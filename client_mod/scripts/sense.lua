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
-- L28: never spawn a process on a hot path. A directory is created only if it is really missing
-- (an open-for-append probe), and only once per load (cached).
local DIRS_OK = {}
local function ensure_dir(d)
    d = tostring(d):gsub("\\", "/")
    if DIRS_OK[d] then return end
    local probe = d .. "/.dwclient_probe"
    local f = io.open(probe, "a")
    if f then f:close(); os.remove(probe); DIRS_OK[d] = true; return end
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. d .. '"') end
    DIRS_OK[d] = true
end
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
-- Census reads on actors / Blueprint class defaults go through U.prop (risk register R17: UE4SS's FindProperty
-- cache is keyed by class ADDRESS, and a streamed-out Blueprint class's address gets reused).
local P = U.prop
local function max_hp(a)
    local hc = P(a, "HealthComponent")
    if hc == nil then return nil end
    local v = num(U.try(function() return hc:GetMaxHealth() end))
    if v and v > 0 then return v end
    v = num(U.try(function() return hc.MaxHealth end))
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
-- The server's privileges for him (EPlayerPrivilege: Build = 2, OpenChests = 4, Chat = 8, Owner = 128;
-- PlayerState.PrivilegeComponent:HasPrivilege, read live for Chat, DISCOVERIES l.746). -> true | false | nil (unreadable)
M.PRIVILEGE = { build = 2, open_chests = 4, chat = 8, owner = 128 }
function M.has_privilege(p)
    if rawget(_G, "DW_PAUSE") then return nil end
    local pc = M.local_pc()
    local ps = pc and U.try(function() return pc.PlayerState end)
    local comp = U.valid(ps) and U.try(function() return ps.PrivilegeComponent end)
    if not U.valid(comp) then return nil end
    local v = U.try(function() return comp:HasPrivilege(M.PRIVILEGE[p] or p) end)
    if v == nil then return nil end
    return v == true
end

-- His active skill perks (they unlock automatically by skill level; USkillPerkComponent only has reads):
-- pc.SkillPerkComponent.SkillPerkRuntimeStates[].ActivePerkDatas -> {{name, skill, level, description}}.
-- Property reads only; cached for M.PERKS_TTL_S (perks change only on a level-up); never under pause.
M.PERKS_TTL_S = 60
local perks_cache
function M.perks(now)
    if rawget(_G, "DW_PAUSE") then return perks_cache and perks_cache.list or nil end
    now = now or os.time()
    if perks_cache and now - perks_cache.t < M.PERKS_TTL_S then return perks_cache.list end
    local pc = M.local_pc()
    local comp = pc and U.try(function() return pc.SkillPerkComponent end)
    if not U.valid(comp) then return nil end
    local out, seen = {}, {}
    pcall(function()
        comp.SkillPerkRuntimeStates:ForEach(function(_, e)
            local st = U.try(function() return e:get() end) or e
            local skill_data = U.try(function() return st.AssociatedSkill end)
            local skill = U.valid(skill_data) and text(U.try(function() return skill_data.Name end)) or nil
            pcall(function()
                st.ActivePerkDatas:ForEach(function(_, pe)
                    local d = U.try(function() return pe:get() end) or pe
                    local id = U.valid(d) and U.short(d)
                    if id and not seen[id] then
                        seen[id] = true
                        local info = U.try(function() return d.PerkUnlockInfo end)
                        local sk2 = info and U.try(function() return info.AssociatedSkill end)
                        out[#out + 1] = { name = text(U.try(function() return d.PerkName end)) or id,
                                          skill = skill or (U.valid(sk2) and text(U.try(function() return sk2.Name end))) or nil,
                                          level = num(info and U.try(function() return info.RequiredSkillLevel end)),
                                          description = text(U.try(function() return d.PerkDescription end)) }
                    end
                end)
            end)
        end)
    end)
    -- on a client the runtime states are empty (server-side; live 2026-11-02 00:1xZ: 0 states, so get_state said
    -- perks: [] while Double Jump and Air Dash were unlocked): every loaded perk definition, asked of the component
    -- (IsPerkUnlocked answers on the client: 30 of 202 unlocked, 12 ms)
    if #out == 0 then
        local okf, all = pcall(FindAllOf, "SkillPerkData")
        for _, d in ipairs(okf and type(all) == "table" and all or {}) do
            local nm = U.fullname(d) or ""
            local id = U.valid(d) and not nm:find("Default__", 1, true) and U.short(d)
            if id and not seen[id] and U.try(function() return comp:IsPerkUnlocked(d) end) == true then
                seen[id] = true
                local info = U.try(function() return d.PerkUnlockInfo end)
                local sk = info and U.try(function() return info.AssociatedSkill end)
                out[#out + 1] = { name = text(U.try(function() return d.PerkName end)) or id,
                                  skill = U.valid(sk) and text(U.try(function() return sk.Name end)) or nil,
                                  level = num(info and U.try(function() return info.RequiredSkillLevel end)),
                                  description = text(U.try(function() return d.PerkDescription end)), id = id }
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.skill or "") ~= (b.skill or "") then return (a.skill or "") < (b.skill or "") end
        return (a.level or 0) < (b.level or 0)
    end)
    perks_cache = { t = now, list = out }
    return out
end
function M._reset_perks() perks_cache = nil end

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
    if not P(a, "bIsStump") then scan(P(a, "DamageModifiersWhenTree")) end
    local dc = P(a, "DamageComponent")
    scan(dc ~= nil and U.try(function() return dc.DamageModifiers end) or nil)
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

-- A player's summon: an AI of a class some FollowerDataAsset spawns (FollowerComponent:ToggleFollower, e.g. the
-- Pharaoh's Sceptre's Kalphite "Buddy"). On a client neither IsFollower() nor IsConfused() reads true on it, and the
-- player's .Follower is not replicated (live 2026-11-01 22:10Z, Luis's Buddy), but the loaded data asset names the
-- class: DA.FollowerClass:GetObjectID():GetAssetPathName(). Read from the game's own assets, cached 10 s.
local SUMMON = { t = -99, set = {} }
function M.summon_classes()
    local t = os.clock()
    if t - SUMMON.t < 10 then return SUMMON.set end
    local set = {}
    local ok, list = pcall(FindAllOf, "FollowerDataAsset")
    for _, da in ipairs((ok and type(list) == "table") and list or {}) do
        local p = U.str(U.try(function() return da.FollowerClass:GetObjectID():GetAssetPathName() end))
        local cls = p and p:match("%.([%w_]+)$")
        if cls then set[cls] = true end
    end
    SUMMON.t, SUMMON.set = t, set
    return set
end
function M.is_summon(a)
    local cw = U.class_word(a)
    return cw ~= nil and M.summon_classes()[cw] == true
end

local function describe_creature(a, origin)
    local d = base(a, origin)
    local data = P(a, "LoadedData")
    d.name = (U.valid(data) and text(U.try(function() return data.AIName end))) or clean_class(d.class)
    d.health, d.max_health = r1(num(U.health(a))), r1(max_hp(a))
    local hc = P(a, "HealthComponent")
    d.dead = (hc ~= nil and U.try(function() return hc:IsDead() end)) or (d.health ~= nil and d.health <= 0) or nil
    local arch = U.valid(data) and num(U.try(function() return data.Archetype end))
    d.attitude, d.archetype = arch and ARCHETYPE[arch] or nil, arch and ARCHETYPE_NAME[arch] or nil
    local al = num(P(a, "CurrentAlertnessState"))
    d.alertness = al and ALERTNESS[al] or nil
    d.in_combat = al == 3 or al == 4 or nil
    d.power_level = num(P(a, "PowerLevel"))
    d.boss = (U.valid(data) and U.try(function() return data.bIsBoss end) == true) or nil
    d.follower = U.try(function() return a:IsFollower() end) == true or nil
    if M.is_summon(a) then d.follower, d.summon = true, true end -- a player's summon: never a threat or a target
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
    local data = P(a, "ItemData")
    d.name, d.item = item_name(data) or clean_class(d.class), item_id(data)
    d.consumable = consumable_kind(data) -- perception: "Pumpkin Spice Infusion (drink)"
    -- who dropped it (AWorldItem.NameOfPlayerCharacterThatDroppedItem, an FString; empty for loot) and how
    -- long it has been seen lying there (first sight per actor, kept in _G across reloads)
    local by = text(P(a, "NameOfPlayerCharacterThatDroppedItem"))
    if by then d.dropped_by = by end
    local seen = rawget(_G, "DWSeenItems") or {}
    _G.DWSeenItems = seen
    if d.id then
        seen[d.id] = seen[d.id] or os.time()
        d.seen_s = os.time() - seen[d.id]
    end
    d.count = num(U.try(function() return a:GetStackSize() end))
    local mag = P(a, "MagneticComponentGrantItem")
    if U.valid(mag) then
        local tgt = U.try(function() return mag.Target end)
        d.magnet_target = U.valid(tgt) and U.player_name(tgt) or nil
    end
    return d
end

local function describe_resource(a, origin)
    local d = base(a, origin)
    local data = P(a, "ItemData")
    if U.valid(data) then -- ground gatherable (BaseInteractableResource)
        d.kind, d.verb = "gatherable", "gather"
        d.name, d.item = item_name(data), item_id(data)
        local avail = U.try(function() return a:IsResourceAvailable() end)
        if avail ~= nil then d.available = avail == true end
    else
        d.kind = "destructible"
        d.health, d.max_health = r1(num(U.health(a))), r1(max_hp(a))
        d.stump = P(a, "bIsStump") == true or nil
        d.hidden = P(a, "bIsHidden") == true or nil
        local has = U.try(function() return a:HasAvailableResources() end)
        if has ~= nil then d.has_resources = has == true end
        local g = gate(a)
        if g then d.tool, d.tool_tier = g.tool, g.tier end
        d.verb = (d.tool == "Hatchet" and "chop") or (d.tool == "Pickaxe" and "mine") or "hit"
        d.drops, d.drop_item = first_drop(P(a, "ItemDropOnDestructionComponent"))
        local dn = text(P(a, "DisplayName"))
        if d.stump then dn = text(P(a, "StumpDisplayName")) or dn end
        d.name = dn or (d.drops and (clean_class(d.class) .. " (" .. d.drops .. ")")) or clean_class(d.class)
    end
    return d
end

-- A thing with an extent is as far off as its nearest point, not its middle. A pond is one BP_WaterVolume_C: a box
-- with the actor's origin at its middle, the actor's scale its size in metres (half = scale * 50 cm) and the actor's
-- yaw its turn (live probe 2026-11-17, build 26574459, 3 of 3 volumes: that box gives the engine's own bounds to the
-- cm; 30 x 49 m up to 311 x 191 m). Measured to its middle, the pond whose bank lay a few metres from Zanik stood
-- "84.7 m" off: outside look's 80 m and explore's 40 m of sight, so he was told there was no water with the bank
-- beside him (window s16, runs 031503 and 033022: six explores for water, no find, both trials lost; in three days
-- look about water matched 0 of 9).
M.EXTENT_CLASSES = { "WaterVolume" }
-- the point of a box (middle mid, half sizes ha, hb, hz in cm, turned yaw_deg about Z) nearest to p; p itself inside it
function M.box_nearest(p, mid, ha, hb, hz, yaw_deg)
    local c, s = math.cos(math.rad(yaw_deg or 0)), math.sin(math.rad(yaw_deg or 0))
    local dx, dy = p.X - mid.X, p.Y - mid.Y
    local lx = math.max(-ha, math.min(ha, dx * c + dy * s))
    local ly = math.max(-hb, math.min(hb, dy * c - dx * s))
    return { X = mid.X + lx * c - ly * s, Y = mid.Y + lx * s + ly * c,
             Z = math.max(mid.Z - (hz or 0), math.min(mid.Z + (hz or 0), p.Z or mid.Z)) }
end
-- -> { mid, ha, hb, hz, yaw, turned } for an actor of an extent class; nil for any other, and when its bounds do not
-- read (it is then measured to its middle, as before). The engine's bounds (GetActorBounds, as move.lua reads a
-- door's): as the turned box when the actor's scale and yaw give those same bounds, else the bounds as they are
-- (axis-aligned: never smaller than the thing).
function M.extent_of(a, id)
    id = id or U.short(a)
    local is = false
    for _, w in ipairs(M.EXTENT_CLASSES) do if id and tostring(id):find(w, 1, true) then is = true end end
    if not is then return nil end
    local ok, o, e = pcall(function() local o2, e2 = {}, {}; a:GetActorBounds(false, o2, e2, false); return o2, e2 end)
    if not (ok and type(o) == "table" and type(e) == "table" and tonumber(o.X) and tonumber(o.Y) and tonumber(o.Z)
            and tonumber(e.X) and tonumber(e.Y) and tonumber(e.Z)) then return nil end
    local ext = { mid = { X = o.X, Y = o.Y, Z = o.Z }, ha = e.X, hb = e.Y, hz = e.Z, yaw = 0, turned = false }
    local sc = U.try(function() return a:GetActorScale3D() end)
    local rot = U.try(function() return a:K2_GetActorRotation() end)
    local okn, sx, sy, yaw = pcall(function() return tonumber(sc.X), tonumber(sc.Y), tonumber(rot.Yaw) end)
    if okn and sx and sy and yaw then
        local ha, hb = math.abs(sx) * 50, math.abs(sy) * 50
        local c, s = math.abs(math.cos(math.rad(yaw))), math.abs(math.sin(math.rad(yaw)))
        local tol = 0.02 * math.max(e.X, e.Y) + 10
        if math.abs(ha * c + hb * s - e.X) <= tol and math.abs(ha * s + hb * c - e.Y) <= tol then
            ext.ha, ext.hb, ext.yaw, ext.turned = ha, hb, yaw, true
        end
    end
    return ext
end

M.IC_MAX_OFFSET_CM = 1000 -- an interaction point further than this from its actor is not trusted
local function describe_interactable(a, ic, kind, origin)
    local d = base(a, origin)
    -- position = the interaction component's own location when it has one (where the game's detector
    -- aims), not the actor origin (a tent's origin is under its roof: live 20:46)
    local v = ic and U.try(function() return ic:K2_GetComponentLocation() end)
    local okv, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    -- only when it is plausibly ON the actor: an NPC's interaction component reads ~(0,0,0) (not attached /
    -- not a placed scene component; live 09:25 UTC, the Wise Old Man listed at 1865 m) -> keep the actor origin
    local at = U.loc(a)
    local near = okv and type(x) == "number" and at and U.dist(at, { X = x, Y = y, Z = z }) <= M.IC_MAX_OFFSET_CM
    if near then
        d.actor_position = d.position
        d.position = U.to_wire({ X = x, Y = y, Z = z })
        if origin then d.distance = U.cm_to_m(U.dist(origin, { X = x, Y = y, Z = z })) end
    end
    d.kind = kind or "interactable"
    d.prompt = ic and text(U.try(function() return ic.InteractionPrompt end)) or nil
    -- owners of an InteractionComponent are any class: a WorldChest has no DisplayName, and the
    -- speculative read of it crashed the client through UE4SS's stale property cache (R17)
    -- a building piece (crate, campfire, bench) by the name buildables and get_state.structures use ("Crate",
    -- not the class word "Base Building Crate": co-play 2026-11-01, he didn't know the crates were his)
    local bpd = P(a, "BuildingPieceData")
    local piece = U.valid(bpd) and text(U.try(function() return bpd.DisplayName end)) or nil
    d.name = piece or text(P(a, "DisplayName")) or text(P(a, "DisplayNameText")) or clean_class(d.class)
    -- ownership (BUGS L10): a summoned shelter's caster (AUtilitySpell:GetCaster(), DISCOVERIES "Lodestones /
    -- night skip"), a bed's claimant (UBedComponent:GetClaimingCharacterName); UNVERIFIED on the client
    local caster = U.try(function() return a:GetCaster() end)
    if U.valid(caster) then d.owner = U.player_name(caster) or U.short(caster) end
    local bed = P(a, "BedComponent") or P(a, "Bed")
    if U.valid(bed) then
        local who = text(U.try(function() return bed:GetClaimingCharacterName() end))
        if who then d.claimed_by = who end
    end
    -- whose a crate or chest is, from the game (M.owner_row, below; property reads only)
    if M.owner_row then pcall(M.owner_row, a, d) end
    -- a vault's door teleporter, lever or chest says what state it is in (M.vault_row, below; property reads only)
    if M.vault_row then pcall(M.vault_row, a, d) end -- a failed read adds nothing; the row stands as it was
    return d
end

-- ------------------------------------------------------------------ whose a container is (the game's owner)
-- A crate or chest carries a UOwnershipComponent (dump 26574459: BP_BaseBuilding_Crate / _Chest.OwnershipComponent;
-- Dominion.hpp UOwnershipComponent: OwningPlayerId, OwningCharacterGuid (FDomCharacterGuid, replicated: OnRep_),
-- bIsPrivatelyOwned). The world save holds it per crate (CompanionDev.sav, named world 'base': every crate's actor
-- record carries ClaudeDev's guid E71C5DC1-46F0A55B-69FF52A8-81255DEF). Until this read he had no way to tell whose a
-- crate was (run 20261118-015315-N1-I2: look listed 7 crates and an Ash Chest with no owner). The building pieces
-- themselves keep no owner (build.lua: the ledger marks those). UNVERIFIED live on the client.
-- Row fields: owner = "yours" | the owner's character name | "a character not in the name list" | "nobody";
-- owner_guid (hex, absent for "nobody"); mine = true/false (this character); private = true when it is locked to its
-- owner. Nothing is added when the read fails: never a guess.
local ZERO_GUID = "00000000000000000000000000000000"
local owner_names = {} -- guid hex -> character name (the replicated name list is append-only)
function M.my_char_guid()
    local pc = M.local_pc and M.local_pc()
    return pc and U.guid_hex(U.try(function() return pc.PlayerState.OwnerGuid.CharacterGuid.InnerGuid end)) or nil
end
-- A character's name from its guid, as the chat box resolves a sender (client_mod/scripts/chat.lua resolve_name:
-- GameState DisplayNameComponent.SanitizedCharacterNames, CharacterGuid.InnerGuid -> CharacterName).
function M.char_name(hex)
    if not hex then return nil end
    if owner_names[hex] then return owner_names[hex] end
    local name
    for _, dn in ipairs(U.find_all("DisplayNameComponent", { skip_defaults = true }) or {}) do
        if name then break end
        pcall(function()
            dn.SanitizedCharacterNames:ForEach(function(_, elem)
                if name then return end
                local e = elem:get()
                if U.guid_hex(e.CharacterGuid.InnerGuid) == hex then name = text(U.try(function() return e.CharacterName end)) end
            end)
        end)
    end
    if name then owner_names[hex] = name end
    return name
end
function M.owner_row(a, d)
    local oc = P(a, "OwnershipComponent") -- Blueprint-declared on the crate: R17 guarded read
    if not U.valid(oc) then return end
    local hex = U.guid_hex(U.try(function() return oc.OwningCharacterGuid.InnerGuid end)) -- native class: plain read
    if not hex then return end
    if U.try(function() return oc.bIsPrivatelyOwned end) == true then d.private = true end
    if hex == ZERO_GUID then d.owner, d.mine = "nobody", false; return end
    d.owner_guid = hex
    local me = M.my_char_guid()
    if me == hex then d.owner, d.mine = "yours", true; return end
    if me then d.mine = false end
    d.owner = M.char_name(hex) or "a character not in the name list"
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
-- Row: {id = "fol:<ActorClass>@<x>,<y>,<z>" (decimetres; see M.foliage_id), kind = "foliage", foliage = "tree"|"pickup"|"sapling"|...,
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
        f.name = text(P(cdo, "DisplayName"))
        if f.name and f.name:upper():find("DEFAULT DISPLAY NAME", 1, true) then f.name = nil end -- placeholder on spawners
        local data = P(cdo, "ItemData") -- ground resources: the item they give
        if U.valid(data) then f.item, f.name = item_id(data), f.name or item_name(data) end
        local g = gate(cdo)
        if g then f.tool, f.tool_tier = g.tool, g.tier end
        local hc = P(cdo, "HealthComponent")
        f.max_health = hc ~= nil and num(U.try(function() return hc.MaxHealth end)) or nil
        if f.max_health and f.max_health <= 0 then f.max_health = nil end
    end
    f.name = f.name or clean_class(key)
    class_facts[key] = f
    return f
end
M.foliage_facts = facts_of
M._describe_interactable = function(...) return describe_interactable(...) end

local function rotate_yaw(v, deg)
    if not deg or deg == 0 then return v end
    local r = math.rad(deg)
    local c, s = math.cos(r), math.sin(r)
    return { X = v.X * c - v.Y * s, Y = v.X * s + v.Y * c, Z = v.Z }
end

-- Foliage ids (BUGS L26). An instance index is NOT an identity: ISM/HISM RemoveInstance swap-removes
-- (the last instance takes the freed slot), the instanced-foliage actors of World Partition cells stream
-- in and out (and their component names repeat per cell), and the server converts an instance into an
-- actor when a player comes within 3 m (it then hides the instance). A foliage instance never moves, so
-- its identity is WHAT it turns into plus WHERE it stands: "fol:<ActorClass>@<x>,<y>,<z>" in whole
-- decimetres. M.resolve_foliage maps such an id back to the instance (nearest same-class instance within
-- FOLIAGE_MATCH_CM: survives re-indexing and streaming) or, once converted, to the actor the server made
-- of it (same class within CONVERTED_MATCH_CM, gather.lua's adopt_cm). Every tool resolves through it
-- (client_bridge find_thing: go_to / interact / inspect / cast / fetch ...). Design:
-- docs/design/stable-target-ids.md.
M.FOLIAGE_MATCH_CM, M.CONVERTED_MATCH_CM = 100, 200
local function dm(v) return math.floor(v / 10 + 0.5) end
function M.foliage_id(class_name, p)
    return string.format("fol:%s@%d,%d,%d", tostring(class_name), dm(p.X), dm(p.Y), dm(p.Z or 0))
end
-- -> {class, pos = {X, Y, Z} cm} for a stable id, {legacy = "fol:<component>:<index>"} for an old one, nil otherwise
function M.parse_foliage_id(id)
    id = tostring(id or "")
    local cls, x, y, z = id:match("^fol:([%w_]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if cls then return { class = cls, pos = { X = tonumber(x) * 10, Y = tonumber(y) * 10, Z = tonumber(z) * 10 } } end
    if id:match("^fol:[^@]+:%d+$") then return { legacy = id } end
    return nil
end

-- foliage(origin_cm, radius_cm, {match = pattern on the class, exclude = pattern|{patterns},
--   kinds = {tree=true,...}, max = n, include_hidden = true (also zero-scale = felled/picked/converted
--   instances, marked hidden = true)}) -> rows nearest first (positions in cm under _pos).
function M.foliage(origin, radius_cm, opts)
    opts = opts or {}
    local out = {}
    if not origin then return out end
    local excl = opts.exclude
    if type(excl) == "string" then excl = { excl } end
    for _, c in ipairs(U.find_all("InteractableFoliageISMComponent", { skip_defaults = true })) do
        local cls = P(c, "ActorClass")
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
                local psm = P(c, "PerInstanceSMData") -- once per component, not per instance
                for _, e in ipairs(idxs) do
                    local i = type(e) == "number" and e or U.try(function() return e:get() end)
                    local w = type(i) == "number" and cl and U.try(function()
                        local m = psm[i + 1].Transform
                        local t, x = m.WPlane, m.XPlane
                        return { X = t.X, Y = t.Y, Z = t.Z, s = math.sqrt(x.X * x.X + x.Y * x.Y + x.Z * x.Z) }
                    end)
                    local hidden = w and w.s <= 0.01 -- a zero-scale instance is hidden (converted / felled)
                    if w and (not hidden or opts.include_hidden) then
                        local p = rotate_yaw({ X = w.X * sc.X, Y = w.Y * sc.Y, Z = w.Z * sc.Z }, yaw)
                        p = { X = cl.X + p.X, Y = cl.Y + p.Y, Z = cl.Z + p.Z }
                        local d = U.dist2d(origin, p)
                        if d <= radius_cm then
                            facts = facts or facts_of(cls)
                            out[#out + 1] = { id = M.foliage_id(cname, p), _legacy = "fol:" .. (U.short(c) or "?") .. ":" .. i,
                                hidden = hidden or nil, kind = "foliage", foliage = fk,
                                class = cname, name = facts.name, position = U.to_wire(p), distance = U.cm_to_m(d), _pos = p,
                                _comp = c, _index = i, damageable = P(c, "bDamageable") == true or nil,
                                interactable = P(c, "bInteractable") == true or nil,
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

-- resolve_foliage(id) -> row (a foliage row, or the census row of the actor it was converted into; its
-- distance is from me), how ("same" | "reindexed" | "converted" | "legacy") | nil, why ("felled_or_picked" |
-- "not_found" | "not_a_foliage_id" | "no_pawn"). Read-only, like M.foliage.
function M.resolve_foliage(id)
    local k = M.parse_foliage_id(id)
    if not k then return nil, "not_a_foliage_id" end
    local pawn = M.local_pawn()
    local me = pawn and U.loc(pawn)
    if not me then return nil, "no_pawn" end
    local function from_me(row)
        local p = row._pos
        if p then row.distance = U.cm_to_m(U.dist2d(me, p)) end
        return row
    end
    if k.legacy then -- an id handed out before stable ids: only an exact component:index match around me
        for _, r in ipairs(M.foliage(me, 8000, {})) do if r._legacy == id then return from_me(r), "legacy" end end
        return nil, "not_found"
    end
    local best, bd, hidden
    for _, r in ipairs(M.foliage(k.pos, M.FOLIAGE_MATCH_CM * 3, { include_hidden = true })) do
        local d = U.dist2d(k.pos, r._pos)
        if r.class == k.class and d <= M.FOLIAGE_MATCH_CM then
            if r.hidden then hidden = true
            elseif not bd or d < bd then best, bd = r, d end
        end
    end
    if best then return from_me(best), best.id == id and "same" or "reindexed" end
    -- converted: the server spawned the instance's actor class where it stood (and hid the instance)
    local near, nd
    for _, a in ipairs(U.find_all(k.class, { skip_defaults = true }) or {}) do
        local at = U.loc(a)
        local d = at and U.dist2d(k.pos, at)
        if d and d <= M.CONVERTED_MATCH_CM and (not nd or d < nd) then near, nd = a, d end
    end
    if near then
        local ok, row = pcall(describe_resource, near, me)
        if ok and row then row.converted_from = id; return row, "converted" end
    end
    return nil, hidden and "felled_or_picked" or "not_found"
end

-- ------------------------------------------------------------------ vaults (read only)
-- What a player sees at and in a Dragonkin vault (design: docs/research/2026-11-17-vault-reads.md, A1 A3 A4 A6 A7).
-- Property reads only, each through U.prop on the actor or component (R17); the fields of engine-built structs
-- (SwitchState, FDungeonData, FBox, FVector) are plain reads, as places.lua reads Landmarks. No UFunction call beyond
-- the census's own position read (U.loc), no RPC, no write, nothing under DW_PAUSE. Field names: dump 26574459, a
-- SERVER dump made with nobody near a vault: whether each one replicates to the client is unknown until probes P1-P4.
--   get_state, look  in_vault  ULocalPlayerAudioSubsystem.bInDungeon, the game's own flag (it switches the music)
--                    vault     the vault whose box holds him: AGameplayObjectRegistry.Dungeons[i] {Box, UserVisibleName},
--                              else the ADungeon actors (DungeonUserVisibleName; BoxComponent's BoxExtent x RelativeScale3D
--                              about its RelativeLocation, used only when the box is the actor's root, i.e. not attached
--                              and standing where the actor stands, so its relative transform is its world one).
--                              Several boxes hold him: the smallest.
--   a teleporter row (any interactable that declares TeleportDestinationName: BP_InteractablePlayerTeleporter_C, its
--                    _Locked variant, ASwitchableTeleporter) destination = that FName; arrives_at = where the
--                    ATeleportationTarget of that TargetName stands (left out when none or several have it); leads_to =
--                    the vault whose box holds arrives_at, or "outside" when every vault's box is known and none holds
--                    it; locked = not IsUnlocked (only on a class that declares IsUnlocked)
--   a switch row     (SwitchState declared: BP_BinaryLever_C) switch_position = SwitchState.SwitchPosition (the raw
--                    number: which one means "pulled" is not known yet), switch_highest = HighestPosition, drives = the
--                    ids of its Switchables
--   a chest row      chest_state "unopened" | "opened" | "emptied" (AWorldChest.ChestState, EChestState 0-2)
--   hazards          a census category: each SwitchableTrap (AAnimatingTrap: fire jets, spikes) in range, kind "trap",
--                    name = UserReadableName, parts = its behaviour modules that read, active_parts = those with bActive
-- The vault boxes and the teleport targets are always-loaded actors: read at most every VAULT_TTL_S into plain tables
-- (names and numbers, never a UObject: R16). A read that fails or gives nil adds no field.
-- Log lines, each only when it changes: "[DWClient] vault_list n=<n> source=<registry|actor|none> complete=<bool>",
-- "[DWClient] vault_targets n=<n>", "[DWClient] vault_read in_vault=<bool|nil> vault=<name|nil> teleporters=<n>
-- switches=<n> chests=<n> traps=<n>".
M.VAULT_TTL_S = 30
M.CHEST_STATES = { [0] = "unopened", [1] = "opened", [2] = "emptied" }
M.VAULT = { noted = {} } -- caches: t, vaults, complete; t_targets, targets (name -> {X, Y, Z} cm, false = several)
M.vault_clock = os.clock

local function vec(v)
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end

function M.vault_note(kind, line, key)
    key = key or kind
    if M.VAULT.noted[key] == line then return end
    M.VAULT.noted[key] = line
    pcall(print, "[DWClient] " .. kind .. " " .. line .. "\n")
end

-- -> the vaults as boxes: {name, min, max} (the registry's, axis-aligned) or {name, mid, half, yaw} (an actor's), and
-- complete = every vault the game lists has a readable box (only then can a point be said to be in none of them)
function M.vault_list()
    if rawget(_G, "DW_PAUSE") then return {}, false end
    local V, now = M.VAULT, M.vault_clock()
    if V.vaults and V.t and now - V.t < M.VAULT_TTL_S then return V.vaults, V.complete end
    local out, complete, source = {}, true, "none"
    local reg = U.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    U.each(reg and P(reg, "Dungeons") or nil, function(e)
        local name = text(U.try(function() return e.UserVisibleName end))
        local box = U.try(function() return e.Box end)
        local mn, mx = vec(U.try(function() return box.min end)), vec(U.try(function() return box.max end))
        local valid = U.try(function() return box.IsValid end)
        if name and mn and mx and valid ~= false and valid ~= 0 and mn.X < mx.X and mn.Y < mx.Y and mn.Z <= mx.Z then
            out[#out + 1] = { name = name, min = mn, max = mx }
        else complete = false end
    end, 64)
    if #out > 0 then source = "registry"
    else
        complete = true
        for _, dg in ipairs(U.find_all("Dungeon", { skip_defaults = true })) do
            local name = text(P(dg, "DungeonUserVisibleName"))
            local box = P(dg, "BoxComponent")
            local row
            if name and U.valid(box) and not U.valid(P(box, "AttachParent")) then
                local c, e, s = vec(P(box, "RelativeLocation")), vec(P(box, "BoxExtent")), vec(P(box, "RelativeScale3D"))
                local rot = P(box, "RelativeRotation")
                local okr, yaw, pitch, roll = pcall(function() return rot.Yaw, rot.Pitch, rot.Roll end)
                local at = U.loc(dg)
                if c and e and s and okr and num(yaw) and num(pitch) and num(roll) and math.abs(pitch) < 0.5
                   and math.abs(roll) < 0.5 and at and U.dist(at, c) < 1 then
                    row = { name = name, mid = c, yaw = yaw,
                            half = { X = math.abs(e.X * s.X), Y = math.abs(e.Y * s.Y), Z = math.abs(e.Z * s.Z) } }
                end
            end
            if row then out[#out + 1] = row else complete = false end
        end
        if #out > 0 then source = "actor" end
    end
    if #out == 0 then complete = false end
    V.t, V.vaults, V.complete = now, out, complete
    M.vault_note("vault_list", string.format("n=%d source=%s complete=%s", #out, source, tostring(complete)))
    return out, complete
end

-- the vault (a vault_list row) whose box holds the point p (cm); several: the smallest; nil when none
function M.vault_at(p, vaults)
    if type(p) ~= "table" or type(p.X) ~= "number" then return nil end
    local best, best_v
    for _, v in ipairs(vaults or {}) do
        local inside, vol
        if v.min then
            inside = p.X >= v.min.X and p.X <= v.max.X and p.Y >= v.min.Y and p.Y <= v.max.Y
                and p.Z >= v.min.Z and p.Z <= v.max.Z
            vol = (v.max.X - v.min.X) * (v.max.Y - v.min.Y) * math.max(v.max.Z - v.min.Z, 1)
        elseif v.mid then
            local c, s = math.cos(math.rad(v.yaw or 0)), math.sin(math.rad(v.yaw or 0))
            local dx, dy = p.X - v.mid.X, p.Y - v.mid.Y
            inside = math.abs(dx * c + dy * s) <= v.half.X and math.abs(dy * c - dx * s) <= v.half.Y
                and math.abs(p.Z - v.mid.Z) <= v.half.Z
            vol = v.half.X * v.half.Y * math.max(v.half.Z, 1)
        end
        if inside and (not best_v or vol < best_v) then best, best_v = v, vol end
    end
    return best
end

-- TargetName -> where that ATeleportationTarget stands (cm); false when several share the name
function M.teleport_targets()
    if rawget(_G, "DW_PAUSE") then return {} end
    local V, now = M.VAULT, M.vault_clock()
    if V.targets and V.t_targets and now - V.t_targets < M.VAULT_TTL_S then return V.targets end
    local out, n = {}, 0
    for _, t in ipairs(U.find_all("TeleportationTarget", { skip_defaults = true })) do
        local name = text(P(t, "TargetName"))
        local at = name and U.loc(t)
        if at then
            if out[name] == nil then out[name], n = at, n + 1 else out[name] = false end
        end
    end
    V.t_targets, V.targets = now, out
    M.vault_note("vault_targets", "n=" .. n)
    return out
end

-- adds the vault fields to an interactable's row d (see above); called by describe_interactable
function M.vault_row(a, d)
    local dest = text(P(a, "TeleportDestinationName"))
    if dest then
        d.destination = dest
        local at = M.teleport_targets()[dest]
        if at then
            d.arrives_at = U.to_wire(at)
            local vaults, complete = M.vault_list()
            local v = M.vault_at(at, vaults)
            if v then d.leads_to = v.name elseif complete then d.leads_to = "outside" end
        end
        local unlocked = P(a, "IsUnlocked")
        if type(unlocked) == "boolean" then d.locked = not unlocked end
    end
    local ss = P(a, "SwitchState")
    local pos = ss ~= nil and num(U.try(function() return ss.SwitchPosition end)) or nil
    if pos then
        d.switch_position = pos
        local hi = num(P(a, "HighestPosition"))
        if hi then d.switch_highest = hi end
        local ids = {}
        U.each(P(a, "Switchables"), function(x)
            local id = U.alive(x) and U.short(x) or nil
            if id then ids[#ids + 1] = id end
        end, 16)
        if #ids > 0 then d.drives = ids end
    end
    if d.kind == "chest" then
        local cs = num(P(a, "ChestState"))
        if cs and M.CHEST_STATES[cs] then d.chest_state = M.CHEST_STATES[cs] end
    end
end

-- a trap's census row (category hazards)
function M.describe_trap(a, origin)
    local d = base(a, origin)
    d.kind = "trap"
    d.name = text(P(a, "UserReadableName")) or clean_class(d.class)
    local n, on = 0, 0
    U.each(P(a, "TrapBehaviourModules"), function(m)
        local b = nil
        if U.valid(m) then b = P(m, "bActive") end
        if type(b) == "boolean" then
            n = n + 1
            if b then on = on + 1 end
        end
    end, 32)
    if n > 0 then d.parts, d.active_parts = n, on end
    return d
end

-- {in_vault, vault} where he stands (cm); each left out when it does not read
function M.vault_here(at)
    if rawget(_G, "DW_PAUSE") then return {} end
    local out = {}
    local sub = U.find_all("LocalPlayerAudioSubsystem", { skip_defaults = true })[1]
    local b = sub and P(sub, "bInDungeon")
    if type(b) == "boolean" then out.in_vault = b end
    local v = at and M.vault_at(at, (M.vault_list())) or nil
    if v then out.vault = v.name end
    return out
end

-- ------------------------------------------------------------------ census
local function owner_of(c) local o = U.try(function() return c:GetOwner() end); return U.alive(o) and o or nil end

-- The players on the game map and compass at any distance (mapplayers.lua: GameplayObjectRegistry.PlayerCharacters),
-- loaded once per load of this file; nil when missing.
local MAPP
local function mapplayers()
    if MAPP == nil then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/mapplayers.lua"))() end)
        MAPP = ok and type(m) == "table" and m or false
    end
    return MAPP or nil
end
M.mapplayers = mapplayers

-- census(log, {radius_m=30, max=25, kinds={players=true,...}, near="<player>", lean=true}) -> {origin, players,
-- creatures, items, resources, interactables, totals, ms, map_players}. Each list nearest first, capped at `max`.
--   near  count from that PLAYER, not from me ("the stones near me", said by him; retro 2026-11-01 root cause 4):
--         origin = his pawn (it must be replicated: in sight); every row's distance is from him, `from_me` from me and
--         `side` where it lies from him ("in front" | "behind" | "to the left" | "to the right" of his facing); his
--         own row is left out. Not in sight -> {ok=false, reason="target_not_visible", detail, map = his map row}.
--   lean  skip the passes of categories not asked for (and the interactables listing unless asked): a cheap
--         kinds-only census (items + resources around a player: ~100 ms instead of ~200 ms live).
--   map_players (players wanted): every OTHER player on the game map at any distance, from ME:
--         {name, position, distance, direction ("NE"), bearing_deg (0 = north), in_sight (pawn replicated)}.
-- What the caps cut off, one row per kind of thing, nearest first: {category, name, count, distance (the nearest),
-- kind, verb, tool, tool_tier, item}. cut = { {category, row}, ... }; listed = the census lists as they are returned.
-- Each list is the N nearest of everything in its category, so in a busy place a whole kind is cut off although it is
-- well inside the radius. Chain 20261116-184351: get_state's 20 resource rows were all Ash Log, Ash Logs and Stone
-- within 12 m; the Rune Essence rocks his quest asked for stood 41 m away, shown to neither model, and the plan went
-- exploring for them until the trial ran out. A name that still has a row in its list is left out: it is listed.
M.BEYOND_MAX = 12
function M.digest_cut(cut, listed, max_rows)
    local shown = {}
    for cat, l in pairs(listed or {}) do
        for _, d in ipairs(type(l) == "table" and l or {}) do
            if type(d) == "table" and d.name then shown[tostring(cat) .. " " .. tostring(d.name)] = true end
        end
    end
    local by, rows = {}, {}
    for _, c in ipairs(cut or {}) do
        local cat, d = c[1], c[2]
        local key = type(d) == "table" and d.name and (tostring(cat) .. " " .. tostring(d.name)) or nil
        if key and not shown[key] then
            local g = by[key]
            if not g then
                g = { category = cat, name = d.name, count = 0, kind = d.kind, verb = d.verb, tool = d.tool,
                      tool_tier = d.tool_tier, item = d.item or d.drop_item }
                by[key] = g
                rows[#rows + 1] = g
            end
            g.count = g.count + (tonumber(d.count) or 1)
            if type(d.distance) == "number" and (not g.distance or d.distance < g.distance) then g.distance = d.distance end
        end
    end
    table.sort(rows, function(a, b) return (a.distance or 1e9) < (b.distance or 1e9) end)
    for i = #rows, (max_rows or M.BEYOND_MAX) + 1, -1 do rows[i] = nil end
    return rows
end

function M.census(log, opts)
    opts = opts or {}
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local t0 = os.clock()
    local pc = M.local_pc()
    local me = M.local_pawn(pc)
    local my_at = me and U.loc(me)
    if not my_at then return { ok = false, reason = "no local pawn" } end
    local origin, anchor = my_at, nil
    local MAP = mapplayers()
    if opts.near ~= nil and opts.near ~= "" then
        local who = tostring(opts.near)
        local pw, pname
        if MAP then pw, pname = MAP.pawn_of(who, me) end
        local at = pw and U.loc(pw)
        if not at then
            local row = MAP and (MAP.find(who, { me = me })) or nil
            return { ok = false, reason = "target_not_visible", near = who,
                     map = row and { name = row.name, position = row.position, distance = row.distance, direction = row.direction } or nil,
                     detail = row and string.format("I can't see %s from here (the map has him %s m %s of me), so I can't tell what is near him.",
                                                    tostring(row.name), tostring(row.distance), tostring(row.direction or "away"))
                         or string.format("No player called %s is in sight or on the map.", who) }
        end
        local rot = U.try(function() return pw:K2_GetActorRotation() end)
        origin, anchor = at, { name = pname or who, id = U.short(pw), yaw = rot and num(U.try(function() return rot.Yaw end)) or nil }
    end
    local r_cm = (opts.radius_m or M.DEFAULT_RADIUS_M) * 100
    local max = opts.max or M.DEFAULT_MAX
    local want = opts.kinds
    local lean = opts.lean == true and want ~= nil
    local seen = { [U.short(me) or "?"] = true }
    if anchor and anchor.id then seen[anchor.id] = true end
    local out, totals = {}, {}
    local cut = {} -- rows the caps drop, { category, row }: told as kinds in out.beyond (M.digest_cut)

    local function within(a)
        local at = U.loc(a)
        return at and U.dist(origin, at) <= r_cm
    end
    local function add(cat, d)
        local l = out[cat] or {}
        out[cat] = l
        l[#l + 1] = d
        totals[cat] = (totals[cat] or 0) + 1
        if anchor and type(d.position) == "table" then
            local p = U.from_wire(d.position)
            if p then
                d.from_me = U.cm_to_m((d.kind == "foliage" and U.dist2d or U.dist)(my_at, p)) -- same metric as distance
                d.side = MAP and MAP.side(origin, anchor.yaw, p) or nil
            end
        end
    end
    local by_id = {}
    -- Every pass runs (so a filtered-out category still claims its actors and they are not listed
    -- again as plain interactables); only wanted categories are described. A lean census lists no
    -- interactables, so it skips the unwanted passes.
    local function pass(cat, classes, describe)
        local on = not want or want[cat]
        if lean and not on then return end
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
    pass("hazards", { "SwitchableTrap" }, M.describe_trap) -- a vault's fire jets and spikes (vault section above)
    -- standing trees / bushes / pickups still drawn as foliage (see M.foliage); opts.foliage=false skips
    if (not want or want.resources) and opts.foliage ~= false then
        -- trees and pickups capped separately (a third of the rows each), so ground stones and branches
        -- (they lie everywhere) don't crowd out the trees or the actors
        for _, kind in ipairs({ "tree", "pickup" }) do
            local ok, rows = pcall(M.foliage, origin, r_cm, { kinds = { [kind] = true } })
            if ok then
                local n = math.max(math.ceil(max / 3), 1)
                for i, r in ipairs(rows) do -- nearest first (M.foliage sorts)
                    r._comp, r._index, r._pos, r._legacy = nil, nil, nil, nil
                    if i <= n then add("resources", r) else cut[#cut + 1] = { "resources", r } end
                end
            elseif log then log("sense: foliage " .. tostring(rows)) end
        end
    end

    local on = not want or want.interactables
    local kind_of = {}
    for _, f in ipairs((lean and not on) and {} or M.ACTOR_FAMILIES) do
        for _, o in ipairs(U.find_all(f.class, { skip_defaults = true })) do
            local id = U.short(o)
            if id and not kind_of[id] then kind_of[id] = f.kind end
        end
    end
    for _, f in ipairs((lean and not on) and {} or M.FAMILIES) do
        for _, c in ipairs(U.find_all(f.class, { skip_defaults = true })) do
            local o = owner_of(c)
            local id = o and U.short(o)
            if id and not kind_of[id] then kind_of[id] = f.kind end
        end
    end
    if on then out.interactables = out.interactables or {} end
    for _, ic in ipairs((lean and not on) and {} or U.find_all("InteractionComponent", { skip_defaults = true })) do
        local a = owner_of(ic)
        local id = a and U.short(a)
        if id and seen[id] and by_id[id] and not by_id[id].prompt then
            -- an already-listed entity that is also interactable (gatherable "Collect", sapling "Uproot")
            by_id[id].prompt = text(U.try(function() return ic.InteractionPrompt end))
        elseif id and not seen[id] then
            -- a thing with an extent (a pond) is in the radius when its nearest point is, and that far off
            local ext = M.extent_of(a, id)
            local edge = ext and M.box_nearest(origin, ext.mid, ext.ha, ext.hb, ext.hz, ext.yaw) or nil
            local inside
            if edge then inside = U.dist(origin, edge) <= r_cm else inside = within(a) end
            if inside then
                seen[id] = true
                if on then
                    local ok, d = pcall(describe_interactable, a, ic, kind_of[id], origin)
                    if ok and d and edge then
                        d.distance = U.cm_to_m(U.dist(origin, edge))
                        d.nearest = U.to_wire(edge) -- its point nearest to him; position stays its middle
                        d.size_m = { r1(ext.ha / 50), r1(ext.hb / 50) }
                    end
                    if ok and d then add("interactables", d) end
                end
            end
        end
    end

    -- Everyone online (PlayerStates are always relevant, pawns only within net relevancy range).
    local online
    if not want or want.players then
        online = {}
        local in_sight = {}
        for _, ps in ipairs(U.find_all("PlayerState", { skip_defaults = true })) do
            local n = text(U.try(function() return ps:GetPlayerName() end))
            if n then
                online[#online + 1] = n
                if U.valid(P(ps, "PawnPrivate")) then in_sight[#in_sight + 1] = n end
            end
        end
        table.sort(online)
        totals.players_online = #online
        -- ... and where each of them is, at any distance: the game map's markers (compass)
        local okm, rows = pcall(function() return MAP and MAP.players({ me = me }) end)
        if okm and type(rows) == "table" then
            local mp = {}
            for _, r in ipairs(rows) do
                if not r.me then
                    local seen_now = false
                    for _, n in ipairs(in_sight) do if MAP.same_name(n, r.name) then seen_now = true end end
                    mp[#mp + 1] = { name = r.name, position = r.position, distance = r.distance, direction = r.direction,
                                    bearing_deg = r.bearing_deg, in_sight = seen_now }
                end
            end
            out.map_players = mp
            totals.map_players = #mp
        elseif not okm and log then log("sense: map players " .. tostring(rows)) end
    end

    -- up_m: each thing's height above MY feet (capsule half-height 88 cm), whatever the census origin, so
    -- "the chest is 15 m up" is perceived, not computed by the model (research 2026-11-01-autonomous-building §4.1)
    local feet_m = (my_at.Z - 88) / 100
    for _, l in pairs(out) do
        for _, d in ipairs(l) do
            local z = type(d) == "table" and type(d.position) == "table" and d.position[3] or nil
            if type(z) == "number" and d.up_m == nil then d.up_m = math.floor((z - feet_m) * 10 + 0.5) / 10 end
        end
    end

    for cat, l in pairs(out) do
        table.sort(l, function(x, y) return (x.distance or 0) < (y.distance or 0) end)
        for i = #l, max + 1, -1 do
            if cat ~= "players" and cat ~= "map_players" then cut[#cut + 1] = { cat, l[i] } end
            l[i] = nil
        end
    end
    out.beyond = M.digest_cut(cut, out)
    out.players_online = online
    out.ok = true
    out.origin = U.to_wire(origin)
    if anchor then out.near, out.from = anchor.name, U.to_wire(my_at) end -- origin = his position; from = mine
    out.radius_m = r_cm / 100
    out.totals = totals
    out.prop_guard = U.prop_stats() -- R17 counters since load (undeclared reads skipped, stale entries refused)
    -- in a vault or not, and which (from where HE stands: not for a census around another player, nor a lean one)
    if not lean and not anchor then
        local okv, vh = pcall(M.vault_here, my_at)
        if okv and type(vh) == "table" then out.in_vault, out.vault = vh.in_vault, vh.vault end
        local n = { teleporters = 0, switches = 0, chests = 0 }
        for _, d in ipairs(out.interactables or {}) do
            if d.destination then n.teleporters = n.teleporters + 1 end
            if d.switch_position then n.switches = n.switches + 1 end
            if d.chest_state then n.chests = n.chests + 1 end
        end
        M.vault_note("vault_read", string.format("in_vault=%s vault=%s teleporters=%d switches=%d chests=%d traps=%d r=%d",
            tostring(out.in_vault), tostring(out.vault), n.teleporters, n.switches, n.chests, #(out.hazards or {}),
            math.floor(r_cm / 100)), "vault_read" .. r_cm) -- one line per radius (look and get_state differ), on change
    end
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
--   {"type":"fatal", killed_by, text, power_level, status_flags, status, fell_m, at}  (DamageComponent:OnRep_FatalDamageInfo);
--   {"type":"death", fell_m, at} / {"type":"revive"} on IsDead transitions;
--   fell_m = the height of a fall he was in or landed from in the last V.FALL_RECENT_S (> 3 m only), from the
--   1 s poll's CharacterMovement:IsFalling + Z (the top is the last grounded sample), at = [x,y,z] m there;
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
    local okw, walltime = pcall(require, "walltime") -- ms ts + act/ep (telemetry items 2, 5)
    -- (a client whose require cache holds an older walltime without stamp: fall back, never lose the row; live
    -- 13:33-13:4x 2026-11-01 the vitals watcher died on "attempt to call a nil value (field 'stamp')")
    if okw and type(walltime) == "table" and type(walltime.stamp) == "function" then walltime.stamp(ev)
    else ev.ts = os.time(); ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts) end
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
    local ps = P(a, "PlayerState") -- the instigator is any class: speculative reads go through U.prop (R17)
    if U.valid(ps) then d.player = U.str(U.try(function() return ps:GetPlayerName() end)) end
    local data = P(a, "LoadedData")
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
    if U.valid(src) then
        d.source = { id = U.short(src), class = U.class_word(src) }
        -- an environment emitter COMPONENT (PoisonEmitterBox killed him twice on 2026-11-01): which actor, and where
        if tostring(d.source.class or ""):find("Emitter", 1, true) then
            local o = U.try(function() return src:GetOwner() end)
            if U.valid(o) then d.source.owner, d.source.owner_class = U.short(o), U.class_word(o) end
            local l = U.try(function() return src:K2_GetComponentLocation() end)
            local x, y, z = l and num(U.try(function() return l.X end)), l and num(U.try(function() return l.Y end)), l and num(U.try(function() return l.Z end))
            if x and y and z then d.source.at = { r1(x / 100), r1(y / 100), r1(z / 100) } end
        end
    end
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
    local fell, at = V.fell_m(M.local_pawn())
    emit({ type = "fatal", set = U.try(function() return f.bIsSet end), killed_by = who(U.try(function() return f.KilledBy:Get() end)),
           text = text(U.try(function() return f.KilledByText end)), power_level = num(U.try(function() return f.KilledByPowerLevel end)),
           status_flags = flags, status = status_names(flags), fell_m = fell, at = at })
    V.counts.fatal = V.counts.fatal + 1
end

M.VITALS_HOOKS = {
    { path = "/Script/Dominion.HealthComponent:OnRep_AuthoritativeHealth", handler = "on_health" },
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyPointDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.DamageComponent:OnRep_FatalDamageInfo", handler = "on_fatal" },
}

-- the shared hook hub (BUGS L24): one native hook per UFunction per process, never unregistered
local HUB
local function hub()
    if not HUB then
        local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or (ROOT .. "/client_mod/scripts")
        HUB = assert(loadfile(dir .. "/hookhub.lua"))()
    end
    return HUB
end

-- subscribe the handler; the hub registers the native hook once, in the world, and never unregisters it
local function register(h, log, in_world)
    local ok = hub().on(h.path, "sense:" .. h.handler, function(...)
        local fn = _G.DWVitals and _G.DWVitals[h.handler]
        if fn then fn(...) end
    end, { defer = not in_world, log = log })
    if ok then V.hooks[h.path] = true end
    return ok
end

-- Falls (death-loop forensics E2: a 30 m fall was reported as "no idea what hit me"). The poll keeps the last
-- grounded Z; while IsFalling the top is that Z; on landing the drop is kept for V.FALL_RECENT_S.
V.FALL_RECENT_S = 6
local function track_fall(p)
    local z = U.try(function() return p:K2_GetActorLocation().Z end)
    if type(z) ~= "number" then return end
    local falling = U.try(function() return p.CharacterMovement:IsFalling() end) == true
    if falling then
        V.air_top = math.max(V.air_top or V.ground_z or z, z)
    elseif V.air_top then
        local h = V.air_top - z
        if h > 300 then V.last_fall = { t = os.time(), h = h } end
        V.air_top = nil
    end
    if not falling then V.ground_z = z end
end

-- (fell_m, at) now: the fall in progress or the one that just ended (> 3 m), and where he is.
function V.fell_m(p)
    local loc = p and U.try(function() return p:K2_GetActorLocation() end)
    local at = loc and { r1(loc.X / 100), r1(loc.Y / 100), r1(loc.Z / 100) } or nil
    local h
    if V.air_top and loc then h = V.air_top - loc.Z end
    if (not h or h <= 300) and V.last_fall and os.time() - V.last_fall.t <= V.FALL_RECENT_S then h = V.last_fall.h end
    return (h and h > 300) and r1(h / 100) or nil, at
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
    track_fall(p)
    local dead = U.try(function() return p.HealthComponent:IsDead() end) == true
    if V.dead ~= nil and dead ~= V.dead then
        local fell, at = V.fell_m(p)
        emit({ type = dead and "death" or "revive", hp = r1(hp), survival = M.survival(p), fell_m = dead and fell or nil, at = dead and at or nil })
    end
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
    ensure_dir(ROOT .. "/client_io/events")
    local p = M.local_pawn()
    V.me_id = p and U.short(p) or V.me_id
    V.last_hp = p and num(U.health(p)) or V.last_hp
    -- Hooks registered at the main menu (client boot) or for an earlier pawn never delivered a damage
    -- row (vitals.jsonl: damage rows only from the 17:53 in-world start; none after the boot-time starts
    -- at 19:29/19:33/19:38 although he took 36 damage at 19:43:53). So once a pawn exists, hooks from
    -- another pawn (or none) are dropped and registered again; the bridge's supervisor calls this again
    -- when vitals_status().hooked_pawn differs from the current pawn. (Re-registering is the fix being
    -- tried; UNVERIFIED until a damage row appears after a boot.)
    -- BUGS L24: no UnregisterHook ever (the 22:31 crash followed an unregister/re-register cycle); a new
    -- pawn just re-subscribes (no native call). The native hooks are made once, with a pawn in the world.
    local me = p and U.short(p) or nil
    local in_world = not hub().not_in_world(p)
    local hooks = {}
    for _, h in ipairs(M.VITALS_HOOKS) do hooks[h.path:match(":(.+)$")] = register(h, log, in_world) end
    if me and in_world then V.hooked_pawn = me end
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
    for _, h in ipairs(M.VITALS_HOOKS) do hub().off(h.path, "sense:" .. h.handler) end -- native hooks stay (L24)
    V.hooks = {}
    return { ok = true }
end

function M.vitals_status()
    local n = 0
    for _ in pairs(V.hooks) do n = n + 1 end
    return { running = V.loop ~= nil, hooks = n, counts = V.counts, last_hp = V.last_hp, me = V.me_id, dead = V.dead,
             hooked_pawn = V.hooked_pawn }
end

return M
