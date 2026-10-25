# Runbook: game patch (server + companion)

Run this after every Dragonwilds patch (CLAUDE.md section 2 "Game patches", design: `docs/design/robustness-and-item-catalog.md` section 11). GFN updates Luis's client automatically and the server must match, so a patch means a short outage.

Goal: one report, `docs/patches/<old>_to_<new>.md`, that says what is **auto-supported**, what **needs review**, and what is **BROKEN (fix before play)**, plus a smoke test that passes before Luis plays again.

All commands run from `C:\gameserver` in PowerShell. `OLD` is the build we run now (read it first), `NEW` is the build after the update.

```powershell
$OLD = (Select-String -Path C:\GameServers\Dragonwilds\steamapps\appmanifest_4019830.acf -Pattern '"buildid"\s+"(\d+)"').Matches[0].Groups[1].Value
```

`dumps\<OLD>` (gitignored, about 170 MB per build) is the baseline and must exist before you update; today `dumps\26161880` is it. If the current build has no snapshot yet, run `tools.patch_pipeline snapshot` now (the dump in the server's `ue4ss\` folder is still the old build's), before step 1 changes anything. Keep the last two builds.

## Time and people

| Step | What | Time | Luis needed? |
|---|---|---|---|
| 1 | Notice, stop server | 2 min | Yes: warn him, agree a time, he must leave the world |
| 2 | SteamCMD update | 5 to 15 min (about 5 GB with `validate`) | No |
| 3 | UE4SS still loads | 2 min | No |
| 4 | Deploy with `-Dump`, start, wait for the dump | 6 to 8 min (boot 1 to 2, dump delay 2, dump about 3 during which the game thread is frozen) | No, but he must not join until it finishes |
| 5 | `snapshot` | 1 min | No |
| 6 | Rebuild catalogs | 5 to 15 min (LoadAsset batches stall the game thread, so it runs staged) | No |
| 7 | `report` | under 1 min | No |
| 8 | Smoke tests | 1 min server-only; about 3 min with Luis for the in-game part | Yes, briefly, for the player checks |
| 9 | Agent fixes BROKEN, then review items | 30 min to several hours, depends on the patch | Only for new in-game verification |

Total outage for Luis: steps 1 to 4 and 6 (about 30 to 45 min). Steps 5, 7 and 9 do not need the server.

## 1. Stop the server, with notice to Luis

Tell Luis first (chat or message): "Patching the server, about 30 minutes, please log out." Then:

```powershell
tools\stop_server.ps1 -Hold
```

`-Hold` creates `logs\server.stopped` so the watchdog does not restart it during the update. (`update_server.ps1` calls `stop_server.ps1` too, without `-Hold`, which is why the hold flag is set here first.) The server autosaves about every 5 minutes, and `update_server.ps1` backs up `Saved\` to `C:\GameServers\backups\`.

## 2. Update

```powershell
tools\update_server.ps1
```

It prints `Build: <old> -> <new>`. If the build did not change, stop here (the patch has not reached Steam yet, or GFN is ahead; ask Luis whether his client updated before continuing, because a mismatch stops him joining).

Record the new build id: add a line to `docs/DISCOVERIES.md` (Environment, "Dedicated server install") and `docs/PROGRESS.md`.

```powershell
$NEW = (Select-String -Path C:\GameServers\Dragonwilds\steamapps\appmanifest_4019830.acf -Pattern '"buildid"\s+"(\d+)"').Matches[0].Groups[1].Value
```

## 3. Check UE4SS still loads

`validate` can remove files the game does not ship, and a new engine version can break UE4SS's signature scan. UE4SS enters through the Ultimate ASI Loader (`version.dll` plus `version.ini`; see DISCOVERIES, "UE4SS on the dedicated server"). Check the files exist:

```powershell
$w = 'C:\GameServers\Dragonwilds\RSDragonwilds\Binaries\Win64'
'version.dll','version.ini','ue4ss\UE4SS.dll','ue4ss\UE4SS-settings.ini' | ForEach-Object { "{0,-28} {1}" -f $_, (Test-Path "$w\$_") }
Get-Content "$w\version.ini"      # LoadFromScriptsOnly=1, LoadExtraPlugins=ue4ss\UE4SS.dll
```

If any is missing, run `tools\install_ue4ss.ps1`. After the first start (step 4), confirm in `$w\ue4ss\UE4SS.log`: `Using engine version`, a successful PS scan, and `Starting Lua mod`. Symptoms of a broken loader: the server process sits at about 6 MB with no log, or `UE4SS.log` has no new lines.

If the engine version changed (UE 5.6 to something newer) and UE4SS fails, that is a decision point: look for a newer UE4SS release (experimental-latest) and re-run `install_ue4ss.ps1`. Do not start native disassembly without asking Luis (CLAUDE.md section 2).

## 4. Deploy with a dump, start, wait for the dump

The dumper (`mod/scripts/dumper.lua`) stalls the game thread for about 3 minutes (the UHT headers alone took 138 s on the last run), so the watchdog's heartbeat check would kill and restart the server mid-dump. Stop the watchdog for this step:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*watchdog.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
tools\deploy_mod.ps1 -Dump
tools\start_server.ps1
```

The dump runs once, 120 s after the mod loads, then deletes `dump.flag`. Wait for the last stage (`GenerateUHTCompatibleHeaders`), which is logged as a `dump_done` event:

```powershell
$deadline = (Get-Date).AddMinutes(10)
do { Start-Sleep 15; $done = Select-String -Path logs\mod\mod_*.jsonl -Pattern 'GenerateUHTCompatibleHeaders' -ErrorAction SilentlyContinue | Where-Object { $_.Line -like '*dump_done*' } | Select-Object -Last 1 } until ($done -or (Get-Date) -gt $deadline)
$done.Line
```

Check that the line reports `"ok":true`. Then restart the watchdog: `tools\start_watchdog.ps1`. Keep Luis out of the world until this is done: his connection would freeze with the game thread.

If the server does not come up, or crashes (a new `crash_*.dmp` in `ue4ss\`), do not continue: use `docs/DISCOVERIES.md` "ROOT CAUSES of the freezes" and the watchdog log, and report to Luis with the evidence.

## 5. Snapshot the dumps

Copies `UE4SS_ObjectDump.txt`, `CXXHeaderDump\`, `UHTHeaderDump\` and the Lua types into `dumps\<NEW>\` and builds `index.json.gz`. It refuses if the dump is older than the server binary (that would be the previous build's dump) or if `--build` does not match the SteamCMD manifest.

```powershell
.venv\Scripts\python.exe -m tools.patch_pipeline snapshot --build $NEW
```

(`--dry-run` shows what it would copy; `--force` overwrites an existing snapshot.)

## 6. Rebuild the catalogs

The server must be up with the new build and the redeployed mod. The item catalog drives the live server through `debug_run catalog` and LoadAsset batches, so run it before Luis joins:

```powershell
.venv\Scripts\python.exe -m tools.build_catalog --build $NEW --notifies --montage
.venv\Scripts\python.exe -m tools.gen_attack_data --catalog data\items_$NEW.json    # regenerates mod/body/attack_data.lua
```

(Cautious first run: add `--limit 5 --max-batches 2`. `tools\build_catalog.py` has `BUILD = "26161880"` as its default and a `CATEGORY_ACTION_FALLBACK` table baked from the old dump: `--build` is mandatory, and the report lists any new weapon category for you to extend that table.)

The spell catalog (`data/spells_<build>.json`) comes from the spell dump experiment (`mod/experiments/spell_dump.lua`, merged by `spell_merge.lua`; see `docs/PROGRESS.md` for the current command). Run it the same way and save to `data\spells_$NEW.json`. If it is not repeatable yet, the report says `spells_<NEW>.json` is missing and that spell items stay in review. Enemy catalog: same, `data/enemies_<build>.json` once it exists.

Recipe catalog (read-only, a few seconds; the new dump must exist first because the station template paths come from `dumps\$NEW\UE4SS_ObjectDump.txt`):

```powershell
.venv\Scripts\python.exe -m tools.build_recipes --build $NEW --wiki-check   # data\recipes_$NEW.json + mod\body\recipe_data.lua
```

`catalog-diff` then lists added/removed/changed recipes. If any changed, deploy the regenerated `recipe_data.lua` (restart) and re-run the crafting drift check with Luis doing one real craft: `.venv\Scripts\python.exe -m tools.craft_drift run` (exit 0 = the catalog still matches the game; the report also lists the RPCs his craft sent, so a renamed crafting RPC shows up here).

If `gen_attack_data` changed `mod/body/attack_data.lua`, redeploy (`tools\deploy_mod.ps1`) and restart after the checks.

## 7. Report

```powershell
.venv\Scripts\python.exe -m tools.patch_pipeline deps                 # refresh data\dependencies.json (what the mod depends on)
.venv\Scripts\python.exe -m tools.patch_pipeline report $OLD $NEW     # writes docs\patches\<OLD>_to_<NEW>.md and .json
```

`report` re-extracts the dependencies from `mod/**/*.lua`, `tools/build_catalog.py` and `brain/BRIDGE_PROTOCOL.md` against the OLD dump, checks each against the NEW dump, and diffs the catalogs. Add `--strict` to exit 2 when anything is BROKEN. Read the Markdown:

- **BROKEN (fix before play)**: something we hook, call or read was removed or changed (class, function signature, property type, enum value, Blueprint member, catalog asset). Native names are checked against the dump; asset paths are cross-checked against the new catalog, because the object dump lists loaded objects only.
- **Needs review**: renamed parameters, new classes in the families we care about (player actions, held and wearable data, creatures, spell modules), changed catalog source classes, new weapon categories, changed attack chains, new spells (they need role tags), changed items.
- **Auto-supported**: additions the catalogs pick up with no code change (new items in known categories, new enemies in the catalog, additive classes and functions).

Offsets are never relied on, so offset-only changes are listed as info.

Individual views: `patch_pipeline diff <OLD> <NEW>` (dump only) and `patch_pipeline catalog-diff <OLD> <NEW>`.

## 8. Smoke tests

Server-only part (no Luis; read-only: ping, capabilities, get_state, body_status, `debug_run body_probe`, catalog spot checks, native dependencies resolve in the dump):

```powershell
.venv\Scripts\python.exe -m tools.smoke_test
```

Exit code 0 means no failures. Then the player part, with Luis connected. It acts in the world (spawns the puppet, follows, speaks, attacks a hostile if one is near), so it needs `--active` and a yes/no from Luis:

```powershell
.venv\Scripts\python.exe -m tools.smoke_test --active
```

Ask Luis, in one message: "Please join. Do you see Claude next to you, did it follow when you walked, did you see its chat line? Anything odd?" Attack needs a hostile nearby: ask him to walk to one if none is close (or skip, and say so in PROGRESS). The matching checklist from CLAUDE.md section 8: ping, capabilities, body_spawn, follow, say relay, attack.

Do not let Luis play on a world with a failed smoke test; his real world is on Shockbyte and is not affected.

## 9. Agent work from the report

1. For each **BROKEN** row: find the replacement in `dumps\<NEW>\CXXHeaderDump\` (grep the class), fix the mod or tool, hook-test it on the dev world, record the finding in `docs/DISCOVERIES.md` with the new build id. Rerun `deps` and `report` until BROKEN is empty and `smoke_test` passes.
2. Work the **Needs review** list: add role tags for new spells, a combat profile for new weapon categories, check changed attack chains and stats in `data/items_<NEW>.json`.
3. Update `docs/DISCOVERIES.md`, `docs/PROGRESS.md`, `docs/tasks.json`; run `.venv\Scripts\python.exe -m pytest tests -q`; commit `data/`, `docs/patches/` and the fixes (`dumps\` is gitignored).

## 10. Claude's game client (route R2)

Claude plays through a real headless client on this VM (Steam account bootymaxer, app 1374490, UE4SS + `DWClient`), joined to the Shockbyte world. That server is updated by Shockbyte, not by us. The client must match its build, or the join fails. Steps 1 to 9 above are for the dev server. Do these for the client:

1. **Stop the client and hold it**, so the client watchdog does not relaunch it mid-update:
   ```powershell
   tools\stop_client.ps1 -Hold          # kills the client, writes logs\client.stopped; Steam keeps running
   ```
   (`logs\client.hold`, created by hand, works the same way.)
2. **Update through the Steam client.** The VM's Steam is logged in as bootymaxer, and the app has `AutoUpdateBehavior` 0 ("always keep updated"), so Steam downloads the patch by itself once the game is closed. SteamCMD can't do this: it would need bootymaxer's password and Steam Guard. Watch the manifest until the build changes and `StateFlags` is back to 4 (fully installed):
   ```powershell
   Select-String 'C:\Program Files (x86)\Steam\steamapps\appmanifest_1374490.acf' -Pattern '"buildid"|"StateFlags"|"TargetBuildID"'
   ```
   If Steam has not noticed the patch after a few minutes, restart Steam so it checks again: `& 'C:\Program Files (x86)\Steam\steam.exe' -shutdown`, wait for it to exit, then `& 'C:\Program Files (x86)\Steam\steam.exe' -silent`. **[UNVERIFIED: no client patch has been applied this way yet.]** Record the new client build in `docs/DISCOVERIES.md` and `docs/PROGRESS.md`.
3. **Check that UE4SS survived.** An update can replace or remove files the game does not ship. Look for `version.dll`, `version.ini` and `ue4ss\UE4SS.dll` in `C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64`, and `ue4ss\Mods\DWClient`. If any is missing, run `tools\install_client_ue4ss.ps1` (the client must be closed).
4. **Boot, join and smoke-test:**
   ```powershell
   tools\client_smoke.ps1 -Release                      # -Release clears the hold; boot_and_join, then read-only checks
   tools\client_smoke.ps1 -NoBoot -AllowMove -Chat      # walk 2 m, one jump, one chat line (clear with main/Luis first)
   ```
   Each step reports pass, fail or skip, and the report goes to `logs\client_smoke_<ts>.json`. Exit code 0 means everything that ran passed.
   - The default run makes no movement and no chat.
   - `-AllowMove` moves the pawn, so the locomotion owner must agree.
   - `-Chat` writes one line in Luis's world chat.
   - If `boot` fails, `logs\client\boot.log` has the reason, for example `join_failed: ... [DuplicateChar]`, `sign_in_failed`, `no_pawn` or `runner_timeout`.
   - If the runner never answers, UE4SS or DWClient did not load: read `ue4ss\UE4SS.log` beside the client exe.
5. **Restart supervision:** `tools\start_client_watchdog.ps1`. It is a no-op if it is already running.

Day-to-day client operations (not only after patches):
- `tools\client_boot.ps1` is the idempotent boot_and_join. It is a no-op when Claude is in the world with services up. `-DryRun` only reports what it would do. Status goes to `logs\state\client_status.json`.
- `tools\client_watchdog.ps1` (start it with `tools\start_client_watchdog.ps1`) recovers the client from crash, hang and disconnect, and keeps the nav oracle and the nav-only dev server alive. Events go to `logs\client_watchdog.jsonl`. Hang stacks go to `logs\client\hang_<pid>_<ts>.txt`.
- Offline tests against a fake client: `.venv\Scripts\python.exe -m pytest tests\test_client_ops.py`.
- **Which server Claude joins:** `tools\client_boot.ps1 -Target dev` joins `client_io\secrets\server_dev.txt` (the nav-only dev server, 127.0.0.1:7777; the password is copied from the dev server's `DedicatedServer.ini` and is never printed). Without `-Target`, an unexpired `logs\state\client_target.json` lease wins, otherwise Shockbyte (`server.txt`). In the world on the wrong server, boot disconnects and rejoins. The client watchdog does the same after 60 s (`wrong_server` event), but only once it has been restarted after 2026-10-25 20:50. See ARCHITECTURE section 8.6.

### Before every live session: the dev-server scenario suite (streamline plan step 6)

It moves Claude off Luis's world for a few minutes, so main must OK the slot and the live brain must be stopped.
```powershell
.venv\Scripts\python.exe -m tools.scenario_run                     # dry run: read-only, any server, no switch
.venv\Scripts\python.exe -m tools.scenario_run --live              # Shockbyte -> dev -> scenarios -> Shockbyte
.venv\Scripts\python.exe -m tools.scenario_run --live --only pit_escape,ledge_jump
.venv\Scripts\python.exe -m tools.scenario_run --here              # already on dev: run there (refused on Shockbyte)
```
- **Scenarios** (`tools\scenarios\dev_suite.json`, each with its own `pass` text):
  - `pit_escape`, `pit_to_grave_area`: the start-area respawn trap;
  - `waypoint_course`: a go_to chain standing in for follow;
  - `ledge_jump`: a 0.6-1.4 m ledge found by traces;
  - `fetch_consume`: what lies around on dev;
  - `combat_weak`: a weak creature, if one is near;
  - `grave_recovery`: only after a natural death.
  - Each answers pass, fail, skip or error.
- **Preflight aborts** before anything moves when any of these holds: the client is not in the world, a hold file exists, `run_live` is running, the client is not on Shockbyte, the dev server is down, or the dev target file is missing.
- **Report:** `logs\scenarios\scn_<ts>_<mode>.{json,md}` plus `_timeline.txt` for the run window. The JSON holds per-scenario evidence, the switch results and the Shockbyte before/after diff. Exit code 0 = pass (or dry run).
- **If it dies mid-run:** the lease expires (45 min at most, renewed per scenario), and the next boot or watchdog check brings Claude back to Shockbyte. To do it now: delete `logs\state\client_target.json`, then run `tools\client_boot.ps1`.

### Diagnosis: one timeline
```powershell
.venv\Scripts\python.exe -m tools.timeline --since 19:20 --until 19:30            # UTC; --local for local time
.venv\Scripts\python.exe -m tools.timeline --around 19:22:21 --window 90 --src chat,brain,move
.venv\Scripts\python.exe -m tools.timeline --since 30m --grep "unreach|stuck|thirst" --all
.venv\Scripts\python.exe -m tools.timeline --since 19:20 --html logs\timeline.html --jsonl logs\timeline.jsonl
```
- **What it merges:**
  - `chat.jsonl`, the brain-live logs that overlap the window, `move`, `vitals` and the other `client_io\events` files;
  - `client_watchdog.jsonl`, `boot.log`, `client.log` and `mod_*.jsonl`;
  - the client game log (joins, travel, failures and `FlushAsyncLoading` only);
  - scenario reports.
- **Noise:** pings, probes, raw bridge traffic and module loads are hidden unless `--all`. Runs of identical lines collapse to `(xN)`.
- **Interactive browsing:** lnav (installed with `winget install tstack.lnav`; the format is installed once with `lnav -i tools\lnav\dw_timeline.json`), then `lnav logs\timeline.jsonl`. It gives filters (`:filter-in`), a histogram and SQL, e.g. `;SELECT src, count(*) FROM dw_timeline GROUP BY src`.

## Notes

- The pipeline never talks to the live server except `smoke_test` (read-only unless `--active`). `snapshot`, `deps`, `diff`, `catalog-diff` and `report` work from files and are safe while Luis plays.
- `dumps\<build>\index.json.gz` is a cache of the parsed dump (classes, enums, assets, Blueprint members). It is rebuilt automatically when the dump files change.
- Tests for the pipeline run on small synthetic dumps: `tests\test_patch_pipeline.py`, `tests\test_smoke_test.py`.
