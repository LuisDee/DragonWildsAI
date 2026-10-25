-- Locomotion status (move.lua), read-only.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.status()
end
