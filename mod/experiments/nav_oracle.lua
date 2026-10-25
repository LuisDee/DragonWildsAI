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
-- Writes: only the anchor actor (spawn/destroy), and only on the dev server.
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

local function vec_cm(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t[1] or t.x), tonumber(t[2] or t.y), tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return { X = x * 100, Y = y * 100, Z = z * 100 }
end

local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
local function wire(v) return { r2(v.X / 100), r2(v.Y / 100), r2(v.Z / 100) } end

-- Projected point (cm table) or nil.
local function project(nav, ctx, p, ext)
    local out = { X = p.X, Y = p.Y, Z = p.Z }
    local hit = U.try(function() return nav:K2_ProjectPointToNavigation(ctx, p, out, nil, nil, ext or M.PROJECT_EXTENT) end)
    if hit == true then return { X = out.X, Y = out.Y, Z = out.Z } end
end

-- ---------------------------------------------------------------- nav anchor (dev server only)
-- TargetPoint's root is static, so the anchor is relocated by destroy + respawn.
local SRC_CLASS = "/Script/Engine.WorldPartitionStreamingSourceComponent"

function M.anchor_clear(log)
    local a = rawget(_G, "DW_NAV_ANCHOR")
    if U.valid(a) then U.call(log, "nav_oracle.anchor_destroy", nil, function() a:K2_DestroyActor() end) end
    _G.DW_NAV_ANCHOR, _G.DW_NAV_ANCHOR_COMP, _G.DW_NAV_ANCHOR_T = nil, nil, nil
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
    local pa, pb = project(nav, ctx, a), project(nav, ctx, b)
    if not pa then
        local loading = (anc.age_s or 0) < M.ANCHOR_SETTLE_S
        return { ok = false, reason = loading and "loading" or "start_off_navmesh", retry = loading }
    end
    -- An unprojectable goal (off the navmesh, or not streamed in yet) is still sent raw: Recast
    -- then returns a partial path toward it if it can.
    local path, err = U.try_err(function() return nav:FindPathToLocationSynchronously(ctx, pa, pb or b, nil, nil) end)
    if not U.valid(path) then return { ok = false, reason = "no_path", detail = err } end
    local pts = {}
    U.try(function()
        path.PathPoints:ForEach(function(_, e) pts[#pts + 1] = wire(e:get()) end)
    end)
    local partial = U.try(function() return path:IsPartial() end) == true
    local len = tonumber(U.try(function() return path:GetPathLength() end))
    local ok = #pts >= 2
    local res = {
        ok = ok, reason = (not ok) and ((anc.age_s or 0) < M.ANCHOR_SETTLE_S and "loading" or "no_path") or nil,
        retry = (not ok) and (anc.age_s or 0) < M.ANCHOR_SETTLE_S or nil,
        points = pts, n = #pts, partial = partial, goal_projected = pb ~= nil,
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
