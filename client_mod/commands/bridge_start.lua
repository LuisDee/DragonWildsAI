-- (Re)start the brain bridge from the newest client_mod/scripts/client_bridge.lua, without a client
-- restart. Stops the running instance first (its loop), keeps the chat hooks (chat.start is idempotent).
-- Answers the bridge status: dir, file offsets, implemented tools, module load errors.
return function(log)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local B = assert(loadfile(root .. "/client_mod/scripts/client_bridge.lua"))()
    return B.start({ root = root, log = log, start_modules = true })
end
