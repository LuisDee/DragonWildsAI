-- Read-only: which trace preset move.lua validated on this client run.
return function(log) return { trace_profile = rawget(_G, "DW_TRACE_PROFILE"), move_mode = _G.DW_MOVE and _G.DW_MOVE.mode } end
