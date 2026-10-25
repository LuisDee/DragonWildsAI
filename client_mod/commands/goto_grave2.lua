-- Walk to the gravestone found by sense_grave at (440.28, 1760.98, -41.78) m.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 440.28, 1760.98, -41.78 }, { tolerance_m = 1.0, timeout_s = 40 })
end
