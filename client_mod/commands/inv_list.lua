-- Claude's real inventory, loadout and held items (inventory.lua), plus the current interact target.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local l = I.list(log)
    l.target = I.interact_target()
    return l
end
