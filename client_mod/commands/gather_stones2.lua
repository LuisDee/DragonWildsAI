-- LIVE (moves the pawn, presses interact): gather 2 ground stones (foliage pickups) via gather.lua at
-- arbiter level "task". Returns at once; follow with gather_status.lua.
return function(log)
    local G = assert(loadfile("C:/gameserver/client_mod/scripts/gather.lua"))()
    return G.start(log, { resource = "stone", count = 2, radius = 40 }, { id = "cmd_gather_stones2" })
end
