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
    page_wait_s = 0.3,      -- after switching the wheel page: let the slices refresh
    select_wait_s = 1.0,    -- after the quick key: wait for a spell mode or the cast to start
    verify_s = 4.0,         -- after the cast input: runes / cooldown must change within this
    wait_s = 14,            -- waiter deadline (the bridge answers expire() after it)
    typo_cutoff = 0.8,      -- fuzzy name match only above this similarity, and only if unique
    default_radius_m = 5,   -- harm radius when a harmful spell has no Shape module
    place_max_m = 15,       -- fallback camera-to-target limit (SpellcastingComponent.MaxDistanceFromCameraToPlaceSpell)
    landed_tolerance_m = 3, -- a targeted spell that lands farther than max(this, its radius) is reported as a miss
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
    local last, now = (snap.last_cast or {})[st.asset], snap.server_time
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
    elseif r.wheel_slot % per >= M.cfg.quick_keys then
        why, detail = "not_on_wheel", st.name .. " sits in a spell wheel slot I can't reach yet (only slots 1-"
            .. M.cfg.quick_keys .. " of each wheel page have keys)."
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
        if not why and snap.casting then
            why, detail = "busy", "I'm already casting " .. tostring(snap.casting_name or snap.casting) .. "."
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
        each(u.try(function() return um.OurSpellActors end), function(e)
            local a = e
            if type(e) == "userdata" and not u.valid(e) then a = u.try(function() return e:Get() end) end
            if u.valid(a) then s.actors[u.short(a)] = { class = u.class_word(a), position = to_m(u.try(function() return a:K2_GetActorLocation() end)) } end
        end, 32)
    end
    local gs = u.find_first("GameStateBase")
    s.server_time = gs and u.try(function() return gs:GetServerWorldTimeSeconds() end)
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
    for id, obj in pairs(snap.objects) do
        local st = W.static(obj)
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
    table.sort(out, function(a, b)
        if a.unlocked ~= b.unlocked then return a.unlocked end
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
    if not t then
        local d = copy(r and r.data); d.detail = "I can't see " .. target .. " to aim at."
        return nil, api.fail("unknown_target", d)
    end
    return { kind = "thing", position = t.position, name = t.name, id = t.id }
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
    if not (acts.menu and acts.quick[slot + 1]) then
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

local function verified_result(job, df)
    local d = job.d
    d.verified = true
    d.runes_spent, d.cooldown_started = df.runes_spent, df.cooldown_started == true
    d.effects = { ge = df.ge_added, tags = df.tags_added }
    d.effect_verified = (#df.ge_added + #df.tags_added + #df.actors_added) > 0
    local a = df.actors_added[1]
    if a then
        d.spell_actor, d.landed_at = a.id, a.position
        if job.target.kind ~= "self" and a.position and job.target.position then
            d.landed_dist_m = math.floor(d3(a.position, job.target.position) * 10 + 0.5) / 10
        end
    end
    if job.target.kind ~= "self" then d.target = job.target.name or job.target.position end
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
    local api, cfg, t = job.api, M.cfg, job.api.now()
    if paused() then return failed(job, "companion_down", "paused", "I'm not in the world right now.") end
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
        if evs[i].ev == "on_cooldown" then return failed(job, "on_cooldown", "server_cooldown", job.row.name .. " is still recharging.") end
    end
    local df = M.diff(job.before, snap, job.st)
    if df.spent or df.cooldown_started then return verified_result(job, df) end
    local mode = snap.input_mode
    if job.phase == "open" then
        if mode == cfg.radial_mode then
            if job.page_wait and t < job.page_wait then return nil end
            -- press the key only when the open page shows THIS spell in that slot (never cast another)
            local icons = W.shown_icons(api)
            if not icons then return failed(job, "verification_failed", "wheel_unreadable", "I can't read my spell wheel right now.") end
            if icons[job.slot + 1] == job.st.icon then
                job.phase, job.until_t = "select", t + cfg.select_wait_s
                press(job, "quick" .. job.slot, job.acts.quick[job.slot + 1])
                return nil
            end
            job.flips = (job.flips or 0) + 1
            if job.flips > job.pages or not job.acts.next_page then
                return failed(job, "verification_failed", "page_not_found", "I couldn't find " .. job.row.name .. " on my spell wheel's pages.")
            end
            press(job, "next_page", job.acts.next_page)
            job.page_wait, job.until_t = t + cfg.page_wait_s, t + cfg.open_wait_s + cfg.page_wait_s
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
            if job.target.kind ~= "self" and job.target.position then
                local dist = W.aim(api, job.target.position)
                local lim = (snap.place_max_m and snap.place_max_m > 0) and snap.place_max_m or cfg.place_max_m
                if dist and dist > lim + 0.5 then
                    return failed(job, "too_far", "too_far", "That's too far away to place " .. job.row.name .. " (" .. math.floor(dist) .. " m; I can reach about " .. math.floor(lim) .. " m).")
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
            return failed(job, "verification_failed", "not_selected", "I opened the spell wheel but " .. job.row.name .. " didn't get selected.")
        end
        return nil
    end
    -- verify
    if t >= job.until_t then
        return failed(job, "verification_failed", "no_effect", "I tried to cast " .. job.row.name .. " but no runes were used and it didn't go on cooldown"
            .. (snap.casting and " (still casting)" or "") .. ".")
    end
    return nil
end
M._step = step

local function cast(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "spells need the bridge api (ctx.api)" } } end
    local job, f = new_cast(api, args or {})
    if not job then return f end
    local w = { kind = "cast" }
    w.poll = function()
        local ok, res = pcall(step, job)
        if not ok then res = failed(job, "body_error", "error", tostring(res)) end
        if res then cleanup(job); if not res.ok then job.d.why = res.data and res.data.why end; return res end
        return nil
    end
    w.expire = function()
        local res = failed(job, "timeout", "timeout", "Casting " .. job.row.name .. " took too long, so I stopped.")
        cleanup(job)
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
    cast = { kind = "waiter", llm = true, moves = false, priority = "command", duration_s = 3, timeout_s = 20,
        detail_is_speech = true,
        description = "Cast one of your spells like a player (spell wheel, then cast); checks runes were used and it went "
            .. "on cooldown. Use a spell from castable_spells/spells, chosen by what its description says it does. Instant "
            .. "spells affect you. Placed/aimed spells go at target, or in front of you if no target. Never at players. "
            .. "Runs alongside following.",
        args = { type = "object", required = { "spell" }, properties = obj({
            spell = { type = "string", description = "The spell's exact name as listed by spells (e.g. from castable_spells)." },
            target = { description = "Placed/aimed spells only: an id from look, or [x, y, z] metres. Omit for yourself / in front of you.",
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
