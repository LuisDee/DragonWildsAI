-- agility: AGILITY COURSES on Claude's own client (M3 every-skill coverage; design
-- docs/design/every-skill-coverage.md §6), through the game's own client paths only:
--
--   courses  the game's course starters (C++ class AAgilityCourseStarter, by class family): position, the
--            course name and minimum level from its TimeTrialDataAsset, and his level in the starter's own
--            AgilitySkill (SkillComponent:GetSkillLevel), so no skill or course names live in code.
--   start    walk to the starter, face it until the game's interact detector targets it, ONE interact press
--            (what a player's E does; the game shows the start banner), then the banner's own button handler
--            (UAgilityCourse_StartBanner:OnStartCourseButtonClicked, what the Start click runs) [UNVERIFIED];
--            verified by the pawn's IsRunningAgilityCourse().
--   run      go to the next orb (the running AAgilityCourseManager's NextOrbInSequence, else the nearest
--            visible orb) through move.lua's public go_to (its jumps / learned links); an orb is collected by
--            touching it (the game's overlap), verified by the orb hiding / the next orb changing.
--   done     the course stops running: ok when his Agility XP rose (the harness reads the same rows), else
--            the truthful reason (left the zone, died, timed out, couldn't reach orb N and where it is).
--   Never a server RPC (Server_StartCourse etc. are the game's own reaction to the banner), never a write.
-- Passive Agility XP from walking (UAgilitySettings.WalkingXPEventTriggerDistance) needs no tool: any go_to,
-- follow or explore earns it.
-- W = the engine touches (tests replace them). Live state in _G.DWAgility (hot reload safe).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    radius_m = 200, max_radius_m = 400,
    starter_class = "AgilityCourseStarter", manager_class = "AgilityCourseManager", orb_class = "AgilityOrb",
    banner_class = "AgilityCourse_StartBanner",
    stand_tol_m = 1.2, reach_m = 3.0, face_s = 3.0, presses = 2,
    banner_wait_s = 4, start_wait_s = 10,
    orb_tol_m = 0.6, orb_timeout_s = 30, orb_retries = 2,
    course_timeout_s = 360, approach_timeout_s = 120,
    lease_s = 5, decide_s = 0.1, rows = 6,
}

local function C()
    local c = rawget(_G, "DWAgility")
    if not c then c = { gen = 0, counts = { jobs = 0, done = 0, failed = 0 }, lines = {} }; _G.DWAgility = c end
    return c
end
M._state = C
local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "agility: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
local function r1(x) return type(x) == "number" and math.floor(x * 10 + 0.5) / 10 or nil end
local function d2(a, b) if not (a and b) then return math.huge end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end

local L = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua)
M.mods, M.set_modules = L.mods, L.set_modules
local mod, mcall = L.mod, L.mcall

-- ------------------------------------------------------------------ pure
-- Starter rows -> courses near `me` with what stops him (level). rows: {id, pos, name, min_level, my_level}
function M.courses(rows, me, radius_cm)
    local out = {}
    for _, r in ipairs(rows or {}) do
        local d = d2(me, r.pos)
        if d <= (radius_cm or math.huge) then
            local c = { id = r.id, name = r.name, min_level = r.min_level, my_level = r.my_level, distance_m = r1(d / 100), pos = r.pos }
            if r.min_level and r.my_level and r.my_level < r.min_level then c.locked = string.format("needs level %d (I'm %d)", r.min_level, r.my_level) end
            out[#out + 1] = c
        end
    end
    table.sort(out, function(a, b) return (a.distance_m or 0) < (b.distance_m or 0) end)
    return out
end

-- The orb to run to: the manager's next orb when readable, else the nearest visible orb not yet taken.
function M.pick_orb(next_orb, orbs, me, taken)
    if next_orb and next_orb.pos and not (taken or {})[next_orb.id] then return next_orb end
    local best, bd
    for _, o in ipairs(orbs or {}) do
        if o.visible ~= false and not (taken or {})[o.id] then
            local d = d2(me, o.pos)
            if not bd or d < bd then best, bd = o, d end
        end
    end
    return best
end

-- Words for where an orb is relative to him (for the failure sentence).
function M.where(me, p)
    local d = d2(me, p) / 100
    local dz = ((p.Z or 0) - (me.Z or 0)) / 100
    local up = dz > 1.5 and string.format(", %.0f m higher", dz) or (dz < -1.5 and string.format(", %.0f m lower", -dz) or "")
    return string.format("%.0f m away%s", d, up)
end

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
function W.pc() return mcall("sense", "local_pc") end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.loc(a) return U.loc(a) end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
function W.skills() local me = mcall("sense", "me"); return type(me) == "table" and me.skills or nil end
local function asset_field(asset, k)
    return U.try(function() return asset[k] end) or U.try(function() return asset.TimeTrialData[k] end)
end
function W.starters(pc)
    local sc = pc and U.try(function() return pc.SkillComponent end)
    local out = {}
    for _, a in ipairs(U.find_all(M.cfg.starter_class, { skip_defaults = true }) or {}) do
        if U.alive(a) then
            local asset = U.try(function() return a.TimeTrialDataAsset end)
            local skill = U.try(function() return a.AgilitySkill end)
            out[#out + 1] = { id = U.short(a), actor = a, pos = U.loc(a),
                name = U.valid(asset) and text(asset_field(asset, "DisplayName")) or U.short(asset),
                min_level = U.valid(asset) and num(asset_field(asset, "MinSkillLevel")) or nil,
                my_level = (U.valid(sc) and U.valid(skill)) and num(U.try(function() return sc:GetSkillLevel(skill) end)) or nil }
        end
    end
    return out
end
function W.running(pawn) return U.try(function() return pawn:IsRunningAgilityCourse() end) == true end
function W.orbs()
    local out = {}
    for _, o in ipairs(U.find_all(M.cfg.orb_class, { skip_defaults = true }) or {}) do
        if U.alive(o) then
            local vis = U.try(function() return o.AgilityCourseComponent:IsVisible() end)
            out[#out + 1] = { id = U.short(o), pos = U.loc(o), visible = vis ~= false, xp = num(U.try(function() return o.XPGainedByPickup end)) }
        end
    end
    return out
end
function W.next_orb(pawn)
    for _, m in ipairs(U.find_all(M.cfg.manager_class, { skip_defaults = true }) or {}) do
        local runner = U.try(function() return m.PlayerCharacterRunningCourse end)
        if U.valid(runner) and U.short(runner) == U.short(pawn) then
            local soft = U.try(function() return m.NextOrbInSequence end)
            local o = soft and (U.try(function() return soft:Get() end) or U.try(function() return soft:LoadSynchronous() end))
            if U.valid(o) then return { id = U.short(o), pos = U.loc(o) } end
        end
    end
    return nil
end
function W.target(pawn) return mcall("inventory", "interact_target", pawn) end
function W.press(log) return mcall("inventory", "press_interact", log) end
function W.banner()
    local b = U.find_first(M.cfg.banner_class)
    if not U.valid(b) then return nil end
    local vis = U.try(function() return b:IsInViewport() end)
    if vis == false then return nil end
    return b
end
function W.click_start(b) return pcall(function() b:OnStartCourseButtonClicked() end) end
function W.face(pc, yaw) pcall(function() pc:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }) end) end
function W.go_to(log, p, tol_m, timeout_s)
    return mcall("move", "go_to", log, { p.X / 100, p.Y / 100, p.Z / 100 }, { tolerance_m = tol_m, timeout_s = timeout_s, sprint = true })
end
function W.move_status() return mcall("move", "status") or {} end
function W.move_stop(log) return mcall("move", "stop", log) end
function W.gate()
    local inp = mod("input")
    if not (inp and inp.gate) then return nil end
    local ok, m = pcall(inp.gate)
    return ok and m or nil
end
function W.claim(kind, owner) local inp = mod("input"); if inp and inp.claim then pcall(inp.claim, kind, owner) end end
function W.release(kind) local inp = mod("input"); if inp and inp.release then pcall(inp.release, kind) end end

-- ------------------------------------------------------------------ the job
local function xp_delta(s0, s1)
    local by = {}
    for _, r in ipairs(s0 or {}) do if r.skill then by[r.skill] = r end end
    local out
    for _, r in ipairs(s1 or {}) do
        local a = r.skill and by[r.skill]
        if a and type(r.xp) == "number" and type(a.xp) == "number" and r.xp > a.xp then
            out = out or {}
            out[r.skill] = { xp = r1(r.xp - a.xp), level = (r.level ~= a.level) and r.level or nil }
        end
    end
    return out
end
M.xp_delta = xp_delta

local function result_of(J, ok, reason, data)
    data = data or {}
    data.course, data.course_name, data.orbs = J.course.id, J.course.name, J.orbs
    data.seconds = (J.run_t and J.t) and r1(J.t - J.run_t) or nil
    data.xp = J.xp
    return { ok = ok == true, reason = reason, data = data }
end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    if J.claimed then W.release("agility_banner"); J.claimed = nil end
    if not paused() then
        if J.moving then pcall(W.move_stop, J.log); J.moving = false end
        J.xp = xp_delta(J.skills0, W.skills()) or J.xp
        res.data.xp = J.xp
    end
    J.result = res
    c.counts[res.ok and "done" or "failed"] = c.counts[res.ok and "done" or "failed"] + 1
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data.detail or "")))
end
local function fail(J, reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return finish(J, result_of(J, false, reason, d))
end
local function set_phase(J, ph, note)
    J.phase, J.phase_t = ph, J.t
    say(J.log, "phase " .. ph .. (note and (" " .. note) or ""))
end

local function start_move(J, p, tol)
    J.goal, J.goal_tol = p, tol
    W.go_to(J.log, p, tol, M.cfg.approach_timeout_s)
    J.moving, J.move_t = true, J.t
end
local function move_done(J, me)
    if me and J.goal and d2(me, J.goal) <= (J.goal_tol or 1) * 100 + 20 and math.abs((me.Z or 0) - (J.goal.Z or 0)) < 250 then
        if J.moving then W.move_stop(J.log); J.moving = false end
        return "arrived"
    end
    local st = W.move_status() or {}
    local res = st.result or {}
    if res.status == "arrived" then J.moving = false; return "arrived" end
    if res.status == "failed" or res.status == "stopped" then J.moving = false; J.move_why = res.reason; return "failed" end
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
        return
    end
    local pawn = W.pawn(J.pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.suspended then return end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over, so I left the course." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return fail(J, "companion_down", "died", "I died on the course.") end
    local me = W.loc(pawn)
    if not me then return end
    local ph = J.phase
    if ph == "approach" then
        if W.running(pawn) then return set_phase(J, "run", "already running") end
        if not J.moving then start_move(J, J.course.pos, M.cfg.stand_tol_m) end
        local m = move_done(J, me)
        if m == "arrived" or (m == "failed" and d2(me, J.course.pos) <= M.cfg.reach_m * 100) then set_phase(J, "press")
        elseif m == "failed" then
            return fail(J, "path_blocked", "cant_reach_start", string.format("I can't get to the start of %s (%s).",
                tostring(J.course.name or "the course"), M.where(me, J.course.pos)))
        end
        return
    end
    if ph == "press" then
        local yaw = math.deg(math.atan(J.course.pos.Y - me.Y, J.course.pos.X - me.X))
        W.face(J.pc, yaw)
        local tg = W.target(pawn)
        if tg and tg.actor == J.course.id then
            local modal = W.gate()
            if modal then
                if J.t - J.phase_t > M.cfg.face_s * 3 then
                    return fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't start the course.", tostring(modal.kind)))
                end
                return
            end
            W.press(J.log)
            J.presses = (J.presses or 0) + 1
            return set_phase(J, "banner")
        end
        if J.t - J.phase_t > M.cfg.face_s then
            return fail(J, "not_interactable", "not_targeted", string.format("I'm at the start of %s but the game won't let me use it%s.",
                tostring(J.course.name or "the course"), tg and tg.actor and (" (it targets " .. tostring(tg.name or tg.prompt or tg.actor) .. ")") or ""))
        end
        return
    end
    if ph == "banner" then
        if W.running(pawn) then return set_phase(J, "run", "started without a banner") end
        local b = W.banner()
        if b then
            W.claim("agility_banner", "agility")
            J.claimed = true
            local ok = W.click_start(b)
            say(J.log, "start banner -> OnStartCourseButtonClicked " .. tostring(ok))
            return set_phase(J, "starting")
        end
        if J.t - J.phase_t > M.cfg.banner_wait_s then
            if (J.presses or 0) < M.cfg.presses then return set_phase(J, "press", "re-press") end
            return fail(J, "verification_failed", "no_banner", string.format(
                "I used the start of %s but no course start came up (maybe the level, or I'm in combat).", tostring(J.course.name or "the course")))
        end
        return
    end
    if ph == "starting" then
        if W.running(pawn) then
            if J.claimed then W.release("agility_banner"); J.claimed = nil end
            J.run_t = J.t
            return set_phase(J, "run")
        end
        if J.t - J.phase_t > M.cfg.start_wait_s then
            return fail(J, "verification_failed", "not_started", string.format("I pressed Start on %s but the course didn't start.", tostring(J.course.name or "the course")))
        end
        return
    end
    if ph == "run" then
        J.run_t = J.run_t or J.t
        local running = W.running(pawn)
        if J.orb and not running then
            -- the finish: the last orb ends the run in the same frame it is collected
            local hid = true
            for _, o in ipairs(W.orbs()) do if o.id == J.orb.id and o.visible ~= false then hid = false end end
            if hid then J.taken[J.orb.id] = true; J.orbs = (J.orbs or 0) + 1; J.orb = nil end
        end
        if not running then
            local xp = xp_delta(J.skills0, W.skills())
            J.xp = xp
            if (J.orbs or 0) > 0 and xp then
                return finish(J, result_of(J, true, nil, { detail = string.format("Finished %s: %d orbs in %.0f s.", tostring(J.course.name or "the course"),
                    J.orbs, J.t - J.run_t) }))
            end
            return fail(J, "verification_failed", "course_ended", string.format("The course ended after %d orbs without a finish.", J.orbs or 0))
        end
        if J.t - J.run_t > M.cfg.course_timeout_s then
            return fail(J, "timeout", "timeout", string.format("I've been on %s for %d minutes; giving up.", tostring(J.course.name or "the course"),
                math.floor(M.cfg.course_timeout_s / 60)))
        end
        local cur = J.orb
        if cur then
            -- collected: it hid, or the manager's next orb moved on
            local nxt = W.next_orb(pawn)
            local hid = true
            for _, o in ipairs(W.orbs()) do if o.id == cur.id and o.visible ~= false then hid = false end end
            if hid or (nxt and nxt.id ~= cur.id) then
                J.taken[cur.id] = true
                J.orbs = (J.orbs or 0) + 1
                J.orb = nil
                say(J.log, "orb " .. J.orbs .. " collected")
                return
            end
            local m = move_done(J, me)
            if m == "failed" or (m == "arrived" and J.t - J.orb_t > 3) or J.t - J.orb_t > M.cfg.orb_timeout_s then
                J.orb_tries = (J.orb_tries or 0) + 1
                if J.orb_tries > M.cfg.orb_retries then
                    return fail(J, "path_blocked", "cant_reach_orb", string.format("I can't reach orb %d (%s)%s.", (J.orbs or 0) + 1,
                        M.where(me, cur.pos), J.move_why and (": " .. tostring(J.move_why)) or ""))
                end
                start_move(J, cur.pos, M.cfg.orb_tol_m)
                J.orb_t = J.t
            end
            return
        end
        local o = M.pick_orb(W.next_orb(pawn), W.orbs(), me, J.taken)
        if not o then return end -- the finish line is the last orb; running stops by itself
        J.orb, J.orb_t, J.orb_tries = o, J.t, 0
        start_move(J, o.pos, M.cfg.orb_tol_m)
    end
end
M._frame = frame

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local me = W.loc(pawn)
    local radius = math.min(tonumber(args.radius) or M.cfg.radius_m, M.cfg.max_radius_m) * 100
    local list = M.courses(W.starters(pc), me, args.course and math.huge or radius)
    local course
    for _, c in ipairs(list) do if not args.course or c.id == args.course then course = c; break end end
    if not course then
        if args.course then return { ok = false, reason = "unknown_target", data = { why = "unknown_course", detail = "I can't find that course." } } end
        return { ok = false, reason = "nothing_in_range", data = { why = "no_course", detail = string.format("I don't know of an agility course within %d m.", radius / 100) } }
    end
    if course.locked then
        return { ok = false, reason = "not_unlocked", data = { why = "level", course = course.id, detail = string.format("%s %s.", tostring(course.name or "That course"), course.locked) } }
    end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_course", detail = "A new course run started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "agility_course", level = "task", resumable = false, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.moving = false end end,
            on_resume = function() if J and not J.done then J.suspended = false; J.moving = false; J.orb = nil; return true end return false end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else, so I left the course." })) end end })
        if not r.ok then return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = "I'm busy with something else." } } end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn)
    J = { gen = c.gen, log = log, pc = pc, course = course, token = token, t0 = t, t = t, phase_t = t, taken = {}, orbs = 0,
          skills0 = W.skills() }
    c.job = J
    set_phase(J, "approach", tostring(course.name) .. " " .. tostring(course.id))
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { course = course.id, name = course.name, distance_m = course.distance_m } }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "I left the course." })) end
    return { ok = true }
end

function M.status()
    local c = C()
    local J = c.job
    return { ok = true, job = J and { phase = J.phase, course = J.course.id, orbs = J.orbs, orb = J.orb and J.orb.id } or nil,
             last = c.last, counts = c.counts, lines = c.lines }
end

local function courses_tool(log, args)
    if paused() then return { ok = false, reason = "companion_down" } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down" } end
    local radius = math.min(tonumber(args and args.radius) or M.cfg.radius_m, M.cfg.max_radius_m)
    local list = M.courses(W.starters(pc), W.loc(pawn), radius * 100)
    local out = {}
    for i, c in ipairs(list) do if i <= M.cfg.rows then c.pos = nil; out[#out + 1] = c end end
    return { ok = true, data = { courses = out, radius_m = radius, running = W.running(pawn) or nil } }
end

M.HANDLERS = {
    agility_course = function(log, args, ctx)
        local r = M.start(log, args or {}, ctx)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "agility_course", id = ctx and ctx.id, timeout_s = M.cfg.course_timeout_s + M.cfg.approach_timeout_s + 30 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "course job vanished" } }
        end
        return { pending = a }
    end,
    agility_courses = function(log, args) return courses_tool(log, args or {}) end,
    agility_status = function() return M.status() end,
}

M.NEEDS = {
    agility_course = { { "sense", "local_pc" }, { "inventory", "interact_target" }, { "inventory", "press_interact" },
                       { "move", "go_to" }, { "move", "status" } },
    agility_courses = { { "sense", "local_pc" } },
}

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        agility_course = { kind = "action", llm = true, moves = true, priority = "task", duration_s = 120, timeout_s = 540,
            detail_is_speech = true,
            description = "Run an agility course: walks to its start, starts it, and runs through its orbs to the finish. "
                .. "Trains Agility (walking anywhere also gives a little Agility XP). See agility_courses.",
            args = { type = "object", properties = obj({
                course = { type = "string", description = "A course id from agility_courses (default: the nearest you can do)." },
                radius = { type = "number", minimum = 10, maximum = M.cfg.max_radius_m, description = "Search radius, m (default 200)." } }) },
            preconditions = { "a course start within the radius", "your level meets the course's minimum" },
            reasons = { "nothing_in_range", "unknown_target", "not_unlocked", "path_blocked", "not_interactable", "verification_failed",
                        "interrupted", "timeout", "companion_down" } },
        agility_courses = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Agility courses near you: name, distance, minimum level vs yours. Read only.",
            args = { type = "object", properties = obj({
                radius = { type = "number", minimum = 10, maximum = M.cfg.max_radius_m, default = 200, description = "Metres." } }) },
            reasons = { "companion_down" } },
        agility_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Agility course job state (debug)." },
    }
end

return M
