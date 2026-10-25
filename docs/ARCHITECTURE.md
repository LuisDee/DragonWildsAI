# Architecture: how to add features without reinventing the wheel

This is the single source of truth for **where code goes** and **which rules it follows**. CLAUDE.md says *what* we are building and *why*. DISCOVERIES.md says *what is proven* in the game. This file says *how the code is organised* so that each new feature reuses what exists.

Read it before adding a skill, a hook, a service or an experiment. When the layout changes, update this file in the same change.

---

## 1. Layers

```
 brain/ (Python, event-driven)        Controller · Planner · Executor · state store
        │  GameInterface (brain/interface.py): tool names, arg schemas, Reason codes
        ▼
 bridge protocol (brain/BRIDGE_PROTOCOL.md v1): JSONL files, cmd / result / error / event
        │  brain/bridge_client.py + transport.py   ⇄   mod/scripts/bridge.lua
        ▼
 body skills (mod/body/skills.lua): one bridge handler per tool, probe-safe, async actions
        │  ticked by ONE game-thread loop; success comes from re-read game state
        ▼
 body services (mod/body/*.lua): puppet, gear, combat, spells, speech, identity, removal
        │  each owns one concern and exposes a small API
        ▼
 shared core (mod/body/util.lua + mod/scripts/{dwlog,jsonutil}.lua)
        │  guarded access, alive checks, player/puppet split, U.call breadcrumbs
        ▼
 UE4SS / native (Unreal reflection: FindAllOf, StaticFindObject, UFunction calls, RegisterHook)
```

**Dependencies point downwards only.** A service may use util and other services, never skills. Skills use services. Only `main.lua` wires the layers together. Experiments (`mod/experiments/`) may use anything in `mod/body/`, but nothing in `mod/body/` or `mod/scripts/` may require an experiment, except `main.lua` loading the legacy `experiments.companion` behind its opt-in flag.

---

## 2. Modules and their public API

### 2.1 Infrastructure (`mod/scripts/`): needs a server restart to change

| Module | Responsibility | Public API |
|---|---|---|
| `main.lua` | Entry point. Sets `package.path`, the logger and `U.set_log`, then wires bridge, debug_run, body, speech, hooks, heartbeat and perf sampler. **The only place that registers subsystems.** | — |
| `dwlog.lua` | Append-only JSONL log, one file per run; every line is flushed (breadcrumbs survive a crash). | `init(dir)`, `event(name, data)`, `path()` |
| `jsonutil.lua` + `dkjson.lua` | JSON (vendored dkjson 2.8, MIT); never fatal on userdata or cycles. | `encode`, `decode`, `null`, `object(t)` |
| `bridge.lua` | Body side of the JSONL bridge: tails `brain_to_body.jsonl`, dispatches to handlers on the game thread, writes results and events. Copies the cmd's top-level `probe` flag into `args.probe`. | `handlers[name] = fn(args, ctx)`, `reply(id, res)`, `emit_event(name, data)`, `null`, `object` |
| `hooks.lua` | Discovery and production hooks (`RegisterHook`) with per-hook extractors. The chat extractor feeds `command_received`. | `register(log, {tag = fn(fields, ctx)})`, `HOOKS`, `PENDING` |
| `debug_cmds.lua` | `debug_run {module, fn, args}`: `loadfile`s `<name>.lua` from `scripts/`, then `experiments/`, and calls `module[fn](log, args)`. No restart needed for the named file. | `register(bridge, log, dirs)`, `resolve(dirs, name)` |
| `dumper.lua` | Headless reflection dumps when `dump.flag` exists. | `maybe_dump(mod_root, log)` |
| `catalog.lua` *(combat agent)* | Item catalog generator, driven by `tools/build_catalog.py`. | `run(log, args)` via debug_run |
| `recipe_dump.lua` *(crafting agent)* | READ-ONLY recipe/station/unlock extractor (recipes, station templates + data-table rows via `UDataTable:ForEachRow`, `DT_Progression_*`, Luis's `RecipesUnlocked`), driven by `tools/build_recipes.py`. | `run(log, args)`, `probe` via debug_run |
| `perf_sampler.lua` *(telemetry agent)* | Frame-time sampler, writes `logs/perf/mod_perf.jsonl`. | `run(log, args)` via debug_run / main |

### 2.2 Shared core: `mod/body/util.lua` (`local U = require("body.util")`)

**Every module uses these instead of redefining them.** The API is additive: never change an existing signature (skills/gear/puppet depend on all of it). `U.try` returns exactly **one** value on purpose, because callers write `tonumber(U.try(...))`.

| Group | Functions |
|---|---|
| Logging, breadcrumbs | `set_log(log)`, `get_log()`, `event(log, name, data)`, `crumb(log, step, data)`. `log` may be nil, in which case the default logger is used. |
| Guarded access | `try(f, ...)` → value or nil; `try_err(f, ...)` → value, or nil and the error; `valid(o)`; **`alive(o)`** (valid and not `Garbage\|Unreachable`, flags `0x10200000`); `GARBAGE_OR_UNREACHABLE` |
| Names | `fullname(o)`, `short(o)` (entity id on the wire), `path_of(o)` (path without the class word), `class_word(o)`, `class_name(o)`, `str(v)` (FString/FName/FText) |
| Finding | `find_all(class, {skip_defaults, valid_only})` (alive only by default, always a table), `find_first(class)`, `find_object(path)` (StaticFindObject, never loads) |
| Geometry (cm in game, m on the wire) | `loc(a)`, `dist`, `dist2d`, `actor_dist`, `forward(a)`, `in_front(a, ahead_cm, up_cm)`, `round`, `to_wire`, `from_wire`, `cm_to_m` |
| Players vs puppet | `PLAYER_CHAR_CLASS`, `PLAYER_CONTROLLER_CLASS`, `controller_of(p)`, `is_player_controller(c)`, **`split_pawns()`** → players and puppets (zombies skipped), `player_controllers()`, `player_state(p)`, `player_id(p)`, `player_name(p)`, `find_player(who, loose)`, `PLAYER_ALIASES`, `health(a)`, `max_health(a)` |
| GUIDs | `guid_hex(g)`, `guid_from_hex(h)`, `guid_copy(g)`, `guid_set(dst, src)` (field by field), `guid_eq(a, b)` |
| Results | `result(ok, reason, data)`, `ok(data)`, `fail(reason, data)`: the `{ok, reason, data}` shape |
| **The guarded native call** | **`call(log, label, data, fn)`** → `ok, res`. It logs `native {call=label}` and flushes **before** `fn` runs, and logs `native_error` on a Lua error. |

### 2.3 Body services (`mod/body/`)

| Module | Owns | Public API (summary) | Verified? |
|---|---|---|---|
| `puppet.lua` | The **one** puppet per run: spawn, possess, immortal, park/unpark, adopt after reload, persisted gear (`DW_BOT_STATE`). | `init`, `get`, `controller`, `ensure_spawned`, `ensure_ready`, `park`, `unpark`, `teleport_near`, `status`, `start` (lifecycle loop, `DW_PUPPET_AUTOSPAWN=1`), `set_safe_remover`, `remember_gear`, `saved_gear` | Spawn, possess, MoveTo and immortal: yes. Park/unpark: no. |
| `removal.lua` | Crash-free removal of a puppet: strip `PlayerRangedAttackComponent`, unpossess, then `SetLifeSpan` the pawn, the held actors and the controller. | `safe_remove(p, {unpossess, log})`, `remove_all(log, opts)`, `remove_orphan_controllers(log)`, `UNSAFE_COMPONENTS` | Yes, offline bisect 1–2g. Death path untested. |
| `gear.lua` | Equip by writing replicated equipment state; read gear back. **Equips only owned items** (`not_in_inventory` otherwise; `debug_unowned=true` is a debug override the brain never sends). | `equip(log, p, item_path, {hand, actor_class, debug_unowned})`, `read(p)`, `slot_for`, `category` | Wearables and right hand: yes. Left hand and replacement: no. |
| `inventory.lua` | The bot's persistent store of item **instances** (count, level, ascension, enchant, durability, ...), stacking by `MaxStackSize`, equipped flags. Persists as the `inventory` section of the bot state file (`puppet.section`/`set_section`); migrates persisted gear once. | `init({log, puppet\|state_path})`, `count(item)`, `take(item, n)` (the spells budget API), `add(inst)`, `put_back`, `summary`, `detail`, `resolve(name)`, `find_for_equip`, `mark_equipped`, `grant` | Offline tests; live: gear migration ran at the 14:45 restart. |
| `items.lua` | World items (`RuntimeSpawnedWorldItem`): read (data, stack, `UItem` instance, magnet target), take into the store (hide + `SetLifeSpan(0.1)` + add, same tick), spawn (`SpawnAndLaunchItem_Sync`, every struct field explicit). | `read`, `find`, `by_id`, `available`, `take_world_item`, `spawn_world_item`, `spawn_params`, `ROUTES` | Reads: yes. Spawn: offline canary OK (no crash, right item and stack). Take on a live item, and the spawn with a player present: pending. |
| `item_skills.lua` | Bridge handlers `pickup`, `drop`, `give` (+ debug `inventory`, `inventory_grant`) and get_state `inventory`/`inventory_items`/`nearby_items`, on `skills.lua`'s action slot and tick loop (`skills._start/_finish/_probe_guard`, `add_state_extender`). | `register(bridge, log, {skills, puppet})`, `HANDLERS` | Offline tests. |
| `crafting.lua` *(crafting agent)* | STRICT crafting emulation (design 19): inputs in the store, a live station actor of the recipe's type within interaction range (census by exact class word; ghosts and stations whose live recipe list excludes it don't count), recipe in Luis's live `RecipesUnlocked` mirror (catalog snapshot offline); consumes exactly inputs (+ fuel at processing stations), waits the craft time, adds exactly the outputs as instances; refunds on interrupt. Handlers `craft` (async), `craft_check`, `recipes`, `stations`. | `register(bridge, log, {skills, puppet, inventory})`, `configure`, `plan` (pure), `check`, `check_recipe`, `find_stations`, `live_mirror`, `recipe`, `recipes_for_item`, `HANDLERS` | Offline tests (`test_crafting.lua`); live read-only check (mirror, store, census) via `craft_drift check`. No station exists in the dev world yet, so no live craft. |
| `recipe_data.lua` | GENERATED recipes/stations/items table (`tools/build_recipes.py` from `data/recipes_<build>.json`). Do not edit by hand. | data | — |
| `sense.lua` | **look** (generic perception: everything with a `UInteractionComponent`, every `ADestructibleWorldActor`, `AOreNode`, creatures; names from game data, verbs pickup/gather/chop/mine/attack/interact, ranked by the player's words; bridge tool `look` and get_state `nearby_resources`). Finding things: census by class + class-word pattern + state filter (`standing`, `stump`, `alive`), nearest-first; foliage -> actor conversion (`ConvertFoliageNearbyLocation`, throttled); `relocate` a target by position after it reverted to foliage. Generic: trees, rocks, ore, loot, enemies. | `census(spec, {origin, radius_cm, near, skip, max})`, `nearest`, `state_of`, `FILTERS`, `key(loc)`, `convert_foliage(log, ctx, at, r)`, `relocate` | Yes, live 2026-10-25 (census, conversion 28 ms / 47 trees). |
| `watch.lua` | Generic timeline recorder (from `tree_watch`): appear/update/gone of actors of some classes near a centre, with HP, stump/hidden, item, stack. To LEARN a mechanic and to VERIFY an outcome. | `new({classes, center, radius_cm, period_ms, tag})` + `w:step(now)`, `snapshot`, `diff` (pure), `start(log, opts)` (experiments only) | Reads verified live (gather_probe census). |
| `hitcheck.lua` | Did a swing register on a gated resource, and why not: hooks on `BP_DamageModifier_SpecificWeapon_C` (GetHeldEquipment..., IsDamageCausedByUnarmedAttack, IsEquipmentOfSufficientTier/Category, ModifyDamage), once per run. | `arm(log)`, `armed()`, `seq()`, `since(who, seq)`, `verdict(events, hp0, hp1)` -> `damaged`/`gate_no_weapon`/`gate_tier`/`gate_category`/`modified_to_zero`/`no_contact`, `check` | Yes, live: the puppet's axe swing is read as UNARMED (no ActionGranter item). |
| `reach.lua` | The aim step for any melee swing: reads the attack class CDO's `TimedDamageShapes` (wedge/arc/box/capsule/sphere), turns it into a distance window and a facing (`yaw = bearing - AngleOffset`), plus a stand point when out of range. Calibrated live (Chop: target 35 deg right, reach ~140 cm to a trunk; Overhead: straight, ~200 cm to a log midpoint). | `shape_of(attack_class)`, `window_of(shape)` (pure), `solve(here, at, radius, win, sign, margin)` (pure) | Yes, reach_calib 2026-10-25. |
| `resource_profiles.lua` | DATA: gatherable profiles (drop item, aliases, tool category + fallback tier, root stage, settle, child stages with attack kind, bonus stage, radii) and the tool table (tier, damage multiplier; checked against the catalog by `tests/test_gather_data.py`). | `RESOURCES`, `TOOLS`, `TOOL_CATEGORIES`, `resolve(name)`, `tool_for(path)` | Oak, ash, stone, rune essence classes: yes. Willow/maple/metal ores: names only. |
| `gather.lua` | The generic gather loop over a profile (beehive BT): scan (widening) -> approach -> swing the held tool's chain -> work the state chain -> collect drops via the inventory -> repeat to the verified count. Hit: native when it lands, else the emulated hit (`DecreaseHealth`) when hitcheck shows the tool gate rejected a puppet swing. Bridge handler `gather` (async, `gather_progress`). | `register(bridge, log, {skills, puppet, store})`, `start`, `tree(deps)`, `new_action`, `check_args`, `tool_ok`, `gate_of`, `swing_for`, `store_from(inv, items)`, `default_store()` | Oak fell by the emulated hit: yes (220 -> 136 -> stump). Full loop live: see DISCOVERIES "Gather". |
| `combat.lua` *(combat agent)* | Melee reflex: combo state machine, specials, beehive behaviour tree, hook points. | `add_hook(kind, name, fn)`, `notify_threat(info)`, `perform` | `BP_PerformAttack` with the Sword set: yes. |
| `spells.lua` *(spells agent)* | Spell catalog, cast routes, cost policies, Luis's unlock mirror, utility-scored combat reflexes (shield on low HP or telegraph, Windstep on 3+ clustered). | `configure`, `list({compact})`, `can_cast`, `cast`, `route_verified`, `live_mirror`, `reflex_status`, `install_combat_hooks(combat)`, `register(bridge, log, opts)` (handlers `cast`, `spells`, `spell_tactics`) | Per route: catalog `routes[r].verified`, else `ROUTES[r].verified`. None verified in game yet, so casts answer `not_implemented` unless `DW_SPELLS_UNVERIFIED=1`. Registered in `main.lua`. |
| `rules.lua` *(spells agent)* | Reflex rules: Luis's standing orders (trigger to actions) run at tick speed inside the combat BT, before the spells reflexes; telegraph sensor (polls `AiAttackComponent.CurrentAttack.AttackData`); per-enemy persistence (bot state section `reflex_rules`). | `validate`, `add`, `list`, `clear`, `sense`, `combat_tick`, `install(combat)`, `register(bridge, log, opts)` (handlers `set_reflex_rule`, `list_rules`, `clear_rule`) | Handlers and persistence: yes (live, 2026-10-25). Sensor read, evade/retreat/focus mid-fight: UNVERIFIED. |
| `sleep.lua` *(spells agent)* | Sleep so the bot never blocks Luis's night skip: a free bed (approach to ~3 m, direct `Sleep`), else spawn a Summon Shelter (`BP_Magic_SummonShelter_C`, LoadAsset by path) beside the bot and `BedComponent:Sleep(puppet)` directly (CanSleep says false; Sleep works). Reflex (1 s loop wired in `main.lua`): Luis sleeps -> bot sleeps; Luis wakes -> bot wakes, shelter SetLifeSpan, follow resumed. | `register(bridge, log, opts)` (handlers `sleep`, `wake`, `sleep_status`), `status`, `tick`, `beds`, `shelter_point`, `direct_sleep` | Shelter + direct Sleep passes the night: yes (Luis, 2026-10-25 15:51 UTC). Real beds, placement heuristic, reflex end to end: UNVERIFIED. The rest flag and the spectator flags do NOT count (removed). |
| `identity.lua` *(identity work)* | A `DominionPlayerState` named "Claude" for the puppet's nameplate. | used by `puppet.lua` | Server side yes; client nameplate pending. |
| `speech.lua` | Every way text reaches players. **Default `DW_SAY_MODE=log`.** `relay` = the verified route. `direct` = on-demand (scalar-only call + one-shot pre-hook that property-assigns the net ids), UNVERIFIED. `chat`/`notify` = legacy and **dangerous**. | `say(log, text)` (unchanged), `mode()`, `arm_relay(log, {triggers})`, `send_direct(log, text)`, `arm_direct(log)`, `register_names(log, name, {force})`, `names()`, `status()`, `is_relaying()`, `is_bot_guid(g)`, `GUID`, `NAME` | Relay and name registration: yes, for Luis. **Direct: built, not yet proven in game** (`speech_direct prove`, then `send`; R4, R15). |
| `presence.lua` | The bot on clients' world map and HUD compass: one scalar-only `FPlayerCharacterData` entry in `GameplayObjectRegistry.PlayerCharacters`, location updated every 1 s. | `ensure(log, p)`, `update(log, p)`, `start(log, get_puppet)`, `stop()`, `status()`, `registry()`, `find_entry(reg)` | No. Not wired in `main.lua`; driven by `experiments/presence_test`. The entry can't be removed live (no `TArray.RemoveAt`). |
| `travel.lua` | Lodestones (world registry, region-based names, Luis's unlock mirror via his `CanTeleport`), map regions (spline polygons, smallest wins), loaded-area check (landscape tiles / player near), puppet teleport (`K2_TeleportTo` to the arrival point, settle + rollback, nav probe). Handlers `travel` (async), `where`, `lodestones` on `skills.lua`'s slot. | `lodestones()`, `list`, `find_lodestone`, `region_at(pos)`, `find_region`, `regions`, `loaded_at(pos)`, `where`, `teleport_to_lodestone(id, {allow_locked})`, `prepare`, `choose`, `resolve`, `register`, `configure` | Reads, regions, cost function: yes (live). Puppet teleport + settle + nav after it: yes (live, 15:48). Walk out of the Temple Woods pad: blocked there. `CanTeleport` true: needs a second lodestone. |
| `skills.lua` *(combat agent)* | Bridge handlers for protocol tools, the action plumbing (start, preempt, finish, task events) and the tick loop. | `register(bridge, log, {puppet, no_loop})`, `HANDLERS`, `tick`, `get_state` | See the file header. |
| `attack_data.lua` | Generated per-weapon attack table (`tools/gen_attack_data.py` from `data/items_<build>.json`). Do not edit by hand. | data | — |
| `vendor/beehive/` | Vendored behaviour-tree library (MIT). | `selector`, `sequence`, … | — |

### 2.4 Experiments (`mod/experiments/`): never loaded at startup

Debug modules run only through `debug_run`. They hold unproven work and historical records. The default action of each one is read-only or refuses: **known crash paths refuse unless `allow_crash=true`**, and Client_* RPCs refuse unless `confirm_client_rpc=true`. `mod/tests/test_core.lua` loads every one of them and checks this.

| Module | What it is | Proven parts promoted to |
|---|---|---|
| `puppet_test` | Spawn, possess, move, strip, address and GC diagnostics; destroy/unpossess refuse | `body/puppet.lua`, `body/removal.lua` |
| `puppet_gear` | Mirror/dress like Luis, arm, disarm | `body/gear.lua` (`equip`) |
| `puppet_combat` | Targets, approach, swing; `hit` (PredictDamage, **crashes**) refuses | `body/skills.lua` + `body/combat.lua` (`attack`) |
| `puppet_safe` | Wrapper: `removal.remove_all` | `body/removal.lua` |
| `follower_test` | Native follower (Kalphite summon), `Confuse` | — (superseded by the humanoid puppet) |
| `companion` | **LEGACY** Kebbit follower reflex. Off unless `DW_COMPANION=1` (it was on by default; `DW_NO_COMPANION` is gone). | — |
| `chat_relay` / `chat_as` | Arm the relay with the `!echo` / `!as` triggers (`chat_as` also registers names) | `body/speech.lua` |
| `name_register` / `names_probe` | Register the bot name / dump the name registry (read-only) | `body/speech.lua` |
| `say_test` | **Historical**: the Client_* variants that froze Luis's client; refuses by default | — (never promote) |
| `speech_direct` | On-demand speech: `ids`, `capture` (genuine line metadata), `status`, `prove` (read-only pre-hook check), `send` (refuses unless `confirm` and `prove` passed) | `body/speech.lua` (`direct`) |
| `presence_probe` / `presence_test` | Read-only PlayerArray + registry dump / append the bot's map entry (`add confirm=true`), `stop` | `body/presence.lua` |
| `perf_probe`, `body_probe` | Read-only timing and world survey | — |
| `rules_probe` | Read-only: spells status from a fresh copy of `body/spells.lua`, one read or a 200 ms watch of AI attack state (the telegraph sensor) | `body/spells.lua`, `body/rules.lua` |
| `sleep_probe`, `sleep_arm`, `cast_test`, `shelter_spawn`, `bed_direct` | Night skip reads/watch (the rest-flag and spectator writes are kept but INEFFECTIVE), arming body/sleep.lua live, the Fire Spirit self_effect canary (refuses when a player is within 10 m), the verified shelter spawn and direct bed Sleep | `body/sleep.lua`, `body/spells.lua` |
| `gather_probe` | Gather discovery: `census` (read-only: trees, logs, rocks, ore nodes, drops, gates), `convert`, `approach`, `swing` (one swing, optional emulated `damage`), `hook_dmg`, `held`, `magnet` | `body/sense.lua`, `body/hitcheck.lua`, `body/gather.lua` |
| `gather_test` | Live self-test of `body/gather.lua` without a restart: hot-loads the new body modules, runs a gather on its own loop; `status` (default), `start`, `stop` | `body/gather.lua` (thin driver) |
| `craft_drift` | Crafting drift check (driven by `tools/craft_drift.py`): `arm` (250 ms watcher of Luis's inventories, nearby station inventories/processing state, world items at the stations, + `Server_CraftRecipe`/`Server_ToggleProcessing` hooks; all read-only), `status`, `stop`, `plan` (fresh `body/crafting.lua` plan), `check` (full read-only craft check from a fresh copy) | `body/crafting.lua` |
| `travel_probe` | Lodestones/regions/teleport discovery: `lodestones`, `regions`, `labels`, `landmarks`, `luis` (read only), `can` (CanTeleport, pure), `calc` (cost fn), `spread`/`landscape` (streaming), `puppet`/`near` (movement reads), `list`/`where` (fresh travel.lua); `tp` and `back` move the PUPPET and refuse without `confirm=true` | `body/travel.lua` |
| `item_probe` | World items and magnets: `census`/`watch`/`env` (read-only), `take` (pickup canary into a TEST store file), `drop` (spawn canary; refuses with players online unless `confirm="luis_ok"`) | `body/items.lua`, `body/inventory.lua` |

**Not migrated yet:** `scripts/identity_attach.lua`, `scripts/identity_probe.lua` and `scripts/spell_dump.lua` are experiments that still live in `scripts/` and carry private `try`/`valid` copies. Their owners should move them to `experiments/` and switch them to `body.util` once the restarted server can find experiments.

### 2.5 Brain side (Python)

| File | Role |
|---|---|
| `brain/interface.py` | `TOOLS` (name → args model, description), `BODY_TOOLS`, `GameInterface`, `Reason` codes, events. **The contract.** |
| `brain/protocol.py`, `BRIDGE_PROTOCOL.md` | Message envelopes; the `capabilities` request; the probe fallback |
| `brain/bridge_client.py` | `GameInterface` over the bridge; per-tool timeouts (`DEFAULT_TIMEOUTS`) |
| `brain/capabilities.py` | Asks the body which tools exist → `SkillRegistry` (the planner only plans with these) |
| `brain/executor.py` | Runs one task, verifies it against fresh `get_state` (`VERIFIERS[skill]`), retries with a cap |
| `brain/state_store.py` | Task tree, notes, `MOCK_SKILLS` (planner skill order) |
| `brain/mock/game.py`, `brain/fake_body.py` | Mock game (Track M) and the fake body used by tests |

---

## 3. Rules

1. **One shared Lua core.** Helpers live in `mod/body/util.lua`. Do not write `local function try/valid/fullname/alive/split_pawns` in a new file; require `body.util`. If a helper is missing, add it to util (additively) with a test in `mod/tests/test_core.lua`.
2. **Every native call that can change game state goes through `U.call(log, label, data, fn)`.** The breadcrumb is on disk before the call, so after a crash the last `native` line in `logs/mod/mod_*.jsonl` names the culprit. Reads (`U.try(function() return o.Prop end)`) don't need a breadcrumb. `pcall` does **not** catch native access violations; the breadcrumb plus the watchdog is the protection.
3. **Never build complex structs for Client_* RPCs.** Hand-built `FChatMessageData` and `Client_DisplayTextNotification` froze Luis's client (DISCOVERIES "Client freeze"). To reach clients, re-send **genuine** game-built structs through **Server_*** functions (the speech relay), or write replicated **properties** and call `OnRep_*` (gear). A new Client_* call needs Luis's explicit go-ahead.
4. **Prefer reading and writing properties over calling functions with struct or array args.** UE4SS struct marshalling crashed natively (`PredictDamage`'s `TArray<FTypeDamage>`). When a struct must cross, reuse one the game built, or write it field by field (`U.guid_set`). Never pass a Lua table as a `TArray` of structs.
5. **Act only on alive objects.** `IsValid()` stays true for destroyed actors until GC. Use `U.alive` / `U.find_all` / `U.split_pawns` before possessing, moving, equipping or removing.
6. **Never unpossess, destroy or kill the puppet** except through `body/removal.lua`. Keep it immortal. Park it instead of despawning it.
7. **Experiments live in `mod/experiments/`; proven code is promoted into `mod/body/`.** An experiment is promoted when DISCOVERIES records it as verified in game (who saw what, when, build ID). Promotion means: a small focused service module or a skill handler, tests, and the experiment reduced to a thin wrapper or deleted.
8. **Every new skill has:**
   - (a) a **probe-safe** handler: registered through `skills.lua`'s `probe_guard`, it answers `invalid_args` on missing args and never acts on defaults;
   - (b) **verified-state success**: `ok` only when re-read game state confirms it, both in the body and in `executor.VERIFIERS`;
   - (c) a **Lua unit test** against the fake world in `mod/tests/`;
   - (d) an entry in the **capabilities list** (automatic once registered as a bridge handler) and in the **brain interface** (`interface.TOOLS`, `GameInterface`, `BridgeClient`, the mock, `MOCK_SKILLS` if the planner may use it, `bridge.lua M.TOOLS`).
9. **One voice, one tick loop, one puppet.** Speech goes only through `speech.say` (the Controller decides what to say). Long actions step in `skills.lua`'s single tick loop; services don't start their own loops unless `main.lua` wires them. There is never a second puppet.
10. **Lowercase, portable paths** (`scripts/`, `experiments/`), paths from env vars, pure Lua. C++ mods are Windows-only (CLAUDE.md section 3).
11. **Record every discovery** in DISCOVERIES.md before building on it. Mark unverified calls `UNVERIFIED` in the module header.

---

## 4. How to…

### 4.1 Add a skill (a new protocol tool, e.g. `gather`)

1. **Discover** (CLAUDE.md section 7): add candidate hooks to `hooks.lua` `PENDING` (or a debug experiment), ask Luis to do the action once, then read `logs/mod/mod_*.jsonl`. Record the authoritative server call in DISCOVERIES.
2. **Prototype** in `mod/experiments/<name>_test.lua` (§4.3). Iterate with `debug_run`, without a restart.
3. **Promote**: put the native mechanics in a service (`mod/body/<concern>.lua`, using `U.*` and `U.call`), then add the handler in `skills.lua`:
   - sync handlers return `{ok, reason, data}`;
   - long actions use `start({kind, id=ctx.id, async=true, step=...})` and return nil;
   - `step` checks game state each tick and calls `finish(a, ok, reason, data)`, which replies and emits `task_done`/`task_failed`;
   - pre-emption, interrupts and the tick loop come for free.
4. **Brain side:** add the args model to `interface.TOOLS` (if new), plus `GameInterface`, `BridgeClient`, the mock and `executor.VERIFIERS`, and the name to `MOCK_SKILLS` if the planner may use it. Add to `bridge.lua M.TOOLS` only if it is a protocol tool name. Document it in `BRIDGE_PROTOCOL.md`.
5. **Test:** a Lua test in `mod/tests/test_body.lua` (fake world) covering success, each failure reason and probe; a pytest scenario on the mock. Run the full suite (§5).
6. **Live:** deploy, restart when Luis is not playing, then run the debug trigger. Ask Luis one yes/no question. Record the result in DISCOVERIES.

### 4.2 Add a hook

- **Discovery only** (just log it): append `{path=..., tag=...}` to `hooks.lua` `M.PENDING`. Everything in `PENDING` registers 30 s after start. Paths must exist verbatim in the dump. Never hook tick or movement functions. `Client_*` functions don't run on the server, so hooking them does nothing.
- **Production** (it feeds the brain or a reflex): give the entry an `extract = function(params) return fields end`, which is cheap and reads only the fields you need, and handle the tag in `main.lua`'s `hooks.register(log, {tag = fn})`. Filter the bot's own actions there (as `is_bot_line` does for chat).
- **A hook owned by a service** (for example the speech relay): the service registers it once per run behind a `_G` flag (`rawget(_G, "__dw_<name>")`), because experiments are loaded with `loadfile` and could otherwise register twice.
- Remember: hooks only see **reflected** calls (RPCs, BP calls, dynamic delegates). Native C++ calls such as `InventoryComponent:AddItem` never fire. Poll state instead.

### 4.3 Add a debug experiment

1. Create `mod/experiments/<name>.lua` (the name must be unique across `scripts/` and `experiments/`):
   ```lua
   local U = require("body.util")
   local M = {}
   function M.run(log, args)
       args = args or {}
       -- reads: U.try / U.find_all / U.split_pawns ...
       local ok, err = U.call(log, "<name>.<Call>", { ... }, function() ... end)
       return { ok = ok, err = err and tostring(err) }
   end
   return M
   ```
2. Make the default action read-only. Put anything on the risk register (§6) behind an explicit `allow_crash=true`. Put any Client_* call behind `confirm_client_rpc=true`, and only with Luis's go-ahead.
3. Deploy with `tools\deploy_mod.ps1` (it copies every `mod/` folder except `tests/`), then run `.venv\Scripts\python.exe -m tools.bridge_cmd debug_run "{\"module\":\"<name>\",\"args\":{...}}"`. The experiment file reloads on every call. **The `body.*` modules it requires do not reload**; they stay as loaded at server start.
4. Add `<name>` to the smoke list in `mod/tests/test_core.lua` ("experiments: all load…").

### 4.4 Promote an experiment

Follow §4.1 step 3. Then reduce the experiment to a thin wrapper over the new service, as `puppet_safe`, `chat_as` and `name_register` are, or delete it. Update the table in §2.4 and the DISCOVERIES entry ("promoted to `body/<x>.lua`").

### 4.5 Add a body service

Create a new `mod/body/<concern>.lua` with:
- one concern;
- a header saying what is verified and what is UNVERIFIED;
- `local U = require("body.util")`;
- state in a local table, or in `_G.__dw_<name>` when it must survive `loadfile` reloads;
- a `_reset()` test hook.

Wire it in `main.lua` inside a `pcall`. Add tests.

---

## 5. Tests

| What | Command |
|---|---|
| Body skills (fake world) | `"C:\Program Files\WinGet\Links\lua.exe" mod/tests/test_body.lua <empty_dir>` |
| Spells + reflex rules (fake world, combat hook wiring) | `... lua.exe mod/tests/test_spells.lua <empty_dir>` and `... lua.exe mod/tests/test_rules.lua <empty_dir>` |
| Inventory, equip gate, pickup/drop/give | `... lua.exe mod/tests/test_inventory.lua <empty_dir>` (+ `tests/test_items.py` for the brain side) |
| Crafting (strict emulation, refusals, exact consumption/production, refunds, generated data) | `... lua.exe mod/tests/test_crafting.lua <empty_dir>` (+ `tests/test_recipes.py`: catalog normalise, Lua data, wiki check, drift analysis, patch diff) |
| Travel (lodestones, regions, where, teleport) | `... lua.exe mod/tests/test_travel.lua <empty_dir>` |
| Bridge | `... lua.exe mod/tests/test_bridge.lua <empty_dir>` |
| Core: util, removal, speech relay, debug_run lookup, experiment smoke, probe flag | `... lua.exe mod/tests/test_core.lua <empty_dir>` |
| Everything, including the Lua suites via pytest wrappers | `cd C:\gameserver; .venv\Scripts\python.exe -m pytest tests -q` |
| Syntax of every Lua file | `luac -p` on each file under `mod/` (`C:\Program Files\WinGet\Links\luac.exe`) |

The fake worlds stub the UE4SS globals (`FindAllOf`, `StaticFindObject`, `RegisterHook`, `LoopInGameThreadWithDelay`, …) in `mod/tests/bridge_harness.lua` and in each test file. Forbidden calls (unpossess, destroy, direct damage) raise and are counted.

---

## 6. Data catalogs (`data/`)

Build-specific, generated offline, committed. Regenerate after every game patch (CLAUDE.md section 8). Schemas are in `data/README.md`.

| File | Generated by | Used by |
|---|---|---|
| `data/items_<build>.json` | `tools/build_catalog.py` → `debug_run catalog` (`mod/scripts/catalog.lua`) | gear/combat (via `body/attack_data.lua`), the brain's weapon choice |
| `mod/body/attack_data.lua` | `tools/gen_attack_data.py` from the items catalog | `body/combat.lua` |
| `data/spells_<build>.json` | `debug_run spell_dump` (`mod/scripts/spell_dump.lua`) + `spells.merge_catalog` | `body/spells.lua`, the brain |
| `data/recipes_<build>.json` + `mod/body/recipe_data.lua` | `tools/build_recipes.py` → `debug_run recipe_dump` (`mod/scripts/recipe_dump.lua`), stage by stage; `--wiki-check` compares with the wiki's `recipe` Bucket table | `body/crafting.lua`, the brain's recipe chainer (planned `brain/recipes.py`); `tools.patch_pipeline catalog-diff` diffs it |
| `data/enemies_<build>.json` | planned (design doc section 4) | weakness-aware weapon choice |

Raw generator output goes to `logs/catalog/` (gitignored). Only normalised files live in `data/`.

---

## 7. Risk register: known crash paths and their mitigations

`pcall` catches Lua errors only. Native access violations kill the server, and UE4SS then blocks in a MessageBox. Everything below is either avoided by construction or recovered by the watchdog.

| # | Crash path | Evidence | Mitigation |
|---|---|---|---|
| R1 | **Unpossess of an AI-possessed `BP_PlayerCharacter_C`** (UnPossess, destroy, SetLifeSpan, probably death): `UPlayerRangedAttackComponent::OnPlayerControllerChanged` reads `Cast<ADominionPlayerController>(Old)->LoadoutComponent` (+0x1248) on null. | 8 dumps, same rip; bisect table in DISCOVERIES | Never unpossess (`puppet.lua` parks instead). The puppet is immortal from possession. Removal only via `body/removal.lua` (strip the ranged component first; it refuses and returns `strip_failed` if the strip didn't take). `puppet_test destroy/unpossess` refuse. **Open:** the death/respawn path is untested. |
| R2 | **UE4SS crash handler blocks** in `MessageBoxW`, so every crash looks like a hang. | `cdb` stack, UE4SS source | `tools/watchdog.ps1` restarts the server on a new `crash_*.dmp` or a missing process. |
| R3 | **Struct/array UFunction args**: UE4SS `push_structproperty` AV marshalling `TArray<FTypeDamage>` (`PredictDamage`). | `crash_2026_10_25_14_07_41` | Rule 4. The direct-damage path is never used (skills/combat use `BP_PerformAttack`). `puppet_combat hit` refuses. |
| R4 | **Client freeze from hand-built Client_* RPCs** (chat struct with empty NetIds, HUD toast). The server stays up; the client hangs. | Luis, 2026-10-25 13:38 | Rule 3. `DW_SAY_MODE` defaults to `log` in code and in `start_server.ps1`. The working route is the relay (genuine struct, Server_* RPC). `say_test` refuses. **Gap:** on-demand speech without a triggering chat line is unsolved, and relay `say()` queues until the next player line (TTL 60 s). |
| R5 | **Zombie actors**: destroyed actors stay in `FindAllOf` with `IsValid()` true until GC, and were re-possessed. | puppet bisect notes | `U.alive` / `U.find_all` / `U.split_pawns` skip `Garbage\|Unreachable`. |
| R6 | **Immediate destroy inside a UE4SS delayed-action callback** deadlocked the game thread. | 2026-10-25 | Use `SetLifeSpan(0.1)` and let the engine destroy on its next tick. |
| R7 | **Hangs with no dump** (game thread stuck). | — | Heartbeat file from the game thread every 10 s; the watchdog restarts after 60 s stale, capturing `cdb` stacks first. |
| R8 | **Modular spell `CostItems`** may dereference the puppet's null PlayerController inventory (same class of bug as R1). | code reading, spells research | `spells.lua` `modular` route is opt-in only (`DW_SPELLS_MODULAR=1`). |
| R9 | **Synchronous `LoadAsset`** stalls the game thread. | catalog design | Only in catalog builds, in small batches; `gear.find_asset` is the only runtime caller (once per item). |
| R10 | **Swapping a player's `OwnerGuid.CharacterGuid`** for name registration: if not restored, the player's identity breaks. | name_register, restore verified | Swap, call and restore in the same tick, with the restore outside the guarded call (`speech.register_names`); checked with `guid_eq`. |
| R11 | **Relay loopback**: the bot's relayed chat line re-enters the chat hook with the template player's PlayerId and would become a "player command". | design | `main.lua` drops chat lines when `speech.is_relaying()` or the sender GUID is the bot's. Tested in `test_core`. |
| R12 | **Hot reload illusions**: `require` returns cached modules, so a redeployed `body/*.lua` isn't picked up. | DISCOVERIES "Debug trigger" | `debug_run` uses `loadfile` for the named file only. Body, infra and service changes need a restart. Shared state that must survive reloads lives in `_G.__dw_*`. |
| R13 | **Game patches** rename classes or change layouts. | — | Use reflected names only, never offsets. After a patch: dump, catalogs, smoke tests (CLAUDE.md section 8). Wrappers fail as Lua errors (breadcrumbed), not crashes. |
| R15 | **UE4SS nested struct userdata** (struct only; UObject/FName/FString userdata nested are fine): a struct userdata inside a Lua table (any depth) given to a UFunction param, a struct field or a TArray element. `push_structproperty` reads it with `get_userdata()` at stack index 1 instead of `stored_at_index` → native AV. | `crash_2026_10_25_15_45_24` (speech_direct v1); UE4SS source at 83330635. Probably also R3. | Never put a userdata inside a table passed to UE4SS. Tables must hold scalars only. Copy structs by property assignment (`a.B = ud`) or as a whole top-level param. `test_core` asserts that the direct and presence payloads are userdata-free. |
| R14 | **Probe mismatch**: the brain's top-level `probe: true` was ignored by the body (the guard read `args.probe`), so a probe of `stop` really stopped. | code reading, 2026-10-25 | `bridge.lua` copies `msg.probe` into `args.probe` (needs a restart). Tested in `test_core`. |
