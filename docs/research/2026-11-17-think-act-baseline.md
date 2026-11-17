# Think and act: the baseline before the actor runs while the Planner composes (2026-11-17)

Asked: the goal's "two models on one job" (`docs/GOAL-2026-11-17-long-jobs.md`) and the research note's Decision item 3 (`docs/research/2026-11-17-long-jobs-planner-actor.md`) name four measures. Nothing computed them. `tools/think_act.py` now does, from the brain's own log rows, with no model call and nothing sent to the game. Tests: `tests/test_think_act.py` (15, on rows cut from real logs).

```
.venv\Scripts\python.exe -m tools.think_act report --since 2026-11-14 --until 2026-11-17T14:00
.venv\Scripts\python.exe -m tools.think_act report --since 2026-11-01T20:00 --until 2026-11-02T12:00 --grep "gear up properly|sort your bag out"
.venv\Scripts\python.exe -m tools.think_act ask 20261115-235756-19752/chat-0001-52b5
```

## The answer in four numbers (14 to 17 Nov, 276 asks)

| measure | n | median | p90 | worst |
|---|---|---|---|---|
| 1. ask to first act, all asks | 276 | 2.34 s | 3.30 s | 27.84 s |
| 1. ask to first act, the Planner composed before any act | 4 | 17.2 s | 27.8 s | 27.8 s |
| 2. standing while a plan is composed, per Planner composition | 100 | 4.75 s | 9.30 s | 22.69 s |
| 2. the whole stand around a plan (last command's end to the next command) | 93 | 7.84 s | 10.62 s | 22.19 s |
| 3. Planner API calls per ask that used it | 73 | 1 | 3 | 4 |
| 4. plans that landed stale | 3 of 99 landed (3 %, 95 %: 1 to 9 %); state known for 69 | | | |

In words. When the Controller acts first (69 of 73 Planner asks, 95 %), his first act comes in about 2.5 s. When the Planner composes first, it comes in 14 to 28 s (4 asks, all the house ask): the goal's "about 20 s" holds for that shape only. Around every plan he stands: 92 of 93 gaps (99 %) are over the 5 s bar. Plans almost never land stale today because nothing moves while he waits; the measure starts to matter once he acts during a composition.

On the Director runs of 2 Nov (gear up) the same stand is five times longer: 25.4 s median per composition (n=17), 357.5 s in one ask.

## 1. The rows each measure reads

| what | row kind | written at | note |
|---|---|---|---|
| a line heard | `event` with `event.type == "chat_heard"` | `brain/run_live.py:267` | the ask's time. Its episode id (`chat-...`) is stamped on every row of that run and of a goal run inside it |
| the line's routing | `chat_decision` (`addressed`, `pending`, `merged`, `ignored`) | `brain/run_live.py:171`, `brain/agent.py:547`, `:551` | `ignored` alone: not an ask |
| Controller call start | `prompt`, `component: controller` | `brain/controller.py:846` | a repair round has no prompt row |
| Controller call end | `llm_response`, `component: controller`; `usage.latency_ms`, `cost_usd`, tokens | `brain/controller.py:852`; usage from `brain/llm.py:257` and `:280` (`_call_meta`, `:186`) | the tool takes the start as `ts - latency_ms`, i.e. DERIVED; the prompt row is the fallback |
| Planner call start | `prompt`, `component: planner` (full messages; a replan's user message carries `failed_task`) | `brain/planner.py:128` | the plan is asked for in line: `brain/agent.py:1207` (plan), `:1240` (replan) |
| Planner call end | `llm_response`, `component: planner`, usage as above; `plan_invalid` between repair rounds | `brain/planner.py:139`, `:133` | a repair round has no prompt row; its start is derived from `latency_ms` |
| Director composition | `director_dispatch` (start), `prompt`/`llm_response` `component: director`, then `director_decision` / `director_discarded` / `director_decision_failed` / `director_timeout` (end) | `brain/director.py:1222`, `:1301`, `:1290`, `:1376`, `:1355`, `:1366`, `:1333` | Director rows carry no episode id, or `director-...`; its steps run in `board-...` episodes |
| body command sent | `tool_call` with `task_id` | `brain/executor.py:495` | read-only tools are `tool_call` with `read_only: true` and no `task_id` (`brain/controller.py:986`): not acts |
| body command result | `tool_result` with `task_id` | `brain/executor.py:510` | |
| a command left running | `action_left_running`, then `bridge_late_result` | `brain/broker.py:358`, `brain/bridge_client.py:351` | |
| the reflex's own fights | `event` with `event.type == "activity"`, `combat_started` / `combat_end` | `brain/agent.py:295` | |
| state reads | `bridge_send` `tool: get_state` and its `bridge_recv` (position, inventory, fight, dead) | `brain/bridge_client.py:176`, `:230` | |
| line said | `say`, `say_result` | `brain/controller.py` say path | measure 1 reports the first `say_result ok` beside the act |
| goal start, goal done, replan | not in the brain log | `brain/agent.py:1197`, `:1244`, `:1257` write `state/.../progress.jsonl` | the brain log has only the Planner's prompt rows; the replan flag is read from `failed_task` in the prompt |
| request end | `request_state` | `brain/run_live.py:246` | used only to close a planner composition that produced nothing |

## 2. What already measured part of this, and what was reused

| tool | what it has | used here |
|---|---|---|
| `tools/quest_run.py` `timeline()` | busy = tool running, model call in flight, or reflex work; idle stretches over 5 s | its idea of reflex intervals (`*_started` to `*_end`) is taken. It merges model time into busy, so it cannot say "standing while planning"; not imported |
| `tools/session_report.py` `Brain` | per-file episodes, LLM calls paired prompt to response, tool calls with results, positions | not imported: it drops repair-round responses (no prompt row), carries no `latency_ms` or cost, and reads the whole log with payloads |
| `tools/chat_ladder.py` `model_calls`, `tools/spend.py` `price` | calls, tokens and $ per window | not needed: every `llm_response` since 1 Nov carries `cost_usd` from LiteLLM |
| `tools/turn_latency.py` | line heard to first response, one file | the same start; its "first response" counts a line said, which this measure must not |
| `tools/timeline.py`, `tools/perf_report.py`, `tools/coplay_ladder.py`, `evals/` | merged timelines, lag, rung 2 scoring | nothing on planner and actor overlap |
| `tools/ab.py` | `need`, `one`, `two` | used for every proportion below; `think_act.need_mean` adds the two-sample count for a time |

## 3. Definitions (the code's docstring has them in full)

- **Ask:** a `chat-` episode with a player's line heard, a Controller call, and not only `ignored`. Its time is the first line heard.
- **Window:** from the ask to the next ask in the session or the session's end, cut back to the last row that belongs to an episode or the Director. A quest_run trial session ends when the harness ends it.
- **Act:** a `tool_call` with a `task_id` in the ask's own episode or a `board-` episode. `set_vitals_policy` is not an act. A line said is not an act.
- **Body running:** a command from its `tool_call` to its `tool_result`, a command left running to its late result, a reflex fight or flight.
- **Composition:** a planner prompt to its last `llm_response` (repairs included), or a Director dispatch to its decision.
- **Stand while planning:** seconds of a composition with no body running. **Whole gap:** from the end of the last body work before the composition to the next command after it (only where no body ran during it).
- **Stale** (measure 4): between the last state read at most 60 s before the composition began and the first read after it landed (before the next command, at most 15 s), any of: moved more than 20 m; a non-consumable item's count changed (food and drink alone are "bag_minor", not counted: the reflex eats); a fight started (a `combat_started` inside the composition, or `fight` set at landing); he died; the plan's first step was already done (its first command answered "already ..." or was a go_to whose target was within 3 m).

## 4. Baseline, 14 to 17 Nov (to 14:00 UTC on 17 Nov)

Sample: 276 asks in 276 brain sessions. All are harness trials on the dev world (`quest_run step` and the house ask), all from "Tester". 73 used the Planner (26 %), 203 did not. No Director run in this window. Asks: "go and see Vannaka" 85, "Zanik" 64, "Doric" 55, "Wise Old Man" 24, grave 18, stone 13, house 11, others 6.

### Measure 1: ask to first act

| asks | n | median | p90 | worst | first act within 10 s |
|---|---|---|---|---|---|
| all | 276 | 2.34 s | 3.30 s | 27.84 s | 272 of 276 (99 %) |
| with the Planner | 73 | 2.66 s | 3.74 s | 27.84 s | 69 of 73 (95 %) |
| without | 203 | 2.27 s | 3.23 s | 7.04 s | 203 of 203 (100 %) |
| the Planner composed before any act (house ask) | 4 | 17.2 s | 27.8 s | 27.8 s | 0 of 4 |
| first act after the first plan landed | 70 | 37.45 s | 45.37 s | 339.09 s | (mostly a walk first, then a goal) |
| first line said (not an act) | 272 | 2.81 s | 4.96 s | 181.17 s | |

The four plan-first asks: 27.84 s, 17.39 s, 17.09 s, 14.19 s (mean 19.1 s, SD 5.98 s). In the other 69 Planner asks the Controller walked or talked first and queued a goal later.

### Measure 2: standing while a plan is composed

| unit | n | median | p90 | worst | over 5 s |
|---|---|---|---|---|---|
| per composition, stand | 100 | 4.75 s | 9.30 s | 22.69 s | 44 of 100 (44 %) |
| per composition, idle before it began | 96 | 3.04 s | 4.00 s | 9.64 s | |
| per composition, whole gap | 93 | 7.84 s | 10.62 s | 22.19 s | 92 of 93 (99 %) |
| per Planner ask, stand summed | 73 | 4.42 s | 15.05 s | 46.84 s | 29 of 73 (40 %) |

A body command ran during 2 of 100 compositions (2 %). The Controller's turn that queued the goal is most of the "idle before".

### Measure 3: calls, latency, tokens, cost

| | n | median | p90 | worst | total |
|---|---|---|---|---|---|
| Planner compositions per Planner ask | 73 | 1 | 3 | 3 | 100 (72 plans, 28 replans) |
| Planner API calls per Planner ask | 73 | 1 | 3 | 4 | 100 |
| Planner API latency | 100 | 4.81 s | 9.30 s | 16.14 s | |
| Planner prompt tokens per call | 100 | 15,893 | 17,747 | 19,016 | 1.57 M, of which 0.26 M cached (17 %) |
| Planner completion tokens per call | 100 | 558 | 1,108 | 2,096 | 64,299 |
| Planner $ per Planner ask | 73 | 0.05 | 0.09 | 0.15 | $3.95 |
| Controller calls per ask | 276 | 8 | 15 | 34 | 2,289 |
| Controller API latency | 2,289 | 1.30 s | 2.17 s | 7.75 s | |
| Controller $ per ask | 276 | 0.01 | 0.02 | 0.03 | $2.29 |

### Share of each ask's wall time

| asks | wall | body running | Controller thinking | Planner thinking | learner | nothing | body and Planner at once |
|---|---|---|---|---|---|---|---|
| all (276) | 47,880 s | 79.2 % | 6.7 % | 1.1 % | 0.2 % | 12.8 % | 0.0 % |
| with the Planner (73) | 24,043 s | 79.0 % | 5.3 % | 2.3 % | 0.4 % | 13.1 % | 0.0 % |
| without (203) | 23,838 s | 79.4 % | 8.1 % | 0 % | 0 % | 12.5 % | 0 % |

A second counts in the first class it belongs to, in this order: body and Planner at once, body, Controller, Planner, learner, nothing. "Learner" is the Sonnet call that saves a finished goal as a skill (`brain/skill_library.py:451`); it also runs while he stands. "Nothing" (12.8 %) is time with no command, no model call and no reflex fight: the brain's own plumbing between calls and the harness's tail.

### The ten worst stands while a plan was composed

| stand | file | UTC | composition | what he did next |
|---|---|---|---|---|
| 22.7 s | 20261115-235756-19752 | 2026-11-15 22:58:09 | plan, 2 calls (a repair) | deconstruct BuildingPiece_282, ok |
| 16.1 s | 20261116-020057-17668 | 2026-11-16 01:01:52 | plan | build, failed unknown_target |
| 12.9 s | 20261116-020057-17668 | 2026-11-16 01:02:10 | replan | build, failed unknown_target |
| 12.7 s | 20261115-235756-19752 | 2026-11-15 23:02:18 | replan | deconstruct BuildingPiece_293, ok |
| 11.4 s | 20261115-235756-19752 | 2026-11-15 23:02:45 | replan | go_to [168, 1874, -30], ok |
| 11.1 s | 20261116-040510-12504 | 2026-11-16 03:05:25 | plan | deconstruct BuildingPiece_561, ok |
| 10.9 s | 20261116-013808-18780 | 2026-11-16 00:39:52 | replan | build, failed unknown_target |
| 10.7 s | 20261116-013808-18780 | 2026-11-16 00:38:23 | plan | set_vitals_policy, ok |
| 9.7 s | 20261116-040510-12504 | 2026-11-16 03:07:14 | replan | build Crafting Table, ok |
| 9.4 s | 20261116-020057-17668 | 2026-11-16 01:02:59 | replan | build, ok |

All ten are the house ask. Per ask the worst is 46.84 s (20261115-235756-19752: three compositions). Three of the ten were followed by a build that failed at once.

### Measure 4: stale plans

3 of 99 landed plans (3 %; Wilson 95 %: 1 to 9 %). On the 69 whose states were read: 3 of 69 (4 %; 1 to 12 %). Reasons: first step already done 2, fight 1. Moved, bag and death: 0.

| file | UTC | what | why stale |
|---|---|---|---|
| 20261116-062404-15380 | 2026-11-16 05:25:12 | replan (5.5 s) in the Zanik quest | its first step `explore` answered `already_in_sight`: the target was in view when it landed |
| 20261117-051900-408 | 2026-11-17 04:24:17 | plan (5.0 s) in the Zanik quest | a reflex fight began during the composition; the first command, gather 1 ash, was `interrupted` |
| 20261117-100019-22220 | 2026-11-17 09:02:50 | replan (4.6 s) in the Doric quest | first step go_to [109.1, 1848.2, -32.1]: he already stood within 3 m of it |

Today staleness is low by construction: the body waits while the plan is composed. The rule exists for the arm where he acts during a composition.

## 5. Baseline, the gear-up and bag runs of 2 Nov

Six trials: five "claude get all your stuff together and gear up properly", one "claude you're carrying too much, sort your bag out". The last two gear-up runs used the Director (the board); the first three and the bag run did not use a planner at all.

| file | UTC | ask | first act | first line | Planner compositions | stand while planning | Planner $ | Controller calls | window |
|---|---|---|---|---|---|---|---|---|---|
| 20261102-003236-16800 | 2026-11-01 23:32:48 | gear up | 5.94 s go_to | 4.77 s | 0 | 0 | 0 | 7 | 424 s |
| 20261102-005154-15372 | 2026-11-01 23:52:07 | gear up | 9.58 s craft | 13.27 s | 0 | 0 | 0 | 5 | 14 s |
| 20261102-013020-15324 | 2026-11-02 00:30:31 | gear up | 4.04 s equip | 5.77 s | 0 | 0 | 0 | 5 | 117 s |
| 20261102-013447-12840 | 2026-11-02 00:34:53 | bag | 6.82 s build | 8.84 s | 0 | 0 | 0 | 5 | 39 s |
| 20261102-023341-8528 | 2026-11-02 01:33:54 | gear up | 4.99 s consume | 5.74 s | 4 (Director) | 149.7 s | 0.51 | 20 | 1,012 s |
| 20261102-031731-15808 | 2026-11-02 02:18:00 | gear up | 70.96 s go_to | 3.72 s | 13 (Director) | 357.5 s | 1.55 | 32 | 942 s |

(Two windows are short because the session ended there.) Summary over the six:

| measure | n | median | p90 | worst |
|---|---|---|---|---|
| ask to first act | 6 | 6.38 s | 70.96 s | 70.96 s |
| Director composition, stand | 17 | 25.42 s | 50.54 s | 51.30 s |
| Director composition, whole gap | 16 | 44.53 s | 72.39 s | 72.39 s |
| Director API latency | 65 | 3.67 s | 18.05 s | 27.73 s |
| Director prompt tokens per call | 65 | 28,048 | 34,474 | 38,441 |
| Director API calls per composition | 17 | 4 | 5 | 6 |
| Director $ per composition | 17 | 0.11 | 0.16 | 0.18 |

All 17 compositions (100 %) stood over 5 s. A body command ran during 1 of 17. Stale: 0 of 16 landed; one "bag_minor" (the reflex ate). Compositions: 7 plan, 5 replan, 3 prepare, 2 review; 16 landed, 1 timed out (90.2 s).

Share of wall time over the two Director asks (1,954 s): body 63.4 %, Planner 24.5 %, Controller 5.1 %, nothing 6.7 %, learner 0.2 %, both at once 0.1 %.

Worst stands on 2 Nov: 51.3 s (20261102-023341-8528, 01:49:50 UTC, 6 calls, then interact with the grave: path_blocked), 50.5 s (20261102-031731-15808, 02:29:07, then deconstruct the spinning wheel), 43.1 s (023341, 01:35:37, then gather 16 ash), 40.3 s (031731, 02:32:13, then deconstruct: verification_failed), 39.4 s (023341, 01:38:28, then drop weeds). In 031731 he stood 357.5 s of 942 s (38 %) while the Director composed, across 13 compositions and 49 Sonnet calls.

## 6. What the first change should move

The change (Decision item 3): the Controller keeps acting while a plan is composed, with an honest note that it is.

**The number:** the whole gap around a plan, per composition. Baseline (14 to 17 Nov): n = 93, median 7.84 s, mean 8.33 s, SD 2.57 s; 92 of 93 (99 %) over the 5 s stand bar. With the change, where something is plainly next, the gap should fall to about one Controller turn (median 1.30 s) plus a dispatch. The second number to watch is "body and Planner at once" in the share table: 0.0 % now.

**Smallest effect worth detecting:** 3 s (8.3 s to 5.3 s, which crosses the 5 s bar).

Time, two-sample count, two-sided 5 %, power 80 %:

n = 2 (z0.975 + z0.80)^2 SD^2 / delta^2 = 2 (1.960 + 0.842)^2 (2.57)^2 / 3^2 = 2 x 7.849 x 6.605 / 9 = 11.5, so **12 compositions per arm**.

The same as a proportion (gap over 5 s, from 99 % to 50 %): `python -m tools.ab need 0.99 0.5` gives **12 per side**. From 99 % to 70 %: 24 per side.

Compositions in one ask are not independent (1.37 per Planner ask). Counting asks instead, the per-ask stand while planning (n = 73, mean 7.51 s, SD 8.09 s) is skewed; on a log scale its SD is 0.679. Halving it is delta = ln 2 = 0.693:

n = 2 x 7.849 x 0.679^2 / 0.693^2 = 2 x 7.849 x 0.461 / 0.480 = 15.1, so **16 asks per arm**. On the raw scale halving needs 73 per arm.

First act for asks where the Planner composes first: 4 asks, mean 19.1 s, SD 5.98 s. To the 7 to 10 s bar (8.5 s), delta = 10.6 s: n = 2 x 7.849 x 35.8 / 112.4 = 5.0, so 5 per arm. An SD from 4 values is weak: plan 8.

**What that means for the trials:** 16 Planner asks per arm, about 22 compositions, covers all three. In the quest mix only 73 of 276 asks (26 %) call the Planner, so that mix needs about 62 trials per arm. Asks that always call it are cheaper: the house ask called it in 6 of 11 trials, and L1 to L3 (long jobs) should every time. Run the measure on both arms with the same `--grep`. The research note also asks for misses per job against the waiting arm; that count is not covered here and needs its own `tools.ab need` once its rate is known.

## 7. What the logs cannot say, and two rows that would make measures 2 and 4 exact

Cannot say:

1. **The state at landing.** In 30 of 99 landed plans (30 %) no state was read between landing and the next command (the executor reuses a cached read, `brain/executor.py:291`), so measure 4 is unknown for them.
2. **The state a plan was made on** is in the planner's prompt, not in a row of its own. The tool uses the last `get_state` read before the prompt; in every case seen that read is the one the plan used, but nothing ties them.
3. **"Its first step was already done"** is a proxy (an "already" result, or a go_to target within 3 m). No row says whether the first step's predicate was already true at landing.
4. **Why the Planner was called.** Plan and replan are told apart by `failed_task` in the prompt text. A goal's start and end are in `progress.jsonl`, not in the brain log.
5. **Body time** is the brain's view (tool_call to tool_result). The body's own start and end are in the mod logs, offset by the bridge round trip (about 0.5 s).
6. **Where a Director composition belongs.** Director rows have no ask's episode id; they are tied to an ask by time only.
7. **Model start times** are derived from `latency_ms`. A call that never answered has no row and is invisible.

Two rows to add (not edited here):

| row | where | fields |
|---|---|---|
| `plan_requested` | `brain/agent.py` just before `self.planner.plan` (`:1207`) and `self.planner.replan` (`:1240`); `brain/director.py` `_dispatch` beside `director_dispatch` (`:1222`) | `composer` (planner or director), `reason` (ask, replan with the failed step and its reason, review, prepare), `request` (the player's words), `basis_ts` and `basis` (position, a digest of the inventory counts, fight, dead) of the state the plan is made on, `body_busy` (the running command's id and tool, or null) |
| `plan_landed` | `brain/agent.py` right after `plan`/`replan` return; `brain/director.py` `_collect_decision` beside `director_decision` and `director_discarded` (`:1376`, `:1355`) | `composer`, `requested_ts`, `steps` (count), `first_step` (skill and args), a fresh `state` (same fields as `basis`, read at landing, not cached), `first_step_satisfied` (its predicate on that state, where the step has one), `body_busy`, `applied` (true, or the reason it was discarded) |

With both, measure 2 is `plan_landed.ts - plan_requested.ts` with `body_busy` at both ends, and measure 4 is a field comparison of `basis` and `state` with no inference. After the change, `body_busy` at landing also counts "revisions that arrived after the step they were about" (Decision item 4).

## 8. Side findings

- **Planner prompt caching is low on the in-line path:** 0.26 M of 1.57 M prompt tokens cached (17 %). The Director's calls on 2 Nov cached 1.32 M of 1.85 M (71 %). Planner calls cost $0.04 each on average; caching would cut that.
- **The house ask's stands end in failure often:** three of the ten worst stands were followed by a build that failed at once (`unknown_target`). A plan composed while standing still was wrong anyway.
- **The quest asks' Planner calls are mid-job, not at the start.** The Controller walks first (go_to in about 2.5 s) and queues a goal 30 to 40 s later. The goal's "about 20 s" is the house shape only, n = 4.

## Limits

- All 276 asks of 14 to 17 Nov are harness trials from "Tester" on the dev world. No live play with Luis is in this window.
- The 2 Nov set is 6 asks; two used the Director. Its medians are a description, not an estimate.
- "Nothing" includes the brain's own plumbing (state reads, say round trips) between calls; it is not all standing still.
- Run from logs modified more than 10 minutes before the run; the 14 to 17 Nov numbers stop at 14:00 UTC on 17 Nov.
