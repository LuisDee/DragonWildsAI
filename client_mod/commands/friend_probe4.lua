-- Read-only: the loaded FollowerDataAssets and the class each spawns (a player's summon = one of these classes).
return function(log)
    local out = {}
    for _, cls in ipairs({ "FollowerDataAsset" }) do
        local ok, list = pcall(FindAllOf, cls)
        if ok and type(list) == "table" then
            for _, d in ipairs(list) do
                local r = {}
                pcall(function() r.name = d:GetFullName() end)
                pcall(function() local c = d.FollowerClass; r.cls = c and (c.GetFullName and c:GetFullName() or tostring(c)) end)
                pcall(function() local c = d.FollowerClass; r.cls2 = c and c:ToString() end)
                pcall(function() local c = d.FollowerClass; r.cls3 = c and c:GetAssetPathName():ToString() end)
                out[#out + 1] = r
            end
        else out[#out + 1] = { err = tostring(list) } end
    end
    return { ok = true, rows = out }
end
