# Dragonwilds workspace recovery, 2026-10-26

## Repository and transcripts
- Source repository: C:/gameserver, branch main, HEAD 3c76837.
- At inspection: 18 modified tracked files and 7 untracked files. Nothing staged. No Git remote configured.
- Main Claude transcript: C:/Users/Administrator/.claude/projects/C--gameserver/e0d45239-de5c-445e-af07-0109fe4fa4e3.jsonl (65,505,504 bytes, 30,033 JSONL records at initial scan).
- Subagents: sibling e0d45239-de5c-445e-af07-0109fe4fa4e3/subagents/ directory; 92 transcripts totalling 337,696,223 bytes.
- Parsed transcript indexes and extracted conversation/tool records are in this temporary audit directory. These exclude thinking blocks.
- First main-session weekly-limit reply: 2026-10-26 20:17:16 UTC / 22:17:16 Europe/Berlin, main transcript line 29904. Reset reported by Claude: October 31, 02:00 Europe/Berlin.
- Final successful main-session update at 20:14:59 UTC said the live queue had been restarted. Scheduled inactivity checks then repeatedly hit the same limit.

## What was being built
An autonomous real player companion, running a headless Dragonwilds client with UE4SS Lua, controlled by a Python brain. The current autonomous scoring world is the local dev server, not Shockbyte. Earlier documentation about the server puppet and testing on Shockbyte describes previous stages.

Three speeds: Lua reflexes for survival/input/combat, an event-driven Haiku Controller for immediate decisions and the single chat voice, and a Sonnet Director for researched multi-step plans. The Director works on a snapshot in one worker thread. It writes a persistent task board; the Controller executes steps. Success predicates inspect fresh game state. Recipe, item, spell, enemy, map and wiki data support decisions. JSONL files carry commands/results/events between Python and the game thread. Watchdogs recover hangs/crashes; a single-client reservation and live-check queue serialize tests.

Milestones: M1 speed/voice/stability/basic spells and combat; M2 purposeful spells/tactics/crafting; M3 all 12 skills gaining XP and levels; M4 long jobs; M5 progression/quests/farming; M6 Brynmoor progression and solo Vel'gar. These milestones were not completed.

## Latest committed work
- 45fbb33: -nullrhi Niagara-null crash mechanism and fxguard.
- 40af35e: shared item-name resolver, station-output pickup improvements, Recall live mechanics.
- 1cdb5cf: spell availability/reason/cooldown/effect perception.
- 5d44964 and ee78fe5: more natural vitals context, prompt caching, speech after a long action is accepted.
- 4a1cf52: quest wiki retrieval and a world-position resolver for named places.
- bc0ff2a: Recall is one held-open cast with walk_to, not a persistent two-cast beacon; argument now survives the brain interface.
- c238bb0: stricter independent Recall proof, four draft goal cases pinned (60 total), judge tag goal-judge-20261026g.
- 3c76837: skill-training tool descriptions, cheap makeable recipe discovery, eleven queued skill-route checks.

## Uncommitted work and exact cutoff
1. Speech agent a95cb405701d1356f: brain/agent.py, brain/controller.py, brain/persona.md, tests/conftest.py, new tests/test_speech_channel.py. Adds explicit say(text), with ordinary assistant text logged but never spoken. Default changes to say; DW_SPEECH_CHANNEL=text retains legacy behavior. Most existing scripted tests force the legacy channel. Implementation and five dedicated tests exist; final handoff and live voice evaluation did not finish. Its last full-suite result was 1 failed, 1046 passed, 1 skipped; failure was not diagnosed in its final captured output.
2. Recall prompt follow-up shares controller.py: spell_lines renders bounded how-to instructions. tests/test_spells_rules_brain.py contains its regression tests. Core Recall changes were already committed.
3. Places agent af5010ebbc8b72d01: brain/places.py, tools/build_places.py, data/places_26161880.json, client_mod/scripts/places.lua, client_mod/commands/places_dump.lua, tests/test_places.py, new tools/live_checks/places_region_tags.json. Models six provinces above 31 subregions, associates NPC copies with provinces, prefers the local province, and records mapping provenance. Code/data/tests are substantially implemented. Last action was looking for a monitor while awaiting live region-tag output. That output later passed but was not reviewed by the agent.
4. Traversal agent a60ca56f19b293f4b: client_mod/scripts/move.lua, client_mod/scripts/localplan.lua, new client_mod/scripts/traversal_moves.lua. Added measured/unlocked capability gates, explanatory height reasons, and planner superjump edges. Execution still checks jump/djump without handling superjump. No changes to move_calib.lua or traversal tests, and no calibration live checks were completed. Not ready to claim functional Windstep navigation.
5. Crash agent ae8fa7b14394decd1: client_mod/scripts/fxguard.lua, client_mod/tests/test_fxguard.lua, new client_mod/commands/fx_null_probe.lua and tools/live_checks/fx_{damage_spell_fire_spirit,enchant_weapon_held_fx,status_effect_dirty_water}.json. Extends the committed guard to class defaults so a new pawn is protected before the periodic service runs. Last action read the live-check failures; no follow-up repair occurred.
6. Latency agent abc3d145c12f694a1: measured Director lead-in times and researched Talker-Reasoner so Haiku can act/speak during Sonnet planning. It was still inspecting board activation baselines at the cutoff. No implementation changes to director.py/board.py landed from this task.
7. Shared documentation edits: docs/ARCHITECTURE.md, docs/BUGS.md, docs/DISCOVERIES.md. Some ledger rows still say open or pending despite later code or live results; cross-check evidence before treating them as current.

## Results completed after Claude stopped
Detached queue run 20261026-211431 finished at 20:24:57 UTC / 22:24:57 Berlin. Its sixteen distinct checks ended 7 passed, 5 failed, 4 blocked. Across all persisted queue checks: 11 passed, 6 failed, 19 observed, 4 blocked, 1 pending. Observed is exploratory evidence, not a scored pass.

New skill-route passes: Agility walking, melee Attack, Cooking Clean Water, Mining a boulder, Ranged bow combat, Woodcutting with an axe. Fishing and Construction had earlier live evidence. This proves individual routes, not autonomous selection or +5-level completion for M3.

Failures/blockers: Magic attack spawned no projectiles; stick collection produced no Woodcutting XP on one successful gather; Artisan could not place a Crafting Table; Farming had no plot; Runecrafting had no nearby altar; Home Teleport could not claim a bed. An initial axe run ended in death, then its retry passed.

All three new FX checks falsely read probe fields at the top level: client_cmd returns {ok, result: {...}}, but the criteria reference fx_before.runs and similar instead of fx_before.result.runs. Probe tokens and counters in the recorded results stayed in one process; those failed verdicts do not demonstrate crashes. Splinter was also interrupted by combat and re-enchant encountered cooldown, so coverage remains incomplete.

## Actual autonomy status
The full no-axe -> gather sticks/stone -> build table -> craft axe -> chop tree chain was promised as Director run 4 but is not proven complete in the reviewed record. The shield run remained incomplete; planning found the recipe dependencies but navigation, survival, crashes and test call limits interrupted execution. Small steps and some sequences work; long reliable autonomous jobs remain the goal.

## Verification during this inspection
52 focused Python tests passed (speech channel, places, spell rules). Existing Lua movement, local planner, FX guard (14/14), and places suites passed. No new live tests, model calls, deployments, game restarts, source edits or commits were performed. Existing Lua tests do not prove the unfinished new traversal feature.

At inspection the dev server and headless client were running; watchdog and reflex services were reporting, and no live-test reservation remained. A live brain process was not identified. Source on disk can differ from already-loaded Lua modules until a reload.

## Recovery order
Review/finish the explicit speech channel and explain the prior full-suite failure; fix the FX-check JSON paths and re-check effects; review the late skill/region results and update stale docs; complete traversal execution/calibration/perception/tests; implement the pending-planner responsiveness work; then run the no-axe tree task end to end and collect fresh goal metrics.

## GitHub recovery checkpoint

At Luis's request, this report and RECOVERED-GOAL.md accompany a WIP snapshot of all 25 interrupted source/data/test files. The snapshot preserves unfinished work; it is not a green release or a claim that the goal is met. Raw Claude transcripts, runtime logs, saves, local wiki data, credentials and SSH keys stay outside version control. The original commit history and judge tags are preserved.
