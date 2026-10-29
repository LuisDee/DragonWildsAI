-- Short-lived sampled walking guard. Plain primitive callback/data contract.
-- This provides bounded observations, not movement, floor-continuity proof or
-- goal arrival. Caller owns actual inputs, lifecycle, physics and progress.
-- read_pose() is required: return the current capsule-centre vector while the
-- caller's world/life/owner/goal binding is valid. It is reread before clear.
-- Adapted pattern: bounded forward collision checking followed by fresh feedback.
-- Nav2 is conceptual precedent, not a UE backend or copied controller/geometry:
-- https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/README.md
-- https://github.com/ros-navigation/navigation2/blob/main/nav2_regulated_pure_pursuit_controller/src/collision_checker.cpp
local M={}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function integer(n) return finite(n) and n%1==0 end
local function vec(v)
    if type(v)~='table' or not finite(v.X) or not finite(v.Y) or not finite(v.Z) then return nil end
    return {X=v.X,Y=v.Y,Z=v.Z}
end
local function eq(a,b) return a and b and a.X==b.X and a.Y==b.Y and a.Z==b.Z end
local function dist(a,b)
    local dx,dy=a.X-b.X,a.Y-b.Y
    local d=math.sqrt(dx*dx+dy*dy); if finite(d) then return d end
end
function M.new(o)
    if type(o)~='table' or type(o.acquire)~='function' or type(o.live)~='function' or type(o.read_pose)~='function' or
       (o.read_time~=nil and type(o.read_time)~='function') or type(o.sample_module)~='table' or type(o.sample_module.new)~='function' then return nil,'invalid_callbacks' end
    local h,ttl,corridor,drift,reserve=o.horizon_cm,o.ttl_s,o.corridor_cm,o.drift_cm,o.reserve_cm
    local budget,poll_budget,max_scan,max_resets=o.budget,o.poll_budget,o.max_scan_s,o.max_resets
    if not finite(h) or h<=0 or h>100 or not finite(ttl) or ttl<=0 or not finite(corridor) or corridor<=0 or
       not finite(drift) or drift<0 or not finite(reserve) or reserve<0 or not integer(budget) or budget<1 or
       not integer(poll_budget) or poll_budget<1 or poll_budget>4 or not finite(max_scan) or max_scan<=0 or
       not integer(max_resets) or max_resets<0 then return nil,'invalid_limits' end
    local acquire,live,read_pose,sampler_new=o.acquire,o.live,o.read_pose,o.sample_module.new
    local sensor,scan,cache,aim,terminal=nil,nil,nil,nil,nil
    local total,resets,reset_total,last_t=0,0,0,nil
    local scan_duration,oldest_started,completed_at,refresh_cause=nil,nil,nil,nil
    local refinement=nil
    local locked,latched,closed=false,false,false
    local function metadata(r)
        if r.refinement_count==nil and r.first_blocked==nil and r.last_blocked==nil then return {} end
        if not integer(r.refinement_count) or r.refinement_count<0 or r.refinement_count>127 then return nil end
        local function segment(s)
            if s==nil then return nil end
            if type(s)~='table' or not integer(s.depth) or s.depth<0 or s.depth>2 then return false end
            local a,b=vec(s.from),vec(s.to)
            if not a or not b then return false end
            return {from=a,to=b,depth=s.depth}
        end
        local first,last=segment(r.first_blocked),segment(r.last_blocked)
        if first==false or last==false or (first==nil)~=(last==nil) or (r.refinement_count>0 and not first) then return nil end
        return {count=r.refinement_count,first_blocked=first,last_blocked=last}
    end
    local function copy_metadata(m)
        if not m then return nil end
        local function segment(s) return s and {from=vec(s.from),to=vec(s.to),depth=s.depth} end
        return {count=m.count,first_blocked=segment(m.first_blocked),last_blocked=segment(m.last_blocked)}
    end
    local function result(status,reason)
        return {status=status,reason=reason,consumed_total=total,scan_duration_s=scan_duration,
            refinement=copy_metadata(refinement),
            cache_completion_age_s=completed_at and last_t and last_t-completed_at or nil,
            oldest_observation_age_s=oldest_started and last_t and last_t-oldest_started or nil,
            coast_reset_streak=resets,coast_reset_total=reset_total,refresh_cause=refresh_cause}
    end
    local function clock(fallback)
        local ok,t=true,fallback
        if o.read_time then ok,t=pcall(o.read_time) end
        if not ok or not finite(t) then return nil,'clock_unknown' end
        if last_t and t<last_t then return nil,'clock_reversed' end
        last_t=t; return t
    end
    local function alive()
        if latched then return false end
        local ok,v=pcall(live)
        if not ok or v~=true then latched=true; return false end
        return true
    end
    local function release()
        if not sensor then return true end
        local ok,closed_ok=pcall(sensor.close)
        if not ok or closed_ok~=true then return false end
        sensor=nil; scan=nil; cache=nil
        return true
    end
    local function fail(reason,status)
        if reason=='binding_changed' then refinement=nil end
        terminal={status=status or 'unknown',reason=reason}
        if not release() then terminal={status='unknown',reason='cleanup_pending'} end
        -- Cleanup and clock callbacks can invalidate the captured lifecycle.
        -- Preserve accounting/cleanup status but never return stale evidence.
        if not alive() then refinement=nil end
        return result(terminal.status,terminal.reason)
    end
    local function valid_sensor()
        if not sensor or type(sensor.valid)~='function' then return false end
        local ok,v=pcall(sensor.valid)
        return ok and v==true and alive()
    end
    local function fresh_pose()
        local ok,p=pcall(read_pose)
        p=ok and vec(p) or nil
        if not p or not alive() then return nil end
        return p
    end
    -- Closest projection on the observed horizontal polyline, with interpolated
    -- capsule centre height. It is a bounded control corridor, not a proof.
    local function inside(me,target)
        local points=cache and cache.points
        if not points or #points<2 then return false end
        local best,best_z,best_along,total_len=math.huge,nil,0,0
        for i=2,#points do
            local a,b=points[i-1],points[i]
            local dx,dy=b.X-a.X,b.Y-a.Y
            local len=math.sqrt(dx*dx+dy*dy)
            if not finite(len) then return false end
            if len>0 then
                local t=((me.X-a.X)*dx+(me.Y-a.Y)*dy)/(len*len)
                if not finite(t) then return false end
                t=math.max(0,math.min(1,t))
                local x,y=a.X+t*dx,a.Y+t*dy
                local lateral=math.sqrt((me.X-x)^2+(me.Y-y)^2)
                local z=a.Z+t*(b.Z-a.Z)
                if not finite(lateral) or not finite(z) then return false end
                if lateral<best then best,best_z,best_along=lateral,z,total_len+t*len end
                total_len=total_len+len
            end
        end
        local rem=dist(me,target)
        if not rem or not best_z or not finite(total_len) then return false end
        return best<=corridor and math.abs(me.Z-best_z)<=cache.step_cm and
            total_len-best_along+1e-7>=math.min(reserve,rem)
    end
    local function check(me,target,t)
        me,target=vec(me),vec(target)
        if not me or not target or not finite(t) then return result('unknown','invalid_input') end
        if locked then latched=true; return result('unknown','reentrant_check') end
        if closed then return result('unknown','guard_closed') end
        locked=true
        local function done(r) locked=false; return r end
        if last_t and t<last_t then return done(fail('clock_reversed')) end
        last_t=t
        if terminal and terminal.reason=='cleanup_pending' then return done(result('unknown','cleanup_pending')) end
        if not alive() then refinement=nil;return done(fail('binding_changed')) end
        if aim and not eq(aim,target) then
            if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
            terminal=nil; aim=nil; refinement=nil;refresh_cause='target_changed'
            return done(result('pending','target_changed'))
        end
        if terminal then return done(result(terminal.status,terminal.reason)) end
        if cache then
            local pose
            if t-cache.completed_at<ttl and valid_sensor() then
                pose=fresh_pose()
                if not pose then return done(fail(latched and 'binding_changed' or 'position_unknown')) end
            end
            if pose and inside(pose,target) then
                if not alive() then return done(fail('binding_changed')) end
                local fresh,why=clock(t); if not fresh then return done(fail(why)) end
                if not alive() then return done(fail('binding_changed')) end
                if fresh-cache.completed_at<ttl then return done(result('clear','sampled_corridor')) end
            end
            if latched then return done(fail('binding_changed')) end
            refresh_cause=(last_t-cache.completed_at>=ttl) and 'cache_expired' or (not pose and 'sensor_invalid' or 'outside_corridor')
            if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
            return done(result('pending','refresh_required'))
        end
        if scan then
            local delta=dist(me,scan.start)
            if not delta or not finite(me.Z-scan.start.Z) then return done(fail('invalid_derived_geometry')) end
            if delta>drift or math.abs(me.Z-scan.start.Z)>drift then
                resets=resets+1; reset_total=reset_total+1; refresh_cause='coast'
                if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
                if resets>max_resets then return done(fail('coast_reset_limit')) end
                return done(result('pending','coast_reset'))
            elseif t-scan.started>max_scan then return done(fail('scan_timeout')) end
        end
        if total>=budget then return done(fail('budget_exhausted')) end
        if not scan then
            refinement=nil
            if not alive() then return done(fail('binding_changed')) end
            aim=vec(target)
            local d=dist(me,target)
            if not d or d<=0 then return done(fail('invalid_horizontal_distance')) end
            local ok,s=pcall(acquire,alive)
            if not ok or type(s)~='table' then return done(fail('sensor_unavailable')) end
            sensor=s
            if not alive() then return done(fail('binding_changed')) end
            local shape=s.shape
            -- Preserve the supplied floor-test reference, never invent sweep semantics for an unknown kind.
            -- https://dev.epicgames.com/documentation/en-us/unreal-engine/python-api/class/FindFloorResult?application_version=5.5
            if type(shape)~='table' or not finite(shape.radius_cm) or shape.radius_cm<=0 or
               not finite(shape.half_height_cm) or shape.half_height_cm<shape.radius_cm or
               not finite(shape.step_cm) or shape.step_cm<=5 or not finite(shape.clearance_cm) or shape.clearance_cm<0 or shape.clearance_cm>=shape.step_cm-5 or
               type(shape.clearance_line_trace)~='boolean' or
               type(s.floor)~='function' or type(s.sweep)~='function' or type(s.initial)~='function' or type(s.close)~='function' then return done(fail('sensor_shape_unknown')) end
            shape={radius_cm=shape.radius_cm,half_height_cm=shape.half_height_cm,step_cm=shape.step_cm,
                clearance_cm=shape.clearance_cm,clearance_line_trace=shape.clearance_line_trace}
            local ratio=math.min(1,h/d)
            local start_feet=me.Z-shape.half_height_cm-shape.clearance_cm
            local far={X=me.X+(target.X-me.X)*ratio,Y=me.Y+(target.Y-me.Y)*ratio,Z=start_feet+(target.Z-start_feet)*ratio}
            if not finite(start_feet) or not vec(far) then return done(fail('invalid_derived_geometry')) end
            local remaining=math.min(budget-total,1000)
            local per=math.min(poll_budget,remaining)
            local good,job,why=pcall(sampler_new,{floor=s.floor,sweep=s.sweep,overlap=s.initial,live=alive,from_center=vec(me),to_feet=far,
                radius_cm=shape.radius_cm,half_height_cm=shape.half_height_cm,step_cm=shape.step_cm,clearance_cm=shape.clearance_cm,
                clearance_line_trace=shape.clearance_line_trace,
                spacing_cm=shape.radius_cm/2,budget=remaining,poll_budget=per})
            if not good or type(job)~='table' or type(job.poll)~='function' then return done(fail('sample_init:'..tostring(why or 'unknown'))) end
            scan={job=job,start=vec(me),far=vec(far),started=t,consumed=0,step_cm=shape.step_cm,limit=remaining,per=per}
            oldest_started=t; completed_at=nil; scan_duration=nil
        end
        local ok,r=pcall(scan.job.poll)
        if not ok or type(r)~='table' or not integer(r.consumed_total) or r.consumed_total<scan.consumed or r.consumed_total>scan.limit then
            total=math.min(budget,total+scan.per); return done(fail('sampler_result_unknown'))
        end
        local used=r.consumed_total-scan.consumed
        if used>scan.per or used>budget-total then total=budget; return done(fail('sampler_budget_invalid')) end
        total=total+used; scan.consumed=r.consumed_total
        if not alive() then return done(fail('binding_changed')) end
        local observed=metadata(r)
        if not observed then return done(fail('sampler_metadata_invalid')) end
        refinement=observed
        local after_poll,clock_why=clock(t); if not after_poll then return done(fail(clock_why)) end
        if not alive() then return done(fail('binding_changed')) end
        scan_duration=after_poll-scan.started
        if not finite(scan_duration) then return done(fail('clock_unknown')) end
        if scan_duration>max_scan then return done(fail('scan_timeout')) end
        if used==0 then return done(fail('sampler_no_progress')) end
        if r.status=='pending' then
            if total>=budget then return done(fail('budget_exhausted')) end
            return done(result('pending','sampling'))
        end
        if r.status=='blocked' then return done(fail(type(r.reason)=='string' and r.reason~='' and r.reason or 'sample_blocked','blocked')) end
        if r.status~='sampled_clear' or type(r.initial)~='table' or r.initial.status~='clear' or
           type(r.samples)~='table' or not integer(r.sample_count) or r.sample_count<1 or r.sample_count>128 or #r.samples~=r.sample_count then
            return done(fail(type(r.reason)=='string' and r.reason~='' and r.reason or 'sample_unknown'))
        end
        local pts={vec(scan.start)}
        for _,sample in ipairs(r.samples) do
            local p=type(sample)=='table' and vec(sample.resolved)
            if not p then return done(fail('sample_geometry_unknown')) end
            pts[#pts+1]=p
        end
        local last=pts[#pts]
        if math.abs(last.X-scan.far.X)>1e-6 or math.abs(last.Y-scan.far.Y)>1e-6 then return done(fail('sample_endpoint_mismatch')) end
        if not valid_sensor() then
            if latched then return done(fail('binding_changed')) end
            refresh_cause='sensor_invalid'
            if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
            return done(result('pending','refresh_required'))
        end
        local pose=fresh_pose()
        if not pose then return done(fail(latched and 'binding_changed' or 'position_unknown')) end
        local moved=dist(pose,scan.start)
        if not moved or not finite(pose.Z-scan.start.Z) then return done(fail('invalid_derived_geometry')) end
        if moved>drift or math.abs(pose.Z-scan.start.Z)>drift then
            resets=resets+1; reset_total=reset_total+1; refresh_cause='coast'
            if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
            if resets>max_resets then return done(fail('coast_reset_limit')) end
            return done(result('pending','coast_reset'))
        end
        -- FindFloor permits location-sensitive cached use; retain the oldest sample
        -- time separately from reuse after a fully validated scan completes.
        -- https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent/FindFloor
        -- Nav2 likewise bounds collision checking in time and distance (conceptual precedent).
        -- https://docs.nav2.org/rolling/configuration_and_development/configuration_guide/controller_plugins/configuring_regulated_pp/
        local finished,why=clock(t); if not finished then return done(fail(why)) end
        scan_duration=finished-scan.started
        if not finite(scan_duration) then return done(fail('clock_unknown')) end
        if scan_duration>max_scan then return done(fail('scan_timeout')) end
        cache={points=pts,started=scan.started,completed_at=finished,step_cm=scan.step_cm}; completed_at=finished; scan=nil
        if not inside(pose,target) then
            if latched then return done(fail('binding_changed')) end
            refresh_cause='outside_corridor'
            if not release() then terminal={status='unknown',reason='cleanup_pending'}; return done(result('unknown','cleanup_pending')) end
            return done(result('pending','refresh_required'))
        end
        if not alive() then return done(fail('binding_changed')) end
        resets=0; refresh_cause=nil
        return done(result('clear','sampled_corridor'))
    end
    local function close()
        if locked then latched=true; return false,'reentrant_close' end
        if closed then return true end
        locked=true; latched=true
        if not release() then locked=false; return false,'cleanup_pending' end
        closed=true; locked=false; return true
    end
    return {check=check,close=close}
end
return M
