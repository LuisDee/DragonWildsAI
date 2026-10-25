-- Offline test for client_mod/scripts/move.lua: fake UE objects, a manual frame pump, a fake nav
-- oracle answering through the same files. Usage: lua test_move.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_move.lua <empty_dir>"):gsub("\\", "/")
os.execute('mkdir "' .. (dir .. "/client_io/nav"):gsub("/", "\\") .. '" 2>nul')
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/?.lua;" .. package.path

-- ---- fake engine
local T, DT = 0, 1 / 30
local function obj(t) t.IsValid = function() return true end; t.GetFullName = t.GetFullName or function() return "X /Game/x" end; return t end
local walls = {}           -- {x0,x1,y0,y1} blocks movement unless airborne
local pawn, pc, luis, settings, eis
local sprinting, injected, air = false, 0, 0
local function blocked(x, y) for _, w in ipairs(walls) do if x > w[1] and x < w[2] and y > w[3] and y < w[4] then return true end end end
pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, input = nil, jumps = 0 })
function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
function pawn:AddMovementInput(d, s) self.input = d end
function pawn:Jump() self.jumps = self.jumps + 1; air = 0.6 end
function pawn:StopJumping() end
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
function StaticFindObject() return { GetRealTimeSeconds = function() return T end } end
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(_, fn) nid = nid + 1; loops[nid] = fn; return nid end
function CancelDelayedAction(h) loops[h] = nil end
local function step(n)
    for _ = 1, n do
        T = T + DT
        pawn.input = nil
        for _, fn in pairs(loops) do fn() end
        if pawn.input then
            local sp = (sprinting and 680 or 450) * DT
            local nx, ny = pawn.loc.X + pawn.input.X * sp, pawn.loc.Y + pawn.input.Y * sp
            if air > 0 or not blocked(nx, ny) then pawn.loc.X, pawn.loc.Y = nx, ny end
        else sprinting = false end
        air = math.max(0, air - DT)
    end
end
local oracle = nil -- function(req) -> lua text, or nil for no answer
local function pump_oracle()
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
local M = dofile(here .. "/../scripts/move.lua")
local logs = {}
local function log(m) logs[#logs + 1] = m end
local function run(n) for _ = 1, n do step(3); pump_oracle() end end
local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- 1. go_to via a dog-leg nav path (wall in the straight line)
walls = { { 900, 1100, -500, 500 } }
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(100)
local s = M.status()
check("go_to arrives via waypoints", s.result and s.result.status == "arrived", s.result and s.result.status)
check("used nav", s.source == "nav", s.source)
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
local M2 = dofile(here .. "/../scripts/move.lua")
M2.stop(log)
run(5)
local n = 0; for _ in pairs(loops) do n = n + 1 end
check("no loops left after stop from a fresh load", n == 0, n)

for _, l in ipairs(logs) do if l:find("error") then print("LOG " .. l) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
