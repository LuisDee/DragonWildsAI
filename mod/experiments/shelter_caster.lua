-- Read-only: GetCaster / Owner / Instigator of each live Summon Shelter (what the "owner" shown in game is).
-- debug_run {module="shelter_caster"}
local U = require("body.util")
local M = {}
function M.run(log, args)
    local res = {}
    for _, a in ipairs(U.find_all("BP_Magic_SummonShelter_C")) do
        if U.alive(a) then
            res[U.short(a)] = { caster = U.fullname(U.try(function() return a:GetCaster() end)) or "nil",
                                owner = U.fullname(U.try(function() return a.Owner end)) or "nil",
                                instigator = U.fullname(U.try(function() return a.Instigator end)) or "nil",
                                cast_id = U.try(function() return a.CastID end) }
        end
    end
    return res
end
return M
