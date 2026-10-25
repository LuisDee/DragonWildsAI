-- Offline test for client_mod/commands/move_calib.lua (jump-envelope calibration): fake engine with
-- jump physics (JumpZVelocity 808, gravity 980 x 1.85, JumpMaxCount 2: a second Jump() while
-- airborne resets the vertical speed = double jump), real arbiter. Checks the flat/open spot test,
-- the arbiter take/release, and the measured file. Usage: lua test_calib.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_calib.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
for _, d in ipairs({ "/client_mod/scripts", "/data/envelopes" }) do os.execute('mkdir "' .. (dir .. d):gsub("/", "\\") .. '" 2>nul') end
do
    local src = assert(io.open(here .. "/../scripts/arbiter.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/client_mod/scripts/arbiter.lua", "wb")); f:write(src); f:close()
end
local real_getenv = os.getenv
os.getenv = function(k) if k == "DW_CLIENT_ROOT" then return dir end return real_getenv(k) end

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- ---- fake engine
local T, DT = 0, 1 / 30
local G = 980 * 1.85
local function obj(t) t.IsValid = function() return true end; t.GetFullName = t.GetFullName or function() return "X /Game/x" end; return t end
local FLOOR = 0            -- feet level when standing
local BLOCK = nil          -- optional obstacle for the open-spot test: {x0,x1,y0,y1,top}
local pawn = obj({ loc = { X = 0, Y = 0, Z = 88 }, vz = 0, jumps_in_air = 0 })
function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
local function grounded() return pawn.loc.Z <= FLOOR + 88 + 0.01 and pawn.vz <= 0 end
function pawn:Jump()
    if grounded() then self.vz = 808; self.jumps_in_air = 1
    elseif self.jumps_in_air < 2 then self.vz = 808; self.jumps_in_air = 2 end
end
function pawn:StopJumping() end
pawn.CharacterMovement = obj({ IsMovingOnGround = function() return grounded() end })
pawn.CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return 88 end })
local pc = obj({ Pawn = pawn, GetFullName = function() return "BP_PlayerController_C /Game/pc" end })
function FindAllOf(c) if c == "PlayerController" then return { pc } end return {} end
local KSL = { LineTraceSingle = function(self, ctx, a, b, ch, cx, ign, dbg, out)
    if a.X == b.X and a.Y == b.Y then
        if a.Z > b.Z and a.Z >= FLOOR then out.ImpactPoint = { X = a.X, Y = a.Y, Z = FLOOR }; out.Distance = a.Z - FLOOR; return true end
        return false -- upward (roof) traces: open sky
    end
    if BLOCK then
        for k = 0, 20 do
            local t = k / 20
            local x, y = a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t
            if x > BLOCK[1] and x < BLOCK[2] and y > BLOCK[3] and y < BLOCK[4] and a.Z < BLOCK[5] then return true end
        end
    end
    return false
end }
local GS = { GetRealTimeSeconds = function() return T end }
function StaticFindObject(p) if p:find("KismetSystemLibrary") then return KSL end return GS end
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(_, fn) nid = nid + 1; loops[nid] = fn; return nid end
function CancelDelayedAction(h) loops[h] = nil end
local function step(n)
    for _ = 1, n do
        T = T + DT
        for _, fn in pairs(loops) do fn() end
        if not grounded() or pawn.vz > 0 then
            pawn.vz = pawn.vz - G * DT
            pawn.loc.Z = pawn.loc.Z + pawn.vz * DT
            if pawn.loc.Z <= FLOOR + 88 then pawn.loc.Z, pawn.vz = FLOOR + 88, 0 end
        end
    end
end

local logs = {}
local function log(m) logs[#logs + 1] = m end
local cmd = assert(loadfile(here .. "/../commands/move_calib.lua"))()

-- 1. not open (a wall 1.5 m away at head height): refuses, takes nothing
BLOCK = { 140, 200, -300, 300, 400 }
local r = cmd(log)
check("refuses a spot that is not open", r.ok == false and tostring(r.error):find("not flat"), r.error)
BLOCK = nil
local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
check("refusal holds no arbiter slot", A.owner() == nil)

-- 2. flat and open: runs the trials and writes the measured envelope
r = cmd(log)
check("starts on a flat open spot", r.started == true, r.error)
check("takes the pawn through the arbiter", A.owner() ~= nil and A.owner().name == "calibration")
step(30 * 40)
local res = _G.DW_CALIB
check("calibration finishes", res and res.state == "done", res and res.state)
local apex = 808 * 808 / (2 * G)
check("single-jump rise measured ~ v^2/2g", res.jump_rise_min_cm and math.abs(res.jump_rise_min_cm - apex) < 15,
    tostring(res.jump_rise_min_cm) .. " vs " .. math.floor(apex))
check("double jump rises higher than a single jump", res.dj_rise_min_cm and res.dj_rise_min_cm > res.jump_rise_min_cm + 40,
    tostring(res.dj_rise_min_cm))
check("best double-jump delay is one of the tried values", res.dj_delay_s == 0.25 or res.dj_delay_s == 0.33 or res.dj_delay_s == 0.40, res.dj_delay_s)
local f = io.open(dir .. "/data/envelopes/Claude.json")
local txt = f and f:read("a"); if f then f:close() end
check("writes data/envelopes/Claude.json under DW_CLIENT_ROOT", txt and txt:find('"jump_up_m"') and txt:find('"dj_up_m"'), txt)
check("releases the pawn afterwards", A.owner() == nil, A.owner() and A.owner().name)
-- the real repo file is untouched by the test (root-relative paths)
print(string.format("measured: jump %s cm, double %s cm at %s s", tostring(res.jump_rise_min_cm), tostring(res.dj_rise_min_cm), tostring(res.dj_delay_s)))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
