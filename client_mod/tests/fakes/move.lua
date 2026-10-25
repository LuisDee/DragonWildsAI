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
    return { ok = true, mode = "go_to", gen = 1 }
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
