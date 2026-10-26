-- The game's own re-evaluation of the PC input mode (DominionPlayerController.RefreshInputMode, no params), for a
-- stuck mode with no visible screen (live 2026-10-26 18:43 DIM_FocussedInGameUI after eating). Reads the mode before.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local pc = I.pc()
    local before = I.input_mode()
    local ok, err = pcall(function() pc:RefreshInputMode() end)
    return { ok = ok, before = before, err = (not ok) and tostring(err) or nil }
end
