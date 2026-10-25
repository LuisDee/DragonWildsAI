-- X1 (docs/research/2026-10-25-spells-and-weaknesses.md section 6): READ-ONLY spell catalog dump.
-- Temporary home: mod/scripts (debug_run only searches mod/scripts until mod/experiments is wired).
-- Run: debug_run {"module":"spell_dump","args":{"out":"C:/gameserver/data/spells_26161880.json"}}
--
-- What it reads (property reads only; no UFunction calls except UE4SS's own GetFullName/IsValid/
-- GetCDO/ToString/GetArrayNum/ForEach wrappers):
--   * every loaded UUtilitySpellData (FindAllOf): display name, cooldown (+ perk modifier), cast type,
--     owning perk (+ its skill and level), and each module in Modules.Modules[] with its class and
--     the fields that matter (rune costs, gameplay effects, held-equipment effects, damage, duration,
--     utility-spell actor class, spawned actor class, launch vector)
--   * combat jump-attack spells (DA_Spell_*_JumpAttack DominionSpellData) as a short list
--   * the gameplay-effect CDOs the spells apply (Tempest Shield health/duration etc.)
--   * the Windstep explosion actor (BP_WindstepExplosion_C) and Tempest Shield burst: their
--     DelayedDamageInfliction template (damage, force, owner/equipment flags, sphere radius)
--   * SkillPerkModule_Spell objects (perk -> spell mapping)
--   * Luis (every real player): PC SpellcastingComponent.SelectedSpells (the wheel),
--     ProgressComponent.SpellsUnlocked (TSet), SkillComponent.Skills (XP), SkillPerkComponent
--     active perks, rune stacks in InventoryComponent.ItemSlots, and the character's
--     PlayerUtilityMagicComponent.LastCastTimeBySpellData (TMap)
--   * the puppet's current gameplay-effect instances (baseline for X4)
-- Usage metadata (role, preconditions, use_when) is merged from body/spells.lua META so the JSON
-- is the single catalog the brain reads.
local jsonutil = require("jsonutil")

local M = {}

local BUILD = "26161880"
local CAST_TYPE = { [0] = "Instant", "Placed", "Aimed", "AllowMovementThenCastInstant" }
local GE_TARGET = { [0] = "OverlappedTargets", "CollisionTarget", "SpellOwner", "SpellTargetActors" }
local DAMAGE_CLASS = { [0] = "None", "Melee", "Magical", "Ranged" }
local SKILL = { [0] = "Invalid", "Agility", "Artisan", "Attack", "Construction", "Cooking", "Defence", "Herblore",
                "Magic", "Mining", "Ranged", "Runecrafting", "Thieving", "Woodcutting" }
local EXPLOSIONS = {
    windstep = "/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/BP_WindstepExplosion.BP_WindstepExplosion_C",
    tempest_shield = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/BP_TempestShieldExplosion.BP_TempestShieldExplosion_C",
}

-- ------------------------------------------------------------------ safe readers (catalog.lua idioms)
local function try(f) local ok, v = pcall(f); if ok then return v end end
local function isobj(o) local t = type(o); return t == "userdata" or t == "table" end
local function valid(o) return isobj(o) and try(function() return o:IsValid() end) == true end
local function fullname(o) return valid(o) and try(function() return o:GetFullName() end) or nil end
local function opath(o) local f = fullname(o); return f and (f:match("^%S+%s+(.+)$") or f) or nil end
local function cls_word(o) local f = fullname(o); return f and f:match("^(%S+)") or nil end
local function short(o) local p = opath(o); return p and (p:match("([%w_]+)$") or p) or nil end
local function str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v ~= "" and v or nil end
    local s = try(function() return v:ToString() end)
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    return s
end
local function num(v) return type(v) == "number" and v or nil end
local function bool(v) if type(v) == "boolean" then return v end end
local function get(o, k) return try(function() return o[k] end) end
local function unwrap(e) local v = try(function() return e:get() end); if v == nil then return e end; return v end

local function each(arr, fn, cap)
    if arr == nil then return 0 end
    local n = num(try(function() return arr:GetArrayNum() end))
    if not n or n <= 0 then return 0 end
    local count, limit = 0, cap or 256
    pcall(function()
        arr:ForEach(function(_, e)
            count = count + 1
            if count > limit then return true end
            fn(unwrap(e))
        end)
    end)
    return count
end

-- TMap: UE4SS experimental TMap:ForEach(function(k, v) ... end) with RemoteUnrealParam k/v.
local function each_map(m, fn, cap)
    local n, ok, err = 0, nil, nil
    if m == nil then return 0, "nil" end
    ok, err = pcall(function()
        m:ForEach(function(k, v)
            n = n + 1
            if n > (cap or 256) then return true end
            fn(unwrap(k), unwrap(v))
        end)
    end)
    return n, (not ok) and tostring(err) or nil
end

-- TSet: UE4SS support is version dependent; try ForEach with either callback shape.
local function each_set(s, fn, cap)
    if s == nil then return 0, "nil" end
    local n = 0
    local ok, err = pcall(function()
        s:ForEach(function(a, b)
            n = n + 1
            if n > (cap or 512) then return true end
            local e = b ~= nil and b or a
            fn(unwrap(e))
        end)
    end)
    return n, (not ok) and tostring(err) or nil
end

local function tag(t) return t and str(get(t, "TagName")) or nil end
local function tags(c)
    local out = {}
    each(c and get(c, "GameplayTags"), function(t) out[#out + 1] = tag(t) end)
    return out
end

local function softpath(sp)
    if not isobj(sp) then return nil end
    local p = str(try(function() return sp:GetObjectID():GetAssetPathName() end))
    local sub = str(try(function() return sp:GetObjectID():GetSubPathString() end))
    if p and sub then p = p .. ":" .. sub end
    if not p then
        local loaded = try(function() return sp:GetWeakPtr():Get() end)
        if valid(loaded) then p = opath(loaded) end
    end
    return p
end

local function vec(v)
    if not isobj(v) then return nil end
    local x, y, z = num(get(v, "X")), num(get(v, "Y")), num(get(v, "Z"))
    if x and y and z then return { x, y, z } end
end

local function crumb(log, step, data) pcall(log.event, "spell_dump_step", { step = step, data = data }) end

-- ------------------------------------------------------------------ gameplay effect CDOs
local function ge_info(ctx, cls)
    if not valid(cls) then return nil end
    local path = opath(cls)
    if not path then return nil end
    if ctx.effects[path] then return path end
    local cdo = try(function() return cls:GetCDO() end)
    local r = jsonutil.object({ class = cls_word(cdo) })
    if valid(cdo) then
        r.name = str(get(cdo, "Name"))
        r.dev_name = str(get(cdo, "DevName"))
        r.instance_class = opath(get(cdo, "InstanceClass"))
        r.single_instance = bool(get(cdo, "bSingleInstance"))
        r.add_tags = tags(get(cdo, "AddTags"))
        r.attribute = opath(get(cdo, "AttributeToModify"))
        -- UTempestShieldGameplayEffectData (DOM:35919)
        r.effect_health_base = num(get(cdo, "EffectHealthBase"))
        r.effect_health_per_attack_level = num(get(cdo, "EffectHealthPerAttackSkillLevel"))
        r.blocking_repulse_force = num(get(cdo, "BlockingRepulseForce"))
        r.actor_on_expiry = opath(get(cdo, "ActorClassToSpawnOnExpiry"))
        local d = get(cdo, "EffectDurationInGameTime")
        if isobj(d) and num(get(d, "Seconds")) then
            r.duration_game_time = { d = num(get(d, "Days")), h = num(get(d, "Hours")),
                                     m = num(get(d, "Minutes")), s = num(get(d, "Seconds")) }
        end
        local kids = {}
        each(get(cdo, "ChildGEsGroups"), function(g)
            each(get(g, "GameplayEffects"), function(c) kids[#kids + 1] = opath(c) or opath(get(c, "DataClass")) end, 16)
        end, 16)
        if #kids > 0 then r.children = kids end
    end
    ctx.effects[path] = r
    return path
end

local function heed_info(ctx, d)
    if not valid(d) then return nil end
    local path = opath(d)
    if ctx.held_effects[path] then return path end
    ctx.held_effects[path] = jsonutil.object({
        name = str(get(d, "Name")),
        category = num(get(d, "EffectCategory")),
        has_time_limit = bool(get(d, "bHasTimeLimit")),
        time_limit_s = num(get(d, "TimeLimitSeconds")),
        additive_damage_multiplier = num(get(d, "AdditiveDamageMultiplier")),
        force_multiplier = num(get(d, "ForceMultiplier")),
        additive_damage_types = tags(get(d, "AdditiveDamageTypes")),
        additional_damage_event = bool(get(d, "bAdditionalDamageEvent")),
        additional_damage_fraction = num(get(d, "AdditionalDamageFraction")),
        additional_damage_types = tags(get(d, "AdditionalDamageTypes")),
        remove_on_unequip = bool(get(d, "bRemoveOnUnequip")),
    })
    return path
end

-- ------------------------------------------------------------------ perks
local function perk_info(ctx, perk)
    if not valid(perk) then return nil end
    local path = opath(perk)
    if ctx.perks[path] then return path end
    local r = jsonutil.object({ name = str(get(perk, "PerkName")) })
    local ui = get(perk, "PerkUnlockInfo")
    if isobj(ui) then
        r.skill = softpath(get(ui, "AssociatedSkill"))
        r.skill_name = r.skill and r.skill:match("([%w_]+)$") or nil
        r.level = num(get(ui, "RequiredSkillLevel"))
    end
    ctx.perks[path] = r
    return path
end

-- ------------------------------------------------------------------ modules
local function module_info(ctx, m)
    local kind = cls_word(m) or "?"
    local r = jsonutil.object({ kind = kind, name = str(get(m, "ModuleName")) })
    local k = kind:gsub("^SpellModule_", "")
    if k == "CostItems" then
        local costs = {}
        each(get(m, "ItemsCostInfo"), function(c)
            local item = get(c, "ItemData")
            costs[#costs + 1] = { item = opath(item), rune = (short(item) or ""):match("^ITEM_Rune_(%w+)$"), count = num(get(c, "Count")) }
        end, 16)
        r.costs = costs
        r.use_magic_ammo = bool(get(m, "bUseMagicAmmo"))
        r.cost_multiplier_attribute = opath(get(m, "ItemCostMultiplierAttribute"))
    elseif k == "CostStamina" or k == "CostSpecialCharge" then
        for _, f in ipairs({ "StaminaCost", "Cost", "Amount", "SpecialChargeCost" }) do
            local v = num(get(m, f)); if v then r[f] = v end
        end
    elseif k == "GameplayEffect" then
        r.effect = ge_info(ctx, get(m, "GameplayEffect"))
        r.upgraded_effect = ge_info(ctx, get(m, "UpgradedGameplayEffect"))
        r.upgrade_perk = opath(get(m, "PerkForUpgradedGameplayEffect"))
        local t = num(get(m, "GameplayEffectSpellTarget"))
        r.target = t and (GE_TARGET[t] or t) or nil
        r.ignore_owner = bool(get(m, "bIgnoreSpellOwner"))
        r.removal_strategy = opath(get(m, "GameplayEffectRemovalStrategy"))
    elseif k == "HeldEquipmentEffect" then
        r.held_effect = heed_info(ctx, get(m, "HeldEquipmentEffectData"))
    elseif k == "ExpireAfterDuration" then
        r.duration_s = num(get(m, "Duration"))
    elseif k == "ExpireAfterDistance" then
        for _, f in ipairs({ "Distance", "MaxDistance" }) do local v = num(get(m, f)); if v then r[f] = v end end
    elseif k:find("Damage", 1, true) then
        r.damage = num(get(m, "DamageAmount"))
        r.damage_types = tags(get(m, "DamageTypes"))
        local dc = num(get(m, "DamageClass"))
        r.damage_class = dc and (DAMAGE_CLASS[dc] or dc) or nil
        r.force = num(get(m, "Force"))
        r.duration_s = num(get(m, "Duration"))
        r.interval_s = num(get(m, "Interval"))
        r.single_target = bool(get(m, "bDamageSingleTarget"))
        r.strategy = opath(get(m, "DamageStrategy"))
    elseif k == "UtilityMagic" then
        r.utility_spell_class = softpath(get(m, "UtilitySpellClass"))
    elseif k == "SpawnActor" or k == "SpawnActorAsync" then
        r.actor_class = opath(get(m, "ActorClass"))
        r.lifespan_s = num(get(m, "SpawnActorLifespan"))
    elseif k == "LaunchCharacter" then
        r.launch = vec(get(m, "LaunchVector"))
        r.z_override = bool(get(m, "bZOverride"))
    elseif k == "Blueprint" then
        for _, f in ipairs({ "BlueprintGraph", "Graph", "GraphClass", "ModuleGraphClass" }) do
            local v = opath(get(m, f)); if v then r.graph = v; break end
        end
    elseif k == "Shape" then
        local s = get(m, "Shape")
        if valid(s) then r.shape = cls_word(s); r.radius = num(get(s, "Radius")) end
    elseif k:find("PlayMontage", 1, true) then
        for _, f in ipairs({ "Montage", "MontageToPlay", "AnimMontage" }) do
            local v = opath(get(m, f)); if v then r.montage = v; break end
        end
        r.alt_montage_perk = opath(get(m, "SkillPerkRequiredForAlternativeMontage"))
    end
    return r
end

local function spell_record(ctx, s)
    local r = jsonutil.object({ path = opath(s), asset = short(s), class = cls_word(s) })
    r.name = str(get(s, "SpellDisplayName"))
    r.special_requirements = str(get(s, "SpecialRequirementsText"))
    r.cooldown_s = num(get(s, "CooldownDuration"))
    local cm = get(s, "CooldownModifierPerk")
    if isobj(cm) and valid(get(cm, "CooldownPerk")) then
        r.cooldown_perk = opath(get(cm, "CooldownPerk"))
        r.cooldown_with_perk_s = num(get(cm, "ModifiedCooldown"))
    end
    local ct = num(get(s, "CastType"))
    r.cast_type = ct and (CAST_TYPE[ct] or ct) or nil
    r.needs_unlocking = bool(get(s, "bNeedsUnlocking"))
    r.center_on_caster = bool(get(s, "bCenterOnCaster"))
    r.repeats = bool(get(s, "bRepeats"))
    r.allow_while_falling = bool(get(s, "bAllowCastingWhileFalling"))
    r.continuously_cast = bool(get(s, "bContinuouslyCast"))
    r.anim_equipment_requirement = num(get(s, "SpellcastingAnimationEquipmentRequirements"))
    r.special_requirements_strategy = opath(get(s, "SpecialRequirementsStrategy"))
    r.blocking_tags = tags(get(s, "BlockingTags"))
    r.owning_perk = perk_info(ctx, get(s, "OwningPerk"))
    r.upgraded_montage_perk = opath(get(s, "SkillPerkRequiredForUpgradedMontage"))
    local mods, runes = {}, jsonutil.object()
    local container = get(s, "Modules")
    each(container and get(container, "Modules"), function(w)
        local m = get(w, "Module")
        if valid(m) then
            local mi = module_info(ctx, m)
            mods[#mods + 1] = mi
            for _, c in ipairs(mi.costs or {}) do
                if c.rune and c.count then runes[c.rune] = (runes[c.rune] or 0) + c.count end
            end
        end
    end, 64)
    r.modules = mods
    r.runes = runes
    return r
end

-- ------------------------------------------------------------------ explosion actors
local function explosion_info(log, path)
    crumb(log, "explosion", { path = path })
    local cls = try(function() return StaticFindObject(path) end)
    local r = jsonutil.object({ class = path, loaded = valid(cls) })
    if not valid(cls) then return r end
    local tmpl = try(function() return StaticFindObject(path .. ":DelayedDamageInfliction_GEN_VARIABLE") end)
    if not valid(tmpl) then
        local cdo = try(function() return cls:GetCDO() end)
        tmpl = get(cdo, "DelayedDamageInfliction")
    end
    if valid(tmpl) then
        local dc = num(get(tmpl, "DamageClass"))
        r.delayed_damage = jsonutil.object({
            damage = num(get(tmpl, "Damage")), force = num(get(tmpl, "Force")),
            damage_class = dc and (DAMAGE_CLASS[dc] or dc) or nil,
            damage_types = tags(get(tmpl, "DamageTypes")),
            damage_by_owner = bool(get(tmpl, "bDamageByOwner")),
            damage_by_equipment = bool(get(tmpl, "bDamageByEquipment")),
            damage_by_equipment_category = tag(get(tmpl, "DamageByEquipmentCategory")),
            can_crit = bool(get(tmpl, "bCanCrit")),
            predict_s = num(get(tmpl, "PredictDamageDurationSeconds")),
            attack_property_flags = num(get(tmpl, "AttackPropertyFlags")),
            noise_range = num(get(tmpl, "NoiseRange")),
            damage_row = str(get(get(tmpl, "DamageDataTableRowHandle"), "RowName")),
            damage_table = opath(get(get(tmpl, "DamageDataTableRowHandle"), "DataTable")),
        })
        local shape = get(tmpl, "OverlapShape")
        if valid(shape) then
            r.delayed_damage.shape = cls_word(shape)
            r.delayed_damage.radius = num(get(shape, "Radius"))
            r.delayed_damage.scale = num(get(shape, "Scale"))
        end
        local ges = {}
        each(get(tmpl, "OnDamagedGameplayEffects"), function(c) ges[#ges + 1] = opath(c) end, 16)
        r.delayed_damage.on_damaged_effects = ges
    end
    return r
end

-- ------------------------------------------------------------------ players (read-only mirror)
local function players_and_puppets()
    local players, puppets = {}, {}
    for _, p in ipairs(try(function() return FindAllOf("BP_PlayerCharacter_C") end) or {}) do
        if valid(p) then
            local c = try(function() return p:GetController() end)
            table.insert(((fullname(c) or ""):find("PlayerController", 1, true)) and players or puppets, p)
        end
    end
    return players, puppets
end

local function mirror(log, pawn)
    local pc = try(function() return pawn:GetController() end)
    local r = jsonutil.object({ pawn = short(pawn), controller = short(pc) })
    local ps = get(pawn, "PlayerState")
    r.name = valid(ps) and str(try(function() return ps:GetPlayerName() end)) or nil
    if not valid(pc) then r.error = "no controller"; return r end
    crumb(log, "mirror_wheel", { pc = r.controller })
    local sc = get(pc, "SpellcastingComponent")
    if valid(sc) then
        local wheel = {}
        each(get(sc, "SelectedSpells"), function(s) wheel[#wheel + 1] = valid(s) and short(s) or jsonutil.null end, 64)
        r.wheel = wheel
        r.wheel_radials = num(get(sc, "NumSpellRadials"))
        r.wheel_slots_per_radial = num(get(sc, "NumSpellSlotsPerRadial"))
    end
    crumb(log, "mirror_unlocked", {})
    local prog = get(pc, "ProgressComponent")
    if valid(prog) then
        local unlocked = {}
        local n, err = each_set(get(prog, "SpellsUnlocked"), function(s) unlocked[#unlocked + 1] = short(s) or tostring(s) end)
        table.sort(unlocked)
        r.spells_unlocked, r.spells_unlocked_err = unlocked, err
        r.spells_unlocked_n = n
    end
    crumb(log, "mirror_skills", {})
    local sk = get(pc, "SkillComponent")
    if valid(sk) then
        local skills = jsonutil.object()
        each(get(sk, "Skills"), function(s)
            local d = get(s, "SkillData")
            local st = num(get(d, "SkillType"))
            skills[(st and SKILL[st]) or short(d) or "?"] = { xp = num(get(s, "CurrentXP")), data = short(d) }
        end, 32)
        r.skills = skills
    end
    crumb(log, "mirror_perks", {})
    local spc = get(pc, "SkillPerkComponent")
    if valid(spc) then
        local active = {}
        each(get(spc, "SkillPerkRuntimeStates"), function(st)
            each(get(st, "ActivePerkDatas"), function(p) active[#active + 1] = short(p) end, 128)
        end, 32)
        table.sort(active)
        r.active_perks = active
    end
    crumb(log, "mirror_runes", {})
    local inv = get(pc, "InventoryComponent")
    if valid(inv) then
        local runes, items = jsonutil.object(), 0
        each(get(inv, "ItemSlots"), function(it)
            if valid(it) then
                items = items + 1
                local rn = (short(get(it, "ItemData")) or ""):match("^ITEM_Rune_(%w+)$")
                if rn then runes[rn] = (runes[rn] or 0) + (num(get(it, "Count")) or 0) end
            end
        end, 256)
        r.runes, r.inventory_items = runes, items
    end
    crumb(log, "mirror_cooldowns", {})
    local um = get(pawn, "PlayerUtilityMagicComponent")
    if valid(um) then
        local last = jsonutil.object()
        local _, err = each_map(get(um, "LastCastTimeBySpellData"), function(k, v)
            last[short(k) or tostring(k)] = num(v)
        end)
        r.last_cast_time, r.last_cast_time_err = last, err
        local sb = get(um, "SpellBeingPreparedOrCast")
        r.preparing = isobj(sb) and short(get(sb, "SpellBeingPreparedOrCastData")) or nil
    end
    return r
end

local function puppet_effects(p)
    local r = jsonutil.object({ pawn = short(p) })
    local gec = get(p, "GameplayEffectsComponent")
    if not valid(gec) then r.error = "no GameplayEffectsComponent"; return r end
    local inst = {}
    each(get(gec, "ReplicatedInstances"), function(g) inst[#inst + 1] = cls_word(g) end, 128)
    r.replicated_instances = inst
    local inst2 = {}
    each(get(gec, "NonReplicatedInstances"), function(g) inst2[#inst2 + 1] = cls_word(g) end, 128)
    r.non_replicated_instances = inst2
    r.tags = tags(get(gec, "GameplayTags"))
    return r
end

-- ------------------------------------------------------------------ usage metadata
local function load_meta(log)
    local root = os.getenv("DW_MOD_ROOT")
    if not root then return nil, "DW_MOD_ROOT unset" end
    local ok, mod = pcall(function() return assert(loadfile(root .. "/body/spells.lua"))() end)
    if not ok or type(mod) ~= "table" then return nil, tostring(mod) end
    return mod
end

local function default_out()
    local dir = os.getenv("DW_MOD_LOG_DIR") or "."
    return dir .. "/../../data/spells_" .. BUILD .. ".json"
end

function M.run(log, args)
    args = args or {}
    local ctx = { effects = jsonutil.object(), held_effects = jsonutil.object(), perks = jsonutil.object() }
    local doc = jsonutil.object({ build = BUILD, generated_at = os.time(), source = "mod/scripts/spell_dump.lua (X1, read-only)" })
    crumb(log, "start", {})

    local spells = jsonutil.object()
    local n = 0
    for _, s in ipairs(try(function() return FindAllOf("UtilitySpellData") end) or {}) do
        local p = opath(s)
        if valid(s) and p and not p:find("Default__", 1, true) then
            crumb(log, "spell", { path = p })
            local rec = spell_record(ctx, s)
            spells[rec.asset] = rec
            n = n + 1
        end
    end
    doc.spells, doc.spell_count = spells, n

    -- perk -> spell (SkillPerkModule_Spell.SpellData; DOM:33724)
    crumb(log, "perk_modules", {})
    local perk_spell = jsonutil.object()
    for _, pm in ipairs(try(function() return FindAllOf("SkillPerkModule_Spell") end) or {}) do
        local p = opath(pm)
        if valid(pm) and p and not p:find("Default__", 1, true) then
            local perk = p:match("^(.-):") or p
            perk_spell[perk:match("([%w_]+)$") or perk] = short(get(pm, "SpellData"))
        end
    end
    doc.perk_to_spell = perk_spell

    -- combat spell data (jump attacks etc.): names and costs only
    crumb(log, "combat_spells", {})
    local combat = jsonutil.object()
    for _, s in ipairs(try(function() return FindAllOf("DominionSpellData") end) or {}) do
        local p = opath(s)
        if valid(s) and p and not p:find("Default__", 1, true) and cls_word(s) == "DominionSpellData" then
            local mods = {}
            local container = get(s, "Modules")
            each(container and get(container, "Modules"), function(w)
                local m = get(w, "Module")
                if valid(m) then mods[#mods + 1] = cls_word(m) end
            end, 32)
            combat[short(s)] = { path = p, modules = mods }
        end
    end
    doc.combat_spell_data = combat

    doc.explosions = jsonutil.object()
    for k, path in pairs(EXPLOSIONS) do doc.explosions[k] = explosion_info(log, path) end
    doc.effects, doc.held_effects, doc.perks = ctx.effects, ctx.held_effects, ctx.perks

    local players, puppets = players_and_puppets()
    doc.players = {}
    for _, pawn in ipairs(players) do doc.players[#doc.players + 1] = mirror(log, pawn) end
    doc.puppets = {}
    for _, p in ipairs(puppets) do doc.puppets[#doc.puppets + 1] = puppet_effects(p) end

    -- usage metadata from body/spells.lua
    local meta, merr = load_meta(log)
    if meta and meta.merge_catalog then
        local ok, e = pcall(meta.merge_catalog, doc)
        doc.meta_merge = ok and "ok" or tostring(e)
    else
        doc.meta_merge = "skipped: " .. tostring(merr)
    end

    local out = args.out or default_out()
    crumb(log, "write", { out = out })
    local f, ferr = io.open(out, "wb")
    if not f then return { ok = false, error = "open " .. tostring(ferr), out = out } end
    f:write(jsonutil.encode(doc))
    f:close()

    local summary = {}
    for asset, rec in pairs(spells) do
        local rs = {}
        for r, c in pairs(rec.runes) do rs[#rs + 1] = c .. " " .. r end
        table.sort(rs)
        summary[#summary + 1] = string.format("%s (%s) cd=%s runes=%s", asset, tostring(rec.name), tostring(rec.cooldown_s), table.concat(rs, "+"))
    end
    table.sort(summary)
    return { ok = true, out = out, spells = n, players = #doc.players, puppets = #doc.puppets,
             meta_merge = doc.meta_merge, summary = summary,
             wheel = doc.players[1] and doc.players[1].wheel or nil,
             unlocked_n = doc.players[1] and doc.players[1].spells_unlocked_n or nil,
             unlocked_err = doc.players[1] and doc.players[1].spells_unlocked_err or nil,
             explosions = doc.explosions }
end

return M
