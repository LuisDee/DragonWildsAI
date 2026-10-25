-- Offline test for client_mod/scripts/traverse_learn.lua (task R2.12): a fake engine with a small
-- kinematic simulator (gravity -1813 cm/s^2, jump 808 cm/s: Claude's measured envelope), scripted
-- leader tracks on a heightmap world, fake multicast hooks and a fake LineTraceSingle over the same
-- heightmap. Checks classification, clustering, verification by Claude's own crossing, the pause
-- rule, persistence + per-world isolation, the move.lua API, and rebuild from raw events.
-- Usage: lua test_traverse_learn.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_traverse_learn.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
do
    local src = assert(io.open(here .. "/../scripts/dkjson.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/client_mod/scripts/dkjson.lua", "wb")); f:write(src); f:close()
end
local real_getenv = os.getenv
os.getenv = function(k)
    if k == "DW_CLIENT_ROOT" then return dir end
    if k == "DW_WORLD_GUID" then return nil end
    return real_getenv(k)
end
local FILE = here .. "/../scripts/traverse_learn.lua"
local json = dofile(here .. "/../scripts/dkjson.lua")

local fails, passes = 0, 0
local function check(name, cond, detail)
    if cond then passes = passes + 1; print("PASS " .. name)
    else fails = fails + 1; print("FAIL " .. name .. "  " .. tostring(detail)) end
end

-- ---------------------------------------------------------------- world (feet heights, cm)
-- Lanes along +X at different Y. Ground 0 unless a lane says otherwise.
local function floor_at(x, y)
    if math.abs(y - 0) < 500 then return x >= 1000 and 120 or 0 end            -- A: 1.2 m ledge
    if math.abs(y - 4000) < 500 then                                            -- C: 3 m pit
        if x >= 1000 and x < 1300 then return -800 end
        return 0
    end
    if math.abs(y - 6000) < 500 then return x >= 1000 and 280 or 0 end         -- D: 2.8 m ledge
    if math.abs(y - 8000) < 500 then return x >= 1000 and 800 or 0 end         -- E: 8 m cliff
    if math.abs(y - 10000) < 500 then return x < 1000 and 400 or 0 end         -- F: 4 m drop
    if math.abs(y - 16000) < 500 then                                            -- I: gentle slope (+1 m over 12 m)
        return math.max(0, math.min(100, (x - 500) * 100 / 1200))
    end
    if math.abs(y - 14000) < 500 then                                            -- H: 7 m pit (double jump + CMOVE_Dash)
        if x >= 1000 and x < 1700 then return -800 end
        return 0
    end
    if math.abs(y - 12000) < 500 then                                            -- G: 2 m pit (air dash)
        if x >= 1000 and x < 1200 then return -800 end
        return 0
    end
    return 0                                                                     -- B and elsewhere: flat
end
local HH = 88
local G = 1813

-- ---------------------------------------------------------------- fake engine
local T = 100.0
local DT = 1 / 60
local reads = 0
local function obj(t)
    t.IsValid = function() return true end
    t.GetFullName = t.GetFullName or function() return "Obj /Game/x" end
    return t
end
local hooks = {}
local function make_pawn(name, x, y)
    local p = { name = name, feet = { X = x, Y = y, Z = floor_at(x, y) }, vel = { X = 0, Y = 0, Z = 0 },
                mode = 1, jc = 0, q = {}, cmd = nil }
    p.mc = obj({ MovementMode = 1, Velocity = { X = 0, Y = 0, Z = 0 } })
    p.uo = obj({
        GetFullName = function() return "BP_PlayerCharacter_C /Game/L_World.L_World:PersistentLevel.Pawn_" .. name end,
        K2_GetActorLocation = function() reads = reads + 1; return { X = p.feet.X, Y = p.feet.Y, Z = p.feet.Z + HH } end,
        CharacterMovement = p.mc,
        ReplicatedJumpCurrentCount = 0, JumpCurrentCount = 0,
        CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return HH end }),
    })
    p.magic = obj({ GetOwner = function() return p.uo end,
                    CurrentSpellActor = { Data = obj({ GetFullName = function() return "DominionUtilitySpellData /Game/Spells/USD_Windstep.USD_Windstep" end }) } })
    p.evade = obj({ GetOwner = function() return p.uo end })
    return p
end
local luis = make_pawn("Zezima", 0, 0)
luis.stale_jc = true -- like the real proxy
local claude = make_pawn("Claude", 0, -3000)
local pawns = { luis, claude }
local function ps(p, n)
    return obj({ GetFullName = function() return "BP_PlayerState_C /Game/L_World.PS_" .. n end,
                 GetPlayerName = function() return { ToString = function() return n end } end, PawnPrivate = p.uo })
end
local pc = obj({ GetFullName = function() return "BP_PlayerController_C /Game/L_World.PC_0" end,
                 IsLocalController = function() return true end, Pawn = claude.uo })
local PSS = { ps(luis, "Zezima"), ps(claude, "Claude") }
local GS = { GetRealTimeSeconds = function() return T end }
local traces = 0
local KSL = { LineTraceSingle = function(_, ctx, a, b, ch, cx, ign, dbg, out)
    traces = traces + 1
    local f = floor_at(a.X, a.Y)
    if f <= a.Z and f >= b.Z then
        out.ImpactPoint = { X = a.X, Y = a.Y, Z = f }
        out.Distance = a.Z - f
        return true
    end
    return false
end }
function FindAllOf(cls)
    if cls == "PlayerController" then return { pc } end
    if cls == "PlayerState" then return PSS end
    return {}
end
function StaticFindObject(path)
    if path:find("GameplayStatics") then return GS end
    if path:find("KismetSystemLibrary") then return KSL end
end
local loops = {}
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = fn; return #loops end
function CancelDelayedAction(h) loops[h] = false end
function RegisterHook(path, pre, post) hooks[path] = post; return 1, 2 end
local function fire(path, comp, a1) local h = hooks[path]; if h then h({ get = function() return comp end }, a1) end end
local CAST = "/Script/Dominion.PlayerMagicComponent:Multicast_SendPayloadForSpellCasting"
local EVADE = "/Script/Dominion.PlayerEvadeComponent:Multicast_StartEvade"

-- ---------------------------------------------------------------- simulator
-- commands: {"walk", to_x, speed} | {"jump", vz, vh, dj_at, evade_at} | {"wait", s} | {"tp", x, y}
--           {"cast"} (Windstep multicast now) | {"walkoff", speed} (walk +X until falling, then land)
local function push(p, ...) for _, c in ipairs({ ... }) do p.q[#p.q + 1] = c end end
local function sim(p)
    local c = p.cmd
    if not c then c = table.remove(p.q, 1); p.cmd = c; if c then c.t = T end end
    if p.mode == 6 then -- CMOVE_Dash (MOVE_Custom): flat and fast, then falling again
        p.feet.X = p.feet.X + p.vel.X * DT
        if T >= c.dash_until then p.mode = 3; p.vel = { X = 450, Y = 0, Z = 0 } end
    elseif p.mode == 3 then -- airborne
        if c and c[1] == "jump" and c[6] and not c.dashed and T - c.t >= c[6] then
            c.dashed, c.dash_until, p.mode, p.vel = true, T + 0.3, 6, { X = 1200, Y = 0, Z = 0 }
        end
        p.feet.X, p.feet.Y = p.feet.X + p.vel.X * DT, p.feet.Y + p.vel.Y * DT
        p.feet.Z = p.feet.Z + p.vel.Z * DT
        p.vel.Z = p.vel.Z - G * DT
        if c and c[1] == "jump" and c[4] and not c.dj and T - c.t >= c[4] then c.dj = true; p.vel.Z = 808; p.jc = 2 end
        if c and c[1] == "jump" and c[5] and not c.ev and T - c.t >= c[5] then c.ev = true; fire(EVADE, p.evade); p.vel.X = p.vel.X + 500 end
        local f = floor_at(p.feet.X, p.feet.Y)
        if p.vel.Z <= 0 and p.feet.Z <= f then
            -- proxies keep a STALE ReplicatedJumpCurrentCount after landing (live 19:40:48)
            p.feet.Z, p.vel, p.mode = f, { X = 0, Y = 0, Z = 0 }, 1
            if not p.stale_jc then p.jc = 0 end
            if c and (c[1] == "jump" or c[1] == "walkoff") then p.cmd = nil end
        end
    elseif c then
        if c[1] == "walk" or c[1] == "walkoff" then
            local sp = c[1] == "walk" and c[3] or c[2]
            local dir = (c[1] == "walkoff" or c[2] > p.feet.X) and 1 or -1
            local nx = p.feet.X + dir * sp * DT
            local f0, f1 = floor_at(p.feet.X, p.feet.Y), floor_at(nx, p.feet.Y)
            p.vel = { X = dir * sp, Y = 0, Z = 0 }
            if f1 - f0 > 45 then p.cmd = nil; p.vel.X = 0           -- blocked by a ledge
            elseif f0 - f1 > 45 then p.feet.X = nx; p.mode = 3          -- walked off an edge
            else
                p.feet.X, p.feet.Z = nx, f1
                if c[1] == "walk" and dir * (c[2] - p.feet.X) <= 0 then p.cmd = nil end
            end
        elseif c[1] == "jump" then
            if not c.go then c.go = true; p.mode = 3; p.jc = 1; p.vel = { X = c[3] or 0, Y = 0, Z = c[2] } end
        elseif c[1] == "wait" then
            if T - c.t >= c[2] then p.cmd = nil end
        elseif c[1] == "tp" then
            p.feet = { X = c[2], Y = c[3], Z = floor_at(c[2], c[3]) }; p.cmd = nil
        elseif c[1] == "cast" then
            fire(CAST, p.magic, { get = function() return { NetId = 77 } end }); p.cmd = nil
        end
    end
    p.mc.MovementMode, p.mc.Velocity = p.mode, { X = p.vel.X, Y = p.vel.Y, Z = p.vel.Z }
    p.mc.CustomMovementMode = p.mode == 6 and 1 or 0
    p.uo.ReplicatedJumpCurrentCount, p.uo.JumpCurrentCount = p.jc, p.jc
end
local function frame()
    T = T + DT
    for _, p in ipairs(pawns) do sim(p) end
    for _, fn in ipairs(loops) do if fn then fn() end end
end
local function run_until_idle(max_s)
    local t_end = T + (max_s or 20)
    repeat frame() until (#luis.q == 0 and not luis.cmd and #claude.q == 0 and not claude.cmd and luis.mode == 1 and claude.mode == 1) or T > t_end
    for _ = 1, 30 do frame() end
end
local function lane(p, y, x) push(p, { "tp", x or 0, y }, { "wait", 1.2 }) end

-- ---------------------------------------------------------------- run
_G.DW_LEARN, _G.DW_PAUSE = nil, nil
local logs = {}
local function log(m) logs[#logs + 1] = m; if os.getenv("DBG") then print("  " .. m) end end
local L = dofile(FILE)
L.cfg.probe_max_m = 1000 -- the fake lanes span ~190 m; the far-guard has its own case below
local r = L.start(log, { world = "testA" })
check("start ok, world from opts", r.ok and r.world == "testA" and r.world_source == "opts", r.world)
check("hooks registered (3)", hooks[CAST] and hooks[EVADE] and r.hooks.fall, r.hooks)
for _ = 1, 90 do frame() end
local st = L.status()
local tracked = {}
for _, t in ipairs(st.trackers) do tracked[t.name] = t end
check("tracks Zezima and Claude (self)", tracked.Zezima and tracked.Claude and tracked.Claude.self, json.encode(st.trackers))

-- A: jump up 1.2 m ledge, twice (second 40 cm to the side) -> one link, n_seen 2
lane(luis, 0); push(luis, { "walk", 900, 450 }, { "jump", 808, 450 }, { "wait", 0.5 })
run_until_idle()
lane(luis, 40); push(luis, { "walk", 880, 450 }, { "jump", 808, 450 }, { "wait", 0.5 })
run_until_idle()
-- B: hop on flat ground -> raw event only
lane(luis, 2000); push(luis, { "walk", 500, 450 }, { "jump", 808, 450 }, { "wait", 0.5 })
run_until_idle()
-- C: sprint jump over a 3 m pit
lane(luis, 4000); push(luis, { "walk", 950, 680 }, { "jump", 808, 680 }, { "wait", 0.5 })
run_until_idle()
-- D: double jump up a 2.8 m ledge
lane(luis, 6000); push(luis, { "walk", 900, 450 }, { "jump", 808, 450, 0.35 }, { "wait", 0.5 })
run_until_idle()
-- E: Windstep onto an 8 m cliff (cast on the ground, then a super jump)
lane(luis, 8000); push(luis, { "walk", 900, 450 }, { "cast" }, { "wait", 0.5 }, { "jump", 1750, 450 }, { "wait", 0.5 })
run_until_idle()
-- F: walk off a 4 m drop (no jump)
lane(luis, 10000, 500); push(luis, { "walkoff", 450 }, { "wait", 0.5 })
run_until_idle()
-- G: jump + evade (air dash) over a 2 m pit
lane(luis, 12000); push(luis, { "walk", 950, 450 }, { "jump", 808, 450, nil, 0.3 }, { "wait", 0.5 })
run_until_idle()
-- H: double jump + CMOVE_Dash (MOVE_Custom at the apex, like Luis live) over a 7 m pit: ONE event
lane(luis, 14000); push(luis, { "walk", 950, 680 }, { "jump", 808, 680, 0.33, nil, 0.6 }, { "wait", 0.5 })
run_until_idle()
-- I: double jump + dash up a gentle slope (live 19:43 pattern): walkable terrain, raw event only
lane(luis, 16000, 300); push(luis, { "walk", 450, 680 }, { "jump", 808, 680, 0.33, nil, 0.6 }, { "wait", 0.5 })
run_until_idle()
-- far from Claude: client collision may be unloaded there, so the gap probe is skipped (no false gaps)
L.cfg.probe_max_m = 10
lane(luis, 4000); push(luis, { "walk", 950, 680 }, { "jump", 808, 680 }, { "wait", 0.5 })
run_until_idle()
L.cfg.probe_max_m = 1000
-- teleport mid-air: aborted, no link
lane(luis, 2000); push(luis, { "walk", 300, 450 }, { "jump", 808, 450 })
for _ = 1, 140 do frame() end
for _ = 1, 15 do frame() end
luis.feet = { X = 50000, Y = 50000, Z = 0 }; luis.mode = 1; luis.vel = { X = 0, Y = 0, Z = 0 }; luis.cmd = nil; luis.q = {}
for _ = 1, 30 do frame() end

local store = L._state().store
local byid, bymove = {}, {}
for _, l in ipairs(store.links) do byid[l.id] = l; bymove[l.move .. "/" .. l.shape] = l end
if os.getenv("DBG") then for _, l in ipairs(store.links) do print(json.encode(l)) end end
local ja = bymove["jump/up"]
check("A: jump-up link, merged twice", ja and ja.n_seen == 2 and ja.status == "demonstrated" and ja.dz_m > 1.0 and ja.dz_m < 1.4,
    ja and json.encode(ja))
check("A: endpoints blended (from y ~ 0.2 m), feet level (z 0 / 1.2)", ja and math.abs(ja.from[2] - 0.2) < 0.15 and math.abs(ja.from[3]) < 0.05 and math.abs(ja.to[3] - 1.2) < 0.05, ja and json.encode({ ja.from, ja.to }))
local sj = bymove["sprint_jump/gap"]
check("C: sprint-jump gap link with width/depth", sj and sj.gap_m and sj.gap_m >= 2 and sj.gap_depth_m >= 5 and sj.needs.sprint == true,
    sj and json.encode(sj))
local dj = bymove["double_jump/up"]
check("D: double-jump link needs DoubleJump", dj and dj.needs.perks and dj.needs.perks[1] == "DoubleJump" and #dj.inputs == 2,
    dj and json.encode(dj))
local ws = bymove["windstep/up"]
check("E: windstep link (cast seen before take-off)", ws and ws.needs.spells[1] == "Windstep" and ws.inputs[1].a:find("cast:") ~= nil,
    ws and json.encode(ws))
local dr = bymove["drop/down"]
check("F: walk-off drop link, dz -4 m", dr and dr.dz_m < -3.5 and #dr.inputs == 0, dr and json.encode(dr))
local ad = bymove["air_dash/gap"]
check("G: air dash from the evade multicast", ad and ad.needs.perks[1] == "AirDash", ad and json.encode(ad))
local hd
for _, l in ipairs(store.links) do if math.abs(l.from[2] - 140) < 1 then hd = l end end
check("H: double jump + MOVE_Custom dash = one air_dash gap link", hd and hd.move == "air_dash" and hd.shape == "gap" and hd.moves.air_dash == 1 and hd.to[1] > 17, hd and json.encode(hd))
check("no link from the flat hop or the teleport (7 links)", #store.links == 7, #store.links)
st = L.status()
local walk_seen = false
for line in io.lines(L.paths("testA").events) do local e = json.decode(line); if e.why == "walkable_terrain" and e.move == "air_dash" then walk_seen = true end end
check("I: dash-hop up a gentle slope = walkable_terrain, no link", walk_seen)
local far_seen = false
for line in io.lines(L.paths("testA").events) do local e = json.decode(line); if e.gap_probe and e.gap_probe.unprobed == "far_from_claude" and e.why == "hop" then far_seen = true end end
check("far flight: probe skipped, flat flight stays a hop", far_seen)
check("counts: aborted >= 1, hop skipped", st.counts.aborted >= 1 and st.counts.events > st.counts.kept, json.encode(st.counts))

-- raw events file: one line per event, samples present
local P = L.paths("testA")
local nlines, hop_seen, with_samples = 0, false, false
for line in io.lines(P.events) do
    local ev = json.decode(line)
    nlines = nlines + 1
    if ev.why == "hop" then hop_seen = true end
    if ev.samples and #ev.samples > 5 then with_samples = true end
end
check("raw events written (incl. hop, samples)", nlines >= 9 and hop_seen and with_samples, nlines)

-- Claude crosses link A himself -> verified; Claude hopping in place -> nothing new
push(claude, { "tp", 0, 0 }, { "wait", 1.2 }, { "walk", 900, 450 }, { "jump", 808, 450 }, { "wait", 0.5 })
run_until_idle()
push(claude, { "tp", 0, -3000 }, { "wait", 1.2 }, { "jump", 808, 0 }, { "wait", 0.5 })
run_until_idle()
check("self crossing verifies link A", ja.status == "verified" and ja.n_ok == 1 and ja.n_try == 1 and ja.last_ok, json.encode(ja))
check("self hop adds no link", #store.links == 7, #store.links)

-- move.lua API
local near = L.links_near({ 9, 0.2, 0.9 }, 5)
check("links_near finds A first (metres in)", near[1] and near[1].id == ja.id and near[1].usable, near[1] and near[1].id)
local nearcm = L.links_near({ X = 900, Y = 6000, Z = 90 }, 5)
check("links_near (cm in) reports unusable double jump", nearcm[1] and nearcm[1].id == dj.id and nearcm[1].usable == false
    and nearcm[1].why == "needs:DoubleJump", nearcm[1] and json.encode(nearcm[1]))
local bl, info = L.best_link({ 5, 0, 0.9 }, { 14, 0, 2.1 })
check("best_link through A", bl and bl.id == ja.id, bl and bl.id or info)
local bl2, why2 = L.best_link({ 5, 60, 0.9 }, { 14, 60, 3.7 })
check("best_link refuses double jump for Claude today", bl2 == nil and why2 == "needs:DoubleJump", tostring(why2))
local bl3 = L.best_link({ 5, 60, 0.9 }, { 14, 60, 3.7 }, { env = { double_jump = true } })
check("best_link uses double jump when the envelope has it", bl3 and bl3.id == dj.id, bl3 and bl3.id)
for _ = 1, 3 do L.record_attempt(log, sj.id, false, "short") end
check("3 failed attempts disable a link", sj.disabled and sj.status == "disabled" and sj.n_try == 3, json.encode(sj))
check("usable() says disabled", select(2, L.usable(sj)) == "disabled")

-- pause: no engine reads while _G.DW_PAUSE
for _ = 1, 30 do frame() end
_G.DW_PAUSE = true
local r0 = reads
for _ = 1, 60 do T = T + DT; for _, fn in ipairs(loops) do if fn then fn() end end end
check("paused: no UObject reads", reads == r0 and L.status().status == "paused", reads - r0)
_G.DW_PAUSE = nil
for _ = 1, 90 do frame() end
check("resumes after pause", L.status().status == "recording" and #L.status().trackers == 2, L.status().status)

-- persistence: a fresh load (new _G state) sees the same links; another world sees none
L.save(true)
local saved = json.decode(assert(io.open(P.links)):read("a"))
check("store file written, git-friendly JSON", saved and saved.world == "testA" and #saved.links == 7 and saved.next_id == 8, saved and #saved.links)
L.stop(log)
_G.DW_LEARN = nil
local L2 = dofile(FILE)
L2.load_store("testA")
check("reload: links persisted with status", #L2._state().store.links == 7 and L2.links_near({ 9, 0.2, 0.9 }, 5)[1].status == "verified")
L2.load_store("testB")
check("per-world isolation (testB empty)", #L2._state().store.links == 0 and #L2.links_near({ 9, 0.2, 0.9 }, 50) == 0)

-- world id fallback order
_G.DW_WORLD_GUID = nil
check("world_id fallback is shockbyte", select(1, L2.world_id()) == "shockbyte" and select(2, L2.world_id()) == "fallback")
_G.DW_WORLD_GUID = "dev/../x y"
check("world_id sanitised", L2.world_id() == "devxy")
_G.DW_WORLD_GUID = nil

-- rebuild from raw events: same clusters (forget flag survives)
L2.load_store("testA")
L2.forget(log, dr.id)
local rb = L2.rebuild(log, "testA")
local s2 = L2._state().store
local nd, forgotten = 0, false
for _, l in ipairs(s2.links) do if l.move == "drop" then nd = nd + 1; forgotten = l.reason == "forgotten" end end
check("rebuild from raw events -> 7 links, forget kept", rb.ok and rb.links == 7 and nd == 1 and forgotten, json.encode(rb))

-- classification unit cases (no engine)
local function ev(t)
    return { t0 = 0, t1 = t.air or 0.8, take = { X = 0, Y = 0, Z = 88 }, land = t.land, apex_z = t.apex or 268,
             v0 = t.v0 or { X = 450, Y = 0, Z = 808 }, jc_max = t.jc or 1, casts = t.casts, evades = t.evades,
             impulses = t.imp, dashes = {}, gap = t.gap }
end
local c1 = L2.classify(ev({ land = { X = 300, Y = 0, Z = 88 } }))
check("classify: flat hop not kept", c1.shape == "flat" and not c1.keep and c1.why == "hop")
local c2 = L2.classify(ev({ land = { X = 300, Y = 0, Z = 88 }, apex = 88 + 330, jc = 1 }))
check("classify: 3.3 m rise on one jump = windstep", c2.move == "windstep", c2.move)
local c3 = L2.classify(ev({ land = { X = 300, Y = 0, Z = 88 + 250 }, apex = 88 + 330, jc = 2 }))
check("classify: 3.3 m rise with jump count 2 = double jump", c3.move == "double_jump" and c3.shape == "up", c3.move)
local c4 = L2.classify(ev({ land = { X = 300, Y = 0, Z = 88 }, air = 0.05 }))
check("classify: blip", c4.why == "blip")

-- hooks that fail at start (main menu) are retried from the tick once in the world
_G.DW_LEARN = nil
_G.DWHookHub = nil -- a fresh client process: hooks are natively registered once per process (hookhub, BUGS L24)
local real_rh = RegisterHook
RegisterHook = function() error("class not loaded") end
local L3 = dofile(FILE)
local r3 = L3.start(log, { world = "testC" })
check("start survives failing hooks", r3.ok and L3.status().hooks == 0)
RegisterHook = real_rh
for _ = 1, 60 * 11 do frame() end
check("hooks retried and registered from the tick", L3.status().hooks == 3, L3.status().hooks)

print(string.format("\n%d passed, %d failed (traces=%d)", passes, fails, traces))
os.exit(fails == 0 and 0 or 1)
