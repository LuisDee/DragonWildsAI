# Director and task board: long-horizon jobs ("get better gear, level skills of your choice")

Status: **design, for the review gate** (autonomy-plan.md §4, §5 steps 2–3; scope additions from Luis via main, 2026-10-25). Author: the Director agent.
Nothing is built yet. The build is offline only (mock + fake models) until main approves the hooks in §8.

## 1. Goal (what Luis will see)
- **Task board.** Luis says "go gather coal", "farm desert weed at our farm", "get a better pickaxe" or "level up skills of your choice". Each becomes a board entry, and Claude says what he'll do first and why. Main can queue tasks from a CLI (`tools/board.py add/list/cancel/gaps`). "What are you up to?" is answered from the board: the current task, its current step, progress and what's queued.
- **Works it out himself.** Claude researches (wiki + game data + his own map memory), plans steps, runs them for hours, loops trips when his bag fills, replans when a step fails, and adds his own prerequisite tasks ("I'm PL 2 and those are PL 5: upgrading my armour first").
- **Milestones, not a timer.** He reports verified facts once per milestone, e.g. "Bronze Pickaxe on: tier 1 → 3", "trip 3: 61 coal so far".
- **Interruptible.** When Luis talks to him, he answers at once and does what is asked. The board pauses and resumes by itself when Claude is idle again ("Back to the coal"). "Hold on" or "drop the coal job" pause or cancel it; the model decides that, through tools.
- **Honest about gaps.** When a plan needs something his body can't do yet (lodestone teleport, storage deposit, planting, quest dialogue, ranged aim), he says so plainly ("I can't use lodestones yet, so I'll walk: about 4 min") and the gap is logged. That log drives the next primitives we build.
- **Asks for help once.** When he's stuck after his own replans, he asks once and specifically ("I've checked the two coal spots I know and both were mined out. Know another?").

## 2. Approach: layers and files
Three loops at three speeds (autonomy-plan §4):
- Lua reflexes, at frame rate;
- the Haiku Controller, on events, one step at a time;
- the **Sonnet Director**, at step boundaries only.

The board and the Director are brain-side. They act only through the Controller's normal tools.

| New file | What it owns |
|---|---|
| `brain/predicates.py` | **The success-predicate format and its evaluator, shared with the Eval agent's benchmark** (§2.2): `validate(p, catalog)` and `evaluate(p, state, ctx) → {passed: true\|false\|null, detail, progress, missing}`. Pure functions. |
| `brain/board.py` | The board: task and step models, plus `BoardStore` (`<state>/worlds/<w>/goals.json`, written atomically, single writer = the brain). Also the CLI inbox `board_inbox.jsonl` (appended by `tools/board.py`, ingested on `tick`) and the verified tallies. |
| `brain/capability_gaps.py` | `GapLog` for `logs/state/capability_gaps.json` (§2.7). |
| `brain/recipes.py` | `RecipeGraph` over `data/recipes_<build>.json` plus `items_<build>.json`: `makers(item)`, `tree(item, count, have, stations_known)`, and name→id resolution with candidates. It is an AND-OR backward chainer with a shared ledger (Plan4MC Alg. 1 plus Mindcraft's leftovers), built as decided in research D4 (`docs/research/2026-10-25-scalable-agent-frameworks.md` §5.2). About 200 lines. |
| `brain/knowledge_memory.py` | `KnowledgeMemory`: facts the Director looked up or observed, with source, confidence, build, refuted flag (§2.11); `efficiency.json` best rates + `efficiency.jsonl` trend log (§2.10) |
| `brain/map_memory.py` | `MapMemory`, per world (`map_memory.json`). It records what any `get_state` showed: stations, resource nodes (by kind/item), creatures (kind, PL, attitude), lodestones, chests and beds, each with position, count and last seen. `query(kind\|name\|item)` returns the nearest known first, with distance and age. It also reports `places.json` and the learned nav-route count as facts. |
| `brain/director.py` | `Director`: the Sonnet decision loop with read-only research tools, the curriculum, DEPS replans, caps and the per-hour `CallBudget`. `StepRunner`: the executor bridge. The Controller-facing board tools. `AgentAdapter`: interim glue to today's `Agent` (§8). |
| `tools/board.py` | CLI: `add "<text>" [--first]`, `list`, `cancel <id>`, `gaps`. Writes only to the inbox; reads `goals.json` and `capability_gaps.json`. |
| `brain/mock/gear_world.py` | `GearWorld(MockGame)`, driven by the real catalogs (item ids, recipe inputs/outputs/stations, tiers, recipe XP). It has ore rocks, a Furnace, a Blacksmith's Bench, `craft` by recipe data, `equip`, `gear`, `inventory_items`, `skills`, a `bag` capacity, creatures with drops and PL, places, and a toggle that removes primitives to provoke gaps. |
| `tests/test_director.py` (+ `tests/test_predicates.py`) | §7 |

No edits to `agent.py`, `controller.py`, `broker.py` or `client_mod/` (other owners). Their hooks are in §8.

### 2.1 The board (`goals.json`, survives restarts)
```
{v:1, current: <task id>|null, paused: null|{by, reason, until_resume}, budget:{calls:[ts...]},
 tasks:[{id, text, by: player:<name>|cli|self, because?, kind: specific|open, priority_index,
         status: queued|active|preempted|paused|waiting_help|waiting_budget|done|stuck|cancelled,
         success: predicate|null (open tasks: none), baseline, tallies:{item: verified gain}, created, ended,
         steps:[{id, title, why, hints, success: predicate, needs:[primitive], group?, status: pending|active|done|failed|dropped,
                 attempts, max_attempts:2, runs, max_runs:8, baseline, failures:[{reason, detail, explanation, at}],
                 actions:[{tool, args, ok, reason}], started, ended}],
         loops:{<group>: {until: predicate, max:20, done:n}}, replans, history:[{title, outcome, seconds, reason}],
         notes_from_player:[...]}]}
```
- **Who adds tasks:**
  - Players, through the Controller tool `add_task(text, when: now|next|later)`. The Controller model understands the line; no phrase tables.
  - Main, through the CLI inbox.
  - Claude himself, through the Director's `add_tasks` output (prerequisites, shown with `because`).
- **One current task.** The others queue. `now` preempts the current task, which goes back to the queue head, its steps intact.
- **Loops (trips).** A step may belong to a `group` that has `until: predicate`. When the group's last step is done and `until` still fails, code re-queues the group's steps (new baselines). That needs no Sonnet call. The cap is 20 loops, and the loop stops after 2 loops with zero verified gain. Example: [mine coal until bag ≥ 95 % or Coal ≥ 99] → [go to base] → [deposit], repeated until the task's tally of Coal ≥ 200.
- **Tallies.** At every step end, code adds the step's verified inventory delta (fresh state minus baseline) to the task's tallies. That is how "200 coal over 4 trips" is verified without trusting a claim.

### 2.2 Success predicates: checkable from fresh state, never from the model's claim (principle 5)
This is a JSON DSL. The Director writes it; code validates it and evaluates it on fresh `get_state`. **The same format is proposed to the Eval agent for `docs/design/eval-benchmark.md`** (that file doesn't exist yet; main to relay, §9). One module serves both. Each leaf reads only fields the body already reports (`inventory`, `inventory_items`, `gear`, `skills[{skill, level, xp}]`, `bag{used, capacity}`, `position`, `players`, census rows, `activity` episodes), plus catalog data (`item_stats`) and per-world memory (places).

| Leaf | Meaning |
|---|---|
| `have {item, at_least}` | carried count |
| `gained {item, at_least}` | since the step's baseline |
| `tally {item, at_least}` | the task's verified gains across steps and trips |
| `skill {name, at_least}` / `skill_gain {name, levels}` | from `state.skills` |
| `equipped {item}` | in gear |
| `gear_better {category\|slot, stat, where: equipped\|carried, than: "start"\|number}` | the best item's catalog stat; `"start"` = the baseline's best |
| `bag {used_pct_at_least \| free_at_least}` | from `state.bag` |
| `near {place\|player\|position\|thing, within_m}` | |
| `moved {min_m}` | distance from the baseline position |
| `killed {kind, at_least}` | combat-end episodes with outcome killed since the baseline (body-verified, `ctx.episodes`) |
| `vital {stat, below_pct\|at_least_pct}` | health and survival stats vs their max (§2.9) |
| `quest {name, stage\|completed}` | **evaluates `null` today**, because the body reports no quest state (a perception gap) |

Combinators: `all`, `any`, `not` (three-valued: Kleene logic). `ctx` is a plain dict: `baseline` (`snapshot(state)`), `tallies`, `places`, `episodes` (activity since the baseline), `results` (tool calls since the baseline). Other leaves join through `register(name, evaluate_fn, validate_fn)` without edits to the module (the benchmark's `spell_effect`, `station_used`, `hit_rate`, ...); `errors(p)` lists every problem with its path and candidates, for one repair round. **Built:** `brain/predicates.py` + `tests/test_predicates.py` (main allowed it before the gate; the Eval agent adopts it). Item names resolve to ids through the catalogs. An unknown or ambiguous name returns its candidates for one repair round.

**`passed: null` means "can't be checked from what the body reports"** (`missing: ["quests"]`). Such a step is never marked done: it is logged as a perception gap (§2.7) and the Director must choose a checkable test or ask the player. `progress` (0..1) and `detail` (e.g. "Copper Ore 4/9; Tin Ore 9/9") feed progress lines, the no-progress rule and the Director.

### 2.3 Director calls (Sonnet, `planner_llm`), each counted against the budget
**When it is called.** Only at these points:
- a task becomes current;
- the step queue is empty (and no loop re-queued);
- a step attempt failed (DEPS);
- the player answered a help question;
- every `review_every_s` (300 s) while a step runs, and only if at least half of the hour's budget is left.

**Prompt.**
- Cached prefix: persona, output schema, and **the body's real tool list** (manifest names and descriptions), so it knows which primitives exist.
- Then: the task, the board (other tasks, one line each), the step tree with done/failed steps and reasons, `history`, a compact state (skills, gear with stats, PL, inventory, bag, where), a map-memory summary, the top-3 learned skills, the known capability gaps, and **readiness** and **curriculum** facts (below).

**Research tools.** They are read-only and brain-side. They run on a state snapshot and never touch the bridge.
- `lookup` (knowledge.py: game data first, then wiki; covers drop tables, regions, quests and lodestones);
- `recipe_tree` and `makers` (recipes.py);
- `compare_gear`: item_stats over the catalog for a category/slot, with stats and deltas vs his best, and each item's recipe status;
- `map_memory`;
- `skills_progress`;
- `learned_skills`.

A decision gets at most 4 LLM rounds (3 research rounds plus the answer), plus 1 repair round for invalid JSON or predicates.

**Output.**
```
{description, explanation, task_success?: predicate,
 steps: [{title, why, hints, success, needs?:[primitive], group?}], loops?: {group: {until}},
 add_tasks?: [{text, because, when}], capability_gaps?: [{primitive, why, workaround?}],
 ask_help?, done?}
```
- `steps` replaces the pending queue; done steps stay.
- `done` ends an open task. That is the model's decision.
- A specific task ends only when `task_success` passes on fresh state.

**Readiness facts** (information, never a rule):
- his PL: catalog power levels of what he wears and holds;
- PLs of creatures and regions involved: census rows plus the wiki's region PL (e.g. Brynmoor 1–2);
- the target creature's weaknesses: `creature_priors` data and learned hit outcomes;
- which carried and craftable weapons deal those damage types (the catalog's `damage_types`).

The model decides whether to add an upgrade task first.

**Curriculum (Voyager §2.1), for open tasks.** The model proposes the next 1–2 achievable steps. Code supplies facts only:
- gear upgrade options per slot/category he uses, with recipe-tree status;
- skills with level/XP, and the recipes/stations that award XP for each (recipe `skill`/`xp`);
- what he can make now;
- the completed/failed history, so he avoids repeating what just failed.

No ranking rule picks for him.

**DEPS on failure.**
1. Describe: the attempt's real tool results and reasons, the predicate's detail now, and the Controller's `report_step` reason.
2. Explain the cause.
3. Revise the remaining steps, add a prerequisite task, or `ask_help`.

Caps: 2 attempts per step and 6 replans per task. Past either, the task goes to `waiting_help`, and the question is said once.

**Threading.** The decision runs on one background worker (PIANO's concurrent modules). `tick()` applies the result on the agent loop, so chat stays responsive while Sonnet thinks. Tests use a synchronous executor.

### 2.4 Executor bridge (`StepRunner`)
- **Activate a step:** baseline snapshot, `attempts += 1`, persisted.
- **One run** is one body-initiated Controller request (empty command text) carrying a `board_step` event. The event holds:
  - the task, the step's title, why and hints;
  - the predicate in words, plus its current detail;
  - run n of max, and the last run's results;
  - learned skills matching the title;
  - `resumed` (after a pause) and `just_completed` (the verified facts of the previous step or loop, which the Controller voices as the milestone: single voice).

  The Controller uses its normal tools and the agent loop (≤ 4 continuation turns).
- **After each run**, the predicate is evaluated on fresh state:
  - Passed: the step is `done`, the tallies are updated, and the next step or loop follows.
  - The Controller called `report_step(blocked, reason)`: the attempt fails with that reason.
  - The Controller called `report_step(done)`: this only triggers an immediate check. If the check fails, the next run is told "you reported done, but: Copper Ore 4/9".
  - No progress in 2 consecutive runs (progress unchanged and no successful action), or `max_runs` reached: the attempt fails with "no progress: <detail>". Then DEPS (§2.3).
- **A tool result in Reason.CANT_YET** (`not_implemented`, `unknown_tool`) is recorded as a capability gap automatically (§2.7).
- **Skill library reuse:** a done step with ≥ 2 verified actions goes to the existing `SkillLibrary.learn`, with its faithfulness and postcondition gates, if at least 30 % of the hour's budget is left. Learned skills are offered to the Director (to plan with) and to the Controller (`run_skill`), so the next trip costs no Sonnet call.

### 2.5 How the requested jobs fall out generically
No job has code of its own. Each comes from the research tools, the predicates, map memory, loops and the gap log.

| Job | Research | Steps, predicates and loops | Gaps today |
|---|---|---|---|
| **gather coal** | `lookup coal` (wiki: coal nodes in Fellhollow, Dowdun Reach, Umbral Sands; game data: vendor too); `map_memory item=coal` and `kind=lodestone` | go to the best known spot (`near`) → mine until `any[bag ≥ 95 %, have Coal ≥ 99]` → go home → deposit → loop until `tally Coal ≥ N` | lodestone teleport, storage deposit (workarounds: walk; drop at base or give to the player) |
| **farm resource X** | `lookup X` (drop tables: X from mob Y) → `lookup Y` (where it lives) + `map_memory creature=Y` → readiness (Y's PL and weaknesses vs his gear) | (gear upgrade task if he chooses one) → go to Y's area → hunt until `any[bag full, have X ≥ k]` → go home → deposit → loop on `tally X` | ranged aim (if chosen), deposit |
| **all Brynmoor quests** | `lookup Brynmoor quests` → each quest's steps and prerequisites (wiki) | one task per quest (`add_tasks`), with steps in prerequisite order; the predicates `quest{...}` evaluate `null` | quest-state perception and quest dialogue: logged and said once; the task asks Luis how he'd like to proceed instead of faking progress |
| **gear progression** | readiness facts on every Director call | the Director adds "upgrade <slot>" tasks before the current one (`because: PL 2 vs PL 5`) | — |
| **farm desert weed at our farm** | `places.json` "our farm" (Luis taught it with `remember`), `lookup desert weed seeds` | go to the place → plant → wait/water → harvest → loop | plant/harvest primitives (`interact` may cover harvesting; unverified) |
| **get a better pickaxe** | `compare_gear category=pickaxe`, `recipe_tree` | mine copper and tin → smelt Bronze Bars → craft at the Blacksmith's Bench → equip; task predicate `gear_better{category: pickaxe, stat: tool_tier, where: equipped, than: start}` | equip (`llm=false` on the client today: "not yet verified") |

### 2.6 Preemption, pause, resume, reports
- **Preemption.** A chat-originated command that runs actions puts the board in `preempted`. No state is lost: the active step keeps its baseline and attempt. A running board run already stops when the player speaks (`Agent._player_spoke`).
- **Auto-resume** follows Mindcraft's `self_prompter`, which stays ACTIVE and restarts after an idle cooldown. The board resumes when all of these hold:
  - no player command for `resume_idle_s` (30 s);
  - no brain action running;
  - not following a player (`state.following`);
  - no chat pending.

  The next run carries `resumed: true`, so he says he's going back to it.
- **Pause and cancel** are the Controller model's choices, through `pause_board(reason)`, `resume_board(note)` and `cancel_task(id, reason)`. A `note` carries the player's answer to a help question into the Director's next call.
- **`board()`** (read) lets the Controller answer "what are you up to?".
- **Milestones.** The verified facts of a done step or loop (predicate detail, tallies, skill and gear deltas since the task began, elapsed time) ride in the next run's `just_completed`. A task's end is a `task_report` event.
- **Never silent** (principle 7): if no model line comes back, a template from the same facts is said. The same holds for help questions and gap notices.

### 2.7 Capability-gap log (`logs/state/capability_gaps.json`, all worlds)
Each primitive gets one record:
```
{primitive, kind: action|perception, count, first_seen, last_seen, examples: [{task, step, why, workaround}], sources: [director|tool_failure|uncheckable]}
```
- **Sources:**
  - the Director's `capability_gaps` (a plan needs a primitive that is not in the tool list);
  - tool results in `Reason.CANT_YET`;
  - predicates that evaluate `null`, which become perception gaps (e.g. `quests`).
- **Voicing:** each new gap for a task becomes a `capability_gap` event. The Controller says it plainly once, with the workaround if any.
- **Reading it:** `tools/board.py gaps` lists the gaps sorted by count. That list drives the next primitives we build.

### 2.8 Budget
- `CallBudget(per_hour = DW_DIRECTOR_CALLS_PER_HOUR, default 20)` keeps a sliding one-hour window of call timestamps, persisted in `goals.json`, so a restart doesn't reset it.
- When it is exhausted at a boundary, the board goes to `waiting_budget` until the oldest call leaves the window, and says so once ("I'll pick my next step in 6 minutes").
- Loops and learned skills keep him working without Sonnet calls.
- Haiku turns are not counted here.
- **Estimate**, using the research doc's §6.7 prices (Sonnet $2/$10 per M):
  - one Director call ≈ 8k tokens in (≈ 3k cached) + 0.8k out ≈ $0.02;
  - 20 calls/h ≈ **$0.40/h**;
  - plus Haiku runs, ~60–120/h ≈ $0.05/h.

### 2.9 Preparation before risky steps (Luis, 2026-10-25)
- The Director marks a step `risk: fight | trip` (its own judgement). Before such a step activates, if the steps just before it are not already its prep, the Director gets one **prepare** call (budget-gated). That call carries the `combat_brief` facts:
  - his power level vs the target's or region's;
  - the target's weaknesses and resistances;
  - his weapons and enchant spells matching those damage types;
  - armour, buffs he can cast, food and drink on the hotbar and in the bag;
  - the way back (known lodestones, places, the nearest bed or shelter).

  The facts come from the body's `combat_brief` when it reports one; until then they are brain-side (§2.3 readiness).
- The model chooses the prep. It may insert prep steps (swap gear, cast the matching enchant, move food to the hotbar, craft potions) and attach an **escape plan**: `escape` hints for the Controller plus an `abort_if` predicate (e.g. `any[vital{health below_pct 30}, not have{food}]`). It may also decide no prep is needed.
- After every run, code checks `abort_if` on fresh state. If it holds, the step stops (`aborted: <detail>`), and the next run's event tells the Controller to carry out the escape hints. Then DEPS follows. Reflexes still own in-fight defence.
- New core leaf for this: `vital {stat: health|hydration|sustenance|endurance|stamina, below_pct | at_least_pct}`. It reads the flat state fields and their `*_max`.

### 2.10 Efficiency reflection (milestones)
- **Rates.** At every step or loop end, code computes the verified rate from the step's baseline → fresh state: items per minute (inventory or tally deltas) and XP per minute (`state.skills` xp deltas). It keys the rate by (item or skill, place or nearest known spot), and keeps the best rate seen per key in `efficiency.json` (per world).
- **Facts for the Director:** rate now, best seen, and the previous loops' trend. Alternatives come from data:
  - castable spells with their own `use_when` text and role;
  - other known spots for the same item (map memory) with travel estimates;
  - lodestones known near them;
  - better tools for the job (`compare_gear` on the tool category the step used).

  Code never says which alternative helps (it can't know that Rocksplosion speeds up mining); the model reads the spell text.
- **When it is called:** a **reflect** call is triggered at a loop end when the rate fell below 70 % of the best for the key, or every 3 loops. Both are budget-gated. Otherwise the facts ride along in the next call that happens anyway.
- **Optimisation trend log.** Each reflection appends one line to `logs/state/worlds/<w>/efficiency.jsonl`: `{ts, task, step, key, rate, best, alternatives_offered, change: <what the model changed> | null}`. The benchmark reads it.

### 2.11 Knowledge-gap check (when to use the wiki)
- **Every Director plan states its facts.** The output gets `facts: [{fact, for_step, status: known | unknown, source: game_data | perception | memory | wiki, confidence}]`. Examples: a recipe, where a resource is, a creature's weakness, a quest step.
- **Unknown facts get one nudge.** If facts are unknown and research rounds are left, the loop answers once with the list: "These facts are unknown: look them up, or say why the plan doesn't need them". This is information, not a veto; the model may commit anyway with its reason.
- **Lookup order:** `recall` (the cache) → game data (`recipe_tree`, `makers`, `compare_gear`, map memory) → `lookup` (game docs first, then wiki: knowledge.py's tiering).
- **The cache.** `KnowledgeMemory` (per world, `knowledge_memory.json`) stores `{key, value, source, confidence, ts, build}`:
  - game data and in-game observation are `high` and override the wiki ("coal mined at [x,y,z]" beats "coal is found in Fellhollow");
  - wiki is `medium`;
  - a fact refuted in game is marked `refuted` (DECKARD's idea).

  Locations also go into map memory.
- **Lookups are logged** with `needed: true` when the query matches a fact the plan had listed as unknown, otherwise `false`. The benchmark can then score needed vs needless lookups. Cached facts make repeat lookups needless by construction.

## 3. Precedent (search-before-building; searches 2026-10-25)
| Need | Found | Decision |
|---|---|---|
| Director/Controller split | PIANO / Project Sid: concurrent modules (arXiv 2411.00114). GITM: goal → sub-goals → structured actions (github.com/OpenGVLab/GITM). HiMAC: planner/executor (arXiv 2603.00977). Odyssey: planner-actor-critic (arXiv 2407.15325) | **adapt**: our Controller is the actor, the Director the planner |
| Task tree with working memory | ReAcTree: an agent node per subgoal, control-flow nodes (sequence/fallback), shared working memory, episodic examples (arXiv 2511.02424, AAMAS 2026) | **adapt**: a board of tasks → step queue with loop groups; map memory as working memory; the skill library as episodic memory. No parallel nodes, because there is one pawn |
| Verified subgoals | Voyager self-verification (arXiv 2305.16291). StructAgent: "verifier-backed state transitions", Minecraft subgoals (VERB, ITEM, n) checked on inventory (arXiv 2607.11388). Neuro-symbolic dual memory: symbolic checks plus neural progress (arXiv 2604.02734) | **adapt**: a declarative predicate DSL evaluated by code. No generated code (the skill library's L3 rule) |
| Curriculum | Voyager's automatic curriculum (completed/failed lists, "not too hard"); OMNI interestingness (arXiv 2306.01711) | **adapt** Voyager's inputs; code gives facts, the model picks |
| Replanning | DEPS: describe/explain/plan/select (arXiv 2302.01560). Metagent-P: plan-verify-execute-reflect, fewer replans (ACL Findings 2025) | **reuse** the Planner's DEPS pattern. The caps are ours; no source found sets one |
| Self-directed loop, interruption | Mindcraft `src/agent/self_prompter.js`: ACTIVE/PAUSED/STOPPED, stops on a user command, auto-restarts after 2 s idle, stops after 3 replies without a command (github.com/kolbytn/mindcraft). MineCollab (arXiv 2504.17950) | **adapt**: preempted/paused states and idle auto-resume, with our no-progress rule in place of "no command ×3" |
| Recipe chaining | Plan4MC, Mindcraft `getDetailedCraftingPlan`, GOAP, GTPyhop (research doc D4) | **build small**, as decided in D4. The Lua `craft_plan` stays the Controller's live tool |
| Board/goal-tree library | py_trees and Dendron (LLM behaviour trees): neither persists or resumes a run. LangGraph checkpoints (rejected in D1: we keep our own harness) | **build**: pydantic models plus atomic JSON, like `task_tree.json`; a CLI inbox file, so there is one writer (principle 9) |
| Hourly budget | `limits` (moving window; memory/redis backends); `pyrate-limiter` (leaky bucket; redis to persist) | **build**, ~20 lines: neither persists to a file, and we need one counter |
| Gap log | Voyager's/Odyssey's skill-library growth comes from failures; no ready tool | **build**: a JSON counter file |

## Search record
Queries (2026-10-25): "LLM agent open-ended game long-horizon goal tree curriculum 2026 arXiv Minecraft"; "ReAcTree hierarchical LLM agent tree subgoal working memory"; "Mindcraft self-guided play self_prompt"; "2026 arXiv LLM agent automatic curriculum open-ended embodied goal feasibility"; "LLM game agent hierarchical planner executor long-horizon 2026 Minecraft subgoal verification replanning budget"; "Python library persistent goal tree task tree LLM agent behavior tree py_trees resume"; "pyrate-limiter sliding window rate limit python persistent per hour". Searches with nothing usable: a library for a persisted/resumable LLM goal tree, and any published cap on replans.
- Voyager: https://arxiv.org/abs/2305.16291
- DEPS: https://arxiv.org/abs/2302.01560
- GITM: https://github.com/OpenGVLab/GITM
- PIANO / Project Sid: https://arxiv.org/abs/2411.00114
- ReAcTree (AAMAS 2026): https://arxiv.org/abs/2511.02424
- Mindcraft self-prompter: https://github.com/kolbytn/mindcraft/blob/main/src/agent/self_prompter.js
- MineCollab: https://arxiv.org/abs/2504.17950
- StructAgent: https://arxiv.org/abs/2607.11388
- Neuro-symbolic dual memory: https://arxiv.org/abs/2604.02734
- HiMAC: https://arxiv.org/abs/2603.00977
- Odyssey: https://arxiv.org/abs/2407.15325
- Metagent-P: https://preview.aclanthology.org/new-sigs/2025.findings-acl.1169/
- OMNI: https://arxiv.org/abs/2306.01711
- py_trees: https://pypi.org/project/py-trees/ · Dendron: https://pypi.org/project/dendron/
- limits: https://limits.readthedocs.io/ · pyrate-limiter: https://pypi.org/project/pyrate-limiter/

## 4. Generality check
- **No names in code.** There is no item, creature, station, skill, quest, region or place name in code. Those come from:
  - `data/*_<build>.json`: items, stats, categories, damage types, recipes, stations, XP;
  - `state.skills`;
  - map memory and `places.json`;
  - the wiki through `lookup`.

  "Better pickaxe", "farm X", "gather coal" and "level Fishing" use the same code; only the model's steps and the data differ. The held-out tests (§7) push non-pickaxe jobs through the same code.
- **Language is the model's job.** The Controller model decides whether a line adds, pauses or cancels a task. Code never reads the player's words.
- **What code decides:**
  - whether a predicate passed, failed or can't be checked (verification);
  - re-queueing a loop while its `until` fails, a rule the model wrote;
  - the attempt, replan and loop caps, and the hourly budget (Luis's cost rule);
  - when to auto-resume, from state (idle, not following).

  It never changes the model's steps, predicates or tasks. The one exception: an invalid predicate schema goes back to the model with the reason.

## 5. Principles touched
- **Central to the design:** #5 verified state (predicates, tallies), #7 communication (milestones, gaps, help), #8 remember (map memory, skills, gaps).
- **#6 single voice: kept.** The Director never speaks. Its facts and questions reach chat through the Controller's runs; templates are used only when the model says nothing.
- **#4 two speeds:** Sonnet runs only at boundaries. The only timer is the budget-gated 5-min review, which autonomy-plan §4 asks for.
- **Luis's OK needed?** No principle is bent. He should nod to the default budget (20 calls/h, ~$0.40/h) before the first long live run.

## 6. Interaction with the existing Planner
- `start_goal` (Planner, a one-shot task list) and `add_task` overlap.
- Proposal: with the Director on, `start_goal` is no longer offered, and `add_task` covers it. The Director plans short jobs in one call, just as the Planner did. This keeps one way to hand off work, so Haiku has fewer near-duplicate tools.
- Check it with a ≤ 15-call Haiku eval before the live switch.

## 7. Acceptance tests (offline: GearWorld mock + FakeLLM scripts; no real model calls)
1. **"get a better pickaxe"** (autonomy ladder 1). Claude starts holding a Stone Pickaxe (catalog tool_tier 1). The Director researches (`recipe_tree`) and plans: mine copper and tin → smelt Bronze Bars at the Furnace → craft the Bronze Pickaxe at the Blacksmith's Bench → equip. Each step is done only by its predicate on fresh state. The task ends on `gear_better` from `item_stats` (tier 1 → 3). Milestones reach chat via the Controller, and `goals.json` shows the tree.
2. **Deliberate failure → replan → ask for help.** No tin is in range, and the Controller reports blocked. The fake DEPS replan sends him to another remembered place; that fails again. The caps are hit, one specific help question is said, and the status is `waiting_help`. Then `resume_board(note)` passes the note to the Director.
3. **Trips.** A loop group with a bag-full predicate: 3 loops, verified tallies, then it stops at `tally ≥ N`. A second case stops after 2 zero-gain loops.
4. **Capability gap.** The Director plans `deposit`, which the body lacks. The gap is logged, told once and listed by `tools/board.py gaps`. A `quest` predicate evaluates `null` and becomes a perception gap; the step is never done.
5. **Board.**
   - A player `add_task` with `when=now` preempts the current task, which keeps its state.
   - A CLI inbox `add` is ingested.
   - A self-added prerequisite task is created from the readiness facts and runs first.
   - `board()` answers status.
6. **Claim vs state:** `report_step(done)` with a failing predicate is not done.
7. **Preemption:**
   - a chat command → preempted;
   - no runs while following;
   - 30 s idle → resumed with `resumed: true`;
   - `pause_board` holds until `resume_board`;
   - `cancel_task` ends the task.
8. **Restart:** a new Director over the same `goals.json` continues the active step with its baseline and tallies.
9. **Budget:** the 21st call in an hour is not made, and the board goes to `waiting_budget`. The window slides on a fake clock.
10. **Prep, reflection, knowledge gaps:** a risky step gets a prepare call whose prep steps run first, and `abort_if` stops a run on a vital; a rate drop at a loop end triggers a reflect call and logs a trend line; a plan with unknown facts gets the one nudge, cached facts are recalled without a lookup, and lookups are logged needed/needless.
11. **Unit tests:**
    - every predicate leaf, including `null`;
    - recipe tree: the Bronze Pickaxe chain from real data, the ledger and the alternatives;
    - map memory;
    - readiness and curriculum facts;
    - the gap log.
12. **Held-out generalisation:** a "farm X from creature Y" job and a skill-level job through the same code. `test_principles.py` stays green.
- **Scenario and live:** after main wires the hooks, run ladder 1 on the dev server. Then spend ≤ 15 real Sonnet calls (stated beforehand) on 3 held-out jobs.

## 8. Hooks main needs in files I don't own (small)
1. `Agent.step()`: call `if self.director: self.director.tick()` after `pump()`.
2. `Agent._run_turn`: dispatch the board tool names (`add_task`, `board`, `pause_board`, `resume_board`, `cancel_task`, `report_step`) to `director.handle_tool(name, args, player)`, as `remember` is dispatched today.
3. `Controller._tool_list`: append `director.tool_schemas()`, and add `board` to `read_tools`. Drop `start_goal` while the Director is on (§6).
4. `Controller.context`:
   - `board = director.brief()`: the current task and step, progress and the queue, so normal chat knows them;
   - in board runs, learned-skill retrieval uses the step title.
5. Persona: two or three lines on `board` and the `board_step` / `task_report` / `capability_gap` events. Interim: each event carries its own instructions.
6. A public `Agent.run_directed(event) -> list[action records]` and an `Agent.on_command` notification. Interim: `AgentAdapter` calls `Agent._command(..., body_events=[event])` and wraps `Agent._run_task` per instance to record outcomes.
7. `Agent._review_tick` busy rule: a board run in progress counts as busy. Between runs, reviews (vitals, night) stay allowed.
8. Map-memory feed: `broker.observe(state)` also calls `director.observe(state)`. Interim: the Director observes its own reads.
9. `run_live.py`: build the Director with `planner_llm`, `open_knowledge`, the world state dir and the skill library. Settings: `DW_DIRECTOR=1`, `DW_DIRECTOR_CALLS_PER_HOUR`.

## 9. Coordination
- **Eval agent (agreed):** `brain/predicates.py` is the shared format (`docs/design/eval-benchmark.md` §4). I own the module; the benchmark adds its leaves through `register()` from `evals/bench/leaves.py`. `None` never counts as a pass (the benchmark reports it as unverifiable). `quest` will read `state.quests [{name, stage, completed}]` once the body reports it.
- **Skills agent:** equip (now `llm=false`, "not yet verified"); `bag` and `quests` perception; the gap log as their backlog.

## 10. Unverified / risks
- Equipping tools on the client is unverified (see §9). Live ladder 1 needs it.
- Gathering XP is not in the data (only recipe XP). Skill-level steps rely on `state.skills` deltas and the wiki.
- The ore-rock → item mapping lives in `gather_profiles.lua`. The Director names items; the Controller maps them to `gather` resources with its own tools.
- Wiki drop tables, habitats and quest steps are community text. The Director is told so, and in-game evidence wins (DECKARD's idea: wiki edges are hypotheses).
- Long Controller runs block the agent loop, as today (body actions are synchronous). Only the Director's thinking is off-loop.
