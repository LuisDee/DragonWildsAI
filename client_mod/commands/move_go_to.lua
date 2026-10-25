-- go_to a fixed point: the goal is read from client_io/nav/goto.lua (`return {x,y,z}` metres,
-- or `return "PlayerName"`), so tools can set it without editing this file.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local g = assert(loadfile("C:/gameserver/client_io/nav/goto.lua"), "write client_io/nav/goto.lua first")()
    return M.go_to(log, g, { tolerance_m = 1.5, sprint_m = 10, timeout_s = 90 })
end
