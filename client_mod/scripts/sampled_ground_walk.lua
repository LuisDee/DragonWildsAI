-- Diagnostic only: sampled floor support and full-shape passage are not a
-- continuity proof or movement authority. Inputs and callback results must be
-- plain primitive tables without metatables or native objects; none are retained.
-- new{floor,sweep,overlap?,live,from_center,to_feet,radius_cm,half_height_cm,
--     step_cm,clearance_cm,spacing_cm,budget,poll_budget,max_samples?}
-- floor(center,1) returns floor_read's primitive observation; sweep(a,b,1)
-- and optional overlap(center,1) return {known=bool,blocking=bool,consumed=1}.
-- Callbacks must use the captured full capsule/profile and remain synchronous.
-- live() is the caller's latched world/life/owner/goal/config binding. A poll
-- issues at most poll_budget queries and charges even errors. Endpoints are cm.
-- API semantics: capsule-centre support, sweep/line distances and walkability:
-- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/FFindFloorResult
-- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor
-- Conceptual precedent: discrete motion checks depend on sampling resolution;
-- these samples do not establish continuous clearance or authorize movement:
-- https://ompl.kavrakilab.org/stateValidation.html
local M={}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function integer(x) return finite(x) and x%1==0 end
local function vec(v)
    if type(v)~='table' or not finite(v.X) or not finite(v.Y) or not finite(v.Z) then return nil end
    return {X=v.X,Y=v.Y,Z=v.Z}
end
local function copy(v)
    if type(v)~='table' then return v end
    local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
local function field(t,k,kind)
    local v=type(t)=='table' and t[k]
    if type(v)~='table' or v.known~=true or type(v.value)~=kind then return nil end
    if kind=='number' and not finite(v.value) then return nil end
    return v.value
end
function M.new(o)
    if type(o)~='table' or type(o.floor)~='function' or type(o.sweep)~='function' or type(o.live)~='function' or
       (o.overlap~=nil and type(o.overlap)~='function') then return nil,'invalid_callbacks' end
    local a,b=vec(o.from_center),vec(o.to_feet)
    local radius,hh,step,gap,spacing=o.radius_cm,o.half_height_cm,o.step_cm,o.clearance_cm,o.spacing_cm
    if not a or not b or not finite(radius) or radius<=0 or not finite(hh) or hh<radius or
       not finite(step) or step<=5 or not finite(gap) or gap<0 or gap>=step-5 or
       not finite(spacing) or spacing<=0 or not integer(o.budget) or o.budget<1 or o.budget>1000 or
       not integer(o.poll_budget) or o.poll_budget<1 or o.poll_budget>100 or o.poll_budget>o.budget then return nil,'invalid_geometry_or_budget' end
    local limit=o.max_samples or 128
    if not integer(limit) or limit<1 or limit>128 then return nil,'invalid_sample_limit' end
    local dx,dy=b.X-a.X,b.Y-a.Y
    local distance=math.sqrt(dx*dx+dy*dy)
    if not finite(distance) or distance<=0 then return nil,'invalid_horizontal_distance' end
    local interval=math.min(spacing,radius/2)
    local n=math.ceil(distance/interval)
    if n>limit then return nil,'sample_limit' end
    local actual_spacing=distance/n
    local floor,sweep,overlap,live=o.floor,o.sweep,o.overlap,o.live
    local budget,poll_budget=o.budget,o.poll_budget
    local current=vec(a)
    local phase=overlap and 'overlap' or 'start_floor'
    local initial={status='unknown',reason='shape_overlap_not_observed'}
    local samples={}; local total,index=0,1
    local pending,terminal,busy,latched,start_floor=nil,nil,false,false,nil
    local function still_live()
        if latched then return false end
        local ok,v=pcall(live)
        if not ok or v~=true then latched=true; return false end
        return true
    end
    local function result(status,reason)
        return {status=status,reason=reason,consumed_total=total,spacing_cm=actual_spacing,
            sample_count=n,completed_samples=#samples,initial=copy(initial),start_floor=copy(start_floor),samples=copy(samples),
            limits='sampled observations only; no continuity proof or movement authority'}
    end
    local function finish(status,reason) terminal=result(status,reason); return copy(terminal) end
    local function poll()
        if busy then latched=true; return result('unknown','reentrant_poll') end
        if terminal then
            busy=true
            if not still_live() then busy=false; return finish('unknown','binding_changed') end
            busy=false; return copy(terminal)
        end
        busy=true
        if not still_live() then busy=false; return finish('unknown','binding_changed') end
        local used=0
        while used<poll_budget and total<budget do
            if not still_live() then busy=false; return finish('unknown','binding_changed') end
            local ok,r
            if phase=='overlap' then ok,r=pcall(overlap,vec(a),1)
            elseif phase=='start_floor' then ok,r=pcall(floor,vec(a),1)
            elseif phase=='floor' then
                local t=index/n
                local end_center_z=b.Z+hh+gap
                local expected={X=a.X+dx*t,Y=a.Y+dy*t,Z=a.Z+(end_center_z-a.Z)*t}
                local raised={X=expected.X,Y=expected.Y,Z=expected.Z+step-5}
                if not finite(end_center_z) or not vec(expected) or not vec(raised) then
                    busy=false; return finish('unknown','invalid_derived_geometry')
                end
                pending={expected=expected,raised=raised}
                ok,r=pcall(floor,vec(raised),1)
            else
                local from,to=vec(current),pending and vec(pending.resolved)
                if not from or not to then busy=false; return finish('unknown','invalid_derived_geometry') end
                ok,r=pcall(sweep,from,to,1)
            end
            used,total=used+1,total+1
            if not still_live() then busy=false; return finish('unknown','binding_changed') end
            if not ok or type(r)~='table' or r.consumed~=1 then busy=false; return finish('unknown','query_failed_or_budget_unknown') end
            if phase=='overlap' or phase=='sweep' then
                if r.known~=true or type(r.blocking)~='boolean' then busy=false; return finish('unknown',phase..'_unknown') end
                if r.blocking then
                    if phase=='overlap' then initial={status='blocked',reason='shape_overlap_query_blocking'} end
                    busy=false; return finish('blocked',phase..'_blocking')
                end
                if phase=='overlap' then initial={status='clear',reason='shape_overlap_query_clear'}; phase='start_floor'
                else
                    pending.sweep='clear'; samples[#samples+1]=pending; current=vec(pending.resolved); pending=nil; index=index+1
                    if index>n then
                        busy=false
                        if initial.status~='clear' then return finish('unknown','initial_overlap_unknown') end
                        return finish('sampled_clear','samples_and_full_shape_sweeps_clear')
                    end
                    phase='floor'
                end
            else
                if r.status~='observed' or r.callbacks~=1 or type(r.fields)~='table' then busy=false; return finish('unknown','floor_unknown') end
                local f=r.fields; local hit=f.hit
                local pen=field(hit,'bStartPenetrating','boolean')
                local walk=field(f,'bWalkableFloor','boolean')
                local line=field(f,'bLineTrace','boolean')
                local blocking=field(f,'bBlockingHit','boolean')
                if pen==nil or walk==nil or line==nil or blocking==nil then busy=false; return finish('unknown','floor_fields_unknown') end
                if pen then busy=false; return finish('blocked','floor_initial_penetration') end
                if not walk then busy=false; return finish('blocked','floor_not_walkable') end
                if not blocking then busy=false; return finish('unknown','floor_flags_inconsistent') end
                local dist=field(f,line and 'LineDist' or 'FloorDist','number')
                if not finite(dist) then busy=false; return finish('unknown','floor_distance_unknown') end
                if phase=='start_floor' then
                    start_floor={walkable=walk,start_penetrating=pen,line_trace=line,distance_cm=dist}
                    phase='floor'
                else
                    local resolved={X=pending.raised.X,Y=pending.raised.Y,Z=pending.raised.Z-dist+gap}
                    if not vec(resolved) then busy=false; return finish('unknown','invalid_derived_geometry') end
                    if dist<0 or math.abs(resolved.Z-pending.expected.Z)>step then
                        busy=false; return finish('unknown','floor_resolution_out_of_bounds')
                    end
                    pending.resolved=resolved
                    pending.support={walkable=walk,start_penetrating=pen,line_trace=line,distance_cm=dist}
                    phase='sweep'
                end
            end
        end
        busy=false
        if total>=budget then return finish('unknown','budget_exhausted') end
        return result('pending','sampling')
    end
    return {poll=poll}
end
return M
