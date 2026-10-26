-- One call of the shared modal gate (input.gate: runs the orphan sweep) + the modal and last screen cleanup.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local m = I.gate()
    return { ok = true, blocked = m, mode = I.input_mode(), last = I.status().last_screen_cleanup }
end
