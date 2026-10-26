-- DEV-ONLY repro (BUGS L38): drink ONE Dirty Water through the normal use path (inventory.lua M.use:
-- hotbar key, else the inventory UI use), bypassing the crash_refusal guard in THIS module instance only.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    I.crash_refusal = function() return nil end
    return I.use(log, "ITEM_Consumable_Water_Dirty", { require = "drink" })
end
