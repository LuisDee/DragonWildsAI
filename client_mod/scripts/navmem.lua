-- navmem.lua: NAVIGATION MEMORY for Claude's client (docs/design/streamline-plan.md step 5, R5).
-- Pure data + graph code, no engine calls (offline-tested: client_mod/tests/test_navmem.lua).
--
--  * ROUTE CACHE: every successful trip is stored as a polyline (~2.5 m spacing). Routes are joined
--    into one graph (consecutive points, plus "join" edges between points of different routes that
--    are close), and planned with Dijkstra, the way the FFXIV bot keeps learned waypoints
--    (github.com/Syraxius/FFXIVSyraxiusBot). Learned traversal links (traverse_learn.lua) are extra
--    directed edges in the same graph.
--  * TRAP MEMORY: an area where Claude got stuck, with the exit that worked. Inside a trap with the
--    goal outside, the exit comes first. A failed approach is TABOOED (Pogamut taboo nav points:
--    diana.ms.mff.cuni.cz/pogamut_files/lectures/2015-2016/Pogamut_3-2016-Lecture-05-Slides-Navigation.pdf):
--    edges toward the tabooed point from the trap get a large cost.
--  * Storage (data, not code): learned per world  -> <root>/data/skills/<world>/nav_memory.json
--                              map seeds (static) -> <root>/data/nav/<map>_seeds.json
--    Points are METRES in the files ({x,y,z} feet level) and centimetres in this API.
-- L28: never spawn a process on a hot path. A directory is created only if it is really missing
-- (an open-for-append probe), and only once per load (cached).
local DIRS_OK = {}
local function ensure_dir(d)
    d = tostring(d):gsub("\\", "/")
    if DIRS_OK[d] then return end
    local probe = d .. "/.dwclient_probe"
    local f = io.open(probe, "a")
    if f then f:close(); os.remove(probe); DIRS_OK[d] = true; return end
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. d .. '"') end
    DIRS_OK[d] = true
end
local NM = {}

NM.cfg = {
    spacing_cm = 250,      -- stored route resolution
    join_cm = 400,         -- points of different routes this close are connected
    entry_cm = 1500,       -- start/goal connect to graph points within this (straight-line assumed)
    entry_factor = 1.5,    -- the unknown straight bits cost more than remembered ones
    entry_dz_cm = 150,     -- an entry edge may rise/fall this much ...
    entry_grade = 0.1,     -- ... plus this much per metre of run (a walkable slope, not a ledge)
    dup_cm = 500,          -- a route with start AND end this close to an existing one replaces it
    max_routes = 400,
    taboo_r_cm = 300,      -- an edge ending within this of a taboo point ...
    taboo_from_cm = 1000,  -- ... and starting within this of the taboo's origin is penalised
    taboo_cost = 10,
    min_route_cm = 1000,   -- don't store trips shorter than this
    water_cell_cm = 200,   -- learned water map resolution
    water_cost = 8,        -- extra cost (in metres per metre) of a remembered route point in water
}

local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function cm(p) if p.X then return { X = p.X, Y = p.Y, Z = p.Z } end return { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 } end
local function m(p) return { math.floor(p.X + 0.5) / 100, math.floor(p.Y + 0.5) / 100, math.floor(p.Z + 0.5) / 100 } end

-- ------------------------------------------------------------------ storage
local JSON
local function json(root)
    if JSON == nil then
        local chunk = loadfile(root .. "/client_mod/scripts/dkjson.lua")
        JSON = chunk and chunk() or false
    end
    return JSON
end

local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("a"); f:close(); return s
end

local function mkdir(p) ensure_dir(p) end

function NM.paths(root, world, map)
    return {
        mem = root .. "/data/skills/" .. world .. "/nav_memory.json",
        mem_dir = root .. "/data/skills/" .. world,
        seeds = root .. "/data/nav/" .. (map or "L_World") .. "_seeds.json",
    }
end

-- mem = { v, world, routes = {{id, pts={{x,y,z}..} m, ts, n_used, n_ok, n_fail, src}},
--         traps = {{id, center={x,y,z}, radius_m, z_max, z_min, exit={{x,y,z[,act]}..}, src, status, n_ok}},
--         taboos = {{at={x,y,z}, toward={x,y,z}, n, ts, note}} }
function NM.new_mem(world) return { v = 1, world = world, routes = {}, traps = {}, taboos = {}, water = {}, next_id = 1 } end

-- ------------------------------------------------------------------ water (learned from wading/swimming)
local function wkey(p) return math.floor(p.X / NM.cfg.water_cell_cm) .. ":" .. math.floor(p.Y / NM.cfg.water_cell_cm) end
function NM.mark_water(mem, p) mem.water = mem.water or {}; if not mem.water[wkey(p)] then mem.water[wkey(p)] = true; return true end end
function NM.is_water(mem, p) return mem.water ~= nil and mem.water[wkey(p)] == true end
-- standing dry on a cell marked water (a false mark: the water probe once saw a roof or a bench as a surface) clears it
function NM.clear_water(mem, p) if mem.water and mem.water[wkey(p)] then mem.water[wkey(p)] = nil; return true end end

-- ------------------------------------------------------------------ water spots (where collecting water WORKED)
-- {water = {X,Y,Z} cm | nil, stand = {X,Y,Z} cm, n_ok, ts}: the place he stood when a press on water gave water
-- (move.remember_water_spot). A new success within 3 m of a known spot counts for that spot.
function NM.add_water_spot(mem, water, stand)
    mem.water_spots = mem.water_spots or {}
    for _, ws in ipairs(mem.water_spots) do
        if math.sqrt((ws.stand.X - stand.X) ^ 2 + (ws.stand.Y - stand.Y) ^ 2) < 300 then
            ws.n_ok, ws.ts, ws.stand = (ws.n_ok or 1) + 1, os.time(), stand
            if water then ws.water = water end
            return #mem.water_spots
        end
    end
    mem.water_spots[#mem.water_spots + 1] = { water = water, stand = stand, n_ok = 1, ts = os.time() }
    return #mem.water_spots
end
-- The known spot nearest to p (a water point or Claude) within max_cm (by its water point, else its stand).
function NM.water_spot_near(mem, p, max_cm)
    local best, bd
    for _, ws in ipairs(mem.water_spots or {}) do
        local q = ws.water or ws.stand
        local d = math.sqrt((q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2)
        if d <= (max_cm or 4000) and (not bd or d < bd) then best, bd = ws, d end
    end
    return best
end

function NM.load(root, world, map)
    local P = NM.paths(root, world, map)
    local J = json(root)
    local mem
    local s = read(P.mem)
    if s and J then local ok, t = pcall(J.decode, s); if ok and type(t) == "table" then mem = t end end
    mem = mem or NM.new_mem(world)
    mem.routes, mem.traps, mem.taboos = mem.routes or {}, mem.traps or {}, mem.taboos or {}
    mem.water_spots = mem.water_spots or {}
    local wl = mem.water_cells or {}
    mem.water, mem.water_cells = {}, nil
    for _, k in ipairs(wl) do mem.water[k] = true end
    mem.next_id = mem.next_id or (#mem.routes + #mem.traps + 1)
    -- map seeds are merged in (read-only; a learned trap with the same id wins)
    local ss = read(P.seeds)
    if ss and J then
        local ok, seeds = pcall(J.decode, ss)
        if ok and type(seeds) == "table" then
            local have = {}
            for _, t in ipairs(mem.traps) do have[t.id] = true end
            for _, t in ipairs(seeds.traps or {}) do if not have[t.id] then t.seed = true; mem.traps[#mem.traps + 1] = t end end
            for _, tb in ipairs(seeds.taboos or {}) do tb.seed = true; mem.taboos[#mem.taboos + 1] = tb end
            for _, r in ipairs(seeds.routes or {}) do r.seed = true; mem.routes[#mem.routes + 1] = r end
        end
    end
    mem._root, mem._world, mem._map = root, world, map
    return mem
end

function NM.save(mem)
    local J = json(mem._root)
    if not J then return false end
    local out = { v = 1, world = mem.world, next_id = mem.next_id, routes = {}, traps = {}, taboos = {}, water_cells = {},
                  water_spots = mem.water_spots or {} }
    for k in pairs(mem.water or {}) do out.water_cells[#out.water_cells + 1] = k end
    for _, r in ipairs(mem.routes) do if not r.seed then out.routes[#out.routes + 1] = r end end
    for _, t in ipairs(mem.traps) do if not t.seed then out.traps[#out.traps + 1] = t end end
    for _, t in ipairs(mem.taboos) do if not t.seed then out.taboos[#out.taboos + 1] = t end end
    local P = NM.paths(mem._root, mem._world or mem.world, mem._map)
    mkdir(P.mem_dir)
    local f = io.open(P.mem .. ".tmp", "wb")
    if not f then return false end
    f:write(J.encode(out, { indent = true }))
    f:close()
    os.remove(P.mem)
    return os.rename(P.mem .. ".tmp", P.mem) == true
end

-- ------------------------------------------------------------------ routes
-- Resample a cm polyline to ~spacing (keeps first/last and any point flagged act).
function NM.simplify(pts, spacing)
    spacing = spacing or NM.cfg.spacing_cm
    if #pts == 0 then return {} end
    local out, acc = { pts[1] }, 0
    for i = 2, #pts do
        acc = acc + d3(pts[i - 1], pts[i])
        if acc >= spacing or pts[i].act or i == #pts then out[#out + 1] = pts[i]; acc = 0 end
    end
    return out
end

local function route_len(pts) local L = 0; for i = 2, #pts do L = L + d3(pts[i - 1], pts[i]) end; return L end

-- Store a successful trip (cm points). Returns the route record (new or the one it replaced).
function NM.add_route(mem, pts_cm, meta)
    meta = meta or {}
    local pts = NM.simplify(pts_cm)
    if #pts < 2 or route_len(pts) < NM.cfg.min_route_cm then return nil, "too_short" end
    local a, b = pts[1], pts[#pts]
    for _, r in ipairs(mem.routes) do
        if not r.seed then
            local ra, rb = cm(r.pts[1]), cm(r.pts[#r.pts])
            if d3(ra, a) < NM.cfg.dup_cm and d3(rb, b) < NM.cfg.dup_cm then
                local mp = {}
                for i, p in ipairs(pts) do mp[i] = m(p); if p.act then mp[i][4] = p.act end end
                r.pts, r.ts, r.n_ok = mp, os.time(), (r.n_ok or 0) + 1
                return r, "updated"
            end
        end
    end
    local mp = {}
    for i, p in ipairs(pts) do mp[i] = m(p); if p.act then mp[i][4] = p.act end end
    local r = { id = "r" .. mem.next_id, pts = mp, ts = os.time(), n_ok = 1, n_fail = 0, n_used = 0, src = meta.src or "trip" }
    mem.next_id = mem.next_id + 1
    mem.routes[#mem.routes + 1] = r
    while #mem.routes > NM.cfg.max_routes do table.remove(mem.routes, 1) end
    return r, "added"
end

-- ------------------------------------------------------------------ traps and taboos
function NM.trap_at(mem, pos)
    for _, t in ipairs(mem.traps) do
        if not t.disabled then
            local c = cm(t.center)
            local zmax = t.z_max and t.z_max * 100 or (c.Z + 150)
            local zmin = t.z_min and t.z_min * 100 or (c.Z - 300)
            if d2(pos, c) <= (t.radius_m or 8) * 100 and pos.Z <= zmax and pos.Z >= zmin then return t end
        end
    end
end

-- The exit of a trap as cm points (with act flags), or nil.
function NM.trap_exit(t)
    if not (t and t.exit and #t.exit > 0) then return nil end
    local out = {}
    for i, p in ipairs(t.exit) do out[i] = cm(p); out[i].act = p[4] end
    return out
end

-- Learn (or refresh) a trap at `center` (cm, feet) with the exit that worked (cm points).
function NM.learn_trap(mem, center, exit_cm, meta)
    meta = meta or {}
    local ex = {}
    for i, p in ipairs(NM.simplify(exit_cm, 150)) do ex[i] = m(p); if p.act then ex[i][4] = p.act end end
    for _, t in ipairs(mem.traps) do
        -- (a disabled seed is skipped: matching it again copied it once per tick, 37 copies in 1 s on 10-28)
        if not t.disabled and d2(cm(t.center), center) < (t.radius_m or 8) * 100 and math.abs(cm(t.center).Z - center.Z) < 200 then
            if t.seed then
                -- a learned exit overrides a seed: shadow it with a learned copy under the same id
                local copy = { id = t.id, center = t.center, radius_m = t.radius_m, z_max = t.z_max, z_min = t.z_min,
                    exit = ex, src = meta.src or "learned", status = "verified", n_ok = 1, ts = os.time() }
                t.disabled = true
                mem.traps[#mem.traps + 1] = copy
                return copy, "learned_over_seed"
            end
            t.exit, t.status, t.ts = ex, "verified", os.time()
            -- once per escape (the exit keeps growing on later calls: meta.refresh); walking its stored exit
            -- again (meta.used) is a use, not new evidence that the place shuts him in
            if not meta.refresh then
                if meta.used then t.n_used = (t.n_used or 0) + 1 else t.n_ok = (t.n_ok or 0) + 1 end
            end
            return t, "updated"
        end
    end
    local t = { id = "t" .. mem.next_id, center = m(center), radius_m = meta.radius_m or 8,
        z_max = (center.Z + 150) / 100, z_min = (center.Z - 300) / 100, exit = ex,
        src = meta.src or "learned", status = "verified", n_ok = 1, ts = os.time() }
    mem.next_id = mem.next_id + 1
    mem.traps[#mem.traps + 1] = t
    return t, "added"
end

function NM.taboo(mem, at, toward, note)
    for _, tb in ipairs(mem.taboos) do
        if d3(cm(tb.at), at) < 300 and d3(cm(tb.toward), toward) < 300 then tb.n = (tb.n or 1) + 1; tb.ts = os.time(); return tb end
    end
    local tb = { at = m(at), toward = m(toward), n = 1, ts = os.time(), note = note }
    mem.taboos[#mem.taboos + 1] = tb
    return tb
end

-- Is moving from a to b tabooed? (b near a taboo's target while a is near its origin)
function NM.is_taboo(mem, a, b)
    for _, tb in ipairs(mem.taboos) do
        if d3(b, cm(tb.toward)) < NM.cfg.taboo_r_cm and d2(a, cm(tb.at)) < NM.cfg.taboo_from_cm then return true end
    end
    return false
end

-- ------------------------------------------------------------------ graph + Dijkstra
-- links: optional list of learned traversal links {from={x,y,z} m (feet), to=..., move, usable=bool}
function NM.plan(mem, from, to, opts)
    opts = opts or {}
    local nodes, adj = {}, {}
    local function add_node(p, tag) nodes[#nodes + 1] = { p = p, tag = tag }; adj[#nodes] = {}; return #nodes end
    local function edge(i, j, c) adj[i][#adj[i] + 1] = { j, c } end
    -- (NM.is_taboo / NM.is_water, with the taboo points converted once and each point's water looked up once:
    -- cost runs for every edge, ~10^5 of them on a big memory)
    local tab = {}
    for _, tb in ipairs(mem.taboos) do tab[#tab + 1] = { at = cm(tb.at), toward = cm(tb.toward) } end
    local wet = {}
    local function cost(a, b, base)
        local c = base or d3(a, b)
        for k = 1, #tab do
            local tb = tab[k]
            if d3(b, tb.toward) < NM.cfg.taboo_r_cm and d2(a, tb.at) < NM.cfg.taboo_from_cm then c = c * NM.cfg.taboo_cost; break end
        end
        local w = wet[b]
        if w == nil then w = NM.is_water(mem, b); wet[b] = w end
        if w then c = c * NM.cfg.water_cost end
        return c
    end
    -- route polylines (both directions; jump points only upward along the recorded direction)
    local route_nodes = {}
    for _, r in ipairs(mem.routes) do
        if not r.disabled then
            local prev
            for k, q in ipairs(r.pts) do
                local p = cm(q)
                p.act = q[4]
                local id = add_node(p, r.id)
                route_nodes[#route_nodes + 1] = id
                if prev then
                    local pen = 1 + (r.n_fail or 0) * 0.5
                    edge(prev, id, cost(nodes[prev].p, p) * pen)
                    if not (p.act == "jump" or p.act == "djump") then edge(id, prev, cost(p, nodes[prev].p) * pen) end
                end
                prev = id
            end
        end
    end
    -- learned links as directed edges
    for _, L in ipairs(opts.links or {}) do
        if L.usable ~= false then
            local a, b = add_node(cm(L.from), "link"), add_node(cm(L.to), "link")
            nodes[b].p.act = (L.move == "drop") and "drop" or "jump"
            nodes[b].link = L
            edge(a, b, cost(nodes[a].p, nodes[b].p) + (L.penalty_m or 5) * 100)
            route_nodes[#route_nodes + 1] = a
            route_nodes[#route_nodes + 1] = b
        end
    end
    -- join edges between nearby points of different routes/links. A uniform grid of join_cm cells: a pair closer
    -- than join_cm lies in the same or a neighbouring cell, so the same edges as comparing every pair, without
    -- the O(n^2) (live 2026-11-01: 4560 remembered points made this plan take 9-11 s on the game thread, every
    -- follow/go_to over mem_min_trip_cm froze the client and a fight's arbiter lease expired: "lease_expired")
    local jc = NM.cfg.join_cm
    local jc2 = jc * jc
    local grid = {}
    for y = 1, #route_nodes do
        local j = route_nodes[y]
        local pj, tj = nodes[j].p, nodes[j].tag
        local cx, cy = math.floor(pj.X / jc), math.floor(pj.Y / jc)
        for gx = cx - 1, cx + 1 do
            for gy = cy - 1, cy + 1 do
                local bucket = grid[gx * 1000003 + gy]
                if bucket then
                    for b = 1, #bucket do
                        local i = bucket[b]
                        local ni = nodes[i]
                        if ni.tag ~= tj or ni.tag == "link" then
                            local pi = ni.p
                            local dx, dy, dz = pi.X - pj.X, pi.Y - pj.Y, pi.Z - pj.Z
                            if dz < 120 and dz > -120 then
                                local s = dx * dx + dy * dy + dz * dz
                                if s < jc2 then
                                    local dd = math.sqrt(s)
                                    edge(i, j, cost(pi, pj, dd * 1.2)); edge(j, i, cost(pj, pi, dd * 1.2))
                                end
                            end
                        end
                    end
                end
            end
        end
        local k = cx * 1000003 + cy
        local bucket = grid[k]
        if not bucket then bucket = {}; grid[k] = bucket end
        bucket[#bucket + 1] = j
    end
    if #route_nodes == 0 then return nil, "empty" end
    local S = add_node(cm(from), "start")
    local G = add_node(cm(to), "goal")
    local direct = d3(nodes[S].p, nodes[G].p)
    -- entry edges are walked straight and unseen, so only on the walker's level: rise <= entry_dz_cm + entry_grade x run
    -- (live 2026-10-31: the terrace outside the church "connected" to the lodestone floor 4-6 m below, through the wall)
    local function level(a, b)
        return math.abs(a.Z - b.Z) <= NM.cfg.entry_dz_cm + NM.cfg.entry_grade * math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
    end
    for _, i in ipairs(route_nodes) do
        local ds = d3(nodes[S].p, nodes[i].p)
        if ds < NM.cfg.entry_cm and level(nodes[S].p, nodes[i].p) then edge(S, i, cost(nodes[S].p, nodes[i].p, ds * NM.cfg.entry_factor)) end
        local dg = d3(nodes[i].p, nodes[G].p)
        if dg < NM.cfg.entry_cm and level(nodes[i].p, nodes[G].p) then edge(i, G, cost(nodes[i].p, nodes[G].p, dg * NM.cfg.entry_factor)) end
    end
    -- Dijkstra with a binary heap (stale entries skipped): the graph has thousands of nodes now, and a linear scan
    -- for the next node was O(n^2) on its own
    local dist, prev, done = { [S] = 0 }, {}, {}
    local hd, hv, hn = { 0 }, { S }, 1
    local function push(d, v)
        hn = hn + 1
        local i = hn
        while i > 1 do
            local p = (i - i % 2) / 2
            if hd[p] <= d then break end
            hd[i], hv[i] = hd[p], hv[p]
            i = p
        end
        hd[i], hv[i] = d, v
    end
    local function pop()
        local d0, v0 = hd[1], hv[1]
        local d, v = hd[hn], hv[hn]
        hd[hn], hv[hn] = nil, nil
        hn = hn - 1
        if hn > 0 then
            local i = 1
            while true do
                local l = 2 * i
                if l > hn then break end
                if l < hn and hd[l + 1] < hd[l] then l = l + 1 end
                if hd[l] >= d then break end
                hd[i], hv[i] = hd[l], hv[l]
                i = l
            end
            hd[i], hv[i] = d, v
        end
        return d0, v0
    end
    while hn > 0 do
        local best, u = pop()
        if not done[u] and best <= dist[u] then
            if u == G then break end
            done[u] = true
            for _, e in ipairs(adj[u]) do
                local v, c = e[1], e[2]
                local nd = best + c
                if not dist[v] or nd < dist[v] then dist[v], prev[v] = nd, u; push(nd, v) end
            end
        end
    end
    if not dist[G] then return nil, "no_connection" end
    if opts.max_factor and dist[G] > direct * opts.max_factor + 2000 then return nil, "detour_too_long" end
    local out, k = {}, prev[G]
    while k and k ~= S do
        local p = nodes[k].p
        table.insert(out, 1, { X = p.X, Y = p.Y, Z = p.Z, act = p.act, link = nodes[k].link })
        k = prev[k]
    end
    if #out == 0 then return nil, "no_memory_edge" end
    out[#out + 1] = { X = nodes[G].p.X, Y = nodes[G].p.Y, Z = nodes[G].p.Z }
    return out, { cost_cm = dist[G], direct_cm = direct, n = #out }
end

return NM
