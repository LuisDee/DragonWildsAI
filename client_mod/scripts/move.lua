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
--   3. Optional dev-server NAV ORACLE (tools/nav_oracle.py), used ONLY while its heartbeat file is
--      fresh (client_io/nav/alive.lua), so a missing oracle costs nothing.
--   4. Straight line to the goal.
-- Unstuck ladder: local plan -> jump -> double jump -> strafe + backtrack along our own trail.
-- Bounded: no net progress toward the goal for > give_up_s -> stop with reason "stuck".
-- Never teleports the pawn. One loop (LoopInGameThreadWithDelay(1, ...)), cancellable, and a
-- generation token so a loop from an older load of this file exits on its own.
--
-- API (all take the DWClient `log` function first):
--   M.go_to(log, goal, opts)   goal = {x,y,z} metres | "<player name>" | "<entity id>" (sense census
--                              short name, e.g. BP_AI_Kebbit_Character_02_C_2147480001) | actor UObject
--                              | {actor=obj}.  opts: tolerance_m=1.5, sprint_m=10, timeout_s=120,
--                              sprint=true, nav=nil(auto)|false, local_plan=true
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
-- Units: metres on the API (wire units), centimetres inside.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local NAV_REQ = ROOT .. "/client_io/nav/req.json"
local NAV_RESP = ROOT .. "/client_io/nav/resp.lua"
local NAV_ALIVE = ROOT .. "/client_io/nav/alive.lua"
local LP_PATH = ROOT .. "/client_mod/scripts/localplan.lua"
local TL_PATH = ROOT .. "/client_mod/scripts/traverse_learn.lua" -- learned traversal links (traversal agent)
local NM_PATH = ROOT .. "/client_mod/scripts/navmem.lua"

local M = {}

M.cfg = {
    wp_radius_cm = 120,        -- waypoint / crumb reached (2D)
    lp_radius_cm = 45,         -- local-plan point reached (cells are 1 m; 70 cut wall corners)
    sprint_on_cm = 1000,       -- sprint when the remaining distance is above this
    sprint_off_cm = 500,       -- ... and stop asking below this
    sprint_retry_s = 1.0,      -- toggle sprint: wait this long for the server ack before pressing again
    repath_goal_move_cm = 300, -- nav: a moving goal that drifted this far from the path's end -> repath
    repath_min_s = 1.0,
    nav_timeout_s = 4.0,
    nav_retry_s = 5.0,
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
    local safe_drop = num(function() return mc.MinFallDamageHeight end) or 500
    local env = { step = step, jump = apex - 15, djump = apex - 15, -- double-jump edges only once MEASURED
                  drop = math.min(1000, math.max(150, safe_drop - 50)), apex = apex, double_jump = dj, source = "engine" }
    -- MEASURED values win (client_mod/commands/move_calib.lua -> data/envelopes/Claude.json)
    local okj, J = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    local f = io.open(ROOT .. "/data/envelopes/Claude.json", "rb")
    if okj and f then
        local txt = f:read("a"); f:close()
        local okd, m = pcall(J.decode, txt)
        if okd and type(m) == "table" then
            local ju = type(m.jump_up_m) == "table" and m.jump_up_m.stand or m.jump_up_m
            if tonumber(ju) then env.jump = tonumber(ju) * 100 end
            if dj and tonumber(m.dj_up_m) then env.djump = tonumber(m.dj_up_m) * 100 end
            if not dj then env.djump = env.jump end
            if tonumber(m.dj_delay_s) then env.dj_delay_s = tonumber(m.dj_delay_s) end
            env.source = "measured " .. tostring(m.measured)
        end
    elseif f then f:close() end
    return env
end

-- ------------------------------------------------------------------ nav oracle client (optional)
local function oracle_alive()
    local chunk = loadfile(NAV_ALIVE)
    if not chunk then return false end
    local ok, t = pcall(chunk)
    return ok and type(t) == "number" and os.time() - t <= M.cfg.nav_alive_s
end

local function nav_request(st, from, to)
    st.nav_id = (st.nav_id or 0) + 1
    local body = string.format('{"id":%d,"from":[%.2f,%.2f,%.2f],"to":[%.2f,%.2f,%.2f]}',
        st.nav_id, from.X / 100, from.Y / 100, from.Z / 100, to.X / 100, to.Y / 100, to.Z / 100)
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
    st.nav_pending, st.nav_goal = st.nav_id, v(to)
    return true
end

local function nav_poll(st)
    local chunk = loadfile(NAV_RESP)
    if not chunk then return nil end
    local ok, r = pcall(chunk)
    if ok and type(r) == "table" and r.id == st.nav_pending then return r end
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

local function start_jump(st, t, pawn, double)
    if st.jump_t then return end
    pcall(function() pawn:Jump() end)
    st.jump_t, st.jump_release, st.jump_double = t, true, double
    st.jumps = (st.jumps or 0) + 1
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
local function advance(pts, i, me, radius, dz_tol, zoff)
    dz_tol, zoff = dz_tol or 60, zoff or 0
    while i <= #pts do
        local p, nxt = pts[i], pts[i + 1]
        local dz = math.abs((me.Z - zoff) - p.Z)
        if p.gap then break end -- never advance across a leader super-jump gap
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
local function nav_mem()
    local NMm = nm_module()
    if not NMm then return nil end
    local TL = tl_module()
    local world = "shockbyte"
    if TL and TL.world_id then local okw, w = pcall(TL.world_id); if okw and w then world = w end end
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
    local mem, NMm = nav_mem()
    if not mem then return end
    local changed = false
    if st.trip and #st.trip >= 2 and st.trip_ok then
        local okr, r, how = pcall(NMm.add_route, mem, st.trip, { src = "self" })
        if okr and r then changed = true; if log then log("move: memory: self route " .. tostring(r.id) .. " " .. tostring(how)) end end
    end
    if st.target_kind == "player" and st.crumbs and #st.crumbs - (st.crumb_mark or 0) >= 2 then
        local pts = {}
        for k = math.max(1, st.crumb_mark or 1), #st.crumbs do
            local c = st.crumbs[k]
            if not c.air and not c.gap then pts[#pts + 1] = { X = c.X, Y = c.Y, Z = c.Z - (st.half_h or 90) } end
        end
        st.crumb_mark = #st.crumbs
        local okr, r, how = pcall(NMm.add_route, mem, pts, { src = "demo:" .. tostring(st.target_name) })
        if okr and r then changed = true; if log then log("move: memory: leader route " .. tostring(r.id) .. " " .. tostring(how)) end end
    end
    if changed then pcall(NMm.save, mem) end
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

local function lp_begin(st, pawn, me, far, why, log)
    local LP = lp_module()
    if not LP then return false end
    local hh = tonumber((pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
        and pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()) or 90
    st.env = st.env or envelope(pawn, st.pc)
    st.lp = LP.new({ trace = make_trace(st, pawn), center = v(me), feet_z = me.Z - hh,
        radius_m = M.cfg.lp_grid_m, cell_cm = M.cfg.lp_cell_cm, env = st.env,
        cache = lp_cache(), now = function() return now(pawn) end, self_pos = v(me),
        cell_cost = function(x, y)
            local mem, NMm = nav_mem()
            return (mem and NMm.is_water(mem, { X = x, Y = y })) and M.cfg.water_cell_cost or 0
        end,
        water_probe = rawget(_G, "DW_WATER_CH") and function(x, y, floor_z)
            local c = rawget(_G, "DW_WATER_CH")
            local ok, hit, out = pcall(trace_with, c, pawn, { X = x, Y = y, Z = floor_z + 300 }, { X = x, Y = y, Z = floor_z - 50 })
            if ok and hit and out.ImpactPoint and out.ImpactPoint.Z > floor_z + 15 then
                local mem, NMm = nav_mem()
                if mem then NMm.mark_water(mem, { X = x, Y = y, Z = floor_z }) end
                return true
            end
            return false
        end or nil })
    st.lp_t0 = now(pawn)
    st.lp_far, st.lp_state, st.lp_why = v(far), "sampling", why
    st.lp_runs = (st.lp_runs or 0) + 1
    st.lp_plans_np = (st.lp_plans_np or 0) + 1
    if log then log(string.format("move: local plan #%d (%s) at %s toward %s", st.lp_runs, why, fmt(me), fmt(far))) end
    return true
end

-- One frame of planner work. Returns true while the planner owns this frame (we stand still).
local function lp_work(st, t, log)
    local P = st.lp
    if st.lp_state == "sampling" then
        if P:step(M.cfg.lp_budget) == "ready" then
            local pts, why = P:plan(st.lp_far)
            if not pts then
                st.lp, st.lp_state, st.lp_fail_t, st.lp_fail = nil, nil, t, why
                if log then log("move: local plan failed: " .. tostring(why)) end
                st.want_trail = true
                st.nav_force = true -- re-query the oracle on every local-plan failure
                return false
            end
            st.lp_pts, st.lp_state, st.lp_rounds = pts, "verifying", 0
        end
        return true
    elseif st.lp_state == "verifying" then
        local r = P:verify(st.lp_pts, M.cfg.lp_budget)
        if r == "blocked" then
            st.lp_rounds = st.lp_rounds + 1
            local pts = st.lp_rounds <= 12 and P:plan(st.lp_far) or nil
            if not pts then
                st.lp, st.lp_state, st.lp_fail_t, st.lp_fail = nil, nil, t, "verify_exhausted"
                if log then log("move: local plan failed: walls everywhere (" .. table.concat(P.block_log or {}, " ") .. ") hops=" .. tostring(P.hops) .. " steeps=" .. tostring(P.steeps) .. " firstseg=" .. tostring(P.first_blocks)) end
                st.want_trail = true
                st.nav_force = true
                return false
            end
            st.lp_pts = pts
        elseif r == "ok" then
            st.lpath, st.lwp, st.lp_state = st.lp_pts, 2, nil
            st.lp_jumped = {}
            local acts = {}
            for _, p in ipairs(st.lpath) do acts[#acts + 1] = p.act:sub(1, 1) end
            st.lp_stand_s = t - (st.lp_t0 or t)
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
local function finish(st, result, log)
    if result and result.status == "arrived" then st.trip_ok = true end
    pcall(mem_flush, st, log, result and result.status)
    st.result = result
    st.mode = "idle"
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    st.handle = nil
    if log then log("move: " .. tostring(result.status) .. " " .. tostring(result.reason or "")) end
end

-- World teardown guard: disconnect/join set _G.DW_PAUSE = true (cleared by the bridge once a new
-- pawn has been stable for 3 s). A UFunction call during teardown crashed the client (18:08:42
-- access violation), so while paused, or with an invalid controller/pawn, the loop does NOTHING.
local function paused() return rawget(_G, "DW_PAUSE") == true end

-- Only a real player CHARACTER may be driven: in the main menu (L_FrontEnd) the controller owns a
-- DefaultPawn at (0,0,0) (live 23:10: a go_to "drove" it). A player character has CharacterMovement.
local function is_character(pawn)
    if not (pawn and pawn:IsValid()) then return false end
    local ok, mc = pcall(function() return pawn.CharacterMovement end)
    return ok and mc ~= nil and mc:IsValid()
end

local function tick(st, gen, log)
    if st.gen ~= gen then return "stale" end
    if paused() then st.status = "paused"; return end
    local pc, pawn = st.pc, nil
    if not (pc and pc:IsValid()) then st.status = "paused"; return end
    pawn = pc.Pawn
    if not is_character(pawn) then st.status = "paused"; st.prog_t = nil; return end
    local t = now(pawn)
    local dt = st.last_t and (t - st.last_t) or 0
    st.last_t = t
    local me = pawn:K2_GetActorLocation()
    st.ticks = st.ticks + 1

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
    if st.dz0 == nil then st.dz0 = goal.Z - me.Z end
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
        if dist <= st.tol_cm then return finish(st, { status = "arrived", dist_m = dist / 100, s = t - st.t0 }, log) end
        if t - st.t0 > st.timeout_s then return finish(st, { status = "failed", reason = "timeout", dist_m = dist / 100 }, log) end
    else
        local hold = st.idle and (st.tol_cm + M.cfg.follow_hysteresis_cm) or st.tol_cm
        if dist <= hold then
            st.idle, st.status = true, "near"
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
                if log then log("move: entered water at " .. fmt(me) .. "; re-planning round it") end
                if st.use_lp and not st.trail_i then st.lpath, st.water_replan = nil, true end
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
    if not st.mem_checked then
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

    -- optional nav oracle (only with a live heartbeat; never waits)
    if st.use_nav ~= false then
        if st.ticks % (st.nav_live and 200 or 50) == 1 then st.nav_live = oracle_alive() end
        if st.nav_live then
            if st.nav_pending then
                if st.ticks % 4 == 0 then
                    local r = nav_poll(st)
                    if r then
                        st.nav_pending, st.nav_t = nil, t
                        if r.ok and r.points and #r.points >= 2 then
                            local pts = {}
                            for i, p in ipairs(r.points) do pts[i] = { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 } end
                            for i = 2, #pts do -- mark nav-link endpoints (rise > step over a short run)
                                if pts[i].Z - pts[i - 1].Z > 60 and d2(pts[i - 1], pts[i]) < 300 then pts[i].link = true end
                            end
                            st.path, st.wp, st.path_partial, st.path_goal = pts, 2, r.partial, st.nav_goal
                            st.nav_jumped = {}
                        else
                            st.path, st.nav_fail = nil, r.reason or "no_path"
                        end
                    elseif t - st.nav_sent_t > M.cfg.nav_timeout_s then
                        st.nav_pending, st.nav_t, st.nav_fail = nil, t, "oracle_timeout"
                    end
                end
            else
                local since = t - (st.nav_t or -100)
                local need = not st.nav_t or (not st.path and since > M.cfg.nav_retry_s)
                    or (st.path and st.path_goal and d2(st.path_goal, goal) > M.cfg.repath_goal_move_cm and since > M.cfg.repath_min_s)
                local far = dist > M.cfg.oracle_primary_cm or (goal.Z - me.Z) > ((st.env and st.env.jump or 165) + 20)
                if st.nav_force then need, st.nav_force = true, false end
                if need and (far or (not st.trail_i and not st.lpath)) and nav_request(st, me, goal) then
                    st.nav_sent_t = t
                    st.nav_requests = (st.nav_requests or 0) + 1
                end
            end
        else
            st.path = nil
        end
    end

    -- leader breadcrumbs: when the straight/nav route is failing
    local path = st.path
    if st.target and not st.trail_i and #st.crumbs >= 2 then
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
                start_jump(st, t, pawn, L.move == "double_jump" and st.env and st.env.double_jump)
                lx.phase, lx.t_jump = "air", t
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
            st.lwp = advance(st.lpath, st.lwp, me, M.cfg.lp_radius_cm, math.max((st.env and st.env.step or 45) + 20, 60), st.half_h or 90)
            if st.lwp > i0 then
                idx_progress = true
                for k = i0, st.lwp - 1 do
                    local pt = st.lpath[k]
                    if k > 1 and (pt.act == "jump" or pt.act == "djump" or pt.act == "drop") then
                        pcall(emit_self_edge, st, st.lpath[k - 1], pt, pt.act)
                    end
                end
            end
            if st.lwp > #st.lpath then
                st.lpath = nil -- segment done; the forward probe re-plans if still blocked
            else
                local p = st.lpath[st.lwp]
                aim, src = p, "local"
                -- jump edges: take off AT the edge start (within 50 cm of the previous point) while
                -- moving toward the landing point; re-armed after 1.5 s if we are still not up
                if (p.act == "jump" or p.act == "djump") then
                    local prev = st.lpath[st.lwp - 1]
                    local last = st.lp_jumped[st.lwp]
                    if prev and d2(me, prev) < 50 and (not last or t - last > 1.5) then
                        st.lp_jumped[st.lwp] = t
                        start_jump(st, t, pawn, p.act == "djump" and st.env and st.env.double_jump)
                    elseif prev and d2(me, prev) >= 50 and not last and d2(me, p) > d2(prev, p) then
                        aim = prev -- walk to the take-off spot first
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
                    for k = st.trail_i, #st.crumbs do
                        if not st.crumbs[k].air then break end
                        st.trail_jumped[st.crumbs[k]] = true
                    end
                    start_jump(st, t, pawn, false)
                    st.trail_jumps = (st.trail_jumps or 0) + 1
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
                        st.mem_jumped[st.mwp] = t
                        start_jump(st, t, pawn, false)
                    elseif d2(me, prevp) >= 60 and not last and d2(me, mp) > d2(prevp, mp) then
                        aim = { X = prevp.X, Y = prevp.Y, Z = prevp.Z + (st.half_h or 90) }
                    end
                end
            end
        end
        if not st.lpath and not st.trail_i and not st.mpath and path then
            local i0 = st.wp
            st.wp = advance(path, st.wp, me, M.cfg.wp_radius_cm, math.max((st.env and st.env.step or 45) + 20, 60), st.half_h or 90)
            if st.wp > i0 then idx_progress = true end
            if st.wp <= #path then
                aim, src = path[st.wp], "nav"
                -- an oracle segment that rises more than a step over a short run is a nav LINK (the
                -- dev navmesh's auto-generated jump links, bGenerateNavLinks): jump from its start
                local prev = path[st.wp - 1]
                if prev and aim.link then
                    local last = st.nav_jumped[st.wp]
                    if d2(me, prev) < 60 and (not last or t - last > 1.5) then
                        st.nav_jumped[st.wp] = t
                        start_jump(st, t, pawn, false)
                        st.link_jumps = (st.link_jumps or 0) + 1
                    elseif d2(me, prev) >= 60 and not last and d2(me, aim) > d2(prev, aim) then
                        aim = prev -- reach the take-off spot first
                    end
                end
            end
        end
    end
    st.source, st.aim = src, aim

    local dx, dy = aim.X - me.X, aim.Y - me.Y
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 1 then dx, dy, dl = goal.X - me.X, goal.Y - me.Y, math.max(dist, 1) end
    dx, dy = dx / dl, dy / dl
    if st.strafe_until and t < st.strafe_until then
        dx, dy = dx * 0.3 + st.strafe_dir * -dy, dy * 0.3 + st.strafe_dir * dx
    end

    -- far goal for the local planner: a crumb a little ahead on the trail, else the goal
    local function far_goal()
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
    if st.use_lp and st.ticks % M.cfg.prefetch_every == 0 then
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
                        start_jump(st, t, pawn, false)
                        st.hops = (st.hops or 0) + 1
                        if log then log("move: hop over a low obstacle") end
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
        if not low and not st.lpath and not st.in_water and dist > 1000 and not st.trail_i then
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
    pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
    if st.hold_gap then
        st.hold_gap = nil
        st.move_acc, st.bt_tested = M.cfg.self_stuck_cm, t -- holding on purpose: not wedged
    else
        pawn:AddMovementInput({ X = dx, Y = dy, Z = 0 }, 1.0, false)
        st.status = "moving"
    end

    -- sprint: far from the goal, only while making progress on the ground, never on a local path
    if dist > M.cfg.sprint_on_cm and st.sprint then st.sprint_want = true
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

    -- jump sequencing: release after 0.25 s; double jump 0.35 s after the first
    if st.jump_t then
        if st.jump_release and t - st.jump_t > 0.25 then pcall(function() pawn:StopJumping() end); st.jump_release = false end
        if st.jump_double and t - st.jump_t > ((st.env and st.env.dj_delay_s) or 0.33) then
            pcall(function() pawn:Jump() end); st.jump_double = false; st.jump_t2 = t; st.double_jumps = (st.double_jumps or 0) + 1
        end
        if st.jump_t2 and t - st.jump_t2 > 0.25 then pcall(function() pawn:StopJumping() end); st.jump_t2 = nil end
        if t - st.jump_t > 1.2 then st.jump_t = nil end
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
                    st.stepoff_tried = true
                    st.stepoff = { i = 0, t0 = t, start = v(me), yaw0 = math.deg(math.atan(goal.Y - me.Y, goal.X - me.X)) }
                    start_jump(st, t, pawn, false)
                    if log then log("move: perched on geometry; stepping off") end
                    planned = true
                end
            end
            if st.use_lp and not planned and n == 1 and t - (st.lp_fail_t or -100) > M.cfg.lp_cooldown_s and st.lp_plans_np < M.cfg.lp_max_plans then
                st.lpath = nil
                planned = lp_begin(st, pawn, me, far_goal(), "stuck", log)
            end
            if not planned then
                st.env = st.env or envelope(pawn, pc)
                start_jump(st, t, pawn, n >= 2 and st.env.double_jump)
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
    if st.handle then pcall(CancelDelayedAction, st.handle) end
    local pc = local_pc()
    local pawn = pc and pc.Pawn
    if not is_character(pawn) then return { ok = false, error = "no player character (main menu / loading?)" } end
    if st.mode ~= "idle" then pcall(mem_flush, st, log, "interrupted") end
    local gen = st.gen + 1
    local keep = { gen = gen, nav_id = st.nav_id, eis = st.eis, pts = st.pts }
    for k in pairs(st) do st[k] = nil end
    for k, x in pairs(keep) do st[k] = x end
    st.mode, st.pc, st.ticks, st.stuck_n = mode, pc, 0, 0
    st.crumbs, st.self_crumbs, st.lp_plans_np, st.trail_jumped, st.nav_jumped = {}, {}, 0, {}, {}
    st.half_h = tonumber((pcall(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
        and pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()) or 90
    st.t0 = now(pawn)
    st.tol_cm = (opts.tolerance_m or 1.5) * 100
    st.timeout_s = opts.timeout_s or 120
    st.sprint = opts.sprint ~= false
    st.use_nav = opts.nav
    st.use_lp = opts.local_plan ~= false and M.cfg.lp_enabled
    st.allow_unstuck = opts.allow_unstuck
    if opts.sprint_m then M.cfg.sprint_on_cm = opts.sprint_m * 100; M.cfg.sprint_off_cm = math.min(M.cfg.sprint_off_cm, opts.sprint_m * 50) end
    st.face_when_near = opts.face_when_near

    local g = opts.goal
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
    st.args = { mode = mode, goal = st.goal and { g[1], g[2], g[3] } or st.target_spec,
                distance_m = mode == "follow" and opts.tolerance_m or nil, opts = oc }
    st.handle = LoopInGameThreadWithDelay(1, function()
        if paused() then return end
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
    if was ~= "idle" then pcall(mem_flush, st, log, "stopped") end
    st.gen = st.gen + 1 -- any running loop exits on its next frame even if the cancel misses
    finish(st, { status = "stopped" }, log)
    pcall(function() local pc = local_pc(); if pc and pc.Pawn then pc.Pawn:StopJumping() end end)
    return { ok = true, was = was }
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
    }
end

return M
