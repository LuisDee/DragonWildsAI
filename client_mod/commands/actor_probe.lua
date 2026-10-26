-- Read-only: does spells' W.actor_thing find a given actor id (live check of the census-less fallback)?
local ID = ""
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    local api = inst and inst.module and inst.module.API
    local SP = api and api.module("spells")
    if not SP then return { ok = false, err = "no spells module" } end
    local ok, t = pcall(SP.W.actor_thing, api, ID, nil)
    return { ok = true, pcall_ok = ok, thing = t }
end
