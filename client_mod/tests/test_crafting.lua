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

local MOVE = {}
function MOVE.go_to(log, pos) F.goal = { pos[1], pos[2], pos[3] }; F.moves = (F.moves or 0) + 1; return { ok = true } end
function MOVE.status() if F.goal then F.pos, F.goal = F.goal, nil end; return { mode = "idle", result = { status = "arrived" } } end
function MOVE.stop() F.goal = nil; return { ok = true } end

local INV = {}
function INV.interact_target()
    local best, bd
    local function consider(id, name, item, pos, reach)
        local d = d2(F.pos, pos)
        if d <= reach and (not best or d < bd) then best, bd = { actor = id, name = name, item = item }, d end
    end
    for _, s in ipairs(F.stations) do consider(s.id, s.name, nil, s.position, 3.0) end
    for _, it in ipairs(F.items) do consider(it.id, it.name, it.item, it.position, 1.5) end
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

local SENSE = { local_pawn = function() return { AddMovementInput = function() end } end, local_pc = function() return {} end }

local api = {
    module = function(n)
        if n == "skills" then return SK elseif n == "move" then return MOVE elseif n == "inventory" then return INV
        elseif n == "sense" then return SENSE elseif n == "gather_profiles" then return GP end
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
            for _, o in ipairs(rec.outputs) do
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
    st.results[#st.results + 1] = { seq = st.seq, result = code, recipe = rid, count = count }
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
do -- held-out: an item absent from every fixture above resolves from the catalog by display name
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
    local leaf = t.root.inputs[1].inputs[1]
    check("cycle guard", leaf.status == "cycle", leaf and leaf.status)
    check("cycle reported missing", #t.missing == 1)
    C.set_data(REAL)
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
    check("proc: inputs + fuel dragged (3 moves)", F.drags == 3, F.drags)
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
    reset({ stations = { TABLE(), FURNACE({ res = { { slot = 0, item = "ITEM_Resources_IronOre", name = "Iron Ore", count = 3 } } }) } })
    local rows = api.census_things()
    local ex = C.state_extras(api, { interactables = rows })
    local fu
    for _, s in ipairs(ex.stations_nearby or {}) do if s.station == "Furnace" then fu = s end end
    check("extras: two stations", ex.stations_nearby and #ex.stations_nearby == 2)
    check("extras: furnace contents", fu and fu.contents and fu.contents[1] == "Iron Ore x3", fu and fu.contents and fu.contents[1])
    check("extras: cached", C.state_extras(api, { interactables = {} }) == ex)
end
for name in pairs(C.HANDLERS) do
    check("manifest entry " .. name, C.MANIFEST[name] and C.MANIFEST[name].description and C.MANIFEST[name].args)
    check("needs entry " .. name, C.NEEDS[name] ~= nil)
end
check("manifest: craft is an action, plan is read", C.MANIFEST.craft.kind == "action" and C.MANIFEST.craft_plan.kind == "read")

print(string.format("test_crafting: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
