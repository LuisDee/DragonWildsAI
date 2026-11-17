# Retro: the two days of 2026-11-16 and 17 (the four quests' chain)

Written 2026-11-17 for Luis, after he stopped the run. It says what the two days produced, what slowed them, and what changed because of it. The rules that came out of it are in `CLAUDE.md` section 2 (rules 8 to 12).

## What the two days produced

- The four tutorial quests (First Steps, Getting Started, Ratcatcher, Rune Mysteries) passed in one chain 3 sittings in a row, inside every bar. Rung 5's quest row is AT STANDARD with its limits (`docs/PROGRESS.md`, 2026-11-17 12:50Z).
- 116 commits, 45 of them on 17 Nov. 58 failed runs in the ledger, every one tagged with its first cause.
- The step workflow: trials from a checkpoint, the failure ledger, void runs, gate last.

## What slowed it

| # | What happened | Cost | What changed |
|---|---|---|---|
| 1 | **Depth without breadth.** Two days went on four quests in one small area. | Nothing he was not tuned on was tried. | The goal moves to long jobs (`docs/GOAL-2026-11-17-long-jobs.md`), with a held-out set I do not fix against. |
| 2 | **Checkpoints richer than the chain.** `rc_start` held Ash Logs the chain's character never has. Ratcatcher was 10 of 10 alone and failed in the chain. | Two sittings. | Rule 8: a checkpoint is saved from the run it stands for (`--save-as`), never built by hand or by grants. |
| 3 | **The world is never reset.** Mined-out essence rocks, campfires with leftovers, a Rune Altar from an earlier run, the clock fixture draining food and water. | 10 void runs, and limits on what the passes mean. | `tools/world_snapshot.py` (keep and restore with the server stopped). Rule 9: a window starts from a named world snapshot. |
| 4 | **Wording before structure.** Five wording fixes for "stops with the request open", one for "give to an NPC". None held live. | About a day. | Rule 10: a fix changes what he is shown, offered or told back. A second change of words on one cause is not allowed. |
| 5 | **A fix judged on too little.** The slope change went in on log statistics, with no trace of the ground, and was to be judged on one window of 5 trials. | It is still undecided. | Rule 11: a window names the one change it tries, the number it should move and the trials that takes (`tools/ab.py`), before it runs. |
| 6 | **Fixes unseen live.** 20 commits had passed tests only. | Nobody knows which of them work. | `tools/unseen.py`: each fix carries a log signature; a scan after each window lists what ran. Rule 12: over 8 open, the next window confirms or bins. |
| 7 | **Unfinished code in a trial.** An uncommitted `combat.lua` hot-loaded for 19 s. | One window. | `quest_run` refuses to start a window on uncommitted code in `client_mod/` or `brain/` (bb5214f). |
| 8 | **Jump landings.** About a third of the paths with a jump have a landing judged missed. It cost attacks on several days and was noted in two progress entries before it was measured. | Open. | It is item 2 of the new goal, measured first. |
| 9 | **Subagents hardly used.** Four launches in the three days from 15 to 17 Nov, against "about five busy". I read traces and wrote fixes myself while the body played. | My time was the limit, not the body's. | Rule 7 now names the bench: each window starts with offline work handed out. |
| 10 | **One body.** A trial takes 4 to 5 minutes; a fault that shows 1 time in 10 needs dozens of trials. | Built in. | Replay of recorded turns first, where the fault is the model's; live trials for what only the body can show. |
| 11 | **Things owed to Luis sat.** The placement report waited a day. | His time. | Decisions for Luis go in one list at the end of a report, and the run goes on. |

## What I got wrong in my own report of 2026-11-17

I told Luis that one window was too small to judge the slope change. For the walks that is true (6 of 38 against 2 of 11). For the jumps it is not: 8 of 43 paths before against 11 of 16 after is p = 0.0005 by Fisher's exact test. The jumps did get worse.

## What is not measured

- Nothing beside a real player since 2026-11-01 (come, follow, give, his reaction to a line while busy).
- No long job since 2026-11-02 (`gear_up` 0 of 5, 2.46 times Luis's time, one stand of 138 s).
- Armour has never been made in a trial. No vault has been entered.
