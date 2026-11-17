# The working goal from 2026-11-17: long jobs, jumps, and what a player can look up

Luis, 2026-11-17: pivot to "long jobs that survive interruption", "jump landings" and "a lookup for enemies and vaults", because these can go on without him. What is set aside is listed under "Parked" below and is still owed.

The ladder and its bars in `docs/GOAL-2026-11-01.md` stay the standard. This file says what is worked now, in which order, and how it is measured. Why the pivot: `docs/RETRO-2026-11-17-session.md`.

## The goal text (what `/goal` holds)

```
Work docs/GOAL-2026-11-17-long-jobs.md on the dev world, run by CLAUDE.md section 2 (rules 1 to 12). Each session starts with `quest_run rates`, `failure_ledger report` and `unseen report`; announce, then start the server, client and brain if they are down. First of all: keep a world snapshot (`world_snapshot keep base`), then the confirm window the unseen ledger asks for.

1. Long jobs that survive interruption: one ask carried to an end the game state confirms, through hunger and thirst, a fight, his own death and grave, a full bag and a brain restart, using a memory of his own chests. The thinking model plans and revises while the fast model keeps acting; neither waits for the other (search first: docs/research/2026-11-17-long-jobs-planner-actor.md). Measure first, then work the interruption with the most open runs alone from a checkpoint. Then the whole jobs: armour made from nothing and worn, a supply run into his chest, gear up for a vault.
2. Jump landings: make every landing readable, then bring the paths with a landing judged missed from 36 % to under 10 %, with no attack ended by it. Decide 61412a5 on that evidence.
3. A lookup for enemies and vaults from the game's data and the wiki, as a player would read it (level, attacks, weak to, what lives in which vault, what it drops). Knowledge he consults; nothing tells him what to do with it.
4. Capstone, Rung 6: from one ask he prepares for a vault, clears it and kills its boss.

Held-out: the asks listed in the doc are run and scored but never fixed against, and the first three trials of anything new are scored before its trace is read. Report the untuned pass rate beside the tuned one.

Unchanged: nothing tells him how to do a quest or task (fixes only in tools, perception, reports and the harness). Do not re-run items AT STANDARD. Tag every failed run in the ledger; evidence in PROGRESS.md; commit and push each change; keep about five subagents busy on offline work; never ask for a go. Stop at the daily spend cap or for Steam Guard.
```

## On resume, in this order

1. **A named world.** Announce, stop the server with `-Hold`, `world_snapshot keep base`, start it. The restore itself is untried live: its first use is a trial of the tool (does the server load the restored save, does the client rejoin), not of him.
2. **The confirm window** (rule 12). The ledger opens with 20 fixes unseen, over the cap of 8. `docs/research/2026-11-17-unseen-triage.md` says which of them the existing logs already settle and the shortest trials for the rest.
3. **Jump landings made readable** (the log line of section 2), then the course.
4. **The first long-job window:** I1 to I5 once each, for a number and a ledger row (`docs/research/2026-11-17-long-job-harness.md` has the wiring).

Offline at the same time, by subagents: the lookup eval and its fix (section 3), replay studies of the turns where an ask was dropped, the planner and actor design.

## 1. Long jobs that survive interruption

### Where it stands (survey of 2026-11-17; code read, nothing run)

| | What the code does today | Where |
|---|---|---|
| The ask | Held in memory as `_open_request`. It closes on any turn in which he calls nothing. Nothing checks the world. | `brain/agent.py:524`, `:668` |
| Two holders | The default path (goal + task tree) and the board with the Director (`goals.json`). The board is off unless `DW_DIRECTOR=1`. | `brain/run_live.py:372` |
| Hunger, thirst | A Lua reflex; the job goes on. | `client_mod/scripts/inventory.lua` |
| A fight | The running command is suspended and resumed. After 5 interruptions the goal ends stuck. | `brain/agent.py:1218` |
| Death | A "deterministic" failure: two re-plans, then the goal is stuck. Nothing brings the ask back after the grave. | `brain/interface.py:93` |
| Full bag, over weight | The same: two re-plans, then stuck. | `brain/interface.py:96` |
| Brain restart | The ask and the goal are lost. Only the board is read back, and it is off. | `brain/state_store.py:126` |
| His chests | Remembered by actor id, which changes every session, so `store` and `take` cannot name a remembered chest after a relaunch. The full-bag options never list a remembered chest (`labels()` gives a dict, `needs.py:399` wants a list). | `brain/stash.py:96`, `brain/needs.py:399` |
| What the Controller can read | `lookup`, `remember`. The memory of places and the gear comparison are the Director's tools only. | `brain/controller.py:489` |

Last measured 2026-11-02: `gear_up` 0 of 5 (2.46 times Luis's time, 3 misses, one stand of 138 s), `bag` 0 of 1. Armour has never been made in a trial.

### The two models on one job (Luis, 2026-11-17)

Luis: long jobs should "push the synergy between the planning thinking model and the faster haiku model ... thinking and acting asynchronously", and how others do it should be searched first.

- **Today:** the Controller (Haiku) mostly waits while the Planner (Sonnet) composes. His first act comes about 20 s after an ask when the Planner is involved, 7 to 10 s when it is not.
- **Aim:** the Controller starts on what is plainly next while the Planner thinks; a plan or a revision lands between two of his calls without stopping him; the Planner is called again when the world has moved off the plan (a death, a full bag, a step that failed twice), not on a clock.
- **Measures:** seconds from the ask to his first act; seconds he stands while a plan is composed; Planner calls per job and their cost; how often a revision arrived after the step it was about.
- **Search before building:** `docs/research/2026-11-17-long-jobs-planner-actor.md` (dual-process agents, game agents with long tasks, task ledgers, durable execution). The design is taken from what it finds, most reusable first.

### What "done" means

- The end is read from the game: the pieces are worn, the ore is in his chest, the count is in his bag. His own claim is never the end.
- Bars per job: done; at most 1.5 times the time composed from Luis's per-unit baselines (as `rung4_gate.gear_up_t_h` and `quest_run.human_bar` do); no stand over 5 s without work or a reason he says; every report true.
- **Misses:** the ladder says at most 1 per item. A 20-minute job has about ten times the calls of a quest. Until Luis says otherwise the bar stays 1, and each run also reports misses per 5 minutes of work.

### The interruption steps (short trials, worked first)

Each is K trials from a checkpoint saved mid-job, with one interruption put in by the harness on the dev world. The score: after the interruption, did he take up the ask again without a new line from the player, and how long after.

| step | interruption | how it is put in |
|---|---|---|
| I1 | hunger and thirst | food and water set low mid-job |
| I2 | a fight | he is led past a creature's spot, or one is near the checkpoint |
| I3 | death | the fixture the grave item of the Rung 1 gate uses |
| I4 | a full bag | the bag filled by grant just before a gather |
| I5 | a brain restart | the brain process ended and started mid-job |

The first window runs each once to get a number and a ledger row. After that the ledger picks the order.

**The first decision, by trial and not by argument:** which of the two holders carries a long ask. One trial set of I3 and I5 on each; the worse one is deleted.

### The whole jobs (gate last; tuning set)

| job | the ask, as a player would say it | end read from the game |
|---|---|---|
| L1 | "claude, make yourself a full set of leather armour and put it on" (from a character with no hides) | the pieces worn, each made in the run |
| L2 | "claude, we need thirty copper ore in the chest at your base" | the count in his own chest |
| L3 | "claude, gear up for the vault" | the target `brain/gear_plan.py` computes for the vault's enemies: armour worn, weapon, food and drink carried |

Each is tried whole only when its interruption steps pass about 9 of 10. A job passes at 4 of its last 5, then 3 in a row.

### Held-out (never fixed against)

- **H1** "claude, make a bow and forty arrows, then bring back five hides".
- **H2** "claude, cook ten meals and boil ten waters for the trip and put them in your chest".
- **H3** "claude, get yourself the next tools up from the ones you carry".
- **The first three trials of anything new** (a quest, a job, a place) are scored before I read a trace of them.

Rules for the held-out set: its runs are scored and tagged by class in the ledger; a cause seen only there is not fixed; a cause that is also open in the tuning set is fixed there. It is run when a tuning job reaches 4 of 5, and at least every second day of work. The untuned pass rate is reported beside every tuned one.

## 2. Jump landings

- **Baseline** (14 to 17 Nov): 166 landings judged missed in 466 paths with a jump up (36 %); 3 of 74 attacks ended `path_blocked` after three such landings. After 61412a5: 11 of 16 paths (PROGRESS 2026-11-17 13:56Z).
- **Step 1, visibility:** each landing logs the signed height offset, the takeoff position, the edge kind and its rise.
- **Step 2, a course with no model in it:** a fixed set of walks over the hill behind Vannaka and the ledges by the windmill, driven through the mover alone. It costs body time and no API spend, and gives 30 or more jumps a run.
- **Step 3:** the rule for a strike, after a search of how Unreal and Detour treat a path after a link. Then 61412a5 is kept or binned.
- **Standard:** under 10 % of paths with a landing judged missed on the course and in play, no attack ended by it in 50 attacks, and the stuck rate of walks no worse than the baseline table.

## 3. A lookup for enemies and vaults

- **What exists:** the wiki mirror has each creature's level, weakness, resistance and drops (`data/wiki/pages/`), and a page that lists each vault's guardians and boss. `client_mod/scripts/creature_wiki.lua` holds 107 creatures, 94 with a weakness. The model sees a weakness only through `combat_brief`, which needs the creature in sight. `lookup` has no creature or vault entry of its own, only wiki text search.
- **Step 1, an eval before any change:** 30 questions a player asks before a vault ("what is a Giant Rat weak to", "what lives in Vertentis Kara", "what level is Velgar and what does he do", "what drops hard leather"), half of them held out, scored on what `lookup` returns today. Offline, no body.
- **Step 2:** creature and vault entries built from the game's data and the wiki mirror, answered by the `lookup` he already has. No new tool unless the eval shows the search cannot carry it.
- **Standard:** 9 of 10 on the held-out half, and in L3 he looks up the vault's enemies before he chooses gear, unprompted, in at least 4 of 5 runs. Whether he does is his decision; if he does not, the fix is in what the tool list and the situation tell him, never an instruction.

## 4. Capstone: a vault from one ask

Rung 6 of the ladder. Tried only when L1 to L3 are at standard and the jump course passes. The first vault is the one the storyline uses (Vertentis Kara, boss Velgar, power level 4, 6,000 HP, four phases, poison). Its first three runs are held-out scores.

## Parked on 2026-11-17 (owed; return in this order unless Luis says otherwise)

| # | Item | State when parked | Needs Luis |
|---|---|---|---|
| 1 | Beside a player: hearing a line while a tool runs (lines waited up to 162 s on 2026-11-01), follow at standard, come 3 of 3, give to a real player, a co-play session scored by `tools/coplay_ladder.py` | last measured 2026-11-01 | yes, for the session |
| 2 | The storyline after the four quests: the second First Steps (shelter, bed), Dragon Slayer; each alone by pass rate; a checkpoint after Rune Mysteries | not started | no |
| 3 | Farming: Growing Pains, plots, then Luis's farming scenario (`docs/GOAL-2026-11-01.md`) | not started | no |
| 4 | Eat and drink by comparing options | 0 in a row on the Rung 1 gate | no |
| 5 | Spinning wheel and spade | parked since rung 2: a wheel works only under a roof | no |
| 6 | Placement by moving the game's preview (agreed 2026-11-17) | not built; the fallback is not agreed | the fallback |
| 7 | One chain sitting of the four quests on a clean world (the Rune Altar of earlier runs still stands, so no sitting had to build one) | not run | no |
| 8 | The creature list (50 m) and `attack` (60 m) agree | not built | no |
| 9 | A reflex fight that starts with a station menu open ends `body_error` once before it wins | seen 2026-11-17 14:16Z | no |
| 10 | The truth judge sees no bag and only 240 characters of a result | known limit | no |
| 11 | The house at standard is on a fixture, and his first act comes 7 to 10 s after an ask | measured 2026-11-16 | no |
| 12 | The TEMPORARY `give_up_swings` guard in chop | marked as a workaround | no |

Not parked, because the tools now carry it: fixes not yet seen live (`tools/unseen.py`), and armour made and worn (job L1).

## Decisions that are Luis's

1. The miss bar for a long job: 1 per job as the ladder says, or a rate (for example 1 per 5 minutes).
2. Placement: whether the fallback is allowed (the placement call sent only when the game's preview says valid, with the preview's own transform).
3. World restore and his dev character: the world save holds the server's copy of every character it has seen. `world_snapshot restore` refuses when the server's logs show a player other than Claude joined after the snapshot (none has since 2026-11-02, as far back as the logs go). If Luis plays on the dev world again, a later restore needs his word (`--others-ok`).
