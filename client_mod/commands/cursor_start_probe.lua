-- READ-ONLY probe (2026-11-16, issue B16): where does the game's build cursor trace start? Hypothesis from
-- aimtrace: at the point of the camera's centre ray nearest the pawn (S = cam + f * dot(pawn - cam, f)), not at the
-- camera. Reports S and what my own line traces meet from the camera, from S, and between the two.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    local s = inst.module.API.module("sense")
    local U = s.U
    local pc, pawn = s.local_pc(), s.local_pawn()
    if not (U.valid(pc) and U.valid(pawn)) then return { ok = false, reason = "no pawn" } end
    local ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary")
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x, y, z } end end
    local cam = v3(U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end))
    local rot = U.try(function() return pc.PlayerCameraManager:GetCameraRotation() end)
    local p = v3(U.try(function() return pawn:K2_GetActorLocation() end))
    local okr, pitch, yaw = pcall(function() return rot.Pitch, rot.Yaw end)
    if not (cam and p and okr) then return { ok = false, reason = "no camera" } end
    local cp, sp, cy, sy = math.cos(math.rad(pitch)), math.sin(math.rad(pitch)), math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local f = { cp * cy, cp * sy, sp }
    local along = (p[1] - cam[1]) * f[1] + (p[2] - cam[2]) * f[2] + (p[3] - cam[3]) * f[3]
    local S = { cam[1] + f[1] * along, cam[2] + f[2] * along, cam[3] + f[3] * along }
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local function tr(a, b, ch)
        local o = {}
        local ok, hit = pcall(function() return ksl:LineTraceSingle(pawn, { X = a[1], Y = a[2], Z = a[3] }, { X = b[1], Y = b[2], Z = b[3] }, ch or 0, false, {}, 0, o, true, C0, C0, 0.0) end)
        if not (ok and hit == true) then return { hit = false } end
        local ha = U.try(function() return o.HitObjectHandle.Actor end)
        local comp = U.try(function() return o.Component:Get() end)
        if not U.valid(comp) then comp = U.try(function() return o.Component end) end
        local ip = v3(o.ImpactPoint)
        return { hit = true, at = ip and { ip[1] / 100, ip[2] / 100, ip[3] / 100 }, dist_m = U.try(function() return o.Distance / 100 end),
                 actor = U.valid(ha) and U.short(ha) or nil, comp = U.valid(comp) and U.short(comp) or nil,
                 owner = U.valid(comp) and U.short(U.try(function() return comp:GetOwner() end)) or nil,
                 full = U.valid(comp) and U.try(function() return comp:GetFullName() end) or nil }
    end
    local function far(a, d) return { a[1] + f[1] * d, a[2] + f[2] * d, a[3] + f[3] * d } end
    local function m(a) return { a[1] / 100, a[2] / 100, a[3] / 100 } end
    local out = { ok = true, cam = m(cam), pawn = m(p), pitch = pitch, yaw = yaw, along_m = along / 100, S = m(S),
                  from_cam = tr(cam, far(cam, 1500)), from_S = tr(S, far(S, 1500)), S_to_cam = tr(S, cam), cam_to_S = tr(cam, S),
                  from_S_cam_ch = tr(S, far(S, 1500), 1) }
    local boom = U.try(function() return pawn.CameraBoom end)
    if U.valid(boom) then
        local at = v3(U.try(function() return boom:K2_GetComponentLocation() end))
        out.boom = at and m(at)
        out.arm = U.try(function() return boom.TargetArmLength end)
    end
    return out
end
