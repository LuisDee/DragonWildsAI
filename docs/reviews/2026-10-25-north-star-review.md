# Cold review against the North Star (2026-10-25)

Reviewer: a fresh-context agent that did not write this code. Standards applied: `docs/design/PRINCIPLES.md` and CLAUDE.md section 0, nothing else.

**Scope**
- `brain/`: controller, agent, situation, interface, capabilities, run_live, broker, voice, grounding; executor, planner and skill_library skimmed.
- `client_mod/scripts/*.lua`.
- `client_mod/commands/` skimmed only (throwaway).

**Snapshot.** This is the working tree, which other agents were editing during the review (`git status`: about 20 modified files and several untracked ones, among them `brain/broker.py`, `brain/grounding.py` and `brain/voice.py`). Line numbers are as read and may drift, so each finding quotes the code. One bug was seen mid-review and fixed by its owner before this was written: `controller.report_failure` referenced `grounding.UNCLEAR` / `grounding.clarify` after they were removed. It is not listed below.

`tests/test_principles.py` passes (2 tests). It misses most of the findings below: see section 6.

---

## 1. Summary: top violations by severity

| # | Sev | Where | Principle | One line |
|---|---|---|---|---|
| 1 | **High** | `brain/broker.py:242`, `brain/agent.py:119` + `client_bridge.lua` `finish()` | #7 | A persistent `follow` that later ends or fails sends `task_failed`. The broker drops every TaskDone/TaskFailed, so **follow ends silently**. |
| 2 | **High** | `inventory.lua:435,509` + `client_bridge.lua:1204` + `broker._vitals` | #7, #2(e) | The stay-fed reflex only uses the **hotbar**, but "has food" counts the **bag**. With food only in the bag, no `vitals_low` is sent, the `no_hotbar_*` event goes only to a file, and Claude **starves silently**. Thresholds are fixed at `eat_below = 30`. |
| 3 | **High** | `brain/agent.py:40-42,403-425` | #2 | Regexes `LEARNED_RE` / `FORGET_RE` map phrases to commands and **bypass the model**. "forget the wolf, follow me" can delete a learned skill, and the follow is never seen. "what did you learn from that fight?" lists skills. |
| 4 | **High** | `brain/controller.py:465-469` | #7, single voice | Tool calls with invalid args are **dropped silently** (logged, `continue`, no refusal). The model's reply ("On my way!") is still spoken while nothing happens. |
| 5 | Med | `brain/voice.py:45` via `controller.say` | #7 | The near-duplicate gate also suppresses **replies to new commands** and **failure reports**. If he asks the same question twice within 30 s, the second answer is never said. |
| 6 | Med | `brain/agent.py:43,351-369` | #2 | The `HERE_WORDS` phrase set decides whether `remember(place:…)` stores a position. Other wordings silently store a place with no position, which breaks `go_to` later. |
| 7 | Med | `combat.lua:64,85-92`; `traverse_learn.lua:81`; `brain/interface.py:143,220` | #3 | Hard-coded entities: player `"Zezima"`, creature priors `goblin`/`kalphite`, spell `"Windstep"` + `Air = 5`, and `"luis"` in tool schemas. |
| 8 | Med | `combat.lua` cfg/orders; `manifest.lua:132`; `inventory.lua:435`; vitals thresholds in 4 places | #2(e) | The fight and survival policy (heal_hp 0.5, eat_hp 0.55, flee_hp 0.35, pl_gap_flee, max_hostiles, eat/drink below 30) is fixed. The model has **no tool** to set it, because `combat_orders` is `llm = false`. |
| 9 | Med | `combat.lua:1488` (start_fight) + manifest `attack` | #2 (judgement) | A commanded `attack` is vetoed by a body policy (too strong / outnumbered / low HP) unless `force`. The model never saw that assessment before choosing. |
| 10 | Low-Med | `brain/controller.py:56-58,64,114-116`; `manifest.lua` `stop` | #2 (judgement) | Utterance→tool mappings in prompts ("wait here" = stop, "come here" = go_to, "raises its claws" → telegraph). One contradicts the manifest: go_to says "for a player use come_to". |
| 11 | Low | `move.lua:120,640` → `skills.lua:173`, `broker.UNREACHABLE_LINES` | #7 truthfulness | Any rise above 250 cm is labelled `leader_windstepped`, and Claude says "you Windstepped". That is an inference spoken as fact. |
| 12 | Low | `brain/run_live.py:60-74` | #2 (judgement) | `GREETINGS` stripping rewrites the player's words before the model sees them. |

No **(d)** violations were found. There are no client `Server_*` calls, no Health/Inventory/Damage writes, and no emulated outcomes in `client_mod/scripts`. No **(g)** violations: the LLM runs only on events, and reflexes and movement are deterministic. See section 5 for the good patterns.

---

## 2. High severity

### H1. Persistent follow can end silently (#7 "persistent behaviours never end silently")
- `client_mod/scripts/client_bridge.lua` `R.follow` replies at once (`replied = true`) and holds an action. Its `poll` later returns `fail("interrupted", {detail = "follow ended (...)"})`, or `fail(reason_code(res.reason or "unknown_target"))`. `finish()` then emits `task_failed`. The only exception is `quiet` preempts, which are fine.
- `brain/broker.py:242`:
  ```python
  elif isinstance(ev, (TaskDone, TaskFailed)):
      why = "action result: the executor already has it (synchronous reply)"
  ```
  and `brain/agent.py:119` `if isinstance(event, (TaskDone, TaskFailed)): return`.
- For a held action the synchronous reply was the *start* (`ok`). The later failure is not something the executor has. Cases like "player logged out", "move stopped underneath" or a debug stop are swallowed. Only `unreachable` / `stuck` reach the brain, because move.lua emits them separately.
- **Fix (minimal):** in `triage`, drop a TaskDone/TaskFailed only when its `task_id` is the id of a request still waiting synchronously, or already answered with that same result. For held actions (follow), convert a `task_failed` into a body situation (`decide`) so the Controller says why. Alternatively, have the body emit an `activity{kind: "follow_ended", reason}` and make the broker treat it as a decide-situation. Add a regression test: follow ok → later task_failed → one spoken line.

### H2. Stay-fed reflex and vitals reporting disagree: silent starvation (#7), fixed thresholds (#2 e)
- `inventory.lua:435`:
  ```lua
  M.REFLEX_CFG = { period_ms = 2000, drink_below = 30, eat_below = 30, ..., allow_bag = false }
  ```
  `inventory.lua:509` uses `hotbar_only = not cfg.allow_bag`. When food is only in the bag, it writes `no_hotbar_<kind>` to `client_io/events/vitals.jsonl`. `forward_vitals` (client_bridge.lua ~1078-1101) forwards only `death` / `revive` / `damage`, so **the brain never hears it**.
- `client_bridge.lua:1204` `check_vitals` counts `{ "hotbar", "bag" }` as "has food", so it does **not** emit `vitals_low`. `broker._vitals` also drops `vitals_low` "carries X now (the stay-fed reflex uses it)".
- Net effect: food is in the bag, the reflex won't use it, nobody is told, and Claude starves. The same happens for items the reflex marks `R.bad` after one failed use: still counted as "has food", never used again, never reported.
- **Fix:**
  1. `check_vitals` / `broker` should count only what the reflex can actually use (hotbar, minus `R.bad`), or forward `reflex` events (`no_hotbar_*`, `verify ok=false`) as body situations.
  2. Make `drink_below` / `eat_below` model-settable standing orders (see M8), with a code safety floor, e.g. always eat at ≤ 5 % whatever the order.
  3. Unify the four "low" thresholds: `client_bridge.VITALS_LOW = 15`, `inventory eat_below = 30`, `situation.py:347` `(LOW) if pct < 15`, `broker.facts` `cur < 0.2 * max`.

### H3. Phrase→command regexes bypass the model (#2 "no phrase→skill tables or keyword rules", "code never overrides the model's interpretation")
- `brain/agent.py:40-42`:
  ```python
  LEARNED_RE = re.compile(r"^\s*(what (have|did) you (learn|learned|learnt)|what do you know how to do|" ...
  FORGET_RE = re.compile(r"^\s*forget (?:about )?(?:the |your )?(?:skill |how to )?(.+?)[.!?]*\s*$", re.I)
  ```
  `_command` calls `_skill_command(event.text)` **before** the Controller. Verified with the venv:
  - `"forget the wolf, follow me"` → FORGET group `"wolf, follow me"`;
  - `"forget about the logs, just come here"` → `"logs, just come here"`;
  - `"what did you learn from that fight?"` → LEARNED match, so it lists skills instead of answering from `recent_activity`.
- `find_name` falls back to BM25 and accepts a match on **one shared token** (`skill_library.py:316`). Any learned skill with "log" or "wolf" in its name is then **deleted** without the model, and the rest of the instruction is lost.
- This is the anti-pattern `if "get your stuff" in text` in regex form. The test misses it because `PHRASE_COND` looks only for string literals.
- **Fix:** delete both regexes. Add two brain tools, `list_skills()` (read) and `forget_skill(name)` (action), and put the learned skill names in the context (they are already in `learned_skills`). The model decides; `forget_skill` with an unknown name returns `unknown_skill` and the candidates.

### H4. Invalid tool args are dropped without a word (#7, single voice)
- `brain/controller.py:465-469`:
  ```python
  try:
      call.arguments = self._validate(call.name, call.arguments)
  except Exception as exc:
      self.log.log("controller_invalid_call", tool=call.name, error=str(exc))
      continue
  ```
  No refusal is recorded. In `Agent._command`, `d.actions` is empty and there is no failure, so `d.speech` (written as if the action happens, e.g. "Coming!") is said. The companion claims an action it never starts.
- A similar gap: `start_goal` with no `goal`, and unknown tool names not in `TOOLS` (`controller.py:451`), are also dropped silently.
- **Fix:** `d.refusals.append((call.name, Reason.INVALID_ARGS, {"error": str(exc)[:300]}))`. Route it through `follow_up`, like a body failure, so the model can fix its args once or say what went wrong. The same applies to the unknown-tool and empty-goal cases.

---

## 3. Medium severity

### M5. The voice gate eats real replies (#7)
- `brain/voice.py:45` `gate()` drops any non-system line with ratio ≥ 0.85 to one said within 30 s. `Controller.say` returns `None`, and `Agent._command` has no fallback. So a repeated question ("what are you holding?" twice), or a repeated failure the player is retrying ("I can't see any sticks around here"), gets **no answer**. The player sees silence.
- **Fix:** gate only `kind == "notice"` (body situations), never `reply` to a new command. Alternatively, pass "you said this N s ago" to the model in context (`chat` already has `you=true` lines) and let it rephrase. Keep the gate as a burst guard, e.g. the identical line within 2 s.

### M6. `HERE_WORDS` interprets language in code (#2)
- `brain/agent.py:43` `HERE_WORDS = {"here", "there", "this spot", "where i am standing", "where you are"}`. `_remember` (361) stores a position only on an exact match. "right here", "where we're standing" or "this camp" are stored with `pos = None`, and the reply is still "Noted.". A later `go_to(camp)` then fails.
- **Fix:** change `RememberArgs` to have `at: Literal["self", "player"] | None` plus an optional `player`. The model sets it; code just reads the position. If `place:` is set and no position resolves, return a failure so the model says so.

### M7. Hard-coded entities in logic (#3 "no item, creature, place or recipe lists in code")
- `combat.lua:64` `protect = "Zezima", -- Luis's character on the Shockbyte world`: a real player's name in body logic. It is wrong on any other world or for any other friend. **Fix:** set it from the brain (`LiveOptions.player`), or protect every player.
- `combat.lua:85-89` `M.PRIORS = { goblin = {...}, kalphite = {...} }`: per-creature priors in code. **Fix:** move them to an enemies data profile (CLAUDE.md principle 2, "data profiles: enemies"), e.g. `data/enemies_<build>.json`, loaded like `weapons_data.lua`. `TOOL_FACTOR` (90) is a category table; it is borderline but belongs in the same profile.
- `traverse_learn.lua:81` `windstep = { spells = { "Windstep" }, runes = { Air = 5 } }`: a spell name and cost in movement logic. **Fix:** read them from the spell catalog or the coming `spells.lua` `list()`: "a spell whose effect grants a high jump, castable". At minimum, keep it in a data file.
- `brain/interface.py:143` `at: Literal["feet", "luis"]` and `:220` `"luis_hp_below"` (also in `ReflexTrigger.kind`): one player's name baked into tool schemas. **Fix:** use `at: "feet" | "player"` plus `player: str`, and `player_hp_below` plus `player`.
- `sense.lua:304,407` `(d.tool == "Hatchet" and "chop") or (d.tool == "Pickaxe" and "mine")`: a small tool→verb table. Low priority; take it from `gather_profiles`.

### M8. Fight and survival policy is fixed; the model can't set it (#2 e: "fixed thresholds the model should decide; code only enforces a safety floor")
- `combat.lua` cfg: `flee_hp = 0.35`, `eat_hp = 0.55`, `pl_gap_flee = 2`, `max_hostiles = 2`, `fight_enter = 0.5`. Orders: `heal_hp = 0.5`, `reengage_hp = 0.8`, `stance`, `avoid`.
- `M.orders` is documented as "the brain / Luis can change them: combat_orders", but `manifest.lua:132` publishes `combat_orders = { kind = "probe", llm = false, ... "(debug)" }`, so the Controller is never offered it. `inventory.REFLEX_CFG` (eat/drink below 30) has no tool at all.
- **Fix:** publish one `llm = true` tool, e.g. `set_policy {stance, avoid[], heal_hp, flee_hp, eat_below, drink_below}`, with schema bounds. Code clamps to a **safety floor** (e.g. `flee_hp ≥ 0.15`, always eat at ≤ 5 %). Show the current policy in context next to `reflex_rules`. Luis says "fight to the death", "don't eat my sandwiches" or "eat when you're half hungry", and the model sets it.

### M9. A commanded attack is vetoed by body policy (#2, judgement call)
- `combat.lua:1488`:
  ```lua
  if opts.mode == "attack" and not opts.force then
      local a = M.assess(...)
      if a.decision == "flee" then return { ok = false, reason = "unsafe", data = { why = a.why, ... } }
  ```
  The manifest says "refuses unsafe fights … force: only when the player insists".
- Mitigating factors: the result is truthful, and the model can retry with `force` through `follow_up`. Still, "too strong / outnumbered" is a body policy, not one of Luis's explicit safety rules, and the model decided without seeing the assessment.
- **Fix:** put the assessment in perception (e.g. a `look` or situation creature note "PL 4 vs your 1, risky"). Then either drop the up-front veto, so the mid-fight flee floor stays as the reflex, or keep it as the model-settable policy from M8. The never-attack-players check (combat.lua start_fight plus `Controller.safety`) stays: that is Luis's rule.

---

## 4. Low severity / judgement calls

- **L10. Utterance mappings in prompts** (`controller.py:56-58` `"wait here" = stop. "come here" = go_to the player.`; `:64` `"chop it" = 1 more`; `:114-116` `Map his words: "raises its claws", "winds up" ... -> telegraph`; the manifest `stop` description `"wait here" = stop`).
  - This is not code deciding, but it is a phrase table in prompt form. It tunes to specific utterances, against the "model infers" spirit.
  - It is also **contradictory**: the manifest `go_to` says "For walking to a player use come_to instead".
  - **Fix:** describe tool semantics ("stop: stand still and stay where you are") instead of utterances, and remove the `go_to`-for-player line. Cover the phrasings with held-out eval cases, not prompt text.
- **L11. "you Windstepped" is a guess spoken as fact.** `move.lua:640`: a rise > `superjump_cm` (250) on one jump becomes `leader_windstepped`. Then `skills.lua:173` says "you Windstepped over somewhere I can't follow yet" and `broker.UNREACHABLE_LINES` says the same. A ledge, a lift or a knock-up gives the same rise. **Fix:** name the reason after the measurement (`leader_rose{rise_m}`) and let the model phrase it ("you went up about 4 m in one jump").
- **L12. `run_live._strip_name` + `GREETINGS`** (`run_live.py:60-74`) rewrite the command text ("ok", "dear" and others are stripped). The raw line is still in `chat`, so the harm is small. Prefer passing the raw text and letting the model ignore greetings; addressing detection (the name as a whole word) is fine.
- `brain/controller.py:458-464`: the `set_reflex_rule` trigger check (`CANT_SENSE`) duplicates the schema `Literal`. It is truthful and capability-based, not wording-based, so it is acceptable. It could be left to the schema plus the body's own `cant_sense`.
- `brain/capabilities.py` `resolve()` + `LEGACY_ARGS` rewrites `pickup` → `fetch` when the model calls a legacy name. This is mechanical aliasing published by the body, not wording-based. Acceptable; log it, as it already does.
- `brain/controller.py` `ACKS` / `SKILL_PHRASES` / `REASON_PHRASES` and `broker.UNREACHABLE_LINES` are code-written speech. They are acceptable as safety nets, because `_explain_failure` gives the model the result first. Keep them as fallback only.
- Executor verifiers trust the body when fresh state lacks the field (`_v_go_to` with no `target_position`, `_v_come_to` when the player is not in the census, `_v_interact` with no item, `_v_cast`). This is a reasonable bound, but log `verified: "body_only"` so Luis-facing claims can be qualified.
- `situation.py` mock-only `{"log": "tree", "stone": "rock"}` (perceived, mock branch). Harmless, mock only.
- The `move.lua` nav oracle (`tools/nav_oracle.py`, server navmesh) is perception that only the dev server has. It is fine as information and is gated on a heartbeat, but it does not generalise to production hosting. Note it in the design doc.
- `brain/agent.py` `_chat_waiting` in the base class always returns `False` (dead in Agent, overridden in LiveAgent). Harmless.

---

## 5. Good patterns worth keeping

- **Grounding as information only.** `brain/grounding.py` (`read` / `hints` → `references` in the context) does typo-tolerant candidate matching and states explicitly that it never vetoes. This is the model for the "assist, don't decide" rule.
- **One code gate on model calls:** `Controller.safety` contains only Luis's never-attack-players rule, and the body enforces it again (`combat.lua` start_fight: PlayerState / PlayerCharacter / follower → `unsafe`).
- **A truthful tool list from the body:** the capability manifest (`brain/capabilities.py`, `manifest.lua`, module `MANIFEST`s). The model can never be offered a tool the body lacks, and arguments are validated against the body's own schema (MCP-style precedent cited).
- **Failure goes back to the model:** `Agent._explain_failure` → `Controller.follow_up` lets the model word the failure and try one fix. Templates are only the safety net.
- **Verified state:** the executor baselines and verifiers (inventory deltas on the id the body resolved, fresh position for go_to, rule read-back for `set_reflex_rule`). The client `go_to` re-checks arrival against a fresh position.
- **Real player paths on the client:** chat sends through the chat widget's own `OnTextCommitted`, not `Server_SendChatMessage`. Combat and gather inject `IA_PrimaryAction`. Items are used via the hotbar `UseItemInSlot` and the `InventoryUIAPI` handlers. Unstuck goes through the pause-menu button. Movement uses `Jump` and `AddMovementInput` and "never teleports".
- **Event hygiene:** the broker dedupes, supersedes and coalesces structured events by type and fields (no phrase matching), with `still_valid` re-checked at speak time, plus `_fresh_reply` re-deciding a pure-talk reply on changed facts. These are good bark-manager patterns, with precedent cited. H1 is a gap in an otherwise sound design.
- **Two speeds:** the LLM runs only on chat and body situations (`run_live` polls the bridge file, and there are no model timers). Reflexes (combat guard, stay-fed, movement unstuck ladder) run in Lua at frame rate. There is a rate cap on unaddressed chat.
- **Data-driven gather:** `gather.lua` + `gather_profiles.lua` + `weapons_data.lua`, with the tool tier read from the live gate and progress counted from the inventory, "never our own tally".
- **Episodic memory:** `Activity` events from any starter (brain, reflex, debug) feed `recent_activity`, so Claude can answer "what did you just do?" truthfully.
- **Precedent:** every module header cites what it reused and where from (#6).

---

## 6. Guardrail test gaps (`tests/test_principles.py`)

The current regexes miss H3, M6, M7 and L10. Suggested additions, each with a small explicit allowlist:
1. **No regex/keyword routing of player text in `brain/`:** flag `re.compile(` whose pattern contains a literal multi-word English phrase, and `set`/`dict` literals of lowercase English words used with `in low` / `in text` (`HERE_WORDS`, `GREETINGS`). Allowlist: `grounding.py` stemming, and `dry_run_llm.py` (a test fake, which says so).
2. **No player or creature names in logic:** flag `Zezima`, `"luis"` (case-insensitive) in `brain/*.py` and `client_mod/scripts/*.lua` outside data files and comments. Flag creature words from `data/` catalogs that appear as table keys in non-data Lua files.
3. **Held actions must not be swallowed:** a unit test that a `task_failed` for a held follow reaches the Controller (H1 regression).
4. **Every dropped model call yields a refusal:** a unit test that invalid args lead to a spoken reason (H4 regression).
