-- Public JSONL bridge + real terrain/localplan, finite fake native line observations.
local here=debug.getinfo(1,'S').source:match('^@(.*)[/\\][^/\\]*$')or'.'
local root=here..'/../..';local H=dofile(root..'/mod/tests/bridge_harness.lua')
local J=assert(loadfile(here..'/../scripts/dkjson.lua'))();local base=assert(arg[1]);local scripts=base..'/scripts';local dir=base..'/bridge'
local function mkdir(p)if package.config:sub(1,1)=='\\'then os.execute('mkdir "'..p:gsub('/','\\')..'" 2>nul')else os.execute('mkdir -p "'..p..'"')end end
mkdir(scripts);mkdir(dir)
local function read(p)local f=assert(io.open(p,'rb'));local s=f:read('a');f:close();return s end
local function write(p,s)local f=assert(io.open(p,'wb'));f:write(s);f:close()end
for _,n in ipairs({'terrain','localplan','dkjson','manifest'})do write(scripts..'/'..n..'.lua',read(here..'/../scripts/'..n..'.lua'))end
for _,n in ipairs({'sense','move','inventory','chat'})do write(scripts..'/'..n..'.lua',read(here..'/fakes/'..n..'.lua'))end
local function append_before_return(name,s)local path=scripts..'/'..name..'.lua';write(path,(read(path):gsub('return M%s*$',function()return s..'\nreturn M'end)))end
append_before_return('sense',[[
function M.local_pc()return FAKE.pc end
function M.local_pawn()return FAKE.pawn end
]])
append_before_return('move',[[
function M._envelope()return {step=45,jump=100,djump=100,drop=450,head=190}end
function M.terrain_observation_trace(_,p,from,hh,live,charge)
 return function(a,b,horizontal)
  charge();FAKE.rays=FAKE.rays+1
  if FAKE.mutation then local f=FAKE.mutation;FAKE.mutation=nil;f()end
  assert(live(),'binding changed')
  if horizontal then return false end
  return 0,false
 end
end
local go=M.go_to;function M.go_to(...)DW_MOVE.gen=DW_MOVE.gen+1;DW_MOVE.mode='go_to';return go(...)end
local status=M.status;function M.status(...)local r=status(...);DW_MOVE.mode=r.mode;return r end
local stop=M.stop;function M.stop(...)DW_MOVE.gen=DW_MOVE.gen+1;DW_MOVE.mode='idle';return stop(...)end
]])
_G.DW_WORLD_GUID='terrain_bridge_test';_G.DW_LIFE={move_death_seq=0};_G.DW_MOVE={gen=1,mode='idle'}
_G.DWArbiter={owner=nil,stack={}};_G.DW_TRACE_PROFILE={name='Player'}
_G.FAKE={move={mode='idle',calls={}}}
FAKE.me_pos={0,0,.88};FAKE.rays=0
local cap={GetAddress=function()return 2 end,GetScaledCapsuleHalfHeight=function()return 88 end,GetScaledCapsuleRadius=function()return 34 end}
local mc={MaxStepHeight=45,GetAddress=function()return 3 end,IsMovingOnGround=function()return true end}
FAKE.pawn={CapsuleComponent=cap,CharacterMovement=mc,HealthComponent={IsDead=function()return false end,GetAuthoritativeHealth=function()return 100 end},
 IsValid=function()return true end,GetAddress=function()return 1 end,K2_GetActorLocation=function()
  local p=FAKE.move.position or FAKE.me_pos;return {X=p[1]*100,Y=p[2]*100,Z=p[3]*100}
 end}
FAKE.pc={Pawn=FAKE.pawn,IsValid=function()return true end}
local B=assert(loadfile(here..'/../scripts/client_bridge.lua'))();B.RELOAD_CHECK_S=0
local clock=100;B.clock=function()return clock end
B.start{root=root,dir=dir,scripts=scripts,no_loop=true,start_modules=false,chat_events=base..'/chat.jsonl',jlog=H.log}
B.API.client_root=function()return base end
local seq,offset,pass=0,0,0
local function check(s,v)assert(v,s);pass=pass+1 end
local function drain()
 local f=io.open(dir..'/client_to_brain.jsonl','rb');if not f then return {}end;f:seek('set',offset);local s=f:read('a');offset=f:seek();f:close()
 local rows={};for l in s:gmatch('[^\n]+')do rows[#rows+1]=assert(J.decode(l))end;return rows
end
local function send(tool,args)
 seq=seq+1;local id='t'..seq;local f=assert(io.open(dir..'/brain_to_client.jsonl','ab'))
 f:write(J.encode{v=1,type='cmd',id=id,tool=tool,args=args or {}}..'\n');f:close();B.step();return id,drain()
end
local function find(rows,id)for _,r in ipairs(rows)do if r.type=='result' and r.id==id then return r end end end
local id,rows=send('terrain',{})
check('read occupies waiter only',not find(rows,id) and B._state().action==nil and #B._state().waiters==1)
local ping,pr=send('ping',{});check('ping retains active read identity',find(pr,ping).ok)
local read_id=id;local answer
for _=1,70 do local before=FAKE.rays;B.step();check('actual bridge slice max16',FAKE.rays-before<=16);answer=find(drain(),read_id);if answer then break end end
check('public read completes',answer and answer.ok and answer.data.terrain.coverage.sampled_columns==361)
check('no input from survey',#FAKE.move.calls==0)
local sid,sr=send('get_state',{});local state=find(sr,sid)
check('get_state terrain projection',state.ok and state.data.terrain.window_id==answer.data.terrain.window_id)
local hid,hr=send('terrain',{mode='history'});check('history immediate',find(hr,hid).data.terrain.status=='historical' and #B._state().waiters==0)
local mid,mr=send('go_to',{target={4,0,.88}});check('ordinary move accepted',B._state().action~=nil)
local bid,br=send('terrain',{});check('survey busy does not steal movement',find(br,bid).reason=='busy' and B._state().action~=nil)
FAKE.auto_arrive=true;B.step();local moved=find(drain(),mid)
check('ordinary outcome retained',moved and moved.ok and moved.data.terrain.attempts[1].requested_target[1]==4)
check('no fabricated start',moved.data.terrain.attempts[1].actual_start==nil)
local moving_calls=#FAKE.move.calls

for _,mutation in ipairs({
 function()DW_MOVE.gen=DW_MOVE.gen+1 end,
 function()DW_LIFE.move_death_seq=DW_LIFE.move_death_seq+1 end,
 function()DWArbiter.owner={token=9}end,
 function()DW_TRACE_PROFILE.name='Pawn'end,
 function()FAKE.move.position={5,0,.88}end})do
 DWArbiter.owner=nil;DW_MOVE.mode='idle';FAKE.move.mode='idle';DW_TRACE_PROFILE.name='Player'
 local q,rr=send('terrain',{});FAKE.mutation=mutation;B.step();local r=find(drain(),q)
 check('changed binding fails partial',r and not r.ok and r.data.terrain.status=='partial')
 check('mutation no input',#FAKE.move.calls==moving_calls)
end
DWArbiter.owner=nil;DW_MOVE.mode='idle';FAKE.move.mode='idle';DW_TRACE_PROFILE.name='Player'
local q=send('terrain',{});_G.DW_PAUSE=true;B.step();local paused=find(drain(),q)
check('pause terminates read',paused and not paused.ok and #B._state().waiters==0)
_G.DW_PAUSE=false
local terrain=B.module('terrain');local response=terrain.handle(B.API,{},{id='afterpause',chan=B._state().bridge})
check('pause releases marker',response.wait~=nil);response.wait:cancel()
local q2=send('terrain',{});clock=clock+8;B.step();local expired=find(drain(),q2)
check('bridge deadline terminates read',expired and not expired.ok)
-- Fresh live boot leaves move.S() uninitialized. A read must not need a prior
-- action or create movement state; later initialization revokes the read.
local saved_move=DW_MOVE;DW_MOVE=nil
local fresh=terrain.handle(B.API,{},{id='freshboot',chan=B._state().bridge})
check('fresh idle accepts survey without mover state',fresh.wait~=nil)
local fresh_result
for _=1,80 do fresh_result=fresh.wait:poll();if fresh_result then break end end
check('fresh idle completes without initializing mover',fresh_result and fresh_result.ok and DW_MOVE==nil)
local interrupted=terrain.handle(B.API,{},{id='freshboot-mutation',chan=B._state().bridge})
check('second cold survey accepted',interrupted.wait~=nil)
DW_MOVE={gen=0,mode='idle'}
local before_rays=FAKE.rays;local invalidated=interrupted.wait:poll()
check('new mover binding invalidates before geometry',not invalidated.ok and invalidated.reason=='interrupted' and FAKE.rays==before_rays)
DW_MOVE=saved_move
B.stop()
check('no floor reader acquired',rawget(_G,'DWFloorReader')==nil and rawget(_G,'DWWalkSenseServiceV1')==nil)
print('terrain_bridge: '..pass..' checks passed')
