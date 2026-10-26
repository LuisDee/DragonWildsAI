# Companion quality: why he feels dumb and robotic, and what fixes it (2026-10-25, 21:20)

Evidence: chat 20:54–21:18, brain logs, the persona in `brain/controller.py`. Companion to `autonomy-plan.md` (speed and long-horizon).

## 1. Diagnosis (what Luis saw → cause)
| Symptom | Cause |
|---|---|
| Narrates stats and position ("standing 13 m from you, food is at 15%"), explains what he "learned about the tree" | The persona is a 4k-character rulebook that says "ALWAYS reply with one line, also when you call a tool", plus "communication is paramount" taken literally. `situation_review` hands him stats_pct and he reads them out. Templates ("Done, gathered 4 Wood Ash.") plus a model report = two lines per action. |
| Promises, then doesn't act; says "Done." when not done | Turns that only talk, and canned templates (BUGS L3/L5). |
| Splinters at Luis's feet; chops a fresh tree instead of the felled log | Primitive failures (L14/L15), plus the model picks without knowing what the spell targets. |
| Hungry: "I'll look for a fire", but never thinks of crafting, cooking, berries 9 m away, or asking Luis | Perception gives ~20 resources, 13 items, 19 interactables, all flat and unranked, with no "needs → options" view. The crafting module can already compute what's craftable (`crafting.lua` `craftable`, `plan_tree`), but nothing puts "how could I meet this need" in front of the model. |
| Slow | See autonomy-plan §1 (debounce, redundant reads, slow failures, retries). |
| No long plans | No Director or goal tree live (autonomy-plan §4). |

## 2. What "human-like and capable" needs (precedent)
- **Generative Agents** (Park et al. 2023): believability comes from observation → memory (recency/importance/relevance) → reflection → planning, and ablations show each matters. https://arxiv.org/abs/2304.03442
- **PUBG Ally** (Krafton/NVIDIA, 2026):
  - A System 1 behaviour tree runs the reflexes; a System 2 language model handles coordination and speech.
  - Reviewers called it repetitive and robotic ("tells me every five minutes it's a PUBG encyclopedia with legs"). That is exactly our narration failure: talking about itself instead of playing.
  - https://arxiv.org/abs/2609.29837 · https://www.pcgamesn.com/playerunknowns-battlegrounds/ai-teammate · https://developer.nvidia.com/blog/how-krafton-built-pubg-ally-a-co-playable-character-powered-by-nvidia-ace/
- **Altera:** agents' output becomes their future input, so quality degrades over long runs. They need grounded sensing and action plus episodic memory. https://techcrunch.com/2024/05/08/bye-bye-bots-alteras-game-playing-ai-agents-get-backing-from-eric-schmidt/
- **Observation compression** (NetHack diff history): 4× more history in the same context, 7× score. Send what changed and what matters, not everything. https://arxiv.org/html/2312.07540v1
- **Affordance inference** (LLM-Regress, ACL 2025): infer goal-relevant objects and affordances instead of predefining them. https://aclanthology.org/2025.acl-long.1018

## 3. Plan (four workstreams; each has an eval from real chat lines)
**V. Voice (persona rewrite):**
- Replace the rulebook with a character sheet: a laid-back, competent RuneScape player and Luis's mate.
- Few-shot pairs taken from today's chat (bad → good).
- Rules of speech:
  - talk when a player would: answer what's asked, flag what needs the other player ("starving, got any food?"), react to notable moments;
  - stay quiet while just doing the job;
  - never read out stats, metres or internal state unless asked;
  - no templates, at most one line per episode;
  - casual and short, with variety.
- Actions over words: if he says he'll do it, the tool call is in the same turn.
- Communication is paramount means *say why when something fails or you need something*, not narrate.
- *Eval:* about 25 real situations graded by a Sonnet rubric (humanlike, no narration, action matches words) plus deterministic checks. ≤ 30 calls per run.

**N. Needs → options digest (perception, generic):**
- For each pressing need (food, drink, health, rest, a tool for the task), list the ways to meet it, computed from game data:
  - carried (hotbar or bag);
  - nearby (berries 9 m, ground items);
  - craftable now or at a nearby station (`crafting.craftable` / `plan_tree`, including cooking);
  - what's missing for the next-best recipe;
  - which player could help.
- Also rank and trim the rest of the perception to the top-N relevant (≤ 8k-token prompt).
- This is information, not a mapping (PRINCIPLES #2).

**M. Memory and lessons:**
- Luis's corrections become persisted lessons the model sees, e.g. "cancel a spell you won't use instead of casting it", "don't tell me, do it". House rules (`brain/house_rules.md`) for his explicit rules; episodic notes for what happened.
- Reflection at milestones (Generative Agents); the facts are never the model's own claims.

**D. Director + speed + reliability:** autonomy-plan §2–4. The Director lets him think about bigger problems (gear, food chains, levelling) with Sonnet, and keeps Haiku fast for chat.

## 4. Order
1. Now: reliability (L14/L15 just landed), speed (broker), voice V (new voice agent).
2. Next: N needs → options (skills/capability agent), M lessons.
3. Then: Director (design in review), acceptance ladder.

## 5. Voice (workstream V), 2026-10-25 evening

### Voice: search record
- **Need:** a persona that makes Claude sound and act like a co-op player, plus an eval that grades chat lines for human-likeness, appropriate silence and words matching actions.
- **Searched:**
  - LLM game-companion and NPC persona prompting (character sheet, speech rules, few-shot, barks);
  - Mindcraft profiles;
  - Anthropic prompting guidance on examples;
  - companion design (BioShock Infinite's Elizabeth);
  - LLM-as-judge rubrics for dialogue (G-Eval, DeepEval RoleAdherence / ConversationalGEval, persona-fidelity papers).
- **Found:**
  - **Mindcraft's default profile** (`profiles/defaults/_default.json`, "conversing" prompt) is the closest precedent for our failure modes. It says: "Be very brief… don't apologize constantly… Don't pretend to act, use commands immediately when requested. Do NOT say 'Sure, I've stopped.' instead say 'Sure, I'll stop. !stop'". It also has the bot answer with a tab when it has nothing to say. → **adapted:** "the action is the answer", a promise needs its tool call in the same reply, and EMPTY for silence. https://github.com/mindcraft-bots/mindcraft (raw `profiles/defaults/_default.json`)
  - **NPC persona guides** say: identity first, then specific traits rather than adjectives, with 2–4 few-shot exchanges as "the most powerful tool for establishing voice". Fortnite personas are built from a character prompt plus facts. → **adopted:** a character sheet plus bad→good pairs from the real chat. https://abratabia.com/llm-npcs/prompting-npcs.php · https://dev.epicgames.com/documentation/fortnite/developing-personas-overview-in-unreal-editor-for-fortnite
  - **Anthropic guidance:** examples steer format and style most strongly, and stating the desired behaviour beats bare prohibitions. That's why each "don't" in the persona comes with the good line. https://the-decoder.com/anthropic-experts-share-top-tips-for-effective-ai-prompting/
  - **BioShock Infinite's Elizabeth** (GDC 2014, Abercrombie; Levine): the companion asks the game whether now is a good time before doing a bit, and the game can say no. The abstracts frame a companion as "both leader and follower". This is the "talk when a player would" rule; the broker's `situation_review` timing already plays that role. https://gdcvault.com/play/1020831/Bringing-BioShock-Infinite-s-Elizabeth · https://www.pcgamer.com/au/ken-levine-scripting-elizabeth-is-the-most-complicated-thing-in-bioshock-infinite
  - **Judges:**
    - G-Eval (criteria + evaluation steps + an integer score) is the standard rubric pattern.
    - Persona-fidelity papers score per criterion on anchored scales.
    - A judge should be at least as strong as the model it grades.
    - Rubric artifacts are real: judges often fail to flip their verdict when the criterion is inverted, so a rubric must be checked.

    https://qaskills.sh/blog/rubric-based-llm-evaluation-guide-2026 · https://arxiv.org/pdf/2608.26674 · https://arxiv.org/pdf/2609.02942 · https://docs.inference.net/platform/eval/llm-as-a-judge
  - **DeepEval** has `RoleAdherenceMetric` and `ConversationalGEval` for multi-turn chat. https://deepeval.com/docs/metrics-role-adherence
- **Decisions:**
  - **Persona:** adapt the Mindcraft rules and NPC-guide structure (character sheet → speech rules → few-shot → functional rules), written for our tool loop.
  - **Judge:** adapt G-Eval in about 60 lines (`evals/voice_eval.py`).
    - Why not DeepEval: it brings a large dependency tree and its own model wrappers and telemetry, and it defaults to an OpenAI judge. Its metrics grade plain text turns, while we need to grade a line *against the tool calls of the same turn*.
    - What we keep from G-Eval: anchors, a blind judge, Sonnet grading Haiku.
    - The deterministic checks carry the hard rules, so judge bias matters less.
  - **Speech gating** stays in `brain/voice.py`: a bark-manager pattern, already searched (see its docstring).

### What changed
- **Persona text** now lives in `brain/persona.md`, loaded by `brain/persona.py` (re-read on change; `DW_PERSONA` overrides). It has three parts:
  - **Character sheet:** a laid-back, capable RuneScape player and Luis's mate, who looks after his own needs.
  - **Speech rules:** talk when a player would; the action is the answer; promise only with the call in the same reply; no stats, metres or internal state unless asked; one line per moment, under 100 characters, varied; on failure, try to fix it, else one plain line with the reason and what he needs.
  - **8 bad→good pairs** from the 20:40–21:20 chat, plus a final self-check.
- **Functional rules kept:** chat addressing, acting/tool order, grounding, body events, spells, standing orders, and the house-rules hook; the placeholders `{name} {player} {triggers} {look_rule} {lookup_rule}` are unchanged. The old template is in `evals/fixtures/persona_old.md`.
- **Hooks sent to the broker agent** (it owns controller.py, agent.py and broker.py):
  - `Controller.persona()` loads the file, with PERSONA as the fallback;
  - the next_turn notes stop asking for "a short report";
  - the canned speech below is dropped or gated.

### Canned speech in brain/ (as of 22:30) and the proposal
| Where | Line | Proposal |
|---|---|---|
| agent.py:403-404, `_long_done` 432-438 | "Done, gathered {n} {what}." / "Done." | Remove (the model gets the result anyway; it caused the double lines at 21:05:27/28 and 21:16:52/54) |
| agent.py:387-389 | `d.speech or ack or "On it."` at the start of a long action | Say the model's line only; no fallback |
| agent.py:352-353, `_default_reply` 440-448 | "On it.", "On it: {goal}.", "On it, I know how to do that (x).", "Okay." | Don't speak when anything ran or started; keep only "Sorry, I didn't catch that." for a true no-op |
| controller.py:168-172, `ack()` 684-685 | the ACKS table ("Right behind you.", "On my way.", "Here you go.", …) | Delete after the two rows above |
| controller.py:782-793 `progress_event`, 795-798 `milestone` (agent.py:251, 614) | "Gathering: {have}/{want} {what} so far.", "Step {d}/{t} done ({task}), carrying on." | Log only; keep the counters in body_status for "how's it going?" |
| controller.py:761-762 `goal_done` (agent.py:642) | "Done: {goal}." | Remove, or a model-phrased goal_done body_event |
| agent.py:550 | "I'll remember how to do that next time ({skill})." | Remove: narrates internal learning ("why do I care") |
| controller.py:755-759 `ask_for_help` (agent.py:560) | "I'm stuck on '{goal}'. X keeps failing (why). Can you help me out?" | A `stuck` body_event for the model to phrase; the template only if that call errors |
| agent.py:297-299 → controller.py:687-736 `report_failure` | refusals before the body (CANT_SENSE trigger list at 698, REASON_PHRASES "I couldn't X: …") | Send them to the model via next_turn(failed); templates stay as fallbacks (agent.py:322/333/338) |
| agent.py:491, 495-499; controller.py:739-753 | "My standing orders: r1: …", "Forgot N orders.", "Heads up: …" | Give them to the model in the tool result (low priority) |
| controller.py:510-514 next_turn note | "…or reply with a short report" | "Say something only if the player needs to hear it…; otherwise EMPTY" |
| Keep (safety nets) | broker.py:75-84, 148-172 `fallback_line` (model error or silent on unreachable/follow_ended); run_live.py:171 "my head glitched"; agent.py:162 attacked-and-can't-fight | Unchanged. Optional: run_live.py:250 drops the quoted goal |

### Eval (evals/voice_eval.py, evals/voice_cases.jsonl, tests/test_voice.py)
**Cases:** 25 real situations, each holding the exact context the live brain sent, plus the tool results for follow-ups. The body's real tool list comes from `evals/fixtures/voice_manifest.json`.
- 19 are "seen": from the 20:40–21:22 chat, used while tuning.
- 6 are **held out**: from the 19:41–20:11 UTC session. They were picked before run 2 and never looked at while tuning.

The few-shot sources (20:42:17, 20:54:10, 20:58:22, 21:02:53, 21:11:13, 21:16:52/55, 20:55:01) are excluded from the cases.

**Replay:** this is the live Controller loop. Up to 3 calls; read-only tools are answered from the logged results of that turn, or else from the logged situation (marked as an approximation).

**Deterministic checks:**
- no numbers or stats unless asked;
- no ids or codes;
- no future-tense promise without a tool call;
- ≤ 150 characters, one line;
- no near-duplicate of his own chat lines;
- silence or speech where the case requires it;
- a tool call where the player asked for a doable action.

**Judge:** Sonnet, blind to the persona, scoring 1–5 for human, silence and match.

Run it with `python evals/voice_eval.py --plan | --dry | --yes [--max-calls N]`.

**Results.** Haiku 5.5 runs at effort low, as live; Sonnet 5.5 is the judge. Logs: `logs/voice-eval-20261025-223150.jsonl` (run 1) and `logs/voice-eval-20261025-223856.jsonl` (run 2).

Run 1 was single-call and had no held-out split. It used 54 calls. All 25 cases, old → new:

| Metric | Old | New |
|---|---|---|
| Checks pass | 0.75 | 0.82 |
| Judge human | 2.38 | 3.50 |
| Judge silence | 3.36 | 3.88 |
| Judge match | 2.56 | 3.20 |

Run 1 exposed read-only first steps being scored as if final, and over-silence. The persona was patched after it (the "let's", direct-question, needs and final self-check lines), then frozen before run 2.

Run 2 used the read loop and the held-out split, 61 calls:

| Split | Checks pass | Judge human | Judge silence | Judge match | Mean chars when speaking |
|---|---|---|---|---|---|
| All 25 | 0.742 → **0.914** | 2.75 → **3.56** | 3.56 → **4.04** | 2.84 → **3.64** | 131 → 93 |
| Seen 19 | 0.697 → 0.911 | 2.62 → 3.57 | 3.26 → 4.00 | 2.63 → 3.63 | 133 → 81 |
| **Held out 6** | 0.941 → 0.923 | 3.33 → 3.50 | 4.50 → 4.17 | 3.50 → 3.67 | 120 → 134 |

Other run-2 counts, old → new:
- unrequested numbers: 3 of 16 spoken lines → 0 of 9;
- promise-without-call lines: 9 → 2;
- "acted when asked": 6/10 → 9/10.

**Reading it honestly:** the gain is large on the failure types seen in the live chat (narration, stats, promises). On the 6 held-out cases it is about flat, and n=6 is noise-level.
- Those cases come from the earlier session: small talk and plain commands, where the old persona already did fine.
- One held-out case regressed: "fancy a job" got a silent start_goal instead of "sure, what is it?".
- Generalisation is **not yet shown**. The next eval round needs fresh held-out cases from a new session.

### Voice score (GOAL `voice_score_min`, Eval agent 2026-10-26)
- **Definition:** score = **min(checks_pass_rate, judge human / 5, judge silence / 5, judge match / 5)**, over every case of the live persona (`new`) in one full judged run (no `--ids`, `--limit` or `--no-judge`). The weakest part decides. The target of 0.8 means every judge dimension averages at least 4 out of 5 AND at least 80% of the deterministic checks pass. A mean that hides one bad dimension cannot pass.
- **Writer:** `evals/voice_eval.py` appends `{"kind": "voice", run_id, at, score, n, persona, components, log, log_sha256, companion_hash, judge_hash}` to `logs/evals/scoreboard.jsonl`.
- **Check:** `tools/goal_check.py` counts the row only if the log exists with that sha256 and the log's own `voice_summary` re-scores to the row's score and n.
- **The 2026-10-26 11:13 run re-scored offline:** 0.75. Checks pass at 0.957, but human is 3.75/5, silence 4.12/5 and match 3.84/5. Held-out: 0.734 (match 3.67/5). Below the 0.8 target. The weak cases are h5_have_pickaxe_q (match 1: "got a spare one?" with no action), h4_overhead_chop_tip and promise_has_tool (1/2).

### Voice eval v2 (main's findings a–d, 2026-10-26): new baseline
- **k = 3 samples per case:** the score is the k-mean, with the spread across the 3 samples reported. A GOAL row needs k ≥ 3.
- **Scored like the live loop:** the eval scores what the live loop would actually say and do. A turn-0 talk-only reply gets the `agent.PROMISE_NOTE` continuation; a follow-up gets `Controller._talk_only_check` (`TALK_ONLY_NOTE`). First-reply checks stay as a diagnostic.
- **Fixtures (`evals/voice_fixtures.py`):** all 25 cases had a truncated bag ("+16 more"). They are re-rendered by the current perception from the last logged get_state before the case, which shows "Spare gear: Mithril Pickaxe" in h5, and the full inventory is served as the `inventory` read.
- **Fresh held-out (seed 20261026, h4/h5 excluded as read):** h6_mine_a_rock, v01_lets_sleep_how, v04_it_didnt_fail, v13_cast_cut_tree, v17_review_food_50, v20_by_felled_tree.
- **Baseline at HEAD** (`logs/voice-eval-20261026-113456.jsonl`, 90 calls, the cap reached):
  - **score 0.73** (k-mean; per sample 0.696 / 0.752 / 0.724, sd 0.028), so a persona change must move the score by more than about 0.06 to be signal;
  - checks pass at 0.918; judge human 3.80, silence 3.97, match 3.65 (the min);
  - held-out: match 3.94, human 3.60;
  - promise_has_tool 0/3 even after the continuation: 6 continuations, none added an action;
  - silence check 22/30.
  - Caveat: the 90-call cap was reached, so some late samples had their reads or continuation cut by the budget reserve. A 110-call cap would remove that bias.

- **Corrected baseline at 03c93df** (honest-option notes; cap 120, 119 used, no continuation skipped; `logs/voice-eval-20261026-115430.jsonl`):
  - **score 0.80**, set by human 4.00/5 (the min); k-mean, per sample 0.822 / 0.756 / 0.816, sd 0.036;
  - checks pass at 0.955; silence 4.20, match 4.04; promise_has_tool 5/7; 21 continuations ran, 5 of which added an action;
  - held-out: human 3.67, silence 4.56, match 4.61.
  - The 0.73 above was a measurement artefact: the 90-call cap had starved the continuations.

### Open items (voice)
1. **Over-silence on direct questions** (v18 "why are you casting Splinter near me?" → silent gather; h2 "fancy a job" → silent start_goal). The persona rule "a direct question gets a short answer" doesn't hold under effort low. Options:
   - move the rule into the few-shots, with a question → answer + action pair;
   - try effort medium for addressed chat only.
2. **Promises still slip** (v08 "I'll wait for the hatchet after", v16 "…or I'll split them by hand"). The live L5 check (`agent.PROMISE_NOTE`, one extra turn after a talk-only reply) catches these live, but the eval doesn't simulate it.
3. **"let's sleep first"** is still read as "wait" (v08) under both personas: a comprehension problem, not voice.
4. **The broker hooks** (`persona()` loader, next_turn notes, template removal) are not applied yet. Until then live speech still has "On it." / "Done, gathered N X." around the model's lines.
5. **Perception still hands out stats** (`situation` "You: HP 100%, water 50%, food 57%", situation_review `stats_pct`). The persona says not to read them out; workstream N could pass needs as words ("hungry", "starving") instead.
6. **Luis's lesson** "cancel a spell you won't use instead of casting it" belongs in house rules / lessons (workstream M), not the persona.

## Follow-up talk-only check (2026-10-26, voice agent)
- **Need:** a follow-up turn that comes after tool results or a body event and returns text without a tool call ends the chain. Example, live 21:17:50: "It's raw, so I'll look for a fire". The turn-0 check in agent.py (PROMISE_NOTE, BUGS L5) doesn't reach those turns.
- **Fix:** `Controller._talk_only_check()` in `brain/controller.py`.
  - When a follow-up turn returns text and no tool call, the model gets one more call before its line is said.
  - If that call uses tools, they run with the model's own line. If it replies empty or errors, the original line stands.
  - The fix triggers on the reply's shape, not on its words. It never vetoes the model's decision.
  - Each check logs a `talk_only_check` row. Tests: tests/test_talk_only_followup.py.
- **Sources:**
  - Claude Code Stop hook continuation (`decision: block`, `stop_hook_active` loop guard): https://docs.anthropic.com/en/docs/claude-code/hooks
  - Branch on stop_reason / "no tool call", not on prose: https://www.developersdigest.tech/blog/the-agent-loop-explained
  - Stalls under "no tool call = stop" gates: https://arxiv.org/pdf/2609.08589
  - `tool_choice=any` rejected, because it forces a call even when silence is right: https://webscraft.org/blog/yak-model-llm-virishuye-koli-shukati-mehanika-priynyattya-rishen?lang=en
- **Decision:** adapt. The stop-hook continuation pattern already used for turn 0 now covers follow-up turns too.
- **Persona experiments:** two runs (logs/voice-eval-20261026-112228 and -112444) both regressed the voice score, from 0.75 to 0.696 and then 0.648, so persona.md was reverted. Their scoreboard rows were recorded at an experimental hash and are not the current companion.
- **Noise:** with n=25 and one sample per case, a persona tweak moves cases in both directions. Measurement needs k≥3 samples per case.
