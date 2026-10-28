-- Actual hookhub and reader, fake native callback/typed wrappers; no game calls.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local hubfile,readerfile=here..'/../scripts/hookhub.lua',here..'/../scripts/floor_read.lua'
local path='/Script/Engine.CharacterMovementComponent:K2_FindFloor'
local key='floor_read:typed'
local passes,failures,registrations,unregisters,post=0,0,0,0,nil
local function check(name,v) if v then passes=passes+1 else failures=failures+1; print('FAIL '..name) end end
function RegisterHook(p,pre,cb) registrations=registrations+1; post=cb; return 1,2 end
function UnregisterHook() unregisters=unregisters+1 end
local function fake_type(x) if type(x)=='table' and x.fake then return 'userdata' end; return type(x) end
local function struct(t) t.fake=true; t.type=function() return 'UScriptStruct' end; t.IsValid=function() return true end; t.GetStructAddress=function() return 23 end; return t end
local function param(k,v) return {fake=true,type=function() return k end,get=function() return v end} end
local pos={X=1,Y=2,Z=3}
local function setup()
 _G.DWHookHub=nil; _G.DWFloorReader=nil; _G.DW_PAUSE=nil; registrations=0; unregisters=0; post=nil
 local h=dofile(hubfile); h._state().off=false; local m=dofile(readerfile); local query,close,acquire=m._new_for_test(h,fake_type)
 local f={h=h,m=m,query=query,close=close,acquire=acquire,valid=true,mode='normal'}
 f.opt={enabled=true,continuity_verified=true,lifecycle=function() return f.valid end}
 f.hit=struct{bBlockingHit=true,bStartPenetrating=false,Distance=4,ImpactPoint={X=1,Y=2,Z=3},ImpactNormal={X=0,Y=0,Z=1}}
 f.floor=struct{bBlockingHit=true,bWalkableFloor=false,bLineTrace=false,FloorDist=2,LineDist=0,HitResult=f.hit}
 f.c={IsValid=function() return true end,GetAddress=function() return 42 end}
 function f.c:K2_FindFloor(loc,out)
  if f.mode=='error' then error('engine') end
  if f.mode=='nested' then f.nested=f.query({lease=f.lease},self,pos,1) end
  if f.mode=='close' then f.close_ok,f.close_reason=f.close(f.lease) end
  if f.mode=='pause' then _G.DW_PAUSE=true end
  local obj=f.mode=='foreign' and {IsValid=function() return true end,GetAddress=function() return 99 end} or self
  local l=struct{X=loc.X+(f.mode=='wrong_location' and 1 or 0),Y=loc.Y,Z=loc.Z}
  local args={param('RemoteUnrealParam',obj),param('LocalUnrealParam',l),param('LocalUnrealParam',f.floor)}
  if f.mode=='old_callback' then f.oldcallback(table.unpack(args)) end
  if f.mode~='missing' then post(table.unpack(args)) end
  if f.mode=='double' then post(table.unpack(args)) end
  if f.mode=='lifecycle_change' then f.valid=false end
  if f.mode=='replace' then f.h._state().paths[path].subs[key]=function() end end
 end
 function f:start() local token,why=self.acquire(self.opt); self.lease=token; return token,why end
 function f:read() return self.query({lease=self.lease},self.c,pos,1) end
 return f
end
local f=setup()
check('load no native',registrations==0)
check('query needs lease',f:read().reason=='lease_unavailable' and registrations==0)
local _,why=f.acquire({enabled=true,lifecycle=function() return true end}); check('continuity declaration required',why=='not_enabled_or_lifecycle_missing' and registrations==0)
check('first explicit lease',f:start()~=nil and registrations==1)
local r=f:read(); check('typed observation',r.status=='observed' and r.fields.bWalkableFloor.known and r.fields.bWalkableFloor.value==false and r.fields.hit.bStartPenetrating.value==false)
f.hit.ImpactPoint.X=77; check('primitive copied',r.fields.hit.ImpactPoint.value.X==1)
f.floor.FloorDist=nil; r=f:read(); check('partial fields explicit',r.status=='observed' and not r.fields.FloorDist.known)
check('budget does not call native',f.query({lease=f.lease},f.c,pos,0).reason=='budget')
for _,mode in ipairs({'foreign','wrong_location','missing','double','error'}) do f.mode=mode; r=f:read(); check(mode..' unknown',r.status=='unknown' and r.consumed==1) end
f.mode='nested'; r=f:read(); check('nested request refused',r.status=='observed' and f.nested.reason=='busy_or_lifecycle')
f.mode='close'; r=f:read(); check('close during query busy',r.status=='observed' and not f.close_ok and f.close_reason=='query_active')
f.mode='normal'; local oldlease=f.lease; local oldcallback=f.h._state().paths[path].subs[key]
local foreign_fn=function() end; f.h.on(path,'other',foreign_fn)
check('foreign lease cannot close',not f.close({}) and f.h._state().paths[path].subs[key]~=nil)
check('exact close only own key',f.close(oldlease) and f.h._state().paths[path].subs.other==foreign_fn and f.h._state().paths[path].native and unregisters==0)
check('closed lease invalid',f.query({lease=oldlease},f.c,pos,1).reason=='lease_unavailable')
local record=f.h._state().paths[path]; check('reacquire same record',f:start()~=nil and f.lease~=oldlease and f.h._state().paths[path]==record and registrations==1)
check('old lease cannot close successor',not f.close(oldlease) and f:read().status=='observed')
f.mode='old_callback'; f.oldcallback=oldcallback; r=f:read(); check('late old closure cannot validate new query',r.status=='unknown')
f.mode='normal'; check('successful reacquired query',f:read().status=='observed')
_G.DW_PAUSE=true; local ok; ok,why=f.close(f.lease); check('pause defers close',not ok and why=='paused')
check('paused invalidates lease',f:read().reason=='lease_unavailable'); _G.DW_PAUSE=nil
check('cannot reacquire during deferred close',f.acquire(f.opt)==nil); check('deferred exact cleanup',f.close(f.lease) and record.subs[key]==nil)
check('reacquire after cleanup',f:start()~=nil and registrations==1)
f.valid=false; r=f:read(); check('invalidated lifecycle rejected',r.status=='unknown' and f.h._state().paths[path].subs[key]~=nil)
f.valid=true; check('invalidated lease cannot revive',f:read().reason=='lease_unavailable'); check('close invalidated lease',f.close(f.lease))
f=setup(); f:start(); f.mode='lifecycle_change'; r=f:read(); check('lifecycle loss after callback discards fields',r.status=='unknown' and r.fields==nil); check('close after lifecycle loss',f.close(f.lease))
f=setup(); f:start(); f.mode='pause'; r=f:read(); check('pause during query invalidates lease',r.status=='unknown' and f:read().reason=='lease_unavailable'); _G.DW_PAUSE=nil
check('pause query owned cleanup',f.close(f.lease))
f=setup(); local reenter=false; f.opt.lifecycle=function() if reenter then f.close(f.lease) end; return true end
f:start(); reenter=true; r=f:read(); check('lifecycle reentrant close prevents native query',r.status=='unknown' and r.consumed==0)
f=setup(); f:start(); f.mode='replace'; r=f:read(); check('subscriber replacement discards result',r.status=='unknown' and r.fields==nil); check('cleanup never removes foreign replacement',not f.close(f.lease) and f.h._state().paths[path].subs[key]~=nil)
f=setup(); f:start(); record=f.h._state().paths[path]; record.pending=true
check('ambiguous pending cleanup preserves key',not f.close(f.lease) and record.subs[key]~=nil and record.pending); record.pending=false; check('exact cleanup after pending resolved',f.close(f.lease))
f=setup(); f:start(); local address_calls=0; f.c.GetAddress=function() address_calls=address_calls+1; if address_calls==3 then f.h._state().paths[path]={native=true,subs={}} end; return 42 end
r=f:read(); check('record changed during final address discards output',r.status=='unknown' and r.fields==nil)
f=setup(); f:start(); local stale=f.lease; local foreignquery,foreignclose,foreignacquire=f.m._new_for_test(f.h,fake_type)
check('foreign factory refused',foreignacquire(f.opt)==nil and foreignquery({lease=stale},f.c,pos,1).status=='unknown' and not foreignclose(stale))
local h2=dofile(hubfile); local m2=dofile(readerfile); local _,_,ac2=m2._new_for_test(h2,fake_type); check('module reload foreign owner refused',ac2(f.opt)==nil and registrations==1)
for _,marker in ipairs({{status='closed'},{status='attempted'},{version=1,status='closed'},'corrupt'}) do f=setup(); _G.DWFloorReader=marker; check('legacy/corrupt refused',f.acquire(f.opt)==nil and registrations==0) end
f=setup(); f.h.on(path,'other',function() end,{defer=true}); local before=registrations
local l; l,why=f.acquire(f.opt); check('pending refused without retry',not l and why=='hub_ambiguous' and registrations==before and f.acquire(f.opt)==nil)
f=setup(); f.h.on(path,key,function() end); before=registrations; l,why=f.acquire(f.opt); check('key collision preserved',not l and why=='hub_ambiguous' and registrations==before and f.h._state().paths[path].subs[key]~=nil)
f=setup(); local save=RegisterHook; local attempts=0; RegisterHook=function() attempts=attempts+1; error('failure') end
l,why=f.acquire(f.opt); check('failed registration retained',not l and why=='registration_failed_or_ambiguous' and not f.acquire(f.opt) and attempts==1); RegisterHook=save
f=setup(); local real_on=f.h.on; f.h.on=function(p,k,fn,opts) _G.DW_PAUSE=true; return real_on(p,k,fn,opts) end
l,why=f.acquire(f.opt); local pending=f.h._state().paths[path]
check('pause race keeps pending marker',not l and why=='registration_failed_or_ambiguous' and pending.pending and pending.subs[key]~=nil); _G.DW_PAUSE=nil
check('pending race never retried',not f.acquire(f.opt) and registrations==0)
f=setup(); f:start(); oldlease=f.lease; check('close before record replacement',f.close(oldlease))
record=f.h._state().paths[path]; f.h._state().paths[path]={native=true,subs={}}; check('replaced record refused',not f.acquire(f.opt) and registrations==1)
f=setup(); f:start(); oldlease=f.lease; check('close before preflight race',f.close(oldlease)); record=f.h._state().paths[path]
f.opt.lifecycle=function() record.native=false; return true end; check('record changed in predicate cannot register',not f.acquire(f.opt) and registrations==1)
check('never unregister',unregisters==0)
print(string.format('%d passed, %d failed',passes,failures)); os.exit(failures==0 and 0 or 1)
