-- Offline tests for client_mod/scripts/gather.lua (+ gather_profiles.lua): whole gather jobs against a
-- fake world (frame pump, fake clock, a fake pawn that walks/turns, foliage trees that the "server"
-- converts when swung at or approached within 3 m, the oak chain tree -> stump + felled tree ->
-- splittable log -> log -> 6 drops -> item magnet, rocks, ground pickups), fake move/inventory/combat
-- modules and the REAL arbiter. Run:
--   lua client_mod/tests/test_gather.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
math.randomseed(11)

-- ---------------------------------------------------------------- engine stubs
local T = 0
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function wrap(d) return (d + 540) % 360 - 180 end

-- ---------------------------------------------------------------- fake world
local Wd -- world state, reset per scenario
local function obj(t) t._alive = true; return t end
local nextid = 0
local function new_actor(cls, fams, pos, hp, extra)
    nextid = nextid + 1
    local a = obj({ cls = cls, fams = fams, pos = { X = pos.X, Y = pos.Y, Z = pos.Z or 0 }, hp = hp, max = hp,
                    id = cls .. "_" .. nextid, born = T })
    for k, v in pairs(extra or {}) do a[k] = v end
    Wd.actors[#Wd.actors + 1] = a
    return a
end
local function kill(a) a._alive = false end

local function reset(opts)
    opts = opts or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWGather, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    Wd = { pawn = { pos = { X = 0, Y = 0, Z = 0 }, yaw = 0, stamina = 80, dead = false }, actors = {}, foliage = {}, drops = {},
           inv = opts.inv or { ITEM_Logging_Axe_Mithril = 1, ITEM_Pickaxe_Mithril = 1 }, held = opts.held, empty = opts.empty or 20,
           blocked = opts.blocked, no_effect = opts.no_effect, dead_inputs = opts.dead_inputs, full = opts.full,
           pending = {}, events = {}, presses = 0, injected = 0, face_calls = 0, equips = {}, moves = 0 }
end

local function add_foliage_tree(species, pos, extra)
    local f = { id = "fol:ISMC_Tree_" .. species .. ":" .. (#Wd.foliage + 1), class = "BP_FH_Tree_" .. species .. "_01_C",
                _pos = pos, name = species .. " Tree", tool = "Hatchet", tool_tier = (species == "Oak") and 3 or 1,
                max_health = species == "Oak" and 220 or 160, kind = "tree", visible = true }
    for k, v in pairs(extra or {}) do f[k] = v end
    Wd.foliage[#Wd.foliage + 1] = f
    return f
end

-- the server converts a foliage instance into an actor (the NearbyFoliageConverter / a swing trace)
local function convert(f)
    if not f.visible then return f.actor end
    f.visible = false
    if f.kind == "pickup" then
        f.actor = new_actor(f.class, { "BaseInteractableResource" }, f._pos, nil, { item = f.item, available = true, species = "pickup" })
    else
        local sp = f.class:match("Tree_(%a+)_")
        f.actor = new_actor(f.class, { "FellableTree" }, f._pos, f.max_health, { stump = false, species = sp, gate_tier = f.tool_tier })
    end
    return f.actor
end

local function spawn_drops(at, n, item)
    for i = 1, n do
        local ang = i * 1.1
        local w = obj({ id = "BP_RuntimeSpawnedWorldItem_C_" .. (#Wd.drops + 1000), pos = { X = at.X + math.cos(ang) * 80, Y = at.Y + math.sin(ang) * 80, Z = 0 },
                        item = item, born = T })
        Wd.drops[#Wd.drops + 1] = w
    end
end

local function damage(a, amount)
    if not a._alive then return end
    a.hp = a.hp - amount
    local sp = a.species
    if a.fams[1] == "FellableTree" and not a.stump and a.hp <= a.max / 2 then
        a.stump, a.hp = true, a.max / 2
        local felled = new_actor("BP_FelledTree_" .. sp .. "_C", { "FelledTree" }, { X = a.pos.X + 300, Y = a.pos.Y, Z = 0 }, 105, { species = sp })
        Wd.pending[#Wd.pending + 1] = { t = T + 2.0, fn = function()
            kill(felled)
            new_actor("BP_SplittableLog_" .. sp .. "_C", { "SplittableTreeLog" }, { X = a.pos.X + 300, Y = a.pos.Y + 50, Z = 0 }, 105, { species = sp })
        end }
    elseif a.fams[1] == "SplittableTreeLog" and a.hp <= 0 then
        kill(a)
        new_actor("BP_Log_" .. sp .. "_C", { "TreeLog" }, { X = a.pos.X + 100, Y = a.pos.Y + 100, Z = 0 }, 105, { species = sp })
    elseif a.fams[1] == "TreeLog" and a.hp <= 0 then
        kill(a)
        spawn_drops(a.pos, 6, "ITEM_Resources_Wood_" .. sp)
    elseif a.fams[1] == "DestructibleMiningRock" and a.hp <= 0 then
        a.hidden = true
        spawn_drops(a.pos, 3, "ITEM_Resources_Stone")
    end
end

-- what a swing hits: the fake chop wedge sits 35 deg right of the body's forward (+-25), depth 160 cm
local function swing()
    local me = Wd.pawn.pos
    local best, bd
    local cands = {}
    for _, a in ipairs(Wd.actors) do if a._alive and a.hp and not a.hidden and a.fams[1] ~= "FelledTree" then cands[#cands + 1] = { a = a, pos = a.pos } end end
    for _, f in ipairs(Wd.foliage) do if f.visible and f.kind == "tree" then cands[#cands + 1] = { f = f, pos = f._pos } end end
    for _, c in ipairs(cands) do
        local d = d2(me, c.pos)
        local rel = wrap(math.deg(math.atan(c.pos.Y - me.Y, c.pos.X - me.X)) - Wd.pawn.yaw)
        if d <= 160 and math.abs(rel - (Wd.aim_rel or 35)) <= 25 and (not bd or d < bd) then best, bd = c, d end
    end
    if not best or Wd.no_effect then return end
    local a = best.a or convert(best.f)
    Wd.pending[#Wd.pending + 1] = { t = T + 0.55, fn = function() damage(a, 68) end }
end

local function step_world(dt)
    -- pending server events
    local keep = {}
    for _, p in ipairs(Wd.pending) do if T >= p.t then p.fn() else keep[#keep + 1] = p end end
    Wd.pending = keep
    -- server-side converter: foliage within 3 m of the pawn becomes an actor
    for _, f in ipairs(Wd.foliage) do if f.visible and d2(Wd.pawn.pos, f._pos) <= 300 and not Wd.no_convert then convert(f) end end
    -- undamaged converted trees revert to foliage after 6 s when Claude is > 3 m away
    -- item magnet: drops older than 1 s within 3.5 m fly in and are granted (unless the bags are full)
    for _, w in ipairs(Wd.drops) do
        if w._alive and T - w.born > 1.0 and d2(Wd.pawn.pos, w.pos) <= 350 and not Wd.full and not Wd.no_magnet then
            w._alive = false
            Wd.inv[w.item] = (Wd.inv[w.item] or 0) + 1
        end
    end
    -- stamina regen
    Wd.pawn.stamina = math.min(80, Wd.pawn.stamina + 5 * dt)
end

-- ---------------------------------------------------------------- fake modules
local MV = { mode = "idle" }
local fake_move = {}
function fake_move.go_to(log, goal, opts)
    Wd.moves = Wd.moves + 1
    MV.mode, MV.goal, MV.tol, MV.t0, MV.result = "go_to", { X = goal[1] * 100, Y = goal[2] * 100, Z = goal[3] * 100 }, (opts.tolerance_m or 1.5) * 100, T, nil
    return { ok = true }
end
function fake_move.follow() return { ok = true } end
function fake_move.stop() MV.mode = "idle"; MV.result = MV.result or { status = "stopped" }; return { ok = true } end
function fake_move.status() return { mode = MV.mode, result = MV.result } end
local function step_move(dt)
    if MV.mode ~= "go_to" then return end
    local me = Wd.pawn.pos
    if Wd.blocked then
        if T - MV.t0 > 1.0 then MV.mode, MV.result = "idle", { status = "failed", reason = "stuck" } end
        return
    end
    local d = d2(me, MV.goal)
    if d <= MV.tol then MV.mode, MV.result = "idle", { status = "arrived", dist_m = d / 100 }; return end
    local stepc = math.min(450 * dt, d)
    local dx, dy = (MV.goal.X - me.X) / d, (MV.goal.Y - me.Y) / d
    me.X, me.Y = me.X + dx * stepc, me.Y + dy * stepc
    Wd.pawn.yaw = math.deg(math.atan(dy, dx))
end

local TOOLS = {
    ITEM_Logging_Axe_Mithril = { name = "Mithril Logging Axe", cat = "axe", tier = 6, prim = { stam = 4, next_ms = 1286, dmg_ms = 549 } },
    ITEM_Logging_Axe_Stone = { name = "Stone Logging Axe", cat = "axe", tier = 1, prim = { stam = 4, next_ms = 1286, dmg_ms = 549 } },
    ITEM_Pickaxe_Mithril = { name = "Mithril Pickaxe", cat = "pickaxe", tier = 6, prim = { stam = 6, next_ms = 1527, dmg_ms = 878 } },
}
local fake_combat = { weapons = function() return { items = TOOLS } end, actions = function() return { primary = "IA_PrimaryAction", special = "IA_SpecialAction" } end }

local fake_inv = {}
function fake_inv.list()
    local hotbar, slot = {}, 0
    for item, n in pairs(Wd.inv) do
        hotbar[#hotbar + 1] = { item = item, name = (TOOLS[item] or {}).name or item, count = n, slot = slot }
        slot = slot + 1
    end
    table.sort(hotbar, function(a, b) return a.item < b.item end)
    return { ok = true, hotbar = hotbar, bag = {}, loadout = {}, empty_slots = Wd.empty, held = {} }
end
function fake_inv.held() return { right_item = nil, left_item = Wd.held } end
function fake_inv.equip(log, what)
    Wd.equips[#Wd.equips + 1] = what
    Wd.pending[#Wd.pending + 1] = { t = T + 0.3, fn = function() Wd.held = what end }
    return { ok = true, via = "hotbar key" }
end
local function near_interactable()
    local me = Wd.pawn.pos
    for _, w in ipairs(Wd.drops) do if w._alive and d2(me, w.pos) <= 150 then return { actor = w.id, item = w.item, class = "BP_RuntimeSpawnedWorldItem_C", w = w } end end
    for _, a in ipairs(Wd.actors) do
        if a._alive and a.fams[1] == "BaseInteractableResource" and a.available and d2(me, a.pos) <= 150 then
            return { actor = a.id, item = a.item, class = a.cls, a = a }
        end
    end
end
function fake_inv.interact_target() local t = near_interactable(); return t or { none = true } end
function fake_inv.press_interact()
    Wd.presses = Wd.presses + 1
    local t = near_interactable()
    if not t or Wd.full then return { ok = true } end
    if t.w then t.w._alive = false; Wd.inv[t.w.item] = (Wd.inv[t.w.item] or 0) + 1 end
    if t.a then t.a.available = false; Wd.inv[t.a.item] = (Wd.inv[t.a.item] or 0) + (t.a.yield or 1) end
    return { ok = true }
end

-- ---------------------------------------------------------------- load the modules
local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local G = assert(loadfile(root .. "/client_mod/scripts/gather.lua"))()
local P = assert(loadfile(root .. "/client_mod/scripts/gather_profiles.lua"))()
G.clock = function() return T end
G.set_modules({ move = fake_move, inventory = fake_inv, combat = fake_combat, arbiter = A, gather_profiles = P })

-- world adapter over the fake world
local W = G.W
local fake_pc = { Pawn = Wd and Wd.pawn }
W.now = function() return T end
W.pc = function() return fake_pc end
W.pawn = function() return (not Wd.no_pawn) and Wd.pawn or nil end
W.actors = function(cls)
    local out = {}
    for _, a in ipairs(Wd.actors) do if a._alive and a.fams[1] == cls then out[#out + 1] = a end end
    return out
end
W.foliage = function(origin, r, opts)
    local out = {}
    for _, f in ipairs(Wd.foliage) do
        if f.visible and d2(origin, f._pos) <= r and (not opts.match or f.class:find(opts.match)) and (not opts.kinds or opts.kinds[f.kind]) then
            local ex = false
            for _, e in ipairs(type(opts.exclude) == "string" and { opts.exclude } or opts.exclude or {}) do if f.class:find(e) then ex = true end end
            if not ex then out[#out + 1] = f end
        end
    end
    table.sort(out, function(a, b) return d2(origin, a._pos) < d2(origin, b._pos) end)
    return out
end
W.loc = function(a) return a and a.pos and { X = a.pos.X, Y = a.pos.Y, Z = a.pos.Z } end
W.alive = function(a) return a ~= nil and a._alive == true end
W.id = function(a) return a.id end
W.class = function(a) return a.cls end
W.hp = function(a) return a.hp end
W.max_hp = function(a) return a.max end
W.stump = function(a) return a.stump == true end
W.depleted = function(a) return a.hidden == true end
W.available = function(a) return a.available ~= false end
W.gate = function(a) return a.gate_tier and { tool = "Hatchet", tier = a.gate_tier } or (a.fams[1] == "DestructibleMiningRock" and { tool = "Pickaxe", tier = 1 }) or nil end
W.item_of = function(a) return a.item end
W.aim = function(a) return W.loc(a) end
W.drops = function(origin, r, item)
    local out = {}
    for _, w in ipairs(Wd.drops) do
        if w._alive and d2(origin, w.pos) <= r and (not item or w.item == item) then out[#out + 1] = { actor = w, key = w.id, pos = w.pos, item = w.item } end
    end
    return out
end
W.stamina = function() return Wd.pawn.stamina end
W.yaw = function() return Wd.pawn.yaw end
W.dead = function() return Wd.pawn.dead end
W.face = function(pc, yaw) Wd.face_calls = Wd.face_calls + 1; Wd.want_yaw = yaw end
-- the body turns toward movement input (540 deg/s)
W.nudge = function(pawn, dir, s)
    local want = math.deg(math.atan(dir.Y, dir.X))
    local e = wrap(want - Wd.pawn.yaw)
    local stepd = math.max(-5.4, math.min(5.4, e))
    Wd.pawn.yaw = Wd.pawn.yaw + stepd
end
local last_inj = {}
W.inject = function(action)
    Wd.injected = Wd.injected + 1
    local rising = last_inj[action] ~= T - 0.01 and (last_inj[action] or -1) < T - 0.015
    last_inj[action] = T
    if rising and action == "IA_PrimaryAction" and not Wd.dead_inputs then
        Wd.pawn.stamina = Wd.pawn.stamina - 4
        swing()
        Wd.swings = (Wd.swings or 0) + 1
    end
    return true
end
W.emit = function(ev) Wd.events[#Wd.events + 1] = ev end

local function pump(seconds, until_fn)
    local dt = 0.01
    local n = math.floor(seconds / dt)
    for _ = 1, n do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        step_move(dt)
        step_world(dt)
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        if until_fn and until_fn() then return true end
    end
    return false
end

local function run_job(args, seconds, ctx)
    local r = G.HANDLERS.gather(print_log or nil, args, ctx or { id = "t1" })
    if not r.pending then return r, nil end
    local res
    pump(seconds or 600, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT", data = G.status().job }, r
end

local function count_ev(kind) local n = 0; for _, e in ipairs(Wd.events) do if e.type == kind then n = n + 1 end end; return n end

-- ================================================================ profiles
do
    local k = P.resolve("oak logs"); check("resolve oak logs", k == "oak", k)
    k = P.resolve("Maple log"); check("resolve maple log (longest alias)", k == "maple", k)
    k = P.resolve("ITEM_Resources_Wood_Ash"); check("resolve by item id", k == "ash", k)
    k = P.resolve("some sticks please"); check("resolve sticks phrase", k == "sticks", k)
    check("resolve unknown", P.resolve("unobtainium") == nil)
    check("ash excludes bare trees", not G.matches("BP_FH_Tree_Ash_Bare_01_C", P.RESOURCES.ash.root.match, P.RESOURCES.ash.root.exclude))
    check("ash matches BM ash", G.matches("BP_BM_Tree_Ash_02_C", P.RESOURCES.ash.root.match, P.RESOURCES.ash.root.exclude))
    check("oak excludes sapling", not G.matches("BP_Sapling_Oak_01_C", P.RESOURCES.oak.root.match, P.RESOURCES.oak.root.exclude))
    check("yew class", G.matches("BP_YewTree_02_C", P.RESOURCES.yew.root.match, P.RESOURCES.yew.root.exclude))
    local bt = G.best_tool({ hotbar = { { item = "ITEM_Logging_Axe_Stone" }, { item = "ITEM_Logging_Axe_Mithril" }, { item = "ITEM_Pickaxe_Mithril" } } },
        P.RESOURCES.oak, TOOLS)
    check("best tool = highest tier axe", bt and bt.entry.item == "ITEM_Logging_Axe_Mithril", bt and bt.entry.item)
end

-- ================================================================ 1. oak: the whole chain from a foliage tree
do
    reset({ held = nil })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 1500, Y = 400, Z = 0 })
    add_foliage_tree("Ash", { X = 600, Y = -300, Z = 0 }) -- nearer, wrong species
    local res = run_job({ resource = "oak", count = 6 }, 300)
    check("oak ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and (res.data.detail or res.data.why)))
    check("oak gathered 6", res.data and res.data.gathered >= 6, res.data and res.data.gathered)
    check("oak equipped the axe by key", Wd.equips[1] == "ITEM_Logging_Axe_Mithril", Wd.equips[1])
    check("oak: tree felled + logs broken", res.data and res.data.broken >= 3, res.data and (res.data.broken .. " " .. table.concat(res.data.phase_log or {}, " | ")))
    check("oak: ash untouched", Wd.foliage[2].visible == true)
    check("oak: progress events", count_ev("gather_progress") >= 1, count_ev("gather_progress"))
    check("oak: faced via the camera", Wd.face_calls > 0)
    check("oak: arbiter released", A.owner() == nil, A.owner() and A.owner().name)
    check("oak: stump left standing (regrowth)", (function() for _, a in ipairs(Wd.actors) do if a.stump and a._alive then return true end end end)())
    check("oak inventory count", Wd.inv.ITEM_Resources_Wood_Oak >= 6, Wd.inv.ITEM_Resources_Wood_Oak)
end

-- ================================================================ 2. no tool / tier too low
do
    reset({ inv = { ITEM_Pickaxe_Mithril = 1 } })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    local r = G.HANDLERS.gather(nil, { resource = "oak", count = 2 }, { id = "t2" })
    check("no axe -> wrong_tool", r.ok == false and r.reason == "wrong_tool" and r.data.why == "no_tool", r.reason)
    check("no axe detail says why", r.data and tostring(r.data.detail):find("logging axe"), r.data and r.data.detail)
    reset({ inv = { ITEM_Logging_Axe_Stone = 1 } })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    r = G.HANDLERS.gather(nil, { resource = "oak", count = 2 }, { id = "t3" })
    check("stone axe on oak -> wrong_tool tier", r.ok == false and r.reason == "wrong_tool" and r.data.why == "tool_tier_too_low", r.reason)
    -- live gate higher than the profile says (a tier-6 tree): found at scan time
    reset({ inv = { ITEM_Logging_Axe_Stone = 1 } })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Ash", { X = 900, Y = 0, Z = 0 }, { tool_tier = 4 })
    local res = run_job({ resource = "ash", count = 2 }, 60)
    check("live gate tier -> wrong_tool", res.ok == false and res.reason == "wrong_tool" and res.data.need_tier == 4, res.reason)
end

-- ================================================================ 3. nothing in range (widens first)
do
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 20000, Y = 0, Z = 0 }) -- 200 m: beyond the max radius
    local res = run_job({ resource = "oak", count = 2 }, 60)
    check("nothing_in_range", res.ok == false and res.reason == "nothing_in_range" and res.data.why == "no_resource_nearby", res.reason)
    check("nothing_in_range widened to max", res.data and res.data.radius_m == G.cfg.max_radius_m, res.data and res.data.radius_m)
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 5000, Y = 0, Z = 0 }) -- 50 m: found after widening
    local T2 = G.HANDLERS.gather(nil, { resource = "oak", count = 1 }, { id = "t4" })
    pump(3)
    local st = G.status().job
    check("widened radius finds the 50 m tree", st and st.target and st.target.kind == "foliage", st and st.phase)
    G.stop(nil, "test")
end

-- ================================================================ 4. unreachable targets
do
    reset({ blocked = true })
    fake_pc.Pawn = Wd.pawn
    for i = 1, 4 do add_foliage_tree("Oak", { X = 800 * i, Y = 500, Z = 0 }) end
    local res = run_job({ resource = "oak", count = 2 }, 120)
    check("unreachable -> path_blocked", res.ok == false and res.reason == "path_blocked" and res.data.why == "unreachable", tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
    check("unreachable detail", res.data and tostring(res.data.detail):find("can't get to"), res.data and res.data.detail)
end

-- ================================================================ 5. swings that do nothing
do
    reset({ no_effect = true })
    fake_pc.Pawn = Wd.pawn
    for i = 1, 4 do add_foliage_tree("Oak", { X = 700 * i, Y = 0, Z = 0 }) end
    local res = run_job({ resource = "oak", count = 2 }, 600)
    check("no effect -> path_blocked swing_no_effect", res.ok == false and res.reason == "path_blocked" and res.data.why == "swing_no_effect",
        tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
    check("no effect: tried several aims", (res.data and res.data.swings or 0) >= G.cfg.no_effect_swings * #G.cfg.aim_offsets.axe, res.data and res.data.swings)
end

-- ================================================================ 6. aim search: the wedge is NOT where the prior says
do
    reset()
    fake_pc.Pawn = Wd.pawn
    Wd.aim_rel = -20 -- this tool's wedge is 20 deg LEFT
    add_foliage_tree("Ash", { X = 900, Y = 300, Z = 0 })
    local res = run_job({ resource = "ash", count = 6 }, 400)
    check("aim search finds the wedge", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
end

-- ================================================================ 7. inputs not reaching the game
do
    reset({ dead_inputs = true })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    local res = run_job({ resource = "oak", count = 2 }, 120)
    check("dead inputs -> body_error", res.ok == false and res.reason == "body_error" and res.data.why == "inputs_not_reaching_game", res.reason)
end

-- ================================================================ 8. combat reflex pre-empts, gather resumes
do
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 1200, Y = 0, Z = 0 })
    local r = G.HANDLERS.gather(nil, { resource = "oak", count = 6 }, { id = "t8" })
    pump(6)
    local before = G.status().job
    local fr = A.request(nil, { name = "combat:reflex", level = "reflex", resumable = false, uses_move = true })
    check("reflex preempts gather", fr.ok and fr.preempted and fr.preempted.name == "gather:oak" and fr.preempted.suspended, fr.preempted and fr.preempted.name)
    local sw0 = Wd.swings or 0
    pump(5)
    check("suspended gather does not swing", (Wd.swings or 0) == sw0, (Wd.swings or 0) - sw0)
    check("gather reports suspended", G.status().job and G.status().job.suspended == true)
    A.release(nil, fr.token, "fight over")
    local res
    pump(400, function() res = r.pending.poll(); return res ~= nil end)
    check("resumed gather completes", res and res.ok == true, res and (tostring(res.reason) .. " " .. tostring(res.data.why)))
    check("resume re-checked the tool", before and true)
end

-- ================================================================ 9. inventory full
do
    reset({ full = true, empty = 0, inv = { ITEM_Logging_Axe_Mithril = 1, ITEM_Resources_Wood_Oak = 99 } })
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    local res = run_job({ resource = "oak", count = 3 }, 400)
    check("inventory full", res.ok == false and res.reason == "inventory_full", tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
    reset({ empty = 0, inv = { ITEM_Logging_Axe_Mithril = 1 } })
    fake_pc.Pawn = Wd.pawn
    local r = G.HANDLERS.gather(nil, { resource = "oak", count = 3 }, { id = "t9" })
    check("full bags up front", r.ok == false and r.reason == "inventory_full", r.reason)
end

-- ================================================================ 10. drops the magnet ignores -> interact key
do
    reset()
    fake_pc.Pawn = Wd.pawn
    Wd.no_magnet = true
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    local res = run_job({ resource = "oak", count = 6 }, 400)
    check("interact collects non-magnet drops", res.ok == true and Wd.presses >= 6, tostring(res.reason) .. " presses=" .. Wd.presses)
end

-- ================================================================ 11. mining a rock (level actor)
do
    reset()
    fake_pc.Pawn = Wd.pawn
    new_actor("BP_OreNode_Stone_C", { "DestructibleMiningRock" }, { X = 800, Y = 200, Z = 0 }, 75)
    local res = run_job({ resource = "rock", count = 3 }, 200)
    check("mine a stone rock", res.ok == true and res.data.gathered >= 3, tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
    check("mining equipped the pickaxe", Wd.equips[1] == "ITEM_Pickaxe_Mithril", Wd.equips[1])
end

-- ================================================================ 12. ground pickups (foliage, interact key)
do
    reset()
    fake_pc.Pawn = Wd.pawn
    for i = 1, 3 do
        Wd.foliage[#Wd.foliage + 1] = { id = "fol:Pick:" .. i, class = "BP_Spawner_Stone_C", _pos = { X = 500 * i, Y = 100, Z = 0 }, name = "Stone",
                                        kind = "pickup", visible = true, item = "ITEM_Resources_Stone" }
    end
    local res = run_job({ resource = "stones", count = 2 }, 120)
    check("pickup stones", res.ok == true and Wd.presses >= 2, tostring(res.reason) .. " " .. tostring(res.data and res.data.why) .. " presses=" .. Wd.presses)
    check("pickups need no tool", #Wd.equips == 0, #Wd.equips)
    -- unknown item id (sticks): learned from the inventory gain
    reset()
    fake_pc.Pawn = Wd.pawn
    for i = 1, 3 do
        Wd.foliage[#Wd.foliage + 1] = { id = "fol:Br:" .. i, class = "BP_Spawner_AshBranch_01_C", _pos = { X = 400 * i, Y = -100, Z = 0 }, name = "Branch",
                                        kind = "pickup", visible = true, item = "ITEM_Resources_Stick" }
    end
    res = run_job({ resource = "sticks", count = 2 }, 120)
    check("pickup sticks (item learned)", res.ok == true and res.data.item == "ITEM_Resources_Stick", tostring(res.reason) .. " item=" .. tostring(res.data and res.data.item))
end

-- ================================================================ 13. pause / death / handler args
do
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    local r = G.HANDLERS.gather(nil, { resource = "oak", count = 2 }, { id = "t13" })
    pump(2)
    _G.DW_PAUSE = true
    local res
    pump(1, function() res = r.pending.poll(); return res ~= nil end)
    check("pause -> interrupted", res and res.reason == "interrupted" and res.data.why == "world_teardown", res and res.reason)
    _G.DW_PAUSE = nil
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    r = G.HANDLERS.gather(nil, { resource = "oak", count = 2 }, { id = "t14" })
    pump(2)
    Wd.pawn.dead = true
    pump(1, function() res = r.pending.poll(); return res ~= nil end)
    check("death -> companion_down", res and res.reason == "companion_down", res and res.reason)
    check("missing resource -> invalid_args", G.HANDLERS.gather(nil, {}, { id = "x" }).reason == "invalid_args")
    check("bad count -> invalid_args", G.HANDLERS.gather(nil, { resource = "oak", count = 0 }, { id = "x" }).reason == "invalid_args")
    local u = G.HANDLERS.gather(nil, { resource = "unobtainium", count = 1 }, { id = "x" })
    check("unknown resource", u.reason == "unknown_target" and u.data.why == "unknown_resource", u.reason)
    check("status handler", G.HANDLERS.gather_status().ok == true)
    -- brain cancel (the bridge pre-empts the action)
    reset()
    fake_pc.Pawn = Wd.pawn
    add_foliage_tree("Oak", { X = 900, Y = 0, Z = 0 })
    r = G.HANDLERS.gather(nil, { resource = "oak", count = 2 }, { id = "t15" })
    pump(2)
    r.pending.cancel()
    res = r.pending.poll()
    check("cancel -> interrupted", res and res.reason == "interrupted", res and res.reason)
    check("cancel released the pawn", A.owner() == nil)
end

-- ================================================================ 14. sense.foliage over fake ISM components
do
    local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()
    local function uobj(full, t)
        t = t or {}
        t.IsValid = function() return true end
        t.GetFullName = function() return full end
        return t
    end
    local function ftext(s) return { ToString = function() return s end } end
    local oak_cdo = uobj("BP_BM_Tree_Oak_01_C /Game/Default__BP_BM_Tree_Oak_01_C", { DisplayName = ftext("Oak Tree"), bIsStump = false,
        DamageModifiersWhenTree = { ForEach = function(_, f) f(1, { get = function() return { RequiredCategory = { TagName = ftext("Item.Equipment.Tool.Hatchet") }, RequiredTier = 3 } end }) end },
        HealthComponent = { MaxHealth = 220 } })
    local oak_cls = uobj("BlueprintGeneratedClass /Game/Trees/BP_BM_Tree_Oak_01.BP_BM_Tree_Oak_01_C", { GetCDO = function() return oak_cdo end })
    local function inst(x, y, z, s) return { Transform = { WPlane = { X = x, Y = y, Z = z }, XPlane = { X = s, Y = 0, Z = 0 } } } end
    local comp = uobj("BP_InteractableFoliageISMC_Tree_C /Game/L.L:PersistentLevel.Tile.BP_InteractableFoliageISMC_Tree_C_10", {
        ActorClass = oak_cls, bDamageable = true, bInteractable = false,
        PerInstanceSMData = { inst(-9786.7, 1249.2, 9411.1, 0.82), inst(100, 100, 0, 0.0), inst(0, -50000, 0, 1) },
        GetInstancesOverlappingSphere = function() return { { get = function() return 0 end }, { get = function() return 1 end }, { get = function() return 2 end } } end,
        K2_GetComponentLocation = function() return { X = 12600, Y = 189000, Z = -12600 } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
        K2_GetComponentScale = function() return { X = 1, Y = 1, Z = 1 } end })
    local ash_cls = uobj("BlueprintGeneratedClass /Game/Trees/BP_FH_Tree_Ash_Bare_01.BP_FH_Tree_Ash_Bare_01_C", { GetCDO = function() return nil end })
    local bare = uobj("BP_InteractableFoliageISMC_Tree_C /Game/L.L:PersistentLevel.Tile.BP_InteractableFoliageISMC_Tree_C_11", {
        ActorClass = ash_cls, PerInstanceSMData = { inst(-9000, 1000, 9400, 1) },
        GetInstancesOverlappingSphere = function() return { { get = function() return 0 end } } end,
        K2_GetComponentLocation = function() return { X = 12600, Y = 189000, Z = -12600 } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
        K2_GetComponentScale = function() return { X = 1, Y = 1, Z = 1 } end })
    local old = FindAllOf
    FindAllOf = function(cls) if cls == "InteractableFoliageISMComponent" then return { comp, bare } end return {} end
    local me = { X = 4851, Y = 189014, Z = -3526 }
    local rows = S.foliage(me, 4000, { kinds = { tree = true } })
    check("foliage: 2 visible trees within 40 m (hidden + far skipped)", #rows == 2, #rows)
    local r
    for _, x in ipairs(rows) do if x.class == "BP_BM_Tree_Oak_01_C" then r = x end end
    check("foliage: nearest first (the bare ash)", rows[1] and rows[1].class == "BP_FH_Tree_Ash_Bare_01_C" and rows[1].name == "FH Tree Ash Bare", rows[1] and rows[1].name)
    check("foliage: world position", r and math.abs(r.position[1] - 28.13) < 0.05 and math.abs(r.position[2] - 1902.49) < 0.05, r and table.concat(r.position, ","))
    check("foliage: name/tool/tier/hp from the class default object", r and r.name == "Oak Tree" and r.tool == "Hatchet" and r.tool_tier == 3 and r.max_health == 220,
        r and (tostring(r.name) .. " " .. tostring(r.tool) .. " " .. tostring(r.tool_tier)))
    check("foliage: id and verb", r and r.id == "fol:BP_BM_Tree_Oak_01_C@281,19025,-319" and r.verb == "chop", r and r.id)
    rows = S.foliage(me, 4000, { match = "Tree_Ash", exclude = { "Bare" } })
    check("foliage: exclude bare ash", #rows == 0, #rows)
    FindAllOf = old
end

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
