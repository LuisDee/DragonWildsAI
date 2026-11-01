-- Wall-clock epoch seconds with ms resolution for JSONL rows (telemetry item 5,
-- docs/research/2026-11-01-telemetry.md). Shared by the client mod and the server mod (mod/scripts is on
-- package.path for both: require("walltime")).
--
-- os.time() has 1 s resolution. os.clock() has ms resolution, and under the MSVC CRT (UE4SS) it is WALL time
-- since process start, not CPU time. So now() = os.clock() + C for a fixed offset C. A single anchor at load
-- (C = os.time() - os.clock()) can be up to 1 s off, so every call narrows C instead: os.time() = floor(clock + C)
-- means C is in [os.time() - clock, os.time() + 1 - clock). The bounds from all calls are intersected; now()
-- uses the midpoint. Rows are written at random sub-second phases, so the interval shrinks quickly (about
-- 1/(n+1) s after n calls). A system clock step (bounds disagree) re-anchors. The state lives in _G, so a hot
-- reload keeps what it learned. On a CRT where os.clock() is CPU time (Linux), it degrades to about 1 s.
local M = {}

local S = rawget(_G, "__dw_walltime")
if type(S) ~= "table" then S = {}; rawset(_G, "__dw_walltime", S) end

M.clock = os.clock -- tests replace these
M.time = os.time

-- epoch seconds, rounded to ms
function M.now()
    local c, t = M.clock(), M.time()
    local lo, hi = t - c, t + 1 - c
    if not S.lo or lo >= S.hi or hi <= S.lo then
        S.lo, S.hi = lo, hi -- first call, or the system clock stepped
    else
        if lo > S.lo then S.lo = lo end
        if hi < S.hi then S.hi = hi end
    end
    return math.floor((c + (S.lo + S.hi) / 2) * 1000 + 0.5) / 1000
end

-- half-width of the offset interval in seconds: the worst-case error of now()
function M.uncertainty_s() return S.lo and (S.hi - S.lo) / 2 or 0.5 end

-- "2026-11-01T12:34:56.789Z" for epoch seconds ts (default now())
function M.iso(ts)
    local ms = math.floor((ts or M.now()) * 1000 + 0.5)
    return os.date("!%Y-%m-%dT%H:%M:%S", ms // 1000) .. string.format(".%03dZ", ms % 1000)
end

-- the whole-second iso the event rows already carry, safe for a fractional ts (os.date needs an integer)
function M.iso_s(ts) return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ts or M.time())) end

-- Stamp an event row in place: ts (ms epoch), iso (whole seconds, as before), and while a body action runs, its
-- correlation ids (telemetry item 2): act = the bridge cmd id, ep = the brain episode, call = the model's tool_use id.
-- client_bridge.lua publishes the running action as _G.__dwc_act = {act, ep, call, kind} (nil when idle).
function M.stamp(ev)
    ev.ts = ev.ts or M.now()
    ev.iso = M.iso_s(ev.ts)
    local a = rawget(_G, "__dwc_act")
    if type(a) == "table" then
        if ev.act == nil then ev.act = a.act end
        if ev.ep == nil then ev.ep = a.ep end
        if ev.call == nil then ev.call = a.call end
    end
    return ev
end

function M.reset() for k in pairs(S) do S[k] = nil end end -- tests

return M
