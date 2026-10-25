-- READ-ONLY: what the combat module sees right now (nearby creatures as threats, own state, held
-- weapon, best weapon pick vs the nearest creature). No input, no movement.
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local pc = C.local_pc()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local me = C.read_me(pawn, pc); me.pos = nil
    local cr = C.creatures_near(C.U.loc(pawn), 40)
    table.sort(cr, function(a, b) return (a.distance_m or 0) < (b.distance_m or 0) end)
    local list = {}
    for i = 1, math.min(6, #cr) do local c = cr[i]; c.actor, c.pos = nil, nil; list[#list + 1] = c end
    local pick = C.best_weapon(I.list(log), cr[1] or {}, nil, C._state().learned)
    local st = C._state()
    return { me = me, creatures = list, held = I.held(pawn),
             best = pick.weapon and { item = pick.weapon.entry.item, score = pick.weapon.score } or nil,
             shield = pick.shield and pick.shield.entry.item or nil,
             threats = #C.pick_threats(cr, st.attackers, st.ally_attackers, C.orders, C.now(pawn)) }
end
