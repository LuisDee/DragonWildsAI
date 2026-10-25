-- Arm body/sleep.lua in a RUNNING server without a restart (it was not loaded at startup before
-- main.lua wired it): registers its bridge handlers (sleep, wake, sleep_status, night_skip) on the live
-- bridge and starts its 1 s reflex loop (sleep when Luis sleeps, wake when he wakes).
--   debug_run {"module":"sleep_arm","args":{"reflex":"auto"}}      arm (reflex auto|bed|flag|off)
--   debug_run {"module":"sleep_arm","args":{"action":"disarm"}}    stop the reflex loop, drop handlers
--   debug_run {"module":"sleep_arm","args":{"action":"status"}}
-- Acts on the puppet only. Once main.lua registers body/sleep.lua at startup this is not needed.
local M = {}

function M.run(log, args)
    args = args or {}
    local ok_s, sleep = pcall(require, "body.sleep")
    if not ok_s then return { ok = false, error = tostring(sleep) } end
    local bridge = require("bridge")
    local action = args.action or "arm"
    if action == "status" then return { ok = true, armed = rawget(_G, "__dw_sleep_armed") == true, status = sleep.status() } end
    if action == "disarm" then
        sleep._reset()
        for name in pairs(sleep.HANDLERS) do bridge.handlers[name] = nil end
        rawset(_G, "__dw_sleep_armed", false)
        return { ok = true, armed = false }
    end
    if action ~= "arm" then return { ok = false, error = "action is arm, disarm or status" } end
    if rawget(_G, "__dw_sleep_armed") then sleep._reset() end -- re-arm with new options
    sleep.register(bridge, log, { reflex = args.reflex or "auto", night_skip = args.night_skip,
                                  no_loop = args.no_loop == true })
    rawset(_G, "__dw_sleep_armed", true)
    return { ok = true, armed = true, status = sleep.status() }
end

return M
