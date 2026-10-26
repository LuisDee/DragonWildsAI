-- LIVE (spells agent): leave the Eye of Oculus mode through the game's own exit handler,
-- UOculusComponent:RequestExitOculusMode() on Claude's pawn (what the build legend's "Exit" runs; it
-- asks the server itself; we never call Server_RequestStopOculus). Reads the state before and after.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    local oc = U.valid(pawn) and U.try(function() return pawn.OculusComponent end)
    if not U.valid(oc) then return { ok = false, reason = "no OculusComponent" } end
    local out = { ok = true, active_before = U.try(function() return oc:IsOculusActive() end),
                  mode_before = U.short(U.try(function() return pc.CurrentInputMode end)) }
    out.call_ok = pcall(function() oc:RequestExitOculusMode() end)
    return out
end
