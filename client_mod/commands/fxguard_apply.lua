-- Apply fxguard (BUGS L38) now and report; the client_bridge service does the same every 10 s.
return function(log)
    local F = assert(loadfile("C:/gameserver/client_mod/scripts/fxguard.lua"))()
    return F.apply(log)
end
