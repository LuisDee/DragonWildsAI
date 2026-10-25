-- LIVE TEST (needs main's clearance): commanded attack on the nearest live Kebbit within 30 m
-- (passive/neutral, power level 1). Returns at once; poll combat_status. Never targets players.
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    -- per-run knobs (this instance's cfg drives the fight it starts)
    C.cfg.lock_on = (os.getenv("DW_COMBAT_LOCKON") == "1")
    C.cfg.loot = true
    local pc = C.local_pc()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local best
    for _, c in ipairs(C.creatures_near(C.U.loc(pawn), 30)) do
        if c.name == "Kebbit" and not c.dead and (c.pl or 1) <= 1 and (not best or c.distance_m < best.distance_m) then best = c end
    end
    if not best then return { ok = false, reason = "no Kebbit within 30 m" } end
    return C.attack(log, best.id, {})
end
