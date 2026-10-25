-- spells: Claude casts spells the way a player does (route R2.20; design docs/design/client-spells.md).
--
--   spells {all?}          what he can cast, from GAME DATA only: name, the game's own description
--                          (use_when), cast type, rune cost vs carried, cooldown left, castable + a
--                          truthful reason/detail. Shape = brain/spells.py SpellBook rows. all=true
--                          also lists locked spells with the skill level that unlocks them.
--   cast {spell, target?}  Q (IA_SpellMenu, Released) opens the wheel -> the slot's quick key
--                          (IA_Spellcasting_QuickAccessN) -> placed/aimed: aim the camera at the
--                          target, LMB (IA_Spellcasting_PlaceSpell, Released) -> VERIFY: runes fell
--                          or LastCastTimeBySpellData changed; effect evidence (new GE instance / tag /
--                          own spell actor + landed_at) reported. Esc (IA_Spellcasting_Cancel) on any
--                          exit that leaves a spell input mode open.
-- No Server_* call, nothing spawned or granted, no spell names in code: every row comes from
-- UtilitySpellData / SkillPerkData, the cast path depends only on CastType and the wheel slot.
-- The model decides WHEN to cast (from use_when). Code only reports the game's gates (unlock, runes,
-- cooldown, wheel) and enforces Luis's safety rule: never hurt players (reason "unsafe").
--
-- Prior art: our own verified input paths (combat IA_PrimaryAction, inventory IA_Interact, hotbar
-- keys); Epic InjectInputVectorForAction; game controls (allthings.how spellbook-and-wheel guide,
-- dragonwilds.runescape.wiki/w/Spells). Decision: ADAPT the injection helper, BUILD this state machine.
--
-- Contract (bridge module handler): HANDLERS.spells(log, args, ctx) -> result;
-- HANDLERS.cast(log, args, ctx) -> {wait = waiter, wait_s} (a WAITER like drop: it never takes the
-- bridge's action slot, so a follow/gather keeps running; the pawn is taken through the arbiter at
-- level 3.5 (above command/task, below reflex), resumable, so a follow is suspended and resumed).
-- W = engine touches; tests replace them.
local M = {}

M.cfg = {
    level = 3.5,            -- arbiter level: above command (3) / task (2), below reflex (4)
    lease_s = 5,
    open_wait_s = 1.2,      -- after Q: wait for the radial input mode
    open_tries = 2,
    page_wait_s = 0.4,      -- after switching the wheel page: let the slices refresh (live: updated within 0.4 s)
    page_max_s = 1.5,       -- ... and wait up to this long for the slice icons to change
    select_wait_s = 1.0,    -- after the quick key: wait for a spell mode or the cast to start
    verify_s = 4.0,         -- after the cast input: runes / cooldown must change within this ...
    cast_max_s = 12,
    late_watch_s = 15,
    cooldown_grace_s = 2,
    finish_s = 3,           -- after a verified cast: wait this long for the game to leave its spell mode   -- after the server's cooldown notice: wait this long for a success signal
    aim_heights_m = { 1.2, 0.8, 1.6, 0.5 }, -- a standing tree / plant (foliage, position = its base): aim at the trunk
    actor_aim_heights_m = { 0.3, 0.0, 0.8, 1.2 }, -- an actor (a log on the ground, a rock; position = its origin)
    aim_match_m = 3,        -- an aimed preview must sit this close (2D) to the target
    preview_checks = 2,     -- re-aim + re-read the preview this many times per candidate
    place_budget_s = 5,     -- the whole aim/placement search; then cancel (never cast it badly)      -- after a failed answer: keep checking this long for a late success        -- ... or, while the game is still casting it (spell input mode / casting state), this
    wait_s = 22,           -- waiter deadline (the bridge answers expire() after it)
    typo_cutoff = 0.8,      -- fuzzy name match only above this similarity, and only if unique
    default_radius_m = 5,   -- harm radius when a harmful spell has no Shape module
    place_max_m = 15,       -- fallback camera-to-target limit (SpellcastingComponent.MaxDistanceFromCameraToPlaceSpell)
    landed_tolerance_m = 3, -- a targeted spell that lands farther than max(this, its radius) is reported as a miss
    preview_wait_s = 0.35,  -- after aiming at a spot: let the game's placement preview follow the camera
    preview_match_m = 2.5,  -- the preview must sit this close to the spot aimed at
    max_spots = 10,
    spot_rings_m = { 3, 4.5, 6, 7.5, 9 }, -- (live: 11 m spots were beyond the camera's 15 m reach)
    far_rings_m = { 15, 20, 25, 30 }, -- when nothing nearby is accepted: where the flattest ground is (a hint) -- automatic spots around me (around a named target: itself, then 2 and 3.5 m rings)
    spot_player_clear_m = 3, -- automatic spots keep this far from players
    spot_max_spread_m = 1.5, -- traces only rank and drop hopeless spots (3x3 heights over 3 m); the GAME preview decides
    spot_min_normal_z = 0.85,
    quick_keys = 8,         -- IA_Spellcasting_QuickAccess0..7
    gameplay_mode = "DIM_Gameplay",
    radial_mode = "DIM_RadialMenu",
    spell_modes = { DIM_SpellcastingMode = true, DIM_SpellPlacementMode = true, DIM_SpellPlacementModeAdvancedMovement = true },
}
-- EUtilitySpellCastType (CXX dump 26161880)
M.CAST_TYPES = { [0] = "instant", [1] = "placed", [2] = "aimed", [3] = "instant_after_move" }
-- Catalog roles (data/spells_<build>.json usage.role, a DATA profile) that mean "this hurts what it
-- hits": refuse at players / near players. Live game data (a Damage module) also counts.
M.HOSTILE_ROLES = { combat_damage = true, combat_cc = true, gathering_aoe = true }
M.AREA_HARM_ROLES = { combat_damage = true, gathering_aoe = true }

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function mem()
    local m = rawget(_G, "DWSpells")
    if not m then m = { static = {}, cast_at = {}, hooks = {}, events = {} }; _G.DWSpells = m end
    return m
end
M.mem = mem
local function lower(s) return tostring(s or ""):lower() end
local function norm_name(s) return lower(s):gsub("[^%w]", "") end
local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
local function d3(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + ((a[3] or 0) - (b[3] or 0)) ^ 2)
end

-- ------------------------------------------------------------------ pure helpers
-- Edit similarity in [0, 1] on normalised names (optimal string alignment: insert, delete,
-- substitute, and swap two neighbours each cost 1, so a transposed typo is one edit).
function M.similarity(a, b)
    a, b = norm_name(a), norm_name(b)
    if a == b then return 1 end
    local la, lb = #a, #b
    if la == 0 or lb == 0 then return 0 end
    local d = {}
    for i = 0, la do d[i] = { [0] = i } end
    for j = 0, lb do d[0][j] = j end
    for i = 1, la do
        for j = 1, lb do
            local c = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            local v = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
            if i > 1 and j > 1 and a:sub(i, i) == b:sub(j - 1, j - 1) and a:sub(i - 1, i - 1) == b:sub(j, j) then
                v = math.min(v, d[i - 2][j - 2] + 1)
            end
            d[i][j] = v
        end
    end
    return 1 - d[la][lb] / math.max(la, lb)
end

-- Resolve the model's spell name among rows: exact (name or id, case/space-insensitive) first, then
-- a typo match above cfg.typo_cutoff ONLY when exactly one row qualifies. Never substitutes.
-- -> row | nil, reason, data
function M.resolve(rows, want)
    local w = norm_name(want)
    if w == "" then return nil, "invalid_args", { detail = "spell is required" } end
    local names = {}
    for _, r in ipairs(rows) do names[#names + 1] = r.name end
    for _, r in ipairs(rows) do
        if norm_name(r.name) == w or norm_name(r.id) == w or norm_name((r.id or ""):gsub("^USD_", "")) == w then return r end
    end
    local hits = {}
    for _, r in ipairs(rows) do
        local s = math.max(M.similarity(r.name, want), M.similarity((r.id or ""):gsub("^USD_", ""), want))
        if s >= M.cfg.typo_cutoff then hits[#hits + 1] = r end
    end
    if #hits == 1 then return hits[1], nil, { matched = "typo" } end
    if #hits > 1 then
        local c = {}
        for _, r in ipairs(hits) do c[#c + 1] = r.name end
        return nil, "ambiguous_target", { candidates = c, detail = "Which spell do you mean: " .. table.concat(c, " or ") .. "?" }
    end
    return nil, "unknown_target", { candidates = names,
        detail = #names > 0 and ("I don't know a spell called " .. tostring(want) .. ". I can cast: " .. table.concat(names, ", ") .. ".")
                 or ("I don't know a spell called " .. tostring(want) .. "; I haven't unlocked any spells yet.") }
end

local function cost_text(cost)
    local parts = {}
    for _, c in ipairs(cost or {}) do parts[#parts + 1] = tostring(c.count) .. " " .. tostring(c.name or c.item) end
    return table.concat(parts, " + ")
end
M.cost_text = cost_text

-- One spell row (SpellBook shape) from its static info + the live snapshot. Pure.
--   st = W.static(...) result; snap = W.snapshot(...) result
function M.row(st, snap, local_cast_at, now_local)
    local cast_type = M.CAST_TYPES[st.cast_type] or tostring(st.cast_type)
    local r = { id = st.asset, name = st.name, role = cast_type, cast_type = cast_type, use_when = st.desc,
                description = st.desc, cooldown_s = st.cooldown_s, icon = st.icon, special = st.special_req, unlocked = snap.unlocked[st.asset] == true }
    local cost = {}
    for _, c in ipairs(st.cost or {}) do
        cost[#cost + 1] = { item = c.item, name = c.name, count = c.count, have = (snap.items or {})[c.item] or 0 }
    end
    r.cost = cost
    -- cooldown: the game's LastCastTimeBySpellData vs the server clock; our own cast record as a floor
    local left = 0
    local last, now = (snap.last_cast or {})[st.asset], snap.world_time or snap.server_time
    if type(last) == "number" and type(now) == "number" and now >= last and now - last < 1e6 then
        left = math.max(left, (st.cooldown_s or 0) - (now - last))
    end
    if local_cast_at and now_local then left = math.max(left, (st.cooldown_s or 0) - (now_local - local_cast_at)) end
    r.remaining_s = left > 0.05 and math.floor(left * 10 + 0.5) / 10 or 0
    -- wheel slot (0-based within the flat SelectedSpells array)
    local per = snap.per_radial or 12
    for i, a in ipairs(snap.wheel or {}) do if a == st.asset then r.wheel_slot = i - 1; break end end
    if r.wheel_slot then r.wheel_page, r.wheel_key = r.wheel_slot // per + 1, r.wheel_slot % per + 1 end
    -- the game's gates, in the order a player meets them
    local why, detail
    if not r.unlocked then
        why = "not_unlocked"
        local p = st.perk or {}
        local have = p.skill and (snap.skills or {})[p.skill] or nil
        r.needs = { skill = p.skill_name, level = p.level, have = have }
        detail = "I haven't unlocked " .. st.name .. " yet" .. (p.level and (": it needs " .. tostring(p.skill_name or "a skill") .. " level "
            .. tostring(p.level) .. (have and (" and I'm level " .. have) or "")) or "") .. "."
    elseif r.wheel_slot == nil then
        why, detail = "not_on_wheel", st.name .. " isn't on my spell wheel, so I can't cast it yet."
    elseif (snap.req or {})[st.asset] then
        -- the game's own special requirement is not met (e.g. "Logging Axe", "A held melee weapon")
        local tag = snap.req[st.asset]
        why = "requirement"
        r.needs = (st.special_req and st.special_req:gsub("%s+$", "")) or M.tag_words(tag)
        r.requirement_tag = tag
        detail = st.name .. " needs " .. tostring(r.needs) .. " (the game says: " .. M.tag_words(tag) .. ")."
    else
        for _, c in ipairs(cost) do
            if c.have < (c.count or 0) then
                why = "not_enough_resources"
                detail = st.name .. " needs " .. c.count .. " " .. tostring(c.name or c.item) .. " and I only have " .. c.have .. "."
                break
            end
        end
        if not why and r.remaining_s > 0 then
            why, detail = "on_cooldown", st.name .. " is still recharging (" .. math.ceil(r.remaining_s) .. " s)."
        end
        if not why and snap.falling and not st.allow_falling then
            why, detail = "busy", "I can't cast " .. st.name .. " in mid-air."
        end
        if not why and snap.input_mode and (M.cfg.spell_modes[snap.input_mode] or snap.input_mode == M.cfg.radial_mode) then
            why, detail = "busy", "A previous cast was still in progress (my spell wheel was open)."
        end
    end
    r.castable = why == nil
    r.reason, r.detail = why, detail
    return r
end

-- Is a player in harm's way? Pure. players = {{name, position}}; at = landing point [m].
--   st = {name, harmful (a Damage module), has_shape (a Shape/area module), role (catalog data
--         profile), cast_type (EUtilitySpellCastType number or word), radius_m}
-- * target check: a hostile spell (damage module or a hostile catalog role) never targets a player.
-- * proximity check: only for spells that deal damage AT the landing point: placed/aimed spells
--   that are harmful or have an area-harm role, and instant spells with BOTH a damage and a Shape
--   module (a self-centred blast). Self buffs without an area (e.g. a weapon enchant, which adds
--   damage to his own weapon) are never refused for a player standing next to him.
--   Radius = the Shape module's radius; the cfg default only for placed/aimed spells without one.
function M.harm_check(st, target_player, at, players)
    local ct = type(st.cast_type) == "number" and M.CAST_TYPES[st.cast_type] or st.cast_type
    local away = ct == "placed" or ct == "aimed"
    local role = st.role or ""
    local hostile = st.harmful or M.HOSTILE_ROLES[role] == true
    if hostile and target_player then
        return { unsafe = true, player = target_player, detail = "I won't cast " .. st.name .. " at " .. target_player .. "." }
    end
    local area
    if away then area = st.harmful or M.AREA_HARM_ROLES[role] == true
    else area = st.harmful and st.has_shape end
    if area and at then
        local radius = st.radius_m or (away and M.cfg.default_radius_m) or nil
        for _, p in ipairs(radius and players or {}) do
            local d = d3(at, p.position)
            if d and d <= radius then
                return { unsafe = true, player = p.name, dist_m = math.floor(d * 10 + 0.5) / 10, radius_m = radius,
                         detail = "Not casting " .. st.name .. " there, it would hit " .. tostring(p.name) .. "." }
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------------ engine touches (tests replace W)
local W = {}
M.W = W
M.STATIC_V = 2 -- bump when W.static gains fields (its cache survives hot reloads in _G.DWSpells)
local Uc
local function U()
    if not Uc then Uc = assert(loadfile((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/") .. "/mod/body/util.lua"))() end
    return Uc
end
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
    pcall(function() arr:ForEach(function(a, b) n = n + 1; if n > (cap or 256) then return true end; fn(unwrap(b), unwrap(a)) end) end)
end
local function to_m(v)
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { x / 100, y / 100, (z or 0) / 100 } end
    return nil
end
function W.pc(api) local s = api.module("sense"); return s and s.local_pc and s.local_pc() or nil end
function W.pawn(api) local s = api.module("sense"); return s and s.local_pawn and s.local_pawn() or nil end

-- Static facts of one UtilitySpellData (cached per asset; game data only).
function W.static(spell)
    local u = U()
    local id = u.short(spell)
    local cache = mem().static
    if cache[id] and cache[id].v == M.STATIC_V then return cache[id] end
    local s = { v = M.STATIC_V, asset = id, name = u.str(u.try(function() return spell.SpellDisplayName end)) or id,
                cast_type = u.try(function() return spell.CastType end),
                cooldown_s = u.try(function() return spell.CooldownDuration end) or 0,
                allow_falling = u.try(function() return spell.bAllowCastingWhileFalling end) == true,
                special_req = u.str(u.try(function() return spell.SpecialRequirementsText end)), cost = {}, modules = {} }
    if s.special_req == "" then s.special_req = nil end
    s.req_class = u.try(function() return spell.SpecialRequirementsStrategy end)
    if not u.valid(s.req_class) then s.req_class = nil end
    -- reach: the spell's own placement distance override (cm), when it has one
    local ov = u.try(function() return spell.bOverrideMaxPlacementDistanceFromCamera end) == true
    local mx = ov and u.try(function() return spell.MaxPlacementDistanceFromCamera end) or nil
    if type(mx) == "number" and mx > 0 then s.reach_m = mx / 100 end
    -- the wheel slice shows this texture: how the cast checks the open page shows THIS spell
    local icon = u.str(u.try(function() return spell.SpellIcon:GetObjectID():GetAssetPathName() end))
        or u.str(u.try(function() return spell.SpellIcon:GetAssetPathName() end))
    s.icon = icon and icon:match("([^%.]+)$") or nil
    local perk = u.try(function() return spell.OwningPerk end)
    if u.valid(perk) then
        s.desc = u.str(u.try(function() return perk.PerkDescription end)) or u.str(u.try(function() return perk.Description end))
        local ui = u.try(function() return perk.PerkUnlockInfo end)
        if ui then
            local sk = u.try(function() return ui.AssociatedSkill end)
            local path = u.str(u.try(function() return sk:GetObjectID():GetAssetPathName() end))
            s.perk = { level = u.try(function() return ui.RequiredSkillLevel end), skill = path and path:match("([%w_]+)$") }
            s.perk.skill_name = s.perk.skill and s.perk.skill:gsub("^SKILL_", "") or nil
        end
    end
    local c = u.try(function() return spell.Modules end)
    each(c and u.try(function() return c.Modules end), function(w)
        local m = u.try(function() return w.Module end)
        if not u.valid(m) then return end
        local kind = (u.class_word(m) or ""):gsub("^SpellModule_", "")
        s.modules[#s.modules + 1] = kind
        if kind:find("Damage", 1, true) then s.harmful = true end
        if kind == "CostItems" then
            each(u.try(function() return m.ItemsCostInfo end), function(ci)
                local it = u.try(function() return ci.ItemData end)
                if u.valid(it) then
                    s.cost[#s.cost + 1] = { item = u.short(it), name = u.str(u.try(function() return it.Name end)) or u.short(it),
                                            count = u.try(function() return ci.Count end) or 0 }
                end
            end, 16)
        elseif kind == "Shape" then
            s.has_shape = true
            local sh = u.try(function() return m.Shape end)
            local rad = u.valid(sh) and u.try(function() return sh.Radius end)
            if type(rad) == "number" and rad > 0 then s.radius_m = rad / 100 end
        elseif kind == "GameplayEffect" then
            s.effect = u.short(u.try(function() return m.GameplayEffect end))
        end
    end, 64)
    if not s.desc or s.desc == "" then s.desc = s.special_req end
    s.role = (M.catalog_roles() or {})[id]
    cache[id] = s
    return s
end

-- Optional DATA profile: usage.role per spell from data/spells_<build>.json (never code).
function M.catalog_roles()
    local m = mem()
    if m.roles ~= nil then return m.roles or nil end
    m.roles = false
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local okj, json = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))() end)
    local f = okj and io.open(root .. "/data/spells_26161880.json", "rb")
    if not f then return nil end
    local txt = f:read("a"); f:close()
    local doc = json.decode(txt)
    if type(doc) == "table" and type(doc.spells) == "table" then
        local roles = {}
        for k, v in pairs(doc.spells) do roles[k] = type(v.usage) == "table" and v.usage.role or nil end
        m.roles = roles
    end
    return m.roles or nil
end

-- Live state: wheel, unlocks, carried item counts, cooldown map, server clock, input mode, falling,
-- casting, GE instances/tags, own spell actors, skill levels.
function W.snapshot(api)
    local u = U()
    local pc, pawn = W.pc(api), W.pawn(api)
    if not (u.valid(pc) and u.valid(pawn)) then return nil end
    local s = { wheel = {}, unlocked = {}, objects = {}, items = {}, last_cast = {}, ge = {}, tags = {}, actors = {}, skills = {} }
    local sc = u.try(function() return pc.SpellcastingComponent end)
    if u.valid(sc) then
        s.per_radial = u.try(function() return sc.NumSpellSlotsPerRadial end)
        s.radials = u.try(function() return sc.NumSpellRadials end)
        s.place_max_m = (u.try(function() return sc.MaxDistanceFromCameraToPlaceSpell end) or 0) / 100
        each(u.try(function() return sc.SelectedSpells end), function(e) s.wheel[#s.wheel + 1] = u.valid(e) and u.short(e) or false end, 64)
    end
    local prog = u.try(function() return pc.ProgressComponent end)
    each(prog and u.try(function() return prog.SpellsUnlocked end), function(b, a)
        local e = u.valid(b) and b or a
        if u.valid(e) then s.unlocked[u.short(e)] = true; s.objects[u.short(e)] = e end
    end, 128)
    local inv = u.try(function() return pc.InventoryComponent end)
    each(inv and u.try(function() return inv.ItemSlots end), function(it)
        if u.valid(it) then
            local d = u.short(u.try(function() return it.ItemData end))
            if d then s.items[d] = (s.items[d] or 0) + (u.try(function() return it.Count end) or 1) end
        end
    end, 256)
    local um = u.try(function() return pawn.PlayerUtilityMagicComponent end)
    if u.valid(um) then
        pcall(function() um.LastCastTimeBySpellData:ForEach(function(k, v) s.last_cast[u.short(unwrap(k)) or "?"] = unwrap(v) end) end)
        local sp = u.try(function() return um.SpellBeingPreparedOrCast.SpellBeingPreparedOrCastData end)
        if u.valid(sp) then s.casting = u.short(sp); s.casting_name = u.str(u.try(function() return sp.SpellDisplayName end)) end
    end
    -- spell actors (shelters, totems, ...) near me. OurSpellActors read EMPTY on the client (live,
    -- with Claude's own shelter standing), so every UtilitySpell within 40 m is listed and a cast is
    -- matched to the NEW one nearest its preview point.
    local here = u.loc(pawn)
    for _, a in ipairs(u.find_all("UtilitySpell", { skip_defaults = true })) do
        local p = u.loc(a)
        if p and here and u.dist(p, here) < 4000 then s.actors[u.short(a)] = { class = u.class_word(a), position = to_m(p) } end
    end
    local gs = u.find_first("GameStateBase")
    s.server_time = gs and u.try(function() return gs:GetServerWorldTimeSeconds() end)
    -- LastCastTimeBySpellData uses THIS client's world clock (live: 1503 s ~ 25 min after joining,
    -- while the server clock read 58000+), i.e. UGameplayStatics::GetTimeSeconds
    local gst = u.find_object("/Script/Engine.Default__GameplayStatics")
    s.world_time = gst and u.try(function() return gst:GetTimeSeconds(pawn) end)
    s.input_mode = u.short(u.try(function() return pc.CurrentInputMode end))
    s.falling = u.try(function() return pawn.CharacterMovement:IsFalling() end) == true
    local ge = u.try(function() return pawn.GameplayEffectsComponent end)
    if u.valid(ge) then
        for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
            each(u.try(function() return ge[f] end), function(x) if u.valid(x) then s.ge[#s.ge + 1] = u.class_word(x) end end, 64)
        end
        pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) s.tags[#s.tags + 1] = u.str(unwrap(t).TagName) end) end)
    end
    local sk = u.try(function() return pc.SkillComponent end)
    each(sk and u.try(function() return sk.Skills end), function(x)
        local d = u.try(function() return x.SkillData end)
        if u.valid(d) then s.skills[u.short(d)] = u.try(function() return sk:GetSkillLevel(d) end) end
    end, 32)
    s.position = to_m(u.try(function() return pawn:K2_GetActorLocation() end))
    return s
end

-- The game's own special-requirement check (L1): the spell's SpecialRequirementsStrategy default object
-- -> AreSpecialRequirementsMet(local PC) (BlueprintNativeEvent, const; the call the game makes). It
-- answers a failure FGameplayTag, "None" when met. Verified live on all 14 strategy classes (20:05).
-- -> failure tag (string) | nil (met, or the spell has no requirement)
function W.requirement(api, st)
    if not st.req_class then return nil end
    local u = U()
    local pc = W.pc(api)
    local cdo = u.try(function() return st.req_class:GetCDO() end)
    if not (u.valid(pc) and u.valid(cdo)) then return nil end
    local ok, tag = pcall(function() return cdo:AreSpecialRequirementsMet(pc) end)
    if not ok then return nil end
    local name = u.str(u.try(function() return tag.TagName end))
    if (not name) and type(tag) == "table" and tag.TagName then name = tostring(tag.TagName) end
    if not name or name == "" or name == "None" then return nil end
    return name
end

-- Every spell asset the game has loaded (for the locked list).
function W.all_spells()
    local out = {}
    for _, o in ipairs(U().find_all("UtilitySpellData", { skip_defaults = true })) do out[#out + 1] = o end
    return out
end

-- The input actions, read from the live UI objects (no asset paths in code).
function W.actions(api)
    local u = U()
    local pc = W.pc(api)
    local a = { quick = {} }
    local sc = pc and u.try(function() return pc.SpellcastingComponent end)
    if u.valid(sc) then
        a.place = u.try(function() return sc.PlaceSpellInputAction end)
        a.cancel = u.try(function() return sc.CancelSpellInputAction end)
    end
    for _, p in ipairs(u.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (u.fullname(p) or ""):find("WidgetTree", 1, true) then
            a.menu = u.try(function() return p.TriggerSpellRadialInputAction end)
            a.next_page = u.try(function() return p.ChangeSpellRadialRightInputAction end)
            a.accept = u.try(function() return p.GenericAcceptInputAction end)
            local rw = u.try(function() return p.SpellRadialWidget end)
            each(rw and u.try(function() return rw.QuickAccessInputActions end), function(x) a.quick[#a.quick + 1] = x end, 16)
            break
        end
    end
    return a
end

-- The icons the open wheel page shows, by slice (1-based = slot within the page + 1), or nil.
function W.shown_icons(api)
    local u = U()
    for _, p in ipairs(u.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (u.fullname(p) or ""):find("WidgetTree", 1, true) then
            local rw = u.try(function() return p.SpellRadialWidget end)
            local out = {}
            each(rw and u.try(function() return rw.Slices end), function(sl)
                local n = u.try(function() return sl.SpellSlotNum end)
                local ic = u.short(u.try(function() return sl.SliceIcon.Brush.ResourceObject end))
                if type(n) == "number" then out[n + 1] = ic or false end
            end, 32)
            return next(out) and out or nil
        end
    end
    return nil
end

-- Point at one slice of the open wheel (the radial's own BlueprintCallable HighlightSlice handler, what
-- hovering runs; live 21:1x: HighlightSlice(9) -> CachedSectionId 9 and SpellName "Enchant Weapon: Air",
-- sticky over the next frames) and read back what the wheel now shows. -> {section, name} | nil
function W.highlight(api, slot)
    local u = U()
    for _, p in ipairs(u.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (u.fullname(p) or ""):find("WidgetTree", 1, true) then
            local rw = u.try(function() return p.SpellRadialWidget end)
            if not u.valid(rw) then return nil end
            if not pcall(function() rw:HighlightSlice(slot) end) then return nil end
            return { section = u.try(function() return rw.CachedSectionId end), name = u.str(u.try(function() return rw.SpellName:GetText() end)) }
        end
    end
    return nil
end

-- The game's own centre of a thing when its actor origin is not where it lies: ATreeLog (felled logs,
-- splittable logs) -> GetMidPointWorldLocation (FVector out param; gather.lua reads it the same way).
-- -> [x, y, z] metres | nil
function W.thing_center(api, t)
    local u = U()
    local a = api.actor_of and api.actor_of(t)
    if not u.valid(a) then return nil end
    local cls = u.find_object("/Script/Dominion.TreeLog")
    if not (cls and u.try(function() return a:IsA(cls) end) == true) then return nil end
    local mid = {}
    local ok = pcall(function() a:GetMidPointWorldLocation(mid) end)
    if ok and type(mid.X) == "number" and (mid.X ~= 0 or mid.Y ~= 0) then return { mid.X / 100, mid.Y / 100, (mid.Z or 0) / 100 } end
    return nil
end

-- This client's world clock in seconds (UGameplayStatics::GetTimeSeconds), or nil.
local GST
function W.clock(api)
    local u = U()
    if not (GST and u.valid(GST)) then GST = u.find_object("/Script/Engine.Default__GameplayStatics") end
    local pawn = W.pawn(api)
    if not (GST and pawn) then return nil end
    local v = u.try(function() return GST:GetTimeSeconds(pawn) end)
    return type(v) == "number" and v or nil
end

-- One frame of an Enhanced Input action (the shared helper combat.lua verified live).
function W.inject(api, action)
    local u = U()
    if not u.valid(action) then return false end
    local c = api.module("combat")
    if c and type(c._inject) == "function" then return c._inject(action) == true end
    local s = u.find_first("EnhancedInputLocalPlayerSubsystem")
    return s ~= nil and pcall(function() s:InjectInputVectorForAction(action, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
end

-- Aim the camera at a point (metres): control rotation from the camera location, as the mouse does.
-- -> distance camera->point in metres, or nil
function W.aim(api, pos)
    local u = U()
    local pc = W.pc(api)
    if not (u.valid(pc) and pos) then return nil end
    local cam = to_m(u.try(function() return pc.PlayerCameraManager:GetCameraLocation() end))
    if not cam then
        api.aim_at(pos)
        local me = api.my_position()
        return me and d3(me, pos)
    end
    local dx, dy, dz = pos[1] - cam[1], pos[2] - cam[2], (pos[3] or cam[3]) - cam[3]
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The spell the game has selected now (SpellcastingComponent:GetCurrentlySelectedSpellData, pure).
function W.selected(api)
    local u = U()
    local pc = W.pc(api)
    local sc = pc and u.try(function() return pc.SpellcastingComponent end)
    return u.valid(sc) and u.short(u.try(function() return sc:GetCurrentlySelectedSpellData() end)) or nil
end

-- The game's own placement preview for OUR cast (AUtilitySpellPlacementVisualizer): the green/red
-- check a player sees. -> {valid, tag, position} | nil
function W.preview(api)
    local u = U()
    local pawn = W.pawn(api)
    local me = pawn and u.short(pawn)
    for _, v in ipairs(u.find_all("UtilitySpellPlacementVisualizer", { skip_defaults = true })) do
        local c = u.try(function() return v:GetCastingPlayerCharacter() end)
        local mine = (u.valid(c) and u.short(c) == me) or (u.try(function() return v:IsLocallyControlled() end) == true)
        if mine then
            local tag = u.str(u.try(function() return v.CurrentAdditionalValidationInfo.TagName end))
            return { valid = u.try(function() return v.bCurrentPlacementValid end) == true,
                     tag = (tag and tag ~= "" and tag ~= "None") and tag or nil,
                     position = to_m(u.try(function() return v:K2_GetActorLocation() end)), id = u.short(v) }
        end
    end
    return nil
end

-- Candidate spots for a placed spell, best first: around `center` (a target, metres; the target
-- itself first) or around me. Each: 3x3 downward traces 1.5 m apart (height spread, centre normal), a
-- 3 m clearance trace up and line of sight from my chest (the trace call move.lua uses).
-- -> {{position, spread_m, normal_z, exact}}
function W.spots(api, center, opts)
    opts = opts or {}
    local u = U()
    local pawn = W.pawn(api)
    if not u.valid(pawn) then return {} end
    local cfg = M.cfg
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local function trace(a, b)
        local out = {}
        local ok, hit = pcall(function() return KSL:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0) end)
        return ok and hit == true, out
    end
    local me = u.loc(pawn)
    local players = W.players(api)
    local pts = {}
    if center then
        local cz = (center[3] or me.Z / 100) * 100
        pts[1] = { center[1] * 100, center[2] * 100, cz, exact = true }
        for _, r in ipairs({ 2, 3.5 }) do for i = 0, 7 do
            local a = math.rad(i * 45)
            pts[#pts + 1] = { center[1] * 100 + r * 100 * math.cos(a), center[2] * 100 + r * 100 * math.sin(a), cz }
        end end
    else
        for _, r in ipairs(opts.rings or cfg.spot_rings_m) do for i = 0, 11 do
            local a = math.rad(i * 30)
            pts[#pts + 1] = { me.X + r * 100 * math.cos(a), me.Y + r * 100 * math.sin(a), me.Z }
        end end
    end
    local out = {}
    for _, p in ipairs(pts) do
        local clear = true
        if not center then
            for _, pl in ipairs(players) do
                local pp = pl.position
                if pp and math.sqrt((pp[1] * 100 - p[1]) ^ 2 + (pp[2] * 100 - p[2]) ^ 2) < cfg.spot_player_clear_m * 100 then clear = false end
            end
        end
        if clear then
            local zs, zc, nz = {}, nil, nil
            for dx = -1, 1 do for dy = -1, 1 do
                local hit, o = trace({ X = p[1] + dx * 150, Y = p[2] + dy * 150, Z = p[3] + 400 }, { X = p[1] + dx * 150, Y = p[2] + dy * 150, Z = p[3] - 600 })
                local z = hit and o.ImpactPoint and o.ImpactPoint.Z or nil
                if z then zs[#zs + 1] = z end
                if dx == 0 and dy == 0 then zc, nz = z, hit and o.ImpactNormal and o.ImpactNormal.Z or nil end
            end end
            if zc and #zs == 9 then
                local lo, hi = math.huge, -math.huge
                for _, z in ipairs(zs) do lo = math.min(lo, z); hi = math.max(hi, z) end
                local spread = (hi - lo) / 100
                local up = trace({ X = p[1], Y = p[2], Z = zc + 50 }, { X = p[1], Y = p[2], Z = zc + 350 })
                local los = opts.los ~= false and trace({ X = me.X, Y = me.Y, Z = me.Z + 50 }, { X = p[1], Y = p[2], Z = zc + 80 }) or false
                if not up and not los and spread <= cfg.spot_max_spread_m and (nz or 0) >= cfg.spot_min_normal_z then
                    out[#out + 1] = { position = { p[1] / 100, p[2] / 100, zc / 100 }, spread_m = math.floor(spread * 100) / 100,
                                      normal_z = nz and math.floor(nz * 1000) / 1000, exact = p.exact }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.exact == true) ~= (b.exact == true) then return a.exact == true end
        return a.spread_m < b.spread_m
    end)
    return out
end

-- A foliage id from look ("fol:<component>:<index>": a standing tree, bush, ...) that the bridge's
-- capped census did not return: ask sense's own foliage reader around me (what look and gather use).
-- -> {id, name, position (metres)} | nil (gone: felled, picked, or out of range)
function W.foliage_thing(api, id)
    local s = api.module("sense")
    local pawn = W.pawn(api)
    if not (s and type(s.foliage) == "function" and pawn) then return nil end
    local here = U().loc(pawn)
    local ok, rows = pcall(s.foliage, here, 6000, {})
    if not ok or type(rows) ~= "table" then return nil end
    for _, r in ipairs(rows) do
        if r.id == id then
            local p = r.position
            if type(p) == "table" and type(p[1]) ~= "number" and p.X then p = { p.X / 100, p.Y / 100, p.Z / 100 } end
            return { id = r.id, name = r.name, position = p }
        end
    end
    return nil
end

-- Players around: {{name, id, position}} (census, metres).
function W.players(api)
    local things = api.census_things(40, 20) or {}
    local out = {}
    for _, t in ipairs(things) do if t.kind == "player" or t.category == "players" then out[#out + 1] = t end end
    return out
end

-- Client RPC post-hooks (read-only): the server's own "on cooldown" / "cancelled" verdicts.
M.HOOKS = {
    { path = "/Script/Dominion.PlayerUtilityMagicComponent:Client_NotifySpellOnCooldown", ev = "on_cooldown" },
    { path = "/Script/Dominion.SpellcastingComponent:Client_CancelSpellcasting", ev = "cancelled" },
}
function W.hooks_start()
    local m = mem()
    for _, h in ipairs(M.HOOKS) do
        if not m.hooks[h.path] and type(RegisterHook) == "function" then
            local ok = pcall(RegisterHook, h.path, function() local mm = mem(); mm.events[#mm.events + 1] = { ev = h.ev, t = os.clock() } end)
            m.hooks[h.path] = ok and "ok" or "failed"
        end
    end
end

-- ------------------------------------------------------------------ listing
local function rows_of(api, snap, all)
    local m = mem()
    local now_local = api.now()
    local out, seen = {}, {}
    snap.req = snap.req or {}
    for id, obj in pairs(snap.objects) do
        local st = W.static(obj)
        snap.req[id] = W.requirement(api, st)
        out[#out + 1] = M.row(st, snap, m.cast_at[id], now_local)
        seen[id] = true
    end
    local locked_n = 0
    if all then
        for _, obj in ipairs(W.all_spells()) do
            local st = W.static(obj)
            -- only real player spells: ones a perk unlocks (internal/unreleased assets have none)
            if not seen[st.asset] and st.perk and st.perk.level then
                seen[st.asset] = true
                locked_n = locked_n + 1
                out[#out + 1] = M.row(st, snap, nil, now_local)
            end
        end
    end
    -- castable first (consumers like brain/spells.py keep only the first rows), then what a little
    -- time or a few runes would fix, then what needs the wheel, then locked; by name within each
    local rank = { on_cooldown = 1, busy = 1, requirement = 2, not_enough_resources = 2, not_on_wheel = 3, not_unlocked = 4 }
    table.sort(out, function(a, b)
        local ra, rb = a.castable and 0 or (rank[a.reason] or 3), b.castable and 0 or (rank[b.reason] or 3)
        if ra ~= rb then return ra < rb end
        return tostring(a.name) < tostring(b.name)
    end)
    return out, locked_n
end
M._rows_of = rows_of

local function list(api, args)
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    local snap = W.snapshot(api)
    if not snap then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    local rows, locked_n = rows_of(api, snap, args and args.all == true)
    local n = 0
    for _, r in ipairs(rows) do if r.unlocked then n = n + 1 end end
    return { ok = true, data = { spells = rows, unlocked_n = n, locked_listed = locked_n,
                                 summary = n == 0 and "I haven't unlocked any spells yet." or nil } }
end

-- ------------------------------------------------------------------ casting
local function in_spell_mode(mode) return M.cfg.spell_modes[mode or ""] == true end

local function target_of(api, target, snap)
    -- -> {kind = "self"|"point"|"thing"|"player", position, name, id} | nil, failure
    if target == nil or target == "" or target == "self" or target == "me" then return { kind = "self", position = snap.position } end
    if type(target) == "table" and type(target[1]) == "number" then
        return { kind = "point", position = { target[1], target[2], target[3] or (snap.position and snap.position[3]) or 0 } }
    end
    if type(target) ~= "string" then return nil, api.fail("invalid_args", { detail = "target must be 'self', an id from look, a player or [x, y, z]" }) end
    for _, p in ipairs(W.players(api)) do
        if p.id == target or lower(p.name) == lower(target) then return { kind = "player", position = p.position, name = p.name, id = p.id } end
    end
    local t, r = api.find_thing(target)
    if not t and target:sub(1, 4) == "fol:" then t = W.foliage_thing(api, target) end
    if not t then
        local d = copy(r and r.data)
        d.detail = target:sub(1, 4) == "fol:" and ("I can't see that " .. "tree or plant any more (" .. target .. "); it may have been felled or picked.")
            or ("I can't see " .. target .. " to aim at.")
        return nil, api.fail("unknown_target", d)
    end
    -- where the thing really is: felled logs roll away from their stale actor origin (DISCOVERIES:
    -- aim at the game's own ATreeLog::GetMidPointWorldLocation; L15 live: the preview fell 1-3.5 m
    -- past the origin with "requires log")
    local pos, where = t.position, nil
    local c = W.thing_center(api, t)
    if c then pos, where = c, "midpoint" end
    return { kind = "thing", position = pos, name = t.name, id = t.id, foliage = target:sub(1, 4) == "fol:" or nil, aim_from = where }
end

local function arbiter(api) local A = api.module("arbiter"); return A and type(A.request) == "function" and A or nil end

local function new_cast(api, args)
    if paused() then return nil, api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    local snap = W.snapshot(api)
    if not snap then return nil, api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    local rows = rows_of(api, snap, false)
    local row, why, data = M.resolve(rows, args.spell)
    if not row then
        -- a locked spell named exactly: say what unlocks it
        if why == "unknown_target" then
            local all = rows_of(api, snap, true)
            for _, r in ipairs(all) do
                if not r.unlocked and (norm_name(r.name) == norm_name(args.spell) or norm_name(r.id) == norm_name(args.spell)) then
                    return nil, api.fail("not_unlocked", { spell = r.name, needs = r.needs, detail = r.detail, candidates = data.candidates })
                end
            end
        end
        return nil, api.fail(why, data)
    end
    local st = W.static(snap.objects[row.id])
    local d = { spell = row.name, id = row.id, cast_type = row.cast_type }
    if data and data.matched then d.matched = data.matched end
    -- Fresh, hard gates block (unlock, wheel, runes, mid-air). A cooldown or "already casting" read
    -- may be stale or rest on the clock mapping: the attempt goes ahead and the game's verdict (the
    -- server's cooldown RPC, verification) decides; the pre-check is reported in data.precheck.
    if not row.castable then
        if row.reason == "on_cooldown" or (row.reason == "busy" and not snap.falling) then
            d.precheck, d.precheck_detail = row.reason, row.detail
        else
            d.why, d.detail, d.remaining_s, d.cost = row.reason, row.detail, row.remaining_s, row.cost
            return nil, api.fail(row.reason, d)
        end
    end
    local tg, tf = target_of(api, args.target, snap)
    if not tg then return nil, tf end
    local placed = row.cast_type == "placed" or row.cast_type == "aimed"
    if not placed and tg.kind ~= "self" then d.target_ignored = true; tg = { kind = "self", position = snap.position } end
    local at = tg.position
    if placed and tg.kind == "self" then at = nil end -- "in front of me": landing point unknown before the cast
    local harm = M.harm_check({ name = row.name, harmful = st.harmful, has_shape = st.has_shape, role = st.role,
                                cast_type = st.cast_type, radius_m = st.radius_m },
                              tg.kind == "player" and tg.name or nil, at, W.players(api))
    if harm then
        d.player, d.dist_m, d.radius_m, d.detail = harm.player, harm.dist_m, harm.radius_m, harm.detail
        return nil, api.fail("unsafe", d)
    end
    local acts = W.actions(api)
    local per = snap.per_radial or 12
    local slot = row.wheel_slot % per -- the key within the page
    if not (acts.menu and (acts.quick[slot + 1] or acts.accept)) then
        d.detail = "I can't find the spell wheel's controls right now."
        return nil, api.fail("verification_failed", d)
    end
    if placed and not (acts.place and acts.cancel) then
        d.detail = "I can't find the controls to place " .. row.name .. "."
        return nil, api.fail("verification_failed", d)
    end
    if not st.icon then
        d.detail = "I can't tell which page of my spell wheel holds " .. row.name .. "."
        return nil, api.fail("verification_failed", d)
    end
    local job = { api = api, row = row, st = st, d = d, acts = acts, slot = slot, target = tg, placed = placed, pages = snap.radials or 4,
                  before = snap, phase = "own", t0 = api.now(), presses = {} }
    return job
end

local function release(job, why)
    if job.token and not job.released then
        job.released = true
        local A = arbiter(job.api)
        if A then
            local ok, r = pcall(A.release, job.api.log, job.token, why)
            if ok and type(r) == "table" and r.resumed then job.d.resumed = r.resumed end
        end
    end
end

-- Leave no spell UI open (every exit path, never while paused).
local function cleanup(job)
    if job.cleaned then return end
    job.cleaned = true
    if not paused() then
        local snap = W.snapshot(job.api)
        local mode = snap and snap.input_mode
        if mode and mode ~= M.cfg.gameplay_mode and (in_spell_mode(mode) or mode == M.cfg.radial_mode) then
            -- the wheel closes with its own key (Q again); a placement/aim mode with Cancel (Esc)
            W.inject(job.api, (mode == M.cfg.radial_mode and job.acts.menu) or job.acts.cancel or job.acts.menu)
            job.d.cancelled_mode = mode
        end
    end
    release(job, job.d.why or "done")
end

local function press(job, name, action)
    job.presses[#job.presses + 1] = name
    return W.inject(job.api, action)
end

-- Drop spots at least as uneven as one the game already called "not flat" (learned this session).
function M.filter_spots(spots, bad_spread)
    if not bad_spread then return spots or {} end
    local out = {}
    for _, x in ipairs(spots or {}) do if (x.spread_m or 0) < bad_spread then out[#out + 1] = x end end
    return out
end

-- A game validation tag in words: "UI.Notification.SpellPlacement.GroundNotFlatEnough" -> "ground not flat enough".
function M.tag_words(tag)
    if not tag then return "it isn't allowed there" end
    local last = tostring(tag):match("([%w_]+)$") or tostring(tag)
    return (last:gsub("(%l)(%u)", "%1 %2"):lower())
end

-- What changed since the cast started (pure on two snapshots).
function M.diff(before, after, st)
    local out = { runes_spent = {}, ge_added = {}, tags_added = {}, actors_added = {} }
    for _, c in ipairs(st.cost or {}) do
        local b, a = (before.items or {})[c.item] or 0, (after.items or {})[c.item] or 0
        if a < b then out.runes_spent[c.item] = b - a; out.spent = true end
    end
    local lb, la = (before.last_cast or {})[st.asset], (after.last_cast or {})[st.asset]
    if la ~= nil and la ~= lb then out.cooldown_started = true end
    local function added(b, a, dst)
        local seen = {}
        for _, x in ipairs(b or {}) do seen[x] = (seen[x] or 0) + 1 end
        for _, x in ipairs(a or {}) do if (seen[x] or 0) > 0 then seen[x] = seen[x] - 1 else dst[#dst + 1] = x end end
    end
    added(before.ge, after.ge, out.ge_added)
    added(before.tags, after.tags, out.tags_added)
    for id, a in pairs(after.actors or {}) do if not (before.actors or {})[id] then out.actors_added[#out.actors_added + 1] = { id = id, class = a.class, position = a.position } end end
    return out
end

-- (the shared failure shape; `failed` below is the same, defined later for the state machine)
function M._fail(job, reason, why, detail)
    job.d.why, job.d.detail, job.d.presses = why, detail, job.presses
    return { ok = false, reason = reason, data = job.d }
end

-- Aim candidates for what was asked for: a thing (its body at a few heights; compared in 2D), a
-- point (itself), or nothing (keep the current, straight-ahead aim). Pure.
function M.target_candidates(target, cfg)
    cfg = cfg or M.cfg
    local p = target and target.kind ~= "self" and target.position or nil
    if not p then return { { here = true } } end
    if target.kind == "point" then return { { position = { p[1], p[2], p[3] or 0 }, exact = true } } end
    local out = {}
    for _, h in ipairs(target.foliage and cfg.aim_heights_m or cfg.actor_aim_heights_m) do
        out[#out + 1] = { position = { p[1], p[2], (p[3] or 0) + h }, aim = true, height_m = h }
    end
    return out
end

-- Does the game's validation tag complain about the GROUND (so flat-spot search can help)?
function M.ground_tag(tag)
    local t = tostring(tag or ""):lower()
    return t:find("flat", 1, true) ~= nil or t:find("ground", 1, true) ~= nil or t:find("blocked", 1, true) ~= nil
        or t:find("slope", 1, true) ~= nil or t:find("surface", 1, true) ~= nil
end

-- Append flat clear ground spots (traces; around the target or me) after the current candidate.
function M.add_ground_spots(job, api)
    job.ground_added = true
    local around = job.target.kind ~= "self" and job.target.position or nil
    for _, x in ipairs(M.filter_spots(W.spots(api, around), job.bad_spread)) do job.spots[#job.spots + 1] = x end
end

-- The one placement/aim failure answer: too far, the game's ground verdict (+ a flat-ground hint),
-- or "couldn't line it up" with the game's own words. The spell is cancelled by cleanup (never cast).
function M.placement_failure(job, api, lim)
    local cfg = M.cfg
    local tag, far, ground
    for _, r in ipairs(job.rejects or {}) do
        if r.game and not tag then tag = r.game end
        if r.game and M.ground_tag(r.game) then ground = r.game end
        if r.why == "too_far" then far = r.dist_m end
    end
    local what = job.target.name or (job.target.kind ~= "self" and "the target") or nil
    if far and not tag then
        return M._fail(job, "too_far", "too_far", "That's too far away for " .. job.row.name .. ": it's " .. math.floor(far + 0.5)
            .. " m from my view and I can reach about " .. math.floor(lim) .. " m, so I need to get closer.")
    end
    if ground and job.ground_ok then
        local hint = ""
        local farspots = W.spots(api, nil, { rings = cfg.far_rings_m, los = false })
        local best = M.filter_spots(farspots, job.bad_spread)[1]
        if best and job.before.position then
            local dd = d3(best.position, job.before.position)
            job.d.flat_spot, job.d.flat_spot_dist_m = best.position, dd and math.floor(dd + 0.5)
            hint = " The flattest ground I can see is about " .. tostring(job.d.flat_spot_dist_m) .. " m away; I could walk there and try again."
        end
        return M._fail(job, "nothing_in_range", "no_valid_spot", "I couldn't find a spot the game accepts for " .. job.row.name ..
            " near " .. (what and "there" or "me") .. " (the game says: " .. M.tag_words(ground) .. "), so I cancelled the spell." .. hint)
    end
    return M._fail(job, "verification_failed", "no_valid_aim", "I couldn't line " .. job.row.name .. " up on " .. (what or "anything in front of me")
        .. (tag and (" (the game says: " .. M.tag_words(tag) .. ")") or "") .. ", so I cancelled the spell; I may need to stand closer or face it from another side.")
end

-- The new spell actor that is THIS cast's: the one nearest the preview / chosen spot (within 4 m).
function M.own_actor(job, df)
    local ref = job.d.preview_at or job.d.spot
    if not ref or not df then return nil end
    local best, bd
    for _, a in ipairs(df.actors_added or {}) do
        local d = a.position and d3(a.position, ref)
        if d and d <= 4 and (not bd or d < bd) then best, bd = a, d end
    end
    return best
end

local function verified_result(job, df, snap)
    local d = job.d
    d.verified = true
    -- how far the cast moved me (dash / leap spells), from fresh positions
    if snap and snap.position and job.before.position then d.moved_m = math.floor(d3(snap.position, job.before.position) * 100 + 0.5) / 100 end
    d.runes_spent, d.cooldown_started = df.runes_spent, df.cooldown_started == true
    d.effects = { ge = df.ge_added, tags = df.tags_added }
    d.effect_verified = (#df.ge_added + #df.tags_added + #df.actors_added) > 0
    local a = M.own_actor(job, df) or df.actors_added[1]
    if a then
        d.spell_actor, d.landed_at = a.id, a.position
        if job.target.kind ~= "self" and a.position and job.target.position then
            d.landed_dist_m = math.floor(d3(a.position, job.target.position) * 10 + 0.5) / 10
        end
    end
    if job.target.kind ~= "self" then d.target = job.target.name or job.target.position end
    if job.target.kind == "thing" and job.target.id then
        -- what happened to the target (a tree hit by an aimed spell): gone (felled) or its health now
        local api = job.api
        local tt = select(1, api.find_thing(job.target.id))
        if not tt and tostring(job.target.id):sub(1, 4) == "fol:" then tt = W.foliage_thing(api, job.target.id) end
        d.target_after = tt and "still_there" or "gone"
        if tt and tt.health then d.target_health = tt.health end
    end
    d.presses = job.presses
    mem().cast_at[job.row.id] = job.api.now()
    -- it went off, but not where asked: say so (the brain voices failures, not ok results)
    local tol = math.max(job.st.radius_m or 0, M.cfg.landed_tolerance_m)
    if d.landed_dist_m and d.landed_dist_m > tol then
        d.why = "landed_elsewhere"
        d.detail = "I cast " .. job.row.name .. " but it landed " .. math.floor(d.landed_dist_m + 0.5) .. " m from where you wanted."
        return { ok = false, reason = "verification_failed", data = d }
    end
    return { ok = true, data = d }
end

local function failed(job, reason, why, detail)
    job.d.why, job.d.detail, job.d.presses = why, detail, job.presses
    return { ok = false, reason = reason, data = job.d }
end

-- One step of the cast state machine; nil = carry on, else the result.
local function step(job)
    -- sub-second clock: the bridge's api.now() is os.time (1 s steps), too coarse for 0.35 s preview waits
    local api, cfg = job.api, M.cfg
    local t = W.clock(api) or api.now()
    if paused() then return failed(job, "companion_down", "paused", "I'm not in the world right now.") end
    if job.phase == "settle" then
        -- a wheel / placement left open by an earlier attempt: wait until it has closed, then open ours
        local s0 = W.snapshot(api)
        if s0 and s0.input_mode ~= cfg.gameplay_mode and t < job.until_t then return nil end
        job.phase, job.until_t, job.tries = "open", t + cfg.open_wait_s, 1
        press(job, "menu", job.acts.menu)
        return nil
    end
    if job.phase == "own" then
        local A = arbiter(api)
        if A then
            local r = A.request(api.log, { name = "spell:" .. job.row.id, level = cfg.level, uses_move = job.placed, lease_s = cfg.lease_s,
                                           resumable = false, on_stop = function(_, _, why) job.stopped = why or "stopped" end })
            if not (type(r) == "table" and r.ok) then
                local o = type(r) == "table" and r.owner or nil
                local fighting = type(o) == "table" and (o.level == "reflex" or o.level == 4)
                return failed(job, "busy", fighting and "fighting" or "pawn_busy", fighting and "I can't cast while I'm fighting yet."
                    or ("I can't cast right now, I'm busy with " .. tostring(type(o) == "table" and o.name or "something") .. "."))
            end
            job.token = r.token
            if type(r.preempted) == "table" then job.d.preempted = r.preempted.name; job.d.preempted_suspended = r.preempted.suspended end
        end
        W.hooks_start()
        job.ev0 = #mem().events
        local m0 = job.before.input_mode
        if m0 and m0 ~= cfg.gameplay_mode and (in_spell_mode(m0) or m0 == cfg.radial_mode) then
            job.d.closed_previous = m0
            press(job, "close_previous", (m0 == cfg.radial_mode and job.acts.menu) or job.acts.cancel)
            job.phase, job.until_t = "settle", t + 1.5
            return nil
        end
        job.phase, job.until_t, job.tries = "open", t + cfg.open_wait_s, 1
        press(job, "menu", job.acts.menu)
        return nil
    end
    if job.stopped then return failed(job, "interrupted", "stopped", "Something else took over (" .. tostring(job.stopped) .. "), so I stopped casting.") end
    if job.token then local A = arbiter(api); if A and A.renew then pcall(A.renew, job.token) end end
    local snap = W.snapshot(api)
    if not snap then return failed(job, "companion_down", "no_pawn", "I'm not in the world right now.") end
    -- the server's own verdicts (Client RPC hooks)
    local evs = mem().events
    for i = (job.ev0 or 0) + 1, #evs do
        if evs[i].ev == "on_cooldown" and not job.cd_seen then job.cd_seen = t end
    end
    local df = M.diff(job.before, snap, job.st)
    if df.spent or df.cooldown_started or M.own_actor(job, df) then
        -- it went off. Don't press Esc into the cast animation: let the game leave its spell mode first
        -- (live 21:2x Splinter: the spell actor appeared while still in DIM_SpellcastingMode), up to
        -- finish_s; then answer with the full evidence (the rune spend may land a moment later)
        job.finish_until = job.finish_until or (t + cfg.finish_s)
        if in_spell_mode(snap.input_mode) and t < job.finish_until then return nil end
        job.succeeded = true
        return verified_result(job, df, snap)
    end
    -- the server said "on cooldown": give a just-cast spell a moment to show its rune spend / cooldown
    -- (L13: a retry got server_cooldown right after a cast that DID go off) before believing it
    if job.cd_seen and t >= job.cd_seen + cfg.cooldown_grace_s then
        return failed(job, "on_cooldown", "server_cooldown", job.row.name .. " is still recharging.")
    end
    local mode = snap.input_mode
    if job.phase == "open" then
        if mode == cfg.radial_mode then
            if job.page_wait and t < job.page_wait then return nil end
            -- press the key only when the open page shows THIS spell in that slot (never cast another)
            local icons = W.shown_icons(api)
            if not icons then return failed(job, "verification_failed", "wheel_unreadable", "I can't read my spell wheel right now.") end
            local sig = table.concat((function() local o = {}; for i = 1, #icons do o[i] = tostring(icons[i]) end; return o end)(), "|")
            -- after a page turn, wait (up to page_max_s) until the slices actually show the new page
            if job.page_sig and sig == job.page_sig and t < (job.page_deadline or 0) then return nil end
            job.page_sig = sig
            if icons[job.slot + 1] == job.st.icon then
                if job.slot < cfg.quick_keys and job.acts.quick[job.slot + 1] then
                    job.phase, job.until_t = "select", t + cfg.select_wait_s
                    press(job, "quick" .. job.slot, job.acts.quick[job.slot + 1])
                    return nil
                end
                -- slots without a number key (9-12): point at the slice like the mouse does (the radial's
                -- own HighlightSlice handler), CHECK the wheel now names this spell, then press accept.
                -- Never accept a slice that names another spell.
                local hl = W.highlight(api, job.slot)
                if not (hl and hl.section == job.slot and norm_name(hl.name) == norm_name(job.row.name)) then
                    return failed(job, "verification_failed", "highlight_mismatch", "I couldn't point at " .. job.row.name .. " on my spell wheel"
                        .. ((hl and hl.name and hl.name ~= "") and (" (it showed " .. hl.name .. ")") or "") .. ", so I didn't pick anything.")
                end
                job.d.picked = "pointer"
                job.phase, job.until_t = "select", t + cfg.select_wait_s
                press(job, "accept", job.acts.accept)
                return nil
            end
            job.flips = (job.flips or 0) + 1
            if job.flips > job.pages or not job.acts.next_page then
                return failed(job, "verification_failed", "page_not_found", "I couldn't find " .. job.row.name .. " on my spell wheel's pages.")
            end
            press(job, "next_page", job.acts.next_page)
            job.page_wait, job.page_deadline = t + cfg.page_wait_s, t + cfg.page_max_s
            job.until_t = t + cfg.open_wait_s + cfg.page_max_s
            return nil
        end
        if t >= job.until_t then
            if job.tries < cfg.open_tries then
                job.tries, job.until_t = job.tries + 1, t + cfg.open_wait_s
                press(job, "menu", job.acts.menu)
                return nil
            end
            return failed(job, "verification_failed", "wheel_not_opened", "My spell wheel didn't open (input mode stayed " .. tostring(mode) .. ").")
        end
        return nil
    end
    if job.phase == "select" then
        if in_spell_mode(mode) then
            -- placed / aimed (or a spell the game wants confirmed): check it is OUR spell, aim, release LMB
            local sel = W.selected(api)
            if sel and sel ~= job.row.id then
                return failed(job, "verification_failed", "wrong_spell", "My wheel picked a different spell than " .. job.row.name .. ", so I cancelled.")
            end
            local aimed_at = job.target.kind ~= "self" and job.target.position or nil
            -- ONE loop for every spell that shows the game's preview (placed, or aimed with a visualizer):
            -- aim at what was asked for (a thing's body at a few heights, a point, or straight ahead),
            -- re-read the preview, release LMB only when it is valid and on target. Flat-ground spots
            -- are added only when the game's own validation tag talks about the ground (not flat /
            -- blocked), or for a placed spell given no target after "straight ahead" was refused.
            -- (L14/L15: one-shot aims threw at nothing; ground spots never validated on a log.)
            if job.row.cast_type == "placed" or mode == "DIM_SpellPlacementMode" or W.preview(api) then
                job.aim_mode = job.row.cast_type ~= "placed"
                job.ground_ok = job.row.cast_type == "placed"
                job.spots = M.target_candidates(job.target, cfg)
                job.place_deadline = t + cfg.place_budget_s
                job.spot_i, job.rejects, job.phase, job.next_spot = 0, {}, "place_check", true
                return nil
            end
            if aimed_at then
                local dist = W.aim(api, { aimed_at[1], aimed_at[2], (aimed_at[3] or 0) + cfg.aim_heights_m[1] })
                local lim = job.st.reach_m or ((snap.place_max_m and snap.place_max_m > 0) and snap.place_max_m) or cfg.place_max_m
                if dist and dist > lim + 0.5 then
                    return failed(job, "too_far", "too_far", "That's too far away for " .. job.row.name .. ": it's " .. math.floor(dist + 0.5)
                        .. " m from my view and I can reach about " .. math.floor(lim) .. " m, so I need to get closer.")
                end
            end
            job.phase, job.until_t = "verify", t + cfg.verify_s
            press(job, "place", job.acts.place)
            return nil
        end
        if mode ~= cfg.radial_mode and not in_spell_mode(mode) then
            job.phase, job.until_t = "verify", t + cfg.verify_s -- wheel closed: an instant cast is under way
            return nil
        end
        if t >= job.until_t then
            if job.d.precheck == "on_cooldown" then
                return failed(job, "on_cooldown", "cooldown", job.d.precheck_detail or (job.row.name .. " is still recharging."))
            end
            local need = job.st.special_req and (" (the game says it needs: " .. (job.st.special_req:gsub("%s+$", "")) .. ")") or ""
            return failed(job, "verification_failed", "not_selected", "I opened the spell wheel but " .. job.row.name .. " didn't get selected" .. need .. ".")
        end
        return nil
    end
    if job.phase == "place_check" then
        if not in_spell_mode(mode) then
            return failed(job, "verification_failed", "placement_closed", "The placement preview for " .. job.row.name .. " closed before I could place it.")
        end
        local lim = job.st.reach_m or ((snap.place_max_m and snap.place_max_m > 0) and snap.place_max_m) or cfg.place_max_m
        local function give_up()
            job.d.rejected = job.rejects
            return M.placement_failure(job, api, lim)
        end
        if t >= (job.place_deadline or math.huge) then return give_up() end
        if job.next_spot then
            job.next_spot = nil
            while true do -- the next candidate within the camera's reach
                job.spot_i = job.spot_i + 1
                local sp = job.spots[job.spot_i]
                if not sp and job.ground_ok and not job.ground_added and job.target.kind == "self" then
                    M.add_ground_spots(job, api) -- a placed spell with no target: "straight ahead" was refused
                    sp = job.spots[job.spot_i]
                end
                if not sp or job.spot_i > cfg.max_spots then return give_up() end
                if sp.here then break end
                local dist = W.aim(api, sp.position)
                if not dist or dist <= lim + 0.5 then break end
                job.rejects[#job.rejects + 1] = { spot = sp.position, why = "too_far", dist_m = math.floor(dist * 10 + 0.5) / 10 }
            end
            job.spot_t, job.checks = t + cfg.preview_wait_s, 0
            return nil
        end
        if t < job.spot_t then return nil end
        local sp = job.spots[job.spot_i]
        local vis = W.preview(api)
        local near
        if vis and vis.position and sp.position then
            if sp.aim then -- aimed: the preview sits on/at the target, compare in 2D
                near = math.sqrt((vis.position[1] - sp.position[1]) ^ 2 + (vis.position[2] - sp.position[2]) ^ 2)
            else near = d3(vis.position, sp.position) end
        end
        local match = sp.here or not near or near <= (sp.aim and cfg.aim_match_m or cfg.preview_match_m)
        if vis and vis.valid == true and match then
            job.d.spot, job.d.spot_flatness, job.d.preview_at, job.d.aim_height_m = sp.position, sp.spread_m, vis.position, sp.height_m
            if #job.rejects > 0 then job.d.rejected = job.rejects end
            job.phase, job.until_t = "verify", t + cfg.verify_s
            press(job, "place", job.acts.place)
            return nil
        end
        if not vis then
            -- no readable preview: place on our own flattest spot once (the cast is still verified)
            job.d.spot, job.d.preview = sp.position, "unreadable"
            job.phase, job.until_t = "verify", t + cfg.verify_s
            press(job, "place", job.acts.place)
            return nil
        end
        -- re-aim and look again a few times before moving on (the preview follows the camera)
        job.checks = (job.checks or 0) + 1
        if job.checks < cfg.preview_checks then
            if sp.position then W.aim(api, sp.position) end
            job.spot_t = t + cfg.preview_wait_s
            return nil
        end
        job.rejects[#job.rejects + 1] = { spot = sp.position, valid = vis.valid, game = vis.tag, preview_at = vis.position,
                                          spread_m = sp.spread_m, height_m = sp.height_m, off_m = near and math.floor(near * 10 + 0.5) / 10 or nil }
        -- the game's verdict decides the search: a ground complaint brings in flat-ground spots
        if job.ground_ok and not job.ground_added and M.ground_tag(vis.tag) then M.add_ground_spots(job, api) end
        -- learn the game's flatness limit (this cast only): a spot it calls "not flat" bounds the
        -- spread it accepts, so equally uneven candidates are skipped; kept as a hint in mem().bad_spread
        if vis.tag and vis.tag:find("NotFlat", 1, true) and sp.spread_m then
            job.bad_spread = math.min(job.bad_spread or math.huge, sp.spread_m)
            mem().bad_spread = job.bad_spread
            local keep = {}
            for i, x in ipairs(job.spots) do if i <= job.spot_i or (x.spread_m or 0) < job.bad_spread then keep[#keep + 1] = x end end
            job.spots = keep
        end
        job.next_spot = true
        return nil
    end
    -- verify (a placed spell plays its cast animation in a spell input mode first: live, Summon
    -- Shelter spent its runes only after the 4 s window, so keep waiting while the game is casting)
    job.cast_deadline = job.cast_deadline or (t + cfg.cast_max_s)
    if t >= job.until_t and (in_spell_mode(mode) or (snap.casting and snap.casting == job.row.id)) and t < job.cast_deadline then
        return nil
    end
    if t >= job.until_t then
        return failed(job, "verification_failed", "no_effect", "I tried to cast " .. job.row.name .. " but no runes were used and it didn't go on cooldown"
            .. (snap.casting and " (still casting)" or "") .. ".")
    end
    return nil
end
M._step = step

-- After a cast answered "failed", the game may still finish it (a slow animation, a late commit):
-- watch for ~15 s and, if runes fall / the cooldown starts / our spell actor appears, write an
-- activity event so the brain can correct itself ("it did work after all"). Never while paused.
M.LATE_EVENT_PATH = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/") .. "/client_io/events/activity.jsonl"
function M.emit_activity(ev)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local okj, json = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))() end)
    if not okj then return false end
    ev.type, ev.ts = "activity", os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local f = io.open(M.LATE_EVENT_PATH, "a")
    if not f then return false end
    f:write(json.encode(ev), "\n"); f:close()
    return true
end
function M.watch_late(job)
    if type(LoopInGameThreadWithDelay) ~= "function" then return end
    local n, h = 0, nil
    h = LoopInGameThreadWithDelay(1000, function()
        n = n + 1
        local done = n > M.cfg.late_watch_s or paused()
        if not done then
            local snap = W.snapshot(job.api)
            local df = snap and M.diff(job.before, snap, job.st)
            if df and (df.spent or df.cooldown_started or M.own_actor(job, df)) then
                local a = M.own_actor(job, df) or (df.actors_added or {})[1]
                M.emit_activity({ kind = "cast_late_success", by = "spells", spell = job.row.name, id = job.row.id,
                                  runes_spent = df.runes_spent, landed_at = a and a.position or nil, spell_actor = a and a.id or nil,
                                  earlier_reason = job.d.why, detail = "My " .. job.row.name .. " did go off after all." })
                mem().cast_at[job.row.id] = job.api.now()
                done = true
            end
        end
        if done and h then pcall(CancelDelayedAction, h) end
        return done
    end)
end
M.LATE_REASONS = { verification_failed = true, timeout = true, interrupted = true, body_error = true, on_cooldown = true, busy = true }

local function cast(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "spells need the bridge api (ctx.api)" } } end
    local job, f = new_cast(api, args or {})
    if not job then return f end
    local w = { kind = "cast" }
    w.poll = function()
        local ok, res = pcall(step, job)
        if not ok then res = failed(job, "body_error", "error", tostring(res)) end
        if res then
            cleanup(job)
            if not res.ok then
                job.d.why = res.data and res.data.why
                if M.LATE_REASONS[res.reason] and job.presses[1] then pcall(M.watch_late, job) end
            end
            return res
        end
        return nil
    end
    w.expire = function()
        local res = failed(job, "timeout", "timeout", "Casting " .. job.row.name .. " took too long, so I stopped.")
        cleanup(job)
        if job.presses[1] then pcall(M.watch_late, job) end
        return res
    end
    M._last_job = job
    return { wait = w, wait_s = M.cfg.wait_s }
end

M.NEEDS = { cast = { { "sense", "local_pc" }, { "sense", "local_pawn" }, { "sense", "census" } },
            spells = { { "sense", "local_pc" }, { "sense", "local_pawn" } } }
M.HANDLERS = {
    spells = function(log, args, ctx)
        local api = ctx and ctx.api
        if not api then return { ok = false, reason = "body_error", data = { detail = "spells need the bridge api (ctx.api)" } } end
        return list(api, args or {})
    end,
    cast = cast,
}

-- ------------------------------------------------------------------ manifest entries
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    cast = { kind = "waiter", llm = true, moves = false, priority = "command", duration_s = 3, timeout_s = 30,
        detail_is_speech = true,
        description = "Cast one of your spells like a player (spell wheel, then cast); checks runes were used and it went "
            .. "on cooldown. Use a spell from castable_spells/spells, chosen by what its description says it does. Instant "
            .. "spells affect you. Placed spells need flat, open ground: give no target and you pick a spot nearby "
            .. "yourself (flat, clear, accepted by the game's own placement preview), or give a target and you place it there or "
            .. "just beside it. Aimed spells fly toward target (or straight ahead). Never at players. "
            .. "Runs alongside following.",
        args = { type = "object", required = { "spell" }, properties = obj({
            spell = { type = "string", description = "The spell's exact name as listed by spells (e.g. from castable_spells)." },
            target = { description = "Placed/aimed spells only: an id from look, or [x, y, z] metres. Omit: instant spells hit yourself; placed spells go on a valid spot you find nearby.",
                       anyOf = { { type = "string" }, { type = "array", items = { type = "number" }, minItems = 2, maxItems = 3 } } } }) },
        preconditions = { "the spell is unlocked and on your spell wheel", "you carry its runes", "it is not on cooldown" },
        ground = obj({ target = "thing" }),
        reasons = { "unknown_target", "ambiguous_target", "not_unlocked", "not_on_wheel", "not_enough_resources", "on_cooldown",
                    "busy", "unsafe", "too_far", "verification_failed", "interrupted", "timeout" } },
    spells = { kind = "read", llm = true, moves = false, duration_s = 0.2, timeout_s = 10,
        description = "Your spells: each one's name, what it does (the game's description), cast type, rune cost vs what you "
            .. "carry, cooldown left, and whether you can cast it now (and why not). all=true also lists locked spells with "
            .. "the skill level that unlocks them. Read-only.",
        args = { type = "object", properties = obj({
            all = { type = "boolean", default = false, description = "Also list spells you haven't unlocked yet." },
            compact = { type = "boolean", default = true, description = "Ignored (rows are already compact)." } }) } },
}

return M
