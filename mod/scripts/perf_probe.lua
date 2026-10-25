-- Read-only timing probe: how long do the lookups our loops use take on the game thread?
local M = {}
function M.run()
    local out = {}
    for _, cls in ipairs({ "BP_PlayerCharacter_C", "DominionAICharacter", "BP_PlayerController_C" }) do
        local t = os.clock()
        local n = #(FindAllOf(cls) or {})
        out[cls] = { ms = math.floor((os.clock() - t) * 1000 + 0.5), count = n }
    end
    return out
end
return M
