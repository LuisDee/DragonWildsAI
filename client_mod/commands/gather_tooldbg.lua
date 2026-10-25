-- READ-ONLY: why did gather find no tool? inventory rows + weapons_data lookups.
return function(log)
    local G = assert(loadfile("C:/gameserver/client_mod/scripts/gather.lua"))()
    local inv = G.mod("inventory")
    local cb = G.mod("combat")
    local l = inv and inv.list(log) or {}
    local w = cb and cb.weapons and cb.weapons() or {}
    local rows = {}
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs(l[where] or {}) do
            local p = (w.items or {})[e.item or ""]
            rows[#rows + 1] = { where, e.item, e.name, p and p.cat, p and p.tier, e.broken }
        end
    end
    return { combat = cb ~= nil, weapons = w.items ~= nil, rows = rows, held = l.held, empty = l.empty_slots }
end
