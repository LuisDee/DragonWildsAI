-- Start the combat reflex (combat.lua guard: threat watch -> fight or flee, at arbiter level "reflex")
-- and its damage/telegraph hooks. Idempotent. Edit `opts`/`orders` below for a run.
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local orders = { stance = "defensive" }
    C.set_orders(orders)
    return C.guard_start(log, {})
end
