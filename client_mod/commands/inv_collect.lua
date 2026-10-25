-- Press interact once to collect the dropped world item the game's detector targets (inventory.lua).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.collect(log)
end
