-- Dev-server creature reads + cleanup for LIVE CHECKS (tools/live_checks/*.json `server` steps). NOT a judge file:
-- it never sets a case up; it only reads what the bench spawn fixture produced and removes it afterwards, so the
-- dev character is never left next to a spawned PL 3 wolf.
--
--   debug_run {module="bench_creatures", args={action="read", character_guid=..., radius_m=40}}
--       READ-ONLY. Every DominionAICharacter within radius_m of the character: id (U.short, the same id the spawn
--       fixture returns), class word, the class's full object path (GetClass():GetFullName(), what spawn_classes.json
--       needs), PowerLevel (property), GetAIPowerLevel(), GetDamageLevelMultiplier(), health / max health, dead,
--       bSpawnedByAiDirector, distance. `ids` (optional) restricts the rows to those actors.
--   debug_run {module="bench_creatures", args={action="kill", character_guid=..., ids={...}}}
--       CLEANUP of the named actors ONLY (the ids the spawn fixture returned in this check): the game's own health
--       path, HealthComponent:DecreaseHealth(current + 1, "live_check_cleanup"), so the creature dies normally (no
--       destroy/unpossess of an AI-possessed pawn: DISCOVERIES "unpossess" crash class). Refuses director-spawned
--       creatures and anything that is not a DominionAICharacter.
--
--   debug_run {module="bench_creatures", args={action="regions", character_guid=...}}
--       READ-ONLY. Map regions (name, PowerLevel, centre) and lodestone arrival points with their region.
--
-- Guards (same as mod/bench/fixtures.lua): DW_SERVER_ROLE=dev; the character is addressed by GUID; refuses when any
-- other player is connected.
local root = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]experiments[/\\][^/\\]*$")) or "."
local U = assert(loadfile(root .. "/body/util.lua"))()
local M = {}

local function guard(args)
    if os.getenv("DW_SERVER_ROLE") ~= "dev" then return "not_dev_server" end
    local guid = tostring(args.character_guid or "")
    if guid == "" then return "no_character_guid" end
    local target, others = nil, {}
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        local ps = U.try(function() return p.PlayerState end)
        local g = ps and U.try(function() return U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid) end)
        if g == guid then target = p else others[#others + 1] = U.player_name(p) end
    end
    if #others > 0 then return "other_players_connected", others end
    if not target then return "character_not_found" end
    return nil, target
end

local function num(v) return type(v) == "number" and v or nil end

local function row(a, here)
    local q = U.loc(a)
    local hc = U.try(function() return a.HealthComponent end)
    local data = U.try(function() return a.LoadedData end)
    local cls = U.class_name(a)
    return {
        id = U.short(a), class = U.class_word(a),
        class_path = cls and (cls:match("^%S+%s+(.*)$") or cls) or nil,
        name = U.valid(data) and U.str(U.try(function() return data.AIName end)) or nil,
        power_level = num(U.try(function() return a.PowerLevel end)),
        ai_power_level = num(U.try(function() return a:GetAIPowerLevel() end)),
        damage_level_multiplier = num(U.try(function() return a:GetDamageLevelMultiplier() end)),
        health = U.valid(hc) and num(U.try(function() return hc:GetAuthoritativeHealth() end)) or nil,
        max_health = U.valid(hc) and num(U.try(function() return hc:GetMaxHealth() end)) or nil,
        dead = U.valid(hc) and U.try(function() return hc:IsDead() end) == true or nil,
        director = U.try(function() return a.bSpawnedByAiDirector end) == true,
        dist_m = (q and here) and math.floor(U.dist(q, here) / 10 + 0.5) / 10 or nil,
    }
end

local function by_ids(ids)
    local want = {}
    for _, id in ipairs(ids or {}) do want[tostring(id)] = true end
    return want
end

function M.run(log, args)
    args = args or {}
    local why, target = guard(args)
    if why then return { ok = false, error = why, detail = target } end
    local here = U.loc(target)
    local action = tostring(args.action or "read")
    if action == "read" then
        local r_cm = (tonumber(args.radius_m) or 40) * 100
        local want = args.ids and by_ids(args.ids) or nil
        local out = {}
        for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
            local id = U.short(a)
            local q = U.loc(a)
            if id and (want and want[id] or (not want and q and here and U.dist(q, here) <= r_cm)) then
                out[#out + 1] = row(a, here)
            end
        end
        table.sort(out, function(x, y) return (x.dist_m or 1e9) < (y.dist_m or 1e9) end)
        -- the map region he stands in (BP_MapRegion_C.PowerLevel, via body/travel.lua's region_at): tells whether a
        -- spawned creature's PowerLevel follows the region or its class
        local region
        pcall(function()
            local T = assert(loadfile(root .. "/body/travel.lua"))()
            local r, parent = T.region_at(here)
            region = r and { name = r.name, power = r.power, parent = parent and parent.name or nil,
                             parent_power = parent and parent.power or nil } or nil
        end)
        return { ok = true, creatures = out, n = #out, first = out[1], region = region }
    end
    if action == "kill" then
        local want = by_ids(args.ids)
        if next(want) == nil then return { ok = false, error = "kill needs ids (the spawn fixture's own ids)" } end
        local res, all_ok = {}, true
        for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
            local id = U.short(a)
            if id and want[id] then
                want[id] = nil
                local r = { id = id }
                local hc = U.try(function() return a.HealthComponent end)
                if U.try(function() return a.bSpawnedByAiDirector end) == true then
                    r.error = "director_spawned"
                elseif not U.valid(hc) then
                    r.error = "no_health_component"
                elseif U.try(function() return hc:IsDead() end) == true then
                    r.ok, r.already_dead = true, true
                else
                    local hp = num(U.try(function() return hc:GetAuthoritativeHealth() end)) or 1e6
                    local ok, err = pcall(function() hc:DecreaseHealth(hp + 1, "live_check_cleanup") end)
                    r.error = (not ok) and tostring(err) or nil
                    r.health_after = num(U.try(function() return hc:GetAuthoritativeHealth() end))
                    r.ok = ok and (U.try(function() return hc:IsDead() end) == true or (r.health_after or 1) <= 0)
                end
                all_ok = all_ok and r.ok == true
                res[#res + 1] = r
            end
        end
        for id in pairs(want) do res[#res + 1] = { id = id, ok = true, gone = true } end  -- not found = already gone
        if log and log.event then log.event("bench_creatures_kill", { results = res }) end
        return { ok = all_ok, results = res }
    end
    if action == "spawn_pl" then
        -- EXPERIMENT (dev only): spawn at a given power level the engine's own deferred way, the same two calls UE4SS's
        -- World:SpawnActor makes internally (docs.ue4ss.com UWorld.SpawnActor): GameplayStatics
        -- BeginDeferredActorSpawnFromClass -> write SpawnInfo.PowerLevel + PowerLevel (scalar int writes) ->
        -- FinishSpawningActor, so BeginPlay sees the level. Live 2026-10-26: a plain SpawnActor is always PL 1, even in a
        -- PL 2 region (pin_pl2_region_spawn). The kill action removes it afterwards.
        local path = tostring(args.class_path or "")
        local cls = U.find_object(path)
        if not U.valid(cls) and type(LoadAsset) == "function" then pcall(LoadAsset, path); cls = U.find_object(path) end
        if not U.valid(cls) then return { ok = false, error = "class_not_loaded", class_path = path } end
        local lib = U.find_object("/Script/Engine.Default__GameplayStatics")
        if not U.valid(lib) then return { ok = false, error = "no_gameplay_statics" } end
        local off = args.offset_m or { 10, 0, 0 }
        local xf = { Translation = { X = here.X + off[1] * 100, Y = here.Y + off[2] * 100, Z = here.Z + (off[3] or 0) * 100 },
                     Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local pl = math.floor(tonumber(args.power_level) or 1)
        local a = U.try(function() return lib:BeginDeferredActorSpawnFromClass(target, cls, xf, 1, nil, 0) end)
        if not U.valid(a) then return { ok = false, error = "begin_deferred_failed" } end
        local w1 = pcall(function() a.SpawnInfo.PowerLevel = pl end)
        local w2 = pcall(function() a.PowerLevel = pl end)
        local fin, ferr = pcall(function() lib:FinishSpawningActor(a, xf, 0) end)
        local r = row(a, here)
        r.spawn_info_power_level = num(U.try(function() return a.SpawnInfo.PowerLevel end))
        return { ok = fin and U.valid(a), error = (not fin) and tostring(ferr) or nil, id = r.id, wrote = { spawn_info = w1, power_level = w2 },
                 want_power_level = pl, creature = r }
    end
    if action == "regions" then  -- READ-ONLY: map regions (name, PowerLevel, centre) + lodestone arrival points
        local T = assert(loadfile(root .. "/body/travel.lua"))()
        local regs, lodes = {}, {}
        for _, r in ipairs(T.regions()) do
            local near, nd = nil, math.huge  -- the region's boundary vertex nearest to him (2-D)
            for _, p in ipairs(r.poly or {}) do
                local d = here and math.sqrt((p[1] - here.X) ^ 2 + (p[2] - here.Y) ^ 2) or math.huge
                if d < nd then near, nd = p, d end
            end
            regs[#regs + 1] = { name = r.name, power = r.power, region_id = r.region_id,
                                center_m = { r.center.X / 100, r.center.Y / 100 }, area_km2 = r.area and r.area / 1e10 or nil,
                                nearest_vertex_m = near and { near[1] / 100, near[2] / 100 } or nil,
                                nearest_m = near and math.floor(nd / 100) or nil }
        end
        local ok, list = pcall(T.list, true)
        for _, l in ipairs(ok and list or {}) do
            local r = T.region_at(l.arrival or l.location)
            local a = l.arrival or l.location
            lodes[#lodes + 1] = { name = l.name, region = r and r.name or nil, power = r and r.power or nil,
                                  arrival_m = { a.X / 100, a.Y / 100, a.Z / 100 },
                                  dist_m = here and math.floor(U.dist(here, a) / 100) or nil }
        end
        table.sort(lodes, function(x, y) return (x.dist_m or 1e12) < (y.dist_m or 1e12) end)
        local mine = T.region_at(here)
        return { ok = true, regions = regs, lodestones = lodes, list_error = (not ok) and tostring(list) or nil,
                 here = mine and { name = mine.name, power = mine.power } or nil }
    end
    return { ok = false, error = "action must be read, kill or regions" }
end

return M
