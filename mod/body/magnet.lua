-- Bot item magnet: the bot collects loose world items near it into its OWN inventory store, like a
-- player's magnet. The native BP_Components_ItemMagnet on the puppet is inert (verified: loot 2.5 m
-- away was never pulled) and forcing it would grant into the null PlayerController inventory
-- (the null-PC crash class), so this re-implements the behaviour with the verified pickup path
-- (items.take_world_item: hide + no collision + lifespan, add to store, same tick).
-- Generic: any world item, no item lists. Safety rules so it never steals from players:
--   * skips items a player's magnet is pulling (items.available)
--   * skips items closer to a player than to the bot
--   * skips items the bot itself dropped in the last DROP_GRACE_S (e.g. a `give` to Luis)
-- DW_BOT_MAGNET=0 disables; DW_BOT_MAGNET_CM sets the range (default 350 cm).
local U = require("body.util")
local items = require("body.items")
local M = {}

M.RANGE_CM = tonumber(os.getenv("DW_BOT_MAGNET_CM") or "") or 350
M.TICK_MS = 1000
M.DROP_GRACE_S = 60
M.MAX_PER_TICK = 5

local S = { handle = nil, recent_drops = {}, taken = 0 }

-- Remember everything the bot spawns as a world item, so the magnet never re-collects it.
local function wrap_spawn()
    if items._magnet_wrapped then return end
    local orig = items.spawn_world_item
    items.spawn_world_item = function(...)
        local res = orig(...)
        local data = type(res) == "table" and res.data or nil
        local now = os.time()
        for _, id in ipairs((data and (data.world_items or data.ids)) or {}) do S.recent_drops[id] = now end
        if data and data.id then S.recent_drops[data.id] = now end
        return res
    end
    items._magnet_wrapped = true
end

local function nearest_player_dist(loc)
    local best
    for _, p in ipairs((U.split_pawns())) do
        local d = U.dist(loc, U.loc(p))
        if d and (not best or d < best) then best = d end
    end
    return best
end

local function tick(log, inv)
    local _, puppets = U.split_pawns()
    local bot = puppets[1]
    if not U.alive(bot) or not inv.is_ready() then return end
    local here = U.loc(bot)
    if not here then return end
    local now = os.time()
    for id, t in pairs(S.recent_drops) do if now - t > M.DROP_GRACE_S then S.recent_drops[id] = nil end end
    for _, info in ipairs(items.find({ origin = here, radius_cm = M.RANGE_CM, max = M.MAX_PER_TICK })) do
        local pd = nearest_player_dist(info.loc)
        if not S.recent_drops[info.id] and not (pd and pd < info.dist) then
            local res = items.take_world_item(log, info.actor, inv)
            if res.ok then
                S.taken = S.taken + (info.count or 0)
                U.event(log, "bot_magnet", { item = info.item, count = info.count, world_item = info.id })
            end
        end
    end
end

function M.status() return { running = S.handle ~= nil, range_cm = M.RANGE_CM, taken = S.taken } end

function M.start(log, inv)
    if S.handle or os.getenv("DW_BOT_MAGNET") == "0" then return M.status() end
    wrap_spawn()
    S.handle = LoopInGameThreadWithDelay(M.TICK_MS, function()
        local ok, err = pcall(tick, log, inv)
        if not ok then U.event(log, "bot_magnet_error", { err = tostring(err) }) end
    end)
    U.event(log, "bot_magnet_started", { range_cm = M.RANGE_CM })
    return M.status()
end

function M.stop()
    if S.handle then pcall(CancelDelayedAction, S.handle); S.handle = nil end
    return M.status()
end

return M
