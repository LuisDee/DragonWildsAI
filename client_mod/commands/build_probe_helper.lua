-- READ-ONLY build probe (2026-11-01, roofs): while a build job is placing an instance-only piece (no preview actor),
-- is the snapped ghost anywhere readable? Lists the BuildingHelper actor and the placement component's
-- PlugVisualizationHost: their location/rotation and every component (class, world location, rotation), and for
-- instanced-mesh components the instance count and instance 0's world transform (GetInstanceTransform, a reflected
-- UFunction). The MPC cursor too. Property reads and pure getters only.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s.U
    local pc = s.local_pc()
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end end
    local function r3(r) local ok, p, y, ro = pcall(function() return r.Pitch, r.Yaw, r.Roll end); if ok and type(y) == "number" then return { p, y, ro } end end
    local function comps(a)
        local out = {}
        local list = U.try(function() return a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent")) end)
        if type(list) ~= "table" then
            local ok, arr = pcall(function() return a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent")) end)
            list = ok and arr or nil
        end
        local n = 0
        local function each(c)
            n = n + 1
            if n > 30 then return end
            local row = { class = U.short(U.try(function() return c:GetClass() end)), name = U.short(c),
                          at = v3(U.try(function() return c:K2_GetComponentLocation() end)),
                          rot = r3(U.try(function() return c:K2_GetComponentRotation() end)),
                          visible = U.try(function() return c:IsVisible() end) }
            local cnt = U.try(function() return c:GetInstanceCount() end)
            if type(cnt) == "number" then
                row.instances = cnt
                if cnt > 0 then
                    local t = {}
                    local ok = pcall(function() return c:GetInstanceTransform(0, t, true) end)
                    local tr = ok and t and (t.OutInstanceTransform or t[1] or t)
                    row.inst0 = { ok = ok, at = tr and v3(U.try(function() return tr.Translation end)) }
                end
            end
            local sm = U.try(function() return c.StaticMesh end)
            if sm then row.mesh = U.short(sm) end
            out[#out + 1] = row
        end
        if list then
            local ok = pcall(function() for _, c in ipairs(list) do if U.valid(c) then each(c) end end end)
            if not ok then pcall(function() list:ForEach(function(_, c) local x = c:get(); if U.valid(x) then each(x) end end) end) end
        end
        return out
    end
    local function actor(a)
        if not U.valid(a) then return nil end
        return { class = U.short(U.try(function() return a:GetClass() end)), name = U.short(a),
                 at = v3(U.try(function() return a:K2_GetActorLocation() end)),
                 rot = r3(U.try(function() return a:K2_GetActorRotation() end)), components = comps(a) }
    end
    local out = { ok = true }
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    if not U.valid(bm) then return { ok = false, reason = "no BuildModeComponent" } end
    out.mode = U.try(function() return bm.CurrentBuildMode end)
    local h = U.try(function() return bm.BuildingHelperActor end)
    out.helper = actor(h and U.try(function() return h:Get() end))
    local bp = U.try(function() return bm.BuildPlacementComponent end)
    out.plug_host = U.valid(bp) and actor(U.try(function() return bp.PlugVisualizationHost end)) or nil
    -- the camera's real place and facing, the control rotation, and what the camera's forward ray hits (10 m): is the
    -- cursor the ray's hit, or a snapped piece's spot?
    local pcm = pc and U.try(function() return pc.PlayerCameraManager end)
    out.camera = U.valid(pcm) and v3(U.try(function() return pcm:GetCameraLocation() end)) or nil
    out.camera_rot = U.valid(pcm) and r3(U.try(function() return pcm:GetCameraRotation() end)) or nil
    out.control_rot = r3(U.try(function() return pc:GetControlRotation() end))
    local pawn0 = s.local_pawn()
    out.pawn = U.valid(pawn0) and v3(U.try(function() return pawn0:K2_GetActorLocation() end)) or nil
    if out.camera and out.camera_rot then
        local p, y = math.rad(out.camera_rot[1]), math.rad(out.camera_rot[2])
        local c = out.camera
        local f = { math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p) }
        local ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary")
        local C0 = { R = 0, G = 0, B = 0, A = 0 }
        local o = {}
        local ok, hit = pcall(function()
            return ksl:LineTraceSingle(pawn0, { X = c[1] * 100, Y = c[2] * 100, Z = c[3] * 100 },
                { X = (c[1] + f[1] * 10) * 100, Y = (c[2] + f[2] * 10) * 100, Z = (c[3] + f[3] * 10) * 100 }, 0, false, {}, 0, o, true, C0, C0, 0.0)
        end)
        local ip = ok and hit == true and o.ImpactPoint
        out.ray_hit = ip and v3(ip) or (ok and "none" or "trace_failed")
        local ha = ok and hit == true and U.try(function() return o.HitObjectHandle.Actor end)
        out.ray_hit_actor = ha and U.short(ha) or nil
    end
    local kml = U.find_object("/Script/Engine.Default__KismetMaterialLibrary")
    local mpc = U.try(function() return bm.MaterialParameterCollection end)
    local pawn = s.local_pawn()
    if kml and U.valid(mpc) then
        local pos = U.try(function() return kml:GetVectorParameterValue(pawn, mpc, bm.CursorWorldPositionMPN) end)
        local okp, x, y, z = pcall(function() return pos.R, pos.G, pos.B end)
        out.cursor = okp and type(x) == "number" and { x / 100, y / 100, z / 100 } or nil
        out.colour = U.try(function() return kml:GetScalarParameterValue(pawn, mpc, bm.PlacingValidityStateIndexMPN) end)
    end
    return out
end
