-- Watch: a generic state recorder, generalised from experiments/tree_watch.lua (the W1 recorder).
-- Records, over time, every actor of some classes near a centre: appear / update / gone, with HP,
-- stump/hidden flags, item data and stack size. Used to LEARN a mechanic (what spawns when a tree
-- falls, a rock breaks, a creature dies) and to VERIFY an outcome (the log census after a fell).
--
-- Two ways to drive it (ARCHITECTURE rule 9: no loop of its own inside a skill):
--   * w = watch.new({classes, center = fn()->loc | actor | loc, radius_cm, period_ms, tag, log})
--     then w:step(now_ms) from the caller's tick. Pure diffing is in M.snapshot / M.diff.
--   * watch.start(log, opts) for experiments: its own LoopInGameThreadWithDelay for opts.seconds,
--     cancelled with CancelDelayedAction (returning true does NOT stop the loop, DISCOVERIES Spells).
-- Read-only: property reads only.
local U = require("body.util")

local M = {}

M.DEFAULT_CLASSES = { "FellableTree", "FelledTree", "TreeLog", "RuntimeSpawnedWorldItem",
                      "DestructibleMiningRock", "OreNode" }

-- One actor's recorded fields (cheap reads only).
function M.read(a, cls)
    return {
        cls = cls, class = U.class_word(a), hp = U.health(a),
        stump = U.try(function() return a.bIsStump end),
        hidden = U.try(function() return a.bIsHidden end),
        item = U.path_of(U.try(function() return a.ItemData end)),
        stack = U.try(function() return a:GetStackSize() end),
        pos = U.to_wire(U.loc(a)),
    }
end

-- {actor_id = fields} for every alive actor of `classes` within radius_cm of center (a loc).
-- An actor listed under two classes (TreeLog includes SplittableTreeLog) is kept once.
function M.snapshot(classes, center, radius_cm)
    local out = {}
    if not center then return out end
    for _, cls in ipairs(classes) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local at = U.loc(a)
            local d = U.dist(center, at)
            if d <= radius_cm then
                local id = U.short(a) or tostring(a)
                if not out[id] then
                    local r = M.read(a, cls)
                    r.dist_m = U.cm_to_m(d)
                    out[id] = r
                end
            end
        end
    end
    return out
end

local CHANGE_FIELDS = { "hp", "stump", "hidden", "stack" }

-- Pure: list of {change = appear|update|gone, actor, state|last} between two snapshots.
function M.diff(prev, snap)
    local out = {}
    for id, v in pairs(snap) do
        local p = prev[id]
        if not p then
            out[#out + 1] = { change = "appear", actor = id, state = v }
        else
            for _, f in ipairs(CHANGE_FIELDS) do
                if p[f] ~= v[f] then out[#out + 1] = { change = "update", actor = id, state = v }; break end
            end
        end
    end
    for id, v in pairs(prev) do
        if not snap[id] then out[#out + 1] = { change = "gone", actor = id, last = v } end
    end
    table.sort(out, function(a, b) return a.actor < b.actor end)
    return out
end

local function center_of(c)
    if type(c) == "function" then return c() end
    if type(c) == "table" and c.X then return c end
    if c ~= nil then return U.loc(c) end
    return nil
end

local W = {}
W.__index = W

-- opts: {classes, center, radius_cm=2500, period_ms=1000, tag="watch", log, on_change=fn(ev)}
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        classes = opts.classes or M.DEFAULT_CLASSES, center = opts.center, radius_cm = opts.radius_cm or 2500,
        period_ms = opts.period_ms or 1000, tag = opts.tag or "watch", log = opts.log, on_change = opts.on_change,
        prev = {}, last = nil, t0 = nil, events = 0,
    }, W)
end

-- Take a snapshot if the period elapsed; log and return the changes.
function W:step(now)
    if self.last and now - self.last < self.period_ms then return nil end
    self.last = now
    self.t0 = self.t0 or now
    local snap = M.snapshot(self.classes, center_of(self.center), self.radius_cm)
    local changes = M.diff(self.prev, snap)
    self.prev = snap
    for _, ev in ipairs(changes) do
        ev.t_ms = now - self.t0
        self.events = self.events + 1
        U.event(self.log, self.tag, ev)
        if self.on_change then pcall(self.on_change, ev) end
    end
    return changes
end

-- Counts by class word in the last snapshot (handy for verification).
function W:counts()
    local c = {}
    for _, v in pairs(self.prev) do c[v.class or "?"] = (c[v.class or "?"] or 0) + 1 end
    return c
end

-- Experiments only: run a watcher on its own game-thread loop for opts.seconds.
function M.start(log, opts)
    opts = opts or {}
    opts.log = opts.log or log
    local w = M.new(opts)
    local t, handle = 0, nil
    local seconds = opts.seconds or 120
    handle = LoopInGameThreadWithDelay(w.period_ms, function()
        t = t + w.period_ms
        pcall(w.step, w, t)
        if t >= seconds * 1000 then
            U.event(log, w.tag .. "_done", { ms = t, events = w.events })
            pcall(CancelDelayedAction, handle)
        end
    end)
    return w
end

return M
