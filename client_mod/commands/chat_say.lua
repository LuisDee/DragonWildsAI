-- Say one line in chat through the chat box's own commit path (client_mod/scripts/chat.lua).
-- Edit TEXT, or copy this file with another text. Keep chat traffic minimal (real group world).
local TEXT = "Claude here - chat test"
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/chat.lua"))()
    M.start(log)
    return M.say(log, TEXT)
end
