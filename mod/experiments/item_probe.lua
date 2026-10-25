-- Item handling probe (W6/W7 of docs/research/2026-10-25-woodcutting-loop.md section 8).
-- debug_run {module="item_probe", args={action=...}}. Default action "census" is READ-ONLY.
--
--   census {radius_m=15}      read-only: the puppet's and the players' BP_Components_ItemMagnet,
--                             the ItemMagnetizationSubsystem, and every RuntimeSpawnedWorldItem within
--                             radius of the puppet or a player (item data, stack, UItem instance
--                             fields, magnet target, auto-magnetise flags, expiry).
--   watch {seconds=60, radius_m=10}  read-only 1 s poll of world items near the PUPPET: logs
--                             appear/update/gone with the magnet Target, so we can see whether items
--                             fly to the puppet (and vanish into a null inventory) or to a player.
--                             Output: "item_probe_watch" events in logs/mod/mod_*.jsonl.
--   take {target, state_path} PICKUP canary on ONE world item: the body/inventory + body/items route
--                             (hide, no collision, SetLifeSpan(0.1), add to a TEST store file).
--                             Refuses without state_path (never the live bot state).
--   drop {item_path, count, confirm="offline_canary"}  DROP canary (SpawnAndLaunchItem_Sync, built
--                             by body/items.lua). Refuses while any player is connected unless
--                             confirm="luis_ok" (struct marshalling: the R3 crash class).
local U = require("body.util")
local M = {}

local function fresh(name)
    -- body.* modules not loaded at server start are loaded fresh from disk here (loadfile), so a
    -- redeploy is picked up without a restart. Never used for modules main.lua already loaded.
    local root = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]experiments[/\\][^/\\]*$")) or "."
    local chunk = assert(loadfile(root .. "/body/" .. name .. ".lua"))
    return chunk()
end

local function rd(o, k) return U.try(function() return o[k] end) end

local function magnet_info(pawn)
    local m = rd(pawn, "BP_Components_ItemMagnet")
    if not U.valid(m) then return { present = false } end
    return {
        present = true, name = U.fullname(m), range = rd(m, "MagnetRange"),
        active = U.try(function() return m:IsActive() end),
        auto_activate = rd(m, "bAutoActivate"),
        component_tick = U.try(function() return m:IsComponentTickEnabled() end),
    }
end

local function uitem_info(it)
    if not U.valid(it) then return nil end
    return {
        name = U.fullname(it), count = rd(it, "Count"), durability = rd(it, "Durability"),
        max_durability = U.try(function() return it:GetMaxDurability() end),
        masterwork = rd(it, "NumMasterworkUpgradesApplied"),
        guid = U.guid_hex(rd(it, "Guid")),
        enchants = U.try(function() return #it.EnchantmentGameplayEffects end),
        magic_effect = U.fullname(U.try(function() return it.CurrentMagicalHeldEquipmentEffectInstance.Data end)),
        physical_effect = U.fullname(U.try(function() return it.CurrentPhysicalHeldEquipmentEffectInstance.Data end)),
    }
end

local function world_item_info(w, origins)
    local mag = rd(w, "MagneticComponentGrantItem")
    local data = rd(w, "ItemData")
    local l = U.loc(w)
    local near = {}
    for name, o in pairs(origins) do near[name] = U.cm_to_m(U.dist(l, o)) end
    return {
        id = U.short(w), class = U.class_word(w), item = U.path_of(data),
        max_stack = data and rd(data, "MaxStackSize"),
        stack = U.try(function() return w:GetStackSize() end),
        manipulated = U.try(function() return w:IsBeingManipulated() end),
        can_expire = rd(w, "bCanExpire"), cache = rd(w, "bCacheInWorldItemRuntimeCache"),
        dropped_by = U.str(rd(w, "NameOfPlayerCharacterThatDroppedItem")),
        position = U.to_wire(l), dist_m = near,
        magnet = U.valid(mag) and {
            target = U.short(rd(mag, "Target")), allow_auto = rd(mag, "bAllowAutoMagnetization"),
            auto_enabled = rd(mag, "bAutoMagnetizationEnabled"), category = rd(mag, "AutoMagnetizationCategory"),
            granted = rd(mag, "bHasBeenGranted"), min_time = rd(mag, "MinTimeBeforeMoving"),
            contact = rd(mag, "ContactRange"), data = U.path_of(rd(mag, "ItemData")),
        } or nil,
        uitem = uitem_info(mag and rd(mag, "SpawnedItem")),
    }
end

local function origins()
    local players, puppets = U.split_pawns()
    local o = {}
    for i, p in ipairs(players) do o["player" .. i] = U.loc(p) end
    if puppets[1] then o.puppet = U.loc(puppets[1]) end
    return o, players, puppets
end

local function items_near(orig, radius_cm)
    local out = {}
    for _, w in ipairs(U.find_all("RuntimeSpawnedWorldItem", { skip_defaults = true })) do
        local l = U.loc(w)
        for _, o in pairs(orig) do
            if U.dist(l, o) <= radius_cm then out[#out + 1] = w; break end
        end
    end
    return out
end

function M.census(log, args)
    local orig, players, puppets = origins()
    local radius = (tonumber(args.radius_m) or 15) * 100
    local out = { players = {}, puppet = nil, items = {} }
    for _, p in ipairs(players) do
        out.players[#out.players + 1] = { id = U.short(p), magnet = magnet_info(p) }
    end
    if puppets[1] then
        local p = puppets[1]
        out.puppet = { id = U.short(p), magnet = magnet_info(p), controller = U.fullname(U.controller_of(p)),
                       player_state = U.fullname(rd(p, "PlayerState")) }
    end
    out.subsystem = U.fullname(U.find_first("ItemMagnetizationSubsystem"))
    local all = U.find_all("RuntimeSpawnedWorldItem", { skip_defaults = true })
    out.world_items_total = #all
    for _, w in ipairs(items_near(orig, radius)) do out.items[#out.items + 1] = world_item_info(w, orig) end
    return out
end

function M.watch(log, args)
    if _G.__dw_item_watch then return { already = true } end
    _G.__dw_item_watch = true
    local seconds, radius = tonumber(args.seconds) or 60, (tonumber(args.radius_m) or 10) * 100
    local prev, t, handle = {}, 0, nil
    handle = LoopInGameThreadWithDelay(1000, function()
        t = t + 1
        local ok, err = pcall(function()
            local orig = origins()
            local snap = {}
            for _, w in ipairs(items_near(orig, radius)) do
                local info = world_item_info(w, orig)
                snap[info.id or tostring(w)] = info
            end
            for k, v in pairs(snap) do
                local p = prev[k]
                local tgt = v.magnet and v.magnet.target
                if not p or p.stack ~= v.stack or (p.magnet and p.magnet.target) ~= tgt
                    or (p.dist_m.puppet ~= v.dist_m.puppet and math.abs((p.dist_m.puppet or 0) - (v.dist_m.puppet or 0)) > 0.3) then
                    log.event("item_probe_watch", { t = t, change = p and "update" or "appear", item = v })
                end
            end
            for k, v in pairs(prev) do
                if not snap[k] then log.event("item_probe_watch", { t = t, change = "gone", last = v }) end
            end
            prev = snap
        end)
        if not ok then log.event("item_probe_watch_error", { err = tostring(err) }) end
        if t >= seconds then
            log.event("item_probe_watch_done", { ticks = t })
            _G.__dw_item_watch = nil
            pcall(CancelDelayedAction, handle)
        end
    end)
    return { armed = true, seconds = seconds, radius_m = radius / 100 }
end

-- Pickup canary: one world item into a TEST store (never the live bot state file).
function M.take(log, args)
    if type(args.state_path) ~= "string" or args.state_path == "" then
        return { ok = false, error = "refused: pass state_path (a test store file, not DW_BOT_STATE)" }
    end
    if args.state_path == os.getenv("DW_BOT_STATE") then return { ok = false, error = "refused: that is the live bot state" } end
    local inv = fresh("inventory")
    local items = fresh("items")
    inv.init({ log = log, state_path = args.state_path })
    local w
    for _, x in ipairs(U.find_all("RuntimeSpawnedWorldItem", { skip_defaults = true })) do
        if U.short(x) == args.target then w = x end
    end
    if not w then return { ok = false, error = "no such world item", target = args.target } end
    local before = world_item_info(w, (origins()))
    local r = items.take_world_item(log, w, inv)
    return { ok = r.ok, reason = r.reason, data = r.data, before = before, store = inv.summary() }
end

-- Is world item `id` gone (garbage / not found)? For the take canary's second step.
function M.gone(log, args)
    for _, x in ipairs(U.find_all("RuntimeSpawnedWorldItem", { skip_defaults = true })) do
        if U.short(x) == args.target then return { gone = false, item = world_item_info(x, (origins())) } end
    end
    return { gone = true }
end

-- Drop canary (SpawnAndLaunchItem_Sync). Offline first: refuses with players connected.
function M.drop(log, args)
    local players, puppets = U.split_pawns()
    if #players > 0 and args.confirm ~= "luis_ok" then
        return { ok = false, error = "refused: " .. #players .. " player(s) connected; run offline first (confirm='luis_ok' only with Luis's go-ahead)" }
    end
    if #players == 0 and args.confirm ~= "offline_canary" and args.confirm ~= "luis_ok" then
        return { ok = false, error = "refused: pass confirm='offline_canary'" }
    end
    local items = fresh("items")
    local at = U.from_wire(args.at) or (puppets[1] and U.in_front(puppets[1], 150, 50)) or (players[1] and U.in_front(players[1], 150, 50))
    if not at then return { ok = false, error = "no location (pass at=[x,y,z] metres)" } end
    local data = U.find_object(args.item_path or "")
    if not data then return { ok = false, error = "item data not loaded", item_path = args.item_path } end
    local world = U.try(function() return (puppets[1] or players[1]):GetWorld() end)
    if not world then
        local any = U.find_first("PlayerController") or U.find_first("GameModeBase")
        world = any and U.try(function() return any:GetWorld() end)
    end
    if not world then return { ok = false, error = "no world" } end
    local r = items.spawn_world_item(log, world, data, tonumber(args.count) or 1, at, { route = args.route, instance = args.instance, skip_floor_check = args.skip_floor_check })
    r.failure_reason = items.last_failure_reason
    if args.track and r.data and r.data.actor then
        -- 50 ms samples for track_s seconds: does it fall (no floor), move, or vanish in place?
        local w, t0, h = r.data.actor, os.clock(), nil
        local n = 0
        h = LoopInGameThreadWithDelay(50, function()
            n = n + 1
            local alive = U.alive(w)
            log.event("item_probe_track", { n = n, alive = alive, valid = U.valid(w), pos = alive and U.to_wire(U.loc(w)) or nil,
                                            life = alive and U.try(function() return w:GetLifeSpan() end) or nil,
                                            hidden = alive and U.try(function() return w.bHidden end) or nil })
            if not alive or n >= (tonumber(args.track_s) or 2) * 20 then pcall(CancelDelayedAction, h) end
        end)
    end
    if r.data and r.data.actor then r.read_back = items.read(r.data.actor); if r.read_back then r.read_back.actor, r.read_back.uitem = nil, nil end end
    if r.ok and r.data and r.data.actor and args.cleanup ~= false then
        -- canary: leave it for N seconds then remove it, unless cleanup=false
        local id = r.data.id
        ExecuteInGameThreadWithDelay((tonumber(args.cleanup_s) or 20) * 1000, function()
            for _, x in ipairs(U.find_all("RuntimeSpawnedWorldItem", { skip_defaults = true })) do
                if U.short(x) == id then U.call(log, "item_probe.cleanup", { id = id }, function() x:SetLifeSpan(0.1) end) end
            end
        end)
    end
    if r.data then r.data.actor = nil end
    return r
end

-- Read-only: UE4SS globals and assets the drop route needs.
function M.env(log, args)
    local paths = args.paths or {
        "/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak",
        "/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Ash.ITEM_Resources_Wood_Ash",
        "/Game/Gameplay/Items/Resources/Animal/ITEM_Resources_Coarse_Animal_Fur.ITEM_Resources_Coarse_Animal_Fur",
        "/Game/Gameplay/WorldItems/BP_RuntimeSpawnedWorldItem_NoExpiry.BP_RuntimeSpawnedWorldItem_NoExpiry_C",
        "/Script/Dominion.Default__ItemHelperLibrary",
    }
    local loaded = {}
    for _, p in ipairs(paths) do loaded[p] = U.find_object(p) ~= nil end
    local inv = type(CreateInvalidObject) == "function" and U.try(CreateInvalidObject) or nil
    local players = U.split_pawns()
    return {
        CreateInvalidObject = type(CreateInvalidObject), invalid_is_valid = inv and U.try(function() return inv:IsValid() end),
        LoadAsset = type(LoadAsset), loaded = loaded, players = #players,
        game_mode = U.fullname(U.find_first("GameModeBase")),
    }
end

function M.run(log, args)
    args = args or {}
    local a = args.action or "census"
    if a == "env" then return M.env(log, args) end
    if a == "census" then return M.census(log, args) end
    if a == "watch" then return M.watch(log, args) end
    if a == "take" then return M.take(log, args) end
    if a == "gone" then return M.gone(log, args) end
    if a == "drop" then return M.drop(log, args) end
    return { ok = false, error = "unknown action " .. tostring(a) }
end

return M
