-- Smoke test (only with client_smoke.ps1 -Chat): one line in the real chat, through chat.lua say.
-- It is a shared world: keep it to this one short line.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/chat.lua"))()
    M.start(log)
    return M.say(log, "Claude: smoke test, please ignore")
end
