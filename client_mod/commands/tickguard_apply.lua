-- Apply the tick guard (scripts/tickguard.lua) to the live world now and return the read-back.
return function(log)
    local T = assert(loadfile("C:/gameserver/client_mod/scripts/tickguard.lua"))()
    return T.apply(log)
end
