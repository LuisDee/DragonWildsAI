-- Leg 1 of the grave trip: the spot east of the lodestone known reachable (where he met Luis at 18:05).
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 89.48, 1851.2, -31.42 }, { tolerance_m = 2, timeout_s = 60 })
end
