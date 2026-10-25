-- LIVE (needs clearance): use one of the held item's actions once. Edit STYLE.
local STYLE = "Overhead Chop"
return function(log)
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/combat.lua"))()
    local r = C.use_action(log, STYLE, {})
    if r.pending then r.pending = { started = true } end
    return r
end
