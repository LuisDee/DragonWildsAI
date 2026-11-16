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
for _, n in ipairs({ "skills", "manifest", "arbiter", "quests", "input" }) do
    write(SCRIPTS .. "/" .. n .. ".lua", read(REPO .. "/client_mod/scripts/" .. n .. ".lua"), "wb")
end
write(SCRIPTS .. "/crafting.lua", [[return { W = { open_station = function(_, kind)
    return FAKE.screen_kind == kind and FAKE.screen_owner or nil
end } }]], "wb")

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
    if not mv._ownership_fixture then
        local go, stop = mv.go_to, mv.stop
        mv.go_to=function(log,goal,opts)
            local r=go(log,goal,opts);F.move.gen=(F.move.gen or 0)+1;F.move.owner_token=opts and opts.owner_token
            r.gen=F.move.gen;return r
        end
        mv.child_status=function(log,gen,token)
            return {ok=F.move.gen==gen and F.move.owner_token==token and arb.owns_move(token),mode=F.move.mode}
        end
        mv.stop_owned=function(log,gen,token)
            if F.move.gen~=gen or F.move.owner_token~=token or not arb.owns_move(token) then return {ok=false,reason="interrupted"} end
            return stop(log)
        end
        mv._ownership_fixture=true
    end
    if inv._patched then return end
    inv._patched = true
    local list0, press0 = inv.list, inv.press_interact
    inv.list = function(log)
        local l = list0(log)
        for i, c in ipairs(F.cons or {}) do
            if c.count > 0 then
                local row = { name = c.name, item = c.item, count = c.count, consumable = c.consumable, slot = 10 + i,
                              slot_type = c.where == "hotbar" and "QuickAction" or "InventoryItems", risk = c.risk }
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
    _G.DWInput = nil
    F.screens, F.screen_owner, F.screen_kind, F.screen_unknown = {}, nil, nil, nil
    F.free_slots = nil
    local inp = B.module("input")
    inp.clock = function() return T end
    inp.observe_screens = function() if F.screen_unknown then return nil end return F.screens end
    inp.input_mode = function() return #F.screens > 0 and "DIM_CraftingMenu" or "DIM_Gameplay" end
    inp.modal = function() return #F.screens > 0 and { kind = "screen", mode = "DIM_CraftingMenu" } or nil end
    inp.close_screens = function() F.screens = {}; return { "Crafting" }, {} end
    inp.close_container = function() return B.module("inventory").close_world_inventory() end
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
    assert(by.give and by.give.llm == true and by.give.moves == true, "give is offered (the 4b exception in its entry)")
    for _, t in ipairs({ "fetch", "come_to", "recover_grave" }) do -- compounds: tested, not offered (PRINCIPLES 4b)
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
    -- read-only module tools come from their own MANIFEST (quests.lua, registered in client_bridge.MODULES)
    assert(by.quests and by.quests.kind == "read" and by.quests.llm == true, "quests listed: " .. json.encode(by.quests))
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
    assert(rr and rr.reason == "path_blocked" and rr.data.why == "no_route" and rr.data.detail:find("no way through", 1, true), json.encode(rr)) -- move.why_words (one word table)
end)

test("consume waits for actual pawn ownership before pressing", function()
    local saved_t = T
    reset()
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar", stat = "hydration", amount = 25 } }
    local A = B.module("arbiter")
    local held = A.request(nil, { name = "combat", level = "reflex", uses_move = false })
    local _, id = rpc("consume", { item = "drink" })
    for _ = 1, 4 do T = T + 0.1; B.step() end
    assert((F.uses or 0) == 0, "must not press before grant")
    A.release(nil, held.token, "done")
    local result = run(id, 15)
    assert(result and result.ok and F.uses == 1, json.encode(result))
    T = saved_t
end)

test("consume waits out another use's animation, then presses once (or says what it's still using)", function()
    reset()
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar", stat = "hydration", amount = 25 } }
    F.consume_busy = { item = "Pumpkin Spice Infusion", left_s = 4 }
    local _, id = rpc("consume", { item = "drink" })
    for _ = 1, 4 do T = T + 0.5; B.step() end
    assert((F.uses or 0) == 0, "no press while another use runs")
    F.consume_busy = nil
    local r = run(id, 15)
    assert(r and r.ok and F.uses == 1, json.encode(r))
    F.consume_busy = { item = "Pumpkin Spice Infusion", left_s = 4 }
    local r0
    r0, id = rpc("consume", { item = "drink" })
    r = r0 or run(id, 40)
    F.consume_busy = nil
    assert(r and r.reason == "busy" and r.data.detail:find("Pumpkin Spice Infusion", 1, true) and F.uses == 1, json.encode(r))
end)

test("consume: a food mid-animation does not hold a drink (the game's use lock is per kind)", function()
    reset()
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar", stat = "hydration", amount = 25 } }
    F.consume_busy = { item = "Fillet", kind = "food", left_s = 5 }
    local r0, id = rpc("consume", { item = "drink" })
    local r = r0 or run(id, 15)
    F.consume_busy = nil
    assert(r and r.ok and F.uses == 1, json.encode(r))
end)

test("consume: the stay-fed reflex already drinking that kind -> says so at once, no second press", function()
    -- live r1-20261102T051035Z: the reflex drank the water he had just put on the hotbar; his drink waited 6.5 s, then pressed again
    reset()
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar", stat = "hydration", amount = 25 } }
    F.consume_busy = { item = "Clean Water", kind = "drink", by = "reflex", left_s = 5 }
    local r0, id = rpc("consume", { item = "Clean Water" })
    local r = r0 or run(id, 15)
    F.consume_busy = nil
    assert(r and r.ok and r.data.by_reflex and (F.uses or 0) == 0, json.encode(r))
    assert(tostring(r.data.detail):find("^My stay%-fed reflex already drank a Clean Water"), r.data.detail)
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

test("consume at a full stat still eats (the model's call) and says it was wasted (live 2026-11-01 13:14)", function()
    reset()
    F.survival.sustenance = { 74.7, 75 }
    F.cons = { { name = "Forager's Sandwich", item = "ITEM_Consumable_Sandwich", count = 2, consumable = "food", where = "hotbar",
                 stat = "sustenance", amount = 58 } }
    local r0, id = rpc("consume", { item = "food" })
    local r = r0 or run(id, 10)
    assert(r and r.ok and r.data.wasted == true and r.data.max == 75 and r.data.count_left == 1
           and r.data.detail:find("already full %(75/75%)", 1, false), json.encode(r))
end)

test("consume: crash-safety mechanism (BUGS L38): a crash-risk item is refused with the truthful reason, nothing used", function()
    reset()
    local inv = mods()
    local real = inv.crash_refusal
    -- the real rule lives in inventory.lua (data/consumable_risks.json; tested in test_inventory_reflex); here: skills
    -- honours it. Synthetic item: the real data lists nothing since fxguard fixed L38 (Dirty Water is safe now).
    inv.crash_refusal = function(item, name, kind)
        if item ~= "ITEM_Test_CrashRisk" then return nil end
        return { ok = false, reason = "unsafe", risk = "client_crash",
                 detail = "I won't drink " .. name .. ": it crashes my game." }
    end
    F.cons = { { name = "Crash Tonic", item = "ITEM_Test_CrashRisk", count = 2, consumable = "drink", where = "hotbar",
                 stat = "hydration", amount = 10 } }
    local uses0 = F.uses or 0
    local r0, id = rpc("consume", { item = "Crash Tonic" })
    local r = r0 or run(id, 10)
    assert(r and not r.ok and r.reason == "unsafe" and r.data.detail == "I won't drink Crash Tonic: it crashes my game."
           and (F.uses or 0) == uses0, json.encode(r))
    -- an ordinary drink is unaffected
    F.cons = { { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 2, consumable = "drink", where = "hotbar",
                 stat = "hydration", amount = 25 } }
    r0, id = rpc("consume", { item = "Clean Water" })
    r = r0 or run(id, 10)
    assert(r and r.ok, json.encode(r))
    inv.crash_refusal = real
end)

test("consume: in the bag -> dragged to the hotbar and used, said so; a drag that fails -> in_bag; not carried; no stat change", function()
    reset()
    F.cons = { { name = "Forager's Sandwich", item = "ITEM_Food_Sandwich", count = 3, consumable = "food", where = "bag",
                 stat = "sustenance", amount = 20 } }
    local r0, cid = rpc("consume", { item = "sandwich" })
    local r = r0 or run(cid, 20)
    assert(r and r.ok and r.data.moved_to_hotbar and F.cons[1].where == "hotbar" and F.uses == 1, json.encode(r))
    assert(r.data.detail == "Moved the Forager's Sandwich from my bag to my hotbar and ate it.", r.data.detail)
    F.cons[1].where, F.move_noop = "bag", true -- the drag doesn't take: never a bag-UI use
    r0, cid = rpc("consume", { item = "sandwich" })
    r = r0 or run(cid, 20)
    F.move_noop = nil
    assert(r.reason == "in_bag" and r.data.offer == "move_item" and r.data.detail:find("didn't get there", 1, true) and F.uses == 1, json.encode(r))
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

test("consume: a partial name match never substitutes another item (Clean Water is not the Water Rune)", function()
    reset()
    F.cons = { { name = "Water Rune", item = "ITEM_Rune_Water", count = 40, where = "hotbar" },
               { name = "Forager's Sandwich", item = "ITEM_Food_Sandwich", count = 1, consumable = "food", where = "bag",
                 stat = "sustenance", amount = 20 } }
    local r = rpc("consume", { item = "Clean Water" })
    assert(r.reason == "not_in_inventory" and r.data.item == "Clean Water" and (F.uses or 0) == 0, json.encode(r))
    assert(has(r.data.carried_consumables, "Forager's Sandwich") and r.data.detail:find("Forager's Sandwich", 1, true)
           and r.data.detail:find("Water Rune isn't something I can eat or drink", 1, true), json.encode(r))
    -- a fuzzy word prefers the consumable over the rune listed before it
    table.insert(F.cons, { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", count = 1, consumable = "drink",
                           where = "hotbar", stat = "hydration", amount = 25 })
    local r0, id = rpc("consume", { item = "water" })
    local c = r0 or run(id, 10)
    assert(c and c.ok and c.data.item == "ITEM_Consumable_Water_Clean", json.encode(c))
    -- only the rune left: "water" is not a drink he has; the exact rune name still says why not
    F.cons[3].count = 0
    r = rpc("consume", { item = "water" })
    assert(r.reason == "not_in_inventory" and r.data.detail:find("Water Rune", 1, true), json.encode(r))
    r = rpc("consume", { item = "Water Rune" })
    assert(r.reason == "not_consumable" and r.data.detail:find("Water Rune", 1, true), json.encode(r))
    -- give / store use the same resolver: no Clean Water handed over as a rune
    local sk = B.module("skills")
    local row, _, info = sk._find_carried(B.API, { hotbar = { { name = "Water Rune", item = "ITEM_Rune_Water" } } }, "Clean Water")
    assert(row == nil and info.near[1].name == "Water Rune", "partial overlap is near, not a match")
    row = sk._find_carried(B.API, { bag = { { name = "Oak Logs", item = "ITEM_Resources_Wood_Oak" } } }, "logs oak")
    assert(row and row.item == "ITEM_Resources_Wood_Oak", "every word matching still resolves")
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

test("interact secondary: collect-all names every kind it took, from the inventory", function()
    reset()
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function(log, opts)
        if not (opts and opts.secondary) then return p0(log, opts) end
        -- the game's collect-all takes every kind within 2 m (live 2026-11-01): the logs aimed at plus what lay there
        for i = #F.world.items, 1, -1 do if F.world.items[i].id == "wi_1" then table.remove(F.world.items, i) end end
        F.cons[#F.cons + 1] = { name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = 2, where = "bag" }
        F.cons[#F.cons + 1] = { name = "Stone", item = "ITEM_Resources_Stone", count = 8, where = "bag" }
        F.cons[#F.cons + 1] = { name = "Ash Logs", item = "ITEM_Resources_Wood_Ash", count = 2, where = "bag" }
        return { ok = true }
    end
    local _, id = rpc("interact", { target = "wi_1", secondary = true })
    local r = run(id, 30)
    inv.press_interact = p0
    assert(r and r.ok and tostring(r.data.detail):find("Collected all: 2 Oak Logs (and 8 Stone, 2 Ash Logs that were lying there).", 1, true),
        json.encode(r))
end)

test("come_to: follow until near, then stop; verified distance", function()
    reset()
    F.follow = "near"
    local _, id = rpc("come_to", { player = "Luis" })
    local r = run(id, 10)
    assert(r and r.ok and r.data.player == "Luis" and r.data.dist_m <= 3.5, json.encode(r))
    assert(has(F.move.calls, "follow:Luis") and F.move.calls[#F.move.calls] == "stop")
end)

test("give / come_to an NPC by name: says it is an NPC, not a player, and how NPC hand-ins go (live 19:3xZ)", function()
    reset()
    table.insert(F.world.interactables, { id = "BP_NPC_Doric_FTUE_C_1", class = "BP_NPC_Doric_FTUE_C", name = "Doric", kind = "npc",
                                          prompt = "Talk", position = { 12, 0, 3 } })
    F.cons[#F.cons + 1] = { name = "Stone Club", item = "ITEM_Club_Stone", count = 1, where = "bag" }
    -- as live: no player of that name, so move's follow finds no target
    local mv = B.module("move")
    local fol0 = mv.follow
    mv.follow = function(...) local r = fol0(...); if type(r) == "table" then r.target_visible = false end; return r end
    local r = rpc("give", { player = "Doric", item = "Stone Club", count = 1 })
    assert(r.ok == false and r.reason == "unknown_target" and r.data.why == "not_a_player" and r.data.npc == "BP_NPC_Doric_FTUE_C_1",
        json.encode(r))
    assert(r.data.detail:find("Doric is an NPC, not a player, so I can't give things", 1, true)
        and r.data.detail:find("hand-in to an NPC happens in the conversation", 1, true), r.data.detail)
    r = rpc("come_to", { player = "Doric" })
    assert(r.ok == false and r.data.why == "not_a_player" and r.data.detail:find("so I can't follow them", 1, true), json.encode(r))
    -- nobody of that name at all: the old words
    r = rpc("come_to", { player = "Zezima" })
    assert(r.ok == false and r.reason == "unknown_target" and r.data.why == nil
        and r.data.detail:find("I can't see where you are from here, Zezima", 1, true), json.encode(r))
    mv.follow = fol0
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

-- An "Open" grave (live 2026-11-01 17:14: 33 stacks, 145 items, 15 free slots; the press opened its storage screen):
-- the rows carry the item's own data, as inventory.external_rows reads it
local function open_grave(free, extra)
    reset()
    F.world.items, F.world.resources = {}, {}
    F.world.interactables = { { id = "grave_9", class = "BP_PlayerGravestone_C", name = "", prompt = "Open", position = { 1, 30, 3 }, chest = true } }
    local sk = B.module("skills")
    sk.W.grave_owner = function(_, t) return t.id == "grave_9" end
    F.extra = extra or { ITEM_Resources_Stone = 95, ITEM_Consumable_GoblinPack = 2 }
    F.chests = { grave_9 = { slots = 40, rows = {
        { slot = 1, item = "ITEM_Consumable_GoblinPack", name = "Goblin Pack", count = 15, category = "ItemFilter.Container", max_stack = 99, weight = 1 },
        { slot = 2, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Fur", count = 19, category = "ItemFilter.Material.BasicMaterial", max_stack = 99, weight = 0.2 },
        { slot = 3, item = "ITEM_Club_Stone", name = "Stone Club", count = 1, category = "Item.Equipment.Weapon.1H.Club", max_stack = 1, weight = 8, power = 1 },
        { slot = 4, item = "ITEM_Resources_Stone", name = "Stone", count = 12, category = "Item.BuildingResource", max_stack = 99, weight = 1 },
        { slot = 5, item = "ITEM_Sword_Bronze", name = "Bronze Sword", count = 1, category = "Item.Equipment.Weapon.1H.Sword", max_stack = 1, weight = 15, power = 3 },
        { slot = 6, item = "ITEM_Resources_VaultCore", name = "Vault Core", count = 1, category = "ItemFilter.Material.BasicMaterial", max_stack = 99, weight = 50 },
        { slot = 7, item = "ITEM_Consumable_Bread", name = "Bread", count = 7, category = "Item.Food", max_stack = 99, weight = 0.2 },
    } } }
    F.open_chest, F.closed, F.transfers, F.transfer_noop, F.free_slots = nil, 0, 0, nil, free
    local W8 = { ITEM_Sword_Bronze = 15, ITEM_Club_Stone = 8, ITEM_Resources_VaultCore = 50, ITEM_Resources_Stone = 1,
                 ITEM_Consumable_GoblinPack = 1, ITEM_Consumable_Bread = 0.2, ITEM_Resources_Coarse_Animal_Fur = 0.2 }
    sk.W.carry = function()
        local w = 60
        for k, n in pairs(F.extra) do w = w + n * (W8[k] or 0) end
        return { cur = w, max = 250 }
    end
    -- he died by it: the death is remembered there
    F.move.position = { 1, 25, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    return sk
end

test("recover_grave: an \"Open\" grave: its storage screen, gear first, then merges, then the rest; what stayed and why", function()
    local sk = open_grave(5)
    -- the order from the items' own data: gear (highest power first), merges (biggest first), food, then the biggest
    local order = sk.grave_take_order(F.chests.grave_9.rows, { { item = "ITEM_Resources_Stone" }, { item = "ITEM_Consumable_GoblinPack" } })
    local ids = {}
    for _, o in ipairs(order) do ids[#ids + 1] = o.item:gsub("^ITEM_", "") end
    assert(table.concat(ids, ",") == "Sword_Bronze,Club_Stone,Consumable_GoblinPack,Resources_Stone,Consumable_Bread,Resources_Coarse_Animal_Fur,Resources_VaultCore",
        table.concat(ids, ","))
    local _, id = rpc("recover_grave")
    local r = run(id, 120)
    assert(r and r.ok and r.data.opened and r.data.count == 55, json.encode(r))
    assert(r.data.taken[1].item == "ITEM_Sword_Bronze" and r.data.taken[2].item == "ITEM_Club_Stone", json.encode(r.data.taken))
    -- 95 + 12 Stone: 4 fill his stack to the game's max (99), the other 8 a new slot
    assert(F.extra.ITEM_Resources_Stone == 107 and F.extra.ITEM_Consumable_GoblinPack == 17, json.encode(F.extra))
    assert(#r.data.left == 1 and r.data.left[1].item == "ITEM_Resources_VaultCore" and r.data.left[1].why == "too_heavy", json.encode(r.data.left))
    assert(r.data.detail == "I took 55 things from the grave: Bronze Sword, Stone Club, 15 Goblin Pack, 12 Stone, 7 Bread and 19 Coarse Fur. "
        .. "Too heavy to carry (I'm at 212 of 250): Vault Core still in the grave.", r.data.detail)
    assert(F.open_chest == nil and F.closed == 1, "the screen is closed after")
    assert(B.module("input").owner("container") == nil, "modal released")
    -- not emptied: the death stays unrecovered, and what it lost is what is still there
    local d = sk.death_memory()
    assert(d and not d.recovered and #d.lost == 1 and d.lost[1].item == "ITEM_Resources_VaultCore" and d.partial_how == "recover_grave", json.encode(d))
end)

-- live 2026-11-02 03:41: at his grave the detector targeted nothing from where he stopped; the next standing spots lay
-- 1.3 m from him ("near"), so he faced 3 s at each without moving (9 s) before one 1 m step and the press. A failed
-- face now goes to a spot he has to walk to, and the face is short (aim first, a nudge only after aim_s).
test("interact on a big thing: a failed face walks to a new spot, never re-faces from where he stands", function()
    reset()
    F.world.items, F.world.resources = {}, {}
    F.world.interactables = { { id = "grave_5", class = "BP_PlayerGravestone_C", name = "", prompt = "Take All", position = { 1, 30, 3 },
                                contents = { { item = "ITEM_Bronze_Sword", count = 1 } } } }
    local inv = B.module("inventory")
    local it0 = inv.interact_target
    local first, faced_at = nil, {}
    inv.interact_target = function(pawn)
        local p = F.move.position or F.me_pos or { 1, 2, 3 }
        first = first or (math.abs(p[2] - 30) < 3 and { p[1], p[2] }) or nil
        if not first or math.sqrt((p[1] - first[1]) ^ 2 + (p[2] - first[2]) ^ 2) < 1.4 then
            faced_at[#faced_at + 1] = { p[1], p[2] }
            return { none = true }
        end
        return it0(pawn)
    end
    local t0 = T
    local _, id = rpc("interact", { target = "grave_5" })
    local r = run(id, 60)
    inv.interact_target = it0
    assert(r and r.ok and (F.extra.ITEM_Bronze_Sword or 0) == 1, json.encode(r))
    -- one failed face (<= face_s 2 s) at the first stand, then a walk: well under the old 3 x 3 s in place
    assert(T - t0 <= 8, "arrive-to-press took " .. tostring(T - t0) .. " s")
end)

-- live 2026-11-02 04:22: a press on a Crafting Table opens its crafting screen; the verify read only containers, sleep,
-- conversations and the prompt, so it saw "nothing changed", pressed again (which shut the screen) and failed.
test("interact on a station: its screen opening is the change; one press, never a second that shuts it", function()
    reset()
    F.world.items, F.world.resources = {}, {}
    F.world.interactables = { { id = "bench_1", class = "BP_Crafting_StartingBench_C", name = "Crafting Table",
                                kind = "crafting_station", prompt = "Use", position = { 1, 30, 3 } } }
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function(log, opts)
        local det = inv.interact_target()
        if det and det.actor == "bench_1" then
            F.presses = (F.presses or 0) + 1
            if F.screen_owner == "bench_1" then F.screen_kind, F.screen_owner = nil, nil -- E again shuts it
            else F.screen_kind, F.screen_owner = "crafting", "bench_1" end
            return { ok = true, action = "IA_Interact" }
        end
        return p0(log, opts)
    end
    local _, id = rpc("interact", { target = "bench_1" })
    local r = run(id, 40)
    inv.press_interact = p0
    assert(r and r.ok and r.data.changed == "opened", json.encode(r))
    assert(F.presses == 1 and F.screen_owner == "bench_1", "one press, the screen left open: " .. tostring(F.presses))
end)

test("recover_grave / interact: a full bag leaves the rest (said, from the game's free slots); an emptied grave is recovered", function()
    local sk = open_grave(2, { ITEM_Resources_Stone = 10, ITEM_Consumable_GoblinPack = 2 })
    local _, id = rpc("recover_grave")
    local r = run(id, 120)
    assert(r and r.ok and r.data.count == 1 + 1 + 15 + 12, json.encode(r))
    assert(r.data.detail == "I took 29 things from the grave: Bronze Sword, Stone Club, 15 Goblin Pack and 12 Stone. "
        .. "My bag's full: 7 Bread, 19 Coarse Fur and Vault Core still in the grave.", r.data.detail)
    assert(not sk.death_memory().recovered and #sk.death_memory().lost == 3, json.encode(sk.death_memory()))
    -- nothing fits at all: a truthful failure, nothing claimed, the screen closed
    sk = open_grave(0, { ITEM_Resources_Stone = 10 })
    F.chests.grave_9.rows = { F.chests.grave_9.rows[2], F.chests.grave_9.rows[7] } -- only Fur and Bread (no stack of either)
    _, id = rpc("recover_grave")
    r = run(id, 60)
    assert(r and not r.ok and r.reason == "inventory_full" and r.data.detail:find("My bag's full: 7 Bread and 19 Coarse Fur still in the grave", 1, true)
        and F.open_chest == nil, json.encode(r))
    -- the brain's own path (interact on his grave) takes the same way; room for all: emptied, so recovered
    sk = open_grave(10)
    sk.W.carry = function() return nil end -- unreadable weight: slots alone
    F.move.position = { 1, 29, 3 }
    _, id = rpc("interact", { target = "grave_9" })
    r = run(id, 120)
    assert(r and r.ok and r.data.opened and r.data.count == 56 and #r.data.left == 0 and r.data.detail == "I took 56 things from the grave: Bronze Sword, "
        .. "Stone Club, 15 Goblin Pack, 12 Stone, 7 Bread, 19 Coarse Fur and Vault Core.", json.encode(r))
    assert(sk.death_memory() == nil, "emptied: recovered")
    -- someone else's grave that opens: never taken from
    sk = open_grave(10)
    sk.W.grave_owner = function() return false end
    F.move.position = { 1, 29, 3 }
    _, id = rpc("interact", { target = "grave_9" })
    r = run(id, 60)
    assert(r and r.ok and r.data.changed == "opened" and not r.data.opened and F.transfers == 0, json.encode(r))
    F.chests, F.open_chest, F.free_slots = nil, nil, nil
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

test("give: steps in front of him, drops, finds the NEW pile by his feet and says where (an older pile is not it)", function()
    reset()
    F.follow = "near" -- the follow stops at (3, 2.5): 1.5 m from Luis at (3, 4)
    local sk, inv = B.module("skills"), B.module("inventory")
    local drop0 = inv.drop
    inv.drop = function(log, what, count)
        local r = drop0(log, what, count)
        table.insert(F.world.items, { id = "wi_gift", class = "BP_WorldItem_C", name = "Oak Logs", item = "ITEM_Resources_Wood_Oak",
                                      count = count, position = { 3, 3.2, 3 }, dropped_by = "Claude" })
        return r
    end
    local _, id = rpc("give", { player = "Luis", item = "Oak Logs", count = 2 })
    local r = run(id, 30)
    inv.drop = drop0
    assert(r and r.ok and r.data.pile and r.data.pile.id == "wi_gift" and r.data.pile.dist_m == 0.8, json.encode(r))
    assert(r.data.detail == "I dropped 2 Oak Logs at your feet (0.8 m from you): pick them up.", r.data.detail)
    assert(r.data.picked_up == false and r.data.inventory_left == 6, json.encode(r.data))
    -- the spot: 1.9 m from him toward me (his facing unreadable in the fakes)
    assert(r.data.spot and math.abs(r.data.spot[1] - 3) < 1e-6 and math.abs(r.data.spot[2] - 2.1) < 1e-6, json.encode(r.data))
    -- seen by his feet, then gone (he took it): says he picked it up
    reset(); F.follow = "near"; F.dropped = nil
    local looks = 0
    local census0 = B.API.census_things
    B.API.census_things = function(r_m, ...)
        local rows = census0(r_m, ...)
        if F.dropped and r_m == 8 then -- give's pile looks (player_row reads at 150 m)
            looks = looks + 1
            if looks == 2 then rows[#rows + 1] = { category = "items", id = "wi_gift2", item = "ITEM_Resources_Wood_Oak", count = 2,
                                                   position = { 3, 3.5, 3 } } end
        end
        return rows
    end
    _, id = rpc("give", { player = "Luis", item = "Oak Logs", count = 2 })
    r = run(id, 80, 0.25) -- fast steps (0.25: exact in binary; the shared clock T stays exact for later tests)
    B.API.census_things = census0
    assert(r and r.ok and r.data.picked_up == true and r.data.detail:find("you picked them up", 1, true), json.encode(r))
    -- the pile never shows (the old Oak Logs pile 2.8 m from him is not it): still true, says so
    reset(); F.follow = "near"
    _, id = rpc("give", { player = "Luis", item = "Oak Logs", count = 2 })
    r = run(id, 30)
    assert(r and r.ok and r.data.pile_seen == false and r.data.detail:find("can't see them on the ground", 1, true), json.encode(r))
    -- pure helpers
    local sp = sk.give_spot({ 10, 10, 0 }, 90, nil, 1.2)
    assert(math.abs(sp[1] - 10) < 1e-6 and math.abs(sp[2] - 11.2) < 1e-6, "in front along his yaw")
    local rows = { { category = "items", id = "a", item = "X", count = 5, position = { 10, 10.5, 0 } },
                   { category = "items", id = "b", item = "X", count = 3, position = { 11, 10, 0 } } }
    local pl = sk.give_pile(rows, "X", { 10, 10, 0 }, { a = 5 })
    assert(pl.id == "b" and pl.count == 3 and pl.stacks == 1, "an unchanged older pile is skipped")
    pl = sk.give_pile(rows, "X", { 10, 10, 0 }, { a = 2 })
    assert(pl.id == "a" and pl.count == 6 and pl.stacks == 2, "a pile that grew counts its growth; every drop is its own item (live)")
    assert(sk.give_pile(rows, "X", { 30, 30, 0 }, {}) == nil, "too far from his feet")
    assert(sk._facing_off({ yaw = 90, position = { 0, 0, 0 } }, { 0, 5, 0 }) < 1e-6, "facing him")
    assert(math.abs(sk._facing_off({ yaw = -168, position = { 0, 0, 0 } }, { 5, 0, 0 }) - 168) < 1e-6, "facing away")
end)

test("give: unreadable counts fail truthfully before or after drop", function()
    local real_counts = B.API.counts
    for fail_at = 1, 3 do
        reset(); F.follow = "near"; F.dropped = nil
        local calls = 0
        B.API.counts = function()
            calls = calls + 1
            if calls >= fail_at then return nil end
            return real_counts()
        end
        local r, id = rpc("give", { player = "Luis", item = "Oak Logs", count = 2 })
        if not r then r = run(id, 40) end
        B.API.counts = real_counts
        assert(r and r.reason == "verification_failed" and r.data.detail:find("read my inventory"), json.encode(r))
        if fail_at <= 2 then assert(not F.dropped, "must not drop without a baseline")
        else assert(F.dropped, "post-drop failure must report uncertain verification") end
    end
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

test("death cause truth: a fatal row puts the cause and the bars in last_death at once; a death with no fatal says none", function()
    reset()
    _G.DW_LIFE = nil
    write(base .. "/vitals.jsonl", json.encode({ type = "survival", ts = T - 5, sustenance = { 11.5, 100 }, hydration = { 60.7, 100 },
                                                 endurance = { 86.8, 100 }, hp = 100 }) .. "\n")
    write(base .. "/vitals.jsonl", json.encode({ type = "fatal", ts = T - 1, fell_m = 31, status = {},
                                                 killed_by = { id = "Default__KillZVolume", class = "KillZVolume" }, at = { 48.3, 1741, -60.8 } }) .. "\n")
    B.step()
    local d = rpc("get_state").data.last_death
    assert(d and d.killed_by:find("kill zone", 1, true) and d.killed_by_class == "KillZVolume" and d.fell_m == 31, json.encode(d))
    assert(d.bars and d.bars.food == 12 and d.bars.water == 61 and d.bars.rest == 87, json.encode(d))
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0, fell_m = 41.2, at = { 48.6, 1740.4, -70.9 },
                                                 survival = { sustenance = { 11.4, 100 }, hydration = { 60.6, 100 }, endurance = { 86.8, 100 } } }) .. "\n")
    B.step()
    d = rpc("get_state").data.last_death
    assert(d.killed_by:find("kill zone", 1, true) and d.fell_m == 31 and d.bars.food == 11, json.encode(d))
    -- a later death with no fatal row: no cause is carried over from the fall
    write(base .. "/vitals.jsonl", json.encode({ type = "revive", ts = T + 5, hp = 100 }) .. "\n")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T + 100, hp = 0,
                                                 survival = { sustenance = { 0, 75 }, hydration = { 30, 75 }, endurance = { 50, 100 } } }) .. "\n")
    B.step()
    d = rpc("get_state").data.last_death
    assert(d and d.killed_by == nil and d.fell_m == nil and d.bars.food == 0 and d.bars.water == 40, json.encode(d))
    _G.DW_LIFE = nil
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

test("water: move ends the walk in the water 1.3 m off the shore stand (arrived, in_water) -> he uses it from there", function()
    -- live 2026-11-16 12:24:18Z (chain 122336): stuck on the way, a local plan took him into the pond from the side,
    -- move's wade rule said "arrived" 1.3 m from the stand, the episode's 0.8 m said no; three more go_tos each
    -- "arrived" at once, then too_far, twice
    reset()
    local sk = B.module("skills")
    local pond = { id = "BP_WaterVolume_C_UAID_2", class = "BP_WaterVolume_C", name = "Water Volume", kind = "interactable",
                   position = { 40, 40, -3 } }
    table.insert(F.world.interactables, pond)
    local mv = B.module("move")
    local sp0, st0 = mv.shore_point, mv.status
    mv.shore_point = function() return { ok = true, how = "channel", stand = { 35, 40, 1.5 }, edge = { 36, 40, 0 } } end
    mv.status = function()
        if F.move.mode == "go_to" then
            F.move.mode, F.move.position = "idle", { 36.3, 40, 0.2 }
            F.move.result = { status = "arrived", in_water = true, dist_m = 1.3 }
        end
        return { mode = F.move.mode, status = F.move.status, result = F.move.result, ticks = 1 }
    end
    local det0, sig0 = sk.W.detector, sk.W.press_signals
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    local used = false
    sk.W.detector = function() return { actor = pond.id, prompt = "Drink", class = pond.class } end
    inv.press_interact = function() used = true; return { ok = true } end
    sk.W.press_signals = function() return { sleeping = used } end
    local auto = F.auto_arrive
    F.auto_arrive = false
    local _, id = rpc("interact", { target = pond.id })
    local r = run(id, 80)
    F.auto_arrive = auto
    sk.W.detector, sk.W.press_signals, inv.press_interact, mv.shore_point, mv.status = det0, sig0, p0, sp0, st0
    assert(r and r.ok and used, json.encode(r))
end)

test("interact: a pond (water volume) -> walk to its shore and face the surface, not its deep origin", function()
    reset()
    local sk = B.module("skills")
    local pond = { id = "BP_WaterVolume_C_UAID_1", class = "BP_WaterVolume_C", name = "Water Volume", kind = "interactable",
                   position = { 40, 40, -3 } }
    table.insert(F.world.interactables, pond)
    local mv = B.module("move")
    local sp0 = mv.shore_point
    local asked
    -- the bank is 0.6 m above the surface: standing there is NOT "on top of" the thing
    mv.shore_point = function(log, w) asked = w; return { ok = true, how = "channel", stand = { 35, 40, 1.5 }, edge = { 36, 40, 0 },
                                                          alts = { { stand = { 36, 43, 1.5 }, edge = { 37, 42, 0 } } } } end
    local det0, sig0 = sk.W.detector, sk.W.press_signals
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    local used = false
    sk.W.detector = function()
        local p = F.move.position
        if math.abs(p[1] - 35) < 0.6 and math.abs(p[2] - 40) < 0.6 then return { actor = pond.id, prompt = "Drink", class = pond.class } end
        return { none = true }
    end
    inv.press_interact = function() used = true; return { ok = true } end
    sk.W.press_signals = function() return { sleeping = used } end -- any "something changed" signal
    local _, id = rpc("interact", { target = pond.id })
    local r = run(id, 40)
    sk.W.detector, sk.W.press_signals, inv.press_interact, mv.shore_point = det0, sig0, p0, sp0
    assert(asked and asked[1] == 40 and asked[3] == -3, "shore_point asked with the volume's position")
    local tg = F.move.target
    assert(math.abs(tg[1] - 35) < 0.01 and tg[2] == 40, "walked to the shore, not round the origin: " .. json.encode(tg))
    assert(r and r.reason ~= "too_far", json.encode(r)) -- reached and faced it (the water item itself is verified elsewhere)
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

test("interact: no progress toward the thing for no_progress_s -> path_blocked at once, with move's why (live 21:57, 101 s)", function()
    reset()
    local sk = B.module("skills")
    local ledge = { id = "ledge_npc_1", class = "BP_NPC_C", name = "Ledge Sage", kind = "npc", prompt = "Talk", position = { 20, 0, 3 },
                    InteractionCollider = { K2_GetComponentLocation = function() return { X = 2000, Y = 0, Z = 300 } end } }
    table.insert(F.world.interactables, ledge)
    local mv = B.module("move")
    local go0, status0 = mv.go_to, mv.status
    local calls = 0
    -- as live: every standing spot's go_to struggles ~15 s (stuck, backtrack, bug2) and then fails; 6 spots = 90 s
    local started
    mv.go_to = function(log, goal, opts)
        calls = calls + 1
        local result = go0(log, goal, opts)
        F.auto_arrive = false
        started = T
        return result
    end
    mv.status = function()
        if started and T - started < 15 then return { mode = "go_to" } end
        return { mode = "idle", result = { status = "failed", reason = "leader_above_jump_height" } }
    end
    local t0 = T
    local _, id = rpc("interact", { target = ledge.id })
    local r = run(id, 240, 0.5)
    mv.go_to, mv.status = go0, status0
    F.auto_arrive = true
    assert(r and not r.ok and r.reason == "path_blocked", json.encode(r))
    assert(T - t0 <= sk.cfg.no_progress_s + 6, "ended by the watchdog, not the 100 s bridge timeout: " .. (T - t0) .. " s")
    assert(r.data.why == "leader_above_jump_height" and tostring(r.data.detail):find("no closer", 1, true), json.encode(r.data))
end)

test("interact on the bed he is lying in: one press gets him up, verified by the resting area clearing", function()
    reset()
    local sk, inp = B.module("skills"), B.module("input")
    local bed = { id = "BP_Magic_SummonShelter_C_2", class = "BP_Magic_SummonShelter_C", name = "Summon Shelter",
                  kind = "resting_area", prompt = "Sleep", position = { 1, 3, 3 } }
    table.insert(F.world.interactables, bed)
    local lying = true
    local r0 = sk.W.resting_in
    sk.W.resting_in = function() return lying and bed.id or nil end
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    local mode0, modal0, observe0 = inp.input_mode, inp.modal, inp.observe_screens
    local native = assert(loadfile(REPO .. "/client_mod/scripts/inventory.lua"))()
    local action, subsystem = {}, {}
    native.pawn = function() return { InteractionManager = { InteractAction = action } } end
    native.U.valid = function(o) return o ~= nil end
    native.U.find_first = function(name) assert(name == "EnhancedInputLocalPlayerSubsystem"); return subsystem end
    native.U.short = function() return "IA_Interact" end
    local pressed = 0
    native.U.find_object = function(path)
        assert(path == native.IA_INTERACT_FN)
        return function(sub, ia, vec) assert(sub == subsystem and ia == action and vec.X == 1); pressed = pressed + 1; lying = false end
    end
    inp.input_mode = function() return lying and "DIM_Resting" or "DIM_Gameplay" end
    inp.modal = function() return lying and { kind = "mode", mode = "DIM_Resting" } or nil end
    local screen_reads = 0
    inp.observe_screens = function() screen_reads = screen_reads + 1; return {} end
    assert(inp.gate().mode == "DIM_Resting", "normal modal gate blocks resting mode")
    inv.press_interact = native.press_interact
    local r1, id = rpc("interact", { target = bed.id })
    local r = r1 or run(id, 10)
    sk.W.resting_in, inv.press_interact = r0, p0
    inp.input_mode, inp.modal, inp.observe_screens = mode0, modal0, observe0
    assert(r and r.ok and r.data.changed == "got_up" and pressed == 1, json.encode(r))
    assert(screen_reads == 0 and not inp.owner("screen"), "rest exit does not enter screen verification")
    assert(#F.move.calls == 0, "no walking to get up")
end)

-- HOLD interactions (an Anima Vent's siphon, InteractionType 1): live 2026-11-01 19:20Z the one-frame IA_Interact press
-- was never let go and he stood rooted at the vent. The press remembers a hold; the release is the manager's
-- InteractActionStop, sent once; a tap interaction never gets one; every skill job's end lets go.
test("hold interaction: the press remembers it, release_held lets go once with InteractActionStop", function()
    local native = assert(loadfile(REPO .. "/client_mod/scripts/inventory.lua"))()
    local press, stop, subsystem, sent = {}, {}, {}, {}
    local vent = { AnimaVentData = { DisplayName = "Air Anima Vent" } }
    local ic = { InteractionType = 1, InteractionPrompt = "Siphon", GetOwner = function() return vent end }
    native.pawn = function() return { InteractionManager = { InteractAction = press, InteractActionStop = stop },
                                      InteractableDetector = { CurrentInteractable = ic } } end
    native.U.valid = function(o) return o ~= nil end
    native.U.find_first = function() return subsystem end
    native.U.short = function(o) return o == vent and "BP_AnimaVent_C_1" or "IA" end
    native.U.find_object = function() return function(sub, ia) sent[#sent + 1] = ia end end
    rawset(_G, "DW_HELD_INTERACTION", nil)
    local r = native.press_interact(nil)
    local h = native.held_interaction()
    assert(r.ok and r.hold and sent[1] == press and h and h.name == "Air Anima Vent" and h.prompt == "Siphon", json.encode(h))
    local rr = native.release_held(nil, "test")
    assert(rr and rr.ok and sent[2] == stop and rr.released == "Air Anima Vent" and native.held_interaction() == nil, json.encode(rr))
    assert(native.release_held(nil, "again") == nil and #sent == 2, "no second release")
    ic.InteractionType = 0 -- a tap (a pickup): no hold remembered, no release ever sent
    native.press_interact(nil)
    assert(native.held_interaction() == nil and native.release_held(nil) == nil and #sent == 3, "a tap is never released")
    -- a hold pressed by another path (no bookkeeping): a still caller's scan finds him in the replicated
    -- PlayersCurrentlyInteracting of the detector's Hold target, and the release then works
    ic.InteractionType = 1
    local me = {}
    local pawn = { InteractionManager = { InteractAction = press, InteractActionStop = stop }, InteractableDetector = { CurrentInteractable = ic } }
    native.pawn = function() return pawn end
    native.U.short = function(o) return o == vent and "BP_AnimaVent_C_1" or (o == pawn and "me") or (o == me and "me") or "IA" end
    ic.PlayersCurrentlyInteracting = { ForEach = function(self, f) f(1, { get = function() return me end }) end }
    assert(native.held_interaction() == nil, "no scan: only what he pressed")
    local hs = native.held_interaction({ scan = true })
    assert(hs and hs.found and hs.name == "Air Anima Vent", json.encode(hs))
    local r2 = native.release_held(nil, "scan")
    assert(r2 and r2.ok and sent[#sent] == stop, json.encode(r2))
    ic.PlayersCurrentlyInteracting = { ForEach = function(self, f) end }
    assert(native.held_interaction({ scan = true }) == nil, "not in the list: not held")
end)

test("hold interaction: a skill job's end lets go of the hold it pressed", function()
    reset()
    local sk = B.module("skills")
    local bed = { id = "BP_Magic_SummonShelter_C_3", class = "BP_Magic_SummonShelter_C", name = "Summon Shelter",
                  kind = "resting_area", prompt = "Sleep", position = { 1, 3, 3 } }
    table.insert(F.world.interactables, bed)
    local lying = true
    local r0 = sk.W.resting_in
    sk.W.resting_in = function() return lying and bed.id or nil end
    local inv = B.module("inventory")
    local p0, rel0 = inv.press_interact, inv.release_held
    local released = 0
    inv.press_interact = function() lying = false; return { ok = true } end
    inv.release_held = function() released = released + 1; return { ok = true } end
    local r1, id = rpc("interact", { target = bed.id })
    local r = r1 or run(id, 10)
    sk.W.resting_in, inv.press_interact, inv.release_held = r0, p0, rel0
    assert(r and r.ok and released >= 1, json.encode(r) .. " released=" .. released)
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

local function stone(id, x, avail)
    return { id = id, class = "BP_Spawner_Stone_C", name = "Stone", kind = "gatherable", verb = "gather", item = "ITEM_Resources_Stone",
             available = avail, position = { x, 2.4, 3 } }
end

test("co-play 2026-11-01: the game highlights ANOTHER stone (overlapping) -> pressed at once and named; a picked spawner is said at once", function()
    reset()
    F.world.items = {} -- nothing else at his feet
    table.insert(F.world.resources, stone("stone_a", 1.8, true))
    table.insert(F.world.resources, stone("stone_b", 1.9, true))
    F.detector_override = { actor = "stone_b", class = "BP_Spawner_Stone_C", name = "Stone", item = "ITEM_Resources_Stone", prompt = "Collect" }
    local t0 = T
    local _, id = rpc("interact", { target = "stone_a" })
    local r = run(id, 60, 0.1)
    assert(r and r.ok and r.data.took == "stone_b" and r.data.detail:find("took it", 1, true) and r.data.gained.ITEM_Resources_Stone == 1, json.encode(r))
    assert(F.presses == 1 and T - t0 <= 3, "one press within 3 s: " .. (T - t0))
    -- fetch: the one he really took is the one listed as picked
    F.presses = 0
    _, id = rpc("fetch", { target = "stone_a" })
    r = run(id, 60, 0.1)
    assert(r and r.ok and r.data.picked[1] == "stone_b" and F.presses == 1, json.encode(r))
    -- the class family serves when neither reads an item (AshBranch_02 ~ AshBranch_03), never the generic world-item class
    local sk = B.module("skills")
    assert(sk._same_kind({ id = "a", class = "BP_Spawner_AshBranch_03_C" }, { actor = "b", class = "BP_Spawner_AshBranch_02_C" }))
    assert(not sk._same_kind({ id = "a", class = "BP_RuntimeSpawnedWorldItem_C" }, { actor = "b", class = "BP_RuntimeSpawnedWorldItem_C" }))
    assert(not sk._same_kind({ id = "a", item = "ITEM_Resources_Stone" }, { actor = "b", item = "ITEM_Resources_Wood_Ash" }))
    -- already picked (IsResourceAvailable false): said at once, with the nearest one that still has something
    reset()
    F.world.items = {}
    table.insert(F.world.resources, stone("stone_c", 1.8, false))
    table.insert(F.world.resources, stone("stone_d", 5, true))
    r = rpc("interact", { target = "stone_c" })
    assert(r and r.reason == "not_interactable" and r.data.why == "depleted" and r.data.others[1].id == "stone_d"
        and r.data.detail:find("already picked", 1, true) and F.presses == 0 and #F.move.calls == 0, json.encode(r))
    r = rpc("fetch", { target = "stone_c" })
    assert(r and r.data.why == "depleted", json.encode(r))
    _, id = rpc("fetch", { item = "Stone" }) -- by name: the picked one is skipped
    r = run(id, 60, 0.1)
    assert(r and r.ok and r.data.picked[1] == "stone_d", json.encode(r))
    -- the census still lists one whose actor is gone (taken a moment ago): said at once, never a 10 s look
    reset()
    F.world.items = {}
    table.insert(F.world.resources, stone("stone_gone", 1.8, true))
    local a0 = B.API.actor_of
    B.API.actor_of = function(t) if t.id == "stone_gone" then return nil, {} end return a0(t) end
    local t0 = T
    _, id = rpc("interact", { target = "stone_gone" })
    r = run(id, 60, 0.1)
    B.API.actor_of = a0
    assert(r and r.reason == "not_interactable" and r.data.why == "gone" and F.presses == 0 and T - t0 < 1, json.encode(r))
end)

test("co-play 2026-11-01: the WATER holds the prompt over a stick at the pond's edge -> he steps out to its far side and takes it", function()
    reset()
    F.world.items, F.world.resources = {}, {} -- (the fake's press takes the nearest row)
    table.insert(F.world.resources, stone("stone_w", 1.8, true))
    local sk = B.module("skills")
    local d0 = sk.W.detector
    local water = { actor = "BP_WaterVolume_C_UAID_1", class = "BP_WaterVolume_C", prompt = "Collect Water", secondary = "Fill Watering Can" }
    -- he stands in the water at x < 2.2; from the far (dry) side the game offers the stone
    sk.W.detector = function()
        local p = F.move.position or F.me_pos or { 1, 2, 3 }
        if p[1] < 2.2 then return water end
        return { actor = "stone_w", class = "BP_Spawner_Stone_C", name = "Stone", item = "ITEM_Resources_Stone", prompt = "Collect" }
    end
    local _, id = rpc("interact", { target = "stone_w" })
    local r = run(id, 80, 0.1)
    if not (r and r.ok) then sk.W.detector = d0 end
    assert(r and r.ok and r.data.gained.ITEM_Resources_Stone == 1, json.encode(r))
    assert(F.move.target and F.move.target[1] > 2.2, "stepped out to the far side: " .. json.encode(F.move.target))
    -- the water from every spot: a fast, specific refusal (the water's edge), never "targets BP_WaterVolume_C_..."
    reset()
    F.world.items = {}
    table.insert(F.world.resources, stone("stone_w", 1.8, true))
    sk.W.detector = function() return water end
    local t0 = T
    _, id = rpc("interact", { target = "stone_w" })
    r = run(id, 300, 0.1)
    sk.W.detector = d0
    assert(r and r.reason == "not_interactable" and r.data.why == "water_prompt" and r.data.detail:find("water's edge", 1, true)
        and not r.data.detail:find("BP_WaterVolume", 1, true), json.encode(r))
    assert(T - t0 <= sk.cfg.small_budget_s + 3, "bounded: " .. (T - t0))
end)

test("co-play 2026-11-01: a stick 3 m off is walked to straight (no local planner: ~10 s per plan, a 100 s timeout live)", function()
    reset()
    F.world.items = {}
    table.insert(F.world.resources, stone("stone_far", 4, true))
    local mv = B.module("move")
    local go0, opts_seen = mv.go_to, nil
    mv.go_to = function(log, goal, opts) opts_seen = opts_seen or opts; return go0(log, goal, opts) end
    local _, id = rpc("interact", { target = "stone_far" })
    local r = run(id, 60, 0.1)
    mv.go_to = go0
    assert(r and r.ok, json.encode(r))
    assert(opts_seen and opts_seen.local_plan == false, "straight walk: " .. json.encode(opts_seen or {}))
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

test("a fall: the death is remembered where he last stood (the grave's spot); go_to my_grave walks to the grave he saw", function()
    reset()
    F.move.position = { 1, 25, 3 }
    rpc("get_state")
    _G.DW_LAST_GROUND = { X = 100, Y = 2900, Z = 300, t = T - 3 } -- move.lua: his last step on the cliff top (cm)
    F.move.position = { 1, 22, -60 }                             -- the body ended 63 m below (live 2026-11-01 15:56)
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    local sk = B.module("skills")
    local d = sk.death_memory()
    assert(d and d.position[2] == 29 and d.position[3] == 3 and d.body_position and d.body_position[3] == -60, json.encode(d))
    -- the grave in sight binds to that death; go_to my_grave then walks to the grave itself, not the remembered spot
    F.move.position = { 1, 27, 3 }
    rpc("get_state")
    assert(sk.death_memory().grave_id == "grave_1", json.encode(sk.death_memory()))
    F.move.position = { 20, 40, 3 }
    local r0, id = rpc("go_to", { target = "my_grave" })
    local r = r0 or run(id, 10)
    assert(r and r.ok and F.move.target[2] == 30, "walked to the grave: " .. json.encode(F.move.target))
    -- a stale last step (a walk long before the death) is not used: the body's spot is
    reset()
    _G.DW_LAST_GROUND = { X = 100, Y = 2900, Z = 300, t = T - 120 }
    F.move.position = { 1, 22, -60 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    d = B.module("skills").death_memory()
    assert(d and d.position[3] == -60 and d.body_position == nil, json.encode(d))
    _G.DW_LAST_GROUND = nil
end)

test("a facing nudge is a step: never toward a lethal edge (aim only then)", function()
    local SK = assert(loadfile(REPO .. "/client_mod/scripts/skills.lua"))()
    local pushes, danger = 0, nil
    local pawn = { AddMovementInput = function() pushes = pushes + 1 end }
    local api = { aim_at = function() return true end, my_position = function() return { 0, 0, 0 } end,
                  module = function(n)
                      if n == "sense" then return { local_pawn = function() return pawn end } end
                      if n == "move" then return { unsafe_ahead = function() return danger end } end
                  end }
    SK.W.face(api, { 5, 0, 0 }, true)
    assert(pushes == 1, "a safe nudge pushes")
    danger = "a 40 m drop ahead"
    SK.W.face(api, { 5, 0, 0 }, true)
    assert(pushes == 1, "no push toward the edge")
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
    -- a death and respawn in between: that fall is not drain (11:19:45 read 41/min at 42% food)
    T = T + 30
    _G.DW_LIFE = { died_at = T - 5, respawned_at = T }
    F.survival.sustenance[1], F.survival.hydration[1] = 8, 17
    rpc("get_state")
    T = T + 60
    F.survival.sustenance[1], F.survival.hydration[1] = 5, 15
    s = rpc("get_state")
    _G.DW_LIFE = nil
    assert(s.data.vitals_rate.sustenance_per_min == 3 and s.data.vitals_rate.hydration_per_min == 2,
           json.encode(s.data.vitals_rate))
end)

test("vitals drain: a nap and one odd step are not his drain (upper median of the falls)", function()
    reset()
    local sk = B.module("skills")
    local r0 = sk.W.resting_in
    local lying = false
    sk.W.resting_in = function() return lying and "BP_Magic_SummonShelter_C_7" or nil end
    F.survival = { sustenance = { 90, 100 }, hydration = { 90, 100 }, endurance = { 40, 100 } }
    local function at(sus, hyd, dt) T = T + dt; F.survival.sustenance[1], F.survival.hydration[1] = sus, hyd; return rpc("get_state") end
    at(90, 90, 0)
    at(86, 85, 60)   -- awake: 4 food, 5 water a minute
    at(82, 80, 60)
    lying = true
    at(70, 64, 60)   -- napping: the clock runs fast
    at(58, 48, 60)
    lying = false
    at(54, 43, 60)
    at(20, 9, 30)    -- one step (a hit, a harness fixture): 68/min for one pair
    local s = at(16, 4, 60)
    sk.W.resting_in = r0
    assert(s.data.vitals_rate.sustenance_per_min == 4 and s.data.vitals_rate.hydration_per_min == 5,
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

test("queue restart command forwards try_once without force", function()
    local original, captured = loadfile, nil
    loadfile = function(path)
        assert(path:find("client_bridge.lua", 1, true))
        return function() return { restart_when_idle = function(opts) captured = opts; return { ok = false } end } end
    end
    local command = assert(load("local ARGS = {try_once = true}\n" .. read(REPO .. "/client_mod/commands/bridge_start.lua")))()
    command(function() end)
    loadfile = original
    assert(captured.immediate_only and not captured.force)
end)

test("immediate restart refuses busy without scheduling, idle starts a polling loop", function()
    reset()
    rpc("follow", { player = "Luis" })
    local old, count = _G.__dwc_bridge, H.next_handle
    local fresh = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    local opts = { root = REPO, dir = DIR, scripts = SCRIPTS, chat_events = base .. "/chat.jsonl",
                   vitals_events = base .. "/vitals.jsonl", move_events = base .. "/move.jsonl",
                   gather_events = base .. "/gather.jsonl", activity_events = base .. "/activity.jsonl",
                   jlog = H.log, immediate_only = true }
    local saved_why = rawget(_G, "why")
    _G.why = "sentinel"
    local legacy = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))()
    local pending = legacy.restart_when_idle({ no_loop = true })
    assert(pending.deferred and _G.why == "sentinel", "legacy busy must not mutate global why")
    local r = fresh.restart_when_idle(opts)
    assert(not r.ok and r.refused and r.why:find("follow"), json.encode(r))
    assert(H.next_handle == count and _G.__dwc_bridge == old and fresh.restart_poll == nil)
    rpc("stop")
    H.tick()
    assert(_G.__dwc_bridge == old, "no delayed restart after becoming idle")
    r = fresh.restart_when_idle(opts)
    assert(r.ok and r.started and H.next_handle > count and fresh._state().loop, "idle start must schedule polling")
    assert(not fresh.restart_poll and _G.why == "sentinel", "idle must not schedule a restart retry")
    _G.why = saved_why
    B = fresh
    assert(rpc("ping").ok)
    local saved = _G.__dwc_bridge
    _G.__dwc_bridge = { busy = function() error("unknown") end }
    local failed = assert(loadfile(REPO .. "/client_mod/scripts/client_bridge.lua"))().restart_when_idle(opts)
    assert(not failed.ok and failed.refused and failed.why:find("unavailable"))
    _G.__dwc_bridge = saved
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

test("recover_grave: the newest death's grave beats a nearer older one of his (live 2026-11-01 13:06)", function()
    reset()
    local sk = B.module("skills")
    sk.W.grave_owner = function() return true end
    local g1 = F.world.interactables[2]
    local newer = {}
    for k, v in pairs(g1) do newer[k] = v end
    newer.id, newer.position = "grave_new", { 1, 58, 3 }
    table.insert(F.world.interactables, newer)
    F.move.position = { 1, 58, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step() -- died at (1,58); grave_1 at (1,30) is an older grave of his
    F.move.position = { 1, 29, 3 } -- standing by the OLD one, the newest 29 m off
    local _, id = rpc("recover_grave")
    local r = run(id, 40)
    assert(r and (r.data.grave == "grave_new" or r.data.target == "grave_new"), json.encode(r))
    if r.ok then assert(r.data.newest == true and r.data.newest_grave == nil, json.encode(r.data)) end
end)

test("emptying a grave that matches no remembered death leaves the newest death remembered (live 2026-11-01 11:22)", function()
    reset()
    F.move.position = { 80, 80, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = T, hp = 0 }) .. string.char(10))
    B.step()
    -- grave_1 sits at (1,30): ~95 m from the only death, so it is some older grave, not this death's
    F.move.position = { 1, 29, 3 }
    local _, gid = rpc("interact", { target = "grave_1" })
    assert(run(gid, 30).ok)
    local g = rpc("get_state").data.graves_remembered
    assert(g and #g == 1 and g[1].position[1] == 80, "the newest death is still unrecovered: " .. json.encode(g))
end)

test("a death whose spot holds no grave of his any more is closed as gone (live 2026-11-01 21:54Z)", function()
    reset()
    local sk = B.module("skills")
    local gone_s = sk.GRAVE_GONE_S
    sk.GRAVE_GONE_S = 0
    F.move.position = { 80, 80, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = os.time() - 120, hp = 0 }) .. string.char(10))
    B.step()
    -- dead a minute or more ago, standing on the spot, grave_1 is 95 m off: two looks, then closed
    rpc("get_state"); rpc("get_state") -- (the list is built before the check: closed from the next read on)
    local g = rpc("get_state").data.graves_remembered
    assert(g == nil or #g == 0, "closed as gone: " .. json.encode(g))
    -- a death by a grave of his stays open
    sk.W.grave_owner = function() return true end
    F.move.position = { 1, 28, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = os.time() - 120, hp = 0 }) .. string.char(10))
    B.step()
    F.move.position = { 1, 27, 3 }
    rpc("get_state"); rpc("get_state")
    g = rpc("get_state").data.graves_remembered
    sk.GRAVE_GONE_S = gone_s
    assert(g and #g == 1 and g[1].position[2] == 28, "his grave in sight: the death stays: " .. json.encode(g))
end)

test("state: his carry weight from the game (overloaded = walk only), in the bag", function()
    reset()
    F.move.enc = { on = true, cur = 403.2, max = 400 }
    local b = rpc("get_state").data.bag
    F.move.enc = nil
    assert(b and b.weight == 403.2 and b.max_weight == 400 and b.encumbered == true, json.encode(b))
end)

test("death: items the game keeps (bDropOnDeath false) are not lost; a death with nothing else is no grave; the respawn bag corrects lost", function()
    reset()
    local sk = B.module("skills")
    _G.DW_KEEP_ON_DEATH = { ITEM_Resources_Wood_Oak = true } -- this fixture's oak "is kept"
    F.move.position = { 80, 80, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = os.time() - 5, hp = 0 }) .. string.char(10))
    B.step()
    local list = rpc("get_state").data.graves_remembered
    assert(list == nil or #list == 0, "only kept items on him: no grave: " .. json.encode(list))
    -- a death with something that drops, then the respawn bag still holds part of it
    _G.DW_KEEP_ON_DEATH = {}
    F.move.position = { 60, 60, 3 }
    rpc("get_state")
    write(base .. "/vitals.jsonl", json.encode({ type = "death", ts = os.time() - 3, hp = 0 }) .. string.char(10))
    B.step()
    list = rpc("get_state").data.graves_remembered
    assert(list and #list == 1 and list[1].lost_items == 8, json.encode(list))
    _G.DW_LIFE = _G.DW_LIFE or {}
    _G.DW_LIFE.respawned_at = os.time()
    rpc("get_state")
    list = rpc("get_state").data.graves_remembered
    _G.DW_KEEP_ON_DEATH = nil
    assert(list == nil or #list == 0, "the respawn bag still holds all of it: nothing was lost: " .. json.encode(list))
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

test("explore names its legs that fell short, and a death is not 'saw nothing' (forensics E2)", function()
    reset(); F.me_pos = nil; F.move.position = { 0, 0, 3 }; F.world.interactables = {}; F.world.resources = {}
    rpc("get_state")
    F.auto_arrive = false
    local short = "Walked 4 m in 9 s (0.4 m/s) from [0.00,0.00,3.00] to [4.00,0.00,3.00]; 6 m left (closest 6 m)"
    local r0, id = rpc("explore", { about = "lava", max_legs = 1, leg_m = 10 })
    assert(r0 == nil, "async: " .. json.encode(r0))
    T = T + 1; B.step() -- the first leg starts once the job owns the pawn
    assert(F.move.mode == "go_to" and #F.move.calls == 1, "one leg walking: " .. json.encode(F.move.calls))
    F.move.mode, F.move.result = "idle", { status = "failed", reason = "unreachable", trip = short }
    local n = run(id, 40)
    assert(n and n.reason == "nothing_in_range" and n.data.detail:find("6 m left", 1, true) and #n.data.trips == 1, json.encode(n))
    reset(); F.me_pos = nil; F.move.position = { 0, 0, 3 }; F.world.interactables = {}; F.world.resources = {}
    rpc("get_state")
    F.auto_arrive = false
    local _, id2 = rpc("explore", { about = "lava", max_legs = 3, leg_m = 10 })
    T = T + 1; B.step()
    F.move.mode, F.move.result = "idle", { status = "failed", reason = "companion_down", trip = short .. "; fell 30.2 m." }
    local d = run(id2, 40)
    assert(d and d.reason == "companion_down" and d.data.detail:find("went down", 1, true) and d.data.detail:find("fell 30.2 m", 1, true), json.encode(d))
end)

test("explore leaves out legs over a void (a cliff, the world's edge: live 05:44Z, a 34 m fall)", function()
    reset(); F.me_pos = nil; F.move.position = { 0, 0, 3 }; F.world.interactables = {}; F.world.resources = {}
    rpc("get_state")
    F.ground_at = function(p) return { ok = true, floor_z = (p[2] >= -1) and 0 or nil } end -- nothing south of y = -1
    local _, id = rpc("explore", { about = "lava", max_legs = 3, leg_m = 10 })
    local n = run(id, 40)
    F.ground_at = nil
    assert(n and n.reason == "nothing_in_range" and n.data.legs == 3, json.encode(n))
    for _, p in ipairs(n.data.trail or {}) do assert(p[2] >= -1, "a leg went over the void: " .. json.encode(n.data.trail)) end
    assert(n.data.detail:find("world's edge", 1, true), n.data.detail)
end)

test("explore: a thing that only shares a word with the ask is not a find, and is named when nothing is found", function()
    -- Rune Mysteries chain 20261116-065203: about "Air Altar or Rune Altar" ended at once on Rune Essence
    reset(); F.me_pos = nil; F.move.position = { 0, 0, 3 }; F.world.resources = {}
    F.world.interactables = { { id = "ess_1", class = "BP_RuneEssence_Node_C", name = "Rune Essence", kind = "interactable",
                                prompt = "Mine", position = { 6, 0, 3 } } }
    rpc("get_state")
    local r0, id = rpc("explore", { about = "Air Altar or Rune Altar", max_legs = 1, leg_m = 10 })
    assert(r0 == nil, "async, not already_in_sight: " .. json.encode(r0))
    local n = run(id, 40)
    assert(n and n.reason == "nothing_in_range", json.encode(n))
    assert(n.data.detail:find("here I see Rune Essence (shares a word with it, not the same thing)", 1, true), n.data.detail)
    local a = rpc("explore", { about = "rune essence or an altar" })
    assert(a.reason == "already_in_sight" and a.data.found.id == "ess_1", json.encode(a))
end)

test("explore that finds nothing says how far he looked and where he has gathered it before (farm chain run 9)", function()
    reset(); F.me_pos = nil; F.move.position = { 0, 0, 3 }; F.world.interactables = {}; F.world.resources = {}
    rpc("get_state")
    local t = os.time()
    _G.DW_NAVMEM = { gather_spots = {
        { item = "ITEM_Resources_Flax", name = "Flax", at = { 0, -300, -40 }, n = 10, picks = 10, ts = t - 5 * 3600 },
        { item = "ITEM_Resources_Stone", name = "Stone", at = { 5, 5, 0 }, n = 3, picks = 3, ts = t } } }
    local _, id = rpc("explore", { about = "flax", max_legs = 2, leg_m = 10 })
    local n = run(id, 40)
    _G.DW_NAVMEM = nil
    assert(n and n.reason == "nothing_in_range", json.encode(n))
    local d = n.data.detail
    assert(d:find("m walked, at most %d+ m from where I began, seeing about 40 m around%) and saw nothing matching 'flax'"), d)
    assert(n.data.farthest_m >= 10 and n.data.farthest_m <= 21, json.encode(n.data))
    assert(d:find("Flax you've gathered before: 10 about %d+ m N at %(0, %-300%), last %d%d:%d%dZ %(5.0 h ago%)"), d)
    assert(not d:find("Stone", 1, true), "only what matches 'flax': " .. d)
    local _, id2 = rpc("explore", { about = "lava", max_legs = 1, leg_m = 10 })
    local n2 = run(id2, 40)
    assert(n2 and n2.reason == "nothing_in_range" and not n2.data.detail:find("before", 1, true), json.encode(n2))
end)

test("interact: a grave beside a drop that killed him is reached from a spot clear of it (live 06:50:20Z)", function()
    reset()
    F.world.items, F.world.resources = {}, {}
    F.world.interactables = { { id = "grave_7", class = "BP_PlayerGravestone_C", name = "", prompt = "Take All", position = { 1, 30, 3 },
                                contents = { { item = "ITEM_Bronze_Sword", count = 1 } } } }
    F.move.position = { 1, 25, 3 }
    F.ground_at = function(p) return { ok = true, floor_z = p[3] - 0.9 } end
    F.auto_arrive = false
    local hz = { 1, 28.6, 2.1 } -- the last ground before the fall: between him and the grave
    local _, id = rpc("interact", { target = "grave_7" })
    for _ = 1, 3 do T = T + 1; B.step() end
    assert(F.move.mode == "go_to", "walking to the first spot: " .. json.encode(F.move))
    F.move.mode, F.move.result = "idle", { status = "failed", reason = "unreachable", why = "known_drop", hazard = hz,
        detail = "I stopped 2.8 m short of a drop that killed me 1 time(s)" }
    for _ = 1, 3 do T = T + 1; B.step() end
    local g = F.move.target
    assert(F.move.mode == "go_to" and g and math.sqrt((g[1] - hz[1]) ^ 2 + (g[2] - hz[2]) ^ 2) >= 2.5,
        "a second walk, to a spot clear of the drop: " .. json.encode(g))
    F.auto_arrive = true
    local r = run(id, 60)
    F.ground_at = nil
    assert(r and r.ok and (F.extra.ITEM_Bronze_Sword or 0) == 1, json.encode(r))
end)

-- ------------------------------------------------------------------ containers: deposit / withdraw (build design §5)
test("explore ignores function-word substrings", function()
    for _,query in ipairs({"a door, gate, stairs or opening leading out of the temple", "gap in the wall, gate or opening"}) do
        reset(); F.me_pos=nil; F.move.position={0,0,3}; F.world.resources={}; F.world.interactables={}
        table.insert(F.world.interactables,{id="ash_1",class="BP_Spawner_AshBranch_01_C",name="Ash Logs",kind="foliage",verb="gather",item="ITEM_Resources_Wood_Ash",position={5,0,3}})
        local immediate,id=rpc("explore",{about=query,max_legs=1,leg_m=10})
        if immediate then assert(immediate.reason=="nothing_in_range",json.encode(immediate)) else assert(id); local done=run(id,40); assert(done.reason=="nothing_in_range",json.encode(done)) end
    end
    reset(); F.me_pos=nil; F.move.position={0,0,3}; F.world.resources={}; F.world.interactables={}
    table.insert(F.world.interactables,{id="ash_1",class="BP_Spawner_AshBranch_01_C",name="Ash Logs",kind="foliage",verb="gather",position={5,0,3}})
    local hit=rpc("explore",{about="ash logs or something missing"})
    assert(hit.reason=="already_in_sight" and hit.data.found.id=="ash_1",json.encode(hit))
end)

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
    -- the reply names what went in and the walk there (main 2026-11-01: a player walks over to a chest 14 m off)
    assert(r.data.walked_m and r.data.walked_m >= 25 and tostring(r.data.detail):find("^Put 8 Oak Logs in the Wooden Chest %(I walked %d+ m to it%)%.$"),
        json.encode(r.data))
    assert(F.transfers == 2, "one press per stack (hotbar 3, bag 5): " .. tostring(F.transfers))
    assert(F.closed == 1 and F.open_chest == nil, "the screen is closed after the action")
    assert(B.module("input") == nil or B.module("input").owner("container") == nil, "modal released")
    _, id = rpc("take", { item = "stone", container = "chest_1", count = 1 })
    r = run(id, 80)
    assert(r and r.ok and r.data.count == 1 and F.extra.ITEM_Resources_Stone == 1 and r.data.contents, json.encode(r))
    assert(tostring(r.data.detail) == "Took 1 Stone out of the Wooden Chest.", json.encode(r.data)) -- already beside it: no walk words
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

test("store: a full stack of the same item is never the target: a free slot, a stack's room, else 'the crate is full'", function()
    -- live 2026-11-02: a Bronze Sword (max stack 1) was pressed onto the chest's own sword in slot 5; nothing moved
    local SW = { slot = 0, item = "ITEM_Weapon_Sword_Bronze", name = "Bronze Sword", count = 1, max_stack = 1 }
    chest_world(6, { SW })
    F.extra.ITEM_Weapon_Sword_Bronze = 1
    local _, id = rpc("store", { item = "ITEM_Weapon_Sword_Bronze", container = "chest_1" })
    local r = run(id, 80)
    assert(r and r.ok and r.data.count == 1 and F.transfers == 1, json.encode(r))
    local in_slot1
    for _, x in ipairs(F.chests.chest_1.rows) do if x.slot == 1 and x.item == SW.item then in_slot1 = x.count end end
    assert(in_slot1 == 1, "the sword went to the free slot 1: " .. json.encode(F.chests.chest_1.rows))
    -- a stack with room takes only its room; the rest goes to a free slot (98/100 Stone + 5 -> 100 and 3)
    chest_world(6, { { slot = 0, item = "ITEM_Resources_Stone", name = "Stone", count = 98, max_stack = 100 } })
    F.extra.ITEM_Resources_Stone = 5
    _, id = rpc("store", { item = "ITEM_Resources_Stone", container = "chest_1" })
    r = run(id, 80)
    assert(r and r.ok and r.data.count == 5 and F.transfers == 2 and r.data.inside_now == 103, json.encode(r))
    -- every slot taken and its own stack full: "the crate is full", no press, the screen closed
    chest_world(1, { { slot = 0, item = "ITEM_Weapon_Sword_Bronze", name = "Bronze Sword", count = 1, max_stack = 1 } })
    F.extra.ITEM_Weapon_Sword_Bronze = 1
    _, id = rpc("store", { item = "ITEM_Weapon_Sword_Bronze", container = "chest_1" })
    r = run(id, 80)
    assert(r and r.reason == "container_full" and F.transfers == 0 and F.open_chest == nil, json.encode(r))
    assert(r.data.detail:find("Wooden Chest is full", 1, true) and r.data.detail:find("its one slot is taken and its .- stack is full, so it stays with me%.$"), r.data.detail)
    -- a stack whose max the item doesn't say and that takes nothing: the next slot, once, before "nothing moved"
    chest_world(6, { { slot = 0, item = "ITEM_Weapon_Sword_Bronze", name = "Bronze Sword", count = 1 } })
    F.extra.ITEM_Weapon_Sword_Bronze, F.slot_noop = 1, { [0] = true }
    _, id = rpc("store", { item = "ITEM_Weapon_Sword_Bronze", container = "chest_1" })
    r = run(id, 80)
    assert(r and r.ok and r.data.count == 1 and F.transfers == 2, json.encode(r))
    -- his reflex drinks one while the deposit is in flight: read on the crate's side, it went (live 04:30Z: 25 Clean
    -- Water moved and the reply said "nothing moved")
    chest_world(6, {})
    F.extra.ITEM_Consumable_Water_Clean, F.eat_during = 10, "ITEM_Consumable_Water_Clean"
    _, id = rpc("store", { item = "ITEM_Consumable_Water_Clean", container = "chest_1", count = 5 })
    r = run(id, 80)
    assert(r and r.ok and r.data.count == 5 and r.data.inside_now == 5 and F.transfers == 1, json.encode(r))
    F.extra.ITEM_Consumable_Water_Clean, F.eat_during = nil, nil
    F.extra.ITEM_Weapon_Sword_Bronze, F.slot_noop, F.chests, F.open_chest = nil, nil, nil, nil
end)

test("store: the same store again while it runs joins it ('I was already doing that'), never restarts it", function()
    chest_world()
    local _, id1 = rpc("store", { item = "Oak Logs", container = "chest_1" })
    T = T + 0.5; B.step()
    local now, id2 = rpc("store", { item = "oak logs", container = "chest_1" })
    assert(now == nil, "no answer yet: it joined the running store " .. json.encode(now))
    local r1, r2
    for _ = 1, 120 do
        T = T + 0.5; B.step()
        local msgs = drain()
        r1, r2 = r1 or result_of(msgs, id1), r2 or result_of(msgs, id2)
        if r1 and r2 then break end
    end
    assert(r1 and r1.ok and r1.data.count == 8 and F.transfers == 2, json.encode(r1))
    assert(r2 and r2.ok and r2.data.joined and r2.data.count == 8 and r2.data.detail:find("^I was already doing that: Put 8 Oak Logs"), json.encode(r2))
    F.chests, F.open_chest = nil, nil
end)

test("store/take: a container named by what it is ('chest', 'the Wooden Chest', 'storage'); none -> the storage that is near", function()
    -- live 07:39Z: "crate" with his Crate 1 m off -> "I can't see that chest anywhere near me"
    for _, name in ipairs({ "chest", "the Wooden Chest", "storage", "Chests" }) do
        chest_world()
        local _, id = rpc("store", { item = "Oak Logs", container = name, count = 1 })
        local r = run(id, 80)
        assert(r and r.ok and r.data.container == "chest_1", name .. ": " .. json.encode(r))
    end
    chest_world()
    local r = rpc("store", { item = "Oak Logs", container = "crate" })
    assert(r.reason == "unknown_target" and r.data.detail:find("I can't see a crate near me; the storage near me: Wooden Chest", 1, true), json.encode(r))
    F.chests, F.open_chest = nil, nil
end)

test("store: the copy in his hand stays (the game won't chest an equipped item); the reply says he kept it", function()
    -- live 2026-11-02: store Bronze Shield with one in the bag and one held -> "only 1 went" (verification_failed)
    chest_world()
    F.extra.ITEM_Shield_Bronze = 1
    F.held_left = { item = "ITEM_Shield_Bronze", name = "Bronze Shield", durability = 1018 }
    local _, id = rpc("store", { item = "ITEM_Shield_Bronze", container = "chest_1" })
    local r = run(id, 80)
    assert(r and r.ok and r.data.count == 1 and r.data.kept_held == 1 and F.transfers == 1, json.encode(r))
    assert(tostring(r.data.detail):find("I kept the one in my hand.", 1, true), json.encode(r.data))
    -- only the held one left: a truthful refusal before any walk, naming the hand
    chest_world()
    F.extra.ITEM_Shield_Bronze = nil
    F.held_left = { item = "ITEM_Shield_Bronze", name = "Bronze Shield", durability = 1018 }
    r = rpc("store", { item = "ITEM_Shield_Bronze", container = "chest_1" })
    assert(r.reason == "not_enough_resources" and r.data.held == 1 and r.data.detail:find("the one in my hand", 1, true), json.encode(r))
    r = rpc("store", { item = "ITEM_Shield_Bronze", container = "chest_1", count = 2 })
    assert(r.reason == "not_enough_resources" and r.data.detail:find("in my hand", 1, true), json.encode(r))
    F.held_left, F.chests, F.open_chest = nil, nil, nil
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
    setmetatable(fake_input, { __index = B.module("input") })
    local mod0 = B.API.module
    B.API.module = function(n) if n == "input" then return fake_input end return mod0(n) end
    _, id = rpc("interact", { target = "npc_1" })
    r = run(id, 60)
    B.API.module = mod0
    sk.W.conversation_npc, inv.press_interact = cv0, p0
    assert(r and r.reason == "not_implemented" and r.data.why == "conversation" and r.data.detail:find("can't hold conversations")
        and r.data.detail:find("goodbye") and cancels == 2 and F.presses == 1, json.encode(r) .. " cancels=" .. cancels)
end)

test("unequip {item} reaches skills' verified unequip (not the bridge's slot-only route)", function()
    reset()
    local inv = B.module("inventory")
    local eq0, un0 = inv.equip_state, inv.unequip
    local held = true
    local unequipped_slot
    inv.equip_state = function(log, item) return { ok = true, data = held and { held = "right", item_id = "ITEM_Tool_Axe_Bronze" } or {} } end
    inv.unequip = function(log, slot) unequipped_slot = slot; held = false; return { ok = true, data = {} } end
    local r, id = rpc("unequip", { item = "Bronze Hatchet" })
    if not r then r = run(id, 20) end
    inv.equip_state, inv.unequip = eq0, un0
    assert(r and r.ok and unequipped_slot == "HeldRight", json.encode(r) .. " slot=" .. tostring(unequipped_slot))
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

-- ------------------------------------------------------------------ collect_water (DISCOVERIES "Drinkable water")
local function water_world()
    reset()
    F.world.items, F.world.resources = {}, {}
    local w = { id = "BP_WaterVolume_NoSlow_C_1", class = "BP_WaterVolume_NoSlow_C", name = "Water Volume", kind = "interactable",
                prompt = "Collect Water", position = { 50, 2, 3 } }
    w.WaterItemData = { id = "ITEM_Consumable_Water_Dirty" }
    table.insert(F.world.interactables, w)
    local inv = B.module("inventory")
    local p0 = inv.press_interact
    inv.press_interact = function(log)
        local det = inv.interact_target()
        if det and det.actor == w.id and not F.water_dead then
            F.presses = (F.presses or 0) + 1
            F.extra.ITEM_Consumable_Water_Dirty = (F.extra.ITEM_Consumable_Water_Dirty or 0) + 1
            return { ok = true }
        end
        return p0(log)
    end
    return w, function() inv.press_interact = p0 end
end

test("collect_water: the nearest water, 3 presses, each verified by the Dirty Water it adds", function()
    local w, restore = water_world()
    local _, id = rpc("collect_water", { count = 3 })
    local r = run(id, 120)
    restore()
    assert(r and r.ok and r.data.count == 3 and r.data.item == "ITEM_Consumable_Water_Dirty" and F.presses == 3, json.encode(r))
end)

test("collect_water: a water named as the model saw it but not found by that name: the nearest water, said so (live 22:11:39Z)", function()
    local w, restore = water_world()
    local _, id = rpc("collect_water", { count = 1, target = "Water Volume" })
    local r = run(id, 60)
    restore()
    assert(r and r.ok and r.data.count == 1 and r.data.asked_for == "Water Volume" and r.data.detail:find("nearest water", 1, true), json.encode(r))
end)

test("collect_water: stopped by the water's edge 1.9 m from the surface still counts as there (2D reach)", function()
    local w, restore = water_world()
    local mv = B.module("move")
    local go0 = mv.go_to
    mv.go_to = function(log, goal, opts) -- move's water avoidance halts him on the bank, short of the wet spot
        local r = go0(log, goal, opts)
        F.auto_arrive = false
        F.move.position = { 48.1, 2, 3 }
        F.move.mode, F.move.result = "idle", { status = "failed", reason = "water_ahead" }
        return r
    end
    local _, id = rpc("collect_water", {})
    local r = run(id, 120)
    mv.go_to = go0
    F.auto_arrive = true
    restore()
    assert(r and r.ok and r.data.count == 1, json.encode(r))
end)

test("collect_water: truthful failures (no water near, the water doesn't take, a partial count)", function()
    reset()
    F.world.interactables = {}
    local r = rpc("collect_water", {})
    assert(r.reason == "nothing_in_range" and r.data.detail:find("water"), json.encode(r))
    local w, restore = water_world()
    local sk = B.module("skills")
    local det0 = sk.W.detector
    sk.W.detector = function() return { actor = "BP_Rock_C_9", name = "Rock" } end
    local _, id = rpc("collect_water", {})
    r = run(id, 200)
    sk.W.detector = det0
    assert(r and r.reason == "not_interactable" and r.data.detail:find("water doesn't take") and r.data.detail:find("Rock"), json.encode(r))
    -- 2 come in, then the press stops working: a partial result, never a claimed 3
    local n = 0
    local inv = B.module("inventory")
    local pi = inv.press_interact
    inv.press_interact = function(log) n = n + 1; if n > 2 then F.water_dead = true end; return pi(log) end
    _, id = rpc("collect_water", { count = 3 })
    r = run(id, 300)
    inv.press_interact, F.water_dead = pi, nil
    restore()
    assert(r and r.ok and r.data.partial and r.data.count == 2 and r.data.detail:find("2 of 3"), json.encode(r))
end)

-- ------------------------------------------------------------------ run
test("collect_water: unrelated inventory gains never count as water", function()
    local w, restore = water_world()
    local inv, mv = B.module("inventory"), B.module("move")
    local remember, learned = mv.remember_water_spot, 0
    mv.remember_water_spot = function(...) learned = learned + 1; if remember then return remember(...) end end
    inv.press_interact = function()
        F.extra.UNRELATED_LOOT = (F.extra.UNRELATED_LOOT or 0) + 2
        return { ok = true }
    end
    local _, id = rpc("collect_water", {})
    local r = run(id, 240)
    mv.remember_water_spot = remember; restore()
    assert(r and not r.ok and r.reason == "verification_failed" and learned == 0, json.encode(r))
end)

test("collect_water: larger unrelated gains cannot replace its source-derived output", function()
    local w, restore = water_world()
    local inv = B.module("inventory")
    local press = inv.press_interact
    inv.press_interact = function(log)
        F.extra.UNRELATED_LOOT = (F.extra.UNRELATED_LOOT or 0) + 2
        return press(log)
    end
    local _, id = rpc("collect_water", {})
    local r = run(id, 150)
    restore()
    assert(r and r.ok and r.data.item == w.WaterItemData.id and r.data.count == 1, json.encode(r))
end)

test("collect_water: matching gains during approach are outside the accepted-press baseline", function()
    local w, restore = water_world()
    local inv, mv = B.module("inventory"), B.module("move")
    local go = mv.go_to
    mv.go_to = function(...)
        F.extra[w.WaterItemData.id] = (F.extra[w.WaterItemData.id] or 0) + 4
        return go(...)
    end
    inv.press_interact = function() return { ok = true } end
    local _, id = rpc("collect_water", {})
    local r = run(id, 240)
    mv.go_to = go; restore()
    assert(r and not r.ok and r.reason == "verification_failed", json.encode(r))
end)

test("collect_water: unreadable source identity and changed detector output fail before pressing", function()
    for _, changed in ipairs({ false, true }) do
        local w, restore = water_world()
        local sk = B.module("skills")
        local detector = sk.W.detector
        if changed then
            local other = { id = "other_water", class = w.class, prompt = w.prompt, name = "Other source",
                kind = w.kind, position = w.position, WaterItemData = { id = "OTHER_WATER_OUTPUT" } }
            table.insert(F.world.interactables, other)
            sk.W.detector = function() return { actor = other.id, prompt = other.prompt } end
        else w.WaterItemData = nil end
        local r, id = rpc("collect_water", {})
        r = r or run(id, 150)
        sk.W.detector = detector; restore()
        assert(r and not r.ok and r.reason == "verification_failed" and (F.presses or 0) == 0, json.encode(r))
    end
end)

test("collect_water: inventory read failure cannot verify a press", function()
    for _, after_press in ipairs({ false, true }) do
        local w, restore = water_world()
        local inv = B.module("inventory")
        local list, press = inv.list, inv.press_interact
        local bad = function() return { ok = false, reason = "inventory unavailable" } end
        if after_press then inv.press_interact = function(log) local r = press(log); inv.list = bad; return r end
        else inv.list = bad end
        local r, id = rpc("collect_water", {})
        r = r or run(id, 150)
        inv.list = list; restore()
        assert(r and not r.ok and r.reason == "verification_failed" and r.data.why == "inventory_unavailable", json.encode(r))
    end
end)

test("collect_water: later source-data loss preserves the earlier verified partial count", function()
    local w, restore = water_world()
    local inv = B.module("inventory")
    local press = inv.press_interact
    inv.press_interact = function(log) local r = press(log); w.WaterItemData = nil; return r end
    local _, id = rpc("collect_water", { count = 2 })
    local r = run(id, 150)
    restore()
    assert(r and r.ok and r.data.partial and r.data.count == 1 and r.data.wanted == 2
        and r.data.why == "water_output_unknown", json.encode(r))
end)

test("collect_water: actual same-output sources survive the final result and shore learning", function()
    for _, multiple in ipairs({ false, true }) do
        local w, restore = water_world()
        local other = { id = "alternate_water", class = w.class, prompt = w.prompt, name = "Alternate source",
            kind = w.kind, position = { 51, 2, 3 }, WaterItemData = w.WaterItemData }
        table.insert(F.world.interactables, other)
        local sk, inv, mv = B.module("skills"), B.module("inventory"), B.module("move")
        local detector, remember = sk.W.detector, mv.remember_water_spot
        local presses, remembered = 0, {}
        sk.W.detector = function()
            local source = multiple and presses > 0 and w or other
            return { actor = source.id, prompt = source.prompt }
        end
        inv.press_interact = function()
            presses = presses + 1
            F.extra[w.WaterItemData.id] = (F.extra[w.WaterItemData.id] or 0) + 1
            return { ok = true }
        end
        mv.remember_water_spot = function(log, source, here) remembered[#remembered + 1] = source end
        local _, id = rpc("collect_water", { count = multiple and 2 or 1 })
        local r = run(id, 200)
        sk.W.detector, mv.remember_water_spot = detector, remember; restore()
        assert(r and r.ok and remembered[1][1] == other.position[1], json.encode(r))
        if multiple then
            assert(#r.data.sources == 2 and remembered[2][1] == w.position[1], json.encode(r))
            assert(r.data.target ~= w.id and r.data.target ~= other.id, json.encode(r))
        else assert(r.data.target == other.id and r.data.sources[1].target == other.id, json.encode(r)) end
    end
end)

test("collect_water: partial no-gain timeout names the actual stopped source", function()
    local w, restore = water_world()
    local other = { id = "stopped_alternate", class = w.class, prompt = w.prompt, name = "Alternate source",
        kind = w.kind, position = { 51, 2, 3 }, WaterItemData = w.WaterItemData }
    table.insert(F.world.interactables, other)
    local sk, inv = B.module("skills"), B.module("inventory")
    local detector, presses = sk.W.detector, 0
    sk.W.detector = function()
        local source = presses == 0 and w or other
        return { actor = source.id, prompt = source.prompt }
    end
    inv.press_interact = function()
        presses = presses + 1
        if presses == 1 then F.extra[w.WaterItemData.id] = (F.extra[w.WaterItemData.id] or 0) + 1 end
        return { ok = true }
    end
    local _, id = rpc("collect_water", { count = 2 })
    local r = run(id, 240)
    sk.W.detector = detector; restore()
    assert(r and r.ok and r.data.partial and r.data.count == 1 and r.data.target == w.id
        and r.data.sources[1].target == w.id and r.data.stopped_target == other.id, json.encode(r))
end)

test("terminal result is not replayed while owned child cleanup is retried", function()
    reset()
    local sk,mv,arb=B.module("skills"),B.module("move"),B.module("arbiter")
    local owner=arb.request(nil,{name="test:pending-result",level="command",uses_move=true,adopt=false})
    local started=mv.go_to(nil,{20,0,0},{owner_token=owner.token})
    local calls=0
    local job={kind="fetch",own="owner",token=owner.token,ep={moving=true,child_gen=started.gen,child_token=owner.token},
        step=function() calls=calls+1;return {ok=true,data={count=1}} end}
    local action=sk.run_job(B.API,{id="pending-result"},job).pending;action.started=T
    local original=mv.stop_owned;local attempts=0
    mv.stop_owned=function(...) attempts=attempts+1;if attempts==1 then return {ok=false,reason="verification_failed"} end;return original(...) end
    assert(action.poll(action)==nil and calls==1 and arb.owns_move(owner.token))
    local result=action.poll(action);mv.stop_owned=original
    assert(result and result.ok and calls==1 and not arb.owns_move(owner.token))
end)

for _, t in ipairs(tests) do

    local ok, err = pcall(t[2])
    if ok then print("PASS " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. ": " .. tostring(err)) end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
