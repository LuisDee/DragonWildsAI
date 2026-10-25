-- Serve the real client_bridge.lua (with the fake client modules from fakes/) on <base>/bridge, for
-- integration tests with the Python brain (tests/test_client_bridge.py).
-- Usage: lua run_client_bridge.lua <base_dir> [max_seconds]
-- <base>/bridge: brain_to_client.jsonl / client_to_brain.jsonl; <base>/chat.jsonl: the chat events file
-- (the test appends player lines; the fake chat.say appends the server echo). Prints "ready" once
-- polling, then steps every 20 ms until max_seconds pass or <base>/stop.flag appears.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local REPO = here .. "/../.."
local H = dofile(REPO .. "/mod/tests/bridge_harness.lua")

local base = assert(arg[1], "usage: lua run_client_bridge.lua <base_dir> [max_seconds]")
local deadline = os.time() + (tonumber(arg[2]) or 30)
local function mkdir(p)
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. p .. '"') end
end
local scripts, chat = base .. "/scripts", base .. "/chat.jsonl"
mkdir(scripts)
for _, n in ipairs({ "chat", "move", "sense", "inventory" }) do
    local src = assert(io.open(here .. "/fakes/" .. n .. ".lua", "rb"))
    local dst = assert(io.open(scripts .. "/" .. n .. ".lua", "wb"))
    dst:write(src:read("a"))
    src:close(); dst:close()
end
local touch = assert(io.open(chat, "ab")); touch:close()
_G.FAKE = { chat_path = chat, auto_arrive = true }

local B = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
B.start({ root = REPO, dir = base .. "/bridge", scripts = scripts, chat_events = chat, vitals_events = base .. "/vitals.jsonl", jlog = H.log, poll_ms = 20,
          start_modules = true })
print("ready")
io.stdout:flush()

while os.time() < deadline do
    H.tick()
    local f = io.open(base .. "/stop.flag", "rb")
    if f then f:close() break end
    H.sleep(0.02)
end
B.stop()
print("stopped")
