-- Companion BODY skills as bridge handlers (CLAUDE.md section 5; brain/BRIDGE_PROTOCOL.md v1).
-- Two speeds (principle 1): handlers only validate and start an action; a game-thread tick loop
-- (LoopInGameThreadWithDelay, TICK_MS) steps the one current action. Nothing ever blocks.
--
-- Handlers (args -> result data; positions/distances on the wire are METRES, game is cm):
--   get_state {}                       -> sync. See M.get_state.
--   follow {player, distance=3}        -> sync ok {following, distance} once the reflex is running;
--                                         re-issues MoveToActor every FOLLOW_MS when too far.
--   stop {}                            -> sync ok {stopped=<kind>|absent}
--   go_to {target}                     -> ASYNC; ok {target_position, position, arrive_tolerance}
--   attack {target}                    -> ASYNC; ok {target, killed, swings} when target hp <= 0 or it is gone
--   equip {item_path, hand?, actor_class?} -> sync ok {slot, item_path, gear, persisted}
--   say {text}                         -> sync ok {method, recipients, verified=false}
--   body_status {} / body_spawn {} / body_park {}   (debug/lifecycle)
--   capabilities {}                    -> sync ok {tools=[every tool with a real handler, sorted]}
-- Every handler above honours args.probe == true: ok {probe=true, tool} without acting. Without a
-- probe, missing required args answer invalid_args (never act on defaults).
-- Player identifiers (follow/go_to): the chat PlayerId string ("256", what command_received.player
-- carries), a display name, or "me"/"luis" for the first connected player (U.find_player).
-- Async actions reply once with bridge.reply(ctx.id, res) and also emit task_done{task_id,data} /
-- task_failed{task_id,reason}. A new action pre-empts the current one: that one replies
-- reason=interrupted (follow, already answered, ends silently).
-- "Verified state only" (principle 2): success comes from game state read back (distance, target
-- health/validity, the equipment slot), never from a call returning.
--
-- Verified in game: MoveToLocation/MoveToActor on the AIController (return 2 = RequestSuccessful),
-- BP_PerformAttack with the Sword attack set, GetAuthoritativeHealth, FindAllOf("DominionAICharacter"),
-- IsFollower. UNVERIFIED: GetMoveStatus, StopMovement, K2_SetFocus/K2_ClearFocus, attack sets other
-- than Sword, GetAttitude (off unless DW_STATE_ATTITUDE=1), the catch-up teleport, speech.
-- The direct-damage path (PredictDamage/ApplyDamageFromGameplayEffect) is deliberately NOT used:
-- it crashed the server in UE4SS struct marshalling.
local U = require("body.util")
local gear = require("body.gear")
local speech = require("body.speech")
local jsonutil = require("jsonutil")

local M = {}

M.TICK_MS = 250
-- follow
M.FOLLOW_MS = 500                 -- reflex cadence
M.FOLLOW_HYST_CM = 100            -- re-issue only beyond distance + this
M.FOLLOW_REISSUE_MS = 3000        -- while already moving, refresh the request this often
M.FOLLOW_TELEPORT_CM = 5000       -- further than 50 m ...
M.FOLLOW_TELEPORT_AFTER_MS = 5000 -- ... for 5 s: catch-up teleport behind the player
-- go_to
M.GOTO_ACCEPT_CM = 100
M.GOTO_TOL_CM = 200               -- horizontal arrival tolerance for coordinates
M.GOTO_DZ_CM = 250                -- vertical slack (navmesh projection)
M.GOTO_ACTOR_TOL_CM = 300         -- arrival distance for a player/entity target
M.GOTO_TIMEOUT_MS = 110000        -- brain gives up at 120 s
M.STUCK_MS = 4000
M.STUCK_MOVE_CM = 50
M.MAX_REISSUE = 3
-- attack
M.ATTACK_MAX_CM = 6000            -- engage targets within 60 m
M.ATTACK_LEASH_CM = 9000          -- give up (too_far) beyond 90 m
M.ATTACK_RANGE_CM = 250           -- swing when this close
M.ATTACK_ACCEPT_CM = 120
M.ATTACK_APPROACH_REISSUE_MS = 1500
M.ATTACK_COOLDOWN_MS = 1250
M.ATTACK_TIMEOUT_MS = 55000       -- brain gives up at 60 s
M.ATTACK_INEFFECTIVE_SWINGS = 10  -- this many swings with no health drop -> verification_failed
M.ATTACK_MAX_ERRORS = 3
M.ATTACK_FMT = "/Game/Gameplay/Character/Player/Attacks/%s/BP_Player_%s_Attack1.BP_Player_%s_Attack1_C"
M.ACTION_FMT = "/Game/Gameplay/Character/Player/Attacks/%s/PA_Attack_%s.Default__PA_Attack_%s_C"
M.DEFAULT_ATTACK_CATEGORY = "Sword" -- the verified set (it swung even with a mace in hand)
-- state export
M.NEARBY_CM = 5000
M.NEARBY_MAX = 20
M.AI_CLASS = "DominionAICharacter"
M.AI_LIB = "/Script/Dominion.Default__DominionAiFunctionLibrary"

-- EPathFollowingStatus / EPathFollowingRequestResult
local MOVE_IDLE, MOVE_MOVING = 0, 3
local REQ_FAILED = 0

local null = jsonutil.null
local S = { now = 0, action = nil, bridge = nil, log = nil, puppet = nil, loop = nil }

local function log(name, data) if S.log then pcall(S.log.event, name, data) end end
local function emit(name, data) if S.bridge then pcall(S.bridge.emit_event, name, data) end end

function M.now() return S.now end
function M.current() return S.action end

function M.following()
    local a = S.action
    return a and a.kind == "follow" and a.player or nil
end

-- ------------------------------------------------------------------ action plumbing
local function finish(a, ok, reason, data, quiet)
    if a.done then return end
    a.done, a.ok, a.reason = true, ok, reason
    if S.action == a then S.action = nil end
    data = data or {}
    if a.cleanup then pcall(a.cleanup, a) end
    log("action_end", { kind = a.kind, id = a.id, ok = ok, reason = reason })
    if a.async then S.bridge.reply(a.id, { ok = ok, reason = reason, data = data }) end
    if quiet then return end
    if ok then emit("task_done", { task_id = a.id, data = jsonutil.object(data) })
    else emit("task_failed", { task_id = a.id, reason = reason or "body_error" }) end
end
M._finish = finish

local function preempt(by)
    local prev = S.action
    if prev then finish(prev, false, "interrupted", { by = by }, prev.kind == "follow") end
    return prev
end

local function start(a)
    preempt(a.kind)
    a.started = S.now
    S.action = a
    log("action_start", { kind = a.kind, id = a.id })
    return a
end

function M.tick()
    S.now = S.now + M.TICK_MS
    local a = S.action
    if not a then return end
    local ok, err = pcall(a.step, a)
    if not ok then
        log("action_step_error", { kind = a.kind, err = tostring(err) })
        finish(a, false, "body_error", { detail = tostring(err) })
    end
end

-- ------------------------------------------------------------------ native wrappers
local function move_status(c)
    local s = U.try(function() return c:GetMoveStatus() end)
    return tonumber(s)
end

local function move_to_actor(c, goal, accept_cm)
    local ok, res = U.call(S.log, "MoveToActor", { goal = U.short(goal), accept = accept_cm }, function()
        return c:MoveToActor(goal, accept_cm, true, true, true, nil, true)
    end)
    return ok and tonumber(res) or (ok and 2 or REQ_FAILED)
end

local function move_to_location(c, dest, accept_cm)
    local ok, res = U.call(S.log, "MoveToLocation", { dest = dest, accept = accept_cm }, function()
        return c:MoveToLocation(dest, accept_cm, true, true, true, false, nil, true)
    end)
    return ok and tonumber(res) or (ok and 2 or REQ_FAILED)
end

local function stop_movement(c)
    if c then U.call(S.log, "StopMovement", {}, function() c:StopMovement() end) end
end

-- ------------------------------------------------------------------ entities
local function ai_kind(name)
    local k = (name or ""):gsub("^BP_AI_", ""):gsub("_Character_C.*$", ""):gsub("_C_%d+$", "")
    return k:lower()
end

local function all_ai()
    local out = {}
    for _, ai in ipairs(U.try(FindAllOf, M.AI_CLASS) or {}) do
        if U.valid(ai) then out[#out + 1] = ai end
    end
    return out
end

-- Target by exact entity id, else nearest whose id/kind contains `want` (case-insensitive).
local function find_ai(want, origin, max_cm)
    if type(want) ~= "string" or want == "" then return nil end
    local lw = want:lower()
    local best, best_d
    for _, ai in ipairs(all_ai()) do
        local id = U.short(ai)
        if id == want then return ai, U.dist(origin, U.loc(ai)) end
        if id and (id:lower():find(lw, 1, true) or ai_kind(id):find(lw, 1, true)) then
            local d = U.dist(origin, U.loc(ai))
            if d <= (max_cm or math.huge) and (not best_d or d < best_d) then best, best_d = ai, d end
        end
    end
    return best, best_d
end

local function attitude_hostile(ai, p)
    if os.getenv("DW_STATE_ATTITUDE") ~= "1" or not p then return nil end
    local lib = U.try(StaticFindObject, M.AI_LIB)
    if not U.valid(lib) then return nil end
    local a = tonumber(U.try(function() return lib:GetAttitude(ai, p) end))
    if a == nil then return nil end
    return a == 2 -- ETeamAttitude::Hostile
end

-- ------------------------------------------------------------------ get_state
M.NOT_IMPLEMENTED = { "inventory", "nearby_resources", "structures", "places" }

function M.get_state()
    local p = S.puppet.get()
    local players = U.split_pawns()
    local here = p and U.loc(p)
    local origin = here or (players[1] and U.loc(players[1]))
    local pl = {}
    for _, pawn in ipairs(players) do
        local at = U.loc(pawn)
        pl[#pl + 1] = {
            name = U.player_name(pawn) or null, player_id = U.player_id(pawn) or null,
            position = U.to_wire(at) or null, distance = here and U.cm_to_m(U.dist(here, at)) or null,
        }
    end
    local ents = {}
    if origin then
        for _, ai in ipairs(all_ai()) do
            local at = U.loc(ai)
            local d = U.dist(origin, at)
            if d <= M.NEARBY_CM then
                local id = U.short(ai)
                local hp = U.health(ai)
                local follower = U.try(function() return ai:IsFollower() end) == true
                local hostile
                if follower then hostile = false else hostile = attitude_hostile(ai, p) end
                ents[#ents + 1] = {
                    id = id, kind = ai_kind(id), position = U.to_wire(at), hp = hp or null,
                    hostile = hostile == nil and null or hostile, follower = follower,
                    alive = hp == nil or hp > 0, distance = U.cm_to_m(d), _d = d,
                }
            end
        end
        table.sort(ents, function(a, b) return a._d < b._d end)
        for i = #ents, M.NEARBY_MAX + 1, -1 do ents[i] = nil end
        for _, e in ipairs(ents) do e._d = nil end
    end
    local a = S.action
    local data = {
        position = U.to_wire(here) or null,
        health = p and U.health(p) or null,
        max_health = p and U.max_health(p) or null,
        inventory = jsonutil.object(),
        following = M.following() or null,
        players = pl,
        nearby_entities = ents,
        nearby_resources = {}, structures = {}, places = {},
        gear = jsonutil.object(p and gear.read(p) or {}),
        action = a and a.kind or null,
        puppet = S.puppet.status(),
        not_implemented = M.NOT_IMPLEMENTED,
    }
    if not p then return { ok = false, reason = "companion_down", data = data } end
    return { ok = true, data = data }
end

-- ------------------------------------------------------------------ follow
local function step_follow(a)
    if a.last_eval and S.now - a.last_eval < M.FOLLOW_MS then return end
    a.last_eval = S.now
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local target = U.find_player(a.player, true)
    if not target then return finish(a, false, "unknown_target", { player = a.player }) end
    local c = U.controller_of(p)
    if not c then return finish(a, false, "companion_down", {}) end
    local d = U.actor_dist(p, target)
    if d >= M.FOLLOW_TELEPORT_CM then
        a.far_since = a.far_since or S.now
        if S.now - a.far_since >= M.FOLLOW_TELEPORT_AFTER_MS then
            a.far_since, a.last_issue = nil, nil
            local ok = S.puppet.teleport_near(target, 200)
            log("follow_catchup", { dist_cm = d, ok = ok })
            return
        end
    else
        a.far_since = nil
    end
    if d <= a.dist_cm + M.FOLLOW_HYST_CM then return end -- close enough; let the current move finish
    local gap = (move_status(c) == MOVE_IDLE) and M.FOLLOW_MS or M.FOLLOW_REISSUE_MS
    if a.last_issue and S.now - a.last_issue < gap then return end
    a.last_issue = S.now
    local r = move_to_actor(c, target, a.dist_cm)
    a.moves = a.moves + 1
    if r == REQ_FAILED then
        a.failed_moves = a.failed_moves + 1
        if a.failed_moves % 10 == 1 then log("follow_move_failed", { count = a.failed_moves, dist_cm = d }) end
    end
end

local function h_follow(args, ctx)
    local who = args.player
    local dist_m = tonumber(args.distance) or 3.0
    if dist_m < 1 then dist_m = 1 end
    if who == nil or (type(who) ~= "string" and type(who) ~= "number") then
        return { ok = false, reason = "invalid_args", data = { detail = "player is required" } }
    end
    local target = U.find_player(who, true)
    if not target then return { ok = false, reason = "unknown_target", data = { target = who or null } } end
    local p, err = S.puppet.ensure_ready(target)
    if not p then return { ok = false, reason = "companion_down", data = { detail = err } } end
    local a = start({ kind = "follow", id = ctx.id, player = tostring(who), dist_cm = dist_m * 100,
                      moves = 0, failed_moves = 0, step = step_follow })
    step_follow(a) -- first move right away
    if a.done then return { ok = false, reason = a.reason or "body_error", data = { player = a.player } } end
    return { ok = true, data = { following = a.player, distance = dist_m } }
end

-- ------------------------------------------------------------------ stop
local function h_stop()
    local prev = preempt("stop")
    stop_movement(S.puppet.controller())
    return { ok = true, data = { stopped = prev and prev.kind or nil } }
end

-- ------------------------------------------------------------------ go_to
local function arrived(a, here, dest)
    if not (here and dest) then return false end
    if a.actor then return U.dist(here, dest) <= M.GOTO_ACTOR_TOL_CM end
    return U.dist2d(here, dest) <= M.GOTO_TOL_CM and math.abs(here.Z - dest.Z) <= M.GOTO_DZ_CM
end

local function issue_goto(a, c)
    if a.actor then return move_to_actor(c, a.actor, M.GOTO_ACCEPT_CM) end
    return move_to_location(c, a.dest, M.GOTO_ACCEPT_CM)
end

local function step_goto(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    if a.actor and not U.valid(a.actor) then return finish(a, false, "unknown_target", { target = a.target }) end
    local here = U.loc(p)
    local dest = a.actor and U.loc(a.actor) or a.dest
    if arrived(a, here, dest) then
        return finish(a, true, nil, { target_position = U.to_wire(dest), position = U.to_wire(here), arrive_tolerance = a.tol_m })
    end
    if S.now - a.started >= M.GOTO_TIMEOUT_MS then
        return finish(a, false, "timeout", { position = U.to_wire(here), target_position = U.to_wire(dest) })
    end
    if not a.last_pos or U.dist(here, a.last_pos) > M.STUCK_MOVE_CM then
        a.last_pos, a.last_progress = here, S.now
    elseif S.now - a.last_progress >= M.STUCK_MS then
        if a.reissues >= M.MAX_REISSUE then
            return finish(a, false, "path_blocked", { position = U.to_wire(here), target_position = U.to_wire(dest), reissues = a.reissues })
        end
        a.reissues = a.reissues + 1
        a.last_progress = S.now
        local c = U.controller_of(p)
        if c then issue_goto(a, c) end
    end
end

-- target: [x,y,z] metres, a player name/id, or an entity id. Named places are resolved brain-side.
local function resolve_goto(target, origin)
    local dest = U.from_wire(target)
    if dest then return { dest = dest } end
    if type(target) ~= "string" then return nil end
    local pl = U.find_player(target)
    if pl then return { actor = pl } end
    local ai = find_ai(target, origin, M.ATTACK_LEASH_CM)
    if ai then return { actor = ai } end
    return nil
end

local function h_go_to(args, ctx)
    if args.target == nil then return { ok = false, reason = "invalid_args", data = { detail = "target is required" } } end
    local origin = U.loc(S.puppet.get()) or U.loc(U.split_pawns()[1])
    local r = resolve_goto(args.target, origin)
    if not r then return { ok = false, reason = "unknown_target", data = { target = args.target or null } } end
    local p, c = S.puppet.ensure_ready(r.actor and U.is_player_controller(U.controller_of(r.actor)) and r.actor or nil)
    if not p then return { ok = false, reason = "companion_down", data = { detail = c } } end
    local tol_m = r.actor and M.GOTO_ACTOR_TOL_CM / 100
        or U.round(math.sqrt(M.GOTO_TOL_CM ^ 2 + M.GOTO_DZ_CM ^ 2) / 100)
    local a = start({ kind = "go_to", id = ctx.id, async = true, target = args.target, dest = r.dest, actor = r.actor,
                      tol_m = tol_m, reissues = 0, step = step_goto })
    local res = issue_goto(a, c)
    if res == REQ_FAILED then
        a.done = true
        S.action = nil
        local dest = r.dest or U.loc(r.actor)
        return { ok = false, reason = "path_blocked", data = { target_position = U.to_wire(dest) or null, detail = "MoveTo request failed" } }
    end
    return nil -- async: step_goto replies
end

-- ------------------------------------------------------------------ attack
local function attack_set(p, a)
    if a.atk then return a.atk, a.act end
    local held = gear.category(gear.read(p).right) -- nil when unarmed
    local cats = { held or M.DEFAULT_ATTACK_CATEGORY, M.DEFAULT_ATTACK_CATEGORY }
    for _, cat in ipairs(cats) do
        local atk = U.try(StaticFindObject, M.ATTACK_FMT:format(cat, cat, cat))
        local act = U.try(StaticFindObject, M.ACTION_FMT:format(cat, cat, cat))
        if U.valid(atk) and U.valid(act) then
            a.atk, a.act, a.category = atk, act, cat
            return atk, act
        end
    end
    return nil
end

local function swing(a, p, t)
    local atk, act = attack_set(p, a)
    if not atk then return finish(a, false, "body_error", { detail = "attack set not loaded" }) end
    a.last_swing = S.now
    local ok, err = U.call(S.log, "BP_PerformAttack", { target = a.target_id, category = a.category, n = a.swings + 1 }, function()
        p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, {
            Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = t,
        })
    end)
    if ok then
        a.swings = a.swings + 1
    else
        a.errors = a.errors + 1
        if a.errors >= M.ATTACK_MAX_ERRORS then return finish(a, false, "body_error", { detail = tostring(err), swings = a.swings }) end
    end
end

local function step_attack(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local t = a.target
    if not U.valid(t) then
        return finish(a, true, nil, { target = a.target_id, killed = (a.last_hp ~= nil and a.last_hp <= 0) or null, gone = true, swings = a.swings })
    end
    local hp = U.health(t)
    if hp ~= nil then
        a.first_hp = a.first_hp or hp
        a.last_hp = hp
        if hp <= 0 then return finish(a, true, nil, { target = a.target_id, killed = true, swings = a.swings }) end
    end
    if S.now - a.started >= M.ATTACK_TIMEOUT_MS then
        return finish(a, false, "timeout", { target = a.target_id, hp = hp or null, swings = a.swings })
    end
    local d = U.actor_dist(p, t)
    if d > M.ATTACK_LEASH_CM then return finish(a, false, "too_far", { target = a.target_id, distance = U.cm_to_m(d) }) end
    if d > M.ATTACK_RANGE_CM then
        if not a.last_issue or S.now - a.last_issue >= M.ATTACK_APPROACH_REISSUE_MS then
            a.last_issue = S.now
            local c = U.controller_of(p)
            if c then move_to_actor(c, t, M.ATTACK_ACCEPT_CM) end
        end
        return
    end
    if a.last_swing and S.now - a.last_swing < M.ATTACK_COOLDOWN_MS then return end
    if a.swings >= M.ATTACK_INEFFECTIVE_SWINGS and hp ~= nil and a.first_hp ~= nil and hp >= a.first_hp then
        return finish(a, false, "verification_failed", { target = a.target_id, detail = "no damage after " .. a.swings .. " swings", hp = hp })
    end
    swing(a, p, t)
end

local function attack_cleanup(a)
    local c = S.puppet.controller()
    if c then U.call(S.log, "K2_ClearFocus", {}, function() c:K2_ClearFocus() end) end
end

local function h_attack(args, ctx)
    if type(args.target) ~= "string" or args.target == "" then
        return { ok = false, reason = "invalid_args", data = { detail = "target is required" } }
    end
    local origin = U.loc(S.puppet.get()) or U.loc(U.split_pawns()[1])
    local t = find_ai(args.target, origin, M.ATTACK_MAX_CM)
    if not t then return { ok = false, reason = "unknown_target", data = { target = args.target or null } } end
    local hp = U.health(t)
    if hp ~= nil and hp <= 0 then return { ok = false, reason = "unknown_target", data = { target = U.short(t), detail = "already dead" } } end
    local p, c = S.puppet.ensure_ready()
    if not p then return { ok = false, reason = "companion_down", data = { detail = c } } end
    local a = start({ kind = "attack", id = ctx.id, async = true, target = t, target_id = U.short(t), swings = 0, errors = 0,
                      step = step_attack, cleanup = attack_cleanup })
    U.call(S.log, "K2_SetFocus", { target = a.target_id }, function() c:K2_SetFocus(t) end)
    return nil -- async: step_attack replies
end

-- ------------------------------------------------------------------ equip / say / lifecycle
local function h_equip(args)
    if type(args.item_path) ~= "string" or args.item_path == "" then
        return { ok = false, reason = "invalid_args", data = { detail = "item_path is required" } }
    end
    local p, err = S.puppet.ensure_spawned()
    if not p then return { ok = false, reason = "companion_down", data = { detail = err } } end
    local r = gear.equip(S.log, p, args.item_path, { hand = args.hand, actor_class = args.actor_class })
    if r.ok then r.data.persisted = S.puppet.remember_gear(r.data.slot, args.item_path) end
    return r
end

local function h_say(args) return speech.say(S.log, args.text) end

local function h_body_status()
    local a = S.action
    return { ok = true, data = { puppet = S.puppet.status(), action = a and a.kind or null, action_id = a and a.id or null,
                                 following = M.following() or null, now_ms = S.now } }
end

local function h_body_spawn()
    local p, err = S.puppet.ensure_ready()
    if not p then return { ok = false, reason = "companion_down", data = { detail = err } } end
    return { ok = true, data = S.puppet.status() }
end

local function h_body_park()
    preempt("park")
    local ok, err = S.puppet.park("cmd")
    if not ok then return { ok = false, reason = "companion_down", data = { detail = err } } end
    return { ok = true, data = S.puppet.status() }
end

M.HANDLERS = {
    get_state = function() return M.get_state() end,
    follow = h_follow, stop = h_stop, go_to = h_go_to, attack = h_attack,
    equip = h_equip, say = h_say,
    body_status = h_body_status, body_spawn = h_body_spawn, body_park = h_body_park,
}

-- Probe contract (BRIDGE_PROTOCOL.md "Fallback for bodies without capabilities"): a cmd with
-- args.probe == true only asks whether the tool exists. Answer ok without acting; this matters
-- most for stop and follow. Every handler registered here is wrapped.
local function probe_guard(name, fn)
    return function(args, ctx)
        if type(args) == "table" and args.probe == true then
            return { ok = true, data = { probe = true, tool = name } }
        end
        return fn(args or {}, ctx)
    end
end
M._probe_guard = probe_guard

-- Handlers that exist but only answer not_implemented: left out of `capabilities`.
M.STUB_TOOLS = {}

-- capabilities: every tool with a real handler (dynamic, so debug_run/companion_status etc. show up
-- too; the brain ignores non-protocol names). bridge.lua's own stub get_state is replaced by ours.
local function h_capabilities()
    local tools = {}
    for name in pairs(S.bridge.handlers) do
        if not M.STUB_TOOLS[name] then tools[#tools + 1] = name end
    end
    table.sort(tools)
    return { ok = true, data = { tools = tools } }
end

-- opts: {puppet = body.puppet module (default require), no_loop = true for tests}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod
    S.puppet = opts.puppet or require("body.puppet")
    for name, fn in pairs(M.HANDLERS) do bridge.handlers[name] = probe_guard(name, fn) end
    bridge.handlers.capabilities = h_capabilities
    if not opts.no_loop and not S.loop then
        S.loop = LoopInGameThreadWithDelay(M.TICK_MS, function()
            local ok, err = pcall(M.tick)
            if not ok then log("skills_tick_error", { err = tostring(err) }) end
        end)
    end
    log("skills_registered", { tick_ms = M.TICK_MS })
    return M
end

-- Test hook.
function M._reset()
    if S.loop and CancelDelayedAction then pcall(CancelDelayedAction, S.loop) end
    S.now, S.action, S.loop = 0, nil, nil
end

return M
