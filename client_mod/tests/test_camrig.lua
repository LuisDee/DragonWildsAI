-- Offline tests for client_mod/scripts/camrig.lua (the one-step aim for the orbit camera, issue B16).
-- Run: lua client_mod/tests/test_camrig.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
local C = assert(loadfile(root .. "/client_mod/scripts/camrig.lua"))()
local function d3(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end

-- 1. the model against the live trace (logs/client/aimtrace.jsonl, build 26574459; 871 rows, median error 0.7 mm):
-- control rotation + pawn -> where the camera stood
local live = {
    { ctl = { 0.0, -129.33 }, cam = { 110.206, 1904.891, -28.988 }, pawn = { 105.615, 1899.603, -30.188 } },
    { ctl = { -16.43, 15.617 }, cam = { 101.373, 1897.986, -27.019 }, pawn = { 107.893, 1899.601, -30.199 } },
    { ctl = { -42.41, 61.127 }, cam = { 105.222, 1895.171, -24.278 }, pawn = { 107.893, 1899.601, -30.199 } },
    { ctl = { -30.026, -13.745 }, cam = { 105.163, 1897.519, -25.616 }, pawn = { 111.002, 1895.885, -30.319 } },
    { ctl = { -17.151, 111.989 }, cam = { 113.321, 1889.608, -27.055 }, pawn = { 111.002, 1895.885, -30.319 } },
}
for i, r in ipairs(live) do
    local rig = { pivot = { r.pawn[1], r.pawn[2], r.pawn[3] + 1.2 }, arm_m = 7.0, socket = { 0, 0.2, 0 }, k = 1 }
    local e = d3(C.camera(rig, r.ctl[1], r.ctl[2]), r.cam)
    check("live camera " .. i, e < 0.01, e)
end

-- 2. solve: the centre ray passes through the target, for targets all round, near and far, above and below, and
-- with the arm pushed in
local rig = { pivot = { 100, 2000, -29 }, arm_m = 7.0, socket = { 0, 0.2, 0 }, k = 1 }
local worst, n = 0, 0
for _, k in ipairs({ 1, 0.7, 0.3 }) do
    rig.k = k
    for a = 0, 345, 15 do
        for _, dist in ipairs({ 0.8, 2, 4, 7 }) do
            for _, dz in ipairs({ -2.2, -1.2, 0, 1.5, 3 }) do
                local t = { rig.pivot[1] + dist * math.cos(math.rad(a)), rig.pivot[2] + dist * math.sin(math.rad(a)), rig.pivot[3] + dz }
                local pitch, yaw, far = C.solve(rig, t)
                local miss, along = C.miss(rig, pitch, yaw, t)
                worst, n = math.max(worst, miss), n + 1
                if along <= 0 or math.abs(along - far) > 1e-6 then check("target ahead of the camera", false, a .. " " .. dist .. " " .. dz) end
            end
        end
    end
end
check("solve passes through the target (" .. n .. " cases)", worst < 0.002, worst)

-- 3. the old aim (direction from where the camera stands) misses by metres; the new one doesn't
rig.k = 1
local cam0 = C.camera(rig, 0, 0)
local t = { 103, 2003, -30.2 }
local dx, dy, dz = t[1] - cam0[1], t[2] - cam0[2], t[3] - cam0[3]
local old_miss = C.miss(rig, math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), math.deg(math.atan(dy, dx)), t)
local p, y = C.solve(rig, t)
check("old aim misses", old_miss > 1.0, old_miss)
check("new aim hits", C.miss(rig, p, y, t) < 0.002)

-- 4. edge cases: the target on the pivot -> nil; straight below -> a clamped pitch, no NaN
check("target on the pivot", C.solve(rig, { 100, 2000, -29 }) == nil)
local pb, yb = C.solve(rig, { 100, 2000, -31 })
check("straight below", pb == pb and yb == yb and pb >= -89 and pb <= -80, tostring(pb))

-- 5. rig / aim with a fake boom
local U = { try = function(f) local ok, v = pcall(f); if ok then return v end end, valid = function(o) return o ~= nil end }
local set
local boom = { TargetOffset = { X = 0, Y = 0, Z = 120 }, SocketOffset = { X = 0, Y = 20, Z = 0 }, TargetArmLength = 700,
               K2_GetComponentLocation = function() return { X = 10000, Y = 200000, Z = -3020 } end }
local pc = { PlayerCameraManager = { GetCameraLocation = function() return { X = 9300, Y = 200020, Z = -2900 } end },
             SetControlRotation = function(_, r) set = r end }
local dist, got = C.aim(U, pc, { CameraBoom = boom }, { 103, 2003, -30.2 })
check("aim sets a rotation", set and set.Roll == 0 and math.abs(set.Pitch - p) < 1e-6 and math.abs(set.Yaw - y) < 1e-6, set and set.Pitch)
check("aim returns the distance and the rig", dist and dist > 7 and got.k == 1 and math.abs(got.pivot[3] + 29) < 1e-9, dist)
check("no boom -> nil", C.aim(U, pc, {}, { 1, 2, 3 }) == nil)
pc.PlayerCameraManager.GetCameraLocation = function() return { X = 9650, Y = 200010, Z = -2900 } end -- pushed in to half
local _, half = C.aim(U, pc, { CameraBoom = boom }, { 103, 2003, -30.2 })
check("arm pushed in: k from the camera", math.abs(half.k - 0.5) < 0.01, half.k)

-- 6. look / stands against a toy world: flat ground at z = -31 and a wall (the plane x = 105, 4 m wide, 3 m tall)
local function world(a, b)
    local best
    local function try(tt, p) if tt > 1e-9 and tt < 1 and (not best or tt < best[1]) then best = { tt, p } end end
    local d = { b[1] - a[1], b[2] - a[2], b[3] - a[3] }
    if d[3] ~= 0 then
        local tt = (-31 - a[3]) / d[3]
        try(tt, { a[1] + d[1] * tt, a[2] + d[2] * tt, -31 })
    end
    if d[1] ~= 0 then
        local tt = (105 - a[1]) / d[1]
        local p = { 105, a[2] + d[2] * tt, a[3] + d[3] * tt }
        if math.abs(p[2] - 2000) <= 2 and p[3] >= -31 and p[3] <= -28 then try(tt, p) end
    end
    if best then return true, best[2] end
    return false
end
local feet = { 100, 2000, -30.12 }
local r6 = { pivot = { 100, 2000, -28.92 }, arm_m = 7.0, socket = { 0, 0.2, 0 } }
local near_face = { 104.99, 2000, -29.5 } -- on my side of the wall
local far_ground = { 108, 2000, -31 }     -- behind it
local l1 = C.look(r6, near_face, world)
check("look: a point on my side of the wall is clear", l1 and l1.clear and l1.off_m < 0.05, l1 and l1.off_m)
local l2 = C.look(r6, far_ground, world)
check("look: a point behind the wall is not (the view stops on the wall)", l2 and not l2.clear and math.abs(l2.sees[1] - 105) < 1e-6, l2 and l2.off_m)
check("look: the camera stays above the ground", l1.cam[3] > -31 and l2.cam[3] > -31, l1.cam[3])
local spots = C.stands(r6, feet, far_ground, world, { max = 3 })
check("stands: spots with a clear view of the point behind the wall", #spots >= 1, #spots)
local all_ok = true
for i, sp in ipairs(spots) do
    if not (sp.look.clear and math.abs(sp.pos[3] - (-31 + 0.88)) < 1e-6) then all_ok = false end
    if i > 1 and spots[i - 1].walk_m > sp.walk_m then all_ok = false end
end
check("stands: each on the ground, clear, the shortest walk first", all_ok)
check("stands: a straight walk through the wall counts as round something", spots[1] and (spots[1].direct or spots[1].walk_m > 8), spots[1] and spots[1].walk_m)
local none = C.stands(r6, feet, far_ground, world, { ok = function() return false end })
check("stands: every spot refused -> none", #none == 0)

-- 7. the cursor's ray starts at the point of the centre ray nearest the pawn: with a wall close behind me the boom
-- is pushed in, that point lies behind the camera and behind the wall, and the cursor lands on the wall
local function back_wall(a, b)
    if (a[1] - 99.5) * (b[1] - 99.5) < 0 then
        local tt = (99.5 - a[1]) / (b[1] - a[1])
        return true, { 99.5, a[2] + (b[2] - a[2]) * tt, a[3] + (b[3] - a[3]) * tt }
    end
    return false
end
local up_ahead = { 102, 2000, -27.5 }
local r7 = { pivot = { 100, 2000, -28.8 }, arm_m = 7.0, socket = { 0, 0.2, 0 } }
local l3 = C.look(r7, up_ahead, back_wall)
check("look: without the pawn's place the ray starts at the camera (clear past a wall behind me)", l3 and l3.clear and l3.k < 0.2 and l3.cam[1] > 99.5, l3 and l3.off_m)
r7.pawn = { 100, 2000, -30 }
local l4 = C.look(r7, up_ahead, back_wall)
check("look: the cursor's ray starts behind the pushed-in camera", l4 and l4.from_m < 0 and l4.from[1] < 99.5, l4 and l4.from_m)
check("look: and lands on the wall behind me, not on the target", l4 and not l4.clear and math.abs(l4.sees[1] - 99.5) < 1e-6, l4 and l4.off_m)
local l5 = C.look({ pivot = { 100, 2000, -28.8 }, arm_m = 7.0, socket = { 0, 0.2, 0 }, pawn = { 100, 2000, -30 } }, up_ahead, function() return false end)
check("look: in the open the ray starts near me, ahead of the camera, and is clear", l5 and l5.clear and l5.from_m > 5, l5 and l5.from_m)

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
