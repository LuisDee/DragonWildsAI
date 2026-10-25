-- Print the REAL client body's `capabilities` answer (tools + manifest + aliases) as JSON, by starting
-- the real client_bridge.lua over the REAL client_mod/scripts modules with the UE4SS globals stubbed
-- (mod/tests/bridge_harness.lua). Nothing touches a game: loading a module has no side effects, and no
-- service is started. Used by evals/manifest_eval.py (the real-model eval of the tool list).
-- Usage: lua dump_manifest.lua <empty_dir>  -> JSON on stdout
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local REPO = here .. "/../.."
local H = dofile(REPO .. "/mod/tests/bridge_harness.lua")
local json = require("dkjson")
local base = assert(arg[1], "usage: lua dump_manifest.lua <empty_dir>")
local B = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
B.start({ root = REPO, dir = base, scripts = REPO .. "/client_mod/scripts", chat_events = base .. "/chat.jsonl",
          vitals_events = base .. "/vitals.jsonl", move_events = base .. "/move.jsonl", gather_events = base .. "/gather.jsonl",
          activity_events = base .. "/activity.jsonl", jlog = H.log, no_loop = true, debug_channel = false })
local list, aliases, ver = B.manifest()
io.write(json.encode({ tools = B.implemented_tools(), manifest = list, aliases = aliases, manifest_version = ver, body = "client" }))
B.stop()
