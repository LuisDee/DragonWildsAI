-- Build probes P3 / P4a (design §7, review finding 12): ONE step per call, chosen by `local STEP = "..."`:
--   read     read-only: build mode, placing piece, input mode, the MPC colour index + cursor position
--   menu     P3: press B once (IA_BuildMenu, one frame), nothing else
--   cancel   P3: press Cancel once (BuildModeComponent.CancelAction, one frame)
--   select   P4a: CallOnBuildingItemSelected(<PIECE or Campfire>) on the build menu's API, ONLY when the mode
--            reads Selection (the menu is open, as a player's click)
--   aim      P4a: look at a point AIM_M metres ahead of the pawn, on the ground (SetControlRotation)
--   preview  P4a read-only: find the preview (BaseBuildingActor with bIsPreview, once) and read it
-- Nothing places anything. Never under DW_PAUSE.
return function(log)
    local step = STEP or "read"
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local bm = U.try(function() return pc.BuildModeComponent end)
    local out = { ok = true, step = step }
    local function state()
        out.mode = U.try(function() return bm.CurrentBuildMode end)
        out.placing = nm(U.try(function() return bm.CurrentlyPlacingPieceData end))
        out.input_mode = nm(U.try(function() return pc.CurrentInputMode end))
        local kml = U.find_object("/Script/Engine.Default__KismetMaterialLibrary")
        local mpc = U.try(function() return bm.MaterialParameterCollection end)
        if kml and U.valid(mpc) then
            out.mpc_index = U.try(function() return kml:GetScalarParameterValue(pawn, mpc, bm.PlacingValidityStateIndexMPN) end)
            local v = U.try(function() return kml:GetVectorParameterValue(pawn, mpc, bm.CursorWorldPositionMPN) end)
            local ok, r, g, b = pcall(function() return v.R, v.G, v.B end)
            if ok then out.mpc_cursor = { r, g, b } end
        end
        local l = U.loc(pawn)
        out.me = l and { l.X, l.Y, l.Z }
    end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local function press(a)
        if not (eis and U.valid(a)) then return false end
        return pcall(function() eis:InjectInputVectorForAction(a, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    end
    if step == "menu" then
        out.pressed = press(U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_BuildMenu.IA_BuildMenu"))
    elseif step == "cancel" then
        out.pressed = press(U.try(function() return bm.CancelAction end))
    elseif step == "select" then
        if U.try(function() return bm.CurrentBuildMode end) ~= 1 then return { ok = false, reason = "not in Selection" } end
        local want = PIECE or "BUILDPIECE_Campfire"
        local prog = U.try(function() return pc.ProgressComponent end)
        local data
        pcall(function() prog.BuildingsUnlocked:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            if not data and U.valid(d) and U.short(d) == want then data = d end
        end) end)
        if not data then return { ok = false, reason = "piece not unlocked: " .. want } end
        local ui = U.find_all("BuildingUIAPI", { skip_defaults = true })[1]
        if not U.valid(ui) then return { ok = false, reason = "no BuildingUIAPI" } end
        local ok, err = pcall(function() ui:CallOnBuildingItemSelected(data) end)
        out.called, out.err = ok, (not ok) and tostring(err) or nil
    elseif step == "aim" then
        local l = U.loc(pawn)
        local r = U.try(function() return pc:GetControlRotation() end)
        local yaw = math.rad((r and r.Yaw) or 0)
        local d = (AIM_M or 4) * 100
        local cam = U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
        local okc, cx, cy, cz = pcall(function() return cam.X, cam.Y, cam.Z end)
        if not okc then cx, cy, cz = l.X, l.Y, l.Z + 60 end
        local tx, ty, tz = l.X + math.cos(yaw) * d, l.Y + math.sin(yaw) * d, l.Z - 90
        local dx, dy, dz = tx - cx, ty - cy, tz - cz
        out.target = { tx, ty, tz }
        out.aimed = pcall(function() pc:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }) end)
    elseif step == "preview" then
        local found = {}
        for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
            if U.try(function() return a.bIsPreview end) == true then
                local l = U.loc(a)
                found[#found + 1] = { id = U.short(a), class = U.class_word(a), piece = nm(U.try(function() return a.BuildingPieceData end)),
                                      at = l and { l.X, l.Y, l.Z }, ghosted = U.try(function() return a.bIsGhosted end),
                                      yaw = U.try(function() return a:K2_GetActorRotation().Yaw end),
                                      managing = nm(U.try(function() return a.PlayerControllerManagingPlacement end)) }
                if #found >= 5 then break end
            end
        end
        out.previews = found
        out.helper = nm(U.try(function() return bm.BuildingHelperActor end))
    end
    state()
    return out
end
