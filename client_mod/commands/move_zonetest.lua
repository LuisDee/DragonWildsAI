-- Live check of avoid zones (scripts/move.lua M.set_avoid_zones; velgar.md 3c), dev world only:
-- a 2.5 m circle zone 6 m ahead of Claude for 40 s, then go_to 12 m ahead. Expect: a local plan
-- "(avoid_zone zt_ahead)" in the log, a path round the zone, arrival; status().avoid while it runs.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") and x:IsLocalController() then pc = x end
    end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local p, r = pawn:K2_GetActorLocation(), pawn:K2_GetActorRotation()
    local hx, hy = math.cos(math.rad(r.Yaw)), math.sin(math.rad(r.Yaw))
    local t = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetRealTimeSeconds(pawn)
    local z = M.set_avoid_zones(log, { { id = "zt_ahead", kind = "circle", x = (p.X + hx * 600) / 100, y = (p.Y + hy * 600) / 100,
        z = (p.Z - 90) / 100, r_cm = 250, until_s = t + 40 } })
    if not z.ok then return z end
    local g = M.go_to(log, { (p.X + hx * 1200) / 100, (p.Y + hy * 1200) / 100, p.Z / 100 }, { tolerance_m = 1.5, timeout_s = 40 })
    return { ok = g.ok, zones = z, go_to = g }
end
