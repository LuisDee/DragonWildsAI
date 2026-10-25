-- One authorised trip: walk to Claude's gravestone (position from sense_grave) with move.lua.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 70.51, 1870.07, -32.86 }, { tolerance_m = 1.2, timeout_s = 60 })
end
