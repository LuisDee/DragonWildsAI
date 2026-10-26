# Combat memory: what he learns in fights survives a restart (2026-10-26, combat agent)

GOAL row: **combat tactics → damage taken per fight drops over repeated fights with the same creature** (`goal_targets.json` `combat_tactics.damage_taken_trend`, case `goal_tactics_damage_trend`, 5 fights). The per-attack learning already existed: timing, parry offset, lunge, reach, damage, the response bandit and cadence in `defense.lua`; damage-type verdicts and swing stamina cost in `combat.lua`; projectile profiles in `ranged.lua`. But it lived only in `_G`, and the client restarts routinely (watchdog relaunch, the L24 front-end policy, crashes). So five fights could not be relied on to build on each other, and the brain could not see how earlier fights went.

## Design

- **One JSON file per world and character:** `data/skills/<world>/combat_memory_<character>.json`.
  - The layout follows `nav_memory.json`, and the world id comes from `DW_WORLD_GUID`, then `client_io/world_guid.txt`, then `shockbyte`, the same as `traverse_learn`.
  - Contents: `{v, build, world, character, saved_at, defense = D.export(), ranged = R.export(), learned, press_cost, history}`.
- **Load once:** the first fight or `combat_brief` for a world and character calls `combat.memory(log, pawn)`.
  - It imports per key: a saved record replaces a session record only when it has more observations (`n`).
  - Cadence keeps the learned interval but never the world clock of the last attack (`last_t`), because the next attack restarts the clock.
- **Write only at a fight's end** (`finish`, after the fight is cleared). The write is plain file I/O with no game call:
  1. write `.tmp`;
  2. rename the old file to `.bak`;
  3. rename `.tmp` to the file;
  4. remove `.bak`.
  - Lua's `os.rename` will not replace an existing file on Windows (checked here: `nil, "File exists", 17`), hence the `.bak` step.
  - A crash between the two renames leaves `.bak`, and the next load reads it.
  - The world folder is created once, only if the first write fails.
- **Build tag:** the client build comes from `DW_CLIENT_BUILD`, else the Steam `appmanifest_1374490.acf` `buildid`.
  - **A file from another build is refused loudly.** The log line is `combat: MEMORY REFUSED: memory from build X refused (client build Y); kept as …build-X.json; learning starts again`, and `combat_status.memory` / `combat_brief.memory` report status `refused_stale` with the detail.
  - A corrupt file gets the same treatment (`corrupt`, kept as `.corrupt-<time>.json`).
  - If the build is unknown, the file loads with status `loaded_build_unknown`.
- **Fight history per creature** (last 10): `{at, outcome, reason, damage_taken, dur_s, kills, parries, blocks, dodges, heals, weapon}`.
  - `combat_brief.history` = `{fights, first_encounter, damage_taken = [series], outcomes, last_at}`.
  - `attacks_learned` gains `best_response` and `best_rate` (the bandit posterior mean).
  - **Information only:** nothing in the code reads the history to refuse or steer a fight.
- **Creatures he hasn't fought, family priors** (`defense.family_prior`, `combat.family_affinity`):
  - Tokens come from the names in the data: creature names and attack asset names, split on non-letters and CamelCase, lower-cased, generic words dropped. There are no hand-written families.
  - The closest learned key with **the same attack asset**, else a shared creature token plus a shared attack token, stands in as a prior. Its source is labelled `prior:family`, as `impact_delay`'s source, `threat.prior` and `weaknesses.family`, and it is never counted as learned. Bandit arms are not transferred.
- **Tests (`client_mod/tests/test_combat.lua` §22, 26 checks):**
  - no write during the fight loop, and exactly one tmp-then-rename write at the end;
  - a restart round trip: timing, bandit, weakness and rhythm survive, and the rhythm restarts cleanly;
  - history grows per creature and appears in `combat_brief` with the memory status;
  - family priors: same attack, family, unrelated, labelled;
  - a stale build is refused, logged and kept; a corrupt file is tolerated; recovery from `.bak`.
  - The other test sections run with the memory off (`cfg.memory_enabled = false`) so they cannot learn from each other, and the test memory root is a temp folder, never the repo.

## Search record (search-before-building)

- **Persisting a bandit across sessions:** nothing found specifically. The discounted Thompson sampling literature decays counts per decision step: [Raj & Kalyani, Taming Non-stationary Bandits](https://arxiv.org/pdf/1707.09727), [Discounted TS](https://arxiv.org/abs/2305.10718), [Russo et al., A Tutorial on Thompson Sampling](https://arxiv.org/pdf/1707.02038), which also covers sliding windows. Decision: keep the counts as they are across restarts, and treat the build change, which may change creature behaviour, as the reset point (refuse stale). Revisit decay if live trends show stale arms.
- **Atomic replace on Windows from Lua:** C `rename()` does not overwrite an existing target on Windows, the reason Python added `os.replace` ([bugs.python.org](https://bugs.python.org/msg292662), [ConTeXt list](https://mailman.ntg.nl/archives/list/ntg-context@ntg.nl/message/AKRPRIKO74BVZELJJKSWAXXB5KFABKC7), [Playdate forum](https://devforum.play.date/t/file-rename-errors-if-target-file-exists/22840)). Verified on this machine's Lua. Decision: the `.bak` swap above, with reuse of the repo's own pattern: `brain/fileio.atomic_write` (Python, `os.replace`) and `navmem.lua`'s remove-then-rename, which this improves by keeping `.bak` until the new file is in place.
- **Reuse:** the dkjson module the client already uses, and the `data/skills/<world>/` layout of nav memory and traversal links.

## Pending (live)

The 5-fight trend proof with a client restart partway through goes in the queued combat slot, together with the loot-hit retest and the L34 wall check. Evidence: `combat_brief.history.damage_taken` across the restart, plus the server `PredictPointDamage` lines.
