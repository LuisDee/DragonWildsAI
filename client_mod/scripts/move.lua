-- move.lua: client-side locomotion for Claude's real game client (route R2,
-- docs/research/2026-10-25-client-side-botting.md decisions 2-4). Real player code paths only:
--   * steering  = pc:SetControlRotation + pawn:AddMovementInput(dir, 1) EVERY frame (what the
--                 IA_Movement handler ends in; a 50 ms cadence jitters, DISCOVERIES R2);
--   * sprint    = Enhanced Input injection of the pawn's own SprintComponent.SprintInputAction
--                 (IA_Player_Sprint) via EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction.
--                 FInputActionValue has NO reflected fields, so the FVector variant is the one
--                 UE4SS can marshal. Fallback: SprintComponent:TryRequestStartSprinting(id);
--   * jump      = pawn:Jump()/StopJumping() (verified); double jump = a second Jump() while
--                 airborne (JumpMaxCount = 2 on Claude);
--   * waypoints = the dev server's navmesh (tools/nav_oracle.py <-> mod/experiments/nav_oracle.lua)
--                 via client_io/nav/req.json -> resp.lua; straight line when there is no path.
-- Never teleports the pawn. One loop (LoopInGameThreadWithDelay(1, ...)), cancellable, and a
-- generation token so a loop from an older load of this file exits on its own.
--
-- API (all take the DWClient `log` function first):
--   M.go_to(log, {x,y,z} metres | "<player name>", opts)   opts: tolerance_m=1.5, sprint_m=10,
--                                                             timeout_s=120, nav=true
--   M.follow(log, player_name, distance_m=3, opts)          keeps following until stop()
--   M.stop(log)   M.status()
-- Units: metres on the API (wire units), centimetres inside.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local NAV_REQ = ROOT .. "/client_io/nav/req.json"
local NAV_RESP = ROOT .. "/client_io/nav/resp.lua"

local M = {}

M.cfg = {
    wp_radius_cm = 120,        -- waypoint reached (2D)
    sprint_on_cm = 1000,       -- sprint when the remaining distance is above this
    sprint_off_cm = 500,       -- ... and stop asking below this
    repath_goal_move_cm = 300, -- a moving goal that drifted this far from the path's end -> repath
    repath_min_s = 1.0,        -- at most one path request per this
    nav_timeout_s = 4.0,       -- no oracle answer in this -> straight line (retry later)
    nav_retry_s = 5.0,         -- after a failed/absent path, ask again this often
    stuck_window_s = 1.0,      -- progress is measured over this window
    stuck_min_cm = 50,         -- less 2D progress than this in a window, while pushing = stuck
    stuck_give_up = 8,         -- go_to fails after this many consecutive stuck windows
    follow_hysteresis_cm = 100,
    log_every_s = 2.0,
}

-- ------------------------------------------------------------------ helpers
local function S() _G.DW_MOVE = _G.DW_MOVE or { gen = 0, mode = "idle" }; return _G.DW_MOVE end

local function local_pc()
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") then
            local ok, isl = pcall(function() return x:IsLocalController() end)
            if not ok or isl then return x end
        end
    end
end

local GS
local function now(ctx)
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return GS:GetRealTimeSeconds(ctx)
end

local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function v(t) return { X = t.X, Y = t.Y, Z = t.Z } end

-- Pawn of the player whose PlayerState name is `name` (case-insensitive), or nil.
local function player_pawn(name, me)
    local want = name:lower()
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        if ps:IsValid() and not ps:GetFullName():find("Default__") then
            local ok, n = pcall(function() return ps:GetPlayerName():ToString() end)
            if ok and n and n:lower() == want then
                local okp, p = pcall(function() return ps.PawnPrivate end)
                if okp and p and p:IsValid() and p ~= me then return p end
            end
        end
    end
end

-- ------------------------------------------------------------------ nav oracle client
local function nav_request(st, from, to)
    st.nav_id = (st.nav_id or 0) + 1
    local f = io.open(NAV_REQ .. ".tmp", "w")
    if not f then return false end
    f:write(string.format('{"id":%d,"from":[%.2f,%.2f,%.2f],"to":[%.2f,%.2f,%.2f]}',
        st.nav_id, from.X / 100, from.Y / 100, from.Z / 100, to.X / 100, to.Y / 100, to.Z / 100))
    f:close()
    os.remove(NAV_REQ)
    os.rename(NAV_REQ .. ".tmp", NAV_REQ)
    st.nav_pending, st.nav_goal = st.nav_id, v(to)
    return true
end

-- The oracle's answer for the pending request, or nil if not there yet.
local function nav_poll(st)
    local f = io.open(NAV_RESP, "r")
    if not f then return nil end
    f:close()
    local chunk = loadfile(NAV_RESP)
    if not chunk then return nil end
    local ok, r = pcall(chunk)
    if ok and type(r) == "table" and r.id == st.nav_pending then return r end
end

-- ------------------------------------------------------------------ input
local function sprint_action(pawn)
    local ok, a = pcall(function() return pawn.SprintComponent.SprintInputAction end)
    return ok and a and a:IsValid() and a or nil
end

local function is_sprinting(pawn)
    local ok, s = pcall(function() return pawn.SprintComponent:IsSprinting() end)
    return ok and s == true
end

-- One frame of "sprint key held". Returns true if the call went through.
local function inject_sprint(st, pawn)
    if st.sprint_route == "broken" then return false end
    local subs = st.eis
    if not (subs and subs:IsValid()) then subs = FindFirstOf("EnhancedInputLocalPlayerSubsystem"); st.eis = subs end
    local act = sprint_action(pawn)
    if not (subs and act) then st.sprint_route = "broken"; return false end
    local ok, err = pcall(function() subs:InjectInputVectorForAction(act, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    if not ok then
        st.sprint_err = tostring(err)
        -- Fallback: what the sprint input handler requests (client-side request + server ack).
        st.sprint_id = ((st.sprint_id or 0) + 1) % 250
        local ok2 = pcall(function() pawn.SprintComponent:TryRequestStartSprinting(st.sprint_id) end)
        st.sprint_route = ok2 and "request" or "broken"
        return ok2
    end
    st.sprint_route = "inject"
    return true
end

local function press_to_sprint(st)
    if st.pts == nil then
        local s = FindFirstOf("DominionUserSettings")
        local ok, b = pcall(function() return s.bPressToSprint end)
        st.pts = ok and b == true
    end
    return st.pts
end

-- ------------------------------------------------------------------ the loop
local function finish(st, result, log)
    st.result = result
    st.mode = "idle"
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    st.handle = nil
    if log then log("move: " .. tostring(result.status) .. " " .. tostring(result.reason or "")) end
end

local function tick(st, gen, log)
    if st.gen ~= gen then return "stale" end
    local pc, pawn = st.pc, nil
    if pc and pc:IsValid() then pawn = pc.Pawn end
    if not (pawn and pawn:IsValid()) then return finish(st, { status = "failed", reason = "no_pawn" }, log) end
    local t = now(pawn)
    local me = pawn:K2_GetActorLocation()
    st.ticks = st.ticks + 1

    -- goal: a point, or a player's pawn (re-resolved if it went away)
    local goal
    if st.target_name then
        if not (st.target and st.target:IsValid()) and t - (st.target_t or 0) > 1.0 then
            st.target, st.target_t = player_pawn(st.target_name, pawn), t
        end
        if not (st.target and st.target:IsValid()) then
            st.status = "target_not_visible"
            if st.mode == "go_to" and t - st.t0 > 10 then return finish(st, { status = "failed", reason = "target_not_visible" }, log) end
            return
        end
        goal = st.target:K2_GetActorLocation()
    else
        goal = st.goal
    end
    local dist = d2(me, goal)
    st.dist_cm = dist

    -- arrival / follow idle
    if st.mode == "go_to" then
        if dist <= st.tol_cm then return finish(st, { status = "arrived", dist_m = dist / 100, s = t - st.t0 }, log) end
        if t - st.t0 > st.timeout_s then return finish(st, { status = "failed", reason = "timeout", dist_m = dist / 100 }, log) end
    else -- follow
        local hold = st.idle and (st.tol_cm + M.cfg.follow_hysteresis_cm) or st.tol_cm
        if dist <= hold then
            st.idle, st.status = true, "near"
            st.stuck_n, st.win_t, st.win_pos = 0, t, v(me)
            return
        end
        st.idle = false
    end

    -- path: request / receive / fall back
    if st.use_nav then
        if st.nav_pending then
            if st.ticks % 4 == 0 then
                local r = nav_poll(st)
                if r then
                    st.nav_pending = nil
                    st.nav_t = t
                    if r.ok and r.points and #r.points >= 2 then
                        local pts = {}
                        for i, p in ipairs(r.points) do pts[i] = { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 } end
                        st.path, st.wp, st.path_partial, st.source = pts, 2, r.partial, "nav"
                        st.path_goal = st.nav_goal
                    else
                        st.path, st.source, st.nav_fail = nil, "straight", r.reason or "no_path"
                    end
                    st.nav_answers = (st.nav_answers or 0) + 1
                elseif t - st.nav_sent_t > M.cfg.nav_timeout_s then
                    st.nav_pending, st.nav_t, st.source, st.nav_fail = nil, t, "straight", "oracle_timeout"
                end
            end
        else
            local since = t - (st.nav_t or -100)
            local need = not st.path and since > M.cfg.nav_retry_s
                or (st.path and st.path_goal and d2(st.path_goal, goal) > M.cfg.repath_goal_move_cm and since > M.cfg.repath_min_s)
                or (st.want_repath and since > M.cfg.repath_min_s)
            if need or not st.nav_t then
                st.want_repath = false
                if nav_request(st, me, goal) then st.nav_sent_t = t; st.nav_requests = (st.nav_requests or 0) + 1 end
            end
        end
    end

    -- current steering point: next waypoint, else the goal itself
    local aim = goal
    local path = st.path
    if path then
        -- skip waypoints already reached, or passed (closer to the next one than this one is)
        while st.wp <= #path do
            local p = path[st.wp]
            local nxt = path[st.wp + 1]
            if d2(me, p) < M.cfg.wp_radius_cm or (nxt and d2(me, nxt) < d2(p, nxt)) then st.wp = st.wp + 1 else break end
        end
        if st.wp <= #path then aim = path[st.wp] end
    end
    local dx, dy = aim.X - me.X, aim.Y - me.Y
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 1 then dx, dy, dl = goal.X - me.X, goal.Y - me.Y, math.max(dist, 1) end
    dx, dy = dx / dl, dy / dl

    -- unstuck manoeuvre in progress: strafe sideways
    if st.strafe_until and t < st.strafe_until then
        dx, dy = dx * 0.3 + st.strafe_dir * -dy, dy * 0.3 + st.strafe_dir * dx
    end

    pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
    pawn:AddMovementInput({ X = dx, Y = dy, Z = 0 }, 1.0, false)
    st.status = "moving"

    -- sprint: far from the goal
    local remaining = dist
    if remaining > M.cfg.sprint_on_cm and st.sprint then st.sprint_want = true
    elseif remaining < M.cfg.sprint_off_cm then st.sprint_want = false end
    if st.sprint_want then
        local sprinting = is_sprinting(pawn)
        if press_to_sprint(st) then
            -- toggle mode: hold the key until sprint starts (max 10 frames), release, retry after 0.5 s
            if not sprinting then
                st.sprint_hold = (st.sprint_hold or 0) + 1
                if st.sprint_hold <= 10 then inject_sprint(st, pawn)
                elseif st.sprint_hold == 11 then st.sprint_rel_t = t
                elseif t - st.sprint_rel_t > 0.5 then st.sprint_hold = 0 end
            else st.sprint_hold = 0 end
        else
            inject_sprint(st, pawn) -- hold mode: hold every frame
        end
        st.sprinting = sprinting
    end

    -- jump sequencing (frame-based): release after 0.25 s; double jump 0.35 s after the first
    if st.jump_t then
        if st.jump_release and t - st.jump_t > 0.25 then pcall(function() pawn:StopJumping() end); st.jump_release = false end
        if st.jump_double and t - st.jump_t > 0.35 then
            pcall(function() pawn:Jump() end); st.jump_double = false; st.jump_t2 = t; st.double_jumps = (st.double_jumps or 0) + 1
        end
        if st.jump_t2 and t - st.jump_t2 > 0.25 then pcall(function() pawn:StopJumping() end); st.jump_t2 = nil end
        if t - st.jump_t > 1.2 then st.jump_t = nil end
    end

    -- stuck detection: 2D progress over a window while we pushed input
    if not st.win_t then st.win_t, st.win_pos = t, v(me) end
    if t - st.win_t >= M.cfg.stuck_window_s then
        local moved = d2(me, st.win_pos)
        st.speed_cms = moved / (t - st.win_t)
        if moved < M.cfg.stuck_min_cm then
            st.stuck_n = st.stuck_n + 1
            st.stuck_total = (st.stuck_total or 0) + 1
            local n = st.stuck_n
            -- ladder: jump -> double jump -> strafe + double jump + repath -> repeat
            if not st.jump_t then
                pcall(function() pawn:Jump() end)
                st.jump_t, st.jump_release = t, true
                st.jump_double = n >= 2
                st.jumps = (st.jumps or 0) + 1
            end
            if n >= 3 then
                st.strafe_dir = (n % 2 == 0) and 1 or -1
                st.strafe_until = t + 0.7
                st.want_repath = true
            end
            if log then log(string.format("move: stuck n=%d moved=%.0fcm d=%.0f src=%s", n, moved, dist, tostring(st.source))) end
            if st.mode == "go_to" and n >= M.cfg.stuck_give_up then
                return finish(st, { status = "failed", reason = "stuck", dist_m = dist / 100 }, log)
            end
        else
            st.stuck_n = 0
        end
        st.win_t, st.win_pos = t, v(me)
    end

    if log and t - (st.log_t or 0) > M.cfg.log_every_s then
        st.log_t = t
        log(string.format("move: %s d=%.0fcm wp=%s/%s src=%s spr=%s spd=%.0f", st.mode, dist, tostring(st.wp),
            tostring(path and #path), tostring(st.source), tostring(st.sprinting), st.speed_cms or 0))
    end
end

local function start(log, mode, opts)
    local st = S()
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local gen = st.gen + 1
    local keep = { gen = gen, nav_id = st.nav_id, eis = st.eis, pts = st.pts }
    for k in pairs(st) do st[k] = nil end
    for k, x in pairs(keep) do st[k] = x end
    st.mode, st.pc, st.ticks, st.stuck_n = mode, pc, 0, 0
    st.t0 = now(pawn)
    st.tol_cm = (opts.tolerance_m or 1.5) * 100
    st.timeout_s = opts.timeout_s or 120
    st.sprint = opts.sprint ~= false
    st.use_nav = opts.nav ~= false
    st.source = st.use_nav and "pending" or "straight"
    if opts.sprint_m then M.cfg.sprint_on_cm = opts.sprint_m * 100; M.cfg.sprint_off_cm = math.min(M.cfg.sprint_off_cm, opts.sprint_m * 50) end
    if type(opts.goal) == "table" then
        st.goal = { X = opts.goal[1] * 100, Y = opts.goal[2] * 100, Z = opts.goal[3] * 100 }
    else
        st.target_name = tostring(opts.goal)
        st.target = player_pawn(st.target_name, pawn)
    end
    st.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(tick, st, gen, log)
        if not ok then
            if log then log("move: tick error " .. tostring(err)) end
            finish(st, { status = "failed", reason = "error", detail = tostring(err) }, log)
        end
    end)
    return { ok = true, mode = mode, gen = gen, target_visible = st.target ~= nil or st.goal ~= nil }
end

function M.go_to(log, goal, opts)
    opts = opts or {}
    opts.goal = goal
    return start(log, "go_to", opts)
end

function M.follow(log, player_name, distance_m, opts)
    opts = opts or {}
    opts.goal = player_name
    opts.tolerance_m = distance_m or 3
    return start(log, "follow", opts)
end

function M.stop(log)
    local st = S()
    local was = st.mode
    st.gen = st.gen + 1 -- any running loop exits on its next frame even if the cancel misses
    finish(st, { status = "stopped" }, log)
    pcall(function() local pc = local_pc(); if pc and pc.Pawn then pc.Pawn:StopJumping() end end)
    return { ok = true, was = was }
end

function M.status()
    local st = S()
    return {
        mode = st.mode, status = st.status, result = st.result, target = st.target_name,
        dist_m = st.dist_cm and math.floor(st.dist_cm) / 100, source = st.source, nav_fail = st.nav_fail,
        wp = st.wp, n_wp = st.path and #st.path, partial = st.path_partial,
        nav_requests = st.nav_requests, nav_answers = st.nav_answers,
        sprinting = st.sprinting, sprint_route = st.sprint_route, sprint_err = st.sprint_err,
        press_to_sprint = st.pts, speed_ms = st.speed_cms and math.floor(st.speed_cms) / 100,
        stuck_n = st.stuck_n, stuck_total = st.stuck_total, jumps = st.jumps, double_jumps = st.double_jumps,
        ticks = st.ticks,
    }
end

return M
