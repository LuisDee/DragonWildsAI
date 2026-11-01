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
            local out = { { id = anchor.id, name = anchor.name, position = anchor.position } }
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

    attach_game({ snap = false, built_at = { 13, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach: green but never snapped (ghost stays where aimed) -> never pressed, says so", r and not r.ok and da.why == "not_snapped"
        and count(G.presses, "place") == 0 and tostring(da.detail):find("couldn't get the Campfire to sit flush on the E side of the Square Foundation", 1, true)
        and tostring(da.detail):find("Nothing was placed", 1, true) and type(da.ghost_off_m) == "number", r and (tostring(r.reason) .. " " .. tostring(da.detail)))

    attach_game({ snap = true, snap_at = { 13, 0, 0 }, built_at = { 13.3, 0, 0 } })
    r = build({ piece = "campfire", on = "BP_Foundation_C_A:E" })
    da = r and r.data or {}
    check("attach: snapped, but the census shows it 0.3 m out -> ok (it was built) and says NOT flush with the gap",
        r and r.ok and da.flush == false and da.gap_m == 0.3 and tostring(da.built):find("NOT flush on the E side", 1, true)
        and tostring(da.built):find("0.30 m gap", 1, true), r and tostring(da.built))

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

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
