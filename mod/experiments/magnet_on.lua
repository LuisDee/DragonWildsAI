-- Arm the bot item magnet (body/magnet.lua) live without a restart.
-- debug_run {module="magnet_on", args={action="start"|"stop"|"status"}}
local M = {}

function M.run(log, args)
    local magnet = require("body.magnet")
    local inv = require("body.inventory")
    local a = args.action or "start"
    if a == "stop" then return magnet.stop() end
    if a == "status" then return magnet.status() end
    return magnet.start(log, inv)
end

return M
