-- Combat state: current fight (phase, target, presses, verified hits), last result, guard, counts,
-- learned weaknesses, recent log lines; plus the arbiter's owner and suspended stack. Read-only.
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local A = assert(loadfile("C:/gameserver/client_mod/scripts/arbiter.lua"))()
    local s = C.status()
    s.arbiter = A.status()
    s.arbiter.history = nil
    return s
end
