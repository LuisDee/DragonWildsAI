-- After a respawn/rejoin: if Claude is in a known trap (e.g. the church start pit), walk its
-- recorded exit (scripts/move.lua M.escape_trap). Returns {ok=false,error="not_in_trap"} otherwise.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.escape_trap(log)
end
