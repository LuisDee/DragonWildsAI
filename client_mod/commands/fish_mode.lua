-- Set fishing.lua's live pull_mode on the bridge's module instance (live tuning). Edit MODE before queueing.
local MODE = "none"
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    local api = inst and inst.module and inst.module.API
    local f = api and api.module("fishing")
    if not f then return { ok = false, err = "no fishing module" } end
    f.cfg.pull_mode = MODE
    return { ok = true, pull_mode = f.cfg.pull_mode }
end
