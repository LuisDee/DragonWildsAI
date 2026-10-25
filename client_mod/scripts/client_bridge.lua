-- client_bridge.lua: the brain <-> CLIENT body link (route R2, docs/research/2026-10-25-client-side-botting.md
-- decision 1: the "agent server" of a Microbot/Mineflayer-style client API).
--
-- Speaks the SAME JSONL protocol as the server puppet (brain/BRIDGE_PROTOCOL.md v1, "Client endpoint"):
-- it loads the server mod's own mod/scripts/bridge.lua (a fresh instance via loadfile) with the client's
-- file pair, so there is one protocol implementation. Files (dir = $DW_CLIENT_BRIDGE_DIR, default
-- <ROOT>/client_io/bridge):  brain_to_client.jsonl (brain writes)  client_to_brain.jsonl (we write).
--
-- Layers (docs/ARCHITECTURE.md section 8, "R2 client body"):
--   brain --JSONL--> client_bridge (this file: dispatch, ONE action slot, waiters, get_state, chat forward)
--         --> client modules client_mod/scripts/{chat,move,sense,inventory}.lua
--         --> the game's own client code paths (UI handlers, Enhanced Input, character calls).
-- Modules are hot-reloaded: a call re-reads the module file at most every RELOAD_CHECK_S and reloads it
-- when the text changed. A missing module or function answers not_implemented and the tool is left out
-- of `capabilities`, so the brain hides it.
--
-- Module contract (as chat/move/sense/inventory do it): functions take the text logger `log(msg)`
-- first and return a table with `ok` (fields flat, or under `data`); failures carry `reason` (or
-- `error`) as free text or a snake_case code, mapped to protocol reasons here (REASONS). Loading a
-- module has no side effects; live state lives in _G. Positions/distances are METRES ([x,y,z]).
--
-- Async:
--   * ACTIONS (move the body: follow, go_to, ...) use one slot. Starting one pre-empts the current one
--     (it answers reason=interrupted; a pre-empted follow, already answered, ends silently). go_to
--     replies when move.status() says the move ended, checked against a fresh position read. follow
--     replies once following and holds the slot.
--   * WAITERS (say, drop) wait for the game's confirmation without touching the slot: say for the
--     server's echo of the line (a self=true chat event), drop for the inventory to shrink (the server
--     confirms drops asynchronously). The brain speaks while a long action runs, so say never pre-empts.
-- Probe (cmd.probe=true): ok {probe=true} without acting. Pure Lua 5.4 + UE4SS
-- LoopInGameThreadWithDelay/CancelDelayedAction; nothing Windows-specific except the mkdir helper.
local M = {}

M.POLL_MS = 100            -- bridge poll + action tick + waiters + chat tail (game thread)
M.RELOAD_CHECK_S = 2       -- re-read a module file at most this often
M.GOTO_TIMEOUT_S = 110     -- brain gives up at 120 s (move.lua's own timeout is 120 s)
M.GOTO_TOL_M = 3.0         -- arrival tolerance reported to the brain for coordinates (move.lua stops at 1.5 m)
M.SAY_ECHO_S = 4           -- wait this long for the server's echo of a chat line
M.DROP_WAIT_S = 5          -- wait this long for the inventory to show a drop
M.NEARBY_M = 50            -- census radius for get_state
M.NEARBY_MAX = 20
M.CHAT_ROTATE_BYTES = 1024 * 1024
M.ACTION_TOOLS = { follow = true, go_to = true, stop = true, attack = true, gather = true, pickup = true,
                   give = true, interact = true, travel = true, sleep = true, craft = true, place = true }
-- Chat lines addressed to the companion (same defaults as brain/run_live.py DEFAULT_PREFIXES; the
-- brain routes again, so this only keeps players' own conversation off the wire).
M.DEFAULT_PREFIXES = { "!c ", "claude,", "claude:", "@claude ", "claude ", "companion,", "companion:", "@companion " }
M.PING = "!ping"
M.IN_NAME = "brain_to_client.jsonl"
M.OUT_NAME = "client_to_brain.jsonl"

local S -- per-start state; the previous instance is stopped on start (hot reload)

-- ------------------------------------------------------------------ small helpers
local function now_s() return (M.clock or os.time)() end

local function text_log(msg)
    if S and S.text_log then pcall(S.text_log, msg) end
end

local function ev(name, data)
    if S and S.jlog then pcall(S.jlog.event, name, data) end
end

local function fail(reason, data) return { ok = false, reason = reason, data = data or {} } end

-- Module reasons -> protocol reason codes (brain/interface.py Reason). Exact codes first, then
-- patterns on free text; any other snake_case code passes through, other free text is body_error.
M.REASONS = { no_pawn = "companion_down", stuck = "path_blocked", target_not_visible = "unknown_target",
              error = "body_error" }
M.REASON_PATTERNS = {
    { "^no pawn", "companion_down" }, { "^no local pawn", "companion_down" },
    { "^no local player controller", "companion_down" }, { "^not in inventory", "not_in_inventory" },
    { "^unknown loadout slot", "invalid_args" }, { "^empty text", "invalid_args" },
}
local function reason_code(r)
    if type(r) ~= "string" then return "body_error" end
    if M.REASONS[r] then return M.REASONS[r] end
    if r:match("^[a-z][a-z_]*$") then return r end
    local low = r:lower()
    for _, p in ipairs(M.REASON_PATTERNS) do
        if low:find(p[1]) then return p[2] end
    end
    return "body_error"
end
M._reason_code = reason_code

-- Module return values -> {ok, reason, data}.
local function norm(res, err)
    if type(res) == "table" and res.ok ~= nil then
        local data = res.data
        if type(data) ~= "table" then
            data = {}
            for k, v in pairs(res) do if k ~= "ok" and k ~= "reason" and k ~= "error" then data[k] = v end end
        end
        if res.ok == true then return { ok = true, reason = nil, data = data } end
        local why = res.reason or res.error
        local code = reason_code(why)
        if why ~= nil and code ~= why then data.detail = data.detail or tostring(why) end
        return { ok = false, reason = code, data = data }
    end
    if type(res) == "table" then return { ok = true, data = res } end
    if res == true then return { ok = true, data = {} } end
    return fail("body_error", { detail = err and tostring(err) or ("module returned " .. tostring(res)) })
end
M._norm = norm

-- An [x,y,z] metre list (or a cm vector {X,Y,Z}) -> metre list; else nil.
local function to_m(p)
    if p == nil then return nil end
    if type(p) == "table" and type(p[1]) == "number" then return { p[1], p[2], p[3] or 0 } end
    local ok, x, y, z = pcall(function() return p.X, p.Y, p.Z end)
    if ok and type(x) == "number" then
        local function r(v) return math.floor(v + 0.5) / 100 end
        return { r(x), r(y), r(z or 0) }
    end
    return nil
end
M._to_m = to_m

local function dist2d(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
end

-- ------------------------------------------------------------------ module loader (hot reload)
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

-- The module table, or nil + why ("missing" | "load: ..." | "init: ...").
function M.module(name)
    local c = S.mods[name]
    local t = now_s()
    if c and c.checked and t - c.checked < M.RELOAD_CHECK_S then return c.mod, c.err end
    local path = S.scripts .. "/" .. name .. ".lua"
    local text = read_file(path)
    if not text then
        S.mods[name] = { checked = t, err = "missing", loads = c and c.loads or 0 }
        return nil, "missing"
    end
    if c and c.text == text then
        c.checked = t
        return c.mod, c.err
    end
    local mod, err
    local chunk, lerr = load(text, "@" .. path)
    if not chunk then err = "load: " .. tostring(lerr)
    else
        local ok, m = pcall(chunk)
        if ok and type(m) == "table" then mod = m else err = "init: " .. tostring(m) end
    end
    S.mods[name] = { checked = t, text = text, mod = mod, err = err, loads = ((c and c.loads) or 0) + 1 }
    ev("client_module_loaded", { name = name, ok = mod ~= nil, err = err, loads = S.mods[name].loads })
    if err then text_log("bridge: module " .. name .. " " .. err) end
    return mod, err
end

-- module.fn if both exist, else nil + reason.
local function fn_of(name, fn)
    local mod, err = M.module(name)
    if not mod then return nil, err end
    if type(mod[fn]) ~= "function" then return nil, "no " .. name .. "." .. fn end
    return mod[fn]
end

-- Call module.fn(log, ...) -> normalised result; not_implemented when absent.
local function call(name, fn, ...)
    local f, why = fn_of(name, fn)
    if not f then return fail("not_implemented", { module = name, fn = fn, detail = why }) end
    local ok, res, err = pcall(f, S.text_log, ...)
    if not ok then
        ev("client_module_error", { module = name, fn = fn, err = tostring(res) })
        return fail("body_error", { module = name, fn = fn, detail = tostring(res) })
    end
    return norm(res, err)
end
M._call = call

-- ------------------------------------------------------------------ the action slot
-- a = {kind, id, poll = fn(a) -> nil | result, cancel = fn(a), quiet_preempt, replied, timeout_s}
local function finish(a, res)
    if a.done then return end
    a.done = true
    if S.action == a then S.action = nil end
    ev("client_action_end", { kind = a.kind, id = a.id, ok = res.ok, reason = res.reason })
    if not a.replied then
        a.replied = true
        S.bridge.reply(a.id, res)
    end
    if a.quiet then return end
    if res.ok then S.bridge.emit_event("task_done", { task_id = a.id, data = S.bridge.object(res.data or {}) })
    else S.bridge.emit_event("task_failed", { task_id = a.id, reason = res.reason or "body_error" }) end
end

local function preempt(by)
    local prev = S.action
    if not prev then return nil end
    if prev.cancel then pcall(prev.cancel, prev) end
    prev.quiet = prev.quiet or prev.quiet_preempt
    finish(prev, fail("interrupted", { by = by }))
    return prev
end

local function tick_action()
    local a = S.action
    if not a then return end
    if a.timeout_s and now_s() - a.started > a.timeout_s then
        if a.cancel then pcall(a.cancel, a) end
        return finish(a, fail("timeout", { kind = a.kind, after_s = a.timeout_s }))
    end
    local ok, res = pcall(a.poll, a)
    if not ok then
        ev("client_action_error", { kind = a.kind, err = tostring(res) })
        a.errors = (a.errors or 0) + 1
        if a.errors >= 3 then return finish(a, fail("body_error", { detail = tostring(res) })) end
        return
    end
    if res then finish(a, res) end
end

function M.following()
    local a = S and S.action
    return a and a.kind == "follow" and a.player or nil
end

-- ------------------------------------------------------------------ waiters (say, drop)
-- w = {id, kind, deadline, poll = fn(w) -> nil | result, expire = fn(w) -> result}
local function add_waiter(w, ctx, wait_s)
    w.id, w.deadline = ctx.id, now_s() + wait_s
    S.waiters[#S.waiters + 1] = w
end

local function tick_waiters()
    local keep, t = {}, now_s()
    for _, w in ipairs(S.waiters) do
        local ok, res = pcall(w.poll, w)
        if not ok then res = fail("body_error", { detail = tostring(res) }) end
        if not res and t >= w.deadline then res = w.expire(w) end
        if res then S.bridge.reply(w.id, res) else keep[#keep + 1] = w end
    end
    S.waiters = keep
end

-- ------------------------------------------------------------------ perception -> get_state
local function me()
    local r = call("sense", "me")
    if not r.ok then return nil, r end
    local d = r.data
    d.position = to_m(d.position or d.location)
    if not d.position then return nil, fail("companion_down", { detail = "no pawn (menu or loading)" }) end
    return d, r
end

local function my_position()
    local d = me()
    return d and d.position
end

local function copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

-- sense.census -> the protocol's buckets (BRIDGE_PROTOCOL.md get_state).
local function bucket_census(c)
    local out = { players = {}, nearby_entities = {}, nearby_resources = {}, nearby_items = {} }
    for _, p in ipairs(c.players or {}) do out.players[#out.players + 1] = copy(p) end
    for _, cr in ipairs(c.creatures or {}) do
        local e = copy(cr)
        e.kind = e.kind or e.name
        e.hp = e.hp or e.health
        e.alive = not (e.dead == true or (tonumber(e.hp) or 1) <= 0)
        if e.hostile == nil then
            if e.attitude ~= nil then e.hostile = e.attitude == "hostile" else e.hostile = S.bridge.null end
        end
        out.nearby_entities[#out.nearby_entities + 1] = e
    end
    for _, key in ipairs({ "resources", "interactables" }) do
        for _, r in ipairs(c[key] or {}) do out.nearby_resources[#out.nearby_resources + 1] = copy(r) end
    end
    for _, it in ipairs(c.items or {}) do
        local i = copy(it)
        if i.collecting == nil then i.collecting = i.magnet_target or S.bridge.null end
        out.nearby_items[#out.nearby_items + 1] = i
    end
    return out
end

local function item_key(row) return row.item or row.name end

-- inventory.list -> inventory {item: count} (hotbar + bag: what he carries and can use), inventory_items
-- (instances; loadout ones equipped=true), gear {loadout slot: item} + held.
local function inventory_view(d)
    local inv, items, gear = {}, {}, {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, it in ipairs(d[where] or {}) do
            local key = item_key(it)
            if key then inv[key] = (inv[key] or 0) + (tonumber(it.count) or 1) end
            local row = copy(it)
            row.id, row.where = tostring(it.slot_type or where) .. ":" .. tostring(it.slot), where
            items[#items + 1] = row
        end
    end
    for _, it in ipairs(d.loadout or {}) do
        local row = copy(it)
        row.id, row.where, row.equipped = "Loadout:" .. tostring(it.slot), "loadout", true
        items[#items + 1] = row
        gear[it.loadout_slot or tostring(it.slot)] = item_key(it)
    end
    if type(d.held) == "table" then
        gear.held_right, gear.held_left = d.held.right_item or d.held.right, d.held.left_item or d.held.left
    end
    return inv, items, gear
end

local function count_of(d, item)
    local inv = inventory_view(d)
    return inv[item] or 0
end

function M.get_state()
    local b = S.bridge
    local data = { position = b.null, health = b.null, inventory = b.object(), following = M.following() or b.null,
                   players = {}, nearby_entities = {}, nearby_resources = {}, structures = {}, places = {},
                   action = S.action and S.action.kind or b.null, body = "client" }
    local missing = { structures = true, places = true }
    local mine, mr = me()
    if not mine then
        for _, k in ipairs({ "position", "health", "players", "nearby_entities", "nearby_resources", "inventory" }) do missing[k] = true end
        data.detail = mr and mr.data and mr.data.detail
    else
        for k, v in pairs(mine) do if data[k] == nil or data[k] == b.null then data[k] = v end end
        data.following = M.following() or b.null
        local cr = call("sense", "census", { radius_m = M.NEARBY_M, max = M.NEARBY_MAX })
        if cr.ok then
            local bk = bucket_census(cr.data)
            data.players, data.nearby_entities, data.nearby_resources = bk.players, bk.nearby_entities, bk.nearby_resources
            data.nearby_items, data.players_online = bk.nearby_items, cr.data.players_online
        else
            missing.players, missing.nearby_entities, missing.nearby_resources = true, true, true
        end
        local ir = call("inventory", "list")
        if ir.ok then
            local inv, items, gear = inventory_view(ir.data)
            data.inventory, data.inventory_items, data.gear = b.object(inv), items, b.object(gear)
        else
            missing.inventory = true
        end
    end
    local left = {}
    for k in pairs(missing) do left[#left + 1] = k end
    table.sort(left)
    data.not_implemented = left
    if not mine then
        -- no sense module yet: like the server stub; sense present but no pawn (menu, loading): companion_down
        local r = (mr and mr.reason == "not_implemented") and "not_implemented" or "companion_down"
        return { ok = false, reason = r, data = data }
    end
    return { ok = true, data = data }
end

-- ------------------------------------------------------------------ tool routes
-- Each route: fn(args, ctx) -> result | {pending = action} | {result, hold = action} | {wait = waiter,
-- wait_s}; `needs` = the module functions it requires (capabilities lists a route only when all exist).
local R = {}
M.ROUTES = R

local function need_str(v) return type(v) == "string" and v ~= "" end

R.say = { needs = { { "chat", "say" } }, fn = function(args)
    if not need_str(args.text) then return fail("invalid_args", { detail = "text is required" }) end
    local r = call("chat", "say", args.text)
    if not r.ok then return r end
    local w = { kind = "say", text = r.data.text or args.text, data = r.data }
    w.poll = function(self)
        if self.echo == nil then return nil end
        local d = copy(self.data)
        d.method, d.text, d.verified, d.echo_exact = "chat_box", self.text, true, self.echo == self.text
        return { ok = true, data = d }
    end
    w.expire = function(self)
        local d = copy(self.data)
        d.method, d.text, d.verified = "chat_box", self.text, false
        return { ok = true, data = d }
    end
    return { wait = w, wait_s = M.SAY_ECHO_S }
end }

R.stop = { needs = { { "move", "stop" } }, fn = function()
    local prev = preempt("stop")
    local r = call("move", "stop")
    if not r.ok then return r end
    return { ok = true, data = { stopped = prev and prev.kind or S.bridge.null } }
end }

local function move_status()
    local r = call("move", "status")
    return r.ok and r.data or {}
end

R.go_to = { needs = { { "move", "go_to" }, { "move", "status" } }, fn = function(args, ctx)
    local target = args.target
    if target == nil or (type(target) == "table" and #target < 2) or (type(target) == "string" and target == "") then
        return fail("invalid_args", { detail = "target is required ([x,y,z] metres, a player, an entity id or a place)" })
    end
    local coords = type(target) == "table" and to_m(target) or nil
    local r = call("move", "go_to", coords or tostring(target), { tolerance_m = tonumber(args.tolerance) })
    if not r.ok then return r end
    local a = { kind = "go_to", id = ctx.id, target = target, timeout_s = M.GOTO_TIMEOUT_S, target_position = coords,
                tol = M.GOTO_TOL_M, polls = 0 }
    a.cancel = function() call("move", "stop") end
    a.poll = function(self)
        self.polls = self.polls + 1
        local st = move_status()
        if st.mode == "go_to" then return nil end -- still walking
        local res = type(st.result) == "table" and st.result or {}
        local here = my_position()
        if res.status == "arrived" then
            -- verified against a fresh position read, not the module's word alone
            local d = self.target_position and here and dist2d(here, self.target_position)
            if d and d > self.tol * 1.5 then
                return fail("verification_failed", { detail = string.format("move said arrived but %.1f m away", d),
                                                     position = here, target_position = self.target_position })
            end
            return { ok = true, data = { target_position = self.target_position or S.bridge.null, target = tostring(target),
                                         position = here or S.bridge.null, arrive_tolerance = self.tol, dist_m = res.dist_m } }
        end
        if res.status == "failed" then
            return fail(reason_code(res.reason or "path_blocked"), { detail = res.detail or res.reason, position = here,
                                                                      dist_m = res.dist_m })
        end
        if res.status == "stopped" or self.polls > 3 then
            return fail("interrupted", { detail = "the move ended without arriving (" .. tostring(res.status) .. ")",
                                         position = here })
        end
        return nil
    end
    return { pending = a }
end }

R.follow = { needs = { { "move", "follow" }, { "move", "status" } }, fn = function(args, ctx)
    local who = args.player
    if who == nil or (type(who) ~= "string" and type(who) ~= "number") or who == "" then
        return fail("invalid_args", { detail = "player is required" })
    end
    local dist_m = tonumber(args.distance) or 3.0
    if dist_m < 1 then dist_m = 1 end
    local r = call("move", "follow", tostring(who), dist_m)
    if not r.ok then return r end
    local a = { kind = "follow", id = ctx.id, player = tostring(who), quiet_preempt = true, replied = true }
    a.cancel = function() call("move", "stop") end
    a.poll = function()
        local st = move_status()
        if st.mode == "follow" then return nil end
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "failed" then return fail(reason_code(res.reason or "unknown_target"), { detail = res.detail or res.reason }) end
        return fail("interrupted", { detail = "follow ended (" .. tostring(res.status) .. ")" })
    end
    local data = copy(r.data)
    data.following, data.distance = a.player, dist_m
    return { result = { ok = true, data = data }, hold = a }
end }

-- drop: the inventory UI's drop; the server confirms asynchronously, so wait for the count to fall.
R.drop = { needs = { { "inventory", "drop" }, { "inventory", "list" } }, fn = function(args)
    if not need_str(args.item) then return fail("invalid_args", { detail = "item is required" }) end
    local n = tonumber(args.count)
    if not n or n < 1 then return fail("invalid_args", { detail = "count must be >= 1" }) end
    n = math.floor(n)
    if args.at ~= nil and args.at ~= "feet" then
        return fail("not_implemented", { detail = "at=" .. tostring(args.at) .. ": walk to the player first, then drop at feet" })
    end
    local before_r = call("inventory", "list") -- the baseline, read before the drop is sent
    if not before_r.ok then return before_r end
    local r = call("inventory", "drop", args.item, n)
    if not r.ok then return r end
    local it = type(r.data.item) == "table" and r.data.item or {}
    local key = item_key(it) or args.item
    local w = { kind = "drop", item = key, count = tonumber(r.data.amount) or n, before = count_of(before_r.data, key) }
    w.poll = function(self)
        local lr = call("inventory", "list")
        if not lr.ok then return nil end
        local now_n = count_of(lr.data, self.item)
        if now_n <= self.before - self.count then
            return { ok = true, data = { item = self.item, count = self.count, at = "feet", inventory_left = now_n } }
        end
        return nil
    end
    w.expire = function(self)
        return fail("verification_failed", { item = self.item, count = self.count,
                                             detail = "the inventory did not shrink within " .. M.DROP_WAIT_S .. " s" })
    end
    return { wait = w, wait_s = M.DROP_WAIT_S }
end }

-- Debug / non-planner tools (capabilities lists them; the brain ignores non-protocol names).
R.equip = { needs = { { "inventory", "equip" } }, fn = function(args)
    if not need_str(args.item) then return fail("invalid_args", { detail = "item is required" }) end
    return call("inventory", "equip", args.item)
end }
R.unequip = { needs = { { "inventory", "unequip" } }, fn = function(args)
    if args.slot == nil then return fail("invalid_args", { detail = "slot is required (HeldRight, Body, ... or index)" }) end
    return call("inventory", "unequip", args.slot)
end }
R.inventory = { needs = { { "inventory", "list" } }, fn = function() return call("inventory", "list") end }
R.census = { needs = { { "sense", "census" } }, fn = function(args) return call("sense", "census", args) end }
R.me = { needs = { { "sense", "me" } }, fn = function() return call("sense", "me") end }
R.move_status = { needs = { { "move", "status" } }, fn = function() return call("move", "status") end }
R.look = { needs = { { "sense", "look" } }, fn = function(args) return call("sense", "look", args) end }

-- Is a route usable right now (every needed module function present)?
local function route_ready(route)
    for _, n in ipairs(route.needs or {}) do
        local f, why = fn_of(n[1], n[2])
        if not f then return false, n[1] .. ": " .. tostring(why) end
    end
    return true
end

-- Module-declared tools: a module listed in M.MODULES may export HANDLERS = {tool = fn(log, args, ctx)}
-- returning what a route returns (see above). Routes win over HANDLERS.
M.MODULES = { "chat", "move", "sense", "inventory" }
local function module_handler(tool)
    for _, name in ipairs(M.MODULES) do
        local mod = M.module(name)
        local h = mod and type(mod.HANDLERS) == "table" and mod.HANDLERS[tool]
        if type(h) == "function" then return h end
    end
    return nil
end

local function implemented_tools()
    local tools = { "ping", "capabilities", "bridge_status" }
    if fn_of("sense", "me") then tools[#tools + 1] = "get_state" end
    for name, route in pairs(R) do
        if route_ready(route) then tools[#tools + 1] = name end
    end
    local seen = {}
    for _, t in ipairs(tools) do seen[t] = true end
    for _, name in ipairs(M.MODULES) do
        local mod = M.module(name)
        if mod and type(mod.HANDLERS) == "table" then
            for t, h in pairs(mod.HANDLERS) do
                if type(h) == "function" and not seen[t] then tools[#tools + 1] = t; seen[t] = true end
            end
        end
    end
    table.sort(tools)
    return tools
end
M.implemented_tools = implemented_tools

-- Run one tool: routes, then module HANDLERS, else not_implemented / unknown_tool.
local function dispatch(tool, args, ctx)
    local route = R[tool]
    local h
    if route then
        local ready, why = route_ready(route)
        if not ready then return fail("not_implemented", { tool = tool, detail = why }) end
        h = route.fn
    else
        local mh = module_handler(tool)
        if not mh then
            local known = false
            for _, t in ipairs(S.bridge.TOOLS) do if t == tool then known = true end end
            return fail(known and "not_implemented" or "unknown_tool", { tool = tool })
        end
        h = function(a, c) return mh(S.text_log, a, c) end
    end
    if args.probe == true then return { ok = true, data = { probe = true, tool = tool } } end
    if M.ACTION_TOOLS[tool] and tool ~= "stop" then preempt(tool) end
    local res = h(args, ctx)
    if type(res) == "table" and res.wait then
        add_waiter(res.wait, ctx, res.wait_s or 5)
        return nil -- replied by tick_waiters
    end
    if type(res) == "table" and res.pending then
        local a = res.pending
        a.id, a.kind, a.started = ctx.id, a.kind or tool, now_s()
        S.action = a
        ev("client_action_start", { kind = a.kind, id = a.id })
        return nil -- replied by finish()
    end
    if type(res) == "table" and res.hold then
        local a = res.hold
        a.id, a.kind, a.started, a.replied = ctx.id, a.kind or tool, now_s(), true
        S.action = a
        ev("client_action_start", { kind = a.kind, id = a.id, held = true })
        return norm(res.result)
    end
    return norm(res)
end
M._dispatch = dispatch

-- ------------------------------------------------------------------ chat -> command_received
local function prefixes()
    local raw = os.getenv("DW_CHAT_PREFIXES")
    if raw and raw ~= "" then
        local out = {}
        for p in raw:gmatch("[^|]+") do if p:match("%S") then out[#out + 1] = p end end
        if #out > 0 then return out end
    end
    return M.DEFAULT_PREFIXES
end

-- Is this chat text addressed to the companion (or !ping)? Mirrors brain/run_live.py chat_route.
function M.addressed(text, pfx)
    local low = tostring(text or ""):match("^%s*(.-)%s*$"):lower()
    if low == M.PING or low:sub(1, #M.PING + 1) == M.PING .. " " then return true end
    for _, p in ipairs(pfx or prefixes()) do
        local lp = p:lower()
        if low:sub(1, #lp) == lp and low:sub(#lp + 1):match("%S") then return true end
    end
    return false
end

-- The writer (chat.lua) only appends, so the file would grow forever. We are its only reader and
-- run on the same game thread as its hook, so once everything is consumed and the file is past
-- CHAT_ROTATE_BYTES it is emptied here (no line can land between the size check and the truncate).
local function rotate_chat()
    local t = S.chat_tail
    if t.offset < M.CHAT_ROTATE_BYTES or t.partial ~= "" then return end
    local f = io.open(t.path, "rb")
    if not f then return end
    local size = f:seek("end") or 0
    f:close()
    if size ~= t.offset then return end
    local w = io.open(t.path, "wb")
    if w then
        w:close()
        t.offset = 0
        S.stats.chat_rotations = S.stats.chat_rotations + 1
        ev("client_chat_rotated", { bytes = size })
    end
end

local function forward_chat()
    if not S.chat_tail then return end
    for _, raw in ipairs(S.chat_tail:read()) do
        local ok, m = pcall(S.jsonutil.decode, raw)
        if ok and type(m) == "table" and m.type == "chat" and type(m.text) == "string" then
            local own = m.self == true or (S.name and m.from == S.name and m.self == nil)
            if own then
                for _, w in ipairs(S.waiters) do -- FIFO: the oldest say still waiting gets this echo
                    if w.kind == "say" and w.echo == nil then w.echo = m.text; break end
                end
            elseif S.chat_all or M.addressed(m.text, S.prefixes) then
                S.bridge.emit_event("command_received", { player = tostring(m.from or m.player_id or "?"), text = m.text })
                S.stats.chat_forwarded = S.stats.chat_forwarded + 1
            else
                S.stats.chat_ignored = S.stats.chat_ignored + 1
            end
        end
    end
    rotate_chat()
end

-- ------------------------------------------------------------------ lifecycle
local function mkdir(p)
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. p .. '"') end
end

function M.step()
    local ok, err = pcall(S.bridge.poll)
    if not ok then ev("client_bridge_poll_error", { err = tostring(err) }) end
    ok, err = pcall(tick_action)
    if not ok then ev("client_action_tick_error", { err = tostring(err) }) end
    ok, err = pcall(forward_chat) -- before the waiters, so an echo read now resolves its say now
    if not ok then ev("client_chat_forward_error", { err = tostring(err) }) end
    ok, err = pcall(tick_waiters)
    if not ok then ev("client_waiters_error", { err = tostring(err) }) end
end

function M.status()
    local mods = {}
    for name, c in pairs(S.mods) do mods[name] = { ok = c.mod ~= nil, err = c.err, loads = c.loads } end
    return { dir = S.dir, paths = S.bridge.paths(), stats = S.bridge.stats, chat = S.stats, modules = mods,
             action = S.action and { kind = S.action.kind, id = S.action.id } or S.bridge.null,
             waiting = #S.waiters, tools = implemented_tools(), chat_events = S.chat_path, started = S.started }
end

-- opts: root (default $DW_CLIENT_ROOT or C:/gameserver), dir (bridge dir), log (fn(msg) text logger),
-- jlog (dwlog-like {event}), scripts (module dir), chat_events (path), start_modules (call chat.start),
-- no_loop (tests drive M.step), poll_ms, from_start (read the brain's file from 0), name (own chat name).
function M.start(opts)
    opts = opts or {}
    local prev = rawget(_G, "__dwc_bridge")
    if prev and prev.stop then pcall(prev.stop) end
    local root = (opts.root or os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/"):gsub("/+$", "")
    local scripts = opts.scripts or (root .. "/client_mod/scripts")
    local shared = root .. "/mod/scripts"
    if not package.path:find(shared, 1, true) then package.path = shared .. "/?.lua;" .. package.path end
    local jsonutil = require("jsonutil")
    -- A fresh bridge.lua instance (its state is file-local), so it never shares offsets with anything.
    local bridge = assert(loadfile(shared .. "/bridge.lua"))()
    local dir = (opts.dir or os.getenv("DW_CLIENT_BRIDGE_DIR") or (root .. "/client_io/bridge")):gsub("\\", "/")
    mkdir(dir)
    local jlog = opts.jlog
    if not jlog then
        local ok_l, dwlog = pcall(function() return assert(loadfile(shared .. "/dwlog.lua"))() end)
        if ok_l then
            mkdir(root .. "/logs/client")
            dwlog.init(root .. "/logs/client")
            jlog = dwlog
        end
    end
    S = { root = root, scripts = scripts, dir = dir, bridge = bridge, jsonutil = jsonutil, jlog = jlog,
          text_log = opts.log or function() end, mods = {}, action = nil, waiters = {},
          started = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          stats = { chat_forwarded = 0, chat_ignored = 0, chat_rotations = 0 }, prefixes = prefixes(),
          chat_all = os.getenv("DW_CLIENT_CHAT_ALL") == "1",
          name = opts.name or os.getenv("DW_COMPANION_NAME") or "Claude" }
    assert(bridge.init({ dir = dir, log = jlog, in_name = M.IN_NAME, out_name = M.OUT_NAME, from_start = opts.from_start }))
    -- every tool goes through dispatch, so modules can appear (or break) while the bridge runs
    local function wrap(tool)
        return function(args, ctx)
            if tool == "get_state" then
                if args.probe == true then
                    return fn_of("sense", "me") and { ok = true, data = { probe = true, tool = tool } }
                           or fail("not_implemented", { tool = tool })
                end
                return M.get_state()
            end
            return dispatch(tool, args, ctx)
        end
    end
    for _, t in ipairs(bridge.TOOLS) do bridge.handlers[t] = wrap(t) end
    for t in pairs(R) do bridge.handlers[t] = wrap(t) end
    for _, t in ipairs({ "look", "inspect", "interact", "travel", "where", "world_info", "spells" }) do bridge.handlers[t] = wrap(t) end
    bridge.handlers.ping = function()
        return { ok = true, data = { pong = true, body = "client", server_clock = os.clock(), server_time = os.time() } }
    end
    bridge.handlers.capabilities = function() return { ok = true, data = { tools = implemented_tools(), body = "client" } } end
    bridge.handlers.bridge_status = function() return { ok = true, data = M.status() } end
    -- other names may be module HANDLERS: route them too
    setmetatable(bridge.handlers, { __index = function(_, tool)
        if type(tool) == "string" and module_handler(tool) then return wrap(tool) end
        return nil
    end })
    -- chat events (client_mod/scripts/chat.lua writes them); start at the end: no history replay
    S.chat_path = opts.chat_events or (root .. "/client_io/events/chat.jsonl")
    S.chat_tail = bridge.new_tail(S.chat_path)
    if opts.start_modules then
        local f = fn_of("chat", "start")
        if f then
            local ok, r = pcall(f, S.text_log)
            ev("client_chat_start", { ok = ok and type(r) == "table" and r.ok == true, err = (not ok) and tostring(r) or nil })
        end
    end
    if not opts.no_loop then
        S.loop = LoopInGameThreadWithDelay(opts.poll_ms or M.POLL_MS, function() M.step() end)
    end
    _G.__dwc_bridge = { stop = M.stop, status = M.status, module = M }
    ev("client_bridge_started", { dir = dir, poll_ms = opts.poll_ms or M.POLL_MS, offset = bridge.paths().offset,
                                  chat = S.chat_path })
    text_log("bridge: started on " .. dir .. " tools=" .. table.concat(implemented_tools(), ","))
    return M.status()
end

function M.stop()
    if not S then return end
    if S.loop and CancelDelayedAction then pcall(CancelDelayedAction, S.loop) end
    S.loop = nil
    ev("client_bridge_stopped", { stats = S.bridge.stats })
end

-- test hook
function M._state() return S end

return M
