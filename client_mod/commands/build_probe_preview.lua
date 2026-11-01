-- READ-ONLY build probe (2026-11-01 step 3): while a build job is in its check phase, where is the GHOST really?
-- Live: for the Square Foundation W.preview_actor found nothing (no ghost yaw, the "ghost" read = the MPC cursor),
-- so the snap signal may have been reading the cursor. Lists every BaseBuildingActor with bIsPreview (class, its
-- PlayerControllerManagingPlacement, location, yaw), the MPC cursor, BuildModeComponent.SnappingMode
-- (Basic 0 / Advanced 1 / Free 2), the BuildPlacementComponent's magnet numbers, BuildingHelperActor and
-- PlugVisualizationHost locations. Property reads only.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s.U
    local pc = s.local_pc()
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end end
    local function loc(a) local l = U.loc(a); return l and { l.X / 100, l.Y / 100, l.Z / 100 } end
    local function yaw(a) return tonumber((U.try(function() return a:K2_GetActorRotation().Yaw end))) end
    local out = { ok = true, pc = U.short(pc) }
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    if U.valid(bm) then
        out.mode = U.try(function() return bm.CurrentBuildMode end)
        out.snapping_mode = U.try(function() return bm.SnappingMode end)
        local h = U.try(function() return bm.BuildingHelperActor end)
        local ha = h and U.try(function() return h:Get() end)
        out.helper = U.valid(ha) and { class = U.short(U.try(function() return ha:GetClass() end)), at = loc(ha), yaw = yaw(ha) } or nil
        local bp = U.try(function() return bm.BuildPlacementComponent end)
        if U.valid(bp) then
            out.placement = { magnet_mult = U.try(function() return bp.MagnetizeExtentsMultiplier end),
                              max_dist = U.try(function() return bp.MaxPlacementDistance end) }
            local host = U.try(function() return bp.PlugVisualizationHost end)
            if U.valid(host) then out.placement.plug_host = { class = U.short(U.try(function() return host:GetClass() end)), at = loc(host) } end
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
    end
    local previews = {}
    for _, a in ipairs(FindAllOf("BaseBuildingActor") or {}) do
        if U.valid(a) and U.try(function() return a.bIsPreview end) == true then
            local m = U.try(function() return a.PlayerControllerManagingPlacement end)
            previews[#previews + 1] = { name = U.short(a), class = U.short(U.try(function() return a:GetClass() end)), at = loc(a), yaw = yaw(a),
                                        managed_by = U.valid(m) and U.short(m) or tostring(m), ghosted = U.try(function() return a.bIsGhosted end),
                                        piece_id = U.try(function() return a.BuildingPieceID end) }
        end
    end
    out.previews = previews
    if #previews == 0 and out.cursor then -- what IS at the cursor then (one FindAllOf("Actor"), ~0.4 s live)
        local c, near = out.cursor, {}
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            local l = loc(a)
            if l and math.sqrt((l[1] - c[1]) ^ 2 + (l[2] - c[2]) ^ 2 + (l[3] - c[3]) ^ 2) <= 4 and #near < 25 then
                near[#near + 1] = { class = U.short(U.try(function() return a:GetClass() end)), name = U.short(a), at = l, yaw = yaw(a),
                                    preview = U.try(function() return a.bIsPreview end) }
            end
        end
        out.near_cursor = near
    end
    return out
end
