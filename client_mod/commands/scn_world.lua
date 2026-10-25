-- Scenario suite (tools/scenario_run.py --memory): which world's NAV MEMORY / traversal store the client uses.
-- traverse_learn.world_id() honours _G.DW_WORLD_GUID first, and move.lua reloads its memory when the id changes,
-- so a scenario run on the dev server can learn into its own store (data/skills/<id>/) instead of Shockbyte's
-- (the fallback id is "shockbyte" on every server). Map seeds (data/nav/L_World_seeds.json) still load.
-- Runner args (`local ARGS = {...}` prefixed): set = "<id>" | restore = true (+ previous = "<id>" or absent).
-- Returns {ok, previous, now}.
return function(log)
    local A = (type(ARGS) == "table" and ARGS) or {}
    local prev = rawget(_G, "DW_WORLD_GUID")
    if A.set then
        assert(tostring(A.set):match("^[%w_%-]+$"), "bad world id")
        _G.DW_WORLD_GUID = tostring(A.set)
    elseif A.restore then
        _G.DW_WORLD_GUID = A.previous   -- nil when there was no override before the run
    end
    return { ok = true, previous = prev, now = rawget(_G, "DW_WORLD_GUID") }
end
