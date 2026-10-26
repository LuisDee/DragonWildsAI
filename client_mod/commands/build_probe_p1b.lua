-- READ-ONLY build probe P1b (review finding 12): ONE TMap / struct-array read per call, chosen by WHICH
-- (prefix the file with `local WHICH = "<name>"`): texts | scalar_index | max_counts | counts | requirements.
-- The owner is validated in the same tick; nothing under DW_PAUSE; no soft refs loaded; nothing pressed.
return function(log)
    local which = rawget(_G, "WHICH") or WHICH or "texts"
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local B = inst.module
    local s = B.API.module("sense")
    local U = s and s.U
    local pc = s.local_pc()
    local out = { ok = true, which = which, entries = {} }
    local function kv(map, kfn, vfn)
        if map == nil then out.error = "map unreadable"; return end
        local ok, err = pcall(function()
            map:ForEach(function(k, v)
                local kk = U.try(function() return k:get() end)
                if kk == nil then kk = k end
                local vv = U.try(function() return v:get() end)
                if vv == nil then vv = v end
                if #out.entries < 64 then out.entries[#out.entries + 1] = { k = kfn(kk), v = vfn(vv) } end
            end)
        end)
        if not ok then out.error = tostring(err) end
    end
    local function num(x) return tonumber(x) or tostring(x) end
    local function txt(x) return U.str(x) or tostring(x) end
    local function tag(x) return U.str(U.try(function() return x.TagName end)) or tostring(x) end
    if which == "texts" then
        local bi = pc and U.try(function() return pc.BuildInteractionComponent end)
        if not U.valid(bi) then return { ok = false, reason = "no BuildInteractionComponent" } end
        kv(U.try(function() return bi.ValidityNotificationTextMap end), num, txt)
    elseif which == "scalar_index" then
        local bm = pc and U.try(function() return pc.BuildModeComponent end)
        if not U.valid(bm) then return { ok = false, reason = "no BuildModeComponent" } end
        kv(U.try(function() return bm.ValiditySpawnStateToScalarIndex end), num, num)
    elseif which == "max_counts" then
        local cdo = U.find_object("/Script/Dominion.Default__BuildingSettings")
        if not U.valid(cdo) then return { ok = false, reason = "no settings CDO" } end
        kv(U.try(function() return cdo.PieceTagToMaxCountMap end), tag, num)
    elseif which == "counts" then
        local g = U.find_all("GlobalBuildingManager", { skip_defaults = true })[1]
        local c = g and U.try(function() return g.CounterComponent end)
        if not U.valid(c) then return { ok = false, reason = "no CounterComponent" } end
        kv(U.try(function() return c.TagsToCountsMap end), tag, num)
    elseif which == "requirements" then
        local prog = pc and U.try(function() return pc.ProgressComponent end)
        if not U.valid(prog) then return { ok = false, reason = "no ProgressComponent" } end
        local piece
        pcall(function()
            prog.BuildingsUnlocked:ForEach(function(_, e)
                local d = U.try(function() return e:get() end) or e
                if not piece and U.valid(d) and U.short(d) == ((rawget(_G, "PIECE") or PIECE) or "BUILDPIECE_Campfire") then piece = d end
            end)
        end)
        if not piece then return { ok = false, reason = "piece not unlocked" } end
        out.piece = U.short(piece)
        out.category = U.str(U.try(function() return piece.Category.TagName end))
        out.description = U.str(U.try(function() return piece.Description end))
        out.shelter_text = U.str(U.try(function() return piece.ShelterRequirementText end))
        local ok, err = pcall(function()
            piece.Requirements:ForEach(function(_, e)
                local r = U.try(function() return e:get() end) or e
                local data = U.try(function() return r.ItemData end)
                out.entries[#out.entries + 1] = { amount = U.try(function() return r.Amount end), item = U.short(data),
                                                  name = U.str(U.try(function() return data.Name end)) }
            end)
        end)
        if not ok then out.error = tostring(err) end
    end
    return out
end
