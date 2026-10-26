-- One press of the UI's own Back (IA_UI_GenericBack, Esc) through input.raw_inject: leaves a focused UI screen
-- (e.g. DIM_FocussedInGameUI) the way a player does. Reports the input mode before/after (read back next tick by the caller).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local before = I.input_mode()
    local back = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    local ok = back and I.raw_inject(back) or false
    return { ok = ok == true, before = before }
end
