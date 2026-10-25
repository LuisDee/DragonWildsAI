-- EMERGENCY bridge restart: drops whatever is in flight (BUGS L20). Prefer bridge_start.lua.
return function(log)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local B = assert(loadfile(root .. "/client_mod/scripts/client_bridge.lua"))()
    return B.restart_when_idle({ root = root, log = log, start_modules = true, force = true })
end
