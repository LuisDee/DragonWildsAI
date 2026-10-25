-- LIVE (moves the pawn, swings the axe): gather 2 ash logs from the nearest standing ash tree via
-- client_mod/scripts/gather.lua at arbiter level "task". Returns at once; follow with gather_status.lua.
return function(log)
    local G = assert(loadfile("C:/gameserver/client_mod/scripts/gather.lua"))()
    return G.start(log, { resource = "ash", count = 2, radius = 40 }, { id = "cmd_gather_ash2" })
end
