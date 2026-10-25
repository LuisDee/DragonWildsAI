-- Walk to Zezima (Luis) and stop ~3 m from him (move.lua go_to with a player target).
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, "Zezima", { tolerance_m = 3, timeout_s = 90 })
end
