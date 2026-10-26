-- BUGS L38: read (and, when _G.L38_SET is a table {cvar = value}, set) the Niagara scalability cvars on
-- Claude's client. Client-local console variables; nothing replicates.
local NAMES = { "fx.Niagara.Scalability.VisibilityCulling", "fx.Niagara.Scalability.DistanceCulling",
    "fx.Niagara.Scalability.InstanceCountCulling", "fx.Niagara.Scalability.GlobalBudgetCulling",
    "fx.Niagara.Scalability.CanPreventCullingOnPlayerFX", "fx.Niagara.AllowCullProxies", "fx.EnableNiagaraSpriteRendering" }
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local K = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local set = rawget(_G, "L38_SET")
    if type(set) == "table" and pc then
        for k, v in pairs(set) do K:ExecuteConsoleCommand(pc, k .. " " .. tostring(v), pc) end
    end
    _G.L38_SET = nil
    local out = { ok = true }
    for _, n in ipairs(NAMES) do out[n] = U.try(function() return K:GetConsoleVariableIntValue(n) end) end
    return out
end
