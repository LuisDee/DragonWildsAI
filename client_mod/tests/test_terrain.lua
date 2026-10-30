-- Real localplan through the public terrain job driver; no native/game calls.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$')or'.'
local root=here..'/../..';local T=assert(loadfile(here..'/../scripts/terrain.lua'))()
local LP=assert(loadfile(here..'/../scripts/localplan.lua'))();local J=assert(loadfile(here..'/../scripts/dkjson.lua'))()
local base=assert(arg[1]);local pass=0
local function check(name,v)assert(v,name);pass=pass+1 end
local function mkdir(p)
 if package.config:sub(1,1)=='\\'then os.execute('mkdir "'..p:gsub('/','\\')..'" 2>nul')else os.execute('mkdir -p "'..p..'"')end
end
local seq=0
local function fixture()
 seq=seq+1
 local f={time=100,cpu=0,alive=true,queries=0,pose={X=0,Y=0,Z=88},mutate=nil,throw=false,wall=false}
 f.store=T.new_store{root=base,world='terrain_test_'..seq,json=J,ensure_dir=mkdir,clock=function()return f.time end}
 f.o={source=f.pose,half_height=88,env={step=45,jump=0,djump=0,drop=45,head=190},live=function()return f.alive end,
  clock=function()return f.time end,cpu=function()return f.cpu end,store=f.store,lp=LP}
 f.o.trace=function(live,charge)return function(a,b,horizontal)
  charge();f.queries=f.queries+1
  if f.mutate then f.mutate();f.mutate=nil end
  if f.throw then error('unknown query')end
  assert(live(),'source changed')
  if horizontal then return f.wall and true or false,{X=(a.X+b.X)/2,Y=(a.Y+b.Y)/2,Z=a.Z}end
  -- Four generic two-height columns: low/high first-hit rays report distinct layers.
  if f.slope then local z=a.X*.6;if z>a.Z then return nil end;return z,false end
  if a.X>=-(f.layer_count or 4)*100 and a.X<=-100 and a.Y==0 and a.X%100==0 then return a.Z>500 and 500 or 0,false end
  return 0,false
 end end
 function f:start(args)
  self.args=assert(T.validate(args or {}));local r=T.survey(self.o,self.args,{id=self.request_id or 'r'..seq})
  self.job=r.wait;return r
 end
 function f:run()
  local r
  for _=1,100 do local before=self.queries;r=self.job:poll();check('native poll bound',self.queries-before<=16)
   if r then return r end;self.time=self.time+.1
  end
  error('job did not finish')
 end
 return f
end

local f=fixture();check('read waiter',f:start().wait~=nil);local r=f:run()
check('floor survey completes',r.ok and r.data.terrain.status=='complete')
check('all cells retained',r.data.terrain.coverage.sampled_columns==361 and #f.store.data.windows[1].columns==361)
check('no fake goal or connected candidate',#r.data.terrain.candidates==0 and r.data.terrain.objective_center_m==nil)
check('rare layers retained',r.data.terrain.layered_columns.total==4 and #r.data.terrain.layered_columns.columns==4)
local id=r.data.terrain.window_id
local page=T.query(f.store,{mode='window',window_id=id,column_m={-4,0}},f.time)
check('rare column independently queryable',page.ok and #page.data.terrain.columns[1].floor_heights_m==2)
check('packet under summary budget',#J.encode(r.data.terrain)<7000)
check('historical source age',T.query(f.store,{mode='history'},f.time+10).data.terrain.source.age_s>=10)
local restart=T.new_store{root=base,world='terrain_test_1',json=J,ensure_dir=mkdir,clock=function()return f.time end}
check('restart retains source and layers',T.query(restart,{mode='window',window_id=id,column_m={-4,0}},f.time).data.terrain.columns[1].floor_heights_m[2]==5)
check('restart is historical',T.query(restart,{mode='history'},f.time).data.terrain.status=='historical')

f=fixture();f:start({toward={8,0,.88}});r=f:run()
check('actual planner candidate',r.ok and #r.data.terrain.candidates>0)
for _,c in ipairs(r.data.terrain.candidates)do
 check('floor centre separated',math.abs(c.derived_capsule_center_m[3]-c.floor_position_m[3]-.88)<1e-9)
 check('capsule remains unknown',c.capsule_clearance=='unknown' and c.derivation=='floor_plus_current_half_height')
end
check('small complete packet',#J.encode(r.data.terrain)<7000)
f.store:note_move('move1',{8,0,.88},{ok=false,reason='verification_failed',data={position={2,0,.88},route_feedback={partial=true,route_endpoint={2,0,0}}}})
f.store:note_move('move1',{8,0,.88},{ok=true,data={}})
check('result recorded once',#f.store.data.attempts==1 and not f.store.data.attempts[1].ok)
check('partial endpoint separate',f.store.data.attempts[1].partial_endpoint[3]==0 and f.store.data.attempts[1].actual_end[3]==.88)
for i=2,132 do f.store:note_move('move'..i,{i,0,.88},{ok=false,reason='verification_failed',data={}})end
check('attempt cap',#f.store.data.attempts==128 and f.store.data.evicted_attempts==4)

-- Shifted floor survey measures union coverage, retaining previous attempts.
f.o.source={X=600,Y=600,Z=88};f:start();r=f:run()
check('shifted actual union',r.data.terrain.coverage.new_columns==192 and r.data.terrain.coverage.overlap_columns==169)
check('failure continuity',#r.data.terrain.attempts==4 and not r.data.terrain.attempts[1].ok)
for _=1,5 do f:start();f.job:cancel()end
check('aborted windows also bounded and evictable',#f.store.data.windows==4 and f.store.data.evicted_windows==3)
local missing=T.query(f.store,{mode='window',window_id='terrain-1'},f.time)
check('eviction explicit',not missing.ok and missing.data.detail=='not_retained')
check('history discloses truncation',T.query(f.store,{mode='history'},f.time).data.terrain.coverage.history_truncated)
for _,w in ipairs(f.store.data.windows)do f.store.pins[w.window_id]=true end
check('active pins protected',f.store:reserve()==nil)

f=fixture();for _=1,3 do f:start();f:run()end
f.layer_count=8;f.request_id=string.rep('r',100);f:start({toward={8,0,.88}});r=f:run()
for i=1,4 do f.store:note_move(string.rep('m',98)..i,string.rep('x',180),{ok=false,reason='verification_failed',data={position={123456.789,123456.789,123456.789},detail=string.rep('d',160),route_feedback={partial=true,route_endpoint={123456.789,123456.789,123456.789}}}})end
local compact=T.query(f.store,{mode='history'},f.time).data.terrain
check('max regular rows present',compact.layered_columns.returned==8 and #compact.candidates==3 and #compact.attempts==4)
print('terrain max regular packet bytes: '..#J.encode(compact))
check('max regular packet byte bound',#J.encode(compact)<7*1024)

f=fixture();f.slope=true;f:start({toward={9,0,6.28}});r=f:run()
check('real LP slope boundary fails closed',not r.ok and r.data.terrain.detail=='poll_query_budget' and r.data.terrain.coverage.sampled_columns==361)

f=fixture();f.o.lp={new=function(o)local P=LP.new(o);local plan=P.plan
 function P:plan(goal)local pts,why=plan(self,goal);self.observation_start=nil;return pts,why end;return P end}
f:start({toward={8,0,.88}});r=f:run()
check('no inferred start connected candidates',r.ok and #r.data.terrain.candidates==0)

f=fixture();f.o.lp={new=function(o)local P=LP.new(o);local plan=P.plan
 function P:plan(goal)local pts,why=plan(self,goal);self.observation_start=self.nodes[4096][1];self.first_ok=true;return pts,why end;return P end}
f:start({toward={8,0,.88}});r=f:run()
check('valid nonactual root disclosed',r.ok and #r.data.terrain.candidates>0 and r.data.terrain.discovery_context.root_floor_position_m[1]==1)
check('root is not actual connector proof',r.data.terrain.discovery_context.actual_source_connector=='unknown' and r.data.terrain.source.actual_capsule_center_m[1]==0)
check('distance qualified by root',r.data.terrain.candidates[1].planner_path_length_m and r.data.terrain.candidates[1].path_length_m==nil and r.data.terrain.candidates[1].connection=='planner_root_ray_checks')

f=fixture()
local producer={new=function(o)
 local P=LP.new(o);local step=P.step
 function P:step(budget)local status=step(self,budget);if status=='ready'then
  self.verify=function()for _=1,16 do o.trace({X=0,Y=0,Z=50},{X=100,Y=0,Z=50},true)end;return 'verifying'end
 end;return status end
 return P
end}
f.o.lp=producer;f:start({toward={8,0,.88}})
for _=1,190 do local before=f.queries;r=f.job:poll();check('uncooperative producer poll bound',f.queries-before<=16);if r then break end end
check('total hard cap',r and not r.ok and r.data.terrain.detail=='query_budget' and f.queries==2000)

for _,kind in ipairs({'pose','throw','walltime','cpu','expire','cancel','reentrant'})do
 f=fixture();f:start()
 if kind=='pose'then f.mutate=function()f.alive=false end
 elseif kind=='throw'then f.throw=true
 elseif kind=='walltime'then f.time=f.time+8
 elseif kind=='cpu'then f.cpu=8
 elseif kind=='reentrant'then f.mutate=function()f.job:poll()end end
 if kind=='expire'then r=f.job:expire()elseif kind=='cancel'then r=f.job:cancel()else r=f:run()end
 check(kind..' failed partial',not r.ok and r.data.terrain.status=='partial')
 local before=f.queries;check(kind..' terminal no queries',not f.job:poll().ok and f.queries==before)
 local other=fixture();check(kind..' marker released',other:start().wait~=nil);other.job:cancel()
end

for _,args in ipairs({{mode='window'},{mode='window',window_id=''},{mode='history',toward={1,2,3}},{column_m={1,2}},
 {toward={1,2}},{cursor=0/0},{limit=false},{mode=false},{bad=true},{limit=25},{cursor=-1}})do
 check('argument rejection',T.validate(args)==nil)
end
local mf=assert(loadfile(here..'/../scripts/manifest.lua'))().TOOLS.terrain
check('read nonmoving manifest',mf.kind=='read' and mf.llm and mf.moves==false and mf.timeout_s==10)
print('terrain: '..pass..' checks passed')
