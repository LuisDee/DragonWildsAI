-- Read-only: guarded tick functions and their current TickInterval (scripts/tickguard.lua).
return function(log)
    local T = assert(loadfile("C:/gameserver/client_mod/scripts/tickguard.lua"))()
    return T.status()
end
