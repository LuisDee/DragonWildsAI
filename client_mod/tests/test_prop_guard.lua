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

-- 7. vault reads (sense.lua "vaults", docs/research/2026-11-17-vault-reads.md): a fake actor of each class the note
--    names (field names from dump 26574459), every read through U.prop. What reads is told; a read that fails or gives
--    nil adds no field and the census (look) still lists the thing; a stale cache entry is refused, never read.
do
    UE_CACHE = {}; FAKE_AV = nil
    local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()
    S.U.is_ue_object = U.is_ue_object
    S.U.prop_reset()
    local clock = 0
    S.vault_clock = function() return clock end
    local function fresh() clock = clock + S.VAULT_TTL_S + 1 end
    local BP = "BlueprintGeneratedClass"
    local function at(x, y, z) return function() return { X = x, Y = y, Z = z } end end
    local function arr(items) return { ForEach = function(_, cb) for i, v in ipairs(items) do if cb(i, v) then break end end end } end
    local function cm(x, y, z) return { X = x, Y = y, Z = z } end

    -- native classes
    local Registry = struct("Class", "/Script/Dominion.GameplayObjectRegistry", "v01", Actor, { { "Dungeons", "ArrayProperty" } })
    local Audio = struct("Class", "/Script/Dominion.LocalPlayerAudioSubsystem", "v02", Object, { { "bInDungeon", "BoolProperty" } })
    local Target = struct("Class", "/Script/Dominion.TeleportationTarget", "v03", Actor, { { "TargetName", "NameProperty" } })
    local SwitchBase = struct("Class", "/Script/Dominion.SwitchBase", "v04", WorldActor,
        { { "Switchables", "ArrayProperty" }, { "SwitchState", "StructProperty" } })
    local ISwitch = struct("Class", "/Script/Dominion.InteractableSwitch", "v05", SwitchBase,
        { { "InteractionComponent" }, { "HighestPosition", "ByteProperty" } })
    local SwActor = struct("Class", "/Script/Dominion.SwitchableActor", "v06", WorldActor, {})
    local STrap = struct("Class", "/Script/Dominion.SwitchableTrap", "v07", SwActor, { { "TrapBehaviourModules", "ArrayProperty" } })
    local ATrap = struct("Class", "/Script/Dominion.AnimatingTrap", "v08", STrap, { { "UserReadableName", "TextProperty" } })
    local Module = struct("Class", "/Script/Dominion.TrapBehaviourModule", "v09", Object, { { "bActive", "BoolProperty" } })
    local VChest = struct("Class", "/Script/Dominion.WorldChest", "v10", Actor,
        { { "InventoryComponent" }, { "ChestRespawnProfile", "StructProperty" }, { "ChestState", "EnumProperty" } })
    local Dungeon = struct("Class", "/Script/Dominion.Dungeon", "v11", Actor,
        { { "BoxComponent" }, { "DungeonUserVisibleName", "TextProperty" } })
    local Scene = struct("Class", "/Script/Engine.SceneComponent", "v12", Object, { { "AttachParent" }, { "RelativeLocation", "StructProperty" },
        { "RelativeRotation", "StructProperty" }, { "RelativeScale3D", "StructProperty" } })
    local Box = struct("Class", "/Script/Engine.BoxComponent", "v13", Scene, { { "BoxExtent", "StructProperty" } })
    -- Blueprint classes (BP headers: the plain and the _Locked teleporter both derive from AWorldActor and each declares its own
    -- TeleportDestinationName)
    local tp_c = struct(BP, "/Game/Gameplay/World/Misc/BP_InteractablePlayerTeleporter.BP_InteractablePlayerTeleporter_C", "0xV1",
        WorldActor, { { "Interaction" }, { "TeleportDestinationName", "NameProperty" } })
    local tpl_c = struct(BP, "/Game/Gameplay/World/Misc/BP_InteractablePlayerTeleporter_Locked.BP_InteractablePlayerTeleporter_Locked_C",
        "0xV2", WorldActor, { { "Interaction" }, { "TeleportDestinationName", "NameProperty" }, { "IsUnlocked", "BoolProperty" } })
    local lever_c = struct(BP, "/Game/Gameplay/World/Mechanisms/BP_BinaryLever.BP_BinaryLever_C", "0xV3", ISwitch, {})
    local chest_c = struct(BP, "/Game/Vault/BP_VaultChest.BP_VaultChest_C", "0xV4", VChest, {})
    local trap_c = struct(BP, "/Game/Vault/BP_FireTrap.BP_FireTrap_C", "0xV5", ATrap, {})
    local door_c = struct(BP, "/Game/Vault/BP_FinalDoor_vault_Refactored.BP_FinalDoor_vault_Refactored_C", "0xV6", SwActor, {})
    local L = "/Game/Maps/World/L_World.L_World:PersistentLevel."
    local function key(st, name) return st.path .. ":" .. name end

    -- the world: he stands at (0, 0, 0); the vault "Crasorak Kara" is the box x 1000..5000, y -2000..2000, z -500..500
    local W = { me = cm(0, 0, 0), ics = {}, all = {} }
    local pawn = { IsValid = function() return true end, K2_GetActorLocation = function() return W.me end,
                   GetFullName = function() return "BP_PlayerCharacter_C " .. L .. "BP_PlayerCharacter_C_1" end }
    local pc = { IsValid = function() return true end, IsLocalController = function() return true end, Pawn = pawn,
                 GetFullName = function() return "BP_PlayerController_C " .. L .. "BP_PlayerController_C_1" end }
    function FindAllOf(cls)
        if cls == "BP_PlayerController_C" then return { pc } end
        if cls == "InteractionComponent" then return W.ics end
        return W.all[cls] or {}
    end
    local function add(cls, o) W.all[cls] = W.all[cls] or {}; table.insert(W.all[cls], o); return o end
    local function interactable(a, prompt, x, y, z)
        W.ics[#W.ics + 1] = { IsValid = function() return true end, GetOwner = function() return a end, InteractionPrompt = ftext(prompt),
            K2_GetComponentLocation = at(x, y, z), GetFullName = function() return "InteractionComponent " .. U.path_of(a) .. ".Interaction" end }
        return a
    end
    local vault_box = { min = cm(1000, -2000, -500), max = cm(5000, 2000, 500), IsValid = true }
    local dungeons = { { UserVisibleName = ftext("Crasorak Kara"), Box = vault_box } }
    local reg = add("GameplayObjectRegistry", instance(Registry, "GameplayObjectRegistry " .. L .. "GameplayObjectRegistry_1",
        { [key(Registry, "Dungeons")] = arr(dungeons) }))
    local audio_vals = { [key(Audio, "bInDungeon")] = false }
    add("LocalPlayerAudioSubsystem", instance(Audio, "LocalPlayerAudioSubsystem /Engine/Transient.GameEngine_1:LocalPlayer_1.LocalPlayerAudioSubsystem_1", audio_vals))
    add("TeleportationTarget", instance(Target, "TeleportationTarget " .. L .. "TeleportationTarget_1",
        { [key(Target, "TargetName")] = ftext("CK_Inside") }, { K2_GetActorLocation = at(3000, 0, 0) }))
    add("TeleportationTarget", instance(Target, "TeleportationTarget " .. L .. "TeleportationTarget_2",
        { [key(Target, "TargetName")] = ftext("CK_Outside") }, { K2_GetActorLocation = at(-500, 0, 0) }))
    local door = instance(door_c, "BP_FinalDoor_vault_Refactored_C " .. L .. "BP_FinalDoor_vault_Refactored_C_1", {})
    local tp_vals = { [key(tp_c, "TeleportDestinationName")] = ftext("CK_Inside") }
    interactable(instance(tp_c, "BP_InteractablePlayerTeleporter_C " .. L .. "BP_InteractablePlayerTeleporter_C_1", tp_vals,
        { K2_GetActorLocation = at(500, 0, 0) }), "Enter", 500, 0, 0)
    local tpl_vals = { [key(tpl_c, "TeleportDestinationName")] = ftext("CK_Outside"), [key(tpl_c, "IsUnlocked")] = false }
    interactable(instance(tpl_c, "BP_InteractablePlayerTeleporter_Locked_C " .. L .. "BP_InteractablePlayerTeleporter_Locked_C_1", tpl_vals,
        { K2_GetActorLocation = at(600, 0, 0) }), "Enter", 600, 0, 0)
    local lever_vals = { [key(SwitchBase, "SwitchState")] = { ServerTimeOfInteraction = 12.5, SwitchPosition = 1 },
                         [key(ISwitch, "HighestPosition")] = 1, [key(SwitchBase, "Switchables")] = arr({ door }) }
    interactable(instance(lever_c, "BP_BinaryLever_C " .. L .. "BP_BinaryLever_C_1", lever_vals, { K2_GetActorLocation = at(700, 0, 0) }),
        "Pull", 700, 0, 0)
    local chest_vals = { [key(VChest, "ChestState")] = 2 }
    add("WorldChest", interactable(instance(chest_c, "BP_VaultChest_C " .. L .. "BP_VaultChest_C_1", chest_vals,
        { K2_GetActorLocation = at(800, 0, 0) }), "Open", 800, 0, 0))
    local m_on = instance(Module, "TrapDamageModule " .. L .. "BP_FireTrap_C_1.TrapDamageModule_1", { [key(Module, "bActive")] = true })
    local m_off = instance(Module, "TrapCollisionModule " .. L .. "BP_FireTrap_C_1.TrapCollisionModule_1", { [key(Module, "bActive")] = false })
    local trap_vals = { [key(ATrap, "UserReadableName")] = ftext("Fire Jet"), [key(STrap, "TrapBehaviourModules")] = arr({ m_on, m_off }) }
    add("SwitchableTrap", instance(trap_c, "BP_FireTrap_C " .. L .. "BP_FireTrap_C_1", trap_vals, { K2_GetActorLocation = at(900, 0, 0) }))

    local function census() fresh(); return S.census(nil, { radius_m = 30 }) end
    local function row(c, word)
        for _, cat in ipairs({ "interactables", "hazards" }) do
            for _, d in ipairs(c[cat] or {}) do if tostring(d.id):find(word, 1, true) then return d, cat end end
        end
    end
    local c = census()
    check("vault: the census reads", c and c.ok == true, c and c.reason)
    check("vault: no raw read faulted", FAKE_AV == nil, FAKE_AV)
    check("vault: outside, the game's flag says so and no vault is named", c.in_vault == false and c.vault == nil, tostring(c.vault))
    local t = row(c, "Teleporter_C_1")
    check("vault: a door says where it leads (its target stands in the vault's box)",
        t and t.destination == "CK_Inside" and t.leads_to == "Crasorak Kara" and t.arrives_at and t.arrives_at[1] == 30 and t.locked == nil,
        t and (tostring(t.destination) .. " " .. tostring(t.leads_to)))
    check("vault: a door keeps its prompt and name", t and t.prompt == "Enter" and t.name == "Interactable Player Teleporter", t and t.name)
    t = row(c, "Locked_C_1")
    check("vault: a locked door says it is locked, and leads outside (every vault's box is known)",
        t and t.locked == true and t.leads_to == "outside" and t.destination == "CK_Outside", t and tostring(t.leads_to))
    local lv = row(c, "BinaryLever")
    check("vault: a lever's raw position, its highest, and what it drives",
        lv and lv.switch_position == 1 and lv.switch_highest == 1 and lv.drives and lv.drives[1] == "BP_FinalDoor_vault_Refactored_C_1",
        lv and tostring(lv.switch_position))
    local ch = row(c, "VaultChest")
    check("vault: a chest's state", ch and ch.kind == "chest" and ch.chest_state == "emptied", ch and tostring(ch.chest_state))
    local tr, tcat = row(c, "FireTrap")
    check("vault: a trap is a hazard with its name and its active parts",
        tr and tcat == "hazards" and tr.kind == "trap" and tr.name == "Fire Jet" and tr.parts == 2 and tr.active_parts == 1,
        tr and (tostring(tcat) .. " " .. tostring(tr.name) .. " " .. tostring(tr.parts)))
    check("vault: no vault field on a thing that is none of these",
        t and t.switch_position == nil and t.chest_state == nil and lv.destination == nil and lv.chest_state == nil)

    -- inside: the flag and the box agree
    W.me = cm(3000, 100, 0); audio_vals[key(Audio, "bInDungeon")] = true
    c = census()
    check("vault: inside, in_vault and the vault's name", c.in_vault == true and c.vault == "Crasorak Kara", tostring(c.vault))
    check("vault: still no fault", FAKE_AV == nil, FAKE_AV)

    -- reads that fail or give nothing: nothing false is said, every thing is still listed
    W.me = cm(0, 0, 0)
    reg = nil; W.all.GameplayObjectRegistry = nil -- no registry, no Dungeon actors: no vault box is known
    W.all.LocalPlayerAudioSubsystem = nil         -- no subsystem: no flag
    tp_vals[key(tp_c, "TeleportDestinationName")] = ftext("None")
    tpl_vals[key(tpl_c, "IsUnlocked")] = nil
    lever_vals[key(SwitchBase, "SwitchState")] = nil
    lever_vals[key(SwitchBase, "Switchables")] = { ForEach = function() error("array gone") end }
    chest_vals[key(VChest, "ChestState")] = 7
    trap_vals[key(ATrap, "UserReadableName")] = nil
    trap_vals[key(STrap, "TrapBehaviourModules")] = nil
    c = census()
    check("vault (unread): the census still reads and lists all five", c and c.ok == true
        and #(c.interactables or {}) == 4 and #(c.hazards or {}) == 1, c and #(c.interactables or {}))
    check("vault (unread): no in_vault, no vault", c.in_vault == nil and c.vault == nil)
    t = row(c, "Teleporter_C_1")
    check("vault (unread): a destination of None is no destination", t and t.destination == nil and t.leads_to == nil and t.prompt == "Enter")
    t = row(c, "Locked_C_1")
    check("vault (unread): no vault box known -> no 'outside' claim; no lock state read -> no locked",
        t and t.destination == "CK_Outside" and t.arrives_at ~= nil and t.leads_to == nil and t.locked == nil, t and tostring(t.leads_to))
    lv = row(c, "BinaryLever")
    check("vault (unread): a lever whose state does not read says no position", lv and lv.switch_position == nil and lv.drives == nil
        and lv.prompt == "Pull")
    ch = row(c, "VaultChest")
    check("vault (unread): a chest state outside the enum is not told", ch and ch.chest_state == nil and ch.kind == "chest")
    tr = row(c, "FireTrap")
    check("vault (unread): a trap with no name or modules: its class word, no parts", tr and tr.name == "Fire Trap" and tr.parts == nil,
        tr and tr.name)
    -- a target name two targets share: no arrival point
    add("TeleportationTarget", instance(Target, "TeleportationTarget " .. L .. "TeleportationTarget_3",
        { [key(Target, "TargetName")] = ftext("CK_Outside") }, { K2_GetActorLocation = at(9000, 0, 0) }))
    c = census()
    t = row(c, "Locked_C_1")
    check("vault (unread): two targets of one name -> no arrives_at", t and t.destination == "CK_Outside" and t.arrives_at == nil)
    -- the whole vault_row failing leaves the row as it was
    local real = S.teleport_targets
    S.teleport_targets = function() error("boom") end
    c = census()
    t = row(c, "Locked_C_1")
    check("vault (unread): an error inside the vault reads leaves the row listed", c.ok and t and t.prompt == "Enter" and t.name ~= nil)
    S.teleport_targets = real
    check("vault (unread): no fault", FAKE_AV == nil, FAKE_AV)

    -- the ADungeon actors when the registry has nothing: a box turned 90 degrees (8000 long in x before the turn)
    local function dungeon(name, mid, ext, yaw, attached)
        local box = instance(Box, "BoxComponent " .. L .. "Dungeon_" .. name .. ".BoxComponent", {
            [key(Scene, "AttachParent")] = attached, [key(Scene, "RelativeLocation")] = mid,
            [key(Scene, "RelativeRotation")] = { Pitch = 0, Yaw = yaw, Roll = 0 }, [key(Scene, "RelativeScale3D")] = cm(1, 1, 1),
            [key(Box, "BoxExtent")] = ext })
        return add("Dungeon", instance(Dungeon, "Dungeon " .. L .. "Dungeon_" .. name, {
            [key(Dungeon, "DungeonUserVisibleName")] = ftext(name), [key(Dungeon, "BoxComponent")] = box },
            { K2_GetActorLocation = function() return mid end }))
    end
    dungeon("Vertentis Kara", cm(20000, 0, 0), cm(4000, 1000, 500), 90, nil)
    add("LocalPlayerAudioSubsystem", instance(Audio, "LocalPlayerAudioSubsystem /Engine/Transient.GameEngine_1:LocalPlayer_1.LocalPlayerAudioSubsystem_1", audio_vals))
    W.me = cm(20500, 3500, 0) -- inside only because the box is turned
    c = census()
    check("vault (actor box): the turned box holds him", c.vault == "Vertentis Kara" and c.in_vault == true, tostring(c.vault))
    W.me = cm(23500, 500, 0)
    c = census()
    check("vault (actor box): outside the turned box he is in none", c.vault == nil, tostring(c.vault))
    local _, complete = S.vault_list()
    check("vault (actor box): every actor box read -> complete", complete == true)
    dungeon("Attached Area", cm(0, 0, 0), cm(100, 100, 100), 0, door) -- attached: its relative transform is not its world one
    fresh()
    local list
    list, complete = S.vault_list()
    check("vault (actor box): an attached box is not used, and the list is no longer complete", #list == 1 and complete == false, #list)
    check("vault (actor box): no fault", FAKE_AV == nil, FAKE_AV)

    -- R17: a chest Blueprint class at the address a lever class had; a Locked teleporter class at the address the plain one had
    UE_CACHE = {}; FAKE_AV = nil; S.U.prop_reset()
    local lev2_c = struct(BP, "/Game/WP/BP_BinaryLever.BP_BinaryLever_C", "0xR1", ISwitch, {})
    local lev2 = instance(lev2_c, "BP_BinaryLever_C " .. L .. "BP_BinaryLever_C_9",
        { [key(SwitchBase, "SwitchState")] = { SwitchPosition = 0 } })
    local d0 = {}
    S.vault_row(lev2, d0)
    check("stale setup: the lever reads its position", d0.switch_position == 0 and UE_CACHE["0xR1"].SwitchState ~= nil)
    local ch2_c = struct(BP, "/Game/WP/BP_VaultChest.BP_VaultChest_C", "0xR1", VChest, {})
    local ch2 = instance(ch2_c, "BP_VaultChest_C " .. L .. "BP_VaultChest_C_9", { [key(VChest, "ChestState")] = 1 })
    check("stale: the raw SwitchState read on the chest faults", not pcall(function() return ch2.SwitchState end) and FAKE_AV == "SwitchState")
    FAKE_AV = nil
    local d1 = { kind = "chest" }
    local ok1 = pcall(S.vault_row, ch2, d1)
    check("stale: vault_row on the chest never reads SwitchState, and reads its own ChestState",
        ok1 and FAKE_AV == nil and d1.switch_position == nil and d1.chest_state == "opened", tostring(FAKE_AV) .. " " .. tostring(d1.chest_state))
    local tpa_c = struct(BP, "/Game/WP/BP_InteractablePlayerTeleporter.BP_InteractablePlayerTeleporter_C", "0xR2", WorldActor,
        { { "TeleportDestinationName", "NameProperty" } })
    local tpa = instance(tpa_c, "BP_InteractablePlayerTeleporter_C " .. L .. "BP_InteractablePlayerTeleporter_C_9",
        { [key(tpa_c, "TeleportDestinationName")] = ftext("A") })
    local d2 = {}
    S.vault_row(tpa, d2)
    check("stale setup: the plain teleporter reads its destination", d2.destination == "A")
    local tpb_c = struct(BP, "/Game/WP/BP_InteractablePlayerTeleporter_Locked.BP_InteractablePlayerTeleporter_Locked_C", "0xR2",
        WorldActor, { { "TeleportDestinationName", "NameProperty" }, { "IsUnlocked", "BoolProperty" } })
    local tpb = instance(tpb_c, "BP_InteractablePlayerTeleporter_Locked_C " .. L .. "BP_InteractablePlayerTeleporter_Locked_C_9",
        { [key(tpb_c, "TeleportDestinationName")] = ftext("B"), [key(tpb_c, "IsUnlocked")] = true })
    check("stale: the raw read on the Locked class faults (the cache holds the plain class's declaration)",
        not pcall(function() return tpb.TeleportDestinationName end) and FAKE_AV == "TeleportDestinationName")
    FAKE_AV = nil
    local d3 = {}
    local ok3 = pcall(S.vault_row, tpb, d3)
    check("stale: vault_row refuses it (no destination said) and does not fault", ok3 and FAKE_AV == nil and d3.destination == nil,
        tostring(FAKE_AV) .. " " .. tostring(d3.destination))
    check("stale: counted", S.U.prop_stats().stale >= 1, S.U.prop_stats().stale)
end

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
