-- shoot: fire the held ranged weapon at a THING (not a creature), on Claude's own client. Coverage audit §10 gap 2
-- (Rune Mysteries): rune essence floats above the geysers and must be "hit out of the sky (most easily with an arrow
-- or an attack from a staff), then they fall to the ground to be mined" (wiki "Rune Essence"); the same for the Pure
-- Essence stone at anima vents (wiki "Pure Essence": shoot it down with arrows or combat spells).
-- Real player path only:
--   * the held weapon's own inputs (PlayerInputBufferInputActions via combat.actions): bow/crossbow = hold the
--     secondary (aim) until full accuracy, then the primary (fire); a staff/wand = the primary (its magic shot);
--   * the camera aimed with ranged.lua's solution (gravity drop, learned per launcher) at the thing's position;
--   * verified from the TARGET's own state: its health fell, it dropped (Z) or it is gone; the shot's projectile is
--     sampled for ranged.lua's learning. The fallen rock is then the model's to mine (gather), the inventory
--     delta comes from that gather; a destroyed thing's drops are listed if they appear.
-- Never damage writes, never a server RPC. The model picks what to shoot and with what (equip first).
-- W = the engine touches (tests replace them). Live state in _G.DWShoot.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    max_m = 30, keep_m = 14, min_m = 3,  -- shoot from up to max_m; walk to about keep_m when farther
    aim_s = 1.0,                          -- aim hold when the game's full-accuracy time can't be read
    fire_frames = 2, shots = 6,           -- presses per shot; shots per call
    verify_s = 2.5,                       -- after a shot: wait this long for the target to react
    fell_cm = 80,                         -- the target dropped at least this much = knocked down
    approach_timeout_s = 45, lease_s = 5, decide_s = 0.05, timeout_s = 120,
}

local function C()
    local c = rawget(_G, "DWShoot")
    if not c then c = { gen = 0, counts = { jobs = 0, shots = 0, hits = 0 }, lines = {} }; _G.DWShoot = c end
    return c
end
M._state = C
local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "shoot: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
local function num(v) return type(v) == "number" and v or nil end
local function d3(a, b) if not (a and b) then return math.huge end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

M.mods = {}
function M.set_modules(t) for k, v in pairs(t) do M.mods[k] = v end end
local function mod(name)
    if not M.mods[name] then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/" .. name .. ".lua"))() end)
        if ok then M.mods[name] = m end
    end
    return M.mods[name]
end
local function mcall(name, fn, ...)
    local m = mod(name)
    if not (m and m[fn]) then return nil, "no " .. name .. "." .. fn end
    local ok, r = pcall(m[fn], ...)
    if not ok then return nil, tostring(r) end
    return r
end

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    if not ctx then return nil end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return (ok and type(t) == "number") and t or nil
end
function W.pc() local s = mod("sense"); return s and s.local_pc and s.local_pc() or nil end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.loc(a) return U.loc(a) end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
function W.actions(pawn) return mcall("combat", "actions", pawn) or {} end
-- What he holds, as a shooter: {kind = "ranged" | "magic", name, item} | nil (from the item catalog's kind)
function W.weapon(pawn)
    local inv = mod("inventory")
    local h = inv and inv.held and U.try(inv.held, pawn) or {}
    local items = (mcall("combat", "weapons") or {}).items or {}
    for _, it in ipairs({ h.right_item, h.left_item }) do
        local p = it and items[it]
        if p and (p.kind == "ranged" or p.kind == "magic") then return { kind = p.kind, item = it, name = p.name or it } end
    end
    return nil, h.right or h.left
end
function W.params(pawn) local Rg = mod("ranged"); return Rg and Rg.read_weapon_params and Rg.read_weapon_params(pawn) or nil end
function W.muzzle(pawn) local Rg = mod("ranged"); return Rg and Rg.muzzle(pawn, Rg.ranged_component(pawn)) end
function W.camera(pc) local Rg = mod("ranged"); return Rg and Rg.camera_location(pc) end
function W.projectiles() local Rg = mod("ranged"); return Rg and Rg.projectile_ids() or {} end
function W.face(pc, rot) pcall(function() pc:SetControlRotation(rot) end) end
function W.gate()
    local inp = mod("input")
    if not (inp and inp.gate) then return nil end
    local ok, m = pcall(inp.gate)
    return ok and m or nil
end
function W.inject(action)
    local inp = mod("input")
    if inp and inp.raw_inject then return inp.raw_inject(action) == true end
    local cb = mod("combat")
    local f = cb and (cb.inject or cb._inject)
    return f and f(action) or false
end
-- The target's state: {pos, hp, alive}
function W.target_state(actor)
    if not U.alive(actor) then return { alive = false } end
    return { alive = true, pos = U.loc(actor), hp = num(U.health(actor)) }
end
function W.go_to(log, p, tol_m) return mcall("move", "go_to", log, { p.X / 100, p.Y / 100, p.Z / 100 }, { tolerance_m = tol_m, timeout_s = M.cfg.approach_timeout_s }) end
function W.move_status() return mcall("move", "status") or {} end
function W.move_stop(log) return mcall("move", "stop", log) end
function W.ranged() return mod("ranged") end

-- ------------------------------------------------------------------ the job
local function result_of(J, ok, reason, data)
    data = data or {}
    data.target, data.target_name, data.weapon = J.thing.id, J.thing.name, J.weapon and J.weapon.name
    data.shots, data.hits = J.shots, J.hits
    data.last_miss_cm = J.last_miss_cm
    return { ok = ok == true, reason = reason, data = data }
end
local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle, J.hold, J.fire = nil, nil, nil
    if J.moving and not paused() then pcall(W.move_stop, J.log); J.moving = false end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data and res.data.detail or "")))
end
local function fail(J, reason, why, detail) return finish(J, result_of(J, false, reason, { why = why, detail = detail })) end
local function set_phase(J, ph, note) J.phase, J.phase_t = ph, J.t; say(J.log, "phase " .. ph .. (note and (" " .. note) or "")) end

-- knocked down / destroyed / damaged? -> "fell" | "destroyed" | "damaged" | nil
function M.outcome(s0, s1, fell_cm)
    if not s1 or s1.alive == false then return "destroyed" end
    if s0 and s0.pos and s1.pos and (s0.pos.Z - s1.pos.Z) >= (fell_cm or M.cfg.fell_cm) then return "fell" end
    if s0 and s0.hp and s1.hp and s1.hp < s0.hp - 0.01 then return "damaged" end
    return nil
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if paused() then
        J.done = true
        if J.handle then pcall(CancelDelayedAction, J.handle) end
        J.result = result_of(J, false, "interrupted", { why = "world_teardown", detail = "The world is reloading." })
        if c.job == J then c.job = nil end
        local arb = mod("arbiter")
        if arb and J.token then J.released = true; pcall(arb.release, nil, J.token, "paused") end
        return
    end
    local pawn = W.pawn(J.pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn) or J.t
    if J.suspended then return end
    local ts = W.target_state(J.actor)
    -- per frame: aim at the target while aiming; hold / fire inputs (own input modes allowed: the bow's aim mode)
    local me = W.loc(pawn)
    if J.aiming and ts.alive and ts.pos then
        J.aimer:observe(J.t, ts.pos)
        local rot, sol = J.aimer:solve(W.muzzle(pawn), W.camera(J.pc), { aim_z = 0 })
        if rot then W.face(J.pc, rot); J.sol = sol; J.sol_why = nil else J.sol = nil; J.sol_why = sol end
    end
    local modal = W.gate()
    local blocked = modal and modal.kind ~= "mode"
    if blocked and (J.hold or J.fire) then
        return fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't shoot.", tostring(modal.kind)))
    end
    if J.hold then W.inject(J.hold) end
    if J.fire then W.inject(J.fire.act); J.fire.frames = J.fire.frames - 1; if J.fire.frames <= 0 then J.fire = nil end end
    if J.shot then -- sample the projectile for learning
        if not J.shot.proj then
            for id, a in pairs(W.projectiles()) do if not J.shot.ids_before[id] then J.shot.proj = a; break end end
        end
        local pp = J.shot.proj and U.alive(J.shot.proj) and U.loc(J.shot.proj) or nil
        J.aimer:sample(J.t, pp, ts.pos)
    end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; J.hold, J.fire, J.aiming = nil, nil, false; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over, so I stopped shooting." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return fail(J, "companion_down", "died", "I died.") end
    if J.t - J.t0 > M.cfg.timeout_s then return fail(J, "timeout", "timeout", "I've been shooting for two minutes; giving up.") end
    if not ts.alive and J.phase ~= "verify" then
        if (J.hits or 0) > 0 then return finish(J, result_of(J, true, nil, { outcome = "destroyed", detail = "It broke." })) end
        return fail(J, "unknown_target", "target_gone", string.format("The %s is gone.", tostring(J.thing.name or "target")))
    end
    local dist = (me and ts.pos) and d3(me, ts.pos) / 100 or nil
    if J.phase == "approach" then
        if dist and dist <= M.cfg.max_m and dist >= M.cfg.min_m and J.sol_why ~= "out_of_range" then
            if J.moving then W.move_stop(J.log); J.moving = false end
            return set_phase(J, "aim")
        end
        if not J.moving then
            local goal = ts.pos
            if dist and dist < M.cfg.min_m and me then -- too close: step back along the line
                goal = { X = me.X + (me.X - ts.pos.X), Y = me.Y + (me.Y - ts.pos.Y), Z = me.Z }
            end
            W.go_to(J.log, goal, M.cfg.keep_m)
            J.moving, J.move_t = true, J.t
        end
        local st = W.move_status() or {}
        local res = st.result or {}
        if res.status == "failed" or J.t - (J.move_t or J.t) > M.cfg.approach_timeout_s then
            J.moving = false
            return fail(J, "path_blocked", "cant_get_in_range", string.format("I can't get within %d m of the %s (it's %.0f m away).",
                M.cfg.max_m, tostring(J.thing.name or "target"), dist or -1))
        end
        if res.status == "arrived" then J.moving = false end
        return
    end
    if J.phase == "aim" then
        if not J.aiming then
            J.aiming, J.aim_t0 = true, J.t
            if J.weapon.kind == "ranged" and J.acts.secondary then J.hold = J.acts.secondary end
        end
        if J.sol_why == "out_of_range" then J.aiming, J.hold = false, nil; return set_phase(J, "approach", "out of the projectile's range") end
        local need = J.weapon.kind == "ranged" and (J.prm.full_accuracy_s or M.cfg.aim_s) or 0.3
        if J.t - J.aim_t0 >= need and J.sol then
            J.s0 = ts
            J.shot = J.aimer:fired(J.t, J.sol, W.projectiles(), W.muzzle(pawn))
            J.fire = { act = J.acts.primary, frames = M.cfg.fire_frames }
            J.shots = (J.shots or 0) + 1
            C().counts.shots = C().counts.shots + 1
            return set_phase(J, "verify", "shot " .. J.shots)
        end
        return
    end
    if J.phase == "verify" then
        if J.fire then return end
        J.hold = nil
        local out = M.outcome(J.s0, ts, M.cfg.fell_cm)
        if out or J.t - J.phase_t >= M.cfg.verify_s then
            local res = J.aimer:finish(out ~= nil)
            J.shot = nil
            if res and res.miss and res.miss.dist_cm then J.last_miss_cm = math.floor(res.miss.dist_cm) end
            if out then
                J.hits = (J.hits or 0) + 1
                C().counts.hits = C().counts.hits + 1
                if out == "fell" or out == "destroyed" then
                    return finish(J, result_of(J, true, nil, { outcome = out, now_at = ts.pos and { ts.pos.X / 100, ts.pos.Y / 100, ts.pos.Z / 100 } or nil,
                        detail = out == "fell" and string.format("I knocked the %s down; it's on the ground now.", tostring(J.thing.name or "target"))
                            or string.format("The %s broke.", tostring(J.thing.name or "target")) }))
                end
                -- damaged but still up: shoot again
            end
            J.aiming = false
            if J.shots >= J.max_shots then
                if (J.hits or 0) > 0 then
                    return fail(J, "verification_failed", "not_down_yet", string.format("I hit the %s %d time(s) but it's still up.", tostring(J.thing.name or "target"), J.hits))
                end
                return fail(J, "verification_failed", "missed", string.format("All %d of my shots missed the %s%s.", J.shots, tostring(J.thing.name or "target"),
                    J.last_miss_cm and string.format(" (closest about %.1f m off)", J.last_miss_cm / 100) or ""))
            end
            if J.weapon.kind == "ranged" and J.prm_now then
                local p = W.params(pawn)
                if p and p.has_ammo == false then return fail(J, "not_enough_resources", "no_ammo", "I'm out of ammunition.") end
            end
            return set_phase(J, "aim", "again")
        end
    end
end
M._frame = frame

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local api = ctx and ctx.api
    if type(args.target) ~= "string" or args.target == "" then
        return { ok = false, reason = "invalid_args", data = { detail = "target (an id from look) is required" } }
    end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local thing = api and api.find_thing and api.find_thing(args.target, 80)
    local actor = thing and api.actor_of and api.actor_of(thing)
    if not actor then return { ok = false, reason = "unknown_target", data = { why = "unknown_target", detail = "I can't see that." } } end
    if thing.category == "players" then return { ok = false, reason = "unsafe", data = { why = "player", detail = "I never shoot at players." } } end
    if thing.category == "creatures" then
        return { ok = false, reason = "invalid_args", data = { why = "creature", detail = "That's a creature: attack is for creatures." } }
    end
    local wpn, holding = W.weapon(pawn)
    if not wpn then
        return { ok = false, reason = "wrong_tool", data = { why = "no_ranged_weapon", detail = string.format(
            "I need a bow, crossbow or staff in my hands to shoot that%s.", holding and (" (I'm holding " .. tostring(holding) .. ")") or "") } }
    end
    local prm = wpn.kind == "ranged" and (W.params(pawn) or {}) or {}
    if wpn.kind == "ranged" and prm.has_ammo == false then
        return { ok = false, reason = "not_enough_resources", data = { why = "no_ammo", detail = string.format("My %s has no ammunition equipped.", wpn.name) } }
    end
    local acts = W.actions(pawn)
    if not acts.primary then return { ok = false, reason = "body_error", data = { detail = "I can't find my attack input." } } end
    local Rg = W.ranged()
    if not Rg then return { ok = false, reason = "not_implemented", data = { detail = "My aiming module isn't loaded." } } end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_shoot", detail = "A new shot started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "shoot", level = "command", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.hold, J.fire, J.aiming = nil, nil, false end end,
            on_resume = function() if J and not J.done then J.suspended, J.moving = false, false; set_phase(J, "approach", "resumed"); return true end return false end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else." })) end end })
        if not r.ok then return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = "I'm busy with something else." } } end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn) or 0
    local key = tostring(wpn.item) .. "|" .. tostring(prm.ammo or "?")
    local seed = prm.speed and { speed = prm.speed, gz = prm.gz or Rg.cfg.default_gz, t0 = prm.t0 or 0, source = "game_data" } or nil
    J = { gen = c.gen, log = log, pc = pc, thing = thing, actor = actor, weapon = wpn, prm = prm, prm_now = true, acts = acts, token = token,
          aimer = Rg.new_aimer(key, seed), t0 = t, t = t, phase_t = t, shots = 0, hits = 0,
          max_shots = math.max(1, math.min(math.floor(tonumber(args.shots) or M.cfg.shots), 12)) }
    c.job = J
    set_phase(J, "approach", string.format("%s at %s with %s", tostring(thing.name), tostring(thing.id), tostring(wpn.name)))
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "I stopped shooting." })) end
    return { ok = true }
end
function M.status() local c = C(); return { ok = true, job = c.job and { phase = c.job.phase, shots = c.job.shots } or nil, last = c.last, counts = c.counts, lines = c.lines } end

M.HANDLERS = {
    shoot = function(log, args, ctx)
        local r = M.start(log, args or {}, ctx)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "shoot", id = ctx and ctx.id, timeout_s = M.cfg.timeout_s + 15 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "shoot job vanished" } }
        end
        return { pending = a }
    end,
    shoot_status = function() return M.status() end,
}
M.NEEDS = { shoot = { { "sense", "local_pc" }, { "combat", "actions" }, { "move", "go_to" }, { "move", "status" } } }
do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        shoot = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 135, detail_is_speech = true,
            description = "Shoot a thing that isn't a creature (e.g. a floating rock, something out of reach) with the bow, crossbow "
                .. "or staff you hold (equip it first): gets in range, aims, fires, and checks it fell, broke or took damage. "
                .. "For creatures use attack.",
            args = { type = "object", required = { "target" }, properties = obj({
                target = { type = "string", description = "An id from look." },
                shots = { type = "integer", minimum = 1, maximum = 12, default = 6, description = "Shots at most." } }) },
            ground = obj({ target = "thing" }),
            reasons = { "unknown_target", "wrong_tool", "not_enough_resources", "path_blocked", "verification_failed", "unsafe",
                        "invalid_args", "interrupted", "timeout", "companion_down" } },
        shoot_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Shoot job state (debug)." },
    }
end

return M
