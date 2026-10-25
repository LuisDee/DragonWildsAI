-- Benchmark observer probe (docs/design/eval-benchmark.md §4.1, review finding 1). OWNED BY THE EVAL AGENT; a judge
-- file (frozen at Luis's judge tag). READ-ONLY: property reads and BlueprintPure getters only, the same reads the
-- live-verified snapshots use (DISCOVERIES "Client spells (R2)"); it never presses input, never calls Server_*, never
-- writes. Independent of the skills under test: it uses only mod/body/util.lua (generic plumbing), not spells.lua,
-- sense.lua, inventory.lua or combat.lua, so a generous skill reply can't make a leaf pass (sensor_mismatch).
--
-- Runner args (`local ARGS = {...}` prefixed, all optional): radius_m (spell actors within; default 40).
-- Returns {ok, probe = {t, wall, position, health, max_health, vitals, inventory, tags, ge, cooldowns, skills,
--          actors, gaps}} ; gaps lists fields this probe version can't read yet (they evaluate null, never pass).
return function(log)
    local A = (type(ARGS) == "table" and ARGS) or {}
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, error = "paused" } end
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local U = assert(loadfile(root .. "/mod/body/util.lua"))()
    local function unwrap(e)
        if type(e) == "userdata" then
            local ok, v = pcall(function() return e:get() end)
            if ok and v ~= nil then return v end
        end
        return e
    end
    local function each(arr, fn, cap)
        if arr == nil then return end
        local n = 0
        pcall(function()
            arr:ForEach(function(i, e)
                n = n + 1
                if n > (cap or 256) then return true end
                fn(unwrap(e), i)
            end)
        end)
    end
    local function m(v)
        local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
        if ok and type(x) == "number" then return { x / 100, y / 100, (z or 0) / 100 } end
        return nil
    end
    local pc
    for _, c in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return c:IsLocalController() end) == true then pc = c end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not (U.valid(pc) and U.alive(pawn)) then return { ok = false, error = "no_local_pawn" } end
    local p = { wall = os.time(), inventory = {}, tags = {}, ge = {}, cooldowns = {}, skills = {}, actors = {}, vitals = {},
                gaps = { "held_effects", "ground", "creatures", "players_inventory" } }
    local gst = U.find_object("/Script/Engine.Default__GameplayStatics")
    p.t = gst and U.try(function() return gst:GetTimeSeconds(pawn) end) or p.wall
    p.position = m(U.try(function() return pawn:K2_GetActorLocation() end))
    p.health = U.health(pawn)
    p.max_health = U.try(function() return pawn.HealthComponent:GetMaxHealth() end) or U.max_health(pawn)
    for key, spec in pairs({ sustenance = { "SustenanceComponent", "GetCurrentSustenance" },
                             hydration = { "HydrationComponent", "GetCurrentHydration" } }) do
        local c = U.try(function() return pawn[spec[1]] end)
        if U.valid(c) then p.vitals[key] = U.try(function() return c[spec[2]](c) end) end
    end
    local inv = U.try(function() return pc.InventoryComponent end)
    each(inv and U.try(function() return inv.ItemSlots end), function(it)
        if U.valid(it) then
            local d = U.short(U.try(function() return it.ItemData end))
            if d then p.inventory[d] = (p.inventory[d] or 0) + (U.try(function() return it.Count end) or 1) end
        end
    end, 512)
    local um = U.try(function() return pawn.PlayerUtilityMagicComponent end)
    if U.valid(um) then
        pcall(function() um.LastCastTimeBySpellData:ForEach(function(k, v) p.cooldowns[U.short(unwrap(k)) or "?"] = unwrap(v) end) end)
    end
    local ge = U.try(function() return pawn.GameplayEffectsComponent end)
    if U.valid(ge) then
        for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
            each(U.try(function() return ge[f] end), function(x) if U.valid(x) then p.ge[#p.ge + 1] = U.class_word(x) end end, 64)
        end
        pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) p.tags[#p.tags + 1] = U.str(unwrap(t).TagName) end) end)
    end
    local sk = U.try(function() return pc.SkillComponent end)
    each(sk and U.try(function() return sk.Skills end), function(x)
        local d = U.try(function() return x.SkillData end)
        if U.valid(d) then
            local name = (U.short(d) or "?"):gsub("^SKILL_", "")
            p.skills[name] = { level = U.try(function() return sk:GetSkillLevel(d) end), xp = U.try(function() return x.CurrentXP end) }
        end
    end, 32)
    local here = U.loc(pawn)
    local r_cm = (tonumber(A.radius_m) or 40) * 100
    for _, a in ipairs(U.find_all("UtilitySpell", { skip_defaults = true })) do
        local q = U.loc(a)
        if q and here and U.dist(q, here) < r_cm then
            p.actors[#p.actors + 1] = { id = U.short(a), class = U.class_word(a), position = m(q) }
        end
    end
    return { ok = true, probe = p, v = 1 }
end
