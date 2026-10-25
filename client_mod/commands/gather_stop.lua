-- Stop the running gather job (releases the pawn through the arbiter).
return function(log)
    local G = assert(loadfile("C:/gameserver/client_mod/scripts/gather.lua"))()
    return G.stop(log, "gather_stop command")
end
