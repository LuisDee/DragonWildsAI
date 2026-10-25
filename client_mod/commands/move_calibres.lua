-- Read-only: result of the last move_calib.lua run.
return function(log) return _G.DW_CALIB or { state = "none" } end
