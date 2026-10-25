-- Drink the first drink and eat the first food in Claude's inventory via the game's use path (inventory.lua).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local l = I.list(log)
    local out = {}
    for _, kind in ipairs({ "drink", "food" }) do
        for _, where in ipairs({ "hotbar", "bag" }) do
            for _, d in ipairs(l[where] or {}) do
                if d.consumable == kind and not out[kind] then out[kind] = I.use(log, d.item) end
            end
        end
    end
    return out
end
