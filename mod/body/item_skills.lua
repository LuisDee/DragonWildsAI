-- Item skills as bridge handlers: pickup, drop, give (+ debug: inventory, inventory_grant).
-- Registered beside body/skills.lua and sharing its single action slot and tick loop
-- (skills._start / _finish / _probe_guard; ARCHITECTURE rules 8 and 9). Services: body/inventory.lua
-- (the bot's persistent store) and body/items.lua (world items).
--
--   pickup {target, item?, limit=1}  ASYNC. target = a world item id (get_state.nearby_items[].id) or
--         "nearest" (+ item filter, e.g. "oak"). Walks to the item, takes it into the store, and
--         repeats for up to `limit` items (nearest matching first).
--         ok {item, count, picked=[{world_item, item, count}], inventory={item: count}}
--         Verified per item: the world item is gone AND the store count rose by its stack. If the
--         actor is still there after VERIFY_MS the store is rolled back (verification_failed).
--         Fails: unknown_target (no such item / a player is collecting it), nothing_in_range,
--         path_blocked, timeout, companion_down.
--   drop {item, count, at="feet"|"luis"}  SYNC. item = an owned item id, path or loose name ("oak").
--         Takes from the store first, then spawns world items (one per max-stack) at the bot's feet,
--         or at Luis's feet when he is within DROP_NEAR_PLAYER_CM. A failed spawn refunds the store.
--         ok {item, count, at, world_items=[ids], position, inventory_left}
--         Verified: the store dropped by `count` and every world item exists with the right stack.
--         Fails: not_in_inventory, not_enough_resources, too_far (at=luis), invalid_args, body_error,
--         verification_failed.
--   give {player, item, count}  ASYNC: walk to the player (MoveToActor), then drop at their feet.
--         ok = drop's data + {player}. Fails like drop plus unknown_target, path_blocked, timeout.
--   inventory {}  (debug, read-only) the store: summary + instances.
--   inventory_grant {item_path, count, level?, durability?}  (debug only, never the brain): add items.
--
-- Spawning world items uses body/items.lua's route; its default (SpawnAndLaunchItem_Sync) is
-- UNVERIFIED until the offline canary passes (DISCOVERIES "Item handling").
local U = require("body.util")
local inventory = require("body.inventory")
local items = require("body.items")
local jsonutil = require("jsonutil")

local M = {}

M.PICKUP_RADIUS_CM = 3000          -- "nearest" looks this far
M.PICKUP_REACH_CM = 200            -- take when this close (2D) ...
M.PICKUP_DZ_CM = 250               -- ... and this close vertically
M.PICKUP_ACCEPT_CM = 50
M.PICKUP_LIMIT_MAX = 20
M.PICKUP_ITEM_TIMEOUT_MS = 25000   -- per world item
M.PICKUP_TIMEOUT_MS = 110000       -- whole action (brain gives up at 120 s)
M.VERIFY_MS = 2000                 -- the taken actor must be gone within this
M.REISSUE_MS = 1500
M.STUCK_MS = 4000
M.STUCK_MOVE_CM = 50
M.MAX_REISSUE = 3
M.DROP_FEET_CM = 100               -- in front of the bot
M.DROP_NEAR_PLAYER_CM = 500        -- at="luis" needs the bot this close
M.DROP_PLAYER_GAP_CM = 100         -- drop this far from the player, toward the bot
M.DROP_MAX_STACKS = 10
M.GIVE_REACH_CM = 300
M.GIVE_TIMEOUT_MS = 55000
M.NEARBY_ITEMS_CM = 3000
M.NEARBY_ITEMS_MAX = 20
M.INVENTORY_DETAIL_MAX = 50

local S = { bridge = nil, log = nil, skills = nil, puppet = nil }

local function log(name, data) U.event(S.log, name, data) end
local function now() return S.skills.now() end
local function finish(a, ok, reason, data) return S.skills._finish(a, ok, reason, data) end

local function fail(reason, data) return { ok = false, reason = reason, data = data or {} } end

-- ------------------------------------------------------------------ movement helpers
local function moved_or_stuck(a, here)
    if not a.last_pos or U.dist(here, a.last_pos) > M.STUCK_MOVE_CM then
        a.last_pos, a.last_progress = here, now()
        return false
    end
    return now() - a.last_progress >= M.STUCK_MS
end

local function reach_ok(here, there, reach_cm)
    return U.dist2d(here, there) <= reach_cm and math.abs(here.Z - there.Z) <= M.PICKUP_DZ_CM
end

-- ------------------------------------------------------------------ pickup
local function next_target(a, origin)
    local list = items.find({ origin = origin, radius_cm = M.PICKUP_RADIUS_CM, item = a.filter })
    for _, info in ipairs(list) do
        if not a.tried[info.id] then return info end
    end
end

local function begin_item(a, info)
    a.target, a.target_id = info.actor, info.id
    a.item_started, a.last_issue, a.last_pos, a.reissues = now(), nil, nil, 0
    a.tried[info.id] = true
    a.phase = "walk"
end

local function pickup_done(a, ok, reason, extra)
    local total, item = 0, nil
    for _, p in ipairs(a.picked) do total = total + p.count; item = item or p.item end
    local data = { item = item or jsonutil.null, count = total, picked = a.picked, inventory = inventory.summary() }
    for k, v in pairs(extra or {}) do data[k] = v end
    if ok == nil then ok = total > 0 end
    return finish(a, ok, (not ok) and reason or nil, data)
end

local function step_pickup(a)
    local p = S.puppet.get()
    if not p then return pickup_done(a, false, "companion_down") end
    local here = U.loc(p)
    if now() - a.started >= M.PICKUP_TIMEOUT_MS then return pickup_done(a, #a.picked > 0, "timeout") end

    if a.phase == "verify" then
        local pend = a.pending
        local gone = items.is_gone(pend.actor)
        local have = inventory.count(pend.item_data_path)
        if gone and have >= pend.before + pend.count then
            a.picked[#a.picked + 1] = { world_item = pend.world_item, item = pend.item, count = pend.count }
            log("pickup_item", { world_item = pend.world_item, item = pend.item, count = pend.count, store = have })
            a.pending = nil
            if #a.picked >= a.limit or a.by_id then return pickup_done(a, true) end
            local nxt = next_target(a, here)
            if not nxt then return pickup_done(a, true) end
            begin_item(a, nxt)
            return
        end
        if now() - pend.at >= M.VERIFY_MS then
            -- The world item is still there: undo the store add so nothing is duplicated.
            local rolled = inventory.take(pend.item_data_path, pend.count)
            log("pickup_rollback", { world_item = pend.world_item, rolled_back = rolled, gone = gone })
            return pickup_done(a, false, "verification_failed",
                { detail = gone and "store count did not rise" or "world item still present", world_item = pend.world_item })
        end
        return
    end

    -- walk
    local info = items.read(a.target)
    if not info or not items.available(info) then
        local why = info and "a player is collecting it" or "it is gone"
        if a.by_id then return pickup_done(a, false, "unknown_target", { target = a.target_id, detail = why }) end
        local nxt = next_target(a, here)
        if not nxt then return pickup_done(a, #a.picked > 0, "nothing_in_range", { detail = why }) end
        return begin_item(a, nxt)
    end
    if reach_ok(here, info.loc, M.PICKUP_REACH_CM) then
        local c = U.controller_of(p)
        if c then S.skills._stop_movement(c) end
        local before = inventory.count(info.item_data_path)
        local r = items.take_world_item(S.log, a.target, inventory)
        if not r.ok then
            if a.by_id or r.reason ~= "unknown_target" then return pickup_done(a, false, r.reason, r.data) end
            local nxt = next_target(a, here)
            if not nxt then return pickup_done(a, #a.picked > 0, "nothing_in_range") end
            return begin_item(a, nxt)
        end
        a.phase = "verify"
        a.pending = { actor = a.target, world_item = info.id, item = info.item, item_data_path = info.item_data_path,
                      count = r.data.count, before = before, at = now() }
        return
    end
    if now() - a.item_started >= M.PICKUP_ITEM_TIMEOUT_MS then
        return pickup_done(a, false, "timeout", { target = a.target_id, distance = U.cm_to_m(U.dist(here, info.loc)) })
    end
    if moved_or_stuck(a, here) then
        if a.reissues >= M.MAX_REISSUE then
            return pickup_done(a, false, "path_blocked", { target = a.target_id, position = U.to_wire(here) })
        end
        a.reissues, a.last_progress, a.last_issue = a.reissues + 1, now(), nil
    end
    if not a.last_issue or now() - a.last_issue >= M.REISSUE_MS then
        a.last_issue = now()
        local c = U.controller_of(p)
        if c then
            local r = S.skills._move_to_location(c, info.loc, M.PICKUP_ACCEPT_CM)
            if r == S.skills.REQ_FAILED then a.move_fails = (a.move_fails or 0) + 1 end
            if (a.move_fails or 0) >= M.MAX_REISSUE then
                return pickup_done(a, false, "path_blocked", { target = a.target_id, detail = "MoveTo request failed" })
            end
        end
    end
end

local function h_pickup(args, ctx)
    local target = args.target
    if type(target) ~= "string" or target == "" then
        return fail("invalid_args", { detail = "target is required (a world item id or \"nearest\")" })
    end
    if args.item ~= nil and type(args.item) ~= "string" then return fail("invalid_args", { detail = "item must be a string" }) end
    local limit = math.floor(tonumber(args.limit) or 1)
    if limit < 1 or limit > M.PICKUP_LIMIT_MAX then return fail("invalid_args", { detail = "limit must be 1.." .. M.PICKUP_LIMIT_MAX }) end
    if not inventory.is_ready() then return fail("state_unavailable", { detail = "bot inventory store not initialised" }) end
    local p, c = S.puppet.ensure_ready()
    if not p then return fail("companion_down", { detail = c }) end
    local here = U.loc(p)
    local a = { kind = "pickup", id = ctx.id, async = true, filter = args.item, limit = limit, picked = {}, tried = {},
                step = step_pickup }
    local first
    if target:lower() == "nearest" then
        first = next_target(a, here)
        if not first then
            return fail("nothing_in_range", { item = args.item or jsonutil.null, radius = M.PICKUP_RADIUS_CM / 100 })
        end
    else
        a.by_id, a.limit = true, 1
        local w = items.by_id(target)
        first = w and items.read(w)
        if not first then return fail("unknown_target", { target = target }) end
        if not items.matches(first, args.item) then return fail("unknown_target", { target = target, detail = "item filter does not match" }) end
        if not items.available(first) then return fail("unknown_target", { target = target, detail = "a player is collecting it" }) end
    end
    S.skills._start(a)
    begin_item(a, first)
    return nil -- async: step_pickup replies
end

-- ------------------------------------------------------------------ drop (shared by give)
local function drop_spot(p, at, player)
    if at == "feet" then return U.in_front(p, M.DROP_FEET_CM, 0) end
    local pl, me = U.loc(player), U.loc(p)
    if not (pl and me) then return nil end
    local dx, dy = me.X - pl.X, me.Y - pl.Y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return U.in_front(player, M.DROP_PLAYER_GAP_CM, 0) end
    return { X = pl.X + dx / d * M.DROP_PLAYER_GAP_CM, Y = pl.Y + dy / d * M.DROP_PLAYER_GAP_CM, Z = pl.Z }
end

-- Resolve an owned item and check the count. Returns item_id or nil, failure result.
local function owned(query, count)
    local id, why, cands = inventory.resolve(query)
    if not id then
        if why == "ambiguous" then return nil, fail("invalid_args", { item = query, detail = "ambiguous", candidates = cands }) end
        return nil, fail("not_in_inventory", { item = query, inventory = inventory.summary() })
    end
    local have = inventory.count(id)
    if have < count then return nil, fail("not_enough_resources", { item = id, have = have, wanted = count }) end
    return id
end

-- The drop itself, at an already-resolved location. Store first, then world; refund on a failed spawn.
local function do_drop(p, item, count, spot, at_label, route)
    local world = U.try(function() return p:GetWorld() end)
    local before = inventory.count(item)
    local stacks, left = {}, count
    local probe = inventory.list()
    local cap = 1
    for _, it in ipairs(probe) do if it.item == item then cap = inventory.max_stack(it); break end end
    while left > 0 do
        local n = math.min(cap, left)
        stacks[#stacks + 1] = n
        left = left - n
    end
    if #stacks > M.DROP_MAX_STACKS then
        return fail("invalid_args", { item = item, detail = "more than " .. M.DROP_MAX_STACKS .. " stacks in one drop" })
    end
    local spawned, lost = {}, false
    for i, n in ipairs(stacks) do
        local took, portions = inventory.take(item, n)
        if not took then return fail("not_enough_resources", { item = item, world_items = spawned }) end
        local path = portions[1].item_data_path
        for _, pt in ipairs(portions) do
            if (tonumber(pt.level) or 0) > 0 or pt.enchant or ((tonumber(pt.durability) or -1) >= 0
                and pt.max_durability and pt.durability ~= pt.max_durability) then lost = true end
        end
        local data = U.find_object(path)
        local at = { X = spot.X + (i - 1) * 40, Y = spot.Y, Z = spot.Z } -- side by side, not one pile
        local r = data and items.spawn_world_item(S.log, world, data, n, at, { route = route })
            or fail("body_error", { detail = "item data not loaded: " .. tostring(path) })
        if not r.ok then
            if not (r.data and r.data.spawned) then inventory.put_back(portions) end
            r.data = r.data or {}
            r.data.actor = nil
            r.data.item, r.data.world_items, r.data.stack_index = item, spawned, i
            return r
        end
        spawned[#spawned + 1] = r.data.id
    end
    local after = inventory.count(item)
    if before - after ~= count then
        return fail("verification_failed", { item = item, detail = "store moved by " .. (before - after), world_items = spawned })
    end
    return { ok = true, data = { item = item, count = count, at = at_label, world_items = spawned,
                                 position = U.to_wire(spot), inventory_left = after,
                                 instance_state_lost = lost or nil } }
end

local function h_drop(args)
    if type(args.item) ~= "string" or args.item == "" then return fail("invalid_args", { detail = "item is required" }) end
    local count = tonumber(args.count)
    if not count or count < 1 or count ~= math.floor(count) then return fail("invalid_args", { detail = "count must be an integer >= 1" }) end
    local at = args.at == nil and "feet" or args.at
    if at ~= "feet" and at ~= "luis" then return fail("invalid_args", { detail = "at must be \"feet\" or \"luis\"" }) end
    if not inventory.is_ready() then return fail("state_unavailable", { detail = "bot inventory store not initialised" }) end
    local item, bad = owned(args.item, count)
    if not item then return bad end
    local p, err = S.puppet.ensure_ready()
    if not p then return fail("companion_down", { detail = err }) end
    local player
    if at == "luis" then
        player = U.find_player("luis")
        if not player then return fail("unknown_target", { target = "luis" }) end
        local d = U.actor_dist(p, player)
        if d > M.DROP_NEAR_PLAYER_CM then return fail("too_far", { distance = U.cm_to_m(d), max = M.DROP_NEAR_PLAYER_CM / 100 }) end
    end
    local spot = drop_spot(p, at, player)
    if not spot then return fail("body_error", { detail = "no drop location" }) end
    -- Instant, like a player dropping while walking: the current action (e.g. follow) keeps going.
    return do_drop(p, item, math.floor(count), spot, at, args.route)
end

-- ------------------------------------------------------------------ give
local function step_give(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local target = U.find_player(a.player, true)
    if not target then return finish(a, false, "unknown_target", { player = a.player }) end
    local here, there = U.loc(p), U.loc(target)
    if U.dist(here, there) <= M.GIVE_REACH_CM then
        local c = U.controller_of(p)
        if c then S.skills._stop_movement(c) end
        local spot = drop_spot(p, "luis", target)
        local r = do_drop(p, a.item, a.count, spot, "player", a.route)
        r.data = r.data or {}
        r.data.player = a.player
        return finish(a, r.ok, r.reason, r.data)
    end
    if now() - a.started >= M.GIVE_TIMEOUT_MS then
        return finish(a, false, "timeout", { player = a.player, distance = U.cm_to_m(U.dist(here, there)) })
    end
    if moved_or_stuck(a, here) then
        if a.reissues >= M.MAX_REISSUE then return finish(a, false, "path_blocked", { player = a.player, position = U.to_wire(here) }) end
        a.reissues, a.last_progress, a.last_issue = a.reissues + 1, now(), nil
    end
    if not a.last_issue or now() - a.last_issue >= M.REISSUE_MS then
        a.last_issue = now()
        local c = U.controller_of(p)
        if c then S.skills._move_to_actor(c, target, M.GIVE_REACH_CM / 2) end
    end
end

local function h_give(args, ctx)
    local who = args.player
    if who == nil or (type(who) ~= "string" and type(who) ~= "number") then return fail("invalid_args", { detail = "player is required" }) end
    if type(args.item) ~= "string" or args.item == "" then return fail("invalid_args", { detail = "item is required" }) end
    local count = tonumber(args.count)
    if not count or count < 1 or count ~= math.floor(count) then return fail("invalid_args", { detail = "count must be an integer >= 1" }) end
    if not inventory.is_ready() then return fail("state_unavailable", { detail = "bot inventory store not initialised" }) end
    local target = U.find_player(who, true)
    if not target then return fail("unknown_target", { target = who }) end
    local item, bad = owned(args.item, count)
    if not item then return bad end
    local p, err = S.puppet.ensure_ready(target)
    if not p then return fail("companion_down", { detail = err }) end
    local a = { kind = "give", id = ctx.id, async = true, player = tostring(who), item = item, count = math.floor(count),
                route = args.route, reissues = 0, step = step_give }
    S.skills._start(a)
    step_give(a) -- already within reach: drop at once
    return nil
end

-- ------------------------------------------------------------------ debug + state
local function h_inventory()
    return { ok = true, data = { inventory = inventory.summary(), items = inventory.detail(), ready = inventory.is_ready() } }
end

local function h_inventory_grant(args)
    if type(args.item_path) ~= "string" or args.item_path:sub(1, 1) ~= "/" then
        return fail("invalid_args", { detail = "item_path (an object path) is required" })
    end
    local count = math.floor(tonumber(args.count) or 0)
    if count < 1 then return fail("invalid_args", { detail = "count must be >= 1" }) end
    local r, why = inventory.grant(args.item_path, count, { level = tonumber(args.level), durability = tonumber(args.durability),
                                                            max_stack = tonumber(args.max_stack) })
    if not r then return fail(why or "invalid_args", {}) end
    return { ok = true, data = { added = r.added, ids = r.ids, inventory = inventory.summary() } }
end

-- get_state: `inventory` {item: count} (available, not equipped), `inventory_items` (instances),
-- `nearby_items` [{id, item, name, count, position, distance, collecting}] for pickup targets.
local function state_extender(data, p)
    if not inventory.is_ready() then return {} end
    data.inventory = inventory.summary()
    data.inventory_items = inventory.detail(M.INVENTORY_DETAIL_MAX)
    local origin = (p and U.loc(p)) or (U.split_pawns()[1] and U.loc(U.split_pawns()[1]))
    local near = {}
    if origin then
        for _, info in ipairs(items.find({ origin = origin, radius_cm = M.NEARBY_ITEMS_CM, all = true, max = M.NEARBY_ITEMS_MAX })) do
            near[#near + 1] = { id = info.id, item = info.item, name = info.name or jsonutil.null, count = info.count or jsonutil.null,
                                position = U.to_wire(info.loc), distance = U.cm_to_m(info.dist),
                                collecting = info.magnet_target or jsonutil.null }
        end
    end
    data.nearby_items = near
    return { "inventory" }
end

M.HANDLERS = { pickup = h_pickup, drop = h_drop, give = h_give, inventory = h_inventory, inventory_grant = h_inventory_grant }

-- opts: {skills = body.skills (registered already), puppet = body.puppet}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod
    S.skills = opts.skills or require("body.skills")
    S.puppet = opts.puppet or require("body.puppet")
    for name, fn in pairs(M.HANDLERS) do bridge.handlers[name] = S.skills._probe_guard(name, fn) end
    S.skills.add_state_extender("items", state_extender)
    log("item_skills_registered", { tools = { "pickup", "drop", "give", "inventory", "inventory_grant" } })
    return M
end

return M
