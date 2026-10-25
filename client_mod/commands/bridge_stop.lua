-- Stop the brain bridge loop (the brain then times out). bridge_start.lua starts it again.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst then return { running = false } end
    inst.stop()
    _G.__dwc_bridge = nil
    return { stopped = true }
end
