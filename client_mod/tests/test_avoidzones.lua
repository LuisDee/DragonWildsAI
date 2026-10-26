-- Offline test for client_mod/scripts/avoidzones.lua (pure geometry) and its use as a local-planner
-- cell cost (scripts/localplan.lua). Usage: lua test_avoidzones.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local AZ = dofile(os.getenv("AZ_FILE") or (here .. "/../scripts/avoidzones.lua"))
local LP = dofile(here .. "/../scripts/localplan.lua")

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- normalize: units, validation, scalars only
local zs, err = AZ.normalize({ { id = "c", x = 1, y = 2, z = 0, r_cm = 300, until_s = 50 },
    { id = "k", kind = "cone", x = 0, y = 0, r_cm = 1000, until_s = 40, yaw_deg = 90, half_angle_deg = 30 } }, 10)
check("normalize: metres -> cm", zs and zs[1].X == 100 and zs[1].Y == 200 and zs[1].Z == 0 and zs[1].r == 300, err)
check("normalize: cone angles in radians", zs and math.abs(zs[2].yaw - math.pi / 2) < 1e-9 and math.abs(zs[2].half - math.pi / 6) < 1e-9)
check("normalize: ttl_s relative to now", (AZ.normalize({ { x = 0, y = 0, r_cm = 1, ttl_s = 2 } }, 10) or {})[1].until_s == 12)
check("normalize: empty list = no zones", #assert(AZ.normalize({}, 0)) == 0)
local bad = {
    { { x = 0, y = 0, r_cm = 100, until_s = 1, pos = {} }, "scalars only" },
    { { x = 0, y = 0, r_cm = 100 }, "until_s" },
    { { x = 0, y = 0, r_cm = 0, until_s = 1 }, "r_cm" },
    { { x = 123456, y = 0, r_cm = 100, until_s = 1 }, "centimetres" },
    { { x = 0, y = 0, r_cm = 100, until_s = 1, kind = "square" }, "kind" },
    { { x = 0, y = 0, r_cm = 100, until_s = 1, kind = "cone", yaw_deg = 0 }, "cone needs" },
    { { x = 0, y = 0, r_cm = 100, ttl_s = 1 }, "game clock" },
}
for _, b in ipairs(bad) do
    local now0 = 0; if b[2] == "game clock" then now0 = nil end
    local z2, e2 = AZ.normalize({ b[1] }, now0)
    check("normalize refuses: " .. b[2], z2 == nil and tostring(e2):find(b[2], 1, true) ~= nil, e2)
end

-- contains: circle (with capsule margin, vertical reach), cone (inside, lateral margin, behind apex)
local c = zs[1]
check("circle: inside", AZ.contains(c, 100, 200, nil, 0))
check("circle: edge + margin", AZ.contains(c, 100 + 330, 200, nil, 40) and not AZ.contains(c, 100 + 330, 200, nil, 0))
check("circle: out of vertical reach", not AZ.contains(c, 100, 200, 500, 0) and AZ.contains(c, 100, 200, 300, 0))
local k = zs[2] -- apex (0,0), facing +Y, half 30 deg, range 10 m
check("cone: on the axis", AZ.contains(k, 0, 500, nil, 0))
check("cone: 25 deg off the axis", AZ.contains(k, 500 * math.sin(math.rad(25)), 500 * math.cos(math.rad(25)), nil, 0))
check("cone: 40 deg off = outside", not AZ.contains(k, 500 * math.sin(math.rad(40)), 500 * math.cos(math.rad(40)), nil, 0))
check("cone: 40 deg off but within the capsule margin of the edge", AZ.contains(k, 500 * math.sin(math.rad(33)), 500 * math.cos(math.rad(33)), nil, 40))
check("cone: behind the apex = outside", not AZ.contains(k, 0, -300, nil, 40))
check("cone: beyond range = outside", not AZ.contains(k, 0, 1100, nil, 40))

-- at: the longest-lasting containing zone; prune; cost cheaper for sooner-ending zones
check("at: longest-lasting wins", AZ.at(zs, 50, 150, nil, 0).id == "c")
local cs = AZ.cost(zs, 0, 500, nil, 10, 0)
local soon = assert(AZ.normalize({ { x = 0, y = 0, r_cm = 100, until_s = 11 } }, 0))
local late = assert(AZ.normalize({ { x = 0, y = 0, r_cm = 100, until_s = 30 } }, 0))
check("cost: sooner-ending zone is cheaper", AZ.cost(soon, 0, 0, nil, 10, 0) < AZ.cost(late, 0, 0, nil, 10, 0), cs)
check("cost: zero outside", AZ.cost(zs, 5000, 5000, nil, 10, 0) == 0)
local pz = assert(AZ.normalize({ { x = 0, y = 0, r_cm = 1, until_s = 5 }, { x = 0, y = 0, r_cm = 1, until_s = 20 } }, 0))
AZ.prune(pz, 10)
check("prune drops expired", #pz == 1 and pz[1].until_s == 20)

-- segments and routes
local z1, s1 = AZ.on_segment(zs, { X = -1000, Y = 200 }, { X = 1000, Y = 200 }, nil, 0)
check("on_segment: first zone and distance", z1 and z1.id == "c" and s1 > 700 and s1 < 850, s1)
check("on_segment: miss", AZ.on_segment(zs, { X = -1000, Y = -2000 }, { X = 1000, Y = -2000 }, nil, 0) == nil)
check("on_route: polyline through the cone", (AZ.on_route(zs, { X = 2000, Y = 0 }, { { X = 2000, Y = 600 }, { X = 0, Y = 600 } }, 1, nil, 0) or {}).id == "k")

-- exits: nearest point outside every zone, bounded
local one = assert(AZ.normalize({ { id = "o", x = 0.5, y = 0, r_cm = 300, until_s = 99 } }, 0))
local ex = AZ.exits(one, { X = 0, Y = 0 }, nil, { margin = 100 })
check("exits: nearest is straight away from the centre (-X)", ex[1] and ex[1].X < -300 and math.abs(ex[1].Y) < 120 and ex[1].dist <= 375, ex[1] and ex[1].dist)
check("exits: every candidate is outside", (function() for _, e in ipairs(ex) do if AZ.at(one, e.X, e.Y, nil, 100) then return false end end return true end)())
check("exits: none inside a bound that the zone covers", #AZ.exits(one, { X = 0, Y = 0 }, nil, { margin = 100, bound = { X = 0, Y = 0, r = 200 } }) == 0)
local ring = assert(AZ.normalize({ { id = "a", x = 0, y = 0, r_cm = 300, until_s = 99 }, { id = "b", x = -4, y = 0, r_cm = 300, until_s = 99 } }, 0))
local ex2 = AZ.exits(ring, { X = 0, Y = 0 }, nil, { margin = 50 })
check("exits: never into a neighbouring zone", ex2[1] and ex2[1].X > 0 and not AZ.at(ring, ex2[1].X, ex2[1].Y, nil, 50), ex2[1] and ex2[1].X)

-- local planner with zones as a cell cost: a wall at x 4..5 m with two gaps (y -4..-2 and 2..4), each
-- gap covered by a zone. The route must take the gap whose zone ends sooner (a cost, not a wall).
local function ground(x, y)
    if x >= 400 and x <= 500 and not ((y >= -400 and y <= -200) or (y >= 200 and y <= 400)) then return 900 end
    return 0
end
local function trace(a, b, horizontal)
    if horizontal then
        for kk = 0, 40 do
            local t = kk / 40
            if ground(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) > a.Z then return true end
        end
        return nil
    end
    local g = ground(a.X, a.Y)
    if a.Z < g then return g, true end
    return g, false
end
local function plan_with(zones, now_s)
    local P = LP.new({ trace = trace, center = { X = 0, Y = 0, Z = 90 }, feet_z = 0, radius_m = 9, cell_cm = 100,
        env = { step = 45, jump = 105, djump = 105, drop = 300 },
        cell_cost = function(x, y, fz) return AZ.cost(zones, x, y, fz, now_s, 40) end, dry_slack = 600 })
    while P:step(400) ~= "ready" do end
    local pts
    for _ = 1, 12 do
        pts = P:plan({ X = 900, Y = 0, Z = 90 })
        if not pts then break end
        local r = P:verify(pts, 10000)
        if r == "ok" then break end
    end
    return pts
end
local function through(pts)
    for _, p in ipairs(pts or {}) do if p.X >= 400 and p.X <= 500 then return p.Y end end
end
local gaps = function(ua, ub) return assert(AZ.normalize({ { id = "A", x = 0, y = -3, r_cm = 150, until_s = ua }, { id = "B", x = 0, y = 3, r_cm = 150, until_s = ub } }, 0)) end
-- zones placed on the gaps (x = 4.5 m)
local function on_gaps(ua, ub) local g = gaps(ua, ub); g[1].X, g[2].X = 450, 450; return g end
local yB = through(plan_with(on_gaps(30, 12), 10))
check("planner: crosses the zone that ends sooner (B, +y gap)", yB and yB > 0, yB)
local yA = through(plan_with(on_gaps(12, 30), 10))
check("planner: ... and A when A ends sooner", yA and yA < 0, yA)
-- open field, one zone straight ahead: the route goes round it, never through
local open = function() return 0 end
ground = open
local blob = assert(AZ.normalize({ { id = "Z", x = 4.5, y = 0, r_cm = 200, until_s = 60 } }, 0))
local pts = plan_with(blob, 10)
local clean = pts ~= nil
for _, p in ipairs(pts or {}) do if AZ.at(blob, p.X, p.Y, nil, 40) then clean = false end end
check("planner: open field, the path goes round the zone", clean, pts and #pts)

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
