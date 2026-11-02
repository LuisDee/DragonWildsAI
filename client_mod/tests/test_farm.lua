-- Offline tests for client_mod/scripts/farm.lua: plot listing, signatures/changes, and whole tend jobs against a
-- fake world (frame pump, fake clock, walking pawn, farm slots whose state the "server" changes when the held
-- item's primary is pressed facing them or the interact key is pressed on them) with the REAL arbiter.
-- Run:  lua client_mod/tests/test_farm.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local T = 0
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWFarm, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    Wd = { pawn = { pos = { X = 0, Y = 0, Z = 0 } }, held = nil, inv = o.inv or { ITEM_Spade = 1, ITEM_Seeds = 3 }, xp = 0,
           plot = { id = "BP_FarmPlot_C_1#0", owner_id = "BP_FarmPlot_C_1", pos = o.plot_pos or { X = 800, Y = 0, Z = 0 },
                    soil = o.soil or "weeds", harvestable = o.harvestable or false, diseased = false, watered = false, fertilized = false,
                    weeds_grown = true, prompt = "Plot", digs_needed = o.digs or 1, digs = 0, stage_digs = o.stage_digs },
           cat = o.cat,
           water = o.water, modal = o.modal, presses = 0, injected = 0 }
end

local fake_move = {}
function fake_move.go_to(log, pos) Wd.goal = { X = pos[1] * 100, Y = pos[2] * 100, Z = 0 }; Wd.move_res = nil; return { ok = true } end
function fake_move.status() if Wd.move_res then return { mode = "idle", result = Wd.move_res } end; return { mode = Wd.goal and "goto" or "idle" } end
function fake_move.stop() Wd.goal = nil; return { ok = true } end
function fake_move.snapshot() return nil end
function fake_move.restore() return true end

local function step(dt)
    local g = Wd.goal
    if g then
        local p = Wd.pawn.pos
        if Wd.water then Wd.goal = nil; Wd.move_res = { status = "failed", reason = "no path" }; return end
        local d = d2(p, g)
        local s = 500 * dt
        if d <= s + 100 then p.X, p.Y = g.X - 100, g.Y; Wd.goal = nil; Wd.move_res = { status = "arrived" }
        else p.X, p.Y = p.X + (g.X - p.X) / d * s, p.Y + (g.Y - p.Y) / d * s end
    end
    local edge = Wd.tapped and not Wd.was_tapped -- one press per held tap (rising edge)
    Wd.was_tapped, Wd.tapped = Wd.tapped, nil
    if edge then
        local pl = Wd.plot
        if d2(Wd.pawn.pos, pl.pos) <= 250 then
            if Wd.held == "ITEM_Spade" and pl.soil == "weeds" then
                pl.digs = pl.digs + 1
                Wd.xp = Wd.xp + 3
                if pl.digs >= pl.digs_needed then pl.soil, pl.weeds_grown = "clear", false
                elseif pl.stage_digs and pl.digs % pl.stage_digs == 0 then pl.weeds_grown, pl.prompt = false, "Weeds " .. pl.digs end
            elseif Wd.held == "ITEM_Seeds" and pl.soil == "clear" then
                Wd.inv.ITEM_Seeds = Wd.inv.ITEM_Seeds - 1; pl.prompt = "Wheat (growing)"; Wd.xp = Wd.xp + 5
            end
        end
    end
end

local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local F = assert(loadfile(root .. "/client_mod/scripts/farm.lua"))()
F.clock = function() return T end
F.set_modules({ move = fake_move, arbiter = A })
local W = F.W
local PC = {}
W.pc = function() return PC end
W.pawn = function() return Wd.pawn end
W.loc = function(p) return { X = p.pos.X, Y = p.pos.Y, Z = 0 } end
W.dead = function() return false end
W.skills = function() return { { skill = "Farming", level = 1, xp = Wd.xp } } end
W.slots = function()
    local p = Wd.plot
    if p.gone then return {} end
    return { { id = p.id, owner_id = p.owner_id, pos = p.pos, soil = p.soil, harvestable = p.harvestable, diseased = p.diseased,
               watered = p.watered, fertilized = p.fertilized, weeds_grown = p.weeds_grown, prompt = p.prompt } }
end
W.counts = function()
    local c, l = {}, { ok = true, hotbar = {}, bag = {} }
    for k, v in pairs(Wd.inv) do if v > 0 then c[k] = v; l.hotbar[#l.hotbar + 1] = { item = k, name = k:gsub("ITEM_", ""), count = v } end end
    return c, l
end
W.find_item = function(list, what)
    for _, e in ipairs(list.hotbar) do
        if e.item == what or e.name == what then
            if Wd.cat and e.item == "ITEM_Spade" then e.category = Wd.cat end
            return e
        end
    end
end
W.held_item = function() return Wd.held end
W.equip = function(_, item) Wd.held = item; return { ok = true } end
W.actions = function() return { primary = { n = "primary" } } end
W.gate = function() return Wd.modal end
W.inject = function() Wd.injected = Wd.injected + 1; Wd.tapped = true; return true end
W.target = function() if d2(Wd.pawn.pos, Wd.plot.pos) <= 250 then return { actor = Wd.plot.owner_id } end; return { none = true } end
W.press = function()
    Wd.presses = Wd.presses + 1
    if Wd.plot.harvestable then Wd.plot.harvestable = false; Wd.plot.prompt = "Plot"; Wd.inv.ITEM_Wheat = (Wd.inv.ITEM_Wheat or 0) + 4; Wd.xp = Wd.xp + 40 end
    return { ok = true }
end
W.face = function() end

local function pump(sec, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(sec / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        step(dt)
        if until_fn and until_fn() then return true end
    end
end
local function run(args, sec)
    local r = F.HANDLERS.tend(nil, args or {}, { id = "t" })
    if not r.pending then return r end
    local res
    pump(sec or 120, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT" }
end

do
    local a = { soil = "weeds", prompt = "x" }
    local b = { soil = "clear", prompt = "x" }
    check("signature differs", F.signature(a) ~= F.signature(b))
    local ch = F.changes(a, b)
    check("changes soil", ch and ch.soil and ch.soil.from == "weeds" and ch.soil.to == "clear")
    local g, n = F.inv_changes({ s = 3 }, { s = 2, w = 4 })
    check("inventory changes", n == 5 and g.s == -1 and g.w == 4)
end

do -- dig the weeds (3 digs needed, times = 5)
    reset({ digs = 3 })
    local res = run({ item = "ITEM_Spade", times = 5 })
    check("dig: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("dig: 3 presses", res.data.presses == 3, res.data.presses)
    check("dig: soil changed", res.data.changed and res.data.changed.soil and res.data.changed.soil.to == "clear")
    check("dig: xp", res.data.xp and res.data.xp.Farming and res.data.xp.Farming.xp == 9)
    check("dig: arbiter released", A.owner() == nil)
end

do -- a spade on weeds digs on until the soil is clear (live 05:00Z: 15 digs, a change every 5; tend had stopped at
   -- the first change, so "dig" looked done with the weeds still there and the seeds then did nothing)
    reset({ digs = 15, stage_digs = 5, cat = "Item.Equipment.Tool.Shovel" })
    local res = run({ item = "ITEM_Spade" })
    check("dig until clear: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("dig until clear: 15 presses", res.data.presses == 15, res.data.presses)
    check("dig until clear: soil clear", Wd.plot.soil == "clear" and tostring(res.data.detail):find("soil is clear", 1, true) ~= nil,
          tostring(res.data.detail))
    reset({ digs = 15, stage_digs = 5 }) -- no shovel category: the old one-change contract stands
    local r2 = run({ item = "ITEM_Spade", times = 10 })
    check("no shovel category: stops at the first change", r2.ok == true and r2.data.presses == 5, r2.data and r2.data.presses)
end

do -- plant (seed spent, prompt changes)
    reset({ soil = "clear" })
    local res = run({ item = "Seeds" })
    check("plant: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("plant: seed spent reported", res.data.inventory and res.data.inventory.ITEM_Seeds == -1)
end

do -- harvest with no item: interact press
    reset({ soil = "clear", harvestable = true })
    local res = run({})
    check("harvest: ok", res.ok == true and Wd.presses == 1, tostring(res.reason))
    check("harvest: crop gained", res.data.inventory and res.data.inventory.ITEM_Wheat == 4)
end

do -- wrong item for the state: nothing changes, truthful sentence
    reset({ soil = "weeds" })
    local res = run({ item = "Seeds", times = 2 })
    check("no change: verification_failed", res.reason == "verification_failed" and res.data.why == "no_change", res.reason)
    check("no change: says what it used and the plot's words", res.data.detail:find("Seeds", 1, true) and res.data.detail:find("the plot says", 1, true), res.data.detail)
end

do -- failures before acting
    reset()
    local r = F.HANDLERS.tend(nil, { item = "Watering Can" }, { id = "x" })
    check("not carried", r.reason == "not_in_inventory", r.reason)
    reset(); Wd.plot.gone = true
    r = F.HANDLERS.tend(nil, {}, { id = "x" })
    check("no plot", r.reason == "nothing_in_range", r.reason)
    reset({ water = true })
    local res = run({ item = "ITEM_Spade" })
    check("unreachable plot", res.reason == "path_blocked" and res.data.why == "cant_reach_plot", res.reason)
    reset({ modal = { kind = "build" } })
    res = run({ item = "ITEM_Spade" })
    check("modal: never presses", Wd.injected == 0 and res.reason == "interrupted" and res.data.why == "screen_open", tostring(res.reason) .. " " .. tostring(Wd.injected))
    check("invalid times", F.HANDLERS.tend(nil, { times = 0 }, {}).reason == "invalid_args")
end

do
    reset()
    local r = F.HANDLERS.farm_plots(nil, {})
    check("plots tool", r.ok and #r.data.plots == 1 and r.data.plots[1].soil == "weeds" and r.data.plots[1].pos == nil)
    check("manifest", F.MANIFEST.tend.kind == "action" and F.MANIFEST.tend.moves and F.MANIFEST.farm_plots.kind == "read")
    local src = assert(io.open(root .. "/client_mod/scripts/farm.lua", "rb")):read("*a")
    check("no server RPC calls", not src:gsub("%-%-[^\n]*", ""):find("[:.]Server_%w+%s*%("))
    check("no item ids in logic", not src:find("ITEM_", 1, true))
end

do -- growth from the plant mesh (the game's own stage meshes), pure
    local map = { SM_Potato_02 = { plant = "Potato", stage = 2, of = 3 } }
    local g = F.growth_of(map, "SM_Potato_02")
    check("growth from a stage mesh", g and g.plant == "Potato" and g.stage == 2 and g.of == 3)
    check("no growth for an unknown mesh", F.growth_of(map, "SM_Other") == nil and F.growth_of(map, nil) == nil and F.growth_of(nil, "x") == nil)
end

do -- "Your farm" (farm_gate 2026-11-02: "where's the farm?" with his own plot 7.5 m away): his plots by what the game
   -- says about them, grouped, nearest first; Luis's plots never; remembered ones out of sight by distance
    local me = { X = 0, Y = 0, Z = 0 }
    local rows = {
        { mine = true, pos = { X = 0, Y = -750 }, distance_m = 7.5, soil = "weeds", weeds_grown = true, growth = { plant = "Weeds", stage = 3, of = 3 } },
        { mine = true, pos = { X = 300, Y = -750 }, distance_m = 8.1, soil = "clear", watered = true, growth = { plant = "Cabbage", stage = 1, of = 3 } },
        { mine = false, pos = { X = 500, Y = 0 }, distance_m = 5, harvestable = true, growth = { plant = "Potato", stage = 3, of = 3 } },
    }
    local line = F.farm_line(rows, { { X = 0, Y = -750 }, { X = 300, Y = -750 }, { X = 0, Y = 12000 } }, me)
    check("farm line: his weeded plot, with distance and the game's own words", tostring(line):find("1 plot 7.5 m N: overgrown with weeds", 1, true) ~= nil, line)
    check("farm line: his crop's stage and water", tostring(line):find("Cabbage stage 1 of 3, watered", 1, true) ~= nil, line)
    check("farm line: not Luis's plot", tostring(line):find("Potato", 1, true) == nil, line)
    check("farm line: remembered plot out of sight", tostring(line):find("1 more out of sight (remembered), nearest 120 m S", 1, true) ~= nil, line)
    check("farm line: none of his -> nil", F.farm_line({ rows[3] }, {}, me) == nil)
    check("plot words: ready", F.plot_words({ harvestable = true, growth = { plant = "Flax" } }) == "Flax ready to harvest")
    check("plot words: clear", F.plot_words({ soil = "clear" }) == "clear, nothing planted")
end

print(string.format("test_farm: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
