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
| `bridge.lua` | Body side of the JSONL bridge: tails `brain_to_body.jsonl`, dispatches to handlers on the game thread, writes results and events. Copies the cmd's top-level `probe` flag into `args.probe`. | `handlers[name] = fn(args, ctx)`, `reply(id, res)`, `emit_event(name, data)`, `null`, `object`, `init({dir, in_name, out_name})`, `new_tail(path)` (the byte-offset JSONL tail; the client body reuses both, section 8) |
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
| `crafting.lua` *(crafting agent)* | Crafting KNOWLEDGE and FEASIBILITY, read-only. **No emulated craft** (real-player remediation, 2026-10-25: removed; `craft` answers not_implemented until the real-client body drives `Server_CraftRecipe` etc.). Pure `plan` (exact inputs/outputs/fuel/time model from `recipe_data.lua`); `check`: inputs held (injected counter), a live station actor of the recipe's exact class word within interaction range (ghosts and live recipe lists honoured), recipe in Luis's live `RecipesUnlocked` mirror (catalog snapshot offline), precise refusal reasons. Handlers `craft_check`, `recipes`, `stations` (sync). | `register(bridge, log, {skills, puppet, inventory})`, `configure`, `plan`, `check`, `check_recipe`, `find_stations`, `live_mirror`, `recipe`, `recipes_for_item`, `HANDLERS` | Offline tests (`test_crafting.lua`, 18); live read-only check (mirror 827 recipes, store, census) via `craft_drift check`. |
| `recipe_data.lua` | GENERATED recipes/stations/items table (`tools/build_recipes.py` from `data/recipes_<build>.json`). Do not edit by hand. | data | — |
| `sense.lua` | **look** (generic perception: everything with a `UInteractionComponent`, every `ADestructibleWorldActor`, `AOreNode`, creatures; names from game data, verbs pickup/gather/chop/mine/attack/interact, ranked by the player's words; bridge tool `look` and get_state `nearby_resources`). Finding things: census by class + class-word pattern + state filter (`standing`, `stump`, `alive`), nearest-first; foliage -> actor conversion (`ConvertFoliageNearbyLocation`, throttled); `relocate` a target by position after it reverted to foliage. Generic: trees, rocks, ore, loot, enemies. | `census(spec, {origin, radius_cm, near, skip, max})`, `nearest`, `state_of`, `FILTERS`, `key(loc)`, `convert_foliage(log, ctx, at, r)`, `relocate` | Yes, live 2026-10-25 (census, conversion 28 ms / 47 trees). |
| `watch.lua` | Generic timeline recorder (from `tree_watch`): appear/update/gone of actors of some classes near a centre, with HP, stump/hidden, item, stack. To LEARN a mechanic and to VERIFY an outcome. | `new({classes, center, radius_cm, period_ms, tag})` + `w:step(now)`, `snapshot`, `diff` (pure), `start(log, opts)` (experiments only) | Reads verified live (gather_probe census). |
| `hitcheck.lua` | Did a swing register on a gated resource, and why not: hooks on `BP_DamageModifier_SpecificWeapon_C` (GetHeldEquipment..., IsDamageCausedByUnarmedAttack, IsEquipmentOfSufficientTier/Category, ModifyDamage), once per run. | `arm(log)`, `armed()`, `seq()`, `since(who, seq)`, `verdict(events, hp0, hp1)` -> `damaged`/`gate_no_weapon`/`gate_tier`/`gate_category`/`modified_to_zero`/`no_contact`, `check` | Yes, live: the puppet's axe swing is read as UNARMED (no ActionGranter item). |
| `reach.lua` | The aim step for any melee swing: reads the attack class CDO's `TimedDamageShapes` (wedge/arc/box/capsule/sphere), turns it into a distance window and a facing (`yaw = bearing - AngleOffset`), plus a stand point when out of range. Calibrated live (Chop: target 35 deg right, reach ~140 cm to a trunk; Overhead: straight, ~200 cm to a log midpoint). | `shape_of(attack_class)`, `window_of(shape)` (pure), `solve(here, at, radius, win, sign, margin)` (pure) | Yes, reach_calib 2026-10-25. |
| `resource_profiles.lua` | DATA: gatherable profiles (drop item, aliases, tool category + fallback tier, root stage, settle, child stages with attack kind, bonus stage, radii) and the tool table (tier, damage multiplier; checked against the catalog by `tests/test_gather_data.py`). | `RESOURCES`, `TOOLS`, `TOOL_CATEGORIES`, `resolve(name)`, `tool_for(path)` | Oak, ash, stone, rune essence classes: yes. Willow/maple/metal ores: names only. |
| `gather.lua` | The generic gather loop over a profile (beehive BT): scan (widening) -> approach -> swing the held tool's chain -> work the state chain -> collect drops via the inventory -> repeat to the verified count. Hit: native only by default (Luis 2026-10-25: real player paths, no emulation); the emulated hit (`DecreaseHealth` when hitcheck shows the gate rejected a contacting swing) is opt-in with `DW_GATHER_HIT=auto`. Bridge handler `gather` (async, `gather_progress`). | `register(bridge, log, {skills, puppet, store})`, `start`, `tree(deps)`, `new_action`, `check_args`, `tool_ok`, `gate_of`, `swing_for`, `store_from(inv, items)`, `default_store()` | Oak fell by the emulated hit: yes (220 -> 136 -> stump). Full loop live: see DISCOVERIES "Gather". |
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
| `craft_drift` | Real-craft capture + catalog drift check (driven by `tools/craft_drift.py`): `arm` (250 ms watcher of Luis's inventories, nearby station inventories/processing state, world items at the stations, plus pre/post hooks on his inventory/crafting RPCs: `Server_CraftRecipe`, `Server_ToggleProcessing`, `Server_MoveItemBetweenInventories`, `Server_MoveAll…`, `Server_FillStacks…`, `Server_SplitAndPutStack`, `Server_RepairItem`, `Server_UpgradeMasterworkEquipment`, `Server_RequestInteraction`; all read-only), `status`, `stop`, `plan` (catalog plan from a fresh `body/crafting.lua`), `check` (read-only feasibility from a fresh copy) | `body/crafting.lua`; the RPC capture feeds the real-client route |
| `travel_probe` | Lodestones/regions/teleport discovery: `lodestones`, `regions`, `labels`, `landmarks`, `luis` (read only), `can` (CanTeleport, pure), `calc` (cost fn), `spread`/`landscape` (streaming), `puppet`/`near` (movement reads), `list`/`where` (fresh travel.lua); `tp` and `back` move the PUPPET and refuse without `confirm=true` | `body/travel.lua` |
| `item_probe` | World items and magnets: `census`/`watch`/`env` (read-only), `take` (pickup canary into a TEST store file), `drop` (spawn canary; refuses with players online unless `confirm="luis_ok"`) | `body/items.lua`, `body/inventory.lua` |

**Not migrated yet:** `scripts/identity_attach.lua`, `scripts/identity_probe.lua` and `scripts/spell_dump.lua` are experiments that still live in `scripts/` and carry private `try`/`valid` copies. Their owners should move them to `experiments/` and switch them to `body.util` once the restarted server can find experiments.

### 2.5 Brain side (Python)

| File | Role |
|---|---|
| `brain/interface.py` | `TOOLS` (name → args model, description), `BODY_TOOLS`, `GameInterface`, `Reason` codes, events. **The contract.** |
| `brain/protocol.py`, `BRIDGE_PROTOCOL.md` | Message envelopes; the `capabilities` request; the probe fallback |
| `brain/bridge_client.py` | `GameInterface` over the bridge; per-tool timeouts (`DEFAULT_TIMEOUTS`) |
| `brain/paths.py`, `brain/transport.py` | `body_kind()` (`DW_BODY` = server \| client), `bridge_dir(body)`, `endpoint_files(body)`: which body the brain drives (section 8) |
| `brain/capabilities.py` | Asks the body which tools exist → `SkillRegistry` (the planner only plans with these) |
| `brain/executor.py` | Runs one task, verifies it against fresh `get_state` (`VERIFIERS[skill]`), retries with a cap |
| `brain/state_store.py` | Task tree, notes, `MOCK_SKILLS` (planner skill order) |
| `brain/mock/game.py`, `brain/fake_body.py` | Mock game (Track M) and the fake body used by tests |
| `brain/broker.py` | **Event broker** between the bridge and the Controller (streamline step 3): `triage` (per batch), `assess` (per event, fresh state), movement episodes, `digest()` → `body_status`, episodic memory → `recent_activity`, `observe()` → the "Where:" line |
| `brain/voice.py` | **Single voice**: `Controller.say` is the only speaker; `Voice.gate` blocks near-duplicate notices (30 s) and same-line reply bursts (2 s) |
| `brain/grounding.py` | **Grounding as information** (streamline step 4): `read()` / `hints()` → `references` (typo-tolerant matches of the player's words to perceived things, with ids). It never vetoes |
| `brain/predicates.py` | **Success predicates** (shared with the benchmark): `validate` / `errors` / `evaluate` → `Result(passed True\|False\|None, detail, progress, missing, measures)`; null = can't be checked, never done; `register()` adds leaves (evals/bench/leaves.py). Judge file: batch changes before a judge tag |
| `brain/board.py` | **Task board** (docs/design/director.md): tasks/steps/segments/loops in `<world>/goals.json` (agent loop = only writer; CLI inbox exactly once), `BoardOps` (order, caps, immutable task success, segments around runs, tallies, loops), `HourlyWindow` |
| `brain/director.py` | **Director** (Sonnet, step boundaries only): `tick()` on the agent loop; one decision on a worker over a snapshot (versioned); research tools (recall, lookup, compare_gear, map_memory, skills_progress, proxied craft_plan/recipes/stations); `StepRunner` = `Agent.run_directed` per step, done only by the predicate; board tools for the Controller (`add_task`, `board`, `pause_board`, `resume_board`, `cancel_task`, `report_step`). `DW_DIRECTOR=1` |
| `brain/capability_gaps.py` | **Gap log** `logs/state/capability_gaps.json`: what plans needed and the body lacks (tool results, uncheckable tests, cross-checked Director claims); `tools/board.py gaps` |
| `brain/knowledge_memory.py`, `brain/llm_json.py` | Facts looked up or seen (source, confidence, refuted) + work rates and the efficiency trend log; the shared validate-and-repair JSON decision loop (tool rounds, budget gate per request) |
| `brain/mock/gear_world.py` | Catalog-driven mock (real item/recipe/station ids, tool tiers, XP, bag slots, equip, creatures with drops, `craft_plan`) for the Director's job scenarios (`tests/test_director_jobs.py`) |

### 2.6 Event hygiene, single voice, grounding (decisions, 2026-10-25)

Live evidence: the 19:21–19:25 episode (`tests/fixtures/episode_2026-10-25_1921.json`), plus 20:21:53 (`..._2021_hungry.json`) and 20:26:20. Precedents:
- bubus event debouncing (merge by work key before expensive work; adapted, not adopted: our loop is synchronous and polls);
- game bark managers (one gate, validate against current state at speak time, drop rather than backlog; bugnet.io / pulsegeek.com);
- stdlib `difflib` for typos (rapidfuzz not needed at this size).
No source was found for expiring queued NPC lines on state change; that part is ours.

1. **Classify by event type and structured fields, never by phrases.** What happens to each event:
   - `task_done` / `task_failed`: dropped, because the executor has the synchronous reply. Exception: `task_failed` of a **held** action (follow, via `BridgeClient.sent_tool(id)`) becomes a `follow_ended` situation.
   - progress events: dropped (they are narrated live).
   - `unreachable`, `resumed`, `vitals_low`, `items_dropped`: body situations, assessed against fresh state.
   - `activity`: memory only.
   - chat: the Controller.
2. **Coalesce and supersede per batch.** An unreachable followed by a resumed is dropped. Only the newest unreachable is kept, the newest `vitals_low` per stat, and the newest `attacked` per attacker.
3. **Stale = superseded by fresh state or by the brain's own episode.**
   - an unreachable for a player he is now within 6 m of;
   - an unreachable from a move that arrived, or that failed (its result was already reported);
   - an unreachable to a spot that is not a player, from a move the brain didn't start. It is information only, a digest line "not a player, not a move you started".
   - a vitals report when the stat rose 5 or more, or a matching consumable is carried (the body's `consumable` field);
   - dropped items that are no longer on the ground.

   Repeats are capped per episode and reason, the unreachable cooldown is 60 s, and vitals repeat every 150 s unless the value fell to 60 % or less.
4. **Situations are model-voiced** (main's decision). The surviving events of a batch go to ONE Controller run (`body_event`), or ride along in the pending chat run. The `broker.fallback_line` templates are only used when the model call fails or says nothing, and only for what fresh state still shows as true. Nothing is said when the model's own action fixed it (live 20:21:53).
5. **Speak-time checks.**
   - A body situation is re-checked on fresh state before it is spoken.
   - A pure-talk reply whose `facts()` changed while the model was thinking (near_player, low/has food/drink) is decided once more.
   - `Voice.gate` never holds back a reply to a new command, except a 2 s same-line burst.
6. **Chat bursts are one run.** The player's pending lines are joined with " / " into `command.text`, and an addressed line takes them along (burst window 0.8 s, `DW_CHAT_DEBOUNCE_S`; lines typed while a model call or tool runs are merged anyway). A line from the player he is with (the one he answered in the last 3 min, or the only player around) counts as addressed; a named line runs at once. The text reaches the model verbatim (no greeting stripping).
7. **Code never vetoes the model** (PRINCIPLES.md #2).
   - The only gate is `Controller.safety`: never attack a player.
   - Grounding only informs (`references`).
   - Failed body actions, invalid args and unknown tools go back to the model once (`Controller.follow_up` with every step's real result). Multi-step turns run in order and stop at the first failure. The `report_failure` templates are the safety net.
8. **What the model gets about its body** (instead of raw events):
   - `body_status`: "Where:" (moving or still, who is in sight at what distance and height, who is NOT in sight), the current or last move and how it ended, open complaints, informational body reports;
   - `recent_activity`: completed body episodes from any starter, generic `kind: field=value` rendering. Kills, deaths and anything with a place are promoted to notes; a death's `where` becomes place `grave`.
9. **Learned-skill management is model-chosen** (`list_skills` read, `forget_skill` exact name). There are no regexes over player text. `remember` stores a place's position only from `at=self|player`.
10. **Proactive behaviour = `situation_review`** (Luis, 2026-10-25: at night with low endurance he asks to rest and, if agreed, composes cast(Summon Shelter) + interact(bed)).
    - **Triggers: meaningful STATE CHANGES only, never rules about what to do.**
      - any reported survival stat, or health, crossing the 50/30/15 % lines downwards;
      - `time_of_day.phase` changing;
      - `sleep_allowed` turning true;
      - the bag reaching 90 %;
      - 5 min with no command or action while a player is within 15 m.
    - **Sampling:** the Agent reads get_state every 30 s when idle. That is a bridge read; the model is called only on a change.
    - **Gates:**
      - 3 min between reviews, unless a stat fell below the band it had at the last review;
      - none during combat (attacked < 30 s ago, or `state.fight`), during a goal or a non-follow move, while chat is pending, or within 20 s of a command.
    - **The event** carries the changes, `stats_pct`, `time_of_day`, `bag`, the players near, and `previous_review` (when, what changed, what he said). The rolling chat holds the player's answer.
    - **The model decides to speak, act or stay silent.** An empty reply is silence: no template, no default reply.
    - **Perception:** `time_of_day` and `bag` come from the body (requested from the capability agent); endurance is already in `survival`.
11. **The agent loop** (live 20:43: a shelter plan died after its first step; 20:46: a raw "I couldn't go to: unknown_target." said twice).
    - **Every model turn's tool results go back to the model** (`Controller.next_turn`). That covers successes and failures, reads run inline again, and each call gets its own result, or "not run" with the reason.
    - **The loop continues** until the model calls no tools, for at most `MAX_TURNS` = 4 extra turns per request. It stops at once when a new chat line arrives (peeked events are stashed for the next pump). A turn of only follow or stop (a standing behaviour) needs no continuation.
    - **A failure's result carries the tool's own schema argument descriptions** (`args_help`), so the model can name the target correctly next time.
    - **The `report_failure` templates are a last resort:** only when the model call errors or it says nothing about a failure. They contain no raw reason codes; a reason that is already a sentence is used without its code prefix.
    - **Speech:** a blocking move or job (go_to, come_to, gather) says its turn's line as it starts, so the line is true when said. Other turns' lines are said after their actions succeed. A failed turn's line is never said.
    - **`body_status` "Your recent actions"** lists the brain's last 5 actions with outcomes and ages. The persona says to act on your own plan, report briefly, and ask only when genuinely ambiguous, risky or beyond your tools.
    - **Cost:** one extra model call per action turn.
12. **Live fixes from the 20:40–21:04 session (docs/BUGS.md L2, L5, L6, L10).**
    - **L2 (3 min unresponsive):**
      - During any wait longer than 5 s, `BridgeClient.request` watches two things. An addressed chat line ends the wait as `interrupted`; the body keeps going until the model's next action or stop, and the late result lands in "Your recent actions". A 10 s heartbeat ping compares the body's `started` epoch and action slot, giving `body_restarted` or `lost_by_body` at once.
      - `timeout`, `body_restarted`, `lost_by_body` and `resting` are deterministic: no blind executor retry, and the model hears them.
    - **L5 (promised, never did):** a first turn that only talked gets ONE more turn ("If your reply says you will do something now, call the tool(s)..., otherwise reply EMPTY"). Its line is said first, so this adds no reply latency. Information, not a veto.
    - **L6 (slow):**
      - The agent's fresh read at the start of a turn is reused by the executor (≤ 1 s, invalidated by any action), and verification stays fresh. That is 1 read before a tool instead of 3.
      - `tools/turn_latency.py <log>` prints chat → first response p50/p95, reads per tool and the prompt-cache share. Before (20:40–21:03): p50 5.0 s, p95 7.8 s, 3 reads per tool, 61–65 % cached.
    - **L10:**
      - `brain/house_rules.md` holds Luis's rules (lines starting with "-"). It is loaded into the persona as rules the model follows and re-read when the file changes.
      - A day/night change is reviewed at once, even inside the 3 min review gap (he stayed in bed after day). A sleep window opening is not urgent.
13. **Speed plan §2 (docs/design/autonomy-plan.md).**
    - **Addressing:** the player he is with counts as addressed, and the burst window is 0.8 s. Named lines run at once.
    - **Turns:** one state read per turn. The live executor makes ONE attempt (no retries; the result goes to the model). The promise-check turn (item 12) covers L5 and the 21:15:01 replay.
    - **Context trims:** `castable_spells` is one line per spell. `recent_events` no longer repeats chat lines (they are in `chat`). Chat is 12 lines / 4 min.
    - **Model:** the Controller runs at effort `low` (`DW_CONTROLLER_EFFORT`; empty = the model default). Adaptive thinking stays on; disabling it can put tool calls into visible text (Claude API docs). A constant effort keeps the prompt cache, and LiteLLM 1.106 passes `output_config` through unchanged (checked with `get_optional_params`).
    - **Streaming tool execution: not adopted.**
      - Anthropic streams tool input as `input_json_delta` fragments, so a call is complete only at its `content_block_stop`.
      - Our replies put the tool block last, so the gain is tens of ms. Running a second call while its JSON streams would save at most a few hundred ms.
      - A LiteLLM issue reports streamed tool arguments truncated by a premature stop.
      - Revisit if multi-tool turns become common.
    - **Replay** (`tests/test_latency_replay.py`; virtual clock, real 20:40–21:03 lines, Haiku 1.9 s/call, get_state 0.25 s): chat → first response p50/p90 went from 4.25/4.50 s before to 3.05/3.30 s after. With effort low the projection (model 1.2 s) is 2.35/2.60 s. Live before (tools/turn_latency.py): 5.0/7.8 s (p50/p95).
14. **Voice, budget and traces (late 2026-10-25).**
    - **Persona:** it lives in `brain/persona.md` (the voice workstream's file, loaded by `brain/persona.py`, re-read on change, `PERSONA` as the fallback). It is followed by `brain/house_rules.md`.
    - **No canned speech** ("On it", "Done: …", "Gathering …", "Step x/y", "I'll remember …"):
      - progress is a "Job progress" line in `body_status`;
      - `goal_done` and `stuck` are body situations the model phrases (stuck keeps a template fallback);
      - refusals before the body go back to the model through `next_turn`.
    - **BUGS L18:** an empty text beside tool calls is replayed as `None`. `llm.strip_markers` removes `[System: …]` markers, and `Controller.say` never speaks one.
    - **Daily $ cap (`brain/budget.py`):** spend comes from `tools.spend.spend_today` and the cap from `tools.spend.cap_usd`, read every 30 s.
      - 80 %: one `budget_warning` log line.
      - 100 %: no model calls (no chat runs, situations or reviews, no new goals). One honest line at most every 10 min, and body situations still get their template line. Reflexes run in the body.
      - The spend reader fails open (0.0 on error).
    - **`episode_id` on every log row:** `JsonlLogger.episode()` stamps each row while an episode is open. Chat bursts share one id (`chat-…`); situations and reviews get their own (`situation-…`, `review-…`); a goal keeps the id of the command that started it.

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
| Crafting knowledge (craft_check refusals, plans, no-emulation guard, lookups, generated data) | `... lua.exe mod/tests/test_crafting.lua <empty_dir>` (+ `tests/test_recipes.py`: catalog normalise, Lua data, wiki check, drift analysis, patch diff) |
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
| R16 | **Stale UObject held across ticks**: a Lua table keeps a UObject wrapper (a hook's component, a creature) after the object is destroyed and GC'd. Any `__index` on it (property or method) is a native AV in `UStruct::FindProperty`. `IsValid()` itself is safe, because UE4SS checks its live-object set. | `crash_2026_10_26_15_56_19` (BUGS L37: `combat.on_ai_action` refs, read by the next fight's `ability_frame`) | Hooks and state store **paths or ids**, never refs, and re-find with `U.find_object` + `U.alive`. Otherwise run `U.valid` in the same tick before every read of a cached ref. `U.loc` validates. Test: test_combat "stale: …" (a freed fake counts any access as the crash). |
| R14 | **Probe mismatch**: the brain's top-level `probe: true` was ignored by the body (the guard read `args.probe`), so a probe of `stop` really stopped. | code reading, 2026-10-25 | `bridge.lua` copies `msg.probe` into `args.probe` (needs a restart). Tested in `test_core`. |

---

## 8. R2 client body (Claude's own game client)

Route R2 (`docs/design/real-player-remediation.md`): Claude plays through a real, headless Dragonwilds client with UE4SS and the `DWClient` mod (`client_mod/`).
- The brain and `GameInterface` are unchanged; only the body moved.
- The shape follows Microbot/Mineflayer (`docs/research/2026-10-25-client-side-botting.md` decision 1): a client-side game API plus an "agent server". Our agent server is the JSONL bridge.

### 8.1 Layers

```
 brain/ (unchanged)  run_live --body client  (paths.body_kind, transport.endpoint_files)
        │  JSONL: client_io/bridge/brain_to_client.jsonl ⇄ client_to_brain.jsonl (BRIDGE_PROTOCOL.md "Client endpoint")
        ▼
 client_mod/scripts/client_bridge.lua   dispatch · ONE action slot · waiters · get_state · chat → command_received
        │  a fresh loadfile instance of mod/scripts/bridge.lua (one protocol implementation for both bodies)
        │  hot-loads modules: re-reads <name>.lua at most every 2 s and reloads it when the text changed
        ▼
 client modules (one owner each): chat.lua · move.lua · sense.lua · inventory.lua · combat.lua · (next: gather, ...)
        │  arbiter.lua: one owner of the pawn at a time (reflex > command > task > idle; suspend + resume)
        │  shared helpers: mod/body/util.lua (loadfile), dkjson
        ▼
 the game's own CLIENT paths: UI handlers, Enhanced Input injection, character calls (never server RPCs)
```

- `client_mod/scripts/main.lua` (**needs a client restart to change**) does three things:
  - keeps the command runner (`client_io/cmd/*.lua` → `client_io/out/*.json`, `tools/client_cmd.sh`);
  - autostarts the bridge with `loadfile` (`DW_CLIENT_BRIDGE=0` turns this off);
  - uses dkjson for runner output.
- Everything below `main.lua` reloads without a restart. `client_mod/commands/bridge_start.lua` restarts the bridge from the newest file: it stops the old loop and keeps the chat hooks. `bridge_status.lua` and `bridge_stop.lua` complete the set.
- Bridge events go to `logs/client/mod_<ts>.jsonl` (dwlog); module text logs go to `logs/client/client.log`.
- **Background services are supervised by the bridge** (`client_bridge.SERVICES`):
  - `chat.start` (receive hooks), `sense.vitals_start` (vitals watcher), `combat.guard_start` (self-defence; `DW_COMBAT_REFLEX=0` off), `inventory.reflex_start` (stay fed) and `tickguard.start` (slows the deadlock-prone `LightFlickeringWorldSubSystem` tick; DISCOVERIES "Client hang (R2)");
  - re-armed after a pause (`DW_PAUSE`) clears;
  - started at bridge start (`start_modules`, so at client boot from `main.lua`, and by `bridge_start.lua`);
  - re-checked every 10 s and restarted while not healthy. At the main menu the hooked classes may not be loaded yet;
  - re-armed when their module file hot-reloads (their start swaps in the new handlers);
  - backoff to once a minute after 3 failed starts;
  - state in `bridge_status.services` (`running` / `starting` / `missing`, `starts`).
  - Nobody needs to start them by hand after a client restart any more.

### 8.2 Module API, as the bridge uses it

Every function takes the DWClient text logger `log(msg)` first and returns a table with `ok`. Fields may be flat or under `data`. A failure carries `reason` or `error`, as free text or a snake_case code; `client_bridge.REASONS` / `REASON_PATTERNS` map these to protocol reasons. Positions are metres `[x,y,z]`. Loading a module has no side effects, and live state lives in `_G`.

| Module (owner) | Functions the bridge calls | Feeds tools |
|---|---|---|
| `chat.lua` | `start(log)` (idempotent hooks, called at bridge start); `say(log, text)`; it writes `client_io/events/chat.jsonl` `{type:"chat", from, text, self, player_id, guid}` | `say`; chat lines → `command_received` |
| `move.lua` | `go_to(log, [x,y,z] \| name, {tolerance_m})`, `follow(log, name, distance_m)`, `stop(log)`, `status()` → `{mode, status, result={status=arrived\|failed\|stopped, reason, dist_m}}` | `go_to`, `follow`, `stop`, `move_status` |
| `sense.lua` | `me(log)` → `{name, position, health, max_health, stamina, survival = {stat = {cur, max}}, skills, ...}`; `census(log, {radius_m, max})` → `{players, creatures, items, resources, interactables, players_online}`; `U` (mod/body/util), `local_pc()`, `local_pawn()`; writes `client_io/events/vitals.jsonl` (`damage`, `survival`, ...) | `get_state`, `me`, `census`, `look`, `inspect`, `interact` (target lookup, aim), events `attacked`, `vitals_low` |
| `combat.lua` + `arbiter.lua` (combat/arbiter agent) | `combat.HANDLERS.attack` (async), `combat.status()` (`fight`, `guard`), `combat.stop(log, why)`, `combat.guard_start(log)`; `arbiter.owner()` / `status()` (who owns the pawn: reflex > command > task > idle) | `attack`, `stop` (commanded fights), `get_state.fight`, service `combat_guard`; follow/go_to/interact wait while a reflex owns the pawn. A fight that starts during an NPC dialogue leaves it through `talk.stop(why)` + `talk.start{leave=true}`, falling back to the panel's own Cancel and never `IA_UI_GenericBack`, and emits activity `conversation_interrupted {why = attacked \| fight_ordered, npc, attacker, via}` |
| `gather.lua` (gather agent) | `gather.HANDLERS.gather` (async), `gather_status`; events `client_io/events/gather.jsonl` (`gather_progress`, `gather_status`); profiles `gather_profiles.lua` | `gather` (failures carry `data.why` + `data.detail`, spoken as is), `gather_progress` events |
| `move.lua` events | `client_io/events/move.jsonl`: `unreachable` (once per episode), `reachable_again`, `stuck` | events `unreachable`, `resumed` |
| `inventory.lua` | `list(log)` → `{hotbar, bag, loadout, personal, held}` (rows carry `consumable`); `drop(log, what, count)`; `equip(log, what)`; `unequip(log, slot)`; `interact_target(pawn)`; `press_interact(log)`; `describe_item(item)` | `get_state.inventory/inventory_items/gear/held`, `drop`, `equip`, `unequip`, `inventory`, `interact` (detector + press), `inspect` (container contents), `vitals_low` (has food/drink) |
| `arbiter.lua` | `request(log, {name, level=reflex\|command\|task\|idle, uses_move, lease_s, on_suspend, on_resume, on_stop})` → `{ok, token, preempted}` or `{ok=false, reason="busy", owner}`; `release(log, token)` (resumes the newest suspended owner, replaying its move via `move.snapshot/restore`); `renew`, `holds`, `is_suspended`, `owner`, `status`; HANDLERS `arbiter_status` | which module owns the pawn; reflex fights suspend and later resume commands and tasks |
| `traverse_learn.lua` (traversal agent; READ-ONLY recorder) | `start(log, {world})` / `stop` / `status()`; for move.lua: `links_near(pos, radius_m, {env, usable_only})`, `best_link(from, to, {env, radius_m, max_detour})`, `usable(link, env)`, `record_attempt(log, id, ok, reason)`, `forget(log, id)`, `rebuild(log, world)`; HANDLERS `learn_status`, `learn_links` (not yet in `MODULES`). It records other players' and Claude's own airborne events into `logs/state/worlds/<world>/traversal_events.jsonl` and clusters them into `data/skills/<world>/traversal_links.json`. It is the **only writer** of that file. | (planned) link segments for go_to/follow; "what have you learned?" |
| `combat.lua` | `attack(log, target, {force})`; `guard_start(log)` / `guard_stop` (the reflex); `stop`; `status`; `set_orders({stance, avoid, force})`; HANDLERS `attack` (async `{pending}`), `combat_status`, `combat_orders`. Pure: `assess`, `best_weapon`, `score_weapon`, `pick_threats`, `learn_outcome` | `attack`; `attacked` → reflex fight or flee |
| `defense.lua` | pure: `plan(info, ctx, orders)` → parry / block / dodge / jump / retreat / none with timing; `observe(key, dt)`, `feedback(key, action, outcome)` (learned per attack); `shape_info` | used by combat's defend phase |
| `ranged.lua` | pure: `solve(muzzle, target, vel, params)` (lead + drop), `camera_rotation`, `fit(samples)`, `closest_approach`, `learn`, `record`/`metrics`; `new_aimer(key, seed)` (`observe`, `solve`, `fired`, `sample`, `finish`); live reads `read_weapon_params`, `read_spell_params`, `muzzle`, `camera_location`, `projectile_ids` | combat ranged engage; aimed projectile spells (contract in docs/design/ranged-aim.md) |
| `gather.lua` + `gather_profiles.lua` (gather agent) | HANDLERS `gather` (async `{pending}`; args `{resource, count, radius, stumps}`), `gather_status`; `start(log, args, ctx)`, `stop(log, why)`, `status()`. Data: `gather_profiles.RESOURCES` (mode chop/pickup, tool, root/children classes, aliases), `resolve(name)`. Uses `sense.foliage`, `move.go_to`, `inventory.{list,equip,held,interact_target,press_interact}`, `combat.{actions,_inject,weapons}`, arbiter level `task`. Events: `client_io/events/gather.jsonl` (`gather_progress`, `gather_status`) | `gather`; standing trees in `census.resources` (kind `foliage`) |
| `spells.lua` (spells agent; design `docs/design/client-spells.md`) | HANDLERS `spells` (read; `{all}`; rows in the brain/spells.py SpellBook shape `{id, name, role, use_when, castable, reason, remaining_s, detail, cost, wheel_page, wheel_key}` from game data only) and `cast` (WAITER `{wait}`: never takes the action slot; arbiter level 3.5, so a follow or gather is suspended and resumed). Cast path: Q (`IA_SpellMenu`), then turn pages (`ChangeSpellRadialRight`) until the slice icon = the spell's `SpellIcon`, then the number key (`QuickAccess0..7`), then for placed/aimed spells camera aim + LMB (`IA_Spellcasting_PlaceSpell`). Verify: runes fell or `LastCastTimeBySpellData` changed. Cleanup: Q or Esc. Pure: `resolve` (exact, else a unique typo), `row`, `harm_check` (never at or near players, from Damage/Shape modules + catalog role), `diff`. `W` = engine touches | `cast`, `spells` (SpellBook → Controller `castable_spells`) |
| `crafting.lua` (crafting agent) | HANDLERS `craft` (async; args `{recipe or item, count, station?, fuel?}`), read tools `recipes`, `craft_plan`, `stations`; `state_extras` (get_state `stations_nearby`). Pure: `assess`, `candidates`, `plan_tree`, `craftable`, `choose_fuel`, `plan`, `result_failure`. Data: `mod/body/recipe_data.lua` (generated; `uq` = unlock queries). Real paths: interact press to open, `CraftingUIAPI:SelectRecipe` + `SendCraftRequest`; processing via `InventoryUIAPI:HandleSplitToExternalSlot` + `ProcessingStationUIAPI:ToggleProcessingStationStarted`; verdict from a read-only post-hook on `Client_OnCraftingResultHandler` | `craft`, `recipes`, `craft_plan`, `stations`; one recipe per craft (the model sequences sub-crafts from `craft_plan`) |

### 8.3 Rules (client side)

1. **Real player paths only.** UI handlers, input injection and character calls. Never call `Server_*` RPCs from the client, never write inventory or game state, never emulate an outcome. (Decision 2 of the client-side-botting research.)
2. **Verified results.**
   - A tool answers `ok` only once fresh game state confirms it: `go_to` re-reads the position, `drop` waits for the count to fall, `say` waits for the server's echo.
   - The brain verifies again (`executor.VERIFIERS`).
3. **Two speeds.** Per-frame loops (steering, combat reflexes) live in the modules. The bridge ticks every 100 ms: it polls, steps the action, tails chat and resolves waiters. The LLM only picks tools.
4. **Pause means no game calls.** While `_G.DW_PAUSE` is true (disconnect, join), every loop returns at once and the bridge answers only ping/capabilities/bridge_status (crash_2026_10_25_19_08_42: a UFunction call during world teardown). The bridge clears it after 3 s with a pawn in `L_World` and re-arms the services.
5. **Perception is generic.** `look`, `inspect`, `interact` and the digest work on `sense.census` categories and the census row fields (`kind`, `verb`, `prompt`, `tool`, `health`), never on hand lists of things. A new kind of thing shows up as soon as sense describes its class family.
6. **One action slot.**
   - Tools that move the body (`ACTION_TOOLS`) pre-empt the current action, which answers `interrupted`.
   - Waiters (`say`, `drop`) never pre-empt.
   - Probes never act. Missing required args answer `invalid_args`.
7. **The client is Luis's shared world.** Experiments that move the pawn or chat belong to that module's owner. The bridge itself is read-only until the brain sends an action.

8. **The modal gate (input.lua; build review 2026-10-26, finding 4).** Gameplay input goes out only through `input.gate()` / `input.inject()`. It is refused while any of these is open:
   - build mode (`BuildModeComponent.CurrentBuildMode ~= None`): the attack click is the place click there;
   - a container screen (`InventoryUIAPI.WorldInventoryAPI.InventoryComponent`);
   - a non-gameplay input mode (`PC.CurrentInputMode ~= DIM_Gameplay`: spell wheel/placement, `DIM_OculusBuildMenu`).

   The modal's owner claims it (`input.claim(kind, owner)` / `release`) and passes `opts.modal = kind` for its own presses. Its arbiter `on_suspend` leaves the modal at once (build: release + one Cancel; store/take: close the screen).

   A build mode or chest screen that nobody owns is cleaned up after 1 s (Cancel, or `CloseCurrentInventory`; one step per second, at most 3, then reported `stuck`). An input mode is never exited by guessing; it is only blocked and reported. Under `DW_PAUSE` the gate answers `paused` and nothing is read.

   Adopted by combat, spells, fishing, agility and farm. A new module that presses keys calls `input.gate()` first. If it opens a screen of its own, it claims that screen.
9. **Action tools from manifests.** `M.is_action_tool(tool)` is the fixed `ACTION_TOOLS` list, plus any module `MANIFEST` entry with `kind = "action"` and `moves = true`. A new skill module needs no bridge edit beyond adding its name to `M.MODULES`.
10. **Shared placement loop (placement.lua; finding 13).** `P.spots` / `P.checker` run over an injected env (trace, me, players, aim, read). A press is authorised only when `read()` says valid, the preview is on target, and the read is fresh (newer than the latest aim). build.lua passes "unreadable = no press". spells keeps its own `press_once` rule.

6. **Owning the pawn.** A module that moves the body or presses gameplay keys first calls `arbiter.request` at its level (a skill = `task`, a brain command = `command`, a reflex = `reflex`), renews its lease in its loop, and calls `arbiter.release` when done. It moves only through move.lua's public API. If it can be resumed after a fight, pass `on_resume` (or rely on the move snapshot the arbiter takes).

### 8.4 How to add a skill on the client (e.g. `gather`)

1. **Discover and prototype** in the module that owns the concern (`client_mod/scripts/<concern>.lua`, its own command files in `client_mod/commands/`). Record what is verified in DISCOVERIES ("REAL CLIENT ROUTE (R2)").
2. **Expose it to the brain**, by one of two routes (no restart either way):
   - **Route** (preferred for protocol tools): add `R.<tool> = {needs = {{"<module>", "<fn>"}}, fn = function(args, ctx) ... end}` in `client_bridge.lua`.
     - Validate args and answer `invalid_args`.
     - Return a result (sync), `{pending = action}` (async: `poll(a)` returns nil until done, then a result; plus `cancel`, `timeout_s`), `{result, hold = action}` (answered now, keeps the slot, like follow), or `{wait = waiter, wait_s}` (confirmation without the slot, like drop).
     - Add the name to `M.ACTION_TOOLS` if it moves the body.
   - **Module handler** (no bridge edit): export `M.HANDLERS = {tool = function(log, args, ctx) ... end}` from a module listed in `client_bridge.MODULES`. It returns the same shapes and appears in `capabilities` at once.
3. **Reload:** `sh tools/client_cmd.sh client_mod/commands/bridge_start.lua`. Then check `capabilities` with `python -m tools.bridge_cmd --body client capabilities`.
4. **Test offline:**
   - add the module's fake to `client_mod/tests/fakes/<module>.lua` (same API and result shape as the real one);
   - add a case to `client_mod/tests/test_client_bridge.lua` covering success, each failure reason and the probe;
   - for brain-visible behaviour, add to `tests/test_client_bridge.py` (the Lua client bridge driven by the real BridgeClient and `run_live`).
5. **Brain side:** nothing, if the tool already exists in `interface.TOOLS`. Otherwise follow §4.1 step 4. Document client-specific behaviour in `BRIDGE_PROTOCOL.md` "Client endpoint".
6b. **Add a buildable / a container use:** nothing. `buildables` / `build` read every unlocked piece from the game's data (`ProgressComponent.BuildingsUnlocked` × `UBuildingPieceData`), and `store` / `take` work on any actor with an inventory. A new piece shows up as soon as he unlocks it (design `docs/design/build-primitive.md` Rev 2).
6. **Add a gatherable** (a new tree, rock, bush or ground pickup) = one entry in `client_mod/scripts/gather_profiles.lua`: `mode` (chop/pickup), `tool`, `root` class family + class-word pattern (read the `class` of the foliage or actor row from `client_mod/commands/gather_scan.lua`), `children` for multi-stage chains, `item`, `aliases`. No code.

### 8.4b The capability contract: manifest, primitives, composite engine (streamline plan step 2)

Root cause R2 of the 19:22–19:26 episode was that the brain's tool list was hand-written and offered tools the body lacked (`pickup` → "Sorry, I can't pick things up yet"). The fix: **the body publishes its contract and the brain builds the model's tool list from it ONLY.**

- **Precedent** (search-before-building):
  - MCP `tools/list` {name, description, inputSchema}, turned into the model's function list at connect time;
  - MINDcraft's command table: name, description, typed params with domain, `runAsAction(fn, resume, timeout)` (github.com/kolbytn/mindcraft `src/agent/commands/actions.js`; arXiv 2504.17950);
  - the ToolFailBench taxonomy: Tool-Skip / Result-Ignore / Output-Fabrication (arXiv 2607.04686).
  - Decision: **adapt**. JSON Schema validation is **reused** (`jsonschema` 4.26, pinned in brain/requirements.txt).
- **Body side.** `client_bridge.lua` `capabilities` answers `{tools, manifest: [entry per IMPLEMENTED tool], aliases, manifest_version}`.
  - The entry shape is documented in `client_mod/scripts/manifest.lua`: name, description (for the LLM), args (JSON Schema, with no top-level anyOf because model APIs reject it), kind (action | read | waiter | probe), llm, moves, priority, preconditions, duration_s, timeout_s, reasons, ground ({arg: kind}), detail_is_speech, aliases.
  - Entries come from `manifest.lua`; a module's own `MANIFEST[tool]` wins over it (skills, combat, gather, spells, crafting).
  - A module handler is listed only while its `NEEDS = {tool = {{module, fn}}}` exist.
  - Get_state extras: every module in `M.MODULES` may export `state_extras(api, data)`.
- **Brain side** (`brain/capabilities.py`):
  - `Capabilities.manifest`, `llm_tools()`, `function_schema()`, `validate()` (manifest schema, then the pydantic model if the brain has one), `timeouts()` (fed into `BridgeClient.timeouts`), `skills()`/`registry()` (the planner registry = manifest actions and waiters; tools without a pydantic model carry their manifest spec), `resolve()` (legacy `pickup` → `interact`).
  - `Controller(caps=...)`: tools come from the manifest only. Without a manifest, ACTION_TOOLS are filtered by what the body lists.
  - A body tool name the body lacks becomes a `not_implemented` refusal, so no reply claims an action that never ran.
  - Rule tools and spells are offered and queried only when the body has them.
  - `GameInterface.call` sends tools without a typed method through `call_raw`.
- **PRINCIPLES 4b (Luis): primitives first, and the model composes them.**
  - Offered to the model: `go_to` (a player name, an id, a place or coordinates), `follow`, `stop`, `interact` (the frame-coupled engine), `consume` (hotbar only), `move_item` (bag ↔ hotbar), `equip` (a verified waiter), `drop`, `set_vitals_policy`, `look`/`inspect`/`inventory`, plus combat/gather/spells/crafting's own entries.
  - Multi-step requests are several tool calls in ONE response. `brain/llm.py` no longer disables parallel calls. The agent runs them in order, each verified, and stops at the first failure.
  - Real Haiku composed them correctly (evals/manifest_eval.py): "give me the logs" → go_to(Zezima) + drop(Ash Logs); "eat something" with food in the bag → move_item + consume.
  - `fetch`, `come_to`, `recover_grave` and `give` (skills.lua) are kept, tested, as `llm = false` debug compounds.
- **The interact engine** (`skills.lua` `episode_poll`, used by `interact`, crafting and the compounds):
  - It acquires the pawn through the arbiter (level `command`). A reflex fight suspends it; it re-approaches on resume, and its timer stops meanwhile.
  - Approach: `move.go_to` with 1 m tolerance, then one tighter approach at 0.6 m.
  - Face: the camera with `SetControlRotation`, plus a small `AddMovementInput` nudge, until the game's own detector (`inventory.interact_target`) targets the thing. A detector on any world item of the wanted item id counts.
  - Then one press (`secondary = true` presses `SecondaryInteractAction`; collect-all is UNVERIFIED live).
  - Verify: the inventory grew, or the target is gone. Re-press at most twice.
  - Every failure carries a reason, a `why` code and a factual `detail`.
  - A pawn held by a non-fight owner for 20 s fails `busy`, naming the real owner (never a guess).
  - `_G.DW_PAUSE` means no game calls.
- **Perception added for the model** (get_state → `brain/situation.py` digest):
  - `my_grave` {id, distance, items, contents, owner verified | unverified}; `other_graves`; `last_death`;
  - `last_held`, re-equipped after a grave recovery;
  - world items' `consumable` kind, `dropped_by`, `seen_s`;
  - `time_of_day` {hour, phase day | night, sleep_allowed};
  - `bag` {used, capacity};
  - `vitals_policy`;
  - `held_actions` (combat); `stations_nearby` (crafting);
  - item stats from `data/items_<build>.json` (`brain/item_stats.py`: PL, weight, slot, tool tier, armour class, attack names, and numeric deltas to what is equipped; no verdict).
  - Events: `items_dropped` (once per burst), `activity` (from `client_io/events/activity.jsonl` and the reflex's own acts), and `vitals_low` (below the model's policy, nothing usable on the HOTBAR, `in_bag`/`unusable` lists).
- **Vitals policy** (review H2/M8): `set_vitals_policy {drink_below_pct, eat_below_pct, heal_below_pct, reserve_warn}` is the model's call. `inventory.lua` keeps only a 10 % safety floor.
- **Needs, memory, safe reload (2026-10-25 late; BUGS L16–L22):**
  - `brain/needs.py` turns state into one line per pressing need (food, drink, health, rest, a missing tool): options carried, nearby, remembered, craft/cook (an estimate; `craft_plan` confirms), players who could help, time to empty. An `Activity` line lists the skill's spells and rate vs best.
  - `brain/map_memory.py` is the ONE per-world map/resource memory (`logs/state/worlds/<w>/map_memory.json`). Every get_state feeds it through `BridgeClient.state_hooks`. The Director reads it through `load`/`query`.
  - `explore {about}` searches outward along least-visited legs (skills.lua).
  - Every unrecovered grave is kept in `client_io/state/last_death.json` (`go_to 'my_grave:<ts>'`).
  - `bridge_start.lua` waits for the bridge to be idle, refuses after 5 s with the reason, and hands over the read offsets. `bridge_start_force.lua` is for emergencies only.
- **How to add a tool now:** a module handler plus its `MANIFEST` entry (plus `NEEDS`). The brain needs no edit unless the result needs a verifier (`executor.VERIFIERS`).

### 8.5 Tests

| What | Command |
|---|---|
| Client bridge (fake modules) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_client_bridge.lua <empty_dir>` |
| Arbiter + combat (fake engine: whole fights, flee, block, dead inputs) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_combat.lua` |
| Traversal recorder (kinematic fake leader on a heightmap: jump-up, gap, double jump, Windstep, drop, air dash, hop, teleport; clustering, self-verify, pause, per-world store, API, rebuild) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_traverse_learn.lua <empty_dir>` |
| Gather (fake world: oak chain, tools, failures, suspend/resume, pickups, foliage maths) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_gather.lua` |
| Spells (fake game: wheel pages by icon, quick keys, placement, runes/cooldown verify, safety floor, arbiter suspend/resume, pause) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_spells.lua` |
| Crafting (real catalog planner; fake world: bench + furnace jobs, every failure reason, fuel, shared stations, UI closed on every exit) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_crafting.lua` |
| Client bridge ⇄ brain (BridgeClient, capabilities, run_live dry run end to end) | `.venv\Scripts\python.exe -m pytest tests/test_client_bridge.py` |
| Capability manifest + composite skills (real bridge + skills + manifest + arbiter over fakes: manifest per implemented tool, interact engine, consume/move_item/equip, compounds, arbiter suspend/busy, pause, items_dropped, activity, vitals re-arm) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_skills.lua <empty_dir>` |
| Contract on the brain side (the real Lua manifest drives the tools, schema validation, alias, today's lines via a scripted model, ordered go_to + drop) | `.venv\Scripts\python.exe -m pytest tests/test_skills_contract.py` |
| Stay-fed reflex + vitals policy (floor, heal) | `"C:\Program Files\WinGet\Links\lua.exe" client_mod/tests/test_inventory_reflex.lua <empty_dir>` |
| Real-model eval of the tool list (states its call budget; `--yes` spends it) | `.venv\Scripts\python.exe -m evals.manifest_eval --yes` |
| Scenario runner (fake body + ops: dry run read-only, live switch/run/switch back, failed leg, crash, preflight abort, Lua prefix compiles) | `.venv\Scripts\python.exe -m pytest tests/test_scenario_run.py` |
| Timeline (synthetic logs: zones, window, noise, collapse, redaction, CLI/HTML/JSONL) | `.venv\Scripts\python.exe -m pytest tests/test_timeline.py` |
| Live validation queue (fake env + the real client_slot: check-file validation, templates, criteria, slot taken/renewed/released, hold, guard, crash wait + bridge_start, stuck input mode sweep, retries, blocked/error caps, observe-only, timeout, single instance, `--if-free`, dry run) | `.venv\Scripts\python.exe -m pytest tests/test_live_queue.py` |
| Join targets + lease + wrong-server watchdog (fake client) | `.venv\Scripts\python.exe -m pytest tests/test_client_ops.py -k "target or lease or wrong_server"` |
| Front-end limit, BUGS L24 (fake client: counted returns, a switch after 2 relaunches instead of disconnecting, menu rejoin, watchdog event) | `.venv\Scripts\python.exe -m pytest tests/test_client_ops.py -k "frontend or returns or relaunch or counted"` |

### 8.6 Process: dev-server scenario suite and the timeline (streamline plan step 6)

**Join targets.** A target is a gitignored file in `client_io/secrets/`: `server.txt` = `shockbyte` (Luis's world, the default) and `server_<name>.txt` = `<name>` (`server_dev.txt` = the nav-only dev server, 127.0.0.1:7777). Line 1 is the address, line 2 the password. Which target applies is decided in one place, `Resolve-ClientTarget` in `tools/client_lib.ps1`:
1. `client_boot.ps1 -Target <name>`;
2. else an unexpired **lease** `logs/state/client_target.json` `{target, until, by}`, written and renewed by `tools/scenario_run.py`;
3. else `shockbyte`. An expired or missing lease always means Shockbyte.
- "Which server is the client on" = the client game log's last `LoadMap: <host:port>/Game/Maps/World/L_World` (`Get-JoinedServer`; the `?p=` part is never returned). When it is unknown, nothing switches.
- `client_boot.ps1` in the world on a different server than the target: `disconnect.lua`, then the normal menu → join path. The join runs `join_server.lua` with `local SECRETS_FILE = "server_<name>.txt"` prefixed (a chunk local, so nothing persists into the next join).
- **Front-end limit (BUGS L24).** The game crashes on the 3rd return to `L_FrontEnd` within one client process, so a process gets at most 2 (`DW_CLIENT_MAX_FE_RETURNS`). `client_lib.ps1` counts them per process: `Get-FrontEndReturns` = max(the game log's `LoadMap .../L_FrontEnd` lines after the startup one, when the log's "Log file open" stamp is not older than the process; `logs/state/client_frontend_returns.json` `{pid, start, returns}`, raised by `Register-FrontEndReturn` on every boot `disconnect.lua`, because the log can stall). When the count is used up, `client_boot.ps1` relaunches instead (`Invoke-Relaunch`: `Stop-ClientProcess`, launch, the normal menu → join path; once per boot run) before a target-switch disconnect or a rejoin from the menu; at a forbidden server it kills the process instead of disconnecting. The rule lives only in boot, so the watchdog, `scenario_run.py` and the bench (`devrun --switch`) get it by going through boot. Read it with `tools/client_frontend.ps1` (one JSON line) or `tools.scenario_run.frontend_state()`; `relaunched(boot_result)` tells whether a boot relaunched. The watchdog's `boot_start` event carries `fe_returns` and `relaunch`. Never send `disconnect.lua` by hand.
- The client watchdog (`WrongServerS`, 60 s) reruns boot when the client sits on a server other than the target. So the lease keeps a scenario run's rejoins on dev, and when a runner dies the lease expires and the watchdog brings Claude back to Shockbyte.
- `Protect-Secret` redacts the password of every target file.

**Scenario suite** (`tools/scenario_run.py`, data in `tools/scenarios/dev_suite.json`):
- Dry run (default) is read-only on any server. `--live` = preflight → Shockbyte baseline snapshot → Claude.json backup → lease → boot `-Target dev` → scenarios → lease cleared → boot `-Target shockbyte` → snapshot diff (in a `finally`). `--here` runs on the current server without switching (refused on Shockbyte).
- It talks to the bridge's **debug channel** (the same tools as the brain). Read-only probes and fallbacks go through the command runner with `local ARGS = {...}` prefixed (`run_client_cmd`): `client_mod/commands/scn_find_ledge.lua` (traces only) and `scn_consume.lua` (one hotbar use; used only while there is no `consume` tool).
- Nav memory: `traverse_learn.world_id()` falls back to "shockbyte" on any server, so a live run sets `_G.DW_WORLD_GUID` through `scn_world.lua`: `--memory dev` (default) = `dev_scenarios`, `nomem` = a fresh `scn_nomem_<ts>`, `shared` = no override. It is re-applied per scenario and restored in the `finally`.
- Every outcome comes from a fresh `get_state`/`look` read: position within tol in 2D and 1.5 m in height, inventory deltas, the stat rising, the target gone or dead.
- **Add a scenario** = one entry in `dev_suite.json` of an existing kind, with its places and pass text:
  - `go_to_chain` (legs may carry `expect_log`, a client.log regex recorded as evidence);
  - `ledge_jump`, `fetch_consume`, `combat`;
  - `collect_cluster` (N stacks within r m, collected against a time budget);
  - `grave_recovery`.
  - `repeat: N` = N runs in a row, all of which must pass; `--repeat` overrides it. A new kind = one `k_<kind>` method in `Runner` plus `KINDS`, returning an `Outcome` (pass/fail/skip/error/dry + evidence) and acting only when `self.live`. Then add a fake to `tests/test_scenario_run.py`.

**Timeline** (`tools/timeline.py`): one reader per source (chat, brain-live, move, vitals, activity episodes, other events, client watchdog, boot.log, client.log, mod_*.jsonl, the client game log filtered to joins/travel/failures, scenario reports) → `Row(ts, src, kind, text, level, noise, key)` → merged by time, noise hidden unless `--all`, adjacent identical keys collapsed into one `(xN)` line, passwords redacted. Every source's own zone is honoured (event files UTC, brain-live names local, boot.log `+01:00`). **Add a source** = a reader function plus one line in `discover()`. `--jsonl` writes normalised rows for lnav (`tools/lnav/dw_timeline.json`); `--html` writes a self-contained filterable page. The scenario runner writes the run's timeline beside its report.


### 8.7 How to queue a live check (live validation queue, 2026-10-26)

Offline-tested client changes used to wait hours for a live run on the one client (main messaging agents one by one,
stale reservations). Now an agent **writes one file** and the queue runs it the next time the client is free.

1. Write `tools/live_checks/<id>.json` (the file name is the id; copy a seed check). Fields:
   - `id` (`[a-z0-9_]+`), `owner` (your agent/area), `commit` and/or `area`, `why`;
   - `preconditions`: `fixtures` (dev-server harness grants through `DevTarget.setup`: `grant {item, count}`,
     `grant_runes {runes}`, `unlock {spell}`, `teleport {at}`, `spawn`, `set_time`, ...), `set_health {pct}`, and
     `input_mode` (e.g. `DIM_Gameplay`, read with `bench_probe.lua`; a mismatch = **blocked**, nothing acts);
   - `steps`, in order, each one of: `{"bridge": tool, "args": {...}, "timeout_s", "save"}` (the body's own tool on the
     bridge **debug** channel, like `tools.bridge_cmd`), `{"client_cmd": "client_mod/commands/x.lua", "args", "save"}`
     (the DWClient runner, `local ARGS` prefixed), `{"probe": true, "save"}` (read-only `bench_probe.lua`: position,
     input_mode, inventory by item id, vitals), `{"sleep_s": n}`, `{"fixture": verb, ...}`. Args may use templates:
     `{"$ref": "start.position"}`, `{"$offset": ["start.position", [12, 0, 0]]}`,
     `{"$find": {"in": "stations.data.stations", "match": {"name": "ampfire"}, "get": "id"}}` (unresolved = blocked);
   - `pass`: criteria over the saved values, all must hold: left side `ref` (dotted path into saved replies/probes),
     `delta: [ref_before, ref_after]` (missing = 0), `dist: [ref_a, ref_b]` (2-D metres), or
     `log: {source: client|game|vitals|activity, regex}` (match count in lines written DURING the check); one operator
     `eq ne gt gte lt lte in contains exists truthy falsy regex`; optional `why`;
   - `observe`: refs/expressions recorded as evidence only (`{"name": ..., "dist": [...]}` names one);
     `observe_only: true` = an exploratory run whose verdict is **observed** (criteria recorded, not gating);
   - `timeout_s` (whole check, including setup) and `max_retries` (re-runs after failed/error in the same sitting).
2. Validate offline: `.venv\Scripts\python.exe -m tools.live_queue run --dry-run` (structure, command files, catalog
   item/spell ids, bridge tool names present in `client_mod/scripts`). No game call, no slot.
3. That's it. The Scheduled Task `DragonwildsLiveQueue` (`tools/register_live_queue_task.ps1`) calls
   `live_queue.py run --if-free` every 5 min; it drains when the client slot is free (and nobody is queued in
   `client_slot`), no hold file exists and something is pending. Main can drain at once, detached:
   `Start-Process -WindowStyle Hidden -WorkingDirectory C:\gameserver C:\gameserver\.venv\Scripts\python.exe -ArgumentList '-m','tools.live_queue','run'`.
4. Read the verdict: `live_queue.py list` / `status`; evidence (every step reply, probe, criterion with its actual
   value, observations) in `logs/live_queue/<date>.jsonl`; state in `logs/state/live_queue.json`.
   `live_queue.py requeue <id>` re-runs a finished check; editing the file re-queues it automatically (hash).

**What a run does** (`tools/live_queue.py`): OS file lock (one instance; a second exits 0) → refuse on
`logs/client.hold`/`client.stopped` → `client_slot take live-queue` (renewed per check, released in a `finally`) →
precheck (watchdog status `in_world` and fresh, `DevTarget.guard`: loopback dev server only, never a forbidden target,
`run_live` not running; bridge ping) → `bridge_start.lua` → each pending check → **recovery** after each: a crashed or
relaunching client is waited for (up to 8 min; the client watchdog relaunches it, the queue never launches, kills,
boots or rejoins the client and never touches Steam), then `bridge_start.lua` again; a non-Gameplay input mode gets one
`input_gate_once.lua` (the modal gate's own sweep) and is reported if it stays. A hold file appearing stops the run
between checks. Verdicts: passed | failed (stays failed until edited/requeued) | observed | blocked / error (no verdict;
retried on later drains, at most 3 runs).

**Decision (search-before-building):**
- Need: run queued live checks on one shared device when it is free.
- Searched: device-test schedulers (LAVA, labgrid), Task Scheduler repetition + MultipleInstances docs.
- Found: LAVA is the canonical "job queue over a device pool, with health checks between jobs" design. It is a
  Debian/Django service with device dictionaries, far too heavy for one Windows game client, and its scheduler does
  not compose with an external lock (the lava-users labgrid threads). Task Scheduler: a `-Once` trigger with
  `-RepetitionInterval` repeats forever, and `MultipleInstances IgnoreNew` skips a trigger while a run is active.
- Decision: **adapt.** Borrow LAVA's model (queued jobs, a health check before and between jobs, an infra error kept
  apart from a test failure). Reuse what the repo has: `client_slot` (the device lock), `DevTarget` (the dev guard and
  fixtures), `BridgeClient` on the debug channel, `run_client_cmd`, `bench_probe.lua` and `input_gate_once.lua`.
  Trigger with **Task Scheduler** (the project already registers `DragonwildsClientWatchdog` this way) rather than a
  hook in `client_slot release`. An expired lock, from an agent that died, never calls release. A timer covers both
  cases and needs no daemon.
- Sources: https://lavalab.nxp.com/static/docs/v2/naming-conventions.html ,
  https://op-lists.linaro.org/archives/list/lava-users@lists.lavasoftware.org/message/YRC7VKVJ2X77ARUJRGULKOS3Q26YI5HH/ ,
  https://technet.microsoft.com/en-us/library/jj649821(v=wps.630) ,
  https://forums.powershell.org/t/how-do-powershell-scheduled-task-repetitionduration-indefinitely/13850 ,
  https://www.powershellgallery.com/packages/Eigenverft.Manifested.Drydock/1.20264.12396/Content/Eigenverft.Manifested.Drydock.ScheduledTask.ps1

> **Deploy note (L28, 2026-10-26):** the game loads the DEPLOYED `ue4ss\Mods\DWClient\scripts\main.lua`, not the repo copy. Other modules are loaded from the repo by path. So a change to `main.lua` must be redeployed (`tools/install_client_ue4ss.ps1`) and the client restarted. The command runner now reads `client_io/cmd/queue.txt` (no process spawning on the game thread).

> **Deploy note (2026-10-26):** after changing `tools/client_lib.ps1` / `client_boot.ps1` / `client_watchdog.ps1`, RESTART the client watchdog (`tools/start_client_watchdog.ps1 -Stop`, then start it). It loads those scripts once, at its own start. An old watchdog kept writing probes the new queue runner never saw, and killed a healthy client about every 4 min (08:04–08:24 UTC).
