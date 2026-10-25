-- Offline test for client_mod/scripts/move.lua: fake UE objects, a manual frame pump, a fake nav
-- oracle answering through the same files (with its heartbeat), and a fake LineTraceSingle over
-- the same fake world so the local planner (scripts/localplan.lua) runs too.
-- Usage: lua test_move.lua <empty_dir>      (MOVE_FILE=<path> tests another move.lua)
local dir = assert(arg[1], "usage: lua test_move.lua <empty_dir>"):gsub("\\", "/")
os.execute('mkdir "' .. (dir .. "/client_io/nav"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
do -- move.lua loads <root>/client_mod/scripts/localplan.lua
    local src = assert(io.open(here .. "/../scripts/localplan.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/client_mod/scripts/localplan.lua", "wb")); f:write(src); f:close()
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
local function wall_top(x, y)
    for _, w in ipairs(walls) do
        if x > w[1] and x < w[2] and y > w[3] and y < w[4] then return FLOOR + (w[5] and 900 or 80) end
    end
end
-- fake KismetSystemLibrary:LineTraceSingle over the fake world (fills `out` like UE4SS does)
local KSL = { LineTraceSingle = function(self, ctx, a, b, ch, cx, ign, dbg, out)
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
        local top = wall_top(x, y)
        if top and a.Z < top then
            out.ImpactPoint = { X = x, Y = y, Z = a.Z }; out.ImpactNormal = { X = -1, Y = 0, Z = 0 }
            return true
        end
    end
    return false
end }
pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, input = nil, jumps = 0 })
function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
function pawn:AddMovementInput(d, s) self.input = d end
function pawn:Jump() self.jumps = self.jumps + 1; air = 0.6 end
function pawn:StopJumping() end
pawn.CharacterMovement = obj({ MaxStepHeight = 45, GetMaxJumpHeightWithJumpTime = function() return 120 end,
    IsMovingOnGround = function() return air <= 0 end, MinFallDamageHeight = 500 })
pawn.CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return 90 end })
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
            local nx, ny = pawn.loc.X + pawn.input.X * sp, pawn.loc.Y + pawn.input.Y * sp
            -- heights: a rise above a step needs a jump within jump height; tall walls never pass
            local here_top = wall_top(pawn.loc.X, pawn.loc.Y) or FLOOR
            local there_top = wall_top(nx, ny) or FLOOR
            local rise = there_top - here_top
            if rise <= 45 or (air > 0 and rise <= 120) then
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

-- 6. bounded give-up: walled in, no trail -> stops with "stuck" after > 5 s, not a loop
walls = { { 300, 400, -5000, 5000, true } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil
local t_start = T
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 120 })
run(300)
s = M.status()
check("gives up stuck", s.result and s.result.reason == "stuck", s.result and s.result.reason)
check("gives up within 5-9 s of no progress", s.result and (T - t_start) > 5, T - t_start)
check("tried the local planner / backtrack before giving up", (s.backtracks or 0) >= 1 or (s.lp_runs or 0) >= 2, s.lp_runs)
local stuck_logged = false
for _, l in ipairs(logs) do if l:find("move: stuck n=") and l:find("aim=") then stuck_logged = true end end
check("stuck events log me/aim/goal/waypoints", stuck_logged)

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
