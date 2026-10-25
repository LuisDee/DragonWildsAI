-- One-off probe: why do destroyed puppets still show up in FindAllOf?
local M = {}
local function try(f) local ok, v = pcall(f); if ok then return v end; return "ERR:" .. tostring(v) end
function M.run(log, args)
    local out = {}
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        out[#out + 1] = {
            name = try(function() return p:GetFullName() end),
            ue4ss_valid = try(function() return p:IsValid() end),
            being_destroyed = try(function() return p:IsActorBeingDestroyed() end),
            ksl_valid = try(function() return ksl:IsValid(p) end),
            root = try(function() return tostring(p.RootComponent and p.RootComponent:IsValid()) end),
            flags_garbage = try(function() return p:HasAnyInternalFlags(0x200000) end),
            mirrored = try(function() return p:HasAnyFlags(0x40000000) end),
        }
    end
    local live, dead = 0, 0
    for _, c in ipairs(FindAllOf("AIController") or {}) do
        if try(function() return c:HasAnyInternalFlags(0x10200000) end) == true then dead = dead + 1 else live = live + 1 end
    end
    return { pawns = out, ai_controllers_live = live, ai_controllers_garbage = dead }
end
return M
