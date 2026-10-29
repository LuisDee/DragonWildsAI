-- Offline tests for client_mod/scripts/navmem.lua (navigation memory: routes + Dijkstra, traps,
-- taboos, seeds, persistence). Usage: lua test_navmem.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_navmem.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local NM = dofile(here .. "/../scripts/navmem.lua")
os.execute('mkdir "' .. (dir .. "/client_mod/scripts"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (dir .. "/data/nav"):gsub("/", "\\") .. '" 2>nul')
do
    local src = assert(io.open(here .. "/../scripts/dkjson.lua", "rb")):read("a")
    local f = assert(io.open(dir .. "/client_mod/scripts/dkjson.lua", "wb")); f:write(src); f:close()
end
local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end
local function P(x, y, z) return { X = x, Y = y, Z = z or 0 } end
local function line(x0, y0, x1, y1, n)
    local out = {}
    for k = 0, n do out[#out + 1] = P(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n, 0) end
    return out
end
-- Small, deliberately exhaustive oracle for the forward graph. It shares no
-- bucket or heap implementation with production and compares outcomes/costs.
local function reference_forward(mem,from,goal,progress)
    local nodes,edges={},{}
    local function add(p,tag) nodes[#nodes+1]={p=p,tag=tag};edges[#nodes]={};return #nodes end
    local function d3(a,b) return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2) end
    local function d2(a,b) return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2) end
    local function cost(a,b,base)
        local c=base or d3(a,b)
        if NM.is_taboo(mem,a,b) then c=c*NM.cfg.taboo_cost end
        if NM.is_water(mem,b) then c=c*NM.cfg.water_cost end
        return c
    end
    local function edge(a,b,c,recorded) edges[a][#edges[a]+1]={b,c,recorded} end
    for _,r in ipairs(mem.routes) do
        local ok=not r.seed and not r.disabled and (r.n_ok or 0)>0
        for _,p in ipairs(r.pts) do if p[4] then ok=false end end
        if ok then
            local prev
            for _,p in ipairs(r.pts) do
                local id=add(P(p[1]*100,p[2]*100,p[3]*100),r.id)
                if prev then edge(prev,id,cost(nodes[prev].p,nodes[id].p)*(1+(r.n_fail or 0)*0.5),true) end
                prev=id
            end
        end
    end
    local count=#nodes
    for i=1,count do for j=i+1,count do
        local a,b=nodes[i],nodes[j];local d=d3(a.p,b.p)
        if a.tag~=b.tag and d<NM.cfg.join_cm and math.abs(a.p.Z-b.p.Z)<120 then
            edge(i,j,cost(a.p,b.p,d*1.2));edge(j,i,cost(b.p,a.p,d*1.2))
        end
    end end
    local S=add(from,'start');local G=add(goal,'goal');local n=#nodes
    for i=1,count do
        local p=nodes[i].p;local a,b=d3(from,p),d3(p,goal)
        if a<NM.cfg.join_cm and math.abs(from.Z-p.Z)<120 then edge(S,i,cost(from,p,a*NM.cfg.entry_factor)) end
        if b<NM.cfg.join_cm and math.abs(goal.Z-p.Z)<120 then edge(i,G,cost(p,goal,b*NM.cfg.entry_factor)) end
    end
    local dist,done={[S]=0},{}
    while true do
        local u,best=nil,math.huge
        for k,v in pairs(dist) do if not done[k] and v<best then u,best=k,v end end
        if not u then break end;done[u]=true
        local base=u>n and u-n or u
        for _,e in ipairs(edges[base]) do
            local v=e[1]+((u>n or e[3]) and n or 0);local nd=best+e[2]
            if not dist[v] or nd<dist[v] then dist[v]=nd end
        end
    end
    if dist[G+n] then return goal,false,dist[G+n] end
    local best,remaining,cost0=nil,math.huge,math.huge
    for i=1,count do
        local c=dist[i+n];local d=d2(nodes[i].p,goal)
        if c and d2(from,goal)-d>=progress and (d<remaining or (d==remaining and c<cost0)) then
            best,remaining,cost0=nodes[i].p,d,c
        end
    end
    if best then return best,true,cost0 end
end
do
    local m=NM.new_mem('forward')
    NM.add_route(m,line(0,0,2000,0,20),{src='self'})
    local p=NM.forward_walk(m,P(200,0),P(1800,0))
    check('forward route admits interior endpoints',p and p[1].X < p[#p-1].X and p[#p].X==1800)
    check('forward route does not infer reverse',NM.forward_walk(m,P(2000,0),P(0,0))==nil)
    check('forward route rejects wrong-floor connector',NM.forward_walk(m,P(0,0,300),P(2000,0))==nil)
    m.routes[1].seed=true
    check('forward route excludes seeds',NM.forward_walk(m,P(0,0),P(2000,0))==nil)
    m.routes[1].seed=nil; m.routes[1].pts[3][4]='jump'
    check('forward route excludes jump segment',NM.forward_walk(m,P(0,0),P(2000,0))==nil)
end
do
    local m=NM.new_mem('chain')
    m.routes={
        {id='a',n_ok=1,pts={{0,0,0},{5,0,0},{10,0,0}}},
        {id='b',n_ok=1,pts={{10,0,0},{15,0,0},{20,0,0}}},
        {id='c',n_ok=1,pts={{20,0,0},{25,0,0},{30,0,0}}},
    }
    local p,info=NM.forward_walk(m,P(0,0),P(4000,0),150)
    check('forward chain returns recorded frontier without goal',p and info.prefix and p[#p].X==3000 and p[#p].X~=4000)
    local full,fi=NM.forward_walk(m,P(0,0),P(3000,0),150)
    check('complete forward chain preferred',full and not fi.prefix and full[#full].X==3000)
    m.routes[2].pts={{10,0,3},{15,0,3},{20,0,3}}
    p,info=NM.forward_walk(m,P(0,0),P(4000,0),150)
    check('wrong-floor join cannot reach later records',p and p[#p].X==1000)
    m.routes[2].pts={{20,0,0},{15,0,0},{10,0,0}}
    p,info=NM.forward_walk(m,P(0,0),P(4000,0),150)
    check('reverse-only record cannot bridge chain',p and p[#p].X<2000)
    m.routes[2].pts={{10,0,0},{15,0,0},{20,0,0}}
    m.routes[4]={id='cycle',n_ok=1,pts={{20,0,0},{10,0,0}}}
    p,info=NM.forward_walk(m,P(0,0),P(4000,0),150)
    check('cycle terminates at furthest frontier',p and p[#p].X==3000)
end
do
    local m=NM.new_mem('large-forward')
    local pts={}
    for i=0,2000 do pts[#pts+1]={i*5,0,0} end
    m.routes={{id='long',n_ok=1,pts=pts}}
    local p,info=NM.forward_walk(m,P(0,0),P(1000000,0),150)
    check('connected forward proposal survives over 2000 nodes',p and info and not info.prefix and p[#p].X==1000000)
end
do
    local m=NM.new_mem('reference')
    m.routes={
        {id='negative',n_ok=1,pts={{-8,0,0},{-4,0,0},{-0.01,0,0}}},
        {id='east',n_ok=1,pts={{0,0,0},{4,0,0},{8,0,0}}},
        {id='boundary',n_ok=1,pts={{3.99,0,0},{4,3.99,0},{8,4,0}}},
        {id='floor',n_ok=1,pts={{0,0,1.2},{8,0,1.2}}},
        {id='cycle',n_ok=1,pts={{8,0,0},{4,0,0},{0,0,0}}},
        {id='tie',n_ok=1,pts={{0,0,0},{4,0,0},{8,0,0}}},
    }
    NM.mark_water(m,P(400,0,0));NM.taboo(m,P(0,0,0),P(400,0,0),'reference')
    for _,goal in ipairs({P(800,0,0),P(2000,0,0),P(800,400,0),P(-2000,0,0),P(800,0,120)}) do
        local from=P(-800,0,0);local ep,prefix,cost=reference_forward(m,from,goal,150)
        local path,info=NM.forward_walk(m,from,goal,150);local got=path and path[#path]
        check('bucket and heap match exhaustive graph '..goal.X..','..goal.Y..','..goal.Z,
            (not ep and not path) or (ep and got and info.prefix==prefix and math.abs(info.cost_cm-cost)<1e-7 and
                got.X==ep.X and got.Y==ep.Y and got.Z==ep.Z))
    end
end

-- seeds: a trap with an exit, and a taboo
local seeds = [==[{"v":1,"traps":[{"id":"pit","center":[0,0,0],"radius_m":5,"z_max":1,"z_min":-3,
  "exit":[[0,8,0],[0,16,0],[0,18,0,"jump"]]}],
  "taboos":[{"at":[0,0,0],"toward":[-6,-6,0]}],"routes":[]}]==]
do local f = io.open(dir .. "/data/nav/L_World_seeds.json", "w"); f:write(seeds); f:close() end

local mem = NM.load(dir, "w1", "L_World")
check("seed trap loaded", #mem.traps == 1 and mem.traps[1].seed, #mem.traps)
local t = NM.trap_at(mem, P(100, 100, 0))
check("trap_at inside", t and t.id == "pit")
check("trap_at outside (radius)", NM.trap_at(mem, P(800, 0, 0)) == nil)
check("trap_at outside (above z_max)", NM.trap_at(mem, P(0, 0, 300)) == nil)
local ex = NM.trap_exit(t)
check("trap exit in cm with act", ex and #ex == 3 and ex[1].Y == 800 and ex[3].act == "jump")

-- routes: an L-shaped route A (0,0)->(30 m,0) and route B (30 m,0)->(30 m,30 m)
local rA, how = NM.add_route(mem, line(0, 0, 3000, 0, 30), { src = "demo:Zezima" })
check("route A added", rA and how == "added" and #rA.pts >= 10, how)
local rB = NM.add_route(mem, line(3000, 100, 3000, 3000, 30), { src = "self" })
check("route B added", rB ~= nil)
check("short trips are not stored", NM.add_route(mem, line(0, 0, 300, 0, 3)) == nil)
local rA2, how2 = NM.add_route(mem, line(50, 0, 2950, 50, 40))
check("near-duplicate route updates instead of adding", how2 == "updated" and #mem.routes == 2, how2)

-- plan from near A's start to near B's end: uses both routes via the join edge at the corner
local path, info = NM.plan(mem, P(-500, 200, 0), P(3100, 3200, 0), {})
check("plan joins two routes", path and #path > 10 and path[#path].Y == 3200, info)
local corner = false
for _, q in ipairs(path or {}) do if math.abs(q.X - 3000) < 200 and math.abs(q.Y) < 300 then corner = true end end
check("plan goes via the corner", corner)
check("no plan when nothing is near", NM.plan(mem, P(90000, 90000, 0), P(99000, 99000, 0), {}) == nil)

-- taboo: from the trap toward (-6,-6) is penalised
check("is_taboo matches", NM.is_taboo(mem, P(0, 0, 0), P(-600, -600, 0)))
check("is_taboo other direction no", not NM.is_taboo(mem, P(0, 0, 0), P(600, 600, 0)))

-- learned links are directed edges: a jump up from (60 m,0) to (60 m,10 m,3 m)
local rC = NM.add_route(mem, line(3000, 0, 5900, 0, 30))
local rD = NM.add_route(mem, { P(6000, 1000, 300), P(6000, 2500, 300), P(6000, 4000, 300) })
local links = { { from = { 59.5, 0, 0 }, to = { 60, 10, 3 }, move = "jump", penalty_m = 5 } }
local pl = NM.plan(mem, P(2900, 0, 0), P(6000, 3900, 300), { links = links })
local used_jump = false
for _, q in ipairs(pl or {}) do if q.act == "jump" then used_jump = true end end
check("learned link used as a graph edge", pl and used_jump)
local back = NM.plan(mem, P(6000, 3900, 300), P(2900, 0, 0), { links = links })
local back_jump = false
for _, q in ipairs(back or {}) do if q.act == "jump" then back_jump = true end end
check("jump links are one-way", not back_jump)

-- learn a trap over the seed: the learned exit wins, the seed is shadowed
local lt, lhow = NM.learn_trap(mem, P(50, 50, 0), { P(0, 0, 0), P(800, 0, 0), P(1600, 0, 0) })
check("learn_trap over a seed shadows it", lhow == "learned_over_seed" and NM.trap_at(mem, P(0, 0, 0)).src == "learned", lhow)
NM.taboo(mem, P(0, 0, 0), P(0, 500, 0), "failed")

-- persistence: save, reload; seeds are not written into the learned file
check("save", NM.save(mem))
local mem2 = NM.load(dir, "w1", "L_World")
local learned_routes = 0
for _, r in ipairs(mem2.routes) do if not r.seed then learned_routes = learned_routes + 1 end end
check("reload keeps learned routes", learned_routes == #mem.routes, learned_routes)
local learned = NM.trap_at(mem2, P(0, 0, 0))
check("reload: learned trap active", learned and learned.src == "learned", learned and learned.src)
local f = io.open(dir .. "/data/skills/w1/nav_memory.json"); local txt = f:read("a"); f:close()
check("seed taboo not duplicated into the learned file", not txt:find('"toward":%[%s*%-6'))

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
