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
-- Perception: look / inspect / interact over sense.census (generic categories), get_state with vitals,
-- held item and interactables; events attacked (vitals watcher damage rows) and vitals_low.
-- Services: chat hooks, vitals watcher and stay-fed reflex are started and supervised here (SERVICES).
-- Probe (cmd.probe=true): ok {probe=true} without acting. Pure Lua 5.4 + UE4SS
-- LoopInGameThreadWithDelay/CancelDelayedAction; nothing Windows-specific except the mkdir helper.
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
local M = {}

M.POLL_MS = 100            -- bridge poll + action tick + waiters + chat tail (game thread)
M.RELOAD_CHECK_S = 2       -- re-read a module file at most this often
M.GOTO_TIMEOUT_S = 290     -- brain gives up at 300 s (move.lua may wait 60 s for a lead out of a trap, then walk on)
M.GOTO_TOL_M = 1.5         -- default movement tolerance, in metres
M.SAY_ECHO_S = 4           -- wait this long for the server's echo of a chat line
M.DROP_WAIT_S = 5          -- wait this long for the inventory to show a drop
M.NEARBY_M = 50            -- census radius for get_state
M.NEARBY_MAX = 20
M.CHAT_ROTATE_BYTES = 1024 * 1024
M.ACTION_TOOLS = { follow = true, go_to = true, stop = true, attack = true, gather = true, pickup = true,
                   give = true, interact = true, travel = true, sleep = true, craft = true, place = true,
                   fetch = true, consume = true, come_to = true, recover_grave = true, explore = true } -- composite skills (skills.lua)
-- Chat lines addressed to the companion (same defaults as brain/run_live.py DEFAULT_PREFIXES; the
-- brain routes again, so this only keeps players' own conversation off the wire).
M.DEFAULT_PREFIXES = { "!c ", "claude,", "claude:", "@claude ", "claude ", "companion,", "companion:", "@companion " }
M.PING = "!ping"
M.IN_NAME = "brain_to_client.jsonl"
M.OUT_NAME = "client_to_brain.jsonl"
M.DEBUG_IN_NAME = "debug_to_client.jsonl"
M.DEBUG_OUT_NAME = "client_to_debug.jsonl"

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
              error = "body_error", unreachable = "path_blocked", no_resource_nearby = "nothing_in_range" }
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

local function has_z(p)
    if type(p) == "table" and type(p[1]) == "number" then return type(p[3]) == "number" end
    local ok, z = pcall(function() return p and p.Z end)
    return ok and type(z) == "number"
end

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
    -- the general stray-screen guard (input.after_action, BUGS B-stuck-focused-ui): an action that left a HUD
    -- screen open (a Campfire's Processing + Inventory panels) must not leave him in DIM_FocussedInGameUI
    local inp = not rawget(_G, "DW_PAUSE") and M.module("input") or nil
    if type(inp) == "table" and type(inp.after_action) == "function" then
        local okg, rec = pcall(inp.after_action, a.kind, S.text_log)
        if okg and type(rec) == "table" then
            ev("client_stray_screen", { kind = a.kind, mode = rec.mode, closed = rec.closed, left = rec.left, after = rec.after })
        end
    end
    local ch = a.chan or S.bridge -- answer on the channel the request came from (main or debug)
    if not a.replied then
        a.replied = true
        ch.reply(a.id, res)
    end
    if a.quiet then return end
    if res.ok then ch.emit_event("task_done", { task_id = a.id, data = ch.object(res.data or {}) })
    else
        -- Held follow already replied; its event is the only way to report a terminal failure.
        -- TaskFailed.reason is the existing brain-facing string field, so retain the specific
        -- observed detail there when available instead of emitting a duplicate movement event.
        local why = res.reason or "body_error"
        if a.kind == "follow" and type(res.data) == "table" and type(res.data.detail) == "string" and res.data.detail ~= "" then why = res.data.detail end
        ch.emit_event("task_failed", { task_id = a.id, reason = why })
    end
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
    if res then finish(a, norm(res)) end
end

function M.following()
    local a = S and S.action
    return a and a.kind == "follow" and a.player or nil
end

-- ------------------------------------------------------------------ waiters (say, drop)
-- w = {id, kind, deadline, poll = fn(w) -> nil | result, expire = fn(w) -> result}
local function add_waiter(w, ctx, wait_s)
    w.id, w.deadline, w.chan = ctx.id, now_s() + wait_s, ctx.chan
    S.waiters[#S.waiters + 1] = w
end

local function tick_waiters()
    local keep, t = {}, now_s()
    for _, w in ipairs(S.waiters) do
        local ok, res = pcall(w.poll, w)
        if not ok then res = fail("body_error", { detail = tostring(res) }) end
        if not res and t >= w.deadline then res = w.expire(w) end
        if res then (w.chan or S.bridge).reply(w.id, res) else keep[#keep + 1] = w end
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
    for _, r in ipairs(c.resources or {}) do out.nearby_resources[#out.nearby_resources + 1] = copy(r) end
    out.interactables = {}
    for _, r in ipairs(c.interactables or {}) do out.interactables[#out.interactables + 1] = copy(r) end
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
        -- own vitals, flat: hydration / sustenance / endurance = current value, *_max = maximum
        for stat, v in pairs(type(mine.survival) == "table" and mine.survival or {}) do
            if type(v) == "table" then data[stat], data[stat .. "_max"] = v[1], v[2] end
        end
        local cr = call("sense", "census", { radius_m = M.NEARBY_M, max = M.NEARBY_MAX })
        if cr.ok then
            local bk = bucket_census(cr.data)
            data.players, data.nearby_entities, data.nearby_resources = bk.players, bk.nearby_entities, bk.nearby_resources
            data.nearby_items, data.interactables, data.players_online = bk.nearby_items, bk.interactables, cr.data.players_online
        else
            missing.players, missing.nearby_entities, missing.nearby_resources = true, true, true
        end
        local ir = call("inventory", "list")
        if ir.ok then
            local inv, items, gear = inventory_view(ir.data)
            data.inventory, data.inventory_items, data.gear = b.object(inv), items, b.object(gear)
            local held = type(ir.data.held) == "table" and ir.data.held or {}
            data.held = held.right or held.left or b.null -- display name of what is in his hands
            data.held_item = held.right_item or held.left_item or b.null
        else
            missing.inventory = true
        end
    end
    if mine then
        local cs = call("combat", "status")
        if cs.ok and type(cs.data.fight) == "table" then
            local f = cs.data.fight
            data.fight = { mode = f.mode, phase = f.phase, target = f.target, target_id = f.target_id, target_hp = f.target_hp,
                           weapon = f.weapon }
        end
        -- module extras: any module in M.MODULES may export state_extras(api, data) -> {key = value}
        -- (skills.lua: my_grave, other_graves, last_death, last_held; spells.lua: spells, spells_locked_n)
        for _, name in ipairs(M.MODULES) do
            local mod = M.module(name)
            if mod and type(mod.state_extras) == "function" then
                local okx, ex = pcall(mod.state_extras, M.API, data)
                if okx and type(ex) == "table" then
                    for k, v in pairs(ex) do data[k] = v; missing[k] = nil end -- e.g. build.lua fills structures
                elseif not okx then ev("client_module_error", { module = name, fn = "state_extras", err = tostring(ex) }) end
            end
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
    local cs = call("combat", "status")
    if cs.ok and type(cs.data.fight) == "table" and cs.data.fight.mode == "attack" then call("combat", "stop", "stop") end
    local r = call("move", "stop")
    if not r.ok then return r end
    return { ok = true, data = { stopped = prev and prev.kind or S.bridge.null } }
end }

local function move_status()
    local r = call("move", "status")
    return r.ok and r.data or {}
end

-- combat.lua's reflex (self-defence) takes the pawn through arbiter.lua, which suspends a running
-- follow/go_to and restores it after the fight. While that is going on, our polls must wait, not
-- read the stopped move as "interrupted".
local function reflex_owns_pawn()
    local A = M.module("arbiter")
    if not (A and type(A.owner) == "function") then return false end
    local ok, o = pcall(A.owner)
    if ok and type(o) == "table" and o.level == "reflex" then return true end
    local ok2, st = pcall(A.status)
    return ok2 and type(st) == "table" and type(st.suspended) == "table" and #st.suspended > 0 and (not o)
end
M._reflex_owns_pawn = reflex_owns_pawn

-- Lying in a bed/shelter: the game disables movement until he gets up (live 20:58, go_to hung 46 s;
-- BUGS L2d). Movement tools answer at once with the bed's id.
local function resting_failure()
    local sk = M.module("skills")
    local W = sk and sk.W
    if not (W and type(W.resting_in) == "function") then return nil end
    local ok, bed = pcall(W.resting_in, M.API)
    if ok and bed then
        return fail("resting", { resting_in = bed, detail = "lying in " .. tostring(bed) .. "; movement is disabled until "
            .. "he gets up (interact on that bed)" })
    end
    return nil
end
M._resting_failure = resting_failure

R.go_to = { needs = { { "move", "go_to" }, { "move", "status" } }, fn = function(args, ctx)
    local target = args.target
    if target == nil or (type(target) == "table" and (type(target[1]) ~= "number" or type(target[2]) ~= "number" or type(target[3]) ~= "number")) or (type(target) == "string" and target == "") then
        return fail("invalid_args", { detail = "target is required ([x,y,z] metres, a player, an entity id or a place)" })
    end
    local rf = resting_failure()
    if rf then return rf end
    if args.tolerance ~= nil and (not tonumber(args.tolerance) or tonumber(args.tolerance) <= 0) then
        return fail("invalid_args", { detail = "tolerance must be positive" })
    end
    local coords = type(target) == "table" and to_m(target) or nil
    local gts = type(target) == "string" and (target == "my_grave" and "" or target:match("^my_grave:(.+)$"))
    if gts then -- BUGS L19/L22: a remembered death spot (newest, or my_grave:<ts>), at any distance
        local sk = M.module("skills")
        local d = sk and type(sk.death_memory) == "function" and sk.death_memory(gts ~= "" and gts or nil) or nil
        if not (d and d.position) then return fail("unknown_target", { target = target, detail = "no remembered grave like that" }) end
        if not has_z(d.position) then return fail("verification_failed", { detail = "destination height unavailable" }) end
        coords = to_m(d.position)
    end
    -- every id that look / get_state return resolves (BUGS L8): a perceived thing's position, except
    -- creatures and players, which move.lua tracks as moving actors
    if not coords and type(target) == "string" then
        -- go_to reaches as far as a known actor is (a fishing node 134 m off, live 2026-10-26), not only look's 80 m
        local t = M.API.find_thing(target, M.GOTO_FIND_M)
        if t and t.position and t.category ~= "creatures" and t.category ~= "players" then
            if not has_z(t.position) then return fail("verification_failed", { detail = "destination height unavailable" }) end
            coords = to_m(t.position)
        end
    end
    local r = call("move", "go_to", coords or tostring(target), { tolerance_m = tonumber(args.tolerance) })
    if not r.ok then return r end
    local a = { kind = "go_to", id = ctx.id, target = target, timeout_s = M.GOTO_TIMEOUT_S, target_position = coords,
                tol = tonumber(args.tolerance) or M.GOTO_TOL_M, polls = 0 }
    a.cancel = function() call("move", "stop") end
    a.poll = function(self)
        if reflex_owns_pawn() then self.started = now_s(); return nil end -- fighting back; resumes after
        self.polls = self.polls + 1
        local st = move_status()
        if st.mode == "go_to" then return nil end -- still walking
        local res = type(st.result) == "table" and st.result or {}
        local here = my_position()
        if res.status == "arrived" then
            local fresh = call("sense", "me")
            local raw_pos = fresh.ok and (fresh.data.position or fresh.data.location) or nil
            if not has_z(raw_pos) then return fail("verification_failed", { detail = "position height unavailable" }) end
            here = to_m(raw_pos)
            -- Movement independently re-reads the controlled pawn, life, ground and original/current
            -- goal. A missing verifier or perception is not a successful arrival.
            local verified = call("move", "verify_arrival")
            if not verified.ok then return fail(reason_code(verified.reason or "verification_failed"),
                { detail = verified.data and verified.data.detail or "arrival could not be verified", position = here }) end
            local goal = verified.data.target_position
            local d = goal and here and dist2d(here, goal)
            local z = goal and here and type(goal[3]) == "number" and type(here[3]) == "number" and math.abs(here[3] - goal[3]) or nil
            local vp = verified.data.position
            if not (d and z and vp and type(vp[3]) == "number") or d > self.tol or math.abs(here[3] - vp[3]) > 0.1
                or dist2d(here, vp) > 0.1 or (self.target_position and
                    (dist2d(self.target_position, goal) > 0.01 or math.abs(self.target_position[3] - goal[3]) > 0.01)) then
                return fail("verification_failed", { detail = "fresh position does not confirm arrival", position = here, target_position = goal })
            end
            return { ok = true, data = { target_position = goal, target = tostring(target),
                                         position = here, arrive_tolerance = self.tol, dist_m = res.dist_m,
                                         vertical_distance_m = verified.data.vertical_distance_m,
                                         vertical_tolerance_m = verified.data.vertical_tolerance_m } }
        end
        if res.status == "failed" then
            return fail(reason_code(res.reason or "path_blocked"), { detail = res.why or res.detail or res.reason,
                                                                      why = res.why, asked = res.asked, position = here,
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
    local rf = resting_failure()
    if rf then return rf end
    local r = call("move", "follow", tostring(who), dist_m)
    if not r.ok then return r end
    local a = { kind = "follow", id = ctx.id, player = tostring(who), quiet_preempt = true, replied = true }
    a.cancel = function() call("move", "stop") end
    a.poll = function()
        if reflex_owns_pawn() then return nil end -- the arbiter restores the follow after the fight
        local st = move_status()
        if st.mode == "follow" then return nil end
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "failed" then return fail(reason_code(res.reason or "unknown_target"), { detail = res.detail }) end
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
R.equip = { needs = { { "inventory", "equip" } }, fn = function(args, ctx)
    -- skills.lua's verified equip (a waiter: answers once it is in his hands or worn) when present
    local sk = M.module("skills")
    if sk and type(sk.HANDLERS) == "table" and type(sk.HANDLERS.equip) == "function" and fn_of("inventory", "list") then
        ctx.api = M.API
        return sk.HANDLERS.equip(S.text_log, args, ctx)
    end
    if not need_str(args.item) then return fail("invalid_args", { detail = "item is required" }) end
    return call("inventory", "equip", args.item)
end }
R.unequip = { needs = { { "inventory", "unequip" } }, fn = function(args, ctx)
    -- skills.lua's verified unequip (item or slot; answers once it is off) when present, like R.equip
    local sk = M.module("skills")
    if sk and type(sk.HANDLERS) == "table" and type(sk.HANDLERS.unequip) == "function" and fn_of("inventory", "list") then
        ctx.api = M.API
        return sk.HANDLERS.unequip(S.text_log, args, ctx)
    end
    if args.slot == nil then return fail("invalid_args", { detail = "slot is required (HeldRight, Body, ... or index)" }) end
    return call("inventory", "unequip", args.slot)
end }
-- inventory (brain read tool): compact listing; raw=true gives inventory.list as is.
local function pct(it)
    local d, m = tonumber(it.durability), tonumber(it.max_durability)
    if d and m and m > 0 then return math.floor(d / m * 100 + 0.5) end
    return nil
end
local function slim(it, with_slot)
    local o = { name = it.name or it.item, item = it.item, count = it.count, durability_pct = pct(it) }
    if with_slot then o.slot = it.slot end
    if it.consumable then o.use = it.consumable end
    return o
end
function M.compact_inventory(d)
    local worn, hotbar, bag = {}, {}, {}
    for _, it in ipairs(d.loadout or {}) do
        local slot = it.loadout_slot or tostring(it.slot)
        if slot ~= "HeldRight" and slot ~= "HeldLeft" then worn[slot] = it.name or it.item end
    end
    for _, it in ipairs(d.hotbar or {}) do hotbar[#hotbar + 1] = slim(it, true) end
    for _, it in ipairs(d.bag or {}) do bag[#bag + 1] = slim(it, false) end
    local held = type(d.held) == "table" and d.held or {}
    return { worn = S.bridge.object(worn), held = S.bridge.object({ right = held.right, left = held.left }),
             hotbar = hotbar, bag = bag, weight = d.weight, empty_slots = d.empty_slots }
end
R.inventory = { needs = { { "inventory", "list" } }, fn = function(args)
    local r = call("inventory", "list")
    if not r.ok or args.raw == true then return r end
    return { ok = true, data = M.compact_inventory(r.data) }
end }
R.census = { needs = { { "sense", "census" } }, fn = function(args) return call("sense", "census", args) end }
R.me = { needs = { { "sense", "me" } }, fn = function() return call("sense", "me") end }
R.move_status = { needs = { { "move", "status" } }, fn = function() return call("move", "status") end }
-- ------------------------------------------------------------------ perception: look / inspect / interact
-- Built on sense.census (generic: every category the client can see; no hand lists). One "thing" =
-- a census row plus category, kind, verb and the actions the CLIENT can do on it now.
M.LOOK_RADIUS_M, M.LOOK_MAX_RADIUS_M, M.LOOK_MAX = 20, 80, 15
M.GOTO_FIND_M = 500 -- go_to resolves a perceived id this far (census rows, live actors by id)
M.INTERACT_REACH_M = 2.0     -- walk closer than this before pressing interact (the detector traces 6 m)
M.INTERACT_APPROACH_M = 1.0  -- move.go_to tolerance for the approach (graves: 0.6-1.2 m works)
M.INTERACT_AIM_S = 2         -- re-aim until the game's detector targets the thing
M.INTERACT_VERIFY_S = 4      -- then wait this long for the outcome (target gone or inventory grew)
M.INTERACT_TIMEOUT_S = 100   -- whole action (brain waits 120 s)
local CATS = {
    { key = "players", kind = "player", verb = "follow", actions = { "follow", "go_to" } },
    { key = "creatures", kind = "creature", verb = "attack", actions = { "attack" } },
    { key = "items", kind = "item", verb = "pickup", actions = { "interact" } },
    { key = "resources" }, -- gatherable (interact = collect) or destructible (chop/mine/hit)
    { key = "interactables", verb = "interact", actions = { "interact" } },
}
M.CATS = CATS

local function thing_of(cat, row)
    local t = copy(row)
    t.category = cat.key
    t.kind = t.kind or cat.kind
    t.verb = t.verb or cat.verb
    if cat.key == "resources" then
        if t.kind == "foliage" then -- standing trees, bushes, branches, ground stones (instanced foliage)
            t.actions = t.verb == "gather" and { "interact", "gather" } or { "gather" }
        else
            t.actions = t.kind == "gatherable" and { "interact" } or { t.verb or "hit" }
        end
    else
        t.actions = cat.actions
    end
    if cat.key == "creatures" then
        t.hp, t.max_hp = t.health, t.max_health
        t.alive = not (t.dead == true or (tonumber(t.health) or 1) <= 0)
        if t.attitude ~= nil then t.hostile = t.attitude == "hostile" end
    end
    return t
end

-- Port of mod/body/sense.lua M.match_score (pure): the share of the player's words found in the
-- thing's name, class, prompt, drops, item id, kind and verb, with simple plural forms.
local function words(s)
    local out = {}
    for w in tostring(s or ""):lower():gmatch("[%a]+") do if #w > 2 then out[#out + 1] = w end end
    return out
end
function M.match_score(t, about)
    local q = words(about)
    if #q == 0 then return 0 end
    local hay = table.concat({ t.name or "", t.class or "", t.prompt or "", t.drops or "", t.drop_item or "",
                               t.item or "", t.kind or "", t.verb or "" }, " "):lower()
    local score = 0
    for _, w in ipairs(q) do
        for _, f in ipairs({ w, (w:gsub("ies$", "y")), (w:gsub("es$", "")), (w:gsub("s$", "")) }) do
            if #f > 2 and hay:find(f, 1, true) then score = score + 1; break end
        end
    end
    return score / #q
end

-- The shared item-name resolver for rows the player's words must pick ONE item from (his inventory, a
-- chest): rows {name, item, ...}. Tiers: 3 exact id or name (case-insensitive); 2 the whole words are
-- in the name or id ("sandwich" -> "Forager's Sandwich"); 1 every word matches (match_score 1, plurals).
-- A partial word overlap ("Clean Water" vs "Water Rune") is NEVER a match: it never silently picks a
-- different item; those rows come back as `near` so the caller can say what he does have.
-- opts.fuzzy_ok(row) -> false drops a row from tiers 1-2 (consume: only consumables match fuzzily, an
-- exact name still resolves so "I can't eat the Oak Logs" stays truthful); opts.rank(row) -> number
-- breaks ties within a tier (hotbar first, clean consumables). -> row | nil, {tier, near = {rows}}
function M.resolve_name(rows, what, opts)
    opts = opts or {}
    local lw = tostring(what or ""):lower()
    if lw == "" then return nil, { near = {} } end
    local best, bt, br, near = nil, 0, 0, {}
    for _, r in ipairs(rows or {}) do
        local name, id = tostring(r.name or ""):lower(), tostring(r.item or ""):lower()
        local tier
        if id == lw or name == lw then tier = 3
        elseif name:find(lw, 1, true) or id:find(lw, 1, true) then tier = 2
        elseif M.match_score({ name = r.name, item = r.item }, what) >= 1 then tier = 1 end
        if tier and tier < 3 and opts.fuzzy_ok and not opts.fuzzy_ok(r) then near[#near + 1] = r; tier = nil
        elseif not tier and M.match_score({ name = r.name, item = r.item }, what) > 0 then near[#near + 1] = r end
        if tier then
            local rk = opts.rank and opts.rank(r) or 0
            if tier > bt or (tier == bt and rk > br) then best, bt, br = r, tier, rk end
        end
    end
    return best, { tier = best and bt or nil, near = near }
end

-- Every thing within radius_m (census, nearest first per category), flattened.
local function census_things(radius_m, max_per_cat)
    local r = call("sense", "census", { radius_m = radius_m, max = max_per_cat or 40 })
    if not r.ok then return nil, r end
    local out = {}
    for _, cat in ipairs(CATS) do
        for _, row in ipairs(r.data[cat.key] or {}) do out[#out + 1] = thing_of(cat, row) end
    end
    return out, r
end

-- A foliage id ("fol:<ActorClass>@x,y,z", sense.lua M.foliage_id) is resolved by WHERE the instance stands, not
-- by a census listing (BUGS L26: the server converts an instance into an actor when he walks up to it, and ISM
-- indices change): the instance itself, or the actor it became. resolved = "reindexed" | "converted" | "legacy"
-- and resolved_from = the asked id tell the caller the id it should use from now on (t.id).
M.FOLIAGE_GONE = {
    felled_or_picked = "that tree or plant is gone: it was felled or picked",
    not_found = "I can't find that tree or plant where it stood any more",
}
local function find_foliage(id, radius_m)
    local s = M.module("sense")
    if not (s and type(s.resolve_foliage) == "function") then return nil end
    local ok, row, how = pcall(s.resolve_foliage, id)
    if not ok then return nil, fail("body_error", { target = id, detail = tostring(row) }) end
    if not row then
        if how == "not_a_foliage_id" then return nil end
        return nil, fail("unknown_target", { target = id, why = how, detail = M.FOLIAGE_GONE[how] or ("not perceived (" .. tostring(how) .. ")") })
    end
    for k in pairs(row) do if type(k) == "string" and k:sub(1, 1) == "_" then row[k] = nil end end
    local r = radius_m or M.LOOK_MAX_RADIUS_M
    if row.distance and row.distance > r then
        return nil, fail("unknown_target", { target = id, detail = "not perceived within " .. r .. " m" })
    end
    local t = thing_of(CATS[4], row)
    if how ~= "same" then t.resolved, t.resolved_from = how, id end
    return t
end
M._find_foliage = find_foliage

-- Any LIVE actor id another read handed out but the census doesn't list (fishing_spots' FishingNodeV2 nodes,
-- 2026-10-26: go_to answered target_not_visible, aimed spells couldn't resolve them). A UE instance name is
-- "<Class>_<n>", so the class comes from the id itself; one find_all of that class, matched by short name.
-- Read-only; never under pause. -> thing | nil
local function find_actor_by_id(id, radius_m)
    if rawget(_G, "DW_PAUSE") == true then return nil end
    local s = M.module("sense")
    local U = s and s.U
    -- placed level actors are "<Class>_UAID_<hex>_<n>" (live 2026-10-26: BP_FishingNodeV2_Net_Brynmoor_C_UAID_..._1131309019)
    local cls = tostring(id):match("^([%w_]-)_UAID_%x+_%d+$") or tostring(id):match("^([%w_]-)_%d+$")
    if not (U and cls and cls ~= "") then return nil end
    for _, a in ipairs(U.find_all(cls, { skip_defaults = true }) or {}) do
        if U.short(a) == id then
            local at = U.loc(a)
            if not at then return nil end
            local pos = U.to_wire(at)
            local here = my_position()
            local d = here and dist2d(here, pos)
            local lim = radius_m or M.LOOK_MAX_RADIUS_M
            if d and d > lim then
                return nil, fail("unknown_target", { target = id, distance = math.floor(d + 0.5), detail = "it's " .. math.floor(d + 0.5) .. " m away, beyond " .. lim .. " m" })
            end
            local name = s.clean_class and s.clean_class(U.class_word(a)) or cls
            return { id = id, class = U.class_word(a), name = name, position = pos, distance = d and math.floor(d * 10 + 0.5) / 10,
                     category = "actors", kind = "actor", actions = { "go_to" } }
        end
    end
    return nil
end
M._find_actor_by_id = find_actor_by_id

local function find_thing(id, radius_m)
    if tostring(id):sub(1, 4) == "fol:" then
        local t, r = find_foliage(id, radius_m)
        if t or r then return t, r end
    end
    local things, r = census_things(radius_m or M.LOOK_MAX_RADIUS_M, 100)
    if not things then return nil, r end
    for _, t in ipairs(things) do if t.id == id then return t end end
    local a, ar = find_actor_by_id(id, radius_m)
    if a or ar then return a, ar end
    return nil, fail("unknown_target", { target = id, detail = "not perceived within " .. (radius_m or M.LOOK_MAX_RADIUS_M) .. " m" })
end

R.look = { needs = { { "sense", "census" } }, fn = function(args)
    local radius = math.min(tonumber(args.radius) or M.LOOK_RADIUS_M, M.LOOK_MAX_RADIUS_M)
    local max = math.max(1, math.min(tonumber(args.max) or M.LOOK_MAX, 40))
    local about = need_str(args.about) and args.about or nil
    local things, r = census_things(radius)
    if not things then return r end
    for _, t in ipairs(things) do t._score = about and M.match_score(t, about) or 0 end
    table.sort(things, function(x, y)
        if x._score ~= y._score then return x._score > y._score end
        return (x.distance or 0) < (y.distance or 0)
    end)
    local out, matched = {}, false
    for i = 1, math.min(#things, max) do
        local t = things[i]
        if about then t.match = math.floor(t._score * 100 + 0.5) / 100 end
        if t._score > 0 then matched = true end
        t._score = nil
        out[#out + 1] = t
    end
    local m = S.bridge.null -- a boolean only when about was given (an and/or chain would turn false into null)
    if about then m = matched end
    return { ok = true, data = { origin = r.data.origin, radius_m = radius, about = about or S.bridge.null, total = #things,
                                 things = out, matched = m } }
end }

-- The live actor behind a thing (class word from the census row; alive only).
local function actor_of(t)
    local s = M.module("sense")
    local U = s and s.U
    if not (U and t and t.class) then return nil end
    for _, a in ipairs(U.find_all(t.class, { skip_defaults = true }) or {}) do
        if U.short(a) == t.id then return a, U end
    end
    return nil, U
end

-- Containers (graves, chests, storage): what is inside, read-only; nil when not a container.
local function contents_of(a, U)
    -- TArray reads on an invalid owner crash natively (UE4SS push_arrayproperty, 21:49:34): validate the
    -- owner and the component in this same tick, never during a pause
    if rawget(_G, "DW_PAUSE") == true or not U.valid(a) then return nil end
    local inv = U.try(function() return a:GetInventory() end) or U.try(function() return a.InventoryComponent end)
    local desc = fn_of("inventory", "describe_item")
    if not (U.valid(inv) and desc) then return nil end
    local out = {}
    pcall(function()
        local arr = inv.ItemSlots
        for i = 1, arr:GetArrayNum() do
            local it = arr[i]
            if U.valid(it) then
                local e = desc(it)
                if e then out[#out + 1] = { name = e.name, item = e.item, count = e.count } end
            end
        end
    end)
    return out
end

R.inspect = { needs = { { "sense", "census" } }, fn = function(args)
    local id = args.target or args.id
    if not need_str(id) then return fail("invalid_args", { detail = "target is required (an id from look)" }) end
    local t, r = find_thing(id)
    if not t then return r end
    local d = copy(t)
    d.gives = {}
    for _, g in ipairs({ t.drops, t.name and t.category == "items" and t.name or nil }) do d.gives[#d.gives + 1] = g end
    if t.tool then d.requires = { tool = t.tool, tier = t.tool_tier } end
    local a, U = actor_of(t)
    if a and U then
        for _, prop in ipairs({ "Description", "DisplayDescription", "DescriptionText" }) do
            local s = U.str(U.try(function() return a[prop] end))
            if s and s ~= "" then d.description = s; break end
        end
        d.contents = contents_of(a, U)
    end
    return { ok = true, data = d }
end }

local function counts()
    local lr = call("inventory", "list")
    return lr.ok and (inventory_view(lr.data)) or nil
end

-- Aim the camera at a point, as the mouse does (the same call move.lua steers with).
local function aim_at(pos)
    local s = M.module("sense")
    if not s then return false end
    local pc, pawn = s.local_pc(), s.local_pawn()
    local U = s.U
    local here = pawn and to_m(U.loc(pawn))
    if not (pc and here and pos) then return false end
    -- from the CAMERA, as the mouse aims (spells.W.aim, live-verified): the game's interaction detector casts its
    -- ray from the camera (UInteractableDetectorComponent.CameraRayLength), which sits behind and above the pawn,
    -- so a pitch from the pawn's centre overshoots a small item on the ground into whatever lies beyond it
    local cam = U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local okc, cx, cy, cz = pcall(function() return cam.X, cam.Y, cam.Z end)
    if okc and type(cx) == "number" and type(cz) == "number" then here = { cx / 100, cy / 100, cz / 100 } end
    local dx, dy, dz = pos[1] - here[1], pos[2] - here[2], (pos[3] or here[3]) - here[3]
    local yaw = math.deg(math.atan(dy, dx))
    local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    return pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
end

R.interact = { needs = { { "sense", "census" }, { "inventory", "interact_target" }, { "inventory", "press_interact" },
                         { "inventory", "list" } }, fn = function(args, ctx)
    -- The composite-skill engine (skills.lua: arbiter ownership, approach, FACE + nudge until the
    -- detector targets it, press, verify, speech-ready reasons) when present; the code below is the
    -- fallback without it.
    local sk = M.module("skills")
    if sk and type(sk.HANDLERS) == "table" and type(sk.HANDLERS.interact) == "function" then
        ctx.api = M.API
        return sk.HANDLERS.interact(S.text_log, args, ctx)
    end
    local id = args.target or args.id
    if not need_str(id) then return fail("invalid_args", { detail = "target is required (an id from look)" }) end
    if args.secondary == true then return fail("not_implemented", { detail = "secondary interactions are not wired yet" }) end
    local t, r = find_thing(id)
    if not t then return r end
    local can = false
    for _, act in ipairs(t.actions or {}) do if act == "interact" then can = true end end
    if not can then return fail("not_interactable", { target = id, kind = t.kind, actions = t.actions }) end
    local a = { kind = "interact", id = ctx.id, target = id, thing = t, timeout_s = M.INTERACT_TIMEOUT_S, phase = "approach",
                before = counts() or {} }
    a.cancel = function() call("move", "stop") end
    local function gained(now)
        local best, n, all = nil, 0, {}
        for k, v in pairs(now or {}) do
            local d = v - (a.before[k] or 0)
            if d > 0 then all[k] = d; if d > n then best, n = k, d end end
        end
        return best, n, all
    end
    a.poll = function(self)
        local tnow = now_s()
        if reflex_owns_pawn() then self.started = tnow; return nil end
        if self.phase == "approach" then
            local here = my_position()
            local d = here and self.thing.position and dist2d(here, self.thing.position)
            if d and d <= M.INTERACT_REACH_M then
                self.phase, self.aim_until = "aim", tnow + M.INTERACT_AIM_S
            elseif not self.moving then
                if not fn_of("move", "go_to") then return fail("too_far", { target = id, distance = d }) end
                local mr = call("move", "go_to", self.thing.position, { tolerance_m = M.INTERACT_APPROACH_M, timeout_s = 60 })
                if not mr.ok then return mr end
                self.moving = true
            else
                local st = move_status()
                if st.mode ~= "go_to" then
                    local res = type(st.result) == "table" and st.result or {}
                    if res.status ~= "arrived" then
                        return fail(reason_code(res.reason or "path_blocked"), { target = id, detail = res.detail or res.reason })
                    end
                    self.moving = false -- arrived: next tick re-checks the distance
                    self.approaches = (self.approaches or 0) + 1
                    if self.approaches > 2 then return fail("too_far", { target = id, distance = d }) end
                end
            end
            return nil
        elseif self.phase == "aim" then
            aim_at(self.thing.position)
            local s = M.module("sense")
            local it_fn = fn_of("inventory", "interact_target") -- (pawn), no log argument
            local okd, cur = pcall(it_fn, s and s.local_pawn() or nil)
            self.detector = okd and type(cur) == "table" and cur or nil
            local fol = tostring(id):sub(1, 4) == "fol:"
            local det = self.detector
            local same = det and (det.actor == id or (fol and not det.none and (
                (det.name and det.name == self.thing.name) or (det.item and det.item == self.thing.item))))
            if same then
                local pr = call("inventory", "press_interact")
                if not pr.ok then return pr end
                self.phase, self.verify_until = "verify", tnow + M.INTERACT_VERIFY_S
                return nil
            end
            if tnow >= self.aim_until then
                return fail("not_interactable", { target = id, detail = "the game's interact target is "
                    .. tostring(self.detector and (self.detector.actor or (self.detector.none and "nothing")) or "unknown") })
            end
            return nil
        else -- verify
            local item, n, all = gained(counts())
            local want = self.thing.item
            if want and tostring(id):sub(1, 4) == "fol:" then -- a foliage pickup must yield ITS item
                item, n = (all[want] and want or nil), all[want] or 0
            end
            -- a foliage id never has an actor of its own: only an inventory gain proves the press worked
            local gone = tostring(id):sub(1, 4) ~= "fol:" and actor_of(self.thing) == nil
            if item or gone then
                return { ok = true, data = { target = id, item = item or S.bridge.null, count = n, gained = S.bridge.object(all),
                                             target_gone = gone, prompt = self.detector and self.detector.prompt or S.bridge.null } }
            end
            if tnow >= self.verify_until then
                return fail("verification_failed", { target = id, detail = "pressed interact, but the target is still there "
                    .. "and nothing new is in the inventory", prompt = self.detector and self.detector.prompt })
            end
            return nil
        end
    end
    return { pending = a }
end }

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
-- A module may also export NEEDS = {tool = {{module, fn}, ...}}: the handler is listed (and run) only
-- while those functions exist, exactly like a route's `needs` (skills.lua composes other modules).
M.MODULES = { "chat", "move", "sense", "inventory", "combat", "arbiter", "gather", "skills", "spells", "crafting", "hookhub",
               "input", "build", "fishing", "agility", "farm", "quests", "lodestone", "shoot" }
-- talk.lua stays OUT until its re-review passes (docs/reviews/2026-10-26-talk-primitive-review.md "Re-review (v2)":
-- sweep_orphan recursed through the gate). Opt-in for a dev test only: _G.DW_ENABLE_TALK = true before bridge_start.
if rawget(_G, "DW_ENABLE_TALK") == true then M.MODULES[#M.MODULES + 1] = "talk" end
local function module_handler(tool)
    for _, name in ipairs(M.MODULES) do
        local mod = M.module(name)
        local h = mod and type(mod.HANDLERS) == "table" and mod.HANDLERS[tool]
        if type(h) == "function" then
            local needs = type(mod.NEEDS) == "table" and mod.NEEDS[tool] or nil
            return h, needs and { needs = needs } or nil, name
        end
    end
    return nil
end

-- An action tool takes the single action slot and pre-empts the running action: the fixed list above,
-- plus any module tool whose MANIFEST entry says kind = "action" and moves = true (skill modules such as
-- fishing / runecraft / agility / build need no bridge edit).
function M.is_action_tool(tool)
    if M.ACTION_TOOLS[tool] then return true end
    for _, name in ipairs(M.MODULES) do
        local mod = M.module(name)
        local e = mod and type(mod.MANIFEST) == "table" and mod.MANIFEST[tool]
        if type(e) == "table" then return e.kind == "action" and e.moves == true end
    end
    return false
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
                local needs = type(mod.NEEDS) == "table" and mod.NEEDS[t] or nil
                if type(h) == "function" and not seen[t] and (not needs or route_ready({ needs = needs })) then
                    tools[#tools + 1] = t; seen[t] = true
                end
            end
        end
    end
    table.sort(tools)
    return tools
end
M.implemented_tools = implemented_tools

-- ------------------------------------------------------------------ capability manifest (the contract)
-- One entry per IMPLEMENTED tool (client_mod/scripts/manifest.lua shape; a module's own MANIFEST[tool]
-- wins), plus the legacy aliases whose new tool is implemented. The brain builds the LLM's tool list
-- from this only (brain/capabilities.py), so it can never offer a tool the body lacks.
local function manifest_data()
    local mf = M.module("manifest")
    if not mf then -- tests point scripts at a fakes dir: fall back to the real data file
        local ok, m = pcall(function() return assert(loadfile(S.root .. "/client_mod/scripts/manifest.lua"))() end)
        mf = ok and m or { TOOLS = {}, ALIASES = {} }
    end
    return mf
end

function M.manifest()
    local mf = manifest_data()
    local own = {}
    for _, name in ipairs(M.MODULES) do
        local mod = M.module(name)
        if mod and type(mod.MANIFEST) == "table" then
            for t, e in pairs(mod.MANIFEST) do if own[t] == nil then own[t] = e end end
        end
    end
    local tools, list, have = implemented_tools(), {}, {}
    for _, t in ipairs(tools) do
        local e = own[t] or (mf.TOOLS or {})[t]
        local entry = { name = t }
        if type(e) == "table" then for k, v in pairs(e) do entry[k] = v end
        else entry.kind, entry.llm, entry.description = "probe", false, "(no manifest entry)" end
        entry.args = entry.args or { type = "object", properties = S.bridge.object() }
        list[#list + 1] = entry
        have[t] = true
    end
    local aliases = {}
    for old, new in pairs(mf.ALIASES or {}) do if have[new] and not have[old] then aliases[old] = new end end
    return list, S.bridge.object(aliases), mf.VERSION or 1
end

-- The bridge's services for module handlers (ctx.api): skills.lua composes these instead of copying them.
M.API = {
    call = function(...) return call(...) end,
    module = function(n) return M.module(n) end,
    fail = fail,
    reason_code = function(r) return reason_code(r) end,
    now = function() return now_s() end,
    me = function() return me() end,
    my_position = function() return my_position() end,
    census_things = function(r, m) return census_things(r, m) end,
    find_thing = function(id, r) return find_thing(id, r) end,
    match_score = function(t, about) return M.match_score(t, about) end,
    resolve_name = function(rows, what, opts) return M.resolve_name(rows, what, opts) end,
    actor_of = function(t) return actor_of(t) end,
    contents_of = function(t) local a, U = actor_of(t); if a and U then return contents_of(a, U) end end,
    counts = function() return counts() end,
    aim_at = function(p) return aim_at(p) end,
    move_status = function() return move_status() end,
    reflex_owns_pawn = function() return reflex_owns_pawn() end,
    object = function(t) return S.bridge.object(t) end,
    log = function(msg) text_log(msg) end,
}
setmetatable(M.API, { __index = function(_, k) if k == "null" then return S and S.bridge.null end end })

-- Run one tool: routes, then module HANDLERS, else not_implemented / unknown_tool.
local function dispatch(tool, args, ctx)
    local route = R[tool]
    local h
    if route then
        local ready, why = route_ready(route)
        if not ready then return fail("not_implemented", { tool = tool, detail = why }) end
        h = route.fn
    else
        local mh, needs = module_handler(tool)
        if not mh then
            local known = false
            for _, t in ipairs(S.bridge.TOOLS) do if t == tool then known = true end end
            return fail(known and "not_implemented" or "unknown_tool", { tool = tool })
        end
        if needs then
            local ready, why = route_ready(needs)
            if not ready then return fail("not_implemented", { tool = tool, detail = why }) end
        end
        h = function(a, c) c.api = M.API; return mh(S.text_log, a, c) end
    end
    if args.probe == true then return { ok = true, data = { probe = true, tool = tool } } end
    local is_action = M.is_action_tool(tool)
    if is_action and S.debug and ctx.chan == S.debug and S.action and S.action.chan ~= S.debug
       and args.force ~= true then
        -- BUGS L12: a debug/test action never pre-empts the brain's running action (it answered
        -- "interrupted" to Luis, 20:56); pass force = true to take the slot anyway
        return fail("busy", { owner = "brain:" .. tostring(S.action.kind), owner_id = S.action.id,
                              detail = "the brain's " .. tostring(S.action.kind) .. " is running (debug channel; force=true overrides)" })
    end
    if is_action and tool ~= "stop" then preempt(tool) end
    local res = h(args, ctx)
    if type(res) == "table" and res.wait then
        add_waiter(res.wait, ctx, res.wait_s or 5)
        return nil -- replied by tick_waiters
    end
    if type(res) == "table" and res.pending then
        local a = res.pending
        a.id, a.kind, a.started, a.chan = ctx.id, a.kind or tool, now_s(), ctx.chan
        S.action = a
        ev("client_action_start", { kind = a.kind, id = a.id })
        return nil -- replied by finish()
    end
    if type(res) == "table" and res.hold then
        local a = res.hold
        a.id, a.kind, a.started, a.replied, a.chan = ctx.id, a.kind or tool, now_s(), true, ctx.chan
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
-- Also addressed: the companion's name as a whole word ANYWHERE ("hello claude what are you wearing",
-- "thanks Claude", "@claude ..."; not "claudette"). The brain strips the name and greeting
-- (brain/run_live.py chat_route), so the line is forwarded unchanged.
function M.addressed(text, pfx, name)
    local low = tostring(text or ""):match("^%s*(.-)%s*$"):lower()
    if low == M.PING or low:sub(1, #M.PING + 1) == M.PING .. " " then return true end
    for _, p in ipairs(pfx or prefixes()) do
        local lp = p:lower()
        if low:sub(1, #lp) == lp and low:sub(#lp + 1):match("%S") then return true end
    end
    name = tostring(name or (S and S.name) or "Claude"):lower():gsub("%p", "%%%0")
    return low:find("%f[%w]" .. name .. "%f[%W]") ~= nil
end

-- The writer (chat.lua) only appends, so the file would grow forever. We are its only reader and
-- run on the same game thread as its hook, so once everything is consumed and the file is past
-- CHAT_ROTATE_BYTES it is emptied here (no line can land between the size check and the truncate).
local function rotate(t)
    if not t or t.offset < M.CHAT_ROTATE_BYTES or t.partial ~= "" then return end
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
        ev("client_events_rotated", { path = t.path, bytes = size })
    end
end

-- ------------------------------------------------------------------ vitals -> attacked / vitals_low
-- attacked{by, name, amount, hp}: a "damage" row of sense.lua's vitals watcher (client_io/events/
-- vitals.jsonl, its Multicast_Apply*DamageFromGameplayEffect hooks) whose instigator is not Claude
-- himself; at most once per ATTACKED_REPEAT_S per attacker. `by` = the attacker's actor id, the
-- same id as in get_state.nearby_entities.
M.ATTACKED_REPEAT_S = 5
-- vitals_low{stat, value, max, has_food, has_drink}: hydration or sustenance below VITALS_LOW and
-- nothing to eat/drink for it in the inventory (the stay-fed reflex would handle it otherwise).
-- Checked every VITALS_CHECK_S from sense.me (so it works without the watcher); re-armed once the
-- stat is back above VITALS_REARM, repeated every VITALS_REPEAT_S while it stays low.
M.VITALS_LOW, M.VITALS_REARM, M.VITALS_CHECK_S, M.VITALS_REPEAT_S = 15, 25, 15, 180
M.VITAL_NEEDS = { hydration = "drink", sustenance = "food" }

local function forward_vitals()
    if not S.vitals_tail then return end
    for _, raw in ipairs(S.vitals_tail:read()) do
        local ok, m = pcall(S.jsonutil.decode, raw)
        if ok and type(m) == "table" and m.type == "reflex" and type(m.action) == "string" and m.action ~= "verify" then
            -- the stay-fed reflex's own acts, as episodic memory (activity); failures too (verify ok=false
            -- marks an item unusable; no_hotbar_* = food/drink only in the bag)
            S.bridge.emit_event("activity", { kind = "reflex_" .. m.action, by = "reflex", item = m.item, name = m.name,
                                              stat = m.stat, ok = m.ok, reason = m.reason, ts = m.ts })
        elseif ok and type(m) == "table" and m.type == "reflex" and m.action == "verify" and m.ok == false then
            S.bridge.emit_event("activity", { kind = "reflex_use_failed", by = "reflex", item = m.item, before = m.before,
                                              after = m.after, ts = m.ts })
        end
        if ok and type(m) == "table" and (m.type == "death" or m.type == "revive") then
            -- recent context for the brain (get_state.last_death via skills.state_extras)
            local life = rawget(_G, "DW_LIFE") or {}
            _G.DW_LIFE = life
            if m.type == "death" then
                life.move_death_seq = (life.move_death_seq or 0) + 1
                life.died_at, life.respawned_at = tonumber(m.ts) or now_s(), nil
                -- BUGS L19: remember WHERE he died and what he carried, persisted, until the grave is recovered
                local sk = M.module("skills")
                if sk and type(sk.record_death) == "function" then
                    local okd, e = pcall(sk.record_death, M.API, tonumber(m.ts) or now_s())
                    if not okd then ev("client_module_error", { module = "skills", fn = "record_death", err = tostring(e) }) end
                end
            else life.respawned_at = tonumber(m.ts) or now_s() end
        end
        if ok and type(m) == "table" and m.type == "revive" then S.escape_pending = "respawn" end
        if ok and type(m) == "table" and m.type == "damage" and type(m.instigator) == "table" and not m.instigator.self then
            local by = m.instigator.id or m.instigator.name or m.instigator.player or "?"
            local t = now_s()
            if not S.attacked_at[by] or t - S.attacked_at[by] >= M.ATTACKED_REPEAT_S then
                S.attacked_at[by] = t
                S.bridge.emit_event("attacked", { by = tostring(by), name = m.instigator.name or m.instigator.player,
                                                  amount = m.amount, hp = m.hp, class = m.class })
                S.stats.attacked = S.stats.attacked + 1
            end
        end
    end
    rotate(S.vitals_tail)
end

-- unreachable{reason, detail, leader_pos, my_pos, mode} / resumed{} from move.lua's events
-- (client_io/events/move.jsonl: "unreachable" once per episode, "reachable_again", "stuck").
local function forward_moves()
    if not S.move_tail then return end
    for _, raw in ipairs(S.move_tail:read()) do
        local ok, m = pcall(S.jsonutil.decode, raw)
        if ok and type(m) == "table" then
            local who = { target = m.target, target_kind = m.target_kind }
            if m.type == "unreachable" then
                S.bridge.emit_event("unreachable", { reason = tostring(m.reason or "no_route"), detail = m.detail,
                                                     leader_pos = m.leader_pos, my_pos = m.my_pos, mode = m.mode,
                                                     target = who.target, target_kind = who.target_kind })
                S.stats.unreachable = S.stats.unreachable + 1
            elseif m.type == "reachable_again" then
                S.bridge.emit_event("resumed", { reason = "reachable_again", after_s = m.after_s, target = who.target,
                                                 target_kind = who.target_kind })
            elseif m.type == "stuck" and m.ask == "lead_me" then -- a player is near: ask him to lead the way out
                S.bridge.emit_event("unreachable", { reason = "lead_me", where = m.where, helper = m.helper,
                                                     detail = m.detail, my_pos = m.my_pos, target = who.target,
                                                     target_kind = who.target_kind })
                S.stats.unreachable = S.stats.unreachable + 1
            elseif m.type == "stuck" then
                S.bridge.emit_event("unreachable", { reason = "stuck", detail = m.unstuck and ("unstuck " .. tostring(m.unstuck)) or m.detail,
                                                     leader_pos = m.leader_pos, my_pos = m.my_pos, target = who.target,
                                                     target_kind = who.target_kind })
                S.stats.unreachable = S.stats.unreachable + 1
            elseif m.type == "led_out" then
                S.bridge.emit_event("resumed", { reason = "led_out", helper = m.helper, target = who.target,
                                                 target_kind = who.target_kind })
            end
        end
    end
    rotate(S.move_tail)
end

-- gather_progress{task_id, resource, item, have, want} from gather.lua's client_io/events/gather.jsonl
-- (gather_status phase lines are for the logs, not speech: not forwarded).
local function forward_gather()
    if not S.gather_tail then return end
    for _, raw in ipairs(S.gather_tail:read()) do
        local ok, m = pcall(S.jsonutil.decode, raw)
        if ok and type(m) == "table" and m.type == "gather_progress" and tonumber(m.have) and tonumber(m.want) then
            S.bridge.emit_event("gather_progress", { task_id = m.task_id, resource = m.resource, item = m.item,
                                                     have = math.floor(tonumber(m.have)), want = math.floor(tonumber(m.want)) })
        end
    end
    rotate(S.gather_tail)
end

-- activity{kind, by, ts, ...} from client_io/events/activity.jsonl: one line per COMPLETED body episode
-- (combat.lua: combat_end, fled, healed; others later), forwarded as is (episodic memory, never spoken
-- by itself; brain/interface.py Activity keeps unknown kinds and fields).
local function forward_activity()
    if not S.activity_tail then return end
    for _, raw in ipairs(S.activity_tail:read()) do
        local ok, m = pcall(S.jsonutil.decode, raw)
        if ok and type(m) == "table" and type(m.kind) == "string" then
            m.type = nil
            S.bridge.emit_event("activity", m)
        end
    end
    rotate(S.activity_tail)
end

-- move.escape_trap (main's decision): after every respawn / rejoin, before other moves. It walks a
-- recorded exit when Claude stands in a known trap (the church start pit), else not_in_trap.
local function escape_after_spawn()
    if not S.escape_pending then return end
    local why = S.escape_pending
    S.escape_pending = nil
    local r = call("move", "escape_trap")
    ev("client_escape_trap", { after = why, ok = r.ok, reason = r.reason, detail = r.data and (r.data.detail or r.data.error) })
    S.stats.escapes = (S.stats.escapes or 0) + (r.ok and 1 or 0)
end

local function check_vitals()
    local t = now_s()
    if S.vitals_checked and t - S.vitals_checked < M.VITALS_CHECK_S then return end
    S.vitals_checked = t
    local mine = me()
    local surv = mine and type(mine.survival) == "table" and mine.survival
    if not surv then return end
    -- review H2: "low" = below the MODEL's policy (inventory.vitals_policy), and "has food" = what the
    -- stay-fed reflex can really use (hotbar, not marked bad). Food only in the bag is reported (in_bag)
    -- so the model can move_item it, instead of silent starvation.
    local inv = M.module("inventory")
    local pol = inv and type(inv.vitals_policy) == "function" and inv.vitals_policy() or {}
    local bad = {}
    if inv and type(inv.reflex_status) == "function" then
        local okr, rs = pcall(inv.reflex_status)
        if okr and type(rs) == "table" and type(rs.bad) == "table" then bad = rs.bad end
    end
    local pct_of = { hydration = pol.drink_below_pct, sustenance = pol.eat_below_pct }
    local lowstats = {}
    for stat in pairs(M.VITAL_NEEDS) do
        local v, mx = type(surv[stat]) == "table" and tonumber(surv[stat][1]), type(surv[stat]) == "table" and tonumber(surv[stat][2])
        if v then
            local lim = (mx or 100) * (tonumber(pct_of[stat]) or M.VITALS_LOW) / 100
            if v > lim + (mx or 100) * 0.1 then S.vitals_low[stat] = nil
            elseif v < lim then lowstats[#lowstats + 1] = { stat, v, mx } end
        end
    end
    if #lowstats == 0 then return end
    local lr = call("inventory", "list")
    if not lr.ok then return end
    local have, in_bag, unusable = {}, {}, {}
    for _, it in ipairs(lr.data.hotbar or {}) do
        if it.consumable then
            if bad[it.item] then unusable[it.consumable] = unusable[it.consumable] or {}; table.insert(unusable[it.consumable], it.name or it.item)
            else have[it.consumable] = true end
        end
    end
    for _, it in ipairs(lr.data.bag or {}) do
        if it.consumable then in_bag[it.consumable] = in_bag[it.consumable] or {}; table.insert(in_bag[it.consumable], it.name or it.item) end
    end
    for _, l in ipairs(lowstats) do
        local stat, v, mx = l[1], l[2], l[3]
        local need = M.VITAL_NEEDS[stat]
        local last = S.vitals_low[stat]
        if not have[need] and (not last or t - last >= M.VITALS_REPEAT_S) then
            S.vitals_low[stat] = t
            S.bridge.emit_event("vitals_low", { stat = stat, value = v, max = mx, has_food = have.food == true,
                                                has_drink = have.drink == true, in_bag = in_bag[need], unusable = unusable[need],
                                                policy_pct = pct_of[stat] })
            S.stats.vitals_low = S.stats.vitals_low + 1
        end
    end
end

-- items_dropped{by, items = [{id, name, item, count, consumable, distance}]}: another player dropped
-- items near Claude (sense: world item rows with dropped_by), once per drop burst (DROP_QUIET_S after
-- the last new item). Perception for the model ("Luis dropped food by me"), not a rule to pick up.
M.DROP_CHECK_S, M.DROP_RADIUS_M, M.DROP_QUIET_S = 2, 8, 2
local function check_drops()
    local t = now_s()
    if S.drops_checked and t - S.drops_checked < M.DROP_CHECK_S then return end
    S.drops_checked = t
    local r = call("sense", "census", { radius_m = M.DROP_RADIUS_M, max = 20, kinds = { items = true } })
    if not r.ok then return end
    if not S.drops_seen then -- first look after a (re)start: what already lies around is not news
        S.drops_seen = {}
        for _, it in ipairs(r.data.items or {}) do if it.id then S.drops_seen[it.id] = t end end
        return
    end
    for _, it in ipairs(r.data.items or {}) do
        if it.id and not S.drops_seen[it.id] then
            S.drops_seen[it.id] = t
            local by = it.dropped_by
            if by and by ~= S.name then
                local b = S.drop_burst or { items = {}, by = {} }
                S.drop_burst = b
                b.last = t
                b.by[by] = true
                b.items[#b.items + 1] = { id = it.id, name = it.name, item = it.item, count = it.count,
                                          consumable = it.consumable, distance = it.distance, dropped_by = by }
            end
        end
    end
    local b = S.drop_burst
    if b and t - b.last >= M.DROP_QUIET_S then
        local who = {}
        for n in pairs(b.by) do who[#who + 1] = n end
        table.sort(who)
        S.bridge.emit_event("items_dropped", { by = who[1], players = who, items = b.items })
        S.drop_burst = nil
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
            elseif S.chat_mode == "addressed" then -- legacy: only addressed lines, as command_received
                if M.addressed(m.text, S.prefixes, S.name) then
                    S.bridge.emit_event("command_received", { player = tostring(m.from or m.player_id or "?"), text = m.text })
                    S.stats.chat_forwarded = S.stats.chat_forwarded + 1
                else
                    S.stats.chat_ignored = S.stats.chat_ignored + 1
                end
            else
                -- Luis (2026-10-25): Claude reads ALL chat and the brain decides what is meant for him.
                -- mentions_me is the fast-path hint (a prefix or his name as a whole word).
                S.bridge.emit_event("chat_heard", { from = tostring(m.from or m.player_id or "?"),
                                                    player = tostring(m.from or m.player_id or "?"), text = m.text,
                                                    ts = m.ts, mentions_me = M.addressed(m.text, S.prefixes, S.name) })
                S.stats.chat_forwarded = S.stats.chat_forwarded + 1
            end
        end
    end
    rotate(S.chat_tail)
end

-- ------------------------------------------------------------------ background services (supervisor)
-- The client modules' own always-on loops/hooks: chat receive hooks, the vitals watcher, the
-- stay-fed reflex. Each start is idempotent. At boot (main menu) the world classes are not loaded
-- yet, so hook registration can fail; the bridge therefore re-checks every SERVICE_CHECK_S and
-- (re)starts a service that is not healthy, and re-arms it when its module file hot-reloads (the
-- start call is what swaps in the newest handler code). Only with start_modules (main.lua's boot
-- and bridge_start.lua; tests leave it off).
M.SERVICE_CHECK_S = 10
M.SERVICES = {
    { name = "chat", module = "chat", start = "start",
      healthy = function(mod)
          local st = type(mod.state) == "table" and mod.state or rawget(_G, "DWChat")
          return type(st) == "table" and type(st.hooks) == "table"
              and st.hooks["/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage"] ~= nil
      end },
    { name = "vitals", module = "sense", start = "vitals_start",
      healthy = function(mod)
          local st = type(mod.vitals_status) == "function" and mod.vitals_status() or {}
          -- hooks must belong to the CURRENT pawn: registered at the menu (hooked_pawn nil while the
          -- poll already sees a pawn) or for an earlier pawn -> not healthy -> vitals_start re-registers
          return st.running == true and (st.hooks or 0) >= #(mod.VITALS_HOOKS or {})
              and (st.me == nil or st.hooked_pawn == st.me)
      end },
    { name = "combat_guard", module = "combat", start = "guard_start", off_env = "DW_COMBAT_REFLEX",
      healthy = function(mod)
          local st = type(mod.status) == "function" and mod.status() or {}
          return st.guard == true
      end },
    { name = "fed_reflex", module = "inventory", start = "reflex_start",
      healthy = function(mod)
          local st = type(mod.reflex_status) == "function" and mod.reflex_status() or {}
          return st.running == true
      end },
    -- Client-hang fix (DISCOVERIES "Client hang (R2)"): ULightFlickeringWorldSubSystem's tick can
    -- deadlock the GameThread, so tickguard gives it a 1 h TickInterval on every new world instance.
    { name = "tickguard", module = "tickguard", start = "start",
      healthy = function(mod) return type(mod.healthy) == "function" and mod.healthy() == true end },
    -- Client-crash fix (BUGS L38): on -nullrhi every Niagara spawn is NULL, and the player character
    -- stores and later dereferences it (LocalFX); fxguard empties the trigger table on every pawn.
    { name = "fxguard", module = "fxguard", start = "start",
      healthy = function(mod) return type(mod.healthy) == "function" and mod.healthy() == true end },
}

local function supervise(force)
    if not S.services_on then return end
    local t = now_s()
    if not force and S.services_checked and t - S.services_checked < M.SERVICE_CHECK_S then return end
    S.services_checked = t
    for _, svc in ipairs(M.SERVICES) do
        local st = S.services[svc.name] or { starts = 0 }
        S.services[svc.name] = st
        if svc.off_env and os.getenv(svc.off_env) == "0" then st.state = "off (" .. svc.off_env .. "=0)"; goto continue end
        local mod, err = M.module(svc.module)
        local loads = S.mods[svc.module] and S.mods[svc.module].loads or 0
        if not mod or type(mod[svc.start]) ~= "function" then
            st.state, st.detail = "missing", err or ("no " .. svc.module .. "." .. svc.start)
        else
            local okh, healthy = pcall(svc.healthy, mod)
            healthy = okh and healthy == true
            local reloaded = st.loads == nil or st.loads ~= loads or S.rearm == true
            if reloaded then st.adopt_pending = true end
            local needs_start = not healthy or st.adopt_pending
            -- Failed adoption is retried under the same bounded backoff as an unhealthy service.
            local backoff = needs_start and not reloaded and st.starts >= 3 and st.last_try and t - st.last_try < 60
            if not needs_start then
                st.state, st.detail = "running", nil
            elseif backoff then
                st.state = "starting"
            else
                st.last_try = t
                local ok, r = pcall(mod[svc.start], S.text_log)
                local started = ok and r ~= false and not (type(r) == "table" and r.ok == false)
                st.starts, st.last_start = st.starts + 1, os.date("!%H:%M:%SZ")
                okh, healthy = pcall(svc.healthy, mod)
                healthy = okh and healthy == true
                st.adopt_pending = not (started and healthy)
                st.state = not st.adopt_pending and "running" or "starting"
                st.detail = (not ok) and tostring(r) or (not started and ((type(r) == "table" and r.reason) or "start failed"))
                    or (not healthy and "service not healthy") or nil
                ev("client_service_start", { name = svc.name, ok = started, state = st.state, reloaded = reloaded,
                                             detail = st.detail, starts = st.starts })
            end
            st.loads = loads
        end
        ::continue::
    end
    S.rearm = nil
end
M._supervise = supervise

-- ------------------------------------------------------------------ lifecycle
local function mkdir(p)
    ensure_dir(p)
end

-- ------------------------------------------------------------------ pause (disconnect / join)
-- crash_2026_10_25_19_08_42: a Lua UFunction call from a game-thread loop while the world was torn
-- down. Convention: disconnect.lua / join_server.lua set _G.DW_PAUSE = true first, and every loop does
-- no game work while it is set. The bridge still reads commands, but every tool that would touch the
-- game answers companion_down (ping / capabilities / bridge_status still work) and the running
-- action and waiters end with companion_down (without calling their cancel: no game calls). The
-- bridge clears the pause itself once a valid local pawn has existed for PAUSE_CLEAR_S in the game
-- world (not the front end), checking at most once a second and not before PAUSE_SETTLE_S, then
-- re-arms the services (chat, vitals, combat guard, stay-fed reflex).
M.PAUSE_SETTLE_S, M.PAUSE_CLEAR_S = 5, 3
M.PAUSE_SAFE_TOOLS = { ping = true, capabilities = true, bridge_status = true }
local function paused() return rawget(_G, "DW_PAUSE") == true end
M._paused = paused

local function on_pause_start()
    S.pause = { since = now_s() }
    ev("client_paused", {})
    local a = S.action
    if a then
        if a.pause_cleanup then pcall(a.pause_cleanup) end
        a.cancel = nil
        finish(a, fail("companion_down", { detail = "client paused (disconnect or join in progress)" }))
    end
    for _, w in ipairs(S.waiters) do
        (w.chan or S.bridge).reply(w.id, fail("companion_down", { detail = "client paused" }))
    end
    S.waiters = {}
end

local function check_unpause()
    local t = now_s()
    local P = S.pause
    if t - P.since < M.PAUSE_SETTLE_S or (P.checked and t - P.checked < 1) then return end
    P.checked = t
    local sense = M.module("sense")
    local pawn = sense and type(sense.local_pawn) == "function" and select(2, pcall(sense.local_pawn)) or nil
    local name = pawn and select(2, pcall(function() return pawn:GetFullName() end)) or nil
    local in_world = type(name) == "string" and name:find("L_World", 1, true) ~= nil and not name:find("FrontEnd", 1, true)
    if not in_world then P.pawn_since = nil; return end
    P.pawn_since = P.pawn_since or t
    if t - P.pawn_since >= M.PAUSE_CLEAR_S then
        _G.DW_PAUSE = nil
        S.pause, S.rearm, S.escape_pending = nil, true, "rejoin"
        ev("client_unpaused", { pawn = name })
        text_log("bridge: pause cleared (pawn in world for " .. M.PAUSE_CLEAR_S .. " s); re-arming services")
    end
end

function M.step()
    if paused() then
        if not S.pause then on_pause_start() end
        local ok, err = pcall(S.bridge.poll) -- commands still answered (companion_down, see dispatch)
        if not ok then ev("client_bridge_poll_error", { err = tostring(err) }) end
        if S.debug then pcall(S.debug.poll) end
        ok, err = pcall(check_unpause)
        if not ok then ev("client_unpause_error", { err = tostring(err) }) end
        if paused() then return end
    elseif S.pause then
        S.pause, S.rearm = nil, true -- cleared by someone else: re-arm too
    end
    local ok, err = pcall(S.bridge.poll)
    if not ok then ev("client_bridge_poll_error", { err = tostring(err) }) end
    if S.debug then
        ok, err = pcall(S.debug.poll)
        if not ok then ev("client_debug_poll_error", { err = tostring(err) }) end
    end
    ok, err = pcall(tick_action)
    if not ok then ev("client_action_tick_error", { err = tostring(err) }) end
    ok, err = pcall(forward_chat) -- before the waiters, so an echo read now resolves its say now
    if not ok then ev("client_chat_forward_error", { err = tostring(err) }) end
    ok, err = pcall(tick_waiters)
    if not ok then ev("client_waiters_error", { err = tostring(err) }) end
    ok, err = pcall(forward_vitals)
    if not ok then ev("client_vitals_forward_error", { err = tostring(err) }) end
    ok, err = pcall(check_vitals)
    if not ok then ev("client_vitals_check_error", { err = tostring(err) }) end
    ok, err = pcall(check_drops)
    if not ok then ev("client_drops_check_error", { err = tostring(err) }) end
    ok, err = pcall(forward_moves)
    if not ok then ev("client_moves_forward_error", { err = tostring(err) }) end
    ok, err = pcall(forward_gather)
    if not ok then ev("client_gather_forward_error", { err = tostring(err) }) end
    ok, err = pcall(escape_after_spawn)
    if not ok then ev("client_escape_error", { err = tostring(err) }) end
    ok, err = pcall(forward_activity)
    if not ok then ev("client_activity_forward_error", { err = tostring(err) }) end
    ok, err = pcall(supervise, S.rearm == true)
    if not ok then ev("client_supervise_error", { err = tostring(err) }) end
end

function M.status()
    local mods = {}
    for name, c in pairs(S.mods) do mods[name] = { ok = c.mod ~= nil, err = c.err, loads = c.loads } end
    return { dir = S.dir, paths = S.bridge.paths(), stats = S.bridge.stats, chat = S.stats, modules = mods,
             action = S.action and { kind = S.action.kind, id = S.action.id } or S.bridge.null,
             waiting = #S.waiters, tools = implemented_tools(), chat_events = S.chat_path, vitals_events = S.vitals_path,
             services = S.services_on and S.services or "off (start_modules=false)", started = S.started,
             paused = paused(), pause = S.pause }
end

-- opts: root (default $DW_CLIENT_ROOT or C:/gameserver), dir (bridge dir), log (fn(msg) text logger),
-- jlog (dwlog-like {event}), scripts (module dir), chat_events (path), start_modules (call chat.start),
-- no_loop (tests drive M.step), poll_ms, from_start (read the brain's file from 0), name (own chat name).
function M.start(opts)
    opts = opts or {}
    local prev = rawget(_G, "__dwc_bridge")
    -- read positions to take over from the running instance (BUGS L20: nothing written meanwhile is lost)
    local handover = prev and type(prev.offsets) == "function" and select(2, pcall(prev.offsets)) or nil
    if type(handover) ~= "table" then handover = nil end
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
          started = os.date("!%Y-%m-%dT%H:%M:%SZ"), started_epoch = os.time(),
          stats = { chat_forwarded = 0, chat_ignored = 0, chat_rotations = 0, attacked = 0, vitals_low = 0, unreachable = 0 },
          attacked_at = {}, vitals_low = {}, prefixes = prefixes(),
          -- DW_CLIENT_CHAT=heard (default): every other player's line -> chat_heard; =addressed: legacy filter
          chat_mode = (os.getenv("DW_CLIENT_CHAT") or "heard"):lower(),
          name = opts.name or os.getenv("DW_COMPANION_NAME") or "Claude" }
    assert(bridge.init({ dir = dir, log = jlog, in_name = M.IN_NAME, out_name = M.OUT_NAME, from_start = opts.from_start,
                         offset = handover and handover.main }))
    -- every tool goes through dispatch, so modules can appear (or break) while the bridge runs.
    -- install(ch) registers the handlers on one channel; ctx.chan tells async replies where to go.
    local function install(ch)
        local function wrap(tool)
            return function(args, ctx)
                ctx.chan = ch
                if paused() and not M.PAUSE_SAFE_TOOLS[tool] then
                    if tool == "get_state" then
                        return { ok = false, reason = "companion_down", data = { body = "client", paused = true,
                                 not_implemented = {}, detail = "client paused (disconnect or join in progress)" } }
                    end
                    return fail("companion_down", { tool = tool, detail = "client paused (disconnect or join in progress)" })
                end
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
        for _, t in ipairs(ch.TOOLS) do ch.handlers[t] = wrap(t) end
        for t in pairs(R) do ch.handlers[t] = wrap(t) end
        for _, t in ipairs({ "look", "inspect", "interact", "travel", "where", "world_info", "spells" }) do ch.handlers[t] = wrap(t) end
        ch.handlers.ping = function()
            -- started (this bridge instance's start, a new value on every reload) and the action slot let the
            -- brain fail a request at once when the body restarted or lost it (BUGS L2b)
            local a = S.action
            -- waiters (cast, move_item, equip, ...) are in flight too, outside the action slot: list their ids
            -- so the brain never reports a waiting command as lost (spells agent 2026-10-26: a 10 s cast came
            -- back lost_by_body)
            local waiting = {}
            for _, w in ipairs(S.waiters or {}) do if w.id then waiting[#waiting + 1] = w.id end end
            return { ok = true, data = { pong = true, body = "client", server_clock = os.clock(), server_time = os.time(),
                                         started = S.started_epoch, waiters = waiting,
                                         action = a and { id = a.id, kind = a.kind, age_s = a.started and (now_s() - a.started) or S.bridge.null }
                                             or S.bridge.null } }
        end
        ch.handlers.capabilities = function()
            local okm, list, aliases, ver = pcall(M.manifest)
            local data = { tools = implemented_tools(), body = "client" }
            if okm then data.manifest, data.aliases, data.manifest_version = list, aliases, ver
            else ev("client_manifest_error", { err = tostring(list) }) end
            return { ok = true, data = data }
        end
        ch.handlers.bridge_status = function() return { ok = true, data = M.status() } end
        -- other names may be module HANDLERS: route them too
        setmetatable(ch.handlers, { __index = function(_, tool)
            if type(tool) == "string" and module_handler(tool) then return wrap(tool) end
            return nil
        end })
    end
    install(bridge)
    -- The DEBUG channel: the same tools on a second file pair (debug_to_client.jsonl ->
    -- client_to_debug.jsonl), for people and tools testing live (tools/bridge_cmd --channel debug), so
    -- their replies never land in the live brain's file. Events (chat, attacked, ...) go only to the
    -- main channel; task_done/task_failed of an action started here are answered here.
    if opts.debug_channel ~= false then
        S.debug = assert(loadfile(shared .. "/bridge.lua"))()
        assert(S.debug.init({ dir = dir, log = jlog, in_name = M.DEBUG_IN_NAME, out_name = M.DEBUG_OUT_NAME,
                              offset = handover and handover.debug }))
        install(S.debug)
    end
    -- chat events (client_mod/scripts/chat.lua writes them); start at the end: no history replay
    S.chat_path = opts.chat_events or (root .. "/client_io/events/chat.jsonl")
    S.chat_tail = bridge.new_tail(S.chat_path)
    -- vitals events (sense.lua's watcher writes them): damage -> attacked
    S.vitals_path = opts.vitals_events or (root .. "/client_io/events/vitals.jsonl")
    S.vitals_tail = bridge.new_tail(S.vitals_path)
    S.move_path = opts.move_events or (root .. "/client_io/events/move.jsonl")
    S.move_tail = bridge.new_tail(S.move_path)
    S.gather_path = opts.gather_events or (root .. "/client_io/events/gather.jsonl")
    S.gather_tail = bridge.new_tail(S.gather_path)
    S.activity_path = opts.activity_events or (root .. "/client_io/events/activity.jsonl")
    S.activity_tail = bridge.new_tail(S.activity_path)
    S.services, S.services_on = {}, opts.start_modules == true
    if S.services_on then pcall(supervise, true) end -- now, then every SERVICE_CHECK_S from step()
    if not opts.no_loop then
        S.loop = LoopInGameThreadWithDelay(opts.poll_ms or M.POLL_MS, function() M.step() end)
    end
    _G.__dwc_bridge = { stop = M.stop, status = M.status, module = M, busy = M.busy, offsets = M.offsets }
    ev("client_bridge_started", { dir = dir, poll_ms = opts.poll_ms or M.POLL_MS, offset = bridge.paths().offset,
                                  chat = S.chat_path })
    text_log("bridge: started on " .. dir .. " tools=" .. table.concat(implemented_tools(), ","))
    return M.status()
end

-- ------------------------------------------------------------------ safe restart (BUGS L20)
-- Why a restart now would drop work, or nil when idle: an action in the slot (follow/go_to/interact...),
-- waiters (say/drop confirmations), or brain/debug lines written but not read yet.
function M.busy()
    if not S then return nil end
    local why = {}
    if S.action then why[#why + 1] = "action " .. tostring(S.action.kind) .. " (" .. tostring(S.action.id) .. ")" end
    if #S.waiters > 0 then why[#why + 1] = #S.waiters .. " waiting confirmation(s)" end
    local function unread(ch)
        if not ch then return 0 end
        local p = ch.paths()
        local f = io.open(p.input, "rb")
        if not f then return 0 end
        local size = f:seek("end") or 0
        f:close()
        return math.max(0, size - (p.offset or 0))
    end
    local u = unread(S.bridge) + unread(S.debug)
    if u > 0 then why[#why + 1] = u .. " unread command bytes" end
    return #why > 0 and table.concat(why, ", ") or nil
end

function M.offsets()
    if not S then return nil end
    return { main = S.bridge and S.bridge.paths().offset, debug = S.debug and S.debug.paths().offset }
end

-- Restart only when the running bridge is idle: now if idle, else re-check every 250 ms for up to
-- opts.wait_s (5) and start the moment it is; refuse (with the reason, logged and returned) when it
-- stays busy; opts.force = true restarts at once (emergency). The new instance takes over the old read
-- positions either way. Returns {ok, started | deferred | refused, why}.
M.RESTART_WAIT_S, M.RESTART_POLL_MS = 5, 250
function M.restart_when_idle(opts)
    opts = opts or {}
    local prev = rawget(_G, "__dwc_bridge")
    local why
    if opts.immediate_only and prev then
        if type(prev.busy) ~= "function" then
            return { ok = false, refused = true, why = "bridge busy state unavailable" }
        end
        local ok_busy, busy = pcall(prev.busy)
        if not ok_busy or (busy ~= nil and type(busy) ~= "string") then
            return { ok = false, refused = true, why = "bridge busy state unavailable" }
        end
        if busy then return { ok = false, refused = true, why = busy } end
    else
        why = prev and type(prev.busy) == "function" and select(2, pcall(prev.busy)) or nil
    end
    if type(why) ~= "string" then why = nil end
    if not why or opts.force then
        local st = M.start(opts)
        return { ok = true, started = true, forced = (why and opts.force) and why or nil, status = st }
    end
    local wait_s = tonumber(opts.wait_s) or M.RESTART_WAIT_S
    local clock = M.clock or os.clock
    local t0 = clock()
    local log = opts.log or function() end
    local handle
    local function try()
        local w = select(2, pcall(prev.busy))
        if type(w) ~= "string" then
            if handle and CancelDelayedAction then pcall(CancelDelayedAction, handle) end
            handle = nil
            pcall(M.start, opts)
            pcall(log, "bridge: restarted once idle (waited for: " .. why .. ")")
            return true
        end
        if clock() - t0 >= wait_s then
            if handle and CancelDelayedAction then pcall(CancelDelayedAction, handle) end
            handle = nil
            pcall(log, "bridge: restart REFUSED, still busy after " .. wait_s .. " s: " .. w .. " (force=true overrides)")
            local okj, jl = pcall(function() return opts.jlog end)
            if okj and jl and jl.event then pcall(jl.event, "client_bridge_restart_refused", { why = w }) end
            M.last_restart = { refused = true, why = w }
            return true
        end
        return false
    end
    if opts.no_loop then -- tests drive it: M.restart_poll() steps once
        M.restart_poll = try
    else
        handle = LoopInGameThreadWithDelay(M.RESTART_POLL_MS, function() try() end)
    end
    M.last_restart = { deferred = true, why = why }
    return { ok = true, deferred = true, why = why, wait_s = wait_s }
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
