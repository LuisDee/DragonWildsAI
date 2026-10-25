-- Lifecycle of the ONE companion body per server run: a server-spawned BP_PlayerCharacter_C
-- ("puppet") possessed by an AIController. Verified in game (DISCOVERIES "ROUTE 1 WORKS"):
-- SpawnActor 3 m from the player, SpawnDefaultController -> AIController, it replicates, walks
-- and animates on vanilla GFN clients; HealthComponent:SetIsImmortal(true, puppet) keeps it alive.
--
-- HARD RULE: never unpossess or destroy the puppet. Any unpossess of an AI-possessed
-- BP_PlayerCharacter_C crashes the server (Dominion reads PC->LoadoutComponent on a null PC;
-- DISCOVERIES "ROOT CAUSES"). Destroy, SetLifeSpan, UnPossess and death all take that path, so:
--   * "despawn" = park(): stop movement, disable movement, hide, no collision, teleport under the
--     player's position (or its own); unpark() brings it back next to a player.
--   * immortal from the moment it is possessed, so death never runs.
--   * one puppet per run: if the module state is lost (hot reload), adopt the existing AI-possessed
--     puppet instead of spawning a second one.
-- Safe removal exists (body/removal.lua: strip PlayerRangedAttackComponent, then unpossess; verified
-- offline, DISCOVERIES "Unpossess crash: fix bisect"). main.lua registers it with
-- M.set_safe_remover(fn(puppet, log) -> ok); park() uses it only with DW_PUPPET_SAFE_REMOVE=1, and
-- otherwise hides and parks the puppet as below.
--
-- Identity: right after possession the puppet gets a DominionPlayerState named "Claude" (overhead
-- nameplate; body/identity.lua). ensure_spawned() also attaches one to an adopted puppet without one.
--
-- UNVERIFIED in game (all pcall-guarded, breadcrumbed): parking (CharacterMovement:DisableMovement,
-- SetActorHiddenInGame, SetActorEnableCollision, K2_TeleportTo), unparking (SetMovementMode(1)),
-- reading WorldSettings.KillZ, re-applying persisted gear on spawn.
local U = require("body.util")
local gear = require("body.gear")
local identity = require("body.identity")
local jsonutil = require("jsonutil")

local M = {}

M.PLAYER_CHAR = "/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C"
M.AI_CONTROLLER = "/Script/AIModule.AIController"
M.SPAWN_DIST_CM = 300       -- 3 m in front of the player (as verified in puppet_test)
M.PARK_DEPTH_CM = 1000      -- park 10 m under the player
M.CHECK_MS = 5000           -- lifecycle loop (only when started with M.start)
M.GEAR_DELAY_MS = 1000      -- re-apply gear a moment after spawning
M.MOVE_WALKING = 1          -- EMovementMode::MOVE_Walking

local st = {
    actor = nil, name = nil, parked = false, parked_by = nil, seen_players = 0,
    log = nil, state_path = nil, saved = nil, loop = nil, safe_remover = nil,
}

local function log(name, data) if st.log then pcall(st.log.event, name, data) end end

-- ------------------------------------------------------------------ persisted bot state
-- JSON: {"v":1,"gear":{"right":"/path","body":"/path",...}}. DW_BOT_STATE overrides the path.
-- NOTE: tools/deploy_mod.ps1 wipes the deployed mod folder, so set DW_BOT_STATE outside it to
-- keep gear across deploys.
function M.state_path() return st.state_path end

function M.load_state()
    local f = st.state_path and io.open(st.state_path, "rb")
    local s = { v = 1, gear = {} }
    if f then
        local text = f:read("a")
        f:close()
        local v = jsonutil.decode(text)
        if type(v) == "table" then
            s = v
            if type(s.gear) ~= "table" then s.gear = {} end
        else
            log("bot_state_corrupt", { path = st.state_path })
        end
    end
    st.saved = s
    return s
end

function M.save_state()
    if not st.state_path then return false end
    local s = st.saved or M.load_state()
    s.v = 1
    s.gear = jsonutil.object(s.gear or {})
    local tmp = st.state_path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then log("bot_state_write_error", { path = tmp, err = tostring(err) }); return false end
    f:write(jsonutil.encode(s))
    f:close()
    os.remove(st.state_path) -- Windows rename does not overwrite
    local ok, rerr = os.rename(tmp, st.state_path)
    if not ok then log("bot_state_write_error", { path = st.state_path, err = tostring(rerr) }) end
    return ok and true or false
end

function M.saved_gear() return (st.saved or M.load_state()).gear end

function M.remember_gear(slot, item_path)
    local s = st.saved or M.load_state()
    s.gear[slot] = item_path
    return M.save_state()
end

-- ------------------------------------------------------------------ finding the puppet
local function is_ai_possessed(p)
    local c = U.controller_of(p)
    return c ~= nil and not U.is_player_controller(c) and (U.fullname(c) or ""):find("AIController", 1, true) ~= nil
end

-- The live puppet, or nil. Re-adopts an AI-possessed puppet if our reference was lost (only those:
-- a real player's pawn mid-join has no controller and must never be treated as ours).
function M.get()
    if U.valid(st.actor) then return st.actor end
    local _, puppets = U.split_pawns()
    for _, p in ipairs(puppets) do
        if is_ai_possessed(p) then
            st.actor, st.name = p, U.fullname(p)
            st.parked = U.try(function() return p.bHidden end) == true
            st.parked_by = st.parked and "adopted" or nil
            log("puppet_adopted", { puppet = st.name, parked = st.parked })
            return p
        end
    end
    st.actor = nil
    return nil
end

function M.controller()
    local p = M.get()
    return p and U.controller_of(p) or nil
end

function M.is_parked() return st.parked end

-- ------------------------------------------------------------------ spawn + possess
local function spawn_near(player)
    local cls = U.try(StaticFindObject, M.PLAYER_CHAR)
    if not U.valid(cls) then return nil, "class not loaded" end
    local at = U.loc(player)
    if not at then return nil, "player has no location" end
    local fwd = U.try(function() return player:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
    local loc = { X = at.X + fwd.X * M.SPAWN_DIST_CM, Y = at.Y + fwd.Y * M.SPAWN_DIST_CM, Z = at.Z + 50 }
    local actor
    local ok, err = U.call(st.log, "puppet.spawn", { at = loc }, function()
        actor = player:GetWorld():SpawnActor(cls, loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(actor) then return nil, ok and "SpawnActor returned invalid" or tostring(err) end
    return actor
end

local function possess(p)
    if is_ai_possessed(p) then return true end
    U.call(st.log, "puppet.SpawnDefaultController", { puppet = U.fullname(p) }, function() p:SpawnDefaultController() end)
    if is_ai_possessed(p) then return true end
    local cls = U.try(StaticFindObject, M.AI_CONTROLLER)
    U.call(st.log, "puppet.possess_ai", { puppet = U.fullname(p) }, function()
        local c = p:GetWorld():SpawnActor(cls, U.loc(p), { Pitch = 0, Yaw = 0, Roll = 0 })
        c:Possess(p)
    end)
    return is_ai_possessed(p)
end

local function make_immortal(p)
    return U.call(st.log, "puppet.SetIsImmortal", {}, function() p.HealthComponent:SetIsImmortal(true, p) end)
end

-- Overhead name "Claude": give the puppet a named DominionPlayerState (body/identity.lua).
-- Idempotent and pcall-guarded; DW_PUPPET_IDENTITY=0 disables it.
local function ensure_identity(p)
    local ok, r = pcall(identity.ensure, st.log, p, U.controller_of(p))
    if not ok then log("puppet_identity_error", { err = tostring(r) }) end
end

-- Re-apply persisted gear (UNVERIFIED as a batch; each item uses the verified equip pattern).
function M.apply_saved_gear()
    local p = M.get()
    if not p then return {} end
    local out = {}
    local g = M.saved_gear()
    for _, slot in ipairs(gear.SLOT_ORDER) do
        local path = g[slot]
        if type(path) == "string" then
            local r = gear.equip(st.log, p, path, { hand = slot })
            out[slot] = r.ok and true or r.reason
        end
    end
    log("puppet_gear_reapplied", { results = out })
    return out
end

-- Spawn (once per run) near the first connected player, possess, make immortal, re-apply gear.
-- Returns puppet or nil, reason.
function M.ensure_spawned()
    local p = M.get()
    if p then
        if is_ai_possessed(p) or possess(p) then
            if not identity.player_state(p) then ensure_identity(p) end
            return p
        end
        return nil, "possess failed"
    end
    local players = U.split_pawns()
    if not players[1] then return nil, "no connected player to spawn near" end
    local actor, err = spawn_near(players[1])
    if not actor then log("puppet_spawn_failed", { err = err }); return nil, err end
    st.actor, st.name, st.parked, st.parked_by = actor, U.fullname(actor), false, nil
    if not possess(actor) then
        -- Not possessed: keep the reference (so we don't spawn another) and retry possession on the
        -- next call. Destroying an unpossessed pawn is safe (bisect A) but keep the rule simple.
        log("puppet_possess_failed", { puppet = st.name })
        return nil, "possess failed"
    end
    make_immortal(actor)
    ensure_identity(actor)
    log("puppet_spawned", { puppet = st.name, controller = U.fullname(U.controller_of(actor)) })
    if next(M.saved_gear()) ~= nil then
        if type(ExecuteInGameThreadWithDelay) == "function" then
            ExecuteInGameThreadWithDelay(M.GEAR_DELAY_MS, function() pcall(M.apply_saved_gear) end)
        else
            pcall(M.apply_saved_gear)
        end
    end
    return actor
end

-- ------------------------------------------------------------------ park / unpark
local function teleport(p, loc, label)
    local ok, res = U.call(st.log, label, { to = loc }, function()
        return p:K2_TeleportTo(loc, U.try(function() return p:K2_GetActorRotation() end) or { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    return ok and res ~= false
end

function M.set_safe_remover(fn) st.safe_remover = fn end

-- "Despawn" without removing: see the HARD RULE above. by = "cmd" (stays parked until summoned) or
-- "auto" (the lifecycle loop unparks it when a player is back).
function M.park(by)
    local p = M.get()
    if not p then return false, "no puppet" end
    if st.safe_remover and os.getenv("DW_PUPPET_SAFE_REMOVE") == "1" then
        local ok, removed = pcall(st.safe_remover, p, st.log)
        log("puppet_safe_remove", { ok = ok, removed = removed })
        if ok and removed then st.actor, st.name, st.parked = nil, nil, false; return true end
    end
    local c = U.controller_of(p)
    if c then U.call(st.log, "puppet.StopMovement", {}, function() c:StopMovement() end) end
    U.call(st.log, "puppet.DisableMovement", {}, function() p.CharacterMovement:DisableMovement() end)
    U.call(st.log, "puppet.hide", {}, function() p:SetActorHiddenInGame(true) end)
    U.call(st.log, "puppet.collision_off", {}, function() p:SetActorEnableCollision(false) end)
    local players = U.split_pawns()
    local base = U.loc(players[1]) or U.loc(p)
    local teleported = false
    if base then
        local killz = U.try(function() return p:GetWorld():K2_GetWorldSettings().KillZ end)
        local z = base.Z - M.PARK_DEPTH_CM
        if type(killz) == "number" then z = math.max(z, killz + 5000) end
        teleported = teleport(p, { X = base.X, Y = base.Y, Z = z }, "puppet.park_teleport")
    end
    pcall(function() p:ForceNetUpdate() end)
    st.parked, st.parked_by = true, by or "cmd"
    log("puppet_parked", { by = st.parked_by, teleported = teleported })
    return true
end

-- Bring the puppet back next to `player` (default: first connected player).
function M.unpark(player)
    local p = M.get()
    if not p then return false, "no puppet" end
    player = player or U.split_pawns()[1]
    U.call(st.log, "puppet.collision_on", {}, function() p:SetActorEnableCollision(true) end)
    local at = player and U.loc(player)
    local moved = false
    if at then
        local fwd = U.try(function() return player:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
        moved = teleport(p, { X = at.X + fwd.X * M.SPAWN_DIST_CM, Y = at.Y + fwd.Y * M.SPAWN_DIST_CM, Z = at.Z + 50 }, "puppet.unpark_teleport")
            or teleport(p, { X = at.X - fwd.X * 150, Y = at.Y - fwd.Y * 150, Z = at.Z + 100 }, "puppet.unpark_teleport2")
    end
    U.call(st.log, "puppet.SetMovementMode", {}, function() p.CharacterMovement:SetMovementMode(M.MOVE_WALKING, 0) end)
    U.call(st.log, "puppet.unhide", {}, function() p:SetActorHiddenInGame(false) end)
    pcall(function() p:ForceNetUpdate() end)
    st.parked, st.parked_by = false, nil
    log("puppet_unparked", { teleported = moved, near = U.fullname(player) })
    return true
end

-- Catch-up teleport to `behind_cm` behind a player (follow reflex; UNVERIFIED: K2_TeleportTo).
function M.teleport_near(player, behind_cm)
    local p = M.get()
    local at = player and U.loc(player)
    if not (p and at) then return false end
    local fwd = U.try(function() return player:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
    local b = behind_cm or 200
    return teleport(p, { X = at.X - fwd.X * b, Y = at.Y - fwd.Y * b, Z = at.Z + 50 }, "puppet.catchup_teleport")
end

-- Ready to act: spawned, possessed and not parked. Returns puppet, controller or nil, reason.
function M.ensure_ready(near_player)
    local p, err = M.ensure_spawned()
    if not p then return nil, err end
    if st.parked then M.unpark(near_player) end
    local c = U.controller_of(p)
    if not c then return nil, "puppet has no controller" end
    return p, c
end

function M.status()
    local p = M.get()
    return {
        spawned = p ~= nil, name = p and U.short(p) or nil, parked = st.parked, parked_by = st.parked_by,
        controller = p and U.fullname(U.controller_of(p)) or nil, state_path = st.state_path,
        saved_gear = jsonutil.object(M.saved_gear()),
    }
end

-- ------------------------------------------------------------------ lifecycle loop
-- Spawn once a player has been connected for two checks; park when everyone leaves; unpark an
-- auto-parked puppet when someone is back.
function M.tick()
    local players = U.split_pawns()
    if #players == 0 then
        st.seen_players = 0
        if M.get() and not st.parked then M.park("auto") end
        return
    end
    st.seen_players = st.seen_players + 1
    local p = M.get()
    if not p then
        if st.seen_players >= 2 then M.ensure_spawned() end
    elseif st.parked and st.parked_by == "auto" then
        M.unpark(players[1])
    end
end

-- opts: {log, mod_root, state_path}
function M.init(opts)
    opts = opts or {}
    st.log = opts.log
    local env = os.getenv("DW_BOT_STATE")
    st.state_path = opts.state_path or (env and env ~= "" and env) or (opts.mod_root and (opts.mod_root .. "/bot_state.json")) or nil
    st.saved = nil
    M.load_state()
    return M
end

function M.start()
    if st.loop then return end
    st.loop = LoopInGameThreadWithDelay(M.CHECK_MS, function()
        local ok, err = pcall(M.tick)
        if not ok then log("puppet_tick_error", { err = tostring(err) }) end
    end)
    log("puppet_lifecycle_started", { check_ms = M.CHECK_MS, state_path = st.state_path })
end

-- Test hook: forget everything (never touches the actor).
function M._reset()
    if st.loop and CancelDelayedAction then pcall(CancelDelayedAction, st.loop) end
    st.actor, st.name, st.parked, st.parked_by, st.seen_players, st.loop, st.safe_remover = nil, nil, false, nil, 0, nil, nil
end

return M
