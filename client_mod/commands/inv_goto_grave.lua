-- Trip to Claude's gravestone (position from sense_grave), move.lua go_to.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 71.63, 1862.03, -35.48 }, { tolerance_m = 1.2, timeout_s = 60 })
end
