-- Dev-only opt-in for talk.lua (review v3: GO for P2 on dev, ClaudeDev). Takes effect at the next bridge_start.
return function(log)
    _G.DW_ENABLE_TALK = true
    return { ok = true, DW_ENABLE_TALK = true, note = "now run bridge_start.lua" }
end
