-- Exercises the actual hookhub with fake typed engine parameters; no native calls.
local here = debug.getinfo(1,"S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local hubfile, readerfile = here.."/../scripts/hookhub.lua", here.."/../scripts/floor_read.lua"
local path = "/Script/Engine.CharacterMovementComponent:K2_FindFloor"
local passes, fails, registrations, unregisters, post = 0,0,0,0,nil
local function check(name, v) if v then passes=passes+1 else fails=fails+1; print("FAIL "..name) end end
function RegisterHook(p,pre,cb) registrations=registrations+1; post=cb; return 1,2 end
function UnregisterHook() unregisters=unregisters+1 end
local function fake_type(x) if type(x)=="table" and x.fake then return "userdata" end return type(x) end
local function struct(values)
    values.fake=true; values.type=function() return "UScriptStruct" end
    values.IsValid=function() return true end; values.GetStructAddress=function() return 23 end
    return values
end
local function param(kind,obj) return {fake=true,type=function() return kind end,get=function() return obj end} end
local function reset()
    _G.DWHookHub=nil; _G.DWFloorReader=nil; _G.DW_PAUSE=nil; post=nil
    local h=dofile(hubfile); h._state().off=false
    return h,dofile(readerfile)
end
local function setup()
    local h,m=reset(); local n=m._new_for_test(h,fake_type)
    local hit=struct{bBlockingHit=true,bStartPenetrating=false,Distance=4,ImpactPoint={X=1,Y=2,Z=3},ImpactNormal={X=0,Y=0,Z=1}}
    local floor=struct{bBlockingHit=true,bWalkableFloor=false,bLineTrace=false,FloorDist=2,LineDist=0,HitResult=hit}
    local c={IsValid=function() return true end,GetAddress=function() return 42 end}
    local behavior="normal"
    function c:K2_FindFloor(loc, ignored)
        if behavior=="error" then error("engine") end
        local obj=behavior=="foreign" and {IsValid=function() return true end,GetAddress=function() return 99 end} or self
        local l=struct{X=loc.X,Y=loc.Y,Z=loc.Z}; if behavior=="wrong_location" then l.X=l.X+1 end
        local args={param("RemoteUnrealParam",obj),param("LocalUnrealParam",l),param("LocalUnrealParam",floor)}
        if behavior~="missing" then post(table.unpack(args)) end
        if behavior=="double" then post(table.unpack(args)) end
        if behavior=="pause" then _G.DW_PAUSE=true end
    end
    return h,n,c,floor,hit,function(x) behavior=x end
end
local h,n,c,floor,hit,behavior=setup()
local opt={enabled=true,lifecycle=function() return true end}; local pos={X=1,Y=2,Z=3}
check("load is opt in", registrations==0 and post==nil)
check("budget blocks registration", n(opt,c,pos,0).reason=="budget" and registrations==0)
local r=n(opt,c,pos,1)
check("observed with correlated typed fields", r.status=="observed" and r.callbacks==1 and r.fields.bWalkableFloor.known and r.fields.bWalkableFloor.value==false)
check("typed hit and vector", r.fields.hit.bStartPenetrating.value==false and r.fields.hit.ImpactPoint.value.X==1)
hit.ImpactPoint.X=77; check("retained vectors copied", r.fields.hit.ImpactPoint.value.X==1)
floor.FloorDist=nil; r=n(opt,c,pos,1); check("partial field unknown", r.status=="observed" and not r.fields.FloorDist.known and r.fields.bBlockingHit.value)
for _, mode in ipairs({"foreign","wrong_location","missing","double","error","pause"}) do
    behavior(mode); r=n(opt,c,pos,1); check(mode.." rejected", r.status=="unknown" and r.consumed==1); _G.DW_PAUSE=nil
end
behavior("normal"); opt.lifecycle=function() return false end
check("lifecycle fails closed", n(opt,c,pos,1).status=="unknown")
opt.lifecycle=function() return true end
local h2=dofile(hubfile); local m2=dofile(readerfile); local n2=m2._new_for_test(h2,fake_type)
check("hot reload never registers again", n2(opt,c,pos,1).status=="unknown" and registrations==1)
-- Same hub instance is reusable without registering again.
check("same hub reuses native hook", n(opt,c,pos,1).status=="observed" and registrations==1)
check("never unregister", unregisters==0)
h,n,c=setup(); local foreign=0
h.on(path,"other",function() foreign=foreign+1 end)
local before=registrations; r=n(opt,c,pos,1)
check("other subscriber retained", r.status=="observed" and foreign==1 and registrations==before and h._state().paths[path].subs.other~=nil)
h,n,c=setup(); h.on(path,"other",function() end,{defer=true}); before=registrations
check("pending hub refuses without retry", n(opt,c,pos,1).reason=="hub_ambiguous" and registrations==before)
check("failed attempt remains failed", n(opt,c,pos,1).reason=="registration_unavailable" and registrations==before)
h,n,c=setup(); h.on(path,"floor_read:typed",function() end); before=registrations
check("key collision preserved", n(opt,c,pos,1).reason=="hub_ambiguous" and registrations==before and h._state().paths[path].subs["floor_read:typed"]~=nil)
h,n,c=setup(); local alive=true; opt.lifecycle=function() return alive end
local original=c.K2_FindFloor
function c:K2_FindFloor(loc,out) original(self,loc,out); alive=false end
r=n(opt,c,pos,1); check("lifecycle change after callback discards fields",r.status=="unknown" and r.fields==nil and r.consumed==1)
h,n,c=setup(); opt.lifecycle=function() return true end
original=c.K2_FindFloor; local nested
function c:K2_FindFloor(loc,out) nested=n(opt,self,pos,1); original(self,loc,out) end
r=n(opt,c,pos,1); check("nested query cannot change owner",nested.reason=="busy_or_lifecycle" and nested.consumed==0 and r.status=="observed")
h,n,c=setup(); original=c.K2_FindFloor
function c:K2_FindFloor(loc,out) original(self,loc,out); h._state().paths[path].subs["floor_read:typed"]=function() end end
r=n(opt,c,pos,1); check("subscriber replaced during call invalidates result",r.status=="unknown" and r.fields==nil)
h,n,c=setup(); local saved=RegisterHook; local attempts=0
RegisterHook=function() attempts=attempts+1; error("registration failure") end
r=n(opt,c,pos,1); check("failed native registration is unknown",r.reason=="registration_failed_or_ambiguous")
check("failed native registration is never retried",n(opt,c,pos,1).reason=="registration_unavailable" and attempts==1)
RegisterHook=saved
h,n,c=setup(); local real_on=h.on; local other=function() end
h.on=function(p,k,fn,opts)
    _G.DW_PAUSE=true
    local ok,why=real_on(p,k,fn,opts)
    h._state().paths[p].subs.other=other
    return ok,why
end
before=registrations; r=n(opt,c,pos,1)
local pending=h._state().paths[path]
check("pause inside on leaves pending and other subscriber",r.status=="unknown" and pending.pending==true and pending.subs.other==other and pending.subs["floor_read:typed"]==nil)
_G.DW_PAUSE=nil
check("ambiguous pending is never retried by reader",n(opt,c,pos,1).status=="unknown" and registrations==before and pending.pending==true)
-- Do not flush: another owner controls resolution of hookhub's pending state.
h,m=reset(); n,cleanup=m._new_for_test(h,fake_type)
local alive=true; opt.lifecycle=function() return alive end
local point=struct{X=1,Y=2,Z=3}; local output=struct{bBlockingHit=true}
c={IsValid=function() return true end,GetAddress=function() return 42 end}
local inner_ok,inner_reason
function c:K2_FindFloor()
    inner_ok,inner_reason=cleanup()
    post(param("RemoteUnrealParam",self),param("LocalUnrealParam",point),param("LocalUnrealParam",output))
end
h.on(path,"other",other)
r=n(opt,c,pos,1)
check("cleanup refuses active query",r.status=="observed" and inner_ok==false and inner_reason=="query_active")
local _,foreign_cleanup=m._new_for_test(h,fake_type)
local foreign_cleaned,foreign_reason=foreign_cleanup()
check("other factory cannot clean owner subscriber",not foreign_cleaned and foreign_reason=="owner_unknown")
_G.DW_PAUSE=true; local cleaned,why=cleanup(); _G.DW_PAUSE=nil
check("cleanup refuses pause",cleaned==false and why=="paused")
local record=h._state().paths[path]; local ours=record.subs["floor_read:typed"]
record.subs["floor_read:typed"]=other
cleaned,why=cleanup(); check("cleanup refuses changed subscriber",not cleaned and why=="ownership_changed" and record.subs["floor_read:typed"]==other)
record.subs["floor_read:typed"]=ours
before=registrations; cleaned,why=cleanup()
check("cleanup removes only own subscriber",cleaned and record.subs["floor_read:typed"]==nil and record.subs.other==other and record.native and registrations==before and unregisters==0)
check("closed reader never reregisters",n(opt,c,pos,1).reason=="registration_unavailable" and registrations==before)
print(string.format("%d passed, %d failed",passes,fails)); os.exit(fails==0 and 0 or 1)
