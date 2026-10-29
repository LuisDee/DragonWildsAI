local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local M=assert(loadfile(here..'/../scripts/sampled_ground_walk.lua'))()
local pass,fail=0,0
local function check(s,v) if v then pass=pass+1 else fail=fail+1; print('FAIL '..s) end end
local function known(v) return {known=true,value=v} end
local function setup()
 local f={calls=0,mode='clear',alive=true,sw=0}
 f.opts={from_center={X=0,Y=0,Z=90},to_feet={X=40,Y=0,Z=0},radius_cm=20,half_height_cm=90,step_cm=45,clearance_cm=2,spacing_cm=20,budget=20,poll_budget=2,
 live=function() return f.alive end}
 f.opts.floor=function(p,remaining)
  f.calls=f.calls+1; f.last_remaining=remaining
  local line=f.mode=='line'; local pz=f.mode=='bad' and nil or false
  local floor={bBlockingHit=known(f.mode~='inconsistent'),bWalkableFloor=known(f.mode~='unsupported'),bLineTrace=known(line),FloorDist=known(p.Z-92),LineDist=known(p.Z-92),hit={bStartPenetrating=known(pz)}}
  if f.mode=='wrong_floor' then floor.FloorDist=known(p.Z-300) end
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
check('raised search and grounded centres',r.samples[1].raised.Z==130.5 and r.samples[1].resolved.Z==94 and r.samples[1].support.distance_cm==38.5)
check('actual centre is first sweep origin',r.samples[1].expected.X==10 and r.start_floor.start_penetrating==false)
r.samples[1].resolved.Z=999; check('terminal returns independent snapshots',tx.poll().samples[1].resolved.Z==94)
f=setup(); f.opts.overlap=nil; tx=f:start(); r=f:run(); check('floor does not prove initial overlap',r.status=='unknown' and r.reason=='initial_overlap_unknown' and r.completed_samples==4)
for _,pair in ipairs({{'unsupported','floor_not_walkable','blocked'},{'penetrating','floor_initial_penetration','blocked'},
 {'wall','sweep_blocking','blocked'},{'ceiling','sweep_blocking','blocked'},{'overlap','overlap_blocking','blocked'},
 {'missing','floor_fields_unknown','unknown'},{'callback_missing','floor_unknown','unknown'},{'inconsistent','floor_flags_inconsistent','unknown'},{'sweep_unknown','sweep_unknown','unknown'},{'overlap_unknown','overlap_unknown','unknown'},
 {'wrong_floor','floor_resolution_out_of_bounds','unknown'},{'life','binding_changed','unknown'}}) do
 f=setup(); f.mode=pair[1]; tx=f:start(); r=f:run(); check(pair[1],r.status==pair[3] and r.reason==pair[2])
end
f=setup(); f.mode='line'; tx=f:start(); r=f:run(); check('line result uses LineDist',r.status=='sampled_clear' and r.samples[1].support.line_trace==true)
f=setup(); f.opts.overlap=nil; f.mode='negative_start'; tx=f:start(); r=f:run(); check('negative start distance not penetration',r.reason=='initial_overlap_unknown' and r.start_floor.distance_cm==-0.58)
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
tx=f:start(); r=f:run(); check('overflow before raised floor callback',r.status=='unknown' and r.reason=='invalid_derived_geometry' and f.calls==2 and f.sw==0)
f=setup(); f.opts.from_center.Z=1e308; f.opts.to_feet.Z=1e308
local original_floor=f.opts.floor
f.opts.floor=function(p,n)
 check('floor callback receives finite coordinates',p.X==p.X and p.Y==p.Y and p.Z==p.Z and math.abs(p.X)<math.huge and math.abs(p.Y)<math.huge and math.abs(p.Z)<math.huge)
 local obs=original_floor(p,n); if f.calls>2 then obs.fields.FloorDist=known(-1e308) end; return obs
end
tx=f:start(); r=f:run(); check('resolved overflow never reaches sweep',r.status=='unknown' and r.reason=='invalid_derived_geometry' and f.sw==0)
print(string.format('%d passed, %d failed',pass,fail)); os.exit(fail==0 and 0 or 1)
