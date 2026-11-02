-- move.lua: client-side locomotion for Claude's real game client (route R2,
-- docs/research/2026-10-25-client-side-botting.md decisions 2-4). Real player code paths only:
--   * steering  = pc:SetControlRotation + pawn:AddMovementInput(dir, 1) EVERY frame (what the
--                 IA_Movement handler ends in; a 50 ms cadence jitters, DISCOVERIES R2);
--   * sprint    = Enhanced Input injection of the pawn's own SprintComponent.SprintInputAction
--                 (IA_Player_Sprint: Boolean, InputTriggerDown; game setting press-to-sprint) via
--                 EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction. FInputActionValue
--                 has NO reflected fields, so the FVector variant is the one UE4SS can marshal.
--                 Fallback: SprintComponent:TryRequestStartSprinting(id). Measured 6.79 m/s;
--   * jump      = pawn:Jump()/StopJumping(); double jump = a second Jump() while airborne
--                 (JumpMaxCount = 2 on Claude).
-- Steering, first that applies each frame (tick):
--   * an escape in progress (a learned link, a step-off, Bug2), then a backtrack;
--   * LOCAL PLANNER (scripts/localplan.lua): a trace-sampled grid + A* around Claude on the real
--     client collision (terrain + replicated player builds). Triggered by a forward wall probe or
--     by being stuck; plans a SEGMENT toward the far goal (Baritone-style segmented planning),
--     re-plans at the segment end if still blocked;
--   * LEADER BREADCRUMBS when following (the leader's grounded trail is known walkable);
--   * a remembered route (NAVIGATION MEMORY below);
--   * the dev-server NAV ORACLE's route (tools/nav_oracle.py): asked first for long trips unless
--     nav=false. No route (oracle absent, no_path, partial/ended route) falls back to the others
--     and straight steering, drop-guarded (KillZ);
--   * straight at the goal.
-- Stuck ladder (1 s windows without movement): step off a perch / local plan -> jump -> double
-- jump -> strafe, once a backtrack along his own trail. One progress clock: no net progress toward
-- the goal for give_up_s -> the escape ladder below, then ONE terminal result.
-- Never teleports the pawn. One loop (LoopInGameThreadWithDelay(1, ...)), cancellable, and a
-- generation token so a loop from an older load of this file exits on its own.
--
-- API (all take the DWClient `log` function first):
--   M.go_to(log, goal, opts)   goal = {x,y,z} metres | "<player name>" | "<entity id>" (sense census
--                              short name, e.g. BP_AI_Kebbit_Character_02_C_2147480001) | actor UObject
--                              | {actor=obj}.  opts: tolerance_m=1.5, sprint_m=10, timeout_s=120,
--                              sprint=true, nav=nil(auto)|false, local_plan=true, wade=false (true: the goal is IN
--                              water on purpose, e.g. M.shore_point's stand: no water detours or re-plans)
--   M.follow(log, goal, distance_m=3, opts)   same goal kinds; runs until stop(). opts.face_when_near
--                              = keep facing the target while idle in range (combat).
--   M.stop(log)   M.status()
-- FOLLOW IS PERSISTENT: when the leader can't be reached, follow enters status "unreachable"
-- (stands, keeps watching him, re-plans every unreachable_check_s or when he moves/comes within
-- reach) and resumes by itself; only stop()/another command ends it. Each episode appends ONE
-- event to client_io/events/move.jsonl: {"type":"unreachable","reason":..., "leader_pos", "my_pos",
-- "detail"}; reasons: leader_windstepped | leader_double_jumped | leader_above_jump_height | no_route,
-- and {"type":"reachable_again"} when it resumes. go_to keeps its give-up (failed/stuck|unreachable).
-- NAVIGATION MEMORY (scripts/navmem.lua, streamline-plan step 5): Claude's successful trips and the
-- leader's walked trail are stored per world as routes (flushed when a move ends, also when a new
-- command interrupts it); Dijkstra over them is the first-choice router for long trips; known TRAPS
-- (seeded: the church start pit) put their exit first; a stuck spot that was later left becomes a
-- learned trap with that exit, and the failed direction is tabooed. M.escape_trap(log) for respawns.
-- Escape ladder at give-up (once each): memory route -> BUG2 wall-following (bounded) -> learned
-- link -> the truthful reason ("stuck" when wedged, else unreachable). With a player near, it ASKS
-- FOR HELP once per episode
-- ({"type":"stuck","ask":"lead_me","where":...}); a go_to then WAITS for the lead (status
-- "waiting_for_lead", up to lead_wait_s): when the helper moves, it walks his trail out and, once
-- clear of the stuck spot, carries on to its goal (one command, one result).
--   M.snapshot() -> {mode, goal, distance_m, opts} | nil    M.restore(log, snap)   (arbiter suspend/resume)
-- AVOID ZONES (scripts/avoidzones.lua; docs/design/velgar.md 3c), for combat hazards:
--   M.set_avoid_zones(log, zones)  replace (no merge) the zones every move keeps out of; [] clears.
--       zone = {id, kind="circle"|"cone", x, y, z (metres), r_cm, until_s (GetRealTimeSeconds clock)
--               | ttl_s, cone: yaw_deg, half_angle_deg; h_cm (vertical reach, 400)}, scalars only.
--       They are a planner COST (not walls): go_to/follow plan round them; when no other way exists the
--       route crosses the zone that ends soonest and status().avoid.crossing names it. A follow whose
--       leader stands in a zone holds at its edge; a follow standing in one steps out.
--   M.escape_zones(log, {time_s, bound = {x, y, z (m), r_cm}}) -> {ok, at = {x,y,z} m, eta_s, why =
--       nil | "no_safe_point" | "no_route" | "too_slow", zone, prev (snapshot to restore after)}:
--       the nearest point outside every zone inside the bound whose straight walk traces clear, walked at
--       once (sprinting); too_slow = it would not get out within time_s (combat dodges instead, no walk).
--   M.status().avoid = {zones = n, inside = id|nil, crossing = id|nil}
-- APPROACH PROGRESS (one "can't get closer" watchdog for combat/skills/shoot): every go_to/follow fills
--   M.status().progress = {verdict = "ok"|"stalled"|"unreachable", why, dist_m, best_dist_m, since_s (since
--   the last gain), elapsed_s (approach time, idle-near excluded), target_moved_m}; opts.progress =
--   {stall_s=12, gain_m=0.5, budget_s, moving_m=3, to={x,y,z}}. whys: move's reasons (no_route, ...,
--   needs:X) | cant_catch | too_long | blocked | no_progress | target_not_visible. M.progress_reset(log[, opts]).
--   M.why_words(why, thing) -> the clause for "I can't get to <thing>: <clause>." (one table for everyone).
-- Units: metres on the API (wire units), centimetres inside.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local NAV_REQ = ROOT .. "/client_io/nav/req.json"
local NAV_RESP = ROOT .. "/client_io/nav/resp.lua"
local NAV_ALIVE = ROOT .. "/client_io/nav/alive.lua"
local LP_PATH = ROOT .. "/client_mod/scripts/localplan.lua"
local TL_PATH = ROOT .. "/client_mod/scripts/traverse_learn.lua" -- learned traversal links (traversal agent)
local NM_PATH = ROOT .. "/client_mod/scripts/navmem.lua"
local AZ_PATH = ROOT .. "/client_mod/scripts/avoidzones.lua"
local TM_PATH = ROOT .. "/client_mod/scripts/traversal_moves.lua" -- DATA: double jump / Windstep gates
local SP_PATH = ROOT .. "/client_mod/scripts/spells.lua"          -- Windstep: its public ability_status / cast_now
local MP_PATH = ROOT .. "/client_mod/scripts/mapplayers.lua"      -- players on the game map / compass, any distance

local M = {}
local move_arbiter, life_check, finish, paused, world_identity

M.cfg = {
    wp_radius_cm = 120,        -- waypoint / crumb reached (2D)
    lp_radius_cm = 45,         -- local-plan point reached (cells are 1 m; 70 cut wall corners)
    sprint_on_cm = 1000,       -- sprint when the remaining distance is above this
    sprint_off_cm = 500,       -- ... and stop asking below this
    sprint_retry_s = 1.0,      -- toggle sprint: wait this long for the server ack before pressing again
    repath_goal_move_cm = 300, -- nav: a moving goal that drifted this far from the path's end -> repath
    nav_timeout_s = 40.0,      -- includes helper's 25 s loading budget and an in-flight 10 s bridge call
    nav_alive_s = 5,           -- oracle heartbeat older than this -> oracle considered absent
    stuck_window_s = 1.0,      -- progress is measured over this window
    stuck_min_cm = 50,         -- less 2D movement than this in a window, while pushing = stuck
    give_up_s = 5.0,           -- no PROGRESS for this long (planning time excluded) -> the escape ladder (give_up)
    detour_s = 20,             -- go_to: waypoints reached stop counting as progress after this long no closer to the goal
    progress_cm = 150,         -- progress = moved this much TOWARD the goal, or a point reached.
                               -- A jump/strafe wobble in place (live 17:52), a backtrack, or sliding
                               -- along a wall is not progress.
    backtrack_after = 3,       -- stuck windows before retracing our own trail back
    backtrack_cm = 400,
    backtrack_s = 2.0,
    self_cap = 120,            -- own-trail ring buffer (0.5 m spacing)
    trail_enter_stuck = 2,     -- after this many stuck windows, retrace the leader's breadcrumbs
    trail_min_dist_cm = 600,
    trail_lookahead = 8,       -- far goal for the local planner = this many crumbs ahead (~4 m)
    crumb_spacing_cm = 50,     -- leader crumb every 0.5 m moved, grounded positions only
    crumb_cap = 400,           -- ring buffer (~200 m of trail)
    crumb_reset_cm = 2000,     -- leader jumped this far at once (teleport/respawn): drop the trail
    -- local planner
    lp_enabled = true,
    lp_grid_m = 9,             -- grid radius (19 x 19 cells at 1 m: ~720 traces)
    lp_grid_up_m = 13,         -- ... when the goal is near but well above him (a stair or ramp up to it may turn back
                               -- past him: the Bramblemead Wise Old Man's switchback reaches 12 m out, 18:31Z)
    leap_land_cm = 130,
    below_max_cm = 500,        -- a go_to spot hanging over his floor up to this above his feet: arrived right under it        -- a leap's landing counts within this of the planned cell (he leaves the edge at speed)
    cam_taken_deg = 1.0,       -- the control rotation moved this far from move's own last write: another skill aims
    cam_yield_s = 0.6,         -- ... and move leaves the camera alone this long (renewed while it keeps aiming)
    lp_cell_cm = 100,
    door_find_cm = 450,        -- a shut door this near when a local plan fails is opened (E), as a player does
    door_reach_cm = 170,       -- he presses from here (the detector's camera ray reaches ~2.5 m from the pawn)
    lp_budget = 64,            -- traces per frame while standing to sample/verify (0.08 ms each live, 2026-11-01; 16 stood ~2.5 s a plan)
    lp_cache_ttl_s = 30,       -- world-aligned cell cache shared by plans and prefetch (builds change)
    prefetch_every = 3,        -- while moving: sample one cell ahead (2 traces) every N frames, so a
                               -- later plan mostly hits the cache (cuts the ~0.9 s standstill)
    lp_max_plans = 4,          -- plans without progress before the ladder takes over
    lp_cooldown_s = 1.5,       -- after a failed plan
    probe_every_s = 0.3,       -- forward wall probe cadence
    probe_ahead_cm = 150,
    probe_wall_nz = 0.7,       -- hit normal Z below this = wall (WalkableFloorAngle ~45 deg)
    follow_hysteresis_cm = 100,
    hop_dist_cm = 120,         -- a low obstacle (blocked at knee, clear at jump height) this close: jump now
    brake_cms2 = 2000,         -- go_to: his assumed braking when he lets go of the key (coasting into the goal)
    arrive_still_cms = 60, trap_undo_cm = 2000, hazard_standoff_cm = 200, hazard_slow_cm = 600, hazard_slow_input = 0.3, hazard_walk_cms = 250,     -- go_to "arrived" only once his ground speed is under this ...
    arrive_settle_s = 1.5,     -- ... or after this long inside the circle (then arrived as he is)
    water_depth = 0.25,        -- EnvironmentComponent:GetNormalizedWaterDepth() above this = in water
    water_cell_cost = 8,       -- local planner: extra cost per known-water cell (prefer going round)
    wet_lookahead_cm = 4000,   -- dry routing (scripts/wetroute.lua): water this far ahead on the way is weighed
    wet_run_cms = 650,         -- ... dry ground at his run (sprint ~680, walk 450) against water at MaxSwimSpeed (300)
    wet_heavy_cms = 270,       -- ... encumbered (403/400 live 00:24Z: walking only, 2.7 m/s)
    wet_min_gain_s = 0.3,      -- ... going round must save this much time over swimming
    wet_entry_s = 2.0,         -- ... and swimming costs this much more (getting in, and out up a bank: live exits
                               --     often needed a hop, 2026-11-01)
    bug_side_s = 12,           -- Bug2: time per side (left-hand, then right-hand)
    bug_side_cm = 3500,        -- Bug2: distance per side
    help_player_cm = 4000,     -- ask for help when a player is this close
    lead_clear_cm = 1500,      -- led this far from the stuck spot -> carry on to the goal ourselves
    lead_wait_s = 60,          -- a go_to waits this long for someone to lead it out
    trip_spacing_cm = 250,     -- trip recording resolution (navmem routes)
    mem_min_trip_cm = 3000,    -- use a remembered route only for trips longer than this
    trap_leave_cm = 1500,      -- leaving a stuck spot by this much makes the path since then its exit ...
    trap_extend_cm = 1000,     -- ... and the exit keeps growing for this much more walking (well clear)
    trap_straight_x = 1.15,    -- ... unless he walked straight out (path <= this x the distance) the way that failed
    prov_walk = true,          -- while a long route streams in on the dev server (~10 s), walk toward the goal
                               -- drop-guarded instead of standing; re-anchored on the route when it comes
    prov_min_cm = 4000,        -- ... only for trips longer than this (short routes come back in < 1 s)
    nav_stand_s = 4.0,         -- a trip that does not walk provisionally stands at most this long for its route
                               -- (a short trip's comes in < 1 s), then plans locally: a player starts at once
    oracle_primary_cm = 1000,  -- beyond this (or above jump height) the oracle route leads; the local
                               -- planner only handles the obstacle in front of the next waypoint
    unreachable_check_s = 1.5, -- while unreachable: re-check this often
    unreachable_moved_cm = 300,-- ... and resume at once when the leader moved this far
    self_stuck_cm = 100,       -- moved less than this in total over give_up_s = WE are stuck (not the route)
    superjump_any_cm = 450,    -- leader rise above this = Windstep (a double jump rises ~2.6-3 m: live
                               -- 20:25 his double jumps were misread at 250 cm and cut his trail)
    leader_far_cm = 30000,     -- leader further than this (teleported / lodestone): hold + "leader_far"
    target_jump_cm = 5000,     -- target moved this much in one step = teleport: reset path/trail
    link_max_tries = 2,        -- learned-link attempts per unreachable episode before reporting
    link_approach_s = 15,
    log_every_s = 2.0,
    -- avoid zones (combat hazards)
    avoid_margin_cm = 40,      -- capsule radius: "inside" = the capsule overlaps the zone
    avoid_dry_slack_cm = 600,  -- planner aims at a zone-free cell up to this much further from the goal
    avoid_check_s = 0.2,       -- route-vs-zones check cadence (pure math)
    avoid_plan_s = 1.0,        -- at most one zone-triggered local plan per this long (unless zones change)
    avoid_edge_cm = 300,       -- follow: leader inside a zone and the zone this close ahead = hold here
    escape_max_cm = 2500,      -- escape search radius without a bound
    escape_extra_cm = 60,      -- walk this far past the zone edge (arrival = out of every zone anyway)
    escape_walk_cms = 450,     -- speeds for the eta when nothing was measured yet
    escape_sprint_cms = 680,
    escape_react_s = 0.25,     -- turn + sprint ack before the speed is reached
    escape_max_tests = 8,      -- candidates traced for reachability (nearest first)
    -- approach progress tracker (status().progress), defaults for opts.progress
    progress_stall_s = 12,     -- no gain of progress_gain_m for this long = stalled
    progress_gain_m = 0.5,
    progress_moving_m = 3,     -- target moved this far since the best distance = it is running away (cant_catch)
    deadline_cap_s = 285,      -- go_to deadline ceiling (client_bridge GOTO_TIMEOUT_S = 290)
    trip_progress_s = 20,      -- a go_to longer than trip_progress_min_cm writes a progress line this often (ISSUES C2:
    trip_progress_min_cm = 4000, -- 147 s silent on a 274 m walk): client_io/events/move.jsonl {"type":"trip_progress"}
    mem_goal_reach_cm = 600,   -- a remembered route "reaches" the goal when its last point is this close (same level)
    mem_goal_factor = 12,      -- ... and may be this many times the straight distance (+20 m): the direct way failed
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
local function fmt(p) return p and string.format("(%.0f,%.0f,%.0f)", p.X, p.Y, p.Z) or "-" end
local function half_h(pawn) -- capsule half height (cm), 90 when unreadable
    local ok, hh = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    return (ok and tonumber(hh)) or 90
end
local function finite3(p) -- p has finite numeric X, Y, Z
    if not p then return false end
    for _, k in ipairs({ "X", "Y", "Z" }) do
        local x = p[k]
        if type(x) ~= "number" or x ~= x or math.abs(x) == math.huge then return false end
    end
    return true
end

-- The players on the game's map and compass (mapplayers.lua), loaded once per load of this file; nil when missing.
local MPm
local function mp()
    if MPm == nil then
        local okc, chunk = pcall(loadfile, MP_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        MPm = (okm and type(mod) == "table" and type(mod.find) == "function") and mod or false
    end
    return MPm or nil
end

-- Pawn of the player whose PlayerState name is `name` (case-insensitive; a name cut short matches too when it is the
-- only one, mapplayers.same_name: the character "luisdeburnaybast" of the account "luisdeburnaybastos"), or nil.
local function player_pawn(name, me)
    local want = name:lower()
    local P = mp()
    local hit, n = nil, 0
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        if ps:IsValid() and not ps:GetFullName():find("Default__") then
            local ok, pn = pcall(function() return ps:GetPlayerName():ToString() end)
            local exact = ok and pn and pn:lower() == want
            if exact or (ok and pn and P and P.same_name(pn, name)) then
                local okp, p = pcall(function() return ps.PawnPrivate end)
                if okp and p and p:IsValid() and p ~= me then
                    if exact then return p end
                    hit, n = p, n + 1
                end
            end
        end
    end
    if n == 1 then return hit end
end

-- Nearest other player's (name, pawn, distance cm) within max_cm of p, or nil.
local function nearest_player(me_pawn, p, max_cm)
    local best, bn, bp = max_cm or math.huge, nil, nil
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        if ps:IsValid() and not ps:GetFullName():find("Default__") then
            local okp, pw = pcall(function() return ps.PawnPrivate end)
            if okp and pw and pw:IsValid() and pw ~= me_pawn then
                local okl, l = pcall(function() return pw:K2_GetActorLocation() end)
                local okn, n = pcall(function() return ps:GetPlayerName():ToString() end)
                if okl and okn then
                    local dd = math.sqrt((l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2)
                    if dd < best then best, bn, bp = dd, n, pw end
                end
            end
        end
    end
    return bn, bp, bn and best or nil
end

-- Actor by entity id (U.short name as the sense census reports it), or nil.
local function actor_by_id(id)
    for _, cls in ipairs({ "DominionAICharacter", "Character" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if a:IsValid() then
                local ok, n = pcall(function() return a:GetFullName() end)
                if ok and n and n:match("([%w_]+)$") == id then return a end
            end
        end
    end
end

-- A player out of net relevancy (his pawn replicates only within ~150 m) is still on the game map and compass: a
-- stand-in target, a plain Lua table with the methods the move reads (IsValid, K2_GetActorLocation, GetFullName; never
-- a UObject), whose position is his map marker (mapplayers.lua: the replicated GameplayObjectRegistry.PlayerCharacters),
-- re-read as he moves. It gives way once his pawn replicates (IsValid turns false after 1 s, so track_goal's
-- once-a-second re-resolve picks the pawn) or when he leaves the map. Retro 2026-11-01 root cause 3.
M.MAP_REFRESH_S = 0.5
M.MAP_REPATH_FRAC = 0.15 -- a map-marker goal re-asks the route once he drifted this share of the distance (>= 3 m)
local function map_target(spec, me)
    local P = mp()
    if not P or type(spec) ~= "string" or spec == "" then return nil end
    local function clock() local ok, t = pcall(now, me); return (ok and type(t) == "number") and t or os.clock() end
    local okf, row = pcall(P.find, spec, { me = me })
    if not (okf and row) then return nil end
    local t0 = clock()
    local proxy = { dw_map = true, name = row.name, spec = spec, row = row, t0 = t0, read_t = t0 }
    function proxy:IsValid()
        local t = clock()
        if t - self.read_t >= M.MAP_REFRESH_S or t < self.read_t then
            self.read_t = t
            local okr, r = pcall(P.find, self.spec, { me = me })
            if okr and r then self.row = r elseif okr then self.gone = true end
            local pw = not self.gone and t - self.t0 > 1.05 and player_pawn(self.spec, me)
            local okl, l = false, nil
            if pw then okl, l = pcall(function() return pw:K2_GetActorLocation() end) end
            -- (a culled pawn can linger at the world origin: that one is no handover)
            if okl and l and (math.abs(l.X) >= 100 or math.abs(l.Y) >= 100) then self.pawn_seen = true end
        end
        return not (self.gone or self.pawn_seen)
    end
    function proxy:K2_GetActorLocation() local p = self.row.pos; return { X = p.X, Y = p.Y, Z = p.Z } end
    function proxy:GetFullName() return "MapPlayer " .. tostring(self.name) end
    return proxy
end

-- Resolve a goal spec to (pawn_or_actor, kind) with kind "player" | "actor"; a player out of sight -> his map marker.
local function resolve_target(spec, me)
    if type(spec) == "userdata" then return spec, "actor" end
    if type(spec) == "table" and spec.actor then return spec.actor, "actor" end
    local p = player_pawn(tostring(spec), me)
    if p then return p, "player" end
    local a = actor_by_id(tostring(spec))
    if a then return a, "actor" end
    local m = map_target(spec, me)
    if m then return m, "player" end
end
-- the players on the map other than me (names), for a truthful "not on the map" reason; nil when unreadable
local function map_names(me)
    local P = mp()
    if not P then return nil end
    local ok, rows = pcall(P.players, { me = me })
    if not ok or type(rows) ~= "table" then return nil end
    local out = {}
    for _, r in ipairs(rows) do if not r.me and r.name then out[#out + 1] = r.name end end
    return out
end

-- Traversal events for the traversal agent / brain (docs/research/2026-10-25-traversal.md):
-- successful non-walk local-plan edges, one JSON line each, metres.
local EVENTS = ROOT .. "/client_io/events/traversal.jsonl"
local MOVE_EVENTS = ROOT .. "/client_io/events/move.jsonl"
local okw, walltime = pcall(require, "walltime") -- ms ts (telemetry item 5)
-- (an older walltime in the client's require cache may lack now: inventory.lua's stale-cache note, 2026-11-01 13:3x)
local function now_ts() return okw and type(walltime) == "table" and type(walltime.now) == "function" and walltime.now() or os.time() end
local function m3s(p) return p and string.format("[%.2f,%.2f,%.2f]", p.X / 100, p.Y / 100, p.Z / 100) or "null" end
local function emit_move_event(kind, fields)
    local f = io.open(MOVE_EVENTS, "a")
    if not f then return end
    -- who the move was toward (the bridge must not say "can't reach YOU" for a go_to to a point)
    local st = rawget(_G, "DW_MOVE")
    if st and fields.target == nil then
        fields.target = st.target_name or "point"
        fields.target_kind = st.target_kind or "point"
    end
    local parts = { string.format('"type":"%s"', kind), string.format('"ts":%.3f', now_ts()),
        string.format('"iso":"%s"', os.date("!%Y-%m-%dT%H:%M:%SZ")) }
    for k, x in pairs(fields) do
        if type(x) == "table" and x.X then parts[#parts + 1] = string.format('"%s":%s', k, m3s(x))
        elseif type(x) == "number" then parts[#parts + 1] = string.format('"%s":%s', k, tostring(x))
        elseif x ~= nil then parts[#parts + 1] = string.format('"%s":%q', k, tostring(x)) end
    end
    f:write("{" .. table.concat(parts, ",") .. "}\n")
    f:close()
end
local function emit_self_edge(st, a, b, move)
    local f = io.open(EVENTS, "a")
    if not f then return end
    local h = math.deg(math.atan(b.Y - a.Y, b.X - a.X))
    f:write(string.format('{"type":"self_edge","move":"%s","from":[%.2f,%.2f,%.2f],"to":[%.2f,%.2f,%.2f],"heading_deg":%.1f,"runup_m":0,"sprint":false,"dz_m":%.2f,"gap_m":%.2f,"ts":%.3f,"iso":"%s"}\n',
        move, a.X / 100, a.Y / 100, a.Z / 100, b.X / 100, b.Y / 100, b.Z / 100, h, (b.Z - a.Z) / 100,
        d2(a, b) / 100, now_ts(), os.date("!%Y-%m-%dT%H:%M:%SZ")))
    f:close()
    st.self_edges = (st.self_edges or 0) + 1
end

-- ------------------------------------------------------------------ traces (real client collision)
-- KismetSystemLibrary:LineTraceSingle(ctx=pawn, start, end, TraceTypeQuery1 (Visibility), simple,
-- {} ignore, no debug draw, out, bIgnoreSelf). UE4SS fills the empty `out` table as nested tables
-- (out.ImpactPoint.Z, out.ImpactNormal.Z, out.Distance); verified on the dev server and the client
-- (~1 ms per trace). out.bStartPenetrating is NOT reliable (it shares a bitfield byte with
-- bBlockingHit and reads true on clean floor hits), so "started inside geometry" = Distance 0.
local KSL
local C0 = { R = 0, G = 0, B = 0, A = 0 }
-- Traces use a real collision PRESET for a pawn (LineTraceSingleByProfile), i.e. what blocks a
-- character; the Visibility channel also hits decorative clutter he walks through.
-- NOT the capsule's own profile name: with per-channel responses UE reports it as "Custom", which is
-- not a preset, so the engine logs "COLLISION PROFILE [Custom] is not found" and returns NO hit
-- (live 2026-10-25 21:33+: 27k log lines, blind local planner). Candidates are the game's "Player"
-- preset (Claude's capsule used it earlier) and the engine default "Pawn"; each is VALIDATED with one
-- downward trace beside Claude that must find the floor Visibility finds. Else: Visibility.
local PROFILE, PROFILE_NAME
M.PROFILE_CANDIDATES = { "Player", "Pawn" }
local function pick_profile(ctx)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local okl, me = pcall(function() return ctx:K2_GetActorLocation() end)
    if not (okl and me) then return false end
    local hh = half_h(ctx)
    local x, y = me.X + 80, me.Y -- beside Claude: his own gear blocks traces
    local a, b = { X = x, Y = y, Z = me.Z - hh + 100 }, { X = x, Y = y, Z = me.Z - hh - 300 }
    local ov = {}
    local vis = KSL:LineTraceSingle(ctx, a, b, 0, false, {}, 0, ov, true, C0, C0, 0.0) == true
    for _, n in ipairs(M.PROFILE_CANDIDATES) do
        local okf, fn = pcall(function() return FName(n) end)
        if okf and fn then
            local op = {}
            local okt, hit = pcall(function() return KSL:LineTraceSingleByProfile(ctx, a, b, fn, false, {}, 0, op, true, C0, C0, 0.0) end)
            if okt and hit == true and (not vis or not op.ImpactPoint or not ov.ImpactPoint
                or math.abs(op.ImpactPoint.Z - ov.ImpactPoint.Z) < 150) then
                PROFILE_NAME = n
                return fn
            end
        end
    end
    PROFILE_NAME = "visibility"
    return false
end
local function raw_trace(ctx, a, b)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    if PROFILE == nil then
        -- shared by every load of this file (status, bridge, commands): validated once per client run
        local g = rawget(_G, "DW_TRACE_PROFILE")
        if g and g.name then
            PROFILE_NAME = g.name
            PROFILE = (g.name ~= "visibility") and FName(g.name) or false
        else
            local okp, fn = pcall(pick_profile, ctx)
            PROFILE = okp and fn or false
            _G.DW_TRACE_PROFILE = { name = PROFILE_NAME or "visibility" }
        end
    end
    if PROFILE then
        local ok, hit = pcall(function() return KSL:LineTraceSingleByProfile(ctx, a, b, PROFILE, false, {}, 0, out, true, C0, C0, 0.0) end)
        if ok then return hit == true, out end
        PROFILE, PROFILE_NAME = false, "visibility"
        _G.DW_TRACE_PROFILE = { name = "visibility" }
        out = {}
    end
    local hit = KSL:LineTraceSingle(ctx, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0)
    return hit == true, out
end

-- WATER SENSE: which trace channel reports the water SURFACE (the pawn profile passes through water
-- to the bed)? Calibrated the first time Claude wades: a downward trace beside him that hits above
-- his feet. Candidates: Visibility (0), Camera (1) channels; WorldStatic (0) / WorldDynamic (1) objects.
local WATER_CANDIDATES = { { ch = 0, name = "vis" }, { ch = 1, name = "cam" }, { ot = 0, name = "static" }, { ot = 1, name = "dyn" } }
local function trace_with(c, ctx, a, b)
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = {}
    local hit
    if c.ch then hit = KSL:LineTraceSingle(ctx, a, b, c.ch, false, {}, 0, out, true, C0, C0, 0.0)
    else hit = KSL:LineTraceSingleForObjects(ctx, a, b, { c.ot }, false, {}, 0, out, true, C0, C0, 0.0) end
    return hit == true, out
end

-- The calibrated channel is kept across client runs of the same build (client_io/state/water_channel.lua). A fresh
-- client used to trust every remembered water cell until he next waded: live 2026-11-01 18:07Z, five false
-- church-door cells ("cannot check: no water channel") put a local plan round "water" on the grave walk, ~13 s.
local WATER_CH_FILE = ROOT .. "/client_io/state/water_channel.lua"
local CLIENT_BUILD = os.getenv("DW_CLIENT_BUILD") or "26162923"
local function water_ch_load()
    -- (false = a wade where no channel saw the surface, e.g. too shallow: the stored channel still holds)
    if type(rawget(_G, "DW_WATER_CH")) == "table" then return end
    local okl, fn = pcall(loadfile, WATER_CH_FILE)
    if not (okl and type(fn) == "function") then return end
    local okr, c = pcall(fn)
    if okr and type(c) == "table" and c.build == CLIENT_BUILD and type(c.name) == "string" and (tonumber(c.ch) or tonumber(c.ot)) then
        _G.DW_WATER_CH = { ch = tonumber(c.ch), ot = tonumber(c.ot), name = c.name, stored = true }
    end
end
local function water_ch_save(c)
    local tmp = WATER_CH_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(string.format("return { build = %q, name = %q, ch = %s, ot = %s }", CLIENT_BUILD, tostring(c.name), tostring(c.ch), tostring(c.ot)))
    f:close()
    os.remove(WATER_CH_FILE)
    os.rename(tmp, WATER_CH_FILE)
end
pcall(water_ch_load)

local function water_sense_calibrate(st, pawn, me, fe, dx, dy, log)
    if rawget(_G, "DW_WATER_CH") ~= nil then return end
    local x, y = me.X + dx * 90, me.Y + dy * 90 -- beside Claude (his own gear blocks traces)
    for _, c in ipairs(WATER_CANDIDATES) do
        local ok, hit, out = pcall(trace_with, c, pawn, { X = x, Y = y, Z = fe.Z + 300 }, { X = x, Y = y, Z = fe.Z - 300 })
        if log then log(string.format("move: water sense try %s: ok=%s hit=%s z=%s feet=%.0f", c.name, tostring(ok), tostring(hit),
            tostring(ok and type(out) == "table" and out.ImpactPoint and math.floor(out.ImpactPoint.Z) or out), fe.Z)) end
        if ok and hit and out.ImpactPoint and out.ImpactPoint.Z > fe.Z + 15 and out.ImpactPoint.Z < fe.Z + 250 then
            _G.DW_WATER_CH = c
            pcall(water_ch_save, c)
            if log then log("move: water sense: channel '" .. c.name .. "' sees the surface") end
            return
        end
    end
    _G.DW_WATER_CH = false
    if log then log("move: water sense: no trace channel sees the water surface (learning by wading only)") end
end

-- Is there water over this floor? true / false, nil when no channel sees water (not calibrated yet). The water
-- channel also stops on solids (a roof or a bench above the floor): water only where the pawn trace, which
-- passes through water to the bed, does NOT stop at that height (the church interior was marked water and every
-- trip from it stood 2.5 s for a "water_ahead" plan, 2026-11-01).
local function water_at(pawn, x, y, floor_z)
    local c = rawget(_G, "DW_WATER_CH")
    if not c then return nil end
    local a, b = { X = x, Y = y, Z = floor_z + 300 }, { X = x, Y = y, Z = floor_z - 50 }
    local ok, hit, out = pcall(trace_with, c, pawn, a, b)
    if not (ok and type(out) == "table") then return nil end
    if not (hit and out.ImpactPoint and out.ImpactPoint.Z > floor_z + 15) then return false end
    local okr, hr, outr = pcall(raw_trace, pawn, a, b)
    if okr and hr and outr.ImpactPoint and outr.ImpactPoint.Z >= out.ImpactPoint.Z - 10 then return false end
    return true
end

-- A remembered water cell is looked at (once per cell per trip) before standing to plan round it, and when he
-- walks dry on it: when the water channel sees no water over the floor at its centre (a false mark from a roof or
-- a bench), it is forgotten. A shoreline cell whose centre is wet stays (walking its dry edge proves nothing).
local function water_false_mark(st, pawn, fe, q, mem, NMm, log)
    local cell = NMm.cfg.water_cell_cm or 200
    local cx, cy = (math.floor(q.X / cell) + 0.5) * cell, (math.floor(q.Y / cell) + 0.5) * cell
    local key = math.floor(cx) .. ":" .. math.floor(cy)
    st.water_seen = st.water_seen or {}
    if st.water_seen[key] ~= nil then return st.water_seen[key] end
    local okf, hf, outf = pcall(raw_trace, pawn, { X = cx, Y = cy, Z = fe.Z + 150 }, { X = cx, Y = cy, Z = fe.Z - 400 })
    local wet = nil -- (not "x and water_at() or nil": that turned a dry "false" into nil, so no false mark was ever forgotten)
    if okf and hf and outf.ImpactPoint then wet = water_at(pawn, cx, cy, outf.ImpactPoint.Z) end
    local false_mark = wet == false
    st.water_seen[key] = false_mark
    if log and not false_mark then
        log(string.format("move: memory: water at (%.0f,%.0f) %s", cx, cy, wet and "confirmed" or "(cannot check: " ..
            (not (okf and hf) and "no floor" or "no water channel") .. ")"))
    end
    if false_mark and NMm.clear_water and NMm.clear_water(mem, q) then
        st.water_new = (st.water_new or 0) + 1
        st.water_cleared = (st.water_cleared or 0) + 1
        pcall(NMm.save, mem); st.water_new = 0
        if log then log(string.format("move: memory: no water at (%.0f,%.0f) after all (a roof or a bench fooled the probe); forgotten", cx, cy)) end
    end
    return false_mark
end
M._water_false_mark = water_false_mark -- fake-engine regression access

local function make_trace(st, pawn)
    return function(a, b, horizontal)
        st.traces = (st.traces or 0) + 1
        local hit, out = raw_trace(pawn, a, b)
        if horizontal then return hit, hit and out.ImpactPoint or nil end
        if not hit then return nil end
        local ip = out.ImpactPoint
        return ip and ip.Z, (tonumber(out.Distance) or 1) < 0.5, out.ImpactNormal and tonumber(out.ImpactNormal.Z)
    end
end

-- Observation must not turn malformed native results into clear space or change
-- the shared profile. Select a profile locally when no validated one is known.
local function make_observation_trace(st, pawn, me, hh, valid)
    local ksl = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not valid() or not ksl then error("trace library unavailable") end
    local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
    local function call(profile, a, b, vertical)
        if not valid() then error("observation interrupted") end
        local out = {}
        local ok, hit = pcall(function()
            if profile then return ksl:LineTraceSingleByProfile(pawn,a,b,profile,false,{},0,out,true,C0,C0,0.0) end
            return ksl:LineTraceSingle(pawn,a,b,0,false,{},0,out,true,C0,C0,0.0)
        end)
        if not valid() or not ok or type(hit) ~= "boolean" then error("trace result unavailable") end
        if not hit then return false end
        local okp, x,y,z, distance = pcall(function()
            local p=out.ImpactPoint
            return p.X,p.Y,p.Z,out.Distance
        end)
        if not okp or not finite(x) or not finite(y) or not finite(z) or
            (vertical and (not finite(distance) or distance < 0)) then error("invalid trace hit") end
        return true, {X=x,Y=y,Z=z}, distance
    end
    local profile
    local shared = rawget(_G,"DW_TRACE_PROFILE")
    local name = shared and shared.name
    if name and name ~= "visibility" then
        local ok, value = pcall(FName,name)
        if not valid() or not ok or not value then error("trace profile unavailable") end
        profile=value
    else
        local a={X=me.X+80,Y=me.Y,Z=me.Z-hh+100}
        local b={X=a.X,Y=a.Y,Z=me.Z-hh-300}
        local vis, floor=call(nil,a,b,true)
        if not vis then error("visibility floor unavailable") end
        for _, candidate in ipairs(M.PROFILE_CANDIDATES) do
            local ok, value=pcall(FName,candidate)
            if not valid() or not ok or not value then error("trace profile unavailable") end
            local hit, p=call(value,a,b,true)
            if hit and math.abs(p.Z-floor.Z)<150 then profile=value; break end
        end
        if not profile then error("validated trace profile unavailable") end
    end
    return function(a,b,horizontal)
        local hit,p,d=call(profile,a,b,not horizontal)
        if not valid() then error("observation interrupted") end
        st.traces=(st.traces or 0)+1
        if horizontal then return hit, p end
        if not hit then return nil end
        return p.Z, d < 0.5
    end
end

-- Jump envelope from the engine's own numbers (traversal design, docs/research/2026-10-25-traversal.md):
-- CMC:GetMaxJumpHeightWithJumpTime() (or GetMaxJumpHeight()) already folds in gravity scale and
-- jump hold; double jump only if the perk is really unlocked (JumpMaxCount = 2 does not prove it:
-- DoubleJumpSkillPerk is Agility 10). Planning margin 15 cm below the apex.
local function envelope(pawn, pc)
    local mc = pawn.CharacterMovement
    local function num(f) local ok, x = pcall(f); return ok and tonumber(x) or nil end
    local step = num(function() return mc.MaxStepHeight end) or 45
    local apex = num(function() return mc:GetMaxJumpHeightWithJumpTime() end)
        or num(function() return mc:GetMaxJumpHeight() end) or 120
    local dj = false
    pcall(function() dj = pc.SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk) == true end)
    -- the perk's own unlock level (game data: USkillPerkData.PerkUnlockInfo.RequiredSkillLevel), for the reason words
    local dj_level = num(function() return pawn.DoubleJumpSkillPerk.PerkUnlockInfo.RequiredSkillLevel end)
    local safe_drop = num(function() return mc.MinFallDamageHeight end) or 500
    -- the steepest floor he can stand on (WalkableFloorAngle 45.5 deg -> 0.70); steeper ground slides him off
    local walk_z = num(function() return mc.WalkableFloorZ end) or num(function() return mc:GetWalkableFloorZ() end) or 0.70
    local env = { step = step, jump = apex - 15, djump = apex - 15, -- double-jump edges only once MEASURED
                  drop = math.min(1000, math.max(150, safe_drop - 50)), apex = apex, double_jump = dj, source = "engine",
                  safe_fall = safe_drop, walk_z = (walk_z > 0.3 and walk_z < 0.99) and walk_z or 0.70,
                  dj_level = (dj_level and dj_level > 0) and math.floor(dj_level) or nil }
    -- MEASURED values win (client_mod/commands/move_calib.lua -> data/envelopes/Claude.json)
    local okj, J = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    local f = io.open(ROOT .. "/data/envelopes/Claude.json", "rb")
    if okj and f then
        local txt = f:read("a"); f:close()
        local okd, m = pcall(J.decode, txt)
        if okd and type(m) == "table" then
            local provenance = type(m.measurement_provenance) == "table" and m.measurement_provenance or {}
            local function measured(field, value)
                local proof, n = provenance[field], tonumber(value)
                return type(proof) == "table" and proof.verified == true and n and n > 0 and n < math.huge
            end
            local ju = type(m.jump_up_m) == "table" and m.jump_up_m.stand or m.jump_up_m
            env.jump_measured = measured("jump_up_m.stand", ju) and true or false
            if env.jump_measured then env.jump = tonumber(ju) * 100 end
            local dj_measured = measured("dj_up_m", m.dj_up_m)
            if dj_measured then
                env.dj_measured, env.dj_measured_up_cm = true, tonumber(m.dj_up_m) * 100
                if dj then
                    env.djump = env.dj_measured_up_cm
                    if tonumber(m.dj_delay_s) then env.dj_delay_s = tonumber(m.dj_delay_s) end
                end
            end
            if not dj then env.djump = env.jump end
            -- A separately verified Windstep measurement is required, as well as live castability.
            if measured("windstep_up_m", m.windstep_up_m) then
                env.ws_up_cm = tonumber(m.windstep_up_m) * 100
                if tonumber(m.windstep_jump_delay_s) then env.ws_jump_delay_s = tonumber(m.windstep_jump_delay_s) end
            end
            if env.jump_measured or env.dj_measured or env.ws_up_cm then env.source = "verified measurements" end
        end
    elseif f then f:close() end
    return env
end
M._envelope = envelope -- fake-engine regression access

-- ------------------------------------------------------------------ nav oracle client (optional)
local function oracle_offer()
    local chunk = loadfile(NAV_ALIVE)
    if not chunk then return nil, "oracle_unavailable" end
    local ok, h = pcall(chunk)
    if not ok or type(h) ~= "table" or h.version ~= 2 or type(h.epoch) ~= "string"
        or type(h.updated) ~= "number" or h.updated ~= h.updated or math.abs(h.updated) == math.huge or
        math.abs(os.time() - h.updated) > M.cfg.nav_alive_s then return nil, "oracle_unavailable" end
    if h.state == "recovering" then return h, "oracle_recovering" end
    if h.state == "unresolved" then return h, "oracle_unresolved" end
    if h.state == "busy" then return h, "oracle_busy" end
    if h.state ~= "offered" then return nil, "oracle_unavailable" end
    return h
end

local function nav_request(st, from, to, offer, world)
    local function uuid(s)
        return type(s) == "string" and #s == 36 and
            s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    end
    if not offer or offer.state ~= "offered" or type(offer.nonce) ~= "string"
        or not uuid(offer.epoch) or not uuid(offer.nonce) then return false end
    _G.DW_NAV_USED = _G.DW_NAV_USED or {}
    local key = offer.epoch .. ":" .. offer.nonce
    if _G.DW_NAV_USED[key] then return false end
    -- A previous client may have written this offer before the helper consumed it.
    local old = io.open(NAV_REQ, "r")
    if old then
        local body = old:read("a"); old:close()
        if body:match('"epoch"%s*:%s*"([^"]+)"') == offer.epoch and
           body:match('"nonce"%s*:%s*"([^"]+)"') == offer.nonce then return false end
    end
    if not (finite3(from) and finite3(to)) then return false end
    st.nav_id = (st.nav_id or 0) + 1
    st.nav_from = { X = from.X, Y = from.Y, Z = from.Z } -- where the route is asked from (nav_response: a route left behind)
    local body = string.format('{"version":2,"epoch":"%s","nonce":"%s","id":%d,"from":[%.2f,%.2f,%.2f],"to":[%.2f,%.2f,%.2f]}',
        offer.epoch, offer.nonce, st.nav_id, from.X / 100, from.Y / 100, from.Z / 100, to.X / 100, to.Y / 100, to.Z / 100)
    local f = io.open(NAV_REQ .. ".tmp", "w")
    if not f then return false end
    f:write(body)
    f:close()
    -- Windows can refuse a rename for a moment (an AV/indexer handle on the fresh file): retry, then
    -- write in place (the helper tolerates a half-read file and re-reads); report failure so the
    -- caller retries next tick instead of waiting out the oracle timeout for a request never sent
    local sent = false
    for _ = 1, 3 do
        os.remove(NAV_REQ)
        if os.rename(NAV_REQ .. ".tmp", NAV_REQ) then sent = true; break end
    end
    if not sent then
        local g = io.open(NAV_REQ, "w")
        if g then g:write(body); g:close(); sent = true end
        os.remove(NAV_REQ .. ".tmp")
    end
    if not sent then return false end
    _G.DW_NAV_USED[key] = true
    st.nav_pending, st.nav_goal = { id=st.nav_id, epoch=offer.epoch, nonce=offer.nonce,
        gen=st.gen, token=st.owner_token, pawn=st.pawn, world=world }, v(to)
    return true
end

local function nav_poll(st)
    local chunk = loadfile(NAV_RESP)
    if not chunk then return nil end
    local ok, r = pcall(chunk)
    local p = st.nav_pending
    if ok and type(r) == "table" and type(p) == "table" and r.version == 2 and
        r.id == p.id and r.epoch == p.epoch and r.nonce == p.nonce then return r end
end

-- ------------------------------------------------------------------ input
local function is_sprinting(pawn)
    local ok, s = pcall(function() return pawn.SprintComponent:IsSprinting() end)
    return ok and s == true
end

local function inject_sprint(st, pawn)
    if st.sprint_route == "broken" then return false end
    local subs = st.eis
    if not (subs and subs:IsValid()) then subs = FindFirstOf("EnhancedInputLocalPlayerSubsystem"); st.eis = subs end
    local okA, act = pcall(function() return pawn.SprintComponent.SprintInputAction end)
    if not (subs and okA and act and act:IsValid()) then st.sprint_route = "broken"; return false end
    local ok, err = pcall(function() subs:InjectInputVectorForAction(act, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    if not ok then
        st.sprint_err = tostring(err)
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

local function binding(st, pawn)
    return { st=st, gen=st.gen, token=st.owner_token, pawn=pawn, pc=st.pc, life=st.life_seq }
end
local function same_binding(b, allow_nil_owner)
    local st=b.st
    if paused() or rawget(_G,"DW_MOVE") ~= st or st.gen ~= b.gen or st.mode == "idle" or
        st.owner_token ~= b.token or not b.token or st.pawn ~= b.pawn or st.pc ~= b.pc or st.life_seq ~= b.life then return false end
    local raw=rawget(_G,"DWArbiter"); local owner=raw and raw.owner
    if not raw or (owner and owner.token ~= b.token) or (not owner and not allow_nil_owner) then return false end
    local ok, p=pcall(function() return b.pc.Pawn end)
    if not ok or p ~= b.pawn then return false end
    local alive=life_check(st,b.pawn)
    local again,pawn_again=pcall(function() return b.pc.Pawn end)
    return alive == true and again and pawn_again == b.pawn and not paused() and rawget(_G,"DW_MOVE") == st and st.gen == b.gen and st.owner_token == b.token and
        st.pc == b.pc and st.pawn == b.pawn and st.life_seq == b.life and st.mode ~= "idle" and rawget(_G,"DWArbiter") == raw and (raw.owner == owner)
end
local function owned(b)
    if not same_binding(b,false) then return false end
    local a=move_arbiter(); local ok,v=pcall(function() return a and a.owns_move and a.owns_move(b.token) end)
    return ok and v == true and same_binding(b,false)
end
local function reject_binding(b,log)
    local s, arb=b.st,rawget(_G,"DWArbiter")
    if paused() then return "superseded" end
    local ok, pawn=pcall(function() return b.pc.Pawn end)
    if not paused() and rawget(_G,"DW_MOVE")==s and s.gen==b.gen and s.mode~="idle" and s.owner_token==b.token and
        s.pawn==b.pawn and s.pc==b.pc and s.life_seq==b.life and ok and pawn==b.pawn and arb and arb.owner and arb.owner.token==b.token then
        finish(s,{status="failed",reason="verification_failed",detail="jump ownership or character state unavailable"},log)
        return "failed"
    end
    return "superseded"
end
local function start_jump(st, t, pawn, double, log)
    if st.jump_t then return "busy" end
    local b=binding(st,pawn)
    if not owned(b) then return reject_binding(b,log) end
    local ok=pcall(function() pawn:Jump() end)
    if not owned(b) then return reject_binding(b,log) end
    if not ok then finish(st,{status="failed",reason="verification_failed",detail="jump input failed"},log); return "failed" end
    st.jump_t, st.jump_release, st.jump_double = t, true, double
    st.jump_observation = {intent="first", submitted=true, airborne="unknown", generation=st.gen}
    st.jumps = (st.jumps or 0) + 1
    return "accepted"
end

-- ------------------------------------------------------------------ trails
local function record_crumb(st, p)
    local c = st.crumbs
    local last = c[#c]
    if last then
        local d = math.sqrt((p.X - last.X) ^ 2 + (p.Y - last.Y) ^ 2 + (p.Z - last.Z) ^ 2)
        if d < M.cfg.crumb_spacing_cm then return end
        if d > M.cfg.crumb_reset_cm then
            for i = #c, 1, -1 do c[i] = nil end
            st.trail_i = nil
        end
    end
    if st.target_mc == nil then
        local ok, m = pcall(function() return st.target.CharacterMovement end)
        st.target_mc = (ok and m and m:IsValid()) and m or false
    end
    local air = false
    if st.target_mc then
        local ok, g = pcall(function() return st.target_mc:IsMovingOnGround() end)
        air = ok and g == false
    end
    -- airborne samples are kept, flagged: that is where the leader jumped (we jump there too)
    local crumb = v(p)
    crumb.air = air or nil
    if st.next_gap and not air then crumb.gap = true; st.next_gap = nil end
    c[#c + 1] = crumb
    if #c > M.cfg.crumb_cap then
        table.remove(c, 1)
        if st.trail_i then st.trail_i = math.max(1, st.trail_i - 1) end
        if st.trail_above_i then st.trail_above_i = math.max(0, st.trail_above_i - 1) end
        if st.crumb_mark then st.crumb_mark = math.max(0, st.crumb_mark - 1) end
    end
end

-- Nearest crumb at OUR level (|dz| <= 1 m): a crumb on a ledge 3.3 m above is not "near"
-- (live 18:52: the trail index jumped 2 -> 21 along crumbs all 3.3 m overhead). nil if none.
local function nearest_crumb(c, me, from_i)
    -- after a leader super-jump gap, prefer the part of the trail beyond it when any of it is at our level
    local g = 0
    for i = #c, 1, -1 do if c[i].gap then g = i; break end end
    -- of the crumbs at our level within 3 m of the nearest, the one with the shortest way to him (straight to it,
    -- then his trail): the nearest alone is often one he left behind (ladder 2026-11-01: re-entering at a crumb
    -- 2 m back walked Claude back up a drop he had just taken)
    local function search(from)
        local best, bi = math.huge, nil
        for i = from, #c do
            local p = c[i]
            if not p.air and not p.gap and math.abs(me.Z - p.Z) <= 100 then
                local d = d2(me, p)
                if d < best then best, bi = d, i end
            end
        end
        if not bi then return nil end
        local rem, score, pick = 0, math.huge, bi
        for i = #c, from, -1 do
            if i < #c then rem = rem + d2(c[i], c[i + 1]) end
            local p = c[i]
            if not p.air and not p.gap and math.abs(me.Z - p.Z) <= 100 then
                local d = d2(me, p)
                if d <= best + 300 and d + rem < score then score, pick = d + rem, i end
            end
        end
        return pick
    end
    if from_i and from_i > g + 1 then return search(from_i) end
    return (g > 0 and search(g + 1)) or search(1)
end

-- Skip points already reached, or passed (closer to the next one than this one is), but only at
-- the point's own level: |(me.Z - zoff) - p.Z| < dz_tol. zoff = 0 for capsule-centre points
-- (leader crumbs), ~90 for floor points (local plan cells, navmesh waypoints).
local function advance(pts, i, me, radius, dz_tol, zoff, local_edges)
    dz_tol, zoff = dz_tol or 60, zoff or 0
    while i <= #pts do
        local p, nxt = pts[i], pts[i + 1]
        local dz = math.abs((me.Z - zoff) - p.Z)
        if p.gap or (local_edges and (p.act == "superjump" or p.act == "jump" or p.act == "djump")) then break end -- local superjump requires verified landing
        -- slope-aware: an ordinary point may differ in height by ~0.9 x the horizontal distance
        -- (slopes up to ~42 deg); jump/link endpoints need us really up there (strict dz_tol)
        local strict = p.link or p.act == "jump" or p.act == "djump"
        local tol = strict and dz_tol or (dz_tol + 0.9 * d2(me, p))
        if (p.air or dz < tol) and (d2(me, p) < radius or (nxt and d2(me, nxt) < d2(p, nxt))) then
            i = i + 1
        else break end
    end
    return i
end

-- Optional modules, loaded once per load of this file: the module, or false when it is missing or broken
-- (key = a field it must have).
local MODS = {}
local function lazy(path, key)
    local m = MODS[path]
    if m == nil then
        local okc, chunk = pcall(loadfile, path)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        m = (okm and type(mod) == "table" and (key == nil or mod[key])) and mod or false
        MODS[path] = m
    end
    return m
end

-- ------------------------------------------------------------------ doors
-- A shut door in the way (his own house on the dev base, 2026-11-01): a player presses E on it. Built doors are
-- BP_BaseBuilding_BaseActor_C children (BP_T1_Door_C) with a HingeInteraction whose prompt reads "Open Door" when
-- shut and "Close Door" when open (probe 16:5xZ). The press is the game's own interact key (inventory.lua), aimed
-- from the camera the way the interaction detector casts.
local INV_PATH = ROOT .. "/client_mod/scripts/inventory.lua"
local function inv_mod() return lazy(INV_PATH, "press_interact") or nil end
function M.set_inventory(m) MODS[INV_PATH] = m or false end
local function door_prompt(a)
    local ok, s = pcall(function() return a.HingeInteraction.InteractionPrompt:ToString() end)
    return ok and type(s) == "string" and s or nil
end
local function door_name(a)
    local ok, s = pcall(function() return a:GetFName():ToString() end)
    return ok and s or tostring(a)
end
-- the shut door nearest to him (and toward the goal) within r_cm, or nil
local function shut_door_near(me, goal, r_cm)
    local best, bs
    local okf, all = pcall(FindAllOf, "BP_BaseBuilding_BaseActor_C")
    for _, a in ipairs(okf and type(all) == "table" and all or {}) do
        local okl, l = pcall(function() return a:K2_GetActorLocation() end)
        if okl and l and math.abs(l.X - me.X) < r_cm and math.abs(l.Y - me.Y) < r_cm and math.abs(l.Z - me.Z) < 300 then
            local d = d2(me, l)
            local pr = d <= r_cm and door_prompt(a)
            if pr and pr:lower():find("open", 1, true) then
                local score = d + 0.5 * (goal and d2(goal, l) or 0)
                if not bs or score < bs then best, bs = { actor = a, at = v(l), name = door_name(a), prompt = pr }, score end
            end
        end
    end
    return best
end
local function door_begin(st, t, log)
    if st.door or not st.pawn then return false end
    local okm, me = pcall(function() return st.pawn:K2_GetActorLocation() end)
    if not (okm and me) then return false end
    local d = shut_door_near(me, st.lp_far or st.goal, M.cfg.door_find_cm)
    st.door_tried = st.door_tried or {}
    if not d or (st.door_tried[d.name] or 0) >= 2 then return false end
    st.door_tried[d.name] = (st.door_tried[d.name] or 0) + 1
    d.t0, d.phase, d.presses = t, "approach", 0
    st.door = d
    if log then log(string.format("move: a shut door at (%.0f,%.0f) is in the way (%s); opening it", d.at.X / 100, d.at.Y / 100, tostring(d.prompt))) end
    return true
end
-- ------------------------------------------------------------------ the camera is shared: one choke point
-- Every control-rotation write of move goes through cam_write. Other skills aim the same camera: build env.aim,
-- deconstruct, gather/spells W.aim, interact face, client_bridge aim_at, farm/fishing/shoot face, the ranged aimer.
-- Live 2026-11-01 ~16:30Z the build's ceiling and roof failures read camera pitch 0 and move's yaw over every aim.
-- Before a write, the controller's rotation is compared with move's own last write: more than cam_taken_deg apart
-- means another skill aimed since, and move leaves the camera alone for cam_yield_s, renewed while that rotation
-- keeps changing; then it takes it back. AddMovementInput is world-space, so walking goes on meanwhile.
-- -> true (written), false (yielding), "taken" (another skill took it just now). st.cam is reset per move.
local function rot_apart(a, b)
    local function d(x, y) return math.abs(((tonumber(x) or 0) - (tonumber(y) or 0) + 540) % 360 - 180) end
    return math.max(d(a.Yaw, b.Yaw), d(a.Pitch, b.Pitch))
end
local function cam_write(st, pc, rot, t)
    local c = st.cam or {}
    st.cam = c
    if st.ws_job or st.ws_exec then c.w, c["until"], c.ref = nil, nil, nil end -- his own Windstep cast aims the camera
    local ok, cur = pcall(function() return pc:GetControlRotation() end)
    cur = (ok and type(cur) == "table" and tonumber(cur.Yaw)) and { Yaw = cur.Yaw, Pitch = cur.Pitch } or nil
    if c["until"] then
        if cur and c.ref and rot_apart(cur, c.ref) > M.cfg.cam_taken_deg then c["until"], c.ref = t + M.cfg.cam_yield_s, cur end
        if t < c["until"] then return false end
        c["until"], c.ref = nil, nil -- the other writer stopped moving it: take the camera back
    elseif c.w and cur and rot_apart(cur, c.w) > M.cfg.cam_taken_deg then
        c["until"], c.ref, c.taken_n = t + M.cfg.cam_yield_s, cur, (c.taken_n or 0) + 1
        return "taken"
    end
    pc:SetControlRotation(rot)
    c.w = { Yaw = rot.Yaw, Pitch = rot.Pitch }
    return true
end
-- a go_to that is the aiming skill's own child walk (its explicit arbiter owner still holds the pawn): aiming means
-- standing still, so the walk ends (stopped, camera_taken) instead of yielding
local function camera_taken_by_owner(st)
    if st.mode ~= "go_to" or not st.owner_token or st.owner_implicit then return false end
    local a = move_arbiter and move_arbiter()
    local ok, holds = pcall(function() return a and a.holds and a.holds(st.owner_token) end)
    return ok and holds == true
end

local function door_end(st, t, ok, why, log)
    local d = st.door
    st.door = nil
    if ok then
        st.doors_opened = (st.doors_opened or 0) + 1
        _G.DW_LP_CACHE = nil -- the cells it shut are open now
        st.lp_fail_t, st.lp_fail, st.lpath, st.lwp = nil, nil, nil, nil
        if log then log(string.format("move: opened the door at (%.0f,%.0f) in %.1f s", d.at.X / 100, d.at.Y / 100, t - d.t0)) end
    else
        st.door_fail = why
        if log then log(string.format("move: the door at (%.0f,%.0f) didn't open: %s", d.at.X / 100, d.at.Y / 100, why)) end
    end
end
-- one frame: walk up to it, aim from the camera, press when the detector targets it, verify the prompt flipped
local function door_step(f)
    local st, pawn, pc, t, me, log = f.st, f.pawn, f.pc, f.t, f.me, f.log
    local d = st.door
    local okv, valid = pcall(function() return d.actor:IsValid() end)
    if not (okv and valid) then door_end(st, t, false, "it's gone", log); return false end
    if t - d.t0 > 8 then door_end(st, t, false, "timed out (" .. d.phase .. ")", log); return false end
    st.win_t, st.win_pos = t, v(me)
    if st.prog_t then st.prog_t = st.prog_t + (f.dt or 0) end
    st.status = "door"
    local dist = d2(me, d.at)
    if d.phase == "approach" then
        if dist > M.cfg.door_reach_cm and t - d.t0 < 4 then
            local ux, uy = (me.X - d.at.X) / dist, (me.Y - d.at.Y) / dist
            local dx, dy = d.at.X + ux * (M.cfg.door_reach_cm - 60) - me.X, d.at.Y + uy * (M.cfg.door_reach_cm - 60) - me.Y
            local l = math.sqrt(dx * dx + dy * dy)
            if l > 20 then
                cam_write(st, pc, { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }, t)
                pawn:AddMovementInput({ X = dx / l, Y = dy / l, Z = 0 }, 1.0, false)
                return true
            end
        end
        d.phase, d.aim_t = "aim", t
    end
    if d.phase == "aim" then
        local okc, cam = pcall(function() return pc.PlayerCameraManager:GetCameraLocation() end)
        local o = (okc and type(cam) == "table" and tonumber(cam.X)) and cam or me
        local dx, dy, dz = d.at.X - o.X, d.at.Y - o.Y, d.at.Z - o.Z
        cam_write(st, pc, { Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }, t)
        local inv = inv_mod()
        if not inv then door_end(st, t, false, "no interact key (inventory module)", log); return false end
        local okt, tg = pcall(inv.interact_target, pawn)
        local on = okt and type(tg) == "table" and tg.prompt and tostring(tg.prompt):lower():find("door", 1, true)
        if on and t - d.aim_t > 0.1 then
            pcall(inv.press_interact, log)
            d.phase, d.press_t, d.presses = "wait", t, d.presses + 1
        elseif t - d.aim_t > 2.0 then
            door_end(st, t, false, "I couldn't get it in my sights (" .. tostring(okt and type(tg) == "table" and tg.prompt or "nothing targeted") .. ")", log)
            return false
        end
        return true
    end
    if d.phase == "wait" then
        if t - d.press_t < 0.5 then return true end
        local pr = door_prompt(d.actor)
        if pr and not pr:lower():find("open", 1, true) then door_end(st, t, true, nil, log); return false end
        if d.presses < 2 then d.phase, d.aim_t = "aim", t; return true end
        door_end(st, t, false, "it stayed shut after 2 presses", log)
        return false
    end
    return false
end

-- ------------------------------------------------------------------ local planner glue
local function lp_cache()
    _G.DW_LP_CACHE = _G.DW_LP_CACHE or { cells = {}, ttl = M.cfg.lp_cache_ttl_s }
    return _G.DW_LP_CACHE
end

-- Prefetch cone ahead of us (forward 2..8 m, lateral -3..3 m), nearest first.
local CONE = {}
for f = 2, 8 do for l = -3, 3 do CONE[#CONE + 1] = { f, l } end end
table.sort(CONE, function(a, b) return a[1] * a[1] + a[2] * a[2] < b[1] * b[1] + b[2] * b[2] end)

local function tl_module() return lazy(TL_PATH, "best_link") end
local function az_module() return lazy(AZ_PATH, "normalize") end
-- zones live in _G (not in the per-move state): they outlast commands and reloads of this file
local function avoid()
    _G.DW_AVOID = _G.DW_AVOID or { zones = {}, ver = 0 }
    return _G.DW_AVOID
end
local function live_zones(t)
    local A = avoid()
    local AZm = az_module()
    if AZm and t and #A.zones > 0 then AZm.prune(A.zones, t) end
    return A.zones, AZm
end

local function nm_module() return lazy(NM_PATH, "plan") end

-- The world id (mod/body/util.lua U.world_id), re-resolved on every call: route authority must not use
-- the resolver's 60 s joined-server cache.
world_identity = function()
    local util = lazy(ROOT .. "/mod/body/util.lua", "world_id")
    if not util then return nil end
    local ok, id = pcall(util.world_id, ROOT, { cache_s = 0 })
    if not ok or type(id) ~= "string" or id == "" or id == "unknown" then return nil end
    return id
end
-- No admitted route (oracle absent, no_path, partial or ended route): hand the move back to the
-- baseline sources (local planner on real collision, leader trail, navmem, stuck ladder) instead of
-- failing it. Straight steering at the raw goal is then drop-guarded (drop_ahead below): the one
-- death this rule exists for was a beeline at a goal 30 m down into a KillZVolume (DISCOVERIES).
local function route_fallback(st, why, log)
    st.nav_required, st.nav_deferred_required, st.nav_wait_t, st.prov = nil, nil, nil, nil
    st.local_authority, st.local_binding = nil, nil
    st.nav_fallback = tostring(why or "no_route")
    if log then log("move: no admitted route (" .. st.nav_fallback .. "); local planning, drop-guarded") end
end
-- Floor ahead of the feet along (dx, dy)? "drop" when nothing is within 4 m below or it is > 2.5 m down
-- (same thresholds as escape_line_clear).
-- a drop (no floor within 2.5 m below) or ground too steep to stand on (walk_z) 1.5 m ahead
local function drop_ahead(pawn, me, feet, dx, dy, walk_z)
    local x, y = me.X + dx * 150, me.Y + dy * 150
    local ok, hit, out = pcall(raw_trace, pawn, { X = x, Y = y, Z = feet + 150 }, { X = x, Y = y, Z = feet - 400 })
    if not ok then return false end
    if not (hit and out.ImpactPoint) or out.ImpactPoint.Z < feet - 250 then return true end
    local nz = out.ImpactNormal and tonumber(out.ImpactNormal.Z)
    return walk_z ~= nil and nz ~= nil and nz < walk_z
end
-- Can Claude walk the straight line me -> c? (wall at knee height, holes/ledges, steep climbs)
local function escape_line_clear(pawn, me, feet, c)
    local dx, dy = c.X - me.X, c.Y - me.Y
    local L = math.max(math.sqrt(dx * dx + dy * dy), 1)
    local hx, hy = dx / L, dy / L
    local knee = feet + 50
    if L > 60 then
        -- from 55 cm out: from his centre the ray hits his own gear (live 19:22)
        local okp, hit, out = pcall(raw_trace, pawn, { X = me.X + hx * 55, Y = me.Y + hy * 55, Z = knee },
            { X = c.X + hx * 30, Y = c.Y + hy * 30, Z = knee })
        if not okp then return "trace_error" end
        if hit and ((out.ImpactNormal and out.ImpactNormal.Z or 0) < M.cfg.probe_wall_nz) then return "wall" end
    end
    local n = math.max(1, math.ceil(L / 150))
    for k = 1, n do
        local f = k / n
        local x, y = me.X + dx * f, me.Y + dy * f
        local okd, hitd, outd = pcall(raw_trace, pawn, { X = x, Y = y, Z = feet + 150 }, { X = x, Y = y, Z = feet - 400 })
        if not okd then return "trace_error" end
        if not (hitd and outd.ImpactPoint) then return "drop" end
        if tonumber(outd.Distance) == 0 then return "inside_geometry" end
        local fz = outd.ImpactPoint.Z
        if fz < feet - 250 then return "drop" end
        if fz > feet + 60 + 0.7 * L * f then return "climb" end
    end
    return true
end
local function route_owned(st, gen, pawn, pc)
    local b = st.nav_binding
    if not b then return false end
    local token, world = b.token, b.world
    local a = move_arbiter()
    local ok, owns = pcall(function() return a and a.owns_move and a.owns_move(token) end)
    local okp, current_pawn = pcall(function() return pc.Pawn end)
    local current_world = world_identity()
    local arb = rawget(_G,"DWArbiter")
    local owner = arb and arb.owner
    return ok and owns == true and okp and current_pawn == pawn and not paused() and
        rawget(_G,"DW_MOVE") == st and st.gen == gen and st.owner_token == token and
        st.pawn == pawn and b.gen == gen and b.pawn == pawn and world ~= nil and
        current_world == world and owner and owner.token == token
end
local function local_route_owned(st, gen, pawn, pc, goal)
    local b = st.local_binding
    if not b or b.gen ~= gen or b.pawn ~= pawn or b.pc ~= pc or b.token ~= st.owner_token or
        b.life ~= st.life_seq or b.half_h ~= st.half_h or b.target ~= st.target or
        (st.local_authority and st.lpath ~= b.path) or not goal or
        goal.X ~= b.goal.X or goal.Y ~= b.goal.Y or goal.Z ~= b.goal.Z then return false end
    local arb = rawget(_G, "DWArbiter")
    if arb ~= b.arb or not arb or arb.owner ~= b.owner then return false end
    local world = world_identity()
    local okh, hh = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local okg, current = pcall(function()
        if st.target_name then return st.target:K2_GetActorLocation() end
        return st.goal
    end)
    if not world or world ~= b.world or not okh or hh ~= b.half_h or not okg or not current or
        current.X ~= b.goal.X or current.Y ~= b.goal.Y or current.Z ~= b.goal.Z or
        not owned(binding(st, pawn)) then return false end
    local world_again = world_identity()
    local ok_again, current_again = pcall(function()
        if st.target_name then return st.target:K2_GetActorLocation() end
        return st.goal
    end)
    local okpawn, final_pawn = pcall(function() return pc.Pawn end)
    local life = rawget(_G,"DW_LIFE")
    local life_seq = type(life)=="table" and (life.move_death_seq or 0) or 0
    return okpawn and final_pawn == pawn and life_seq == b.life and
        ok_again and current_again and current_again.X == b.goal.X and current_again.Y == b.goal.Y and
        current_again.Z == b.goal.Z and world_again == b.world and not paused() and
        rawget(_G,"DW_MOVE") == st and st.gen == gen and st.local_binding == b and
        rawget(_G,"DWArbiter") == arb and arb.owner == b.owner and st.owner_token == b.token and
        st.half_h == b.half_h and st.life_seq == b.life and st.target == b.target and
        (not st.local_authority or st.lpath == b.path)
end
-- The per-world navigation memory (cached in _G.DW_NAVMEM across reloads of this file).
local function nav_mem()
    local NMm = nm_module()
    if not NMm then return nil end
    -- the world: the shared resolver (mod/body/util.lua U.world_id: explicit, else the joined server, else
    -- "unknown"; never a silent "shockbyte"), re-resolved at most every 5 s (nav_mem runs per planner cell)
    local wc = rawget(_G, "DW_MOVE_WORLD")
    local tw = os.time()
    if not wc or tw - wc.t >= 5 then
        local w = world_identity() or "unknown"
        wc = { t = tw, id = w }
        _G.DW_MOVE_WORLD = wc
    end
    local world = wc.id
    local m = rawget(_G, "DW_NAVMEM")
    if not m or m._world ~= world then
        local okl, loaded = pcall(NMm.load, ROOT, world, "L_World")
        m = okl and loaded or nil
        _G.DW_NAVMEM = m
    end
    return m, NMm
end

local function feet_of(st, p) return { X = p.X, Y = p.Y, Z = p.Z - (st.half_h or 90) } end
-- a spot that killed him (skills.record_death: a fall's last ground), in nav memory; at = {x,y,z} metres
function M.mark_hazard(at, info)
    local mem, NMm = nav_mem()
    if not (mem and NMm and NMm.mark_hazard and type(at) == "table") then return nil end
    local h, new = NMm.mark_hazard(mem, { X = at[1] * 100, Y = at[2] * 100, Z = at[3] * 100 }, info)
    pcall(NMm.save, mem)
    return h, new
end
-- A walk that started inside a known trap and got out of it (or where it was going) with no stuck and without its
-- exit counts against the trap (navmem.trap_miss), which is forgotten once such walks outnumber its escapes. t227
-- (2026-11-01) was learned between house walls at 13:29Z; the walls changed, but its exit was walked first on
-- every start in its 8 m (128 uses, 1 escape: cook walked 18 m to end 4 m away) and nothing counted against it.
local function trap_evidence(st, how, log)
    if not st.trap_start or st.trap_judged or st.trap_exit_taken then return end
    if (st.stuck_total or 0) > (st.trap_stuck0 or 0) then return end
    st.trap_judged = true
    local mem, NMm = nav_mem()
    if not (mem and NMm.trap_miss) then return end
    local okm, t, dropped = pcall(NMm.trap_miss, mem, st.trap_start)
    if not (okm and t) then return end
    pcall(NMm.save, mem)
    local cand = rawget(_G, "DW_TRAP_CAND")
    if cand and cand.trap == st.trap_start then _G.DW_TRAP_CAND = nil end
    if log then log(string.format("move: memory: trap %s: I %s with no stuck and without its exit (%d such walks; it shut me in %d time(s))%s",
        tostring(t.id), how, t.n_bad or 0, t.n_ok or 1, dropped and "; not a trap any more: forgotten" or "")) end
end

-- A remembered route that really REACHES the goal: its last walked point is within goal_reach_cm of the goal on
-- the goal's level. Used when the oracle's route ends short (the NPC navmesh misses the church ramp a player
-- walks: live 2026-10-31, every route to the lodestone ended on the terrace outside, 13 m off and 4 m up), and
-- before a learned trap's exit (a junk trap's "exit" walked away from the goal). The detour may be long: the
-- direct way is already known to fail.
local function mem_goal_plan(st, me, goal)
    local mem, NMm = nav_mem()
    if not mem then return nil end
    local gfe = feet_of(st, goal)
    local okp, pts = pcall(NMm.plan, mem, feet_of(st, me), gfe, { max_factor = M.cfg.mem_goal_factor })
    if not (okp and pts and #pts >= 2) then return nil end
    local last = pts[#pts - 1] -- pts[#pts] is the goal itself
    if d2(last, gfe) > M.cfg.mem_goal_reach_cm or math.abs(last.Z - gfe.Z) > 200 then return nil end
    return pts
end

-- Persist what this move learned: Claude's own trip (only if it got somewhere: arrived, or a follow
-- that reached the leader) and the leader's walked trail (human-proven). Called when a move ends,
-- including when a new command interrupts it (live 19:42: a follow's demo trail was lost that way).
local function mem_flush(st, log, why)
    local gen, token, trip, crumbs = st.gen, st.owner_token, st.trip, st.crumbs
    local function current()
        return rawget(_G,"DW_MOVE")==st and st.gen==gen and st.owner_token==token and st.trip==trip and st.crumbs==crumbs
    end
    local mem, NMm = nav_mem()
    if not mem or not current() then return end
    local changed = false
    if st.trip and #st.trip >= 2 and st.trip_ok then
        local okr, r, how = pcall(NMm.add_route, mem, st.trip, { src = "self" })
        if not current() then return end
        if okr and r then changed = true; if log then log("move: memory: self route " .. tostring(r.id) .. " " .. tostring(how)) end end
        if not current() then return end
    end
    if st.target_kind == "player" and st.crumbs and #st.crumbs - (st.crumb_mark or 0) >= 2 then
        local pts = {}
        for k = math.max(1, st.crumb_mark or 1), #st.crumbs do
            local c = st.crumbs[k]
            if not c.air and not c.gap then pts[#pts + 1] = { X = c.X, Y = c.Y, Z = c.Z - (st.half_h or 90) } end
        end
        st.crumb_mark = #st.crumbs
        local okr, r, how = pcall(NMm.add_route, mem, pts, { src = "demo:" .. tostring(st.target_name) })
        if not current() then return end
        if okr and r then changed = true; if log then log("move: memory: leader route " .. tostring(r.id) .. " " .. tostring(how)) end end
        if not current() then return end
    end
    if changed then pcall(NMm.save, mem) end
    if not current() then return end
    st.trip, st.trip_ok = nil, nil
end

local LP_MOD
local function lp_module()
    if LP_MOD == nil then
        local chunk = loadfile(LP_PATH)
        LP_MOD = chunk and chunk() or false
    end
    return LP_MOD
end

-- ------------------------------------------------------------------ traversal moves beyond a jump
-- (data profile scripts/traversal_moves.lua). Double jump: the perk (envelope) + a MEASURED rise. Windstep
-- (a super-jump spell): castable now per the spells module (unlock, wheel, runes, cooldown: the game's own
-- gates, spells.ability_status) + a MEASURED rise. Execution: the player's own cast input (spells.cast_now,
-- borrowing the pawn: no arbiter hand-over mid-move), then the jump at the take-off point.
local function tm_profile() return lazy(TM_PATH) or {} end
local function spells_mod() return lazy(SP_PATH, "ability_status") or nil end
-- tests (and the bridge) may inject the spells module: {ability_status(asset[, api]), cast_now(log, asset, opts)}
function M.set_spells(m) MODS[SP_PATH] = m or false end

-- Windstep's state from the spells module -> {state = castable|unlock|runes|cooldown|wheel|busy|unknown, why, detail}
local WS_STATE = { not_unlocked = "unlock", not_enough_resources = "runes", on_cooldown = "cooldown", not_on_wheel = "wheel",
                   busy = "busy", requirement = "busy" }
local function windstep_status(api, now_t, fresh)
    local prof = tm_profile().windstep
    if not prof or not prof.spell_asset then return { state = "unknown", detail = "no traversal profile" } end
    local m = rawget(_G, "DW_MOVE_WS")
    if not fresh and m and now_t and m.t and math.abs(now_t - m.t) < 1.0 then return m.r end
    local sp = spells_mod()
    local r
    if not sp then r = { state = "unknown", detail = "no spells module" }
    else
        local ok, a = pcall(sp.ability_status, prof.spell_asset, api)
        if not ok or type(a) ~= "table" then r = { state = "unknown", detail = tostring(a) }
        elseif a.available then r = { state = "castable", cooldown_s = a.cooldown_s }
        else r = { state = WS_STATE[a.why or ""] or "unknown", why = a.why, detail = a.detail, cooldown_s = a.cooldown_s } end
    end
    _G.DW_MOVE_WS = { t = now_t, r = r }
    return r
end
M._windstep_status = windstep_status

-- What he can do to get UP, with heights only from measurements. Pure. -> caps table (also get_state.traversal)
function M.traverse_caps(env, ws)
    env, ws = env or {}, ws or { state = "unknown" }
    local P = tm_profile()
    local djp, wsp = P.double_jump or {}, P.windstep or {}
    local function m(cm) return cm and math.floor(cm + 0.5) / 100 or nil end
    return {
        jump = { have = true, up_m = m(env.jump), measured = env.jump_measured == true },
        double_jump = { have = env.double_jump == true, measured = env.dj_measured == true,
                        up_m = env.dj_measured and m(env.dj_measured_up_cm or env.djump) or nil,
                        unlock = env.dj_level and ("Agility " .. env.dj_level) or djp.unlock,
                        planned = env.double_jump == true and env.dj_measured == true },
        windstep = { have = ws.state ~= "unlock" and ws.state ~= "unknown", state = ws.state, castable = ws.state == "castable",
                     measured = env.ws_up_cm ~= nil, up_m = m(env.ws_up_cm), detail = ws.detail, cooldown_s = ws.cooldown_s,
                     unlock = (ws.detail and ws.detail:match("needs (%a+ level %d+)") or wsp.unlock or ""):gsub(" level", ""),
                     planned = ws.state == "castable" and env.ws_up_cm ~= nil },
        source = env.source,
    }
end

-- Why can't he get up a rise of rise_cm? Pure. -> reason | nil (nil: a move he HAS and has MEASURED covers it,
-- so the height is not the blocker). Reasons: "needs:<Move>:<lack>[:<info>]" (lack = unmeasured | cooldown |
-- busy | runes | wheel | unlock), "<who>_above_windstep_height" (Windstep measured + castable, still too high),
-- "<who>_above_jump_height" (no move he has or could get reaches it).
local LACK_RANK = { unmeasured = 0, cooldown = 1, busy = 1, runes = 2, wheel = 2, unlock = 3 }
function M.height_verdict(rise_cm, caps, who)
    who = who or "target"
    local P = tm_profile()
    local slack = 60 -- the same slack as the jump reach check (goal tolerance)
    local jr = ((caps.jump and caps.jump.up_m) or 1.65) * 100 + slack
    if rise_cm <= jr then return nil end
    local best, best_rank
    local function consider(key, c, prof, lack, info)
        local rank = LACK_RANK[lack]
        if rank and (not best_rank or rank < best_rank) then
            best_rank = rank
            best = "needs:" .. prof.key .. ":" .. lack .. ((info and info ~= "") and (":" .. tostring(info):gsub(":", " ")) or "")
        end
    end
    local function could(c, prof) -- can it plausibly reach? measured -> exactly; else the profile's claim bound
        if c.measured and c.up_m then return rise_cm <= c.up_m * 100 + slack end
        local bound = prof.expect_up_m or prof.claim_max_m
        return bound ~= nil and rise_cm <= bound * 100 + slack
    end
    local dj, djp = caps.double_jump or {}, P.double_jump
    if djp and could(dj, djp) then
        if not dj.have then consider("double_jump", dj, djp, "unlock", dj.unlock)
        elseif not dj.measured then consider("double_jump", dj, djp, "unmeasured")
        else return nil end
    end
    local ws, wsp = caps.windstep or {}, P.windstep
    if wsp and could(ws, wsp) then
        local st = ws.state
        if st == "castable" then
            if ws.measured then return nil end
            consider("windstep", ws, wsp, "unmeasured")
        elseif st == "unlock" then consider("windstep", ws, wsp, "unlock", ws.unlock)
        elseif st == "runes" then
            local n, what, have = tostring(ws.detail or ""):match("needs (%d+) (.-) and I only have (%d+)")
            consider("windstep", ws, wsp, "runes", n and (n .. " " .. what .. ", have " .. have) or nil)
        elseif st == "cooldown" then consider("windstep", ws, wsp, "cooldown", ws.cooldown_s and math.ceil(ws.cooldown_s) or nil)
        elseif st == "wheel" or st == "busy" then consider("windstep", ws, wsp, st) end
    end
    if best then return best end
    if ws.state == "castable" and ws.measured then return who .. "_above_windstep_height" end
    return who .. "_above_jump_height"
end

local function caps_of(st, t)
    return M.traverse_caps(st.env, windstep_status(nil, t))
end
-- the height reason for a move (who = leader|target), nil when the height is not the blocker
local function height_reason(st, rise_cm, who, t)
    local okv, r = pcall(M.height_verdict, rise_cm, caps_of(st, t), who)
    if okv then return r end
    return who .. "_above_jump_height"
end

-- Over the carry weight (UPlayerEncumbranceComponent, read-only getters): the game's encumbered penalty slows him to
-- 0.6 x walk (2.7 m/s), and sprint and jumps fail (live 2026-11-01 13:18Z: 446.5 of 300 after a grave pickup, the
-- recorder read 2.70 m/s, "a double jump never left the ground"). {on, cur, max} or nil when unreadable.
local function encumbrance(pawn)
    local ok, ec = pcall(function() return pawn.PlayerEncumbranceComponent end)
    if not (ok and ec and ec:IsValid()) then return nil end
    local ok1, on = pcall(function() return ec:IsEncumbered() end)
    if not ok1 or type(on) ~= "boolean" then return nil end
    local ok2, cur = pcall(function() return ec:GetCurrentCarryWeight() end)
    local ok3, mx = pcall(function() return ec:GetMaxCarryWeight() end)
    return { on = on, cur = ok2 and tonumber(cur) or nil, max = ok3 and tonumber(mx) or nil }
end
local function heavy(st) return st.enc ~= nil and st.enc.on == true end
-- his carry weight for the brain (skills.lua state bag): {on, cur, max} or nil (live 00:24Z: 403/400, walk only, and
-- the model never knew)
function M.encumbrance()
    local pc = local_pc()
    local okp, pawn = pcall(function() return pc and pc.Pawn end)
    if not (okp and pawn and pawn:IsValid()) then return nil end
    local ok, e = pcall(encumbrance, pawn)
    return ok and e or nil
end

local function lp_begin(st, pawn, me, far, why, log, observe)
    local LP = lp_module()
    if not LP then return false end
    local generation, pc = st.gen, st.pc
    local function valid() return not observe or local_route_owned(st,generation,pawn,pc,far) end
    local hh = observe and st.half_h or half_h(pawn)
    local env = st.env or envelope(pawn, pc)
    if not valid() then return false end
    st.env = env
    if st.max_drop_cm then st.env.drop = math.min(st.env.drop or st.max_drop_cm, st.max_drop_cm) end
    -- a Windstep super-jump edge only while it is castable now AND measured (and not just failed on this move)
    do
        local ws = st.env.ws_up_cm and windstep_status(nil, now(pawn)) or nil
        if not valid() then return false end
        st.env.superjump = (ws and ws.state == "castable") and st.env.ws_up_cm or nil
        st.env.superjump_cost = (tm_profile().windstep or {}).cost
    end
    local trace = observe and make_observation_trace(st,pawn,me,hh,valid) or make_trace(st,pawn)
    if not valid() then return false end
    local penv = st.env
    if heavy(st) then -- encumbered: jumps fail, so no jump edges (a copy: the envelope comes back once he is lighter)
        penv = {}
        for k, x in pairs(st.env) do penv[k] = x end
        penv.jump, penv.djump, penv.superjump = 0, 0, nil
    end
    local up_near = far and d2(me, far) < 1500 and (far.Z - (me.Z - hh)) > 300
    local planner = LP.new({ trace = trace, center = v(me), feet_z = me.Z - hh,
        radius_m = up_near and M.cfg.lp_grid_up_m or M.cfg.lp_grid_m, cell_cm = M.cfg.lp_cell_cm, env = penv,
        cache = not observe and lp_cache() or nil, now = function() return now(pawn) end, self_pos = v(me), avoid = st.jump_fail,
        cell_cost = not observe and function(x, y, fz)
            local mem, NMm = nav_mem()
            local c = (mem and not st.wade and NMm.is_water(mem, { X = x, Y = y })) and M.cfg.water_cell_cost or 0 -- opts.wade: water is no detour
            local zs, AZm = avoid().zones, az_module()
            if AZm and #zs > 0 then c = c + AZm.cost(zs, x, y, fz, st.lp_clock, M.cfg.avoid_margin_cm) end
            return c
        end,
        -- a goal IN water (a pond to drink from, a ford) is aimed at as it is: no swap for dry ground
        dry_slack = not observe and (function()
            local mem, NMm = nav_mem()
            if st.wade or (mem and NMm.is_water(mem, { X = far.X, Y = far.Y }) and d2(me, far) < M.cfg.lp_grid_m * 100) then return -math.huge end
            return (#avoid().zones > 0) and M.cfg.avoid_dry_slack_cm or nil
        end)(),
        water_probe = not observe and rawget(_G, "DW_WATER_CH") and function(x, y, floor_z)
            if water_at(pawn, x, y, floor_z) then
                local mem, NMm = nav_mem()
                if mem then NMm.mark_water(mem, { X = x, Y = y, Z = floor_z }) end
                return true
            end
            return false
        end or nil })
    if not valid() then return false end
    local plan_time = now(pawn)
    if not valid() then return false end
    st.lp, st.lp_t0 = planner, plan_time
    st.lp_clock = st.lp_t0 -- zone costs are taken at plan time (sooner-ending zones are cheaper)
    st.lp_zver = avoid().ver
    local plan_goal = v(far)
    if observe then plan_goal.Z = plan_goal.Z - hh end -- planner nodes and heuristic use floor height
    st.lp_far, st.lp_state, st.lp_why, st.lp_observe = plan_goal, "sampling", why, observe == true
    st.lp_runs = (st.lp_runs or 0) + 1
    st.lp_plans_np = (st.lp_plans_np or 0) + 1
    if log then log(string.format("move: local plan #%d (%s) at %s toward %s", st.lp_runs, why, fmt(me), fmt(far))) end
    return true
end

-- One frame of planner work. Returns true while the planner owns this frame (we stand still).
local function lp_work(st, t, log)
    local P, generation, observation = st.lp, st.gen, st.lp_observe
    local function current() return not observation or (st.gen == generation and st.lp == P and st.local_binding and
        local_route_owned(st,generation,st.pawn,st.pc,st.local_binding.goal)) end
    if st.lp_state == "sampling" then
        local state = P:step(M.cfg.lp_budget)
        if not current() then return false end
        if state == "ready" then
            local pts, why = P:plan(st.lp_far)
            if not current() then return false end
            if not pts then
                st.lp, st.lp_state, st.lp_fail_t, st.lp_fail = nil, nil, t, why
                if log then log("move: local plan failed: " .. tostring(why)) end
                if not st.lp_observe then st.want_trail = true; door_begin(st, t, log) end -- ordinary replans only
                return false
            end
            st.lp_pts, st.lp_state, st.lp_rounds = pts, "verifying", 0
        end
        return true
    elseif st.lp_state == "verifying" then
        local r = P:verify(st.lp_pts, M.cfg.lp_budget)
        if not current() then return false end
        if r == "blocked" then
            st.lp_rounds = st.lp_rounds + 1
            local pts = st.lp_rounds <= 12 and P:plan(st.lp_far) or nil
            if not current() then return false end
            if not pts then
                st.lp, st.lp_state, st.lp_fail_t, st.lp_fail = nil, nil, t, "verify_exhausted"
                if log then log("move: local plan failed: walls everywhere (" .. table.concat(P.block_log or {}, " ") .. ") hops=" .. tostring(P.hops) .. " steeps=" .. tostring(P.steeps) .. " firstseg=" .. tostring(P.first_blocks)) end
                if not st.lp_observe then st.want_trail = true; door_begin(st, t, log) end
                return false
            end
            st.lp_pts = pts
        elseif r == "ok" then
            if st.lp_observe then st.lp_state = "observed"; return false end
            st.lpath, st.lwp, st.lp_state = st.lp_pts, 2, nil
            st.lp_jumped = {}
            local acts = {}
            for _, p in ipairs(st.lpath) do acts[#acts + 1] = p.leap and "l" or p.act:sub(1, 1) end
            st.lp_stand_s = t - (st.lp_t0 or t)
            local zs, AZm = live_zones(t)
            if AZm and #zs > 0 then
                -- a cost, not a wall: when no other way exists the plan crosses (the soonest-ending zone)
                local zc = AZm.on_route(zs, st.lpath[1], st.lpath, 2, nil, M.cfg.avoid_margin_cm)
                if zc and log then log(string.format("move: no way round avoid zone %s; crossing it (ends in %.1fs)", zc.id, zc.until_s - t)) end
            end
            if log then
                local at = {}
                for _, p in ipairs(st.lpath) do at[#at + 1] = string.format("%.0f,%.0f,%.1f", p.X / 100, p.Y / 100, p.Z / 100) end
                log(string.format("move: local path %d pts [%s] traces=%d cache_hits=%d replans=%d stand=%.2fs end=%s pts=%s",
                    #st.lpath, table.concat(acts), P.traces, P.cache_hits or 0, st.lp_rounds, st.lp_stand_s, fmt(st.lpath[#st.lpath]),
                    table.concat(at, " ")))
            end
            st.lp = nil
            return false
        end
        return true
    end
    return false
end

-- ------------------------------------------------------------------ the loop
move_arbiter = function()
    local ok, a = pcall(function()
        local arb = assert(loadfile(ROOT .. "/client_mod/scripts/arbiter.lua"))()
        assert(type(arb) == "table" and type(arb.set_move) == "function", "arbiter setter unavailable")
        arb.set_move(M) -- use this active mover for housekeeping, without another move.lua load
        return arb
    end)
    return ok and a or nil
end

local function release_implicit(st, log)
    if not st.owner_implicit or not st.owner_token then return end
    local a = move_arbiter()
    local token = st.owner_token
    st.owner_token, st.owner_implicit = nil, nil
    if a and a.release_implicit then pcall(a.release_implicit, log, token) end
end

local function cancel_superjump(st)
    local job = st.ws_job
    st.ws_job = nil -- cancellation can re-enter movement cleanup
    if job and job.cancel then pcall(job.cancel) end
end

-- ------------------------------------------------------------------ trip record (PLAN fix 2)
-- One row per go_to/follow in client_io/events/trips.jsonl, and ONE plain sentence on the result (result.trip),
-- computed from what the body measured: start/end, metres walked, closest approach, "moving away", where the
-- walkable map (oracle route) ended, falls, and whether the navigation helper was there at all.

local TRIPS = ROOT .. "/client_io/events/trips.jsonl"
local function m1(x) return math.floor(x * 10 + 0.5) / 10 end
local function trip_report(st, result)
    local tr = st.trip_rec
    if not (tr and tr.goal and tr.last) or (st.mode ~= "go_to" and st.mode ~= "follow") then return nil end
    local hh = st.half_h or 88
    local secs = math.max(0, (tr.t1 or tr.t0) - tr.t0)
    local endd, moved = tr.dist or d2(tr.last, tr.goal), tr.path / 100
    local arrived = result.status == "arrived"
    local fall = tr.fall
    local from = tr.air_top and (tr.air_from or tr.air_top)
    if from and from - tr.last.Z > fall then fall = from - tr.last.Z end
    local net = d2(tr.start, tr.last) / 100
    local bits = {}
    if not arrived and st.mode == "go_to" then
        bits[#bits + 1] = string.format("%.0f m left (closest %.0f m)", endd / 100, tr.best / 100)
        if endd > tr.d0 + 300 then
            bits[#bits + 1] = string.format("moving away: %.0f m further from the goal than at the start", (endd - tr.d0) / 100)
        end
        local dz = (tr.goal.Z - tr.last.Z) / 100
        if math.abs(dz) >= 2 then bits[#bits + 1] = string.format("the goal is %.0f m %s me", math.abs(dz), dz > 0 and "above" or "below") end
        if st.nav_end and d2(st.nav_end, tr.goal) > 300 then
            local h = (tr.goal.Z - (st.nav_end.Z + hh)) / 100
            bits[#bits + 1] = string.format("the walkable map ends %.0f m short of the goal, %.0f m %s it", d2(st.nav_end, tr.goal) / 100,
                math.abs(h), h >= 0 and "below" or "above")
        end
    end
    if fall > 300 then bits[#bits + 1] = string.format("fell %.1f m", fall / 100) end
    -- ground covered that got him nowhere (round in circles, back and forth): the net move says it
    if moved >= 3 and net < moved * 0.5 then bits[#bits + 1] = string.format("I ended up %.0f m from where I started", net) end
    -- endurance 0 (no rest) scales his stamina down: no sprint, and jumps fail (live 21:14-21:24: sprint 0 s on every
    -- trip, "a double jump never left the ground", the ladder 10/10 -> 7/10 until he rested)
    local okE, endu = pcall(function() return st.pawn.EnduranceComponent:GetCurrentEndurance() end)
    if okE and type(endu) == "number" and endu <= 0.5 then
        bits[#bits + 1] = "I'm exhausted (endurance 0): no sprinting and my jumps fail until I rest in a bed or shelter"
    end
    if heavy(st) then
        bits[#bits + 1] = string.format("I'm carrying too much (%.0f of %.0f weight): I can only walk slowly, and I can't sprint or jump until I drop or store some",
            st.enc.cur or 0, st.enc.max or 0)
    end
    local fb = st.nav_fallback
    local nav_down = fb == "oracle_unavailable" or fb == "oracle_timeout"
    if nav_down then bits[#bits + 1] = "the navigation helper was unavailable, so I steered by what I could see" end
    if st.trip_notes and #st.trip_notes > 0 then
        local order, n = {}, {}
        for _, x in ipairs(st.trip_notes) do
            if not n[x] then order[#order + 1] = x; n[x] = 0 end
            n[x] = n[x] + 1
        end
        for i, x in ipairs(order) do order[i] = n[x] > 1 and (x .. " (" .. n[x] .. "x)") or x end
        bits[#bits + 1] = table.concat(order, ", ")
    end
    local sentence = string.format("%s %.0f m in %.0f s (%.1f m/s) from %s to %s", moved < 1 and "Moved" or "Walked", moved, secs,
        secs > 0 and moved / secs or 0, m3s(tr.start), m3s(tr.last)) .. (#bits > 0 and ("; " .. table.concat(bits, "; ")) or "") .. "."
    local function pm(q) return q and { m1(q.X / 100), m1(q.Y / 100), m1(q.Z / 100) } or nil end
    local src = {}
    for k, x in pairs(tr.src_t) do src[k] = m1(x) end
    local act = rawget(_G, "__dwc_act")
    local row = { type = "trip", id = st.cmd_id or (type(act) == "table" and act.act or nil), ts = now_ts(), iso = os.date("!%Y-%m-%dT%H:%M:%SZ"), mode = st.mode, status = result.status,
        reason = result.reason, gen = st.gen, target = st.target_name, start = pm(tr.start), ["end"] = pm(tr.last), goal = pm(tr.goal),
        d0_m = m1(tr.d0 / 100), end_m = m1(endd / 100), closest_m = m1(tr.best / 100), walked_m = m1(moved), net_m = m1(net), s = m1(secs),
        sprint_s = m1(tr.sprint_t), src_s = src, zmin_m = m1(tr.zmin / 100), zmax_m = m1(tr.zmax / 100),
        fell_m = fall > 300 and m1(fall / 100) or nil, nav_end = pm(st.nav_end), nav_fallback = fb, nav_requests = st.nav_requests,
        lp_runs = st.lp_runs, stuck_total = st.stuck_total, backtracks = st.backtracks, notes = st.trip_notes,
        endurance = okE and type(endu) == "number" and m1(endu) or nil, sentence = sentence }
    local okr, J = pcall(require, "jsonutil")
    local okj, line = false, nil
    if okr and J then okj, line = pcall(J.encode, row) end
    local f = okj and line and io.open(TRIPS, "a")
    if f then f:write(line, "\n"); f:close() end
    return sentence, nav_down
end

finish = function(st, result, log)
    if st.mode == "idle" then return end
    local gen, token, pawn, pc = st.gen, st.owner_token, st.pawn, st.pc
    local initial_arb = rawget(_G,"DWArbiter")
    local initial_owner = initial_arb and initial_arb.owner
    local function current()
        local arb=rawget(_G,"DWArbiter"); local owner=arb and arb.owner
        return rawget(_G,"DW_MOVE")==st and st.gen==gen and st.owner_token==token and st.pawn==pawn and st.pc==pc and
            arb==initial_arb and owner==initial_owner and (not owner or owner.token==token)
    end
    if not current() then return end
    cancel_superjump(st)
    if not current() then return end
    if result and result.status == "arrived" then st.trip_ok = true end
    if result and result.status == "arrived" and st.trip_rec and (st.trip_rec.path or 0) >= 200 then
        pcall(trap_evidence, st, "got where I was going", log)
    end
    local tl = st.trap_learn
    if tl and tl.undo and tl.undo.trap and result and result.status == "failed" and st.trip_rec and st.trip_rec.last
        and d2(st.trip_rec.last, st.trip_rec.start) < M.cfg.trap_undo_cm then
        -- a walk "out" of a stuck spot that failed and ended near where it began led nowhere: not an exit, and
        -- no count for or against the trap (Luis's rule: only a clean walk out is evidence)
        pcall(function()
            local mem, NMm = nav_mem()
            local u, tr = tl.undo, tl.undo.trap
            if u.prev and u.prev == tr then
                tr.exit, tr.n_ok, tr.n_used, tr.ts, tr.status = u.exit, u.n_ok, u.n_used, u.ts, u.status
            else
                for i = #mem.traps, u.n + 1, -1 do if mem.traps[i] == tr then table.remove(mem.traps, i) end end
                if u.prev and u.prev.seed then u.prev.disabled = nil end
            end
            NMm.save(mem)
            if rawget(_G, "DW_TRAP_CAND") == tl then _G.DW_TRAP_CAND = nil end
            if log then log(string.format("move: memory: trap %s: the walk out of it failed %.0f m from where it began: exit %s",
                tostring(tr.id), d2(st.trip_rec.last, st.trip_rec.start) / 100, u.prev == tr and "kept as it was" or "not learned")) end
        end)
    end
    pcall(mem_flush, st, log, result and result.status)
    if not current() then return end
    local handle=st.handle
    if handle then pcall(CancelDelayedAction, handle) end
    if not current() or st.handle ~= handle then return end
    local okt, sentence, nav_down = pcall(trip_report, st, result)
    if okt and sentence then
        result.trip = sentence
        -- an outage is an outage: never "stuck"/"unreachable" (-> path_blocked) when the helper was not there
        if nav_down and result.status == "failed" and (result.reason == "stuck" or result.reason == "unreachable" or result.reason == "timeout") then
            result.why, result.reason = result.reason, "nav_unavailable"
        end
        -- over his carry weight is the true cause of a stalled walk (no jumps, 0.6x speed), before any route outage
        if heavy(st) and result.status == "failed" and (result.reason == "stuck" or result.reason == "unreachable" or
            result.reason == "timeout" or result.reason == "nav_unavailable") then
            result.why, result.reason = result.why or result.reason, "encumbered"
        end
        -- MOVE_None for the whole failed attempt: still lying down after a rest whose bed/shelter is gone (live 21:34:
        -- teleported out of a shelter, every go_to "stuck" at 0 m). Not checked at start: right after a teleport the
        -- mode reads None for a moment (live 21:43, two false refusals).
        local okm, mmode = pcall(function() return st.pawn.CharacterMovement.MovementMode end)
        if okm and mmode == 0 and result.status == "failed" and (result.reason == "stuck" or result.reason == "timeout") then
            -- why = the words (client_bridge shows why first, after the trip sentence)
            result.why, result.reason = "my movement is disabled (I'm still lying down from a rest, and the bed or shelter I could get up from is gone)", "resting"
        end
        if log then log("move: trip: " .. sentence) end
    elseif not okt and log then log("move: trip report error " .. tostring(sentence)) end
    st.result = result
    st.mode = "idle"
    st.handle = nil
    if log then log("move: " .. tostring(result.status) .. " " .. tostring(result.reason or "")) end
    if current() then release_implicit(st, log) end
end

-- World teardown guard: disconnect/join set _G.DW_PAUSE = true (cleared by the bridge once a new
-- pawn has been stable for 3 s). A UFunction call during teardown crashed the client (18:08:42
-- access violation), so while paused, or with an invalid controller/pawn, the loop does NOTHING.
paused = function() return rawget(_G, "DW_PAUSE") == true end

-- Only a real player CHARACTER may be driven: in the main menu (L_FrontEnd) the controller owns a
-- DefaultPawn at (0,0,0) (live 23:10: a go_to "drove" it). A player character has CharacterMovement.
local function is_character(pawn)
    if not (pawn and pawn:IsValid()) then return false end
    local ok, mc = pcall(function() return pawn.CharacterMovement end)
    return ok and mc ~= nil and mc:IsValid()
end

-- Never infer life or ground state from a failed native read.
life_check = function(st, pawn)
    if st.pawn and pawn ~= st.pawn then return false, "interrupted", "controlled character changed" end
    local life = rawget(_G, "DW_LIFE")
    if st.life_seq ~= nil and type(life) == "table" and (life.move_death_seq or 0) ~= st.life_seq then
        return false, "companion_down", "death observed during movement"
    end
    local ok, dead = pcall(function() return pawn.HealthComponent:IsDead() end)
    if not ok or type(dead) ~= "boolean" then return false, "verification_failed", "health state unavailable" end
    if dead then return false, "companion_down", "character is dead" end
    local okh, hp = pcall(function() return pawn.HealthComponent:GetAuthoritativeHealth() end)
    if not okh or type(hp) ~= "number" or hp ~= hp then return false, "verification_failed", "health value unavailable" end
    if hp <= 0 then return false, "companion_down", "character has no health" end
    return true
end


local function ground_check(pawn)
    local ok, ground = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
    if not ok or type(ground) ~= "boolean" then return nil end
    return ground
end

-- Standing for an arrival: on the ground, or in water (wading/swimming at the spot is being there). Live 21:48: the
-- Water Anima Vent sits at the pond edge; he stood 1.2 m from it in the water, never "on ground", and the go_to
-- ended unreachable at 0-2 m.
-- his ground speed (cm/s): the movement component's velocity, else the speed of his own positions (trip_tick)
local function h_speed(st, pawn)
    local ok, x, y = pcall(function() local u = pawn.CharacterMovement.Velocity; return u.X, u.Y end)
    if ok and type(x) == "number" and type(y) == "number" then return math.sqrt(x * x + y * y) end
    return st.hspd
end

local function standing_check(pawn)
    local g = ground_check(pawn)
    if g ~= false then return g end
    local ok, swim = pcall(function() return pawn.CharacterMovement:IsSwimming() end)
    return ok and swim == true
end

-- Target Z may be an actor origin or floor point. One capsule's full height covers the
-- known pawn-centre/floor offset (DISCOVERIES); closer stacked floors can still overlap
-- this provisional allowance, which is exposed to callers for honest interpretation.
local function reached(st, me, goal)
    if not (me and goal and type(me.X) == "number" and type(me.Y) == "number" and type(me.Z) == "number"
        and type(goal.X) == "number" and type(goal.Y) == "number" and type(goal.Z) == "number") then return nil end
    return d2(me, goal) <= st.tol_cm and math.abs(me.Z - goal.Z) <= 2 * st.half_h
end

function M.verify_arrival()
    local st = S()
    if paused() then return { ok = false, reason = "verification_failed", detail = "world changing" } end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not is_character(pawn) then return { ok = false, reason = "verification_failed", detail = "player character unavailable" } end
    local alive, reason, detail = life_check(st, pawn)
    if not alive then return { ok = false, reason = reason, detail = detail } end
    local grounded = standing_check(pawn)
    if grounded ~= true then return { ok = false, reason = "verification_failed", detail = grounded == false and "character is airborne" or "ground state unavailable" } end
    if st.escape then return { ok = false, reason = "verification_failed", detail = "escape outcome needs zone verification" } end
    local okp, here = pcall(function() return pawn:K2_GetActorLocation() end)
    local okg, goal = pcall(function()
        if st.target_name then
            if not (st.target and st.target:IsValid()) then return nil end
            return st.target:K2_GetActorLocation()
        end
        return st.goal
    end)
    local near = okp and okg and reached(st, here, goal)
    -- right under a spot that hangs in the air over his floor (overhead()): that is the arrival
    local bo = st.below_ok
    local below = near == false and type(bo) == "table" and d2(here, goal) <= st.tol_cm and here.Z < goal.Z
        and math.abs(bo.X - goal.X) < 1 and math.abs(bo.Y - goal.Y) < 1 and math.abs(bo.Z - goal.Z) < 1
    if below then near = true end
    if near ~= true then return { ok = false, reason = "verification_failed", detail = near == false and "position differs from requested destination" or "position or destination unavailable" } end
    return { ok = true, below = below or nil, position = { here.X / 100, here.Y / 100, here.Z / 100 },
        target_position = { goal.X / 100, goal.Y / 100, goal.Z / 100 }, tolerance_m = st.tol_cm / 100,
        vertical_distance_m = math.abs(here.Z - goal.Z) / 100, vertical_tolerance_m = 2 * st.half_h / 100 }
end

-- ------------------------------------------------------------------ approach progress (one watchdog for all)
-- Every go_to/follow tracks whether it is getting closer, so callers (combat chase, skills interact, shoot)
-- read one verdict from status().progress instead of each keeping its own "can't get closer" timer.
-- opts.progress = { stall_s, gain_m, budget_s, moving_m, to = {x,y,z} m (measure to this point, e.g. the
-- thing to use, when the goal is a standing spot) }. Pure bookkeeping: move never stops on its own verdict.
local function progress_new(o)
    o = type(o) == "table" and o or {}
    local to = type(o.to) == "table" and tonumber(o.to[1]) and { X = o.to[1] * 100, Y = o.to[2] * 100, Z = (o.to[3] or 0) * 100 } or nil
    return { stall_s = tonumber(o.stall_s) or M.cfg.progress_stall_s, gain = (tonumber(o.gain_m) or M.cfg.progress_gain_m) * 100,
             budget_s = tonumber(o.budget_s), moving_cm = (tonumber(o.moving_m) or M.cfg.progress_moving_m) * 100,
             to = to, elapsed = 0 }
end

local function progress_tick(st, t, me, goal, dist, near)
    local P = st.prog_tr
    if not P then return end
    local d = P.to and d2(me, P.to) or dist
    P.dist, P.tpos = d, v(goal)
    -- a gap between frames (paused by the world-teardown guard, or the loop was starved) restarts the window
    local gap = P.last_t and (t - P.last_t) or nil
    if not gap or gap > 2 then P.best_t = t; P.best_tpos = v(goal) end
    if near then
        P.best, P.best_t, P.best_tpos = d, t, v(goal)
    else
        P.elapsed = P.elapsed + ((gap and gap >= 0 and gap <= 2) and gap or 0)
        if not P.best or d < P.best - P.gain then P.best, P.best_t, P.best_tpos = d, t, v(goal) end
    end
    P.last_t = t
end

-- The verdict, from the tracker plus move's own states (no engine calls: safe from status()).
local function progress_view(st)
    local P = st.prog_tr
    if not P then return nil end
    local since = (P.last_t and P.best_t) and (P.last_t - P.best_t) or 0
    local moved = (P.best_tpos and P.tpos) and d2(P.best_tpos, P.tpos) or 0
    local verdict, why = "ok", nil
    local over = P.budget_s and P.elapsed > P.budget_s
    local stalled = over or since > P.stall_s
    -- why the approach is not getting closer (also used when a caller's timeout ends the move first:
    -- live 2026-10-26 16:05, sticks on a ledge 4 m up came back as a bare "timeout")
    local function stall_why()
        local walls = st.lp_fail == "verify_exhausted" or st.lp_fail == "unreachable_in_window" or (st.stuck_n or 0) > 0 or st.bug ~= nil
        local reach = ((st.env and st.env.jump) or 165) + 60
        if st.status == "target_not_visible" then return "target_not_visible" end
        if heavy(st) then return "encumbered" end
        if moved > P.moving_cm then return "cant_catch" end
        -- the goal was out of jump reach from the start, and he got no closer: that height is the reason
        -- (which move would reach it and what he lacks: double jump / Windstep, height_verdict)
        if st.dz0 and st.dz0 > reach then
            local hr = height_reason(st, st.dz0, st.target_kind == "player" and "leader" or "target", t)
            if hr then return hr end
        end
        if over then return "too_long" end
        return walls and "blocked" or "no_progress"
    end
    local r = st.result
    if r and r.status == "arrived" then verdict = "ok"
    elseif r and r.status == "failed" then
        verdict = "unreachable"
        why = r.why or r.reason
        if why == "timeout" and since > math.min(P.stall_s, 5) then why = stall_why() end
    elseif st.unreach then verdict, why = "unreachable", st.unreach.reason
    elseif st.far then verdict, why = "unreachable", "leader_far"
    elseif st.lead and not st.lead.phase then verdict, why = "unreachable", st.lead.why
    elseif st.status == "near" or st.status == "near_zone" then verdict = "ok"
    elseif stalled then
        verdict, why = "stalled", stall_why()
    end
    local function r1(x) return x and math.floor(x / 10 + 0.5) / 10 or nil end
    return { verdict = verdict, why = why, dist_m = r1(P.dist), best_dist_m = r1(P.best), since_s = math.floor(since * 10) / 10,
             elapsed_s = math.floor(P.elapsed * 10) / 10, target_moved_m = r1(moved), stall_s = P.stall_s, budget_s = P.budget_s }
end

-- ------------------------------------------------------------------ the tick, in phases
-- One frame of a move. tick() runs the phases below in order on a frame table f (st, gen, log, pc, pawn, t, dt,
-- me; then, as they become known, goal, dist, same_level, the zone fields, fe, path, aim/src/idxp, dx/dy,
-- sprinting). A phase returns true when the frame ends there (the move finished, holds still this frame, or
-- lost its binding). One progress clock (no gain toward the goal for give_up_s), re-plans while it runs and
-- ONE terminal result, as with UE's PathFollowingComponent block detection (-> Blocked, the owner decides)
-- and mineflayer-pathfinder's 3.5 s reset-and-replan.
local function stop(st, result, log) finish(st, result, log); return true end
local function step_tol(st) return math.max((st.env and st.env.step or 45) + 20, 60) end -- a reached point's height slack
local function jump_cm(st) return (st.env and st.env.jump) or 165 end
local function face(pc, from, to, st, t)
    local rot = { Pitch = 0, Yaw = math.deg(math.atan(to.Y - from.Y, to.X - from.X)), Roll = 0 }
    if st and t then return cam_write(st, pc, rot, t) end
    pc:SetControlRotation(rot)
end
local function note(st, text) st.trip_notes = st.trip_notes or {}; st.trip_notes[#st.trip_notes + 1] = text end
-- (a new escape or route also gets a fresh detour budget: st.best_t)
local function restart_progress(st, t, me) st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.best_t, st.detour_spent = t, v(me), 0, nil, t, nil end
-- a stuck spot: whatever gets him away from here is learned as its trap exit (trap_tick)
local function mark_trap(st, me) _G.DW_TRAP_CAND = { at = feet_of(st, me), toward = st.aim and feet_of(st, st.aim) or nil, t = os.time() } end

-- jump sequencing: release after 0.25 s; the double jump's second press dj_delay_s (measured, else 0.33 s) after the first
local function jump_tick(f)
    local st, gen, pc, pawn, t, log = f.st, f.gen, f.pc, f.pawn, f.t, f.log
    -- an admitted local traversal cannot release or submit a second jump under a stale route
    if st.jump_t and st.local_authority and (not st.local_binding or not local_route_owned(st, gen, pawn, pc, st.local_binding.goal)) then return true end
    if not st.jump_t then return end
    local jb = binding(st, pawn)
    if st.jump_release and t - st.jump_t > 0.25 then
        if not owned(jb) then reject_binding(jb, log); return true end
        local ok = pcall(function() pawn:StopJumping() end)
        if not owned(jb) then reject_binding(jb, log); return true end
        if not ok then return stop(st, { status = "failed", reason = "verification_failed", detail = "jump release unconfirmed" }, log) end
        st.jump_release = false
    end
    if st.jump_double and t - st.jump_t > ((st.env and st.env.dj_delay_s) or 0.33) then
        if not owned(jb) then reject_binding(jb, log); return true end
        local grounded = ground_check(pawn)
        if not owned(jb) then reject_binding(jb, log); return true end
        st.jump_observation = { intent = "second", submitted = false, airborne = grounded == nil and "unknown" or not grounded, generation = st.gen }
        if grounded == false then
            local ok = pcall(function() pawn:Jump() end)
            if not owned(jb) then reject_binding(jb, log); return true end
            if not ok then return stop(st, { status = "failed", reason = "verification_failed", detail = "second jump input failed" }, log) end
            st.jump_double = false; st.jump_t2 = t; st.double_jumps = (st.double_jumps or 0) + 1
            st.jump_observation.submitted = true
        elseif t - st.jump_t > 1.2 then
            -- the first jump never left the ground: no second press, carry on (the stuck/re-plan ladder decides;
            -- live 2026-10-31 20:32 this ended the ramp_down journey)
            st.jump_double = false
            note(st, "my jump never left the ground")
            if log then log("move: double jump: first jump not airborne after 1.2 s; skipping the second") end
        end
    end
    if st.jump_t2 and t - st.jump_t2 > 0.25 then
        if not owned(jb) then reject_binding(jb, log); return true end
        local ok = pcall(function() pawn:StopJumping() end)
        if not owned(jb) then reject_binding(jb, log); return true end
        if not ok then return stop(st, { status = "failed", reason = "verification_failed", detail = "second jump release unconfirmed" }, log) end
        st.jump_t2 = nil
    end
    if t - st.jump_t > 1.2 and not st.jump_double and not st.jump_t2 and not st.jump_release then st.jump_t = nil end
end

-- ------------------------------------------------------------------ the goal (a point, or a target that moves)
local function lost_target(f)
    local st = f.st
    st.status = "target_not_visible"
    st.lost_t = st.lost_t or f.t
    -- a go_to gives up 10 s into the move once the target has been gone 2 s in a row (a pawn handing over to its map
    -- marker, or back, may miss a frame); the reason says who IS on the map
    -- (a target never seen in this move fails after those 2 s: nothing to hand over; live rung1, 10 s to fail
    -- before the brain's map fallback)
    if st.mode == "go_to" and (f.t - st.t0 > 10 or not st.target_ever) and f.t - st.lost_t >= 2 then
        local names = st.target_kind ~= "actor" and map_names(f.pawn) or nil
        local detail = names and string.format("%s is not in sight, and no player of that name is on the game map (on the map: %s)",
            tostring(st.target_spec or st.target_name), #names > 0 and table.concat(names, ", ") or "nobody else") or nil
        return stop(st, { status = "failed", reason = "target_not_visible", detail = detail }, f.log)
    end
    st.prog_t = nil
    return true
end

-- Leader moves Claude may lack: an airborne rise above superjump_any_cm is Windstep (his airborne crumbs are no
-- path for us: the trail is cut at his take-off); his jump count reaching 2 while airborne is a double jump.
local function watch_leader(st, goal, t, log)
    record_crumb(st, goal)
    local okg, ground = pcall(function() return st.target.CharacterMovement:IsMovingOnGround() end)
    if okg and ground == false then
        if not st.l_air then st.l_air = { z0 = goal.Z, zmax = goal.Z, n0 = #st.crumbs } else st.l_air.zmax = math.max(st.l_air.zmax, goal.Z) end
    elseif okg and st.l_air then
        local rise = st.l_air.zmax - st.l_air.z0
        if rise > M.cfg.superjump_any_cm then
            st.leader_superjump_t = t
            for k = #st.crumbs, st.l_air.n0 + 1, -1 do table.remove(st.crumbs, k) end
            if st.trail_i and st.trail_i > #st.crumbs then st.trail_i = #st.crumbs end
            st.next_gap = true
            if log then log("move: leader super-jump (Windstep) rise=" .. math.floor(rise) .. "cm; trail cut at take-off") end
        end
        st.l_air = nil
    end
    -- jump count CHANGES only: the replicated value stays stale after landing (traversal agent)
    local okj, jc = pcall(function() return st.target.ReplicatedJumpCurrentCount end)
    jc = okj and tonumber(jc) or nil
    if jc and st.l_jc and jc >= 2 and st.l_jc < 2 and st.l_air then st.leader_dj_t = t end
    st.l_jc = jc
end

-- f.goal: the point, or the target's position (re-resolved at most once a second while it is gone)
local function track_goal(f)
    local st, t, log = f.st, f.t, f.log
    if not st.target_name then f.goal = st.goal; return end
    if not (st.target and st.target:IsValid()) and t - (st.target_t or 0) > 1.0 then
        local tgt, kind = resolve_target(st.target_spec or st.target_name, f.pawn)
        st.target, st.target_t = tgt, t
        if kind and not st.target_kind then st.target_kind = kind end
        st.target_mc = nil
    end
    if not (st.target and st.target:IsValid()) then return lost_target(f) end
    local goal = st.target:K2_GetActorLocation()
    -- a relevancy-culled / teleporting proxy reads as the world origin (live 20:25: Claude sprinted
    -- toward (0,0,0), 1.8 km away): treat as not visible; a player: his marker on the game map instead
    if math.abs(goal.X) < 100 and math.abs(goal.Y) < 100 then
        local m = st.target_kind == "player" and not (type(st.target) == "table" and st.target.dw_map)
            and map_target(st.target_spec or st.target_name, f.pawn)
        if not m then return lost_target(f) end
        st.target, st.target_t, st.target_mc = m, t, nil
        goal = m:K2_GetActorLocation()
    end
    local via = (type(st.target) == "table" and st.target.dw_map) and "map" or "sight"
    if via ~= st.target_via then
        if log and st.target_via then log("move: " .. tostring(st.target_spec or st.target_name) .. " now tracked by "
            .. (via == "map" and "his marker on the game map (out of sight)" or "sight (his pawn replicated)")) end
        st.target_via = via
    end
    st.lost_t, st.target_ever = nil, true
    if st.last_goal and d2(goal, st.last_goal) > M.cfg.target_jump_cm then -- teleport: drop the old route and trail
        if log then log(string.format("move: target jumped %.0f m (teleport?); resetting route and trail", d2(goal, st.last_goal) / 100)) end
        st.path, st.lpath, st.mpath, st.trail_i, st.bug = nil, nil, nil, nil, nil
        st.crumbs, st.crumb_mark = {}, 0
    end
    st.last_goal = v(goal)
    -- the leader's ground speed over >= 0.3 s windows (follow sprint matching)
    if not st.lv_t or t < st.lv_t then st.lv_t, st.lv_pos = t, v(goal)
    elseif t - st.lv_t >= 0.3 then
        st.leader_cms = d2(goal, st.lv_pos) / (t - st.lv_t)
        st.lv_t, st.lv_pos = t, v(goal)
    end
    -- a map marker is no trail (coarse samples, no ground/jump state): crumbs only from a pawn in sight
    if st.target_kind ~= "actor" and via ~= "map" then watch_leader(st, goal, t, log) end
    st.target_pos = goal
    f.goal = goal
end

-- trip record (PLAN fix 2): what this move really did, for one honest sentence and client_io/events/trips.jsonl
local function trip_tick(f)
    local st, pawn, t, dt, me, goal, dist = f.st, f.pawn, f.t, f.dt, f.me, f.goal, f.dist
    local tr = st.trip_rec
    if not tr then
        tr = { t0 = t, start = v(me), d0 = dist, path = 0, best = dist, last = v(me), zmin = me.Z, zmax = me.Z,
               src_t = {}, sprint_t = 0, fall = 0 }
        st.trip_rec = tr
    else
        -- walked = ground covered (2D): hops on the spot are no walking (live 19:20Z, rooted by a vent's hold
        -- interaction, every go_to "walked 17-20 m" of his own up-and-down hops and ended where it began)
        local step = math.sqrt((me.X - tr.last.X) ^ 2 + (me.Y - tr.last.Y) ^ 2)
        if step < 1500 then tr.path = tr.path + step end -- a teleport/respawn is not walking
        if dt and dt > 0 and step < 1500 then -- ground speed from his own positions (h_speed's fallback)
            local inst = step / dt
            st.hspd = st.hspd and (0.5 * st.hspd + 0.5 * inst) or inst
        end
        if dist < tr.best then tr.best = dist end
        tr.zmin, tr.zmax = math.min(tr.zmin, me.Z), math.max(tr.zmax, me.Z)
        local src0 = st.source or "start"
        tr.src_t[src0] = (tr.src_t[src0] or 0) + dt
        if st.sprinting then tr.sprint_t = tr.sprint_t + dt end
    end
    tr.last, tr.goal, tr.t1, tr.dist = v(me), v(goal), t, dist
    -- a progress line on a long walk (every trip_progress_s): how far is left, the pace, and an honest "slowed" cause
    if st.mode == "go_to" and tr.d0 > M.cfg.trip_progress_min_cm then
        tr.prog_t = tr.prog_t or t
        if t - tr.prog_t >= M.cfg.trip_progress_s then
            local span = t - tr.prog_t
            local pace = (tr.prog_d and span > 0) and (tr.prog_d - dist) / span / 100 or nil
            tr.prog_t, tr.prog_d = t, dist
            local left = math.floor(dist / 100 + 0.5)
            local text = string.format("Walking: %d m to go of %d", left, math.floor(tr.d0 / 100 + 0.5))
            if pace and pace > 0.5 then text = text .. string.format(", about %d s more at %.1f m/s", math.floor(left / pace + 0.5), pace)
            elseif pace then text = text .. ", but I'm barely getting closer" end
            if heavy(st) then text = text .. " (I'm carrying too much, so I can only walk)" end
            pcall(emit_move_event, "trip_progress", { text = text, left_m = left, total_m = math.floor(tr.d0 / 100 + 0.5),
                pace_ms = pace and math.floor(pace * 10 + 0.5) / 10 or nil, my_pos = me })
        end
    end
    local okf, falling = pcall(function() return pawn.CharacterMovement:IsFalling() end)
    -- the last spot he stood on (the game leaves his grave there after a deadly fall, not where the body ends:
    -- live 2026-11-01 15:56 the death read (38.6, 1740.3, -94.0), the grave stood at (45.0, 1744.9, -30.6))
    if okf and not falling then _G.DW_LAST_GROUND = { X = me.X, Y = me.Y, Z = me.Z, t = os.time() } end
    -- a fall is the drop from where he left the ground to where he lands: his own jump's height is no fall (a hop
    -- on the spot read "fell 3.3 m", live 19:20Z)
    if okf and falling then
        tr.air_top = math.max(tr.air_top or me.Z, me.Z)
        tr.air_from = tr.air_from or tr.ground_z or me.Z
    elseif okf then
        if tr.air_top then
            local drop = (tr.air_from or tr.air_top) - me.Z
            if drop > tr.fall then tr.fall = drop end
            tr.air_top, tr.air_from = nil, nil
        end
        tr.ground_z = me.Z
    end
end

-- ------------------------------------------------------------------ the nav oracle route
-- The oracle's answer as cm points, or nil when it is not a well-formed route (finite numeric triples).
local function route_points(r)
    if not (r.ok == true and type(r.points) == "table" and #r.points >= 2) then return nil end
    if (r.partial ~= nil and type(r.partial) ~= "boolean") or (r.goal_projected ~= nil and type(r.goal_projected) ~= "boolean") then return nil end
    local pts = {}
    for _, p in ipairs(r.points) do
        if type(p) ~= "table" or #p ~= 3 then return nil end
        for k in pairs(p) do
            if type(k) ~= "number" or k < 1 or k > 3 or k % 1 ~= 0 then return nil end
        end
        for i = 1, 3 do
            if type(p[i]) ~= "number" or p[i] ~= p[i] or math.abs(p[i]) == math.huge or math.abs(p[i] * 100) == math.huge then return nil end
        end
        pts[#pts + 1] = { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 }
    end
    return pts
end

-- a trip short enough for one local plan (the planner's grid reaches the goal)
local function short_goal(st)
    return st.use_lp and st.original_goal_xy and st.original_goal_xy <= M.cfg.oracle_primary_cm and st.original_goal_xy <= M.cfg.lp_grid_m * 100
end

-- The oracle answered the pending request: admit its route as st.path, or record why not (st.nav_fail).
local function nav_response(f, pending)
    local st, gen, t, me, goal, log = f.st, f.gen, f.t, f.me, f.goal, f.log
    local r = nav_poll(st)
    if not r then return end
    st.nav_pending = nil
    local pts = route_points(r)
    -- a short trip, or a follow that found no route, takes only a complete route that ends at the goal
    if pts and ((st.nav_required and short_goal(st)) or (st.unreach and st.unreach.reason == "no_route")) and
        (r.partial ~= false or not reached(st, pts[#pts], goal)) then pts = nil end
    if not pts then st.path, st.nav_fail = nil, r.reason or "invalid_route"; return end
    -- a segment rising more than a step over a short run is a nav LINK (the dev navmesh's jump links): jump it
    for i = 2, #pts do
        if pts[i].Z - pts[i - 1].Z > 60 and d2(pts[i - 1], pts[i]) < 300 then pts[i].link = true end
    end
    -- a partial route asked from where he WAS can end behind him once he has walked on (the temple is a navmesh island
    -- on the dev oracle: every route from inside it ends at its edge). Joining it walked him back inside, where he gave
    -- up with "the walkable map ends 414 m short" (live 2026-11-01 17:20, a 434 m quest walk out of the temple: he had
    -- reached the doorway while the route was computed). Ask again from here instead (a few times a trip, 10+ m on).
    local endp = pts[#pts]
    if r.partial and st.mode == "go_to" and st.nav_from and d2(st.nav_from, me) > 1000 and d2(me, goal) + 300 < d2(endp, goal)
        and (st.nav_reasks or 0) < 3 then
        st.nav_reasks, st.path, st.nav_fail = (st.nav_reasks or 0) + 1, nil, nil
        if log then log(string.format("move: the route asked from (%.0f,%.0f) ends %.0f m behind me, short of the goal; asking again from here",
            st.nav_from.X / 100, st.nav_from.Y / 100, (d2(endp, goal) - d2(me, goal)) / 100)) end
        return
    end
    if st.lp_observe then
        st.lp, st.lp_state, st.lp_observe, st.local_binding = nil, nil, nil, nil
        st.local_observe_done = true
    end
    st.path, st.wp, st.path_partial = pts, 2, r.partial
    if st.prov then
        -- he walked on while it was computed: continue from the route point with the shortest way on (straight to
        -- it, then the route), among points within 5 m of the nearest at his level
        local hh, best, bi = st.half_h or 90, math.huge, nil
        for i = 2, #pts do
            if math.abs((me.Z - hh) - pts[i].Z) < 250 then
                local d = d2(me, pts[i]); if d < best then best, bi = d, i end
            end
        end
        if bi then
            local rem, score, pick = 0, math.huge, bi
            for i = #pts, 2, -1 do
                if i < #pts then rem = rem + d2(pts[i], pts[i + 1]) end
                if math.abs((me.Z - hh) - pts[i].Z) < 250 then
                    local d = d2(me, pts[i])
                    if d <= best + 500 and d + rem < score then score, pick = d + rem, i end
                end
            end
            st.wp = pick
        end
        if log then log(string.format("move: route came after %.1f s of walking; joining it at point %d/%d", t - (st.prov_t or t), st.wp, #pts)) end
        st.prov = nil
    end
    local lastp = pts[#pts]
    if r.partial then st.nav_end = v(lastp) end
    if st.mode == "go_to" and not reached(st, lastp, goal) then
        -- the route ends short (the NPC navmesh misses the church ramp a player walks): a remembered route that
        -- reaches the goal is this trip's authority, and the oracle is not asked again (re-asking every ~4 s
        -- re-admitted it and reset the route to its first point: live 20:46-20:48, ramp_up)
        local mp = mem_goal_plan(st, me, goal)
        if mp then
            st.path = nil
            route_fallback(st, "oracle route ends short; a remembered route reaches the goal", log)
            st.mem_checked = true
            st.mpath, st.mwp, st.msrc = mp, 1, "memory"
            st.use_nav = false
            if log then log(string.format("move: memory: remembered route reaches the goal (%d pts); the oracle's ends %.0f m short",
                #mp, d2(lastp, goal) / 100)) end
        end
    end
    st.nav_jumped, st.nav_binding, st.nav_fail = {}, pending, nil
    if st.unreach and st.unreach.reason == "no_route" then
        pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me, after_s = t - st.unreach.since })
        if rawget(_G, "DW_MOVE") ~= st or st.gen ~= gen or st.owner_token ~= pending.token then return true end
        st.unreach = nil
    end
end

-- A short trip that needs a route: sample a local plan while standing (input held). It becomes the route
-- (st.local_authority) only when it really ends at the goal; else the oracle's answer, or the fallback, decides.
local function route_observe(f, world)
    local st, gen, pc, pawn, t, me, goal, log = f.st, f.gen, f.pc, f.pawn, f.t, f.me, f.goal, f.log
    local b = st.local_binding
    if not b then
        local arb = rawget(_G, "DWArbiter")
        if arb and arb.owner and arb.owner.token == st.owner_token and world and owned(binding(st, pawn)) then
            b = { gen = gen, token = st.owner_token, pawn = pawn, pc = pc, arb = arb, owner = arb.owner, world = world, goal = v(goal),
                  life = st.life_seq, half_h = st.half_h, target = st.target }
            st.local_binding = b
            local ok_begin, begun = pcall(lp_begin, st, pawn, me, goal, "route_observation", log, true)
            if not local_route_owned(st, gen, pawn, pc, goal) then return true end
            if not ok_begin or not begun then st.local_observe_done = true
            else st.local_sample_start = v(me) end
        end
    end
    if not (b and not st.local_observe_done) then return end
    if not local_route_owned(st, gen, pawn, pc, goal) then st.local_observe_done = true; st.lp = nil; st.lp_state = nil; return true end
    local worked = pcall(lp_work, st, t, log)
    if not local_route_owned(st, gen, pawn, pc, goal) then return true end
    if not worked then st.lp = nil; st.lp_state = nil; st.local_observe_done = true end
    if st.lp_state == "observed" then
        -- input is no longer submitted while observing, but inertia can still move the pawn: recheck the start
        -- of the verified first segment
        local okpos, sample_now = pcall(function() return pawn:K2_GetActorLocation() end)
        if not local_route_owned(st, gen, pawn, pc, goal) then return true end
        if not okpos or not finite3(sample_now) then
            st.lp, st.lp_state, st.nav_fail, st.local_observe_done = nil, nil, "local_position_unknown", true
            return true
        end
        local origin = st.local_sample_start
        if not origin or d2(sample_now, origin) > M.cfg.lp_radius_cm or math.abs(sample_now.Z - origin.Z) > step_tol(st) then
            st.local_replans = (st.local_replans or 0) + 1
            st.lp, st.lp_state, st.lp_observe, st.local_binding = nil, nil, nil, nil
            st.local_observe_done = st.local_replans > M.cfg.lp_max_plans
            if st.local_observe_done then st.nav_fail = "local_replan_limit" end
            st.status = "planning"
            return true
        end
        local pts = st.lp_pts; local last = pts and pts[#pts]
        st.local_observe_done = true
        -- an equivalent failed destination cannot be made safe by repackaging it (ignore table identity and index)
        local repeats = false
        for _, p in ipairs(pts or {}) do
            for _, failed in ipairs(st.local_failed_points or {}) do
                if p.X == failed.X and p.Y == failed.Y and
                    math.abs(p.Z - failed.Z) <= math.max((st.env and st.env.step or 45), 1) then repeats = true; break end
            end
            if repeats then break end
        end
        if repeats then
            st.lp, st.lp_state, st.nav_fail = nil, nil, "local_replan_repeats_stalled_waypoint"
        elseif last and #pts >= 2 and d2(last, goal) <= st.tol_cm and
            math.abs((last.Z + st.half_h) - goal.Z) <= 2 * st.half_h then
            local copied = {}
            for i, p in ipairs(pts) do copied[i] = { X = p.X, Y = p.Y, Z = p.Z, act = p.act } end
            b.path = copied
            st.lpath, st.lwp, st.lp_jumped, st.local_authority = copied, 2, {}, true
            st.lp, st.lp_state = nil, nil
        end
    elseif not st.lp_state then st.local_observe_done = true end
    if not st.local_authority then return true end
end

-- A follow of a leader in sight walks his own trail (breadcrumbs at our level, no Windstep gap ahead): it needs no
-- route, so it never stands waiting for the oracle while he moves. (Movement ladder 2026-11-01, follow_church_loop:
-- every time he passed 10 m the old rule required an oracle route, and each 3 m he moved dropped it and re-asked:
-- Claude stood "planning" while the gap grew 9 -> 21 m.) The breadcrumb-follow companion pattern; mineflayer's
-- GoalFollow re-paths to a moving entity instead, which is what stood still here.
local function trail_led(st, me)
    if st.mode ~= "follow" or st.target_via ~= "sight" or #st.crumbs < 2 then return false end
    local from = st.trail_i or nearest_crumb(st.crumbs, me)
    if not from then return false end
    -- his trail from here on must be one he walked: no Windstep gap, no jump of > 5 m between two samples (a
    -- relevancy pop-in or a hitch: no path in between), else the route decides as before
    for k = from, #st.crumbs do
        local c = st.crumbs[k]
        if c.gap or (k > from and d2(st.crumbs[k - 1], c) > 500) then return false end
    end
    return true
end

-- Long trips (beyond oracle_primary_cm, or above jump height) ask the nav oracle first and steer by its admitted
-- route. No route (oracle absent, no_path, a route that ends short) falls back to local planning (route_fallback).
local function route_tick(f)
    local st, gen, pc, pawn, t, me, goal, dist, log = f.st, f.gen, f.pc, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    if trail_led(st, me) and not st.ws_exec and not st.link_exec and not st.local_authority then
        if st.nav_required or st.nav_pending or st.nav_deferred_required or st.path then
            -- (a route asked before he moved ends where he WAS: steering by it later walked Claude back to the
            -- leader's start, live 15:54:57, 54 m the wrong way)
            st.nav_required, st.nav_deferred_required, st.nav_pending, st.nav_wait_t, st.nav_goal = nil, nil, nil, nil, nil
            st.path, st.wp, st.nav_binding = nil, nil, nil
            if log then log("move: following his trail (he is in sight); no route needed") end
        end
        st.trail_led = true
        return
    end
    st.trail_led = nil
    local route_far = dist > M.cfg.oracle_primary_cm or (goal.Z - me.Z) > (jump_cm(st) + 20)
    if st.use_nav ~= false and not st.nav_required and not st.nav_fallback and (route_far or st.nav_deferred_required) then
        if st.ws_exec or st.link_exec or st.jump_t then
            st.nav_deferred_required = true -- let the already-owned traversal finish its landing/release first
        else
            st.nav_required, st.nav_deferred_required = true, nil
            -- existing short/direct plans are not authority for the newly required route
            st.lpath, st.lp_state, st.trail_i, st.mpath, st.lp_jump_exec = nil, nil, nil, nil, nil
        end
    end
    -- finish an already accepted ordinary jump, but no further steering while the route waits for its release
    if st.nav_deferred_required and st.jump_t and not st.ws_exec and not st.link_exec then
        st.status = "planning"
        return true
    end
    if st.use_nav == false or reached(st, me, goal) then return end
    local arb = move_arbiter()
    local owns = arb and arb.owns_move and st.owner_token and arb.owns_move(st.owner_token)
    if not owns or rawget(_G, "DW_MOVE") ~= st or st.gen ~= gen or pawn ~= st.pawn or paused() then return true end
    -- (a player tracked by his map marker, hundreds of metres off, moves a few metres between oracle answers: a fixed
    -- 3 m drop-and-re-ask kept the route pending forever and Claude stood "planning", live 2026-11-01 12:45 at 435 m)
    local repath_cm = M.cfg.repath_goal_move_cm
    if st.target_via == "map" then repath_cm = math.max(repath_cm, dist * M.MAP_REPATH_FRAC) end
    if not st.local_authority and not st.lp_observe and st.nav_goal and (d2(goal, st.nav_goal) > repath_cm or
        math.abs(goal.Z - st.nav_goal.Z) > repath_cm) then
        st.path, st.nav_pending, st.nav_goal, st.nav_fail, st.nav_wait_t = nil, nil, nil, nil, nil -- the goal moved: re-path
    end
    local world = world_identity()
    local pending = st.nav_pending
    if pending and not st.local_authority then
        local helper = oracle_offer()
        if helper and helper.epoch ~= pending.epoch then
            st.nav_pending, st.path, st.nav_fail = nil, nil, "oracle_restarted"
        elseif pending.gen ~= gen or pending.token ~= st.owner_token or pending.pawn ~= pawn or not world or pending.world ~= world then
            st.nav_pending, st.path, st.nav_fail = nil, nil, "route_identity_changed"
        elseif nav_response(f, pending) then return true end
    end
    if st.path then
        local b = st.nav_binding
        if not b or b.gen ~= gen or b.token ~= st.owner_token or b.pawn ~= pawn or not world or b.world ~= world then return true end
        if not st.lpath and not st.trail_i and not st.mpath and not st.link_exec then
            st.wp = advance(st.path, st.wp, me, M.cfg.wp_radius_cm, step_tol(st), st.half_h or 90)
        end
        if st.wp > #st.path then
            local last = st.path[#st.path]
            if last and reached(st, last, goal) then
                st.wp = #st.path -- steer to the admitted endpoint, never substitute the raw goal
            else
                st.nav_end = last and v(last) or st.nav_end
                st.path, st.nav_fail = nil, "route_ended_before_goal"
            end
        end
    end
    if st.mode == "follow" and not st.nav_pending and st.nav_fail and st.unreach and st.unreach.reason == "no_route" and
        t - st.unreach.check_t > M.cfg.unreachable_check_s then
        st.unreach.check_t, st.nav_fail, st.nav_wait_t = t, nil, t -- an unreachable follow asks again now and then
    end
    if not st.local_authority and not st.path and not st.nav_pending and not st.nav_fail then
        local offer, offer_reason = oracle_offer()
        st.nav_live = offer ~= nil
        st.nav_wait_reason = offer_reason or "oracle_unavailable"
        if world and nav_request(st, me, goal, offer, world) then st.nav_requests = (st.nav_requests or 0) + 1 end
    end
    if st.local_authority and not local_route_owned(st, gen, pawn, pc, goal) then
        st.local_authority, st.local_binding, st.lpath, st.lp_observe = nil, nil, nil, nil
        return true
    end
    if not st.path and st.nav_required and not st.local_authority and short_goal(st) and not st.local_observe_done
        and route_observe(f, world) then return true end
    if not st.path and st.nav_required and not st.local_authority then
        st.nav_wait_t = st.nav_wait_t or t
        local prov_ok = M.cfg.prov_walk and st.nav_pending and not st.prov_stalled and not st.unreach and dist > M.cfg.prov_min_cm
            and not (st.mode == "go_to" and t - st.t0 > st.timeout_s)
        -- a player starts walking at once: no route can come while the helper recovers or is unresolved (live
        -- 01:01-02:18Z "recovering: server_identity_changed": 59-66 s standing, explore legs "Moved 0 m in 40 s"),
        -- and a short trip's route comes in < 1 s, so standing longer than nav_stand_s is waiting on nothing;
        -- a long trip walks provisionally meanwhile (prov_ok) and keeps waiting for its route
        local dead = not st.nav_pending and (not st.nav_live or st.nav_wait_reason == "oracle_recovering"
            or st.nav_wait_reason == "oracle_unresolved")
        local stand_s = math.min(M.cfg.nav_timeout_s, M.cfg.nav_stand_s, math.max(1, (st.timeout_s or 40) * 0.25))
        if st.nav_fail or dead or t - st.nav_wait_t > M.cfg.nav_timeout_s or (not prov_ok and t - st.nav_wait_t > stand_s) then
            route_fallback(st, st.nav_fail or (st.nav_pending and "oracle_timeout") or st.nav_wait_reason or "oracle_unavailable", log)
        elseif prov_ok then
            -- waiting for a long route (the dev server streams the corridor in: 9.8-11.9 s standing at the start of
            -- every 150+ m trip, live 2026-11-01): walk toward the goal meanwhile, drop-guarded like the fallback
            -- (killz); when the route comes it is re-anchored where he is now (nav_response). Stalled -> stand as before.
            if not st.prov then
                st.prov, st.prov_t = true, t
                if log then log(string.format("move: route pending (%.0f m trip); walking toward the goal meanwhile", dist / 100)) end
            end
            return
        else
            -- waiting for the route: stand, with the progress clocks paused
            st.prov = nil
            st.status = st.unreach and "unreachable" or "planning"
            st.prog_t, st.prog_pos, st.win_t, st.win_pos = t, v(me), t, v(me)
            if st.prog_tr then st.prog_tr.last_t = nil end
            if st.mode == "go_to" and t - st.t0 > st.timeout_s then
                return stop(st, { status = "failed", reason = "timeout", detail = "route not yet verified" }, log)
            end
            return true
        end
    end
    st.nav_wait_t = nil
end

-- ------------------------------------------------------------------ arrival, holds, zones
-- AVOID ZONES (combat hazards): the zone he stands in (capsule overlap), and the goal's
local function zone_tick(f)
    local st, me, goal = f.st, f.me, f.goal
    local zs, AZm = live_zones(f.t)
    f.zs, f.AZm, f.mfeet = zs, AZm, me.Z - (st.half_h or 90)
    if AZm and #zs > 0 then
        f.zone_in = AZm.at(zs, me.X, me.Y, f.mfeet, M.cfg.avoid_margin_cm)
        f.zone_goal = AZm.at(zs, goal.X, goal.Y, goal.Z - (st.half_h or 90), 0)
    end
    st.zone_in = f.zone_in and f.zone_in.id or nil
    if not f.zone_in then st.zone_exit = nil end
    if not (AZm and #zs > 0) then st.zone_cross = nil end
end

-- follow: a leader this far off teleported (a lodestone): hold and say so until he is near again
local function leader_far(f)
    local st, t, me, goal, dist, log = f.st, f.t, f.me, f.goal, f.dist, f.log
    -- (a leader tracked by his map marker is far by definition and his position is known: walk to him)
    if st.mode == "follow" and dist > M.cfg.leader_far_cm and st.target_via ~= "map" then
        if not st.far then
            st.far = true
            pcall(emit_move_event, "unreachable", { reason = "leader_far", leader_pos = goal, my_pos = me,
                detail = string.format("leader %.0f m away (teleported?)", dist / 100), mode = "follow" })
            if log then log(string.format("move: leader is %.0f m away; holding (lodestone catch-up needed)", dist / 100)) end
        end
        st.status = "leader_far"
        st.prog_t, st.win_t, st.win_pos = nil, t, v(me)
        return true
    elseif st.far then
        st.far = nil
        pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me })
    end
end

-- go_to: he stands at the goal's x,y but the goal is above the arrival's height (two capsule half-heights). Live
-- 2026-11-01 17:25-17:44Z: a build spot 2.1 m over his house floor ran "stuck n=159" for 19 min (stuck, local plans,
-- double jumps, backtracks); 18:14Z and 18:31Z: the Bramblemead Wise Old Man 3-6 m up on his platform, 60 s of the
-- same under it. One downward trace at the goal says which it is:
--   * nothing to stand on between the goal and his head (or his floor): the spot hangs in the air over his floor,
--     and standing right under it IS the arrival (arrived, below = true, below_m);
--   * a floor up there that a jump reaches: the local plan's jump edges get 12 s;
--   * a floor higher than that: one local plan from here looks for a way up (a stair or ramp round the back), and
--     with none the go_to fails at once, goal_above, with that floor's height.
-- Right under it the trace stops above his head: his gear (helmet, held tool) blocks Visibility traces.
local function overhead(f, early)
    local st, pawn, t, me, goal, log = f.st, f.pawn, f.t, f.me, f.goal, f.log
    local hh = st.half_h or 88
    if goal.Z - me.Z <= 2 * hh or standing_check(pawn) ~= true then st.ovh = nil; return nil end
    local feet = me.Z - hh
    local o = st.ovh
    if not (o and d2(o.at, me) < 50 and math.abs(o.at.Z - me.Z) < 30 and d2(o.goal, goal) < 30) then
        local close = d2(me, goal) < 60
        local stop_z = close and (me.Z + hh + 30) or (feet - 100)
        local fz
        if goal.Z + 30 > stop_z then
            local ok, hit, out = pcall(raw_trace, pawn, { X = goal.X, Y = goal.Y, Z = goal.Z + 30 }, { X = goal.X, Y = goal.Y, Z = stop_z })
            if not ok then return nil end
            fz = (hit and type(out) == "table" and out.ImpactPoint) and tonumber(out.ImpactPoint.Z) or nil
        end
        o = { at = v(me), goal = v(goal), t = t, floor = (fz and fz > feet + step_tol(st)) and fz or nil }
        st.ovh = o
    end
    if early and o.floor then return nil end -- (before routing: only the no-floor answers; a floor is the planners' job)
    local above = (goal.Z - me.Z) / 100
    if not o.floor and goal.Z - feet > M.cfg.below_max_cm then
        local detail = string.format("the spot is %.0f m up in the air above me, with nothing up there to stand on", (goal.Z - feet) / 100)
        if log then log("move: goal above: " .. detail) end
        return stop(st, { status = "failed", reason = "goal_above", why = detail, dist_m = d2(me, goal) / 100, s = t - st.t0, detail = detail }, log)
    end
    if not o.floor then
        st.below_ok = { X = goal.X, Y = goal.Y, Z = goal.Z }
        st.lp_jump_exec, st.ws_exec = nil, nil
        if log then log(string.format("move: the goal hangs %.1f m over the floor here, nothing to stand on up there: arrived, right under it", above)) end
        return stop(st, { status = "arrived", below = true, below_m = m1(above), dist_m = d2(me, goal) / 100, s = t - st.t0,
            detail = string.format("I'm right under it: the spot is %.1f m above the floor here, with nothing up there to stand on", above) }, log)
    end
    local rise = o.floor - feet
    local reach = math.max(jump_cm(st), (st.env and st.env.double_jump and st.env.dj_measured and st.env.djump) or 0) + 60
    local function give_up(what)
        local detail = string.format("the spot is on a floor %.1f m above me%s", rise / 100, what)
        if log then log("move: goal above: " .. detail) end
        return stop(st, { status = "failed", reason = "goal_above", why = detail, height = height_reason(st, rise, "target", t),
            rise_m = m1(rise / 100), dist_m = d2(me, goal) / 100, s = t - st.t0, detail = detail }, log)
    end
    if rise <= reach then
        if t - o.t > 12 then return give_up(", and 12 s of trying didn't get me up there") end
        return nil
    end
    if st.lp or st.lpath then return nil end -- a local plan is looking for (or walking) a way up
    local nf = 0 -- one plan from here, and one more each time a jump on the way failed (that move is left out)
    for _ in pairs(st.jump_fail or {}) do nf = nf + 1 end
    if (o.lp_tried or -1) < nf and st.use_lp ~= false and lp_module() then
        o.lp_tried = nf
        if lp_begin(st, pawn, me, goal, "goal_overhead", log) then st.status = "planning"; return true end
    end
    return give_up(", higher than I can jump, and I see no way up from here")
end

-- go_to: arrived (standing or wading at the goal), out of every zone (escape), or past the deadline.
-- follow: idle in range (or at the edge of a zone the leader stands in); standing in a zone near him, step out first.
local function arrival(f)
    local st, pc, pawn, t, me, goal, dist, log = f.st, f.pc, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    local zs, AZm, zone_in, mfeet = f.zs, f.AZm, f.zone_in, f.mfeet
    if st.mode == "go_to" then
        if st.escape and not zone_in then
            return stop(st, { status = "arrived", out_of_zones = true, zone = st.escape.zone, dist_m = dist / 100, s = t - st.t0 }, log)
        end
        local at_goal = reached(st, me, goal)
        if at_goal == nil then return stop(st, { status = "failed", reason = "verification_failed", detail = "position or destination unavailable" }, log) end
        if not at_goal then st.settle_t = nil end
        -- a jump/windstep plan holds arrival off only while it is in flight (its landing advances the plan) or just
        -- pressed; one that never left the ground is stale (it kept him "stuck" on the goal, travel uphill_plateau 02:15Z)
        local function in_flight(e) return e and (e.saw_air or t - (e.started or e.jump_t or t) < 2) end
        if at_goal and not in_flight(st.ws_exec) and not in_flight(st.lp_jump_exec) then
            local grounded = standing_check(pawn)
            if grounded == nil then return stop(st, { status = "failed", reason = "verification_failed", detail = "ground state unavailable" }, log) end
            if grounded then
                -- "arrived" means stopped there: no input while he slows down, and if he slides out of the circle
                -- he walks back in (live 20:33:51Z: "arrived" at 6.8 m/s, then a 5 m slide out of reach of the rock)
                local spd = h_speed(st, pawn)
                if spd and spd > M.cfg.arrive_still_cms and t - (st.settle_t or t) < M.cfg.arrive_settle_s then
                    st.settle_t = st.settle_t or t
                    st.status = "stopping"
                    return true
                end
                st.lp_jump_exec, st.ws_exec = nil, nil
                return stop(st, { status = "arrived", dist_m = dist / 100, s = t - st.t0 }, log)
            end
            if t - st.t0 <= st.timeout_s then st.status = "awaiting_landing"; return true end
        end
        -- a goal under water (the bed of a pond he was sent to drink from): swimming or wading over it IS the arrival
        -- (live 22:12:07Z: 1 cm from it on the surface, 3 m above it, then 21 s of circles in the water)
        if at_goal == false and (st.in_water or st.wade) and goal.Z < me.Z and d2(me, goal) <= st.tol_cm + 100 then
            return stop(st, { status = "arrived", in_water = true, below_m = math.floor((me.Z - goal.Z) / 10 + 0.5) / 10,
                dist_m = dist / 100, s = t - st.t0,
                detail = string.format("the spot is under water, %.1f m below me; I'm in the water over it", (me.Z - goal.Z) / 100) }, log)
        end
        if at_goal == false and d2(me, goal) <= st.tol_cm and not in_flight(st.ws_exec) and not in_flight(st.lp_jump_exec) then
            local r = overhead(f)
            if r ~= nil then return r end
        end
        if t - st.t0 > st.timeout_s then return stop(st, { status = "failed", reason = "timeout", dist_m = dist / 100 }, log) end
        return
    end
    local hold = st.idle and (st.tol_cm + M.cfg.follow_hysteresis_cm) or st.tol_cm
    -- he is walking off (> 2.5 m/s): go now, not once he is a further metre away (a human reacts in ~0.5 s)
    if st.idle and (st.leader_cms or 0) > 250 then hold = st.tol_cm end
    -- the leader stands in a zone and its edge is just ahead: wait here, at the edge
    local edge_hold = false
    if f.zone_goal and not zone_in and dist > hold then
        local z1, s1 = AZm.on_segment(zs, me, goal, mfeet, M.cfg.avoid_margin_cm)
        edge_hold = z1 ~= nil and s1 <= M.cfg.avoid_edge_cm
    end
    -- standing in a zone while near him: step out first (nearest point outside every zone)
    local exit_pt = nil
    if zone_in and (dist <= hold or st.zone_exit) then
        if not (st.zone_exit and not AZm.at(zs, st.zone_exit.X, st.zone_exit.Y, mfeet, M.cfg.avoid_margin_cm)) then
            local ex = AZm.exits(zs, me, mfeet, { margin = M.cfg.avoid_margin_cm + M.cfg.escape_extra_cm, max_cm = M.cfg.escape_max_cm })
            st.zone_exit = ex[1] and { X = ex[1].X, Y = ex[1].Y, Z = me.Z } or nil
            if st.zone_exit and log then log(string.format("move: standing in avoid zone %s; stepping out to %s", zone_in.id, fmt(st.zone_exit))) end
        end
        exit_pt = st.zone_exit
    end
    if ((dist <= hold and f.same_level) or edge_hold) and not exit_pt and not st.lp_jump_exec and not st.ws_exec then
        st.idle, st.status = true, edge_hold and "near_zone" or "near"
        if st.trip and #st.trip >= 4 then st.trip_ok = true; pcall(mem_flush, st, log, "near"); st.trip = { feet_of(st, me) } end
        if st.unreach then
            pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me, after_s = math.floor((t - st.unreach.since) * 10) / 10 })
            st.unreach = nil
        end
        if st.face_when_near then face(pc, me, goal, st, t) end
        st.stuck_n, st.win_t, st.win_pos = 0, t, v(me)
        st.prog_t, st.prog_pos = t, v(me)
        st.lp, st.lp_state, st.lpath = nil, nil, nil
        return true
    end
    st.idle = false
end

-- persistent follow, unreachable: stand facing him, re-check now and then, and resume by itself when he
-- moved or came within jump reach
local function unreachable_hold(f)
    local st, pc, t, me, goal, log = f.st, f.pc, f.t, f.me, f.goal, f.log
    local u = st.unreach
    if not u then return end
    st.status = "unreachable"
    local moved = d2(goal, u.leader_pos) > M.cfg.unreachable_moved_cm
    local within = (goal.Z - me.Z) <= (jump_cm(st) + 60)
    if moved or (t - u.check_t > M.cfg.unreachable_check_s and within and u.reason == "leader_above_jump_height") then
        if log then log(string.format("move: reachable again? (%s) leader=%s", moved and "leader moved" or "within reach", fmt(goal))) end
        pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me, after_s = math.floor((t - u.since) * 10) / 10 })
        st.unreach, st.link_tries = nil, 0
        st.prog_t, st.prog_pos, st.stuck_n, st.lp_plans_np, st.move_acc = t, v(me), 0, 0, 0
        st.lpath, st.backtrack_until, st.trail_i = nil, nil, nil
        return
    end
    if t - u.check_t > M.cfg.unreachable_check_s then u.check_t = t end
    st.win_t, st.win_pos = t, v(me)
    face(pc, me, goal, st, t)
    return true
end

-- ------------------------------------------------------------------ what he learns while walking
-- where he has been is walkable: his own trail (backtracking) and the trip (navmem routes), grounded samples
local function record_trails(f)
    local st, pawn, me, fe = f.st, f.pawn, f.me, f.fe
    local sc = st.self_crumbs
    if not sc[#sc] or d2(me, sc[#sc]) >= M.cfg.crumb_spacing_cm then
        if ground_check(pawn) ~= false then
            sc[#sc + 1] = v(me)
            if #sc > M.cfg.self_cap then table.remove(sc, 1) end
        end
    end
    st.trip = st.trip or {}
    local tp = st.trip
    if not tp[#tp] or d2(fe, tp[#tp]) >= M.cfg.trip_spacing_cm then
        if ground_check(pawn) ~= false then
            tp[#tp + 1] = fe
            if #tp > 2000 then table.remove(tp, 1) end
        end
    end
end

-- TRAPS: a stuck spot (_G.DW_TRAP_CAND, global: it survives new commands and trip flushes) keeps its own escape
-- path; once he is trap_leave_cm away, the path since he was last there is learned as its exit (and keeps
-- growing for trap_extend_cm, until well clear), and the direction that failed is tabooed.
local function trap_tick(f)
    local fe, log = f.fe, f.log
    if not f.st.trap_checked then
        -- a start inside a known trap with the goal outside it, once per move, whatever routes the walk (the
        -- oracle's routes skip memory_once): the walk is evidence for or against the trap (trap_evidence)
        local st = f.st
        st.trap_checked = true
        local mem, NMm = nav_mem()
        local okt, trap = false, nil
        if mem then okt, trap = pcall(NMm.trap_at, mem, fe) end
        if okt and trap then
            local okg, gtrap = pcall(NMm.trap_at, mem, feet_of(st, f.goal))
            if not (okg and gtrap and gtrap.id == trap.id) then st.trap_start, st.trap_stuck0 = trap.id, st.stuck_total or 0 end
        end
    end
    local cand = rawget(_G, "DW_TRAP_CAND")
    if cand then
        cand.path = cand.path or {}
        local cp = cand.path
        if (cp[#cp] and d2(fe, cp[#cp]) > 1000) or (not cp[#cp] and d2(fe, cand.at) > 1000) or os.time() - (cand.t or 0) > 600 then
            -- a teleport (respawn, Unstuck, lodestone, a ladder fixture; also between the stuck and the first
            -- sample) or a stale candidate: not an escape route
            _G.DW_TRAP_CAND, cand = nil, nil
        elseif not cp[#cp] or d2(fe, cp[#cp]) >= M.cfg.trip_spacing_cm then
            cp[#cp + 1] = fe
            if #cp > 400 then table.remove(cp, 1) end
        end
    end
    if not (cand and d2(fe, cand.at) > M.cfg.trap_leave_cm and math.abs(fe.Z - cand.at.Z) < 400) then return end
    local cp = cand.path or {}
    local k0 = nil
    for k = #cp, 1, -1 do if d2(cp[k], cand.at) < 400 then k0 = k; break end end
    local mem, NMm = nav_mem()
    if not (k0 and mem and #cp - k0 >= 2) then _G.DW_TRAP_CAND = nil; return end
    local ex = {}
    for k = k0, #cp do ex[#ex + 1] = cp[k] end
    local walked = 0
    for k = k0 + 1, #cp do walked = walked + d2(cp[k - 1], cp[k]) end
    local function heading_off(a, b) -- degrees between the leg cand.at->a and cand.at->b
        local ax, ay, bx, by = a.X - cand.at.X, a.Y - cand.at.Y, b.X - cand.at.X, b.Y - cand.at.Y
        local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
        if la < 1 or lb < 1 then return 180 end
        return math.deg(math.acos(math.max(-1, math.min(1, (ax * bx + ay * by) / (la * lb)))))
    end
    local st = f.st
    local stuck_in = st.trap_start == cand.trap and (st.stuck_total or 0) > (st.trap_stuck0 or 0)
    if cand.trap and not cand.learned and st.trap_start == cand.trap and not st.trap_exit_taken and not stuck_in then
        -- started in a known trap and walked out his own way, never stuck: evidence against it, no exit refresh
        pcall(trap_evidence, st, "walked out of it", log)
        _G.DW_TRAP_CAND = nil
        return
    end
    if not cand.trap and not cand.learned and cand.toward and walked <= M.cfg.trap_straight_x * d2(cp[k0], fe)
        and heading_off(fe, cand.toward) < 45 then
        -- he walked straight out the very way that "failed": nothing shut him in there (the stuck passed); a
        -- learned exit would only make every later start there walk that way first (t161, 2026-11-01)
        if log then log(string.format("move: memory: walked straight out of (%.0f,%.0f) the way that failed: not a trap", cand.at.X / 100, cand.at.Y / 100)) end
        _G.DW_TRAP_CAND = nil
        return
    end
    -- n_ok counts escapes from a fresh stuck once (also a stuck on a start inside a known trap); walking a known
    -- trap's exit again with no stuck counts as n_used
    if not cand.undo then
        -- what this learn replaces, so a walk out that leads nowhere can be taken back (finish: trap_undo; live
        -- 21:51-21:53Z two bug2 excursions out of t7 and back, each overwrote its working exit, both walks no_route)
        local okp, prev = pcall(NMm.trap_at, mem, cand.at)
        prev = okp and prev or nil
        cand.undo = { prev = prev, exit = prev and prev.exit, n_ok = prev and prev.n_ok, n_used = prev and prev.n_used,
            ts = prev and prev.ts, status = prev and prev.status, n = #mem.traps }
    end
    local okt, trap, how = pcall(NMm.learn_trap, mem, cand.at, ex, { src = "learned", used = cand.trap ~= nil and not stuck_in, refresh = cand.learned })
    if okt and trap then cand.undo.trap = trap; st.trap_learn = cand end
    if cand.toward and not cand.learned then pcall(NMm.taboo, mem, cand.at, cand.toward, "failed approach") end
    pcall(NMm.save, mem)
    if log and not cand.learned then log(string.format("move: memory: trap %s %s, exit %d pts", tostring(okt and trap and trap.id), tostring(how), #ex)) end
    cand.learned = true
    cand.extend_to = cand.extend_to or (walked + M.cfg.trap_extend_cm)
    if walked >= cand.extend_to then _G.DW_TRAP_CAND = nil end
end

-- WATER: learned from wading/swimming (EnvironmentComponent depth, MovementMode 4 = swimming); entering water
-- (unless the goal is in it) re-plans round it; the leader's wading marks water too
local function water_tick(f)
    local st, pawn, me, fe, goal, dist, log = f.st, f.pawn, f.me, f.fe, f.goal, f.dist, f.log
    if st.ticks % 6 ~= 0 then return end
    local okd, depth = pcall(function() return pawn.EnvironmentComponent:GetNormalizedWaterDepth() end)
    local okm, mmode = pcall(function() return pawn.CharacterMovement.MovementMode end)
    local wet = (okd and tonumber(depth) and tonumber(depth) > M.cfg.water_depth) or (okm and mmode == 4)
    local mem, NMm = nav_mem()
    if wet and mem then
        if NMm.mark_water(mem, fe) then st.water_new = (st.water_new or 0) + 1 end
        if not st.in_water then
            local hx, hy = 1, 0
            if st.aim then
                local ax2, ay2 = st.aim.X - me.X, st.aim.Y - me.Y
                local al = math.max(math.sqrt(ax2 * ax2 + ay2 * ay2), 1)
                hx, hy = ax2 / al, ay2 / al
            end
            water_sense_calibrate(st, pawn, me, fe, hx, hy, log)
            st.in_water = true
            st.water_entries = (st.water_entries or 0) + 1
            -- the goal itself is in the water close by (a pond to use, a ford): wading in is the point
            local goal_wet = st.wade or (NMm.is_water(mem, feet_of(st, goal)) and dist < M.cfg.lp_grid_m * 100)
            if log then log("move: entered water at " .. fmt(me) .. (goal_wet and "; the goal is in it" or "; re-planning round it")) end
            if st.use_lp and not st.trail_i and not goal_wet then st.lpath, st.water_replan = nil, true end
        end
    elseif not wet then
        -- walking dry on a cell marked water: looked at, forgotten when its centre is dry (water_false_mark)
        if mem and okm and mmode == 1 and NMm.is_water(mem, fe) then water_false_mark(st, pawn, fe, fe, mem, NMm, log) end
        if st.in_water and mem and (st.water_new or 0) > 0 then pcall(NMm.save, mem); st.water_new = 0 end
        st.in_water = nil
    end
    if st.target and st.target_kind == "player" and mem then
        local okl, ldepth = pcall(function() return st.target.EnvironmentComponent:GetNormalizedWaterDepth() end)
        if okl and tonumber(ldepth) and tonumber(ldepth) > M.cfg.water_depth then NMm.mark_water(mem, feet_of(st, goal)) end
    end
end

-- ------------------------------------------------------------------ asking for a lead
-- a player is near: wait for him to lead the way out (his trail, lead_tick), then carry on to the goal
local function wait_for_lead(st, hname, hpawn, me, t, why, detail)
    local okl, hl = pcall(function() return hpawn:K2_GetActorLocation() end)
    st.lead = { pawn = hpawn, name = hname, from = v(me), since = t, leader_pos = okl and v(hl) or v(me), why = why, detail = detail }
    st.crumbs, st.crumb_mark, st.trail_i = {}, 0, nil
    st.status = "waiting_for_lead"
    return true
end

-- go_to waiting for (up to lead_wait_s), then being led out by, the helper it asked; clear of the stuck spot
-- by lead_clear_cm, it carries on to its goal (one command, one result)
local function lead_tick(f)
    local st, pc, t, dt, me, dist, log = f.st, f.pc, f.t, f.dt, f.me, f.dist, f.log
    local ld = st.lead
    if not ld then return end
    local okl, hl = pcall(function() return ld.pawn:K2_GetActorLocation() end)
    if not (okl and ld.pawn:IsValid()) or t - ld.since > M.cfg.lead_wait_s and not ld.phase then
        st.lead, st.lead_done = nil, true
        return stop(st, { status = "failed", reason = "unreachable", why = ld.why, detail = ld.detail, asked = ld.name,
            dist_m = dist / 100 }, log)
    end
    -- the helper's walked trail (grounded samples), as leader breadcrumbs
    local c = st.crumbs
    if not c[#c] or d2(hl, c[#c]) >= M.cfg.crumb_spacing_cm then
        if ground_check(ld.pawn) ~= false then c[#c + 1] = v(hl) end
        if #c > M.cfg.crumb_cap then table.remove(c, 1) end
    end
    if not ld.phase then
        if d2(hl, ld.leader_pos) <= 300 then
            st.status = "waiting_for_lead"
            if st.prog_t then st.prog_t = st.prog_t + dt end
            st.win_t, st.win_pos = t, v(me)
            face(pc, me, hl, st, t)
            return true
        end
        ld.phase = "trail"
        if log then log("move: " .. ld.name .. " is leading; following his trail out") end
        restart_progress(st, t, me); st.stuck_n = 0
    end
    if d2(me, ld.from) > M.cfg.lead_clear_cm then
        if log then log("move: led clear of the stuck spot; carrying on to the goal") end
        pcall(emit_move_event, "led_out", { my_pos = me, helper = ld.name })
        st.lead, st.lead_done, st.trail_i = nil, true, nil
        restart_progress(st, t, me); st.stuck_n = 0
        st.bug_tried, st.mem_retry, st.link_tries = false, false, 0
    elseif not st.trail_i and #st.crumbs >= 2 then
        st.trail_i = nearest_crumb(st.crumbs, me) or 1 -- trail steering follows st.crumbs from st.trail_i
    end
end

-- memory routing, once per move: inside a known trap its exit first (and the way out refreshes it); after an
-- oracle fallback a remembered route that reaches the goal; else a remembered route for long trips (Dijkstra)
local function memory_once(f)
    local st, me, fe, goal, dist, log = f.st, f.me, f.fe, f.goal, f.dist, f.log
    if st.mem_checked or st.nav_required then return end
    st.mem_checked = true
    local mem, NMm = nav_mem()
    if not mem then return end
    local gfe = feet_of(st, goal)
    local okt, trap = pcall(NMm.trap_at, mem, fe)
    local okg, gtrap = pcall(NMm.trap_at, mem, gfe)
    local in_trap = okt and trap and not (okg and gtrap and gtrap.id == trap.id) -- (not when the goal is in it too)
    if in_trap and not rawget(_G, "DW_TRAP_CAND") then
        local c0 = trap.center
        _G.DW_TRAP_CAND = { at = { X = c0[1] * 100, Y = c0[2] * 100, Z = c0[3] * 100 }, t = os.time(), trap = trap.id }
        if log then log("move: memory: in trap " .. tostring(trap.id) .. "; the way out will be learned as its exit") end
    end
    local reach = st.mode == "go_to" and st.nav_fallback and mem_goal_plan(st, me, goal) or nil
    if reach then
        -- the oracle's route failed: a remembered route that ends at the goal beats any trap exit or length rule
        st.mpath, st.mwp, st.msrc = reach, 1, "memory"
        if log then log(string.format("move: memory: remembered route reaches the goal (%d pts) after %s", #reach, st.nav_fallback)) end
    elseif in_trap and st.mode == "follow" and st.target then
        -- following a visible leader out: his live trail beats a stored (maybe provisional) exit
    elseif in_trap and not (NMm.trap_trusted and NMm.trap_trusted(trap)) then
        -- shut him in once: his own way first (the exit is a stuck-ladder rung, memory_retry), so a walk out with no
        -- stuck can count against it
        if log then log(string.format("move: memory: in trap %s (it shut me in %d time(s), I walked out of it %d): my own way first, its exit only if I get stuck",
            tostring(trap.id), trap.n_ok or 1, trap.n_bad or 0)) end
        st.trap_own = trap.id
    elseif in_trap then
        st.mpath, st.mwp, st.msrc = NMm.trap_exit(trap), 1, "trap:" .. tostring(trap.id)
        st.trap_exit_taken = true
        if log then log("move: memory: in trap " .. tostring(trap.id) .. ", taking its exit first") end
    elseif dist > M.cfg.mem_min_trip_cm then
        local okp, pts = pcall(NMm.plan, mem, fe, gfe, { max_factor = 2.5 })
        if okp and pts then
            st.mpath, st.mwp, st.msrc = pts, 1, "memory"
            if log then log(string.format("move: memory: remembered route, %d pts", #pts)) end
        end
    end
end

-- leader breadcrumbs: when the straight/nav route is failing (it ended short, he is above, a plan failed, stuck)
local function trail_entry(f)
    local st, me, goal, dist, log, path = f.st, f.me, f.goal, f.dist, f.log, f.path
    if st.nav_required or not st.target or st.trail_i or #st.crumbs < 2 then return end
    local nav_bad = (path and st.path_partial and st.wp > #path) and dist > M.cfg.trail_min_dist_cm
    local above = (goal.Z - me.Z) > (jump_cm(st) + 100) and dist < 1500
    local led = st.trail_led and dist > st.tol_cm + 100
    if nav_bad or above or led or st.want_trail or st.stuck_n >= M.cfg.trail_enter_stuck then
        if st.trail_block_t and f.t - st.trail_block_t < 0.5 then return end
        st.want_trail = false
        st.trail_i = nearest_crumb(st.crumbs, me, st.trail_above_i and st.trail_above_i + 1)
        -- rejoin his trail where the straight way to it is open: the nearest crumb is often across a wall whose end
        -- he walked round (live church loop 02:15:54Z: rejoined 1.3 m away through a wall, 14 s pushing into it);
        -- the crumbs on toward him first, then back toward that wall end; none open = keep walking (the planner)
        local i0 = st.trail_i
        if i0 and f.pawn and d2(me, st.crumbs[i0]) > 100 then
            local feet = me.Z - (st.half_h or 88)
            local tests, last = 0, nil
            local function open(i) -- (at most 12 line tests, crumbs 1 m apart or more)
                local c = st.crumbs[i]
                if tests >= 12 or not c or c.air or c.gap or math.abs(c.Z - me.Z) > 100 or d2(me, c) > 1500 then return false end
                if last and d2(last, c) < 100 then return false end
                tests, last = tests + 1, c
                local okc, clear = pcall(escape_line_clear, f.pawn, me, feet, c)
                return okc and clear == true
            end
            local pick
            if open(i0) then pick = i0 end
            for i = i0 + 1, math.min(#st.crumbs, i0 + 40) do if pick or tests >= 7 then break end; if open(i) then pick = i end end
            last = st.crumbs[i0]
            for i = i0 - 1, math.max(1, i0 - 40), -1 do if pick then break end; if open(i) then pick = i end end
            if pick ~= i0 and log then
                log(string.format("move: trail: the way to his nearest trail point (i=%d) is blocked; %s", i0,
                    pick and string.format("rejoining at i=%d, in the open", pick) or "walking on until it is in the open"))
            end
            st.trail_i = pick
            if not pick then st.trail_block_t = f.t; return end
        end
        if st.trail_i then
            st.trail_above_i = nil
            st.trail_entries = (st.trail_entries or 0) + 1
            if log then log(string.format("move: trail ON i=%d/%d", st.trail_i, #st.crumbs)) end
        end
    end
end

-- ------------------------------------------------------------------ steering: where to aim this frame
-- A learned link, a step-off or Bug2 in progress steers first; else a backtrack, then the local plan, the
-- leader's trail, a remembered route, the oracle route; else straight at the goal. Each sets f.aim/f.src
-- (f.idxp = an index advanced or an escape running: progress for the give-up clock).

-- running a learned traversal link (traverse_learn.lua): approach the run-up point, run at link.from, jump
-- there (double/sprint per the link), then verify the landing near link.to
local function steer_link(f)
    local st, pawn, t, me, log = f.st, f.pawn, f.t, f.me, f.log
    local lx = st.link_exec
    local L = lx.link
    local from = { X = L.from[1] * 100, Y = L.from[2] * 100, Z = L.from[3] * 100 }
    local to = { X = L.to[1] * 100, Y = L.to[2] * 100, Z = L.to[3] * 100 }
    local hx, hy = to.X - from.X, to.Y - from.Y
    local hl = math.max(math.sqrt(hx * hx + hy * hy), 1)
    hx, hy = hx / hl, hy / hl
    local runup = (tonumber(L.runup_m) or 0) * 100
    local feet = { X = me.X, Y = me.Y, Z = me.Z - (st.half_h or 90) }
    local function done(ok, why)
        st.link_exec = nil
        local TL = tl_module()
        if TL then pcall(TL.record_attempt, log, L.id, ok, why) end
        if log then log(string.format("move: link %s %s %s", tostring(L.id), ok and "OK" or "FAILED", tostring(why or ""))) end
        restart_progress(st, t, me)
        st.lpath, st.trail_i = nil, nil
        if ok then st.link_ok = (st.link_ok or 0) + 1 end
    end
    if lx.phase == "approach" then
        local start = runup > 50 and { X = from.X - hx * runup, Y = from.Y - hy * runup, Z = from.Z } or from
        f.aim, f.src = start, "link"
        if d2(me, start) < 60 then lx.phase = "run" end
        if t - lx.t0 > M.cfg.link_approach_s then done(false, "approach_timeout") end
    elseif lx.phase == "run" then
        f.aim, f.src = to, "link"
        if (L.needs and L.needs.sprint) or L.move == "sprint_jump" then st.sprint_want = true end
        local along = (me.X - from.X) * hx + (me.Y - from.Y) * hy
        if d2(me, from) < 50 or along > 0 then
            local jr = start_jump(st, t, pawn, L.move == "double_jump" and st.env and st.env.double_jump, log)
            if jr == "accepted" then lx.phase, lx.t_jump = "air", t elseif jr ~= "busy" then return true end
        end
    elseif lx.phase == "air" then
        f.aim, f.src = to, "link"
        local ground = ground_check(pawn)
        if t - lx.t_jump > 0.4 and ground then
            local dz = math.abs(feet.Z - to.Z)
            done(d2(feet, to) < 200 and dz < 100, string.format("landed %.1fm from link.to", d2(feet, to) / 100))
        elseif t - lx.t_jump > 4 then
            done(false, "no_landing")
        end
    end
    if st.link_exec then f.idxp = true end -- executing a link is progress (no give-up mid-run)
end

-- step-off (perched on top of geometry, stuck_tick): pushes all round, alternating sides, until he is off
local function steer_stepoff(f)
    local st, t, me, log = f.st, f.t, f.me, f.log
    local so = st.stepoff
    if d2(me, so.start) > 120 or (so.start.Z - me.Z) > 60 then
        if log then log("move: stepped off") end
        st.stepoff = nil
        restart_progress(st, t, me); st.stuck_n = 0
        st.lpath = nil
    elseif t - so.t0 > 0.6 then
        so.i, so.t0 = so.i + 1, t
        if so.i > 8 then st.stepoff = nil end
    end
    if st.stepoff then
        local yaw = so.yaw0 + so.i * 45 * ((so.i % 2 == 0) and 1 or -1)
        f.aim, f.src = { X = me.X + math.cos(math.rad(yaw)) * 300, Y = me.Y + math.sin(math.rad(yaw)) * 300, Z = me.Z }, "stepoff"
        f.idxp = true
    end
end

-- BUG2 wall-following (automaticaddison.com/the-bug2-algorithm-for-robot-motion-planning ;
-- cs.columbia.edu/~allen/F19/NOTES/Chap2-Bug.pdf): keep the obstacle on one side until he crosses the
-- start->goal line closer to the goal than where he hit it; one side, then the other, bounded. Probes every 3rd frame.
local function steer_bug2(f)
    local st, pawn, t, me, goal, log = f.st, f.pawn, f.t, f.me, f.goal, f.log
    local bug = st.bug
    f.src, f.idxp = "bug2", true
    bug.travel = bug.travel + (bug.last and d2(me, bug.last) or 0)
    bug.last = v(me)
    local function blocked_dir(yaw)
        local hx, hy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
        local knee = me.Z - (st.half_h or 90) + 50
        local okp, hit, out = pcall(raw_trace, pawn, { X = me.X + hx * 60, Y = me.Y + hy * 60, Z = knee },
            { X = me.X + hx * 170, Y = me.Y + hy * 170, Z = knee })
        st.traces = (st.traces or 0) + 1
        if okp and hit and ((out.ImpactNormal and out.ImpactNormal.Z or 0) < M.cfg.probe_wall_nz) then return true end
        if goal.Z > me.Z - 150 then
            -- don't wall-follow off a ledge when the goal is level or above (it only makes it worse)
            local fx, fy = me.X + hx * 130, me.Y + hy * 130
            local feet = me.Z - (st.half_h or 90)
            local okd, hitd, outd = pcall(raw_trace, pawn, { X = fx, Y = fy, Z = feet + 60 }, { X = fx, Y = fy, Z = feet - 400 })
            st.traces = (st.traces or 0) + 1
            if okd and (not hitd or (outd.ImpactPoint and outd.ImpactPoint.Z < feet - 150)) then return true end
        end
        return false
    end
    if st.ticks % 3 == 0 then
        if blocked_dir(bug.yaw) then bug.yaw = bug.yaw + bug.dir * 35
        elseif not blocked_dir(bug.yaw - bug.dir * 90) then bug.yaw = bug.yaw - bug.dir * 25 end
        -- leave: on the m-line, closer to the goal than the hit point, and the way to the goal is open
        local sx, sy, gx, gy = bug.s.X, bug.s.Y, goal.X, goal.Y
        local lx2, ly2 = gx - sx, gy - sy
        local ll = math.max(math.sqrt(lx2 * lx2 + ly2 * ly2), 1)
        local off = math.abs((me.X - sx) * ly2 - (me.Y - sy) * lx2) / ll
        if off < 80 and d2(me, goal) < bug.hit_d - 100 and bug.travel > 150 then
            local gyaw = math.deg(math.atan(gy - me.Y, gx - me.X))
            if not blocked_dir(gyaw) then
                if log then log(string.format("move: bug2 left the wall after %.0f cm", bug.travel)) end
                st.bug = nil
                restart_progress(st, t, me); st.stuck_n = 0
            end
        end
    end
    if st.bug and (t - bug.t0 > M.cfg.bug_side_s or bug.travel > M.cfg.bug_side_cm) then
        if not bug.switched then
            if log then log("move: bug2 switching sides") end
            bug.switched, bug.dir, bug.t0, bug.travel, bug.yaw = true, -bug.dir, t, 0, bug.yaw + 180
        else
            if log then log("move: bug2 gave up") end
            st.bug = nil
            st.prog_t = t - M.cfg.give_up_s - 1 -- straight back to the give-up decision
        end
    end
    if st.bug then f.aim = { X = me.X + math.cos(math.rad(bug.yaw)) * 300, Y = me.Y + math.sin(math.rad(bug.yaw)) * 300, Z = me.Z } end
end

-- a planned Windstep edge: cast at the take-off point (the spell job owns input meanwhile), jump, and accept the
-- edge only on a grounded landing at its endpoint; any doubt ends the move with its windstep_* reason
local function steer_superjump(f, p)
    local st, pawn, t, me, log = f.st, f.pawn, f.t, f.me, f.log
    local prev = st.lpath[st.lwp - 1]
    local ws = st.ws_exec
    local function fail(reason, detail) return stop(st, { status = "failed", reason = reason, detail = detail }, log) end
    if not ws and prev and d2(me, prev) < 50 then
        local a, token, generation = move_arbiter(), st.owner_token, st.gen
        local owns = a and a.owns_move and a.owns_move(token)
        if st.gen ~= generation or st.mode == "idle" then return true end
        if not owns then return fail("windstep_owner_lost", "movement ownership lost before casting") end
        if ground_check(pawn) ~= true then return fail("windstep_not_grounded", "grounded takeoff was not confirmed") end
        local gate = windstep_status(nil, t, true)
        if gate.state ~= "castable" then return fail(gate.why or "windstep_unavailable", gate.detail or gate.state) end
        local sp, prof = spells_mod(), tm_profile().windstep
        if not (sp and sp.cast_now and prof and st.env and st.env.ws_up_cm) then
            return fail("windstep_unavailable", "spell executor or measured envelope unavailable")
        end
        owns = a.owns_move(token)
        if st.gen ~= generation or st.mode == "idle" then return true end
        if not owns then return fail("windstep_owner_lost", "movement ownership lost before casting") end
        local ok, job = pcall(sp.cast_now, log, prof.spell_asset, { owner_token = token })
        if st.gen ~= generation or st.mode == "idle" then if ok and job and job.cancel then pcall(job.cancel) end; return true end
        if not ok or not job or type(job.poll) ~= "function" then return fail("windstep_cast_failed", tostring(job)) end
        st.ws_job, st.ws_exec = job, { phase = "casting", index = st.lwp, token = token, started_t = t, path = st.lpath, endpoint = p }
        ws = st.ws_exec
    elseif not ws and prev then f.aim = prev end
    if not (ws and ws.index == st.lwp) then return end
    local a, generation = move_arbiter(), st.gen
    local owns = a and a.owns_move and a.owns_move(ws.token)
    if st.gen ~= generation or st.mode == "idle" then return true end
    if not owns then return fail("windstep_owner_lost", "movement ownership lost during traversal") end
    if ws.phase == "casting" then
        local job = st.ws_job
        if t - ws.started_t > 15 then return fail("windstep_cast_timeout", "spell cast did not finish") end
        local ok, result = pcall(job.poll)
        if st.gen ~= generation or st.mode == "idle" or st.ws_job ~= job then return true end
        if not ok then return fail("windstep_cast_failed", tostring(result)) end
        owns = a.owns_move(ws.token)
        if st.gen ~= generation or st.mode == "idle" or st.ws_job ~= job then return true end
        if not owns then return fail("windstep_owner_lost", "movement ownership lost during casting") end
        if not result then
            st.status = "casting"
            st.win_t, st.win_pos, st.prog_t = t, v(me), nil
            return true -- no movement input while the spell job owns the player's input
        end
        st.ws_job = nil
        if not result.ok then return fail(result.reason or "windstep_cast_failed", result.data and (result.data.detail or result.data.why)) end
        local jr = start_jump(st, t, pawn, false, log)
        if jr ~= "accepted" then
            if jr == "busy" then return fail("windstep_interrupted", "another jump is still active") end
            return true
        end
        ws.phase, ws.jump_t = "air", t
        return
    end
    local grounded = ground_check(pawn)
    if grounded == false then ws.saw_air = true end
    if t - ws.jump_t > 0.4 and ws.saw_air and grounded == true then
        local dz = math.abs((me.Z - (st.half_h or 90)) - p.Z)
        if d2(me, p) < M.cfg.lp_radius_cm and dz < step_tol(st) then
            pcall(emit_self_edge, st, prev, p, p.act)
            st.lwp, st.ws_exec = st.lwp + 1, nil
            f.idxp = true
        else return fail("windstep_landing_missed", "landed away from the planned endpoint") end
    elseif t - ws.jump_t > 8 then
        return fail("windstep_landing_timeout", "grounded landing was not confirmed")
    end
end

-- a typed jump edge (jump / djump) advances only after owned airborne evidence and a landing at its endpoint
local function steer_typed_jump(f, p)
    local st, gen, pc, pawn, t, me, goal, log = f.st, f.gen, f.pc, f.pawn, f.t, f.me, f.goal, f.log
    local function traversal_failure(detail)
        -- a jump that took off and landed wrong is left out of this trip's next plans (the planner then finds the
        -- other way, e.g. the leap from the other landing: live 19:01Z the same double jump missed twice)
        local fp, fi = st.lpath, st.lwp
        local edge_fault = type(detail) == "string" and (detail:find("landing", 1, true) or detail:find("unavailable", 1, true))
        if edge_fault and fp and fi and fp[fi] and fp[fi - 1] then
            local LPm = lp_module()
            if LPm and LPm.edge_key then
                local a0, b0 = fp[fi - 1], fp[fi]
                st.jump_fail = st.jump_fail or {}
                st.jump_fail[LPm.edge_key(a0.X, a0.Y, a0.Z) .. ">" .. LPm.edge_key(b0.X, b0.Y, b0.Z)] = true
            end
        end
        st.local_authority, st.local_binding, st.lpath, st.lp_jump_exec = nil, nil, nil, nil
        st.jump_double = false
        st.trav_fails = (st.trav_fails or 0) + 1
        -- follow too (a fight's approach): one missed landing was "no_route" at once, and the fight ended path_blocked
        -- while the rat stood 22 m up an open slope he then walked (live 2026-11-01 20:09:02Z and 20:09:07Z, ClaudeQ4
        -- Ratcatcher); a follow gives up only on the third failed jump of the trip
        if st.mode ~= "follow" or st.trav_fails < 3 then
            -- go_to: a missed landing is one failed local plan, not the end of the trip (live 2026-10-31 19:59: "jump
            -- landing missed" ended a 225 m walk 48 m short); re-plan from where he landed, the give-up ladder still
            -- ends real non-progress
            st.lp_fail_t, st.lp_fail, st.want_trail = t, detail, true
            note(st, detail)
            if log then log("move: " .. detail .. "; re-planning from here") end
            return true
        end
        st.local_observe_done, st.nav_required, st.nav_fail = true, true, detail
        st.unreach = { reason = "no_route", since = t, check_t = t, leader_pos = v(goal) }
        st.status = "unreachable"
        pcall(emit_move_event, "unreachable", { reason = "no_route", detail = detail, leader_pos = goal, my_pos = me, mode = "follow" })
        return true
    end
    local prev = st.lpath[st.lwp - 1]
    local j = st.lp_jump_exec
    local bind = binding(st, pawn)
    if not owned(bind) or (st.local_authority and not local_route_owned(st, gen, pawn, pc, goal)) then return true end
    if p.act == "djump" and not (st.env and st.env.double_jump and (not st.local_authority or st.env.dj_measured)) then
        return traversal_failure("double jump unavailable")
    end
    if not j and prev and d2(me, prev) < 50 then
        local grounded = ground_check(pawn)
        if not owned(bind) then return true end
        if grounded ~= true then return traversal_failure("jump takeoff not confirmed grounded") end
        local jr = start_jump(st, t, pawn, p.act == "djump" and st.env and st.env.double_jump, log)
        if st.local_authority and not local_route_owned(st, gen, pawn, pc, goal) then return true end
        if jr == "accepted" then
            st.lp_jump_exec = { path = st.lpath, index = st.lwp, endpoint = p, previous = prev, token = st.owner_token, started = t, saw_air = false }
            st.lp_jumped[st.lwp] = t; j = st.lp_jump_exec
        elseif jr ~= "busy" then return true end
    elseif not j and prev and d2(me, prev) >= 50 then f.aim = prev end
    if not j then return end
    if j.path ~= st.lpath or j.index ~= st.lwp or j.endpoint ~= p or j.token ~= st.owner_token then
        return traversal_failure("jump route changed")
    end
    local grounded = ground_check(pawn)
    if not owned(bind) or (st.local_authority and not local_route_owned(st, gen, pawn, pc, goal)) then return true end
    if grounded == false then j.saw_air = true end
    if j.saw_air and grounded == true then
        local dz = math.abs((me.Z - st.half_h) - p.Z)
        if d2(me, p) < (p.leap and M.cfg.leap_land_cm or M.cfg.lp_radius_cm) and dz < step_tol(st) then
            pcall(emit_self_edge, st, prev, p, p.act)
            if not owned(bind) then return true end
            if st.local_authority and st.lwp == #st.lpath then p.act = "walk" end
            st.lwp, st.lp_jump_exec = st.lwp + 1, nil; f.idxp = true
        else return traversal_failure("jump landing missed") end
    elseif t - j.started > 8 then return traversal_failure("jump landing unconfirmed") end
end

-- the local plan: next cell point (successful jump/drop edges are reported as traversal self_edges)
local function steer_local(f)
    local st, me = f.st, f.me
    local i0 = st.lwp
    st.lwp = advance(st.lpath, st.lwp, me, M.cfg.lp_radius_cm, step_tol(st), st.half_h or 90, true)
    if st.lwp > i0 then
        f.idxp = true
        for k = i0, st.lwp - 1 do
            local pt = st.lpath[k]
            if k > 1 and (pt.act == "jump" or pt.act == "djump" or pt.act == "drop") then
                pcall(emit_self_edge, st, st.lpath[k - 1], pt, pt.act)
            end
        end
    end
    if st.local_authority and st.lwp > #st.lpath then st.lwp = #st.lpath end
    if st.lwp > #st.lpath then st.lpath = nil; return end -- segment done; the forward probe re-plans if still blocked
    local p = st.lpath[st.lwp]
    f.aim, f.src = p, "local"
    if p.act == "superjump" then return steer_superjump(f, p) end
    if p.act == "jump" or p.act == "djump" then return steer_typed_jump(f, p) end
end

-- the leader's trail: hold at the take-off of a move of his we lack (a gap); jump where he jumped
local function steer_trail(f)
    local st, pawn, t, me, log = f.st, f.pawn, f.t, f.me, f.log
    local i0 = st.trail_i
    st.trail_i = advance(st.crumbs, st.trail_i, me, M.cfg.wp_radius_cm, step_tol(st))
    if st.trail_i > i0 then f.idxp = true end
    if st.trail_i > #st.crumbs then
        st.trail_i = nil
        if log then log("move: trail OFF (caught up)") end
        return
    end
    local cr = st.crumbs[st.trail_i]
    -- his jump we already tried here and missed: back on the ground at the take-off, below where he landed
    local top, missed = cr, false
    if cr.air and st.trail_jumped[cr] and st.trail_jump_t and t - st.trail_jump_t > 0.8 and d2(me, cr) < 250 then
        local k = st.trail_i
        while k < #st.crumbs and st.crumbs[k].air do k = k + 1 end
        top = st.crumbs[k]
        missed = not top.air and top.Z - me.Z > step_tol(st) + 40
    end
    if (missed or (not cr.air and not cr.gap and d2(me, cr) < 250 and cr.Z - me.Z > step_tol(st) + 40 + 0.9 * d2(me, cr)))
        and (not st.jump_t or t - st.jump_t > 0.6) and ground_check(pawn) == true then -- (a ramp or stairs is no wall)
        cr = top
        -- he walks on top of something we did not get onto (a jump of his we missed or lack): his trail where it
        -- comes back down to our level, round the obstacle (the stuck ladder plans if the way is blocked); while he
        -- is still up there, walk below him (straight at him, the local planner round what is in the way)
        local found = false
        for k = st.trail_i + 1, #st.crumbs do
            local q = st.crumbs[k]
            if q.gap then break end
            if not q.air and math.abs(q.Z - me.Z) <= 100 and d2(me, q) > 150 then
                if log then log(string.format("move: trail: his path goes %.1f m up here; skipping to where it comes back down (i=%d -> %d)",
                    (cr.Z - me.Z) / 100, st.trail_i, k)) end
                st.trail_i, st.trail_skips = k, (st.trail_skips or 0) + 1
                cr, found = q, true
                break
            end
        end
        if not found then
            if log then log(string.format("move: trail: his path goes %.1f m up here; walking below him until it comes down",
                (cr.Z - me.Z) / 100)) end
            st.trail_above_i, st.trail_i, st.trail_skips = st.trail_i, nil, (st.trail_skips or 0) + 1
            return
        end
    end
    f.aim, f.src = cr, "trail"
    if cr.gap then
        local prev = st.crumbs[st.trail_i - 1]
        f.aim = prev or cr
        if d2(me, f.aim) < 150 then st.status = "holding"; st.win_t, st.win_pos = t, v(me); st.hold_gap = true end
    end
    if cr.air and d2(me, cr) < 150 and not st.trail_jumped[cr] then
        -- where he landed above our single jump's reach, double jump (when we have it)
        local k = st.trail_i
        while k < #st.crumbs and st.crumbs[k].air do k = k + 1 end
        local land = st.crumbs[k]
        -- a hop or Windstep of his over open ground is not copied: each copied jump cost 1-3 s at 2-3 m/s, a gap that
        -- never closes behind a 6.8 m/s sprint (ghost ladder 2026-11-01: Luis hops and Windsteps on the flat; church
        -- loop 20:19:24Z, 10.5 m behind for 5 s after one). Run on when the straight line to where he lands on our
        -- level (or to below him while he is still up) is clear at knee height with floor all the way
        -- (not when he lands on something above our step: he jumped up onto it, and the way on is that jump; live
        -- doric 23:31:40Z, "running on" toward him on a 1.8 m ledge, then 4 s pushing into its face at 1 m/s)
        local up = land and not land.air and land.Z - me.Z > step_tol(st)
        local tgt = not up and (land and not land.air and math.abs(land.Z - me.Z) <= step_tol(st) and land or f.goal)
        if up then
            -- what he "landed" on must be there: no floor under him at his height = he was still in the air (hops and
            -- Windsteps in a row, a sample between two of them reads as ground). Then it is open ground: run on below
            -- him (live doric 01:24:35Z: Luis 1.5-2.4 m over flat ground for 5 s; a copied double jump at 3 m/s)
            local hh = st.half_h or 90
            local okf, hitf, outf = pcall(raw_trace, pawn, { X = land.X, Y = land.Y, Z = land.Z }, { X = land.X, Y = land.Y, Z = land.Z - hh - 400 })
            local fz = okf and hitf and type(outf) == "table" and outf.ImpactPoint and tonumber(outf.ImpactPoint.Z)
            if fz and land.Z - hh - fz > step_tol(st) and math.abs(fz + hh - me.Z) <= step_tol(st) then
                up, tgt = false, { X = land.X, Y = land.Y, Z = fz + hh }
            end
        end
        if up then
            -- (but where his trail already comes back down to our level close by, the way on may go round what he
            -- hopped onto: run there when the line is clear; and a landing out of our jump's reach is not copied,
            -- live church loop 00:39:15Z, a copied 2.8 m jump missed and cost 11 s)
            for j = k + 1, #st.crumbs do
                local q = st.crumbs[j]
                if q.gap or d2(me, q) > 1200 then break end
                if not q.air and math.abs(q.Z - me.Z) <= step_tol(st) then tgt = q; break end
            end
            if not tgt then
                st.env = st.env or envelope(pawn, f.pc)
                local reach = math.max(jump_cm(st), (st.env and st.env.double_jump and st.env.dj_measured and st.env.djump) or 0)
                if land.Z - me.Z > reach then tgt = f.goal end
            end
        end
        if tgt and d2(me, tgt) > 100 and d2(me, tgt) < 1200 and ground_check(pawn) == true then
            local okc, clear = pcall(escape_line_clear, pawn, me, me.Z - (st.half_h or 88), tgt)
            if okc and clear == true then
                for j = st.trail_i, #st.crumbs do
                    if not st.crumbs[j].air then break end
                    st.trail_jumped[st.crumbs[j]] = true
                end
                st.trail_hops_run = (st.trail_hops_run or 0) + 1
                if log then log(string.format("move: trail: his jump here %s, and the way under it is clear: running on, no jump",
                    tgt == land and "lands back on my level" or "is over open ground")) end
                return
            end
        end
        st.env = st.env or envelope(pawn, f.pc)
        local dbl = land and not land.air and (land.Z - me.Z) > jump_cm(st) - 20 and st.env and st.env.double_jump or false
        local jr = start_jump(st, t, pawn, dbl, log)
        if jr == "accepted" then
            for k = st.trail_i, #st.crumbs do
                if not st.crumbs[k].air then break end
                st.trail_jumped[st.crumbs[k]] = true
            end
            st.trail_jumps, st.trail_jump_t = (st.trail_jumps or 0) + 1, t
        elseif jr ~= "busy" then return true end
    end
end

-- a remembered route (navmem: floor points, jump flags): reach a jump's start, then jump
local function steer_memory(f)
    local st, pawn, t, me, log = f.st, f.pawn, f.t, f.me, f.log
    local hh = st.half_h or 90
    local i0 = st.mwp
    st.mwp = advance(st.mpath, st.mwp, me, M.cfg.wp_radius_cm, step_tol(st), hh)
    if st.mwp > i0 then f.idxp = true end
    if st.mwp > #st.mpath then
        if log then log("move: memory route done (" .. tostring(st.msrc) .. ")") end
        st.mpath = nil
        return
    end
    local mp = st.mpath[st.mwp]
    f.aim, f.src = { X = mp.X, Y = mp.Y, Z = mp.Z + hh }, "memory"
    local prevp = st.mpath[st.mwp - 1]
    if (mp.act == "jump" or mp.act == "djump") and prevp then
        st.mem_jumped = st.mem_jumped or {}
        local last = st.mem_jumped[st.mwp]
        if d2(me, prevp) < 60 and (not last or t - last > 1.5) then
            local jr = start_jump(st, t, pawn, false, log)
            if jr == "accepted" then st.mem_jumped[st.mwp] = t elseif jr ~= "busy" then return true end
        elseif d2(me, prevp) >= 60 and not last and d2(me, mp) > d2(prevp, mp) then
            f.aim = { X = prevp.X, Y = prevp.Y, Z = prevp.Z + hh }
        end
    end
end

-- the oracle route's waypoint (advanced in route_tick); a nav link: reach its start, then jump
local function steer_nav(f)
    local st, pawn, t, me, log, path = f.st, f.pawn, f.t, f.me, f.log, f.path
    if st.wp > #path then return end
    local aim = path[st.wp]
    f.aim, f.src = aim, "nav"
    local prev = path[st.wp - 1]
    if prev and aim.link then
        local last = st.nav_jumped[st.wp]
        if d2(me, prev) < 60 and (not last or t - last > 1.5) then
            local jr = start_jump(st, t, pawn, false, log)
            if jr == "accepted" then st.nav_jumped[st.wp] = t; st.link_jumps = (st.link_jumps or 0) + 1 elseif jr ~= "busy" then return true end
        elseif d2(me, prev) >= 60 and not last and d2(me, aim) > d2(prev, aim) then
            f.aim = prev -- reach the take-off spot first
        end
    end
end

-- ------------------------------------------------------------------ dry routing round water
-- Water slows him (MaxSwimSpeed 300 cm/s against ~650 running): water ahead on the way (the trail, a remembered
-- or oracle route, or the straight line) is weighed by scripts/wetroute.lua, a time-cost A* on the remembered water
-- map; when going round is faster he follows that detour, then the way he was on picks up past the water. The water
-- channel looks at the way ahead, so a pond he has never waded is seen before he walks in (Luis, 2026-11-02).
M._wf = {} -- (no main-chunk local: the chunk is at its 200-locals limit)
function M._wf.module() return lazy(ROOT .. "/client_mod/scripts/wetroute.lua", "plan") end
-- the way ahead from where he stands: points of the source he is on, with the index each came from
function M._wf.way(st, me, goal)
    local pts, src = {}, "straight"
    local function add(list, i0)
        for k = i0, #list do pts[#pts + 1] = { X = list[k].X, Y = list[k].Y, k = k } end
    end
    if st.trail_i and st.crumbs[st.trail_i] then src = "trail"; add(st.crumbs, st.trail_i)
    elseif st.mpath and st.mwp and st.mpath[st.mwp] then src = "memory"; add(st.mpath, st.mwp)
    elseif st.path and st.wp and st.path[st.wp] then src = "nav"; add(st.path, st.wp) end
    pts[#pts + 1] = { X = goal.X, Y = goal.Y }
    return pts, src
end
-- along the way (from me), the first water and the first dry spot after it, within the lookahead
function M._wf.stretch(me, way, wet, look)
    -- the target past it: up to 10 m on along the way while it stays dry (aiming at the shore point itself made
    -- the detour come back along the far bank to it)
    local prev, walked, enter, exit = { X = me.X, Y = me.Y }, 0, nil, nil
    for _, q in ipairs(way) do
        local dx, dy = q.X - prev.X, q.Y - prev.Y
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 1 then
            local n = math.max(1, math.ceil(l / 50))
            for i = 1, n do
                local x, y = prev.X + dx * i / n, prev.Y + dy * i / n
                local at = walked + l * i / n
                local w = wet(x, y)
                if exit then
                    if w then return enter, exit end
                    exit.X, exit.Y, exit.k = x, y, q.k
                    if at - exit.at_cm >= 1000 then return enter, exit end
                elseif w and not enter then
                    if at > look then return nil end
                    enter = { X = x, Y = y, at_cm = at }
                elseif enter and not w and not wet(x + dx / l * 200, y + dy / l * 200) then
                    exit = { X = x, Y = y, k = q.k, at_cm = at }
                end
            end
        end
        walked, prev = walked + l, q
        if not enter and walked > look then return nil end
    end
    return enter, exit
end
-- is there water over the ground at (x, y)? the water channel (nil when it can't tell)
function M._wf.look(pawn, x, y, z)
    local okf, hf, outf = pcall(raw_trace, pawn, { X = x, Y = y, Z = z + 150 }, { X = x, Y = y, Z = z - 400 })
    if not (okf and hf and outf.ImpactPoint) then return nil end
    return water_at(pawn, x, y, outf.ImpactPoint.Z)
end
function M._wet_tick(f)
    local st, pawn, me, t, log, goal = f.st, f.pawn, f.me, f.t, f.log, f.goal
    if st.wade or st.in_water or st.local_authority or st.ticks % 3 ~= 0 then return end
    local mem, NMm = nav_mem()
    local WRm = M._wf.module()
    if not (mem and NMm and NMm.is_water and WRm) then return end
    local function wet(x, y) return NMm.is_water(mem, { X = x, Y = y }) end
    local feet = me.Z - (st.half_h or 88)
    -- look ahead with the water channel (one spot per look, 3/6/9 m on the way he is heading): water found is
    -- remembered, and a detour that runs into it is planned again
    local head = st.wet and st.wet.pts[st.wet.i] or st.aim or goal
    local hx, hy = head.X - me.X, head.Y - me.Y
    local hl = math.sqrt(hx * hx + hy * hy)
    if hl > 100 and rawget(_G, "DW_WATER_CH") then
        st.wet_look_i = (st.wet_look_i or 0) % 3 + 1
        local k = math.min(hl, st.wet_look_i * 300)
        local x, y = me.X + hx / hl * k, me.Y + hy / hl * k
        if not wet(x, y) then
            if M._wf.look(pawn, x, y, feet) == true then
                NMm.mark_water(mem, { X = x, Y = y, Z = feet })
                st.water_new = (st.water_new or 0) + 1
                if st.wet then st.wet, st.wet_t, st.wet_swim_key = nil, nil, nil end
            end
        end -- (a remembered cell is not re-checked here: shallow water no channel sees would be forgotten each look)
    end
    if st.wet then return end
    if t - (st.wet_t or -100) < 1.0 then return end
    st.wet_t = t
    local way, src = M._wf.way(st, me, goal)
    local enter, exit = M._wf.stretch(me, way, wet, M.cfg.wet_lookahead_cm)
    if not (enter and exit) then return end -- no water ahead, or the goal is in it (a pond to use: wade in)
    -- the dry spot past it may be water no one has waded yet (live 00:24:57Z: a detour "round" the pond to a goal
    -- in its unmapped east half): look first
    if rawget(_G, "DW_WATER_CH") and M._wf.look(pawn, exit.X, exit.Y, feet) == true then
        NMm.mark_water(mem, { X = exit.X, Y = exit.Y, Z = feet })
        st.water_new = (st.water_new or 0) + 1
        return
    end
    local key = math.floor(exit.X / 200) .. ":" .. math.floor(exit.Y / 200)
    if st.wet_swim_key == key then return end
    if not st.swim_cms then
        local oks, sw = pcall(function() return pawn.CharacterMovement.MaxSwimSpeed end)
        st.swim_cms = (oks and tonumber(sw) and sw > 0) and sw or 300
    end
    -- his speed on dry ground now: encumbered he walks (~270 cm/s live 00:24Z, slower than he swims), else his run
    local run = heavy(st) and M.cfg.wet_heavy_cms or (st.sprint == false and 450 or M.cfg.wet_run_cms)
    local p = WRm.plan({ from = me, to = exit, is_water = wet, run_cms = run, swim_cms = st.swim_cms })
    if p and p.swim_m < p.straight.swim_m - 1 and p.straight.cost_s + (p.swim_m < 0.5 and M.cfg.wet_entry_s or 0) - p.cost_s >= M.cfg.wet_min_gain_s then
        st.wet = { pts = p.points, i = 1, src = src, k = exit.k, t = t }
        st.wet_detours = (st.wet_detours or 0) + 1
        if log then log(string.format("move: water: going round the water %.0f m ahead: %.0f m on dry ground instead of %.0f m with %.0f m swimming (%.1f s against %.1f s; I swim %.1f m/s)",
            enter.at_cm / 100, p.len_m, p.straight.len_m, p.straight.swim_m, p.cost_s, p.straight.cost_s, st.swim_cms / 100)) end
    else
        st.wet_swim_key = key
        if log then log(string.format("move: water: %.0f m of water %.0f m ahead; going round is no faster (%s), so across it",
            p and p.straight.swim_m or 0, enter.at_cm / 100, p and string.format("%.1f s against %.1f s", p.cost_s, p.straight.cost_s) or "no way round known")) end
    end
end
function M._steer_wet(f)
    local st, me, log = f.st, f.me, f.log
    local w = st.wet
    local i0 = w.i
    while w.pts[w.i] and d2(me, w.pts[w.i]) < 2 * M.cfg.wp_radius_cm do w.i = w.i + 1 end
    if w.i > i0 then f.idxp = true end
    if not w.pts[w.i] then
        -- past the water: the way he was on picks up there (its index at the dry spot, never back into the water)
        if w.k then
            if w.src == "trail" and st.trail_i then st.trail_i = math.max(st.trail_i, w.k)
            elseif w.src == "memory" and st.mpath then st.mwp = math.max(st.mwp or 1, w.k)
            elseif w.src == "nav" and st.path then st.wp = math.max(st.wp or 1, w.k) end
        end
        if log then log(string.format("move: water: round it in %.1f s; back on the %s way", f.t - w.t, w.src)) end
        st.wet = nil
        return
    end
    local q = w.pts[w.i]
    f.aim, f.src = { X = q.X, Y = q.Y, Z = me.Z }, "wet"
end

local function steer_route(f)
    local st, t, me = f.st, f.t, f.me
    if st.backtrack_until and t < st.backtrack_until and st.backtrack_pt then
        f.aim, f.src = st.backtrack_pt, "backtrack"
        if d2(me, st.backtrack_pt) < M.cfg.wp_radius_cm then st.backtrack_until = nil end
        return
    end
    if st.backtrack_until then st.backtrack_until, st.backtrack_pt = nil, nil end
    -- in order; a source that ran out this frame (segment done, trail caught up, memory route done) hands on to the next
    if st.lpath and steer_local(f) then return true end
    if st.lpath then return end
    if st.wet and not st.local_authority then M._steer_wet(f); if f.src == "wet" then return end end
    if st.trail_i and steer_trail(f) then return true end
    if st.trail_i then return end
    if st.mpath and steer_memory(f) then return true end
    if st.mpath then return end
    if f.path then return steer_nav(f) end
end

-- far goal for the local planner: the next waypoint of a required route; a crumb a little ahead on the trail;
-- ~6 m ahead on a remembered or oracle route (it knows the way round cliffs and hills); else the goal
local function far_goal(f)
    local st, me = f.st, f.me
    if st.wet and st.wet.pts[st.wet.i] then local q = st.wet.pts[st.wet.i]; return { X = q.X, Y = q.Y, Z = me.Z } end
    if st.nav_required and st.path and st.wp and st.wp <= #st.path then return st.path[st.wp] end
    if st.trail_i then return st.crumbs[math.min(#st.crumbs, st.trail_i + M.cfg.trail_lookahead)] end
    if st.mpath and st.mwp and st.mwp <= #st.mpath then
        local k = st.mwp
        while k < #st.mpath and d2(me, st.mpath[k]) < 600 do k = k + 1 end
        local q = st.mpath[k]
        return { X = q.X, Y = q.Y, Z = q.Z + (st.half_h or 90) }
    end
    if st.path and st.wp and st.wp <= #st.path then
        local k = st.wp
        while k < #st.path and d2(me, st.path[k]) < 600 do k = k + 1 end
        return st.path[k]
    end
    return f.goal
end

-- ------------------------------------------------------------------ re-plans, guards, input
-- prefetch: sample one not-yet-cached cell in the cone ahead every few frames (a later plan mostly hits the cache)
local function prefetch(f)
    local st, pawn, t, me, dx, dy = f.st, f.pawn, f.t, f.me, f.dx, f.dy
    if st.local_authority or not st.use_lp or st.ticks % M.cfg.prefetch_every ~= 0 then return end
    local LP = lp_module()
    if not (LP and LP.prefetch) then return end
    local cache, feet = lp_cache(), me.Z - (st.half_h or 90)
    local ctrace = st.ctrace or make_trace(st, pawn)
    st.ctrace = ctrace
    for _ = 1, 6 do
        st.cone_i = (st.cone_i or 0) % #CONE + 1
        local c = CONE[st.cone_i]
        local x = me.X + dx * c[1] * 100 - dy * c[2] * 100
        local y = me.Y + dy * c[1] * 100 + dx * c[2] * 100
        local used = LP.prefetch(cache, ctrace, x, y, feet, { cell_cm = M.cfg.lp_cell_cm, env = st.env,
            walk_z = st.env and st.env.walk_z, now = function() return t end })
        if used > 0 then st.prefetched = (st.prefetched or 0) + 1; break end
    end
end

-- local planning is allowed now: not cooling down after a failed plan, and under the plans-without-progress cap
local function may_plan(st, t)
    return t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and st.lp_plans_np < M.cfg.lp_max_plans
end

-- AVOID ZONES on the way (pure math, a few times a second): re-plan round them with the local planner (zones
-- are a cell cost there), at once when the zones changed, else at most once per avoid_plan_s; a route that
-- still crosses one (no other way) is reported in status().avoid.crossing
local function zone_replan(f)
    local st, pawn, t, me, dist, log = f.st, f.pawn, f.t, f.me, f.dist, f.log
    local zs, AZm, mfeet, src, dx, dy = f.zs, f.AZm, f.mfeet, f.src, f.dx, f.dy
    if not (AZm and #zs > 0 and t - (st.zone_chk_t or -1) >= M.cfg.avoid_check_s) then return end
    st.zone_chk_t = t
    local zc
    if st.lpath then
        zc = AZm.on_route(zs, { X = me.X, Y = me.Y, Z = mfeet }, st.lpath, st.lwp, mfeet, M.cfg.avoid_margin_cm)
    else
        local L = math.min(dist, M.cfg.lp_grid_m * 100)
        zc = AZm.on_segment(zs, me, { X = me.X + dx * L, Y = me.Y + dy * L }, mfeet, M.cfg.avoid_margin_cm)
    end
    st.zone_cross = zc and zc.id or nil
    local A = avoid()
    local replan = not st.local_authority and zc and st.use_lp and (not st.lpath or st.lp_zver ~= A.ver)
        and src ~= "avoid_exit" and src ~= "link" and src ~= "stepoff" and src ~= "bug2" and src ~= "backtrack"
        and (st.zone_plan_ver ~= A.ver or t - (st.zone_plan_t or -100) > M.cfg.avoid_plan_s) and may_plan(st, t)
    if replan then
        st.zone_plan_t, st.zone_plan_ver = t, A.ver
        st.lpath = nil
        if lp_begin(st, pawn, me, far_goal(f), "avoid_zone " .. zc.id, log) then st.status = "planning"; return true end
    end
end

-- forward wall probe (a few per second): a steep hit at knee height ahead -> plan round it; blocked at the knee
-- but clear at jump height = a low obstacle (a felled log): jump it. Water entered, or known water ahead -> re-plan.
local function probe(f)
    local st, pawn, t, me, fe, dist, log, src, dx, dy = f.st, f.pawn, f.t, f.me, f.fe, f.dist, f.log, f.src, f.dx, f.dy
    if not (st.use_lp and not st.lpath and src ~= "backtrack" and src ~= "link" and src ~= "bug2" and src ~= "stepoff"
        and t - (st.probe_t or 0) > M.cfg.probe_every_s and may_plan(st, t)) then return end
    st.probe_t = t
    local hh = st.half_h or 90
    local knee = me.Z - hh + 50
    -- start 60 cm out: from Claude's centre the ray hits his own attached gear (live 19:22)
    local a = { X = me.X + dx * 60, Y = me.Y + dy * 60, Z = knee }
    local b = { X = me.X + dx * (60 + M.cfg.probe_ahead_cm), Y = me.Y + dy * (60 + M.cfg.probe_ahead_cm), Z = knee }
    local okp, hit, out = pcall(raw_trace, pawn, a, b)
    st.traces = (st.traces or 0) + 1
    local low = false
    -- an obstacle at the goal (inside its arrival circle: the rock he walks up to mine) is no obstacle to hop or plan
    -- round (live 20:33:51Z, rung 3 mine: a hop at 1.6 m from the goal, then a 5 m slide after "arrived")
    if okp and hit and st.mode == "go_to" and 60 + (tonumber(out.Distance) or 0) >= dist - st.tol_cm then hit = false end
    if okp and hit and (out.ImpactNormal and out.ImpactNormal.Z or 0) < M.cfg.probe_wall_nz then
        local zh = me.Z - hh + jump_cm(st) - 30
        local okh, hh2 = pcall(raw_trace, pawn, { X = a.X, Y = a.Y, Z = zh }, { X = b.X, Y = b.Y, Z = zh })
        st.traces = (st.traces or 0) + 1
        if okh and not hh2 and not heavy(st) then
            low = true
            st.probe_t = t - M.cfg.probe_every_s + 0.05 -- watch it closely until we jump
            -- close enough to clear it, or held up at it: sliding along a low wall he never gets within hop range
            -- of (ghost doric 21:26:57-21:27:01Z: 4 s at 1-2 m/s beside a low wall the leader had Windstepped over)
            local close = 60 + (tonumber(out.Distance) or 999) < M.cfg.hop_dist_cm
            local slow = (h_speed(st, pawn) or 999) < 250
            if slow then st.low_slow_t = st.low_slow_t or t else st.low_slow_t = nil end
            if (close or (st.low_slow_t and t - st.low_slow_t > 0.4)) and not st.jump_t then
                st.low_slow_t = nil
                local jr = start_jump(st, t, pawn, false, log)
                if jr == "accepted" then st.hops = (st.hops or 0) + 1; if log then log(close and "move: hop over a low obstacle" or "move: hop over a low obstacle I was held up at") end elseif jr ~= "busy" then return true end
            end
        elseif src ~= "trail" and st.use_lp and lp_begin(st, pawn, me, far_goal(f), "wall_ahead", log) then
            -- (on his trail a wall ahead is a corner he walked round: the trail turns, no standing plan)
            st.status = "planning"
            return true
        end
    end
    if low then return end
    if st.water_replan then
        st.water_replan = nil
        if lp_begin(st, pawn, me, far_goal(f), "water", log) then st.status = "planning"; return true end
    end
    -- known water a few metres ahead on the way (e.g. an oracle route through shallow water)
    if not st.lpath and not st.in_water and not st.wade and dist > 1000 and not st.trail_i then
        local mem, NMm = nav_mem()
        if mem and next(mem.water or {}) then
            for _, k in ipairs({ 300, 600, 900 }) do
                local q = { X = fe.X + dx * k, Y = fe.Y + dy * k }
                if NMm.is_water(mem, q) and not water_false_mark(st, pawn, fe, q, mem, NMm, log) then
                    if t - (st.water_plan_t or -100) > 5 and lp_begin(st, pawn, me, far_goal(f), "water_ahead", log) then
                        st.water_plan_t = t
                        st.status = "planning"
                        return true
                    end
                    break
                end
            end
        end
    end
end

-- A required local route cannot use the ordinary stuck ladder (it would replace the path and could jump): hold
-- this frame, remember the stalled waypoint, and re-observe a fresh plan under the original goal (bounded).
local function local_stall(f)
    local st, gen, pc, pawn, t, me, goal = f.st, f.gen, f.pc, f.pawn, f.t, f.me, f.goal
    if not (st.local_authority and not st.lp_jump_exec and not st.ws_exec and not st.jump_t and
        st.win_t and st.win_pos and t - st.win_t >= M.cfg.stuck_window_s and d2(me, st.win_pos) < M.cfg.stuck_min_cm) then return end
    local old_binding, old_path = st.local_binding, st.lpath
    if not local_route_owned(st, gen, pawn, pc, goal) then return true end
    local p = old_path and old_path[st.lwp]
    if not p or not local_route_owned(st, gen, pawn, pc, goal) or
        st.local_binding ~= old_binding or st.lpath ~= old_path then return true end
    st.local_failed_points = st.local_failed_points or {}
    st.local_failed_points[#st.local_failed_points + 1] = { X = p.X, Y = p.Y, Z = p.Z }
    st.local_replans = (st.local_replans or 0) + 1
    st.local_authority, st.local_binding, st.lpath, st.lp, st.lp_state, st.lp_observe = nil, nil, nil, nil, nil, nil
    st.local_observe_done = st.local_replans > M.cfg.lp_max_plans
    if st.local_observe_done then st.nav_fail = "local_replan_limit" end
    st.status = "planning"
    st.win_t, st.win_pos, st.prog_t, st.prog_pos = t, v(me), t, v(me)
    return true
end

-- LETHAL DROP GUARD, on every walk (a local plan, a route, memory, the leader's trail, straight): never step off
-- a drop deeper than his safe fall (MinFallDamageHeight, 15 m). Two probes 0.7 and 1.2 m ahead (both must be
-- deep: a crack a stride wide is not a cliff edge); a hit: hold, forget the cached floor cells (a mis-sampled
-- cell made the plan), plan again up to twice, then fail with the drop named ("a 36 m drop ahead"). Live
-- 2026-11-01 15:56 (quests run, explore): a local plan led along a 63-73 degree shoulder above a 36 m cliff,
-- he slid off it and died.
local report_unreachable -- (defined with the give-up ladder below)
-- "a 36 m drop ahead" / "a drop of more than 18 m ahead" / "a slope too steep to stand on ahead, down to a 40 m drop"
function M.drop_words(st)
    if not st.drop_m then return "a drop ahead" end
    local d = st.drop_more and string.format("a drop of more than %d m", st.drop_m) or string.format("a %d m drop", st.drop_m)
    if st.drop_steep then return "a slope too steep to stand on ahead, down to " .. d end
    return d .. " ahead"
end
-- The fall hazard straight ahead along (dx, dy) from me: a drop deeper than safe_cm under both probes (0.7 and
-- 1.2 m, none past max_cm), or ground too steep to stand on (normal under walk_z, going down) that runs on into
-- such a drop within 6 m. Returns fall_cm, steep (or nil when it is safe), traces used.
local function fall_hazard(pawn, me, dx, dy, half_h, safe, walk_z, max_cm)
    local feet = me.Z - (half_h or 90)
    -- the fall from his feet to whatever is below (x, y): the floor, or deep water's surface (a swim, not a fall)
    local function fall_at(x, y)
        local ok, hit, out = pcall(raw_trace, pawn, { X = x, Y = y, Z = feet + 150 }, { X = x, Y = y, Z = feet - safe - 300 })
        if not ok then return nil end
        local fall = (hit and out.ImpactPoint) and (feet - out.ImpactPoint.Z) or (safe + 300)
        local nz = hit and out.ImpactNormal and tonumber(out.ImpactNormal.Z) or 1
        if fall > safe and rawget(_G, "DW_WATER_CH") then
            local a, b = { X = x, Y = y, Z = feet + 150 }, { X = x, Y = y, Z = feet - safe - 300 }
            local okw, hw, outw = pcall(trace_with, _G.DW_WATER_CH, pawn, a, b)
            local wz = okw and hw and type(outw) == "table" and outw.ImpactPoint and outw.ImpactPoint.Z
            if wz and (not (hit and out.ImpactPoint) or wz > out.ImpactPoint.Z + 15) then fall, nz = math.min(fall, feet - wz), 1 end
        end
        return fall, nz
    end
    local worst, steep, n, drops, traces = nil, false, 0, 0, 0
    for _, k in ipairs({ 70, 120 }) do
        if k > (max_cm or 1e9) + 40 then break end -- past the goal: he stops before it (a goal on an edge is fine)
        local fall, nz = fall_at(me.X + dx * k, me.Y + dy * k)
        if not fall then return nil, nil, traces end
        traces, n = traces + 1, n + 1
        if fall > safe then drops, worst = drops + 1, math.max(worst or 0, fall)
        elseif nz < walk_z and fall > 30 then steep = true end -- too steep to stand on, going down: he'd slide
    end
    if n == 0 or drops < n then worst = nil end -- a drop counts when every probe finds it (not a gap he steps over)
    -- a slope too steep to stand on slides him down it whatever he presses (live 2026-11-01 16:37: a 6 m walk to his
    -- grave on a cliff-top shoulder, normals 0.3-0.46, slid him off the cliff): follow it down to where it ends
    if not worst and steep then
        for _, k in ipairs({ 200, 300, 450, 600 }) do
            local fall, nz = fall_at(me.X + dx * k, me.Y + dy * k)
            if not fall then return nil, nil, traces end
            traces = traces + 1
            if fall > safe then return fall, true, traces end
            if nz >= walk_z then return nil, nil, traces end -- it levels out within a safe fall
        end
        return nil, nil, traces
    end
    return worst, false, traces
end
local function fall_limits(st, pawn)
    if not st.safe_fall_cm then -- the engine's own number (MinFallDamageHeight: below it a fall does no damage)
        local oks, sf = pcall(function() return pawn.CharacterMovement.MinFallDamageHeight end)
        st.safe_fall_cm = (oks and tonumber(sf) and tonumber(sf) > 100) and tonumber(sf) or 1500
    end
    if not st.walk_z then
        local okw, wz = pcall(function() return pawn.CharacterMovement.WalkableFloorZ end)
        st.walk_z = (okw and tonumber(wz) and tonumber(wz) > 0.3 and tonumber(wz) < 0.99) and tonumber(wz) or 0.70
    end
    return st.safe_fall_cm, st.walk_z
end
-- For other walkers (a skill's facing nudge toward a grave on an edge): the words for a lethal fall straight ahead
-- along (dx, dy) (unit, world), or nil when a step that way is safe.
function M.unsafe_ahead(pawn, dx, dy)
    local okm, me = pcall(function() return pawn:K2_GetActorLocation() end)
    local l = math.sqrt((tonumber(dx) or 0) ^ 2 + (tonumber(dy) or 0) ^ 2)
    if not (okm and me) or l < 1e-6 then return nil end
    dx, dy = dx / l, dy / l
    local lim = rawget(_G, "DW_FALL_LIMITS") or {}
    _G.DW_FALL_LIMITS = lim
    local safe, walk_z = fall_limits(lim, pawn)
    local okh, hh = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local worst, steep = fall_hazard(pawn, me, dx, dy, (okh and tonumber(hh)) or 90, safe, walk_z, nil)
    if not worst then return nil end
    local st = { drop_m = math.floor(worst / 100 + 0.5), drop_more = worst >= safe + 300, drop_steep = steep }
    return M.drop_words(st)
end
local function cliff_guard(f)
    local st, pawn, t, me, log, dx, dy = f.st, f.pawn, f.t, f.me, f.log, f.dx, f.dy
    if st.wade or st.in_water or st.jump_t or (st.ticks or 0) % 2 ~= 0 then return end
    local okg, ground = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
    if okg and ground == false then return end -- airborne (a planned jump or drop): the landing was checked
    -- a spot that killed him (navmem hazards, from skills.record_death: the last ground before a fatal fall): never
    -- step toward it within hazard_standoff_cm, whatever routes the walk (live 2026-11-01 22:10/22:11Z: interact's
    -- 2-point remembered route to his grave on a cliff lip, the look-ahead fired late or not at all, two deaths)
    local hmem, HNM = nav_mem()
    local hl = (dx and dy) and math.sqrt(dx * dx + dy * dy) or 0
    if hmem and HNM.hazard_near and hl > 0 then
        local fe = feet_of(st, me)
        local ahead = { X = fe.X + dx / hl * 100, Y = fe.Y + dy / hl * 100, Z = fe.Z }
        -- near one and walking at it: slow to a walk (no sprint, 0.3 input), because a stop at speed is followed by a
        -- 2.7-3.8 m jump forward on his client (kin trace 22:55Z: 2.66 m in 0.12 s right after a stop at 6.6 m/s; the
        -- 22:46Z lip death: 3.8 m with nothing driving him); at a walk it is a few decimetres (22:43Z)
        local okn, hn = pcall(HNM.hazard_near, hmem, fe, M.cfg.hazard_slow_cm)
        if okn and hn then
            local hcn = { X = hn.at[1] * 100, Y = hn.at[2] * 100, Z = hn.at[3] * 100 }
            if d2(ahead, hcn) < d2(fe, hcn) then
                if not st.hz_slow_t and log then log(string.format("move: hazard: slowing to a walk %.1f m from a drop that killed me %d time(s)", d2(fe, hcn) / 100, hn.n or 1)) end
                st.hz_slow_t = t
            end
        end
        local okh, h, hd = pcall(HNM.hazard_near, hmem, ahead, M.cfg.hazard_standoff_cm)
        if okh and h then
            local hc = { X = h.at[1] * 100, Y = h.at[2] * 100, Z = h.at[3] * 100 }
            if hd < d2(fe, hc) then
                local detail = string.format("I stopped %.1f m short of a drop that killed me %d time(s) at [%.1f,%.1f]%s; I don't go closer than %.0f m to it",
                    d2(fe, hc) / 100, h.n or 1, h.at[1], h.at[2], h.drop_m and string.format(" (a %d m fall)", h.drop_m) or "",
                    M.cfg.hazard_standoff_cm / 100)
                if not st.hazard_said then
                    st.hazard_said = true
                    if log then log("move: hazard: " .. detail) end
                    note(st, detail)
                end
                st.win_t, st.win_pos = t, v(me)
                if st.mode == "go_to" then
                    return stop(st, { status = "failed", reason = "unreachable", why = "known_drop", detail = detail,
                        hazard = { h.at[1], h.at[2], h.at[3] }, deaths_here = h.n or 1, dist_m = (f.dist or 0) / 100 }, log)
                end
                st.status = "holding"
                return true
            end
        end
    end
    local safe = fall_limits(st, pawn)
    local worst, steep, traces = fall_hazard(pawn, me, dx, dy, st.half_h, safe, st.walk_z, f.dist)
    st.traces = (st.traces or 0) + (traces or 0)
    st.drop_steep = steep or nil
    if not worst then return end
    st.drop_m = math.floor(worst / 100 + 0.5)
    st.drop_more = worst >= safe + 300 -- no floor within reach of the trace: "more than N m"
    st.cliff_n = (st.cliff_n or 0) + 1
    st.win_t, st.win_pos = t, v(me)
    if log then log(string.format("move: %s at (%.0f,%.0f) on %s (safe fall %d m); not stepping off",
        M.drop_words(st), me.X / 100, me.Y / 100, tostring(f.src), math.floor(safe / 100))) end
    _G.DW_LP_CACHE = nil
    st.lpath, st.lwp = nil, nil
    if st.cliff_n <= 2 and st.use_lp and t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and
        lp_begin(st, pawn, me, far_goal(f), "drop_ahead", log) then
        st.status = "planning"
        return true
    end
    st.lp_fail = M.drop_words(st)
    report_unreachable(f, "drop_ahead", nil)
    return true
end

-- KillZ guard: without an admitted route a straight walk at the raw goal never steps off a big drop (the one death
-- this rule exists for: a beeline at a goal 30 m down into a KillZVolume, DISCOVERIES). The local planner (traced
-- floor edges only) takes over; when it can't, the move fails honestly. One trace per frame: a sprint covers ~2 m
-- per probe_every_s, more than the 1.5 m look-ahead.
local function killz(f)
    local st, pawn, t, dt, me, log, src, dx, dy = f.st, f.pawn, f.t, f.dt, f.me, f.log, f.src, f.dx, f.dy
    if not ((st.nav_fallback or st.prov) and src == "straight" and not st.wade and not st.in_water) then return end
    st.traces = (st.traces or 0) + 1
    if not drop_ahead(pawn, me, me.Z - (st.half_h or 90), dx, dy, st.env and st.env.walk_z) then return end
    if st.prov then -- a drop ahead while the route is still coming: stop walking provisionally, wait for it
        st.prov, st.prov_stalled = nil, "drop_ahead"
        if log then log("move: drop ahead on the provisional walk; waiting for the route") end
        return true
    end
    st.win_t, st.win_pos = t, v(me)
    if st.prog_t then st.prog_t = st.prog_t + dt end
    if st.use_lp and st.lp_plans_np < M.cfg.lp_max_plans then
        if t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and lp_begin(st, pawn, me, far_goal(f), "drop_ahead", log) then
            st.status = "planning"
        end
        return true
    end
    local detail = "no route (" .. st.nav_fallback .. ") and a drop ahead toward the destination"
    if st.mode == "go_to" then return stop(st, { status = "failed", reason = "unreachable", detail = detail }, log) end
    st.status = "unreachable"
    return true
end

-- face where he goes (control rotation = camera yaw; the pawn orients to its movement) and push; a required
-- route must still be his to steer by
local function steer_input(f)
    local st, gen, pc, pawn, t, goal, dx, dy = f.st, f.gen, f.pc, f.pawn, f.t, f.goal, f.dx, f.dy
    local function bound()
        if not st.nav_required or st.prov then return true end
        if st.local_authority then return local_route_owned(st, gen, pawn, pc, goal) end
        return route_owned(st, gen, pawn, pc)
    end
    if not bound() then return true end
    if cam_write(st, pc, { Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }, t) == "taken" then
        if f.log then f.log(string.format("move: another skill took the camera; %s", camera_taken_by_owner(st) and
            "its own walk ends here (aiming means standing still)" or "walking on without turning it for a moment")) end
        if camera_taken_by_owner(st) then
            return stop(st, { status = "stopped", reason = "camera_taken", detail = "the skill I walk for took the camera to aim" }, f.log)
        end
    end
    if st.hold_gap then
        st.hold_gap = nil
        st.move_acc, st.bt_tested = M.cfg.self_stuck_cm, t -- holding on purpose: not wedged
        return
    end
    if not bound() then return true end
    -- the last metres of a go_to: let go of the key once his speed carries him in, the way a player stops under
    -- control (he reached a rock at 6.8 m/s and slid 5 m past it, live 20:33:51Z); slower, he pushes on again
    if st.mode == "go_to" and f.dist and not st.jump_t and not st.lpath and not st.mpath then
        local spd = h_speed(st, pawn)
        if spd and spd > 250 and f.dist - 0.6 * st.tol_cm <= spd * spd / (2 * M.cfg.brake_cms2) and ground_check(pawn) == true then
            st.status, st.coasts = "braking", (st.coasts or 0) + 1
            return
        end
    end
    local slow = st.hz_slow_t and t - st.hz_slow_t < 0.6
    if slow then
        -- a smaller input alone keeps his sprint speed (kin trace 23:01Z: 6.8 m/s held at 0.3 input): let go until he
        -- is down to a walk, then walk on at hazard_slow_input
        local spd = h_speed(st, pawn)
        if spd and spd > M.cfg.hazard_walk_cms then st.status = "slowing"; return end
    end
    pawn:AddMovementInput({ X = dx, Y = dy, Z = 0 }, slow and M.cfg.hazard_slow_input or 1.0, false)
    st.status = "moving"
end

-- sprint: far from the goal, only while making progress on the ground, never on a local path. Press-to-sprint:
-- press for up to 10 frames, then release and wait sprint_retry_s for the server's ack before pressing again.
local function sprint_tick(f)
    local st, pawn, t = f.st, f.pawn, f.t
    local lv = st.leader_cms or 0
    if st.sprint_force then st.sprint_want = true
    elseif st.mode == "follow" and st.sprint then
        -- match the leader: sprint when he runs (> 5 m/s) or the gap opens 2.5 m past the follow distance; a walk
        -- behind a 6.8 m/s sprint loses 2.3 m/s (ladder 2026-11-01: 48 m behind at the end)
        if f.dist > st.tol_cm + 250 or (lv > 500 and f.dist > st.tol_cm + 50) then st.sprint_want = true
        elseif f.dist < st.tol_cm + 50 or (lv < 300 and f.dist < st.tol_cm + 150) then st.sprint_want = false end
    elseif f.dist > M.cfg.sprint_on_cm and st.sprint then st.sprint_want = true
    elseif f.dist < M.cfg.sprint_off_cm then st.sprint_want = false end
    if st.hz_slow_t and t - st.hz_slow_t < 0.6 then st.sprint_want = false end -- walking up to a drop that killed him
    local sprinting = is_sprinting(pawn)
    if st.sprinting and not sprinting and f.log then
        -- what ends a sprint (telemetry: the follow ladder saw 31 presses in 80 s)
        local yaw = math.deg(math.atan(f.dy or 0, f.dx or 1))
        f.log(string.format("move: sprint dropped src=%s jump=%s stuck=%d turn=%.0f want=%s air=%s", tostring(f.src),
            tostring(st.jump_t ~= nil), st.stuck_n or 0, st.spr_yaw and ((yaw - st.spr_yaw + 540) % 360 - 180) or 0,
            tostring(st.sprint_want), tostring(ground_check(pawn) == false)))
    end
    st.spr_yaw = math.deg(math.atan(f.dy or 0, f.dx or 1))
    st.sprinting, f.sprinting = sprinting, sprinting
    -- a jump ends the sprint (live 14:52: 8 of 10 drops were jumps/hops, each one ~2 s at walking pace while the
    -- jump's 1.2 s bookkeeping ran out): press again 0.15 s after landing, not after the jump bookkeeping
    local jumping = st.jump_t ~= nil
    if not jumping then st.spr_land_t = nil
    elseif not st.jump_double and not st.jump_t2 and t - st.jump_t > 0.35 and ground_check(pawn) == true then
        st.spr_land_t = st.spr_land_t or t
        jumping = t - st.spr_land_t < 0.15
    end
    if not (st.sprint_want and st.stuck_n == 0 and not jumping and f.src ~= "local") or heavy(st) then return end
    if not press_to_sprint(st) then inject_sprint(st, pawn); return end
    if sprinting then st.sprint_hold = 0; return end
    st.sprint_hold = (st.sprint_hold or 0) + 1
    if st.sprint_hold <= 10 then
        if inject_sprint(st, pawn) and st.sprint_hold == 1 then st.sprint_presses = (st.sprint_presses or 0) + 1 end
    elseif st.sprint_hold == 11 then st.sprint_rel_t = t
    elseif t - st.sprint_rel_t > M.cfg.sprint_retry_s then st.sprint_hold = 0 end
end

-- ------------------------------------------------------------------ stuck, then give up
-- the point about cm back along his own trail (or its oldest), and the trail distance to it
local function trail_back(sc, cm)
    local back, acc = nil, 0
    for i = #sc - 1, 1, -1 do
        acc = acc + d2(sc[i], sc[i + 1]); back = sc[i]
        if acc >= cm then break end
    end
    return back, acc
end

-- Why he can't move at all when it is the game holding him, not the ground: a hold interaction he is pressing (a vent's
-- siphon), his movement input ignored, movement switched off (MOVE_None), or an animation's root motion. nil = none.
local function rooted_why(st, pawn, pc)
    local inv = inv_mod()
    local okh, h = pcall(function() return inv and inv.held_interaction and inv.held_interaction({ scan = true }) end)
    if okh and type(h) == "table" then
        return string.format("I'm held in place by the %s (%s is a hold: it lasts while I hold the key)", tostring(h.name or h.actor or "thing"),
            tostring(h.prompt or "its use")), h
    end
    local ok1, ign = pcall(function() return pc:IsMoveInputIgnored() end)
    if ok1 and ign == true then return "the game is ignoring my movement input right now" end
    local ok2, mode = pcall(function() return pawn.CharacterMovement.MovementMode end)
    if ok2 and tonumber(mode) == 0 then return "the game has switched my movement off" end
    local ok3, rm = pcall(function() return pawn:IsPlayingRootMotion() end)
    if ok3 and rm == true then
        local okm, m = pcall(function() local x = pawn:GetCurrentMontage(); return x and x:IsValid() and x:GetFName():ToString() or nil end)
        return "an animation" .. ((okm and m) and (" (" .. m .. ")") or "") .. " is holding me in place"
    end
end

-- stuck = moved less than stuck_min_cm in a stuck_window_s window while pushing. The ladder: step off a perch
-- (1st), a local plan (1st), else a jump (a double jump from the 2nd), a strafe (3rd+), once a backtrack (3rd).
local function stuck_tick(f)
    local st, pc, pawn, t, me, goal, dist, log = f.st, f.pc, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    if not st.win_t then st.win_t, st.win_pos = t, v(me) end
    if t - st.win_t < M.cfg.stuck_window_s then return end
    local moved = d2(me, st.win_pos)
    st.move_acc = (st.move_acc or 0) + moved
    st.speed_cms = moved / (t - st.win_t)
    if f.sprinting then st.sprint_speed_cms = st.speed_cms end
    if moved >= M.cfg.stuck_min_cm then
        st.stuck_n = 0
        st.win_t, st.win_pos = t, v(me)
        return
    end
    st.stuck_n = st.stuck_n + 1
    st.stuck_total = (st.stuck_total or 0) + 1
    local n = st.stuck_n
    local ev = string.format("move: stuck n=%d moved=%.0fcm d=%.0f src=%s me=%s aim=%s goal=%s lwp=%s/%s trail=%s/%d",
        n, moved, dist, f.src, fmt(me), fmt(f.aim), fmt(goal), tostring(st.lwp), tostring(st.lpath and #st.lpath),
        tostring(st.trail_i), #st.crumbs)
    st.last_stuck = ev
    if log then log(ev) end
    -- held by a hold interaction (a vent's siphon roots him): let go at the first stuck, not after the give-up ladder
    -- (live 20:39Z: a hold pressed without bookkeeping was found and let go only by wedged(), 8 s in)
    if n == 1 and not st.held_let_go then
        local _, held = rooted_why(st, pawn, pc)
        if held then
            st.held_let_go = true
            local inv = inv_mod()
            local okr, rr = pcall(function() return inv.release_held(log, "a walk could not move") end)
            if okr and type(rr) == "table" and rr.ok then
                note(st, string.format("I let go of the %s (holding it kept me in place)", tostring(held.name or held.actor)))
                st.win_t, st.win_pos = t, v(me)
                return
            end
        end
    end
    -- his own way out of an untrusted trap got stuck: its exit at once (not after the give-up ladder)
    -- (taken on the next frame: memory_retry is defined below)
    if st.trap_own and not st.mem_retry then st.trap_own_stuck = true; return true end
    -- pushing against a shut door ahead (his house door, the trail through it: live 18:08:33-35 he pushed 2 s, re-planned
    -- "walls everywhere", and only then opened it): open it at the first stuck
    if n == 1 and not st.door then
        local ahead = f.aim or goal
        local okd, dd = pcall(shut_door_near, me, ahead, 250)
        if okd and dd and ahead then
            local ax, ay, dx, dy = ahead.X - me.X, ahead.Y - me.Y, dd.at.X - me.X, dd.at.Y - me.Y
            local la, ld = math.sqrt(ax * ax + ay * ay), math.sqrt(dx * dx + dy * dy)
            if la > 1 and ld > 1 and (ax * dx + ay * dy) / (la * ld) > 0.3 and door_begin(st, t, log) then
                st.win_t, st.win_pos = t, v(me)
                return
            end
        end
    end
    local planned = false
    if n == 1 and not st.stepoff_tried then
        -- standing ON TOP of geometry (the floor around him is well below his feet, e.g. on the shelter,
        -- live 20:49): step off first (a jump forward, then short pushes all round)
        local feet = me.Z - (st.half_h or 90)
        local below = 0
        for k = 0, 3 do
            local ang = math.rad(k * 90 + 45)
            local px, py = me.X + math.cos(ang) * 90, me.Y + math.sin(ang) * 90
            local okf, hitf, outf = pcall(raw_trace, pawn, { X = px, Y = py, Z = feet + 60 }, { X = px, Y = py, Z = feet - 400 })
            st.traces = (st.traces or 0) + 1
            if okf and (not hitf or (outf.ImpactPoint and outf.ImpactPoint.Z < feet - 60)) then below = below + 1 end
        end
        if below >= 3 then
            local jr = start_jump(st, t, pawn, false, log)
            if jr == "accepted" then
                st.stepoff_tried = true
                st.stepoff = { i = 0, t0 = t, start = v(me), yaw0 = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)) }
                if log then log("move: perched on geometry; stepping off") end
                planned = true
            elseif jr ~= "busy" then return true end
        end
    end
    local on_trail = f.src == "trail"
    if st.use_lp and not planned and n == (on_trail and 2 or 1) and may_plan(st, t) then
        st.lpath = nil
        planned = lp_begin(st, pawn, me, far_goal(f), "stuck", log)
    end
    if not planned then
        st.env = st.env or envelope(pawn, pc)
        local jr = heavy(st) and "skipped" or start_jump(st, t, pawn, n >= 2 and st.env.double_jump, log) -- encumbered: no jumps
        if jr ~= "accepted" and jr ~= "busy" and jr ~= "skipped" then return true end
        if n >= 3 then
            st.strafe_dir = (n % 2 == 0) and 1 or -1
            st.strafe_until = t + 0.7
            if st.trail_i then st.trail_i = nearest_crumb(st.crumbs, me) end
        end
        if n == M.cfg.backtrack_after and not st.backtrack_until and not on_trail then
            local back, acc = trail_back(st.self_crumbs, M.cfg.backtrack_cm)
            if back and acc >= 100 then
                st.backtrack_pt, st.backtrack_until = back, t + M.cfg.backtrack_s
                st.backtracks = (st.backtracks or 0) + 1
                if log then log(string.format("move: backtrack %.0fcm to %s", acc, fmt(back))) end
            end
        end
    end
    st.win_t, st.win_pos = t, v(me)
end

-- Placed pieces (stations, plots, walls: BP_BaseBuilding_BaseActor_C) whose bounds touch his capsule: what he is
-- wedged against, by name (live 23:42Z: boxed in at the church base by a Spinning Wheel 1.4 m off, a bench and two
-- farm plots; every input moved 0 cm and no jump left the ground, and he could only say "path blocked")
function M._wedged_by(pawn, me)
    local okf, all = pcall(FindAllOf, "BP_BaseBuilding_BaseActor_C")
    if not (okf and type(all) == "table") then return {} end
    local okr, rad = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleRadius() end)
    rad = (okr and tonumber(rad) or 42) + 25
    local out = {}
    for _, a in ipairs(all) do
        local okl, l = pcall(function() return a:K2_GetActorLocation() end)
        if okl and l and math.abs(l.X - me.X) < 600 and math.abs(l.Y - me.Y) < 600 then
            local okb, o, e = pcall(function() local o2, e2 = {}, {}; a:GetActorBounds(true, o2, e2, false); return o2, e2 end)
            if okb and o and e and o.X and e.X and math.abs(me.X - o.X) <= e.X + rad and math.abs(me.Y - o.Y) <= e.Y + rad
                and me.Z - (o.Z + e.Z) < 120 and (o.Z - e.Z) - me.Z < 120 then
                local okn, n = pcall(function() return a:GetFullName() end)
                local cls = okn and n and n:match("([%w_]+)_C_%d+$") or "piece"
                local name = cls:gsub("^BP_", ""):gsub("^Station_", ""):gsub("^Crafting_", ""):gsub("^T%d_", ""):gsub("_New$", ""):gsub("_%d+$", "")
                    :gsub("(%l)(%u)", "%1 %2"):gsub("_", " ")
                out[#out + 1] = { name = name, at = { X = l.X, Y = l.Y, Z = l.Z }, d_m = math.floor(d2(me, l) / 10 + 0.5) / 10 }
            end
        end
    end
    table.sort(out, function(x, y) return x.d_m < y.d_m end)
    return out
end

-- he cannot move at all (wedged): ask a nearby player to lead him out (a go_to waits for the lead), else "stuck"
local function wedged(f, at)
    local st, pawn, t, me, goal, dist, log = f.st, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    if log then log("move: self-stuck (moved " .. math.floor(st.move_acc or 0) .. " cm in " .. M.cfg.give_up_s .. " s). " .. tostring(st.last_stuck)) end
    -- the game holding him is no trap of the ground (no nav memory mark): let go of a held interaction once and walk
    -- on, else say what holds him
    local rwhy, held = rooted_why(st, pawn, f.pc)
    if rwhy then
        if log then log("move: rooted: " .. rwhy) end
        if held and not st.held_let_go then
            st.held_let_go = true
            local inv = inv_mod()
            local okr, rr = pcall(function() return inv.release_held(log, "a walk could not move") end)
            if okr and type(rr) == "table" and rr.ok then
                note(st, string.format("I let go of the %s (holding it kept me in place)", tostring(held.name or held.actor)))
                st.bt_tested, st.bt_pos, st.move_acc = nil, nil, 0
                st.prog_t, st.prog_pos, st.win_t, st.win_pos = t, v(me), t, v(me)
                return true
            end
        end
        return stop(st, { status = "failed", reason = "rooted", why = rwhy, detail = rwhy, dist_m = dist / 100, at_m = at }, log)
    end
    mark_trap(st, me)
    local okw, by = pcall(M._wedged_by, pawn, me)
    local wedge_detail
    if okw and type(by) == "table" and #by > 0 then
        local names = {}
        for i = 1, math.min(3, #by) do names[#names + 1] = string.format("the %s (%.1f m)", by[i].name, by[i].d_m) end
        wedge_detail = string.format("I'm wedged in among placed things: %s; I can't walk or jump out%s", table.concat(names, ", "),
            (st.trip_notes and table.concat(st.trip_notes, " "):find("never left the ground", 1, true)) and " (my jumps never left the ground)" or "")
        if log then log("move: wedged: " .. wedge_detail) end
        -- once: walk out the open side, away from what holds him (the sum of directions from each piece to him)
        if not st.wedge_out_tried then
            st.wedge_out_tried = true
            local ax, ay = 0, 0
            for _, w in ipairs(by) do
                local dx, dy = me.X - w.at.X, me.Y - w.at.Y
                local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
                ax, ay = ax + dx / l, ay + dy / l
            end
            local l = math.sqrt(ax * ax + ay * ay)
            if l > 0.1 then
                st.backtrack_pt, st.backtrack_until = { X = me.X + ax / l * 150, Y = me.Y + ay / l * 150, Z = me.Z }, t + 1.5
                st.bt_tested, st.bt_pos, st.move_acc = nil, nil, 0
                st.prog_t, st.prog_pos, st.win_t, st.win_pos = t, v(me), t, v(me)
                if log then log(string.format("move: wedged: walking out away from them, toward %s", fmt(st.backtrack_pt))) end
                return true
            end
        end
    end
    local hname, hpawn = nearest_player(pawn, me, M.cfg.help_player_cm)
    if not st.asked_help then
        st.asked_help = true
        pcall(emit_move_event, "stuck", { ask = "lead_me", helper = hname, reason = "wedged", my_pos = me, leader_pos = goal,
            where = string.format("at (%.0f, %.0f, %.0f)", me.X / 100, me.Y / 100, me.Z / 100) })
    end
    if st.mode == "follow" then
        st.unreach = { reason = "wedged", since = t, check_t = t, leader_pos = v(goal), my_pos = v(me), detail = "can't move" }
        st.status = "unreachable"
        return true
    end
    if hname and hpawn and not st.lead_done then return wait_for_lead(st, hname, hpawn, me, t, "wedged", wedge_detail or "can't move") end
    return stop(st, { status = "failed", reason = "stuck", dist_m = dist / 100, at_m = at, why = wedge_detail and "wedged_by_pieces" or nil,
        detail = wedge_detail, wedged_by = wedge_detail and by or nil }, log)
end

-- he can move but not get closer: a remembered route (one that reaches the goal, a trap's exit, or any)
local function memory_retry(f)
    local st, t, me, goal, log = f.st, f.t, f.me, f.goal, f.log
    local mem, NMm = nav_mem()
    if not mem then return end
    local okt, trap = pcall(NMm.trap_at, mem, feet_of(st, me))
    local pts = st.mode == "go_to" and mem_goal_plan(st, me, goal) or nil
    if pts then trap = nil
    else pts = okt and trap and NMm.trap_exit(trap) or nil end
    if not pts then
        local okp, pp = pcall(NMm.plan, mem, feet_of(st, me), feet_of(st, goal), { max_factor = 3 })
        pts = okp and pp or nil
    end
    if not pts then return end
    st.mpath, st.mwp, st.msrc = pts, 1, okt and trap and ("trap:" .. tostring(trap.id)) or "memory"
    if okt and trap then st.trap_exit_taken = true end
    restart_progress(st, t, me)
    st.lpath, st.trail_i = nil, nil
    if log then log("move: memory: retrying via " .. st.msrc) end
    return true
end

-- Nothing left to try: the most specific TRUE reason (needs:<Move> from a known link, the leader's Windstep or
-- double jump, a height that was out of jump reach from the start, else no_route). A nearby player is asked to
-- lead (once per episode); a follow stays persistent (unreachable), a go_to waits for the lead or fails.
report_unreachable = function(f, needs, at)
    local st, pawn, t, me, goal, dist, log = f.st, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    local reason
    if heavy(st) then reason = "encumbered"                     -- over his carry weight: no jumps, the true cause
    elseif needs then reason = needs                            -- e.g. "needs:DoubleJump" (a known link needs a move he lacks)
    elseif st.leader_superjump_t and t - st.leader_superjump_t < 30 then reason = "leader_windstepped"
    elseif st.leader_dj_t and t - st.leader_dj_t < 30 and not (st.env and st.env.double_jump) then reason = "leader_double_jumped"
    else
        -- the height gap counts only if the goal was ALREADY out of jump reach at the start; a gap he made by
        -- dropping down during the escape (live 07:05: Bug2 walked him off a ledge) is not the cause, the walls
        -- that blocked the way on his level are
        local jump_reach = jump_cm(st) + 60
        local high_now = goal.Z - me.Z > jump_reach
        local high_at_start = st.dz0 and st.dz0 > jump_reach
        local who = (st.target_kind == "player") and "leader" or "target"
        if high_now and (high_at_start or st.dz0 == nil) then reason = who .. "_above_jump_height"
        else reason = "no_route" end
    end
    local walls = (st.lp_fail == "verify_exhausted") and " blocked by walls" or ""
    local detail = string.format("dz=%.1fm d=%.1fm lp_fail=%s%s%s", (goal.Z - me.Z) / 100, dist / 100, tostring(st.lp_fail), walls,
        (st.dz0 and math.abs((goal.Z - me.Z) - st.dz0) > 150) and string.format(" (height gap was %.1fm at start)", st.dz0 / 100) or "")
    if log then log("move: unreachable: " .. reason .. " " .. detail) end
    -- a trap candidate only when walls kept him from a goal some way off: a goal above his reach, a leader's move
    -- he lacks, his load, or a goal he is already beside (on or in an object) say nothing about being shut in
    local confined = reason == "no_route" and dist > 300
    local hname, hpawn = nearest_player(pawn, me, M.cfg.help_player_cm)
    if hname and not st.asked_help then
        local mem, NMm = nav_mem()
        local okt, trap = false, nil
        if mem then okt, trap = pcall(NMm.trap_at, mem, feet_of(st, me)) end
        local where = (okt and trap and (trap.name or trap.id)) or string.format("at (%.0f, %.0f, %.0f)", me.X / 100, me.Y / 100, me.Z / 100)
        st.asked_help = true
        pcall(emit_move_event, "stuck", { ask = "lead_me", where = where, helper = hname, reason = reason, my_pos = me, detail = detail })
        if log then log("move: asking " .. hname .. " to lead me (" .. where .. ")") end
    end
    if st.mode == "follow" then
        st.unreach = { reason = reason, since = t, check_t = t, leader_pos = v(goal), my_pos = v(me), detail = detail }
        st.unreach_episodes = (st.unreach_episodes or 0) + 1
        pcall(emit_move_event, "unreachable", { reason = reason, leader_pos = goal, my_pos = me, detail = detail, mode = "follow" })
        if confined then mark_trap(st, me) end
        st.status = "unreachable"
        return true
    end
    pcall(emit_move_event, "unreachable", { reason = reason, leader_pos = goal, my_pos = me, detail = detail, mode = "go_to" })
    if confined then mark_trap(st, me) end
    if hname and hpawn and not st.lead_done then return wait_for_lead(st, hname, hpawn, me, t, reason, detail) end
    return stop(st, { status = "failed", reason = "unreachable", why = reason, detail = detail, dist_m = dist / 100, at_m = at }, log)
end

-- Bounded give-up: no net progress toward the goal (progress_cm, or a route index advanced) for give_up_s. Then:
-- already there -> arrived; could not move at all (not even backwards, tested once) -> wedged; else, once each, a
-- remembered route, Bug2 wall-following, a learned link; then the truthful unreachable reason.
local function give_up(f)
    local st, pawn, t, me, goal, dist, log = f.st, f.pawn, f.t, f.me, f.goal, f.dist, f.log
    if not st.prog_t then st.prog_t, st.prog_pos = t, v(me) end
    local gx, gy = goal.X - st.prog_pos.X, goal.Y - st.prog_pos.Y
    local gl = math.max(math.sqrt(gx * gx + gy * gy), 1)
    local toward = ((me.X - st.prog_pos.X) * gx + (me.Y - st.prog_pos.Y) * gy) / gl
    -- DETOUR BUDGET (go_to): a waypoint reached counts as progress only while he got progress_cm closer to the goal
    -- within detour_s. Local plans are re-made each time, so their indices advance forever in a loop (live 2026-11-01
    -- 14:23-14:26: memory route -> wall -> local plan away -> memory route back to the same wall, 3 min, never gave up;
    -- co-play B5 "walking into a rock edge for over a minute"). The oracle's route is one global plan: exempt.
    if not st.best_d or dist < st.best_d - M.cfg.progress_cm then st.best_d, st.best_t = dist, t end
    local detour_ok = f.idxp and (st.mode ~= "go_to" or f.src == "nav" or t - st.best_t < M.cfg.detour_s)
    if f.idxp and not detour_ok and not st.detour_spent then
        st.detour_spent = true
        if log then log(string.format("move: no closer to the goal in %.0f s (best %.0f m, now %.0f m; src=%s): detour budget spent",
            t - st.best_t, st.best_d / 100, dist / 100, tostring(f.src))) end
        note(st, string.format("I went round in circles for %.0f s without getting closer", t - st.best_t))
    end
    if toward >= M.cfg.progress_cm or detour_ok then
        st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.bt_pos = t, v(me), 0, nil, nil
        if toward >= M.cfg.progress_cm then st.lp_plans_np = 0 end
        return
    end
    if t - st.prog_t <= M.cfg.give_up_s then return end
    if st.prov then -- no progress on the provisional walk: stand and wait for the route (as before), no escape ladder
        st.prov, st.prov_stalled = nil, "no_progress"
        if log then log("move: no progress on the provisional walk; waiting for the route") end
        return
    end
    -- no progress because he is already there (a local-plan jump kept the arrival check off: chat run 8,
    -- on top of the Water Anima Vent, 0 m left, 1.2 m up of 1.76 allowed -> "no_route")
    if st.mode == "go_to" and reached(st, me, goal) and standing_check(pawn) == true then
        st.lp_jump_exec, st.ws_exec = nil, nil
        return stop(st, { status = "arrived", dist_m = dist / 100, s = t - st.t0 }, log)
    end
    local at = { math.floor(me.X) / 100, math.floor(me.Y) / 100, math.floor(me.Z) / 100 }
    if (st.move_acc or 0) < M.cfg.self_stuck_cm then
        if not st.bt_tested then
            -- before calling himself wedged, try to move back the way he came (2.5 s)
            local back = trail_back(st.self_crumbs, M.cfg.backtrack_cm)
            st.bt_tested, st.bt_pos = t, v(me)
            if back then st.backtrack_pt, st.backtrack_until = back, t + 2.5 end
            st.prog_t = t - M.cfg.give_up_s + 2.5
            if log then log("move: no movement; backtrack test before declaring self-stuck") end
            return true
        end
        if st.bt_pos ~= nil and d2(me, st.bt_pos) < 50 then return wedged(f, at) end
    end
    if not st.mem_retry then
        st.mem_retry = true
        if memory_retry(f) then return true end
    end
    if not st.bug_tried and st.use_lp and not (st.in_water or st.wade) then -- (no wall-following in water: 22:12Z circles)
        st.bug_tried = true
        st.bug = { s = v(me), hit_d = dist, t0 = t, travel = 0, dir = 1, switched = false,
            yaw = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)) + 35 }
        restart_progress(st, t, me)
        st.lpath, st.trail_i, st.mpath = nil, nil, nil
        if log then log("move: bug2 wall-following from " .. fmt(me)) end
        return true
    end
    -- a learned traversal link toward the goal (or what a known link needs that he lacks: the reason)
    local TL, needs = tl_module(), nil
    if TL and (st.link_tries or 0) < M.cfg.link_max_tries then
        local m = function(q) return { q.X / 100, q.Y / 100, q.Z / 100 } end
        local okb, link, info = pcall(TL.best_link, m(me), m(goal), { env = { double_jump = st.env and st.env.double_jump or false,
            air_dash = false, windstep = false }, max_detour = 3 })
        if okb and link then
            st.link_tries = (st.link_tries or 0) + 1
            st.link_exec = { link = link, phase = "approach", t0 = t }
            restart_progress(st, t, me)
            if log then log(string.format("move: trying learned link %s (%s, cost %.1fm)", tostring(link.id), tostring(link.move), tonumber(link.cost_m) or -1)) end
            return true
        elseif okb and type(info) == "string" and info:sub(1, 6) == "needs:" then
            needs = info
        end
    end
    return report_unreachable(f, needs, at)
end

local function tick(st, gen, log)
    if st.gen ~= gen then return "stale" end -- (the loop skips the whole frame while the world is paused)
    local pc = st.pc
    if not (pc and pc:IsValid()) then return finish(st, { status = "failed", reason = "verification_failed", detail = "controller unavailable" }, log) end
    local pawn = pc.Pawn
    if not is_character(pawn) then return finish(st, { status = "failed", reason = "verification_failed", detail = "player character unavailable" }, log) end
    local alive, life_reason, life_detail = life_check(st, pawn)
    if not alive then return finish(st, { status = "failed", reason = life_reason, detail = life_detail }, log) end
    local t = now(pawn)
    local dt = st.last_t and (t - st.last_t) or 0
    st.last_t = t
    local me = pawn:K2_GetActorLocation()
    st.ticks = st.ticks + 1
    if not st.enc_t or t - st.enc_t > 2 or t < st.enc_t then st.enc_t, st.enc = t, encumbrance(pawn) end
    if st.ws_exec and (st.lpath ~= st.ws_exec.path or st.lwp ~= st.ws_exec.index
        or not st.lpath or st.lpath[st.lwp] ~= st.ws_exec.endpoint or st.lpath[st.lwp].act ~= "superjump") then
        return finish(st, { status = "failed", reason = "windstep_interrupted", detail = "planned traversal changed before landing" }, log)
    end
    local f = { st = st, gen = gen, log = log, pc = pc, pawn = pawn, t = t, dt = dt, me = me }
    if jump_tick(f) or track_goal(f) then return end
    local goal = f.goal
    local dist = d2(me, goal)
    f.dist, st.dist_cm = dist, dist
    if st.dz0 == nil then st.dz0 = goal.Z - me.Z; st.original_goal_xy = dist end
    if st.timeout_auto then
        -- PLAN fix 1: a long trip gets time to finish: max(120, 3 x distance / 4.5 m/s), capped under the bridge's
        -- 290 s (live 19:08: 128 m of steady progress was answered "timeout" at 120 s)
        st.timeout_auto = nil
        st.timeout_s = math.min(M.cfg.deadline_cap_s, math.max(st.timeout_s, 3 * (dist + math.abs(goal.Z - me.Z)) / 450))
    end
    trip_tick(f)
    -- a goal over his head with nothing up there to stand on is answered before any route is asked for (live 19:25Z:
    -- the oracle took 17 s to say "invalid_route" for a spot 1 m beside him and 2.6 m up, and he stood all that time)
    if st.mode == "go_to" and dist <= st.tol_cm and goal.Z - me.Z > 2 * (st.half_h or 88) and not st.ws_exec
        and not st.lp_jump_exec and not st.jump_t and overhead(f, true) ~= nil then return end
    if route_tick(f) then return end
    -- "near" for the tracker: within tolerance, or a follow idling (incl. holding at a zone's edge)
    f.same_level = type(goal.Z) == "number" and type(me.Z) == "number" and math.abs(goal.Z - me.Z) <= 2 * st.half_h
    progress_tick(st, t, me, goal, dist, (dist <= st.tol_cm and f.same_level) or (st.mode == "follow" and st.idle == true and f.same_level))
    zone_tick(f)
    if leader_far(f) or arrival(f) or unreachable_hold(f) then return end
    f.fe = feet_of(st, me)
    record_trails(f)
    trap_tick(f)
    water_tick(f)
    if lead_tick(f) then return end
    memory_once(f)
    -- the local planner owns the frame while it samples/verifies: stand still, pause the progress clock
    if st.lp_state and lp_work(st, t, log) then
        st.status = "planning"
        if st.prog_t then st.prog_t = st.prog_t + dt end
        st.win_t, st.win_pos = t, v(me)
        return
    end
    if st.door and door_step(f) then return end
    f.path = st.path
    trail_entry(f)
    pcall(M._wet_tick, f)
    f.aim, f.src, f.idxp = goal, "straight", false
    if st.link_exec and steer_link(f) then return end
    if st.stepoff then steer_stepoff(f) end
    if not st.stepoff and st.bug and not st.link_exec then steer_bug2(f) end
    if not st.stepoff and not st.bug and not st.link_exec and steer_route(f) then return end
    if f.zone_in and st.zone_exit and not st.escape then f.aim, f.src, f.idxp = st.zone_exit, "avoid_exit", true end
    local aim, src = f.aim, f.src
    if st.local_authority and src ~= "local" then route_fallback(st, "local route unavailable", log) end
    if st.nav_required and src == "straight" and not st.prov then route_fallback(st, "route ended before destination", log) end
    st.source, st.aim = src, aim
    local dx, dy = aim.X - me.X, aim.Y - me.Y
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 1 and st.local_authority then route_fallback(st, "local endpoint did not reach goal", log) end
    if dl < 1 then dx, dy, dl = goal.X - me.X, goal.Y - me.Y, math.max(dist, 1) end
    dx, dy = dx / dl, dy / dl
    if st.strafe_until and t < st.strafe_until then
        dx, dy = dx * 0.3 + st.strafe_dir * -dy, dy * 0.3 + st.strafe_dir * dx
    end
    f.dx, f.dy = dx, dy
    prefetch(f)
    if zone_replan(f) or probe(f) or local_stall(f) or cliff_guard(f) or killz(f) or steer_input(f) then return end
    sprint_tick(f)
    -- an owned airborne or landing transaction must not enter the ordinary stuck ladder
    if st.local_authority and (st.lp_jump_exec or st.ws_exec or st.jump_t) then
        st.win_t, st.win_pos = t, v(me)
        return
    end
    if st.trap_own_stuck then
        st.trap_own_stuck, st.mem_retry = nil, true
        if log then log("move: memory: my own way out of trap " .. tostring(st.trap_own) .. " got stuck: its exit now") end
        st.trap_own = nil
        if memory_retry(f) then st.win_t, st.win_pos = t, v(me); return end
    end
    if stuck_tick(f) or give_up(f) then return end
    if log and t - (st.log_t or 0) > M.cfg.log_every_s then
        st.log_t = t
        log(string.format("move: %s d=%.0fcm src=%s lwp=%s/%s trail=%s/%d spr=%s spd=%.0f traces=%d", st.mode, dist, src,
            tostring(st.lwp), tostring(st.lpath and #st.lpath), tostring(st.trail_i), #st.crumbs, tostring(f.sprinting),
            st.speed_cms or 0, st.traces or 0))
    end
end

local function start(log, mode, opts)
    if paused() then return { ok = false, error = "paused (world changing)" } end
    local st = S()
    local old_gen, old_token, old_mode = st.gen, st.owner_token, st.mode
    local function death_seq()
        local life=rawget(_G,"DW_LIFE")
        return type(life)=="table" and (life.move_death_seq or 0) or 0
    end
    local start_life_seq=death_seq()
    local raw_arb = rawget(_G,"DWArbiter")
    local old_owner = type(raw_arb)=="table" and raw_arb.owner or nil
    local old_owner_token = old_owner and old_owner.token
    local function unchanged()
        return not paused() and death_seq()==start_life_seq and rawget(_G,"DW_MOVE")==st and st.gen==old_gen and st.owner_token==old_token
            and st.mode==old_mode and rawget(_G,"DWArbiter")==raw_arb
            and (type(raw_arb)~="table" or raw_arb.owner==old_owner)
            and (not old_owner or old_owner.token==old_owner_token)
    end
    local arb = move_arbiter()
    if not unchanged() then return {ok=false,reason="interrupted"} end
    if opts.owner_token then
        -- A resumed implicit record is intentionally owner while its old move is
        -- idle; housekeeping would otherwise discard it before restore starts.
        local restoring_implicit = old_mode=="idle" and old_owner and old_owner.implicit == true and
            old_owner.state=="owner" and old_owner.uses_move~=false and old_owner.token==opts.owner_token
        if not restoring_implicit and not (arb and arb.owns_move and arb.owns_move(opts.owner_token)) then
            return {ok=false,reason="interrupted",detail="movement ownership unavailable"}
        end
        if not unchanged() then return {ok=false,reason="interrupted",detail="movement ownership changed"} end
    elseif old_owner and not (old_owner.implicit and st.owner_implicit and old_owner.token==old_token) then
        -- say WHO holds the pawn (live 10-30: "movement owner token required" was really the eat reflex)
        local lvl = ({ "idle", "task", "command", "reflex" })[old_owner.level] or tostring(old_owner.level)
        local age = old_owner.since and math.max(0, os.time() - old_owner.since) or nil
        local left = old_owner.lease_s and old_owner.since and math.max(0, old_owner.lease_s - (os.time() - (old_owner.renewed or old_owner.since))) or nil
        return {ok=false,reason="busy",owner=tostring(old_owner.name),
            detail=string.format("busy: %s (%s) is using my legs%s%s", tostring(old_owner.name), lvl,
                age and string.format(", for %d s", age) or "", left and string.format(", lease ends in %d s", left) or "")}
    end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not is_character(pawn) then return { ok = false, error = "no player character (main menu / loading?)" } end
    local alive, life_reason, life_detail = life_check({}, pawn)
    if not alive then return { ok = false, reason = life_reason, detail = life_detail } end
    local okh, half_height = pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if not okh or type(half_height) ~= "number" or half_height ~= half_height or half_height <= 0 or half_height == math.huge then
        return { ok = false, reason = "verification_failed", detail = "character capsule height unavailable" }
    end
    local g = opts.goal
    if type(g) == "table" and not g.actor and (type(g[1]) ~= "number" or type(g[2]) ~= "number" or type(g[3]) ~= "number") then
        return { ok = false, reason = "invalid_args", detail = "destination needs x, y and z" }
    end
    local start_world=world_identity()
    if opts.owner_token and not start_world then return {ok=false,reason="verification_failed",detail="movement world unavailable"} end
    local function oldsafe()
        local current_world=world_identity()
        local ok,current=pcall(function() return pc.Pawn end)
        local living=ok and current==pawn and life_check({},pawn)
        return current_world==start_world and living==true and death_seq()==start_life_seq and unchanged()
    end
    if not oldsafe() then return {ok=false,reason="interrupted"} end
    cancel_superjump(st) -- callbacks may replace the mover
    if not oldsafe() then return {ok=false,reason="interrupted"} end
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    if not oldsafe() then return {ok=false,reason="interrupted"} end
    if st.mode ~= "idle" then pcall(mem_flush, st, log, "interrupted") end
    if not oldsafe() then return {ok=false,reason="interrupted"} end
    local inherited_token
    if st.owner_implicit and st.owner_token and not opts.owner_token then
        local a = move_arbiter()
        if a and a.replace_implicit then inherited_token = a.replace_implicit(st.owner_token) end
    end
    if inherited_token then
        local current_world=world_identity()
        local ok,current=pcall(function() return pc.Pawn end)
        if current_world~=start_world or not ok or current~=pawn or paused() or death_seq()~=start_life_seq or rawget(_G,"DW_MOVE")~=st or st.gen~=old_gen or st.owner_token~=old_token or st.mode~=old_mode or
            rawget(_G,"DWArbiter")~=raw_arb or not old_owner or raw_arb.owner~=old_owner or old_owner.token~=inherited_token then
            return {ok=false,reason="interrupted"}
        end
    elseif not oldsafe() then return {ok=false,reason="interrupted"} end
    if not inherited_token then
        local had_implicit = st.owner_implicit and st.owner_token ~= nil
        release_implicit(st, log)
        if had_implicit then
            -- release may resume another owner; never replace it.
            local current_world=world_identity()
            local ok,current=pcall(function() return pc.Pawn end)
            if current_world~=start_world or not ok or current~=pawn or paused() or death_seq()~=start_life_seq or rawget(_G,"DW_MOVE")~=st or st.gen~=old_gen or st.mode~=old_mode or
                rawget(_G,"DWArbiter")~=raw_arb or (raw_arb and raw_arb.owner~=nil) then return {ok=false,reason="interrupted"} end
        elseif not oldsafe() then return {ok=false,reason="interrupted"} end
    end
    local gen = st.gen + 1
    local keep = { gen = gen, nav_id = st.nav_id, eis = st.eis, pts = st.pts }
    for k in pairs(st) do st[k] = nil end
    for k, x in pairs(keep) do st[k] = x end
    st.mode, st.pc, st.ticks, st.stuck_n = mode, pc, 0, 0
    st.pawn = pawn
    st.owner_world = start_world
    st.life_seq = start_life_seq
    local provisional={};st.start_guard=provisional
    local candidate, implicit
    local function abort_start()
        local raw=rawget(_G,"DWArbiter");local owner=type(raw)=="table" and raw.owner
        if rawget(_G,"DW_MOVE")==st and st.gen==gen and st.mode==mode and st.start_guard==provisional and
            st.pc==pc and st.pawn==pawn and st.handle==nil and (st.owner_token==nil or st.owner_token==candidate) then
            st.mode="idle";st.owner_token=nil;st.owner_implicit=nil;st.start_guard=nil
            st.result={status="failed",reason="interrupted",detail="movement ownership unavailable"}
            if not paused() and implicit and candidate and owner and owner.token==candidate then
                local old=move_arbiter();if old and old.release_implicit then pcall(old.release_implicit,log,candidate) end
            end
        end
        return {ok=false,reason="interrupted",detail="movement ownership unavailable"}
    end
    -- this start still holds st: no pause, death, newer command or mode change
    local function fresh()
        return not paused() and death_seq()==start_life_seq and rawget(_G,"DW_MOVE")==st and st.gen==gen and st.mode==mode
    end
    -- the same world and living pawn (read in this order: world, pawn, life)
    local function same_body()
        local w=world_identity()
        local ok,cur=pcall(function() return pc.Pawn end)
        local alive=ok and cur==pawn and life_check(st,pawn)
        return w==start_world and alive
    end
    local a = move_arbiter()
    if not fresh() then return abort_start() end
    if inherited_token then
        candidate, implicit = inherited_token, true
    elseif a and opts.owner_token and a.owns_move then
        local owns = a.owns_move(opts.owner_token)
        if not fresh() then return abort_start() end
        if owns then
            local owner = a.owner and a.owner()
            if not fresh() then return abort_start() end
            candidate, implicit = opts.owner_token, owner and owner.implicit == true or false
        end
    elseif a and not opts.owner_token and a.adopt_move then
        candidate = a.adopt_move(log)
        if not fresh() then return abort_start() end
        implicit = candidate ~= nil
    end
    local body_ok=same_body()
    local admitted_arb=rawget(_G,"DWArbiter")
    local admitted_owner=type(admitted_arb)=="table" and admitted_arb.owner
    if not (fresh() and body_ok and candidate and admitted_owner and admitted_owner.token==candidate and admitted_owner.uses_move~=false) then
        return abort_start()
    end
    -- ... and the owner admitted here still owns the move
    local function admitted() return rawget(_G,"DWArbiter")==admitted_arb and admitted_arb.owner==admitted_owner end
    local function still_ours()
        local body=same_body()
        return fresh() and body and st.start_guard==provisional and admitted()
    end
    st.owner_token, st.owner_implicit = candidate, implicit
    st.crumbs, st.self_crumbs, st.lp_plans_np, st.trail_jumped, st.nav_jumped = {}, {}, 0, {}, {}
    st.below_ok, st.ovh, st.cam, st.jump_fail = nil, nil, nil, nil
    st.half_h = half_height
    st.t0 = now(pawn)
    if not (fresh() and admitted()) then return abort_start() end
    st.tol_cm = (opts.tolerance_m or 1.5) * 100
    st.cmd_id = opts.cmd_id -- the bridge command this move serves (trips.jsonl "id")
    local rt = type(opts.resume_trip) == "table" and opts.resume_trip or nil
    if rt and type(rt.rec) == "table" then
        -- resumed after an arbiter suspend (a fight): the trip goes on, so its sentence covers the whole walk
        st.trip_rec, st.trip_notes = rt.rec, {}
        for i, n in ipairs(rt.notes or {}) do st.trip_notes[i] = n end
        st.trip_notes[#st.trip_notes + 1] = string.format("paused %d s while %s had my legs",
            math.max(0, os.time() - (rt.at or os.time())), tostring(rt.by or "a reflex"))
    end
    opts.resume_trip = nil
    -- he can't walk while holding a hold interaction (an Anima Vent's siphon roots him): let go first, as a player
    -- lets go of E before walking off (live 2026-11-01 19:20Z: the siphon was never let go; every walk stood still)
    local inv0 = inv_mod()
    local okh, h0 = pcall(function() return inv0 and inv0.held_interaction and inv0.held_interaction() end)
    if okh and type(h0) == "table" then
        local okr, rr = pcall(inv0.release_held, log, "a walk starts")
        if okr and type(rr) == "table" and rr.ok then
            st.trip_notes = st.trip_notes or {}
            st.trip_notes[#st.trip_notes + 1] = string.format("I let go of the %s first (holding it kept me in place)", tostring(h0.name or h0.actor))
        end
    end
    st.timeout_s = opts.timeout_s or 120
    st.timeout_auto = opts.timeout_s == nil -- grows with the trip on the first tick (tick)
    st.sprint = opts.sprint ~= false
    st.use_nav = opts.nav
    st.use_lp = opts.local_plan ~= false and M.cfg.lp_enabled
    if opts.sprint_m then M.cfg.sprint_on_cm = opts.sprint_m * 100; M.cfg.sprint_off_cm = math.min(M.cfg.sprint_off_cm, opts.sprint_m * 50) end
    st.face_when_near = opts.face_when_near
    st.sprint_force = opts.sprint_force == true
    st.wade = opts.wade == true -- the goal is IN water on purpose (a pond to use): water avoidance off for this move
    -- an optional trip (explore legs) takes no planned drop deeper than this (live 2026-11-01 11:18: a planned 4.8 m
    -- drop landed on a mis-sampled floor and he fell 29 m into a KillZ)
    st.max_drop_cm = tonumber(opts.max_drop_m) and tonumber(opts.max_drop_m) * 100 or nil
    st.escape = type(opts.escape) == "table" and opts.escape or nil
    st.prog_tr = progress_new(opts.progress)

    if type(g) == "table" and not g.actor then
        st.goal = { X = g[1] * 100, Y = g[2] * 100, Z = g[3] * 100 }
    else
        st.target, st.target_kind = resolve_target(g, pawn)
        -- a stand-in leader (the movement ladder's ghost_leader.lua) is followed like a player: crumbs, jumps
        if opts.as_player and st.target then st.target_kind = "player" end
        local okn, n = pcall(function() return st.target and st.target:GetFullName():match("([%w_]+)$") end)
        st.target_name = type(g) == "string" and g or (okn and n) or "actor"
        st.target_spec = type(g) == "string" and g or st.target_name
    end
    -- replayable args (snapshot/restore): goal as metres or a name/id string, never a UObject
    local oc = {}
    for k, x in pairs(opts) do if k ~= "goal" and type(x) ~= "userdata" and type(x) ~= "table" then oc[k] = x end end
    if type(opts.progress) == "table" then
        local pc2 = {}
        for k, x in pairs(opts.progress) do
            if type(x) == "number" then pc2[k] = x
            elseif k == "to" and type(x) == "table" then pc2.to = { tonumber(x[1]), tonumber(x[2]), tonumber(x[3]) } end
        end
        oc.progress = pc2
    end
    st.args = { mode = mode, goal = st.goal and { g[1], g[2], g[3] } or st.target_spec,
                distance_m = mode == "follow" and opts.tolerance_m or nil, opts = oc }
    if not still_ours() then return abort_start() end
    local handle = LoopInGameThreadWithDelay(1, function()
        if paused() then
            if st.gen == gen and st.local_binding then
                st.local_authority, st.local_binding, st.lpath, st.lp, st.lp_state, st.lp_observe = nil,nil,nil,nil,nil,nil
                st.local_observe_done, st.lp_jump_exec, st.jump_double = true,nil,false
            end
            return
        end
        local ok, err = pcall(tick, st, gen, log)
        if not ok then
            if log then log("move: tick error " .. tostring(err)) end
            if st.gen == gen then finish(st, { status = "failed", reason = "error", detail = tostring(err) }, log) end
        end
    end)
    if not still_ours() then
        if handle then pcall(CancelDelayedAction,handle) end
        return abort_start()
    end
    st.handle=handle;st.start_guard=nil
    local on_map = type(st.target) == "table" and st.target.dw_map
    local mp_at = on_map and st.target:K2_GetActorLocation() or nil
    if mp_at and log then log(string.format("move: %s %s is out of sight; going by his marker on the game map at (%.0f,%.0f,%.0f)",
        mode, tostring(st.target.name), mp_at.X, mp_at.Y, mp_at.Z)) end
    return { ok = true, mode = mode, gen = gen, target_visible = st.target ~= nil or st.goal ~= nil,
             target_via = on_map and "map" or (st.target and "sight") or nil,
             target_position = mp_at and { math.floor(mp_at.X) / 100, math.floor(mp_at.Y) / 100, math.floor(mp_at.Z) / 100 } or nil }
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

function M.stop(log, context)
    local st = rawget(_G,"DW_MOVE")
    if context ~= nil and st == nil then return {ok=false,reason="interrupted"} end
    st = st or S()
    local was = st.mode
    local arb=rawget(_G,"DWArbiter")
    local function context_valid()
        if context == nil then return true end
        local rec=context.record
        if context.expected_generation ~= nil then
            local world=world_identity()
            return world and world==st.owner_world and not paused() and rawget(_G,"DW_MOVE")==st and
                arb and rawget(_G,"DWArbiter")==arb and rec and arb.owner==rec and rec.token==context.token and
                context.token==st.owner_token and st.gen==context.expected_generation and rec.state=="owner"
        end
        return arb and rawget(_G,"DWArbiter")==arb and arb.move_stop_context==context and rec and
            context.token==rec.token and rec.token==st.owner_token and (rec.state=="stopped" or rec.state=="suspended")
    end
    if not context_valid() then return {ok=false,was=was,reason="interrupted"} end
    if was == "idle" then return {ok=true,was=was} end
    local b=binding(st,st.pawn)
    local allow_nil=context ~= nil and context.expected_generation == nil and context_valid()
    if not same_binding(b,allow_nil) then
        local arb=rawget(_G,"DWArbiter"); local owner=arb and arb.owner
        local ok, current_pawn=false,nil
        if not paused() then ok,current_pawn=pcall(function() return b.pc.Pawn end) end
        if ok and current_pawn==b.pawn and not paused() and rawget(_G,"DW_MOVE")==st and st.gen==b.gen and st.owner_token==b.token and b.token and
            st.pawn==b.pawn and st.pc==b.pc and arb and rawget(_G,"DWArbiter")==arb and arb.owner==owner and context_valid() and (owner and owner.token==b.token or not owner and allow_nil) then
            st.gen=st.gen+1
            finish(st,{status="failed",reason="verification_failed",detail="jump release unconfirmed"},log)
            return {ok=false,was=was,reason="verification_failed"}
        end
        return {ok=false,was=was,reason="interrupted"}
    end
    if not context_valid() then return {ok=false,was=was,reason="interrupted"} end
    local ok=pcall(function() b.pawn:StopJumping() end)
    if not context_valid() or not same_binding(b,allow_nil) then return {ok=false,was=was,reason="interrupted"} end
    st.gen = st.gen + 1
    finish(st, ok and { status = "stopped" } or {status="failed",reason="verification_failed",detail="jump release unconfirmed"}, log)
    if context and context.expected_generation ~= nil and (rawget(_G,"DW_MOVE")~=st or st.gen~=b.gen+1 or st.mode~="idle" or rawget(_G,"DWArbiter")~=arb or arb.owner~=context.record) then
        return {ok=false,was=was,reason="interrupted"}
    end
    return { ok=ok, was=was, reason=not ok and "verification_failed" or nil }
end

-- Interaction episodes may finish only the exact move generation they started.
function M.child_status(log, generation, token)
    local st=rawget(_G,"DW_MOVE");local arb=rawget(_G,"DWArbiter")
    local owner=type(arb)=="table" and arb.owner
    if paused() or type(generation)~="number" or not st or not token then return {ok=false,reason="interrupted"} end
    if st.gen~=generation then
        local same_parent_active=st.mode~="idle" and st.owner_token==token and owner and owner.token==token
        return {ok=true,mode="superseded",gen=st.gen,same_parent_active=same_parent_active==true}
    end
    if st.owner_token~=token or not owner or owner.token~=token or owner.state~="owner" then
        return {ok=false,reason="interrupted"}
    end
    local b=binding(st,st.pawn)
    local world=world_identity()
    if not world or world~=st.owner_world or paused() or rawget(_G,"DW_MOVE")~=st or st.gen~=generation or
        rawget(_G,"DWArbiter")~=arb or arb.owner~=owner then return {ok=false,reason="interrupted"} end
    if st.mode=="idle" then
        local ok,pawn=pcall(function() return b.pc.Pawn end)
        local alive=ok and pawn==b.pawn and life_check(st,pawn)
        local again,current=pcall(function() return b.pc.Pawn end)
        local world_again=world_identity()
        if world_again~=world or not alive or not again or current~=b.pawn or paused() or rawget(_G,"DW_MOVE")~=st or st.gen~=generation or st.life_seq~=b.life or
            rawget(_G,"DWArbiter")~=arb or arb.owner~=owner then return {ok=false,reason="interrupted"} end
        return {ok=true,mode="idle",gen=generation}
    end
    if not owned(b) then return {ok=false,reason="interrupted"} end
    local world_again=world_identity()
    if world_again~=world or paused() or rawget(_G,"DW_MOVE")~=st or st.gen~=generation or
        st.owner_token~=token or rawget(_G,"DWArbiter")~=arb or arb.owner~=owner then return {ok=false,reason="interrupted"} end
    return {ok=true,mode=st.mode,gen=generation}
end
function M.stop_owned(log, generation, token)
    local check=M.child_status(log,generation,token)
    if not check.ok then return check end
    if check.mode=="idle" or check.mode=="superseded" then return {ok=true,was=check.mode,same_parent_active=check.same_parent_active} end
    local arb=rawget(_G,"DWArbiter");local rec=arb and arb.owner
    return M.stop(log,{expected_generation=generation,token=token,record=rec})
end

-- The game's own Unstuck, through the UI a player uses: open the pause menu
-- (MainMenuUIAPI:NavigateToScreen(12 = EMainSubMenuType Pause)), complete the held Unstuck button
-- (UDomHeldProgressBarButton:HandleHeldActionCompleted, what IA_UnstuckCharacter_Held's 3 s hold
-- ends in), then Resume(). It teleports Claude to the start point (Server_TeleportToPlayerStart on
-- the game's side). Asynchronous: the result lands in _G.DW_UNSTUCK. No move calls it any more: as the
-- wedged rung it crashed the client (live 20:49:34, UE4SS push_arrayproperty access violation right
-- after the teleport); a wedged move reports "stuck" and asks a nearby player to lead instead.
function M.unstuck(log)
    local api = FindFirstOf("MainMenuUIAPI")
    if not (api and api:IsValid()) then return { ok = false, error = "no MainMenuUIAPI" } end
    -- every game-thread loop must stay out while the pawn is teleported (crash 20:49:34)
    local set_pause = rawget(_G, "DW_PAUSE") ~= true
    if set_pause then _G.DW_PAUSE = true end
    local ok, err = pcall(function() api:NavigateToScreen(12) end)
    if not ok then
        if set_pause then _G.DW_PAUSE = nil end
        return { ok = false, error = "NavigateToScreen: " .. tostring(err) }
    end
    if set_pause then
        ExecuteInGameThreadWithDelay(4000, function() if rawget(_G, "DW_UNSTUCK_PAUSE") then _G.DW_PAUSE = nil; _G.DW_UNSTUCK_PAUSE = nil end end)
        _G.DW_UNSTUCK_PAUSE = true
    end
    _G.DW_UNSTUCK = { state = "menu_requested" }
    if log then log("move: unstuck requested (pause menu)") end
    -- game-thread delays only (UE4SS async-thread race; DISCOVERIES "Dev server crash 2026-11-02")
    ExecuteInGameThreadWithDelay(700, function()
        if paused() and not rawget(_G, "DW_UNSTUCK_PAUSE") then return end
        local r = _G.DW_UNSTUCK
        local scr
        for _, w in ipairs(FindAllOf("PauseMenuScreen") or {}) do
            local n = w:GetFullName()
            if w:IsValid() and not n:find("Default__") then scr = w end
        end
        if not scr then r.state = "no_pause_screen"; if log then log("move: unstuck failed: no pause screen") end; return end
        local okb, eb = pcall(function() scr.ProgressButton_Unstuck:HandleHeldActionCompleted() end)
        r.state = okb and "completed" or ("button_error " .. tostring(eb))
        pcall(function() scr:Resume() end)
        if log then log("move: unstuck " .. r.state) end
    end)
    return { ok = true }
end

-- After a respawn/rejoin: if Claude stands in a known trap (e.g. the church start pit), walk its
-- recorded exit. Returns go_to's reply, or {ok=false, error="not_in_trap"}.
function M.escape_trap(log, opts)
    if paused() then return { ok = false, error = "paused (world changing)" } end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local mem, NMm = nav_mem()
    if not mem then return { ok = false, error = "no navmem" } end
    local hh = half_h(pawn)
    local me = pawn:K2_GetActorLocation()
    local trap = NMm.trap_at(mem, { X = me.X, Y = me.Y, Z = me.Z - hh })
    if not trap then return { ok = false, error = "not_in_trap" } end
    local ex = NMm.trap_exit(trap)
    if not ex then return { ok = false, error = "trap has no exit", trap = trap.id } end
    local last = ex[#ex]
    local r = M.go_to(log, { last.X / 100, last.Y / 100, (last.Z + hh) / 100 }, opts or { tolerance_m = 1.5 })
    r.trap = trap.id
    return r
end

function M.snapshot()
    local st = S()
    if st.mode == "idle" or not st.args then return nil end
    local a = st.args
    local opts = {}
    for k, x in pairs(a.opts) do opts[k] = x end
    -- the trip so far, so a resumed move keeps one record (restore -> start(opts.resume_trip))
    opts.resume_trip = st.trip_rec and { rec = st.trip_rec, notes = st.trip_notes, at = os.time() } or nil
    local life = rawget(_G, "DW_LIFE")
    opts.life_seq = type(life) == "table" and (life.move_death_seq or 0) or 0 -- restore refuses across a death
    return { mode = a.mode, goal = a.goal, distance_m = a.distance_m, opts = opts }
end

function M.restore(log, snap)
    if type(snap) ~= "table" or not snap.mode then return { ok = false, error = "no snapshot" } end
    local opts = {}
    for k, x in pairs(snap.opts or {}) do opts[k] = x end
    -- a move suspended for a fight he then lost is over: never walk on from the respawn point (live 22:08, a Giant Rat
    -- killed him mid-go_to and the arbiter resumed it from the church, 368 m from the goal)
    local life = rawget(_G, "DW_LIFE")
    local seq = type(life) == "table" and (life.move_death_seq or 0) or 0
    if opts.life_seq ~= nil and opts.life_seq ~= seq then
        local st = S()
        local by = type(life) == "table" and life.killed_by or nil
        local rt = type(opts.resume_trip) == "table" and opts.resume_trip.rec or nil
        st.result = { status = "failed", reason = "companion_down",
            detail = "I died before I got there" .. (by and (" (killed by " .. tostring(by) .. ")") or "")
                .. (type(life) == "table" and life.fell_m and string.format(", after a %.0f m fall", life.fell_m) or ""),
            dist_m = rt and rt.dist and rt.dist / 100 or nil }
        st.result.why = st.result.detail
        if log then log("move: restore refused: " .. st.result.detail) end
        return { ok = false, reason = "companion_down", detail = st.result.detail }
    end
    opts.life_seq = nil
    local by = type(opts.resume_trip) == "table" and opts.resume_trip.by or nil
    local r
    if snap.mode == "follow" then r = M.follow(log, snap.goal, snap.distance_m or opts.tolerance_m or 3, opts)
    else r = M.go_to(log, snap.goal, opts) end
    -- tell the brain the walk goes on (live 21:57:35Z: follow resumed after a reflex fight, nobody said so, and the
    -- model called follow again 2.7 s later)
    if type(r) == "table" and r.ok ~= false then
        pcall(emit_move_event, "move_resumed", { mode = snap.mode, by = by and tostring(by) or nil,
            target = type(snap.goal) == "string" and snap.goal or nil })
    end
    return r
end

local function m3(p) return p and { math.floor(p.X) / 100, math.floor(p.Y) / 100, math.floor(p.Z) / 100 } or nil end

function M.status()
    local st = S()
    return {
        mode = st.mode, status = st.status, result = st.result, target = st.target_name,
        jump_observation = st.jump_observation,
        dist_m = st.dist_cm and math.floor(st.dist_cm) / 100, source = st.source,
        lwp = st.lwp, n_lwp = st.lpath and #st.lpath, lp_state = st.lp_state, lp_runs = st.lp_runs,
        lp_fail = st.lp_fail, lp_why = st.lp_why, traces = st.traces, env = st.env,
        nav_live = st.nav_live, nav_requests = st.nav_requests,
        link_exec = st.link_exec and { id = st.link_exec.link.id, move = st.link_exec.link.move, phase = st.link_exec.phase } or nil,
        link_tries = st.link_tries, link_ok = st.link_ok,
        link_jumps = st.link_jumps, trail_jumps = st.trail_jumps, backtracks = st.backtracks, trail_i = st.trail_i, crumbs = st.crumbs and #st.crumbs, trail_entries = st.trail_entries,
        sprinting = st.sprinting, sprint_route = st.sprint_route, sprint_err = st.sprint_err, sprint_presses = st.sprint_presses,
        sprint_speed_ms = st.sprint_speed_cms and math.floor(st.sprint_speed_cms) / 100,
        press_to_sprint = st.pts, speed_ms = st.speed_cms and math.floor(st.speed_cms) / 100,
        stuck_n = st.stuck_n, stuck_total = st.stuck_total, jumps = st.jumps, double_jumps = st.double_jumps,
        last_stuck = st.last_stuck, ticks = st.ticks, self_edges = st.self_edges,
        prefetched = st.prefetched, lp_stand_s = st.lp_stand_s, unstuck = _G.DW_UNSTUCK,
        hops = st.hops, water_entries = st.water_entries, in_water = st.in_water, water_detours = st.wet_detours, trace_profile = PROFILE_NAME or (rawget(_G, "DW_TRACE_PROFILE") and _G.DW_TRACE_PROFILE.name),
        bug2 = st.bug and { dir = st.bug.dir, travel_m = math.floor(st.bug.travel) / 100 } or nil,
        lead = st.lead and { helper = st.lead.name, phase = st.lead.phase or "waiting" } or nil,
        memory = st.mpath and { src = st.msrc, wp = st.mwp, n = #st.mpath } or nil, trip_pts = st.trip and #st.trip,
        unreachable = st.unreach and { reason = st.unreach.reason, detail = st.unreach.detail,
            leader_pos = m3(st.unreach.leader_pos), my_pos = m3(st.unreach.my_pos) } or nil,
        unreach_episodes = st.unreach_episodes,
        aim = m3(st.aim), target_pos = m3(st.target_pos), target_kind = st.target_kind,
        target_via = st.target_via, -- "sight" (his pawn) | "map" (his game-map marker: out of net relevancy)
        avoid = M.avoid_status(st),
        progress = progress_view(st),
        escape = st.escape and { zone = st.escape.zone, eta_s = st.escape.eta_s, at = st.escape.at } or nil,
    }
end

-- Restart the progress window of the running move (e.g. combat: a hit landed, or the boss is airborne
-- so "not closer" means nothing). opts may replace the parameters ({stall_s, gain_m, budget_s, moving_m, to}).
function M.progress_reset(log, opts)
    local st = S()
    if st.mode == "idle" then return { ok = false, error = "no move running" } end
    local P = st.prog_tr
    if opts ~= nil or not P then st.prog_tr = progress_new(opts or (st.args and st.args.opts and st.args.opts.progress)); P = st.prog_tr
    else P.best, P.best_t, P.best_tpos, P.elapsed = nil, nil, nil, 0 end
    P.last_t = nil -- the next frame starts a fresh window
    return { ok = true }
end

-- ONE table of truthful words for every movement reason (move's own reasons, the tracker's verdict
-- whys, escape answers). `thing` = who/what he can't reach: "you" (the leader), "the Kebbit", "it".
-- Returns a clause for "I can't get to <thing>: <clause>."
local PLURAL = false -- set per call: "the sticks are", "they keep"
local function be(thing)
    if thing == "you" then return "you're" end
    if thing == "it" then return "it's" end
    if thing == "they" then return "they're" end
    return thing .. (PLURAL and " are" or " is")
end
local WHY = {
    windstep_owner_lost = function() return "I lost control of movement while using Windstep" end,
    windstep_not_grounded = function() return "I couldn't confirm that I was on the ground before using Windstep" end,
    windstep_unavailable = function() return "Windstep isn't available for that jump" end,
    windstep_interrupted = function() return "the planned Windstep jump was interrupted" end,
    windstep_cast_failed = function() return "the Windstep cast failed" end,
    windstep_cast_timeout = function() return "the Windstep cast didn't finish in time" end,
    windstep_landing_missed = function() return "I landed away from the planned Windstep landing" end,
    windstep_landing_timeout = function() return "I couldn't confirm a landing after the Windstep jump" end,
    not_enough_resources = function() return "I don't have enough runes to cast Windstep" end,
    on_cooldown = function() return "Windstep is still on cooldown" end,
    not_unlocked = function() return "I haven't unlocked Windstep" end,
    not_on_wheel = function() return "Windstep isn't available on my spell wheel" end,
    no_route = function(th) return "there's no way through to " .. th .. " from here" end,
    drop_ahead = function()
        return "there's " .. M.drop_words(rawget(_G, "DW_MOVE") or {}) .. ", more than I can fall safely, and no other way down"
    end,
    target_above_jump_height = function(th) return be(th) .. " higher up than I can jump" end,
    leader_above_jump_height = function(th) return be(th) .. " higher up than I can jump" end,
    leader_windstepped = function(th) return (th == "you" and "you" or th) .. " Windstepped over somewhere I can't follow yet" end,
    leader_double_jumped = function(th) return (th == "you" and "you" or th) .. " double-jumped somewhere I can't follow yet" end,
    leader_far = function(th) return be(th) .. " too far away (a teleport?); I'd need a lodestone to catch up" end,
    target_not_visible = function(th) return "I can't see " .. (th == "you" and "you" or th) .. " any more" end,
    wedged = function() return "I'm wedged and can't move" end,
    encumbered = function()
        local e = (rawget(_G, "DW_MOVE") or {}).enc
        local w = (e and e.cur and e.max) and string.format(" (%.0f of %.0f weight)", e.cur, e.max) or ""
        return "I'm carrying too much" .. w .. ", so I can only walk slowly and can't jump until I drop or store some"
    end,
    stuck = function() return "I keep getting stuck on the way" end,
    blocked = function() return "something is in the way (I keep bumping into it)" end,
    no_progress = function() return "I'm not getting any closer" end,
    cant_catch = function(th) return ((th == "you" or th == "they" or PLURAL) and (th .. " keep") or (th .. " keeps")) .. " moving away faster than I can catch up" end,
    too_long = function() return "it's taking far too long to get there" end,
    timeout = function() return "it's taking far too long to get there" end,
    unreachable = function() return "I can't find a way there" end,
    no_safe_point = function() return "there's nowhere safe to stand nearby" end,
    too_slow = function() return "I can't get out of the way in time" end,
    paused = function() return "the world is still loading" end,
    no_shore = function() return "I can't find the water's edge from here" end,
    no_water_sense = function() return "I can't tell where the water starts from here" end,
}
-- plural = true for things named in the plural ("the sticks are higher up ...").
function M.why_words(why, thing, plural)
    thing = (type(thing) == "string" and thing ~= "") and thing or "it"
    why = tostring(why or "")
    local f = WHY[why]
    if f then
        PLURAL = plural == true
        local ok, w = pcall(f, thing)
        PLURAL = false
        if ok then return w end
    end
    local mv = why:match("^needs:(%w+)")
    if mv then return "I'd need " .. mv:gsub("(%l)(%u)", "%1 %2") .. " to get there, and I can't do that yet" end
    return "I can't find a way there"
end
M.WHY_KEYS = {}
for k in pairs(WHY) do M.WHY_KEYS[#M.WHY_KEYS + 1] = k end
table.sort(M.WHY_KEYS)

-- ------------------------------------------------------------------ avoid zones (velgar.md 3c)
local function zone_sig(zs)
    local p = {}
    for _, z in ipairs(zs) do
        p[#p + 1] = string.format("%s:%s:%.0f:%.0f:%.0f:%.0f:%.2f:%.2f", z.id, z.kind, z.X / 10, z.Y / 10, (z.Z or 0) / 10, z.r / 10, z.yaw or 0, z.half or 0)
    end
    return table.concat(p, "|")
end

-- Replace the avoid zones (no merge); [] clears. The version (which triggers re-planning) changes only
-- when the set or a zone's geometry changes, so re-sending the same zones every frame costs nothing.
function M.set_avoid_zones(log, zones)
    local AZm = az_module()
    if not AZm then return { ok = false, error = "avoidzones.lua missing" } end
    local t = nil
    if not paused() then pcall(function() local pc = local_pc(); if pc and pc.Pawn and pc.Pawn:IsValid() then t = now(pc.Pawn) end end) end
    local zs, err = AZm.normalize(zones or {}, t)
    if not zs then
        if log then log("move: set_avoid_zones refused: " .. tostring(err)) end
        return { ok = false, error = err }
    end
    if t then AZm.prune(zs, t) end
    local A = avoid()
    local sig = zone_sig(zs)
    if sig ~= A.sig then
        A.ver, A.sig = A.ver + 1, sig
        if log then
            local ids = {}
            for _, z in ipairs(zs) do ids[#ids + 1] = string.format("%s(%s r=%.1fm)", z.id, z.kind, z.r / 100) end
            log("move: avoid zones v" .. A.ver .. ": " .. (#ids > 0 and table.concat(ids, " ") or "cleared"))
        end
    end
    A.zones = zs
    return { ok = true, zones = #zs, ver = A.ver }
end

function M.avoid_status(st)
    st = st or S()
    local A = avoid()
    local AZm = az_module()
    local inside = st.mode ~= "idle" and st.zone_in or nil
    if not paused() then pcall(function() -- no engine calls during world teardown (crash 18:08)
        local pc = local_pc()
        local pawn = pc and pc.Pawn
        if not (AZm and pawn and pawn:IsValid()) then return end
        AZm.prune(A.zones, now(pawn))
        if st.mode == "idle" and #A.zones > 0 then
            local me = pawn:K2_GetActorLocation()
            local z = AZm.at(A.zones, me.X, me.Y, me.Z - half_h(pawn), M.cfg.avoid_margin_cm)
            inside = z and z.id or nil
        end
    end) end
    return { zones = #A.zones, inside = inside, crossing = (st.mode ~= "idle" and #A.zones > 0) and st.zone_cross or nil }
end

-- ------------------------------------------------------------------ the water's edge (ponds, rivers)
-- A water volume's actor origin is deep inside it (live 2026-10-26 16:08: a pond's origin 3.1 m under the
-- surface). The game's interact target reads the water only from AT its edge: live 2026-10-26 18:3x, from the
-- dry bank point nothing was targeted; ~3-4 m nearer, feet at the waterline, one press gave +1 Dirty Water.
-- M.shore_point finds that edge with real traces: along rays out from the water point (first toward Claude,
-- then rotated), the last wet sample before dry ground is the waterline. Claude stands THERE (feet in the
-- shallows, depth <= shallow_cm; a steep bank: right at the dry edge) and faces a surface point 1.5 m further out.
-- Wet = a water-surface channel (Visibility / Camera; the calibrated one first) hits 15-250 cm above the
-- Player-profile floor (that profile passes through water); without any, navmem's waded cells. A spot where
-- a collect actually WORKED (M.remember_water_spot) wins over the traces.
--   M.shore_point(log, water = {x,y,z} m | nil, opts = {from = {x,y,z} m, max_m = 30, rays = 5})
--     -> {ok, stand = {x,y,z} (capsule centre, m), edge = {x,y,z} (surface point to face, m), bank = {x,y,z},
--         depth_cm, dist_m, alts = {{stand, edge}, ...}, how = "learned"|"channel"|"memory"}
--      | {ok = false, why = "no_water_sense" | "no_shore" | "no_pawn" | "paused"}
--   M.remember_water_spot(log, water = {x,y,z} m, stand = {x,y,z} m) -> {ok, n}: a spot where it worked.
-- Walk to `stand` with go_to opts.wade = true (water avoidance off for that move).
M.cfg.shore_shallow_cm = 60   -- stand in water no deeper than this (else at the dry edge)
M.cfg.shore_face_cm = 150     -- face a surface point this far out from where he stands
M.cfg.water_spot_m = 40       -- a learned spot counts for a water point within this

local SURFACE_CH = { { ch = 0, name = "vis" }, { ch = 1, name = "cam" } }

function M.remember_water_spot(log, water, stand)
    if type(stand) ~= "table" or not tonumber(stand[1]) then return { ok = false, error = "stand {x,y,z} m needed" } end
    local mem, NMm = nav_mem()
    if not (mem and NMm.add_water_spot) then return { ok = false, error = "no navmem" } end
    local w = (type(water) == "table" and tonumber(water[1])) and { X = water[1] * 100, Y = water[2] * 100, Z = (tonumber(water[3]) or stand[3]) * 100 } or nil
    local n = NMm.add_water_spot(mem, w, { X = stand[1] * 100, Y = stand[2] * 100, Z = (tonumber(stand[3]) or 0) * 100 })
    pcall(NMm.save, mem)
    if log then log(string.format("move: water spot remembered at (%.1f, %.1f, %.1f) m (%d known)", stand[1], stand[2], tonumber(stand[3]) or 0, n)) end
    return { ok = true, n = n }
end

function M.shore_point(log, water, opts)
    opts = opts or {}
    if paused() then return { ok = false, why = "paused" } end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not is_character(pawn) then return { ok = false, why = "no_pawn" } end
    local hh = half_h(pawn)
    local me = pawn:K2_GetActorLocation()
    local from = (type(opts.from) == "table" and tonumber(opts.from[1])) and { X = opts.from[1] * 100, Y = opts.from[2] * 100, Z = (opts.from[3] or me.Z / 100) * 100 } or v(me)
    local W = (type(water) == "table" and tonumber(water[1])) and { X = water[1] * 100, Y = water[2] * 100, Z = (tonumber(water[3]) or from.Z / 100) * 100 } or nil
    local function m(p) return { math.floor(p.X) / 100, math.floor(p.Y) / 100, math.floor(p.Z) / 100 } end
    local mem, NMm = nav_mem()
    -- 1. a spot where collecting this water WORKED before
    if mem and NMm.water_spot_near then
        local ws = NMm.water_spot_near(mem, W or from, M.cfg.water_spot_m * 100)
        if ws then
            local s = ws.stand
            local tw = ws.water or W
            local edge = { X = s.X, Y = s.Y, Z = s.Z - hh }
            if tw then
                local dx, dy = tw.X - s.X, tw.Y - s.Y
                local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
                edge = { X = s.X + dx / l * M.cfg.shore_face_cm, Y = s.Y + dy / l * M.cfg.shore_face_cm, Z = s.Z - hh + 30 }
            end
            if log then log(string.format("move: shore point (learned) %s, worked %d times", fmt(s), ws.n_ok or 1)) end
            return { ok = true, stand = m(s), edge = m(edge), bank = m(s), alts = {}, how = "learned", depth_cm = nil,
                     dist_m = math.floor(d2(from, s)) / 100, n_ok = ws.n_ok }
        end
    end
    -- 2. traces
    local chans = {}
    local cal = rawget(_G, "DW_WATER_CH")
    if cal and cal.ch then chans[1] = cal end
    for _, c in ipairs(SURFACE_CH) do if not (cal and cal.ch == c.ch) then chans[#chans + 1] = c end end
    local has_mem = mem and next(mem.water or {}) ~= nil
    local zref = from.Z - hh
    local traces, cap = 0, opts.max_traces or 400
    -- -> wet (bool) | nil (out of budget), floor_z, surface_z
    local function probe(x, y)
        if traces >= cap then return nil end
        traces = traces + 1
        local okf, hf, of = pcall(raw_trace, pawn, { X = x, Y = y, Z = zref + 400 }, { X = x, Y = y, Z = zref - 1200 })
        local fz = (okf and hf and of.ImpactPoint) and of.ImpactPoint.Z or nil
        if not fz then return false, nil, nil end
        local sz = nil
        for _, c in ipairs(chans) do
            traces = traces + 1
            local oks, hs, os_ = pcall(trace_with, c, pawn, { X = x, Y = y, Z = fz + 400 }, { X = x, Y = y, Z = fz - 50 })
            local z = (oks and hs and os_.ImpactPoint) and os_.ImpactPoint.Z or nil
            if z and z > fz + 15 and z < fz + 250 and (not sz or z < sz) then sz = z end
        end
        if sz then return true, fz, sz end
        if has_mem and NMm.is_water(mem, { X = x, Y = y }) then return true, fz, fz + 50 end
        return false, fz, nil
    end
    local function at(ox, oy, dx, dy, s) return ox + dx * s, oy + dy * s end
    local function ray(ox, oy, dx, dy, maxd)
        -- out from a wet origin: coarse 1 m steps to the first dry sample, then 25 cm refinement
        local last_wet, s = nil, 0
        while s <= maxd do
            local x, y = at(ox, oy, dx, dy, s)
            local wet, fz, sz = probe(x, y)
            if wet == nil then return nil end
            if wet then last_wet = { X = x, Y = y, Z = sz, F = fz, s = s }
            elseif last_wet and fz then
                local lo, hi = last_wet.s, s
                local edge, dry = last_wet, { X = x, Y = y, Z = fz, s = s }
                for _ = 1, 2 do
                    local mid = (lo + hi) / 2
                    local mx, my = at(ox, oy, dx, dy, mid)
                    local w2, f2, s2 = probe(mx, my)
                    if w2 == nil then break end
                    if w2 then lo, edge = mid, { X = mx, Y = my, Z = s2, F = f2, s = mid }
                    elseif f2 then hi, dry = mid, { X = mx, Y = my, Z = f2, s = mid } end
                end
                local depth = edge.Z - edge.F
                -- stand at the waterline: in the shallows, or (a steep bank) on the dry edge 25 cm from it
                local stand
                if depth <= M.cfg.shore_shallow_cm then stand = { X = edge.X, Y = edge.Y, Z = edge.F + hh }
                else
                    local sx, sy = at(ox, oy, dx, dy, dry.s + 25)
                    local _, f3 = probe(sx, sy)
                    stand = { X = sx, Y = sy, Z = (f3 or dry.Z) + hh }
                end
                -- face the surface a little further out (toward the origin)
                local fs = math.max(0, edge.s - M.cfg.shore_face_cm)
                local fx, fy = at(ox, oy, dx, dy, fs)
                local bx, by = at(ox, oy, dx, dy, dry.s + 40)
                return { stand = stand, edge = { X = fx, Y = fy, Z = edge.Z }, bank = { X = bx, Y = by, Z = dry.Z + hh },
                         depth = math.floor(depth) }
            end
            s = s + 100
        end
        return nil
    end
    -- the water point: given (over water), or the first wet sample walking from Claude toward it
    local base = W
    if base then
        local wet = probe(base.X, base.Y)
        if not wet then
            local L = d2(from, base)
            local hit = nil
            for s = 0, L, 100 do
                local f = s / math.max(L, 1)
                local x, y = from.X + (base.X - from.X) * f, from.Y + (base.Y - from.Y) * f
                if probe(x, y) then hit = { X = x, Y = y }; break end
            end
            base = hit
        end
    end
    if not base then
        if #chans == 0 and not has_mem then return { ok = false, why = "no_water_sense", traces = traces } end
        if log then log(string.format("move: shore point: no water found (%d traces)", traces)) end
        return { ok = false, why = "no_shore", traces = traces }
    end
    local bx, by = from.X - base.X, from.Y - base.Y
    local yaw0 = math.sqrt(bx * bx + by * by) > 1 and math.atan(by, bx) or 0
    local maxd = (opts.max_m or 30) * 100
    local found = {}
    local offs = { 0, 30, -30, 60, -60, 90, -90, 180 }
    for k = 1, math.min(opts.rays or 5, #offs) do
        local a = yaw0 + math.rad(offs[k])
        local r = ray(base.X, base.Y, math.cos(a), math.sin(a), maxd)
        if r then found[#found + 1] = r end
    end
    if #found == 0 then
        if log then log(string.format("move: shore point: no edge found (%d traces)", traces)) end
        return { ok = false, why = "no_shore", traces = traces }
    end
    local best = found[1]
    local alts = {}
    for k = 2, #found do alts[#alts + 1] = { stand = m(found[k].stand), edge = m(found[k].edge) } end
    if log then log(string.format("move: shore point %s (depth %dcm, face %s), %d alternatives, %d traces", fmt(best.stand), best.depth, fmt(best.edge), #alts, traces)) end
    return { ok = true, stand = m(best.stand), edge = m(best.edge), bank = m(best.bank), depth_cm = best.depth,
             dist_m = math.floor(d2(from, best.stand)) / 100, alts = alts, how = "channel", traces = traces }
end

-- "Get me out now": nearest point outside every zone (inside the bound) whose straight walk is clear;
-- walks there at once (sprinting when it matters). Never moves when the answer is not ok.
function M.escape_zones(log, opts)
    opts = opts or {}
    if paused() then return { ok = false, why = "no_route", error = "paused (world changing)" } end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not is_character(pawn) then return { ok = false, why = "no_route", error = "no player character" } end
    local t = now(pawn)
    local zs, AZm = live_zones(t)
    if not AZm then return { ok = false, why = "no_route", error = "avoidzones.lua missing" } end
    local hh = half_h(pawn)
    local me = pawn:K2_GetActorLocation()
    local feet = me.Z - hh
    local mg = M.cfg.avoid_margin_cm
    local zin = AZm.at(zs, me.X, me.Y, feet, mg)
    if not zin then return { ok = true, at = m3(me), eta_s = 0, already_safe = true } end
    local bound = nil
    local b = opts.bound
    if type(b) == "table" then
        local bx, by, br = tonumber(b.x or b[1]), tonumber(b.y or b[2]), tonumber(b.r_cm or b[4])
        if bx and by and br then bound = { X = bx * 100, Y = by * 100, r = br } end
    end
    local ex = AZm.exits(zs, me, feet, { margin = mg + M.cfg.escape_extra_cm, bound = bound,
        max_cm = bound and math.min(2 * bound.r, 2 * M.cfg.escape_max_cm) or M.cfg.escape_max_cm })
    if #ex == 0 then
        if log then log("move: escape_zones: no safe point " .. (bound and "inside the bound" or "within range") .. " (in " .. zin.id .. ")") end
        return { ok = false, why = "no_safe_point", zone = zin.id, detail = bound and "every point in the bound is in a zone" or "every point within range is in a zone" }
    end
    local mem, NMm = nav_mem()
    local pick, tested, why = nil, 0, {}
    for _, c in ipairs(ex) do
        if tested >= M.cfg.escape_max_tests then break end
        if not (mem and NMm.is_water(mem, c)) then
            tested = tested + 1
            local okr, r = pcall(escape_line_clear, pawn, me, feet, c)
            if okr and r == true then pick = c; break end
            why[#why + 1] = string.format("%.0fdeg:%s", c.yaw, okr and tostring(r) or "error")
        end
    end
    if not pick then
        if log then log("move: escape_zones: no route out of " .. zin.id .. " (" .. table.concat(why, " ") .. ")") end
        return { ok = false, why = "no_route", zone = zin.id, tested = tested, detail = table.concat(why, " ") }
    end
    local st = S()
    local okw, walk = pcall(function() return pawn.CharacterMovement.MaxWalkSpeed end)
    walk = (okw and tonumber(walk) and tonumber(walk) > 50) and tonumber(walk) or M.cfg.escape_walk_cms
    local spr = (st.sprint_speed_cms and st.sprint_speed_cms > walk) and st.sprint_speed_cms or M.cfg.escape_sprint_cms
    local time_s = tonumber(opts.time_s)
    local sprint = opts.sprint ~= false and (pick.dist > 300 or (time_s ~= nil and time_s < 5))
    local eta = M.cfg.escape_react_s + pick.dist / (sprint and spr or walk)
    local at = { X = pick.X, Y = pick.Y, Z = me.Z }
    local eta_r = math.floor(eta * 100 + 0.5) / 100
    if time_s and eta > time_s then
        if log then log(string.format("move: escape_zones: too slow (%.2fs to get out of %s, %.2fs left)", eta, zin.id, time_s)) end
        return { ok = false, why = "too_slow", at = m3(at), eta_s = eta_r, zone = zin.id, dist_m = math.floor(pick.dist) / 100 }
    end
    local prev = M.snapshot()
    local r = start(log, "go_to", { goal = { at.X / 100, at.Y / 100, at.Z / 100 }, tolerance_m = 0.4, sprint = sprint,
        sprint_force = sprint, nav = false, local_plan = false, timeout_s = math.max(3, eta * 3),
        escape = { zone = zin.id, eta_s = eta_r, at = m3(at) } })
    if not r.ok then return { ok = false, why = "no_route", zone = zin.id, error = r.error } end
    if log then log(string.format("move: escape_zones: out of %s -> %s (%.1fm, eta %.2fs%s)", zin.id, fmt(at), pick.dist / 100, eta, sprint and ", sprint" or "")) end
    return { ok = true, at = m3(at), eta_s = eta_r, zone = zin.id, dist_m = math.floor(pick.dist) / 100, sprint = sprint, prev = prev }
end

return M
