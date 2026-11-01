-- READ-ONLY probe (deconstruct skill, 2026-11-01): what the client knows about built pieces and the game's destroy
-- inputs. No input, no RPC, no write. Prefix `local AT = {x, y, z}` (metres) and `local R = 40` to move the circle.
--   * the piece catalogue: every loaded UBuildingPieceData -> BuildingPieceDataIndex, asset, DisplayName, Category tag
--   * GlobalBuildingManager.BuildingPieces within R of AT: pid, index, name, category, location, yaw, ghosted, health,
--     stability, and the actor (when it has one): class, has an inventory and how many items it holds
--   * BuildInteractionComponent: DestroyBuildingAction / DestroyBuildingHoldAction / InteractAction, the
--     DestroyRequestNotificationTextMap (the game's own refusal words), TargetedPieceHandle.Context now
--   * BuildModeComponent.ToggleRepairAndEditModeAction, CurrentBuildMode
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local API = inst.module.API
    local s = API.module("sense")
    local U = s and s.U
    local pc = s.local_pc()
    local t0 = os.clock()
    local function asset(o)
        local p = U.valid(o) and U.path_of(o)
        return p and (p:match("%.([%w_]+)$") or p) or nil
    end
    local function str(v) local x = U.str(v); if x and x ~= "" and x ~= "None" then return x end end
    local out = { ok = true }
    -- catalogue
    local cat, ncat = {}, 0
    for _, d in ipairs(FindAllOf("BuildingPieceData") or {}) do
        if U.valid(d) and not tostring(U.fullname(d) or ""):find("Default__", 1, true) then
            local idx = tonumber((U.try(function() return d.BuildingPieceDataIndex end)))
            if idx then
                ncat = ncat + 1
                cat[idx] = { id = asset(d), name = str(U.try(function() return d.DisplayName end)),
                             category = str(U.try(function() return d.Category.TagName end)) }
            end
        end
    end
    out.catalogue_n = ncat
    -- pieces
    local here = API.my_position()
    out.me = here
    local at = rawget(_G, "AT") or AT or here
    local r = rawget(_G, "R") or R or 40
    local gbm
    for _, a in ipairs(FindAllOf("GlobalBuildingManager") or {}) do if U.valid(a) then gbm = a end end
    local actors = {}
    for _, a in ipairs(FindAllOf("BaseBuildingActor") or {}) do
        if U.valid(a) and U.try(function() return a.bIsPreview end) ~= true then
            local pid = tonumber((U.try(function() return a.BuildingPieceID end)))
            if pid then actors[pid] = a end
        end
    end
    local invm = API.module("inventory")
    local pieces = {}
    local map = gbm and U.try(function() return gbm.BuildingPieces end)
    pcall(function()
        map:ForEach(function(k, v)
            local st = U.try(function() return v:get() end) or v
            local cv = st and U.try(function() return st.ClientVisible end)
            local l = cv and U.try(function() return cv.Location end)
            local okp, x, y, z = pcall(function() return l.X, l.Y, l.Z end)
            if okp and type(x) == "number" and math.sqrt((x / 100 - at[1]) ^ 2 + (y / 100 - at[2]) ^ 2) <= r then
                local pid = tonumber((U.try(function() return k:get() end)))
                local idx = tonumber((U.try(function() return cv.BuildingPieceDataIndex end)))
                local c = (idx and cat[idx]) or {}
                local e = { pid = pid, index = idx, id = c.id, name = c.name, category = c.category,
                            at = { math.floor(x + 0.5) / 100, math.floor(y + 0.5) / 100, math.floor(z + 0.5) / 100 },
                            yaw = tonumber((U.try(function() return cv.Yaw end))),
                            ghosted = U.try(function() return cv.bGhosted end),
                            health = tonumber((U.try(function() return cv.FractionalHealth end))),
                            stability = tonumber((U.try(function() return cv.StabilityValue end))) }
                local a = pid and actors[pid]
                if a then
                    e.actor = U.short(a)
                    e.class = U.short(U.try(function() return a:GetClass() end))
                    local inv = invm and invm.inventory_of and invm.inventory_of(a)
                    if inv then
                        local rows = invm.external_rows(inv)
                        local n = 0
                        for _, c2 in pairs(rows.by_item or {}) do n = n + c2 end
                        e.holds = n
                        e.holds_items = rows.by_item
                    end
                end
                pieces[#pieces + 1] = e
            end
        end)
    end)
    table.sort(pieces, function(a, b) return (a.pid or 0) < (b.pid or 0) end)
    out.at, out.r, out.pieces, out.n = at, r, pieces, #pieces
    out.next_pid = gbm and tonumber((U.try(function() return gbm.GeneratedPieceID end)))
    -- inputs and words
    local bi = pc and U.try(function() return pc.BuildInteractionComponent end)
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    if U.valid(bi) then
        out.destroy_action = U.path_of(U.try(function() return bi.DestroyBuildingAction end))
        out.destroy_hold_action = U.path_of(U.try(function() return bi.DestroyBuildingHoldAction end))
        out.interact_action = U.path_of(U.try(function() return bi.InteractAction end))
        out.detection_range = tonumber((U.try(function() return bi.DetectionRange end)))
        out.targeted_ctx = tonumber((U.try(function() return bi.TargetedPieceHandle.Context end)))
        local words = {}
        pcall(function()
            bi.DestroyRequestNotificationTextMap:ForEach(function(k, v)
                local kk = U.try(function() return k:get() end); if kk == nil then kk = k end
                local vv = U.try(function() return v:get() end); if vv == nil then vv = v end
                words[tostring(kk)] = U.str(vv)
            end)
        end)
        out.destroy_words = words
    end
    if U.valid(bm) then
        out.repair_toggle_action = U.path_of(U.try(function() return bm.ToggleRepairAndEditModeAction end))
        out.build_mode = tonumber((U.try(function() return bm.CurrentBuildMode end)))
    end
    out.ms = math.floor((os.clock() - t0) * 1000)
    return out
end
