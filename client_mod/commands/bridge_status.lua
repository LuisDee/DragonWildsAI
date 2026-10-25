-- Read-only: the running brain bridge's status (or "not running").
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst then return { running = false } end
    return inst.status()
end
