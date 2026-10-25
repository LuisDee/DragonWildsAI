-- Census of what Claude's client perceives within 40 m, plus his own state (client_mod/scripts/sense.lua).
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    return { me = S.me(log), census = S.census(log, { radius_m = 40, max = 12 }) }
end
