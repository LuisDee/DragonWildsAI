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
        item = WOOD .. species, aliases = aliases, mode = "chop", tool = "axe", min_tier = min_tier,
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

local function rock(match, item, aliases, verified)
    return {
        item = item, aliases = aliases, mode = "chop", tool = "pickaxe", min_tier = 1,
        root = { class = "DestructibleMiningRock", match = match, attack = "primary", reach_cm = 150 },
        children = {}, site_radius_cm = 600, collect_radius_cm = 900, verified = verified,
    }
end

local function pickup(match, item, aliases, verified)
    return {
        item = item, aliases = aliases, mode = "pickup",
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
    stone_rock = rock("OreNode_Stone", "ITEM_Resources_Stone", { "stone_rock", "rock", "rocks", "boulder", "mine stone" },
                      { actor = true, gate = true }),
    rune_essence = rock("RuneEssence", "ITEM_Rune_Essence", { "rune_essence", "rune essence", "essence" }, { actor = true, gate = true }),
    copper = rock("OreNode_Copper", "ITEM_Resources_CopperOre", { "copper", "copper_ore", "copper ore" }, false),
    tin = rock("OreNode_Tin", "ITEM_Resources_TinOre", { "tin", "tin_ore", "tin ore" }, false),
    iron = rock("OreNode_Iron", "ITEM_Resources_IronOre", { "iron", "iron_ore", "iron ore" }, false),
    coal = rock("OreNode_Coal", "ITEM_Resources_Coal", { "coal" }, false),
    clay = rock("OreNode_Clay", "ITEM_Resources_Clay", { "clay" }, false),
    -- Ground pickups and bushes (foliage "PickUps" components; the interact key collects them).
    stone = pickup("Spawner_Stone", "ITEM_Resources_Stone", { "stone", "stones", "pebble" }, { foliage = true }),
    sticks = pickup("Spawner_AshBranch", nil, { "stick", "sticks", "branch", "branches", "twig", "twigs" }, { foliage = true }),
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
    for key, p in pairs(M.RESOURCES) do
        for _, a in ipairs(p.aliases or {}) do if a == q then return key, p end end
        if p.item and p.item:lower() == q then return key, p end
    end
    local best, bk, bl = nil, nil, 0 -- the longest alias found in the phrase wins ("maple log" -> maple)
    for key, p in pairs(M.RESOURCES) do
        for _, a in ipairs(p.aliases or {}) do
            if #a >= 3 and #a > bl and q:find(a, 1, true) then best, bk, bl = p, key, #a end
        end
    end
    return bk, best
end

return M
