-- gather_profiles: DATA for client_mod/scripts/gather.lua (route R2). Adding a gatherable = adding an
-- entry here; no code per resource (CLAUDE.md principle 2). Ported from the legacy server profiles
-- (mod/body/resource_profiles.lua, build 26161880: the W1 woodcutting timeline, gates and HP), with
-- the client facts of 2026-10-25 (client build 26162923, DISCOVERIES "Client gathering (R2)"):
--   * standing trees, bushes, branches and ground stones are FOLIAGE instances on the client
--     (InteractableFoliageISMComponent.ActorClass names the actor they turn into); the server
--     converts one within ~3 m of a player (NearbyFoliageConverterComponent Range 300) or when a
--     swing traces it, and the actor then replicates;
--   * rocks are level actors (DestructibleMiningRock, always replicated, HP readable).
--
-- profile = {
--   item     = counted drop item id (inventory.list `item`); nil for pickups = learned from the first
--              converted actor's ItemData (or item_match below)
--   item_match = Lua pattern on item ids/names counted when `item` is nil
--   aliases  = names the brain may use (lower case)
--   mode     = "chop" (destructible chain, tool swings) | "pickup" (walk up, interact key)
--   trains   = the skill whose XP this gather gives ("Woodcutting" / "Mining"), false = verified to give none,
--              nil = not measured (shown to the model in the gather result; data, not logic)
--   tool     = "axe" | "pickaxe" (weapons_data.lua `cat`); min_tier = fallback gate (the live gate on the
--              actor / its class default object wins)
--   root     = {class (FindAllOf class of the converted actor), match (pattern on the class word),
--              exclude (pattern or list), foliage = true (also found as foliage instances),
--              attack = "primary" | "special", reach_cm (stand this close to the aim point)}
--   children = stages worked at the site after the root breaks, in priority order (same fields;
--              bonus = true: only with args.stumps; at_root = true: the root actor itself (the stump))
--   settle   = {class, match, max_s}: wait while this transient actor exists near the site
--   site_radius_cm / collect_radius_cm
--   verified = what was seen in game
-- }
local M = {}
M.BUILD = "26162923"

local WOOD = "ITEM_Resources_Wood_"

local function tree(species, min_tier, aliases, opts)
    opts = opts or {}
    local cls = opts.class_match or ("Tree_" .. species)
    return {
        item = WOOD .. species, aliases = aliases, mode = "chop", tool = "axe", min_tier = min_tier, trains = "Woodcutting",
        root = { class = "FellableTree", match = cls, exclude = opts.exclude or { "Sapling" }, foliage = true,
                 attack = "primary", reach_cm = 120 },
        settle = { class = "FelledTree", match = "FelledTree_" .. species, max_s = 10 },
        children = {
            { name = "splittable", class = "SplittableTreeLog", match = "SplittableLog_" .. species, attack = "primary", reach_cm = 140 },
            { name = "log", class = "TreeLog", match = "^BP_Log_" .. species, attack = "primary", reach_cm = 140 },
            { name = "stump", class = "FellableTree", match = cls, exclude = { "Sapling" }, stump = true, attack = "primary",
              reach_cm = 120, bonus = true, at_root = true },
        },
        site_radius_cm = 1200, collect_radius_cm = 1400, verified = opts.verified or false,
    }
end

local function rock(match, item, aliases, verified, opts)
    opts = opts or {}
    return {
        item = item, aliases = aliases, mode = "chop", tool = "pickaxe", min_tier = 1, trains = "Mining",
        root = { class = "DestructibleMiningRock", match = match, attack = "primary", reach_cm = 150, max_above_m = opts.max_above_m },
        children = {}, site_radius_cm = 600, collect_radius_cm = 900, verified = verified,
    }
end

local function pickup(match, item, aliases, verified, opts)
    return {
        item = item, aliases = aliases, mode = "pickup", trains = (opts or {}).trains,
        root = { class = "BaseInteractableResource", match = match, foliage = true, reach_cm = 110 },
        children = {}, site_radius_cm = 400, collect_radius_cm = 400, verified = verified,
    }
end

M.RESOURCES = {
    -- Trees. Standard chop for all stages (Overhead Chop is Woodcutting 4: Claude is level 1).
    oak = tree("Oak", 3, { "oak", "oak_log", "oak_logs", "oak logs", "oak tree", "oak trees", "log", "logs", "wood" },
               { verified = { foliage = true, server_chain = true } }),
    ash = tree("Ash", 1, { "ash", "ash_log", "ash_logs", "ash logs", "ash tree", "ash trees" },
               { exclude = { "Sapling", "Bare" }, verified = { foliage = true, server_chain = "splittable only" } }),
    willow = tree("Willow", 4, { "willow", "willow_log", "willow_logs", "willow logs" }, { verified = { foliage = true } }),
    maple = tree("Maple", 6, { "maple", "maple_log", "maple_logs", "maple logs" }, { verified = { foliage = true } }),
    yew = tree("Yew", 7, { "yew", "yew_log", "yew_logs", "yew logs" }, { class_match = "YewTree", verified = { foliage = true } }),
    -- Rocks (level actors on the client).
    -- "stone" alone names BOTH stone_boulder (mined with a pickaxe: Mining XP) and loose_stones (picked off the
    -- ground: NO Mining XP, live skill_routes 2026-10-26: "Got 2 stone", Mining 3 -> 3), so neither key is "stone":
    -- a bare "stone" is the category (the nearest of either), and the model names the one it means.
    stone_boulder = rock("OreNode_Stone", "ITEM_Resources_Stone", { "stone_rock", "stone boulder", "stone rock", "stone rocks", "rock",
                                                                    "rocks", "boulder", "boulders", "mine stone", "mining stone" },
                         { actor = true, gate = true }),
    -- up to 3 essence rocks FLOAT above a geyser (wiki "Rune Essence Geyser"): never walk at those; they are knocked
    -- down first (shoot / a spell), then mined. 1.2 m above his capsule centre is about 2 m above the ground he stands on.
    rune_essence = rock("RuneEssence", "ITEM_Rune_Essence", { "rune_essence", "rune essence", "essence" }, { actor = true, gate = true },
                        { max_above_m = 1.2 }),
    copper = rock("OreNode_Copper", "ITEM_Resources_CopperOre", { "copper", "copper_ore", "copper ore" }, false),
    tin = rock("OreNode_Tin", "ITEM_Resources_TinOre", { "tin", "tin_ore", "tin ore" }, false),
    iron = rock("OreNode_Iron", "ITEM_Resources_IronOre", { "iron", "iron_ore", "iron ore" }, false),
    coal = rock("OreNode_Coal", "ITEM_Resources_Coal", { "coal" }, false),
    clay = rock("OreNode_Clay", "ITEM_Resources_Clay", { "clay" }, false),
    -- Ground pickups and bushes (foliage "PickUps" components; the interact key collects them).
    loose_stones = pickup("Spawner_Stone", "ITEM_Resources_Stone", { "loose stone", "loose stones", "ground stone", "ground stones",
                                                                     "pebble", "pebbles" }, { foliage = true, no_mining_xp = true },
                          { trains = false }),
    -- fallen ash branches: ItemData ITEM_Resources_Wood_Ash ("Ash Logs"), "Collect", no tool (DISCOVERIES ground
    -- gatherables, interact_probe 15:58 UTC): the first logs before any axe (gather falls back here from `ash`)
    sticks = pickup("Spawner_AshBranch", WOOD .. "Ash", { "stick", "sticks", "branch", "branches", "twig", "twigs" }, { foliage = true }),
    flax = pickup("Spawner_Flax", nil, { "flax" }, { foliage = true }),
    mushroom = pickup("Spawner_Mushroom", nil, { "mushroom", "mushrooms", "bittercap" }, { foliage = true }),
    redberries = pickup("RedberryBush", nil, { "redberry", "redberries", "berries", "berry bush" }, { foliage = true }),
    cadava = pickup("CadavaBush", nil, { "cadava", "cadava berries", "cadavaberries" }, { foliage = true }),
    pumpkin = pickup("Spawner_Pumpkin", nil, { "pumpkin", "pumpkins" }, { foliage = true }),
    cabbage = pickup("Spawner_Cabbage", nil, { "cabbage", "cabbages" }, { foliage = true }),
    onion = pickup("Spawner_Onion", nil, { "onion", "onions" }, { foliage = true }),
    marrentill = pickup("Spawner_Marrentil", nil, { "marrentill", "marrentil" }, { foliage = true }),
}

-- name -> key, profile. Accepts the key, an alias, or the drop item id (case-insensitive); then a
-- word match on keys/aliases ("oak logs please" -> oak).
function M.resolve(name)
    if type(name) ~= "string" or name == "" then return nil end
    local q = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if M.RESOURCES[q] then return q, M.RESOURCES[q] end
    local by_item -- an item id several profiles share (ash logs: tree + branches): the TOOL source, deterministic;
    -- gather itself falls back to the tool-free one when no usable tool is carried
    for key, p in pairs(M.RESOURCES) do
        for _, a in ipairs(p.aliases or {}) do if a == q then return key, p end end
        if p.item and p.item:lower() == q then
            local better = not by_item or (p.tool and not M.RESOURCES[by_item].tool)
                or ((p.tool ~= nil) == (M.RESOURCES[by_item].tool ~= nil) and key < by_item)
            if better then by_item = key end
        end
    end
    if by_item then return by_item, M.RESOURCES[by_item] end
    local best, bk, bl = nil, nil, 0 -- the longest alias found in the phrase wins ("maple log" -> maple)
    for key, p in pairs(M.RESOURCES) do
        for _, a in ipairs(p.aliases or {}) do
            if #a >= 3 and #a > bl and q:find(a, 1, true) then best, bk, bl = p, key, #a end
        end
    end
    return bk, best
end

-- ------------------------------------------------------------------ category words (from game identifiers)
-- "ore", "rock", "logs", "mining", "wood": a generic word resolves to every profile whose GAME identifiers
-- carry it, with no word list here: the tokens come from each profile's drop item id
-- (ITEM_Resources_CopperOre -> resources, copper, ore), its actor classes and match patterns (OreNode_Copper,
-- DestructibleMiningRock, FellableTree, SplittableTreeLog -> ore, node, mining, rock, tree, log ...), its
-- tool category (weapons_data cat) and its mode. Plurals fold to the singular ("logs" -> "log").
local function singular(w)
    if #w > 3 and w:sub(-3) == "ies" then return w:sub(1, -4) .. "y" end
    if #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then return w:sub(1, -2) end
    return w
end
M.singular = singular

local function tokens_of(id, out)
    if type(id) ~= "string" then return end
    local s = id:gsub("%^", ""):gsub("[%%%.%*%+%-%?%[%]%(%)]", " ")
    s = s:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2"):gsub("[_/]", " ")
    for w in s:gmatch("%a+") do
        w = singular(w:lower())
        if #w >= 3 and w ~= "item" and w ~= "c" then out[w] = true end
    end
end

local INDEX
function M.category_index()
    if INDEX then return INDEX end
    INDEX = {}
    for key, p in pairs(M.RESOURCES) do
        local t = {}
        tokens_of(p.item, t)
        tokens_of(p.tool, t)
        tokens_of(p.mode, t)
        for _, st in ipairs({ p.root or {}, table.unpack(p.children or {}) }) do
            tokens_of(st.class, t)
            tokens_of(st.match, t)
        end
        tokens_of(key, t)
        INDEX[key] = t
    end
    return INDEX
end

-- word -> {key, ...} of every profile whose game identifiers carry it (sorted for stability).
function M.category(word)
    if type(word) ~= "string" or word == "" then return {} end
    local idx = M.category_index()
    local wants = {}
    for w in word:lower():gmatch("%a+") do wants[#wants + 1] = singular(w) end
    local out = {}
    for key, t in pairs(idx) do
        local all = #wants > 0
        for _, w in ipairs(wants) do if not t[w] then all = false end end
        if all then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

return M
