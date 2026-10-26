-- Offline tests for client_mod/scripts/build.lua (docs/design/build-primitive.md + review 2026-10-26):
-- buildables from the game's own data (ProgressComponent.BuildingsUnlocked x UBuildingPieceData), over fake
-- UE objects shaped like the live P1a/P1b reads. Run: lua client_mod/tests/test_build.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end
local U = assert(loadfile(root .. "/mod/body/util.lua"))()

local function uobj(full, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    return t
end
local function ftext(s) return { ToString = function() return s end } end
local function tarray(items, reads)
    return { ForEach = function(_, f)
        if reads then reads.n = reads.n + 1 end
        for i, v in ipairs(items) do f(i, { get = function() return v end }) end
    end }
end
local function item(id, name) return uobj("ItemData /Game/Items/" .. id .. "." .. id, { Name = ftext(name) }) end
local STONE, ASH = item("ITEM_Resources_Stone", "Stone"), item("ITEM_Resources_Wood_Ash", "Ash Logs")
local req_reads = { n = 0 }
local function piece(id, name, cost, extra)
    local reqs = {}
    for _, c in ipairs(cost) do reqs[#reqs + 1] = { Amount = c[2], ItemData = c[1] } end
    local t = { DisplayName = ftext(name), Description = ftext(name .. " description"), Category = { TagName = ftext("None") },
                Requirements = tarray(reqs, req_reads), ConstructionXPOnBuild = 20, BuildingPieceDataIndex = 26,
                ShelterRequirementText = ftext("") }
    for k, v in pairs(extra or {}) do t[k] = v end
    return uobj("BuildingPieceData /Game/Gameplay/BaseBuilding/Data/BuildingPieces/" .. id .. "." .. id, t)
end
local campfire = piece("BUILDPIECE_Campfire", "Campfire", { { STONE, 6 } }, { ShelterRequirementText = ftext("Must Be Exposed") })
local table_ = piece("BUILDPIECE_CraftingStation_Basic", "Crafting Table", { { ASH, 4 } })
local totem = piece("DA_BaseBuilding_Building_Protection_Totem", "Build Protection Totem", {}, { bOnlyAvailableToHost = true, ConstructionXPOnBuild = 0 })
local chinchompa = piece("BUILDPIECE_Decoration_DeluxeEdition_Pet_Chinchompa", "Sleeping Chinchompa", {})
-- live P1a: the unlock list repeats entries
local unlocked = { chinchompa, campfire, table_, totem, chinchompa }
local prog = uobj("ProgressComponent /Game/L.L:PersistentLevel.PC_1.ProgressComponent", { BuildingsUnlocked = tarray(unlocked) })
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.PC_1", { ProgressComponent = prog })

local PRIV = { build = true, owner = false }
local CARRIED = { ITEM_Resources_Stone = 6, ITEM_Resources_Wood_Ash = 1 }
local CHESTS = {}
local api = {
    null = "NULL",
    object = function(t) return t end,
    counts = function() return CARRIED end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data } end,
    match_score = function(t, about)
        local hay = ((t.name or "") .. " " .. (t.class or "")):lower()
        return hay:find(about:lower(), 1, true) and 1 or 0
    end,
    census_things = function() return CHESTS end,
    actor_of = function(t) return t end,
    module = function(n)
        if n == "sense" then return { U = U, local_pc = function() return pc end, has_privilege = function(p) return PRIV[p] end } end
        if n == "inventory" then return {
            inventory_of = function(a) return a and a.inv end,
            external_rows = function(inv) return { by_item = inv } end } end
    end,
}
_G.DWBuild = nil
local Bd = assert(loadfile(root .. "/client_mod/scripts/build.lua"))()
local function call(args) return Bd.HANDLERS.buildables(nil, args or {}, { api = api }) end

local r = call()
check("buildables ok", r.ok, r.reason)
local by = {}
for _, p in ipairs(r.data.pieces) do by[p.id] = p end
check("deduplicated (5 entries, 4 unique)", r.data.unlocked == 4 and #r.data.pieces == 4, r.data.unlocked)
check("campfire from data: name, cost, xp, can build now (6 stone carried)", by.BUILDPIECE_Campfire and by.BUILDPIECE_Campfire.name == "Campfire"
    and by.BUILDPIECE_Campfire.cost[1].item == "ITEM_Resources_Stone" and by.BUILDPIECE_Campfire.cost[1].count == 6
    and by.BUILDPIECE_Campfire.xp == 20 and by.BUILDPIECE_Campfire.can_build_now == true and by.BUILDPIECE_Campfire.missing == nil)
local t = by.BUILDPIECE_CraftingStation_Basic
check("crafting table: missing in crafting's row shape {item, name, need, have}", t and t.can_build_now == false and t.missing[1].item == "ITEM_Resources_Wood_Ash"
    and t.missing[1].need == 4 and t.missing[1].have == 1 and t.missing[1].name == "Ash Logs")
check("host-only totem: not buildable without the Owner privilege, says why", by.DA_BaseBuilding_Building_Protection_Totem.host_only == true
    and by.DA_BaseBuilding_Building_Protection_Totem.can_build_now == false and by.DA_BaseBuilding_Building_Protection_Totem.blocked_by == "host_only")
check("buildable pieces listed first", r.data.pieces[1].can_build_now == true)
check("shelter text kept for speech", by.BUILDPIECE_Campfire.shelter_text == "Must Be Exposed")

-- about ranks matches (by name / asset id, never by Category); can_build_now filters
r = call({ about = "table" })
check("about: only matches, the table first", r.data.matched == 1 and r.data.pieces[1].id == "BUILDPIECE_CraftingStation_Basic", r.data.matched)
r = call({ can_build_now = true })
local ids = {}
for _, p in ipairs(r.data.pieces) do ids[#ids + 1] = p.id end
check("can_build_now: campfire and the free chinchompa only", #r.data.pieces == 2, table.concat(ids, ","))

-- static data is read once per session (struct arrays cached, review finding 11)
local n0 = req_reads.n
call(); call()
check("requirements read once per piece, not per call", req_reads.n == n0, req_reads.n - n0)

-- linked storage: the game may build from a nearby chest (advisory, never blocking in code)
CHESTS = { { id = "chest_1", category = "interactables", kind = "storage", inv = { ITEM_Resources_Wood_Ash = 5 } } }
r = call({ about = "table" })
local m = r.data.pieces[1].missing[1]
check("storage nearby: missing row says how many are in storage; flagged storage_may_cover", m.in_storage == 5 and r.data.pieces[1].storage_may_cover == true,
    tostring(m.in_storage))
CHESTS = {}

-- no Build privilege: listed, but nothing is buildable and the reply says why
PRIV.build = false
r = call()
check("no Build privilege: may_build=false, note, nothing can_build_now", r.data.may_build == false and r.data.note:find("building rights")
    and not r.data.pieces[1].can_build_now)
PRIV.build = true

-- pause: no game read at all
_G.DW_PAUSE = true
r = call()
check("paused: state_unavailable, no reads", r.ok == false and r.reason == "state_unavailable")
_G.DW_PAUSE = nil


-- ================================================================ the build action (review §21 tests)
-- A fake game behind build.lua's W functions: build mode states, the menu API select, the validity hook
-- firing after each aim (a scripted state per spot), the MPC colour, the place press spending materials.
local G
local Wb = Bd.W
local saved = {}
for k, v in pairs(Wb) do saved[k] = v end
local T = 100
local function reset_game(opts)
    opts = opts or {}
    _G.DWBuild = nil
    for k, v in pairs(saved) do Wb[k] = v end
    G = { mode = "None", placing = nil, presses = {}, seq = 0, hook = {}, pos = { 0, 0, 0 }, xp = 1000, aims = 0,
          state = opts.state or function() return 0 end, menu_dead = opts.menu_dead, select_dead = opts.select_dead,
          refuse = opts.refuse, no_spend = opts.no_spend, mpc_off = opts.mpc_off, no_hook = opts.no_hook, cancels = 0 }
    CARRIED.ITEM_Resources_Stone, CARRIED.ITEM_Resources_Wood_Ash = 6, 1
    local function rec(kind, v) G.seq = G.seq + 1; G.hook[kind] = { seq = G.seq, v = v } end
    G.rec = rec
    Wb.mode = function() return G.mode end
    Wb.placing = function() return G.placing end
    Wb.menu_action = function() return "menu" end
    Wb.rotate_action = function() return "rotate" end
    Wb.place_action = function() return "place" end
    Wb.press = function(_, a)
        G.presses[#G.presses + 1] = a
        if a == "menu" and not G.menu_dead then G.mode = (G.mode == "None") and "Selection" or "None" end
        if a == "cancel" then G.cancels = G.cancels + 1; G.mode = (G.mode == "Placement") and "Selection" or "None" end
        if a == "place" then
            if G.mode ~= "Placement" then G.stray_place = true end
            if G.refuse then rec("refused", G.refuse); return true end
            if not G.no_spend then
                CARRIED.ITEM_Resources_Stone = CARRIED.ITEM_Resources_Stone - 6
                G.xp = G.xp + 20
                rec("complete", 26)
            end
        end
        return true
    end
    Wb.select = function(_, data)
        if G.select_dead then return true end
        G.mode, G.placing = "Placement", data:GetFullName():match("%.([%w_]+)$")
        return true
    end
    Wb.aim = function(_, p)
        G.aimed, G.aims = p, G.aims + 1
        G.cur = G.state(p, G.aims)
        if not G.no_hook then rec("validity", G.cur) end
        return 3
    end
    Wb.mpc = function()
        if G.mpc_off or not G.aimed then return nil end
        local st = G.cur or 13
        return { index = (st == 0 or st == 4) and 2 or ((st == 7 or st == 13) and 0 or 1), position = G.aimed }
    end
    Wb.hook = function(kind) return G.hook[kind] end
    Wb.hook_seq = function() return G.seq end
    Wb.arm_hooks = function() G.armed = true; return true end
    Wb.construction_xp = function() return G.xp end
    Wb.structures_near = function() return {} end
    Wb.clock = function() return T end
    Wb.texts = function() return Bd.STATE_TEXT end
    Wb.trace = function(_, a, b)
        if b.Z > a.Z then return false, {} end
        return true, { ImpactPoint = { Z = 0 }, ImpactNormal = { Z = 1 } }
    end
    Wb.storage_counts = function() return {}, {} end
end
-- the bridge services the action uses
api.my_position = function() return G.pos end
api.now = function() return T end
api.reflex_owns_pawn = function() return false end
api.me = function() return { skills = { { skill = "Construction", xp = G.xp } } } end
api.reason_code = function(r) return r end
api.find_thing = function(id) if id == "bench_1" then return { id = "bench_1", position = { 8, 0, 0 } } end end
local MOVES = {}
api.call = function(mod, fn, a)
    if mod == "move" and fn == "go_to" then MOVES[#MOVES + 1] = a; G.pos = { a[1], a[2], a[3] }; return { ok = true } end
    if mod == "move" and fn == "stop" then return { ok = true } end
    return { ok = true }
end
api.move_status = function() return { mode = "idle", result = { status = "arrived" } } end
-- input.lua: the real one would read the game; a fake with the same API over G
local INPUT = { claims = {} }
function INPUT.gate() return nil end
function INPUT.build_mode() return G.mode end
function INPUT.claim(k, o) INPUT.claims[k] = o end
function INPUT.release(k) INPUT.claims[k] = nil end
function INPUT.raw_inject(a) return Wb.press(nil, a) end
function INPUT.leave_build_step(press) if G.mode ~= "None" then press("cancel") end return G.mode end
local ARB
local mod0 = api.module
api.module = function(n)
    if n == "input" then return INPUT end
    if n == "arbiter" then return ARB end
    return mod0(n)
end
api.log = function() end

local function build(args, n, dt)
    local h = Bd.HANDLERS.build(nil, args, { api = api, id = "b1" })
    if h.ok == false then return h end
    local a = h.pending
    for _ = 1, n or 300 do
        T = T + (dt or 0.2)
        local r = a:poll()
        if r then return r, a end
    end
    return nil, a
end
local function count(list, x) local c = 0; for _, v in ipairs(list) do if v == x then c = c + 1 end end return c end

-- 1. happy path: Campfire near the bench -> menu, select, aim, valid, place, verified (spent + telemetry), left
reset_game()
local r = build({ piece = "campfire", near = "bench_1" })
check("build: ok, verified by spend + the game's completion telemetry", r and r.ok and r.data.evidence == "telemetry"
    and r.data.spent.ITEM_Resources_Stone == 6 and r.data.piece == "BUILDPIECE_Campfire", r and (tostring(r.reason) .. " " .. tostring(r.data and (r.data.why or r.data.detail))) or "nil")
check("build: left build mode afterwards; modal released", G.mode == "None" and INPUT.claims.build == nil)
check("build: one menu press, one place press, hooks armed", count(G.presses, "menu") == 1 and count(G.presses, "place") == 1 and G.armed)
check("build: never a place press outside Placement", not G.stray_place)

-- 2. no Build privilege -> no_permission, no key pressed
reset_game()
PRIV.build = false
r = build({ piece = "campfire" })
check("no Build privilege: no_permission before any press", r.reason == "no_permission" and #G.presses == 0, r.reason)
PRIV.build = true

-- 3. ambiguous / unknown / typo
reset_game()
r = build({ piece = "camfire" })
check("a unique typo resolves (camfire -> Campfire)", r and r.ok, r and r.reason)
reset_game()
r = build({ piece = "dragon throne" })
check("unknown piece: unknown_target, no press", r.reason == "unknown_target" and #G.presses == 0)

-- ambiguous: two unlocked pieces with the same name -> ambiguous_target with candidates, never a guess
do
    local twin = piece("BUILDPIECE_Campfire_Iron", "Campfire", { { STONE, 8 } })
    local d, p, code, more = Bd.resolve(api, { campfire, twin }, "campfire")
    check("ambiguous piece name: ambiguous_target with both candidates", d == nil and code == "ambiguous_target" and #more == 2)
end
-- materials in a linked chest: the spend is verified across own inventory + storage
reset_game()
CARRIED.ITEM_Resources_Stone = 0
local chest_stone = 6
Wb.storage_counts = function() return { ITEM_Resources_Stone = chest_stone }, {} end
local press0 = Wb.press
Wb.press = function(x, a)
    if a == "place" and G.mode == "Placement" then chest_stone = 0; G.xp = G.xp + 20; G.rec("complete", 26); G.presses[#G.presses + 1] = a; return true end
    return press0(x, a)
end
r = build({ piece = "campfire" })
check("materials in a nearby chest: built, spend verified from the chest", r and r.ok and r.data.spent.ITEM_Resources_Stone == 6, r and r.reason)

-- 4. host-only piece
reset_game()
r = build({ piece = "Build Protection Totem" })
check("host-only piece without Owner: host_only, no press", r.reason == "host_only" and #G.presses == 0)

-- 5. the menu was only slow: B is never pressed twice while it reads anything but None
reset_game({ menu_dead = true })
r = build({ piece = "campfire" }, 60)
check("menu never opens: bounded (2 presses), verification_failed menu_not_open", r and r.reason == "verification_failed" and r.data.why == "menu_not_open"
    and count(G.presses, "menu") == 2, r and r.data and r.data.why)

-- 6. unreadable preview (no MPC / no hook) -> no place press, says so
reset_game({ mpc_off = true })
r = build({ piece = "campfire" })
check("unreadable preview: never pressed, preview_unreadable, left build mode", r and r.data.why == "preview_unreadable" and count(G.presses, "place") == 0 and G.mode == "None",
    r and r.data and r.data.why)
reset_game({ no_hook = true })
r = build({ piece = "campfire" })
check("no validity hook event (MPC green only): no press", r and count(G.presses, "place") == 0 and r.data.why == "preview_unreadable", r and r.data and r.data.why)

-- 7. NeedsSnapping is green in the MPC (P1b) but not Valid: never pressed
reset_game({ state = function() return 4 end })
r = build({ piece = "campfire" })
check("NeedsSnapping (MPC 2, hook 4): no press, blocked with the game's reason", r and r.reason == "blocked" and count(G.presses, "place") == 0 and r.data.why == "NeedsSnapping",
    r and r.reason)

-- 8. first spot overlapping, a later one valid -> placed there, the rejection reported
reset_game({ state = function(p, n) return n <= 3 and 1 or 0 end })
r = build({ piece = "campfire", near = "bench_1" })
check("Overlapping at the first spot -> another spot, tried reported", r and r.ok and r.data.tried and r.data.tried[1].why == "Overlapping", r and r.reason)

-- 9. every spot needs a foundation -> blocked, in the game's own words
reset_game({ state = function() return 3 end })
r = build({ piece = "campfire" })
check("all spots NeedsFoundation: blocked + the game's text", r and r.reason == "blocked" and r.data.detail:find("foundation"), r and r.data and r.data.detail)

-- 10. outside-only piece refused inside: the piece's own shelter text
reset_game({ state = function() return 11 end })
r = build({ piece = "campfire" })
check("ShelterCheckFailed: the piece's own text (Must Be Exposed)", r and r.data.detail:find("Must Be Exposed"), r and r.data and r.data.detail)

-- 11. the server refuses after the press -> the reason it sent
reset_game({ refuse = 6 })
r = build({ piece = "campfire" })
check("server refusal after place: missing_materials with the game's words", r and r.reason == "missing_materials" and r.data.detail:find("more materials"), r and r.reason)

-- 12. pressed, valid, but nothing spent and nothing built -> verification_failed (never a claimed success)
reset_game({ no_spend = true })
r = build({ piece = "campfire" })
check("nothing spent / built: verification_failed", r and r.reason == "verification_failed" and G.mode == "None", r and r.reason)

-- 13. a reflex pre-empts during Placement: build mode is left AT ONCE (no stray place); resume re-opens and finishes
ARB = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
ARB.clock = function() return T end
ARB.set_move({ stop = function() return { ok = true } end, status = function() return { mode = "idle" } end })
ARB.reset()
reset_game()
local h = Bd.HANDLERS.build(nil, { piece = "campfire" }, { api = api, id = "b2" })
local a = h.pending
for _ = 1, 400 do T = T + 0.1; a:poll(); if G.mode == "Placement" then break end end
check("reached Placement", G.mode == "Placement")
local fight = ARB.request(nil, { name = "combat:reflex", level = "reflex", uses_move = true })
check("reflex pre-empt: build mode left at once, claim released", fight.ok and G.mode ~= "Placement" and INPUT.claims.build == nil, G.mode)
for _ = 1, 20 do T = T + 0.5; a:poll() end
check("while the reflex fights: no place press", count(G.presses, "place") == 0)
INPUT.leave_build_step(function(x) Wb.press(nil, x) end) -- (the orphan sweep finishes leaving)
ARB.release(nil, fight.token, "won")
r = nil
for _ = 1, 400 do T = T + 0.2; r = a:poll(); if r then break end end
check("after the fight: re-opened, placed, verified", r and r.ok and count(G.presses, "menu") == 2, r and r.reason)
ARB = nil

-- 14. pause during Placement: no game call at all; afterwards it carries on
reset_game()
h = Bd.HANDLERS.build(nil, { piece = "campfire" }, { api = api, id = "b3" })
a = h.pending
for _ = 1, 400 do T = T + 0.1; a:poll(); if G.mode == "Placement" then break end end
local n0 = #G.presses
local a0 = G.aims
_G.DW_PAUSE = true
for _ = 1, 30 do T = T + 0.5; a:poll() end
check("paused: no presses, no aims", #G.presses == n0 and G.aims == a0)
_G.DW_PAUSE = nil
r = nil
for _ = 1, 400 do T = T + 0.2; r = a:poll(); if r then break end end
check("after the pause: finishes", r and r.ok, r and r.reason)

-- 15. cancel (stop) leaves build mode
reset_game()
h = Bd.HANDLERS.build(nil, { piece = "campfire" }, { api = api, id = "b4" })
a = h.pending
for _ = 1, 400 do T = T + 0.1; a:poll(); if G.mode == "Placement" then break end end
a.cancel()
check("cancel: Cancel pressed, claim released", G.cancels >= 1 and INPUT.claims.build == nil)

-- get_state.structures: near, capped, previews excluded, refreshed at most every 5 s (one find_all then)
do
    for k, v in pairs(saved) do Wb[k] = v end
    _G.DWBuild = nil
    local finds = 0
    local actors = {}
    for i = 1, 20 do
        actors[i] = uobj("BP_Campfire_C /Game/L.L:PersistentLevel.BP_Campfire_C_" .. i, {
            K2_GetActorLocation = function() return { X = i * 100, Y = 0, Z = 0 } end, BuildingPieceData = campfire,
            DisplayName = ftext("Campfire"), bIsPreview = (i == 1) })
    end
    FindAllOf = function(cls) if cls == "BaseBuildingActor" then finds = finds + 1; return actors end return {} end
    G = G or {}
    G.pos = { 0, 0, 0 }
    T = 1000
    local ex = Bd.state_extras(api)
    local st = ex and ex.structures or {}
    check("structures: capped at 15, preview excluded, nearest first, with piece and name", #st == 15 and st[1].id == "BP_Campfire_C_2"
        and st[1].piece == "BUILDPIECE_Campfire" and st[1].name == "Campfire", #st)
    T = 1002; Bd.state_extras(api)
    check("structures: cached within 5 s (no second find_all)", finds == 1, finds)
    T = 1006; Bd.state_extras(api)
    check("structures: refreshed after 5 s", finds == 2, finds)
    FindAllOf = function() return {} end
end

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
