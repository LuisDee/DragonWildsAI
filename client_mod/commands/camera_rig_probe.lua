-- READ-ONLY probe (2026-11-16, issue B16): the local pawn's camera rig. Every SpringArmComponent and CameraComponent on
-- the pawn: where it is, its arm length, offsets, lag and collision settings; the PlayerCameraManager's view. Property
-- reads and pure getters only.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    local s = inst.module.API.module("sense")
    local U = s.U
    local pc, pawn = s.local_pc(), s.local_pawn()
    if not (U.valid(pc) and U.valid(pawn)) then return { ok = false, reason = "no pawn" } end
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x, y, z } end end
    local function r3(q) local ok, p, y, r = pcall(function() return q.Pitch, q.Yaw, q.Roll end); if ok and type(y) == "number" then return { p, y, r } end end
    local out = { ok = true, pawn = v3(U.try(function() return pawn:K2_GetActorLocation() end)), pawn_class = U.short(U.try(function() return pawn:GetClass() end)),
                  control_rot = r3(U.try(function() return pc:GetControlRotation() end)), arms = {}, cameras = {} }
    local function comps(cls)
        local list = {}
        local okc, arr = pcall(function() return pawn:K2_GetComponentsByClass(StaticFindObject(cls)) end)
        if okc and arr then
            local ok = pcall(function() for _, c in ipairs(arr) do if U.valid(c) then list[#list + 1] = c end end end)
            if not ok or #list == 0 then pcall(function() arr:ForEach(function(_, c) local x = c:get(); if U.valid(x) then list[#list + 1] = x end end) end) end
        end
        return list
    end
    local arms = comps("/Script/Engine.SpringArmComponent")
    local boom = U.try(function() return pawn.CameraBoom end)
    if #arms == 0 and U.valid(boom) then arms = { boom } end
    for _, c in ipairs(arms) do
        local row = { name = U.short(c), class = U.short(U.try(function() return c:GetClass() end)),
                      at = v3(U.try(function() return c:K2_GetComponentLocation() end)), rot = r3(U.try(function() return c:K2_GetComponentRotation() end)),
                      rel = v3(U.try(function() return c.RelativeLocation end)),
                      parent = U.short(U.try(function() return c.AttachParent end)), socket = U.str and U.str(U.try(function() return c.AttachSocketName end)) or nil }
        for _, k in ipairs({ "TargetArmLength", "ProbeSize", "CameraLagSpeed", "CameraRotationLagSpeed", "CameraLagMaxDistance", "bUsePawnControlRotation",
                             "bEnableCameraLag", "bEnableCameraRotationLag", "bDoCollisionTest", "bInheritPitch", "bInheritYaw", "bInheritRoll", "bUseCameraLagSubstepping" }) do
            row[k] = U.try(function() return c[k] end)
        end
        row.SocketOffset = v3(U.try(function() return c.SocketOffset end))
        row.TargetOffset = v3(U.try(function() return c.TargetOffset end))
        out.arms[#out.arms + 1] = row
    end
    local cams = comps("/Script/Engine.CameraComponent")
    local fc = U.try(function() return pawn.FollowCamera end)
    if #cams == 0 and U.valid(fc) then cams = { fc } end
    for _, c in ipairs(cams) do
        out.cameras[#out.cameras + 1] = { name = U.short(c), class = U.short(U.try(function() return c:GetClass() end)),
            at = v3(U.try(function() return c:K2_GetComponentLocation() end)), rot = r3(U.try(function() return c:K2_GetComponentRotation() end)),
            parent = U.short(U.try(function() return c.AttachParent end)), fov = U.try(function() return c.FieldOfView end),
            active = U.try(function() return c:IsActive() end), bUsePawnControlRotation = U.try(function() return c.bUsePawnControlRotation end) }
    end
    local pcm = U.try(function() return pc.PlayerCameraManager end)
    if U.valid(pcm) then
        out.pcm = { class = U.short(U.try(function() return pcm:GetClass() end)), at = v3(U.try(function() return pcm:GetCameraLocation() end)),
                    rot = r3(U.try(function() return pcm:GetCameraRotation() end)), fov = U.try(function() return pcm:GetFOVAngle() end),
                    view_target = U.short(U.try(function() return pcm.ViewTarget.Target end)) }
    end
    return out
end
