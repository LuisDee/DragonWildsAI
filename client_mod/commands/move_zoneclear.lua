-- Clear every avoid zone (scripts/move.lua M.set_avoid_zones(log, {})).
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.set_avoid_zones(log, {})
end
