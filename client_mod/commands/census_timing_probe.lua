-- Read-only: how long a full census and an items+resources census take on Claude's client (ms).
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local a = S.census(log, { radius_m = 50, max = 20 })
    local b = S.census(log, { radius_m = 15, max = 8, kinds = { items = true, resources = true } })
    return { full_ms = a.ms, full_totals = a.totals, ir_ms = b.ms, ir_totals = b.totals }
end
