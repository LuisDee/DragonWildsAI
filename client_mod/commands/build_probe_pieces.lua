-- READ-ONLY build probe (2026-11-01 step 3): the client's census of built pieces. Live: a Square Foundation built
-- and confirmed (telemetry, spend, XP) has NO actor on the client (structural pieces render as HISM instances of
-- CellBuildingProxy; only props like the crate get a BaseBuildingActor). So read the replicated piece list:
-- GlobalBuildingManager.BuildingReplicationArray.Items (FBuildingReplicatedEntry: ID, Location, YawRotation,
-- BuildingPieceDataIndex, bIsGhosted, StabilityValue, HealthPercentage) and BuildingPieces (TMap<uint32,
-- FBuildingPieceState>.ClientVisible). Prefix: `local AT = {x, y, z}` metres (default me), `local R = 20`.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s and s.U
    local at = rawget(_G, "AT") or AT
    if not at then local l = U.loc(s.local_pawn()); at = l and { l.X / 100, l.Y / 100, l.Z / 100 } end
    local r = rawget(_G, "R") or R or 20
    local gbm
    for _, a in ipairs(FindAllOf("GlobalBuildingManager") or {}) do if U.valid(a) then gbm = a end end
    if not gbm then return { ok = false, reason = "no GlobalBuildingManager" } end
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end end
    local function near(p) return p and math.sqrt((p[1] - at[1]) ^ 2 + (p[2] - at[2]) ^ 2) <= r end
    local out = { ok = true, at = at, r = r, gbm = U.short(gbm), generated_id = U.try(function() return gbm.GeneratedPieceID end) }
    -- the replicated fast array
    local items, n = {}, 0
    local ok, err = pcall(function()
        gbm.BuildingReplicationArray.Items:ForEach(function(_, e)
            n = n + 1
            local v = U.try(function() return e:get() end) or e
            local p = v3(U.try(function() return v.Location end))
            if near(p) and #items < 30 then
                items[#items + 1] = { id = U.try(function() return v.ID end), at = p, yaw = U.try(function() return v.YawRotation end),
                                      index = U.try(function() return v.BuildingPieceDataIndex end), ghosted = U.try(function() return v.bIsGhosted end),
                                      stability = U.try(function() return v.StabilityValue end), health = U.try(function() return v.HealthPercentage end) }
            end
        end)
    end)
    out.rep = { n = n, near = items, error = (not ok) and tostring(err) or nil }
    -- the state map
    local pieces, m = {}, 0
    ok, err = pcall(function()
        gbm.BuildingPieces:ForEach(function(k, v)
            m = m + 1
            local id = U.try(function() return k:get() end)
            local st = U.try(function() return v:get() end) or v
            local cv = st and U.try(function() return st.ClientVisible end)
            local p = cv and v3(U.try(function() return cv.Location end))
            if near(p) and #pieces < 30 then
                pieces[#pieces + 1] = { id = id, at = p, yaw = U.try(function() return cv.Yaw end), index = U.try(function() return cv.BuildingPieceDataIndex end),
                                        ghosted = U.try(function() return cv.bGhosted end), stability = U.try(function() return cv.StabilityValue end) }
            end
        end)
    end)
    out.map = { n = m, near = pieces, error = (not ok) and tostring(err) or nil }
    -- the subsystem's id -> actor handles (which pieces have an actor)
    local bs = U.try(function() return gbm.BuildingSubsystem end)
    return out
end
