-- Read-only probe of the census "near" anchor with Claude HIMSELF as the anchor (no other player online):
-- mapplayers.pawn_of never returns my own pawn, so this probe overrides it on its own sense instance only.
-- Also the failure path for a name nobody has, and the map_players rows. Property reads only.
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local out = {}
    local plain = S.census(log, { radius_m = 15, max = 8, lean = true, kinds = { items = true, resources = true } })
    out.plain = { ms = plain.ms, totals = plain.totals, first = (plain.resources or {})[1] or (plain.items or {})[1] }
    out.nobody = S.census(log, { near = "NoSuchPlayer", radius_m = 15, kinds = { items = true, resources = true } })
    local MAP = S.mapplayers()
    local real = MAP.pawn_of
    MAP.pawn_of = function() return S.local_pawn(), "ClaudeDev" end
    local ok, a = pcall(S.census, log, { near = "ClaudeDev", radius_m = 15, max = 8, lean = true,
                                         kinds = { items = true, resources = true } })
    MAP.pawn_of = real
    if not ok then out.anchored_error = tostring(a); return out end
    local rows = {}
    for _, cat in ipairs({ "items", "resources" }) do
        for i, t in ipairs(a[cat] or {}) do
            if i <= 4 then rows[#rows + 1] = { cat = cat, name = t.name, id = t.id, distance = t.distance,
                                               from_me = t.from_me, side = t.side } end
        end
    end
    out.anchored = { ok = a.ok, near = a.near, from = a.from, ms = a.ms, totals = a.totals, rows = rows }
    local pl = S.census(log, { radius_m = 60, kinds = { players = true } })
    out.players = { players = pl.players, map_players = pl.map_players, totals = pl.totals }
    return out
end
