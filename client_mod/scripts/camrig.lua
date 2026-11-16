-- camrig: point the screen centre AT a world point in ONE step (issue B16, 2026-11-16).
--
-- The player camera is an orbit camera on a spring arm (pawn.CameraBoom, a DominionSpringArmComponent, live probe
-- build 26574459: TargetArmLength 700, TargetOffset (0,0,120) world, SocketOffset (0,20,0) camera frame,
-- bUsePawnControlRotation, no rotation lag, collision test on). The camera sits at
--     cam = pivot + k * (-L * f + R * socket)        pivot = boom location + TargetOffset, f = the view direction,
--                                                    k = 1, or less when the arm is pushed in by a wall
-- so a new control rotation MOVES the camera round the pivot. Everything the game aims with the screen centre (the
-- build cursor, the interaction ray, a spell's ground target) follows the ray cam + s * f. An aim worked out from
-- where the camera IS misses by construction and has to be corrected again and again (live trace, 871 frames: steps
-- of 4.5, 3.1, 1.4, 1.2, 1.0, 0.6 ... m, 5-8 s a wall). The ray passes through a target T exactly when
--     f  is parallel to  T - pivot - k * (socket.y * right(f) + socket.z * up(f))
-- which depends on the pivot only: three fixed-point rounds on the 0.2 m side offset and it is exact. The game's
-- cursor then answers within 2 frames (same trace) and stands still.
--
-- C.solve is pure (tested offline); C.rig / C.aim read the boom and set the control rotation.
local C = {}

C.cfg = {
    rounds = 4,
    -- the boom's values when it can't be read (m)
    arm_m = 7.0, target_offset = { 0, 0, 1.2 }, socket = { 0, 0.2, 0 },
    pitch_min = -89, pitch_max = 89,
    probe_m = 0.12, -- the boom's collision probe (ProbeSize 12): the camera stops this far before what is behind me
}

local function norm(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l < 1e-9 then return nil end
    return { v[1] / l, v[2] / l, v[3] / l }, l
end

-- Unreal's axes for a rotator (pitch, yaw, roll 0), degrees: forward, right, up.
function C.axes(pitch, yaw)
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp, sp, cy, sy = math.cos(p), math.sin(p), math.cos(y), math.sin(y)
    return { cp * cy, cp * sy, sp }, { -sy, cy, 0 }, { -sp * cy, -sp * sy, cp }
end

function C.rot(f)
    return math.deg(math.atan(f[3], math.sqrt(f[1] * f[1] + f[2] * f[2]))), math.deg(math.atan(f[2], f[1]))
end

-- Where the camera stands for a control rotation. rig = {pivot, arm_m, socket, k}.
function C.camera(rig, pitch, yaw)
    local f, r, u = C.axes(pitch, yaw)
    local s, k, L = rig.socket or C.cfg.socket, rig.k or 1, rig.arm_m or C.cfg.arm_m
    local out = {}
    for i = 1, 3 do out[i] = rig.pivot[i] + k * (-L * f[i] + s[1] * f[i] + s[2] * r[i] + s[3] * u[i]) end
    return out
end

-- The control rotation whose centre ray passes through target (metres). -> pitch, yaw (degrees), distance camera ->
-- target (m); nil when the target is on the pivot.
function C.solve(rig, target)
    local s, k = rig.socket or C.cfg.socket, rig.k or 1
    local d = { target[1] - rig.pivot[1], target[2] - rig.pivot[2], target[3] - rig.pivot[3] }
    local f = norm(d)
    if not f then return nil end
    local pitch, yaw = C.rot(f)
    for _ = 1, C.cfg.rounds do
        local _, r, u = C.axes(pitch, yaw)
        local g = norm({ d[1] - k * (s[2] * r[1] + s[3] * u[1]), d[2] - k * (s[2] * r[2] + s[3] * u[2]), d[3] - k * (s[2] * r[3] + s[3] * u[3]) })
        if not g then break end
        pitch, yaw = C.rot(g)
    end
    pitch = math.max(C.cfg.pitch_min, math.min(C.cfg.pitch_max, pitch))
    local cam = C.camera(rig, pitch, yaw)
    return pitch, yaw, math.sqrt((target[1] - cam[1]) ^ 2 + (target[2] - cam[2]) ^ 2 + (target[3] - cam[3]) ^ 2)
end

-- How far the centre ray of (pitch, yaw) passes from a point (m): the check after an aim, and the offline test.
function C.miss(rig, pitch, yaw, target)
    local cam, f = C.camera(rig, pitch, yaw), (C.axes(pitch, yaw))
    local d = { target[1] - cam[1], target[2] - cam[2], target[3] - cam[3] }
    local along = d[1] * f[1] + d[2] * f[2] + d[3] * f[3]
    return math.sqrt(math.max(0, d[1] * d[1] + d[2] * d[2] + d[3] * d[3] - along * along)), along
end

-- What the screen centre would land on if I aimed at target from where I stand, BEFORE turning the camera (the
-- engine's own trace as the judge, as Baritone checks a rotation before it acts). trace(a_m, b_m) -> hit, point_m.
-- -> { pitch, yaw, cam (where the camera would stand), k (the arm, pushed in by what is behind me), sees (the first
--      thing on the centre ray, or the target), off_m (how far that is from the target), clear = off_m <= tol_m }
function C.look(rig, target, trace, tol_m)
    local s, L = rig.socket or C.cfg.socket, rig.arm_m or C.cfg.arm_m
    local r = { pivot = rig.pivot, arm_m = L, socket = s, k = 1 }
    local pitch, yaw = C.solve(r, target)
    if not pitch then return nil end
    local cam = C.camera(r, pitch, yaw)
    -- the boom: what stands between the pivot and the camera pushes the camera in to just before it
    local hit, p = trace(r.pivot, cam)
    if hit and p then
        local full = math.sqrt((cam[1] - r.pivot[1]) ^ 2 + (cam[2] - r.pivot[2]) ^ 2 + (cam[3] - r.pivot[3]) ^ 2)
        local d = math.sqrt((p[1] - r.pivot[1]) ^ 2 + (p[2] - r.pivot[2]) ^ 2 + (p[3] - r.pivot[3]) ^ 2)
        r.k = math.max(0.05, math.min(1, (d - C.cfg.probe_m) / full))
        pitch, yaw = C.solve(r, target)
        cam = C.camera(r, pitch, yaw)
    end
    local out = { pitch = pitch, yaw = yaw, cam = cam, k = r.k, sees = target, off_m = 0 }
    local hit2, p2 = trace(cam, target)
    if hit2 and p2 then
        out.sees = p2
        out.off_m = math.sqrt((p2[1] - target[1]) ^ 2 + (p2[2] - target[2]) ^ 2 + (p2[3] - target[3]) ^ 2)
    end
    out.clear = out.off_m <= (tol_m or 0.3)
    return out
end

-- Where to stand to put the screen centre on target: spots on rings round it, each judged by the predicted view
-- from there (C.look), the shortest walk first. The pattern: list the candidates, keep the feasible, take the
-- cheapest, act once. feet = my pawn's location (m). opts = { radii, steps, tol_m | tol_for(pos), up_m (how far
-- above or below my own level a spot may lie), ok(pos) (e.g. not where the piece goes), max (direct spots wanted) }
-- -> { { pos (the pawn's location there), walk_m, direct (a clear straight walk from here), look }, ... }
function C.stands(rig, feet, target, trace, opts)
    opts = opts or {}
    local off = { rig.pivot[1] - feet[1], rig.pivot[2] - feet[2], rig.pivot[3] - feet[3] }
    local half, up = opts.half_m or 0.88, opts.up_m or 1.2
    local cands = {}
    for _, r in ipairs(opts.radii or { 2.5, 4.0, 5.5 }) do
        local n = opts.steps or 12
        for i = 0, n - 1 do
            local a = 2 * math.pi * i / n
            local x, y = target[1] + r * math.cos(a), target[2] + r * math.sin(a)
            cands[#cands + 1] = { x, y, math.sqrt((x - feet[1]) ^ 2 + (y - feet[2]) ^ 2) }
        end
    end
    table.sort(cands, function(a, b) return a[3] < b[3] end)
    local out, direct = {}, 0
    for _, c in ipairs(cands) do
        -- the ground there, near my own level (a roof or the foot of a bank is no place to stand)
        local top = { c[1], c[2], feet[3] - half + up }
        local hit, g = trace(top, { c[1], c[2], feet[3] - half - up })
        if hit and g and top[3] - g[3] > 0.05 then
            local pos = { c[1], c[2], g[3] + half }
            if not opts.ok or opts.ok(pos) then
                local tol = opts.tol_for and opts.tol_for(pos) or opts.tol_m
                local look = C.look({ pivot = { pos[1] + off[1], pos[2] + off[2], pos[3] + off[3] }, arm_m = rig.arm_m, socket = rig.socket },
                    target, trace, tol)
                if look and look.clear then
                    local blocked = trace({ feet[1], feet[2], feet[3] }, pos)
                    out[#out + 1] = { pos = pos, walk_m = c[3] + (blocked and (opts.round_m or 8) or 0), direct = not blocked, look = look }
                    if not blocked then direct = direct + 1 end
                    if direct >= (opts.max or 3) then break end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.walk_m < b.walk_m end)
    return out
end

-- The live rig: U = sense.U, pc, pawn. Reads only. k: how far the arm is pushed in right now, from where the camera
-- is (1 = free). -> {pivot, arm_m, socket, k} in metres, or nil (no boom: the caller falls back to its old aim).
function C.rig(U, pc, pawn)
    local boom = U.try(function() return pawn.CameraBoom end)
    if not U.valid(boom) then return nil end
    local function v3(get)
        local v = U.try(get)
        local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x / 100, y / 100, z / 100 } end
    end
    local at = v3(function() return boom:K2_GetComponentLocation() end)
    if not at then return nil end
    local to = v3(function() return boom.TargetOffset end) or C.cfg.target_offset
    local arm = tonumber((U.try(function() return boom.TargetArmLength end)))
    local rig = { pivot = { at[1] + to[1], at[2] + to[2], at[3] + to[3] }, arm_m = arm and arm / 100 or C.cfg.arm_m,
                  socket = v3(function() return boom.SocketOffset end) or C.cfg.socket, k = 1 }
    local cam = v3(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local s = rig.socket
    local full = math.sqrt((rig.arm_m - s[1]) ^ 2 + s[2] ^ 2 + s[3] ^ 2)
    if cam and full > 0.01 then
        local d = math.sqrt((cam[1] - rig.pivot[1]) ^ 2 + (cam[2] - rig.pivot[2]) ^ 2 + (cam[3] - rig.pivot[3]) ^ 2)
        rig.k = math.max(0.05, math.min(1, d / full))
        rig.cam = cam
    end
    return rig
end

-- Aim the screen centre at pos (metres). -> distance camera -> pos (m), rig; nil when the boom is unreadable.
function C.aim(U, pc, pawn, pos)
    if not (U.valid(pc) and U.valid(pawn) and pos) then return nil end
    local rig = C.rig(U, pc, pawn)
    if not rig then return nil end
    local pitch, yaw, dist = C.solve(rig, { pos[1], pos[2], pos[3] or rig.pivot[3] })
    if not pitch then return nil end
    local ok = pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
    if not ok then return nil end
    rig.pitch, rig.yaw = pitch, yaw
    return dist, rig
end

return C
