-- Read-only timing probe: how long do the lookups our loops use take on the game thread?
-- Times the raw FindAllOf on purpose (no filtering), so the number is the engine's cost.
-- debug_run {module="perf_probe"}
local U = require("body.util")

local M = {}

function M.run()
    local out = {}
    for _, cls in ipairs({ U.PLAYER_CHAR_CLASS, "DominionAICharacter", U.PLAYER_CONTROLLER_CLASS }) do
        local t = os.clock()
        local n = #(U.try(FindAllOf, cls) or {})
        out[cls] = { ms = math.floor((os.clock() - t) * 1000 + 0.5), count = n }
    end
    return out
end

return M
