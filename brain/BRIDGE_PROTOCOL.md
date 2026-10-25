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
- `tool`: one of `get_state, follow, stop, go_to, attack, gather, craft, place, give, say,
  ping`. `args` follow the schemas in `brain/interface.py` (`TOOLS`).
- `ping` takes no args and must answer immediately with `data: {"pong": true}`. It is used for
  the Phase 5 latency gate.

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
    `unknown_tool`, `not_implemented`, `companion_down`.
  - Interrupts (handled without using a retry): `interrupted` (a player command pre-empted the
    action) and `attacked` (`data.by` = attacker entity id).
- The `data` for `get_state` must include `position` `[x,y,z]`, `health`, `inventory`
  `{item: count}`, `following` (player name or null), `players`
  `[{name, position, distance}]`, `nearby_entities`
  `[{id, kind, position, hp, hostile, alive, distance}]`, `nearby_resources`
  `[{id, resource, position, remaining, distance}]`, `structures` `[{id, blueprint, position}]`
  and `places` `[name]`.
- `go_to` success data should include `target_position` (and optionally `arrive_tolerance`),
  so that the brain can verify arrival against a fresh `get_state`. `place` success should
  include `structure_id`.

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
Defaults are 10 s, with gather 180 s, go_to 120 s, and craft, attack and place 60 s (see
`DEFAULT_TIMEOUTS` in `bridge_client.py`). If a `result` arrives late, the brain logs it as
unmatched and discards it.

## Testing without the game

`python -m brain.fake_body [bridge_dir]` serves the protocol using the mock game.
`tests/test_bridge.py` runs the round trip.
