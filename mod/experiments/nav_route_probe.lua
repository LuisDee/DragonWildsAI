-- Read-only, synchronous DEV diagnostic. One context per invocation: call once with
-- context=0 (default), then once per returned explicit context on separate frames,
-- passing expected_identity from that enumeration to reject reordered objects.
-- No streaming sources, movement or navigation state is modified. Metres on the wire.
local U = require("body.util")
local M = {}
local MAX_CONTEXTS, MAX_POINTS = 4, 128
local EXTENT = { X = 150, Y = 150, Z = 150 }

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local function vector(a)
    if type(a) ~= "table" then return nil end
    local x, y, z = a[1], a[2], a[3]
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    x, y, z = x * 100, y * 100, z * 100
    if not (finite(x) and finite(y) and finite(z)) then return nil end
    return { X = x, Y = y, Z = z }
end
local function wire(v) return { v.X / 100, v.Y / 100, v.Z / 100 } end
local function alive(o) return U.alive(o) end
local function identity(o)
    if not alive(o) then return nil end
    return U.fullname(o)
end
local function get_world(o)
    if not alive(o) then return nil end
    local w = U.try(function() return o:GetWorld() end)
    if alive(w) and identity(w) then return w end
end
local function ready(nav, ctx, world_id, data)
    if not (alive(nav) and alive(ctx)) then return false end
    local w = get_world(ctx)
    if not w or identity(w) ~= world_id then return false end
    if data then
        if not alive(data) then return false end
        local dw = get_world(data)
        if not dw or identity(dw) ~= world_id then return false end
    end
    return true
end
local function read_bool(f)
    local ok, value = pcall(f)
    if ok and type(value) == "boolean" then return value end
    return nil
end
local function project(nav, ctx, world_id, data, p)
    if not ready(nav, ctx, world_id, data) then return nil, "invalidated" end
    local out = { X = p.X, Y = p.Y, Z = p.Z }
    local ok, hit = pcall(function() return nav:K2_ProjectPointToNavigation(ctx, p, out, data, nil, EXTENT) end)
    if not ready(nav, ctx, world_id, data) then return nil, "invalidated" end
    if not ok or type(hit) ~= "boolean" then return nil, "unknown" end
    if not hit then return nil, "off_navmesh" end
    if not (finite(out.X) and finite(out.Y) and finite(out.Z)) then return nil, "unknown" end
    return out, "projected"
end

function M.run(_, args)
    args = type(args) == "table" and args or {}
    local a, b = vector(args.from), vector(args.to)
    local selected = args.context == nil and 0 or args.context
    if not a or not b or not finite(selected) or selected ~= math.floor(selected) or selected < 0 or selected > MAX_CONTEXTS then
        return { ok = false, reason = "invalid_args" }
    end
    local nav = U.try(function() return StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1") end)
    local ctx
    for _, cls in ipairs({ "GameStateBase", "WorldSettings" }) do
        for _, candidate in ipairs(U.find_all(cls, { skip_defaults = true })) do
            if alive(candidate) and get_world(candidate) then ctx = candidate; break end
        end
        if ctx then break end
    end
    local w = ctx and get_world(ctx)
    local world_id = w and identity(w)
    if not (world_id and ready(nav, ctx, world_id)) then return { ok = false, reason = "world_unavailable" } end
    local available, descriptors, overflow = {}, {}, false
    for _, n in ipairs(U.find_all("RecastNavMesh", { skip_defaults = true })) do
        if ready(nav, ctx, world_id, n) then
            if #available >= MAX_CONTEXTS then overflow = true; break end
            available[#available + 1] = n
            local radius = U.try(function() return n.AgentRadius end)
            local height = U.try(function() return n.AgentHeight end)
            descriptors[#descriptors + 1] = { index = #available, identity = identity(n),
                radius_cm = finite(radius) and radius or nil, height_cm = finite(height) and height or nil }
        end
    end
    local data = selected > 0 and available[selected] or nil
    local result = { ok = false, context = selected, contexts = descriptors, contexts_truncated = overflow,
        from = wire(a), to = wire(b), projection_extent_cm = {150, 150, 150}, world = world_id }
    if selected > 0 and not data then result.reason = "context_unavailable"; return result end
    if data and (type(args.expected_identity) ~= "string" or args.expected_identity ~= descriptors[selected].identity) then
        result.reason = "context_identity_mismatch"; return result
    end
    result.nav_data = data and descriptors[selected] or nil -- nil means default, identity unknown
    local pa, sa = project(nav, ctx, world_id, data, a)
    result.start_projection = sa
    if sa == "invalidated" then result.reason = sa; return result end
    local pb, sb = project(nav, ctx, world_id, data, b)
    result.goal_projection = sb
    if sb == "invalidated" then result.reason = sb; return result end
    result.projected_start, result.projected_goal = pa and wire(pa) or nil, pb and wire(pb) or nil
    if not pa or not pb then result.reason = "projection_failed"; return result end
    if not ready(nav, ctx, world_id, data) then result.reason = "invalidated"; return result end
    local ok, path = pcall(function() return nav:FindPathToLocationSynchronously(ctx, pa, pb, data, nil) end)
    if not ready(nav, ctx, world_id, data) then result.reason = "invalidated"; return result end
    if not ok then result.reason = "path_query_error"; return result end
    if not alive(path) then result.reason = "path_unavailable"; return result end
    -- UE4SS RemoteObject:IsValid checks the wrapper, not verified navigation-path validity.
    result.path_object_valid, result.path_validity_known = true, false
    result.partial = read_bool(function() return path:IsPartial() end)
    if not ready(nav, ctx, world_id, data) or not alive(path) then result.reason = "invalidated"; return result end
    local length = U.try(function() return path:GetPathLength() end)
    if finite(length) and length >= 0 then result.length_m = length / 100 end
    if not ready(nav, ctx, world_id, data) or not alive(path) then result.reason = "invalidated"; return result end
    local points = {}
    local array = U.try(function() return path.PathPoints end)
    local count = array and U.try(function() return array:GetArrayNum() end)
    if not finite(count) or count < 0 or count ~= math.floor(count) then result.reason = "invalid_path_payload"; return result end
    for i = 1, math.min(count, MAX_POINTS) do
        if not ready(nav, ctx, world_id, data) or not alive(path) then result.reason = "invalidated"; return result end
        local v = U.try(function() return array[i] end)
        local xyz = v and U.try(function() return { X = v.X, Y = v.Y, Z = v.Z } end)
        if not xyz or not (finite(xyz.X) and finite(xyz.Y) and finite(xyz.Z)) then result.reason = "invalid_path_payload"; return result end
        points[#points + 1] = wire(xyz)
    end
    if not ready(nav, ctx, world_id, data) or not alive(path) then result.reason = "invalidated"; return result end
    result.points, result.points_truncated = points, count > MAX_POINTS
    if #points < 2 then result.reason = "no_path"; return result end
    if result.partial == nil then result.reason = "path_flags_unknown"; return result end
    result.ok = true
    return result
end

return M
