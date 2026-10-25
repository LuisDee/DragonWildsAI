-- Players and creatures within 300 m (client_mod/scripts/sense.lua).
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local c = S.census(log, { radius_m = 300, max = 8, kinds = { players = true, creatures = true, interactables = true } })
    return { players = c.players, creatures = c.creatures, interactables = c.interactables, totals = c.totals, ms = c.ms }
end
