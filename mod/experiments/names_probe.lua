-- Read-only: dump the game's character display-name registry (GameState.DisplayNameComponent).
-- debug_run {module="names_probe"}. Server-side reads only; nothing is sent to clients.
-- Logic: body/speech.lua M.names().
local speech = require("body.speech")

local M = {}

function M.run() return speech.names() end

return M
