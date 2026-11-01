-- Read-only: Buddy (KalphiteFriend) vs a goblin: data asset path and candidate faction/friendly props.
return function(log)
    local out = {}
    local ok, actors = pcall(FindAllOf, "DominionAICharacter")
    if not ok or type(actors) ~= "table" then return { ok = false } end
    local want = { Kalphite = 1, MeleeGoblin = 1, GiantRat = 1 }
    local seen = {}
    for _, a in ipairs(actors) do
        local okn, fn = pcall(function() return a:GetFullName() end)
        if okn and fn and not fn:find("Default__", 1, true) then
            local key
            for k in pairs(want) do if fn:find(k, 1, true) then key = k end end
            if key and not seen[key] then
                seen[key] = true
                local r = { name = fn:match("([%w_]+)$") }
                local function try(k, f) local o, v = pcall(f); r[k] = o and tostring(v) or ("ERR") end
                try("data", function() return a.LoadedData:GetFullName() end)
                try("archetype", function() return a.LoadedData.Archetype end)
                try("faction", function() return a.LoadedData.Faction end)
                try("ai_faction", function() return a.Faction end)
                try("FactionTag", function() return a.LoadedData.FactionTag.TagName:ToString() end)
                try("aname", function() return a.LoadedData.AIName:ToString() end)
                try("IsHostile", function() return a:IsHostile() end)
                try("bIsSummoned", function() return a.bIsSummoned end)
                try("bSkipSpudStore", function() return a.bSkipSpudStore end)
                try("IsPlayerFriendly", function() return a:IsFriendlyToPlayers() end)
                try("tags", function() local s = {}; a.Tags:ForEach(function(_, t) s[#s + 1] = t:get():ToString() end); return table.concat(s, ",") end)
                out[#out + 1] = r
            end
        end
    end
    return { ok = true, rows = out }
end
