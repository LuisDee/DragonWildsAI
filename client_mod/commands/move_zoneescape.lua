-- Live check of M.escape_zones (velgar.md 3c), dev world only: a 3 m circle zone centred 0.5 m in
-- front of Claude for 20 s, then escape_zones{time_s=2}. Expect ok, an exit ~3 m behind him, a sprint
-- out, status().result.out_of_zones. Clears the zones afterwards with move_zoneclear.
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
    local z = M.set_avoid_zones(log, { { id = "zt_here", kind = "circle", x = (p.X + hx * 50) / 100, y = (p.Y + hy * 50) / 100,
        z = (p.Z - 90) / 100, r_cm = 300, until_s = t + 20 } })
    if not z.ok then return z end
    return M.escape_zones(log, { time_s = 2 })
end
