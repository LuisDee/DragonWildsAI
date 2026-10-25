-- Live self-test of body/gather.lua WITHOUT a server restart (the gather handler only exists after
-- one). Hot-loads the new body modules with loadfile (require would return stale copies, R12),
-- runs a gather action on its own 250 ms game-thread loop and logs the timeline.
--   debug_run {module="gather_test", args={action="start", resource="oak", count=6, radius=30,
--              bonus=true, inventory="test"}}
--     inventory="live" (default): the bot's real store (body/inventory.lua as main.lua initialised it);
--     inventory="test": a fresh copy on logs/state/gather_test_inventory.json (bot state untouched).
--   {action="status"} -> the running action's counters;  {action="stop"} -> cancel it.
-- Default action is status (read-only). Equipping a tool is NOT done here: use the bridge `equip`
-- (with debug_unowned=true only from this experiment's operator, never from the skill).
local U = require("body.util")
local M = {}

local G = rawget(_G, "__dw_gather_test") or {}
rawset(_G, "__dw_gather_test", G)

local function mod_root()
    local dc = package.loaded["debug_cmds"]
    local d = dc and dc.dirs and dc.dirs[1]
    return d and d:gsub("[/\\]scripts$", "") or nil
end

local function load_body(root, name)
    local chunk, err = loadfile(root .. "/body/" .. name .. ".lua")
    if not chunk then error("loadfile body/" .. name .. ": " .. tostring(err)) end
    local mod = chunk()
    package.loaded["body." .. name] = mod
    return mod
end

local function counters(a)
    if not a then return nil end
    return { resource = a.key, have = a.have, want = a.want, total = a.total, sites = a.sites, swings = a.swings,
             native_hits = a.native_hits, emulated_hits = a.emulated_hits, picked = a.picked,
             radius_m = U.cm_to_m(a.radius_cm), target = a.target and a.target.id, stage = a.target and a.target.stage,
             done = a.done, ok = a.ok, reason = a.reason, t_ms = G.now }
end

function M.stop(log)
    if G.loop then pcall(CancelDelayedAction, G.loop) end
    G.loop = nil
    local a = G.action
    if a and not a.done then a.done, a.reason = true, "interrupted" end
    return { stopped = true, last = counters(a) }
end

function M.status() return { running = G.loop ~= nil, action = counters(G.action), result = G.result } end

function M.start(log, args)
    M.stop(log)
    local root = mod_root()
    if not root then return { ok = false, err = "mod root unknown" } end
    for _, n in ipairs({ "sense", "watch", "hitcheck", "resource_profiles" }) do load_body(root, n) end
    local inv, items
    local live_inv = package.loaded["body.inventory"]
    if (args.inventory or "live") == "live" and type(live_inv) == "table" and live_inv.is_ready and live_inv.is_ready()
        and type(package.loaded["body.items"]) == "table" then
        inv, items = live_inv, package.loaded["body.items"] -- the bot's real store (main.lua initialised it)
    else
        package.loaded["body.inventory"], package.loaded["body.items"] = nil, nil
        inv = load_body(root, "inventory")
        items = load_body(root, "items")
        inv.init({ log = log, state_path = (os.getenv("DW_MOD_LOG_DIR") or (root .. "/logs")) .. "/../state/gather_test_inventory.json" })
        if live_inv then package.loaded["body.inventory"] = live_inv end
    end
    local gather = load_body(root, "gather")
    local chk, err = gather.check_args(args)
    if not chk then return err end
    local puppet = require("body.puppet")
    local p = puppet.get()
    if not p then return { ok = false, err = "no puppet" } end
    local bridge = package.loaded["bridge"]
    local hk = package.loaded["body.hitcheck"].arm(log)
    G.now, G.result = 0, nil
    local store = gather.store_from(inv, items)
    local deps = gather.live_deps({
        log_mod = log, puppet = puppet, store = store,
        now = function() return G.now end,
        finish = function(a, ok, reason, data)
            if a.done then return end
            a.done, a.ok, a.reason = true, ok, reason
            pcall(gather.cleanup, a)
            G.result = { ok = ok, reason = reason, data = data }
            log.event("gather_test_end", G.result)
            if bridge then pcall(bridge.emit_event, ok and "task_done" or "task_failed",
                ok and { task_id = "gather_test", data = data } or { task_id = "gather_test", reason = reason }) end
        end,
        emit = function(name, data)
            log.event("gather_test_" .. name, data)
            if bridge then pcall(bridge.emit_event, name, data) end
        end,
    })
    package.loaded["body.sense"].set_clock(function() return G.now end)
    local a = gather.new_action(chk.key, chk.profile, args, deps, store.count(chk.profile.item))
    a.id, a.started = "gather_test", 0
    a.tree = gather.tree(deps)
    if gather.WATCH then
        a.watch = package.loaded["body.watch"].new({ log = log, tag = "gather_watch", radius_cm = 2500, period_ms = 1000,
            center = function() return (a.site and a.site.loc) or U.loc(a.p or p) end })
    end
    G.action = a
    G.loop = LoopInGameThreadWithDelay(250, function()
        G.now = G.now + 250
        local cur = G.action
        if not cur or cur.done then pcall(CancelDelayedAction, G.loop); G.loop = nil; return end
        local ok, e = pcall(cur.tree, cur)
        if not ok then
            log.event("gather_test_error", { err = tostring(e) })
            deps.finish(cur, false, "body_error", { detail = tostring(e) })
        end
    end)
    log.event("gather_test_start", { resource = chk.key, want = a.want, base = a.base, hitcheck = hk })
    return { ok = true, resource = chk.key, item = a.item_id, want = a.want, base = a.base, hitcheck = hk.armed }
end

function M.run(log, args)
    args = args or {}
    local act = args.action or "status"
    if act == "start" then return M.start(log, args) end
    if act == "stop" then return M.stop(log) end
    return M.status()
end

return M
