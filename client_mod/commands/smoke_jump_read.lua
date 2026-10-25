-- Smoke test: the jump samples smoke_jump.lua recorded (read-only).
return function(log)
    return _G.DW_SMOKE_JUMP or { done = false, missing = true }
end
