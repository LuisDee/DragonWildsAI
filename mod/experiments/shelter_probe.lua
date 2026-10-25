-- Read-only: compare live Summon Shelters (Luis's vs the bot's) to find what the "owner" shown
-- in game is. Lists the shelter Blueprint class's own properties with values, plus the bed claimant.
-- The BP class loads after the reflection dump ran, so it is not in dumps/.
-- debug_run {module="shelter_probe"}
local U = require("body.util")
local M = {}

local function value_of(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return v end
    if t ~= "userdata" then return t end
    local s = U.try(function() return v:ToString() end)
    if s then return s end
    local full = U.fullname(v)
    if full then return full end
    local x = U.try(function() return v.X end)
    if x then return { X = x, Y = U.try(function() return v.Y end), Z = U.try(function() return v.Z end) } end
    return "userdata"
end

local function props(obj, cls)
    local out = {}
    pcall(function()
        cls:ForEachProperty(function(prop)
            local name = prop:GetFName():ToString()
            local kind = prop:GetClass():GetFName():ToString()
            out[name] = { kind = kind, value = value_of(U.try(function() return obj[name] end)) }
        end)
    end)
    return out
end

function M.run(log, args)
    local res = {}
    for _, a in ipairs(U.find_all("BP_Magic_SummonShelter_C")) do
        if U.alive(a) then
            local cls = U.try(function() return a:GetClass() end)
            local entry = { loc = U.loc(a), owner = U.fullname(U.try(function() return a:GetOwner() end)),
                            instigator = U.fullname(U.try(function() return a:GetInstigator() end)),
                            props = props(a, cls) }
            local super = U.try(function() return cls:GetSuperStruct() end)
            entry.super = U.fullname(super)
            if U.valid(super) and not (U.fullname(super) or ""):find("/Script/") then entry.super_props = props(a, super) end
            for _, b in ipairs(U.find_all("BedComponent")) do
                if U.try(function() return b:GetOwner() end) == a or U.short(U.try(function() return b:GetOwner() end)) == U.short(a) then
                    entry.bed = { claimed_any = U.try(function() return b:IsClaimedByAnyPlayer() end),
                                  name = value_of(U.try(function() return b:GetClaimingCharacterName() end)),
                                  requires_claim = U.try(function() return b.bRequiresClaimingToSleepIn end) }
                end
            end
            res[U.short(a)] = entry
        end
    end
    return res
end

return M
