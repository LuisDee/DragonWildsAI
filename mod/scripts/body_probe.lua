-- Phase 4 body probe: READ-ONLY survey of what the server has loaded, for the spawn plan in
-- docs/research/2026-10-25-dump-body.md. Never spawns, possesses, moves, loads or writes
-- anything. Every Unreal call is wrapped in pcall; a failure is logged, never fatal.
--
-- Usage (from main.lua, on the game thread, ideally once Luis is connected so the world
-- has streamed in around him and the AiDirector has spawned creatures):
--   require("body_probe").run(log)            -- log = dwlog (needs log.event(name, data))
--   require("body_probe").run(log, { max_names = 8, nav_query = false })
-- Returns a summary table (also logged as event "body_probe_summary").
--
-- Class names below come from the 26161880 dump (Dominion module). FindAllOf/FindFirstOf
-- take the short class name and only see objects already in memory.
local M = {}

M.DEFAULTS = {
    max_names = 5,    -- full names / per-instance details logged per class
    nav_query = true, -- K2_ProjectPointToNavigation at player pawns (a pure query)
}

-- Candidate classes to look up with StaticFindObject (finds loaded objects only, no load).
-- Paths verified in the idle-server dump are marked (dump); the rest are guesses to test.
M.CLASS_PATHS = {
    "/Game/Gameplay/AI/BP_DominionAICharacter.BP_DominionAICharacter_C", -- (dump)
    "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Worker/BP_AI_KalphiteWorker_Character.BP_AI_KalphiteWorker_Character_C", -- (dump)
    "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Worker/BP_AI_KalphiteWorker_Controller.BP_AI_KalphiteWorker_Controller_C", -- (dump)
    "/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C", -- (dump)
    "/Game/Gameplay/Character/Player/BP_PlayerController.BP_PlayerController_C", -- (dump)
    "/Game/Gameplay/NPCs/BP_BaseInteractableNPC.BP_BaseInteractableNPC_C", -- (dump; AActor, not a Pawn)
    "/Game/Gameplay/AI/Cow/BP_AI_Cow_Character.BP_AI_Cow_Character_C", -- guess (folder exists)
    "/Game/Gameplay/AI/Chicken/BP_AI_Chicken_Character.BP_AI_Chicken_Character_C", -- guess
    "/Game/Gameplay/AI/Sheep/BP_AI_Sheep_Character.BP_AI_Sheep_Character_C", -- guess
}

M.OBJECT_PATHS = {
    "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Friend/DA_Kalphite_Friend.DA_Kalphite_Friend", -- (dump) FollowerDataAsset
}

-- ------------------------------------------------------------------ safe helpers
local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil, tostring(v)
end

local function valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    return try(function() return o:IsValid() end) == true
end

local function full_name(o)
    if not valid(o) then return nil end
    return try(function() return o:GetFullName() end)
end

local function class_name(o)
    if not valid(o) then return nil end
    return try(function() return o:GetClass():GetFullName() end)
end

local function is_default(o)
    local n = full_name(o)
    return n ~= nil and n:find("Default__", 1, true) ~= nil
end

local function vec(v)
    if v == nil then return nil end
    local t = try(function() return { X = v.X, Y = v.Y, Z = v.Z } end)
    if t and type(t.X) == "number" then
        return { X = math.floor(t.X + 0.5), Y = math.floor(t.Y + 0.5), Z = math.floor(t.Z + 0.5) }
    end
    return nil
end

local function location(actor)
    if not valid(actor) then return nil end
    return vec(try(function() return actor:K2_GetActorLocation() end))
end

-- Read a property; objects become their full name, other userdata a string.
local function prop(o, name)
    if not valid(o) then return nil end
    local v, err = try(function() return o[name] end)
    if err then return "<err " .. err .. ">" end
    if type(v) == "userdata" then
        if valid(v) then return full_name(v) or "<object>" end
        local s = try(function() return v:ToString() end) -- FString/FName/FText/soft ptrs
        if s then return s end
        return tostring(v)
    end
    return v
end

local function props(o, names)
    local out = {}
    for _, n in ipairs(names) do out[n] = prop(o, n) end
    return out
end

-- Non-default, valid instances of a short class name (empty table when none).
local function find_all(short)
    local list, err = try(function() return FindAllOf(short) end)
    local out = {}
    if type(list) == "table" then
        for _, o in ipairs(list) do
            if valid(o) and not is_default(o) then out[#out + 1] = o end
        end
    end
    return out, err
end

local function histogram(objs)
    local h = {}
    for _, o in ipairs(objs) do
        local c = class_name(o) or "?"
        h[c] = (h[c] or 0) + 1
    end
    return h
end

local function names(objs, n)
    local out = {}
    for i = 1, math.min(#objs, n) do out[i] = full_name(objs[i]) end
    return out
end

-- ------------------------------------------------------------------ probe sections
local REPL = { "bReplicates", "bReplicateMovement", "bAlwaysRelevant", "NetDormancy", "NetCullDistanceSquared" }
local PAWN = { "AutoPossessAI", "AIControllerClass", "Controller" }

local function survey(log, short, opts, detail)
    local objs, err = find_all(short)
    local rec = { class = short, count = #objs, err = err, classes = histogram(objs), names = names(objs, opts.max_names) }
    if detail then
        rec.details = {}
        for i = 1, math.min(#objs, opts.max_names) do
            local d = { name = full_name(objs[i]) }
            local okd, e = pcall(detail, objs[i], d)
            if not okd then d.err = tostring(e) end
            rec.details[i] = d
        end
    end
    log.event("body_probe_class", rec)
    return objs, rec
end

local function ai_detail(o, d)
    d.class = class_name(o)
    d.loc = location(o)
    d.props = props(o, { "CurrentAlertnessState", "PowerLevel", "bSpawnedByAiDirector", "bSkipSpudStore", "bShouldWalk", "AIDataClass" })
    d.repl = props(o, REPL)
    d.pawn = props(o, PAWN)
    d.is_follower = try(function() return o:IsFollower() end)
    d.is_confused = try(function() return o:IsConfused() end)
    local ctrl = try(function() return o.Controller end)
    if valid(ctrl) then
        d.controller_class = class_name(ctrl)
        d.move_status = try(function() return ctrl:GetMoveStatus() end) -- EPathFollowingStatus 0 Idle..3 Moving
    end
    local cm = try(function() return o.CharacterMovement end)
    if valid(cm) then
        d.movement = { class = class_name(cm), props = props(cm, { "MovementMode", "DefaultLandMovementMode", "MaxWalkSpeed", "bOrientRotationToMovement", "bUseControllerDesiredRotation" }) }
    end
end

local function player_detail(o, d)
    d.class = class_name(o)
    d.loc = location(o)
    d.follower = prop(o, "Follower")
    d.follower_component = prop(o, "FollowerComponent")
    d.controller = prop(o, "Controller")
    d.player_state = prop(o, "PlayerState")
end

local function pc_detail(o, d)
    d.class = class_name(o)
    d.is_local = try(function() return o:IsLocalController() end)
    local pawn = try(function() return o.Pawn end)
    d.pawn = full_name(pawn)
    d.pawn_loc = location(pawn)
end

local function cdo_defaults(log)
    local paths = {
        "/Game/Gameplay/AI/BP_DominionAICharacter.Default__BP_DominionAICharacter_C",
        "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Worker/BP_AI_KalphiteWorker_Character.Default__BP_AI_KalphiteWorker_Character_C",
        "/Game/Gameplay/NPCs/BP_BaseInteractableNPC.Default__BP_BaseInteractableNPC_C",
        "/Script/Dominion.Default__DominionAICharacter",
    }
    for _, p in ipairs(paths) do
        local o = try(function() return StaticFindObject(p) end)
        local rec = { path = p, found = valid(o) }
        if rec.found then
            rec.repl = props(o, REPL)
            rec.pawn = props(o, PAWN)
            rec.other = props(o, { "bSkipSpudStore", "bCanBeSpawnedByDebugMenu", "AIDataClass", "DesiredCullRange" })
            local cm = try(function() return o.CharacterMovement end)
            if valid(cm) then rec.movement_class = class_name(cm) end
        end
        log.event("body_probe_cdo", rec)
    end
end

local function static_paths(log)
    local out = {}
    for _, p in ipairs(M.CLASS_PATHS) do
        out[p] = valid(try(function() return StaticFindObject(p) end))
    end
    for _, p in ipairs(M.OBJECT_PATHS) do
        local o = try(function() return StaticFindObject(p) end)
        local rec = { found = valid(o) }
        if rec.found then
            rec.props = props(o, { "FollowerClass", "FollowerLifetime", "FollowerCooldown", "FollowerPowerLevel", "EffectToApplyDuringSummon" })
        end
        out[p] = rec
    end
    log.event("body_probe_static", out)
end

local function world_info(log, ctx)
    local rec = {}
    local world = valid(ctx) and try(function() return ctx:GetWorld() end) or nil
    if not valid(world) then world = try(function() return FindFirstOf("World") end) end
    rec.world = full_name(world)
    local ksl = try(function() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    if valid(ksl) and valid(world) then
        rec.is_server = try(function() return ksl:IsServer(world) end)
        rec.is_dedicated = try(function() return ksl:IsDedicatedServer(world) end)
    end
    if valid(world) then
        rec.authority_game_mode = prop(world, "AuthorityGameMode")
        rec.game_state = prop(world, "GameState")
    end
    log.event("body_probe_world", rec)
    return world
end

local function nav_info(log, world, player_pawns, opts)
    local navsys = find_all("NavigationSystemV1")
    local rec = { nav_systems = names(navsys, opts.max_names) }
    if navsys[1] then
        rec.navsys_props = props(navsys[1], { "bGenerateNavigationOnlyAroundNavigationInvokers", "bAutoCreateNavigationData", "bSpawnNavDataInNavBoundsLevel", "DataGatheringMode" })
    end
    local recast = find_all("RecastNavMesh")
    rec.recast_count = #recast
    rec.recast = {}
    for i = 1, math.min(#recast, opts.max_names + 3) do
        rec.recast[i] = { name = full_name(recast[i]), props = props(recast[i], { "RuntimeGeneration", "AgentRadius", "AgentHeight" }) }
    end
    rec.nav_chunk_actors = #(find_all("NavigationDataChunkActor"))
    rec.nav_invokers = #(find_all("NavigationInvokerComponent"))
    rec.nav_bounds = #(find_all("NavMeshBoundsVolume"))

    if opts.nav_query and valid(world) then
        local nav = try(function() return StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1") end)
        rec.projections = {}
        for i, pawn in ipairs(player_pawns) do
            local at = location(pawn)
            if at and valid(nav) then
                local out = {}
                -- (WorldContextObject, Point, out ProjectedLocation, NavData, FilterClass, QueryExtent)
                -- UE4SS fills a table passed for an out struct; nil is tried for NavData/FilterClass.
                local r = table.pack(pcall(function()
                    return nav:K2_ProjectPointToNavigation(world, at, out, nil, nil, { X = 200, Y = 200, Z = 500 })
                end))
                local ok = r[1]
                rec.projections[i] = {
                    pawn = full_name(pawn), at = at, ok = ok,
                    ret = ok and tostring(r[2]) or nil, ret2 = ok and r[3] ~= nil and tostring(r[3]) or nil,
                    err = (not ok) and tostring(r[2]) or nil,
                    projected = vec(out.ProjectedLocation) or vec(out),
                }
            end
        end
    end
    log.event("body_probe_nav", rec)
end

local function director_info(log, opts)
    local dirs = find_all("AiDirector")
    local rec = { count = #dirs, names = names(dirs, opts.max_names) }
    if dirs[1] then
        rec.props = props(dirs[1], { "bDynamicSpawningEnabled", "MaxNumberOfAI", "ManagementTickPeriod", "SpawningTickPeriod" })
        rec.dynamic_enabled = try(function() return dirs[1]:IsDynamicSpawningEnabled() end)
    end
    local subs = find_all("DominionAISubsystem")
    rec.ai_subsystems = names(subs, opts.max_names)
    local points = find_all("AISpawnPoint")
    rec.spawn_points = #points
    rec.spawn_point_classes = {}
    for _, p in ipairs(points) do
        local c = prop(p, "AIClass") or "?"
        rec.spawn_point_classes[c] = (rec.spawn_point_classes[c] or 0) + 1
    end
    rec.spawn_volumes = #(find_all("AISpawnVolume"))
    log.event("body_probe_director", rec)
end

-- ------------------------------------------------------------------ entry point
function M.run(log, opts)
    opts = opts or {}
    for k, v in pairs(M.DEFAULTS) do if opts[k] == nil then opts[k] = v end end
    local started = os.clock()
    local summary = {}

    local ok, err = pcall(function()
        log.event("body_probe_start", { opts = opts })

        survey(log, "GameInstance", opts)
        local gms = survey(log, "GameModeBase", opts)
        survey(log, "GameStateBase", opts)
        local pcs = survey(log, "PlayerController", opts, pc_detail)
        local players = survey(log, "DominionPlayerCharacter", opts, player_detail)
        local ais = survey(log, "DominionAICharacter", opts, ai_detail)
        survey(log, "DominionAIController", opts)
        survey(log, "AIController", opts)
        local chars = survey(log, "Character", opts) -- class histogram catches non-Dominion creatures
        survey(log, "InteractableNPC", opts)
        survey(log, "FollowerComponent", opts)
        survey(log, "FollowerDataAsset", opts)
        survey(log, "AsyncAction_DomSpawnAI", opts)

        local world = world_info(log, gms[1] or pcs[1] or players[1])
        cdo_defaults(log)
        static_paths(log)
        director_info(log, opts)
        nav_info(log, world, players, opts)

        summary = {
            game_modes = #gms, player_controllers = #pcs, players = #players,
            ai_characters = #ais, ai_classes = histogram(ais), characters = #chars,
            world = full_name(world),
        }
    end)

    summary.ok = ok
    summary.err = err and tostring(err) or nil
    summary.cpu_s = os.clock() - started
    log.event("body_probe_summary", summary)
    return summary
end

return M
