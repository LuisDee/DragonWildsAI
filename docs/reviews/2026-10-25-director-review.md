# Review: docs/design/director.md (Director, task board, predicates, StepRunner)

- **Reviewer:** a fresh-context design reviewer (PRINCIPLES.md review gate). Date: 2026-10-25.
- **Reviewed:** the untracked working copy of `docs/design/director.md`, 311 lines. The note changed during the review: a `## Search record` and the "Eval agent (agreed)" text were added. I reviewed the later version.
- **Checked against:** PRINCIPLES.md, GOAL.md, autonomy-plan.md, companion-quality.md and ARCHITECTURE.md.
- **Code read:** `brain/agent.py`, `controller.py`, `run_live.py`, `planner.py`, `executor.py`, `state_store.py`, `knowledge.py`, `item_stats.py`, `skill_library.py`, `broker.py`; the already-built `brain/predicates.py`; and on the client side `client_bridge.lua` (`get_state`), `sense.lua`, `skills.lua`, `crafting.lua` and `combat.lua` state_extras / combat_end.

## Verdict: **approve with changes**

The overall design is sound and within the principles:
- three speeds;
- the Director acts only through the Controller's own tools;
- "done" is decided by code-evaluated predicates on fresh state;
- caps, a budget, a gap log, and no names in code.

Nothing here needs a redesign. But eleven findings (H1–H11) must be fixed in the note before code is written. They cover verification integrity, a false-pass bug already in `predicates.py`, races and thread-safety, a duplicated recipe planner, dead ends that loop forever, and an acceptance plan that only proves the plumbing.

---

## Answers to the six questions

### Q1. Phrase maps, hard-coding, vetoes, and model claims as state

**Phrase→tool maps: none.**
- Language goes to the Controller model, which calls `add_task`, `pause_board` and `cancel_task`.
- `tools/board.py` text goes to the Director as plain text.
- Watch the overfit detector (`tests/test_overfit.py`). The example lines in §1/§2.6 ("Back to the coal", "drop the coal job") must not end up in brain/ prompt strings.

**Hard-coded items, places or creatures: none in the design.** All names come from data, state, places and the wiki. The GearWorld mock and the tests are exempt. One gap:
- Readiness relies on "`creature_priors` data and learned hit outcomes".
- Both live only in `client_mod/scripts` (a Lua table, and combat.lua's memory). The brain can't read them (see M8).

**Code vetoing or overriding the model.** Mostly clean. Caps, the budget and loop re-queues are a bounded-retry policy that hands the decision back to DEPS. Two places override the model or the player in effect:
- **H4: auto-resume.** It restarts the board 30 s after the player's "stop" or "wait here".
- **H6: the following gate.** `add_task(now)` while he is following never starts.

**Model claims as state.** `report_step(done)` is correctly never trusted. But:
- **H1:** the Director *writes the predicates that define done*, and can weaken or trivialise them. That turns a claim back into "state".
- **M4:** Director-declared `capability_gaps` are model claims, and they would be logged as fact.

### Q2. Can each predicate be checked from today's perception?

Suppliers are from `client_bridge.lua` `get_state`, `sense.me`, the `state_extras` of skills.lua and crafting.lua, and broker activity.

| Leaf | Supplied by | Status |
|---|---|---|
| `have` | `inventory` (hotbar + bag, `inventory_view`; loadout excluded) | **OK** |
| `gained` | `inventory` minus the persisted baseline `snapshot()` | **OK.** Attribution is wrong across preemption (H3) |
| `tally` | board-computed step deltas | **Mechanically OK; semantics undefined** (H3: deposits, drops, preemption) |
| `skill` | `sense.me` → `skills[{skill, level, xp}]` (SkillComponent) | **OK** (names normalised by `_skill_key`) |
| `skill_gain` | same, plus the baseline | **OK for pass/fail. Progress is useless:** levels only, so `xp` is ignored and the no-progress rule fails levelling steps (H8) |
| `equipped` | `gear` (loadout slots plus `held_right` / `held_left`) | **OK for armour. Flaky for tools and weapons:** "equipped" means *held at this instant* (H2) |
| `gear_better` | `gear` / `inventory` / `inventory_items` + `item_stats` (`tier`, `power_level`) | **Works, but has a false pass** (H2). It ignores instance stats (level, ascension, enchant: `inventory.lua` reports only `enchanted`), so upgrades by ascension or enchant are invisible (L3) |
| `bag` | skills.lua `state_extras` `bag{used = bag slot rows, capacity = InventoryItems page n}` | **OK, slot-based.** A slot with a partial stack isn't "full". `capacity` is nil when the page read fails, and then `any[bag, have]` evaluates to null (M9) |
| `near` (position, player) | `position`, `players` (census ≤ 50 m) | **OK** |
| `near` (place) | `places.json` via ctx | **OK** for places Luis taught. **Gap** for wiki regions: no region→coordinates data exists (H9) |
| `near` (thing) | census rows by exact id, ≤ 50 m | **OK only while in sight.** An id from map memory is stale once out of range |
| `moved` | position vs the baseline | **OK** |
| `killed` | `combat_end` activity (`target` = display name, `outcome`) | **Partial.** Needs its own persisted counter, because broker keeps `ACTIVITY_KEEP = 8` and nothing is persisted (M6). The substring match counts "goblin" in "Hobgoblin" (L2) |
| `quest` | — | **Gap** (null; honest) |

Missing leaves that the requested or GOAL jobs need (all gaps today):
- delivered/given: no negative `gained` or `lost`, and no "items on the ground near X";
- elapsed or waited time (for farm crops);
- crop or structure state (`structures` is in `not_implemented`);
- station running or output (`stations_nearby[].running` exists in state, but no leaf reads it);
- vitals (for "re-stock food" in ladder 2);
- container contents (deposit).

### Q3. Failures and dead ends

All covered in the findings:
- **Loops and oscillation:** H5 (empty-queue Director calls are uncapped), H10 (prerequisite tasks re-added).
- **A board that never completes:** H5, M1 (open tasks starve the queue; `waiting_help` blocks the board).
- **Preemption races:** H4, H6, H7 (stale worker results; runs cut short by other players' chat).
- **Thread safety:** H11.
- **Persistence on restart:** M2, M3.
- **Budget exhaustion:** M5.

### Q4. Reuse vs duplication

- **Duplicated:**
  - `brain/recipes.py` duplicates `crafting.lua` `plan_tree` / `craft_plan` (H7b).
  - `BoardStore` + `goals.json` + Director DEPS run alongside `StateStore.TaskTree` + `task_tree.json` + `Planner.replan` + `Agent.run_goal`. The old path stays alive through `run_skill` (M7).
- **Minor overlap:**
  - `CallBudget` vs `LiveAgent._rate_capped`;
  - the gap log vs `Capabilities.missing`;
  - milestone speech vs `Controller.progress` / `milestone`.
- **Real reuse:** `item_stats`, `knowledge.lookup`, `SkillLibrary.learn` (with caveats, H11 and M7), the existing verifiers through `Agent._run_task`, and `places.json`.

### Q5. Search record

Real and adequate. It has 16+ distinct URLs, all relevant, and passes `tests/test_design_notes.py`. I spot-checked two:
- StructAgent, arXiv 2607.11388, exists and matches the description.
- Mindcraft `self_prompter.js` matches: STOPPED / ACTIVE / PAUSED, 2000 ms cooldown, `MAX_NO_COMMAND = 3`.

Corrections are in L4:
- pyrate-limiter *does* persist to a file (`SQLiteBucket`).
- There was no search for an off-the-shelf JSON predicate evaluator (JsonLogic, CEL), nor for benchmark success checkers (MineDojo programmatic tasks, Crafter achievements, PDDL goal conditions), although the predicate format is the core new artefact.

### Q6. Is the acceptance plan enough?

No. Every offline test runs on a *scripted* FakeLLM Director, so it proves the plumbing, not that the jobs "fall out generically". Of GOAL §1's five T3 jobs, only the pickaxe (and only as a player-given task, not "on his own initiative") has an end-to-end test. Coal, farm-drop, quest and desert weed appear only as gap and null cases.

**A held-out job that breaks it:** CLAUDE.md's own Phase 8 gate, "gather 20 logs and 10 stone, then bring them to me". The delivery has no checkable predicate:
- Luis's inventory is invisible.
- There is no `lost` leaf and no `on_ground_near` leaf.

So the Director either writes a weak proxy (`not have Logs`), which passes if he drops them anywhere or dies, or the step is null and goes to `waiting_help`. Other breakers:
- "wait for me at the lodestone": no time leaf;
- "keep the furnace going": no station leaf;
- "kill 5 goblins in Fellhollow" on a fresh world: no region coordinates, and `go_to` `timeout_s` is 120.

See H12.

---

## Findings

Severity: **H** = fix in the note before building; **M** = fix in the note or in the first build wave; **L** = small.

### H1. The model writes its own definition of "done" (§2.2, §2.3 Output, §4)
- **Problem:** the Director authors both the steps and the predicates. A replan can replace `task_success` with something weaker. Nothing stops a predicate that is already true at the baseline (`have Coal ≥ 0`, `near home` while at home). In effect that is the model's claim becoming state, which breaks principle 5 and GOAL §3's eval-of-the-eval rules.
- **Fix:**
  - (a) `task_success` is set by the first decision for a task and is **immutable** afterwards. Only an explicit player instruction can change it, through the Controller's `add_task` / `cancel_task`, and the change is logged and voiced.
  - (b) At validation, evaluate every new predicate on the current state. If one already passes, the repair round gets that as *information* ("already true now: choose a test that measures the work"). That is not a veto: the model may keep it, but the board then marks the step `trivial` in `goals.json` and in `board()`.
  - (c) For player-given tasks, the first `board_step` run carries `task_success` in words, so the line Luis hears says what "done" will mean.
  - (d) Add a negative-control test: a fake Director that writes a trivially-true or weakened predicate is caught (H12).

### H2. `gear_better` / `equipped` pass falsely and flicker for held tools (§2.2; the built `predicates.py` `_best` / `_gear_items`)
- **Problem:**
  - Pickaxes are `two_handed` / `weapon` in the catalog. They are in `gear` only while *held* (`gear.held_right`).
  - With `where: "equipped", than: "start"`, a baseline taken while he held a sword gives `ref = None`. The code then returns "any matching item beats nothing → True". So the task "get a better pickaxe" **passes by switching to the Stone Pickaxe he already had**.
  - Conversely, a Bronze Pickaxe in the hotbar fails `equipped` whenever the combat reflex swaps to a weapon.
- **Fix:**
  - (a) Always compute the `"start"` reference over carried *and* equipped items. The question is "is the best thing I have better than the best thing I had".
  - (b) Document `where: carried` (hotbar counts) as the meaning for tools.
  - (c) Return `False`, not `True`, when the reference is None and the best item now was already carried at the baseline.
  - (d) Unit-test exactly this sequence: held sword at the start → holding the Stone Pickaxe → must be False.

### H3. Tally and baseline semantics are undefined across deposits, drops and preemption (§2.1 Tallies, §2.6)
- **Problem:**
  - "Adds the step's verified inventory delta" means a deposit or drop step (−61 Coal) cancels the mining step (+61).
  - If only positive deltas count, picking his own dropped coal back up (the "drop at base" workaround) counts twice.
  - Preemption keeps the step's baseline, so whatever happens during the chat command counts against the step. If Luis says "give me 10 coal", that is −10. If Luis gives him ore, the step passes falsely.
  - `killed` episodes aren't persisted, so kills before a restart vanish.
- **Fix:** specify the rules.
  - (a) Tallies count **positive** deltas only, per item, and only for items named in the task's or loop's predicates.
  - (b) Each step keeps a list of **segments**. On preempt, close the segment (fold its delta into the step's accumulated delta). On resume, take a fresh baseline. `gained` = the accumulated delta + the current segment, so chat-command activity is excluded.
  - (c) Gains that came from the player or from ground items he dropped himself are recorded but flagged (the `picked_up` activity carries `by` and the item ids), so a "drop at base" round trip can't inflate the tally.
  - (d) Persist the per-step kill count (see M6).

### H4. Auto-resume overrides the player's "stop" / "wait here" (§2.6 Auto-resume)
- **Problem:** `stop` is a chat-originated action, so the board goes to `preempted`, and 30 s later it auto-resumes and walks off. That defeats both the model's decision and Luis's instruction (principle 2).
- **Fix:**
  - The resumed run is a Controller run that **may decline**. It carries the recent chat and the preempting command, and the persona and event text say "if the player told you to stop, wait or stay, call `pause_board` instead".
  - Add a test: "stop" → 30 s → the resume run's model calls `pause_board` → no movement.
  - Also, a preempting command whose tool was `stop` sets `paused_by: player`. That is information in the brief, not a code rule.

### H5. A specific task whose `task_success` never passes loops forever, bounded only by the budget (§2.3 "When it is called", §2.1 Loops)
- **Problem:**
  - Calls for "the step queue is empty" are not counted as replans.
  - A loop that stops after 2 zero-gain loops just empties the queue, so the Director re-plans the same loop.
  - The same happens when the steps all pass but `task_success` doesn't (e.g. H2's flicker).
  - Result: 20 Sonnet calls per hour, every hour, with no help question.
- **Fix:** a **task-level progress rule**. Every Director decision records `task_success.progress`. If K = 3 consecutive decisions on a task bring neither a progress increase nor a newly done step, the task goes to `waiting_help` with the predicate's detail as the reason. Count empty-queue calls after a zero-gain loop as replans.

### H6. `add_task(now)` while following never starts and says nothing (§2.6 Auto-resume conditions, §2.1 "now preempts")
- **Problem:** `add_task` is not a body action, so the follow continues. The resume and start gate requires `not state.following`, so the task waits forever, silently (principle 7).
- **Fix:**
  - The idle and following gate applies only to **auto-resume after preemption**. A player's `add_task(now)` starts the first `board_step` run at once, and that run's first action replaces the follow, as any action does.
  - `add_task`'s tool result tells the model "queued; I'm following X, it starts when I stop following" whenever it won't start.

### H7. Races and ordering between the worker, chat and runs (§2.3 Threading, §2.4, §8 hooks 1, 2 and 6)
- **(a) Stale results.** A decision computed for a task that was meanwhile cancelled, paused or preempted, or whose step finished, is applied by `tick()`.
  - Fix: every request carries `(task_id, board_version)`. `tick()` applies the result only if they are unchanged, and otherwise discards it (logged and still counted against the budget).
  - At most one outstanding decision. A 5-minute review request is dropped while another decision is pending.
  - Define what a review may replace: the pending steps only, never the active step mid-run.
- **(b) `run_skill` / `start_goal` inside a board run run *after* the predicate check.**
  - `Agent._command` only sets `pending_goal`, and `Agent.step()` runs it after `pump()`, which is where hook 1 calls `director.tick()`.
  - So the run's predicate is evaluated before the skill executes. That counts as "no progress", and `tick()` may start another run first.
  - Fix: either `run_directed` executes a queued `run_skill` before returning (preferred: the run is "done" when its actions are), or StepRunner treats a pending goal as part of the run.
  - With `start_goal` dropped (§6), refuse it in board runs.
- **(c) Other players' chat cuts runs short.**
  - `Agent._player_spoke()` returns True for **any** `ChatHeard`, including friends talking to each other on Shockbyte.
  - Every cut run then counts toward "no progress in 2 runs" and fails the attempt, which spends Sonnet on DEPS.
  - Fix: a run that ended because chat arrived (`chain_stopped why="the player spoke"`) does not count toward no-progress or `max_runs`, just as the executor doesn't count interrupts.
  - Main may also narrow `_player_spoke` to addressed lines (`LiveAgent._addressed_line`).
- **(d) Board tools would interrupt jobs.**
  - `Decision.interrupts` is true for any action not in `NON_INTERRUPTING`, so `add_task` or `pause_board` during a running `run_skill` goal sets `_cancelled`.
  - Hook 3 must add all six board tools to `NON_INTERRUPTING`, and `board` to `read_tools`.
- **(e) Hook 6's interim monkeypatching.** Wrapping `_run_task` per instance and calling the private `_command` across owners is fragile. Ask main for `run_directed` first. It is small, and it also fixes (b).

### H8. Levelling steps fail the no-progress rule (§2.4 no-progress, `predicates._skill` / `_skill_gain`)
- **Problem:** progress is `level / target` only. A level takes many runs, so "progress unchanged in 2 runs" fails every "level X" step. `state.skills[].xp` is reported but unused. The same happens with `near` progress (`within / d`): it jitters, so it never reads as "unchanged" and only `max_runs` ends it.
- **Fix:**
  - (a) `skill` / `skill_gain` progress uses XP when it is present (`xp` since the baseline, against the level span if known, or else "xp increased" as progress).
  - (b) The no-progress rule uses "progress increased by ≥ ε, or a successful body action whose verified result changed state". Positional jitter doesn't count.

### H9. Travel to places he has never seen is an unlisted gap (§2.5 coal and farm-X, §2.7)
- **Problem:**
  - The coal and farm jobs rely on "go to the best known spot" from map memory. Map memory only holds what a ≤ 50 m census showed.
  - On a fresh area, the wiki gives region *names* ("Fellhollow") but no coordinates. `go_to` accepts a player, an id, a place name or `[x, y, z]`, and its `timeout_s` is 120, which is too short for a 4-minute walk.
  - So GOAL T3 (a) and (b) dead-end unless Luis taught a place.
- **Fix:**
  - List "region/world-map positions" (perception) and "long-distance travel" (action) as gaps in §2.5.
  - Seed the gap log with them.
  - Make the Director's documented workaround "ask the player for a place or to lead the way", said once.
  - Check whether game data has region volumes or lodestone positions (a `world_<build>.json`, as in research §5.2) before building anything.

### H10. Self-added prerequisites can repeat and grow without bound (§2.1 "Claude himself", §2.3 Readiness)
- **Problem:** every Director call sees the readiness facts. If an "upgrade armour" prerequisite gets stuck (`waiting_help`) and the parent task becomes current again, the next call re-adds a new "upgrade armour". Prerequisites can also add prerequisites, and each new task gets fresh replan caps.
- **Fix:**
  - Self-added tasks carry `parent`.
  - Cap prerequisite depth at 2 and live self-added tasks at 3 per parent.
  - Show the Director every task on the board *with status and last reason*, cancelled and stuck ones included, so it doesn't repeat them.
  - A duplicate (same `text` + `parent` while a sibling is stuck) is returned to the model as information in the repair round.

### H11. Thread safety of the worker's research tools (§2.3 Threading, Research tools)
- **Problem and fix:**
  - **`learned_skills` crashes.** It reads `SkillLibrary`, whose FTS `sqlite3.connect(":memory:")` uses the default `check_same_thread = True`. A call from the worker raises `ProgrammingError`. `_reindex()` also swaps `_db` on the agent loop while the worker reads.
    - Fix: pass the worker precomputed retrievals (top-k done on the agent loop), or give the library a lock and `check_same_thread = False`. Main owns that file.
  - **MapMemory has two threads.** The agent loop writes it (hook 8) and the worker reads it. Fix: hand the worker an immutable snapshot (`deepcopy` or a frozen dict), never the live object. Do the same for `state`.
  - **The budget and `goals.json` have a hidden second writer.** Record the call timestamp and write `goals.json` only on the agent loop, before dispatch. `state_store._atomic_write` uses a fixed `.tmp` name, so two writers collide.
  - **A hung LLM call freezes the board.** Fix: a per-decision timeout (e.g. 90 s), plus a failure path ("my planning call failed", retried once at the next boundary, voiced if it fails again).
  - **Already safe:** `Knowledge` (it has a lock and `check_same_thread = False`), `JsonlLogger` (it has a lock) and `LiteLLMClient` (stateless).
  - **`SkillLibrary.learn` blocks chat.** Run on the agent loop, it makes a synchronous Sonnet call that stalls chat for several seconds. Run it on the worker too (the same queue, versioned), and count it against the budget explicitly.

### H12. The acceptance plan proves plumbing, not generality (§7)
- **Fix:** add these.
  - **(a) Negative controls** (GOAL §3):
    - a do-nothing Controller;
    - a claims-only Controller (always `report_step(done)` and "done!" speech);
    - a Director that writes trivially-true or weakened predicates (H1).

    All must leave tasks not done.
  - **(b) All five GOAL T3 jobs** as offline scenarios. Coal from a world with no map memory exercises H9. A farm-drop uses the weapon-choice readiness facts. A gear upgrade *on his own initiative* comes under an open task. Each ends in done, or in an honest `waiting_help` with the right gap.
  - **(c) Recorded real-Sonnet decisions** (cassettes) for those five jobs, captured once with the call count stated beforehand, so later code changes replay real model output rather than scripts.
  - **(d) Held-out jobs** come from the Eval agent's generator and are never shown to the implementer. Name these in the plan as must-not-fake cases:
    - the Phase 8 gate "gather 20 logs and 10 stone, then bring them to me";
    - "wait for me at the lodestone";
    - "keep the furnace going".

    Each must end in done with a real predicate, or in a logged perception gap ("can't see what you received"), and never a weak proxy.
  - **(e) The interleavings from H4, H6 and H7:** stop → no resume; an unaddressed friend chat mid-run is not a failure; cancel while Sonnet thinks → the result is discarded.

### M1. Open tasks starve the queue, and `waiting_help` blocks the board (§2.1 "One current task")
- **Problem:** an open task ("level what you like") never ends unless the model says `done`, so "later" tasks behind it never run. It is also unspecified whether a `waiting_help` task blocks the board while Luis is offline.
- **Fix:**
  - Open tasks yield to queued specific tasks at every curriculum boundary.
  - A `waiting_help` task parks, and the next queued task runs.
  - The help question is re-voiced once, when the asked player is next in `players_online` or in range. Don't ask into an empty server.

### M2. Restart and persistence details (§2.1, §2.8, `tools/board.py`)
- **(a) A corrupt or newer-schema `goals.json`.** `StateStore._load_tree`'s pattern raises on load and would stop the brain. Fix: on a validation error, quarantine to `goals.json.bad-<ts>`, start empty, and voice/log it once.
- **(b) A decision in flight at shutdown is lost.** Fix: persist `awaiting_decision: {reason, since}` and re-issue it on start.
- **(c) Windows `os.replace` raises `PermissionError`** while a reader (`tools/board.py list`, AV) has the file open. Fix: retry with backoff, and on persistent failure keep the in-memory board and alarm.
- **(d) The CLI inbox duplicates entries.** "Ingest then crash" re-ingests the same lines. Fix: store the ingested byte offset (or line ids) in `goals.json` in the same atomic write as the new tasks, and parse only newline-terminated lines.
- **(e) Map memory thrashes the disk.** It would write on every `get_state` (~3 per turn). Fix: debounce (e.g. every 30 s, or when it changes), and use atomic writes.

### M3. A step's predicate that is null at activation still runs (§2.2 null, §2.4)
- **Problem:** the note says a null step "is never marked done" and the Director must choose another test. When this is detected is unspecified, so runs and Haiku calls would be spent first. `any[bag ≥ 95 %, have Coal ≥ 99]` evaluates to null whenever `bag.capacity` is unreadable.
- **Fix:**
  - Evaluate every predicate at validation and at activation. A null there goes straight back to the Director (repair round or DEPS) with `missing`, with no runs.
  - Recommend that loop `until` predicates prefer leaves that can't be null, or that `any` with one True branch is still True. Kleene already does the latter; document it for the model.

### M4. Director-declared capability gaps are model claims (§2.7 sources)
- **Problem:**
  - The Director may "need" a primitive the body has under another name. That would pollute the gap log, and the gap log drives the build order.
  - `Reason.CANT_YET` includes `UNKNOWN_SKILL`, so a `run_skill` with an invented skill name would log "run_skill" as a gap.
- **Fix:**
  - Cross-check every `capability_gaps` entry against the manifest and `Capabilities.missing`. If the tool exists, record `source: director_claim, tool_exists: true` and tell the Director in the repair round.
  - Seed the log from `caps.missing` and the `llm = false` tools (equip, unequip).
  - Exclude `UNKNOWN_SKILL` from auto-gaps.

### M5. Budget behaviour and cost estimate (§2.8)
- **(a) What counts.** A "call" must mean **one LLM request** (research rounds and repairs included), not one decision. Re-estimate on that basis: up to 5 requests per decision with growing context is more like $0.05–0.10 per decision. The Haiku side (~13k-token prompts, up to 5 turns per run) is nearer $0.1–0.2/h than $0.05/h.
- **(b) Add a daily cap**, as GOAL §3 requires. Unattended, 20/h is 480 calls a day. Add a kill switch (`DW_DIRECTOR=0` read on every tick).
- **(c) The player waits at an exhausted budget.** When it is exhausted and a *player* is waiting (a new `add_task(now)`, or an answer to a help question), say the wait time once, from the board's facts. Exempt skill-learning calls first, before player-driven ones.
- **(d) Log every call's tokens and cost** to the scoreboard (GOAL §2).

### M6. `killed` needs its own episode feed (§2.2 `killed`, §8 hook 8)
- **Problem:** the broker keeps only `ACTIVITY_KEEP = 8` episodes in memory, and the Director's "interim: observes its own reads" sees no activity events at all.
- **Fix:** a hook in `Agent._activity` (main) that forwards every `Activity` to `director.observe_activity`, plus a persisted per-step counter of matching `combat_end` / `killed` episodes.

### M7. Two task systems stay alive (§6, §8)
- **Problem:** with `start_goal` hidden, `run_skill` still runs through `Agent.run_goal` → `StateStore.set_goal` → `task_tree.json` → `Planner.replan`. That leaves two persisted trees, two DEPS implementations and two replan caps (`max_replans = 2` vs 6), with different restart behaviour. The Director also re-implements `Planner._ask`'s validate-and-repair loop.
- **Fix:**
  - (a) Reuse `Planner._ask`'s pattern. Extract a shared `json_decision(llm, messages, validate, max_repairs)` helper rather than a second copy.
  - (b) State the end state: the Director subsumes the Planner. `run_skill` becomes a step action whose expansion runs inside `run_directed`. `run_goal` and `task_tree.json` are retired once the Director is on.
  - (c) `SkillLibrary.learn` takes `Task`s with `done` status. Convert only the step's *successful body actions*, excluding reads and the brain tools (`remember`, the board tools, `report_step`), or `registry.validate` will reject them.

### H7b (counted under H7). `brain/recipes.py` duplicates `crafting.lua` `plan_tree` / `craft_plan` (§2 file table, §3 "Recipe chaining")
- **Problem:**
  - The client already has a shared-ledger AND-OR tree with alternatives, unlock status and station-near.
  - Above all it has `gather_for` (the ore-rock → item mapping that §10 admits recipes.py lacks). Without it, a Python tree marks raw ores "obtain" instead of "gather".
  - Two planners over two data files (`mod/body/recipe_data.lua` vs `data/recipes_<build>.json`) will drift.
  - Research D4 predates `plan_tree`.
- **Fix:** don't build `RecipeGraph`. Instead:
  - prefetch `craft_plan` on the agent loop (it is a read tool, 0.5 s) into the decision's snapshot when a task becomes current or a craft step fails; or
  - expose it to the Director as a research tool proxied to the agent loop.

  If a brain-side chainer is still wanted for costs (research §5.2), it must replace the Lua one, with golden parity tests, not sit beside it.

### M8. Readiness facts read client-only data (§2.3 Readiness)
- **Problem:** `creature_priors.lua` and learned hit outcomes live in client_mod. The brain has no reader for either.
- **Fix:** either have combat.lua export weaknesses and learned outcomes in a `state_extras` key (the Skills agent), or generate `data/creature_priors.json` beside the Lua table.

  Creature PL is already in census rows (`power_level`). Say so.

### M9. Bag fullness is slot-based (§2.5 coal: "bag ≥ 95 %")
- **Problem:** `bag.used` counts occupied bag slots, so a slot with a partial stack still takes ore.
- **Fix:** tell the Director in `SCHEMA_DOC` that `bag` is slot occupancy. The real "full" signal is a gather result of `inventory_full`, so recommend `until` = `any[bag ≥ 95 %, have X ≥ k]` *and* end the step on an `inventory_full` tool result as a verified outcome. That should be a recorded result, not a model claim.

### M10. Templates as the never-silent fallback conflict with the voice work (§2.6 Never silent)
- **Problem:** companion-quality V asks for "no templates" and "stay quiet while just doing the job", and the voice eval counts stat narration. A milestone template like "trip 3: 61 coal so far", said whenever the model chose silence, is exactly that.
- **Fix:**
  - Templates only for **failures, gaps, help questions and task end**, which principle 7 requires.
  - A milestone the model chose not to voice stays silent, and is logged and available through `board()`.
  - `broker.fallback_line` returns None for the new event types, so the Director's own template must go through `Controller.say` (single voice).

### L1. Stale text in the note
- **Problem:**
  - The status line says "Nothing is built yet", but §2.2 says `predicates.py` is built (659 lines, untracked).
  - §2.2 still says the eval-benchmark file "doesn't exist yet; main to relay", while §9 says "agreed".
  - The note uses `register(name, …)`, the module docstring `register_leaf`.
- **Fix:** reconcile.

### L2. The `killed` match is a substring (`predicates._killed`)
- **Problem:** "goblin" counts "Hobgoblin".
- **Fix:** match on whole words, or on the census `kind` / id family recorded at fight start (`target_id`), and validate `kind` against the census or wiki names, returning candidates.

### L3. Instance stats are ignored (§2.2 `gear_better`)
- **Problem:** CLAUDE.md §0 says items are *instances* (level, ascension, enchants), but the catalog stats are per type, and `inventory.lua` exposes only `enchanted`. An upgrade by ascension or enchant can't pass.
- **Fix:** log it as a perception gap now. Read instance level from the item when the Skills agent can.

### L4. Search record corrections (§3, Search record)
- (a) pyrate-limiter has a file-persistent `SQLiteBucket` (`create_sqlite_bucket`, `init_from_file`), so "neither persists to a file" is wrong. Building 20 lines is still fine, but say why.
- (b) Record a search for JSON rule evaluators (JsonLogic: `json-logic-py`, `python-jsonlogic`; CEL) and for programmatic success checkers (MineDojo tasks, Crafter achievements, PDDL goal conditions). Note why the domain leaves (baselines, tallies, catalog name resolution, three-valued null) justify building.
- (c) The arXiv IDs in the §3 table should be links, as in the Search record.

### L5. Map memory needs negative evidence (§2 `MapMemory`)
- **Problem:** "Both coal spots were mined out" (§1) needs memory of *failure*.
- **Fix:** record `gather` results of `nothing_in_range` / depleted at a position, with time, so `query` ranks those spots down and the help question can cite them truthfully.

---

## Must-fix before build (summary)
H1 immutable and non-trivial success · H2 the `gear_better` false pass · H3 segment baselines and positive tallies · H4 resume may be declined · H5 the task-level no-progress cap · H6 `add_task(now)` while following · H7 versioned results / `run_directed` / chat-cut runs / `NON_INTERRUPTING` / reuse `craft_plan` · H8 XP-based progress · H9 the travel gap · H10 the prerequisite cap · H11 worker thread safety · H12 negative controls, the five T3 jobs, cassettes, held-out must-not-fake jobs.

The M items can land in the first build wave if the note names them.

## Sources checked
- StructAgent: https://arxiv.org/abs/2607.11388
- Mindcraft self-prompter: https://github.com/kolbytn/mindcraft/blob/main/src/agent/self_prompter.js
- pyrate-limiter storage backends: https://pyratelimiter.readthedocs.io/en/stable/modules/pyrate_limiter.limiter_factory.html
- JsonLogic for Python: https://github.com/delta10/json-logic-py · https://pypi.org/project/python-jsonlogic
