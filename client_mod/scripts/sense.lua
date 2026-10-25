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

-- Survival stats on the pawn: {sustenance={cur,max}, hydration=..., endurance=...}.
M.SURVIVAL = {
    { key = "sustenance", comp = "SustenanceComponent", cur = "GetCurrentSustenance", max = "GetMaxSustenance" },
    { key = "hydration", comp = "HydrationComponent", cur = "GetCurrentHydration", max = "GetMaxHydration" },
    { key = "endurance", comp = "EnduranceComponent", cur = "GetCurrentEndurance", max = "GetMaxEndurance" },
}
function M.survival(p)
    local out = {}
    for _, s in ipairs(M.SURVIVAL) do
        local c = U.try(function() return p[s.comp] end)
        if U.valid(c) then
            out[s.key] = { r1(num(U.try(function() return c[s.cur](c) end))), r1(num(U.try(function() return c[s.max](c) end))) }
        end
    end
    return out
end

-- The effect thresholds of each survival stat: {key = {{value, effects = {GE names}}, ...}}.
function M.survival_levels(p)
    p = p or M.local_pawn()
    local out = {}
    for _, s in ipairs(M.SURVIVAL) do
        local c = p and U.try(function() return p[s.comp] end)
        local field = s.key:sub(1, 1):upper() .. s.key:sub(2) .. "EffectLevels"
        local levels = {}
        pcall(function()
            c[field]:ForEach(function(_, e)
                local lv = e:get()
                local l = { value = num(U.try(function() return lv.Value end)), effects = {} }
                pcall(function()
                    lv.GameplayEffectsToApply:ForEach(function(_, g)
                        local spec = g:get()
                        l.effects[#l.effects + 1] = U.short(U.try(function() return spec.Effect end)) or "?"
                    end)
                end)
                levels[#levels + 1] = l
            end)
        end)
        out[s.key] = levels
    end
    return out
end

-- Own state: position, health, stamina, survival, skills (levels + xp), total level.
function M.me(log)
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end -- no reads during world changes
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
        d.survival = M.survival(p)
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

M.gate = gate -- {tool = "Hatchet"|"Pickaxe", tool_tag, tier} of a resource actor (or a class default object)

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

-- In-game clock and the sleep window, from the game (DISCOVERIES "Night skip and sleep": both read fine
-- live on the server; UInGameTimeFunctionLibrary is static, PlayerRestComponent is the pawn's):
--   hour        GetInGameTime(ctx).Ticks / 3.6e10, modulo 24 (FTimespan ticks = 100 ns)
--   is_night    IsNighttime(ctx)
--   phase       "night" | "day" from is_night (dusk/dawn times are not readable: GetTimeOfDusk/Dawn
--               returned nothing, so no dusk/dawn phase is claimed)
--   sleep_allowed  PlayerRestComponent:IsInTimeframeForSleep() (the game's own check)
-- Read-only; nil fields when a read fails. UNVERIFIED on the client until a live read.
M.TIME_LIB = "/Script/Dominion.Default__InGameTimeFunctionLibrary"
function M.time_of_day(pawn)
    if rawget(_G, "DW_PAUSE") then return nil end
    pawn = pawn or M.local_pawn()
    if not U.valid(pawn) then return nil end
    local lib = U.try(StaticFindObject, M.TIME_LIB)
    local out = {}
    if U.valid(lib) then
        local night = U.try(function() return lib:IsNighttime(pawn) end)
        if type(night) == "boolean" then out.is_night, out.phase = night, night and "night" or "day" end
        local ts = U.try(function() return lib:GetInGameTime(pawn) end)
        local ticks = ts and num(U.try(function() return ts.Ticks end))
        if ticks then out.hour = math.floor((ticks / 3.6e10) % 24 * 10 + 0.5) / 10 end
    end
    local rc = U.try(function() return pawn.PlayerRestComponent end)
    if U.valid(rc) then
        local ok = U.try(function() return rc:IsInTimeframeForSleep() end)
        if type(ok) == "boolean" then out.sleep_allowed = ok end
        local zz = U.try(function() return rc.IsSleeping end)
        if type(zz) == "boolean" then out.sleeping = zz end
        local area = U.try(function() return rc.CurrentRestingAreaActor end)
        if U.valid(area) then out.resting_in = U.short(area) end -- lying in a bed/shelter (movement disabled)
    end
    return next(out) and out or nil
end

-- inventory.lua's consumable_kind (food | drink | potion by the item DATA CLASS), loaded lazily: loading
-- inventory.lua has no side effects beyond its own _G state table.
local INV
local function consumable_kind(data)
    if INV == nil then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/inventory.lua"))() end)
        INV = ok and m or false
    end
    return INV and INV.consumable_kind and U.try(function() return INV.consumable_kind(data) end) or nil
end

local function describe_item(a, origin)
    local d = base(a, origin)
    local data = U.try(function() return a.ItemData end)
    d.name, d.item = item_name(data) or clean_class(d.class), item_id(data)
    d.consumable = consumable_kind(data) -- perception: "Pumpkin Spice Infusion (drink)"
    -- who dropped it (AWorldItem.NameOfPlayerCharacterThatDroppedItem, an FString; empty for loot) and how
    -- long it has been seen lying there (first sight per actor, kept in _G across reloads)
    local by = text(U.try(function() return a.NameOfPlayerCharacterThatDroppedItem end))
    if by then d.dropped_by = by end
    local seen = rawget(_G, "DWSeenItems") or {}
    _G.DWSeenItems = seen
    if d.id then
        seen[d.id] = seen[d.id] or os.time()
        d.seen_s = os.time() - seen[d.id]
    end
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
    -- position = the interaction component's own location when it has one (where the game's detector
    -- aims), not the actor origin (a tent's origin is under its roof: live 20:46)
    local v = ic and U.try(function() return ic:K2_GetComponentLocation() end)
    local okv, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if okv and type(x) == "number" then
        d.actor_position = d.position
        d.position = U.to_wire({ X = x, Y = y, Z = z })
        if origin then d.distance = U.cm_to_m(U.dist(origin, { X = x, Y = y, Z = z })) end
    end
    d.kind = kind or "interactable"
    d.prompt = ic and text(U.try(function() return ic.InteractionPrompt end)) or nil
    d.name = text(U.try(function() return a.DisplayName end))
        or text(U.try(function() return a.DisplayNameText end)) or clean_class(d.class)
    -- ownership (BUGS L10): a summoned shelter's caster (AUtilitySpell:GetCaster(), DISCOVERIES "Lodestones /
    -- night skip"), a bed's claimant (UBedComponent:GetClaimingCharacterName); UNVERIFIED on the client
    local caster = U.try(function() return a:GetCaster() end)
    if U.valid(caster) then d.owner = U.player_name(caster) or U.short(caster) end
    local bed = U.try(function() return a.BedComponent end) or U.try(function() return a.Bed end)
    if U.valid(bed) then
        local who = text(U.try(function() return bed:GetClaimingCharacterName() end))
        if who then d.claimed_by = who end
    end
    return d
end

-- ------------------------------------------------------------------ foliage (standing trees, bushes, pickups)
-- Why the census could not see STANDING trees (gather agent, live probe 2026-10-25): trees, saplings,
-- bushes, branches and stones are instances of UInteractableFoliageISMComponent (198 components
-- on Claude's client: BP_InteractableFoliageISMC_Tree_C / _PickUps_C / _Sapling_C). The SERVER turns
-- an instance into a real actor only on demand: the player pawn's NearbyFoliageConverterComponent
-- (Range 300 cm, damageable + interactable) and the swing's own trace (ConvertTracedFoliage). So a
-- tree further than ~3 m from every player is foliage, not an actor, and FindAllOf can't see it.
-- Read-only scan, no struct out-params:
--   GetInstancesOverlappingSphere(center, r, true) -> instance indices (UE4SS: a Lua table of
--   RemoteUnrealParam ints, :get()); position = component location + rotation * (scale *
--   PerInstanceSMData[i].Transform.WPlane) (the reflected FMatrix's translation row).
-- Row: {id = "fol:<component>:<index>", kind = "foliage", foliage = "tree"|"pickup"|"sapling"|...,
--       class = the actor class an instance converts into (ActorClass, e.g. BP_BM_Tree_Oak_01_C),
--       name, position, distance, damageable, interactable, verb, tool, tool_tier, health, max_health}
-- The class facts (DisplayName, tool gate, HP) come from the actor class's default object, cached.
local FOLIAGE_KIND = { Tree = "tree", PickUps = "pickup", Sapling = "sapling" }
local class_facts = {}
local function facts_of(cls)
    local key = U.short(cls)
    if not key then return {} end
    if class_facts[key] then return class_facts[key] end
    local f = { class = key }
    local cdo = U.try(function() return cls:GetCDO() end)
    if U.valid(cdo) then
        f.name = text(U.try(function() return cdo.DisplayName end))
        if f.name and f.name:upper():find("DEFAULT DISPLAY NAME", 1, true) then f.name = nil end -- placeholder on spawners
        local data = U.try(function() return cdo.ItemData end) -- ground resources: the item they give
        if U.valid(data) then f.item, f.name = item_id(data), f.name or item_name(data) end
        local g = gate(cdo)
        if g then f.tool, f.tool_tier = g.tool, g.tier end
        f.max_health = num(U.try(function() return cdo.HealthComponent.MaxHealth end))
        if f.max_health and f.max_health <= 0 then f.max_health = nil end
    end
    f.name = f.name or clean_class(key)
    class_facts[key] = f
    return f
end
M.foliage_facts = facts_of

local function rotate_yaw(v, deg)
    if not deg or deg == 0 then return v end
    local r = math.rad(deg)
    local c, s = math.cos(r), math.sin(r)
    return { X = v.X * c - v.Y * s, Y = v.X * s + v.Y * c, Z = v.Z }
end

-- foliage(origin_cm, radius_cm, {match = pattern on the class, exclude = pattern|{patterns},
--   kinds = {tree=true,...}, max = n}) -> rows nearest first (positions in cm under _pos).
function M.foliage(origin, radius_cm, opts)
    opts = opts or {}
    local out = {}
    if not origin then return out end
    local excl = opts.exclude
    if type(excl) == "string" then excl = { excl } end
    for _, c in ipairs(U.find_all("InteractableFoliageISMComponent", { skip_defaults = true })) do
        local cls = U.try(function() return c.ActorClass end)
        local cname = U.short(cls) or "?"
        local fk = FOLIAGE_KIND[((U.class_word(c) or ""):match("ISMC_([%w]+)_C$")) or ""] or "foliage"
        local ok_cls = (not opts.match or cname:find(opts.match)) and (not opts.kinds or opts.kinds[fk])
        for _, e in ipairs(excl or {}) do if cname:find(e) then ok_cls = false end end
        if ok_cls then
            local idxs = U.try(function() return c:GetInstancesOverlappingSphere({ X = origin.X, Y = origin.Y, Z = origin.Z }, radius_cm, true) end)
            if type(idxs) == "table" and #idxs > 0 then
                local cl = U.try(function() local v = c:K2_GetComponentLocation(); return { X = v.X, Y = v.Y, Z = v.Z } end)
                local yaw = num(U.try(function() return c:K2_GetComponentRotation().Yaw end)) or 0
                local sc = U.try(function() local s = c:K2_GetComponentScale(); return { X = s.X, Y = s.Y, Z = s.Z } end) or { X = 1, Y = 1, Z = 1 }
                local facts
                for _, e in ipairs(idxs) do
                    local i = type(e) == "number" and e or U.try(function() return e:get() end)
                    local w = type(i) == "number" and cl and U.try(function()
                        local m = c.PerInstanceSMData[i + 1].Transform
                        local t, x = m.WPlane, m.XPlane
                        return { X = t.X, Y = t.Y, Z = t.Z, s = math.sqrt(x.X * x.X + x.Y * x.Y + x.Z * x.Z) }
                    end)
                    if w and w.s > 0.01 then -- a zero-scale instance is hidden (converted / felled)
                        local p = rotate_yaw({ X = w.X * sc.X, Y = w.Y * sc.Y, Z = w.Z * sc.Z }, yaw)
                        p = { X = cl.X + p.X, Y = cl.Y + p.Y, Z = cl.Z + p.Z }
                        local d = U.dist2d(origin, p)
                        if d <= radius_cm then
                            facts = facts or facts_of(cls)
                            out[#out + 1] = { id = "fol:" .. (U.short(c) or "?") .. ":" .. i, kind = "foliage", foliage = fk,
                                class = cname, name = facts.name, position = U.to_wire(p), distance = U.cm_to_m(d), _pos = p,
                                _comp = c, _index = i, damageable = U.try(function() return c.bDamageable end) == true or nil,
                                interactable = U.try(function() return c.bInteractable end) == true or nil,
                                tool = facts.tool, tool_tier = facts.tool_tier, health = facts.max_health, max_health = facts.max_health, item = facts.item,
                                verb = (facts.tool == "Hatchet" and "chop") or (facts.tool == "Pickaxe" and "mine") or (fk == "pickup" and "gather") or "hit" }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
    if opts.max then for i = #out, opts.max + 1, -1 do out[i] = nil end end
    return out
end

-- ------------------------------------------------------------------ census
local function owner_of(c) local o = U.try(function() return c:GetOwner() end); return U.alive(o) and o or nil end

-- census(log, {radius_m=30, max=25, kinds={players=true,...}}) -> {origin, players, creatures,
-- items, resources, interactables, totals, ms}. Each list nearest first, capped at `max`.
function M.census(log, opts)
    opts = opts or {}
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
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
    -- standing trees / bushes / pickups still drawn as foliage (see M.foliage); opts.foliage=false skips
    if (not want or want.resources) and opts.foliage ~= false then
        -- trees and pickups capped separately (a third of the rows each), so ground stones and branches
        -- (they lie everywhere) don't crowd out the trees or the actors
        for _, kind in ipairs({ "tree", "pickup" }) do
            local ok, rows = pcall(M.foliage, origin, r_cm, { max = math.max(math.ceil(max / 3), 1), kinds = { [kind] = true } })
            if ok then
                for _, r in ipairs(rows) do
                    r._comp, r._index, r._pos = nil, nil, nil
                    add("resources", r)
                end
            elseif log then log("sense: foliage " .. tostring(rows)) end
        end
    end

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

-- ------------------------------------------------------------------ vitals watcher
-- Logs to <ROOT>/client_io/events/vitals.jsonl:
--   {"type":"health", hp, prev, delta, max, source="rep"|"poll"}   every change of his health
--     (post-hook HealthComponent:OnRep_AuthoritativeHealth = the replicated value arriving, plus a
--     1 s poll as a fallback);
--   {"type":"damage", amount, absorbed, class, fatal, status, types, instigator, source}  each
--     damage event the server multicasts for his pawn (DamageComponent:Multicast_Apply[Point]DamageFromGameplayEffect);
--   {"type":"fatal", killed_by, text, power_level, status_flags, status}  (DamageComponent:OnRep_FatalDamageInfo);
--   {"type":"death"} / {"type":"revive"} on IsDead transitions;
--   {"type":"survival", sustenance, hydration, endurance, hp}  every M.VITALS_SURVIVAL_S seconds.
-- Read-only (hooks read params, nothing is written). Hot-reload safe: state in _G.DWVitals,
-- hooks registered once and dispatching to the newest handlers.
M.VITALS_PATH = ROOT .. "/client_io/events/vitals.jsonl"
M.VITALS_SURVIVAL_S = 30
local DAMAGE_CLASS = { [0] = "none", "melee", "magical", "ranged" }
local STATUS = { [0] = "none", "poison", "burning", "bleeding", "shock", "starvation", "dehydration", "toxicity", "scorch" }
M.STATUS = STATUS

local V = _G.DWVitals or { hooks = {}, counts = { health = 0, damage = 0, fatal = 0, survival = 0 } }
_G.DWVitals = V

local json_mod
local function emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    ev.ts = os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local line = U.try(function() return json_mod.encode(ev) end)
    if not line then return end
    local f = io.open(M.VITALS_PATH, "a")
    if f then f:write(line, "\n"); f:close() end
end
M.vitals_emit = emit

-- KilledByStatusEffectFlags is a bitmask over EStatusEffectType (bit n = type n): 64 = dehydration.
local function status_names(flags)
    if not flags or flags == 0 then return nil end
    local out = {}
    for i = 1, 8 do if (flags >> i) & 1 == 1 then out[#out + 1] = STATUS[i] end end
    return out
end
M.status_names = status_names

local function who(a)
    if not U.valid(a) then return nil end
    local d = { id = U.short(a), class = U.class_word(a) }
    if U.short(a) == V.me_id then d.self = true end
    local ps = U.try(function() return a.PlayerState end)
    if U.valid(ps) then d.player = U.str(U.try(function() return ps:GetPlayerName() end)) end
    local data = U.try(function() return a.LoadedData end)
    if U.valid(data) then d.name = text(U.try(function() return data.AIName end)) end
    return d
end

local function is_mine(comp)
    local o = U.try(function() return comp:GetOwner() end)
    return o ~= nil and U.short(o) == V.me_id
end

local function read_damage(e)
    local d = {
        amount = r1(num(U.try(function() return e.Amount end))),
        absorbed = r1(num(U.try(function() return e.AmountAbsorbedByShield end))),
        fatal = U.try(function() return e.bIsFatalHit end) == true or nil,
        instigator = who(U.try(function() return e.Instigator end)),
    }
    local cls = num(U.try(function() return e.DamageClass end))
    d.class = cls and DAMAGE_CLASS[cls] or nil
    local src = U.try(function() return e.Source end)
    if U.valid(src) then d.source = { id = U.short(src), class = U.class_word(src) } end
    local types, status = {}, {}
    pcall(function()
        e.TypeDamagesArray.TypeDamages:ForEach(function(_, t)
            local td = t:get()
            local se = num(U.try(function() return td.StatusEffect end))
            if se and se > 0 then status[#status + 1] = STATUS[se] end
            pcall(function()
                td.Types.GameplayTags:ForEach(function(_, g)
                    local n = U.str(U.try(function() return g:get().TagName end))
                    if n then types[#types + 1] = n end
                end)
            end)
        end)
    end)
    if #types > 0 then d.types = types end
    if #status > 0 then d.status = status end
    return d
end

function V.on_health(ctx, prev)
    local c = ctx:get()
    if not is_mine(c) then return end
    local hp = num(U.try(function() return c:GetAuthoritativeHealth() end))
    local pv = num(U.try(function() return prev:get() end))
    if hp == nil or hp == V.last_hp then return end
    local before = pv or V.last_hp or hp
    emit({ type = "health", source = "rep", hp = r1(hp), prev = r1(before), delta = r1(hp - before),
           max = r1(num(U.try(function() return c:GetMaxHealth() end))) })
    V.last_hp = hp
    V.counts.health = V.counts.health + 1
end

function V.on_damage(ctx, ev)
    local c = ctx:get()
    if not is_mine(c) then return end
    local d = read_damage(ev:get())
    d.type = "damage"
    d.hp = r1(num(U.health(M.local_pawn())))
    emit(d)
    V.counts.damage = V.counts.damage + 1
end

function V.on_fatal(ctx)
    local c = ctx:get()
    if not is_mine(c) then return end
    local f = U.try(function() return c.FatalDamageInfo end)
    local flags = num(U.try(function() return f.KilledByStatusEffectFlags end))
    emit({ type = "fatal", set = U.try(function() return f.bIsSet end), killed_by = who(U.try(function() return f.KilledBy:Get() end)),
           text = text(U.try(function() return f.KilledByText end)), power_level = num(U.try(function() return f.KilledByPowerLevel end)),
           status_flags = flags, status = status_names(flags) })
    V.counts.fatal = V.counts.fatal + 1
end

M.VITALS_HOOKS = {
    { path = "/Script/Dominion.HealthComponent:OnRep_AuthoritativeHealth", handler = "on_health" },
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyPointDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.DamageComponent:OnRep_FatalDamageInfo", handler = "on_fatal" },
}

local function register(h, log)
    if V.hooks[h.path] then return true end
    local ok, pre, post = pcall(RegisterHook, h.path, function() end, function(...)
        local fn = V[h.handler]
        if fn then
            local ok2, err = pcall(fn, ...)
            if not ok2 and log then pcall(log, "vitals hook " .. h.handler .. " error: " .. tostring(err)) end
        end
    end)
    if ok then V.hooks[h.path] = { pre = pre, post = post } end
    if log then pcall(log, "vitals hook " .. h.path .. " ok=" .. tostring(ok) .. (ok and "" or (" " .. tostring(pre)))) end
    return ok
end

local function poll()
    if _G.DW_PAUSE then return end -- set by disconnect/travel commands: no UObject access during teardown
    local p = M.local_pawn()
    if not p then return end
    V.me_id = U.short(p)
    local hp = num(U.health(p))
    if hp and V.last_hp and hp ~= V.last_hp then
        emit({ type = "health", source = "poll", hp = r1(hp), prev = r1(V.last_hp), delta = r1(hp - V.last_hp), max = r1(max_hp(p)) })
        V.counts.health = V.counts.health + 1
    end
    if hp then V.last_hp = hp end
    local dead = U.try(function() return p.HealthComponent:IsDead() end) == true
    if V.dead ~= nil and dead ~= V.dead then emit({ type = dead and "death" or "revive", hp = r1(hp), survival = M.survival(p) }) end
    V.dead = dead
    local t = os.time()
    if not V.last_survival or t - V.last_survival >= M.VITALS_SURVIVAL_S then
        V.last_survival = t
        local s = M.survival(p)
        emit({ type = "survival", hp = r1(hp), max_hp = r1(max_hp(p)), sustenance = s.sustenance, hydration = s.hydration, endurance = s.endurance })
        V.counts.survival = V.counts.survival + 1
    end
end
V.poll = poll

-- Start (idempotent): hooks + a 1 s game-thread poll. Returns {ok, data}.
function M.vitals_start(log)
    os.execute('mkdir "' .. (ROOT .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
    local p = M.local_pawn()
    V.me_id = p and U.short(p) or V.me_id
    V.last_hp = p and num(U.health(p)) or V.last_hp
    -- Hooks registered at the main menu (client boot) or for an earlier pawn never delivered a damage
    -- row (vitals.jsonl: damage rows only from the 17:53 in-world start; none after the boot-time starts
    -- at 19:29/19:33/19:38 although he took 36 damage at 19:43:53). So once a pawn exists, hooks from
    -- another pawn (or none) are dropped and registered again; the bridge's supervisor calls this again
    -- when vitals_status().hooked_pawn differs from the current pawn. (Re-registering is the fix being
    -- tried; UNVERIFIED until a damage row appears after a boot.)
    local me = p and U.short(p) or nil
    if me and V.hooked_pawn ~= me and next(V.hooks) then
        for path, ids in pairs(V.hooks) do
            if UnregisterHook then pcall(UnregisterHook, path, ids.pre, ids.post) end
            V.hooks[path] = nil
        end
        if log then pcall(log, "vitals: hooks re-registered for pawn " .. me .. " (were for " .. tostring(V.hooked_pawn) .. ")") end
    end
    local hooks = {}
    for _, h in ipairs(M.VITALS_HOOKS) do hooks[h.path:match(":(.+)$")] = register(h, log) end
    if me then V.hooked_pawn = me end
    if not V.loop then
        V.loop = LoopInGameThreadWithDelay(1000, function()
            local f = _G.DWVitals and _G.DWVitals.poll
            if f then pcall(f) end
        end)
    end
    emit({ type = "start", hp = r1(V.last_hp), survival = p and M.survival(p) or nil })
    return { ok = true, data = { hooks = hooks, path = M.VITALS_PATH, counts = V.counts } }
end

function M.vitals_stop(log)
    if V.loop and CancelDelayedAction then pcall(CancelDelayedAction, V.loop) end
    V.loop = nil
    for path, ids in pairs(V.hooks) do
        if UnregisterHook then pcall(UnregisterHook, path, ids.pre, ids.post) end
        V.hooks[path] = nil
    end
    return { ok = true }
end

function M.vitals_status()
    local n = 0
    for _ in pairs(V.hooks) do n = n + 1 end
    return { running = V.loop ~= nil, hooks = n, counts = V.counts, last_hp = V.last_hp, me = V.me_id, dead = V.dead,
             hooked_pawn = V.hooked_pawn }
end

return M
