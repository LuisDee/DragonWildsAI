-- LIVE (spells agent): leave a UI/spell mode the way a player does. Press the current mode's own
-- "back" action (IA_UI_GenericBack = Escape in IMC_UI_Generic, or IA_Spellcasting_Cancel), up to 3 times,
-- 0.5 s apart, until the input mode is DIM_Gameplay. Result -> client_io/out/leave_mode_async.json.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local J = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local back = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    local cancel = U.find_object("/Game/Gameplay/Inputs/Actions/Spellcasting/IA_Spellcasting_Cancel.IA_Spellcasting_Cancel")
    local function mode() return U.short(U.try(function() return pc.CurrentInputMode end)) end
    local res = { start = mode(), steps = {} }
    local n, h = 0, nil
    h = LoopInGameThreadWithDelay(500, function()
        local m = mode()
        res.steps[#res.steps + 1] = m
        if m == "DIM_Gameplay" or n >= 3 then
            res.final = m
            local f = io.open("C:/gameserver/client_io/out/leave_mode_async.json", "wb"); if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h); return true
        end
        n = n + 1
        local a = (m == "DIM_SpellcastingMode" or m == "DIM_SpellPlacementMode") and cancel or back
        pcall(function() eis:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end)
    end)
    return { ok = true, started = true, mode = res.start }
end
