# Codex audit, slice 4: 2026-10-30 00:00 to 2026-10-31, and how it ended

The sources were all read-only:

- Root thread `rollout-2026-10-26T22-27-56-01a17a1c...jsonl`: the records from 2026-10-29T23:00Z to its end at 2026-10-31T17:57Z.
- The six 10/30 subagent threads. There is no 10/31 folder.
- git, the worktrees, the Codex automation config and `goals_1.sqlite`, the process and task lists, `client_slot status`, and `logs/recovery/ACTIVE-HANDOFF.txt`.

All times are UTC unless marked +0100; commit times are +0100. Model: `gpt-6-astra`, reasoning effort high, `approval_policy=never`, `danger-full-access`. Subagent agent messages and reasoning are encrypted. Only the assistant's visible messages, tool calls and outputs can be read.

## 1. Timeline: asks and plans

**Luis sent no new messages in this window.** His last real messages were on 10/29:

- 20:29Z: "Adopt the persisted Astra independent review ... capture the exact cause of the normal navigation failure ... Prioritize three unassisted temple-lodestone → at least 200m outside → correct-floor return trips"
- 20:32Z: "Change the terra building subagent to a sol agent"
- 21:55Z: "Can you give me an update please on whT youve been doing..."
- 22:00Z: "Anazing what do you think you can acheive in the next 6 hours"
- 22:09Z: "At what point will he be competant be able to gather build stations craft chests research the wiki gather armour farm enemies farm crops progress himself etc when will he be competant and how can we acheiev that"

Every "user" turn in the window is machine-generated. There were 17 `<codex_internal_context source="goal">` continuations, which re-inject the long goal objective (the FIRST DELIVERABLE is three autonomous temple-lodestone → ≥200 m → correct-floor round trips, then a changed destination, another slope or doorway, and an unfamiliar route). There were also 36 `<heartbeat>` messages from the Codex automation `resume-dragonwilds-companion`, which is hourly.

**Proven: Codex re-answered Luis's 22:09 "when will he be competent" question nine times** (23:43, 00:17, 01:05, 01:43, 02:36, 03:39, 04:28, 05:19 and 06:11). Each time it was a long essay with the same competence-stages table and the line "I cannot honestly promise … within six hours". Each goal turn ended on this re-answer, and the next turn opened with "The previous turn answered your question but added no live evidence."

The plan was the same throughout: diagnose the navigation failure, repair it narrowly, review it, run the full gate, deploy, verify with developer real controls, then run the full Sonnet Director + Haiku Controller trial. Each turn ended with "No new autonomous pass".

## 2. What it tried (chronological, with evidence)

| Time (Z) | Attempt | Result |
|---|---|---|
| 23:00–23:38 | Floor-sensor fix: the sensor rejected a 6.14 cm floor distance against a 5 cm cutoff. Native-segment progress fix. | Gate 1,311 passed. Deployed `a98de42`. Live: the stance was now accepted. Developer return "hasn't reached the lodestone". |
| 23:43–00:12 | Return failure analysis: the remembered route stitched two journeys across a wall. The production local planner gives up at 13 rejected paths after 758 ray queries; the detour needed 18. | Live: the character walked over an obstacle grounded (35 cm rise, no jump), yet the checker rejected that same chord. |
| 00:17–00:53 | "Grounded step sweep" descent check: move horizontally, then settle. | Gate 1,311 passed. Deployed `6cade13`. The character's food and water had run out, so Codex supplied "declared navigation-test food and water". |
| 00:57 | Developer `go_to` return | **Passed in 59.7 s**, 0.27 m from the lodestone. |
| 01:00 | Developer outward leg | Hit its 120 s deadline at 114.5 m, ending in `sweep_blocking`. |
| 01:13–01:25 | **Full-agent trial a873** | Failed: "never reached the starting lodestone or 200 metres away". $0.629, 33 calls. Found a race: a hydration review let Haiku pause the task and Sonnet's plan was discarded. |
| 01:35–01:44 | Developer test of an away-first detour | Walkable, but "normal routing led him back to the same dead end". |
| 01:47–01:57 | Fix serialising reviews with Director planning (`08f2f6d`) | Gate 1,345 passed. Deployed. |
| 02:20–02:30 | **Full-agent a882/a885** | The first launch died before any model call ("PowerShell rounded the pause timestamp"). The retry failed after 24 calls: "paused and asked for help ... also attempted Windstep". |
| 02:15–03:20 | New `terrain.lua` (370 lines, `5d20332`) exposing sampled floor layers to both models. A cold-start bug followed: it rejected the read when movement was uninitialised (`f808d3d`). | Live: survey of 361 columns. Developer survey → move → survey worked. |
| 03:22–03:29 | **Full-agent a891** (terrain available to both models) | Failed after 37 calls: "the starting lodestone was never reached". Sonnet wasted calls on tools its role lacks. |
| 03:40–03:52 | Developer-driven exploration | The two-part route "reached the recorded entrance in 10.3 s, then returned to the lodestone on the correct floor in 59.3 s". **This taught route memory to the bot** ("developer provenance"). |
| 03:55–04:00 | **Full-agent a906** | Aborted. "Sonnet's hourly allowance cannot admit another planning cycle until about 04:22". The Director limit is local: 20 calls per hour. |
| 04:03–04:18 | Fix so that research tools are removed once the research budget is exhausted (`f63d809`) | Gate 1,378 passed. Deployed. |
| 04:24–04:35 | **Full-agent a907: PASS 1/3** | Details below. |
| 04:41–05:16 | Fix so a model-selected `run_skill` recovery is no longer dropped (`694fb84`). The first gate went RED because the Lua suite hit its 180 s timeout at 177 s; the timeout was raised to 240 s. | Gate 1,381 passed. Not deployed. |
| 05:25–05:40 | **Full-agent a914 (repeat): FAIL** | Details below. |
| 05:45–06:02 | Fix preserving a valid plan when an optional advisory exceeds the call cap (`aabdd66`). Pure-Lua replay of the detour selection. | Gate 1,388 passed. |
| 06:03–06:05 | Integrated into `C:\gameserver` (`40c6345`/`6ee8375`). "Only 1% development allowance remains." Left the client off. | No live validation. |
| 06:06–06:22 | Design for partial-memory route arbitration, with a Sol review (BLOCKED, then CLEAR after narrowing). Offline simulated-mover repro: 50 m reached with local planning, and the run failed 30 m short when a remembered detour was added. | Committed only in the worktree (`0447c8e`, **not pushed or merged**). |
| 06:22:34 | `task_complete` error | "You've hit your usage limit ... try again at Nov 4th, 2026 7:36 AM" (`usage_limit_exceeded`). |

**The a907 task (3b71129).** The goal's natural-language request was a temple round trip: from the spawn lodestone, at least 200 m from it, then back on the correct floor. The run was on `f63d809` with 40 model calls (23 Haiku, 17 Sonnet). From `measured-outcome.json`:

- `maximum_xy_m 200.65`
- final error 0.04 m XY and 0.003 m Z, grounded, `minimum_health 100`
- 502.9 s to return
- task `45d55b1a` done
- one airborne sample, the "ordinary obstacle hop" in `3b7d61e`

The provenance is stated by Codex itself: "Preserved route memory includes developer demonstrations; setup a913 ordinary return and earlier supplied water/food fixtures. This is route-use acceptance, NOT unfamiliar discovery or self-sufficient provisions."

Both legs timed out midway, and the models recovered by re-issuing `go_to`. Haiku afterwards told chat it had "only travelled 40m", which is false.

The audit (`docs/research/2026-10-30-roundtrip-recovery-audit.md`) found:

- The "busy/token required" errors came from the stay-fed reflex holding the movement arbiter for about 4 s while it verifies food or drink. No token had leaked.
- In `agent.py:721`, a model's `run_skill` recovery was dropped because the emptiness check left out `d.skill` and `d.goal`.

**The a914 task (ea4ddfe).** This was the identical request on the same build, and it failed:

- The first movement came 407 s after start. That came from eight Sonnet calls (a valid plan was lost at the five-call cap to an optional advisory) and then waiting on the 20/hour limiter.
- The maximum distance was **150.4 m**. The character returned to the correct floor at 100 HP, and the task ended `waiting_budget`.
- Cause of the failed far leg: `go_to([250,1790,-28])` picked an 89-point remembered prefix (231.6 m) toward a goal 71.9 m away, and timed out 45.9 m short. Replay proved that **adding the route learned on that same outbound leg (r152)** triggered the choice, because `navmem` ranks prefixes by remaining distance and uses cost only as a tie-break.
- Haiku again misread transient busy refusals as needing a reset.

The streak reset to 0/3.

**Subagents (10/30).** All six were short Sol **reviewers**; none built anything. Avicenna, Kepler, Fermat, Faraday and Averroes returned CLEAR. Copernicus returned BLOCKED, then CLEAR after the design was narrowed.

## 3. Final state (checked 2026-10-31 ~19:00 local)

- **main is at `6ee8375`, clean, and equal to origin.** The deployed runtime has the brain fixes `08f2f6d`, `f63d809`, `694fb84` and `aabdd66`, and the Lua from `a98de42`, `6cade13`, `5d20332` and `f808d3d`. The recovery-dispatch and advisory fixes **were never live-validated**. The a914 navmem detour bug **is unfixed**.
- **Codex worktrees:**
  - `navigation-cause` (the root's working tree) holds **one unmerged commit, `0447c8e`**: docs plus `docs/design/partial-memory-route-arbitration.md`. There is no code fix.
  - `feedback-loop` has 14 uncommitted modified files: `move.lua` +92, `test_move.lua` +217, and `controller`/`director`/`llm`/`llm_json`/`run_live`. These are the "unfinished navigation candidate"; content differs from main.
  - `companion-development` has 13 uncommitted files from 10/28 (lodestone, skills, places).
  - `interaction-ui` and `manifest-validation` contain only a marker file.
- **Processes:**
  - Dev server PID 7016, up since 10/26.
  - `nav_oracle serve` (PIDs 3228 and 1980) and `client_watchdog.ps1` (PID 12580), both up since 10/28.
  - Steam, and the idle Codex app-server and node runtimes.
  - No game client and no brain. The pytest, lua and watchdog -DryRun processes started today belong to the Claude session, not Codex.
- **Client slot:** `{"holder": null, "free": true, "queue": []}`, and `logs/client.hold` exists.
- **Scheduler:** there are no Windows scheduled tasks from Codex. The **Codex automation `resume-dragonwilds-companion` is `status = "ACTIVE"`, hourly**, targeting the root thread. It has fired 36 times since the limit and failed immediately each time, the last at 17:57Z on 10/31. **Once the limit resets on Nov 4 07:36 it would resume autonomous work** unless it is disabled.
- **Goal DB:** status `usage_limited`, `time_used_seconds` 161,404 (about 44.8 h), `tokens_used` 46.3 M.
- **Usage:** the weekly Codex limit rose from 60% at 23:00Z to 100% at 06:15Z, which is about 40% of the week in 7.3 hours. The thread total is 1.52 B tokens (mostly cached input). Game-model spend for 10/30 was $2.97 over 185 calls.
- Luis never answered Codex's "optional DEV 20→60/hour" question.

## 4. Failure patterns and diagnosis (interpretation)

1. **Process overhead dwarfed experiments.** In about 7.3 active hours there were 9 full gates of about 10 minutes each (1,311 to 1,388 tests), plus design docs, cold reviews and freezes, for each repair of a few lines. The log shows 52 new `logs/recovery` folders in the window. There were only 6 full-agent attempts, and one of those died on argument parsing.
2. **The "pass" was teaching to the test.** Codex walked the route under developer controls at 03:51, and the full agent replayed that memory at 04:24. Food and water were hand-supplied. Even so, the success did not repeat on the same build. Learning that very route made the next run worse.
3. **Every layer was brittle, and each failure exposed a new one.** These were the floor cutoff, chord collision, the local planner's budget, the planner/review race, research tools offered after the budget ran out, the dropped `run_skill`, the advisory cap, the prefix scoring, and transient arbiter contention. Every fix was narrow, and navigation has no robust baseline. The custom Lua sweep, sampled-ground and navmem stack is second-guessing the engine's own movement.
4. **Self-imposed limits blocked live time.** The local Director limiter (20/hour) aborted a906, delayed a907 and a914, and caused the 407 s stall.
5. **Communication loop.** The same competence essay was produced nine times in response to auto-continuations, and hourly updates repeated "0/3".
6. **It burned the whole weekly allowance** on this one sub-deliverable, and then sat dead for about 35 hours with the automation still armed.

## 5. Verified facts worth keeping

- The dev-server temple round trip is physically walkable on foot. a907 telemetry gives anchor `[51.76,1889.41,-35.11]`, a ≥200 m point near `[225.6,1790,-34.2]`, and correct-floor return.
- The ordinary mover can cross a low obstacle grounded (about 35 cm rise) that straight-chord capsule sweeps reject. Horizontal-then-settle checks match better.
- Dominion's floor-distance reading at a valid stance can be 6.14 cm, so a 5 cm cutoff is invalid.
- The stay-fed reflex holds the movement arbiter for about 4 s per consume. A `go_to` during that window returns busy/token-required, which is not a leaked token. The error should name the owner.
- `navmem` prefix selection by least remaining distance can choose a long incomplete detour once a new route is learned. A replay exists in `logs/recovery/temple-repeat-a914/`.
- Haiku narrated the outcome falsely ("only 40m") because the task-finish notice omits checkpoint evidence (`Director._finish_task`).
- `terrain.lua` (multi-level floor sampling, 361 columns in about 6 s) works live from a cold start.
