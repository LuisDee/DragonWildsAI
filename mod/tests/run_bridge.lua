-- Serve the real bridge.lua against a bridge dir with stubbed UE4SS globals, for
-- integration tests with the Python BridgeClient (tests/test_lua_bridge.py).
-- Usage: lua run_bridge.lua <bridge_dir> [max_seconds]
-- Prints "ready" once polling, emits one command_received event, then polls every
-- 20 ms until max_seconds pass or <bridge_dir>/stop.flag appears.
local H = dofile(((debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or ".") .. "/bridge_harness.lua")
local bridge = require("bridge")

local dir = assert(arg[1], "usage: lua run_bridge.lua <bridge_dir> [max_seconds]")
local deadline = os.time() + (tonumber(arg[2]) or 30)
local stop_flag = dir .. "/stop.flag"

assert(bridge.start(H.log, { dir = dir, poll_ms = 20 }))
bridge.emit_event("command_received", { player = "Luis", text = "!ping" })
print("ready")
io.stdout:flush()

while os.time() < deadline do
    H.tick()
    local f = io.open(stop_flag, "rb")
    if f then f:close() break end
    H.sleep(0.02)
end
bridge.stop()
print(string.format("stopped received=%d malformed=%d sent=%d", bridge.stats.received, bridge.stats.malformed, bridge.stats.sent))
