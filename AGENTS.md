# Dragonwilds companion: working agreements

Read the current user request first. For the autonomous companion goal, read
`docs/GOAL.md`, `docs/goal_targets.json`, `docs/SESSION-RECOVERY-2026-10-26.md`,
`docs/ARCHITECTURE.md`, and `docs/design/PRINCIPLES.md`. The recovered original
goal is in `docs/RECOVERED-GOAL.md`. Current user instructions override historical
Claude notes; older server-puppet and Shockbyte instructions are not the current
autonomous test configuration.

## Runtime and safety

- Use the local DEV server and its dedicated dev character only. Never connect
  the companion to Shockbyte or modify other players, their inventory or saves.
- Inspect and adopt existing processes before starting anything. There is room
  for one dev server and one headless client, not a second server on another port.
- Confirm the effective client target is dev and Shockbyte is forbidden before
  live work. Use the existing client reservation and live-check queue. One live
  tester at a time; never reload the bridge with an action in flight.
- Announce game/client restarts before executing them. Never restart Steam as a
  routine repair: the previous login was not persistent and may require Luis's
  Steam Guard approval. Use `tools/steam_restart.py` for its safety check.
- Read-only native diagnostics (ProcDump/cdb, dumps and stacks) are approved.
  Binary or memory patching requires explicit approval.

## Build the companion, not a scripted solution

- Use the game's real client input, UI and interaction paths. Test-harness grants
  and spawns are allowed on dev; the companion itself must obtain outcomes by
  playing, not by writing inventory/health or emulating damage/crafting.
- The model interprets intent from truthful capabilities, perception and context.
  No phrase-to-tool mappings, hard-coded entity logic, benchmark-specific plans,
  spoon-fed solutions or code that rewrites the model's choices.
- Fix root causes. An avoidance rule is only a temporary guard, never the final
  answer to a crash or missing player system. Record verified mechanics and mark
  hypotheses explicitly.
- Preserve the single voice. Persistent actions must report a specific truthful
  failure; do not silently end follow or narrate internal reasoning/statistics.
- Use `.claude/skills/search-before-building/SKILL.md`: search repository research
  and primary sources, then reuse > adapt > build. Record the search in a design
  note, review against PRINCIPLES, implement a regression, and re-measure live.

## Delegation, integration and resources

- For this goal, Sol coordinates and reviews; GPT-6.1 Terra handles bounded
  independent work. Start with one child agent and use at most two concurrently.
  This supersedes the historical request to keep five or six agents busy.
- Give each file/resource one owner. Include the search-before-building brief in
  every implementation assignment. Main integrates and commits completed work.
- Never stash, reset, restore, clean or check out over the shared working tree.
  Compare with `git diff` or `git show HEAD:path` instead.
- One heavy local workload at a time (full pytest, a benchmark batch or a world
  load). Agents use targeted tests. Observe free RAM and commit headroom; stop
  launching heavy work under critical pressure.
- Run tests with `.venv/Scripts/python.exe`. If pytest's old system temp root is
  inaccessible after a change of Windows elevation, use a fresh test temp root;
  do not delete or relax permissions on unrelated temp directories.
- `--basetemp` deletes an existing target: use a unique new directory under
  `logs/recovery/` for focused tests. For the full `tools/check_all.ps1` command,
  a task-local TMP/TEMP directory can avoid the inaccessible inherited temp root.

## Memory, evidence and budget

- Preserve per-world state in `logs/state/worlds/<world>/`, learned/navigation/
  combat data in `data/skills/<world>/`, envelopes in `data/envelopes/`, and client
  state in `client_io/state/`. Back up before migrations or world restoration.
- Keep dev and Shockbyte memories separate. Do not clear progress to hide a
  failure or casually replace the active world with an empty memory folder.
- The existing model-API cap is $10 per UTC day, across the game brain, Director,
  evaluations and generators. Read spend before batches, state call counts and
  models, warn at 80%, and never exceed the cap. Development-model account
  allowances are separate; inspect them when available and bound delegation.
- Freeze the approved judge definitions. Check `evals/bench/hashes.py` JUDGE_PATHS
  before edits; new changes to those files require explicit user approval. Do
  not weaken criteria or count model claims as game-state evidence.
- Goal completion requires fresh current-code measurements, the original M1-M6
  targets, `GOAL MET` and `CHECK_ALL: GREEN`, followed by Luis's sign-off.
- Commit/push coherent tested checkpoints, and update PROGRESS, BUGS, DISCOVERIES
  and the recovery handoff. Raw logs, secrets, saves, external wiki data and SSH
  keys stay outside Git.
- If one item needs Luis, park only that dependency and continue independent
  work. Ask for actual missing access/Steam Guard/visual confirmation, not routine
  reversible implementation decisions. Never retry a usage-limit error in a
  loop: save a handoff and report it.

## Provenance

Consolidated on 2026-10-26 from Luis's active Codex goal, the repository's existing
project documents, and the external Claude development-memory files under
`C:/Users/Administrator/.claude/projects/C--gameserver/memory/`. The source memory
files and a snapshot of runtime memory were preserved in a private local archive
under `logs/recovery/`. Historical permission to choose judge changes and the
five-to-six-agent preference are superseded by the current goal above.
