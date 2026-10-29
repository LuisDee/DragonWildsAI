local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local real=loadfile
local script=here..'/../scripts/walk_sense.lua'; local hubfile=here..'/../scripts/hookhub.lua'; local readerfile=here..'/../scripts/floor_read.lua'
local path='/Script/Engine.CharacterMovementComponent:K2_FindFloor'; local key='floor_read:typed'
local pass,fail=0,0
local function check(s,v) if v then pass=pass+1 else fail=fail+1; print('FAIL '..s) end end
local function fake_type(x) if type(x)=='table' and x.fake then return 'userdata' end; return type(x) end
local function struct(t) t.fake=true;t.type=function() return 'UScriptStruct' end;t.IsValid=function() return true end;t.GetStructAddress=function() return 23 end;return t end
local function param(k,v) return {fake=true,type=function() return k end,get=function() return v end} end
local function object(id,t) t=t or {}; t.IsValid=function() return true end;t.GetAddress=function() return id end;return t end
local function setup()
 _G.DWHookHub=nil;_G.DWFloorReader=nil;_G.DWWalkSenseServiceV1=nil;_G.DW_PAUSE=nil
 local f={regs=0,native=0,traces=0,live=true,mode='normal',profile='Player',radius=34,hh=88,step=45,gap=2.1,actors={},components={},position={X=1,Y=2,Z=3}}
 function RegisterHook(p,pre,post) f.regs=f.regs+1;f.post=post;return 1,2 end
 function UnregisterHook() error('must not unregister') end
 local hub=assert(real(hubfile))();hub._state().off=false;f.hub=hub
 local reader=assert(real(readerfile))()
 _G.loadfile=function(p)
  if p:match('/client_mod/scripts/hookhub.lua$') then return function() return hub end end
  if p:match('/client_mod/scripts/floor_read.lua$') then return function() return {new=function(h)
   local query,close,acquire=reader._new_for_test(h,fake_type)
   if not f.cleanup_throw then return query,close,acquire end
   return query,function() error(true) end,function(opts) local lease,reason=acquire(opts); if lease then f.live=false end; return lease,reason end
  end} end end
  return real(p)
 end
 f.cap=object(3,{GetScaledCapsuleRadius=function() return f.radius end,GetScaledCapsuleHalfHeight=function() return f.hh end,
 GetCollisionProfileName=function() return {ToString=function() return f.profile end} end,
 CopyArrayOfMoveIgnoreActors=function() return f.actors end,CopyArrayOfMoveIgnoreComponents=function() return f.components end,
 K2_GetComponentLocation=function() return f.position end})
 f.health=object(4,{IsDead=function() return f.mode=='dead' end,GetAuthoritativeHealth=function() return 100 end})
 f.floor=struct{bBlockingHit=true,bWalkableFloor=true,bLineTrace=false,FloorDist=f.gap,LineDist=0}
 f.mc=object(2,{MaxStepHeight=f.step,CurrentFloor=f.floor,IsMovingOnGround=function() return f.mode~='air' end})
 f.pawn=object(1,{CapsuleComponent=f.cap,RootComponent=f.cap,CharacterMovement=f.mc,HealthComponent=f.health,K2_GetActorLocation=function() return f.position end})
 f.pc=object(5,{Pawn=f.pawn})
 f.ksl=object(6,{CapsuleTraceSingleByProfile=function(_,pawn,a,b,r,hh,profile,complex,ignore,draw,out,selfignore,c0,c1,time)
  f.traces=f.traces+1;f.traceargs={a=a,b=b,r=r,hh=hh,profile=profile,selfignore=selfignore}
  if f.mode=='trace_bad' then return nil end
  if f.mode=='trace_invalidate' then f.live=false end
  return f.mode=='blocked'
 end})
 local fn=object(7)
 function StaticFindObject(p) if p:find('Default__') then return f.ksl else return fn end end
 function FName(x) return x end
 function f.mc:K2_FindFloor(pos)
  f.native=f.native+1
  if f.mode=='reentry' then f.nested_close,f.nested_reason=f.sensor.close() end
  local hit=struct{bBlockingHit=true,bStartPenetrating=false,Distance=0,ImpactPoint={X=1,Y=2,Z=3},ImpactNormal={X=0,Y=0,Z=1}}
  local floor=struct{bBlockingHit=true,bWalkableFloor=true,bLineTrace=false,FloorDist=2,LineDist=0,HitResult=hit}
  f.post(param('RemoteUnrealParam',self),param('LocalUnrealParam',struct{X=pos.X,Y=pos.Y,Z=pos.Z}),param('LocalUnrealParam',floor))
  if f.mode=='floor_invalidate' then f.live=false end
 end
 f.mod=assert(real(script))()
 function f:acquire() return self.mod.acquire{root='C:/gameserver',pawn=self.pawn,pc=self.pc,live=function() return self.live end} end
 return f
end
local f=setup();check('load inert',f.regs==0 and f.native==0 and f.traces==0 and _G.DWWalkSenseServiceV1==nil)
local s,why=f:acquire();check('acquire first',s~=nil and f.regs==1 and s.shape.profile=='Player' and s.shape.radius_cm==34)
f.floor.FloorDist=2.7
check('valid tolerates in-range clearance jitter',s.valid() and s.shape.clearance_cm==2.1 and f.native==0 and f.traces==0)
s.shape.radius_cm=999;s.shape.half_height_cm=999;s.shape.profile='Custom';s.shape.clearance_cm=999
check('public shape mutation leaves private binding valid',s.valid())
local r=s.floor({X=1,Y=2,Z=3},0);check('floor budget',r.consumed==0 and f.native==0)
r=s.sweep({X=1,Y=2,Z=3},{X=3,Y=2,Z=3},0);check('sweep budget',not r.known and r.consumed==0 and f.traces==0)
r=s.floor({X=1,Y=2,Z=3},1);check('typed floor',r.status=='observed' and r.callbacks==1 and f.native==1)
r=s.initial({X=1,Y=2,Z=3},1);check('initial full up 10',r.known and not r.blocking and f.traceargs.r==34 and f.traceargs.hh==88 and f.traceargs.b.Z==13)
check('public shape mutation cannot alter trace profile',f.traceargs.profile=='Player')
r=s.initial({X=1,Y=2,Z=4},1);check('initial requires actual centre',not r.known and r.consumed==0 and f.traces==1)
r=s.initial({X=1,Y=2,Z=1e308},1);check('initial requires representable upward motion',not r.known and r.consumed==0 and f.traces==1)
r=s.sweep({X=1,Y=2,Z=3},{X=4,Y=2,Z=3},1);check('sweep boolean false preserved',r.known and r.blocking==false)
check('exact close',s.close() and _G.DWFloorReader.status=='closed')
local reload=assert(real(script))();local s2=reload.acquire{root='C:/gameserver',pawn=f.pawn,pc=f.pc,live=function() return f.live end}
check('factory survives reload',s2~=nil and f.regs==1);check('stale sensor cannot close new lease',not s.close());check('second close',s2.close())
f=setup();_G.DWFloorReader={version=2,status='closed'};s,why=f:acquire();check('foreign ledger refused',not s and why=='foreign_reader' and f.regs==0)
for _,mode in ipairs({'Custom','Other'}) do f=setup();f.profile=mode;s=f:acquire();check('invalid profile '..mode,not s and f.regs==0) end
f=setup();f.profile='Pawn';s=f:acquire();check('Pawn profile accepted',s~=nil);if s then s.close() end
f=setup();f.actors={object(20)};s=f:acquire();check('ignored actor rejected',not s and f.regs==0)
f=setup();f.components={[7]=object(21)};s=f:acquire();check('sparse ignored component rejected',not s and f.regs==0)
f=setup();f.cap.CopyArrayOfMoveIgnoreActors=function() return nil end;s=f:acquire();check('unknown ignore list rejected',not s and f.regs==0)
f=setup();f.radius=0;s=f:acquire();check('invalid capsule rejected',not s and f.regs==0)
f.radius=34;s=f:acquire();check('safe preflight failure permits later acquire',s~=nil and f.regs==1);if s then s.close() end
f=setup();f.floor.FloorDist=0/0;s=f:acquire();check('unknown clearance rejected',not s and f.regs==0)
f=setup();s=f:acquire();f.floor.FloorDist=5.01;check('out-of-range current clearance invalidates',not s.valid());f.floor.FloorDist=2.1;check('invalid clearance latches',not s.valid());s.close()
f=setup();s=f:acquire();f.floor.FloorDist=nil;check('unknown current clearance invalidates',not s.valid());s.close()
f=setup();f.floor.bLineTrace=true;f.floor.LineDist=3;s=f:acquire();check('line clearance used',s and s.shape.clearance_cm==3);if s then s.close() end
f=setup();f.mode='dead';s=f:acquire();check('dead refused',not s and f.regs==0)
f=setup();f.mode='air';s=f:acquire();check('airborne refused',not s and f.regs==0)
f=setup();f.pawn.RootComponent=object(40);s=f:acquire();check('root mismatch refused',not s and f.regs==0)
f=setup();s=f:acquire();f.mode='trace_bad';r=s.sweep({X=1,Y=2,Z=3},{X=2,Y=2,Z=3},1);check('native nonboolean unknown',not r.known and r.consumed==1);s.close()
f=setup();s=f:acquire();f.mode='blocked';r=s.sweep({X=1,Y=2,Z=3},{X=2,Y=2,Z=3},1);check('native blocking boolean',r.known and r.blocking==true);s.close()
f=setup();s=f:acquire();f.radius=35;r=s.floor({X=1,Y=2,Z=3},1);check('changed config stops native',r.status=='unknown' and r.consumed==0 and f.native==0);f.radius=34;check('config change latches',s.floor({X=1,Y=2,Z=3},1).status=='unknown');s.close()
f=setup();s=f:acquire();f.mode='trace_invalidate';r=s.sweep({X=1,Y=2,Z=3},{X=2,Y=2,Z=3},1);check('postcall lifecycle invalidates',not r.known and r.consumed==1);s.close()
f=setup();s=f:acquire();f.mode='floor_invalidate';r=s.floor({X=1,Y=2,Z=3},1);check('post-floor lifecycle invalidates',r.status=='unknown' and r.consumed==1 and s.close())
f=setup();s=f:acquire();f.sensor=s;f.mode='reentry';r=s.floor({X=1,Y=2,Z=3},1);check('reentrant close refused during native query',r.status=='observed' and not f.nested_close and f.nested_reason=='owner_or_busy' and s.close())
f=setup();s=f:acquire();_G.DW_PAUSE=true;local done,reason=s.close();check('pause retains exact lease',not done and reason=='paused' and _G.DWFloorReader.status=='closing');_G.DW_PAUSE=nil;check('paused close retried by owner',s.close() and _G.DWFloorReader.status=='closed')
f=setup();s=f:acquire();f.hub._state().paths[path].subs[key]=function() end
r=s.sweep({X=1,Y=2,Z=3},{X=2,Y=2,Z=3},1);check('foreign hook invalidates sweep',not r.known and r.consumed==0 and f.traces==0)
check('cleanup leaves foreign callback',not s.close() and f.hub._state().paths[path].subs[key]~=nil)
f=setup();s=f:acquire();local rec=f.hub._state().paths[path];local callback=rec.subs[key]
_G.DWWalkSenseServiceV1={version=1};check('foreign service cannot trigger cleanup',not s.close() and rec.subs[key]==callback and _G.DWFloorReader.status=='ready')
f=setup();f.cleanup_throw=true;s=f:acquire();local svc=_G.DWWalkSenseServiceV1
check('thrown true cleanup retains lease',not s and svc.failed_lease~=nil and svc.active~=nil and _G.DWFloorReader.status~='closed')
_G.loadfile=real
print(string.format('%d passed, %d failed',pass,fail));os.exit(fail==0 and 0 or 1)
