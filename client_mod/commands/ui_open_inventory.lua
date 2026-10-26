-- Experiment (BUGS B-stuck-focused-ui): open the Inventory screen with the game's own
-- InputManagerUIAPI:OpenWidgetIfClosed(PC, 11, false, false), to check the stray-screen guards live.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local api, pc = I.input_manager(), I.pc()
    if not (api and pc) then return { ok = false, reason = "no InputManagerUIAPI" } end
    local ok, err = pcall(function() api:OpenWidgetIfClosed(pc, 11, false, false) end)
    return { ok = ok, err = (not ok) and tostring(err) or nil, mode = I.input_mode() }
end
