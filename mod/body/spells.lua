-- Spells service for the companion body (docs/design/robustness-and-item-catalog.md sections 3-6,
-- research docs/research/2026-10-25-spells-and-weaknesses.md). Small API:
--   M.configure(opts)                 policy, inventory store, mirror, clock, catalog path, flags
--   M.list()                          every catalogued spell with role/cost/cooldown/readiness
--   M.can_cast(name)                  -> ok, reason, data   (resolution, route, cooldown, cost policy)
--   M.cast(puppet, name, target, o)   -> {ok, reason, data} (runs the route; starts cooldown; pays)
--   M.is_target_stunned(ai)           -> bool, detail      (IsStumbling() or a hooked knockdown)
--   M.note_knockdown(ai, on)          hook sink for BP_DominionAICharacter_C:OnAIKnockdownState_*
--   M.pick_cluster(points, r, n)      pure helper for "Windstep into 3+ enemies"
--   M.register(bridge, log, opts)     bridge handlers `cast` and `spells` (main.lua must call it)
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
-- A route is used live only once verified in game (M.ROUTES[r].verified) unless allow_unverified.
-- pcall cannot catch native crashes, so every native call goes through U.call (breadcrumb first).
--
-- Cost policies (configure {cost_policy=...}, env DW_SPELL_COST_POLICY):
--   "free"    ignore runes
--   "budget"  runes come from the bot's inventory store (planned mod/body/inventory.lua):
--             store.count(item_id) -> number and store.take(item_id, n) -> bool, item_id like
--             "ITEM_Rune_Air". Paid only after a successful cast.
--   "mirror"  only spells Luis has unlocked (mirror.unlocked[asset]); perk-gated variants (Wind
--             Stomp) also need the perk in mirror.perks when perks are known. Runes are not charged.
local U = require("body.util")

local M = {}

M.BUILD = "26161880"
M.MIN_GAP_S = 1.0               -- global spacing between two casts (any spell)
M.SAFE_PLAYER_CM = 1000         -- never put an AoE within 10 m of a real player
M.STOMP_RADIUS_CM = 500         -- fallback if the catalog has no explosion radius
M.STOMP_LIFESPAN_S = 5.0        -- the explosion actor is cleaned up after this
M.STUN_PRESUME_S = 1.5          -- after our stomp, targets in radius count as "stunned" this long
M.POLICIES = { free = true, budget = true, mirror = true }
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
    wind_stomp = { verified = false, note = "X3" },
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
        preconditions = { "enemy cluster >= 3 within ~5 m of the landing point (Kalphites especially)", "no player within 10 m of the landing point" },
        use_when = "Wind Stomp: an AoE stagger at the landing point; use on groups (great vs Kalphites), then hit them while they stumble." },
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
        use_when = "Throws a conjured axe that fells every tree in its path; use when chopping a row of trees (uses the held axe's damage)." },
    USD_Splinter = { name = "Splinter", role = "gathering_aoe", runes = { Earth = 10, Nature = 5 }, wiki = W("Woodcutting", 27),
        preconditions = { "holding an axe", "felled tree trunks on the ground nearby" },
        use_when = "Chops fallen trunks around the caster into logs at once; cast after felling trees (pair with Trunk Totem)." },
    USD_PileEmUp = { name = "Trunk Totem", role = "gathering_aoe", runes = { Nature = 30, Law = 10 }, wiki = W("Woodcutting", 52),
        aliases = { "trunk totem", "totem" },
        preconditions = { "several felled trunks scattered nearby" },
        use_when = "Gathers scattered felled trunks into one totem; then cast Splinter on it to get all the logs." },
    USD_Rocksplosion = { name = "Rocksplosion", role = "gathering_aoe", runes = { Earth = 15, Fire = 5 }, wiki = W("Mining", 11),
        preconditions = { "boulders or ore rocks nearby" }, use_when = "Breaks apart nearby boulders and ore; use while mining." },
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

local function check_policy(asset)
    if S.policy == "free" then return true end
    if S.policy == "mirror" then
        local m = mirror_state()
        if not m or type(m.unlocked) ~= "table" then return false, "state_unavailable", { detail = "no mirror of Luis's unlocks" } end
        if not m.unlocked[asset] then return false, "not_unlocked", { spell = asset } end
        local perk = (M.META[asset] or {}).requires_perk
        if perk and type(m.perks) == "table" and not m.perks[perk] then
            return false, "not_unlocked", { spell = asset, perk = perk }
        end
        return true
    end
    -- budget
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

local function pay(asset)
    if S.policy ~= "budget" then return {} end
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
    local rinfo = M.ROUTES[route]
    if not (rinfo and (rinfo.verified or S.allow_unverified)) then
        data.detail = "route not verified in game (" .. tostring(rinfo and rinfo.note) .. ")"
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

function M.list()
    local out = {}
    for _, a in ipairs(all_assets()) do
        local meta, g = M.META[a] or {}, game_rec(a) or {}
        local ok, reason = M.can_cast(a)
        local runes, rsrc = M.runes(a)
        local cd, csrc = M.cooldown_s(a)
        out[#out + 1] = {
            id = a, name = g.name or meta.name or a, role = meta.role or "other", route = M.route(a),
            runes = runes, runes_source = rsrc, cooldown_s = cd, cooldown_source = csrc,
            remaining_s = M.remaining_s(a), castable = ok, reason = reason,
            preconditions = meta.preconditions or {}, use_when = meta.use_when or "",
        }
    end
    return out
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
        route = route, route_verified = (M.ROUTES[route] or {}).verified == true,
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
    doc.cost_policies = { "free", "budget", "mirror" }
    doc.routes = M.ROUTES
    doc.meta_missing = missing
    local not_loaded = {}
    for asset in pairs(M.META) do if not (doc.spells or {})[asset] then not_loaded[#not_loaded + 1] = asset end end
    table.sort(not_loaded)
    doc.meta_not_in_game = not_loaded
    S.catalog = prev
    return doc
end

-- ------------------------------------------------------------------ bridge
-- cast {spell, target?, trigger?, upgraded?}: target is an entity id, a player name is refused, or
-- [x,y,z] metres. spells {}: the list. Both honour args.probe.
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod or S.log
    S.puppet = opts.puppet or S.puppet
    if opts.cost_policy or os.getenv("DW_SPELL_COST_POLICY") then
        M.configure({ cost_policy = opts.cost_policy or os.getenv("DW_SPELL_COST_POLICY") })
    end
    if os.getenv("DW_SPELLS_MODULAR") == "1" then S.allow_modular = true end
    if opts.catalog_path then M.load_catalog(opts.catalog_path) end
    local find_ai = opts.find_ai -- function(id) -> actor (skills.lua's resolver), optional
    bridge.handlers.spells = function(args)
        if type(args) == "table" and args.probe == true then return result(true, nil, { probe = true, tool = "spells" }) end
        return result(true, nil, { spells = M.list(), config = M.config() })
    end
    bridge.handlers.cast = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "cast" }) end
        if type(args.spell) ~= "string" or args.spell == "" then return result(false, "invalid_args", { detail = "spell is required" }) end
        local pm = S.puppet or require("body.puppet")
        local p = U.try(pm.get)
        if not p then return result(false, "companion_down", {}) end
        local target = args.target
        if type(target) == "string" then
            local ai = find_ai and find_ai(target, U.loc(p))
            if not ai then return result(false, "unknown_target", { target = target }) end
            target = ai
        end
        return M.cast(p, args.spell, target, { trigger = args.trigger, upgraded = args.upgraded == true })
    end
    return M
end

return M
