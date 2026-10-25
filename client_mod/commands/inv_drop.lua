-- Drop one item on the ground via the inventory UI's drop (edit WHAT / COUNT; inventory.lua).
local WHAT, COUNT = "Bone Dagger", 1
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.drop(log, WHAT, COUNT)
end
