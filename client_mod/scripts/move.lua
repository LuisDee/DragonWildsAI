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
-- Route sources, in order of use:
--   1. LOCAL PLANNER (scripts/localplan.lua): a trace-sampled grid + A* around Claude on the real
--      client collision (terrain + replicated player builds). Triggered by a forward wall probe or
--      by being stuck; plans a SEGMENT toward the far goal (Baritone-style segmented planning),
--      re-plans at the segment end if still blocked.
--   2. LEADER BREADCRUMBS when following (the leader's grounded trail is known walkable).
--   3. Dev-server NAV ORACLE (tools/nav_oracle.py): required before long-trip input unless nav=false;
--      nearby moves may use it opportunistically. A missing or unanswered required route holds.
--   4. Straight line for nearby or explicitly direct movement.
-- Unstuck ladder: local plan -> jump -> double jump -> strafe + backtrack along our own trail.
-- Bounded: no net progress toward the goal for > give_up_s -> stop with reason "stuck".
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
-- Unstuck (the game's, teleports to start) is used only when Claude himself cannot move at all.
-- NAVIGATION MEMORY (scripts/navmem.lua, streamline-plan step 5): Claude's successful trips and the
-- leader's walked trail are stored per world as routes (flushed when a move ends, also when a new
-- command interrupts it); Dijkstra over them is the first-choice router for long trips; known TRAPS
-- (seeded: the church start pit) put their exit first; a stuck spot that was later left becomes a
-- learned trap with that exit, and the failed direction is tabooed. M.escape_trap(log) for respawns.
-- Escape ladder at give-up: memory route -> learned link -> BUG2 wall-following (bounded) -> (wedged:
-- the game's Unstuck) -> unreachable. With a player near, it ASKS FOR HELP once per episode
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
    give_up_s = 5.0,           -- no PROGRESS for this long (planning time excluded) -> "stuck"
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
    lp_cell_cm = 100,
    lp_budget = 16,            -- traces per frame while standing to sample/verify (~1 ms each)
    lp_cache_ttl_s = 30,       -- world-aligned cell cache shared by plans and prefetch (builds change)
    prefetch_every = 3,        -- while moving: sample one cell ahead (2 traces) every N frames, so a
                               -- later plan mostly hits the cache (cuts the ~0.9 s standstill)
    allow_unstuck = false,     -- DISABLED (live 20:49:34: client CRASH, UE4SS push_arrayproperty access
                               -- violation right after the pause-menu Unstuck teleport). Opt-in only via
                               -- opts.allow_unstuck=true, and then it holds _G.DW_PAUSE across the teleport.
                               -- Default: report "stuck" and ask for help instead. (Was: the game's own
                               -- just before reporting "stuck" (Luis's decision 2026-10-25)
    lp_max_plans = 4,          -- plans without progress before the ladder takes over
    lp_cooldown_s = 1.5,       -- after a failed plan
    probe_every_s = 0.3,       -- forward wall probe cadence
    probe_ahead_cm = 150,
    probe_wall_nz = 0.7,       -- hit normal Z below this = wall (WalkableFloorAngle ~45 deg)
    follow_hysteresis_cm = 100,
    hop_dist_cm = 120,         -- a low obstacle (blocked at knee, clear at jump height) this close: jump now
    water_depth = 0.25,        -- EnvironmentComponent:GetNormalizedWaterDepth() above this = in water
    water_cell_cost = 8,       -- local planner: extra cost per known-water cell (prefer going round)
    bug_side_s = 12,           -- Bug2: time per side (left-hand, then right-hand)
    bug_side_cm = 3500,        -- Bug2: distance per side
    help_player_cm = 4000,     -- ask for help when a player is this close
    lead_clear_cm = 1500,      -- led this far from the stuck spot -> carry on to the goal ourselves
    lead_wait_s = 60,          -- a go_to waits this long for someone to lead it out
    trip_spacing_cm = 250,     -- trip recording resolution (navmem routes)
    mem_min_trip_cm = 3000,    -- use a remembered route only for trips longer than this
    trap_leave_cm = 1500,      -- leaving a stuck spot by this much makes the path since then its exit ...
    trap_extend_cm = 1000,     -- ... and the exit keeps growing for this much more walking (well clear)
    oracle_primary_cm = 1000,  -- beyond this (or above jump height) the oracle route leads; the local
                               -- planner only handles the obstacle in front of the next waypoint
    unreachable_check_s = 1.5, -- while unreachable: re-check this often
    unreachable_moved_cm = 300,-- ... and resume at once when the leader moved this far
    self_stuck_cm = 100,       -- moved less than this in total over give_up_s = WE are stuck (not the route)
    superjump_cm = 450,        -- leader rise above this = Windstep (a double jump rises ~2.6-3 m: live
    superjump_any_cm = 450,    --  20:25 his double jumps were misread at 250 cm and cut his trail)
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

-- Resolve a goal spec to (pawn_or_actor, kind) with kind "player" | "actor".
local function resolve_target(spec, me)
    if type(spec) == "userdata" then return spec, "actor" end
    if type(spec) == "table" and spec.actor then return spec.actor, "actor" end
    local p = player_pawn(tostring(spec), me)
    if p then return p, "player" end
    local a = actor_by_id(tostring(spec))
    if a then return a, "actor" end
end

-- Traversal events for the traversal agent / brain (docs/research/2026-10-25-traversal.md):
-- successful non-walk local-plan edges, one JSON line each, metres.
local EVENTS = ROOT .. "/client_io/events/traversal.jsonl"
local MOVE_EVENTS = ROOT .. "/client_io/events/move.jsonl"
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
    local parts = { string.format('"type":"%s"', kind), string.format('"ts":%d', os.time()),
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
    f:write(string.format('{"type":"self_edge","move":"%s","from":[%.2f,%.2f,%.2f],"to":[%.2f,%.2f,%.2f],"heading_deg":%.1f,"runup_m":0,"sprint":false,"dz_m":%.2f,"gap_m":%.2f,"ts":%d,"iso":"%s"}\n',
        move, a.X / 100, a.Y / 100, a.Z / 100, b.X / 100, b.Y / 100, b.Z / 100, h, (b.Z - a.Z) / 100,
        d2(a, b) / 100, os.time(), os.date("!%Y-%m-%dT%H:%M:%SZ")))
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
    local okh, hh = pcall(function() return ctx.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if not (okl and me) then return false end
    hh = (okh and tonumber(hh)) or 90
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

local function water_sense_calibrate(st, pawn, me, fe, dx, dy, log)
    if rawget(_G, "DW_WATER_CH") ~= nil then return end
    local x, y = me.X + dx * 90, me.Y + dy * 90 -- beside Claude (his own gear blocks traces)
    for _, c in ipairs(WATER_CANDIDATES) do
        local ok, hit, out = pcall(trace_with, c, pawn, { X = x, Y = y, Z = fe.Z + 300 }, { X = x, Y = y, Z = fe.Z - 300 })
        if log then log(string.format("move: water sense try %s: ok=%s hit=%s z=%s feet=%.0f", c.name, tostring(ok), tostring(hit),
            tostring(ok and type(out) == "table" and out.ImpactPoint and math.floor(out.ImpactPoint.Z) or out), fe.Z)) end
        if ok and hit and out.ImpactPoint and out.ImpactPoint.Z > fe.Z + 15 and out.ImpactPoint.Z < fe.Z + 250 then
            _G.DW_WATER_CH = c
            if log then log("move: water sense: channel '" .. c.name .. "' sees the surface") end
            return
        end
    end
    _G.DW_WATER_CH = false
    if log then log("move: water sense: no trace channel sees the water surface (learning by wading only)") end
end

local function make_trace(st, pawn)
    return function(a, b, horizontal)
        st.traces = (st.traces or 0) + 1
        local hit, out = raw_trace(pawn, a, b)
        if horizontal then return hit, hit and out.ImpactPoint or nil end
        if not hit then return nil end
        local ip = out.ImpactPoint
        return ip and ip.Z, (tonumber(out.Distance) or 1) < 0.5
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
    local env = { step = step, jump = apex - 15, djump = apex - 15, -- double-jump edges only once MEASURED
                  drop = math.min(1000, math.max(150, safe_drop - 50)), apex = apex, double_jump = dj, source = "engine",
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
    for _, p in ipairs({from, to}) do
        for _, k in ipairs({"X", "Y", "Z"}) do
            local x = p[k]
            if type(x) ~= "number" or x ~= x or math.abs(x) == math.huge then return false end
        end
    end
    st.nav_id = (st.nav_id or 0) + 1
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
        if st.crumb_mark then st.crumb_mark = math.max(0, st.crumb_mark - 1) end
    end
end

-- Nearest crumb at OUR level (|dz| <= 1 m): a crumb on a ledge 3.3 m above is not "near"
-- (live 18:52: the trail index jumped 2 -> 21 along crumbs all 3.3 m overhead). nil if none.
local function nearest_crumb(c, me)
    -- after a leader super-jump gap, prefer the part of the trail beyond it when any of it is at our level
    local g = 0
    for i = #c, 1, -1 do if c[i].gap then g = i; break end end
    local function search(from)
        local best, bi = math.huge, nil
        for i = from, #c do
            local p = c[i]
            if not p.air and not p.gap and math.abs(me.Z - p.Z) <= 100 then
                local d = d2(me, p)
                if d < best then best, bi = d, i end
            end
        end
        return bi
    end
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

-- ------------------------------------------------------------------ local planner glue
local function lp_cache()
    _G.DW_LP_CACHE = _G.DW_LP_CACHE or { cells = {}, ttl = M.cfg.lp_cache_ttl_s }
    return _G.DW_LP_CACHE
end

-- Prefetch cone ahead of us (forward 2..8 m, lateral -3..3 m), nearest first.
local CONE = {}
for f = 2, 8 do for l = -3, 3 do CONE[#CONE + 1] = { f, l } end end
table.sort(CONE, function(a, b) return a[1] * a[1] + a[2] * a[2] < b[1] * b[1] + b[2] * b[2] end)

local TL_MOD
local function tl_module()
    if TL_MOD == nil then
        local okc, chunk = pcall(loadfile, TL_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        TL_MOD = (okm and type(mod) == "table" and mod.best_link) and mod or false
    end
    return TL_MOD
end

local AZ_MOD
local function az_module()
    if AZ_MOD == nil then
        local okc, chunk = pcall(loadfile, AZ_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        AZ_MOD = (okm and type(mod) == "table" and mod.normalize) and mod or false
    end
    return AZ_MOD
end
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

local NM_MOD
local function nm_module()
    if NM_MOD == nil then
        local okc, chunk = pcall(loadfile, NM_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        NM_MOD = (okm and type(mod) == "table" and mod.plan) and mod or false
    end
    return NM_MOD
end

-- The per-world navigation memory (cached in _G.DW_NAVMEM across reloads of this file).
local UTIL_MOD
world_identity = function()
    if UTIL_MOD == nil then
        local okc, chunk = pcall(loadfile, ROOT .. "/mod/body/util.lua")
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        UTIL_MOD = (okm and type(mod) == "table" and mod.world_id) and mod or false
    end
    if not UTIL_MOD then return nil end
    -- Do not use the resolver's 60 s joined-server cache for route authority.
    local ok, id = pcall(UTIL_MOD.world_id, ROOT, { cache_s = 0 })
    if not ok or type(id) ~= "string" or id == "" or id == "unknown" then return nil end
    return id
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
local TM_MOD, SP_MOD
local function tm_profile()
    if TM_MOD == nil then
        local okc, chunk = pcall(loadfile, TM_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        TM_MOD = (okm and type(mod) == "table") and mod or false
    end
    return TM_MOD or {}
end
local function spells_mod()
    if SP_MOD == nil then
        local okc, chunk = pcall(loadfile, SP_PATH)
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        SP_MOD = (okm and type(mod) == "table" and mod.ability_status) and mod or false
    end
    return SP_MOD or nil
end
-- tests (and the bridge) may inject the spells module: {ability_status(asset[, api]), cast_now(log, asset, opts)}
function M.set_spells(m) SP_MOD = m or false end

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

local function lp_begin(st, pawn, me, far, why, log, observe)
    local LP = lp_module()
    if not LP then return false end
    local generation, pc = st.gen, st.pc
    local function valid() return not observe or local_route_owned(st,generation,pawn,pc,far) end
    local hh = observe and st.half_h or tonumber((pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
        and pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()) or 90
    local env = st.env or envelope(pawn, pc)
    if not valid() then return false end
    st.env = env
    -- a Windstep super-jump edge only while it is castable now AND measured (and not just failed on this move)
    do
        local ws = (st.env.ws_up_cm and not st.ws_off) and windstep_status(nil, now(pawn)) or nil
        if not valid() then return false end
        st.env.superjump = (ws and ws.state == "castable") and st.env.ws_up_cm or nil
        st.env.superjump_cost = (tm_profile().windstep or {}).cost
    end
    local trace = observe and make_observation_trace(st,pawn,me,hh,valid) or make_trace(st,pawn)
    if not valid() then return false end
    local planner = LP.new({ trace = trace, center = v(me), feet_z = me.Z - hh,
        radius_m = M.cfg.lp_grid_m, cell_cm = M.cfg.lp_cell_cm, env = st.env,
        cache = not observe and lp_cache() or nil, now = function() return now(pawn) end, self_pos = v(me),
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
            local c = rawget(_G, "DW_WATER_CH")
            local ok, hit, out = pcall(trace_with, c, pawn, { X = x, Y = y, Z = floor_z + 300 }, { X = x, Y = y, Z = floor_z - 50 })
            if ok and hit and out.ImpactPoint and out.ImpactPoint.Z > floor_z + 15 then
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
                if not st.lp_observe then st.want_trail = true; st.nav_force = true end -- ordinary replans only
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
                if not st.lp_observe then st.want_trail = true; st.nav_force = true end
                return false
            end
            st.lp_pts = pts
        elseif r == "ok" then
            if st.lp_observe then st.lp_state = "observed"; return false end
            st.lpath, st.lwp, st.lp_state = st.lp_pts, 2, nil
            st.lp_jumped = {}
            local acts = {}
            for _, p in ipairs(st.lpath) do acts[#acts + 1] = p.act:sub(1, 1) end
            st.lp_stand_s = t - (st.lp_t0 or t)
            local zs, AZm = live_zones(t)
            if AZm and #zs > 0 then
                -- a cost, not a wall: when no other way exists the plan crosses (the soonest-ending zone)
                local zc = AZm.on_route(zs, st.lpath[1], st.lpath, 2, nil, M.cfg.avoid_margin_cm)
                if zc and log then log(string.format("move: no way round avoid zone %s; crossing it (ends in %.1fs)", zc.id, zc.until_s - t)) end
            end
            if log then
                log(string.format("move: local path %d pts [%s] traces=%d cache_hits=%d replans=%d stand=%.2fs end=%s",
                    #st.lpath, table.concat(acts), P.traces, P.cache_hits or 0, st.lp_rounds, st.lp_stand_s, fmt(st.lpath[#st.lpath])))
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
    pcall(mem_flush, st, log, result and result.status)
    if not current() then return end
    local handle=st.handle
    if handle then pcall(CancelDelayedAction, handle) end
    if not current() or st.handle ~= handle then return end
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
    local grounded = ground_check(pawn)
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
    if near ~= true then return { ok = false, reason = "verification_failed", detail = near == false and "position differs from requested destination" or "position or destination unavailable" } end
    return { ok = true, position = { here.X / 100, here.Y / 100, here.Z / 100 },
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

local function tick(st, gen, log)
    if st.gen ~= gen then return "stale" end
    if paused() then
        if st.local_binding then
            st.local_authority, st.local_binding, st.lpath, st.lp, st.lp_state, st.lp_observe = nil, nil, nil, nil, nil, nil
            st.local_observe_done, st.lp_jump_exec, st.jump_double = true, nil, false
        end
        st.status = "paused"; return
    end
    local pc, pawn = st.pc, nil
    if not (pc and pc:IsValid()) then return finish(st, { status = "failed", reason = "verification_failed", detail = "controller unavailable" }, log) end
    pawn = pc.Pawn
    if not is_character(pawn) then return finish(st, { status = "failed", reason = "verification_failed", detail = "player character unavailable" }, log) end
    local alive, life_reason, life_detail = life_check(st, pawn)
    if not alive then return finish(st, { status = "failed", reason = life_reason, detail = life_detail }, log) end
    local t = now(pawn)
    local dt = st.last_t and (t - st.last_t) or 0
    st.last_t = t
    local me = pawn:K2_GetActorLocation()
    st.ticks = st.ticks + 1
    if st.ws_exec and (st.lpath ~= st.ws_exec.path or st.lwp ~= st.ws_exec.index
        or not st.lpath or st.lpath[st.lwp] ~= st.ws_exec.endpoint or st.lpath[st.lwp].act ~= "superjump") then
        return finish(st, { status = "failed", reason = "windstep_interrupted", detail = "planned traversal changed before landing" }, log)
    end

    -- An admitted local traversal cannot release or submit a second jump under a stale route.
    if st.jump_t and st.local_authority and (not st.local_binding or not local_route_owned(st,gen,pawn,pc,st.local_binding.goal)) then return end
    -- jump sequencing: release after 0.25 s; double jump 0.35 s after the first
    if st.jump_t then
        local jb=binding(st,pawn)
        if st.jump_release and t - st.jump_t > 0.25 then
            if not owned(jb) then reject_binding(jb,log); return end
            local ok=pcall(function() pawn:StopJumping() end)
            if not owned(jb) then reject_binding(jb,log); return end
            if not ok then return finish(st,{status="failed",reason="verification_failed",detail="jump release unconfirmed"},log) end
            st.jump_release = false
        end
        if st.jump_double and t - st.jump_t > ((st.env and st.env.dj_delay_s) or 0.33) then
            if not owned(jb) then reject_binding(jb,log); return end
            local grounded=ground_check(pawn)
            if not owned(jb) then reject_binding(jb,log); return end
            st.jump_observation = {intent="second", submitted=false, airborne=grounded == nil and "unknown" or not grounded, generation=st.gen}
            if grounded == false then
                local ok=pcall(function() pawn:Jump() end)
                if not owned(jb) then reject_binding(jb,log); return end
                if not ok then return finish(st,{status="failed",reason="verification_failed",detail="second jump input failed"},log) end
                st.jump_double = false; st.jump_t2 = t; st.double_jumps = (st.double_jumps or 0) + 1
                st.jump_observation.submitted = true
            elseif t - st.jump_t > 1.2 then
                return finish(st,{status="failed",reason="verification_failed",detail="airborne state unconfirmed for second jump"},log)
            end
        end
        if st.jump_t2 and t - st.jump_t2 > 0.25 then
            if not owned(jb) then reject_binding(jb,log); return end
            local ok=pcall(function() pawn:StopJumping() end)
            if not owned(jb) then reject_binding(jb,log); return end
            if not ok then return finish(st,{status="failed",reason="verification_failed",detail="second jump release unconfirmed"},log) end
            st.jump_t2 = nil
        end
        if t - st.jump_t > 1.2 and not st.jump_double and not st.jump_t2 and not st.jump_release then st.jump_t = nil end
    end

    -- goal: a point, or a player's pawn (re-resolved at most once a second if it went away)
    local goal
    if st.target_name then
        if not (st.target and st.target:IsValid()) and t - (st.target_t or 0) > 1.0 then
            st.target, st.target_t = resolve_target(st.target_spec or st.target_name, pawn), t
            st.target_mc = nil
        end
        if not (st.target and st.target:IsValid()) then
            st.status = "target_not_visible"
            if st.mode == "go_to" and t - st.t0 > 10 then return finish(st, { status = "failed", reason = "target_not_visible" }, log) end
            st.prog_t = nil
            return
        end
        goal = st.target:K2_GetActorLocation()
        -- a relevancy-culled / teleporting proxy reads as the world origin (live 20:25: Claude sprinted
        -- toward (0,0,0), 1.8 km away): treat as not visible
        if math.abs(goal.X) < 100 and math.abs(goal.Y) < 100 then
            st.status = "target_not_visible"
            if st.mode == "go_to" and t - st.t0 > 10 then return finish(st, { status = "failed", reason = "target_not_visible" }, log) end
            st.prog_t = nil
            return
        end
        -- teleport: drop the old route and trail
        if st.last_goal and d2(goal, st.last_goal) > M.cfg.target_jump_cm then
            if log then log(string.format("move: target jumped %.0f m (teleport?); resetting route and trail", d2(goal, st.last_goal) / 100)) end
            st.path, st.lpath, st.mpath, st.trail_i, st.bug = nil, nil, nil, nil, nil
            st.crumbs, st.crumb_mark = {}, 0
            st.nav_force = true
        end
        st.last_goal = v(goal)
        if st.target_kind ~= "actor" then
            record_crumb(st, goal)
            -- leader moves Claude may lack: airborne rise > superjump_cm = Windstep; jump count 2 = double jump
            local okg, ground = pcall(function() return st.target.CharacterMovement:IsMovingOnGround() end)
            if okg and ground == false then
                if not st.l_air then st.l_air = { z0 = goal.Z, zmax = goal.Z, n0 = #st.crumbs, jc = 0 } else st.l_air.zmax = math.max(st.l_air.zmax, goal.Z) end
                local okj0, jc0 = pcall(function() return st.target.ReplicatedJumpCurrentCount end)
                if okj0 and tonumber(jc0) then st.l_air.jc = math.max(st.l_air.jc or 0, tonumber(jc0)) end
            elseif okg and st.l_air then
                local rise = st.l_air.zmax - st.l_air.z0
                if rise > M.cfg.superjump_any_cm then
                    -- Windstep: his airborne crumbs are not a path for us; the trail ends at his take-off
                    st.leader_superjump_t = t
                    for k = #st.crumbs, st.l_air.n0 + 1, -1 do table.remove(st.crumbs, k) end
                    if st.trail_i and st.trail_i > #st.crumbs then st.trail_i = #st.crumbs end
                    st.next_gap = true
                    if log then log("move: leader super-jump (Windstep) rise=" .. math.floor(st.l_air.zmax - st.l_air.z0) .. "cm; trail cut at take-off") end
                end
                st.l_air = nil
            end
            -- jump count CHANGES only: the replicated value stays stale after landing (traversal agent)
            local okj, jc = pcall(function() return st.target.ReplicatedJumpCurrentCount end)
            jc = okj and tonumber(jc) or nil
            if jc and st.l_jc and jc >= 2 and st.l_jc < 2 and st.l_air then st.leader_dj_t = t end
            st.l_jc = jc
        end
        st.target_pos = goal
    else
        goal = st.goal
    end
    local dist = d2(me, goal)
    st.dist_cm = dist
    if st.dz0 == nil then st.dz0 = goal.Z - me.Z; st.original_goal_xy = dist end
    -- Long trips require an admitted route before any planner, traversal or raw input.
    -- Once required, keep the authority until the real three-dimensional arrival.
    local route_far = dist > M.cfg.oracle_primary_cm or
        (goal.Z - me.Z) > ((st.env and st.env.jump or 165) + 20)
    if st.use_nav ~= false and not st.nav_required and (route_far or st.nav_deferred_required) then
        if st.ws_exec or st.link_exec or st.jump_t then
            -- Let the already-owned traversal finish its existing landing/release transaction.
            st.nav_deferred_required = true
        else
            st.nav_required, st.nav_deferred_required = true, nil
            -- Existing short/direct plans are not authority for the newly required route.
            st.lpath, st.lp_state, st.trail_i, st.mpath, st.lp_jump_exec = nil, nil, nil, nil, nil
        end
    end
    -- Finish an already accepted ordinary jump, but do not issue further steering
    -- while a newly required route waits for its release transaction.
    if st.nav_deferred_required and st.jump_t and not st.ws_exec and not st.link_exec then
        st.status = "planning"
        return
    end
    local at_route_goal = reached(st, me, goal)
    if st.use_nav ~= false and not at_route_goal then
        local arb = move_arbiter()
        local owns = arb and arb.owns_move and st.owner_token and arb.owns_move(st.owner_token)
        if not owns or rawget(_G, "DW_MOVE") ~= st or st.gen ~= gen or pawn ~= st.pawn or paused() then return end
        if not st.local_authority and not st.lp_observe and st.nav_goal and (d2(goal, st.nav_goal) > M.cfg.repath_goal_move_cm or
            math.abs(goal.Z - st.nav_goal.Z) > M.cfg.repath_goal_move_cm) then
            st.path, st.nav_pending, st.nav_goal, st.nav_fail = nil, nil, nil, nil
            st.nav_wait_t = nil
        end
        local world = world_identity()
        local pending = st.nav_pending
        if pending and not st.local_authority then
            local helper = oracle_offer()
            if helper and helper.epoch ~= pending.epoch then
                st.nav_pending, st.path, st.nav_fail = nil, nil, "oracle_restarted"
            elseif pending.gen ~= gen or pending.token ~= st.owner_token or pending.pawn ~= pawn or
                not world or pending.world ~= world then
                st.nav_pending, st.path = nil, nil
                st.nav_fail = "route_identity_changed"
            else
                local r = nav_poll(st)
                if r then
                    st.nav_pending = nil
                    local pts, valid = {}, type(r.ok) == "boolean" and r.ok == true and type(r.points) == "table" and #r.points >= 2
                    if r.partial ~= nil and type(r.partial) ~= "boolean" then valid = false end
                    if r.goal_projected ~= nil and type(r.goal_projected) ~= "boolean" then valid = false end
                    if valid then
                        for _, p in ipairs(r.points) do
                            if type(p) ~= "table" or #p ~= 3 then valid = false; break end
                            for k in pairs(p) do
                                if type(k) ~= "number" or k < 1 or k > 3 or k % 1 ~= 0 then valid = false; break end
                            end
                            if not valid then break end
                            for i = 1, 3 do
                                if type(p[i]) ~= "number" or p[i] ~= p[i] or math.abs(p[i]) == math.huge or
                                    math.abs(p[i] * 100) == math.huge then valid = false; break end
                            end
                            if not valid then break end
                            pts[#pts + 1] = { X=p[1]*100, Y=p[2]*100, Z=p[3]*100 }
                        end
                    end
                    if valid then
                        local last = pts[#pts]
                        local short_local = st.nav_required and st.use_lp and st.original_goal_xy and
                            st.original_goal_xy <= M.cfg.oracle_primary_cm and st.original_goal_xy <= M.cfg.lp_grid_m * 100
                        if (short_local or (st.unreach and st.unreach.reason == "no_route")) and
                            (r.partial ~= false or d2(last, goal) > st.tol_cm or math.abs(last.Z-goal.Z) > 2*st.half_h) then
                            valid = false
                        end
                    end
                    if valid then
                        for i = 2, #pts do
                            if pts[i].Z - pts[i-1].Z > 60 and d2(pts[i-1], pts[i]) < 300 then pts[i].link = true end
                        end
                        if st.lp_observe then
                            st.lp, st.lp_state, st.lp_observe, st.local_binding = nil, nil, nil, nil
                            st.local_observe_done = true
                        end
                        st.path, st.wp, st.path_partial = pts, 2, r.partial
                        st.path_goal, st.nav_jumped = v(st.nav_goal), {}
                        st.nav_binding = pending
                        st.nav_fail = nil
                        if st.unreach and st.unreach.reason == "no_route" then
                            pcall(emit_move_event, "reachable_again", { leader_pos=goal, my_pos=me, after_s=t-st.unreach.since })
                            if rawget(_G,"DW_MOVE") ~= st or st.gen ~= gen or st.owner_token ~= pending.token then return end
                            st.unreach = nil
                        end
                    else
                        st.path, st.nav_fail = nil, r.reason or "invalid_route"
                    end
                end
            end
        end
        if st.path then
            local b = st.nav_binding
            if not b or b.gen ~= gen or b.token ~= st.owner_token or b.pawn ~= pawn or
                not world or b.world ~= world then return end
            if not st.lpath and not st.trail_i and not st.mpath and not st.link_exec then
                st.wp = advance(st.path, st.wp, me, M.cfg.wp_radius_cm,
                    math.max((st.env and st.env.step or 45) + 20, 60), st.half_h or 90)
            end
            if st.wp > #st.path then
                local last = st.path[#st.path]
                if last and d2(last, goal) <= st.tol_cm and math.abs(last.Z - goal.Z) <= 2 * st.half_h then
                    st.wp = #st.path -- steer to the admitted endpoint, never substitute the raw goal
                else
                    st.path, st.nav_fail = nil, "route_ended_before_goal"
                end
            end
        end
        if st.mode == "follow" and not st.nav_pending and st.nav_fail and st.unreach and st.unreach.reason == "no_route" and
            t - st.unreach.check_t > M.cfg.unreachable_check_s then
            st.unreach.check_t, st.nav_fail, st.nav_wait_t = t, nil, t
        end
        if not st.local_authority and not st.path and not st.nav_pending and not st.nav_fail then
            local offer, offer_reason = oracle_offer()
            st.nav_live = offer ~= nil
            st.nav_wait_reason = offer_reason or "oracle_unavailable"
            if world and nav_request(st, me, goal, offer, world) then
                st.nav_sent_t = t
                st.nav_requests = (st.nav_requests or 0) + 1
            end
        end
        if st.local_authority and not local_route_owned(st, gen, pawn, pc, goal) then
            st.local_authority, st.local_binding, st.lpath, st.lp_observe = nil, nil, nil, nil
            return
        end
        if not st.path and st.nav_required and not st.local_authority then
            -- A short candidate is sampled while input is held. It is not authority until complete.
            if st.use_lp and st.original_goal_xy and st.original_goal_xy <= M.cfg.oracle_primary_cm and
                st.original_goal_xy <= M.cfg.lp_grid_m * 100 and not st.local_observe_done then
                local b = st.local_binding
                if not b then
                    local arb = rawget(_G,"DWArbiter")
                    if arb and arb.owner and arb.owner.token == st.owner_token and world and owned(binding(st,pawn)) then
                        b = { gen=gen, token=st.owner_token, pawn=pawn, pc=pc, arb=arb, owner=arb.owner, world=world, goal=v(goal), life=st.life_seq, half_h=st.half_h, target=st.target }
                        st.local_binding = b
                        local ok_begin, begun = pcall(lp_begin,st,pawn,me,goal,"route_observation",log,true)
                        if not local_route_owned(st,gen,pawn,pc,goal) then return end
                        if not ok_begin or not begun then st.local_observe_done=true end
                    end
                end
                if b and not st.local_observe_done then
                    if not local_route_owned(st,gen,pawn,pc,goal) then st.local_observe_done=true; st.lp=nil; st.lp_state=nil; return end
                    local worked = pcall(lp_work,st,t,log)
                    if not local_route_owned(st,gen,pawn,pc,goal) then return end
                    if not worked then st.lp=nil; st.lp_state=nil; st.local_observe_done=true end
                    if st.lp_state == "observed" then
                        local pts = st.lp_pts; local last = pts and pts[#pts]
                        st.local_observe_done=true
                        if last and #pts >= 2 and d2(last,goal) <= st.tol_cm and
                            math.abs((last.Z + st.half_h) - goal.Z) <= 2 * st.half_h then
                            local copied = {}
                            for i, p in ipairs(pts) do copied[i] = { X=p.X, Y=p.Y, Z=p.Z, act=p.act } end
                            b.path = copied
                            st.lpath, st.lwp, st.lp_jumped, st.local_authority = copied, 2, {}, true
                            st.lp, st.lp_state = nil, nil
                        end
                    elseif not st.lp_state then st.local_observe_done=true end
                    if not st.local_authority then return end
                end
            end
        end
        if not st.path and st.nav_required and not st.local_authority then
            st.nav_wait_t = st.nav_wait_t or t
            st.status = st.unreach and "unreachable" or "planning"
            st.prog_t, st.prog_pos, st.win_t, st.win_pos = t, v(me), t, v(me)
            if st.prog_tr then st.prog_tr.last_t = nil end
            if st.mode == "go_to" and t - st.t0 > st.timeout_s then
                return finish(st, { status="failed", reason="timeout", detail="route not yet verified" }, log)
            end
            if st.nav_fail or t - st.nav_wait_t > M.cfg.nav_timeout_s then
                local why = st.nav_fail or (st.nav_pending and "oracle_timeout") or st.nav_wait_reason or "oracle_unavailable"
                if st.mode == "go_to" then
                    return finish(st, { status="failed", reason="verification_failed", detail="route unavailable: " .. tostring(why) }, log)
                end
                if not st.unreach then
                    st.nav_fail = why
                    st.unreach = { reason="no_route", since=t, check_t=t, leader_pos=v(goal) }
                    pcall(emit_move_event, "unreachable", { reason="no_route", detail="route unavailable: " .. tostring(why), leader_pos=goal, my_pos=me, mode="follow" })
                    if rawget(_G,"DW_MOVE") ~= st or st.gen ~= gen then return end
                end
                st.status = "unreachable"
            end
            return
        end
        st.nav_wait_t = nil
    end
    -- "near" for the tracker: within tolerance, or a follow idling (incl. holding at a zone's edge)
    local same_level = type(goal.Z) == "number" and type(me.Z) == "number" and math.abs(goal.Z - me.Z) <= 2 * st.half_h
    progress_tick(st, t, me, goal, dist, (dist <= st.tol_cm and same_level) or (st.mode == "follow" and st.idle == true and same_level))

    -- AVOID ZONES (combat hazards): the zone we stand in (capsule overlap), and the leader's
    local zs, AZm = live_zones(t)
    local zone_in, zone_goal = nil, nil
    local mfeet = me.Z - (st.half_h or 90)
    if AZm and #zs > 0 then
        zone_in = AZm.at(zs, me.X, me.Y, mfeet, M.cfg.avoid_margin_cm)
        zone_goal = AZm.at(zs, goal.X, goal.Y, goal.Z - (st.half_h or 90), 0)
    end
    st.zone_in = zone_in and zone_in.id or nil
    if not zone_in then st.zone_exit = nil end
    if not (AZm and #zs > 0) then st.zone_cross = nil end
    if st.mode == "follow" and dist > M.cfg.leader_far_cm then
        if not st.far then
            st.far = true
            pcall(emit_move_event, "unreachable", { reason = "leader_far", leader_pos = goal, my_pos = me,
                detail = string.format("leader %.0f m away (teleported?)", dist / 100), mode = "follow" })
            if log then log(string.format("move: leader is %.0f m away; holding (lodestone catch-up needed)", dist / 100)) end
        end
        st.status = "leader_far"
        st.prog_t, st.win_t, st.win_pos = nil, t, v(me)
        return
    elseif st.far then
        st.far = nil
        pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me })
        st.nav_force = true
    end

    -- arrival / follow idle
    if st.mode == "go_to" then
        if st.escape and not zone_in then
            return finish(st, { status = "arrived", out_of_zones = true, zone = st.escape.zone, dist_m = dist / 100, s = t - st.t0 }, log)
        end
        local at_goal = reached(st, me, goal)
        if at_goal == nil then return finish(st, { status = "failed", reason = "verification_failed", detail = "position or destination unavailable" }, log) end
        if at_goal and not st.ws_exec and not st.lp_jump_exec and not (st.lpath and st.lpath[st.lwp] and st.lpath[st.lwp].act == "superjump") then
            local grounded = ground_check(pawn)
            if grounded == nil then return finish(st, { status = "failed", reason = "verification_failed", detail = "ground state unavailable" }, log) end
            if grounded then return finish(st, { status = "arrived", dist_m = dist / 100, s = t - st.t0 }, log) end
            if t - st.t0 <= st.timeout_s then st.status = "awaiting_landing"; return end
        end
        if t - st.t0 > st.timeout_s then return finish(st, { status = "failed", reason = "timeout", dist_m = dist / 100 }, log) end
    else
        local hold = st.idle and (st.tol_cm + M.cfg.follow_hysteresis_cm) or st.tol_cm
        -- the leader stands in a zone and its edge is just ahead: wait here, at the edge
        local edge_hold = false
        if zone_goal and not zone_in and dist > hold then
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
        if ((dist <= hold and same_level) or edge_hold) and not exit_pt and not st.lp_jump_exec and not st.ws_exec then
            st.idle, st.status = true, edge_hold and "near_zone" or "near"
            if st.trip and #st.trip >= 4 then st.trip_ok = true; pcall(mem_flush, st, log, "near"); st.trip = { feet_of(st, me) } end
            if st.unreach then
                pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me, after_s = math.floor((t - st.unreach.since) * 10) / 10 })
                st.unreach = nil
            end
            if st.face_when_near then
                pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)), Roll = 0 })
            end
            st.stuck_n, st.win_t, st.win_pos = 0, t, v(me)
            st.prog_t, st.prog_pos = t, v(me)
            st.lp, st.lp_state, st.lpath = nil, nil, nil
            return
        end
        st.idle = false
    end

    -- persistent follow: unreachable sub-state (stand, watch, re-check, resume by itself)
    if st.unreach then
        local u = st.unreach
        st.status = "unreachable"
        local moved = d2(goal, u.leader_pos) > M.cfg.unreachable_moved_cm
        local within = (goal.Z - me.Z) <= ((st.env and st.env.jump or 165) + 60)
        if moved or (t - u.check_t > M.cfg.unreachable_check_s and within and u.reason == "leader_above_jump_height") then
            if log then log(string.format("move: reachable again? (%s) leader=%s", moved and "leader moved" or "within reach", fmt(goal))) end
            pcall(emit_move_event, "reachable_again", { leader_pos = goal, my_pos = me, after_s = math.floor((t - u.since) * 10) / 10 })
            st.unreach, st.link_tries = nil, 0
            st.prog_t, st.prog_pos, st.stuck_n, st.lp_plans_np, st.move_acc = t, v(me), 0, 0, 0
            st.lpath, st.backtrack_until = nil, nil
            st.trail_i = nil
        else
            if t - u.check_t > M.cfg.unreachable_check_s then u.check_t = t end
            st.win_t, st.win_pos = t, v(me)
            pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)), Roll = 0 })
            return
        end
    end

    -- own trail (where we have been is walkable)
    local sc = st.self_crumbs
    if not sc[#sc] or d2(me, sc[#sc]) >= M.cfg.crumb_spacing_cm then
        local okg, g = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
        if not okg or g ~= false then
            sc[#sc + 1] = v(me)
            if #sc > M.cfg.self_cap then table.remove(sc, 1) end
        end
    end

    -- trip recording (navmem routes) and trap learning
    local fe = feet_of(st, me)
    st.trip = st.trip or {}
    local tp = st.trip
    if not tp[#tp] or d2(fe, tp[#tp]) >= M.cfg.trip_spacing_cm then
        local okg2, g2 = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
        if not okg2 or g2 ~= false then
            tp[#tp + 1] = fe
            if #tp > 2000 then table.remove(tp, 1) end
        end
    end
    local cand = rawget(_G, "DW_TRAP_CAND")
    if cand then
        -- the candidate keeps its OWN escape path (global: survives new commands and trip flushes)
        cand.path = cand.path or {}
        local cp = cand.path
        if (cp[#cp] and d2(fe, cp[#cp]) > 1000) or os.time() - (cand.t or 0) > 600 then
            -- a teleport (respawn, Unstuck, lodestone) or a stale candidate: not an escape route
            _G.DW_TRAP_CAND, cand = nil, nil
        elseif not cp[#cp] or d2(fe, cp[#cp]) >= M.cfg.trip_spacing_cm then
            cp[#cp + 1] = fe
            if #cp > 400 then table.remove(cp, 1) end
        end
    end
    if cand and d2(fe, cand.at) > M.cfg.trap_leave_cm and math.abs(fe.Z - cand.at.Z) < 400 then
        -- we got away from where we were stuck: the path since we were last there is its exit
        local cp = cand.path or {}
        local k0 = nil
        for k = #cp, 1, -1 do if d2(cp[k], cand.at) < 400 then k0 = k; break end end
        local mem, NMm = nav_mem()
        if k0 and mem and #cp - k0 >= 2 then
            local ex = {}
            for k = k0, #cp do ex[#ex + 1] = cp[k] end
            local okt, trap, how = pcall(NMm.learn_trap, mem, cand.at, ex, { src = "learned" })
            if cand.toward and not cand.learned then pcall(NMm.taboo, mem, cand.at, cand.toward, "failed approach") end
            pcall(NMm.save, mem)
            if log and not cand.learned then log(string.format("move: memory: trap %s %s, exit %d pts", tostring(okt and trap and trap.id), tostring(how), #ex)) end
            -- keep extending the exit for a while (until well clear), then close the candidate
            local walked = 0
            for k = k0 + 1, #cp do walked = walked + d2(cp[k - 1], cp[k]) end
            cand.learned = true
            cand.extend_to = cand.extend_to or (walked + M.cfg.trap_extend_cm)
            if walked >= cand.extend_to then _G.DW_TRAP_CAND = nil end
        else
            _G.DW_TRAP_CAND = nil
        end
    end

    -- WATER: learned from wading/swimming (EnvironmentComponent depth, MovementMode 4 = swimming);
    -- entering water, or known water ahead on the route, triggers a local re-plan that goes round
    if st.ticks % 6 == 0 then
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
            if st.in_water and mem and (st.water_new or 0) > 0 then pcall(NMm.save, mem); st.water_new = 0 end
            st.in_water = nil
        end
        if st.target and st.target_kind == "player" and mem then
            local okl, ldepth = pcall(function() return st.target.EnvironmentComponent:GetNormalizedWaterDepth() end)
            if okl and tonumber(ldepth) and tonumber(ldepth) > M.cfg.water_depth then NMm.mark_water(mem, feet_of(st, goal)) end
        end
    end

    -- go_to waiting for / being led out by a helper (after asking "lead me")
    local ld = st.lead
    if ld then
        local okl, hl = pcall(function() return ld.pawn:K2_GetActorLocation() end)
        if not (okl and ld.pawn:IsValid()) or t - ld.since > M.cfg.lead_wait_s and not ld.phase then
            st.lead, st.lead_done = nil, true
            return finish(st, { status = "failed", reason = "unreachable", why = ld.why, detail = ld.detail, asked = ld.name,
                dist_m = dist / 100 }, log)
        end
        -- the helper's walked trail (grounded samples), as leader breadcrumbs
        local c = st.crumbs
        if not c[#c] or d2(hl, c[#c]) >= M.cfg.crumb_spacing_cm then
            local okg4, g4 = pcall(function() return ld.pawn.CharacterMovement:IsMovingOnGround() end)
            if not okg4 or g4 ~= false then c[#c + 1] = v(hl) end
            if #c > M.cfg.crumb_cap then table.remove(c, 1) end
        end
        if not ld.phase then
            if d2(hl, ld.leader_pos) > 300 then
                ld.phase = "trail"
                if log then log("move: " .. ld.name .. " is leading; following his trail out") end
                st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.stuck_n = t, v(me), 0, nil, 0
            else
                st.status = "waiting_for_lead"
                if st.prog_t then st.prog_t = st.prog_t + dt end
                st.win_t, st.win_pos = t, v(me)
                pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(hl.Y - me.Y, hl.X - me.X)), Roll = 0 })
                return
            end
        end
        if ld.phase == "trail" then
            if d2(me, ld.from) > M.cfg.lead_clear_cm then
                if log then log("move: led clear of the stuck spot; carrying on to the goal") end
                pcall(emit_move_event, "led_out", { my_pos = me, helper = ld.name })
                st.lead, st.lead_done, st.trail_i = nil, true, nil
                st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.stuck_n, st.nav_force = t, v(me), 0, nil, 0, true
                st.bug_tried, st.mem_retry, st.link_tries = false, false, 0
            else
                if not st.trail_i and #st.crumbs >= 2 then st.trail_i = nearest_crumb(st.crumbs, me) or 1 end
                -- trail steering below follows st.crumbs from st.trail_i
            end
        end
    end

    -- memory routing, once per move (needs our position): a known trap's exit first; else a
    -- remembered route for long trips (human-proven / self routes, Dijkstra)
    if not st.mem_checked and not st.nav_required then
        st.mem_checked = true
        local mem, NMm = nav_mem()
        if mem then
            local gfe = feet_of(st, goal)
            local okt, trap = pcall(NMm.trap_at, mem, fe)
            local okg3, gtrap = pcall(NMm.trap_at, mem, gfe)
            if okt and trap and not (okg3 and gtrap and gtrap.id == trap.id) then
                -- whatever gets us out of this known trap becomes (or refreshes) its exit
                if not rawget(_G, "DW_TRAP_CAND") then
                    local c0 = trap.center
                    _G.DW_TRAP_CAND = { at = { X = c0[1] * 100, Y = c0[2] * 100, Z = c0[3] * 100 }, t = os.time(), trap = trap.id }
                    if log then log("move: memory: in trap " .. tostring(trap.id) .. "; the way out will be learned as its exit") end
                end
            end
            if okt and trap and not (okg3 and gtrap and gtrap.id == trap.id) and st.mode == "follow" and st.target then
                -- following a visible leader out: his live trail beats a stored (maybe provisional) exit
            elseif okt and trap and not (okg3 and gtrap and gtrap.id == trap.id) then
                st.mpath, st.mwp, st.msrc = NMm.trap_exit(trap), 1, "trap:" .. tostring(trap.id)
                if log then log("move: memory: in trap " .. tostring(trap.id) .. ", taking its exit first") end
            elseif dist > M.cfg.mem_min_trip_cm then
                local okp, pts = pcall(NMm.plan, mem, fe, gfe, { max_factor = 2.5 })
                if okp and pts then
                    st.mpath, st.mwp, st.msrc = pts, 1, "memory"
                    if log then log(string.format("move: memory: remembered route, %d pts", #pts)) end
                end
            end
        end
    end

    -- local planner owns the frame while it samples/verifies: stand still, pause the progress clock
    if st.lp_state then
        if lp_work(st, t, log) then
            st.status = "planning"
            if st.prog_t then st.prog_t = st.prog_t + dt end
            st.win_t, st.win_pos = t, v(me)
            return
        end
    end

    -- leader breadcrumbs: when the straight/nav route is failing
    local path = st.path
    if not st.nav_required and st.target and not st.trail_i and #st.crumbs >= 2 then
        local nav_bad = (path and st.path_partial and st.wp > #path) and dist > M.cfg.trail_min_dist_cm
        local above = (goal.Z - me.Z) > ((st.env and st.env.jump or 165) + 100) and dist < 1500
        if nav_bad or above or st.want_trail or st.stuck_n >= M.cfg.trail_enter_stuck then
            st.want_trail = false
            st.trail_i = nearest_crumb(st.crumbs, me)
            if st.trail_i then
                st.trail_entries = (st.trail_entries or 0) + 1
                if log then log(string.format("move: trail ON i=%d/%d", st.trail_i, #st.crumbs)) end
            end
        end
    end

    -- choose the steering point
    local aim, src = goal, "straight"
    local idx_progress = false
    local lx = st.link_exec
    if lx then
        -- running a learned traversal link (traverse_learn.lua): approach the run-up point, run at
        -- link.from, jump there (double/sprint per the link), then verify the landing near link.to
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
            st.prog_t, st.prog_pos, st.move_acc, st.bt_tested = t, v(me), 0, nil
            st.lpath, st.trail_i = nil, nil
            if ok then st.link_ok = (st.link_ok or 0) + 1 end
        end
        if lx.phase == "approach" then
            local start = runup > 50 and { X = from.X - hx * runup, Y = from.Y - hy * runup, Z = from.Z } or from
            aim, src = start, "link"
            if d2(me, start) < 60 then lx.phase = "run" end
            if t - lx.t0 > M.cfg.link_approach_s then done(false, "approach_timeout") end
        elseif lx.phase == "run" then
            aim, src = to, "link"
            if (L.needs and L.needs.sprint) or L.move == "sprint_jump" then st.sprint_want = true end
            local along = (me.X - from.X) * hx + (me.Y - from.Y) * hy
            if d2(me, from) < 50 or along > 0 then
                local jr=start_jump(st, t, pawn, L.move == "double_jump" and st.env and st.env.double_jump, log)
                if jr == "accepted" then lx.phase, lx.t_jump = "air", t elseif jr ~= "busy" then return end
            end
        elseif lx.phase == "air" then
            aim, src = to, "link"
            local okg2, ground = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
            if t - lx.t_jump > 0.4 and okg2 and ground then
                local dz = math.abs(feet.Z - to.Z)
                done(d2(feet, to) < 200 and dz < 100, string.format("landed %.1fm from link.to", d2(feet, to) / 100))
            elseif t - lx.t_jump > 4 then
                done(false, "no_landing")
            end
        end
        if st.link_exec then idx_progress = true end -- executing a link is progress (no give-up mid-run)
    end
    local so = st.stepoff
    if so then
        if d2(me, so.start) > 120 or (so.start.Z - me.Z) > 60 then
            if log then log("move: stepped off") end
            st.stepoff = nil
            st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.stuck_n, st.nav_force = t, v(me), 0, nil, 0, true
            st.lpath = nil
        elseif t - so.t0 > 0.6 then
            so.i, so.t0 = so.i + 1, t
            if so.i > 8 then st.stepoff = nil end
        end
        if st.stepoff then
            local yaw = so.yaw0 + so.i * 45 * ((so.i % 2 == 0) and 1 or -1)
            aim, src = { X = me.X + math.cos(math.rad(yaw)) * 300, Y = me.Y + math.sin(math.rad(yaw)) * 300, Z = me.Z }, "stepoff"
            idx_progress = true
        end
    end
    local bug = st.bug
    if st.stepoff then
        -- steering point chosen by step-off
    elseif bug and not (lx and st.link_exec) then
        -- BUG2 wall-following (automaticaddison.com/the-bug2-algorithm-for-robot-motion-planning ;
        -- cs.columbia.edu/~allen/F19/NOTES/Chap2-Bug.pdf): keep the obstacle on one side until we
        -- cross the start->goal line closer to the goal than where we hit it. Probes every 3rd frame.
        src = "bug2"
        idx_progress = true
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
                    st.bug, st.nav_force = nil, true
                    st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.stuck_n = t, v(me), 0, nil, 0
                end
            end
        end
        if st.bug and (t - bug.t0 > M.cfg.bug_side_s or bug.travel > M.cfg.bug_side_cm) then
            if not bug.switched then
                if log then log("move: bug2 switching sides") end
                bug.switched, bug.dir, bug.t0, bug.travel, bug.yaw = true, -bug.dir, t, 0, bug.yaw + 180
            else
                if log then log("move: bug2 gave up") end
                st.bug, st.bug_failed = nil, true
                st.prog_t = t - M.cfg.give_up_s - 1 -- straight back to the give-up decision
            end
        end
        if st.bug then aim = { X = me.X + math.cos(math.rad(bug.yaw)) * 300, Y = me.Y + math.sin(math.rad(bug.yaw)) * 300, Z = me.Z } end
    end
    if st.stepoff then
        -- steering point chosen by step-off
    elseif bug and st.bug then
        -- steering point chosen by Bug2
    elseif lx and st.link_exec then
        -- steering point chosen above
    elseif st.backtrack_until and t < st.backtrack_until and st.backtrack_pt then
        aim, src = st.backtrack_pt, "backtrack"
        if d2(me, st.backtrack_pt) < M.cfg.wp_radius_cm then st.backtrack_until = nil end
    else
        if st.backtrack_until then st.backtrack_until, st.backtrack_pt = nil, nil end
        if st.lpath then
            local i0 = st.lwp
            st.lwp = advance(st.lpath, st.lwp, me, M.cfg.lp_radius_cm, math.max((st.env and st.env.step or 45) + 20, 60), st.half_h or 90, true)
            if st.lwp > i0 then
                idx_progress = true
                for k = i0, st.lwp - 1 do
                    local pt = st.lpath[k]
                    if k > 1 and (pt.act == "jump" or pt.act == "djump" or pt.act == "drop") then
                        pcall(emit_self_edge, st, st.lpath[k - 1], pt, pt.act)
                    end
                end
            end
            if st.local_authority and st.lwp > #st.lpath then st.lwp = #st.lpath end
            if st.lwp > #st.lpath then
                st.lpath = nil -- segment done; the forward probe re-plans if still blocked
            else
                local p = st.lpath[st.lwp]
                aim, src = p, "local"
                if p.act == "superjump" then
                    local prev = st.lpath[st.lwp - 1]
                    local ws = st.ws_exec
                    local function fail(reason, detail)
                        return finish(st, { status = "failed", reason = reason, detail = detail }, log)
                    end
                    if not ws and prev and d2(me, prev) < 50 then
                        local a, token, generation = move_arbiter(), st.owner_token, st.gen
                        local owned = a and a.owns_move and a.owns_move(token)
                        if st.gen ~= generation or st.mode == "idle" then return end
                        if not owned then return fail("windstep_owner_lost", "movement ownership lost before casting") end
                        local okg, grounded = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
                        if not okg or grounded ~= true then return fail("windstep_not_grounded", "grounded takeoff was not confirmed") end
                        local gate = windstep_status(nil, t, true)
                        if gate.state ~= "castable" then return fail(gate.why or "windstep_unavailable", gate.detail or gate.state) end
                        local sp, prof = spells_mod(), tm_profile().windstep
                        if not (sp and sp.cast_now and prof and st.env and st.env.ws_up_cm) then
                            return fail("windstep_unavailable", "spell executor or measured envelope unavailable")
                        end
                        owned = a.owns_move(token)
                        if st.gen ~= generation or st.mode == "idle" then return end
                        if not owned then return fail("windstep_owner_lost", "movement ownership lost before casting") end
                        local ok, job = pcall(sp.cast_now, log, prof.spell_asset, { owner_token = token })
                        if st.gen ~= generation or st.mode == "idle" then if ok and job and job.cancel then pcall(job.cancel) end; return end
                        if not ok or not job or type(job.poll) ~= "function" then return fail("windstep_cast_failed", tostring(job)) end
                        st.ws_job, st.ws_exec = job, { phase = "casting", index = st.lwp, token = token, started_t = t, path = st.lpath, endpoint = p }
                        ws = st.ws_exec
                    elseif not ws and prev then aim = prev end
                    if ws and ws.index == st.lwp then
                        local a, generation = move_arbiter(), st.gen
                        local owned = a and a.owns_move and a.owns_move(ws.token)
                        if st.gen ~= generation or st.mode == "idle" then return end
                        if not owned then return fail("windstep_owner_lost", "movement ownership lost during traversal") end
                        if ws.phase == "casting" then
                            local job = st.ws_job
                            if t - ws.started_t > 15 then return fail("windstep_cast_timeout", "spell cast did not finish") end
                            local ok, result = pcall(job.poll)
                            if st.gen ~= generation or st.mode == "idle" or st.ws_job ~= job then return end
                            if not ok then return fail("windstep_cast_failed", tostring(result)) end
                            owned = a.owns_move(ws.token)
                            if st.gen ~= generation or st.mode == "idle" or st.ws_job ~= job then return end
                            if not owned then return fail("windstep_owner_lost", "movement ownership lost during casting") end
                            if result then
                                st.ws_job = nil
                                if not result.ok then return fail(result.reason or "windstep_cast_failed", result.data and (result.data.detail or result.data.why)) end
                                local jr=start_jump(st, t, pawn, false, log)
                                if jr ~= "accepted" then
                                    if jr == "busy" then return fail("windstep_interrupted", "another jump is still active") end
                                    return
                                end
                                ws.phase, ws.jump_t = "air", t
                            else
                                st.status = "casting"
                                st.win_t, st.win_pos, st.prog_t = t, v(me), nil
                                return -- no movement input while the spell job owns the player's input
                            end
                        else
                            local okg, grounded = pcall(function() return pawn.CharacterMovement:IsMovingOnGround() end)
                            if okg and grounded == false then ws.saw_air = true end
                            if t - ws.jump_t > 0.4 and ws.saw_air and okg and grounded == true then
                                local dz = math.abs((me.Z - (st.half_h or 90)) - p.Z)
                                if d2(me, p) < M.cfg.lp_radius_cm and dz < math.max((st.env.step or 45) + 20, 60) then
                                    pcall(emit_self_edge, st, prev, p, p.act)
                                    st.lwp, st.ws_exec = st.lwp + 1, nil
                                    idx_progress = true
                                else return fail("windstep_landing_missed", "landed away from the planned endpoint") end
                            elseif t - ws.jump_t > 8 then
                                return fail("windstep_landing_timeout", "grounded landing was not confirmed")
                            end
                        end
                    end
                end
                -- A typed jump advances only after owned air and endpoint landing evidence.
                if p.act == "jump" or p.act == "djump" then
                    local function traversal_failure(detail)
                        if st.mode ~= "follow" then
                            return finish(st,{status="failed",reason="verification_failed",detail=detail},log)
                        end
                        st.local_authority, st.local_binding, st.lpath, st.lp_jump_exec = nil,nil,nil,nil
                        st.local_observe_done, st.nav_required, st.nav_fail = true,true,detail
                        st.jump_double = false
                        st.unreach = {reason="no_route",since=t,check_t=t,leader_pos=v(goal)}
                        st.status = "unreachable"
                        pcall(emit_move_event,"unreachable",{reason="no_route",detail=detail,leader_pos=goal,my_pos=me,mode="follow"})
                    end
                    local prev = st.lpath[st.lwp - 1]
                    local j = st.lp_jump_exec
                    local bind = binding(st,pawn)
                    if not owned(bind) or (st.local_authority and not local_route_owned(st,gen,pawn,pc,goal)) then return end
                    if p.act == "djump" and not (st.env and st.env.double_jump and (not st.local_authority or st.env.dj_measured)) then
                        return traversal_failure("double jump unavailable")
                    end
                    if not j and prev and d2(me,prev) < 50 then
                        local grounded=ground_check(pawn)
                        if not owned(bind) then return end
                        if grounded ~= true then return traversal_failure("jump takeoff not confirmed grounded") end
                        local jr=start_jump(st,t,pawn,p.act=="djump" and st.env and st.env.double_jump,log)
                        if st.local_authority and not local_route_owned(st,gen,pawn,pc,goal) then return end
                        if jr == "accepted" then
                            st.lp_jump_exec={path=st.lpath,index=st.lwp,endpoint=p,previous=prev,token=st.owner_token,started=t,saw_air=false}
                            st.lp_jumped[st.lwp]=t; j=st.lp_jump_exec
                        elseif jr ~= "busy" then return end
                    elseif not j and prev and d2(me,prev)>=50 then aim=prev end
                    if j then
                        if j.path~=st.lpath or j.index~=st.lwp or j.endpoint~=p or j.token~=st.owner_token then
                            return traversal_failure("jump route changed")
                        end
                        local grounded=ground_check(pawn)
                        if not owned(bind) or (st.local_authority and not local_route_owned(st,gen,pawn,pc,goal)) then return end
                        if grounded==false then j.saw_air=true end
                        if j.saw_air and grounded==true then
                            local dz=math.abs((me.Z-st.half_h)-p.Z)
                            if d2(me,p)<M.cfg.lp_radius_cm and dz<math.max((st.env.step or 45)+20,60) then
                                pcall(emit_self_edge,st,prev,p,p.act)
                                if not owned(bind) then return end
                                if st.local_authority and st.lwp == #st.lpath then p.act="walk" end
                                st.lwp,st.lp_jump_exec=st.lwp+1,nil;idx_progress=true
                            else return traversal_failure("jump landing missed") end
                        elseif t-j.started>8 then return traversal_failure("jump landing unconfirmed") end
                    end
                end
            end
        end
        if not st.lpath and st.trail_i then
            local i0 = st.trail_i
            st.trail_i = advance(st.crumbs, st.trail_i, me, M.cfg.wp_radius_cm, math.max((st.env and st.env.step or 45) + 20, 60))
            if st.trail_i > i0 then idx_progress = true end
            if st.trail_i > #st.crumbs then
                st.trail_i = nil
                if log then log("move: trail OFF (caught up)") end
            else
                local cr = st.crumbs[st.trail_i]
                aim, src = cr, "trail"
                if cr.gap then
                    -- the trail continues only beyond a move we lack: hold at the take-off spot
                    local prev = st.crumbs[st.trail_i - 1]
                    aim = prev or cr
                    if d2(me, aim) < 150 then st.status = "holding"; st.win_t, st.win_pos = t, v(me); st.hold_gap = true end
                end
                -- the leader jumped here: take off when we reach the start of his airborne run
                if cr.air and d2(me, cr) < 150 and not st.trail_jumped[cr] then
                    local jr=start_jump(st, t, pawn, false, log)
                    if jr == "accepted" then
                        for k = st.trail_i, #st.crumbs do
                            if not st.crumbs[k].air then break end
                            st.trail_jumped[st.crumbs[k]] = true
                        end
                        st.trail_jumps = (st.trail_jumps or 0) + 1
                    elseif jr ~= "busy" then return end
                end
            end
        end
        if not st.lpath and not st.trail_i and st.mpath then
            local i0 = st.mwp
            st.mwp = advance(st.mpath, st.mwp, me, M.cfg.wp_radius_cm, math.max((st.env and st.env.step or 45) + 20, 60), st.half_h or 90)
            if st.mwp > i0 then idx_progress = true end
            if st.mwp > #st.mpath then
                if log then log("move: memory route done (" .. tostring(st.msrc) .. ")") end
                st.mpath, st.nav_force = nil, true
            else
                local mp = st.mpath[st.mwp]
                aim, src = { X = mp.X, Y = mp.Y, Z = mp.Z + (st.half_h or 90) }, "memory"
                local prevp = st.mpath[st.mwp - 1]
                if (mp.act == "jump" or mp.act == "djump") and prevp then
                    st.mem_jumped = st.mem_jumped or {}
                    local last = st.mem_jumped[st.mwp]
                    if d2(me, prevp) < 60 and (not last or t - last > 1.5) then
                        local jr=start_jump(st, t, pawn, false, log)
                        if jr == "accepted" then st.mem_jumped[st.mwp] = t elseif jr ~= "busy" then return end
                    elseif d2(me, prevp) >= 60 and not last and d2(me, mp) > d2(prevp, mp) then
                        aim = { X = prevp.X, Y = prevp.Y, Z = prevp.Z + (st.half_h or 90) }
                    end
                end
            end
        end
        if not st.lpath and not st.trail_i and not st.mpath and path then
            local i0 = st.wp
            if st.wp > i0 then idx_progress = true end
            if st.wp <= #path then
                aim, src = path[st.wp], "nav"
                -- an oracle segment that rises more than a step over a short run is a nav LINK (the
                -- dev navmesh's auto-generated jump links, bGenerateNavLinks): jump from its start
                local prev = path[st.wp - 1]
                if prev and aim.link then
                    local last = st.nav_jumped[st.wp]
                    if d2(me, prev) < 60 and (not last or t - last > 1.5) then
                        local jr=start_jump(st, t, pawn, false, log)
                        if jr == "accepted" then st.nav_jumped[st.wp] = t; st.link_jumps = (st.link_jumps or 0) + 1 elseif jr ~= "busy" then return end
                    elseif d2(me, prev) >= 60 and not last and d2(me, aim) > d2(prev, aim) then
                        aim = prev -- reach the take-off spot first
                    end
                end
            end
        end
    end
    if zone_in and st.zone_exit and not st.escape then aim, src, idx_progress = st.zone_exit, "avoid_exit", true end
    if st.local_authority and src ~= "local" then
        return finish(st, {status="failed", reason="verification_failed", detail="local route unavailable"}, log)
    end
    if st.nav_required and src == "straight" then
        if st.mode == "go_to" then
            return finish(st, { status="failed", reason="verification_failed", detail="route ended before destination" }, log)
        end
        st.status = "unreachable"
        return
    end
    st.source, st.aim = src, aim

    local dx, dy = aim.X - me.X, aim.Y - me.Y
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 1 and st.local_authority then
        return finish(st,{status="failed",reason="verification_failed",detail="local endpoint did not reach goal"},log)
    end
    if dl < 1 then dx, dy, dl = goal.X - me.X, goal.Y - me.Y, math.max(dist, 1) end
    dx, dy = dx / dl, dy / dl
    if st.strafe_until and t < st.strafe_until then
        dx, dy = dx * 0.3 + st.strafe_dir * -dy, dy * 0.3 + st.strafe_dir * dx
    end

    -- far goal for the local planner: a crumb a little ahead on the trail, else the goal
    local function far_goal()
        if st.nav_required and st.path and st.wp and st.wp <= #st.path then
            return st.path[st.wp]
        end
        if st.trail_i then
            return st.crumbs[math.min(#st.crumbs, st.trail_i + M.cfg.trail_lookahead)]
        end
        if st.mpath and st.mwp and st.mwp <= #st.mpath then
            local k = st.mwp
            while k < #st.mpath and d2(me, st.mpath[k]) < 600 do k = k + 1 end
            local q = st.mpath[k]
            return { X = q.X, Y = q.Y, Z = q.Z + (st.half_h or 90) }
        end
        if st.path and st.wp and st.wp <= #st.path then
            -- the oracle knows the way round (cliffs, hills): plan locally only to its next waypoints
            local k = st.wp
            while k < #st.path and d2(me, st.path[k]) < 600 do k = k + 1 end
            return st.path[k]
        end
        return goal
    end

    -- prefetch: sample one not-yet-cached cell in the cone ahead every few frames
    if not st.local_authority and st.use_lp and st.ticks % M.cfg.prefetch_every == 0 then
        local LP = lp_module()
        if LP and LP.prefetch then
            local cache, feet = lp_cache(), me.Z - (st.half_h or 90)
            local ctrace = st.ctrace or make_trace(st, pawn)
            st.ctrace = ctrace
            for _ = 1, 6 do
                st.cone_i = (st.cone_i or 0) % #CONE + 1
                local c = CONE[st.cone_i]
                local x = me.X + dx * c[1] * 100 - dy * c[2] * 100
                local y = me.Y + dy * c[1] * 100 + dx * c[2] * 100
                local used = LP.prefetch(cache, ctrace, x, y, feet, { cell_cm = M.cfg.lp_cell_cm, env = st.env,
                    now = function() return t end })
                if used > 0 then st.prefetched = (st.prefetched or 0) + 1; break end
            end
        end
    end

    -- AVOID ZONES on the way (pure math, a few times a second): plan round them with the local planner
    -- (zones are a cell cost there), at once when the zones changed, else at most once per avoid_plan_s;
    -- a route that still goes through one (no other way) is reported in status().avoid.crossing
    if AZm and #zs > 0 and t - (st.zone_chk_t or -1) >= M.cfg.avoid_check_s then
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
            and (st.zone_plan_ver ~= A.ver or t - (st.zone_plan_t or -100) > M.cfg.avoid_plan_s)
            and t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and st.lp_plans_np < M.cfg.lp_max_plans
        if replan then
            st.zone_plan_t, st.zone_plan_ver = t, A.ver
            st.lpath = nil
            if lp_begin(st, pawn, me, far_goal(), "avoid_zone " .. zc.id, log) then st.status = "planning"; return end
        end
    end

    -- forward wall probe (cheap, a few per second): a steep hit at knee height ahead -> plan
    if st.use_lp and not st.lpath and src ~= "backtrack" and src ~= "link" and src ~= "bug2" and src ~= "stepoff" and t - (st.probe_t or 0) > M.cfg.probe_every_s
        and t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and st.lp_plans_np < M.cfg.lp_max_plans then
        st.probe_t = t
        local hh = st.half_h or 90
        local knee = me.Z - hh + 50
        -- start 60 cm out: from Claude's centre the ray hits his own attached gear (live 19:22)
        local a = { X = me.X + dx * 60, Y = me.Y + dy * 60, Z = knee }
        local b = { X = me.X + dx * (60 + M.cfg.probe_ahead_cm), Y = me.Y + dy * (60 + M.cfg.probe_ahead_cm), Z = knee }
        local okp, hit, out = pcall(raw_trace, pawn, a, b)
        st.traces = (st.traces or 0) + 1
        local low = false
        if okp and hit then
            local nz = out.ImpactNormal and out.ImpactNormal.Z or 0
            if nz < M.cfg.probe_wall_nz then
                -- blocked at the knee but clear at jump height = a LOW obstacle (felled log): jump it
                local zh = me.Z - hh + ((st.env and st.env.jump) or 165) - 30
                local okh, hh2 = pcall(raw_trace, pawn, { X = a.X, Y = a.Y, Z = zh }, { X = b.X, Y = b.Y, Z = zh })
                st.traces = (st.traces or 0) + 1
                if okh and not hh2 then
                    low = true
                    st.probe_t = t - M.cfg.probe_every_s + 0.05 -- watch it closely until we jump
                    if 60 + (tonumber(out.Distance) or 999) < M.cfg.hop_dist_cm and not st.jump_t then
                        local jr=start_jump(st, t, pawn, false, log)
                        if jr == "accepted" then st.hops = (st.hops or 0) + 1; if log then log("move: hop over a low obstacle") end elseif jr ~= "busy" then return end
                    end
                elseif lp_begin(st, pawn, me, far_goal(), "wall_ahead", log) then
                    st.status = "planning"
                    return
                end
            end
        end
        if not low and st.water_replan then
            st.water_replan = nil
            if lp_begin(st, pawn, me, far_goal(), "water", log) then st.status = "planning"; return end
        end
        -- known water a few metres ahead on the way (e.g. an oracle route through shallow water)
        if not low and not st.lpath and not st.in_water and not st.wade and dist > 1000 and not st.trail_i then
            local mem, NMm = nav_mem()
            if mem and next(mem.water or {}) then
                for _, k in ipairs({ 300, 600, 900 }) do
                    if NMm.is_water(mem, { X = fe.X + dx * k, Y = fe.Y + dy * k }) then
                        if t - (st.water_plan_t or -100) > 5 and lp_begin(st, pawn, me, far_goal(), "water_ahead", log) then
                            st.water_plan_t = t
                            st.status = "planning"
                            return
                        end
                        break
                    end
                end
            end
        end
    end

    -- face where we go (control rotation = camera yaw; the pawn orients to its movement)
    if st.nav_required then
        if st.local_authority then if not local_route_owned(st,gen,pawn,pc,goal) then return end
        elseif not route_owned(st, gen, pawn, pc) then return end
    end
    pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
    if st.hold_gap then
        st.hold_gap = nil
        st.move_acc, st.bt_tested = M.cfg.self_stuck_cm, t -- holding on purpose: not wedged
    else
        if st.nav_required then
            if st.local_authority then if not local_route_owned(st,gen,pawn,pc,goal) then return end
            elseif not route_owned(st, gen, pawn, pc) then return end
        end
        pawn:AddMovementInput({ X = dx, Y = dy, Z = 0 }, 1.0, false)
        st.status = "moving"
    end

    -- sprint: far from the goal, only while making progress on the ground, never on a local path
    if st.sprint_force then st.sprint_want = true
    elseif dist > M.cfg.sprint_on_cm and st.sprint then st.sprint_want = true
    elseif dist < M.cfg.sprint_off_cm then st.sprint_want = false end
    local sprinting = is_sprinting(pawn)
    st.sprinting = sprinting
    if st.sprint_want and st.stuck_n == 0 and not st.jump_t and src ~= "local" then
        if press_to_sprint(st) then
            if not sprinting then
                st.sprint_hold = (st.sprint_hold or 0) + 1
                if st.sprint_hold <= 10 then
                    if inject_sprint(st, pawn) and st.sprint_hold == 1 then st.sprint_presses = (st.sprint_presses or 0) + 1 end
                elseif st.sprint_hold == 11 then st.sprint_rel_t = t
                elseif t - st.sprint_rel_t > M.cfg.sprint_retry_s then st.sprint_hold = 0 end
            else st.sprint_hold = 0 end
        else
            inject_sprint(st, pawn)
        end
    end

    -- stuck detection over 1 s windows, and the unstuck ladder
    if not st.win_t then st.win_t, st.win_pos = t, v(me) end
    if t - st.win_t >= M.cfg.stuck_window_s then
        local moved = d2(me, st.win_pos)
        st.move_acc = (st.move_acc or 0) + moved
        st.speed_cms = moved / (t - st.win_t)
        if sprinting then st.sprint_speed_cms = st.speed_cms end
        if moved < M.cfg.stuck_min_cm then
            st.stuck_n = st.stuck_n + 1
            st.stuck_total = (st.stuck_total or 0) + 1
            local n = st.stuck_n
            local ev = string.format("move: stuck n=%d moved=%.0fcm d=%.0f src=%s me=%s aim=%s goal=%s lwp=%s/%s trail=%s/%d",
                n, moved, dist, src, fmt(me), fmt(aim), fmt(goal), tostring(st.lwp), tostring(st.lpath and #st.lpath),
                tostring(st.trail_i), #st.crumbs)
            st.last_stuck = ev
            if log then log(ev) end
            local planned = false
            if n == 1 and not st.stepoff_tried then
                -- standing ON TOP of geometry (the floor around us is well below our feet, e.g. on the
                -- shelter, live 20:49): step off first (a jump forward, then short pushes all round)
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
                    local jr=start_jump(st, t, pawn, false, log)
                    if jr == "accepted" then
                        st.stepoff_tried = true
                        st.stepoff = { i = 0, t0 = t, start = v(me), yaw0 = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)) }
                        if log then log("move: perched on geometry; stepping off") end
                        planned = true
                    elseif jr ~= "busy" then return end
                end
            end
            if st.use_lp and not planned and n == 1 and t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and st.lp_plans_np < M.cfg.lp_max_plans then
                st.lpath = nil
                planned = lp_begin(st, pawn, me, far_goal(), "stuck", log)
            end
            if not planned then
                st.env = st.env or envelope(pawn, pc)
                local jr=start_jump(st, t, pawn, n >= 2 and st.env.double_jump, log)
                if jr ~= "accepted" and jr ~= "busy" then return end
                if n >= 3 then
                    st.strafe_dir = (n % 2 == 0) and 1 or -1
                    st.strafe_until = t + 0.7
                    st.want_repath = true
                    if st.trail_i then st.trail_i = nearest_crumb(st.crumbs, me) end
                end
                if n == M.cfg.backtrack_after and not st.backtrack_until then
                    local back, acc = nil, 0
                    for i = #sc - 1, 1, -1 do
                        acc = acc + d2(sc[i], sc[i + 1])
                        back = sc[i]
                        if acc >= M.cfg.backtrack_cm then break end
                    end
                    if back and acc >= 100 then
                        st.backtrack_pt, st.backtrack_until = back, t + M.cfg.backtrack_s
                        st.backtracks = (st.backtracks or 0) + 1
                        if log then log(string.format("move: backtrack %.0fcm to %s", acc, fmt(back))) end
                    end
                end
            end
        else
            st.stuck_n = 0
        end
        st.win_t, st.win_pos = t, v(me)
    end

    -- bounded give-up: no net progress toward the goal (or point reached) for > give_up_s
    if not st.prog_t then st.prog_t, st.prog_pos = t, v(me) end
    local gx, gy = goal.X - st.prog_pos.X, goal.Y - st.prog_pos.Y
    local gl = math.max(math.sqrt(gx * gx + gy * gy), 1)
    local toward = ((me.X - st.prog_pos.X) * gx + (me.Y - st.prog_pos.Y) * gy) / gl
    if toward >= M.cfg.progress_cm or idx_progress then
        st.prog_t, st.prog_pos, st.move_acc, st.bt_tested, st.bt_pos = t, v(me), 0, nil, nil
        if toward >= M.cfg.progress_cm then st.lp_plans_np = 0 end
    elseif t - st.prog_t > M.cfg.give_up_s then
        local at = { math.floor(me.X) / 100, math.floor(me.Y) / 100, math.floor(me.Z) / 100 }
        local self_stuck = false
        if (st.move_acc or 0) < M.cfg.self_stuck_cm then
            if not st.bt_tested then
                -- before calling ourselves wedged, try to move back the way we came (2.5 s)
                local sc2, back, acc = st.self_crumbs, nil, 0
                for i = #sc2 - 1, 1, -1 do
                    acc = acc + d2(sc2[i], sc2[i + 1]); back = sc2[i]
                    if acc >= M.cfg.backtrack_cm then break end
                end
                st.bt_tested, st.bt_pos = t, v(me)
                if back then st.backtrack_pt, st.backtrack_until = back, t + 2.5 end
                st.prog_t = t - M.cfg.give_up_s + 2.5
                if log then log("move: no movement; backtrack test before declaring self-stuck") end
                return
            end
            self_stuck = st.bt_pos ~= nil and d2(me, st.bt_pos) < 50
        end
        if self_stuck then
            -- WE cannot move at all (wedged): the game's Unstuck is the last rung, then report
            if log then log("move: self-stuck (moved " .. math.floor(st.move_acc or 0) .. " cm in " .. M.cfg.give_up_s .. " s). " .. tostring(st.last_stuck)) end
            local un = nil
            if st.allow_unstuck == true then un = M.unstuck(log) end -- explicit opt-in only
            _G.DW_TRAP_CAND = { at = feet_of(st, me), toward = st.aim and feet_of(st, st.aim) or nil, t = os.time() }
            local hname, hpawn = nearest_player(pawn, me, M.cfg.help_player_cm)
            if not st.asked_help then
                st.asked_help = true
                pcall(emit_move_event, "stuck", { ask = "lead_me", helper = hname, reason = "wedged", my_pos = me, leader_pos = goal,
                    where = string.format("at (%.0f, %.0f, %.0f)", me.X / 100, me.Y / 100, me.Z / 100),
                    unstuck = un and (un.ok and "requested" or un.error) })
            end
            if st.mode == "follow" then
                st.unreach = { reason = "wedged", since = t, check_t = t, leader_pos = v(goal), my_pos = v(me), detail = "can't move" }
                st.status = "unreachable"
                return
            end
            if hname and hpawn and not st.lead_done then
                local okl, hl = pcall(function() return hpawn:K2_GetActorLocation() end)
                st.lead = { pawn = hpawn, name = hname, from = v(me), since = t, leader_pos = okl and v(hl) or v(me), why = "wedged", detail = "can't move" }
                st.crumbs, st.crumb_mark, st.trail_i = {}, 0, nil
                st.status = "waiting_for_lead"
                return
            end
            return finish(st, { status = "failed", reason = "stuck", dist_m = dist / 100, unstuck = un and (un.ok and "requested" or un.error), at_m = at }, log)
        end
        -- we can move but cannot get closer. First: a remembered route (once per move)?
        if not st.mem_retry then
            st.mem_retry = true
            local mem, NMm = nav_mem()
            if mem then
                local okt, trap = pcall(NMm.trap_at, mem, feet_of(st, me))
                local pts = okt and trap and NMm.trap_exit(trap) or nil
                if not pts then
                    local okp, pp = pcall(NMm.plan, mem, feet_of(st, me), feet_of(st, goal), { max_factor = 3 })
                    pts = okp and pp or nil
                end
                if pts then
                    st.mpath, st.mwp, st.msrc = pts, 1, okt and trap and ("trap:" .. tostring(trap.id)) or "memory"
                    st.prog_t, st.prog_pos, st.move_acc, st.bt_tested = t, v(me), 0, nil
                    st.lpath, st.trail_i = nil, nil
                    if log then log("move: memory: retrying via " .. st.msrc) end
                    return
                end
            end
        end
        -- Next: Bug2 wall-following (bounded), once per move
        if not st.bug_tried and st.use_lp then
            st.bug_tried = true
            st.bug = { s = v(me), hit_d = dist, t0 = t, travel = 0, dir = 1, switched = false,
                yaw = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)) + 35 }
            st.prog_t, st.prog_pos, st.move_acc = t, v(me), 0
            st.lpath, st.trail_i, st.mpath = nil, nil, nil
            if log then log("move: bug2 wall-following from " .. fmt(me)) end
            return
        end
        -- Next: a learned traversal link toward the goal?
        local TL = tl_module()
        local needs = nil
        if TL and (st.link_tries or 0) < M.cfg.link_max_tries then
            local m = function(q) return { q.X / 100, q.Y / 100, q.Z / 100 } end
            local okb, link, info = pcall(TL.best_link, m(me), m(goal), { env = { double_jump = st.env and st.env.double_jump or false,
                air_dash = false, windstep = false }, max_detour = 3 })
            if okb and link then
                st.link_tries = (st.link_tries or 0) + 1
                st.link_exec = { link = link, phase = "approach", t0 = t }
                st.prog_t, st.prog_pos, st.move_acc = t, v(me), 0
                if log then log(string.format("move: trying learned link %s (%s, cost %.1fm)", tostring(link.id), tostring(link.move), tonumber(link.cost_m) or -1)) end
                return
            elseif okb and type(info) == "string" and info:sub(1, 6) == "needs:" then
                needs = info
            end
        end
        local reason
        if needs then reason = needs                                -- e.g. "needs:DoubleJump" (a known link needs a move we lack)
        elseif st.leader_superjump_t and t - st.leader_superjump_t < 30 then reason = "leader_windstepped"
        elseif st.leader_dj_t and t - st.leader_dj_t < 30 and not (st.env and st.env.double_jump) then reason = "leader_double_jumped"
        else
            -- the height gap counts only if the goal was ALREADY out of jump reach when we started; a
            -- gap we created by dropping down during the escape (live 07:05: Bug2 walked him off a
            -- ledge) is not the cause; the walls that blocked the way on our level are
            local jump_reach = (st.env and st.env.jump or 165) + 60
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
        -- ask for help (once per episode) when a player is near enough to lead us out
        local hname, hpawn, hd = nearest_player(pawn, me, M.cfg.help_player_cm)
        local where = nil
        do
            local mem, NMm = nav_mem()
            local okt, trap = false, nil
            if mem then okt, trap = pcall(NMm.trap_at, mem, feet_of(st, me)) end
            where = (okt and trap and (trap.name or trap.id)) or string.format("at (%.0f, %.0f, %.0f)", me.X / 100, me.Y / 100, me.Z / 100)
        end
        if hname and not st.asked_help then
            st.asked_help = true
            pcall(emit_move_event, "stuck", { ask = "lead_me", where = where, helper = hname, reason = reason, my_pos = me, detail = detail })
            if log then log("move: asking " .. hname .. " to lead me (" .. where .. ")") end
        end
        if st.mode == "follow" then
            st.unreach = { reason = reason, since = t, check_t = t, leader_pos = v(goal), my_pos = v(me), detail = detail }
            st.unreach_episodes = (st.unreach_episodes or 0) + 1
            pcall(emit_move_event, "unreachable", { reason = reason, leader_pos = goal, my_pos = me, detail = detail, mode = "follow" })
            _G.DW_TRAP_CAND = { at = feet_of(st, me), toward = st.aim and feet_of(st, st.aim) or nil, t = os.time() }
            st.status = "unreachable"
            return
        end
        pcall(emit_move_event, "unreachable", { reason = reason, leader_pos = goal, my_pos = me, detail = detail, mode = "go_to" })
        _G.DW_TRAP_CAND = { at = feet_of(st, me), toward = st.aim and feet_of(st, st.aim) or nil, t = os.time() }
        if hname and hpawn and not st.lead_done then
            -- a player is near: wait for them to lead us out (their trail), then carry on
            local okl, hl = pcall(function() return hpawn:K2_GetActorLocation() end)
            st.lead = { pawn = hpawn, name = hname, from = v(me), since = t, leader_pos = okl and v(hl) or v(me),
                why = reason, detail = detail }
            st.crumbs, st.crumb_mark, st.trail_i = {}, 0, nil
            st.status = "waiting_for_lead"
            return
        end
        return finish(st, { status = "failed", reason = "unreachable", why = reason, detail = detail, dist_m = dist / 100, at_m = at }, log)
    end

    if log and t - (st.log_t or 0) > M.cfg.log_every_s then
        st.log_t = t
        log(string.format("move: %s d=%.0fcm src=%s lwp=%s/%s trail=%s/%d spr=%s spd=%.0f traces=%d", st.mode, dist, src,
            tostring(st.lwp), tostring(st.lpath and #st.lpath), tostring(st.trail_i), #st.crumbs, tostring(sprinting),
            st.speed_cms or 0, st.traces or 0))
    end
end

local function start(log, mode, opts)
    if paused() then return { ok = false, error = "paused (world changing)" } end
    local st = S()
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
    cancel_superjump(st) -- before timer cancellation or ownership rotation
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    if st.mode ~= "idle" then pcall(mem_flush, st, log, "interrupted") end
    local inherited_token
    if st.owner_implicit and st.owner_token and not opts.owner_token then
        local a = move_arbiter()
        if a and a.replace_implicit then inherited_token = a.replace_implicit(st.owner_token) end
    end
    if not inherited_token then release_implicit(st, log) end
    local gen = st.gen + 1
    local keep = { gen = gen, nav_id = st.nav_id, eis = st.eis, pts = st.pts }
    for k in pairs(st) do st[k] = nil end
    for k, x in pairs(keep) do st[k] = x end
    st.mode, st.pc, st.ticks, st.stuck_n = mode, pc, 0, 0
    st.pawn = pawn
    local life = rawget(_G, "DW_LIFE")
    st.life_seq = type(life) == "table" and (life.move_death_seq or 0) or 0
    local a = move_arbiter()
    if inherited_token then
        st.owner_token, st.owner_implicit = inherited_token, true
    elseif a and opts.owner_token and a.owns_move and a.owns_move(opts.owner_token) then
        st.owner_token = opts.owner_token
        local owner = a.owner and a.owner()
        st.owner_implicit = owner and owner.implicit == true or false
    elseif a and not opts.owner_token and a.adopt_move then
        st.owner_token = a.adopt_move(log)
        st.owner_implicit = st.owner_token ~= nil
    end
    st.crumbs, st.self_crumbs, st.lp_plans_np, st.trail_jumped, st.nav_jumped = {}, {}, 0, {}, {}
    st.half_h = half_height
    st.t0 = now(pawn)
    st.tol_cm = (opts.tolerance_m or 1.5) * 100
    st.timeout_s = opts.timeout_s or 120
    st.sprint = opts.sprint ~= false
    st.use_nav = opts.nav
    st.use_lp = opts.local_plan ~= false and M.cfg.lp_enabled
    st.allow_unstuck = opts.allow_unstuck
    if opts.sprint_m then M.cfg.sprint_on_cm = opts.sprint_m * 100; M.cfg.sprint_off_cm = math.min(M.cfg.sprint_off_cm, opts.sprint_m * 50) end
    st.face_when_near = opts.face_when_near
    st.sprint_force = opts.sprint_force == true
    st.wade = opts.wade == true -- the goal is IN water on purpose (a pond to use): water avoidance off for this move
    st.escape = type(opts.escape) == "table" and opts.escape or nil
    st.prog_tr = progress_new(opts.progress)

    if type(g) == "table" and not g.actor then
        st.goal = { X = g[1] * 100, Y = g[2] * 100, Z = g[3] * 100 }
    else
        st.target, st.target_kind = resolve_target(g, pawn)
        local okn, n = pcall(function() return st.target and st.target:GetFullName():match("([%w_]+)$") end)
        st.target_name = type(g) == "string" and g or (okn and n) or "actor"
        st.target_spec = type(g) == "string" and g or st.target_name
        if st.target_kind == "player" then st.target_kind = "player" end
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
    st.handle = LoopInGameThreadWithDelay(1, function()
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

function M.stop(log, context)
    local st = rawget(_G,"DW_MOVE")
    if context ~= nil and st == nil then return {ok=false,reason="interrupted"} end
    st = st or S()
    local was = st.mode
    local arb=rawget(_G,"DWArbiter")
    local function context_valid()
        if context == nil then return true end
        local rec=context.record
        return arb and rawget(_G,"DWArbiter")==arb and arb.move_stop_context==context and rec and
            context.token==rec.token and rec.token==st.owner_token and (rec.state=="stopped" or rec.state=="suspended")
    end
    if not context_valid() then return {ok=false,was=was,reason="interrupted"} end
    if was == "idle" then return {ok=true,was=was} end
    local b=binding(st,st.pawn)
    local allow_nil=context ~= nil and context_valid()
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
    return { ok=ok, was=was, reason=not ok and "verification_failed" or nil }
end

-- The game's own Unstuck, through the UI a player uses: open the pause menu
-- (MainMenuUIAPI:NavigateToScreen(12 = EMainSubMenuType Pause)), complete the held Unstuck button
-- (UDomHeldProgressBarButton:HandleHeldActionCompleted, what IA_UnstuckCharacter_Held's 3 s hold
-- ends in), then Resume(). It teleports Claude to the start point (Server_TeleportToPlayerStart on
-- the game's side). Asynchronous: the result lands in _G.DW_UNSTUCK. UNTESTED LIVE until supervised.
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
        ExecuteWithDelay(4000, function() ExecuteInGameThread(function() if rawget(_G, "DW_UNSTUCK_PAUSE") then _G.DW_PAUSE = nil; _G.DW_UNSTUCK_PAUSE = nil end end) end)
        _G.DW_UNSTUCK_PAUSE = true
    end
    _G.DW_UNSTUCK = { state = "menu_requested" }
    if log then log("move: unstuck requested (pause menu)") end
    ExecuteWithDelay(700, function()
        ExecuteInGameThread(function()
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
    local hh = tonumber((pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
        and pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()) or 90
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
    return { mode = a.mode, goal = a.goal, distance_m = a.distance_m, opts = opts }
end

function M.restore(log, snap)
    if type(snap) ~= "table" or not snap.mode then return { ok = false, error = "no snapshot" } end
    local opts = {}
    for k, x in pairs(snap.opts or {}) do opts[k] = x end
    if snap.mode == "follow" then return M.follow(log, snap.goal, snap.distance_m or opts.tolerance_m or 3, opts) end
    return M.go_to(log, snap.goal, opts)
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
        hops = st.hops, water_entries = st.water_entries, in_water = st.in_water, trace_profile = PROFILE_NAME or (rawget(_G, "DW_TRACE_PROFILE") and _G.DW_TRACE_PROFILE.name),
        bug2 = st.bug and { dir = st.bug.dir, travel_m = math.floor(st.bug.travel) / 100 } or nil,
        lead = st.lead and { helper = st.lead.name, phase = st.lead.phase or "waiting" } or nil,
        memory = st.mpath and { src = st.msrc, wp = st.mwp, n = #st.mpath } or nil, trip_pts = st.trip and #st.trip,
        unreachable = st.unreach and { reason = st.unreach.reason, detail = st.unreach.detail,
            leader_pos = m3(st.unreach.leader_pos), my_pos = m3(st.unreach.my_pos) } or nil,
        unreach_episodes = st.unreach_episodes,
        aim = m3(st.aim), target_pos = m3(st.target_pos), target_kind = st.target_kind,
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
    target_above_jump_height = function(th) return be(th) .. " higher up than I can jump" end,
    leader_above_jump_height = function(th) return be(th) .. " higher up than I can jump" end,
    leader_windstepped = function(th) return (th == "you" and "you" or th) .. " Windstepped over somewhere I can't follow yet" end,
    leader_double_jumped = function(th) return (th == "you" and "you" or th) .. " double-jumped somewhere I can't follow yet" end,
    leader_far = function(th) return be(th) .. " too far away (a teleport?); I'd need a lodestone to catch up" end,
    target_not_visible = function(th) return "I can't see " .. (th == "you" and "you" or th) .. " any more" end,
    wedged = function() return "I'm wedged and can't move" end,
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
local function half_h(pawn)
    return tonumber((pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
        and pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()) or 90
end

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
