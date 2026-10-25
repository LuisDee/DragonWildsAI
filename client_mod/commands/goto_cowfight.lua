-- Trip to the cow-fight area (~(438.7, 1837.5) m) where he likely died at ~19:14-19:18 UTC, to find the grave.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 438.7, 1837.5, -35.0 }, { tolerance_m = 4, timeout_s = 300 })
end
