-- Offline unit tests for mod/scripts/bridge.lua. Usage: lua test_bridge.lua <empty_dir>
-- (tests/test_lua_bridge.py runs this with a pytest tmp dir). Exits non-zero on failure.
local H = dofile(((debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or ".") .. "/bridge_harness.lua")
local json = require("dkjson")
local bridge = require("bridge")

local dir = arg[1] or os.getenv("DW_BRIDGE_DIR")
assert(dir, "usage: lua test_bridge.lua <bridge_dir>")
local IN = dir .. "/brain_to_body.jsonl"
local OUT = dir .. "/body_to_brain.jsonl"

local function write(path, s, mode)
    local f = assert(io.open(path, mode or "ab"))
    f:write(s)
    f:close()
end

local out_offset = 0
-- New body->brain lines since the last call: { {raw=, msg=}, ... }
local function drain()
    local f = io.open(OUT, "rb")
    if not f then return {} end
    f:seek("set", out_offset)
    local s = f:read("a")
    f:close()
    out_offset = out_offset + #s
    local out = {}
    for line in s:gmatch("([^\n]*)\n") do out[#out + 1] = { raw = line, msg = json.decode(line) } end
    return out
end

local function cmd(id, tool, args)
    return bridge.encode({ v = 1, type = "cmd", id = id, tool = tool, args = args or bridge.object() }) .. "\n"
end

local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end

-- ---------------------------------------------------------------------------------
test("stale lines before start are ignored", function()
    write(IN, cmd("stale1", "ping"))
    assert(bridge.start(H.log, { dir = dir, poll_ms = 100 }))
    local handle, loop = next(H.loops)
    assert(loop and loop.delay_ms == 100, "loop registered with delay")
    H.tick()
    assert(#drain() == 0, "stale command must not be answered")
    assert(bridge.paths().offset > 0)
    assert(handle)
end)

test("ping round trip echoes id with pong and server clock", function()
    write(IN, cmd("p1", "ping"))
    H.tick()
    local out = drain()
    assert(#out == 1, "one reply, got " .. #out)
    local m = out[1].msg
    assert(m.v == 1 and m.type == "result" and m.id == "p1" and m.ok == true)
    assert(m.data.pong == true and type(m.data.server_clock) == "number" and type(m.data.server_time) == "number")
    assert(out[1].raw:find('"reason":null', 1, true), "reason must be an explicit null: " .. out[1].raw)
end)

test("partial line waits for completion", function()
    local line = cmd("part", "ping")
    write(IN, line:sub(1, 20))
    H.tick()
    assert(#drain() == 0)
    write(IN, line:sub(21))
    H.tick()
    local out = drain()
    assert(#out == 1 and out[1].msg.id == "part")
end)

test("several lines in one chunk, CRLF and blank lines", function()
    write(IN, cmd("a", "ping"):sub(1, -2) .. "\r\n" .."\n   \n" .. cmd("b", "ping"))
    H.tick()
    local out = drain()
    assert(#out == 2 and out[1].msg.id == "a" and out[2].msg.id == "b")
end)

test("malformed lines get error with id null and the loop carries on", function()
    write(IN, "this is not json\n[1,2,3]\n{broken json\n\"str\"\n" .. cmd("after", "ping"))
    H.tick()
    local out = drain()
    assert(#out == 5, "4 errors + 1 result, got " .. #out)
    for i = 1, 4 do
        assert(out[i].msg.type == "error" and out[i].msg.reason == "malformed")
        assert(out[i].raw:find('"id":null', 1, true), out[i].raw)
    end
    assert(out[1].msg.detail == "this is not json")
    assert(out[5].msg.type == "result" and out[5].msg.id == "after")
end)

test("structurally invalid cmd objects", function()
    write(IN, '{"v":1,"type":"cmd","tool":"ping"}\n')                -- no id
    write(IN, '{"v":1,"type":"hello","id":"x1","tool":"ping"}\n')   -- wrong type, string id
    write(IN, '{"v":1,"type":"cmd","id":"x2","tool":7}\n')           -- tool not a string
    H.tick()
    local out = drain()
    assert(#out == 3)
    assert(out[1].raw:find('"id":null', 1, true))
    assert(out[2].msg.id == "x1" and out[2].msg.reason == "malformed")
    assert(out[3].msg.id == "x2" and out[3].msg.detail == "expected type=cmd with string id and tool")
end)

test("unimplemented protocol tools answer not_implemented; unknown tools unknown_tool", function()
    local tools = { "follow", "stop", "go_to", "attack", "gather", "craft", "place", "give", "say" }
    for i, t in ipairs(tools) do write(IN, cmd("n" .. i, t, { count = 1 })) end
    write(IN, cmd("u1", "fly"))
    H.tick()
    local out = drain()
    assert(#out == #tools + 1)
    for i, t in ipairs(tools) do
        local m = out[i].msg
        assert(m.id == "n" .. i and m.ok == false and m.reason == "not_implemented" and m.data.tool == t)
    end
    assert(out[#out].msg.reason == "unknown_tool" and out[#out].msg.data.tool == "fly")
end)

test("get_state stub has every protocol key and lists what is stubbed", function()
    write(IN, cmd("s1", "get_state"))
    H.tick()
    local o = drain()[1]
    assert(o.msg.ok == false and o.msg.reason == "not_implemented")
    for _, k in ipairs({ "position", "health", "following" }) do
        assert(o.raw:find('"' .. k .. '":null', 1, true), k .. " should be null")
    end
    assert(o.raw:find('"inventory":{}', 1, true), "inventory must encode as an object")
    for _, k in ipairs({ "players", "nearby_entities", "nearby_resources", "structures", "places" }) do
        assert(o.raw:find('"' .. k .. '":[]', 1, true), k .. " should be []")
    end
    assert(#o.msg.data.not_implemented == 9)
end)

test("empty data encodes as {}", function()
    bridge.handlers.noop = function() return { ok = true } end
    write(IN, cmd("e1", "noop"))
    H.tick()
    local o = drain()[1]
    assert(o.raw:find('"data":{}', 1, true) and o.raw:find('"reason":null', 1, true), o.raw)
    bridge.handlers.noop = nil
end)

test("handler errors become body_error results", function()
    bridge.handlers.boom = function() error("kaboom") end
    write(IN, cmd("b1", "boom"))
    H.tick()
    local m = drain()[1].msg
    assert(m.id == "b1" and m.ok == false and m.reason == "body_error" and m.data.detail:find("kaboom"))
    bridge.handlers.boom = nil
end)

test("async handler replies later via bridge.reply", function()
    local pending
    bridge.handlers.slow = function(args, ctx) pending = ctx.id end
    write(IN, cmd("w1", "slow"))
    H.tick()
    assert(#drain() == 0 and pending == "w1")
    bridge.emit_event("attacked", { by = "wolf_2" })
    bridge.reply(pending, { ok = false, reason = "attacked", data = { by = "wolf_2" } })
    local out = drain()
    assert(out[1].msg.type == "event" and out[1].msg.event.type == "attacked" and out[1].msg.event.by == "wolf_2")
    assert(out[2].msg.id == "w1" and out[2].msg.reason == "attacked")
    bridge.handlers.slow = nil
end)

test("emit_event is flat {type, ...data}", function()
    bridge.emit_event("command_received", { player = "Luis", text = "follow me" })
    local m = drain()[1].msg
    assert(m.v == 1 and m.type == "event")
    assert(m.event.type == "command_received" and m.event.player == "Luis" and m.event.text == "follow me")
end)

test("truncation resets the offset to 0", function()
    write(IN, "", "wb") -- brain truncated its file
    write(IN, cmd("t1", "ping"))
    H.tick()
    local out = drain()
    assert(#out == 1 and out[1].msg.id == "t1")
end)

test("stop cancels the loop", function()
    bridge.stop()
    assert(next(H.loops) == nil and #H.cancelled == 1)
end)

-- ---------------------------------------------------------------------------------
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    print((ok and "PASS " or "FAIL ") .. t[1] .. (ok and "" or ("\n     " .. tostring(err))))
    if not ok then failures = failures + 1 end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
