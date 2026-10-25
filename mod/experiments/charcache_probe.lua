-- READ-ONLY (dev server): the world's ACachedCharacterStates actor (Dominion.hpp:9068; SaveGame, SPUD-persisted).
-- Lists each cached character: guid, LastUpdated, State length, char_name / SaveCount / skill XP pulled out of
-- the State string by pattern. No writes, no RPCs. debug_run {"module":"charcache_probe"}.
local M = {}

function M.run(log, args)
    local out = { actors = {} }
    local list = FindAllOf("CachedCharacterStates") or {}
    for _, a in ipairs(list) do
        if a:IsValid() and not a:GetFullName():find("Default__", 1, true) then
            local r = { name = a:GetFullName(), entries = {} }
            pcall(function()
                a.CachedCharacterStates:ForEach(function(i, e)
                    local s = e:get()
                    local st = ""
                    pcall(function() st = s.State:ToString() end)
                    local ent = { i = i, state_len = #st }
                    pcall(function() ent.last_updated = s.LastUpdated end)
                    ent.char_name = st:match('"char_name"%s*:%s*"([^"]*)"')
                    ent.save_count = st:match('"SaveCount"%s*:%s*(%d+)')
                    ent.playtime = st:match('"Playtime_wall"%s*:%s*([%d%.]+)')
                    ent.head = st:sub(1, 160)
                    local xps = {}
                    for id, xp in st:gmatch('"Id"%s*:%s*"([^"]+)"%s*,%s*"Xp"%s*:%s*(%d+)') do xps[#xps + 1] = id .. "=" .. xp end
                    ent.skill_xp = xps
                    r.entries[#r.entries + 1] = ent
                end)
            end)
            out.actors[#out.actors + 1] = r
        end
    end
    -- Live skill XP of every player controller on the server, for comparison.
    out.players = {}
    for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
        if pc:IsValid() and not pc:GetFullName():find("Default__", 1, true) then
            local p = { pc = pc:GetFName():ToString() }
            pcall(function() p.total_level = pc.SkillComponent:GetTotalSkillLevel() end)
            pcall(function() p.name = pc.PlayerState:GetPlayerName():ToString() end)
            out.players[#out.players + 1] = p
        end
    end
    return { ok = true, data = out }
end

return M
