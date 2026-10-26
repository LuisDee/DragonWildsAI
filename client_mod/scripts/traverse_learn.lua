-- traverse_learn.lua: READ-ONLY traversal recorder and per-world learned-link store (task R2.12;
-- design docs/research/2026-10-25-traversal.md section 3.5). It never moves the pawn, never presses
-- input and never writes game state. It only reads replicated movement state, runs a few downward
-- traces (reads) to tell a gap from a hop, and writes files.
--
-- What it does, per frame (one LoopInGameThreadWithDelay(1) loop, hot-reload safe):
--   * tracks every other player's pawn (simulated proxy: MovementMode, Velocity,
--     ReplicatedJumpCurrentCount, position) and Claude's own pawn (source "self");
--   * opens a traversal EVENT when a pawn starts falling (or its jump count rises) and closes it on
--     landing: take-off point and speed, landing point, apex, jump-count changes, mid-air impulses,
--     evade/spell multicasts and fall damage seen (hooks), run-up length, heading;
--   * classifies it: shape up | gap | down | flat, move drop | jump | sprint_jump | double_jump |
--     air_dash | windstep; flat hops are kept as raw events only;
--   * clusters kept events into LINKS (leader clustering: endpoints within from_merge_m/to_merge_m
--     and heading within heading_merge_deg -> the same link, running-mean endpoints, n_seen++);
--   * Claude's own landings that match a link mark it VERIFIED (n_ok++); his own useful crossings
--     that match nothing become links with source "self" (verified at once).
-- Files (world = DW world id, see world_id()):
--   raw events  <root>/logs/state/worlds/<world>/traversal_events.jsonl   (gitignored, append-only)
--   link store  <root>/data/skills/<world>/traversal_links.json           (git-tracked; ONE writer: this module)
-- API for move.lua (positions: {x,y,z} metres or {X,Y,Z} centimetres; results in metres). Link
-- endpoints are FEET level (capsule centre - half height); raw-event samples are capsule centres.
--   M.links_near(pos, radius_m, opts) -> { link..., d_m } sorted by distance of link.from
--   M.best_link(from, to, opts)       -> link, info | nil, reason   (detour cost through one link)
--   M.usable(link, env)               -> bool, reason ("needs:DoubleJump", "disabled", ...)
--   M.record_attempt(log, id, ok, reason)   (move.lua reports its own tries; 3 fails in a row disable)
--   opts.env = { double_jump=bool, air_dash=bool, windstep=bool }; default = Claude today (none).
-- Commands: client_mod/commands/learn_start.lua, learn_status.lua, learn_stop.lua.
-- Loops honour _G.DW_PAUSE and an invalid controller/pawn (no UObject access then).
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

local M = {}

M.cfg = {
    max_players = 6,          -- other players tracked at once
    discover_s = 1.0,         -- re-scan PlayerStates this often
    ground_spacing_cm = 25,   -- grounded ring sample spacing
    ground_ring = 80,         -- grounded samples kept per pawn (run-up, take-off point)
    min_air_s = 0.12,         -- shorter airborne blips are not events
    max_air_s = 15,           -- longer: aborted (flying / glitch)
    teleport_cm = 2000,       -- one-frame jump above this = teleport/respawn: abort and reset
    max_horiz_m = 40,         -- longer flights are not links
    up_m = 0.6,               -- dz >= this: "up" (MaxStepHeight 45 cm + margin)
    down_m = 1.5,             -- dz <= -this: "down" (smaller drops are walkable by the local planner)
    gap_min_m = 1.5,          -- a flat-ish flight this long is probed for a gap
    gap_depth_m = 1.0,        -- floor below the arc deeper than this under the lower end = gap
    gap_probe_step_m = 0.5,
    gap_probe_max = 12,       -- traces per event at most (~1 ms each)
    probe_max_m = 80,         -- only probe flights this close to Claude (client collision streaming)
    probe_clear_cm = 70,      -- no probe this close to the landing (the jumper and his gear stand there)
    walk_step_cm = 45,        -- walkable-terrain test: per probe segment |dz| <= step + slope x length
    walk_slope = 0.3,
    sprint_cms = 520,         -- take-off horizontal speed above this = sprinting (walk 450, sprint 680)
    impulse_vz = 350,         -- mid-air vertical velocity jump above this = second jump impulse
    dash_cms = 300,           -- mid-air horizontal speed rise above this within dash_window_s = dash
    dash_window_s = 0.2,
    windstep_rise_m = 2.5,    -- rise above take-off beyond a single jump (apex 1.8 m) ...
    windstep_rise_dj_m = 4.5, -- ... or beyond a double jump (UNMEASURED; first-order ~3-3.6 m) = Windstep
    cast_window_s = 8,        -- a spell cast this long before take-off counts (Windstep: 7 s to use)
    runup_max_m = 15,
    runup_heading_deg = 25,
    from_merge_m = 1.5,       -- clustering radii
    to_merge_m = 2.0,
    heading_merge_deg = 25,
    match_from_m = 2.0,       -- a self crossing verifies a link within these radii
    match_to_m = 2.0,
    self_min_up_m = 1.0,      -- Claude's own step-ups below this never create a link (they still verify one)
    fail_disable = 3,       -- consecutive failed attempts -> disabled
    save_every_s = 2.0,       -- store write debounce
    samples_max = 120,        -- airborne samples kept in a raw event (replay fixtures)
    sample_every_s = 0.033,
    build = os.getenv("DW_CLIENT_BUILD") or "26162923",
}

-- Move ranks: the easiest move seen to cross a link is what it needs.
M.RANK = { drop = 0, jump = 1, sprint_jump = 2, double_jump = 3, air_dash = 4, windstep = 5 }
M.NEEDS = {
    drop = { sprint = false }, jump = { sprint = false }, sprint_jump = { sprint = true },
    double_jump = { perks = { "DoubleJump" } },
    air_dash = { perks = { "AirDash" } },
    windstep = { spells = { "Windstep" }, runes = { Air = 5 } },
}
-- EMovementMode: 1 Walking, 2 NavWalking, 3 Falling, 4 Swimming, 5 Flying, 6 Custom. Dominion has ONE
-- custom mode, ECustomMovementMode CMOVE_Dash = 1 (dump Dominion_enums.hpp:1055): MOVE_Custom IS the
-- Air Dash (live 19:44:14: Luis's proxy went 3 -> 6 at the apex of a double jump, then 3 again).
local MODE_FALLING, MODE_SWIMMING, MODE_FLYING, MODE_CUSTOM = 3, 4, 5, 6

-- ------------------------------------------------------------------ state (survives hot reload)
local function S()
    local s = rawget(_G, "DW_LEARN")
    if not s then
        s = { gen = 0, trackers = {}, marks = {}, hooks = {}, counts = { events = 0, kept = 0, links_new = 0,
              merged = 0, verified = 0, aborted = 0, saves = 0, traces = 0, ticks = 0, hook_hits = 0 } }
        _G.DW_LEARN = s
    end
    return s
end
M._state = S

local json
local function J()
    json = json or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    return json
end

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function r2(x) return x and math.floor(x * 100 + 0.5) / 100 or nil end
local function m3(p) return { r2(p.X / 100), r2(p.Y / 100), r2(p.Z / 100) } end
local function cm(p) -- {x,y,z} metres or {X,Y,Z} cm -> {X,Y,Z} cm
    if type(p) ~= "table" then return nil end
    if p.X then return { X = p.X, Y = p.Y, Z = p.Z or 0 } end
    if p[1] then return { X = p[1] * 100, Y = p[2] * 100, Z = (p[3] or 0) * 100 } end
end
local function heading(a, b) return math.deg(math.atan(b.Y - a.Y, b.X - a.X)) end
local function ang(a, b) local d = math.abs(a - b) % 360; return d > 180 and 360 - d or d end
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t or os.time()) end
local function try(f) local ok, x = pcall(f); if ok then return x end; return nil end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end

local function mkdir(p)
    ensure_dir(p)
end

-- ------------------------------------------------------------------ world id and files
-- The world id: opts.world, _G.DW_WORLD_GUID, env DW_WORLD_GUID, <root>/client_io/world_guid.txt,
-- else "shockbyte" (the only world Claude's client joins today; brain/worlds.py uses the same name
-- via DW_WORLD_GUID). Sanitised like brain/worlds.py sanitize().
local function sanitize(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[^%w_%-]", ""):sub(1, 64)
    return s ~= "" and s or nil
end

function M.world_id(opt)
    local w = sanitize(opt); if w then return w, "opts" end
    w = sanitize(rawget(_G, "DW_WORLD_GUID")); if w then return w, "global" end
    w = sanitize(os.getenv("DW_WORLD_GUID")); if w then return w, "env" end
    local f = io.open(ROOT .. "/client_io/world_guid.txt", "r")
    if f then w = sanitize((f:read("l") or "")); f:close(); if w then return w, "file" end end
    return "shockbyte", "fallback"
end

function M.paths(world)
    return {
        events = ROOT .. "/logs/state/worlds/" .. world .. "/traversal_events.jsonl",
        links = ROOT .. "/data/skills/" .. world .. "/traversal_links.json",
        events_dir = ROOT .. "/logs/state/worlds/" .. world,
        links_dir = ROOT .. "/data/skills/" .. world,
    }
end

local function read_file(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("a"); f:close(); return s
end

-- Load (or switch to) a world's link store. Idempotent per world.
function M.load_store(world)
    local s = S()
    if s.store and s.world == world then return s.store end
    local P = M.paths(world)
    local store
    local txt = read_file(P.links)
    if txt and txt ~= "" then
        local ok, t = pcall(function() return J().decode(txt) end)
        if ok and type(t) == "table" and type(t.links) == "table" then store = t end
    end
    store = store or { v = 1, world = world, next_id = 1, links = {} }
    store.next_id = store.next_id or (#store.links + 1)
    s.world, s.store, s.paths, s.dirty = world, store, P, false
    return store
end

local function store() return S().store or M.load_store((M.world_id())) end

function M.save(force)
    local s = S()
    if not s.store or (not s.dirty and not force) then return false end
    local P = s.paths
    if not s.links_dir_ok then mkdir(P.links_dir); s.links_dir_ok = true end
    s.store.updated = iso()
    s.store.build = M.cfg.build
    table.sort(s.store.links, function(a, b) return (tonumber(a.id:sub(2)) or 0) < (tonumber(b.id:sub(2)) or 0) end)
    local txt = J().encode(s.store, { indent = true, keyorder = { "v", "world", "build", "updated", "next_id", "links",
        "id", "status", "move", "shape", "from", "to", "heading_deg", "dz_m", "horiz_m", "gap_m", "gap_depth_m",
        "runup_m", "speed_ms", "air_s", "rise_m", "needs", "inputs", "moves", "source", "sources", "n_seen",
        "n_try", "n_ok", "n_fail_run", "last_fail", "first_seen", "last_seen", "last_ok", "disabled", "reason" } })
    local tmp = P.links .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(txt, "\n"); f:close()
    os.remove(P.links)
    local ok = os.rename(tmp, P.links)
    s.dirty, s.save_t = false, os.time()
    s.counts.saves = s.counts.saves + 1
    return ok and true or false
end

local function append_event(ev)
    local s = S()
    if not s.events_dir_ok then mkdir(s.paths.events_dir); s.events_dir_ok = true end
    local ok, line = pcall(function() return J().encode(ev) end)
    if not ok then return end
    local f = io.open(s.paths.events, "a")
    if f then f:write(line, "\n"); f:close() end
end

-- ------------------------------------------------------------------ link logic (pure; offline-tested)
function M.usable(link, env)
    env = env or {}
    if link.disabled then return false, "disabled" end
    local mv = link.move
    if mv == "double_jump" and not env.double_jump then return false, "needs:DoubleJump" end
    if mv == "air_dash" and not env.air_dash then return false, "needs:AirDash" end
    if mv == "windstep" and not env.windstep then return false, "needs:Windstep" end
    return true
end

local function status_of(l)
    if l.disabled then return "disabled" end
    return (l.n_ok or 0) > 0 and "verified" or "demonstrated"
end

local function new_link(ev, st)
    local id = "L" .. st.next_id
    st.next_id = st.next_id + 1
    local selfsrc = ev.source == "self"
    local l = {
        id = id, move = ev.move, shape = ev.shape, from = ev.from, to = ev.to, heading_deg = ev.heading_deg,
        dz_m = ev.dz_m, horiz_m = ev.horiz_m, gap_m = ev.gap_m, gap_depth_m = ev.gap_depth_m,
        runup_m = ev.runup_m, speed_ms = ev.speed_ms, air_s = ev.air_s, rise_m = ev.rise_m,
        needs = M.NEEDS[ev.move] or {}, inputs = ev.inputs, moves = { [ev.move] = 1 },
        source = selfsrc and "self" or ("demo:" .. tostring(ev.who)), sources = { [tostring(ev.who)] = 1 },
        n_seen = selfsrc and 0 or 1, n_try = selfsrc and 1 or 0, n_ok = selfsrc and 1 or 0, n_fail_run = 0,
        first_seen = ev.iso, last_seen = ev.iso, last_ok = selfsrc and ev.iso or nil,
        disabled = false, build = M.cfg.build,
    }
    l.status = status_of(l)
    st.links[#st.links + 1] = l
    return l
end

-- Weighted running mean of endpoints (sky-survey style duplicate merge: weight = members).
local function blend(a, b, n)
    local out = {}
    for i = 1, 3 do out[i] = r2((a[i] * n + b[i]) / (n + 1)) end
    return out
end

-- The link a (kept) event belongs to, or nil. Same direction only (links are one-way).
function M.match(ev, links, rf, rt)
    rf, rt = rf or M.cfg.from_merge_m, rt or M.cfg.to_merge_m
    local best, bd
    local ef, et = cm(ev.from), cm(ev.to)
    for _, l in ipairs(links) do
        local df, dt = d3(ef, cm(l.from)) / 100, d3(et, cm(l.to)) / 100
        local hd = (ev.horiz_m or 0) >= 1 and (l.horiz_m or 0) >= 1 and ang(ev.heading_deg, l.heading_deg) or 0
        if df <= rf and dt <= rt and hd <= M.cfg.heading_merge_deg then
            local sc = df + dt
            if not bd or sc < bd then best, bd = l, sc end
        end
    end
    return best
end

-- Fold one classified event into the store. Returns (link, action) with action
-- "new" | "merged" | "verified" | nil (not kept).
function M.ingest(ev, st)
    st = st or store()
    if not ev.keep then return nil end
    local selfsrc = ev.source == "self"
    local l = M.match(ev, st.links, selfsrc and M.cfg.match_from_m, selfsrc and M.cfg.match_to_m)
    if not l then
        -- Claude's own small step-ups (local-planner jump edges) are routine, not links
        if selfsrc and ev.shape == "up" and (ev.dz_m or 0) < M.cfg.self_min_up_m then return nil, "self_small" end
        return new_link(ev, st), "new"
    end
    l.moves = l.moves or {}
    l.moves[ev.move] = (l.moves[ev.move] or 0) + 1
    if (M.RANK[ev.move] or 9) < (M.RANK[l.move] or 9) then -- an easier move crossed it: that is what it needs
        l.move, l.needs, l.inputs = ev.move, M.NEEDS[ev.move] or {}, ev.inputs
    end
    l.last_seen = ev.iso
    if selfsrc then
        l.n_try, l.n_ok, l.n_fail_run, l.last_ok = (l.n_try or 0) + 1, (l.n_ok or 0) + 1, 0, ev.iso
        if l.disabled and l.reason ~= "forgotten" then l.disabled, l.reason = false, nil end
        l.status = status_of(l)
        return l, "verified"
    end
    local n = l.n_seen or 0
    if n > 0 then -- demos refine the geometry; self crossings never move a link
        l.from, l.to = blend(l.from, ev.from, n), blend(l.to, ev.to, n)
        l.runup_m = r2(math.max(l.runup_m or 0, ev.runup_m or 0))
        l.speed_ms = r2(((l.speed_ms or 0) * n + (ev.speed_ms or 0)) / (n + 1))
    end
    l.n_seen = n + 1
    l.sources = l.sources or {}
    l.sources[tostring(ev.who)] = (l.sources[tostring(ev.who)] or 0) + 1
    l.status = status_of(l)
    return l, "merged"
end

function M.record_attempt(log, id, ok, reason)
    local st = store()
    for _, l in ipairs(st.links) do
        if l.id == id then
            l.n_try = (l.n_try or 0) + 1
            if ok then
                l.n_ok, l.n_fail_run, l.last_ok = (l.n_ok or 0) + 1, 0, iso()
            else
                l.n_fail_run = (l.n_fail_run or 0) + 1
                l.last_fail = reason or "failed"
                if l.n_fail_run >= M.cfg.fail_disable then l.disabled, l.reason = true, "failed_" .. l.n_fail_run .. "x" end
            end
            l.status = status_of(l)
            S().dirty = true
            M.save(true)
            if log then pcall(log, string.format("learn: attempt %s ok=%s -> %s", id, tostring(ok), l.status)) end
            return { ok = true, link = l }
        end
    end
    return { ok = false, reason = "unknown_link" }
end

function M.forget(log, id)
    for _, l in ipairs(store().links) do
        if l.id == id then
            l.disabled, l.reason, l.status = true, "forgotten", "disabled"
            S().dirty = true; M.save(true)
            return { ok = true, link = l }
        end
    end
    return { ok = false, reason = "unknown_link" }
end

local function copy_link(l, extra)
    local c = {}
    for k, x in pairs(l) do c[k] = x end
    for k, x in pairs(extra or {}) do c[k] = x end
    return c
end

function M.links_near(pos, radius_m, opts)
    opts = opts or {}
    local p = cm(pos)
    if not p then return {} end
    local out = {}
    for _, l in ipairs(store().links) do
        local d = d3(p, cm(l.from)) / 100
        if d <= (radius_m or 20) then
            local okU, why = M.usable(l, opts.env)
            if okU or not opts.usable_only then out[#out + 1] = copy_link(l, { d_m = r2(d), usable = okU, why = why }) end
        end
    end
    table.sort(out, function(a, b) return a.d_m < b.d_m end)
    return out
end

-- Cheapest detour through ONE link from `from` to `to`: walk(from -> link.from) + penalty(move)
-- (Baritone-style jump penalty) scaled by the failure record + walk(link.to -> to). The link must
-- make progress (link.to nearer `to` than `from` is). opts: env, radius_m (search), max_detour (x straight).
M.PENALTY_M = { drop = 2, jump = 5, sprint_jump = 8, double_jump = 10, air_dash = 12, windstep = 15 }
function M.best_link(from, to, opts)
    opts = opts or {}
    local a, b = cm(from), cm(to)
    if not (a and b) then return nil, "bad_args" end
    local straight = d3(a, b) / 100
    local radius = opts.radius_m or math.max(30, straight * 1.2)
    local best, bc, blocked
    for _, l in ipairs(store().links) do
        local lf, lt = cm(l.from), cm(l.to)
        local walk1, walk2 = d3(a, lf) / 100, d3(lt, b) / 100
        if walk1 <= radius and walk2 < straight then
            local okU, why = M.usable(l, opts.env)
            if okU then
                local fails = (l.n_try or 0) - (l.n_ok or 0)
                local unverified = (l.n_ok or 0) == 0 and 1.5 or 1.0
                local cost = walk1 + walk2 + (M.PENALTY_M[l.move] or 10) * unverified * (1 + math.max(0, fails))
                if not bc or cost < bc then best, bc = l, cost end
            else
                blocked = blocked or why
            end
        end
    end
    if not best then return nil, blocked or "no_link" end
    if opts.max_detour and bc > straight * opts.max_detour + 10 then return nil, "detour_too_long" end
    return copy_link(best, { cost_m = r2(bc), usable = true }), { straight_m = r2(straight), cost_m = r2(bc) }
end

-- ------------------------------------------------------------------ event classification (pure)
-- ev fields (cm inside): t0, t1, take (pos), land (pos), apex_z, v0 (vel at take-off), jc_max,
-- jc_times {dt...}, impulses {dt...}, dashes {dt...}, evades {dt...}, casts {{dt, name}}, fall_damage,
-- runup_cm, water, aborted, gap (probe result {gap=bool, depth_cm, width_cm}).
function M.classify(e)
    local c = M.cfg
    local dz = (e.land.Z - e.take.Z) / 100
    local horiz = d2(e.take, e.land) / 100
    local rise = (e.apex_z - e.take.Z) / 100
    local air = e.t1 - e.t0
    local v0h = e.v0 and math.sqrt(e.v0.X ^ 2 + e.v0.Y ^ 2) or 0
    local jumped = (e.jc_max or 0) >= 1 or (e.v0 and e.v0.Z > 200) or rise > 0.3
    local double = (e.jc_max or 0) >= 2 or #(e.impulses or {}) > 0
    local cast_ws, cast_any = false, false
    for _, k in ipairs(e.casts or {}) do
        cast_any = true
        if tostring(k.name or ""):lower():find("windstep") then cast_ws = true end
    end
    local move
    if cast_ws or (cast_any and rise > c.windstep_rise_m) or rise > c.windstep_rise_dj_m
        or (not double and rise > c.windstep_rise_m) then move = "windstep"
    elseif #(e.evades or {}) > 0 or #(e.dashes or {}) > 0 then move = "air_dash"
    elseif double then move = "double_jump"
    elseif jumped and v0h > c.sprint_cms then move = "sprint_jump"
    elseif jumped then move = "jump"
    else move = "drop" end
    local shape
    if dz >= c.up_m then shape = "up"
    elseif dz <= -c.down_m then shape = "down"
    elseif e.gap and e.gap.gap then shape = "gap"
    else shape = "flat" end
    local why
    if e.aborted then why = "aborted:" .. tostring(e.aborted)
    elseif air < c.min_air_s then why = "blip"
    elseif horiz > c.max_horiz_m then why = "too_long"
    elseif e.water then why = "water"
    elseif shape == "flat" then why = "hop"
    elseif e.gap and e.gap.walkable then why = "walkable_terrain" end
    local inputs = {}
    for _, k in ipairs(e.casts or {}) do inputs[#inputs + 1] = { t = r2(-k.dt), a = "cast:" .. tostring(k.name or "spell") } end
    if jumped then inputs[#inputs + 1] = { t = 0, a = "jump" } end
    if double then
        local t2 = (e.jc_times or {})[2] or (e.impulses or {})[1]
        inputs[#inputs + 1] = { t = r2(t2 or 0.35), a = "jump" }
    end
    for _, t in ipairs(e.evades or {}) do inputs[#inputs + 1] = { t = r2(t), a = "evade" } end
    -- the dash itself (CMOVE_Dash or a speed spike); which input triggers it is UNVERIFIED (evade key?)
    if #(e.evades or {}) == 0 then for _, t in ipairs(e.dashes or {}) do inputs[#inputs + 1] = { t = r2(t), a = "dash" } end end
    local hd = horiz >= 0.5 and heading(e.take, e.land) or (e.v0 and heading({ X = 0, Y = 0 }, e.v0)) or 0
    return {
        move = move, shape = shape, keep = why == nil, why = why,
        from = m3(e.take), to = m3(e.land), heading_deg = r2(hd), dz_m = r2(dz), horiz_m = r2(horiz),
        rise_m = r2(rise), air_s = r2(air), speed_ms = r2(v0h / 100), runup_m = r2((e.runup_cm or 0) / 100),
        gap_m = e.gap and e.gap.gap and r2((e.gap.width_cm or 0) / 100) or nil,
        gap_depth_m = e.gap and e.gap.gap and r2((e.gap.depth_cm or 0) / 100) or nil,
        jc_max = e.jc_max, fall_damage = e.fall_damage, sprint = v0h > c.sprint_cms, inputs = inputs,
        land_mode = e.land_mode, land_vz = e.land_vz,
    }
end

-- ------------------------------------------------------------------ engine reads
local GS, KSL
local C0 = { R = 0, G = 0, B = 0, A = 0 }
local function now(ctx)
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return GS:GetRealTimeSeconds(ctx)
end

local function local_pc()
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(x) and not x:GetFullName():find("Default__") then
            local ok, isl = pcall(function() return x:IsLocalController() end)
            if not ok or isl then return x end
        end
    end
end

-- Down trace; returns floor Z (cm) or nil, plus started_inside.
local function floor_z(ctx, x, y, z0, z1)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    S().counts.traces = S().counts.traces + 1
    local hit = KSL:LineTraceSingle(ctx, { X = x, Y = y, Z = z0 }, { X = x, Y = y, Z = z1 }, 0, false, {}, 0, out, true, C0, C0, 0.0)
    if hit ~= true then return nil, false end
    local ip = out.ImpactPoint
    return ip and tonumber(ip.Z), (tonumber(out.Distance) or 1) < 0.5
end

-- Probe the floor under the flight line every gap_probe_step_m: gap when the floor is missing, or
-- more than gap_depth_m below the lower end. Feet = capsule centre - half height.
function M.probe_gap(ctx, take, land, half_h, trace)
    trace = trace or floor_z
    local c = M.cfg
    local horiz = d2(take, land)
    local n = math.min(c.gap_probe_max, math.max(1, math.floor(horiz / (c.gap_probe_step_m * 100)) - 1))
    local fa, fb = take.Z - half_h, land.Z - half_h
    local low = math.min(fa, fb)
    local z0, z1 = math.max(fa, fb) + 50, low - 500
    local gaps, deepest, valid_n = 0, 0, 0
    -- floor profile take-off -> probes -> landing, for the walkable-terrain test (like localplan's
    -- slope vs step check): every segment must rise/fall at most a step + 0.3 x its length
    local prof = { { d = 0, z = fa } }
    local complete = true
    for i = 1, n do
        local f = i / (n + 1)
        local x, y = take.X + (land.X - take.X) * f, take.Y + (land.Y - take.Y) * f
        -- the jumper stands at the landing point while we probe, and traces hit attached gear
        -- (bIgnoreSelf skips only the context pawn): no probe within 0.7 m of the landing
        local z, inside
        if horiz * (1 - f) >= c.probe_clear_cm then z, inside = trace(ctx, x, y, z0, z1) else inside = "skip" end
        if not inside then
            valid_n = valid_n + 1
            local depth = z and (low - z) or 500
            if depth > c.gap_depth_m * 100 then gaps = gaps + 1; deepest = math.max(deepest, depth) end
            if z then prof[#prof + 1] = { d = horiz * f, z = z } else complete = false end
        elseif inside ~= "skip" then
            complete = false
        end
    end
    prof[#prof + 1] = { d = horiz, z = fb }
    local walkable = complete and gaps == 0 and #prof >= 3
    local worst = 0
    for i = 2, #prof do
        local seg = prof[i].d - prof[i - 1].d
        local dz = math.abs(prof[i].z - prof[i - 1].z)
        worst = math.max(worst, dz)
        if dz > c.walk_step_cm + c.walk_slope * seg then walkable = false end
    end
    local width = gaps > 0 and math.min(horiz, (gaps + 1) * horiz / (n + 1)) or 0
    return { gap = gaps > 0, probes = n, valid = valid_n, gaps = gaps, depth_cm = deepest, width_cm = width,
             walkable = walkable, worst_step_cm = math.floor(worst) }
end

-- ------------------------------------------------------------------ hooks (multicasts reach every client)
-- Handlers only stamp {owner full name -> time}; nothing is written to the game.
M.HOOKS = {
    { path = "/Script/Dominion.PlayerEvadeComponent:Multicast_StartEvade", kind = "evade" },
    { path = "/Script/Dominion.PlayerMagicComponent:Multicast_SendPayloadForSpellCasting", kind = "cast" },
    { path = "/Script/Dominion.DominionMovementComponent:Multicast_ApplyFallDamage", kind = "fall" },
}

local function on_hook(kind, ctx, a1)
    local s = S()
    if paused() then return end
    local comp = ctx:get()
    local owner = try(function() return comp:GetOwner() end)
    local key = owner and try(function() return owner:GetFullName() end)
    if not key then return end
    s.counts.hook_hits = s.counts.hook_hits + 1
    local t = s.last_now or 0
    local m = { kind = kind, t = t }
    if kind == "cast" then
        m.net_id = try(function() return a1:get().NetId end)
        m.name = try(function()
            local d = comp.CurrentSpellActor.Data
            return d and d:GetFullName():match("([%w_]+)$")
        end)
    elseif kind == "fall" then
        m.amount = tonumber(try(function() return a1:get() end))
    end
    local list = s.marks[key] or {}
    s.marks[key] = list
    list[#list + 1] = m
    if #list > 20 then table.remove(list, 1) end
end

local function register_hooks(log)
    local s = S()
    local res = {}
    for _, h in ipairs(M.HOOKS) do
        if s.hooks[h.path] then res[h.kind] = true
        else
            -- BUGS L24: the shared hook hub (one native hook per path, never unregistered, skipped under DW_PAUSE)
            local hubm = (function()
                local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or ((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver") .. "/client_mod/scripts")
                return assert(loadfile(dir .. "/hookhub.lua"))()
            end)()
            local ok = hubm.on(h.path, "learn:" .. h.kind, function(ctx, a1)
                local f = rawget(_G, "DW_LEARN") and _G.DW_LEARN.on_hook
                if f then f(h.kind, ctx, a1) end
            end, { log = log })
            if ok then s.hooks[h.path] = true end
            res[h.kind] = ok
        end
    end
    return res
end

-- ------------------------------------------------------------------ per-pawn tracking
local function read_pawn(tr)
    local p = tr.pawn
    local loc = p:K2_GetActorLocation()
    local pos = { X = loc.X, Y = loc.Y, Z = loc.Z }
    local mc = tr.mc
    local mode = tonumber(try(function() return mc.MovementMode end))
    if mode == nil then mode = try(function() return mc:IsFalling() end) and MODE_FALLING or 1 end
    local v = try(function() return mc.Velocity end)
    local vel = v and { X = tonumber(v.X) or 0, Y = tonumber(v.Y) or 0, Z = tonumber(v.Z) or 0 } or { X = 0, Y = 0, Z = 0 }
    local jc = tonumber(try(function() return p.ReplicatedJumpCurrentCount end)) or 0
    if tr.self then jc = math.max(jc, tonumber(try(function() return p.JumpCurrentCount end)) or 0) end
    return pos, mode, vel, jc
end

local function marks_between(s, key, t_from, t_to, kind)
    local out = {}
    for _, m in ipairs(s.marks[key] or {}) do
        if m.kind == kind and m.t >= t_from and m.t <= t_to then out[#out + 1] = m end
    end
    return out
end

local function runup_cm(ring, take, hd)
    local acc, prev = 0, take
    for i = #ring, 1, -1 do
        local g = ring[i]
        local seg = d2(prev, g)
        if seg > 1 then
            if ang(heading(g, prev), hd) > M.cfg.runup_heading_deg then break end
            acc = acc + seg
            if acc >= M.cfg.runup_max_m * 100 then break end
        end
        prev = g
    end
    return acc
end

local function close_event(tr, t, land, why_abort, ctx, log)
    local s = S()
    local e = tr.ev
    tr.ev = nil
    if not e then return end
    e.t1, e.land = t, land or e.last
    e.aborted = why_abort
    local key = tr.key
    -- a cast counts only since this pawn's previous landing (Windstep's GE is removed on landing)
    local since = math.max(e.t0 - M.cfg.cast_window_s, tr.last_land_t or -math.huge)
    if not why_abort then tr.last_land_t = t end
    for _, m in ipairs(marks_between(s, key, since, e.t1, "cast")) do
        e.casts = e.casts or {}
        e.casts[#e.casts + 1] = { dt = e.t0 - m.t, name = m.name, net_id = m.net_id }
    end
    for _, m in ipairs(marks_between(s, key, e.t0, e.t1, "evade")) do
        e.evades = e.evades or {}
        e.evades[#e.evades + 1] = m.t - e.t0
    end
    for _, m in ipairs(marks_between(s, key, e.t1 - 0.5, e.t1 + 0.5, "fall")) do e.fall_damage = m.amount or true end
    local hd = d2(e.take, e.land) >= 50 and heading(e.take, e.land) or (e.v0 and heading({ X = 0, Y = 0 }, e.v0)) or 0
    e.runup_cm = runup_cm(tr.ring_before or {}, e.take, hd)
    -- gap probe only for flat-ish flights long enough to span one (reads; skipped when aborted)
    local dz = (e.land.Z - e.take.Z) / 100
    -- probe every flight long enough: gaps under flat flights, and the walkable-terrain test (a dash-hop
    -- over rolling ground, live 19:43, is not a link: the floor under it is continuous)
    if not why_abort and ctx and d2(e.take, e.land) / 100 >= M.cfg.gap_min_m then
        -- client collision streams around CLAUDE: far from him "no floor" may just be unloaded
        local me = try(function() return ctx:K2_GetActorLocation() end)
        local mid = { X = (e.take.X + e.land.X) / 2, Y = (e.take.Y + e.land.Y) / 2 }
        if me and d2(me, mid) <= M.cfg.probe_max_m * 100 then
            local ok, g = pcall(M.probe_gap, ctx, e.take, e.land, tr.half_h or 88, M._trace)
            e.gap = ok and g or { gap = false, err = tostring(g) }
        else
            e.gap = { gap = false, unprobed = "far_from_claude" }
        end
    end
    -- links are stored at FEET level (floor points), like nav waypoints; the actor location is the
    -- capsule centre (move.lua's landing check compares feet with link.to.Z)
    local hh = tr.half_h or 88
    e.take = { X = e.take.X, Y = e.take.Y, Z = e.take.Z - hh }
    e.land = { X = e.land.X, Y = e.land.Y, Z = e.land.Z - hh }
    e.apex_z = e.apex_z - hh
    local c = M.classify(e)
    s.counts.events = s.counts.events + 1
    if why_abort then s.counts.aborted = s.counts.aborted + 1 end
    local ev = c
    ev.type, ev.who, ev.source, ev.leader = "traversal", tr.name, tr.self and "self" or "demo", tr.leader or nil
    ev.ts, ev.iso = os.time(), iso()
    ev.casts, ev.evades, ev.impulses, ev.dashes, ev.jc_times = e.casts, e.evades, e.impulses, e.dashes, e.jc_times
    ev.custom = e.custom
    ev.gap_probe = e.gap
    ev.samples = e.samples
    local link, action = nil, nil
    if ev.keep then
        s.counts.kept = s.counts.kept + 1
        link, action = M.ingest(ev, s.store)
        if link then
            s.dirty = true
            ev.link, ev.action = link.id, action
            if action == "new" then s.counts.links_new = s.counts.links_new + 1
            elseif action == "merged" then s.counts.merged = s.counts.merged + 1
            else s.counts.verified = s.counts.verified + 1 end
        end
    end
    append_event(ev)
    s.last_event = { who = ev.who, move = ev.move, shape = ev.shape, keep = ev.keep, why = ev.why, link = ev.link,
                     action = action, dz_m = ev.dz_m, horiz_m = ev.horiz_m, iso = ev.iso }
    if log then
        pcall(log, string.format("learn: %s %s/%s dz=%.2f h=%.2f rise=%.2f air=%.2fs %s%s", tostring(ev.who), ev.move,
            ev.shape, ev.dz_m or 0, ev.horiz_m or 0, ev.rise_m or 0, ev.air_s or 0,
            ev.keep and "KEEP" or ("skip:" .. tostring(ev.why)), link and (" -> " .. link.id .. " " .. action) or ""))
    end
end

local function step_tracker(tr, t, ctx, log)
    local okr, pos, mode, vel, jc = pcall(read_pawn, tr)
    if not okr then return "read_error" end
    local c = M.cfg
    if tr.last and d3(pos, tr.last) > c.teleport_cm then
        if tr.ev then close_event(tr, t, tr.last, "teleport", nil, log) end
        tr.ring, tr.last, tr.last_jc = {}, nil, jc
        return
    end
    local airborne = mode == MODE_FALLING or mode == MODE_CUSTOM or mode == MODE_FLYING
    local swimming = mode == MODE_SWIMMING
    local e = tr.ev
    if not e then
        -- ReplicatedJumpCurrentCount on a proxy is STALE after landing (live 19:40:48: it stayed 2
        -- through a walk-off one second after a double jump), so only a CHANGE from the grounded
        -- baseline counts as a jump signal, never the absolute value.
        local base = tr.ground_jc or 0
        if airborne or (jc ~= base and jc >= 1 and vel.Z > 100) then
            local take = tr.ring[#tr.ring] and tr.last_ground or pos
            tr.ring_before = tr.ring
            tr.ring = {}
            e = { t0 = t, take = take, v0 = tr.last_ground_vel or vel, apex_z = math.max(pos.Z, take.Z), jc_max = 0,
                  jc_base = base, jc_prev = base,
                  jc_times = {}, impulses = {}, dashes = {}, samples = {}, last = pos, prev_vz = vel.Z,
                  hs = { { t = t, h = math.sqrt(vel.X ^ 2 + vel.Y ^ 2) } } }
            if e.v0.Z < vel.Z then e.v0 = { X = e.v0.X, Y = e.v0.Y, Z = vel.Z } end
            tr.ev = e
        else
            -- grounded: ring of take-off candidates
            local r = tr.ring
            if not r[#r] or d2(r[#r], pos) >= c.ground_spacing_cm then
                r[#r + 1] = pos
                if #r > c.ground_ring then table.remove(r, 1) end
            end
            tr.last_ground, tr.last_ground_vel, tr.ground_jc = pos, vel, jc
        end
    end
    if e then
        local dt = t - e.t0
        e.apex_z = math.max(e.apex_z, pos.Z)
        if jc ~= e.jc_prev and jc >= 1 then -- a jump (1) or second jump (2) happened now
            e.jc_max = math.max(e.jc_max, jc)
            e.jc_times[jc] = e.jc_times[jc] or dt
        end
        e.jc_prev = jc
        if airborne then
            -- a second upward impulse mid-air (double jump / Windstep boost) when the count lags.
            -- Airborne frames only: the landing frame zeroes a falling velocity (not an impulse).
            if dt > 0.1 and vel.Z - (e.prev_vz or vel.Z) > c.impulse_vz and #e.impulses < 3 then e.impulses[#e.impulses + 1] = dt end
            e.prev_vz = vel.Z
            local h = math.sqrt(vel.X ^ 2 + vel.Y ^ 2)
            local hs = e.hs
            hs[#hs + 1] = { t = t, h = h }
            while #hs > 2 and t - hs[1].t > c.dash_window_s do table.remove(hs, 1) end
            if dt > 0.1 and h - hs[1].h > c.dash_cms and #e.dashes < 2 then e.dashes[#e.dashes + 1] = dt; e.hs = { { t = t, h = h } } end
            if mode == MODE_CUSTOM and e.prev_mode ~= MODE_CUSTOM then -- entered CMOVE_Dash
                e.custom = e.custom or {}
                e.custom[#e.custom + 1] = { t = r2(dt), cmode = tonumber(try(function() return tr.mc.CustomMovementMode end)) }
                if #e.dashes < 2 then e.dashes[#e.dashes + 1] = dt end
            end
            e.prev_mode = mode
        end
        if #e.samples < c.samples_max and (not e.sample_t or t - e.sample_t >= c.sample_every_s) then
            e.sample_t = t
            e.samples[#e.samples + 1] = { r2(dt), r2(pos.X / 100), r2(pos.Y / 100), r2(pos.Z / 100), mode, jc, math.floor(vel.Z) }
        end
        e.last = pos
        if airborne then e.seen_air = true end
        if not airborne and not e.seen_air and not swimming then
            -- opened on a jump-count rise; the movement mode may lag a frame or two
            if dt > 0.3 then tr.ev = nil; tr.ring = tr.ring_before or {} end
        elseif not airborne then
            if dt < c.min_air_s and not swimming then
                tr.ev = nil -- blip: back to ground, keep the old ring
                tr.ring = tr.ring_before or {}
            else
                e.water = swimming or nil
                e.land_mode, e.land_vz = mode, math.floor(vel.Z)
                close_event(tr, t, pos, nil, ctx, log)
                tr.ring = { pos }
                tr.last_ground, tr.last_ground_vel, tr.ground_jc = pos, vel, jc
            end
        elseif dt > c.max_air_s then
            close_event(tr, t, pos, "too_long_airborne", nil, log)
        end
    end
    tr.last, tr.last_jc, tr.mode, tr.hspeed, tr.vz = pos, jc, mode, math.sqrt(vel.X ^ 2 + vel.Y ^ 2), vel.Z
    if mode == MODE_FALLING then tr.falling_frames = (tr.falling_frames or 0) + 1 end
    tr.modes = tr.modes or {}
    local mk = tostring(mode)
    tr.modes[mk] = (tr.modes[mk] or 0) + 1
    if jc > 0 then tr.jc_frames = (tr.jc_frames or 0) + 1 end
end

local function player_name(ps)
    return try(function() return ps:GetPlayerName():ToString() end)
end

local function full(o) return try(function() return o:GetFullName() end) end

-- UObject wrappers from different FindAllOf calls need not compare equal, so pawns are compared by
-- full name (stable while the pawn lives).
local function new_tracker(name, pawn, key, is_self)
    return { name = name, self = is_self or nil, pawn = pawn, key = key, ring = {},
             mc = try(function() return pawn.CharacterMovement end),
             half_h = tonumber(try(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)) or 88 }
end

local function discover(s, me_pawn, log)
    local seen = {}
    local n = 0
    local me_key = me_pawn and full(me_pawn)
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        if valid(ps) and not ps:GetFullName():find("Default__") then
            local name = player_name(ps)
            local pawn = try(function() return ps.PawnPrivate end)
            local key = valid(pawn) and full(pawn)
            if name and key and key ~= me_key and n < M.cfg.max_players then
                n = n + 1
                seen[name] = true
                local tr = s.trackers[name]
                if not tr or tr.key ~= key then
                    if tr and tr.ev then close_event(tr, s.last_now or 0, nil, "pawn_changed", nil, log) end
                    s.trackers[name] = new_tracker(name, pawn, key)
                    if log then pcall(log, "learn: tracking " .. name) end
                end
            end
        end
    end
    -- self (Claude's own crossings verify links)
    if M.cfg.track_self ~= false and me_key then
        local tr = s.trackers["@self"]
        if not tr or tr.key ~= me_key then s.trackers["@self"] = new_tracker("Claude", me_pawn, me_key, true) end
        seen["@self"] = true
    end
    for name, tr in pairs(s.trackers) do
        if not seen[name] then
            if tr.ev then close_event(tr, s.last_now or 0, nil, "lost_relevancy", nil, log) end
            s.trackers[name] = nil
        end
    end
end

local function tick(log)
    local s = S()
    if paused() then s.status = "paused"; s.trackers = {}; return end
    local pc = s.pc
    if not valid(pc) then pc = local_pc(); s.pc = pc end
    if not valid(pc) then s.status = "no_controller"; s.trackers = {}; return end
    local me = try(function() return pc.Pawn end)
    if not valid(me) then s.status = "no_pawn"; s.trackers = {}; return end
    local t = now(me)
    s.last_now = t
    s.counts.ticks = s.counts.ticks + 1
    s.status = "recording"
    -- hooks registered at the main menu (or while paused) can fail: retry in the world every 10 s
    local nh = 0
    for _ in pairs(s.hooks) do nh = nh + 1 end
    if nh < #M.HOOKS and (not s.hook_try_t or t - s.hook_try_t >= 10) then
        s.hook_try_t = t
        register_hooks(log)
    end
    if not s.disc_t or t - s.disc_t >= M.cfg.discover_s then
        s.disc_t = t
        discover(s, me, log)
        local mv = rawget(_G, "DW_MOVE")
        local leader = mv and mv.mode == "follow" and mv.target_name
        for _, tr in pairs(s.trackers) do tr.leader = (leader and tr.name == leader) or nil end
    end
    for _, tr in pairs(s.trackers) do
        if valid(tr.pawn) then
            local r = step_tracker(tr, t, me, log)
            if r == "read_error" then tr.errors = (tr.errors or 0) + 1 end
        end
    end
    if s.dirty and (not s.save_t or os.time() - s.save_t >= M.cfg.save_every_s) then M.save() end
end
M._tick = tick

-- ------------------------------------------------------------------ lifecycle
function M.start(log, opts)
    opts = opts or {}
    local s = S()
    local world, src = M.world_id(opts.world)
    if s.world ~= world or s.stopped then -- after stop() re-read the file (hand edits / forget via git)
        if s.dirty then M.save(true) end
        s.store, s.events_dir_ok, s.links_dir_ok = nil, nil, nil
    end
    M.load_store(world)
    s.world_src = world and src
    s.log = log
    s.on_hook = on_hook               -- newest handler code (hot reload)
    s.tick = function() return tick(s.log) end
    local hooks = (not paused()) and register_hooks(log) or {}
    if not s.loop then
        s.gen = s.gen + 1
        local gen = s.gen
        s.loop = LoopInGameThreadWithDelay(1, function()
            local st = rawget(_G, "DW_LEARN")
            if not st or st.gen ~= gen or st.stopped then return true end
            if paused() then st.status = "paused"; st.trackers = {}; return end
            local f = st.tick
            if f then
                local ok, err = pcall(f)
                if not ok then st.errors = (st.errors or 0) + 1; st.last_error = tostring(err) end
            end
        end)
    end
    s.stopped, s.errors, s.last_error = nil, nil, nil
    s.started = s.started or iso()
    if log then pcall(log, "learn: recorder started world=" .. world .. " (" .. src .. ") links=" .. #s.store.links) end
    return { ok = true, world = world, world_source = src, links = #s.store.links, hooks = hooks, paths = s.paths }
end

function M.stop(log)
    local s = S()
    s.stopped = true
    if s.loop and CancelDelayedAction then pcall(CancelDelayedAction, s.loop) end
    s.loop = nil
    for _, tr in pairs(s.trackers) do tr.ev = nil end
    s.trackers = {}
    M.save(true)
    if log then pcall(log, "learn: recorder stopped") end
    return { ok = true }
end

function M.status()
    local s = S()
    local st = s.store
    local by = { demonstrated = 0, verified = 0, disabled = 0 }
    local list = {}
    for _, l in ipairs(st and st.links or {}) do
        by[l.status or "demonstrated"] = (by[l.status or "demonstrated"] or 0) + 1
        list[#list + 1] = { id = l.id, status = l.status, move = l.move, shape = l.shape, from = l.from, to = l.to,
                            dz_m = l.dz_m, horiz_m = l.horiz_m, n_seen = l.n_seen, n_ok = l.n_ok }
    end
    local trackers = {}
    for name, tr in pairs(s.trackers) do
        trackers[#trackers + 1] = { name = tr.name, self = tr.self, leader = tr.leader, airborne = tr.ev ~= nil, errors = tr.errors,
            mode = tr.mode, jc = tr.last_jc, speed_ms = r2((tr.hspeed or 0) / 100), vz = tr.vz and math.floor(tr.vz),
            pos = tr.last and m3(tr.last), falling_frames = tr.falling_frames, jc_frames = tr.jc_frames, modes = tr.modes }
    end
    local hooks = 0
    for _ in pairs(s.hooks) do hooks = hooks + 1 end
    return { running = s.loop ~= nil and not s.stopped, status = s.status, world = s.world, world_source = s.world_src,
             started = s.started, counts = s.counts, links = by, link_list = list, trackers = trackers, hooks = hooks,
             last_event = s.last_event, errors = s.errors, last_error = s.last_error, paths = s.paths }
end

-- Rebuild a world's link store from its raw events (thresholds changed). Keeps 'forgotten' flags.
function M.rebuild(log, world)
    world = world or S().world or (M.world_id())
    local P = M.paths(world)
    local f = io.open(P.events, "r")
    if not f then return { ok = false, reason = "no_events" } end
    local old = M.load_store(world)
    local forgotten = {}
    for _, l in ipairs(old.links) do if l.reason == "forgotten" then forgotten[#forgotten + 1] = l end end
    local st = { v = 1, world = world, next_id = 1, links = {} }
    local n, kept = 0, 0
    for line in f:lines() do
        local ok, ev = pcall(function() return J().decode(line) end)
        if ok and type(ev) == "table" and ev.type == "traversal" then
            n = n + 1
            if ev.keep then kept = kept + 1; M.ingest(ev, st) end
        end
    end
    f:close()
    for _, fl in ipairs(forgotten) do
        local l = M.match(fl, st.links)
        if l then l.disabled, l.reason, l.status = true, "forgotten", "disabled" end
    end
    S().store, S().dirty = st, true
    M.save(true)
    return { ok = true, events = n, kept = kept, links = #st.links }
end

M.HANDLERS = {
    learn_status = function() local r = M.status(); r.ok = true; return r end,
    learn_links = function(_, args)
        args = args or {}
        local pos = args.pos or args.position
        return { ok = true, links = pos and M.links_near(pos, args.radius_m or 30, { env = args.env }) or store().links }
    end,
}

return M
