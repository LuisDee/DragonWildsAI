-- One press of the UI accept (IA_UI_GenericAccept) through input.raw_inject: leaves a focused UI screen
-- (e.g. DIM_FocussedInGameUI) the way a player does. Reports the input mode before/after (read back next tick by the caller).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local before = I.input_mode()
    local back = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericAccept.IA_UI_GenericAccept")
    local ok = back and I.raw_inject(back) or false
    return { ok = ok == true, before = before }
end
