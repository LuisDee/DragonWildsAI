-- Item catalog generator (docs/design/robustness-and-item-catalog.md section 2).
-- Enumerates every UHeldEquipmentData (weapons, tools) and UWearableEquipmentData (armour),
-- loaded ones via FindAllOf plus unloaded ones via the asset registry, reads their fields
-- (names from the build-26161880 dump, Dominion.hpp) and writes the raw result as JSON.
-- tools/build_catalog.py drives it in batches and normalises the output into
-- data/items_<build>.json.
--
-- Run via debug_run {module="catalog", args={...}}. Runs on the game thread.
--   loaded=true      describe every loaded item found by FindAllOf (default true)
--   registry=true    list held/wearable assets from the asset registry (default true)
--   registry_mode    "class" (GetAssetsByClass, default) or "path" (GetAssetsByPath per root)
--   load=false       opt-in: also describe registry entries [offset+1 .. offset+limit] of the
--                    sorted registry list, loading unloaded ones with LoadAsset (synchronous,
--                    stalls the game thread, so keep limit small)
--   offset=0, limit=10
--   paths={...}      describe exactly these object paths (loads them only if load=true)
--   attacks=true     resolve action classes, attack-data chains and ranged collections
--   soft=true        read soft class/object paths (HeldEquipmentActorClass, Icon)
--   kismet_soft=false opt-in fallback: KismetSystemLibrary:Conv_SoftClassReferenceToString
--                    when the soft path could not be read directly (passes a struct to a UFunction)
--   refresh=false    re-query the registry instead of the cached list from an earlier call
--   out=<path>       JSON output (default <DW_MOD_LOG_DIR>/../catalog_<ts>.json)
--   sample=3, build=<string>
-- Returns counts, the batch window (next_offset), the out path and a few sample items.
--
-- Crash safety (docs/DISCOVERIES.md "ROOT CAUSES"): pcall cannot catch native access
-- violations. Everything here is property reads plus three kinds of call: GetAssetRegistry()
-- (no args), GetAssetsByClass/GetAssetsByPath (a two-FName struct or one FName, an empty out
-- table, a bool) and UE4SS's native LoadAsset(string). A breadcrumb (catalog_step) is logged
-- before each of them and before each item is read, so a crash dump can be matched to a step.
local jsonutil = require("jsonutil")

local M = {}

local DOM = "/Script/Dominion"
-- Concrete data classes from Dominion.hpp. Bases are queried with subclass search; the
-- subclasses are also queried exactly, in case subclass search finds nothing in a cooked build.
local HELD_CLASSES = { "HeldEquipmentData", "FishingRodHeldEquipmentData", "HarvestToolEquipmentData",
                       "HeldContainerEquipmentData", "HeldTreeSeedData", "SeedHeldEquipmentData",
                       "ShieldData", "SpadeToolEquipmentData" }
local WEAR_CLASSES = { "WearableEquipmentData", "JewelleryData" }
local BASES = { HeldEquipmentData = true, WearableEquipmentData = true }
-- Roots for registry_mode="path" (mount points seen in the object dump); roots of loaded items are added.
local PATH_ROOTS = { "/Game", "/DowdunReach", "/UmbralSands", "/ScornedWilderness" }
local ACTION_KINDS = { -- checked in order with UClass:IsChildOf
    { "melee", "PlayerMeleeAttackAction" }, { "ranged", "PlayerRangedAttackAction" },
    { "magic", "PlayerMagicAttackAction" }, { "aim", "PlayerAimAction" }, { "block", "PlayerBlockAction" },
    { "harvest", "PlayerHarvestAction" }, { "evade", "PlayerEvadeAction" }, { "drop", "PlayerDropHeldItemAction" },
}

-- Enum names (Dominion_enums.hpp). Values are also kept raw.
local SLOT = { [0] = "Head", "Body", "Legs", "Cape", "Trinket", "Ammo", "MagicAmmo", "CrossbowBolts", "PlantSeed",
               "HeldAny", "HeldOnlyRight", "HeldOnlyLeft", "HeldTwoHanded", "FishingBait", "JournalItem", "Necklace" }
local HAND = { [0] = "Right", "Left" }
local ARMOR_WEIGHT = { [0] = "None", "Light", "Medium", "Heavy" }
local MAGNITUDE = { [0] = "None", "VeryWeak", "Weak", "Medium", "Strong", "VeryStrong" }
local AMMO = { [0] = "None", "Self", "Arrows", "CrossbowBolts", "FishingBait", "Runes" }
local POSE = { [0] = "Unarmed", "Default", "Ranged" }
local DAMAGE_CLASS = { [0] = "None", "Melee", "Magical", "Ranged" }

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function isobj(o) local t = type(o); return t == "userdata" or t == "table" end -- tables: offline mocks
local function valid(o) return isobj(o) and try(function() return o:IsValid() end) == true end
local function fullname(o) return valid(o) and try(function() return o:GetFullName() end) or nil end
-- "Class /Path/Pkg.Obj" -> "/Path/Pkg.Obj"
local function opath(o) local f = fullname(o); return f and (f:match("^%S+%s+(.+)$") or f) or nil end
local function str(v)
    if v == nil then return nil end
    local s = try(function() return v:ToString() end)
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    return s
end
-- UE4SS returns an invalid-object userdata (not nil) for a missing member, so type-check reads.
local function num(v) return type(v) == "number" and v or nil end
local function bool(v) if type(v) == "boolean" then return v end end
local function get(o, k) return try(function() return o[k] end) end
local function enum(v, names) v = num(v); return v, v and names[v] or nil end
local function unwrap(e) local v = try(function() return e:get() end); if v == nil then return e end; return v end

-- Iterate a TArray userdata (read-only), capped.
local function each(arr, fn, cap)
    if arr == nil then return end
    local n = num(try(function() return arr:GetArrayNum() end))
    if not n or n <= 0 then return end
    local count, limit = 0, cap or 256
    pcall(function()
        arr:ForEach(function(_, e)
            count = count + 1
            if count > limit then return true end
            fn(unwrap(e))
        end)
    end)
end

local function tag(t) return t and str(get(t, "TagName")) or nil end
local function tags(c)
    local out = {}
    each(c and get(c, "GameplayTags"), function(t) out[#out + 1] = tag(t) end)
    return out
end
local function row(h)
    if h == nil then return nil end
    local r = str(get(h, "RowName"))
    return r and { table = opath(get(h, "DataTable")), row = r } or nil
end

local function crumb(log, step, data) log.event("catalog_step", { step = step, data = data }) end

-- --------------------------------------------------------------------- soft references

local function softref(ctx, sp, is_class)
    if not ctx.soft or not isobj(sp) then return nil end
    local r = {}
    r.path = str(try(function() return sp:GetObjectID():GetAssetPathName() end))
    local sub = str(try(function() return sp:GetObjectID():GetSubPathString() end))
    if sub then r.subpath = sub end
    local loaded = try(function() return sp:GetWeakPtr():Get() end)
    if valid(loaded) then r.loaded = opath(loaded) end
    if not r.path and ctx.kismet_soft and is_class and valid(ctx.ksl) then
        crumb(ctx.log, "kismet_soft_to_string", nil)
        r.kismet = str(try(function() return ctx.ksl:Conv_SoftClassReferenceToString(sp) end))
    end
    if next(r) == nil then return nil end
    return r
end

-- --------------------------------------------------------------------- actions and attacks

local function describe_attack(ctx, cls, depth)
    if not valid(cls) then return nil end
    local path = opath(cls)
    if not path or ctx.attacks[path] then return path end
    local rec = jsonutil.object()
    ctx.attacks[path] = rec -- placeholder first: breaks NextAttackClass cycles
    ctx.n_attacks = ctx.n_attacks + 1
    local cdo = try(function() return cls:GetCDO() end)
    if not valid(cdo) then rec.error = "no CDO"; return path end
    rec.damage = num(get(cdo, "DamageAmount"))
    rec.damage_class, rec.damage_class_name = enum(get(cdo, "DamageClass"), DAMAGE_CLASS)
    rec.uses_weapon = bool(get(cdo, "bUsesWeapon"))
    rec.single_target = bool(get(cdo, "bDamageSingleTarget"))
    rec.force = num(get(cdo, "Force"))
    rec.stamina_cost = num(get(cdo, "StaminaCost"))
    rec.special_charge_cost = num(get(cdo, "SpecialChargeCost"))
    rec.attack_property_flags = num(get(cdo, "AttackPropertyFlags"))
    rec.montage_preset = num(get(cdo, "MontagePreset"))
    rec.max_move_speed = bool(get(cdo, "bLimitMovementSpeedDuringAttack")) and num(get(cdo, "MaxMovementSpeedDuringAttack")) or nil
    rec.damage_shapes = num(try(function() return cdo.TimedDamageShapes:GetArrayNum() end))
    if bool(get(cdo, "bHasOverrideWeaponDamageTypes")) then rec.override_damage_types = tags(get(cdo, "OverrideWeaponDamageTypes")) end
    rec.required_perk_for_next = opath(get(cdo, "RequiredPerkForNextAttack"))
    if depth < 16 and ctx.n_attacks < 4000 then
        rec.next = describe_attack(ctx, get(cdo, "NextAttackClass"), depth + 1)
        rec.next_no_perk = describe_attack(ctx, get(cdo, "NextAttackClassNoRequiredPerk"), depth + 1)
    end
    return path
end

local function base_class(ctx, name)
    if ctx.bases[name] == nil then
        local c = StaticFindObject(DOM .. "." .. name)
        ctx.bases[name] = valid(c) and c or false
    end
    return ctx.bases[name] or nil
end

local function describe_action(ctx, cls)
    if not valid(cls) then return nil end
    local path = opath(cls)
    if not path or ctx.actions[path] then return path end
    local rec = jsonutil.object()
    ctx.actions[path] = rec
    for _, k in ipairs(ACTION_KINDS) do
        local b = base_class(ctx, k[2])
        if b and try(function() return cls:IsChildOf(b) end) == true then rec.kind = k[1]; break end
    end
    local cdo = try(function() return cls:GetCDO() end)
    if not valid(cdo) then rec.error = "no CDO"; return path end
    rec.name = str(get(cdo, "ActionName"))
    rec.requires_holding = bool(get(cdo, "bRequiresHolding"))
    rec.can_be_held = bool(get(cdo, "bCanBeHeld"))
    rec.required_perk = opath(get(cdo, "RequiredPerk"))
    if rec.kind == "melee" or rec.kind == "ranged" or rec.kind == nil then
        rec.attack_data = describe_attack(ctx, get(cdo, "AttackData"), 0)
    end
    for _, o in ipairs({ "PrimaryActionOverride", "SecondaryActionOverride", "SpecialActionOverride" }) do
        local c = get(cdo, o)
        if valid(c) then rec[o] = opath(c) end
    end
    return path
end

local function describe_collection(ctx, cls)
    if not valid(cls) then return nil end
    local path = opath(cls)
    if not path or ctx.collections[path] then return path end
    local rec = jsonutil.object()
    ctx.collections[path] = rec
    local cdo = try(function() return cls:GetCDO() end)
    if not valid(cdo) then rec.error = "no CDO"; return path end
    rec.quick_attack = describe_attack(ctx, get(cdo, "QuickAttackData"), 0)
    rec.full_attack = describe_attack(ctx, get(cdo, "FullAttackData"), 0)
    rec.trick_shot_damage_multiplier = num(get(cdo, "TrickShotDamageMultiplier"))
    rec.max_charge_up = num(get(cdo, "MaxChargeUpDuration"))
    rec.allow_move_quick = bool(get(cdo, "bAllowMovementDuringQuickAttack"))
    return path
end

-- --------------------------------------------------------------------- items

local function describe_item(ctx, o, source)
    local r = { path = opath(o), source = source }
    r.class = str(try(function() return o:GetClass():GetFName() end))
    local held_base, wear_base = base_class(ctx, "HeldEquipmentData"), base_class(ctx, "WearableEquipmentData")
    if held_base and try(function() return o:IsA(held_base) end) == true then r.kind = "held"
    elseif wear_base and try(function() return o:IsA(wear_base) end) == true then r.kind = "wearable" end

    -- UItemData
    r.name = str(get(o, "Name"))
    r.flavour = str(get(o, "FlavourText"))
    r.category_tag = tag(get(o, "Category"))
    r.item_status_tag = tag(get(o, "ItemStatus"))
    r.filter_tags = tags(get(o, "ItemFilterTags"))
    r.power_level = num(get(o, "PowerLevel"))
    r.weight = num(get(o, "Weight"))
    r.max_stack = num(get(o, "MaxStackSize"))
    r.base_durability = num(get(o, "BaseDurability"))
    r.masterwork = bool(get(o, "bIsMasterworkItem"))
    r.masterwork_type = num(get(o, "MasterworkType"))
    r.bound_to_player = bool(get(o, "bBoundToPlayer"))
    r.drop_on_death = bool(get(o, "bDropOnDeath"))
    r.skill_used = opath(get(o, "SkillUsed"))
    r.use_custom_stats = bool(get(o, "bUseCustomStatDetails"))
    local stats = {}
    each(get(o, "CustomStatDetails"), function(s)
        stats[#stats + 1] = { name = str(get(s, "Name")), value = str(get(s, "Value")) }
    end, 32)
    r.custom_stats = stats
    r.icon = softref(ctx, get(o, "Icon"), false)

    -- UEquipmentData
    r.slot, r.slot_name = enum(get(o, "Slot"), SLOT)
    r.hand, r.hand_name = enum(get(o, "HandPreference"), HAND)
    r.tier = num(get(o, "Tier"))
    r.is_weapon = bool(get(o, "bIsAWeapon"))
    r.distance_offset = num(get(o, "DistanceOffset"))
    r.associated_skill = opath(get(o, "AssociatedSkill"))
    r.granted_tags = tags(get(o, "GrantedTags"))
    local effects = {}
    each(get(o, "GrantedEffects"), function(c) effects[#effects + 1] = opath(c) end, 32)
    r.granted_effects = effects
    r.perk_required = opath(get(o, "SkillPerkRequiredToEquip"))
    r.recipe_required = opath(get(o, "RecipeRequiredToEquip"))
    r.entitlement_required = opath(get(o, "EntitlementRequiredToEquip"))

    if r.kind == "held" then
        local h = {}
        h.actor_class = softref(ctx, get(o, "HeldEquipmentActorClass"), true)
        h.pose, h.pose_name = enum(get(o, "AnimationPoseType"), POSE)
        h.damage_multiplier = num(get(o, "DamageMultiplier"))
        h.additional_damage_multiplier = num(get(o, "AdditionalDamageMultiplier"))
        h.blocking_damage_negation = num(get(o, "BlockingDamageNegation"))
        h.additional_blocking_damage_negation = num(get(o, "AdditionalBlockingDamageNegation"))
        h.stamina_cost_multiplier = num(get(o, "StaminaCostMultiplier"))
        h.crit_chance_increase = num(get(o, "CriticalHitChanceIncrease"))
        h.damage_types = tags(get(o, "DamageTypes"))
        h.ammo, h.ammo_name = enum(get(o, "AmmoType"), AMMO)
        h.required_ammo_tag = tag(get(o, "RequiredAmmoCategory"))
        h.requires_reload = bool(get(o, "bRequiresReload"))
        h.reload_duration = num(get(o, "ReloadDuration"))
        h.projectile_class = opath(get(o, "ProjectileClass"))
        h.power_level_row = row(get(o, "BaseHeldEquipmentPowerLevelRowHandle"))
        h.damage_negation_row = row(get(o, "BaseHeldEquipmentDamageNegationRowHandle"))
        h.exclusive_loadout_only = bool(get(o, "bExclusiveLoadoutOnlyEquipment"))
        h.loses_durability_on_attack = bool(get(o, "bLosesDurabilityOnAttack"))
        local ranged, magic = get(o, "RangedAttackCollection"), get(o, "MagicAttackCollection")
        local acts = jsonutil.object()
        for k, prop in pairs({ primary = "PrimaryActionClass", primary_jump = "PrimaryJumpActionClass",
                               primary_sprint = "PrimarySprintActionClass", primary_visceral = "PrimaryVisceralActionClass",
                               secondary = "SecondaryActionClass", special = "SpecialActionClass" }) do
            local c = get(o, prop)
            if valid(c) then acts[k] = ctx.attacks_on and describe_action(ctx, c) or opath(c) end
        end
        h.actions = acts
        if valid(ranged) then h.ranged_collection = ctx.attacks_on and describe_collection(ctx, ranged) or opath(ranged) end
        if valid(magic) then h.magic_collection = opath(magic) end
        r.held = h
    elseif r.kind == "wearable" then
        local w = {}
        w.armor_weight, w.armor_weight_name = enum(get(o, "ArmorWeight"), ARMOR_WEIGHT)
        w.warmth, w.warmth_name = enum(get(o, "WarmthMagnitude"), MAGNITUDE)
        w.data_row = row(get(o, "WearableEquipmentDataTableRowHandle"))
        w.male_mesh = opath(get(o, "MaleMeshData"))
        w.female_mesh = opath(get(o, "FemaleMeshData"))
        w.equip_delay_combat = num(get(o, "InsideCombatEquipDelay"))
        w.equip_delay = num(get(o, "OutsideCombatEquipDelay"))
        r.wearable = w
    end
    return r
end

-- --------------------------------------------------------------------- enumeration

local function find_loaded()
    local seen, list = {}, {}
    for _, group in ipairs({ HELD_CLASSES, WEAR_CLASSES }) do
        for _, cls in ipairs(group) do
            for _, o in ipairs(FindAllOf(cls) or {}) do
                local p = valid(o) and opath(o)
                if p and not seen[p] and not p:find("Default__", 1, true) then
                    seen[p] = true
                    list[#list + 1] = { path = p, obj = o }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

local function get_registry(log)
    crumb(log, "get_asset_registry", nil)
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local reg = valid(helpers) and try(function() return helpers:GetAssetRegistry() end) or nil
    if not valid(reg) then reg = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryImpl") end
    return valid(reg) and reg or nil
end

-- Call an IAssetRegistry UFunction on the impl: the UFunction lives on the interface class
-- (/Script/AssetRegistry.AssetRegistry), so look it up there first; fall back to member lookup.
local function reg_call(reg, fname, ...)
    local f = StaticFindObject("/Script/AssetRegistry.AssetRegistry:" .. fname)
    if valid(f) then return f(reg, ...) end
    return reg[fname](reg, ...)
end

local function add_entries(out, entries, filter)
    local n = 0
    for _, e in ipairs(out) do
        local ad = unwrap(e)
        local pkg, name = str(get(ad, "PackageName")), str(get(ad, "AssetName"))
        local cls = str(try(function() return ad.AssetClassPath.AssetName end))
        if pkg and name and (not filter or (cls and filter[cls])) then
            local p = pkg .. "." .. name
            if not entries[p] then entries[p] = { path = p, class = cls }; n = n + 1 end
        end
    end
    return n
end

local function registry_list(log, mode, extra_roots, errors)
    local reg = get_registry(log)
    if not reg then errors[#errors + 1] = "asset registry not found"; return nil end
    local entries, calls = {}, {}
    if mode == "path" then
        local filter, roots, seen = {}, {}, {}
        for _, c in ipairs(HELD_CLASSES) do filter[c] = true end
        for _, c in ipairs(WEAR_CLASSES) do filter[c] = true end
        for _, r in ipairs(PATH_ROOTS) do if not seen[r] then seen[r] = true; roots[#roots + 1] = r end end
        for _, r in ipairs(extra_roots) do if not seen[r] then seen[r] = true; roots[#roots + 1] = r end end
        for _, root in ipairs(roots) do
            local out = {}
            crumb(log, "get_assets_by_path", { root = root })
            local ok, err = pcall(function() reg_call(reg, "GetAssetsByPath", FName(root), out, true, false) end)
            calls[#calls + 1] = { root = root, ok = ok, err = (not ok) and tostring(err) or nil, raw = #out,
                                  added = ok and add_entries(out, entries, filter) or 0 }
        end
    else
        for _, group in ipairs({ HELD_CLASSES, WEAR_CLASSES }) do
            for _, cls in ipairs(group) do
                local out, sub = {}, BASES[cls] == true
                crumb(log, "get_assets_by_class", { class = cls, sub = sub })
                local ok, err = pcall(function()
                    reg_call(reg, "GetAssetsByClass", { PackageName = FName(DOM), AssetName = FName(cls) }, out, sub)
                end)
                calls[#calls + 1] = { class = cls, sub = sub, ok = ok, err = (not ok) and tostring(err) or nil,
                                      raw = #out, added = ok and add_entries(out, entries, nil) or 0 }
            end
        end
    end
    local list = {}
    for _, e in pairs(entries) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list, calls
end

local function write_json(path, value)
    local s = jsonutil.encode(value)
    local f, err = io.open(path, "wb")
    if not f then return false, tostring(err) end
    f:write(s)
    f:close()
    return true, #s
end

local function default_out()
    local dir = os.getenv("DW_MOD_LOG_DIR") or "."
    return dir .. "/../catalog_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".json"
end

function M.run(log, args)
    args = args or {}
    local t0 = os.clock()
    local ctx = {
        log = log, soft = args.soft ~= false, kismet_soft = args.kismet_soft == true,
        attacks_on = args.attacks ~= false, bases = {},
        actions = jsonutil.object(), attacks = jsonutil.object(), collections = jsonutil.object(), n_attacks = 0,
    }
    if ctx.kismet_soft then ctx.ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    local errors, items, described = {}, {}, {}
    local function describe(o, source)
        local p = opath(o)
        if not p or described[p] then return end
        described[p] = true
        crumb(log, "describe_item", { path = p })
        local ok, rec = pcall(describe_item, ctx, o, source)
        if ok then items[#items + 1] = rec
        else errors[#errors + 1] = { path = p, stage = "describe", err = tostring(rec) } end
    end

    -- 1. Loaded items.
    local loaded = {}
    if args.loaded ~= false then
        crumb(log, "find_all_of", nil)
        loaded = find_loaded()
        for _, e in ipairs(loaded) do if valid(e.obj) then describe(e.obj, "loaded") end end
    end

    -- 2. Registry listing (cached across debug_run calls in a global; each call reloads this file).
    local registry, reg_calls
    if args.registry ~= false then
        local mode = args.registry_mode == "path" and "path" or "class"
        local cache = rawget(_G, "DW_CATALOG_REGISTRY")
        if cache and cache.mode == mode and not args.refresh then
            registry, reg_calls = cache.list, { { cached = true } }
        else
            local roots, seen = {}, {}
            for _, e in ipairs(loaded) do
                local root = e.path:match("^(/[^/]+)/")
                if root and not seen[root] then seen[root] = true; roots[#roots + 1] = root end
            end
            registry, reg_calls = registry_list(log, mode, roots, errors)
            if registry and #registry > 0 then rawset(_G, "DW_CATALOG_REGISTRY", { mode = mode, list = registry }) end
        end
        for _, e in ipairs(registry or {}) do
            e.loaded = described[e.path] == true or valid(StaticFindObject(e.path))
        end
    end

    -- 3. Explicit paths or a registry window, loading only when asked.
    local targets, window = {}, nil
    if type(args.paths) == "table" then
        for _, p in ipairs(args.paths) do if type(p) == "string" then targets[#targets + 1] = p end end
    elseif args.load == true and registry then
        local offset = math.max(0, math.floor(tonumber(args.offset) or 0))
        local limit = math.max(1, math.min(200, math.floor(tonumber(args.limit) or 10)))
        for i = offset + 1, math.min(#registry, offset + limit) do targets[#targets + 1] = registry[i].path end
        local nxt = offset + limit
        window = { offset = offset, limit = limit, total = #registry, next_offset = nxt < #registry and nxt or nil,
                   done = nxt >= #registry }
    end
    local loaded_now, load_failed = 0, 0
    for _, p in ipairs(targets) do
        if not described[p] then
            local o, source = StaticFindObject(p), "found"
            if not valid(o) and args.load == true then
                crumb(log, "load_asset", { path = p })
                local ok, obj = pcall(LoadAsset, p)
                if ok and valid(obj) then o, source = obj, "loaded_now"; loaded_now = loaded_now + 1
                else
                    load_failed = load_failed + 1
                    errors[#errors + 1] = { path = p, stage = "load", err = ok and "not loaded" or tostring(obj) }
                end
            end
            if valid(o) then describe(o, source)
            elseif args.load ~= true then errors[#errors + 1] = { path = p, stage = "find", err = "not loaded (load=false)" } end
        end
    end

    local counts = {
        loaded_found = #loaded, registry = registry and #registry or nil, described = #items,
        loaded_now = loaded_now, load_failed = load_failed, actions = 0, attacks = ctx.n_attacks,
        errors = #errors,
    }
    for _ in pairs(ctx.actions) do counts.actions = counts.actions + 1 end

    local out = args.out or default_out()
    local doc = {
        schema = "dw_catalog_raw/1", build = args.build, generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        args = { loaded = args.loaded ~= false, registry = args.registry ~= false, load = args.load == true,
                 registry_mode = args.registry_mode or "class", attacks = ctx.attacks_on, soft = ctx.soft },
        counts = counts, window = window, registry_calls = reg_calls, registry = registry,
        items = items, actions = ctx.actions, attacks = ctx.attacks, collections = ctx.collections, errors = errors,
    }
    crumb(log, "write_json", { out = out, items = #items })
    local wok, wres = write_json(out, doc)
    local ms = math.floor((os.clock() - t0) * 1000)

    local sample = {}
    for i = 1, math.min(#items, math.floor(tonumber(args.sample) or 3)) do
        local it = items[i]
        sample[#sample + 1] = { path = it.path, name = it.name, kind = it.kind, slot = it.slot_name, tier = it.tier,
                                category_tag = it.category_tag,
                                actor_class = it.held and it.held.actor_class or nil,
                                primary = it.held and it.held.actions and it.held.actions.primary or nil }
    end
    local errs = {}
    for i = 1, math.min(#errors, 10) do errs[i] = errors[i] end
    local res = { ok = wok, out = out, bytes = wok and wres or nil, write_error = (not wok) and wres or nil,
                  counts = counts, window = window, registry_calls = reg_calls, cpu_ms = ms,
                  sample = sample, errors = errs }
    log.event("catalog_done", { out = out, counts = counts, window = window, cpu_ms = ms, write_ok = wok })
    return res
end

return M
