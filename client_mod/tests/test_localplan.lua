-- Offline test for client_mod/scripts/localplan.lua: a fake heightfield world with an alcove under
-- an overhang (the Shockbyte lodestone-pad trap), a step-up exit and a thin wall.
-- Usage: lua test_localplan.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local LP = dofile(os.getenv("LP_FILE") or (here .. "/../scripts/localplan.lua"))

-- World: pit floor z=0 in |x|,|y| < 300; upper ground z=340 elsewhere; an intermediate shelf z=200
-- at x in [-600,-300) (the exit: 2 jumps); an overhang roof slab z in [400,520] over x in [-100,300]
-- (so a top-down trace there sees the roof, not the pit floor); a thin wall at x in [900,920] for
-- y in [-2000, 150] up to z 900 (only a horizontal trace sees it; it's thinner than a cell).
local function ground(x, y)
    if math.abs(y) < 300 and x > -300 and x < 300 then return 0 end
    if math.abs(y) < 300 and x >= -600 and x <= -300 then return 200 end
    return 340
end
local function roof(x, y) return x > -100 and x < 300 and math.abs(y) < 300 end
local function wall(x, y, z) return x >= 900 and x <= 920 and y > -2000 and y < 150 and z < 900 end

local traces = 0
local function trace(a, b, horizontal)
    traces = traces + 1
    if horizontal then
        for k = 0, 40 do
            local t = k / 40
            local x, y, z = a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z
            if wall(x, y, z) or ground(x, y) > z then return true end
        end
        return nil
    end
    local x, y = a.X, a.Y
    local g = ground(x, y)
    if roof(x, y) then
        if a.Z >= 400 and a.Z <= 520 then return 520, true end   -- start inside the slab
        if a.Z > 520 then return 520, false end                   -- hits the roof top
    end
    if a.Z < g then return g, true end
    return g, false
end

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

local P = LP.new({ trace = trace, center = { X = 0, Y = 0, Z = 90 }, radius_m = 14, cell_cm = 100,
    env = { step = 45, jump = 250, djump = 300, drop = 600 } })
local st, n = "sampling", 0
while st ~= "ready" do st = P:step(12); n = n + 1 end
check("sampling finishes in budgeted steps", n > 50, n)
local goal = { X = 1500, Y = 0, Z = 340 }
local pts, why = P:plan(goal)
check("plan found", pts ~= nil, why)
local acts, last = {}, pts and pts[#pts]
for _, p in ipairs(pts or {}) do acts[p.act] = (acts[p.act] or 0) + 1 end
check("route leaves the pit by jumping (no 340 cm single jump)", (acts.jump or 0) >= 1, acts.jump)
check("never a single jump higher than the envelope", (function()
    for k = 2, #(pts or {}) do
        local dz = pts[k].Z - pts[k - 1].Z
        if pts[k].act == "jump" and dz > 250 then return false end
        if pts[k].act == "walk" and math.abs(dz) > 45 then return false end
    end
    return true end)())
check("ends near the goal", last and math.sqrt((last.X - goal.X) ^ 2 + (last.Y - goal.Y) ^ 2) < 200, last and last.X)

-- lazy wall check: the straight route crosses the thin wall; verify must block and replan around
local rounds, res = 0, "blocked"
while res ~= "ok" and rounds < 40 do
    res = P:verify(pts, 50)
    if res == "blocked" then pts = P:plan(goal); rounds = rounds + 1 end
end
check("lazy verify converges", res == "ok", res)
local crosses = false
for k = 2, #(pts or {}) do
    local a, b = pts[k - 1], pts[k]
    if (a.X < 900 and b.X > 920 or b.X < 900 and a.X > 920 or (a.X >= 900 and a.X <= 920)) and math.min(a.Y, b.Y) < 150 then crosses = true end
end
check("final route goes around the thin wall", not crosses and rounds >= 1, "rounds=" .. rounds)
check("trace count bounded", traces < 2500, traces)
print(string.format("traces=%d expanded=%s replans=%d points=%d", traces, tostring(P.expanded), rounds, #(pts or {})))

-- cache: a second plan from (almost) the same spot reuses the cells, and prefetch fills new ones
local clock = 0
local cache = { cells = {}, ttl = 30 }
local P1 = LP.new({ trace = trace, center = { X = 0, Y = 0, Z = 90 }, radius_m = 6, cache = cache, now = function() return clock end,
    env = { step = 45, jump = 250, djump = 300, drop = 600 } })
while P1:step(50) ~= "ready" do end
local P2 = LP.new({ trace = trace, center = { X = 30, Y = -20, Z = 90 }, radius_m = 6, cache = cache, now = function() return clock end,
    env = { step = 45, jump = 250, djump = 300, drop = 600 } })
while P2:step(50) ~= "ready" do end
check("second plan reuses cached cells", P2.traces == 0 and P2.cache_hits > 100, P2.traces .. " hits=" .. P2.cache_hits)
check("prefetch skips cached, samples new", LP.prefetch(cache, trace, 0, 0, 0) == 0 and LP.prefetch(cache, trace, 5000, 5000, 0) == 2)
clock = 100
local P3 = LP.new({ trace = trace, center = { X = 0, Y = 0, Z = 90 }, radius_m = 6, cache = cache, now = function() return clock end,
    env = { step = 45, jump = 250, djump = 300, drop = 600 } })
while P3:step(50) ~= "ready" do end
check("stale cache entries are re-sampled", P3.traces > 100, P3.traces)
-- slopes vs steps: a 30 deg ramp (0.58 cm per cm, > the 45 cm step per 1 m cell) must be WALKED;
-- a 90 cm vertical step must be a JUMP (the midpoint trace tells them apart)
local function g2(x, y)
    if x < 0 then return 0 end
    if x < 500 then return 0.58 * x end           -- ramp up to 290 cm
    if x < 900 then return 290 end
    return 380                                    -- 90 cm step at x = 900
end
local function trace2(a, b, horizontal)
    if horizontal then
        for k = 0, 20 do
            local t = k / 20
            if g2(a.X + (b.X - a.X) * t, 0) > a.Z then return true end
        end
        return nil
    end
    local gz = g2(a.X, a.Y)
    if a.Z < gz then return gz, true end
    return gz, false
end
local Ps = LP.new({ trace = trace2, center = { X = -300, Y = 0, Z = 90 }, radius_m = 14, env = { step = 45, jump = 165, djump = 165, drop = 600 } })
while Ps:step(50) ~= "ready" do end
local sp = Ps:plan({ X = 1300, Y = 0, Z = 380 })
local r2 = 0
local res2 = "blocked"
while res2 ~= "ok" and r2 < 30 do
    res2 = Ps:verify(sp, 100)
    if res2 == "blocked" then sp = Ps:plan({ X = 1300, Y = 0, Z = 380 }); r2 = r2 + 1 end
end
local ramp_jumps, step_jump = 0, false
for k = 2, #(sp or {}) do
    local p0, p1 = sp[k - 1], sp[k]
    if p1.act == "jump" and p1.X <= 500 then ramp_jumps = ramp_jumps + 1 end
    if p1.act == "jump" and p0.X < 900 and p1.X >= 900 then step_jump = true end
end
check("30 deg ramp is walked, not jumped", sp and ramp_jumps == 0, ramp_jumps)
check("90 cm step is a jump", step_jump, "replans=" .. r2)

-- ramp over low dead space (church start area, live 19:22): a 20 deg ramp rises from the lower
-- ground to an upper floor 3.4 m up; UNDER the ramp is ground with < head clearance. Each ramp cell
-- yields lo = ground under it, hi = ramp surface; the walkable one is the ramp.
local function ramp_top(x) if x < 0 then return 0 end; if x < 930 then return 0.366 * x end; return 340 end
local function trace3(a, b, horizontal)
    if horizontal then
        for k = 0, 20 do
            local t = k / 20
            local x = a.X + (b.X - a.X) * t
            if ramp_top(x) > a.Z and not (a.Z < ramp_top(x) - 30) then return true end
        end
        return nil
    end
    local top = ramp_top(a.X)
    if a.Z >= top then return top, false end                 -- from above: the ramp surface
    -- from below the ramp surface (inside the dead space under it): the ground under the ramp
    if a.Z > 0 then return 0, false end
    return 0, true
end
local Pr = LP.new({ trace = trace3, center = { X = -200, Y = 0, Z = 90 }, radius_m = 14, env = { step = 45, jump = 165, djump = 165, drop = 600 } })
while Pr:step(60) ~= "ready" do end
local rp = Pr:plan({ X = 1100, Y = 0, Z = 340 })
local rr, rres = 0, "blocked"
while rp and rres ~= "ok" and rr < 30 do
    rres = Pr:verify(rp, 100)
    if rres == "blocked" then rp = Pr:plan({ X = 1100, Y = 0, Z = 340 }); rr = rr + 1 end
end
local top_end = rp and rp[#rp]
check("ramp over dead space: route climbs the ramp to the upper floor", top_end and top_end.Z >= 300 and top_end.X > 900,
    top_end and string.format("end (%.0f,%.0f)", top_end.X, top_end.Z) or "no plan")

-- A low obstacle must not produce a hop without enough reach for a probe
-- above knee height. A real wall remains blocked even with jump reach.
local function hop_case(reach, wall_high)
    local heights = {}
    local function obstacle(a, b, horizontal)
        if horizontal then
            heights[#heights + 1] = a.Z
            return wall_high or a.Z <= 50
        end
        return 0, false
    end
    local p = LP.new({ trace = obstacle, center = { X = 0, Y = 0, Z = 90 }, env = { step = 45, jump = reach } })
    local a, b = {i=0, j=0, z=0}, {i=1, j=0, z=0}
    local pts = { {X=0, Y=0, Z=0, node=a}, {X=100, Y=0, Z=0, node=b, act="walk"} }
    local result = p:verify(pts, 10)
    return p, a, b, result, heights
end
local zero, za, zb, zr, zh = hop_case(0, false)
check("zero jump blocks low obstacle without high probe", zr == "blocked" and #zh == 1 and zh[1] == 50)
zero.hop[tostring(za) .. ">" .. tostring(zb)] = true
check("zero jump ignores remembered hop", zero:edge(za, zb) == "walk")
zero.wall_pts = { {X=50, Y=0, Z=50} }
check("zero jump remembered hop cannot bypass wall", zero:crosses_wall(za, zb))
local small, sa, sb, sr, sh = hop_case(70, false)
check("insufficient jump clearance blocks without high probe", sr == "blocked" and #sh == 1 and sh[1] == 50)
small.hop[tostring(sa) .. ">" .. tostring(sb)] = true
check("insufficient jump clearance ignores remembered hop", small:edge(sa, sb) == "walk")
small.wall_pts = { {X=50, Y=0, Z=50} }
check("insufficient jump remembered hop cannot bypass wall", small:crosses_wall(sa, sb))
local _, _, _, equal_result, equal_heights = hop_case(80, false)
check("equal-height hop probe is skipped", equal_result == "blocked" and #equal_heights == 1 and equal_heights[1] == 50)
local hop, ha, hb, hr, hh = hop_case(165, false)
check("positive jump probes above knee and proposes hop", hr == "blocked" and #hh == 2 and hh[2] > hh[1] and hop:edge(ha, hb) == "jump")
local solid, wa, wb, wr, wh = hop_case(165, true)
check("true wall remains blocked with jump reach", wr == "blocked" and #wh == 2 and solid:edge(wa, wb) == "walk" and next(solid.hop) == nil)

-- Too steep to stand on (live 2026-11-01 15:56): a level-looking band whose surface normal is 0.4 (66 degrees)
-- across the direct line is no floor when walk_z is given; the route goes round it (without walk_z it walks over)
do
    local function steep_band(x, y) return x > 250 and x < 450 and math.abs(y) < 250 end
    local function trace_s(a, b, horizontal)
        if horizontal then return nil end
        if a.Z < 0 then return 0, true end
        return 0, false, steep_band(a.X, a.Y) and 0.4 or 1.0
    end
    local function route(walk_z)
        local Pz = LP.new({ trace = trace_s, center = { X = 0, Y = 0, Z = 90 }, radius_m = 8, walk_z = walk_z,
            env = { step = 45, jump = 165, djump = 165, drop = 600 } })
        local s2 = "sampling"
        while s2 ~= "ready" do s2 = Pz:step(64) end
        local pz = Pz:plan({ X = 700, Y = 0, Z = 0 })
        local over = false
        for _, q in ipairs(pz or {}) do if steep_band(q.X, q.Y) then over = true end end
        return pz, over
    end
    local p1, over1 = route(0.70)
    local p0, over0 = route(nil)
    check("steep band (normal 0.4) is no floor: the route goes round it", p1 ~= nil and not over1 and over0, tostring(over1) .. " " .. tostring(over0))
end

-- LEAP over a gap (live 2026-11-01 18:31Z, the Bramblemead stair landings 1.6-1.8 m apart over a 3.6 m drop):
-- a deck at z 0 for |y| < 300, cut by a 1.6 m gap at x 160-320 over ground at -360; void elsewhere (no way round).
-- The route leaps from the take-off cell (x 100) to x 400 after a straight run-up (x 0 -> 100); with no jump
-- (encumbered) there is no route across; a gap with a floor in it at deck level is walked, not leapt.
do
    local function deck(x, y) return math.abs(y) < 300 and (x < 160 or x > 320) end
    local function pit(x, y) return math.abs(y) < 300 and x >= 160 and x <= 320 end
    local bridge = false
    local function trace_g(a, b, horizontal)
        if horizontal then return nil end
        local z = (deck(a.X, a.Y) or (bridge and pit(a.X, a.Y))) and 0 or (pit(a.X, a.Y) and -360 or nil)
        if not z then return nil end
        if a.Z < z then return z, true end
        return z, false
    end
    local function route(jump, avoid)
        local Pg = LP.new({ trace = trace_g, center = { X = 0, Y = 0, Z = 90 }, radius_m = 8, avoid = avoid,
            env = { step = 45, jump = jump, djump = jump, drop = 600 } })
        local s2 = "sampling"
        while s2 ~= "ready" do s2 = Pg:step(64) end
        return Pg:plan({ X = 700, Y = 0, Z = 0 })
    end
    local pg = route(165)
    local li
    for k, q in ipairs(pg or {}) do if q.leap then li = k end end
    local L, T, R = li and pg[li], li and pg[li - 1], li and pg[li - 2]
    check("leap: the route jumps the gap from the take-off cell", L and L.act == "jump" and L.X == 400 and L.Z == 0
        and T and T.act == "walk" and T.X == 100, L and (L.X .. "," .. tostring(T and T.X)) or "no leap")
    check("leap: a straight run-up into the take-off", R and R.Y == T.Y and R.X == T.X - 100, R and (R.X .. "," .. R.Y))
    local last = pg and pg[#pg]
    check("leap: the route goes on to the goal", last and last.X >= 600, last and last.X)
    local av = {}
    for y = -200, 200, 100 do av[LP.edge_key(100, y, 0) .. ">" .. LP.edge_key(400, y, 0)] = true end
    local pa = route(165, av)
    local across = false
    for _, q in ipairs(pa or {}) do if q.X > 320 then across = true end end
    check("leap: a leap that failed on this trip is left out of the next plan", not across, pa and #pa)
    local p0, why0 = route(0)
    local crossed = false
    for _, q in ipairs(p0 or {}) do if q.X > 320 then crossed = true end end
    check("leap: no jump (encumbered) -> no way across", not crossed, why0)
    bridge = true
    local pb = route(165)
    local leapt = false
    for _, q in ipairs(pb or {}) do if q.leap then leapt = true end end
    check("leap: a floor across the gap is walked, not leapt", pb and not leapt and pb[#pb].X >= 600, tostring(leapt))
    -- a 9 m wall in the "gap" (its cells have no floor: every trace starts inside it) is a wall, not a hole
    -- (test_avoidzones' wall with two gaps was leapt straight through, 2026-11-01)
    bridge = false
    local wall = true
    local trace_w0 = trace_g
    trace_g = function(a, b, horizontal)
        if wall and not horizontal and pit(a.X, a.Y) then if a.Z < 900 then return 900, true end return 900, false end
        return trace_w0(a, b, horizontal)
    end
    local pw = route(165)
    local over = false
    for _, q in ipairs(pw or {}) do if q.leap or q.X > 320 then over = true end end
    check("leap: a tall wall is not leapt as a gap", not over, pw and #pw)
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
