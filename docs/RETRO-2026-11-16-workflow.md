# Retrospective and workflow change: the 17-hour goal run of 2026-11-15/16

Written 2026-11-16 after Luis paused the goal and asked where the time went. The rules that came out of it are binding in `CLAUDE.md` section 2 and `docs/GOAL-2026-11-01.md` "How the work is run". This file is the evidence behind them.

## What the run did (about 20:00Z on the 15th to 13:10Z on the 16th)

| time (UTC) | what | result |
|---|---|---|
| 20:00-21:00 | patch day: client and server updated, EULA, back in the dev world | done |
| 21:07-22:50 | rung 1, grave | at standard, 3 in a row twice |
| 23:50-00:45 | rung 2, own house, three live runs | all failed; four fixes made one at a time |
| 00:45-03:00 | rung 2, placement speed, the roof cause, the batch call | at standard, 3 in a row |
| 03:10-05:30 | rung 3 mine and chop, rung 4 spells | each at standard, 3 in a row |
| 04:57-07:30 | rung 5, four quest chains | Rune Mysteries 0 of 4; seven causes fixed |
| 07:30-08:50 | one death in chain 072935, then a combat wave on it | no pass came of it |
| 08:50-12:20 | nine more chains | Rune Mysteries 3 of 9 by the amended counting rules |
| 12:20-13:10 | chain 1219: the brain warm-up race, then a part 2 that did not move on | paused by Luis |

Rungs 1 to 4 moved quickly. Rung 5 took about eight hours and ended with one quest of four at its gate.

## What the records say about rung 5

Counted from `logs/evals/quest_runs.jsonl` and `quest_fresh.jsonl` by `tools.quest_run rates` and `tools.failure_ledger report` (2026-11-16, one void run left out):

- **15 chain windows took 4.88 hours of the one body** and gave 12 full Rune Mysteries samples: about 24 minutes of body time for each sample of the quest that was failing.
- **Every Rune Mysteries failure was in part 2.** All 12 full runs reached part 2, 183 to 333 s into the quest. Part 2 itself took 79 to 209 s in the four runs that passed. Each sample replayed three quests and part 1 that already worked.
- **Pass rates:** First Steps 12 of 12, Getting Started 5 of 13, Ratcatcher 9 of 13, Rune Mysteries 3 of 13.
- **At 3 of 13 a streak of three takes about 104 trials** on average ((1 - p^3) / (p^3 (1 - p))). At 9 of 10 it takes about 4. Attempting the gate at a low rate could not have worked however long it ran.
- **23 failed runs, 14 causes** (`docs/failure_ledger.jsonl`). The largest: six Rune Mysteries runs stopped with the quest's next part still open. That one cause was fixed five times (73b694e, 502eafe, b21b657, 159a42d, c019a6f), each fix written after one sample of one variant. The second largest: four Getting Started runs failed on the same `collect_water` search cap, which was fixed only after its fourth run.
- **One failed run was the harness's:** the line went out before the brain's warm-up ended, the grader saw a 5.0 s stand at 0.0 s, and it cost First Steps a streak of 12.
- **The last failure was not readable.** Runes were crafted, the quest did not move on, and talk to Zanik opened no conversation. The quest's own flags were not exported by the body, so the cause could only be guessed at.

## Where the time went

| time (UTC) | what happened | the rule that addresses it | estimate saved |
|---|---|---|---|
| 23:00-00:45 | three whole house runs to find four causes | 1 shortest reproduction, 2 ledger | about 1.5 h |
| 05:00-07:30 | whole chains to see one part of one quest | 1, 6 gate last | about 1 h |
| 07:30-09:00 | a combat wave built on one death | 2 ledger: one run is one row | about 1 h |
| 09:00-12:20 | six chains, a fix after each | 1, 2, 5 search at the triggers | about 1.5 h |
| 12:20-13:10 | a harness fault read as his failure; an unreadable quest state | 3 void, 4 visibility | about 0.5 h |

About 5 to 6 of the 17 hours. These are estimates made after the fact, not measurements.

Two more things did not work:
- **No search when stuck.** The best two hours of the run followed a search for how others solve placement. On rung 5 there was no search for how agent evals are run or for the quest's rules on the wiki until after the pause.
- **The counting rule was amended twice mid-run** (5df4488, dd347ef) to read a run as a pass. Both are recorded for Luis to accept or reject. A checkpoint trial now has its own item name, so the question does not come up for step work.

## What the search found (after the pause)

- Run many short trials and report a pass rate. At 75% per trial, three in a row happens 42% of the time. Anthropic, "Demystifying evals for AI agents"; tau-bench (arxiv 2406.12045) and its pass^k; Sierra's write-up of the same.
- Zero passes over many trials usually means a broken task or instrument, not a weak agent (same sources).
- Read failed traces, note the first thing that went wrong in each, group and count, then fix the largest group (hamel.dev error analysis; the Langfuse error-analysis cookbook).
- Fork from a checkpoint at the failing step instead of replaying from the start (DBOS workflow debugging; Arize on agent checkpointing; ROS replay testing).

## What changed

| rule | tool or text |
|---|---|
| 1 shortest reproduction | `tools/quest_clone.py keep` and `fork` (a checkpoint is a kept save; a fork is that save under a new name and guid, because the dev server caches a character by guid). `tools/quest_run.py step`: K trials from a checkpoint in one lock window, `--until-step` to end at a step, `--save-as` to keep the next checkpoint. |
| 2 ledger before fix | `tools/failure_ledger.py scan / tag / report`, `docs/failure_ledger.jsonl` (seeded with the 23 failed runs of the 16th). |
| 3 void | `failure_ledger tag --void`; `quest_run rates` and the chain guard leave void runs out. |
| 4 visibility | `client_mod/scripts/quests.lua` now exports each quest's bool and int flags. The rule itself is text. |
| 5 search triggers | `CLAUDE.md` section 2 and the `search-before-building` skill ("When you are stuck"). |
| 6 gate last | `quest_run rates` prints the rate and streak per item; `quest_run fresh` refuses the chain under 4 of the last 5 (`--chain-anyway REASON` is recorded). |
| 7 body never idle | text; `tools/replay_episode.py` already replays a turn in live order off the body. |
| the brief | `CLAUDE.md` cut from 380 lines to about 60; the original is `docs/BRIEF-ORIGINAL.md`. |
| the harness fault | `tools/chat_ladder.py start_brain` waits for the brain's warm-up row before it returns. |

## Limits, stated plainly

- **Nothing here has run live.** `step`, `fork`, `park`, `--save-as`, the warm-up wait and the quest flags are tested offline only (45 Python tests, 24 Lua tests, and a fork of the real failing save checked in memory). The first live window is the real test.
- **A fork restores the character, not the world.** Quest state, bag, skills and place come back. Trees, NPCs, station contents and the time of day are the server's and stay as the last trial left them.
- **The dev server keeps every forked character** in its own save and memory. Parking moves the client's file only. The growth per fork is not measured.
- **A switch costs 57 to 67 s per trial** (measured on clones), so a trial from a checkpoint is the step plus about a minute.
- **The Rune Mysteries part 2 cause is still unknown.** The workflow makes it about six times cheaper to sample and makes the quest's flags visible. It does not find the cause by itself.
- **The saved hours are estimates.**
