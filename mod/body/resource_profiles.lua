-- Gatherable resource profiles: DATA for body/gather.lua (build 26161880). Adding a gatherable is
-- adding an entry here (recipe: docs/ARCHITECTURE.md "Add a gatherable"). No code per resource.
--
-- profile = {
--   item       = drop item data path (what is counted in the inventory)
--   aliases    = names the brain may use for it (lower case; also matched: item id, item path)
--   tool       = tool category key in TOOL_CATEGORIES ("axe" | "pickaxe"); min_tier = fallback tier
--                (the live gate on the resource, BP_DamageModifier_SpecificWeapon_C.RequiredTier, wins)
--   foliage    = true: the resource lives as foliage until converted (trees), sense.convert_foliage
--   root       = the stage SCAN looks for: {class (FindAllOf short class), match (Lua pattern on the
--                class word), exclude, filter (sense.FILTERS), attack = "primary" | "special", reach_cm}
--   settle     = optional {class, match, max_ms}: wait while this transient actor exists near the site
--                (the toppling felled tree that turns into log pieces)
--   children   = stages worked at the site after the root is broken, in priority order:
--                {name, class, match, filter, attack, reach_cm, bonus = true (optional, args.bonus=false
--                skips it), at_root = true (the root actor itself, e.g. the stump)}
--   site_radius_cm / collect_radius_cm = how far from the root the children / the drops are looked for
--   verified   = which parts were seen in game (DISCOVERIES); false = from names only
-- }
-- Facts (live census 2026-10-25, experiments/gather_probe; W1 timeline in DISCOVERIES):
--   oak tree HP 220 split fraction 0.5 (-> stump HP 110 + BP_FelledTree_Oak_C HP 105 -> BP_SplittableLog_Oak_C
--   HP 105 -> BP_Log_Oak_C HP 105 -> 6 x ITEM_Resources_Wood_Oak stack 1; stump drops 1 more), gate
--   DA_HatchetOnly_Tier3 (tree and stump). Ash HP 160, DA_HatchetOnly (tier 1), splittable HP 80.
--   Stone: BP_OreNode_Stone_C (a DestructibleMiningRock) HP 75, DA_PickaxeOnly (tier 1), drops
--   ITEM_Resources_Stone 10-16, bDestroyActorOnZeroHealth=false (hidden, respawns). Rune essence:
--   BP_MiningRock_RuneEssence_Static_A_C HP 60, 5 x ITEM_Rune_Essence.
local M = {}

M.BUILD = "26161880"

M.TOOL_CATEGORIES = {
    axe = { tag = "Item.Equipment.Tool.Hatchet" },
    pickaxe = { tag = "Item.Equipment.Tool.Pickaxe" },
}

-- Tool items: tier and damage multiplier from data/items_26161880.json (tests/test_gather_data.py
-- checks this table against the catalog). Per-hit damage = attack step damage (10) x mult; verified
-- for Adamant: 84 per hit = Luis's log 105 -> 21 -> 0 (W1).
M.TOOLS = {
    ITEM_Logging_Axe_Stone = { category = "axe", tier = 1, mult = 1.5 },
    ITEM_Logging_Axe_Bronze = { category = "axe", tier = 3, mult = 2.0 },
    ITEM_Logging_Axe_Iron = { category = "axe", tier = 4, mult = 3.0 },
    ITEM_Logging_Axe_Steel = { category = "axe", tier = 5, mult = 4.0 },
    ITEM_Logging_Axe_Mithril = { category = "axe", tier = 6, mult = 6.8 },
    ITEM_Logging_Axe_Adamant = { category = "axe", tier = 7, mult = 8.4 },
    ITEM_Logging_Axe_Rune = { category = "axe", tier = 8, mult = 9.5 },
    ITEM_Pickaxe_Stone = { category = "pickaxe", tier = 1, mult = 1.0 },
    ITEM_Pickaxe_Bone = { category = "pickaxe", tier = 2, mult = 1.5 },
    ITEM_Pickaxe_Bronze = { category = "pickaxe", tier = 3, mult = 3.4 },
    ITEM_Pickaxe_Iron = { category = "pickaxe", tier = 4, mult = 5.0 },
    ITEM_Pickaxe_Steel = { category = "pickaxe", tier = 5, mult = 6.6 },
    ITEM_Pickaxe_Mithril = { category = "pickaxe", tier = 6, mult = 8.2 },
    ITEM_Pickaxe_Adamant = { category = "pickaxe", tier = 7, mult = 8.4 },
    ITEM_Pickaxe_Rune = { category = "pickaxe", tier = 7, mult = 9.5 },
}

local WOOD = "/Game/Gameplay/Items/Resources/Wood/"

-- A tree species from three class-word patterns; everything else is shared.
local function tree(species, item_id, min_tier, aliases, verified)
    return {
        item = WOOD .. item_id .. "." .. item_id, aliases = aliases, tool = "axe", min_tier = min_tier, foliage = true,
        root = { class = "FellableTree", match = "Tree_" .. species, exclude = "Sapling", filter = "standing",
                 attack = "primary", reach_cm = 170 },
        settle = { class = "FelledTree", match = "FelledTree_" .. species, max_ms = 10000 },
        children = {
            { name = "splittable", class = "SplittableTreeLog", match = "SplittableLog_" .. species, filter = "alive",
              attack = "special", reach_cm = 200 },
            { name = "log", class = "TreeLog", match = "^BP_Log_" .. species, filter = "alive", attack = "special", reach_cm = 200 },
            { name = "stump", class = "FellableTree", match = "Tree_" .. species, exclude = "Sapling", filter = "stump",
              attack = "special", reach_cm = 170, bonus = true, at_root = true },
        },
        site_radius_cm = 1000, collect_radius_cm = 1200, verified = verified,
    }
end

local function rock(match, item, aliases, verified)
    return {
        item = item, aliases = aliases, tool = "pickaxe", min_tier = 1, foliage = false,
        root = { class = "DestructibleMiningRock", match = match, filter = "alive", attack = "primary", reach_cm = 200 },
        children = {}, site_radius_cm = 600, collect_radius_cm = 800, verified = verified,
    }
end

local MINERAL = "/Game/Gameplay/Items/Resources/Mineral/"
local METAL = "/Game/Gameplay/Items/Resources/Metal/"

M.RESOURCES = {
    oak = tree("Oak", "ITEM_Resources_Wood_Oak", 3, { "oak", "oak_log", "oak_logs", "oak logs", "log", "logs", "wood" },
               { classes = true, chain = true, gate = true }),
    ash = tree("Ash", "ITEM_Resources_Wood_Ash", 1, { "ash", "ash_log", "ash_logs", "ash logs" },
               { classes = true, chain = "splittable only", gate = true }),
    willow = tree("Willow", "ITEM_Resources_Wood_Willow", 4, { "willow", "willow_log", "willow_logs" }, false),
    maple = tree("Maple", "ITEM_Resources_Wood_Maple", 5, { "maple", "maple_log", "maple_logs" }, false),
    stone = rock("OreNode_Stone", MINERAL .. "ITEM_Resources_Stone.ITEM_Resources_Stone",
                 { "stone", "stones", "rock", "rocks" }, { classes = true, gate = true }),
    rune_essence = rock("RuneEssence", "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Essence.ITEM_Rune_Essence",
                        { "rune_essence", "rune essence", "essence" }, { classes = true, gate = true }),
    -- Metal ores: the item paths are in the dump; the rock class names are a guess from the stone rock
    -- (BP_OreNode_Stone_C) and must be confirmed by a census near those rocks (docs/research/2026-10-25-mining.md).
    copper = rock("OreNode_Copper", METAL .. "ITEM_Resources_CopperOre.ITEM_Resources_CopperOre", { "copper", "copper_ore" }, false),
    tin = rock("OreNode_Tin", METAL .. "ITEM_Resources_TinOre.ITEM_Resources_TinOre", { "tin", "tin_ore" }, false),
    iron = rock("OreNode_Iron", METAL .. "ITEM_Resources_IronOre.ITEM_Resources_IronOre", { "iron", "iron_ore" }, false),
    coal = rock("OreNode_Coal", MINERAL .. "ITEM_Resources_Coal.ITEM_Resources_Coal", { "coal" }, false),
    clay = rock("OreNode_Clay", MINERAL .. "ITEM_Resources_Clay.ITEM_Resources_Clay", { "clay" }, false),
}

local function item_id(path) return path and (path:match("%.([%w_]+)$") or path) end
M.item_id = item_id

-- name -> key, profile. Accepts the key, an alias, the drop item id or path (case-insensitive).
function M.resolve(name)
    if type(name) ~= "string" or name == "" then return nil end
    local q = name:lower()
    if M.RESOURCES[q] then return q, M.RESOURCES[q] end
    for key, p in pairs(M.RESOURCES) do
        for _, a in ipairs(p.aliases or {}) do if a == q then return key, p end end
        if item_id(p.item):lower() == q or p.item:lower() == q then return key, p end
    end
    return nil
end

-- Tool info for a held item data path (nil when it is not a gathering tool).
function M.tool_for(item_path)
    local id = item_id(item_path)
    return id and M.TOOLS[id] or nil, id
end

return M
