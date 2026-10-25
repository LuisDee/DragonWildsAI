-- Follow Zezima (Luis) at 3 m with the client locomotion service (scripts/move.lua): nav-oracle
-- waypoints, sprint when > 10 m, jump/double-jump when stuck. Runs until move_stop.lua.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.follow(log, "Zezima", 3, { sprint_m = 10 })
end
