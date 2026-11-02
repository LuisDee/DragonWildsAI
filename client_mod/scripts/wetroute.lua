-- Dry routing round water (Luis, 2026-11-02: "water slows him down, he should try go around where he can").
-- Pure: a time-cost A* (vendored Jumper 1.8.1, MIT, scripts/vendor/jumper, with a one-line per-cell cost patch) on
-- the remembered water map's 2 m cells (navmem water cells). Dry cells cost their length at his run speed, wet cells at
-- his swim speed, so a long dry detour still loses to a short swim. Unknown cells are taken as dry; move.lua probes
-- the cells ahead on the detour with the water channel and re-plans when it finds more water.
--   WR.plan{ from = {X,Y}, to = {X,Y}, is_water = fn(x, y) -> bool, cell_cm = 200, margin_cm = 2400,
--            run_cms = 650, swim_cms = 300, max_cells = 9000, shore_cost = 1.5 }
--   -> { points = {{X,Y},...} (to the goal, simplified), cost_s, swim_m, len_m, straight = {cost_s, swim_m, len_m} }
--      or nil, why
--   WR.line(from, to, is_water, cell_cm) -> {cost-free stats of the straight line: swim_m, len_m, first_wet_m}
local WR = {}

local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
here = here:gsub("\\", "/")
local JP
local function jumper()
    if JP == nil then
        local add = here .. "/?.lua"
        if not package.path:find(add, 1, true) then package.path = add .. ";" .. package.path end
        local okg, Grid = pcall(require, "vendor.jumper.grid")
        local okp, Pathfinder = pcall(require, "vendor.jumper.pathfinder")
        JP = (okg and okp) and { Grid = Grid, Pathfinder = Pathfinder } or false
    end
    return JP or nil
end
WR._jumper = jumper

-- the straight line from -> to, sampled every 50 cm: how much of it is water
function WR.line(from, to, is_water, cell_cm)
    local dx, dy = to.X - from.X, to.Y - from.Y
    local len = math.sqrt(dx * dx + dy * dy)
    local n = math.max(1, math.ceil(len / 50))
    local wet, first = 0, nil
    for i = 1, n do
        local s = (i - 0.5) / n
        if is_water(from.X + dx * s, from.Y + dy * s) then
            wet = wet + 1
            first = first or (s * len)
        end
    end
    return { len_m = len / 100, swim_m = wet / n * len / 100, first_wet_m = first and first / 100 or nil }
end

local function time_s(len_m, swim_m, run_cms, swim_cms)
    return (len_m - swim_m) * 100 / run_cms + swim_m * 100 / swim_cms
end

function WR.plan(o)
    local J = jumper()
    if not J then return nil, "no_pathfinder" end
    local cell = o.cell_cm or 200
    local margin = o.margin_cm or 2400
    local run, swim = o.run_cms or 650, o.swim_cms or 300
    local x0 = math.floor((math.min(o.from.X, o.to.X) - margin) / cell)
    local y0 = math.floor((math.min(o.from.Y, o.to.Y) - margin) / cell)
    local x1 = math.floor((math.max(o.from.X, o.to.X) + margin) / cell)
    local y1 = math.floor((math.max(o.from.Y, o.to.Y) + margin) / cell)
    local nx, ny = x1 - x0 + 1, y1 - y0 + 1
    if nx * ny > (o.max_cells or 9000) then return nil, "too_far" end
    local wet = {}
    local map = {}
    for j = 1, ny do
        local row = {}
        for i = 1, nx do
            row[i] = 0
            if o.is_water((x0 + i - 0.5) * cell, (y0 + j - 0.5) * cell) then wet[(j - 1) * nx + i] = true end
        end
        map[j] = row
    end
    local function cell_of(p) return math.floor(p.X / cell) - x0 + 1, math.floor(p.Y / cell) - y0 + 1 end
    local sx, sy = cell_of(o.from)
    local ex, ey = cell_of(o.to)
    local grid = J.Grid(map)
    local finder = J.Pathfinder(grid, "ASTAR", 0)
    finder:setHeuristic("EUCLIDIAN")
    local ratio = math.max(1, run / swim)
    -- a cell beside water costs a little more: the remembered map's edge is ragged, so keep a cell off the shore
    local shore = o.shore_cost or 1.5
    local function wet_at(i, j) return i >= 1 and i <= nx and j >= 1 and j <= ny and wet[(j - 1) * nx + i] end
    finder.nodeCost = function(node)
        local i, j = node.x, node.y
        if wet[(j - 1) * nx + i] then return ratio end
        for dj = -1, 1 do for di = -1, 1 do if wet_at(i + di, j + dj) then return shore end end end
        return 1
    end
    local okp, path = pcall(finder.getPath, finder, sx, sy, ex, ey)
    if not (okp and path) then return nil, "no_path" end
    local cells = {}
    for node in path:iter() do cells[#cells + 1] = { X = (x0 + node.x - 0.5) * cell, Y = (y0 + node.y - 0.5) * cell, wet = wet[(node.y - 1) * nx + node.x] } end
    -- simplify: from each kept point, the farthest later cell centre whose straight line keeps the same water (none)
    local is_w = o.is_water
    local pts, k = {}, 1
    cells[1] = { X = o.from.X, Y = o.from.Y, wet = cells[1].wet }
    cells[#cells] = { X = o.to.X, Y = o.to.Y, wet = cells[#cells].wet }
    while k < #cells do
        local best = k + 1
        for m = #cells, k + 2, -1 do
            local ln = WR.line(cells[k], cells[m], is_w, cell)
            local own = 0 -- the path's own water between k and m
            for q = k + 1, m do if cells[q].wet then own = own + 1 end end
            if ln.swim_m <= own * cell / 100 + 0.01 then best = m; break end
        end
        pts[#pts + 1] = { X = cells[best].X, Y = cells[best].Y }
        k = best
    end
    local len, sw = 0, 0
    local prev = o.from
    for _, p in ipairs(pts) do
        local ln = WR.line(prev, p, is_w, cell)
        len, sw = len + ln.len_m, sw + ln.swim_m
        prev = p
    end
    local st = WR.line(o.from, o.to, is_w, cell)
    return { points = pts, len_m = len, swim_m = sw, cost_s = time_s(len, sw, run, swim),
             straight = { len_m = st.len_m, swim_m = st.swim_m, cost_s = time_s(st.len_m, st.swim_m, run, swim) } }
end

return WR
