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
    for _, s in ipairs(steps or {}) do if s["do"] == what and (key == nil or s[key] == val) then return s end end
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
        elseif n == "sense" then return SENSE elseif n == "gather_profiles" then return GP
        elseif n == "input" then return INPUTF end
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
    check("tree: alternatives unresolved", t.root.status == "choices_unresolved", t.root.status)
    check("tree: no unconditional steps with choices", t.steps == nil)
    check("tree: input acquisition options exposed", #t.root.inputs >= 2 and t.root.inputs[1].options_total >= 1)
    local cs = has_step(t.steps, "craft", "recipe", "RECIPE_Pickaxe_Stone")
    check("tree: no premature craft step", cs == nil)
    -- with the inputs carried the root is ready
    ctx.have = { ITEM_Resources_Wood_Ash = 6, ITEM_Resources_Stone = 8 }
    t = C.plan_tree({ item = "ITEM_Pickaxe_Stone" }, 1, ctx)
    check("tree: carried inputs do not prove execution", t.ready == nil and t.root.status == "execution_unknown" and t.root.suggestion and t.root.suggestion.conditional, t.root.status)
    -- the shared pool: 2 pickaxes need 12 ash, 6 carried -> gather 6 more
    t = C.plan_tree({ item = "ITEM_Pickaxe_Stone" }, 2, ctx)
    local g
    for _, v in ipairs(t.root.inputs or {}) do if v.item == "ITEM_Resources_Wood_Ash" then g = v end end
    check("tree: pool counts carried once", g and g.need == 12 and g.observed_have == 6, g and g.observed_have)
end
do -- alternatives listed; locked recipes carry their unlock text with station names
    local ctx = { have = {}, unlocked = U({ "RECIPE_Process_BronzeBar" }), near = near("Furnace"), gather_for = C.W.gather_for(api) }
    local t = C.plan_tree({ item = "ITEM_Resources_BronzeBar" }, 2, ctx)
    check("tree: bronze bar exposes recipes", t.root.options and t.root.options_total >= 1)
    check("tree: bronze alternatives listed", t.root.options and t.root.options_total >= 2, t.root.options_total)
    check("tree: bronze alternatives not flattened", t.steps == nil)
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
    local t = C.plan_tree({ item = "ITEM_A" }, 1, { have = {}, count_status = {status="complete",count_semantics="exact"}, unlocked = U({ "R_A", "R_B" }), near = near("Bench") })
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
do -- the output lies at the station, whose interaction wins a near miss (live 2026-10-26: "the game targets
   -- BP_Station_Campfire_C, not the Clean Water"): he stands where the station is not behind the item
    reset({ stations = { FURNACE() }, unlocked = U({ "RECIPE_Process_IronBar" }),
            have = { ITEM_Resources_IronOre = 3, ITEM_Fuel_Resources_Charcoal = 1 } })
    F.station_behind = true
    local r = run({ recipe = "RECIPE_Process_IronBar" })
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
    for _ = 1, 200 do T = T + 0.25; res = SK._episode_poll(api, e, T); if res then break end end
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
    check("craft_plan: execution remains unknown", r.ok and r.data.ready == nil and r.data.root.status == "execution_unknown" and r.data.root.suggestion.conditional)
    r = C.HANDLERS.craft_plan(nil, {}, { api = api })
    check("craft_plan: invalid args", r.reason == "invalid_args")
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
              and r.data.total == #hits and r.data.candidates[1].category == "Item.Equipment.Tool.Hatchet"
              and r.data.truncated == (#hits > #r.data.candidates))
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
    local r = C.HANDLERS.craft_plan(nil, { item = "special" }, { api = api })
    check("category: singular detail is truthful", r.reason == "ambiguous_target" and r.data.total == 1
          and not r.data.truncated and not r.data.detail:find("these items", 1, true))
    r = C.HANDLERS.recipes(nil, { item = "bundle" }, { api = api })
    check("category: bounded sorted candidates", r.reason == "ambiguous_target" and r.data.total == 17
          and #r.data.candidates == 15 and r.data.truncated and r.data.candidates[1].item < r.data.candidates[2].item)
    check("category: exact name wins", C.resolve_item("One Object") == "ITEM_only")
    check("category: unique substring wins", C.resolve_item("One Obj") == "ITEM_only")
    local _, none = C.resolve_item("does-not-exist")
    check("category: absent is unknown", #none == 0)
    C.set_data(REAL)
end
do -- unknown unlocks and raw condition bundles remain distinct and read-only
    local path = "/fixture/ITEM_Potion"
    local q1 = "ANY ITEMS[ Glowcap, Pebble ] AND ALL ACTORS[ BP_Station_Kettle_C ]"
    local q2 = "UNKNOWN_FN[ x ] OR ALL ITEMS[ Berries ]"
    local fake = { items = { [path] = { id = "ITEM_Potion", name = "Potion" } },
                   stations = { Kettle = { name = "Brew Kettle", classes = { "BP_Station_Kettle_C" } } },
                   recipes = { R = { path = "/fixture/R", inputs = {}, outputs = {{ path, 1 }}, stations = { "Kettle" }, uq = {q1, q2} } } }
    C.set_data(fake)
    local locked = C.assess("R", 1, { have = {}, unlocked = {}, near = {} })
    check("unlock: confirmed locked retains exact queries", locked.status == "not_unlocked"
          and locked.unlock_queries[1] == q1 and locked.unlock_queries[2] == q2
          and locked.unlock:find("relation between conditions unknown", 1, true) ~= nil)
    local card = C.card(locked)
    check("unlock: card carries raw queries and context", card.unlock_queries[1] == q1
          and card.unlock_context:find("actor%-class interactions")
          and card.unlock_query_source == "generated recipe catalog (whitespace normalized)")
    local known = C.plan_tree({ recipe = "R" }, 1, { have = {}, unlocked = {}, near = {} })
    check("unlock: locked plan retains condition facts", known.root.status == "not_unlocked"
          and known.root.unlock_queries[2] == q2 and known.root.unlock_status == "locked")
    local unknown = C.plan_tree({ recipe = "R" }, 1, { have = {}, unlocked = nil, near = {} })
    check("unlock: unreadable state remains unknown without unlock step", unknown.root.status == "unlock_unknown"
          and not has_step(unknown.steps, "unlock") and unknown.root.unlock_queries[1] == q1)
    fake.recipes.R.uq = { q1 }
    local single = C.assess("R", 1, { have = {}, unlocked = {}, near = {} })
    check("unlock: one condition has no invented relation", single.unlock_queries[1] == q1
          and not single.unlock:find("relation between conditions", 1, true))
    C.set_data(REAL)
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

do -- held-out acquisition alternatives and count provenance
    local A,B,CUR,GOAL = "/fixture/ITEM_A", "/fixture/ITEM_B", "/fixture/ITEM_Currency", "/fixture/ITEM_Goal"
    local fake = {items={ [A]={id="ITEM_A",name="A"}, [B]={id="ITEM_B",name="B"},
                          [CUR]={id="ITEM_Currency",name="Currency"}, [GOAL]={id="ITEM_Goal",name="Goal"} },
        stations={Bench={name="Bench",kind="crafting",classes={"BP_Bench_C"}},
                  Merchant={name="Merchant",kind="crafting",classes={}}},
        recipes={ R_Goal={inputs={{B,1},{A,2}},outputs={{GOAL,1}},stations={"Bench"}},
                  R_B={inputs={{A,2}},outputs={{B,1}},stations={"Merchant"}} } }
    C.set_data(fake)
    local function sources(item) if item=="ITEM_B" then return {"pickup_b", "extract_b"} end return {} end
    local ctx={have={ITEM_A=3},count_status={status="complete",count_semantics="exact"},
               unlocked=U({"R_Goal","R_B"}),near=near("Bench"),gather_for=sources}
    local t=C.plan_tree({recipe="R_Goal"},1,ctx)
    local b,a=t.root.inputs[1],t.root.inputs[2]
    check("options: pinned root preserves OR alternatives", b.options_total==3 and #b.options==3 and t.steps==nil and t.missing==nil)
    check("options: gather capability not availability", b.options[1].type=="gather" and b.options[1].availability=="unknown")
    local recipe
    for _,opt in ipairs(b.options) do if opt.type=="recipe" then recipe=opt end end
    check("options: recipe AND inputs and unknown execution", recipe and #recipe.inputs==1 and recipe.inputs[1].item=="ITEM_A" and recipe.execution_capability=="unknown")
    check("options: sibling uses conservative branch pool", a.observed_have==1 and a.have_semantics=="lower_bound" and a.sufficiency=="unknown")
    ctx.have={};ctx.count_status={status="partial",count_semantics="lower_bound"}
    t=C.plan_tree({recipe="R_Goal"},1,ctx)
    b=t.root.inputs[1]
    check("options: incomplete zero unknown", b.observed_have==0 and b.sufficiency=="unknown" and b.short==nil and b.options[1].quantity_semantics=="upper_bound")
    ctx.have={ITEM_B=1,ITEM_A=3}
    t=C.plan_tree({recipe="R_Goal"},1,ctx)
    check("options: lower bound enough proves snapshot sufficiency", t.root.inputs[1].sufficiency=="enough" and t.root.inputs[2].sufficiency=="enough")
    ctx.have={ITEM_A=1};ctx.count_status={status="complete",count_semantics="exact"};ctx.gather_for=nil
    t=C.plan_tree({recipe="R_Goal"},1,ctx)
    check("options: exact insufficient short", t.root.inputs[2].sufficiency=="short" and t.root.inputs[2].short~=nil)
    ctx.have={ITEM_Goal=9,ITEM_B=1,ITEM_A=2}
    t=C.plan_tree({recipe="R_Goal"},1,ctx)
    check("options: explicit recipe requests one craft even if output carried", t.root.crafts==1 and t.root.output_count==1)
    C.set_data(REAL)
end

do -- bounded choices, vendor metadata, and multiple independent profiles
    local X,G="/heldout/ITEM_X", "/heldout/ITEM_G"
    local recipes={R_G={inputs={{X,1}},outputs={{G,1}},stations={"Bench"}}}
    for i=1,10 do recipes[string.format("R_%02d",i)]={inputs={},outputs={{X,1}},stations={i==1 and "Trader" or "Bench"}} end
    local fake={items={[X]={id="ITEM_X",name="X"},[G]={id="ITEM_G",name="G"}},
        stations={Bench={name="Bench",kind="crafting",classes={}}, Trader={name="Trader",kind="crafting",vendor=true,classes={}}}, recipes=recipes}
    C.set_data(fake)
    local all={"R_G"}; for i=1,10 do all[#all+1]=string.format("R_%02d",i) end
    local ctx={have={},count_status={status="complete",count_semantics="exact"},unlocked=U(all),near=near("Bench")}
    local t=C.plan_tree({recipe="R_G"},1,ctx)
    local x=t.root.inputs[1]
    check("options: capped deterministic alternatives", x.options_total==10 and #x.options==8 and x.options_truncated and t.truncated and not t.steps)
    check("options: confirmed vendor unsupported", x.options[1].recipe=="R_01" and x.options[1].execution_capability=="unsupported_vendor")
    local profile_api={module=function(n) return n=="gather_profiles" and {RESOURCES={z={item="ITEM_X"},a={item="ITEM_X"},b={item="other"}}} end}
    local gather=C.W.gather_options(profile_api)("ITEM_X")
    check("options: all matching profiles ordered", #gather==2 and gather[1]=="a" and gather[2]=="z")
    check("options: absent profile does not invent source", #C.W.gather_options(profile_api)("ITEM_Missing")==0)
    ctx.count_status={status="complete",count_semantics="bad"}
    t=C.plan_tree({recipe="R_G"},1,ctx)
    check("options: malformed exact status unknown", t.root.inputs[1].have_semantics=="lower_bound" and t.root.inputs[1].sufficiency=="unknown")
    C.set_data(REAL)
end

do -- observed generic station and enough inputs do not establish execution capability
    local input, goal = "/heldout/ITEM_Input", "/heldout/ITEM_Product"
    local fake={items={[input]={id="ITEM_Input",name="Input"},[goal]={id="ITEM_Product",name="Product"}},
        stations={Bench={name="Bench",kind="crafting",classes={"BP_GenericBench_C"}}},
        recipes={R_Product={inputs={{input,2}},outputs={{goal,1}},stations={"Bench"}}}}
    C.set_data(fake)
    local ctx={have={ITEM_Input=2},count_status={status="complete",count_semantics="exact"},
               unlocked=U({"R_Product"}),near=near("Bench")}
    local t=C.plan_tree({recipe="R_Product"},1,ctx)
    check("execution: enough exact input retained", t.root.inputs[1].sufficiency=="enough" and t.root.inputs[1].observed_have==2)
    check("execution: observed station retained", t.root.station_id=="Bench_1" and t.root.unlock_status=="unlocked")
    check("execution: capability unknown and no ready", t.root.execution_capability=="unknown" and t.root.status=="execution_unknown" and t.ready==nil)
    check("execution: suggestion explicitly conditional", t.root.suggestion and t.root.suggestion.conditional==true and t.steps==nil)
    ctx.have={ITEM_Input=1}; t=C.plan_tree({recipe="R_Product"},1,ctx)
    local craft=has_step(t.steps,"craft")
    check("execution: future craft step conditional", craft and craft.conditional==true and craft.ready==nil)
    C.set_data(REAL)
end

print(string.format("test_crafting: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
