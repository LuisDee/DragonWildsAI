-- Status of the stay-fed reflex (inventory.lua), read-only.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.reflex_status()
end
