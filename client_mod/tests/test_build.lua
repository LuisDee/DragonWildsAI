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
          refuse = opts.refuse, no_spend = opts.no_spend, mpc_off = opts.mpc_off, no_hook = opts.no_hook, cancels = 0,
          sticky = opts.sticky, bounce = opts.bounce }
    CARRIED.ITEM_Resources_Stone, CARRIED.ITEM_Resources_Wood_Ash = 6, 1
    local function rec(kind, v) G.seq = G.seq + 1; G.hook[kind] = { seq = G.seq, v = v } end
    G.rec = rec
    Wb.mode = function()
        if G.rebound and G.mode == "None" then G.rebound = false; local m = G.mode; G.mode = "Placement"; return m end
        return G.mode
    end
    Wb.placing = function() return G.placing end
    Wb.menu_action = function() return "menu" end
    Wb.rotate_action = function() return "rotate" end
    Wb.place_action = function() return "place" end
    Wb.press = function(_, a)
        G.presses[#G.presses + 1] = a
        if a == "menu" and not G.menu_dead then G.mode = (G.mode == "None") and "Selection" or "None" end
        if a == "cancel" then
            G.cancels = G.cancels + 1
            if not G.sticky then G.mode = "None" end -- live P3: one Cancel from Placement goes straight to None
            if G.bounce and G.mode == "None" then G.bounce = false; G.rebound = true end -- the game re-opens placement once
        end
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
    Wb.preview_actor = function() return {} end
    Wb.snap_only = function() return false end
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
local DEC -- a fake deconstruct (his ledger of pieces he placed)
local mod0 = api.module
api.module = function(n)
    if n == "input" then return INPUT end
    if n == "arbiter" then return ARB end
    if n == "deconstruct" then return DEC end
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

-- live 14:59: the build screen must be VERIFIED closed at the end (None read twice), on success and on failure
reset_game({ bounce = true })
r = build({ piece = "campfire" })
check("leave: a None that bounces back to Placement is not 'closed': cancelled again, then confirmed None",
    r and r.ok and G.mode == "None" and r.data.left_build_mode == true and G.cancels == 2, r and (tostring(G.mode) .. " cancels=" .. G.cancels))
reset_game({ sticky = true })
r = build({ piece = "campfire" })
check("leave: Cancel never works -> bounded (3), reported left_build_mode=false with a warning, claim released",
    r and r.ok and r.data.left_build_mode == false and r.data.warning and G.cancels == 3 and INPUT.claims.build == nil,
    r and (tostring(r.data.left_build_mode) .. " cancels=" .. G.cancels))
reset_game({ sticky = true, state = function() return 3 end })
r = build({ piece = "campfire" })
check("leave on failure too: blocked result still reports the screen state", r and r.reason == "blocked" and r.data.left_build_mode == false)

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
check("no validity hook (live P4: it never fires): MPC 2 on target -> pressed and verified", r and r.ok and count(G.presses, "place") == 1, r and r.reason)
-- placed freely, off any floor, far from his roofed house: the reply says how far (live 07:4xZ), and never errors
-- (live 08:0xZ: a nil 'cfg' in that sentence broke every free placement)
reset_game({ no_hook = true })
DEC = { ledger = function() return { pieces = {} } end, mark_mine = function() end,
        bases = function() return { { centre = { 60, 0, 0 }, pieces = 11, covered = true, distance_m = 60 } } end }
local sn0, press0 = Wb.structures_near, Wb.press
Wb.press = function(x, a) if a == "place" and G.mode == "Placement" then G.placed = true end; return press0(x, a) end
Wb.structures_near = function() if G.placed then return { { id = "BP_Station_Campfire_C_1", position = { 3, 0, 0 }, yaw = 0 } } end; return {} end
r = build({ piece = "campfire" })
Wb.structures_near, Wb.press = sn0, press0
check("free placement 60 m from his house: built, and the line says it isn't by the house",
    r and r.ok and tostring(r.data.built):find("It is 60 m from my house (my roofed building of 11 pieces at (60, 0), W of it), not by it.", 1, true),
    r and (tostring(r.reason) .. " " .. tostring(r.data.built or r.data.detail)))
DEC = nil
-- a snap piece (preview has plugs): colour 2 may be NeedsSnapping -> never pressed (known limit)
reset_game({ no_hook = true })
Wb.preview_actor = function() return {} end
Wb.snap_only = function() return true end
r = build({ piece = "campfire" })
check("snap piece + colour 2 only: preview_ambiguous, no press", r and r.data.why == "preview_ambiguous" and count(G.presses, "place") == 0, r and r.data and r.data.why)
-- MPC 1 and materials short (own + storage): missing_materials
reset_game({ no_hook = true, state = function() return 6 end })
CARRIED.ITEM_Resources_Stone = 0
r = build({ piece = "campfire" })
check("MPC 1 + short of stone: missing_materials with what's missing", r and r.reason == "missing_materials" and r.data.missing and r.data.missing[1].need == 6, r and r.reason)
check("short with none carried or stored near: said at once, nothing pressed (live 07:4xZ: 11.5 s to the game's refusal)",
    r and #G.presses == 0 and tostring(r.data.detail):find("needs 6 Stone (I carry 0), and I see none of it in storage within 15 m", 1, true), r and r.data.detail)

-- 7. NeedsSnapping is green in the MPC (P1b) but not Valid: never pressed
reset_game({ state = function() return 4 end })
r = build({ piece = "campfire" })
check("NeedsSnapping (MPC 2, hook 4): no press, blocked with the game's reason", r and r.reason == "blocked" and count(G.presses, "place") == 0 and r.data.why == "NeedsSnapping",
    r and r.reason)

-- 8. first spot overlapping, a later one valid -> placed there, the rejection reported
reset_game({ state = function(p, n) return n <= 3 and 1 or 0 end })
r = build({ piece = "campfire", near = "bench_1" })
check("Overlapping at the first spot -> another spot, the rejected spot listed as rejected before placing",
    r and r.ok and r.data.rejected_previews_before_placing and r.data.rejected_previews_before_placing[1].why == "Overlapping"
    and r.data.tried == nil, r and r.reason)

-- 8b. co-play 2026-11-01 (the crate): no validity hook, two red previews, then green -> placed. The reply leads with
-- what was placed and where, finds the NEW piece in the census (not the one already standing there), and labels
-- the red previews as rejected attempts (no "valid": false rows that read as a failed build).
local function fake_census(opts)
    opts = opts or {}
    local press0 = Wb.press
    Wb.press = function(x, a)
        if a == "place" and G.mode == "Placement" and not opts.no_actor then G.new_at = G.aimed end
        return press0(x, a)
    end
    G.old = opts.old -- {id, position}: a piece of this kind already standing near the spot
    G.census_reads = 0
    Wb.structures_near = function(_, id, pos, r)
        G.census_reads = G.census_reads + 1
        local out = {}
        if G.old then out[#out + 1] = { id = G.old.id, position = G.old.position, yaw = 0 } end
        if G.new_at then out[#out + 1] = { id = "BP_Campfire_C_NEW", position = { G.new_at[1], G.new_at[2], G.new_at[3] or 0 }, yaw = 90 } end
        return out
    end
end
reset_game({ no_hook = true, state = function(p, n) return n <= 3 and 1 or 0 end })
fake_census({ old = { id = "BP_Campfire_C_OLD", position = { 8.5, 0.5, 0 } } })
r = build({ piece = "campfire", near = "bench_1" })
local d8 = r and r.data or {}
check("crate case: ok, placed, the NEW piece's id (not the one already there)", r and r.ok and d8.placed == true
    and d8.structure == "BP_Campfire_C_NEW", r and (tostring(r.reason) .. " " .. tostring(d8.structure)))
check("crate case: the built line leads: what, distance + compass from me, position, facing, id",
    type(d8.built) == "string" and d8.built:find("^Placed the Campfire and it is built") and d8.built:find(" m [NESW]+ of me at %[")
    and d8.built:find("facing S") and d8.built:find("BP_Campfire_C_NEW", 1, true) and d8.built:find("6 Stone", 1, true), d8.built)
check("crate case: red previews listed as rejected before placing, said to be no failure; no valid=false rows",
    d8.rejected_previews_before_placing and #d8.rejected_previews_before_placing >= 1
    and d8.rejected_previews_before_placing[1].why == "preview_red" and d8.rejected_previews_before_placing[1].valid == nil
    and d8.built:find("rejected and nothing was placed there", 1, true) and d8.tried == nil, d8.built)
check("crate case: distance_m, direction and facing fields beside the line", type(d8.distance_m) == "number" and d8.facing == "S"
    and type(d8.direction) == "string", tostring(d8.distance_m) .. " " .. tostring(d8.direction))
do -- the bridge's encoder (dkjson) keeps the order: the model reads "built" first
    local J = assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))()
    local s = J.encode(d8)
    check("crate case: JSON starts with the built line, rejected previews after the placement", s:find('^{"built":')
        and s:find('"placed":true', 1, true) < s:find('"rejected_previews_before_placing"', 1, true), s:sub(1, 120))
end
check("crate case: get_state.structures cache dropped after a build", _G.DWBuild.structs_t == nil)

-- 8c. the game confirmed it (telemetry + spend) but the census never shows the piece: still ok, and says so
reset_game()
fake_census({ no_actor = true })
local t8 = T
r = build({ piece = "campfire" })
check("confirmed but not seen: ok, structure null, says it can't see it yet and where it should be",
    r and r.ok and r.data.structure == "NULL" and r.data.built:find("can't see it in the world yet", 1, true)
    and r.data.built:find("the game confirmed it", 1, true), r and r.data and r.data.built)
check("confirmed but not seen: looked for it a few times (<= find_s), not forever", G.census_reads >= 3 and (T - t8) < 30, G.census_reads)

-- 8d. no telemetry, no XP, no spend seen, but a new piece stands at the preview: built (and says the spend didn't show)
reset_game({ no_spend = true })
fake_census()
r = build({ piece = "campfire" })
check("new piece but no spend seen: ok, evidence actor, honest about the materials", r and r.ok and r.data.evidence == "actor"
    and r.data.structure == "BP_Campfire_C_NEW" and r.data.built:find("didn't visibly go down", 1, true), r and (tostring(r.reason) .. " " .. tostring(r.data and r.data.built)))

-- 8e. attach (research 2026-11-01-autonomous-building §6 step 3): build {on = "<id>[:side]"} presses only on the
-- positive snap signal (green AND the ghost itself on the flush spot while the cursor is aimed outside it), and the
-- reply measures how the new piece really sits from the census (never claims flush from the preview).
do
    local function near(a, b) return math.abs(a - b) < 1e-6 end
    -- live probe 2026-11-01: Square Foundation box 300 cm cube hanging below the actor origin (its location = its top)
    local FB = { origin = { 0, 0, -1.5 }, extent = { 1.5, 1.5, 1.5 } }
    local anchor = { id = "BP_Foundation_C_A", piece = "BUILDPIECE_Campfire", name = "Square Foundation", position = { 10, 0, 0 }, yaw = 0, box = FB }
    local p, ax = Bd.flush_spot(anchor, "E", FB)
    check("flush_spot E: 3 m east of the anchor, same level", near(p[1], 13) and near(p[2], 0) and near(p[3], 0) and near(ax[1], 1), p and table.concat(p, ","))
    p = Bd.flush_spot(anchor, "N", FB)
    check("flush_spot N: north = -Y", near(p[1], 10) and near(p[2], -3), table.concat(p, ","))
    p = Bd.flush_spot(anchor, "top", FB)
    check("flush_spot top: the new box's bottom on the anchor's top", near(p[3], 3), table.concat(p, ","))
    local turned = { position = { 0, 0, 0 }, yaw = 90, box = { origin = { 0, 0, 0 }, extent = { 2, 1, 1 } } }
    p = Bd.flush_spot(turned, "E", turned.box)
    check("flush_spot on a turned piece: its own axis nearest east (local Y, half 1 m)", near(p[1], 2) and math.abs(p[2]) < 1e-6, table.concat(p, ","))
    -- a wall (live profile: 303 x 100 x 303 cm, its origin at its bottom) stands ON the edge, across it
    local WB = { origin = { 0, 0, 1.515 }, extent = { 1.515, 0.5, 1.515 } }
    local wp, wax, wm = Bd.flush_spot(anchor, "N", WB)
    check("wall on the N edge: centred on the edge line, on the foundation's top, along the edge (yaw 0)",
        near(wp[1], 10) and near(wp[2], -1.5) and near(wp[3], 0) and wm and wm.edge and wm.yaw == 0, table.concat(wp, ","))
    wp, wax, wm = Bd.flush_spot(anchor, "E", WB)
    check("wall on the E edge: turned 90 to run along it", near(wp[1], 11.5) and near(wp[2], 0) and wm.yaw == 90, table.concat(wp, ","))
    local wr = Bd.flush_report(anchor, "E", WB, { position = { 11.5, 0, 0 }, yaw = 270 }, 0.06)
    check("wall report: yaw 270 runs along the E edge too (mod 180) -> square", wr.flush, wr.facing_off_deg)
    wr = Bd.flush_report(anchor, "E", WB, { position = { 11.5, 0, 0 }, yaw = 0 }, 0.06)
    check("wall report: across the edge instead of along it -> not square, turned 90", not wr.flush and math.abs(wr.facing_off_deg) == 90, wr.facing_off_deg)
    local rep = Bd.flush_report(anchor, "E", FB, { position = { 13, 0, 0 }, yaw = 90 }, 0.06)
    check("flush_report: exact spot, turned 90 (a square tile) -> flush", rep.flush and rep.gap_m == 0 and rep.level_m == 0 and rep.facing_off_deg == 0)
    rep = Bd.flush_report(anchor, "E", FB, { position = { 13.2, 0.1, -0.3 }, yaw = 10 }, 0.06)
    check("flush_report: gap, side offset, level and facing measured", not rep.flush and rep.gap_m == 0.2 and rep.offset_m == 0.1
        and rep.level_m == -0.3 and rep.facing_off_deg == 10, string.format("%s %s %s %s", rep.gap_m, rep.offset_m, rep.level_m, rep.facing_off_deg))

    -- the action over fakes: the ghost snaps (to snap_at) or stays where the cursor aims; the census shows the new piece at built_at
    local function attach_game(o)
        reset_game({ no_hook = true })
        CARRIED.ITEM_Resources_Stone = 12
        Wb.actor_info = function(_, id) if id == anchor.id then return anchor end end
        Wb.piece_profile = function() return { snap_only = o.snap_only or false, box = o.box or FB } end
        Wb.structures = function()
            local out = { { id = anchor.id, name = anchor.name, position = anchor.position, edges = o.edges } }
            for _, s in ipairs(o.others or {}) do out[#out + 1] = s end
            return out
        end
        Wb.preview_actor = function()
            if o.no_preview then return nil end
            return { IsValid = function() return true end,
                     K2_GetActorLocation = function()
                         local a = (o.snap and o.snap_at) or G.aimed or { 0, 0, 0 }
                         return { X = a[1] * 100, Y = a[2] * 100, Z = (a[3] or 0) * 100 }
                     end,
                     K2_GetActorRotation = function() return { Yaw = 0 } end }
        end
        local press0 = Wb.press
        Wb.press = function(x, a)
            if a == "place" and G.mode == "Placement" then G.placed = true end
            return press0(x, a)
        end
        Wb.structures_near = function()
            if G.placed then return { { id = "BP_Foundation_C_NEW", position = o.built_at, yaw = 90 } } end
            return {}
        end
    end
    attach_game({ snap = true, snap_at = { 13, 0, 0 }, built_at = { 13, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    local da = r and r.data or {}
    check("attach: snapped ghost on the flush spot -> placed, measured flush from the census", r and r.ok and da.attached_to == anchor.id
        and da.side == "E" and da.flush == true and da.gap_m == 0 and da.structure == "BP_Foundation_C_NEW", r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)))
    check("attach: the built line says where it sits", type(da.built) == "string"
        and da.built:find("sits flush on the E side of the Square Foundation (BP_Foundation_C_A)", 1, true), da.built)
    check("attach: aimed at the anchor's edge, on its top (a player's snap aim), never at the flush spot; one place press",
        G.aimed and math.abs(G.aimed[1] - 11.2) < 1e-6 and count(G.presses, "place") == 1, G.aimed and table.concat(G.aimed, ","))
    -- a verified build goes into his ledger of pieces he placed (get_state.structures mine; the game keeps no owner)
    do
        local noted, saved = {}, 0
        DEC = { world_id = function() return "dev" end, ledger = function(w) return { world = w, pieces = {} } end,
                note_mine = function(L, p, src) noted[#noted + 1] = { p = p, src = src, w = L.world }; return true end,
                save_ledger = function() saved = saved + 1; return true end }
        attach_game({ snap = true, snap_at = { 13, 0, 0 }, built_at = { 13, 0, 0 } })
        local r2 = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
        local n1 = noted[1]
        check("build: the verified piece is noted as his (piece, census position, build reply), ledger saved",
            r2 and r2.ok and #noted == 1 and n1.p.piece == "BUILDPIECE_Campfire" and n1.src == "build reply" and n1.w == "dev"
            and n1.p.position[1] == 13 and saved == 1, r2 and (tostring(r2.data.structure) .. " noted " .. #noted))
        DEC = nil
    end

    attach_game({ snap = false, built_at = { 13, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach: green but never snapped (ghost stays where aimed) -> never pressed, says so", r and not r.ok and da.why == "not_snapped"
        and count(G.presses, "place") == 0 and tostring(da.detail):find("couldn't get the Campfire to sit flush on the E side of the Square Foundation", 1, true)
        and tostring(da.detail):find("Nothing was placed", 1, true) and type(da.ghost_off_m) == "number", r and (tostring(r.reason) .. " " .. tostring(da.detail)))

    -- a door aimed at a door frame's side (live 21:16Z, "on 107" then "107:N"): the reply says it goes in the frame
    do
        local p0, b0, n0 = anchor.piece, anchor.box, anchor.name
        anchor.piece, anchor.box, anchor.name = "DA_T1_Wall_Large_Doorframe", WB, "WALL WITH DOOR FRAME"
        attach_game({ snap = false, box = { origin = { 0, 0, 1.1 }, extent = { 0.75, 0.1, 1.1 } }, built_at = { 10, 0, 0 } })
        r = build({ piece = "campfire", on = "BP_Foundation_C_A:N" })
        da = r and r.data or {}
        check("attach: a door that never lands on a frame's side -> nothing placed, and the reply says it goes in on ':in'",
            r and not r.ok and tostring(da.detail):find("A door goes into the frame's opening: on 'BP_Foundation_C_A:in'.", 1, true),
            r and (tostring(r.reason) .. " " .. tostring(da.detail)))
        anchor.piece, anchor.box, anchor.name = p0, b0, n0
    end
    -- a roof aimed at a foundation's top (live brain run 19:42Z, twice: "the closest its preview came was 1.68 m"):
    -- the reply says roofs snap onto wall tops and names the on that reaches over this floor from its walls
    local RB = { origin = { 0, 0, 0.75 }, extent = { 1.5, 1.5, 0.75 } }
    local hint = Bd.roof_hint(FB, RB, { N = "Wall BP_Wall_C_9", E = "Doorframe BuildingPiece_81", S = "beside: Square Foundation BuildingPiece_79", W = "open" })
    check("roof_hint: the walls on the floor's edges, each from its side facing the floor", hint
        and hint:find("covers a room from the tops of its walls", 1, true) and hint:find("on 'BP_Wall_C_9:S' or 'BuildingPiece_81:W'", 1, true)
        and not hint:find("BuildingPiece_79", 1, true), hint)
    hint = Bd.roof_hint(FB, RB, { N = "open", E = "open", S = "open", W = "open" })
    check("roof_hint: a floor with no walls says so", hint and hint:find("no wall on any edge yet", 1, true), hint)
    hint = Bd.roof_hint(FB, RB, { N = "Wall BP_Wall_C_9" }, true)
    check("roof_hint, placed: says it is on the floor inside the walls, not covering the room", hint
        and hint:find("^ That puts it on the floor inside the walls, so it doesn't cover the room%.") and hint:find("'BP_Wall_C_9:S'", 1, true), hint)
    check("roof_hint: by the game's placement profile when known (a medium roof yes, a table on a floor no)",
        Bd.roof_hint(FB, { origin = { 0, 0, 0.4 }, extent = { 0.75, 0.75, 0.4 } }, {}, true, "RoofProfile") ~= nil
        and Bd.roof_hint(FB, RB, {}, true, "FloorPropNonOverlapProfile") == nil)
    check("thin_axis: a medium wall (75 x 50 x 75 cm extent, live) is wall-like; a wide low table and a crate aren't; a large wall is",
        Bd.thin_axis({ origin = { 0, 0, 0.75 }, extent = { 0.75, 0.5, 0.75 } }) == 2 and Bd.thin_axis({ origin = { 0, 0, 0.5 }, extent = { 1.0, 0.5, 0.5 } }) == nil
        and Bd.thin_axis({ origin = { 0, 0, 0.4 }, extent = { 0.5, 0.4, 0.4 } }) == nil and Bd.thin_axis(WB) == 2)
    local MF = { origin = { 0, 0, -1.5 }, extent = { 0.75, 0.75, 1.5 } }
    local MW = { origin = { 0, 0, 0.75 }, extent = { 0.75, 0.5, 0.75 } }
    local mrep = Bd.flush_report({ position = { 139.1153, 1866.0096, -31.4401 }, yaw = 0, box = MF }, "N", MW,
        { position = { 139.1153, 1865.2596, -31.4401 }, yaw = 0 }, 0.06)
    check("medium wall on a medium foundation's N edge, where the game put it (live 20:5xZ) -> square", mrep and mrep.flush,
        mrep and string.format("%s %s %s", mrep.gap_m, mrep.offset_m, mrep.facing_off_deg))
    local sin = Bd.standing_in({ { id = "T", name = "Crafting Table", position = { 139.23, 1866.18, -31.43 } },
                                 { id = "F", name = "Medium Square Foundation", position = { 139.1153, 1866.0096, -31.4401 } },
                                 { id = "C", name = "Crate", position = { 145, 1866, -31.4 } } },
        { 139.1153, 1866.7596, -31.4401 }, MW, 0, { F = true })
    check("standing_in: the table on the medium foundation is where its S wall would go (live 20:5xZ); the far crate and the anchor aren't",
        #sin == 1 and sin[1].id == "T", #sin)
    -- a station placed freely: which floor it stands on, whose, and where on it (live 20:5xZ: the table in the
    -- middle of his medium foundation)
    local MFL = { id = "BuildingPiece_100", name = "Medium Square Foundation", piece = "DA_T1_Foundation_Medium", data = "MFD",
                  position = { 139.1153, 1866.0096, -31.4401 }, yaw = 0 }
    check("on_floor: the table at the foundation's middle is on it (0.2 m from its centre); a spot 2 m off isn't",
        math.abs((Bd.on_floor({ 139.23, 1866.18, -31.43 }, MFL, MF) or 9) - 0.2) < 0.01 and Bd.on_floor({ 141.2, 1866.0, -31.43 }, MFL, MF) == nil)
    do
        local bp1, pp1 = Wb.built_pieces, Wb.piece_profile
        Wb.built_pieces = function() return { MFL, { id = "T9", name = "Crafting Table", data = "TD", position = { 139.23, 1866.18, -31.43 } } } end
        Wb.piece_profile = function(_, d)
            if d == "MFD" then return { box = MF, profile = "FoundationProfile" } end
            return { box = { origin = { 0, 0, 0.5 }, extent = { 1.0, 0.5, 0.5 } }, profile = "FloorPropNonOverlapProfile" }
        end
        DEC = { mark_mine = function(_, rows) rows[1].mine = true end }
        local fl = Wb.floor_under(api, { 139.23, 1866.18, -31.43 }, "T9")
        check("floor_under: names his foundation, the distance from its centre and its size",
            fl and fl.id == "BuildingPiece_100" and fl.mine == true
            and fl.words == "It stands on your Medium Square Foundation (BuildingPiece_100), 0.2 m from its centre (the floor is 1.5 x 1.5 m).", fl and fl.words)
        DEC = { mark_mine = function() end }
        fl = Wb.floor_under(api, { 139.23, 1866.18, -31.43 }, "T9")
        check("floor_under: someone else's floor says so", fl and fl.mine == false and fl.words:find("on the Medium Square Foundation (BuildingPiece_100), not placed by you", 1, true), fl and fl.words)
        DEC = nil
        Wb.built_pieces, Wb.piece_profile = bp1, pp1
    end
    check("roof_hint: not for a small piece (a crate) or on a wall's own top",
        Bd.roof_hint(FB, { origin = { 0, 0, 0.4 }, extent = { 0.5, 0.4, 0.4 } }, {}) == nil and Bd.roof_hint(WB, RB, {}) == nil)
    attach_game({ snap = false, box = RB, built_at = { 10, 0, 0 }, edges = { N = "Wall BP_Wall_C_9", E = "open", S = "open", W = "open" } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:top" })
    da = r and r.data or {}
    check("attach: a roof that never lands on a foundation's top -> nothing placed, and the reply names the wall top to use",
        r and not r.ok and count(G.presses, "place") == 0 and tostring(da.detail):find("Nothing was placed. A roof or ceiling tile covers a room from the tops of its walls", 1, true)
        and tostring(da.detail):find("on 'BP_Wall_C_9:S'", 1, true), r and (tostring(r.reason) .. " " .. tostring(da.detail)))

    attach_game({ no_preview = true, box = RB, built_at = { 10, 0, 0 }, edges = { N = "Wall BP_Wall_C_9", E = "open", S = "open", W = "open" } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:top" })
    da = r and r.data or {}
    check("attach: a roof built on a foundation's top -> ok, and the reply says it's on the floor inside the walls, naming the wall top",
        r and r.ok and tostring(da.built):find("That puts it on the floor inside the walls, so it doesn't cover the room.", 1, true)
        and tostring(da.built):find("on 'BP_Wall_C_9:S'", 1, true) and tostring(da.fit):find("doesn't cover the room", 1, true),
        r and (tostring(r.reason) .. " " .. tostring(da.built or da.detail)))

    -- a roof on a wall's ':top' (live 05:57Z, a Hip Roof aimed at the wall's own top line: red 1.7 m off, nothing
    -- placed): it reaches over the side its floor is on, and the reply says so
    do
        local saved = { id = anchor.id, name = anchor.name, position = anchor.position, box = anchor.box, piece = anchor.piece }
        anchor.id, anchor.name, anchor.position, anchor.box, anchor.piece = "BP_Wall_C_9", "Wall", { 10, -1.5, 0 }, WB, "DA_T1_Wall_Large"
        attach_game({ no_preview = true, box = RB, built_at = { 10, 0, 3.4 },
                      others = { { id = "BP_Foundation_C_A", piece = "DA_T1_Foundation_Large", name = "Square Foundation", position = { 10, 0, 0 } } } })
        r = build({ piece = "campfire", on = "BP_Wall_C_9:top" })
        da = r and r.data or {}
        check("attach: a roof on a wall's top reaches over its floor's side (S here), and the reply says so",
            r and r.ok and da.side == "S" and tostring(da.built):find("the side the room is on", 1, true),
            r and (tostring(r.reason) .. " " .. tostring(da.side) .. " " .. tostring(da.built or da.detail)))
        attach_game({ no_preview = true, box = RB, built_at = { 10, -1.5, 3.4 } })
        r = build({ piece = "campfire", on = "BP_Wall_C_9:top" })
        check("attach: no floor by the wall -> its top, as asked", r and (r.data or {}).side == "top", r and tostring((r.data or {}).side))
        for k, v in pairs(saved) do anchor[k] = v end
    end

    attach_game({ snap = true, snap_at = { 13, 0, 0 }, built_at = { 13.3, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach: snapped, but the census shows it 0.3 m out -> ok (it was built) and says NOT flush with the gap",
        r and r.ok and da.flush == false and da.gap_m == 0.3 and tostring(da.built):find("NOT flush on the E side", 1, true)
        and tostring(da.built):find("0.30 m gap", 1, true), r and tostring(da.built))
    check("attach: a batch's fit is that whole NOT-flush sentence, decimals and all (live 20:5xZ it read 'It stands at')",
        tostring(da.fit):find("^It is NOT flush on the E side") and tostring(da.fit):find("0.30 m gap", 1, true), tostring(da.fit))

    attach_game({ snap = true, snap_at = { 13, 0, 0 }, built_at = { 13, 0, 0 },
                  others = { { id = "BP_Wall_C_9", name = "Wall", position = { 13, 0, 0.5 } } } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    check("attach: that side already has a piece -> blocked side_taken, naming it, no press", r and r.reason == "blocked" and r.data.why == "side_taken"
        and r.data.taken_by == "BP_Wall_C_9" and #G.presses == 0, r and r.reason)
    attach_game({ snap = true, snap_at = { 7, 0, 0 }, built_at = { 7, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A" })
    check("attach without a side: the free side nearest me (W, I'm west of it), flush", r and r.ok and r.data.side == "W" and r.data.flush == true,
        r and (tostring(r.reason) .. " " .. tostring(r.data.side) .. " " .. tostring(r.data.detail or r.data.built)))
    attach_game({})
    r = build({ piece = "campfire", on = "BP_Gone_C_1:E" })
    check("attach to an id I can't see: unknown_target, no press", r and r.reason == "unknown_target" and #G.presses == 0, r and r.reason)
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:up-ish" })
    check("attach with a side I don't know: invalid_args naming the sides", r and r.reason == "invalid_args" and tostring(r.data.detail):find("N, E, S, W or top", 1, true), r and r.reason)
    -- an instance-only piece (live: the foundation) has no preview actor: aim AT the flush spot, press once the
    -- cursor settled there green, then measure from the census (and say the snap itself wasn't seen)
    attach_game({ no_preview = true, built_at = { 13, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach, no preview actor: aimed at the flush spot, settled, pressed; flush from the census; says it couldn't watch the snap",
        r and r.ok and da.flush == true and da.snap_moved_m == 0 and count(G.presses, "place") == 1 and G.aimed and math.abs(G.aimed[1] - 13) < 1e-6
        and tostring(da.built):find("can't watch this piece's preview snap", 1, true), r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)))
    -- live 15:02Z: the cursor settles 0.6 m short and 0.2 m aside of the aim point -> the aim is corrected by the miss
    attach_game({ no_preview = true, built_at = { 13, 0, 0 } })
    Wb.mpc = function()
        if not G.aimed then return nil end
        return { index = 2, position = { G.aimed[1] - 0.6, G.aimed[2] + 0.2, -0.4 } }
    end
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach, biased cursor: the aim is nudged by the miss until the cursor sits on the flush spot, then pressed",
        r and r.ok and da.flush == true and count(G.presses, "place") == 1 and G.aimed and math.abs(G.aimed[1] - 13.6) < 1e-6
        and math.abs(G.aimed[2] + 0.2) < 1e-6, r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)) .. " aimed " .. (G.aimed and table.concat(G.aimed, ",") or "-"))
    -- a wall on the E edge: turned 90 (6 presses of 15) so it runs along the edge (live 15:26Z: unturned it stood
    -- across it), aimed at the edge midpoint, measured square from the census
    attach_game({ no_preview = true, box = WB, built_at = { 11.5, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("wall on an edge: 6 rotate presses, aimed just inside the edge on the top face, square from the census",
        r and r.ok and count(G.presses, "rotate") == 6 and da.flush == true and G.aimed and math.abs(G.aimed[1] - 11.2) < 1e-6
        and tostring(da.built):find("stands squarely on the E edge", 1, true), r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)))
    -- live 15:42Z: the cursor on the foundation's SIDE face (below its top) snapped a frame to the bottom edge, 3 m low:
    -- a wall is never pressed while the cursor isn't on the top face
    attach_game({ no_preview = true, box = WB, built_at = { 11.5, 0, 0 } })
    Wb.mpc = function()
        if not G.aimed then return nil end
        return { index = 2, position = { G.aimed[1], G.aimed[2], -0.6 } }
    end
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    check("wall: cursor below the anchor's top (its side face) -> never pressed", r and not r.ok and count(G.presses, "place") == 0,
        r and (tostring(r.reason) .. " " .. tostring(r.data and r.data.why)))
    -- live 15:42-15:46Z: the ghost keeps the last placement's rotation -> a ghost already at 90 needs no turn for the
    -- E edge, and the census yaw re-syncs the tracked value
    attach_game({ no_preview = true, box = WB, built_at = { 11.5, 0, 0 } })
    _G.DWBuild = { static = {}, ghost_yaw = 90 }
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    check("wall: the ghost already turned 90 (kept from the last piece) -> no rotate press; re-synced from the census",
        r and r.ok and count(G.presses, "rotate") == 0 and r.data.flush == true and _G.DWBuild.ghost_yaw == 90,
        r and (tostring(r.reason) .. " rot=" .. count(G.presses, "rotate") .. " gy=" .. tostring(_G.DWBuild and _G.DWBuild.ghost_yaw)))
    attach_game({ snap = true, snap_only = true, snap_at = { 13, 0, 0 }, built_at = { 13, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    check("attach: a snap-only piece IS pressed once the snap is seen (no longer preview_ambiguous)", r and r.ok and r.data.flush == true, r and (tostring(r.reason) .. " " .. tostring(r.data.why)))
    -- a ceiling tile off a wall's top (live profile: Square Tile 300 x 300 x 37.5 cm, its top at its origin): its
    -- edge on the wall's line, reaching toward the side, its top level with the wall's top, on the wall's 90 grid
    local TB = { origin = { 0, 0, -0.1875 }, extent = { 1.5, 1.5, 0.1875 } }
    local wall = { position = { 10, 0, 0 }, yaw = 90, box = WB }
    local cp, cax, cm = Bd.flush_spot(wall, "E", TB)
    check("ceiling off a wall (yaw 90) to the E: the cell centre 1.5 m E of the wall line, top level with the wall top",
        near(cp[1], 11.5) and near(cp[2], 0) and near(cp[3], 3.03) and near(cax[1], 1) and cm and cm.ceiling and cm.per == 90,
        table.concat(cp, ","))
    local cr = Bd.flush_report(wall, "E", TB, { position = { 11.5, 0, 3.03 }, yaw = 0 }, 0.06)
    check("ceiling report: a square tile turned 90 from the wall still lines up (90 degree grid)", cr.flush and cr.facing_off_deg == 0, cr.facing_off_deg)
    cr = Bd.flush_report(wall, "E", TB, { position = { 11.5, 0, 3.03 }, yaw = 45 }, 0.06)
    check("ceiling report: turned 45 -> not square", not cr.flush and math.abs(cr.facing_off_deg) == 45, cr.facing_off_deg)
    local saved = { id = anchor.id, name = anchor.name, position = anchor.position, yaw = anchor.yaw, box = anchor.box }
    anchor.name, anchor.position, anchor.yaw, anchor.box = "Wall", { 10, 0, 0 }, 90, WB
    attach_game({ no_preview = true, box = TB, built_at = { 11.5, 0, 3.03 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("ceiling on a wall: aimed at the wall face just below its top from the E, pressed, square from the census",
        r and r.ok and da.flush == true and count(G.presses, "place") == 1 and G.aimed and math.abs(G.aimed[1] - 10.1) < 1e-6
        and math.abs(G.aimed[3] - 2.83) < 1e-6 and tostring(da.built):find("sits squarely on top of the Wall (BP_Foundation_C_A), reaching E", 1, true),
        r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)) .. " aimed " .. (G.aimed and table.concat(G.aimed, ",") or "-"))
    attach_game({ no_preview = true, box = TB, built_at = { 11.8, 0, 3.03 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("ceiling 0.3 m out: built, and says the gap from the wall", r and r.ok and da.flush == false
        and tostring(da.built):find("0.30 m gap from the wall", 1, true), r and tostring(da.built))
    -- the helper follows the snapped spot: aimed at the wall face, the cursor jumps onto the cell centre -> a seen snap
    attach_game({ no_preview = true, box = TB, built_at = { 11.5, 0, 3.03 } })
    Wb.mpc = function()
        if not G.aimed then return nil end
        return { index = 2, position = { 11.5, 0, 3.03 } }
    end
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("ceiling: the cursor jumped from the wall face onto the flush spot -> pressed as a seen snap, says so",
        r and r.ok and da.flush == true and count(G.presses, "place") == 1 and tostring(da.built):find("jumped onto the flush spot", 1, true),
        r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)))
    -- live 17:03Z: the cursor settles on the wall's face 0.8 m under the aim -> the aim is lifted by the miss (like the
    -- xy nudge) and the next read lands on the target
    attach_game({ no_preview = true, box = TB, built_at = { 11.5, 0, 3.03 } })
    Wb.mpc = function()
        if not G.aimed then return nil end
        return { index = 2, position = { G.aimed[1], G.aimed[2], G.aimed[3] - 0.8 } }
    end
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("ceiling: cursor 0.8 m under the aim on the face -> aim lifted 0.8 m, then pressed, square",
        r and r.ok and da.flush == true and count(G.presses, "place") == 1 and G.aimed and math.abs(G.aimed[3] - 3.63) < 1e-6,
        r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)) .. " aimed z " .. (G.aimed and G.aimed[3] or "-"))
    -- a door into its frame: the reply says it sits IN the frame (live 18:57Z it said "on the in edge ... on its top")
    attach_game({ no_preview = true, box = WB, built_at = { 10, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:in" })
    da = r and r.data or {}
    check("door in its frame: built, 'sits squarely in the frame of the Wall', never 'on its top'",
        r and r.ok and da.flush == true and tostring(da.built):find("sits squarely in the frame of the Wall (BP_Foundation_C_A): in the opening", 1, true)
        and not tostring(da.built):find("on its top", 1, true), r and (tostring(r.reason) .. " " .. tostring(da.built or da.detail)))
    -- live 18:34Z: the cursor trembles 5-10 cm a read right on the target -> settled enough, pressed
    attach_game({ no_preview = true, box = TB, built_at = { 11.5, 0, 3.03 } })
    local flip = 1
    Wb.mpc = function()
        if not G.aimed then return nil end
        flip = -flip
        return { index = 2, position = { G.aimed[1] + 0.05 * flip, G.aimed[2], G.aimed[3] } }
    end
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("ceiling: a cursor trembling 10 cm a read on the target counts as settled, pressed, square",
        r and r.ok and da.flush == true and count(G.presses, "place") == 1, r and (tostring(r.reason) .. " " .. tostring(da.detail or da.built)))
    -- live 17:44Z: the walk to a ceiling's stand point went to the wall top's height, never arrived and kept steering
    -- the camera through the aim. The stand point is on the floor, and a walk still running is stopped first.
    attach_game({ no_preview = true, box = TB, built_at = { 11.5, 0, 3.03 } })
    G.pos = { 20, 5, 0.88 }
    local ms0, call0, stops = api.move_status, api.call, 0
    api.move_status = function() return { mode = "go_to" } end
    api.call = function(mod, fn, a, ...)
        if mod == "move" and fn == "stop" then stops = stops + 1; api.move_status = ms0 end
        return call0(mod, fn, a, ...)
    end
    local mv0 = #MOVES
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    api.move_status, api.call = ms0, call0
    local goal = MOVES[#MOVES]
    check("ceiling: walks to a spot on the floor (wall bottom + 0.88), stops that walk before the build screen, square",
        r and r.ok and #MOVES == mv0 + 1 and goal and math.abs(goal[3] - 0.88) < 1e-6 and stops >= 1,
        r and (tostring(r.reason) .. " goal " .. (goal and table.concat(goal, ",") or "-") .. " stops " .. stops))
    anchor.name, anchor.position, anchor.yaw, anchor.box = saved.name, saved.position, saved.yaw, saved.box
    -- speed: a wall in reach, the view clear, not in its way -> placed from where I stand (no walk); Luis placed 11
    -- walls from one spot
    attach_game({ no_preview = true, box = WB, built_at = { 11.5, 0, 0 } })
    Wb.camera = function() return { G.pos[1], G.pos[2], G.pos[3] + 0.8 } end
    G.pos = { 10.5, 1.5, 0.88 }
    local moves0 = #MOVES
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("stay: a wall 1.7 m away on my floor, view clear -> no walk, placed square, says it stayed",
        r and r.ok and #MOVES == moves0 and da.flush == true and da.stayed == true, r and (tostring(r.reason) .. " moves " .. (#MOVES - moves0)))
    attach_game({ no_preview = true, box = WB, built_at = { 11.5, 0, 0 } })
    Wb.camera = function() return { G.pos[1], G.pos[2], G.pos[3] + 0.8 } end
    G.pos = { 11.5, 0.5, 0.88 } -- standing on the edge line, where the wall goes
    moves0 = #MOVES
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    check("stay: standing where the wall goes -> walks off first", r and r.ok and #MOVES > moves0 and not r.data.stayed,
        r and (tostring(r.reason) .. " moves " .. (#MOVES - moves0)))
    -- a batch: two pieces in one go, the second on the first ("#1:E"); the build screen stays open between them
    local function batch_game(o)
        attach_game({ no_preview = true, others = o and o.others })
        local NEW = {}
        Wb.structures_near = function()
            local out = {}
            for _, x in ipairs(NEW) do out[#out + 1] = x end
            return out
        end
        local press1 = Wb.press
        Wb.press = function(x, act)
            local mode = G.mode
            local res = press1(x, act)
            if act == "place" and mode == "Placement" then
                local n = #NEW + 1
                NEW[n] = { id = "BP_NEW_" .. n, position = { 10 + 3 * n, 0, 0 }, yaw = 90 }
            end
            return res
        end
        Wb.actor_info = function(_, id)
            if id == anchor.id then return anchor end
            for _, x in ipairs(NEW) do
                if x.id == id then return { id = x.id, name = "Campfire", piece = "BUILDPIECE_Campfire", position = x.position, yaw = 0, box = FB } end
            end
        end
        CARRIED.ITEM_Resources_Stone = 12
    end
    batch_game()
    r = build({ pieces = { { piece = "campfire", on = "BP_Foundation_C_A:E" }, { piece = "campfire", on = "#1:E" } } }, 800)
    da = r and r.data or {}
    check("batch: 2 of 2 built, the second on the first; one menu press, one cancel at the end",
        r and r.ok and tostring(da.built):find("Built 2 of 2 pieces", 1, true) and count(G.presses, "place") == 2
        and count(G.presses, "menu") == 1 and count(G.presses, "cancel") == 1 and da.built_pieces and da.built_pieces[2]
        and da.built_pieces[2].structure == "BP_NEW_2" and da.built_pieces[2].attached_to == "BP_NEW_1",
        r and (tostring(r.reason) .. " " .. tostring(da.built or da.detail) .. " presses " .. table.concat(G.presses, ",")))
    batch_game({ others = { { id = "BP_X", name = "Wall", position = { 16, 0, 0.2 } } } })
    r = build({ pieces = { { piece = "campfire", on = "BP_Foundation_C_A:E" }, { piece = "campfire", on = "#1:E" } } }, 800)
    da = r and r.data or {}
    check("batch: the second's side is taken -> not ok, says what was built and where it stopped, build screen closed",
        r and not r.ok and r.reason == "blocked" and tostring(da.detail):find("Built 1 of 2 pieces", 1, true)
        and tostring(da.detail):find("#2 (campfire on #1:E) failed", 1, true) and tostring(da.detail):find("BP_X", 1, true)
        and da.failed_item == 2 and G.mode == "None", r and (tostring(r.reason) .. " " .. tostring(da.detail)))
    -- a piece that can't start (a name I don't know) fails alone: the one after it still goes up (rung 2 run
    -- 20261116-013406: "Roof" stopped the batch with three pieces untried)
    batch_game()
    r = build({ pieces = { { piece = "nosuchpiece", on = "BP_Foundation_C_A:N" }, { piece = "campfire", on = "BP_Foundation_C_A:E" } } }, 800)
    da = r and r.data or {}
    check("batch: an unknown piece fails alone, the next one is built",
        r and not r.ok and r.reason == "unknown_target" and tostring(da.detail):find("Built 1 of 2 pieces", 1, true)
        and tostring(da.detail):find("#1 (nosuchpiece on BP_Foundation_C_A:N) failed", 1, true) and da.built_pieces and #da.built_pieces == 1
        and G.mode == "None", r and (tostring(r.reason) .. " " .. tostring(da.detail)))
    local br = Bd.batch_result(api, { items = { { piece = "Door", on = "#2:in" } },
        results = { { ok = false, reason = "blocked", data = { detail = "x", why = "not_snapped", ghost_off_m = 3.63, preview_reads = { { off_m = 3.63 } } } } } }, nil, 9)
    check("batch: a failed piece's own preview reads and ghost offset come back with the batch (live 21:15Z: none did)",
        br and not br.ok and br.data.ghost_off_m == 3.63 and br.data.preview_reads and br.data.preview_reads[1].off_m == 3.63)
    r = build({ pieces = { { piece = "campfire", on = "#2:E" }, { piece = "campfire", on = "#1:E" } } })
    check("batch: each names the other -> invalid_args, nothing pressed", r and r.reason == "invalid_args", r and r.reason)
    r = build({ pieces = { { on = "BP_Foundation_C_A:E" } } })
    check("batch: an item without a piece -> invalid_args", r and r.reason == "invalid_args", r and r.reason)
    -- a 45° Roof off a wall top (Luis's census: BuildingPiece_42 at the cell centre (93.21, 1853.14), z -27.31, yaw 90,
    -- over the S wall at y 1854.64 whose top is -28.78): the cell centre, 1.5 m up, the eave toward the wall
    local RB = { origin = { 0, 0, 0 }, extent = { 1.687, 1.5, 1.687 } }
    local swall = { position = { 93.2113, 1854.6378, -31.8092 }, yaw = 0, box = WB }
    local rp, _, rm = Bd.flush_spot(swall, "N", RB)
    check("roof on a wall's top, reaching N: Luis's roof spot (cell centre, ~1.5 m over the wall top), facing yaw 90",
        math.abs(rp[1] - 93.2113) < 1e-6 and math.abs(rp[2] - 1853.1378) < 1e-6 and math.abs(rp[3] - (-27.3092)) < 0.06
        and rm.roof and rm.yaw == 90 and rm.per == 360, table.concat(rp, ",") .. " yaw " .. tostring(rm.yaw))
    local rr = Bd.flush_report(swall, "N", RB, { position = { 93.2113, 1853.1378, -27.3092 }, yaw = 90 }, 0.06)
    check("roof report: Luis's roof measures square", rr.flush, string.format("%s %s %s %s", rr.gap_m, rr.offset_m, rr.level_m, rr.facing_off_deg))
    rr = Bd.flush_report(swall, "N", RB, { position = { 93.2113, 1853.1378, -27.3092 }, yaw = 270 }, 0.06)
    check("roof report: the same spot sloping the wrong way (yaw 270) -> not square, turned 180", not rr.flush
        and math.abs(rr.facing_off_deg) == 180, rr.facing_off_deg)
    -- find_structure: a built piece by its structures id, for find_thing (live 18:57Z: his crate 13.7 m off was
    -- "I can't see that chest anywhere near me")
    local bp0 = Wb.built_pieces
    Wb.built_pieces = function() return { { id = "BP_BaseBuilding_Crate_C_7", name = "Crate", position = { 13.7, 0, 0 },
        actor = uobj("BP_BaseBuilding_Crate_C /Game/Maps/World.World:PersistentLevel.BP_BaseBuilding_Crate_C_7") },
        { id = "BuildingPiece_9", name = "Wall", position = { 3, 0, 0 } } } end
    G.pos = { 0, 0, 0.88 }
    local fs = Bd.find_structure(api, "BP_BaseBuilding_Crate_C_7")
    local fw = Bd.find_structure(api, "BuildingPiece_9")
    check("find_structure: the crate 13.7 m off with its class (actor_of finds it); a wall with no actor; unknown -> nil",
        fs and fs.class == "BP_BaseBuilding_Crate_C" and fs.distance == 13.7 and fs.category == "structures" and fw and fw.class == nil
        and fw.kind == "piece" and Bd.find_structure(api, "BP_Nope_1") == nil, fs and (tostring(fs.class) .. " " .. tostring(fs.distance)))
    -- the game re-created the crate's actor under a new name: its old name and its BuildingPiece id still find it
    Wb.built_pieces = function() return { { pid = 5, id = "BP_BaseBuilding_Crate_C_8", name = "Crate", position = { 13.7, 0, 0 },
        actor = uobj("BP_BaseBuilding_Crate_C /Game/Maps/World.World:PersistentLevel.BP_BaseBuilding_Crate_C_8") } } end
    _G.DWBuild.pid_of = _G.DWBuild.pid_of or {}
    _G.DWBuild.pid_of["BP_BaseBuilding_Crate_C_7"] = 5
    local fo = Bd.find_structure(api, "BP_BaseBuilding_Crate_C_7")
    local fp = Bd.find_structure(api, "BuildingPiece_5")
    check("find_structure: an older actor name of the same piece (live 19:40Z) and its BuildingPiece id find today's actor",
        fo and fo.id == "BP_BaseBuilding_Crate_C_8" and fo.was == "BP_BaseBuilding_Crate_C_7" and fo.class == "BP_BaseBuilding_Crate_C"
        and fp and fp.id == "BP_BaseBuilding_Crate_C_8", fo and (tostring(fo.id) .. " was " .. tostring(fo.was)))
    Wb.built_pieces = bp0
    -- the house perception: each foundation's edges (open / a wall on it / the next foundation) and its ceiling
    local ed = Bd.edges({
        { id = "F1", name = "Square Foundation", position = { 0, 0, 0 }, yaw = 0, box = FB },
        { id = "F2", name = "Square Foundation", position = { 0, 3, 0 }, yaw = 0, box = FB },
        { id = "W1", name = "Wall", position = { -1.5, 0, 0 }, yaw = 90, box = WB },
        { id = "W2", name = "Wall", position = { 0, 4.5, 0 }, yaw = 0, box = WB },
        { id = "T1", name = "Square Tile", position = { 0, 0, 3.03 }, yaw = 0, box = TB },
        { id = "W3", name = "Wall", position = { 1.5, 3, -3 }, yaw = 90, box = WB } }) -- 3 m low: not on F2's edge
    check("edges: F1 W wall, S = beside F2, N/E open, its ceiling the tile", ed.F1 and ed.F1.edges.W == "Wall W1"
        and ed.F1.edges.S == "beside: Square Foundation F2" and ed.F1.edges.N == "open" and ed.F1.edges.E == "open"
        and ed.F1.ceiling == "Square Tile T1", ed.F1 and (ed.F1.edges.W .. "|" .. ed.F1.edges.S .. "|" .. tostring(ed.F1.ceiling)))
    check("edges: F2 S wall, N beside F1, E open (a wall 3 m low isn't on it), no ceiling; walls get no edges",
        ed.F2 and ed.F2.edges.S == "Wall W2" and ed.F2.edges.N == "beside: Square Foundation F1" and ed.F2.edges.E == "open"
        and ed.F2.ceiling == nil and ed.W1 == nil and ed.T1 == nil, ed.F2 and (ed.F2.edges.S .. "|" .. ed.F2.edges.E))
    -- frames: a door in one (listed before its frame: the edge's wall is the taller piece), a frame with no door, a
    -- window frame (live 20:29Z: 4 door-frame walls and 1 door read as a closed house)
    local DB = { origin = { 0, 0, 1.1 }, extent = { 0.75, 0.1, 1.1 } }
    ed = Bd.edges({
        { id = "F3", name = "Square Foundation", position = { 20, 0, 0 }, yaw = 0, box = FB },
        { id = "DR", name = "Door", piece = "DA_T1_Door", position = { 20, -1.5, 0 }, yaw = 0, box = DB },
        { id = "D1", name = "WALL WITH DOOR FRAME", piece = "DA_T1_Wall_Large_Doorframe", position = { 20, -1.5, 0 }, yaw = 0, box = WB },
        { id = "D2", name = "WALL WITH DOOR FRAME", piece = "DA_T1_Wall_Large_Doorframe", position = { 20, 1.5, 0 }, yaw = 0, box = WB },
        { id = "WF", name = "WALL WITH WINDOW FRAME", piece = "DA_T1_Wall_Large_Windowframe", position = { 21.5, 0, 0 }, yaw = 90, box = WB },
        { id = "W9", name = "Wall", piece = "DA_T1_Wall_Large", position = { 18.5, 0, 0 }, yaw = 90, box = WB } })
    local f3 = ed.F3 or { edges = {}, inside = {} }
    check("edges: the frame is the edge's wall, the door is in it; a frame with no door is an open doorway; a window frame an opening; a plain wall nothing",
        f3.edges.N == "WALL WITH DOOR FRAME D1" and f3.inside.N == "Door DR" and f3.edges.S == "WALL WITH DOOR FRAME D2"
        and f3.inside.S == "an open doorway, no door in it" and f3.inside.E == "a window opening" and f3.edges.W == "Wall W9" and f3.inside.W == nil,
        tostring(f3.edges.N) .. "|" .. tostring(f3.inside.N) .. "|" .. tostring(f3.inside.S) .. "|" .. tostring(f3.inside.E))
end
-- the piece's own data decides snap-only before the preview actor (live: the preview read came back unreadable)
reset_game({ no_hook = true })
Wb.piece_profile = function() return { snap_only = false } end
Wb.snap_only = function() return nil end
r = build({ piece = "campfire" })
check("piece data says not snap-only: pressed although the preview's own read is unreadable", r and r.ok and count(G.presses, "place") == 1, r and (tostring(r.reason) .. " " .. tostring(r.data.why)))
reset_game({ no_hook = true })
Wb.preview_actor = function() return nil end
r = build({ piece = "campfire" }, 400)
check("no profile and no preview actor: waited, then treated as snap (never pressed blind), says where that came from",
    r and r.data.why == "preview_ambiguous" and r.data.snap_only_from == "no preview" and count(G.presses, "place") == 0, r and (tostring(r.reason) .. " " .. tostring(r.data.why)))

-- 9. every spot needs a foundation -> blocked, in the game's own words
reset_game({ state = function() return 3 end })
r = build({ piece = "campfire" })
check("all spots NeedsFoundation: blocked + the game's text", r and r.reason == "blocked" and r.data.detail:find("foundation"), r and r.data and r.data.detail)

-- 10. outside-only piece refused inside: the piece's own shelter text
reset_game({ state = function() return 11 end })
r = build({ piece = "campfire" })
check("ShelterCheckFailed: the piece's own text (Must Be Exposed)", r and r.data.detail:find("Must Be Exposed"), r and r.data and r.data.detail)

-- 10b. red everywhere and no exact state (the validity hooks never fire live): one press to hear the game's reason
reset_game({ state = function() return 1 end, no_hook = true, refuse = 1 })
r = build({ piece = "campfire" })
check("all red, no state: one press, the game's own reason in the detail",
    r and not r.ok and count(G.presses, "place") == 1 and r.data.game_says == "Blocked"
    and r.data.detail:find('the game said: "Blocked"', 1, true) and not r.data.detail:find("something in the way", 1, true), r and r.data and r.data.detail)
reset_game({ state = function() return 1 end, no_hook = true, no_spend = true })
r = build({ piece = "campfire" })
check("all red, the press gets no message: says so, still not placed",
    r and not r.ok and count(G.presses, "place") == 1 and r.data.detail:find("gave no message", 1, true), r and r.data and r.data.detail)

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
-- the lease is renewed while the build runs (live 2026-11-01: a 30 s walk to the spot ended "lease_expired")
ARB.reset()
reset_game()
do
    local walk_until, goal = T + 45, nil
    local ms0, call0 = api.move_status, api.call
    api.call = function(mod, fn, a)
        if mod == "move" and fn == "go_to" then goal = a; return { ok = true } end -- a long walk, not a teleport
        return call0(mod, fn, a)
    end
    api.move_status = function()
        if T < walk_until then return { mode = "go_to" } end
        if goal then G.pos = { goal[1], goal[2], goal[3] } end
        return { mode = "idle", result = { status = "arrived" } }
    end
    h = Bd.HANDLERS.build(nil, { piece = "campfire", near = "bench_1" }, { api = api, id = "b5" })
    a = h.pending
    r = nil
    for _ = 1, 600 do T = T + 0.2; ARB.status(); r = a:poll(); if r then break end end
    api.move_status, api.call = ms0, call0
    check("a 45 s walk to the spot: lease renewed every tick, the build finishes", r and r.ok and T >= walk_until,
        r and (tostring(r.reason) .. " " .. tostring(r.data and r.data.why)))
end
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

-- the piece census (live 2026-11-01): a built foundation has NO actor on the client (HISM instance); every piece is
-- in GlobalBuildingManager.BuildingPieces (TMap<ID, FBuildingPieceState>.ClientVisible)
do
    for k, v in pairs(saved) do Wb[k] = v end
    _G.DWBuild = nil
    table_.BuildingPieceDataIndex, campfire.BuildingPieceDataIndex = 27, 25 -- (the fakes all share 26)
    local function tmap(entries)
        return { ForEach = function(_, f) for k, v in pairs(entries) do f({ get = function() return k end }, { get = function() return v end }) end end }
    end
    local function cv(idx, x, y, z, yaw)
        return { ClientVisible = { BuildingPieceDataIndex = idx, Location = { X = x, Y = y, Z = z }, Yaw = yaw, bGhosted = false, StabilityValue = 100 } }
    end
    local gbm = uobj("GlobalBuildingManager /Game/L.L:PersistentLevel.GlobalBuildingManager_1",
        { BuildingPieces = tmap({ [59] = cv(27, 300, 0, 50, 0), [60] = cv(25, 500, 0, 0, 90), [61] = cv(27, 9000, 0, 0, 0) }) })
    local fire = uobj("BP_Campfire_C /Game/L.L:PersistentLevel.BP_Campfire_C_7", { BuildingPieceID = 60, bIsPreview = false,
        K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end })
    FindAllOf = function(cls)
        if cls == "GlobalBuildingManager" then return { gbm } end
        if cls == "BaseBuildingActor" then return { fire } end
        return {}
    end
    G = G or {}
    G.pos = { 0, 0, 0 }
    T = 2000
    local st = (Bd.state_extras(api) or {}).structures or {}
    check("piece census: an instance-only piece (no actor) listed by its piece id, named from buildables",
        st[1] and st[1].id == "BuildingPiece_59" and st[1].name == "Crafting Table" and st[1].piece == "BUILDPIECE_CraftingStation_Basic"
        and st[1].position[3] == 0.5, st[1] and (tostring(st[1].id) .. " " .. tostring(st[1].name)))
    check("piece census: a piece with an actor keeps the actor's id (= the interactable's); far pieces left out",
        st[2] and st[2].id == "BP_Campfire_C_7" and st[2].name == "Campfire" and st[2].yaw == 90 and #st == 2,
        st[2] and string.format("%s %s %s %d", tostring(st[2].id), tostring(st[2].name), tostring(st[2].yaw), #st))
    local nb = Wb.structures_near(api, "BUILDPIECE_CraftingStation_Basic", { 3, 0, 0 }, 3)
    check("structures_near: from the census, this piece only", #nb == 1 and nb[1].id == "BuildingPiece_59", #nb)
    local info = Wb.actor_info(api, "BuildingPiece_59")
    check("actor_info: an instance-only piece by its id; box from its data (nil: not loaded here)",
        info and info.position[1] == 3 and info.box == nil and info.piece == "BUILDPIECE_CraftingStation_Basic", info and info.id)
    FindAllOf = function() return {} end
    table_.BuildingPieceDataIndex, campfire.BuildingPieceDataIndex = 26, 26
end

-- blueprints (data/blueprints/*.json): Luis's house and his own verified small house as relative pieces
do
    local ids = Bd.blueprint_ids()
    check("blueprints: the index lists small_house and luis_house", table.concat(ids, ","):find("small_house", 1, true)
        and table.concat(ids, ","):find("luis_house", 1, true), table.concat(ids, ","))
    local sh = Bd.blueprint_load("small_house")
    local lh = Bd.blueprint_load("luis_house")
    check("blueprints: both load (11 and 29 pieces)", sh and #sh.pieces == 11 and lh and #lh.pieces == 29, sh and #sh.pieces)
    local none, why = Bd.blueprint_load("castle")
    check("blueprints: an unknown one says which exist", none == nil and why:find("small_house", 1, true), why)
    local it = Bd.blueprint_items(sh, { 10, 20, -31 }, nil)
    check("blueprint_items: first foundation at the spot, the rest by #k refs on their own sides, the door in its frame",
        it[1].at[1] == 10 and it[1].on == nil and it[2].on == "#1:S" and it[8].on == "#2:W" and it[9].on == "#8:in"
        and it[10].on == "#3:S" and it[11].on == "#7:N", it[2].on .. " " .. it[8].on .. " " .. it[9].on)
    local rt = Bd.blueprint_items(sh, "me", "S") -- door from W to S: every side turned 270 (W -> S)
    check("blueprint_items: facing S turns its W door to S (N->W, S->E, W->S), in/top untouched, 'me' = beside me",
        rt[1].near == "me" and rt[2].on == "#1:E" and rt[8].on == "#2:S" and rt[9].on == "#8:in" and rt[3].on == "#1:W",
        rt[2].on .. " " .. rt[8].on .. " " .. rt[3].on)
    -- the Luis house layout matches his census (pieces 15-45): corner hips from the outer walls toward the cell
    local li = Bd.blueprint_items(lh, { 0, 0, 0 }, nil)
    local by = {}
    for k, p in ipairs(lh.pieces) do by[p.key] = k end
    check("blueprint_items: Luis's NE hip roof goes on the NE window frame's W side, its door frame on the E middle",
        li[by.h_ne].on == "#" .. by.w_ne_e .. ":W" and li[by.w_e].piece == "DA_T1_Wall_Large_Doorframe" and li[by.w_e].on == "#" .. by.e .. ":E")
    -- materials first: a blueprint he can't pay for says what it needs and places nothing
    local b0 = Bd.HANDLERS.buildables
    Bd.HANDLERS.buildables = function(_, a)
        local cost = { DA_T1_Foundation_Large = 4, DA_T1_Wall_Large = 4, DA_T1_Wall_Large_Doorframe = 4, DA_T1_Door = 2, DA_T1_Roof_Large_Diagonal = 6 }
        local n = cost[a.about]
        return { ok = true, data = { pieces = n and { { id = a.about, name = a.about, cost = { { item = "ITEM_Resources_Wood_Ash", name = "Ash Logs", count = n } } } } or {} } }
    end
    reset_game({ no_hook = true })
    CARRIED.ITEM_Resources_Wood_Ash = 12
    local r = Bd.HANDLERS.build_blueprint(nil, { blueprint = "small_house" }, { api = api, id = "bp1" })
    check("build_blueprint: short of logs -> missing_materials with the whole cost (2x4 + 5x4 + 4 + 2 + 2x6 = 46), nothing pressed",
        r and r.ok == false and r.reason == "missing_materials" and tostring(r.data.detail):find("needs 46 Ash Logs (I have 12)", 1, true)
        and #G.presses == 0, r and tostring(r.data and r.data.detail))
    Bd.HANDLERS.buildables = function() return { ok = true, data = { pieces = {} } } end
    r = Bd.HANDLERS.build_blueprint(nil, { blueprint = "small_house" }, { api = api, id = "bp2" })
    check("build_blueprint: a piece not unlocked -> says which", r and r.ok == false and tostring(r.data.detail):find("isn't among the pieces I can build", 1, true))
    Bd.HANDLERS.buildables = b0
    check("build_blueprint: in the manifest, its description naming the blueprints", Bd.MANIFEST.build_blueprint
        and Bd.MANIFEST.build_blueprint.description:find("'luis_house'", 1, true) and Bd.MANIFEST.build_blueprint.llm == false)
    -- a blueprint batch goes on past a piece the game wouldn't take; what goes on it is not tried
    local bb = { items = { { piece = "F", key = "f1" }, { piece = "W", key = "w1", on = "#1:N" }, { piece = "R", key = "r1", on = "#2:S" }, { piece = "W", key = "w2", on = "#1:E" } },
                 results = { { ok = true, data = { structure = "BP_1", name = "F", fit = "It stands at [0, 0, 0]." } },
                             { ok = false, reason = "blocked", data = { detail = "the preview was red there" } }, nil,
                             { ok = true, data = { structure = "BP_4", name = "W", fit = "It stands squarely on the E edge." } } }, keep_going = true }
    local br = Bd.batch_result(api, bb, nil, 30)
    check("batch (blueprint): built 2 of 4, #2 failed with why, #3 (on the failed one) not tried",
        br and not br.ok and tostring(br.data.detail):find("Built 2 of 4", 1, true) and tostring(br.data.detail):find("#2 (w1 on #1:N) failed: the preview was red there", 1, true)
        and tostring(br.data.detail):find("Not tried (they go on a piece that failed or the run stopped): #3", 1, true), br and br.data.detail)
end
check("names: Firepit shares 'fire' with Campfire", Bd.share_run("Campfire", "Firepit") and not Bd.share_run("Crate", "Wall"))
-- a blueprint piece the game refused gets one more try once the others are up
do
    local b = { items = { { at = { 0, 0, 0 } }, { at = { 1, 0, 0 } }, { at = { 9, 0, 0 } } }, done = { true }, failed_once = { nil, true }, results = {} }
    check("batch retry: a first try (the far one) before the second try", Bd.batch_pick(api, b) == 3, Bd.batch_pick(api, b))
    b.done[3] = true
    check("batch retry: then the refused one again", Bd.batch_pick(api, b) == 2, Bd.batch_pick(api, b))
end
-- shelter-only pieces: a covered spot (my house first), a covered place to stand, never open sky
do
    -- a roof over x 10..14, y -2..2 (my house, its floor at z 0); open sky elsewhere
    local function env(floors, here)
        return { ground_at = function(x, y, z) return 0 end,
                 covered = function(p) return p[1] >= 10 and p[1] <= 14 and math.abs(p[2]) <= 2 end,
                 mine_floors = floors, reach_m = 25, standoff_m = 1.5, here = here or { 0, 0, 0 } }
    end
    local plan = Bd.shelter_plan(env({ { 12, 0, -0.2 } }), { 2, 0, 0 })
    check("shelter: open sky round the asked spot -> my covered floor 10 m off", plan and plan.center[1] == 12 and plan.on_mine, plan and plan.center[1])
    check("shelter: stands under the same roof, 2 m off", plan and plan.stand_at and plan.stand_at[1] >= 10 and plan.stand_at[1] <= 14,
        plan and plan.stand_at and plan.stand_at[1])
    check("shelter: no roof in reach -> nothing", Bd.shelter_plan(env({}), { 2, 0, 0 }) == nil)
    check("shelter: a far house (30 m) is out of reach", Bd.shelter_plan(env({ { 12, 0, 0 } }), { -20, 0, 0 }) == nil)
    local p2 = Bd.shelter_plan(env({}), { 11, 1, 0 })
    check("shelter: asked under a roof that isn't mine -> there, not on_mine", p2 and p2.center[1] == 11 and not p2.on_mine, p2 and p2.center[1])
end
print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
