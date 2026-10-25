-- Unequip a loadout slot (edit SLOT: "HeldRight", "Head", ...) through the game's own path (inventory.lua).
local SLOT = "HeldRight"
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.unequip(log, SLOT)
end
