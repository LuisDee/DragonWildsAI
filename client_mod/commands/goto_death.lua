-- Trip toward the last death spot (where the 18:18 follow stopped, ~(440.1, 1766.8, -40.9) m) to find the grave.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 440.06, 1766.78, -40.88 }, { tolerance_m = 3, timeout_s = 240 })
end
