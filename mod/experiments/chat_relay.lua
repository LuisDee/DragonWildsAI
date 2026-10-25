-- Chat relay experiment 1 (verified 2026-10-25): "!echo <words>" re-sends "[Claude] <words>"
-- through the server's own Server_SendChatMessage, under the sender's own name.
-- The relay lives in body/speech.lua; this arms it (once per server run) with the debug triggers.
-- debug_run {module="chat_relay"}
local speech = require("body.speech")

local M = {}

function M.run(log)
    return speech.arm_relay(log, { triggers = true })
end

return M
