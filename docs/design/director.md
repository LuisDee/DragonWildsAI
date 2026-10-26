# Director and task board: long-horizon jobs ("get better gear, level skills of your choice")

Status: **design, revision 2**, after the fresh-context review `docs/reviews/2026-10-25-director-review.md` (approve with changes). Author: the Director agent. Scope: autonomy-plan.md §4 and §5 steps 2–3; Luis's scope additions via main; GOAL.md milestone **M3**.
- **Built:** wave 1, `brain/predicates.py` + `tests/test_predicates.py` (shared with the Eval agent). It includes the review's H2, H8 and L2 code fixes.
- **Built since:** wave 2 (board, store, gap log, CLI), wave 3 (Director worker, StepRunner, research, `llm_json`, knowledge memory; hooks applied by the event-hygiene agent), wave 4 (`brain/mock/gear_world.py` + `tests/test_director_jobs.py`: the five T3 jobs and the must-not-fake jobs end to end with the real Agent and Controller). Next: (5) cassettes of real Sonnet decisions (call count stated first). Live only after `DW_DIRECTOR=1` is turned on by main.
- **Prompt risk seen in wave 4:** a step-level `gear_better than=start` compares with the step's own start (after crafting), so an "equip it" step written that way can never pass. Its detail says so ("Bronze 3 vs Bronze 3") and DEPS replans. The Director's rules now say what "start"/"gained"/"lost"/"elapsed" mean in a step vs the job's test. To check with the cassettes.
- **Review resolution:** every H/M/L finding maps to a section in §11.

## 1. Goal (what Luis will see)
- **A task board.** A player says "go gather coal", "farm desert weed at our farm", "get a better pickaxe" or "level up skills of your choice". Main can queue tasks from a CLI (`tools/board.py add/list/cancel/gaps`).
  - Each becomes a board entry, and Claude says what he'll do first, what "done" will mean, and why.
  - "What are you up to?" is answered from the board: the current task, its step, its progress and the queue.
- **He works it out himself.** He researches (game data first, then the wiki, plus his own map and knowledge memory), plans steps, and runs them for hours. He loops trips when his bag fills, replans when a step fails, and adds his own prerequisite tasks (a gear upgrade when he's under-geared for the target).
- **Milestones, not a timer.** He voices a milestone only when the model chooses to. Failures, gaps, help questions and task ends are always said.
- **Interruptible.** A player's request is answered and done at once. The board resumes when he's idle again, unless the model decides the player wanted him to stop, wait or stay.
- **Honest about gaps.** A plan that needs a primitive the body lacks says so plainly once, with the workaround, and logs it. That log drives the next primitives we build.
- **Asks for help once.** When he's stuck after his own replans, he asks once and specifically, citing what he tried. He doesn't ask into an empty server.

## 2. Approach: layers and files
Three loops at three speeds (autonomy-plan §4):
- Lua reflexes, at frame rate;
- the Haiku Controller, on events, one step at a time;
- the **Sonnet Director**, at step boundaries only.

The board and the Director are brain-side, and act only through the Controller's normal tools.

| File | What it owns |
|---|---|
| `brain/predicates.py` (**built**) | The success-predicate format shared with the Eval benchmark (§2.2): `validate`, `errors`, `evaluate → Result(passed True\|False\|None, detail, progress, missing, measures)`, `grew`, `snapshot`, `describe`, `register`. Pure. |
| `brain/board.py` | Task, step and segment models and `BoardStore` (`<state>/worlds/<w>/goals.json`). The agent loop is the only writer: atomic writes with a unique temp name, a Windows retry/backoff, and quarantine of a bad file. Also the CLI inbox (`board_inbox.jsonl`, an offset-tracked ingest) and tallies. |
| `brain/capability_gaps.py` | `GapLog` (`logs/state/capability_gaps.json`, §2.7). |
| `brain/knowledge_memory.py` | `KnowledgeMemory` (per world): facts with source, confidence, build and a refuted flag (§2.11). `Efficiency`: best rates plus the `efficiency.jsonl` trend log (§2.10). |
| (shared) map/resource memory | **Owned by the capability agent** (live bug L21: water, food, stations, lodestones, graves). One per-world store: it writes from the census, the Director only reads it through a pure `query` / `snapshot` API, plus negative evidence (§2.12). No `brain/map_memory.py` of mine. |
| `brain/llm_json.py` | `json_decision(llm, messages, validate, max_repairs, tools?, on_call)`: the validate-and-repair loop extracted from `Planner._ask` (review M7a). The Director uses it; main may switch the Planner to it. |
| `brain/director.py` | `Director` (the decision worker: Sonnet, research tools, curriculum, DEPS, prep, reflection, caps), `StepRunner` (the executor bridge), the board tools for the Controller, and `HourlyWindow` (with the daily cap from `brain/budget.py`). |
| `tools/board.py` | CLI: `add "<text>" [--first]`, `list`, `cancel <id>`, `gaps`. It appends to the inbox and only reads `goals.json` and the gap log. |
| `brain/mock/gear_world.py` | `GearWorld(MockGame)`, driven by the real catalogs: item ids, recipe inputs/outputs/stations, tiers, recipe XP. It has ore rocks, a Furnace, a Blacksmith's Bench, creatures with PL and drops, `bag` slots, `stations_nearby`, `skills` with XP, `activity` episodes, a `craft_plan` read tool that replays the client's `plan_tree` shape (from a recorded fixture), and toggles to remove primitives. |
| `tests/test_director.py` | §7. |

**Not built** (review H7b): no `brain/recipes.py`. The Director reaches the client's own planner (`craft_plan`, `recipes`, `stations`, in `crafting.lua` `plan_tree`, which has `gather_for`, unlocks and station-near) through a **proxied read tool** (§2.3). There is then one planner over one data file.

No edits to `agent.py`, `controller.py`, `broker.py`, `run_live.py` or `client_mod/` (other owners). Their hooks are in §8, sent to main as an exact diff.

### 2.1 The board (`goals.json`, survives restarts)
```
{v:1, version:<int, bumped on every change>, current:<task id>|null, inbox_offset:<bytes>,
 awaiting_decision: null|{task_id, reason, since},
 budget:{calls:[ts...]},
 tasks:[{id, text, by: player:<name>|cli|self, parent?, depth, because?, kind: specific|open,
         status: queued|active|preempted|paused|parked|waiting_help|waiting_budget|done|stuck|cancelled,
         paused_by?, success:{predicate, set_at, set_by: director|player, trivial?}|null, baseline,
         tallies:{item: n}, my_drops:[world item ids], kills:{kind: n}, created, ended,
         steps:[{id, title, why, hints, success, abort_if?, escape?, risk?, needs:[primitive], group?, trivial?,
                 status: pending|active|done|failed|aborted|dropped, attempts, max_attempts:2, runs, max_runs:8,
                 segments:[{baseline, start, end?, delta?}], accumulated:{item: n}, last_measures,
                 failures:[{reason, detail, explanation, at}], actions:[{tool, args, ok, reason, data}], started, ended}],
         loops:{<group>: {until: predicate, max:20, done:n, zero_gain:n}},
         replans, decisions_without_progress, history:[{title, outcome, seconds, reason}], notes_from_player:[...],
         help:{question, asked_at, asked_player, revoice_pending}?}]}
```

**Who adds tasks**
- A player, through the Controller tool `add_task(text, when: now|next|later)`. The model understands the line; there are no phrase tables.
- Main, through the CLI inbox. Ingest stores `inbox_offset` in the same atomic write as the new tasks, and parses only newline-terminated lines (M2d).
- Claude himself, through the Director's `add_tasks`, with `parent`, `because` and depth ≤ 2. A parent may have at most 3 live self-added tasks. A duplicate (same text and parent while a sibling is stuck) goes back to the model as information (H10).

**Order**
- One task is current; the others queue.
- `now` preempts the current task, which keeps its state and goes back to the queue head.
- `add_task(now)` starts its first run at once, even while following (that run's first action replaces the follow, as any action does). The tool result says when it won't start at once, e.g. waiting for a decision or out of budget (H6).
- An **open** task yields to queued specific tasks at every curriculum boundary.
- A `waiting_help` task **parks**, and the next queued task runs (M1).

**Success: immutable, never trivial (H1)**
- `task.success` is set by the task's first decision and is **never changed by later decisions**. Only a player's new instruction can change it: the Controller calls `add_task` / `cancel_task`, and the change is logged and voiced.
- Every new predicate (task or step) is evaluated on the current state at validation:
  - **already true** → the repair round gets "already true now: choose a test that measures the work" as information. If the model keeps it, it is stored `trivial: true` and shown so in `board()` and the benchmark.
  - **null** → it goes back for repair with `missing`. No run is spent on it (M3).
- A player-given task's first run carries `success` in words, so Luis hears what "done" will mean.

**Steps, segments and tallies (H3)**
- A step's work is a list of **segments**. Activating or resuming a step opens a segment with a fresh baseline. Preemption closes the segment and folds its positive deltas into `accumulated`.
- `gained` and the tally use `accumulated` + the open segment. So whatever happens during a player's command (he gives Luis 10 coal; Luis hands him ore) never counts for the step.
- **Tallies** count **positive** deltas only, per item, and only for items named in the task's or its loops' predicates.
- **Own drops don't count twice.** World-item ids from his own `drop` results in this task are kept in `my_drops`. A later `picked_up` episode or pickup result naming one of them is subtracted, so a "drop at base" round trip can't inflate the tally.
- Gains from a player (`items_dropped` by another player, then picked up) are kept but flagged in the tally detail.
- **Kills** for `killed` come from activity forwarded on the agent loop (M6). They are counted per step and persisted with the step.

**Loops (trips)**
- A step may belong to a `group` with `until`. When the group's last step is done and `until` still fails, code re-queues the group (fresh segments, no Sonnet call).
- Caps: 20 loops. After 2 loops with zero tally gain, the loop ends, and that **counts as a replan** (H5).
- For "bag full", the step also ends on a gather result of `inventory_full`, which is a recorded body outcome (M9).

**Task-level progress rule (H5)**
- Every Director decision records `success.progress` and `measures`.
- After K = 3 consecutive decisions on a task with no increase in either, and no newly done step, the task goes to `waiting_help`. The reason is the predicate's detail.

### 2.2 Success predicates (built: `brain/predicates.py`; shared with the benchmark, `docs/design/eval-benchmark.md` §4)
Each leaf reads only fields the body already reports, plus catalogs and per-world memory. Every result says `passed` true, false or **null** ("can't be checked from what the body reports"). Null never counts as done.

| Leaf | Reads |
|---|---|
| `have {item, at_least}` | `inventory` |
| `gained {item, at_least}` | `inventory` vs the step's segments |
| `lost {item, at_least}` | `inventory` vs the baseline |
| `tally {item, at_least}` | the task's verified tallies |
| `on_ground {item, at_least, player\|place\|position, within_m}` | `nearby_items` (a delivery = `all[lost, on_ground near the player]`; out of sight = null) |
| `skill {name, at_least}` / `skill_gain {name, levels}` | `skills[{skill, level, xp}]`; XP is the measure (H8) |
| `equipped {item}` | `gear` (worn or held now; tools flicker) |
| `gear_better {category\|slot, stat, where, than, op}` | catalog stats. `than: "start"` = the best he had **held or carried** at the baseline (H2); for tools use `where: carried` |
| `bag {used_pct_at_least\|free_at_least}` | `bag` slots (slot occupancy, M9) |
| `vital {stat, below_pct\|at_least_pct}` | `health`/`max_health`, `<stat>`/`<stat>_max` |
| `near {place\|player\|position\|thing, within_m}` | `position`, `players`, census rows; places from `places.json` |
| `moved {min_m}` | position vs the baseline |
| `elapsed {seconds}` | the baseline's `t` vs now |
| `station {station, running?}` | `stations_nearby` |
| `killed {kind\|kind_id\|target_id, at_least}` | forwarded `combat_end` episodes; whole-word name match (L2); `kind_id` needs `target_class` in combat_end (null until the combat agent adds it) |
| `quest {name, stage\|completed}` | `quests`: **null today** (a perception gap) |

- **Combinators:** `all`, `any`, `not`, with Kleene logic: `any` is true when one branch is true, even if others are null.
- **Extension:** the benchmark adds its own leaves (`spell_effect`, `station_used`, `hit_rate`, …) through `register()`, with no edits to the module.
- **`measures`** (counts, XP, kills; never distances) feed the no-progress rules through `grew()`.
- **Gaps today, logged and never faked:** Luis's inventory (what he received), crop/structure state, container contents, instance stats (item level, ascension, enchant; L3).

### 2.3 Director decisions (Sonnet via `planner_llm`)
**When a decision is made** (at most one outstanding):
- a task becomes current;
- the step queue is empty and no loop was re-queued;
- a step attempt failed or aborted (DEPS);
- a risky step is next (prepare, §2.9);
- a loop's rate fell (reflect, §2.10);
- a player answered a help question.
- Plus a 5-minute review while a step runs, only if at least half of the hour's window is left and no other decision is pending. A review may replace only *pending* steps, never the active one.

**Versioning (H7a).** Each request carries `(task_id, board_version)`. `tick()` applies the result only if neither changed. Otherwise the result is discarded: it is logged, and still counted against the budget.

**Threading (H11)**
- The decision runs on one worker thread, on an **immutable snapshot**: the state, a map-memory snapshot, top-k learned skills retrieved on the agent loop, the board view, gaps and known facts.
- The worker never writes files and never touches the bridge. Only the agent loop records call timestamps and writes `goals.json`.
- `Knowledge` is thread-safe and is used directly (it has a lock and `check_same_thread = False`).
- Each decision has a 90 s timeout. On failure or timeout: one retry at the next boundary. If that fails too, the Controller says "my planning call failed" once, and the task waits.

**Prompt**
- Cached prefix: the persona, the output schema, `predicates.SCHEMA_DOC`, and the body's real tool list (manifest names and descriptions).
- Then:
  - the task, and every board task with its status and last reason (cancelled and stuck ones included: H10);
  - the step tree, `history`, and a compact state (skills with XP, gear with stats, PL, inventory, bag, vitals, where);
  - map and knowledge memory summaries, top-3 learned skills, known gaps, readiness/curriculum facts, and the `facts` ledger (§2.11).

**Research tools** (read-only):
- `recall` (knowledge memory) and `map_memory` (snapshot);
- `lookup` (knowledge.py: game docs first, then the wiki);
- `compare_gear` (item_stats over the catalog);
- `skills_progress`;
- the **proxied body reads** `craft_plan`, `recipes` and `stations`. The worker posts the request, the agent loop serves it inside `tick()` (between runs, when the bridge is free), and it times out after 20 s with "body busy". This reuses the Lua planner (H7b).

A decision gets at most 4 LLM rounds plus 1 repair round. Each round is **one counted call** (M5a).

**Output** (validated by `json_decision`):
```
{description, explanation, facts:[{fact, for_step, status, source, confidence}],
 task_success? (first decision only), steps:[{title, why, hints, success, risk?, abort_if?, escape?, needs?, group?}],
 loops?, add_tasks?:[{text, because, when}], capability_gaps?:[{primitive, why, workaround?}], ask_help?, done?}
```
- `steps` replaces the pending queue.
- `done` ends an *open* task; a specific task ends only when its immutable `success` passes on fresh state.

**Readiness facts** (information only):
- His PL (catalog power levels of what he wears and holds).
- The creature PL from census rows (`power_level`).
- Region PL, once the region data exists (§2.12).
- Creature weaknesses: the brain can't read `creature_priors.lua` today (M8). The Skills agent is asked for a `state_extras` export or a generated `data/creature_priors.json`. Until then this is "unknown", and a `lookup` candidate.
- Weapons and enchants by damage type (catalog `damage_types`, spells data); food and drink carried.

**Curriculum (Voyager), for open tasks.** Code supplies facts only:
- gear upgrade options with `craft_plan` status;
- skills with XP and the recipes that award XP;
- what he can make now;
- the completed/failed history.

**DEPS** on failure: describe (the real tool results, the predicate detail, the `report_step` reason) → explain → revise, add a prerequisite task, or `ask_help`. Caps: 2 attempts per step, 6 replans per task. Past either, or past the task-level progress rule, the task goes to `waiting_help`.

### 2.4 Executor bridge (`StepRunner`; needs `Agent.run_directed`, §8)
**Activate a step:**
- evaluate its predicate (null → back to the Director, no runs);
- open a segment;
- `attempts += 1`.

**One run** = `agent.run_directed(event)`: one body-initiated Controller request, with the agent loop's continuation turns. Any `run_skill` it queues is **executed inside the run before it returns** (H7b). `start_goal` is not offered while the Director is on.

The `board_step` event carries:
- the task;
- the step's title, why and hints, plus `escape` (if any);
- the predicate in words with its current detail;
- run n of max;
- the last run's results;
- learned skills for the step;
- `resumed` and `preempted_by` (§2.6);
- `just_completed` (verified facts of the previous step or loop).

`run_directed` returns the action records (tool, args, ok, reason, data) and why the run ended.

**After each run** (fresh state):
- `abort_if` holds → `aborted` (§2.9).
- The predicate passed → done; tallies and the segment are folded in.
- `report_step(blocked, reason)` → the attempt fails.
- `report_step(done)` → only an immediate check. If it fails, the next run is told the detail.

**No-progress rule (H7c, H8).** The run counts toward "2 runs without progress" only if it ended normally and:
- no measure grew (`grew`);
- no body action succeeded with a verified state change.

A run that ended because chat arrived (`chain_stopped why="the player spoke"`) never counts, and neither do interrupts. The same holds for `max_runs`.

**Capability gaps from tools.** Tool results with `not_implemented` or `unknown_tool` (not `unknown_skill`: M4) are recorded as gaps.

**Skill library.** A done step with ≥ 2 verified **body** actions goes to `SkillLibrary.learn`. It is converted to `Task`s from the step's successful body actions only (not reads, `remember`, board tools or `report_step`: M7c).
- It runs on the worker with **its own `SkillLibrary` instance** over the same directory (its own SQLite). The agent loop's library `load()`s when the result is applied (H11).
- It runs only if at least 30 % of the hour's window is left. It is the first thing to be skipped when budget is short (M5c).

### 2.5 How the requested jobs fall out generically
No job has code of its own.

| Job | Research | Steps, predicates and loops | Gaps today |
|---|---|---|---|
| **gather coal** | `recall`/`lookup coal` (game data: no recipe, vendor; wiki: coal nodes and regions); `map_memory item=coal` (incl. depleted spots), `kind=lodestone`, regions | go to a known spot (`near`) → mine until `any[bag ≥ 95 %, have Coal ≥ 99]` or `inventory_full` → go home → deposit → loop until `tally Coal ≥ N` | region coordinates (until §2.12 data), long-distance travel (`go_to` timeout 120 s), lodestone teleport, storage deposit. Workarounds: ask the player for a place or to lead the way (said once); drop at base (tracked by `my_drops`) |
| **farm X from mob Y** | `lookup X` (drop table) → `lookup Y` (habitat) → `map_memory creature=Y` → readiness (PL, weakness, weapons, food) | prepare (§2.9) → go to Y's area → hunt until `any[bag full, have X ≥ k]` (with `killed` as progress) → home → deposit → loop on `tally X` | weaknesses (M8), ranged aim (if chosen), deposit |
| **all Brynmoor quests** | `lookup` (wiki quest steps and prerequisites) | one task per quest via `add_tasks`; `quest` predicates are null | quest-state perception and quest dialogue: logged, said once, the task parks with an honest question |
| **gear progression** (his own initiative) | readiness facts on every decision | under an open task, or as a prerequisite: "upgrade <slot>" tasks with `gear_better` | instance stats (L3) |
| **farm desert weed at our farm** | `places.json` ("our farm", taught with `remember`), `lookup` seeds | go to place → plant → `elapsed` → harvest → loop | plant/harvest primitives, crop state |
| **get a better pickaxe** | `compare_gear category=pickaxe`, proxied `craft_plan` | mine → smelt (`station running`, `have bars`) → craft → task success `gear_better{pickaxe, tool_tier, carried, start}` | equip is `llm=false` on the client ("not yet verified") |

### 2.6 Preemption, pause, resume, reports
**Preemption.** A chat-originated command that runs actions closes the step's segment, and the board goes to `preempted`. Board tools never preempt: they are in `NON_INTERRUPTING` (H7d).

**Auto-resume** (Mindcraft `self_prompter`) is allowed when all of these hold:
- no player command for 30 s;
- no brain action running;
- not following;
- no chat pending.

It does not decide by itself (H4). The resume run is a normal Controller run whose event carries `resumed: true`, `preempted_by` (the command and its tools), the recent chat, and `paused_by: player` when the preempting tool was `stop`. Its instructions say: "If the player told you to stop, wait or stay, call `pause_board` instead of working". The model may decline. This gate applies **only** to auto-resume, never to a new `add_task(now)` (H6).

**Tools:** `pause_board(reason)` (until `resume_board`), `resume_board(note)` (a player's answer reaches the next decision), `cancel_task(id, reason)`, `board()` (read).

**Help (M1).** The help question is said once. If the asked player isn't in `players_online` or in range, it is said when he next appears (once). The task parks meanwhile.

**Speech (M10)**
- Milestone facts ride in `just_completed`, and the model voices them only if it chooses to. A silent milestone stays silent, and is logged and visible in `board()`.
- Templates are used **only** for failures, gaps, help questions, budget waits and task ends (principle 7), through `Controller.say` (single voice).

### 2.7 Capability-gap log (`logs/state/capability_gaps.json`, all worlds)
- **Record:** `{primitive, kind: action|perception, count, first_seen, last_seen, examples:[{task, step, why, workaround}], sources, tool_exists?}`.
- **Sources:**
  - tool results `not_implemented` / `unknown_tool`;
  - predicates that evaluate null (perception gaps, e.g. `quests`, `nearby_items` for a delivery out of sight);
  - **seeded** from `caps.missing` and the manifest's `llm = false` tools (equip, unequip), plus the travel gaps of §2.5 (H9);
  - the Director's `capability_gaps`, **cross-checked against the manifest** (M4). A primitive the body has is recorded as `source: director_claim, tool_exists: true`, not counted as a gap, and the Director is told in the repair round.
- **Voicing:** each new gap for a task is voiced once (a `capability_gap` event, Controller voice, template fallback).
- **Reading:** `tools/board.py gaps` sorts the gaps by count.

### 2.8 Budget (M5)
- **Hourly window:** one **call = one LLM request** (research rounds, repairs, prepare, reflect and skill learning included). `HourlyWindow(per_hour = DW_DIRECTOR_CALLS_PER_HOUR, default 20)` is a sliding window persisted in `goals.json`.
- **Daily cap:** `brain/budget.py` `Budget.allows("director")`, the shared $10/day cap from `spend_today()` (GOAL §3, commit 7ae4e23). At 100 % the Director stops: the board keeps running loops and learned skills (no Sonnet), and a help wait says so once.
- **Kill switch:** `DW_DIRECTOR=0`, read on every tick.
- **Priority when budget is short:** player-driven decisions (a new `add_task`, a help answer) first, then failures, then curriculum, reviews and reflection. Skill learning is the first thing dropped.
- **A waiting player** hears the wait time once, computed from the window.
- **Logging:** every call logs its usage with `component: "director"`, so `tools.spend` attributes it (`director_planner`).
- **Estimate** (research doc §6.7 prices):
  - a request is ~8–12k tokens in (≈ 3–4k cached) + ~0.8k out ≈ $0.02–0.03, so a decision of 1–5 requests ≈ $0.03–0.10;
  - 20 requests/h ≈ **$0.5/h**, plus Haiku runs ≈ $0.1–0.2/h (~13k-token prompts, up to 5 turns);
  - a 10-hour unattended day is ~$6–7. The daily cap still binds.

### 2.9 Preparation before risky steps
- **When:** the Director marks a step `risk: fight | trip`. Before such a step activates, if the steps before it aren't already its prep, a **prepare** decision runs (budget-gated).
- **Its facts:**
  - his PL vs the target's or region's;
  - weaknesses and resistances (M8: "unknown" until exported);
  - his weapons and enchant spells by damage type;
  - armour, castable buffs, food and drink;
  - the way back (lodestones, places, bed or shelter).

  These come from the body's `combat_brief` once it reports one, else brain-side.
- **The model chooses.** It may insert prep steps (swap gear, cast the matching enchant, move food to the hotbar, craft potions), attach `escape` hints and an `abort_if` predicate (e.g. `any[vital{health below_pct 30}, not have{food}]`), or decide no prep is needed.
- **Abort:** after each run, `abort_if` is checked on fresh state. If it holds, the step goes to `aborted`, the next run carries out the escape hints, and then DEPS follows. Reflexes still own in-fight defence.

### 2.10 Efficiency reflection
- **Rates:** at each step or loop end, the verified rate (items/min from tallies, XP/min from skill XP) is computed per key (item or skill, plus spot). The best rate seen per key is kept.
- **Alternatives offered** (from data):
  - castable spells with their own `use_when` text;
  - other known spots (map memory) with travel estimates;
  - lodestones;
  - better tools (`compare_gear`).

  Code never decides which helps.
- **When:** a **reflect** decision runs at a loop end when the rate fell below 70 % of the best for the key, or every 3 loops (budget-gated). Otherwise the facts ride along in the next decision.
- **Trend log:** each reflection appends `{ts, task, step, key, rate, best, alternatives_offered, change}` to `logs/state/worlds/<w>/efficiency.jsonl`, for the benchmark's optimisation-trend score.

### 2.11 Knowledge-gap check (when to use the wiki)
- **Each plan states its facts:** `{fact, for_step, status: known|unknown, source: game_data|perception|memory|wiki, confidence}`.
- **Unknowns get one nudge.** If facts are unknown and rounds are left, the loop answers once: "These facts are unknown: look them up, or say why the plan doesn't need them". Information, not a veto.
- **Order:** `recall` → game data (`craft_plan`, `compare_gear`, map memory) → `lookup` (game docs, then wiki).
- **The cache.** `KnowledgeMemory` stores `{key, value, source, confidence, ts, build, refuted?}`:
  - game data and in-game observation are `high` and override the wiki;
  - a wiki fact refuted in game (e.g. no coal where it said) is marked refuted (DECKARD).
- **Lookup logging:** each lookup is logged `needed: true|false` (did it match a listed unknown fact?), so the benchmark can score needed vs needless lookups.

### 2.12 Map memory and static map data (H9, L5, M2e): the capability agent's shared store; the Director reads
- **Sightings:** what a `get_state` showed (stations, resource nodes by item, creatures with PL, lodestones, chests, beds), each with position, count and last seen.
- **Negative evidence:** `gather` results of `nothing_in_range` or depleted at a position, with the time. These spots rank lower, and the help question can cite them truthfully.
- **Writes** are debounced: every 30 s, or on change.
- **Static map data already exists in the game** (DISCOVERIES "Lodestones, map regions and travel"):
  - 31 `BP_MapRegion_C` actors (RegionName, PowerLevel, BoundarySpline);
  - `AGameplayObjectRegistry.Lodestones` (Location, Identifier);
  - 558 landmarks.

  A generated `data/regions_<build>.json` (requested from the capability agent: a read-only dump, like the recipe dump) gives region positions and PL for "go to Coalridge Pass". `BP_MapRegion_C` was read **on the server**, so the dump comes from a one-off **dev-server** run (the dev world is the test and scoring world, GOAL §1b). A client-side read is the fallback if the regions turn out to be on the client too. Until then "region positions" and "long-distance travel" are seeded gaps.

## 3. Precedent
| Need | Found | Decision |
|---|---|---|
| Director/Controller split | [PIANO](https://arxiv.org/abs/2411.00114) concurrent modules; [GITM](https://github.com/OpenGVLab/GITM) goal → sub-goals → actions; [HiMAC](https://arxiv.org/abs/2603.00977); [Odyssey](https://arxiv.org/abs/2407.15325) planner-actor-critic | **adapt**: our Controller is the actor, the Director the planner |
| Task tree + working memory | [ReAcTree](https://arxiv.org/abs/2511.02424): agent node per subgoal, control-flow nodes, working and episodic memory | **adapt**: board → steps with loop groups; map/knowledge memory = working memory; skill library = episodic memory |
| Verified subgoals | [Voyager](https://arxiv.org/abs/2305.16291) self-verification; [StructAgent](https://arxiv.org/abs/2607.11388) verifier-backed transitions, (VERB, ITEM, n) inventory checks; [dual memory](https://arxiv.org/abs/2604.02734) symbolic checks; [MineDojo](https://docs.minedojo.org/sections/customization/task.html) programmatic tasks (all targets must hold); [Crafter](https://pypi.org/project/crafter) achievements | **build** the domain DSL: three-valued null, baselines/segments, tallies, catalog name resolution and measures have no counterpart in JsonLogic/CEL |
| Rule evaluators | [JsonLogic](https://github.com/delta10/json-logic-py) (2017 port, two-valued), [python-jsonlogic](https://pypi.org/project/python-jsonlogic) (typed); CEL ([cel-python](https://github.com/cloud-custodian/cel-python), cloud-custodian) | **not adopted**: our leaves are domain functions, and the combinator layer is ~15 lines |
| Curriculum | Voyager; [OMNI](https://arxiv.org/abs/2306.01711) | **adapt** Voyager's inputs; code gives facts, the model picks |
| Replanning | [DEPS](https://arxiv.org/abs/2302.01560); [Metagent-P](https://preview.aclanthology.org/new-sigs/2025.findings-acl.1169/) | **reuse** the Planner's DEPS pattern through `json_decision`. The caps are ours (no source sets one) |
| Self-directed loop | [Mindcraft self_prompter](https://github.com/kolbytn/mindcraft/blob/main/src/agent/self_prompter.js): ACTIVE/PAUSED/STOPPED, restart after 2 s idle; [MineCollab](https://arxiv.org/abs/2504.17950) | **adapt**, with a resume the model may decline (H4) |
| Recipe chaining | `crafting.lua` `plan_tree` (ours, live data, `gather_for`) | **reuse** through the proxied `craft_plan` (H7b) |
| Board persistence | [py_trees](https://pypi.org/project/py-trees/), [Dendron](https://pypi.org/project/dendron/): no persisted resume; LangGraph checkpoints (rejected in D1) | **build**: pydantic + atomic JSON |
| Hourly window | [limits](https://limits.readthedocs.io/) (moving window; no file store); [pyrate-limiter](https://pyratelimiter.readthedocs.io/en/stable/modules/pyrate_limiter.limiter_factory.html) **does** persist (`SQLiteBucket`) | **build** ~20 lines: the timestamps already live in `goals.json`'s single atomic write, so a second store (SQLite) would split board state across two files. The daily cap **reuses** `brain/budget.py` |

## Search record
Queries (2026-10-25):
- "LLM agent open-ended game long-horizon goal tree curriculum 2026 arXiv Minecraft"
- "ReAcTree hierarchical LLM agent tree subgoal working memory"
- "Mindcraft self-guided play self_prompt"
- "2026 arXiv LLM agent automatic curriculum open-ended embodied goal feasibility"
- "LLM game agent hierarchical planner executor long-horizon 2026 Minecraft subgoal verification replanning budget"
- "Python library persistent goal tree task tree LLM agent behavior tree py_trees resume"
- "pyrate-limiter sliding window rate limit python persistent per hour"
- "JsonLogic python json-logic-py evaluate rules CEL common expression language python"
- "MineDojo programmatic tasks success criteria inventory check Crafter achievements success"

Found nothing for: a persisted/resumable LLM goal-tree library; a published replan cap; (CEL does have a Python evaluator, cel-python; corrected in the re-check.)

Sources:
- https://arxiv.org/abs/2305.16291 · https://arxiv.org/abs/2302.01560 · https://github.com/OpenGVLab/GITM · https://arxiv.org/abs/2411.00114
- https://arxiv.org/abs/2511.02424 · https://github.com/kolbytn/mindcraft/blob/main/src/agent/self_prompter.js · https://arxiv.org/abs/2504.17950
- https://arxiv.org/abs/2607.11388 · https://arxiv.org/abs/2604.02734 · https://arxiv.org/abs/2603.00977 · https://arxiv.org/abs/2407.15325
- https://preview.aclanthology.org/new-sigs/2025.findings-acl.1169/ · https://arxiv.org/abs/2306.01711
- https://pypi.org/project/py-trees/ · https://pypi.org/project/dendron/
- https://limits.readthedocs.io/ · https://pyratelimiter.readthedocs.io/en/stable/modules/pyrate_limiter.limiter_factory.html
- https://github.com/delta10/json-logic-py · https://pypi.org/project/python-jsonlogic
- https://docs.minedojo.org/sections/customization/task.html · https://pypi.org/project/crafter

## 4. Generality check
- **No names in code.** No item, creature, station, skill, quest, region or place names. These come from `data/*_<build>.json`, `state`, map/knowledge memory, `places.json`, the wiki and the client's planner. The held-out jobs (§7) run through the same code.
- **No example lines in prompts.** The example lines in this note never go into brain/ prompt strings (`tests/test_overfit.py`).
- **Language is the model's job.** The Controller decides whether a line adds, pauses, cancels or declines a resume. Code never reads the player's words.
- **What code decides:**
  - whether a predicate passed, failed or can't be checked;
  - segment and tally accounting;
  - re-queueing a loop while its own `until` fails;
  - the caps (attempts, replans, task-level progress, loops, prerequisite depth and count);
  - the hourly window and daily cap (Luis's cost rule);
  - when an auto-resume *run* is offered (the model may decline it).

  It never changes the model's steps or predicates. Exceptions: `task.success` is immutable (H1, verification integrity), and invalid or trivial predicates go back to the model as information.

## 5. Principles touched
- **Central:** #5 (immutable, non-trivial, code-evaluated success; segments), #7 (failures, gaps and help always said), #8 (map/knowledge memory, skills, gaps).
- **#6 single voice: kept.** The Director never speaks.
- **#2:** no vetoes. The resume run lets the model honour "stop" (H4). Trivial predicates are information.
- **Luis's OK:** the budget defaults (20 requests/h, inside the $10/day cap) before the first long live run.

## 6. The Planner and `start_goal` (M7, main's decision)
- **Who runs them:** the Director subsumes the Planner.
- **When:** while the Director is on, `start_goal` is hidden, after a ≤ 15-call Haiku eval (stated before running) that shows `add_task` gets chosen for multi-step jobs.
- **How `run_skill` runs:** it becomes a step action, and its expansion runs inside `run_directed`.
- **What is retired:** `Agent.run_goal`, `task_tree.json` and `Planner.replan`, once the Director is on live.
- **Shared code:** `json_decision` (in `brain/llm_json.py`) replaces the copy of `Planner._ask`.

## 7. Acceptance tests (offline: GearWorld + FakeLLM; cassettes later)
1. **"get a better pickaxe"** (ladder 1, a player task): proxied `craft_plan` → mine → smelt (`station`) → craft → task success `gear_better` (tier 1 → 3). The H2 sequence (a held sword at the start, then switching to the Stone Pickaxe) is **not** done.
2. **Failure → replan → help:** no tin. The Controller reports blocked → DEPS to a remembered place → fails again → caps → one specific help question citing the depleted spots (negative evidence) → the task parks, and the next queued task runs. `resume_board(note)` reaches the Director.
3. **The five GOAL T3 jobs** (H12b), each ending done or in an honest `waiting_help` with the right gap:
   - coal: a world with no map memory, so travel and region gaps plus the ask-to-lead workaround; then a world with a known spot → 3 trips → `tally`;
   - farm-drop: prepare uses the readiness facts, plus `abort_if` on a vital;
   - a quest: null predicate → perception gap → parked, with an honest question;
   - gear progression under an open task, on his own initiative (a self-added prerequisite);
   - desert weed: a place from `places.json` → plant gap → said once.
4. **Negative controls** (H12a): a do-nothing Controller; a claims-only Controller (always `report_step(done)` plus "done!"); a Director writing trivially-true or weakened predicates (flagged `trivial`; a weakened `task.success` is rejected as immutable). All leave tasks not done.
5. **Must-not-fake held-out jobs** (H12d; the Eval agent's generator holds the real held-out set): "gather 20 logs and 10 stone, then bring them to me" (`lost` + `on_ground` near the player, null when he's out of sight); "wait for me at the lodestone" (`near` + `elapsed`); "keep the furnace going" (`station running`). Each ends done with a real predicate, or with a logged perception gap.
6. **Interleavings** (H12e):
   - "stop" → 30 s → the resume run's model calls `pause_board` → no movement;
   - an unaddressed friend's chat mid-run doesn't count as no-progress;
   - cancel while Sonnet thinks → the stale result is discarded;
   - `add_task(now)` while following starts at once;
   - preempted activity (Luis gives ore) doesn't count for `gained`.
7. **Persistence:** a restart continues the active step with its segments, tallies and kills. A pending decision is re-issued (M2b). A corrupt `goals.json` is quarantined (M2a). CLI ingest survives a crash without duplicates (M2d). A Windows `PermissionError` on replace is retried (M2c).
8. **Budget:** the 21st request in an hour isn't made; the daily cap stops the Director; the player hears the wait once; usage is logged as `director`.
9. **Prep, reflection, knowledge:** a prepare decision's prep steps run first; `abort_if` stops a run; a rate drop triggers reflect and a trend line; unknown facts get the one nudge; recalled facts need no lookup; lookups are logged needed/needless.
10. **Thread safety:** the worker sees snapshots only; a hung decision times out; skill learning on the worker uses its own library instance.
11. **Unit tests:** predicates (built: 34 test functions, 59 tests with parametrisation), segments/tallies/my_drops, map memory with negative evidence, the gap cross-check against the manifest, the prerequisite caps.
12. **Cassettes** (H12c): real Sonnet decisions for the five T3 jobs, recorded once (≤ 15 calls, stated beforehand), then replayed in CI.

## 8. Hooks in files I don't own (approved by main: H7e, NON_INTERRUPTING/read_tools, M6, the tick in pump; exact diff sent to main)
1. `Agent.pump()` (end): `if self.director: self.director.tick()`.
2. `Agent.run_directed(event: dict, player: str) -> dict`: runs one body-initiated Controller request with the event as `body_events=[event]`. It executes a `run_skill` queued in that run before returning, and returns `{actions: [records], ended: normal|chat|interrupted|error, said: [lines]}`. Action records come from `_run_task`.
3. `Agent._run_turn`: board tool names go to `director.handle_tool(name, args, player)`, as `remember` does.
4. `Agent._activity`: forward every `Activity` to `director.observe_activity(event)` (M6).
5. `Agent._command`: after a chat-originated command whose decision ran actions, call `director.on_player_command(event, tools_run)`.
6. `Controller`:
   - board tool schemas appended from `director.tool_schemas()`;
   - `board` added to `read_tools`;
   - the board tools added to `NON_INTERRUPTING`;
   - `start_goal` hidden while the Director is on (after the eval, §6);
   - context `board = director.brief()`;
   - learned-skill retrieval in `board_step` runs uses the step title.
7. Persona: three lines on `board`, the `board_step` / `capability_gap` / `task_report` events and the resume rule. Each event also carries its own instructions.
8. `Agent._review_tick`: a board run in progress counts as busy; reviews between runs stay allowed.
9. `run_live.py`: build the Director (`planner_llm`, `open_knowledge`, the world state dir, the skill library dir, caps, the shared `Budget`); `DW_DIRECTOR=1`, `DW_DIRECTOR_CALLS_PER_HOUR`.
10. **Main (optional):** narrow `_player_spoke` to addressed lines (H7c).

## 9. Coordination
- **Eval agent (a65fe5f1906cd7879):**
  - `brain/predicates.py` is the shared format; I own it, and the benchmark adds leaves through `register()`.
  - Core gained `lost`, `on_ground`, `elapsed`, `station`, `vital` and `measures`; told 2026-10-25.
  - Null is "unverifiable" and never a pass.
- **Skills/capability agents:**
  - verify equip (`llm=false`);
  - export creature weaknesses and learned outcomes (M8);
  - `combat_brief`;
  - `quests` perception;
  - a `data/regions_<build>.json` dump (§2.12);
  - instance stats (L3);
  - the gap log as their backlog.
- **Observability agent:** `spend_today()` via `brain/budget.py`. Director calls log `component: "director"`.

## 10. Unverified / risks
- Equip of tools on the client (needed for live ladder 1).
- Gathering XP is not in data. Skill steps rely on `state.skills` XP (reported live) and the wiki.
- Wiki drop tables, habitats and quest steps are community text. In-game evidence wins, and refuted facts are marked.
- The proxied `craft_plan` waits for the bridge between runs. During a long run it answers "body busy", and the Director plans with what it has.
- Long Controller runs block the agent loop, as today. Only the Director's thinking is off-loop.

## 11. Review resolution (docs/reviews/2026-10-25-director-review.md)
| Finding | Where |
|---|---|
| H1 the model defines done | §2.1 "Success: immutable, never trivial", §7.4 |
| H2 gear_better false pass | **fixed in code**: `predicates._gear_better` (reference = held or carried at the baseline; a missing baseline inventory gives null). Tests: `test_h2_switching_to_a_pickaxe_he_already_carried_is_not_better` |
| H3 tally/baseline semantics | §2.1 segments, positive tallies, `my_drops`, kills |
| H4 auto-resume overrides "stop" | §2.6 (the resume run may decline), §7.6 |
| H5 endless empty-queue loop | §2.1 task-level progress rule; zero-gain loops count as replans |
| H6 `add_task(now)` while following | §2.1 Order, §2.6 |
| H7 races, `run_directed`, chat-cut runs, NON_INTERRUPTING, recipes | §2.3 versioning, §2.4, §8, the "Not built" note in §2 |
| H8 levelling progress | **fixed in code**: XP `measures` + `grew()`. Test: `test_h8_xp_is_a_measure_...`; §2.4 no-progress rule |
| H9 travel to unseen places | §2.5, §2.7 seeded gaps, §2.12 game map data |
| H10 prerequisite growth | §2.1 Who adds tasks (parent, depth ≤ 2, ≤ 3 live), §2.3 prompt shows every task |
| H11 thread safety | §2.3 Threading, §2.4 skill library instance |
| H12 acceptance | §7.3–7.6, §7.12 |
| M1 open tasks, help blocking | §2.1 Order, §2.6 Help |
| M2 persistence | §2 board.py row, §2.1 inbox offset / `awaiting_decision`, §7.7 |
| M3 null at activation | §2.1, §2.4 Activate |
| M4 claimed gaps | §2.7 cross-check, seeding, `unknown_skill` excluded |
| M5 budget | §2.8 |
| M6 `killed` feed | §8.4, §2.1 kills |
| M7 two task systems | §6, `brain/llm_json.py`, §2.4 skill conversion |
| M8 readiness data | §2.3 Readiness, §9 |
| M9 bag is slots | **fixed in code**: `SCHEMA_DOC`; §2.1 `inventory_full` ends the step |
| M10 templates | §2.6 Speech |
| L1 stale text | this revision |
| L2 `killed` substring | **fixed in code**: whole words (`situation.tokens`) + `target_id`. Test: `test_l2_killed_matches_whole_words_not_substrings` |
| L3 instance stats | §2.2 gaps, §9 |
| L4 search record | §3, Search record (JsonLogic, CEL, MineDojo, Crafter; pyrate-limiter corrected; links) |
| L5 negative evidence | §2.12 |

## 12. Re-check items (review "Re-check (rev 2)": go for wave 2)
1. **Segments follow run boundaries (High).** A segment opens immediately before each `run_directed` and closes immediately after it, so nothing between runs (chat commands, situation runs that eat or pick up) ever counts. An `on_player_command` that arrives *while* a run is in progress (nested, e.g. inside a `run_skill` expansion) **taints** that segment: the items the command's actions touched are left out of its delta. Test: a chat "give him ore" during a `run_skill` step.
2. **Action records carry their origin (High).** While a nested chat command runs inside a board run, `run_directed` records `origin: chat` (an `Agent._directed_origin` flag set by `_command` when `event.text`). Only `origin: board` records count for no-progress, `actions` and skill learning.
3. **Uncounted runs are capped (Medium).** Runs ended by `chat` / `interrupted` don't count toward no-progress or `max_runs`, but they do count toward `max_uncounted = 3 × max_runs` per attempt, plus a wall-clock limit per step (default 30 min). When either trips, the step **parks** with the truthful reason ("chat kept interrupting me").
4. **Skill learning: the worker only makes the model call (Medium).** It returns the raw record and example params. The agent loop runs the faithfulness and postcondition checks and `save()` on its own `SkillLibrary`, so there is one writer. This needs a small split of `SkillLibrary.learn` into `propose(...)` and `accept(...)` in `brain/skill_library.py` (main's file; listed in §8).
5. **Re-entrancy (Medium).** `tick()` is a no-op while `running` (inside `run_directed` → `run_goal` → `pump()`), and it doesn't start a run while `agent.active_goal` or `agent.pending_goal` is set (a chat-started `run_skill`). Pinned by a test. Fixed in the hooks diff.
6. **Drain events before the post-run check (Medium).** `run_directed` hands the stashed and pending events (`_stash` + `poll_events`) to `handle_event` before it returns, so the `killed` / pickup counters are current when StepRunner evaluates. Fixed in the hooks diff.
7. **Quiet legacy `run_goal` in board runs (Medium).** `run_goal(..., quiet=True)` from `run_directed`: no `milestone`, `goal_done` or `ask_for_help` lines. Its result goes back to the board. Fixed in the hooks diff.
8. **A delivery stays true after the player takes it (Medium).** `on_ground` gets `or_collected_by` (player): rows whose `magnet_target` is that player count. The board also **latches** a delivery verified right after the `drop` (its `world_items` within range of the player at that moment) as a recorded step outcome. Test: drop → the player picks it up → still done. (This is a predicates.py change; it is batched for the Eval agent before the judge tag.)
9. **No-progress prefers the step's own measures (Low).** `gained` / `tally` / XP / `killed` / `lost` / `on_ground` keys first, so a drop and pick-up of the same `have:` count never reads as progress.
10. **Request timeout (Low).** The Director passes `timeout=` to LiteLLM (`LiteLLMClient(..., timeout=60)`), so a hung request can't block the single worker. The 90 s decision timeout stays as the outer guard.
11. **Regions dump source (Low):** a dev-server run (§2.12).

## 13. Wave 5: real-model findings (2026-10-26; 24 Sonnet + 14 Haiku requests, $0.37, cap 40)
Cassettes are in `tests/fixtures/director_cassettes/` (better_pickaxe, coal_multitrip). `tests/test_director_cassettes.py` replays each job's first decision through today's Validator and board. The recorder is `tools/director_cassettes.py`. The other four jobs were not recorded: the hard cap was reached.

**Where real Sonnet differed from the scripted plans:**
- **Better pickaxe.** It planned a **Bone Pickaxe first**: the wiki says copper and tin ore need a bone pickaxe or better. GearWorld doesn't gate those rocks by tier (`min_tier` 1), so the mock is the inaccurate side; the live gate is read from the rock actor (gather_profiles / sense `gate`). Its first plan also put **3 prerequisites** on the board, and one of them made the Bronze plan with 7 steps, including explicit "walk to the Furnace / Bench" steps. It over-gathered (15 of each ore instead of 9), because the game-data lookup card was truncated.
- **Coal.** It planned "mine 50 coal → go back → drop at his feet" even though it knew no node position. It tried first rather than asking for help. The wiki says coal needs an iron pickaxe, so it added an iron-pickaxe prerequisite, and that prerequisite's own plan mixed ore with Iron Salvage Piles. It declared no travel gap.

**Problems it exposed, and the fixes:**
1. **About 5 requests per decision, not 3.** All 3 research rounds were used. Then, once the tools were withdrawn, LiteLLM injected a `dummy_tool` and Sonnet called it, which cost a repair round. **Fixed:** `json_decision` keeps the tools offered, says "Research is over", and refuses late calls as a counted repair. Test: `test_research_limit_keeps_tools_offered_says_so_and_refuses_late_calls`.
2. **Prerequisite explosion:** each prerequisite costs a full decision. **Fixed:** the prompt says the job's own work goes in its steps, and add_tasks is for a separate job; code takes at most 1 per decision (a cost cap).
3. **Lookup scoring.** Sonnet researches before it writes facts, so "not listed as unknown" was scored "needless". `situation.tokens` folded "nodes"→"nod" but "node"→"node". **Fixed:** needed = answers a listed unknown fact; needless = repeats an earlier lookup or recall of the same decision; else unscored (None). The knowledge index's own stemmer is used.
4. **Game-data cards are truncated** (`knowledge.py` SNIPPET 500 characters), so recipe quantities were cut off. Not my file; reported to main. `craft_plan` gives the quantities.
5. **GearWorld `craft_plan`** took the first recipe by id (Bronze Bar from Bronze Leaf), and Haiku then reported a recipe loop. **Fixed:** it ranks like the client planner (station near, inputs obtainable without a cycle).

**Haiku (start_goal eval, 5 lines × 2):**
- With or without `start_goal`, Haiku **never chose `add_task`**. Multi-step lines went straight to `gather` (a first step); a single action stayed a single action; "what are you working on?" was answered from `board`.
- So hiding `start_goal` doesn't by itself route long jobs to the board, and `start_goal` stays offered (`hides_start_goal=False`).
- Next: the `add_task` description and the persona lines need a clearer "a job of several steps or long duration goes on the board" (information, not a rule). Then re-check with a ≤15-call eval.

**Validator:** every recorded answer validated on its first JSON. No predicate errors. The only repair was the dummy-tool artefact.

**Wave 5b (2026-10-26; 15 Sonnet + 10 Haiku requests, within the approved ≤15 + ≤15):**
- **Cassettes recorded:** farm_mob_drop, quest, gear_self_initiated (4 requests each), with 2 research rounds per decision.
  - desert_weed's decision was cut off by the 15-request cap; its cassette has no decision and the replay skips it.
- **Farm drop:** real Sonnet noticed that the wiki's Giant Rat drop table has no Animal Bone (the mock's drop was my fixture). It planned a kill-and-check loop and would ask after no bones. It also claimed a "gap" that is knowledge, not a body primitive ("read drop tables"). The gap cross-check only tests tool names, so the claim was logged.
- **Quest:** it set the job test to `quest{completed}`, which can never be checked, and the validator accepted it, because only steps were checked for null. **Fixed:** an uncheckable job test now goes back for repair (test `test_a_job_test_that_can_never_be_checked_goes_back_for_repair`); its replay is now an expected rejection. Its first step used `near{thing: <name>}`, which only resolves once that thing is in sight. It declared quest-state and NPC-dialogue gaps.
- **Gear on his own initiative:** a sensible open-task curriculum (craft a Bronze Pickaxe, then mine for XP), with correct test semantics.
- **Haiku add_task re-eval:** after the information-only changes (the add_task description, the persona line that says start_goal → add_task while the board is on, and board context that says when it is empty):
  - with start_goal offered: the pickaxe line went to add_task, the coal line to gather;
  - with start_goal hidden: both long lines went to add_task, and every single action stayed single.
  - `Director.for_session` now hides start_goal. Sample: one run per line.
- **Other fixes in this round:**
  - knowledge.py game cards are cut by whole fields (recipe quantities kept, "N more way(s)"), with tests in `tests/test_knowledge_cards.py`;
  - GearWorld rock gates come from `data/wiki/derived/rock_gates.json`: the wiki node infoboxes resolved to catalog tool tiers (`tools/build_rock_gates.py`; gitignored with the mirror; the live gate wins in game);
  - decisions use 2 research rounds.

## 14. Dev live smoke plan: DW_DIRECTOR=1 (not run yet)
**When:** once the client is free, after the L24 A/B and the eval T0 smoke. **Where:** the dev world only (GOAL §1b). Nothing touches Shockbyte.

**Budget:** ≤ 10 Sonnet requests, hard-held by `DW_DIRECTOR_CALLS_PER_HOUR=10`. Plus the Haiku turns of the Controller runs (expected 10–20 small calls, priced as live_controller). State both before starting. Check `tools.obs spend --today` first: at least $1 must be left under the cap.

**Job:** "chop 5 logs and bring them to me". It needs several tools (gather → go_to → drop), so it exercises the board. (A plain "chop me 5 logs" is one `gather` and rightly not a board job.) Two entry paths, both checked:
- (a) chat from the dev test player, so Haiku decides whether it goes to add_task;
- (b) `tools/board.py add "..." --world <dev world>`, the board path whatever Haiku chooses.

**Preconditions (all must hold):**
1. The client is on dev: `client_boot.ps1 -Target dev` or a scenario lease. `Get-JoinedServer` shows the dev address. The watchdog is quiet.
2. The body manifest lists gather, go_to and drop as `llm: true`. equip is `llm: false` (a seeded gap).
3. **World id:** start the brain with `$env:DW_DIRECTOR="1"; $env:DW_DIRECTOR_CALLS_PER_HOUR="10"; tools\start_brain.ps1 -Body client -World dev_director` (`-World` overrides the user-level DW_WORLD_GUID=shockbyte). Then confirm `session_start world=dev_director` in the brain log. Abort if it says shockbyte.
4. `$env:DW_DIRECTOR="1"; $env:DW_DIRECTOR_CALLS_PER_HOUR="10"`. `session_start director=true`. The board file `logs/state/worlds/<dev>/goals.json` is absent or holds no live tasks.
5. Ash trees within 30 m of the spawn, or the test player stands near some. Claude carries an axe (the gather gate).

**Steps and what to see:**
1. Start the brain: `tools\start_brain.ps1 -Body client -World dev_director` (precondition 3). Check `session_start` (director=true, world=dev…) and that persona_lines and the board tools are in the first prompt.
2. **(a)** The test player says the line in chat. Record whether the Controller called `add_task` (expected, per the wave 5b eval) or went straight to gather. Either way the line is answered at once.
3. A `director_dispatch` decision is made (≤ 4 requests) and `director_decision` sets steps whose tests are core predicates (gained logs, near the player, lost + on_ground near the player).
4. Board runs: `board_run` rows. gather is verified by the executor. The segments' gains and the tally show the logs.
5. Delivery: `on_ground` near the test player (or magnet_target while he takes them) → step done → task done → a `task_report` notice voiced by the Controller (one line).
6. **(b)** `tools/board.py add "chop 5 logs and bring them to me" --world dev_director` → ingested on the next tick (`tools/board.py list` shows it) → the same flow.
7. Optional (1–2 more Sonnet requests): during a board run the player says "stop" → `preempted`; after 30 s the resume run should call `pause_board`. Then `resume_board` via chat.

**Pass:**
- both tasks done by predicates, with no `director_error`;
- Sonnet requests ≤ 10 (count `llm_response` component=director in the brain log);
- every line said matches a verified state;
- no hang or crash; spend delta noted.

**Abort at once:**
- any `director_error` or `board_quarantined`;
- a step re-running with no change for more than 3 runs;
- the client hung or off dev;
- the board writing to the shockbyte world folder.

To abort: `tools/board.py cancel <id>` and pause the board through chat. If needed, stop the brain and restart it without DW_DIRECTOR. The board file is kept as evidence.

**Amendment (2026-10-26):** the dev world may have no player to chat with or deliver to. Then the CLI path is the main test, with a job that needs no player: `tools/board.py add "chop 5 ash logs, then drop them on the ground next to you" --world dev_director`. It needs two tools, and its success is checkable from his own state: logs gained, then `lost` + `on_ground` near himself. The chat path (a) runs only if a dev player is online. Also expect the Wooden Shield prerequisite case (Luis, M1/M2) as a follow-up smoke once a Crafting Table exists on dev.

**Evidence:** the brain log path, the goals.json snapshot, `tools/board.py list --json`, `tools/board.py gaps`, `tools/timeline.py` over the window, and the spend delta. File the results in DISCOVERIES ("Director live smoke (dev)") and PROGRESS.

## 15. Live verification order for the 12 skill routes (M3; ready for when the client is back)

This proves each route that the mock passes (tests/test_director_skills.py) on the real body, on dev only.

**Method:**
- One debug call per skill through the bridge (no model): read `get_state.skills` before and after.
- **Pass** = that skill's `xp` rose by more than 0, by the body's own skill state (`skill_gain {name, xp: 1}`), and the tool answered `ok`.
- Record each result in DISCOVERIES.

**Order:** cheapest and least risky first. Each row lists the precondition he must meet first.

| # | Skill | Call | Precondition | Risk / unknown |
|---|---|---|---|---|
| 1 | Woodcutting | `gather {resource: ash, count: 2}` | an axe; ash in reach | none (proven live) |
| 2 | Mining | `gather {resource: stone, count: 2}` | a pickaxe; a boulder near | none (stone tier 1) |
| 3 | Agility | `agility_course {}` (after `agility_courses`) | a course near, level ≥ its minimum | can it run a course |
| 4 | Fishing | `fish {count: 1}` (after `fishing_spots`) | a net or rod that fits the spot | spot and tool fit |
| 5 | Cooking | `craft {item: <a cooked food>}` at a Campfire | raw food carried; a lit campfire | campfire fuel |
| 6 | Artisan | `craft {item: <cheapest>}` at a CraftingTable | inputs from `recipes` | none (craft proven) |
| 7 | Attack | `attack {target: <weak creature>}` with a melee weapon | a low-power creature | a fight (immortal off on R2: HP watch) |
| 8 | Construction | `build {piece: Campfire}` | 6 stone | build ships with a bridge_start |
| 9 | Farming | `farm_plots` → `tend {item: <spade>}` on a plot | a plot (weeds, so dig first) and a spade | plot ownership |
| 10 | Magic | `cast {spell: <combat spell>, target}`, or attack with a staff | runes; a target | whether utility casts give XP; runes |
| 11 | Ranged | `attack {target, weapon: <bow>}` | a bow AND ammo (Sonnet's plan crafts arrows first) | ammo use, aim |
| 12 | Runecrafting | `craft {item: Air Rune}` at a RuneAltar | Rune Essence; an altar in reach | **does craft drive the altar** (asked of the skills agent) |

**Stop rules:**
- Stop if health drops below 50% in rows 7, 10 or 11.
- Stop and log a gap on any `not_implemented`, `unknown_tool` or `verification_failed`. The Director then names it as a gap (test_m3_a_lagging_skill_without_a_body_tool_is_a_named_gap_not_fake_progress).

**After the routes:** one real-model run of an m3 `_initiative` case per skill that fails or is untested, with ≤ 10 Sonnet requests per batch.
