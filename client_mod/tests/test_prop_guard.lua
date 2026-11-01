-- Offline tests for U.prop (mod/body/util.lua, risk register R17) and its use in the census describers
-- (client_mod/scripts/sense.lua). A fake UE4SS reproduces the crash_2026_11_01_00_08_24 mechanism: UE4SS 3.0.1's
-- UStruct::FindProperty memoises (struct ADDRESS, name) -> FProperty and never evicts, so a Blueprint class
-- allocated at a freed class's address inherits the old entries. A raw `obj.Name` read whose resolved property
-- is not declared by the object's live class chain counts as the native AV (FAKE_AV).
--   lua client_mod/tests/test_prop_guard.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

function StaticFindObject() return nil end
function FindFirstOf() return nil end
function FindAllOf() return {} end

-- ------------------------------------------------------------------ fake UE4SS reflection
local UE_CACHE = {}  -- [struct addr] = {[name] = prop}: UE4SS's FindProperty cache (never evicted)
local FAKE_AV       -- set when a raw read would have read another class's layout
local walks = 0     -- ForEachProperty calls (the guard's live walk)
local reflections = 0 -- obj:Reflection() calls (the guard's check against UE4SS's resolution)

local function prop(owner, name, ptype) return { owner = owner, name = name, ptype = ptype or "ObjectProperty" } end
local function prop_ud(p)
    return { GetFName = function() return { ToString = function() return p.name end } end,
             GetFullName = function() return p.ptype .. " " .. p.owner.path .. ":" .. p.name end }
end
local function chain_has(st, p)
    local s = st
    while s do
        if s == p.owner then return true end
        s = s.super
    end
    return false
end
-- UE4SS 3.0.1 FindProperty: cache hit by address first; else walk (most-derived first) and memoise a hit
local function find_property(st, name)
    local per = UE_CACHE[st.addr]
    if per and per[name] then return per[name] end
    local s = st
    while s do
        for _, p in ipairs(s.props) do
            if p.name == name then
                UE_CACHE[st.addr] = per or {}
                UE_CACHE[st.addr][name] = p
                return p
            end
        end
        s = s.super
    end
    return nil -- a miss is not cached
end

local struct_ud
local function struct_methods(st)
    return {
        IsValid = function() return st ~= nil end,
        GetFullName = function() return st and (st.kind .. " " .. st.path) or nil end,
        ForEachProperty = function(_, cb)
            walks = walks + 1
            if st.broken then error("ForEachProperty failed") end
            for _, p in ipairs(st.props) do if cb(prop_ud(p)) == true then break end end
        end,
        GetSuperStruct = function() return struct_ud(st.super) end,
        IsClass = function() return true end,
        GetAddress = function() return st.addr end,
    }
end
struct_ud = function(st)
    if not st then return { IsValid = function() return false end } end
    return struct_methods(st)
end
local function struct(kind, path, addr, super, props)
    local st = { kind = kind, path = path, addr = addr, super = super, props = {} }
    for _, n in ipairs(props or {}) do st.props[#st.props + 1] = prop(st, n[1], n[2]) end
    return st
end

-- An instance: memory is keyed by the DECLARING property ("owner:name"); a raw read resolves through the cache.
local function instance(cls, full, values, extra)
    local o = { __ue = true }
    local methods = {
        IsValid = function() return true end,
        GetFullName = function() return full end,
        GetClass = function() return struct_ud(cls) end,
        IsClass = function() return false end,
        Reflection = function()
            reflections = reflections + 1
            return { GetProperty = function(_, name)
                local p = find_property(cls, name)
                return p and prop_ud(p) or { GetFullName = function() return nil end }
            end }
        end,
        K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
    }
    for k, f in pairs(extra or {}) do methods[k] = f end
    return setmetatable(o, { __index = function(_, k)
        if methods[k] then return methods[k] end
        local p = find_property(cls, k)
        if not p then error("no property " .. k) end
        if not chain_has(cls, p) then FAKE_AV = k; error("native AV: " .. k .. " read with " .. p.owner.path .. "'s layout") end
        return values[p.owner.path .. ":" .. k]
    end })
end

-- the classes (dump 26161880 Dominion.hpp: AWorldActor declares DisplayName@0x300; AWorldChest is NOT one)
local Object = struct("Class", "/Script/CoreUObject.Object", "n0", nil, {})
local Actor = struct("Class", "/Script/Engine.Actor", "n1", Object, { { "RootComponent" } })
local WorldActor = struct("Class", "/Script/Dominion.WorldActor", "n2", Actor, { { "DisplayName", "TextProperty" } })
local Destructible = struct("Class", "/Script/Dominion.DestructibleWorldActor", "n3", WorldActor,
    { { "HealthComponent" }, { "bIsHidden", "BoolProperty" } })
local WorldChest = struct("Class", "/Script/Dominion.WorldChest", "n4", Actor,
    { { "InventoryComponent" }, { "ChestRespawnProfile", "StructProperty" } })
local AIChar = struct("Class", "/Script/Dominion.DominionAICharacter", "n5", Actor, { { "HealthComponent" }, { "PowerLevel", "IntProperty" } })

local U = assert(loadfile(root .. "/mod/body/util.lua"))()
U.is_ue_object = function(o) return type(o) == "table" and rawget(o, "__ue") == true end

local function ftext(s) return { ToString = function() return s end } end

-- 1. a real declaration through the super chain reads normally
do
    local rock_c = struct("BlueprintGeneratedClass", "/Game/BP_Rock.BP_Rock_C", "0xA", Destructible, {})
    local rock = instance(rock_c, "BP_Rock_C /Game/L.L:PersistentLevel.BP_Rock_C_1", { ["/Script/Dominion.WorldActor:DisplayName"] = ftext("Rock") })
    check("declared via super: value read", U.str(U.prop(rock, "DisplayName")) == "Rock")
    check("declared via super: no AV", FAKE_AV == nil)
    check("undeclared name: nil, value untouched", U.prop(rock, "ItemData") == nil and FAKE_AV == nil)
end

-- 2. THE CRASH: an AWorldActor BP class at 0x12889f99190 had DisplayName read, was GC'd, and a WorldChest BP class
--    was allocated at the same address. The raw read (old sense.lua) hits UE4SS's stale entry; U.prop never reads.
do
    U.prop_reset(); UE_CACHE = {}; FAKE_AV = nil
    local old_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Sign.BP_Sign_C", "0x12889f99190", WorldActor, {})
    local sign = instance(old_c, "BP_Sign_C /Game/L.L:PersistentLevel.BP_Sign_C_1", { ["/Script/Dominion.WorldActor:DisplayName"] = ftext("Sign") })
    check("crash setup: the old class's read caches its DisplayName", U.str(U.prop(sign, "DisplayName")) == "Sign"
        and UE_CACHE["0x12889f99190"] and UE_CACHE["0x12889f99190"].DisplayName ~= nil)
    local chest_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Chest.BP_Chest_C", "0x12889f99190", WorldChest, {})
    local chest = instance(chest_c, "BP_Chest_C /Game/L.L:PersistentLevel.BP_Chest_C_1", {})
    local raw_ok = pcall(function() return chest.DisplayName end)
    check("crash repro: the raw read faults (stale cache entry)", not raw_ok and FAKE_AV == "DisplayName", FAKE_AV)
    FAKE_AV = nil
    check("guard: U.prop on the chest returns nil", U.prop(chest, "DisplayName") == nil)
    check("guard: the value was never read", FAKE_AV == nil, FAKE_AV)
    check("guard: counted as undeclared", U.prop_stats().undeclared >= 1, U.prop_stats().undeclared)
end

-- 3. same name, another declaration: a creature BP class at 0xB (HealthComponent of DominionAICharacter) was GC'd
--    and a destructible BP class took the address. The live chain declares HealthComponent too, so only the
--    comparison with UE4SS's resolution catches it.
do
    U.prop_reset(); UE_CACHE = {}; FAKE_AV = nil
    local wolf_c = struct("BlueprintGeneratedClass", "/Game/AI/BP_Wolf.BP_Wolf_C", "0xB", AIChar, {})
    local wolf = instance(wolf_c, "BP_Wolf_C /Game/L.L:PersistentLevel.BP_Wolf_C_1", { ["/Script/Dominion.DominionAICharacter:HealthComponent"] = "hc_wolf" })
    check("cross-decl setup: creature read", U.prop(wolf, "HealthComponent") == "hc_wolf")
    local log_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Log.BP_Log_C", "0xB", Destructible, {})
    local log = instance(log_c, "BP_Log_C /Game/L.L:PersistentLevel.BP_Log_C_1", { ["/Script/Dominion.DestructibleWorldActor:HealthComponent"] = "hc_log" })
    check("cross-decl: raw read faults", not pcall(function() return log.HealthComponent end) and FAKE_AV == "HealthComponent")
    FAKE_AV = nil
    check("cross-decl: U.prop refuses (stale)", U.prop(log, "HealthComponent") == nil and FAKE_AV == nil)
    check("cross-decl: counted as stale", U.prop_stats().stale == 1, U.prop_stats().stale)
    check("cross-decl: U.health/max_health refuse too", U.health(log) == nil and U.max_health(log) == nil and FAKE_AV == nil, FAKE_AV)
    -- a fresh address resolves and reads normally
    local log2_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Log.BP_Log_C", "0xC", Destructible, {})
    local log2 = instance(log2_c, "BP_Log_C /Game/L.L:PersistentLevel.BP_Log_C_2", { ["/Script/Dominion.DestructibleWorldActor:HealthComponent"] = "hc_log2" })
    check("fresh address: reads", U.prop(log2, "HealthComponent") == "hc_log2")
end

-- 4. caches: the native levels are listed once; a walk error fails closed; plain tables (fakes) read directly
do
    U.prop_reset(); UE_CACHE = {}; FAKE_AV = nil
    local a_c = struct("BlueprintGeneratedClass", "/Game/BP_A.BP_A_C", "0xD", Destructible, {})
    local b_c = struct("BlueprintGeneratedClass", "/Game/BP_B.BP_B_C", "0xE", Destructible, {})
    local a = instance(a_c, "BP_A_C /Game/L.L:PersistentLevel.BP_A_C_1", { ["/Script/Dominion.DestructibleWorldActor:bIsHidden"] = true })
    local b = instance(b_c, "BP_B_C /Game/L.L:PersistentLevel.BP_B_C_1", { ["/Script/Dominion.DestructibleWorldActor:bIsHidden"] = false })
    walks = 0
    check("bool read", U.prop(a, "bIsHidden") == true)
    local first = walks
    check("cached: the same class+name walks no more", (function() U.prop(a, "bIsHidden"); return walks == first end)())
    walks = 0
    check("false is a value, not a miss", U.prop(b, "bIsHidden") == false)
    check("native levels listed once: a second BP class lists only its own level + the declaring one", walks <= 2, walks)
    reflections = 0
    check("verified fast path: a repeat read skips the UE4SS check", U.prop(a, "bIsHidden") == true and reflections == 0, reflections)
    -- the address is part of the key: another class at a reused address is checked again
    local c_c = struct("BlueprintGeneratedClass", "/Game/BP_C.BP_C_C", "0xD", Destructible, {})
    local c = instance(c_c, "BP_C_C /Game/L.L:PersistentLevel.BP_C_C_1", { ["/Script/Dominion.DestructibleWorldActor:bIsHidden"] = true })
    check("reused address, other class: checked again", U.prop(c, "bIsHidden") == true and reflections == 1, reflections)
    local broken_c = struct("BlueprintGeneratedClass", "/Game/BP_X.BP_X_C", "0xF", Destructible, {})
    broken_c.broken = true
    local x = instance(broken_c, "BP_X_C /Game/L.L:PersistentLevel.BP_X_C_1", {})
    check("walk error: nil, counted", U.prop(x, "DisplayName") == nil and U.prop_stats().errors == 1, U.prop_stats().errors)
    check("plain table: direct read", U.prop({ DisplayName = "t" }, "DisplayName") == "t")
    check("nil object: nil", U.prop(nil, "DisplayName") == nil)
end

-- 5. the census describers use the guard: the crash's chest in describe_interactable, a destructible in the
--    resources describer (sense.lua loads its own util instance)
do
    UE_CACHE = {}; FAKE_AV = nil
    local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()
    S.U.is_ue_object = U.is_ue_object
    S.U.prop_reset()
    local old_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Sign.BP_Sign_C", "0xAA", WorldActor, {})
    local sign = instance(old_c, "BP_Sign_C /Game/L.L:PersistentLevel.BP_Sign_C_1", { ["/Script/Dominion.WorldActor:DisplayName"] = ftext("Signpost") })
    local d1 = S._describe_interactable(sign, nil, "interactable", { X = 0, Y = 0, Z = 0 })
    check("census: a world actor keeps its DisplayName", d1 and d1.name == "Signpost", d1 and d1.name)
    local chest_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_TreasureChest.BP_TreasureChest_C", "0xAA", WorldChest, {})
    local chest = instance(chest_c, "BP_TreasureChest_C /Game/L.L:PersistentLevel.BP_TreasureChest_C_1", {})
    local ok, d2 = pcall(S._describe_interactable, chest, nil, "chest", { X = 0, Y = 0, Z = 0 })
    check("census: the chest at the reused address does not fault", ok and FAKE_AV == nil, tostring(d2) .. " " .. tostring(FAKE_AV))
    check("census: the chest is named from its class", ok and d2 and d2.name == "Treasure Chest", ok and d2 and d2.name)
end

-- 6. the other modules' speculative reads: combat.read_creature on any actor (the brain may name a chest), and
--    U.player_name on a pawn whose BP class took the address of an AI controller's (PlayerState: APawn + AController)
do
    UE_CACHE = {}; FAKE_AV = nil
    local Cb = assert(loadfile(root .. "/client_mod/scripts/combat.lua"))()
    Cb.U.is_ue_object = U.is_ue_object
    Cb.U.prop_reset()
    local wolf_c = struct("BlueprintGeneratedClass", "/Game/AI/BP_Wolf.BP_Wolf_C", "0xBB", AIChar, {})
    local wolf = instance(wolf_c, "BP_Wolf_C /Game/L.L:PersistentLevel.BP_Wolf_C_2", { ["/Script/Dominion.DominionAICharacter:PowerLevel"] = 7 })
    check("combat: a creature reads its power level", Cb.read_creature(wolf).pl == 7)
    local chest_c = struct("BlueprintGeneratedClass", "/Game/WP/BP_Chest.BP_Chest_C", "0xBB", WorldChest, {})
    local chest = instance(chest_c, "BP_Chest_C /Game/L.L:PersistentLevel.BP_Chest_C_2", {})
    check("combat: the raw read on the chest faults (stale entry)", not pcall(function() return chest.PowerLevel end) and FAKE_AV == "PowerLevel")
    FAKE_AV = nil
    local ok, d = pcall(Cb.read_creature, chest)
    check("combat: read_creature on the chest does not fault", ok and FAKE_AV == nil, tostring(d) .. " " .. tostring(FAKE_AV))
    check("combat: the chest has no power level or health", ok and d.pl == nil and d.max_hp == nil and d.hp == nil)

    U.prop_reset(); UE_CACHE = {}; FAKE_AV = nil
    local Pawn = struct("Class", "/Script/Engine.Pawn", "n6", Actor, { { "PlayerState" } })
    local Controller = struct("Class", "/Script/Engine.Controller", "n7", Actor, { { "PlayerState" } })
    local aic_c = struct("BlueprintGeneratedClass", "/Game/AI/BP_AIC_Wolf.BP_AIC_Wolf_C", "0xCC", Controller, {})
    local aic = instance(aic_c, "BP_AIC_Wolf_C /Game/L.L:PersistentLevel.BP_AIC_Wolf_C_1", { ["/Script/Engine.Controller:PlayerState"] = false })
    check("player_name setup: the controller's PlayerState is cached", U.prop(aic, "PlayerState") == false and UE_CACHE["0xCC"].PlayerState ~= nil)
    local pawn_c = struct("BlueprintGeneratedClass", "/Game/AI/BP_Golem.BP_Golem_C", "0xCC", Pawn, {})
    local golem = instance(pawn_c, "BP_Golem_C /Game/L.L:PersistentLevel.BP_Golem_C_1", {})
    check("player_name: the raw read faults", not pcall(function() return golem.PlayerState end) and FAKE_AV == "PlayerState")
    FAKE_AV = nil
    check("player_name: refuses the stale entry, falls back to the object name", U.player_name(golem) == "BP_Golem_C_1" and FAKE_AV == nil, FAKE_AV)
end

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
