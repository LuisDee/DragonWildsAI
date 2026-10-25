-- W1 (docs/research/2026-10-25-woodcutting-loop.md): read-only timeline while Luis chops one tree.
-- debug_run {module="tree_watch", args={seconds=240, radius_m=20}} arms a 1 s poll that logs every
-- change near the first player: trees (health, stump), felled trees, logs, dropped world items.
-- Property reads only. Output: "tree_watch" events in logs/mod/mod_*.jsonl.
local U = require("body.util")
local M = {}

local CLASSES = { "FellableTree", "FelledTree", "SplittableTreeLog", "TreeLog", "RuntimeSpawnedWorldItem" }

local function hp(a)
    return U.try(function() return a.HealthComponent:GetAuthoritativeHealth() end)
end

local function snapshot(center, radius_cm)
    local out = {}
    for _, cls in ipairs(CLASSES) do
        for _, a in ipairs(U.find_all(cls)) do
            if U.alive(a) then
                local l = U.loc(a)
                local d = l and center and math.sqrt((l.X - center.X) ^ 2 + (l.Y - center.Y) ^ 2 + (l.Z - center.Z) ^ 2)
                if d and d <= radius_cm then
                    local key = U.fullname(a) or tostring(a)
                    out[key] = {
                        cls = cls, hp = hp(a), stump = U.try(function() return a.bIsStump end),
                        item = U.fullname(U.try(function() return a.ItemData end)),
                        stack = U.try(function() return a:GetStackSize() end),
                        dist_m = math.floor(d / 10) / 10,
                    }
                end
            end
        end
    end
    return out
end

function M.run(log, args)
    if _G.__dw_tree_watch then return { already = true } end
    _G.__dw_tree_watch = true
    local players = U.split_pawns()
    local seconds, radius = args.seconds or 240, (args.radius_m or 20) * 100
    local prev, ticks = {}, 0
    local handle
    handle = LoopInGameThreadWithDelay(1000, function()
        ticks = ticks + 1
        local pl = U.split_pawns()[1]
        local snap = snapshot(pl and U.loc(pl), radius)
        for k, v in pairs(snap) do
            local p = prev[k]
            if not p or p.hp ~= v.hp or p.stump ~= v.stump or p.stack ~= v.stack then
                log.event("tree_watch", { t = ticks, change = p and "update" or "appear", actor = k, state = v })
            end
        end
        for k, v in pairs(prev) do
            if not snap[k] then log.event("tree_watch", { t = ticks, change = "gone", actor = k, last = v }) end
        end
        prev = snap
        if ticks >= seconds then
            log.event("tree_watch_done", { ticks = ticks })
            _G.__dw_tree_watch = nil
            pcall(CancelDelayedAction, handle)
        end
    end)
    return { armed = true, seconds = seconds, radius_m = radius / 100, players = #players }
end

return M
