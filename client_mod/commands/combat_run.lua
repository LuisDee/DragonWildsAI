-- LIVE TEST (needs main's clearance): commanded fight with a chosen policy against the nearest LONE
-- weak hostile (power level <= 1, no other hostile within 25 m of it), or TARGET if set.
-- Edit ORDERS / TARGET per run. Returns at once; poll combat_status.
local ORDERS = { defense = "auto", heal_hp = 0.5, reengage_hp = 0.8, disengage = true, allow_jump = true }
local TARGET = nil
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    C.cfg.lock_on = false
    C.set_orders(ORDERS)
    local pc = C.local_pc()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, reason = "no pawn" } end
    local list = C.creatures_near(C.U.loc(pawn), 60)
    local best
    if TARGET then best = { id = TARGET } else
        for _, c in ipairs(list) do
            if not c.dead and c.archetype == 0 and (c.pl or 1) <= 1 then
                local lone = true
                for _, o in ipairs(list) do
                    if o.id ~= c.id and not o.dead and o.archetype == 0 and c.pos and o.pos and C.U.dist(c.pos, o.pos) < 2500 then lone = false end
                end
                if lone and (not best or c.distance_m < best.distance_m) then best = c end
            end
        end
    end
    if not best then return { ok = false, reason = "no lone weak hostile within 60 m", seen = #list } end
    local r = C.attack(log, best.id, { force = false })
    r.orders = C.orders
    return r
end
