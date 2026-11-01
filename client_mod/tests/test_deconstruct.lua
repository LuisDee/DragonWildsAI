-- Offline tests for client_mod/scripts/deconstruct.lua: the plan on the REAL layout of Luis's dev-world house
-- (live read 2026-11-01 13:3x UTC, client_mod/commands/decon_probe_read.lua), the safety rules, the take-down order,
-- the "mine" ledger, and the step machine over a fake world (menu -> repair -> aim until the game highlights the
-- piece -> destroy -> gone + refund). Run: cd client_mod/tests && lua test_deconstruct.lua <empty temp dir>
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local tmp = (arg and arg[1]) or os.getenv("TEMP") or "."
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end
_G.DWDecon = nil
local D = assert(loadfile(root .. "/client_mod/scripts/deconstruct.lua"))()

-- ------------------------------------------------------------------ the real house (pid, piece, name, kind input, x, y, z, extra)
local RAW = {
    { 12, "BUILDPIECE_Interior_Crate", "Crate", "BP_BaseBuilding_Crate_C", 108.24, 1848.1, -32.11, { holds = 28, mine = true } },
    { 14, "BUILDPIECE_Interior_Crate", "Crate", "BP_BaseBuilding_Crate_C", 115.12, 1850.84, -32.19, { holds = 0, mine = true } },
    { 15, "DA_T1_Foundation_Large", "Square Foundation", nil, 93.21, 1853.14, -31.81 },
    { 16, "DA_T1_Foundation_Large", "Square Foundation", nil, 93.21, 1850.14, -31.81 },
    { 17, "DA_T1_Foundation_Large", "Square Foundation", nil, 96.21, 1850.14, -31.81 },
    { 18, "DA_T1_Foundation_Large", "Square Foundation", nil, 96.21, 1853.14, -31.81 },
    { 19, "DA_T1_Foundation_Large", "Square Foundation", nil, 90.21, 1853.14, -31.81 },
    { 20, "DA_T1_Foundation_Large", "Square Foundation", nil, 90.21, 1850.14, -31.81 },
    { 21, "DA_T1_Foundation_Large", "Square Foundation", nil, 90.21, 1847.14, -31.81 },
    { 22, "DA_T1_Foundation_Large", "Square Foundation", nil, 93.21, 1847.14, -31.81 },
    { 23, "DA_T1_Foundation_Large", "Square Foundation", nil, 96.21, 1847.14, -31.81 },
    { 24, "BUILDPIECE_CraftingStation_Basic", "Crafting Table", "BP_Crafting_StartingBench_C", 89.6, 1850.09, -31.82 },
    { 25, "BUILDPIECE_Campfire", "Campfire", "BP_Station_Campfire_C", 89.57, 1847.79, -31.82, { holds = 77 } },
    { 26, "DA_T1_Wall_Large_Doorframe", "WALL WITH DOOR FRAME", nil, 97.71, 1850.14, -31.81 },
    { 27, "DA_T1_Wall_Large", "Wall", nil, 88.71, 1847.14, -31.81 },
    { 28, "DA_T1_Wall_Large", "Wall", nil, 88.71, 1853.14, -31.81 },
    { 29, "DA_T1_Wall_Large", "Wall", nil, 90.21, 1854.64, -31.81 },
    { 30, "DA_T1_Wall_Large", "Wall", nil, 96.21, 1854.64, -31.81 },
    { 31, "DA_T1_Wall_Large", "Wall", nil, 96.21, 1845.64, -31.81 },
    { 32, "DA_T1_Wall_Large", "Wall", nil, 90.21, 1845.64, -31.81 },
    { 33, "DA_T1_Wall_Large_Windowframe", "WALL WITH WINDOW FRAME", nil, 93.21, 1845.64, -31.81 },
    { 34, "DA_T1_Wall_Large_Windowframe", "WALL WITH WINDOW FRAME", nil, 97.71, 1847.14, -31.81 },
    { 35, "DA_T1_Wall_Large_Windowframe", "WALL WITH WINDOW FRAME", nil, 97.71, 1853.14, -31.81 },
    { 36, "DA_T1_Wall_Large_Windowframe", "WALL WITH WINDOW FRAME", nil, 93.21, 1854.64, -31.81 },
    { 37, "DA_T1_Wall_Large_Windowframe", "WALL WITH WINDOW FRAME", nil, 88.71, 1850.14, -31.81 },
    { 38, "DA_T1_Roof_Large_Hip_Diagonal", "45 Hip Roof", nil, 90.21, 1853.14, -27.31 },
    { 39, "DA_T1_Roof_Large_Hip_Diagonal", "45 Hip Roof", nil, 90.21, 1847.14, -27.31 },
    { 40, "DA_T1_Roof_Large_Hip_Diagonal", "45 Hip Roof", nil, 96.21, 1847.14, -27.31 },
    { 41, "DA_T1_Roof_Large_Hip_Diagonal", "45 Hip Roof", nil, 96.21, 1853.14, -27.31 },
    { 42, "DA_T1_Roof_Large_Diagonal", "45 Roof", nil, 93.21, 1853.14, -27.31 },
    { 43, "DA_T1_Roof_Large_Diagonal", "45 Roof", nil, 96.21, 1850.14, -27.31 },
    { 44, "DA_T1_Roof_Large_Diagonal", "45 Roof", nil, 93.21, 1847.14, -27.31 },
    { 45, "DA_T1_Roof_Large_Diagonal", "45 Roof", nil, 90.21, 1850.14, -27.31 },
    { 46, "DA_T1_Floor_Large", "Square Tile", nil, 93.21, 1850.14, -25.81 },
    { 47, "BUILDPIECE_Prop_Torch", "Wall-mounted Torch", "BP_BaseBuilding_Torch_C", 88.92, 1852.25, -30.2 },
    { 48, "BUILDPIECE_Prop_Torch", "Wall-mounted Torch", "BP_BaseBuilding_Torch_C", 95.09, 1845.85, -30.2 },
    { 49, "BUILDPIECE_Prop_Torch", "Wall-mounted Torch", "BP_BaseBuilding_Torch_C", 97.52, 1852.11, -30.11 },
    { 50, "DA_FarmPlot_T1_Brynmoor", "Ash Farming Plot", "BP_FarmPlot1x1_T1_C", 87.21, 1853.14, -31.81 },
    { 51, "DA_FarmPlot_T1_Brynmoor", "Ash Farming Plot", "BP_FarmPlot1x1_T1_C", 87.21, 1850.14, -31.81 },
    { 52, "DA_FarmPlot_T1_Brynmoor", "Ash Farming Plot", "BP_FarmPlot1x1_T1_C", 87.21, 1847.14, -31.81 },
    { 53, "DA_FarmPlot_T1_Brynmoor", "Ash Farming Plot", "BP_FarmPlot1x1_T1_C", 84.21, 1847.14, -31.81 },
    { 56, "BUILDPIECE_ProcessingStation_Spinning_Wheel", "Spinning Wheel", "BP_Station_Spinning_Wheel_C", 89.39, 1853.33, -31.82, { holds = 2 } },
    { 57, "DA_BaseBuilding_Station_Composter", "Compost Bin", "BP_Station_Composter_New_C", 81.66, 1847.22, -31.89, { holds = 0 } },
    { 58, "BUILDPIECE_ProcessingStation_Tanner", "Tannery", "BP_Station_Tanner_C", 96.38, 1846.51, -31.82, { holds = 0 } },
}
local function rows()
    local out = {}
    for _, r in ipairs(RAW) do
        local e = r[8] or {}
        local p = { pid = r[1], id = r[4] and (r[4] .. "_" .. r[1]) or ("BuildingPiece_" .. r[1]), piece = r[2], name = r[3], class = r[4],
                    position = { r[5], r[6], r[7] }, holds = e.holds, mine = e.mine }
        p.kind = D.kind(p.piece, p.class, e.holds ~= nil)
        out[#out + 1] = p
    end
    return out
end
local function by_pid(list) local t = {}; for _, p in ipairs(list) do t[p.pid] = p end return t end

-- kinds from the game's own ids/classes
local P = by_pid(rows())
check("kind: foundation", P[15].kind == "foundation", P[15].kind)
check("kind: wall = structure", P[27].kind == "structure" and P[26].kind == "structure", P[27].kind)
check("kind: roof + tile = roof", P[38].kind == "roof" and P[46].kind == "roof", P[46].kind)
check("kind: torch = prop", P[47].kind == "prop", P[47].kind)
check("kind: stations (table, campfire, wheel, tannery, compost bin)", P[24].kind == "station" and P[25].kind == "station"
    and P[56].kind == "station" and P[58].kind == "station" and P[57].kind == "station", P[57].kind)
check("kind: farm plot", P[50].kind == "farm_plot", P[50].kind)
check("kind: crate = container", P[14].kind == "container", P[14].kind)

-- the whole house from one wall
local plan = D.plan(rows(), by_pid(rows())[27], { whole = true, world = "dev" })
local q = by_pid(plan.queue)
local left = {}
for _, l in ipairs(plan.left) do left[l.piece.pid] = l end
local n_struct = 0
for pid = 26, 49 do if q[pid] then n_struct = n_struct + 1 end end
check("whole: every wall, roof, tile and torch queued (24)", n_struct == 24, n_struct)
for _, pid in ipairs({ 15, 16, 17, 18, 22 }) do check("whole: free foundation " .. pid .. " queued", q[pid] ~= nil) end
for _, pid in ipairs({ 19, 20, 21, 23 }) do
    check("whole: foundation " .. pid .. " under a station left", left[pid] and left[pid].why == "supports", left[pid] and left[pid].why)
end
check("whole: the table's foundation names the table", left[20] and left[20].words:find("Crafting Table", 1, true), left[20] and left[20].words)
check("whole: stations left (not mine)", left[24] and left[24].why == "not_mine" and left[58] and left[58].why == "not_mine")
check("whole: campfire with logs left as holds_items", left[25] and left[25].why == "holds_items", left[25] and left[25].why)
check("whole: plots next to it left", left[50] and left[50].why == "not_mine" and left[51] and left[52])
check("whole: the far plot, compost bin and crates never reached", not q[53] and not left[53] and not left[57] and not q[14] and not left[14])
check("whole: 29 pieces to take down", #plan.queue == 29, #plan.queue)
-- order: torches first, then the tile, the roof, the walls, the foundations last
local first_nonprop
for i, p in ipairs(plan.queue) do if p.kind ~= "prop" then first_nonprop = i; break end end
check("order: the 3 torches first", first_nonprop == 4, first_nonprop)
check("order: then the tile (highest)", plan.queue[4].pid == 46, plan.queue[4].pid)
local saw_wall, roof_after_wall, found_before = false, false, false
local saw_found = false
for _, p in ipairs(plan.queue) do
    if p.kind == "structure" then saw_wall = true end
    if p.kind == "roof" and saw_wall then roof_after_wall = true end
    if p.kind == "foundation" then saw_found = true elseif saw_found then found_before = true end
end
check("order: no roof after a wall", not roof_after_wall)
check("order: foundations last", saw_found and not found_before)

-- single pieces
local R = by_pid(rows())
local p1 = D.plan(rows(), R[14], { world = "dev" })
check("single: my empty crate", #p1.queue == 1 and p1.queue[1].pid == 14)
local p2 = D.plan(rows(), R[12], { world = "dev" })
check("single: a crate with items is never taken (even mine)", #p2.queue == 0 and p2.left[1].why == "holds_items", p2.left[1] and p2.left[1].why)
check("single: its words say how many", p2.left[1].words:find("28 items", 1, true), p2.left[1].words)
local p3 = D.plan(rows(), R[58], { world = "dev" })
check("single: someone else's station stays", #p3.queue == 0 and p3.left[1].why == "not_mine")
local p4 = D.plan(rows(), R[58], { world = "dev", include_stations = true })
check("single: ... unless asked for it and empty", #p4.queue == 1)
local p5 = D.plan(rows(), R[25], { world = "dev", include_stations = true })
check("single: a station holding items stays even when asked", #p5.queue == 0 and p5.left[1].why == "holds_items")
local p6 = D.plan(rows(), R[20], { world = "dev" })
check("single: a foundation under the table stays (it would fall)", #p6.queue == 0 and p6.left[#p6.left].why == "supports",
    p6.left[#p6.left] and p6.left[#p6.left].why)
local p7 = D.plan(rows(), R[16], { world = "dev" })
check("single: a free foundation comes down", #p7.queue == 1 and p7.queue[1].pid == 16)
local p8 = D.plan(rows(), R[27], { world = "shockbyte" })
check("shockbyte: only my own pieces", #p8.queue == 0 and p8.left[1].why == "not_mine")
local p9 = D.plan(rows(), R[14], { world = "shockbyte" })
check("shockbyte: my own empty crate is fine", #p9.queue == 1)
local pg = D.plan(rows(), R[14], { world = "dev" })
R[14].game_says = 1
local pg2 = D.plan(rows(), (function() local r = rows(); local t = by_pid(r)[14]; t.game_says = 1; t.game_words = "In use"; return t end)(), { world = "dev" })
check("the game's own refusal is honoured", #pg2.queue == 0 and pg2.left[1].words:find("In use", 1, true), pg2.left[1] and pg2.left[1].words)
check("plan without refusal ok", #pg.queue == 1)

-- aim points: a foundation's location is its top; a wall's its base; a box centre wins
local ap = D.aim_points({ position = { 0, 0, 0 }, kind = "foundation" }, nil, { 5, 0, 0 })
check("aim: foundation just under its top", math.abs(ap[1][3] + 0.15) < 1e-6, ap[1][3])
local aw = D.aim_points({ position = { 0, 0, 0 }, kind = "structure" }, nil, { 5, 0, 0 })
check("aim: wall at mid height", math.abs(aw[1][3] - 1.5) < 1e-6)
local ab = D.aim_points({ position = { 10, 0, 0 }, kind = "foundation", yaw = 90 }, { origin = { 1, 0, -1.5 }, extent = { 1.5, 1.5, 1.5 } }, { 0, 0, 0 })
check("aim: box centre (origin rotated by yaw)", math.abs(ab[1][1] - 10) < 1e-6 and math.abs(ab[1][2] - 1) < 1e-6 and math.abs(ab[1][3] + 1.5) < 1e-6,
    ab[1][1] .. "," .. ab[1][2] .. "," .. ab[1][3])
check("aim: the second point is toward me", ab[2][1] < 10, ab[2][1])

-- the ledger: telemetry resolves to the newest piece of that type near me, never an older one
_G.DWDecon = nil
local L = { world = "test", pieces = {} }
local near = { { pid = 15, index = 663, piece = "DA_T1_Foundation_Large", position = { 1, 1, 1 } },
               { pid = 59, index = 663, piece = "DA_T1_Foundation_Large", position = { 2, 2, 2 } },
               { pid = 58, index = 721, piece = "X", position = { 3, 3, 3 } } }
-- the module's state: pending telemetry
_G.DWDecon = { hk = { seq = 0 }, pending = { { index = 663, t = 100 } } }
check("ledger: not resolved in the first second", D.resolve_pending(L, near, 100.5) == false and #_G.DWDecon.pending == 1)
check("ledger: resolved to the newest 663", D.resolve_pending(L, near, 101.5) == true and #L.pieces == 1 and L.pieces[1].at[1] == 2, #L.pieces)
_G.DWDecon.pending = { { index = 663, t = 100 } }
local only_old = { { pid = 15, index = 663, piece = "DA_T1_Foundation_Large", position = { 1, 1, 1 } }, { pid = 70, index = 1, piece = "Y", position = { 0, 0, 0 } } }
check("ledger: an old piece of that type is never taken for the new one", D.resolve_pending(L, only_old, 102) == false and #L.pieces == 1)
check("ledger: note is idempotent", D.note_mine(L, near[2], "x") == false)
check("ledger: forget", D.forget_mine(L, near[2]) == true and #L.pieces == 0)

-- the ledger file round trip (atomic write) in the temp dir
D.ledger_path = function(w) return tmp .. "/my_pieces_" .. w .. ".json" end
local L2 = { world = "rt", pieces = {} }
D.note_mine(L2, near[2], "test")
check("ledger: saved", D.save_ledger(L2) == true)
_G.DWDecon.ledger = nil
local L3 = D.ledger("rt", true)
check("ledger: read back", #L3.pieces == 1 and L3.pieces[1].piece == "DA_T1_Foundation_Large", #L3.pieces)
-- get_state.structures: mine true for his, false for a piece read against the ledger and not in it (the game keeps
-- no owner per piece), nil for a row it can't check
local wid0 = D.world_id
D.world_id = function() return "rt" end
_G.DWDecon.pending = {}
local rows = { { piece = "DA_T1_Foundation_Large", position = { 2, 2, 2 } }, { piece = "BUILDPIECE_Interior_Crate", position = { 2, 2, 2 } },
               { position = { 9, 9, 9 } } }
D.state_extras({ my_position = function() return { 0, 0, 0 } end }, { structures = rows })
check("structures: mine true / false / unchecked", rows[1].mine == true and rows[2].mine == false and rows[3].mine == nil,
    tostring(rows[1].mine) .. " " .. tostring(rows[2].mine) .. " " .. tostring(rows[3].mine))
D.world_id = wid0
os.remove(tmp .. "/my_pieces_rt.json")

-- ------------------------------------------------------------------ line of sight (live boxes, 14:3xZ)
do
    local WALL = { pid = 35, id = "BuildingPiece_35", name = "WALL WITH WINDOW FRAME", position = { 97.7113, 1853.1378, -31.8092 }, yaw = 90,
                   box = { origin = { 0, 0, 1.5 }, extent = { 1.5, 0.5, 1.5 } } }
    local TORCH = { pid = 49, id = "BP_BaseBuilding_Torch_C_2147224263", name = "Wall-mounted Torch", position = { 97.5238, 1852.1116, -30.1054 }, yaw = 90,
                    box = { origin = { 0.0087, 0.154, 0.4028 }, extent = { 0.0971, 0.1917, 0.4028 } } }
    local rows = { WALL, TORCH }
    local c = { 97.3698, 1852.1203, -29.7026 }
    local outside, inside = { 101.5, 1852.1, -30.2 }, { 94.9, 1852.9, -30.2 }
    check("los: from outside the wall blocks the torch", D.blocker(rows, TORCH, outside, c) == WALL)
    check("los: from inside it is clear (the torch sits in the wall's box)", D.blocker(rows, TORCH, inside, c) == nil)
    local s = D.clear_stand(rows, TORCH, c, { 101.5, 1852.1, -30.9 }, 3.5, {})
    check("los: the stand picked is inside (west of the wall)", s and s[1] < 97.2, s and (s[1] .. "," .. s[2]))
    check("los: a box I'd stand in is refused", D.clear_stand({ { pid = 9, position = { c[1] - 3.5, c[2], -31 }, yaw = 0,
        box = { origin = { 0, 0, 0 }, extent = { 0.4, 0.4, 2 } } }, TORCH }, TORCH, c, { c[1] - 3.5, c[2], -30.9 }, 3.5, {}) ~= nil)
    WALL.done = true
    check("los: a removed piece no longer blocks", D.blocker(rows, TORCH, outside, c) == nil)
end

-- ------------------------------------------------------------------ the step machine over a fake world
_G.DWDecon = nil
local G = { mode = "None", alive = {}, targeted = 0, counts = { ITEM_Resources_Wood_Ash = 3 }, presses = {}, t = 0, aim = nil, me = { 112, 1851, -31.2 },
            refund = { ITEM_Resources_Wood_Ash = 8 }, refuse = false }
for _, r in ipairs(RAW) do G.alive[r[1]] = true end
local CRATE = { pid = 14, id = "BP_BaseBuilding_Crate_C_14", piece = "BUILDPIECE_Interior_Crate", name = "Crate", kind = "container",
                position = { 115.12, 1850.84, -32.19 }, holds = 0, mine = true }
local api = {
    null = "NULL", object = function(t) return t end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
    now = function() return G.t end, my_position = function() return G.me end, counts = function() return G.counts end,
    census_things = function() return {} end,
    call = function(mod, fn, goal) if mod == "move" and fn == "go_to" then G.me = { goal[1], goal[2], G.me[3] }; G.moving = true end return { ok = true } end,
    move_status = function() G.moving = false; return { mode = "idle", result = { status = "arrived" } } end,
    module = function(n)
        if n == "input" then return { gate = function() end, build_mode = function() return G.mode end, claim = function() end, release = function() end,
            leave_build_step = function(press) if G.mode ~= "None" then press("cancel") end return G.mode end } end
        if n == "build" then return { W = { pc = function() return {} end, clock = function() return G.t end } } end
    end,
}
D.W.alive = function() return G.alive end
D.W.targeted = function() return G.targeted end
D.W.action = function(_, which) return which end
G.ground = {}
D.W.ground = function() return G.ground end
G.cross = nil
D.W.crosshair = function() return G.cross end
D.W.cost = function() return { ITEM_Resources_Wood_Ash = 8 } end
D.W.can_destroy = function() return G.refuse and 1 or 0 end
D.W.words = function() return D.DESTROY_TEXT end
D.W.arm_hooks = function() return true end
D.W.aim_points = function(_, p, me) return D.aim_points(p, nil, me) end
D.W.press = function(_, a)
    G.presses[#G.presses + 1] = a
    if a == "menu" and G.mode == "None" then G.mode = "Selection"
    elseif a == "repair" and G.mode == "Selection" then G.mode = "RepairAndEdit"
    elseif a == "cancel" then G.mode = "None"
    elseif a == "destroy" and G.mode == "RepairAndEdit" and G.targeted == 14 and not G.refuse then
        G.alive[14] = nil
        G.counts.ITEM_Resources_Wood_Ash = G.counts.ITEM_Resources_Wood_Ash + 8
    end
    return true
end
local aims = 0
api.module_build_aim = true
local real_module = api.module
api.module = function(n)
    local m2 = real_module(n)
    if n == "build" then m2.W.aim = function() aims = aims + 1; if aims >= 3 then G.targeted = 14 else G.targeted = 13 end end end
    return m2
end
local function run(job, max)
    for _ = 1, max or 400 do
        G.t = G.t + 0.2
        local res = D._step(api, job, G.t)
        if res then return res end
    end
end
local job = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {}, expected = {},
              t0 = 0, queue = { CRATE }, left = {}, target = CRATE, planned = { [14] = CRATE }, world = "dev",
              counts_start = { ITEM_Resources_Wood_Ash = 3 } }
local res = run(job)
check("step: done", res ~= nil and res.ok == true, res and (tostring(res.reason) .. " " .. tostring(res.data.detail)))
check("step: menu then repair mode, then destroy, then leave", table.concat(G.presses, ","):find("menu,repair", 1, true) ~= nil
    and table.concat(G.presses, ","):find("destroy", 1, true) ~= nil and G.mode == "None", table.concat(G.presses, ","))
check("step: destroy pressed only once the game highlighted MY piece (3rd aim)", aims >= 3)
check("step: refund is the inventory gain", res and res.data.refund.ITEM_Resources_Wood_Ash == 8, res and res.data.refund.ITEM_Resources_Wood_Ash)
check("step: expected = its cost", res and res.data.expected.ITEM_Resources_Wood_Ash == 8)
check("step: the sentence says it", res and res.data.detail:find("Took down 1 piece (the Crate)", 1, true) and res.data.detail:find("8 Resources Wood Ash", 1, true),
    res and res.data.detail)
-- refused by the game: honest reason, nothing claimed
_G.DWDecon = nil
G.mode, G.presses, G.targeted, G.refuse, aims = "None", {}, 0, true, 0
G.alive[14] = true
local job2 = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {}, expected = {},
               t0 = G.t, queue = { CRATE }, left = {}, target = CRATE, planned = { [14] = CRATE }, world = "dev",
               counts_start = { ITEM_Resources_Wood_Ash = G.counts.ITEM_Resources_Wood_Ash } }
CRATE.done, CRATE.actor = nil, {}
local res2 = run(job2)
check("step: refused -> not ok", res2 and res2.ok == false, res2 and res2.reason)
check("step: the game's own words", res2 and res2.data.detail:find("Someone is using it", 1, true), res2 and res2.data.detail)
check("step: still left build mode", G.mode == "None" and res2 and res2.data.left_build_mode == true)

-- no handle (TargetedPieceHandle stays 0 on this client): the crosshair trace names the piece; the refund drops on
-- the ground, I walk over it (the magnet takes it), and the total is the bag's gain over the whole job
_G.DWDecon = nil
G.mode, G.presses, G.targeted, G.refuse, aims = "None", {}, 0, false, 0
G.alive[14] = true
api.module = function(n)
    local m2 = real_module(n)
    if n == "build" then m2.W.aim = function() aims = aims + 1; G.cross = { pid = 14, how = "box" } end end
    return m2
end
local DROP = { id = "BP_RuntimeSpawnedWorldItem_NoExpiry_C_1", name = "Ash Logs", item = "ITEM_Resources_Wood_Ash", count = 8, position = { 115.6, 1851.2, -32.0 } }
local real_press = D.W.press
D.W.press = function(a2, a)
    if a == "destroy" and G.mode == "RepairAndEdit" and G.cross and G.cross.pid == 14 then
        G.presses[#G.presses + 1] = a; G.alive[14] = nil; G.ground = { [DROP.id] = DROP }; return true
    end
    return real_press(a2, a)
end
local walked_to
api.call = function(mod, fn, goal)
    if mod == "move" and fn == "go_to" then
        G.me = { goal[1], goal[2], G.me[3] }
        if goal == DROP.position then walked_to = goal; G.ground = {}; G.counts.ITEM_Resources_Wood_Ash = G.counts.ITEM_Resources_Wood_Ash + 8 end
    end
    return { ok = true }
end
CRATE.done, CRATE.actor = nil, nil
local c0 = G.counts.ITEM_Resources_Wood_Ash
local job3 = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {}, expected = {},
               t0 = G.t, queue = { CRATE }, left = {}, target = CRATE, planned = { [14] = CRATE }, world = "dev", rows = { CRATE },
               counts_start = { ITEM_Resources_Wood_Ash = c0 } }
local res3 = run(job3)
check("crosshair: done with no handle", res3 and res3.ok == true, res3 and (tostring(res3.reason) .. " " .. tostring(res3.data.detail)))
check("crosshair: the drop was seen", res3 and res3.data.dropped and #res3.data.dropped == 1)
check("collect: walked over the drop", walked_to ~= nil)
check("collect: refund counted once = the bag's gain", res3 and res3.data.refund.ITEM_Resources_Wood_Ash == 8, res3 and res3.data.refund.ITEM_Resources_Wood_Ash)
check("collect: nothing left on the ground", res3 and res3.data.on_ground == nil)
check("collect: the sentence says all it cost", res3 and res3.data.detail:find("(all it cost)", 1, true), res3 and res3.data.detail)
-- the drop stays (magnet missed): it says it still lies there
_G.DWDecon = nil
G.mode, G.presses, G.cross, aims = "None", {}, nil, 0
G.alive[14] = true
api.call = function(mod, fn, goal) if mod == "move" and fn == "go_to" then G.me = { goal[1], goal[2], G.me[3] } end return { ok = true } end
CRATE.done = nil
local job4 = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {}, expected = {},
               t0 = G.t, queue = { CRATE }, left = {}, target = CRATE, planned = { [14] = CRATE }, world = "dev", rows = { CRATE },
               counts_start = { ITEM_Resources_Wood_Ash = G.counts.ITEM_Resources_Wood_Ash } }
local res4 = run(job4)
check("left on ground: reported", res4 and res4.data.on_ground and #res4.data.on_ground == 1, res4 and res4.data.detail)
check("left on ground: the sentence says so", res4 and res4.data.detail:find("still lie on the ground", 1, true), res4 and res4.data.detail)
-- nothing came back and nothing dropped: the cost is named with the game's display name from my inventory listing
-- (live 16:11Z: "it cost 4 Resources Wood Ash")
_G.DWDecon = nil
G.mode, G.presses, G.cross, aims, G.ground = "None", {}, nil, 0, {}
G.alive[14] = true
local press_drop = D.W.press
D.W.press = function(a2, a)
    if a == "destroy" and G.mode == "RepairAndEdit" and G.cross and G.cross.pid == 14 then
        G.presses[#G.presses + 1] = a; G.alive[14] = nil; return true
    end
    return real_press(a2, a)
end
api.call = function(mod, fn, goal)
    if mod == "inventory" and fn == "list" then
        return { ok = true, data = { bag = { { item = "ITEM_Resources_Wood_Ash", name = "Ash Logs", count = 3 } } } }
    end
    if mod == "move" and fn == "go_to" then G.me = { goal[1], goal[2], G.me[3] } end
    return { ok = true }
end
CRATE.done = nil
local job5 = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {},
               expected = { ITEM_Resources_Wood_Ash = 4 }, t0 = G.t, queue = { CRATE }, left = {}, target = CRATE,
               planned = { [14] = CRATE }, world = "dev", rows = { CRATE },
               counts_start = { ITEM_Resources_Wood_Ash = G.counts.ITEM_Resources_Wood_Ash } }
local res5 = run(job5)
check("no refund: the cost in the game's own name (Ash Logs), not the item id", res5 and res5.data.detail
    and res5.data.detail:find("Ash Logs)", 1, true) and not res5.data.detail:find("Wood Ash", 1, true), res5 and res5.data.detail)
D.W.press = press_drop
-- safety: a press that also takes down something I didn't plan (a station, a supporting floor) stops the job
_G.DWDecon = nil
G.mode, G.presses, G.cross, aims, G.ground = "None", {}, nil, 0, {}
G.alive[14], G.alive[12] = true, true
local TABLE = { pid = 12, id = "BP_BaseBuilding_CraftingTable_C_12", name = "Crafting Table", kind = "station", position = { 113, 1850, -32 } }
D.W.press = function(a2, a)
    if a == "destroy" and G.mode == "RepairAndEdit" and G.cross and G.cross.pid == 14 then
        G.presses[#G.presses + 1] = a; G.alive[14] = nil; G.alive[12] = nil; return true
    end
    return real_press(a2, a)
end
CRATE.done = nil
local job5 = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, collapsed = {}, refund = {}, dropped = {}, expected = {},
               t0 = G.t, queue = { CRATE }, left = {}, target = CRATE, planned = { [14] = CRATE }, world = "dev", rows = { CRATE, TABLE },
               counts_start = {} }
local res5 = run(job5)
check("collateral: stops, not ok", res5 and res5.ok == false, res5 and res5.reason)
check("collateral: names the piece", res5 and res5.data.detail and res5.data.detail:find("Crafting Table", 1, true), res5 and res5.data.detail)
check("collateral: listed in data", res5 and res5.data.collateral and res5.data.collateral[1] and res5.data.collateral[1].pid == 12)
G.alive[12] = true
D.W.press = real_press

print(string.format("deconstruct: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
