-- Read-only: is farm growth on the game clock? The InGameTimeActor's day length / dawn / dusk / paused flag, the full
-- in-game time (days included), what 720 real seconds (FarmingSettings.CyclePeriod) is in game time, and per farm
-- plot within 150 m: the plant mesh (the stage's mesh: a growth-stage proxy), soil, harvestable, growth lock.
-- No writes, no RPCs. Output: client_io/out/farm_time_probe.json.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
local function ticks(ts) local t = ts and U.try(function() return ts.Ticks end); return type(t) == "number" and t or nil end
return function(log)
    local pc
    local okp, pcs = pcall(FindAllOf, "BP_PlayerController_C")
    for _, c in ipairs(okp and pcs or {}) do if U.try(function() return c:IsLocalController() end) then pc = c end end
    local pawn = U.valid(pc) and U.try(function() return pc.Pawn end) or nil
    local out = { clock = {}, plots = {}, now_os = os.time() }
    local okt, ta = pcall(FindAllOf, "InGameTimeActor")
    for _, a in ipairs(okt and ta or {}) do
        local n = U.fullname(a) or ""
        if not n:find("Default__", 1, true) then
            out.clock[#out.clock + 1] = { actor = U.short(a), class = U.class_word(a),
                real_min_per_day = U.try(function() return a.RealTimeMinutesPerInGameDay end),
                dawn = U.try(function() return a.TimeOfDawn end), dusk = U.try(function() return a.TimeOfDusk end),
                paused = U.try(function() return a.bIsTimePaused end), stored = U.try(function() return a.StoredTime end),
                last_sync = U.try(function() return a.LastSyncTime end), initial_ticks = ticks(U.try(function() return a.InitialTime end)),
                game_ticks = ticks(U.try(function() return a:GetInGameTime() end)) }
        end
    end
    local lib = U.try(StaticFindObject, "/Script/Dominion.Default__InGameTimeFunctionLibrary")
    local ctx = pawn or pc
    if U.valid(lib) and ctx then
        local t = ticks(U.try(function() return lib:GetInGameTime(ctx) end))
        out.game_ticks = t
        if t then out.game_days = t / 8.64e11; out.game_hour = (t / 3.6e10) % 24 end
        out.night = U.try(function() return lib:IsNighttime(ctx) end)
        out.dawn = U.try(function() return lib:GetTimeOfDawn(ctx) end)
        out.dusk = U.try(function() return lib:GetTimeOfDusk(ctx) end)
        local c = ticks(U.try(function() return lib:ConvertRealTimeSecondsToInGameTime(ctx, 720) end))
        out.cycle720_game_hours = c and c / 3.6e10 or nil
        local nd = ticks(U.try(function() return lib:GetTimeOfNextDawn(ctx) end))
        out.next_dawn_hours_from_epoch = nd and nd / 3.6e10 or nil
    end
    local me = U.valid(pawn) and U.loc(pawn) or nil
    local ok, list = pcall(FindAllOf, "FarmSlotComponent")
    for _, c in ipairs(ok and list or {}) do
        local owner = U.try(function() return c:GetOwner() end)
        if U.alive(owner) then
            local v = U.try(function() return c:K2_GetComponentLocation() end)
            local d = (me and v) and math.floor(math.sqrt((me.X - v.X) ^ 2 + (me.Y - v.Y) ^ 2) / 10 + 0.5) / 10 or nil
            if d == nil or d <= 150 then
                local pm = U.try(function() return c.PlantMeshComponent end)
                local mesh = U.valid(pm) and U.fullname(U.try(function() return pm:GetStaticMesh() end) or U.try(function() return pm.StaticMesh end)) or nil
                local inst = U.valid(pm) and U.try(function() return pm:GetInstanceCount() end) or nil
                out.plots[#out.plots + 1] = { owner = U.short(owner), distance_m = d, plot_id = tostring(U.try(function() return c:GetPlotID() end)),
                    soil = U.try(function() return c:GetSoilState() end), harvestable = U.try(function() return c:CanHarvest() end),
                    watered = U.try(function() return c:IsFullyWatered() end), growth_lock = U.try(function() return c:ShouldVisualizeGrowthLock() end),
                    mesh = mesh, instances = inst }
            end
        end
    end
    return { ok = true, r = out }
end
