-- Sleep the bot in a specific bed/shelter directly (no walking): find the BedComponent owned by the
-- target actor, CanSleep(puppet) -> Sleep(puppet). debug_run {module="bed_direct", args={target=<actor id>, action="sleep"|"stop"}}
local U = require("body.util")
local M = {}

function M.run(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not U.alive(p) then return { ok = false, error = "no bot" } end
    local comp
    for _, b in ipairs(U.find_all("BedComponent")) do
        local owner = U.try(function() return b:GetOwner() end)
        if U.valid(owner) and U.short(owner) == args.target then comp = b; break end
    end
    if not comp then return { ok = false, error = "no BedComponent on " .. tostring(args.target) } end
    if args.action == "stop" then
        local ok = U.call(log, "bed_direct.StopSleeping", {}, function() comp:StopSleeping(p) end)
        return { stopped = ok }
    end
    local can = U.try(function() return comp:CanSleep(p) end)
    local ok, err = U.call(log, "bed_direct.Sleep", { target = args.target, can = tostring(can) }, function() comp:Sleep(p) end)
    local rc = U.try(function() return p.PlayerRestComponent end)
    return { can_sleep = tostring(can), sleep_called = ok, err = err and tostring(err),
             rest_is_sleeping = U.try(function() return rc.IsSleeping end),
             resting_area = U.fullname(U.try(function() return rc.CurrentRestingAreaActor end)) }
end

return M
