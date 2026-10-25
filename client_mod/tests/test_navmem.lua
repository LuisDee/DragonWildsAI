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
