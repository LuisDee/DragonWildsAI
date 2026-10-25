-- World items within 15 m and the players nearby (client_mod/scripts/sense.lua).
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local c = S.census(log, { radius_m = 15, max = 20, kinds = { items = true, players = true } })
    return { items = c.items, players = c.players, online = c.players_online }
end
