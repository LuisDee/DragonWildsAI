-- Spells service for the companion body (docs/design/robustness-and-item-catalog.md sections 3-6,
-- research docs/research/2026-10-25-spells-and-weaknesses.md). Small API:
--   M.configure(opts)                 policy, inventory store, mirror, clock, catalog path, flags
--   M.list()                          every catalogued spell with role/cost/cooldown/readiness
--   M.can_cast(name)                  -> ok, reason, data   (resolution, route, cooldown, cost policy)
--   M.cast(puppet, name, target, o)   -> {ok, reason, data} (runs the route; starts cooldown; pays)
--   M.is_target_stunned(ai)           -> bool, detail      (IsStumbling() or a hooked knockdown)
--   M.note_knockdown(ai, on)          hook sink for BP_DominionAICharacter_C:OnAIKnockdownState_*
--   M.pick_cluster(points, r, n)      pure helper for "Windstep into 3+ enemies"
--   M.register(bridge, log, opts)     bridge handlers `cast`, `spells`, `spell_tactics` (main.lua must call it)
--   M.install_combat_hooks(combat)    on_tick hook into body/combat.lua: utility-scored reflex casts
--   M.rank(situation) / M.add_scorer  utility scoring (design section 9)
--   M.merge_catalog(doc)              adds usage metadata to the X1 dump (data/spells_<build>.json)
--
-- Casting routes, in the research's safety order (section 1.3):
--   wind_stomp   Windstep's stun: SpawnActor(BP_WindstepExplosion_C) at the target, SetOwner(puppet),
--                optional DelayedDamageInfliction:StartDelayedDamage(0.0). Plain object/scalar args.
--   self_effect  the spell's own gameplay effect on the puppet: GameplayEffectsComponent:
--                InstantiateGameplayEffect(class, nil, false). Plain args (returns a struct).
--   held_effect  weapon enchants / Spectral Arrows: property write of the held actor's
--                PhysicalHeldEquipmentEffectInfo + OnRep (research row E, X7). A struct PROPERTY
--                write, never a struct UFunction argument.
--   modular      TriggerModularAbilityForPlayer(puppet, spellData): OPT-IN ONLY (configure
--                {allow_modular=true} or DW_SPELLS_MODULAR=1): its CostItems module may dereference
--                the puppet's null PlayerController inventory (DISCOVERIES "ROOT CAUSES").
--   none         catalogued only (e.g. Magical Mending until its repair path is verified).
-- A route is used live only once verified in game unless allow_unverified (DW_SPELLS_UNVERIFIED=1).
-- The verified status comes from the loaded catalog's `routes[r].verified` (data/spells_<build>.json,
-- the record of what was seen in game) and falls back to M.ROUTES[r].verified (M.route_verified).
-- pcall cannot catch native crashes, so every native call goes through U.call (breadcrumb first).
--
-- Integration (main.lua): spells.register(bridge, log, {find_ai=skills.find_ai, catalog_path=...,
-- cost_policy=..., inventory=<store>}) then spells.install_combat_hooks(require("body.combat")).
-- Luis's unlocks come from M.live_mirror(): his PlayerController's ProgressComponent.SpellsUnlocked
-- (TSet) and SkillPerkComponent active perks, read-only (the X1 dump read them), cached
-- MIRROR_TTL_S, with the catalog's `players[1]` snapshot as the fallback.
--
-- Cost policies (configure {cost_policy=...}, env DW_SPELL_COST_POLICY):
--   "free"    ignore runes
--   "budget"  runes come from the bot's inventory store (planned mod/body/inventory.lua):
--             store.count(item_id) -> number and store.take(item_id, n) -> bool, item_id like
--             "ITEM_Rune_Air". Paid only after a successful cast.
--   "mirror"  only spells Luis has unlocked (mirror.unlocked[asset]); perk-gated variants (Wind
--             Stomp) also need the perk in mirror.perks when perks are known. Runes are not charged.
--   "mirror_budget"  both: Luis's unlocks AND the bot's runes (the design's proposed default,
--             docs/design/robustness-and-item-catalog.md section 9; awaiting Luis's choice).
local U = require("body.util")

local M = {}

M.BUILD = "26161880"
M.MIN_GAP_S = 1.0               -- global spacing between two casts (any spell)
M.SAFE_PLAYER_CM = 1000         -- never put an AoE within 10 m of a real player
M.STOMP_RADIUS_CM = 700         -- BP_WindstepExplosion_C sphere radius (X1 dump); catalog wins
M.STOMP_LIFESPAN_S = 5.0        -- the explosion actor is cleaned up after this
M.STUN_PRESUME_S = 1.5          -- after our stomp, targets in radius count as "stunned" this long
M.MIRROR_TTL_S = 60             -- re-read Luis's unlocks at most this often
M.POLICIES = { free = true, budget = true, mirror = true, mirror_budget = true }
M.ROLES = { "combat_defence", "combat_cc", "combat_damage", "weapon_buff", "gathering_buff",
            "gathering_aoe", "scouting", "repair", "travel", "other" }

M.PATHS = {
    explosion_windstep = "/Game/Gameplay/UtilityMagic/PerkSpells/Windstep/BP_WindstepExplosion.BP_WindstepExplosion_C",
    runtime_lib = "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary",
    rune_fmt = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_%s.ITEM_Rune_%s",
    spell_fmt = "/Game/Gameplay/UtilityMagic/PerkSpells/%s/%s.%s",
}

-- verified: true only after an in-game test recorded in DISCOVERIES "Spells (build 26161880)".
M.ROUTES = {
    wind_stomp = { verified = false, note = "X3 2026-10-25: native path crash-safe (5 live spawns, 2 forced); no stagger seen on a Kebbit (can't stumble, knockdown 1000); needs a Kalphite test with Luis watching" },
    self_effect = { verified = false, note = "X4" },
    held_effect = { verified = false, note = "X7" },
    modular = { verified = false, note = "X5; opt-in only (null-PC rune-cost path)" },
    none = { verified = false, note = "catalogued only" },
}

-- ------------------------------------------------------------------ usage metadata
-- Keyed by data-asset name. Wiki facts (skill/level/runes/cooldown) are fallbacks; the X1 dump's
-- game values (catalog) win. role/preconditions/use_when are what the planner and the combat BT read.
-- PileEmUp = "Trunk Totem" and Harvest = "Uproot" etc. are inferred from asset names + wiki text;
-- the dump's SpellDisplayName is authoritative.
local function W(skill, level) return { skill = skill, level = level } end
M.META = {
    USD_TempestShield = { name = "Tempest Shield", role = "combat_defence", route = "self_effect",
        effect = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/GE_TempestShield.GE_TempestShield_C",
        upgraded_effect = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/GE_TempestShield_Upgraded.GE_TempestShield_Upgraded_C",
        runes = { Air = 15 }, cooldown_s = 45, wiki = W("Attack", 11), aliases = { "shield", "tempest" },
        preconditions = { "in combat or a fight is about to start", "incoming big telegraph, or own HP below ~50%" },
        use_when = "Block all damage for about a minute; cast before a big hit lands or when HP is low. Save it for bosses if Luis asks." },
    USD_Windstep = { name = "Windstep", role = "combat_cc", route = "wind_stomp",
        requires_perk = "PerkV2_Agility_Spell_Windstep_Upgrade",
        runes = { Air = 5 }, cooldown_s = 3, wiki = W("Agility", 8), aliases = { "wind stomp", "windstomp", "wind jump", "stun", "stomp" },
        preconditions = { "enemy cluster >= 3 within 7 m of the landing point (Kalphites especially)", "no player within 10.5 m of the landing point" },
        use_when = "Wind Stomp: a 7 m AoE stagger (force 1000, no damage) at the landing point; use on groups (great vs Kalphites), then hit them while they stumble." },
    USD_EnchantWeapon_Fire = { name = "Enchant Weapon: Fire", role = "weapon_buff", route = "held_effect",
        held_effect = "HEED_EnchantWeaponFire", runes = { Fire = 15, Astral = 5 }, cooldown_s = 90, wiki = W("Attack", 20),
        aliases = { "fire enchant", "enchant fire" },
        preconditions = { "melee weapon in hand", "target weak to Fire or not Fire-resistant (goblins)" },
        use_when = "Adds Fire to melee hits (burn on crit); use against Fire-weak enemies such as goblins." },
    USD_EnchantWeapon_Air = { name = "Enchant Weapon: Air", role = "weapon_buff", route = "held_effect",
        held_effect = "HEED_EnchantWeaponAir", runes = { Air = 15, Astral = 5 }, wiki = W("Attack", 30),
        aliases = { "air enchant", "enchant air" },
        preconditions = { "melee weapon in hand", "a longer fight ahead" },
        use_when = "Faster melee attacks for a while; use at the start of a long fight. Kalphites resist Air damage." },
    USD_EnchantWeapon_Water = { name = "Enchant Weapon: Water", role = "weapon_buff", route = "held_effect",
        held_effect = "HEED_EnchantWeaponWater", runes = { Water = 15, Astral = 5 }, wiki = W("Attack", 50),
        aliases = { "water enchant", "enchant water" },
        preconditions = { "melee weapon in hand", "target not Water-resistant" },
        use_when = "Adds Water damage and occasional healing orbs; good for sustained melee when not fighting Kalphites." },
    USD_EnchantWeapon_Earth = { name = "Enchant Weapon: Earth", role = "weapon_buff", route = "held_effect",
        held_effect = "HEED_EnchantWeaponEarth", aliases = { "earth enchant", "enchant earth" },
        preconditions = { "melee weapon in hand", "target not Earth-resistant (Kalphites do not resist Earth)" },
        use_when = "Adds Earth damage to melee hits; a good enchant against Kalphites." },
    USD_CorruptionArrows = { name = "Spectral Arrows", role = "weapon_buff", route = "held_effect",
        held_effect = "HEED_CorruptionArrows", runes = { Air = 5, Astral = 15 }, cooldown_s = 90, wiki = W("Ranged", 25),
        aliases = { "spectral arrows", "spectral" },
        preconditions = { "two-handed bow equipped (not a crossbow)", "enemies resistant to Ranged" },
        use_when = "Arrows pierce several targets and bypass Ranged resistance for 5 minutes; use with a bow vs Ranged-resistant enemies." },
    USD_Confuse = { name = "Confuse", role = "combat_cc", runes = { Astral = 25 }, wiki = W("Magic", 30),
        preconditions = { "several lesser enemies attacking" },
        use_when = "Lesser enemies can't tell friend from foe for a while; use when outnumbered by weak enemies." },
    USD_Enfeeble = { name = "Enfeeble", role = "combat_cc", runes = { Water = 20, Astral = 20 }, wiki = W("Magic", 61),
        preconditions = { "a strong single enemy (boss) targeting us or Luis" },
        use_when = "Weakens the target's attacks; use on a boss or the hardest-hitting enemy." },
    USD_SnareTrap = { name = "Snare", role = "combat_cc", runes = { Astral = 15, Nature = 10 }, wiki = W("Ranged", 12),
        aliases = { "snare" },
        preconditions = { "enemies approaching along a predictable path", "placed spell (needs a location)" },
        use_when = "A trap that roots enemies that walk into it; place it between enemies and Luis." },
    USD_Vengeance = { name = "Vengeance", role = "combat_defence", runes = { Earth = 10, Astral = 20 }, wiki = W("Magic", 80),
        preconditions = { "in melee with enemies that hit hard" },
        use_when = "Reflects enemy damage back at them; use when tanking a hard hitter." },
    USD_Surge = { name = "Surge", role = "combat_defence", runes = { Astral = 10, Law = 10 }, wiki = W("Magic", 11),
        preconditions = { "a fight with many telegraphed attacks to dodge" },
        use_when = "Dodges travel further and evade for longer; use before a fight full of big attacks." },
    USD_PhaseDash = { name = "Phase Dash", role = "travel", runes = { Air = 20, Astral = 10 }, wiki = W("Agility", 44),
        preconditions = { "airborne (player movement only)" }, use_when = "A second dash in mid-air; player movement, rarely useful for the bot." },
    USD_Recall = { name = "Recall", role = "travel", runes = { Air = 30, Law = 15 }, wiki = W("Agility", 57),
        preconditions = { "a place worth returning to soon" }, use_when = "Places a beacon to return to within a time limit." },
    USD_HomeTeleport = { name = "Home Teleport", role = "travel", runes = { Law = 15 }, wiki = W("Runecrafting", 27),
        preconditions = { "a bed is set" }, use_when = "Teleports to the caster's bed; the bot uses go_to/teleport instead." },
    USD_AxtralProjection = { name = "Axtral Projection", role = "gathering_aoe", runes = { Air = 10, Astral = 5 }, wiki = W("Woodcutting", 11),
        aliases = { "astral projection", "axtral" },
        preconditions = { "holding an axe", "several standing trees in a line in front of the caster" },
        use_when = "Aimed: throws a conjured axe that flies up to 20 m and fells the trees in its path (damage from the held axe); use when several trees stand in a line. Cooldown 45 s." },
    USD_Splinter = { name = "Splinter", role = "gathering_aoe", runes = { Earth = 10, Nature = 5 }, wiki = W("Woodcutting", 27),
        preconditions = { "holding an axe", "felled tree trunks on the ground nearby" },
        use_when = "Placed: chops felled trunks within 2.3 m of the target point into logs at once (damage from the held axe); cast on a Trunk Totem or a felled trunk. Cooldown 45 s." },
    USD_PileEmUp = { name = "Trunk Totem", role = "gathering_aoe", runes = { Nature = 30, Law = 10 }, wiki = W("Woodcutting", 50),
        aliases = { "trunk totem", "totem" },
        preconditions = { "several felled trunks scattered nearby" },
        use_when = "Placed: gathers scattered felled trunks into one totem; then Splinter the totem for all the logs. Cooldown 180 s, so use it once per clearing." },
    USD_Rocksplosion = { name = "Rocksplosion", role = "gathering_aoe", runes = { Earth = 15, Fire = 5 }, wiki = W("Mining", 11),
        preconditions = { "holding a pickaxe", "boulders or ore rocks nearby" }, use_when = "Breaks apart nearby boulders and ore; use while mining." },
    USD_Harvest = { name = "Uproot", role = "gathering_aoe", runes = { Earth = 10, Astral = 10 }, wiki = W("Farming", 15),
        aliases = { "uproot" },
        preconditions = { "ripe crops or wild plants within a few metres" }, use_when = "Instantly harvests ripe and wild plants in a small radius." },
    USD_FishCyclone = { name = "Fishnado", role = "gathering_aoe", runes = { Air = 15, Nature = 5 }, wiki = W("Fishing", 55),
        aliases = { "fishnado" },
        preconditions = { "standing at a fishing spot" }, use_when = "A tornado pulls up to 5 fish out of the water." },
    USD_FishingFrenzy = { name = "Fishing Frenzy", role = "gathering_buff", runes = { Water = 15, Astral = 5 }, wiki = W("Fishing", 10),
        preconditions = { "about to fish" }, use_when = "Each catch yields an extra fish for a time." },
    USD_InfernalRod = { name = "Infernal Rod", role = "gathering_buff", runes = { Fire = 50 }, wiki = W("Fishing", 30),
        preconditions = { "holding a fishing rod" }, use_when = "Fish caught are cooked for 2 minutes." },
    USD_DivineRock = { name = "Divine Rock", role = "gathering_buff", runes = { Earth = 100, Nature = 100 }, wiki = W("Mining", 80),
        preconditions = { "5 ore dropped on the ground" }, use_when = "Turns 5 dropped ore into a personal mining vein." },
    USD_DetectOre = { name = "Summon Stone Spirits", role = "scouting", runes = { Earth = 5, Astral = 5 }, wiki = W("Mining", 24),
        aliases = { "stone spirits", "detect ore" },
        preconditions = { "looking for rocks to mine" }, use_when = "Guides to the nearest minable rocks." },
    USD_DetectOreAlt = { name = "Summon Stone Spirits (alt)", role = "scouting",
        preconditions = { "looking for rocks to mine" }, use_when = "Alternative radar for minable rocks." },
    USD_DetectAnimaVents = { name = "Summon Elemental Spirits", role = "scouting", runes = { Earth = 5, Astral = 5 }, wiki = W("Runecrafting", 19),
        aliases = { "elemental spirits" },
        preconditions = { "looking for anima vents" }, use_when = "Guides to nearby Anima Vents." },
    USD_EyeOfOculus = { name = "Eye of Oculus", role = "scouting", runes = { Astral = 3 }, wiki = W("Construction", 11),
        preconditions = { "building" }, use_when = "A building camera view; player-only." },
    USD_MagicalMending = { name = "Magical Mending", role = "repair", route = "none", runes = { Earth = 20, Nature = 10 }, wiki = W("Artisan", 56),
        aliases = { "mending", "repair" },
        mechanism = "SpellModule_UtilityMagic spawns an AUtilitySpell actor; URepairSpellComponent:RepairEquipmentOfNearbyPlayers() (no args) with SpellConfig{SpellRange, DurabilityTierPercentageMap, UsedItemsCollection}, bIncludeInventory/bIncludeLoadout/bIgnoreItemRequirements. Wiki: repairs dropped items instantly. Items carry UItem.Durability.",
        preconditions = { "damaged item(s) dropped on the ground near the caster" },
        use_when = "Repairs damaged gear that Luis drops on the floor next to the bot." },
    USD_SpeedupStation = { name = "Overdrive", role = "other", runes = { Air = 15, Water = 5 }, wiki = W("Artisan", 48),
        preconditions = { "next to a working mechanical station" }, use_when = "Speeds up a mechanical processing station." },
    USD_FerociousFurnace = { name = "Superheat", role = "other", runes = { Air = 5, Fire = 15 }, wiki = W("Artisan", 20),
        preconditions = { "next to a working fire-based station" }, use_when = "Speeds up fire-based stations for a time." },
    USD_SummonShelter = { name = "Summon Shelter", role = "other", runes = { Earth = 10, Astral = 10 }, wiki = W("Construction", 20),
        preconditions = { "night or a storm, far from base" }, use_when = "Builds a temporary shelter with a bed." },
    USD_AccessPersonalChest = { name = "Personal Chest", role = "other", runes = { Astral = 15, Law = 20 }, wiki = W("Construction", 40),
        preconditions = { "inventory full" }, use_when = "Opens personal storage from anywhere (player UI)." },
    USD_FireSpirit = { name = "Fire Spirit", role = "other", runes = { Fire = 10 }, wiki = W("Runecrafting", 42),
        preconditions = { "dark area" }, use_when = "Summons a fire spirit that gives light." },
    USD_InternalAlchemy = { name = "Internal Alchemy", role = "other", runes = { Nature = 10 }, wiki = W("Cooking", 20),
        preconditions = { "food or drink buffs about to expire" }, use_when = "Refreshes active food and drink buffs." },
    USD_BonesToPeaches = { name = "Bones to Peaches", role = "other", runes = { Earth = 5, Nature = 10 }, wiki = W("Cooking", 28),
        preconditions = { "bones on the ground" }, use_when = "Turns dropped bones into peaches (food)." },
    USD_Humidify = { name = "Humidify", role = "other", runes = { Water = 15, Astral = 10 }, wiki = W("Farming", 28),
        preconditions = { "dry farm plots" }, use_when = "A rain cloud waters the plots it passes." },
    USD_RapidGrowth = { name = "Rapid Growth", role = "other", runes = { Earth = 30, Nature = 30 }, wiki = W("Farming", 74),
        preconditions = { "planted crops" }, use_when = "Advances plant growth by one stage." },
    USD_Farming_RapidGrowth = { name = "Rapid Growth (farming)", role = "other",
        preconditions = { "planted crops" }, use_when = "Advances plant growth." },
    USD_Farming_Compost = { name = "Mucksplosion", role = "other", runes = { Earth = 20, Astral = 15 }, wiki = W("Farming", 80),
        preconditions = { "farm plots needing fertiliser" }, use_when = "Showers plots with fertiliser." },
    USD_Treequipment = { name = "Bark to Bones", role = "other", runes = { Earth = 10, Nature = 10 }, wiki = W("Artisan", 11),
        preconditions = { "cast on a tree (placed spell)", "bones are wanted more than logs" },
        use_when = "Turns a tree into a stack of bones; only when bones are needed (not for log gathering)." },
    USD_ShadowVeil = { name = "Shadow Veil", role = "other", runes = { Astral = 20 },
        preconditions = { "sneaking past enemies (not in the wiki spell list; may be unreleased)" },
        use_when = "Self gameplay effect GE_ShadowVeil_C (stealth, inferred from the name); not for normal play." },
    USD_CabbageRain = { name = "Cabbage Rain", role = "other",
        preconditions = { "no rune cost and no owning perk in this build (likely event/unreleased)" },
        use_when = "Not a normal player spell in this build; do not use." },
    USD_EnchantChefsTools = { name = "Enchant Chef's Tools", role = "other",
        preconditions = { "cast on a Cooking Range" }, use_when = "Cooking-station buff; no rune cost or owning perk in this build." },
    USD_MagicFocus = { name = "Magic Focus", role = "other", preconditions = { "internal (held-equipment montage only)" },
        use_when = "Internal spell data, not on the spell wheel; do not use." },
    USD_WeaponBarbs = { name = "Weapon Barbs", role = "other", preconditions = { "internal (held-equipment montage only)" },
        use_when = "Internal spell data (no cost, no modules beyond a montage); do not use." },
    USD_WeaponPoison = { name = "Weapon Poison", role = "other", preconditions = { "internal (held-equipment montage only)" },
        use_when = "Internal spell data (no cost, no modules beyond a montage); do not use." },
    USD_Whetstone = { name = "Whetstone", role = "other", preconditions = { "internal (held-equipment montage only)" },
        use_when = "Internal spell data (no cost, no modules beyond a montage); do not use." },
    USD_GetWaterFromWaterSource = { name = "Get Water", role = "other", preconditions = { "world interaction, not a wheel spell" },
        use_when = "World interaction (filling water from a source); not cast directly." },
    USD_SiphonAnimaCharge = { name = "Siphon Anima Charge", role = "other", preconditions = { "world interaction at an anima source" },
        use_when = "World interaction; not cast directly." },
    USD_SiphonRunes = { name = "Siphon Runes", role = "other", preconditions = { "world interaction at a rune source" },
        use_when = "World interaction; not cast directly." },
    USD_RunesToRuneEssence = { name = "Runes To Rune Essence", role = "other", runes = { Water = 5, Astral = 5 }, wiki = W("Runecrafting", 61),
        preconditions = { "unwanted runes dropped on the ground" }, use_when = "Converts dropped runes back into 40% of their essence." },
}

-- ------------------------------------------------------------------ state
local S = {
    policy = "free", inventory = nil, mirror = nil, catalog = nil,
    allow_modular = false, allow_unverified = false,
    clock = os.time, last_cast = {}, last_any = nil,
    knockdown = {}, stomps = {}, log = nil, bridge = nil, puppet = nil,
}

local function log(name, data) if S.log then pcall(S.log.event, name, data) end end
local function result(ok, reason, data) return { ok = ok, reason = reason, data = data or {} } end

function M.configure(opts)
    opts = opts or {}
    if opts.cost_policy ~= nil then
        if not M.POLICIES[opts.cost_policy] then error("unknown cost_policy " .. tostring(opts.cost_policy)) end
        S.policy = opts.cost_policy
    end
    if opts.inventory ~= nil then S.inventory = opts.inventory end
    if opts.mirror ~= nil then S.mirror = opts.mirror end
    if opts.catalog ~= nil then S.catalog = opts.catalog end
    if opts.allow_modular ~= nil then S.allow_modular = opts.allow_modular == true end
    if opts.allow_unverified ~= nil then S.allow_unverified = opts.allow_unverified == true end
    if opts.clock ~= nil then S.clock = opts.clock end
    if opts.log ~= nil then S.log = opts.log end
    return M.config()
end

function M.config()
    return { cost_policy = S.policy, allow_modular = S.allow_modular, allow_unverified = S.allow_unverified,
             has_inventory = S.inventory ~= nil, has_mirror = S.mirror ~= nil, has_catalog = S.catalog ~= nil }
end

function M._reset()
    S.policy, S.inventory, S.mirror, S.catalog = "free", nil, nil, nil
    S.allow_modular, S.allow_unverified = false, false
    S.clock, S.last_cast, S.last_any = os.time, {}, nil
    S.knockdown, S.stomps, S.log, S.bridge, S.puppet = {}, {}, nil, nil, nil
    S.tactics = {}
    for k, v in pairs(M.TACTICS_DEFAULT) do S.tactics[k] = v end
end

-- Catalog: the decoded data/spells_<build>.json (X1). Game values override wiki fallbacks.
function M.load_catalog(path, decode)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open " .. tostring(path) end
    local text = f:read("*a")
    f:close()
    decode = decode or require("jsonutil").decode
    local doc, err = decode(text)
    if type(doc) ~= "table" then return nil, err or "bad json" end
    S.catalog = doc
    return doc
end

-- ------------------------------------------------------------------ resolution
local function norm(s) return (tostring(s or ""):lower():gsub("[^%w]", ""):gsub("^usd", "")) end

local function game_rec(asset)
    local c = S.catalog
    return c and type(c.spells) == "table" and c.spells[asset] or nil
end

local function all_assets()
    local seen, out = {}, {}
    for a in pairs(M.META) do seen[a] = true; out[#out + 1] = a end
    if S.catalog and type(S.catalog.spells) == "table" then
        for a in pairs(S.catalog.spells) do if not seen[a] then seen[a] = true; out[#out + 1] = a end end
    end
    table.sort(out)
    return out
end

-- name: asset ("USD_TempestShield"), its suffix ("TempestShield"), display name or alias; any case.
function M.resolve(name)
    if type(name) ~= "string" or name == "" then return nil end
    local want = norm(name)
    for _, a in ipairs(all_assets()) do
        local meta, g = M.META[a] or {}, game_rec(a) or {}
        if norm(a) == want or norm(meta.name) == want or norm(g.name) == want then return a end
        for _, al in ipairs(meta.aliases or {}) do if norm(al) == want then return a end end
    end
    return nil
end

-- Rune cost: game data first (summed CostItems), else the wiki fallback.
function M.runes(asset)
    local g = game_rec(asset)
    if g and type(g.runes) == "table" and next(g.runes) then return g.runes, "game" end
    local meta = M.META[asset]
    if meta and meta.runes then return meta.runes, "wiki" end
    return {}, "unknown"
end

function M.cooldown_s(asset)
    local g = game_rec(asset)
    if g and type(g.cooldown_s) == "number" and g.cooldown_s > 0 then return g.cooldown_s, "game" end
    local meta = M.META[asset]
    if meta and meta.cooldown_s then return meta.cooldown_s, "wiki" end
    return 0, "unknown"
end

-- Self-targeted gameplay effect in the game data (module GameplayEffect with target SpellOwner).
local function game_self_effect(asset)
    local g = game_rec(asset)
    for _, m in ipairs(g and g.modules or {}) do
        if m.kind == "SpellModule_GameplayEffect" and m.target == "SpellOwner" and m.effect then return m.effect, m.upgraded_effect end
    end
end

local function game_held_effect(asset)
    local g = game_rec(asset)
    for _, m in ipairs(g and g.modules or {}) do
        if m.kind == "SpellModule_HeldEquipmentEffect" and m.held_effect then return m.held_effect end
    end
end

-- Route for a spell: explicit META route; else derived from game data; modular when opted in.
function M.route(asset)
    local meta = M.META[asset] or {}
    local r = meta.route
    if not r then
        if game_self_effect(asset) then r = "self_effect"
        elseif game_held_effect(asset) then r = "held_effect" end
    end
    if (not r or r == "none") and S.allow_modular then r = "modular" end
    return r or "none"
end

-- Verified-in-game status of a route: the catalog's routes[r].verified (a boolean) wins, because the
-- catalog is the record of what was seen in game; else the code default M.ROUTES[r].verified.
-- -> verified(bool), note
function M.route_verified(route)
    local c = S.catalog
    local cr = c and type(c.routes) == "table" and c.routes[route]
    local r = M.ROUTES[route]
    if not r and not cr then return false, "unknown route" end
    if type(cr) == "table" and type(cr.verified) == "boolean" then
        return cr.verified, cr.note or (r and r.note)
    end
    return (r and r.verified) == true, r and r.note
end

-- ------------------------------------------------------------------ cost policies
local function rune_item(rune) return "ITEM_Rune_" .. rune end

local function inv_count(store, rune)
    local n = U.try(store.count, rune_item(rune))
    return tonumber(n) or 0
end

local function mirror_state()
    local m = S.mirror
    if type(m) == "function" then m = U.try(m) end
    return type(m) == "table" and m or nil
end

local function check_mirror(asset)
        local m = mirror_state()
        if not m or type(m.unlocked) ~= "table" then return false, "state_unavailable", { detail = "no mirror of Luis's unlocks" } end
        if not m.unlocked[asset] then return false, "not_unlocked", { spell = asset } end
        local perk = (M.META[asset] or {}).requires_perk
        if perk and type(m.perks) == "table" and not m.perks[perk] then
            return false, "not_unlocked", { spell = asset, perk = perk }
        end
        return true
end

local function check_budget(asset)
    local store = S.inventory
    if not store or type(store.count) ~= "function" or type(store.take) ~= "function" then
        return false, "state_unavailable", { detail = "no bot inventory store (mod/body/inventory.lua)" }
    end
    local need, src = M.runes(asset)
    local missing = {}
    for rune, n in pairs(need) do
        local have = inv_count(store, rune)
        if have < n then missing[rune] = n - have end
    end
    if next(missing) then return false, "not_enough_resources", { spell = asset, missing = missing, cost = need, cost_source = src } end
    return true
end

local function check_policy(asset)
    local pol = S.policy
    if pol == "free" then return true end
    if pol == "mirror" or pol == "mirror_budget" then
        local ok, reason, data = check_mirror(asset)
        if not ok then return ok, reason, data end
        if pol == "mirror" then return true end
    end
    return check_budget(asset)
end

local function pay(asset)
    if S.policy ~= "budget" and S.policy ~= "mirror_budget" then return {} end
    local need = M.runes(asset)
    local paid = {}
    for rune, n in pairs(need) do
        if U.try(S.inventory.take, rune_item(rune), n) then paid[rune] = n
        else log("spell_pay_failed", { spell = asset, rune = rune, n = n }) end
    end
    return paid
end

-- ------------------------------------------------------------------ can_cast
function M.remaining_s(asset)
    local last = S.last_cast[asset]
    if not last then return 0 end
    local left = M.cooldown_s(asset) - (S.clock() - last)
    return left > 0 and left or 0
end

-- -> ok, reason, data. Reasons: unknown_skill, not_implemented, on_cooldown, not_enough_resources,
-- not_unlocked, state_unavailable.
function M.can_cast(name)
    local asset = M.resolve(name)
    if not asset then return false, "unknown_skill", { spell = name } end
    local route = M.route(asset)
    local data = { spell = asset, route = route }
    if route == "none" then return false, "not_implemented", data end
    if route == "modular" and not S.allow_modular then return false, "not_implemented", data end
    local verified, note = M.route_verified(route)
    if not (verified or S.allow_unverified) then
        data.detail = "route not verified in game (" .. tostring(note) .. ")"
        return false, "not_implemented", data
    end
    local left = M.remaining_s(asset)
    if left > 0 then data.remaining_s = left; return false, "on_cooldown", data end
    if S.last_any and S.clock() - S.last_any < M.MIN_GAP_S then
        data.remaining_s = M.MIN_GAP_S - (S.clock() - S.last_any)
        return false, "on_cooldown", data
    end
    local ok, reason, pdata = check_policy(asset)
    if not ok then
        for k, v in pairs(pdata or {}) do data[k] = v end
        return false, reason, data
    end
    return true, nil, data
end

-- opts.compact: only spells the bot could cast (castable now, or blocked only by a cooldown or
-- missing runes), with the short fields the brain's Controller context needs.
M.TRANSIENT_REASONS = { on_cooldown = true, not_enough_resources = true }
function M.list(opts)
    local compact = type(opts) == "table" and opts.compact == true
    local out = {}
    for _, a in ipairs(all_assets()) do
        local meta, g = M.META[a] or {}, game_rec(a) or {}
        local ok, reason, cdata = M.can_cast(a)
        if not compact then
            local runes, rsrc = M.runes(a)
            local cd, csrc = M.cooldown_s(a)
            out[#out + 1] = {
                id = a, name = g.name or meta.name or a, role = meta.role or "other", route = M.route(a),
                runes = runes, runes_source = rsrc, cooldown_s = cd, cooldown_source = csrc,
                remaining_s = M.remaining_s(a), castable = ok, reason = reason,
                preconditions = meta.preconditions or {}, use_when = meta.use_when or "",
            }
        elseif ok or M.TRANSIENT_REASONS[reason] then
            out[#out + 1] = {
                id = a, name = g.name or meta.name or a, role = meta.role or "other",
                use_when = meta.use_when or "", castable = ok, reason = reason,
                remaining_s = (cdata and cdata.remaining_s) or M.remaining_s(a), missing = cdata and cdata.missing,
            }
        end
    end
    return out
end

-- ------------------------------------------------------------------ Luis's unlocks (mirror)
-- Pure: a catalog `players[i]` snapshot (spell_dump X1) -> {unlocked={asset=true}, perks={perk=true}}.
function M.mirror_from_snapshot(snap)
    if type(snap) ~= "table" or type(snap.spells_unlocked) ~= "table" then return nil end
    local m = { unlocked = {}, perks = nil, source = "catalog_snapshot", name = snap.name }
    for _, a in ipairs(snap.spells_unlocked) do m.unlocked[a] = true end
    if type(snap.active_perks) == "table" then
        m.perks = {}
        for _, p in ipairs(snap.active_perks) do m.perks[p] = true end
    end
    return m
end

local function each_set(s, fn)
    if s == nil then return false end
    return pcall(function()
        s:ForEach(function(a, b)
            local e = b ~= nil and b or a
            local v = U.try(function() return e:get() end)
            fn(v ~= nil and v or e)
        end)
    end)
end

local function each_arr(arr, fn)
    if arr == nil then return false end
    return pcall(function()
        arr:ForEach(function(_, e)
            local v = U.try(function() return e:get() end)
            fn(v ~= nil and v or e)
        end)
    end)
end

-- Read-only live read of a connected player's unlocks (the reads X1 verified). nil when unreadable.
function M.read_player_unlocks(pawn)
    local pc = U.controller_of(pawn)
    if not pc then return nil end
    local prog = U.try(function() return pc.ProgressComponent end)
    if not U.valid(prog) then return nil end
    local m = { unlocked = {}, perks = nil, source = "live", name = U.player_name(pawn) }
    local n = 0
    local ok = each_set(U.try(function() return prog.SpellsUnlocked end), function(s)
        local id = U.short(s)
        if id then m.unlocked[id] = true; n = n + 1 end
    end)
    if not ok or n == 0 then return nil end
    local spc = U.try(function() return pc.SkillPerkComponent end)
    if U.valid(spc) then
        local perks = {}
        local okp = each_arr(U.try(function() return spc.SkillPerkRuntimeStates end), function(st)
            each_arr(U.try(function() return st.ActivePerkDatas end), function(p)
                local id = U.short(p)
                if id then perks[id] = true end
            end)
        end)
        if okp and next(perks) then m.perks = perks end
    end
    return m
end

-- Mirror provider for configure({mirror=...}): Luis = the first connected player (U.find_player).
-- Cached for MIRROR_TTL_S; when no player is online or the read fails, the catalog snapshot.
function M.live_mirror()
    local cache = { at = nil, m = nil }
    return function()
        local now = S.clock()
        if cache.at and now - cache.at >= 0 and now - cache.at < M.MIRROR_TTL_S then return cache.m end
        local luis = U.find_player("luis")
        local m = luis and M.read_player_unlocks(luis)
        if not m then
            local c = S.catalog
            m = c and type(c.players) == "table" and M.mirror_from_snapshot(c.players[1]) or nil
        end
        cache.at, cache.m = now, m
        return m
    end
end

-- ------------------------------------------------------------------ helpers
local function resolve_point(target)
    if type(target) == "table" then
        if type(target.X) == "number" then return { X = target.X, Y = target.Y, Z = target.Z } end
        local w = U.from_wire(target)
        if w then return w end
        local l = U.loc(target)
        if l then return l, target end
    elseif type(target) == "userdata" then
        local l = U.loc(target)
        if l then return l, target end
    end
    return nil
end

local function nearest_player_cm(point)
    local best = math.huge
    local players = U.split_pawns()
    for _, p in ipairs(players) do
        local d = U.dist(point, U.loc(p))
        if d < best then best = d end
    end
    return best, #players
end

local function stomp_radius()
    local c = S.catalog
    local r = c and c.explosions and c.explosions.windstep and c.explosions.windstep.delayed_damage
              and c.explosions.windstep.delayed_damage.radius
    return (type(r) == "number" and r > 0) and r or M.STOMP_RADIUS_CM
end

-- pure: points = {{X,Y,Z}, ...}; returns centre, count of the best cluster of >= min_n within
-- radius_cm of one of the points (O(n^2), n is small).
function M.pick_cluster(points, radius_cm, min_n)
    local best, best_n = nil, 0
    for i, p in ipairs(points or {}) do
        local n, sx, sy, sz = 0, 0, 0, 0
        for _, q in ipairs(points) do
            if U.dist(p, q) <= radius_cm then n = n + 1; sx, sy, sz = sx + q.X, sy + q.Y, sz + q.Z end
        end
        if n > best_n then best, best_n = { X = sx / n, Y = sy / n, Z = sz / n }, n end
        local _ = i
    end
    if best_n >= (min_n or 1) then return best, best_n end
    return nil, best_n
end

-- ------------------------------------------------------------------ routes
local ROUTE_FN = {}

-- Windstep stun (X3). BP_WindstepExplosion_C's BeginPlay (authority) already calls
-- StartDelayedDamage (ubergraph CallFunc_StartDelayedDamage); opts.trigger="force" calls it again.
function ROUTE_FN.wind_stomp(p, asset, target, opts)
    local point = resolve_point(target == nil and p or target)
    if not point then return result(false, "invalid_args", { detail = "target must be an actor, {X,Y,Z} cm or [x,y,z] m" }) end
    local radius = stomp_radius()
    local safe = math.max(M.SAFE_PLAYER_CM, radius * 1.5)
    local pd = nearest_player_cm(point)
    if pd < safe then
        return result(false, "unsafe", { detail = "a player is within the stomp safety distance", player_cm = pd, safe_cm = safe })
    end
    local cls = U.try(StaticFindObject, M.PATHS.explosion_windstep)
    if not U.valid(cls) then return result(false, "not_implemented", { detail = "BP_WindstepExplosion_C not loaded" }) end
    local world = U.try(function() return p:GetWorld() end)
    if not world then return result(false, "companion_down", { detail = "no world" }) end
    local ex
    local ok, err = U.call(S.log, "spells.spawn_windstep_explosion", { at = point }, function()
        ex = world:SpawnActor(cls, point, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(ex) then return result(false, "body_error", { detail = "spawn failed: " .. tostring(err) }) end
    U.call(S.log, "spells.explosion_set_owner", { owner = U.short(p) }, function() ex:SetOwner(p) end)
    if opts.trigger == "force" then
        U.call(S.log, "spells.StartDelayedDamage", { delay = 0.0 }, function() ex.DelayedDamageInfliction:StartDelayedDamage(0.0) end)
    end
    U.call(S.log, "spells.explosion_lifespan", { s = M.STOMP_LIFESPAN_S }, function() ex:SetLifeSpan(M.STOMP_LIFESPAN_S) end)
    S.stomps[#S.stomps + 1] = { at = point, t = S.clock(), radius = radius }
    while #S.stomps > 8 do table.remove(S.stomps, 1) end
    return result(true, nil, { explosion = U.short(ex), at = U.to_wire(point), radius_m = U.cm_to_m(radius),
                               nearest_player_m = U.cm_to_m(pd), trigger = opts.trigger or "begin_play", verified = false })
end

local function effect_instances(gec)
    local out = {}
    local arr = U.try(function() return gec.ReplicatedInstances end)
    if not arr then return out end
    pcall(function()
        arr:ForEach(function(_, e)
            local g = U.try(function() return e:get() end) or e
            out[#out + 1] = (U.fullname(g) or ""):match("^(%S+)") or "?"
        end)
    end)
    return out
end

-- Self gameplay effect (X4): Tempest Shield and other self-targeted GEs.
function ROUTE_FN.self_effect(p, asset, _target, opts)
    local meta = M.META[asset] or {}
    local ge_path, up_path = meta.effect, meta.upgraded_effect
    if not ge_path then ge_path, up_path = game_self_effect(asset) end
    if opts.upgraded and up_path then ge_path = up_path end
    if not ge_path then return result(false, "not_implemented", { detail = "no self gameplay effect known for " .. asset }) end
    local cls = U.try(StaticFindObject, ge_path)
    if not U.valid(cls) then return result(false, "not_implemented", { detail = "effect class not loaded", effect = ge_path }) end
    local gec = U.try(function() return p.GameplayEffectsComponent end)
    if not U.valid(gec) then return result(false, "body_error", { detail = "no GameplayEffectsComponent" }) end
    local before = effect_instances(gec)
    local ok, err = U.call(S.log, "spells.InstantiateGameplayEffect", { effect = ge_path }, function()
        gec:InstantiateGameplayEffect(cls, nil, false)
    end)
    if not ok then return result(false, "body_error", { detail = tostring(err) }) end
    local after = effect_instances(gec)
    local verified = #after > #before
    return result(verified, (not verified) and "verification_failed" or nil,
                  { effect = ge_path, instances_before = #before, instances_after = #after, instances = after, verified = verified })
end

-- Weapon enchant (X7, UNVERIFIED): property write on the held actor, then its OnRep for visuals.
function ROUTE_FN.held_effect(p, asset, _target, opts)
    local meta = M.META[asset] or {}
    local heed_path = game_held_effect(asset)
    if not heed_path and meta.held_effect then
        heed_path = ("/Game/Gameplay/UtilityMagic/PerkSpells/%s/%s.%s"):format(
            asset:find("Corruption") and "CorruptionArrows" or "EnchantWeapon", meta.held_effect, meta.held_effect)
    end
    local heed = heed_path and U.try(StaticFindObject, heed_path)
    if not U.valid(heed) then return result(false, "not_implemented", { detail = "held effect data not loaded", held_effect = heed_path }) end
    local eq = U.try(function() return p.PlayerEquipmentComponent end)
    local held = eq and U.try(function() return eq.HeldEquipmentActorRight end)
    if not U.valid(held) then return result(false, "invalid_args", { detail = "nothing held in the right hand" }) end
    local gs = U.try(function() return p:GetWorld().GameState end)
    local now = gs and tonumber(U.try(function() return gs:GetServerWorldTimeSeconds() end))
    if not now then return result(false, "body_error", { detail = "no server world time" }) end
    local dur = tonumber(opts.duration_s) or 300
    local ok, err = U.call(S.log, "spells.held_effect_write", { heed = heed_path, until_s = now + dur }, function()
        held.PhysicalHeldEquipmentEffectInfo = { EffectData = heed, ServerExpirationTime = now + dur }
        held:OnRep_PhysicalHeldEquipmentEffectInfo(nil)
        held:ForceNetUpdate()
    end)
    if not ok then return result(false, "body_error", { detail = tostring(err) }) end
    local back = U.fullname(U.try(function() return held.PhysicalHeldEquipmentEffectInfo.EffectData end))
    local verified = back ~= nil and back:find(heed_path:match("([%w_]+)$"), 1, true) ~= nil
    return result(verified, (not verified) and "verification_failed" or nil,
                  { held_effect = heed_path, expires_s = now + dur, verified = verified, damage_change = "unverified" })
end

-- Real cast through the game's module graph (X5). OPT-IN ONLY.
function ROUTE_FN.modular(p, asset)
    if not S.allow_modular then return result(false, "not_implemented", { detail = "modular route is opt-in" }) end
    local g = game_rec(asset)
    local path = g and g.path
    local sd = path and U.try(StaticFindObject, path)
    if not U.valid(sd) then return result(false, "not_implemented", { detail = "spell data not loaded", spell = asset }) end
    local lib = U.try(StaticFindObject, M.PATHS.runtime_lib)
    if not U.valid(lib) then return result(false, "body_error", { detail = "DominionRuntimeBlueprintLibrary CDO missing" }) end
    local ok, err = U.call(S.log, "spells.TriggerModularAbilityForPlayer", { spell = asset }, function()
        lib:TriggerModularAbilityForPlayer(p, sd)
    end)
    if not ok then return result(false, "body_error", { detail = tostring(err) }) end
    return result(true, nil, { spell = asset, verified = false })
end

M._ROUTE_FN = ROUTE_FN

-- ------------------------------------------------------------------ cast
-- target_or_location: an actor, {X,Y,Z} cm, [x,y,z] m, or nil for self spells.
-- opts: {trigger="force" (wind_stomp), upgraded=true (self_effect), duration_s (held_effect)}
function M.cast(p, name, target, opts)
    opts = opts or {}
    if not U.valid(p) then return result(false, "companion_down", { detail = "no puppet" }) end
    local ok, reason, data = M.can_cast(name)
    if not ok then return result(false, reason, data) end
    local asset, route = data.spell, data.route
    local fn = ROUTE_FN[route]
    if not fn then return result(false, "not_implemented", data) end
    log("spell_cast", { spell = asset, route = route })
    local r = fn(p, asset, target, opts)
    r.data = r.data or {}
    r.data.spell, r.data.route = asset, route
    -- a native call ran even when verification failed: still start the cooldown, never double-cast
    local ran = r.ok or r.reason == "verification_failed"
    if ran then
        local now = S.clock()
        S.last_cast[asset], S.last_any = now, now
        r.data.paid = pay(asset)
        r.data.cooldown_s = M.cooldown_s(asset)
    end
    log("spell_cast_end", { spell = asset, ok = r.ok, reason = r.reason })
    return r
end

-- ------------------------------------------------------------------ stun detection
function M.note_knockdown(ai, on)
    local id = U.short(ai) or (type(ai) == "string" and ai) or nil
    if id then S.knockdown[id] = on and true or nil end
end

-- -> stunned(bool), detail{stumbling, knockdown, presumed}
function M.is_target_stunned(ai)
    local detail = { stumbling = false, knockdown = false, presumed = false }
    if not U.valid(ai) then return false, detail end
    local hr = U.try(function() return ai.AiHitReactionsComponent end)
    if U.valid(hr) then detail.stumbling = U.try(function() return hr:IsStumbling() end) == true end
    detail.knockdown = S.knockdown[U.short(ai)] == true
    local here = U.loc(ai)
    local now = S.clock()
    for _, s in ipairs(S.stomps) do
        if now - s.t <= M.STUN_PRESUME_S and U.dist(here, s.at) <= s.radius then detail.presumed = true end
    end
    return detail.stumbling or detail.knockdown, detail
end

-- ------------------------------------------------------------------ catalog metadata (X1 merge)
function M.usage(asset)
    local meta = M.META[asset] or {}
    local route = M.route(asset)
    local runes, rsrc = M.runes(asset)
    local cd, csrc = M.cooldown_s(asset)
    local g = game_rec(asset) or {}
    return {
        role = meta.role or "other", name = g.name or meta.name,
        preconditions = meta.preconditions or {},
        use_when = meta.use_when or ("Cast " .. tostring(g.name or meta.name or asset) .. " (no usage notes yet)."),
        runes = runes, runes_source = rsrc, cooldown_s = cd, cooldown_source = csrc,
        route = route, route_verified = M.route_verified(route) == true,
        wiki = meta.wiki, requires_perk = meta.requires_perk, mechanism = meta.mechanism,
        catalogued_in_meta = M.META[asset] ~= nil,
    }
end

function M.merge_catalog(doc)
    local prev = S.catalog
    S.catalog = doc
    local missing = {}
    for asset, rec in pairs(doc.spells or {}) do
        rec.usage = M.usage(asset)
        if not M.META[asset] then missing[#missing + 1] = asset end
    end
    table.sort(missing)
    doc.usage_roles = M.ROLES
    doc.cost_policies = { "free", "budget", "mirror", "mirror_budget" }
    -- keep any verified status the catalog already records (route_verified reads doc.routes here)
    local routes = {}
    for r, info in pairs(M.ROUTES) do
        local v, note = M.route_verified(r)
        routes[r] = { verified = v, note = note or info.note }
    end
    doc.routes = routes
    doc.meta_missing = missing
    local not_loaded = {}
    for asset in pairs(M.META) do if not (doc.spells or {})[asset] then not_loaded[#not_loaded + 1] = asset end end
    table.sort(not_loaded)
    doc.meta_not_in_game = not_loaded
    S.catalog = prev
    return doc
end

-- ------------------------------------------------------------------ combat reflexes (BT hook)
-- Tactics the Controller may set (honours "save shield for the boss": shield=false).
M.TACTICS_DEFAULT = { shield = true, shield_hp_frac = 0.5, shield_on_threat = true,
                      stomp = true, stomp_min = 3, stomp_scan_cm = 1500, eval_ms = 500 }
S.tactics = {}
for k, v in pairs(M.TACTICS_DEFAULT) do S.tactics[k] = v end

function M.set_tactics(t)
    for k, v in pairs(t or {}) do if M.TACTICS_DEFAULT[k] ~= nil then S.tactics[k] = v end end
    return M.tactics()
end
function M.tactics() local c = {}; for k, v in pairs(S.tactics) do c[k] = v end; return c end

local function enemy_points(around, scan_cm)
    local pts = {}
    for _, ai in ipairs(U.try(FindAllOf, "DominionAICharacter") or {}) do
        if U.valid(ai) and U.try(function() return ai:IsFollower() end) ~= true and (U.health(ai) or 1) > 0 then
            local at = U.loc(ai)
            if at and U.dist(around, at) <= scan_cm then pts[#pts + 1] = at end
        end
    end
    return pts
end

-- Utility scoring (design section 9): each scorer maps the situation to (score 0..~1.2, target).
-- The best castable spell above SCORE_THRESHOLD is cast. Add more with M.add_scorer(asset, fn).
-- situation = {hp_frac, threat (fresh telegraph), cluster_n, cluster_centre, kalphite}
M.SCORE_THRESHOLD = 0.5
M.SCORERS = {
    USD_TempestShield = function(sit, tac)
        if not tac.shield then return 0 end
        local v = 0
        if sit.hp_frac and sit.hp_frac < tac.shield_hp_frac then v = 0.6 + (tac.shield_hp_frac - sit.hp_frac) end
        if sit.threat and tac.shield_on_threat then v = math.max(v, 0.8) end
        return v
    end,
    USD_Windstep = function(sit, tac)
        if not tac.stomp or not sit.cluster_centre or (sit.cluster_n or 0) < tac.stomp_min then return 0 end
        return 0.55 + 0.1 * (sit.cluster_n - tac.stomp_min) + (sit.kalphite and 0.2 or 0), sit.cluster_centre
    end,
}
function M.add_scorer(asset, fn) M.SCORERS[asset] = fn end

-- -> ranked list of {spell, score, target} above the threshold (pure given the situation).
function M.rank(sit)
    local out = {}
    for asset, fn in pairs(M.SCORERS) do
        local ok, score, target = pcall(fn, sit, S.tactics)
        if ok and type(score) == "number" and score >= M.SCORE_THRESHOLD then
            out[#out + 1] = { spell = asset, score = score, target = target }
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

function M.situation(ctx)
    local tac = S.tactics
    local p, t = ctx.p, ctx.t
    local hp, max = U.health(p), U.max_health(p)
    local th = ctx.threat
    local sit = { hp_frac = (hp and max and max > 0) and hp / max or nil,
                  threat = th and ctx.now and th.at and ctx.now - th.at < 1000 or false }
    if U.valid(t) then
        sit.cluster_centre, sit.cluster_n = M.pick_cluster(enemy_points(U.loc(t), tac.stomp_scan_cm), stomp_radius(), 1)
        sit.kalphite = (U.short(t) or ""):find("Kalphite", 1, true) ~= nil
    end
    return sit
end

-- Which reflex scorers may cast live: a scorer's spell is ON only when its route is verified in
-- game (catalog routes[r].verified, M.route_verified) or unverified routes are allowed
-- (DW_SPELLS_UNVERIFIED=1). -> {asset = {route, verified, on, why}}
function M.reflex_status()
    local out = {}
    for asset in pairs(M.SCORERS) do
        local route = M.route(asset)
        local verified, note = M.route_verified(route)
        local on = route ~= "none" and (verified or S.allow_unverified)
        out[asset] = { route = route, verified = verified, on = on,
                       why = (not on) and ("route " .. route .. " not verified in game: " .. tostring(note)) or nil }
    end
    return out
end

-- One decision per eval_ms. Returns the cast spell's id (truthy: the BT skips the swing) or nil.
-- ctx = {a, p, t, hp, d, now, threat, ...} from body/combat.lua.
function M.combat_tick(ctx)
    local a = ctx.a or {}
    if a._spell_eval and ctx.now and ctx.now - a._spell_eval < S.tactics.eval_ms then return nil end
    a._spell_eval = ctx.now
    if not U.valid(ctx.p) then return nil end
    local status = M.reflex_status()
    for _, c in ipairs(M.rank(M.situation(ctx))) do
        if status[c.spell] and status[c.spell].on and M.can_cast(c.spell) then
            local r = M.cast(ctx.p, c.spell, c.target, {})
            if r.ok then log("spell_reflex", { spell = c.spell, score = c.score }); return c.spell end
            log("spell_reflex_failed", { spell = c.spell, reason = r.reason })
        end
    end
    return nil
end

-- Install into body/combat.lua's BT (on_tick hook): Tempest Shield on low HP or a fresh telegraph
-- (combat.notify_threat, fed by body/rules.lua's sensor), Windstep (Wind Stomp) on a cluster of
-- tactics.stomp_min (3) or more. Each is gated per route by M.reflex_status(). Returns the remover.
function M.install_combat_hooks(combat)
    local remover = combat.add_hook("on_tick", "spells", M.combat_tick)
    log("spells_reflexes_installed", { routes = M.reflex_status(), allow_unverified = S.allow_unverified })
    return remover
end

-- ------------------------------------------------------------------ bridge
-- cast {spell, target?, trigger?, upgraded?}: target is an entity id, a player name is refused, or
-- [x,y,z] metres. spells {}: the list. Both honour args.probe.
-- opts: {puppet, find_ai(id, origin) -> actor, catalog_path, cost_policy, inventory (store with
-- count/take), mirror (false = none; default M.live_mirror()), allow_unverified}.
-- Env: DW_SPELL_COST_POLICY overrides opts.cost_policy; DW_SPELLS_UNVERIFIED=1 allows unverified
-- routes (manual casts and reflexes); DW_SPELLS_MODULAR=1 allows the modular route.
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod or S.log
    S.puppet = opts.puppet or S.puppet
    if opts.catalog_path then
        local doc, err = M.load_catalog(opts.catalog_path)
        log("spells_catalog", { path = opts.catalog_path, ok = doc ~= nil, err = err,
                                spells = doc and doc.spell_count or nil })
    end
    if opts.inventory ~= nil then S.inventory = opts.inventory end
    if opts.mirror ~= false and S.mirror == nil then S.mirror = opts.mirror or M.live_mirror() end
    local policy = os.getenv("DW_SPELL_COST_POLICY")
    if policy == "" then policy = nil end
    policy = policy or opts.cost_policy
    if policy then M.configure({ cost_policy = policy }) end
    if os.getenv("DW_SPELLS_MODULAR") == "1" then S.allow_modular = true end
    if os.getenv("DW_SPELLS_UNVERIFIED") == "1" or opts.allow_unverified == true then S.allow_unverified = true end
    log("spells_registered", M.config())
    local find_ai = opts.find_ai -- function(id) -> actor (skills.lua's resolver), optional
    -- spells {compact?}: the list (compact = only what the bot could cast, for the Controller)
    bridge.handlers.spells = function(args)
        if type(args) == "table" and args.probe == true then return result(true, nil, { probe = true, tool = "spells" }) end
        local compact = type(args) == "table" and args.compact == true
        return result(true, nil, { spells = M.list({ compact = compact }), config = M.config(), reflexes = M.reflex_status() })
    end
    bridge.handlers.cast = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "cast" }) end
        if type(args.spell) ~= "string" or args.spell == "" then return result(false, "invalid_args", { detail = "spell is required" }) end
        local pm = S.puppet or require("body.puppet")
        local p = U.try(pm.get)
        if not p then return result(false, "companion_down", {}) end
        local target = args.target
        if target == "self" or target == "" then
            target = nil
        elseif type(target) == "string" then
            local ai = find_ai and find_ai(target, U.loc(p))
            if not ai then return result(false, "unknown_target", { target = target }) end
            target = ai
        end
        return M.cast(p, args.spell, target, { trigger = args.trigger, upgraded = args.upgraded == true })
    end
    -- spell_tactics {shield=false, stomp_min=4, ...}: the Controller's knobs for the reflexes
    bridge.handlers.spell_tactics = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "spell_tactics" }) end
        args.probe = nil
        return result(true, nil, { tactics = M.set_tactics(args) })
    end
    return M
end

return M
