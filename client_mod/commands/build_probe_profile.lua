-- READ-ONLY build probe (research 2026-11-01-autonomous-building §6 step 2): one unlocked piece's placement profile
-- and size from its data, without build mode: UBuildingPieceData.DerivedData (a soft pointer, read with :Get() only
-- when already loaded: nothing is loaded here) -> PlacementProfileRowHandle (DataTable:FindRow) flags,
-- BuildingPieceLocalBounds, PlacementZOffset. Prefix: `local PIECE = "<asset id>"` (default DA_T1_Foundation_Large).
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s and s.U
    local pc = s.local_pc()
    local want = rawget(_G, "PIECE") or PIECE or "DA_T1_Foundation_Large"
    local prog = pc and U.try(function() return pc.ProgressComponent end)
    if not U.valid(prog) then return { ok = false, reason = "no ProgressComponent" } end
    local data
    pcall(function()
        prog.BuildingsUnlocked:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            if not data and U.valid(d) and U.short(d) == want then data = d end
        end)
    end)
    if not data then return { ok = false, reason = "piece not unlocked", piece = want } end
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x, y, z } end end
    local out = { ok = true, piece = want, name = U.str(U.try(function() return data.DisplayName end)),
                  piece_tag = U.str(U.try(function() return data.PieceTag.TagName end)) }
    -- a soft pointer: its path (the repo's pattern, inventory.lua/sense.lua), then StaticFindObject = only if loaded
    local soft = U.try(function() return data.DerivedData end)
    local path = soft and U.str(U.try(function() return soft:GetObjectID():GetAssetPathName() end))
    out.derived_path = path
    local dd = path and U.find_object(path)
    if not U.valid(dd) then out.derived = "not_loaded"; return out end
    out.derived = U.short(dd)
    local b = U.try(function() return dd.BuildingPieceLocalBounds end)
    if b then out.local_bounds_cm = { origin = v3(U.try(function() return b.Origin end)), extent = v3(U.try(function() return b.BoxExtent end)) } end
    out.z_offset = U.try(function() return dd.PlacementZOffset end)
    local h = U.try(function() return dd.PlacementProfileRowHandle end)
    local dt = h and U.try(function() return h.DataTable end)
    local row_name = h and U.str(U.try(function() return h.RowName end))
    out.profile = row_name
    out.table = U.valid(dt) and U.short(dt) or nil
    if U.valid(dt) and row_name then
        local ok, row = pcall(function() return dt:FindRow(row_name) end)
        if ok and row ~= nil then
            local f = {}
            for _, k in ipairs({ "bCanOnlyBeSnapped", "bForcePlugRotation", "bCanSharePlugWithSamePieces", "bAllowUserHeightModification",
                                 "bAllowUserRotationModification", "bCanOnlyBePlacedOnDefinedSurface", "bCanOnlyBePlacedOnGround",
                                 "bOverrideRotationFromHitSurface", "bShouldOffsetFromNonBuildingSurface" }) do
                f[k] = U.try(function() return row[k] end)
            end
            out.flags = f
        else
            out.flags_error = tostring(row)
        end
    end
    return out
end
