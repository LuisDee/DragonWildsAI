-- Fake of client_mod/scripts/move.lua (same API and status shape): go_to/follow start a "loop";
-- status() = {mode, status, result = {status = arrived|failed|stopped, reason, dist_m}}.
-- FAKE.auto_arrive = true: the next status() after go_to reports arrival at the target.
local M = {}
_G.FAKE = _G.FAKE or {}
local S = _G.FAKE
S.move = S.move or { mode = "idle", calls = {} }
local LUIS = { 3, 4, 3 }
function M.go_to(log, goal, opts)
    table.insert(S.move.calls, "go_to")
    S.move.mode, S.move.status, S.move.result = "go_to", "moving", nil
    S.move.target = type(goal) == "table" and goal or LUIS
    S.move.tolerance = opts.tolerance_m or 1.5
    return { ok = true, mode = "go_to", gen = 1 }
end
function M.verify_arrival()
    local p, g = S.move.position or S.me_pos or { 1, 2, 3 }, S.move.target
    if S.no_pawn or S.move.dead then return { ok = false, reason = "companion_down", detail = "character unavailable" } end
    if S.move.unknown_life or S.move.airborne then return { ok = false, reason = "verification_failed", detail = "state unavailable" } end
    if not (p and g and p[3] and g[3]) then return { ok = false, reason = "verification_failed", detail = "position unavailable" } end
    local d = math.sqrt((p[1] - g[1]) ^ 2 + (p[2] - g[2]) ^ 2)
    if d > S.move.tolerance or math.abs(p[3] - g[3]) > 1.8 then
        return { ok = false, reason = "verification_failed", detail = "destination not reached" }
    end
    return { ok = true, position = p, target_position = g, tolerance_m = S.move.tolerance,
        vertical_distance_m = math.abs(p[3] - g[3]), vertical_tolerance_m = 1.8 }
end
function M.follow(log, player_name, distance_m, opts)
    table.insert(S.move.calls, "follow:" .. player_name)
    S.move.mode, S.move.status, S.move.result = "follow", "moving", nil
    return { ok = true, mode = "follow", gen = 1 }
end
function M.stop(log)
    table.insert(S.move.calls, "stop")
    local was = S.move.mode
    S.move.mode, S.move.result = "idle", { status = "stopped" }
    return { ok = true, was = was }
end
function M.status()
    if S.auto_arrive and S.move.mode == "go_to" then
        S.move.mode, S.move.result, S.move.position = "idle", { status = "arrived", dist_m = 1.2 }, S.move.target
    end
    return { mode = S.move.mode, status = S.move.status, result = S.move.result, ticks = 1 }
end
M.VERSION = 1
return M
