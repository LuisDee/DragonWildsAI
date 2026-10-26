-- Offline tests for client_mod/scripts/shoot.lua: shooting a floating thing down with the real ranged.lua solution,
-- a fake world (frame pump, fake clock, a pawn that walks, a rock that falls when a shot's aim is right), the REAL
-- arbiter. Run:  lua client_mod/tests/test_shoot.lua
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

local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWShoot, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    Wd = { pawn = { X = 0, Y = 0, Z = 0 }, rot = nil, held = o.held == nil and { kind = "ranged", item = "ITEM_Bow_Ash", name = "Ash Bow" } or o.held,
           ammo = o.ammo ~= false, rock = { X = o.dist or 1200, Y = 300, Z = 600, hp = 30, alive = true }, presses = {}, aim_err = o.aim_err or 0,
           tough = o.tough, cat = o.cat or "resources" }
end

local fake_move = {}
function fake_move.go_to(log, pos) Wd.goal = { X = pos[1] * 100, Y = pos[2] * 100, Z = pos[3] * 100 }; Wd.move_res = nil; return { ok = true } end
function fake_move.status()
    if Wd.stall then return { mode = "go_to", progress = { verdict = "stalled", why = "no_route" } } end
    if Wd.move_res then return { mode = "idle", result = Wd.move_res } end; return { mode = Wd.goal and "goto" or "idle" }
end
function fake_move.stop() Wd.goal = nil; return { ok = true } end
function fake_move.snapshot() end
function fake_move.restore() return true end

local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local S = assert(loadfile(root .. "/client_mod/scripts/shoot.lua"))()
local Rg = assert(loadfile(root .. "/client_mod/scripts/ranged.lua"))()
S.clock = function() return T end
local SKm = assert(loadfile(root .. "/client_mod/scripts/skills.lua"))()
S.set_modules({ move = fake_move, arbiter = A, ranged = Rg, skills = SKm })
local W = S.W
local ACT = { primary = { n = "primary" }, secondary = { n = "secondary" } }
W.pc = function() return {} end
W.pawn = function() return Wd.pawn end
W.loc = function(p) return { X = p.X, Y = p.Y, Z = p.Z } end
W.dead = function() return false end
W.actions = function() return ACT end
W.weapon = function() if Wd.held then return Wd.held end return nil, "Bronze Sword" end
W.params = function() return { has_ammo = Wd.ammo, speed = 4000, gz = -980, full_accuracy_s = 0.5 } end
W.muzzle = function() return { X = Wd.pawn.X, Y = Wd.pawn.Y, Z = Wd.pawn.Z + 150 } end
W.camera = function() return { X = Wd.pawn.X, Y = Wd.pawn.Y, Z = Wd.pawn.Z + 150 } end
W.projectiles = function() return {} end
W.face = function(_, rot) Wd.rot = rot end
W.gate = function() return Wd.modal end
W.inject = function(a) Wd.held_now = Wd.held_now or {}; Wd.held_now[a.n] = true; return true end
W.target_state = function() local r = Wd.rock; if not r.alive then return { alive = false } end; return { alive = true, pos = { X = r.X, Y = r.Y, Z = r.Z }, hp = r.hp } end
local api = { find_thing = function(id) if id == "rock_1" then return { id = id, name = "Rune Essence", category = Wd.cat } end end,
              actor_of = function(t) return t and Wd.rock or nil end,
              -- the bridge API the shared ownership (skills._acquire/_hold/_release) uses
              module = function(n) if n == "arbiter" then return A end end, now = function() return T end, log = function() end,
              fail = function(r, d) return { ok = false, reason = r, data = d or {} } end, reflex_owns_pawn = function() return false end }

local function step(dt)
    local g = Wd.goal
    if g then
        local p = Wd.pawn
        local d = math.sqrt((g.X - p.X) ^ 2 + (g.Y - p.Y) ^ 2)
        if d <= 500 * dt then p.X, p.Y = g.X, g.Y; Wd.goal = nil; Wd.move_res = { status = "arrived" }
        else p.X, p.Y = p.X + (g.X - p.X) / d * 500 * dt, p.Y + (g.Y - p.Y) / d * 500 * dt end
    end
    local h = Wd.held_now or {}
    Wd.held_now = {}
    if h.primary and not Wd.prev_primary and Wd.rot then
        -- the shot: right if the camera's yaw points at the rock and its pitch is at/above the straight line
        local m = { X = Wd.pawn.X, Y = Wd.pawn.Y, Z = Wd.pawn.Z + 150 }
        local r = Wd.rock
        local yaw = math.deg(math.atan(r.Y - m.Y, r.X - m.X)) + Wd.aim_err
        local los = math.deg(math.atan(r.Z - m.Z, math.sqrt((r.X - m.X) ^ 2 + (r.Y - m.Y) ^ 2)))
        local good = math.abs((Wd.rot.Yaw - yaw + 540) % 360 - 180) < 2 and Wd.rot.Pitch >= los - 0.5 and Wd.rot.Pitch <= los + 15
        Wd.shots_fired = (Wd.shots_fired or 0) + 1
        if good then
            Wd.pending = { t = T + 0.4, fn = function()
                r.hp = r.hp - 10
                if not Wd.tough then r.Z = 0 end -- knocked out of the sky
            end }
        end
    end
    Wd.prev_primary = h.primary
    if Wd.pending and T >= Wd.pending.t then local f = Wd.pending.fn; Wd.pending = nil; f() end
end
local function pump(sec, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(sec / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        step(dt)
        if until_fn and until_fn() then return true end
    end
end
local function run(args)
    local r = S.HANDLERS.shoot(nil, args, { id = "t", api = api })
    if not r.pending then return r end
    local res
    pump(150, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT" }
end

do
    reset()
    local res = run({ target = "rock_1" })
    check("knocked down: ok", res.ok == true and res.data.outcome == "fell", tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("one shot", res.data.shots == 1 and Wd.shots_fired == 1, res.data.shots)
    check("aimed with the hold first", Wd.rot ~= nil)
    check("says it's on the ground", res.data.detail:find("on the ground", 1, true) ~= nil)
    check("arbiter released", A.owner() == nil)
end
do
    reset({ dist = 5000 })
    local res = run({ target = "rock_1" })
    check("far: walked into range then shot", res.ok == true and math.abs(Wd.pawn.X) > 100, tostring(res.reason) .. " " .. tostring(Wd.pawn.X))
end
do -- move's shared progress tracker says stalled: stop, say why (no flat timer)
    reset({ dist = 5000 })
    Wd.stall = true
    local res = run({ target = "rock_1" })
    check("stalled approach: path_blocked with the words", res.reason == "path_blocked" and res.data.why == "cant_get_in_range"
          and res.data.detail:find("can't", 1, true) ~= nil, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
end
do
    reset({ aim_err = 10 }) -- the game's shots land off to the side every time
    local res = run({ target = "rock_1", shots = 3 })
    check("misses: truthful verification_failed after N shots", res.reason == "verification_failed" and res.data.why == "missed" and res.data.shots == 3,
        tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
end
do
    reset({ tough = true })
    local res = run({ target = "rock_1", shots = 2 })
    check("hit but still up", res.reason == "verification_failed" and res.data.why == "not_down_yet" and res.data.hits == 2, tostring(res.data and res.data.why))
end
do
    reset({ held = false })
    local r = S.HANDLERS.shoot(nil, { target = "rock_1" }, { api = api })
    check("no ranged weapon: wrong_tool naming what he holds", r.reason == "wrong_tool" and r.data.detail:find("Bronze Sword", 1, true) ~= nil, r.data and r.data.detail)
    reset({ ammo = false })
    r = S.HANDLERS.shoot(nil, { target = "rock_1" }, { api = api })
    check("no ammo", r.reason == "not_enough_resources" and r.data.why == "no_ammo")
    reset({ cat = "players" })
    check("never at players", S.HANDLERS.shoot(nil, { target = "rock_1" }, { api = api }).reason == "unsafe")
    reset({ cat = "creatures" })
    check("creatures go to attack", S.HANDLERS.shoot(nil, { target = "rock_1" }, { api = api }).data.why == "creature")
    reset()
    check("unknown target", S.HANDLERS.shoot(nil, { target = "nope" }, { api = api }).reason == "unknown_target")
    check("target required", S.HANDLERS.shoot(nil, {}, { api = api }).reason == "invalid_args")
end
do
    reset()
    Wd.modal = { kind = "build" }
    local res = run({ target = "rock_1" })
    check("a build screen open: never fires", res.reason == "interrupted" and res.data.why == "screen_open" and (Wd.shots_fired or 0) == 0, tostring(res.reason))
end
do
    -- llm = false until live-verified (main, 2026-10-26); the bridge still treats it as an action tool
    check("manifest action", S.MANIFEST.shoot.kind == "action" and S.MANIFEST.shoot.moves and S.MANIFEST.shoot.llm == false)
    local src = assert(io.open(root .. "/client_mod/scripts/shoot.lua", "rb")):read("*a"):gsub("%-%-[^\n]*", "")
    check("no server RPC calls", not src:find("[:.]Server_%w+%s*%("))
    check("no item names in logic", not src:find("ITEM_", 1, true) and not src:find("Essence", 1, true))
end

print(string.format("test_shoot: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
