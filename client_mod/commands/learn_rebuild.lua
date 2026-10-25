-- Re-cluster the current world's link store from its raw events (scripts/traverse_learn.lua rebuild;
-- keeps 'forgotten' flags). Use after classifier changes or a hand repair of traversal_events.jsonl.
return function(log)
    local L = assert(loadfile("C:/gameserver/client_mod/scripts/traverse_learn.lua"))()
    return L.rebuild(log)
end
