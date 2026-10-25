-- sense: what Claude's own CLIENT perceives (route R2). Read-only: property reads and BlueprintPure
-- getters on replicated actors, nothing that changes game state, no foliage conversion.
--
-- Generic by design (CLAUDE.md principle 2): entities are found through the game's own base
-- classes and component families (dump 26161880, client build 26162923), never item lists:
--   players       DominionPlayerCharacter (minus the local pawn), name from the PlayerState
--   creatures     DominionAICharacter: LoadedData.AIName, HealthComponent, LoadedData.Archetype
--                 (Aggressive=hostile, Defensive/NeutralUntilAttacked=neutral, Passive/Bird=passive),
--                 CurrentAlertnessState (COMBAT=4), PowerLevel, bIsBoss
--   items         WorldItem (dropped loot): ItemData.Name, GetStackSize()
--   resources     DestructibleWorldActor (trees, logs, stumps, rocks), OreNode, BaseInteractableResource
--                 (ground gatherables): HP, tool gate (DamageModifier RequiredCategory / RequiredTier),
--                 first drop's item name
--   interactables owners of an InteractionComponent not already listed, typed by component family
--                 (CraftingStation, ProcessingStation, EnchantingStation, RestingArea=bed, Lodestone,
--                 Container, Inventory=storage) or actor family (WorldChest); name from AWorldActor.DisplayName
-- Ported from the server-side mod/body/sense.lua look() (ideas, not code calls). Helpers are the
-- shared, dependency-free mod/body/util.lua (reused as-is).
--
-- Units: positions/distances on the wire are METRES (util.to_wire / cm_to_m).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.DEFAULT_RADIUS_M = 30
M.DEFAULT_MAX = 25 -- per category

local ARCHETYPE = { [0] = "hostile", [1] = "neutral", [2] = "passive", [3] = "passive", [4] = "neutral" }
local ARCHETYPE_NAME = { [0] = "Aggressive", [1] = "Defensive", [2] = "Passive", [3] = "Bird", [4] = "NeutralUntilAttacked" }
local ALERTNESS = { [0] = "ambient", [1] = "to_suspicious", [2] = "suspicious", [3] = "to_combat", [4] = "combat",
                    [5] = "lost_target", [6] = "to_ambient" }

-- Component family -> interactable kind (owner actors of these components).
M.FAMILIES = {
    { class = "CraftingStationComponent", kind = "crafting_station" },
    { class = "ProcessingStationComponent", kind = "processing_station" },
    { class = "EnchantingStationComponent", kind = "enchanting_station" },
    { class = "RestingAreaComponent", kind = "bed" },
    { class = "LodestoneComponent", kind = "lodestone" },
    { class = "ContainerComponent", kind = "container" },
    { class = "InventoryComponent", kind = "storage" }, -- crates/chests (after stations, which also own one)
}
M.ACTOR_FAMILIES = { { class = "WorldChest", kind = "chest" }, { class = "WorldLodestone", kind = "lodestone" } }

local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end
local function r1(x) return x and math.floor(x * 10 + 0.5) / 10 or nil end

-- Max health: GetMaxHealth() first (players and many AI keep MaxHealth = 0 and derive it from an
-- attribute), then the MaxHealth property when it is positive.
local function max_hp(a)
    local v = num(U.try(function() return a.HealthComponent:GetMaxHealth() end))
    if v and v > 0 then return v end
    v = num(U.try(function() return a.HealthComponent.MaxHealth end))
    return (v and v > 0) and v or nil
end

local function clean_class(cw)
    if not cw then return "?" end
    local s = cw:gsub("^BP_AI_", ""):gsub("^BP_", ""):gsub("_C$", ""):gsub("_Character$", ""):gsub("_%d+$", "")
    s = s:gsub("(%l)(%u)", "%1 %2")
    return (s:gsub("_", " "))
end
M.clean_class = clean_class

local function item_name(data) return U.valid(data) and text(U.try(function() return data.Name end)) or nil end
local function item_id(data) local p = U.valid(data) and U.path_of(data); return p and p:match("%.([%w_]+)$") or nil end
M.item_name, M.item_id = item_name, item_id

-- ------------------------------------------------------------------ me
function M.local_pc()
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then return pc end
    end
    return nil
end

function M.local_pawn(pc)
    pc = pc or M.local_pc()
    local p = pc and U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end

local function skills(pc)
    local sc = U.try(function() return pc.SkillComponent end)
    if not U.valid(sc) then return nil end
    local out = {}
    pcall(function()
        sc.Skills:ForEach(function(_, e)
            local s = U.try(function() return e:get() end) or e
            local data = U.try(function() return s.SkillData end)
            if U.valid(data) then
                out[#out + 1] = {
                    skill = text(U.try(function() return data.Name end)) or U.short(data),
                    level = num(U.try(function() return sc:GetSkillLevel(data) end)),
                    xp = num(U.try(function() return s.CurrentXP end)),
                }
            end
        end)
    end)
    table.sort(out, function(a, b) return tostring(a.skill) < tostring(b.skill) end)
    return out
end

-- Own state: position, health, stamina, skills (levels + xp), total level.
function M.me(log)
    local pc = M.local_pc()
    if not pc then return { ok = false, reason = "no local player controller" } end
    local p = M.local_pawn(pc)
    local d = { ok = true, name = U.player_name(p) or nil, pawn = U.short(p) }
    if p then
        local at = U.loc(p)
        d.position = U.to_wire(at)
        d.health, d.max_health = r1(num(U.health(p))), r1(max_hp(p))
        local st = U.try(function() return p.StaminaComponent end)
        if U.valid(st) then
            d.stamina = r1(num(U.try(function() return st:GetStamina() end)))
            d.max_stamina = r1(num(U.try(function() return st:GetMaxStamina() end)))
            d.exhausted = U.try(function() return st:IsExhausted() end)
        end
        d.dead = U.try(function() return p.HealthComponent:IsDead() end)
        local rot = U.try(function() return p:K2_GetActorRotation() end)
        d.yaw = rot and r1(rot.Yaw) or nil
    end
    d.skills = skills(pc)
    d.total_level = num(U.try(function() return pc.SkillComponent:GetTotalSkillLevel() end))
    return d
end

-- ------------------------------------------------------------------ describers
local function gate(a)
    local g
    local function scan(arr)
        if g or arr == nil then return end
        pcall(function()
            arr:ForEach(function(_, e)
                local m = U.try(function() return e:get() end) or e
                local tag = U.str(U.try(function() return m.RequiredCategory.TagName end)) or ""
                if tag ~= "" and tag ~= "None" then
                    g = { tool = tag:match("([%w]+)$"), tool_tag = tag, tier = num(U.try(function() return m.RequiredTier end)) }
                    return true
                end
            end)
        end)
    end
    if not U.try(function() return a.bIsStump end) then scan(U.try(function() return a.DamageModifiersWhenTree end)) end
    scan(U.try(function() return a.DamageComponent.DamageModifiers end))
    return g
end

local function first_drop(comp)
    if not U.valid(comp) then return nil end
    local name, id
    pcall(function()
        comp.ItemsToDrop:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            local sp = U.try(function() return d.ItemDataClass end)
            local obj = U.try(function() return sp:Get() end)
            if U.valid(obj) then name, id = item_name(obj), item_id(obj)
            else
                local path = U.str(U.try(function() return sp:GetObjectID():GetAssetPathName() end))
                id = path and path:match("%.([%w_]+)$")
            end
            return true
        end)
    end)
    return name, id
end

local function base(a, origin)
    local at = U.loc(a)
    return { id = U.short(a), class = U.class_word(a), position = U.to_wire(at),
             distance = origin and U.cm_to_m(U.dist(origin, at)) or nil }, at
end

local function describe_player(a, origin)
    local d = base(a, origin)
    d.name = U.player_name(a)
    d.health, d.max_health = r1(num(U.health(a))), r1(max_hp(a))
    local held = U.try(function() return a.PlayerEquipmentComponent:GetHeldEquipmentDataRight() end)
    d.held = item_name(held)
    return d
end

local function tags_of(container, pattern)
    local out = {}
    pcall(function()
        container.GameplayTags:ForEach(function(_, e)
            local t = U.try(function() return e:get() end) or e
            local n = U.str(U.try(function() return t.TagName end))
            if n and (not pattern or n:find(pattern)) then out[#out + 1] = n end
        end)
    end)
    return #out > 0 and out or nil
end

local function describe_creature(a, origin)
    local d = base(a, origin)
    local data = U.try(function() return a.LoadedData end)
    d.name = (U.valid(data) and text(U.try(function() return data.AIName end))) or clean_class(d.class)
    d.health, d.max_health = r1(num(U.health(a))), r1(max_hp(a))
    d.dead = U.try(function() return a.HealthComponent:IsDead() end) or (d.health ~= nil and d.health <= 0) or nil
    local arch = U.valid(data) and num(U.try(function() return data.Archetype end))
    d.attitude, d.archetype = arch and ARCHETYPE[arch] or nil, arch and ARCHETYPE_NAME[arch] or nil
    local al = num(U.try(function() return a.CurrentAlertnessState end))
    d.alertness = al and ALERTNESS[al] or nil
    d.in_combat = al == 3 or al == 4 or nil
    d.power_level = num(U.try(function() return a.PowerLevel end))
    d.boss = (U.valid(data) and U.try(function() return data.bIsBoss end) == true) or nil
    d.follower = U.try(function() return a:IsFollower() end) == true or nil
    d.tags = U.valid(data) and tags_of(U.try(function() return data.GameplayTags end), "Faction") or nil
    return d
end

local function describe_item(a, origin)
    local d = base(a, origin)
    local data = U.try(function() return a.ItemData end)
    d.name, d.item = item_name(data) or clean_class(d.class), item_id(data)
    d.count = num(U.try(function() return a:GetStackSize() end))
    local mag = U.try(function() return a.MagneticComponentGrantItem end)
    if U.valid(mag) then
        local tgt = U.try(function() return mag.Target end)
        d.magnet_target = U.valid(tgt) and U.player_name(tgt) or nil
    end
    return d
end

local function describe_resource(a, origin)
    local d = base(a, origin)
    local data = U.try(function() return a.ItemData end)
    if U.valid(data) then -- ground gatherable (BaseInteractableResource)
        d.kind, d.verb = "gatherable", "gather"
        d.name, d.item = item_name(data), item_id(data)
        local avail = U.try(function() return a:IsResourceAvailable() end)
        if avail ~= nil then d.available = avail == true end
    else
        d.kind = "destructible"
        d.health, d.max_health = r1(num(U.health(a))), r1(max_hp(a))
        d.stump = U.try(function() return a.bIsStump end) == true or nil
        d.hidden = U.try(function() return a.bIsHidden end) == true or nil
        local has = U.try(function() return a:HasAvailableResources() end)
        if has ~= nil then d.has_resources = has == true end
        local g = gate(a)
        if g then d.tool, d.tool_tier = g.tool, g.tier end
        d.verb = (d.tool == "Hatchet" and "chop") or (d.tool == "Pickaxe" and "mine") or "hit"
        d.drops, d.drop_item = first_drop(U.try(function() return a.ItemDropOnDestructionComponent end))
        local dn = text(U.try(function() return a.DisplayName end))
        if d.stump then dn = text(U.try(function() return a.StumpDisplayName end)) or dn end
        d.name = dn or (d.drops and (clean_class(d.class) .. " (" .. d.drops .. ")")) or clean_class(d.class)
    end
    return d
end

local function describe_interactable(a, ic, kind, origin)
    local d = base(a, origin)
    d.kind = kind or "interactable"
    d.prompt = ic and text(U.try(function() return ic.InteractionPrompt end)) or nil
    d.name = text(U.try(function() return a.DisplayName end))
        or text(U.try(function() return a.DisplayNameText end)) or clean_class(d.class)
    return d
end

-- ------------------------------------------------------------------ census
local function owner_of(c) local o = U.try(function() return c:GetOwner() end); return U.alive(o) and o or nil end

-- census(log, {radius_m=30, max=25, kinds={players=true,...}}) -> {origin, players, creatures,
-- items, resources, interactables, totals, ms}. Each list nearest first, capped at `max`.
function M.census(log, opts)
    opts = opts or {}
    local t0 = os.clock()
    local pc = M.local_pc()
    local me = M.local_pawn(pc)
    local origin = me and U.loc(me)
    if not origin then return { ok = false, reason = "no local pawn" } end
    local r_cm = (opts.radius_m or M.DEFAULT_RADIUS_M) * 100
    local max = opts.max or M.DEFAULT_MAX
    local want = opts.kinds
    local seen = { [U.short(me) or "?"] = true }
    local out, totals = {}, {}

    local function within(a)
        local at = U.loc(a)
        return at and U.dist(origin, at) <= r_cm
    end
    local function add(cat, d)
        local l = out[cat] or {}
        out[cat] = l
        l[#l + 1] = d
        totals[cat] = (totals[cat] or 0) + 1
    end
    local by_id = {}
    -- Every pass runs (so a filtered-out category still claims its actors and they are not listed
    -- again as plain interactables); only wanted categories are described.
    local function pass(cat, classes, describe)
        local on = not want or want[cat]
        if on then out[cat] = out[cat] or {} end
        for _, cls in ipairs(classes) do
            for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
                local id = U.short(a)
                if id and not seen[id] and within(a) then
                    seen[id] = true
                    if on then
                        local ok, d = pcall(describe, a, origin)
                        if ok and d then add(cat, d); by_id[id] = d
                        elseif not ok and log then log("sense: describe " .. id .. ": " .. tostring(d)) end
                    end
                end
            end
        end
    end

    pass("players", { "DominionPlayerCharacter" }, describe_player)
    pass("creatures", { "DominionAICharacter" }, describe_creature)
    pass("items", { "WorldItem" }, describe_item)
    pass("resources", { "DestructibleWorldActor", "OreNode", "BaseInteractableResource" }, describe_resource)

    local kind_of = {}
    for _, f in ipairs(M.ACTOR_FAMILIES) do
        for _, o in ipairs(U.find_all(f.class, { skip_defaults = true })) do
            local id = U.short(o)
            if id and not kind_of[id] then kind_of[id] = f.kind end
        end
    end
    for _, f in ipairs(M.FAMILIES) do
        for _, c in ipairs(U.find_all(f.class, { skip_defaults = true })) do
            local o = owner_of(c)
            local id = o and U.short(o)
            if id and not kind_of[id] then kind_of[id] = f.kind end
        end
    end
    local on = not want or want.interactables
    if on then out.interactables = out.interactables or {} end
    for _, ic in ipairs(U.find_all("InteractionComponent", { skip_defaults = true })) do
        local a = owner_of(ic)
        local id = a and U.short(a)
        if id and seen[id] and by_id[id] and not by_id[id].prompt then
            -- an already-listed entity that is also interactable (gatherable "Collect", sapling "Uproot")
            by_id[id].prompt = text(U.try(function() return ic.InteractionPrompt end))
        elseif id and not seen[id] and within(a) then
            seen[id] = true
            if on then
                local ok, d = pcall(describe_interactable, a, ic, kind_of[id], origin)
                if ok and d then add("interactables", d) end
            end
        end
    end

    -- Everyone online (PlayerStates are always relevant, pawns only within net relevancy range).
    local online
    if not want or want.players then
        online = {}
        for _, ps in ipairs(U.find_all("PlayerState", { skip_defaults = true })) do
            local n = text(U.try(function() return ps:GetPlayerName() end))
            if n then online[#online + 1] = n end
        end
        table.sort(online)
        totals.players_online = #online
    end

    for cat, l in pairs(out) do
        table.sort(l, function(x, y) return (x.distance or 0) < (y.distance or 0) end)
        for i = #l, max + 1, -1 do l[i] = nil end
    end
    out.players_online = online
    out.ok = true
    out.origin = U.to_wire(origin)
    out.radius_m = r_cm / 100
    out.totals = totals
    out.ms = math.floor((os.clock() - t0) * 1000)
    return out
end

return M
