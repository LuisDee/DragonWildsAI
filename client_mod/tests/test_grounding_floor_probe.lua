local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local real_load=loadfile
local command=assert(real_load(here..'/../commands/grounding_floor_probe.lua'))()
local hubfile=here..'/../scripts/hookhub.lua'; local readerfile=here..'/../scripts/floor_read.lua'
local path='/Script/Engine.CharacterMovementComponent:K2_FindFloor'
local key='floor_read:typed'
local passes, failures=0,0
local function check(s,b) if b then passes=passes+1 else failures=failures+1; print('FAIL '..s) end end
local function fake_type(x) if type(x)=='table' and x.fake then return 'userdata' end; return type(x) end
local function struct(t) t.fake=true; t.type=function() return 'UScriptStruct' end; t.IsValid=function() return true end; t.GetStructAddress=function() return 123 end; return t end
local function param(k,v) return {fake=true,type=function() return k end,get=function() return v end} end
local function object(id,t) t=t or {}; t.IsValid=function() return true end; t.GetAddress=function() return id end; return t end
local function setup()
 _G.DWHookHub=nil; _G.DWFloorReader=nil; _G.DWGroundingFloorProbeAPI=nil; _G.DW_PAUSE=nil
 _G.DW_MOVE={mode='idle',gen=1}; _G.DWArbiter={owner=nil,stack={}}; _G.DW_LIFE={move_death_seq=0}
 local f={world='dev',calls=0,registers=0,mode='normal',pos={X=1,Y=2,Z=3}}
 function RegisterHook(p,pre,post) f.registers=f.registers+1; f.post=post; return 1,2 end
 function UnregisterHook() error('never unregister') end
 f.w=object(6); f.c=object(3,{Velocity={X=0,Y=0,Z=0}}); f.cap=object(4,{GetScaledCapsuleRadius=function() return 34 end,GetScaledCapsuleHalfHeight=function() return 88 end})
 f.health=object(5,{IsDead=function() return false end,GetAuthoritativeHealth=function() return 100 end})
 f.p=object(2,{CharacterMovement=f.c,CapsuleComponent=f.cap,HealthComponent=f.health,GetWorld=function() return f.w end,K2_GetActorLocation=function() return f.pos end})
 f.pc=object(1,{Pawn=f.p,IsLocalController=function() return true end})
 f.U={find_all=function() return {f.pc} end,try=function(fn) local ok,r=pcall(fn); return ok and r or nil end,world_id=function() return f.world end}
 local h=assert(real_load(hubfile))(); h._state().off=false; f.h=h
 local reader=assert(real_load(readerfile))()
 _G.loadfile=function(p)
  if p:match('/mod/body/util.lua$') then return function() return f.U end end
  if p:match('/client_mod/scripts/hookhub.lua$') then return function() return h end end
  if p:match('/client_mod/scripts/floor_read.lua$') then return function() return {new=function(hub) return reader._new_for_test(hub,fake_type) end} end end
  return real_load(p)
 end
 function f.c:K2_FindFloor(loc)
  f.calls=f.calls+1
  if f.mode=='reenter' then f.inner=command(nil) end
  if f.mode=='life' or f.mode=='life_aba' then _G.DW_LIFE.move_death_seq=1 end
  if f.mode=='world' then f.world='other' end
  if f.mode=='owner' then _G.DWArbiter.owner={} end
  if f.mode=='pose' then f.pos={X=2,Y=2,Z=3} end
  if f.mode=='cleanup' then f.h._state().paths[path].subs[key]=function() end end
  if f.mode=='error' then error('native failure') end
  local hit=struct{bBlockingHit=true,bStartPenetrating=false,Distance=0,ImpactPoint={X=1,Y=2,Z=3},ImpactNormal={X=0,Y=0,Z=1}}
  local floor=struct{bBlockingHit=true,bWalkableFloor=true,bLineTrace=false,FloorDist=2,LineDist=0,HitResult=hit}
  if f.mode~='missing' then f.post(param('RemoteUnrealParam',self),param('LocalUnrealParam',struct{X=loc.X,Y=loc.Y,Z=loc.Z}),param('LocalUnrealParam',floor)) end
  if f.mode=='life_aba' then _G.DW_LIFE.move_death_seq=0 end
 end
 return f
end
local f=setup(); local r=command(nil)
check('one query and first registration',r.ok and r.consumed==1 and f.calls==1 and f.registers==1 and r.observation.callbacks==1)
check('zero distance copied separately',r.ok and r.observation.fields.hit.Distance.value==0 and r.observation.fields.hit.bStartPenetrating.value==false)
local ledger=_G.DWFloorReader; local retained=_G.DWGroundingFloorProbeAPI
r=command(nil,{offset_cm={X=150,Y=0,Z=0}})
check('same retained factory and bounded offset',r.ok and f.calls==2 and f.registers==1 and _G.DWFloorReader==ledger and _G.DWGroundingFloorProbeAPI==retained and r.observation.location.X==151)
for _,offset in ipairs({{X=151,Y=0,Z=0},{X=100,Y=100,Z=100},{X=0/0,Y=0,Z=0}}) do local n=f.calls; r=command(nil,{offset_cm=offset}); check('offset rejected',not r.ok and f.calls==n) end
f=setup(); _G.DWFloorReader={version=2,status='closed'}; r=command(nil); check('foreign closed ledger never adopted',not r.ok and f.calls==0 and f.registers==0)
f=setup(); f.h._state().paths[path]={native=true,subs={foreign=function() end}}; r=command(nil); check('foreign subscriber preserved',not r.ok and f.calls==0 and f.registers==0 and f.h._state().paths[path].subs.foreign~=nil)
for _,mode in ipairs({'life','life_aba','world','owner','pose','error','missing','cleanup'}) do
 f=setup(); f.mode=mode; r=command(nil); check(mode..' rejected after one query',not r.ok and r.observation==nil and f.calls==1)
 if mode~='cleanup' then check(mode..' exact cleanup',r.cleanup.ok and _G.DWFloorReader.status=='closed')
 else check('foreign replacement never removed',not r.cleanup.ok and f.h._state().paths[path].subs[key]~=nil) end
end
f=setup(); f.mode='reenter'; r=command(nil); check('reentry rejected without extra call',r.ok and f.calls==1 and f.inner and not f.inner.ok)
f=setup(); f.c.Velocity.X=1; r=command(nil); check('moving pawn refuses query',not r.ok and f.calls==0)
f=setup(); _G.DW_PAUSE=true; r=command(nil); check('paused refuses query',not r.ok and f.calls==0)
f=setup(); _G.DWArbiter.owner={}; r=command(nil); check('owned action refuses query',not r.ok and f.calls==0)
_G.loadfile=real_load
print(string.format('%d passed, %d failed',passes,failures)); os.exit(failures==0 and 0 or 1)
