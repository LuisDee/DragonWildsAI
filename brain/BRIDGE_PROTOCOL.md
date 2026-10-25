# Bridge protocol v1 (brain <-> body)

This is the message format between the Python brain and the UE4SS Lua body. The
transport is abstracted (`brain/transport.py`). This document covers the
**file-based JSONL fallback**, which is guaranteed to work from Lua because it
only needs `io.open`. A socket transport can carry the same messages later, one
JSON object per newline-terminated line.

## Files

Both files live in one bridge directory. The default is `<repo>/bridge_io/`;
override it with the `DW_BRIDGE_DIR` environment variable.

| File | Writer | Reader |
|---|---|---|
| `brain_to_body.jsonl` | brain | body |
| `body_to_brain.jsonl` | body | brain |

Rules:

- **One JSON object per line**, UTF-8, terminated by `\n`. Write each line with a single
  write call in append mode (`io.open(path, "a")`, `f:write(line .. "\n")`, `f:flush()`,
  `f:close()`), so a reader never sees two lines interleaved.
- Each side **tails** the other's file by byte offset. It reads from its saved offset to the
  current end of file. It processes only complete lines, and keeps a trailing partial line
  until the rest arrives.
- On startup, a reader starts at the **current end** of the file it reads, so stale lines
  from an earlier run are ignored. Request ids make any stale results harmless anyway.
- If a file becomes smaller than the saved offset (truncated or rotated), the reader resets to
  offset 0. Only the writer of a file may truncate it, and only while the other side is
  stopped.
- A reader **must skip malformed lines**: lines that are not JSON, or not a JSON object. It
  logs them and carries on. When the body reads a malformed line, it replies with an `error`
  message with `"id": null`.
- Poll interval: the brain polls every 20 ms while waiting for a result. A Lua body can poll
  from a game-thread loop (`LoopAsync`) every 50–100 ms.

## Client endpoint (route R2: Claude's own game client)

The same protocol, served by the client mod instead of the server puppet:
`client_mod/scripts/client_bridge.lua`. It loads a fresh instance of `mod/scripts/bridge.lua`, so both bodies share one implementation.

| | Server body (puppet mod) | Client body (R2) |
|---|---|---|
| Brain switch | `DW_BODY=server` (default) / `--body server` | `DW_BODY=client` / `--body client` |
| Default dir | `<repo>/bridge_io/` | `<repo>/client_io/bridge/` (`DW_CLIENT_BRIDGE_DIR` on the client side) |
| brain writes | `brain_to_body.jsonl` | `brain_to_client.jsonl` |
| body writes | `body_to_brain.jsonl` | `client_to_brain.jsonl` |

- `DW_BRIDGE_DIR` still overrides the directory on the brain side. The file names always follow the body, so a brain pointed at the wrong directory never reaches the other body.
- Entry points:
  - `python -m brain.run_live --body client [--dry-run]`
  - `tools\start_brain.ps1 -Body client`
  - `python -m tools.bridge_cmd --body client <tool> [json]`
  - `python -m brain.fake_body <dir> client`
- **Capabilities are dynamic.** A tool is listed only while the client module functions it needs exist (`client_mod/scripts/{chat,move,sense,inventory}.lua`, hot-reloaded).
  - Missing or broken module → `not_implemented`, and the tool is not listed.
  - So the brain hides everything else: today `attack, gather, craft, place, give, pickup, cast, sleep, wake` and the rule tools.
  - `ping` and `capabilities` answers carry `body: "client"`.
- **Debug channel:** the client also serves the same tools on `debug_to_client.jsonl` -> `client_to_debug.jsonl`
  (same dir). Use it for live tests (`python -m tools.bridge_cmd --body client <tool>` picks it by default;
  `--channel main` to override), so replies never reach the live brain's file (it logs them as
  `bridge_unmatched`). Events go only to the main channel.
- **Pause:** while `_G.DW_PAUSE` is true (set by `disconnect.lua` / `join_server.lua`), the client makes no
  game calls. Every tool except `ping`, `capabilities` and `bridge_status` answers `companion_down`
  (`get_state` with `data.paused: true`). The running action and waiters end with `companion_down`. The
  bridge clears the pause once a valid local pawn has been in `L_World` for 3 s (checked from 5 s after the
  pause started), then re-arms its services.
- **Chat (since 2026-10-25 evening, Luis: "just read the chat and decipher when a message is for him"):**
  - Every chat line from another player is sent as `chat_heard{from, player, text, ts, mentions_me}`.
    `mentions_me` = a prefix or the companion's name as a whole word anywhere ("hello claude ...",
    "thanks Claude", "@claude"; not "claudette"). Claude's own lines are not sent. `DW_CLIENT_CHAT=addressed`
    restores the old filter (`command_received` for addressed lines only).
  - The brain (`run_live.LiveAgent`) keeps the last 20 lines / 5 min (his own included) as `chat` in the
    Controller context. `!ping` -> pong without a model. A named line -> the Controller (`command.addressed:
    true`, name and greeting stripped: "hello claude what are you wearing" -> "what are you wearing"). Any
    other line -> after 1.5 s of quiet (bursts merged; at most 4 lines wait) the Controller with
    `addressed: false` decides whether it is meant for him (a follow-up, an instruction while he is clearly
    the one addressed, a group question he can help with) and stays silent if not. Capped at
    `DW_CHAT_CALLS_PER_MIN` (20) such calls a minute (`DW_CHAT_DEBOUNCE_S` 1.5). Every line gets a
    `chat_decision` log record (`ping` / `addressed` / `pending` / `merged` / `ignored`, with the reason).
- **Chat (legacy wording below):**
  - The client tails `client_io/events/chat.jsonl`, written by `chat.lua`'s `Client_ReceiveChatMessage` hook.
  - It forwards a line as `command_received{player, text}` only when the line is addressed to the companion: `!ping`, or the `brain/run_live.py` prefixes (`DW_CHAT_PREFIXES`). `DW_CLIENT_CHAT_ALL=1` forwards every line.
  - `player` is the sender's **character name** (on Luis's Shockbyte world he is `Zezima`). It is passed through to `follow`/`go_to` unchanged.
  - Claude's own lines (`self: true`) are never forwarded.
  - The client empties the events file once it has consumed more than 1 MB.
- **Tools that differ from the server body:**

| Tool | Client behaviour |
|---|---|
| `say` | Typed into the real chat box (`chat.lua`). The reply waits up to 4 s for the server's echo of the line. Echo seen: `data.verified: true`. No echo in time: still `ok`, with `verified: false`. Never pre-empts an action. |
| `follow` | Sync `ok {following, distance}`, then holds the action slot. If the movement ends by itself (pawn lost, stopped elsewhere), it emits `task_failed` with no second reply. |
| `go_to` | Async. `target` is `[x,y,z]` metres or a player name. It replies when `move.status()` says the move ended. Arrival is re-checked against a fresh position, within `arrive_tolerance` (3 m) × 1.5. Otherwise it answers `verification_failed`. A coordinate target includes `target_position`. A player target has `target` and `dist_m`. Body cap 110 s. |
| `drop` | The inventory UI's drop (`at` = `feet` only; anything else answers `not_implemented`). The server confirms asynchronously, so the reply waits up to 5 s for the carried count to fall by `count`. It then answers `ok {item: <resolved id>, count, at, inventory_left}`, or else `verification_failed`. |
| `get_state` | Built from `sense.me` + `sense.census` + `inventory.list`. **`inventory` = hotbar + bag** (loadout excluded; an item equipped from the hotbar keeps its hotbar slot in the game, so it shows in both `inventory` and `gear`). `gear` = `{loadout slot: item}` plus `held_right` / `held_left`. Extras: `skills`, `total_level`, `stamina`, `players_online`, `body: "client"`; survival as flat numbers `hydration`, `sustenance`, `endurance` (+ `<stat>_max`); `held` (display name) and `held_item`; `interactables` (census rows with `prompt`) next to `nearby_resources` (rows keep `health`, `tool`, `tool_tier`, `drops`, `stump`). The brain's situation digest shows these (`You: HP 100%, water 49%, food 64%, holding ...`, hostiles first with HP, `Around: ... chop, needs Hatchet T1, HP 80/80`, `Usable: ...`). Answers `companion_down` while there is no pawn (menu, loading). |
| `look` | `{about?, radius=20 (cap 80), max=15 (cap 40)}`, built on `sense.census`. Every category is flattened into `things`: players, creatures, world items, resources, interactables (stations, chests, beds, graves, NPCs). Each thing is a census row plus `category, kind, verb, actions` (what the client can do now: `interact` for world items, ground gatherables and interactables; `chop`/`mine` for gated destructibles; `attack` for creatures). Ranked by `match` (a port of the server's `match_score`), then distance. `data.matched` is a boolean when `about` is set. About 200 ms live. **Standing trees are foliage instances, not actors, so they are not seen yet** (felled logs, stumps, rocks and saplings are). |
| `inventory` | `{raw?}`, read-only (a brain READ tool, like look). Compact: `{worn: {slot: name}, held: {right, left}, hotbar: [{slot, name, item, count, durability_pct, use?}], bag: [...], weight, empty_slots}`; `raw: true` gives `inventory.list` as is. |
| `attack` | From `combat.lua`'s `HANDLERS` (combat/arbiter agent): async, `{target, force?}`, results `{target, target_id, killed, hits, presses, looted}` or `unsafe` (`data.why`: too_strong / boss / outnumbered / low_hp / never attack players), `unknown_target`, `too_far`, `interrupted`, `timeout`. `stop` also ends a commanded fight; the self-defence reflex (`combat.guard_start`, a supervised service, `DW_COMBAT_REFLEX=0` turns it off) keeps running. While the reflex owns the pawn (`arbiter.owner().level == "reflex"`), `follow` / `go_to` / `interact` wait instead of failing. `get_state.fight` = the current fight (mode, phase, target, target_hp, weapon). |
| `inspect` | `{target}` (an id from look): the thing, plus `gives`, `requires {tool, tier}`, `description` when the actor has one, and `contents [{name, item, count}]` for containers (graves, chests). Read-only. |
| `interact` | `{target, secondary=false}`. Async, like a player pressing E. If the target is further than 2 m, walk to within 1 m (`move.go_to`). Then aim the camera at it (`SetControlRotation`, as move.lua steers), wait up to 2 s until the game's own detector (`inventory.interact_target`) targets that actor, and press IA_Interact once (`inventory.press_interact`). **Verified** within 4 s by the target disappearing or the inventory growing: `ok {target, item, count, gained {item: n}, target_gone, prompt}`. Reasons: `unknown_target`, `not_interactable` (a creature or player, or the detector targets something else: `detail` names it), `too_far`, `path_blocked`, `verification_failed` (pressed, nothing changed: e.g. a station whose use is a UI), `timeout` (100 s). `secondary` is `not_implemented`. A grave's "Take All" is one press: every item comes back and the grave disappears. |
| debug (not planner tools) | `bridge_status` (stats, modules, action, and `services`: chat / vitals / fed_reflex, `running` / `starting` / `missing`), `me`, `census`, `inventory`, `move_status`, `equip {item}`, `unequip {slot}` |

## Messages

Every message has `"v": 1` and a `"type"`.

### `cmd` (brain to body)

```json
{"v":1,"type":"cmd","id":"3f9c0a1b2d4e","tool":"gather","args":{"resource":"log","count":5},"ts":1767225600.123}
```

- `id`: an opaque string, unique per request. The reply must echo it.
- `tool`: one of `get_state, follow, stop, go_to, attack, gather, craft, place, give, pickup,
  drop, say, ping, capabilities`. `args` follow the schemas in `brain/interface.py` (`TOOLS`).
  See [Item tools](#item-tools-pickup-drop-give) for the inventory skills.
- `ping` takes no args and must answer immediately with `data: {"pong": true}`. It is used for
  the Phase 5 latency gate.
- `capabilities` takes no args; see [Capabilities](#capabilities-protocol-v1-addition) below.
- `probe` (optional, boolean): `true` means the brain only wants to know whether the tool is
  implemented. See below.

### Capabilities (protocol v1 addition)

The brain builds the Planner's skill registry from what the body says it can do
(CLAUDE.md principle 3), once at startup (`brain/capabilities.py`, `brain/run_live.py`).

```json
{"v":1,"type":"cmd","id":"a1b2c3d4e5f6","tool":"capabilities","args":{},"ts":1767225600.1}
{"v":1,"type":"result","id":"a1b2c3d4e5f6","ok":true,"reason":null,"data":{"tools":["ping","capabilities","get_state","say","follow","stop"]}}
```

- Answer immediately with `ok: true` and `data.tools`, a list of tool names that have a **real**
  handler. Leave out tools whose handler is a stub that answers `not_implemented`.
- `get_state` counts as implemented once it returns `ok: true`, even if `data.not_implemented`
  still lists some missing keys.
- Names that are not protocol tools (for example `debug_run`) are allowed. The brain ignores them.
- The brain only lets the Planner use `go_to, follow, stop, attack, gather, craft, give, place,
  pickup, drop` (`state_store.MOCK_SKILLS`) from the list. It warns at startup if `say` or `get_state` are missing: without `say` the
  companion cannot reply, and without `get_state` no action can be verified, so the executor
  refuses to act (`reason: state_unavailable`).
- Restart the brain after deploying a body with new skills. The list is read once per session.

**Fallback for bodies without `capabilities`.** A body that answers `unknown_tool` (or anything
other than an ok result with a `tools` list) is probed instead. The brain sends each body tool
once, with `args: {}` and `"probe": true`. Any reply other than `not_implemented`,
`unknown_tool` or a timeout (3 s) counts as implemented. So:

- A body **may** honour `probe: true` by replying `ok: true` without acting.
- A body that ignores `probe` must reject empty args with `invalid_args` rather than acting on
  defaults. `stop` and `get_state` take no args, so a probe really runs them once; both are
  harmless.

### Spells and reflex rules (protocol v1 addition)

Body: `mod/body/spells.lua` and `mod/body/rules.lua`, registered in `main.lua`. All of them honour
`probe: true` and answer `invalid_args` on missing required args.

| Tool | Args | Success `data` |
|---|---|---|
| `cast` | `spell` (name, alias or asset id), `target?` (`"self"`/absent, an entity id, or `[x,y,z]` m) | `{spell, route, cooldown_s, paid, ...}` |
| `spells` | `compact?` (only spells the bot could cast: castable, or blocked by a cooldown or runes) | `{spells: [{id, name, role, use_when, castable, reason, remaining_s}], config, reflexes}` |
| `spell_tactics` | reflex knobs, e.g. `{shield: false, stomp_min: 4}` | `{tactics}` |
| `set_reflex_rule` | `enemy` (kind or `"*"`), `trigger {kind, value?, attack?, spell?, near_m?}`, `actions [{kind, spell?, target?, item?, distance_m?, duration_s?}]` (1-3), `cooldown_s?`, `note?` | `{rule (read back from the store), replaced, persisted, warnings, count}` |
| `list_rules` | `enemy?` | `{rules, sensable, actions}` |
| `clear_rule` | `id` \| `enemy` \| `all: true` | `{removed, persisted, count}` |

- Trigger kinds (only what the body can sense): `telegraph`, `enemy_hp_below`, `cluster_at_least`,
  `own_hp_below`, `luis_hp_below`, `enemy_stunned`, `spell_ready`. Anything else answers
  `reason: cant_sense`. Action kinds: `cast`, `evade`, `switch_weapon`, `retreat`, `focus_target`;
  anything else answers `not_implemented`.
- A rule with the same enemy and trigger replaces the old one (same id). Rules persist per enemy
  kind in the bot state file (section `reflex_rules`). They run inside the attack skill's combat loop.
- `warnings` lists parts the body cannot do yet (for example a spell whose route is not verified in
  game, or one Luis has not unlocked). The rule is stored anyway and starts working when that changes.
- New reasons: `on_cooldown` (transient; `data.remaining_s`; the executor waits up to 5 s, then
  retries), `not_unlocked` (deterministic: the bot mirrors Luis's unlocks), `unsafe` (deterministic:
  an area spell would land within about 10 m of a player), `cant_sense` (deterministic).
- Casting routes that are not verified in game (catalog `routes[r].verified`) answer
  `not_implemented` unless the server runs with `DW_SPELLS_UNVERIFIED=1`.

### Sleep (protocol v1 addition)

| Tool | Args | Success `data` |
|---|---|---|
| `sleep` | `target?` (`nearest` or a bed id), `mode?` (`auto` \| `bed` \| `shelter`) | `{mode, bed?, shelter?, sleeping: true, resting_area, can_sleep}`; async when the bot walks to a bed |
| `wake` | none | `{was, sleeping: false, shelter_removed}` |
| `sleep_status` | none | `{night, luis_sleeping, bot_sleeping, how, shelter, beds, reflex}` |

- `auto` uses a free bed, and otherwise spawns a Summon Shelter next to the bot and sleeps in it directly. This is the route verified to pass the night.
- The bot never uses a bed claimed by someone else, or someone else's shelter. `mode=bed` with no free bed answers `nothing_in_range`.
- `get_state` gains `sleeping` and `luis_sleeping`.

### `result` (body to brain)

```json
{"v":1,"type":"result","id":"3f9c0a1b2d4e","ok":false,"reason":"nothing_in_range","data":{"resource":"log"}}
```

- Exactly one `result` per `cmd`. It is sent when the action **finishes** (succeeded,
  failed or was interrupted), not when it starts.
- `reason` is `null` on success. Otherwise it is a reason code; see `Reason` in
  `brain/interface.py`. The executor uses some codes to choose between retrying,
  replanning and handling an interrupt:
  - Transient (retried): `path_blocked`, `timeout`, `body_error` (a body handler crashed), or any
    unknown code.
  - Deterministic (replanned at once): `nothing_in_range`, `not_enough_resources`,
    `missing_materials`, `unknown_target`, `unknown_recipe`, `too_far`, `invalid_args`,
    `unknown_tool`, `not_implemented`, `companion_down`, `not_in_inventory`.
  - Interrupts (handled without using a retry): `interrupted` (a player command pre-empted the
    action) and `attacked` (`data.by` = attacker entity id).
- The `data` for `get_state` must include `position` `[x,y,z]`, `health`, `inventory`
  `{item: count}`, `following` (player name or null), `players`
  `[{name, position, distance}]`, `nearby_entities`
  `[{id, kind, position, hp, hostile, alive, distance}]`, `nearby_resources`
  `[{id, resource, position, remaining, distance}]`, `structures` `[{id, blueprint, position}]`
  and `places` `[name]`.
  - `inventory` is what the companion **carries and can use**: `{item_id: count}`, where the real
    body's item ids are asset names (`ITEM_Resources_Wood_Oak`, `ITEM_Rune_Air`). Equipped items
    are not in it (they are in `gear`), like a player's loadout is not their bag.
  - Optional, filled by the real body (`mod/body/item_skills.lua`) and the mock:
    `inventory_items` `[{id, item, count, level?, ascension?, enchant?, durability?, equipped?}]`
    (item instances, equipped ones included) and `nearby_items`
    `[{id, item, name, count, position, distance, collecting}]` (world items on the ground within
    30 m; `collecting` is the player whose magnet is already pulling it, else null).
- `go_to` success data should include `target_position` (and optionally `arrive_tolerance`),
  so that the brain can verify arrival against a fresh `get_state`. `place` success should
  include `structure_id`.

### Item tools: pickup, drop, give

The bot has its own persistent inventory (`mod/body/inventory.lua`, saved in the bot state file):
it equips only what it owns, and items enter it only by pickup (later: being given, crafting).

| Tool | Args | Success `data` | Failure reasons |
|---|---|---|---|
| `pickup` | `target` (a `nearby_items` id, or `"nearest"`), `item?` (filter: part of the id or name, e.g. `"oak"`), `limit=1` (1–20 world items) | `{item, count, picked: [{world_item, item, count}], inventory}` | `unknown_target`, `nothing_in_range`, `path_blocked`, `timeout`, `verification_failed`, `invalid_args` |
| `drop` | `item` (an inventory id, a path, or a loose name such as `"oak logs"`), `count`, `at="feet"\|"luis"` | `{item, count, at, world_items: [ids], position, inventory_left, instance_state_lost?}` | `not_in_inventory`, `not_enough_resources`, `too_far` (Luis not within 5 m), `invalid_args`, `body_error`, `verification_failed` |
| `give` | `player`, `item`, `count` | drop's data plus `player` | as drop, plus `unknown_target`, `path_blocked`, `timeout` |

- `pickup` and `give` are async (they walk); `drop` answers at once and does not interrupt the
  current action (e.g. follow).
- `data.item` is the **resolved item id** (`"oak"` → `ITEM_Resources_Wood_Oak`). The executor
  verifies against that key: `pickup` = the inventory grew by `count` and the picked world items
  are gone from `nearby_items`; `drop` = the inventory shrank by `count` and every `world_items`
  id is in `nearby_items`; `give` = the inventory shrank by `count`.
- A drop spawns one world item per max stack (`MaxStackSize`, e.g. 99 logs), at most 10 per call.
- Instance state (upgrade level, enchant, durability) does not survive a drop yet: the game
  builds a fresh item (`instance_state_lost: true` is reported).
- Debug only (not protocol tools; the brain never sends them): `inventory {}` lists the store,
  `inventory_grant {item_path, count}` adds items, and `equip {item_path, debug_unowned: true}`
  bypasses the ownership rule (without it, equip answers `not_in_inventory`).

### Gather

| Tool | Args | Success `data` | Failure reasons |
|---|---|---|---|
| `gather` | `resource` (profile key, alias, drop item id or path: `"oak"`, `"log"`, `"stone"`, `"ITEM_Resources_Wood_Oak"`), `count` (how many MORE to collect), `radius?` (metres, default 30, widens x1.5 up to 120), `bonus?` (false skips bonus stages such as the stump) | `{resource, item, gathered, want, total, sites, swings, native_hits, emulated_hits, picked, seconds, radius_m}` | `nothing_in_range`, `wrong_tool` (`data.detail` = `no_tool`/`wrong_category`/`tier_too_low`, `need_category`, `need_tier`), `path_blocked`, `inventory_full`, `interrupted`, `timeout`, `unknown_target` (unknown resource; `data.known` lists them), `invalid_args`, `not_implemented` (no inventory service) |

- Async. While it runs the body emits `gather_progress{task_id, resource, item, have, want}` (at
  most every 2 s, and when the goal is reached), then `task_done` / `task_failed`.
- `data.item` is the resolved inventory key; the executor verifies the gain on that key (also on
  failures, so a retry asks only for the remainder). Profiles: `mod/body/resource_profiles.lua`.
- The body caps itself at 90 s + 20 s per unit (max 1700 s); the brain waits 1800 s.

### Travel: lodestones, regions, where (protocol v1 addition)

| Tool | Args | Success `data` | Failure reasons |
|---|---|---|---|
| `travel` | `to`: a lodestone (`id` = 32-hex registry GUID, or its name such as `"Temple Woods Lodestone"`), a map region name (`"Bramblemead Valley"`), or `[x,y,z]` metres; `teleport?` = `auto` (default) \| `never` \| `require` | `{to, kind: lodestone\|region\|coords, teleported, lodestone, lodestone_name, region, position, saved_m, cost, nav_ok?, already_there?}` | `not_unlocked` (Luis can't use that lodestone yet), `no_lodestone` (unknown lodestone, or `teleport=require` with no usable one), `too_far` (`data.detail = destination_unloaded`: the area isn't streamed in on the server), `path_blocked`, `timeout`, `verification_failed` (teleport didn't land, or the bot fell and was rolled back), `not_enough_resources` (`DW_TRAVEL_COST=budget` and too few law runes), `unknown_target` (`data.regions`, `data.lodestones` list the names), `invalid_args`, `companion_down`, `interrupted` |
| `where` | `position?` (`[x,y,z]` m; default the bot, else Luis) | `{position, region, region_id, parent_region, power_level, loaded, nearest_lodestone: {id, name, distance, unlocked_by_luis}}` | `invalid_args` |
| `lodestones` | none | `{lodestones: [{id, name, region, region_id, position, arrival, unlocked_by_luis, loaded, distance}], unlock_mode, cost_mode}` | |

- `travel` is async. It teleports **the bot only** (never a player) to the unlocked, loaded lodestone
  that saves the most walking (at least 150 m), checks after 1 s that it is standing there (and
  rolls back on a fall), then walks to the target. A region counts as reached once the bot is inside its
  polygon, and coordinates once it is within 2 m (Z ±2.5 m).
  - The body caps itself at 280 s, so the brain should wait 300 s.
  - Name resolution order: exact lodestone, exact region, then partial matches. So `"Temple Woods"`
    means the region, and `"Temple Woods Lodestone"` means the lodestone.
- `unlocked_by_luis` mirrors the game's own rule: `CanTeleport(from, to)` on Luis's lodestone
  component, true when some other registered lodestone can reach it. Lodestones are world objects
  (mostly player-built), so a world with a single lodestone has none unlocked.
  `DW_TRAVEL_UNLOCK=registry` counts every registered lodestone as unlocked.
- `where` is what `remember_place` stores: a region name from game data, plus the nearest lodestone.
- The server streams the world only around players, so teleports far from every player answer
  `too_far` / `destination_unloaded` for now.
- `reason` codes new to `interface.Reason`: `no_lodestone`. Also used: `not_unlocked`, `too_far` and
  `not_enough_resources` (all existing).

### Perception and interaction: what the brain expects (protocol v1 addition)

The Controller is a bounded look-then-act loop (`brain/controller.py`; research 2026-10-25 sections
3.2 and 6). It offers `look`/`inspect`/`interact` to the model **only when the body lists them in
`capabilities`**. Without them it works from the `get_state` situation digest alone and says
"I can't see any X" for anything not in it.

| Tool | Args (brain sends) | Success `data` (brain reads) | Notes |
|---|---|---|---|
| `look` (body: `gather.lua` `h_look`) | `about?` (the player's words), `radius` (m, default 20, max 80), `max` (default 15) | `{origin, radius_m, about, total, things: [{id, name, kind, verb, distance, count?, item?, drops?, prompt?, class, match?}]}` | Read-only and sync. Things are ranked by `match` (0 = no match) when `about` is set. The brain treats "no thing with `match > 0`" as `matched: false` (an explicit boolean `matched` also works). |
| `inspect` | `target` (an id from look) | one thing, as in look, plus anything descriptive (`description`, `gives`, `actions`) | Read-only. Optional. |
| `interact` | `target` (an id from look), `secondary=false` | `{target, item?, count?, prompt?}`; `item` = the inventory id granted | Async (walks). The executor verifies `item` gained `count` in `inventory`. A grant-less interaction is verified by the body. Reasons: `unknown_target`, `not_interactable`, `too_far`, `path_blocked`, `timeout`, `verification_failed`. |
| `world_info` (probe, not a planner tool) | none | `{world_guid, name?}` | The save's `WorldSaveGuid`, for per-world memory. Optional: `get_state.world_guid` (or `world.guid`) works too; else the brain uses `DW_WORLD_GUID` or `default`. |

- `get_state.nearby_resources` rows from the body (`{id, name, kind, verb, distance, count, hp}`) are
  shown to the model as the "Around" line of the situation. A future `surroundings` key
  (`[{name, kind, count, nearest_m, gives}]`) is also understood.
- **Grounding is enforced in the brain:** `pickup`, `interact` and `attack` are refused before they reach
  the body when their target is not among the perceived things (state, digest or a look this turn), or
  when it is not what the player named ("sticks" vs a perceived "Oak Logs"). The refusal reason is
  `not_perceived` (brain-side only).
- **Progress while an action runs:** the brain speaks a progress line (at most every ~20 s) as soon as a
  `gather_progress` or `task_progress` event arrives, *while the action's own `result` is still pending*.
  So the body must accept a `say` cmd during an async action (it does: actions are ticked, not blocking).

### Crafting (`mod/body/crafting.lua`, read-only; no emulated craft)

Luis's decision (2026-10-25, `docs/design/real-player-remediation.md`): Claude uses the real player
code paths only. The body therefore **never crafts by itself** (no consuming inputs or granting
outputs in Lua). The protocol tool **`craft` answers `not_implemented`** until the real-client body
drives the game's own crafting path (`Server_CraftRecipe` at a crafting station; loading the station
plus `Server_ToggleProcessing` at a furnace/kiln; see DISCOVERIES "Crafting: the real player path").

What exists now is route-independent knowledge from live game data (`data/recipes_<build>.json`,
generated by `tools/build_recipes.py`):

| Tool | Args | Success `data` | Failure reasons |
|---|---|---|---|
| `craft_check` | `recipe` (id, e.g. `"RECIPE_Process_IronBar"`) **or** `item` (output id or name, e.g. `"Iron Bar"`); `count` (default 1; with `recipe` = crafts, with `item` = items wanted, crafts = ceil(count / output per craft)); `fuel?` | `{plan: {recipe, crafts, kind: crafting\|processing, inputs: [{item, count}], outputs, seconds, seconds_model, fuel: [{item, count}] \| null, station: {station, name, id, kind, position, distance, max}}}` | `missing_input` (`item, have, need, missing: [{item, name, have, need, fuel?}]`), `wrong_station` (`need: [{station, name}]`, `near: [...]`), `not_unlocked` (`recipe`, or `detail: "vendor_reputation", tag, need, have`), `too_far` (`station, name, distance, max, position` in metres), `unknown_target`, `invalid_args`, `state_unavailable`, `companion_down` |
| `recipes` | `item` or `station` (id or display name), `limit=10` | `{recipes: [{recipe, inputs, outputs, stations, unlocked}], total}` | `invalid_args` |
| `stations` | `radius=30` (m) | `{stations: [{station, name, id, kind, position, distance, max, in_reach}]}` | `invalid_args`, `companion_down` |

- All three are sync and read-only. `craft_check` answers "could Claude craft this here, now?": inputs
  (counted in the bot's current inventory), a live station of the recipe's exact type within
  interaction range, and the recipe in Luis's live unlock list. Refusals carry
  `checks: {unlocked, inputs, station}`; with several recipes for an `item`, the closest refusal plus
  `alternatives: [{recipe, reason}]`.
- `plan.seconds` and the fuel count are models (UNVERIFIED) until `tools/craft_drift.py` measures a
  real craft.
- The recipe-graph planner (brain side) should read `data/recipes_<build>.json` directly; `recipes`
  is for quick chat answers ("what do I need for X?").
- Debug env: `DW_CRAFT_UNLOCKS=all` skips the unlock mirror, `DW_CRAFT_FUEL=off` skips fuel.

### `event` (body to brain, unsolicited)

```json
{"v":1,"type":"event","event":{"type":"command_received","player":"Luis","text":"follow me"}}
{"v":1,"type":"event","event":{"type":"attacked","by":"wolf_2"}}
```

The `event` object types (`brain/interface.py`) are:

- `command_received{player,text}`
- `task_done{task_id,data}`
- `task_failed{task_id,reason}`
- `attacked{by}`
- `player_nearby_activity{player,activity}`
- `gather_progress{task_id,resource,item,have,want}`
- `task_progress{task_id?,text?,have?,want?}`: milestones of any long skill (`text` is a short label,
  e.g. `"Smelting"`); optional
- `attacked{by, name?, amount?, hp?}`: the client body sends it for a `damage` row of the vitals watcher
  (`client_io/events/vitals.jsonl`) whose instigator is not Claude, at most once per 5 s per attacker. A
  brain whose registry has no `attack` says a help line instead of running the reflex attack.
- `chat_heard{from, text, ts?, mentions_me?}` (client body): every chat line from another player; see
  "Client endpoint".
- `unreachable{reason, detail?, leader_pos?, my_pos?, mode?}` (client body, from move.lua's
  `client_io/events/move.jsonl`, once per episode): reasons `leader_windstepped`, `leader_double_jumped`,
  `leader_above_jump_height`, `no_route`, `stuck` (`detail` "unstuck requested"). The brain says one line for
  that exact reason (`agent.UNREACHABLE_LINES`; an unknown reason quotes `detail`), at most once a minute per
  reason. `resumed{}` ("reachable_again"): "Found you." only if it complained in the last 5 min.
- `vitals_low{stat, value, max?, has_food?, has_drink?}` (client body): hydration or sustenance below 15
  and nothing in the inventory to fix it (the stay-fed reflex covers the rest). Checked every 15 s from
  `sense.me`, repeated every 180 s while it stays low, re-armed above 25. The brain asks the player for
  food or drink (at most once a minute per stat).

When an action is interrupted, the body sends the event that caused the interrupt
**before** the `result` with `reason: interrupted` or `attacked`.

### `error` (body to brain)

```json
{"v":1,"type":"error","id":null,"reason":"malformed","detail":"expected type=cmd with string id and tool"}
```

If `id` matches a pending request, the brain treats the error as a failed result. If `id` is
null, the brain only logs it.

## Timeouts

The brain gives up on a request after a per-tool timeout and returns `reason: timeout`.
Defaults are 10 s, with gather 1800 s, travel 300 s, go_to, pickup and interact 120 s, give 70 s, craft, attack and
place 60 s, and look 15 s (see
`DEFAULT_TIMEOUTS` in `bridge_client.py`). If a `result` arrives late, the brain logs it as
unmatched and discards it.

## Testing without the game

`python -m brain.fake_body [bridge_dir]` serves the protocol using the mock game.
`tests/test_bridge.py` runs the round trip.
`python -m brain.run_live --dry-run` runs the whole live loop (chat routing, `!ping`, capabilities,
Controller, executor) with rule-based fake models; `tests/test_run_live.py` runs it against the
fake body.
