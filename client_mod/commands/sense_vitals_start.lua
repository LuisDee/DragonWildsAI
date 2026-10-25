-- Start the vitals watcher (sense.lua): health/damage/fatal/survival -> client_io/events/vitals.jsonl.
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local r = S.vitals_start(log)
    r.me = S.me(log)
    r.levels = S.survival_levels()
    return r
end
