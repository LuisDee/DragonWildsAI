-- Stop the current fight (if any) and the combat reflex loop. Hooks stay registered (read-only).
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local r = C.stop(log, "combat_stop command")
    local g = C.guard_stop(log)
    return { fight = r, guard = g }
end
