local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local M=assert(loadfile(here..'/../scripts/walk_guard.lua'))()
local pass,fail=0,0
local function check(s,v) if v then pass=pass+1 else fail=fail+1;print('FAIL '..s) end end
local function cp(v) local r={};for k,x in pairs(v) do r[k]=x end;return r end
local function fixture()
 local f={alive=true,acquires=0,closes=0,valids=0,polls=0,mode='clear',valid=true,cleanup=true,delay=0,pose={X=0,Y=0,Z=90}}
 f.sampler={new=function(o)
  f.last_options=o; local n=0
  return {poll=function()
   f.polls=f.polls+1;n=n+1
   if f.mode=='reenter' then f.nested=f.guard.check({X=0,Y=0,Z=90},{X=100,Y=0,Z=0},0) end
   if f.mode=='malformed' then return {status='pending',consumed_total=0} end
   if f.mode=='error' then error('fake') end
   if f.mode=='move_during' then f.pose={X=3,Y=0,Z=90} end
   if n<=f.delay then return {status='pending',consumed_total=n} end
   if f.mode=='blocked' then return {status='blocked',reason='floor_not_walkable',consumed_total=n} end
   if f.mode=='refined_blocked' or f.mode=='refined_pending' or f.mode=='refined_unknown' then
    local status=f.mode=='refined_blocked' and 'blocked' or (f.mode=='refined_pending' and 'pending' or 'unknown')
    return {status=status,reason='sweep_blocking',consumed_total=n,refinement_count=2,
    first_blocked={from={X=0,Y=0,Z=90},to={X=10,Y=0,Z=90},depth=0},last_blocked={from={X=0,Y=0,Z=90},to={X=2.5,Y=0,Z=90},depth=2}} end
   if f.mode=='malformed_refinement' then return {status='blocked',reason='sweep_blocking',consumed_total=n,refinement_count=2,
    first_blocked={from={X=0/0,Y=0,Z=90},to={X=10,Y=0,Z=90},depth=0},last_blocked={from={X=0,Y=0,Z=90},to={X=2,Y=0,Z=90},depth=2}} end
   if f.mode=='unknown' then return {status='unknown',reason='floor_unknown',consumed_total=n} end
   return {status='sampled_clear',initial={status=f.mode=='bad_initial' and 'unknown' or 'clear'},sample_count=1,consumed_total=n,samples={{resolved={X=o.to_feet.X+(f.mode=='bad_endpoint' and 2 or 0),Y=o.to_feet.Y,Z=o.to_feet.Z+o.half_height_cm+o.clearance_cm}}}}
  end}
 end}
 f.opts={acquire=function(live)
  f.acquires=f.acquires+1; f.sensor_live=live
  local sensor={shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,clearance_line_trace=false,profile='Player'},
    floor=function() end,sweep=function() end,initial=function() end,
    valid=function() f.valids=f.valids+1;return f.valid end,
    close=function() f.closes=f.closes+1;return f.cleanup end}
  f.last_sensor=sensor;return sensor
 end,sample_module=f.sampler,live=function() return f.alive end,read_pose=function()
  if f.mode=='pose_reenter' then f.nested=f.guard.check(cp(f.pose),{X=100,Y=0,Z=0},0) end
  return f.pose
 end,horizon_cm=100,ttl_s=.35,corridor_cm=10,drift_cm=2,reserve_cm=25,budget=20,poll_budget=4,max_scan_s=2,max_resets=4}
 function f:start() local g,why=M.new(self.opts);self.guard=g;return g,why end
 function f:check(x,target,t) self.pose={X=x,Y=0,Z=90};return self.guard.check(cp(self.pose),{X=target,Y=0,Z=0},t) end
 return f
end
local f=fixture();local g=f:start();local r=f:check(0,200,0)
check('first clear is validated',r.status=='clear' and f.acquires==1 and f.valids==1 and r.consumed_total==1)
check('horizon clamped and z interpolated',f.last_options.to_feet.X==100 and f.last_options.to_feet.Z==0)
check('explicit captured floor reference reaches sampler',f.last_options.clearance_line_trace==false)
for _,kind in ipairs({'missing','string'}) do
 local bad=fixture();local acquire=bad.opts.acquire
 bad.opts.acquire=function(live) local sensor=acquire(live);sensor.shape.clearance_line_trace=kind=='string' and 'false' or nil;return sensor end
 bad:start();local result=bad:check(0,100,0)
 check('unknown sensor floor reference refused '..kind,result.status=='unknown' and result.reason=='sensor_shape_unknown' and bad.closes==1 and bad.polls==0)
end
r=f:check(10,200,.1);check('cache uses valid without resampling',r.status=='clear' and f.valids==2 and f.polls==1)
f=fixture();g=f:start();f:check(0,200,0);r=f:check(80,200,.1);check('reserve near horizon requests held refresh',r.status=='pending' and r.reason=='refresh_required' and f.closes==1)
f=fixture();g=f:start();f:check(0,200,0)
f.valid=false;r=f:check(10,200,.2);check('invalid sensor never grants cached clear',r.status~='clear' and f.closes==1)
f=fixture();g=f:start();f:check(0,200,0);f.pose={X=10,Y=11,Z=90};r=g.check(cp(f.pose),{X=200,Y=0,Z=0},.1);check('outside corridor holds for fresh scan',r.status=='pending' and f.acquires==1)
f=fixture();g=f:start();f:check(0,200,0);f.last_sensor.shape.step_cm=999;f.pose={X=5,Y=0,Z=150}
r=g.check(cp(f.pose),{X=200,Y=0,Z=0},.1);check('cached corridor uses captured private step',r.status=='pending')
f=fixture();g=f:start();f:check(0,200,0);r=f:check(5,200,.36);check('TTL forces new held scan',r.status=='pending' and f.closes==1 and f.acquires==1);r=f:check(5,200,.37);check('TTL rechecks on next poll',r.status=='clear' and f.acquires==2 and r.consumed_total==2)
f=fixture();g=f:start();f:check(0,200,0);r=f:check(5,150,.1);check('new waypoint holds before new scan',r.status=='pending' and f.closes==1 and f.acquires==1);r=f:check(5,150,.11);check('new waypoint rescanned',r.status=='clear' and f.acquires==2 and r.consumed_total==2)
f=fixture();g=f:start();f.delay=1;r=f:check(0,100,0);r=f:check(3,100,.01);check('coast resets lease and holds',r.status=='pending' and f.closes==1 and f.acquires==1);r=f:check(3,100,.02);check('coast resamples on next poll',r.status=='pending' and f.acquires==2 and r.consumed_total==2)
f=fixture();g=f:start();f.delay=100;f:check(0,100,0);r=f:check(0,100,2.1);check('scan timeout terminal',r.status=='unknown' and r.reason=='scan_timeout' and f.closes==1)
f=fixture();f.opts.max_resets=1;g=f:start();f.delay=100;f:check(0,100,0);f:check(3,100,.1);f:check(3,100,.11);r=f:check(6,100,.2);check('finite coast reset limit',r.status=='unknown' and r.reason=='coast_reset_limit')
for _,mode in ipairs({'blocked','unknown'}) do f=fixture();g=f:start();f.mode=mode;r=f:check(0,100,0);local calls=f.acquires;r=f:check(0,100,.1);check(mode..' terminal on same target',r.status==mode and f.acquires==calls);f.mode='clear';r=f:check(0,101,.2);r=f:check(0,101,.21);check(mode..' new route can retry',r.status=='clear' and f.acquires==calls+1) end
f=fixture();g=f:start();f.mode='refined_blocked';r=f:check(0,100,0)
check('guard retains refinement after cleanup',r.status=='blocked' and f.closes==1 and r.refinement and r.refinement.count==2 and r.refinement.first_blocked.to.X==10 and r.refinement.last_blocked.depth==2)
r.refinement.first_blocked.to.X=999;r=f:check(0,100,.1);check('guard copies retained refinement',r.refinement.first_blocked.to.X==10)
f.alive=false;r=f:check(0,100,.2);check('stale binding hides retained refinement',r.reason=='binding_changed' and r.refinement==nil)
f=fixture();g=f:start();f.mode='malformed_refinement';r=f:check(0,100,0)
check('malformed refinement cannot authorize',r.status=='unknown' and r.reason=='sampler_metadata_invalid' and f.closes==1)
for _,mode in ipairs({'refined_blocked','refined_pending','refined_unknown'}) do
 f=fixture();f.mode=mode;f.opts.read_time=function() f.alive=false;return 0 end;g=f:start();r=f:check(0,100,0)
 check('clock lifecycle change drops '..mode..' refinement',r.status=='unknown' and r.reason=='binding_changed' and r.refinement==nil and r.consumed_total==1 and f.closes==1)
end
for _,mode in ipairs({'nil','nan','reversed','throw'}) do
 f=fixture();f.mode='refined_blocked'
 f.opts.read_time=function()
  f.alive=false
  if mode=='throw' then error('clock failure') end
  if mode=='nan' then return 0/0 end
  if mode=='reversed' then return 0 end
  return nil
 end
 g=f:start();r=f:check(0,100,1)
 check('invalid '..mode..' clock with binding change scrubs refinement',r.status=='unknown' and r.refinement==nil and r.consumed_total==1 and f.closes==1 and (r.reason=='clock_unknown' or r.reason=='clock_reversed'))
end
f=fixture();f.mode='refined_blocked'
local original_acquire=f.opts.acquire
f.opts.acquire=function(live)
 local sensor=original_acquire(live);local close=sensor.close
 sensor.close=function()
  f.nested=f.guard.check(cp(f.pose),{X=100,Y=0,Z=0},0)
  return close()
 end
 return sensor
end
g=f:start();r=f:check(0,100,0)
check('cleanup reentry scrubs refinement and preserves accounting',r.status=='blocked' and r.refinement==nil and r.consumed_total==1 and f.closes==1 and f.nested.reason=='reentrant_check')
f=fixture();f.mode='refined_blocked';f.cleanup=false
f.opts.read_time=function() f.alive=false;return 0/0 end
g=f:start();r=f:check(0,100,0)
check('cleanup pending remains explicit with stale refinement',r.reason=='cleanup_pending' and r.refinement==nil and r.consumed_total==1)
f=fixture();f.opts.budget=2;g=f:start();f:check(0,100,0);f:check(0,101,.1);r=f:check(0,101,.11);check('budget charged across waypoint scans',r.status=='clear' and r.consumed_total==2);f:check(0,102,.2);r=f:check(0,102,.21);check('budget exhaustion after refresh',r.status=='unknown' and r.reason=='budget_exhausted' and f.acquires==2)
f=fixture();g=f:start();f:check(0,100,0);f.cleanup=false;r=f:check(0,101,.1);check('failed cleanup holds new acquisition',r.status=='unknown' and r.reason=='cleanup_pending' and f.acquires==1);r=f:check(0,102,.11);check('changed target cannot bypass failed cleanup',r.reason=='cleanup_pending' and f.closes==1 and f.acquires==1);check('failed close retained',not g.close());f.cleanup=true;check('failed close retry',g.close() and f.closes==3)
f=fixture();g=f:start();r=f:check(0,10,0);check('short target admitted',r.status=='clear');r=f:check(5,10,.1);check('short target remains covered',r.status=='clear')
f=fixture();g=f:start();f:check(0,100,0);f.alive=false;r=f:check(0,100,.1);check('binding invalidates cache',r.status=='unknown' and r.reason=='binding_changed');f.alive=true;check('binding change latched',f:check(0,100,.2).status=='unknown')
f=fixture();g=f:start();r=g.check({X=0/0,Y=0,Z=90},{X=100,Y=0,Z=0},0);check('invalid input no callbacks',r.status=='unknown' and f.acquires==0);r=f:check(0,100,0/0);check('invalid time no callbacks',r.status=='unknown' and f.acquires==0)
f=fixture();g=f:start();f.mode='reenter';r=f:check(0,100,0);check('reentrant poll never authorizes clear',r.status=='unknown' and f.nested.reason=='reentrant_check')
f=fixture();g=f:start();f.mode='move_during';r=f:check(0,100,0);check('post-sample pose catches coast before clear',r.status=='pending' and r.reason=='coast_reset' and f.closes==1)
f=fixture();g=f:start();f.mode='pose_reenter';r=f:check(0,100,0);check('pose callback reentry cannot authorize clear',r.status=='unknown' and f.nested.reason=='reentrant_check')
f=fixture();g=f:start();f:check(0,100,0);f.pose=nil
r=g.check({X=0,Y=0,Z=90},{X=100,Y=0,Z=0},.1);check('missing fresh cache pose fails closed',r.status=='unknown' and r.reason=='position_unknown')
f=fixture();g=f:start();f.mode='malformed';r=f:check(0,100,0);check('pending must consume',r.status=='unknown' and r.reason=='sampler_no_progress')
f=fixture();g=f:start();f.mode='bad_endpoint';r=f:check(0,100,0);check('sample endpoint must match intended horizon',r.status=='unknown' and r.reason=='sample_endpoint_mismatch')
f=fixture();g=f:start();f.mode='bad_initial';r=f:check(0,100,0);check('unknown initial overlap cannot clear',r.status=='unknown')
f=fixture();g=f:start();f.mode='blocked';r=f:check(0,100,0);r.status='clear';r.reason='sampled_corridor';check('terminal return mutation cannot turn failure clear',f:check(0,100,.1).status=='blocked')
f=fixture();g=f:start();f.mode='error';r=f:check(0,100,0);check('sampler exception charged bounded allowance',r.status=='unknown' and r.consumed_total==4)
f=fixture();g=f:start();f:check(0,100,1);r=f:check(0,100,.9);check('backward clock invalidates',r.status=='unknown' and r.reason=='clock_reversed')
f=fixture();g=f:start();r=f:check(0,100,0);r.status='blocked';check('return snapshot does not mutate cache',f:check(0,100,.1).status=='clear')
-- Exercise the real sampler, including its multi-poll query accounting.
f=fixture();f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))()
local queries=0
local function known(v) return {known=true,value=v} end
f.opts.acquire=function()
 f.acquires=f.acquires+1
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,clearance_line_trace=false},
  valid=function() return true end,close=function() f.closes=f.closes+1;return true end,
  initial=function() queries=queries+1;return {known=true,blocking=false,consumed=1} end,
  floor=function(p) queries=queries+1;return {status='observed',callbacks=1,consumed=1,fields={
   bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(false),FloorDist=known(p.Z-90),hit={bStartPenetrating=known(false)}}} end,
  sweep=function() queries=queries+1;return {known=true,blocking=false,consumed=1} end}
end
g=f:start();for i=0,8 do r=f:check(0,100,i*.01);if r.status~='pending' then break end end
check('real sampler completes through finite polls',r.status=='clear' and r.consumed_total==queries and queries>4 and f.acquires==1)
-- Actual a830 gap/shape through the real guard and sampler; deterministic native fixtures only.
f=fixture();f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))()
local gap=6.1427993774414;local native_calls=0;local base_acquire=f.opts.acquire
f.opts.acquire=function(live)
 local sensor=base_acquire(live);sensor.shape.clearance_cm=gap;sensor.shape.clearance_line_trace=true
 sensor.initial=function() native_calls=native_calls+1;return {known=true,blocking=false,consumed=1} end
 sensor.sweep=function() native_calls=native_calls+1;return {known=true,blocking=false,consumed=1} end
 sensor.floor=function(p)
  native_calls=native_calls+1;local d=p.Z-90+gap
  return {status='observed',callbacks=1,consumed=1,fields={bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(p.X==0),FloorDist=known(d),LineDist=known(d),hit={bStartPenetrating=known(false),bBlockingHit=known(true)}}}
 end
 return sensor
end
g=f:start();for i=0,8 do r=g.check(cp(f.pose),{X=100,Y=0,Z=90-88-gap},i*.01);if r.status~='pending' then break end end
check('a830 gap preserves full shape and real sampler accounting',r.status=='clear' and native_calls==r.consumed_total and f.acquires==1 and f.last_sensor.shape.radius_cm==34 and f.last_sensor.shape.half_height_cm==88)
f.valid=false;r=g.check(cp(f.pose),{X=100,Y=0,Z=90-88-gap},.1)
check('invalidated lease clears actual sampled cache',r.status~='clear' and f.closes==1)
f=fixture();f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))();f.opts.budget=100
local calls=0
f.opts.acquire=function()
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,clearance_line_trace=false},valid=function() return true end,
  close=function() f.closes=f.closes+1;return true end,
  initial=function() calls=calls+1;return {known=true,blocking=false,consumed=1} end,
  floor=function(p) calls=calls+1;return {status='observed',callbacks=1,consumed=1,fields={
   bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(false),FloorDist=known(p.Z-90),hit={bStartPenetrating=known(false)}}} end,
  sweep=function(a,b) calls=calls+1;return {known=true,blocking=b.X-a.X>8,consumed=1} end}
end
g=f:start();for i=0,30 do r=f:check(0,100,i*.01);if r.status~='pending' then break end end
check('guard accepts actual refined ordered polyline',r.status=='clear' and r.refinement and r.refinement.count==18 and r.refinement.first_blocked and r.consumed_total==calls)
check('refinement evidence survives close',g.close() and f.closes==1)
-- Real sampler with time spent both between polls and inside native callbacks.
f=fixture(); f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))()
local time=0; local count=0
f.opts.read_time=function() return time end
f.opts.acquire=function()
 f.acquires=f.acquires+1
 local function tick() time=time+.04; count=count+1 end
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,clearance_line_trace=false},
  valid=function() time=time+.01; return true end, close=function() f.closes=f.closes+1;return true end,
  initial=function() tick();return {known=true,blocking=false,consumed=1} end,
  floor=function(p) tick();return {status='observed',callbacks=1,consumed=1,fields={
   bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(false),FloorDist=known(p.Z-90),hit={bStartPenetrating=known(false),bBlockingHit=known(true)}}} end,
  sweep=function() tick();return {known=true,blocking=false,consumed=1} end}
end
g=f:start(); repeat r=f:check(0,100,time); if r.status=='pending' then time=time+.03 end until r.status~='pending'
check('real elapsed acquisition exceeds reuse TTL but completes',r.status=='clear' and time>.35 and time<2 and r.scan_duration_s>.35 and r.oldest_observation_age_s>.35 and r.cache_completion_age_s==0 and r.consumed_total==count)
r=f:check(0,100,time); check('immediate pre-input cache recheck',r.status=='clear' and r.cache_completion_age_s<.35 and r.oldest_observation_age_s>.35)
time=time+.36;r=f:check(0,100,time);check('completion TTL expires',r.reason=='refresh_required' and r.refresh_cause=='cache_expired')
f=fixture();time=0; f.opts.read_time=function() return time end; f.mode='clear'
local old_new=f.sampler.new; f.sampler.new=function(o) local job=old_new(o); local poll=job.poll; job.poll=function() local v=poll();time=2.1;return v end; return job end
g=f:start();r=f:check(0,100,0);check('final clear after deadline rejected and charged',r.reason=='scan_timeout' and r.consumed_total==1)
f=fixture();f.opts.read_time=function() return 0/0 end;g=f:start();r=f:check(0,100,0);check('invalid clock fails',r.reason=='clock_unknown')
f=fixture();f.opts.read_time=function() return .5 end;g=f:start();r=f:check(0,100,1);check('callback clock reversal fails',r.reason=='clock_reversed')
f=fixture();f.opts.budget=100;g=f:start();local t=0
for i=1,6 do
 if i>1 then t=t+.4; f:check(0,100,t); t=t+.01 end
 f.delay=1; f:check(0,100,t);t=t+.01;r=f:check(3,100,t);t=t+.01
 f.delay=0;r=f:check(3,100,t);t=t+.01
end
check('successful fresh scans reset only streak',r.status=='clear' and r.coast_reset_streak==0 and r.coast_reset_total==6 and r.consumed_total==12)
f=fixture();f.opts.max_resets=1;g=f:start();f.delay=1;f:check(0,100,0);f:check(3,100,.1);f:check(3,101,.2);f:check(3,101,.21);r=f:check(6,101,.3)
check('aim changes do not reset streak',r.reason=='coast_reset_limit' and r.coast_reset_streak==2 and r.coast_reset_total==2)
f=fixture();local reenter_clock=false
f.opts.read_time=function()
 if reenter_clock then f.nested=f.guard.check({X=0,Y=0,Z=90},{X=100,Y=0,Z=0},.1) end
 return reenter_clock and .1 or 0
end
g=f:start();r=f:check(0,100,0);reenter_clock=true;r=f:check(0,100,.1)
check('cached clock reentry cannot authorize clear',r.status=='unknown' and r.reason=='binding_changed' and f.nested.reason=='reentrant_check')
do -- Actual sampler + independent C-space lip: horizontal then settling clears.
 local function descent_guard(target)
  local f=fixture();local calls=0
  f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))();f.opts.budget=100
  f.opts.acquire=function()
   f.acquires=f.acquires+1
   return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,clearance_line_trace=false},
    valid=function()return f.valid end,close=function()f.closes=f.closes+1;return f.cleanup end,
    initial=function()calls=calls+1;return {known=true,blocking=false,consumed=1}end,
    floor=function(p)
     calls=calls+1;local d=p.Z-(p.X>90 and 68 or 88);local supported=d<=47.4
     return {status='observed',consumed=1,callbacks=1,fields={FloorDist=known(d),LineDist=known(0),bLineTrace=known(false),
      bBlockingHit=known(supported),bWalkableFloor=known(supported),hit={bStartPenetrating=known(false),bBlockingHit=known(supported)}}}
    end,
    sweep=function(a,b)
     calls=calls+1;local dx,dz=b.X-a.X,b.Z-a.Z;local length=dx*dx+dz*dz
     local t=length>0 and math.max(0,math.min(1,((91.6666666667-a.X)*dx+(80-a.Z)*dz)/length))or 0
     return {known=true,blocking=(a.X+t*dx-91.6666666667)^2+(a.Z+t*dz-80)^2<1,consumed=1}
    end}
  end
  local g=f:start();local target={X=target or 100,Y=0,Z=-20};local r
  for i=0,30 do r=g.check(cp(f.pose),target,i*.005);if r.status~='pending'then break end end
  check('real descent guard accounts every callback',r.status=='clear' and r.deferred_descent_count==1 and r.refinement.deferred_descents==1 and r.consumed_total==calls)
  return f,g,target
 end
 local f,g,target=descent_guard()
 for _,z in ipairs({90,80,70})do
  f.pose={X=100,Y=0,Z=z};local r=g.check(cp(f.pose),target,.2)
  check('vertical cached interval admits observed height '..z,r.status=='clear' and f.acquires==1)
 end
 f.pose={X=100,Y=0,Z=136};local r=g.check(cp(f.pose),target,.21)
 check('vertical cache Z remains bounded',r.status=='pending' and r.refresh_cause=='outside_corridor' and f.closes==1)
 f,g,target=descent_guard();f.pose={X=100,Y=0,Z=-200};r=g.check(cp(f.pose),target,.2)
 check('descent cache rejects another floor',r.status~='clear' and f.closes==1)
 f,g,target=descent_guard(150);f.pose={X=95,Y=0,Z=80};r=g.check(cp(f.pose),target,.2)
 check('vertical distance supplies no forward reserve',r.status=='pending' and r.refresh_cause=='outside_corridor')
 for _,kind in ipairs({'x','height','nonfinite','ascending','drop','missing','tag','count','boolean_count'})do
  f=fixture();f.opts.sample_module={new=function(o)return {poll=function()
   local via={X=100,Y=0,Z=90};local p={X=100,Y=0,Z=70};local count=1;local tag='deferred_descent_clear'
   if kind=='x'then via.X=99 elseif kind=='height'then via.Z=91 elseif kind=='nonfinite'then via.Z=math.huge
   elseif kind=='ascending'then p.Z=91 elseif kind=='drop'then p.Z=44 elseif kind=='missing'then via=nil
   elseif kind=='tag'then tag='clear' elseif kind=='count'then count=2 else count=false end
   return {status='sampled_clear',initial={status='clear'},sample_count=1,consumed_total=1,deferred_descent_count=count,
    samples={{resolved=p,via=via,sweep=tag}}}
  end}end}
  g=f:start();r=g.check(cp(f.pose),{X=100,Y=0,Z=-20},0)
  check('malformed deferred cache '..kind,r.status=='unknown' and f.closes==1)
 end
end
do -- Bounded transient failure evidence survives cleanup without native reads.
 local f=fixture();local polls=0
 f.opts.sample_module={new=function(o)return {poll=function()
  polls=polls+1
  return {status='unknown',reason='floor_resolution_out_of_bounds',consumed_total=1,
   failure_detail={phase='floor',query={X=17,Y=0,Z=130},depth=1,actual_z=70,expected_z=90,callbacks=1,
    fields={bWalkableFloor=true,bLineTrace=false,FloorDist=62,ImpactNormal={X=0,Y=0,Z=1},secret='omit'},arbitrary={1,2,3}}}
 end}end}
 local g=f:start();local target={X=100,Y=0,Z=0};local r=g.check(cp(f.pose),target,0)
 check('terminal failure captures scan and floor reference',r.reason=='floor_resolution_out_of_bounds' and f.closes==1 and r.failure and
  r.failure.scan.start.X==0 and r.failure.scan.far.X==100 and r.failure.scan.shape.clearance_line_trace==false and
  r.failure.scan.shape.clearance_cm==2 and r.failure.scan.shape.step_cm==45 and r.failure.detail.fields.FloorDist==62)
 r.failure.detail.fields.FloorDist=999;r.failure.scan.start.X=999
 r=g.check(cp(f.pose),target,.01)
 check('failure diagnostic independent after terminal cleanup',r.failure.detail.fields.FloorDist==62 and r.failure.scan.start.X==0 and polls==1 and r.consumed_total==1)
 check('failure diagnostic whitelists fields',r.failure.detail.arbitrary==nil and r.failure.detail.fields.secret==nil)
 local malformed=M.copy_failure{reason=string.rep('x',81),detail={phase='floor',query={X=math.huge,Y=0,Z=0},actual_z=0/0,
  fields={FloorDist=math.huge,bWalkableFloor='yes',Normal=setmetatable({},{__index=function()error('must not dereference')end})}}}
 check('malformed diagnostic omitted without interpretation',malformed.reason==nil and malformed.detail.query==nil and malformed.detail.actual_z==nil and
  malformed.detail.fields.FloorDist==nil and malformed.detail.fields.bWalkableFloor==nil and malformed.detail.fields.Normal==nil)
 f.cleanup=false;r=g.check(cp(f.pose),{X=101,Y=0,Z=0},.02)
 check('new aim hides prior failure even with cleanup pending',r.failure==nil)
 f.alive=false;r=g.check(cp(f.pose),target,.03)
 check('stale binding hides failure',r.failure==nil and r.status~='clear')
 -- The ORIGINAL failure may already have an ambiguous release. Its fast path
 -- must not re-expose that diagnostic before checking a later aim/binding.
 f=fixture();f.cleanup=false;local original_polls=0;local reads=0
 f.opts.live=function()reads=reads+1;return f.alive end
 f.opts.sample_module={new=function()return {poll=function()
  original_polls=original_polls+1
  return {status='unknown',reason='floor_resolution_out_of_bounds',consumed_total=1,
   failure_detail={phase='floor',query={X=17,Y=0,Z=130},fields={FloorDist=62}}}
 end}end}
 g=f:start();r=g.check(cp(f.pose),target,0)
 check('original ambiguous cleanup omits diagnostic',r.reason=='cleanup_pending' and r.failure==nil and f.closes==1)
 local before=reads;f.alive=false
 r=g.check(cp(f.pose),target,.01)
 check('ambiguous cleanup fast path hides stale failure without callbacks',r.reason=='cleanup_pending' and r.failure==nil and reads==before and original_polls==1)
 r=g.check(cp(f.pose),{X=101,Y=0,Z=0},.02)
 check('ambiguous cleanup fast path hides new-aim failure without callbacks',r.reason=='cleanup_pending' and r.failure==nil and reads==before and original_polls==1 and f.closes==1)
end
print(string.format('%d passed, %d failed',pass,fail));os.exit(fail==0 and 0 or 1)
