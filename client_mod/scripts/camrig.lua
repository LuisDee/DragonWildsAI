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
