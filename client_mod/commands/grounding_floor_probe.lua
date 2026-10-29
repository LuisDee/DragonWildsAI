-- Stationary compatibility diagnostic only. DEV target and frozen source must be verified externally.
-- No result from this probe certifies a route, passage, or clearance.
local PATH = '/Script/Engine.CharacterMovementComponent:K2_FindFloor'
local KEY = 'floor_read:typed'
local API_KEY = 'DWGroundingFloorProbeAPI'
local SOURCE = 'client_mod/commands/grounding_floor_probe.lua:v1'
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function vec(v)
    if not v then return nil end
    local ok,x,y,z=pcall(function() return v.X,v.Y,v.Z end)
    if ok and finite(x) and finite(y) and finite(z) then return {X=x,Y=y,Z=z} end
end
local function same(a,b) return a and b and a.X==b.X and a.Y==b.Y and a.Z==b.Z end
local function addr(o)
    if not o or rawget(_G,'DW_PAUSE')==true then return nil end
    local ok,n=pcall(function() if o:IsValid() ~= true then return nil end; return o:GetAddress() end)
    return ok and finite(n) and n~=0 and n or nil
end
local function load(root,path)
    local f,e=loadfile(root..'/'..path); if not f then error(e) end
    return f()
end
return function(log, opts)
    local out={ok=false,status='unknown',source=SOURCE,query_budget=1,consumed=0,
        limits='stationary floor observation only; not clearance or route authority',cleanup={ok=false,reason='not_acquired'}}
    local lease,api,ledger,latched,marker,check_stable=nil,nil,nil,false,{},nil
    local root=(os.getenv('DW_CLIENT_ROOT') or 'C:/gameserver'):gsub('\\','/'):gsub('/+$','')
    local off={X=0,Y=0,Z=0}
    if opts~=nil then
        if type(opts)~='table' then out.reason='invalid_options'; return out end
        for k in pairs(opts) do if k~='offset_cm' then out.reason='invalid_options'; return out end end
        if opts.offset_cm~=nil then
            off=vec(opts.offset_cm)
            if not off or off.X*off.X+off.Y*off.Y+off.Z*off.Z>150*150 then out.reason='offset_out_of_bounds'; return out end
        end
    end
    local ok,err=xpcall(function()
        if rawget(_G,'DW_PAUSE')==true then error('paused') end
        local h=rawget(_G,'DWHookHub')
        if type(h)~='table' or type(h.paths)~='table' or type(h.counts)~='table' or not finite(h.counts.registered) then error('hub_unknown') end
        local before_count=h.counts.registered
        local initial=h.paths[PATH]
        local function healthy(r)
            return type(r)=='table' and r.native==true and not r.pending and not r.error and not r.last_error and type(r.subs)=='table'
        end
        if initial and (not healthy(initial) or next(initial.subs)~=nil) then error('hook_not_exclusive') end
        local previous=rawget(_G,API_KEY)
        local oldledger=rawget(_G,'DWFloorReader')
        if previous then
            if type(previous)~='table' or previous.version~=1 or previous.source~=SOURCE or previous.busy or
               type(previous.query)~='function' or type(previous.cleanup)~='function' or type(previous.acquire)~='function' or
               previous.hubstate~=h or previous.ledger~=oldledger or not oldledger or oldledger.status~='closed' or
               previous.record~=initial or not healthy(initial) or next(initial.subs)~=nil then error('retained_factory_unavailable') end
            api=previous
        elseif oldledger~=nil then error('foreign_reader_ledger') end
        local U=load(root,'mod/body/util.lua')
        local hub=api and api.hub or load(root,'client_mod/scripts/hookhub.lua')
        if hub._state()~=h or rawget(_G,'DWHookHub')~=h or h.paths[PATH]~=initial then error('hub_changed') end
        if not api then
            local module=load(root,'client_mod/scripts/floor_read.lua')
            local query,cleanup,acquire=module.new(hub)
            api={version=1,source=SOURCE,hub=hub,hubstate=h,query=query,cleanup=cleanup,acquire=acquire}
            if rawget(_G,API_KEY)~=nil or rawget(_G,'DWFloorReader')~=nil then error('factory_race') end
            _G[API_KEY]=api
        end
        if rawget(_G,API_KEY)~=api or api.busy then error('probe_busy') end
        api.busy=marker
        local move,arb,life=rawget(_G,'DW_MOVE'),rawget(_G,'DWArbiter'),rawget(_G,'DW_LIFE')
        if type(move)~='table' or move.mode~='idle' or not finite(move.gen) or type(arb)~='table' or arb.owner~=nil or
           type(arb.stack)~='table' or next(arb.stack)~=nil or (life~=nil and (type(life)~='table' or (life.move_death_seq~=nil and not finite(life.move_death_seq)))) then error('not_idle_or_life_unknown') end
        local gen,life_seq=move.gen,life and (life.move_death_seq or 0) or 0
        local pcs={}
        for _,pc in ipairs(U.find_all('BP_PlayerController_C',{skip_defaults=true})) do
            if U.try(function() return pc:IsLocalController() end)==true then pcs[#pcs+1]=pc end
        end
        if #pcs~=1 then error('controller_not_unique') end
        local pc=pcs[1]; local pawn=pc.Pawn; local mc=pawn and pawn.CharacterMovement
        local cap=pawn and pawn.CapsuleComponent; local health=pawn and pawn.HealthComponent
        local pcid,pid,mid,cid,hid=addr(pc),addr(pawn),addr(mc),addr(cap),addr(health)
        local world=U.world_id(root,{cache_s=0})
        local worldobj=pawn and pawn:GetWorld(); local wid=addr(worldobj)
        local shape={radius=cap:GetScaledCapsuleRadius(),half_height=cap:GetScaledCapsuleHalfHeight()}
        local pos=vec(pawn:K2_GetActorLocation()); local vel=vec(mc.Velocity)
        local dead=health:IsDead(); local hp=health:GetAuthoritativeHealth()
        if not pcid or not pid or not mid or not cid or not hid or not wid or type(world)~='string' or world=='' or world=='unknown' or
           not finite(shape.radius) or shape.radius<=0 or not finite(shape.half_height) or shape.half_height<shape.radius or not pos or not vel or
           vel.X~=0 or vel.Y~=0 or vel.Z~=0 or dead~=false or not finite(hp) or hp<=0 then error('stationary_binding_unknown') end
        local function stable()
            if latched then return false end
            local good,v=pcall(function()
                local current=rawget(_G,'DWFloorReader'); local rec=h.paths[PATH]
                local expected_count=before_count+(initial and 0 or (rec and 1 or 0))
                local allowed_record=(initial and rec==initial) or (not initial and (rec==nil or (healthy(rec) and h.counts.registered==before_count+1)))
                local allowed_ledger=(current==nil and ledger==nil) or (type(current)=='table' and current.version==2 and current.hub==hub and current.hubstate==h and
                    (not ledger or current==ledger) and (current.status=='acquiring' or current.status=='ready' or current.status=='closed'))
                local subs=true
                if rec then
                    if not healthy(rec) then subs=false else for k,fn in pairs(rec.subs) do
                        if k~=KEY or not current or fn~=current.callback then subs=false end
                    end end
                end
                return rawget(_G,'DW_PAUSE')~=true and rawget(_G,API_KEY)==api and api.busy==marker and rawget(_G,'DWHookHub')==h and
                    allowed_record and subs and allowed_ledger and h.counts.registered==expected_count and
                    rawget(_G,'DW_MOVE')==move and move.mode=='idle' and move.gen==gen and rawget(_G,'DWArbiter')==arb and arb.owner==nil and next(arb.stack)==nil and
                    rawget(_G,'DW_LIFE')==life and (life and (life.move_death_seq or 0) or 0)==life_seq and
                    addr(pc)==pcid and addr(pc.Pawn)==pid and addr(pawn)==pid and addr(pawn.CharacterMovement)==mid and addr(pawn.CapsuleComponent)==cid and addr(pawn.HealthComponent)==hid and
                    U.world_id(root,{cache_s=0})==world and addr(pawn:GetWorld())==wid and cap:GetScaledCapsuleRadius()==shape.radius and cap:GetScaledCapsuleHalfHeight()==shape.half_height and
                    same(vec(pawn:K2_GetActorLocation()),pos) and same(vec(mc.Velocity),vel) and health:IsDead()==false and health:GetAuthoritativeHealth()==hp
            end)
            if not good or v~=true then latched=true; return false end
            return true
        end
        check_stable=stable
        if not stable() then error('binding_before_acquire') end
        local why; lease,why=api.acquire({enabled=true,continuity_verified=true,lifecycle=stable})
        if not lease then error('acquire:'..tostring(why)) end
        ledger=rawget(_G,'DWFloorReader')
        if not stable() then error('binding_before_query') end
        local location={X=pos.X+off.X,Y=pos.Y+off.Y,Z=pos.Z+off.Z}
        local observation=api.query({lease=lease},mc,location,1)
        out.consumed=type(observation)=='table' and observation.consumed or 0
        if type(observation)~='table' or observation.status~='observed' or observation.consumed~=1 or observation.callbacks~=1 or not stable() then error('query_unknown') end
        out.observation=observation
        out.binding={world=world,world_address=wid,controller_address=pcid,pawn_address=pid,movement_address=mid,capsule_address=cid,
            life_sequence=life_seq,position_cm=pos,velocity_cm_s=vel,shape_cm=shape,offset_cm=off}
        out.native_registrations_before=before_count
        out.native_expected_after=before_count+(initial and 0 or 1)
    end,function(e) return tostring(e) end)
    if lease and api then
        local good,closed,why=pcall(api.cleanup,lease)
        out.cleanup={ok=good and closed==true,reason=good and why or tostring(closed)}
    end
    -- Recheck the original pose and all lifecycle bindings after cleanup too.
    if ok and (not check_stable or not check_stable()) then ok=false; err='binding_after_cleanup' end
    if api and api.busy==marker then api.busy=nil end
    if ok and api then
        local h=api.hubstate; local rec=h.paths[PATH]; local now=rawget(_G,'DWFloorReader')
        local finalized=not latched and out.cleanup.ok and now==ledger and now.status=='closed' and rec and rec.native==true and
            not rec.pending and not rec.error and not rec.last_error and type(rec.subs)=='table' and next(rec.subs)==nil and
            h.counts.registered==out.native_expected_after and rawget(_G,'DWHookHub')==h and rawget(_G,API_KEY)==api
        out.native_registrations_after=h.counts.registered
        if finalized then api.ledger=ledger; api.record=rec; out.ok=true; out.status='observed'
        else out.reason='cleanup_or_binding_unresolved'; out.observation=nil end
    else out.reason=err or 'unknown'; out.observation=nil end
    return out
end
