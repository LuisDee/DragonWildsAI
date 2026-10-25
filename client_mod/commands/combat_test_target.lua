-- LIVE TEST (needs main's clearance): commanded attack on one specific creature id (edit TARGET).
-- force=true skips the fight-or-flight veto (supervised: stop with combat_stop). Lock-on off.
local TARGET = "BP_AI_RuntGoblin_Character_C_2147463004"
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    C.cfg.lock_on = false
    C.cfg.loot = true
    -- a stand-in "task" (no movement) so the fight has something to suspend and resume
    local A = assert(loadfile("C:/gameserver/client_mod/scripts/arbiter.lua"))()
    _G.DWCombatTestResumed = nil
    local t = A.request(log, { name = "test_task", level = "task", uses_move = false,
        on_resume = function() _G.DWCombatTestResumed = os.date("!%H:%M:%S"); return true end })
    local r = C.attack(log, TARGET, { force = false })
    r.task = t
    return r
end
