-- Native sensor for sampled_ground_walk; no movement authority. Loading is inert.
-- Caller owns a permanently latched world/life/owner/goal predicate and controls
-- client lifecycle, game thread and budgets. Initial is a +10 cm full-capsule
-- sweep, NOT a general overlap API; it can conservatively reject a low ceiling.
local M={}
local SERVICE='DWWalkSenseServiceV1'
local PATH='/Script/Engine.CharacterMovementComponent:K2_FindFloor'
local KEY='floor_read:typed'
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function vector(v)
    if not v then return nil end
    local ok,x,y,z=pcall(function() return v.X,v.Y,v.Z end)
    if ok and finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function same(a,b) return a and b and a.X==b.X and a.Y==b.Y and a.Z==b.Z end
local function address(o)
    if not o or rawget(_G,'DW_PAUSE')==true then return nil end
    local ok,n=pcall(function() if o:IsValid()~=true then return nil end; return o:GetAddress() end)
    return ok and finite(n) and n~=0 and n or nil
end
local function count(a)
    if type(a)=='table' then
        -- Reject sparse or otherwise unrecognised array wrappers, not only #a.
        return next(a)==nil and 0 or nil
    end
    if not a then return nil end
    local ok,n=pcall(function() return a:GetArrayNum() end)
    return ok and finite(n) and n==0 and 0 or nil
end
local function load(root,path)
    local f=assert(loadfile(root..'/'..path)); return f()
end
local function clearance(mc)
    local f=mc.CurrentFloor
    if not f or f:type()~='UScriptStruct' or f:IsValid()~=true or not finite(f:GetStructAddress()) or f:GetStructAddress()==0 then return nil end
    if f.bBlockingHit~=true or f.bWalkableFloor~=true or type(f.bLineTrace)~='boolean' then return nil end
    local d=f.bLineTrace and f.LineDist or f.FloorDist
    if not finite(d) or d<0 or d>5 then return nil end
    return d
end
function M.acquire(o)
    if type(o)~='table' or type(o.root)~='string' or o.root=='' or not o.pawn or not o.pc or type(o.live)~='function' then return nil,'invalid_request' end
    if rawget(_G,'DW_PAUSE')==true then return nil,'paused' end
    local root=o.root:gsub('\\','/'):gsub('/+$','')
    local service=rawget(_G,SERVICE)
    if service then
        if type(service)~='table' or service.version~=1 or service.root~=root or service.active or service.busy then return nil,'service_unavailable' end
        local ledger=rawget(_G,'DWFloorReader')
        if service.ledger then
            if ledger~=service.ledger or service.ledger.status~='closed' then return nil,'reader_ownership_unknown' end
        elseif ledger~=nil then return nil,'reader_ownership_unknown' end
    elseif rawget(_G,'DWFloorReader')~=nil then return nil,'foreign_reader' end
    local marker={}
    if service then service.busy=marker else
        service={version=1,root=root,busy=marker}; _G[SERVICE]=service
    end
    local latched=false
    local pawn,pc,live=o.pawn,o.pc,o.live
    local ok,shape,ctx=pcall(function()
        if live()~=true or rawget(_G,'DW_PAUSE')==true then error('lifecycle') end
        local mc,cap,hp=pawn.CharacterMovement,pawn.CapsuleComponent,pawn.HealthComponent
        local pid,cid,mid,hid,pcid=address(pawn),address(cap),address(mc),address(hp),address(pc)
        if not pid or not cid or not mid or not hid or not pcid or address(pc.Pawn)~=pid or address(pawn.RootComponent)~=cid then error('identity') end
        local apos,cpos=vector(pawn:K2_GetActorLocation()),vector(cap:K2_GetComponentLocation())
        if not same(apos,cpos) then error('capsule_origin') end
        local radius,hh,step=cap:GetScaledCapsuleRadius(),cap:GetScaledCapsuleHalfHeight(),mc.MaxStepHeight
        local profile=cap:GetCollisionProfileName():ToString()
        local gap=clearance(mc)
        if not finite(radius) or radius<=0 or not finite(hh) or hh<radius or not finite(step) or step<=5 or not gap or gap>=step-5 or
            (profile~='Player' and profile~='Pawn') or count(cap:CopyArrayOfMoveIgnoreActors())~=0 or count(cap:CopyArrayOfMoveIgnoreComponents())~=0 then error('shape_or_collision') end
        local dead,health,ground=hp:IsDead(),hp:GetAuthoritativeHealth(),mc:IsMovingOnGround()
        if dead~=false or not finite(health) or health<=0 or ground~=true then error('life_or_ground') end
        return {radius_cm=radius,half_height_cm=hh,step_cm=step,clearance_cm=gap,profile=profile},
            {mc=mc,cap=cap,hp=hp,pid=pid,cid=cid,mid=mid,hid=hid,pcid=pcid}
    end)
    if not ok then service.busy=nil; return nil,'preflight:'..tostring(shape) end
    local function stable()
        if latched then return false end
        local good,result=pcall(function()
            if rawget(_G,'DW_PAUSE')==true or rawget(_G,SERVICE)~=service or service.active~=marker or
               (service.busy~=nil and service.busy~=marker) or live()~=true then return false end
            local cap,mc,hp=ctx.cap,ctx.mc,ctx.hp
            if ctx.lease then
                local ledger=rawget(_G,'DWFloorReader')
                local hub=rawget(_G,'DWHookHub')
                local rec=type(hub)=='table' and type(hub.paths)=='table' and hub.paths[PATH] or nil
                if ledger~=service.ledger or not ledger or ledger.status~='ready' or ledger.lease~=ctx.lease or
                   hub~=ledger.hubstate or rec~=ledger.record or not rec or rec.native~=true or rec.pending or rec.error or rec.last_error or
                   type(rec.subs)~='table' or rec.subs[KEY]~=ledger.callback then return false end
            end
            local a,b=vector(pawn:K2_GetActorLocation()),vector(cap:K2_GetComponentLocation())
            return address(pc)==ctx.pcid and address(pc.Pawn)==ctx.pid and address(pawn)==ctx.pid and address(pawn.RootComponent)==ctx.cid and
                address(pawn.CapsuleComponent)==ctx.cid and address(pawn.CharacterMovement)==ctx.mid and address(pawn.HealthComponent)==ctx.hid and
                same(a,b) and cap:GetScaledCapsuleRadius()==shape.radius_cm and cap:GetScaledCapsuleHalfHeight()==shape.half_height_cm and
                mc.MaxStepHeight==shape.step_cm and cap:GetCollisionProfileName():ToString()==shape.profile and
                count(cap:CopyArrayOfMoveIgnoreActors())==0 and count(cap:CopyArrayOfMoveIgnoreComponents())==0 and
                clearance(mc)~=nil and hp:IsDead()==false and finite(hp:GetAuthoritativeHealth()) and hp:GetAuthoritativeHealth()>0 and
                mc:IsMovingOnGround()==true and live()==true and rawget(_G,'DW_PAUSE')~=true and
                rawget(_G,SERVICE)==service and service.active==marker and (service.busy==nil or service.busy==marker)
        end)
        if not good or result~=true then latched=true; return false end
        return true
    end
    service.active=marker
    local good,why=pcall(function()
        if not service.hub then
            local hub=load(root,'client_mod/scripts/hookhub.lua')
            local reader=load(root,'client_mod/scripts/floor_read.lua')
            if rawget(_G,'DWFloorReader')~=nil or rawget(_G,SERVICE)~=service or service.busy~=marker then error('factory_race') end
            service.hub=hub; service.query,service.cleanup,service.acquire=reader.new(hub)
        end
        if not stable() then error('binding_changed') end
        local k=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
        local fn=StaticFindObject('/Script/Engine.KismetSystemLibrary:CapsuleTraceSingleByProfile')
        if not address(k) or not address(fn) then error('trace_unavailable') end
        ctx.ksl=k; ctx.fn=fn; ctx.profile=FName(shape.profile)
        if not ctx.profile or not stable() then error('binding_changed') end
        local lease,reason=service.acquire({enabled=true,continuity_verified=true,lifecycle=stable})
        if not lease then error('floor_acquire:'..tostring(reason)) end
        ctx.lease=lease; service.ledger=rawget(_G,'DWFloorReader')
        if not stable() then error('binding_changed') end
    end)
    if not good then
        if ctx.lease then
            local called,closed=pcall(service.cleanup,ctx.lease)
            if not called or closed~=true then service.failed_lease=ctx.lease else service.active=nil end
        else service.active=nil end
        service.busy=nil
        return nil,'acquire:'..tostring(why)
    end
    service.busy=nil
    local sensor={shape={radius_cm=shape.radius_cm,half_height_cm=shape.half_height_cm,step_cm=shape.step_cm,clearance_cm=shape.clearance_cm,profile=shape.profile}}
    local function begin(remaining)
        if not finite(remaining) or remaining<1 then return false,'budget' end
        if service.busy then return false,'binding_or_busy' end
        service.busy=marker
        if not stable() then
            if rawget(_G,SERVICE)==service and service.busy==marker then service.busy=nil end
            return false,'binding_changed'
        end
        return true
    end
    local function unknown(reason,consumed) return {status='unknown',reason=reason,consumed=consumed} end
    local function release()
        if rawget(_G,SERVICE)~=service or service.busy~=marker then latched=true; return false end
        service.busy=nil; return true
    end
    -- Fresh binding/configuration/ground read only: no floor or sweep query.
    -- This is not corridor freshness, movement authority, or a model outcome.
    function sensor.valid()
        local admitted,reason=begin(1)
        if not admitted then return false,reason end
        local current=stable(); if not release() then current=false end
        if current then return true end
        return false,'binding_changed'
    end
    function sensor.floor(center,remaining)
        local pos=vector(center); if not pos then return unknown('location',0) end
        local admitted,reason=begin(remaining); if not admitted then return unknown(reason,0) end
        local success,r=pcall(service.query,{lease=ctx.lease},ctx.mc,pos,1)
        local current=stable(); if not release() then current=false end
        if not success or type(r)~='table' then return unknown('floor_error',1) end
        if not current then return unknown('binding_changed',r.consumed==0 and 0 or 1) end
        return r
    end
    local function trace(a,b,remaining,initial)
        a,b=vector(a),vector(b)
        if not a or not b then return {known=false,reason='location',consumed=0} end
        local admitted,reason=begin(remaining); if not admitted then return {known=false,reason=reason,consumed=0} end
        if initial then
            local ok,current=pcall(function() return vector(pawn:K2_GetActorLocation()) end)
            if not ok or not same(a,current) or not stable() then
                release(); return {known=false,reason='initial_position_changed',consumed=0}
            end
        end
        local hit={}; local color={R=0,G=0,B=0,A=0}
        local ok,result=pcall(function() return ctx.ksl:CapsuleTraceSingleByProfile(pawn,a,b,shape.radius_cm,shape.half_height_cm,ctx.profile,false,{},0,hit,true,color,color,0.0) end)
        local current=stable(); if not release() then current=false end
        if not ok or type(result)~='boolean' or not current then return {known=false,reason=current and 'trace_unknown' or 'binding_changed',consumed=1} end
        return {known=true,blocking=result,consumed=1}
    end
    function sensor.sweep(a,b,remaining) return trace(a,b,remaining) end
    function sensor.initial(center,remaining)
        local a=vector(center)
        if not a or not finite(a.Z+10) or a.Z+10<=a.Z then return {known=false,reason='location',consumed=0} end
        return trace(a,{X=a.X,Y=a.Y,Z=a.Z+10},remaining,true)
    end
    function sensor.close()
        if rawget(_G,SERVICE)~=service or service.active~=marker or service.busy then return false,'owner_or_busy' end
        latched=true; service.busy=marker
        local called,closed,reason=pcall(service.cleanup,ctx.lease)
        if rawget(_G,SERVICE)~=service or service.busy~=marker or service.active~=marker then return false,'ownership_changed' end
        service.busy=nil
        if called and closed==true then service.active=nil; service.failed_lease=nil; return true end
        service.failed_lease=ctx.lease
        return false,called and reason or 'cleanup_error'
    end
    return sensor
end
-- Exact-lease recovery if acquisition was interrupted after obtaining a lease.
-- No registration, reset or native unregistration is attempted here.
function M.cleanup_pending()
    local s=rawget(_G,SERVICE)
    if type(s)~='table' or s.version~=1 or not s.failed_lease or s.busy or type(s.cleanup)~='function' then return false,'no_pending_lease' end
    local marker={}; s.busy=marker
    local ok,closed,reason=pcall(s.cleanup,s.failed_lease)
    if rawget(_G,SERVICE)~=s or s.busy~=marker then return false,'ownership_changed' end
    s.busy=nil
    if ok and closed==true then s.failed_lease=nil; s.active=nil; return true end
    return false,ok and reason or 'cleanup_error'
end
return M
