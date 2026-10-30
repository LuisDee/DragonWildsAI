local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local M=assert(loadfile(os.getenv('SAMPLED_GROUND_WALK_FILE') or here..'/../scripts/sampled_ground_walk.lua'))()
local pass,fail=0,0
local function check(s,v) if v then pass=pass+1 else fail=fail+1; print('FAIL '..s) end end
local function known(v) return {known=true,value=v} end
local function setup()
 local f={calls=0,mode='clear',alive=true,sw=0}
 f.opts={from_center={X=0,Y=0,Z=94},to_feet={X=40,Y=0,Z=0},radius_cm=20,half_height_cm=90,step_cm=45,clearance_cm=2,clearance_line_trace=false,spacing_cm=20,budget=20,poll_budget=2,
 live=function() return f.alive end}
 f.opts.floor=function(p,remaining)
  f.calls=f.calls+1; f.last_remaining=remaining
  local line=f.mode=='line'; local pz=f.mode=='bad' and nil or false
  local floor={bBlockingHit=known(f.mode~='inconsistent'),bWalkableFloor=known(f.mode~='unsupported'),bLineTrace=known(line),FloorDist=known(p.Z-92),LineDist=known(p.Z-92),hit={bStartPenetrating=known(pz),bBlockingHit=known(f.mode~='inconsistent')}}
  if f.mode=='wrong_floor' and f.calls>2 then floor.FloorDist=known(p.Z-300) end
  if f.mode=='line' then floor.FloorDist=known(9999) end
  if f.mode=='negative_start' and f.calls==1 then floor.FloorDist=known(-0.58) end
  if f.mode=='life' then f.alive=false end
  if f.mode=='missing' then floor.hit={} end
  if f.mode=='penetrating' then floor.hit.bStartPenetrating=known(true) end
  return {status='observed',consumed=1,callbacks=(f.mode=='callback_missing' and 0 or 1),fields=floor}
 end
 f.opts.sweep=function(a,b,remaining)
  f.calls=f.calls+1; f.sw=f.sw+1; f.last_sweep={a=a,b=b}; f.last_remaining=remaining
  return {known=f.mode~='sweep_unknown',blocking=f.mode=='wall' or f.mode=='ceiling',consumed=1}
 end
 f.opts.overlap=function(p,remaining) f.calls=f.calls+1; f.last_remaining=remaining; return {known=f.mode~='overlap_unknown',blocking=f.mode=='overlap',consumed=1} end
 function f:start() local tx,why=M.new(self.opts); self.tx=tx; return tx,why end
 function f:run() local r repeat r=self.tx.poll() until r.status~='pending'; return r end
 return f
end
local f=setup(); local tx=f:start(); local r=tx.poll(); check('per poll bounded',r.status=='pending' and f.calls==2 and r.consumed_total==2)
r=f:run(); check('sampled clear not proof',r.status=='sampled_clear' and r.initial.status=='clear' and r.limits:find('no continuity proof')~=nil)
check('spacing at most half radius',r.spacing_cm==10 and #r.samples==4 and f.sw==4 and f.last_remaining==1)
check('raised search and grounded centres',r.samples[1].raised.Z==134 and r.samples[1].resolved.Z==94 and r.samples[1].support.distance_cm==42)
check('actual centre is first sweep origin',r.samples[1].expected.X==10 and r.start_floor.start_penetrating==false)
r.samples[1].resolved.Z=999; check('terminal returns independent snapshots',tx.poll().samples[1].resolved.Z==94)
for _,case in ipairs({{5,1,2,8},{2.5,3,4,16}}) do
 f=setup();f.opts.to_feet.X=10;f.opts.budget=40;f.opts.poll_budget=1
 f.opts.sweep=function(a,b) f.calls=f.calls+1;return {known=true,blocking=b.X-a.X>case[1]+1e-8,consumed=1} end
 tx=f:start();r=f:run()
 check('refined supported chord '..case[1],r.status=='sampled_clear' and r.refinement_count==case[2] and r.sample_count==case[3] and #r.samples==case[3] and r.consumed_total==case[4])
 check('original block retained '..case[1],r.first_blocked and r.first_blocked.from.X==0 and r.first_blocked.to.X==10 and r.first_blocked.depth==0)
 local ordered=true;for i,p in ipairs(r.samples) do if i>1 and p.resolved.X<=r.samples[i-1].resolved.X then ordered=false end end
 check('refined polyline ordered '..case[1],ordered and r.samples[#r.samples].resolved.X==10)
 r.first_blocked.from.X=999;check('refinement evidence copied '..case[1],tx.poll().first_blocked.from.X==0)
end
f=setup();f.opts.to_feet.X=10;f.opts.budget=40;local floor_queries={}
local flat=f.opts.floor
f.opts.floor=function(p,n)
 floor_queries[#floor_queries+1]={X=p.X,Z=p.Z};local obs=flat(p,n)
 if p.X==5 then obs.fields.FloorDist=known(p.Z-95) end
 return obs
end
f.opts.sweep=function(a,b) f.calls=f.calls+1;return {known=true,blocking=a.X==0 and b.X==10,consumed=1} end
tx=f:start();r=f:run()
check('refinement re-resolves endpoint from midpoint support',r.status=='sampled_clear' and #floor_queries==4 and floor_queries[2].X==10 and floor_queries[3].X==5 and floor_queries[4].X==10 and r.samples[1].resolved.Z==97 and r.samples[2].raised.Z==137)
f=setup();f.opts.to_feet.X=10;f.opts.budget=40;f.mode='wall';tx=f:start();r=f:run()
check('blocked leaf depth bounded',r.status=='blocked' and r.reason=='sweep_blocking' and r.last_blocked.depth==2 and r.refinement_count==2 and r.consumed_total==8)
f=setup();f.opts.to_feet.X=10;f.opts.budget=40
f.opts.sweep=function(a,b) f.calls=f.calls+1;return {known=true,blocking=(b.X-a.X>5.01 or a.X>=5),consumed=1} end
tx=f:start();r=f:run();check('blocked second half remains blocked',r.status=='blocked' and r.last_blocked.depth==2 and r.last_blocked.from.X>=5)
for _,mode in ipairs({'unsupported','missing','penetrating'}) do
 f=setup();f.opts.to_feet.X=10;f.opts.budget=40
 local basefloor=f.opts.floor
 f.opts.floor=function(p,n) if p.X==5 then f.mode=mode end;return basefloor(p,n) end
 f.opts.sweep=function(a,b) f.calls=f.calls+1;return {known=true,blocking=b.X-a.X>5.01,consumed=1} end
 tx=f:start();r=f:run();check('midpoint '..mode..' rejects',r.status~='sampled_clear' and r.refinement_count==1)
end
f=setup();f.opts.to_feet.X=10;f.opts.max_samples=1;f.mode='wall';tx=f:start();r=f:run()
check('refinement respects sample cap',r.status=='unknown' and r.reason=='sample_limit' and r.first_blocked and r.refinement_count==0)
f=setup();f.opts.to_feet.X=10;f.opts.budget=4;f.opts.poll_budget=2;f.mode='wall';tx=f:start();r=f:run()
check('refinement respects cumulative budget',r.status=='unknown' and r.reason=='budget_exhausted' and r.consumed_total==4 and r.refinement_count==1)
f=setup();f.opts.to_feet.X=10;f.opts.budget=40
f.opts.sweep=function(a,b) f.calls=f.calls+1;f.alive=false;return {known=true,blocking=true,consumed=1} end
tx=f:start();r=f:run();check('binding loss before refinement fails closed',r.reason=='binding_changed' and r.refinement_count==0)
f=setup(); f.opts.overlap=nil; tx=f:start(); r=f:run(); check('floor does not prove initial overlap',r.status=='unknown' and r.reason=='initial_overlap_unknown' and r.completed_samples==4)
for _,pair in ipairs({{'unsupported','floor_not_walkable','blocked'},{'penetrating','floor_initial_penetration','blocked'},
 {'wall','sweep_blocking','blocked'},{'ceiling','sweep_blocking','blocked'},{'overlap','overlap_blocking','blocked'},
 {'missing','floor_fields_unknown','unknown'},{'callback_missing','floor_unknown','unknown'},{'inconsistent','floor_flags_inconsistent','unknown'},{'sweep_unknown','sweep_unknown','unknown'},{'overlap_unknown','overlap_unknown','unknown'},
 {'wrong_floor','floor_resolution_out_of_bounds','unknown'},{'life','binding_changed','unknown'}}) do
 f=setup(); f.mode=pair[1]; tx=f:start(); r=f:run(); check(pair[1],r.status==pair[3] and r.reason==pair[2])
end
f=setup(); f.mode='line'; f.opts.clearance_line_trace=true; tx=f:start(); r=f:run(); check('line result uses LineDist',r.status=='sampled_clear' and r.samples[1].support.line_trace==true)
f=setup();f.mode='line';tx=f:start();r=f:run();check('start reference mismatch is unknown',r.status=='unknown' and r.reason=='start_floor_reference_changed' and f.sw==0)
for _,value in ipairs({'missing','false_string'}) do
 f=setup();f.opts.clearance_line_trace=value=='false_string' and 'false' or nil;tx=f:start()
 check('explicit floor reference required '..value,tx==nil and f.calls==0)
end
for _,delta in ipairs({5,5.001}) do
 f=setup();local floor=f.opts.floor
 f.opts.floor=function(p,n) local obs=floor(p,n);if p.X==0 then obs.fields.FloorDist=known(f.opts.clearance_cm+delta) end;return obs end
 tx=f:start();r=f:run()
 check('start gap residual '..delta,delta==5 and r.status=='sampled_clear' or delta>5 and r.status=='unknown' and r.reason=='start_floor_clearance_mismatch' and f.sw==0)
end
for _,case in ipairs({{2,-1},{39,40}}) do
 f=setup();f.opts.clearance_cm=case[1];local floor=f.opts.floor
 f.opts.floor=function(p,n) local obs=floor(p,n);if p.X==0 then obs.fields.FloorDist=known(case[2]) end;return obs end
 tx=f:start();r=f:run()
 check('fresh start bounds override small residual '..case[2],r.status=='unknown' and r.reason=='start_floor_distance_out_of_bounds' and f.sw==0)
end
for _,mode in ipairs({'missing','infinite','nan'}) do
 f=setup();local floor=f.opts.floor
 f.opts.floor=function(p,n)
  local obs=floor(p,n);if p.X==0 then obs.fields.FloorDist=mode=='missing' and {known=false} or known(mode=='nan' and 0/0 or math.huge) end;return obs
 end
 tx=f:start();r=f:run();check('unknown fresh distance '..mode,r.status=='unknown' and r.reason=='floor_distance_unknown' and f.sw==0)
end
f=setup();f.mode='line';f.opts.clearance_line_trace=true;local floor=f.opts.floor
f.opts.floor=function(p,n) local obs=floor(p,n);if p.X>0 then obs.fields.bLineTrace=known(false);obs.fields.FloorDist=obs.fields.LineDist end;return obs end
tx=f:start();f.opts.clearance_line_trace=false;f.opts.clearance_cm=999;r=f:run()
check('immutable starting reference permits different later raised-query kind',r.status=='sampled_clear' and r.start_floor.line_trace==true and r.samples[1].support.line_trace==false)
f=setup();local gap=6.1427993774414;local start=-2914.4765801762
f.opts.from_center.Z=start;f.opts.to_feet.Z=start-88-gap;f.opts.radius_cm=34;f.opts.half_height_cm=88;f.opts.clearance_cm=gap;f.opts.clearance_line_trace=true
f.opts.floor=function(p)
 f.calls=f.calls+1;local d=p.Z-start+gap
 return {status='observed',consumed=1,callbacks=1,fields={bBlockingHit=known(true),bWalkableFloor=known(true),bLineTrace=known(true),FloorDist=known(.26082754135132),LineDist=known(d),hit={bStartPenetrating=known(false),bBlockingHit=known(true)}}}
end
tx=f:start();r=f:run();check('a830 offset reconstructs actual capsule centre',r.status=='sampled_clear' and math.abs(r.samples[1].resolved.Z-start)<1e-8 and r.start_floor.distance_cm==gap and f.sw==3)
for _,value in ipairs({-0.01,40,math.huge}) do f=setup();f.opts.clearance_cm=value;tx=f:start();check('invalid supplied gap '..value,tx==nil and f.calls==0) end
f=setup();f.opts.radius_cm=0;tx=f:start();check('zero radius rejected',tx==nil and f.calls==0)
f=setup();f.opts.half_height_cm=10;tx=f:start();check('capsule dimensions preserved',tx==nil and f.calls==0)
f=setup(); f.opts.overlap=nil; f.mode='negative_start'; tx=f:start(); r=f:run(); check('negative start distance is unknown without inventing penetration',r.status=='unknown' and r.reason=='start_floor_distance_out_of_bounds' and f.sw==0)
f=setup(); f.opts.budget=3; f.opts.poll_budget=2; tx=f:start(); r=f:run(); check('cumulative budget stops',r.status=='unknown' and r.reason=='budget_exhausted' and f.calls==3); tx.poll(); check('no calls after exhaustion',f.calls==3)
f=setup(); f.opts.max_samples=2; local why; tx,why=f:start(); check('sample cap',tx==nil and why=='sample_limit')
f=setup(); f.opts.step_cm=5; tx=f:start(); check('invalid raise limit',tx==nil)
f=setup(); f.opts.spacing_cm=0/0; tx=f:start(); check('nonfinite rejected',tx==nil)
f=setup(); f.opts.sweep=function() f.calls=f.calls+1; return {known=true,blocking=false,consumed=0} end; tx=f:start(); r=f:run(); check('unknown query cost',r.status=='unknown' and r.reason=='query_failed_or_budget_unknown')
f=setup(); f.opts.floor=function() error('fake native failure') end; tx=f:start(); r=f:run(); check('callback error costs query',r.status=='unknown' and r.reason=='query_failed_or_budget_unknown' and r.consumed_total==2)
f=setup(); local original=f.opts.floor; f.opts.floor=function(p,n) f.nested=f.tx.poll(); return original(p,n) end
tx=f:start(); r=f:run(); check('reentry latches transaction',r.status=='unknown' and r.reason=='binding_changed' and f.nested.reason=='reentrant_poll')
f=setup(); tx=f:start(); local old=f.opts.to_feet.X; f.opts.to_feet.X=999; r=f:run(); check('geometry copied',r.status=='sampled_clear' and r.sample_count==4 and old==40)
-- Individually finite coordinates can overflow during centre reconstruction.
f=setup(); f.opts.to_feet.Z=1e308; f.opts.half_height_cm=1e308
tx=f:start(); r=f:run(); check('target height overflow rejected',r.status=='unknown' and r.reason=='invalid_derived_geometry' and r.samples[1].raised.Z==134)
f=setup(); f.opts.from_center.Z=1e308; f.opts.to_feet.Z=1e308
local original_floor=f.opts.floor
f.opts.floor=function(p,n)
 check('floor callback receives finite coordinates',p.X==p.X and p.Y==p.Y and p.Z==p.Z and math.abs(p.X)<math.huge and math.abs(p.Y)<math.huge and math.abs(p.Z)<math.huge)
 local obs=original_floor(p,n); if f.calls==2 then obs.fields.FloorDist=known(0) elseif f.calls>2 then obs.fields.FloorDist=known(-1e308) end; return obs
end
tx=f:start(); r=f:run(); check('resolved overflow never reaches sweep',r.status=='unknown' and r.reason=='invalid_derived_geometry' and f.sw==0)
-- Model floor elevations and the bounded retry independently of target height.
local function terrain(heights, miss, bad)
 local f=setup(); f.opts.to_feet.Z=6; f.opts.poll_budget=1
 local calls, queries=0,{}
 f.opts.floor=function(p)
  calls=calls+1; queries[#queries+1]={X=p.X,Y=p.Y,Z=p.Z}
  local sample=math.floor(p.X/10+0.5)
  local previous=queries[#queries-1]
  local lower=sample>0 and previous and previous.X==p.X and p.Z<previous.Z
  local ismiss=sample>0 and (miss=='always' or (miss=='raised' and not lower) or (miss=='downhill' and sample>=3 and not lower))
  local block=not ismiss; local walk=not ismiss; local pen=false
  if sample>0 and bad then
   if bad=='blocking' then block=true; walk=false end
   if bad=='penetration' then pen=true end
  end
  local fields={bBlockingHit=known(block),bWalkableFloor=known(walk),bLineTrace=known(false),
   FloorDist=known(p.Z-(heights[sample+1] or 92)),LineDist=known(0),
   hit={bStartPenetrating=known(pen),bBlockingHit=known(block),ImpactNormal=known({X=0,Y=0,Z=1})}}
  if sample>0 and bad=='unknown' then fields.bBlockingHit={known=false} end
  if sample>0 and bad=='hit_true' then fields.bBlockingHit=known(false); fields.bWalkableFloor=known(false); fields.hit.bBlockingHit=known(true) end
  if sample>0 and bad=='hit_unknown' then fields.bBlockingHit=known(false); fields.bWalkableFloor=known(false); fields.hit.bBlockingHit={known=false} end
  return {status='observed',callbacks=1,consumed=1,fields=fields}
 end
 f.queries=queries; f:start(); return f
end
f=terrain({92,92,92,92,92},nil); r=f:run()
check('misleading destination height flat support',r.status=='sampled_clear' and r.samples[1].raised.Z==134 and r.samples[4].resolved.Z==94)
f=terrain({92,102,112,102,92},'downhill'); r=f:run()
check('ascending and downhill fallback',r.status=='sampled_clear' and r.samples[2].resolved.Z==114 and r.samples[4].resolved.Z==94)
check('fallback uses previous resolved elevation',f.queries[4].Z==154 and f.queries[5].Z==114 and r.consumed_total==12 and r.samples[3].fallback==true and r.samples[3].query.Z==114 and r.samples[1].fallback==false and r.samples[1].query.Z==134)
f=terrain({92,92,92,92,92},'always'); r=f:run()
check('second miss is unknown support',r.status=='unknown' and r.reason=='no_floor_support' and #f.queries==3 and r.failure_detail.phase=='floor_fallback' and r.failure_detail.query.Z==94)
check('failure retains primitive normal',r.failure_detail.fields.ImpactNormal.Z==1 and r.failure_detail.fields.bBlockingHit==false)
r.failure_detail.fields.ImpactNormal.Z=99; check('failure snapshot copied',f.tx.poll().failure_detail.fields.ImpactNormal.Z==1)
for _,case in ipairs({{'blocking','floor_not_walkable'},{'penetration','floor_initial_penetration'},{'unknown','floor_fields_unknown'},{'hit_true','floor_hit_flags_unknown_or_inconsistent'},{'hit_unknown','floor_hit_flags_unknown_or_inconsistent'}}) do
 f=terrain({92,92,92,92,92},nil,case[1]); r=f:run()
 check('no fallback '..case[1],r.reason==case[2] and #f.queries==2)
end
f=terrain({92,200,92,92,92},nil); r=f:run(); check('delta measured from previous support',r.reason=='floor_resolution_out_of_bounds' and f.sw==0)
f=terrain({92,92,92,92,92},'raised'); f.opts.budget=3; f.opts.poll_budget=1; f:start(); r=f:run()
check('fallback budget exhaustion',r.reason=='budget_exhausted' and #f.queries==2)
f=terrain({92,92,92,92,92},'raised'); r=f.tx.poll(); r=f.tx.poll(); r=f.tx.poll(); f.alive=false; r=f.tx.poll()
check('binding invalidates pending fallback',r.reason=='binding_changed' and #f.queries==2)
for _,distance in ipairs({1000,-1000}) do
 f=setup(); local original=f.opts.floor
 f.opts.floor=function(p,n) local obs=original(p,n); if f.calls==2 then obs.fields.FloorDist=known(distance) end; return obs end
 tx=f:start(); r=f:run(); check('starting floor distance bounded '..distance,r.reason=='start_floor_distance_out_of_bounds' and f.sw==0)
end
for _,case in ipairs({{47,'sampled_clear'},{47.01,'unknown'}}) do
 f=setup(); f.opts.to_feet.Z=case[1]; tx=f:start(); r=f:run()
 check('target support boundary '..case[1],r.status==case[2] and (case[2]=='sampled_clear' or (r.reason=='target_support_mismatch' and r.failure_detail.actual_z==94 and r.failure_detail.expected_z==case[1]+92)))
end
f=terrain({92,110,130,150,170},nil); r=f:run()
check('rolling terrain drift cannot pass wrong target floor',r.reason=='target_support_mismatch' and r.failure_detail.actual_z==172 and r.failure_detail.expected_z==98)

do -- Immutable a849/a851 native requests/results: no invented unqueried geometry.
 -- Diagnostic fixtures only, not hidden runtime coordinates or autonomous proof.
 -- Observed native walking semantics:
 -- https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent/MoveAlongFloor?application_version=5.5
 local floors={{7703.3343028396,185498.93608937,-3086.1674565941,2.1500010490417,0.0,false,true,true,false,true},{7800,185500,-3046.1674565941,43.413425445557,0.0,false,true,true,false,true},{7703.3343028396,185498.93608937,-3086.1674565941,2.1500010490417,0.0,false,true,true,false,true},{7717.1436881482,185499.0880766,-3046.1674565941,28.40145111084,0.0,false,true,true,false,true},{7730.9530734569,185499.24006384,-3032.4189066559,25.678609848022,0.0,false,true,true,false,true},{7724.0483808025,185499.16407022,-3032.4189066559,30.898445129395,0.0,false,true,true,false,true},{7730.9530734569,185499.24006384,-3021.1673507363,36.930168151855,0.0,false,true,true,false,true},{7744.7624587655,185499.39205107,-3015.9475178391,38.330959320068,0.0,false,true,true,false,true},{7758.5718440741,185499.5440383,-3012.1284761101,41.019397735596,0.0,false,true,true,false,true},{7772.3812293827,185499.69602553,-3010.9978727966,42.434921264648,0.0,false,true,true,false,true},{7786.1906146914,185499.84801277,-3011.2827930123,44.967807769775,0.0,false,true,true,false,true},{7800.0,185500.0,-3014.100599733,47.400100708008,0.0,false,false,false,false,false},{7800.0,185500.0,-3054.100599733,35.480270385742,0.0,false,true,true,false,true},{7703.3343028396,185498.93608937,-3086.1674565941,2.1500010490417,0.0,false,true,true,false,true},{7800,185500,-3046.1674565941,43.413425445557,0.0,false,true,true,false,true},{7703.3343028396,185498.93608937,-3086.1674565941,2.1500010490417,0.0,false,true,true,false,true},{7717.1436881482,185499.0880766,-3046.1674565941,28.40145111084,0.0,false,true,true,false,true},{7730.9530734569,185499.24006384,-3032.4189066559,25.678609848022,0.0,false,true,true,false,true},{7724.0483808025,185499.16407022,-3032.4189066559,30.898445129395,0.0,false,true,true,false,true},{7730.9530734569,185499.24006384,-3021.1673507363,36.930168151855,0.0,false,true,true,false,true},{7744.7624587655,185499.39205107,-3015.9475178391,38.330959320068,0.0,false,true,true,false,true},{7758.5718440741,185499.5440383,-3012.1284761101,41.019397735596,0.0,false,true,true,false,true},{7772.3812293827,185499.69602553,-3010.9978727966,42.434921264648,0.0,false,true,true,false,true},{7786.1906146914,185499.84801277,-3011.2827930123,44.967807769775,0.0,false,true,true,false,true},{7800.0,185500.0,-3014.100599733,47.400100708008,0.0,false,false,false,false,false},{7800.0,185500.0,-3054.100599733,35.480270385742,0.0,false,true,true,false,true},{7793.0953073457,185499.92400638,-3014.100599733,45.893817901611,0.0,false,true,true,false,true},{7800.0,185500.0,-3017.8444165856,47.400100708008,0.0,false,false,false,false,false},{7800.0,185500.0,-3057.8444165856,31.736450195312,0.0,false,true,true,false,true},{7796.5476536728,185499.96200319,-3017.8444165856,46.245410919189,0.0,false,true,true,false,true},{7800.0,185500.0,-3021.9398264557,47.400100708008,0.0,false,false,false,false,false},{7800.0,185500.0,-3061.9398264557,27.641052246094,0.0,false,true,true,false,true},{7798.2738268364,185499.9810016,-3021.9398264557,47.400100708008,0.0,false,false,false,false,false},{7798.2738268364,185499.9810016,-3061.9398264557,27.331638336182,0.0,false,true,true,false,true},{7800.0,185500.0,-3047.1214637428,42.459415435791,0.0,false,true,true,false,true}}
 local sweeps={{7703.3343028396,185498.93608937,-3086.1674565941,7800,185500,-3087.4308809906,true},{7703.3343028396,185498.93608937,-3086.1674565941,7703.3343028396,185498.93608937,-3076.1674565941,false},{7703.3343028396,185498.93608937,-3086.1674565941,7717.1436881482,185499.0880766,-3072.4189066559,false},{7717.1436881482,185499.0880766,-3072.4189066559,7730.9530734569,185499.24006384,-3055.9475154549,true},{7717.1436881482,185499.0880766,-3072.4189066559,7724.0483808025,185499.16407022,-3061.1673507363,false},{7724.0483808025,185499.16407022,-3061.1673507363,7730.9530734569,185499.24006384,-3055.9475178391,false},{7730.9530734569,185499.24006384,-3055.9475178391,7744.7624587655,185499.39205107,-3052.1284761101,false},{7744.7624587655,185499.39205107,-3052.1284761101,7758.5718440741,185499.5440383,-3050.9978727966,false},{7758.5718440741,185499.5440383,-3050.9978727966,7772.3812293827,185499.69602553,-3051.2827930123,false},{7772.3812293827,185499.69602553,-3051.2827930123,7786.1906146914,185499.84801277,-3054.100599733,false},{7786.1906146914,185499.84801277,-3054.100599733,7800.0,185500.0,-3087.4308690697,true},{7786.1906146914,185499.84801277,-3054.100599733,7800.0,185500.0,-3054.100599733,false},{7800.0,185500.0,-3054.100599733,7800.0,185500.0,-3087.4308690697,false},{7703.3343028396,185498.93608937,-3086.1674565941,7800,185500,-3087.4308809906,true},{7703.3343028396,185498.93608937,-3086.1674565941,7703.3343028396,185498.93608937,-3076.1674565941,false},{7703.3343028396,185498.93608937,-3086.1674565941,7717.1436881482,185499.0880766,-3072.4189066559,false},{7717.1436881482,185499.0880766,-3072.4189066559,7730.9530734569,185499.24006384,-3055.9475154549,true},{7717.1436881482,185499.0880766,-3072.4189066559,7724.0483808025,185499.16407022,-3061.1673507363,false},{7724.0483808025,185499.16407022,-3061.1673507363,7730.9530734569,185499.24006384,-3055.9475178391,false},{7730.9530734569,185499.24006384,-3055.9475178391,7744.7624587655,185499.39205107,-3052.1284761101,false},{7744.7624587655,185499.39205107,-3052.1284761101,7758.5718440741,185499.5440383,-3050.9978727966,false},{7758.5718440741,185499.5440383,-3050.9978727966,7772.3812293827,185499.69602553,-3051.2827930123,false},{7772.3812293827,185499.69602553,-3051.2827930123,7786.1906146914,185499.84801277,-3054.100599733,false},{7786.1906146914,185499.84801277,-3054.100599733,7800.0,185500.0,-3087.4308690697,true},{7786.1906146914,185499.84801277,-3054.100599733,7793.0953073457,185499.92400638,-3057.8444165856,false},{7793.0953073457,185499.92400638,-3057.8444165856,7800.0,185500.0,-3087.4308657318,true},{7793.0953073457,185499.92400638,-3057.8444165856,7796.5476536728,185499.96200319,-3061.9398264557,false},{7796.5476536728,185499.96200319,-3061.9398264557,7800.0,185500.0,-3087.4308776528,true},{7796.5476536728,185499.96200319,-3061.9398264557,7798.2738268364,185499.9810016,-3087.1214637428,true},{7798.2738268364,185499.9810016,-3087.1214637428,7800.0,185500.0,-3087.4308781296,false}}
 local calls,unknown=0,0
 local function near(a,b)return math.abs(a-b)<1e-4 end -- JSON/native float replay noise, cm
 local function floor(p)
  calls=calls+1;local best,delta
  for _,q in ipairs(floors)do
   if near(p.X,q[1]) and near(p.Y,q[2]) and near(p.Z,q[3]) then
    local d=math.abs(p.Z-q[3]);if not delta or d<delta then best,delta=q,d end
   end
  end
  if not best then unknown=unknown+1;error('unrecorded native floor')end
  local q=best
  return {status='observed',consumed=1,callbacks=1,fields={FloorDist=known(q[4]),LineDist=known(q[5]),
   bLineTrace=known(q[6]),bWalkableFloor=known(q[7]),bBlockingHit=known(q[8]),hit={bStartPenetrating=known(q[9]),bBlockingHit=known(q[10])}}}
 end
 local function sweep(a,b)
  calls=calls+1;local best,delta
  for _,q in ipairs(sweeps)do
   if near(a.X,q[1]) and near(a.Y,q[2]) and near(a.Z,q[3]) and near(b.X,q[4]) and near(b.Y,q[5]) and near(b.Z,q[6]) then
    local d=math.abs(a.Z-q[3])+math.abs(b.Z-q[6]);if not delta or d<delta then best,delta=q,d end
   end
  end
  if not best then unknown=unknown+1;error('unrecorded native sweep')end
  return {known=true,blocking=best[7],consumed=1}
 end
 for _,per in ipairs({1,2,4})do
  calls,unknown=0,0
  local tx=assert(M.new{floor=floor,sweep=sweep,overlap=function(p)return sweep(p,{X=p.X,Y=p.Y,Z=p.Z+10})end,live=function()return true end,
   from_center={X=7703.3343028396,Z=-3086.1674565941,Y=185498.93608937},to_feet={X=7800,Z=-3178.55,Y=185500},radius_cm=34,half_height_cm=88,step_cm=45,clearance_cm=2.1500010490417,clearance_line_trace=false,spacing_cm=16,budget=96,poll_budget=per})
  local r;local max=0
  repeat local before=calls;r=tx.poll();max=math.max(max,calls-before) until r.status~='pending'
  if per==4 then print('native descent replay status='..r.status..' reason='..r.reason..' queries='..calls..' unknown='..unknown..' deferred='..tostring(r.deferred_descent_count)) end
  check('recorded a851 full segment admits descent budget '..per,r.status=='sampled_clear' and r.deferred_descent_count==1 and r.refinement_count==1 and unknown==0)
  check('recorded native callbacks all charged '..per,r.consumed_total==calls and calls==23 and max<=per)
  local last=r.samples[#r.samples]
  check('recorded descent retains explicit two-leg geometry '..per,last and last.sweep=='deferred_descent_clear' and last.via and last.via.X==last.resolved.X and last.via.Z>last.resolved.Z)
 end
end

if os.getenv('SAMPLED_NATIVE_REPLAY_ONLY')=='1' then print(string.format('%d passed, %d failed',pass,fail));os.exit(fail==0 and 0 or 1)end
do -- Independent configuration-space obstacle crossing the diagonal only.
 local function descent(mode,per,budget)
  local f={calls=0,alive=true,segments={},mode=mode}
  local function floor(p)
   f.calls=f.calls+1
   local centre=p.X==0 and 92 or (mode=='rising' and 112 or mode=='flat' and 92 or 72)
   local d=p.Z-centre;local supported=d<=47.4 and mode~='missing'
   return {status='observed',consumed=1,callbacks=1,fields={FloorDist=known(d),LineDist=known(0),bLineTrace=known(false),
    bWalkableFloor=known(supported),bBlockingHit=known(supported),hit={bStartPenetrating=known(false),bBlockingHit=known(supported)}}}
  end
  local function sweep(a,b)
   f.calls=f.calls+1;f.segments[#f.segments+1]={a=a,b=b}
   local dx,dz=b.X-a.X,b.Z-a.Z;local len=dx*dx+dz*dz
   local t=len>0 and math.max(0,math.min(1,((5-a.X)*dx+(84-a.Z)*dz)/len)) or 0
   local blocked=(a.X+t*dx-5)^2+(a.Z+t*dz-84)^2<1
   if mode=='wall' or mode=='rising' or mode=='flat' then blocked=(a.X<5 and b.X>=5) end
   if mode=='down_blocked' then blocked=(a.Z>=84 and b.Z<84) end
   local horizontal=dx>0 and dz==0;local down=dx==0 and dz<0
   if mode=='life_horizontal' and horizontal or mode=='life_down' and down then f.alive=false end
   if mode=='reenter' and horizontal then f.nested=f.tx.poll() end
   if mode=='throw_horizontal' and horizontal then error('sensor callback failure')end
   local unknown=mode=='unknown_horizontal' and horizontal or mode=='unknown_down' and down
   return {known=not unknown,blocking=blocked,consumed=1}
  end
  f.tx=assert(M.new{from_center={X=0,Y=0,Z=94},to_feet={X=10,Y=0,Z=(mode=='rising' and 20 or mode=='flat' and 0 or -20)},
   radius_cm=20,half_height_cm=90,step_cm=45,clearance_cm=2,clearance_line_trace=false,spacing_cm=10,
   budget=budget or 40,poll_budget=per or 1,live=function()return f.alive end,floor=floor,sweep=sweep,
   overlap=function()f.calls=f.calls+1;return {known=true,blocking=false,consumed=1}end})
  function f:run()
   local r;self.max=0
   for _=1,100 do local before=self.calls;r=self.tx.poll();self.max=math.max(self.max,self.calls-before);if r.status~='pending'then return r end end
   error('pending descent did not terminate')
  end
  return f
 end
 for _,per in ipairs({1,2,4})do
  local f=descent('clear',per);local r=f:run()
  check('deferred geometry all counted '..per,r.status=='sampled_clear' and r.deferred_descent_count==1 and r.sample_count==1 and r.consumed_total==7 and f.calls==7 and f.max<=per)
  check('diagonal remains blocked evidence '..per,r.first_blocked and r.first_blocked.from.Z==94 and r.first_blocked.to.Z==74 and r.samples[1].via.Z==94 and r.samples[1].sweep=='deferred_descent_clear')
  r.samples[1].via.Z=999;check('descent via copied '..per,f.tx.poll().samples[1].via.Z==94)
 end
 for _,budget in ipairs({4,5,6})do
  local f=descent('clear',1,budget);local r=f:run()
  check('uncompleted descent budget '..budget,r.reason=='budget_exhausted' and r.sample_count==0 and r.deferred_descent_count==0 and r.consumed_total==budget and f.calls==budget)
 end
 for _,mode in ipairs({'wall','down_blocked','unknown_horizontal','unknown_down','life_horizontal','life_down','reenter','throw_horizontal','rising','flat','missing'})do
  local f=descent(mode);local r=f:run()
  check('descent negative '..mode,r.status~='sampled_clear' and r.deferred_descent_count==0 and r.consumed_total==f.calls and f.max<=1)
  if mode=='wall' or mode=='down_blocked' then check('failed descent uses bounded refinement '..mode,r.reason=='sweep_blocking' and r.refinement_count==2)end
  if mode=='reenter' then check('descent reentry latches',r.reason=='binding_changed' and f.nested.reason=='reentrant_poll')end
 end
end
print(string.format('%d passed, %d failed',pass,fail)); os.exit(fail==0 and 0 or 1)
