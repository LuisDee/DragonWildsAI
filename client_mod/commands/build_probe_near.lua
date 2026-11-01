-- READ-ONLY probe (2026-11-01 step 3): every actor within R metres of a point (default: me), class + name + position,
-- to find what a built piece is on the client when get_state.structures can't see it. Prefix:
-- `local AT = {x, y, z}` (metres), `local R = 6`.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s and s.U
    local pawn = s.local_pawn()
    local at = rawget(_G, "AT") or AT
    if not at then local l = U.loc(pawn); at = l and { l.X / 100, l.Y / 100, l.Z / 100 } end
    local r = rawget(_G, "R") or R or 6
    local out, n = {}, 0
    local t0 = os.clock()
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        n = n + 1
        local l = U.loc(a)
        if l then
            local d = math.sqrt((l.X / 100 - at[1]) ^ 2 + (l.Y / 100 - at[2]) ^ 2 + (l.Z / 100 - at[3]) ^ 2)
            if d <= r and #out < 40 then
                out[#out + 1] = { d = math.floor(d * 100 + 0.5) / 100, class = U.short(U.try(function() return a:GetClass() end)),
                                  name = U.short(a), at = { l.X / 100, l.Y / 100, l.Z / 100 } }
            end
        end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return { ok = true, at = at, r = r, scanned = n, ms = math.floor((os.clock() - t0) * 1000), near = out }
end
