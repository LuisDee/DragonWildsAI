-- Claude's own state (sense.lua me): position, health, stamina, survival, skills.
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local m = S.me(log); m.skills = nil
    return m
end
