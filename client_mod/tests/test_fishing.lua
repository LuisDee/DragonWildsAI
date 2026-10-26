-- Offline tests for client_mod/scripts/fishing.lua: the pure decisions (method from tags, tool fit, spot
-- choice, charge ballistics, cast learning, fight inputs, gains, XP deltas) and whole fishing jobs against a
-- fake world (frame pump, fake clock, fake pawn that walks, fishing nodes, a fake fishing component with
-- casting / bite / fight / result, a net trawl that lands items in the bag) with the REAL arbiter.
-- Run:  lua client_mod/tests/test_fishing.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
math.randomseed(7)

-- ---------------------------------------------------------------- engine stubs
local T = 0
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

local NET_TAG, ROD_TAG = "Item.Equipment.Tool.Fishing.Net", "Item.Equipment.Tool.Fishing.Rod"
local TOOLS = { ITEM_Net_A = { pl = 2 }, ITEM_Net_B = { pl = 5 }, ITEM_Rod_A = { pl = 2 }, ITEM_Rod_B = { pl = 6 } }

local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

-- ---------------------------------------------------------------- fake world
local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWFishing, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    Wd = { pawn = { pos = { X = 0, Y = 0, Z = 0 }, yaw = 0, stamina = 100, dead = false }, nodes = o.nodes or {},
           inv = o.inv or {}, held = nil, empty = o.empty or 10, held_now = {}, held_prev = {}, equips = 0,
           water = o.water, -- function(pos) -> true when a point is unwalkable water
           k_true = o.k_true or 1.0, invert = o.invert, no_bite = o.no_bite, deplete_after = o.deplete_after,
           xp = 100, comp = { activity = 0, cast = 4, result = 3, swim = 0, reel = 0, session = 0, changed_t = 0 },
           charge = 0, trawl_hold = 0, fish_catches = 0, outside_ok = o.outside_ok }
end

local function inv_list()
    local l = { ok = true, hotbar = {}, bag = {}, loadout = {}, empty_slots = Wd.empty }
    for item, n in pairs(Wd.inv) do
        local cat
        if item:find("Net") then cat = NET_TAG elseif item:find("Rod") then cat = ROD_TAG end
        if n > 0 then table.insert(cat and l.hotbar or l.bag, { item = item, name = item:gsub("ITEM_", ""), count = n, category = cat }) end
    end
    table.sort(l.hotbar, function(a, b) return a.item < b.item end)
    return l
end

local fake_move = {}
function fake_move.go_to(log, pos) Wd.goal = { X = pos[1] * 100, Y = pos[2] * 100, Z = (pos[3] or 0) * 100 }; Wd.move_res = nil; return { ok = true } end
function fake_move.status()
    if Wd.move_res then return { mode = "idle", result = Wd.move_res } end
    return { mode = Wd.goal and "goto" or "idle", result = Wd.goal and nil or { status = "arrived" } }
end
function fake_move.stop() Wd.goal = nil; return { ok = true } end
function fake_move.snapshot() return nil end
function fake_move.restore() return true end

local function step_move(dt)
    local g = Wd.goal
    if not g then return end
    local p = Wd.pawn.pos
    local d = d2(p, g)
    local stepcm = 500 * dt
    if d <= stepcm then
        if Wd.water and Wd.water(g) then Wd.goal = nil; Wd.move_res = { status = "failed", reason = "path_blocked" }; return end
        p.X, p.Y = g.X, g.Y; Wd.goal = nil; Wd.move_res = { status = "arrived" }; return
    end
    local nx, ny = p.X + (g.X - p.X) / d * stepcm, p.Y + (g.Y - p.Y) / d * stepcm
    if Wd.water and Wd.water({ X = nx, Y = ny }) then Wd.goal = nil; Wd.move_res = { status = "failed", reason = "path_blocked" }; return end
    p.X, p.Y = nx, ny
end

local IA = { primary = { n = "primary" }, left = { n = "left" }, right = { n = "right" }, reel = { n = "reel" }, cancel = { n = "cancel" } }

local function node(id, tag, pos, extra)
    local r = { id = id, pos = pos, name = (tag == NET_TAG) and "Net Fishing Spot" or "Rod Fishing Spot", tag = tag, level = 1,
                depleted = false, blocked = false, in_use = false }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

-- the fishing "server": per frame, after the module injected its inputs
local function nearest_node(tag)
    local best, bd
    for _, n in ipairs(Wd.nodes) do if n.tag == tag and not n.depleted then local d = d2(Wd.pawn.pos, n.pos); if not bd or d < bd then best, bd = n, d end end end
    return best, bd
end
local function grant(item) Wd.inv[item] = (Wd.inv[item] or 0) + 1; Wd.xp = Wd.xp + 25 end
local function after_catch(n)
    Wd.fish_catches = Wd.fish_catches + 1
    if Wd.deplete_after and Wd.fish_catches >= Wd.deplete_after then n.depleted = true end
end

local function step_world(dt)
    local h, c = Wd.held_now, Wd.comp
    Wd.pawn.stamina = math.min(100, Wd.pawn.stamina + 3 * dt)
    -- net trawl: hold primary with a net; released after >= 2 s inside a net node -> a catch 1 s later
    if Wd.held == "ITEM_Net_A" or Wd.held == "ITEM_Net_B" then
        if h.primary then Wd.trawl_hold = Wd.trawl_hold + dt
        elseif Wd.trawl_hold > 0 then
            local n, d = nearest_node(NET_TAG)
            if n and (d <= 150 or Wd.outside_ok) and Wd.trawl_hold >= 2 and Wd.pawn.stamina >= 10 then
                Wd.pawn.stamina = Wd.pawn.stamina - 10
                Wd.pending = { t = T + 1.0, fn = function() grant("ITEM_Fish_Shrimp"); after_catch(n) end }
            end
            Wd.trawl_hold = 0
        end
    end
    if Wd.pending and T >= Wd.pending.t then local f = Wd.pending.fn; Wd.pending = nil; f() end
    -- rod
    if Wd.held == "ITEM_Rod_A" or Wd.held == "ITEM_Rod_B" then
        if c.activity == 0 then
            if h.primary then Wd.charge = Wd.charge + dt; c.activity_casting = true
            elseif Wd.charge > 0 then
                local frac = math.min(Wd.charge / 1.0, 1)
                Wd.charge = 0
                local Fm = FM
                local v = Fm.cfg.speed_min_cm + (Fm.cfg.speed_max_cm - Fm.cfg.speed_min_cm) * frac
                local range = Fm.range_of(v, Fm.cfg.launch_deg, Fm.cfg.water_drop_cm) * Wd.k_true
                local n = nearest_node(ROD_TAG)
                local p = Wd.pawn.pos
                local dir = n and math.atan(n.pos.Y - p.Y, n.pos.X - p.X) or 0
                local hit = { X = p.X + math.cos(dir) * range, Y = p.Y + math.sin(dir) * range, Z = 0 }
                c.hit, c.session, c.changed_t = hit, c.session + 1, T
                if n and d2(hit, n.pos) <= 200 then
                    c.activity, c.cast = 2, 3
                    Wd.bite_at = (not Wd.no_bite) and T + 2.0 or nil
                    Wd.fight_node = n
                else
                    c.activity, c.cast = 0, 2
                end
            end
        elseif c.activity == 2 then
            if Wd.bite_at and T >= Wd.bite_at then c.activity, c.changed_t, c.reel, Wd.swim_t = 3, T, 0, T end
            if h.cancel then c.activity, c.changed_t = 0, T end
        elseif c.activity == 3 then
            -- swim cycle: left 1.5 s, right 1.5 s, resting 1.5 s
            local ph = math.floor((T - Wd.swim_t) / 1.5) % 3
            c.swim = ({ [0] = 1, [1] = 2, [2] = 0 })[ph]
            local want
            if c.swim == 1 then want = Wd.invert and "left" or "right" elseif c.swim == 2 then want = Wd.invert and "right" or "left" else want = "reel" end
            local good = h[want]
            local any = h.left or h.right or h.reel
            c.reel = c.reel + (good and 0.12 or (any and -0.1 or -0.03)) * dt
            if c.reel >= 0.3 then
                c.activity, c.result, c.changed_t = 0, 2, T
                grant("ITEM_Fish_Herring"); after_catch(Wd.fight_node)
            elseif c.reel <= -0.3 then
                c.activity, c.result, c.changed_t = 0, 0, T
            end
        end
    end
    Wd.held_prev, Wd.held_now = h, {}
end

-- ---------------------------------------------------------------- load the module with the fake world adapter
local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local F = assert(loadfile(root .. "/client_mod/scripts/fishing.lua"))()
F.clock = function() return T end
FM = F
F.set_modules({ move = fake_move, arbiter = A })
local fake_pc = { Pawn = "PAWN" }
local W = F.W
W.pc = function() return fake_pc end
W.pawn = function(pc) return pc and not Wd.pawn.dead and Wd.pawn or nil end
W.loc = function(p) return { X = p.pos.X, Y = p.pos.Y, Z = p.pos.Z } end
W.dead = function() return Wd.pawn.dead end
W.stamina = function() return Wd.pawn.stamina end
W.nodes = function()
    local out = {}
    for _, n in ipairs(Wd.nodes) do
        out[#out + 1] = { id = n.id, pos = n.pos, name = n.name, tag = n.tag, level = n.level, depleted = n.depleted, blocked = n.blocked, in_use = n.in_use }
    end
    return out
end
W.counts = function()
    local l = inv_list()
    local c = {}
    for _, where in ipairs({ "hotbar", "bag" }) do for _, e in ipairs(l[where]) do c[e.item] = (c[e.item] or 0) + e.count end end
    return c, l
end
W.skills = function() return { { skill = "Fishing", level = 1, xp = Wd.xp }, { skill = "Mining", level = 3, xp = 500 } } end
W.held_item = function() return Wd.held, nil end
W.equip = function(_, item) Wd.equips = Wd.equips + 1; Wd.held = item; return { ok = true, via = "hotbar key" } end
W.tools = function() return TOOLS end
W.actions = function() return { primary = IA.primary } end
W.inject = function(ia) Wd.held_now[ia.n] = true; return true end
W.gate = function() return Wd and Wd.modal or nil end
W.face = function(_, yaw) Wd.pawn.yaw = yaw end
W.comp = function() return Wd.comp end
W.fstate = function(c) return { activity = c.activity, cast = c.cast, result = c.result, swim = c.swim, reel = c.reel, hit = c.hit,
                               session = c.session, changed_t = c.changed_t } end
W.settings = function() return { full_s = 1.0, inputs = { left = IA.left, right = IA.right, reel = IA.reel, cancel = IA.cancel } } end
W.held_level = function() return TOOLS[Wd.held or ""] and TOOLS[Wd.held].pl or nil end
-- go_to / status / stop through fake_move (the module's own W.go_to calls mcall("move"...), set_modules covers it)
Wd = nil

local function pump(seconds, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(seconds / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        step_move(dt)
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        step_world(dt)
        if until_fn and until_fn() then return true end
    end
    return false
end

local function run(args, seconds)
    local r = F.HANDLERS.fish(nil, args, { id = "t1" })
    if not r.pending then return r end
    local res
    pump(seconds or 900, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT", data = { st = F.status().job } }
end

-- ================================================================ pure
do
    check("method net", F.method_of(NET_TAG) == "net")
    check("method rod", F.method_of(ROD_TAG) == "rod")
    check("method nil", F.method_of(nil) == nil)
    check("tag fits equal", F.tag_fits(NET_TAG, NET_TAG))
    check("tag fits child", F.tag_fits(NET_TAG .. ".Fine", NET_TAG))
    check("tag no prefix confusion", not F.tag_fits("Item.Equipment.Tool.Fishing.Netting", NET_TAG))
    check("tag rod vs net", not F.tag_fits(ROD_TAG, NET_TAG))
    local me = { X = 0, Y = 0, Z = 0 }
    local rows = { node("far", NET_TAG, { X = 3000, Y = 0, Z = 0 }), node("near", ROD_TAG, { X = 1000, Y = 0, Z = 0 }),
                   node("dep", NET_TAG, { X = 500, Y = 0, Z = 0 }, { depleted = true }) }
    local s = F.spots(rows, me, {})
    check("spots skip depleted by default", #s == 2 and s[1].id == "near", #s)
    s = F.spots(rows, me, { include_unusable = true })
    check("spots nearest first incl depleted", s[1].id == "dep" and s[1].distance_m == 5, s[1].id)
    check("spots radius", #F.spots(rows, me, { radius_cm = 2000 }) == 1)
    check("spots method filter", #F.spots(rows, me, { method = "net" }) == 1)
    local list = { hotbar = { { item = "ITEM_Net_A", category = NET_TAG }, { item = "ITEM_Net_B", category = NET_TAG },
                              { item = "ITEM_Rod_A", category = ROD_TAG, broken = true } } }
    local t = F.pick_tool(list, NET_TAG, TOOLS)
    check("pick highest-PL net", t and t.entry.item == "ITEM_Net_B", t and t.entry.item)
    check("broken rod not picked", F.pick_tool(list, ROD_TAG, TOOLS) == nil)
    local tm = F.tools_by_method(list, { NET_TAG, ROD_TAG })
    check("tools by method", tm.net ~= nil and tm.rod == nil)
    -- ballistics: farther wants more charge, and the predicted range matches the asked distance
    local f1, p1 = F.charge_for(900, {})
    local f2, p2 = F.charge_for(1500, {})
    check("charge monotone", f2 > f1, string.format("%.3f %.3f", f1, f2))
    check("charge hits the distance", math.abs(p1 - 900) < 5 and math.abs(p2 - 1500) < 5, p1 .. " " .. p2)
    local fk = F.charge_for(1500, { k = 1.3 })
    check("learned k>1 means less charge", fk < f2)
    local fmax = F.charge_for(1e7, {})
    check("charge clamps at 1", fmax == 1.0)
    -- learning converges to the true multiplier
    local L = { k = 1, n = 0 }
    for _ = 1, 6 do
        local _, pred = F.charge_for(1000, { k = L.k })
        local landed = pred / L.k * 1.3
        L = F.learn_cast(L, pred, landed)
    end
    check("learn_cast converges to 1.3", math.abs(L.k - 1.3) < 0.02, L.k)
    check("learn_cast ignores junk", F.learn_cast({ k = 1, n = 0 }, nil, 5).k == 1)
    check("fight: swim left -> pull right", F.fight_input(1) == "right")
    check("fight: swim right -> pull left", F.fight_input(2) == "left")
    check("fight: resting -> reel", F.fight_input(0) == "reel")
    check("fight: swapped", F.fight_input(1, true) == "left")
    local g, n = F.gains({ a = 1 }, { a = 3, b = 1 })
    check("gains", n == 3 and g.a == 2 and g.b == 1)
    local xd = F.xp_delta({ { skill = "Fishing", level = 1, xp = 10 } }, { { skill = "Fishing", level = 2, xp = 60 } })
    check("xp delta", xd and xd.Fishing.xp == 50 and xd.Fishing.level == 2)
    check("xp delta none", F.xp_delta({ { skill = "Fishing", xp = 1 } }, { { skill = "Fishing", xp = 1 } }) == nil)
    local sp = F.stand_point({ X = 0, Y = 0 }, { X = 1000, Y = 0, Z = 0 }, 800, 1, 8)
    check("first stand point faces me", math.abs(sp.X - 800) < 1 and math.abs(sp.Y) < 1)
end

-- ================================================================ choose failures (truthful reasons)
do
    reset({ inv = { ITEM_Rod_A = 1 }, nodes = {} })
    local r = F.HANDLERS.fish(nil, { count = 2 }, { id = "x" })
    check("no spot -> nothing_in_range", r.ok == false and r.reason == "nothing_in_range" and r.data.why == "no_spot", r.reason)
    check("no spot detail", r.data.detail:find("can't see a fishing spot", 1, true) ~= nil, r.data.detail)

    reset({ inv = { ITEM_Rod_A = 1 }, nodes = { node("n1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    r = F.HANDLERS.fish(nil, { count = 2 }, { id = "x" })
    check("net spot, only a rod -> wrong_tool", r.reason == "wrong_tool" and r.data.why == "no_tool", r.reason)
    check("wrong_tool names the method", r.data.detail:find("net", 1, true) ~= nil, r.data.detail)
    check("wrong_tool lists the spots seen", r.data.spots and #r.data.spots == 1 and r.data.spots[1].pos == nil)

    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("n1", NET_TAG, { X = 800, Y = 0, Z = 0 }, { depleted = true }) } })
    r = F.HANDLERS.fish(nil, { count = 2 }, { id = "x" })
    check("all depleted", r.reason == "nothing_in_range" and r.data.why == "all_depleted", r.data.why)

    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("n1", NET_TAG, { X = 800, Y = 0, Z = 0 }) }, empty = 0 })
    r = F.HANDLERS.fish(nil, { count = 2 }, { id = "x" })
    check("bags full", r.reason == "inventory_full", r.reason)

    r = F.HANDLERS.fish(nil, { count = 0 }, { id = "x" })
    check("invalid count", r.reason == "invalid_args")

    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("n1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    r = F.HANDLERS.fish(nil, { spot = "nope" }, { id = "x" })
    check("unknown spot id", r.reason == "unknown_target" and r.data.why == "unknown_spot", r.reason)
    _G.DW_PAUSE = true
    r = F.HANDLERS.fish(nil, {}, { id = "x" })
    check("paused -> companion_down", r.reason == "companion_down")
    _G.DW_PAUSE = nil
end

-- ================================================================ net fishing: whole job
do
    reset({ inv = { ITEM_Net_A = 1, ITEM_Net_B = 1, ITEM_Rod_A = 1 },
            nodes = { node("rod1", ROD_TAG, { X = 4000, Y = 0, Z = 0 }), node("net1", NET_TAG, { X = 1500, Y = 500, Z = 0 }) } })
    local res = run({ count = 3 }, 300)
    check("net: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("net: nearest usable spot chosen", res.data.spot == "net1", res.data.spot)
    check("net: method", res.data.method == "net")
    check("net: best net used", Wd.held == "ITEM_Net_B", Wd.held)
    check("net: caught 3", res.data.caught == 3, res.data.caught)
    check("net: bag gained the fish", res.data.gained and res.data.gained.ITEM_Fish_Shrimp == 3)
    check("net: xp reported", res.data.xp and res.data.xp.Fishing and res.data.xp.Fishing.xp == 75, res.data.xp and res.data.xp.Fishing and res.data.xp.Fishing.xp)
    check("net: stood in the spot", d2(Wd.pawn.pos, Wd.nodes[2].pos) <= 150)
    check("net: arbiter released", A.owner() == nil)
    check("net: detail is a sentence", type(res.data.detail) == "string" and res.data.detail:find("Caught 3", 1, true) ~= nil, res.data.detail)
end

do -- the spot is fished out after one catch: ok with what he got, truthful sentence
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }) }, deplete_after = 1 })
    local res = run({ count = 4 }, 300)
    check("net depleted: ok with partial", res.ok == true and res.data.caught == 1 and res.data.why == "depleted", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("net depleted: says so", res.data.detail:find("fished out", 1, true) ~= nil, res.data.detail)
end

do -- the spot is out in the water: can't walk there
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 1500, Y = 0, Z = 0 }) },
            water = function(p) return p.X > 900 end })
    local res = run({ count = 2 }, 200)
    check("net unreachable: path_blocked", res.ok == false and res.reason == "path_blocked" and res.data.why == "cant_reach_spot", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("net unreachable: names the distance", res.data.detail:find("m away", 1, true) ~= nil, res.data.detail)
end

do -- he reaches the edge but the game never runs the trawl (not inside): walks in once, then says why
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 1500, Y = 0, Z = 0 }) },
            water = function(p) return p.X > 1300 end })
    local res = run({ count = 2 }, 300)
    check("net outside: verification_failed", res.reason == "verification_failed" and res.data.why == "trawl_not_running", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("net outside: tried trawling", (res.data.trawls or 0) >= 2, res.data.trawls)
end

-- ================================================================ rod fishing: whole job, learning the cast
do
    reset({ inv = { ITEM_Rod_B = 1 }, nodes = { node("rod1", ROD_TAG, { X = 1000, Y = 0, Z = 0 }) }, k_true = 1.35 })
    local res = run({ count = 2 }, 600)
    check("rod: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("rod: caught 2", res.data.caught == 2, res.data.caught)
    check("rod: missed then learned", (res.data.casts or 0) >= 3, res.data.casts)
    local L = F.status().learned.ITEM_Rod_B
    check("rod: learned k near truth", L and math.abs(L.k - 1.35) < 0.15, L and L.k)
    check("rod: fish in the bag", Wd.inv.ITEM_Fish_Herring == 2)
    check("rod: stood back from the spot", d2(Wd.pawn.pos, Wd.nodes[1].pos) >= 600)
end

do -- the game's pull directions are the other way round: the self-check swaps and still lands it
    reset({ inv = { ITEM_Rod_A = 1 }, nodes = { node("rod1", ROD_TAG, { X = 1000, Y = 0, Z = 0 }) }, invert = true })
    local res = run({ count = 1 }, 600)
    check("rod inverted: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("rod inverted: swap learned", F.status().last and F.status().last.result.ok == true)
end

do -- nothing bites: three waits, then a truthful no_bite (and the cancel input was used)
    reset({ inv = { ITEM_Rod_A = 1 }, nodes = { node("rod1", ROD_TAG, { X = 1000, Y = 0, Z = 0 }) }, no_bite = true })
    F.cfg.bite_wait_s = 5
    local res = run({ count = 1 }, 600)
    F.cfg.bite_wait_s = 45
    check("rod no bite: nothing_in_range", res.reason == "nothing_in_range" and res.data.why == "no_bite", tostring(res.reason) .. " " .. tostring(res.data.why))
end

do -- rod spot too close: he walks out to a bank spot first
    reset({ inv = { ITEM_Rod_A = 1 }, nodes = { node("rod1", ROD_TAG, { X = 200, Y = 0, Z = 0 }) } })
    local res = run({ count = 1 }, 600)
    check("rod close: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
end

-- ================================================================ interruptions
do
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    local r = F.HANDLERS.fish(nil, { count = 20 }, { id = "t" })
    pump(3)
    r.pending.cancel()
    local res = r.pending.poll()
    check("cancel -> interrupted", res and res.reason == "interrupted", res and res.reason)
    check("cancel: arbiter released", A.owner() == nil)

    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    r = F.HANDLERS.fish(nil, { count = 20 }, { id = "t" })
    pump(2)
    _G.DW_PAUSE = true
    pump(0.2)
    res = r.pending.poll()
    check("pause -> interrupted world_teardown", res and res.reason == "interrupted" and res.data.why == "world_teardown", res and res.data and res.data.why)
    _G.DW_PAUSE = nil
end

-- ================================================================ modal gate: no injection while a screen is open
do
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    Wd.modal = { kind = "build" }
    local res = run({ count = 1 }, 60)
    check("gated: never trawls while build mode is open", (Wd.inv.ITEM_Fish_Shrimp or 0) == 0)
    check("gated: says which screen", res.reason == "interrupted" and res.data.why == "screen_open" and res.data.detail:find("build", 1, true) ~= nil,
        tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }) } })
    Wd.modal = { kind = "container" }
    local r = F.HANDLERS.fish(nil, { count = 1 }, { id = "g" })
    pump(4)
    Wd.modal = nil
    local res2
    pump(120, function() res2 = r.pending.poll(); return res2 ~= nil end)
    check("gated: resumes once the screen closes", res2 and res2.ok == true, res2 and res2.reason)
end

-- ================================================================ read tool, extras, contract
do
    reset({ inv = { ITEM_Net_A = 1 }, nodes = { node("net1", NET_TAG, { X = 800, Y = 0, Z = 0 }), node("rod1", ROD_TAG, { X = 1600, Y = 0, Z = 0 }) } })
    local r = F.HANDLERS.fishing_spots(nil, {})
    check("spots tool ok", r.ok and #r.data.spots == 2)
    check("spots tool: my tool fits net", r.data.spots[1].my_tool ~= nil and r.data.spots[2].my_tool == nil)
    check("spots tool: methods", r.data.spots[1].method == "net" and r.data.spots[2].method == "rod")
    check("spots tool: my tools by method", r.data.my_tools.net ~= nil and r.data.my_tools.rod == nil)
    local ex = F.state_extras({ now = function() return 1 end })
    check("extras: fishing_spots_nearby", ex.fishing_spots_nearby and #ex.fishing_spots_nearby == 2)
    for name, e in pairs(F.MANIFEST) do
        check("manifest " .. name .. " has kind+description", e.kind and type(e.description) == "string")
        check("manifest " .. name .. " no top-level anyOf", e.args and e.args.anyOf == nil)
    end
    check("fish is an llm action that moves", F.MANIFEST.fish.llm and F.MANIFEST.fish.moves and F.MANIFEST.fish.kind == "action")
    check("fishing_spots is a read", F.MANIFEST.fishing_spots.kind == "read" and F.MANIFEST.fishing_spots.llm)
    check("needs declared", F.NEEDS.fish and F.NEEDS.fishing_spots)
    -- no names of items/places/creatures in the module logic: tags and classes come from data
    local src = assert(io.open(root .. "/client_mod/scripts/fishing.lua", "rb")):read("*a")
    check("no item ids in logic", not src:find("ITEM_", 1, true))
    check("no server RPC calls", not src:gsub("%-%-[^\n]*", ""):find("[:.]Server_%w+%s*%(") )
end

print(string.format("test_fishing: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
