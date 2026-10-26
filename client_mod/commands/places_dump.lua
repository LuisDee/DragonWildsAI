-- places_dump: READ-ONLY dump of the game's map regions (boundary polygons), landmarks (named map points: NPCs,
-- shrines, courses ...) and the region the game says he is in (client_mod/scripts/places.lua; BUGS A5).
-- Writes the full dump to logs/places_raw_latest.json (+ a timestamped copy) for tools/build_places.py, and
-- returns a summary (the live queue keeps only short replies). Property reads and spline getters only.
-- Runner args (optional): none.
return function(log)
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, error = "paused" } end
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local P = assert(loadfile(root .. "/client_mod/scripts/places.lua"))()
    local J = assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))()
    local ok, all = pcall(P.read_all)
    if not ok then return { ok = false, error = "read_failed", detail = tostring(all) } end
    local dir = root .. "/logs" -- exists on every install; no mkdir (L28: no process spawns on the game thread)
    all.wall = os.time()
    local body = J.encode(all)
    local written = {}
    for _, name in ipairs({ "places_raw_latest.json", "places_raw_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".json" }) do
        local f = io.open(dir .. "/" .. name, "wb")
        if f then f:write(body); f:close(); written[#written + 1] = name end
    end
    local with_poly, named = 0, 0
    for _, r in ipairs(all.regions) do if #(r.polygon or {}) >= 3 then with_poly = with_poly + 1 end end
    for _, l in ipairs(all.landmarks) do if l.desc and l.desc ~= "" then named = named + 1 end end
    return { ok = #written > 0, regions = #all.regions, regions_with_polygon = with_poly,
             landmarks = #all.landmarks, landmarks_named = named, position = all.me.position,
             game_region = all.me.game_region, computed_region = all.computed_region, agrees = all.agrees,
             written = written }
end
