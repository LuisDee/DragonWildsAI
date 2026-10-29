-- Focused, deterministic fake-native regression. No game calls.
local here = assert(debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$"))
local U = {}
local world = { name = "World Dev", live = true }
local ctx = { name = "GameState Dev", live = true }
local nav = { name = "NavigationSystem CDO", live = true }
function ctx:GetWorld() return world end
local meshes = {}
for i = 1, 6 do
    meshes[i] = { name = "Recast " .. i, live = true, AgentRadius = i * 30, AgentHeight = 150 }
    meshes[i].GetWorld = function() return world end
end
function U.try(f) local ok, v = pcall(f); if ok then return v end end
function U.alive(o) return type(o) == "table" and o.live == true end
function U.fullname(o) return o.name end
function U.find_all(cls)
    if cls == "GameStateBase" then return {ctx} end
    if cls == "RecastNavMesh" then return meshes end
    return {}
end
package.loaded["body.util"] = U
function StaticFindObject() return nav end
local calls, mode, point_reads = {}, "ok", 0
function nav:K2_ProjectPointToNavigation(c, p, out, data, filter, ext)
    calls[#calls + 1] = { kind = "project", ctx = c, data = data, ext = ext.Z }
    if mode == "invalidate" then world.live = false end
    if mode == "projection_false" then return false end
    if mode == "projection_unknown" then return nil end
    out.X, out.Y, out.Z = p.X + 10, p.Y, p.Z - 10
    return true
end
function nav:FindPathToLocationSynchronously(c, a, b, data)
    calls[#calls + 1] = { kind = "path", ctx = c, data = data, a = a, b = b }
    if mode == "missing_path" then return nil end
    local p = { live = true }
    function p:IsValid() error("must not interpret object validity as path validity") end
    function p:IsPartial() if mode == "unknown_partial" then return nil end; return mode == "partial" end
    function p:GetPathLength() return 100 end
    local count = mode == "many_points" and 200 or (mode == "no_points" and 0 or 2)
    p.PathPoints = setmetatable({ GetArrayNum = function() return count end }, {__index = function(_, i)
        point_reads = point_reads + 1
        if mode == "point_nav_invalid" then nav.live = false end
        if mode == "point_ctx_invalid" then ctx.live = false end
        if mode == "point_data_invalid" then data.live = false end
        if mode == "point_path_invalid" then p.live = false end
        return {X=i, Y=2, Z=3}
    end})
    return p
end
local M = dofile(here .. "/../experiments/nav_route_probe.lua")
local function run(context, expected_identity)
    calls, point_reads = {}, 0
    return M.run(nil, { from = {0, 2, 3}, to = {1, 2, 3}, context = context, expected_identity = expected_identity })
end
local r = run(0)
assert(r.ok and r.partial == false and r.path_object_valid == true and r.path_validity_known == false and #r.points == 2)
assert(#calls == 3 and calls[1].data == nil and calls[2].data == nil and calls[3].data == nil)
assert(calls[1].ctx == ctx and calls[3].ctx == ctx and calls[1].ext == 150)
assert(r.projected_start[1] == 0.1 and r.projected_goal[1] == 1.1 and calls[3].a.X == 10 and calls[3].b.X == 110)
assert(#r.contexts == 4 and r.contexts_truncated and r.nav_data == nil)
r = run(2, meshes[2].name)
assert(r.ok and r.nav_data.identity == meshes[2].name and r.nav_data.radius_cm == 60)
assert(calls[1].data == meshes[2] and calls[2].data == meshes[2] and calls[3].data == meshes[2])
r = run(2, meshes[1].name); assert(r.reason == "context_identity_mismatch" and #calls == 0)
for _, value in ipairs({0/0, math.huge, -math.huge, 1e308}) do
    calls = {}; r = M.run(nil, {from = {value,0,0}, to = {1,0,0}})
    assert(not r.ok and r.reason == "invalid_args" and #calls == 0)
    r = run(value); assert(not r.ok and r.reason == "invalid_args" and #calls == 0)
end
for _, value in ipairs({"point_nav_invalid", "point_ctx_invalid", "point_data_invalid", "point_path_invalid"}) do
    mode = value; r = run(2, meshes[2].name)
    assert(not r.ok and r.reason == "invalidated" and point_reads == 1)
    nav.live, ctx.live, meshes[2].live = true, true, true
end
mode = "ok"
meshes = {}; r = run(1)
assert(r.reason == "context_unavailable" and #calls == 0 and #r.contexts == 0)
r = run(0); assert(r.ok and #r.contexts == 0) -- default may work without an enumerable explicit mesh
mode = "partial"; r = run(0); assert(r.ok and r.partial == true)
mode = "unknown_partial"; r = run(0); assert(not r.ok and r.reason == "path_flags_unknown" and r.partial == nil)
mode = "no_points"; r = run(0); assert(not r.ok and r.reason == "no_path" and r.path_object_valid == true and r.path_validity_known == false)
mode = "missing_path"; r = run(0); assert(not r.ok and r.reason == "path_unavailable")
mode = "projection_false"; r = run(0); assert(not r.ok and r.start_projection == "off_navmesh" and #calls == 2)
mode = "projection_unknown"; r = run(0); assert(not r.ok and r.start_projection == "unknown" and #calls == 2)
mode = "many_points"; r = run(0); assert(r.ok and #r.points == 128 and point_reads == 128 and r.points_truncated)
mode = "invalidate"; r = run(0); assert(not r.ok and r.reason == "invalidated" and #calls == 1)
world.live = true; mode = "ok"; ctx.live = false; r = run(0)
assert(not r.ok and r.reason == "world_unavailable" and #calls == 0)
print("nav_route_probe: focused checks passed")
