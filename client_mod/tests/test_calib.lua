-- Offline test for client_mod/commands/move_calib.lua (jump-envelope calibration): fake engine with
-- jump physics (JumpZVelocity 808, gravity 980 x 1.85, JumpMaxCount 2: a second Jump() while
-- airborne resets the vertical speed = double jump), real arbiter. Checks the flat/open spot test,
-- the arbiter take/release, and the measured file. Usage: lua test_calib.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_calib.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
for _, d in ipairs({ "/client_mod/scripts", "/data/envelopes" }) do os.execute('mkdir "' .. (dir .. d):gsub("/", "\\") .. '" 2>nul') end
do
    for _, name in ipairs({ "arbiter.lua", "dkjson.lua" }) do
        local src = assert(io.open(here .. "/../scripts/" .. name, "rb")):read("a")
        local f = assert(io.open(dir .. "/client_mod/scripts/" .. name, "wb")); f:write(src); f:close()
    end
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
local forced_air, no_landing = false, false
function pawn:Jump()
    if no_landing then forced_air = true end
    if grounded() then self.vz = 808; self.jumps_in_air = 1; self.JumpCurrentCount = 1
    elseif self.jumps_in_air < 2 then
        self.double_tries = (self.double_tries or 0) + 1
        if not self.ignore_double and not (self.partial_double and self.double_tries % 2 == 0) then
            self.vz = 808; self.jumps_in_air = 2; self.JumpCurrentCount = 2
        end
    end
end
function pawn:StopJumping() end
pawn.CharacterMovement = obj({ IsMovingOnGround = function() return not forced_air and grounded() end })
pawn.CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return 88 end })
local count_value, count_mode, count_changed = 0, "normal", 0
setmetatable(pawn, {
    __index = function(_, key)
        if key == "JumpCurrentCount" then
            if count_mode == "error" then error("count unavailable") end
            if count_mode == "stale" then return 1 end
            if count_mode == "late" and count_value == 2 and T - count_changed < 0.4 then return 1 end
            return count_value
        end
    end,
    __newindex = function(obj, key, value)
        if key == "JumpCurrentCount" then count_value, count_changed = value, T else rawset(obj, key, value) end
    end,
})
pawn.DoubleJumpSkillPerk = {}; pawn.JumpCurrentCount = 0
local perk_unlocked = true
local pc = obj({ Pawn = pawn, SkillPerkComponent = { IsPerkUnlocked = function() return perk_unlocked end }, GetFullName = function() return "BP_PlayerController_C /Game/pc" end })
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
            if pawn.loc.Z <= FLOOR + 88 then pawn.loc.Z, pawn.vz, pawn.JumpCurrentCount = FLOOR + 88, 0, 0 end
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

local path = dir .. "/data/envelopes/Claude.json"
local function contents() local x = assert(io.open(path, "rb")); local v = x:read("a"); x:close(); return v end
local function put(v) local x = assert(io.open(path, "wb")); x:write(v); x:close() end
local function trial()
    pawn.loc.Z, pawn.vz, pawn.JumpCurrentCount = FLOOR + 88, 0, 0
    local r = cmd(log); check("integrity: starts", r.started == true, r.error)
    step(30 * 40)
    return _G.DW_CALIB
end
local json = assert(loadfile(dir .. "/client_mod/scripts/dkjson.lua"))()
put('{"sentinel":{"x":42},"windstep_up_m":7.25,"dj_up_m":4.5,"measurement_provenance":{"windstep_up_m":{"note":"prior"},"dj_up_m":{"note":"old"}}}')
perk_unlocked = false
res = trial(); local doc = json.decode(contents())
check("locked perk skips double trials and preserves prior data", #res.trials == 3 and res.double_perk == "locked" and doc.dj_up_m == 4.5 and doc.windstep_up_m == 7.25 and doc.sentinel.x == 42)
check("single measurement does not bless prior double or Windstep", doc.measurement_provenance.dj_up_m.note == "old" and doc.measurement_provenance.windstep_up_m.note == "prior" and doc.measurement_provenance["jump_up_m.stand"].verified == true)
perk_unlocked = true; pawn.ignore_double = true
res = trial(); doc = json.decode(contents())
check("ignored second jump is unverified and preserves prior double", res.state == "done" and res.dj_rise_min_cm == nil and doc.dj_up_m == 4.5 and doc.measurement_provenance.dj_up_m.note == "old")
pawn.ignore_double = false
count_mode = "error"; res = trial(); doc = json.decode(contents())
check("unreadable jump count cannot certify double", res.state == "done" and res.dj_rise_min_cm == nil and doc.dj_up_m == 4.5)
count_mode = "stale"; res = trial(); doc = json.decode(contents())
check("stale jump count cannot certify double", res.state == "done" and res.dj_rise_min_cm == nil and doc.dj_up_m == 4.5)
count_mode = "late"; res = trial(); doc = json.decode(contents())
check("late jump count cannot certify double", res.state == "done" and res.dj_rise_min_cm == nil and doc.dj_up_m == 4.5)
count_mode = "normal"; pawn.partial_double = true; pawn.double_tries = 0
res = trial(); doc = json.decode(contents())
check("partial samples cannot certify double", res.state == "done" and res.dj_rise_min_cm == nil and doc.dj_up_m == 4.5)
pawn.partial_double = false
put('{broken')
res = trial()
check("malformed envelope is preserved with error", res.state == "error" and contents() == '{broken' and A.owner() == nil, res.err)
put('{"sentinel":17}')
forced_air = true
res = trial(); forced_air = false
check("ground wait timeout releases lease and timer without saving", res.state == "error" and res.err:find("grounded start not confirmed") and A.owner() == nil and _G.DW_CALIB_H == nil and next(loops) == nil and contents() == '{"sentinel":17}', res.err)
no_landing = true
res = trial(); no_landing, forced_air = false, false
check("no landing then ground wait timeout releases lease without saving", res.state == "error" and res.trials[1] and res.trials[1].error == "no landing" and res.err:find("grounded state not confirmed after trial") and A.owner() == nil and _G.DW_CALIB_H == nil and next(loops) == nil and contents() == '{"sentinel":17}', res.err)
local original_open = io.open
io.open = function(name, mode)
    if name == path and mode == "rb" then return nil, "access denied", 13 end
    return original_open(name, mode)
end
res = trial(); io.open = original_open
check("read access failure preserves envelope", res.state == "error" and contents() == '{"sentinel":17}' and A.owner() == nil, res.err)
local saved_perk = pc.SkillPerkComponent
pc.SkillPerkComponent = nil
res = trial(); pc.SkillPerkComponent = saved_perk
check("missing perk data does not schedule double trials", res.state == "done" and res.double_perk == "unknown" and #res.trials == 3)
put('{"sentinel":17}')
io.open = function(name, mode)
    if mode == "wb" and name:find("%.tmp%-") then return nil, "write denied", 13 end
    return original_open(name, mode)
end
res = trial(); io.open = original_open
check("temporary write failure preserves envelope", res.state == "error" and contents() == '{"sentinel":17}' and A.owner() == nil, res.err)
local original_rename = os.rename
os.rename = function(from, to)
    if from:find("%.tmp%-") then return nil, "injected install failure" end
    return original_rename(from, to)
end
res = trial(); os.rename = original_rename
check("install failure rolls back and reports error", res.state == "error" and contents() == '{"sentinel":17}' and A.owner() == nil, res.err)
os.rename = function(from, to)
    if from:find("%.tmp%-") or from:find("%.bak%-") then return nil, "injected rename failure" end
    return original_rename(from, to)
end
res = trial(); os.rename = original_rename
check("rollback failure identifies recoverable backup", res.state == "error" and res.err:find("rollback failed") and res.err:find("recover from") and A.owner() == nil, res.err)
local backup = res.err:match("recover from (.+)$")
local backup_file = backup and io.open(backup, "rb")
check("rollback failure retains original backup", backup_file and backup_file:read("a") == '{"sentinel":17}')
if backup_file then backup_file:close() end
-- the real repo file is untouched by the test (root-relative paths)
print(string.format("measured: jump %s cm, double %s cm at %s s", tostring(res.jump_rise_min_cm), tostring(res.dj_rise_min_cm), tostring(res.dj_delay_s)))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
