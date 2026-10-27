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
    page_wait_s = 0.1,      -- after switching the wheel page: then poll until the slice icons change (live ~0.4 s)
    page_max_s = 1.5,       -- ... and wait up to this long for the slice icons to change
    page_settle_s = 0.2,    -- ... and judge a page only once its slice icons held still this long (T0 2026-10-26:
                            -- with ~38 spells the slices refresh over several frames; a half-drawn page was judged,
                            -- "not here", and turned past: page_not_found after a full lap). DOUBLED each further lap
                            -- (0.2 / 0.4 / 0.8 s): the draw time isn't known, so a missed lap retries slower.
    page_laps = 3,          -- turn at most this many full laps of the wheel before page_not_found
    -- APPROACH (Luis 2026-10-26: Confuse "too_far", the model's go_to + recast took seconds and the magpie moved on):
    -- one cast call does the whole player motion. A target farther than reach - approach_margin_m is approached
    -- (move.go_to on the LIVE target: move tracks a moving actor, its progress tracker judges "can't catch"), the
    -- wheel opens the moment it is in reach, and the aim re-reads its position at release.
    approach_margin_m = 3,  -- camera-to-target reach minus this (the camera sits behind him) = stand-off distance
    approach_budget_s = 20, -- the whole approach; then a truthful "it got away / I can't get there"
    approach_stall_s = 6,   -- no 0.5 m gain on the target for this long = stalled
    reapproach_max = 2,     -- it moved out of reach while the wheel opened: walk again at most this often
    -- HOLD-AND-WALK (cast type instant_after_move = the game's AllowMovementThenCastInstant; Recall: wiki "Leaves a runic
    -- marker on the ground; recasting teleports you back", live 17:35: the spell opens a placement mode you can MOVE in):
    -- cast {spell, walk_to}: open it, walk to walk_to while it is held open, then finish it; the result says where he
    -- ended relative to where it was opened (a jump back there = the return, by position). VERIFIED live 19:39 UTC
    -- (DISCOVERIES "Recall hold-and-walk"): opened at A, walked 10.8 m, the place press teleported him back to A (0.1 m);
    -- a later plain cast returns nowhere (0 m): one cast, no lasting marker, so walk_to is REQUIRED for this cast type.
    hold_walk_budget_s = 25,  -- the walk while held open; then finish it where he is
    hold_return_m = 4,        -- finished within this of the opening point after walking away = returned
    select_wait_s = 1.0,    -- after the quick key: wait for a spell mode or the cast to start
    verify_s = 4.0,         -- after the cast input: runes / cooldown must change within this ...
    cast_max_s = 12,
    late_watch_s = 15,
    cooldown_grace_s = 2,
    settle_after_leave_s = 2, -- ... and this long after leaving a spell's own mode
    mode_linger_s = 1.0,    -- settled: let the game leave its spell mode by itself this long ...
    leave_s = 6,            -- ... then leave it ourselves and wait this long for DIM_Gameplay (live: Oculus exit transition ~3-4 s)
    settle_s = 8,           -- after the first success sign: wait up to this long for runes AND cooldown to replicate   -- after the server's cooldown notice: wait this long for a success signal
    aim_heights_m = { 1.2, 0.8, 1.6, 0.5 }, -- a standing tree / plant (foliage, position = its base): aim at the trunk
    actor_aim_heights_m = { 0.3, 0.0, 0.8, 1.2 }, -- an actor (a log on the ground, a rock; position = its origin)
    aim_match_m = 3,        -- an aimed preview must sit this close (2D) to the target
    preview_checks = 2,     -- re-aim + re-read the preview this many times per candidate
    place_budget_s = 5,     -- the whole aim/placement search; then cancel (never cast it badly)      -- after a failed answer: keep checking this long for a late success        -- ... or, while the game is still casting it (spell input mode / casting state), this
    wait_s = 50,           -- waiter deadline (the bridge answers expire() after it): approach (<= 22 s) + wheel + verify
    typo_cutoff = 0.8,      -- fuzzy name match only above this similarity, and only if unique
    default_radius_m = 5,   -- harm radius when a harmful spell has no Shape module
    place_max_m = 15,       -- fallback camera-to-target limit (SpellcastingComponent.MaxDistanceFromCameraToPlaceSpell)
    landed_tolerance_m = 3, -- a targeted spell that lands farther than max(this, its radius) is reported as a miss
    preview_wait_s = 0.35,  -- after aiming at a spot: let the game's placement preview follow the camera
    preview_match_m = 2.5,  -- the preview must sit this close to the spot aimed at
    placed_point_match_m = 4, -- ... for a placed spell at an asked point (live: the shelter preview centres 3.2 m off the aim point)
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
-- Modes a spell can put the player in that are NOT left with the spell keys (L29): the game's own
-- component on the pawn, its "is active" check and its exit handler (the call the mode's Exit legend
-- runs). DATA from the reflection dump (26161880), one row per game component, not per spell.
M.MODE_EXITS = {
    { component = "OculusComponent", active = "IsOculusActive", exit = "RequestExitOculusMode",
      source = "UOculusComponent (Dominion.hpp:28618); the build legend's Exit; live 2026-10-26 it left DIM_OculusBuildMenu" },
}

-- EUtilitySpellCastType (CXX dump 26161880)
M.CAST_TYPES = { [0] = "instant", [1] = "placed", [2] = "aimed", [3] = "instant_after_move" }
-- Catalog roles (data/spells_<build>.json usage.role, a DATA profile) that mean "this hurts what it
-- hits": refuse at players / near players. Live game data (a Damage module) also counts.
M.HOSTILE_ROLES = { combat_damage = true, combat_cc = true, gathering_aoe = true }
M.AREA_HARM_ROLES = { combat_damage = true, gathering_aoe = true }

local function paused() return rawget(_G, "DW_PAUSE") == true end
-- ONE wall clock for our own cast records (mem().cast_at), whichever api casts: the bridge's api.now()
-- and combat's self-built api use different clocks (live: a 1.79e9 s "cooldown" came from mixing them)
function M.wall() return os.time() end
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
local function unwrap(e) return U().unwrap(e) end
local function each(arr, fn, cap) return U().each(arr, function(v, k) fn(v, k) end, cap) end -- the shared iterator (mod/body/util.lua)
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
    -- (+ every DominionSpellActor: live 2026-10-26, Eye of Oculus and Summon Stone Spirits spawn a bare
    -- DominionSpellActor, not a UtilitySpell)
    for _, fam in ipairs({ "UtilitySpell", "DominionSpellActor" }) do
        for _, a in ipairs(u.find_all(fam, { skip_defaults = true })) do
            local p = u.loc(a)
            if p and here and u.dist(p, here) < 4000 then s.actors[u.short(a)] = { class = u.class_word(a), position = to_m(p) } end
        end
    end
    local gs = u.find_first("GameStateBase")
    s.server_time = gs and u.try(function() return gs:GetServerWorldTimeSeconds() end)
    -- LastCastTimeBySpellData uses THIS client's world clock (live: 1503 s ~ 25 min after joining,
    -- while the server clock read 58000+), i.e. UGameplayStatics::GetTimeSeconds
    local gst = u.find_object("/Script/Engine.Default__GameplayStatics")
    s.world_time = gst and u.try(function() return gst:GetTimeSeconds(pawn) end)
    s.input_mode = u.short(u.try(function() return pc.CurrentInputMode end))
    -- what the camera shows (a spell may switch the view: Eye of Oculus -> BP_OculusCamera_C)
    s.view_target = u.class_word(u.try(function() return pc:GetViewTarget() end))
    -- the held weapon's enchant (AHeldEquipmentActor.Magical/PhysicalHeldEquipmentEffectInfo.EffectData,
    -- replicated; live 2026-10-26: Enchant Weapon: Fire -> HEED_EnchantWeaponFire on BP_Sword_Bronze_C)
    s.held_effects = {}
    local eq = u.try(function() return pawn.PlayerEquipmentComponent end)
    for _, side in ipairs({ "HeldEquipmentActorLeft", "HeldEquipmentActorRight" }) do
        local a = eq and u.try(function() return eq[side] end)
        if u.valid(a) then
            for _, f in ipairs({ "MagicalHeldEquipmentEffectInfo", "PhysicalHeldEquipmentEffectInfo" }) do
                local e = u.short(u.try(function() return a[f].EffectData end))
                if e then s.held_effects[#s.held_effects + 1] = e end
            end
        end
    end
    s.falling = u.try(function() return pawn.CharacterMovement:IsFalling() end) == true
    local fx = W.effects_of(pawn)
    s.ge, s.tags = fx.ge, fx.tags
    local sk = u.try(function() return pc.SkillComponent end)
    each(sk and u.try(function() return sk.Skills end), function(x)
        local d = u.try(function() return x.SkillData end)
        if u.valid(d) then s.skills[u.short(d)] = u.try(function() return sk:GetSkillLevel(d) end) end
    end, 32)
    s.position = to_m(u.try(function() return pawn:K2_GetActorLocation() end))
    return s
end

-- GameplayEffect classes + gameplay tags on one actor's GameplayEffectsComponent (the pawn's, or a creature's: an
-- aimed spell's status lands there, e.g. GE_Confuse_C per the dump). -> {ge = {...}, tags = {...}} (empty when unreadable)
function W.effects_of(actor)
    local u = U()
    local out = { ge = {}, tags = {} }
    local ge = u.valid(actor) and u.try(function() return actor.GameplayEffectsComponent end)
    if u.valid(ge) then
        for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
            each(u.try(function() return ge[f] end), function(x) if u.valid(x) then out.ge[#out.ge + 1] = u.class_word(x) end end, 64)
        end
        pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) out.tags[#out.tags + 1] = u.str(unwrap(t).TagName) end) end)
    end
    return out
end

-- A creature target's effects now (UNVERIFIED on the client: whether creature GEs replicate; the live check
-- tools/live_checks/spell_confuse_observe.json records it). nil for anything that is not a creature thing.
function W.target_effects(api, target)
    if not (target and target.kind == "thing" and target.category == "creatures" and target.id and api.actor_of) then return nil end
    local t = select(1, api.find_thing(target.id))
    local a = t and api.actor_of(t)
    if not U().valid(a) then return nil end
    return W.effects_of(a)
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
            a.prev_page = u.try(function() return p.ChangeSpellRadialLeftInputAction end)
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
-- Through the shared input layer (input.lua, the modal gate): spells OWNS the "mode" modal (the wheel, the
-- placement / spell modes it opens), so it passes opts.modal = "mode"; a build-mode or container modal still
-- blocks it. (Live 2026-10-26 08:1x: combat._inject, now gated, refused every press after Q because the wheel
-- is a non-gameplay mode -> "not_selected", and the wheel stayed open.)
function W.inject(api, action)
    local u = U()
    if not u.valid(action) then return false end
    local inp = api.module("input")
    if inp and type(inp.inject) == "function" then
        local ok, blocked = inp.inject(action, nil, { modal = "mode" })
        if not ok and blocked then mem().blocked = { kind = blocked.kind, mode = blocked.mode, at = os.time() } end
        return ok == true
    end
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

-- The shared placement module (client_mod/scripts/placement.lua, build review finding 13): spot search and
-- the preview check loop live there; spells passes its env and its own numbers.
local PL
function M.placement(api)
    local m = api and api.module and api.module("placement")
    if m then return m end
    if not PL then
        PL = assert(loadfile((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/") .. "/client_mod/scripts/placement.lua"))()
    end
    return PL
end

-- placement.lua's env over this client: traces, my position (cm), players (m), camera aim, the preview.
function W.placement_env(api)
    local u = U()
    local pawn = W.pawn(api)
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    return {
        trace = function(a, b)
            local out = {}
            local ok, hit = pcall(function() return KSL:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0) end)
            return ok and hit == true, out
        end,
        me = function() return u.valid(pawn) and u.loc(pawn) or nil end,
        players = function() return W.players(api) end,
        aim = function(pos) if pos then return W.aim(api, pos) end end,
        read = function()
            local v = W.preview(api)
            if not v then return nil end
            return { valid = v.valid, why = v.tag, position = v.position }
        end,
    }
end

-- Candidate spots for a placed spell, best first (placement.lua P.spots): around `center` (a target,
-- metres; the target itself first; players not skipped there, the harm check decides) or around me
-- (cfg.spot_rings_m, keeping cfg.spot_player_clear_m from players). opts.rings / opts.los as before.
-- -> {{position, spread_m, normal_z, exact}}
function W.spots(api, center, opts)
    opts = opts or {}
    local u = U()
    if not u.valid(W.pawn(api)) then return {} end
    local cfg = M.cfg
    local P = M.placement(api)
    local out = P.spots(W.placement_env(api), center, {
        rings_m = opts.rings or cfg.spot_rings_m, ring_n = 12, around_m = { 2, 3.5 }, around_n = 8,
        clear_players_m = center and 0 or cfg.spot_player_clear_m,
        max_spread_m = cfg.spot_max_spread_m, min_normal_z = cfg.spot_min_normal_z, los = opts.los })
    return out
end

-- Camera-to-point distance in metres (the placement reach is measured from the camera).
function W.cam_dist(api, pos)
    local u = U()
    local pc = W.pc(api)
    if not (pos and u.valid(pc)) then return nil end
    local cam = to_m(u.try(function() return pc.PlayerCameraManager:GetCameraLocation() end))
    if not cam then local me = api.my_position(); return me and d3(me, pos) end
    return d3(cam, pos)
end

-- A foliage id from look ("fol:<component>:<index>": a standing tree, bush, ...) that the bridge's
-- capped census did not return: ask sense's own foliage reader around me (what look and gather use).
-- -> {id, name, position (metres)} | nil (gone: felled, picked, or out of range)
-- A live actor by its id (U.short name; the class is the id up to "_C"), within 80 m of `here` (m). One FindAllOf
-- of that class only. -> {id, name, position} | nil
function W.actor_thing(api, id, here)
    local u = U()
    local cls = type(id) == "string" and id:match("^(.-_C)_") or nil
    if not cls then return nil end
    for _, a in ipairs(u.find_all(cls, { skip_defaults = true }) or {}) do
        if u.short(a) == id then
            local p = to_m(u.loc(a))
            if not p then return nil end
            if here and d3(p, here) > 80 then return nil end
            local name = u.str(u.try(function() return a.DisplayNameText end)) or u.class_word(a)
            return { id = id, name = name, position = p }
        end
    end
    return nil
end

-- move (the shared mover): go_to on the LIVE actor id (move tracks a moving actor) or the point; its status/stop.
local function move_mod(api) local m = api.module and api.module("move"); return type(m) == "table" and m or nil end
function W.move_go_to(api, target, opts)
    local m = move_mod(api)
    if not (m and m.go_to) then return nil end
    local goal = (target.kind ~= "point" and target.id and not target.foliage) and target.id or target.position
    return m.go_to(api.log, goal, opts)
end
function W.move_status(api) local m = move_mod(api); return m and m.status and m.status() or {} end
function W.move_stop(api) local m = move_mod(api); if m and m.stop then pcall(m.stop, api.log) end end
function W.why_words(api, why, thing)
    local m = move_mod(api)
    return (m and m.why_words and m.why_words(why, thing)) or "I can't find a way there"
end
-- A thing's / player's position now (m), from its live actor (cached on the job, re-validated each read).
function W.live_position(api, tg, job)
    local u = U()
    local a = job._actor
    if not (a and u.valid(a)) then
        a = nil
        local cls = tostring(tg.id):match("^(.-_C)_")
        for _, x in ipairs(cls and u.find_all(cls, { skip_defaults = true }) or {}) do
            if u.short(x) == tg.id then a = x; break end
        end
        if not a and tg.kind == "player" then
            for _, p in ipairs(W.players(api)) do if p.id == tg.id or p.name == tg.name then return p.position end end
        end
        job._actor = a
    end
    return a and to_m(u.loc(a)) or nil
end

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

-- Which own modes (M.MODE_EXITS rows) are active on the pawn now. -> {row, ...}
function W.own_modes(api)
    local u = U()
    local pawn = W.pawn(api)
    local out = {}
    if not u.valid(pawn) then return out end
    for _, row in ipairs(M.MODE_EXITS) do
        local c = u.try(function() return pawn[row.component] end)
        if u.valid(c) and u.try(function() return c[row.active](c) end) == true then out[#out + 1] = row end
    end
    return out
end

-- Leave one own mode through the game's own exit handler. -> true if the call went through
function W.exit_own_mode(api, row)
    local u = U()
    local pawn = W.pawn(api)
    local c = u.valid(pawn) and u.try(function() return pawn[row.component] end)
    return u.valid(c) and pcall(function() c[row.exit](c) end) or false
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
        if m.hooks[h.path] ~= "ok" and type(RegisterHook) == "function" then
            -- BUGS L24: the shared hook hub (one native hook per path, never unregistered, skipped under DW_PAUSE)
            local hubm = (function()
                local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or ((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver") .. "/client_mod/scripts")
                return assert(loadfile(dir .. "/hookhub.lua"))()
            end)()
            local ok = hubm.on(h.path, "spells:" .. h.ev, function() local mm = mem(); mm.events[#mm.events + 1] = { ev = h.ev, t = os.clock() } end,
                               {})
            m.hooks[h.path] = ok and "ok" or "pending"
        end
    end
end

-- ------------------------------------------------------------------ listing
local function rows_of(api, snap, all)
    local m = mem()
    local now_local = M.wall()
    local out, seen = {}, {}
    snap.req = snap.req or {}
    for id, obj in pairs(snap.objects) do
        local st = W.static(obj)
        snap.req[id] = W.requirement(api, st)
        out[#out + 1] = M.row(st, snap, m.cast_at[id], now_local)
        -- how it is really used (drop-then-cast, cast-on-a-thing, charges; data/spell_mechanics.json, wiki-sourced):
        -- the `spells` read showed only the game's one-line description (M2 gap audit 2026-10-26)
        local mech = M.mechanics(id)
        if mech and mech.how then out[#out].how = mech.how end
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
    -- an actor id the census doesn't list (re-run 2026-10-26: fishing nodes from fishing_spots, Fishnado /
    -- Fishing Frenzy "can't see what you want me to aim at"): the live actor itself, by its own name
    if not t and target:sub(1, 4) ~= "fol:" then t = W.actor_thing(api, target, snap.position) end
    if not t then
        local d = copy(r and r.data)
        -- no raw ids in words meant for speech (L26): the id stays in data.target
        d.detail = target:sub(1, 4) == "fol:" and "I can't see that tree or plant any more; it may have been felled or picked."
            or "I can't see what you want me to aim at any more."
        return nil, api.fail("unknown_target", d)
    end
    -- where the thing really is: felled logs roll away from their stale actor origin (DISCOVERIES:
    -- aim at the game's own ATreeLog::GetMidPointWorldLocation; L15 live: the preview fell 1-3.5 m
    -- past the origin with "requires log")
    local pos, where = t.position, nil
    local c = W.thing_center(api, t)
    if c then pos, where = c, "midpoint" end
    return { kind = "thing", position = pos, name = t.name, id = t.id, foliage = target:sub(1, 4) == "fol:" or nil, aim_from = where,
             category = t.category }
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
    -- a creature target's effects before the cast, so the result can say what the spell put on it
    local okfx, fx0 = pcall(W.target_effects, api, tg)
    tg.fx_before = okfx and fx0 or nil
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
    local icon_of = {}
    for a, o in pairs(snap.objects or {}) do local so = W.static(o); icon_of[a] = so and so.icon end
    local walk_to
    if args.walk_to == nil and row.cast_type == "instant_after_move" then
        -- verified live 19:39 UTC: opened and finished in place it moves him 0 m and still spends the runes
        local how = (M.mechanics(row.id) or {}).how
        d.why = "walk_to_required"
        d.detail = row.name .. " is held open while I move and finishes back where I opened it, so opened and finished "
            .. "on the spot it moves me 0 m and wastes the runes. Give walk_to: where to walk while it's open."
            .. (how and (" (" .. how .. ")") or "")
        return nil, api.fail("invalid_args", d)
    end
    if args.walk_to ~= nil then
        if row.cast_type ~= "instant_after_move" then
            d.why, d.detail = "walk_to_not_supported", row.name .. " can't be held open while I walk; only spells that let you move while casting can."
            return nil, api.fail("invalid_args", d)
        end
        local wt, wf = target_of(api, args.walk_to, snap)
        if not wt or wt.kind == "self" then return nil, wf or api.fail("invalid_args", { detail = "walk_to must be a place or a thing" }) end
        walk_to = wt
    end
    local job = { api = api, row = row, st = st, d = d, acts = acts, slot = slot, target = tg, placed = placed, walk_to = walk_to,
                  pages = M.page_count(snap.radials, #(snap.wheel or {}), per),
                  per = per, icon_of = icon_of,
                  before = snap, phase = "own", t0 = api.now(), presses = {} }
    return job
end

local function release(job, why)
    if job.borrowed then return end -- the caller (combat) owns the pawn and its token
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
        for _, row in ipairs(W.own_modes(job.api)) do
            if W.exit_own_mode(job.api, row) then
                job.d.exited_own_mode = job.d.exited_own_mode or {}
                table.insert(job.d.exited_own_mode, row.component)
            end
        end
    end
    release(job, job.d.why or "done")
end

-- How many pages the wheel has: the game's NumSpellRadials, never fewer than the wheel data fills
-- (SelectedSpells / NumSpellSlotsPerRadial, rounded UP). Pure. -> >= 1
function M.page_count(radials, wheel_len, per)
    per = (tonumber(per) or 0) > 0 and per or 12
    local by_data = math.ceil((tonumber(wheel_len) or 0) / per)
    return math.max(1, math.floor(tonumber(radials) or 0), by_data)
end

-- Which wheel page the open radial shows: the page whose spells' icons match the shown slice icons
-- best (at least half of its filled slots). Pure. -> 0-based page | nil
function M.page_of(icons, wheel, per, icon_of)
    if not (icons and wheel and per and icon_of) then return nil end
    local best, best_n, pages = nil, 0, math.ceil(#wheel / per)
    for pg = 0, pages - 1 do
        local hit, filled = 0, 0
        for i = 1, per do
            local a = wheel[pg * per + i]
            if a then
                filled = filled + 1
                if icon_of[a] and icons[i] == icon_of[a] then hit = hit + 1 end
            end
        end
        if filled > 0 and hit * 2 >= filled and hit > best_n then best, best_n = pg, hit end
    end
    return best
end

-- Stage timing (L27): the first time each stage was reached, reported as data.timing.
local function mark(job, name, t)
    job.marks = job.marks or {}
    if t and not job.marks[name] then job.marks[name] = t end
end
M._mark = mark
function M.timing(job, t_end)
    local m = job.marks or {}
    local function span(a, b) return (m[a] and m[b]) and math.floor((m[b] - m[a]) * 100 + 0.5) / 100 or nil end
    m.done = m.done or t_end
    return { open_s = span("start", "opened"), pages_s = span("opened", "page_ok"), select_s = span("page_ok", "selected"),
             aim_s = span("spell_mode", "released"), verify_s = span(m.released and "released" or "selected", "evidence"),
             settle_s = span("evidence", "done"), total_s = span("start", "done"), page_turns = job.flips or 0 }
end

local function press(job, name, action)
    job.presses[#job.presses + 1] = name
    if name == "place" then mark(job, "released", W.clock(job.api) or job.api.now()) end
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
-- Entries of `a` not in `b` (a multiset difference: one new GE of a class already present still counts). Pure.
function M.list_added(b, a, dst)
    dst = dst or {}
    local seen = {}
    for _, x in ipairs(b or {}) do seen[x] = (seen[x] or 0) + 1 end
    for _, x in ipairs(a or {}) do if (seen[x] or 0) > 0 then seen[x] = seen[x] - 1 else dst[#dst + 1] = x end end
    return dst
end

function M.diff(before, after, st)
    local out = { runes_spent = {}, ge_added = {}, tags_added = {}, actors_added = {} }
    for _, c in ipairs(st.cost or {}) do
        local b, a = (before.items or {})[c.item] or 0, (after.items or {})[c.item] or 0
        if a < b then out.runes_spent[c.item] = b - a; out.spent = true end
    end
    local lb, la = (before.last_cast or {})[st.asset], (after.last_cast or {})[st.asset]
    if la ~= nil and la ~= lb then out.cooldown_started = true end
    local added = M.list_added
    added(before.ge, after.ge, out.ge_added)
    added(before.tags, after.tags, out.tags_added)
    for id, a in pairs(after.actors or {}) do if not (before.actors or {})[id] then out.actors_added[#out.actors_added + 1] = { id = id, class = a.class, position = a.position } end end
    if after.view_target and before.view_target and after.view_target ~= before.view_target then out.view_target = after.view_target end
    out.held_added = {}
    added(before.held_effects, after.held_effects, out.held_added)
    if after.input_mode and after.input_mode ~= before.input_mode then out.mode = after.input_mode end
    return out
end

-- (the shared failure shape; `failed` below is the same, defined later for the state machine)
function M._fail(job, reason, why, detail)
    job.d.why, job.d.detail, job.d.presses = why, detail, job.presses
    job.d.timing = M.timing(job, W.clock(job.api) or job.api.now())
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
    d.timing = M.timing(job, W.clock(job.api) or job.api.now())
    -- how far the cast moved me (dash / leap spells), from fresh positions
    if snap and snap.position and job.before.position then d.moved_m = math.floor(d3(snap.position, job.before.position) * 100 + 0.5) / 100 end
    d.runes_spent, d.cooldown_started = df.runes_spent, df.cooldown_started == true
    d.effects = { ge = df.ge_added, tags = df.tags_added, actors = {}, view_target = df.view_target or job.seen_view, mode = job.seen_mode or df.mode,
                  held = df.held_added }
    for _, a in ipairs(df.actors_added or {}) do d.effects.actors[#d.effects.actors + 1] = a.class end
    d.effect_verified = (#df.ge_added + #df.tags_added + #df.actors_added + #(df.held_added or {})) > 0 or d.effects.view_target ~= nil
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
        if job.target.fx_before then
            -- what the spell put on the creature (Confuse / Enfeeble / Snare status effects): new GE classes + tags
            local okfx, fx1 = pcall(W.target_effects, api, job.target)
            if okfx and fx1 then
                d.target_effects = { ge = M.list_added(job.target.fx_before.ge, fx1.ge), tags = M.list_added(job.target.fx_before.tags, fx1.tags) }
                if #d.target_effects.ge + #d.target_effects.tags > 0 then d.effect_verified = true end
            end
        end
    end
    d.presses = job.presses
    mem().cast_at[job.row.id] = M.wall()
    -- it went off, but not where asked: say so (the brain voices failures, not ok results)
    local tol = math.max(job.st.radius_m or 0, M.cfg.landed_tolerance_m)
    if d.landed_dist_m and d.landed_dist_m > tol then
        d.why = "landed_elsewhere"
        d.detail = "I cast " .. job.row.name .. " but it landed " .. math.floor(d.landed_dist_m + 0.5) .. " m from where you wanted."
        return { ok = false, reason = "verification_failed", data = d }
    end
    if job.hold and job.hold.start and snap and snap.position then
        -- landed_at = where he ended up; placed_at = where the place press (and its spell actor) happened
        d.placed_at, d.landed_at = d.landed_at, snap.position
        local from_open = d3(snap.position, job.hold.start)
        d.from_opened_m = math.floor(from_open * 10 + 0.5) / 10
        d.returned = (job.d.walked_m or 0) > M.cfg.hold_return_m and from_open <= M.cfg.hold_return_m
        if d.returned then
            d.detail = string.format("I opened %s, walked %d m, and finishing it brought me back to where I opened it.",
                job.row.name, math.floor((job.d.walked_m or 0) + 0.5))
        else
            d.detail = string.format("I opened %s, walked %d m and finished it, but it didn't bring me back: I'm still %d m from where I opened it.",
                job.row.name, math.floor((job.d.walked_m or 0) + 0.5), math.floor(from_open + 0.5))
        end
        return { ok = true, data = d }
    end
    d.detail = d.detail or M.success_words(job.row.name, job.st.cost, d)
    return { ok = true, data = d }
end

-- The outcome in words (re-run 2026-10-26: an ok cast carried no sentence, so the model re-cast Vengeance and
-- hit its cooldown). Only what was verified: runes from the inventory diff, the cooldown from the game's map.
function M.success_words(name, cost, d)
    local names = {}
    for _, c in ipairs(cost or {}) do if c.item then names[c.item] = c.name end end
    local spent = {}
    for item, n in pairs(d.runes_spent or {}) do spent[#spent + 1] = string.format("%d %s", n, names[item] or item) end
    table.sort(spent)
    local s = "I cast " .. tostring(name)
    if #spent > 0 then s = s .. ": used " .. table.concat(spent, ", ") end
    if d.cooldown_started then s = s .. (#spent > 0 and "; " or ": ") .. "it's recharging now" end
    return s .. "."
end

local function failed(job, reason, why, detail)
    job.d.why, job.d.detail, job.d.presses = why, detail, job.presses
    job.d.timing = M.timing(job, W.clock(job.api) or job.api.now())
    return { ok = false, reason = reason, data = job.d }
end

-- ------------------------------------------------------------------ multi-step mechanics (DATA)
-- data/spell_mechanics.json (non-judge; sources inside): per spell id {how, setup?, observed?, sources}. Cached.
function M.mechanics(id)
    local m = mem()
    if m.mech == nil then
        m.mech = false
        local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
        local okj, json = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))() end)
        local f = okj and io.open(root .. "/data/spell_mechanics.json", "rb")
        if f then
            local doc = json.decode(f:read("a")); f:close()
            if type(doc) == "table" and type(doc.spells) == "table" then m.mech = doc.spells end
        end
    end
    return m.mech and id and m.mech[id] or nil
end

-- ------------------------------------------------------------------ approach (one call = the whole player motion)
local function d2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
-- The target's live position (m): the actor (cached, re-validated) for a thing / player id, else as given.
function M.refresh_target(job)
    local tg = job.target
    if not (tg and (tg.kind == "thing" or tg.kind == "player") and tg.id) or tg.foliage then return tg and tg.position end
    local p = W.live_position(job.api, tg, job)
    if p then tg.position = p end
    return tg.position
end
local function reach_of(job, snap)
    return job.st.reach_m or ((snap and snap.place_max_m and snap.place_max_m > 0) and snap.place_max_m) or M.cfg.place_max_m
end
-- Open the wheel now, or first walk into reach of a target that is too far (never for self casts).
function M.begin_open(job, t, snap)
    local cfg = M.cfg
    if job.target.kind ~= "self" and not job.approached then
        local pos = M.refresh_target(job)
        local me = (snap and snap.position) or (W.snapshot(job.api) or {}).position
        local reach = reach_of(job, snap)
        local stand = math.max(reach - cfg.approach_margin_m, 2)
        -- the game measures reach from the CAMERA (live 17:3x: 11.5 m from him was 17 m from the view): judge by it
        local cam = pos and W.cam_dist(job.api, pos)
        local far = pos and me and ((cam and cam > reach - 1) or (not cam and d2(pos, me) > stand))
        if far then
            job.approach = { t0 = t, stand = stand, reach = reach, from_m = d2(pos, me) }
            job.d.approach_from_m = math.floor(job.approach.from_m * 10 + 0.5) / 10
            job.phase = "approach"
            -- walk right up if need be (live 17:3x: the view was 7.4 m farther than him); stopped as soon as the VIEW is in reach
            W.move_go_to(job.api, job.target, { tolerance_m = 1.5, owner_token = job.token,
                progress = { stall_s = cfg.approach_stall_s, budget_s = cfg.approach_budget_s } })
            job.presses[#job.presses + 1] = "approach"
            return nil
        end
    end
    job.phase, job.until_t, job.tries = "open", t + cfg.open_wait_s, 1
    press(job, "menu", job.acts.menu)
    return nil
end
function M.approach_step(job, t)
    local cfg, ap = M.cfg, job.approach
    local snap = W.snapshot(job.api)
    local pos, me = M.refresh_target(job), snap and snap.position
    local name = job.target.name or "the target"
    if not pos then
        W.move_stop(job.api)
        return failed(job, "unknown_target", "target_lost", "I lost sight of " .. name .. " while walking up to cast " .. job.row.name .. ".")
    end
    local d = me and d2(pos, me)
    job.d.approach_m = d and math.floor(d * 10 + 0.5) / 10
    local cam = W.cam_dist(job.api, pos)
    job.d.approach_view_m = cam and math.floor(cam * 10 + 0.5) / 10
    if (cam and cam <= ap.reach - 1.5) or (not cam and d and d <= ap.stand) then
        W.move_stop(job.api)
        job.approached, job.d.approached_s = true, math.floor((t - ap.t0) * 10 + 0.5) / 10
        return M.begin_open(job, t, snap)
    end
    local st = W.move_status(job.api) or {}
    local pv = type(st.progress) == "table" and st.progress or {}
    local res = type(st.result) == "table" and st.result or {}
    local over = t - ap.t0 > cfg.approach_budget_s + 2
    local ended = st.mode == "idle" and t - ap.t0 > 1
    if pv.verdict == "stalled" or pv.verdict == "unreachable" or res.status == "failed" or over or ended then
        W.move_stop(job.api)
        local why = pv.why or res.reason or res.why or (over and "too_long") or "no_progress"
        job.d.approach_why = why
        local words = (why == "cant_catch") and "it keeps getting away from me" or W.why_words(job.api, why, name)
        local gap = cam and string.format("it's %d m from my view and I can reach about %d m", math.floor(cam + 0.5), math.floor(ap.reach))
            or string.format("it's %d m away, I need about %d m", math.floor((d or 0) + 0.5), math.floor(ap.stand))
        return failed(job, "too_far", "cant_get_in_range", "I couldn't get within reach of " .. name .. " to cast " .. job.row.name
            .. " (" .. gap .. "): " .. words .. ".")
    end
    return nil
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
        return M.begin_open(job, t, s0)
    end
    if job.phase == "approach" then return M.approach_step(job, t) end
    if job.phase == "own" then
        local A = (not job.borrowed) and arbiter(api) or nil
        if A then
            local r = A.request(api.log, { name = "spell:" .. job.row.id, level = cfg.level, uses_move = job.placed or job.target.kind ~= "self", lease_s = cfg.lease_s,
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
        mark(job, "start", t)
        local m0 = job.before.input_mode
        local own = W.own_modes(api)
        if #own > 0 then
            job.d.closed_previous = own[1].component
            for _, row in ipairs(own) do job.presses[#job.presses + 1] = "exit:" .. row.component; W.exit_own_mode(api, row) end
            job.phase, job.until_t = "settle", t + 2.5
            return nil
        end
        -- another modal (build mode, a container screen) owns the input: the game's controls there do
        -- something else, and input.lua refuses our presses (L30) -> say so instead of "the wheel didn't open"
        local inp = api.module("input")
        local blocker = inp and type(inp.gate) == "function" and inp.gate({ modal = "mode" }) or nil
        if blocker and blocker.kind ~= "mode" then
            local what = (blocker.kind == "build" and "build mode") or (blocker.kind == "container" and "a storage screen")
                or (blocker.kind == "paused" and "a loading screen") or tostring(blocker.kind)
            job.d.blocked_by = blocker.kind
            return failed(job, "busy", "modal_open", "I can't cast right now: " .. what .. " is open.")
        end
        if m0 and m0 ~= cfg.gameplay_mode and (in_spell_mode(m0) or m0 == cfg.radial_mode) then
            job.d.closed_previous = m0
            press(job, "close_previous", (m0 == cfg.radial_mode and job.acts.menu) or job.acts.cancel)
            job.phase, job.until_t = "settle", t + 1.5
            return nil
        end
        return M.begin_open(job, t, job.before)
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
    -- remember transient evidence (a view switch / mode lasts only while the spell's mode is open)
    if df.view_target then job.seen_view = job.seen_view or df.view_target end
    if df.mode and df.mode ~= cfg.radial_mode then job.seen_mode = job.seen_mode or df.mode end
    if df.spent or df.cooldown_started or M.own_actor(job, df) then
        -- it went off. Wait (bounded) until the game state SETTLES: the rune spend and the cooldown
        -- record replicate separately and late (L25, dev run 23:32: shelter actor first, runes and
        -- cooldown seconds later), and don't press Esc into the cast animation (Splinter, 21:2x).
        mark(job, "evidence", t)
        job.settle_until = job.settle_until or (t + cfg.settle_s)
        local settled = (df.spent or not next(job.st.cost or {})) and df.cooldown_started
        local own = W.own_modes(api)
        if settled then
            job.settled_t = job.settled_t or t
            -- settled: leave the spell's mode (the game's own exit for an own mode, else Esc), then
            -- answer once the input mode is back to gameplay (L29: Oculus stayed in its build menu)
            local linger = in_spell_mode(snap.input_mode) or #own > 0
            if linger and t < job.settled_t + cfg.mode_linger_s then return nil end
            if linger and not job.leaving then
                job.leaving = true
                job.d.left_mode = snap.input_mode
                if #own > 0 then
                    for _, row in ipairs(own) do job.presses[#job.presses + 1] = "exit:" .. row.component; W.exit_own_mode(api, row) end
                    job.d.exited_own_mode = {}
                    for _, row in ipairs(own) do table.insert(job.d.exited_own_mode, row.component) end
                else
                    press(job, "leave_mode", job.acts.cancel or job.acts.menu)
                end
                job.leave_until = t + cfg.leave_s
                return nil
            end
            if linger and t < (job.leave_until or 0) then return nil end
            job.d.mode_after = snap.input_mode
        elseif t < job.settle_until then
            return nil
        end
        -- a spell that keeps its own mode open (Eye of Oculus: a camera mode) may record its cooldown
        -- only when the mode ends: leave the mode, then give the record a moment to land
        if not settled and (in_spell_mode(snap.input_mode) or #own > 0) and not job.settle_cancelled then
            job.settle_cancelled = true
            job.d.left_mode = snap.input_mode
            if #own > 0 then
                for _, row in ipairs(own) do job.presses[#job.presses + 1] = "exit:" .. row.component; W.exit_own_mode(api, row) end
            else
                press(job, "leave_mode", job.acts.cancel or job.acts.menu)
            end
            job.settle_until = t + cfg.settle_after_leave_s
            return nil
        end
        job.succeeded = true
        job.d.settled = settled and true or false
        if not settled then
            job.d.unsettled = {}
            if not df.cooldown_started then job.d.unsettled[#job.d.unsettled + 1] = "cooldown_started" end
            if next(job.st.cost or {}) and not df.spent then job.d.unsettled[#job.d.unsettled + 1] = "runes_spent" end
        end
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
            mark(job, "opened", t)
            if not job.page_deadline then job.page_deadline = t + cfg.page_max_s end -- the first page settles too
            if job.page_wait and t < job.page_wait then return nil end
            -- press the key only when the open page shows THIS spell in that slot (never cast another)
            local icons = W.shown_icons(api)
            if not icons then return failed(job, "verification_failed", "wheel_unreadable", "I can't read my spell wheel right now.") end
            local sig = table.concat((function() local o = {}; for i = 1, #icons do o[i] = tostring(icons[i]) end; return o end)(), "|")
            -- after a page turn, wait (up to page_max_s) until the slices actually show the new page
            -- ... and judge it only once the slices have held still for page_settle_s (a page draws over frames)
            if job.page_deadline and t < job.page_deadline then
                if job.page_sig and sig == job.page_sig then return nil end
                if sig ~= job.settle_sig then job.settle_sig, job.settle_t = sig, t; return nil end
                local lap = math.floor((job.flips or 0) / math.max(job.pages, 1))
                if t - job.settle_t < cfg.page_settle_s * 2 ^ lap then return nil end
            end
            job.page_sig, job.settle_sig = sig, nil
            -- Two witnesses per page: the slice ICON (what is drawn) and the radial's own DATA (HighlightSlice +
            -- SpellName for this slot: the wheel's real page, BlueprintCallable, what hovering runs). T0 2026-10-26
            -- (~38 spells): pages draw over frames, so the icon alone judged half-drawn pages ("not here", turned
            -- past: page_not_found after a lap) and could even show the OLD page's icon in this slot.
            --   data names this spell             -> here (by name if the icon differs: Enchant Weapon: Fire)
            --   icon matches, data names another  -> not settled: look again until page_deadline, then
            --                                        highlight_mismatch (never press a slice that names another spell)
            --   icon matches, data unreadable     -> here (icon only, as before)
            --   neither                           -> turn the page
            local icon_here = icons[job.slot + 1] == job.st.icon
            local hl = W.highlight(api, job.slot)
            local hl_ok = hl and hl.section == job.slot and type(hl.name) == "string"
            local named = hl_ok and norm_name(hl.name) == norm_name(job.row.name)
            local by_name = named and not icon_here
            if by_name then
                job.d.icon_mismatch = { slot = job.slot, shown = icons[job.slot + 1] or "empty", want = job.st.icon, highlight = hl.name }
                job.d.picked_by = "name"
            elseif icon_here and hl_ok and not named then
                job.d.highlight_disagreed = (job.d.highlight_disagreed or 0) + 1
                if t < (job.page_deadline or 0) then job.page_sig = nil; return nil end
                return failed(job, "verification_failed", "highlight_mismatch", "I couldn't point at " .. job.row.name .. " on my spell wheel"
                    .. ((hl.name ~= "") and (" (it showed " .. hl.name .. ")") or "") .. ", so I didn't pick anything.")
            elseif not icon_here and hl_ok and hl.name ~= "" then
                job.d.icon_mismatch = job.d.icon_mismatch or { slot = job.slot, shown = icons[job.slot + 1] or "empty", want = job.st.icon, highlight = hl.name }
            end
            local here = named or (icon_here and not hl_ok)
            if here then
                mark(job, "page_ok", t)
                mark(job, "selected", t)
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
            if job.flips > job.pages * (cfg.page_laps or 1) or not job.acts.next_page then
                local mm = job.d.icon_mismatch
                return failed(job, "verification_failed", "page_not_found", "I couldn't find " .. job.row.name .. " on my spell wheel's pages"
                    .. ((mm and mm.highlight and mm.highlight ~= "") and (" (its slot shows " .. mm.highlight .. ")") or "") .. ".")
            end
            local dir = "next"
            if job.acts.prev_page and not job.page_dir then
                local cur = M.page_of(icons, job.before.wheel, job.per, job.icon_of)
                if cur then
                    local want = job.row.wheel_slot // job.per
                    local fwd, back = (want - cur) % job.pages, (cur - want) % job.pages
                    job.page_dir = back < fwd and "prev" or "next"
                    job.d.page_from = cur + 1
                end
            end
            dir = job.page_dir or dir
            if dir == "prev" then press(job, "prev_page", job.acts.prev_page) else press(job, "next_page", job.acts.next_page) end
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
    if job.phase == "hold_walk" then
        local h = job.hold
        if not in_spell_mode(mode) then
            W.move_stop(api)
            return failed(job, "verification_failed", "hold_closed", job.row.name .. " closed while I was walking (I'd gone "
                .. math.floor(((snap.position and h.start) and d3(snap.position, h.start) or 0) + 0.5) .. " m), so it never finished.")
        end
        local st = W.move_status(api) or {}
        local res = type(st.result) == "table" and st.result or {}
        local pv = type(st.progress) == "table" and st.progress or {}
        local done = res.status == "arrived" or (st.mode == "idle" and t - h.t0 > 1) or pv.verdict == "stalled"
            or t - h.t0 > cfg.hold_walk_budget_s
        if not done then return nil end
        W.move_stop(api)
        job.walked = true
        job.d.walked_m = (snap.position and h.start) and math.floor(d3(snap.position, h.start) * 10 + 0.5) / 10 or nil
        job.d.walk_result = res.status or pv.verdict or "budget"
        job.phase, job.until_t = "select", t + cfg.select_wait_s -- the select phase now finishes it (validated spot search)
        return nil
    end
    if job.phase == "select" then
        if in_spell_mode(mode) then
            mark(job, "spell_mode", t)
            -- placed / aimed (or a spell the game wants confirmed): check it is OUR spell, aim, release LMB
            local sel = W.selected(api)
            if sel and sel ~= job.row.id then
                return failed(job, "verification_failed", "wrong_spell", "My wheel picked a different spell than " .. job.row.name .. ", so I cancelled.")
            end
            M.refresh_target(job) -- re-aim at where it is NOW (a creature moves while the wheel opens)
            local aimed_at = job.target.kind ~= "self" and job.target.position or nil
            -- ONE loop for every spell that shows the game's preview (placed, or aimed with a visualizer):
            -- aim at what was asked for (a thing's body at a few heights, a point, or straight ahead),
            -- re-read the preview, release LMB only when it is valid and on target. Flat-ground spots
            -- are added only when the game's own validation tag talks about the ground (not flat /
            -- blocked), or for a placed spell given no target after "straight ahead" was refused.
            -- (L14/L15: one-shot aims threw at nothing; ground spots never validated on a log.)
            -- live 17:37 (Recall): DIM_SpellPlacementModeAdvancedMovement is a ground placement too; a place press on an
            -- invalid spot does nothing (12 s "prepared"), so it goes through the same validated spot search
            local ground_mode = mode == "DIM_SpellPlacementModeAdvancedMovement"
            if ground_mode and job.walk_to and not job.walked then
                job.hold = { t0 = t, start = snap.position }
                job.d.opened_at = snap.position
                job.phase = "hold_walk"
                W.move_go_to(api, job.walk_to, { tolerance_m = 1.5, owner_token = job.token, progress = { stall_s = 8, budget_s = cfg.hold_walk_budget_s } })
                job.presses[#job.presses + 1] = "hold_walk"
                return nil
            end
            if job.row.cast_type == "placed" or mode == "DIM_SpellPlacementMode" or ground_mode or W.preview(api) then
                job.aim_mode = job.row.cast_type ~= "placed" and not ground_mode
                job.ground_ok = job.row.cast_type == "placed" or ground_mode
                job.spots = M.target_candidates(job.target, cfg)
                job.place_deadline = t + cfg.place_budget_s
                job.spot_i, job.rejects, job.phase, job.next_spot = 0, {}, "place_check", true
                return nil
            end
            if aimed_at then
                local dist = W.aim(api, { aimed_at[1], aimed_at[2], (aimed_at[3] or 0) + cfg.aim_heights_m[1] })
                local lim = job.st.reach_m or ((snap.place_max_m and snap.place_max_m > 0) and snap.place_max_m) or cfg.place_max_m
                if dist and dist > lim + 0.5 and (job.reapproaches or 0) < cfg.reapproach_max and job.target.kind ~= "point" then
                    -- it moved out of reach while the wheel opened: put the spell away, walk again, re-open
                    job.reapproaches = (job.reapproaches or 0) + 1
                    job.approached = nil
                    press(job, "cancel", job.acts.cancel)
                    job.phase, job.until_t = "settle", t + 1.5
                    return nil
                end
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
        if not job.checker and (job.target.kind == "thing" or job.target.kind == "player") and (job.reapproaches or 0) < cfg.reapproach_max then
            -- it moved out of reach while the wheel opened: put the spell away, walk again, re-open
            local pos, me = M.refresh_target(job), snap.position
            if pos and me and d2(pos, me) > lim + 0.5 then
                job.reapproaches, job.approached = (job.reapproaches or 0) + 1, nil
                press(job, "cancel", job.acts.cancel)
                job.phase, job.until_t = "settle", t + 1.5
                return nil
            end
            job.spots = M.target_candidates(job.target, cfg) -- aim at where it is now
        end
        if not job.checker then
            local P = M.placement(api)
            job.rejects = {}
            -- out of the camera's reach: rejected up front, like before (spells' rule, not the module's)
            local keep = {}
            for _, sp in ipairs(job.spots) do
                local dist = (not sp.here) and W.cam_dist(api, sp.position) or nil
                if dist and dist > lim + 0.5 then
                    job.rejects[#job.rejects + 1] = { spot = sp.position, why = "too_far", dist_m = math.floor(dist * 10 + 0.5) / 10 }
                else keep[#keep + 1] = sp end
            end
            job.spots = keep
            job.checker = P.checker(W.placement_env(api), job.spots, {
                match_m = function(sp)
                    -- an aimed spell at a CREATURE: the game's validity already says it is on an AI character, and its
                    -- preview sits where the trace meets it, not at the body (live 17:3x Confuse on a deer: valid, 5.3 m
                    -- short of its origin with the deer 5.6 m away) -> any valid preview not beyond the creature
                    if sp.aim and job.target.category == "creatures" and job.row.cast_type == "aimed" and snap.position and job.target.position then
                        return math.max(cfg.aim_match_m, d3(snap.position, job.target.position) + 1)
                    end
                    return sp.aim and cfg.aim_match_m or (sp.exact and job.row.cast_type == "placed" and cfg.placed_point_match_m) or cfg.preview_match_m
                end,
                checks = cfg.preview_checks, wait_s = cfg.preview_wait_s, budget_s = cfg.place_budget_s, on_unreadable = "press_once",
                on_reject = function(rej, ch)
                    local sp = ch.spots[ch.i]
                    rej.game, rej.height_m = rej.why, sp and sp.height_m
                    job.rejects[#job.rejects + 1] = rej
                    -- the game's verdict decides the search: a ground complaint brings in flat-ground spots
                    if job.ground_ok and not job.ground_added and M.ground_tag(rej.why) then M.add_ground_spots(job, api) end
                    -- learn the game's flatness limit (this cast only)
                    if rej.why and tostring(rej.why):find("NotFlat", 1, true) and rej.spread_m then
                        job.bad_spread = math.min(job.bad_spread or math.huge, rej.spread_m)
                        mem().bad_spread = job.bad_spread
                        for k = #ch.spots, ch.i + 1, -1 do
                            if (ch.spots[k].spread_m or 0) >= job.bad_spread then table.remove(ch.spots, k) end
                        end
                    end
                    -- a placed spell with no target: "straight ahead" refused -> flat-ground spots
                    if job.ground_ok and not job.ground_added and job.target.kind == "self" and ch.i >= #ch.spots then M.add_ground_spots(job, api) end
                end,
            })
        end
        local r = job.checker:step(t)
        if not r then return nil end
        if r.press then
            local sp = r.spot or {}
            if r.preview == "unreadable" then
                job.d.spot, job.d.preview = sp.position, "unreadable"
            else
                job.d.spot, job.d.spot_flatness, job.d.preview_at, job.d.aim_height_m = sp.position, sp.spread_m, r.preview.position, sp.height_m
            end
            if #job.rejects > 0 then job.d.rejected = job.rejects end
            job.phase, job.until_t = "verify", t + cfg.verify_s
            press(job, "place", job.acts.place)
            return nil
        end
        job.d.rejected = job.rejects
        return M.placement_failure(job, api, lim)
    end
    -- verify (a placed spell plays its cast animation in a spell input mode first: live, Summon
    -- Shelter spent its runes only after the 4 s window, so keep waiting while the game is casting)
    job.cast_deadline = job.cast_deadline or (t + cfg.cast_max_s)
    if t >= job.until_t and (in_spell_mode(mode) or (snap.casting and snap.casting == job.row.id)) and t < job.cast_deadline then
        return nil
    end
    if t >= job.until_t then
        if snap.casting and snap.casting == job.row.id then
            -- the game still holds THIS spell prepared (SpellBeingPreparedOrCast) with nothing spent: it never went
            -- off. Re-run 2026-10-26: Recall (AllowMovementThenCastInstant) three times. What it needs to go off is
            -- not observed yet (client_mod/commands/recall_probe.lua records it), so say exactly that.
            job.d.prepared_s = math.floor((t - (job.marks and job.marks.selected or t)) * 10 + 0.5) / 10
            return failed(job, "verification_failed", "still_preparing", "I started " .. job.row.name .. " but it never went off: the game still"
                .. " has it prepared, no runes were used and it isn't recharging. I haven't learned yet what it needs to finish.")
        end
        return failed(job, "verification_failed", "no_effect", "I tried to cast " .. job.row.name .. " but no runes were used and it didn't go on cooldown"
            .. (snap.casting and (" (the game is busy with " .. tostring(snap.casting_name or snap.casting) .. ")") or "") .. ".")
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
                mem().cast_at[job.row.id] = M.wall()
                done = true
            end
        end
        if done and h then pcall(CancelDelayedAction, h) end
        return done
    end)
end
M.LATE_REASONS = { verification_failed = true, timeout = true, interrupted = true, body_error = true, on_cooldown = true, busy = true }

-- ------------------------------------------------------------------ the combat contract
-- docs/design/defense-abilities.md section 4. Combat (holding the pawn at reflex level) asks
--   ability_status(asset) -> {available, why, detail, latency_s, cooldown_s, runes_ok, route}
--   cast_now(log, asset, {owner_token}) -> job {poll() -> nil | {ok, cast_t, reason, data}, cancel()}
-- cast_now drives the same real inputs as `cast` (wheel, page turns, key / highlight + accept, LMB),
-- under the caller's arbiter token (no new request, no "while fighting" refusal, never released here).
-- Combat loads this file itself (no bridge ctx), so a minimal api is built from the sense module.
local DEFAULT_API
function M.default_api()
    if DEFAULT_API then return DEFAULT_API end
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local mods = {}
    local function module(n)
        if mods[n] == nil then
            local ok, m = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/" .. n .. ".lua"))() end)
            mods[n] = ok and m or false
        end
        return mods[n] or nil
    end
    local api = {
        module = module,
        fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
        now = function() return W.clock(DEFAULT_API) or os.time() end,
        log = function() end,
        my_position = function() local p = W.pawn(DEFAULT_API); return p and to_m(U().try(function() return p:K2_GetActorLocation() end)) end,
        aim_at = function() return false end,
        census_things = function(r, m)
            local sense = module("sense")
            local ok, res = pcall(sense.census, nil, { radius_m = r, max = m })
            if not (ok and type(res) == "table") then return {} end
            local data = res.data or res
            local out = {}
            for _, row in ipairs(data.players or {}) do row.kind = "player"; row.category = "players"; out[#out + 1] = row end
            return out
        end,
        find_thing = function(id) return nil, { ok = false, reason = "unknown_target", data = { target = id } } end,
        actor_of = function() return nil end,
    }
    DEFAULT_API = api
    return api
end

-- Rough time from the first key to the cast taking effect, by route (measured values win).
function M.route_latency(row, per)
    per = per or 12
    if not row or not row.wheel_slot then return nil end
    local page = row.wheel_slot // per
    local key = row.wheel_slot % per
    -- open the wheel ~0.3 s, up to `page` page turns ~0.45 s each (it opens on the last used page),
    -- the key (or highlight + accept) ~0.1-0.2 s, the cast itself ~0.3 s (instant spells may also
    -- need the cast-mode release)
    return 0.3 + page * 0.45 + (key < M.cfg.quick_keys and 0.1 or 0.2) + 0.3 + (row.cast_type ~= "instant" and 0.3 or 0)
end

function M.ability_status(asset, api)
    api = api or M.default_api()
    if paused() then return { available = false, why = "companion_down" } end
    local snap = W.snapshot(api)
    if not snap then return { available = false, why = "companion_down" } end
    if not snap.objects[asset] then
        return { available = false, why = "not_unlocked", detail = "I haven't unlocked that spell." }
    end
    local st = W.static(snap.objects[asset])
    snap.req = { [asset] = W.requirement(api, st) }
    local row = M.row(st, snap, mem().cast_at[asset], M.wall())
    local measured = (mem().latency or {})[asset]
    local runes_ok = row.reason ~= "not_enough_resources"
    return { available = row.castable == true, why = row.reason, detail = row.detail, cooldown_s = row.remaining_s,
             runes_ok = runes_ok, latency_s = measured or M.route_latency(row, snap.per_radial),
             latency_measured = measured ~= nil, route = row.wheel_slot and { page = row.wheel_page, key = row.wheel_key,
             keyless = (row.wheel_slot % (snap.per_radial or 12)) >= M.cfg.quick_keys } or nil }
end

function M.cast_now(log, asset, opts)
    opts = opts or {}
    local api = opts.api or M.default_api()
    local job, f = new_cast(api, { spell = asset })
    if not job then
        return { done = true, poll = function() return { ok = false, reason = f and f.reason, data = f and f.data } end, cancel = function() end }
    end
    if job.d.precheck == "on_cooldown" then -- in a fight there is no time to try a spell still recharging
        return { done = true, poll = function() return { ok = false, reason = "on_cooldown", data = job.d } end, cancel = function() end }
    end
    job.borrowed, job.token = true, opts.owner_token
    job.d.borrowed_token = opts.owner_token
    local t0 = W.clock(api) or api.now()
    local h = { job = job }
    h.poll = function()
        if h.result then return h.result end
        local ok, res = pcall(step, job)
        if not ok then res = failed(job, "body_error", "error", tostring(res)) end
        if not res then return nil end
        cleanup(job)
        local t = W.clock(api) or api.now()
        res.cast_t = res.ok and t or nil
        if res.ok then
            local m = mem()
            m.latency = m.latency or {}
            m.latency[asset] = math.floor((t - t0) * 100 + 0.5) / 100
            res.latency_s = m.latency[asset]
        elseif M.LATE_REASONS[res.reason] and job.presses[1] then
            pcall(M.watch_late, job)
        end
        h.result = res
        return res
    end
    h.cancel = function()
        if not h.result then
            h.result = failed(job, "interrupted", "cancelled", "Casting " .. job.row.name .. " was cancelled.")
            cleanup(job)
        end
    end
    return h
end

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
-- get_state extras (Director's board `spell` leaf; read only, cached cfg.extras_ttl_s): the UNLOCKED spells with
-- school (the skill whose perk unlocks it), castable now, why not, and runes needed vs carried.
M.cfg.extras_ttl_s = M.cfg.extras_ttl_s or 5
function M.state_extras(api)
    if paused() or not api then return {} end
    local m = mem()
    local now = (api.now and api.now()) or os.time()
    if m.extras and m.extras_at and now - m.extras_at >= 0 and now - m.extras_at < M.cfg.extras_ttl_s then return m.extras end
    local ok, snap = pcall(W.snapshot, api)
    if not ok or not snap then return {} end
    local okr, rows = pcall(rows_of, api, snap, false)
    if not okr then return {} end
    local out = {}
    for _, r in ipairs(rows or {}) do
        if r.unlocked then
            local st = W.static(snap.objects[r.id]) or {}
            local runes, short = {}, nil
            for _, c in ipairs(r.cost or {}) do
                runes[tostring(c.name or c.item)] = c.count
                if (c.have or 0) < (c.count or 0) then short = short or {}; short[tostring(c.name or c.item)] = c.count - (c.have or 0) end
            end
            local mech = M.mechanics(r.id)
            out[#out + 1] = { id = r.id, name = r.name, school = st.perk and st.perk.skill_name or nil, castable = r.castable == true,
                              reason = (not r.castable) and r.reason or nil, runes = next(runes) and runes or nil, runes_short = short,
                              how = mech and mech.how or nil, cast_type = r.cast_type,
                              remaining_s = (r.remaining_s or 0) > 0 and r.remaining_s or nil } -- cooldown left (M2 gap audit)
        end
    end
    m.extras, m.extras_at = { spells = out }, now
    return m.extras
end

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
    cast = { kind = "waiter", llm = true, moves = false, priority = "command", duration_s = 3, timeout_s = 60,
        detail_is_speech = true,
        description = "Cast one of your spells (wheel, then cast); verified by runes and cooldown. Pick from castable_spells by "
            .. "what it does. Instant: on you. Placed/aimed: at target, or omit it and you find a valid spot or aim yourself; "
            .. "a target out of reach (even a moving creature) is walked up to and cast at in this same call. Each spell's "
            .. "`how` (state.spells) says how it is really used: what to drop or stand by first, what to cast it on, or "
            .. "(cast_type instant_after_move) that it is held open while you walk_to somewhere. Never at players.",
        args = { type = "object", required = { "spell" }, properties = obj({
            spell = { type = "string", description = "Exact name from castable_spells." },
            walk_to = { description = "Required for, and only for, cast_type instant_after_move: walk here (look id or "
                .. "[x,y,z] m) while it is held open, then finish it; the result says where you ended (landed_at), how far "
                .. "from where you opened it (from_opened_m) and whether that brought you back (returned).",
                        anyOf = { { type = "string" }, { type = "array", items = { type = "number" }, minItems = 2, maxItems = 3 } } },
            target = { description = "Placed/aimed: look id or [x,y,z] m; omit to choose.",
                       anyOf = { { type = "string" }, { type = "array", items = { type = "number" }, minItems = 2, maxItems = 3 } } } }) },
        preconditions = { "the spell is unlocked and on your spell wheel", "you carry its runes", "it is not on cooldown" },
        ground = obj({ target = "thing" }),
        reasons = { "unknown_target", "ambiguous_target", "not_unlocked", "not_on_wheel", "not_enough_resources", "on_cooldown",
                    "busy", "unsafe", "too_far", "verification_failed", "interrupted", "timeout" } },
    spells = { kind = "read", llm = true, moves = false, duration_s = 0.2, timeout_s = 10,
        description = "Your spells: what each does, rune cost vs carried, cooldown, castable now and why not. all=true adds "
            .. "locked ones with their unlock level. Read-only.",
        args = { type = "object", properties = obj({
            all = { type = "boolean", default = false, description = "Include locked spells." },
            compact = { type = "boolean", default = true, description = "Ignored." } }) } },
}

return M
