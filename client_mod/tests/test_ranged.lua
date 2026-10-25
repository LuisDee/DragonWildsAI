-- Offline tests for client_mod/scripts/ranged.lua: the ballistic solver with lead, the camera-ray aim,
-- fitting a projectile's real parameters from sampled positions, learning, and hit-rate metrics,
-- against a fake projectile model that behaves like the game (launch from the muzzle toward the point
-- under the crosshair, straight for t0, then gravity). Run: lua client_mod/tests/test_ranged.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local R = assert(loadfile(root .. "/client_mod/scripts/ranged.lua"))()
local V = R.vec
local v, add, sub, mul, len, norm = V.v, V.add, V.sub, V.mul, V.len, V.norm

-- ---------------------------------------------------------------- 1. solver
do
    local m = v(0, 0, 150)
    local p = { speed = 5000, gz = -980, t0 = 0 }
    local tgt = v(2500, 0, 100)
    local sol = R.solve(m, tgt, nil, p)
    check("static: solution", sol ~= nil)
    local at = R.position(m, sol.dir, p, sol.tau)
    check("static: lands on target", len(sub(at, tgt)) < 2, len(sub(at, tgt)))
    check("static: aims above the line to compensate drop", sol.pitch > math.deg(math.atan(-50, 2500)))
    local hi = R.solve(m, tgt, nil, p, { arc = "high", max_time = 12 })
    check("high arc exists and is higher", hi and hi.pitch > sol.pitch + 20, hi and hi.pitch)
    local vel = v(0, 300, 0) -- 3 m/s sideways (UE +Y = right)
    local lead = R.solve(m, tgt, vel, p)
    local at2 = R.position(m, lead.dir, p, lead.tau)
    local fut = add(tgt, mul(vel, lead.tau))
    check("moving: meets the target's future position", len(sub(at2, fut)) < 2, len(sub(at2, fut)))
    check("moving: leads to the right", lead.yaw > 0.5, lead.yaw)
    local p0 = { speed = 5000, gz = -1500, t0 = 0.2 }
    local s0 = R.solve(m, v(4000, 0, 100), nil, p0)
    check("straight segment: lands on target", len(sub(R.position(m, s0.dir, p0, s0.tau), v(4000, 0, 100))) < 2)
    local none, why, info = R.solve(m, v(60000, 0, 0), nil, { speed = 3000, gz = -980, t0 = 0 })
    check("out of range: no solution + max range", none == nil and why == "out_of_range" and info.max_range_cm < 60000, info and info.max_range_cm)
    local rot, aimp = R.camera_rotation(v(-300, 0, 200), m, sol.dir, 5000)
    local fwd = v(math.cos(math.rad(rot.Pitch)) * math.cos(math.rad(rot.Yaw)), math.cos(math.rad(rot.Pitch)) * math.sin(math.rad(rot.Yaw)), math.sin(math.rad(rot.Pitch)))
    local onray = add(v(-300, 0, 200), mul(fwd, len(sub(aimp, v(-300, 0, 200)))))
    check("camera ray passes through the muzzle aim point", len(sub(onray, aimp)) < 1)
end

-- ---------------------------------------------------------------- 2. fitting the real projectile
local function fly(m, dir, p, dt, tmax)
    local out = {}
    local t = 0
    while t <= tmax do out[#out + 1] = { t = t, pos = R.position(m, dir, p, t) }; t = t + dt end
    return out
end
do
    local truth = { speed = 5200, gz = -1500, t0 = 0.12 }
    local s = fly(v(0, 0, 150), norm(v(1, 0, 0.05)), truth, 1 / 30, 1.2)
    local f = R.fit(s)
    check("fit: speed", math.abs(f.speed - 5200) / 5200 < 0.03, f.speed)
    check("fit: gravity", math.abs(f.gz - (-1500)) / 1500 < 0.05, f.gz)
    check("fit: straight time", math.abs(f.t0 - 0.12) < 0.07, f.t0)
end

-- ---------------------------------------------------------------- 3. learning loop vs a fake game
-- The game: launch from the muzzle toward the point the CAMERA ray reaches at its trace distance
-- (not our aim distance: parallax), true params unknown to Claude. Target walks sideways at 3 m/s.
local function game_launch_dir(cam, rot, muzzle, trace)
    local fwd = v(math.cos(math.rad(rot.Pitch)) * math.cos(math.rad(rot.Yaw)), math.cos(math.rad(rot.Pitch)) * math.sin(math.rad(rot.Yaw)), math.sin(math.rad(rot.Pitch)))
    return norm(sub(add(cam, mul(fwd, trace)), muzzle))
end
do
    _G.DWRanged = nil
    local truth = { speed = 5600, gz = -1700, t0 = 0.1 }
    local key = "ITEM_Crossbow_Test|ITEM_Ammo_Bolts_Bone"
    local aimer = R.new_aimer(key, { speed = 4000, gz = -980, t0 = 0, source = "default" })
    local muzzle = v(0, 0, 150)
    local cam = v(-280, 40, 210)
    local hits, first_miss, last3 = 0, nil, 0
    for shot = 1, 10 do
        local t = 0
        local tpos = v(2600, -300, 100)
        local vel = v(0, 300, 0)
        for k = 0, 10 do aimer:observe(k * 0.1, add(tpos, mul(vel, k * 0.1))) end
        t = 1.0
        local now_pos = add(tpos, mul(vel, t))
        local rot, sol = aimer:solve(muzzle, cam, { aim_distance = 5000 })
        check("loop: solution " .. shot, rot ~= nil)
        aimer:fired(t, sol, {}, muzzle)
        local dir = game_launch_dir(cam, rot, muzzle, 6000)
        local hit = false
        for f = 0, 60 do
            local ft = f / 30
            local pp = R.position(muzzle, dir, truth, ft)
            local tp = add(now_pos, mul(vel, ft))
            if len(sub(pp, tp)) < 45 then hit = true end
            aimer:sample(t + ft, pp, tp)
        end
        aimer:sample(t + 2.1, nil, add(now_pos, mul(vel, 2.1)))
        local res = aimer:finish(hit)
        if hit then hits = hits + 1 end
        if shot == 1 then first_miss = not hit end
        if shot >= 8 and hit then last3 = last3 + 1 end
    end
    check("learning: the first shot (wrong data) misses", first_miss)
    check("learning: the last 3 shots hit", last3 == 3, last3)
    local p = R.profile(key)
    check("learning: speed converges", math.abs(p.speed - truth.speed) / truth.speed < 0.08, p.speed)
    check("learning: gravity converges", math.abs(p.gz - truth.gz) / math.abs(truth.gz) < 0.12, p.gz)
    local m = R.metrics()[key]
    check("metrics: shots and hits recorded", m.shots == 10 and m.hits == hits)
    check("metrics: by distance bucket", m.by_dist["20-35m"] and m.by_dist["20-35m"].shots == 10, next(m.by_dist))
    check("metrics: by target speed bucket", m.by_speed["0.5-3m/s"] or m.by_speed["3-7m/s"])
end

print(string.format("ranged tests: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
