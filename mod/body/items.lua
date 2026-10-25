-- World items (ARuntimeSpawnedWorldItem): read, take into the bot store, spawn from the bot store.
-- Research: docs/research/2026-10-25-woodcutting-loop.md sections 4-5; DISCOVERIES "Woodcutting
-- timeline" and "Item handling" (build 26161880).
--
-- Reads (verified live 2026-10-25 via experiments/item_probe census): w.ItemData (UItemData),
-- w:GetStackSize(), w.MagneticComponentGrantItem.{Target, bAllowAutoMagnetization,
-- bAutoMagnetizationEnabled, bHasBeenGranted, SpawnedItem}, SpawnedItem.{Count, Durability, Guid,
-- NumMasterworkUpgradesApplied}, GetMaxDurability(), ItemData.MaxStackSize.
--
-- TAKE (pickup): the game's own pickup grants into a PlayerController inventory the puppet does not
-- have (HandleInteraction / magnet: the null-PC crash class), so we never call it. Instead, in ONE
-- tick: hide the item, collision off, SetLifeSpan(0.1) (engine destroys it next tick; never an
-- immediate destroy inside a delayed-action callback, risk R6), then add the instance to the store.
-- The destroy request comes first, so a crash in between loses the item instead of duplicating it.
-- The caller verifies on a later tick that the actor is gone (and rolls the store back if not).
-- Items a player's magnet is already pulling (Target set) are left alone.
-- UNVERIFIED until the live canary: that SetLifeSpan(0.1) removes a world item cleanly on clients.
--
-- SPAWN (drop/give), two routes:
--   spawn_sync  (default) UItemHelperLibrary:SpawnAndLaunchItem_Sync(world, FItemSpawnParameters, "")
--               The game builds the world item and its replicated UItem itself (bCreateItem=true).
--               FItemSpawnParameters is a big struct and struct marshalling has crashed us before
--               (R3), so M.spawn_params fills EVERY field explicitly, object fields that must be null
--               use UE4SS CreateInvalidObject(), and the route must pass an OFFLINE canary
--               (experiments/item_probe drop, no players) before it is used with Luis around.
--   spawn_actor (opt-in, opts.route) SpawnActor(BP_RuntimeSpawnedWorldItem_NoExpiry_C) + property
--               writes (ItemData, the magnet's ItemData, SpawnedItem.Count) + OnRep_*. Needs the
--               actor to have built its own UItem; if it has not, the actor is removed and the drop
--               fails (never leave a half-built replicated item: the client-freeze lesson).
-- Both: success = an alive world item near the requested spot with the right ItemData and stack.
-- Instance state (level, durability, enchant) is NOT carried into a spawned item yet: the game makes
-- a fresh base UItem. Callers report instance_state_lost for such items. (CopiedItem would carry a
-- genuine UItem; we have none for items the bot picked up earlier.)
local U = require("body.util")

local M = {}

M.WORLD_ITEM_CLASS = "RuntimeSpawnedWorldItem"
M.PATHS = {
    noexpiry = "/Game/Gameplay/WorldItems/BP_RuntimeSpawnedWorldItem_NoExpiry.BP_RuntimeSpawnedWorldItem_NoExpiry_C",
    helper = "/Script/Dominion.Default__ItemHelperLibrary",
}
M.ROUTES = {
    spawn_sync = { verified = false },   -- flip after the offline canary + Luis sees/picks up the item
    spawn_actor = { verified = false },
}
M.DEFAULT_ROUTE = "spawn_sync"
M.REMOVE_LIFESPAN_S = 0.1
M.SPAWN_RAISE_CM = 30          -- spawn a little above the requested point; the floor check settles it
M.VERIFY_NEAR_CM = 500         -- a spawned item must be within this of the requested spot (2D)

local function rd(o, k) return U.try(function() return o[k] end) end

-- TArray -> Lua list via ForEach (UE4SS), each element mapped by fn(elem) (nil results skipped).
local function each(arr, fn)
    local out = {}
    if arr == nil then return out end
    pcall(function()
        arr:ForEach(function(_, e)
            local v = U.try(function() return fn(e:get()) end)
            if v ~= nil then out[#out + 1] = v end
        end)
    end)
    return out
end

-- Instance fields from a UItem (UEquipment / UHeldEquipmentItem extras when present).
function M.instance_of(it)
    if not U.valid(it) then return {} end
    local inst = {
        durability = tonumber(rd(it, "Durability")),
        max_durability = tonumber(U.try(function() return it:GetMaxDurability() end)),
        level = tonumber(rd(it, "NumMasterworkUpgradesApplied")) or 0,
        guid = U.guid_hex(rd(it, "Guid")),
    }
    local enchant = U.path_of(U.try(function() return it.CurrentMagicalHeldEquipmentEffectInstance.Data end))
    if enchant then inst.enchant = enchant end
    local ench = each(rd(it, "EnchantmentGameplayEffects"), function(c) return U.path_of(c) end)
    if #ench > 0 then inst.enchantments = ench end
    local tags = each(U.try(function() return it.GameplayTags.GameplayTags end), function(t) return U.str(t.TagName) end)
    if #tags > 0 then inst.tags = tags end
    return inst
end

-- Everything we need to know about one world item, or nil if it is not a live world item.
function M.read(w)
    if not U.alive(w) then return nil end
    local data = rd(w, "ItemData")
    local path = U.path_of(data)
    if not path then return nil end
    local mag = rd(w, "MagneticComponentGrantItem")
    local uitem = U.valid(mag) and rd(mag, "SpawnedItem") or nil
    local count = tonumber(U.try(function() return w:GetStackSize() end)) or tonumber(uitem and rd(uitem, "Count"))
    local target = U.valid(mag) and rd(mag, "Target") or nil
    return {
        actor = w, id = U.short(w), item_data_path = path, item = path:match("%.([%w_]+)$") or path,
        name = U.str(U.try(function() return data.Name end)),
        count = count, max_stack = tonumber(rd(data, "MaxStackSize")),
        loc = U.loc(w),
        magnet_target = U.valid(target) and U.short(target) or nil,
        granted = U.valid(mag) and rd(mag, "bHasBeenGranted") == true or false,
        manipulated = U.try(function() return w:IsBeingManipulated() end) == true,
        uitem = uitem,
    }
end

-- Case-insensitive match of a query against the item id, display name or full path.
function M.matches(info, query)
    if query == nil or query == "" then return true end
    local q = tostring(query):lower()
    return (info.item or ""):lower():find(q, 1, true) ~= nil
        or (info.name or ""):lower():find(q, 1, true) ~= nil
        or (info.item_data_path or ""):lower() == q
end

-- Is this item free for the bot to take? (not being pulled by a player's magnet, not granted)
function M.available(info)
    return info ~= nil and info.magnet_target == nil and not info.granted and not info.manipulated and (info.count or 0) > 0
end

-- World items within radius_cm of origin, nearest first. opts: {origin, radius_cm, item, all=true
-- to include unavailable ones, max}
function M.find(opts)
    opts = opts or {}
    local out = {}
    for _, w in ipairs(U.find_all(M.WORLD_ITEM_CLASS, { skip_defaults = true })) do
        local info = M.read(w)
        if info and (opts.all or M.available(info)) and M.matches(info, opts.item) then
            info.dist = opts.origin and U.dist(opts.origin, info.loc) or 0
            if not opts.radius_cm or info.dist <= opts.radius_cm then out[#out + 1] = info end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    if opts.max then for i = #out, opts.max + 1, -1 do out[i] = nil end end
    return out
end

function M.by_id(id)
    if type(id) ~= "string" or id == "" then return nil end
    for _, w in ipairs(U.find_all(M.WORLD_ITEM_CLASS, { skip_defaults = true })) do
        if U.short(w) == id then return w end
    end
end

-- Gone = destroyed or destroying (garbage / invalid / no longer listed).
function M.is_gone(w)
    if w == nil or not U.alive(w) then return true end
    local life = tonumber(U.try(function() return w:GetLifeSpan() end))
    return false, life
end

-- Remove world item `w` and add its contents to the store `inv` in the same tick.
-- Returns {ok, reason, data = {item, count, ids, world_item, instance}}.
function M.take_world_item(log, w, inv)
    local info = M.read(w)
    if not info then return U.fail("unknown_target", { detail = "not a live world item" }) end
    if not M.available(info) then
        return U.fail("unknown_target", { world_item = info.id, detail = "a player is collecting it", magnet_target = info.magnet_target })
    end
    local inst = M.instance_of(info.uitem)
    inst.item_data_path, inst.item, inst.count = info.item_data_path, info.item, info.count
    inst.max_stack, inst.name, inst.source = info.max_stack, info.name, "pickup"
    local ok, err = U.call(log, "items.remove_world_item", { id = info.id, item = info.item, count = info.count }, function()
        w:SetActorHiddenInGame(true)
        w:SetActorEnableCollision(false)
        w:SetLifeSpan(M.REMOVE_LIFESPAN_S)
    end)
    if not ok then return U.fail("body_error", { world_item = info.id, detail = tostring(err) }) end
    local added, why = inv.add(inst)
    if not added then return U.fail("body_error", { world_item = info.id, detail = "store refused: " .. tostring(why) }) end
    return U.ok({ item = info.item, count = info.count, ids = added.ids, world_item = info.id,
                  item_data_path = info.item_data_path, name = info.name })
end

-- ------------------------------------------------------------------ spawning
local function null_object()
    if type(CreateInvalidObject) == "function" then return CreateInvalidObject() end
    return nil
end

-- Every FItemSpawnParameters field (Dominion.hpp:4111), in declaration order. Nothing is left to
-- UE4SS's defaults. `at` is cm.
function M.spawn_params(cls, data, count, at, opts)
    opts = opts or {}
    local none = null_object()
    return {
        ItemClass = cls,
        bCreateItem = true,
        bMagnetize = false,
        SpawnedItemData = data,
        CopiedItem = opts.copied_item or none,
        Count = math.floor(count),
        Transform = {
            Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
            Translation = { X = at.X, Y = at.Y, Z = at.Z + M.SPAWN_RAISE_CM },
            Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
        },
        LaunchDirection = { X = 0.0, Y = 0.0, Z = 1.0 },
        LaunchSpeed = opts.launch_speed or 0.0,
        LaunchAngleVariance = 0.0,
        bSkipFloorSafetyCheck = false,
        OwnerController = none,
        bSpawnOnlyForController = false,       -- true would make a client-only item
        PlayerControllerThatDroppedItem = none,
        bAddToWorldItemRuntimeCache = true,
        bMagnetizeToInstigatorOnSpawn = false,
    }
end

local function spawn_sync(log, world, data, count, at, opts)
    local helper = U.find_object(M.PATHS.helper)
    local cls = U.find_object(M.PATHS.noexpiry)
    if not helper then return nil, "ItemHelperLibrary CDO not found" end
    if not cls then return nil, "world item class not loaded" end
    local params = M.spawn_params(cls, data, count, at, opts)
    local w
    local ok, err = U.call(log, "items.SpawnAndLaunchItem_Sync", { item = U.path_of(data), count = count, at = U.to_wire(at) }, function()
        w = helper:SpawnAndLaunchItem_Sync(world, params, "")
    end)
    if not ok then return nil, tostring(err) end
    return w
end

local function spawn_actor(log, world, data, count, at)
    local cls = U.find_object(M.PATHS.noexpiry)
    if not cls then return nil, "world item class not loaded" end
    local w
    local ok, err = U.call(log, "items.spawn_actor", { item = U.path_of(data), count = count }, function()
        w = world:SpawnActor(cls, { X = at.X, Y = at.Y, Z = at.Z + M.SPAWN_RAISE_CM }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(w) then return nil, ok and "SpawnActor returned invalid" or tostring(err) end
    local mag = rd(w, "MagneticComponentGrantItem")
    local it = U.valid(mag) and rd(mag, "SpawnedItem") or nil
    if not U.valid(it) then
        U.call(log, "items.spawn_actor_discard", { reason = "no SpawnedItem" }, function() w:SetLifeSpan(M.REMOVE_LIFESPAN_S) end)
        return nil, "spawned world item has no UItem (refusing a half-built item)"
    end
    ok, err = U.call(log, "items.spawn_actor_props", { item = U.path_of(data), count = count }, function()
        it:SetItemData(data)
        it.Count = math.floor(count)
        it:OnRep_Count()
        mag.ItemData = data
        w.ItemData = data
        w:OnRep_ItemData()
        w:ForceNetUpdate()
    end)
    if not ok then
        pcall(function() w:SetLifeSpan(M.REMOVE_LIFESPAN_S) end)
        return nil, tostring(err)
    end
    return w
end

-- Spawn one world item of `count` x `data` at `at` (cm). opts: {route, launch_speed}.
-- Returns {ok, reason, data = {id, actor, route, stack, position}}. Verified by reading it back.
function M.spawn_world_item(log, world, data, count, at, opts)
    opts = opts or {}
    local route = opts.route or M.DEFAULT_ROUTE
    if route ~= "spawn_sync" and route ~= "spawn_actor" then return U.fail("invalid_args", { detail = "unknown route " .. tostring(route) }) end
    if not (U.valid(world) and U.valid(data) and at and (tonumber(count) or 0) >= 1) then
        return U.fail("invalid_args", { detail = "world, item data, count >= 1 and a location are required" })
    end
    local w, err
    if route == "spawn_sync" then w, err = spawn_sync(log, world, data, count, at, opts)
    else w, err = spawn_actor(log, world, data, count, at) end
    if not w then return U.fail("body_error", { route = route, detail = err }) end
    local info = M.read(w)
    local res = { route = route, id = info and info.id or U.short(w), actor = w,
                  stack = info and info.count, position = info and U.to_wire(info.loc) }
    local want = U.path_of(data)
    local problem
    if not info then problem = "no live world item came back"
    elseif info.item_data_path ~= want then problem = "item data mismatch: " .. tostring(info.item_data_path)
    elseif info.count ~= math.floor(count) then problem = "stack " .. tostring(info.count) .. " ~= " .. tostring(count)
    elseif U.dist2d(info.loc, at) > M.VERIFY_NEAR_CM then problem = "spawned too far from the requested spot" end
    -- spawned = a real world item with the right data exists (the caller must not refund the store)
    res.spawned = info ~= nil and info.item_data_path == want
    if problem then
        res.detail = problem
        if U.valid(w) and info and info.item_data_path ~= want then
            -- a wrong item must never stay in the world
            U.call(log, "items.spawn_discard", { id = res.id, problem = problem }, function() w:SetLifeSpan(M.REMOVE_LIFESPAN_S) end)
        end
        return U.fail("verification_failed", res)
    end
    return U.ok(res)
end

return M
