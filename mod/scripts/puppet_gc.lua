-- Force a garbage collection (KismetSystemLibrary.CollectGarbage queues "obj gc" for the next tick)
-- to check that removed puppets are purged without a dangling-reference crash.
local M = {}
function M.run(log, args)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local ok, err = pcall(function() ksl:CollectGarbage() end)
    log.event("force_gc", { ok = ok, err = (not ok) and tostring(err) or nil })
    return { ok = ok, err = (not ok) and tostring(err) or nil }
end
return M
