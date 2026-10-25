-- Vitals watcher status (sense.lua), read-only.
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    return S.vitals_status()
end
