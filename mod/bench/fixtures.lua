-- Benchmark FIXTURES on the DEV server (docs/design/eval-benchmark.md §7.2; Luis approved option B, broadened,
-- 2026-10-25: grant items/runes, unlock perks, set time, spawn creatures, reset, server mods - DEV SERVER ONLY).
-- OWNED BY THE EVAL AGENT; a judge file; FROZEN: tests/test_bench_lua.py lists the verbs (finding 13f), so deleting
-- legacy mod/ code can't silently remove or widen them.
--
-- The companion never calls this: it is the test rig, run by the harness BEFORE a case starts, logged as `setup` in
-- the trace. Claude's own play still uses only real client paths (PRINCIPLES #1).
--
-- Guards (finding 13): DW_SERVER_ROLE=dev on this server process (the harness additionally checks the client's
-- joined address != Shockbyte's before every call); the target is addressed by character GUID, never by name; refuse
-- when any OTHER player is connected.
--
-- Status v0: only `spawn` uses a verified primitive (World:SpawnActor, DISCOVERIES "Route 1"); every other verb
-- answers {ok=false, error="unverified"} until its route is probed read-only and verified on dev, one at a time,
-- with main's go-ahead. Unverified verbs make the case `skip: precondition`, never a fake pass.
local M = { VERSION = 0 }
M.VERBS = { "grant", "grant_runes", "unlock", "set_time", "spawn", "reset_skills", "teleport", "clear_area",
            "set_health", "raise_skills", "grant_to_ground", "spawn_tester" }
M.VERIFIED = { spawn = true, grant = true, grant_runes = true, unlock = true, set_health = true, teleport = true, set_time = true,
               raise_skills = true }  -- raise_skills: dev 2026-10-26 (Attack 2 -> 3), QUICK variants only  -- live on dev 2026-10-25 (DISCOVERIES "Benchmark referee + fixtures")

local root = (rawget(_G, "__dw_bench_root") or os.getenv("DW_MOD_ROOT") or "."):gsub("\\", "/")
local U = assert(loadfile(root .. "/body/util.lua"))()

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

local function spawn(target, args)
    local cls = U.find_object(tostring(args.class or ""))
    if not U.valid(cls) then  -- a short class name: take the class of a live instance (loaded classes only)
        local inst = U.find_all(tostring(args.class or ""), { skip_defaults = true })[1]  -- FindFirstOf may return the CDO
        cls = U.valid(inst) and U.try(function() return inst:GetClass() end) or nil
    end
    local loaded = nil
    if not U.valid(cls) and args.class_path and type(LoadAsset) == "function" then
        -- a class nothing has loaded yet (the runt on a fresh dev world, M1 blocker): UE4SS LoadAsset on the game
        -- thread, then find it by its full object path (the same route as mod/body/sleep.lua's shelter class)
        loaded = pcall(LoadAsset, tostring(args.class_path))
        cls = U.try(StaticFindObject, tostring(args.class_path))
    end
    if not U.valid(cls) then return { ok = false, error = "unknown_class", class = args.class, load_attempted = loaded } end
    local here = U.loc(target)
    local off = args.offset_m or { 5, 0, 0 }
    local at = { X = here.X + off[1] * 100, Y = here.Y + off[2] * 100, Z = here.Z + off[3] * 100 }
    local world = U.try(function() return target:GetWorld() end)
    local a = world and U.try(function() return world:SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not U.valid(a) then return { ok = false, error = "spawn_failed" } end
    return { ok = true, id = U.short(a), class = U.class_word(a), loaded = loaded }
end

-- Read-only: which setup routes exist for the target (the game's own UDominionCheatManager dom* functions are the
-- preferred route: domAddItem, domUnlockSpell, domSetTime, domSpawnAi, domAddSkillXp, domResetSkillXP, domTeleportTo).
local function probe_routes(target)
    local pc = U.controller_of(target)
    local cm = U.valid(pc) and U.try(function() return pc.CheatManager end) or nil
    local cdo = U.find_object("/Script/Dominion.Default__DominionCheatManager")
    return { ok = true, pc = U.short(pc), cheat_manager = U.valid(cm) and U.fullname(cm) or nil,
             cheat_class_loaded = U.valid(cdo), cheat_class_cdo = U.valid(cdo) and U.fullname(cdo) or nil }
end

-- Server-side grant (verified live): InventoryComponent:AddItemByData(ItemData, Count, 100, <tags>), where <tags> is a
-- COPY of a live, empty FGameplayTagContainer from a UItem already in that inventory (CLAUDE.md principle 4: never a
-- struct built in Lua). The harness passes the item's asset path from the catalog.
local function live_empty_tags(inv)
    local tags
    pcall(function()
        inv.ItemSlots:ForEach(function(_, e)
            local it = U.try(function() return e:get() end) or e
            if tags == nil and U.valid(it) then
                local t = U.try(function() return it.GameplayTags end)
                if t and U.try(function() return #t.GameplayTags end) == 0 then tags = t end
            end
        end)
    end)
    return tags
end

local function grant(target, path, count)
    local pc = U.controller_of(target)
    local inv = U.valid(pc) and U.try(function() return pc.InventoryComponent end) or nil
    if not U.valid(inv) then return { ok = false, error = "no_inventory" } end
    local data = U.find_object(tostring(path or ""))
    if not U.valid(data) then return { ok = false, error = "item_data_not_loaded", path = path } end
    local tags = live_empty_tags(inv)
    if not tags then return { ok = false, error = "no_live_empty_tag_container" } end
    local before = U.try(function() return inv:GetNumItemsByData(data) end) or 0
    local ok, err = pcall(function() inv:AddItemByData(data, math.floor(tonumber(count) or 1), 100.0, tags) end)
    local after = U.try(function() return inv:GetNumItemsByData(data) end) or 0
    return { ok = ok and after > before, error = (not ok) and tostring(err) or (after <= before and "not_added" or nil),
             path = path, before = before, after = after }
end

-- raise_skills (QUICK variants only; main cases make him level himself - Luis 2026-10-26).
-- Route: the server's own SkillComponent:AddXpFromEvent(XPEventRowHandle, Context, Multiplier, bIgnoreModifier) on his
-- controller, with the row handle READ from the live SkillData.DamageXPEvent property (a copy of a live engine struct,
-- CLAUDE.md principle 4; never a hand-built handle). Verified on dev 2026-10-26: the XP lands on a later tick (not
-- readable in the same call) at ~0.8 XP per multiplier unit (Attack: x1 -> +1, x10 -> +8). So the verb is ONE STEP:
-- it reports the current level/xp and, when below the wanted level, adds (needed - current) * 1.15 multiplier units;
-- the harness repeats it until every skill reports ok (devtarget.setup, bounded rounds).
local function skill_rows(sk)
    local out = {}
    local arr = U.try(function() return sk.Skills end)
    if not arr then return out end
    pcall(function()
        arr:ForEach(function(_, el)
            local x = el:get()
            local d = U.try(function() return x.SkillData end)
            if U.valid(d) then
                out[#out + 1] = { name = (U.short(d) or "?"):gsub("^SKILL_", ""), data = d, xp = U.try(function() return x.CurrentXP end) }
            end
        end)
    end)
    return out
end

-- Per-skill XP-event sources (live 2026-10-26: SkillData.DamageXPEvent gives NO XP for Fishing, Magic, Agility).
-- Each is a READ of a live row handle the game itself uses for that skill (reflection dump, build 26161880).
local function component_of(actor, cls)
    for _, c in ipairs(U.find_all(cls, { skip_defaults = true })) do
        if U.try(function() return c:GetOwner() end) == actor then return c end
    end
end
local XP_SOURCES = {
    Magic = function(target)  -- UPlayerMagicComponent.SpellDamageXpEvent
        local c = component_of(target, "PlayerMagicComponent")
        return c and U.try(function() return c.SpellDamageXpEvent end)
    end,
    Agility = function(target)  -- ADominionPlayerCharacter.SprintComponent -> USprintComponent.SprintXpEvent
        local c = U.try(function() return target.SprintComponent end)
        return U.valid(c) and U.try(function() return c.SprintXpEvent end) or nil
    end,
    Fishing = function()  -- UCatchableFishSpeciesData.Info.NormalDrop.OnFishingXpEvent (any loaded species)
        local d = U.find_all("CatchableFishSpeciesData", { skip_defaults = true })[1]
        return d and U.try(function() return d.Info.NormalDrop.OnFishingXpEvent end)
    end,
}

local function raise_skills(target, args)
    local pc = U.try(function() return target.Controller end)
    local sk = U.valid(pc) and U.try(function() return pc.SkillComponent end) or nil
    if not U.valid(sk) then return { ok = false, error = "no_skill_component" } end
    local want_of = function(name)
        if type(args.skills) == "table" and args.skills[name] then return tonumber(args.skills[name]) end
        if args.level and name ~= args.except then return tonumber(args.level) end
    end
    -- adaptive step (live 2026-10-26: XP per multiplier unit differs per event: Attack ~0.8, Mining ~3, so a fixed
    -- factor overshot Mining to 19): the first call adds a quarter of the gap; later calls use the ratio observed
    -- since the previous call (the XP lands a tick later, so it is measured across calls), aiming at 97% of the gap
    local mem = rawget(_G, "__dw_bench_raise") or {}
    rawset(_G, "__dw_bench_raise", mem)
    local guid = tostring(args.character_guid or "")
    local results, all_ok = {}, true
    for _, r in ipairs(skill_rows(sk)) do
        local want = want_of(r.name)
        if want then
            local d = r.data
            local res = { level = U.try(function() return sk:GetSkillLevel(d) end), xp = r.xp, want = want }
            res.ok = (res.level or 0) >= want
            local key = guid .. ":" .. r.name
            local prev = mem[key]
            if prev and prev.added and r.xp and prev.xp and r.xp > prev.xp then prev.ratio = (r.xp - prev.xp) / prev.added end
            if not res.ok then
                local src = XP_SOURCES[r.name]
                local handle = (src and src(target)) or U.try(function() return d.DamageXPEvent end)
                res.source = src and "skill_specific" or "DamageXPEvent"
                local need = U.try(function() return sk:GetTotalXPNeededForLevel(want) end)
                res.need_total = need
                local mult = tonumber(args.multiplier)
                if not mult and need and r.xp then
                    local gap = need - r.xp
                    local ratio = prev and prev.ratio
                    mult = math.max(1, math.ceil(ratio and (gap * 0.97 / ratio) or (gap * 0.25)))
                    res.ratio = ratio
                end
                if prev and prev.added and r.xp == prev.xp and (prev.calls or 0) >= 3 then
                    res.error = "no_xp_from_event"  -- three calls, no XP: this row gives this skill nothing
                elseif not handle then
                    res.error = "no_xp_event_handle"
                elseif not mult then
                    res.error = "no_xp_target"
                else
                    local ok1, e1 = pcall(function() sk:AddXpFromEvent(handle, "bench_fixture", mult + 0.0, true) end)
                    res.added = ok1 and mult or nil
                    res.error = (not ok1) and tostring(e1) or nil
                    mem[key] = { xp = r.xp, added = ok1 and mult or nil, ratio = prev and prev.ratio,
                                 calls = ((prev and r.xp == prev.xp) and (prev.calls or 0) or 0) + 1 }
                end
            else
                mem[key] = nil
            end
            all_ok = all_ok and res.ok
            results[r.name] = res
        end
    end
    if next(results) == nil then return { ok = false, error = "no_matching_skill", skills = args.skills } end
    return { ok = all_ok, pending = not all_ok, results = results }
end

-- set_time (UNVERIFIED until a live run): the server's own time actor. BP_InGameTimeActor_C (AInGameTimeActor, it
-- implements IInGameTimeProvider) :GetInGameTime() -> FTimespan {Ticks}, :SetInGameTime(FTimespan). FTimespan is the
-- TOTAL in-game time (crop timers store PlantedInGameTime / NextStageInGameTime in it), so the clock only ever moves
-- FORWARD: to the next occurrence of the wanted hour of day. A plain {Ticks=n} table is the parameter (a server-local
-- call, never a Client_* RPC; CLAUDE.md principle 4); 1 tick = 100 ns.
local TICKS_PER_HOUR = 36000000000
local function set_time(args)
    local actor = U.find_all("InGameTimeActor", { skip_defaults = true })[1]
    if not U.valid(actor) then return { ok = false, error = "no_time_actor" } end
    local now = U.try(function() return actor:GetInGameTime() end)
    local ticks = now and U.try(function() return now.Ticks end)
    if type(ticks) ~= "number" then return { ok = false, error = "time_unreadable" } end
    local day = 24 * TICKS_PER_HOUR
    if args.read then return { ok = true, hour = (ticks % day) / TICKS_PER_HOUR, day = math.floor(ticks / day) } end
    local want = tonumber(args.hours)
    if not want or want < 0 or want >= 24 then return { ok = false, error = "hours must be in [0, 24)" } end
    local base = ticks - (ticks % day)
    local target = base + math.floor(want * TICKS_PER_HOUR)
    if target <= ticks then target = target + day end
    local ok, err = pcall(function() actor:SetInGameTime({ Ticks = target }) end)
    local after = U.try(function() return actor:GetInGameTime().Ticks end)
    return { ok = ok and type(after) == "number" and after >= target - TICKS_PER_HOUR / 60, error = (not ok) and tostring(err) or nil,
             before_h = (ticks % day) / TICKS_PER_HOUR, after_h = after and (after % day) / TICKS_PER_HOUR or nil,
             advanced_h = after and (after - ticks) / TICKS_PER_HOUR or nil }
end

local function unlock(target, paths)
    local pc = U.controller_of(target)
    local prog = U.valid(pc) and U.try(function() return pc.ProgressComponent end) or nil
    if not U.valid(prog) then return { ok = false, error = "no_progress_component" } end
    local list = {}
    for _, p in ipairs(paths or {}) do
        local sd = U.find_object(tostring(p))
        if not U.valid(sd) then return { ok = false, error = "spell_data_not_loaded", path = p } end
        list[#list + 1] = sd
    end
    local ok, err = pcall(function() prog:UnlockSpells(list) end)
    return { ok = ok, error = (not ok) and tostring(err) or nil, n = #list }
end

-- The target's CheatManager (step by step, each verified on dev before the next is used):
--   mode "enable": APlayerController:EnableCheats() (the game's own exec; a no-op when the server disallows cheats)
--   mode "construct": StaticConstructObject(DominionCheatManager, outer = the PC) assigned to pc.CheatManager
local function cheat_manager(target, mode)
    local pc = U.controller_of(target)
    if not U.valid(pc) then return nil, "no_controller" end
    local cm = U.try(function() return pc.CheatManager end)
    if U.valid(cm) then return cm end
    if mode == "enable" or mode == "construct" then
        pcall(function() pc:EnableCheats() end)
        cm = U.try(function() return pc.CheatManager end)
        if U.valid(cm) then return cm end
    end
    if mode == "construct" and type(StaticConstructObject) == "function" then
        local cls = U.find_object("/Script/Dominion.DominionCheatManager")
        local obj = U.valid(cls) and U.try(function() return StaticConstructObject(cls, pc) end) or nil
        if U.valid(obj) then
            pcall(function() pc.CheatManager = obj end)
            cm = U.try(function() return pc.CheatManager end)
            if U.valid(cm) then return cm end
            return nil, "constructed_but_not_assigned"
        end
        return nil, "construct_failed"
    end
    return nil, "no_cheat_manager"
end

function M.run(log, args)
    args = args or {}
    if args.action == "cheats" then
        local why, target = guard(args)
        if why then return { ok = false, error = why, detail = target } end
        local cm, err = cheat_manager(target, args.mode)
        return { ok = cm ~= nil, error = err, cheat_manager = cm and U.fullname(cm) or nil, mode = args.mode }
    end
    if args.action == "probe" then
        local why, target = guard(args)
        if why then return { ok = false, error = why, detail = target } end
        return probe_routes(target)
    end
    local verb = tostring(args.verb or "")
    local known = false
    for _, v in ipairs(M.VERBS) do if v == verb then known = true end end
    if not known then return { ok = false, error = "unknown_verb", verbs = M.VERBS } end
    local why, target = guard(args)
    if why then return { ok = false, error = why, detail = target } end
    if not M.VERIFIED[verb] and args.verify_attempt ~= true then return { ok = false, error = "unverified", verb = verb } end
    if verb == "spawn" and not args.via_cheat then return spawn(target, args) end
    if verb == "grant" then return grant(target, args.path, args.count) end
    if verb == "grant_runes" then
        local out = {}
        for _, r in ipairs(args.items or {}) do  -- [{path, count}] resolved by the harness from the catalog
            local g = grant(target, r.path, r.count)
            out[#out + 1] = g
            if not g.ok then return { ok = false, error = g.error, results = out } end
        end
        return { ok = true, results = out }
    end
    if verb == "unlock" then return unlock(target, args.paths) end
    if verb == "raise_skills" then return raise_skills(target, args) end
    if verb == "set_time" then return set_time(args) end
    if verb == "set_health" then  -- HealthComponent:SetHealth(value, Context): a server-local call with an FString
        local hc = U.try(function() return target.HealthComponent end)
        if not U.valid(hc) then return { ok = false, error = "no_health_component" } end
        local mx = U.try(function() return hc:GetMaxHealth() end) or 100
        local v = tonumber(args.value) or (mx * (tonumber(args.pct) or 50) / 100)
        local ok, err = pcall(function() hc:SetHealth(v, "bench_fixture") end)
        local now = U.try(function() return hc:GetAuthoritativeHealth() end)
        return { ok = ok and now ~= nil and math.abs(now - v) < 1, error = (not ok) and tostring(err) or nil, health = now, want = v }
    end
    if verb == "teleport" then  -- server-side K2_TeleportTo on the benchmark character (vectors, like SpawnActor)
        local at = args.at or {}
        local x, y, z = (tonumber(at[1]) or 0) * 100, (tonumber(at[2]) or 0) * 100, (tonumber(at[3]) or 0) * 100
        local before = U.loc(target)
        local ok, res = pcall(function() return target:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        local after = U.loc(target)
        return { ok = ok and res ~= false, error = (not ok) and tostring(res) or nil, returned = ok and res or nil,
                 before = before and { before.X / 100, before.Y / 100, before.Z / 100 } or nil,
                 after = after and { after.X / 100, after.Y / 100, after.Z / 100 } or nil }
    end
    -- every other verb goes through the game's own cheat functions on the target's (constructed) CheatManager
    local cm, err = cheat_manager(target, "construct")
    if not cm then return { ok = false, error = err or "no_cheat_manager" } end
    local function call(fn, ...)
        local a = { ... }
        local ok, e = pcall(function() return cm[fn](cm, table.unpack(a)) end)
        return { fn = fn, ok = ok, error = (not ok) and tostring(e) or nil }
    end
    local calls = {}
    if verb == "grant" then
        calls[1] = call("domAddItem", tostring(args.item), math.floor(tonumber(args.count) or 1), math.floor(tonumber(args.durability_pct) or 100))
    elseif verb == "grant_runes" then
        for rune, n in pairs(args.runes or {}) do
            local item = tostring(rune):find("^ITEM_") and tostring(rune) or ("ITEM_Rune_" .. tostring(rune))
            calls[#calls + 1] = call("domAddItem", item, math.floor(tonumber(n) or 1), 100)
        end
    elseif verb == "unlock" then
        calls[1] = call("domUnlockSpell", tostring(args.spell))
    elseif verb == "set_time" then
        calls[1] = call("domSetTime", tonumber(args.hours) or 12.0)
    elseif verb == "reset_skills" then
        calls[1] = call("domResetSkillXP", tostring(args.skill))
    elseif verb == "teleport" then
        local at = args.at or {}
        calls[1] = call("domTeleportTo", (tonumber(at[1]) or 0) * 100, (tonumber(at[2]) or 0) * 100, (tonumber(at[3]) or 0) * 100)
    elseif verb == "spawn" then
        local here = U.loc(target)
        local off = args.offset_m or { 5, 0, 0 }
        calls[1] = call("domSpawnAi", tostring(args.class), here.X + off[1] * 100, here.Y + off[2] * 100, here.Z + off[3] * 100,
                        math.floor(tonumber(args.level) or 1))
    else
        return { ok = false, error = "unverified", verb = verb }
    end
    local all_ok = true
    for _, c in ipairs(calls) do all_ok = all_ok and c.ok end
    return { ok = all_ok, verb = verb, calls = calls, verified = M.VERIFIED[verb] == true }
end

return M
