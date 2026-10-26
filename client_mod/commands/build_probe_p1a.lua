-- READ-ONLY build probe P1a (docs/design/build-primitive.md §7 + review finding 12): object and scalar reads
-- only, plus the BuildingsUnlocked object list. Never presses, never calls a UI handler, never loads soft refs.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local B = inst.module
    local s = B.API.module("sense")
    local U = s and s.U
    if not U then return { ok = false, reason = "no sense" } end
    local function v(f) local ok, x = pcall(f); if ok then return x end return "ERR" end
    local function str(x) return U.str(x) end
    local out = { ok = true }
    local pc = s.local_pc()
    out.pc = U.short(pc)
    out.input_mode = U.short(U.try(function() return pc.CurrentInputMode end))
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    out.build_mode = U.valid(bm) and {
        current = v(function() return bm.CurrentBuildMode end), prev = v(function() return bm.PrevBuildMode end),
        snapping = v(function() return bm.SnappingMode end), new_component = v(function() return bm.bUseNewComponent end),
        placing = U.short(U.try(function() return bm.CurrentlyPlacingPieceData end)),
        cancel_action = U.short(U.try(function() return bm.CancelAction end)),
        rotate_action = U.short(U.try(function() return bm.ModifyRotationAction end)),
        ghost_action = U.short(U.try(function() return bm.GhostModifierAction end)),
        mapping = U.short(U.try(function() return bm.BuildingMappingContext end)),
        mpc = U.short(U.try(function() return bm.MaterialParameterCollection end)),
        validity_mpn = str(U.try(function() return bm.PlacingValidityStateIndexMPN end)),
        cursor_mpn = str(U.try(function() return bm.CursorWorldPositionMPN end)),
        placement_component = U.short(U.try(function() return bm.BuildPlacementComponent end)),
        helper = U.short(U.try(function() return bm.BuildingHelperActor end)),
    } or "missing"
    local bp = pc and U.try(function() return pc.BuildPlacementComponent end)
    out.placement = U.valid(bp) and {
        max_dist = v(function() return bp.MaxPlacementDistance end), selection_max_dist = v(function() return bp.SelectionMaxPlacementDistance end),
        max_dist_mod = v(function() return bp.MaxDistanceModifier end), max_height_mod = v(function() return bp.MaxHeightModifier end),
    } or "missing"
    local bi = pc and U.try(function() return pc.BuildInteractionComponent end)
    out.interaction = U.valid(bi) and {
        min_between_s = v(function() return bi.MinTimeBetweenBuildingPlacementRequests end),
        range = v(function() return bi.DetectionRange end),
        interact_action = U.short(U.try(function() return bi.InteractAction end)),
        quick_action = U.short(U.try(function() return bi.QuickInteractAction end)),
    } or "missing"
    out.validation = U.valid(pc and U.try(function() return pc.BuildValidationComponent end))
    -- privileges (EPlayerPrivilege Build 2, OpenChests 4, Chat 8, Owner 128)
    local ps = pc and U.try(function() return pc.PlayerState end)
    local pr = U.valid(ps) and U.try(function() return ps.PrivilegeComponent end)
    out.privileges = U.valid(pr) and {
        build = v(function() return pr:HasPrivilege(2) end), open_chests = v(function() return pr:HasPrivilege(4) end),
        chat = v(function() return pr:HasPrivilege(8) end), owner = v(function() return pr:HasPrivilege(128) end),
    } or "missing"
    -- unlocks
    local prog = pc and U.try(function() return pc.ProgressComponent end)
    if U.valid(prog) then
        out.farming_unlocked = v(function() return prog.bFarmingUnlocked end)
        local list = {}
        pcall(function()
            prog.BuildingsUnlocked:ForEach(function(_, e)
                local d = U.try(function() return e:get() end) or e
                if U.valid(d) and #list < 400 then
                    list[#list + 1] = (U.short(d) or "?") .. "|" .. tostring(str(U.try(function() return d.DisplayName end)))
                        .. "|host=" .. tostring(U.try(function() return d.bOnlyAvailableToHost end))
                        .. "|xp=" .. tostring(U.try(function() return d.ConstructionXPOnBuild end))
                        .. "|idx=" .. tostring(U.try(function() return d.BuildingPieceDataIndex end))
                end
            end)
        end)
        out.unlocked_n, out.unlocked = #list, list
    else
        out.progress = "missing"
    end
    -- the build menu's API object and the settings CDO
    local apis = U.find_all("BuildingUIAPI", { skip_defaults = true })
    out.building_ui_api = { count = #apis, first = U.short(apis[1]) }
    local cdo = U.find_object("/Script/Dominion.Default__BuildingSettings")
    out.settings = U.valid(cdo) and {
        rotation_step_deg = v(function() return cdo.ModifyRotationStepDeg end), height_step = v(function() return cdo.ModifyHeightStep end),
        distance_step = v(function() return cdo.ModifyDistanceStep end), max_pieces = v(function() return cdo.MaxNumPieces end),
        catalogue_loaded = U.short(U.try(function() return cdo.BuildPieceCatalogue end)),
    } or "missing"
    local gbm = U.find_all("GlobalBuildingManager", { skip_defaults = true })
    out.global_manager = { count = #gbm, counter = gbm[1] and U.short(U.try(function() return gbm[1].CounterComponent end)) }
    -- what the shared input gate sees now (input.lua, if loaded)
    local IN = B.API.module("input")
    out.input_modal = IN and IN.modal and IN.modal() or "input.lua not loaded"
    return out
end
