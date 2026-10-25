-- Route 1 experiments: a server-driven BP_PlayerCharacter_C ("puppet") that looks and acts like a player.
-- Run via debug_run {module="puppet_test", args={action=...}} with Luis connected. Each step is
-- pcall-guarded and breadcrumbed; a crash here only costs a restart of the throwaway server.
-- The proven parts live in body/puppet.lua (lifecycle) and body/removal.lua (safe removal).
--   status  : list puppets (every BP_PlayerCharacter_C that is not a real player's pawn)
--   spawn   : SpawnActor(BP_PlayerCharacter_C) 3 m in front of Luis (or at args.at)
--   possess : give each unpossessed puppet a controller (SpawnDefaultController, else a plain AIController)
--   move    : AIController:MoveToLocation(Luis) for each puppet
--   destroy : SetLifeSpan(0.1) on every puppet (and its AIController). CRASHES if the puppet is
--             AI-possessed (risk register R1); refuses unless args.allow_crash=true. Use puppet_safe.
--   strip {components} : K2_DestroyComponent(owner) on the named pawn component properties
--   unpossess : AIController:UnPossess() (logs addresses first, for dump matching). CRASHES unless
--               PlayerRangedAttackComponent was stripped first; refuses unless args.allow_crash=true.
--   addrs / components / fname {indices} / gc : crash-dump and GC diagnostics
local U = require("body.util")

local M = {}

local PLAYER_CHAR = "/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C"
local AI_CONTROLLER = "/Script/AIModule.AIController"
local REFUSED = { ok = false, error = "refused: known server crash path; pass allow_crash=true on a throwaway run with nobody connected" }

local function describe(p)
    local c = U.controller_of(p)
    return {
        name = U.fullname(p),
        location = U.loc(p),
        controller = U.fullname(c),
        player_state = U.fullname(U.try(function() return p.PlayerState end)),
        hidden = U.try(function() return p.bHidden end),
        replicates = U.try(function() return p:GetIsReplicated() end),
    }
end

local function err_str(e) return e and tostring(e) or nil end

local actions = {}

function actions.status()
    local players, puppets = U.split_pawns()
    local out = { players = {}, puppets = {} }
    for _, p in ipairs(players) do out.players[#out.players + 1] = describe(p) end
    for _, p in ipairs(puppets) do out.puppets[#out.puppets + 1] = describe(p) end
    return out
end

-- args.at = {X,Y,Z} spawns there (works with nobody connected); otherwise 3 m in front of Luis.
function actions.spawn(log, args)
    local luis = U.split_pawns()[1]
    if not luis and not args.at then return { ok = false, error = "no connected player and no args.at" } end
    local cls = U.find_object(PLAYER_CHAR)
    if not cls then return { ok = false, error = "class not loaded", path = PLAYER_CHAR } end
    local loc = args.at or U.in_front(luis, 300, 50)
    local world = luis and luis:GetWorld() or U.find_first("World")
    local ok, actor = U.call(log, "puppet_test.SpawnActor", { at = loc }, function()
        return world:SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    U.event(log, "puppet_spawn", { ok = ok, actor = ok and U.fullname(actor) or nil, err = (not ok) and tostring(actor) or nil, at = loc })
    if not ok or not U.valid(actor) then return { ok = false, error = ok and "SpawnActor returned invalid" or tostring(actor) } end
    return { ok = true, puppet = describe(actor) }
end

-- args.player_state=true: spawn a plain AIController with bWantsPlayerState (the UE bot pattern)
-- instead of SpawnDefaultController, so the puppet gets a PlayerState like a real player.
function actions.possess(log, args)
    local _, puppets = U.split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        local r = { puppet = U.fullname(p) }
        if not U.controller_of(p) then
            if not args.player_state then
                r.default_ok, r.default_err = U.call(log, "puppet_test.SpawnDefaultController", {}, function() p:SpawnDefaultController() end)
            end
            if not U.controller_of(p) then
                local cls = U.find_object(AI_CONTROLLER)
                r.ai_ok, r.ai_err = U.call(log, "puppet_test.Possess", { player_state = args.player_state }, function()
                    local ctrl = p:GetWorld():SpawnActor(cls, U.loc(p), { Pitch = 0, Yaw = 0, Roll = 0 })
                    if args.player_state then ctrl.bWantsPlayerState = true end
                    ctrl:Possess(p)
                end)
            end
        end
        r.default_err, r.ai_err = err_str(r.default_err), err_str(r.ai_err)
        r.after = describe(p)
        out[#out + 1] = r
    end
    U.event(log, "puppet_possess", { results = out })
    return { results = out }
end

function actions.move(log)
    local players, puppets = U.split_pawns()
    local luis = players[1]
    if not luis then return { ok = false, error = "no connected player" } end
    local dest, out = U.loc(luis), {}
    for _, p in ipairs(puppets) do
        local c = U.controller_of(p)
        local ok, res = U.call(log, "puppet_test.MoveToLocation", { dest = dest }, function()
            return c:MoveToLocation(dest, 150.0, true, true, true, false, nil, true)
        end)
        out[#out + 1] = { puppet = U.fullname(p), ok = ok, result = tostring(res) }
    end
    U.event(log, "puppet_move", { results = out })
    return { results = out }
end

-- Unpossess-crash fix experiment (bisect 0-2b): destroy pawn components before unpossess.
-- args.components = list of pawn property names (default: all candidates).
local STRIP_DEFAULT = { "PlayerActionPerformerComponent", "PlayerEquipmentComponent", "PlayerRangedAttackComponent",
                        "PlayerMeleeAttackComponent", "SprintComponent" }
function actions.strip(log, args)
    local _, puppets = U.split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        for _, prop in ipairs(args.components or STRIP_DEFAULT) do
            local comp = U.try(function() return p[prop] end)
            local ok, err = false, "missing"
            -- K2_DestroyComponent(Object) refuses unless Object is the owner (or the owner is null),
            -- so pass the pawn. The first strip run passed the component itself (a no-op).
            if U.valid(comp) then
                ok, err = U.call(log, "puppet_test.K2_DestroyComponent", { prop = prop }, function() comp:K2_DestroyComponent(p) end)
            end
            out[#out + 1] = { prop = prop, ok = ok, err = (not ok) and tostring(err) or nil,
                              destroyed = U.valid(comp) and not U.alive(comp) }
        end
    end
    U.event(log, "puppet_strip", { results = out })
    return { results = out }
end

-- Log the address of the puppet, its controller and every component, so the `this` register
-- (rdi) of the crashing handler in a dump can be matched to an object.
local function hex(o) local a = U.try(function() return o:GetAddress() end); return a and string.format("0x%x", a) or nil end
local function components_of(p)
    local list = {}
    local comps = U.try(function() return p:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent")) end)
    for i = 1, (comps and #comps or 0) do list[#list + 1] = comps[i]:get() end
    return list
end

function actions.addrs(log)
    local _, puppets = U.split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        local r = { puppet = hex(p), controller = hex(U.controller_of(p)), comps = {} }
        for _, c in ipairs(components_of(p)) do
            r.comps[#r.comps + 1] = { addr = hex(c), name = U.str(U.try(function() return c:GetFName() end)) }
        end
        out[#out + 1] = r
    end
    U.event(log, "puppet_addrs", { results = out })
    return { results = out }
end

function actions.unpossess(log, args)
    if args.allow_crash ~= true then return REFUSED end
    local _, puppets = U.split_pawns()
    actions.addrs(log)
    local out = {}
    for _, p in ipairs(puppets) do
        local c = U.controller_of(p)
        local ok, err = U.call(log, "puppet_test.UnPossess", { puppet = U.fullname(p) }, function() c:UnPossess() end)
        out[#out + 1] = { puppet = U.fullname(p), ok = ok, err = (not ok) and tostring(err) or nil }
    end
    U.event(log, "puppet_unpossess", { results = out })
    return { results = out }
end

function actions.destroy(log, args)
    if args.allow_crash ~= true then return REFUSED end
    local _, puppets = U.split_pawns()
    local n = 0
    for _, p in ipairs(puppets) do
        local c = (not args.keep_controller) and U.controller_of(p) or nil
        -- SetLifeSpan, not K2_DestroyActor: destroying immediately from inside a UE4SS delayed-action
        -- callback deadlocked the game thread (verified 2026-10-25); the engine destroys it next tick.
        if U.call(log, "puppet_test.SetLifeSpan", { puppet = U.fullname(p) }, function() p:SetLifeSpan(0.1) end) then n = n + 1 end
        if c and not U.is_player_controller(c) then
            U.call(log, "puppet_test.controller_SetLifeSpan", {}, function() c:SetLifeSpan(0.1) end)
        end
    end
    U.event(log, "puppet_destroy", { count = n })
    return { destroyed = n }
end

-- Resolve FName ComparisonIndex values read from a crash dump (object header +0x18).
-- args.indices = {number,...}. FName pool order is stable across runs for startup names; verify
-- with a known index (the AIController class name) before trusting the others.
function actions.fname(log, args)
    local out = {}
    for _, i in ipairs(args.indices or {}) do
        local s, err = U.try_err(function() return FName(i):ToString() end)
        out[#out + 1] = { index = i, ok = err == nil, name = s or err }
    end
    return { names = out }
end

-- List every component on each puppet: object name, class, FName index.
function actions.components()
    local _, puppets = U.split_pawns()
    local out = {}
    for _, p in ipairs(puppets) do
        local list = {}
        for _, c in ipairs(components_of(p)) do
            list[#list + 1] = {
                name = U.str(U.try(function() return c:GetFName() end)),
                index = U.try(function() return c:GetFName():GetComparisonIndex() end),
                class = U.str(U.try(function() return c:GetClass():GetFName() end)),
            }
        end
        out[#out + 1] = { puppet = U.fullname(p), components = list }
    end
    return { results = out }
end

-- Force a GC (KismetSystemLibrary.CollectGarbage queues "obj gc" for the next tick). Used to check
-- that removed puppets are purged without a dangling-reference crash.
function actions.gc(log)
    local ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary")
    local ok, err = U.call(log, "puppet_test.CollectGarbage", {}, function() ksl:CollectGarbage() end)
    U.event(log, "force_gc", { ok = ok })
    return { ok = ok, err = (not ok) and tostring(err) or nil }
end

function M.run(log, args)
    args = args or {}
    local a = actions[args.action or "status"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
