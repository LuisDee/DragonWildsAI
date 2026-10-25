-- Arm the "stay fed and watered" reflex (inventory.lua): a game-thread loop, returns at once.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.reflex_start(log)
end
