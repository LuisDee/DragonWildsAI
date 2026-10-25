-- gather job status (read-only): phase, target, swings/hits, counts, recent log lines.
return function(log)
    local G = assert(loadfile("C:/gameserver/client_mod/scripts/gather.lua"))()
    return G.status()
end
