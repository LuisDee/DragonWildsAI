-- Traversal recorder status (scripts/traverse_learn.lua), read-only: trackers, counts, links.
return function(log)
    local L = assert(loadfile("C:/gameserver/client_mod/scripts/traverse_learn.lua"))()
    return L.status()
end
