# A slow planner and a fast actor on one long job: what others do, and what to take (2026-11-17)

### Planner and actor working at the same time on a job that survives interruption (2026-11-17)

- Need: a long ask (10 to 30 min: "gear up for the vault", "make a full set of leather armour and wear it", "thirty copper ore in the chest") ends at the first blocker. Death, a full bag or a brain restart lose the ask. The Controller (Haiku) stands while the Planner (Sonnet) composes: first act about 20 s after an ask with the Planner, 7 to 10 s without. Last measured 2026-11-02: `gear_up` 0 of 5, one stand of 138 s (`docs/GOAL-2026-11-17-long-jobs.md`).
- Searched (web, 2026-11-17, several phrasings per area; pages and source files read, not snippets, except where Limits says so):
  - dual-process and fast/slow agents: Talker-Reasoner, HLA, DPT-Agent, real-time reasoning benchmarks, "parallel planning acting", "asynchronous reflection embodied";
  - game agents with long tasks: Voyager, Mindcraft and MineCollab, PIANO / Project Sid, Lyfe Agents, Optimus-1, Cradle, GITM, JARVIS-1, DEPS, Odyssey (the last four from the repo's own note of 2026-10-25);
  - orchestration: plan-and-execute, LLMCompiler, Magentic-One ledgers, Anthropic's harness posts, the advisor strategy, steering and follow-up queues, sleep-time compute;
  - durable execution: LangGraph checkpointers, Temporal, DBOS (the repo's note of 2026-10-29);
  - robotics: SayCan, Inner Monologue, DoReMi, LLM with behaviour trees, Hi Robot, Helix;
  - completion: Voyager's critic, goal predicates, PDDL goals written by a model;
  - the repo first: `docs/design/director.md` section 3, `docs/research/2026-10-25-scalable-agent-frameworks.md`, `2026-10-29-observability-durable-execution.md`, `2026-11-17-stop-with-request-open.md`.

## Found: the ten patterns that matter

Each line of "Rules" judges the pattern against CLAUDE.md section 3 (the model decides; verified state only; open source).

**1. One shared record; the fast model never waits for the slow one.**
- What: the slow model writes a belief and a plan to a shared memory. The fast model reads the latest one each turn and acts. If the slow model has not finished, the fast one works from the raw ask.
- Evidence:
  - HLA (Overcooked, real time, 60 volunteers): macro-action latency 1.07 s against 4.16 s slow-only and 2.30 s fast-only. Human-study scores on four maps: slow-only 80.9 / 33.0 / 102.4 / 60.8, fast-only 92.5 / 57.7 / 103.8 / 71.2, both 114.4 / 100.3 / 130.3 / 117.2.
  - DPT-Agent (Overcooked, real time): mean score with rule partners ReAct 19.77, Reflexion 20.39, DPT-Agent 43.06. With 68 humans, map 2: ReAct 115.00, Reflexion 119.67, DPT-Agent 160.63. The slow side reflects asynchronously and writes a "behaviour guideline" the fast side reads at its next run.
  - Talker-Reasoner (DeepMind): the same split through memory. It names the failure: the Talker acts on a stale belief ("snap judgement"). Its fix is to tell the Talker to wait when the belief says the phase is planning. Qualitative only, no numbers.
- Code: DPT-Agent, MIT (https://github.com/sjtu-marl/DPT-Agent). None found for HLA or Talker-Reasoner.
- Rules: fits. Both sides are models. Code only holds the record.

**2. Two threads and a slot that holds only the latest plan.**
- What: a planning thread and an acting thread run at once. They share one slot. A newer plan overwrites an unread one. The plan is guidance; the actor decides on the freshest observation.
- Evidence:
  - AgileThinker (Real-Time Reasoning Gym, ICLR 2026): scores for reactive-only / planning-only / both: Freeway 0.24 / 0.12 / 0.88, Snake 0.37 / 0.04 / 0.45, Overcooked 0.57 / 0.00 / 0.89. Under time pressure planning-only fell from 0.92 to 0.05, both threads from 0.90 to 0.58. The reactive thread reads the planner's partial, still-streaming output.
  - Parallelized Planning-Acting (Minecraft, live server, Qwen-Plus): a single-slot buffer; the planner returns a new action and an interrupt flag, and only the model decides to interrupt. Plans judged not urgent are dropped unread. Serial against parallel is shown only in figures; the text gives no number.
  - "Reflex first, reflect later" (RRARA, HAZARD with real time charged): the actor keeps acting; an asynchronous reflector returns "still valid" or a replacement. Value rate 0.44 at 0.38 s blocking latency, against GPT-3.5 in the loop 0.25 at 2.54 s and Claude 3.7 Sonnet in the loop 0.07 at 13.05 s (89 % of time spent waiting).
- Code: RealtimeGym, MIT (https://github.com/SALT-NLP/RealtimeGym), a benchmark, not a runtime. None found for the other two.
- Rules: fits when the actor is a model. RRARA's actor is a rule policy; that part is not for us.

**3. Reflexes preempt; the model is told what was interrupted; the goal is on disk.**
- What (Mindcraft, read in source): reflex modes (self-defence, self-preservation, unstuck) interrupt the running action. The model then gets a message: "Your previous action '<x>' was interrupted by <mode>. ... Respond accordingly." The goal is one prompt string with states ACTIVE / PAUSED / STOPPED, saved in `memory.json` and reloaded at start (`handleLoad`). After a death the model is told where it died and that its actions were stopped. Three replies with no command stop the loop.
- Evidence: none measured for these mechanisms. It is the most used open game agent (about 6,000 stars, pushed October 2026).
- Code: MIT (https://github.com/mindcraft-bots/mindcraft). JavaScript on mineflayer: the pattern transfers, the code does not.
- Rules: fits. The message is a true report; the model chooses what to do after it.

**4. A task ledger, a progress ledger and a stall counter.**
- What (Magentic-One): the outer loop writes a ledger (facts known, facts to look up, guesses, the plan as a hint). Each step the inner loop asks: done? looping? progress? who next? what instruction? A stall count above the limit forces a re-plan that rewrites the ledger.
- Evidence: GAIA 38.0 % with o1, 32.3 % with GPT-4o; WebArena 32.8 %. Replacing the ledger orchestrator with a plain group chat cut GAIA validation performance by 31 %.
- Code: MIT in microsoft/agent-framework (`MagenticBuilder`, `max_stall_count`, `max_reset_count`, Python supported). The docs say it is untested outside the original design.
- Rules: the ledger and the counter fit. "Request satisfied" is the model's own claim there; that part does not.

**5. A progress file and pass flags read at every start.**
- What (Anthropic, "Effective harnesses for long-running agents"): a first session writes a list of items, each `passes: false`, and a progress file. Every later session starts by reading them ("getting up to speed"), then works one item. A flag flips only after a test. "Harness design for long-running apps" adds a contract that fixes what "done" is before the work, and an evaluator that tests the running thing, not the claim.
- Evidence: no benchmark. One comparison: solo run 20 min, $9, core feature broken; full harness 6 h, $200, working. Failure modes named: doing it all in one go, declaring victory early, marking done without testing. The research-system post: the lead agent saves its plan to memory; systems must "resume from where the agent was when the errors occurred".
- Code: none to reuse; it is a pattern.
- Rules: fits, and it is the rule "verified state only".

**6. The planner is called by events, and the actor may call it.**
- What: the cheap model drives. The strong one is called when the actor is stuck (Anthropic's advisor strategy), or when a condition the planner wrote stops holding (DoReMi: the plan carries constraints, a detector watches them, a violation re-plans at once), or on a period (Optimus-1's reflector).
- Evidence: Haiku 4.5 with an Opus advisor 41.2 % on BrowseComp against 19.7 % alone; Sonnet 4.6 with an Opus advisor +2.7 points on SWE-bench Multilingual at 11.9 % lower cost. DoReMi: 43 s against 68 s in one demo. Inner Monologue (real kitchen, 120 runs): SayCan 30.8 % total, with success feedback 48.7 %, with object and success feedback 60.4 %; under disturbances SayCan fell to 0 % on two of three task families.
- Code: the advisor is an API tool, not open code, and it is synchronous inside one request. DoReMi and Inner Monologue: no code used.
- Rules: fits. Code decides when a model is asked, never what the answer is.

**7. A revision lands at a model boundary (steering), not by stopping the tool.**
- What: a steering message is queued. It is added after the results of the running tool batch and before the next model call. A follow-up waits until the agent would stop. An interrupt is a separate, explicit act.
- Evidence: product docs and pattern write-ups only (OpenClaw, GitHub Copilot SDK, agentpatterns.ai). No numbers.
- Code: nothing needed; it is where a write is read.
- Rules: fits.

**8. Durable execution: checkpoint at step ends, write intent before a side effect, reconcile after a crash.**
- What: LangGraph saves a checkpoint per step and re-runs whatever came after it. Temporal replays the workflow code against a recorded event history. Both assume a step can be run again safely.
- Evidence: none specific to agents. The repo's note of 2026-10-29 already found: steps are at-least-once, the game is not in the transaction, so save the command's id and intent before dispatch and reconcile against world state.
- Code: LangGraph MIT, Temporal Python SDK MIT, DBOS MIT.
- Rules: the rules fit. A replay engine does not: a craft or a deposit run twice is a real loss.

**9. Done is read from the environment.**
- What: a check against state after each task. In Voyager it is a second model call (the critic). In MineDojo, Crafter and the board here it is a predicate.
- Evidence: Voyager without self-verification found 73 % fewer items, its largest ablation. Inner Monologue as in 6. In this repo a closing tool the model calls (`request_done`) closed the request with the quest still open 5 of 10 times (`2026-11-17-stop-with-request-open.md`).
- Code: `brain/predicates.py` (ours). Voyager is MIT; its critic is a prompt.
- Rules: the predicate form fits. The critic form is a model's claim about state.

**10. A warning about the numbers: most game agents stop the world to think.**
- What: Voyager posts `/pause` to the server around every step (read in `voyager/env/bridge.py`). Cradle pauses the game during calls (the repo's note of 2026-10-25; not confirmed again today).
- Evidence for what real time costs: RRARA in 2 (Sonnet in the acting loop: 13 s blocked per decision). AgenticCache reports over 70 % of run time in planning queries for its baselines.
- So: the headline numbers of Voyager, GITM, JARVIS-1 and Cradle say nothing about acting while thinking. Only patterns 1 and 2 were measured in real time.

## The design for this system

The repo already has most of it in the board and the Director: an ask stored in `goals.json`, steps with predicates checked on fresh state, a decision made on a worker thread over a snapshot and applied only if `plan_key` is unchanged, a progress budget, preempt and resume. The default path (`_open_request`, `task_tree.json`, `Planner.plan` called in line) has none of the persistence and none of the checks. The literature points at one record, so it points at the board. That does not replace the trial of I3 and I5 the goal asks for.

| Question | Design | Where it lives |
|---|---|---|
| What is the one record? | The job: the player's words, who and when, a success predicate, the plan as steps with their own predicates, each step's state and last reason, notes, what was taken and stored. | `brain/board.py` (`Task`, `Step`). Today the ask is only `_open_request` in memory (`brain/agent.py:524`). |
| What does the planner write? | The success predicate once, at the ask (pattern 5's contract). Then steps, each with `success`, `abort_if` and `why`. On a revision: the new steps and one line saying what changed and why. | `brain/director.py` `_dispatch` (`:1203`), `_collect_decision` (`:1327`). |
| What does the actor read each turn? | The ask in the player's words, the end condition and how far it is ("12 of 30 in the chest"), the current step and its why, the state of the plan (being composed / landed / being revised since <event>), the last revision line, the last interruption. | `brain/controller.py` `context()` already carries `board: director.brief()` (`:628`). |
| What does the actor do while the planner thinks? | It acts. The step run is given the ask itself and the honest note "the plan is being composed". The model chooses: start on what is plainly next, look something up, or say it is waiting and why (patterns 1 and 2). | Gap: `brain/director.py:1144` returns while a decision is pending, so no step runs. `brain/agent.py:1207` calls `planner.plan` in line. |
| How does a revision land? | One atomic write to the board. The next Controller call reads it in the brief and sees one event line ("plan revised: ..."). The running body command is not stopped (pattern 7). A newer revision replaces an unread one (pattern 2). At landing, code checks each step's predicate on fresh state and marks what is already true as done. The planner may ask for a stop of the running command, with a reason; default is no. | `_collect_decision` and `plan_key` exist. New: the event line, the check at landing, a count of revisions that arrived after their step. |
| When is the planner called? | At the ask. When a step failed twice or the progress budget is spent (pattern 4). When the world left the plan: death, full bag, over weight, restart, an `abort_if` that became true (pattern 6). When the actor asks. Never on a clock. | `PROGRESS_BUDGET` (`brain/board.py:63`), `Step.abort_if`, `budget.allows("director")`. |
| Who decides the job is done? | Code, from the job's predicate on fresh state. The planner writes the predicate; the report states which predicate was checked. A turn with no call does not close the job: the next step run says truthfully what is still open. The model may park the job, and says why. | `brain/predicates.py`, `BoardOps.park` (`brain/board.py:454`). Today the ask closes on any turn that calls nothing (`brain/agent.py:670`). |
| What is on disk, and when? | The ask: when the line is heard, before any model call. The plan: at each landing. Step state: at each step end. A body command with a side effect: its id and intent before dispatch. The event log stays append-only. | `goals.json` (atomic). `progress.jsonl` in `brain/state_store.py`. `task_tree.json` is the second store; it goes with whichever holder loses the trial. |
| Death | The step is preempted, not failed, and no re-plan is spent. After the respawn the actor gets a message: the open job, what killed him, where the grave is. The planner is asked for a revision at the same time. Grave first or job first is the model's choice. | `BoardOps.preempt` / `resume` (`brain/board.py:491`, `:469`). Today: `Reason.DETERMINISTIC`, two re-plans, stuck (`brain/interface.py:93`). |
| Full bag, over weight | The same shape: a message with the true options (his chests by a key that survives a relaunch, what he carries, what the job still needs). The job stays open. | `brain/needs.py:399`, `brain/stash.py:96` (both listed as broken in the goal doc). |
| Brain restart | At start the board is read. An active job is marked preempted with the reason "brain restarted". Fresh state is read; step predicates are checked; a command whose intent was saved and whose effect is unknown is reconciled from the game, not run again. The actor's first turn says: you were doing this for <player>, asked <time> ago, this is done, this is next. The model may decline, and says so. | `brain/state_store.py:126` reads a tree nothing resumes. The board's load is the path to keep. |
| A fight | As now: the reflex fights, the command is suspended and resumed. The count of interruptions is shown to the model; it does not end the job by itself. | `brain/agent.py:1223` ends the goal after 5. |

## Decision: adapt. Most valuable first, each with its measure

1. **Adapt (Mindcraft, Anthropic progress file): the ask on disk at the moment it is heard, read back at start with a "where you were" turn.** Measure: I5, he takes up the ask after a restart with no new line from the player, k of 5, and the seconds from start to his first act on it. Today 0 by construction.
2. **Adapt (Mindcraft's interruption message; the board's preempt): death and a full bag are interruptions with a true message, not failed steps.** Measure: I3 and I4 pass counts and seconds to resume; jobs ended "stuck" after a death go to 0.
3. **Build, small (HLA, DPT-Agent, AgileThinker): the actor runs while a decision is pending.** Remove the wait at `brain/director.py:1144` for a job whose plan is being composed; give the step run the ask and the note. Measure: seconds from ask to first act (20 s now; the bar is the 7 to 10 s of a turn with no Planner), seconds standing while a plan is composed, and misses per job against the waiting arm (`tools/ab`). If misses rise, Talker-Reasoner's finding holds here and the note must say more, not the code.
4. **Adapt (steering queue; single slot): a revision lands as a board write and one event line, and is checked against fresh state at landing.** Measure: body commands stopped by a landing (0), revisions that arrived after the step they were about (count and share), `director_discarded` per job.
5. **Reuse (ours; Magentic-One's stall counter, DoReMi's constraints): the planner is called by events only.** Measure: Planner calls per job and their cost; no stand over 5 s at a stall.
6. **Reuse (ours; Anthropic's contract): the end condition is written at the ask and checked by code.** Measure: reports of "done" with the predicate false (0); L1 to L3 ending with the predicate true; the count of jobs where the predicate had to be revised.
7. **Adapt (the note of 2026-10-29): intent before dispatch, reconcile after a restart.** Measure: side effects repeated after I5 (a second craft, a second deposit): 0.

No framework is adopted. The parts that carry the result are small and are ours already; a second state store beside `goals.json` is the thing the earlier note warned against.

### Built for item 3, on the default path (2026-11-17, behind `DW_ASYNC_PLAN=1`, default off)

- Where: `brain/plan_async.py`, `brain/agent.py` `_plan_in_background` (plan and replan), the context key `planner` (`brain/controller.py`). Tests: `tests/test_async_plan.py` (a FakeLLM Planner that blocks on a gate).
- How: the Planner call goes to a worker (`ThreadPoolExecutor`, as the Director's); the agent loop keeps pumping, so body events and chat are heard, and the Controller gets one turn in the goal's own episode with the fact `plan_pending` (patterns 1 and 2). A plan that lands while his chain runs is told on his next turn (pattern 7) and starts when the chain ends. At the start it is checked on fresh state: stale only when he died since its state was read or its first step's own effect is already true (PlanFence, arXiv 2609.03340: check what the next action depends on, not freshness). A stale plan is not started; it is shown to him with its steps and why, and he chooses. Moving, bag changes and a fight are reported as drift.
- Rows: `plan_started {plan_kind, goal, basis}`, `acted_while_planning {n, tools}`, `plan_arrived {age_s, composed_s, stale, why, drift, applied, shown}`, `plan_abandoned {age_s}` (the job replaced meanwhile). `tools/think_act.py` reads them: an async composition runs from `plan_started` to `plan_started + composed_s`; its gap is the longest stand from the last command's end before it to the first command after it.
- The window that judges it: the gap around a plan over 5 s, 99 % in the waiting arm; `tools.ab need 0.99 0.5` = 12 compositions per side (24 for 99 % against 70 %). Misses per job are counted on both arms beside it (Talker-Reasoner's warning).

### The Planner's research inside the background plan (2026-11-18, ported onto f51fa70)

The research loop (up to 4 read-only calls: lookup, recall, craft_plan, buildables) runs inside `Planner.plan`/`replan`, so it runs on the worker unchanged. What was checked for that:

- **Inputs:** the worker got the loop's own objects (the executor's cached state, shallow-copied by `with_asked`; the task tree for a replan), which the loop keeps reading and changing while his turn runs. Now one `deepcopy` of state, notes, tree and failed task is made on the loop before submit (`Agent._snapshot`; one copy for all, so `t is not failed` still holds), and the plan's basis is a copy too.
- **Knowledge index:** one sqlite connection for all threads (`check_same_thread=False`) under a lock, but `kinds()` (asked for every research tool list, through the lookup schema), `_meta()` and `stats()` ran without it. All three take the lock now. The Director's worker had the same exposure.
- **Logger:** safe as it is: the episode and scope ids are thread-local and writes are under a lock; the worker stamps the goal's episode on its rows (`plan_async.submit`).
- **Facts for recall:** read from `knowledge_memory.json`, written by `atomic_write` (temp file and `os.replace`); a failed read gives no facts, never a broken plan.
- **Body reads (craft_plan, buildables):** the bridge has one owner, the loop. A worker's read queues on `BodyProxy` and was served only in `Agent.pump`, so a read queued while Haiku's first step ran waited out the 20 s and came back "the body is busy right now; plan without it", which named the wrong cause (the body was walking fine; the loop was in his turn). A read the loop had just started was also dropped as busy. Now: under `DW_ASYNC_PLAN=1` the loop also serves the queue between his tool calls and inside every body wait (`BridgeClient.wait_hooks`, a nested request as the heartbeat ping already is; the wait wakes every 0.25 s for it, and only with the flag on); the client mod answers reads beside a running action (`client_bridge.lua`: only action tools pre-empt). What can still hold a read is his model call; past `plan_async.READ_WAIT_S` (10 s) the read is answered "not read" with what held the loop (`Agent.loop_holder`: his model call and for how long, body calls in flight, or the loop's own work), and nothing is sent. A read already sent is waited for. Row: `body_read_queued {component, tool, waited_s, served_in: pump | turn | body_wait | null, answered, busy_with}`; `tools/think_act.py` counts them under the compositions.

## Not taken

- **Stopping the world while he thinks** (Voyager, Cradle). The server is live and Luis is on it.
- **A model that judges "done"** (Voyager's critic, Magentic-One's "request satisfied", Inner Monologue's stop action). Our own trial closed wrongly 5 of 10, and the rule is verified state.
- **A planner that streams without pause, read mid-sentence** (AgileThinker). About 8,000 tokens per step, all the time. Not inside $10 a day. Its lesson (the plan is guidance, the actor reads the latest) is taken.
- **The advisor tool as built.** It runs inside one request, so the actor waits for it, which is the fault being removed. Published numbers pair it with Opus. The idea (the actor may call the planner) is kept through the tools the Controller already has.
- **Temporal, DBOS or LangGraph as the runtime.** Replay re-runs steps; game side effects are not safe to repeat; each adds a store, and Temporal a server. Their rules are taken (pattern 8).
- **Microsoft's Magentic orchestration.** A strong-model progress call every round, and completion by claim. The ledger shape and the stall counter are taken.
- **A cache of plan-to-plan transitions** (AgenticCache: 22 % higher success, 65 % lower latency, 50 % fewer tokens across 12 set-ups). It learns a table of what follows what. One body gives little repetition, and the table sits close to a task recipe. Its code states no licence. Worth a second look for the skill library.
- **Code as the fast policy** (DPT-Agent, Voyager). Generated code near the client is a native-crash risk (decided 2026-10-25, lesson L3).
- **A rule policy as the actor** (RRARA). That is a hardcoded recipe. Lua keeps only the survival reflexes.
- **PDDL goals and a classical planner.** A hand-written domain is task recipes in another language. The predicate set is already the goal language.
- **A behaviour tree written by the model** (BETR-XP-LLM and follow-ups). Read only in summaries; the Lua tree is the reflex layer, not the job layer.
- **Sleep-time compute** (Letta: about 5 times less compute at equal accuracy). Measured on maths questions, not on an acting agent. Not now.
- **PIANO's code.** The repository has no licence.

## Limits

- **Searches that found nothing:** a measured result for a job that survives a process restart or the agent's death in any embodied LLM agent (Mindcraft has the mechanism, no number); any measurement of Haiku with Sonnet in this split; a number for steering queues; code for Talker-Reasoner, HLA, Lyfe Agents, Parallelized Planning-Acting and RRARA; a primary page that says Cradle pauses the game; SayCan's own headline numbers.
- **One source each:** every number above comes from its own paper, on other models (GPT-3.5, GPT-4o, DeepSeek, Qwen). DoReMi's 43 s against 68 s is one demo video. HLA and DPT-Agent are both Overcooked.
- **Read only as search extracts or summaries:** Optimus-1's reflector; the PDDL translation accuracy figures; Helix's 7 to 9 Hz; arXiv 2606.15684 (real-time Minecraft collaboration, calls of about 20 s going stale); the behaviour-tree papers.
- **Inferred, not stated:** how DPT-Agent hands a new guideline to the running policy; that LangGraph nodes with side effects must be idempotent; that Temporal does not re-run a recorded activity on replay (the page read does not say it in words). LLMCompiler dispatching tasks while its planner still writes was not confirmed.
- **Talker-Reasoner points the other way on one thing:** for a planning phase it makes the fast side wait. In a dialogue a wrong sentence cannot be taken back; in the game the first acts of a long job (walk to base, open a chest, look a recipe up) are cheap. That is an argument, not a measurement. Item 3's A/B is the measurement.
- **Repo reading:** `brain/agent.py`, `director.py`, `board.py`, `controller.py` were read in part. Not checked: exactly what `plan_key` hashes (it must not go stale because the actor finished a step), and whether `next_turn` re-reads the board brief inside one run or only `context()` at its start. Nothing was run.
- **Licences** were read from the GitHub API on 2026-11-17: Voyager, Mindcraft, DPT-Agent, RealtimeGym, LangGraph, Temporal's Python SDK, DBOS, agent-framework: MIT. Letta: Apache-2.0. Project Sid, GITM, JARVIS-1, MC-Planner: none. AgenticCache: not stated. pi-mono: not confirmed.

## Sources

- Dual-process and real time: https://arxiv.org/abs/2410.08328 , https://arxiv.org/html/2312.15224v2 , https://sites.google.com/view/overcooked-hla , https://arxiv.org/html/2502.11882v1 , https://github.com/sjtu-marl/DPT-Agent , https://arxiv.org/abs/2511.04898 , https://github.com/SALT-NLP/RealtimeGym , https://arxiv.org/abs/2503.03505 , https://arxiv.org/abs/2506.07223 , https://arxiv.org/abs/2604.24039 , https://github.com/hojoonleokim/MLSys26_AgenticCache , https://arxiv.org/abs/2606.15684
- Game agents: https://arxiv.org/abs/2305.16291 , https://github.com/MineDojo/Voyager/blob/main/voyager/env/bridge.py , https://github.com/MineDojo/Voyager/blob/main/voyager/agents/critic.py , https://github.com/mindcraft-bots/mindcraft/blob/develop/src/agent/self_prompter.js , https://github.com/mindcraft-bots/mindcraft/blob/develop/src/agent/modes.js , https://github.com/mindcraft-bots/mindcraft/blob/develop/src/agent/history.js , https://arxiv.org/abs/2504.17950 , https://arxiv.org/abs/2411.00114 , https://github.com/altera-al/project-sid , https://arxiv.org/abs/2310.02172 , https://arxiv.org/abs/2408.03615 , https://arxiv.org/abs/2403.03186
- Orchestration: https://arxiv.org/abs/2411.04468 , https://learn.microsoft.com/en-us/agent-framework/user-guide/workflows/orchestrations/magentic , https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents , https://www.anthropic.com/engineering/harness-design-long-running-apps , https://www.anthropic.com/engineering/multi-agent-research-system , https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents , https://claude.com/blog/the-advisor-strategy , https://agentpatterns.ai/patterns/agent-design/steering-running-agents/ , https://docs.openclaw.ai/concepts/queue-steering , https://docs.github.com/en/copilot/how-tos/copilot-sdk/use-copilot-sdk/steering-and-queueing , https://arxiv.org/abs/2312.04511 , https://arxiv.org/abs/2504.13171
- Durable execution: https://docs.langchain.com/oss/python/langgraph/checkpointers , https://docs.temporal.io/workflow-execution , https://github.com/dbos-inc/dbos-transact-py
- Robotics and completion: https://arxiv.org/abs/2207.05608 , https://sites.google.com/view/doremi-paper , https://arxiv.org/abs/2307.00329 , https://arxiv.org/abs/2502.19417 , https://figure.ai/news/helix , https://arxiv.org/abs/2409.13356 , https://arxiv.org/abs/2302.05128 , https://arxiv.org/abs/2407.03321
