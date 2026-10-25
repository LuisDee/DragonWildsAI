-- READ-ONLY: the CachedCharacterStates actor(s) visible on Claude's client: entry count, guid, LastUpdated,
-- State length and a few fields pulled out of State by pattern (no writes, no calls with side effects).
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local out = { actors = {} }
    for _, a in ipairs(U.find_all("CachedCharacterStates", { skip_defaults = true }) or {}) do
        local r = { actor = U.short(a), path = U.path_of(a), entries = {} }
        r.has_authority = U.try(function() return a:HasAuthority() end)
        r.replicates = U.try(function() return a.bReplicates end)
        pcall(function()
            a.CachedCharacterStates:ForEach(function(i, e)
                local s = U.try(function() return e:get() end) or e
                local g = U.try(function() return s.CharacterGuid.InnerGuid end)
                local st = U.try(function() return s.State:ToString() end) or ""
                local ent = {
                    i = i, last_updated = U.try(function() return s.LastUpdated end), state_len = #st,
                    guid = g and string.format("%08X%08X%08X%08X", (g.A or 0) % 2^32, (g.B or 0) % 2^32,
                        (g.C or 0) % 2^32, (g.D or 0) % 2^32) or nil,
                    head = st:sub(1, 200),
                    char_name = st:match('"char_name"%s*:%s*"([^"]*)"'),
                    save_count = st:match('"SaveCount"%s*:%s*(%d+)'),
                    playtime = st:match('"Playtime_wall"%s*:%s*([%d%.]+)'),
                }
                local xps = {}
                for id, xp in st:gmatch('"Id"%s*:%s*"([^"]+)"%s*,%s*"Xp"%s*:%s*(%d+)') do xps[#xps + 1] = id .. "=" .. xp end
                ent.skill_xp = xps
                r.entries[#r.entries + 1] = ent
            end)
        end)
        out.actors[#out.actors + 1] = r
    end
    return out
end
