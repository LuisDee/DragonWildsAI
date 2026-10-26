-- Offline tests for the capability manifest (client_bridge `capabilities`) and the composite skills
-- (client_mod/scripts/skills.lua): fetch, consume, come_to, recover_grave, give, interact (engine).
-- Usage: lua test_skills.lua <empty_dir>   (tests/test_skills_contract.py runs it with a pytest tmp dir)
-- The REAL client_bridge.lua, skills.lua, manifest.lua and arbiter.lua run over the shared fakes in
-- client_mod/tests/fakes/ (chat, move, sense, inventory), patched per test for consumables, follow
-- arrival and equip. UE4SS globals come from mod/tests/bridge_harness.lua.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local REPO = here .. "/../.."
local H = dofile(REPO .. "/mod/tests/bridge_harness.lua")
local json = require("dkjson")

local base = assert(arg[1], "usage: lua test_skills.lua <empty_dir>")
local function mkdir(p)
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. p .. '"') end
end
local DIR, SCRIPTS = base .. "/bridge", base .. "/scripts"
mkdir(DIR); mkdir(SCRIPTS)
local IN, OUT = DIR .. "/brain_to_client.jsonl", DIR .. "/client_to_brain.jsonl"
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local function write(path, s, mode) local f = assert(io.open(path, mode or "ab")); f:write(s); f:close() end
for _, n in ipairs({ "chat", "move", "sense", "inventory" }) do write(SCRIPTS .. "/" .. n .. ".lua", read(here .. "/fakes/" .. n .. ".lua"), "wb") end
for _, n in ipairs({ "skills", "manifest", "arbiter" }) do
    write(SCRIPTS .. "/" .. n .. ".lua", read(REPO .. "/client_mod/scripts/" .. n .. ".lua"), "wb")
end

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
local seq, B, T = 0, nil, 1000
local function send(tool, args)
    seq = seq + 1
    local id = "s" .. seq
    write(IN, json.encode({ v = 1, type = "cmd", id = id, tool = tool,
                            args = args or setmetatable({}, { __jsontype = "object" }) }) .. "\n")
    return id
end
local function result_of(msgs, id) for _, m in ipairs(msgs) do if m.type == "result" and m.id == id then return m end end end
local function rpc(tool, args) local id = send(tool, args); B.step(); return result_of(drain(), id), id end
-- step (advancing the clock dt each step) until the result for id arrives or n steps pass
local function run(id, n, dt)
    for _ = 1, n or 60 do
        T = T + (dt or 0.5)
        B.step()
        local r = result_of(drain(), id)
        if r then return r end
    end
end
local function has(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end

-- ------------------------------------------------------------------ fixtures
local F
local function mods() return B.module("inventory"), B.module("move"), B.module("sense"), B.module("skills"), B.module("arbiter") end

-- Consumables carried (F.cons rows {name, item, count, consumable, where, stat, amount}) on top of the
-- shared inventory fake; inventory.use / equip / held; world items with `consumable` land in F.cons.
local function patch()
    local inv, mv, sense, sk, arb = mods()
    arb.clock = function() return T end
    arb.set_move(mv)
    if inv._patched then return end
    inv._patched = true
    local list0, press0 = inv.list, inv.press_interact
    inv.list = function(log)
        local l = list0(log)
        for i, c in ipairs(F.cons or {}) do
            if c.count > 0 then
                local row = { name = c.name, item = c.item, count = c.count, consumable = c.consumable, slot = 10 + i,
                              slot_type = c.where == "hotbar" and "QuickAction" or "InventoryItems" }
                table.insert(c.where == "hotbar" and l.hotbar or l.bag, row)
            end
        end
        if F.held_item ~= nil then l.held = { right = F.held_name, right_item = F.held_item or nil } end
        return l
    end
    inv.use = function(log, what, opts)
        F.uses = (F.uses or 0) + 1
        for _, c in ipairs(F.cons or {}) do
            if (c.item == what or c.name == what) and c.count > 0 then
                if opts and opts.hotbar_only and c.where ~= "hotbar" then return { ok = false, reason = "not on the hotbar" } end
                if F.use_noop then return { ok = true, via = "hotbar key" } end
                c.count = c.count - 1
                local s = F.survival[c.stat]
                s[1] = math.min(s[2], s[1] + c.amount)
                return { ok = true, via = "hotbar key" }
            end
        end
        return { ok = false, reason = "not in hotbar/bag: " .. tostring(what) }
    end
    inv.equip = function(log, what) F.equips = (F.equips or 0) + 1; F.held_item, F.held_name = what, what; return { ok = true } end
    inv.move = function(log, what, to)
        for _, c in ipairs(F.cons or {}) do
            if c.item == what or c.name == what then
                if not F.move_noop then c.where = to end
                return { ok = true, to = to }
            end
        end
        return { ok = false, reason = "not in inventory: " .. tostring(what) }
    end
    inv.press_interact = function(log)
        local det = inv.interact_target()
        for cat, rows in pairs(F.world) do
            for i, r in ipairs(rows) do
                if det and r.id == det.actor and r.consumable then
                    F.presses = (F.presses or 0) + 1
                    table.remove(rows, i)
                    F.cons[#F.cons + 1] = { name = r.name, item = r.item, count = r.count or 1, consumable = r.consumable,
                                            where = F.pickup_where or "hotbar", stat = "hydration", amount = 25 }
                    return { ok = true }
                end
            end
        end
        return press0(log)
    end
    local status0 = mv.status
    mv.status = function()
        local st = status0()
        if st.mode == "follow" and F.follow then
            if F.follow == "near" then F.move.position = { 3, 2.5, 3 }; st.status = "near"
            elseif F.follow == "unreachable" then st.status = "unreachable"
                st.unreachable = { reason = "leader_above_jump_height", leader_pos = { 3, 4, 9 }, my_pos = { 1, 2, 3 } } end
        end
        return st
    end
end

local function reset()
    F = _G.FAKE
    F.world = B.module("sense").default_world()
    table.insert(F.world.items, { id = "wi_psi", class = "BP_WorldItem_C", name = "Pumpkin Spice Infusion",
        item = "ITEM_Consumable_PSI", count = 2, position = { 9, 9, 3 }, consumable = "drink" })
    F.inv = { oak_bag = 5, oak_bar = 3 }
    F.extra, F.cons = {}, {}
    F.survival = { sustenance = { 40, 100 }, hydration = { 10, 100 }, endurance = { 40, 100 } }
    F.move = { mode = "idle", calls = {} }
    F.me_pos, F.detector_override, F.press_noop, F.use_noop, F.follow, F.held_item, F.held_name = nil, nil, nil, nil, nil, nil, nil
    F.auto_arrive, F.aims, F.presses, F.uses, F.equips, F.pickup_where, F.move_noop = true, 0, 0, 0, 0, nil, nil
    _G.DW_PAUSE, _G.DWSkills, _G.DW_LIFE = nil, nil, nil
    local sk = B.module("skills")
    sk.W.grave_owner = function() return nil end
    sk.DEATH_FILE = base .. "/last_death.json" -- never the live client's file
    os.remove(sk.DEATH_FILE)
    patch()
    B.module("arbiter").reset()
    drain()
end

-- ------------------------------------------------------------------ tests
test("start the real bridge with skills + manifest over the fakes", function()
    B = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    B.RELOAD_CHECK_S = 0
    B.clock = function() return T end
    _G.FAKE = { auto_arrive = true }
    B.start({ root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = base .. "/chat.jsonl", vitals_events = base .. "/vitals.jsonl",
              move_events = base .. "/move.jsonl", gather_events = base .. "/gather.jsonl", jlog = H.log, no_loop = true })
    reset()
end)

test("manifest: one entry per implemented tool; primitives offered, compounds demoted; alias pickup -> interact", function()
    reset()
    local r = rpc("capabilities")
    assert(r.ok and type(r.data.manifest) == "table", json.encode(r))
    local by = {}
    for _, e in ipairs(r.data.manifest) do by[e.name] = e end
    for _, t in ipairs(r.data.tools) do assert(by[t], "manifest lacks implemented tool " .. t) end
    for _, e in ipairs(r.data.manifest) do assert(has(r.data.tools, e.name), "manifest lists unimplemented " .. e.name) end
    for _, t in ipairs({ "interact", "consume", "move_item", "equip", "follow", "stop", "go_to", "drop", "look", "inspect", "inventory" }) do
        assert(by[t] and by[t].llm == true, "llm tool " .. t)
        assert(by[t].args and by[t].args.type == "object", "schema " .. t)
        assert(type(by[t].description) == "string" and #by[t].description > 20, "description " .. t)
    end
    for _, t in ipairs({ "fetch", "come_to", "recover_grave", "give" }) do -- compounds: tested, not offered (PRINCIPLES 4b)
        assert(by[t] and by[t].llm == false, "compound demoted " .. t)
    end
    assert(by.interact.moves == true and by.interact.priority == "command" and by.interact.timeout_s >= 100)
    assert(by.interact.args.properties.secondary and by.interact.detail_is_speech == true)
    assert(by.consume.args.required[1] == "item" and by.move_item.args.properties.to.enum[1] == "hotbar")
    assert(by.recover_grave.args.properties ~= nil, "no-arg schema still has properties")
    assert(by.look.kind == "read" and by.drop.args.properties.at.enum[1] == "feet")
    assert(by.get_state and by.get_state.llm == false and by.ping.llm == false and by.census.llm == false)
    assert(not by.pickup and not by.attack and not by.gather, "tools the body lacks are absent")
    assert(r.data.aliases.pickup == "interact", json.encode(r.data.aliases))
    assert(r.data.manifest_version == 1)
    write(base .. "/capabilities.json", json.encode(r.data), "wb") -- for tests/test_skills_contract.py
    -- the raw JSON keeps empty schemas as objects
    write(IN, "")
    local raw = read(OUT)
    assert(raw:find('"properties":{}', 1, true), "empty properties encode as {}")
end)

test("manifest follows the modules: no move.follow -> no come_to/give (and no alias without fetch)", function()
    reset()
    local mv = B.module("move")
    local f = mv.follow
    mv.follow = nil
    local r = rpc("capabilities")
    assert(not has(r.data.tools, "come_to") and not has(r.data.tools, "give") and has(r.data.tools, "fetch"))
    assert(rpc("come_to", { player = "Luis" }).reason == "not_implemented")
    mv.follow = f
    local inv = B.module("inventory")
    local p = inv.press_interact
    inv.press_interact = nil
    r = rpc("capabilities")
    inv.press_interact = p
    assert(not has(r.data.tools, "fetch") and not has(r.data.tools, "interact") and r.data.aliases.pickup == nil,
           "no alias to a missing tool")
end)

test("fetch by item name: find -> walk -> face -> press -> verified in the inventory", function()
    reset()
    local r0, id = rpc("fetch", { item = "pumpkin spice infusion" })
    assert(r0 == nil, "async")
    local r = run(id, 40)
    assert(r and r.ok, json.encode(r))
    assert(r.data.item == "ITEM_Consumable_PSI" and r.data.count == 2 and r.data.picked[1] == "wi_psi", json.encode(r.data))
    assert(has(F.move.calls, "go_to") and F.presses == 1 and F.aims >= 1)
    for _, it in ipairs(F.world.items) do assert(it.id ~= "wi_psi", "picked up") end
    local st = B.module("arbiter").status()
    assert(st.owner == nil and st.counts.granted >= 1, "acquired the pawn and released it")
end)

test("fetch by target id; legacy-style limit is not needed; count 1", function()
    reset()
    local _, id = rpc("fetch", { target = "wi_1" })
    local r = run(id, 30)
    assert(r and r.ok and r.data.item == "ITEM_Resources_Wood_Oak", json.encode(r))
end)

test("fetch failures carry a reason and a sayable detail", function()
    reset()
    local r = rpc("fetch", { item = "dragon bones" })
    assert(r.reason == "nothing_in_range" and r.data.detail:find("dragon bones"), json.encode(r))
    r = rpc("fetch", { target = "deer_1" })
    assert(r.reason == "not_interactable" and r.data.detail:find("Deer"), json.encode(r))
    r = rpc("fetch", { target = "ghost" })
    assert(r.reason == "unknown_target" and r.data.detail, json.encode(r))
    r = rpc("fetch", {})
    assert(r.reason == "invalid_args")
    -- the game's detector keeps picking something else: face + nudge, a closer approach, then not_interactable
    F.detector_override = { actor = "rock_9", name = "Stone" }
    local _, id = rpc("fetch", { target = "wi_psi" })
    local rr = run(id, 60)
    assert(rr and rr.reason == "not_interactable" and rr.data.detail:find("Stone"), json.encode(rr))
    assert(F.aims >= 3 and F.presses == 0, "faced repeatedly, never pressed the wrong thing")
    -- pressed but nothing happened (twice) -> verification_failed
    reset()
    F.press_noop = true
    _, id = rpc("fetch", { target = "wi_1" })
    rr = run(id, 60)
    assert(rr and rr.reason == "verification_failed" and F.presses == 2, json.encode(rr))
    -- the walk fails -> path_blocked with the move's why in words
    reset()
    F.auto_arrive = false
    _, id = rpc("fetch", { target = "wi_psi" })
    T = T + 1; B.step()
    F.move.mode, F.move.result = "idle", { status = "failed", reason = "no_route", dist_m = 12 }
    rr = run(id, 5)
    assert(rr and rr.reason == "path_blocked" and rr.data.why == "no_route" and rr.data.detail:find("no way I can walk"), json.encode(rr))
end)

test("consume from the hotbar: verified by the stat rising", function()
    reset()
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar",
                 stat = "hydration", amount = 25 } }
    local r0, id = rpc("consume", { item = "Clean Water" })
    local r = r0 or run(id, 10)
    assert(r and r.ok and r.data.stat == "hydration" and r.data.stat_rose == true and r.data.before == 10 and r.data.after == 35,
           json.encode(r))
    -- by kind
    r0, id = rpc("consume", { item = "drink" })
    r = r0 or run(id, 10)
    assert(r and r.ok and r.data.item == "ITEM_Consumable_Water_Clean" and r.data.count_left == 0, json.encode(r))
end)

test("consume: in the bag -> in_bag + offer; not carried -> not_in_inventory; no stat change -> verification_failed", function()
    reset()
    F.cons = { { name = "Forager's Sandwich", item = "ITEM_Food_Sandwich", count = 3, consumable = "food", where = "bag",
                 stat = "sustenance", amount = 20 } }
    local r = rpc("consume", { item = "sandwich" })
    assert(r.reason == "in_bag" and r.data.offer == "move_item" and r.data.detail:find("bag"), json.encode(r))
    assert(F.uses == 0, "no bag-UI use")
    r = rpc("consume", { item = "potato" })
    assert(r.reason == "not_in_inventory" and r.data.detail:find("potato"), json.encode(r))
    r = rpc("consume", { item = "Oak Logs" })
    assert(r.reason == "not_consumable", json.encode(r))
    F.cons[1].where = "hotbar"
    F.use_noop = true
    local _, id = rpc("consume", { item = "sandwich" })
    local rr = run(id, 20)
    assert(rr and rr.reason == "verification_failed" and rr.data.detail:find("sustenance"), json.encode(rr))
end)

test("consume: not carried but lying nearby -> not_in_inventory naming it (the model composes interact + consume)", function()
    reset()
    F.me_pos = { 8, 8, 3 } -- the infusion lies 1.4 m away (Luis dropped it in front of him)
    local r = rpc("consume", { item = "Pumpkin Spice Infusion" })
    assert(r.reason == "not_in_inventory" and r.data.on_ground.id == "wi_psi" and r.data.detail:find("on the ground"), json.encode(r))
    assert(F.presses == 0 and F.uses == 0, "a primitive: it neither walked nor picked up")
    -- composed: interact (pick up) then consume
    local _, id = rpc("interact", { target = "wi_psi" })
    local p = run(id, 30)
    assert(p and p.ok and p.data.item == "ITEM_Consumable_PSI" and p.data.count == 2, json.encode(p))
    local r0
    r0, id = rpc("consume", { item = "Pumpkin Spice Infusion" })
    local c = r0 or run(id, 10)
    assert(c and c.ok and c.data.stat_rose == true, json.encode(c))
end)

test("move_item bag -> hotbar (verified), then consume works; equip verified in the hands", function()
    reset()
    F.cons = { { name = "Forager's Sandwich", item = "ITEM_Food_Sandwich", count = 3, consumable = "food", where = "bag",
                 stat = "sustenance", amount = 20 } }
    assert(rpc("consume", { item = "Forager's Sandwich" }).reason == "in_bag")
    local id = send("move_item", { item = "Forager's Sandwich", to = "hotbar" })
    local m = run(id, 10)
    assert(m and m.ok and m.data.to == "hotbar" and F.cons[1].where == "hotbar", json.encode(m))
    local r0
    r0, id = rpc("consume", { item = "Forager's Sandwich" })
    local c = r0 or run(id, 10)
    assert(c and c.ok and c.data.stat == "sustenance", json.encode(c))
    F.move_noop = true
    F.cons[1].where = "bag"
    id = send("move_item", { item = "Forager's Sandwich", to = "hotbar" })
    m = run(id, 12)
    assert(m and m.reason == "verification_failed" and m.data.detail:find("didn't move"), json.encode(m))
    assert(rpc("move_item", { item = "Dragon Bones", to = "hotbar" }).reason == "not_in_inventory")
    -- equip: answered once it is in his hands
    F.held_item, F.held_name = false, nil
    id = send("equip", { item = "Oak Logs" })
    local e = run(id, 10)
    assert(e and e.ok and e.data.item == "ITEM_Resources_Wood_Oak" and F.equips == 1, json.encode(e))
end)

test("interact secondary=true presses the secondary action (collect-all on a stack)", function()
    reset()
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    local got
    inv.press_interact = function(log, opts) got = opts; return p0(log, opts) end
    local _, id = rpc("interact", { target = "wi_1", secondary = true })
    local r = run(id, 30)
    inv.press_interact = p0
    assert(r and r.ok and got and got.secondary == true, json.encode(r))
end)

test("come_to: follow until near, then stop; verified distance", function()
    reset()
    F.follow = "near"
    local _, id = rpc("come_to", { player = "Luis" })
    local r = run(id, 10)
    assert(r and r.ok and r.data.player == "Luis" and r.data.dist_m <= 3.5, json.encode(r))
    assert(has(F.move.calls, "follow:Luis") and F.move.calls[#F.move.calls] == "stop")
end)

test("come_to: unreachable for 30 s -> path_blocked with the specific why in words", function()
    reset()
    F.follow = "unreachable"
    local _, id = rpc("come_to", { player = "Luis" })
    local r = run(id, 40, 1.0)
    assert(r and r.reason == "path_blocked" and r.data.why == "leader_above_jump_height", json.encode(r))
    assert(r.data.detail:find("higher up than I can jump"), r.data.detail)
    assert(rpc("come_to", {}).reason == "invalid_args")
end)

test("recover_grave: own grave in get_state, walk, Take All, items back, the held tool re-equipped", function()
    reset()
    F.held_item, F.held_name = "ITEM_Pickaxe_Mithril", "Mithril Pickaxe"
    rpc("get_state")                     -- remembers what he holds
    F.held_item, F.held_name = false, nil -- died: hands empty, gear in the grave
    F.move.position = { 1, 25, 3 }       -- the grave is 5 m away
    local s = rpc("get_state")
    assert(s.ok and s.data.my_grave and s.data.my_grave.id == "grave_1" and s.data.my_grave.items == 1, json.encode(s.data.my_grave))
    assert(s.data.my_grave.contents[1] == "Mithril Pickaxe x1" and s.data.my_grave.owner == "unverified")
    assert(s.data.last_held == "Mithril Pickaxe")
    local _, id = rpc("recover_grave")
    local r = run(id, 40)
    assert(r and r.ok and r.data.count == 1 and r.data.grave == "grave_1", json.encode(r))
    assert(r.data.reequipped == "Mithril Pickaxe" and F.equips == 1, json.encode(r.data))
end)

test("recover_grave: never another player's grave; several unknown -> ambiguous; none -> nothing_in_range", function()
    reset()
    local sk = B.module("skills")
    sk.W.grave_owner = function() return false end
    local r = rpc("recover_grave")
    assert(r.reason == "nothing_in_range" and r.data.detail:find("other people"), json.encode(r))
    sk.W.grave_owner = function() return nil end
    table.insert(F.world.interactables, { id = "grave_2", class = "BP_PlayerGravestone_C", name = "", prompt = "Take All", position = { 2, 28, 3 } })
    r = rpc("recover_grave")
    assert(r.reason == "ambiguous_target", json.encode(r))
    sk.W.grave_owner = function(_, t) return t.id == "grave_2" end -- the owner check works: take OUR grave
    local s = rpc("get_state")
    assert(s.data.my_grave.id == "grave_2" and s.data.my_grave.owner == "verified" and s.data.other_graves == 1, json.encode(s.data.my_grave))
    F.world.interactables = {}
    r = rpc("recover_grave")
    assert(r.reason == "nothing_in_range" and r.data.detail:find("grave"))
end)

test("give: walk to the player, drop at his feet, verified by the count falling", function()
    reset()
    F.follow = "near"
    local _, id = rpc("give", { player = "Luis", item = "Oak Logs", count = 2 })
    local r = run(id, 20)
    assert(r and r.ok and r.data.count == 2 and r.data.player == "Luis" and r.data.item == "ITEM_Resources_Wood_Oak", json.encode(r))
    assert(F.dropped and F.dropped[2] == 2)
    assert(rpc("give", { player = "Luis", item = "Dragon Bones", count = 1 }).reason == "not_in_inventory")
    assert(rpc("give", { player = "Luis", item = "Oak Logs", count = 99 }).reason == "not_enough_resources")
end)

test("arbiter: a reflex fight suspends a fetch (no timeout while it fights), then it re-approaches and finishes", function()
    reset()
    F.auto_arrive = false
    local _, id = rpc("fetch", { item = "Pumpkin Spice Infusion" })
    T = T + 0.5; B.step()
    local A = B.module("arbiter")
    assert(A.owner() and A.owner().name == "skill:fetch", json.encode(A.status()))
    local fight = A.request(nil, { name = "combat:reflex", level = "reflex", uses_move = true })
    assert(fight.ok and fight.preempted.suspended)
    for _ = 1, 30 do T = T + 5; B.step() end -- 150 s of fighting: longer than the fetch timeout
    assert(result_of(drain(), id) == nil, "waits while the reflex owns the pawn")
    A.release(nil, fight.token, "won")
    F.auto_arrive = true
    local r = run(id, 40)
    assert(r and r.ok and r.data.item == "ITEM_Consumable_PSI", json.encode(r))
end)

test("stop pre-empts a running skill and releases the pawn; DW_PAUSE answers companion_down", function()
    reset()
    F.auto_arrive = false
    local _, id = rpc("fetch", { item = "Pumpkin Spice Infusion" })
    T = T + 0.5; B.step()
    local r, sid = rpc("stop")
    local msgs = drain()
    assert(r and r.ok, "stop answered")
    assert(B.module("arbiter").owner() == nil, "released")
    _G.DW_PAUSE = true
    r = rpc("consume", { item = "drink" })
    assert(r.reason == "companion_down", json.encode(r))
    _G.DW_PAUSE = nil
end)

test("interact route delegates to the skills engine (arbiter + face + verify + detail)", function()
    reset()
    local _, id = rpc("interact", { target = "wi_1" })
    local r = run(id, 30)
    assert(r and r.ok and r.data.item == "ITEM_Resources_Wood_Oak", json.encode(r))
    assert(B.module("arbiter").status().counts.granted >= 1, "through the arbiter")
    r = rpc("interact", { target = "deer_1" })
    assert(r.reason == "not_interactable" and r.data.detail, json.encode(r))
end)

test("death and respawn rows from the vitals watcher -> get_state.last_death", function()
    reset()
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T - 60, hp = 0 }) .. "\n")
    write(base .. "/vitals.jsonl", json.encode({ type = "revive", ts = T - 50, hp = 100 }) .. "\n")
    B.step()
    local s = rpc("get_state")
    assert(s.data.last_death and s.data.last_death.ago_s >= 60 and s.data.last_death.respawned == true, json.encode(s.data.last_death))
end)

test("activity.jsonl lines are forwarded as activity events (kind and fields kept)", function()
    reset()
    write(base .. "/activity.jsonl", "") -- tail starts at the end: create it, then append
    B.stop()
    B = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    B.RELOAD_CHECK_S = 0
    B.clock = function() return T end
    B.start({ root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = base .. "/chat.jsonl", vitals_events = base .. "/vitals.jsonl",
              move_events = base .. "/move.jsonl", gather_events = base .. "/gather.jsonl", activity_events = base .. "/activity.jsonl",
              jlog = H.log, no_loop = true })
    drain()
    write(base .. "/activity.jsonl", json.encode({ type = "activity", kind = "combat_end", by = "reflex", target = "Goblin Runt",
                                                   outcome = "killed", loot = { { name = "Goblin Pack", count = 1 } } }) .. "\n")
    write(base .. "/activity.jsonl", "not json\n")
    B.step()
    local evs = {}
    for _, m in ipairs(drain()) do if m.type == "event" and m.event.type == "activity" then evs[#evs + 1] = m.event end end
    assert(#evs == 1 and evs[1].kind == "combat_end" and evs[1].outcome == "killed" and evs[1].loot[1].name == "Goblin Pack",
           json.encode(evs))
end)

test("vitals service: hooks registered at the menu (no pawn) are re-armed once a pawn exists", function()
    reset()
    local sense = B.module("sense")
    local st0, start0 = sense.vitals_status, sense.vitals_start
    local hooked
    sense.vitals_status = function() return { running = true, hooks = 4, me = "BP_PlayerCharacter_C_1", hooked_pawn = hooked } end
    sense.vitals_start = function() F.vitals_starts = (F.vitals_starts or 0) + 1; hooked = "BP_PlayerCharacter_C_1"; return { ok = true } end
    local S = B._state()
    S.services_on, S.services = true, {}
    F.vitals_starts = 0
    B._supervise(true)
    assert(F.vitals_starts == 1 and S.services.vitals.state == "running", json.encode(S.services.vitals))
    T = T + B.SERVICE_CHECK_S
    B._supervise(false)
    assert(F.vitals_starts == 1, "healthy now: not restarted again")
    hooked = "BP_PlayerCharacter_C_OLD" -- a rejoin: new pawn, hooks for the old one
    T = T + B.SERVICE_CHECK_S
    B._supervise(false)
    assert(F.vitals_starts == 2, "re-armed for the new pawn")
    sense.vitals_status, sense.vitals_start, S.services_on = st0, start0, false
end)

test("items_dropped: a player's drop near Claude -> one event per burst, with who and what (existing ones ignored)", function()
    reset()
    B._state().drops_seen, B._state().drop_burst = nil, nil
    T = T + 5; B.step() -- first look: seeds what already lies around
    drain()
    table.insert(F.world.items, { id = "wi_sand", class = "BP_WorldItem_C", name = "Forager's Sandwich", item = "ITEM_Food_Sandwich",
        count = 3, position = { 2, 3, 3 }, consumable = "food", dropped_by = "Luis" })
    table.insert(F.world.items, { id = "wi_tea", class = "BP_WorldItem_C", name = "Pumpkin Spice Infusion", item = "ITEM_Tea",
        count = 2, position = { 2, 2.5, 3 }, consumable = "drink", dropped_by = "Luis" })
    T = T + 2; B.step()
    local function dropped() local o = {}; for _, m in ipairs(drain()) do if m.type == "event" and m.event.type == "items_dropped" then o[#o + 1] = m.event end end; return o end
    assert(#dropped() == 0, "waits for the burst to end")
    T = T + 3; B.step()
    local evs = dropped()
    assert(#evs == 1 and evs[1].by == "Luis" and #evs[1].items == 2 and evs[1].items[1].consumable, json.encode(evs))
    T = T + 5; B.step()
    assert(#dropped() == 0, "once per burst")
    local s = rpc("get_state")
    local row
    for _, it in ipairs(s.data.nearby_items) do if it.id == "wi_sand" then row = it end end
    assert(row and row.dropped_by == "Luis", json.encode(row))
end)

test("a pawn held by a non-fight owner: the skill fails 'busy' naming the real owner (never a guess)", function()
    reset()
    local A = B.module("arbiter")
    local stale = A.request(nil, { name = "debug:stale_lock", level = 3.5, uses_move = false })
    assert(stale.ok)
    local _, id = rpc("interact", { target = "wi_1" })
    local r = run(id, 60, 1.0)
    A.release(nil, stale.token)
    assert(r and r.reason == "busy" and r.data.owner == "debug:stale_lock", json.encode(r))
end)

test("interact on a shelter: walk to the INTERACTION point's open side (not the roof), detector, press, verified by sleeping", function()
    reset()
    local sk = B.module("skills")
    local shelter = { id = "BP_Magic_SummonShelter_C_1", class = "BP_Magic_SummonShelter_C", name = "Summon Shelter",
                      kind = "resting_area", prompt = "Sleep", position = { 20, 20, 3 },
                      InteractionCollider = { K2_GetComponentLocation = function() return { X = 2100, Y = 2000, Z = 350 } end },
                      GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end }
    table.insert(F.world.interactables, shelter)
    F.move.position = { 20, 20, 5 } -- standing ON the tent (the 20:46 bug)
    local det0, sig0 = sk.W.detector, sk.W.press_signals
    local slept = false
    sk.W.detector = function()
        local p = F.move.position
        if math.abs(p[1] - 22.5) < 0.5 and math.abs(p[2] - 20) < 0.5 then
            return { actor = shelter.id, prompt = "Sleep", class = shelter.class }
        end
        return { none = true }
    end
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function() slept = true; return { ok = true } end
    sk.W.press_signals = function() return { sleeping = slept } end
    local _, id = rpc("interact", { target = shelter.id })
    local r = run(id, 40)
    sk.W.detector, sk.W.press_signals, inv.press_interact = det0, sig0, p0
    assert(r and r.ok and r.data.changed == "sleeping", json.encode(r))
    local tg = F.move.target
    assert(math.abs(tg[1] - 22.5) < 0.01 and tg[2] == 20, "walked to the open side of the collider, not the origin: " .. json.encode(tg))
    -- spot maths: away from the actor centre, then rotated alternatives; forward vector when the collider is central
    local sp = sk._spots_around({ 21, 20, 3.5 }, { 20, 20, 3 }, nil)
    assert(math.abs(sp[1][1] - 22.5) < 1e-6 and #sp == 6 and math.abs(sp[6][1] - 19.5) < 1e-6, json.encode(sp))
    sp = sk._spots_around({ 20, 20, 3 }, { 20, 20, 3 }, { 0, 1 })
    assert(math.abs(sp[1][2] - 21.5) < 1e-6, "forward vector used: " .. json.encode(sp[1]))
    assert(B.module("move") and true)
end)

test("interact: a blocked side -> the next standing spot", function()
    reset()
    local sk = B.module("skills")
    local bench = { id = "bench_9", class = "BP_Workbench_C", name = "Workbench", kind = "crafting_station", prompt = "Craft",
                    position = { 6, 2, 3 },
                    InteractionCollider = { K2_GetComponentLocation = function() return { X = 700, Y = 200, Z = 300 } end } }
    table.insert(F.world.interactables, bench)
    local det0, sig0 = sk.W.detector, sk.W.press_signals
    local mv = B.module("move")
    local go0 = mv.go_to
    local tries = 0
    local unstuck_allowed = false
    mv.go_to = function(log, goal, opts)
        tries = tries + 1
        if not opts or opts.allow_unstuck ~= false then unstuck_allowed = true end
        local r = go0(log, goal, opts)
        if tries == 1 then F.auto_arrive = false; F.move.mode, F.move.result = "idle", { status = "failed", reason = "no_route" } end
        return r
    end
    local status0 = mv.status
    mv.status = function() local st = status0(); if tries >= 2 then F.auto_arrive = true end; return st end
    sk.W.detector = function()
        local p = F.move.position or {}
        if p[1] and math.abs(p[2] - 2) > 0.5 then return { actor = bench.id, prompt = "Craft" } end -- only from the rotated spot
        return { none = true }
    end
    local opened = false
    sk.W.press_signals = function() return { sleeping = false } end
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function() opened = true; return { ok = true } end
    local d0 = sk.W.detector
    sk.W.detector = function() if opened then return { actor = bench.id, prompt = "Close" } end return d0() end
    local _, id = rpc("interact", { target = bench.id })
    local r = run(id, 60)
    mv.go_to, mv.status, inv.press_interact, sk.W.detector, sk.W.press_signals = go0, status0, p0, det0, sig0
    assert(r and r.ok and tostring(r.data.changed):find("prompt"), json.encode(r))
    assert(tries >= 2, "tried another side after the first was blocked")
    assert(not unstuck_allowed, "the interact engine never lets move.lua use the game's Unstuck (teleport; live 20:49)")
end)

test("interact on the bed he is lying in: one press gets him up, verified by the resting area clearing", function()
    reset()
    local sk = B.module("skills")
    local bed = { id = "BP_Magic_SummonShelter_C_2", class = "BP_Magic_SummonShelter_C", name = "Summon Shelter",
                  kind = "resting_area", prompt = "Sleep", position = { 1, 3, 3 } }
    table.insert(F.world.interactables, bed)
    local lying = true
    local r0 = sk.W.resting_in
    sk.W.resting_in = function() return lying and bed.id or nil end
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    local pressed = 0
    inv.press_interact = function() pressed = pressed + 1; lying = false; return { ok = true } end
    local r1, id = rpc("interact", { target = bed.id })
    local r = r1 or run(id, 10)
    sk.W.resting_in, inv.press_interact = r0, p0
    assert(r and r.ok and r.data.changed == "got_up" and pressed == 1, json.encode(r))
    assert(#F.move.calls == 0, "no walking to get up")
end)

test("BUGS L2d: movement while lying in a bed fails at once with reason resting (bed named)", function()
    reset()
    local sk = B.module("skills")
    local r0 = sk.W.resting_in
    sk.W.resting_in = function() return "BP_Magic_SummonShelter_C_7" end
    local g = rpc("go_to", { target = "Luis" })
    local f = rpc("follow", { player = "Luis" })
    local i = rpc("interact", { target = "wi_1" })
    local ir = i or run(select(2, rpc("interact", { target = "wi_1" })), 5)
    sk.W.resting_in = r0
    assert(g and g.reason == "resting" and g.data.resting_in == "BP_Magic_SummonShelter_C_7", json.encode(g))
    assert(f and f.reason == "resting", json.encode(f))
    assert(ir and ir.reason == "resting", json.encode(ir))
    assert(#F.move.calls == 0, "no movement attempted")
end)

test("BUGS L8: go_to resolves every perceived id (a foliage tree) to its position", function()
    reset()
    table.insert(F.world.resources, { id = "fol:BP_InteractableFoliageISMC_Tree_C_7:2", class = "BP_BM_Tree_Ash_02_C", name = "Ash Tree",
                                      kind = "foliage", verb = "chop", position = { 9, 4, 3 } })
    local r0, id = rpc("go_to", { target = "fol:BP_InteractableFoliageISMC_Tree_C_7:2" })
    local r = r0 or run(id, 10)
    assert(r and r.ok, json.encode(r))
    assert(F.move.target[1] == 9 and F.move.target[2] == 4, "walked to the tree's position: " .. json.encode(F.move.target))
end)

test("BUGS L7: interact on an item: an equal stack in front serves; a DIFFERENT item in front is named", function()
    reset()
    local sk = B.module("skills")
    local d0 = sk.W.detector
    table.insert(F.world.items, { id = "wi_axe", class = "BP_WorldItem_C", name = "Steel Logging Axe", item = "ITEM_Logging_Axe_Steel",
                                  count = 1, position = { 4, 4, 3 } })
    sk.W.detector = function() return { actor = "wi_pick", name = "Iron Pickaxe", item = "ITEM_Pickaxe_Iron" } end
    local _, id = rpc("interact", { target = "wi_axe" })
    local r = run(id, 80)
    assert(r and r.reason == "not_interactable" and r.data.detail:find("Iron Pickaxe") and r.data.spots_tried, json.encode(r))
    assert(#F.move.calls >= 2, "tried other sides of the item")
    reset()
    sk.W.detector = function() return { actor = "wi_other_logs", name = "Oak Logs", item = "ITEM_Resources_Wood_Oak" } end
    _, id = rpc("interact", { target = "wi_1" }) -- the same item id, another stack: pressing takes it
    r = run(id, 30)
    sk.W.detector = d0
    assert(r and r.ok and F.presses >= 1, json.encode(r))
end)

test("BUGS L12: the debug channel never pre-empts the brain's action (force=true overrides)", function()
    reset()
    local DIN, DOUT = DIR .. "/debug_to_client.jsonl", DIR .. "/client_to_debug.jsonl"
    local doff = 0
    do local f = io.open(DOUT, "rb"); if f then doff = f:seek("end"); f:close() end end
    local function dsend(tool, args)
        seq = seq + 1
        local did = "d" .. seq
        write(DIN, json.encode({ v = 1, type = "cmd", id = did, tool = tool, args = args }) .. "\n")
        return did
    end
    local function dresult(did)
        local f = io.open(DOUT, "rb"); if not f then return nil end
        f:seek("set", doff); local s2 = f:read("a"); f:close()
        for line in s2:gmatch("([^\n]*)\n") do local m = json.decode(line); if m and m.id == did and m.type == "result" then return m end end
    end
    local fr = rpc("follow", { player = "Luis" }) -- the brain's action holds the slot
    assert(fr and fr.ok)
    local did = dsend("interact", { target = "wi_1" })
    B.step()
    local dr = dresult(did)
    assert(dr and dr.reason == "busy" and dr.data.owner == "brain:follow", json.encode(dr))
    assert(B._state().action and B._state().action.kind == "follow", "the brain's follow still runs")
    did = dsend("interact", { target = "wi_1", force = true })
    B.step()
    assert(B._state().action and B._state().action.kind == "interact", "force takes the slot")
    rpc("stop")
end)

test("ping carries the bridge start epoch and the action slot (BUGS L2b)", function()
    reset()
    local p = rpc("ping")
    assert(p.ok and type(p.data.started) == "number" and p.data.action == nil, json.encode(p))
    rpc("follow", { player = "Luis" })
    p = rpc("ping")
    assert(p.data.action and p.data.action.kind == "follow" and p.data.action.id, json.encode(p))
    rpc("stop")
end)

test("BUGS L19: a death is remembered (where, what he carried), persisted, shown, go_to my_grave, cleared on recovery", function()
    reset()
    F.move.position = { 1, 25, 3 }
    rpc("get_state") -- he carries 3+5 oak logs here
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    local sk = B.module("skills")
    local f = io.open(sk.DEATH_FILE, "rb")
    assert(f, "persisted to a file"); f:close()
    _G.DWSkills = nil -- a client restart forgets _G: the file brings it back
    F.move.position = { 60, 60, 3 }
    local s = rpc("get_state")
    local dm = s.data.death_memory
    assert(dm and dm.position[2] == 25 and dm.lost_items >= 8 and dm.distance and dm.distance > 40, json.encode(dm))
    local r0, id = rpc("go_to", { target = "my_grave" })
    local r = r0 or run(id, 10)
    assert(r and r.ok and F.move.target[2] == 25, "walked to the death spot: " .. json.encode(F.move.target))
    -- Take All on the grave clears it
    F.move.position = { 1, 29, 3 }
    local _, gid = rpc("interact", { target = "grave_1" })
    local g = run(gid, 30)
    assert(g and g.ok, json.encode(g))
    s = rpc("get_state")
    assert(s.data.death_memory == nil, "recovered: no longer shown")
end)

test("vitals drain rate from samples (for 'empty in ~N min')", function()
    reset()
    F.survival = { sustenance = { 30, 100 }, hydration = { 50, 100 }, endurance = { 40, 100 } }
    rpc("get_state")
    T = T + 60
    F.survival.sustenance[1], F.survival.hydration[1] = 28, 47
    local s = rpc("get_state")
    assert(s.data.vitals_rate and s.data.vitals_rate.sustenance_per_min == 2 and s.data.vitals_rate.hydration_per_min == 3,
           json.encode(s.data.vitals_rate))
end)

test("activity: XP/min per skill and item gains/min over the window, with the best seen", function()
    reset()
    local sense = B.module("sense")
    local me0 = sense.me
    local xp = 1000
    sense.me = function(log) local r = me0(log); r.skills = { { skill = "Mining", level = 5, xp = xp } }; return r end
    rpc("get_state")
    T = T + 120
    xp = 1300
    F.inv.oak_bag = F.inv.oak_bag + 6
    local s = rpc("get_state")
    sense.me = me0
    local a = s.data.activity
    assert(a and a.skill == "Mining" and a.xp_per_min == 150 and a.best_xp_per_min == 150, json.encode(a))
    assert(a.items[1].item == "ITEM_Resources_Wood_Oak" and a.items[1].per_min == 3, json.encode(a.items))
end)

test("BUGS L20: bridge restart waits for idle, refuses with the reason, force overrides, unread commands survive", function()
    reset()
    local opts = { root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = base .. "/chat.jsonl", vitals_events = base .. "/vitals.jsonl",
                   move_events = base .. "/move.jsonl", gather_events = base .. "/gather.jsonl", activity_events = base .. "/activity.jsonl",
                   jlog = H.log, no_loop = true }
    local function fresh()
        local b = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
        b.RELOAD_CHECK_S, b.clock = 0, function() return T end
        return b
    end
    -- 1. an action in the slot: deferred, then refused after wait_s with the reason
    rpc("follow", { player = "Luis" })
    local B2 = fresh()
    local r = B2.restart_when_idle(opts)
    assert(r.deferred and r.why:find("action follow"), json.encode(r))
    T = T + 6
    assert(B2.restart_poll() == true and B2.last_restart.refused and B2.last_restart.why:find("follow"), "refused after 5 s")
    assert(B._state().action and B._state().action.kind == "follow", "the running bridge (and its follow) untouched")
    -- 2. it becomes idle within the wait: started then
    local B3 = fresh()
    r = B3.restart_when_idle(opts)
    assert(r.deferred)
    rpc("stop")
    assert(B3.restart_poll() == true and not B3.last_restart.refused, "started once idle")
    B = B3
    assert(rpc("ping").ok, "the new instance answers")
    -- 3. force while busy: at once; a command written before the swap is still read by the new instance
    rpc("follow", { player = "Luis" })
    local id = send("ping") -- unread by the old instance
    local B4 = fresh()
    r = B4.restart_when_idle({ root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = base .. "/chat.jsonl", jlog = H.log,
                               no_loop = true, force = true, vitals_events = base .. "/vitals.jsonl", move_events = base .. "/move.jsonl",
                               gather_events = base .. "/gather.jsonl", activity_events = base .. "/activity.jsonl" })
    assert(r.started and r.forced and r.forced:find("follow"), json.encode(r))
    B = B4
    B.step()
    assert(result_of(drain(), id), "the command written during the swap was answered (read position handed over)")
end)

test("BUGS L22: every unrecovered grave is kept (newest is not the only one); recovering one leaves the other", function()
    reset()
    -- death 1 at (1, 25): he carried logs
    F.move.position = { 1, 25, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    local ts1 = T
    -- death 2 far away, 100 s later, with less on him
    T = T + 100
    F.inv = { oak_bag = 1, oak_bar = 0 }
    F.move.position = { 80, 80, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    local s = rpc("get_state")
    local g = s.data.graves_remembered
    assert(g and #g == 2 and g[1].position[1] == 80 and g[2].position[2] == 25, json.encode(g))
    assert(g[2].go_to == "my_grave:" .. tostring(ts1) and g[2].lost_items == 8, json.encode(g[2]))
    -- go_to the OLDER grave by its key
    local r0, id = rpc("go_to", { target = "my_grave:" .. tostring(ts1) })
    local r = r0 or run(id, 10)
    assert(r and r.ok and F.move.target[2] == 25, json.encode(F.move.target))
    -- Take All at the grave by death 1 (grave_1 sits at (1,30), within 15 m): only death 1 is cleared
    F.move.position = { 1, 29, 3 }
    local _, gid = rpc("interact", { target = "grave_1" })
    assert(run(gid, 30).ok)
    s = rpc("get_state")
    g = s.data.graves_remembered
    assert(g and #g == 1 and g[1].position[1] == 80, "the other grave stays remembered: " .. json.encode(g))
end)

test("BUGS L21: explore walks least-visited legs and stops when something matching 'about' appears", function()
    reset()
    F.me_pos = nil
    F.move.position = { 0, 0, 3 }
    F.world.interactables = {}
    rpc("get_state")
    -- he came from the north-east (his trail): explore must head elsewhere first; water lies east, beyond sight
    local mem = _G.DWSkills
    mem.visited = mem.visited or {}
    for i = 0, 6 do mem.visited[i .. ":" .. i] = 5 end -- 10 m cells along +X+Y
    table.insert(F.world.interactables, { id = "water_1", class = "BP_WaterVolume_C", name = "Water Volume", kind = "interactable",
                                          prompt = "Collect Water", position = { 100, -10, 3 } })
    local r0, id = rpc("explore", { about = "water", max_legs = 6, leg_m = 30 })
    assert(r0 == nil, "async: " .. json.encode(r0))
    local r = run(id, 60)
    assert(r and r.ok and r.data.found.id == "water_1" and r.data.legs >= 1, json.encode(r))
    assert(not (r.data.position[1] > 0 and r.data.position[2] > 0), "did not go back the way he came (NE)")
    -- already in sight: says so at once
    local a = rpc("explore", { about = "water" })
    assert(a.reason == "already_in_sight" and a.data.found.id == "water_1", json.encode(a))
    -- nothing anywhere: a bounded search, then nothing_in_range with how far
    F.world.interactables = {}
    local _, id2 = rpc("explore", { about = "lava", max_legs = 2, leg_m = 10 })
    local n = run(id2, 40)
    assert(n and n.reason == "nothing_in_range" and n.data.legs == 2 and n.data.detail:find("lava"), json.encode(n))
end)

-- ------------------------------------------------------------------ containers: deposit / withdraw (build design §5)
local function chest_world(slots, rows)
    reset()
    F.world.items, F.world.resources = {}, {} -- nothing else in the detector's reach
    F.chests = { chest_1 = { slots = slots or 6, rows = rows or { { slot = 0, item = "ITEM_Resources_Stone", name = "Stone", count = 2 } } } }
    F.open_chest, F.closed, F.transfers, F.transfer_noop = nil, 0, 0, nil
    table.insert(F.world.interactables, { id = "chest_1", class = "BP_Chest_C", name = "Wooden Chest", kind = "storage",
                                          prompt = "Open", position = { 30, 2, 3 }, chest = true })
end

test("containers: interact on a chest is verified by its screen opening (changed = opened)", function()
    chest_world()
    local _, id = rpc("interact", { target = "chest_1" })
    local r = run(id, 60)
    assert(r and r.ok and r.data.changed == "opened" and F.open_chest == "chest_1", json.encode(r))
    F.open_chest = nil
end)

test("store: walk, open, all oak in (two stacks), verified on both sides, screen closed; take: one stone back", function()
    chest_world()
    local _, id = rpc("store", { item = "Oak Logs", container = "chest_1" })
    local r = run(id, 80)
    assert(r and r.ok and r.data.count == 8 and r.data.carried_now == 0 and r.data.inside_now == 8, json.encode(r))
    assert(F.transfers == 2, "one press per stack (hotbar 3, bag 5): " .. tostring(F.transfers))
    assert(F.closed == 1 and F.open_chest == nil, "the screen is closed after the action")
    assert(B.module("input") == nil or B.module("input").owner("container") == nil, "modal released")
    _, id = rpc("take", { item = "stone", container = "chest_1", count = 1 })
    r = run(id, 80)
    assert(r and r.ok and r.data.count == 1 and F.extra.ITEM_Resources_Stone == 1 and r.data.contents, json.encode(r))
    assert(F.closed == 2 and F.open_chest == nil)
end)

test("store/take: truthful refusals (not a container, not in it, too many, full, nothing moved) and every exit closes", function()
    chest_world()
    local r = rpc("store", { item = "Oak Logs", container = "bench_1" })
    assert(r.reason == "not_a_container" and r.data.detail:find("Workbench"), json.encode(r))
    r = rpc("store", { item = "Oak Logs", container = "chest_1", count = 50 })
    assert(r.reason == "not_enough_resources" and r.data.have == 8 and r.data.detail:find("only have 8"), json.encode(r))
    r = rpc("store", { item = "Dragon Bones", container = "chest_1" })
    assert(r.reason == "not_in_inventory", json.encode(r))
    -- not in it: only known once open, so it opens, looks, says what IS there, and closes
    local _, id = rpc("take", { item = "Dragon Bones", container = "chest_1" })
    r = run(id, 80)
    assert(r and r.reason == "not_in_container" and r.data.detail:find("2 Stone") and F.open_chest == nil, json.encode(r))
    -- full: one slot, holding stone
    chest_world(1)
    _, id = rpc("store", { item = "Oak Logs", container = "chest_1" })
    r = run(id, 80)
    assert(r and r.reason == "container_full" and F.transfers == 0 and F.open_chest == nil, json.encode(r))
    -- the game takes nothing: verification_failed when the wait runs out, never a claimed success
    chest_world()
    F.transfer_noop = true
    _, id = rpc("store", { item = "Oak Logs", container = "chest_1", count = 3 })
    r = run(id, 80)
    assert(r and r.reason == "verification_failed" and r.data.detail:find("nothing moved") and F.open_chest == nil, json.encode(r))
    -- the chest is already open (he opened it with interact): no walk, straight to the move
    chest_world()
    F.open_chest = "chest_1"
    F.move.calls = {}
    _, id = rpc("store", { item = "Oak Logs", container = "chest_1", count = 2 })
    r = run(id, 20)
    assert(r and r.ok and r.data.count == 2 and #F.move.calls == 0, json.encode(r))
    F.chests, F.open_chest, F.transfer_noop = nil, nil, nil
end)

test("store: a reflex pre-empting mid-transfer closes the chest at once; on resume it reopens and finishes", function()
    chest_world()
    F.open_chest, F.transfer_noop = "chest_1", true -- open, first press pending (the server hasn't answered)
    local _, id = rpc("store", { item = "Oak Logs", container = "chest_1", count = 3 })
    T = T + 0.5; B.step()
    local A = B.module("arbiter")
    assert(A.owner() and A.owner().name == "skill:store", json.encode(A.status()))
    local fight = A.request(nil, { name = "combat:reflex", level = "reflex", uses_move = true })
    assert(fight.ok and fight.preempted.suspended)
    assert(F.open_chest == nil and F.closed == 1, "the screen closed the moment the reflex took over (no stray input on it)")
    for _ = 1, 10 do T = T + 2; B.step() end
    assert(result_of(drain(), id) == nil, "waits while the reflex owns the pawn")
    F.transfer_noop = nil
    A.release(nil, fight.token, "won")
    local r = run(id, 80)
    assert(r and r.ok and r.data.count == 3 and F.open_chest == nil, json.encode(r))
end)

test("interact on an NPC: verified by the conversation it starts (changed = conversation), one press only", function()
    reset()
    F.world.items, F.world.resources = {}, {}
    table.insert(F.world.interactables, { id = "npc_1", class = "BP_NPC_Herbalist_C", name = "Herbalist", kind = "npc",
                                          prompt = "Talk", position = { 40, 2, 3 } })
    local sk = B.module("skills")
    local cv0 = sk.W.conversation_npc
    local talking
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function() F.presses = F.presses + 1; talking = "npc_1"; return { ok = true } end
    sk.W.conversation_npc = function() return talking end
    -- talk enabled: interact reports the conversation (talk builds on it)
    _G.DW_ENABLE_TALK = true
    local tw0 = sk.W.talk_enabled
    sk.W.talk_enabled = function() return true end
    local _, id = rpc("interact", { target = "npc_1" })
    local r = run(id, 60)
    sk.W.talk_enabled = tw0
    _G.DW_ENABLE_TALK = nil
    assert(r and r.ok and r.data.changed == "conversation" and F.presses == 1, json.encode(r))
    assert(type(sk._new_episode) == "function", "the episode is exported for talk.lua")
    -- talk NOT enabled (V2): the dialogue is left with the panel's own Cancel, and the reason is truthful
    talking, F.presses = nil, 0
    local cancels = 0
    local fake_input = { leave_conversation_step = function(press) cancels = cancels + 1; press("cancel"); return true end,
                         raw_inject = function(a) if a == "cancel" and cancels >= 2 then talking = nil end; return true end }
    local mod0 = B.API.module
    B.API.module = function(n) if n == "input" then return fake_input end return mod0(n) end
    _, id = rpc("interact", { target = "npc_1" })
    r = run(id, 60)
    B.API.module = mod0
    sk.W.conversation_npc, inv.press_interact = cv0, p0
    assert(r and r.reason == "not_implemented" and r.data.why == "conversation" and r.data.detail:find("can't hold conversations")
        and r.data.detail:find("goodbye") and cancels == 2 and F.presses == 1, json.encode(r) .. " cancels=" .. cancels)
end)

test("store: no OpenChests privilege -> no_permission before any walk or press", function()
    chest_world()
    local sense = B.module("sense")
    local hp0 = sense.has_privilege
    sense.has_privilege = function(p) return p ~= "open_chests" end
    F.move.calls, F.presses = {}, 0
    local r = rpc("store", { item = "Oak Logs", container = "chest_1" })
    sense.has_privilege = hp0
    assert(r.reason == "no_permission" and r.data.detail:find("rights") and #F.move.calls == 0 and F.presses == 0, json.encode(r))
end)

-- ------------------------------------------------------------------ run
for _, t in ipairs(tests) do

    local ok, err = pcall(t[2])
    if ok then print("PASS " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. ": " .. tostring(err)) end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
