-- Read-only terrain observations, not routing authority. Reuse localplan's finite native
-- sampling; retain history separately from the player's current task.
-- https://www.cs.cmu.edu/~motionplanning/papers/sbp_papers/integrated2/yamauchi_frontier_explor.pdf
-- Frontier/history precedent only: our knee rays do NOT establish traversability.
-- https://ompl.kavrakilab.org/classompl_1_1geometric_1_1LazyPRM.html
-- Retained observations survive a query; their validity is historical, never movement authority.
local M={}
local stores={}
local active
M.MAX_WINDOWS=4;M.MAX_ATTEMPTS=128;M.MAX_EDGES=2000
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function cp(v,depth)
    depth=depth or 0;if depth>12 then return nil end
    if type(v)=='number' then return finite(v) and v or nil end
    if type(v)=='string' then return v:sub(1,180) end
    if type(v)=='boolean' then return v end
    if type(v)~='table' then return nil end
    local mt=getmetatable(v)
    if mt then
        if type(mt)~='table' or (mt.__jsontype~='object' and mt.__jsontype~='array')then return nil end
        for k in pairs(mt)do if k~='__jsontype'then return nil end end
    end
    local r={};for k,x in pairs(v)do if type(k)=='string' or type(k)=='number' then r[k]=cp(x,depth+1)end end;return r
end
local function vec(p)return {X=p.X,Y=p.Y,Z=p.Z}end
local function pos(p)return p and {p.X/100,p.Y/100,p.Z/100}end
local function same(a,b)return a and b and a.X==b.X and a.Y==b.Y and a.Z==b.Z end
local function xy(a,b)return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2)end
local function xyz(a,n)
    if type(a)~='table' or #a~=n then return false end
    for i=1,n do if not finite(a[i]) then return false end end;return true
end
local function ck(x,y)return ('%.6f:%.6f'):format(x,y)end
local function nk(p)return ck(p.X,p.Y)..(':%0.6f'):format(p.Z)end
local function count(t)local n=0;for _ in pairs(t or {})do n=n+1 end;return n end
local function result(ok,reason,data)return {ok=ok,reason=reason,data=data or {}}end
local function read(path)local f=io.open(path,'rb');if not f then return nil end;local s=f:read('a');f:close();return s end

-- Only this module writes this file. Keep a recoverable previous image on Windows,
-- where rename cannot replace an existing destination; never delete the sole image.
function M.new_store(o)
    assert(type(o.world)=='string' and o.world:match('^[%w_-]+$'),'world_identity_unavailable')
    local dir=o.root..'/data/skills/'..o.world
    local path=dir..'/terrain_observations.json';local J=o.json
    local data={version=1,world=o.world,revision=0,windows={},attempts={},evicted_windows=0,evicted_attempts=0}
    local raw=read(path) or read(path..'.bak')
    if raw then local ok,d=pcall(J.decode,raw);if ok and type(d)=='table' and d.version==1 and d.world==o.world and
        type(d.windows)=='table' and type(d.attempts)=='table' then data=d end end
    data.revision=tonumber(data.revision) or 0;data.evicted_windows=tonumber(data.evicted_windows) or 0
    data.evicted_attempts=tonumber(data.evicted_attempts) or 0
    while #data.windows>M.MAX_WINDOWS do table.remove(data.windows,1);data.evicted_windows=data.evicted_windows+1 end
    while #data.attempts>M.MAX_ATTEMPTS do table.remove(data.attempts,1);data.evicted_attempts=data.evicted_attempts+1 end
    -- Old images are bounded again before use. No unknown serialized edge acquires authority.
    for _,w in ipairs(data.windows)do
        w.columns=type(w.columns)=='table' and w.columns or {};while #w.columns>361 do table.remove(w.columns)end
        for _,c in ipairs(w.columns)do c.floor_heights_m=type(c.floor_heights_m)=='table' and c.floor_heights_m or {};while #c.floor_heights_m>2 do table.remove(c.floor_heights_m)end end
        w.edges=type(w.edges)=='table' and w.edges or {};while #w.edges>M.MAX_EDGES do table.remove(w.edges)end
    end
    local store={data=data,path=path,pins={},persisted=true}
    function store:save()
        local made=pcall(o.ensure_dir,dir);if not made then self.persisted=false;return false end
        local f=io.open(path..'.tmp','wb');if not f then self.persisted=false;return false end
        local ok=pcall(function()assert(f:write(J.encode(data)));assert(f:close())end)
        if not ok then pcall(function()f:close()end);self.persisted=false;return false end
        if os.rename(path..'.tmp',path) then self.persisted=true;return true end
        os.remove(path..'.bak')
        local previous=read(path)~=nil
        if previous and not os.rename(path,path..'.bak') then self.persisted=false;return false end
        if not os.rename(path..'.tmp',path) then if previous then os.rename(path..'.bak',path)end;self.persisted=false;return false end
        self.persisted=true;return true
    end
    function store:reserve()
        if #data.windows>=M.MAX_WINDOWS then
            local found;for i,w in ipairs(data.windows)do if not self.pins[w.window_id]then found=i;break end end
            if not found then return nil,'capacity' end
            table.remove(data.windows,found);data.evicted_windows=data.evicted_windows+1
        end
        data.revision=data.revision+1
        local w={window_id='terrain-'..data.revision,revision=data.revision,status='partial',columns={},edges={}}
        data.windows[#data.windows+1]=w;self.pins[w.window_id]=true;return w
    end
    function store:note_move(id,target,res,start)
        if type(res)~='table' then return end
        for _,a in ipairs(data.attempts)do if a.request_id==id then return end end
        local d=type(res.data)=='table' and res.data or {};local rf=type(d.route_feedback)=='table' and d.route_feedback or {}
        local a={request_id=tostring(id):sub(1,100),tool='go_to',requested_target=cp(target),actual_start=cp(start),
            actual_end=cp(d.position or rf.final_position),partial_endpoint=cp(rf.route_endpoint),
            partial=rf.partial,ok=res.ok==true,reason=res.reason,detail=type(d.detail)=='string' and d.detail:sub(1,160) or nil,
            observed_at=o.clock(),clock='unix_seconds',observation_revision=data.revision,provenance='unknown',endpoint_convention='reported_by_mover'}
        data.attempts[#data.attempts+1]=a
        if #data.attempts>M.MAX_ATTEMPTS then table.remove(data.attempts,1);data.evicted_attempts=data.evicted_attempts+1 end
        self:save()
    end
    return store
end

local function packet(store,w,mode,now)
    local d=store.data;local out={version=1,mode=mode,status=w and w.status or 'historical',revision=d.revision,
        world=d.world,provenance='unknown',build='unknown',attempts={},limitations={'Candidate floors/ray checks are not capsule clearance or a route. Historical layers/age are not live movement authority.'},
        coverage={history_truncated=(d.evicted_windows or 0)>0},persisted=store.persisted}
    for i=math.max(1,#d.attempts-3),#d.attempts do out.attempts[#out.attempts+1]=cp(d.attempts[i])end
    if w then
        out.window_id=w.window_id;out.request_id=w.request_id;out.source=cp(w.source);out.objective_center_m=cp(w.objective_center_m)
        if out.source then
            local t=out.source.observed_at;out.source.age_s=finite(t) and now>=t and now-t or 'unknown'
        end
        out.coverage=cp(w.coverage or out.coverage);out.coverage.history_truncated=(d.evicted_windows or 0)>0
        out.candidates=cp(w.candidates or {});out.layered_columns={total=0,columns={}}
        out.discovery_context=cp(w.discovery_context)
        for _,c in ipairs(w.columns or {})do if #(c.floor_heights_m or {})>1 then
            out.layered_columns.total=out.layered_columns.total+1
            if #out.layered_columns.columns<8 then out.layered_columns.columns[#out.layered_columns.columns+1]=cp(c)end
        end end
        out.layered_columns.returned=#out.layered_columns.columns;out.layered_columns.truncated=out.layered_columns.total>out.layered_columns.returned
        out.detail=w.detail
    end
    return out
end

function M.query(store,args,now)
    local d=store.data;local w=d.windows[#d.windows]
    if args.mode=='window' then
        w=nil;for _,row in ipairs(d.windows)do if row.window_id==args.window_id then w=row;break end end
        if not w then return result(false,'verification_failed',{detail='not_retained'})end
    end
    local out=packet(store,w,args.mode or 'history',now);out.status='historical'
    if args.mode=='window' then
        local rows={};for _,c in ipairs(w.columns)do
            if not args.column_m or (c.column_m[1]==args.column_m[1] and c.column_m[2]==args.column_m[2])then rows[#rows+1]=c end
        end
        if args.column_m and #rows==0 then return result(false,'verification_failed',{detail='not_retained'})end
        out.columns={};local cursor=args.cursor or 0;local limit=args.limit or 8
        for i=cursor+1,math.min(#rows,cursor+limit)do out.columns[#out.columns+1]=cp(rows[i])end
        out.cursor=cursor;out.total=#rows;if cursor+#out.columns<#rows then out.next_cursor=cursor+#out.columns end
    else
        out.windows={};for _,row in ipairs(d.windows)do
            local source=cp(row.source)
            if source then
                local at=source.observed_at
                source={observed_at=at,clock=source.clock,age_s=finite(at) and now>=at and now-at or 'unknown'}
            end
            out.windows[#out.windows+1]={window_id=row.window_id,status=row.status,source=source}
        end
    end
    return result(true,nil,{terrain=out})
end

local function capture(store,w,P,query,hh)
    w.columns={};w.edges={};local nodes={};local node_ids={}
    for _,layers in pairs(P.nodes)do for _,n in ipairs(layers)do local x,y=P:pos(n.i,n.j);local p={X=x,Y=y,Z=n.z};node_ids[tostring(n)]=p;nodes[nk(p)]=p end end
    for i=1,P.qi-1 do
        local q=P.queue[i];local x,y=P:pos(q[1],q[2]);local zs={}
        for _,n in ipairs(P.nodes[q[1]*4096+q[2]] or {})do zs[#zs+1]=n.z/100 end;table.sort(zs)
        w.columns[#w.columns+1]={column_m={x/100,y/100},floor_heights_m=zs,
            source=xy({X=x,Y=y},query)<P.self_r and 'self_feet_substitution' or (#zs>0 and 'line_hit_candidate' or 'no_candidate_observed'),layer_identity='unknown'}
    end
    local prior={};for _,old in ipairs(store.data.windows)do if old~=w then for _,c in ipairs(old.columns)do prior[ck(c.column_m[1],c.column_m[2])]=true end end end
    local cov={sampled_columns=#w.columns,total_columns=#P.queue,unvisited_columns=#P.queue-#w.columns,new_columns=0,overlap_columns=0,
        no_candidate_columns=0,reference='retained_prior_windows',history_truncated=store.data.evicted_windows>0}
    for _,c in ipairs(w.columns)do
        if prior[ck(c.column_m[1],c.column_m[2])]then cov.overlap_columns=cov.overlap_columns+1 else cov.new_columns=cov.new_columns+1 end
        if #c.floor_heights_m==0 then cov.no_candidate_columns=cov.no_candidate_columns+1 end
    end
    w.coverage=cov
    local graph={}
    for key in pairs(P.edge_ok)do
        local a,b=key:match('^(.-)>(.*)$');a,b=node_ids[a],node_ids[b]
        if a and b and #w.edges<M.MAX_EDGES then
            w.edges[#w.edges+1]={from_floor_m=pos(a),to_floor_m=pos(b),kind='planner_ray_checks'}
            local ak=nk(a);graph[ak]=graph[ak]or {};graph[ak][#graph[ak]+1]=b
        end
    end
    local root=P.observation_start and node_ids[tostring(P.observation_start)] or nil
    w.discovery_context={root_floor_position_m=root and pos(root) or nil,actual_source_connector='unknown',
        path_length_basis='planner_root',ray_scope='knee_height_with_self_region_exclusion'}
    local queue=root and {root}or {};local seen={};local distances={};if root then seen[nk(root)]=true;distances[nk(root)]=0 end
    for _,a in ipairs(queue)do for _,b in ipairs(graph[nk(a)] or {})do if not seen[nk(b)]then
        seen[nk(b)]=true;distances[nk(b)]=distances[nk(a)]+xy(a,b);queue[#queue+1]=b
    end end end
    local ranked={};local union={};for _,old in ipairs(store.data.windows)do for _,c in ipairs(old.columns)do union[ck(c.column_m[1],c.column_m[2])]=true end end
    for _,n in ipairs(queue)do if xy(n,query)>150 then
        local cx=math.floor(n.X/P.cell+.5)*P.cell;local cy=math.floor(n.Y/P.cell+.5)*P.cell;local new=0
        for di=-P.r,P.r do for dj=-P.r,P.r do if not union[ck((cx+di*P.cell)/100,(cy+dj*P.cell)/100)]then new=new+1 end end end
        ranked[#ranked+1]={p=n,new=new,length=distances[nk(n)]}
    end end
    table.sort(ranked,function(a,b)if a.new~=b.new then return a.new>b.new end;if a.length~=b.length then return a.length>b.length end;return nk(a.p)<nk(b.p)end)
    w.candidates={}
    for _,row in ipairs(ranked)do
        local separate=true;for _,selected in ipairs(w.candidates)do if xy(row.p,{X=selected.floor_position_m[1]*100,Y=selected.floor_position_m[2]*100})<200 then separate=false end end
        if separate and #w.candidates<3 then
            local n=row.p;local target={X=n.X,Y=n.Y,Z=n.Z+hh}
            w.candidates[#w.candidates+1]={observation_candidate_id=w.window_id..':'..(#w.candidates+1),window_id=w.window_id,
                floor_position_m=pos(n),derived_capsule_center_m=pos(target),half_height_m=hh/100,derivation='floor_plus_current_half_height',
                source='localplan',connection='planner_root_ray_checks',capsule_clearance='unknown',
                planner_path_length_m=row.length/100,predicted_new_columns=row.new,purpose=row.new>0 and 'new_columns' or 'unknown_connection',
                original_goal_distance_m=w.objective_center_m and xy(target,{X=w.objective_center_m[1]*100,Y=w.objective_center_m[2]*100})/100 or nil}
        end
    end
end

function M.validate(args)
    if type(args)~='table' then return nil,'arguments required' end
    local out=cp(args);local allowed={mode=true,toward=true,window_id=true,column_m=true,cursor=true,limit=true}
    for k in pairs(args)do if not allowed[k]then return nil,'unknown argument' end end
    out.mode=args.mode==nil and 'survey' or args.mode
    if out.mode~='survey' and out.mode~='history' and out.mode~='window' then return nil,'invalid mode' end
    if out.toward and (out.mode~='survey' or not xyz(out.toward,3))then return nil,'toward requires three finite centre coordinates' end
    if out.mode=='window' and (type(out.window_id)~='string' or #out.window_id<1 or #out.window_id>80)then return nil,'window_id required' end
    if out.window_id and out.mode~='window' then return nil,'window_id only for window mode' end
    if out.column_m and (out.mode~='window' or not xyz(out.column_m,2))then return nil,'column_m only for window mode' end
    for key,default in pairs({cursor=0,limit=8})do
        local n=args[key];if n==nil then n=default end
        if not finite(n) or n%1~=0 or n<(key=='cursor' and 0 or 1) or (key=='limit' and n>24)then return nil,'invalid '..key end
        out[key]=n
    end
    return out
end

-- Testable job driver uses the same LP and same trace factory as the live body.
-- No hypothetical capsule support, hook lease, arbiter request or movement here.
function M.survey(o,args,ctx)
    if active then return result(false,'busy',{detail='terrain survey already active'})end
    if not o.live()then return result(false,'busy',{detail='survey needs an idle stationary character'})end
    local w,why=o.store:reserve();if not w then return result(false,'verification_failed',{detail=why})end
    local marker={};active=marker
    local start,cpu=o.clock(),o.cpu();local total,poll_queries=0,0;local terminal,job,P
    local generation_live=true;local failure_detail
    w.request_id=tostring(ctx.id or 'unknown'):sub(1,100);w.objective_center_m=cp(args.toward)
    w.source={actual_capsule_center_m=pos(o.source),half_height_m=o.half_height/100,observed_at=start,clock='unix_seconds',age_s=0}
    local function live()
        if o.clock()<start then failure_detail='clock_changed'
        elseif o.clock()-start>=8 then failure_detail='wall_deadline'
        elseif o.cpu()-cpu>=8 then failure_detail='cpu_budget'end
        if terminal or not generation_live or active~=marker or failure_detail or not o.live()then
            generation_live=false;return false
        end
        return true
    end
    local function charge()
        assert(live(),'observation_interrupted')
        if total>=2000 or poll_queries>=16 then failure_detail=total>=2000 and 'query_budget' or 'poll_query_budget';error(failure_detail)end
        total=total+1;poll_queries=poll_queries+1
    end
    local function finish(ok,reason,detail)
        if terminal then return cp(terminal)end
        if ok and not live()then ok=false;reason='interrupted';detail=failure_detail or 'terrain observation invalidated'end
        generation_live=false
        if P then capture(o.store,w,P,o.source,o.half_height)end
        if o.clock()-start>=8 then ok=false;reason='timeout';detail='wall_deadline'end
        w.status=ok and 'complete' or 'partial';w.detail=detail;w.queries=total
        if w.coverage then w.coverage.geometry_queries=total;w.coverage.verification_reason=why end
        o.store.pins[w.window_id]=nil;if active==marker then active=nil end
        o.store:save()
        local data={terrain=packet(o.store,w,'survey',o.clock()),detail=detail}
        terminal=result(ok,reason,data);return cp(terminal)
    end
    local phase='start';local pts,blocked= nil,0;local polling=false
    job={kind='terrain'}
    function job:poll()
        if terminal then return cp(terminal)end
        if polling then return finish(false,'interrupted','reentrant terrain observation')end
        if not live() then return finish(false,o.clock()-start>=8 and 'timeout' or 'interrupted',failure_detail or 'terrain observation invalidated')end
        polling=true
        poll_queries=0
        local ok,answer=pcall(function()
            if phase=='start' then
                local trace=o.trace(live,charge)
                assert(live(),'observation_interrupted')
                P=o.lp.new{trace=trace,center=vec(o.source),feet_z=o.source.Z-o.half_height,radius_m=9,cell_cm=100,
                    env=cp(o.env),cache=nil,now=o.clock,self_pos=vec(o.source)}
                phase='sampling'
            end
            if phase=='sampling' then
                local state=P:step(math.max(0,16-poll_queries))
                assert(live(),'observation_interrupted')
                if state=='ready' then
                    if not args.toward then return finish(true,nil,'floor candidates only; connectivity unknown')end
                    pts,why=P:plan({X=args.toward[1]*100,Y=args.toward[2]*100,Z=args.toward[3]*100-o.half_height})
                    if not pts then return finish(true,nil,'bounded planner observation: '..tostring(why))end
                    phase='verifying'
                end
                return nil
            end
            local status=P:verify(pts,16)
            assert(live(),'observation_interrupted')
            if status=='ok' then why='ray_proposal';return finish(true,nil,'ray proposal only; capsule clearance unknown')end
            if status=='blocked' then
                blocked=blocked+1
                if blocked<=12 then pts,why=P:plan({X=args.toward[1]*100,Y=args.toward[2]*100,Z=args.toward[3]*100-o.half_height})
                else pts=nil;why='verification_budget_exhausted'end
                if not pts then return finish(true,nil,'bounded planner observation: '..tostring(why))end
            end
        end)
        polling=false
        if not ok then return finish(false,failure_detail and 'verification_failed' or 'interrupted',failure_detail or 'terrain observation unavailable')end
        return answer
    end
    function job:expire()return finish(false,'timeout','terrain observation deadline')end
    function job:cancel()return finish(false,'interrupted','terrain observation cancelled')end
    job.pause_cleanup=job.cancel
    return {wait=job,wait_s=8}
end

local function store_for(api,world)
    if type(world)~='string' or not world:match('^[%w_-]+$')then return nil end
    local root=api.client_root();local key=root..'/'..world
    if not stores[key]then
        local J=api.module('dkjson');if not J then return nil end
        stores[key]=M.new_store{root=root,world=world,json=J,ensure_dir=api.ensure_dir,clock=os.time}
    end
    return stores[key]
end
local function world()local w=rawget(_G,'DW_WORLD_GUID');return type(w)=='string' and w or nil end
function M.state_extras(api)
    local store=store_for(api,world());if not store or #store.data.windows==0 then return {}end
    return {terrain=M.query(store,{mode='history'},os.time()).data.terrain}
end
function M.note_move(api,id,target,res,start,action_world)
    local store=store_for(api,action_world or world());if store and #store.data.windows>0 then
        store:note_move(id,target,res,start);return M.query(store,{mode='history'},os.time()).data.terrain
    end
end

function M.handle(api,args,ctx)
    local parsed,why=M.validate(args);if not parsed then return result(false,'invalid_args',{detail=why})end
    local store=store_for(api,world());if not store then return result(false,'state_unavailable',{detail='terrain world storage unavailable'})end
    if parsed.mode~='survey'then return M.query(store,parsed,os.time())end
    if api.terrain_busy()then return result(false,'busy',{detail='another action owns the character'})end
    local sense,move=api.module('sense'),api.module('move')
    if not sense or not move or type(move.terrain_observation_trace)~='function' or type(move._envelope)~='function'then return result(false,'not_implemented')end
    local ok,options=pcall(function()
        local pc=sense.local_pc();local pawn=pc and sense.local_pawn(pc);assert(pawn and pc,'no_character')
        local st=rawget(_G,'DW_MOVE');local arb=rawget(_G,'DWArbiter');local w=world();local life=rawget(_G,'DW_LIFE')
        local seq=type(life)=='table' and life.move_death_seq or nil;local gen=st and st.gen
        local address=pawn:GetAddress();local source=vec(pawn:K2_GetActorLocation());local cap=pawn.CapsuleComponent;local mc=pawn.CharacterMovement
        local cap_id,mc_id=cap:GetAddress(),mc:GetAddress()
        local hh,radius=cap:GetScaledCapsuleHalfHeight(),cap:GetScaledCapsuleRadius();local step=mc.MaxStepHeight
        local profile=rawget(_G,'DW_TRACE_PROFILE');local profile_name=type(profile)=='table' and profile.name or nil
        local latched=false
        local function live()
            if latched then return false end
            local worked,current=pcall(function()
                if rawget(_G,'DW_PAUSE') or world()~=w or api.terrain_busy() or not api.terrain_channel_current(ctx.chan) or
                    rawget(_G,'DW_MOVE')~=st or not st or st.gen~=gen or st.mode~='idle' or rawget(_G,'DWArbiter')~=arb or
                    (arb and (arb.owner~=nil or #(arb.stack or {})>0)) or rawget(_G,'DW_TRACE_PROFILE')~=profile or
                    (profile and profile.name~=profile_name)then return false end
                local l=rawget(_G,'DW_LIFE');if (type(l)=='table' and l.move_death_seq or nil)~=seq then return false end
                if not pawn:IsValid() or not pc:IsValid() or pawn:GetAddress()~=address or not pc.Pawn or pc.Pawn:GetAddress()~=address or
                    pawn.CapsuleComponent:GetAddress()~=cap_id or pawn.CharacterMovement:GetAddress()~=mc_id or cap:GetScaledCapsuleHalfHeight()~=hh or cap:GetScaledCapsuleRadius()~=radius or mc.MaxStepHeight~=step or
                    pawn.HealthComponent:IsDead()~=false or pawn.HealthComponent:GetAuthoritativeHealth()<=0 or mc:IsMovingOnGround()~=true then return false end
                local p=pawn:K2_GetActorLocation()
                local last_life=rawget(_G,'DW_LIFE')
                return same(p,source) and not rawget(_G,'DW_PAUSE') and world()==w and rawget(_G,'DW_MOVE')==st and st.gen==gen and st.mode=='idle' and
                    (type(last_life)=='table' and last_life.move_death_seq or nil)==seq and rawget(_G,'DWArbiter')==arb and
                    (not arb or (arb.owner==nil and #(arb.stack or {})==0)) and rawget(_G,'DW_TRACE_PROFILE')==profile and
                    (not profile or profile.name==profile_name) and not api.terrain_busy()
            end)
            if not worked or current~=true then latched=true;return false end;return true
        end
        assert(finite(hh) and hh>0 and finite(radius) and radius>0 and finite(step) and step>0 and live(),'binding_unknown')
        local env=move._envelope(pawn,pc);assert(live(),'binding_changed')
        env=cp(env);env.jump,env.djump,env.superjump,env.drop=0,0,nil,env.step
        return {source=source,half_height=hh,env=env,live=live,clock=os.time,cpu=os.clock,store=store,lp=api.module('localplan'),
            trace=function(valid,charge)return move.terrain_observation_trace({},pawn,source,hh,valid,charge)end}
    end)
    if not ok then return result(false,'busy',{detail='terrain needs an idle live stationary character'})end
    return M.survey(options,parsed,ctx)
end
M.HANDLERS={terrain=function(_,args,ctx)return M.handle(ctx.api,args,ctx)end}
return M
