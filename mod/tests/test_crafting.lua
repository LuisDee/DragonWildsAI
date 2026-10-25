-- Offline unit tests for body/crafting.lua (strict crafting emulation): every refusal path, exact
-- consumption and production, craft time, fuel, refunds on interrupt, item-based resolution, and the
-- generated body/recipe_data.lua (live game data). Runs the real bridge, skills tick loop and
-- inventory store against fake UE objects.
-- Usage: lua test_crafting.lua <empty_dir>   (tests/test_lua_crafting.py runs it with a tmp dir)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local H = dofile(here .. "/bridge_harness.lua")
package.path = here .. "/../?.lua;" .. package.path
local json = require("dkjson")
local bridge = require("bridge")
local skills = require("body.skills")
local inventory = require("body.inventory")
local crafting = require("body.crafting")

local dir = assert(arg[1] or os.getenv("DW_BRIDGE_DIR"), "usage: lua test_crafting.lua <dir>")
local IN, OUT = dir .. "/brain_to_body.jsonl", dir .. "/body_to_brain.jsonl"
local STATE = dir .. "/bot_state.json"

-- =============================================================================== fake UE
local F = {}
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
local function obj(full, t) t = t or {}; t._valid, t._full = true, full; return setmetatable(t, Obj) end
local LEVEL = "/Game/Maps/L_World.L_World:PersistentLevel."

local function actor(cls, n, x, y, z, t)
    local a = obj(cls .. " " .. LEVEL .. cls .. "_" .. n, t)
    a.loc = { X = x, Y = y, Z = z }
    a.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    a.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
    a.GetController = function(self) return self.controller end
    return a
end

local function tarray(list)
    return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end

local function station(cls, x, y, z, opts)
    opts = opts or {}
    F.n = F.n + 1
    local s = actor(cls, F.n, x, y, z, { bIsGhosted = opts.ghosted or false })
    if opts.lists then
        local recs = {}
        for _, p in ipairs(opts.lists) do recs[#recs + 1] = obj("RecipeData " .. p) end
        s.ProcessingStation = obj("ProcessingStationComponent " .. LEVEL .. cls .. "_" .. F.n .. ".ProcessingStation",
                                  { RecipesCache = tarray(recs) })
    end
    F.stations[cls] = F.stations[cls] or {}
    table.insert(F.stations[cls], s)
    return s
end

function FindAllOf(name)
    local out = {}
    if name == "BP_PlayerCharacter_C" then
        for _, p in ipairs(F.players) do out[#out + 1] = p end
        if F.puppet then out[#out + 1] = F.puppet end
    elseif F.stations[name] then
        for _, s in ipairs(F.stations[name]) do out[#out + 1] = s end
    end
    return #out > 0 and out or nil
end
function FindFirstOf() return nil end
function StaticFindObject() return nil end

local function make_puppet(x, y, z)
    local p = actor("BP_PlayerCharacter_C", 91, x, y, z)
    p.controller = obj("AIController " .. LEVEL .. "AIController_1", { stops = 0 })
    p.controller.StopMovement = function(self) self.stops = self.stops + 1 end
    p.controller.MoveToActor = function() return 2 end
    p.controller.MoveToLocation = function() return 2 end
    F.puppet = p
    return p
end

local fake_puppet = {
    get = function() return F.puppet end,
    ensure_ready = function() if F.puppet then return F.puppet, F.puppet.controller end; return nil, "no puppet" end,
    status = function() return {} end,
}

-- =============================================================================== test data
-- A tiny catalog in the generated recipe_data.lua shape (schema dw_recipe_data/1).
local P = function(id) return "/Game/Items/" .. id .. "." .. id end
local ORE, SALV, BAR = P("ITEM_IronOre"), P("ITEM_Salvage_Iron"), P("ITEM_IronBar")
local CHAR, PELLET, LOG = P("ITEM_Charcoal"), P("ITEM_FuelPellet"), P("ITEM_Oak")
local PLANK, AXE, HAMMER, COIN, GOLDCAPE = P("ITEM_Plank"), P("ITEM_IronAxe"), P("ITEM_Hammer"), P("ITEM_Coins"), P("ITEM_GoldCape")
local function data()
    return {
        schema = "dw_recipe_data/1", build = "test",
        interaction_ranges = { Short = 250, Medium = 350, Long = 650 },
        unlocked_snapshot = { player = "Zezima", ids = { "RECIPE_Plank" } },
        stations = {
            Furnace = { kind = "processing", name = "Furnace", classes = { "BP_Station_Smelter_C" }, range = "Medium",
                        rate = 5.0, fuels = { CHAR, PELLET }, vendor = false },
            ToolsMeleeBench = { kind = "crafting", name = "Blacksmith's Bench", classes = { "BP_Crafting_ToolsMeleeWeapons_C" },
                                range = "Medium", fuels = {}, vendor = false },
            CraftingTable = { kind = "crafting", name = "Crafting Table", classes = { "BP_Crafting_StartingBench_C" },
                              range = "Medium", fuels = {}, vendor = false },
            Fellhollow = { kind = "crafting", name = "Death's Exchange", classes = { "BP_NPC_Death_C" }, range = "Medium",
                           fuels = {}, vendor = true },
        },
        items = {
            [ORE] = { id = "ITEM_IronOre", name = "Iron Ore", max_stack = 99 },
            [SALV] = { id = "ITEM_Salvage_Iron", name = "Iron Salvage Pile", max_stack = 99 },
            [BAR] = { id = "ITEM_IronBar", name = "Iron Bar", max_stack = 99 },
            [CHAR] = { id = "ITEM_Charcoal", name = "Charcoal", max_stack = 99, fuel = 120 },
            [PELLET] = { id = "ITEM_FuelPellet", name = "Fuel Pellet", max_stack = 99, fuel = 360 },
            [LOG] = { id = "ITEM_Oak", name = "Oak Logs", max_stack = 99 },
            [PLANK] = { id = "ITEM_Plank", name = "Oak Plank", max_stack = 99 },
            [AXE] = { id = "ITEM_IronAxe", name = "Iron Logging Axe", max_stack = 1, durability = 1500 },
            [HAMMER] = { id = "ITEM_Hammer", name = "Hammer", max_stack = 1, durability = 300 },
            [COIN] = { id = "ITEM_Coins", name = "Coins", max_stack = 999 },
            [GOLDCAPE] = { id = "ITEM_GoldCape", name = "Golden Cape", max_stack = 1 },
        },
        recipes = {
            RECIPE_IronBar = { path = P("RECIPE_IronBar"), inputs = { { ORE, 3 } }, outputs = { { BAR, 1 } },
                               stations = { "Furnace" }, t = 0.5, tmax = 1.5, qm = 1.2, pt = { 8, 12 } },
            RECIPE_IronBar_Salvage = { path = P("RECIPE_IronBar_Salvage"), inputs = { { SALV, 9 } }, outputs = { { BAR, 1 } },
                                       stations = { "Furnace" }, t = 0.5, tmax = 1.5, qm = 1.2, pt = { 8, 12 } },
            RECIPE_IronAxe = { path = P("RECIPE_IronAxe"), inputs = { { BAR, 6 }, { LOG, 4 } }, outputs = { { AXE, 1 } },
                               stations = { "ToolsMeleeBench" }, t = 0.5, tmax = 1.5, qm = 1.2, pt = { 8, 12 } },
            RECIPE_Plank = { path = P("RECIPE_Plank"), inputs = { { LOG, 1 } }, outputs = { { PLANK, 2 } },
                             stations = { "CraftingTable" }, t = 0.5, tmax = 1.5, qm = 1.2, pt = { 8, 12 },
                             extra = { chance = 0.05, items = { { LOG, 1 } } } },
            RECIPE_GoldCape = { path = P("RECIPE_GoldCape"), inputs = { { COIN, 50 } }, outputs = { { GOLDCAPE, 1 } },
                                stations = { "Fellhollow" }, t = 0.5, tmax = 1.5, qm = 1.2, pt = { 8, 12 },
                                rep = { "Vendor.Fellhollow", 100 } },
        },
    }
end

local ALL = { RECIPE_IronBar = true, RECIPE_IronBar_Salvage = true, RECIPE_IronAxe = true, RECIPE_Plank = true,
              RECIPE_GoldCape = true }

-- =============================================================================== bridge io
local function write(path, s) local f = assert(io.open(path, "ab")); f:write(s); f:close() end
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
local function cmd(tool, args, top)
    seq = seq + 1
    local id = tool .. "_" .. seq
    local msg = { v = 1, type = "cmd", id = id, tool = tool, args = args or bridge.object() }
    for k, v in pairs(top or {}) do msg[k] = v end
    write(IN, bridge.encode(msg) .. "\n")
    bridge.poll()
    return drain(), id
end
local function result_of(msgs, id)
    for _, m in ipairs(msgs) do if m.type == "result" and m.id == id then return m end end
end
local function events_of(msgs, typ)
    local out = {}
    for _, m in ipairs(msgs) do if m.type == "event" and m.event.type == typ then out[#out + 1] = m.event end end
    return out
end
local function ticks(n)
    local all = {}
    for _ = 1, n do skills.tick(); for _, m in ipairs(drain()) do all[#all + 1] = m end end
    return all
end

local function setup(opts)
    opts = opts or {}
    F.players, F.stations, F.puppet, F.n = {}, {}, nil, 0
    inventory._reset(); skills._reset(); crafting._reset()
    os.remove(STATE)
    inventory.init({ log = H.log, state_path = STATE, max_stack = function() return 99 end })
    skills.register(bridge, H.log, { puppet = fake_puppet, no_loop = true })
    local mirror = opts.mirror
    if mirror == nil then mirror = { unlocked = ALL, reputations = { ["Vendor.Fellhollow"] = 500 }, source = "test" } end
    crafting.register(bridge, H.log, { skills = skills, puppet = fake_puppet, inventory = inventory, data = data(),
                                       mirror = mirror, unlocks = opts.unlocks, fuel = opts.fuel, extras = opts.extras })
    if opts.rng then crafting.configure({ rng = opts.rng }) end
    make_puppet(0, 0, 0)
    drain()
end

local function give(path, n, fields)
    local inst = { item_data_path = path, count = n, source = "test" }
    for k, v in pairs(fields or {}) do inst[k] = v end
    assert(inventory.add(inst))
end

-- =============================================================================== tests
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function snapshot() local s = {}; for k, v in pairs(inventory.summary()) do s[k] = v end; return s end
local function same(a, b, msg)
    for k, v in pairs(a) do eq(b[k], v, (msg or "") .. " " .. k) end
    for k, v in pairs(b) do eq(a[k], v, (msg or "") .. " " .. k) end
end

test("probe answers without acting; craft is listed in capabilities", function()
    setup()
    give(ORE, 3)
    station("BP_Station_Smelter_C", 200, 0, 0)
    local msgs, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 }, { probe = true })
    local r = result_of(msgs, id)
    eq(r.ok, true); eq(r.data.probe, true)
    eq(inventory.count(ORE), 3, "nothing consumed by a probe")
    eq(skills.current(), nil, "no action started")
    local m2, id2 = cmd("capabilities", {})
    local tools = {}
    for _, t in ipairs(result_of(m2, id2).data.tools) do tools[t] = true end
    assert(tools.craft and tools.craft_check and tools.recipes and tools.stations, "craft tools in capabilities")
end)

test("invalid args and unknown recipe/item", function()
    setup()
    local m, id = cmd("craft", {})
    eq(result_of(m, id).reason, "invalid_args")
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 0 })
    eq(result_of(m, id).reason, "invalid_args")
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1.5 })
    eq(result_of(m, id).reason, "invalid_args")
    m, id = cmd("craft", { recipe = "RECIPE_Nope", count = 1 })
    eq(result_of(m, id).reason, "unknown_target")
    m, id = cmd("craft", { item = "Dragon Platebody", count = 1 })
    eq(result_of(m, id).reason, "unknown_target")
end)

test("not_unlocked: a recipe missing from Luis's mirror is refused, nothing consumed", function()
    setup({ mirror = { unlocked = { RECIPE_Plank = true }, source = "test" } })
    give(ORE, 9)
    station("BP_Station_Smelter_C", 200, 0, 0)
    give(CHAR, 2)
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    local r = result_of(m, id)
    eq(r.ok, false); eq(r.reason, "not_unlocked"); eq(r.data.recipe, "RECIPE_IronBar")
    eq(r.data.checks.inputs, true, "other checks still reported"); eq(r.data.checks.station, true)
    eq(inventory.count(ORE), 9); eq(inventory.count(CHAR), 2)
end)

test("not_unlocked: vendor reputation below the recipe's requirement", function()
    setup({ mirror = { unlocked = ALL, reputations = { ["Vendor.Fellhollow"] = 20 }, source = "test" } })
    give(COIN, 100)
    station("BP_NPC_Death_C", 150, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_GoldCape", count = 1 })
    local r = result_of(m, id)
    eq(r.reason, "not_unlocked"); eq(r.data.detail, "vendor_reputation"); eq(r.data.need, 100); eq(r.data.have, 20)
end)

test("state_unavailable without a mirror; unlocks=all bypasses (debug)", function()
    setup({ mirror = false })
    give(LOG, 1)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_Plank", count = 1 })
    eq(result_of(m, id).reason, "state_unavailable")
    setup({ mirror = false, unlocks = "all" })
    give(LOG, 1)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_Plank", count = 1 })
    eq(result_of(m, id), nil, "async: accepted")
end)

test("missing_input: exact have/need per input, scaled by count", function()
    setup()
    give(ORE, 5)
    give(CHAR, 1)
    station("BP_Station_Smelter_C", 200, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 2 })
    local r = result_of(m, id)
    eq(r.reason, "missing_input"); eq(r.data.item, "ITEM_IronOre"); eq(r.data.have, 5); eq(r.data.need, 6)
    eq(#r.data.missing, 1); eq(r.data.crafts, 2)
    eq(inventory.count(ORE), 5, "nothing consumed")
    setup()
    give(BAR, 2)
    station("BP_Crafting_ToolsMeleeWeapons_C", 100, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_IronAxe", count = 1 })
    r = result_of(m, id)
    eq(r.reason, "missing_input"); eq(#r.data.missing, 2, "every missing input is listed")
    eq(r.data.missing[2].item, "ITEM_Oak"); eq(r.data.missing[2].have, 0); eq(r.data.missing[2].need, 4)
end)

test("missing_input: processing fuel (strict) when no accepted fuel is held", function()
    setup()
    give(ORE, 3)
    give(LOG, 10) -- logs are not a Furnace fuel
    station("BP_Station_Smelter_C", 200, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    local r = result_of(m, id)
    eq(r.reason, "missing_input"); eq(r.data.item, "ITEM_Charcoal"); eq(r.data.missing[1].fuel, true)
    eq(inventory.count(ORE), 3)
    -- fuel=off (debug) skips the fuel requirement
    setup({ fuel = "off" })
    give(ORE, 3)
    station("BP_Station_Smelter_C", 200, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    eq(result_of(m, id), nil, "accepted without fuel")
end)

test("wrong_station: no station of the right type; nearby other stations are listed", function()
    setup()
    give(ORE, 3); give(CHAR, 1)
    station("BP_Crafting_StartingBench_C", 150, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    local r = result_of(m, id)
    eq(r.reason, "wrong_station"); eq(r.data.need[1].station, "Furnace"); eq(r.data.need[1].name, "Furnace")
    eq(#r.data.near, 1); eq(r.data.near[1].station, "CraftingTable")
    eq(inventory.count(ORE), 3)
end)

test("wrong_station: ghost placements and stations whose live list excludes the recipe don't count", function()
    setup()
    give(ORE, 3); give(CHAR, 1)
    station("BP_Station_Smelter_C", 150, 0, 0, { ghosted = true })
    station("BP_Station_Smelter_C", 160, 0, 0, { lists = { P("RECIPE_Something_Else") } })
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    eq(result_of(m, id).reason, "wrong_station")
    -- a subclass with a different class word is a different station type
    setup()
    give(BAR, 6); give(LOG, 4)
    station("BP_Crafting_Cauldron_C", 100, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_IronAxe", count = 1 })
    eq(result_of(m, id).reason, "wrong_station")
end)

test("too_far: the nearest correct station is outside interaction range", function()
    setup()
    give(ORE, 3); give(CHAR, 1)
    station("BP_Station_Smelter_C", 1000, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    local r = result_of(m, id)
    eq(r.reason, "too_far"); eq(r.data.station, "Furnace"); eq(r.data.distance, 10); eq(r.data.max, 4.5)
    eq(r.data.position[1], 10, "position (m) for go_to")
    -- vertical: right above is not reachable either
    setup()
    give(ORE, 3); give(CHAR, 1)
    station("BP_Station_Smelter_C", 100, 0, 600)
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    eq(result_of(m, id).reason, "too_far")
end)

test("crafting station: waits the craft time, consumes exactly, produces exactly (instances)", function()
    setup()
    give(BAR, 7); give(LOG, 4); give(ORE, 2)
    give(HAMMER, 1, { durability = 120, max_durability = 300 })
    station("BP_Crafting_ToolsMeleeWeapons_C", 250, 0, 0)
    local before = snapshot()
    local m, id = cmd("craft", { recipe = "RECIPE_IronAxe", count = 1 })
    eq(result_of(m, id), nil, "async")
    eq(skills.current().kind, "craft")
    eq(inventory.count(BAR), 1, "inputs set aside at the start"); eq(inventory.count(LOG), 0)
    local msgs = ticks(2) -- 0.5 s: craft time 0.5 + 0.25 slack not reached
    eq(result_of(msgs, id), nil, "still crafting")
    eq(inventory.count(AXE), 0, "nothing produced before the craft time")
    msgs = ticks(2)
    local r = result_of(msgs, id)
    assert(r, "finished")
    eq(r.ok, true, json.encode(r))
    eq(r.data.recipe, "RECIPE_IronAxe"); eq(r.data.crafts, 1)
    eq(inventory.count(AXE), 1); eq(inventory.count(BAR), 1); eq(inventory.count(LOG), 0)
    eq(inventory.count(ORE), 2, "unrelated items untouched"); eq(inventory.count(HAMMER), 1, "tools are never consumed")
    local after = snapshot()
    after.ITEM_IronAxe = nil
    before.ITEM_IronBar, before.ITEM_Oak = 1, nil
    same(after, before, "only the recipe's items moved:")
    local axe
    for _, it in ipairs(inventory.list()) do if it.item_data_path == AXE then axe = it end end
    eq(axe.durability, 1500, "a fresh crafted instance has full durability"); eq(axe.source, "craft"); eq(axe.max_stack, 1)
    eq(#events_of(msgs, "task_done"), 1)
end)

test("craft time scales with count (model) and outputs scale exactly", function()
    setup()
    give(LOG, 5)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    local m, id = cmd("craft_check", { recipe = "RECIPE_Plank", count = 3 })
    local r = result_of(m, id)
    eq(r.ok, true); eq(r.data.plan.seconds, 0.72, "0.5 * 1.2^2"); eq(r.data.plan.outputs[1].count, 6)
    eq(inventory.count(LOG), 5, "craft_check consumes nothing")
    m, id = cmd("craft", { recipe = "RECIPE_Plank", count = 3 })
    local msgs = ticks(5)
    r = result_of(msgs, id)
    eq(r.ok, true); eq(inventory.count(LOG), 2); eq(inventory.count(PLANK), 6)
end)

test("processing station: fuel consumed by burn time, processing time waited", function()
    setup()
    give(ORE, 7); give(CHAR, 3)
    station("BP_Station_Smelter_C", 300, 0, 0)
    local m, id = cmd("craft_check", { recipe = "RECIPE_IronBar", count = 2 })
    local plan = result_of(m, id).data.plan
    eq(plan.kind, "processing"); eq(plan.seconds, 4, "2 x mean(8,12) / rate 5")
    eq(plan.fuel[1].item, "ITEM_Charcoal"); eq(plan.fuel[1].count, 1, "4 s of burn < 120 s per charcoal")
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 2 })
    local msgs = ticks(16) -- 4.0 s
    eq(result_of(msgs, id), nil, "still processing at 4.0 s (+0.25 s slack)")
    msgs = ticks(1)
    local r = result_of(msgs, id)
    eq(r.ok, true, json.encode(r))
    eq(inventory.count(ORE), 1); eq(inventory.count(CHAR), 2); eq(inventory.count(BAR), 2)
    eq(r.data.fuel[1].item, "ITEM_Charcoal"); eq(r.data.fuel[1].count, 1)
    -- a requested fuel is honoured
    setup()
    give(ORE, 3); give(CHAR, 1); give(PELLET, 1)
    station("BP_Station_Smelter_C", 300, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1, fuel = "Fuel Pellet" })
    msgs = ticks(10)
    r = result_of(msgs, id)
    eq(r.ok, true); eq(inventory.count(PELLET), 0); eq(inventory.count(CHAR), 1)
end)

test("interrupted mid-craft: every input and the fuel are refunded exactly", function()
    setup()
    give(ORE, 6, { level = 0 }); give(CHAR, 2)
    station("BP_Station_Smelter_C", 300, 0, 0)
    local before = snapshot()
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 2 })
    ticks(4)
    eq(inventory.count(ORE), 0, "set aside during the craft")
    local msgs = cmd("stop", {})
    msgs = msgs or {}
    local r = result_of(msgs, id)
    assert(r, "the craft replied")
    eq(r.reason, "interrupted")
    same(snapshot(), before, "refunded:")
    eq(inventory.count(BAR), 0, "nothing produced")
end)

test("moving away or losing the station mid-craft fails and refunds", function()
    setup()
    give(ORE, 3); give(CHAR, 1)
    local s = station("BP_Station_Smelter_C", 300, 0, 0)
    local before = snapshot()
    local m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    F.puppet.loc.X = -900
    local msgs = ticks(12)
    local r = result_of(msgs, id)
    eq(r.reason, "too_far"); eq(r.data.mid_craft, true)
    same(snapshot(), before, "refunded after moving away:")
    F.puppet.loc.X = 0
    m, id = cmd("craft", { recipe = "RECIPE_IronBar", count = 1 })
    s._valid = false
    msgs = ticks(12)
    r = result_of(msgs, id)
    eq(r.reason, "wrong_station"); eq(r.data.mid_craft, true)
    same(snapshot(), before, "refunded after the station vanished:")
end)

test("item-based craft: picks the recipe the bot can do; count = items wanted", function()
    setup()
    give(SALV, 18); give(CHAR, 1)
    station("BP_Station_Smelter_C", 200, 0, 0)
    local m, id = cmd("craft_check", { item = "Iron Bar", count = 2 })
    local r = result_of(m, id)
    eq(r.ok, true); eq(r.data.plan.recipe, "RECIPE_IronBar_Salvage"); eq(r.data.plan.crafts, 2)
    -- neither recipe possible: the closest refusal plus the alternatives
    setup()
    give(ORE, 1); give(CHAR, 1)
    station("BP_Station_Smelter_C", 200, 0, 0)
    m, id = cmd("craft", { item = "ITEM_IronBar", count = 1 })
    r = result_of(m, id)
    eq(r.reason, "missing_input"); eq(#r.data.alternatives, 1)
    -- by item: 3 planks wanted at 2 per craft -> 2 crafts
    setup()
    give(LOG, 3)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    m, id = cmd("craft_check", { item = "oak plank", count = 3 })
    r = result_of(m, id)
    eq(r.data.plan.crafts, 2); eq(r.data.plan.outputs[1].count, 4)
end)

test("extras: off by default; extras=roll adds them and verification still passes", function()
    setup()
    give(LOG, 1)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_Plank", count = 1 })
    local r = result_of(ticks(4), id)
    eq(r.ok, true); eq(inventory.count(LOG), 0); eq(r.data.extra, nil)
    setup({ extras = "roll", rng = function() return 0.01 end })
    give(LOG, 1)
    station("BP_Crafting_StartingBench_C", 100, 0, 0)
    m, id = cmd("craft", { recipe = "RECIPE_Plank", count = 1 })
    r = result_of(ticks(4), id)
    eq(r.ok, true, json.encode(r)); eq(inventory.count(LOG), 1, "the 5% extra log was rolled"); eq(inventory.count(PLANK), 2)
end)

test("equipped items are not inputs (a worn item is not in the bag)", function()
    setup()
    give(BAR, 6, {}); give(LOG, 4)
    local inst = inventory.add({ item_data_path = BAR, count = 1, max_stack = 1, equipped = "right", source = "test" })
    assert(inst)
    station("BP_Crafting_ToolsMeleeWeapons_C", 100, 0, 0)
    local m, id = cmd("craft", { recipe = "RECIPE_IronAxe", count = 1 })
    local r = result_of(ticks(4), id)
    eq(r.ok, true)
    local eqd = inventory.equipped_in("right")
    assert(eqd and eqd.item_data_path == BAR, "the equipped bar is still equipped")
end)

test("recipes and stations handlers (read-only)", function()
    setup()
    station("BP_Station_Smelter_C", 300, 0, 0)
    station("BP_Crafting_StartingBench_C", 2500, 0, 0)
    local m, id = cmd("recipes", { item = "Iron Bar" })
    local r = result_of(m, id)
    eq(r.ok, true); eq(r.data.total, 2); eq(r.data.recipes[1].stations[1], "Furnace"); eq(r.data.recipes[1].unlocked, true)
    m, id = cmd("recipes", { station = "Crafting Table" })
    eq(result_of(m, id).data.recipes[1].recipe, "RECIPE_Plank")
    m, id = cmd("stations", { radius = 30 })
    r = result_of(m, id)
    eq(#r.data.stations, 2); eq(r.data.stations[1].station, "Furnace"); eq(r.data.stations[1].in_reach, true)
    eq(r.data.stations[2].in_reach, false)
    m, id = cmd("recipes", {})
    eq(result_of(m, id).reason, "invalid_args")
end)

test("mirror: the catalog snapshot is the fallback when nobody is online", function()
    crafting._reset()
    crafting.configure({ data = data() })
    local m = crafting.snapshot_mirror()
    eq(m.source, "catalog_snapshot"); eq(m.unlocked.RECIPE_Plank, true); eq(m.unlocked.RECIPE_IronBar, nil)
    F.players = {}
    crafting.configure({ mirror = crafting.live_mirror() })
    eq(crafting.check_unlocked("RECIPE_Plank"), true)
    local ok, why = crafting.check_unlocked("RECIPE_IronBar")
    eq(ok, false); eq(why, "not_unlocked")
end)

test("generated recipe_data.lua: live game data, Iron Bar = 3 Iron Ore or 9 Iron Salvage Pile at the Furnace", function()
    crafting._reset()
    package.loaded["body.recipe_data"] = nil
    local D = require("body.recipe_data")
    eq(D.schema, "dw_recipe_data/1")
    local r = D.recipes.RECIPE_Process_IronBar
    assert(r, "iron bar recipe present")
    eq(#r.inputs, 1); eq(r.inputs[1][2], 3); eq(D.items[r.inputs[1][1]].name, "Iron Ore")
    eq(D.items[r.outputs[1][1]].name, "Iron Bar"); eq(r.outputs[1][2], 1)
    eq(r.stations[1], "Furnace"); eq(#r.stations, 1, "test stations are excluded")
    local fur = D.stations.Furnace
    eq(fur.kind, "processing"); eq(fur.classes[1], "BP_Station_Smelter_C"); eq(fur.name, "Furnace")
    local s = D.recipes.RECIPE_Process_Bar_Iron_From_Salvage
    eq(s.inputs[1][2], 9); eq(D.items[s.inputs[1][1]].name, "Iron Salvage Pile")
    -- every recipe's stations exist and every referenced item has a record
    local n = 0
    for rid, rec in pairs(D.recipes) do
        n = n + 1
        for _, sid in ipairs(rec.stations) do assert(D.stations[sid], rid .. " -> unknown station " .. sid) end
        for _, c in ipairs(rec.inputs) do assert(D.items[c[1]], rid .. " input without an item record") end
        for _, c in ipairs(rec.outputs) do assert(D.items[c[1]], rid .. " output without an item record") end
    end
    assert(n > 1000, "the full catalog: " .. n)
    crafting.configure({ data = D })
    local p = crafting.plan("RECIPE_Process_IronBar", 2, "Furnace")
    eq(p.inputs[1].count, 6); eq(p.outputs[1].count, 2); eq(p.kind, "processing")
    assert(p.fuel and #p.fuel.options >= 1, "the furnace burns fuel")
end)

assert(bridge.init({ dir = dir, log = H.log }))
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then print("ok   " .. t[1]) else failures = failures + 1; print("FAIL " .. t[1] .. ": " .. tostring(err)) end
end
print(string.format("%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)
