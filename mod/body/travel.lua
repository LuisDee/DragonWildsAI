-- Lodestone travel, map regions and "where am I" (build 26161880; DISCOVERIES "Lodestones, map regions
-- and travel"). The bot travels like a player: teleport to a lodestone Luis can use, then walk.
--
-- Game data used (all read live 2026-10-25, travel_probe):
--   * Lodestones are WORLD objects, not per-player unlocks: AGameplayObjectRegistry.Lodestones
--     (TArray<FLodestoneData>{Location, RespawnLocation, Identifier}) lists every lodestone of the world
--     (replicated to every client for the map). RespawnLocation = Location + the lodestone's
--     TeleportLocationOffset (0,0,145 cm): the point a teleporting player arrives at.
--     Loaded lodestone actors (BP_WorldLodestone_C, AWorldActor.DisplayName "Lodestone") carry the same
--     GameplayObjectRegistryIdentifier. Most lodestones are player-built (wiki).
--   * "Unlocked by Luis" = the game's own rule on HIS controller's LodestoneTeleportationComponent:
--     CanTeleport(FromId, ToId) (BlueprintPure, scalar FGuid tables, verified safe). A lodestone counts
--     as unlocked when some OTHER registered lodestone can reach it. DW_TRAVEL_UNLOCK=registry treats
--     every registered lodestone as unlocked (debug / relaxed mirror).
--   * Regions: BP_MapRegion_C actors (persistent level, always loaded): RegionID, RegionName (FText),
--     PowerLevel, BoundarySpline (closed). region_at(pos) = point in the spline polygon, smallest wins.
--   * Teleport cost: CalculateTeleportationCost(distance_cm, weight) on Luis's component (verified:
--     8 km/0 -> 4, 8 km/400 -> 164; capped 999), paid in ITEM_Rune_Law. DW_TRAVEL_COST=free (default) |
--     budget (the bot's own law runes from body/inventory.lua; weight 0, UNVERIFIED units).
--   * The server streams World Partition cells only around players (2 LandscapeStreamingProxy tiles of
--     252 m were loaded live). A puppet teleported into an unloaded area would fall through the world
--     (and a fall death is the R1 unpossess crash path), so teleports only go to LOADED destinations
--     (a landscape tile with bounds covers the point, or a player is within STREAM_RADIUS_CM) and a
--     settle check rolls the teleport back if the puppet drops. Far teleports need a streaming source on
--     the puppet (UWorldPartitionStreamingSourceComponent): not built, needs an offline canary.
--
-- Teleport route: K2_TeleportTo(scalar FVector, scalar FRotator) on the PUPPET (the same call park/unpark
-- use). TeleportationSubsystem:TeleportWithParams was NOT used: it takes a delegate and drives the
-- loading screen / client RPCs of a real PlayerController, which the puppet does not have (R1 class).
--
-- Bridge handlers (registered beside body/skills.lua; its action slot, tick loop and probe guard):
--   travel {to: <lodestone id|name> | <region name> | [x,y,z] m, teleport?="auto"|"never"|"require"}
--     ASYNC. ok {to, kind, teleported, lodestone?, region?, position, saved_m?, cost?}
--     Fails: invalid_args, unknown_target (data.regions/lodestones), no_lodestone, not_unlocked,
--     too_far (detail destination_unloaded), path_blocked, timeout, verification_failed (teleport did
--     not land / fell and was rolled back), not_enough_resources (budget cost), companion_down.
--   where {position?: [x,y,z] m}   read-only: {position, region, region_id, parent_region, loaded,
--     nearest_lodestone {id, name, distance, unlocked_by_luis}}
--   lodestones {}                  read-only: {lodestones: [{id, name, region, position, arrival,
--     unlocked_by_luis, loaded}]}
-- UNVERIFIED in game: the puppet teleport itself (K2_TeleportTo on an AI-possessed player character),
-- what a client sees, the walk after it. Everything above marked "verified" was read live.
local U = require("body.util")
local jsonutil = require("jsonutil")
local null = jsonutil.null

local M = {}

M.REGISTRY_CLASS = "GameplayObjectRegistry"
M.LODESTONE_CLASS = "WorldLodestone"
M.REGION_CLASS = "MapRegion"
M.LANDSCAPE_CLASS = "LandscapeStreamingProxy"
M.COST_ITEM = "ITEM_Rune_Law"
M.SPLINE_WORLD = 1                -- ESplineCoordinateSpace::World
M.SPLINE_SUBSTEPS = 4             -- samples per spline segment (GetLocationAtSplineInputKey)

M.MIN_SAVING_CM = 15000           -- teleport only if it saves at least 150 m of walking
M.CROWD_CM = 150                  -- arrival point taken by a player: arrive this far beside it
M.ARRIVE_CM = 500                 -- teleport verified when the puppet is this close to the target
M.SETTLE_MS = 1000                -- then check it did not fall ...
M.FALL_CM = 500                   -- ... more than this below the arrival point
M.STREAM_RADIUS_CM = 10000        -- a player this close keeps the area loaded
M.LOADED_MARGIN_CM = 1000         -- a landscape tile must cover the point with this margin
M.CACHE_S = 5                     -- lodestone list / unlock cache
-- walking (same shape as skills.lua go_to)
M.ACCEPT_CM = 100
M.TOL_CM = 200
M.DZ_CM = 250
M.STUCK_MS = 4000
M.STUCK_MOVE_CM = 50
M.MAX_REISSUE = 3
M.TIMEOUT_MS = 280000             -- the brain waits 300 s
M.NAV_PROBE_CM = 150              -- after a lodestone-only teleport: one short MoveTo proves nav works

local REQ_FAILED = 0

local S = { log = nil, bridge = nil, skills = nil, puppet = nil, store = nil,
            regions = nil, tiles = {}, ls_cache = nil, ls_at = nil }

local function log(name, data) U.event(S.log, name, data) end
local function env(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then return default end
    return v
end
function M.unlock_mode() return env("DW_TRAVEL_UNLOCK", "luis") end
function M.cost_mode() return env("DW_TRAVEL_COST", "free") end

-- ------------------------------------------------------------------ reads (scalars only: R15)
local function vec(v)
    if v == nil then return nil end
    return U.try(function() return { X = v.X + 0, Y = v.Y + 0, Z = v.Z + 0 } end)
end

local function each(arr, fn)
    local out = {}
    if arr == nil then return out end
    U.try(function()
        arr:ForEach(function(_, e)
            local v = U.try(function() return fn(e:get()) end)
            if v ~= nil then out[#out + 1] = v end
        end)
    end)
    return out
end

function M.registry()
    local p = S.puppet and S.puppet.get and S.puppet.get()
    local r = p and U.try(function() return p.GameplayObjectRegistry end)
    if U.alive(r) then return r end
    for _, o in ipairs(U.find_all(M.REGISTRY_CLASS, { skip_defaults = true })) do return o end
    return nil
end

-- Luis's (the first connected player's) lodestone teleport component, read only.
function M.luis_teleport_component()
    local players = U.split_pawns()
    local pc = players[1] and U.controller_of(players[1])
    if not pc then return nil end
    local c = U.try(function() return pc.LodestoneTeleportationComponent end)
    if not U.valid(c) then c = U.try(function() return pc.BP_Components_LodestoneTeleportationComponent end) end
    return U.valid(c) and c or nil
end

-- ------------------------------------------------------------------ regions
local function polygon_area(poly)
    local a = 0
    for i = 1, #poly do
        local p, q = poly[i], poly[i % #poly + 1]
        a = a + p[1] * q[2] - q[1] * p[2]
    end
    return math.abs(a) / 2
end

function M.point_in_polygon(x, y, poly)
    local inside, j = false, #poly
    for i = 1, #poly do
        local xi, yi, xj, yj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
        if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
        j = i
    end
    return inside
end

local function spline_polygon(s)
    local n = tonumber(U.try(function() return s:GetNumberOfSplinePoints() end)) or 0
    local poly = {}
    for i = 0, n - 1 do
        for k = 0, M.SPLINE_SUBSTEPS - 1 do
            local key = i + k / M.SPLINE_SUBSTEPS
            local p = (k > 0) and U.try(function() return s:GetLocationAtSplineInputKey(key, M.SPLINE_WORLD) end)
                or U.try(function() return s:GetLocationAtSplinePoint(i, M.SPLINE_WORLD) end)
            p = vec(p)
            if p then poly[#poly + 1] = { p.X, p.Y } end
        end
    end
    return poly
end

-- Cached once per run: regions live in the persistent level and never move.
function M.regions(refresh)
    if S.regions and not refresh then return S.regions end
    local out = {}
    for _, r in ipairs(U.find_all(M.REGION_CLASS, { skip_defaults = true })) do
        local name = U.str(U.try(function() return r.RegionName end)) or U.str(U.try(function() return r:GetRegionName() end))
        local s = U.try(function() return r.BoundarySpline end)
        local poly = U.valid(s) and spline_polygon(s) or {}
        if name and name ~= "" and #poly >= 3 then
            local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
            local cx, cy = 0, 0
            for _, p in ipairs(poly) do
                minx, miny, maxx, maxy = math.min(minx, p[1]), math.min(miny, p[2]), math.max(maxx, p[1]), math.max(maxy, p[2])
                cx, cy = cx + p[1], cy + p[2]
            end
            out[#out + 1] = { name = name, region_id = tonumber(U.try(function() return r.RegionID end)),
                              power = tonumber(U.try(function() return r.PowerLevel end)), poly = poly,
                              bbox = { minx, miny, maxx, maxy }, area = polygon_area(poly),
                              center = { X = cx / #poly, Y = cy / #poly } }
        end
    end
    table.sort(out, function(a, b) return a.area < b.area end) -- smallest (most specific) first
    S.regions = out
    log("travel_regions_cached", { count = #out })
    return out
end

-- -> region, parent (both region records) or nil. Smallest containing polygon wins.
function M.region_at(pos)
    if not pos then return nil end
    local hit, parent
    for _, r in ipairs(M.regions()) do
        local b = r.bbox
        if pos.X >= b[1] and pos.X <= b[3] and pos.Y >= b[2] and pos.Y <= b[4]
            and M.point_in_polygon(pos.X, pos.Y, r.poly) then
            if not hit then hit = r elseif not parent then parent = r; break end
        end
    end
    return hit, parent
end

function M.find_region(name, exact)
    if type(name) ~= "string" or name == "" then return nil end
    local l = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
    for _, r in ipairs(M.regions()) do if r.name:lower() == l then return r end end
    for _, r in ipairs(M.regions()) do
        local n = r.name:lower()
        if n:gsub("^the ", "") == l:gsub("^the ", "") then return r end
    end
    if exact then return nil end
    local found
    for _, r in ipairs(M.regions()) do
        if r.name:lower():find(l, 1, true) then
            if found then return nil end -- ambiguous
            found = r
        end
    end
    return found
end

-- ------------------------------------------------------------------ loaded area
local function tile_bounds(t)
    local key = U.short(t)
    local b = key and S.tiles[key]
    if b then return b end
    local origin, ext = {}, {}
    U.try(function() t:GetActorBounds(false, origin, ext, false) end) -- out FVectors (verified live)
    if not (origin.X and ext.X) then return nil end
    b = { X = origin.X, Y = origin.Y, EX = ext.X, EY = ext.Y }
    if key then S.tiles[key] = b end
    return b
end

-- Is the ground at pos streamed in on the server? A landscape tile covers it, or a player is near.
function M.loaded_at(pos)
    if not pos then return false, "no_position" end
    for _, pl in ipairs(U.split_pawns()) do
        if U.dist2d(U.loc(pl), pos) <= M.STREAM_RADIUS_CM then return true, "player_near" end
    end
    local m = M.LOADED_MARGIN_CM
    for _, t in ipairs(U.find_all(M.LANDSCAPE_CLASS, { skip_defaults = true })) do
        local b = tile_bounds(t)
        if b and b.EX > m and b.EY > m and math.abs(pos.X - b.X) <= b.EX - m and math.abs(pos.Y - b.Y) <= b.EY - m then
            return true, "landscape"
        end
    end
    return false, "unloaded"
end

-- ------------------------------------------------------------------ lodestones
local function raw_lodestones()
    local reg = M.registry()
    if not reg then return {} end
    return each(U.try(function() return reg.Lodestones end), function(e)
        local g = U.guid_copy(e.Identifier)
        local loc, arr = vec(e.Location), vec(e.RespawnLocation)
        if not (g and loc) then return nil end
        return { id = U.guid_hex(g), guid = g, location = loc, arrival = arr or loc }
    end)
end

local function loaded_actors()
    local by_id = {}
    for _, a in ipairs(U.find_all(M.LODESTONE_CLASS, { skip_defaults = true })) do
        local id = U.guid_hex(U.try(function() return a.GameplayObjectRegistryIdentifier end))
        if id then by_id[id] = a end
    end
    return by_id
end

-- unlocked[id] = true when the game lets Luis teleport there from some other registered lodestone.
local function unlocks(list)
    local out = {}
    if M.unlock_mode() == "registry" then
        for _, l in ipairs(list) do out[l.id] = true end
        return out
    end
    local tc = M.luis_teleport_component()
    if not tc then return out end
    for _, to in ipairs(list) do
        for _, from in ipairs(list) do
            if from.id ~= to.id then
                local f, t = from.guid, to.guid
                -- scalar-only FGuid tables (R15): verified safe live (travel_probe "can")
                local ok = U.try(function()
                    return tc:CanTeleport({ A = f.A, B = f.B, C = f.C, D = f.D }, { A = t.A, B = t.B, C = t.C, D = t.D })
                end)
                if ok == true then out[to.id] = true; break end
            end
        end
    end
    return out
end

-- The full list: {id, name, region, region_id, position, arrival (wire m), unlocked_by_luis, loaded,
-- _loc/_arrival/_guid (cm, internal; stripped by the handlers)}.
function M.list(refresh)
    local now = os.time()
    if not refresh and S.ls_cache and S.ls_at and now - S.ls_at < M.CACHE_S then return S.ls_cache end
    local list = raw_lodestones()
    local actors = loaded_actors()
    local un = unlocks(list)
    local per_region = {}
    for _, l in ipairs(list) do
        local r = M.region_at(l.location)
        local a = actors[l.id]
        local display = a and U.str(U.try(function() return a.DisplayName end)) or nil
        if not display or display == "" then display = "Lodestone" end
        local base = (r and (r.name .. " ") or "") .. display
        per_region[base] = (per_region[base] or 0) + 1
        l.name = per_region[base] > 1 and (base .. " " .. per_region[base]) or base
        l.region, l.region_id = r and r.name or nil, r and r.region_id or nil
        l.unlocked_by_luis = un[l.id] == true
        l.loaded = a ~= nil
    end
    S.ls_cache, S.ls_at = list, now
    return list
end

local function wire_lodestone(l, here)
    return { id = l.id, name = l.name, region = l.region or null, region_id = l.region_id,
             position = U.to_wire(l.location), arrival = U.to_wire(l.arrival),
             unlocked_by_luis = l.unlocked_by_luis, loaded = l.loaded,
             distance = here and U.cm_to_m(U.dist(here, l.arrival)) or nil }
end

-- {id, name, region, position, unlocked_by_luis, ...} for the brain (wire units).
function M.lodestones()
    local out = {}
    for _, l in ipairs(M.list()) do out[#out + 1] = wire_lodestone(l) end
    return out
end

-- by id (hex, case-insensitive), exact name, or (unless exact) a unique name substring.
function M.find_lodestone(key, exact)
    if type(key) ~= "string" or key == "" then return nil end
    local k = key:lower()
    local list = M.list()
    for _, l in ipairs(list) do if l.id:lower() == k or l.name:lower() == k then return l end end
    if exact then return nil end
    local found
    for _, l in ipairs(list) do
        if l.name:lower():find(k, 1, true) then
            if found then return nil end
            found = l
        end
    end
    return found
end

function M.is_lodestone_key(key)
    return type(key) == "string" and (key:match("^%x+$") ~= nil and #key == 32 or key:lower():find("lodestone", 1, true) ~= nil)
end

-- ------------------------------------------------------------------ where
-- opts.position: wire [x,y,z] (m); else the puppet's position, else Luis's.
function M.where(args, opts)
    args = args or {}
    local pos = args.position and U.from_wire(args.position)
    if args.position ~= nil and not pos then return U.fail("invalid_args", { detail = "position must be [x,y,z] metres" }) end
    if not pos then
        local p = S.puppet and S.puppet.get and S.puppet.get()
        pos = p and U.loc(p) or U.loc(U.split_pawns()[1])
    end
    if not pos then return U.fail("companion_down", { detail = "no position to describe" }) end
    local r, parent = M.region_at(pos)
    local best, best_d
    for _, l in ipairs(M.list()) do
        local d = U.dist(pos, l.location)
        if not best_d or d < best_d then best, best_d = l, d end
    end
    local loaded = M.loaded_at(pos)
    return U.ok({
        position = U.to_wire(pos), region = r and r.name or null, region_id = r and r.region_id or null,
        parent_region = parent and parent.name or null, power_level = r and r.power or null, loaded = loaded,
        nearest_lodestone = best and { id = best.id, name = best.name, distance = U.cm_to_m(best_d),
                                       unlocked_by_luis = best.unlocked_by_luis } or null,
    })
end

-- ------------------------------------------------------------------ teleport (the puppet only)
local function arrival_point(l)
    local at = { X = l.arrival.X, Y = l.arrival.Y, Z = l.arrival.Z }
    for _, pl in ipairs(U.split_pawns()) do
        if U.dist2d(U.loc(pl), at) < M.CROWD_CM then
            at.X = at.X + M.CROWD_CM -- a player stands on the pad: arrive beside them
            break
        end
    end
    return at
end

local function cost_of(here, l)
    if M.cost_mode() ~= "budget" then return 0 end
    local d = U.dist(here, l.arrival)
    local tc = M.luis_teleport_component()
    local n = tc and tonumber(U.try(function() return tc:CalculateTeleportationCost(d, 0) end))
    return math.max(1, math.floor(n or 1))
end

-- Raw move of the puppet: StopMovement, K2_TeleportTo, verify the new location. -> ok, here_after, err
local function teleport_puppet(p, at)
    local c = U.controller_of(p)
    if c then U.call(S.log, "travel.StopMovement", {}, function() c:StopMovement() end) end
    local yaw = tonumber(U.try(function() return p:K2_GetActorRotation().Yaw end)) or 0
    local ok, res = U.call(S.log, "travel.K2_TeleportTo", { to = U.to_wire(at) }, function()
        return p:K2_TeleportTo({ X = at.X, Y = at.Y, Z = at.Z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
    end)
    U.try(function() p:ForceNetUpdate() end)
    local after = U.loc(p)
    if not ok then return false, after, tostring(res) end
    if res == false then return false, after, "K2_TeleportTo returned false" end
    if U.dist(after, at) > M.ARRIVE_CM then return false, after, "not at target after teleport" end
    return true, after
end

-- Checks before a teleport. -> lodestone record, arrival point or nil, reason, data.
function M.prepare(id_or_l, opts)
    opts = opts or {}
    local l = type(id_or_l) == "table" and id_or_l or M.find_lodestone(id_or_l)
    if not l then return nil, "no_lodestone", { lodestone = id_or_l, known = #M.list() } end
    if not l.unlocked_by_luis and not opts.allow_locked then
        return nil, "not_unlocked", { lodestone = l.id, name = l.name, detail = "Luis cannot teleport there yet" }
    end
    local at = arrival_point(l)
    local loaded, why = M.loaded_at(at)
    if not loaded then
        return nil, "too_far", { lodestone = l.id, name = l.name, detail = "destination_unloaded", why = why }
    end
    return l, at
end

-- Teleport the PUPPET to a lodestone's arrival point (sync). opts: {allow_locked (debug only, the
-- brain never sends it), settle_check = true: re-check after SETTLE_MS (rollback on a fall) and probe nav}.
-- -> {ok, reason, data}
function M.teleport_to_lodestone(id, opts)
    opts = opts or {}
    if opts.log then S.log = opts.log end
    local l, at, data = M.prepare(id, opts)
    if not l then return U.fail(at, data) end
    local p = S.puppet and S.puppet.get and S.puppet.get()
    if not p then
        local pp, err = S.puppet and S.puppet.ensure_ready and S.puppet.ensure_ready()
        if not pp then return U.fail("companion_down", { detail = err }) end
        p = pp
    end
    local before = U.loc(p)
    local cost = cost_of(before, l)
    if cost > 0 then
        if not (S.store and S.store.count and S.store.count(M.COST_ITEM) >= cost) then
            return U.fail("not_enough_resources", { item = M.COST_ITEM, need = cost,
                          have = S.store and S.store.count and S.store.count(M.COST_ITEM) or 0 })
        end
    end
    local ok, after, err = teleport_puppet(p, at)
    if not ok then
        log("travel_teleport_failed", { lodestone = l.id, err = err, at = U.to_wire(after) })
        return U.fail("verification_failed", { lodestone = l.id, detail = err, position = U.to_wire(after) })
    end
    if cost > 0 then S.store.take(M.COST_ITEM, cost) end
    log("travel_teleported", { lodestone = l.id, name = l.name, from = U.to_wire(before), to = U.to_wire(after) })
    if opts.settle_check ~= false then M.settle_later(p, at, before) end
    return U.ok({ lodestone = l.id, name = l.name, region = l.region or null, position = U.to_wire(after),
                  from = U.to_wire(before), cost = cost, moved_m = U.cm_to_m(U.dist(before, after)) })
end

-- After a teleport: is the puppet still standing at the arrival? (fell through unloaded ground -> back)
-- -> "ok" | "fell"
function M.settle(p, at, before)
    local here = U.loc(p)
    if not here or here.Z < at.Z - M.FALL_CM then
        log("travel_fell", { at = U.to_wire(at), here = U.to_wire(here) })
        if before then teleport_puppet(p, before) end
        return "fell"
    end
    return "ok"
end

-- Nav check: one short MoveTo from the arrival point (proves the path following works after a teleport).
function M.nav_probe(p, at)
    local c = U.controller_of(p)
    if not (c and S.skills and S.skills._move_to_location) then return nil end
    local r = S.skills._move_to_location(c, { X = at.X + M.NAV_PROBE_CM, Y = at.Y, Z = at.Z }, M.ACCEPT_CM)
    return r ~= REQ_FAILED
end

function M.settle_later(p, at, before)
    local function check()
        local s = M.settle(p, at, before)
        local nav = s == "ok" and M.nav_probe(p, at) or nil
        log("travel_settle", { result = s, nav_ok = nav, here = U.to_wire(U.loc(p)) })
    end
    if type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(M.SETTLE_MS, function() pcall(check) end)
    else
        pcall(check)
    end
end

-- ------------------------------------------------------------------ travel (async action)
local function now() return S.skills.now() end
local function finish(a, ok, reason, data) return S.skills._finish(a, ok, reason, data) end

local function arrived(a, here)
    if not here then return false end
    if a.region then return M.point_in_polygon(here.X, here.Y, a.region.poly) end
    if not a.dest then return false end
    return U.dist2d(here, a.dest) <= M.TOL_CM and math.abs(here.Z - a.dest.Z) <= M.DZ_CM
end

local function result_data(a, here)
    local r = M.region_at(here)
    return { to = a.to, kind = a.kind_of, teleported = a.teleported == true,
             lodestone = a.lodestone and a.lodestone.id or null, lodestone_name = a.lodestone and a.lodestone.name or null,
             region = r and r.name or null, position = U.to_wire(here), saved_m = a.saved_cm and U.cm_to_m(a.saved_cm) or null,
             cost = a.cost or 0 }
end

local function walk_target(a)
    if a.dest then return a.dest end
    local c = a.region.center
    return { X = c.X, Y = c.Y, Z = (U.loc(S.puppet.get()) or { Z = 0 }).Z }
end

local function issue_walk(a, p)
    local c = U.controller_of(p)
    if not c then return REQ_FAILED end
    return S.skills._move_to_location(c, walk_target(a), M.ACCEPT_CM)
end

local function step_travel(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local here = U.loc(p)
    if now() - a.started >= M.TIMEOUT_MS then return finish(a, false, "timeout", result_data(a, here)) end
    if a.phase == "settle" then
        if now() - a.teleported_at < M.SETTLE_MS then return end
        if M.settle(p, a.arrival, a.before) == "fell" then
            return finish(a, false, "verification_failed", { detail = "fell after teleport; rolled back", lodestone = a.lodestone.id })
        end
        if a.lodestone_only or arrived(a, U.loc(p)) then
            a.nav_ok = M.nav_probe(p, a.arrival)
            local d = result_data(a, U.loc(p))
            d.nav_ok = a.nav_ok
            return finish(a, true, nil, d)
        end
        a.phase = "walk"
        a.last_pos, a.last_progress, a.reissues = nil, now(), 0
        if issue_walk(a, p) == REQ_FAILED then
            return finish(a, false, "path_blocked", result_data(a, U.loc(p)))
        end
        return
    end
    -- walk
    if arrived(a, here) then return finish(a, true, nil, result_data(a, here)) end
    if not a.last_pos or U.dist(here, a.last_pos) > M.STUCK_MOVE_CM then
        a.last_pos, a.last_progress = here, now()
    elseif now() - a.last_progress >= M.STUCK_MS then
        if a.reissues >= M.MAX_REISSUE then
            local d = result_data(a, here)
            d.reissues = a.reissues
            return finish(a, false, "path_blocked", d)
        end
        a.reissues = a.reissues + 1
        a.last_progress = now()
        issue_walk(a, p)
    end
end

-- Resolve `to`. -> {kind_of="lodestone"|"region"|"coords", lodestone?, region?, dest?} or nil, reason, data
function M.resolve(to)
    local dest = U.from_wire(to)
    if dest then return { kind_of = "coords", dest = dest } end
    if type(to) ~= "string" or to == "" then return nil, "invalid_args", { detail = "to must be a lodestone, a region or [x,y,z]" } end
    -- exact lodestone, exact region, then partial matches ("Temple Woods" is the region, not its lodestone)
    local l = M.find_lodestone(to, true)
    if l then return { kind_of = "lodestone", lodestone = l, dest = l.arrival } end
    local r = M.find_region(to, true)
    if r then return { kind_of = "region", region = r } end
    l = M.find_lodestone(to)
    if l then return { kind_of = "lodestone", lodestone = l, dest = l.arrival } end
    r = M.find_region(to)
    if r then return { kind_of = "region", region = r } end
    if M.is_lodestone_key(to) then return nil, "no_lodestone", { lodestone = to, known = #M.list() } end
    local regions = {}
    for _, x in ipairs(M.regions()) do regions[#regions + 1] = x.name end
    table.sort(regions)
    local ls = {}
    for _, x in ipairs(M.list()) do ls[#ls + 1] = x.name end
    return nil, "unknown_target", { target = to, regions = regions, lodestones = ls }
end

-- Best unlocked, loaded lodestone for reaching the target from `here`. -> l, at, saved_cm
function M.choose(target, here)
    local best, best_at, best_saving
    for _, l in ipairs(M.list()) do
        if l.unlocked_by_luis then
            local inside = target.region and M.point_in_polygon(l.arrival.X, l.arrival.Y, target.region.poly)
            local goal = target.dest or (target.region and { X = target.region.center.X, Y = target.region.center.Y, Z = l.arrival.Z })
            local direct = target.region and M.point_in_polygon(here.X, here.Y, target.region.poly) and 0 or U.dist2d(here, goal)
            local via = inside and 0 or U.dist2d(l.arrival, goal)
            local saving = direct - via
            if saving >= M.MIN_SAVING_CM and (not best_saving or saving > best_saving) then
                local _, at = M.prepare(l)
                if at then best, best_at, best_saving = l, at, saving end
            end
        end
    end
    return best, best_at, best_saving
end

local function h_travel(args, ctx)
    if args.to == nil then return U.fail("invalid_args", { detail = "to is required" }) end
    local mode = args.teleport or "auto"
    if mode ~= "auto" and mode ~= "never" and mode ~= "require" then
        return U.fail("invalid_args", { detail = "teleport must be auto, never or require" })
    end
    local target, reason, data = M.resolve(args.to)
    if not target then return U.fail(reason, data) end
    local p, err = S.puppet.ensure_ready()
    if not p then return U.fail("companion_down", { detail = err }) end
    local here = U.loc(p)
    local a = { kind = "travel", id = ctx.id, async = true, to = args.to, kind_of = target.kind_of,
                dest = target.dest, region = target.region, phase = "walk", reissues = 0, step = step_travel }
    local l, at
    if target.kind_of == "lodestone" then
        if mode == "never" then return U.fail("invalid_args", { detail = "a lodestone target needs a teleport" }) end
        l, at, data = M.prepare(target.lodestone)
        if not l then return U.fail(at, data) end
        a.lodestone_only = true
        a.saved_cm = U.dist(here, l.arrival)
    elseif target.region and M.point_in_polygon(here.X, here.Y, target.region.poly) then
        local d = result_data(a, here)
        d.already_there = true
        return U.ok(d)
    elseif mode ~= "never" then
        l, at, a.saved_cm = M.choose(target, here)
        if not l and mode == "require" then
            return U.fail("no_lodestone", { detail = "no unlocked, loaded lodestone saves at least "
                                           .. U.cm_to_m(M.MIN_SAVING_CM) .. " m" })
        end
    end
    if a.lodestone_only and U.dist(here, at) <= M.ARRIVE_CM then
        local d = result_data(a, here)
        d.already_there, d.lodestone, d.lodestone_name = true, l.id, l.name
        return U.ok(d)
    end
    local cost = l and cost_of(here, l) or 0
    if cost > 0 and not (S.store and S.store.count and S.store.count(M.COST_ITEM) >= cost) then
        return U.fail("not_enough_resources", { item = M.COST_ITEM, need = cost,
                      have = S.store and S.store.count and S.store.count(M.COST_ITEM) or 0 })
    end
    -- From here on the action owns the slot (pre-empts follow etc.); failures reply through finish().
    S.skills._start(a)
    if l then
        local ok, after, terr = teleport_puppet(p, at)
        a.lodestone = l
        if not ok then
            log("travel_teleport_failed", { lodestone = l.id, err = terr, at = U.to_wire(after) })
            finish(a, false, "verification_failed", { lodestone = l.id, detail = terr, position = U.to_wire(after) })
            return nil
        end
        if cost > 0 then S.store.take(M.COST_ITEM, cost) end
        a.cost, a.arrival, a.before = cost, at, here
        a.teleported, a.teleported_at, a.phase = true, now(), "settle"
        log("travel_teleported", { lodestone = l.id, name = l.name, from = U.to_wire(here), to = U.to_wire(after) })
        return nil -- async: step_travel settles, walks on and replies
    end
    a.last_progress = now()
    if issue_walk(a, p) == REQ_FAILED then
        finish(a, false, "path_blocked", { detail = "MoveTo request failed", position = U.to_wire(here) })
    end
    return nil -- async: step_travel replies
end

local function h_where(args) return M.where(args) end
local function h_lodestones()
    local p = S.puppet.get and S.puppet.get()
    local here = p and U.loc(p)
    local out = {}
    for _, l in ipairs(M.list(true)) do out[#out + 1] = wire_lodestone(l, here) end
    return U.ok({ lodestones = out, unlock_mode = M.unlock_mode(), cost_mode = M.cost_mode() })
end

M.HANDLERS = { travel = h_travel, where = h_where, lodestones = h_lodestones }

-- opts: {skills = body.skills (registered already), puppet = body.puppet, store = body.inventory (budget)}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod
    S.skills = opts.skills or require("body.skills")
    S.puppet = opts.puppet or require("body.puppet")
    S.store = opts.store
    for name, fn in pairs(M.HANDLERS) do bridge.handlers[name] = S.skills._probe_guard(name, fn) end
    log("travel_registered", { tools = { "travel", "where", "lodestones" }, unlock = M.unlock_mode(), cost = M.cost_mode() })
    return M
end

-- For experiments (debug_run travel_probe): wire the services without registering handlers.
function M.configure(opts)
    opts = opts or {}
    S.log = opts.log or S.log
    S.skills = opts.skills or S.skills
    S.puppet = opts.puppet or S.puppet
    S.store = opts.store or S.store
    return M
end

function M._reset()
    S.log, S.bridge, S.skills, S.puppet, S.store = nil, nil, nil, nil, nil
    S.regions, S.tiles, S.ls_cache, S.ls_at = nil, {}, nil, nil
end

return M
