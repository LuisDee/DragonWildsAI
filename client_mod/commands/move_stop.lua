-- Stop any locomotion loop (scripts/move.lua) and report the final status.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local r = M.stop(log)
    r.status = M.status()
    return r
end
