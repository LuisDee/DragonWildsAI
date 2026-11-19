-- Offline test for client_mod/scripts/move.lua: fake UE objects, a manual frame pump, a fake nav
-- oracle answering through the same files (with its heartbeat), and a fake LineTraceSingle over
-- the same fake world so the local planner (scripts/localplan.lua) runs too.
-- Usage: lua test_move.lua <empty_dir>      (MOVE_FILE=<path> tests another move.lua)
local dir = assert(arg[1], "usage: lua test_move.lua <empty_dir>"):gsub("\\", "/")
os.execute('mkdir "' .. (dir .. "/client_io/nav"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
do -- move.lua loads <root>/client_mod/scripts/{localplan,navmem,dkjson}.lua
    for _, n in ipairs({ "localplan.lua", "navmem.lua", "dkjson.lua", "avoidzones.lua", "arbiter.lua", "move.lua", "mapplayers.lua", "wetroute.lua",
                         "vendor/jumper/grid.lua", "vendor/jumper/pathfinder.lua", "vendor/jumper/core/bheap.lua", "vendor/jumper/core/heuristics.lua",
                         "vendor/jumper/core/node.lua", "vendor/jumper/core/path.lua", "vendor/jumper/search/astar.lua", "vendor/jumper/search/bfs.lua",
                         "vendor/jumper/search/dfs.lua", "vendor/jumper/search/dijkstra.lua", "vendor/jumper/search/jps.lua" }) do
        os.execute('mkdir "' .. (dir .. "/client_mod/scripts/" .. n):gsub("/[^/]*$", ""):gsub("/", "\\") .. '" 2>nul')
        local src = assert(io.open(here .. "/../scripts/" .. n, "rb")):read("a")
        local f = assert(io.open(dir .. "/client_mod/scripts/" .. n, "wb")); f:write(src); f:close()
    end
    os.execute('mkdir "' .. (dir .. "/data/nav"):gsub("/", "\\") .. '" 2>nul')
    os.execute('mkdir "' .. (dir .. "/mod/body"):gsub("/", "\\") .. '" 2>nul')
    local util = assert(io.open(here .. "/../../mod/body/util.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/mod/body/util.lua", "wb")); f:write(util); f:close()
end
_G.DW_WORLD_GUID = "test-world"
function json_cells(c) local o = {}; for _, k in ipairs(c) do o[#o + 1] = '"' .. k .. '"' end; return "[" .. table.concat(o, ",") .. "]" end
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
PINCH = nil
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
    if a.X == b.X and a.Y == b.Y and HOLES then
        for _, h in ipairs(HOLES) do if a.X > h[1] and a.X < h[2] and a.Y > h[3] and a.Y < h[4] then
            if h[5] and ch == 1 and a.Z > h[5] and b.Z < h[5] then -- deep water: the camera channel sees its surface
                out.Distance = a.Z - h[5]; out.ImpactPoint = { X = a.X, Y = a.Y, Z = h[5] }; out.ImpactNormal = { X = 0, Y = 0, Z = 1 }
                return true
            end
            return false
        end end
    end
    if a.X == b.X and a.Y == b.Y and STEEP then -- {x0, x1, y0, y1, drop per cm, normal Z}: a slope down in +X
        for _, sl in ipairs(STEEP) do if a.X > sl[1] and a.X < sl[2] and a.Y > sl[3] and a.Y < sl[4] then
            local top = FLOOR - (a.X - sl[1]) * sl[5]
            if a.Z < top or b.Z > top then return false end
            out.Distance = a.Z - top; out.ImpactPoint = { X = a.X, Y = a.Y, Z = top }; out.ImpactNormal = { X = -0.8, Y = 0, Z = sl[6] }
            return true
        end end
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
            local pinched = false -- PINCH: blocks his capsule, unseen by any trace (a tree and a log 0.8 m apart)
            for _, q in ipairs(PINCH or {}) do if nx > q[1] and nx < q[2] and ny > q[3] and ny < q[4] then pinched = true end end
            if pinched then
            elseif rise <= 45 or (air > 0 and rise <= 120) or (air > 0 and pawn.dbl and HAS_DJ and rise <= 260) or (air > 0 and near_portal and rise <= 700) then
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
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

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

do
    -- Drive the actual move module with a deterministic planner result. The real planner's
    -- nearest-node contract is covered separately; these isolate admission and ownership.
    local function observe_case(endpoint, tolerance, act)
        pawn.loc={X=0,Y=0,Z=0}; air=0; walls={}
        offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no)
        oracle=function() return nil end; pump_oracle()
        M.go_to(log,{8,0,3},{tolerance_m=tolerance})
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
    recovery.win_t=T-2; recovery.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}
    local original_jump_count=pawn.jumps; step(1)
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
            bounded.win_t=T-2; bounded.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}; step(1)
            step(1)
            local endx=x
            bounded.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=endx,Y=0,Z=210,act="walk"}} end,verify=function() return "ok" end}
            step(2)
            check("distinct replacement route admitted within retry bound",bounded.local_authority and bounded.lpath[#bounded.lpath].X==x,bounded.status)
        end
        bounded.win_t=T-2; bounded.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}; step(1)
        check("distinct routes still exhaust bounded replan",not bounded.local_authority and bounded.local_replans==3 and bounded.nav_fail=="local_replan_limit" and pawn.input==nil,bounded.status)
        step(1)
        check("exhausted replan falls back to local planning",bounded.mode=="go_to" and not bounded.nav_required and bounded.nav_fallback=="local_replan_limit",bounded.status)
        M.stop(log); M.cfg.lp_max_plans=old_limit
    end
    do -- A complete late oracle route may win, without mixing local waypoints.
        local race=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
        local pending=race.nav_pending
        race.win_t=T-2; race.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}; step(1); step(1)
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
        follow.win_t=T-2;follow.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z};step(2)
        check("exhausted local recovery keeps following via fallback",follow.mode=="follow" and not follow.nav_required and follow.nav_fallback~=nil,follow.status)
        M.stop(log);M.cfg.lp_max_plans=old_limit
    end
    do -- Owner can replace the move during the final stalled-route check.
        local owned_move=observe_case({X=800,Y=0,Z=210,act="walk"},0.5)
        local prior=owned_move.gen;owned_move.win_t=T-2;owned_move.win_pos={X=pawn.loc.X,Y=pawn.loc.Y,Z=pawn.loc.Z}
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
    pawn.loc={X=700,Y=0,Z=300}; step(1)
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
    -- (down on a floor: since 2026-11-19 a landing must stand on one, the top's floor under him)
    pawn.loc={X=300,Y=0,Z=300}; raised={{220,380,-80,80,300,300}}; air=0; step(1); raised={}
    check("grounded endpoint advances only after observed air",jump.lp_jump_exec==nil and jump.lwp==#jump.lpath+1 and jump.lpath[#jump.lpath].act=="walk",jump.status)
    M.stop(log); air=0
    local before_double=pawn.jumps
    local double=observe_case({X=300,Y=0,Z=210,act="djump"},6,"djump")
    step(14)
    check("double jump uses airborne second input",double.lp_jump_exec and double.lp_jump_exec.saw_air and pawn.jumps==before_double+2,double.status)
    M.stop(log); air=0
    local missed=observe_case({X=300,Y=0,Z=210,act="jump"},6)
    step(1); pawn.loc={X=-200,Y=0,Z=300}; raised={{-280,-120,-80,80,300,300}}; air=0; step(1); raised={}
    -- PLAN fix 1 (live 2026-10-31): a missed landing drops the local path and re-plans; the go_to keeps going
    check("missed landing re-plans without path success",missed.mode=="go_to" and not missed.result and missed.lpath==nil and
        missed.lp_jump_exec==nil and missed.lp_fail=="jump landing missed",missed.status)
    M.stop(log); air=0
    pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=800,Y=200,Z=300}
    offer.no=offer.no+1; offer.nonce=fake_nonce(offer.no); pump_oracle()
    M.follow(log,"Zezima",6); step(1)
    local follower=_G.DW_MOVE
    follower.lp={step=function() return "ready" end,plan=function() return {{X=0,Y=0,Z=-90,act="walk"},{X=300,Y=0,Z=210,act="jump"}} end,verify=function() return "ok" end}
    step(3); pawn.loc={X=-200,Y=0,Z=300}; raised={{-280,-120,-80,80,300,300}}; air=0; step(1); raised={}
    -- (since 2026-11-01 20:09Z: one missed landing re-plans, like go_to; the third of the trip is no_route, tested below)
    check("failed local jump preserves persistent follow",follower.mode=="follow" and not follower.unreach and follower.lp_fail=="jump landing missed" and follower.lpath==nil,follower.status)
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
        check("active mover injected for owned planner without nested move loads",m.lp_state=="sampling" and (m.traces or 0)-before==M.cfg.lp_budget and arb_loads>0 and injections==arb_loads and move_loads==0 and pawn.input==nil,move_loads)
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

if os.getenv("MOVE_AUTHORITY_ONLY") == "1" then
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; walls = {}; oracle = function() return nil end
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
    check("world identity change drops the pending route", _G.DW_MOVE.nav_pending == nil and _G.DW_MOVE.nav_fallback == "route_identity_changed", M.status().status)
    _G.DW_WORLD_GUID = "test-world"
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
    check("new helper epoch rejects old matching response", _G.DW_MOVE.path == nil and _G.DW_MOVE.nav_fallback == "oracle_restarted", M.status().status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
    oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',points={}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    local bad = M.status()
    check("no path falls back to drop-guarded walking", _G.DW_MOVE.nav_fallback == "no_path" and pawn.loc.X > 0, bad.status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(80)
    local partial = M.status()
    check("partial route, then fallback, reaches the goal", partial.result and partial.result.status == "arrived" and _G.DW_MOVE.nav_fallback ~= nil, tostring(pawn.loc.X) .. " " .. tostring(partial.status) .. " " .. tostring(partial.result and partial.result.detail))
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; _G.DW_TRAP_CAND = nil
    oracle = function(id) return ("return {id=%d,ok=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(80)
    local unknown = M.status()
    check("unknown partial endpoint arrives without learning a trap", unknown.result and unknown.result.status == "arrived" and _G.DW_TRAP_CAND == nil, unknown.status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }
    oracle = function(id) return ("return {id=%d,ok=true,points={{0,0,0},{1e308,0,0}}}"):format(id) end
    pump_oracle(); M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    check("overflowing converted waypoint is rejected", _G.DW_MOVE.path == nil and _G.DW_MOVE.nav_fallback == "invalid_route", M.status().status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; luis.loc = { X=2000, Y=200, Z=0 }
    local evpath = dir .. "/client_io/events/move.jsonl"
    os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
    os.remove(evpath)
    oracle = function(id) return ("return {id=%d,ok=true,partial=true,points={{0,0,0},{5,0,0}}}"):format(id) end
    pump_oracle(); M.follow(log, "Zezima", 3, {local_plan=false}); run(80)
    local follow = M.status(); local blocked = pawn.loc.X
    check("partial routed follow keeps following via fallback", follow.mode == "follow" and follow.status == "near" and _G.DW_MOVE.nav_fallback ~= nil, follow.status)
    oracle = function(id) return ("return {id=%d,ok=false,reason='no_path',points={}}"):format(id) end
    run(30)
    local count = 0; local events = io.open(evpath, "r")
    if events then for line in events:lines() do if line:find('"type":"unreachable"') then count=count+1 end end; events:close() end
    check("fallback follow emits no unreachable event", count==0 and M.status().mode == "follow", count)
    oracle = function(id) return ("return {id=%d,ok=true,partial=false,points={{%.2f,%.2f,0},{20,2,0}}}"):format(id,pawn.loc.X/100,pawn.loc.Y/100) end
    run(130)
    check("routed follow resumes on fresh admitted route", M.status().mode == "follow" and M.status().status == "near", M.status().status)
    M.stop(log); pawn.loc = { X=0, Y=0, Z=0 }; oracle = nil; pump_oracle()
    local original_timeout = M.cfg.nav_timeout_s; M.cfg.nav_timeout_s = 0.5
    M.go_to(log, {20,0,0}, {local_plan=false}); run(20)
    check("missing service falls back at once and walks", pawn.loc.X > 0 and _G.DW_MOVE.nav_fallback == "oracle_unavailable", _G.DW_MOVE.nav_fallback)
    M.stop(log); M.cfg.nav_timeout_s = original_timeout
    walls={{900,1100,-500,500}}; pawn.loc={X=0,Y=0,Z=0}
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{5,6,0},{12,6,0},{20,0,0}}}"):format(id) end
    pump_oracle()
    local saved_rename=os.rename
    os.rename=function(a,b) if tostring(b):find("req%.json$") then return nil,"denied" end return saved_rename(a,b) end
    M.go_to(log,{20,0,0},{tolerance_m=1}); run(100); os.rename=saved_rename
    check("refused rename still obtains admitted route", M.status().result and M.status().result.status == "arrived", tostring(M.status().status) .. " requests=" .. tostring(M.status().nav_requests))
    M.stop(log); walls={}; pawn.loc={X=0,Y=0,Z=0}; oracle=nil; pump_oracle()
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
    check("landing completes before the route requirement", flight.link_exec==nil and injected_after_required==0 and flight.nav_fallback~=nil, flight.status)
    M.stop(log); pawn.loc={X=0,Y=0,Z=0}; luis.loc={X=900,Y=200,Z=0}; air=0
    M.follow(log,"Zezima",3,{local_plan=false})
    flight=_G.DW_MOVE
    flight.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}
    flight.lwp=2; flight.lp_jumped={}
    before_jumps=pawn.jumps; step(1)
    local ordinary_accepted=flight.jump_t ~= nil and pawn.jumps==before_jumps+1
    luis.loc={X=2000,Y=200,Z=0}; step(100)
    check("ordinary jump finishes before the route requirement", ordinary_accepted and flight.nav_fallback~=nil, string.format("status=%s required=%s jumps=%s accepted=%s deferred=%s jump_t=%s release=%s",tostring(flight.status),tostring(flight.nav_required),tostring(pawn.jumps-before_jumps),tostring(ordinary_accepted),tostring(flight.nav_deferred_required),tostring(flight.jump_t),tostring(flight.jump_release)))
    M.stop(log); pawn.loc={X=0,Y=0,Z=0}
    M.go_to(log, {20,0,0}, {nav=false,local_plan=false}); run(60)
    check("explicit direct opt-out moves", pawn.loc.X > 0, pawn.loc.X)
    M.stop(log)
    do -- Actual arbiter + mover + interaction episode, no fake ownership layer.
        local A=assert(loadfile(dir.."/client_mod/scripts/arbiter.lua"))(); A.set_move(M)
        local SK=assert(loadfile(here.."/../scripts/skills.lua"))()
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
check("plateau: trail used", (s.trail_entries or 0) >= 1, s.trail_entries); if os.getenv("DBG8") then for i = math.max(1, #logs - 40), #logs do print("  " .. logs[i]) end end
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
do -- a trap that shut him in once is not walked first: his own way, stuck, then its exit (the stuck rung); that
    -- second escape counts once (not once per tick), and makes it a trusted trap
    local fm3 = io.open(memf); local txt = fm3 and fm3:read("a") or ""; if fm3 then fm3:close() end
    local traps = txt:match('"traps"%s*:%s*(%b[])') or ""
    local n_ok, n_used = tonumber(traps:match('"n_ok"%s*:%s*(%d+)')), tonumber(traps:match('"n_used"%s*:%s*(%d+)'))
    check("memory (b3): trap n_ok 2 (stuck again, escaped by its exit), n_used none", n_ok == 2 and n_used == nil, tostring(n_ok) .. " " .. tostring(n_used))
    local own = false
    for _, l in ipairs(logs) do if l:find("my own way first, its exit only if I get stuck", 1, true) then own = true end end
    check("memory (b3): the once-trap's exit was not walked first", own)
end
MB2.stop(log)
do
-- (b4) now trusted (it shut him in twice): its exit first, a use with no new evidence
_G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
pit_world()
local nlog = #logs
local MB3 = dofile(MOVE)
MB3.go_to(log, { 20, 0, 0 }, { tolerance_m = 1.5, timeout_s = 120, nav=false })
run(500)
s = MB3.status()
do
    local first = false
    for i = nlog + 1, #logs do if logs[i]:find("taking its exit first", 1, true) then first = true end end
    local fm4 = io.open(memf); local txt = fm4 and fm4:read("a") or ""; if fm4 then fm4:close() end
    local traps = txt:match('"traps"%s*:%s*(%b[])') or ""
    local n_ok, n_used = tonumber(traps:match('"n_ok"%s*:%s*(%d+)')), tonumber(traps:match('"n_used"%s*:%s*(%d+)'))
    check("memory (b4): a trusted trap's exit first, arrived, n_ok 2 n_used 1", first and s.result and s.result.status == "arrived"
        and n_ok == 2 and n_used == 1, tostring(first) .. " " .. tostring(s.result and s.result.status) .. " " .. tostring(n_ok) .. " " .. tostring(n_used))
end
MB3.stop(log)
-- (b5) the pit's walls are gone (a house torn down: t227, 2026-11-01): walks out of the "trap" with no stuck
-- count against it, and once they outnumber its escapes it is forgotten
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
do local f = io.open(memf, "w"); f:write([==[{"v":1,"next_id":9,"traps":[{"id":"t227","center":[0,0,-0.9],"radius_m":5,"z_max":0.5,"z_min":-3,
  "status":"verified","src":"learned","n_ok":1,"n_used":128,"exit":[[0,8,-0.9],[0,16,-0.9],[0,18,-0.9],[12,18,-0.9]]}],"taboos":[],"routes":[]}]==]); f:close() end
local said = {}
for k = 1, 2 do
    raised = {}; oracle = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil
    local n0 = #logs
    local MT = dofile(MOVE)
    MT.go_to(log, { 9, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav=false })
    run(300)
    local r = MT.status().result
    said[k] = { arrived = r and r.status == "arrived", walked = r and r.trip }
    for i = n0 + 1, #logs do
        if logs[i]:find("trap t227: I got where I was going with no stuck", 1, true) then said[k].against = logs[i] end
        if logs[i]:find("taking its exit first", 1, true) then said[k].exit_first = true end
    end
    MT.stop(log)
end
check("trap unlearn: a straight walk out of a once-trap is not routed by its exit", said[1].arrived and not said[1].exit_first, said[1].walked)
check("trap unlearn: the first clean walk counts against it", said[1].against and said[1].against:find("(1 such walks; it shut me in 1 time(s))", 1, true)
    and not said[1].against:find("forgotten", 1, true), said[1].against)
check("trap unlearn: the second clean walk forgets it", said[2].arrived and said[2].against and said[2].against:find("not a trap any more: forgotten", 1, true), said[2].against)
do
    _G.DW_NAVMEM = nil
    local NMt = dofile(dir .. "/client_mod/scripts/navmem.lua")
    local mem = NMt.load(dir, "test-world", "L_World")
    check("trap unlearn: forgotten on disk (no trap at the spot after a reload)", NMt.trap_at(mem, { X = 0, Y = 0, Z = -90 }) == nil)
end
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
end
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)

-- (b6) a spot that killed him (a fall off the world's edge: live 22:10/22:11Z): a walk toward it stops 2 m short and
-- says why; a walk away from it is not held; a goal beyond it, outside its 2 m ring (his grave beside the 05:44Z drop,
-- live 06:18:40Z), is reached round the ring
do
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
do local f = io.open(memf, "w"); f:write([==[{"v":1,"next_id":9,"traps":[],"taboos":[],"routes":[],
  "hazards":[{"at":[6,0,-0.9],"n":2,"cause":"fall","drop_m":40}]}]==]); f:close() end
local hz = {}
for k, gx in ipairs({ 7.2, -9, 9 }) do
    raised = {}; oracle = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil
    local n0 = #logs
    local MT = dofile(MOVE)
    hz[k] = { near = 1e9 }
    frame_hook = function() hz[k].near = math.min(hz[k].near, math.sqrt((pawn.loc.X - 600) ^ 2 + pawn.loc.Y ^ 2)) end
    MT.go_to(log, { gx, 0, 0 }, { tolerance_m = 1.5, timeout_s = 60, nav = false })
    run(400)
    frame_hook = nil
    local r = MT.status().result
    hz[k].r, hz[k].x = r, pawn.loc.X
    for i = n0 + 1, #logs do if logs[i]:find("move: hazard:", 1, true) then hz[k].said = logs[i] end end
    MT.stop(log)
end
check("hazard: a walk toward a spot that killed me stops short of it, failed known_drop",
    hz[1].r and hz[1].r.status == "failed" and hz[1].r.why == "known_drop" and hz[1].x <= 420 and hz[1].x >= 250
    and hz[1].r.detail and hz[1].r.detail:find("killed me 2 time(s)", 1, true) and hz[1].said ~= nil, hz[1].r and hz[1].r.detail .. " x=" .. hz[1].x)
check("hazard: a walk away from it is not held", hz[2].r and hz[2].r.status == "arrived", hz[2].r and hz[2].r.status)
check("hazard: a goal 3 m beyond it is reached round its ring (never within 2 m)", hz[3].r and hz[3].r.status == "arrived" and hz[3].near >= 190,
    (hz[3].r and tostring(hz[3].r.status) .. " " .. tostring(hz[3].r.detail) or "nil") .. " near=" .. hz[3].near)
do
    local MT = dofile(MOVE)
    _G.DW_NAVMEM = nil
    local h, new = MT.mark_hazard({ 6.5, 0.5, -0.9 }, { cause = "fall", drop_m = 41 })
    check("hazard: a death 0.7 m from a known hazard merges into it (n 3)", h and not new and h.n == 3 and h.drop_m == 41, h and h.n)
end
walls = {}; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
end

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

do -- 38b-38d in a block (the main chunk is at Lua's 200-locals limit)
zreset()
-- 38b. a setback is no stall while he is closing in again (live 20261116-184943, Ratcatcher: 8.8 m from a rat up a
--      hill he fell 5.8 m, climbed again, and 12 s after his best distance the chase ended "the Giant Rat keeps moving
--      away faster than I can catch up" while he was running at it 12.7 m off; the next attack reached it in 7 s)
luis.loc = { X = 4000, Y = 0, Z = 0 }
local fell38
frame_hook = function()
    luis.loc.Y = luis.loc.Y + 60 * DT -- it wanders, 0.6 m/s
    if not fell38 and pawn.loc.X > 3000 then fell38 = T; pawn.loc.X = pawn.loc.X - 2800 end
end
MZ = dofile(MOVE)
MZ.follow(log, { actor = luis }, 2, { nav=false, progress = { stall_s = 3 } })
local p38b, t38b = nil, T
while T - t38b < 14 do
    run(1)
    local p = MZ.status().progress
    if p.verdict ~= "ok" then p38b = p; break end
end
local d38b = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
check("progress: thrown back 28 m, he closes in again and is not called stalled", fell38 ~= nil and p38b == nil and d38b < 400,
    (p38b and (p38b.verdict .. " " .. tostring(p38b.why) .. " at " .. tostring(p38b.dist_m) .. " m, best " .. tostring(p38b.best_dist_m)) or "ok")
    .. " d=" .. math.floor(d38b) .. " fell=" .. tostring(fell38))
MZ.stop(log); frame_hook = nil

zreset()
-- 38c. the budget grows with the way there (budget_per_m): 40 m to a thing that stands still is a walk, not a chase
luis.loc = { X = 4000, Y = 0, Z = 0 }
MZ = dofile(MOVE)
MZ.follow(log, { actor = luis }, 2, { nav=false, progress = { stall_s = 3, budget_s = 2, budget_per_m = 0.5 } })
local p38c, t38c = nil, T
while T - t38c < 12 do
    run(1)
    local p = MZ.status().progress
    if p.verdict ~= "ok" then p38c = p; break end
end
check("progress: a budget with budget_per_m is not over on the walk there (2 s + 0.5 s a metre of 40 m)",
    p38c == nil and MZ.status().progress.budget_s and math.abs(MZ.status().progress.budget_s - 22) < 1.5,
    (p38c and (p38c.verdict .. " " .. tostring(p38c.why) .. " after " .. tostring(p38c.elapsed_s) .. " s") or "ok") .. " budget=" .. tostring(MZ.status().progress.budget_s))
MZ.stop(log)

zreset()
-- 38d. over the budget while he IS closing in again on a thing that moves: "too_long", never "it keeps moving away
--      faster than I can catch up" (the thing moved since his best distance, but he is the one who fell back)
luis.loc = { X = 6000, Y = 0, Z = 0 }
local fell38d
frame_hook = function()
    luis.loc.X = luis.loc.X + 150 * DT -- 1.5 m/s away, far slower than he runs
    if not fell38d and pawn.loc.X > 3000 then fell38d = T; pawn.loc.X = pawn.loc.X - 3000 end
end
MZ = dofile(MOVE)
MZ.follow(log, { actor = luis }, 2, { nav=false, progress = { stall_s = 6, budget_s = 8, moving_m = 2 } })
local p38d
for _ = 1, 150 do run(1); local p = MZ.status().progress; if p.verdict ~= "ok" then p38d = p; break end end
check("progress: over the budget while closing in -> too_long, not cant_catch", fell38d ~= nil and p38d and p38d.verdict == "stalled" and p38d.why == "too_long",
    (p38d and (p38d.verdict .. " " .. tostring(p38d.why) .. " moved=" .. tostring(p38d.target_moved_m) .. " at " .. tostring(p38d.dist_m)
        .. " best " .. tostring(p38d.best_dist_m) .. " after " .. tostring(p38d.elapsed_s)) or "never") .. " fell=" .. tostring(fell38d))
-- 38e. a thing that wanders while he stands at a wall is no ground made good: still stalled
zreset()
luis.loc = { X = 3000, Y = 0, Z = 0 }
walls = { { 900, 1100, -9000, 9000, true } }
local t38e = T
frame_hook = function() -- from 2 s on it goes 5 m further off and comes back, again and again; he is behind a wall he cannot pass
    luis.loc.X = 3000 + 500 * math.abs(math.sin(math.max(0, T - t38e - 2) * 0.8))
end
MZ = dofile(MOVE)
MZ.follow(log, { actor = luis }, 2, { nav=false, local_plan = false, progress = { stall_s = 5 } })
local p38e
while T - t38e < 20 do run(1); local p = MZ.status().progress; if p.verdict ~= "ok" then p38e = p; break end end
check("progress: the thing coming back nearer while he stands at a wall is not progress", p38e ~= nil and T - t38e < 9,
    (p38e and (p38e.verdict .. " " .. tostring(p38e.why)) or "never") .. " after " .. tostring(T - t38e) .. " s, pawn x=" .. math.floor(pawn.loc.X))
walls = {}
MZ.stop(log); frame_hook = nil
end

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

-- 43b. a go_to suspended by a reflex and resumed keeps ONE trip: the sentence covers the whole walk and names the pause
do
zreset()
walls = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }
MZ.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav = false, local_plan = false, cmd_id = "c43b" })
run(25)
local x_mid = pawn.loc.X
local snap43b = MZ.snapshot()
MZ.stop(log)
if snap43b and snap43b.opts.resume_trip then snap43b.opts.resume_trip.by = "combat:reflex" end
MZ.restore(log, snap43b)
run(400)
s = MZ.status()
local trip43b = s.result and s.result.trip or ""
check("trip: a resumed go_to keeps one trip from the first start, naming the pause",
    s.result and s.result.status == "arrived" and x_mid > 100 and trip43b:find("from %[0%.00,0%.00") ~= nil and
    trip43b:find("combat:reflex had my legs", 1, true) ~= nil and _G.DW_MOVE.cmd_id == "c43b",
    tostring(s.result and s.result.status) .. " mid=" .. tostring(x_mid) .. " trip=" .. trip43b)
MZ.stop(log)
end
-- 43c. a go_to suspended for a fight he then lost is not resumed from the respawn point
do
zreset()
walls = {}
pawn.loc = { X = 0, Y = 0, Z = 0 }
local life0 = _G.DW_LIFE
_G.DW_LIFE = { move_death_seq = 3 }
MZ.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, nav = false, local_plan = false })
run(10)
local snap43c = MZ.snapshot()
MZ.stop(log)
_G.DW_LIFE = { move_death_seq = 4, killed_by = "Giant Rat" }
local r43c = MZ.restore(log, snap43c)
local st43c = MZ.status()
check("restore: refused across a death, companion_down naming the killer",
    r43c and r43c.ok == false and r43c.reason == "companion_down" and st43c.mode ~= "go_to" and st43c.result and
    st43c.result.reason == "companion_down" and tostring(st43c.result.detail):find("Giant Rat", 1, true) ~= nil,
    tostring(r43c and r43c.reason) .. " mode=" .. tostring(st43c.mode) .. " detail=" .. tostring(st43c.result and st43c.result.detail))
_G.DW_LIFE = life0
MZ.stop(log)
end

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
-- 45b. the same stall after he has climbed most of the way: the height he began under is not what stops him (live
--      2026-11-17 07:36:11Z, run 073510: a rat 24 m up the hill, he climbed 19 m, was stopped against a ledge and the
--      attack ended "the Giant Rat is higher up than I can jump"; his reflex walked up to it 6 s later)
MZ.go_to(log, { 8, 0, 4.9 }, { tolerance_m = 0.35, timeout_s = 10, nav=false, progress = { stall_s = 3 } })
run(5)
_G.DW_MOVE.dz0 = 2400
run(145)
s = MZ.status()
check("progress: stopped at a ledge after climbing most of the height -> blocked, not the height he began under",
    s.result and s.result.status == "failed" and s.progress.why == "blocked", tostring(s.result and s.result.reason) .. " " .. tostring(s.progress and s.progress.why))
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
if os.getenv("WET_DEBUG") then for i = nlog46 + 1, #logs do if logs[i]:find("water", 1, true) then print("W46", logs[i]) end end end
check("water goal: arrives in the pond (known water), no dry detour", first46 and first46.status == "arrived" and s.result and s.result.status == "arrived" and said46,
    tostring(first46 and first46.status) .. " " .. tostring(s.result and s.result.status) .. " said=" .. tostring(said46))
MZ.stop(log)
-- 46b. a spot on the BED of the pond (the model took a water volume's own position from look; runs 20261116-214249
-- and -222242): wading over it is the arrival, and the arrival's verifier says so too. It said "position differs from
-- requested destination" with him in the water 2.4 m from the spot and 3.4 m above it: a miss for a walk that got there
do
MZ.go_to(log, { 2, 0, 0 }, { tolerance_m = 1.0 }); run(100)
MZ.go_to(log, { 7, 0, -3.4 }, { tolerance_m = 1.0, timeout_s = 60 })
run(300)
s = MZ.status()
local va46 = MZ.verify_arrival()
check("water goal on the pond's bed: arrived in the water over it", s.result and s.result.status == "arrived" and s.result.in_water == true
    and tostring(s.result.detail):find("under water, 3.4 m below me", 1, true) ~= nil, tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.detail))
check("water goal on the pond's bed: the verifier agrees he is over it", va46.ok == true and va46.over == true and va46.vertical_distance_m == 3.4,
    tostring(va46.reason) .. " " .. tostring(va46.detail))
local x46 = pawn.loc.X
pawn.loc.X = x46 - 300 -- 3 m further from it: no longer over the spot
va46 = MZ.verify_arrival()
check("water goal on the pond's bed: 3 m off is not over it, and the verifier says how far", va46.ok == false
    and tostring(va46.detail):find("m from the spot", 1, true) ~= nil and tostring(va46.detail):find("3.4 m above it", 1, true) ~= nil, tostring(va46.detail))
pawn.loc.X = x46
MZ.go_to(log, { 2, 0, 0 }, { tolerance_m = 1.0 }); run(100) -- the next walk starts clean: a dry spot is judged as before
va46 = MZ.verify_arrival()
check("water goal on the pond's bed: the next walk's arrival is the plain one", va46.ok == true and va46.over == nil, tostring(va46.detail))
MZ.stop(log)
end

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
    -- PLAN fix 1: an unconfirmed first jump skips the second press and the go_to carries on (noted on the trip)
    check("jump binding: unknown airborne skips the second jump",st.mode=="go_to" and not st.result and st.jump_double==false and
        st.trip_notes and st.trip_notes[#st.trip_notes]=="my jump never left the ground")
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
do
    local original_jump=pawn.Jump
    local function setup()
        pawn.Jump=original_jump; M.stop(log)
        walls, raised, oracle, frame_hook, air = {}, {}, nil, nil, 0
        M.cfg.prov_walk = false -- (jump-rejection units: no provisional walk before the route)
        pawn.loc={X=0,Y=0,Z=0}; M.go_to(log,{20,0,0},{nav=false,local_plan=false})
        return _G.DW_MOVE
    end
    local attempts=0
    local function refuse() attempts=attempts+1; error("rejected fake jump") end
    local st=setup(); st.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="djump"}}; st.lwp=2; st.lp_jumped={}; st.env={step=45,double_jump=true}
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: local djump rejection preserves marker",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.lp_jumped[2] and not st.jump_t)
    st=setup(); local crumb={X=140,Y=0,Z=0,air=true}
    walls={{300,320,-100,100}} -- his jump is over a low wall (a hop over open ground is not copied)
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
    oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{2,0,1}}}"):format(id) end; pump_oracle(); run(1)
    pawn.Jump=refuse; attempts=0; run(1)
    check("jump paths: oracle link rejection preserves marker",attempts==1 and st.result and st.result.reason=="verification_failed" and not st.nav_jumped[2] and not st.link_jumps)
    local scenarios={
        {name="local",prepare=function(s) s.lpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; s.lwp=2; s.lp_jumped={}; return s.lp_jumped,2 end},
        {name="trail",prepare=function(s) local c={X=140,Y=0,Z=0,air=true}; walls={{300,320,-100,100}}; s.crumbs={{X=0,Y=0,Z=0},c,{X=500,Y=0,Z=0}}; s.trail_i=2; return s.trail_jumped,c end},
        {name="memory",prepare=function(s) s.mpath={{X=0,Y=0,Z=-90,act="walk"},{X=500,Y=0,Z=-90,act="jump"}}; s.mwp=2; s.mem_jumped={}; return s.mem_jumped,2 end},
        {name="link",prepare=function(s) local e={phase="run",t0=T,link={id="t",from={0,0,-.9},to={5,0,-.9},move="jump"}}; s.link_exec=e; return e,"t_jump" end},
        {name="oracle",prepare=function(s)
            s.use_nav=true
            oracle=function(id) return ("return {id=%d,ok=true,partial=false,points={{0,0,0},{2,0,1}}}"):format(id) end; pump_oracle(); run(1)
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
    pawn.Jump=original_jump; M.stop(log); M.cfg.prov_walk = true
end
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
-- No admitted route (oracle absent) falls back to local planning at once instead of holding/failing;
-- straight steering is drop-guarded (the KillZ death was a beeline at a goal far below).
do
    M.stop(log); walls, raised, HOLES = {}, {}, nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; air = 0
    oracle = nil; pump_oracle()
    M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
    run(100)
    local r = M.status().result
    check("fallback: far go_to without an oracle walks and arrives", r and r.status == "arrived" and _G.DW_MOVE.nav_fallback ~= nil,
        r and (tostring(r.status) .. " " .. tostring(r.detail)))
    M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }
    HOLES = { { 200, 3000, -3000, 3000 } }
    if _G.DW_NAVMEM then _G.DW_NAVMEM.routes = {} end -- the first case remembered this very line: test the straight guard
    local old_plans = M.cfg.lp_max_plans; M.cfg.lp_max_plans = 0
    M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1 })
    run(30)
    r = M.status().result
    check("fallback: drop ahead stops the straight walk with an honest failure", r and r.status == "failed" and pawn.loc.X < 200 and
        tostring(r.detail):find("drop ahead", 1, true), r and (tostring(r.status) .. " " .. tostring(r.detail) .. " x=" .. pawn.loc.X))
    M.cfg.lp_max_plans = old_plans; HOLES = nil; M.stop(log)
end
-- Steering hands on in order within ONE frame: a source that runs out (a local segment done, the trail caught up)
-- gives the frame to the next one (trail, then a remembered route), never a frame of straight steering.
do
    M.stop(log); walls, raised, oracle, frame_hook, air, HOLES = {}, {}, nil, nil, 0, nil; pump_oracle()
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 20, 0, 0 }, { nav = false, local_plan = false, sprint = false })
    local st = _G.DW_MOVE
    st.mem_checked = true
    st.lpath, st.lwp = { { X = -100, Y = 0, Z = -90, act = "walk" }, { X = 0, Y = 0, Z = -90, act = "walk" } }, 2
    st.crumbs, st.trail_i = { { X = -100, Y = 0, Z = 0 }, { X = 0, Y = -500, Z = 0 } }, 2
    step(1)
    check("steering: a finished local segment hands the same frame to the trail",
        st.lpath == nil and st.source == "trail" and pawn.input and pawn.input.Y < -0.9, tostring(st.source))
    M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 20, 0, 0 }, { nav = false, local_plan = false, sprint = false })
    st = _G.DW_MOVE
    st.mem_checked = true
    st.crumbs, st.trail_i = { { X = -100, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 } }, 2
    st.mpath, st.mwp = { { X = 0, Y = 0, Z = -90 }, { X = 0, Y = 500, Z = -90 } }, 2
    step(1)
    check("steering: a caught-up trail hands the same frame to the remembered route",
        st.trail_i == nil and st.source == "memory" and pawn.input and pawn.input.Y > 0.9, tostring(st.source))
    M.stop(log)
end
-- A local plan is made toward a point of the remembered route some metres ahead. Where it ends, the route picks up
-- at that point, not at the point he was on when the plan began. Live 2026-11-17 12:00:37Z (run 120009) and
-- 07:35:50Z (run 073510): a plan took him up a 3 m ledge to the route's point 25; the route's index still stood at
-- point 21 at the ledge's foot, he ran back to it off the ledge, and the attack ended path_blocked.
do
    M.stop(log); walls, raised, oracle, frame_hook, air, HOLES = { { -30, 30, 150, 210, true } }, {}, nil, nil, 0, nil; pump_oracle()
    _G.DW_LP_CACHE = nil
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 7, -15, 0 }, { nav = false, sprint = false })
    local st = _G.DW_MOVE
    st.mem_checked = true
    -- the route's first two points lie close together and off the plan's way, so he neither reaches nor passes them
    st.mpath, st.mwp, st.msrc = { { X = 0, Y = 400, Z = -90 }, { X = 0, Y = 460, Z = -90 }, { X = 700, Y = 400, Z = -90 },
        { X = 700, Y = -1500, Z = -90 } }, 1, "memory"
    local n0, at_far, back = #logs, false, false
    frame_hook = function()
        if math.abs(pawn.loc.X - 700) < 120 and math.abs(pawn.loc.Y - 400) < 120 then at_far = true end
        if at_far and pawn.loc.X < 450 then back = true end
    end
    run(250)
    local planned = false
    for i = n0 + 1, #logs do if logs[i]:find("(wall_ahead)", 1, true) and logs[i]:find("toward (700,400", 1, true) then planned = true end end
    local r = M.status().result
    check("remembered route: a local plan toward a point of it ends there and the route goes on from that point",
        planned and at_far and not back and r and r.status == "arrived",
        string.format("planned=%s at_far=%s back=%s status=%s at=(%.0f,%.0f)", tostring(planned), tostring(at_far), tostring(back),
            tostring(r and r.status), pawn.loc.X, pawn.loc.Y))
    M.stop(log); frame_hook = nil; walls = {}
end
-- A malformed oracle answer is never a route: each shape below falls back with "invalid_route".
do
    for _, case in ipairs({
        { "one point", "points={{0,0,0}}" },
        { "two coordinates", "points={{0,0,0},{5,0}}" },
        { "four coordinates", "points={{0,0,0},{5,0,0,1}}" },
        { "named key in a point", "points={{0,0,0},{5,0,0,x=1}}" },
        { "NaN coordinate", "points={{0,0,0},{0/0,0,0}}" },
        { "infinite coordinate", "points={{0,0,0},{1/0,0,0}}" },
        { "string coordinate", "points={{0,0,0},{'5',0,0}}" },
        { "non-boolean partial", "partial='no',points={{0,0,0},{5,0,0}}" },
        { "non-boolean goal_projected", "goal_projected=1,points={{0,0,0},{5,0,0}}" },
        { "points not a table", "points=5" },
    }) do
        local name, body = case[1], case[2]
        M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }; _G.DW_TRAP_CAND = nil
        offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
        oracle = function(id) return ("return {id=%d,ok=true," .. body .. "}"):format(id) end
        pump_oracle(); M.go_to(log, { 20, 0, 0 }, { local_plan = false }); run(3)
        check("malformed oracle route rejected: " .. name, _G.DW_MOVE.path == nil and _G.DW_MOVE.nav_fallback == "invalid_route",
            tostring(_G.DW_MOVE.nav_fallback))
    end
    M.stop(log); oracle = nil; pump_oracle()
end
-- FAR PLAYER (retro 2026-11-01 root cause 3): out of net relevancy his pawn is not replicated (PawnPrivate nil), but the
-- game map's registry (GameplayObjectRegistry.PlayerCharacters) lists him: go_to walks toward the marker, re-reads it as
-- he moves, hands over to his pawn once it replicates and arrives at HIM; my own map row is never a target; a follow of
-- a marker 400 m off walks (no "leader_far" hold); a name on no map fails with who IS on the map.
do
    M.stop(log); walls, raised, oracle, frame_hook, air, HOLES = {}, {}, nil, nil, 0, nil; pump_oracle()
    local function fstr(s) return { ToString = function() return s end } end
    local rows = {}
    local REG = obj({ PlayerCharacters = { ForEach = function(_, fn) for i, e in ipairs(rows) do fn(i, e) end end } })
    local base_find = FindAllOf
    FindAllOf = function(c) if c == "GameplayObjectRegistry" then return { REG } end return base_find(c) end
    pawn.PlayerState = obj({ GetPlayerName = function() return fstr("ClaudeDev") end })
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 30000, Y = 0, Z = 0 }
    rows[1] = { OwningPlayerName = fstr("ClaudeDev"), Location = pawn.loc, Identifier = { A = 1, B = 1, C = 1, D = 1 } }
    rows[2] = { OwningPlayerName = fstr("Zezima"), Location = luis.loc, Identifier = { A = 2, B = 2, C = 2, D = 2 } }
    local relevancy_cm = 15000
    local handed = nil
    frame_hook = function()
        _G.DWMapPlayers = nil -- a fresh registry read every frame (the module caches 0.5 s of os.clock)
        local near = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2) < relevancy_cm
        ps_luis.PawnPrivate = near and luis or nil
        if near and not handed then handed = T end
    end
    ps_luis.PawnPrivate = nil
    local r0 = M.go_to(log, "Zezima", { tolerance_m = 2, nav = false, local_plan = false })
    check("far player: go_to starts on his map marker", r0.ok and r0.target_via == "map" and r0.target_position and r0.target_position[1] == 300,
        tostring(r0.target_via) .. " " .. tostring(r0.target_position and r0.target_position[1]))
    run(60)
    local s1 = M.status()
    check("far player: walks toward the marker (tracked via the map)", s1.mode == "go_to" and s1.target_via == "map" and pawn.loc.X > 1500,
        tostring(s1.mode) .. " " .. tostring(s1.target_via) .. " x=" .. math.floor(pawn.loc.X))
    luis.loc.Y = 4000 -- he walks 40 m south; his map row follows (same table)
    run(10)
    check("far player: the marker is re-read as he moves", M.status().target_pos and math.abs(M.status().target_pos[2] - 40) < 1,
        M.status().target_pos and M.status().target_pos[2])
    run(700)
    local s2 = M.status()
    check("far player: handed over to his pawn once it replicated", handed ~= nil and (s2.target_via == "sight" or (s2.result and s2.result.status == "arrived")),
        tostring(s2.target_via) .. " handed=" .. tostring(handed))
    check("far player: arrives at him", s2.result and s2.result.status == "arrived" and
        math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2) < 300,
        s2.result and (tostring(s2.result.status) .. " " .. tostring(s2.result.reason)) or s2.mode)
    -- my own map row is not a player to walk to; a name on no map fails with who IS on it
    M.stop(log); frame_hook = nil; ps_luis.PawnPrivate = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }; rows[1].Location = pawn.loc
    _G.DWMapPlayers = nil
    local r1 = M.go_to(log, "ClaudeDev", { nav = false, local_plan = false })
    check("far player: my own map row is no target", r1.ok and r1.target_via == nil, tostring(r1.target_via))
    local T0, fail_t = T, nil
    for _ = 1, 130 do run(1); if M.status().result and not fail_t then fail_t = T - T0 end end
    check("far player: a name never seen fails in ~2 s (not 10 s)", fail_t and fail_t < 3, tostring(fail_t))
    local s3 = M.status()
    local on_map = s3.result and tostring(s3.result.detail):match("on the map: ([^)]*)") or ""
    check("far player: unknown name fails truthfully, naming who is on the map", s3.result and s3.result.reason == "target_not_visible" and
        on_map == "Zezima", s3.result and tostring(s3.result.detail))
    -- follow a marker 400 m away: walks to him, no "leader_far" hold (his position is known)
    M.stop(log); _G.DWMapPlayers = nil; luis.loc = { X = 40000, Y = 0, Z = 0 }; rows[2].Location = luis.loc
    frame_hook = function() _G.DWMapPlayers = nil end
    M.follow(log, "Zezima", 3, { nav = false, local_plan = false })
    run(30)
    local s4 = M.status()
    check("far player: follow of a 400 m marker walks (no leader_far hold)", s4.mode == "follow" and s4.status ~= "leader_far" and
        s4.target_via == "map" and pawn.loc.X > 500, tostring(s4.status) .. " " .. tostring(s4.target_via) .. " x=" .. math.floor(pawn.loc.X))
    -- with the nav oracle (a far goal needs its route): he keeps moving while the oracle takes its time. A fixed 3 m
    -- drift dropped every pending request, so Claude stood "planning" (live 2026-11-01 12:45, 435 m, 0 m in 12 s).
    M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }; rows[1].Location = pawn.loc
    luis.loc = { X = 30000, Y = 0, Z = 0 }; rows[2].Location = luis.loc; ps_luis.PawnPrivate = nil
    local asked, waited = nil, 0
    oracle = function(id)
        if id ~= asked then asked, waited = id, 0 end
        waited = waited + 1
        if waited < 20 then return nil end -- ~2 s per answer (a pump per 3 frames)
        return ("return {id=%d,ok=true,partial=false,points={{%.2f,%.2f,0},{%.2f,%.2f,0}}}"):format(id,
            pawn.loc.X / 100, pawn.loc.Y / 100, luis.loc.X / 100, luis.loc.Y / 100)
    end
    pump_oracle()
    frame_hook = function()
        _G.DWMapPlayers = nil
        luis.loc.Y = luis.loc.Y + 12 -- he walks on, 3.6 m/s
        ps_luis.PawnPrivate = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2) < relevancy_cm and luis or nil
    end
    M.go_to(log, "Zezima", { tolerance_m = 2, local_plan = false })
    run(200)
    local s5 = M.status()
    check("far player: a moving marker still gets its route and walks", pawn.loc.X > 3000 and (s5.nav_requests or 0) >= 1,
        tostring(s5.status) .. " x=" .. math.floor(pawn.loc.X) .. " requests=" .. tostring(s5.nav_requests))
    M.stop(log); frame_hook = nil; oracle = nil; pump_oracle()
    FindAllOf = base_find; pawn.PlayerState = nil; ps_luis.PawnPrivate = luis; _G.DWMapPlayers = nil
end
-- MOVEMENT LADDER (2026-11-01): a follow of a leader in sight walks his trail. A slow oracle (answers never come)
-- must not make him stand "planning" once the leader is beyond 10 m; he sprints to match a running leader; where
-- the leader climbs onto something out of reach, Claude takes the trail where it comes back down.
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; HOLES = nil; air = 0; sprinting = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 300, Y = 0, Z = 0 }; ps_luis.PawnPrivate = luis
    oracle = function() return nil end; pump_oracle() -- alive, but never answers
    frame_hook = function() luis.loc.X = luis.loc.X + 650 * DT end -- he runs east at 6.5 m/s
    M.follow(log, "Zezima", 3)
    local planning, far_n, near_n, n = 0, 0, 0, 0
    for _ = 1, 150 do -- 15 s
        run(1)
        local st = _G.DW_MOVE
        local d = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2)
        n = n + 1
        if d <= 600 then near_n = near_n + 1 end
        if d > 1000 then far_n = far_n + 1 end
        if st.status == "planning" then planning = planning + 1 end
    end
    local st = _G.DW_MOVE
    check("trail follow: no oracle wait behind a running leader", planning == 0 and far_n == 0 and st.trail_led == true,
        string.format("planning=%d far=%d led=%s nav_required=%s", planning, far_n, tostring(st.trail_led), tostring(st.nav_required)))
    check("trail follow: sprints to match him (within 6 m 90%+)", near_n / n >= 0.9 and (st.sprint_presses or 0) >= 1,
        string.format("near=%d/%d presses=%s", near_n, n, tostring(st.sprint_presses)))
    -- he hops onto a 2.4 m crate (out of Claude's single-jump reach), walks along it and comes down: Claude goes
    -- round below and picks up the trail where it comes down
    M.stop(log); frame_hook = nil; sprinting = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 300, Y = 0, Z = 0 }
    raised = { { 1000, 1600, -150, 150, 240, 240 } } -- crate x 10-16 m, y +-1.5 m, 2.4 m high
    local lx = 300
    frame_hook = function()
        if lx < 2400 then lx = lx + 450 * DT end
        luis.loc.X, luis.loc.Y = lx, 0
        luis.loc.Z = (wall_top(lx, 0) or FLOOR) + 90
    end
    M.follow(log, "Zezima", 3, { local_plan = true })
    run(200)
    local s2 = M.status()
    local d2 = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2)
    local skipped = false
    for _, l in ipairs(logs) do if l:find("trail: his path goes") then skipped = true end end
    check("trail follow: round a crate he hopped over, to him", d2 < 450 and math.abs(pawn.loc.Z - luis.loc.Z) < 60 and skipped,
        string.format("d=%.0f dz=%.0f status=%s skipped=%s", d2, pawn.loc.Z - luis.loc.Z, tostring(s2.status), tostring(skipped)))
    M.stop(log); frame_hook = nil; raised = {}; oracle = nil; pump_oracle()
end

-- the same walk with NOTHING there: his recorded path rises 2.4 m over flat ground (a ghost's hop arcs read as on-ground,
-- or a log since chopped; doric follow 04:59Z): our ground lies right under those crumbs, so no "walking below him"
;(function()
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; sprinting = false; oracle = function() return nil end; pump_oracle()
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 300, Y = 0, Z = 0 }; ps_luis.PawnPrivate = luis
    local lx, l_air = 300, false
    luis.CharacterMovement = obj({ IsMovingOnGround = function() return not l_air end })
    frame_hook = function()
        if lx < 2400 then lx = lx + 450 * DT end
        l_air = (lx > 850 and lx < 1000) or (lx > 1600 and lx < 1700)
        luis.loc.X, luis.loc.Y = lx, 0
        luis.loc.Z = FLOOR + 90 + ((lx > 1000 and lx < 1600) and 240 or 0) + (l_air and 120 or 0)
    end
    local n0 = #logs
    M.follow(log, "Zezima", 3, { local_plan = true })
    run(200)
    local below = false
    for i = n0 + 1, #logs do if logs[i]:find("walking below him", 1, true) or logs[i]:find("skipping to where it comes back down", 1, true) then below = logs[i] end end
    local dd = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2)
    check("trail follow: his path high over our own ground is no climb (no walking below him)", not below and dd < 450,
        string.format("d=%.0f %s", dd, tostring(below)))
    M.stop(log); frame_hook = nil; luis.CharacterMovement = nil; oracle = nil; pump_oracle()
end)()

-- the same crate, but he JUMPS onto it (airborne crumbs before the top): Claude tries the jump, misses (2.4 m is out
-- of his reach) and, back on the ground at the take-off, takes the trail where it comes down instead of pushing on
do
    M.stop(log); frame_hook = nil; walls = {}; air = 0; sprinting = false; HAS_DJ = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 300, Y = 0, Z = 0 }; pawn.jumps = 0
    raised = { { 1000, 1600, -150, 150, 240, 240 } }
    local lx, l_air = 300, false
    luis.CharacterMovement = obj({ IsMovingOnGround = function() return not l_air end })
    frame_hook = function()
        if lx < 2400 then lx = lx + 450 * DT end
        l_air = (lx > 850 and lx < 1000) or (lx > 1600 and lx < 1700)
        luis.loc.X, luis.loc.Y = lx, 0
        luis.loc.Z = (wall_top(lx, 0) or FLOOR) + 90 + (l_air and 120 or 0)
    end
    local n0 = #logs
    M.follow(log, "Zezima", 3, { local_plan = true })
    run(220)
    local s = M.status()
    local d = math.sqrt((luis.loc.X - pawn.loc.X) ^ 2 + (luis.loc.Y - pawn.loc.Y) ^ 2)
    local skipped = false
    for k = n0 + 1, #logs do if logs[k]:find("trail: his path goes") then skipped = true end end
    check("trail follow: a jump of his he can't make -> round, to him", d < 450 and math.abs(pawn.loc.Z - luis.loc.Z) < 60 and skipped and pawn.jumps >= 1,
        string.format("d=%.0f dz=%.0f status=%s skipped=%s jumps=%d", d, pawn.loc.Z - luis.loc.Z, tostring(s.status), tostring(skipped), pawn.jumps))
    M.stop(log); frame_hook = nil; raised = {}; luis.CharacterMovement = nil; oracle = nil; pump_oracle()
end

-- TRAVEL SPEED (2026-11-01 trips: 9.8-11.9 s standing at the start of every 150+ m go_to while the dev server streamed
-- the route in): he walks toward the goal while a long route is pending, then joins the route where he is
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local asked, waited = nil, 0
    oracle = function(id)
        if id ~= asked then asked, waited = id, 0 end
        waited = waited + 1
        if waited < 30 then return nil end -- ~3 s
        return ("return {id=%d,ok=true,partial=false,points={{0,0,-0.9},{20,0,-0.9},{40,0,-0.9},{60,0,-0.9},{80,0,-0.9}}}"):format(id)
    end
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no) -- a fresh offer (earlier cases left theirs used)
    pump_oracle()
    local n0 = #logs
    M.go_to(log, { 80, 0, 0 }, { tolerance_m = 2 })
    run(25) -- ~2.5 s: the route has not come yet
    local x_wait = pawn.loc.X
    run(300)
    local s = M.status()
    local joined = false
    for k = n0 + 1, #logs do if logs[k]:find("joining it at point") then joined = true end end
    check("long go_to: walks while the route is pending, then joins it", x_wait > 300 and joined and s.result and s.result.status == "arrived",
        string.format("x_wait=%.0f joined=%s result=%s", x_wait, tostring(joined), tostring(s.result and s.result.status)))
    M.stop(log); oracle = nil; pump_oracle()
end

-- A PARTIAL route left behind (live 2026-11-01 17:20: asked from inside the temple, a navmesh island, it ended at the
-- island's edge; he had walked out of the doorway meanwhile, joined it at its end and walked back in): asked again
-- from where he is, and the new route is the one he walks
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local asked, waited, answers, max_back = nil, 0, 0, 0
    oracle = function(id)
        if id ~= asked then asked, waited = id, 0 end
        waited = waited + 1
        if waited < 30 then return nil end -- ~3 s: he walks on meanwhile
        answers = answers + 1
        if answers == 1 then -- from the start: partial, ending 5 m BEHIND the start (the island's edge)
            return ("return {id=%d,ok=true,partial=true,points={{0,0,-0.9},{-3,2,-0.9},{-5,0,-0.9}}}"):format(id)
        end
        return ("return {id=%d,ok=true,partial=false,points={{%.2f,0,-0.9},{60,0,-0.9},{80,0,-0.9}}}"):format(id, pawn.loc.X / 100)
    end
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no)
    pump_oracle()
    local n0 = #logs
    M.go_to(log, { 80, 0, 0 }, { tolerance_m = 2 })
    local x_at_answer
    for _ = 1, 300 do
        run(1)
        if answers == 1 and not x_at_answer then x_at_answer = pawn.loc.X end
        if x_at_answer then max_back = math.max(max_back, x_at_answer - pawn.loc.X) end
        if M.status().result then break end
    end
    local s = M.status()
    local reasked = false
    for k = n0 + 1, #logs do if logs[k]:find("ends %d+ m behind me") then reasked = true end end
    check("a partial route left behind is asked again from where he is, never walked back", reasked and answers >= 2 and max_back < 100
        and s.result and s.result.status == "arrived", string.format("reasked=%s answers=%d back=%.0f result=%s", tostring(reasked), answers,
        max_back, tostring(s.result and (s.result.status .. " " .. tostring(s.result.detail)))))
    M.stop(log); oracle = nil; pump_oracle()
end

-- TRAPS (live 2026-11-01, t161 on the ladders' southeast start): a fixture teleport between the stuck and the
-- next sample is no escape route, and walking straight out the way that "failed" is no trap
walls = {}; raised = {}; oracle = nil; _G.DW_NAVMEM = nil; _G.DW_LP_CACHE = nil
os.remove(dir .. "/data/skills/test-world/nav_memory.json")
luis.loc = { X = 90000, Y = 90000, Z = 0 }
do
    local function learned_since(n0) for i = n0 + 1, #logs do if logs[i]:find("memory: trap", 1, true) then return true end end return false end
    _G.DW_TRAP_CAND = { at = { X = 0, Y = 0, Z = -90 }, t = os.time(), toward = { X = 500, Y = 0, Z = -90 } }
    pawn.loc = { X = 5000, Y = 0, Z = 0 }
    local n0 = #logs
    local MT = dofile(MOVE)
    MT.go_to(log, { 75, 0, 0 }, { tolerance_m = 1.5, timeout_s = 30, nav = false })
    run(200)
    check("traps: a teleport after the stuck drops the candidate", _G.DW_TRAP_CAND == nil and not learned_since(n0), tostring(_G.DW_TRAP_CAND))
    MT.stop(log)
    _G.DW_NAVMEM = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
    _G.DW_TRAP_CAND = { at = { X = 0, Y = 0, Z = -90 }, t = os.time(), toward = { X = 500, Y = 0, Z = -90 } }
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    n0 = #logs
    MT = dofile(MOVE)
    MT.go_to(log, { 30, 0, 0 }, { tolerance_m = 1.5, timeout_s = 30, nav = false })
    run(300)
    local said = false
    for i = n0 + 1, #logs do if logs[i]:find("not a trap", 1, true) then said = true end end
    check("traps: walked straight out the way that failed -> not a trap", said and not learned_since(n0) and _G.DW_TRAP_CAND == nil)
    MT.stop(log)
    _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(dir .. "/data/skills/test-world/nav_memory.json")
end

-- LETHAL DROP (live 2026-11-01 15:56, quests run: explore slid off a cliff shoulder and fell 36 m): every walk,
-- not only the no-route straight walk, refuses a drop deeper than his safe fall, and the reason names the drop
do
    M.stop(log); walls, raised, oracle, frame_hook = {}, {}, nil, nil; pump_oracle(); pawn.loc = { X = 0, Y = 0, Z = 0 }; air = 0
    luis.loc = { X = 90000, Y = 90000, Z = 0 }
    HOLES = { { 300, 3000, -3000, 3000 } }
    _G.DW_LP_CACHE = nil
    if _G.DW_NAVMEM then _G.DW_NAVMEM.routes = {} end
    local MD = dofile(MOVE)
    MD.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, nav = false })
    run(200)
    local r = MD.status().result
    check("lethal drop: a plain go_to stops before the edge and names the drop", r and r.status == "failed" and pawn.loc.X < 300
        and r.why == "drop_ahead" and tostring(r.detail):find("drop", 1, true),
        r and (tostring(r.status) .. " " .. tostring(r.why) .. " " .. tostring(r.detail) .. " x=" .. pawn.loc.X))
    check("lethal drop: the words say so", tostring(MD.why_words("drop_ahead", "it")):find("drop of more than 8 m ahead, more than I can fall safely", 1, true), MD.why_words("drop_ahead", "it"))
    MD.stop(log); _G.DW_LP_CACHE = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }
    -- deep water off the shore (its surface 1 m down, its bed out of reach) is a swim, not a fall
    local saved_ch = rawget(_G, "DW_WATER_CH")
    _G.DW_WATER_CH = { name = "cam", ch = 1 }
    HOLES = { { 300, 3000, -3000, 3000, -100 } }
    local nl = #logs
    MD.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, nav = false })
    run(60)
    local said = false
    for i = nl + 1, #logs do if logs[i]:find("(safe fall", 1, true) then said = logs[i] end end
    check("lethal drop: deep water off a shore is not a drop", not said, said)
    MD.stop(log); HOLES = nil; _G.DW_LP_CACHE = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }
    -- a slope too steep to stand on (normal 0.4) running down to the edge: he stops before stepping onto it
    -- (live 2026-11-01 16:37: a 6 m walk to his grave slid him off the cliff-top shoulder)
    STEEP = { { 300, 500, -3000, 3000, 1.5, 0.4 } }
    HOLES = { { 500, 3000, -3000, 3000 } }
    MD.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, nav = false })
    run(200)
    r = MD.status().result
    check("lethal drop: a steep slope down to a drop is refused before he steps on it", r and r.status == "failed"
        and pawn.loc.X < 300 and tostring(r.detail):find("too steep", 1, true),
        r and (tostring(r.status) .. " " .. tostring(r.detail) .. " x=" .. pawn.loc.X))
    MD.stop(log); HOLES = nil; _G.DW_LP_CACHE = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }
    -- the same slope ending on a floor within a safe fall is just a bank: no refusal from the slope
    HOLES = nil
    local nl2 = #logs
    MD.go_to(log, { 4, 0, 0 }, { tolerance_m = 1, nav = false })
    run(60)
    said = false
    for i = nl2 + 1, #logs do if logs[i]:find("(safe fall", 1, true) then said = logs[i] end end
    check("lethal drop: a steep bank that ends on the floor is not refused", not said, said)
    STEEP = nil
    _G.DW_WATER_CH = saved_ch
    HOLES = nil; MD.stop(log); _G.DW_LP_CACHE = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }
end

-- DOOR (his own house on the dev base, 2026-11-01): a room walled on every side, its only way out a shut door. A
-- local plan finds no way; he walks up to the door, aims at it, presses E once (the game's interact key) and walks
-- out when the prompt flips. A door that stays shut fails honestly.
do
    M.stop(log); walls, raised, oracle, frame_hook, air, HOLES, STEEP = {}, {}, nil, nil, 0, nil, nil; pump_oracle()
    luis.loc = { X = 90000, Y = 90000, Z = 0 }
    local leaf = { -20, 0, -60, 60, true }
    walls = { { -20, 320, 150, 170, true }, { -20, 320, -170, -150, true }, { 300, 320, -170, 170, true },
              { -20, 0, -170, -60, true }, { -20, 0, 60, 170, true }, leaf }
    local shut, presses, aims_ok = true, 0, 0
    local door = obj({ HingeInteraction = obj({ InteractionPrompt = { ToString = function() return shut and "Open Door" or "Close Door" end } }),
                       K2_GetActorLocation = function() return { X = -10, Y = 0, Z = 60 } end, BuildingPieceID = 77,
                       GetFName = function() return { ToString = function() return "BP_T1_Door_C_1" end } end })
    -- the door's piece record (GlobalBuildingManager.BuildingPieces): the frame's centre and yaw (a wall along Y)
    TEST_GBM = { BuildingPieces = { ForEach = function(_, fn)
        fn({ get = function() return 76 end }, { get = function() return { ClientVisible = { Location = { X = 400, Y = 400, Z = 0 }, Yaw = 0 } } end })
        fn({ get = function() return 77 end }, { get = function() return { ClientVisible = { Location = { X = -10, Y = 0, Z = 0 }, Yaw = 90 } } end })
    end } }
    TEST_BASE_FIRST = FindFirstOf
    FindFirstOf = function(c) if c == "GlobalBuildingManager" then return TEST_GBM end return TEST_BASE_FIRST(c) end
    _G.DW_DOOR_FRAMES = nil
    local stuck_door = false
    local base_find = FindAllOf
    FindAllOf = function(c) if c == "BP_BaseBuilding_BaseActor_C" then return { door } end return base_find(c) end
    local near = function() return math.sqrt((pawn.loc.X + 10) ^ 2 + pawn.loc.Y ^ 2) < 250 end
    local inv = { interact_target = function() if near() then aims_ok = aims_ok + 1; return { actor = "BP_T1_Door_C_1", prompt = shut and "Open Door" or "Close Door" } end return { none = true } end,
                  press_interact = function() presses = presses + 1
                      if near() and not stuck_door then shut = false
                          for i, w in ipairs(walls) do if w == leaf then table.remove(walls, i) break end end end
                      return { ok = true } end }
    _G.DW_LP_CACHE = nil
    pawn.loc = { X = 150, Y = 0, Z = 0 }
    local MDo = dofile(MOVE)
    MDo.set_inventory(inv)
    local nl = #logs
    MDo.go_to(log, { -8, 0, 0 }, { tolerance_m = 1, nav = false })
    run(600)
    local r = MDo.status().result
    local opened = false
    for i = nl + 1, #logs do if logs[i]:find("opened the door", 1, true) then opened = logs[i] end end
    check("door: shut door opened with one press, then out through it", r and r.status == "arrived" and presses == 1 and opened,
        (r and tostring(r.status) .. " " .. tostring(r.detail) or "nil") .. " presses=" .. presses .. " x=" .. pawn.loc.X .. " " .. tostring(opened))
    MDo.stop(log)
    -- a door that won't open (locked, someone else's): no endless pressing, an honest failure
    shut, presses, stuck_door = true, 0, true
    walls[#walls + 1] = leaf
    _G.DW_LP_CACHE = nil
    pawn.loc = { X = 150, Y = 0, Z = 0 }
    nl = #logs
    MDo.go_to(log, { -8, 0, 0 }, { tolerance_m = 1, nav = false, timeout_s = 40 })
    run(500)
    r = MDo.status().result
    local said = false
    for i = nl + 1, #logs do if logs[i]:find("didn't open", 1, true) then said = logs[i] end end
    check("door: one that stays shut is not pressed forever, and the failure says so", r and r.status == "failed" and presses <= 4 and said,
        (r and tostring(r.status) .. " " .. tostring(r.detail) or "nil") .. " presses=" .. presses .. " " .. tostring(said))
    MDo.stop(log)
    -- INTO the room (build 2026-11-02: a go_to into his covered house): the goal is behind the shut door, so the
    -- wall ahead opens the door first (no plan over the roof first)
    shut, presses, stuck_door = true, 0, false -- (the leaf is still in place: the last door stayed shut)
    _G.DW_LP_CACHE = nil
    pawn.loc = { X = -400, Y = 0, Z = 0 }
    nl = #logs
    local T0 = T
    MDo.go_to(log, { 1.5, 0, 0 }, { tolerance_m = 1, nav = false, timeout_s = 40 })
    local in_t
    for _ = 1, 400 do run(1); if MDo.status().result then in_t = T - T0; break end end
    r = MDo.status().result
    local plan_first, opened_in = false, false
    for i = nl + 1, #logs do
        if logs[i]:find("local plan failed", 1, true) and not opened_in then plan_first = true end
        if logs[i]:find("opened the door", 1, true) then opened_in = logs[i] end
    end
    check("door: into a room behind a shut door, the door is opened first (no failed plan before it)",
        r and r.status == "arrived" and presses == 1 and opened_in and not plan_first and in_t and in_t < 8,
        (r and tostring(r.status) or "nil") .. " presses=" .. presses .. " plan_first=" .. tostring(plan_first) .. " t=" .. tostring(in_t))
    MDo.stop(log)
    -- an OPEN door, from off to the side (live 04:21Z: a 1 m plan grid round the ~1 m doorway circled his house
    -- 2.6 m from the goal for 52 s): he lines up with the frame and walks straight through
    shut = false
    walls = { walls[1], walls[2], walls[3], walls[4], walls[5] } -- the room without the leaf (no new locals here)
    _G.DW_LP_CACHE = nil
    pawn.loc = { X = -350, Y = 380, Z = 0 }
    nl = #logs
    T0 = T
    MDo.go_to(log, { 1.5, 0.3, 0 }, { tolerance_m = 1, nav = false, timeout_s = 40 })
    in_t = nil
    while not MDo.status().result and T - T0 < 20 do run(1) end
    if MDo.status().result then in_t = T - T0 end
    r = MDo.status().result
    opened_in = false -- (reused: the main chunk is at its locals limit) the lining-up line
    opened_in = table.concat(logs, "|", nl + 1):match("[^|]*through the doorway[^|]*") or false
    check("door: an open doorway is walked through from its own frame (lined up, no circling)",
        r and r.status == "arrived" and opened_in and in_t and in_t < 12,
        (r and tostring(r.status) .. " " .. tostring(r.detail) or "nil") .. " t=" .. tostring(in_t) .. " " .. tostring(opened_in))
    MDo.stop(log)
    -- a SWINGING door (live 05:45:51Z, "stayed shut after 2 presses" in 1 s): the hinge state flips at the press,
    -- the prompt only when the swing ends 1.5 s later, and a second press meanwhile shuts it again. One press.
    ;(function()
        local shown, swing_t = "Open Door", nil
        door.Hinge = { HingeState = 2, bIsReady = true }
        door.HingeInteraction = { InteractionPrompt = { ToString = function()
            if swing_t and T - swing_t >= 1.5 then shown = door.Hinge.HingeState == 2 and "Open Door" or "Close Door" end
            return shown end } }
        inv.press_interact = function()
            if not near() then return { ok = true } end
            presses = presses + 1
            if door.Hinge.HingeState == 2 then
                door.Hinge.HingeState = 0
                for i, w in ipairs(walls) do if w == leaf then table.remove(walls, i) break end end
            else door.Hinge.HingeState = 2; walls[#walls + 1] = leaf end
            swing_t = T
            return { ok = true } end
        shut, presses = true, 0
        walls[#walls + 1] = leaf
        _G.DW_LP_CACHE = nil
        pawn.loc = { X = -400, Y = 0, Z = 0 }
        local n0, t0 = #logs, T
        MDo.go_to(log, { 1.5, 0, 0 }, { tolerance_m = 1, nav = false, timeout_s = 40 })
        while not MDo.status().result and T - t0 < 20 do run(1) end
        local rr = MDo.status().result
        local said = table.concat(logs, "|", n0 + 1):match("[^|]*opened the door[^|]*")
        check("door: a swinging door (hinge open, prompt not yet) is pressed once, then walked through",
            rr and rr.status == "arrived" and presses == 1 and said,
            (rr and tostring(rr.status) .. " " .. tostring(rr.detail) or "nil") .. " presses=" .. presses .. " t=" .. (T - t0) .. " " .. tostring(said))
        MDo.stop(log)
        door.Hinge = nil
    end)()
    FindAllOf, FindFirstOf = base_find, TEST_BASE_FIRST; walls = {}; _G.DW_LP_CACHE = nil; pawn.loc = { X = 0, Y = 0, Z = 0 }
end

-- ENCUMBERED (live 2026-11-01 13:2x: 446.5 of 300 weight): no jump attempts (they fail in game), and the honest reason
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; pawn.jumps = 0; luis.loc = { X = 90000, Y = 90000, Z = 0 } -- nobody near to lead
    pawn.PlayerEncumbranceComponent = obj({ IsEncumbered = function() return true end,
        GetCurrentCarryWeight = function() return 446.5 end, GetMaxCarryWeight = function() return 300 end })
    walls = { { 500, 560, -3000, 3000 } } -- an 80 cm fence across the way (a jump would clear it)
    M.go_to(log, { 15, 0, 0 }, { tolerance_m = 1, local_plan = false })
    run(400)
    local s = M.status()
    local why = s.result and (tostring(s.result.reason) .. " " .. tostring(s.result.detail)) or tostring(s.status)
    check("encumbered: no jumps, and the reason says so", pawn.jumps == 0 and why:find("encumbered") ~= nil, "jumps=" .. pawn.jumps .. " " .. why)
    M.stop(log); pawn.PlayerEncumbranceComponent = nil; walls = {}
end

-- ISSUES C2 (147 s silent on a 274 m walk): a long go_to writes a progress line every 20 s (move.jsonl trip_progress)
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false
    os.execute('mkdir "' .. (dir .. "/client_io/events"):gsub("/", "\\") .. '" 2>nul')
    os.remove(dir .. "/client_io/events/move.jsonl")
    pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil; pump_oracle()
    M.go_to(log, { 200, 0, 0 }, { tolerance_m = 2 })
    run(450)
    local f = io.open(dir .. "/client_io/events/move.jsonl")
    local body = f and f:read("a") or ""; if f then f:close() end
    local n = 0
    for line in body:gmatch("[^\n]+") do if line:find('"type":"trip_progress"') then n = n + 1 end end
    check("long go_to: a progress line every 20 s", n >= 1 and body:find("m to go of 200") ~= nil, "lines=" .. n .. " " .. body:sub(1, 200))
    M.stop(log)
end

-- The goal above him at his x,y (coordinator 2026-11-01; live 17:25-17:44Z a build spot 2.1 m over his house floor
-- ran "stuck n=159" for 19 min): a spot hanging in the air over his floor is an arrival right under it, verified;
-- a spot on a floor 6 m up beside him fails at once (goal_above) with that floor's height, after one local plan.
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false; oracle = nil; pump_oracle()
    GEAR = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local t0 = T
    M.go_to(log, { 0.3, 0, 2.1 }, { tolerance_m = 0.8, nav = false })
    run(60)
    local s = M.status()
    local va = M.verify_arrival()
    check("goal hanging over his floor: arrived right under it, verified", s.result and s.result.status == "arrived" and s.result.below == true
        and (s.result.s or 99) < 1.5 and va.ok and va.below == true, s.result and (tostring(s.result.status) .. " " .. tostring(s.result.reason) .. " " .. tostring(s.result.s)))
    M.stop(log)
    -- the same with the route oracle up but slow (live 19:25Z: 17 s standing for its "invalid_route")
    oracle = function() return nil end; pump_oracle()
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 1.0, 0, 2.6 }, { tolerance_m = 1.5 })
    run(60)
    s = M.status()
    check("goal hanging 1 m beside him with a slow oracle: arrived right under it, without waiting for a route",
        s.result and s.result.status == "arrived" and s.result.below == true and (s.result.s or 99) < 1.5,
        s.result and (tostring(s.result.status) .. " " .. tostring(s.result.reason) .. " " .. tostring(s.result.s)) or tostring(s.mode))
    M.stop(log); oracle = nil; pump_oracle()
    raised = { { 100, 900, -400, 400, 600, 600 } }
    pawn.loc = { X = 30, Y = 0, Z = 0 }
    t0 = T
    M.go_to(log, { 1.5, 0, 6.9 }, { tolerance_m = 1.5, nav = false })
    run(300)
    s = M.status()
    check("goal on a floor 6 m up beside him: goal_above at once, with its height", s.result and s.result.status == "failed"
        and s.result.reason == "goal_above" and (s.result.rise_m or 0) > 5.5 and (s.result.s or T - t0) < 8 and tostring(s.result.detail):find("6.0 m above me", 1, true),
        s.result and (tostring(s.result.status) .. " " .. tostring(s.result.reason) .. " " .. tostring(s.result.detail)))
    M.stop(log); raised = {}
end

-- A spot on a ledge (jump course 2026-11-17 18:53:45Z: go_to said "arrived" at the foot of the windmill-hill top
-- ledge, 1.4 m short of (144.00,1706.00,-2.72) with his feet 1.6 m under its floor; the Doric ledge the same at 0.84 m:
-- the arrival allowed 2 x half_h of height inside the circle). A spot to stand on (opts.stand: the brain's [x,y,z])
-- is reached on its floor: he climbs on, or the go_to fails saying the floor is above him. A thing's position (no
-- stand) keeps the old rule (a chest on a table is reached from the floor).
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false; oracle = nil; pump_oracle()
    GEAR = false
    local function go(goal, opts, n)
        M.stop(log); air = 0; pawn.loc = { X = 0, Y = 0, Z = 0 }
        local l0 = #logs
        M.go_to(log, goal, opts)
        run(n)
        local said = nil
        for i = l0 + 1, #logs do if logs[i]:find("move: not arrived:", 1, true) then said = said or logs[i] end end        return M.status().result or {}, said
    end
    raised = { { 100, 900, -400, 400, 84, 84 } } -- a 0.84 m ledge from x = 1 m
    local r, said = go({ 1.3, 0, 0.84 }, { tolerance_m = 1.5, nav = false, stand = true }, 400)
    local va = M.verify_arrival()
    check("spot on a 0.84 m ledge 1.3 m away: he climbs onto it before arrived", r.status == "arrived" and pawn.loc.Z > 60 and va.ok,
        tostring(r.status) .. " " .. tostring(r.reason) .. " z=" .. tostring(pawn.loc.Z))
    check("spot on a ledge: the refused arrival is logged", said ~= nil and said:find("below the goal's floor", 1, true) ~= nil, tostring(said))
    r = go({ 1.3, 0, 0.84 }, { tolerance_m = 1.5, nav = false }, 60)
    check("a thing's position on a ledge (no stand): the old rule, arrived from the foot", r.status == "arrived" and pawn.loc.Z < 20,
        tostring(r.status) .. " z=" .. tostring(pawn.loc.Z))
    raised = { { 100, 900, -400, 400, 170, 170 } } -- 1.7 m: over his jump (no double jump), inside the old 1.76 m
    r = go({ 1.3, 0, 1.7 }, { tolerance_m = 1.5, nav = false, stand = true }, 600)
    check("spot on a 1.7 m ledge he can't jump: not arrived, fails naming the floor above him",
        r.status == "failed" and pawn.loc.Z < 20 and tostring(r.detail or r.why):find("above me", 1, true) ~= nil,
        tostring(r.status) .. " " .. tostring(r.reason) .. " " .. tostring(r.detail or r.why))
    raised = {}
    r = go({ 1.3, 0, -0.9 }, { tolerance_m = 1.5, nav = false, stand = true }, 60)
    check("spot given as a floor point on his own level: arrived", r.status == "arrived", tostring(r.status) .. " " .. tostring(r.reason))
    r = go({ 1.3, 0, 0 }, { tolerance_m = 1.5, nav = false, stand = true }, 60)
    check("spot given as a capsule centre on his own level: arrived", r.status == "arrived", tostring(r.status) .. " " .. tostring(r.reason))
    M.stop(log)
end

-- The camera is shared (coordinator 2026-11-01: the build's ceiling and roof aims read pitch 0 and move's yaw,
-- ~16:30Z): another skill's aim mid-walk is left alone, renewed while it keeps aiming, and he walks on; then move
-- takes the camera back. A go_to that is the aiming skill's own child walk ends, stopped camera_taken.
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false; oracle = nil; pump_oracle()
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local writes = 0
    pc.SetControlRotation = function(self, r) rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = 0 }; writes = writes + 1 end
    pc.GetControlRotation = function() return { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = 0 } end
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 40, 0, 0 }, { tolerance_m = 1, nav = false, local_plan = false })
    run(15)
    local aim_frames = 0
    frame_hook = function()
        aim_frames = aim_frames + 1
        if aim_frames <= 90 then rot = { Pitch = -30, Yaw = 90 + aim_frames * 0.5, Roll = 0 } end -- 3 s (run(n) = 3n frames)
    end
    local w0, x0 = writes, pawn.loc.X
    run(30)
    check("camera: another skill's aim is left alone while he walks on", writes == w0 and pawn.loc.X > x0 + 100 and rot.Pitch == -30,
        (writes - w0) .. " writes, moved " .. (pawn.loc.X - x0))
    run(30)
    check("camera: taken back once the other skill stops aiming", writes > w0 and math.abs(rot.Pitch) < 0.01 and math.abs(rot.Yaw) < 1,
        rot.Pitch .. "," .. rot.Yaw)
    M.stop(log); frame_hook = nil
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))(); A.set_move(M)
    local owner = A.request(log, { name = "test:build", level = "command", uses_move = true, adopt = false })
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local r = M.go_to(log, { 40, 0, 0 }, { tolerance_m = 1, nav = false, local_plan = false, owner_token = owner.token })
    run(10)
    rot = { Pitch = -40, Yaw = 45, Roll = 0 }
    run(3)
    local s = M.status()
    check("camera: the aiming skill's own walk ends (stopped, camera_taken)", r.ok and s.result and s.result.status == "stopped" and s.result.reason == "camera_taken",
        tostring(r.ok) .. " " .. tostring(s.mode) .. " " .. tostring(s.result and s.result.status) .. " " .. tostring(s.result and s.result.reason))
    A.release(log, owner.token, "test")
    pc.SetControlRotation = function() end; pc.GetControlRotation = nil
end

-- the calibrated water channel survives a client restart (same build): a fresh client checks remembered water
-- from his first trip instead of trusting it (live 18:07Z: false church-door cells, "cannot check: no water channel")
do
    os.execute('mkdir "' .. (dir .. "/client_io/state"):gsub("/", "\\") .. '" 2>nul')
    local saved_ch = rawget(_G, "DW_WATER_CH")
    local function seed(build)
        local f = io.open(dir .. "/client_io/state/water_channel.lua", "w")
        f:write(string.format('return { build = %q, name = "cam", ch = 1, ot = nil }\n', build)); f:close()
    end
    seed("26162923"); _G.DW_WATER_CH = nil; dofile(MOVE)
    local c = rawget(_G, "DW_WATER_CH")
    check("water channel: loaded from the last client run", type(c) == "table" and c.name == "cam" and c.ch == 1 and c.stored == true, c and c.name)
    seed("26162923"); _G.DW_WATER_CH = false; dofile(MOVE) -- a shallow wade found no channel this run
    c = rawget(_G, "DW_WATER_CH")
    check("water channel: the stored one holds after a calibration that saw nothing", type(c) == "table" and c.name == "cam", tostring(c))
    seed("11111111"); _G.DW_WATER_CH = nil; dofile(MOVE)
    check("water channel: another build's channel is not trusted", rawget(_G, "DW_WATER_CH") == nil, tostring(rawget(_G, "DW_WATER_CH")))
    os.remove(dir .. "/client_io/state/water_channel.lua")
    _G.DW_WATER_CH = saved_ch
end

-- a remembered water cell over dry floor is forgotten when a water channel is known (the dry answer was read as
-- "cannot check" and no false mark was ever cleared: live 19:26Z, every church-door cell stayed)
do
    local saved_ch = rawget(_G, "DW_WATER_CH")
    _G.DW_WATER_CH = { ch = 0, name = "vis" }
    local cleared = 0
    local NMf = { cfg = { water_cell_cm = 200 }, clear_water = function() cleared = cleared + 1; return true end, save = function() end }
    local st = {}
    local q = { X = pawn.loc.X + 3000, Y = pawn.loc.Y, Z = pawn.loc.Z }
    local fm = M._water_false_mark(st, pawn, { X = q.X, Y = q.Y, Z = FLOOR }, q, {}, NMf, log)
    check("water memory: a dry cell is forgotten once the channel is known", fm == true and cleared == 1, tostring(fm) .. " " .. cleared)
    _G.DW_WATER_CH = saved_ch
end

-- ROOTED by a hold interaction (live 2026-11-01 19:20Z: an Anima Vent's siphon pressed and never let go; every walk
-- "walked 17-20 m" of hops on the spot and "fell 3.2 m (stuck)"): a walk lets go first; if it can't, the failure
-- says what holds him, and the trip reports ground covered, not hops
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    local held, release_ok, releases = true, true, 0
    local inv = { press_interact = function() return { ok = true } end, interact_target = function() return { none = true } end,
        held_interaction = function() return held and { actor = "BP_AnimaVent_C_1", name = "Air Anima Vent", prompt = "Siphon" } or nil end,
        release_held = function() releases = releases + 1; if release_ok then held = false; return { ok = true, released = "Air Anima Vent" } end
            return { ok = false, reason = "no InteractActionStop" } end }
    M.set_inventory(inv)
    local real_add2 = pawn.AddMovementInput
    pawn.AddMovementInput = function(self, d, sc) if held then return end return real_add2(self, d, sc) end
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 6, 0, 0 }, { tolerance_m = 1, nav = false })
    run(150)
    local s = M.status()
    local tr = s.result and s.result.trip or ""
    check("held: a walk lets go of the hold first and walks", s.result and s.result.status == "arrived" and releases == 1
        and tostring(tr):find("let go of the Air Anima Vent", 1, true), tostring(s.result and s.result.status) .. " releases=" .. releases .. " " .. tostring(tr))
    -- the release does not take: rooted, said in words; the trip covers 0 m of ground
    M.stop(log)
    held, release_ok, releases = true, false, 0
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 6, 0, 0 }, { tolerance_m = 1, nav = false })
    run(400)
    s = M.status()
    tr = s.result and s.result.trip or ""
    check("held: a hold he can't let go of fails as rooted, naming it", s.result and s.result.status == "failed" and s.result.reason == "rooted"
        and tostring(s.result.detail):find("Air Anima Vent", 1, true), tostring(s.result and s.result.reason) .. " " .. tostring(s.result and s.result.detail))
    check("held: the trip says he moved 0 m, not his hops", tostring(tr):find("^Moved 0 m") ~= nil and not tostring(tr):find("fell", 1, true), tostring(tr))
    pawn.AddMovementInput = real_add2
    M.set_inventory(nil)
    M.stop(log)
end

-- A FOLLOW (a fight's approach) re-plans after a missed jump landing, like go_to; only the third failed jump of the
-- trip is "no_route" (live 2026-11-01 20:09Z, ClaudeQ4 Ratcatcher: one missed landing on an open slope ended two
-- attacks path_blocked/no_route 20-22 m from a rat standing still, and a go_to then walked there)
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
    M.follow(log, "Zezima", 2, { nav = false })
    run(5)
    local mv = _G.DW_MOVE
    local function miss()
        local here = pawn.loc
        mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X + 300, Y = here.Y, Z = FLOOR, act = "jump" } }
        mv.lwp = 2
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T, saw_air = true }
        air = 0
        step(2)
    end
    miss()
    check("follow: a missed jump landing re-plans, no no_route", mv.mode == "follow" and mv.unreach == nil and mv.trav_fails == 1
        and mv.lp_fail == "jump landing missed", tostring(mv.unreach and mv.unreach.reason) .. " fails=" .. tostring(mv.trav_fails) .. " " .. tostring(mv.lp_fail))
    miss(); miss()
    check("follow: the third failed jump of the trip is no_route", mv.unreach and mv.unreach.reason == "no_route" and mv.trav_fails == 3,
        tostring(mv.unreach and mv.unreach.reason) .. " fails=" .. tostring(mv.trav_fails))
    M.stop(log); luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- A jump onto a ledge has landed when he stands on the ledge: at the endpoint's height and within jump_land_cm of
-- it, not only within a walk point's 45 cm (live 2026-11-16 09:53:58Z, chain 094732 Ratcatcher: the third jump of an
-- approach put him on a 3 m ledge 72 cm from the planned cell, counted as the third miss, and the attack ended
-- path_blocked 7.3 m from a rat he then walked straight to). A jump across a gap on one level keeps the 45 cm.
do
    -- floor: how far under his feet the floor under him lies (nil: he stands on it, a plateau at his feet's height;
    -- false: none but the world's floor); held: his capsule gets nowhere (live: 6 cm in a second)
    local function land(rise, dx, dy, nearest, below, act, second, floor, held)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false; PINCH = nil
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = rise }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        local here = pawn.loc
        if act == "djump" then mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true end
        mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X + 100, Y = here.Y, Z = FLOOR + rise, act = act or "jump" },
                     { X = here.X + 200, Y = here.Y, Z = FLOOR + rise, act = "walk" } }
        mv.lwp = 2
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T, saw_air = true, nearest = nearest, nearest_dz = nearest and 60 or nil,
                            dj2 = second and T + 0.4 or nil }
        mv.trav_fails, mv.lp_fail = nil, nil
        pawn.loc = { X = here.X + 100 + dx, Y = here.Y + dy, Z = here.Z + rise - (below or 0) }
        if floor ~= false then
            local h = rise - (below or 0) - (floor or 0)
            raised = { { pawn.loc.X - 80, pawn.loc.X + 80, pawn.loc.Y - 80, pawn.loc.Y + 80, h, h } }
        end
        if held then PINCH = { { pawn.loc.X - 300, pawn.loc.X + 300, pawn.loc.Y - 300, pawn.loc.Y + 300 } } end
        air = 0
        step(1)
        return mv
    end
    local n0 = #logs
    local mv = land(300, 54, 48)
    local function verdict_line(from)
        for i = from + 1, #logs do if tostring(logs[i]):find("move: jump verdict=", 1, true) then return logs[i] end end
    end
    local vl = verdict_line(n0)
    check("every typed jump writes its landing line: a landed one", vl ~= nil and vl:find("verdict=landed why=within", 1, true) ~= nil
        and vl:find("rise=300", 1, true) ~= nil, tostring(vl))
    check("ledge jump: on the ledge 72 cm from the cell is landed", (mv.trav_fails or 0) == 0 and mv.lp_fail ~= "jump landing missed" and mv.unreach == nil,
        "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(mv.lp_fail))
    n0 = #logs
    mv = land(300, 200, 0)
    vl = verdict_line(n0)
    check("every typed jump writes its landing line: a missed one", vl ~= nil and vl:find("verdict=missed why=far", 1, true) ~= nil
        and vl:find("off=200", 1, true) ~= nil, tostring(vl))
    check("ledge jump: 2 m past the cell is still a miss", mv.trav_fails == 1 and mv.lp_fail == "jump landing missed", "fails=" .. tostring(mv.trav_fails))
    -- over the cell in the air and down on its level past it (jump course 2026-11-17 18:33Z: 10 of 15 misses passed
    -- within 20 cm of the cell and rested 1.4-1.9 m on)
    n0 = #logs
    mv = land(300, 180, 0, 10)
    vl = verdict_line(n0)
    check("ledge jump: over the cell in the air and down on its level 1.8 m past it is landed", (mv.trav_fails or 0) == 0
        and vl ~= nil and vl:find("verdict=landed why=over", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    -- over the cell but back down most of the way (jump course 2026-11-17 18:55Z, the Doric ledge: a 78 cm rise, down
    -- 55 cm under its level 1.6 m on, inside the 65 cm step slack, was counted landed)
    mv = land(100, 180, 0, 10, 55)
    check("ledge jump: over the cell but down 55 cm under a 1 m rise's level stays a miss", mv.trav_fails == 1,
        "fails=" .. tostring(mv.trav_fails))
    -- near the cell and above its level, on the slope up from it (the Doric ledge, 18:53:59Z: 44 cm from the cell and
    -- 93 cm over it, at the goal's own height, judged missed six times a window)
    n0 = #logs
    mv = land(300, 40, 0, nil, -93)
    vl = verdict_line(n0)
    check("ledge jump: 40 cm from the cell and 93 cm above its level is landed", (mv.trav_fails or 0) == 0
        and vl ~= nil and vl:find("verdict=landed why=above", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    mv = land(300, 40, 0, nil, -200)
    check("ledge jump: 2 m above the cell's level stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    mv = land(300, 180, 0, 140)
    check("ledge jump: never over the cell and 1.8 m past it stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    mv = land(0, 180, 0, 10)
    check("gap jump on one level: over the cell and 1.8 m past it stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    mv = land(0, 54, 48)
    check("gap jump on one level: 72 cm from the cell stays a miss", mv.trav_fails == 1 and mv.lp_fail == "jump landing missed", "fails=" .. tostring(mv.trav_fails))
    -- a rise over the walkable step (45 cm) but under the step slack (65) is a level change (the pond bank by home,
    -- window 2026-11-19 00:15-00:26Z: 61-63 cm hops that came down on the top past the cell, going on forward, were
    -- judged on 45 cm and missed 7 times, then re-planned). Real rows: bank T1 off 99 feet_dz 1, T5 off 186 nearest 107
    -- feet_dz 12, top off 180 nearest 70 feet_dz 42
    n0 = #logs
    mv = land(61, 99, 0, 58, -1)
    vl = verdict_line(n0)
    check("61 cm hop: on the top 99 cm past the cell is landed and he goes on forward", (mv.trav_fails or 0) == 0 and mv.lwp == 3
        and vl ~= nil and vl:find("verdict=landed why=within", 1, true) ~= nil and vl:find("rise=61", 1, true) ~= nil,
        "fails=" .. tostring(mv.trav_fails) .. " lwp=" .. tostring(mv.lwp) .. " " .. tostring(vl))
    n0 = #logs
    mv = land(63, 186, 0, 107, -12)
    vl = verdict_line(n0)
    check("63 cm hop: over the cell and down on the top 1.9 m on is landed (over)", (mv.trav_fails or 0) == 0 and mv.lwp == 3
        and vl ~= nil and vl:find("verdict=landed why=over", 1, true) ~= nil and vl:find("rise=63", 1, true) ~= nil,
        "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    n0 = #logs
    mv = land(61, 180, 0, 70, -42)
    vl = verdict_line(n0)
    check("61 cm hop: down 42 cm over the top 1.8 m on is landed (over)", (mv.trav_fails or 0) == 0
        and vl ~= nil and vl:find("verdict=landed why=over", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    -- the goalposts stay: back at the foot (feet at the takeoff's level, 61 cm under the top, inside the 65 cm slack)
    -- near the cell, or under it, is a miss; so is a fall off the far side, to the takeoff's level or below it
    mv = land(61, -60, 0, 50, 61)
    check("61 cm hop: back at the foot 60 cm short of the cell stays a miss", mv.trav_fails == 1 and mv.lp_fail == "jump landing missed",
        "fails=" .. tostring(mv.trav_fails))
    mv = land(61, -20, 0, 15, 58)
    check("61 cm hop: at the foot under the lip, 20 cm from the cell, 3 cm over the takeoff's level stays a miss", mv.trav_fails == 1,
        "fails=" .. tostring(mv.trav_fails))
    mv = land(61, 40, 0, 10, -30)
    check("61 cm hop: 40 cm from the cell, 30 cm up the slope over the top is landed", (mv.trav_fails or 0) == 0,
        "fails=" .. tostring(mv.trav_fails))
    mv = land(61, 180, 0, 20, 61)
    check("61 cm hop: over the cell and off the far side to the takeoff's level stays a miss", mv.trav_fails == 1,
        "fails=" .. tostring(mv.trav_fails))
    mv = land(61, 180, 0, 20, 101)
    check("61 cm hop: over the cell and off the far side 40 cm under the takeoff stays a miss", mv.trav_fails == 1,
        "fails=" .. tostring(mv.trav_fails))
    mv = land(61, 99, 0, 58, 40)
    check("61 cm hop: 99 cm past the cell but 40 cm under the top (nearer the foot) stays a miss", mv.trav_fails == 1,
        "fails=" .. tostring(mv.trav_fails))
    -- a hop under the walkable step keeps a walk point's 45 cm
    mv = land(40, 99, 0, 58, -1)
    check("40 cm hop (under the step): 99 cm past the cell stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    -- landed means standing on the top: two 3 m double jumps onto the rock east of home were judged landed by height
    -- alone and he was back at the takeoff's level (scratchpad study jump_real_1119; logs/client/client.log).
    -- 01:06:19Z: feet 2 cm under the top, 64 cm from the cell (-41,-49), the floor under him 46 cm down, 6 cm moved in
    -- the next second (he stayed on his capsule's rim)
    local function verdicts(from) local o = {}; for i = from + 1, #logs do
        if tostring(logs[i]):find("move: jump verdict=", 1, true) then o[#o + 1] = logs[i] end end; return o end
    n0 = #logs
    mv = land(300, -41, -49, 70, 2, "djump", true, 46, true)
    local first = verdicts(n0)
    local pushed = pawn.input ~= nil
    local said_settle = false
    for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump: down but not standing (floor 46 cm under my feet)", 1, true) then said_settle = true end end
    step(20); PINCH = nil
    vl = verdicts(n0)[1]
    check("rock 01:06:19Z: on the top's height with the floor 46 cm under his feet is not judged at once; he pushes on",
        #first == 0 and pushed and said_settle, "verdicts=" .. #first .. " pushed=" .. tostring(pushed) .. " said=" .. tostring(said_settle))
    check("rock 01:06:19Z: still not standing after jump_settle_s is a miss (why=perched)", mv.trav_fails == 1
        and vl ~= nil and vl:find("verdict=missed why=perched", 1, true) ~= nil and vl:find("settle=0.5", 1, true) ~= nil,
        "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    -- 02:12:14Z: "landed" 71 cm from the cell (-4,-71), feet 53 cm under the top, the floor 247 cm under them; he
    -- came down at the takeoff's level
    n0 = #logs
    mv = land(298, -4, -71, 71, 53, "djump", true, 247)
    first = verdicts(n0)
    step(20)
    vl = verdicts(n0)[1]
    check("rock 02:12:14Z: feet 53 cm under the top with the floor 247 cm under them is not landed", #first == 0
        and mv.trav_fails == 1 and vl ~= nil and vl:find("verdict=missed", 1, true) ~= nil,
        "verdicts=" .. #first .. " fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    -- down on the lip with the floor under his centre 60 cm lower, he steps in onto the top: landed once he stands
    n0 = #logs
    mv = land(150, -30, 0, 30, 0, "jump", nil, 60)
    first = verdicts(n0)
    local cx = pawn.loc.X + 30
    raised = { { cx - 25, cx + 200, -80, 80, 150, 150 } }
    frame_hook = function() pawn.loc.X = cx - 5 end
    step(3); frame_hook = nil
    vl = verdicts(n0)[1]
    check("lip: down on the rim, then standing on the top a frame later, is landed", #first == 0 and (mv.trav_fails or 0) == 0
        and vl ~= nil and vl:find("verdict=landed why=within", 1, true) ~= nil and vl:find("settle=0.0", 1, true) ~= nil,
        "verdicts=" .. #first .. " fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    -- a landing standing on the floor at once is judged in that frame, settle=-
    n0 = #logs
    land(300, 54, 48)
    vl = verdicts(n0)[1]
    check("a landing standing at once is judged in that frame (settle=-)", vl ~= nil and vl:find("verdict=landed why=within", 1, true) ~= nil
        and vl:find("settle=-", 1, true) ~= nil, tostring(vl))
    -- the landing line says whether a double jump's second press fired, and when (double-jumps study 2026-11-17: three
    -- flights cut to 31-185 cm could not tell "never pressed" from "pressed and the face ate it")
    n0 = #logs
    land(300, 200, 0, nil, nil, "djump", true)
    vl = verdict_line(n0)
    check("landing line: a double jump whose second press fired says second=yes", vl ~= nil and vl:find("act=djump", 1, true) ~= nil
        and vl:find("second=yes dj2=0.40", 1, true) ~= nil, tostring(vl))
    n0 = #logs
    land(300, 200, 0, nil, nil, "djump", false)
    vl = verdict_line(n0)
    check("landing line: a double jump with no second press says second=no", vl ~= nil and vl:find("second=no dj2=-", 1, true) ~= nil, tostring(vl))
    n0 = #logs
    land(300, 200, 0)
    vl = verdict_line(n0)
    check("landing line: a single jump says second=-", vl ~= nil and vl:find("second=- dj2=-", 1, true) ~= nil, tostring(vl))
    M.stop(log); luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- A flight cut short: back on the takeoff's level sooner than gravity allows is not a judged landing; he presses
-- again from there, once per edge and trip (M.flight_cut). Real rows, logs/client/client.log 2026-11-19 (rise, top
-- seen over the takeoff, where he stood after it, s from the press; rounded): 10:46:41Z djump 294, ~110 cm up, +2,
-- 0.36 s (free flight needs 0.50 s); 10:47:08Z jump 161, ~50 cm up, +2, 0.10 s (0.30). 09:24:20Z djump 267, ~57 cm
-- up, -15, 0.41 s is within free flight under a ceiling (0.36 s): a real obstruction, a miss as before.
do
    local function cut(rise, act, up, back, air_s, busy)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false; PINCH = nil
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = rise }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        if act == "djump" then mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true end
        mv.lpath = { { X = 0, Y = 0, Z = FLOOR, act = "walk" }, { X = 100, Y = 0, Z = FLOOR + rise, act = act },
                     { X = 200, Y = 0, Z = FLOOR + rise, act = "walk" } }
        mv.lwp = 2; mv.lp_cut_hold = nil
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T - air_s, saw_air = true, takeoff = { X = 0, Y = 0, Z = 0 }, apex = up,
                            last_air_t = T - air_s + 0.17, last_air_z = up }
        -- the first press's bookkeeping still running (jump_tick clears jump_t 1.2 s after it)
        if busy then mv.jump_t, mv.jump_release, mv.jump_double = T - air_s, false, act == "djump" end
        mv.trav_fails, mv.lp_fail = nil, nil
        pawn.loc = { X = 0, Y = 0, Z = back }
        air = 0
        step(1)
        return mv
    end
    local function lines(from, pat) local o = {}; for i = from + 1, #logs do
        if tostring(logs[i]):find(pat, 1, true) then o[#o + 1] = logs[i] end end; return o end
    local n0 = #logs
    local jumps0 = pawn.jumps
    local mv = cut(294, "djump", 112, 2, 0.36, true)
    local vl = lines(n0, "move: jump verdict=")[1]
    local said = lines(n0, "move: jump flight cut short")[1]
    check("cut 10:46:41Z: back at the takeoff 0.36 s after the press from 112 cm up is no missed landing",
        (mv.trav_fails or 0) == 0 and mv.lp_fail == nil and mv.lwp == 2 and mv.lp_jump_exec == nil
        and vl ~= nil and vl:find("verdict=cut why=snapped", 1, true) ~= nil and said ~= nil and said:find("free flight needs 0.5", 1, true) ~= nil,
        "fails=" .. tostring(mv.trav_fails) .. " lwp=" .. tostring(mv.lwp) .. " " .. tostring(vl) .. " | " .. tostring(said))
    local pushed = false
    for _ = 1, 20 do step(1); if pawn.input then pushed = true end end -- 0.67 s: the first press's 1.2 s still runs
    check("cut: he stands with no stick while the first press's bookkeeping runs", not pushed and pawn.jumps == jumps0, "pushed=" .. tostring(pushed))
    step(15)
    check("cut: then he presses again from the takeoff, toward the same edge", pawn.jumps == jumps0 + 1 and mv.lp_jump_exec ~= nil
        and mv.lp_jump_exec.index == 2 and mv.lp_jump_exec.previous == mv.lpath[1], "jumps=" .. tostring(pawn.jumps - jumps0))
    -- the same edge cut a second time in the trip: a miss, as before (re-planned without it)
    mv = cut(294, "djump", 112, 2, 0.36)
    local key_edges = mv.jump_cut
    if mv.lpath then -- (the old mover dropped the path at the first cut)
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T - 0.36, saw_air = true, takeoff = { X = 0, Y = 0, Z = 0 }, apex = 112 }
        mv.jump_t, mv.jump_release, mv.jump_double = nil, false, false
        pawn.loc = { X = 0, Y = 0, Z = 2 }; air = 0
        step(1)
    end
    check("cut: the same edge cut again in the trip is a missed landing", key_edges ~= nil and mv.trav_fails == 1 and mv.lp_fail == "jump landing missed",
        "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(mv.lp_fail) .. " lwp=" .. tostring(mv.lwp) .. " exec=" .. tostring(mv.lp_jump_exec)
        .. " status=" .. tostring(mv.status) .. " " .. tostring(logs[#logs]))
    n0 = #logs
    mv = cut(161, "jump", 49, 2, 0.10)
    vl = lines(n0, "move: jump verdict=")[1]
    check("cut 10:47:08Z: a single jump back at the takeoff 0.10 s after the press from 49 cm up is cut", (mv.trav_fails or 0) == 0
        and vl ~= nil and vl:find("verdict=cut", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    n0 = #logs
    mv = cut(267, "djump", 58, -15, 0.41)
    vl = lines(n0, "move: jump verdict=")[1]
    check("09:24:20Z: 58 cm up and back in 0.41 s fits free flight under a ceiling: a miss", mv.trav_fails == 1
        and vl ~= nil and vl:find("verdict=missed", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    n0 = #logs
    mv = cut(294, "djump", 112, 2, 0.60)
    check("a flight back at the takeoff after 0.60 s (free flight could) stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    M.stop(log); luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- The jump verdict line carries his frames from the run-up to the verdict: the longest frame, frames over 250 ms, on
-- a cut the dt of the frame he came back in, and ms / cm over the takeoff per frame from the press on (snap study
-- 2026-11-19, scratchpad jump_snapback: cuts at 3-9 frames/s 10 of 22, at 9-30 1 of 241; the server's
-- MAXCLIENTUPDATEINTERVAL is 0.25 s, and per-frame dt was never logged). The tick's own dt and location: no new call.
local function typed_flight(act, rise, dts, zs)
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false; PINCH = nil
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = rise }
    M.follow(log, "Zezima", 2, { nav = false })
    run(5)
    local mv = _G.DW_MOVE
    local here = { X = pawn.loc.X, Y = pawn.loc.Y, Z = pawn.loc.Z }
    if act == "djump" then mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true end
    mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X, Y = here.Y + 150, Z = FLOOR + rise, act = act },
                 { X = here.X, Y = here.Y + 250, Z = FLOOR + rise, act = "walk" } }
    mv.lwp = 2; mv.lp_jump_exec = nil; mv.lp_jumped = {}; mv.lp_runup = nil; mv.lp_cut_hold = nil
    mv.trav_fails, mv.lp_fail = nil, nil
    mv.win_t, mv.win_pos = T, { X = here.X, Y = here.Y, Z = here.Z }
    local j0, n0 = pawn.jumps, #logs
    local k = 0
    while pawn.jumps == j0 and k < 60 do step(1); k = k + 1 end
    local pressed_after = k
    for i, d in ipairs(dts or {}) do
        DT = d
        frame_hook = function() pawn.loc.Z = here.Z + zs[i]; air = zs[i] > 3 and 1 or 0 end
        step(1)
    end
    DT, frame_hook = 1 / 30, nil
    local vl
    for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump verdict=", 1, true) then vl = logs[i] end end
    return mv, vl, pressed_after, n0
end
do
    -- a cut as at 10:43:20Z (djump, ~100 cm up, back at the takeoff at 0.37 s): two short frames up, one of 300 ms down
    local mv, vl = typed_flight("djump", 294, { 1 / 30, 1 / 30, 0.30 }, { 60, 100, 2 })
    check("verdict line: a cut flight shows its long frame (max_dt, over250, cut_dt) and the frames from the press",
        vl ~= nil and vl:find("verdict=cut", 1, true) ~= nil and vl:find("max_dt=0.300 over250=1 frames=4 cut_dt=0.300 fdt=33,33,33,300 fz=0,60,100,2", 1, true) ~= nil,
        tostring(vl))
    check("verdict line: the frame trace ends at the verdict", mv.jtrace == nil, tostring(mv.jtrace))
    -- a flight at 30 frames/s, back on the takeoff's level after 0.6 s (free flight could): missed, no long frame
    local dts, zs = {}, {}
    for i = 1, 18 do dts[i] = 1 / 30; zs[i] = i < 18 and math.min(100, 20 * i) or 2 end
    mv, vl = typed_flight("djump", 294, dts, zs)
    check("verdict line: a flight at 30 frames/s says max_dt=0.033 over250=0 and no cut_dt",
        vl ~= nil and vl:find("verdict=missed", 1, true) ~= nil and vl:find("max_dt=0.033 over250=0 frames=19 cut_dt=- fdt=33,33,", 1, true) ~= nil,
        tostring(vl))
    -- a verdict with no frames recorded (the line written directly) says "-"
    local n0 = #logs
    local mv2 = _G.DW_MOVE
    mv2.jtrace = nil
    M.jump_landing_line(mv2, pawn, pawn:K2_GetActorLocation(), { X = 0, Y = 0, Z = 0, act = "jump" }, { previous = { X = 0, Y = 0, Z = 0 }, started = T },
        "missed", "far", T, log)
    check("verdict line: no frames recorded says max_dt=- over250=- cut_dt=-", tostring(logs[#logs]):find("max_dt=- over250=- frames=- cut_dt=- fdt=- fz=-", 1, true) ~= nil
        and #logs == n0 + 1, tostring(logs[#logs]))
    M.stop(log); luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- A hop over a one-cell top, down at the path's NEXT point on its level, has landed (the ford east of home,
-- 2026-11-18 04:48-09:05Z: from a 270 cm/s wade he passed 3-17 cm over a 22-54 cm lip's cell and came down 8-57 cm
-- from the following point at its floor; the rise is under the step slack, so only 45 cm of the cell was allowed and
-- all five were judged missed). Real rows from logs/client/client.log (cm, floor heights; `nx` from the local path
-- line before each jump). Real misses of the same day stay misses.
do
    local function hop(from, to, nx, at, feet, nearest)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        local here = pawn.loc
        local function q(r, act) return { X = here.X + r[1] - from[1], Y = here.Y + r[2] - from[2], Z = FLOOR + r[3] - from[3], act = act } end
        local after = { 2 * nx[1] - to[1], 2 * nx[2] - to[2], nx[3] }
        mv.lpath = { q(from, "walk"), q(to, "jump"), q(nx, "drop"), q(after, "walk") }
        mv.lwp = 2
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T, saw_air = true, nearest = nearest, nearest_dz = 140 }
        mv.trav_fails, mv.lp_fail = nil, nil
        pawn.loc = { X = here.X + at[1] - from[1], Y = here.Y + at[2] - from[2], Z = here.Z + feet - from[3] }
        local n0 = #logs
        air = 0
        step(1)
        local vl
        for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump verdict=", 1, true) then vl = logs[i] end end
        return mv, vl
    end
    local ford_a, ford_b, ford_n = { 12500, 189100, -3257 }, { 12600, 189200, -3211 }, { 12700, 189300, -3280 }
    local rows = {
        { "04:48:39Z", ford_a, ford_b, ford_n, { 12739, 189342 }, -3274, 17 },
        { "07:16:03Z", ford_a, ford_b, ford_n, { 12707, 189307 }, -3274, 3 },
        { "07:19:31Z", ford_a, ford_b, ford_n, { 12739, 189331 }, -3274, 7 },
        { "09:01:14Z", { 13000, 189100, -3275 }, { 13100, 189200, -3253 }, { 13200, 189300, -3280 }, { 13203, 189307 }, -3273, 10 },
        { "09:05:26Z", ford_a, ford_b, ford_n, { 12708, 189308 }, -3274, 4 },
    }
    for _, r in ipairs(rows) do
        local mv, vl = hop(r[2], r[3], r[4], r[5], r[6], r[7])
        check("ford hop " .. r[1] .. ": over the bump's cell and down at the next point is landed", (mv.trav_fails or 0) == 0
            and vl ~= nil and vl:find("verdict=landed why=next", 1, true) ~= nil, "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
        check("ford hop " .. r[1] .. ": the plan goes on past the top and the next point", mv.lpath ~= nil and mv.lwp == 4,
            "lwp=" .. tostring(mv.lwp))
    end
    -- the day's real misses stay misses: a 1.25 m rock passed 56 cm off (03:49:20Z, he never got up), a hump cleared
    -- sideways and down 1.9 m from the next point (04:40:06Z), a 1.4 m rock from the water, 100 cm off (04:52:34Z)
    local misses = {
        { "03:49:20Z", { 11100, 185200, -3222 }, { 11000, 185100, -3097 }, { 11000, 185000, -3180 }, { 10888, 184949 }, -3217, 56 },
        { "04:40:06Z", { 15700, 191600, -3216 }, { 15600, 191500, -3161 }, { 15700, 191400, -3200 }, { 15511, 191470 }, -3223, 53 },
        { "04:52:34Z", { 32300, 178600, -4350 }, { 32400, 178700, -4210 }, { 32500, 178800, -4330 }, { 32486, 178653 }, -4348, 100 },
    }
    for _, r in ipairs(misses) do
        local mv, vl = hop(r[2], r[3], r[4], r[5], r[6], r[7])
        check("real miss " .. r[1] .. " stays a miss", mv.trav_fails == 1 and vl ~= nil and vl:find("verdict=missed", 1, true) ~= nil,
            "fails=" .. tostring(mv.trav_fails) .. " " .. tostring(vl))
    end
    -- over the cell and down near a next point on the jump's own level (no top): a gap stays judged at its point
    local mv = hop({ 0, 0, 0 }, { 100, 0, 0 }, { 200, 0, 0 }, { 230, 0 }, 0, 10)
    check("gap jump: over the cell and down near a next point on one level stays a miss", mv.trav_fails == 1, "fails=" .. tostring(mv.trav_fails))
    M.stop(log); luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- The point a jump starts from lay against the foot of the ledge, nearer to it than his capsule could stand (live
-- 2026-11-17 07:36:02Z, run 073510 Ratcatcher: on the ground 51 cm from that point he pushed at it for 8 s and moved 0
-- to 3 cm; the re-plans gave the same path, and the attack ended path_blocked 7 m from the rat). He takes off from
-- where he stands once he gets no nearer; further off than a cell he does not.
do
    local function blocked(off)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        local here = pawn.loc
        PINCH = { { here.X + 1, here.X + 400, here.Y - 400, here.Y + 400 } } -- his capsule gets no further along +X
        mv.lpath = { { X = here.X + off, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X + off + 100, Y = here.Y, Z = FLOOR, act = "jump" } }
        mv.lwp = 2; mv.lp_jump_exec = nil; mv.lp_jumped = {}
        mv.trav_fails, mv.lp_fail = nil, nil
        mv.win_t, mv.win_pos = T, { X = here.X, Y = here.Y, Z = here.Z }
        local j0 = pawn.jumps
        step(27) -- 0.9 s: before the first stuck window ends
        PINCH = nil
        return mv, pawn.jumps - j0
    end
    local mv, jumps = blocked(52)
    check("takeoff: stopped 52 cm short of the jump's start, he takes off from where he stands", jumps == 1 and mv.lp_jumped[2] ~= nil
        and (mv.stuck_n or 0) == 0, "jumps=" .. jumps .. " stuck_n=" .. tostring(mv.stuck_n) .. " lp_fail=" .. tostring(mv.lp_fail))
    mv, jumps = blocked(120)
    check("takeoff: stopped 120 cm short of it, he does not jump from there", jumps == 0, "jumps=" .. jumps)
    M.stop(log); air = 0; luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- His run-up at a jump's takeoff points at the landing (jump course 2026-11-17 18:2xZ: 10 of 16 missed landings took
-- off at 450 cm/s at right angles to the landing, still running along the leg before it, and came down 1.3 m short or
-- back on the lower level). Fast and sideways, he steers at the landing first and presses once his run-up turns; still
-- sideways after run_up_wait_s, he jumps anyway and says so; slow or straight, he jumps at once.
do
    local cm = pawn.CharacterMovement
    local function runup(vel, frames, rise, leap, act)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        local here = pawn.loc
        if act == "djump" then mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true end
        mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" },
            { X = here.X, Y = here.Y + 150, Z = FLOOR + (rise or 0), act = act or "jump", leap = leap } }
        mv.lwp = 2; mv.lp_jump_exec = nil; mv.lp_jumped = {}; mv.lp_runup = nil
        mv.trav_fails, mv.lp_fail = nil, nil
        mv.win_t, mv.win_pos = T, { X = here.X, Y = here.Y, Z = here.Z }
        local j0, n0 = pawn.jumps, #logs
        local inputs, real_add = 0, pawn.AddMovementInput
        pawn.AddMovementInput = function(self, d, sc) if pawn.jumps == j0 then inputs = inputs + 1 end return real_add(self, d, sc) end
        frame_hook = function() cm.Velocity = type(vel) == "function" and vel() or vel end
        step(frames)
        frame_hook = nil
        pawn.AddMovementInput = real_add
        local said = {}
        for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump run-up", 1, true) then said[#said + 1] = logs[i] end end
        return pawn.jumps - j0, said, inputs
    end
    local jumps, said = runup({ X = 450, Y = 0, Z = 0 }, 1)
    check("run-up: fast and sideways at the takeoff, he does not press yet", jumps == 0 and said[1] ~= nil
        and said[1]:find("turning to the landing", 1, true) ~= nil, "jumps=" .. jumps .. " " .. tostring(said[1]))
    local f = 0
    jumps, said = runup(function() f = f + 1; return f < 4 and { X = 450, Y = 0, Z = 0 } or { X = 40, Y = 450, Z = 0 } end, 6)
    check("run-up: once it turns toward the landing, he jumps", jumps == 1, "jumps=" .. jumps)
    jumps, said = runup({ X = 450, Y = 0, Z = 0 }, 30)
    check("run-up: still sideways after the wait, he jumps anyway and says so", jumps == 1
        and tostring(said[#said]):find("jumping anyway", 1, true) ~= nil, "jumps=" .. jumps .. " " .. tostring(said[#said]))
    jumps, said = runup({ X = 100, Y = 0, Z = 0 }, 1)
    check("run-up: slow at the takeoff, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    jumps, said = runup({ X = 0, Y = 450, Z = 0 }, 1)
    check("run-up: fast and straight at the landing, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    -- a jump up onto another level is pressed from a near standstill (jump-misses-left study 2026-11-17: pressed under
    -- 100 cm/s 0 of 40 missed, faster 28 of 69): fast, he faces the landing with no move input until he is slow, at
    -- most run_up_wait_s; a gap jump on one level and a leap keep their running jump
    local inputs
    jumps, said, inputs = runup({ X = 0, Y = 450, Z = 0 }, 3, 150)
    check("run-up: fast and straight at a jump up, he brakes and does not press yet", jumps == 0 and inputs == 0 and said[1] ~= nil
        and said[1]:find("slowing for a jump up", 1, true) ~= nil, "jumps=" .. jumps .. " inputs=" .. inputs .. " " .. tostring(said[1]))
    f = 0
    jumps, said = runup(function() f = f + 1; return f < 6 and { X = 0, Y = 450, Z = 0 } or { X = 0, Y = 60, Z = 0 } end, 10, 150)
    check("run-up: at a jump up, he presses once he is slow", jumps == 1 and #said == 1, "jumps=" .. jumps .. " said=" .. #said)
    jumps, said = runup({ X = 0, Y = 450, Z = 0 }, 30, 150)
    check("run-up: still fast at a jump up after the wait, he jumps anyway and says so", jumps == 1
        and tostring(said[#said]):find("jumping anyway", 1, true) ~= nil, "jumps=" .. jumps .. " " .. tostring(said[#said]))
    jumps, said = runup({ X = 0, Y = 60, Z = 0 }, 1, 150)
    check("run-up: slow at a jump up, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    jumps, said = runup({ X = 0, Y = 450, Z = 0 }, 1, 0)
    check("run-up: fast at a gap jump on one level, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    jumps, said = runup({ X = 0, Y = 450, Z = 0 }, 1, 150, true)
    check("run-up: fast at a leap up, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    -- ... and a double jump up brakes like a jump up (double-jumps study 2026-11-17: djumps of 2.4 m or more pressed
    -- at 300 cm/s or more landed 2 of 6, three with the rise cut to 31-185 cm by the face; under 150 cm/s 8 of 10)
    jumps, said, inputs = runup({ X = 0, Y = 450, Z = 0 }, 3, 280, nil, "djump")
    check("run-up: fast and straight at a double jump up, he brakes and does not press yet", jumps == 0 and inputs == 0 and said[1] ~= nil
        and said[1]:find("slowing for a jump up", 1, true) ~= nil, "jumps=" .. jumps .. " inputs=" .. inputs .. " " .. tostring(said[1]))
    f = 0
    jumps, said = runup(function() f = f + 1; return f < 6 and { X = 0, Y = 450, Z = 0 } or { X = 0, Y = 60, Z = 0 } end, 10, 280, nil, "djump")
    check("run-up: at a double jump up, he presses once he is slow", jumps == 1 and #said == 1, "jumps=" .. jumps .. " said=" .. #said)
    jumps, said = runup({ X = 0, Y = 450, Z = 0 }, 1, 0, nil, "djump")
    check("run-up: fast at a double jump on one level, he jumps at once", jumps == 1 and #said == 0, "jumps=" .. jumps)
    cm.Velocity = nil
    M.stop(log); air = 0; luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- The jump landing line shows his ground speed at the second press and at his nearest pass over the cell, whether he
-- pushed the stick at the first press, the second press and that pass, and his airborne frames with input; the first
-- typed jump of a load logs the movement values that govern the flight once (djump-drift study 2026-11-18: on a
-- one-cell rock top every standstill double jump drifted 2.6 m and came down 1.25-1.5 m past the cell; air input or
-- the game's directional double jump?).
do
    local cm = pawn.CharacterMovement
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
    M.follow(log, "Zezima", 2, { nav = false })
    run(5)
    local mv = _G.DW_MOVE
    local here = pawn.loc
    mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true
    mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X, Y = here.Y + 130, Z = FLOOR + 230, act = "djump" } }
    mv.lwp = 2; mv.lp_jump_exec = nil; mv.lp_jumped = {}; mv.lp_runup = nil
    M.jump_phys = nil
    cm.AirControl, cm.BrakingDecelerationFalling, cm.JumpZVelocity, cm.MinimumAccelerationForDirectionalDoubleJumpAndDash = 0.35, 0, 807.9, 1500
    local n0 = #logs
    local vy = 40
    frame_hook = function() cm.Velocity = { X = 0, Y = vy, Z = 0 }; vy = math.min(250, vy + 20) end
    step(14) -- past the second press (0.33 s)
    frame_hook = nil
    local j = mv.lp_jump_exec
    local phys
    for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump physics ", 1, true) then phys = (phys and phys .. "|" or "") .. logs[i] end end
    check("jump physics: logged once at the first typed jump, by property", phys ~= nil and not phys:find("|", 1, true)
        and phys:find("AirControl=0.35 ", 1, true) ~= nil and phys:find("JumpZVelocity=807.9 ", 1, true) ~= nil
        and phys:find("BrakingDecelerationFalling=0 ", 1, true) ~= nil
        and phys:find("MinimumAccelerationForDirectionalDoubleJumpAndDash=1500 ", 1, true) ~= nil
        and phys:find("FallingLateralFriction=- ", 1, true) ~= nil, tostring(phys))
    check("jump air: the second press keeps his speed and whether he pushed the stick", j ~= nil and j.dj2 ~= nil
        and type(j.vh2) == "number" and j.vh2 > 40 and j.in2 ~= nil and j.in0 ~= nil and (j.air_n or 0) > 0 and j.vhn ~= nil,
        j and ("vh2=" .. tostring(j.vh2) .. " in2=" .. tostring(j.in2) .. " air_n=" .. tostring(j.air_n)) or "no jump")
    local lines = {}
    local function cap(m) lines[#lines + 1] = m end
    M.jump_landing_line(mv, pawn, pawn:K2_GetActorLocation(), mv.lpath[2], { previous = mv.lpath[1], started = T - 1,
        dj2 = T - 0.6, vh2 = 212.4, vhn = 251, in0 = false, in2 = true, inn = true, air_n = 40, air_in = 38 }, "missed", "far", T, cap)
    check("landing line: vh2, vhn, in= first/second/nearest and airin", lines[1] ~= nil
        and lines[1]:find("second=yes dj2=0.40 vh2=212 vhn=251 in=0/1/1 airin=38/40", 1, true) ~= nil, tostring(lines[1]))
    lines = {}
    M.jump_landing_line(mv, pawn, pawn:K2_GetActorLocation(), mv.lpath[2], { previous = mv.lpath[1], started = T }, "missed", "far", T, cap)
    check("landing line: none of it known reads as dashes", lines[1] ~= nil and lines[1]:find("vh2=- vhn=- in=-/-/- airin=-", 1, true) ~= nil,
        tostring(lines[1]))
    -- a second typed jump in the same load does not log the values again
    n0 = #logs
    M.jump_physics_line(pawn, log)
    local again = false
    for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump physics ", 1, true) then again = true end end
    check("jump physics: not logged again in the same load", not again, "")
    lines = {}
    M.jump_landing_line(mv, pawn, pawn:K2_GetActorLocation(), mv.lpath[2], { previous = mv.lpath[1], started = T - 1, let_go = T - 0.75 },
        "missed", "far", T, cap)
    check("landing line: letgo= says when he let go of the stick", lines[1] ~= nil and lines[1]:find("letgo=0.25", 1, true) ~= nil, tostring(lines[1]))
    cm.Velocity, cm.AirControl, cm.BrakingDecelerationFalling, cm.JumpZVelocity = nil, nil, nil, nil
    cm.MinimumAccelerationForDirectionalDoubleJumpAndDash = nil
    M.stop(log); air = 0; luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- In the air on a typed jump he lets go of the stick once the drift still to come (his speed toward the landing over
-- the time left to fall to its level) covers the distance left (djump-drift study 2026-11-18: on a one-cell rock top
-- he pushed at the cell all flight and came down 1.25-1.5 m past it, 16 of 16). A long gap jump still steers; moving
-- away from the landing, he pushes back at it. With the second press of a double jump still to come, the flight is
-- counted with that press (since 2026-11-19; before, he steered on until it).
do
    local cm = pawn.CharacterMovement
    -- jt: s since the first press (st.jump_t), with a second press pending
    local function airborne(dist, vh, vz, above, rise, act, pending, jt)
        M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 2500, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(5)
        local mv = _G.DW_MOVE
        local here = pawn.loc
        mv.env = mv.env or {}; mv.env.double_jump, mv.env.dj_measured = true, true
        mv.lpath = { { X = here.X, Y = here.Y, Z = FLOOR, act = "walk" }, { X = here.X + 600, Y = here.Y, Z = FLOOR + rise, act = act or "djump" },
            { X = here.X + 700, Y = here.Y, Z = FLOOR + rise, act = "walk" } }
        mv.lwp = 2; mv.lp_jumped = {}; mv.lp_runup = nil
        mv.lp_jump_exec = { path = mv.lpath, index = 2, endpoint = mv.lpath[2], previous = mv.lpath[1], token = mv.owner_token,
                            started = T - 0.6, saw_air = true }
        mv.jump_t, mv.jump_double, mv.jump_release, mv.jump_t2 = jt and T - jt or nil, pending or false, false, nil
        mv.trav_fails, mv.lp_fail = nil, nil
        pawn.loc = { X = here.X + 600 - dist, Y = here.Y, Z = here.Z + rise + above }
        local inputs, real_add = 0, pawn.AddMovementInput
        pawn.AddMovementInput = function(self, d, sc) inputs = inputs + 1; return real_add(self, d, sc) end
        frame_hook = function() cm.Velocity = { X = vh, Y = 0, Z = vz } end
        local n0 = #logs
        air = 0.5
        step(1)
        frame_hook = nil; pawn.AddMovementInput = real_add
        local said
        for i = n0 + 1, #logs do if tostring(logs[i]):find("move: jump air: letting go", 1, true) then said = logs[i] end end
        return inputs, said, mv
    end
    -- the rock step: 60 cm short of the cell, 250 cm/s toward it, 87 cm over its level and falling (0.26 s to it)
    local inputs, said, mv = airborne(60, 250, -100, 87, 230)
    check("air: 60 cm from a top's cell with drift to spare, no stick this frame", inputs == 0 and said ~= nil
        and mv.lp_jump_exec and mv.lp_jump_exec.let_go ~= nil, "inputs=" .. inputs .. " " .. tostring(said))
    -- a long gap jump on one level: 4 m left at 300 cm/s, 0.33 s of flight left: he steers on
    inputs, said = airborne(400, 300, 300, 0, 0, "jump")
    check("air: a long gap jump still steers", inputs == 1 and said == nil, "inputs=" .. inputs .. " " .. tostring(said))
    -- past the cell and moving on away from it: he pushes back at it (the stick toward it brakes him)
    inputs, said = airborne(-60, 250, -100, 87, 230)
    check("air: past the cell, moving away, he pushes back at it", inputs == 1 and said == nil, "inputs=" .. inputs .. " " .. tostring(said))
    -- before a double jump's second press (scratchpad study jump_real_1119): the standing djumps onto one-cell tops
    -- (00:43:10Z, 01:08:41Z, 01:08:44Z, 01:57:38Z) pushed until the press, were at 221-309 cm/s there and came down
    -- 1.1-2.3 m past. 01:57:38Z's shape 0.2 s after the first press: the cell 85 cm off and 207 cm up, 82 cm under
    -- its level, rising at 445 cm/s, 150 cm/s toward it, the press 0.13 s away: the flight with that press carries
    -- him there, no stick
    inputs, said, mv = airborne(85, 150, 445, -82, 207, "djump", true, 0.2)
    check("air: before a double jump's second press, drift to spare over the flight it makes: no stick", inputs == 0
        and said ~= nil and said:find("the second press still to come in 0.1", 1, true) ~= nil and mv.jump_double == true,
        "inputs=" .. inputs .. " " .. tostring(said))
    -- 0.05 s after the press, 40 cm/s toward a cell 100 cm off: the drift falls short, he steers on
    inputs, said = airborne(100, 40, 717, -169, 207, "djump", true, 0.05)
    check("air: before the second press with too little drift he steers on", inputs == 1 and said == nil, "inputs=" .. inputs .. " " .. tostring(said))
    -- a 4 m gap double jump on one level before its second press: he steers on
    inputs, said = airborne(400, 300, 500, 50, 0, "djump", true, 0.1)
    check("air: a long gap double jump before its second press still steers", inputs == 1 and said == nil, "inputs=" .. inputs .. " " .. tostring(said))
    -- under the top's level and rising too slowly to reach it: no coast to its level, he steers on
    inputs, said = airborne(60, 250, 100, -200, 230)
    check("air: never back up to the top's level, he steers on", inputs == 1 and said == nil, "inputs=" .. inputs .. " " .. tostring(said))
    cm.Velocity = nil
    M.stop(log); air = 0; luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- A walk to a creature that is gone before he gets there says so (live 2026-11-17 07:36:55Z, run 073510: his reflex
-- killed the rat he was walking to and the walk ended with the bare code target_not_visible)
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local rat = obj({ loc = { X = 20000, Y = 0, Z = 0 }, K2_GetActorLocation = function(self) return self.loc end })
    M.go_to(log, { actor = rat }, { tolerance_m = 1, nav = false })
    run(105)
    local walking = M.status().result == nil
    rat.IsValid = function() return false end
    run(30)
    local r = M.status().result
    check("gone target: a walk to a creature that is no longer there says so", walking and r and r.status == "failed"
        and r.reason == "target_not_visible" and tostring(r.detail):find("no longer there", 1, true) ~= nil,
        tostring(walking) .. " " .. tostring(r and r.reason) .. " " .. tostring(r and r.detail))
    M.stop(log)
    -- the same when the walk was suspended for a fight and the creature died in it (live 2026-11-17 09:32:09Z, window
    -- s23: the walk resumed 5 s after his reflex killed the rat and ended 2 s later with the bare code again)
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local rat2 = obj({ loc = { X = 20000, Y = 0, Z = 0 }, K2_GetActorLocation = function(self) return self.loc end })
    M.go_to(log, { actor = rat2 }, { tolerance_m = 1, nav = false })
    run(105)
    local snap = M.snapshot()
    M.stop(log)
    rat2.IsValid = function() return false end
    local rr = M.restore(log, snap)
    run(120)
    local r2 = M.status().result
    check("gone target: a resumed walk to a creature that died meanwhile says so", snap ~= nil and rr and rr.ok ~= false
        and r2 and r2.status == "failed" and r2.reason == "target_not_visible"
        and tostring(r2.detail):find("no longer there", 1, true) ~= nil,
        tostring(rr and rr.ok) .. " " .. tostring(r2 and r2.reason) .. " " .. tostring(r2 and r2.detail))
    M.stop(log)
end

-- ARRIVAL UNDER CONTROL (live 20:33:51Z, rung 3 mine: "arrived" at 6.8 m/s after a hop 1.6 m from the goal, then a 5 m
-- slide out of reach of the rock): "arrived" waits until he has stopped in the circle; a rock AT the goal is not hopped
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    local cm = pawn.CharacterMovement
    cm.Velocity = { X = 0, Y = 0, Z = 0 }
    local hops, real_jump = 0, pawn.Jump
    pawn.Jump = function(...) hops = hops + 1; return real_jump(...) end
    M.go_to(log, { 6, 0, 0 }, { tolerance_m = 1.5, nav = false })
    local stopping = false
    frame_hook = function()
        local d = math.abs(600 - pawn.loc.X)
        cm.Velocity = { X = (d <= 150 and not stopping) and 500 or 0, Y = 0, Z = 0 } -- still sliding on reaching the circle
        if _G.DW_MOVE.status == "stopping" then stopping = true end
    end
    run(200)
    local s = M.status()
    check("arrival: waits in the circle while he still slides, then arrived", stopping and s.result and s.result.status == "arrived",
        tostring(stopping) .. " " .. tostring(s.result and s.result.status))
    frame_hook = nil; cm.Velocity = nil
    -- a low rock that IS the goal's surroundings (inside the arrival circle): walked up to, not hopped
    M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }; hops = 0
    walls = { { 560, 700, -100, 100 } }
    M.go_to(log, { 6.6, 0, 0 }, { tolerance_m = 1.6, nav = false })
    run(200)
    s = M.status()
    check("arrival: no hop onto a rock inside the goal's circle", hops == 0 and s.result and s.result.status == "arrived",
        "hops=" .. hops .. " " .. tostring(s.result and s.result.status))
    pawn.Jump = real_jump; walls = {}
    M.stop(log)
end

-- A hop of the leader's over open ground is not copied (ghost ladder 2026-11-01: Luis hops and Windsteps on the
-- flat; every copied jump cost 1-3 s at 2-3 m/s, a gap that never closes behind a 6.8 m/s sprint); over a low wall
-- it is
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); GEAR = false
    local jumps, real_jump = 0, pawn.Jump
    pawn.Jump = function(...) jumps = jumps + 1; return real_jump(...) end
    local function hop(wall)
        M.stop(log); walls = wall or {}; air = 0; jumps = 0
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 900, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(2)
        local mv = _G.DW_MOVE
        mv.crumbs = { { X = 0, Y = 0, Z = 0 }, { X = 100, Y = 0, Z = 120, air = true }, { X = 300, Y = 0, Z = 150, air = true },
                      { X = 500, Y = 0, Z = 0 }, { X = 900, Y = 0, Z = 0 } }
        mv.trail_i, mv.trail_jumped = 2, {}
        local n0 = #logs
        step(3)
        local said = false
        for i = n0 + 1, #logs do if logs[i]:find("running on, no jump", 1, true) then said = true end end
        return said, jumps
    end
    local said, n = hop()
    check("trail: his hop over open ground is not copied", said and n == 0, tostring(said) .. " jumps=" .. n)
    said, n = hop({ { 300, 320, -100, 100 } })
    check("trail: his jump over a low wall is copied", not said and n >= 1, tostring(said) .. " jumps=" .. n)
    -- his jump up onto a 1.6 m ledge (he lands on it, on ground): copied, not "run on" toward him up there
    do
        M.stop(log); walls = {}; air = 0; jumps = 0
        raised = { { 400, 2000, -150, 150, 160, 160 } }
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 900, Y = 0, Z = 160 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(2)
        local mv = _G.DW_MOVE
        mv.crumbs = { { X = 0, Y = 0, Z = 0 }, { X = 100, Y = 0, Z = 120, air = true }, { X = 300, Y = 0, Z = 250, air = true },
                      { X = 500, Y = 0, Z = 160 }, { X = 900, Y = 0, Z = 160 } }
        mv.trail_i, mv.trail_jumped = 2, {}
        local n0 = #logs
        step(3)
        said = false
        for i = n0 + 1, #logs do if logs[i]:find("running on, no jump", 1, true) then said = true end end
        check("trail: his jump up onto a ledge is copied, not run on", not said and jumps >= 1, tostring(said) .. " jumps=" .. jumps)
        raised = {}
    end
    -- he hops onto a box beside the way and down again: where his trail comes back down is in clear sight, so run
    -- on there, no jump (live church loop 00:39:15Z: copying such hops cost 4-11 s)
    do
        M.stop(log); walls = {}; air = 0; jumps = 0
        raised = { { 350, 550, 150, 300, 160, 160 } }
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 900, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(2)
        local mv = _G.DW_MOVE
        local bx = pawn.loc.X
        mv.crumbs = { { X = bx, Y = 0, Z = 0 }, { X = bx + 130, Y = 0, Z = 120, air = true }, { X = 300, Y = 180, Z = 250, air = true },
                      { X = 450, Y = 220, Z = 160 }, { X = 650, Y = 60, Z = 120, air = true }, { X = 750, Y = 0, Z = 0 }, { X = 900, Y = 0, Z = 0 } }
        mv.trail_i, mv.trail_jumped = 2, {}
        local n0 = #logs
        step(3)
        said = false
        for i = n0 + 1, #logs do if logs[i]:find("running on, no jump", 1, true) then said = true end end
        check("trail: his hop onto a box beside the way, with the way down in sight, is not copied", said and jumps == 0, tostring(said) .. " jumps=" .. jumps)
        raised = {}
    end
    -- hops and Windsteps in a row over flat ground: a sample between two reads as ground ~1 m up (in our jump's reach), with no floor under
    -- it at that height: no ledge, so run on below him (live doric 01:24:35Z, a copied double jump at 3 m/s)
    do
        M.stop(log); walls = {}; raised = {}; air = 0; jumps = 0
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 900, Y = 0, Z = 0 }
        M.follow(log, "Zezima", 2, { nav = false })
        run(2)
        local mv = _G.DW_MOVE
        local bx = pawn.loc.X
        mv.crumbs = { { X = bx, Y = 0, Z = 0 }, { X = bx + 130, Y = 0, Z = 150, air = true }, { X = bx + 300, Y = 0, Z = 220, air = true },
                      { X = bx + 450, Y = 0, Z = 90 }, { X = bx + 600, Y = 0, Z = 200, air = true }, { X = bx + 750, Y = 0, Z = 90 }, { X = 2200, Y = 0, Z = 0 } }
        mv.trail_i, mv.trail_jumped = 2, {}
        local n0 = #logs
        step(3)
        said = false
        for i = n0 + 1, #logs do if logs[i]:find("running on, no jump", 1, true) then said = true end end
        check("trail: his hops in a row over flat ground (no floor under where he 'landed') are not copied", said and jumps == 0, tostring(said) .. " jumps=" .. jumps)
    end
    pawn.Jump = real_jump
    M.stop(log); walls = {}; luis.loc = { X = 3000, Y = 0, Z = 0 }
end

-- STANDING for a route (Luis's stand bar: a player starts at once): a route helper that is recovering cannot send one
-- (live 01:01-02:18Z, 59-66 s standing); one that never answers is waited on for nav_stand_s, then local planning
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; HOLES = nil; air = 0
    pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = nil; pump_oracle()
    local hb = io.open(dir .. "/client_io/nav/alive.lua", "w")
    hb:write(('return {version=2,epoch="33333333-3333-4333-8333-333333333333",state="recovering",updated=%d}'):format(os.time())); hb:close()
    M.go_to(log, { 20, 0, 0 }, { local_plan = false })
    local T0, moved_t = T, nil
    for _ = 1, 300 do step(1); if pawn.loc.X > 10 then moved_t = T - T0; break end end
    check("stand: a recovering route helper -> walking at once", moved_t and moved_t < 1, tostring(moved_t))
    M.stop(log); pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = function() return nil end; pump_oracle()
    M.go_to(log, { 20, 0, 0 }, { local_plan = false })
    T0, moved_t = T, nil
    for _ = 1, 600 do step(1); pump_oracle(); if pawn.loc.X > 10 then moved_t = T - T0; break end end
    check("stand: a route that never comes -> walking within 5 s", moved_t and moved_t > 2 and moved_t < 5, tostring(moved_t))
    M.stop(log); oracle = nil; pump_oracle()
end

-- a long go_to whose route is pending walks a remembered route that reaches the goal meanwhile, not the straight
-- line into the wall (live grave runs 02:40-03:03Z: respawn at the temple lodestone, 20 s to a steady sprint)
do
    M.stop(log); frame_hook = nil; raised = {}; HOLES = nil; air = 0
    walls = { { 1000, 1500, -800, 800, true } }
    _G.DW_NAVMEM = nil; os.remove(memf)
    local f = io.open(memf, "w")
    f:write('{"v":1,"next_id":2,"traps":[],"taboos":[],"routes":[{"id":"r1","src":"self","n_ok":3,"n_fail":0,"n_used":0,"ts":1,'
        .. '"pts":[[0,0,-0.9],[5,0,-0.9],[5,12,-0.9],[25,12,-0.9],[25,0,-0.9],[60,0,-0.9]]}]}'); f:close()
    pawn.loc = { X = 0, Y = 0, Z = 0 }; oracle = function() return nil end
    offer.no = offer.no + 1; offer.nonce = fake_nonce(offer.no); pump_oracle()
    local n0 = #logs
    M.go_to(log, { 60, 0, 0 }, { tolerance_m = 1.5, timeout_s = 90 })
    run(500)
    local r = M.status().result
    local mem_said, walls_said, stuck = false, false, 0
    for i = n0 + 1, #logs do
        if logs[i]:find("walking a remembered route that reaches the goal", 1, true) then mem_said = true end
        if logs[i]:find("walls everywhere", 1, true) then walls_said = true end
        if logs[i]:find("move: stuck n=", 1, true) then stuck = stuck + 1 end
    end
    check("route pending: a remembered route to the goal is walked meanwhile (no wall, no stuck)",
        mem_said and not walls_said and stuck == 0 and r and r.status == "arrived",
        tostring(mem_said) .. " walls=" .. tostring(walls_said) .. " stuck=" .. stuck .. " " .. tostring(r and r.status))
    M.stop(log); walls = {}; oracle = nil; pump_oracle(); _G.DW_NAVMEM = nil; os.remove(memf)
end

-- a pinch no trace sees (a tree and a felled log 0.8 m apart, live doric 03:45:52Z): where he was stopped, the next
-- plans go round instead of back into it
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; HOLES = nil; air = 0; oracle = nil; pump_oracle()
    _G.DW_NAVMEM = nil; os.remove(memf)
    PINCH = { { 600, 760, -90, 90 } }
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 60, nav = false })
    local T0, done_t = T, nil
    for _ = 1, 600 do run(1); local r = M.status().result; if r then done_t = T - T0; break end end
    local r = M.status().result
    PINCH = nil
    check("pinch: a thin obstacle that stopped him is planned round (arrives in < 16 s; it never did)",
        r and r.status == "arrived" and done_t and done_t < 16, tostring(r and r.status) .. " t=" .. tostring(done_t))
    M.stop(log)
end

-- WEDGED among placed pieces (live 23:42Z, Luis's church base: a Spinning Wheel, a bench, farm plots): the failure
-- names them instead of a bare "stuck"
do
    M.stop(log); frame_hook = nil; raised = {}; air = 0; oracle = nil; pump_oracle(); lakes = {}
    _G.DW_LP_CACHE = nil; _G.DW_NAVMEM = nil; _G.DW_TRAP_CAND = nil; os.remove(memf)
    walls = { { 60, 160, -400, 400, true }, { -160, -60, -400, 400, true }, { -400, 400, 60, 160, true }, { -400, 400, -160, -60, true } }
    pawn.loc = { X = 0, Y = 0, Z = 0 }
    luis.loc = { X = 90000, Y = 90000, Z = 0 }
    local base_find = FindAllOf
    local wheel = obj({ GetFullName = function() return "BP_Station_Spinning_Wheel_C /Game/Maps/World.L:PersistentLevel.BP_Station_Spinning_Wheel_C_2147480387" end,
        K2_GetActorLocation = function() return { X = 0, Y = 110, Z = -10 } end,
        GetActorBounds = function(_, _, o, e) o.X, o.Y, o.Z = 0, 110, -10; e.X, e.Y, e.Z = 58, 60, 76 end })
    FindAllOf = function(c) if c == "BP_BaseBuilding_BaseActor_C" then return { wheel } end return base_find(c) end
    M.go_to(log, { 20, 0, 0 }, { tolerance_m = 1, timeout_s = 120, nav = false })
    run(1200)
    local r = M.status().result
    FindAllOf = base_find
    check("wedged: the failure names the placed piece he is wedged against", r and r.reason == "stuck" and r.why == "wedged_by_pieces"
        and tostring(r.detail):find("Spinning Wheel", 1, true) ~= nil, r and (tostring(r.reason) .. " " .. tostring(r.detail)))
    M.stop(log); walls = {}
end

-- WATER: a pond on the straight way is gone round on dry ground (it is slower to swim: MaxSwimSpeed 300 against ~650
-- running); a river across the whole way is swum (no way round is faster). Luis, 2026-11-02
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle()
    local function water_run(cells, goal)
        M.stop(log); _G.DW_NAVMEM = nil; os.remove(memf)
        local f = io.open(memf, "w"); f:write('{"v":1,"next_id":1,"traps":[],"taboos":[],"routes":[],"water_cells":' .. json_cells(cells) .. '}'); f:close()
        pawn.loc = { X = 0, Y = 0, Z = 0 }
        local n0, wet_n = #logs, 0
        local NMt = dofile(dir .. "/client_mod/scripts/navmem.lua")
        M.go_to(log, goal, { tolerance_m = 1.5, timeout_s = 60, nav = false })
        for _ = 1, 400 do
            run(1)
            local mem = _G.DW_NAVMEM
            if mem and NMt.is_water(mem, pawn.loc) then wet_n = wet_n + 1 end
            local s2 = M.status()
            if s2.result then break end
        end
        local said = {}
        for i = n0 + 1, #logs do if logs[i]:find("move: water:", 1, true) then said[#said + 1] = logs[i] end end
        local s3 = M.status()
        if os.getenv("WET_DEBUG") then print("WET", pawn.loc.X, pawn.loc.Y, s3.mode, s3.status, s3.result and s3.result.status, table.concat(said, " | ")) end
        return s3.result, wet_n, table.concat(said, " | ")
    end
    local pond = {}
    for i = 6, 13 do for j = -4, 3 do pond[#pond + 1] = i .. ":" .. j end end -- 16 x 16 m at x 12-28 m
    local r, wet_n, said = water_run(pond, { 40, 0, 0 })
    check("water: a pond on the way is gone round on dry ground", r and r.status == "arrived" and wet_n == 0 and said:find("going round", 1, true) ~= nil,
        tostring(r and r.status) .. " wet_frames=" .. wet_n .. " " .. said)
    local river = {}
    for i = 9, 10 do for j = -60, 60 do river[#river + 1] = i .. ":" .. j end end -- a 4 m band, 240 m long
    r, wet_n, said = water_run(river, { 40, 0, 0 })
    check("water: a river across the whole way is swum (going round is no faster)", r and r.status == "arrived" and said:find("so across it", 1, true) ~= nil,
        tostring(r and r.status) .. " " .. said)
    -- following: he walks round a pond (Luis 2026-11-02: "Claude goes straight through the water instead of round
    -- it"); Claude, cutting the corner toward him, does not cut through the water
    do
        M.stop(log); _G.DW_NAVMEM = nil; os.remove(memf)
        local f = io.open(memf, "w"); f:write('{"v":1,"next_id":1,"traps":[],"taboos":[],"routes":[],"water_cells":' .. json_cells(pond) .. '}'); f:close()
        local NMt = dofile(dir .. "/client_mod/scripts/navmem.lua")
        pawn.loc = { X = 0, Y = 0, Z = 0 }; luis.loc = { X = 400, Y = 0, Z = 0 }
        local path = { { 900, -1300 }, { 3100, -1300 }, { 4200, 0 }, { 6000, 0 } } -- round the pond's south side
        local seg = 1
        frame_hook = function()
            local tgt = path[seg]; if not tgt then return end
            local dx, dy = tgt[1] - luis.loc.X, tgt[2] - luis.loc.Y
            local d = math.sqrt(dx * dx + dy * dy); local sp = 420 * DT
            if d <= sp then luis.loc.X, luis.loc.Y = tgt[1], tgt[2]; seg = seg + 1
            else luis.loc.X, luis.loc.Y = luis.loc.X + dx / d * sp, luis.loc.Y + dy / d * sp end
        end
        local n0, wet_n = #logs, 0
        M.follow(log, "Zezima", 3, { nav = false })
        for _ = 1, 260 do
            run(1)
            local mem = _G.DW_NAVMEM
            if mem and NMt.is_water(mem, pawn.loc) then wet_n = wet_n + 1 end
        end
        frame_hook = nil
        local said = ""
        for i = n0 + 1, #logs do if logs[i]:find("move: water:", 1, true) then said = said .. logs[i] .. " | " end end
        local dl = math.sqrt((pawn.loc.X - luis.loc.X) ^ 2 + (pawn.loc.Y - luis.loc.Y) ^ 2)
        check("water: following him round a pond, Claude does not cut through it", wet_n == 0 and dl < 800,
            string.format("wet_frames=%d d=%.0f %s", wet_n, dl, said))
        M.stop(log); luis.loc = { X = 90000, Y = 90000, Z = 0 }
    end
    M.stop(log); _G.DW_NAVMEM = nil; os.remove(memf)
end

-- IDLE HOSTILES (Luis 2026-11-02: route cost near idle hostiles in sight, like the hazard memory): a Giant Rat
-- (Aggressive, ambient) 6 m off a straight 24 m walk is given a wide berth; one already fighting, or one at the goal
-- (the rat he walks up to), is not
;(function()
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; oracle = nil; pump_oracle(); _G.DW_LP_CACHE = nil
    luis.loc = { X = 90000, Y = 90000, Z = 0 }
    local alert = 0
    local rat = obj({ K2_GetActorLocation = function() return { X = 800, Y = 50, Z = 0 } end,
        LoadedData = obj({ Archetype = 0 }), HealthComponent = obj({ IsDead = function() return false end }),
        IsFollower = function() return false end, GetFName = function() return { ToString = function() return "BP_GiantRat_C_1" end } end })
    rat.__alert = true
    setmetatable(rat, { __index = function(_, k) if k == "CurrentAlertnessState" then return alert end end })
    local base_find = FindAllOf
    FindAllOf = function(c) if c == "DominionAICharacter" then return { rat } end return base_find(c) end
    local function walk(goal)
        pawn.loc = { X = 0, Y = 0, Z = 0 }
        M.go_to(log, goal, { tolerance_m = 1, nav = false, timeout_s = 40 })
        local closest, t0 = 1e9, T
        while not M.status().result and T - t0 < 30 do
            run(1)
            closest = math.min(closest, math.sqrt((pawn.loc.X - 800) ^ 2 + (pawn.loc.Y - 50) ^ 2))
        end
        local r = M.status().result
        M.stop(log)
        return r, closest, T - t0
    end
    local r, closest, dt = walk({ 24, 0, 0 })
    check("hostile: an idle rat 0.5 m off the way is walked round (keeps 5 m+), arrives", r and r.status == "arrived" and closest >= 500 and dt < 10,
        (r and r.status or "nil") .. string.format(" closest=%.0f t=%.1f", closest, dt))
    alert = 4
    r, closest, dt = walk({ 24, 0, 0 })
    check("hostile: one already in combat is no cost (the fight handles it)", r and r.status == "arrived" and closest < 300,
        (r and r.status or "nil") .. string.format(" closest=%.0f", closest))
    alert = 0
    r, closest, dt = walk({ 9, 0.5, 0 })
    check("hostile: the rat at the goal (walking up to it) is no cost", r and r.status == "arrived" and dt < 4,
        (r and r.status or "nil") .. string.format(" t=%.1f", dt))
    FindAllOf = base_find
end)()

-- A JUMP LANDING CELL ON A FLANK (jump_doric 2026-11-17, docs/research/2026-11-17-jump-doric.md): the cell's one centre
-- trace reads a notch on a rock's flank, and inside his capsule's footprint (34 cm from the centre) the rock stands far
-- over it. He cannot stand there: he passes over it and lands on the bench past it (14 of 14 west jumps). A jump's
-- landing cell is taken only when no ground under his capsule's footprint is more than a step above the cell; otherwise
-- the planner leaves that cell out, takes another, and says which it refused. Here, walking +X along y = 0: notch x 0.6
-- to 1.25 m, y +-0.25 m, 1.0 m up (cell (1,0)), from x = -2 m; a 6 m rock from x = 1.25 m (y < 0.4 m), 25 cm from the cell's centre;
-- a wide real ledge 1.0 m up at y > 0.4 m (cell (1,1)). The goal is the notch cell (like Doric's goal on its cell).
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false; oracle = nil; pump_oracle()
    GEAR = false; HAS_DJ = false
    local function trip(world)
        M.stop(log); air = 0; pawn.loc = { X = -200, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil; raised = world
        local l0 = #logs
        M.go_to(log, { 1.0, 0, 1.0 }, { tolerance_m = 0.3, nav = false, stand = true, timeout_s = 20 })
        run(250)
        local onto, refused, paths = {}, {}, 0
        for i = l0 + 1, #logs do
            local acts, pts = logs[i]:match("move: local path %d+ pts %[(%a+)%].- pts=(.*)$")
            if acts then
                paths = paths + 1
                local k = 0
                for p in pts:gmatch("%S+") do
                    k = k + 1
                    local a = acts:sub(k, k)
                    if a == "j" or a == "d" then onto[p] = (onto[p] or 0) + 1 end
                end
            end
            if logs[i]:find("move: jump cell refused: not standable", 1, true) then refused[#refused + 1] = logs[i] end
        end
        if os.getenv("FLANK_DEBUG") then for i = l0 + 1, #logs do print("  | " .. logs[i]) end end
        M.stop(log)
        return onto, refused, paths
    end
    local ledge = { 60, 600, 40, 300, 100, 100 }
    local onto, refused, paths = trip({ { 60, 125, -25, 25, 100, 100 }, { 125, 600, -300, 40, 600, 600 }, ledge })
    check("flank cell: no jump lands on the notch whose footprint is inside the rock", paths > 0 and not onto["1,0,0.1"],
        string.format("paths=%d jumps onto the notch=%s", paths, tostring(onto["1,0,0.1"])))
    check("flank cell: the refused cell is logged with the ground above it", #refused > 0 and refused[1]:find("1,0,0.1", 1, true) ~= nil
        and refused[1]:find("above the cell", 1, true) ~= nil, tostring(refused[1]))
    check("flank cell: the plan takes the ledge cell beside it instead", onto["1,1,0.1"] ~= nil,
        string.format("paths=%d jumps onto the ledge cell=%s", paths, tostring(onto["1,1,0.1"])))
    -- the control: the same notch with the rock 40 cm from its centre (outside the footprint): a narrow top like any
    -- other, the jump onto it stays
    onto, refused, paths = trip({ { 60, 140, -25, 25, 100, 100 }, { 140, 600, -300, 40, 600, 600 }, ledge })
    check("notch with the rock outside his footprint: the jump onto it stays, nothing refused", onto["1,0,0.1"] ~= nil and #refused == 0,
        string.format("paths=%d jumps onto the notch=%s refused=%s", paths, tostring(onto["1,0,0.1"]), tostring(refused[1])))
    raised = {}; _G.DW_LP_CACHE = nil
end

-- A LOCAL PLAN BEGUN IN THE AIR (window jumpcourse_1118b, 2026-11-18 00:40Z): two plans begun 84 and 94 cm up in a hop
-- took his feet in flight as the start floor, offered single jumps of 122 and 143 cm that rose 216 and 227 cm from the
-- floor he came down on, and he fell back twice. A plan begun while falling starts on the floor under him. Here: a
-- ledge 2.4 m up from x = 0.6 m (under the measured 2.6 m double jump); from x = -1.5 m until the first plan begins
-- (at most 1.5 s) he is in the air 90 cm over the floor. From his feet in flight the ledge is a 1.5 m rise; from the
-- floor, 2.4 m.
do
    M.stop(log); frame_hook = nil; walls = {}; raised = {}; air = 0; sprinting = false; oracle = nil; pump_oracle()
    GEAR = false
    local dj0 = HAS_DJ
    HAS_DJ = true
    do local f = io.open(envf, "w"); f:write('{"character":"Claude","measured":"test","jump_up_m":{"stand":1.05},"dj_up_m":2.6,"dj_delay_s":0.33,"measurement_provenance":{"jump_up_m.stand":{"verified":true},"dj_up_m":{"verified":true}}}'); f:close() end
    local M = dofile(MOVE)
    local cm = pawn.CharacterMovement
    local function airplan(lift)
        M.stop(log); air = 0; pawn.loc = { X = -200, Y = 0, Z = 0 }; _G.DW_LP_CACHE = nil
        raised = { { 60, 800, -400, 400, 240, 240 } }
        local l0 = #logs
        cm.IsFalling = function() return air > 0 end
        -- once he walks (x > -1.5 m) and until the first plan begins, he is in the air (a hop), then lands
        local held, t_up = lift ~= nil, nil
        frame_hook = function()
            if held and pawn.loc.X > -150 then
                t_up = t_up or T
                if T - t_up > 1.5 then held = false end
                for i = l0 + 1, #logs do if logs[i]:find("move: local plan #", 1, true) then held = false end end
                if held then air = 0.5; pawn.loc.Z = (wall_top(pawn.loc.X, pawn.loc.Y) or FLOOR) + 90 + lift
                else air = 0; pawn.loc.Z = (wall_top(pawn.loc.X, pawn.loc.Y) or FLOOR) + 90 end
            end
        end
        M.go_to(log, { 3.0, 0, 2.4 }, { tolerance_m = 0.3, nav = false, stand = true, timeout_s = 20 })
        run(200)
        frame_hook = nil; cm.IsFalling = nil
        local first, said
        for i = l0 + 1, #logs do
            local acts, pts = logs[i]:match("move: local path %d+ pts %[(%a+)%].- pts=(%S+)")
            if acts and not first then first = { acts = acts, start = pts } end
            if logs[i]:find("move: local plan begun in the air", 1, true) then said = logs[i] end
        end
        if os.getenv("AIRPLAN_DEBUG") then for i = l0 + 1, #logs do print("  | " .. logs[i]) end end
        M.stop(log)
        return first, said
    end
    local first, said = airplan(90)
    check("plan begun in the air: it starts on the floor under him (-0.9 m), not at his feet in flight (0.0)",
        first ~= nil and first.start:match(",%-0%.9$") ~= nil, first and (first.acts .. " start=" .. first.start) or "no path")
    check("plan begun in the air: the mover says so, with the drop", said ~= nil and said:find("90 cm", 1, true) ~= nil, tostring(said))
    -- the control: the same plan begun on the ground starts at his feet and says nothing
    first, said = airplan(nil)
    check("plan begun on the ground: starts at his feet, a double jump, nothing said", first ~= nil and first.start:match(",%-0%.9$") ~= nil
        and first.acts:find("d") ~= nil and said == nil, first and (first.acts .. " start=" .. first.start) or "no path")
    M.stop(log); os.remove(envf); raised = {}; _G.DW_LP_CACHE = nil; HAS_DJ = dj0
end

for _, l in ipairs(logs) do if l:find("error") then print("LOG " .. l) end end
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
