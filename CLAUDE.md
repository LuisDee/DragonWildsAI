# Dragonwilds AI Companion: working brief

Claude plays **RuneScape: Dragonwilds** beside Luis as another player. He is a real headless game client on this VM (Steam account `bootymaxer`, persona "Claude", UE4SS + `client_mod/`), driven by a Python brain (`brain/`: Haiku 5.5 Controller, Sonnet 5.5 Planner, through `brain/llm.py`).

This file holds the binding rules only. The original brief, its history and the sections that code and older docs cite as "CLAUDE.md section N" are in `docs/BRIEF-ORIGINAL.md`.

## 1. Start of a session
1. **The goal:** what is worked now is `docs/GOAL-2026-11-17-long-jobs.md` (long jobs that survive interruption, jump landings, a lookup for enemies and vaults; it also lists what is parked and owed). The standard is `docs/GOAL-2026-11-01.md` (six rungs, judged against `docs/BASELINES-2026-11-01-luis.md`; status table inside). Direction: `docs/DIRECTION-2026-11-01.md`.
2. **Where it stands:** the last entries of `docs/PROGRESS.md`, then `.venv\Scripts\python.exe -m tools.quest_run rates`, `-m tools.failure_ledger report` and `-m tools.unseen report`.
3. **Look it up before working it out:** `docs/DISCOVERIES.md` (verified engine facts with build ID), `docs/ARCHITECTURE.md` (layers, "how to add X" recipes, crash risk register), `docs/BUGS.md`, `docs/research/`, `docs/RUNBOOK-patch.md` (after a game patch), `SERVER-SETUP.md` (this VM).

## 2. How the work is run (binding; there is ONE live body)
The loop: research, make the failure observable, negative test, small change, live trial, keep or bin. Local tests are not progress; live behaviour is. No design-note or review chains: review only native-crash risk, anything near Luis's character, and Shockbyte. Rules 1 to 7 come from the 17-hour run of 2026-11-15/16 (`docs/RETRO-2026-11-16-workflow.md`), rules 8 to 12 from the two days after it (`docs/RETRO-2026-11-17-session.md`):

1. **Shortest reproduction.** Work a failing step alone: K trials from a checkpoint in one window (`quest_run step --from <checkpoint> --quest "<name>" -k 5`). Never rerun a whole chain to see one step.
2. **Ledger before fix.** After every window run `failure_ledger scan`, tag each failed run with the first thing that went wrong (`model`, `skill`, `harness`, `game`), and fix the cause with the most open runs, not the one the last run showed.
3. **A harness fault voids the trial** (`failure_ledger tag RUN --class harness --void`). It is rerun and resets no streak. Only a fault of the run or the grader is void, never something he did.
4. **Visibility before a second fix.** Before a second fix on one item, confirm the game's own state for it is readable (quest flags, station contents, the thing's real name). If it is not, make it readable first.
5. **Search at the triggers.** Ten minutes of search (skill `search-before-building`) at the first failure of a new class, and again after two fixes that did not move the number. A question about the game's rules goes to the Dragonwilds wiki first.
6. **Gate last.** The goal's gate stays 3 in a row. Try it only when the item passes about 9 of 10 alone. `quest_run fresh` refuses a chain until every quest in it has passed 4 of its last 5 trials.
7. **Body never idle, me never waiting.** Before a window starts, hand out the offline work to subagents (about five busy: log measurement, research, an eval, a tool, a replay study; each with its own files). While the body plays: read what they return, replay turns (`tools/replay_episode.py`), tests. No repo Lua or brain edits while a window runs: skill modules hot-load into the running client, and `quest_run` refuses to start a window on uncommitted code.
8. **A checkpoint comes from the run it stands for** (`quest_run step --save-as`), never from a hand-built bag or grants. A step that passes alone and fails in the chain means the checkpoint is wrong: compare the bags first.
9. **A window starts from a named world.** `tools.world_snapshot restore <label>` with the server stopped, so no trial meets what an earlier one left (mined rocks, leftovers in a fire, a built altar). A trial that did is void.
10. **A fix changes what he is shown, offered or told back.** Words in a prompt or a tool description may be tried once per cause. If that does not hold live, the next fix is structural.
11. **One change per window, its number named first.** Before the window: the change, the number it should move, and the trials that takes (`tools.ab need p0 p1`). After it: `tools.ab two` on the counts. Five of five says only "above about 57 %".
12. **No fix stays unseen.** Every fix gets a row in `tools.unseen` with the log line that shows it ran. `unseen scan` after each window; confirm or bin on what the trials show. Over 8 open rows, the next window is a confirm window and no new fix is written.

**Breadth:** a held-out set of asks is run and scored but never fixed against, and the first three trials of anything new are scored before its trace is read (`docs/GOAL-2026-11-17-long-jobs.md`). Report the untuned pass rate beside the tuned one.

Drop an approach whose number has not moved after 3 live iterations. Commit and push each change as it is made.

## 3. Design rules (Luis, binding)
- **A real player.** He uses the game's own client paths (UI handlers, input actions, character calls). No emulation of player systems. He equips only what is in his own inventory, and items are instances (level, enchants).
- **The model decides.** No phrase-to-skill tables, no hardcoded task recipes, and code never vetoes or rewrites a decision. Code gives a truthful tool list, honest perception and recent context, reports outcomes, and enforces only the safety rules below.
- **Communication is paramount.** He says what he is doing, what he cannot do and why. Every skill failure carries a specific, true reason to the brain. Follow never ends silently.
- **Verified state only.** A step is done when the game state confirms it. The model's own claim is never state.
- **Search before building.** Reuse, then adapt, then build. Open source only. Every capability leaves shared services and data profiles behind, so the next one is mostly a profile.
- **Root cause, never avoid.** A workaround is a temporary guard, marked as one, until the mechanism is found.
- **Persist what is learned:** `docs/DISCOVERIES.md`, `docs/PROGRESS.md` (append only), `docs/tasks.json` (keep the format; flip flags or append).

## 4. Safety (hard rules)
- **Luis's character, inventory and saves are never touched.** Nor are other players' characters, nor what someone else left in a station. Claude may use shared stations, fuel and items, and reports what he used or took.
- **Two worlds.** The dev world on this VM is for trials (harness fixtures allowed). The group's Shockbyte server stays vanilla: nothing is installed there, and no risky route gets its first trial there.
- **Native crashes:** `pcall` cannot catch them, so try a risky call offline first. Never send hand-built structs in `Client_*` RPCs (that froze Luis's client). Prefer property reads and copies of live engine structs.
- **Ask Luis before** patching binaries or memory, and before native disassembly. ProcDump and cdb stack diagnostics are approved.
- **Steam is never restarted as a routine repair** (the login may need Luis's Steam Guard). `tools/steam_restart.py` has the safety check.
- **Restarts are announced** in text first when Luis may be connected.
- **Keep the client freeze fix:** `client_mod/scripts/tickguard.lua` and the 30 fps cap. Keep the stay-fed reflex running: hunger and thirst kill him.
- **Character switches** (`quest_run fresh` and `step`): the live lock is never released while the client is on a character other than `ClaudeDev`. `ClaudeDev.json` is only read; a clone or fork is a new file under a new name and guid.
- **Secrets:** `ANTHROPIC_API_KEY` lives in the user environment only. Server addresses and passwords live in the gitignored `client_io/secrets/`. Neither is printed or committed. Saves are never committed.
- **Spend:** the daily guard is $50 (Luis, 2026-11-21: "up to $50 per day"; `DW_DAILY_CAP_USD` in the user environment; the first $200 a month comes from the Ultra plan's API credit on the linked Console org). State the call count and model before a batch eval run.
- **Shared working tree:** never `git stash`, `checkout`, `reset` or `restore`. Subagents get their own files; commits happen in the main session, finished files only.
- **RAM:** low free RAM is no reason to wait. The wall is commit charge: back off when free commit drops under about 300 MB (`Win32_OperatingSystem.FreeVirtualMemory`).

## 5. Operating
- Python is `.venv\Scripts\python.exe`. Lua and scripts keep Linux conventions (lowercase `scripts`, no hard-coded Windows paths in mods).
- **Dev server:** `tools\start_server.ps1`, `tools\stop_server.ps1`. **Client:** `tools\client_boot.ps1 -Target dev` (idempotent; `-DryRun` only looks; `-Target shockbyte` for the group's server). Supervision: `tools\start_client_watchdog.ps1`. After a patch: `docs/RUNBOOK-patch.md`, then `tools\client_smoke.ps1`.
- **Brain:** `tools\start_brain.ps1 -Body client -World dev` (on Shockbyte: `DW_PLAYER_NAME=Zezima`, `-World shockbyte`). Sonnet is uncapped; the Planner's `max_tokens` is 16000.
- **Subagents** are approved and expected for offline work, about five busy at a time. Background shells are reaped at low RAM: run gates in the foreground. Codex is on the VM for offload, optional.
- **The VM is Claude's to manage:** only Dragonwilds, the server, Steam and this repo matter. Kill or delete the rest when it is in the way.

## 6. Working with Luis
- **Decide, act, record, report.** Never ask for permission or for a "go", and never block an autonomous run on a question. Ask in text, and keep working, only when a decision is truly his (his character, money beyond the guard, binary patching).
- He plays on a Mac through GeForce Now and cannot run client mods. Claude cannot see the game: for a visual check ask him one clear action or one yes/no question, and read the result from log files. Never ask him to paste logs.
- A pass means done to a real player's standard, measured live, and reported with its limits. Say plainly what failed, what was skipped and what was not tested.
