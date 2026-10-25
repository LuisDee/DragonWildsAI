-- Stop the traversal recorder (scripts/traverse_learn.lua) and flush the link store.
return function(log)
    local L = assert(loadfile("C:/gameserver/client_mod/scripts/traverse_learn.lua"))()
    return L.stop(log)
end
