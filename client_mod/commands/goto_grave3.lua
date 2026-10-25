-- Walk to the gravestone found at (441.6, 1829.1, -16.68) m (cow-fight death, ~20 m up a slope).
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 441.6, 1829.1, -16.68 }, { tolerance_m = 1.0, timeout_s = 120 })
end
