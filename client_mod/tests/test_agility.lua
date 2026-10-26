-- Offline tests for client_mod/scripts/agility.lua: course listing (level locks), orb choice, and whole course
-- runs against a fake world (frame pump, fake clock, walking pawn, a starter whose interact opens the start
-- banner, the banner's start handler starting the course, orbs collected by touch, the finish) with the REAL
-- arbiter. Run:  lua client_mod/tests/test_agility.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local T = 0
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWAgility, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    local orbs = {}
    for i, p in ipairs(o.orbs or { { X = 1000, Y = 0, Z = 0 }, { X = 2000, Y = 0, Z = 0 }, { X = 2000, Y = 1000, Z = 0 } }) do
        orbs[i] = { id = "BP_AgilityOrb_C_" .. i, pos = p, visible = false, xp = 10 }
    end
    Wd = { pawn = { pos = { X = 0, Y = 0, Z = 0 } }, xp = 0, level = o.level or 1, min_level = o.min_level or 1,
           starter = { id = "BP_CourseStarter_C_1", pos = o.start or { X = 500, Y = 0, Z = 0 }, name = "Test Dash" },
           orbs = orbs, next_i = nil, running = false, banner = false, water = o.water, no_banner = o.no_banner,
           manager_readable = o.manager_readable ~= false, modal = o.modal }
end

local fake_move = {}
function fake_move.go_to(log, pos) Wd.goal = { X = pos[1] * 100, Y = pos[2] * 100, Z = (pos[3] or 0) * 100 }; Wd.move_res = nil; return { ok = true } end
function fake_move.status() if Wd.move_res then return { mode = "idle", result = Wd.move_res } end; return { mode = Wd.goal and "goto" or "idle" } end
function fake_move.stop() Wd.goal = nil; return { ok = true } end
function fake_move.snapshot() return nil end
function fake_move.restore() return true end

local function step(dt)
    local g = Wd.goal
    if g then
        local p = Wd.pawn.pos
        local d = d2(p, g)
        local s = 600 * dt
        if Wd.water and Wd.water(g) then Wd.goal = nil; Wd.move_res = { status = "failed", reason = "no path" }
        elseif d <= s then p.X, p.Y = g.X, g.Y; Wd.goal = nil; Wd.move_res = { status = "arrived" }
        else p.X, p.Y = p.X + (g.X - p.X) / d * s, p.Y + (g.Y - p.Y) / d * s end
    end
    -- touching the next orb collects it (the game's overlap)
    if Wd.running and Wd.next_i then
        local o = Wd.orbs[Wd.next_i]
        if d2(Wd.pawn.pos, o.pos) <= 100 then
            o.visible = false
            Wd.xp = Wd.xp + o.xp
            Wd.next_i = Wd.next_i + 1
            if Wd.next_i > #Wd.orbs then Wd.running = false; Wd.next_i = nil; Wd.xp = Wd.xp + 50
            else Wd.orbs[Wd.next_i].visible = true end
        end
    end
end

local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local G = assert(loadfile(root .. "/client_mod/scripts/agility.lua"))()
G.clock = function() return T end
G.set_modules({ move = fake_move, arbiter = A })
local W = G.W
local PC = { Pawn = "P" }
W.pc = function() return PC end
W.pawn = function() return Wd.pawn end
W.loc = function(p) return { X = p.pos.X, Y = p.pos.Y, Z = p.pos.Z } end
W.dead = function() return false end
W.skills = function() return { { skill = "Agility", level = Wd.level, xp = Wd.xp } } end
W.starters = function() local s = Wd.starter; return { { id = s.id, pos = s.pos, name = s.name, min_level = Wd.min_level, my_level = Wd.level } } end
W.running = function() return Wd.running end
W.orbs = function() local out = {}; for _, o in ipairs(Wd.orbs) do out[#out + 1] = { id = o.id, pos = o.pos, visible = o.visible } end; return out end
W.next_orb = function() if Wd.manager_readable and Wd.next_i then local o = Wd.orbs[Wd.next_i]; return { id = o.id, pos = o.pos } end end
W.target = function() if d2(Wd.pawn.pos, Wd.starter.pos) <= 300 then return { actor = Wd.starter.id, prompt = "Start" } end; return { none = true } end
W.press = function() if not Wd.no_banner then Wd.banner = true end; Wd.presses = (Wd.presses or 0) + 1; return { ok = true } end
W.banner = function() return Wd.banner and "BANNER" or nil end
W.click_start = function() Wd.banner = false; Wd.running = true; Wd.next_i = 1; Wd.orbs[1].visible = true; return true end
W.face = function() end
W.gate = function() return Wd.modal end
W.claim = function(k) Wd.claimed = k end
W.release = function() Wd.claimed = nil end

local function pump(sec, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(sec / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        step(dt)
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        if until_fn and until_fn() then return true end
    end
end
local function run(args, sec)
    local r = G.HANDLERS.agility_course(nil, args or {}, { id = "t" })
    if not r.pending then return r end
    local res
    pump(sec or 400, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT", data = { st = G.status() } }
end

-- pure
do
    local me = { X = 0, Y = 0, Z = 0 }
    local c = G.courses({ { id = "a", pos = { X = 5000, Y = 0 }, min_level = 15, my_level = 3 }, { id = "b", pos = { X = 1000, Y = 0 }, min_level = 1, my_level = 3 } }, me)
    check("courses nearest first", c[1].id == "b" and c[2].id == "a")
    check("course locked by level", c[2].locked ~= nil and c[1].locked == nil, c[2].locked)
    local o = G.pick_orb(nil, { { id = "x", pos = { X = 900, Y = 0 } }, { id = "y", pos = { X = 100, Y = 0 }, visible = false }, { id = "z", pos = { X = 300, Y = 0 } } }, me, { z = true })
    check("pick orb: visible, not taken, nearest", o and o.id == "x", o and o.id)
    check("pick orb: manager's next wins", G.pick_orb({ id = "n", pos = { X = 1, Y = 1 } }, {}, me, {}).id == "n")
    check("where words", G.where(me, { X = 1000, Y = 0, Z = 400 }):find("4 m higher", 1, true) ~= nil)
end

-- a whole run
do
    reset()
    local res = run()
    check("course: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("course: 3 orbs", res.data.orbs == 3, res.data.orbs)
    check("course: xp reported", res.data.xp and res.data.xp.Agility and res.data.xp.Agility.xp == 80, res.data.xp and res.data.xp.Agility and res.data.xp.Agility.xp)
    check("course: one interact press", Wd.presses == 1, Wd.presses)
    check("course: banner claim released", Wd.claimed == nil)
    check("course: arbiter released", A.owner() == nil)
    check("course: finish sentence", res.data.detail:find("Finished Test Dash", 1, true) ~= nil, res.data.detail)
end

do -- manager's next orb unreadable: falls back to the nearest visible orb
    reset({ manager_readable = false })
    local res = run()
    check("fallback orbs: ok", res.ok == true and res.data.orbs == 3, tostring(res.reason) .. " " .. tostring(res.data and res.data.orbs))
end

do -- an orb across water he can't reach: says which and where
    reset({ water = function(p) return p.Y > 500 end })
    local res = run()
    check("unreachable orb: path_blocked", res.reason == "path_blocked" and res.data.why == "cant_reach_orb", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("unreachable orb: names orb 3", res.data.detail:find("orb 3", 1, true) ~= nil, res.data.detail)
end

do -- level too low
    reset({ level = 3, min_level = 15 })
    local res = run()
    check("locked: not_unlocked", res.reason == "not_unlocked" and res.data.detail:find("needs level 15", 1, true) ~= nil, res.data and res.data.detail)
end

do -- the start never shows a banner
    reset({ no_banner = true })
    local res = run()
    check("no banner: verification_failed", res.reason == "verification_failed" and res.data.why == "no_banner", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("no banner: pressed twice", Wd.presses == 2, Wd.presses)
end

do -- a build/container screen is open: never presses, says why
    reset({ modal = { kind = "container" } })
    local res = run()
    check("modal: interrupted screen_open", res.reason == "interrupted" and res.data.why == "screen_open", tostring(res.reason) .. " " .. tostring(res.data.why))
    check("modal: no press", (Wd.presses or 0) == 0)
end

do -- no course near
    reset()
    Wd.starter.pos = { X = 900000, Y = 0, Z = 0 }
    local res = run()
    check("no course: nothing_in_range", res.reason == "nothing_in_range", res.reason)
end

do -- read tool + contract
    reset()
    local r = G.HANDLERS.agility_courses(nil, {})
    check("courses tool", r.ok and #r.data.courses == 1 and r.data.courses[1].pos == nil)
    check("manifest action moves", G.MANIFEST.agility_course.kind == "action" and G.MANIFEST.agility_course.moves and G.MANIFEST.agility_course.llm)
    check("manifest read", G.MANIFEST.agility_courses.kind == "read")
    local src = assert(io.open(root .. "/client_mod/scripts/agility.lua", "rb")):read("*a")
    check("no server RPC calls", not src:gsub("%-%-[^\n]*", ""):find("[:.]Server_%w+%s*%("))
end

print(string.format("test_agility: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
