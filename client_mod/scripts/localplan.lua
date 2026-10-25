-- localplan.lua: client-side LOCAL PLANNER from physics traces (route R2). Claude's client has the
-- real collision (terrain AND replicated player builds), which the dev-server navmesh lacks, so a
-- small grid sampled with line traces finds the way out of pits, alcoves and buildings.
--
-- Pattern (adapted, not invented):
--   * sampling = A* Pathfinding Project GridGraph / LayerGridGraph scan: a downward raycast per
--     cell gives floor height, with up to two layers per cell (here: one trace from just above
--     our own level, one from high above, so a ledge above an alcove is a separate node);
--   * edges = mineflayer-pathfinder move types: walk (step), jump up, double jump up, drop down;
--   * walls/thin obstacles are checked LAZILY (Lazy PRM, Bohlin & Kavraki 2000): A* runs on floor
--     data only, then only the chosen path's edges get horizontal traces; a blocked edge is
--     removed and the path re-planned. That keeps the trace count bounded.
-- Cost on the dev server: ~1 ms CPU per LineTraceSingle from Lua (FHitResult marshalling), so all
-- traces are spread over frames with a budget (step()).
--
-- API:
--   local P = LP.new(opts)          opts.trace(a, b) -> hit_z | nil, start_penetrating   (cm)
--                                   opts.center {X,Y,Z} (pawn location), opts.radius_m (12),
--                                   opts.cell_cm (100), env = {step, jump, djump, drop} cm
--   P:step(budget) -> "sampling" | "ready"       (budget = traces this call)
--   P:plan(goal) -> points {X,Y,Z,act="walk"|"jump"|"djump"|"drop"} | nil, reason
--   P:verify(points, budget) -> "ok" | "blocked" (re-plan) | "verifying"
--   LP.prefetch(cache, trace, x, y, feet_z, opts) -> traces used (0 if cached): sample one
--                                   world cell into the cache while moving (no standstill later)
-- CACHE (opts.cache = { cells = {}, ttl = 30 }, opts.now = clock function): the grid is snapped to a
-- world-aligned lattice, so cells sampled by earlier plans or by prefetch are reused while fresh
-- (within ttl s, and sampled from a reference height within 60 cm of ours). Builds can change, so
-- the ttl stays short.
local LP = {}
LP.__index = LP

local function key(i, j) return i * 4096 + j end

function LP.new(o)
    local self = setmetatable({}, LP)
    self.trace = assert(o.trace)
    self.cell = o.cell_cm or 100
    -- snap to the world lattice so cached cells line up between plans
    self.c = { X = math.floor(o.center.X / self.cell + 0.5) * self.cell,
               Y = math.floor(o.center.Y / self.cell + 0.5) * self.cell, Z = o.center.Z }
    self.cache = o.cache
    -- Claude's own position: bIgnoreSelf ignores his pawn but NOT his attached gear actors (armour,
    -- held tool), which block Visibility traces. Live 19:22: every edge leaving his own cell hit
    -- his gear -> "walls everywhere". Cells within self_r use his feet height (he stands there),
    -- and wall checks skip the part of a segment within self_r of him.
    self.self_pos = o.self_pos
    self.self_r = o.self_r or 80
    self.now = o.now or os.clock
    self.cache_hits = 0
    self.r = math.floor((o.radius_m or 12) * 100 / self.cell)
    self.env = o.env or {}
    self.env.step = self.env.step or 45
    self.env.jump = self.env.jump or 250
    self.env.djump = self.env.djump or 450
    self.env.drop = self.env.drop or 600
    self.env.head = self.env.head or 190       -- clearance needed above a floor
    self.lo_off = o.lo_off or 100              -- low trace starts this far above our feet level
    self.hi_off = o.hi_off or 700              -- high trace starts this far above
    self.depth = o.depth or 900                -- traces go this far below our level
    self.nodes = {}                            -- key -> { {z=,i=,j=}, ... } (1-2 layers)
    self.blocked = {}                          -- edge key -> true (lazy wall checks)
    self.edge_ok = {}
    self.steep = {}                            -- edge key -> true: a "slope" walk that is really a step
    self.wall_pts = {}                         -- horizontal-check hit points: edges passing near one are walls
    self.queue = {}
    -- spiral order from the centre outwards, so a partial grid is still useful
    for ring = 0, self.r do
        for i = -ring, ring do
            for j = -ring, ring do
                if math.max(math.abs(i), math.abs(j)) == ring then self.queue[#self.queue + 1] = { i, j } end
            end
        end
    end
    self.qi = 1
    self.traces = 0
    self.feet = o.feet_z or (self.c.Z - 90)    -- capsule half-height ~90 cm
    return self
end

function LP:pos(i, j) return self.c.X + i * self.cell, self.c.Y + j * self.cell end

-- Sample one cell (2 traces). Layers with < head clearance between them collapse to one.
-- Floor heights (cm) of one world cell: up to two layers, from a trace starting just above our
-- level and one from high above (a ledge over an alcove is a separate layer). Two surfaces closer
-- than head clearance are ONE walkable surface: the upper one (the lower has no headroom).
local function cell_floors(trace, x, y, feet, lo_off, hi_off, depth, head)
    local lo, lo_pen = trace({ X = x, Y = y, Z = feet + lo_off }, { X = x, Y = y, Z = feet - depth })
    local hi, hi_pen = trace({ X = x, Y = y, Z = feet + hi_off }, { X = x, Y = y, Z = feet - depth })
    local zs = {}
    local lo_ok, hi_ok = lo and not lo_pen, hi and not hi_pen
    if lo_ok and hi_ok and hi > lo + 5 and hi <= lo + head then
        -- something sits less than head clearance above the low floor: the low floor has NO
        -- headroom (e.g. the ground under a ramp, live 19:22 church start area), and the upper
        -- surface (first hit from above, so open above) is the walkable one. Keep only that.
        zs[1] = hi
        return zs
    end
    if lo_ok then zs[#zs + 1] = lo end
    if hi_ok and (not lo_ok or hi > lo + head) then zs[#zs + 1] = hi end
    return zs
end

local function ckey(x, y, cell) return math.floor(x / cell + 0.5) .. ":" .. math.floor(y / cell + 0.5) end

local function cache_get(cache, k, feet, now)
    local e = cache and cache.cells[k]
    if e and now - e.t <= (cache.ttl or 30) and math.abs(e.feet - feet) <= 60 then return e.zs end
end

function LP.prefetch(cache, trace, x, y, feet, o)
    o = o or {}
    local cell = o.cell_cm or 100
    local now = (o.now or os.clock)()
    local k = ckey(x, y, cell)
    if cache_get(cache, k, feet, now) then return 0 end
    local env = o.env or {}
    local zs = cell_floors(trace, math.floor(x / cell + 0.5) * cell, math.floor(y / cell + 0.5) * cell, feet,
        o.lo_off or 100, o.hi_off or 700, o.depth or 900, env.head or 190)
    cache.cells[k] = { t = now, feet = feet, zs = zs }
    return 2
end

function LP:sample(i, j)
    local x, y = self:pos(i, j)
    if self.self_pos and math.sqrt((x - self.self_pos.X) ^ 2 + (y - self.self_pos.Y) ^ 2) < self.self_r then
        self.nodes[key(i, j)] = { { z = self.feet, i = i, j = j } }
        return 0
    end
    local k = ckey(x, y, self.cell)
    local now = self.now()
    local zs = cache_get(self.cache, k, self.feet, now)
    if zs then
        self.cache_hits = self.cache_hits + 1
    else
        zs = cell_floors(self.trace, x, y, self.feet, self.lo_off, self.hi_off, self.depth, self.env.head)
        self.traces = self.traces + 2
        if self.cache then self.cache.cells[k] = { t = now, feet = self.feet, zs = zs } end
    end
    local layers = {}
    for _, z in ipairs(zs) do layers[#layers + 1] = { z = z, i = i, j = j } end
    self.nodes[key(i, j)] = layers
    return zs and 2 or 0
end

function LP:step(budget)
    local used = 0
    while self.qi <= #self.queue and used + 2 <= budget do
        local q = self.queue[self.qi]
        local t0 = self.traces
        self:sample(q[1], q[2])
        self.qi = self.qi + 1
        used = used + (self.traces - t0) -- cached cells are free
    end
    return self.qi > #self.queue and "ready" or "sampling"
end

-- Edge type between two floor nodes (adjacent cells), or nil if impassable by floor data.
-- Edge type between two floor nodes (adjacent cells). Between `step` and the walkable SLOPE
-- (tan of WalkableFloorAngle minus a margin, times the horizontal distance) the edge is a
-- provisional "walk" (a slope), unless verify() found the profile to be a step (self.steep[ek]).
local function ekey(a, b) return tostring(a) .. ">" .. tostring(b) end

function LP:edge(a, b)
    local dz = b.z - a.z
    local e = self.env
    if dz <= e.step and dz >= -e.step then return "walk", 0 end
    local run = math.sqrt(((b.i - a.i) * self.cell) ^ 2 + ((b.j - a.j) * self.cell) ^ 2)
    if math.abs(dz) <= (e.slope_k or 0.9) * run and not self.steep[ekey(a, b)] then return "walk", 0.3 end
    if dz > 0 then
        if dz <= e.jump then return "jump", 2 end
        if dz <= e.djump then return "djump", 4 end
        return nil
    end
    if -dz <= e.drop then return "drop", 1 end
    return nil
end

-- 2D distance from point p to segment a-b
local function seg_dist(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local l2 = vx * vx + vy * vy
    local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * vx + (py - ay) * vy) / l2)) or 0
    local qx, qy = ax + vx * t, ay + vy * t
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

-- Does the edge between two nodes pass a known wall hit (from an earlier lazy check)? One hit then
-- rules out every edge across that wall nearby, instead of one re-plan per crossing edge (a thin
-- wall spanning many cells exhausted the 12-round budget: "walls everywhere").
function LP:crosses_wall(a, b)
    if #self.wall_pts == 0 then return false end
    local ax, ay = self:pos(a.i, a.j)
    local bx, by = self:pos(b.i, b.j)
    local top = math.max(a.z, b.z)
    for _, w in ipairs(self.wall_pts) do
        if w.Z > top and w.Z < top + 150 and seg_dist(w.X, w.Y, ax, ay, bx, by) < 45 then return true end
    end
    return false
end

-- A* over the sampled nodes from the node nearest to the centre at our level, toward `goal`
-- (cm). If the goal is off-grid, the target is the reachable node closest to it.
function LP:plan(goal)
    local start, best = nil, math.huge
    for _, n in ipairs(self.nodes[key(0, 0)] or {}) do
        local d = math.abs(n.z - self.feet)
        if d < best then best, start = d, n end
    end
    if not start then
        -- standing somewhere odd: take any nearby node at our level
        for di = -1, 1 do for dj = -1, 1 do
            for _, n in ipairs(self.nodes[key(di, dj)] or {}) do
                local d = math.abs(n.z - self.feet) + 50
                if d < best then best, start = d, n end
            end
        end end
    end
    if not start then return nil, "no_start_floor" end
    local cell = self.cell
    local function h(n)
        local x, y = self:pos(n.i, n.j)
        return math.sqrt((x - goal.X) ^ 2 + (y - goal.Y) ^ 2 + ((n.z - goal.Z) * 0.5) ^ 2)
    end
    local g, came, act = { [start] = 0 }, {}, {}
    local open, closed = { start }, {}
    local best_n, best_h = start, h(start)
    local expanded = 0
    while #open > 0 and expanded < 4000 do
        local bi, bf = 1, math.huge
        for k, n in ipairs(open) do
            local f = g[n] + h(n)
            if f < bf then bi, bf = k, f end
        end
        local cur = table.remove(open, bi)
        if not closed[cur] then
            closed[cur] = true
            expanded = expanded + 1
            local hc = h(cur)
            if hc < best_h then best_h, best_n = hc, cur end
            if hc < cell then break end
            for di = -1, 1 do
                for dj = -1, 1 do
                    if di ~= 0 or dj ~= 0 then
                        for _, nb in ipairs(self.nodes[key(cur.i + di, cur.j + dj)] or {}) do
                            if not closed[nb] and not self.blocked[ekey(cur, nb)] and not self:crosses_wall(cur, nb) then
                                local kind, extra = self:edge(cur, nb)
                                if kind then
                                    local step = ((di ~= 0 and dj ~= 0) and 1.414 or 1) * cell + extra * cell
                                    local ng = g[cur] + step
                                    if not g[nb] or ng < g[nb] then
                                        g[nb], came[nb], act[nb] = ng, cur, kind
                                        open[#open + 1] = nb
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if best_n == start then return nil, "no_progress_possible" end
    -- the goal is out of reach inside this window (e.g. on a ledge above jump height): say so instead
    -- of handing back a route to the cliff base that the lazy wall check then rejects again and again
    if h(start) - best_h < 2 * cell and best_h > 2 * cell then return nil, "unreachable_in_window" end
    local rev, n = {}, best_n
    while n do
        local x, y = self:pos(n.i, n.j)
        rev[#rev + 1] = { X = x, Y = y, Z = n.z, act = act[n] or "walk", node = n }
        n = came[n]
    end
    local pts = {}
    for k = #rev, 1, -1 do pts[#pts + 1] = rev[k] end
    self.expanded = expanded
    return pts
end

-- Lazy wall check of a planned path: a horizontal trace between consecutive points at knee
-- height (walk/drop) or just above the higher floor (jumps). A hit blocks that edge.
-- Returns "ok", "blocked" (call plan() again), or "verifying" (budget used up; call again).
function LP:verify(pts, budget)
    local used = 0
    for k = 2, #pts do
        local a, b = pts[k - 1], pts[k]
        local ek = ekey(a.node, b.node)
        if not self.edge_ok[ek] then
            if used >= budget then return "verifying" end
            -- a provisional slope walk: one downward trace at the midpoint tells slope from step
            if b.act == "walk" and math.abs(b.Z - a.Z) > self.env.step then
                local mx, my = (a.X + b.X) / 2, (a.Y + b.Y) / 2
                local mz = self.trace({ X = mx, Y = my, Z = math.max(a.Z, b.Z) + 100 }, { X = mx, Y = my, Z = math.min(a.Z, b.Z) - 100 })
                used, self.traces = used + 1, self.traces + 1
                local lin = (a.Z + b.Z) / 2
                if not mz or math.abs(mz - lin) > 0.3 * math.abs(b.Z - a.Z) then
                    self.steep[ek] = true
                    self.steeps = (self.steeps or 0) + 1
                    return "blocked" -- re-plan: edge() now treats it as a jump/drop
                end
            end
            local z = (b.act == "jump" or b.act == "djump") and (math.max(a.Z, b.Z) + 60) or (math.max(a.Z, b.Z) + 50)
            -- clip the part of the segment within self_r of Claude (his own gear)
            local ax, ay, bx, by = a.X, a.Y, b.X, b.Y
            local sp = self.self_pos
            if sp then
                local function near(px, py) return math.sqrt((px - sp.X) ^ 2 + (py - sp.Y) ^ 2) < self.self_r end
                local n = 0
                while near(ax, ay) and n < 10 do ax, ay = ax + (bx - ax) * 0.2, ay + (by - ay) * 0.2; n = n + 1 end
                n = 0
                while near(bx, by) and n < 10 do bx, by = bx + (ax - bx) * 0.2, by + (ay - by) * 0.2; n = n + 1 end
            end
            local hit, hp = false, nil
            if math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) > 10 then
                hit, hp = self.trace({ X = ax, Y = ay, Z = z }, { X = bx, Y = by, Z = z }, true)
            end
            if hit and type(hp) == "table" and hp.X then self.wall_pts[#self.wall_pts + 1] = { X = hp.X, Y = hp.Y, Z = z } end
            used, self.traces = used + 1, self.traces + 1
            if hit then
                self.blocked[ek] = true
                self.blocks = (self.blocks or 0) + 1
                self.block_log = self.block_log or {}
                if #self.block_log < 6 then
                    self.block_log[#self.block_log + 1] = string.format("%s(%.0f,%.0f,%.0f)->(%.0f,%.0f,%.0f)@%.0f",
                        b.act, a.X, a.Y, a.Z, b.X, b.Y, b.Z, z)
                end
                return "blocked"
            end
            self.edge_ok[ek] = true
        end
    end
    return "ok"
end

return LP
