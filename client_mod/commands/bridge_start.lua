-- (Re)start the brain bridge from the newest client_mod/scripts/client_bridge.lua, without a client
-- restart. Keeps the chat hooks (chat.start is idempotent).
-- BUGS L20: never while the running bridge has work in flight (an action in the slot, waiting
-- confirmations, unread brain/debug commands): it waits up to 5 s for idle, else REFUSES with the reason.
-- Emergency: put `FORCE = true` before this file's `return` (or run bridge_start_force.lua).
-- The new instance takes over the old read positions, so nothing written meanwhile is lost.
-- Answers {ok, started | deferred (+why) , status}; a refusal is logged ("restart REFUSED") and in
-- bridge_status.last_restart.
return function(log)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local B = assert(loadfile(root .. "/client_mod/scripts/client_bridge.lua"))()
    local try_once = type(ARGS) == "table" and ARGS.try_once == true
    return B.restart_when_idle({ root = root, log = log, start_modules = true, immediate_only = try_once,
                                 force = not try_once and rawget(_G, "FORCE") == true })
end
