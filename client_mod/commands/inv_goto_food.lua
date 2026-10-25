-- Short trip to Luis's food/drink drop (authorised by main), move.lua go_to.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    return M.go_to(log, { 55.14, 1884.86, -36.3 }, { tolerance_m = 1.0, timeout_s = 30 })
end
