-- Hot-load client_mod/scripts/chat.lua and install the chat receive hooks (idempotent; re-running
-- swaps in the newest handler code). Lines go to client_io/events/chat.jsonl.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/chat.lua"))()
    return M.start(log)
end
