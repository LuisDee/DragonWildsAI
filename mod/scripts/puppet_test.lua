-- Route 1 experiments: a server-driven BP_PlayerCharacter_C ("puppet") that looks and acts like a player.
-- Run via debug_run {module="puppet_test", args={action=...}} with Luis connected. Each step is
-- pcall-guarded and logged; a crash here only costs a restart of the throwaway server.
--   status  : list puppets (every BP_PlayerCharacter_C that is not a real player's pawn)
--   spawn   : SpawnActor(BP_PlayerCharacter_C) 3 m in front of Luis
--   possess : give each unpossessed puppet a controller (SpawnDefaultController, else a plain AIController)
--   move    : AIController:MoveToLocation(Luis) for each puppet
--   destroy : SetLifeSpan(0.1) on every puppet (and its AIController)
local M = {}

local PLAYER_CHAR = "/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C"
local AI_CONTROLLER = "/Script/AIModule.AIController"

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function fullname(o) return o and try(function() return o:GetFullName() end) or nil end

local function vec(a)
    local v = try(function() return a:K2_GetActorLocation() end)
    return v and { X = v.X, Y = v.Y, Z = v.Z }
end

-- Real players are pawns possessed by a PlayerController; everything else of the class is ours.
local function split_pawns()
    local players, puppets = {}, {}
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if valid(p) then
            local c = try(function() return p:GetController() end)
            local is_player = valid(c) and (fullname(c) or ""):find("PlayerController", 1, true) ~= nil
            table.insert(is_player and players or puppets, p)
        end
    end
    return players, puppets
end

local function describe(p)
    local c = try(function() return p:GetController() end)
    return {
        name = fullname(p),
        location = vec(p),
        controller = valid(c) and fullname(c) or nil,
        player_state = fullname(try(function() return p.PlayerState end)),
        hidden = try(function() return p.bHidden end),
        replicates = try(function() return p:GetIsReplicated() end),
    }
end

local actions = {}

function actions.status()
    local players, puppets = split_pawns()
    local out = { players = {}, puppets = {} }
    for _, p in ipairs(players) do out.players[#out.players + 1] = describe(p) end
    for _, p in ipairs(puppets) do out.puppets[#out.puppets + 1] = describe(p) end
    return out
end

-- args.at = {X,Y,Z} spawns there (works with nobody connected); otherwise 3 m in front of Luis.
function actions.spawn(log, args)
    local players = split_pawns()
    local luis = players[1]
    if not luis and not args.at then return { ok = false, error = "no connected player and no args.at" } end
    local cls = StaticFindObject(PLAYER_CHAR)
    if not valid(cls) then return { ok = false, error = "class not loaded", path = PLAYER_CHAR } end
    local loc = args.at
    if not loc then
        local at = vec(luis)
        local fwd = try(function() return luis:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
        loc = { X = at.X + fwd.X * 300, Y = at.Y + fwd.Y * 300, Z = at.Z + 50 }
    end
    local world = luis and luis:GetWorld() or FindFirstOf("World")
    local ok, actor = pcall(function() return world:SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    log.event("puppet_spawn", { ok = ok, actor = ok and fullname(actor) or nil, err = (not ok) and tostring(actor) or nil, at = loc })
    if not ok or not valid(actor) then return { ok = false, error = ok and "SpawnActor returned invalid" or tostring(actor) } end
    return { ok = true, puppet = describe(actor) }
end

-- args.player_state=true: spawn a plain AIController with bWantsPlayerState (the UE bot pattern)
-- instead of SpawnDefaultController, so the puppet gets a PlayerState like a real player.
function actions.possess(log, args)
    local _, puppets = split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        local r = { puppet = fullname(p) }
        if not valid(try(function() return p:GetController() end)) then
            if not args.player_state then
                r.default_ok, r.default_err = pcall(function() p:SpawnDefaultController() end)
            end
            if not valid(try(function() return p:GetController() end)) then
                local cls = StaticFindObject(AI_CONTROLLER)
                r.ai_ok, r.ai_err = pcall(function()
                    local ctrl = p:GetWorld():SpawnActor(cls, vec(p), { Pitch = 0, Yaw = 0, Roll = 0 })
                    if args.player_state then ctrl.bWantsPlayerState = true end
                    ctrl:Possess(p)
                end)
            end
        end
        r.default_err, r.ai_err = r.default_err and tostring(r.default_err), r.ai_err and tostring(r.ai_err)
        r.after = describe(p)
        out[#out + 1] = r
    end
    log.event("puppet_possess", { results = out })
    return { results = out }
end

function actions.move(log)
    local players, puppets = split_pawns()
    local luis = players[1]
    if not luis then return { ok = false, error = "no connected player" } end
    local dest, out = vec(luis), {}
    for _, p in ipairs(puppets) do
        local c = try(function() return p:GetController() end)
        local ok, res = pcall(function() return c:MoveToLocation(dest, 150.0, true, true, true, false, nil, true) end)
        out[#out + 1] = { puppet = fullname(p), ok = ok, result = tostring(res) }
    end
    log.event("puppet_move", { results = out })
    return { results = out }
end

-- args.keep_controller=true destroys only the pawn.
function actions.unpossess(log)
    local _, puppets = split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        local c = try(function() return p:GetController() end)
        local ok, err = pcall(function() c:UnPossess() end)
        out[#out + 1] = { puppet = fullname(p), ok = ok, err = (not ok) and tostring(err) or nil }
    end
    log.event("puppet_unpossess", { results = out })
    return { results = out }
end

function actions.destroy(log, args)
    local _, puppets = split_pawns()
    local n = 0
    for _, p in ipairs(puppets) do
        local c = (not args.keep_controller) and try(function() return p:GetController() end) or nil
        -- SetLifeSpan, not K2_DestroyActor: destroying immediately from inside a UE4SS delayed-action
        -- callback deadlocked the game thread (verified 2026-10-25); the engine destroys it next tick.
        if pcall(function() p:SetLifeSpan(0.1) end) then n = n + 1 end
        if valid(c) and not (fullname(c) or ""):find("PlayerController", 1, true) then pcall(function() c:SetLifeSpan(0.1) end) end
    end
    log.event("puppet_destroy", { count = n })
    return { destroyed = n }
end

function M.run(log, args)
    local a = actions[args.action or "status"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
