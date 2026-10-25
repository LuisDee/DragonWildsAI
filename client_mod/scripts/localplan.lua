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
local LP = {}
LP.__index = LP

local function key(i, j) return i * 4096 + j end

function LP.new(o)
    local self = setmetatable({}, LP)
    self.trace = assert(o.trace)
    self.c = { X = o.center.X, Y = o.center.Y, Z = o.center.Z }
    self.cell = o.cell_cm or 100
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
function LP:sample(i, j)
    local x, y = self:pos(i, j)
    local base = self.feet
    local lo, lo_pen = self.trace({ X = x, Y = y, Z = base + self.lo_off }, { X = x, Y = y, Z = base - self.depth })
    local hi, hi_pen = self.trace({ X = x, Y = y, Z = base + self.hi_off }, { X = x, Y = y, Z = base - self.depth })
    self.traces = self.traces + 2
    local layers = {}
    if lo and not lo_pen then layers[#layers + 1] = { z = lo, i = i, j = j } end
    if hi and not hi_pen then
        if not lo or lo_pen or hi > lo + self.env.head then
            layers[#layers + 1] = { z = hi, i = i, j = j }
        end
    end
    -- a low floor needs headroom: if the high trace hit something just above it, that's a roof
    -- low enough to block us only when it's within head clearance, which the hi>lo+head test
    -- already filters (a roof < head above the low floor is treated as the same surface).
    self.nodes[key(i, j)] = layers
end

function LP:step(budget)
    local used = 0
    while self.qi <= #self.queue and used + 2 <= budget do
        local q = self.queue[self.qi]
        self:sample(q[1], q[2])
        self.qi = self.qi + 1
        used = used + 2
    end
    return self.qi > #self.queue and "ready" or "sampling"
end

-- Edge type between two floor nodes (adjacent cells), or nil if impassable by floor data.
function LP:edge(a, b)
    local dz = b.z - a.z
    local e = self.env
    if dz <= e.step and dz >= -e.step then return "walk", 0 end
    if dz > 0 then
        if dz <= e.jump then return "jump", 2 end
        if dz <= e.djump then return "djump", 4 end
        return nil
    end
    if -dz <= e.drop then return "drop", 1 end
    return nil
end

local function ekey(a, b) return tostring(a) .. ">" .. tostring(b) end

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
                            if not closed[nb] and not self.blocked[ekey(cur, nb)] then
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
            local z = (b.act == "jump" or b.act == "djump") and (math.max(a.Z, b.Z) + 60) or (math.max(a.Z, b.Z) + 50)
            local hit = self.trace({ X = a.X, Y = a.Y, Z = z }, { X = b.X, Y = b.Y, Z = z }, true)
            used, self.traces = used + 1, self.traces + 1
            if hit then
                self.blocked[ek] = true
                return "blocked"
            end
            self.edge_ok[ek] = true
        end
    end
    return "ok"
end

return LP
