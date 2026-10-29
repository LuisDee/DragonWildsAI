-- Offline test for client_mod/scripts/move.lua: fake UE objects, a manual frame pump, a fake nav
-- oracle answering through the same files (with its heartbeat), and a fake LineTraceSingle over
-- the same fake world so the local planner (scripts/localplan.lua) runs too.
-- Usage: lua test_move.lua <empty_dir>      (MOVE_FILE=<path> tests another move.lua)
local dir = assert(arg[1], "usage: lua test_move.lua <empty_dir>"):gsub("\\", "/")
os.execute('mkdir "' .. (dir .. "/client_io/nav"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
do -- move.lua loads <root>/client_mod/scripts/{localplan,navmem,dkjson}.lua
    for _, n in ipairs({ "localplan.lua", "navmem.lua", "dkjson.lua", "avoidzones.lua", "arbiter.lua", "move.lua", "walk_guard.lua", "sampled_ground_walk.lua" }) do
        local src = assert(io.open(here .. "/../scripts/" .. n, "rb")):read("a")
        local f = assert(io.open(dir .. "/client_mod/scripts/" .. n, "wb")); f:write(src); f:close()
    end
    local native=assert(io.open(here..'/fakes/walk_sense.lua','rb')):read('a')
    local nf=assert(io.open(dir..'/client_mod/scripts/walk_sense.lua','wb'));nf:write(native);nf:close()
    os.execute('mkdir "' .. (dir .. "/data/nav"):gsub("/", "\\") .. '" 2>nul')
    os.execute('mkdir "' .. (dir .. "/mod/body"):gsub("/", "\\") .. '" 2>nul')
    local util = assert(io.open(here .. "/../../mod/body/util.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/mod/body/util.lua", "wb")); f:write(util); f:close()
end
_G.DW_WORLD_GUID = "test-world"
package.path = here .. "/?.lua;" .. package.path

-- ---- fake engine
local T, DT = 0, 1 / 30
local function obj(t) t.IsValid = function() return true end; t.GetFullName = t.GetFullName or function() return "X /Game/x" end; return t end
local walls = {}           -- {x0,x1,y0,y1[,tall]}: short (80 cm, jumpable) or tall (9 m)
local FLOOR = -90
local pawn, pc, luis, settings, eis
local sprinting, injected, air = false, 0, 0
local walking_speed = 450
local function blocked(x, y, airborne)
    for _, w in ipairs(walls) do
        if x > w[1] and x < w[2] and y > w[3] and y < w[4] and (w[5] or not airborne) then return true end
    end
end
local frame_hook = nil
local motor = nil -- optional independent acceleration/braking model for coarse-cadence cases
local raised = {}          -- {x0,x1,y0,y1, h0, h1}: floor raised by h0..h1 cm (linear along x) = plateau / ramp
local lakes = {}           -- {x0,x1,y0,y1}: shallow water (EnvironmentComponent depth 0.6, slow walking)
local function in_lake(x, y) for _, l in ipairs(lakes) do if x > l[1] and x < l[2] and y > l[3] and y < l[4] then return true end end end
local portals = {}         -- {x,y}: airborne within 1.5 m of one may rise up to 7 m (a learned link's take-off)
HAS_DJ = false             -- the double-jump perk: a 2nd Jump() while airborne allows a 2.6 m rise
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
_G.TEST_WALK_NATIVE={normal=function(x,y)
 for _,r in ipairs(raised) do
  if x>r[1] and x<r[2] and y>r[3] and y<r[4] then
   local slope=(r[6]-r[5])/(r[2]-r[1]);local length=math.sqrt(1+slope*slope)
   return {X=-slope/length,Y=0,Z=1/length}
  end
 end
 return {X=-1,Y=0,Z=0}
end,
 floor=function(at)
  local z=wall_top(at.X,at.Y) or FLOOR
  local d=at.Z-90-z
  local function known(v) return {known=true,value=v} end
  return {status='observed',consumed=1,callbacks=1,fields={bBlockingHit=known(d<=47.4),
   bWalkableFloor=known(d>=-1 and d<=47.4),bLineTrace=known(false),FloorDist=known(d),LineDist=known(0),
   hit={bStartPenetrating=known(d < -1),bBlockingHit=known(d<=47.4)}}}
 end,
 sweep=function(a,b)
  for k=0,24 do
   local f=k/24;local x,y,z=a.X+(b.X-a.X)*f,a.Y+(b.Y-a.Y)*f,a.Z+(b.Z-a.Z)*f
   local top=wall_top(x,y)
   if top and z-90<top-1 then return true end
  end
  return false
 end}
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
            out.ImpactPoint = { X = x, Y = y, Z = a.Z }; out.ImpactNormal = TEST_WALK_NATIVE.normal(x,y)
            return true
        end
    end
    return false
end
pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, input = nil, jumps = 0 })
function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
function pawn:AddMovementInput(d, s) self.input = d end
function pawn:Jump()
    self.jumps = self.jumps + 1
    if air > 0 then self.dbl = true else self.dbl = false; self.jump_origin = { X = self.loc.X, Y = self.loc.Y } end
    air = 0.6
end
function pawn:StopJumping() end
pawn.CharacterMovement = obj({ MaxStepHeight = 45, GetMaxJumpHeightWithJumpTime = function() return 120 end,
    IsMovingOnGround = function() return air <= 0 end, MinFallDamageHeight = 500 })
pawn.HealthComponent = obj({ IsDead = function() return false end, GetAuthoritativeHealth = function() return 100 end })
pawn.CapsuleComponent = obj({ GetScaledCapsuleHalfHeight = function() return 90 end,
    GetCollisionProfileName = function() return { ToString = function() return "Custom" end } end })
pawn.EnvironmentComponent = obj({ GetNormalizedWaterDepth = function() return in_lake(pawn.loc.X, pawn.loc.Y) and 0.6 or 0 end })
local water_frames = 0
pawn.SprintComponent = obj({ SprintInputAction = obj({}), IsSprinting = function() return sprinting end })
function pawn.SprintComponent:TryRequestStopSprinting() sprinting=false end
pc = obj({ Pawn = pawn, IsLocalController = function() return true end, SetControlRotation = function() end, GetFullName = function() return "PC /Game/pc" end })
pc.SkillPerkComponent = obj({ IsPerkUnlocked = function(self, perk) return HAS_DJ end })
pawn.DoubleJumpSkillPerk = obj({})
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
        local scheduled={}
        for id, fn in pairs(loops) do scheduled[#scheduled+1]={id=id,fn=fn} end
        for _, item in ipairs(scheduled) do if loops[item.id]==item.fn then item.fn() end end
        if motor then motor(DT,pawn.input)
        elseif pawn.input then
            local sp = (sprinting and 680 or walking_speed) * DT
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
            if rise <= 45 or (air > 0 and rise <= 120) or (air > 0 and pawn.dbl and HAS_DJ and rise <= 260) or (air > 0 and near_portal and rise <= 700) then
                pawn.loc.X, pawn.loc.Y, pawn.loc.Z = nx, ny, there_top + 90
            end
        else sprinting = false end
        air = math.max(0, air - DT)
    end
end
local oracle = nil -- function(req) -> lua text, or nil for no answer
local function fake_nonce(n) return ("22222222-2222-4222-8222-%012x"):format(n) end
local offer = { no=1, nonce=fake_nonce(1), epoch="11111111-1111-4111-8111-111111111111" }
do local wire_offer = os.getenv("MOVE_ORACLE_OFFER_FILE")
if wire_offer then
    local offered = assert(assert(loadfile(wire_offer))())
    assert(offered.version == 2 and offered.state == "offered")
    offer.epoch, offer.nonce = assert(offered.epoch), assert(offered.nonce)
end
end
local function pump_oracle()
    if oracle then
        local hb = io.open(dir .. "/client_io/nav/alive.lua", "w")
        hb:write(('return {version=2,epoch="%s",state="offered",nonce="%s",updated=%d}'):format(offer.epoch, offer.nonce, os.time())); hb:close()
    else
        os.remove(dir .. "/client_io/nav/alive.lua")
    end
    local f = io.open(dir .. "/client_io/nav/req.json"); if not f then return end
    local s = f:read("a"); f:close()
    local id = tonumber(s:match('"id":(%d+)'))
    local nonce = s:match('"nonce":"([^"]+)"')
    if oracle and id and nonce == offer.nonce then
        local raw = oracle(id)
        if not raw then return end
        local response = raw:gsub('^return%s*{', ('return {version=2,epoch="%s",nonce="%s",'):format(offer.epoch, nonce))
        local w = io.open(dir .. "/client_io/nav/resp.lua", "w"); w:write(response); w:close()
        offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
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
local function check(name, c, info)
 if c then print('ok   '..name) else
  fails=fails+1;print('FAIL '..name..' '..tostring(info))
  if os.getenv('DBG_MOVE_FAILURES')=='1' then
   local st=_G.DW_MOVE
   print('detail '..tostring(st.result and st.result.detail)..' terrain '..tostring(st.walk_failure)..' guard '..tostring(st.walk_report and st.walk_report.reason))
   for i=math.max(1,#logs-7),#logs do print('  '..logs[i]) end
  end
 end
end

function NATIVE_SEGMENT_CASES()
 -- Independent supported terrain descends 1.2m below a sparse native chord.
 -- Actual mover, oracle admission, guard and sampler run without progress hooks.
 -- Conceptual surface-vs-corner precedent:
 -- https://raw.githubusercontent.com/recastnavigation/recastnavigation/v1.6.0/DetourCrowd/Source/DetourPathCorridor.cpp
 local seed=dir..'/data/nav/L_World_seeds.json'
 local memory=dir..'/data/skills/test-world/nav_memory.json'
 local saved_dt,saved_speed=DT,walking_speed;DT=0.1;walking_speed=150
 local old_ground=pawn.CharacterMovement.IsMovingOnGround
 local old_input=pawn.AddMovementInput
 local function begin(goal_z)
  M.stop(log);motor=nil;frame_hook=nil;air=0;walls={};lakes={};sprinting=false
  pawn.loc={X=0,Y=0,Z=0};pawn.AddMovementInput=old_input
  pawn.CharacterMovement.IsMovingOnGround=old_ground
  raised={{-1,600.001,-500,500,0,-120},{600,1600.001,-500,500,-120,-120},{1600,3001,-500,500,-120,0}}
  _G.DW_NAVMEM=nil;_G.DW_TRAP_CAND=nil;_G.DW_LP_CACHE=nil;_G.DW_WORLD_GUID='test-world';_G.DW_LIFE=nil
  os.remove(seed);os.remove(memory)
  offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no)
  oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{30,0,-0.9}}}'):format(id) end
  pump_oracle();M.go_to(log,{30,0,goal_z or 0},{sprint=false,local_plan=false,tolerance_m=0.5,timeout_s=90})
  local st=_G.DW_MOVE;st.walk_guarded=true -- same execution mode as memory→native live transition
  return st
 end
 local q=begin();local started=q.t0;local holds,clear_below,credits=0,0,0;local last=0
 for _=1,900 do
  step(1);pump_oracle()
  if q.status=='checking_terrain' then holds=holds+1 end
  if q.source=='nav' and q.walk_report and q.walk_report.status=='clear' and pawn.loc.Z < -70 then clear_below=clear_below+1 end
  if q.prog_pos.X>last then credits=credits+1;last=q.prog_pos.X end
  if q.result or q.backtrack_until or q.bug then break end
 end
 print('native uneven replay x='..pawn.loc.X..' progress='..q.prog_pos.X..' credits='..credits..' holds='..holds..' below_clear='..clear_below..' recovery='..tostring(q.backtrack_until or q.bug)..' terminal='..tostring(q.result and q.result.status))
 check('uneven native leg retains observed progress without false recovery',q.result and q.result.status=='arrived' and not q.backtrack_until and not q.bug and credits>3 and clear_below>5 and holds>5,q.status)
 check('native liveness preserves original deadline and endpoint',q.t0==started and q.timeout_s==90 and q.goal.X==3000 and q.path and q.path[2].Z==-90)
 if os.getenv('MOVE_NATIVE_SEGMENT_REPLAY_ONLY')=='1' then return end
 -- Real guard must reject missing support, blocked/unknown observations and air.
 for _,kind in ipairs({'air','blocked','unknown','no_input','wrong_floor'}) do
  q=begin(kind=='wrong_floor' and 5 or 0);local floor,sweep=TEST_WALK_NATIVE.floor,TEST_WALK_NATIVE.sweep
  if kind=='air' then pawn.CharacterMovement.IsMovingOnGround=function() return false end
  elseif kind=='blocked' then TEST_WALK_NATIVE.sweep=function() return true end
  elseif kind=='unknown' then TEST_WALK_NATIVE.floor=function() return {status='unknown',consumed=1} end
  elseif kind=='no_input' then pawn.AddMovementInput=function() end
  end
  for _=1,(kind=='wrong_floor' and 900 or 120) do step(1);pump_oracle();if q.result or q.backtrack_until or q.bug then break end end
  check('native '..kind..' cannot manufacture progress or arrival',not (q.result and q.result.status=='arrived') and
   (kind=='wrong_floor' and math.abs(pawn.loc.X-3000)<=50 and math.abs(pawn.loc.Z-q.goal.Z)>180 or
    kind=='air' and q.prog_pos.X<650 or kind~='air' and kind~='wrong_floor' and q.prog_pos.X<150),q.prog_pos.X)
  TEST_WALK_NATIVE.floor,TEST_WALK_NATIVE.sweep=floor,sweep
 end
 for _,kind in ipairs({'world','goal','path','index','endpoint','pose','owner','guard','metadata','life','pause','stale','jump'}) do
  q=begin();local fired=false;local baseline,history
  pawn.CharacterMovement.IsMovingOnGround=function(...)
   if not fired and q.walk_input and pawn.loc.X>250 then
    fired=true;baseline=q.prog_pos.X;history=#q.progress_positions
    if kind=='world' then _G.DW_WORLD_GUID='changed-segment-world'
    elseif kind=='goal' then q.goal.X=q.goal.X+1
    elseif kind=='path' then q.path={{X=0,Y=0,Z=-90},{X=3000,Y=1,Z=-90}}
    elseif kind=='index' then q.wp=1
    elseif kind=='endpoint' then q.path[q.wp].Y=1
    elseif kind=='pose' then pawn.loc.X=pawn.loc.X+5
    elseif kind=='owner' then _G.DWArbiter.owner.token=_G.DWArbiter.owner.token+100
    elseif kind=='guard' then q.walk_guard.close();q.walk_guard={check=function()return {status='clear',reason='sampled_corridor'}end,close=function()return true end}
    elseif kind=='metadata' then q.nav_binding.metadata_goal.X=q.nav_binding.metadata_goal.X+1
    elseif kind=='life' then _G.DW_LIFE={move_death_seq=1}
    elseif kind=='pause' then _G.DW_PAUSE=true
    elseif kind=='stale' then T=T+1
    else q.jump_t=T end
   end
   return old_ground(...)
  end
  for _=1,100 do step(1);pump_oracle();if fired or q.result then break end end
  check('guarded native credit rejects callback '..kind,fired and q.prog_pos.X==baseline and #q.progress_positions==history,q.status)
  if kind=='owner' then _G.DWArbiter.owner.token=q.owner_token end
  _G.DW_WORLD_GUID='test-world';_G.DW_PAUSE=nil;_G.DW_LIFE=nil
 end
 M.stop(log);pawn.CharacterMovement.IsMovingOnGround=old_ground;pawn.AddMovementInput=old_input
 frame_hook=nil;motor=nil;walls={};raised={};lakes={};air=0;pawn.loc={X=0,Y=0,Z=0}
 oracle=nil;pump_oracle();_G.DW_NAVMEM=nil;os.remove(seed);os.remove(memory)
 DT,walking_speed=saved_dt,saved_speed
end
if os.getenv('MOVE_NATIVE_SEGMENT_ONLY')=='1' then NATIVE_SEGMENT_CASES();print(fails==0 and 'NATIVE SEGMENT OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end

function SNAPSHOT_PREEMPTION_CASE() -- Reentry must not write into or cancel the successor.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}; raised={}
    oracle=function() return nil end; pump_oracle()
    local old=M.go_to(log,{8,0,3},{tolerance_m=0.5,timeout_s=10})
    step(1)
    local st=_G.DW_MOVE
    local planner=st.lp
    local fired, successor, successor_handle, cancelled = false,nil,nil,false
    local old_cancel=CancelDelayedAction
    CancelDelayedAction=function(handle)
        if successor_handle and handle==successor_handle then cancelled=true end
        return old_cancel(handle)
    end
    if planner then
        planner.trace=function() return nil end
        local snapshot=planner.observation_snapshot
        planner.observation_snapshot=function(self)
            local packet=snapshot(self)
            fired=true
            successor=M.go_to(log,{9,0,0},{nav=false,local_plan=false,sprint=false})
            successor_handle=_G.DW_MOVE.handle
            return packet
        end
    end
    for i=1,300 do if fired then break end; step(1) end
    CancelDelayedAction=old_cancel
    local current=_G.DW_MOVE
    check("snapshot preemption preserves successor evidence, result and handle",fired and old and successor and successor.ok and
        current.gen>old.gen and current.gen==successor.gen and current.mode=="go_to" and
        current.navigation_evidence==nil and current.result==nil and successor_handle and
        current.handle==successor_handle and loops[successor_handle] and not cancelled)
    M.stop(log)
end
if os.getenv("MOVE_SNAPSHOT_PREEMPT_ONLY")=="1" then SNAPSHOT_PREEMPTION_CASE(); os.exit(fails==0 and 0 or 1) end

local function force_guard_stall(st)
    local context=(st.local_authority and st.lpath) or (st.memory_binding and st.mpath) or (st.source=='memory' and st.mpath) or (st.source=='local' and st.lpath) or
        (st.source=='nav' and st.path) or st.source or 'straight'
    st.guard_stall={context=context,elapsed=2,pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z},sent=false}
end
local function wait_guard_stall(st)
    local before,gen=st.local_replans or 0,st.gen
    for _=1,100 do
        step(1)
        if st.gen~=gen or (st.local_replans or 0)>before or st.result then return end
    end
end
if os.getenv('MOVE_JUMP_ONLY')~='1' then
if os.getenv('MOVE_PROTOCOL_WIRE_ONLY')~='1' and os.getenv('MOVE_AUTHORITY_ONLY')~='1' then
do -- Actual mover + sampled guard: memory entries and native coverage repair.
 local seed=dir..'/data/nav/L_World_seeds.json'
 local memory=dir..'/data/skills/test-world/nav_memory.json'
 local function clean()
  M.stop(log);walls={};raised={};lakes={};air=0;pawn.loc={X=0,Y=0,Z=0}
  _G.DW_NAVMEM=nil;_G.DW_TRAP_CAND=nil;_G.DW_LP_CACHE=nil
  os.remove(seed);os.remove(memory);TEST_WALK_NATIVE.calls={}
 end
 local function bad_seed()
  local f=assert(io.open(seed,'w'))
  f:write([==[{"v":1,"traps":[{"id":"wrong-floor","center":[0,0,-0.9],"radius_m":5,"z_min":-2,"z_max":2,"exit":[[0.01,0,-4.4],[0,8,-4.4]]}],"taboos":[],"routes":[]}]==])
  f:close()
 end
 do -- Real local planner + sampled guard, including several rolling windows.
  local NM=assert(loadfile(dir..'/client_mod/scripts/navmem.lua'))()
  local original_input=pawn.AddMovementInput
  local function begin(target,follow)
   clean();motor=nil;frame_hook=nil
   local mem=NM.new_mem('test-world');mem._world='test-world'
   _G.DW_NAVMEM=mem;_G.DW_MOVE_WORLD={id='test-world',t=os.time()}
   oracle=function(id) return ('return {id=%d,ok=false,reason="no_path",points={}}'):format(id) end
   pump_oracle()
   if follow then luis.loc={X=target*100,Y=0,Z=0};M.follow(log,'Zezima',0.5)
   else M.go_to(log,{target,0,0},{sprint=false,timeout_s=90,tolerance_m=0.5}) end
   return _G.DW_MOVE
  end
  local q=begin(40);local start=q.t0;local missed,credited,holds=0,0,0
  for _=1,2700 do
   local path,index=q.lpath,q.lwp
   step(1);pump_oracle()
   if q.status=='checking_terrain' then holds=holds+1 end
   if path and q.lpath==path and index and q.lwp>index and q.status=='checking_terrain' then
    local last=q.progress_positions and q.progress_positions[#q.progress_positions]
    if last and math.abs(last.X-pawn.loc.X)<0.01 and math.abs(last.Y-pawn.loc.Y)<0.01 then
     if q.prog_pos and math.abs(q.prog_pos.X-last.X)<0.01 and math.abs(q.prog_pos.Y-last.Y)<0.01 then credited=credited+1
     else missed=missed+1 end
    end
   end
   if q.result then break end
  end
  check('real-guard multiple local windows retain physical progress',q.result and q.result.status=='arrived' and
   (q.local_prefixes or 0)>=2 and credited>2 and missed==0 and holds>10,
   'x='..pawn.loc.X..' prefixes='..tostring(q.local_prefixes)..' credited='..credited..' lost='..missed..' result='..tostring(q.result and q.result.detail))
  print('progress replay x='..pawn.loc.X..' prefixes='..tostring(q.local_prefixes)..' credited='..credited..' lost='..missed..' terminal='..tostring(q.result and (q.result.detail or q.result.status)))
  check('rolling local execution preserves deadline and cumulative sensing',q.t0==start and (q.walk_spent or 0)>0 and T-start<90)
  if os.getenv('MOVE_PROGRESS_MULTI_ONLY')=='1' then print(fails==0 and 'PROGRESS MULTI OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
  local function admitted(points,follow)
   local st=begin(20,follow)
   pawn.AddMovementInput=function() end
   for _=1,40 do step(1);pump_oracle();if st.lp_observe then break end end
   st.lp={step=function() return 'ready' end,plan=function() return points end,verify=function() return 'ok' end}
   for _=1,30 do step(1);pump_oracle();if st.local_authority and st.walk_input then break end end
   check('progress fixture owns an admitted local route',st.local_authority and st.lpath,st.status)
   return st
  end
  local function points() return {{X=0,Y=0,Z=-90,act='walk'},{X=200,Y=0,Z=-90,act='walk'},{X=400,Y=0,Z=-90,act='walk'}} end
  q=admitted(points());pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0}}
  step(1)
  check('novel local waypoint credits before real guard target-change hold',q.lwp==3 and q.status=='checking_terrain' and q.prog_pos.X==200 and pawn.input==nil,q.status)
  q=admitted(points());pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0},{X=200,Y=0,Z=0}}
  step(1)
  check('revisited local waypoint cannot renew physical progress',q.prog_pos.X==0 and #q.progress_positions==2 and pawn.input==nil,q.prog_pos.X)
  q=admitted({{X=0,Y=0,Z=-90,act='walk'},{X=200,Y=0,Z=-90,act='walk'}})
  pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0}};step(1)
  check('novel prefix-final waypoint credits before planning handoff',q.local_prefixes==1 and not q.local_authority and q.prog_pos.X==200 and pawn.input==nil,q.status)
  local height=pawn.CapsuleComponent.GetScaledCapsuleHalfHeight
  for _,kind in ipairs({'successor','path','goal','pose','world','authority'}) do
   q=admitted(points());pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0}}
   local oldgen=q.gen;local fired=false;local replacement
   pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=function(...)
    if not fired and q.lwp==3 then
     fired=true
     if kind=='successor' then M.go_to(log,{8,8,0},{nav=false,local_plan=false})
     elseif kind=='path' then replacement=points();q.lpath=replacement
     elseif kind=='goal' then q.goal.X=q.goal.X+1
     elseif kind=='world' then _G.DW_WORLD_GUID='changed-progress-world'
     elseif kind=='authority' then q.local_authority=false
     else pawn.loc.X=250 end
    end
    return height(...)
   end
   step(1);pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=height
   check('credit callback '..kind..' cannot consume successor progress',fired and pawn.input==nil and
    (kind=='successor' and q.gen>oldgen and not q.prog_pos or kind~='successor' and q.prog_pos.X==0 and #q.progress_positions==1),q.status)
   _G.DW_WORLD_GUID='test-world'
  end
  local location=pawn.K2_GetActorLocation
  q=admitted(points());pawn.loc.X=200;q.progress_positions={{X=0,Y=0,Z=0}};local fired=false
  pawn.K2_GetActorLocation=function(...)
   if not fired and q.lwp==3 then fired=true;_G.DW_WORLD_GUID='pose-changed-world' end
   return location(...)
  end
  step(1);pawn.K2_GetActorLocation=location;_G.DW_WORLD_GUID='test-world'
  check('final pose callback world change cannot mint progress',fired and q.prog_pos.X==0 and #q.progress_positions==1 and pawn.input==nil,q.status)
  q=admitted(points(),true);pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0}}
  step(1)
  check('dynamic target keeps prior pending-waypoint credit behavior',q.target_name and q.status=='checking_terrain' and q.prog_pos.X==0,q.status)
  q=admitted(points(),true);pawn.loc.X=200;q.prog_t=T-3;q.progress_positions={{X=0,Y=0,Z=0}}
  q.walk_guard.close();q.walk_guard={check=function() return {status='clear',consumed_total=0} end,close=function() return true end}
  step(1)
  check('dynamic target retains existing late physical waypoint credit',q.target_name and q.prog_pos.X==200 and #q.progress_positions==2,q.status)
  local function selected_route(source)
   clean();local mem=NM.new_mem('test-world');mem._world='test-world'
   if source=='memory' then mem.routes={{id='progress',n_ok=1,pts={{0,0,-0.9},{2,0,-0.9},{4,0,-0.9},{20,0,-0.9}}}} end
   _G.DW_NAVMEM=mem;_G.DW_MOVE_WORLD={id='test-world',t=os.time()}
   oracle=function(id)
    if source=='memory' then return ('return {id=%d,ok=false,reason="no_path",points={}}'):format(id) end
    return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{2,0,-0.9},{20,0,-0.9}}}'):format(id)
   end
   pump_oracle();M.go_to(log,{20,0,0},{sprint=false,timeout_s=60});local st=_G.DW_MOVE;st.walk_guarded=true
   for _=1,70 do step(1);pump_oracle();if st.walk_input and st.source==source then break end end
   check('selected '..source..' fixture has real guarded authority',st.source==source and st.walk_input~=nil,st.status)
   pawn.loc.X=200;st.prog_t=T-3;st.progress_positions={{X=0,Y=0,Z=0}}
   return st
  end
  for _,source in ipairs({'memory','nav'}) do
   q=selected_route(source);step(1)
   check('selected '..source..' waypoint credits before real guard hold',q.status=='checking_terrain' and q.prog_pos.X==200 and pawn.input==nil,q.status)
  end
  q=selected_route('nav');q.nav_binding.metadata_goal.X=q.nav_binding.metadata_goal.X+1;step(1)
  check('native goal-binding mutation cannot grant early credit',q.prog_pos.X==0 and #q.progress_positions==1 and pawn.input==nil,q.status)
  q=selected_route('nav');q.backtrack_pt={X=-400,Y=0,Z=0};q.backtrack_until=T+2;step(1)
  check('inactive native waypoint cannot grant early credit',q.prog_pos.X==0 and #q.progress_positions==1,q.status)
  -- Let a real clear guard deliver the expiry tick, without waiting out its
  -- separate input-stall detector. The deadline and no-novel limit stay intact.
  for _,follow in ipairs({false,true}) do
   q=admitted(points(),follow)
   local closed=q.walk_guard.close
   q.walk_guard.close=function() closed();return true end
   local check_guard=q.walk_guard.check
   local entered=false
   q.walk_guard.check=function(...)
    local r=check_guard(...)
    if r.status=='clear' then q.prog_t=T-M.cfg.give_up_s-1;entered=true end
    return r
   end
   for _=1,30 do step(1);if q.result or q.unreach then break end end
   check((follow and 'follow' or 'go_to')..' no-novel expiry preserves local recovery ownership',entered and not q.backtrack_until and not q.bug and
    (follow and q.mode=='follow' and q.unreach and q.unreach.reason=='no_route' or not follow and q.result and q.result.detail=='local route made no novel progress'),q.status)
  end
  q=admitted(points());q.backtrack_pt={X=-400,Y=0,Z=0};q.backtrack_until=T+2;q.bt_tested=T-0.1;q.move_acc=12
  step(1)
  local mismatch
  for _,row in ipairs(q.route_trace or {}) do if row.reason=='local_source_mismatch' then mismatch=row end end
  check('local source invariant stamps attempted primitive cause',mismatch and mismatch.attempted_src=='backtrack' and mismatch.local_authority==true and
   mismatch.move_acc==12 and type(mismatch.bt_tested)=='number' and type(mismatch.backtrack_until)=='number' and q.result and q.result.detail=='local route unavailable',q.status)
  local copied=mismatch and mismatch.backtrack_until;q.backtrack_until=0
  check('source mismatch stamp survives later state mutation',mismatch and mismatch.backtrack_until==copied)
  pawn.AddMovementInput=original_input;clean();luis.loc={X=3000,Y=0,Z=0};oracle=nil;pump_oracle()
  if os.getenv('MOVE_PROGRESS_CREDIT_ONLY')=='1' then print(fails==0 and 'PROGRESS CREDIT OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
 end
 do -- Adjacent physical observations, not a larger acceptance disk.
  local saved_dt,old_input=DT,pawn.AddMovementInput
  local function prepare(points)
   clean();motor=nil;DT=saved_dt;frame_hook=nil;oracle=nil;pump_oracle()
   M.go_to(log,{15,0,0},{nav=false,local_plan=false,sprint=false,timeout_s=45,tolerance_m=0.5})
   local s=_G.DW_MOVE
   s.mpath=points or {{X=26.55,Y=0,Z=-90},{X=500,Y=0,Z=-90},{X=1500,Y=0,Z=-90}}
   s.mwp=1;s.walk_guarded=true
   return s
  end
  local s=prepare();local vx,vy=0,0
  motor=function(dt,input)
   local tx,ty=input and input.X*450 or 0,input and input.Y*450 or 0
   local acceleration=input and 1800 or 6000
   local dx,dy=tx-vx,ty-vy;local delta=math.sqrt(dx*dx+dy*dy)
   local f=delta>0 and math.min(1,acceleration*dt/delta) or 0
   vx,vy=vx+dx*f,vy+dy*f
   local nx,ny=pawn.loc.X+vx*dt,pawn.loc.Y+vy*dt
   if not blocked(nx,ny,false) then pawn.loc.X,pawn.loc.Y=nx,ny end
  end
  local crossed=false;local retained=true
  for i=1,230 do
   DT=({1/6,0.2,0.24})[(i-1)%3+1];step(1)
   crossed=crossed or (s.mwp or 1)>1
   retained=retained and not s.local_replans
   if s.result then break end
  end
  check('coarse finite motor crosses short entry once and retains route',crossed and retained and s.result and s.result.status=='arrived',s.status..' x='..pawn.loc.X)
  local observed=0
  for _,row in ipairs(s.route_trace or {}) do if row.reason=='waypoint_crossed' then observed=observed+1 end end
  check('crossing trace records bounded actual-pose transition',observed>=1,observed)
  if os.getenv('MOVE_CROSSING_MOTOR_ONLY')=='1' then print(fails==0 and 'CROSSING MOTOR OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
  motor=nil;DT=saved_dt

  -- Hold the motor, then supply independent consecutive pose observations.
  -- Real guard admission still decides whether input may follow a crossing.
  local function arm(points)
   local q=prepare(points)
   pawn.AddMovementInput=function() end
   for _=1,50 do step(1);if q.walk_input then break end end
   check('crossing fixture has real admitted first input',q.walk_input~=nil,q.status)
   return q
  end
  local function negative(name,mutate,points)
   local q=arm(points);local path=q.mpath
   local token,world,life=q.owner_token,_G.DW_WORLD_GUID,_G.DW_LIFE
   pawn.loc={X=55,Y=0,Z=0};mutate(q,path)
   step(1)
   check('crossing rejects '..name,(q.mwp==1 or not q.mpath) and not (q.route_trace and q.route_trace[#q.route_trace].reason=='waypoint_crossed'),q.status..' wp='..tostring(q.mwp))
   q.owner_token=token;_G.DW_WORLD_GUID=world;_G.DW_LIFE=life
   pawn.AddMovementInput=old_input
  end
  negative('wrong floor',function() pawn.loc.Z=300 end)
  negative('teleport',function() pawn.loc.X=150 end)
  negative('long observation interval',function() DT=0.5 end)
  negative('changed route',function(q,path) q.mpath={{X=path[1].X,Y=0,Z=-90},path[2],path[3]} end)
  negative('changed endpoint',function(q,path) path[1].Y=2 end)
  negative('changed goal',function(q) q.goal.Y=1 end)
  negative('changed owner',function(q) q.owner_token=q.owner_token+1 end)
  negative('changed world',function() _G.DW_WORLD_GUID='other-crossing-world' end)
  _G.DW_WORLD_GUID='test-world';_G.DW_MOVE_WORLD=nil
  negative('changed life',function() _G.DW_LIFE={move_death_seq=1} end)
  _G.DW_LIFE=nil
  negative('airborne observation',function() air=0.5 end)
  for _,kind in ipairs({'gap','air','link','jump','djump','superjump','drop'}) do
   local p={X=26.55,Y=0,Z=-90}
   if kind=='gap' or kind=='air' or kind=='link' then p[kind]=true else p.act=kind end
   negative(kind..' waypoint',function() end,{p,{X=500,Y=0,Z=-90},{X=1500,Y=0,Z=-90}})
  end
  negative('final waypoint',function() end,{{X=26.55,Y=0,Z=-90}})
  local q=arm();_G.DW_PAUSE=true;step(1);_G.DW_PAUSE=false;pawn.loc.X=55;step(1)
  check('pause discards previous crossing sample',q.mwp==1,q.mwp)
  pawn.AddMovementInput=old_input
  q=arm();step(1) -- pending? force one held tick through the real guard
  local guard=q.walk_guard;local prior=guard.check
  guard.check=function() return {status='pending'} end
  step(1);guard.check=prior;pawn.loc.X=55;step(1)
  check('held interval cannot reuse earlier input crossing',q.mwp==1,q.mwp)
  pawn.AddMovementInput=old_input
  local ground=pawn.CharacterMovement.IsMovingOnGround
  for _,kind in ipairs({'pose','index','route','goal'}) do
   q=arm();pawn.loc.X=55;local fired=false;local replacement
   pawn.CharacterMovement.IsMovingOnGround=function()
    if not fired then
     fired=true
     if kind=='pose' then pawn.loc.X=0
     elseif kind=='index' then q.mwp=3
     elseif kind=='route' then replacement={{X=800,Y=0,Z=-90}};q.mpath=replacement;q.mwp=1
     else q.goal.Y=1 end
    end
    return true
   end
   step(1);pawn.CharacterMovement.IsMovingOnGround=ground
   check('ground callback changing '..kind..' aborts crossing without stale input',fired and pawn.input==nil and
    (kind~='index' or q.mwp==3) and (kind~='route' or q.mpath==replacement) and (kind~='pose' or q.mwp==1),q.status)
   pawn.AddMovementInput=old_input
  end
  -- Change state during the input callback: the already submitted direction
  -- must never be attributed to a successor waypoint/route.
  for _,kind in ipairs({'index','endpoint','guard','pose'}) do
   q=prepare();local fired=false
   pawn.AddMovementInput=function()
    fired=true
    if kind=='index' then q.mwp=2 elseif kind=='endpoint' then q.mpath[1].Y=2
    elseif kind=='pose' then pawn.loc.X=55 else q.walk_guard={} end
   end
   for _=1,50 do step(1);if fired then break end end
   check('input callback changing '..kind..' cannot record successor sample',fired and not q.walk_input,q.status)
   if kind=='guard' then q.walk_guard=nil end
   pawn.AddMovementInput=old_input
  end
  for _,kind in ipairs({'pose','route','goal'}) do
   q=prepare();local fired=false;local inputs=0
   -- Hold the real scan until a clear result; then mutate inside the new ground
   -- read immediately before the final actual-pose guard check.
   local g={check=function() return {status='clear',reason='fixture'} end,close=function() return true end}
   q.walk_guard=g;q.walk_goal={X=q.goal.X,Y=q.goal.Y,Z=q.goal.Z}
   pawn.CharacterMovement.IsMovingOnGround=function()
    if not fired then
     fired=true
     if kind=='pose' then pawn.loc.X=300
     elseif kind=='route' then q.mpath={{X=900,Y=0,Z=-90}};q.mwp=1
     else q.goal.Y=1 end
    end
    return true
   end
   -- Route/goal mutations must abort; a moved pose must be rechecked, never
   -- submitted along the old direction. This spy requires the fresh pose.
   g.check=function(me) if fired then return {status='pending'} end;return {status='clear'} end
   pawn.AddMovementInput=function() inputs=inputs+1 end
   step(1);pawn.CharacterMovement.IsMovingOnGround=ground
   check('pre-input ground callback changing '..kind..' cannot use stale clearance',fired and inputs==0 and not q.walk_input,q.status)
   pawn.AddMovementInput=old_input
  end
  q=prepare();q.target_name='moving-fixture';q.target_kind='actor'
  q.target=obj({loc={X=1500,Y=0,Z=0},K2_GetActorLocation=pawn.K2_GetActorLocation})
  local dynamic_inputs=0
  pawn.AddMovementInput=function() dynamic_inputs=dynamic_inputs+1;q.target.loc.Y=q.target.loc.Y+1 end
  for _=1,50 do step(1);if dynamic_inputs>1 then break end end
  check('dynamic target inputs do not create crossing evidence',dynamic_inputs>0 and not q.walk_input,dynamic_inputs)
  pawn.AddMovementInput=old_input
  q=arm({{X=26.55,Y=0,Z=-90},{X=26.55,Y=500,Z=-90},{X=1500,Y=0,Z=-90}})
  pawn.loc.X=55;walls={{0,80,30,80,true}};step(1)
  check('changed next aim holds before inheriting old clearance',q.mwp==2 and pawn.input==nil and q.status=='checking_terrain',q.status)
  for _=1,40 do step(1);if q.walk_failure then break end end
  check('blocked corner chord cannot receive new segment input',q.walk_failure~=nil and pawn.input==nil,q.walk_failure)
  pawn.AddMovementInput=old_input

  -- A route from before the memory leg cannot silently become its recovery.
  local function dormant_native()
   local q=arm()
   q.use_nav=true;q.nav_required=true;q.forward_checked=true
   q.path={{X=0,Y=0,Z=-90},{X=1000,Y=500,Z=-90}};q.wp=2;q.path_partial=true
   q.nav_id=(q.nav_id or 0)+1
   local pending={id=q.nav_id,epoch=offer.epoch,nonce=offer.nonce,gen=q.gen,token=q.owner_token,pawn=pawn,world='test-world',metadata_goal={X=1500,Y=0,Z=0}}
   q.nav_pending=pending;q.nav_binding=pending;q.nav_goal={X=1500,Y=0,Z=0};q.nav_sent_t=T
   return q,pending
  end
  q=select(1,dormant_native());local old_deadline,spent=q.t0,q.walk_spent
  force_guard_stall(q)
  for _=1,30 do step(1);if q.local_replans then break end end
  check('memory stall withdraws dormant partial native and pending request',q.local_replans and not q.mpath and not q.path and not q.nav_binding and not q.nav_pending,q.status)
  check('memory discard preserves command deadline and accumulated guard spend',q.t0==old_deadline and (q.walk_spent or 0)>=(spent or 0),q.walk_spent)
  pawn.AddMovementInput=old_input
  local old;q,old=dormant_native()
  local prior=q.walk_guard.check
  q.walk_guard.check=function() return {status='blocked',reason='test_blocked',consumed_total=1} end
  step(1)
  check('memory guard rejection also withdraws dormant native authority',not q.mpath and not q.path and not q.nav_pending and q.walk_failure=='test_blocked',q.status)
  local f=assert(io.open(dir..'/client_io/nav/resp.lua','w'))
  f:write(('return {version=2,id=%d,epoch="%s",nonce="%s",ok=true,partial=false,points={{0,0,-0.9},{15,0,-0.9}}}'):format(old.id,old.epoch,old.nonce));f:close()
  offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no)
  oracle=function() return nil end;pump_oracle();step(1)
  local fresh=q.nav_pending
  check('recovery requests a fresh route instead of accepting late old reply',not q.path and fresh and fresh.id>old.id and fresh.nonce~=old.nonce and pawn.input==nil,q.status)
  step(1)
  check('late old response stays rejected while fresh request waits',q.nav_pending==fresh and not q.path and pawn.input==nil,q.status)
  pawn.AddMovementInput=old_input
  clean();motor=nil;frame_hook=nil;DT=saved_dt
  if os.getenv('MOVE_CROSSING_ONLY')=='1' then print(fails==0 and 'CROSSING OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
 end
 do -- Held scans do not spend the guarded input window or reset it.
  local function setup_guard()
   clean();oracle=nil;pump_oracle()
   M.go_to(log,{15,0,0},{nav=false,local_plan=false,sprint=false,timeout_s=30})
   local s=_G.DW_MOVE
   s.mpath={{X=25,Y=0,Z=-90},{X=1500,Y=0,Z=-90}};s.mwp=1;s.walk_guarded=true;s.walk_goal={X=s.goal.X,Y=s.goal.Y,Z=s.goal.Z}
   local mode='pending'
   s.walk_guard={check=function() return {status=mode,reason='test',consumed_total=1} end,close=function() return true end}
   return s,function(v) mode=v end
  end
  local s,set=setup_guard()
  step(60)
  check('long initial pending scan never starts input stall window',not s.guard_stall and s.mpath and pawn.input==nil,s.status)
  set('clear');step(1)
  check('short entry submits after held scan',s.guard_stall and s.guard_stall.sent and s.mpath and pawn.loc.X>0,s.status)
  clean()
  local paused_move,pause_change=setup_guard();pause_change('clear');step(1)
  _G.DW_PAUSE=true;step(1);T=T+5;_G.DW_PAUSE=false;step(1)
  check('paused interval does not spend guarded active window',paused_move.guard_stall and paused_move.guard_stall.elapsed<1 and not paused_move.local_replans,tostring(paused_move.status)..' elapsed='..tostring(paused_move.guard_stall and paused_move.guard_stall.elapsed)..' replans='..tostring(paused_move.local_replans)..' src='..tostring(paused_move.source))
  clean()
  local delayed,delayed_change=setup_guard();delayed_change('clear')
  local late=false;local old_check=delayed.walk_guard.check
  delayed.walk_guard.check=function(...)
   if not late then late=true;T=T+2 end
   return old_check(...)
  end
  local old_input=pawn.AddMovementInput;local submitted=0
  pawn.AddMovementInput=function() submitted=submitted+1 end
  step(1);step(1)
  check('long first clear callback is not charged as active input',late and submitted==2 and delayed.guard_stall and delayed.guard_stall.elapsed<1 and not delayed.local_replans,delayed.status)
  for _=1,90 do step(1);if delayed.local_replans then break end end
  pawn.AddMovementInput=old_input
  check('blocked input still stalls after first observation',delayed.local_replans and delayed.local_replans>0,delayed.status)
  local captured
  for _,row in ipairs(delayed.route_trace or {}) do if row.reason=='guarded_stall' then captured=row end end
  check('trace records first guarded discard before clearing route',captured and captured.source=='memory' and captured.points==2 and captured.wp==1 and not delayed.mpath,delayed.status)
  check('trace captures active exposure and primitive cause',captured and captured.active_s>=M.cfg.stuck_window_s and captured.stall_distance_cm<M.cfg.stuck_min_cm and captured.guard_status=='clear' and captured.guard_queries==1)
  local saved_x=captured and captured.position_cm and captured.position_cm.X
  pawn.loc.X=1234
  check('trace snapshot survives later native position mutation',captured and captured.position_cm.X==saved_x and captured.position_cm~=pawn.loc)
  local primitives=true
  local function primitive_tree(x,depth)
   if type(x)=='table' then
    if depth>2 or getmetatable(x) then return false end
    for k,v in pairs(x) do if type(k)~='string' or not primitive_tree(v,depth+1) then return false end end
    return true
   end
   return type(x)=='string' or type(x)=='number' or type(x)=='boolean'
  end
  for _,row in ipairs(delayed.route_trace or {}) do primitives=primitives and primitive_tree(row,0) end
  check('route trace contains primitives without route or native references',primitives)
  clean()
  local bounded=setup_guard()
  for i=1,72 do
   bounded.mpath={{X=25,Y=0,Z=-90},{X=1500,Y=0,Z=-90}};bounded.mwp=1
   step(1)
  end
  check('transition ring is bounded with explicit lost-event count',#bounded.route_trace==64 and bounded.route_trace_dropped==bounded.route_trace_seq-64)
  check('retained transition sequence exposes overflow gap',bounded.route_trace[1].seq>1 and bounded.route_trace[64].seq==bounded.route_trace_seq)
  clean()
  for _,oscillate in ipairs({false,true}) do
   local q,change=setup_guard();change('clear')
   local original=pawn.AddMovementInput;local inputs=0
   pawn.AddMovementInput=function() inputs=inputs+1 end
   step(1)
   local before=q.guard_stall and q.guard_stall.elapsed or 0
   for i=1,180 do
    change((math.floor((i-1)/4)%2==0) and 'pending' or 'clear')
    if oscillate then pawn.loc.X=(i%2==0) and 20 or 0 end
    step(1)
    if q.local_replans then break end
   end
   pawn.AddMovementInput=original
   check((oscillate and 'oscillation' or 'stationary')..' remains bounded across repeated guard holds',inputs>1 and q.local_replans and q.local_replans>0 and before==0,q.status)
   clean()
  end
  local q,change=setup_guard();change('clear')
  local original=pawn.AddMovementInput;local oldgen=q.gen;local fired=false
  pawn.AddMovementInput=function()
   fired=true;pawn.AddMovementInput=original
   M.go_to(log,{4,4,0},{nav=false,local_plan=false,sprint=false})
  end
  step(1);pawn.AddMovementInput=original
  check('preemption during guarded input cannot mutate successor',fired and q.gen>oldgen and q.mode=='go_to' and q.guard_stall==nil,q.status)
  clean()
  if os.getenv('MOVE_GUARD_STALL_ONLY')=='1' then print(fails==0 and 'GUARD STALL OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
 end
 if os.getenv('MOVE_PREFIX_ONLY')~='1' then
 clean();bad_seed()
 oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{8,0,-0.9}}}'):format(id) end
 pump_oracle();local jumps=pawn.jumps
 M.go_to(log,{8,0,0},{sprint=false,timeout_s=30});run(220)
 local st=_G.DW_MOVE
 check('wrong-floor memory entry rejected before jump or step-off',st.walk_failure=='target_support_mismatch' and pawn.jumps==jumps and not st.stepoff,st.walk_failure)
 check('actual-goal native route wins after invalid memory entry',M.status().result and M.status().result.status=='arrived' and math.abs(pawn.loc.Z)<1,M.status().status)
 clean();bad_seed();walls={{70,100,-50,50}};oracle=nil;pump_oracle()
 jumps=pawn.jumps;M.go_to(log,{8,0,0},{sprint=false,timeout_s=30});step(1)
 check('reactive low-obstacle hop cannot bypass wrong-floor admission',pawn.jumps==jumps and pawn.input==nil and _G.DW_MOVE.walk_failure=='target_support_mismatch',_G.DW_MOVE.walk_failure)
 clean();bad_seed();oracle=nil;pump_oracle()
 M.go_to(log,{8,0,0},{sprint=false,timeout_s=30})
 st=_G.DW_MOVE;st.mem_checked=true
 step(1)
 st.prog_t=T-M.cfg.give_up_s-1;st.prog_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z};st.move_acc=200
 jumps=pawn.jumps;step(1);run(220)
 check('recovery memory uses same floor guard and cannot step off',st.walk_failure=='target_support_mismatch' and st.mem_retry and pawn.jumps==jumps and not st.stepoff,st.walk_failure)
 check('recovery replans to actual nearby goal',M.status().result and M.status().result.status=='arrived',M.status().status)
 clean()
 oracle=function(id)
  local x=math.min(30,pawn.loc.X/100+4)
  return ('return {id=%d,ok=true,partial=%s,points={{%.3f,0,-0.9},{%.3f,0,-0.9}}}'):format(id,tostring(x<30),pawn.loc.X/100,x)
 end
 pump_oracle();M.go_to(log,{30,0,0},{sprint=false,timeout_s=80});run(600)
 st=_G.DW_MOVE
 check('native partial endpoints continue through bounded local prefixes',st.local_prefixes and st.local_prefixes>=2,st.local_prefixes)
 check('prefix completion is not false arrival; actual far goal reached',M.status().result and M.status().result.status=='arrived' and math.abs(pawn.loc.X-3000)<=150,M.status().status..' x='..pawn.loc.X)
 clean();oracle=nil;pump_oracle()
 M.go_to(log,{8,0,3},{sprint=false,timeout_s=0.3});run(8)
 check('held planning retains whole-command deadline',M.status().result and M.status().result.reason=='timeout',M.status().status)
 clean();luis.loc={X=1000,Y=0,Z=0}
 oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{10,0,-0.9}}}'):format(id) end
 pump_oracle();M.follow(log,'Zezima',0.5);_G.DW_MOVE.walk_guarded=true
 frame_hook=function() luis.loc.X=luis.loc.X+1 end
 run(24);frame_hook=nil
 check('moving actor does not restart every multi-poll walking scan',pawn.loc.X>150 and _G.DW_MOVE.mode=='follow' and #TEST_WALK_NATIVE.calls>8,_G.DW_MOVE.status..' x='..pawn.loc.X)
 clean();luis.loc={X=3000,Y=0,Z=0}
 oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{8,0,-0.9}}}'):format(id) end
 pump_oracle();M.go_to(log,{8,0,0},{sprint=true,timeout_s=30});_G.DW_MOVE.walk_guarded=true
 _G.DW_MOVE.strafe_until=T+10;_G.DW_MOVE.strafe_dir=1;sprinting=true
 step(1)
 check('guarded walking observes sprint release before input',pawn.input==nil and not sprinting,_G.DW_MOVE.status)
 run(20)
 check('carried strafe cannot escape checked forward corridor',pawn.loc.X>0 and math.abs(pawn.loc.Y)<0.01 and _G.DW_MOVE.strafe_until==nil,pawn.loc.Y)
 clean();oracle=nil;pump_oracle()
 M.go_to(log,{8,0,0},{nav=false,sprint=false,timeout_s=30});st=_G.DW_MOVE;st.walk_guarded=true
 run(4);force_guard_stall(st);wait_guard_stall(st)
 check('guarded stalled direct mode preserves nav opt-out',st.nav_required==false and pawn.input==nil,st.status)
 run(180)
 check('guarded direct recovery terminates at actual destination',st.result and st.result.status=='arrived',st.status)
 clean();M.go_to(log,{8,0,0},{nav=false,sprint=false,timeout_s=30});st=_G.DW_MOVE;st.walk_guarded=true
 local old_gen=st.gen;local getter=pawn.SprintComponent.IsSprinting;local stop=pawn.SprintComponent.TryRequestStopSprinting
 local fired,stops=false,0
 pawn.SprintComponent.IsSprinting=function()
  if not fired then fired=true;M.go_to(log,{4,4,0},{nav=false,local_plan=false}) end
  return true
 end
 pawn.SprintComponent.TryRequestStopSprinting=function() stops=stops+1 end
 step(1);pawn.SprintComponent.IsSprinting=getter;pawn.SprintComponent.TryRequestStopSprinting=stop
 check('sprint getter preemption cannot stop or mutate successor',fired and _G.DW_MOVE.gen>old_gen and stops==0 and _G.DW_MOVE.sprint_id==nil and pawn.input==nil,stops)
 clean();oracle=nil;pump_oracle()
 end
 do
  local NM=assert(loadfile(dir..'/client_mod/scripts/navmem.lua'))()
  local function install()
   local mem=NM.new_mem('test-world');mem._world='test-world'
   NM.add_route(mem,{{X=0,Y=0,Z=-90},{X=500,Y=0,Z=-90},{X=1000,Y=0,Z=-90},{X=1500,Y=0,Z=-90}},{src='self'})
   _G.DW_NAVMEM=mem;_G.DW_MOVE_WORLD={id='test-world',t=os.time()}
  end
  local function on_search(fn)
   local routes=_G.DW_NAVMEM.routes;local fired=false
   _G.DW_NAVMEM.routes=setmetatable({}, {__index=function(_,i)
    if not fired then fired=true;fn() end
    return routes[i]
   end})
  end
  install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=1})
  local delayed=_G.DW_MOVE;on_search(function() T=T+2 end);step(1)
  check('forward search exceeding deadline never adopts or moves',delayed.result and delayed.result.reason=='timeout' and not delayed.memory_binding and not delayed.mpath and pawn.input==nil and delayed.forward_search and delayed.forward_search.duration_s>1.9,tostring(delayed.status)..' mode='..tostring(delayed.mode)..' result='..tostring(delayed.result and delayed.result.reason)..' searched='..tostring(delayed.forward_checked)..' evidence='..tostring(delayed.forward_search and delayed.forward_search.duration_s)..' path='..tostring(delayed.mpath)..' input='..tostring(pawn.input))
  clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30})
  local interrupted=_G.DW_MOVE;local owner=_G.DWArbiter.owner
  on_search(function() _G.DWArbiter.owner=nil end);step(1)
  check('forward search owner change never adopts or moves',not interrupted.memory_binding and not interrupted.mpath and pawn.input==nil,interrupted.status)
  _G.DWArbiter.owner=owner;clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30})
  local drifted=_G.DW_MOVE;on_search(function() pawn.loc.X=35 end);step(1)
  check('forward search records actual drift and defers input',drifted.memory_binding and drifted.forward_search and drifted.forward_search.before.X==0 and drifted.forward_search.after.X==35 and pawn.input==nil,drifted.status)
  clean();install();oracle=nil;pump_oracle()
  if os.getenv('MOVE_POST_SEARCH_ONLY')=='1' then print(fails==0 and 'POST SEARCH OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
  install();M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30});run(200)
  check('forward memory runs with unavailable oracle',_G.DW_MOVE.forward_checked and _G.DW_MOVE.result and _G.DW_MOVE.result.status=='arrived',_G.DW_MOVE.status)
  clean();install()
  oracle=function(id) return ('return {id=%d,ok=true,partial=true,points={{0,0,-0.9},{0,3,-0.9}}}'):format(id) end
  pump_oracle();M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30});run(200)
  check('partial native route cannot suppress connected forward walk',_G.DW_MOVE.result and _G.DW_MOVE.result.status=='arrived' and math.abs(pawn.loc.Y)<1,_G.DW_MOVE.status)
  clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30});step(1)
  local late=_G.DW_MOVE;local had_memory=late.memory_binding~=nil
  oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{15,0,-0.9}}}'):format(id) end
  pump_oracle();run(20)
  check('late complete native route replaces proposal',had_memory and not late.memory_binding and late.path and late.path_partial==false,late.status)
  clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30});step(1)
  local bound=_G.DW_MOVE;bound.goal.X=1600
  oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{16,0,-0.9}}}'):format(id) end;pump_oracle();run(200)
  check('changed goal abandons proposal and falls back to native',not bound.memory_binding and bound.mem_retry and bound.result and bound.result.status=='arrived' and pawn.loc.X>=1450,bound.status)
  clean();install();luis.loc={X=1500,Y=0,Z=0};oracle=nil;pump_oracle()
  M.go_to(log,'Zezima',{local_plan=false,sprint=false,timeout_s=30});step(1)
  bound=_G.DW_MOVE
  check('stationary actor can use a bound forward proposal',bound.target_name and bound.memory_binding and bound.forward_checked,bound.status)
  luis.loc.X=1600;oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{16,0,-0.9}}}'):format(id) end;pump_oracle();run(200)
  check('moving actor abandons proposal and falls back',not bound.memory_binding and bound.mem_retry and bound.result and bound.result.status=='arrived',bound.status)
  clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{30,0,0},{local_plan=false,sprint=false,timeout_s=60});step(1)
  bound=_G.DW_MOVE;local start_t=bound.t0;local active=bound.memory_binding and bound.memory_binding.prefix
  local prefix_end,spent,old_id
  oracle=function(id)
   if not prefix_end then return ('return {id=%d,ok=true,partial=true,points={{0,0,-0.9},{0,3,-0.9}}}'):format(id) end
   return ('return {id=%d,ok=true,partial=false,points={{%.3f,0,-0.9},{30,0,-0.9}}}'):format(id,pawn.loc.X/100)
  end
  for _=1,900 do
   step(1)
   if active and not bound.memory_binding then prefix_end=true;spent=bound.walk_spent;old_id=bound.nav_id;break end
   pump_oracle()
  end
  check('prefix ends short without false arrival',active and prefix_end and not bound.result and pawn.loc.X>1000 and pawn.loc.X<2000,bound.status..' failure='..tostring(bound.walk_failure)..' x='..pawn.loc.X..' y='..pawn.loc.Y)
  check('prefix preserves deadline and accumulated guard budget',bound.t0==start_t and spent and spent>0 and bound.forward_checked,bound.walk_spent)
  step(1)
  local pending=bound.nav_pending
  if pending then
   local f=assert(io.open(dir..'/client_io/nav/resp.lua','w'))
   f:write(('return {version=2,epoch="%s",nonce="%s",id=%d,ok=true,partial=false,points={{0,0,-0.9},{30,0,-0.9}}}'):format(pending.epoch,pending.nonce,old_id));f:close()
  end
  local x_before=pawn.loc.X;step(2)
  check('stale native response is not reused after prefix',pending and bound.nav_pending==pending and not bound.path and pawn.loc.X==x_before,bound.status)
  run(200)
  check('prefix requests fresh native path and never reselects memory',bound.nav_id>old_id and bound.forward_checked and not bound.memory_binding and bound.result and bound.result.status=='arrived',bound.status..' fail='..tostring(bound.nav_fail)..' pending='..tostring(bound.nav_pending~=nil)..' id='..tostring(bound.nav_id)..' old='..tostring(old_id)..' x='..pawn.loc.X)
  clean();install()
  _G.DW_NAVMEM.routes={
   {id='a',n_ok=1,pts={{0,0,-0.9},{5,0,-0.9},{10,0,-0.9}}},
   {id='b',n_ok=1,pts={{13,0,-0.9},{18,0,-0.9},{23,0,-0.9}}}}
  walls={{1100,1200,-100,100,true}};oracle=nil;pump_oracle()
  M.go_to(log,{30,0,0},{local_plan=false,sprint=false,timeout_s=60})
  bound=_G.DW_MOVE
  for _=1,600 do step(1);if bound.walk_failure then break end end
  check('blocked inter-record join is rejected before crossing',bound.walk_failure and not bound.memory_binding and pawn.loc.X<1100,bound.status..' x='..pawn.loc.X)
  clean();install();oracle=nil;pump_oracle()
  M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=30});step(1)
  bound=_G.DW_MOVE;bound.mpath=nil
  oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{15,0,-0.9}}}'):format(id) end;pump_oracle();run(200)
  check('abandoned proposal clears binding and falls back',not bound.memory_binding and bound.mem_retry and bound.result and bound.result.status=='arrived',bound.status)
  clean();install();walls={{100,200,-100,100,true}}
  oracle=nil;pump_oracle();M.go_to(log,{15,0,0},{local_plan=false,sprint=false,timeout_s=40});step(1)
  for _=1,120 do step(1);if _G.DW_MOVE.walk_failure then break end end
  oracle=function(id) return ('return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{0,4,-0.9},{15,4,-0.9},{15,0,-0.9}}}'):format(id) end
  pump_oracle();run(450)
  check('rejected forward proposal falls back once to native',_G.DW_MOVE.forward_checked and _G.DW_MOVE.mem_retry and _G.DW_MOVE.walk_failure and _G.DW_MOVE.result and _G.DW_MOVE.result.status=='arrived',_G.DW_MOVE.status)
  clean();oracle=nil;pump_oracle()
 end
 if os.getenv('MOVE_GROUND_WALK_ONLY')=='1' then print(fails==0 and 'GROUND WALK OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
end
end

-- 1. go_to via a dog-leg nav path (wall in the straight line)
walls = { { 900, 1100, -500, 500 } }
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
pump_oracle() -- heartbeat first, as with a running helper
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(100)
local s = M.status()
check("go_to arrives via waypoints", s.result and s.result.status == "arrived", s.result and (tostring(s.result.status) .. " " .. tostring(s.result.detail)))
local saw_nav = false

for _, l in ipairs(logs) do if l:find("src=nav") then saw_nav = true end end
check("used nav waypoints (oracle heartbeat live)", (s.nav_requests or 0) >= 1 and saw_nav, s.nav_requests); if os.getenv("DBG") then for _, l in ipairs(logs) do print("  " .. l) end; print(pawn.loc.X, pawn.loc.Y) end
check("sprint injected", injected > 0, injected)
if os.getenv("MOVE_PROTOCOL_WIRE_ONLY") == "1" then os.exit(fails == 0 and 0 or 1) end

do -- The oracle's next point is closer, but the intervening corner is mandatory.
    M.stop(log); pawn.loc={X=0,Y=0,Z=0}; air=0
    walls={{-100,250,400,600,true}}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{10,0,0},{0,10,0},{-5,10,0}}}"):format(id) end
    pump_oracle(); M.go_to(log,{-5,10,0},{local_plan=false,timeout_s=30})
    run(3)
    local corner=_G.DW_MOVE
    check("unreached corner retained despite nearer next point",corner.path and corner.wp==2 and pawn.loc.X>0 and pawn.loc.Y<100,corner.wp)
    run(180)
    check("physical detour follows mandatory corner",M.status().result and M.status().result.status=="arrived",M.status().status)
    M.stop(log); walls={}
end

do -- A long first leg goes directly away from the destination for over five seconds.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walking_speed=150
    walls={{300,700,-200,1400,true}}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{-15,0,-0.9},{-15,18,-0.9},{10,18,-0.9},{10,0,-0.9}}}"):format(id) end
    pump_oracle(); M.go_to(log,{10,0,0},{local_plan=false,sprint=false,timeout_s=70})
    run(70)
    local detour=M.status()
    check("moving away along admitted segment remains live",not detour.result and pawn.loc.X < -300,detour.status.." x="..pawn.loc.X)
    run(580)
    check("long physical U detour completes",M.status().result and M.status().result.status=="arrived",M.status().status)
    M.stop(log); walking_speed=450; walls={}
end
if os.getenv('MOVE_DETOUR_ONLY')=='1' then print(fails==0 and 'DETOUR OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end

do -- Overshooting a corner must steer back and recover within the action deadline.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{10,0,0},{10,10,0}}}"):format(id) end
    pump_oracle(); M.go_to(log,{10,10,0},{local_plan=false,sprint=false,timeout_s=20})
    run(3); pawn.loc={X=1350,Y=0,Z=0}; run(180)
    check("overshot corner recovers or terminates within deadline",M.status().result~=nil,M.status().status)
    check("overshot corner recovers to destination",M.status().result and M.status().result.status=="arrived",M.status().status)
    M.stop(log)
end

do -- A pawn repeatedly displaced within a small area cannot earn unlimited time.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{20,0,0},{30,0,0}}}"):format(id) end
    luis.loc={X=90000,Y=90000,Z=0}
    pump_oracle(); M.go_to(log,{30,0,0},{local_plan=false,sprint=false,timeout_s=120})
    local frames=0
    frame_hook=function()
        frames=frames+1; pawn.loc.X=(frames%2==0) and 40 or 0; pawn.loc.Y=0
        if frames%30==0 then _G.DW_MOVE.want_repath=true end
    end
    run(240); frame_hook=nil
    check("oscillation fails before action deadline",M.status().result and M.status().result.status=="failed" and M.status().result.reason~="timeout",M.status().status)
    M.stop(log); luis.loc={X=3000,Y=0,Z=0}
end

do -- Matching XY is not enough to reach an elevated native link endpoint.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{0,0,5},{10,0,5}}}"):format(id) end
    pump_oracle(); M.go_to(log,{10,0,5},{local_plan=false,timeout_s=20})
    run(3)
    local elevated=_G.DW_MOVE
    check("native link at same XY on another floor is not reached",elevated.path and elevated.wp==2,elevated.wp)
    M.stop(log)
end

do -- Real oracle replacements with jittered starts must not refresh the stall budget.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    local replies=0
    oracle=function(id)
        replies=replies+1
        local x=pawn.loc.X/100
        return ("return {id=%d,ok=true,partial=false,points={{%.3f,0,-0.9},{%.3f,0,-0.9},{30,0,-0.9}}}"):format(id,x,10+replies*0.001)
    end
    luis.loc={X=90000,Y=90000,Z=0}
    pump_oracle(); M.go_to(log,{30,0,0},{local_plan=false,sprint=false,timeout_s=120})
    local frames, ages=0,{}
    frame_hook=function()
        frames=frames+1
        pawn.loc.X=(math.floor(frames/45)%2==0) and 0 or 200
        pawn.loc.Y=0
        local move=_G.DW_MOVE
        -- Withdraw the active path to trigger the normal nonce-bound request/response path.
        if frames%75==0 and move.mode=="go_to" and move.path then
            ages[#ages+1]=move.prog_t and T-move.prog_t or 0
            move.path,move.nav_fail=nil,nil
        end
    end
    run(270); frame_hook=nil
    local result=M.status().result
    check("jittered oracle replacements were admitted",replies>=2,replies)
    check("replacements preserve accumulated stall age",ages[2] and ages[2]>ages[1]+1,table.concat(ages,","))
    local move=_G.DW_MOVE
    check("large oscillation and jittered intermediate replans fail before deadline",result and result.status=="failed" and result.reason~="timeout",
        (result and result.reason or M.status().status).." age="..tostring(move.prog_t and T-move.prog_t).." replies="..replies)
    M.stop(log); luis.loc={X=3000,Y=0,Z=0}
end

do -- A persistent follow may revisit a prior leg after the leader moves back.
    pawn.loc={X=500,Y=0,Z=0}; luis.loc={X=2000,Y=0,Z=0}; air=0; walls={}; walking_speed=150
    oracle=function(id)
        return ("return {id=%d,ok=true,partial=false,points={{%.3f,0,-0.9},{%.3f,0,-0.9}}}"):format(id,pawn.loc.X/100,luis.loc.X/100)
    end
    pump_oracle(); M.follow(log,{actor=luis},1,{local_plan=false,sprint=false}); run(130)
    local outbound=M.status()
    check("persistent follow reaches first end of leg",outbound.status=="near",outbound.status)
    luis.loc={X=500,Y=0,Z=0}; run(130)
    local inbound=M.status()
    check("persistent follow returns on revisited leg",inbound.status=="near" and pawn.loc.X<650,inbound.status.." x="..pawn.loc.X)
    M.stop(log); walking_speed=450; luis.loc={X=3000,Y=0,Z=0}
end

do -- A different incoming leg to the same endpoint cannot borrow the old projection.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    local replies=0
    oracle=function(id)
        replies=replies+1
        return ("return {id=%d,ok=true,partial=false,points={{%.3f,%.3f,-0.9},{30,0,-0.9}}}"):format(id,pawn.loc.X/100,pawn.loc.Y/100)
    end
    frame_hook=function() pawn.loc.X,pawn.loc.Y=0,0 end
    pump_oracle(); M.go_to(log,{30,0,0},{local_plan=false,sprint=false,timeout_s=20}); run(20)
    local move=_G.DW_MOVE
    move.path,move.nav_fail=nil,nil
    frame_hook=function() pawn.loc.X,pawn.loc.Y=600,500 end
    run(25); frame_hook=nil
    check("changed incoming leg does not credit lateral projection",replies>=2 and move.prog_t and T-move.prog_t>3,
        "replies="..replies.." age="..tostring(move.prog_t and T-move.prog_t))
    run(100)
    check("changed incoming leg earns progress once physically followed",not M.status().result and pawn.loc.X>1200,
        M.status().status.." x="..pawn.loc.X)
    M.stop(log)
end

do -- Long physical routes retain a fixed upper bound on progress evidence.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
    oracle=function(id)
        local points={}
        for i=0,70 do points[#points+1]=("{%d,0,-0.9}"):format(i*2) end
        return ("return {id=%d,ok=true,partial=false,points={%s}}"):format(id,table.concat(points,","))
    end
    pump_oracle(); M.go_to(log,{140,0,0},{local_plan=false,sprint=false,timeout_s=120}); run(400)
    local move=_G.DW_MOVE
    check("long physical route completes",M.status().result and M.status().result.status=="arrived",M.status().status)
    check("progress history remains bounded",move.progress_positions and #move.progress_positions==64,#(move.progress_positions or {}))
    M.stop(log)
end

SNAPSHOT_PREEMPTION_CASE()
do -- A real failed observation planner must reach the terminal result without native route metadata.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}; raised={}
    offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no)
    oracle=function() return nil end; pump_oracle()
    M.go_to(log,{8,0,3},{tolerance_m=0.5,timeout_s=10})
    step(1)
    local st=_G.DW_MOVE
    if st.lp then st.lp.trace=function() return nil end end
    for i=1,300 do if st.lp_fail or st.result then break end; step(1) end
    check("real failed observation captures planner evidence",st.lp_fail and st.navigation_evidence and
        st.navigation_evidence.packet.coverage.sampled_cells>0,st.lp_fail)
    for i=1,500 do if st.result then break end; step(1) end
    local result=M.status().result
    check("failed observation reaches terminal without route metadata",result and result.status=="failed" and
        result.navigation_observation and not result.route_feedback,result and result.reason)
    local evidence=st.navigation_evidence
    local function invalid_case(name, mutate, restore)
        local oldvalid, reads=pc.IsValid,0
        local oldavoid=M.avoid_status
        M.avoid_status=function() return {} end -- isolate the packet path from its independent fresh-controller lookup
        pc.IsValid=function(...) reads=reads+1; return oldvalid(...) end
        mutate()
        local dropped=M.status().result
        check("observation rejects changed "..name,dropped and result and dropped.reason==result.reason and not dropped.navigation_observation)
        if name=="life" or name=="owner" then check("stale "..name.." avoids cached controller",reads==0,reads) end
        restore()
        pc.IsValid=oldvalid
        M.avoid_status=oldavoid
        check("changed "..name.." cannot revive observation",M.status().result and not M.status().result.navigation_observation)
        -- Recreate the terminal fixture for the next independent invalidation case.
        st.result=result; st.navigation_evidence=evidence
    end
    local oldgen=st.gen
    invalid_case("generation",function() st.gen=oldgen+1 end,function() st.gen=oldgen end)
    local oldgoal=st.goal
    invalid_case("goal",function() st.goal={X=oldgoal.X+1,Y=oldgoal.Y,Z=oldgoal.Z} end,function() st.goal=oldgoal end)
    local oldpawn=st.pawn
    invalid_case("pawn",function() st.pawn={} end,function() st.pawn=oldpawn end)
    local oldlife=_G.DW_LIFE
    invalid_case("life",function() _G.DW_LIFE={move_death_seq=(st.life_seq or 0)+1} end,function() _G.DW_LIFE=oldlife end)
    local oldtoken=st.owner_token
    invalid_case("owner",function() st.owner_token="other" end,function() st.owner_token=oldtoken end)
    local old=_G.DW_WORLD_GUID; _G.DW_WORLD_GUID="other-world"
    local dropped=M.status().result
    check("stale observation drops without changing failure",dropped and result and dropped.reason==result.reason and not dropped.navigation_observation)
    _G.DW_WORLD_GUID=old
    check("dropped observation cannot revive",M.status().result and not M.status().result.navigation_observation)
    M.stop(log)
end

do -- Exercise the real planner's verification and recorded horizontal hit path.
    pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}; raised={}
    offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no)
    oracle=function() return nil end; pump_oracle()
    M.go_to(log,{8,0,3},{tolerance_m=0.5,timeout_s=10})
    step(1)
    local st=_G.DW_MOVE
    for i=1,300 do if st.lp_state=="verifying" or st.result then break end; step(1) end
    local planner=st.lp
    if planner and st.lp_state=="verifying" then
        local trace=planner.trace
        planner.trace=function(a,b,horizontal)
            if horizontal then return true,{X=(a.X+b.X)/2,Y=(a.Y+b.Y)/2,Z=12345} end
            return trace(a,b,horizontal)
        end
        st.lp_rounds=12
        step(1)
    end
    local packet=st.navigation_evidence and st.navigation_evidence.packet
    check("real verification records bounded synthetic-plane barrier",packet and packet.phase=="verification" and
        packet.reason=="verify_exhausted" and packet.underlying_reason=="verification_budget_exhausted" and
        #packet.barrier_samples>0 and packet.barrier_samples[1].position_m[3]~=123.45)
    for i=1,500 do if st.result then break end; step(1) end
    local terminal=M.status().result
    check("verification evidence reaches terminal",terminal and terminal.navigation_observation~=nil)
    local oldvalid=pc.IsValid; local reads=0
    pc.IsValid=function(...) reads=reads+1; return oldvalid(...) end
    _G.DW_PAUSE=true
    local paused_result=M.status().result
    _G.DW_PAUSE=false; pc.IsValid=oldvalid
    check("paused status drops packet without controller access",reads==0 and paused_result and
        not paused_result.navigation_observation and terminal and paused_result.reason==terminal.reason)
    check("paused packet cannot revive",M.status().result and not M.status().result.navigation_observation)
    M.stop(log)
end

do
    -- Drive the actual move module with a deterministic planner result. The real planner's
    -- nearest-node contract is covered separately; these isolate admission and ownership.
    local function observe_case(endpoint, tolerance, act)
        pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
        -- A planner promise alone no longer permits input. Walking fixtures
        -- include the corresponding physical ramp in the independent fake world.
        raised=(not act or act=='walk') and {{0,1000,-100,100,0,375}} or {}
        offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no)
        oracle=function() return nil end; pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=tolerance})
        -- This fixture measures the local planner's retry bound, independently
        -- of any successful trips recorded by earlier sandbox scenarios.
        local NM=assert(loadfile(dir..'/client_mod/scripts/navmem.lua'))()
        _G.DW_NAVMEM=NM.new_mem('test-world');_G.DW_NAVMEM._world='test-world'
        _G.DW_MOVE_WORLD={id='test-world',t=os.time()}
        step(1)
        local move=_G.DW_MOVE
        local held=move.lp_state=="sampling" and pawn.input==nil and move.nav_pending~=nil
        local goal_seen
        if act == "djump" then move.env.double_jump=true; move.env.dj_measured=true end
        move.lp={step=function() return "ready" end,
            plan=function(_,g) goal_seen=g; return {{X=0,Y=0,Z=-90,act="walk"},endpoint} end,
            verify=function() return "ok" end}
        step(1)
        local still_held=pawn.input==nil and move.lp_state=="verifying"
        step(1)
        if not act or act=='walk' then step(4) end -- bounded native walking scan
        return move,held,still_held,goal_seen
    end
    local localmove, held, verified_hold, feetgoal=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    check("local observation holds through sampling and verification",held and verified_hold, tostring(held).." "..tostring(verified_hold))
    check("local planner gets original goal in feet coordinates",feetgoal and feetgoal.X==800 and feetgoal.Z==210, feetgoal and feetgoal.Z)
    check("complete local path admitted while oracle remains pending",localmove.local_authority and localmove.nav_pending and localmove.lpath and pawn.input~=nil, localmove.status)
    -- A stalled, admitted route is withdrawn before another movement command,
    -- and the oracle request remains independently owned while observing again.
    local recovery=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    local pending=recovery.nav_pending; local original_path=recovery.lpath
    force_guard_stall(recovery)
    local original_jump_count=pawn.jumps; wait_guard_stall(recovery)
    check("local stall holds input and preserves pending oracle",pawn.input==nil and not recovery.local_authority and not recovery.lpath and recovery.local_replans==1 and recovery.nav_pending==pending and pawn.jumps==original_jump_count,recovery.status)
    step(1)
    check("local stall starts observational replan",recovery.lp_state=="sampling" and recovery.lp_observe==true and recovery.nav_pending==pending and pawn.input==nil,recovery.lp_state)
    recovery.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}} end,verify=function() return "ok" end}
    step(2)
    check("repackaged failed waypoint cannot regain authority",not recovery.local_authority and recovery.nav_fail=="local_replan_repeats_stalled_waypoint" and pawn.input==nil,recovery.status)
    M.stop(log)
    do -- Different replacement routes cannot evade the per-move retry limit.
        local old_limit=M.cfg.lp_max_plans; M.cfg.lp_max_plans=2
        local bounded=observe_case({X=700,Y=0,Z=210,act="walk"},1.5)
        for _, x in ipairs({750,800}) do
            force_guard_stall(bounded); wait_guard_stall(bounded)
            step(1)
            local endx=x
            bounded.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=endx,Y=0,Z=210,act="walk"}} end,verify=function() return "ok" end}
            step(2)
            check("distinct replacement route admitted within retry bound",bounded.local_authority and bounded.lpath[#bounded.lpath].X==x,bounded.status)
        end
        force_guard_stall(bounded); wait_guard_stall(bounded)
        check("distinct routes still exhaust bounded replan",not bounded.local_authority and bounded.local_replans==3 and bounded.nav_fail=="local_replan_limit" and pawn.input==nil,bounded.status)
        step(1)
        check("exhausted replan reports specific failure",bounded.result and bounded.result.reason=="verification_failed" and bounded.result.detail:find("local_replan_limit",1,true),bounded.status)
        M.stop(log); M.cfg.lp_max_plans=old_limit
    end
    do -- A complete late oracle route may win, without mixing local waypoints.
        local race=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
        local pending=race.nav_pending
        force_guard_stall(race); wait_guard_stall(race); step(1)
        local reply=assert(io.open(dir.."/client_io/nav/resp.lua","w"))
        reply:write(('return {version=2,epoch="%s",nonce="%s",id=%d,ok=true,partial=false,points={{0,0,0},{8,0,3}}}'):format(pending.epoch,pending.nonce,pending.id));reply:close()
        step(1)
        check("late complete oracle route supersedes observation without mixing",race.path and not race.local_authority and not race.lpath and not race.lp_state and not race.nav_pending,race.status)
        M.stop(log)
    end
    do -- Follow retains ownership and reports an unreachable episode on exhaustion.
        local old_limit=M.cfg.lp_max_plans;M.cfg.lp_max_plans=0
        pawn.loc={X=0,Y=0,Z=0};luis.loc={X=800,Y=200,Z=300};air=0
        offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no);pump_oracle()
        M.follow(log,"Zezima",0.5);step(1)
        local follow=_G.DW_MOVE
        follow.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=200,Z=210,act="walk"}} end,verify=function() return "ok" end};step(2)
        force_guard_stall(follow);wait_guard_stall(follow);step(1)
        check("exhausted local recovery preserves follow",follow.mode=="follow" and follow.status=="unreachable" and follow.unreach and follow.unreach.reason=="no_route" and pawn.input==nil,follow.status)
        M.stop(log);M.cfg.lp_max_plans=old_limit
    end
    do -- Owner can replace the move during the final stalled-route check.
        local owned_move=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
        local prior=owned_move.gen;force_guard_stall(owned_move)
        local old_height=pawn.CapsuleComponent.GetScaledCapsuleHalfHeight;local calls=0;local fired=false
        pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=function(...)
            calls=calls+1
            if calls==2 then fired=true;M.go_to(log,{20,0,0},{nav=false,local_plan=false}) end
            return old_height(...)
        end
        step(1);pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=old_height
        check("stall ownership reentry preserves successor",fired and _G.DW_MOVE.gen>prior and _G.DW_MOVE.mode=="go_to" and not _G.DW_MOVE.local_replans and pawn.input==nil,_G.DW_MOVE.mode)
        M.stop(log)
    end
    do -- A coasting pawn invalidates the sampled first segment before admission.
        pawn.loc={X=0,Y=0,Z=0};air=0;offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no);pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=.5});step(1)
        local coast=_G.DW_MOVE;local pending=coast.nav_pending
        coast.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}} end,verify=function() return "ok" end}
        step(1);pawn.loc.X=60;step(1)
        check("coasting discards stale first segment without input",not coast.local_authority and not coast.lpath and coast.local_replans==1 and coast.nav_pending==pending and pawn.input==nil,coast.status)
        M.stop(log)
    end
    do -- Position read after verification can replace the move.
        pawn.loc={X=0,Y=0,Z=0};air=0;offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no);pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=.5});step(1)
        local old=_G.DW_MOVE.gen;local fire=false;local fired=false;local original=pawn.K2_GetActorLocation
        _G.DW_MOVE.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}} end,verify=function() fire=true;return "ok" end}
        step(1)
        pawn.K2_GetActorLocation=function(self)
            if fire and not fired then fired=true;M.go_to(log,{20,0,0},{nav=false,local_plan=false}) end
            return original(self)
        end
        step(1);pawn.K2_GetActorLocation=original
        check("post-plan position reentry preserves successor",fired and _G.DW_MOVE.gen>old and _G.DW_MOVE.mode=="go_to" and not _G.DW_MOVE.local_authority and pawn.input==nil,_G.DW_MOVE.mode)
        M.stop(log)
    end
    localmove=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    local path_copy=localmove.lpath
    pawn.loc={X=700,Y=0,Z=262.5}; step(6)
    check("final waypoint retained outside exact tolerance",localmove.local_authority and localmove.lwp==#localmove.lpath and pawn.input~=nil,localmove.lwp)
    _G.DW_WORLD_GUID="changed-world"; step(1)
    check("local authority rejects world change before input",pawn.input==nil and not localmove.local_authority,localmove.status)
    _G.DW_WORLD_GUID="test-world"; M.stop(log)
    local partial=observe_case({X=746.1,Y=0,Z=210,act="walk"},0.5)
    check("53.9 cm nearest endpoint fails 50 cm tolerance",not partial.local_authority and pawn.input==nil,partial.status)
    M.stop(log)
    local default=observe_case({X=746.1,Y=0,Z=210,act="walk"},1.5)
    check("53.9 cm endpoint meets default tolerance",default.local_authority and pawn.input~=nil,default.status)
    M.stop(log)
    local wrong=observe_case({X=800,Y=0,Z=-90,act="walk"},0.5)
    check("wrong level local endpoint rejected",not wrong.local_authority and pawn.input==nil,wrong.status)
    M.stop(log)
    local jump=observe_case({X=300,Y=0,Z=210,act="jump"},6)
    -- A complete endpoint must also reach the goal: adjust only the requested tolerance for this edge.
    check("typed local edge accepts real jump input",jump.local_authority and jump.lp_jump_exec and pawn.jumps>0,jump.status)
    local jump_index=jump.lwp
    local jumping_path=jump.lpath
    jump.win_t=T-2;jump.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}
    step(1)
    check("airborne jump cannot advance path",jump.lwp==jump_index and jump.lp_jump_exec and jump.lp_jump_exec.saw_air,jump.lwp)
    check("stuck window cannot interrupt owned jump",jump.lpath==jumping_path and jump.local_authority and not jump.local_replans,jump.status)
    pawn.loc={X=300,Y=0,Z=300}; air=0; step(1)
    check("grounded endpoint advances only after observed air",jump.lp_jump_exec==nil and jump.lwp==#jump.lpath+1 and jump.lpath[#jump.lpath].act=="walk",jump.status)
    M.stop(log); air=0
    local before_double=pawn.jumps
    local double=observe_case({X=300,Y=0,Z=210,act="djump"},6,"djump")
    step(14)
    check("double jump uses airborne second input",double.lp_jump_exec and double.lp_jump_exec.saw_air and pawn.jumps==before_double+2,double.status)
    M.stop(log); air=0
    local missed=observe_case({X=300,Y=0,Z=210,act="jump"},6)
    step(1); pawn.loc={X=-200,Y=0,Z=300}; air=0; step(1)
    check("missed landing fails without path success",missed.result and missed.result.reason=="verification_failed" and missed.lp_jump_exec~=nil,missed.status)
    M.stop(log); air=0
    pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=800,Y=200,Z=300}
    offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
    M.follow(log,"Zezima",6); step(1)
    local follower=_G.DW_MOVE
    follower.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=300,Y=0,Z=210,act="jump"}} end,verify=function() return "ok" end}
    step(3); pawn.loc={X=-200,Y=0,Z=300}; air=0; step(1)
    check("failed local jump preserves persistent follow",follower.mode=="follow" and follower.status=="unreachable" and follower.unreach and follower.unreach.reason=="no_route",follower.status)
    M.stop(log); air=0
    local changed=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    changed.goal.X=801; step(1)
    check("changed original goal invalidates local input",pawn.input==nil and not changed.local_authority,changed.status)
    M.stop(log)
    local swapped=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    swapped.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}}; step(1)
    check("replaced local path cannot authorize input",pawn.input==nil and not swapped.local_authority,swapped.status)
    M.stop(log)
    local paused_move=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
    _G.DW_PAUSE=true; step(1)
    check("pause invalidates local route without input",pawn.input==nil and not paused_move.local_authority and not paused_move.local_binding,paused_move.status)
    _G.DW_PAUSE=nil; M.stop(log)
    pawn.loc={X=0,Y=0,Z=0}; offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
    M.go_to(log,{8,0,3},{tolerance_m=0.5}); step(1)
    local prior=_G.DW_MOVE.gen
    _G.DW_MOVE.lp={step=function() return "ready" end,plan=function()
        M.go_to(log,{20,0,0},{nav=false,local_plan=false})
        return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}}
    end}
    step(1)
    check("planner reentry preserves successor state",_G.DW_MOVE.gen>prior and _G.DW_MOVE.mode=="go_to" and not _G.DW_MOVE.lp_pts and not _G.DW_MOVE.local_authority and pawn.input==nil,_G.DW_MOVE.mode)
    M.stop(log)
    do -- strict observation owns neither global trace profile nor malformed evidence
        local old_profile, saved_profile, old_cache = _G.DW_TRACE_PROFILE, KSL.LineTraceSingleByProfile, _G.DW_LP_CACHE
        for _, case in ipairs({"nonboolean", "throw", "geometry", "pause"}) do
            pawn.loc={X=0,Y=0,Z=0}; air=0
            offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
            local selected={name="Player"}; _G.DW_TRACE_PROFILE=selected
            local cache={cells={}}; _G.DW_LP_CACHE=cache
            M.go_to(log,{8,0,3},{tolerance_m=0.5}); step(1)
            local m=_G.DW_MOVE; local P=m.lp
            KSL.LineTraceSingleByProfile=function(self,ctx,a,b,prof,cx,ign,dbg,out,...)
                if case=="throw" then error("fake profile error") end
                if case=="pause" then _G.DW_PAUSE=true; return false end
                if case=="nonboolean" then return "unknown" end
                out.ImpactPoint={X=0/0,Y=0,Z=0}; out.Distance=1; return true
            end
            P.step=function(self) self.trace({X=0,Y=0,Z=0},{X=100,Y=0,Z=0},true); return "ready" end
            step(1)
            check("strict observation rejects "..case,pawn.input==nil and not m.local_authority and _G.DW_TRACE_PROFILE==selected and _G.DW_LP_CACHE==cache and next(cache.cells)==nil, m.status)
            _G.DW_PAUSE=nil; KSL.LineTraceSingleByProfile=saved_profile; M.stop(log)
        end
        _G.DW_TRACE_PROFILE=nil; pawn.loc={X=0,Y=0,Z=0}
        offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=0.5}); step(1)
        check("observation selects profile locally without calibration mutation",_G.DW_MOVE.lp~=nil and _G.DW_TRACE_PROFILE==nil and pawn.input==nil,_G.DW_MOVE.status)
        M.stop(log); _G.DW_TRACE_PROFILE=old_profile; _G.DW_LP_CACHE=old_cache
    end
    do -- A target read after ownership may change pawn or death sequence.
        local original_loc=luis.K2_GetActorLocation
        for _, case in ipairs({"pawn","life"}) do
            pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=800,Y=200,Z=300}; air=0; _G.DW_LIFE={move_death_seq=0}
            offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
            M.follow(log,"Zezima",0.5); step(1)
            local m=_G.DW_MOVE
            m.lp={step=function() return "ready" end, plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=200,Z=210,act="walk"}} end,verify=function() return "ok" end}
            step(2)
            local olddead=pawn.HealthComponent.IsDead; local health_reads=0; local fired=false; local rotations=0
            local oldrot=pc.SetControlRotation
            pawn.HealthComponent.IsDead=function(...) health_reads=health_reads+1; return olddead(...) end
            luis.K2_GetActorLocation=function(self)
                if health_reads>=3 and not fired then
                    fired=true
                    if case=="pawn" then pc.Pawn=obj({}) else _G.DW_LIFE.move_death_seq=1 end
                end
                return original_loc(self)
            end
            pc.SetControlRotation=function(...) rotations=rotations+1; return oldrot(...) end
            step(1)
            check("post-owner target read rejects changed "..case,fired and rotations==0 and pawn.input==nil and m.gen==_G.DW_MOVE.gen,rotations)
            pc.Pawn=pawn; pawn.HealthComponent.IsDead=olddead; luis.K2_GetActorLocation=original_loc; pc.SetControlRotation=oldrot; _G.DW_LIFE=nil; M.stop(log)
        end
    end
    do -- world resolver can reenter after ownership as well
        local saved_getenv=os.getenv
        for _, case in ipairs({"pawn","life"}) do
            pawn.loc={X=0,Y=0,Z=0}; air=0; _G.DW_LIFE={move_death_seq=0}
            offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
            M.go_to(log,{8,0,3},{tolerance_m=0.5}); step(1)
            local m=_G.DW_MOVE
            m.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=800,Y=0,Z=210,act="walk"}} end,verify=function() return "ok" end}
            step(2)
            local olddead=pawn.HealthComponent.IsDead; local reads=0; local fired=false; local rotations=0
            local oldrot=pc.SetControlRotation
            pawn.HealthComponent.IsDead=function(...) reads=reads+1; return olddead(...) end
            _G.DW_WORLD_GUID=nil
            os.getenv=function(k)
                if k=="DW_WORLD_GUID" then
                    if reads>=3 and not fired then
                        fired=true
                        if case=="pawn" then pc.Pawn=obj({}) else _G.DW_LIFE.move_death_seq=1 end
                    end
                    return "test-world"
                end
                return saved_getenv(k)
            end
            pc.SetControlRotation=function(...) rotations=rotations+1; return oldrot(...) end
            step(1)
            check("post-owner world read rejects changed "..case,fired and rotations==0 and pawn.input==nil and m.gen==_G.DW_MOVE.gen,rotations)
            os.getenv=saved_getenv; _G.DW_WORLD_GUID="test-world"; pc.Pawn=pawn; pawn.HealthComponent.IsDead=olddead; pc.SetControlRotation=oldrot; _G.DW_LIFE=nil; M.stop(log)
        end
    end
    -- The actual planner and real arbiter exercise injection, not an isolated mock.
    do
        local real_loadfile=loadfile
        local arb_loads, move_loads, injections=0,0,0
        loadfile=function(path,...)
            local chunk,err=real_loadfile(path,...)
            if tostring(path):find("arbiter.lua",1,true) and chunk then
                arb_loads=arb_loads+1
                return function()
                    local a=chunk(); local setter=a.set_move
                    a.set_move=function(m) if m==M then injections=injections+1 end; return setter(m) end
                    return a
                end
            elseif tostring(path):find("move.lua",1,true) then move_loads=move_loads+1 end
            return chunk,err
        end
        pawn.loc={X=0,Y=0,Z=0}; air=0; offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=.5}); step(1)
        local m=_G.DW_MOVE; arb_loads,move_loads,injections=0,0,0
        local before=m.traces or 0; step(1)
        check("active mover injected for owned planner without nested move loads",m.lp_state=="sampling" and (m.traces or 0)-before==16 and arb_loads>0 and injections==arb_loads and move_loads==0 and pawn.input==nil,move_loads)
        loadfile=real_loadfile; M.stop(log)
    end
    do -- A broken/missing setter is not permission to drive the pawn.
        for _, kind in ipairs({"missing","throw","load"}) do
            pawn.loc={X=0,Y=0,Z=0}; air=0; offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
            M.go_to(log,{8,0,3},{tolerance_m=.5}); step(1)
            local m,gen,owner=_G.DW_MOVE,_G.DW_MOVE.gen,_G.DWArbiter.owner
            local real_loadfile=loadfile
            loadfile=function(path,...)
                local chunk,err=real_loadfile(path,...)
                if tostring(path):find("arbiter.lua",1,true) then
                    if kind=="load" then return nil,"unavailable" end
                    return function() local a=chunk(); if kind=="missing" then a.set_move=nil else a.set_move=function() error("setter failed") end end; return a end
                end
                return chunk,err
            end
            step(1); loadfile=real_loadfile
            check("arbiter "..kind.." cannot authorize planner or input",pawn.input==nil and m.gen==gen and _G.DWArbiter.owner==owner and not m.local_authority,kind)
            M.stop(log)
        end
    end
    do -- Real housekeeping still expires a lease and resumes its suspended owner.
        pawn.loc={X=0,Y=0,Z=0}; air=0; offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=.5}); step(1)
        local st,old=_G.DW_MOVE,_G.DWArbiter.owner
        local stops,resumes=0,0
        old.implicit=false; old.lease_s=1; old.renewed=os.time()-5
        old.on_stop=function(_,_,why) if why=="lease_expired" then stops=stops+1 end end
        local nextowner={token=old.token+100,name="suspended",level=1,uses_move=false,state="suspended",suspended_at=os.time(),on_resume=function() resumes=resumes+1; return true end}
        _G.DWArbiter.stack={nextowner}
        step(1)
        check("injected mover retains real lease expiry and resume",stops==1 and resumes==1 and _G.DWArbiter.owner==nextowner and pawn.input==nil and not st.local_authority,st.status)
        _G.DWArbiter.owner=old; _G.DWArbiter.stack={}; old.implicit=true; old.lease_s=30; old.renewed=os.time(); M.stop(log)
    end
    do -- Setter can reenter: ownership must not publish into its successor.
        pawn.loc={X=0,Y=0,Z=0}; air=0; offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=.5}); step(1)
        local prior=_G.DW_MOVE.gen; local real_loadfile=loadfile; local fired=false
        loadfile=function(path,...)
            local chunk,err=real_loadfile(path,...)
            if tostring(path):find("arbiter.lua",1,true) and chunk then
                return function()
                    local a=chunk(); local setter=a.set_move
                    a.set_move=function(m)
                        if not fired then fired=true; M.go_to(log,{20,0,0},{nav=false,local_plan=false}) end
                        return setter(m)
                    end
                    return a
                end
            end
            return chunk,err
        end
        step(1); loadfile=real_loadfile
        check("setter reentry preserves successor",fired and _G.DW_MOVE.gen>prior and _G.DW_MOVE.mode=="go_to" and not _G.DW_MOVE.local_authority and pawn.input==nil,_G.DW_MOVE.mode)
        M.stop(log)
    end
    offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no)

end
raised={}

if os.getenv("MOVE_AUTHORITY_ONLY") == "1" then
    -- The protocol assertions below exercise native authority alone. Earlier
    -- mover scenarios can have recorded routes in this test world's sandbox.
    local NM=assert(loadfile(dir..'/client_mod/scripts/navmem.lua'))()
    local function empty_native_memory()
        local m=NM.new_mem('test-world');m._world='test-world'
        _G.DW_NAVMEM=m;_G.DW_MOVE_WORLD={id='test-world',t=os.time()}
    end
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; walls = {}; oracle = function() return nil end
    empty_native_memory()
    pump_oracle()
    M.go_to(log, { 20, 0, 0 }, { local_plan=false })
    run(20)
    local waiting = M.status()
    check("pending request holds actual input", pawn.loc.X == 0 and waiting.status == "planning" and (waiting.nav_requests or 0) == 1, waiting.status)
    check("pending does not accrue progress time", waiting.progress and (waiting.progress.elapsed_s or 0) < 0.1, waiting.progress and waiting.progress.elapsed_s)
    local pending_id = _G.DW_MOVE.nav_pending.id
    local stale = assert(io.open(dir .. "/client_io/nav/resp.lua", "w"))
    stale:write(('return {version=2,epoch="old-process",nonce="%s",id=%d,ok=true,partial=false,points={{0,0,0},{20,0,0}}}'):format(offer.nonce,pending_id)); stale:close()
    step(20)
    check("stale epoch cannot authorize input", pawn.loc.X == 0 and _G.DW_MOVE.nav_pending ~= nil, pawn.loc.X)
    stale = assert(io.open(dir .. "/client_io/nav/resp.lua", "w"))
    stale:write(('return {version=2,epoch="11111111-1111-4111-8111-111111111111",nonce="wrong-offer",id=%d,ok=true,points={{0,0,0},{20,0,0}}}'):format(pending_id)); stale:close()
    step(10)
    check("stale nonce cannot authorize input", pawn.loc.X == 0 and _G.DW_MOVE.nav_pending ~= nil, pawn.loc.X)
    _G.DW_WORLD_GUID = "other-world"; step(2)
    check("world identity change fails closed", pawn.loc.X == 0 and M.status().result and M.status().result.reason == "verification_failed", M.status().status)
    check("world replacement cannot donate route feedback", M.status().result and M.status().result.route_feedback == nil)
    _G.DW_WORLD_GUID = "test-world"
    do -- A stale helper response cannot donate authority to independent memory.
        M.stop(log); pawn.loc={X=0,Y=0,Z=0}; empty_native_memory()
        offer.no=offer.no+1;offer.nonce=fake_nonce(offer.no)
        oracle=function() return nil end;pump_oracle()
        M.go_to(log,{20,0,0},{local_plan=false,sprint=false});run(1)
        local active=_G.DW_MOVE;local pending=active.nav_pending
        local m=NM.new_mem('test-world');m._world='test-world'
        NM.add_route(m,{{X=0,Y=0,Z=-90},{X=500,Y=0,Z=-90},{X=1000,Y=0,Z=-90},{X=2000,Y=0,Z=-90}},{src='self'})
        _G.DW_NAVMEM=m;TEST_WALK_NATIVE.calls={}
        local reply=assert(io.open(dir..'/client_io/nav/resp.lua','w'))
        reply:write(('return {version=2,epoch="%s",nonce="%s",id=%d,ok=true,partial=false,points={{0,0,0},{20,0,0}}}'):format(pending.epoch,pending.nonce,pending.id));reply:close()
        local hb=assert(io.open(dir..'/client_io/nav/alive.lua','w'))
        hb:write(('return {version=2,epoch="33333333-3333-4333-8333-333333333333",state="recovering",updated=%d}'):format(os.time()));hb:close()
        step(1)
        check('stale helper cannot donate memory authority or input',active.memory_binding and not active.nav_binding and not active.route_feedback and pawn.input==nil and pawn.loc.X==0,active.status)
        step(30)
        check('independent memory moves only with fresh physical guard',pawn.loc.X>0 and #TEST_WALK_NATIVE.calls>0 and not active.nav_binding and not active.route_feedback,active.status)
        M.stop(log);empty_native_memory()
    end
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
    oracle = function() return nil end; pump_oracle()
    M.go_to(log, {20,0,0}, {local_plan=false}); run(1)
    local old_pending = _G.DW_MOVE.nav_pending
    local old_reply = assert(io.open(dir .. "/client_io/nav/resp.lua", "w"))
    old_reply:write(('return {version=2,epoch="%s",nonce="%s",id=%d,ok=true,points={{0,0,0},{20,0,0}}}'):format(old_pending.epoch,old_pending.nonce,old_pending.id)); old_reply:close()
    local restart = assert(io.open(dir .. "/client_io/nav/alive.lua", "w"))
    restart:write(('return {version=2,epoch="33333333-3333-4333-8333-333333333333",state="recovering",updated=%d}'):format(os.time())); restart:close()
    step(1)
    check("new helper epoch rejects old matching response", pawn.loc.X == 0 and M.status().result and M.status().result.detail:find("oracle_restarted",1,true), M.status().status)
    check("old helper response supplies no feedback", M.status().result and M.status().result.route_feedback == nil)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
    oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',goal_projected=false,points={}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    local bad = M.status()
    check("no path fails without raw movement", pawn.loc.X == 0 and bad.result and bad.result.reason == "verification_failed", bad.status)
    local f=bad.result and bad.result.route_feedback
    check("matched no path preserves false projection and requested 3D goal", f and f.goal_projected==false and f.requested_xyz[1]==20 and f.route_endpoint==nil and f.final_position[1]==0 and f.horizontal_error_m==20, f and f.goal_projected)
    _G.DW_WORLD_GUID = "other-world"
    check("terminal world replacement suppresses evidence", M.status().result.route_feedback == nil)
    _G.DW_WORLD_GUID = "test-world"
    check("terminal evidence cannot revive after world restoration", M.status().result.route_feedback == nil)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id)
        _G.DW_MOVE.goal.X = _G.DW_MOVE.goal.X + 1 -- smaller than ordinary repath threshold
        return ("return {id=%d,ok=false,reason='no_path',goal_projected=false,points={}}"):format(id)
    end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    check("changed exact goal suppresses feedback without changing failure", M.status().result and M.status().result.reason == "verification_failed" and M.status().result.route_feedback == nil)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id)
        _G.DW_MOVE.unreach = {reason="no_route"}
        return ("return {id=%d,ok=true,partial=false,goal_projected=true,points={{0,0,0},{20,0,4.62}}}"):format(id)
    end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    local rejected=M.status().result; f=rejected and rejected.route_feedback
    check("policy-rejected valid route retains endpoint evidence", rejected and rejected.reason=="verification_failed" and pawn.loc.X==0 and f and f.partial==false and f.route_endpoint[3]==4.62)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id) return ("return {id=%d,ok=true,partial=false,goal_projected=true,points={{0,0,0},{4,0,7.62}}}"):format(id) end
    pump_oracle(); M.go_to(log, {4,0,3}, {tolerance_m=0.5}); run(120)
    local short=M.status().result; f=short and short.route_feedback
    check("short route rejected for height retains endpoint evidence", short and short.reason=="verification_failed" and f and f.partial==false and f.requested_xyz[3]==3 and f.route_endpoint[3]==7.62, short and short.detail)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id) return ("return {id=%d,ok=true,partial=true,goal_projected=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(80)
    local partial = M.status()
    check("partial endpoint does not fall through to raw goal", partial.result and partial.result.reason == "verification_failed" and pawn.loc.X < 600, tostring(pawn.loc.X) .. " " .. tostring(partial.status) .. " " .. tostring(partial.result and partial.result.detail))
    f=partial.result and partial.result.route_feedback
    check("partial result carries admitted route endpoint", f and f.partial==true and f.goal_projected==true and f.route_endpoint[1]==5 and f.requested_xyz[1]==20 and f.vertical_error_m==0 and f.absolute_vertical_error_m==0)
    pc.Pawn = obj({CharacterMovement=mc})
    check("terminal pawn replacement suppresses evidence", M.status().result.route_feedback == nil)
    pc.Pawn = pawn
    check("terminal evidence cannot revive after pawn restoration", M.status().result.route_feedback == nil)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    for _, invalid in ipairs({"controller", "pawn", "foreign", "world"}) do
        oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
        pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(2)
        local active = _G.DW_MOVE
        check("retained evidence before "..invalid.." termination", active.route_feedback ~= nil)
        local original_loc, original_pc_valid, original_pawn_valid, original_dead = pawn.K2_GetActorLocation, pc.IsValid, pawn.IsValid, pawn.HealthComponent.IsDead
        local reads = 0
        pawn.K2_GetActorLocation = function(self) reads=reads+1; return original_loc(self) end
        if invalid == "controller" then pc.IsValid=function() return false end
        elseif invalid == "pawn" then pawn.IsValid=function() return false end
        elseif invalid == "foreign" then pc.Pawn=obj({CharacterMovement=mc, HealthComponent=pawn.HealthComponent})
        else pawn.HealthComponent.IsDead=function() _G.DW_WORLD_GUID="other-world"; return true end end
        step(1)
        local outcome=active.result
        check("invalid "..invalid.." finish never reads cached pawn", reads==0 and outcome and outcome.status=="failed" and outcome.route_feedback==nil, reads)
        pc.IsValid, pawn.IsValid, pc.Pawn, pawn.K2_GetActorLocation, pawn.HealthComponent.IsDead = original_pc_valid, original_pawn_valid, pawn, original_loc, original_dead
        _G.DW_WORLD_GUID="test-world"; M.stop(log); pawn.loc={X=0,Y=0,Z=0}
    end
    oracle = function(id) return ("return {id=%d,ok=true,partial=false,goal_projected=true,points={{0,0,0},{20,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,-4}, {local_plan=false}); run(200)
    local vertical=M.status().result; f=vertical and vertical.route_feedback
    check("route endpoint does not replace requested height",vertical and vertical.reason=="verification_failed" and f and f.partial==false and f.requested_xyz[3]==-4 and f.route_endpoint[3]==0 and f.vertical_error_m==4 and f.absolute_vertical_error_m==4,vertical and vertical.detail)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; _G.DW_TRAP_CAND = nil
    oracle = function(id) return ("return {id=%d,ok=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(80)
    local unknown = M.status()
    check("unknown partial endpoint fails without learning a trap", unknown.result and unknown.result.reason == "verification_failed" and pawn.loc.X < 600 and _G.DW_TRAP_CAND == nil, unknown.status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id) return ("return {id=%d,ok=true,points={{0,0,0},{1e308,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    check("overflowing converted waypoint is rejected", pawn.loc.X == 0 and M.status().result and M.status().result.reason == "verification_failed", M.status().status)
    check("malformed waypoint supplies no feedback", M.status().result and M.status().result.route_feedback == nil)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; luis.loc = { X=2000, Y=200, Z=0 }
    local evpath = dir .. "/client_io/events/move.jsonl"
    os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
    os.remove(evpath)
    oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.follow(log, "Zezima", 3, {local_plan=false}); run(80)
    local follow = M.status(); local blocked = pawn.loc.X
    check("partial routed follow remains owned and unreachable", follow.mode == "follow" and follow.status == "unreachable", follow.status)
    oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',points={}}"):format(id) end
    run(30)
    local count = 0; local events = io.open(evpath, "r")
    if events then for line in events:lines() do if line:find('"type":"unreachable"') then count=count+1 end end; events:close() end
    check("routed follow holds and emits one unreachable event", math.abs(pawn.loc.X-blocked)<1 and count==1 and M.status().mode == "follow", count)
    oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{%.2f,%.2f,0},{20,2,0}}}"):format(id,pawn.loc.X/100,pawn.loc.Y/100) end
    run(130)
    check("routed follow resumes on fresh admitted route", M.status().mode == "follow" and M.status().status == "near", M.status().status)
    M.stop(log); empty_native_memory(); pawn.loc = { X=0, Y=0, Z=0 }; oracle = nil; pump_oracle()
    local original_timeout = M.cfg.nav_timeout_s; M.cfg.nav_timeout_s = 0.5
    M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    check("missing service reports unavailable without input", pawn.loc.X == 0 and M.status().result and
        M.status().result.detail:find("oracle_unavailable", 1, true) ~= nil, M.status().result and M.status().result.detail)
    M.stop(log); M.cfg.nav_timeout_s = original_timeout
    walls={{900,1100,-500,500}}; pawn.loc={X=0,Y=0,Z=0}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
    pump_oracle()
    local saved_rename=os.rename
    os.rename=function(a,b) if tostring(b):find("req%.json$") then return nil,"denied" end return saved_rename(a,b) end
    M.go_to(log,{20,0,0},{tolerance_m=1}); run(100); os.rename=saved_rename
    check("refused rename still obtains admitted route", M.status().result and M.status().result.status == "arrived", tostring(M.status().status) .. " requests=" .. tostring(M.status().nav_requests))
    M.stop(log); empty_native_memory(); walls={}; pawn.loc={X=0,Y=0,Z=0}; oracle=nil; pump_oracle()
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{20,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log,{20,0,0},{local_plan=false}); run(1)
    local owner = _G.DWArbiter.owner
    local saved_rotation = pc.SetControlRotation
    local rotated = false
    pc.SetControlRotation = function() rotated=true; _G.DWArbiter.owner=nil end
    step(1)
    check("owner lost before input cannot dispatch", rotated and pawn.loc.X == 0 and pawn.input == nil, pawn.loc.X)
    _G.DWArbiter.owner=owner; pc.SetControlRotation=saved_rotation; M.stop(log)
    for _, boundary in ipairs({2,3}) do
        pawn.loc={X=0,Y=0,Z=0}
        oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{20,0,0}}}"):format(id) end
        pump_oracle(); M.go_to(log,{20,0,0},{local_plan=false}); run(1)
        local prior = _G.DW_MOVE.gen
        local real_loadfile, own_calls, rotations, fired = loadfile, 0, 0, false
        local original_rotation = pc.SetControlRotation
        pc.SetControlRotation=function(...) rotations=rotations+1; return original_rotation(...) end
        loadfile=function(path,...)
            local chunk,err=real_loadfile(path,...)
            if chunk and tostring(path):find("arbiter%.lua$") then
                return function()
                    local a=chunk(); local original=a.owns_move
                    a.owns_move=function(token)
                        local result=original(token); own_calls=own_calls+1
                        if not fired and own_calls==boundary then
                            fired=true; M.go_to(log,{30,0,0},{nav=false,local_plan=false})
                        end
                        return result
                    end
                    return a
                end
            end
            return chunk,err
        end
        step(1); loadfile=real_loadfile; pc.SetControlRotation=original_rotation
        local successor=_G.DW_MOVE
        check("ownership reentry at boundary "..boundary.." preserves successor", fired and successor.gen>prior and successor.mode=="go_to" and pawn.input==nil and rotations==(boundary==2 and 0 or 1), rotations)
        M.stop(log)
    end
    oracle=nil; pump_oracle()
    -- A real accepted link jump retains its existing landing transaction when the
    -- followed target crosses the primary boundary; the following input is held.
    pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=900,Y=200,Z=0}; air=0
    M.follow(log,"Zezima",3,{local_plan=false})
    local flight=_G.DW_MOVE
    local link={id="boundary-test",move="jump",from={0,0,-0.9},to={3,0,-0.9}}
    flight.link_exec={link=link,phase="run",t0=T}
    local before_jumps=pawn.jumps
    step(1)
    local accepted=flight.jump_t ~= nil and pawn.jumps == before_jumps+1 and flight.link_exec and flight.link_exec.phase=="air"
    local flight_owner=flight.owner_token
    luis.loc={X=2000,Y=200,Z=0}; step(1)
    check("boundary preserves accepted link transaction", accepted and flight.nav_deferred_required and flight.link_exec and flight.owner_token==flight_owner, flight.status)
    local injected_after_required=0
    local saved_add=pawn.AddMovementInput
    pawn.AddMovementInput=function(self,d,sc,...)
        if flight.nav_required then injected_after_required=injected_after_required+1 end
        return saved_add(self,d,sc,...)
    end
    step(100); pawn.AddMovementInput=saved_add
    check("landing completes before required-route hold", flight.link_exec==nil and flight.nav_required and flight.status=="planning" and injected_after_required==0, flight.status)
    M.stop(log); pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=900,Y=200,Z=0}; air=0
    M.follow(log,"Zezima",3,{local_plan=false})
    flight=_G.DW_MOVE
    flight.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}
    flight.lwp=2; flight.lp_jumped={}
    before_jumps=pawn.jumps; step(1)
    local ordinary_accepted=flight.jump_t ~= nil and pawn.jumps==before_jumps+1
    luis.loc={X=2000,Y=200,Z=0}; step(100)
    check("ordinary jump cannot repeatedly bypass authority", ordinary_accepted and pawn.jumps==before_jumps+1 and flight.nav_required and flight.status=="planning", string.format("status=%s required=%s jumps=%s accepted=%s deferred=%s jump_t=%s release=%s",tostring(flight.status),tostring(flight.nav_required),tostring(pawn.jumps-before_jumps),tostring(ordinary_accepted),tostring(flight.nav_deferred_required),tostring(flight.jump_t),tostring(flight.jump_release)))
    M.stop(log); pawn.loc={X=0,Y=0,Z=0}
    M.go_to(log, {20,0,0}, {nav=false,local_plan=false}); run(60)
    check("explicit direct opt-out moves", pawn.loc.X > 0, pawn.loc.X)
    M.stop(log); empty_native_memory()
    do -- Actual arbiter + mover + interaction episode, no fake ownership layer.
        local A=assert(loadfile(dir.."/client_mod/scripts/arbiter.lua"))(); A.set_move(M)
        local SK=assert(loadfile(here.."/../scripts/skills.lua"))()
        pawn.loc={X=0,Y=0,Z=0}; air=0; M.stop(log)
        oracle=function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
        pump_oracle(); local original=M.go_to(log,{20,0,0},{local_plan=false}); run(2)
        local old_feedback=_G.DW_MOVE.route_feedback
        local reflex=A.request(log,{name="feedback:reflex",level="reflex",uses_move=true})
        A.release(log,reflex.token,"done")
        local resumed_gen=_G.DW_MOVE.gen
        oracle=function(id) return ("return {id=%d,ok=false,reason='no_path',goal_projected=false,points={}}"):format(id) end
        pump_oracle(); run(20)
        local resumed=M.status().result
        check("real suspend resume cannot donate old generation feedback",original.ok and old_feedback and reflex.ok and resumed_gen~=original.gen and resumed and resumed.status=="failed" and (not resumed.route_feedback or resumed.route_feedback.generation~=original.gen))
        M.stop(log); pawn.loc={X=0,Y=0,Z=0}; oracle=nil; pump_oracle()
        local faces=0
        SK.W.interaction_point=function(_,thing) return thing.position,"actor_origin" end
        SK.W.resting_in=function() return nil end
        SK.W.face=function() faces=faces+1 end
        local api={module=function(n) if n=="arbiter" then return A elseif n=="move" then return M end end,
            my_position=function() return {pawn.loc.X/100,pawn.loc.Y/100,pawn.loc.Z/100} end,
            counts=function() return {} end,
            fail=function(reason,data) return {ok=false,reason=reason,data=data} end,
            call=function(mod,fn,...) local r=M[fn](nil,...);return {ok=r.ok,reason=r.reason,data=r} end,
            move_status=function() return M.status() end}
        pawn.loc={X=0,Y=0,Z=0};air=0;M.stop(log)
        local owner=A.request(log,{name="test:parent",level="command",uses_move=true,adopt=false})
        local thing={id="target",name="target",category="items",position={4,0,0}}
        local e=SK._new_episode(api,thing,{})
        local gen0=_G.DW_MOVE.gen;local denied=SK._episode_poll(api,e,T,nil)
        check("nested nil parent denied before movement",denied and not denied.ok and _G.DW_MOVE.gen==gen0 and _G.DW_MOVE.mode=="idle")
        local unowned=M.go_to(log,{4,0,0},{nav=false,local_plan=false})
        local invalid=M.go_to(log,{4,0,0},{nav=false,local_plan=false,owner_token=owner.token+100})
        check("direct nil or invalid parent rejected before mutation",not unowned.ok and not invalid.ok and _G.DW_MOVE.gen==gen0 and _G.DW_MOVE.mode=="idle" and A.owns_move(owner.token))
        local p=SK._episode_poll(api,e,T,owner.token)
        local child=_G.DW_MOVE.gen
        check("nested episode uses parent token",p==nil and e.child_gen==child and _G.DW_MOVE.owner_token==owner.token and A.owns_move(owner.token))
        pawn.loc={X=250,Y=0,Z=0}
        local stop0=M.stop_owned;M.stop_owned=function() return {ok=false,reason="verification_failed"} end
        SK._episode_poll(api,e,T+0.1,owner.token)
        check("unconfirmed child cleanup cannot face",faces==0 and e.phase=="approach" and e.child_gen==child and A.owns_move(owner.token))
        M.stop_owned=stop0;SK._episode_poll(api,e,T+0.2,owner.token)
        check("nested near transition stops exact child before facing",faces==1 and e.phase=="face" and _G.DW_MOVE.mode=="idle" and A.owns_move(owner.token))
        -- Focus shortcut uses exact actor and must drain the real running child.
        local old_detector=SK.W.detector
        local focus={none=true}
        SK.W.detector=function() return focus end
        pawn.loc={X=0,Y=0,Z=0}
        local fe=SK._new_episode(api,thing,{})
        SK._episode_poll(api,fe,T,owner.token)
        local focus_gen=fe.child_gen
        focus={actor="other"};SK._episode_poll(api,fe,T+.1,owner.token)
        check("wrong focus cannot shortcut",fe.phase=="approach" and _G.DW_MOVE.mode=="go_to")
        focus={actor="target"};SK._episode_poll(api,fe,T+.15,owner.token)
        check("distant exact focus cannot bypass reach",fe.phase=="approach" and _G.DW_MOVE.mode=="go_to")
        pawn.loc={X=250,Y=0,Z=0};fe.spots={{100,0,0}};fe.spot_i=1
        focus={none=true,actor="target"};SK._episode_poll(api,fe,T+.16,owner.token)
        check("explicit none rejects matching actor within reach",fe.phase=="approach" and _G.DW_MOVE.mode=="go_to")
        focus={actor="target",class="Thing",prompt="Use"}
        local real_stop=M.stop_owned;M.stop_owned=function() return {ok=false,reason="verification_failed"} end
        SK._episode_poll(api,fe,T+.2,owner.token)
        check("exact focus waits for confirmed child cleanup",fe.phase=="approach" and fe.child_gen==focus_gen)
        M.stop_owned=real_stop;SK._episode_poll(api,fe,T+.3,owner.token)
        check("exact focus drains moving child outside stand tolerance",fe.phase=="face" and _G.DW_MOVE.mode=="idle")
        focus={none=true};local oldcall=api.call;local presses=0
        api.call=function(mod,fn,...) if mod=="inventory" then presses=presses+1;return {ok=true} end return oldcall(mod,fn,...) end
        SK._episode_poll(api,fe,T+.4,owner.token)
        check("lost focus is rechecked before press",presses==0)
        api.call=oldcall
        local test_focus=SK._new_episode(api,thing,{})
        focus={actor="target"};pawn.loc={X=0,Y=0,Z=200}
        test_focus.spots={{0,0,0}};test_focus.spot_i=1;test_focus.ipoint={4,0,0};test_focus.small=false
        SK._episode_poll(api,test_focus,T+.5,owner.token)
        check("exact focus does not bypass on-top guard",test_focus.phase=="approach")
        if _G.DW_MOVE.mode~="idle" then M.stop_owned(log,_G.DW_MOVE.gen,owner.token) end
        pawn.loc={X=0,Y=0,Z=0}
        test_focus=SK._new_episode(api,thing,{})
        local gen_before=_G.DW_MOVE.gen
        SK._episode_poll(api,test_focus,T+.6,owner.token+999)
        check("exact focus cannot use foreign owner",test_focus.phase=="approach" and _G.DW_MOVE.gen==gen_before)
        _G.DW_PAUSE=true;SK._episode_poll(api,test_focus,T+.7,owner.token);_G.DW_PAUSE=nil
        check("paused exact focus does not change phase",test_focus.phase=="approach")
        local reflex=A.request(log,{name="focus:reflex",level="reflex",uses_move=false,adopt=false})
        SK._episode_poll(api,test_focus,T+.8,owner.token)
        check("suspended parent cannot use exact focus",reflex.ok and test_focus.phase=="approach" and A.owner() and A.owner().token==reflex.token)
        A.release(log,reflex.token,"done")
        SK.W.detector=old_detector
        A.release(log,owner.token,"done")
        -- Actual Lodestone handler + real skills episode + mover + arbiter.
        local L=assert(loadfile(here.."/../scripts/lodestone.lua"))()
        local IN={claim=nil}
        IN.owner=function() return IN.claim end
        IN.claim_if_free=function(_,name) if IN.claim then return false end IN.claim={owner=name};return true end
        IN.release_if_owned=function(_,name) if IN.claim and IN.claim.owner==name then IN.claim=nil;return true end return false end
        L.W.registry_lodestones=function() return {{key="aaaa",guid={},position={0,0,0}},{key="bbbb",guid={},position={20,0,0}}} end
        L.W.can_teleport=function() return true end;L.W.cost=function() return 1,true end
        L.W.cost_item=function() return {name="Rune"} end;L.W.arm_hook=function() return true end
        L.W.map_open=function() return false end
        L.W.map_closed=function() return true end
        api.module=function(n) if n=="arbiter" then return A elseif n=="move" then return M elseif n=="skills" then return SK elseif n=="input" then return IN end end
        api.census_things=function() return {{id="lodestone",kind="lodestone",category="interactables",actions={"interact"},position={4,0,0},distance=4}} end
        api.now=function() return T end;api.log=log;api.reflex_owns_pawn=function() return false end
        pawn.loc={X=0,Y=0,Z=0}
        local lh=L.HANDLERS.teleport(log,{to="lodestone:bbbb"},{api=api,id="lodestone-composed"})
        local la=lh.pending;la.started=T;la.poll(la)
        local lowner=_G.DWArbiter.owner;local lgen=_G.DW_MOVE.gen
        check("real lodestone episode owns mover with no prompt",lowner and _G.DW_MOVE.mode=="go_to" and _G.DW_MOVE.owner_token==lowner.token and IN.claim~=nil)
        local suspended=A.request(log,{name="lodestone:reflex",level="reflex",uses_move=false,adopt=false})
        local stopped_gen=_G.DW_MOVE.gen
        A.release(log,suspended.token,"done")
        local resumed=la.poll(la)
        check("real lodestone resumes after reflex",suspended.ok and resumed==nil and A.owner() and A.owner().token==lowner.token and _G.DW_MOVE.mode=="go_to" and _G.DW_MOVE.gen>stopped_gen and _G.DW_MOVE.owner_token==lowner.token)
        la.cancel(la)
        check("real lodestone cancel drains its child and screen",_G.DW_MOVE.gen>=lgen and _G.DW_MOVE.mode=="idle" and A.owner()==nil and IN.claim==nil, string.format("gen=%s expected=%s mode=%s owner=%s claim=%s",tostring(_G.DW_MOVE.gen),tostring(lgen),tostring(_G.DW_MOVE.mode),tostring(A.owner() and A.owner().token),tostring(IN.claim and IN.claim.owner)))
        -- Compose the actual candidate crafting action with skills, mover and arbiter.
        local C=assert(loadfile(here.."/../scripts/crafting.lua"))()
        local function up(fn,name)
            for i=1,40 do local n,v=debug.getupvalue(fn,i);if not n then break end;if n==name then return v end end
        end
        local craft_fn=up(C.HANDLERS.craft,"fn");local make_action=craft_fn and up(craft_fn,"action")
        assert(make_action,"actual crafting action closure")
        C.W.station_state=function() return {} end
        api.module=function(n) if n=="arbiter" then return A elseif n=="move" then return M elseif n=="skills" then return SK elseif n=="crafting" then return C end end
        api.actor_of=function() return {} end;api.reflex_owns_pawn=function() return false end;api.now=function() return T end
        api.log=log
        owner=A.request(log,{name="skill:craft",level="command",uses_move=true,adopt=false});pawn.loc={X=0,Y=0,Z=0}
        local job={kind="craft",phase="collect",own="owner",token=owner.token,station={id="station",name="Station"},
                   plan={kind="processing"},ep=SK._new_episode(api,thing,{})}
        local pending=make_action(api,{id="composed"},job).pending;pending.started=T
        pending.poll(pending)
        local captured=job.ep.child_gen
        check("actual craft pickup propagates owner into mover",captured and _G.DW_MOVE.owner_token==owner.token and _G.DW_MOVE.gen==captured)
        pawn.loc={X=250,Y=0,Z=0};pending.poll(pending)
        check("actual craft pickup drains child before face",job.ep.phase=="face" and _G.DW_MOVE.mode=="idle" and A.owns_move(owner.token))
        pending.cancel(pending)
        check("actual craft cancellation releases only after child idle",_G.DW_MOVE.mode=="idle" and A.owner()==nil)
        owner=A.request(log,{name="skill:craft",level="command",uses_move=true,adopt=false});pawn.loc={X=0,Y=0,Z=0}
        job={kind="craft",phase="collect",own="owner",token=owner.token,station={id="station",name="Station"},
             plan={kind="processing"},ep=SK._new_episode(api,thing,{})}
        pending=make_action(api,{id="supersession"},job).pending;pending.started=T;pending.poll(pending)
        local old_child=job.ep.child_gen
        local same_parent=M.go_to(log,{9,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        local same_handle=_G.DW_MOVE.handle
        local blocked=pending.poll(pending)
        check("craft terminal retains same-parent successor",blocked==nil and same_parent.gen>old_child and _G.DW_MOVE.gen==same_parent.gen and _G.DW_MOVE.handle==same_handle and A.owns_move(owner.token))
        pending.cancel(pending)
        check("craft cancellation retains same-parent successor",_G.DW_MOVE.gen==same_parent.gen and _G.DW_MOVE.handle==same_handle and A.owns_move(owner.token))
        M.stop_owned(log,same_parent.gen,owner.token)
        local ended=pending.poll(pending)
        if not ended then ended=pending.poll(pending) end
        check("craft releases only after successor ends",ended and not ended.ok and A.owner()==nil)
        -- A stale child must never stop a successor, even with the same parent.
        owner=A.request(log,{name="test:parent2",level="command",uses_move=true,adopt=false});pawn.loc={X=0,Y=0,Z=0}
        e=SK._new_episode(api,thing,{})
        SK._episode_poll(api,e,T,owner.token);local prior=e.child_gen
        local newer=M.go_to(log,{9,0,0},{nav=false,local_plan=false,owner_token=owner.token});local handle=_G.DW_MOVE.handle
        local result=SK._episode_poll(api,e,T+0.1,owner.token)
        check("nested stale cleanup preserves successor",newer.ok and newer.gen>prior and _G.DW_MOVE.gen==newer.gen and _G.DW_MOVE.handle==handle and _G.DW_MOVE.mode=="go_to")
        M.stop_owned(log,newer.gen,owner.token);A.release(log,owner.token,"done")
        -- Suspension ends the child under arbiter context; cleanup never stops reflex.
        owner=A.request(log,{name="test:parent3",level="command",uses_move=true,adopt=false});pawn.loc={X=0,Y=0,Z=0}
        e=SK._new_episode(api,thing,{});SK._episode_poll(api,e,T,owner.token);prior=e.child_gen
        local reflex=A.request(log,{name="test:reflex",level="reflex",uses_move=true})
        local after=_G.DW_MOVE.gen;local cleanup=SK._episode_cleanup(api,e,owner.token)
        check("suspended child cleanup never stops reflex",reflex.ok and _G.DWArbiter.owner.token==reflex.token and _G.DW_MOVE.gen==after and after>prior and cleanup==true)
        A.release(log,reflex.token,"done");A.release(log,owner.token,"done")
        -- Native release can reenter; stale checked stop cannot mutate successor.
        owner=A.request(log,{name="test:parent4",level="command",uses_move=true,adopt=false})
        local moving=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        local old_stop=pawn.StopJumping;local changed=false
        pawn.StopJumping=function() changed=true;_G.DWArbiter.owner={token=99999,state="owner",uses_move=true} end
        local stopped=M.stop_owned(log,moving.gen,owner.token);pawn.StopJumping=old_stop
        check("checked stop reentry preserves successor owner",changed and not stopped.ok and _G.DWArbiter.owner.token==99999 and _G.DW_MOVE.gen==moving.gen)
        _G.DWArbiter.owner=nil;_G.DW_MOVE.mode="idle"
        owner=A.request(log,{name="test:replace-reentry",level="command",uses_move=true,adopt=false})
        local old=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token});local st=_G.DW_MOVE
        local fired=false;local successor
        st.ws_job={cancel=function() fired=true;successor=M.go_to(log,{8,0,0},{nav=false,local_plan=false,owner_token=owner.token}) end}
        local outer=M.go_to(log,{7,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        check("start cancel reentry preserves successor",fired and successor and successor.ok and not outer.ok and st.gen==successor.gen and st.mode=="go_to" and st.handle~=nil)
        M.stop_owned(log,successor.gen,owner.token)
        M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token});st=_G.DW_MOVE
        st.trip={{X=0,Y=0,Z=-90},{X=10000,Y=0,Z=-90}};st.trip_ok=true
        fired=false;successor=nil
        local function reentrant_log(message)
            if not fired and message:find("memory: self route",1,true) then
                fired=true;successor=M.go_to(log,{9,0,0},{nav=false,local_plan=false,owner_token=owner.token})
            end
        end
        outer=M.go_to(reentrant_log,{7,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        check("start memory-flush reentry preserves successor",fired and successor and successor.ok and not outer.ok and st.gen==successor.gen and st.mode=="go_to" and st.handle~=nil)
        M.stop_owned(log,successor.gen,owner.token);A.release(log,owner.token,"done")
        owner=A.request(log,{name="test:world-change",level="command",uses_move=true,adopt=false});pawn.loc={X=0,Y=0,Z=0}
        e=SK._new_episode(api,thing,{});SK._episode_poll(api,e,T,owner.token);local original_world=_G.DW_WORLD_GUID
        _G.DW_WORLD_GUID="different-world";pawn.loc={X=250,Y=0,Z=0};local old_faces=faces
        SK._episode_poll(api,e,T+.1,owner.token)
        check("world replacement cannot authorize face or stop",faces==old_faces and e.child_gen~=nil and _G.DW_MOVE.mode=="go_to")
        _G.DW_WORLD_GUID=original_world;M.stop_owned(log,e.child_gen,owner.token);A.release(log,owner.token,"done")
        owner=A.request(log,{name="test:stop-reentry",level="command",uses_move=true,adopt=false})
        local pending_move=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        local oldstop=pawn.StopJumping;successor=nil
        pawn.StopJumping=function() pawn.StopJumping=oldstop;successor=M.go_to(log,{8,0,0},{nav=false,local_plan=false,owner_token=owner.token}) end
        local stale=M.stop_owned(log,pending_move.gen,owner.token);pawn.StopJumping=oldstop
        check("checked stop preserves reentrant same-owner successor",successor and successor.ok and not stale.ok and _G.DW_MOVE.gen==successor.gen and _G.DW_MOVE.mode=="go_to")
        M.stop_owned(log,successor.gen,owner.token);A.release(log,owner.token,"done")
        owner=A.request(log,{name="test:stop-world",level="command",uses_move=true,adopt=false})
        pending_move=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token});oldstop=pawn.StopJumping
        original_world=_G.DW_WORLD_GUID
        pawn.StopJumping=function() _G.DW_WORLD_GUID="changed-during-stop" end
        stale=M.stop_owned(log,pending_move.gen,owner.token);pawn.StopJumping=oldstop
        check("checked stop rejects world change during native release",not stale.ok and _G.DW_MOVE.gen==pending_move.gen and _G.DW_MOVE.mode=="go_to")
        _G.DW_WORLD_GUID=original_world;M.stop_owned(log,pending_move.gen,owner.token);A.release(log,owner.token,"done")
        local original_life=_G.DW_LIFE;_G.DW_LIFE={move_death_seq=41}
        local capsule=pawn.CapsuleComponent.GetScaledCapsuleHalfHeight
        pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=function() _G.DW_LIFE.move_death_seq=42;return 90 end
        local before=_G.DW_MOVE.gen;local refused=M.go_to(log,{5,0,0},{nav=false,local_plan=false})
        pawn.CapsuleComponent.GetScaledCapsuleHalfHeight=capsule;_G.DW_LIFE=original_life
        check("death sequence change rejects same healthy pawn before mutation",not refused.ok and _G.DW_MOVE.gen==before and _G.DW_MOVE.mode=="idle")
        owner=A.request(log,{name="test:provisional-parent",level="command",uses_move=true,adopt=false})
        local saved_pawn=pc.Pawn;pc.Pawn=nil;local foreign={token=99001,state="owner",uses_move=true};local fired=false
        setmetatable(pc,{__index=function(_,k)
            if k=="Pawn" then
                if _G.DW_MOVE.start_guard and not fired then fired=true;_G.DWArbiter.owner=foreign end
                return saved_pawn
            end
        end})
        local rejected=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        setmetatable(pc,nil);pc.Pawn=saved_pawn
        check("foreign takeover rolls back only provisional move",fired and not rejected.ok and _G.DWArbiter.owner==foreign and _G.DW_MOVE.mode=="idle" and _G.DW_MOVE.handle==nil)
        _G.DWArbiter.owner=nil
        original_life=_G.DW_LIFE;_G.DW_LIFE={move_death_seq=51}
        owner=A.request(log,{name="test:provisional-life",level="command",uses_move=true,adopt=false})
        saved_pawn=pc.Pawn;pc.Pawn=nil;fired=false
        setmetatable(pc,{__index=function(_,k)
            if k=="Pawn" then
                if _G.DW_MOVE.start_guard and not fired then fired=true;_G.DW_LIFE.move_death_seq=52 end
                return saved_pawn
            end
        end})
        rejected=M.go_to(log,{5,0,0},{nav=false,local_plan=false,owner_token=owner.token})
        setmetatable(pc,nil);pc.Pawn=saved_pawn;_G.DW_LIFE=original_life
        check("death sequence change during provisional admission rolls back",fired and not rejected.ok and _G.DW_MOVE.mode=="idle" and _G.DW_MOVE.handle==nil and A.owns_move(owner.token))
        A.release(log,owner.token,"done")
    end
    do
        local A=assert(loadfile(dir.."/client_mod/scripts/arbiter.lua"))(); A.set_move(M)
        _G.DWArbiter.owner=nil;_G.DWArbiter.stack={};_G.DW_MOVE.mode="idle";pawn.loc={X=0,Y=0,Z=0}
        local d=M.go_to(log,{20,0,0},{nav=false,local_plan=false});local prior=_G.DW_MOVE.owner_token
        local high=A.request(log,{name="restore-reflex",level="reflex",uses_move=true})
        local rel=A.release(log,high.token,"done")
        local owner=A.owner()
        check("nested implicit suspension restores original",d.ok and owner and owner.token==prior and _G.DW_MOVE.owner_token==prior and _G.DW_MOVE.mode=="go_to",
              "prior="..tostring(prior).." owner="..tostring(owner and owner.token).." sttoken="..tostring(_G.DW_MOVE.owner_token).." mode="..tostring(_G.DW_MOVE.mode).." resumed="..tostring(rel.resumed))
        M.stop(log)
    end
    os.exit(fails == 0 and 0 or 1)
end

-- 2. explicit direct mode: wall -> stuck ladder jumps over it
walls = { { 900, 1000, -500, 500 } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil; pawn.jumps = 0
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav=false })
run(150)
s = M.status()
check("straight fallback", s.source == "straight", s.source)
check("jumped when stuck", (s.jumps or 0) >= 1, s.jumps)
check("arrived after unstuck", s.result and s.result.status == "arrived", s.result and s.result.reason)

-- 3. follow a moving player, idle when near, stop
walls = {}; pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 3000, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',points={}}"):format(id) end
M.follow(log, "Zezima", 3, {nav=false})
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
M.go_to(log, { 100, 0, 0 }, {nav=false})
local M2 = dofile(MOVE)
M2.stop(log)
run(5)
local n = 0; for _ in pairs(loops) do n = n + 1 end
check("no loops left after stop from a fresh load", n == 0, n)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 5. Direct-mode breadcrumb/local mechanism: leader walks around the wall's end.
walls = { { 900, 1100, -2000, 600, true } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 200, Y = 0, Z = 0 }
oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
local route = { { 200, 0 }, { 200, 1000 }, { 2000, 1000 }, { 2000, 0 } }
local seg = 1
local max_pawn_y = 0
frame_hook = function()
    max_pawn_y = math.max(max_pawn_y, pawn.loc.Y)
    local tgt = route[seg + 1]
    if not tgt then return end
    local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
    local d = math.sqrt(dx * dx + dy * dy)
    local sp = 400 * DT
    if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg = seg + 1
    else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
end
M.follow(log, "Zezima", 3, {nav=false})
run(400)
s = M.status()
local dl = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
check("breadcrumbs: reached leader around the wall", dl < 450, string.format("d=%.0f status=%s res=%s", dl, tostring(s.status), tostring(s.result and s.result.reason)))
check("direct follow actually went around the wall", max_pawn_y > 600, max_pawn_y)
M.stop(log)
frame_hook = nil

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 6. bounded give-up: walled in, no trail -> stops with "stuck" after > 5 s, not a loop
walls = { { 300, 400, -5000, 5000, true } }
pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil
luis.loc = { X = 90000, Y = 90000, Z = 0 } -- nobody near to lead us out
local t_start = T
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 120, nav=false })
run(1200)
s = M.status()
check("go_to gives up (stuck or unreachable)", s.result and (s.result.reason == "stuck" or s.result.reason == "unreachable"), s.result and s.result.reason)
check("gives up after > 5 s, bounded (ladder incl. Bug2 both sides)", s.result and (T - t_start) > 5, T - t_start)
check("tried the local planner / backtrack before giving up", (s.backtracks or 0) >= 1 or (s.lp_runs or 0) >= 2, s.lp_runs)
local stuck_logged = false
for _, l in ipairs(logs) do if l:find("move: stuck n=") and l:find("aim=") then stuck_logged = true end end
check("stuck events log me/aim/goal/waypoints", stuck_logged)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
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
M.follow(log, "Zezima", 3, {nav=false})
run(500)
s = M.status()
local dl = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
check("leader on a plateau: reached him via his trail", dl < 450 and math.abs(pawn.loc.Z - luis.loc.Z) < 60,
    string.format("d=%.0f dz=%.0f status=%s res=%s trail=%s lp_fail=%s", dl, pawn.loc.Z - luis.loc.Z, tostring(s.status),
        tostring(s.result and s.result.reason), tostring(s.trail_entries), tostring(s.lp_fail)))
-- Correct ramp normals can keep direct pursuit valid. The preceding assertion
-- requires actual arrival/elevation, without prescribing a particular router.
if os.getenv("DBG8") then for i = math.max(1, #logs - 40), #logs do print("  " .. logs[i]) end end
M.stop(log)
frame_hook = nil
raised = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
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
M.follow(log, "Zezima", 3, {nav=false})
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

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
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

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 11. world-teardown guard: while _G.DW_PAUSE is set, the loop makes no engine calls at all
walls = {}; oracle = nil
pawn.loc = { X = 0, Y = 0, Z = 0 }
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav=false })
_G.DW_PAUSE = true
local calls = 0
local real_add = pawn.AddMovementInput
pawn.AddMovementInput = function(self, d, sc) calls = calls + 1; return real_add(self, d, sc) end
run(30)
check("paused: no movement input / no engine calls", calls == 0 and pawn.loc.X == 0, calls)
check("paused: start() refuses", not M.go_to(log, { 1, 1, 0 }, {}).ok)
_G.DW_PAUSE = nil
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav=false })
run(100)
if os.getenv("DBG11") then for i = math.max(1, #logs - 12), #logs do print("  " .. logs[i]) end; print("POS", pawn.loc.X, pawn.loc.Y, "walls", #walls, "raised", #raised) end
check("unpaused: moves again", M.status().result and M.status().result.status == "arrived", M.status().status)
pawn.AddMovementInput = real_add

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
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
M3.follow(log, "Zezima", 3, {nav=false})
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
M4.follow(log, "Zezima", 3, {nav=false})
run(400)
s = M4.status()
check("unreachable reason = needs:DoubleJump", s.unreachable and s.unreachable.reason == "needs:DoubleJump", s.unreachable and s.unreachable.reason)
M4.stop(log)
os.remove(dir .. "/client_mod/scripts/traverse_learn.lua")
raised, portals = {}, {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 13. self-collision regression (live 19:22): with Claude's gear blocking traces, an open-field
--     go_to must not see "walls" around him (no endless wall_ahead plans, no "walls everywhere")
GEAR = true
walls = { { 900, 1000, -300, 300 } } -- one real (jumpable) obstacle so a plan is needed
oracle = nil; raised = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }
local nlog0 = #logs
M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav=false })
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

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
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

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 15. NAVIGATION MEMORY: a walled pit (respawn trap) whose only exit is 15 m north, outside the
--     9 m planner window; the goal is east, beyond the east wall.
local PIT = { { 300, 400, -2000, 1500, true }, { -400, -300, -2000, 1500, true }, { -400, 400, -400, -300, true } }
local function pit_world() walls = PIT; raised = {}; oracle = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil end
local seedf = dir .. "/data/nav/L_World_seeds.json"
local memf = dir .. "/data/skills/test-world/nav_memory.json"
os.remove(memf); _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
-- (a) seeded trap: the seed's exit gets him out
do local f = io.open(seedf, "w"); f:write([==[{"v":1,"traps":[{"id":"pit","center":[0,0,-0.9],"radius_m":5,"z_max":0.5,"z_min":-3,
  "exit":[[0,8,-0.9],[0,16,-0.9],[0,18,-0.9]]}],"taboos":[],"routes":[]}]==]); f:close() end
pit_world()
local MN = dofile(MOVE)
MN.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
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
MB.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav=false })
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
MB.follow(log, "Zezima", 3, {nav=false})
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
MB2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
run(500)
s = MB2.status()
if os.getenv("DBG15") then for i = math.max(1, #logs - 14), #logs do print("  " .. logs[i]) end; local fm2 = io.open(memf); if fm2 then print("MEM", (fm2:read("a"):gsub("%s+", " "):sub(1, 900))); fm2:close() end end
check("memory (b3): learned exit -> unaided go_to out of the pit", s.result and s.result.status == "arrived", tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason))
MB2.stop(log)
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 16. BUG2: a 34 m tall wall across the way, its north end 14 m off (outside the 9 m planner window),
--     no oracle, no memory, nobody to ask: wall-following rounds it and the go_to arrives
walls = { { 500, 600, -2000, 1400, true } }
raised = {}; oracle = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MB2b = dofile(MOVE)
MB2b.go_to(log, { 15, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
run(900)
s = MB2b.status()
local bug_used = false
for _, l in ipairs(logs) do if l:find("bug2 wall%-following") then bug_used = true end end
check("bug2: rounds a long wall and arrives", s.result and s.result.status == "arrived" and bug_used,
    tostring(s.result and s.result.status) .. " bug=" .. tostring(bug_used))
MB2b.stop(log)
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 17. ASK FOR HELP: in the pit with Luis near: "lead_me" event, go_to waits, Luis walks out, Claude
--     follows his trail, then carries on to the goal by himself (one go_to, one result)
local evf = dir .. "/client_io/events/move.jsonl"
os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
os.remove(evf)
walls = PIT; raised = {}; oracle = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = -150, Y = 300, Z = 0 }
local MH = dofile(MOVE)
MH.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 300, nav=false })
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

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 18. FELLED LOG: a 50 cm log across the whole way (no way round): hop it, don't plan around it
walls = { { 900, 960, -5000, 5000 } } -- short wall = jumpable (fake: 80 cm)
raised = {}; oracle = nil; lakes = {}
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 0 }
local ML = dofile(MOVE)
local t_log = T
ML.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav=false })
run(300)
s = ML.status()
check("log: hops the felled log and arrives quickly", s.result and s.result.status == "arrived" and (T - t_log) < 30,
    tostring(s.result and s.result.status) .. string.format(" t=%.0f", T - t_log))
ML.stop(log)
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 19. WATER: a lake straight across the way; the first crossing learns the water cells (persisted),
--     the second trip goes round (less time in water)
lakes = { { 500, 1500, -500, 500 } }
walls = {}; raised = {}; oracle = nil
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MW = dofile(MOVE)
water_frames = 0
MW.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
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
MW2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
run(600)
local w2 = water_frames
if os.getenv("DBG19") then for _, l in ipairs(logs) do if l:find("water sense") then print("  WS " .. l) end end; for i = math.max(1, #logs - 14), #logs do print("  " .. logs[i]) end; local mem = _G.DW_NAVMEM; local n = 0; for _ in pairs(mem and mem.water or {}) do n = n + 1 end; print("WATER cells", n) end
s = MW2.status()
check("water: second trip goes round (less wading)", s.result and s.result.status == "arrived" and w2 < w1 * 0.5,
    string.format("w1=%d w2=%d %s", w1, w2, tostring(s.result and s.result.status)))
check("water detour does not report unrelated route feedback", s.result and s.result.route_feedback == nil)
MW2.stop(log)
lakes = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 20. TRACE PROFILE regression: the capsule reports "Custom" (not a preset); traces must not use it
--     (the engine finds no such profile and returns no hit), but a validated preset ("Player"), and
--     Visibility when no preset validates
walls = { { 900, 1000, -300, 300, true } }; raised = {}; oracle = nil; lakes = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 90000, Y = 90000, Z = 0 }
profile_not_found = 0
_G.DW_TRACE_PROFILE = nil
local MP = dofile(MOVE)
MP.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav=false })
run(400)
s = MP.status()
check("profile: never traces with the capsule's 'Custom' name", profile_not_found == 0, profile_not_found)
check("profile: a validated preset is used", s.trace_profile == "Player", tostring(s.trace_profile))
check("profile: planning works (arrives round the wall)", s.result and s.result.status == "arrived", s.result and s.result.status)
MP.stop(log)
VALID_PROFILES = {} -- a game with neither preset: fall back to Visibility, still plans
_G.DW_TRACE_PROFILE = nil -- a new client run re-validates
_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MP2 = dofile(MOVE)
MP2.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav=false })
run(400)
s = MP2.status()
check("profile: no preset -> Visibility fallback, still arrives", s.trace_profile == "visibility" and s.result and s.result.status == "arrived",
    tostring(s.trace_profile) .. " " .. tostring(s.result and s.result.status))
MP2.stop(log)
VALID_PROFILES = { Player = true, Pawn = true }
walls = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 21. MAIN MENU: the controller's pawn is a DefaultPawn (no CharacterMovement) -> refuse / pause
local real_cm = pawn.CharacterMovement
pawn.CharacterMovement = nil
local MM = dofile(MOVE)
local rr = MM.go_to(log, { 5, 0, 0 }, {})
check("menu: refuses to drive a non-character pawn", rr.ok == false, rr.error)
pawn.CharacterMovement = real_cm

-- 22. DOUBLE JUMP: a 2.3 m ledge (above the 1.05 m single jump) across the whole way.
--     (a) with the perk but NO measured envelope: no double-jump edges -> the go_to reports unreachable
--     (b) with data/envelopes/Claude.json (dj_up_m 2.6, delay 0.33): a planned double jump gets up
local envf = dir .. "/data/envelopes/Claude.json"
os.execute('mkdir "' .. (dir .. "/data/envelopes"):gsub("/", "\\") .. '" 2>nul')
os.remove(envf)
HAS_DJ = true
walls = {}; oracle = nil; lakes = {}
raised = { { 800, 4000, -5000, 5000, 230, 230 } }
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MD = dofile(MOVE)
local nlog22 = #logs
MD.go_to(log, { 15, 0, 2.3 }, { tolerance_m = 1.5, timeout_s = 90, nav=false })
run(900)
s = MD.status()
local planned_d = false
for i = nlog22 + 1, #logs do
    local acts = logs[i]:match("local path %d+ pts %[(%a*)%]")
    if acts and acts:find("d") then planned_d = true end
end
-- (the stuck ladder may still TRY a double jump with the perk; only PLANNED edges wait for a measurement)
check("dj (a): unmeasured -> the planner never plans a double-jump edge", not planned_d)
MD.stop(log)
do local f = io.open(envf, "w"); f:write('{"character":"Claude","measured":"test","jump_up_m":{"stand":1.05},"dj_up_m":2.6,"dj_delay_s":0.33,"measurement_provenance":{"jump_up_m.stand":{"verified":true},"dj_up_m":{"verified":true}}}'); f:close() end
_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
pawn.loc = { X = 0, Y = 0, Z = 0 }
local MD2 = dofile(MOVE)
MD2.go_to(log, { 15, 0, 2.3 }, { tolerance_m = 1.5, timeout_s = 90, nav=false })
run(600)
s = MD2.status()
local planned_d2 = false
for i = math.max(1, #logs - 60), #logs do
    local acts = logs[i]:match("local path %d+ pts %[(%a*)%]")
    if acts and acts:find("d") then planned_d2 = true end
end
check("dj (b): measured envelope -> planned double jump up the ledge", s.result and s.result.status == "arrived" and planned_d2,
    tostring(s.result and s.result.status) .. " dj=" .. tostring(s.double_jumps) .. " env=" .. tostring(s.env and s.env.source))
MD2.stop(log)
local function envelope_fixture(text)
    local f = assert(io.open(envf, "wb")); f:write(text); f:close()
    return MD2._envelope(pawn, pc)
end
local legacy = envelope_fixture('{"jump_up_m":{"stand":1.05},"dj_up_m":2.6,"windstep_up_m":5,"measurement_provenance":{"jump_up_m.stand":{"verified":true}}}')
local legacy_caps = MD2.traverse_caps(legacy, { state = "castable" })
check("provenance: old double and Windstep remain unmeasured", legacy.jump_measured and not legacy_caps.double_jump.measured and not legacy_caps.windstep.measured and not legacy_caps.windstep.planned)
local verified = envelope_fixture('{"dj_up_m":2.6,"windstep_up_m":5,"measurement_provenance":{"dj_up_m":{"verified":true},"windstep_up_m":{"verified":true}}}')
local available = MD2.traverse_caps(verified, { state = "castable" })
check("provenance: separately verified capabilities can be planned", available.double_jump.measured and available.double_jump.planned and available.windstep.measured and available.windstep.planned)
for _, gate in ipairs({ "cooldown", "runes", "unlock" }) do
    local caps = MD2.traverse_caps(verified, { state = gate })
    check("provenance: Windstep " .. gate .. " remains measured but unavailable", caps.windstep.measured and not caps.windstep.planned and caps.windstep.state == gate)
end
HAS_DJ = false
local locked = MD2._envelope(pawn, pc)
local locked_caps = MD2.traverse_caps(locked, { state = "castable" })
check("provenance: missing perk preserves measurement but prevents planning", locked_caps.double_jump.measured and not locked_caps.double_jump.have and not locked_caps.double_jump.planned and locked.djump == locked.jump)
os.remove(envf); HAS_DJ = false; raised = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 23. TRUTHFUL REASON (live 07:05): on a 3 m plateau, a tall wall across its whole width (it runs
--     past the plateau's edges); the goal is level with us beyond the wall. The escape must not walk
--     him off the plateau (Bug2 did), and the reason must be "no_route" (walls), not "above jump height"
walls = {}; oracle = nil; lakes = {}; portals = {}
raised = { { 500, 600, -1500, 1500, 1200, 1200 },      -- the wall (12 m high), wider than the plateau
           { -1000, 1500, -1000, 1000, 300, 300 } }    -- the plateau, 3 m up
luis.loc = { X = 90000, Y = 90000, Z = 0 }
pawn.loc = { X = 0, Y = 0, Z = 300 }
local nlog23 = #logs
local MR = dofile(MOVE)
MR.go_to(log, { 12, 0, 3.0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
run(1500)
s = MR.status()
check("reason: stays on the plateau (no wall-following off the ledge)", pawn.loc.Z >= 290, pawn.loc.Z)
check("reason: truthful 'no_route' for a level goal behind walls", s.result and s.result.status == "failed" and s.result.why == "no_route",
    tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.why) .. " " .. tostring(s.result and s.result.detail))
MR.stop(log)
walls = {}; raised = {}

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 24. Windows refuses the request file's rename (AV/indexer handle; made test 1 flaky under load):
--     the oracle request must still be sent (direct write) and its waypoints used
walls = { { 900, 1100, -500, 500 } }; raised = {}; lakes = {}; portals = {}
oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
pump_oracle()
local real_rename = os.rename
os.rename = function(a, b) if tostring(b):find("req%.json$") then return nil, "Permission denied" end return real_rename(a, b) end
pawn.loc = { X = 0, Y = 0, Z = 0 }
local nlog24 = #logs
local MQ = dofile(MOVE)
MQ.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
run(150)
os.rename = real_rename
s = MQ.status()
local saw_nav24 = false
for i = nlog24 + 1, #logs do if logs[i]:find("src=nav") then saw_nav24 = true end end
check("refused rename: oracle request still sent, waypoints used, arrives", s.result and s.result.status == "arrived" and saw_nav24 and (s.nav_requests or 0) >= 1,
    tostring(s.result and s.result.status) .. " nav=" .. tostring(saw_nav24) .. " status=" .. tostring(s.status) .. " requests=" .. tostring(s.nav_requests))
MQ.stop(log)
walls = {}; oracle = nil

-- 25-36. AVOID ZONES (docs/design/velgar.md 3c): set_avoid_zones / escape_zones / status().avoid
local AZt = dofile(here .. "/../scripts/avoidzones.lua")
local function zreset()
    _G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; _G.DW_AVOID = nil
    os.remove(dir .. "/data/skills/test-world/nav_memory.json")
    walls = {}; raised = {}; lakes = {}; portals = {}; oracle = nil; frame_hook = nil
    luis.loc = { X = 90000, Y = 90000, Z = 0 }; pawn.loc = { X = 0, Y = 0, Z = 0 }; sprinting = false
end
-- frames Claude's capsule spends inside a zone (the module's own geometry, 40 cm capsule)
local function watch_zone(zl)
    local w = { inside = 0, frames = 0 }
    local zz = assert(AZt.normalize(zl, T))
    frame_hook = function() w.frames = w.frames + 1; if AZt.at(zz, pawn.loc.X, pawn.loc.Y, nil, 40) then w.inside = w.inside + 1 end end
    return w
end

zreset()
-- 25. API: validation (scalars only, metres, until_s), versions change only with the geometry, [] clears
local MZ = dofile(MOVE)
local rz = MZ.set_avoid_zones(log, { { id = "a", x = 1, y = 0, z = 0, r_cm = 200, until_s = T + 30, pos = { 1, 2 } } })
check("zones: a table field is refused (scalars only)", rz.ok == false and tostring(rz.error):find("scalars"), rz.error)
rz = MZ.set_avoid_zones(log, { { id = "a", x = 150000, y = 0, r_cm = 200, until_s = T + 30 } })
check("zones: centimetre coordinates are refused", rz.ok == false and tostring(rz.error):find("centimetres"), rz.error)
local r1 = MZ.set_avoid_zones(log, { { id = "a", x = 30, y = 0, z = 0, r_cm = 200, until_s = T + 30 } })
local r2 = MZ.set_avoid_zones(log, { { id = "a", x = 30, y = 0, z = 0, r_cm = 200, until_s = T + 31 } })
local r3 = MZ.set_avoid_zones(log, { { id = "a", x = 31, y = 0, z = 0, r_cm = 200, until_s = T + 31 } })
check("zones: same geometry re-sent = same version; moved = new version", r1.ok and r2.ver == r1.ver and r3.ver == r1.ver + 1,
    tostring(r1.ver) .. " " .. tostring(r2.ver) .. " " .. tostring(r3.ver))
check("zones: status().avoid counts them (idle)", MZ.status().avoid.zones == 1 and MZ.status().avoid.inside == nil)
MZ.set_avoid_zones(log, { { id = "here", x = 0, y = 0, z = 0, r_cm = 200, until_s = T + 30 } })
check("zones: status().avoid.inside while idle", MZ.status().avoid.inside == "here", MZ.status().avoid.inside)
check("zones: [] clears", MZ.set_avoid_zones(log, {}).zones == 0 and MZ.status().avoid.zones == 0)

zreset()
-- 26. go_to plans round a circle zone straight ahead (open field) and never steps into it
MZ = dofile(MOVE)
local Z26 = { { id = "fire", x = 7.5, y = 0, z = 0, r_cm = 250, until_s = T + 120 } }
MZ.set_avoid_zones(log, Z26)
local w26 = watch_zone(Z26)
local nlog26 = #logs
MZ.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, timeout_s = 60, nav=false })
local saw_cross26 = false
for _ = 1, 400 do run(1); if MZ.status().avoid.crossing then saw_cross26 = true end; if MZ.status().mode == "idle" then break end end
s = MZ.status()
local planned26 = false
for i = nlog26 + 1, #logs do if logs[i]:find("avoid_zone fire") then planned26 = true end end
check("avoid: go_to arrives round the zone", s.result and s.result.status == "arrived", s.result and (s.result.status .. " " .. tostring(s.result.reason)))
check("avoid: planned because of the zone, never inside it", planned26 and w26.inside == 0, "planned=" .. tostring(planned26) .. " inside_frames=" .. w26.inside)
MZ.stop(log)

zreset()
-- 27. a cost, not a wall: a corridor (tall walls) fully covered by a zone; no other way -> it crosses
--     and says so (status().avoid.crossing, log)
walls = { { -500, 2500, 150, 3000, true }, { -500, 2500, -3000, -150, true } }
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "breath", x = 10, y = 0, z = 0, r_cm = 400, until_s = T + 120 } })
local nlog27 = #logs
MZ.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 90, nav=false })
local cross27, inside27 = nil, false
for _ = 1, 800 do
    run(1)
    local a = MZ.status().avoid
    cross27 = cross27 or a.crossing
    if a.inside then inside27 = true end
    if MZ.status().mode == "idle" then break end
end
s = MZ.status()
check("avoid: no other way -> crosses the zone and arrives", s.result and s.result.status == "arrived" and inside27,
    tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason) .. " x=" .. math.floor(pawn.loc.X))
check("avoid: the crossing is reported (status().avoid.crossing)", cross27 == "breath", cross27)
MZ.stop(log)

zreset()
-- 28. follow: the leader stands in a zone -> Claude holds at its edge ("near_zone"), never enters
luis.loc = { X = 1500, Y = 0, Z = 0 }
MZ = dofile(MOVE)
local Z28 = { { id = "pool", x = 15, y = 0, z = 0, r_cm = 400, until_s = T + 120 } }
MZ.set_avoid_zones(log, Z28)
local w28 = watch_zone(Z28)
MZ.follow(log, "Zezima", 3, {nav=false})
run(200)
s = MZ.status()
check("avoid: follow holds at the edge of the leader's zone", s.status == "near_zone" and w28.inside == 0 and pawn.loc.X > 600,
    tostring(s.status) .. " x=" .. math.floor(pawn.loc.X) .. " inside_frames=" .. w28.inside)
-- the zone ends: he closes in to the normal follow distance
_G.DW_AVOID.zones[1].until_s = T + 0.5
run(120)
s = MZ.status()
check("avoid: zone expired -> follows in to 3 m", s.status == "near" and s.dist_m <= 4.1 and s.avoid.zones == 0, tostring(s.status) .. " " .. tostring(s.dist_m))
MZ.stop(log)

zreset()
-- 29. follow: Claude and the leader both stand in a zone -> Claude steps OUT (nearest way), then holds at the edge
luis.loc = { X = 150, Y = 0, Z = 0 }; pawn.loc = { X = -100, Y = 0, Z = 0 } -- both in the zone: walking to him stays inside
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "puddle", x = 0, y = 0, z = 0, r_cm = 200, until_s = T + 120 } })
MZ.follow(log, "Zezima", 3, {nav=false})
run(100)
s = MZ.status()
local dz29 = math.sqrt(pawn.loc.X ^ 2 + pawn.loc.Y ^ 2) -- zone centre (0,0), r 2 m + 40 cm capsule
check("avoid: follow steps out of a zone it stands in", dz29 > 240 and s.avoid.inside == nil and (s.status == "near" or s.status == "near_zone"),
    "d=" .. math.floor(dz29) .. " " .. tostring(s.status) .. " inside=" .. tostring(s.avoid.inside))
MZ.stop(log)

zreset()
-- 30. escape_zones: inside a circle (centre 0.5 m ahead): ok, nearest way out (backwards), sprint, out in time
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "meteor", x = 0.5, y = 0, z = 0, r_cm = 300, until_s = T + 10 } })
local t30, inj30 = T, injected
local e30 = MZ.escape_zones(log, { time_s = 1.5 })
local out_t = nil
for _ = 1, 100 do run(1); if not out_t and not MZ.status().avoid.inside then out_t = T - t30 end; if MZ.status().mode == "idle" then break end end
s = MZ.status()
check("escape: ok, away from the centre, with an eta", e30.ok and e30.at[1] < -2.5 and e30.eta_s > 0 and e30.eta_s <= 1.5 and e30.why == nil,
    tostring(e30.ok) .. " " .. tostring(e30.why) .. " at=" .. tostring(e30.at and e30.at[1]) .. " eta=" .. tostring(e30.eta_s))
check("escape: walked out of every zone within the eta (+0.3 s)", out_t and out_t <= e30.eta_s + 0.3 and s.result and s.result.status == "arrived" and s.result.out_of_zones,
    "out_t=" .. tostring(out_t) .. " " .. tostring(s.result and s.result.status))
check("escape: sprinted (time is short)", e30.sprint == true and injected > inj30)

zreset()
-- 31. too_slow: not enough time -> answer, but don't move (combat dodges instead)
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "big", x = 0, y = 0, z = 0, r_cm = 1000, until_s = T + 10 } })
local e31 = MZ.escape_zones(log, { time_s = 0.4 })
run(10)
check("escape: too_slow, with at/eta, and no walking", e31.ok == false and e31.why == "too_slow" and e31.at and e31.eta_s > 0.4
    and MZ.status().mode == "idle" and math.abs(pawn.loc.X) < 1 and math.abs(pawn.loc.Y) < 1, tostring(e31.why) .. " eta=" .. tostring(e31.eta_s))

zreset()
-- 32. no_safe_point: the whole bound (the arena) is covered
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "floor", x = 0, y = 0, z = 0, r_cm = 3000, until_s = T + 10 } })
local e32 = MZ.escape_zones(log, { time_s = 3, bound = { x = 0, y = 0, z = 0, r_cm = 2000 } })
check("escape: no_safe_point when the bound is all zone", e32.ok == false and e32.why == "no_safe_point", tostring(e32.why))

zreset()
-- 33. no_route: boxed in by tall walls, the zone covers the box -> every way out is a wall
walls = { { 150, 250, -400, 400, true }, { -250, -150, -400, 400, true }, { -400, 400, 150, 250, true }, { -400, 400, -250, -150, true } }
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "box", x = 0, y = 0, z = 0, r_cm = 300, until_s = T + 10 } })
local e33 = MZ.escape_zones(log, { time_s = 5 })
check("escape: no_route when every way out is blocked", e33.ok == false and e33.why == "no_route" and (e33.tested or 0) >= 1 and tostring(e33.detail):find("wall"),
    tostring(e33.why) .. " " .. tostring(e33.detail))

zreset()
-- 34. not in any zone: ok at once, nothing to do
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "far", x = 20, y = 0, z = 0, r_cm = 300, until_s = T + 10 } })
local e34 = MZ.escape_zones(log, { time_s = 1 })
check("escape: already safe", e34.ok and e34.already_safe and e34.eta_s == 0 and MZ.status().mode == "idle")

zreset()
-- 35. cone (dragon breath from 3 m behind, facing +X): the way out is sideways, not along the axis
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "breath", kind = "cone", x = -3, y = 0, z = 0, r_cm = 1500, until_s = T + 10, yaw_deg = 0, half_angle_deg = 30 } })
local e35 = MZ.escape_zones(log, { time_s = 2 })
run(60)
check("escape: cone -> sideways exit, walked out", e35.ok and math.abs(e35.at[2]) > 1.7 and math.abs(e35.at[1]) < 2 and MZ.status().avoid.inside == nil,
    tostring(e35.why) .. " at=" .. tostring(e35.at and (e35.at[1] .. "," .. e35.at[2])))

zreset()
-- 36. expiry: a zone that has ended is ignored (no avoid plan, straight line)
MZ = dofile(MOVE)
MZ.set_avoid_zones(log, { { id = "old", x = 7.5, y = 0, z = 0, r_cm = 250, until_s = T + 0.2 } })
run(5)
local nlog36 = #logs
MZ.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, nav=false })
run(150)
local planned36 = false
for i = nlog36 + 1, #logs do if logs[i]:find("avoid_zone") then planned36 = true end end
s = MZ.status()
check("avoid: expired zones are dropped (straight there)", s.result and s.result.status == "arrived" and not planned36 and s.avoid.zones == 0,
    tostring(s.result and s.result.status) .. " planned=" .. tostring(planned36))
MZ.stop(log)
zreset()

-- 37-44. APPROACH PROGRESS (status().progress) and M.why_words: one watchdog for combat/skills/shoot
-- 37. a go_to that can't get closer (goal behind a long tall wall): "stalled" with a wall reason ~stall_s after
--     reaching the wall (~1 s walk + planning), while move itself is still trying (pure information, no stop)
walls = { { 400, 500, -3000, 3000, true } }
MZ = dofile(MOVE)
MZ.go_to(log, { 10, 0, 0 }, { tolerance_m = 1, timeout_s = 60, nav=false, progress = { stall_s = 3 } })
local p37, t37 = nil, T
for _ = 1, 200 do run(1); local p = MZ.status().progress; if p and p.verdict ~= "ok" then p37 = p; break end end
check("progress: blocked go_to -> stalled (walls) within ~stall_s, move still running",
    p37 and p37.verdict == "stalled" and (p37.why == "blocked" or p37.why == "no_progress") and T - t37 < 9 and MZ.status().mode == "go_to",
    p37 and (p37.verdict .. " " .. tostring(p37.why) .. " t=" .. (T - t37)) or "never")
MZ.stop(log)
check("progress: kept after stop (last verdict readable)", MZ.status().progress ~= nil)

zreset()
-- 38. a target running away faster than Claude can sprint: "stalled" / cant_catch
luis.loc = { X = 800, Y = 0, Z = 0 }
frame_hook = function() luis.loc.X = luis.loc.X + 800 * DT end
MZ = dofile(MOVE)
MZ.follow(log, { actor = luis }, 2, { nav=false, progress = { stall_s = 3 } })
local p38
for _ = 1, 100 do run(1); local p = MZ.status().progress; if p.verdict ~= "ok" then p38 = p; break end end
check("progress: fleeing target -> cant_catch", p38 and p38.verdict == "stalled" and p38.why == "cant_catch" and p38.target_moved_m > 3,
    p38 and (p38.verdict .. " " .. tostring(p38.why)) or "never")
MZ.stop(log); frame_hook = nil

zreset()
-- 39. follow that arrives and idles: stays "ok" however long he waits near the leader
luis.loc = { X = 1000, Y = 0, Z = 0 }
MZ = dofile(MOVE)
MZ.follow(log, "Zezima", 3, { nav=false, progress = { stall_s = 2 } })
run(250)
s = MZ.status()
check("progress: idle near the leader stays ok", s.status == "near" and s.progress.verdict == "ok" and s.progress.since_s < 1, s.status .. " " .. s.progress.verdict .. " since=" .. tostring(s.progress.since_s))
-- he walks away 12 m: approach time counts again, still ok while gaining
luis.loc = { X = 2200, Y = 0, Z = 0 }
run(10)
check("progress: chasing again, gaining = ok", MZ.status().progress.verdict == "ok" and MZ.status().progress.elapsed_s > 0)
MZ.stop(log)

zreset()
-- 40. budget: a long trip with budget_s = 2 -> too_long after 2 s even while gaining
MZ = dofile(MOVE)
MZ.go_to(log, { 60, 0, 0 }, { tolerance_m = 1, nav=false, progress = { budget_s = 2 } })
run(10)
local p40a = MZ.status().progress
run(20)
local p40 = MZ.status().progress
check("progress: budget exceeded -> too_long", p40a.verdict == "ok" and p40.verdict == "stalled" and p40.why == "too_long" and p40.elapsed_s > 2,
    p40a.verdict .. " -> " .. p40.verdict .. " " .. tostring(p40.why))
-- 41. progress_reset restarts the window (and can change the parameters)
MZ.progress_reset(log, { budget_s = 30 })
run(2)
check("progress: progress_reset -> ok again", MZ.status().progress.verdict == "ok" and MZ.status().progress.elapsed_s < 1, MZ.status().progress.verdict)
MZ.stop(log)

zreset()
-- 42. measure to a THING, not to the standing spot (skills interact)
MZ = dofile(MOVE)
MZ.go_to(log, { 5, 0, 0 }, { tolerance_m = 0.5, progress = { to = { 5, 3, 0 } } })
run(60)
s = MZ.status()
check("progress: distance measured to opts.progress.to", s.result and s.result.status == "arrived" and math.abs(s.progress.dist_m - 3) < 0.6 and s.progress.verdict == "ok",
    tostring(s.result and s.result.status) .. " d=" .. tostring(s.progress.dist_m))

zreset()
-- 43. move's own verdicts pass through: a failed go_to is "unreachable" with its why; the snapshot keeps opts.progress
walls = { { -300, 300, 150, 250, true }, { -300, 300, -250, -150, true }, { 150, 250, -300, 300, true }, { -250, -150, -300, 300, true } }
MZ = dofile(MOVE)
MZ.go_to(log, { 10, 0, 0 }, { tolerance_m = 1, timeout_s = 120, progress = { stall_s = 4, to = { 10, 1, 0 } } })
local snap43 = MZ.snapshot()
run(1200)
s = MZ.status()
check("progress: failed go_to -> unreachable with move's reason", s.result and s.result.status == "failed" and s.progress.verdict == "unreachable" and s.progress.why ~= nil,
    tostring(s.result and s.result.status) .. " " .. tostring(s.progress.verdict) .. " " .. tostring(s.progress.why))
check("progress: snapshot keeps opts.progress", snap43 and snap43.opts.progress and snap43.opts.progress.stall_s == 4 and snap43.opts.progress.to[2] == 1)
MZ.stop(log)

-- 44. why_words: one table, truthful clauses, grammar for "you"/"it"/a name, needs:X, unknown
local W = MZ.why_words
check("words: every key has a clause", (function() for _, k in ipairs(MZ.WHY_KEYS) do local w = W(k, "the Kebbit"); if type(w) ~= "string" or #w < 8 then return false end end return #MZ.WHY_KEYS >= 15 end)())
check("words: you're higher up", W("leader_above_jump_height", "you") == "you're higher up than I can jump", W("leader_above_jump_height", "you"))
check("words: the Kebbit is higher up", W("target_above_jump_height", "the Kebbit") == "the Kebbit is higher up than I can jump")
check("words: default thing is it", W("cant_catch") == "it keeps moving away faster than I can catch up", W("cant_catch"))
check("words: windstep (you)", W("leader_windstepped", "you"):find("^you Windstepped") ~= nil)
check("words: needs:DoubleJump", W("needs:DoubleJump") == "I'd need Double Jump to get there, and I can't do that yet", W("needs:DoubleJump"))
check("words: unknown reason -> generic, never the raw code", W("zz_weird") == "I can't find a way there")
check("words: plural", W("target_above_jump_height", "the sticks", true) == "the sticks are higher up than I can jump" and W("cant_catch", "they") == "they keep moving away faster than I can catch up",
    W("target_above_jump_height", "the sticks", true))
zreset()

-- 45. a goal on a ledge 4 m up (no way up): the caller's timeout ends the go_to; the progress verdict names
--     the height, not a bare "timeout" (live 2026-10-26 16:05: branches on a rock)
raised = { { 500, 1500, -1500, 1500, 400, 400 } }
MZ = dofile(MOVE)
MZ.go_to(log, { 8, 0, 4.9 }, { tolerance_m = 0.35, timeout_s = 10, nav=false, progress = { stall_s = 3 } })
run(150)
s = MZ.status()
check("progress: ledge goal -> timeout reported as target_above_jump_height", s.result and s.result.status == "failed" and s.result.reason == "timeout"
    and s.progress.verdict == "unreachable" and s.progress.why == "target_above_jump_height",
    tostring(s.result and s.result.reason) .. " " .. tostring(s.progress and s.progress.why))
MZ.stop(log)

zreset()
-- 46. a goal IN known water (a pond to use): no swap for dry ground, it walks in and arrives
lakes = { { 500, 1500, -500, 500 } }
MZ = dofile(MOVE)
MZ.go_to(log, { 9, 0, 0 }, { tolerance_m = 1.0, timeout_s = 60 }) -- the first wade learns the cells
run(300)
local first46 = MZ.status().result
MZ.go_to(log, { 2, 0, 0 }, { tolerance_m = 1.0 }); run(100)
local nlog46 = #logs
MZ.go_to(log, { 7, 0, 0 }, { tolerance_m = 1.0, timeout_s = 60 })
run(300)
s = MZ.status()
local said46 = false
for i = nlog46 + 1, #logs do if logs[i]:find("the goal is in it", 1, true) then said46 = true end end
check("water goal: arrives in the pond (known water), no dry detour", first46 and first46.status == "arrived" and s.result and s.result.status == "arrived" and said46,
    tostring(first46 and first46.status) .. " " .. tostring(s.result and s.result.status) .. " said=" .. tostring(said46))
MZ.stop(log)

-- 47. shore_point: the WATERLINE on Claude's side of the pond, from real traces (live 18:3x: the game's
--     interact target reads the water only from there, not from the dry bank)
pawn.loc = { X = 0, Y = 0, Z = 0 }
_G.DW_WATER_CH = { name = "vis", ch = 0 }
_G.DW_TRACE_PROFILE = { name = "Player" } -- the pawn profile passes through water (live); Visibility sees the surface
_G.DW_NAVMEM = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
MZ = dofile(MOVE)
local sp = MZ.shore_point(log, { 10, 0, -3 })
check("shore: stands at the waterline (shallows), faces the water further out",
    sp.ok and sp.stand[1] >= 5.0 and sp.stand[1] < 5.6 and math.abs(sp.stand[2]) < 0.5 and sp.depth_cm == 50
    and sp.edge[1] > 6.3 and sp.edge[1] < 7.2 and math.abs(sp.edge[3] - (-0.4)) < 0.05 and sp.bank[1] < 5.0,
    sp.ok and (table.concat(sp.stand, ",") .. " face " .. table.concat(sp.edge, ",") .. " depth " .. tostring(sp.depth_cm)) or tostring(sp.why))
check("shore: alternatives along the bank", sp.ok and #sp.alts >= 2 and sp.how == "channel", sp.ok and #sp.alts)
-- a volume pivot on dry land beside the water: found by walking from Claude toward it
local sp2 = MZ.shore_point(log, { 16, 0, 0 })
check("shore: pivot off the water -> still the near waterline", sp2.ok and sp2.stand[1] < 5.6, sp2.ok and sp2.stand[1] or sp2.why)
-- the calibrated channel is wrong (sees nothing here): the other surface channels still find it
_G.DW_WATER_CH = { name = "cam", ch = 1 }
local sp2b = MZ.shore_point(log, { 10, 0, -3 })
check("shore: a mis-calibrated channel doesn't hide the water", sp2b.ok and sp2b.stand[1] >= 5.0 and sp2b.stand[1] < 5.6, sp2b.ok and sp2b.stand[1] or sp2b.why)
-- no water anywhere -> no_shore (truthful)
local lakes_saved = lakes
lakes = {}
local sp3 = MZ.shore_point(log, { 10, 0, -3 })
check("shore: no water there -> no_shore", sp3.ok == false and sp3.why == "no_shore", sp3.why)
lakes = lakes_saved
check("words: no_shore", W("no_shore") == "I can't find the water's edge from here")

-- 48. walking INTO the shallows: go_to opts.wade = true -> no water re-plan, arrives at the waterline spot
pawn.loc = { X = 0, Y = 0, Z = 0 }
local nlog48 = #logs
MZ.go_to(log, { sp.stand[1] + 1, sp.stand[2], 0 }, { tolerance_m = 0.4, wade = true, timeout_s = 30 })
run(150)
s = MZ.status()
local replanned48 = false
for i = nlog48 + 1, #logs do if logs[i]:find("local plan #%d+ %(water") then replanned48 = true end end
check("wade: arrives in the shallows with no water detour", s.result and s.result.status == "arrived" and not replanned48 and in_lake(pawn.loc.X, pawn.loc.Y),
    tostring(s.result and s.result.status) .. " replanned=" .. tostring(replanned48) .. " x=" .. math.floor(pawn.loc.X))
MZ.stop(log)

-- 49. a spot where collecting WORKED is learned and offered first (persisted)
local rw = MZ.remember_water_spot(log, { 10, 0, -3 }, { 5.3, 0.2, 0 })
_G.DW_NAVMEM = nil -- reload from disk
local sp4 = MZ.shore_point(log, { 10.5, 0, -3 })
check("shore: the learned working spot wins", rw.ok and sp4.ok and sp4.how == "learned" and math.abs(sp4.stand[1] - 5.3) < 0.02 and sp4.edge[1] > 5.3,
    sp4.ok and (sp4.how .. " " .. table.concat(sp4.stand, ",")) or tostring(sp4.why))
MZ.remember_water_spot(log, { 10, 0, -3 }, { 5.4, 0.1, 0 })
check("shore: a repeat success near it counts for the same spot", #(_G.DW_NAVMEM.water_spots or {}) == 1 and _G.DW_NAVMEM.water_spots[1].n_ok == 2)
lakes = {}
zreset()

_G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
-- 7. arbiter hooks: actor target ({actor=obj}), snapshot/restore, face_when_near
walls = {}; pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 1500, Y = 0, Z = 0 }; oracle = nil
M.follow(log, { actor = luis }, 2, { sprint = true, face_when_near = true, nav=false })
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

-- Ownership is captured at movement start, never inferred later from an unrelated owner.
do
    local src = assert(io.open(here .. "/../scripts/arbiter.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/client_mod/scripts/arbiter.lua", "wb")); f:write(src); f:close()
    local ms = assert(io.open(here .. "/../scripts/move.lua", "rb")):read("a")
    local mf = assert(io.open(dir .. "/client_mod/scripts/move.lua", "wb")); mf:write(ms); mf:close()
    _G.DWArbiter = nil
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
    A.set_move(M)
    M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
    local direct = A.owner()
    check("owner: direct move adopted", direct and direct.implicit and _G.DW_MOVE.owner_token == direct.token)
    M.go_to(log, { 21, 0, 0 }, { tolerance_m = 1 })
    local replacement = A.owner()
    check("owner: replacement receives a new token", replacement and direct and replacement.token ~= direct.token)
    local high = A.request(log, { name = "fight", level = "reflex", uses_move = true })
    check("owner: direct move suspended", high.ok and A.is_suspended(replacement.token))
    A.release(log, high.token, "done")
    check("owner: resumed move keeps its token", A.owns_move(replacement.token) and _G.DW_MOVE.owner_token == replacement.token)
    M.stop(log)
    local skill = A.request(log, { name = "skill", level = "command", uses_move = true })
    M.go_to(log, { 22, 0, 0 }, { owner_token = skill.token })
    check("owner: skill token associated", _G.DW_MOVE.owner_token == skill.token and A.owns_move(skill.token))
    local interrupt = A.request(log, { name = "reflex", level = "reflex", uses_move = true })
    A.release(log, interrupt.token, "done")
    check("owner: skill move resumes with its token", A.owns_move(skill.token) and _G.DW_MOVE.owner_token == skill.token)
    M.stop(log); A.release(log, skill.token, "done")
    local other = A.request(log, { name = "non-mover", level = "command", uses_move = false })
    local prior_gen, prior_handle = _G.DW_MOVE.gen, _G.DW_MOVE.handle
    local refused=M.go_to(log, { 22, 0, 0 }, { owner_token = other.token })
    check("owner: non-mover cannot be borrowed", not refused.ok and _G.DW_MOVE.gen==prior_gen and _G.DW_MOVE.handle==prior_handle and not A.owns_move(other.token))
    refused=M.go_to(log, { 23, 0, 0 }, {})
    check("owner: unassociated move does not borrow existing owner", not refused.ok and _G.DW_MOVE.gen==prior_gen and _G.DW_MOVE.handle==prior_handle)
    M.stop(log); A.release(log, other.token, "done")
end

-- Borrowed Windstep jobs are owned by the movement action and require a verified landing.
do
    local f = assert(io.open(dir .. "/client_mod/scripts/traversal_moves.lua", "wb"))
    f:write(assert(io.open(here .. "/../scripts/traversal_moves.lua", "rb")):read("a")); f:close()
    M = dofile(MOVE)
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
    A.set_move(M)
    local available, polls, cancelled, calls, result, cancelled_owned = true, 0, 0, 0, nil, false
    M.set_spells({ ability_status = function() return { available = available, why = "on_cooldown" } end,
        cast_now = function(_, _, opts)
            calls = calls + 1
            check("windstep: cast borrows movement owner", opts.owner_token == _G.DW_MOVE.owner_token and A.owns_move(opts.owner_token))
            return { poll = function() polls = polls + 1; return result end, cancel = function() cancelled_owned = A.owns_move(opts.owner_token); cancelled = cancelled + 1 end }
        end })
    local function begin()
        pawn.loc = { X = 0, Y = 0, Z = 0 }; air = 0; walls = {}; raised = {}; oracle = nil
        M.go_to(log, { 20, 0, 0 }, { local_plan = false, nav=false })
        local st = _G.DW_MOVE
        st.env = { step = 45, ws_up_cm = 500 }
        st.lpath = { { X = 0, Y = 0, Z = -90, act = "walk" }, { X = 100, Y = 0, Z = -90, act = "superjump" } }
        st.lwp, st.lp_jumped = 2, {}
        return st
    end
    local st = begin(); run(1)
    check("windstep: pending cast holds without jumping", polls > 0 and st.ws_exec and st.ws_exec.phase == "casting" and not st.jump_t)
    local token = st.owner_token
    M.go_to(log, { 21, 0, 0 }, {nav=false})
    check("windstep: replacement cancels before owner rotates", cancelled == 1 and cancelled_owned and _G.DW_MOVE.owner_token ~= token)
    M.stop(log)
    available, result = false, nil
    st = begin(); _G.DW_MOVE_WS = { t = T, r = { state = "castable" } }; local before = calls; run(1)
    check("windstep: takeoff bypasses stale gate", calls == before and M.status().result.reason == "on_cooldown")
    available, result = true, { ok = false, reason = "not_enough_resources", data = { detail = "no runes" } }
    st = begin(); run(1)
    check("windstep: cast failure is authoritative", M.status().result.reason == "not_enough_resources" and not st.jump_t)
    result = { ok = true }
    do
        local old_jump = pawn.Jump
        local attempted = 0
        pawn.Jump = function() attempted = attempted + 1; error("windstep jump rejected") end
        st = begin(); run(1)
        check("windstep: rejected jump never enters air or consumes jump",attempted==1 and st.result and st.result.reason=="verification_failed" and not st.jump_t and not (st.ws_exec and st.ws_exec.phase=="air"))
        pawn.Jump = old_jump
    end
    do
        local old_jump=pawn.Jump; local attempted=0
        pawn.Jump=function()
            attempted=attempted+1; pawn.Jump=old_jump
            M.go_to(log,{30,0,0},{nav=false,local_plan=false})
        end
        st=begin(); local previous=st.gen; run(1)
        check("windstep: preempted jump cannot advance successor",attempted==1 and st.gen>previous and st.mode=="go_to" and not st.ws_exec and not st.jump_t)
        pawn.Jump=old_jump; M.stop(log)
    end
    st = begin(); run(1)
    check("windstep: successful cast starts jump", st.ws_exec and st.ws_exec.phase == "air" and st.jump_t)
    pawn.loc = { X = 100, Y = 0, Z = 0 }; air = 1; run(1)
    check("windstep: endpoint proximity in air cannot advance", st.lwp == 2)
    air = 0; st.ws_exec.jump_t = T - 1; pawn.loc = { X = 100, Y = 0, Z = 0 }; run(1)
    check("windstep: grounded endpoint advances", st.lwp > 2)
    M.stop(log)
    st = begin(); run(1); local oldpath = st.lpath
    st.lpath = { oldpath[1], oldpath[2] }; run(1)
    check("windstep: path replacement after cast fails before landing", M.status().result.reason == "windstep_interrupted")
    st = begin(); run(1); st.lpath = nil; run(1)
    check("windstep: path removal after cast fails before landing", M.status().result.reason == "windstep_interrupted")
    st = begin(); run(1); st.ws_exec.jump_t = T - 1; pawn.loc = { X = 0, Y = 0, Z = 0 }; air = 0; run(1)
    check("windstep: missed landing fails truthfully", M.status().result.reason == "windstep_landing_missed")
    st = begin(); run(1); st.ws_exec.jump_t = T - 9
    local ground_fn = pawn.CharacterMovement.IsMovingOnGround
    pawn.CharacterMovement.IsMovingOnGround = function() error("missing ground") end
    run(1); pawn.CharacterMovement.IsMovingOnGround = ground_fn
    check("windstep: missing ground read times out", M.status().result.reason == "windstep_landing_timeout")
    result = nil; st = begin(); run(1); local c = cancelled
    st.ws_exec.token = -1; local before_polls = polls; run(1)
    check("windstep: owner loss cancels without another poll", M.status().result.reason == "windstep_owner_lost" and polls == before_polls and cancelled == c + 1)
    st = begin(); run(1); c = cancelled
    local high = A.request(log, { name = "windstep-interrupt", level = "reflex", uses_move = true })
    check("windstep: suspension cancels pending cast", high.ok and cancelled == c + 1)
    A.release(log, high.token, "done"); M.stop(log)
    st = begin(); run(1); c = cancelled
    pawn.HealthComponent.IsDead = function() return true end; run(1)
    check("windstep: death cancels pending cast and releases owner", M.status().result.reason == "companion_down" and cancelled == c + 1 and A.owner() == nil)
    pawn.HealthComponent.IsDead = function() return false end
    M.stop(log)
    st = begin(); st.lpath = nil
    st.mpath = { { X = 0, Y = 0, Z = -90, act = "walk" }, { X = 10, Y = 0, Z = -90, act = "superjump" }, { X = 1000, Y = 0, Z = -90, act = "walk" } }
    st.mwp = 2; run(1)
    check("windstep: local edge barrier does not stall memory waypoint advance", st.mwp > 2)
    M.stop(log); M.set_spells(nil)
end

do
    local hc, mc = pawn.HealthComponent, pawn.CharacterMovement
    walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local started = M.go_to(log, { 0, 0, 0 }, { tolerance_m = 0.5 }); run(1)
    check("integrity: normal grounded arrival", started.ok and M.status().result.status == "arrived" and M.verify_arrival().ok)
    M.go_to(log, { 0, 0, -30 }, { timeout_s = 0.05, local_plan = false }); run(1)
    check("integrity: same XY lower floor not arrived", M.status().result and M.status().result.status == "failed")
    M.go_to(log, { 0, 0, 30 }, { timeout_s = 0.05, local_plan = false }); run(1)
    check("integrity: same XY higher floor not arrived", M.status().result and M.status().result.status == "failed")
    M.go_to(log, { 0, 0, 0 }, { tolerance_m = 0.5 }); air = 1; run(1)
    check("integrity: airborne cannot arrive", M.status().mode == "go_to" and M.status().status == "awaiting_landing")
    air = 0; run(1); check("integrity: arrival after landing", M.status().result.status == "arrived")
    hc.IsDead = function() return true end
    local dead = M.go_to(log, { 5, 0, 0 }, {}); check("integrity: dead at start", not dead.ok and dead.reason == "companion_down")
    hc.IsDead = function() return false end
    M.go_to(log, { 5, 0, 0 }, {}); hc.IsDead = function() return true end; run(1)
    check("integrity: death interrupts", M.status().result.reason == "companion_down" and not _G.DW_MOVE.trip_ok)
    hc.IsDead = function() return false end
    M.go_to(log, { 5, 0, 0 }, {}); _G.DW_LIFE = { move_death_seq = 1 }; run(1)
    check("integrity: observed death and revival same pawn interrupts", M.status().result.reason == "companion_down")
    _G.DW_LIFE = nil
    M.go_to(log, { 5, 0, 0 }, {}); pc.Pawn = obj({ CharacterMovement = mc }); run(1); pc.Pawn = pawn
    check("integrity: pawn replacement interrupts", M.status().result.reason == "interrupted")
    hc.IsDead = function() error("unavailable") end
    local unknown = M.go_to(log, { 5, 0, 0 }, {}); check("integrity: unknown health is not death", not unknown.ok and unknown.reason == "verification_failed")
    hc.IsDead = function() return false end
    local missing = M.go_to(log, { 5, 0 }, {}); check("integrity: missing Z rejected", not missing.ok and missing.reason == "invalid_args")
    local capsule = pawn.CapsuleComponent.GetScaledCapsuleHalfHeight
    pawn.CapsuleComponent.GetScaledCapsuleHalfHeight = function() error("unavailable") end
    local no_capsule = M.go_to(log, { 5, 0, 0 }, {})
    check("integrity: unavailable capsule fails closed", not no_capsule.ok and no_capsule.reason == "verification_failed")
    pawn.CapsuleComponent.GetScaledCapsuleHalfHeight = function() return math.huge end
    no_capsule = M.go_to(log, { 5, 0, 0 }, {})
    check("integrity: nonfinite capsule fails closed", not no_capsule.ok and no_capsule.reason == "verification_failed")
    pawn.CapsuleComponent.GetScaledCapsuleHalfHeight = capsule
    pawn.loc = { X = 0, Y = 0, Z = 0 }; M.go_to(log, { 2, 0, 0 }, { tolerance_m = 0.5, local_plan = false }); run(1)
    check("integrity: custom tolerance used", not (M.status().result and M.status().result.status == "arrived")); M.stop(log)
    M.go_to(log, { 0, 0, 0 }, {}); mc.IsMovingOnGround = function() error("unavailable") end; run(1)
    check("integrity: unavailable ground fails", M.status().result.reason == "verification_failed"); mc.IsMovingOnGround = function() return air <= 0 end
end

do
    walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
    pawn.loc = {X=0,Y=0,Z=0}
    local old_jump, old_stop = pawn.Jump, pawn.StopJumping
    M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    local st=_G.DW_MOVE
    st.mpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}
    st.mwp=2
    pawn.Jump=function() error("fake input failure") end
    run(1)
    check("jump binding: failed input does not consume route marker",st.result and st.result.reason=="verification_failed" and not (st.mem_jumped and st.mem_jumped[2]) and not st.jump_t)
    pawn.Jump=old_jump
    M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    st=_G.DW_MOVE
    st.mpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; st.mwp=2
    local started=0
    pawn.Jump=function(self) started=started+1; old_jump(self) end
    run(1)
    check("jump binding: accepted input marks once",started==1 and st.mem_jumped[2]~=nil and st.jump_observation.submitted==true)
    pawn.Jump=old_jump
    M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    local oldgen=_G.DW_MOVE.gen; local calls=0
    pawn.StopJumping=function(self)
        calls=calls+1
        pawn.StopJumping=old_stop
        M.go_to(log,{30,0,0},{nav=false,local_plan=false})
    end
    local stopped=M.stop(log)
    check("jump binding: reentrant stop cannot finish successor",not stopped.ok and calls==1 and _G.DW_MOVE.gen>oldgen and M.status().mode=="go_to")
    pawn.StopJumping=old_stop; M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    pawn.StopJumping=function() error("fake release failure") end
    stopped=M.stop(log)
    check("jump binding: release failure stops loop truthfully",not stopped.ok and M.status().mode=="idle" and M.status().result.detail=="jump release unconfirmed")
    pawn.StopJumping=old_stop
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE
    st.jump_t=T-0.5; st.jump_double=true; st.jump_release=false
    started=0; pawn.Jump=function(self) started=started+1; old_jump(self) end
    air=0; run(1)
    check("jump binding: second jump waits for airborne",started==0 and st.jump_double==true)
    air=1; run(1)
    check("jump binding: second jump submits once when airborne",started==1 and st.jump_double==false and st.double_jumps==1)
    pawn.Jump=old_jump; M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE
    st.jump_t=T-2; st.jump_double=true; st.jump_release=false
    local ground=pawn.CharacterMovement.IsMovingOnGround
    pawn.CharacterMovement.IsMovingOnGround=function() error("unknown ground") end
    run(1)
    check("jump binding: unknown airborne ends truthfully",st.result and st.result.detail=="airborne state unconfirmed for second jump")
    pawn.CharacterMovement.IsMovingOnGround=ground; air=0
    pawn.loc={X=0,Y=0,Z=0}; M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE
    st.mpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; st.mwp=2
    oldgen=st.gen; started=0
    pawn.Jump=function(self)
        started=started+1
        pawn.Jump=old_jump
        M.go_to(log,{30,0,0},{nav=false,local_plan=false})
    end
    run(1)
    check("jump binding: superseded during input cannot mark successor",started==1 and st.gen>oldgen and st.mode=="go_to" and not st.mem_jumped and not st.jump_t)
    pawn.Jump=old_jump; M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE; calls=0
    pawn.StopJumping=function() calls=calls+1 end; _G.DW_PAUSE=true
    stopped=M.stop(log)
    check("jump binding: pause has no native cleanup",not stopped.ok and calls==0 and st.mode=="go_to")
    _G.DW_PAUSE=nil; pawn.StopJumping=old_stop; M.stop(log)
    local A=assert(loadfile(dir.."/client_mod/scripts/arbiter.lua"))(); A.set_move(M)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); calls=0
    pawn.StopJumping=function() calls=calls+1 end
    local higher=A.request(log,{name="jump-binding-reflex",level="reflex",uses_move=true})
    check("jump binding: nil-owner suspension releases old input once",higher.ok and calls==1 and M.status().mode=="idle")
    pawn.StopJumping=old_stop; A.release(log,higher.token,"done"); M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE; local old_owner=_G.DWArbiter.owner
    local beforegen,beforehandle=st.gen,st.handle; calls=0; pawn.StopJumping=function() calls=calls+1 end
    _G.DWArbiter.owner=nil; stopped=M.stop(log)
    check("jump binding: orphan nil owner cannot stop",not stopped.ok and calls==0 and st.gen==beforegen and st.handle==beforehandle and st.mode=="go_to")
    _G.DWArbiter.owner=old_owner
    stopped=M.stop(log,{token=old_owner.token,record=old_owner})
    check("jump binding: forged context cannot stop",not stopped.ok and calls==0 and st.gen==beforegen and st.handle==beforehandle)
    pawn.StopJumping=old_stop; M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    higher=A.request(log,{name="expiry-reflex",level="reflex",uses_move=true})
    M.go_to(log,{30,0,0},{nav=false,local_plan=false,owner_token=higher.token})
    st=_G.DW_MOVE; beforegen,beforehandle=st.gen,st.handle
    local high_record=_G.DWArbiter.owner
    _G.DWArbiter.stack[#_G.DWArbiter.stack].suspended_at=os.time()-A.MAX_SUSPEND_S-1
    calls=0; pawn.StopJumping=function() calls=calls+1 end
    A.release(log,higher.token,"expire old suspended")
    check("jump binding: expired suspended owner cannot stop foreign move",calls==0 and st.gen==beforegen and st.handle==beforehandle and st.mode=="go_to" and st.owner_token==higher.token)
    _G.DWArbiter.owner=high_record; pawn.StopJumping=old_stop; M.stop(log); A.release(log,higher.token,"cleanup")
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE
    st.jump_t=T-0.5; st.jump_release=true; st.jump_double=false; oldgen=st.gen; calls=0
    pawn.StopJumping=function()
        calls=calls+1; pawn.StopJumping=old_stop; M.go_to(log,{30,0,0},{nav=false,local_plan=false})
    end
    run(1)
    check("jump binding: timed release reentry preserves successor",calls==1 and st.gen>oldgen and st.mode=="go_to" and not st.jump_t)
    pawn.StopJumping=old_stop; M.stop(log)
    local prior={marker=true}; _G.DWArbiter.move_stop_context=prior
    local dummy={status=function() return {mode="idle"} end,stop=function() error("injected stop") end}
    A.set_move(dummy)
    local first=A.request(log,{name="throw-old",level="command",uses_move=true,adopt=false})
    local next_owner=A.request(log,{name="throw-new",level="command",uses_move=true,adopt=false})
    check("jump binding: stop context restored after throw",first.ok and next_owner.ok and _G.DWArbiter.move_stop_context==prior)
    _G.DWArbiter.move_stop_context=nil; A.release(log,next_owner.token,"cleanup"); A.set_move(M)
end
end -- full mover scenarios before the isolated jump-path fixture
do
    local original_jump=pawn.Jump
    local function setup()
        pawn.Jump=original_jump; M.stop(log)
        walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
        pawn.loc={X=0,Y=0,Z=0}; M.go_to(log,{20,0,0},{nav=false,local_plan=false})
        local NM=assert(loadfile(dir..'/client_mod/scripts/navmem.lua'))()
        _G.DW_NAVMEM=NM.new_mem('test-world');_G.DW_NAVMEM._world='test-world'
        _G.DW_MOVE_WORLD={id='test-world',t=os.time()}
        return _G.DW_MOVE
    end
    local attempts=0
    local function refuse() attempts=attempts+1; error("rejected fake jump") end
    local st=setup(); st.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="djump"}}; st.lwp=2; st.lp_jumped={}; st.env={step=45,double_jump=true}
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: local djump rejection preserves marker",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.lp_jumped[2] and not st.jump_t)
    st=setup(); local crumb={X=140,Y=0,Z=0,air=true}
    st.crumbs={{X=0,Y=0,Z=0},crumb,{X=500,Y=0,Z=0}}; st.trail_i=2
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: trail rejection preserves crumbs",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.trail_jumped[crumb] and not st.trail_jumps)
    st=setup(); local link={id="test-link",from={0,0,-0.9},to={5,0,-0.9},move="jump"}
    local exec={link=link,phase="run",t0=T}; st.link_exec=exec
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: learned link rejection preserves phase",attempts==1 and st.result and st.result.reason=="verification_failed" and exec.phase=="run" and not exec.t_jump)
    st=setup(); st.win_t=T-2; st.win_pos={X=0,Y=0,Z=0}; st.stepoff_tried=true
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: stuck rejection has no strafe or jump",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.jump_t and not st.strafe_until)
    st=setup(); pawn.loc.Z=300; st.win_t=T-2; st.win_pos={X=0,Y=0,Z=300}
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: stepoff rejection preserves attempt",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.stepoff_tried and not st.stepoff)
    st=setup(); walls={{70,150,-50,50}}; st.use_lp=true; st.probe_t=T-10
    local old_trace=KSL_BASE
    KSL_BASE=function(self,ctx,a,b,ch,cx,ign,dbg,out)
        local hit=old_trace(self,ctx,a,b,ch,cx,ign,dbg,out)
        if hit and not out.Distance and out.ImpactPoint then
            out.Distance=math.sqrt((a.X-out.ImpactPoint.X)^2+(a.Y-out.ImpactPoint.Y)^2+(a.Z-out.ImpactPoint.Z)^2)
        end
        return hit
    end
    pawn.Jump=refuse; attempts=0; run(1); KSL_BASE=old_trace
    check("jump paths: reactive hop rejection preserves counter",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.hops and not st.jump_t)
    st=setup(); st.use_nav=true
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{2,0,1},{20,0,0}}}"):format(id) end; pump_oracle(); run(1)
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: oracle link rejection preserves marker",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.nav_jumped[2] and not st.link_jumps)
    local scenarios={
        {name="local",prepare=function(s) s.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; s.lwp=2; s.lp_jumped={}; return s.lp_jumped,2 end},
        {name="trail",prepare=function(s) local c={X=140,Y=0,Z=0,air=true}; s.crumbs={{X=0,Y=0,Z=0},c,{X=500,Y=0,Z=0}}; s.trail_i=2; return s.trail_jumped,c end},
        {name="memory",prepare=function(s) s.mpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; s.mwp=2; s.mem_jumped={}; return s.mem_jumped,2 end},
        {name="link",prepare=function(s) local e={phase="run",t0=T,link={id="t",from={0,0,-.9},to={5,0,-.9},move="jump"}}; s.link_exec=e; return e,"t_jump" end},
        {name="oracle",prepare=function(s)
            s.use_nav=true
            oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{2,0,1},{20,0,0}}}"):format(id) end; pump_oracle(); run(1)
            return s.nav_jumped,2
        end},
        {name="stepoff",prepare=function(s) pawn.loc.Z=300; s.win_t=T-2; s.win_pos={X=0,Y=0,Z=300}; return s,"stepoff_tried" end},
        {name="reactive hop",prepare=function(s)
            walls={{70,150,-50,50}}; s.use_lp=true; s.probe_t=T-10
            old_trace=KSL_BASE
            KSL_BASE=function(self,ctx,a,b,ch,cx,ign,dbg,out)
                local hit=old_trace(self,ctx,a,b,ch,cx,ign,dbg,out)
                if hit and not out.Distance and out.ImpactPoint then out.Distance=math.sqrt((a.X-out.ImpactPoint.X)^2+(a.Y-out.ImpactPoint.Y)^2+(a.Z-out.ImpactPoint.Z)^2) end
                return hit
            end
            return s,"hops"
        end,cleanup=function() KSL_BASE=old_trace end},
    }
    for _,scenario in ipairs(scenarios) do
        st=setup(); local marker,key=scenario.prepare(st); local before=st.gen; local created_token,created_handle; attempts=0
        pawn.Jump=function()
            if scenario.name == "oracle" then marker = st.nav_jumped end
            attempts=attempts+1; pawn.Jump=original_jump
            M.go_to(log,{30,0,0},{nav=false,local_plan=false})
            created_token,created_handle=st.owner_token,st.handle
        end
        run(1)
        check("jump preemption: "..scenario.name.." preserves successor and marker",attempts==1 and st.gen>before and st.mode=="go_to" and st.owner_token==created_token and st.handle==created_handle and loops[created_handle] and marker[key]==nil)
        if scenario.cleanup then scenario.cleanup() end
    end
    pawn.Jump=original_jump; M.stop(log)
end
if os.getenv('MOVE_JUMP_ONLY')=='1' then print(fails==0 and 'JUMP PATHS OK' or (fails..' FAILED'));os.exit(fails==0 and 0 or 1) end
do
    walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
    M.stop(log)
    local prior_world,prior_memory,prior_trap=_G.DW_MOVE_WORLD,_G.DW_NAVMEM,_G.DW_TRAP_CAND
    local world="jump-arrival-route-regression"
    _G.DW_MOVE_WORLD={id=world,t=os.time()}; _G.DW_NAVMEM=nil; _G.DW_TRAP_CAND=nil
    pawn.loc={X=0,Y=0,Z=0}; M.go_to(log,{25,0,0},{nav=false,local_plan=false,sprint=false}); run(100)
    local NM=assert(loadfile(dir.."/client_mod/scripts/navmem.lua"))()
    local saved=NM.load(dir,world,"L_World")
    local found=false
    for _,route in ipairs(saved.routes or {}) do
        if route.src=="self" and #route.pts>=2 and route.pts[#route.pts][1]-route.pts[1][1]>=10 then found=true end
    end
    check("jump memory: ordinary arrival persists own route",M.status().result and M.status().result.status=="arrived" and found)
    _G.DW_MOVE_WORLD,_G.DW_NAVMEM,_G.DW_TRAP_CAND=prior_world,prior_memory,prior_trap
end
do
    walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
    pawn.loc={X=0,Y=0,Z=0}; M.stop(log); M.go_to(log,{20,0,0},{nav=false,local_plan=false})
    local st=_G.DW_MOVE; local fired=false; local successor_gen,successor_token,successor_handle
    st.ws_job={cancel=function()
        if fired then return end
        fired=true
        M.go_to(log,{30,0,0},{nav=false,local_plan=false})
        successor_gen,successor_token,successor_handle=st.gen,st.owner_token,st.handle
    end}
    M.stop(log)
    check("jump reentry: cancel job preserves successor",fired and st.gen==successor_gen and st.owner_token==successor_token and st.handle==successor_handle and loops[successor_handle] and st.mode=="go_to")
    M.stop(log)
    M.go_to(log,{20,0,0},{nav=false,local_plan=false}); st=_G.DW_MOVE
    st.trip={{X=0,Y=0,Z=-90},{X=10000,Y=0,Z=-90}}; st.trip_ok=true
    fired=false; local sentinel={{X=10,Y=20,Z=30}}
    local function reentrant_log(message)
        if not fired and message:find("memory: self route",1,true) then
            fired=true
            M.go_to(log,{30,0,0},{nav=false,local_plan=false})
            successor_gen,successor_token,successor_handle=st.gen,st.owner_token,st.handle
            st.trip=sentinel
        end
    end
    M.stop(reentrant_log)
    check("jump reentry: memory flush preserves successor",fired and st.gen==successor_gen and st.owner_token==successor_token and st.handle==successor_handle and loops[successor_handle] and st.mode=="go_to" and st.trip==sentinel,
        string.format("fired=%s gen=%s token=%s handle=%s loop=%s mode=%s trip=%s",tostring(fired),tostring(st.gen==successor_gen),tostring(st.owner_token==successor_token),tostring(st.handle==successor_handle),tostring(loops[successor_handle]~=nil),tostring(st.mode),tostring(st.trip==sentinel)))
    M.stop(log)
end
NATIVE_SEGMENT_CASES()
for _, l in ipairs(logs) do if l:find("error") then print("LOG " .. l) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
