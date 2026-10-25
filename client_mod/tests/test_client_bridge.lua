-- Offline unit tests for client_mod/scripts/client_bridge.lua (the client body's brain bridge).
-- Usage: lua test_client_bridge.lua <empty_dir>   (tests/test_client_bridge.py runs it with a pytest tmp dir)
-- Fake client modules (chat, move, sense, inventory) are written into <dir>/scripts and hot-loaded
-- exactly as the real ones are. UE4SS globals come from mod/tests/bridge_harness.lua.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local REPO = here .. "/../.."
local H = dofile(REPO .. "/mod/tests/bridge_harness.lua")
local json = require("dkjson")

local base = assert(arg[1], "usage: lua test_client_bridge.lua <empty_dir>")
local function mkdir(p)
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. p .. '"') end
end
local DIR, SCRIPTS = base .. "/bridge", base .. "/scripts"
local CHAT = base .. "/chat.jsonl"
mkdir(DIR); mkdir(SCRIPTS)
local IN, OUT = DIR .. "/brain_to_client.jsonl", DIR .. "/client_to_brain.jsonl"

local function write(path, s, mode)
    local f = assert(io.open(path, mode or "ab"))
    f:write(s)
    f:close()
end

-- ------------------------------------------------------------------ fake client modules
-- The fakes live in client_mod/tests/fakes/ (shared with run_client_bridge.lua).
local FAKES = {}
for _, n in ipairs({ "chat", "move", "sense", "inventory" }) do
    local fh = assert(io.open(here .. "/fakes/" .. n .. ".lua", "rb"))
    FAKES[n] = fh:read("a")
    fh:close()
end

local function install(name, text) write(SCRIPTS .. "/" .. name .. ".lua", text or FAKES[name], "wb") end
local function uninstall(name) os.remove(SCRIPTS .. "/" .. name .. ".lua") end

-- ------------------------------------------------------------------ wire helpers
local out_offset = 0
local function drain()
    local f = io.open(OUT, "rb")
    if not f then return {} end
    f:seek("set", out_offset)
    local s = f:read("a")
    f:close()
    out_offset = out_offset + #s
    local out = {}
    for line in s:gmatch("([^\n]*)\n") do out[#out + 1] = json.decode(line) end
    return out
end

local seq = 0
local B, T
local function step() B.step() end
local function send(tool, args, extra)
    seq = seq + 1
    local id = "c" .. seq
    local msg = { v = 1, type = "cmd", id = id, tool = tool, args = args or json.null }
    if args == nil then msg.args = setmetatable({}, { __jsontype = "object" }) end
    for k, v in pairs(extra or {}) do msg[k] = v end
    write(IN, json.encode(msg) .. "\n")
    return id
end
local function results(msgs, id)
    local r = {}
    for _, m in ipairs(msgs) do if m.type == "result" and (id == nil or m.id == id) then r[#r + 1] = m end end
    return r
end
local function events(msgs, kind)
    local r = {}
    for _, m in ipairs(msgs) do if m.type == "event" and (kind == nil or m.event.type == kind) then r[#r + 1] = m.event end end
    return r
end
-- send + one step, return the single result for that id (nil if none yet) and all messages
local function rpc(tool, args, extra)
    local id = send(tool, args, extra)
    step()
    local msgs = drain()
    return results(msgs, id)[1], msgs, id
end
local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end

local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end

-- ------------------------------------------------------------------ tests
test("start: stale brain lines and chat history are ignored; bare capabilities", function()
    write(IN, '{"v":1,"type":"cmd","id":"stale","tool":"ping","args":{}}\n')
    write(CHAT, '{"type":"chat","from":"Luis","text":"claude follow me","self":false}\n')
    B = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    B.RELOAD_CHECK_S = 0
    T = 1000
    B.clock = function() return T end
    local st = B.start({ root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = CHAT, vitals_events = base .. "/vitals.jsonl", move_events = base .. "/move.jsonl", jlog = H.log, no_loop = true,
                         start_modules = true })
    assert(st.dir == DIR:gsub("\\", "/"), "dir " .. tostring(st.dir))
    step()
    assert(#drain() == 0, "stale cmd or chat history must not produce output")
    local r = rpc("capabilities")
    assert(r.ok and r.data.body == "client")
    local tools = r.data.tools
    assert(#tools == 3 and has(tools, "ping") and has(tools, "capabilities") and has(tools, "bridge_status"),
           "only builtins without modules: " .. table.concat(tools, ","))
end)

test("ping answers pong with body=client", function()
    local r = rpc("ping")
    assert(r.ok and r.data.pong == true and r.data.body == "client" and r.reason == nil)
end)

test("missing modules: not_implemented; unknown tool: unknown_tool; get_state stub", function()
    assert(rpc("follow", { player = "Luis" }).reason == "not_implemented")
    assert(rpc("gather", { resource = "log", count = 1 }).reason == "not_implemented")
    assert(rpc("fly").reason == "unknown_tool")
    local s = rpc("get_state")
    assert(s.ok == false and s.reason == "not_implemented", tostring(s.reason))
    assert(has(s.data.not_implemented, "position") and s.data.body == "client")
    assert(rpc("get_state", nil, { probe = true }).reason == "not_implemented", "get_state probe without sense")
end)

test("modules appear while running: capabilities grow (hot load)", function()
    for _, n in ipairs({ "chat", "move", "sense", "inventory" }) do install(n) end
    local tools = rpc("capabilities").data.tools
    for _, t in ipairs({ "get_state", "say", "follow", "go_to", "stop", "drop", "inventory", "census", "me",
                         "move_status", "inv_debug" }) do
        assert(has(tools, t), "missing " .. t .. " in " .. table.concat(tools, ","))
    end
    assert(not has(tools, "equip"), "equip needs inventory.equip, which the fake lacks")
    assert(not has(tools, "gather") and not has(tools, "attack"), "no such module functions")
    for _, t in ipairs({ "look", "inspect", "interact" }) do assert(has(tools, t), "perception tool " .. t) end
end)

test("services: chat hooks, vitals watcher, stay-fed reflex started, retried until healthy, re-armed on reload", function()
    FAKE.hooks_fail = true -- at the main menu the hooked classes are not loaded yet
    B._supervise(true)
    local sv = B._state().services
    assert(sv.chat.state == "starting" and sv.vitals.state == "starting" and sv.fed_reflex.state == "running",
           json.encode(sv))
    FAKE.hooks_fail = nil
    T = T + B.SERVICE_CHECK_S
    step()
    sv = B._state().services
    assert(sv.chat.state == "running" and sv.vitals.state == "running", "retried once the world is up")
    assert(sv.chat.starts == 2 and sv.vitals.starts == 2 and sv.fed_reflex.starts == 1)
    T = T + B.SERVICE_CHECK_S
    step()
    assert(B._state().services.chat.starts == 2, "healthy services are not restarted")
    install("inventory", FAKES.inventory .. "\n-- edited\n")
    T = T + B.SERVICE_CHECK_S
    step()
    assert(B._state().services.fed_reflex.starts == 2, "re-armed after a hot reload")
    install("inventory")
    local st = rpc("bridge_status").data.services
    assert(st.chat.state == "running" and st.fed_reflex.state == "running", json.encode(st))
end)

test("unit and reason helpers", function()
    local m = B._to_m({ X = 150, Y = -250, Z = 1000 })
    assert(m[1] == 1.5 and m[2] == -2.5 and m[3] == 10, "cm -> m")
    assert(B._reason_code("no_pawn") == "companion_down" and B._reason_code("stuck") == "path_blocked")
    assert(B._reason_code("not in inventory: Oak") == "not_in_inventory" and B._reason_code("timeout") == "timeout")
    assert(B._reason_code("rate limited (4 lines in 10 s)") == "body_error")
    local n = B._norm({ ok = false, error = "no pawn" })
    assert(n.reason == "companion_down" and n.data.detail == "no pawn")
    n = B._norm({ ok = true, was = "follow" })
    assert(n.ok and n.data.was == "follow", "flat fields become data")
end)

test("get_state from the real module shapes: buckets, inventory, gear, extras", function()
    local r = rpc("get_state")
    assert(r.ok, tostring(r.reason))
    local d = r.data
    assert(d.position[1] == 1 and d.position[3] == 3 and d.health == 90 and d.max_health == 100 and d.name == "Claude")
    assert(d.total_level == 12 and d.skills[1].skill == "Woodcutting" and d.stamina == 50, "sense.me extras kept")
    assert(d.following == nil, "following is JSON null")
    assert(#d.players == 1 and d.players[1].name == "Luis" and d.players[1].distance == 2.8)
    assert(#d.nearby_entities == 2)
    local wolf, deer = d.nearby_entities[1], d.nearby_entities[2]
    assert(wolf.id == "wolf_2" and wolf.kind == "Wolf" and wolf.alive == false and wolf.hostile == true and wolf.hp == 0)
    assert(deer.alive == true and deer.hostile == false)
    assert(#d.nearby_resources == 2 and d.nearby_resources[1].id == "stick_1" and d.nearby_resources[2].id == "oak_1")
    assert(d.nearby_resources[2].tool == "Hatchet" and d.nearby_resources[2].health == 220, "HP and tool gate kept")
    assert(#d.interactables == 2 and d.interactables[1].id == "bench_1" and d.interactables[1].prompt == "Craft")
    assert(d.hydration == 70 and d.hydration_max == 100 and d.sustenance == 80 and d.endurance == 40, "flat vitals")
    assert(d.held == "Bronze Hatchet" and d.held_item == "ITEM_Tool_Axe_Bronze")
    assert(#d.nearby_items == 1 and d.nearby_items[1].collecting == nil)
    assert(d.inventory.ITEM_Resources_Wood_Oak == 8 and d.inventory.ITEM_Tool_Axe_Bronze == nil, json.encode(d.inventory))
    assert(#d.inventory_items == 3 and d.inventory_items[3].equipped == true and d.inventory_items[1].id == "QuickAction:0")
    assert(d.gear.HeldRight == "ITEM_Tool_Axe_Bronze" and d.gear.held_right == "ITEM_Tool_Axe_Bronze")
    assert(d.players_online[2] == "Luis")
    assert(has(d.not_implemented, "structures") and has(d.not_implemented, "places") and not has(d.not_implemented, "position"))
end)

test("get_state: controller but no pawn -> companion_down", function()
    FAKE.no_pawn = true
    local r = rpc("get_state")
    FAKE.no_pawn = nil
    assert(r.ok == false and r.reason == "companion_down", tostring(r.reason))
end)

test("probe never acts; invalid args never act", function()
    FAKE.move.calls = {}
    assert(rpc("follow", {}, { probe = true }).data.probe == true)
    assert(rpc("stop", {}, { probe = true }).data.probe == true)
    assert(rpc("drop", {}, { probe = true }).data.probe == true)
    assert(rpc("follow", {}).reason == "invalid_args")
    assert(rpc("go_to", {}).reason == "invalid_args")
    assert(rpc("say", {}).reason == "invalid_args")
    assert(rpc("drop", { item = "oak" }).reason == "invalid_args")
    assert(#FAKE.move.calls == 0 and FAKE.dropped == nil, "nothing acted: " .. table.concat(FAKE.move.calls, ","))
end)

test("follow: sync ok, held in the slot, get_state.following echoes the player", function()
    local r = rpc("follow", { player = "Luis", distance = 4 })
    assert(r.ok and r.data.following == "Luis" and r.data.distance == 4)
    assert(FAKE.move.calls[#FAKE.move.calls] == "follow:Luis")
    local s = rpc("get_state").data
    assert(s.following == "Luis" and s.action == "follow")
end)

test("follow ending on its own (move stopped elsewhere) emits task_failed, no second reply", function()
    local r, _, id = rpc("follow", { player = "Luis" })
    assert(r.ok)
    FAKE.move.mode, FAKE.move.result = "idle", { status = "failed", reason = "no_pawn" }
    step()
    local out = drain()
    assert(#results(out, id) == 0, "follow already answered")
    local tf = events(out, "task_failed")
    assert(#tf == 1 and tf[1].task_id == id and tf[1].reason == "companion_down", json.encode(tf))
    assert(rpc("get_state").data.following == nil)
end)

test("go_to pre-empts follow silently, replies when move.status says arrived (verified)", function()
    rpc("follow", { player = "Luis" })
    FAKE.move.calls = {}
    local first, msgs, id = rpc("go_to", { target = { 10, 0, 0 } })
    assert(first == nil, "async: no reply at start")
    assert(#events(msgs, "task_failed") == 0, "pre-empted follow ends silently")
    assert(FAKE.move.calls[1] == "stop" and FAKE.move.calls[2] == "go_to", table.concat(FAKE.move.calls, ","))
    step(); step()
    assert(#results(drain(), id) == 0, "still moving")
    FAKE.move.mode, FAKE.move.result, FAKE.move.position = "idle", { status = "arrived", dist_m = 1.4 }, { 9, 1, 0 }
    step()
    local out = drain()
    local r = results(out, id)[1]
    assert(r and r.ok, "arrived reply")
    assert(r.data.target_position[1] == 10 and r.data.position[1] == 9 and r.data.arrive_tolerance == 3 and r.data.dist_m == 1.4)
    local done = events(out, "task_done")
    assert(#done == 1 and done[1].task_id == id)
    assert(rpc("get_state").data.following == nil, "follow ended")
end)

test("go_to: arrival claim far from the target -> verification_failed", function()
    local _, _, id = rpc("go_to", { target = { 10, 0, 0 } })
    FAKE.move.mode, FAKE.move.result, FAKE.move.position = "idle", { status = "arrived" }, { 50, 0, 0 }
    step()
    local r = results(drain(), id)[1]
    assert(r and r.ok == false and r.reason == "verification_failed", r and r.reason)
end)

test("go_to a player: no target_position, module reasons mapped", function()
    local _, _, id = rpc("go_to", { target = "Luis" })
    FAKE.move.mode, FAKE.move.result = "idle", { status = "arrived", dist_m = 1.0 }
    step()
    local r = results(drain(), id)[1]
    assert(r.ok and r.data.target_position == nil and r.data.target == "Luis")
    for reason, want in pairs({ stuck = "path_blocked", target_not_visible = "unknown_target", timeout = "timeout",
                                error = "body_error" }) do
        _, _, id = rpc("go_to", { target = "Luis" })
        FAKE.move.mode, FAKE.move.result = "idle", { status = "failed", reason = reason }
        step()
        r = results(drain(), id)[1]
        assert(r.reason == want, reason .. " -> " .. tostring(r.reason))
    end
end)

test("go_to: a move stopped from elsewhere -> interrupted", function()
    local _, _, id = rpc("go_to", { target = "Luis" })
    FAKE.move.mode, FAKE.move.result = "idle", { status = "stopped" }
    step()
    assert(results(drain(), id)[1].reason == "interrupted")
end)

test("go_to: timeout stops the move", function()
    local _, _, id = rpc("go_to", { target = { 10, 0, 0 } })
    T = T + B.GOTO_TIMEOUT_S + 1
    step()
    assert(results(drain(), id)[1].reason == "timeout")
    assert(FAKE.move.mode == "idle", "timeout stops the move")
end)

test("stop interrupts go_to: interrupted reply + task_failed, stop says what it stopped", function()
    local _, _, gid = rpc("go_to", { target = { 10, 0, 0 } })
    local sid = send("stop")
    step()
    local out = drain()
    local g, s = results(out, gid)[1], results(out, sid)[1]
    assert(g and g.reason == "interrupted" and g.data.by == "stop")
    assert(s and s.ok and s.data.stopped == "go_to")
    local tf = events(out, "task_failed")
    assert(#tf == 1 and tf[1].task_id == gid and tf[1].reason == "interrupted")
    assert(rpc("stop").data.stopped == nil, "nothing to stop (JSON null)")
end)

test("say waits for the server echo (self line), FIFO; no echo -> ok verified=false", function()
    local _, _, id = rpc("say", { text = "hello Luis" })
    assert(FAKE.said[#FAKE.said] == "hello Luis")
    step()
    assert(#results(drain(), id) == 0, "waiting for echo")
    write(CHAT, json.encode({ type = "chat", from = "Claude", text = "hello Luis", self = true }) .. "\n")
    step()
    local out = drain()
    local r = results(out, id)[1]
    assert(r and r.ok and r.data.verified == true and r.data.echo_exact == true)
    assert(#events(out, "command_received") == 0, "own echo is never a command")
    _, _, id = rpc("say", { text = "anyone?" })
    T = T + B.SAY_ECHO_S
    step()
    r = results(drain(), id)[1]
    assert(r and r.ok and r.data.verified == false)
    FAKE.say_fail = true
    r = rpc("say", { text = "spam" })
    FAKE.say_fail = nil
    assert(r.ok == false and r.reason == "body_error" and r.data.detail:find("rate limited"), "free-text reason -> detail")
end)

test("say during an async action does not pre-empt it", function()
    local _, _, gid = rpc("go_to", { target = { 10, 0, 0 } })
    local _, _, sid = rpc("say", { text = "on my way" })
    write(CHAT, json.encode({ type = "chat", from = "Claude", text = "on my way", self = true }) .. "\n")
    step()
    local out = drain()
    assert(#results(out, gid) == 0, "go_to still running")
    assert(results(out, sid)[1].data.verified == true)
    assert(rpc("get_state").data.action == "go_to")
    rpc("stop")
end)

test("drop waits for the inventory to shrink; resolved item id; never-confirmed -> verification_failed", function()
    local r = rpc("drop", { item = "oak", count = 2 })
    assert(r and r.ok, "confirmed by the next list(): " .. tostring(r and r.reason))
    assert(r.data.item == "ITEM_Resources_Wood_Oak" and r.data.count == 2 and r.data.inventory_left == 6, json.encode(r.data))
    assert(FAKE.dropped[1] == "oak" and FAKE.dropped[2] == 2)
    assert(rpc("get_state").data.inventory.ITEM_Resources_Wood_Oak == 6)
    FAKE.drop_never = true
    local _, _, id = rpc("drop", { item = "oak", count = 1 })
    T = T + B.DROP_WAIT_S
    step()
    r = results(drain(), id)[1]
    FAKE.drop_never = nil
    assert(r and r.reason == "verification_failed", r and r.reason)
    assert(rpc("drop", { item = "stone", count = 1 }).reason == "not_in_inventory")
    assert(rpc("drop", { item = "oak", count = 1, at = "luis" }).reason == "not_implemented")
end)

test("look: every census category as things, ranked by match, matched flag, radius cap", function()
    FAKE.move.position = nil -- the go_to tests left him elsewhere
    local r = rpc("look", { about = "sticks" })
    assert(r.ok, tostring(r.reason))
    local d = r.data
    assert(d.radius_m == 20 and d.about == "sticks" and d.matched == true and d.total >= 6, json.encode(d))
    local first = d.things[1]
    assert(first.id == "stick_1" and first.match == 1 and first.kind == "gatherable" and first.actions[1] == "interact")
    assert(d.things[2].match == 0, "the rest do not match")
    local by = {}
    for _, t in ipairs(d.things) do by[t.id] = t end
    assert(by.wolf_2.category == "creatures" and by.wolf_2.alive == false and by.wolf_2.hostile == true and by.wolf_2.actions[1] == "attack")
    assert(by.oak_1.verb == "chop" and by.oak_1.actions[1] == "chop" and by.oak_1.tool_tier == 1)
    assert(by.bench_1.verb == "interact" and by.wi_1.actions[1] == "interact" and by["BP_PlayerCharacter_C_2"].kind == "player")
    assert(by.grave_1 == nil, "28 m away: outside the 20 m default")
    r = rpc("look", { about = "dragon", radius = 500, max = 3 })
    assert(r.data.radius_m == 80 and #r.data.things == 3 and r.data.matched == false and r.data.things[1].match == 0)
    assert(r.data.total >= 8, "the grave is inside 80 m")
    r = rpc("look", {})
    assert(r.ok and r.data.matched == nil and r.data.things[1].match == nil, "no about: no match scores")
    assert(B.match_score({ name = "Ash Branches" }, "branch") == 1 and B.match_score({ name = "Oak" }, "an oak tree") == 0.5)
end)

test("inspect: one thing with gives/requires, container contents; unknown id", function()
    local r = rpc("inspect", { target = "oak_1" })
    assert(r.ok and r.data.id == "oak_1" and r.data.requires.tool == "Hatchet" and r.data.gives[1] == "Oak Logs")
    r = rpc("inspect", { target = "grave_1" })
    assert(r.ok and r.data.contents and r.data.contents[1].item == "ITEM_Pickaxe_Mithril", json.encode(r.data))
    assert(rpc("inspect", { target = "nope" }).reason == "unknown_target")
    assert(rpc("inspect", {}).reason == "invalid_args")
end)

test("interact: a world item in reach -> aim, press, verified by the inventory gain and the item gone", function()
    FAKE.aims, FAKE.presses = 0, 0
    local first, _, id = rpc("interact", { target = "wi_1" })
    assert(first == nil, "async")
    for _ = 1, 4 do step() end
    local out = drain()
    local r = results(out, id)[1]
    assert(r and r.ok, "interact ok: " .. json.encode(r))
    assert(r.data.item == "ITEM_Resources_Wood_Oak" and r.data.count == 2 and r.data.target_gone == true)
    assert(FAKE.aims >= 1 and FAKE.presses == 1, "aimed and pressed once")
    assert(#events(out, "task_done") == 1)
    assert(rpc("get_state").data.nearby_items[1] == nil, "gone from the world")
end)

test("interact: a grave out of reach -> walk there first, Take All, the grave disappears", function()
    FAKE.presses = 0
    FAKE.auto_arrive = true
    local _, _, id = rpc("interact", { target = "grave_1" })
    for _ = 1, 8 do step() end
    FAKE.auto_arrive = nil
    local r = results(drain(), id)[1]
    assert(r and r.ok, json.encode(r))
    assert(r.data.item == "ITEM_Pickaxe_Mithril" and r.data.target_gone == true and FAKE.presses == 1)
    assert(FAKE.move.calls[#FAKE.move.calls] == "go_to", "approached with move.go_to")
    FAKE.move.position = nil -- back to the default spot
end)

test("interact refusals: creature, detector on something else, nothing happens", function()
    assert(rpc("interact", { target = "deer_1" }).reason == "not_interactable")
    assert(rpc("interact", { target = "ghost" }).reason == "unknown_target")
    assert(rpc("interact", { target = "stick_1", secondary = true }).reason == "not_implemented")
    FAKE.detector_override = { actor = "bench_1", prompt = "Craft" }
    local _, _, id = rpc("interact", { target = "stick_1" })
    T = T + B.INTERACT_AIM_S
    step(); step()
    local r = results(drain(), id)[1]
    FAKE.detector_override = nil
    assert(r and r.reason == "not_interactable" and r.data.detail:find("bench_1"), json.encode(r))
    FAKE.press_noop = true
    _, _, id = rpc("interact", { target = "stick_1" })
    step(); step()
    T = T + B.INTERACT_VERIFY_S
    step()
    r = results(drain(), id)[1]
    FAKE.press_noop = nil
    assert(r and r.reason == "verification_failed", json.encode(r))
end)

test("events: damage from someone else -> attacked (debounced); own damage ignored", function()
    local V = base .. "/vitals.jsonl"
    write(V, json.encode({ type = "damage", amount = 7, hp = 83, instigator = { id = "wolf_9", name = "Wolf", class = "BP_AI_Wolf_C" } }) .. "\n")
    write(V, json.encode({ type = "damage", amount = 7, hp = 76, instigator = { id = "wolf_9", name = "Wolf" } }) .. "\n")
    write(V, json.encode({ type = "damage", amount = 2, instigator = { id = "me", self = true } }) .. "\n")
    write(V, json.encode({ type = "survival", hydration = { 50, 100 } }) .. "\n")
    step()
    local at = events(drain(), "attacked")
    assert(#at == 1 and at[1].by == "wolf_9" and at[1].name == "Wolf" and at[1].amount == 7, json.encode(at))
    T = T + B.ATTACKED_REPEAT_S
    write(V, json.encode({ type = "damage", amount = 7, instigator = { id = "wolf_9" } }) .. "\n")
    step()
    assert(#events(drain(), "attacked") == 1, "again after the debounce window")
end)

test("events: vitals_low only when low AND nothing to eat/drink; re-armed above 25", function()
    FAKE.survival = { hydration = { 10, 100 }, sustenance = { 12, 100 } }
    FAKE.has_food = true
    T = T + B.VITALS_CHECK_S
    step()
    local vl = events(drain(), "vitals_low")
    assert(#vl == 1 and vl[1].stat == "hydration" and vl[1].value == 10 and vl[1].has_food == true and vl[1].has_drink == false,
           json.encode(vl))
    T = T + B.VITALS_CHECK_S
    step()
    assert(#events(drain(), "vitals_low") == 0, "not repeated within VITALS_REPEAT_S")
    T = T + B.VITALS_REPEAT_S
    step()
    assert(#events(drain(), "vitals_low") == 1, "repeated while still low")
    FAKE.has_drink = true
    T = T + B.VITALS_REPEAT_S
    step()
    assert(#events(drain(), "vitals_low") == 0, "the reflex can drink: no event")
    FAKE.survival, FAKE.has_food, FAKE.has_drink = nil, nil, nil
end)

test("chat: every other player's line -> chat_heard with mentions_me; self, events and junk skipped", function()
    for _, line in ipairs({
        { type = "chat", from = "Luis", text = "Claude, follow me", self = false, ts = 5 },
        { type = "chat", from = "Bob", text = "nice house", self = false },
        { type = "chat", from = "Luis", text = "hello claude what are you wearing", self = false },
        { type = "chat", from = "Luis", text = "thanks Claude", self = false },
        { type = "chat", from = "Ann", text = "claudette is here", self = false },
        { type = "chat", from = "Luis", text = "!ping", self = false },
        { type = "chat_event", from = "Bob", tag = "Joined" },
        { type = "chat", from = "Claude", text = "claude here", self = true },
    }) do write(CHAT, json.encode(line) .. "\n") end
    write(CHAT, "not json\n")
    step()
    local out = drain()
    assert(#events(out, "command_received") == 0, "no pre-filtered commands any more")
    local h = events(out, "chat_heard")
    assert(#h == 6, "six heard, got " .. #h)
    assert(h[1].from == "Luis" and h[1].player == "Luis" and h[1].text == "Claude, follow me" and h[1].mentions_me == true and h[1].ts == 5)
    assert(h[2].from == "Bob" and h[2].mentions_me == false)
    assert(h[3].mentions_me == true and h[4].mentions_me == true, "name anywhere")
    assert(h[5].mentions_me == false, "claudette is not claude")
    assert(h[6].text == "!ping" and h[6].mentions_me == true)
    assert(B.addressed("@Companion come") and B.addressed("  !PING x") and not B.addressed("claudette", nil, "Claude"))
end)

test("chat file rotation: emptied once consumed past the threshold, reading continues", function()
    B.CHAT_ROTATE_BYTES = 10
    write(CHAT, json.encode({ type = "chat", from = "Luis", text = "claude one", self = false }) .. "\n")
    step()
    assert(#events(drain(), "chat_heard") == 1)
    local f = io.open(CHAT, "rb"); local size = f:seek("end"); f:close()
    assert(size == 0, "rotated, size " .. size)
    write(CHAT, json.encode({ type = "chat", from = "Luis", text = "claude two", self = false }) .. "\n")
    step()
    local cr = events(drain(), "chat_heard")
    assert(#cr == 1 and cr[1].text == "claude two")
    B.CHAT_ROTATE_BYTES = 1024 * 1024
end)

test("debug channel: same tools on its own file pair; replies never reach the brain's file", function()
    local DIN, DOUT = DIR .. "/debug_to_client.jsonl", DIR .. "/client_to_debug.jsonl"
    write(DIN, json.encode({ v = 1, type = "cmd", id = "dbg1", tool = "ping", args = setmetatable({}, { __jsontype = "object" }) }) .. "\n")
    step()
    assert(#drain() == 0, "nothing on the brain's file")
    local f = assert(io.open(DOUT, "rb")); local txt = f:read("a"); f:close()
    local m = json.decode(txt:match("([^\n]*)\n"))
    assert(m.id == "dbg1" and m.ok and m.data.pong, txt)
end)

test("move events: unreachable once per episode, reachable_again -> resumed, stuck -> unreachable(stuck)", function()
    local MV = base .. "/move.jsonl"
    write(MV, json.encode({ type = "unreachable", reason = "leader_windstepped", detail = "dz=6.9m", leader_pos = { 1, 2, 9 },
                            my_pos = { 1, 2, 3 }, mode = "follow" }) .. "\n")
    write(MV, json.encode({ type = "reachable_again", after_s = 12 }) .. "\n")
    write(MV, json.encode({ type = "stuck", unstuck = "requested", my_pos = { 0, 0, 0 } }) .. "\n")
    step()
    local out = drain()
    local un, re = events(out, "unreachable"), events(out, "resumed")
    assert(#un == 2 and un[1].reason == "leader_windstepped" and un[1].detail == "dz=6.9m" and un[1].leader_pos[3] == 9)
    assert(un[2].reason == "stuck" and un[2].detail == "unstuck requested")
    assert(#re == 1 and re[1].after_s == 12)
end)

test("inventory tool: compact worn / held / hotbar with durability / bag; raw on request", function()
    local r = rpc("inventory", {})
    assert(r.ok, tostring(r.reason))
    local d = r.data
    assert(d.held.right == "Bronze Hatchet" and d.hotbar[1].slot == 0 and d.hotbar[1].name == "Oak Logs", json.encode(d))
    assert(d.worn.HeldRight == nil, "held slots are under held, not worn")
    assert(#d.bag >= 1 and d.bag[1].count >= 1)
    local raw = rpc("inventory", { raw = true })
    assert(raw.ok and raw.data.loadout and raw.data.loadout[1].loadout_slot == "HeldRight")
end)

test("a reflex fight owns the pawn: go_to and follow wait (no interrupted), then carry on", function()
    install("arbiter", [[
local A = {}
function A.owner() return _G.FAKE.reflex and { name = "reflex:guard", level = "reflex" } or nil end
function A.status() return { ok = true, suspended = {} } end
A.HANDLERS = { arbiter_status = function() return A.status() end }
return A
]])
    FAKE.move.position = nil
    local _, _, id = rpc("go_to", { target = { 10, 0, 0 } })
    FAKE.reflex = true
    FAKE.move.mode, FAKE.move.result = "idle", { status = "stopped" } -- the arbiter suspended the walk
    for _ = 1, 5 do step() end
    T = T + B.GOTO_TIMEOUT_S - 1
    step()
    assert(#results(drain(), id) == 0, "waits while the reflex fights, and the clock is paused")
    FAKE.reflex = nil
    FAKE.move.mode, FAKE.move.result = "go_to", nil -- restored by the arbiter
    step()
    FAKE.move.mode, FAKE.move.result, FAKE.move.position = "idle", { status = "arrived" }, { 10, 0, 0 }
    step()
    local r = results(drain(), id)[1]
    assert(r and r.ok, json.encode(r))
    FAKE.move.position = nil
    uninstall("arbiter")
end)

test("combat module: attack via its HANDLERS (async), stop ends a commanded fight only", function()
    install("combat", [[
local C = {}
_G.FAKE.fight = _G.FAKE.fight or nil
function C.status() return { ok = true, fight = _G.FAKE.fight, guard = true } end
function C.stop(log, why) _G.FAKE.combat_stopped = why; _G.FAKE.fight = nil; return { ok = true } end
function C.guard_start(log) return { ok = true } end
C.HANDLERS = { attack = function(log, args, ctx)
    _G.FAKE.fight = { mode = "attack", phase = "engage", target = "Wolf", target_id = args.target }
    local a = { kind = "attack", timeout_s = 135 }
    a.poll = function() if _G.FAKE.killed then _G.FAKE.fight = nil; return { ok = true, data = { killed = true, target = args.target } } end end
    a.cancel = function() C.stop(log, "cancel") end
    return { pending = a }
end }
return C
]])
    assert(has(rpc("capabilities").data.tools, "attack"), "attack from combat.HANDLERS")
    local _, _, id = rpc("attack", { target = "wolf_9" })
    local s = rpc("get_state").data
    assert(s.fight and s.fight.mode == "attack" and s.fight.target_id == "wolf_9" and s.action == "attack")
    local sid = send("stop")
    step()
    local out = drain()
    assert(results(out, id)[1].reason == "interrupted" and results(out, sid)[1].data.stopped == "attack")
    assert(FAKE.combat_stopped ~= nil, "commanded fight stopped")
    FAKE.combat_stopped = nil
    FAKE.fight = { mode = "reflex", phase = "engage" }
    rpc("stop")
    assert(FAKE.combat_stopped == nil, "self-defence keeps running on stop")
    FAKE.fight = nil
    uninstall("combat")
end)

test("module-declared HANDLERS dispatch", function()
    local r = rpc("inv_debug", { x = 7 })
    assert(r.ok and r.data.echo == 7)
end)

test("hot reload: an edited module is reloaded; a broken one answers not_implemented, a crash body_error", function()
    install("move", FAKES.move:gsub("M.VERSION = 1", "M.VERSION = 2"))
    rpc("capabilities")
    local st = B._state().mods.move
    assert(st.loads == 2 and st.mod.VERSION == 2, "reloaded")
    install("move", "return {")
    local r = rpc("follow", { player = "Luis" })
    assert(r.reason == "not_implemented" and r.data.detail:find("load"), tostring(r.data.detail))
    assert(not has(rpc("capabilities").data.tools, "follow"))
    install("move", (FAKES.move:gsub("function M.stop%(log%)", "function M.stop(log) error('boom')")))
    r = rpc("stop")
    assert(r.reason == "body_error" and r.data.detail:find("boom"))
    install("move")
    uninstall("inventory")
    assert(rpc("drop", { item = "oak", count = 1 }).reason == "not_implemented")
    install("inventory")
end)

test("bridge_status reports modules, stats and chat counters", function()
    local r = rpc("bridge_status")
    assert(r.ok and r.data.modules.move.ok and r.data.chat.chat_forwarded >= 3 and r.data.stats.received > 10)
    assert(r.data.chat.chat_rotations >= 1 and r.data.waiting == 0)
end)

test("restart via start(): old loop cancelled, new instance answers", function()
    B.stop()
    local B2 = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    B2.RELOAD_CHECK_S = 0
    B2.clock = function() return T end
    B2.start({ root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = CHAT, vitals_events = base .. "/vitals.jsonl", move_events = base .. "/move.jsonl", jlog = H.log, poll_ms = 50 })
    local handle, loop = nil, nil
    for h, l in pairs(H.loops) do handle, loop = h, l end
    assert(loop and loop.delay_ms == 50, "loop registered")
    B = B2
    local id = send("ping")
    H.tick()
    assert(results(drain(), id)[1].ok)
    B2.stop()
    assert(H.loops[handle] == nil, "stop cancels the loop")
end)

-- ------------------------------------------------------------------ run
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then print("PASS " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. ": " .. tostring(err)) end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
