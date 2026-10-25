-- The dev server navmesh's automatic nav-link generation (UE 5.5+ experimental bGenerateNavLinks +
-- NavLinkJumpDownConfig). Links are built during TILE generation, but the base navmesh comes from
-- cooked NavigationDataChunkActor tiles, so local tiles must be rebuilt to get links.
--   debug_run {"module":"navlink_probe"}                        READ-ONLY settings
--   debug_run {"module":"navlink_probe","fn":"dirty","args":{"at":[x,y,z],"size_m":40}}
--       DEV SERVER ONLY write: spawns a flat movable cube 30 m ABOVE `at` (it obstructs nothing on the
--       ground) so the navigation octree dirties the tile columns under it, which Dynamic runtime
--       generation then rebuilds (now with links); destroys it after 3 s (dirties again).
--   debug_run {"module":"navlink_probe","fn":"building"}        IsNavigationBeingBuilt
local U = require("body.util")
local M = {}
function M.run(log, args)
    local out = {}
    for _, r in ipairs(U.find_all("RecastNavMesh", { skip_defaults = true })) do
        local c = {}
        local cfg = U.try(function() return r.NavLinkJumpDownConfig end)
        for _, f in ipairs({ "bEnabled", "JumpLength", "JumpDistanceFromEdge", "JumpMaxDepth", "JumpHeight", "JumpEndsHeightTolerance", "SamplingSeparationFactor", "FilterDistanceThreshold", "LinkBuilderFlags" }) do
            c[f] = U.try(function() return cfg[f] end)
        end
        c.down_area = U.fullname(U.try(function() return cfg.DownDirectionAreaClass end))
        c.up_area = U.fullname(U.try(function() return cfg.UpDirectionAreaClass end))
        out[U.short(r)] = {
            bGenerateNavLinks = U.try(function() return r.bGenerateNavLinks end),
            bForceRebuildOnLoad = U.try(function() return r.bForceRebuildOnLoad end),
            runtime = U.try(function() return r.RuntimeGeneration end),
            jump_down = c,
        }
    end
    return out
end
local function ctx()
    for _, a in ipairs(U.find_all("GameStateBase", { skip_defaults = true })) do return a end
end

function M.building(log, args)
    local nav = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    return { building = U.try(function() return nav:IsNavigationBeingBuilt(ctx()) end),
             locked = U.try(function() return nav:IsNavigationBeingBuiltOrLocked(ctx()) end) }
end

function M.dirty(log, args)
    local at = args.at
    local size = (args.size_m or 40) / 1   -- the cube is 1 m: scale = metres
    local world = U.try(function() return ctx():GetWorld() end)
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local mesh = StaticFindObject("/Engine/BasicShapes/Cube.Cube")
    if not (world and cls and mesh) then return { ok = false, reason = "missing", mesh = mesh ~= nil, cls = cls ~= nil } end
    local loc = { X = at[1] * 100, Y = at[2] * 100, Z = at[3] * 100 + 3000 }
    local ok, a = U.call(log, "navlink_probe.SpawnActor_cube", { at = at }, function()
        return world:SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not (ok and U.valid(a)) then return { ok = false, reason = "spawn", detail = tostring(a) } end
    local comp = a.StaticMeshComponent
    local r = {}
    r.mob = select(1, U.call(log, "navlink_probe.SetMobility", nil, function() comp:SetMobility(2) end))
    r.mesh = select(1, U.call(log, "navlink_probe.SetStaticMesh", nil, function() return comp:SetStaticMesh(mesh) end))
    r.scale = select(1, U.call(log, "navlink_probe.SetActorScale3D", nil, function() a:SetActorScale3D({ X = size, Y = size, Z = 0.2 }) end))
    r.affects = U.try(function() return comp.bCanEverAffectNavigation end)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function() pcall(function() a:K2_DestroyActor() end) end)
    end)
    r.ok = true
    r.actor = U.short(a)
    return r
end

return M
