-- arbiter: ONE owner of Claude's pawn at a time, by priority (docs/design/real-player-remediation.md
-- "Next-wave hardening" 2; ARCHITECTURE section 8). Route R2, client side.
--
-- Prior art (search-before-building, DISCOVERIES "Client combat (R2)"):
--   * Behavior Multi-Queues (Cutumisu & Szafron, AIIDE 2009, used in Neverwinter Nights): one queue
--     per priority; a higher-priority behaviour interrupts, the interrupted one is SUSPENDED and
--     RESUMED afterwards instead of restarted. That is what this module does, with one slot per level.
--   * Subsumption (Brooks; MIT 6.189 "arbitration" lecture): higher layers suppress lower ones.
--   * Behaviour-tree "lower priority" observer aborts (Unity Behavior, UE BT decorators): the reflex
--     layer watches conditions and aborts lower-priority work.
-- Decision: ADAPT (a priority slot + suspended stack + leases), BUILD the thin Lua (no Lua library
-- for this exists; the pattern is ~150 lines).
--
-- Levels: reflex (4) > command (3) > task (2) > idle (1).
--   * A request at a HIGHER level than the owner preempts it: the owner is suspended (its move is
--     snapshotted) if resumable, else stopped.
--   * A request at the SAME level replaces the owner (a new command replaces the old one; the old
--     one is stopped, not suspended), unless spec.queue_same=false (then it is refused).
--   * A LOWER request is refused (ok=false, reason="busy", owner=...).
--   * release() hands the pawn back: the newest suspended owner is resumed (its on_resume, or its
--     move snapshot replayed through move.lua's public API).
--   * Leases: an owner with lease_s must renew() (each loop tick); an expired lease is released
--     automatically (a crashed or hot-reloaded loop can never hold the pawn forever).
--   * Unregistered movement (the bridge driving move.lua directly) is adopted as an implicit
--     "command" owner the first time a higher request arrives, so a brain follow is suspended and
--     resumed after a fight even before the bridge registers its actions.
-- Movement goes ONLY through move.lua's public API: stop / go_to / follow / status (+ snapshot /
-- restore when the locomotion agent's move.lua offers them).
--
-- API (log = DWClient text logger, may be nil):
--   A.request(log, spec) -> {ok, token, preempted = {name, level, suspended}} | {ok=false, reason, owner}
--      spec = {name, level = "reflex"|"command"|"task"|"idle"|n, resumable = true, uses_move = true,
--              lease_s, on_suspend(log, rec), on_resume(log, rec) -> ok?, on_stop(log, rec, why), data}
--   A.release(log, token, why) -> {ok, resumed = name|nil}
--   A.renew(token)  A.holds(token)  A.owner()  A.is_suspended(token)  A.status()  A.reset(log)
--   A.cancel(log, token, why)   -- drop a SUSPENDED entry (its owner gave up)
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")

local A = {}
A.LEVELS = { idle = 1, task = 2, command = 3, reflex = 4 }
A.LEVEL_NAMES = { "idle", "task", "command", "reflex" }
A.MAX_SUSPEND_S = 300   -- a suspended owner older than this is stopped instead of resumed
A.MAX_STACK = 6

local function S()
    local s = _G.DWArbiter
    if not s then
        s = { seq = 0, owner = nil, stack = {}, history = {}, counts = { granted = 0, refused = 0, suspended = 0, resumed = 0, expired = 0 } }
        _G.DWArbiter = s
    end
    return s
end

-- Clock: wall seconds (os.time has 1 s resolution; good enough for leases and suspend age).
-- Tests (and the combat loop) may set A.clock to a finer source.
local function now() return (A.clock or os.time)() end

local function say(log, msg) if log then pcall(log, "arbiter: " .. msg) end end

local function level_of(l)
    if type(l) == "number" then return l end
    return A.LEVELS[tostring(l or "task")] or 2
end

-- move.lua instance: the bridge's or our own loadfile (state lives in _G.DW_MOVE either way).
function A.set_move(m) A._move = m end
local function mv()
    if A._move then return A._move end
    local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/move.lua"))() end)
    if ok then A._move = m end
    return A._move
end
-- World teardown guard (main's crash convention): while _G.DW_PAUSE is true (set by disconnect /
-- join, cleared by the bridge once a new pawn has been stable for 3 s) nothing here touches the game:
-- no move calls, no resumes (the suspended stack is dropped; the world it belonged to is gone).
local function paused() return _G.DW_PAUSE == true end
A.paused = paused
local function move_call(fn, ...)
    if paused() then return nil end
    local m = mv()
    if not (m and m[fn]) then return nil end
    local ok, r = pcall(m[fn], ...)
    return ok and r or nil
end

local function history(s, ev)
    ev.t = now()
    s.history[#s.history + 1] = ev
    if #s.history > 30 then table.remove(s.history, 1) end
end

-- What move.lua is doing, as a replayable snapshot (move.snapshot when available, else from status).
local function move_snapshot()
    local m = mv()
    if not m then return nil end
    if m.snapshot then
        local ok, snap = pcall(m.snapshot)
        if ok then return snap end
    end
    local st = move_call("status")
    if type(st) ~= "table" or st.mode == nil or st.mode == "idle" then return nil end
    if st.mode == "follow" and st.target then
        return { mode = "follow", goal = st.target, opts = { tolerance_m = st.tolerance_m or 3 }, derived = true }
    end
    if st.mode == "go_to" and (st.goal or st.target) then
        return { mode = "go_to", goal = st.goal or st.target, opts = { tolerance_m = st.tolerance_m }, derived = true }
    end
    return { mode = st.mode, unreplayable = true }
end
A._move_snapshot = move_snapshot

local function move_restore(log, snap)
    if type(snap) ~= "table" or snap.unreplayable then return false end
    local m = mv()
    if not m then return false end
    if m.restore and not snap.derived then
        local ok, r = pcall(m.restore, log, snap)
        return ok and type(r) == "table" and r.ok ~= false
    end
    local r
    if snap.mode == "follow" then r = move_call("follow", log, snap.goal, (snap.opts or {}).tolerance_m or 3, snap.opts)
    elseif snap.mode == "go_to" then r = move_call("go_to", log, snap.goal, snap.opts) end
    return type(r) == "table" and r.ok ~= false
end

local function move_is_idle()
    local st = move_call("status")
    return type(st) ~= "table" or st.mode == nil or st.mode == "idle"
end

local function expired(rec) return rec.lease_s and now() - (rec.renewed or rec.since) > rec.lease_s end

local function stop_rec(log, rec, why)
    rec.state = "stopped"
    if rec.on_stop then pcall(rec.on_stop, log, rec, why) end
    if rec.uses_move ~= false then move_call("stop", log) end
    history(S(), { ev = "stop", name = rec.name, why = why })
end

local function suspend_rec(log, s, rec, by)
    rec.state = "suspended"
    rec.suspended_at = now()
    rec.suspended_by = by
    if rec.uses_move ~= false then
        rec.move_snap = move_snapshot()
        move_call("stop", log)
    end
    if rec.on_suspend then pcall(rec.on_suspend, log, rec) end
    table.insert(s.stack, rec)
    while #s.stack > A.MAX_STACK do stop_rec(log, table.remove(s.stack, 1), "stack_full") end
    s.counts.suspended = s.counts.suspended + 1
    history(s, { ev = "suspend", name = rec.name, by = by })
    say(log, "suspended " .. rec.name .. " (by " .. tostring(by) .. ")")
end

-- Hand the pawn to the newest suspended entry that is still fresh.
local function resume_next(log, s)
    if paused() then
        for _, r in ipairs(s.stack) do r.state = "dropped_paused" end
        if #s.stack > 0 then history(s, { ev = "drop_paused", n = #s.stack }) end
        s.stack = {}
        return nil
    end
    while #s.stack > 0 do
        local rec = table.remove(s.stack)
        if now() - (rec.suspended_at or 0) > A.MAX_SUSPEND_S then
            stop_rec(log, rec, "suspended_too_long")
        else
            rec.state = "owner"
            rec.renewed = now()
            s.owner = rec
            local ok = true
            if rec.on_resume then
                local okc, r = pcall(rec.on_resume, log, rec)
                ok = okc and r ~= false
            elseif rec.uses_move ~= false and rec.move_snap then
                ok = move_restore(log, rec.move_snap)
            end
            if ok then
                s.counts.resumed = s.counts.resumed + 1
                history(s, { ev = "resume", name = rec.name })
                say(log, "resumed " .. rec.name)
                return rec.name
            end
            s.owner = nil
            stop_rec(log, rec, "resume_failed")
        end
    end
    return nil
end

-- Lazy housekeeping: an expired lease releases its owner.
local function housekeep(log, s)
    local o = s.owner
    if o and expired(o) then
        s.counts.expired = s.counts.expired + 1
        history(s, { ev = "expired", name = o.name })
        say(log, "lease expired: " .. o.name)
        s.owner = nil
        if o.on_stop then pcall(o.on_stop, log, o, "lease_expired") end
        resume_next(log, s)
    end
end

local function brief(rec)
    if not rec then return nil end
    return { name = rec.name, level = A.LEVEL_NAMES[rec.level] or rec.level, token = rec.token, since = rec.since,
             state = rec.state, implicit = rec.implicit, suspended_by = rec.suspended_by }
end
A.brief = brief

function A.request(log, spec)
    spec = spec or {}
    local s = S()
    housekeep(log, s)
    local lvl = level_of(spec.level)
    if paused() then return { ok = false, reason = "paused" } end
    local cur = s.owner
    -- adopt unregistered movement (e.g. the bridge's follow) so it can be suspended and resumed
    if not cur and lvl > A.LEVELS.command - 1 and spec.adopt ~= false and not move_is_idle() then
        local st = move_call("status") or {}
        s.seq = s.seq + 1
        cur = { token = s.seq, name = "move:" .. tostring(st.mode), level = A.LEVELS.command, resumable = true,
                uses_move = true, implicit = true, since = now(), state = "owner" }
        s.owner = cur
    end
    local preempted
    if cur then
        if lvl < cur.level or (lvl == cur.level and spec.replace_same == false) then
            s.counts.refused = s.counts.refused + 1
            return { ok = false, reason = "busy", owner = brief(cur) }
        end
        s.owner = nil
        if lvl > cur.level and cur.resumable ~= false then
            suspend_rec(log, s, cur, spec.name)
            preempted = { name = cur.name, level = A.LEVEL_NAMES[cur.level], suspended = true }
        else
            stop_rec(log, cur, "replaced_by:" .. tostring(spec.name))
            preempted = { name = cur.name, level = A.LEVEL_NAMES[cur.level], suspended = false }
        end
    end
    s.seq = s.seq + 1
    local rec = { token = s.seq, name = tostring(spec.name or "?"), level = lvl, resumable = spec.resumable ~= false,
                  uses_move = spec.uses_move, lease_s = spec.lease_s, on_suspend = spec.on_suspend,
                  on_resume = spec.on_resume, on_stop = spec.on_stop, data = spec.data, since = now(), state = "owner" }
    rec.renewed = rec.since
    s.owner = rec
    s.counts.granted = s.counts.granted + 1
    history(s, { ev = "grant", name = rec.name, level = A.LEVEL_NAMES[lvl], preempted = preempted and preempted.name })
    say(log, string.format("granted %s (%s)%s", rec.name, A.LEVEL_NAMES[lvl] or lvl,
        preempted and (" preempting " .. preempted.name .. (preempted.suspended and " [suspended]" or " [stopped]")) or ""))
    return { ok = true, token = rec.token, preempted = preempted }
end

function A.release(log, token, why)
    local s = S()
    if not (s.owner and s.owner.token == token) then
        -- not the owner: maybe a suspended entry giving up
        A.cancel(log, token, why or "released_while_suspended")
        return { ok = false, reason = "not_owner" }
    end
    local o = s.owner
    s.owner = nil
    o.state = "released"
    history(s, { ev = "release", name = o.name, why = why })
    say(log, "released " .. o.name .. (why and (" (" .. tostring(why) .. ")") or ""))
    local resumed = resume_next(log, s)
    return { ok = true, resumed = resumed }
end

function A.cancel(log, token, why)
    local s = S()
    for i = #s.stack, 1, -1 do
        if s.stack[i].token == token then
            local rec = table.remove(s.stack, i)
            rec.state = "cancelled"
            history(s, { ev = "cancel", name = rec.name, why = why })
            return true
        end
    end
    return false
end

function A.renew(token)
    local s = S()
    if s.owner and s.owner.token == token then s.owner.renewed = now(); return true end
    return false
end

function A.holds(token)
    local s = S()
    housekeep(nil, s)
    return s.owner ~= nil and s.owner.token == token
end

function A.is_suspended(token)
    for _, r in ipairs(S().stack) do if r.token == token then return true end end
    return false
end

function A.owner()
    local s = S()
    housekeep(nil, s)
    return brief(s.owner)
end

function A.status()
    local s = S()
    housekeep(nil, s)
    local stack = {}
    for i = #s.stack, 1, -1 do
        local r = brief(s.stack[i])
        r.age_s = now() - (s.stack[i].suspended_at or now())
        r.has_move_snap = s.stack[i].move_snap ~= nil
        stack[#stack + 1] = r
    end
    return { ok = true, owner = brief(s.owner), suspended = stack, counts = s.counts, history = s.history }
end

function A.reset(log)
    local s = S()
    if s.owner then stop_rec(log, s.owner, "reset") end
    for _, r in ipairs(s.stack) do r.state = "dropped" end
    s.owner, s.stack = nil, {}
    return { ok = true }
end

-- Brain-visible handler: arbiter_status (read-only).
A.HANDLERS = {
    arbiter_status = function() return A.status() end,
}

return A
