-- Press the interact key once on whatever the game's detector targets (inventory.lua).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local t = I.interact_target()
    local r = I.press_interact(log)
    r.target = t
    return r
end
