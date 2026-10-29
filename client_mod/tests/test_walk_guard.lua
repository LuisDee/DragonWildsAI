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
  local sensor={shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2,profile='Player'},
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
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2},
  valid=function() return true end,close=function() f.closes=f.closes+1;return true end,
  initial=function() queries=queries+1;return {known=true,blocking=false,consumed=1} end,
  floor=function(p) queries=queries+1;return {status='observed',callbacks=1,consumed=1,fields={
   bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(false),FloorDist=known(p.Z-90),hit={bStartPenetrating=known(false)}}} end,
  sweep=function() queries=queries+1;return {known=true,blocking=false,consumed=1} end}
end
g=f:start();for i=0,8 do r=f:check(0,100,i*.01);if r.status~='pending' then break end end
check('real sampler completes through finite polls',r.status=='clear' and r.consumed_total==queries and queries>4 and f.acquires==1)
f=fixture();f.opts.sample_module=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))();f.opts.budget=100
local calls=0
f.opts.acquire=function()
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2},valid=function() return true end,
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
 return {shape={radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2},
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
print(string.format('%d passed, %d failed',pass,fail));os.exit(fail==0 and 0 or 1)
