-- Offline tests for client_mod/scripts/crafting.lua (R2.19): the planner over the REAL catalog
-- (mod/body/recipe_data.lua) and whole craft jobs against a fake world (fake api, move, inventory,
-- sense; the REAL skills.lua episode + detector/face helpers; the engine layer crafting.W replaced).
-- Run:  lua client_mod/tests/test_crafting.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local C = assert(loadfile(root .. "/client_mod/scripts/crafting.lua"))()
local SK = assert(loadfile(root .. "/client_mod/scripts/skills.lua"))()
local GP = assert(loadfile(root .. "/client_mod/scripts/gather_profiles.lua"))()
local REAL = assert(loadfile(root .. "/mod/body/recipe_data.lua"))()
C.set_data(REAL)
-- the record of what he left in stations (kept on disk in the live client): a file of this run, world "test"
local LOADS_DIR = ((arg and arg[1]) or os.getenv("TEMP") or "."):gsub("\\", "/")
local LOADS_STAMP = tostring(os.time())
C.loads_path = function(world) return LOADS_DIR .. "/my_loads_" .. tostring(world) .. "_" .. LOADS_STAMP .. ".json" end
C.W.world_id = function() return "test" end

local function path_of(id) return C.index().path_of[id] end
local function has_step(steps, what, key, val)
    for _, s in ipairs(steps) do if s["do"] == what and (key == nil or s[key] == val) then return s end end
end

-- ------------------------------------------------------------------ fake world
local T, F
local NULL = setmetatable({}, { __tostring = function() return "null" end })
local function inv_counts()
    local c = {}
    for _, r in ipairs(F.inv) do if r.count > 0 then c[r.item] = (c[r.item] or 0) + r.count end end
    return c
end
local function add_inv(item, n)
    if F.reflex_takes == item then -- the stay-fed reflex uses one the moment it lands (inventory.lua keeps the ledger)
        F.reflex_takes, n = nil, n - 1
        local L = rawget(_G, "DW_REFLEX_USES") or {}
        L[#L + 1] = { item = item, name = "Iron Bar", kind = "drink", ts = os.time() + 1 }
        _G.DW_REFLEX_USES = L
    end
    for _, r in ipairs(F.inv) do if r.item == item then r.count = r.count + n; return end end
    F.inv[#F.inv + 1] = { item = item, name = C.item_name_of(item), count = n, slot = #F.inv + 10, slot_type = "InventoryItems" }
end
local function d2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
local function contents(rows)
    local by = {}
    for _, r in ipairs(rows) do by[r.item] = (by[r.item] or 0) + r.count end
    local slots = 0
    return { rows = rows, by_item = by, slots = 2 }
end

local MOVE = { gen=0 }
local ARB = { owner=nil, seq=0 }
function ARB.request(_,spec) ARB.seq=ARB.seq+1;ARB.owner={token=ARB.seq,state="owner",name=spec.name};return {ok=true,token=ARB.seq} end
function ARB.owns_move(token) return ARB.owner~=nil and ARB.owner.token==token end
function ARB.holds(token) return ARB.owns_move(token) end
function ARB.renew(token) return ARB.owns_move(token) end
function ARB.release(_,token) if ARB.owns_move(token) then ARB.owner=nil;return {ok=true} end return {ok=false} end
function MOVE.go_to(log,pos,opts)
    MOVE.gen=MOVE.gen+1; MOVE.token=opts and opts.owner_token
    F.goal={pos[1],pos[2],pos[3]};F.moves=(F.moves or 0)+1;return {ok=true,gen=MOVE.gen}
end
function MOVE.status() if F.goal then F.pos,F.goal=F.goal,nil end;return {mode="idle",result={status="arrived"}} end
function MOVE.stop() F.goal=nil;return {ok=true} end
function MOVE.child_status(_,gen,token) return {ok=gen==MOVE.gen and token==MOVE.token and ARB.owns_move(token),mode=F.goal and "go_to" or "idle"} end
function MOVE.stop_owned(_,gen,token)
    if gen~=MOVE.gen or token~=MOVE.token or not ARB.owns_move(token) then return {ok=false} end
    F.goal=nil;return {ok=true}
end

local INV = {}
-- the game's own per-item total (GetNumItemsByData); F.native overrides it (items the slot rows miss)
function INV.count_item(path)
    local id = C.index().id_of[path]
    if F.native and F.native[id] ~= nil then return F.native[id] or nil end
    return id and (inv_counts()[id] or 0) or nil
end
function INV.interact_target()
    if F.ui_blocks_prompt and F.ui then return { none = true } end -- a station menu open: the game offers no pickup
    local best, bd
    local function consider(id, name, item, pos, reach)
        local d = d2(F.pos, pos)
        if d <= reach and (not best or d < bd) then best, bd = { actor = id, name = name, item = item }, d end
    end
    for _, s in ipairs(F.stations) do consider(s.id, s.name, nil, s.position, F.station_reach or 3.0) end
    if not F.no_item_prompt then -- F.no_item_prompt: the game offers no pickup for items (a full bag, live 00:31Z)
        for _, it in ipairs(F.items) do consider(it.id, it.name, it.item, it.position, F.item_reach or 1.5) end
    end
    -- F.station_behind: the game's camera ray / character trace (live 2026-10-26, Campfire): a small item
    -- loses to a station that lies BEHIND it along his line of sight (or when he stands on the item)
    if F.station_behind and best and best.item then
        for _, it in ipairs(F.items) do
            if it.id == best.actor then
                for _, s in ipairs(F.stations) do
                    local v1 = { it.position[1] - F.pos[1], it.position[2] - F.pos[2] }
                    local v2 = { s.position[1] - it.position[1], s.position[2] - it.position[2] }
                    local l1, l2 = math.sqrt(v1[1] ^ 2 + v1[2] ^ 2), math.sqrt(v2[1] ^ 2 + v2[2] ^ 2)
                    local behind = l1 < 0.5 or (l2 > 0 and (v1[1] * v2[1] + v1[2] * v2[2]) / (l1 * l2) > 0.5)
                    if behind and d2(F.pos, s.position) <= 3.0 then return { actor = s.id, name = s.name } end
                end
            end
        end
    end
    return best or { none = true }
end
function INV.press_interact()
    F.presses = (F.presses or 0) + 1
    local det = INV.interact_target()
    for _, s in ipairs(F.stations) do
        if det.actor == s.id and not F.ui_broken then F.ui = { id = s.id, kind = s.kind_short } end
    end
    for i, it in ipairs(F.items) do
        if det.actor == it.id then table.remove(F.items, i); add_inv(it.item, it.count or 1); break end
    end
    return { ok = true }
end
function INV.list() return { ok = true, data = { hotbar = F.inv, bag = {} } } end

-- input.lua's claim/release (the stray-screen guard, BUGS B-stuck-focused-ui): records what the craft claims
INPUTF = { owners = {}, claims = 0 }
function INPUTF.claim(kind, owner) INPUTF.owners[kind] = owner; INPUTF.claims = INPUTF.claims + 1 end
function INPUTF.release(kind) INPUTF.owners[kind] = nil end
local SENSE = { local_pawn = function() return { AddMovementInput = function() end } end, local_pc = function() return {} end }

local api = {
    module = function(n)
        if n == "skills" then return SK elseif n == "move" then return MOVE elseif n == "inventory" then return INV
        elseif n == "sense" then return SENSE elseif n == "arbiter" then return ARB elseif n == "gather_profiles" then return GP
        elseif n == "input" then return INPUTF elseif n == "build" then return BUILD_STUB end
    end,
    call = function(mod, fn, ...)
        local m = ({ move = MOVE, inventory = INV })[mod]
        local r = m[fn](nil, ...)
        return r
    end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
    reason_code = function(r) return type(r) == "string" and r:match("^[a-z_]+$") and r or "body_error" end,
    now = function() return T end,
    my_position = function() return F.pos end,
    census_things = function()
        local out = {}
        for _, s in ipairs(F.stations) do
            out[#out + 1] = { id = s.id, class = s.class, category = "interactables", kind = s.kind, name = s.name, position = s.position,
                              distance = d2(F.pos, s.position), actions = { "interact" } }
        end
        for _, it in ipairs(F.items) do
            out[#out + 1] = { id = it.id, class = "BP_RuntimeSpawnedWorldItem_ProcessingStation_C", category = "items", kind = "item",
                              item = it.item, name = it.name, count = it.count, position = it.position, distance = d2(F.pos, it.position),
                              actions = { "interact" } }
        end
        return out
    end,
    find_thing = function(id) for _, it in ipairs(F.items) do if it.id == id then return it end end end,
    actor_of = function(t)
        for _, s in ipairs(F.stations) do if s.id == t.id then return s end end
        for _, it in ipairs(F.items) do if it.id == t.id then return it end end
    end,
    counts = function() return inv_counts() end,
    aim_at = function() return true end,
    move_status = function() return MOVE.status() end,
    reflex_owns_pawn = function() return false end,
    object = function(t) return t or {} end,
    log = function() end,
    null = NULL,
}

-- the engine layer
local function furnace_tick(s)
    if not s.running then return end
    if T >= s.started + (s.proc_s or 2) then
        local rec = s.recipe and REAL.recipes[s.recipe]
        if rec and not s.never then
            for _, c in ipairs(rec.inputs) do
                local id = C.asset(c[1])
                for _, r in ipairs(s.res) do if r.item == id then r.count = r.count - c[2] end end
            end
            for _, o in ipairs((s.burn and rec.alt) or rec.outputs) do -- s.burn: the cook fails (the recipe's alt)
                local id = C.asset(o[1])
                if s.store then s.out[#s.out + 1] = { slot = #s.out, item = id, name = C.item_name_of(id), count = o[2] }
                else
                    F.nid = (F.nid or 0) + 1
                    F.items[#F.items + 1] = { id = "out_" .. F.nid, item = id, name = C.item_name_of(id), count = o[2],
                                              position = { s.position[1] + 1, s.position[2], s.position[3] } }
                end
            end
            local j = 1
            while j <= #s.res do if s.res[j].count <= 0 then table.remove(s.res, j) else j = j + 1 end end
        end
        s.running = false
    end
end
local function recipe_from_contents(s)
    local by = {}
    for _, r in ipairs(s.res) do by[r.item] = (by[r.item] or 0) + r.count end
    if (by.ITEM_Resources_CopperOre or 0) >= 3 and (by.ITEM_Resources_TinOre or 0) >= 3 then return "RECIPE_Process_BronzeBar" end
    if (by.ITEM_Resources_IronOre or 0) >= 3 and not by.ITEM_Resources_TinOre then return "RECIPE_Process_IronBar" end
    if (by.ITEM_Resources_Meat_Farm or 0) >= 1 then return "RECIPE_Consumable_Steak_From_Farm" end
    return nil
end

C.W.unlocked = function() if F.unlocked == false then return nil end; local n = 0; for _ in pairs(F.unlocked) do n = n + 1 end; return F.unlocked, n end
C.W.station_state = function(_, actor, kind)
    if kind ~= "processing" then return { kind = kind } end
    furnace_tick(actor)
    local s = actor
    s.recipe = recipe_from_contents(s) or (s.running and s.recipe) or nil
    return { kind = kind, running = s.running == true, store_output = s.store, recipe = s.recipe, resources = contents(s.res),
             fuel = contents(s.fuel), output = contents(s.out), _res = s.res, _fuel = s.fuel, _out = s.out }
end
C.W.open_station = function(_, kind) return F.ui and F.ui.id or nil end
C.W.send_craft = function(_, rid, count)
    F.sent = { rid = rid, count = count }
    local st = _G.DWCraft
    st.seq = st.seq + 1
    local code = F.result_code or 0
    st.results[#st.results + 1] = { seq = st.seq, result = code, recipe = rid, recipe_path = REAL.recipes[rid].path, count = count }
    if code == 0 then
        local r = REAL.recipes[rid]
        for _, c in ipairs(r.inputs) do add_inv(C.asset(c[1]), -c[2] * count) end
        for _, o in ipairs(r.outputs) do add_inv(C.asset(o[1]), o[2] * count) end
    end
    return true
end
C.W.close = function() F.closed = (F.closed or 0) + 1; F.ui = nil; return true end
C.W.move_into = function(_, row, amount, to, target)
    F.drags = (F.drags or 0) + 1
    for _, r in ipairs(F.inv) do if r.item == row.item then r.count = r.count - amount end end
    for _, r in ipairs(target) do if r.item == row.item then r.count = r.count + amount; return true end end
    target[#target + 1] = { slot = to, item = row.item, name = row.name, count = amount }
    return true
end
C.W.take_from = function(_, slot, source)
    for i, r in ipairs(source) do if r.slot == slot then add_inv(r.item, r.count); table.remove(source, i); break end end
    F.takes = (F.takes or 0) + 1
    return true
end
C.W.toggle = function() F.toggles = (F.toggles or 0) + 1; for _, s in ipairs(F.stations) do if F.ui and s.id == F.ui.id then s.running = true; s.started = T end end; return true end
C.W.arm_result_hook = function() return true end

local function station(sid, id, pos, extra)
    local st = REAL.stations[sid]
    local s = { id = id, class = st.classes[1], kind = st.kind == "processing" and "processing_station" or "crafting_station",
                kind_short = st.kind, name = st.name, position = pos, res = {}, fuel = {}, out = {} }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local function reset(o)
    o = o or {}
    T = 1000
    if not o.keep_loads then os.remove(C.loads_path("test")); _G.DWCraftKept = nil end
    ARB.owner=nil
    _G.DWArbiter=ARB
    _G.DWCraft, _G.DW_PAUSE = { results = {}, seq = 0 }, nil
    F = { pos = { 0, 0, 0 }, inv = {}, items = o.items or {}, stations = o.stations or {}, unlocked = (o.unlocked == nil) and {} or o.unlocked }
    for item, n in pairs(o.have or {}) do add_inv(item, n) end
    F.result_code = o.result_code
    F.ui_broken = o.ui_broken
end

local function run(args, n, dt)
    local h = C.HANDLERS.craft(nil, args, { api = api, id = "t1" })
    if not h.pending then return h end
    local a = h.pending
    a.started = T
    for _ = 1, n or 400 do
        T = T + (dt or 0.25)
        local r = a.poll(a)
        if r then return r end
    end
    return { ok = false, reason = "test_timeout" }
end
local function U(ids) local s = {}; for _, i in ipairs(ids) do s[i] = true end; return s end
local function near(sid, d) return { [sid] = { id = sid .. "_1", station = sid, distance = d or 5 } } end

-- ------------------------------------------------------------------ planner (pure, real catalog)
do
    local ctx = { have = {}, unlocked = U({ "RECIPE_Pickaxe_Stone" }), near = near("CraftingTable"), gather_for = C.W.gather_for(api) }
    local t = C.plan_tree({ item = "ITEM_Pickaxe_Stone" }, 1, ctx)
    check("tree: stone pickaxe root recipe", t and t.root.recipe == "RECIPE_Pickaxe_Stone", t and t.root.recipe)
    check("tree: craft_after (inputs first)", t.root.status == "craft_after", t.root.status)
    check("tree: gather stone step", has_step(t.steps, "gather", "item", "ITEM_Resources_Stone") ~= nil)
    check("tree: gather ash step", has_step(t.steps, "gather", "item", "ITEM_Resources_Wood_Ash") ~= nil)
    local cs = has_step(t.steps, "craft", "recipe", "RECIPE_Pickaxe_Stone")
    check("tree: craft step last + station", cs and t.steps[#t.steps] == cs and cs.station == "CraftingTable")
    -- with the inputs carried the root is ready
    ctx.have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }
    t = C.plan_tree({ item = "ITEM_Pickaxe_Stone" }, 1, ctx)
    check("tree: ready when carried", t.ready and t.root.status == "craft", t.root.status)
    -- the shared pool: 2 pickaxes need 12 ash, 6 carried -> gather 6 more
    t = C.plan_tree({ item = "ITEM_Pickaxe_Stone" }, 2, ctx)
    local g = has_step(t.steps, "gather", "item", "ITEM_Resources_Wood_Ash")
    check("tree: pool counts carried once", g and g.count == 6, g and g.count)
end
do -- a gatherable short of everything: gather it, the vendor buy (short of its currency) only as an alternative
    local ctx = { have = {}, unlocked = U({ "RECIPE_Process_Thread_Linen_From_Flax", "DA_Recipe_Vendor_UmS_Buy_Plant_Flax" }),
                  near = near("Spinning Wheel"), gather_for = C.W.gather_for(api) }
    local t = C.plan_tree({ item = "ITEM_Resources_Thread_Coarse" }, 1, ctx)
    local g = has_step(t.steps, "gather", "item", "ITEM_Resources_Flax")
    local domri = has_step(t.steps, "craft", "recipe", "DA_Recipe_Vendor_UmS_Buy_Plant_Flax")
    check("tree: flax is gathered, not bought for chits he lacks", g ~= nil and domri == nil, g and g.resource)
    local fl
    local function walk(n) if n.item == "ITEM_Resources_Flax" then fl = n end; for _, c in ipairs(n.inputs or {}) do walk(c) end end
    walk(t.root)
    local alt = false
    for _, a in ipairs(fl and fl.alternatives or {}) do if a.recipe == "DA_Recipe_Vendor_UmS_Buy_Plant_Flax" then alt = true end end
    check("tree: the vendor buy stays listed as an alternative", alt, fl and #(fl.alternatives or {}))
end
do -- alternatives listed; locked recipes carry their unlock text with station names
    local ctx = { have = {}, unlocked = U({ "RECIPE_Process_BronzeBar" }), near = near("Furnace"), gather_for = C.W.gather_for(api) }
    local t = C.plan_tree({ item = "ITEM_Resources_BronzeBar" }, 2, ctx)
    check("tree: bronze bar expands the unlocked ore recipe", t.root.recipe == "RECIPE_Process_BronzeBar", t.root.recipe)
    check("tree: bronze alternatives listed", t.root.alternatives and #t.root.alternatives >= 2, t.root.alternatives and #t.root.alternatives)
    check("tree: 2 bars = 1 craft", t.root.crafts == 1, t.root.crafts)
    local cands = C.candidates("ITEM_Resources_IronBar", 1, { have = {}, unlocked = {}, near = {} })
    check("candidates: iron bar has every recipe", #cands >= 2, #cands)
    local a
    for _, c in ipairs(cands) do if c.recipe == "RECIPE_Process_IronBar" then a = c end end
    check("locked: status + unlock text names the Furnace", a.status == "not_unlocked" and tostring(a.unlock):find("Furnace", 1, true) ~= nil, tostring(a.unlock))
end
do -- "used a Tannery: not yet" beside a Tannery: using it (the craft opens it) is the unlock, so it is makeable (rung 4)
    local disc = function(items) return function() return { items = items, actors = {} } end end
    local base = { have = { ITEM_Resources_Animal_Hide = 3 }, unlocked = {}, near = near("Tannery") }
    local a = C.assess("RECIPE_Process_Leather_From_Hide", 1, setmetatable({ discovered = disc({ ITEM_Resources_Animal_Hide = true }) }, { __index = base }))
    check("unlock on use: hide picked up + Tannery near -> ready", a.status == "ready" and a.unlock_on_use == true, a.status)
    a = C.assess("RECIPE_Process_Leather_From_Hide", 1, setmetatable({ discovered = disc({}) }, { __index = base }))
    check("unlock on use: hide never picked up -> not_unlocked", a.status == "not_unlocked", a.status)
    a = C.assess("RECIPE_Process_Leather_From_Hide", 1, { have = base.have, unlocked = {}, near = {}, discovered = disc({ ITEM_Resources_Animal_Hide = true }) })
    check("unlock on use: no Tannery near -> not_unlocked", a.status == "not_unlocked", a.status)
end
do -- a craft short of several things names each with what it takes and what he has (chain sitting of 2026-11-17, run
   -- 090028: "I need 8 Stone for that and I have 4 (and 1 more thing missing)" left the Ash Logs for a second try)
    local ctx = { have = { ITEM_Resources_Stone = 4, ITEM_Resources_Wood_Ash = 4 }, unlocked = { RECIPE_Weapon_Club_Stone = true },
        near = near("CraftingTable") }
    local a = C.assess("RECIPE_Weapon_Club_Stone", 1, ctx)
    check("missing input: every missing thing is named with need and have", a.status == "missing_input"
        and tostring(a.detail):find("8 Stone", 1, true) ~= nil and tostring(a.detail):find("6 Ash Logs", 1, true) ~= nil
        and select(2, tostring(a.detail):gsub("I have 4", "")) == 2 and not tostring(a.detail):find("more thing", 1, true),
        a.status .. ": " .. tostring(a.detail))
    ctx.have.ITEM_Resources_Wood_Ash = 6
    a = C.assess("RECIPE_Weapon_Club_Stone", 1, ctx)
    check("missing input: one missing thing reads as before", a.detail == "I need 8 Stone for that and I have 4", tostring(a.detail))
end
do -- held-out: an item absent from every fixture above resolves from the catalog by display name
    -- every word he said is a word of the name (live 2026-11-01 17:10Z: "Stone Axe" read unknown, then 24 axes)
    check("resolve: words -> Stone Logging Axe", C.resolve_item("Stone Axe") == "ITEM_Logging_Axe_Stone")
    check("resolve: words -> Wooden Spade", C.resolve_item("wooden spade") == "ITEM_Spade_T1_Wood")
    check("resolve: one word still ambiguous", C.resolve_item("axe") == nil)
    local id = C.resolve_item("stone dagger")
    check("resolve by display name (held-out)", id == "ITEM_Weapon_Dagger_Stone" or (id and id:find("Dagger")), id)
    local _, hits = C.resolve_item("Torc")
    check("resolve: ambiguous substring gives candidates", type(hits) == "table" and #hits > 1)
    local ctx = { have = { ITEM_Resources_Wood_Ash = 1, ITEM_Resources_Hide_Coarse = 5 }, unlocked = U({ "RECIPE_Torch" }), near = near("CraftingTable") }
    local cr = C.craftable(ctx)
    local found = false
    for _, x in ipairs(cr) do if x.recipe == "RECIPE_Torch" then found = true end end
    local r = REAL.recipes.RECIPE_Torch
    local fur = C.asset(r.inputs[2][1])
    ctx.have[fur] = 1
    cr = C.craftable(ctx)
    for _, x in ipairs(cr) do if x.recipe == "RECIPE_Torch" then found = true end end
    check("craftable now lists the torch", found)
end
do -- cycle + depth guards on a synthetic catalog
    local A, B = "/G/ITEM_A.ITEM_A", "/G/ITEM_B.ITEM_B"
    C.set_data({ stations = { Bench = { kind = "crafting", name = "Bench", classes = { "BP_Bench_C" } } },
                 items = { [A] = { id = "ITEM_A", name = "A" }, [B] = { id = "ITEM_B", name = "B" } },
                 recipes = { R_A = { inputs = { { B, 1 } }, outputs = { { A, 1 } }, stations = { "Bench" } },
                             R_B = { inputs = { { A, 1 } }, outputs = { { B, 1 } }, stations = { "Bench" } } } })
    local t = C.plan_tree({ item = "ITEM_A" }, 1, { have = {}, unlocked = U({ "R_A", "R_B" }), near = near("Bench") })
    -- A's one recipe takes B, which is only made from A: no path, so A is to be obtained and the loop is shown as such
    local alt = (t.root.alternatives or {})[1] or {}
    check("cycle guard: a loop is no path", t.root.status == "obtain" and t.root.recipe == nil and #t.steps == 1
          and t.steps[1]["do"] == "obtain", t.root.status)
    check("cycle guard: the loop listed as cycle", alt.recipe == "R_A" and alt.status == "cycle"
          and tostring(alt.detail):find("only made from A", 1, true) ~= nil, tostring(alt.status) .. " " .. tostring(alt.detail))
    check("cycle reported missing", #t.missing == 1)
    -- a recipe that takes its own output
    C.set_data({ stations = { Bench = { kind = "crafting", name = "Bench", classes = { "BP_Bench_C" } } },
                 items = { [A] = { id = "ITEM_A", name = "A" } },
                 recipes = { R_A = { inputs = { { A, 2 } }, outputs = { { A, 3 } }, stations = { "Bench" } } } })
    t = C.plan_tree({ item = "ITEM_A" }, 1, { have = {}, unlocked = U({ "R_A" }), near = near("Bench") })
    alt = (t.root.alternatives or {})[1] or {}
    check("cycle guard: takes itself", t.root.status == "obtain" and alt.status == "cycle"
          and tostring(alt.detail):find("takes A itself", 1, true) ~= nil, tostring(alt.detail))
    -- carried, the input is no loop: the recipe is a path
    t = C.plan_tree({ item = "ITEM_A" }, 1, { have = { ITEM_A = 2 }, unlocked = U({ "R_A" }), near = near("Bench") })
    check("cycle guard: carried input is a path", t.root.recipe == "R_A", t.root.status)
    C.set_data(REAL)
end
do -- the logged Bronze Pickaxe plan (logs/brain-live-20261117-231925-27552, 23:19Z, nothing bronze unlocked): Bronze
   -- Bar's main path was Bronze Leaf, which is only made from Bronze Bar, and the steps crafted 50 Bronze Leaf first
    local ctx = { have = {}, unlocked = {}, near = near("CraftingTable"), gather_for = C.W.gather_for(api) }
    local t = C.plan_tree({ item = "ITEM_Pickaxe_Bronze" }, 1, ctx)
    local bar
    for _, c in ipairs(t.root.inputs or {}) do if c.item == "ITEM_Resources_BronzeBar" then bar = c end end
    check("loop: Bronze Bar is not made from Bronze Leaf", bar and bar.recipe ~= "RECIPE_Process_Bar_Bronze_From_Leaf", bar and bar.recipe)
    check("loop: Bronze Bar from ore (gatherable inputs before salvage piles)", bar and bar.recipe == "RECIPE_Process_BronzeBar", bar and bar.recipe)
    check("loop: no step crafts Bronze Leaf", has_step(t.steps, "craft", "recipe", "RECIPE_Process_Bronze_Leaf_From_Bar") == nil)
    local leaf
    for _, a in ipairs(bar and bar.alternatives or {}) do if a.recipe == "RECIPE_Process_Bar_Bronze_From_Leaf" then leaf = a end end
    check("loop: the leaf recipe is listed as a cycle", leaf and leaf.status == "cycle"
          and tostring(leaf.detail):find("Bronze Leaf, which is only made from Bronze Bar", 1, true) ~= nil, leaf and leaf.detail)
    local gathers = 0
    for _, st in ipairs(t.steps) do if st["do"] == "gather" and tostring(st.name):find("Ore", 1, true) then gathers = gathers + 1 end end
    check("loop: copper and tin ore gathered", gathers == 2, gathers)
    -- Bronze Leaf itself is still planned (its bar from ore, not from leaf)
    t = C.plan_tree({ item = "ITEM_Resources_Agility_Bronze_Leaf" }, 1, ctx)
    check("loop: Bronze Leaf goal: its bar from ore", t.root.recipe == "RECIPE_Process_Bronze_Leaf_From_Bar"
          and (t.root.inputs[1] or {}).recipe == "RECIPE_Process_BronzeBar", (t.root.inputs[1] or {}).recipe)
end
do -- fuel choice (pure)
    local p = C.plan("RECIPE_Process_IronBar", 1, "Furnace")
    local f, why, d = C.choose_fuel(p, nil, { ITEM_Fuel_Resources_Charcoal = 2, ITEM_Fuel_Resources_Fuel_Pellet = 1 })
    check("fuel: two kinds carried -> ambiguous", f == nil and why == "ambiguous_target" and #d.fuels == 2, why)
    f = C.choose_fuel(p, "Charcoal", { ITEM_Fuel_Resources_Charcoal = 2, ITEM_Fuel_Resources_Fuel_Pellet = 1 })
    check("fuel: arg picks", f and f.item == "ITEM_Fuel_Resources_Charcoal" and f.source == "mine")
    f = C.choose_fuel(p, nil, {}, { ITEM_Fuel_Resources_Charcoal = 3 })
    check("fuel: station's own fuel used", f and f.source == "station")
    local fake = { kind = "processing", inputs = { { item = "ITEM_Resources_Wood_Oak", count = 4 } },
                   fuels = { { item = "ITEM_Resources_Wood_Oak", name = "Oak Logs", count = 1 } } }
    f, why, d = C.choose_fuel(fake, nil, { ITEM_Resources_Wood_Oak = 4 })
    check("fuel: never burns a recipe input", f == nil and why == "missing_input" and tostring(d.detail):find("won't burn"), d and d.detail)
    f = C.choose_fuel(fake, nil, { ITEM_Resources_Wood_Oak = 5 })
    check("fuel: spare beyond the inputs is fine", f and f.count == 1)
end
check("results: unknown code -> craft_failed", select(1, C.result_failure(9, "x")) == "craft_failed" and select(2, C.result_failure(9, "x")):find("result 9"))
for code = 1, 7 do check("results: code " .. code .. " mapped", C.RESULTS[code] ~= nil) end

-- ------------------------------------------------------------------ bench crafts
local TABLE = function() return station("CraftingTable", "bench_1", { 10, 0, 0 }) end
do
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    local r = run({ item = "Stone Pickaxe", count = 1 })
    check("bench: ok", r.ok, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("bench: recipe_chosen", r.data and r.data.recipe_chosen == "RECIPE_Pickaxe_Stone")
    check("bench: sent via UI with count 1", F.sent and F.sent.count == 1)
    check("bench: output in inventory", inv_counts().ITEM_Pickaxe_Stone == 1)
    check("bench: UI closed", F.closed == 1, F.closed)
    check("bench: station returned", r.data and r.data.station_id == "bench_1")
end
-- live 2026-10-26: a sapling next to the Campfire won the game's focus from the first standing spot ->
-- stand on another side of the station; the detector must name the STATION before the press
do
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }),
            items = { { id = "BP_BM_Sapling_Ash_01_C_1", name = "Ash Sapling", position = { 8.0, 0, 0 } } } })
    local r = run({ item = "Stone Pickaxe", count = 1 })
    check("sapling in front: another side, then crafted", r.ok and F.sent and F.sent.count == 1, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("sapling in front: never pressed while the sapling had the focus", #F.items == 1 and F.presses == 1, F.presses)
    -- every side blocked: a truthful reason naming the blocker in words (no raw class), and the sides tried
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    local det0 = INV.interact_target
    INV.interact_target = function() return { actor = "BP_BM_Sapling_Ash_01_C_1", name = nil } end
    r = run({ item = "Stone Pickaxe", count = 1 }, 800)
    INV.interact_target = det0
    check("every side blocked: not_interactable, the sides tried, blocker in words", r.reason == "not_interactable" and r.data.sides_tried == 6
        and r.data.detail:find("BM Sapling Ash") and not r.data.detail:find("BP_", 1, true) and (F.presses or 0) == 0, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
end
-- the REAL W.close: the altar's own panel (EWidgetType 36) is closed too when it is up; a plain bench closes only 6
do
    local C2 = assert(loadfile(root .. "/client_mod/scripts/crafting.lua"))()
    local hidden = {}
    local ui = { IsValid = function() return true end, GetFullName = function() return "CraftingUIAPI /Engine/Transient.CraftingUIAPI_1" end,
                 HideCraftingUI = function(_, t) hidden[#hidden + 1] = t end }
    local panel_up = true
    local panel = { IsValid = function() return true end, GetFullName = function() return "WBP_Runecrafting_MainPanel_C /Engine/Transient.P_1" end,
                    IsInViewport = function() return panel_up end }
    local Ureal = assert(loadfile(root .. "/mod/body/util.lua"))()
    local Uf = setmetatable({ find_all = function(cls) if cls == "CraftingUIAPI" then return { ui } elseif cls == "RunecraftingMainPanel" then return { panel } end return {} end },
                            { __index = Ureal })
    local api = { module = function(n) if n == "sense" then return { U = Uf, local_pc = function() return nil end } end end }
    C2.W.close(api, "crafting")
    check("close: altar panel up -> types 6 and 36 hidden", #hidden == 2 and hidden[1] == 6 and hidden[2] == 36, table.concat(hidden, ","))
    hidden, panel_up = {}, false
    C2.W.close(api, "crafting")
    check("close: plain bench -> only 6", #hidden == 1 and hidden[1] == 6, table.concat(hidden, ","))
    -- BUGS B-stuck-focused-ui: a processing station (Campfire) is closed with the game's InputManagerUIAPI close
    -- (input.close_screens) for the station panels + coupled Inventory; HideCraftingUI(15) was a live no-op
    local asked, logged = nil, {}
    local left = {}
    local IN = { close_screens = function(types) asked = types; return { "Processing" }, left end }
    local api2 = { log = function(m) logged[#logged + 1] = m end,
                   module = function(n) if n == "sense" then return { U = Uf, local_pc = function() return nil end } elseif n == "input" then return IN end end }
    hidden = {}
    local okc = C2.W.close(api2, "processing")
    check("close: processing -> no HideCraftingUI, CloseWidgetIfOpen for 15/6/36/11", okc == true and #hidden == 0 and asked
        and table.concat(asked, ",") == "15,6,36,11" and logged[1] and logged[1]:find("Processing", 1, true), table.concat(asked or {}, ","))
    left = { "Inventory" }
    check("close: a panel still open -> false (truthful)", C2.W.close(api2, "processing") == false)
    left, hidden = {}, {}
    check("close: bench -> HideCraftingUI(6) then the input close", C2.W.close(api2, "crafting") == true and hidden[1] == 6)
end

-- Runecrafting (M3): the Rune Altar is a crafting station (CraftingStation component, prompt Craft); its recipes are
-- RuneRecipeData (1 Rune Essence -> 5 runes). The same bench path drives it: open, SelectRecipe + SendCraftRequest.
do
    reset({ stations = { station("RuneAltar", "altar_1", { 8, 0, 0 }) }, have = { ITEM_Rune_Essence = 3 },
            unlocked = U({ "RECIPE_Process_Altar_Air_Rune" }) })
    local r = run({ item = "Air Rune", count = 5 })
    check("altar: ok", r.ok, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("altar: the altar recipe chosen", r.data and r.data.recipe_chosen == "RECIPE_Process_Altar_Air_Rune", r.data and r.data.recipe_chosen)
    check("altar: runes in the bag", (inv_counts().ITEM_Rune_Air or 0) >= 5, inv_counts().ITEM_Rune_Air)
    check("altar: its screen closed", (F.closed or 0) >= 1, F.closed)
end
do
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }), result_code = 2 })
    local r = run({ item = "Stone Pickaxe" })
    check("bench: bag full -> inventory_full + speech", r.reason == "inventory_full" and tostring(r.data.detail):find("bag is full"), tostring(r.reason))
    check("bench: UI closed on failure", F.closed == 1)
end
do
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }), result_code = 9 })
    local r = run({ item = "Stone Pickaxe" })
    check("bench: unknown verdict -> craft_failed", r.reason == "craft_failed" and tostring(r.data.detail):find("result 9"), tostring(r.reason))
    check("bench: UI closed on craft_failed", F.closed == 1)
end
do
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    local r = run({ item = "Stone Pickaxe" })
    check("bench: missing -> missing_materials + list", r.reason == "missing_materials" and r.data.missing and r.data.missing[1].item == "ITEM_Resources_Stone", tostring(r.reason))
    check("bench: no walk when it can't work", (F.moves or 0) == 0)
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = { RECIPE_Torch = true } })
    r = run({ item = "Stone Pickaxe" })
    check("bench: locked -> not_unlocked", r.reason == "not_unlocked", tostring(r.reason))
    reset({ stations = {}, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    r = run({ item = "Stone Pickaxe" })
    check("bench: no station -> nothing_in_range + names it", r.reason == "nothing_in_range" and tostring(r.data.detail):find("Crafting Table"), tostring(r.data.detail))
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }), ui_broken = true })
    r = run({ item = "Stone Pickaxe" })
    check("bench: menu never opens -> verification_failed", r.reason == "verification_failed" and F.presses == 2, r.reason .. " presses " .. tostring(F.presses))
    check("bench: nothing sent without the menu", F.sent == nil)
    reset({ stations = { TABLE() }, have = {}, unlocked = false })
    r = run({ item = "Stone Pickaxe" })
    check("bench: unreadable unlocks -> state_unavailable", r.reason == "state_unavailable", tostring(r.reason))
end
do -- pause
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    _G.DW_PAUSE = true
    local r = C.HANDLERS.craft(nil, { item = "Stone Pickaxe" }, { api = api })
    check("pause: refused", r.reason == "companion_down")
    _G.DW_PAUSE = nil
    local h = C.HANDLERS.craft(nil, { item = "Stone Pickaxe" }, { api = api })
    local a = h.pending
    _G.DW_PAUSE = true
    for _ = 1, 10 do T = T + 1; check("pause: no progress", a.poll(a) == nil) end
    check("pause: nothing moved", (F.moves or 0) == 0)
    _G.DW_PAUSE = nil
end

-- ------------------------------------------------------------------ processing (furnace)
local function FURNACE(extra) return station("Furnace", "furnace_1", { 8, 3, 0 }, extra) end
do -- ambiguous recipe (two viable) -> candidates; one viable -> recipe_chosen + alternatives
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_BronzeBar", "RECIPE_Process_Bar_Bronze_From_Salvage_01" }),
            have = { ITEM_Resources_CopperOre = 3, ITEM_Resources_TinOre = 3, ITEM_Resources_Salvage_Bronze = 9, ITEM_Fuel_Resources_Charcoal = 1 } })
    local salv = C.asset(REAL.recipes.RECIPE_Process_Bar_Bronze_From_Salvage_01.inputs[1][1])
    F.inv = {}; add_inv("ITEM_Resources_CopperOre", 3); add_inv("ITEM_Resources_TinOre", 3); add_inv(salv, 9); add_inv("ITEM_Fuel_Resources_Charcoal", 1)
    local r = run({ item = "Bronze Bar" })
    check("proc: ambiguous recipe -> candidates", r.reason == "ambiguous_target" and r.data.candidates and #r.data.candidates == 2, tostring(r.reason))
    check("proc: ambiguous -> no movement", (F.moves or 0) == 0)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_BronzeBar", "RECIPE_Process_Bar_Bronze_From_Salvage_01" }),
            have = { ITEM_Resources_CopperOre = 3, ITEM_Resources_TinOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.items[#F.items + 1] = { id = "pre_1", item = "ITEM_Resources_BronzeBar", name = "Bronze Bar", count = 1, position = { 8, 4.3, 0 } }
    r = run({ item = "Bronze Bar", count = 2 })
    check("proc: one viable -> ok", r.ok, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("proc: recipe_chosen + alternatives", r.data.recipe_chosen == "RECIPE_Process_BronzeBar" and #r.data.alternatives >= 1)
    check("proc: collected only the 2 new bars", inv_counts().ITEM_Resources_BronzeBar == 2, inv_counts().ITEM_Resources_BronzeBar)
    local pre = false
    for _, it in ipairs(F.items) do if it.id == "pre_1" then pre = true end end
    check("proc: pre-existing bar left alone", pre)
    check("proc: fuel_used reported (mine)", r.data.fuel_used and r.data.fuel_used.source == "mine")
    check("proc: started via the UI button once", F.toggles == 1)
    check("proc: UI closed", F.closed == 1)
    check("proc: the open station screen was claimed, and released at the end", INPUTF.claims >= 1 and INPUTF.owners.screen == nil)
    check("proc: inputs + fuel dragged (3 moves)", F.drags == 3, F.drags)
end
do -- a nearer station whose slots hold someone else's things is passed over for a free one (rung 3: Luis's
   -- Spinning Wheel holds his fur in its only slot); the result says which one he used and why
    local full = FURNACE()
    full.res = { { slot = 0, item = "ITEM_Resources_Flax", name = "Flax", count = 2 },
                 { slot = 1, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Animal Fur", count = 2 } }
    local far = station("Furnace", "furnace_2", { 20, 3, 0 })
    reset({ stations = { full, far }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    check("free station: ok at the far one", r.ok and r.data.station_id == "furnace_2",
          tostring(r.reason) .. " " .. tostring((r.data or {}).station_id) .. " " .. tostring((r.data or {}).detail))
    check("free station: the full one untouched", #full.res == 2 and full.res[1].count == 2 and full.res[2].count == 2)
    check("free station: says why", tostring((r.data or {}).why_this_station):find("Coarse Animal Fur", 1, true) ~= nil,
          tostring((r.data or {}).why_this_station))
end
do -- a nearer station that fails the game's shelter check is passed over, the reason with both checks' numbers
   -- (2026-11-20 L3: a roofed wheel on an open edge, "needs more surrounding shelter")
    _G.DWCraftLoads = {}
    local near = FURNACE()
    local far = station("Furnace", "furnace_2", { 20, 3, 0 })
    reset({ stations = { near, far }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local w0 = C.W.shelter
    C.W.shelter = function(_, _, pos)
        if pos and pos[1] < 10 then
            return { rule = "shelter_only", roof = "yes", roof_hits = 1, roof_n = 1, side_hits = 4, side_n = 16, side_pct = 25,
                     need_pct = 38, open = { "S" }, sides_ok = false, covered = true, sheltered = false }
        end
        return { rule = "shelter_only", roof = "yes", roof_hits = 1, roof_n = 1, side_hits = 9, side_n = 16, side_pct = 56,
                 need_pct = 38, open = {}, sides_ok = true, covered = true, sheltered = true }
    end
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    C.W.shelter = w0
    check("shelter pass-over: ok at the sheltered one", r.ok and r.data.station_id == "furnace_2",
          tostring(r.reason) .. " " .. tostring((r.data or {}).station_id))
    local why = tostring((r.data or {}).why_this_station)
    check("shelter pass-over: says which check failed, its % vs needed, the open side", why:find("too few building pieces", 1, true)
          and why:find("25 %", 1, true) and why:find("needs 38 %", 1, true) and why:find("open toward S", 1, true), why)
end
do -- ...and the same when he names the KIND of station, not one station (fresh chains 20261116-085113 / 091005:
   -- craft {station "Campfire"} took the nearest campfire, which held an earlier character's Dirty Water, and
   -- answered station_busy with a free campfire in range)
    _G.DWCraftLoads = {}
    local full = FURNACE()
    full.res = { { slot = 0, item = "ITEM_Resources_IronOre", name = "Iron Ore", count = 2 } }
    local far = station("Furnace", "furnace_2", { 20, 3, 0 })
    reset({ stations = { full, far }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local r = run({ recipe = "RECIPE_Process_IronBar", station = "Furnace" })
    check("kind named: ok at the free one", r.ok and r.data.station_id == "furnace_2",
          tostring(r.reason) .. " " .. tostring((r.data or {}).station_id) .. " " .. tostring((r.data or {}).detail))
    check("kind named: the other one untouched", #full.res == 1 and full.res[1].count == 2)
    check("kind named: says why", tostring((r.data or {}).why_this_station):find("Iron Ore", 1, true) ~= nil,
          tostring((r.data or {}).why_this_station))
end
do -- someone else's inputs in the only station: never added to, started or taken (Luis's rule; live 18:22Z the
   -- model aimed a fur craft at Luis's Spinning Wheel holding his 2 fur). His own leftovers (ledger) are fine.
    _G.DWCraftLoads = {}
    local theirs = FURNACE()
    theirs.res = { { slot = 0, item = "ITEM_Resources_IronOre", name = "Iron Ore", count = 2 } }
    reset({ stations = { theirs }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local r = run({ recipe = "RECIPE_Process_IronBar", station = "furnace_1" })
    check("theirs: station_busy", r.reason == "station_busy", tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("theirs: says whose", tostring((r.data or {}).detail):find("someone else left", 1, true) ~= nil, tostring((r.data or {}).detail))
    check("theirs: nothing moved, not started", (F.drags or 0) == 0 and (F.toggles or 0) == 0 and theirs.res[1].count == 2)
    _G.DWCraftLoads = { furnace_1 = T }
    reset({ stations = { theirs }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    theirs.res = { { slot = 0, item = "ITEM_Resources_IronOre", name = "Iron Ore", count = 2 } }
    r = run({ recipe = "RECIPE_Process_IronBar", station = "furnace_1" })
    check("own leftovers: not refused as someone else's", r.reason ~= "station_busy" or not tostring((r.data or {}).detail):find("someone else", 1, true),
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    _G.DWCraftLoads = {}
end
do -- the recipe he named is locked, another for the same item is ready: the failure says so (live 18:24Z)
    reset({ stations = { station("Spinning Wheel", "wheel_1", { 4, 0, 0 }) },
            unlocked = U({ "RECIPE_Process_Thread_Linen_From_Flax" }),
            have = { ITEM_Resources_Flax = 2, ITEM_Resources_Coarse_Animal_Fur = 24 } })
    local r = run({ recipe = "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur", count = 8 })
    check("ready instead: not_unlocked", r.reason == "not_unlocked", tostring(r.reason))
    check("ready instead: names the Flax recipe", r.data and r.data.ready_instead
          and r.data.ready_instead.recipe == "RECIPE_Process_Thread_Linen_From_Flax"
          and tostring(r.data.detail):find("from 1 Flax", 1, true) ~= nil, tostring((r.data or {}).detail))
end
do -- burnt food (live 2026-11-01 17:07Z, rung 3 cook): the Campfire dropped Burnt Steak; he waited for Steak,
   -- timed out "made 0 of 2" and could not say why. The recipe's alt output ends the wait and is reported
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }, { burn = true }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local r = run({ item = "Steak" })
    check("burnt: craft_failed (not a timeout)", r.reason == "craft_failed", tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("burnt: the detail names the burnt item", tostring((r.data or {}).detail):find("Burnt Steak", 1, true) ~= nil,
          tostring((r.data or {}).detail))
    check("burnt: picked up", inv_counts().ITEM_Consumable_Farm_Steak_Burnt == 1, inv_counts().ITEM_Consumable_Farm_Steak_Burnt)
    check("burnt: failed_output listed", r.data and r.data.failed_output and r.data.failed_output[1].count == 1)
end
do -- input: what a station makes from a carried item, the way a player puts raw meat on a fire (rung 3 gate
   -- 2026-11-01 19:03Z / 20:03Z: he read recipes first to learn the output's name and stood 6-7 s in silence)
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 2, ITEM_Resources_Wood_Ash = 2 } })
    local r = run({ input = "raw farm meat" })
    check("input: cooked what the meat makes, all of it", r.ok and (r.data or {}).crafts == 2 and (inv_counts().ITEM_Consumable_Farm_Steak or 0) >= 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail) .. " " .. tostring(inv_counts().ITEM_Consumable_Farm_Steak))
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) }, unlocked = U({}), have = { ITEM_Resources_Wood_Ash = 2 } })
    local r2 = run({ input = "Ash Logs" })
    check("input: an item no recipe takes says so", r2.ok == false and r2.reason ~= nil, tostring(r2.reason) .. " " .. tostring((r2.data or {}).detail))
end
do -- less of the input in his bag at the load than when the craft began (Ratcatcher run 20261116-071227: he set out
   -- to boil 2 Dirty Water, a rat fight came first and his thirst reflex drank one; the craft loaded 1, failed "ran
   -- out while loading" and left it on the fire): he cooks what went in and says what was short
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 2, ITEM_Resources_Wood_Ash = 2 } })
    local open, ate = C.W.open_station, false
    C.W.open_station = function(...) if not ate then ate = true; add_inv("ITEM_Resources_Meat_Farm", -1) end; return open(...) end
    local r = run({ input = "raw farm meat", count = 2 }); C.W.open_station = open
    check("short load: cooks what went in", r.ok and (inv_counts().ITEM_Consumable_Farm_Steak or 0) == 1 and #F.stations[1].res == 0,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("short load: says what was short", r.ok and r.data.partial == true and r.data.short and r.data.short[1].loaded == 1
          and tostring(r.data.detail):find("Only 1 .- went in", 1) ~= nil, tostring((r.data or {}).detail))
end
do -- the station's menu closed by something else between the load and the start (Ratcatcher runs 20261116-184351 and
   -- 20261116-201124: a rat came at him as the meat and the wood went in, the fight reflex pressed back four times to
   -- reach gameplay, and the resumed craft pressed the start button of a menu that was no longer there: "I loaded the
   -- Campfire but it won't start"): he opens it again and starts it
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local r = run({ input = "raw farm meat", count = 1 })
    local plain = F.presses -- the presses of a cook nothing cuts across
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local move, reopens, shut = C.W.move_into, C.cfg.reopens, false
    C.W.move_into = function(...) local ok = move(...); if not shut then shut = true; F.ui = nil end; return ok end
    r = run({ input = "raw farm meat", count = 1 }); C.W.move_into = move
    check("menu closed before the start: opened again (one more press) and started", r.ok
          and (inv_counts().ITEM_Consumable_Farm_Steak or 0) == 1 and F.presses == plain + 1 and F.toggles == 1,
          tostring(r.reason) .. " presses=" .. tostring(F.presses) .. " of " .. tostring(plain) .. " " .. tostring((r.data or {}).detail))
    -- ...and one that keeps closing is said as that, not as a fire that won't start
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    C.W.move_into = function(...) local ok = move(...); F.ui = nil; return ok end
    C.cfg.reopens = 1
    r = run({ input = "raw farm meat", count = 1 }); C.W.move_into = move
    check("menu keeps closing: said so, the count told", not r.ok and r.reason == "verification_failed"
          and tostring((r.data or {}).detail):find("menu keeps closing", 1, true) ~= nil and r.data.menu_reopened == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    C.cfg.reopens = reopens
end
do -- what he left in a station is still his in a new session (chain 20261116-204431: both fires at the windmill held
   -- what earlier trials of his own had left, 1 Dirty Water and 2 Raw Rat Meat; his record of his loads had died
   -- with those client processes, so they were "someone else's" and he would not cook)
    local fire = station("Campfire", "fire_1", { 8, 3, 0 })
    local function relaunch(id) -- new actor ids, the in-process ledgers gone, the file read afresh
        _G.DWCraftLoads, _G.DWCraftLoaded, _G.DWCraftKept = {}, {}, nil
        fire.id = id
        reset({ keep_loads = true, stations = { fire }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
                have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
        fire.fuel, fire.out, fire.running = {}, {}, false
    end
    reset({ stations = { fire }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local move, reopens = C.W.move_into, C.cfg.reopens
    C.W.move_into = function(...) local ok = move(...); F.ui = nil; return ok end
    C.cfg.reopens = 1
    local r = run({ input = "raw farm meat", count = 1 }); C.W.move_into = move; C.cfg.reopens = reopens
    check("kept loads: a craft that failed left his meat on the fire", not r.ok and #fire.res == 1
          and fire.res[1].item == "ITEM_Resources_Meat_Farm", tostring(r.reason) .. " res=" .. #fire.res)
    relaunch("fire_7")
    r = run({ input = "raw farm meat", count = 1 })
    check("kept loads: in a new session what he left is still his, and he cooks there", r.ok
          and (inv_counts().ITEM_Consumable_Farm_Steak or 0) >= 1, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    -- the file itself: his 2 Flax on that fire (a recipe that doesn't use them takes them out first)
    local function seed(n, world, at)
        local f = assert(io.open(C.loads_path(world or "test"), "wb"))
        f:write('{"v":1,"world":"' .. (world or "test") .. '","stations":[{"class":"' .. fire.class .. '","at":[' .. (at or "8,3,0")
                .. '],"items":{"ITEM_Resources_Flax":{"n":' .. n .. ',"t":' .. os.time() .. '}}}]}')
        f:close()
    end
    local function flax(n, more)
        fire.res = { { slot = 0, item = "ITEM_Resources_Flax", name = "Flax", count = n }, more }
    end
    seed(2); relaunch("fire_8"); flax(2)
    r = run({ item = "Steak", station = "fire_8" })
    check("kept loads: his leftover of another recipe comes out first, then he cooks", r.ok and inv_counts().ITEM_Resources_Flax == 2
          and r.data.took_out and #r.data.took_out == 1, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    -- ...and anything added since is someone else's: never his by the place alone
    seed(2); relaunch("fire_9"); flax(3)
    r = run({ item = "Steak", station = "fire_9" })
    check("kept loads: more of it than he left is someone else's", r.reason == "station_busy" and fire.res[1].count == 3
          and tostring((r.data or {}).detail):find("someone else left", 1, true) ~= nil, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    seed(2); relaunch("fire_10"); flax(2, { slot = 1, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Animal Fur", count = 1 })
    r = run({ item = "Steak", station = "fire_10" })
    check("kept loads: an item he never put there makes the lot someone else's", r.reason == "station_busy" and #fire.res == 2,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    local keep = C.cfg.loads_keep_s
    C.cfg.loads_keep_s = 0
    seed(2); relaunch("fire_11"); flax(2)
    r = run({ item = "Steak", station = "fire_11" })
    C.cfg.loads_keep_s = keep
    check("kept loads: a record past its time counts for nothing", r.reason == "station_busy", tostring(r.reason))
    seed(2, nil, "8,5,0"); relaunch("fire_12"); flax(2)
    r = run({ item = "Steak", station = "fire_12" })
    check("kept loads: another fire 2 m away is not that one", r.reason == "station_busy", tostring(r.reason))
    seed(2, "other"); relaunch("fire_13"); flax(2)
    r = run({ item = "Steak", station = "fire_13" })
    os.remove(C.loads_path("other"))
    check("kept loads: another world's record counts for nothing here", r.reason == "station_busy", tostring(r.reason))
    fire.res = {}
    reset()
end
do -- his own leftovers that this recipe doesn't use come out of an idle station first (same run: the rat after the
   -- boil had "no free slot ... it already holds 1 Dirty Water", and he walked 130 m to another fire)
    local fire = station("Campfire", "fire_1", { 8, 3, 0 })
    reset({ stations = { fire }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    fire.res = { { slot = 0, item = "ITEM_Resources_Flax", name = "Flax", count = 2 },
                 { slot = 1, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Animal Fur", count = 1 } }
    _G.DWCraftLoads = { fire_1 = T }
    _G.DWCraftLoaded = { fire_1 = { ITEM_Resources_Flax = T, ITEM_Resources_Coarse_Animal_Fur = T } }
    local r = run({ item = "Steak", station = "fire_1" })
    check("own leftovers: taken out, then cooked", r.ok and (inv_counts().ITEM_Consumable_Farm_Steak or 0) == 1
          and inv_counts().ITEM_Resources_Flax == 2 and inv_counts().ITEM_Resources_Coarse_Animal_Fur == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("own leftovers: reported", r.ok and r.data.took_out and #r.data.took_out == 2
          and tostring(r.data.detail):find("took out", 1, true) ~= nil and tostring(r.data.detail):find("2 Flax", 1, true) ~= nil,
          tostring((r.data or {}).detail))
    -- with no station named he still picks his own fire (its slots come free at the load)
    reset({ stations = { fire }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    fire.res = { { slot = 0, item = "ITEM_Resources_Flax", name = "Flax", count = 2 },
                 { slot = 1, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Animal Fur", count = 1 } }
    fire.fuel, fire.out, fire.running = {}, {}, false
    _G.DWCraftLoads = { fire_1 = T }
    _G.DWCraftLoaded = { fire_1 = { ITEM_Resources_Flax = T, ITEM_Resources_Coarse_Animal_Fur = T } }
    r = run({ item = "Steak" })
    check("own leftovers: his own fire is still a station that takes it", r.ok and r.data.station_id == "fire_1",
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    -- an item he never put in (someone added it to the fire he used) stays where it is
    reset({ stations = { fire }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    fire.res = { { slot = 0, item = "ITEM_Resources_Flax", name = "Flax", count = 2 },
                 { slot = 1, item = "ITEM_Resources_Coarse_Animal_Fur", name = "Coarse Animal Fur", count = 1 } }
    fire.fuel, fire.out, fire.running = {}, {}, false
    _G.DWCraftLoads = { fire_1 = T }
    _G.DWCraftLoaded = { fire_1 = { ITEM_Resources_Flax = T } }
    r = run({ item = "Steak", station = "fire_1" })
    check("own leftovers: what he never loaded is not taken", inv_counts().ITEM_Resources_Coarse_Animal_Fur == nil
          and #fire.res >= 1, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    _G.DWCraftLoads, _G.DWCraftLoaded = {}, nil
end
do -- lying in a bed: the game blocks walking and stations, so craft says so at once (rung 3 gate 19:56Z)
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local old = SK.W.resting_in
    SK.W.resting_in = function() return "BP_Magic_SummonShelter_C_1" end
    local r = run({ item = "Steak" })
    SK.W.resting_in = old
    check("resting: craft fails resting, naming the bed", r.ok == false and r.reason == "resting"
          and tostring((r.data or {}).detail):find("Summon", 1, true) ~= nil, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
end
do -- the station's menu is closed before the pickup: with it open the game offers none (live 2026-11-02 03:31Z)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.ui_blocks_prompt = true
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    F.ui_blocks_prompt = nil
    check("proc/menu open blocks pickup: closed first, collected", r.ok and inv_counts().ITEM_Resources_IronBar == 1 and F.closed == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail) .. " closed=" .. tostring(F.closed))
end
do -- out of time with part made: he collects what lies there and says the rest wasn't done (live 2026-11-02 03:2xZ:
   -- "made 2 of 3" and both Leather left lying by the Tannery)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 6, ITEM_Fuel_Resources_Charcoal = 2 } })
    local toggle = C.W.toggle
    C.W.toggle = function(...)
        local ok = toggle(...)
        local st = F.stations[1]
        st.never = true -- the second bar never finishes; the first is out at once
        F.nid = (F.nid or 0) + 1
        F.items[#F.items + 1] = { id = "out_" .. F.nid, item = "ITEM_Resources_IronBar", name = "Iron Bar", count = 1,
                                  position = { st.position[1] + 1, st.position[2], st.position[3] } }
        return ok
    end
    local r = run({ recipe = "RECIPE_Process_IronBar", count = 2 }, 1200)
    C.W.toggle = toggle
    check("proc/timeout part made: collected the one, ok partial", r.ok and r.data.partial and inv_counts().ITEM_Resources_IronBar == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("proc/stopped part made: says the rest wasn't done", tostring((r.data or {}).detail):find("1 of 2", 1, true) ~= nil,
          (r.data or {}).detail)
    reset({ stations = { FURNACE({ proc_s = 1e9 }) }, unlocked = U({ "RECIPE_Process_IronBar" }), -- still running at the deadline
            have = { ITEM_Resources_IronOre = 6, ITEM_Fuel_Resources_Charcoal = 2 } })
    C.W.toggle = function(...)
        local ok = toggle(...)
        local st = F.stations[1]
        F.nid = (F.nid or 0) + 1
        F.items[#F.items + 1] = { id = "out_" .. F.nid, item = "ITEM_Resources_IronBar", name = "Iron Bar", count = 1,
                                  position = { st.position[1] + 1, st.position[2], st.position[3] } }
        return ok
    end
    r = run({ recipe = "RECIPE_Process_IronBar", count = 2 }, 2400)
    C.W.toggle = toggle
    check("proc/timeout part made: collected, says it stopped waiting", r.ok and inv_counts().ITEM_Resources_IronBar == 1
          and tostring(r.data.detail):find("stopped waiting (1 of 2)", 1, true) ~= nil, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
end
do -- the side spots round the station never get the item's prompt; the plain walk-up (its tighter last step) does
   -- (live 2026-11-02 03:09Z: 3 Leather by the Tannery, "no use from where I can stand"; interact on one took it)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.item_reach = 0.7 -- the prompt only from close up; once it runs, the station's own prompt reaches only its centre
    local toggle = C.W.toggle
    C.W.toggle = function(...) F.station_reach = 0.3; return toggle(...) end
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    C.W.toggle, F.item_reach, F.station_reach = toggle, nil, nil
    check("proc/side spots fail, plain walk-up collects", r.ok and inv_counts().ITEM_Resources_IronBar == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
end
do -- the output finds no room and lies by the station, with no pickup offered (live 2026-11-02 00:31Z: Tannery,
   -- bag 32/32, 406/400): he says it is still there, where, and the room he lacks, not "couldn't pick up what it made"
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.no_item_prompt = true
    local old_free, old_enc = INV.free_slot, MOVE.encumbrance
    INV.free_slot = function() return nil end
    MOVE.encumbrance = function() return { on = true, cur = 406.04, max = 400 } end
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    INV.free_slot, MOVE.encumbrance = old_free, old_enc
    local d = r.data or {}
    check("proc/no room: inventory_full, not verification_failed", r.ok == false and r.reason == "inventory_full", tostring(r.reason))
    check("proc/no room: names what lies there and where", d.left_behind and d.left_behind.count == 1 and d.left_behind.at
          and d.left_behind.at[1] == 9 and #d.left_behind.ids == 1, d.left_behind and d.left_behind.count)
    check("proc/no room: detail says it is still there, the full bag and the weight",
          tostring(d.detail):find("still lying on the ground by it at (9, 3)", 1, true) ~= nil
          and tostring(d.detail):find("no free slot", 1, true) ~= nil and tostring(d.detail):find("406 of 400", 1, true) ~= nil,
          d.detail)
    check("proc/no room: the bar is still in the world", #F.items == 1)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.no_item_prompt = true -- room known to be there: no room claim, still where it lies
    INV.free_slot = function() return 4 end
    r = run({ recipe = "RECIPE_Process_IronBar" })
    INV.free_slot = old_free
    check("proc/no prompt, room free: verification_failed, says where it lies, claims no full bag",
          r.reason == "verification_failed" and tostring((r.data or {}).detail):find("still lying", 1, true) ~= nil
          and tostring((r.data or {}).detail):find("free slot", 1, true) == nil, tostring((r.data or {}).detail))
end
do -- the output lies at the station, whose interaction wins a near miss (live 2026-10-26: "the game targets
   -- BP_Station_Campfire_C, not the Clean Water"): he stands where the station is not behind the item
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.station_behind = true
    local old_poll=SK._episode_poll;local owned_polls=0
    SK._episode_poll=function(api_,ep,t,token)
        if token and ARB.owns_move(token) then owned_polls=owned_polls+1 end
        return old_poll(api_,ep,t,token)
    end
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    SK._episode_poll=old_poll
    check("processing pickup inherits craft owner token",owned_polls>0)
    check("proc/station behind: collected", r.ok and inv_counts().ITEM_Resources_IronBar == 1,
          tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    local st = F.stations[1].position
    local v = { F.pos[1] - (st[1] + 1), F.pos[2] - st[2] } -- from the output (station + 1 m on X) to where he stood
    check("proc/station behind: stood beside the item, not on it or beyond it", math.abs(v[1]) < 0.2 and math.abs(math.abs(v[2]) - 0.9) < 0.1,
          F.pos[1] .. "," .. F.pos[2])
    -- spot geometry: 0 deg = between the item and the competitor, 180 = the far side
    local sp = SK._spots_avoiding({ 1, 0, 0 }, { 0, 0, 0 })
    check("spots_avoiding: beside first, between, far side last", #sp == 4 and math.abs(sp[1][1] - 1) < 1e-6 and math.abs(math.abs(sp[1][2]) - 0.9) < 1e-6
          and math.abs(sp[3][1] - 0.1) < 1e-6 and math.abs(sp[4][1] - 1.9) < 1e-6)
end
do -- a generic pickup the detector loses to a neighbour: the next sides avoid what it picked instead
    reset({ stations = { FURNACE() } })
    F.station_behind = true
    F.items = { { id = "it_1", item = "ITEM_Resources_IronBar", name = "Iron Bar", count = 1, position = { 9, 3, 0 }, category = "items" } }
    api.find_thing = function(id)
        for _, it in ipairs(F.items) do if it.id == id then return it end end
        for _, s in ipairs(F.stations) do if s.id == id then return s end end
    end
    F.pos = { 11, 3, 0 } -- approaching from beyond the item: the furnace is right behind it
    local e = SK._new_episode(api, F.items[1], { label = "Iron Bar" })
    e.want_item, e.need_gain = "ITEM_Resources_IronBar", true
    local res
    local owner=ARB.request(nil,{name="test:episode"})
    for _ = 1, 200 do T = T + 0.25; res = SK._episode_poll(api, e, T, owner.token); if res then break end end
    check("episode: other sides avoid the station it picked", res and res.ok and e.avoid and e.avoid[1] == 8 and inv_counts().ITEM_Resources_IronBar == 1,
          res and (tostring(res.reason) .. " " .. tostring((res.data or {}).detail)))
    api.find_thing = function(id) for _, it in ipairs(F.items) do if it.id == id then return it end end end
end
do -- station's own fuel (allowed) + stored outputs (quick transfer)
    reset({ stations = { FURNACE({ fuel = { { slot = 0, item = "ITEM_Fuel_Resources_Charcoal", name = "Charcoal", count = 2 } }, store = true }) },
            unlocked = U({ "RECIPE_Process_IronBar" }), have = { ITEM_Resources_IronOre = 3 } })
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    check("proc: station fuel ok", r.ok, tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("proc: station fuel reported", r.data.fuel_used and r.data.fuel_used.source == "station")
    check("proc: station_before reported", r.data.station_before and #r.data.station_before.fuel == 1)
    check("proc: stored output taken via quick transfer", F.takes == 1 and inv_counts().ITEM_Resources_IronBar == 1)
    check("proc: only the ore dragged", F.drags == 1, F.drags)
end
do -- contents already in it would change the recipe -> station_busy naming it
    reset({ stations = { FURNACE({ res = { { slot = 0, item = "ITEM_Resources_TinOre", name = "Tin Ore", count = 5 } } }) },
            unlocked = U({ "RECIPE_Process_IronBar" }), have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.stations[1].res[2] = { slot = 1, item = "ITEM_Resources_CopperOre", name = "Copper Ore", count = 3 }
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    check("proc: station_busy", r.reason == "station_busy", tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("proc: busy names the station contents", r.data.station_before and #r.data.station_before.resources == 2)
    check("proc: UI closed on busy", F.closed == 1)
end
do -- ambiguous fuel in a job
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1, ITEM_Fuel_Resources_Fuel_Pellet = 1 } })
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    check("proc: ambiguous fuel -> fuels listed", r.reason == "ambiguous_target" and #r.data.fuels == 2, tostring(r.reason))
    check("proc: UI closed on ambiguous fuel", F.closed == 1)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1, ITEM_Fuel_Resources_Fuel_Pellet = 1 } })
    r = run({ recipe = "RECIPE_Process_IronBar", fuel = "Fuel Pellet" })
    check("proc: fuel arg -> ok", r.ok and r.data.fuel_used.item == "ITEM_Fuel_Resources_Fuel_Pellet", tostring(r.reason))
end
do -- the station never finishes -> timeout with the time in the sentence; UI closed
    reset({ stations = { FURNACE({ never = true, proc_s = 1e9 }) }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local r = run({ recipe = "RECIPE_Process_IronBar" }, 2000, 0.5)
    check("proc: timeout", r.reason == "timeout" and tostring(r.data.detail):find("took too long"), tostring(r.reason) .. " " .. tostring((r.data or {}).detail))
    check("proc: UI closed on timeout", F.closed == 1)
end
do -- cancel closes the UI
    reset({ stations = { FURNACE({ never = true, proc_s = 1e9 }) }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    local h = C.HANDLERS.craft(nil, { recipe = "RECIPE_Process_IronBar" }, { api = api })
    local a = h.pending
    for _ = 1, 40 do T = T + 0.25; a.poll(a) end
    a.cancel()
    check("cancel: UI closed", F.closed == 1, F.closed)
end

-- ------------------------------------------------------------------ read tools + manifest
do
    reset({ stations = { TABLE(), FURNACE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 },
            unlocked = U({ "RECIPE_Pickaxe_Stone", "RECIPE_Process_IronBar" }) })
    local r = C.HANDLERS.stations(nil, {}, { api = api })
    check("stations: both typed", r.ok and #r.data.stations == 2 and r.data.stations[1].station ~= nil)
    local bench
    for _, s in ipairs(r.data.stations) do if s.station == "CraftingTable" then bench = s end end
    local can = false
    for _, n in ipairs(bench and bench.can_make_now or {}) do if n == "Stone Pickaxe" then can = true end end
    check("stations: can_make_now at the bench", can)
    local fu
    for _, s in ipairs(r.data.stations) do if s.station == "Furnace" then fu = s end end
    check("stations: furnace state", fu and fu.state and fu.state.running == false)
    r = C.HANDLERS.recipes(nil, {}, { api = api })
    check("recipes: craftable now", r.ok and r.data.recipes[1] and r.data.recipes[1].recipe == "RECIPE_Pickaxe_Stone")
    r = C.HANDLERS.recipes(nil, { item = "Iron Bar" }, { api = api })
    check("recipes: every iron bar recipe with status", r.ok and r.data.total >= 2 and r.data.recipes[1].status ~= nil)
    r = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe", count = 1 }, { api = api })
    check("craft_plan: tool works", r.ok and r.data.root.status == "craft")
    r = C.HANDLERS.craft_plan(nil, {}, { api = api })
    check("craft_plan: invalid args", r.reason == "invalid_args")
end
do -- get_state extras: stations nearby with the furnace's state, from the census rows
    _G.DWCraftLoads = {}
    reset({ stations = { TABLE(), FURNACE({ res = { { slot = 0, item = "ITEM_Resources_IronOre", name = "Iron Ore", count = 3 } } }) } })
    local rows = api.census_things()
    local ex = C.state_extras(api, { interactables = rows })
    local fu
    for _, s in ipairs(ex.stations_nearby or {}) do if s.station == "Furnace" then fu = s end end
    check("extras: two stations", ex.stations_nearby and #ex.stations_nearby == 2)
    check("extras: furnace contents", fu and fu.contents and fu.contents[1] == "Iron Ore x3", fu and fu.contents and fu.contents[1])
    check("extras: cached", C.state_extras(api, { interactables = {} }) == ex)
    -- an action that ended may have changed what a station holds: the state after it is read anew
    check("extras: an action's end is told to the module", type(C.action_ended) == "function")
    if C.action_ended then C.action_ended("craft") end
    local ex2 = C.state_extras(api, { interactables = rows })
    check("extras: read anew after an action ended", ex2 ~= ex and ex2.stations_nearby and #ex2.stations_nearby == 2)
    ex = ex2
    fu = nil
    for _, s in ipairs(ex.stations_nearby or {}) do if s.station == "Furnace" then fu = s end end
    -- what a player sees at the fire before he walks to it: no fuel in it, and things in it that are not his
    -- (quest chain 094732, Ratcatcher: the row said only name, id and distance; he named a campfire holding another
    -- player's Dirty Water -> station_busy, then one with no fuel -> missing_materials: two of the run's three misses)
    check("extras: no fuel is said", fu and fu.fuel == false, fu and tostring(fu.fuel))
    check("extras: someone else's inputs are said", fu and fu.others_left == "3 Iron Ore", fu and tostring(fu.others_left))
    check("extras: a bench has no fuel field", (function() for _, s in ipairs(ex.stations_nearby) do if s.station ~= "Furnace" and s.fuel ~= nil then return false end end return true end)())
end
for name in pairs(C.HANDLERS) do
    check("manifest entry " .. name, C.MANIFEST[name] and C.MANIFEST[name].description and C.MANIFEST[name].args)
    check("needs entry " .. name, C.NEEDS[name] ~= nil)
end
check("manifest: craft is an action, plan is read", C.MANIFEST.craft.kind == "action" and C.MANIFEST.craft_plan.kind == "read")
-- a craft without its inputs is a failed action (the goal counts it as a miss), and a recipe can be read without one:
-- 6 of 12 Getting Started runs (2026-11-16 16:00Z on) began the craft step with a craft that had no Ash Logs
check("manifest: craft does not call a craft without its inputs safe, and says where a recipe is read",
    not C.MANIFEST.craft.description:lower():find("safe to try", 1, true) and C.MANIFEST.craft.description:find("recipes", 1, true) ~= nil,
    C.MANIFEST.craft.description)

do -- an ambiguous name lists what he can make now first and names it (rung 4, 21:57Z: "bow" hid the Ash Shortbow)
    reset({ stations = { TABLE() }, unlocked = U({ "RECIPE_Weapon_Shortbow_Wood" }),
            have = { ITEM_Resources_Wood_Ash = 20, ITEM_Resources_Thread_Coarse = 6 } })
    for _, tool in ipairs({ "recipes", "craft_plan", "craft" }) do
        local r = C.HANDLERS[tool](nil, { item = "bow" }, { api = api })
        local c1 = r.data and r.data.candidates and r.data.candidates[1] or {}
        check(tool .. ": ambiguous bow -> the makeable Ash Shortbow first", not r.ok and r.reason == "ambiguous_target"
              and c1.item == "ITEM_Shortbow_Wood" and c1.status == "ready", tostring(c1.item) .. " " .. tostring(c1.status))
        check(tool .. ": the detail names it", tostring(r.data and r.data.detail):find("I can make now: Ash Shortbow", 1, true) ~= nil,
              tostring(r.data and r.data.detail))
    end
    reset({ stations = { TABLE() }, unlocked = {} })
    local r = C.HANDLERS.recipes(nil, { item = "bow" }, { api = api })
    check("recipes: ambiguous bow, nothing makeable -> says so", not r.ok and tostring(r.data.detail):find("can't make any", 1, true) ~= nil,
          tostring(r.data and r.data.detail))
    check("ambiguous: no craft action or movement", not F.goal and not F.moves and not F.ui)
end
do -- category discovery offers identities only; exact and substring names retain precedence
    reset({ stations = { TABLE() }, unlocked = {} })
    local id, hits, kind = C.resolve_item("  hAtChEt  ")
    local has_stone = false
    for _, item in ipairs(hits or {}) do if item == "ITEM_Logging_Axe_Stone" then has_stone = true end end
    check("category: native hatchet finds stone axe", not id and kind == "category" and has_stone)
    local _, full, full_kind = C.resolve_item("Item.Equipment.Tool.Hatchet")
    check("category: full tag and leaf match", full_kind == "category" and #full == #hits)
    for _, tool in ipairs({ "recipes", "craft_plan", "craft" }) do
        local r = C.HANDLERS[tool](nil, { item = "Hatchet" }, { api = api })
        check(tool .. ": category candidates not a selection", not r.ok and r.reason == "ambiguous_target"
              and r.data.total == #hits and r.data.candidates[1].category == "Item.Equipment.Tool.Hatchet")
    end
    check("category: no craft action or movement", not F.goal and not F.moves and not F.ui)
    local fake = { items = {}, recipes = {}, stations = {} }
    for i = 1, 17 do
        local path = "/fake/ITEM_" .. i
        fake.items[path] = { id = "ITEM_" .. i, name = "Object " .. i, category = "Item.Tool.Bundle" }
        fake.recipes["R" .. i] = { path = "/fake/R" .. i, inputs = {}, outputs = {{ path, 1 }}, stations = {} }
    end
    fake.items["/fake/only"] = { id = "ITEM_only", name = "One Object", category = "Item.Tool.Special" }
    fake.recipes.ONLY = { path = "/fake/ONLY", inputs = {}, outputs = {{ "/fake/only", 1 }}, stations = {} }
    C.set_data(fake)
    local single, one, one_kind = C.resolve_item("special")
    check("category: single still requires selection", not single and #one == 1 and one_kind == "category")
    local r = C.HANDLERS.recipes(nil, { item = "bundle" }, { api = api })
    check("category: sorted candidates", r.reason == "ambiguous_target" and r.data.total == 17
          and #r.data.candidates == 17 and r.data.candidates[1].item < r.data.candidates[2].item)
    check("category: exact name wins", C.resolve_item("One Object") == "ITEM_only")
    check("category: unique substring wins", C.resolve_item("One Obj") == "ITEM_only")
    local _, none = C.resolve_item("does-not-exist")
    check("category: absent is unknown", #none == 0)
    C.set_data(REAL)
end

do -- the game's own count (GetNumItemsByData) feeds assess and the plan where the slot rows miss an item
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    F.native = { ITEM_Resources_Stone = 8 }
    local r = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe" }, { api = api })
    check("native: plan counts what the rows miss", r.ok and r.data.root.status == "craft", r.data and r.data.root and r.data.root.status)
    r = C.HANDLERS.recipes(nil, { item = "Stone Pickaxe" }, { api = api })
    check("native: assess counts it", r.ok and r.data.recipes[1].status == "ready", r.data and r.data.recipes and r.data.recipes[1] and r.data.recipes[1].status)
    F.native = { ITEM_Resources_Stone = false }
    r = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe" }, { api = api })
    check("native: unreadable falls back to the rows", r.ok and r.data.root.status == "craft_after", r.data and r.data.root and r.data.root.status)
end

do -- quantity_mode: additional_output (default) ignores the carried goal item; inventory_target counts it
    reset({ stations = { TABLE() }, have = { ITEM_Pickaxe_Stone = 1, ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 },
            unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    local a = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe" }, { api = api })
    check("mode: default plans one more", a.ok and a.data.quantity_mode == "additional_output" and a.data.root.have == 0 and a.data.root.status == "craft")
    local target = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe", quantity_mode = "inventory_target" }, { api = api })
    check("mode: inventory target counts the carried one", target.ok and target.data.quantity_mode == "inventory_target" and target.data.root.status == "have")
    local bad = C.HANDLERS.craft_plan(nil, { item = "Stone Pickaxe", quantity_mode = "invalid" }, { api = api })
    check("mode: unknown rejected", bad.reason == "invalid_args")
    bad = C.HANDLERS.craft_plan(nil, { recipe = "RECIPE_Pickaxe_Stone", quantity_mode = "inventory_target" }, { api = api })
    check("mode: recipe with stock target rejected", bad.reason == "invalid_args")
    local schema = C.MANIFEST.craft_plan.args.properties.quantity_mode
    check("mode: manifest exposes it", schema and schema.default == "additional_output" and #schema.enum == 2)
    local A, P = "/cycle/A.A", "/cycle/P.P"
    C.set_data({ stations = { Bench = { kind = "crafting", name = "Bench" } }, items = { [A] = { id = "A", name = "Input" }, [P] = { id = "P", name = "Product" } },
                 recipes = { RP = { path = "/cycle/RP", inputs = { { A, 1 } }, outputs = { { P, 1 } }, stations = { "Bench" } },
                             RA = { path = "/cycle/RA", inputs = { { P, 1 } }, outputs = { { A, 1 } }, stations = { "Bench" } } } })
    local ctx = { have = { P = 1 }, unlocked = U({ "RP", "RA" }), near = near("Bench"), quantity_mode = "additional_output" }
    local t = C.plan_tree({ item = "P" }, 1, ctx)
    check("mode: root stock left for a descendant", t.root.have == 0 and t.root.inputs[1].inputs[1].status == "have")
    ctx.have = {}
    t = C.plan_tree({ item = "P" }, 1, ctx)
    check("mode: cycle detection kept (a loop is no path)", t.root.status == "obtain" and ((t.root.alternatives or {})[1] or {}).status == "cycle")
    C.set_data(REAL)
end

do -- only a verdict for this recipe and count is ours; another craft's verdict never decides
    local send = C.W.send_craft
    local function run_extra(code, extra)
        reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }), result_code = code })
        C.W.send_craft = function(api_, rid, count)
            local ok = send(api_, rid, count); local st = _G.DWCraft; st.seq = st.seq + 1
            local event = extra(rid, count); event.seq = st.seq; st.results[#st.results + 1] = event; return ok
        end
        local result = run({ recipe = "RECIPE_Pickaxe_Stone" }); C.W.send_craft = send; return result
    end
    local r = run_extra(0, function(_, count) return { recipe_path = "/Other/Unrelated.Unrelated", count = count, result = 2 } end)
    check("verdict: unrelated failure ignored", r.ok, tostring(r.reason))
    r = run_extra(2, function(_, count) return { recipe_path = "/Other/Unrelated.Unrelated", count = count, result = 0 } end)
    check("verdict: unrelated success can't hide ours", r.reason == "inventory_full", tostring(r.reason))
end

do -- an unreadable inventory after the craft is never reported as made, nor as "didn't show up"
    reset({ stations = { TABLE() }, have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }, unlocked = U({ "RECIPE_Pickaxe_Stone" }) })
    local counts, send = api.counts, C.W.send_craft
    C.W.send_craft = function(...) local ok = send(...); api.counts = function() return nil end; return ok end
    local r = run({ recipe = "RECIPE_Pickaxe_Stone" })
    api.counts, C.W.send_craft = counts, send
    check("verify: unknown counts -> verification_failed", r.reason == "verification_failed" and tostring(r.data.detail):find("couldn't read"), tostring(r.reason))
end

do -- the processing baseline is read right before the start, not before the walk
    reset({ stations = { FURNACE() }, have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 }, unlocked = U({ "RECIPE_Process_IronBar" }) })
    local move, injected = C.W.move_into, false
    C.W.move_into = function(...) if not injected then injected = true; add_inv("ITEM_Resources_IronBar", 1) end; return move(...) end
    local r = run({ recipe = "RECIPE_Process_IronBar" }); C.W.move_into = move
    check("proc: baseline excludes earlier output", r.ok and r.data.count == 1 and inv_counts().ITEM_Resources_IronBar == 2, tostring(r.reason))
end

do -- A malformed successful movement response must not release its parent or press UI.
    reset({stations={TABLE()},have={ITEM_Resources_Wood_Ash=6,ITEM_Resources_Stone=8},unlocked=U({"RECIPE_Pickaxe_Stone"})})
    local original=MOVE.go_to
    MOVE.go_to=function(log,pos,opts) local r=original(log,pos,opts);r.gen=nil;return r end
    local h=C.HANDLERS.craft(nil,{recipe="RECIPE_Pickaxe_Stone"},{api=api,id="missing-gen"})
    local a=h.pending;a.started=T
    for _=1,10 do T=T+.25;a.poll(a) end
    check("unconfirmed child generation retains parent and does not press",ARB.owner~=nil and not F.presses and not F.sent and F.moves==1,
      "owner="..tostring(ARB.owner~=nil).." presses="..tostring(F.presses).." sent="..tostring(F.sent).." goal="..tostring(F.goal~=nil).." moves="..tostring(F.moves))
    MOVE.go_to=original;ARB.owner=nil;F.goal=nil
end

do -- burn odds as a player sees them (rung 3 cook 2026-11-02 04:20Z: he cooked his Raw Farm Meat first, 2 of 3 burnt;
   -- the card said "below Cooking 12 most burn" with no word of his own odds). The game's own attribute per power level
   -- is on every cook he can make (recipes, stations) and in get_state; nothing is skipped or ranked
    local old = C.W.burn_odds
    C.W.burn_odds = function() return { [1] = 0.0, [2] = 0.4615 } end
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) },
            unlocked = U({ "RECIPE_Consumable_Steak_From_Farm", "RECIPE_Consumable_Rat_Roast_From_Rat" }),
            have = { ITEM_Resources_Meat_Farm = 3, ITEM_Resources_Raw_Stringy_Meat = 3, ITEM_Resources_Wood_Ash = 2 } })
    local r = C.HANDLERS.recipes(nil, { near_only = true }, { api = api })
    local by = {}
    for _, c in ipairs((r.data or {}).recipes or {}) do by[c.recipe] = c end
    local steak = (by.RECIPE_Consumable_Steak_From_Farm or {}).may_burn or {}
    local rat = (by.RECIPE_Consumable_Rat_Roast_From_Rat or {}).may_burn or {}
    check("burn odds: steak names the raw input and the game's 46 %", tostring(steak.text):find("Raw Farm Meat: burns about 46%", 1, true) ~= nil
          and steak.source == "game", tostring(steak.text))
    check("burn odds: steak says from when it stops (wiki)", tostring(steak.text):find("none from Cooking 27", 1, true) ~= nil, tostring(steak.text))
    check("burn odds: rat never burns now", tostring(rat.text):find("Raw Rat Meat: never burns", 1, true) ~= nil, tostring(rat.text))
    check("burn odds: both cooks still listed (no veto)", by.RECIPE_Consumable_Steak_From_Farm ~= nil and by.RECIPE_Consumable_Rat_Roast_From_Rat ~= nil)
    local s = C.HANDLERS.stations(nil, { radius = 40 }, { api = api })
    local st = (((s.data or {}).stations) or {})[1] or {}
    local joined = table.concat(st.burn_odds or {}, " | ")
    check("burn odds: the station lists each cook's odds", joined:find("Steak from Raw Farm Meat: burns about 46%", 1, true) ~= nil
          and joined:find("Rat Roast from Raw Rat Meat: never burns", 1, true) ~= nil, joined)
    C.W.burn_odds = function() return nil end
    reset({ stations = { station("Campfire", "fire_1", { 8, 3, 0 }) }, unlocked = U({ "RECIPE_Consumable_Steak_From_Farm" }),
            have = { ITEM_Resources_Meat_Farm = 1, ITEM_Resources_Wood_Ash = 2 } })
    local r2 = C.HANDLERS.recipes(nil, { near_only = true }, { api = api })
    local c2 = (((r2.data or {}).recipes) or {})[1] or {}
    check("burn odds: unread -> the wiki levels, marked wiki", (c2.may_burn or {}).source == "wiki"
          and tostring((c2.may_burn or {}).text):find("below Cooking 12 most burn", 1, true) ~= nil, tostring((c2.may_burn or {}).text))
    C.W.burn_odds = old
end

do -- no wheel near: the plan names the Spinning Wheel (a real station in this build), never the catalog-only
   -- AdvancedSpinningWheel listed first (farm_gate 06:1xZ: he explored 254 m for it and died)
    reset({ stations = { TABLE() }, unlocked = U({ "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur", "RECIPE_Tool_T1_Spade_Wood" }),
            have = { ITEM_Resources_Coarse_Animal_Fur = 9, ITEM_Resources_Wood_Ash = 10 } })
    local r = C.HANDLERS.craft_plan(nil, { item = "Wooden Spade" }, { api = api })
    local fs
    for _, st in ipairs((r.data or {}).steps or {}) do if st["do"] == "find_station" then fs = st end end
    check("plan: find the Spinning Wheel", fs and fs.station == "Spinning Wheel" and fs.name == "Spinning Wheel",
          fs and (tostring(fs.station) .. " / " .. tostring(fs.name)))
end

do -- no Tannery near: the find_station step says whether a Tannery is a piece he has unlocked and can build, with
   -- what (offline check 2026-11-17 23:4xZ of craft_plan Bone Pickaxe: "find_station Tannery" only)
    local function plan_bone()
        reset({ stations = { TABLE() }, unlocked = U({ "RECIPE_Pickaxe_Bone", "RECIPE_Process_Leather_From_Hide" }),
                have = { ITEM_Resources_AnimalBone = 8, ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Animal_Hide = 4 } })
        local r = C.HANDLERS.craft_plan(nil, { item = "Bone Pickaxe" }, { api = api })
        for _, st in ipairs((r.data or {}).steps or {}) do if st["do"] == "find_station" and st.station == "Tannery" then return st end end
    end
    BUILD_STUB = { HANDLERS = { buildables = function()
        return { ok = true, data = { pieces = { { name = "Tannery", cost = { { count = 12, name = "Ash Logs" }, { count = 4, name = "Animal Bone" },
            { count = 2, name = "Coarse Thread" } }, missing = { { item = "ITEM_Resources_Wood_Ash", name = "Ash Logs", need = 12, have = 6 },
            { item = "ITEM_Resources_Thread_Coarse", name = "Coarse Thread", need = 2, have = 0 } }, can_build_now = false } } } }
    end } }
    local fs = plan_bone()
    check("plan: find Tannery says it is his to build, with the cost", fs and fs.build and fs.build.piece == "Tannery"
          and fs.build.cost == "12 Ash Logs + 4 Animal Bone + 2 Coarse Thread" and fs.build.can_build_now == false
          and tostring(fs.build.short):find("6 Ash Logs", 1, true) ~= nil, fs and fs.build and fs.build.text)
    BUILD_STUB = { HANDLERS = { buildables = function() return { ok = true, data = { pieces = { { name = "Campfire", cost = {} } } } } end } }
    fs = plan_bone()
    check("plan: a station not among his pieces is marked so", fs and fs.build == nil and fs.build_unlocked == false, fs and tostring(fs.build_unlocked))
    BUILD_STUB = { HANDLERS = { buildables = function() return { ok = false, reason = "state_unavailable" } end } }
    fs = plan_bone()
    check("plan: pieces unread -> nothing claimed", fs and fs.build == nil and fs.build_unlocked == nil)
    -- the build's short things as rows with their ids, so the brain can give each its sources like any plan input
    -- (thread study 2026-11-18, run 053839: "I'm short of 2 Coarse Thread" was text only; he carried 7 fur, the
    -- Planner asked the player for thread)
    BUILD_STUB = { HANDLERS = { buildables = function()
        return { ok = true, data = { pieces = { { name = "Tannery", cost = { { count = 12, name = "Ash Logs" }, { count = 4, name = "Animal Bone" },
            { count = 2, name = "Coarse Thread" } }, missing = { { item = "ITEM_Resources_Wood_Ash", name = "Ash Logs", need = 12, have = 6, in_storage = 6 },
            { item = "ITEM_Resources_Thread_Coarse", name = "Coarse Thread", need = 2, have = 0 } }, can_build_now = false } } } }
    end } }
    fs = plan_bone()
    local si = fs and fs.build and fs.build.short_items or {}
    check("plan: a build's short things carry their item ids (stored ones are not short)", #si == 1
          and si[1].item == "ITEM_Resources_Thread_Coarse" and si[1].name == "Coarse Thread" and si[1].count == 2,
          fs and fs.build and fs.build.short)
    BUILD_STUB = nil
end

do -- a recipe whose inputs he holds and that lacks only the station ranks ahead of one that lacks an input AND the
   -- same station (thread study 2026-11-18: 7 fur carried, no flax, no wheel near; the plan's path was gather Flax,
   -- the fur recipe only an alternative, because the flax recipe read missing_input and hid that it lacks the wheel too)
    local unl = U({ "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur", "RECIPE_Process_Thread_Linen_From_Flax" })
    reset({ stations = { TABLE() }, unlocked = unl, have = { ITEM_Resources_Coarse_Animal_Fur = 7 } })
    local r = C.HANDLERS.craft_plan(nil, { item = "Coarse Thread", count = 2 }, { api = api })
    local root = (r.data or {}).root or {}
    check("rank: fur held, no wheel -> the fur recipe is the path", root.recipe == "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur",
          tostring(root.recipe) .. " " .. tostring(root.status))
    check("rank: no flax gather step when the fur is held", has_step((r.data or {}).steps or {}, "gather", "item", "ITEM_Resources_Flax") == nil)
    local alt = (root.alternatives or {})[1] or {}
    check("rank: the flax alternative says it lacks the flax and the wheel", alt.recipe == "RECIPE_Process_Thread_Linen_From_Flax"
          and tostring(alt.detail):find("2 Flax for that", 1, true) ~= nil and tostring(alt.detail):find("Spinning Wheel near here", 1, true) ~= nil,
          alt.detail)
    local ctx = { have = { ITEM_Resources_Coarse_Animal_Fur = 7 }, unlocked = unl, near = {} }
    local cs = C.candidates("ITEM_Resources_Thread_Coarse", 2, ctx)
    check("rank: candidates list the fur recipe first", cs[1] and cs[1].recipe == "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur"
          and cs[2] and cs[2].status == "missing_input" and cs[2].rank < C.RANK.missing_input, cs[1] and cs[1].recipe)
    -- a wheel near: lacking an input there still ranks above lacking the station (unchanged)
    local near_ctx = { have = {}, unlocked = unl, near = near("Spinning Wheel") }
    local a = C.assess("RECIPE_Process_Thread_Linen_From_Flax", 1, near_ctx)
    check("rank: an input short at a station near keeps its rank", a.status == "missing_input" and a.rank == C.RANK.missing_input, a.rank)
end

do -- a step or a craft short of a raw material says where he has gathered it before (navmem's gather spots)
    local old = C.W.gather_memory
    local asked = {}
    C.W.gather_memory = function() return { known_text = function(item, here)
        asked[#asked + 1] = item
        if item == "ITEM_Resources_Coarse_Animal_Fur" or item == "ITEM_Resources_Thread_Coarse" then
            return "Stuff you've gathered before: 3 about 50 m E at (60, 0), last 02:00Z (1.0 h ago)."
        end
    end } end
    reset({ stations = { TABLE() }, unlocked = U({ "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur", "RECIPE_Tool_T1_Spade_Wood" }),
            have = { ITEM_Resources_Wood_Ash = 10 } })
    local r = C.HANDLERS.craft_plan(nil, { item = "Wooden Spade" }, { api = api })
    local ob
    for _, st in ipairs((r.data or {}).steps or {}) do if st["do"] == "obtain" or st["do"] == "gather" then ob = ob or st end end
    check("plan: a get-it step carries where he gathered it before", ob and tostring(ob.gathered_before):find("50 m E", 1, true) ~= nil,
          ob and (tostring(ob.item) .. " " .. tostring(ob.gathered_before)))
    local c = C.HANDLERS.craft(nil, { item = "Wooden Spade" }, { api = api })
    local m = ((c.data or {}).missing or {})[1] or {}
    check("craft short: the missing row and the sentence say where he gathered it", c.ok == false and m.gathered_before ~= nil
          and tostring(c.data.detail):find("you've gathered before: 3 about 50 m E", 1, true) ~= nil, tostring(c.data and c.data.detail))
    -- thread from fur (2 carried, 1 short) or from flax: an alternative short of a thing he has gathered before says where
    C.W.gather_memory = function() return { known_text = function(item)
        if item == "ITEM_Resources_Flax" then return "Flax you've gathered before: 10 about 301 m NE at (394, 1713), last 02:25Z (5.0 h ago)." end
        if item == "ITEM_Resources_Coarse_Animal_Fur" then return "Fur you've picked up before: 2 about 120 m W at (-90, 10), last 02:00Z (5.4 h ago)." end
    end } end
    local spade_unl = U({ "RECIPE_Process_Thread_Linen_From_Coarse_Animal_Fur", "RECIPE_Process_Thread_Linen_From_Flax", "RECIPE_Tool_T1_Spade_Wood" })
    reset({ stations = { TABLE() }, unlocked = spade_unl, have = { ITEM_Resources_Coarse_Animal_Fur = 2, ITEM_Resources_Wood_Ash = 10 } })
    local ra = C.HANDLERS.craft_plan(nil, { item = "Wooden Spade" }, { api = api })
    local found
    local function walk(n) for _, a in ipairs(n.alternatives or {}) do if a.gathered_before then found = a end end
        for _, c in ipairs(n.inputs or {}) do walk(c) end end
    walk((ra.data or {}).root or {})
    check("plan: an alternative short of fur says where he had fur", found and tostring(found.detail):find("120 m W", 1, true) ~= nil,
          found and found.detail)
    -- 1 fur short (no recipe or gather profile yields fur), flax gatherable: the flax is the path, its gather step says
    -- where (farm chain 11: 1 fur short sent him 300 m after a deer while the flax he had picked went unsaid)
    local gf = has_step((ra.data or {}).steps or {}, "gather", "item", "ITEM_Resources_Flax")
    check("plan: 1 fur short -> the gatherable flax is the path, with where", gf and tostring(gf.gathered_before):find("301 m NE", 1, true) ~= nil,
          gf and gf.gathered_before)
    C.W.gather_memory = function() return nil end
    local r2 = C.HANDLERS.craft_plan(nil, { item = "Wooden Spade" }, { api = api })
    local any
    for _, st in ipairs((r2.data or {}).steps or {}) do if st.gathered_before then any = true end end
    check("plan: no memory, no line", r2.ok and not any)
    C.W.gather_memory = old
end

do -- the stay-fed reflex drinks what a boil has just handed him (chain 20261116-114101, 11:56:06Z: Clean Water out of a
   -- new campfire, drunk 0.6 s later; the craft counted his bag, read "couldn't pick up what it made", a miss)
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    _G.DW_REFLEX_USES = nil
    F.reflex_takes = "ITEM_Resources_IronBar"
    local r = run({ recipe = "RECIPE_Process_IronBar" })
    local d = r.data or {}
    check("proc/reflex used the output: the craft made it", r.ok and d.count == 1, tostring(r.reason) .. " " .. tostring(d.detail))
    check("proc/reflex used the output: says who used it", d.reflex_used and d.reflex_used[1].count == 1
          and tostring(d.detail):find("My stay-fed reflex drank it", 1, true) ~= nil, d.detail)
    check("proc/reflex used the output: none of it in the bag", (inv_counts().ITEM_Resources_IronBar or 0) == 0)
    -- a use from before the craft is not this craft's
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    _G.DW_REFLEX_USES = { { item = "ITEM_Resources_IronBar", name = "Iron Bar", kind = "drink", ts = os.time() - 30 } }
    r = run({ recipe = "RECIPE_Process_IronBar" })
    check("proc/an older reflex use is not counted", r.ok and r.data.count == 1 and r.data.reflex_used == nil, (r.data or {}).detail)
    _G.DW_REFLEX_USES = nil
end

do -- a failed craft names the recipe he is closest to, each other recipe's shortfall, and how many he can make now
   -- (V1 study 2026-11-19, 4 of 15 misses: "need 4 Animal Hide, have 0" for Leather x4 while he held 11 of the 12
   -- Animal Hide Scraps the scraps recipe takes; the tie on kinds went to the recipe id, Hide before scraps)
    local LEATHER = U({ "RECIPE_Process_Leather_From_Hide", "RECIPE_Process_Leather_From_scraps" })
    local TAN = function() return station("Tannery", "tan_1", { 8, 0, 0 }) end
    local logged = {}
    local log0 = api.log
    api.log = function(m) logged[#logged + 1] = m end
    reset({ stations = { TAN() }, unlocked = LEATHER, have = { ITEM_Resources_Skin_Scraps = 11 } })
    local r = run({ item = "Leather", count = 4 })
    local d = tostring((r.data or {}).detail)
    check("closest: Leather x4 from 11 scraps -> missing_materials", r.reason == "missing_materials", tostring(r.reason))
    check("closest: the scraps recipe named, not the hide one", r.data and r.data.recipe == "RECIPE_Process_Leather_From_scraps", r.data and r.data.recipe)
    check("closest: headline is the scraps shortfall", d:find("^I need 12 Animal Hide Scraps for that and I have 11 %(recipe RECIPE_Process_Leather_From_scraps, 1 short") ~= nil, d)
    check("closest: the hide recipe's shortfall briefly", d:find("the other recipe: RECIPE_Process_Leather_From_Hide needs 4 Animal Hide, I have 0 (4 short)", 1, true) ~= nil, d)
    check("closest: says he can make 3 now", d:find("With what I hold I can make 3 Leather (recipe RECIPE_Process_Leather_From_scraps).", 1, true) ~= nil, d)
    check("closest: can_make in the data", r.data and r.data.can_make and r.data.can_make.count == 3
          and r.data.can_make.recipe == "RECIPE_Process_Leather_From_scraps")
    local cw = {}
    for _, c in ipairs((r.data or {}).candidates or {}) do cw[c.recipe] = c end
    check("closest: candidates carry short and can_make", cw.RECIPE_Process_Leather_From_scraps and cw.RECIPE_Process_Leather_From_scraps.short == 1
          and cw.RECIPE_Process_Leather_From_Hide.short == 4 and cw.RECIPE_Process_Leather_From_Hide.can_make == 0
          and cw.RECIPE_Process_Leather_From_scraps.can_make == 3)
    check("closest: no walk when it can't work", (F.moves or 0) == 0)
    local seen
    for _, m in ipairs(logged) do
        if tostring(m):find("crafting: closest recipe for Leather x4: RECIPE_Process_Leather_From_scraps (1 short of 2 recipes); can make 3 by RECIPE_Process_Leather_From_scraps", 1, true) then seen = m end
    end
    check("closest: the log line", seen ~= nil, table.concat(logged, " | "))
    -- x3 with 3 scraps: the hide recipe is 3 short, the scraps one 6, so hide is closest, and 1 can be made from scraps
    reset({ stations = { TAN() }, unlocked = LEATHER, have = { ITEM_Resources_Skin_Scraps = 3 } })
    r = run({ item = "Leather", count = 3 })
    d = tostring((r.data or {}).detail)
    check("closest x3: fewest short by count -> hide named", r.data and r.data.recipe == "RECIPE_Process_Leather_From_Hide"
          and d:find("(recipe RECIPE_Process_Leather_From_Hide, 3 short", 1, true) ~= nil, d)
    check("closest x3: scraps 6 short", d:find("RECIPE_Process_Leather_From_scraps needs 9 Animal Hide Scraps, I have 3 (6 short)", 1, true) ~= nil, d)
    check("closest x3: can make 1 from scraps", d:find("I can make 1 Leather (recipe RECIPE_Process_Leather_From_scraps)", 1, true) ~= nil, d)
    -- nothing affordable: 0
    reset({ stations = { TAN() }, unlocked = LEATHER, have = { ITEM_Resources_Skin_Scraps = 2 } })
    r = run({ item = "Leather", count = 1 })
    d = tostring((r.data or {}).detail)
    check("closest: none affordable -> can make 0", d:find("With what I hold I can make 0 Leather.", 1, true) ~= nil
          and r.data.can_make.count == 0 and r.data.can_make.recipe == nil, d)
    check("closest: 1 hide vs 1 scrap short: tie on count and kinds -> by id (Hide)", r.data.recipe == "RECIPE_Process_Leather_From_Hide", r.data.recipe)
    -- he names the hide recipe: that one is the headline, the count still covers every recipe for Leather
    reset({ stations = { TAN() }, unlocked = LEATHER, have = { ITEM_Resources_Skin_Scraps = 11 } })
    r = run({ recipe = "RECIPE_Process_Leather_From_Hide", count = 4 })
    d = tostring((r.data or {}).detail)
    check("closest: named recipe stays the headline", r.data and r.data.recipe == "RECIPE_Process_Leather_From_Hide"
          and d:find("^I need 4 Animal Hide for that and I have 0") ~= nil and not d:find("the other recipe", 1, true), d)
    check("closest: named recipe, count over all recipes", d:find("I can make 3 Leather (recipe RECIPE_Process_Leather_From_scraps)", 1, true) ~= nil, d)
    -- pure: candidates rank the closest first
    local cs = C.candidates("ITEM_Resources_Leather", 4, { have = { ITEM_Resources_Skin_Scraps = 11 }, unlocked = LEATHER, near = near("Tannery") })
    check("closest: candidates() puts scraps (1 short) before hide (4 short)", cs[1].recipe == "RECIPE_Process_Leather_From_scraps"
          and cs[1].short == 1 and cs[2].short == 4)
    api.log = log0
end

do -- a gather step names the tool gathering it takes (gather_profiles tool/min_tier) and his best one now (gather.best_tool)
   -- (L3 study 2026-11-20: "gather rune_essence x14", no pickaxe, an essence rock 47 m off; nothing said a pickaxe)
    local G = assert(loadfile(root .. "/client_mod/scripts/gather.lua"))()
    local WD = assert(loadfile(root .. "/client_mod/scripts/weapons_data.lua"))()
    local mod0 = api.module
    api.module = function(n)
        if n == "gather" then return G elseif n == "combat" then return { weapons = function() return WD end } end
        return mod0(n)
    end
    local legs = U({ "RECIPE_Armour_T1_Legs_Lightness", "RECIPE_Pickaxe_Stone" })
    reset({ stations = { TABLE() }, unlocked = legs, have = { ITEM_Resources_Coarse_Animal_Fur = 6 } })
    local r = C.HANDLERS.craft_plan(nil, { recipe = "RECIPE_Armour_T1_Legs_Lightness" }, { api = api })
    local g = has_step((r.data or {}).steps or {}, "gather", "resource", "rune_essence") or {}
    local t = g.tool or {}
    check("gather tool: rune essence needs a pickaxe tier 1, carried none", t.needs == "pickaxe" and t.min_tier == 1
          and t.tier_read == true and t.carried == "none" and not t.ok,tostring(t.needs) .. " " .. tostring(t.min_tier) .. " " .. tostring(t.carried))
    local m1 = (t.makes or {})[1] or {}
    check("gather tool: lacking it, the pickaxes a recipe makes, lowest tier first", m1.item == "ITEM_Pickaxe_Stone" and m1.tier == 1
          and #t.makes <= C.cfg.tool_makes_max, m1.item)
    reset({ stations = { TABLE() }, unlocked = legs, have = { ITEM_Resources_Coarse_Animal_Fur = 6, ITEM_Pickaxe_Bronze = 1 } })
    r = C.HANDLERS.craft_plan(nil, { recipe = "RECIPE_Armour_T1_Legs_Lightness" }, { api = api })
    t = (has_step((r.data or {}).steps or {}, "gather", "resource", "rune_essence") or {}).tool or {}
    check("gather tool: a good-enough pickaxe carried says so", t.ok == true and t.carried == "Bronze Pickaxe (tier 3)" and t.makes == nil,
          tostring(t.carried))
    -- a tool-free resource (flax: a pickup) has no tool field
    reset({ stations = { TABLE() }, unlocked = U({ "RECIPE_Process_Thread_Linen_From_Flax" }) })
    r = C.HANDLERS.craft_plan(nil, { item = "Coarse Thread", count = 2 }, { api = api })
    local gf = has_step((r.data or {}).steps or {}, "gather", "item", "ITEM_Resources_Flax")
    check("gather tool: flax needs none, no field", gf and gf.tool == nil, gf and tostring(gf.tool))
    -- oak needs a tier 3 logging axe; a stone axe is below it
    reset({ have = { ITEM_Logging_Axe_Stone = 1 } })
    local fn = C.W.gather_tool(api)
    local oak = fn("oak") or {}
    check("gather tool: oak, stone axe below tier 3", oak.needs == "logging axe" and oak.min_tier == 3
          and oak.carried == "Stone Logging Axe (tier 1, below 3)" and not oak.ok, tostring(oak.carried))
    local ash = fn("ash") or {}
    check("gather tool: ash names its tool-free source", ash.ok and ash.no_tool_source == nil, tostring(ash.carried))
    reset({})
    ash = C.W.gather_tool(api)("ash") or {}
    check("gather tool: ash without an axe names sticks", ash.carried == "none" and ash.no_tool_source == "sticks", tostring(ash.no_tool_source))
    check("gather tool: a rock kind whose gate was never read says so", (C.W.gather_tool(api)("copper") or {}).tier_read == false)
    api.module = mod0
    check("gather tool: no gather module, no field", C.W.gather_tool(api)("rune_essence") == nil)
end

-- ------------------------------------------------------------------ shelter: the game's two checks (2026-11-20 L3)
do
    -- a 3 m room round a station at (0, 0, 0): boxes {x0, x1, y0, y1, z0, z1}; north = -Y
    local N_WALL = { -1.5, 1.5, -1.6, -1.4, 0, 3 }
    local S_WALL = { -1.5, 1.5, 1.4, 1.6, 0, 3 }
    local E_WALL = { 1.4, 1.6, -1.5, 1.5, 0, 3 }
    local W_WALL = { -1.6, -1.4, -1.5, 1.5, 0, 3 }
    local ROOF = { -1.6, 1.6, -1.6, 1.6, 3, 3.2 }
    local SHORT_N = { -0.5, 0.5, -1.6, -1.4, 0, 3 } -- a 1 m wall piece on the N side
    local function seg_box(a, b, bx) -- slab test: does the segment a->b cross the box?
        local t0, t1 = 0, 1
        for i = 1, 3 do
            local lo, hi, d = bx[2 * i - 1], bx[2 * i], b[i] - a[i]
            if math.abs(d) < 1e-9 then
                if a[i] < lo or a[i] > hi then return false end
            else
                local u, v = (lo - a[i]) / d, (hi - a[i]) / d
                if u > v then u, v = v, u end
                t0, t1 = math.max(t0, u), math.min(t1, v)
                if t0 > t1 then return false end
            end
        end
        return true
    end
    local function world(boxes) return function(a, b) for _, bx in ipairs(boxes) do if seg_box(a, b, bx) then return true end end return false end end
    local rays = {}
    for i = 0, 15 do local ang = math.rad(i * 22.5); rays[#rays + 1] = { math.cos(ang), math.sin(ang), 0 } end
    local rule = { roof_rays = { { 0, 0, 1 } }, shelter_rays = rays, dist_cm = 2000, thick_cm = 200, need = 0.38 }
    local function has(t, w) for _, x in ipairs(t or {}) do if x == w then return true end end return false end

    local three = C.shelter_eval(rule, { 0, 0, 0 }, 0, world({ N_WALL, E_WALL, W_WALL, ROOF }))
    check("shelter eval: roof + walls N, E, W -> roof yes, sides pass", three.roof == "yes" and three.sides_ok == true, three.side_pct)
    check("shelter eval: the open side is named by compass (S), never a walled one", has(three.open, "S") and not has(three.open, "N")
          and not has(three.open, "E") and not has(three.open, "W"), table.concat(three.open or {}, ","))
    check("shelter eval: the threshold is the component's (38 %)", three.need_pct == 38 and three.side_n == 16)
    local one = C.shelter_eval(rule, { 0, 0, 0 }, 0, world({ SHORT_N, ROOF }))
    check("shelter eval: roofed, one short wall -> sides fail (the L3 'needs more surrounding shelter')", one.roof == "yes" and one.sides_ok == false
          and has(one.open, "S") and has(one.open, "E") and has(one.open, "W"), one.side_pct)
    local open = C.shelter_eval(rule, { 0, 0, 0 }, 0, world({ N_WALL, E_WALL, W_WALL, S_WALL }))
    check("shelter eval: four walls, no roof -> roof no", open.roof == "no" and open.sides_ok == true and #open.open == 0)
    -- the rays turn with the station: a ray set covering only its own +X half, the station turned 180 -> faces W
    local half = { roof_rays = {}, shelter_rays = { { 1, 0, 0 }, { 1, 1, 0 }, { 1, -1, 0 } }, dist_cm = 2000, thick_cm = 0, need = 0.38 }
    local turned = C.shelter_eval(half, { 0, 0, 0 }, 180, world({ W_WALL }))
    check("shelter eval: rays are the station's own, turned with its yaw", turned.side_hits == 3 and turned.roof == nil, turned.side_hits)
    -- a ray given as an offset in cm (not a unit vector) is used as is: 5 m, so a wall 10 m off is out of reach
    local far = C.shelter_eval({ shelter_rays = { { 500, 0, 0 } }, dist_cm = 2000, need = 0.38 }, { 0, 0, 0 }, 0, world({ { 9.9, 10.1, -1, 1, 0, 3 } }))
    check("shelter eval: a ray as a cm offset keeps its own length", far.side_hits == 0 and has(far.open, "E"))

    -- words: both checks as facts, the failing one named, the game's own text quoted
    local sh = { rule = "shelter_only", says = " needs more surrounding shelter.", roof_says = " needs a roof.",
                 roof = "yes", roof_hits = 1, roof_n = 1, side_hits = 4, side_n = 16, side_pct = 25, need_pct = 38,
                 open = { "S", "SE", "SW" }, sides_ok = false, covered = true, sheltered = false }
    local w = C.shelter_words(sh, "Spinning Wheel")
    check("shelter words: roof yes, side % vs needed %, open sides", w:find("roof: yes", 1, true) and w:find("4 of 16 rays (25 %)", 1, true)
          and w:find("it needs 38 %", 1, true) and w:find("open toward S, SE, SW", 1, true), w)
    check("shelter words: names the failing check and the game's text", w:find("fails the side check", 1, true)
          and w:find("Spinning Wheel needs more surrounding shelter.", 1, true) and not w:find("walls and a roof round it", 1, true), w)
    local r = C.shelter_refusal(sh)
    check("shelter refusal: a roofed wheel failing the sides is refused with the numbers", r and r:find("too few building pieces", 1, true)
          and r:find("25 %", 1, true), r)
    check("shelter refusal: a passing one is not refused", C.shelter_refusal({ rule = "shelter_only", roof = "yes", sides_ok = true }) == nil)
    check("shelter refusal: unknown sides (no rays read) refuse only on no roof", C.shelter_refusal({ rule = "shelter_only", roof = "yes" }) == nil
          and C.shelter_refusal({ rule = "shelter_only", roof = "no" }) ~= nil)
    local ok_words = C.shelter_words({ rule = "shelter_only", says = " needs more surrounding shelter.", roof = "yes", roof_hits = 1, roof_n = 1,
                                       side_hits = 10, side_n = 16, side_pct = 63, need_pct = 38, open = { "S" }, sides_ok = true, sheltered = true }, "Spinning Wheel")
    check("shelter words: a passing one says so and quotes no failure", ok_words:find("passes both", 1, true) and not ok_words:find("game's words", 1, true), ok_words)

    -- the engine layer: the component's own data by property reads, one line per ray through build's trace;
    -- the station itself and a tree are passed through, a CellBuildingProxy (instance-only pieces) counts
    local function obj(t) t.__valid = true; return t end
    local FU = { try = function(f, ...) local ok, v = pcall(f, ...); if ok then return v end end,
                 valid = function(o) return type(o) == "table" and o.__valid == true end,
                 short = function(o) return o and o.__name end,
                 str = function(v) return type(v) == "table" and v.text or v end }
    local function arr(list) return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end } end
    local function vec(t) return { X = t[1], Y = t[2], Z = t[3] } end
    local vrays = {}
    for _, v in ipairs(rays) do vrays[#vrays + 1] = vec(v) end
    local comp = obj({ __name = "BuildingShelter", InteractionRequirements = 0, RequiresShelterText = { text = " needs more surrounding shelter." },
                       RequiresRoofText = { text = " needs a roof." }, RoofRays = arr({ vec({ 0, 0, 1 }) }), ShelterRays = arr(vrays),
                       SweepRayDistance = 2000, SweepRayThickness = 200, ValidityPercentage = 0.38, bIncludeNonBuildingPartActors = false })
    local wheel = obj({ __name = "BP_Station_Spinning_Wheel_C_7", BuildingShelter = comp, K2_GetActorRotation = function() return { Yaw = 0 } end })
    local proxy = obj({ __name = "CellBuildingProxy_3" })
    local tree = obj({ __name = "BP_Tree_Oak_C_1" })
    local boxes = { SHORT_N, ROOF }
    local traces, logs = 0, {}
    local function hit_out(owner, at) return { ImpactPoint = vec({ at[1] * 100, at[2] * 100, at[3] * 100 }), Component = obj({ GetOwner = function() return owner end }) } end
    local BW = { trace = function(_, a, b)
        traces = traces + 1
        local p, q = { a.X / 100, a.Y / 100, a.Z / 100 }, { b.X / 100, b.Y / 100, b.Z / 100 }
        -- the station's own body round its foot: a line starting inside it meets it first
        if math.abs(p[1]) < 0.3 and math.abs(p[2]) < 0.3 and p[3] < 1.3 and not (math.abs(q[1]) < 0.3 and math.abs(q[2]) < 0.3 and q[3] < 1.3) then
            local d = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2)
            if d > 0.31 then
                local k = 0.3 / d
                return true, hit_out(wheel, { p[1] + (q[1] - p[1]) * k, p[2] + (q[2] - p[2]) * k, p[3] + (q[3] - p[3]) * k })
            end
        end
        if world(boxes)(p, q) then return true, hit_out(proxy, q) end
        return false, {}
    end }
    local fapi = { module = function(n) if n == "sense" then return { U = FU } elseif n == "build" then return { W = BW } end end,
                   now = function() return 100 end, log = function(s) logs[#logs + 1] = s end }
    C.state().shelter_seen = nil
    local got = C.W.shelter(fapi, wheel, { 0, 0, 0 })
    check("shelter W: the component's rays read, both checks run (roof yes, sides fail with one wall)", got and got.roof == "yes"
          and got.sides_ok == false and got.side_n == 16 and got.need_pct == 38 and got.sheltered == false and got.covered == true,
          got and (tostring(got.roof) .. " " .. tostring(got.side_pct)))
    check("shelter W: a log line shows it ran, with the numbers", logs[1] and logs[1]:find("crafting: shelter BP_Station_Spinning_Wheel_C_7", 1, true)
          and logs[1]:find("roof yes 1/1", 1, true) and logs[1]:find("needs 38%", 1, true), logs[1])
    local n0 = traces
    C.W.shelter(fapi, wheel, { 0, 0, 0 })
    check("shelter W: one station's verdict is kept a few seconds (no second ray set)", traces == n0)
    -- a tree in the way is passed through: the wall behind it still counts; with only trees round it, nothing does
    local hits_tree = C.W.shelter_cast(fapi, { 0, 0, 1 }, { 0, -20, 1 }, "BP_Station_Spinning_Wheel_C_7", false)
    check("shelter cast: the station itself is passed, the wall behind counts", hits_tree == true)
    local BW2 = { trace = function(_, a, b)
        if a.Y > -400 then return true, hit_out(tree, { a.X / 100, -4.5, a.Z / 100 }) end
        return false, {}
    end }
    local fapi2 = { module = function(n) if n == "sense" then return { U = FU } elseif n == "build" then return { W = BW2 } end end, now = function() return 0 end }
    check("shelter cast: a tree is no building piece", C.W.shelter_cast(fapi2, { 0, 0, 1 }, { 0, -20, 1 }, "x", false) == false)
    check("shelter cast: ... unless the component counts any actor", C.W.shelter_cast(fapi2, { 0, 0, 1 }, { 0, -20, 1 }, "x", true) == true)
    -- no rays readable (a rule only): the old upward line, marked as such, and no side verdict
    local bare = obj({ __name = "BuildingShelter", InteractionRequirements = 0, RequiresShelterText = { text = " needs more surrounding shelter." } })
    local wheel2 = obj({ __name = "BP_Station_Spinning_Wheel_C_8", BuildingShelter = bare, K2_GetActorRotation = function() return { Yaw = 0 } end })
    local got2 = C.W.shelter(fapi, wheel2, { 0, 0, 0 })
    check("shelter W: no rays read -> the upward line, said so, sides unknown", got2 and got2.roof == "yes" and got2.side_n == nil
          and got2.sheltered == nil and (C.shelter_facts(got2) or ""):find("anything counts", 1, true), C.shelter_facts(got2))
    C.state().shelter_seen = nil
end

print(string.format("test_crafting: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
