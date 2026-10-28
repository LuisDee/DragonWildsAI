-- NAV ORACLE (route R2, docs/research/2026-10-25-client-side-botting.md decision 3).
-- Claude's headless client has no NavigationSystem, so the DEV server (same map L_World, real
-- navmesh) answers path queries and the client mover (client_mod/scripts/move.lua) steers along
-- the waypoints. Glue: tools/nav_oracle.py (client_io/nav/req.json -> this -> resp.lua).
--
--   debug_run {"module":"nav_oracle","args":{"from":[x,y,z],"to":[x,y,z]}}        metres (wire units)
--     -> { ok, points = {{x,y,z},...} metres, n, partial, length_m, ms }  or
--        { ok=false, reason = "loading" | "start_off_navmesh" | "no_path" | ... , retry = bool }
--   fn "project" {at, ext}      K2_ProjectPointToNavigation (pure)
--   fn "anchor"  {at} / "anchor_clear"   the streaming-source anchor (below)
--   fn "navmesh" / "info" / "cvar" {names}   read-only diagnostics
--
-- Verified on build 26161880 (DISCOVERIES "Client locomotion (R2)"):
--   * the dev server streams World Partition cells around streaming sources only
--     (wp.Runtime.EnableServerStreaming=1, ...StreamingOut=1); the base navmesh lives in
--     NavigationDataChunkActors inside those cells, so with nobody connected there is NO navmesh
--     near Claude's Shockbyte position. A spawned TargetPoint carrying a
--     UWorldPartitionStreamingSourceComponent loads it (chunks 0 -> 4 within ~10 s).
--   * FindPathToLocationSynchronously(ctx, a, b, nil, nil) on the CDO returns a UNavigationPath;
--     an unfound path has GetPathLength() = -1 and no PathPoints.
--   * K2_ProjectPointToNavigation fills a FLAT {X,Y,Z} table passed as the out param in place
--     (not out.ProjectedLocation). Start/end must be projected first: a pawn's capsule-centre Z
--     is ~0.8 m above the navmesh and the raw query then fails.
--   * auto-generated nav LINKS (UE 5.5 experimental, ini bGenerateNavLinks=True on the dev server)
--     exist only in tiles generated at runtime; the cooked chunk tiles have none. So after a fresh
--     anchor has settled, the oracle dirties the tile columns around it once (a flat movable cube
--     30 m above the anchor, destroyed after 3 s); Dynamic generation rebuilds them WITH links.
--     Verified: the start-area lodestone pad got a +1.85 m link up to the upper level (18:30 UTC).
-- Writes: only the anchor actor and the temporary cube (spawn/destroy), and only on the dev server.
local U = require("body.util")

local M = {}

M.ANCHOR_REUSE_CM = 8000      -- keep the anchor if the query start is within 80 m of it
M.ANCHOR_SETTLE_S = 6         -- after (re)spawning, report "loading" for this long
M.PROJECT_EXTENT = { X = 300, Y = 300, Z = 600 }

local function navsys_cdo()
    return U.try(function() return StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1") end)
end

local function world_ctx()
    for _, cls in ipairs({ "GameStateBase", "WorldSettings" }) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            if U.valid(a) then return a end
        end
    end
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function vec_cm(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    local cx, cy, cz = x * 100, y * 100, z * 100
    if not (finite(cx) and finite(cy) and finite(cz)) then return nil end
    return { X = cx, Y = cy, Z = cz }
end

local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
local function wire(v) return { r2(v.X / 100), r2(v.Y / 100), r2(v.Z / 100) } end

-- Projected point (cm table) or nil. A tight vertical box first (+-1.5 m around the capsule
-- centre): with +-6 m a start UNDER a floor snapped onto the floor above it (live 19:22, church
-- start area: waypoint 2.6 m straight above Claude). The wide box is only the fallback.
M.PROJECT_TIGHT = { X = 150, Y = 150, Z = 150 }
local function project(nav, ctx, p, ext)
    local unknown = false
    for _, e in ipairs(ext and { ext } or { M.PROJECT_TIGHT, M.PROJECT_EXTENT }) do
        local out = { X = p.X, Y = p.Y, Z = p.Z }
        local ok, hit = pcall(function() return nav:K2_ProjectPointToNavigation(ctx, p, out, nil, nil, e) end)
        if ok and hit == true then
            if finite(out.X) and finite(out.Y) and finite(out.Z) then return { X = out.X, Y = out.Y, Z = out.Z }, true end
            unknown = true
        end
        if not ok or hit ~= false then unknown = true end
    end
    if not unknown then return nil, false end
    return nil, nil
end

-- ---------------------------------------------------------------- nav anchor (dev server only)
-- TargetPoint's root is static, so the anchor is relocated by destroy + respawn.
local SRC_CLASS = "/Script/Engine.WorldPartitionStreamingSourceComponent"

M.LINK_REBUILD_M = 160      -- cube side: covers the anchor reuse radius (+-80 m)
-- CORRIDOR streaming for long trips (live 19:22/19:39: no_path for a 357 m trip, the goal area was
-- simply not loaded on the dev server): extra streaming-source anchors every CORRIDOR_STEP_CM
-- along the straight line, up to CORRIDOR_MAX; "loading" while they settle.
M.CORRIDOR_MIN_CM = 12000
M.CORRIDOR_STEP_CM = 12000
M.CORRIDOR_MAX = 5
M.CORRIDOR_SETTLE_S = 10

local function navlinks_enabled()
    for _, r in ipairs(U.find_all("RecastNavMesh", { skip_defaults = true })) do
        if U.try(function() return r.bGenerateNavLinks end) then return true end
    end
    return false
end

-- Dirty the tile columns around `at` (cm) so they are regenerated (with links). Async cleanup.
local function rebuild_links_around(log, at)
    local ctx = world_ctx()
    local world = U.try(function() return ctx:GetWorld() end)
    local cls = U.try(function() return StaticFindObject("/Script/Engine.StaticMeshActor") end)
    local mesh = U.try(function() return StaticFindObject("/Engine/BasicShapes/Cube.Cube") end)
    if not (world and cls and mesh) then return false end
    local ok, a = U.call(log, "nav_oracle.SpawnActor_linkcube", { at = wire(at) }, function()
        return world:SpawnActor(cls, { X = at.X, Y = at.Y, Z = at.Z + 3000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not (ok and U.valid(a)) then return false end
    local comp = a.StaticMeshComponent
    U.call(log, "nav_oracle.linkcube_setup", nil, function()
        comp:SetMobility(2)
        comp:SetStaticMesh(mesh)
        a:SetActorScale3D({ X = M.LINK_REBUILD_M, Y = M.LINK_REBUILD_M, Z = 0.2 })
    end)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function() pcall(function() a:K2_DestroyActor() end) end)
    end)
    U.event(log, "nav_oracle_links_rebuild", { at = wire(at) })
    return true
end

-- A bare streaming source (TargetPoint + WorldPartitionStreamingSourceComponent) at `at` (cm).
local function spawn_source(log, at)
    local cls = U.try(function() return StaticFindObject("/Script/Engine.TargetPoint") end)
    local ccls = U.try(function() return StaticFindObject(SRC_CLASS) end)
    local ctx = world_ctx()
    local world = U.try(function() return ctx:GetWorld() end)
    if not (U.valid(cls) and U.valid(ccls) and world) then return nil end
    local ok, actor = U.call(log, "nav_oracle.SpawnActor_corridor", { at = wire(at) }, function()
        return world:SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not (ok and U.valid(actor)) then return nil end
    U.call(log, "nav_oracle.AddComponentByClass_corridor", nil, function()
        return actor:AddComponentByClass(ccls, false,
            { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    return actor
end

local function corridor_clear(log)
    local c = rawget(_G, "DW_NAV_CORRIDOR")
    if c then
        for _, a in ipairs(c.anchors or {}) do
            if U.valid(a) then U.call(log, "nav_oracle.corridor_destroy", nil, function() a:K2_DestroyActor() end) end
        end
    end
    _G.DW_NAV_CORRIDOR = nil
end

-- Ensure corridor anchors from a to b (cm). Returns age_s of the corridor (0 if just placed), or nil
-- when the trip is short (no corridor needed).
local function ensure_corridor(log, a, b)
    local D = math.sqrt((b.X - a.X) ^ 2 + (b.Y - a.Y) ^ 2)
    if D < M.CORRIDOR_MIN_CM then return nil end
    local key = string.format("%d:%d>%d:%d", math.floor(a.X / 5000), math.floor(a.Y / 5000), math.floor(b.X / 5000), math.floor(b.Y / 5000))
    local c = rawget(_G, "DW_NAV_CORRIDOR")
    if c and c.key == key then return os.time() - c.t end
    corridor_clear(log)
    local n = math.min(M.CORRIDOR_MAX, math.ceil(D / M.CORRIDOR_STEP_CM))
    local anchors = {}
    for k = 1, n do
        local f = (k == n) and 1 or (k * M.CORRIDOR_STEP_CM / D)
        local at = { X = a.X + (b.X - a.X) * f, Y = a.Y + (b.Y - a.Y) * f, Z = a.Z + (b.Z - a.Z) * f }
        local act = spawn_source(log, at)
        if act then anchors[#anchors + 1] = act end
    end
    _G.DW_NAV_CORRIDOR = { key = key, t = os.time(), anchors = anchors, goal = b, links_done = false }
    U.event(log, "nav_oracle_corridor", { n = #anchors, from = wire(a), to = wire(b) })
    return 0
end

function M.anchor_clear(log)
    local a = rawget(_G, "DW_NAV_ANCHOR")
    if U.valid(a) then U.call(log, "nav_oracle.anchor_destroy", nil, function() a:K2_DestroyActor() end) end
    _G.DW_NAV_ANCHOR, _G.DW_NAV_ANCHOR_COMP, _G.DW_NAV_ANCHOR_T, _G.DW_NAV_LINKS_DONE = nil, nil, nil, nil
    corridor_clear(log)
    return { ok = true }
end

-- Ensure an anchor near `at` (cm). Returns { ok, fresh = true if just spawned, age_s }.
local function ensure_anchor(log, at)
    local old = rawget(_G, "DW_NAV_ANCHOR")
    if U.valid(old) then
        local l = U.loc(old)
        if l and math.abs(l.X - at.X) < M.ANCHOR_REUSE_CM and math.abs(l.Y - at.Y) < M.ANCHOR_REUSE_CM then
            return { ok = true, age_s = os.time() - (rawget(_G, "DW_NAV_ANCHOR_T") or 0) }
        end
        M.anchor_clear(log)
    end
    local cls = U.try(function() return StaticFindObject("/Script/Engine.TargetPoint") end)
    local ccls = U.try(function() return StaticFindObject(SRC_CLASS) end)
    local ctx = world_ctx()
    if not (U.valid(cls) and U.valid(ccls) and U.valid(ctx)) then return { ok = false, reason = "missing_class" } end
    local world = U.try(function() return ctx:GetWorld() end)
    local ok, actor = U.call(log, "nav_oracle.SpawnActor_anchor", { at = wire(at) }, function()
        return world:SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(actor) then return { ok = false, reason = "spawn_failed", detail = tostring(actor) } end
    _G.DW_NAV_ANCHOR, _G.DW_NAV_ANCHOR_T = actor, os.time()
    local ok2, comp = U.call(log, "nav_oracle.AddComponentByClass", nil, function()
        return actor:AddComponentByClass(ccls, false,
            { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
    end)
    if not (ok2 and U.valid(comp)) then return { ok = false, reason = "component_failed", detail = tostring(comp) } end
    _G.DW_NAV_ANCHOR_COMP = comp
    return { ok = true, fresh = true, age_s = 0 }
end

function M.anchor(log, args)
    local at = vec_cm(args.at)
    if not at then return { ok = false, reason = "invalid_args" } end
    local r = ensure_anchor(log, at)
    local a = rawget(_G, "DW_NAV_ANCHOR")
    r.anchor, r.comp = U.short(a), U.short(rawget(_G, "DW_NAV_ANCHOR_COMP"))
    local l = U.valid(a) and U.loc(a)
    r.at = l and wire(l) or nil
    return r
end

-- ---------------------------------------------------------------- path query
function M.run(log, args)
    local t0 = os.clock()
    local a, b = vec_cm(args.from), vec_cm(args.to)
    if not (a and b) then return { ok = false, reason = "invalid_args", detail = "from/to must be [x,y,z] metres" } end
    local nav, ctx = navsys_cdo(), world_ctx()
    if not (U.valid(nav) and U.valid(ctx)) then return { ok = false, reason = "no_navsys" } end
    local anc = ensure_anchor(log, a)
    if not anc.ok then return { ok = false, reason = "anchor_" .. tostring(anc.reason), detail = anc.detail } end
    -- once per anchor placement, after it has settled: regenerate the local tiles with nav links
    local links_rebuilt = nil
    if not rawget(_G, "DW_NAV_LINKS_DONE") and (anc.age_s or 0) >= M.ANCHOR_SETTLE_S and navlinks_enabled() then
        _G.DW_NAV_LINKS_DONE = true
        links_rebuilt = rebuild_links_around(log, U.loc(rawget(_G, "DW_NAV_ANCHOR")) or a)
    end
    -- long trip: stream the corridor to the goal, then path over all of it
    local cage = ensure_corridor(log, a, b)
    local corridor = nil
    if cage then
        corridor = #(rawget(_G, "DW_NAV_CORRIDOR").anchors)
        if cage < M.CORRIDOR_SETTLE_S then
            return { ok = false, reason = "loading", retry = true, corridor = corridor, age_s = cage }
        end
        local c = rawget(_G, "DW_NAV_CORRIDOR")
        if not c.links_done and navlinks_enabled() then
            c.links_done = true
            rebuild_links_around(log, c.goal) -- the goal area gets jump links too
        end
    end
    local pa, start_projected = project(nav, ctx, a)
    local pb, goal_projected = project(nav, ctx, b)
    if not pa then
        local loading = (anc.age_s or 0) < M.ANCHOR_SETTLE_S
        return { ok = false, reason = loading and "loading" or (start_projected == false and "start_off_navmesh" or "start_projection_unknown"), retry = loading, goal_projected = goal_projected }
    end
    -- An unprojectable goal (off the navmesh, or not streamed in yet) is still sent raw: Recast
    -- then returns a partial path toward it if it can.
    local path, err = U.try_err(function() return nav:FindPathToLocationSynchronously(ctx, pa, pb or b, nil, nil) end)
    if not U.valid(path) then return { ok = false, reason = "no_path", detail = err, goal_projected = goal_projected } end
    local pts = {}
    local points_ok = pcall(function()
        path.PathPoints:ForEach(function(_, e)
            local v = e:get()
            if not v or not finite(v.X) or not finite(v.Y) or not finite(v.Z) then error("invalid path point") end
            pts[#pts + 1] = wire(v)
        end)
    end)
    if not points_ok then return { ok = false, reason = "invalid_path_payload", points = {}, goal_projected = goal_projected } end
    local ok_partial, partial = pcall(function() return path:IsPartial() end)
    if not ok_partial or type(partial) ~= "boolean" then partial = nil end
    local len = tonumber(U.try(function() return path:GetPathLength() end))
    local ok = #pts >= 2
    local res = {
        ok = ok, reason = (not ok) and ((anc.age_s or 0) < M.ANCHOR_SETTLE_S and "loading" or "no_path") or nil,
        retry = (not ok) and (anc.age_s or 0) < M.ANCHOR_SETTLE_S or nil,
        points = pts, n = #pts, partial = partial, goal_projected = goal_projected, links_rebuilt = links_rebuilt,
        corridor = corridor,
        length_m = len and len > 0 and r2(len / 100) or nil, ms = math.floor((os.clock() - t0) * 1000),
    }
    U.event(log, "nav_oracle", { from = args.from, to = args.to, n = res.n, partial = partial, length_m = res.length_m, ms = res.ms, reason = res.reason })
    return res
end

-- ---------------------------------------------------------------- read-only diagnostics
function M.project(log, args)
    local p = vec_cm(args.at)
    if not p then return { ok = false, reason = "invalid_args" } end
    local q = project(navsys_cdo(), world_ctx(), p, vec_cm(args.ext))
    return { ok = q ~= nil, projected = q and wire(q) or nil }
end

function M.navmesh(log, args)
    local out = { recast = {} }
    for _, n in ipairs(U.find_all("NavigationSystemV1", { skip_defaults = true })) do
        out.navsys = {
            invokers_only = U.try(function() return n.bGenerateNavigationOnlyAroundNavigationInvokers end),
            auto_create = U.try(function() return n.bAutoCreateNavigationData end),
        }
    end
    for _, r in ipairs(U.find_all("RecastNavMesh", { skip_defaults = true })) do
        out.recast[#out.recast + 1] = {
            name = U.short(r), runtime = U.try(function() return r.RuntimeGeneration end),
            radius = U.try(function() return r.AgentRadius end), height = U.try(function() return r.AgentHeight end),
            tile = U.try(function() return r.TileSizeUU end),
        }
    end
    out.chunks = {}
    for _, c in ipairs(U.find_all("NavigationDataChunkActor", { skip_defaults = true })) do
        local l = U.loc(c)
        out.chunks[#out.chunks + 1] = l and { math.floor(l.X / 100), math.floor(l.Y / 100) } or U.short(c)
    end
    return out
end

function M.cvar(log, args)
    local ksl = U.try(function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    local out = {}
    for _, cv in ipairs(args.names or { "wp.Runtime.EnableServerStreaming" }) do
        out[cv] = U.try(function() return ksl:GetConsoleVariableIntValue(cv) end)
    end
    return out
end

function M.info(log, args)
    local a = rawget(_G, "DW_NAV_ANCHOR")
    return {
        nav_systems = #U.find_all("NavigationSystemV1", { skip_defaults = true }),
        recast = #U.find_all("RecastNavMesh", { skip_defaults = true }),
        chunks = #U.find_all("NavigationDataChunkActor", { skip_defaults = true }),
        cdo = U.valid(navsys_cdo()), ctx = U.short(world_ctx()),
        anchor = U.valid(a) and wire(U.loc(a)) or nil,
    }
end

return M
