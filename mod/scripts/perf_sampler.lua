-- Game-thread frame-time sampler (lag investigation). Read-only: it calls only simple getters
-- (no struct arguments) and never touches gameplay state.
--
--   debug_run {module="perf_sampler"}                         arm (once per server run; re-arming is a no-op)
--   debug_run {module="perf_sampler", args={action="status"}}  last window + clock benchmark
--   debug_run {module="perf_sampler", args={action="stop"}}    cancel the loop (arm again later)
-- main.lua auto-arms it 60 s after mod start unless DW_PERF=0.
--
-- Every frame (LoopInGameThreadAfterFrames(1), run from UE4SS's UEngine::Tick pre-hook): read a
-- clock, store the delta in a preallocated array, count >50/>100 ms frames. That is all.
-- Every WINDOW_S seconds: sort the deltas, count players/AI (one FindAllOf each), read each
-- player's ping, and append one JSON line to logs/perf/mod_perf.jsonl ($DW_PERF_FILE overrides).
--
-- Clock: UGameplayStatics::GetRealTimeSeconds(World) returns UWorld::RealTimeSeconds (double,
-- updated once per world tick), so consecutive reads give exactly one frame's real duration.
-- Falls back to os.clock (UCRT clock() is wall time since process start, 1 ms resolution).
local M = {}

local WINDOW_S = 10
local MAX_HITCHES = 8 -- frames >100 ms recorded individually per window (timestamp + ms)

local function try(f, ...) local ok, v = pcall(f, ...); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end

local function perf_path()
    local p = os.getenv("DW_PERF_FILE")
    if p and p ~= "" then return p end
    local dir = os.getenv("DW_MOD_LOG_DIR")
    if dir and dir ~= "" then return (dir:gsub("[/\\]+$", "")) .. "/../perf/mod_perf.jsonl" end
    return "mod_perf.jsonl"
end

local function find_world()
    for _, cls in ipairs({ "GameModeBase", "GameStateBase" }) do
        local o = try(FindFirstOf, cls)
        if valid(o) then
            local w = try(function() return o:GetWorld() end)
            if valid(w) then return w end
        end
    end
end

-- Benchmark clock candidates on the game thread (all calls happen inside this one frame).
local function pick_clock(S)
    local bench = {}
    local N = 200
    local t0 = os.clock()
    for _ = 1, N * 5 do local _ = os.clock() end
    bench.os_clock_us = (os.clock() - t0) * 1e6 / (N * 5)

    local gs = try(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    local ksl = try(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    local world = find_world()
    bench.world = world and try(function() return world:GetFullName() end) or nil
    if valid(ksl) then
        local fc = try(function() return ksl:GetFrameCount() end)
        if type(fc) == "number" then S.ksl = ksl; bench.frame_count = fc end
    end
    if valid(gs) and world then
        local v = try(function() return gs:GetRealTimeSeconds(world) end)
        bench.grts_value = v
        if type(v) == "number" and v > 0 then
            t0 = os.clock()
            local ok = pcall(function() for _ = 1, N do gs:GetRealTimeSeconds(world) end end)
            bench.grts_us = (os.clock() - t0) * 1e6 / N
            if ok and bench.grts_us < 200 then
                S.gs, S.world = gs, world
                S.clock_name = "grts"
                S.clock = function() return gs:GetRealTimeSeconds(world) end
                bench.chosen = "grts"
                return bench
            end
        end
    end
    S.clock_name = "os_clock"
    S.clock = os.clock
    bench.chosen = "os_clock"
    return bench
end

local function pct(sorted, n, p)
    if n == 0 then return nil end
    local i = math.floor(p * (n - 1) + 0.5) + 1
    return sorted[i]
end

local function r2(x) return x and math.floor(x * 100 + 0.5) / 100 or nil end

local function players_and_pings()
    local players, pings = 0, {}
    for _, pc in ipairs(try(FindAllOf, "PlayerController") or {}) do
        local ps = try(function() return pc.PlayerState end)
        if valid(ps) then
            players = players + 1
            local name = try(function() return ps:GetPlayerName():ToString() end)
            local ping = try(function() return ps:GetPingInMilliseconds() end)
            local cp = try(function() return ps.CompressedPing end)
            pings[#pings + 1] = { name = name, ping_ms = r2(ping), compressed_x4 = type(cp) == "number" and cp * 4 or nil }
        end
    end
    return players, pings
end

local function append(S, rec)
    local line = require("jsonutil").encode(rec)
    local f, err = io.open(S.path, "a")
    if not f then S.write_err = tostring(err); return end
    f:write(line, "\n")
    f:close()
end

local function flush(S, t)
    local c0 = os.clock()
    local n, buf = S.n, S.buf
    local sorted = {}
    local sum = 0
    for i = 1, n do local v = buf[i]; sorted[i] = v; sum = sum + v end
    table.sort(sorted)
    local span = t - S.win_start
    local engine_frames
    if S.ksl then
        local fc = try(function() return S.ksl:GetFrameCount() end)
        if type(fc) == "number" then
            if S.fc0 then engine_frames = fc - S.fc0 end
            S.fc0 = fc
        end
    end
    local players, pings = players_and_pings()
    local ai = #(try(FindAllOf, "DominionAICharacter") or {})
    local rec = {
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), t = os.time(), clock = S.clock_name,
        window_s = r2(span), frames = n, engine_frames = engine_frames, dupes = S.dupes,
        hz = span > 0 and r2(n / span) or nil,
        ms_mean = n > 0 and r2(sum / n) or nil,
        ms_p50 = r2(pct(sorted, n, 0.50)), ms_p95 = r2(pct(sorted, n, 0.95)),
        ms_p99 = r2(pct(sorted, n, 0.99)), ms_max = r2(sorted[n]),
        over_50 = S.o50, over_100 = S.o100, over_250 = S.o250, hitches = S.hitches,
        players = players, ai = ai, pings = pings,
        lua_kb = math.floor(collectgarbage("count")), errors = S.errors,
    }
    rec.flush_ms = r2((os.clock() - c0) * 1000)
    append(S, rec)
    S.last_rec = rec
    S.windows = S.windows + 1
    -- reset window
    S.n, S.o50, S.o100, S.o250, S.dupes, S.calls = 0, 0, 0, 0, 0, 0
    S.hitches = {}
    S.win_start = t
    -- The clock's world must still be alive (it only goes away on shutdown/travel).
    if S.clock_name == "grts" and not valid(S.world) then
        S.clock_name, S.clock, S.last = "os_clock", os.clock, nil
    end
end

local function on_frame(S)
    S.calls = S.calls + 1
    local t = S.clock()
    local last = S.last
    S.last = t
    if not last then S.win_start = t; return end
    local dt = (t - last) * 1000
    if dt <= 0 then
        S.dupes = S.dupes + 1 -- callback ran twice in one world tick
    else
        local n = S.n + 1
        S.n = n
        S.buf[n] = dt
        if dt > 50 then
            S.o50 = S.o50 + 1
            if dt > 100 then
                S.o100 = S.o100 + 1
                if dt > 250 then S.o250 = S.o250 + 1 end
                if #S.hitches < MAX_HITCHES then S.hitches[#S.hitches + 1] = { t = os.time(), ms = r2(dt) } end
            end
        end
    end
    -- calls cap: a clock that stopped advancing would otherwise never close the window
    if t - S.win_start >= WINDOW_S or S.calls >= WINDOW_S * 300 then
        if S.n == 0 and S.clock_name == "grts" then S.clock_name, S.clock, S.last = "os_clock", os.clock, nil end
        flush(S, t)
    end
end

local function status(S)
    return { running = S.running == true, clock = S.clock_name, bench = S.bench, path = S.path,
             windows = S.windows, errors = S.errors, last_err = S.last_err, write_err = S.write_err,
             last = S.last_rec, armed_at = S.armed_at }
end

function M.run(log, args)
    args = args or {}
    local S = _G.__dw_perf
    if args.action == "status" then return S and status(S) or { running = false } end
    if args.action == "stop" then
        if S and S.handle then pcall(CancelDelayedAction, S.handle) end
        if S then S.running, S.handle = false, nil end
        if log then log.event("perf_sampler_stopped", {}) end
        return { stopped = true }
    end
    if S and S.running then local st = status(S); st.already = true; return st end

    if type(LoopInGameThreadAfterFrames) ~= "function" then
        return { running = false, err = "LoopInGameThreadAfterFrames missing" }
    end
    local eta = EngineTickAvailable
    if type(eta) == "function" then eta = try(eta) end

    S = { n = 0, buf = {}, o50 = 0, o100 = 0, o250 = 0, dupes = 0, calls = 0, hitches = {},
          windows = 0, errors = 0, path = perf_path(), armed_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    S.bench = pick_clock(S)
    S.bench.engine_tick_available = eta
    _G.__dw_perf = S
    S.handle = LoopInGameThreadAfterFrames(1, function()
        local ok, err = pcall(on_frame, S)
        if not ok then
            S.errors = S.errors + 1
            S.last_err = tostring(err)
            if S.errors >= 50 and S.handle then pcall(CancelDelayedAction, S.handle); S.running = false end
        end
    end)
    S.running = S.handle ~= nil
    append(S, { ts = S.armed_at, t = os.time(), event = "armed", bench = S.bench })
    if log then log.event("perf_sampler_armed", { bench = S.bench, path = S.path, running = S.running }) end
    return status(S)
end

return M
