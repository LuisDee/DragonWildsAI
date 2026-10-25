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
    F.auto_arrive, F.aims, F.presses, F.uses, F.equips, F.pickup_where = true, 0, 0, 0, 0, nil
    _G.DW_PAUSE, _G.DWSkills, _G.DW_LIFE = nil, nil, nil
    local sk = B.module("skills")
    sk.W.grave_owner = function() return nil end
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

test("manifest: one entry per implemented tool, llm flags, schemas, legacy alias pickup -> fetch", function()
    reset()
    local r = rpc("capabilities")
    assert(r.ok and type(r.data.manifest) == "table", json.encode(r))
    local by = {}
    for _, e in ipairs(r.data.manifest) do by[e.name] = e end
    for _, t in ipairs(r.data.tools) do assert(by[t], "manifest lacks implemented tool " .. t) end
    for _, e in ipairs(r.data.manifest) do assert(has(r.data.tools, e.name), "manifest lists unimplemented " .. e.name) end
    for _, t in ipairs({ "fetch", "consume", "come_to", "recover_grave", "give", "interact", "follow", "stop", "go_to", "drop", "look" }) do
        assert(by[t] and by[t].llm == true, "llm tool " .. t)
        assert(by[t].args and by[t].args.type == "object", "schema " .. t)
        assert(type(by[t].description) == "string" and #by[t].description > 20, "description " .. t)
    end
    assert(by.fetch.moves == true and by.fetch.priority == "command" and by.fetch.timeout_s >= 100)
    assert(by.consume.args.required[1] == "item" and by.come_to.args.required[1] == "player")
    assert(by.recover_grave.args.properties ~= nil, "no-arg schema still has properties")
    assert(by.look.kind == "read" and by.drop.args.properties.at.enum[1] == "feet")
    assert(by.get_state and by.get_state.llm == false and by.ping.llm == false and by.census.llm == false)
    assert(not by.pickup and not by.attack and not by.gather, "tools the body lacks are absent")
    assert(r.data.aliases.pickup == "fetch", json.encode(r.data.aliases))
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
    assert(not has(r.data.tools, "fetch") and r.data.aliases.pickup == nil, "no alias to a missing tool")
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
    assert(r.reason == "in_bag" and r.data.offer == "move_to_hotbar" and r.data.detail:find("bag"), json.encode(r))
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

test("consume something lying nearby: fetch first, then drink it, one result", function()
    reset()
    F.me_pos = { 8, 8, 3 } -- the infusion lies 1.4 m away (Luis dropped it in front of him)
    local _, id = rpc("consume", { item = "Pumpkin Spice Infusion" })
    local r = run(id, 40)
    assert(r and r.ok and r.data.fetched == true and r.data.stat_rose == true and r.data.item == "ITEM_Consumable_PSI", json.encode(r))
    assert(F.presses == 1 and F.uses == 1)
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

-- ------------------------------------------------------------------ run
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then print("PASS " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. ": " .. tostring(err)) end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
