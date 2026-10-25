-- Chat relay experiment 2 (verified 2026-10-25): "!as <words>" makes the bot say <words>, shown
-- as "Claude". Registers the bot's display name under every connected player's account (the
-- verified swap-and-restore in body/speech.lua register_names), then arms the relay.
-- debug_run {module="chat_as", args={name="Claude"}}
local speech = require("body.speech")

local M = {}

function M.run(log, args)
    args = args or {}
    local reg = speech.register_names(log, args.name, { force = args.force })
    local armed = speech.arm_relay(log, { triggers = true })
    return { names = reg, relay = armed }
end

return M
