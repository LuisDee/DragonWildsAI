-- Equip an item by name from Claude's own inventory (edit WHAT before running; inventory.lua).
local WHAT = "Mithril Logging Axe"
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    return I.equip(log, WHAT)
end
