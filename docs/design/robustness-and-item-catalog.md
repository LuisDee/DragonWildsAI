# Robustness ("crash-proof") and the item catalog: design (2026-10-25)

Luis asked two things: how to make the companion crash-proof, and how it can use any weapon or item without being slowed down in real deployment.

## 1. Crash-proofing

Key fact: **`pcall` does not protect us from native crashes.** A bad argument or a game null-dereference kills the process. So robustness comes from layers.

| Layer | What | Status |
|---|---|---|
| 1. Never take known-crashing paths | Puppet lifecycle module. The puppet is never unpossessed; removal means hide plus teleport plus park its AI. One puppet per server run, reused across player sessions. Immortal (`SetIsImmortal`) so death never runs the unpossess path. | to build (`mod/body/puppet.lua`) |
| 2. Fix the root cause | The unpossess crash is `PC->LoadoutComponent` on a null PC. Experiments: before unpossess, unbind or destroy the components whose controller-changed handlers touch the loadout (PlayerEquipmentComponent, attack/loadout-delegate components), or clear `ReceiveControllerChangedDelegate`. Bisect offline: the watchdog makes crashes cheap. | next, offline |
| 3. Safe call surface | Native calls come only through a small set of wrapper functions, each verified in game once and then frozen. Prefer functions with scalar arguments. Struct and array arguments (for example `PredictDamage`'s `TArray<FTypeDamage>`) are only allowed through wrappers that build the struct the way UE4SS expects. Unverified calls run only in `*_test.lua` debug modules. | in progress |
| 4. Validate before calling | Check `IsValid`, check the class (`IsA`), check distance and range, and refuse to call methods on objects that are pending kill. Use a precondition table per wrapper. | to build |
| 5. Fail fast and recover | `tools/watchdog.ps1`: when a crash dump appears it kills and restarts the server, and it restarts a missing process. On restart the mod respawns the puppet from the persisted bot state (layer 7). | **done** (watchdog) |
| 6. Know what crashed | UE4SS dumps plus `cdb` (stack, exception), offset lookup in CXXHeaderDump, Lua breadcrumbs flushed per line. Next: auto-analyse each new dump with `cdb` into `logs/crashes.jsonl` (exception, top frames, last breadcrumb). | partly done |
| 7. Persistent bot state | The bot's gear, inventory and stats live server-side in `logs/state/bot.json` (or SQLite) and are re-applied on spawn. World backups come from `update_server.ps1`; take a snapshot before risky sessions. | to build |
| 8. Canary before live | A new native call is first run offline (no players) by the test harness, and only then promoted to the live skill registry. That is CLAUDE.md principle 3. | process |
| 9. Patch safety | After each game patch, regenerate the dump and run smoke tests. Class and offset changes show up as wrapper failures, not crashes, because of layer 4. | process (CLAUDE.md section 8) |

## 2. Item catalog: any weapon or item, used correctly, with no runtime discovery

Goal: the companion can equip any weapon or armour (picked up, given, or chosen), knows how to fight with it, and pays no lookup cost at play time.

**Build once per game build (offline), store as `data/items_<build>.json`:**
- Enumerate every `UHeldEquipmentData` (weapons and tools) and `UWearableEquipmentData` (armour). 168 and 235 were loaded at idle; the asset registry lists the rest, including unloaded ones.
- Record per item:
  - path and display name
  - category (sword, mace, greatsword, bow, staff, axe, pickaxe, torch...)
  - slot (right/left hand, head/body/legs/cape)
  - tier and stats
  - `HeldEquipmentActorClass`
  - the attack set the game uses for that category (`BP_Player_<Cat>_Attack1..N`, `PA_Attack_<Cat>`)
  - its range type (melee/ranged/magic)
- Source: UE4SS asset registry calls (`AssetRegistryHelpers` / `AssetRegistry:GetAssetsByClass`) plus property reads; the reflection dump for the field names.

**Use at runtime:**
- `equip(item_id)` loads the data asset (`StaticFindObject`, else `LoadAsset` once, then cached), spawns its `HeldEquipmentActorClass`, attaches it to `prop_r`/`prop_l`, and sets the replicated slot (the method verified on 2026-10-25).
- **"Knows how to use it"** is a per-category combat profile, written once in code: melee approaches and swings with that category's attack set; bow keeps distance and fires; staff casts. The planner and controller choose a weapon by catalog stats (damage, range) for the situation.
- Picking up loot: a world drop (`RuntimeSpawnedWorldItem`) carries its item data, so map it to the catalog, then `equip` or stash it in the bot's inventory (layer 7). No player inventory component is needed.
- Preload the attack-set assets for the bot's current weapons at spawn, so the first swing has no load hitch. (Only sword attacks were loaded at idle; mace and other attack sets load on demand.)
