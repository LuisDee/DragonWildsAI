-- Register the bot's display name under each connected player's account (verified for Luis,
-- 2026-10-25: the line showed as "Claude"; Luis's GUID restore checked). Logic: body/speech.lua.
-- debug_run {module="name_register", args={name="Claude", force=true}}. Server-side only.
local speech = require("body.speech")

local M = {}

function M.run(log, args)
    args = args or {}
    return speech.register_names(log, args.name, { force = args.force ~= false })
end

return M
