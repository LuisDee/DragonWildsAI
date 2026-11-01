-- Read-only: read the FollowerDataAsset's FollowerClass soft pointer path a few ways.
return function(log)
    local out = {}
    local ok, list = pcall(FindAllOf, "FollowerDataAsset")
    for _, d in ipairs(ok and list or {}) do
        local c = d.FollowerClass
        local function try(k, f) local o, v = pcall(f); out[k] = o and tostring(v) or ("ERR " .. tostring(v):sub(1, 90)) end
        try("get", function() local x = c:get(); return x and x:GetFullName() end)
        try("Get", function() local x = c:Get(); return x and x:GetFullName() end)
        try("path1", function() return c.SoftObjectPtr.ObjectID.AssetPathName:ToString() end)
        try("path2", function() return c:GetSoftObjectPath():ToString() end)
        try("path3", function() return c.ObjectID.AssetPathName:ToString() end)
        try("path4", function() return c:ToSoftObjectPath():ToString() end)
        try("path5", function() return c:GetObjectID():GetAssetPathName():ToString() end)
        try("path6", function() return c:GetObjectID().AssetPathName:ToString() end)
        try("path7", function() return c:GetObjectID():GetAssetPathName() end)
    end
    return { ok = true, r = out }
end
