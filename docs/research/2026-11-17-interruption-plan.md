# The first interruption windows: I1 to I5 once each on L2 (plan, 2026-11-17)

For `docs/GOAL-2026-11-17-long-jobs.md` section 1 ("Measure first, then work the interruption with the most open runs
alone from a checkpoint") and "On resume" step 4. Offline plan: nothing was run, no repo file but this one was
edited. Sources read: CLAUDE.md section 2, `tools/job_run.py`, `data/jobs.json`,
`docs/research/2026-11-17-long-job-harness.md`, `docs/research/2026-11-17-long-job-gap-tests.md`, PROGRESS to
19:40Z, the one job record so far (`logs/evals/job_runs.jsonl`, run `20261117-195219-L2`), `job_windows.jsonl`,
`client_io/state/last_death.json`, the brain logs of 16 and 17 Nov, `tools.spend` (20:18Z: $3.96 of $10, 1,719
calls) and `tools.unseen report` (9 open, cap 8).

## 1. What these windows are

- Six windows: one probe that makes the mid-job checkpoint, then one window per step, one trial each.
- **No change is in any of them** (rule 11). They are measure windows: each gives one number and one ledger row.
  The unseen ledger is over its cap (9 of 8), and these windows carry no new fix, so they also serve as confirm
  windows: `unseen scan` after each (e5b851c, a walk resumed after a fight, can show in I2; 3ec85ff, the open-ask
  turn, and c96dc9e, a goal that keeps its request, in any of them).
- **Named first** (rule 11): per step, pass or fail of one trial. What the code predicts (gap tests, harness doc):
  I1 pass, I2 pass, I3 fail (death is a "deterministic" failure on the default path: two re-plans, then stuck),
  I4 fail (the same, and no options line for a bag full by slots), I5 fail (the ask is not on disk; 3ec85ff keeps
  it in memory only). So about 2 of 5. One trial per step says nothing about a rate; it gives each step a row, and
  the ledger then picks the step to work with K trials.
- Holder: the default path (`--holder default`, the flag's default). The holder decision (I3 and I5 on each
  holder) comes after these, see section 8.

## 2. Is L2 right for each step?

L2 ("claude, we need thirty copper ore in the chest at your base") is used for all five. The step verdict reads
only whether he took the job up again, not whether the job got done, so L2 serves. What the 19:52Z trial showed
about L2 itself (940 s, ended quiet, not done):

- **His first verified step comes at 26.6 s**, and it is a gather of 6 ash sticks for a pickaxe, not ore. The
  `first_step` trigger therefore puts every interruption in about 30 s into a trial, during the tool-making, not
  during mining. That is still mid-job (he is working the ask), and it is the earliest stable point.
- **No copper was found.** Two `explore` calls (209 s and 229 s, up to 126 m from home) and a `gather copper` at
  90 m found none. Copper may also need a tier-2 pickaxe (`docs/research/2026-11-01-competence-map.md`: the Bone
  Pickaxe). A later trigger ("during mining") is not reachable today.
- **He owns no chest at that base.** `own_containers` at the start lists two benches, two campfires, a door and
  building pieces, no crate. `in_own_chest` cannot pass unless he builds one. This blocks the whole L2 job, not the
  steps; it is said so the whole-job runs do not read it as a model fault later.
- **His bag holds no food and no drink** (`consumables` 0 and 0 at the start; 5 raw rat meat). So I1 is a real
  interruption on this start: the stay-fed reflex has nothing to eat, he has to cook or forage.

Per step:

| step | L2? | why |
|---|---|---|
| I1 hunger, thirst | yes | no food or drink in the bag; raw meat and a campfire near home |
| I2 a fight | yes | open ground by home; the runt is spawned 8 m from him |
| I3 death | yes | death at home, respawn at the Temple Woods lodestone, about 100 m off (over the 20 m the harness needs) |
| I4 full bag | yes | his next step after sticks is a gather of stone and a craft: a full bag meets it |
| I5 brain restart | yes | the ask is about 30 s old, nothing else is open |

No other job is better for the first measure: L1 stops at thread (spinning wheel under a roof, parked), L3's
target ignores the vault, and H1 to H3 are held-out (never worked against).

## 3. The mid-job checkpoint (rule 8)

**Why make it, when `interrupt` would fall back to ClaudeDev:** ClaudeDev's save drifts between windows. The client
sits on ClaudeDev at home between windows, and the 5-minute autosave writes whatever he is then: at 19:36Z both
forks of a starved ClaudeDev (food 0, water 0, health 1) died to a rat on the walk to the start. A checkpoint is
never overwritten, so all five windows start from one fixed bag, place and set of vitals.

**Which run:** the probe trial below, a real L2 run cut at his first verified step. Nothing is granted or built by
hand. The record has `until: first_step`, so `scored()` leaves it out of every rate.

```
.venv\Scripts\python.exe -m tools.job_run trial --confirm --job L2 -k 1 --until first_step --save-as job_l2_mid | Tee-Object logs\window_l2_mid_1117.txt
```

- The trial ends at his first work call the body reported ok (about 27 s). `quest_clone.keep` then waits up to
  `AUTOSAVE_S` (330 s) for the fork's next autosave and copies it to `logs/quests/checkpoints/job_l2_mid.json`.
  The window prints `saved_as`. `no save of ... within 330 s` means rerun the probe (the label stays free).
- What it holds: ClaudeDev's bag plus the sticks of that first step, standing where the brain stopped, vitals as
  of that autosave (about 5 minutes after the start, idle).
- **Before the probe, ClaudeDev must be fit**, or the fork is refused ("body unfit", 3f32da0) and the checkpoint
  inherits low vitals. Aim at 80 % or more, so the checkpoint has margin over the 40 % refusal. ClaudeDev has no
  food: the remedy is the logged harness rescue the unfit line names (`set_stat` sustenance and hydration, and
  `set_health` if low, through the dev fixtures, purpose "harness rescue: ClaudeDev fed before the probe"), then
  wait for one autosave (5 minutes) so `ClaudeDev.json` carries it before the probe forks it.
- After it exists: `interrupt` finds it on its own (`start_ref`: "the job's mid-job checkpoint"). The commands
  below pass `--from job_l2_mid` anyway, so a missing checkpoint stops the window ("no start") instead of falling
  back to ClaudeDev without a word.
- The interrupt trial sends the line again at its start (the brain is new), and `first_step` fires at his first
  verified step after it, so the interruption lands about 30 s in.

## 4. Before the first window

1. The L2 window running at 20:17Z (fork ClaudeJ171948b) has ended and handed the lock back on ClaudeDev.
   `failure_ledger scan`, tag its runs.
2. **The I2 harness fault, fixed first** (a harness change, not a change to him; commit it before the I2 window).
   The fight is seen only through `combat_started` in the brain log. Over the last 40 brain logs of 16 and 17 Nov
   that row reached the log a median 32 s after the event (p90 98 s, max 142 s, n = 37), and fights he starts with
   `attack` emit no `combat_started` at all (18 of 55 `combat_end` rows were `by: brain`). With `fight_wait_s` 40,
   about half of I2 trials would end "interruption did not take" while he fights: void. The fix: `fight_wait_s`
   150 in `data/jobs.json`, and in `fight_cleared` a fight starts at the first of `combat_started`, an `attack` call
   after the spawn, or a `combat_end` after the spawn. Without it, plan two I2 windows.
3. **Read `client_io/state/last_death.json`.** It has no character field: every fork and ClaudeDev share it, and a
   world restore does not touch it. At 19:52Z it still offered an unrecovered grave from 17:54Z (a void trial's, on a
   world restored three times since) to the fork, and he walked 474 m to it (`my_grave:1794938042.517`). At 20:17Z
   it holds 12 deaths, 0 unrecovered. Check again before each window, the I3 window above all.
4. Announce in text: each window starts with a server stop and restore (section 5).
5. Foreground shells only (background gates are reaped at low RAM), and no repo Lua or brain edits until the last
   window ends.

## 5. The sequence

Every window starts from the named world `base` (rule 9: kept 17:12Z, ClaudeDev's base as after the four-quest
chain). The restore, with the lock free and announced:

```
tools\stop_server.ps1 -Hold
.venv\Scripts\python.exe -m tools.world_snapshot restore base --confirm
tools\start_server.ps1
tools\client_boot.ps1 -Target dev
```

If the restore refuses because another player joined since 17:12Z, pass `--others-ok` with Luis's words of
2026-11-17 ("you can delete roll back nuke do whatever to the world its a dev world"). `start_server.ps1` runs the
nav reset; the window's preflight refuses while the nav helper is not "offered".

| # | window | command (after the restore) | ends when |
|---|---|---|---|
| 0 | the probe | `.venv\Scripts\python.exe -m tools.job_run trial --confirm --job L2 -k 1 --until first_step --save-as job_l2_mid` | his first verified step, then the autosave is kept |
| 1 | I1 hunger, thirst | `.venv\Scripts\python.exe -m tools.job_run interrupt --confirm --job L2 --from job_l2_mid --step I1 -k 1` | resumed + 60 s, or 90 s after the set with no work call |
| 2 | I2 a fight | `... interrupt --confirm --job L2 --from job_l2_mid --step I2 -k 1` | resumed + 60 s after `combat_end`, or 90 s with none |
| 3 | I4 full bag | `... interrupt --confirm --job L2 --from job_l2_mid --step I4 -k 1` | resumed + 60 s, or 120 s |
| 4 | I5 brain restart | `... interrupt --confirm --job L2 --from job_l2_mid --step I5 -k 1` | resumed + 60 s, 120 s, or 40 s quiet after the new brain is up |
| 5 | I3 death, grave | `... interrupt --confirm --job L2 --from job_l2_mid --step I3 -k 1` | resumed + 60 s, or 180 s after the respawn |
| 6 | restore `base` | the four lines above | the grave of window 5 is gone |

- Each command is piped to `| Tee-Object logs\window_l2_<step>_1117.txt`.
- **I3 last:** its grave (and the fork's items in it) stays in the world. The restore after it (row 6) is part of
  the plan, so the next window of any kind meets a clean world.
- **To stop a window:** create `logs\job_run.stop`. Never kill it (18:04Z: a killed window left the client on its
  fork). Delete the file before the next window, or that window skips every trial.
- **After every window:**
  ```
  .venv\Scripts\python.exe -m tools.failure_ledger scan
  .venv\Scripts\python.exe -m tools.job_run show <RUN>
  .venv\Scripts\python.exe -m tools.unseen scan
  ```
  Tag the failed run by its first wrong thing (`failure_ledger tag <RUN> --class model|skill|harness|game`, with
  `--void` for a harness fault). Read the window's `job_windows.jsonl` row too (section 6, I1).
- A void trial is rerun in its own window, after a restore, before the next step.

## 6. What each verdict reads, and what may be unreadable

`verdict()` for a step has five bars: `interrupted` (the interruption took), `resumed` (a work call STARTED after it
cleared), `no_new_line`, `in_time` (within `resume_within_s`), `counted`. Misses are recorded and split
before / during / after; they are not a bar of a step.

Common to all five:

- `resumed` counts any call of L2's `work_tools` (gather, store, craft, take, interact, cast), **ok or not**, and
  whether or not it serves the ask. Read the resume call (`show`: `resumed_after_s` and the call) by hand: a
  failed gather into a full bag, or a cook for his own hunger, passes the bar.
- `no_new_line`: the harness never sends a second line, so this is always true. A line from a player in the world
  is not read; the fixtures refuse while another player is on, so none can be there.
- `counted`: L2 has no `not_carried_at_start`, so always true.
- The trial can end "quiet" (40 s with no model call or tool open) before the step's resume limit. That counts
  against him: he stood 40 s after the interruption with the job open.

| step | `interrupted` reads | clears at | unreadable or weak |
|---|---|---|---|
| I1 | `set_stat` did not raise (the `how` text holds the `after` values) | at once | `took` is true whatever `after` says: check `how` shows about 10 %. The record holds no vitals (`snapshot` has no survival); the end vitals are in the window row's `clock_after.vitals_back` (read just after the trial, put back after the regrow). The verdict cannot tell "ate, then resumed" from "ignored hunger": his next work call comes about 15 s after the set either way. Read `says_after_put` and the calls (cook, consume, collect_water) |
| I2 | `combat_started` row after the spawn (`fight_cleared`) | `combat_end` event's own ts | the log lag and the brain-led fight in section 4 item 2. A spawn that fails (`r.get("id")` empty) shows in `how` |
| I3 | `me()` alive and over 20 m from where he died, within 120 s | the respawn | death within 20 m of the respawn never clears (void). `take` and `interact` at his grave count as resuming: report the grave recovery apart from the ore work. Which grave he goes to: compare `go_to my_grave:<ts>` with the trial's own death |
| I4 | `inventory {raw:true}` `empty_slots` == 0 after up to 3 grants | at once | three unknowns: whether the Coarse Net's item data is loaded on the server (`grant` gives `item_data_not_loaded` if not); whether one grant of N unstackable nets fills N slots; `empty_slots` read as None makes `took` false. All three end "did not take": void, rerun after a look at the fixture log |
| I5 | the new brain process started (`start_brain` gave a log file) | when it is up | the new brain's rows are read from a second log file (`brain_logs` lists both). Side effects repeated after the restart (goal measure 7) are not counted; the calls are in the record |

## 7. Void (harness) or counted against him

**Void** (rule 3: `failure_ledger tag RUN --class harness --void`, rerun, no streak reset): a fault of the run or
the grader.

- `ended: interruption did not take` from a fixture that failed or a fight the log did not show in time (I2 lag,
  I4 unknowns, I3 no respawn over 20 m, I5 brain did not start).
- The nav helper not "offered" during the trial (every walk `nav_unavailable`, as the 17:40Z L2 trial).
- A trial that met an earlier one's leftovers: the world not restored, or a grave from `last_death.json` that is
  not this trial's and that he went to.
- `ended: stopped` (the stop file), or `deadline` from the window's time budget, or the brain refused by the spend
  guard mid-trial.
- A fork skipped (unfit, not at the start's place) leaves no run record: nothing to void; rerun the window.

**Game**, tagged and not void: the game took something away (a grave gone, as gear_up trial 2 at 17:54Z).

**Against him** (model or skill): no work call within the step's limit; "quiet" after the interruption; a
`haiku cap` end; a resume call that is plainly not the ask (counted as a pass by the bar, tagged by hand in the
ledger note so the number is honest). Misses are his, but not a bar of a step.

## 8. Time and cost

Per window, from `quest_run.SWITCH_S`, the 19:35Z and 19:52Z windows and the step limits:

| part | seconds |
|---|---|
| restore: stop, copy and sha256 check, start, nav reset, client rejoin (89 s at 17:12Z) | 180 to 240 |
| lock, switch to the fork | 60 to 70 |
| walk from the world spawn to the checkpoint's place | 25 to 100 |
| brain start | 10 to 30 |
| trial: about 30 s to the first step, then I1 about 90, I2 120 to 200, I4 90 to 180, I5 80 to 200, I3 120 to 300 | 110 to 330 |
| stop, regrow clock | 10 to 20 |
| switch back to ClaudeDev | 70 to 120 |

- Probe window: about 10 to 12 minutes (the autosave wait is up to 330 s) plus the restore.
- Each step window: about 6 to 10 minutes plus the restore.
- **All six windows and the final restore: about 65 to 85 minutes of the body.** Each void adds a window and a
  restore (about 10 to 14 minutes).
- **Spend:** the L2 trial at 19:52Z, 940 s of play, was 18 Haiku and 3 Sonnet calls, $0.14. Today's averages:
  Haiku (controller) about $0.001 a call, Sonnet (planner) about $0.04 a call. A step trial is 2 to 5 minutes of
  brain: about 5 to 20 Haiku and 1 to 3 Sonnet calls, $0.05 to $0.15. The probe: about $0.05.
  **Total about $0.30 to $0.80; the worst case at the `--usd 0.6` cap per trial is $3.60.** From $3.96 spent at
  20:18Z (and the running L2 window), the day ends near $5, under the $10 guard in every case.
- State before the batch (spend rule): six trials, Haiku 5.5 controller and Sonnet 5.5 planner through `brain/llm.py`,
  at most 120 Haiku calls and $0.60 each.

## 9. After the five

- `job_run rates` and `failure_ledger report`: the step with the most open runs is worked alone with K trials from
  `job_l2_mid` (rule 1), with its fix named first (rule 11). The gate stays last (rule 6).
- **The holder decision** (goal: "one trial set of I3 and I5 on each; the worse one is deleted"): the same two
  commands with `--holder board`, each after a restore, I3 last. The Director audit's worktree is not merged; a
  board job trial was estimated at $0.70 to $1.90, so a short step trial is likely $0.20 to $0.60.
- If I1 passes trivially (resumed within 15 s, no eating in the calls), the next I1 trials want a later trigger
  (`--trigger at:120`) or a resume read after his food is back over a threshold; that is a change to the harness,
  named before its window.
