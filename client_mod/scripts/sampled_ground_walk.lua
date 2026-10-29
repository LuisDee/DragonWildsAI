-- Diagnostic only: sampled floor support and full-shape passage are not a
-- continuity proof or movement authority. Inputs and callback results must be
-- plain primitive tables without metatables or native objects; none are retained.
-- new{floor,sweep,overlap?,live,from_center,to_feet,radius_cm,half_height_cm,
--     step_cm,clearance_cm,clearance_line_trace,spacing_cm,budget,poll_budget,max_samples?}
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
    local gap_line=o.clearance_line_trace
    if not a or not b or not finite(radius) or radius<=0 or not finite(hh) or hh<radius or
       not finite(step) or step<=5 or not finite(gap) or gap<0 or gap>=step-5 or type(gap_line)~='boolean' or
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
    local todo,refinements,first_blocked,last_blocked=nil,0,nil,nil
    local failure_detail,query_origin=nil,nil
    local function detail(phase_name, origin, r)
        local d={phase=phase_name,query=vec(origin)}
        if type(r)=='table' then
            local f=type(r.fields)=='table' and r.fields or {}
            d.status=type(r.status)=='string' and r.status:sub(1,80) or nil
            d.callbacks=finite(r.callbacks) and r.callbacks or nil
            d.fields={}
            for _,k in ipairs({'bBlockingHit','bWalkableFloor','bLineTrace','FloorDist','LineDist'}) do
                local v=field(f,k,k:sub(1,1)=='b' and 'boolean' or 'number')
                if v~=nil then d.fields[k]=v end
            end
            local hit=type(f.hit)=='table' and f.hit or {}
            d.fields.bStartPenetrating=field(hit,'bStartPenetrating','boolean')
            d.fields.hitBlocking=field(hit,'bBlockingHit','boolean')
            d.fields.hitDistance=field(hit,'Distance','number')
            for _,k in ipairs({'ImpactNormal','Normal'}) do
                local v=hit[k]
                if type(v)=='table' and v.known==true then v=v.value end
                local n=vec(v); if n then d.fields[k]=n end
            end
        end
        return d
    end
    local function still_live()
        if latched then return false end
        local ok,v=pcall(live)
        if not ok or v~=true then latched=true; return false end
        return true
    end
    local function result(status,reason)
        return {status=status,reason=reason,consumed_total=total,spacing_cm=actual_spacing,coarse_count=n,
            sample_count=#samples,completed_samples=#samples,initial=copy(initial),start_floor=copy(start_floor),samples=copy(samples),failure_detail=copy(failure_detail),
            refinement_count=refinements,first_blocked=copy(first_blocked),last_blocked=copy(last_blocked),
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
                if not todo then
                    local t=index/n
                    todo={{X=a.X+dx*t,Y=a.Y+dy*t,depth=0}}
                end
                local task=todo[#todo]
                -- FindFloor traces vertically from the capsule location; its search range is bounded.
                -- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor
                -- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/ComputeFloorDist
                local expected={X=task.X,Y=task.Y,Z=current.Z}
                local raised={X=expected.X,Y=expected.Y,Z=current.Z+step-5}
                if not vec(expected) or not vec(raised) then
                    busy=false; return finish('unknown','invalid_derived_geometry')
                end
                pending={expected=expected,raised=raised,depth=task.depth}
                query_origin=raised
                ok,r=pcall(floor,vec(query_origin),1)
            elseif phase=='floor_fallback' then
                query_origin=pending.expected
                ok,r=pcall(floor,vec(query_origin),1)
            else
                local from,to=vec(current),pending and vec(pending.resolved)
                if not from or not to then busy=false; return finish('unknown','invalid_derived_geometry') end
                ok,r=pcall(sweep,from,to,1)
            end
            used,total=used+1,total+1
            if not still_live() then busy=false; return finish('unknown','binding_changed') end
            if not ok or type(r)~='table' or r.consumed~=1 then
                if phase=='floor' or phase=='floor_fallback' or phase=='start_floor' then failure_detail=detail(phase, phase=='start_floor' and a or query_origin, r) end
                busy=false; return finish('unknown','query_failed_or_budget_unknown')
            end
            if phase=='overlap' or phase=='sweep' then
                if r.known~=true or type(r.blocking)~='boolean' then busy=false; return finish('unknown',phase..'_unknown') end
                if r.blocking then
                    if phase=='overlap' then initial={status='blocked',reason='shape_overlap_query_blocking'} end
                    if phase=='overlap' then busy=false; return finish('blocked','overlap_blocking') end
                    local blocked={from=vec(current),to=vec(pending.resolved),depth=pending.depth}
                    if not first_blocked then first_blocked=copy(blocked) end
                    last_blocked=copy(blocked);failure_detail={phase='sweep',from=vec(blocked.from),to=vec(blocked.to),depth=blocked.depth}
                    if pending.depth>=2 then busy=false;return finish('blocked','sweep_blocking') end
                    if n+refinements+1>limit then busy=false;return finish('unknown','sample_limit') end
                    -- A blocked chord stays blocked. Adapt discrete subdivision
                    -- with fresh support at both new endpoints, not interpolated
                    -- Z or a weakened collision check:
                    -- https://ompl.kavrakilab.org/stateValidation.html
                    -- https://raw.githubusercontent.com/ompl/ompl/main/src/ompl/base/src/DiscreteMotionValidator.cpp
                    local task=todo[#todo];local depth=task.depth+1
                    todo[#todo]={X=task.X,Y=task.Y,depth=depth}
                    todo[#todo+1]={X=(current.X+task.X)/2,Y=(current.Y+task.Y)/2,depth=depth}
                    if not finite(todo[#todo].X) or not finite(todo[#todo].Y) then busy=false;return finish('unknown','invalid_derived_geometry') end
                    refinements=refinements+1;pending=nil;phase='floor'
                elseif phase=='overlap' then initial={status='clear',reason='shape_overlap_query_clear'}; phase='start_floor'
                else
                    pending.sweep='clear'; samples[#samples+1]=pending; current=vec(pending.resolved); pending=nil
                    todo[#todo]=nil
                    if #todo==0 then todo=nil;index=index+1 end
                    if index>n then
                        busy=false
                        if initial.status~='clear' then return finish('unknown','initial_overlap_unknown') end
                        local expected_z=b.Z+hh+gap
                        local delta=current.Z-expected_z
                        if not finite(expected_z) or not finite(delta) then return finish('unknown','invalid_derived_geometry') end
                        if math.abs(delta)>step then
                            failure_detail={phase='target_support',actual_z=current.Z,expected_z=expected_z}
                            return finish('unknown','target_support_mismatch')
                        end
                        return finish('sampled_clear','samples_and_full_shape_sweeps_clear')
                    end
                    phase='floor'
                end
            else
                failure_detail=detail(phase,phase=='start_floor' and a or query_origin,r)
                if r.status~='observed' or r.callbacks~=1 or type(r.fields)~='table' then busy=false; return finish('unknown','floor_unknown') end
                local f=r.fields; local hit=f.hit
                local pen=field(hit,'bStartPenetrating','boolean')
                local walk=field(f,'bWalkableFloor','boolean')
                local line=field(f,'bLineTrace','boolean')
                local blocking=field(f,'bBlockingHit','boolean')
                if pen==nil or walk==nil or line==nil or blocking==nil then busy=false; return finish('unknown','floor_fields_unknown') end
                if pen then busy=false; return finish('blocked','floor_initial_penetration') end
                if not walk then
                    local hit_blocking=field(hit,'bBlockingHit','boolean')
                    if not blocking and (hit_blocking==nil or hit_blocking~=false) then
                        busy=false; return finish('unknown','floor_hit_flags_unknown_or_inconsistent')
                    end
                    if not blocking and phase=='floor' then
                        phase='floor_fallback'
                    elseif not blocking and phase=='floor_fallback' then
                        busy=false; return finish('unknown','no_floor_support')
                    else busy=false; return finish('blocked','floor_not_walkable') end
                else
                if not blocking then busy=false; return finish('unknown','floor_flags_inconsistent') end
                local dist=field(f,line and 'LineDist' or 'FloorDist','number')
                if not finite(dist) then busy=false; return finish('unknown','floor_distance_unknown') end
                if phase=='start_floor' then
                    -- Compare like floor references against the immutable observed starting offset.
                    -- Later raised queries may naturally resolve via a different kind of floor test.
                    -- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/ComputeFloorDist?application_version=5.5
                    if line~=gap_line then busy=false; return finish('unknown','start_floor_reference_changed') end
                    if dist<0 or dist>=step-5 then busy=false; return finish('unknown','start_floor_distance_out_of_bounds') end
                    if math.abs(dist-gap)>5 then busy=false; return finish('unknown','start_floor_clearance_mismatch') end
                    start_floor={walkable=walk,start_penetrating=pen,line_trace=line,distance_cm=dist}
                    phase='floor'
                else
                    local resolved={X=query_origin.X,Y=query_origin.Y,Z=query_origin.Z-dist+gap}
                    if not vec(resolved) then busy=false; return finish('unknown','invalid_derived_geometry') end
                    if dist<0 or math.abs(resolved.Z-current.Z)>step then
                        busy=false; return finish('unknown','floor_resolution_out_of_bounds')
                    end
                    pending.query=vec(query_origin)
                    pending.fallback=phase=='floor_fallback'
                    pending.resolved=resolved
                    pending.support={walkable=walk,start_penetrating=pen,line_trace=line,distance_cm=dist}
                    phase='sweep'
                end
                failure_detail=nil
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
