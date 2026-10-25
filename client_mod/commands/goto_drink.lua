-- Step onto the dropped drink so the game's interaction detector targets it.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 60.41, 1880.26, -36.25 }, { tolerance_m = 0.5, timeout_s = 15 })
end
