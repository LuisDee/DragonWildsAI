-- Offline test for client_mod/scripts/move.lua: fake UE objects, a manual frame pump, a fake nav
-- oracle answering through the same files (with its heartbeat), and a fake LineTraceSingle over
-- the same fake world so the local planner (scripts/localplan.lua) runs too.
-- Usage: lua test_move.lua <empty_dir>      (MOVE_FILE=<path> tests another move.lua)
local dir = assert(arg[1], "usage: lua test_move.lua <empty_dir>"):gsub("\\", "/")
os.execute('mkdir "' .. (dir .. "/client_io/nav"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
do -- move.lua loads <root>/client_mod/scripts/{localplan,navmem,dkjson}.lua
    for _, n in ipairs({ "localplan.lua", "navmem.lua", "dkjson.lua" }) do
        local src = assert(io.open(here .. "/../scripts/" .. n, "rb")):read("a")
        local f = assert(io.open(dir .. "/client_mod/scripts/" .. n, "wb")); f:write(src); f:close()
    end
    os.execute('mkdir "' .. (dir .. "/data/nav"):gsub("/", "\\") .. '" 2>nul')
end
package.path = here .. "/?.lua;" .. package.path

-- ---- fake engine
local T, DT = 0, 1 / 30
local function obj(t) t.IsValid = function() return true end; t.GetFullName = t.GetFullName or function() return "X /Game/x" end; return t end
local walls = {}           -- {x0,x1,y0,y1[,tall]}: short (80 cm, jumpable) or tall (9 m)
local FLOOR = -90
local pawn, pc, luis, settings, eis
local sprinting, injected, air = false, 0, 0
local function blocked(x, y, airborne)
    for _, w in ipairs(walls) do
        if x > w[1] and x < w[2] and y > w[3] and y < w[4] and (w[5] or not airborne) then return true end
    end
end
local frame_hook = nil
local raised = {}          -- {x0,x1,y0,y1, h0, h1}: floor raised by h0..h1 cm (linear along x) = plateau / ramp
local lakes = {}           -- {x0,x1,y0,y1}: shallow water (EnvironmentComponent depth 0.6, slow walking)
local function in_lake(x, y) for _, l in ipairs(lakes) do if x > l[1] and x < l[2] and y > l[3] and y < l[4] then return true end end end
local portals = {}         -- {x,y}: airborne within 1.5 m of one may rise up to 7 m (a learned link's take-off)
local function wall_top(x, y)
    for _, r in ipairs(raised) do
        if x > r[1] and x < r[2] and y > r[3] and y < r[4] then
            return FLOOR + r[5] + (r[6] - r[5]) * (x - r[1]) / (r[2] - r[1])
        end
    end
    for _, w in ipairs(walls) do
        if x > w[1] and x < w[2] and y > w[3] and y < w[4] then return FLOOR + (w[5] and 900 or 80) end
    end
end
-- Claude's attached gear: bIgnoreSelf ignores his pawn but NOT his armour/tool actors (live 19:22)
local GEAR = false
local function in_gear(x, y, z)
    return GEAR and math.sqrt((x - pawn.loc.X) ^ 2 + (y - pawn.loc.Y) ^ 2) < 40 and z > pawn.loc.Z - 90 and z < pawn.loc.Z + 90
end
-- fake KismetSystemLibrary:LineTraceSingle over the fake world (fills `out` like UE4SS does)
-- fake water surface: Visibility (ch 0) vertical traces stop at the lake surface; the pawn profile
-- (LineTraceSingleByProfile) and object-type traces pass through to the bed
local function fake_water(a, b, out)
    if a.X == b.X and a.Y == b.Y and in_lake(a.X, a.Y) and a.Z > FLOOR + 50 then
        out.Distance = a.Z - (FLOOR + 50); out.ImpactPoint = { X = a.X, Y = a.Y, Z = FLOOR + 50 }; out.ImpactNormal = { X = 0, Y = 0, Z = 1 }
        return true
    end
end
local KSL_BASE
local KSL = {}
-- like the engine: an unknown profile name ("Custom" = per-channel responses, not a preset) is
-- "not found" and the trace returns NO hit (live bug 2026-10-25 21:33)
local VALID_PROFILES = { Player = true, Pawn = true }
local profile_not_found = 0
KSL.LineTraceSingleByProfile = function(self, ctx, a, b, prof, cx, ign, dbg, out)
    local n = type(prof) == "table" and prof.name or tostring(prof)
    if not VALID_PROFILES[n] then profile_not_found = profile_not_found + 1; return false end
    return KSL_BASE(self, ctx, a, b, 99, cx, ign, dbg, out)
end
KSL.LineTraceSingleForObjects = function(self, ctx, a, b, ots, cx, ign, dbg, out) return KSL_BASE(self, ctx, a, b, 99, cx, ign, dbg, out) end
KSL.LineTraceSingle = function(self, ctx, a, b, ch, cx, ign, dbg, out)
    if ch == 0 and fake_water(a, b, out) then return true end
    return KSL_BASE(self, ctx, a, b, ch, cx, ign, dbg, out)
end
KSL_BASE = function(self, ctx, a, b, ch, cx, ign, dbg, out)
    if a.X == b.X and a.Y == b.Y and GEAR and math.sqrt((a.X - pawn.loc.X) ^ 2 + (a.Y - pawn.loc.Y) ^ 2) < 40 and a.Z > pawn.loc.Z then
        out.Distance = a.Z - (pawn.loc.Z + 90); out.ImpactPoint = { X = a.X, Y = a.Y, Z = pawn.loc.Z + 90 }; out.ImpactNormal = { X = 0, Y = 0, Z = 1 }
        return true -- a downward trace through Claude lands on his head/gear
    end
    if a.X == b.X and a.Y == b.Y then
        local top = wall_top(a.X, a.Y) or FLOOR
        -- like the real client: bStartPenetrating is junk (always true), Distance 0 = started inside
        out.bStartPenetrating = true
        if a.Z < top then out.Distance = 0; out.ImpactPoint = { X = a.X, Y = a.Y, Z = a.Z }; return true end
        out.Distance = a.Z - top
        out.ImpactPoint = { X = a.X, Y = a.Y, Z = top }; out.ImpactNormal = { X = 0, Y = 0, Z = 1 }
        return true
    end
    for k = 0, 30 do
        local t = k / 30
        local x, y = a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t
        if in_gear(x, y, a.Z) then
            out.Distance = (k == 0) and 0 or 1; out.ImpactPoint = { X = x, Y = y, Z = a.Z }; out.ImpactNormal = { X = -1, Y = 0, Z = 0 }
            return true
        end
        local top = wall_top(x, y)
        if top and a.Z < top then
            out.ImpactPoint = { X = x, Y = y, Z = a.Z }; out.ImpactNormal = { X = -1, Y = 0, Z = 0 }
            return true
        end
    end
    return false
end
pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, input = nil, jumps = 0 })
function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
function pawn:AddMovementInput(d, s) self.input = d end
function pawn:Jump() self.jumps = self.jumps + 1; air = 0.6; self.jump_origin = { X = self.loc.X, Y = self.loc.Y } end
function pawn:StopJumping() end
pawn.CharacterMovement = obj({ MaxStepHeight = 45, GetMaxJumpHeightWithJumpTime = function() return 120 end,
    IsMovingOnGround = function() return air <= 0 end, MinFallDamageHeight = 500 })
pawn.CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return 90 end,
    GetCollisionProfileName = function() return { ToString = function() return "Custom" end } end })
pawn.EnvironmentComponent = obj({ GetNormalizedWaterDepth = function() return in_lake(pawn.loc.X, pawn.loc.Y) and 0.6 or 0 end })
local water_frames = 0
pawn.SprintComponent = obj({ SprintInputAction = obj({}), IsSprinting = function() return sprinting end })
pc = obj({ Pawn = pawn, IsLocalController = function() return true end, SetControlRotation = function() end, GetFullName = function() return "PC /Game/pc" end })
luis = obj({ loc = { X = 3000, Y = 0, Z = 0 } })
luis.K2_GetActorLocation = pawn.K2_GetActorLocation
local ps_luis = obj({ GetPlayerName = function() return { ToString = function() return "Zezima" end } end, PawnPrivate = luis, GetFullName = function() return "PS /Game/ps" end })
settings = obj({ bPressToSprint = true })
eis = obj({ InjectInputVectorForAction = function(self, a, v) injected = injected + 1; sprinting = true end })
function FindAllOf(c)
    if c == "PlayerController" then return { pc } elseif c == "PlayerState" then return { ps_luis } end
    return {}
end
function FindFirstOf(c)
    if c == "DominionUserSettings" then return settings elseif c == "EnhancedInputLocalPlayerSubsystem" then return eis end
end
function FName(n) return { name = n } end -- UE4SS global (move.lua traces by the pawn's collision profile)
local GSF = { GetRealTimeSeconds = function() return T end }
function StaticFindObject(path) if path and path:find("KismetSystemLibrary") then return KSL end return GSF end
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(_, fn) nid = nid + 1; loops[nid] = fn; return nid end
function CancelDelayedAction(h) loops[h] = nil end
local function step(n)
    for _ = 1, n do
        T = T + DT
        pawn.input = nil
        if frame_hook then frame_hook() end
        for _, fn in pairs(loops) do fn() end
        if pawn.input then
            local sp = (sprinting and 680 or 450) * DT
            if in_lake(pawn.loc.X, pawn.loc.Y) then sp = 150 * DT; water_frames = water_frames + 1 end
            local nx, ny = pawn.loc.X + pawn.input.X * sp, pawn.loc.Y + pawn.input.Y * sp
            -- heights: a rise above a step needs a jump within jump height; tall walls never pass
            local here_top = wall_top(pawn.loc.X, pawn.loc.Y) or FLOOR
            local there_top = wall_top(nx, ny) or FLOOR
            local rise = there_top - here_top
            local near_portal = false
            local jo = pawn.jump_origin
            for _, pt in ipairs(portals) do
                if jo and math.sqrt((jo.X - pt[1]) ^ 2 + (jo.Y - pt[2]) ^ 2) < 60 then near_portal = true end
            end
            if rise <= 45 or (air > 0 and rise <= 120) or (air > 0 and near_portal and rise <= 700) then
                pawn.loc.X, pawn.loc.Y, pawn.loc.Z = nx, ny, there_top + 90
            end
        else sprinting = false end
        air = math.max(0, air - DT)
    end
end
local oracle = nil -- function(req) -> lua text, or nil for no answer
local function pump_oracle()
    if oracle then
        local hb = io.open(dir .. "/client_io/nav/alive.lua", "w"); hb:write("return " .. os.time()); hb:close()
    else
        os.remove(dir .. "/client_io/nav/alive.lua")
    end
    local f = io.open(dir .. "/client_io/nav/req.json"); if not f then return end
    local s = f:read("a"); f:close()
    local id = tonumber(s:match('"id":(%d+)'))
    if oracle and id then
        local w = io.open(dir .. "/client_io/nav/resp.lua", "w"); w:write(oracle(id)); w:close()
    end
end

-- ---- load the module with the test dir as root
local real_getenv = os.getenv
os.getenv = function(k) if k == "DW_CLIENT_ROOT" then return dir end return real_getenv(k) end
local MOVE = real_getenv("MOVE_FILE") or (here .. "/../scripts/move.lua")
local M = dofile(MOVE)
local logs = {}
local function log(m) logs[#logs + 1] = m end
local function run(n) for _ = 1, n do step(3); pump_oracle() end end
local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- 1. go_to via a dog-leg nav path (wall in the straight line)
walls = { { 900, 1100, -500, 500 } }
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
pump_oracle() -- heartbeat first, as with a running helper
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(100)
local s = M.status()
check("go_to arrives via waypoints", s.result and s.result.status == "arrived", s.result and s.result.status)
local saw_nav = false
for _, l in ipairs(logs) do if l:find("src=nav") then saw_nav = true end end
check("used nav waypoints (oracle heartbeat live)", (s.nav_requests or 0) >= 1 and saw_nav, s.nav_requests); if os.getenv("DBG") then for _, l in ipairs(logs) do print("  " .. l) end; print(pawn.loc.X, pawn.loc.Y) end
check("sprint injected", injected > 0, injected)

-- 2. no oracle -> straight line fallback, wall -> stuck ladder jumps over it
walls = { { 900, 1000, -500, 500 } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil; pawn.jumps = 0
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(150)
s = M.status()
check("straight fallback", s.source == "straight", s.source)
check("jumped when stuck", (s.jumps or 0) >= 1, s.jumps)
check("arrived after unstuck", s.result and s.result.status == "arrived", s.result and s.result.reason)

-- 3. follow a moving player, idle when near, stop
walls = {}; pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 3000, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',points={}}"):format(id) end
M.follow(log, "Zezima", 3)
run(100)
s = M.status()
check("follow reached and idles", s.status == "near" and s.dist_m <= 4.1, s.status .. " " .. tostring(s.dist_m))
luis.loc = { X = 3000, Y = 2500, Z = 0 }
run(100)
s = M.status()
check("follow tracks moved target", s.dist_m <= 4.1, s.dist_m)
local r = M.stop(log)
local before = { X = pawn.loc.X }
run(20)
check("stop halts", r.was == "follow" and M.status().mode == "idle" and pawn.loc.X == before.X)

-- 4. stale loop from an older load exits
M.go_to(log, { 100, 0, 0 }, {})
local M2 = dofile(MOVE)
M2.stop(log)
run(5)
local n = 0; for _ in pairs(loops) do n = n + 1 end
check("no loops left after stop from a fresh load", n == 0, n)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 5. breadcrumbs: a tall wall the dev navmesh doesn't know; nav gives a partial path into it;
--    the leader walks around the wall's end; Claude must retrace the leader's trail
walls = { { 900, 1100, -2000, 600, true } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 200, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
local route = { { 200, 0 }, { 200, 1000 }, { 2000, 1000 }, { 2000, 0 } }
local seg = 1
frame_hook = function()
    local tgt = route[seg + 1]
    if not tgt then return end
    local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
    local d = math.sqrt(dx * dx + dy * dy)
    local sp = 400 * DT
    if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg = seg + 1
    else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
end
M.follow(log, "Zezima", 3)
run(400)
s = M.status()
local dl = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
check("breadcrumbs: reached leader around the wall", dl < 450, string.format("d=%.0f status=%s res=%s", dl, tostring(s.status), tostring(s.result and s.result.reason)))
check("breadcrumbs or local planner routed around it", (s.trail_entries or 0) >= 1 or (s.lp_runs or 0) >= 1, s.trail_entries)
M.stop(log)
frame_hook = nil

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 6. bounded give-up: walled in, no trail -> stops with "stuck" after > 5 s, not a loop
walls = { { 300, 400, -5000, 5000, true } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil
luis.loc = { X = 90000, Y = 90000, Z = 0 } -- nobody near to lead us out
local t_start = T
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 120 })
run(1200)
s = M.status()
check("go_to gives up (stuck or unreachable)", s.result and (s.result.reason == "stuck" or s.result.reason == "unreachable"), s.result and s.result.reason)
check("gives up after > 5 s, bounded (ladder incl. Bug2 both sides)", s.result and (T - t_start) > 5, T - t_start)
check("tried the local planner / backtrack before giving up", (s.backtracks or 0) >= 1 or (s.lp_runs or 0) >= 2, s.lp_runs)
local stuck_logged = false
for _, l in ipairs(logs) do if l:find("move: stuck n=") and l:find("aim=") then stuck_logged = true end end
check("stuck events log me/aim/goal/waypoints", stuck_logged)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 8. leader on a 6 m plateau reached by a ramp ~23 m away (outside the 9 m planner window):
--    the local plan must fail as "unreachable", and Claude must retrace the leader's trail up
walls = {}; oracle = nil
raised = { { 1000, 4000, -1000, 3000, 600, 600 },        -- plateau, 6 m high, x >= 10 m
           { 100, 1000, 2200, 2600, 0, 600 } }            -- ramp up to it from ground level, far north (y 22-26 m)
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 0, Y = 300, Z = 0 }
local route2 = { { 0, 300 }, { 0, 2400 }, { 1600, 2400 }, { 1600, 0 } }
local seg2 = 1
frame_hook = function()
    local tgt = route2[seg2 + 1]
    if tgt then
        local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
        local d = math.sqrt(dx * dx + dy * dy)
        local sp = 400 * DT
        if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg2 = seg2 + 1
        else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
    end
    luis.loc.Z = (wall_top(luis.loc.X, luis.loc.Y) or FLOOR) + 90
end
M.follow(log, "Zezima", 3)
run(500)
s = M.status()
local dl = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
check("leader on a plateau: reached him via his trail", dl < 450 and math.abs(pawn.loc.Z - luis.loc.Z) < 60,
    string.format("d=%.0f dz=%.0f status=%s res=%s trail=%s lp_fail=%s", dl, pawn.loc.Z - luis.loc.Z, tostring(s.status),
        tostring(s.result and s.result.reason), tostring(s.trail_entries), tostring(s.lp_fail)))
check("plateau: trail used", (s.trail_entries or 0) >= 1, s.trail_entries); if os.getenv("DBG8") then for i = math.max(1, #logs - 40), #logs do print("  " .. logs[i]) end end
M.stop(log)
frame_hook = nil
raised = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 9. persistent follow: the leader Windsteps onto a plateau Claude can't reach (no ramp), so
--    follow goes "unreachable" (once, with reason leader_windstepped), then he jumps back down
--    and follow resumes by itself
walls = {}; oracle = nil
raised = { { 1000, 4000, -1000, 3000, 600, 600 } }
local ev_path = dir .. "/client_io/events/move.jsonl"
os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
os.remove(ev_path)
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 300, Y = 0, Z = 0 }
local lground = true
luis.CharacterMovement = obj({ IsMovingOnGround = function() return lground end })
M.follow(log, "Zezima", 3)
run(30)
-- windstep: airborne, rises 8 m, lands on the plateau at x = 1500
local ws = 0
frame_hook = function()
    ws = ws + 1
    if ws <= 60 then
        lground = false
        luis.loc.X = 300 + ws * 20; luis.loc.Z = math.min(800, ws * 25)
    elseif ws == 61 then
        lground = true; luis.loc.X = 1500; luis.loc.Z = 600 + 90
    end
end
run(250)
s = M.status()
if os.getenv("DBG9") then for i = math.max(1, #logs - 25), #logs do print("  " .. logs[i]) end end
check("follow goes unreachable instead of ending", s.mode == "follow" and s.status == "unreachable", tostring(s.mode) .. " " .. tostring(s.status))
check("unreachable reason = leader_windstepped", s.unreachable and s.unreachable.reason == "leader_windstepped", s.unreachable and s.unreachable.reason)
local n_ev = 0
local fe = io.open(ev_path)
if fe then for l in fe:lines() do if l:find('"type":"unreachable"') then n_ev = n_ev + 1 end end; fe:close() end
check("one unreachable event per episode", n_ev == 1, n_ev)
-- he jumps back down near Claude
frame_hook = nil
luis.loc = { X = 600, Y = 300, Z = 0 }
run(120)
s = M.status()
check("follow resumes by itself when he comes back", s.mode == "follow" and s.status == "near", tostring(s.status))
M.stop(log)
luis.CharacterMovement = nil
raised = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 10. oracle path with an auto-generated nav LINK (a 1 m step up): jump from the take-off point.
--     Local planner off so only the nav-link logic can get us up.
walls = {}
raised = { { 500, 3000, -1000, 1000, 100, 100 } }
pawn.loc = { X = 0, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{4.8,0,-0.9},{5.3,0,0.1},{10,0,0.1}}}"):format(id) end
pump_oracle()
M.go_to(log, { 10, 0, 1.0 }, { tolerance_m = 1, local_plan = false })
run(150)
s = M.status()
check("nav link: jumped up the step and arrived", s.result and s.result.status == "arrived" and (s.link_jumps or 0) >= 1,
    tostring(s.result and s.result.status) .. " link_jumps=" .. tostring(s.link_jumps))
raised = {}; oracle = nil

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 11. world-teardown guard: while _G.DW_PAUSE is set, the loop makes no engine calls at all
walls = {}; oracle = nil
pawn.loc = { X = 0, Y = 0, Z = 0 }
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
_G.DW_PAUSE = true
local calls = 0
local real_add = pawn.AddMovementInput
pawn.AddMovementInput = function(self, d, sc) calls = calls + 1; return real_add(self, d, sc) end
run(30)
check("paused: no movement input / no engine calls", calls == 0 and pawn.loc.X == 0, calls)
check("paused: start() refuses", not M.go_to(log, { 1, 1, 0 }, {}).ok)
_G.DW_PAUSE = nil
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(100)
if os.getenv("DBG11") then for i = math.max(1, #logs - 12), #logs do print("  " .. logs[i]) end; print("POS", pawn.loc.X, pawn.loc.Y, "walls", #walls, "raised", #raised) end
check("unpaused: moves again", M.status().result and M.status().result.status == "arrived", M.status().status)
pawn.AddMovementInput = real_add

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 12. learned traversal links (traverse_learn.lua API): Luis on a 6 m plateau, no ramp; a learned
--     "jump" link exists at x = 9 m (only there can you get up). Expect: give-up -> best_link ->
--     approach -> jump at link.from -> landing verified -> record_attempt(ok) -> follow reaches him.
local tl_src = [[
local M = {}
_G.TL_ATTEMPTS = {}
function M.best_link(from, to, opts)
    if _G.TL_MODE == "needs" then return nil, "needs:DoubleJump" end
    return { id = "L1", move = "sprint_jump", from = { 5, 0, -0.9 }, to = { 8.6, 0, 5.1 }, runup_m = 3, needs = { sprint = true }, cost_m = 12 }, {}
end
function M.record_attempt(log, id, ok, reason) _G.TL_ATTEMPTS[#_G.TL_ATTEMPTS + 1] = { id = id, ok = ok, reason = reason } end
return M
]]
do local f = io.open(dir .. "/client_mod/scripts/traverse_learn.lua", "w"); f:write(tl_src); f:close() end
local M3 = dofile(MOVE) -- fresh module instance: picks up the fake traverse_learn.lua
walls = {}; oracle = nil
raised = { { 800, 4000, -1000, 1000, 600, 600 } }
portals = { { 500, 0 } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 1500, Y = 0, Z = 690 }
_G.TL_MODE = "link"
M3.follow(log, "Zezima", 3)
run(500)
s = M3.status()
if os.getenv("DBG12") then for i = math.max(1, #logs - 8), #logs do print("  " .. logs[i]) end; local q = M3.status(); print("ST", q.mode, q.status, q.lp_state, q.stuck_n, q.ticks, q.source, pawn.loc.X, pawn.loc.Z, T) end
local att = (_G.TL_ATTEMPTS or {})[1]
check("learned link tried and recorded ok", att and att.id == "L1" and att.ok == true, att and tostring(att.reason))
check("follow reached the leader via the link", s.status == "near", tostring(s.status) .. " z=" .. pawn.loc.Z)
M3.stop(log)
-- needs:X becomes the unreachable reason
_G.TL_MODE = "needs"
pawn.loc = { X = 0, Y = 0, Z = 0 }
local M4 = dofile(MOVE)
M4.follow(log, "Zezima", 3)
run(400)
s = M4.status()
check("unreachable reason = needs:DoubleJump", s.unreachable and s.unreachable.reason == "needs:DoubleJump", s.unreachable and s.unreachable.reason)
M4.stop(log)
os.remove(dir .. "/client_mod/scripts/traverse_learn.lua")
raised, portals = {}, {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 13. self-collision regression (live 19:22): with Claude's gear blocking traces, an open-field
--     go_to must not see "walls" around him (no endless wall_ahead plans, no "walls everywhere")
GEAR = true
walls = { { 900, 1000, -300, 300 } } -- one real (jumpable) obstacle so a plan is needed
oracle = nil; raised = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }
local nlog0 = #logs
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(200)
s = M.status()
local plans, everywhere = 0, false
for i = nlog0 + 1, #logs do
    if logs[i]:find("local plan #") then plans = plans + 1 end
    if logs[i]:find("walls everywhere") then everywhere = true end
end
if os.getenv("DBG13") then for i = nlog0 + 1, #logs do print("  " .. logs[i]) end end
check("gear: arrives in the open", s.result and s.result.status == "arrived", s.result and s.result.status)
check("gear: no 'walls everywhere', few plans", not everywhere and plans <= 3, "plans=" .. plans)
GEAR = false
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 14. cliff + far ramp, plain go_to (no leader trail): the ORACLE route around must lead; the local
--     planner may only handle the obstacle in front of the next waypoint (live 19:44: it fought the cliff)
walls = {}
raised = { { 1000, 4000, -1000, 3000, 600, 600 }, { 100, 1000, 2200, 2600, 0, 600 } }
pawn.loc = { X = 0, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{0,24,-0.9},{5,24,2.1},{10,24,5.1},{16,24,5.1},{15,0,5.1}}}"):format(id) end
pump_oracle()
M.go_to(log, { 15, 0, 6.0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(600)
s = M.status()
check("cliff: go_to reaches the plateau via the oracle route", s.result and s.result.status == "arrived",
    tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason))
raised = {}; oracle = nil

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 15. NAVIGATION MEMORY: a walled pit (respawn trap) whose only exit is 15 m north, outside the
--     9 m planner window; the goal is east, beyond the east wall.
local PIT = { { 300, 400, -2000, 1500, true }, { -400, -300, -2000, 1500, true }, { -400, 400, -400, -300, true } }
local function pit_world() walls = PIT; raised = {}; oracle = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil end
local seedf = dir .. "/data/nav/L_World_seeds.json"
local memf = dir .. "/data/skills/shockbyte/nav_memory.json"
os.remove(memf); _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
-- (a) seeded trap: the seed's exit gets him out
do local f = io.open(seedf, "w"); f:write([==[{"v":1,"traps":[{"id":"pit","center":[0,0,-0.9],"radius_m":5,"z_max":0.5,"z_min":-3,
  "exit":[[0,8,-0.9],[0,16,-0.9],[0,18,-0.9]]}],"taboos":[],"routes":[]}]==]); f:close() end
pit_world()
local MN = dofile(MOVE)
MN.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(500)
s = MN.status()
if os.getenv("DBG15") then for i = math.max(1, #logs - 30), #logs do print("  " .. logs[i]) end end
check("memory (a): seeded trap exit gets him out of the pit", s.result and s.result.status == "arrived", tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason))
MN.stop(log)
-- (b) no seed: go_to fails; Luis leads him out (follow); the exit is learned; then go_to works alone
os.remove(seedf); os.remove(memf); _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
pit_world()
luis.loc = { X = 90000, Y = 90000, Z = 0 } -- nobody near to lead (else the go_to waits for a lead)
local MB = dofile(MOVE)
MB.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60 })
run(400)
s = MB.status()
check("memory (b1): without memory the pit go_to fails", s.result and s.result.status == "failed", s.result and s.result.status)
check("memory (b1): a trap candidate was noted", _G.DW_TRAP_CAND ~= nil)
luis.loc = { X = 0, Y = 200, Z = 0 }
local route3 = { { 0, 200 }, { 0, 1800 }, { 1500, 1800 }, { 2000, 0 } }
local seg3 = 1
frame_hook = function()
    local tgt = route3[seg3 + 1]
    if not tgt then return end
    local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
    local d = math.sqrt(dx * dx + dy * dy)
    local sp = 350 * DT
    if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg3 = seg3 + 1
    else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
end
MB.follow(log, "Zezima", 3)
run(500)
frame_hook = nil
MB.stop(log)
local learned_trap = false
for _, l in ipairs(logs) do if l:find("memory: trap") then learned_trap = true end end
if os.getenv("DBG15") then for i = math.max(1, #logs - 30), #logs do print("  " .. logs[i]) end; print("CAND", _G.DW_TRAP_CAND and _G.DW_TRAP_CAND.at.X, _G.DW_TRAP_CAND and _G.DW_TRAP_CAND.at.Y, "pawn", pawn.loc.X, pawn.loc.Y) end
check("memory (b2): following him out learned the trap exit", learned_trap)
local fm = io.open(memf)
check("memory (b2): saved to data/skills/<world>/nav_memory.json", fm ~= nil)
if fm then fm:close() end
-- (b3) back in the pit, fresh module + memory reloaded from disk: go_to gets out unaided
_G.DW_NAVMEM = nil
pit_world()
local MB2 = dofile(MOVE)
MB2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(500)
s = MB2.status()
if os.getenv("DBG15") then for i = math.max(1, #logs - 14), #logs do print("  " .. logs[i]) end; local fm2 = io.open(memf); if fm2 then print("MEM", (fm2:read("a"):gsub("%s+", " "):sub(1, 900))); fm2:close() end end
check("memory (b3): learned exit -> unaided go_to out of the pit", s.result and s.result.status == "arrived", tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason))
MB2.stop(log)
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 16. BUG2: a 34 m tall wall across the way, its north end 14 m off (outside the 9 m planner window),
--     no oracle, no memory, nobody to ask: wall-following rounds it and the go_to arrives
walls = { { 500, 600, -2000, 1400, true } }
raised = {}; oracle = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MB2b = dofile(MOVE)
MB2b.go_to(log, { 15, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(900)
s = MB2b.status()
local bug_used = false
for _, l in ipairs(logs) do if l:find("bug2 wall%-following") then bug_used = true end end
check("bug2: rounds a long wall and arrives", s.result and s.result.status == "arrived" and bug_used,
    tostring(s.result and s.result.status) .. " bug=" .. tostring(bug_used))
MB2b.stop(log)
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 17. ASK FOR HELP: in the pit with Luis near: "lead_me" event, go_to waits, Luis walks out, Claude
--     follows his trail, then carries on to the goal by himself (one go_to, one result)
local evf = dir .. "/client_io/events/move.jsonl"
os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
os.remove(evf)
walls = PIT; raised = {}; oracle = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = -150, Y = 300, Z = 0 }
local MH = dofile(MOVE)
MH.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 300 })
local waited = false
for _ = 1, 160 do run(5); if MH.status().status == "waiting_for_lead" then waited = true; break end end
check("help: go_to waits for a lead", waited, MH.status().status)
local nask = 0
local fe2 = io.open(evf)
if fe2 then for l in fe2:lines() do if l:find('"type":"stuck"') and l:find('"ask":"lead_me"') then nask = nask + 1 end end; fe2:close() end
check("help: one lead_me event", nask == 1, nask)
local route4 = { { -150, 300 }, { 0, 1800 }, { 1500, 1800 }, { 2000, 0 } }
local seg4 = 1
frame_hook = function()
    local tgt = route4[seg4 + 1]
    if not tgt then return end
    local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
    local d = math.sqrt(dx * dx + dy * dy)
    local sp = 300 * DT
    if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg4 = seg4 + 1
    else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
end
run(700)
frame_hook = nil
s = MH.status()
check("help: led out, then the same go_to arrives", s.result and s.result.status == "arrived",
    tostring(s.result and s.result.status) .. " " .. tostring(s.status))
MH.stop(log)
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 18. FELLED LOG: a 50 cm log across the whole way (no way round): hop it, don't plan around it
walls = { { 900, 960, -5000, 5000 } } -- short wall = jumpable (fake: 80 cm)
raised = {}; oracle = nil; lakes = {}
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 0 }
local ML = dofile(MOVE)
local t_log = T
ML.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60 })
run(300)
s = ML.status()
check("log: hops the felled log and arrives quickly", s.result and s.result.status == "arrived" and (T - t_log) < 30,
    tostring(s.result and s.result.status) .. string.format(" t=%.0f", T - t_log))
ML.stop(log)
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 19. WATER: a lake straight across the way; the first crossing learns the water cells (persisted),
--     the second trip goes round (less time in water)
lakes = { { 500, 1500, -500, 500 } }
walls = {}; raised = {}; oracle = nil
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MW = dofile(MOVE)
water_frames = 0
MW.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(600)
local w1 = water_frames
s = MW.status()
check("water: first trip arrives (wading) and learns the lake", s.result and s.result.status == "arrived" and (s.water_entries or 0) >= 1,
    tostring(s.result and s.result.status) .. " entries=" .. tostring(s.water_entries))
MW.stop(log)
_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil -- reload memory from disk
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MW2 = dofile(MOVE)
water_frames = 0
MW2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120 })
run(600)
local w2 = water_frames
if os.getenv("DBG19") then for _, l in ipairs(logs) do if l:find("water sense") then print("  WS " .. l) end end; for i = math.max(1, #logs - 14), #logs do print("  " .. logs[i]) end; local mem = _G.DW_NAVMEM; local n = 0; for _ in pairs(mem and mem.water or {}) do n = n + 1 end; print("WATER cells", n) end
s = MW2.status()
check("water: second trip goes round (less wading)", s.result and s.result.status == "arrived" and w2 < w1 * 0.5,
    string.format("w1=%d w2=%d %s", w1, w2, tostring(s.result and s.result.status)))
MW2.stop(log)
lakes = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 20. TRACE PROFILE regression: the capsule reports "Custom" (not a preset); traces must not use it
--     (the engine finds no such profile and returns no hit), but a validated preset ("Player"), and
--     Visibility when no preset validates
walls = { { 900, 1000, -300, 300, true } }; raised = {}; oracle = nil; lakes = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 90000, Y = 90000, Z = 0 }
profile_not_found = 0
_G.DW_TRACE_PROFILE = nil
local MP = dofile(MOVE)
MP.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60 })
run(400)
s = MP.status()
check("profile: never traces with the capsule's 'Custom' name", profile_not_found == 0, profile_not_found)
check("profile: a validated preset is used", s.trace_profile == "Player", tostring(s.trace_profile))
check("profile: planning works (arrives round the wall)", s.result and s.result.status == "arrived", s.result and s.result.status)
MP.stop(log)
VALID_PROFILES = {} -- a game with neither preset: fall back to Visibility, still plans
_G.DW_TRACE_PROFILE = nil -- a new client run re-validates
_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MP2 = dofile(MOVE)
MP2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60 })
run(400)
s = MP2.status()
check("profile: no preset -> Visibility fallback, still arrives", s.trace_profile == "visibility" and s.result and s.result.status == "arrived",
    tostring(s.trace_profile) .. " " .. tostring(s.result and s.result.status))
MP2.stop(log)
VALID_PROFILES = { Player = true, Pawn = true }
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/shockbyte/nav_memory.json")
-- 21. MAIN MENU: the controller's pawn is a DefaultPawn (no CharacterMovement) -> refuse / pause
local real_cm = pawn.CharacterMovement
pawn.CharacterMovement = nil
local MM = dofile(MOVE)
local rr = MM.go_to(log, { 5, 0, 0 }, {})
check("menu: refuses to drive a non-character pawn", rr.ok == false, rr.error)
pawn.CharacterMovement = real_cm

-- 7. arbiter hooks: actor target ({actor=obj}), snapshot/restore, face_when_near
walls = {}; pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 1500, Y = 0, Z = 0 }; oracle = nil
M.follow(log, { actor = luis }, 2, { sprint = true, face_when_near = true })
run(80)
s = M.status()
check("follows an actor target", s.target_kind == "actor" and s.status == "near", tostring(s.target_kind) .. " " .. tostring(s.status))
local snap = M.snapshot()
check("snapshot is plain and replayable", snap and snap.mode == "follow" and type(snap.goal) == "string" and snap.distance_m == 2, snap and tostring(snap.goal))
M.stop(log)
check("snapshot nil when idle", M.snapshot() == nil)
M.go_to(log, { 3, 4, 0 }, { tolerance_m = 1 })
local snap2 = M.snapshot()
M.stop(log)
local r = M.restore(log, snap2)
check("restore re-issues go_to", r.ok and M.status().mode == "go_to" and snap2.goal[1] == 3, snap2 and snap2.mode)
M.stop(log)

for _, l in ipairs(logs) do if l:find("error") then print("LOG " .. l) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
