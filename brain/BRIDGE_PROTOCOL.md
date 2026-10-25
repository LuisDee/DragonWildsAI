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
Defaults are 10 s, with gather 1800 s, go_to and pickup 120 s, give 70 s, and craft, attack and
place 60 s (see
`DEFAULT_TIMEOUTS` in `bridge_client.py`). If a `result` arrives late, the brain logs it as
unmatched and discards it.

## Testing without the game

`python -m brain.fake_body [bridge_dir]` serves the protocol using the mock game.
`tests/test_bridge.py` runs the round trip.
`python -m brain.run_live --dry-run` runs the whole live loop (chat routing, `!ping`, capabilities,
Controller, executor) with rule-based fake models; `tests/test_run_live.py` runs it against the
fake body.
