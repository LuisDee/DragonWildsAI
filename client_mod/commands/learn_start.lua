-- Start the READ-ONLY traversal recorder (scripts/traverse_learn.lua, task R2.12): watches other
-- players' jumps/drops/double jumps/Windstep and Claude's own crossings; learned links go to
-- data/skills/<world>/traversal_links.json, raw events to logs/state/worlds/<world>/traversal_events.jsonl.
-- Never moves the pawn or presses input. Idempotent (re-running hot-swaps the newest code).
return function(log)
    local L = assert(loadfile("C:/gameserver/client_mod/scripts/traverse_learn.lua"))()
    return L.start(log, {})
end
