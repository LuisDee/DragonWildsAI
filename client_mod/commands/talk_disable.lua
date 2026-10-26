-- Turns the dev-only talk opt-in off again (after P2). Takes effect at the next bridge_start.
return function(log)
    _G.DW_ENABLE_TALK = nil
    return { ok = true, DW_ENABLE_TALK = false, note = "now run bridge_start.lua" }
end
