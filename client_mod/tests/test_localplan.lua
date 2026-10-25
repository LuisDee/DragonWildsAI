-- Offline test for client_mod/scripts/localplan.lua: a fake heightfield world with an alcove under
-- an overhang (the Shockbyte lodestone-pad trap), a step-up exit and a thin wall.
-- Usage: lua test_localplan.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local LP = dofile(here .. "/../scripts/localplan.lua")

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
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
