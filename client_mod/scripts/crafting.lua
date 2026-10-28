-- crafting: CRAFTING AT REAL STATIONS on Claude's own client (route R2, task R2.19), through the
-- game's own client paths only (design docs/design/r2-crafting.md, reviewed against PRINCIPLES.md):
--
--   bench (crafting station):  approach + face + ONE interact press (the game opens the station's
--       menu: Client_ToggleCraftingMenu -> CraftingUIAPI.CurrentStation) -> the menu's own handlers
--       CraftingUIAPI:SelectRecipe(recipe) + SendCraftRequest(count) (what the craft button runs;
--       [UNVERIFIED] until the capture hooks confirm SendCraftRequest -> InventoryController:CraftRecipe)
--       -> the server's verdict from a READ-ONLY post-hook on
--       InventoryController:Client_OnCraftingResultHandler -> inventory delta verify -> close the menu.
--   processing station (Furnace, Kiln, Campfire, ...): open it the same way
--       (ProcessingStationUIAPI.ProcessingStationComponent) -> the inventory UI's own drag handler
--       InventoryUIAPI:HandleSplitToExternalSlot into the station's Resources / Fuel inventories ->
--       ProcessingStationUIAPI:ToggleProcessingStationStarted (the start button) -> wait on
--       bStationRunning / outputs -> collect: stored outputs by InventoryUIAPI:HandleExternalQuickTransfer,
--       world-item outputs by the skills.lua pickup episode (only output ids that appeared after start).
--   Never a Server_* call, never a write to inventory or station state (tests/test_principles.py).
--
-- Read-only planning (pure functions over mod/body/recipe_data.lua, GENERATED from live game data):
--   assess / candidates  every recipe for an item with its status (unlocked, inputs, station near)
--   plan_tree            goal -> tree of craft / gather / obtain / unlock steps (ALL alternatives listed)
--   craftable            what he can make right now
-- The MODEL decides what to make: `craft` crafts exactly one recipe from what he carries and never
-- runs the plan tree itself (no hidden sub-crafts or gathers); when an item has several viable
-- recipes and none was pinned it answers ambiguous_target with the candidates.
--
-- Shared stations (Luis, 2026-10-25, binding): he MAY use stations holding other players' items and
-- the station's own fuel; he reports truthfully what was there (station_before), what fuel he used
-- (fuel_used) and what he collected (collected).
--
-- Prior art (search-before-building, design note): Mineflayer/Mindcraft craft = recipe resolved from
-- game data + walk to the table + the client's own window click; Mindcraft's crafting-plan text;
-- Plancraft's dependency tree; ported from the legacy mod/body/crafting.lua plan/check.
--
-- Contract: HANDLERS[tool](log, args, ctx) with ctx.api = client_bridge M.API (as skills.lua).
-- W = the engine touches (tests replace them).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")

local M = {}

M.cfg = {
    station_radius_m = 60,  -- stations further than this are not "near"
    stand_m = 1.6,          -- stand this far from the station's origin, on the line towards him
    reach_m = 2.8,          -- within this (2D, to the origin) he faces + presses
    approach_tol_m = 0.8,
    approaches = 3,
    face_s = 3.0,
    open_wait_s = 3.0,      -- after the press: wait this long for the game to open the station's menu
    presses = 2,
    result_wait_s = 6.0,    -- after SendCraftRequest: wait for the server's verdict + the inventory
    move_wait_s = 3.0,      -- after each drag into the station: wait for its inventory to show it
    start_wait_s = 4.0,     -- after the start button: wait for bStationRunning
    proc_slack = 1.5,       -- processing wait = catalog seconds * slack + extra
    proc_extra_s = 20,
    collect_radius_m = 6,   -- output world items this close to the station
    magnet_wait_s = 4.0,    -- outputs may fly to him by themselves first
    lease_s = 15,
    unlock_ttl_s = 10,
    max_count = 50,
    plan_depth = 6,
    list_limit = 25,
}

local W = {}
M.W = W

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end
local function dist2d(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
end
local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
local function r1(x) return x and math.floor(x * 10 + 0.5) / 10 or nil end
local function state() -- hot-reload-safe live state (hook records)
    local s = rawget(_G, "DWCraft")
    if not s then s = { results = {}, seq = 0 }; _G.DWCraft = s end
    return s
end
M.state = state

-- "/Game/.../RECIPE_X.RECIPE_X" | "RECIPE_X" -> "RECIPE_X"
local function asset(x)
    if type(x) ~= "string" then return nil end
    local a = x:match("%.([^%./]+)$") or x:match("([^/]+)$") or x
    return (a:gsub("@.*$", ""))
end
M.asset = asset

-- ------------------------------------------------------------------ catalog
local DATA -- recipe_data table (cached in _G across hot reloads: it is ~1 MB of Lua)
function M.set_data(d) DATA = d; M._idx = nil end
function M.data()
    if DATA then return DATA end
    DATA = rawget(_G, "DWRecipeData")
    if not DATA then
        DATA = assert(loadfile(ROOT .. "/mod/body/recipe_data.lua"))()
        _G.DWRecipeData = DATA
    end
    return DATA
end

-- Indexes over the catalog (built once per data table).
local function idx()
    local d = M.data()
    if M._idx and M._idx.data == d then return M._idx end
    local I = { data = d, id_of = {}, name_of = {}, path_of = {}, by_output = {}, by_station = {}, class_sid = {}, ambiguous = {} }
    for p, it in pairs(d.items or {}) do
        local id = it.id or asset(p)
        I.id_of[p], I.name_of[p] = id, it.name
        if I.path_of[id] and I.path_of[id] ~= p then I.ambiguous[id] = true else I.path_of[id] = p end
    end
    local function id_of(p)
        I.id_of[p] = I.id_of[p] or asset(p)
        local id=I.id_of[p]
        if I.path_of[id] and I.path_of[id]~=p then I.ambiguous[id]=true else I.path_of[id]=p end
        return id
    end
    for rid, r in pairs(d.recipes or {}) do
        for _, o in ipairs(r.outputs or {}) do
            local id = id_of(o[1])
            I.path_of[id] = I.path_of[id] or o[1]
            local l = I.by_output[id] or {}; I.by_output[id] = l; l[#l + 1] = rid
        end
        for _, c in ipairs(r.inputs or {}) do local id = id_of(c[1]); I.path_of[id] = I.path_of[id] or c[1] end
        for _, sid in ipairs(r.stations or {}) do
            local l = I.by_station[sid] or {}; I.by_station[sid] = l; l[#l + 1] = rid
        end
    end
    for _, l in pairs(I.by_output) do table.sort(l) end
    for _, l in pairs(I.by_station) do table.sort(l) end
    for sid, st in pairs(d.stations or {}) do
        for _, cw in ipairs(st.classes or {}) do I.class_sid[cw] = I.class_sid[cw] or sid end
    end
    M._idx = I
    return I
end
M.index = idx

local function item_id(path) return idx().id_of[path] or asset(path) end
local function item_name(path) return idx().name_of[path] end
local function name_of_id(id) local p = idx().path_of[id]; return (p and idx().name_of[p]) or id end
M.item_name_of = name_of_id
local function station_info(sid) return (M.data().stations or {})[sid] end
local function station_name(sid) local st = station_info(sid); return (st and st.name) or sid end
local function recipe_of(rid) return (M.data().recipes or {})[rid] end
-- The station type a census row's class word belongs to (exact class word: some station BPs subclass
-- others, so IsA would mis-type them; DISCOVERIES "Crafting: recipes, stations and unlocks").
function M.station_type(class_word) return class_word and idx().class_sid[class_word] or nil end

-- A recipe by id (case-insensitive) or object path.
function M.recipe(q)
    if not need_str(q) then return nil end
    local R = M.data().recipes
    if R[q] then return q end
    local want = lower(asset(q))
    for rid, r in pairs(R) do if lower(rid) == want or r.path == q then return rid end end
end

-- An item id from an id, a display name (exact, case-insensitive), else a UNIQUE substring among
-- craftable outputs. Returns id | nil, {candidates}.
function M.resolve_item(q)
    if not need_str(q) then return nil end
    local I = idx()
    if I.path_of[q] then return q end
    if I.id_of[q] then return I.id_of[q] end
    local lq = lower(q)
    for id in pairs(I.path_of) do if lower(id) == lq then return id end end
    local exact = {}
    for p, n in pairs(I.name_of) do if lower(n) == lq then exact[#exact + 1] = I.id_of[p] end end
    if #exact > 1 then -- the same display name on several items: prefer the craftable ones
        local made = {}
        for _, id in ipairs(exact) do if I.by_output[id] then made[#made + 1] = id end end
        if #made >= 1 then exact = made end
    end
    table.sort(exact)
    if #exact == 1 then return exact[1] end
    if #exact > 1 then return nil, exact end
    local hits = {}
    for id in pairs(I.by_output) do
        local n = lower(name_of_id(id))
        if n:find(lq, 1, true) or lower(id):find(lq, 1, true) then hits[#hits + 1] = id end
    end
    table.sort(hits)
    if #hits == 1 then return hits[1] end
    if #hits > 0 then return nil, hits end
    local want = lower(q):match("^%s*(.-)%s*$")
    for id in pairs(I.by_output) do
        local item = (M.data().items or {})[I.path_of[id]] or {}
        local category = item.category
        if type(category) == "string" then
            local tag = lower(category)
            local leaf = tag:match("([^%.]+)$")
            if want ~= "" and (want == tag or want == leaf) then hits[#hits + 1] = id end
        end
    end
    table.sort(hits)
    return nil, hits, #hits > 0 and "category" or nil
end

-- Suggestions are metadata, never an implicit selection, even for one match.
local function item_resolution_failure(api, query, hits, kind, limit, ctx)
    local c = {}
    for i = 1, math.min(#(hits or {}), limit) do
        local id = hits[i]
        local item = (M.data().items or {})[idx().path_of[id]] or {}
        local category = not idx().ambiguous[id] and type(item.category)=="string" and item.category~="" and item.category or nil
        local recipes, seen = {}, {}
        for _, rid in ipairs(idx().by_output[id] or {}) do
            if not seen[rid] then
                seen[rid] = true
                local unlock = type(ctx and ctx.unlocked)=="table" and ctx.unlocked[rid]==true and "unlocked" or "unknown"
                recipes[#recipes+1] = {recipe=rid,unlock_status=unlock}
            end
        end
        c[i] = { item = id, name = name_of_id(id), category = category, recipes = recipes }
    end
    local total = #(hits or {})
    local detail = total == 0 and ("I don't know how to make " .. tostring(query) .. ".")
        or (total == 1 and ("\"" .. query .. "\" matches this item; choose it explicitly.")
            or ("\"" .. query .. "\" matches these items; choose one explicitly."))
    return api.fail(total > 0 and "ambiguous_target" or "unknown_recipe",
                    { item = query, candidates = c, total = total, truncated = total > #c, detail = detail })
end

-- Unlock rule text with actor class words turned into station names (data, not code).
local function unlock_text(r)
    if type(r.uq) ~= "table" or #r.uq == 0 then return nil end
    local out = {}
    for _, q in ipairs(r.uq) do
        out[#out + 1] = (q:gsub("(BP_[%w_]+_C)", function(cw)
            local sid = idx().class_sid[cw]
            return sid and station_name(sid) or cw
        end))
    end
    return table.concat(out, "; ") .. (#out > 1 and " (relation between conditions unknown)" or "")
end
M.unlock_text = unlock_text
local UNLOCK_CONTEXT = "Progress records item first pickups and actor-class interactions separately; "
    .. "the relationship between separate condition queries is not established."

-- ------------------------------------------------------------------ the pure plan (one recipe)
local function per_craft(r, item)
    for _, o in ipairs(r.outputs or {}) do if item_id(o[1]) == item then return o[2] end end
    return (r.outputs and r.outputs[1] and r.outputs[1][2]) or 1
end

-- What `crafts` crafts of recipe rid at station type sid consume, produce and take (seconds model
-- UNVERIFIED, as in the legacy plan; the drift check measures it).
function M.plan(rid, crafts, sid)
    local r = recipe_of(rid)
    if not r then return nil end
    sid = sid or (r.stations or {})[1]
    local st = sid and station_info(sid)
    local p = { recipe = rid, crafts = crafts, station = sid, kind = st and st.kind or "crafting", inputs = {}, outputs = {} }
    for _, c in ipairs(r.inputs or {}) do p.inputs[#p.inputs + 1] = { path = c[1], item = item_id(c[1]), name = item_name(c[1]), count = c[2] * crafts } end
    for _, c in ipairs(r.outputs or {}) do p.outputs[#p.outputs + 1] = { path = c[1], item = item_id(c[1]), name = item_name(c[1]), count = c[2] * crafts } end
    if p.kind == "processing" then
        local pt = r.pt or {}
        local lo, hi = tonumber(pt[1]) or 0, tonumber(pt[2]) or tonumber(pt[1]) or 0
        local rate = tonumber(st and st.rate) or 1
        if rate <= 0 then rate = 1 end
        p.seconds = ((lo + hi) / 2) / rate * crafts
        p.fuels = {}
        if r.fuel then
            for _, c in ipairs(r.fuel) do p.fuels[#p.fuels + 1] = { path = c[1], item = item_id(c[1]), name = item_name(c[1]), count = c[2] * crafts, fixed = true } end
        else
            for _, f in ipairs(st and st.fuels or {}) do
                local fv = tonumber((M.data().items[f] or {}).fuel) or 0
                if fv > 0 then
                    p.fuels[#p.fuels + 1] = { path = f, item = item_id(f), name = item_name(f), fuel_value = fv,
                                              count = math.max(1, math.ceil(p.seconds / fv)) }
                end
            end
        end
    else
        local t, tmax, qm = tonumber(r.t) or 0, tonumber(r.tmax), tonumber(r.qm) or 1
        local s = t * (qm ^ math.max(0, crafts - 1))
        if tmax and tmax > 0 then s = math.min(s, tmax) end
        p.seconds = s
    end
    return p
end

-- ------------------------------------------------------------------ assessing candidates (pure)
-- ctx = {have = {item_id = n}, unlocked = {rid = true} | nil (unknown), near = {sid = station row}}
-- -> {recipe, item, name, station, station_name, kind, crafts, viable, status, missing = {...},
--     unlock?, vendor?, station_row?, detail}
-- status: ready | not_unlocked | missing_input | no_station | vendor | no_station_type
local RANK = { ready = 5, missing_input = 4, no_station = 3, not_unlocked = 2, unlock_unknown = 2, vendor = 1, no_station_type = 0 }
M.RANK = RANK

function M.assess(rid, crafts, ctx)
    local r = recipe_of(rid)
    local p = M.plan(rid, crafts)
    local a = { recipe = rid, crafts = crafts, missing = {}, inputs = {}, outputs = {} }
    local all_carried_known = true
    local out1 = p.outputs[1]
    a.item, a.name = out1 and out1.item, out1 and out1.name
    for _, c in ipairs(p.inputs) do
        local observation = ctx.native_count and (idx().ambiguous[c.item] and {status="unknown",reason="ambiguous_item_identity"} or ctx.native_count(c.path)) or nil
        local have
        if observation and observation.status == "observed" then have=observation.count
        elseif not ctx.native_count then have=(ctx.have or {})[c.item] or 0 end
        a.inputs[#a.inputs + 1] = { item = c.item, path = c.path, name = c.name, need = c.count, have = have,
                                   count_scope = observation and observation.scope, count_status = observation and observation.status }
        if type(have) ~= "number" or have < c.count then all_carried_known = false end
        if type(have) == "number" and have < c.count then a.missing[#a.missing + 1] = { item = c.item, name = c.name, need = c.count, have = have, scope = observation and observation.scope } end
    end
    a.carried_sufficient = ctx.native_count and all_carried_known or nil
    for _, c in ipairs(p.outputs) do a.outputs[#a.outputs + 1] = { item = c.item, name = c.name, count = c.count } end
    -- station: the nearest live one of any type that crafts it
    local best
    for _, sid in ipairs(r.stations or {}) do
        local row = (ctx.near or {})[sid]
        if row and (not best or (row.distance or 1e9) < (best.distance or 1e9)) then best = row end
    end
    local sid = best and best.station or (r.stations or {})[1]
    a.station, a.station_name, a.kind = sid, sid and station_name(sid) or nil, sid and (station_info(sid) or {}).kind or nil
    a.station_row = best
    local vendor = sid and (station_info(sid) or {}).vendor == true
    local unl
    if ctx.unlocked == nil then unl = nil else unl = ctx.unlocked[rid] == true end
    if not unl then
        a.unlock = unlock_text(r)
        if type(r.uq) == "table" and #r.uq > 0 then
            a.unlock_queries, a.unlock_context = r.uq, UNLOCK_CONTEXT
            a.unlock_query_source = "generated recipe catalog (whitespace normalized)"
        end
    end
    if #(r.stations or {}) == 0 then
        a.status, a.detail = "no_station_type", "nothing in the game crafts " .. tostring(a.name or rid) .. " at a station"
    elseif vendor then
        a.status, a.vendor = "vendor", true
        a.detail = (a.name or rid) .. " is bought from " .. tostring(a.station_name) .. ", and I can't trade with vendors yet"
    elseif unl == false then
        a.status = "not_unlocked"
        a.detail = "I haven't unlocked " .. tostring(a.name or rid) .. " yet" .. (a.unlock and (" (catalog conditions: " .. a.unlock .. ")") or "")
    elseif unl == nil then
        a.status, a.detail = "unlock_unknown", "I can't read which recipes I've unlocked right now"
    elseif #a.missing > 0 and not ctx.native_count then
        local m = a.missing[1]
        a.status = "missing_input"
        a.detail = "I need " .. m.need .. " " .. tostring(m.name or m.item) .. " for that and I have " .. m.have
            .. (#a.missing > 1 and (" (and " .. (#a.missing - 1) .. " more thing" .. (#a.missing > 2 and "s" or "") .. " missing)") or "")
    elseif not best then
        local names = {}
        for _, s in ipairs(r.stations or {}) do names[#names + 1] = station_name(s) end
        a.status = "no_station"
        a.detail = "there's no " .. table.concat(names, " or ") .. " near here"
    else
        a.status = "ready"
    end
    a.viable = a.status == "ready"
    a.rank = RANK[a.status] or 0
    return a
end

-- Every recipe that makes item_id, assessed, best first (ranked as INFORMATION; the model chooses).
function M.candidates(item_id, count, ctx)
    local out = {}
    for _, rid in ipairs(idx().by_output[item_id] or {}) do
        local r = recipe_of(rid)
        local crafts = math.ceil((count or 1) / math.max(1, per_craft(r, item_id)))
        out[#out + 1] = M.assess(rid, crafts, ctx)
    end
    table.sort(out, function(x, y)
        if x.rank ~= y.rank then return x.rank > y.rank end
        if #x.missing ~= #y.missing then return #x.missing < #y.missing end
        return x.recipe < y.recipe
    end)
    return out
end

-- Wire form of an assessment.
function M.card(a)
    local c = { recipe = a.recipe, name = a.name, item = a.item, crafts = a.crafts, status = a.status, station = a.station,
                station_name = a.station_name, kind = a.kind, inputs = a.inputs, outputs = a.outputs, detail = a.detail }
    if #a.missing > 0 then c.missing = a.missing end
    if a.unlock then c.unlock = a.unlock end
    if a.unlock_queries then
        c.unlock_queries, c.unlock_context, c.unlock_query_source = a.unlock_queries, a.unlock_context, a.unlock_query_source
    end
    if a.station_row then c.station_id, c.station_distance = a.station_row.id, a.station_row.distance end
    return c
end

-- ------------------------------------------------------------------ the crafting tree (pure, read-only)
-- plan_tree(goal = {item | recipe}, count, ctx) reports observed counts and bounded
-- OR acquisition choices; each recipe option has AND inputs. A single option is
-- represented directly by its node. Steps are omitted when choices are unresolved.
-- Recipe execution capability is unknown unless independently established; a
-- station observation and sufficient inputs alone are not proof of craft readiness.
function M.plan_tree(goal, count, ctx)
    count = math.max(1, math.floor(tonumber(count) or 1))
    ctx = ctx or {}
    local cs = ctx.count_status
    local exact = type(cs) == "table" and cs.status == "complete" and cs.count_semantics == "exact"
    local max_options, max_nodes = 8, 100
    local used, truncated = 0, false
    local function clone(pool)
        local out = { values = {}, certainty = copy(pool.certainty), provenance = copy(pool.provenance), exact = pool.exact }
        for k, v in pairs(pool.values) do out.values[k] = v end
        return out
    end
    local function merge(pool, branches, incomplete)
        if incomplete then
            for k in pairs(pool.values) do pool.values[k] = 0; pool.certainty[k] = false end
            pool.exact = false
            return
        end
        if #branches == 0 then return end
        local keys={}
        for k in pairs(pool.values) do keys[k]=true end
        for _,branch in ipairs(branches) do for k in pairs(branch.values) do keys[k]=true end end
        for k in pairs(keys) do
            local prior=pool.values[k]
            local minimum, maximum = prior or math.huge, 0
            local all_known = prior == nil or pool.certainty[k] == true
            for _, p in ipairs(branches) do
                local v = p.values[k]
                if v==nil then v=0; all_known=false end
                minimum, maximum = math.min(minimum, v), math.max(maximum, v)
                if not p.exact then pool.exact = false end
                if not p.certainty[k] then all_known=false end
            end
            pool.values[k] = minimum
            if minimum ~= maximum then pool.exact = false end
            pool.certainty[k] = all_known and minimum == maximum
            local sources={}
            for _,branch in ipairs(branches) do
                for _,obs in ipairs(branch.provenance[k] or {}) do sources[#sources+1]=obs end
            end
            if #sources>0 then pool.provenance[k]=sources end
        end
    end
    local function observed(pool, item, need)
        local path = ctx.native_count and not idx().ambiguous[item] and idx().path_of[item] or nil
        local key = ctx.native_count and (path or ("ambiguous:" .. item)) or item
        local value = pool.values[key]
        if value == nil and ctx.native_count then
            local result = path and ctx.native_count(path) or nil
            if result and result.status == "observed" then value = result.count; pool.certainty[key] = true; pool.provenance[key]={result}
            else value = 0; pool.certainty[key] = false; pool.provenance[key]=result and {result} or {} end
        end
        if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or value < 0 then
            if value ~= nil then pool.exact = false end
            value = 0
        end
        local n = math.min(value, need)
        pool.values[key] = value - n
        local known = ctx.native_count and pool.certainty[key] == true or (not ctx.native_count and pool.exact)
        local sufficiency = n >= need and "enough" or (known and "short" or "unknown")
        if ctx.native_count and not known then return nil, nil, "unknown", sufficiency, n, pool.provenance[key] end
        return value, n, known and "exact" or "lower_bound", sufficiency, n, pool.provenance[key]
    end
    local node, recipe_option
    recipe_option = function(rid, item, need, pool, depth, stack)
        local r = recipe_of(rid)
        local per = math.max(1, per_craft(r, item))
        local crafts = math.ceil(need / per)
        local a = M.assess(rid, crafts, { have = pool.values, unlocked = ctx.unlocked, near = ctx.near })
        local unl = ctx.unlocked == nil and "unknown" or (ctx.unlocked[rid] == true and "unlocked" or "locked")
        local station = a.station_row and "nearby" or "not_observed"
        local out = { type = "recipe", recipe = rid, item = item, crafts = crafts,
                      output_count = crafts * per, station = a.station, station_name = a.station_name,
                      station_id = a.station_row and a.station_row.id or nil, station_observation = station,
                      station_kind = a.kind, station_types = r.stations, unlock_status = unl,
                      execution_capability = a.vendor and "unsupported_vendor" or "unknown",
                      inputs = {}, status = a.status }
        if a.unlock then out.unlock = a.unlock end
        if a.unlock_queries then
            out.unlock_queries, out.unlock_context, out.unlock_query_source = a.unlock_queries, a.unlock_context, a.unlock_query_source
        end
        if a.status == "missing_input" and not pool.exact then out.status = "inventory_unknown"
        elseif a.status == "ready" then out.status = "execution_unknown"
        else out.detail = a.detail end
        stack[item] = true
        local all_enough, has_unknown, has_choices = true, false, false
        local steps, missing = {}, {}
        local ingredient_rows = M.plan(rid, crafts).inputs
        out.inputs_total = #ingredient_rows
        for _, ingredient in ipairs(ingredient_rows) do
            if used >= max_nodes then
                out.inputs_truncated, truncated, has_choices = true, true, true
                break
            end
            local child, child_steps, child_missing, unresolved = node(ingredient.item, ingredient.count, pool, depth + 1, stack)
            out.inputs[#out.inputs + 1] = child
            if child.sufficiency ~= "enough" then all_enough = false end
            if child.sufficiency == "unknown" then has_unknown = true end
            if unresolved then has_choices = true end
            for _, step in ipairs(child_steps) do steps[#steps + 1] = step end
            for _, m in ipairs(child_missing) do missing[#missing + 1] = m end
        end
        stack[item] = nil
        if ctx.native_count and all_enough and not has_unknown and a.station_row and unl == "unlocked" and not a.vendor then
            out.status = "execution_unknown"
            out.suggestion = { ["do"]="craft", recipe=rid, item=item, conditional=true, reason="execution_capability_unknown" }
        end
        if has_choices then out.plan_status = "choices_unresolved"
        elseif has_unknown then out.plan_status = "inventory_unknown"
        elseif not all_enough then out.plan_status = "craft_after"
        elseif out.status == "execution_unknown" or a.status == "ready" then out.plan_status = "execution_unknown"
        else out.plan_status = a.status end
        if a.status == "ready" and not a.vendor then
            out.suggestion = { ["do"] = "craft", recipe = rid, item = item, conditional = true,
                               reason = "execution_capability_unknown" }
        end
        if not has_choices then
            if a.status == "not_unlocked" then
                steps[#steps + 1] = { ["do"] = "unlock", recipe = rid, name = a.name, how = a.unlock,
                    unlock_queries = a.unlock_queries, unlock_context = a.unlock_context, unlock_query_source = a.unlock_query_source }
            elseif unl == "unlocked" and not a.station_row then
                steps[#steps + 1] = { ["do"] = "find_station", station = a.station, name = a.station_name, recipe = rid }
            end
            -- Unknown station execution is not presented as an unconditional craft step.
            if a.station_row and not a.vendor then
                steps[#steps + 1] = { ["do"] = "craft", recipe = rid, item = item, name = name_of_id(item),
                    crafts = crafts, count = crafts * per, station = a.station, station_name = a.station_name,
                    conditional = true, reason = "execution_capability_unknown" }
            end
        end
        return out, steps, missing, has_choices or has_unknown or a.status == "ready"
    end
    node = function(item, need, pool, depth, stack, pinned)
        used = used + 1
        local n = { item = item, name = name_of_id(item), need = need }
        if ctx.native_count then
            n.count_scope = "main_inventory"
            n.asset_path = not idx().ambiguous[item] and idx().path_of[item] or nil
        end
        local accounted
        if pinned then
            local snapshot = clone(pool)
            n.observed_have, n.have, n.have_semantics, n.sufficiency, accounted, n.count_observations = observed(snapshot, item, need)
        else
            n.observed_have, n.have, n.have_semantics, n.sufficiency, accounted, n.count_observations = observed(pool, item, need)
        end
        if n.sufficiency == "enough" and not pinned then n.status = "have"; return n, {}, {}, false end
        local remaining = pinned and need or (need - accounted)
        if n.sufficiency == "short" then n.short = remaining end
        if used > max_nodes or depth > M.cfg.plan_depth then
            n.status, n.options_total, n.options_truncated = "depth", 0, true
            truncated = true
            return n, {}, {}, true
        end
        if stack[item] then
            n.status = "cycle"
            local missing = n.sufficiency == "short" and { {item=item,name=n.name,count=remaining} } or {}
            return n, {}, missing, n.sufficiency ~= "short"
        end
        local specs = {}
        if not pinned and ctx.gather_for then
            local names = ctx.gather_for(item)
            if type(names) == "string" then names = { names } end
            if type(names) == "table" then
                local seen = {}
                for _, name in ipairs(names) do
                    if type(name) == "string" and not seen[name] then specs[#specs + 1] = { type="gather", resource=name }; seen[name] = true end
                end
            end
        end
        if pinned then specs[#specs + 1] = { type="recipe", recipe=pinned }
        else
            for _, rid in ipairs(idx().by_output[item] or {}) do
                local r = recipe_of(rid)
                if r and #(r.stations or {}) > 0 then specs[#specs + 1] = { type="recipe", recipe=rid } end
            end
        end
        table.sort(specs, function(x,y) return (x.type .. ":" .. (x.resource or x.recipe)) < (y.type .. ":" .. (y.resource or y.recipe)) end)
        n.options_total, n.options_truncated, n.options = #specs, #specs > max_options, {}
        if n.options_truncated then truncated = true end
        local branches, alternatives_steps, alternatives_missing = {}, {}, {}
        for i=1, math.min(#specs, max_options) do
            if used >= max_nodes then n.options_truncated, truncated = true, true; break end
            local spec, branch = specs[i], clone(pool)
            local option, steps, missing, unresolved
            if spec.type == "gather" then
                option = { type="gather", resource=spec.resource, provenance="gather_profiles", availability="unknown" }
                steps = { { ["do"]="gather", resource=spec.resource, item=item, name=n.name, count=remaining } }
                missing, unresolved = {}, false
            else
                option, steps, missing, unresolved = recipe_option(spec.recipe, item, remaining, branch, depth, stack)
            end
            option.quantity_semantics = pinned and "requested" or (n.sufficiency == "unknown" and "upper_bound" or "exact_shortfall")
            n.options[#n.options + 1], branches[#branches + 1] = option, branch
            alternatives_steps[i], alternatives_missing[i] = steps, missing
            if unresolved then option.unresolved = true end
        end
        merge(pool, branches, n.options_truncated)
        if #specs == 0 then
            n.status = "obtain"
            local steps = { { ["do"]="obtain", item=item, name=n.name, count=remaining } }
            local missing = n.sufficiency == "short" and { {item=item,name=n.name,count=remaining} } or {}
            return n, steps, missing, n.sufficiency == "unknown"
        end
        if #specs ~= 1 or n.options_truncated then n.status = "choices_unresolved"; return n, {}, {}, true end
        local option = n.options[1]
        -- A single choice is represented by the requirement node itself; copying
        -- its recursive inputs into both places would duplicate every subtree on JSON serialization.
        n.options = nil
        if option.type == "gather" then
            n.status, n.gather, n.provenance, n.availability = "gather", option.resource, option.provenance, option.availability
            n.quantity_semantics = option.quantity_semantics
        else
            for k,v in pairs(option) do if k ~= "type" then n[k] = v end end
            n.status = option.plan_status
        end
        if option.unresolved then return n, {}, {}, true end
        return n, alternatives_steps[1], alternatives_missing[1], n.sufficiency == "unknown"
    end
    local pool = { values = copy(ctx.have or {}), certainty = {}, provenance = {}, exact = exact }
    local item, rid, need
    if goal.recipe then
        rid = M.recipe(goal.recipe)
        if not rid then return nil, "unknown_recipe" end
        local r = recipe_of(rid)
        item = r.outputs[1] and item_id(r.outputs[1][1])
        need = count * per_craft(r, item)
    else item, need = goal.item, count end
    local root, steps, missing, unresolved = node(item, need, pool, 0, {}, rid)
    local ready
    if root.status == "have" then ready = true
    elseif root.status ~= "execution_unknown" and not unresolved then ready = false end
    local function has_choices(n)
        if type(n) ~= "table" then return false end
        if (type(n.options_total) == "number" and n.options_total > 1) or n.options_truncated then return true end
        for _, child in ipairs(n.inputs or {}) do if has_choices(child) then return true end end
        for _, option in ipairs(n.options or {}) do if has_choices(option) then return true end end
        return false
    end
    return { root=root, steps=not unresolved and steps or nil, missing=not unresolved and missing or nil,
             ready=ready, choices_unresolved=has_choices(root) or nil, truncated=truncated or nil }
end

-- Every recipe he could craft right now (unlocked + inputs carried), with whether a station of its
-- type is near. ctx as assess.
function M.craftable(ctx, opts)
    opts = opts or {}
    local out = {}
    for rid, r in pairs(M.data().recipes or {}) do
        if (ctx.unlocked or {})[rid] and #(r.stations or {}) > 0 then -- (some recipes cost nothing, e.g. capes)
            local a = M.assess(rid, 1, ctx)
            if a.status == "ready" or (a.status == "no_station" and not opts.near_only) then out[#out + 1] = a end
        end
    end
    table.sort(out, function(x, y)
        if x.status ~= y.status then return x.status == "ready" end
        return tostring(x.name) < tostring(y.name)
    end)
    return out
end

-- ------------------------------------------------------------------ fuel choice (pure)
-- plan.fuels (accepted fuels of the station / the recipe's fixed fuel), what he carries, what the
-- station already holds -> {source = "station" | "mine", item, name, count} | nil, reason, data
function M.choose_fuel(plan, want, have, station_fuel)
    if plan.kind ~= "processing" or #(plan.fuels or {}) == 0 then return { none = true } end
    local inputs = {}
    for _, c in ipairs(plan.inputs) do inputs[c.item] = c.count end
    local function matches(f) return not want or f.item == want or lower(f.name) == lower(want) or lower(f.item) == lower(want) end
    if not want and station_fuel then -- the station's own fuel (allowed, reported)
        for _, f in ipairs(plan.fuels) do
            if (station_fuel[f.item] or 0) >= f.count then
                return { source = "station", item = f.item, name = f.name, count = f.count, in_station = station_fuel[f.item] }
            end
        end
    end
    local carried, burn_input = {}, nil
    for _, f in ipairs(plan.fuels) do
        if matches(f) then
            local spare = (have[f.item] or 0) - (inputs[f.item] or 0)
            if spare >= f.count then carried[#carried + 1] = f
            elseif (have[f.item] or 0) >= f.count then burn_input = f end
        end
    end
    if #carried == 1 or (want and #carried >= 1) then
        local f = carried[1]
        return { source = "mine", item = f.item, name = f.name, count = f.count }
    end
    if #carried > 1 then
        local c = {}
        for _, f in ipairs(carried) do c[#c + 1] = { item = f.item, name = f.name, count = f.count } end
        local names = {}
        for _, f in ipairs(carried) do names[#names + 1] = tostring(f.name) end
        return nil, "ambiguous_target", { fuels = c, detail = "I could burn " .. table.concat(names, " or ") .. "; which fuel should I use?" }
    end
    if burn_input then
        return nil, "missing_input", { fuel = true, item = burn_input.item, detail = "The only fuel I have is the "
            .. tostring(burn_input.name) .. " I need for the recipe itself, so I won't burn it." }
    end
    local names = {}
    for _, f in ipairs(plan.fuels) do if matches(f) then names[#names + 1] = (f.count .. " " .. tostring(f.name)) end end
    return nil, "missing_input", { fuel = true, item = want or (plan.fuels[1] or {}).item,
        detail = "I need fuel for that: " .. (#names > 0 and table.concat(names, " or ") or tostring(want)) .. "." }
end

-- ------------------------------------------------------------------ crafting result codes -> speech
-- ECraftingResult (Dominion_enums): Success 0, FailureMissingConsumedItems 1, FailureNotEnoughSpace 2,
-- FailureCarryingTooMuchWeight 3, FailureInvalidRecipe 4, FailureInvalidCount 5, FailureRecipeNotUnlocked 6,
-- FailureNotEnoughVendorReputation 7.
M.RESULTS = {
    [1] = { "missing_input", "The game says I'm missing something for the %s." },
    [2] = { "inventory_full", "My bag is full, so I couldn't make the %s." },
    [3] = { "inventory_full", "I'm carrying too much to make the %s." },
    [4] = { "invalid_args", "The game says the %s can't be crafted here." },
    [5] = { "invalid_args", "The game rejected that amount of %s." },
    [6] = { "not_unlocked", "The game says I haven't unlocked the %s yet." },
    [7] = { "not_unlocked", "I don't have enough reputation with this vendor for the %s." },
}
function M.result_failure(code, what)
    local e = M.RESULTS[code]
    if e then return e[1], string.format(e[2], tostring(what or "item")) end
    return "craft_failed", "The craft failed (result " .. tostring(code) .. ")."
end

-- ------------------------------------------------------------------ engine touches (tests replace W)
local function sense_U(api)
    local s = api.module("sense")
    return s and s.U, s
end

local function local_pc(api)
    local _, s = sense_U(api)
    return s and s.local_pc and s.local_pc() or nil
end

local function ui_object(api, class)
    local U = sense_U(api)
    local pc = local_pc(api)
    if not U then return nil end
    for _, a in ipairs(U.find_all(class, { skip_defaults = true }) or {}) do
        local apc = U.try(function() return a.PlayerController end)
        if not pc or (U.valid(apc) and U.short(apc) == U.short(pc)) then return a end
    end
end

-- Claude's own recipe unlocks: PlayerController.ProgressComponent.RecipesUnlocked (TSet, read-only).
function W.unlocked(api)
    local U = sense_U(api)
    local pc = local_pc(api)
    local prog = pc and U and U.try(function() return pc.ProgressComponent end)
    if not (U and U.valid(prog)) then return nil end
    local set, n = {}, 0
    local ok = pcall(function()
        prog.RecipesUnlocked:ForEach(function(a, b)
            local e = b ~= nil and b or a
            local v = U.try(function() return e:get() end)
            local id = asset(U.path_of(v ~= nil and v or e))
            if id then set[id] = true; n = n + 1 end
        end)
    end)
    if not ok or n == 0 then return nil end
    return set, n
end

-- Contents of an inventory component: {slots = n, rows = {{slot, item, name, count}}, by_item = {id = n}}
function W.contents(api, inv)
    local U = sense_U(api)
    local out = { slots = 0, rows = {}, by_item = {} }
    if not (U and U.valid(inv)) then return out end
    pcall(function()
        local arr = inv.ItemSlots
        out.slots = arr:GetArrayNum()
        for i = 1, out.slots do
            local it = arr[i]
            if U.valid(it) then
                local data = U.try(function() return it.ItemData end)
                local id = asset(U.path_of(data))
                local n = tonumber(U.try(function() return it.Count end)) or 1
                if id then
                    out.rows[#out.rows + 1] = { slot = i - 1, item = id, name = U.str(U.try(function() return data.Name end)), count = n }
                    out.by_item[id] = (out.by_item[id] or 0) + n
                end
            end
        end
    end)
    return out
end

local COMPONENTS = { crafting = { "CraftingStation" }, processing = { "ProcessingStation" } } -- BP variable names (dump)
function W.component(api, actor, kind)
    local U = sense_U(api)
    for _, p in ipairs(COMPONENTS[kind] or {}) do
        local c = U and U.try(function() return actor[p] end)
        if U and U.valid(c) then return c end
    end
end

-- Live state of a processing station (property reads only).
function W.station_state(api, actor, kind)
    local U = sense_U(api)
    local c = W.component(api, actor, kind)
    if not (U and c) then return nil end
    if kind ~= "processing" then return { kind = kind } end
    local function b(p) return U.try(function() return c[p] end) == true end
    local function n(p) return tonumber(U.try(function() return c[p] end)) end
    local res = U.try(function() return c.Resources end)
    local fuel = U.try(function() return c.Fuel end)
    local outv = U.try(function() return c.OutputInventory end)
    return { kind = kind, running = b("bStationRunning"), ready = b("bReadyToProcess"), store_output = b("bStoreOutput"),
             remaining_s = n("RemainingProcessingTime"), fuel_s = n("RemainingFuelTime"),
             recipe = asset(U.path_of(U.try(function() return c.CurrentRecipe end))),
             resources = W.contents(api, res), fuel = W.contents(api, fuel), output = W.contents(api, outv),
             _res = res, _fuel = fuel, _out = outv }
end

-- Which station's menu the game has open for him: owner actor short id | nil.
function W.open_station(api, kind)
    local U = sense_U(api)
    if not U then return nil end
    local comp
    if kind == "processing" then
        local ui = ui_object(api, "ProcessingStationUIAPI")
        comp = ui and U.try(function() return ui.ProcessingStationComponent end)
    else
        local ui = ui_object(api, "CraftingUIAPI")
        comp = ui and U.try(function() return ui.CurrentStation end)
    end
    if not U.valid(comp) then return nil end
    local o = U.try(function() return comp:GetOwner() end)
    return U.valid(o) and U.short(o) or nil
end

-- The crafting menu's own handlers (what its craft button runs).
function W.send_craft(api, rid, count)
    local U = sense_U(api)
    local ui = ui_object(api, "CraftingUIAPI")
    local r = recipe_of(rid)
    local obj = U and r and U.find_object(r.path)
    if U and r and not (obj and U.valid(obj)) then -- not found by path: the loaded RecipeData objects (read-only)
        for _, o in ipairs(U.find_all("RecipeData") or {}) do
            if U.path_of(o) == r.path then obj = o; break end
        end
    end
    if not ui then return false, "no CraftingUIAPI" end
    if not (obj and U.valid(obj)) then return false, "recipe object not loaded: " .. tostring(rid) end
    api.log("crafting: CraftingUIAPI:SelectRecipe(" .. rid .. ") + SendCraftRequest(" .. count .. ")")
    local ok, err = pcall(function() ui:SelectRecipe(obj); ui:SendCraftRequest(count) end)
    return ok, (not ok) and tostring(err) or nil
end

-- Close the station's menu (EWidgetType Crafting 6 / Processing 15) through the crafting UI API.
-- The Rune Altar (a crafting station too) opens its OWN panel, EWidgetType Runecrafting 36 (URunecraftingMainPanel,
-- dump l.32462): when that panel is up, close type 36 as well, else the dialogue-like screen stays open and every
-- gated module refuses (input.lua's modal gate).
M.RUNECRAFTING_WIDGET = 36
function W.runecrafting_open(api)
    local U = sense_U(api)
    if not U then return false end
    for _, p in ipairs(U.find_all("RunecraftingMainPanel", { skip_defaults = true }) or {}) do
        if U.try(function() return p:IsInViewport() end) == true then return true end
    end
    return false
end
-- Then the game's own HUD close, InputManagerUIAPI:CloseWidgetIfOpen (input.close_screens), for every station
-- panel still open plus its coupled Inventory (BUGS B-stuck-focused-ui, live 2026-10-26: HideCraftingUI(15) is a
-- no-op for a Campfire's Processing panel; Processing 15 + Inventory 11 stayed open -> DIM_FocussedInGameUI until a
-- client restart. CloseWidgetIfOpen(15) closed both, mode -> DIM_Gameplay). -> true when no station panel is left
M.STATION_WIDGETS = { 15, 6, 36, 11 } -- Processing, Crafting, Runecrafting, Inventory (EWidgetType)
function W.close(api, kind)
    local ui = ui_object(api, "CraftingUIAPI")
    local ok = ui ~= nil
    if ui and kind ~= "processing" then
        ok = pcall(function() ui:HideCraftingUI(6) end)
        if W.runecrafting_open(api) then
            ok = pcall(function() ui:HideCraftingUI(M.RUNECRAFTING_WIDGET) end) and ok
        end
    end
    local IN = api.module("input")
    if IN and type(IN.close_screens) == "function" then
        local okc, closed, left = pcall(IN.close_screens, M.STATION_WIDGETS)
        if okc and closed then
            if #closed > 0 then api.log("crafting: closed [" .. table.concat(closed, ",") .. "] (InputManagerUIAPI:CloseWidgetIfOpen)") end
            ok = #left == 0
        end
    end
    return ok
end

-- Inventory UI drag: `amount` from his (slot, slot_type) into slot `to` of an external inventory.
function W.move_into(api, row, amount, to_slot, target)
    local inv = api.module("inventory")
    local ui = inv and inv.ui_api and inv.ui_api()
    local st = inv and inv.SLOT_TYPE and inv.SLOT_TYPE[row.slot_type]
    if not (ui and st and row.slot) then return false, "no InventoryUIAPI / slot type" end
    api.log(string.format("crafting: HandleSplitToExternalSlot(%d, %s, %d, %d) %s", row.slot, tostring(row.slot_type), amount, to_slot, tostring(row.item)))
    local ok, err = pcall(function() ui:HandleSplitToExternalSlot(row.slot, st, amount, to_slot, target) end)
    return ok, (not ok) and tostring(err) or nil
end

-- Quick transfer one slot of an external inventory (station output) into his inventory.
function W.take_from(api, slot, source)
    local inv = api.module("inventory")
    local ui = inv and inv.ui_api and inv.ui_api()
    if not ui then return false, "no InventoryUIAPI" end
    api.log("crafting: HandleExternalQuickTransfer(" .. slot .. ")")
    local ok, err = pcall(function() ui:HandleExternalQuickTransfer(slot, source) end)
    return ok, (not ok) and tostring(err) or nil
end

-- The processing menu's start button.
function W.toggle(api)
    local ui = ui_object(api, "ProcessingStationUIAPI")
    if not ui then return false, "no ProcessingStationUIAPI" end
    api.log("crafting: ProcessingStationUIAPI:ToggleProcessingStationStarted()")
    local ok, err = pcall(function() ui:ToggleProcessingStationStarted() end)
    return ok, (not ok) and tostring(err) or nil
end

-- READ-ONLY post-hook on the server's craft verdict (a Client RPC arriving on his client). Registered
-- once per client process; the callback reads _G.DWCraft, so hot reloads need no re-registration.
M.RESULT_HOOK = "/Script/Dominion.InventoryController:Client_OnCraftingResultHandler"
function W.arm_result_hook(api)
    local st = state()
    if st.hooked then return true end
    if type(RegisterHook) ~= "function" then return false end
    -- BUGS L24: the shared hook hub (one native hook per path, never unregistered, skipped under DW_PAUSE)
    local hubm = (function()
                local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or ((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver") .. "/client_mod/scripts")
                return assert(loadfile(dir .. "/hookhub.lua"))()
            end)()
    local ok, err = hubm.on(M.RESULT_HOOK, "crafting:result", function(_, result, recipe, count)
        local s = rawget(_G, "DWCraft")
        if not s then return end
        local function g(p) local okg, v = pcall(function() return p:get() end); return okg and v or nil end
        local rec = g(recipe)
        local path
        pcall(function() path = rec:GetFullName() end)
        s.seq = (s.seq or 0) + 1
        local recipe_path = path and path:match("%S+%s+(%S+)$")
        s.results[#s.results + 1] = { seq = s.seq, result = tonumber(g(result)), recipe = asset(recipe_path), recipe_path=recipe_path,
                                      count = tonumber(g(count)), at = os.time() }
        while #s.results > 20 do table.remove(s.results, 1) end
    end, {})
    st.hooked = ok
    if not ok then api.log("crafting: RegisterHook result: " .. tostring(err)) end
    return ok
end

function W.results_since(seq)
    local out = {}
    for _, r in ipairs(state().results or {}) do if r.seq > seq then out[#out + 1] = r end end
    return out
end

-- gather_profiles: item id -> resource name (the gather tool's own data; no code per item)
function W.gather_for(api)
    local gp = api.module("gather_profiles")
    local map, names = {}, {}
    for name in pairs(type(gp) == "table" and gp.RESOURCES or {}) do names[#names + 1] = name end
    table.sort(names) -- deterministic: the first resource name (alphabetical) that yields the item
    for _, name in ipairs(names) do
        local p = gp.RESOURCES[name]
        if type(p) == "table" and p.item and not map[p.item] then map[p.item] = name end
    end
    return function(item) return map[item] end
end

-- Every profile is an acquisition hint; the census and actual tool still decide availability.
function W.gather_options(api)
    local gp = api.module("gather_profiles")
    local map = {}
    for name, profile in pairs(type(gp) == "table" and gp.RESOURCES or {}) do
        if type(name) == "string" and type(profile) == "table" and type(profile.item) == "string" then
            map[profile.item] = map[profile.item] or {}
            table.insert(map[profile.item], name)
        end
    end
    for _, names in pairs(map) do table.sort(names) end
    return function(item) return map[item] or {} end
end

-- ------------------------------------------------------------------ live context
local function unlocked(api)
    local st = state()
    local now = api.now()
    if st.unl and st.unl_at and now - st.unl_at >= 0 and now - st.unl_at < M.cfg.unlock_ttl_s then return st.unl, st.unl_n end
    local set, n = W.unlocked(api)
    st.unl, st.unl_n, st.unl_at = set, n, now
    return set, n
end

-- Stations near him: census interactables of the station kinds whose class word the catalog knows.
function M.stations(api, radius_m)
    local things = api.census_things(radius_m or M.cfg.station_radius_m, 40)
    local out = {}
    for _, t in ipairs(things or {}) do
        if t.category == "interactables" and (t.kind == "crafting_station" or t.kind == "processing_station") then
            local sid = M.station_type(t.class)
            if sid then
                local st = station_info(sid) or {}
                out[#out + 1] = { id = t.id, class = t.class, station = sid, name = st.name or t.name, kind = st.kind,
                                  position = t.position, distance = t.distance, prompt = t.prompt }
            end
        end
    end
    table.sort(out, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
    return out
end

local function near_map(rows)
    local near = {}
    for _, s in ipairs(rows) do if not near[s.station] then near[s.station] = s end end
    return near
end

local function context(api, radius_m, scalar_only)
    local have, count_status
    local native_count
    if scalar_only then
        have, count_status = {}, {status="unknown", count_semantics="lower_bound"}
        native_count = function(path)
            local inv = api.module("inventory")
            if not inv or type(inv.count_item) ~= "function" then return {status="unknown",reason="native_count_unavailable"} end
            local ok, r = pcall(inv.count_item, path)
            return ok and type(r)=="table" and r or {status="unknown",reason="native_count_failed"}
        end
    end
    if not scalar_only then
        if type(api.counts_with_status) == "function" then have, count_status = api.counts_with_status()
        else have = api.counts() end
    end
    if not have then return nil, api.fail("state_unavailable", { detail = "I can't read my inventory right now." }) end
    local rows = M.stations(api, radius_m)
    local unl, n = unlocked(api)
    return { have = have, count_status = count_status, native_count = native_count, unlocked = unl, unlocked_n = n, near = near_map(rows), stations = rows }
end

-- ------------------------------------------------------------------ the pawn (arbiter), as skills.lua
local function arbiter(api)
    local A = api.module("arbiter")
    return A and type(A.request) == "function" and A or nil
end
local function acquire(api, job)
    if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
    local A = arbiter(api)
    if not A then job.own = "none"; return true end
    local r = A.request(api.log, { name = "skill:craft", level = "command", uses_move = true, lease_s = M.cfg.lease_s, resumable = true,
                                   on_suspend = function() job.own = "suspended" end,
                                   on_resume = function() job.own = "owner"; job.resumed = true; return true end,
                                   on_stop = function(_, _, why) if job.own ~= "released" then job.stopped = why or "stopped" end end })
    if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
    job.own = "waiting"
    return false
end
local function release(api, job, why)
    if job.token and job.own ~= "released" then
        local A = arbiter(api)
        job.own = "released"
        if A then pcall(A.release, api.log, job.token, why) end
    end
end

-- ------------------------------------------------------------------ the station episode
-- approach a stand point in front of the station -> face it until the game's detector targets it ->
-- one interact press -> wait for the game to open ITS menu (re-press once).
local function skills_W(api)
    local sk = api.module("skills")
    return sk and sk.W
end

local function stand_point(here, pos, d)
    local dx, dy = here[1] - pos[1], here[2] - pos[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then return { pos[1] + d, pos[2], pos[3] } end
    return { pos[1] + dx / l * d, pos[2] + dy / l * d, pos[3] }
end

-- Other standing spots around a station when the game's detector keeps targeting something else from here
-- (live 2026-10-26: a sapling next to the Campfire won the focus): stand_m out, rotated around the station
-- from the side he stood on. -> {{x, y, z}, ...}
M.cfg.spot_angles = { 90, -90, 180, 45, -45 }
local function stand_spots(from, pos, d)
    local dx, dy = from[1] - pos[1], from[2] - pos[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1, 0, 1 end
    dx, dy = dx / l, dy / l
    local out = {}
    for _, deg in ipairs(M.cfg.spot_angles) do
        local r = math.rad(deg)
        local cx, cy = dx * math.cos(r) - dy * math.sin(r), dx * math.sin(r) + dy * math.cos(r)
        out[#out + 1] = { pos[1] + cx * d, pos[2] + cy * d, pos[3] }
    end
    return out
end
M._stand_spots = stand_spots

local function open_poll(api, job, t)
    local e, row = job.open, job.station
    if e.phase == "approach" then
        local here = api.my_position()
        local d = here and dist2d(here, row.position)
        local at_goal = e.goal and here and dist2d(here, e.goal) <= 0.8
        if (not e.goal and d and d <= M.cfg.reach_m) or at_goal then e.phase, e.face_until = "face", t + M.cfg.face_s; return nil end
        if not e.moving then
            if e.approaches >= M.cfg.approaches then
                return api.fail("too_far", { station = row.id, distance = d and r1(d), detail = "I can't get close enough to the " .. tostring(row.name) .. "." })
            end
            local mr = api.call("move", "go_to", e.goal or stand_point(here or row.position, row.position, M.cfg.stand_m),
                                { tolerance_m = M.cfg.approach_tol_m, timeout_s = 60, owner_token = job.token })
            if not mr.ok then return mr end
            e.moving, e.approaches = true, e.approaches + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        e.moving = false
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "arrived" or res.status == "stopped" then return nil end
        -- a failed approach that still ended within reach is fine (stations are big): next tick checks
        local here2 = api.my_position()
        if here2 and dist2d(here2, row.position) <= M.cfg.reach_m and not e.goal then return nil end
        -- a side spot he can't reach: try the next side (or face from where he got to)
        if e.goal then
            e.spot_i = e.spot_i + 1
            if e.spots[e.spot_i] then e.goal, e.moving, e.approaches = e.spots[e.spot_i], false, 0; return nil end
            e.goal, e.phase, e.face_until = nil, "face", t + M.cfg.face_s
            return nil
        end
        local sk = api.module("skills")
        local words = sk and sk.why_words and sk.why_words(res.reason) or "I can't find a way there"
        return api.fail(api.reason_code(res.reason or "path_blocked") == "body_error" and "path_blocked" or api.reason_code(res.reason or "path_blocked"),
                        { station = row.id, why = res.reason, detail = "I can't get to the " .. tostring(row.name) .. ": " .. words .. "." })
    elseif e.phase == "face" then
        local SW = skills_W(api)
        local det = SW and SW.detector and SW.detector(api)
        if det and not det.none and det.actor == row.id then
            local pr = api.call("inventory", "press_interact")
            if not pr.ok then return pr end
            e.presses = e.presses + 1
            e.phase, e.open_until = "opening", t + M.cfg.open_wait_s
            return nil
        end
        if SW and SW.face then SW.face(api, row.position, true) else api.aim_at(row.position) end
        if t >= e.face_until then
            local other = det and not det.none and (det.name or det.actor)
            -- something else holds the game's focus from here: stand on another side of the station first
            if not e.spots then
                local here = api.my_position()
                e.spots, e.spot_i = stand_spots(here or row.position, row.position, M.cfg.stand_m), 0
                e.blockers = {}
            end
            if other then e.blockers[#e.blockers + 1] = other end
            e.spot_i = e.spot_i + 1
            if e.spots[e.spot_i] then
                e.goal, e.phase, e.moving, e.approaches = e.spots[e.spot_i], "approach", false, 0
                return nil
            end
            local sides = e.spots and #e.spots + 1 or 1
            local word = other and (tostring(other):gsub("^BP_", ""):gsub("_C$", ""):gsub("_%d+$", ""):gsub("_", " ")) or nil
            return api.fail("not_interactable", { station = row.id, detector = det, blockers = e.blockers, sides_tried = sides,
                detail = other and ("I can't get the game to target the " .. tostring(row.name) .. " from any of the " .. sides
                    .. " sides I tried; it keeps picking the " .. word .. " next to it.")
                    or ("I can't get the game to let me use the " .. tostring(row.name) .. ".") })
        end
        return nil
    else -- opening
        if W.open_station(api, row.kind) == row.id then
            job.ui_open = true
            local IN = api.module("input") -- this screen is MEANT to be open: input's stray-screen guard leaves it
            if IN and IN.claim then pcall(IN.claim, "screen", "craft") end
            return true
        end
        if t >= e.open_until then
            if e.presses < M.cfg.presses then e.phase, e.face_until = "face", t + M.cfg.face_s; return nil end
            return api.fail("verification_failed", { station = row.id,
                detail = "I pressed use on the " .. tostring(row.name) .. " but its menu didn't open." })
        end
        return nil
    end
end

-- ------------------------------------------------------------------ craft job
local function cand_wire(list)
    local out = {}
    for _, a in ipairs(list) do
        out[#out + 1] = { recipe = a.recipe, name = a.name, status = a.status, station = a.station_name, missing = (#a.missing > 0) and a.missing or nil,
                          detail = a.detail }
    end
    return out
end

local function resolve_candidates(api, args, ctx)
    local count = tonumber(args.count) or 1
    if count ~= math.floor(count) or count < 1 or count > M.cfg.max_count then
        return nil, api.fail("invalid_args", { detail = "count must be a whole number from 1 to " .. M.cfg.max_count })
    end
    if args.recipe ~= nil then
        local rid = M.recipe(args.recipe)
        if not rid then return nil, api.fail("unknown_recipe", { recipe = args.recipe, detail = "I don't know a recipe called " .. tostring(args.recipe) .. "." }) end
        return { M.assess(rid, count, ctx) }, nil, nil
    end
    if not need_str(args.item) then return nil, api.fail("invalid_args", { detail = "item or recipe is required" }) end
    local id, hits, kind = M.resolve_item(args.item)
    if not id then
        return nil, item_resolution_failure(api, args.item, hits, kind, 10, ctx)
    end
    local list = M.candidates(id, count, ctx)
    if #list == 0 then
        return nil, api.fail("unknown_recipe", { item = id, detail = "Nothing in the game crafts " .. name_of_id(id) .. "." })
    end
    return list, nil, id
end

-- A specific station row when args.station names one (id, type id or display name).
local function pick_station(api, a, args, ctx)
    if not need_str(args.station) then return a.station_row end
    local want = lower(args.station)
    local r = recipe_of(a.recipe)
    local ok_type = {}
    for _, s in ipairs(r.stations or {}) do ok_type[s] = true end
    for _, s in ipairs(ctx.stations) do
        if s.id == args.station or ((lower(s.station) == want or lower(s.name) == want) and ok_type[s.station]) then
            if not ok_type[s.station] then return nil, api.fail("invalid_args", { station = s.id,
                detail = "The " .. tostring(s.name) .. " can't make " .. tostring(a.name) .. "." }) end
            return s
        end
    end
    return nil, api.fail("unknown_target", { station = args.station, detail = "I can't see that station (" .. args.station .. ") near here." })
end

local function start_craft(api, args, ctx0)
    local ctx, bad = context(api, nil, true)
    if not ctx then return bad end
    if ctx.unlocked == nil then
        return api.fail("state_unavailable", { detail = "I can't read which recipes I've unlocked right now." })
    end
    local list, err, item = resolve_candidates(api, args, ctx)
    if not list then return err end
    local viable, carried = {}, {}
    for _, a in ipairs(list) do
        if a.viable then
            viable[#viable + 1] = a
            if a.carried_sufficient then carried[#carried + 1] = a end
        end
    end
    -- Prefer a uniquely established carried-input option; other options may
    -- still be possible from linked storage and remain listed as alternatives.
    if args.recipe == nil and #carried == 1 then viable = carried end
    if args.recipe == nil and #viable > 1 then
        local names = {}
        for _, a in ipairs(viable) do names[#names + 1] = a.recipe end
        return api.fail("ambiguous_target", { item = item, candidates = cand_wire(viable),
            detail = "I can make " .. name_of_id(item) .. " " .. #viable .. " ways; which recipe should I use?" })
    end
    local a = viable[1]
    if not a then
        local best = list[1]
        local reason = ({ not_unlocked = "not_unlocked", unlock_unknown = "state_unavailable", missing_input = "missing_materials",
                          no_station = "nothing_in_range", vendor = "not_implemented", no_station_type = "unknown_recipe" })[best.status] or "unknown_recipe"
        return api.fail(reason, { recipe = best.recipe, item = best.item, missing = (#best.missing > 0) and best.missing or nil,
            unlock = best.unlock, unlock_queries = best.unlock_queries, unlock_context = best.unlock_context,
            unlock_query_source = best.unlock_query_source,
            station = best.station_name, candidates = (#list > 1) and cand_wire(list) or nil,
            detail = (best.detail or "I can't make that.") .. "." })
    end
    local row, perr = pick_station(api, a, args, ctx)
    if not row then return perr end
    local plan = M.plan(a.recipe, a.crafts, row.station)
    local job = { kind = "craft", a = a, plan = plan, station = row, alternatives = {}, ctx = ctx, args = args }
    for _, o in ipairs(list) do if o ~= a then job.alternatives[#job.alternatives + 1] = { recipe = o.recipe, status = o.status } end end
    job.open = { phase = "approach", moving = false, approaches = 0, presses = 0 }
    job.phase = "open"
    job.before, job.count_bindings = {}, {}
    for _, group in ipairs({plan.inputs,plan.outputs,plan.fuels or {}}) do
        for _, entry in ipairs(group) do
            if not idx().ambiguous[entry.item] and entry.path and job.before[entry.item] == nil then
                local obs = ctx.native_count(entry.path)
                if obs and obs.status == "observed" then job.before[entry.item] = obs.count; job.count_bindings[entry.item] = obs; ctx.have[entry.item] = obs.count end
            end
        end
    end
    W.arm_result_hook(api)
    return job
end

-- Counts helpers
local function gained(before, now, item)
    local b,n=(before or {})[item],(now or {})[item]
    if type(b)~="number" or type(n)~="number" then return nil end
    return n-b
end
local function current_counts(job, baseline)
    local out={}
    if baseline then job.count_bindings={} end
    for _, group in ipairs({job.plan.inputs,job.plan.outputs,job.plan.fuels or {}}) do
        for _, entry in ipairs(group) do
            if not idx().ambiguous[entry.item] and entry.path and out[entry.item]==nil then
                local obs=job.ctx.native_count(entry.path)
                if obs and obs.status=="observed" then
                    local prior=job.count_bindings[entry.item]
                    if baseline then job.count_bindings[entry.item]=obs; out[entry.item]=obs.count
                    elseif prior and prior.world==obs.world and prior.controller==obs.controller and prior.pawn==obs.pawn and prior.component==obs.component and prior.asset==obs.asset then out[entry.item]=obs.count end
                end
            end
        end
    end
    return out
end

local function base_data(job)
    local d = { recipe = job.a.recipe, recipe_chosen = job.a.recipe, item = job.a.item, crafts = job.a.crafts,
                station = job.station.name, station_id = job.station.id, alternatives = job.alternatives }
    return d
end

-- bench: send -> await verdict + inventory
local function bench_step(api, job, t)
    if job.phase == "send" then
        job.before = current_counts(job, true)
        job.seq0 = state().seq or 0
        local ok, err = W.send_craft(api, job.a.recipe, job.a.crafts)
        if not ok then return api.fail("not_implemented", { detail = "The crafting menu didn't take my order (" .. tostring(err) .. ")." }) end
        job.phase, job.until_t = "await", t + M.cfg.result_wait_s + (job.plan.seconds or 0)
        return nil
    end
    -- await
    local verdicts = W.results_since(job.seq0)
    local v, ambiguous = nil, false
    for _,event in ipairs(verdicts) do
        if type(event.recipe_path) ~= "string" or type(event.count) ~= "number" or type(event.result) ~= "number" then
            ambiguous = true
        elseif event.recipe_path == (recipe_of(job.a.recipe) or {}).path and event.count == job.a.crafts then
            if v then ambiguous=true else v=event end
        end
    end
    if ambiguous then v=nil end
    local now = current_counts(job)
    local out = job.plan.outputs[1]
    local got = out and gained(job.before, now, out.item) or nil
    if v and v.result and v.result ~= 0 then
        local reason, words = M.result_failure(v.result, out and out.name)
        local d = base_data(job)
        d.result_code, d.detail = v.result, words
        return api.fail(reason, d)
    end
    local want = out and out.count or 1
    if got and got >= want and v and v.result == 0 then
        local d = base_data(job)
        local consumed = {}
        for _, c in ipairs(job.plan.inputs) do consumed[#consumed + 1] = { item = c.item, name = c.name, count = gained(job.before, now, c.item) and -gained(job.before, now, c.item) or nil } end
        d.count, d.confirmed_crafts, d.observed_inventory_delta = want, v.count, got
        d.possible_concurrent_delta = got > want
        d.consumed, d.result_code = consumed, v.result
        d.detail = "The game confirmed my request for " .. v.count .. " " .. tostring(job.a.name) .. " craft" .. (v.count == 1 and "" or "s") .. "; my inventory increased by " .. got .. " " .. tostring(out.name) .. "."
        return { ok = true, data = d }
    end
    if t >= job.until_t then
        local d = base_data(job)
        if v and v.result == 0 and got == nil then
            d.result_code = 0
            d.detail = "The game reported success, but I couldn't verify the inventory change."
            return api.fail("verification_failed", d)
        end
        if v and v.result == 0 then
            d.result_code = 0
            d.detail = "The game said the craft worked, but the " .. tostring(out and out.name) .. " didn't show up in my inventory."
            return api.fail("verification_failed", d)
        end
        d.detail = "I asked the " .. tostring(job.station.name) .. " to make " .. tostring(out and out.name) .. " but nothing happened."
        return api.fail("timeout", d)
    end
    return nil
end

-- processing: load inputs + fuel -> start -> wait -> collect
local function station_actor(api, job)
    return api.actor_of({ id = job.station.id, class = job.station.class })
end

local function first_slot(contents, slots, item)
    for _, r in ipairs(contents.rows) do if r.item == item then return r.slot end end
    local used = {}
    for _, r in ipairs(contents.rows) do used[r.slot] = true end
    for i = 0, (slots or contents.slots or 0) - 1 do if not used[i] then return i end end
    return nil
end

local function carried_rows(api, item)
    local lr = api.call("inventory", "list")
    local rows = {}
    if not lr.ok then return rows, false end
    local d = lr.data or {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, r in ipairs(d[where] or {}) do if r.item == item and (tonumber(r.count) or 0) > 0 then rows[#rows + 1] = r end end
    end
    local status = d.read_status and d.read_status.carried
    return rows, type(status)=="table" and status.status=="complete"
end

local function proc_setup(api, job)
    local actor = station_actor(api, job)
    local s = actor and W.station_state(api, actor, "processing")
    if not s then return api.fail("state_unavailable", { station = job.station.id, detail = "I can't read the " .. tostring(job.station.name) .. " right now." }) end
    job.actor, job.st0 = actor, s
    job.station_before = { resources = s.resources.rows, fuel = s.fuel.rows, output = s.output.rows, running = s.running,
                           recipe = s.recipe }
    local fuel_by_item = s.fuel.by_item
    local f, why, fd = M.choose_fuel(job.plan, job.args.fuel, job.ctx.have, fuel_by_item)
    if not f then
        local d = base_data(job); for k, v in pairs(fd or {}) do d[k] = v end
        d.station_before = job.station_before
        for _, fuel in ipairs(job.plan.fuels or {}) do
            if job.ctx.have[fuel.item] == nil then
                d.detail = "I couldn't verify my available fuel for the " .. tostring(job.station.name) .. "."
                return api.fail("verification_failed", d)
            end
        end
        return api.fail(why == "missing_input" and "missing_materials" or why, d)
    end
    job.fuel = f
    -- the loading queue: every input (and our own fuel)
    job.queue = {}
    for _, c in ipairs(job.plan.inputs) do job.queue[#job.queue + 1] = { item = c.item, name = c.name, count = c.count, into = "resources" } end
    if f.source == "mine" then job.queue[#job.queue + 1] = { item = f.item, name = f.name, count = f.count, into = "fuel" } end
    job.loaded = {}
    -- outputs already lying near the station (never counted as his)
    job.pre_items = {}
    for _, t in ipairs(api.census_things(M.cfg.collect_radius_m + 30, 60) or {}) do
        if t.category == "items" then job.pre_items[t.id] = true end
    end
    return nil
end

local function load_step(api, job, t)
    local q = job.queue[1]
    if not q then job.phase = "start"; return nil end
    local s = W.station_state(api, job.actor, "processing")
    if not s then return api.fail("state_unavailable", { detail = "I lost track of the " .. tostring(job.station.name) .. "." }) end
    local inv = q.into == "fuel" and s.fuel or s.resources
    local target = q.into == "fuel" and s._fuel or s._res
    local now_in = inv.by_item[q.item] or 0
    if job.moving then
        if now_in >= job.moving.expect then
            job.loaded[q.item] = (job.loaded[q.item] or 0) + job.moving.amount
            q.count = q.count - job.moving.amount
            job.moving = nil
            if q.count <= 0 then table.remove(job.queue, 1) end
            return nil
        end
        if t >= job.moving.until_t then
            local d = base_data(job)
            d.detail = "I tried to put the " .. tostring(q.name) .. " into the " .. tostring(job.station.name) .. " but it didn't go in."
            d.station_before, d.loaded = job.station_before, job.loaded
            return api.fail("verification_failed", d)
        end
        return nil
    end
    local rows, complete = carried_rows(api, q.item)
    local row = rows[1]
    if not row then
        local d = base_data(job)
        if not complete then
            d.detail = "I couldn't locate " .. tostring(q.name) .. " in my inventory to load the " .. tostring(job.station.name) .. "."
            return api.fail("verification_failed", d)
        end
        d.detail = "I ran out of " .. tostring(q.name) .. " while loading the " .. tostring(job.station.name) .. "."
        return api.fail("missing_materials", d)
    end
    local to = first_slot(inv, nil, q.item)
    if not to then
        local d = base_data(job)
        d.station_before = job.station_before
        d.detail = "The " .. tostring(job.station.name) .. " has no free slot for the " .. tostring(q.name) .. "."
        return api.fail("station_busy", d)
    end
    local amount = math.min(q.count, tonumber(row.count) or 1)
    local ok, err = W.move_into(api, row, amount, to, target)
    if not ok then return api.fail("not_implemented", { detail = "The inventory screen didn't let me move the " .. tostring(q.name) .. " (" .. tostring(err) .. ")." }) end
    job.moving = { amount = amount, expect = now_in + amount, until_t = t + M.cfg.move_wait_s }
    return nil
end

local function proc_collect_targets(api, job)
    local want = {}
    for _, o in ipairs(job.plan.outputs) do want[o.item] = true end
    local list = {}
    for _, t in ipairs(api.census_things(M.cfg.collect_radius_m + 30, 60) or {}) do
        if t.category == "items" and want[t.item] and not job.pre_items[t.id] and t.position
            and dist2d(t.position, job.station.position) <= M.cfg.collect_radius_m then
            list[#list + 1] = t
        end
    end
    return list
end

local function produced_total(api, job, s)
    local n, unknown = 0, false
    local now, world, seen = current_counts(job), {}, {}
    for _, t in ipairs(proc_collect_targets(api, job)) do
        if not t.id or seen[t.id] then unknown=true
        else
            seen[t.id]=true
            local count=tonumber(t.count)
            if not count or count~=count or count<0 or count==math.huge then unknown=true
            else world[t.item]=(world[t.item] or 0)+count end
        end
    end
    local seen_outputs={}
    for _, o in ipairs(job.plan.outputs) do
        if not seen_outputs[o.item] then
            seen_outputs[o.item]=true
            local delta=gained(job.before, now, o.item)
            if delta==nil then unknown=true end
            local station_delta = ((s and s.output.by_item[o.item]) or 0) - ((job.st0.output.by_item[o.item]) or 0)
            -- A unit may move between scopes during the episode. The maximum is
            -- conservative; summing the three views can count the same unit twice.
            n = n + math.max(0, delta or 0, station_delta, world[o.item] or 0)
        end
    end
    return n, unknown
end

local function out_total(job)
    local n = 0
    for _, o in ipairs(job.plan.outputs) do n = n + o.count end
    return n
end

local function proc_step(api, job, t)
    if job.phase == "load" then return load_step(api, job, t) end
    local s = W.station_state(api, job.actor, "processing")
    if not s then return api.fail("state_unavailable", { detail = "I lost track of the " .. tostring(job.station.name) .. "." }) end
    if job.phase == "start" then
        if s.recipe and s.recipe ~= job.a.recipe then
            local d = base_data(job)
            d.station_before, d.station_recipe, d.loaded = job.station_before, s.recipe, job.loaded
            d.detail = "With what's already in it, the " .. tostring(job.station.name) .. " would make " .. tostring(s.recipe)
                .. " instead of " .. tostring(job.a.name) .. "."
            return api.fail("station_busy", d)
        end
        job.before = current_counts(job, true)
        if not s.running then
            local ok, err = W.toggle(api)
            if not ok then return api.fail("not_implemented", { detail = "The " .. tostring(job.station.name) .. "'s start button didn't respond (" .. tostring(err) .. ")." }) end
        end
        job.phase, job.until_t = "starting", t + M.cfg.start_wait_s
        return nil
    elseif job.phase == "starting" then
        local produced, unknown = produced_total(api, job, s)
        if s.running or produced > 0 then
            job.phase = "wait"
            job.started_at = t
            job.until_t = t + (job.plan.seconds or 0) * M.cfg.proc_slack + M.cfg.proc_extra_s
            return nil
        end
        if t >= job.until_t then
            local d = base_data(job)
            d.station_before, d.loaded, d.fuel_used = job.station_before, job.loaded, job.fuel
            d.detail = unknown and ("I loaded the " .. tostring(job.station.name) .. " but couldn't verify whether it started or produced anything.")
                or ("I loaded the " .. tostring(job.station.name) .. " but it won't start.")
            if unknown then d.observed_output_lower_bound=produced end
            return api.fail("verification_failed", d)
        end
        return nil
    elseif job.phase == "wait" then
        local made, unknown = produced_total(api, job, s)
        if made >= out_total(job) or (not s.running and made > 0) then
            job.phase, job.collect_until = "magnet", t + M.cfg.magnet_wait_s
            return nil
        end
        if t >= job.until_t then
            local d = base_data(job)
            d.loaded, d.fuel_used, d.station_before = job.loaded, job.fuel, job.station_before
            d.observed_output_lower_bound = made
            d.output_count_unknown = unknown
            d.detail = "The " .. tostring(job.station.name) .. " stopped or took too long; I observed at least " .. made
                .. " matching output" .. (made == 1 and "" or "s") .. ", but could not verify the total."
            return api.fail("timeout", d)
        end
        return nil
    elseif job.phase == "magnet" then
        if t < job.collect_until and #proc_collect_targets(api, job) > 0 then return nil end
        job.phase = "collect"
        return nil
    else -- collect: stored outputs by quick transfer, then world items (pickup episode, output ids only)
        if job.ep then
            local sk = api.module("skills")
            local r = sk._episode_poll(api, job.ep, t)
            if r == nil then return nil end
            job.ep = nil
            if not r.ok then job.pickup_fail = r end
            job.picks = (job.picks or 0) + 1
            return nil
        end
        local want = {}
        for _, o in ipairs(job.plan.outputs) do want[o.item] = true end
        if s.store_output and not job.took then
            job.took = true
            for _, r in ipairs(s.output.rows) do if want[r.item] then W.take_from(api, r.slot, s._out) end end
            job.collect_until = t + M.cfg.magnet_wait_s
            return nil
        end
        local targets = proc_collect_targets(api, job)
        local sk = api.module("skills")
        if #targets > 0 and (job.picks or 0) < out_total(job) + 2 and sk and sk._episode_poll and sk._new_episode
            and not job.pickup_fail then
            local th = targets[1]
            -- the shared episode (aim at the item itself, other sides on a miss); the output lies at the station,
            -- whose own interaction wins any near miss, so it stands where the station is not behind the item
            job.ep = sk._new_episode(api, th, { label = th.name or "output", avoid = job.station.position,
                -- any NEW output of this recipe the detector targets will do (never a pre-existing item)
                accept = function(det) return det.item ~= nil and want[det.item] == true and det.actor ~= nil
                                              and not job.pre_items[det.actor] end })
            job.ep.want_item, job.ep.need_gain = th.item, true
            return nil
        end
        if job.took and t < (job.collect_until or 0) then return nil end
        local now = current_counts(job)
        local collected, total = {}, 0
        for _, o in ipairs(job.plan.outputs) do
            local g = gained(job.before, now, o.item)
            if g and g > 0 then collected[#collected + 1] = { item = o.item, name = o.name, count = g }; total = total + g end
        end
        local d = base_data(job)
        d.loaded, d.fuel_used, d.station_before, d.collected = job.loaded, job.fuel, job.station_before, collected
        local out = job.plan.outputs[1]
        d.count = out and gained(job.before, now, out.item) or 0
        if total <= 0 and out and gained(job.before, now, out.item)==nil then
            d.detail = "The " .. tostring(job.station.name) .. " finished, but I couldn't verify my inventory change."
            return api.fail("verification_failed", d)
        end
        if total <= 0 then
            d.detail = "The " .. tostring(job.station.name) .. " finished, but I couldn't pick up what it made."
                .. (job.pickup_fail and (" " .. tostring((job.pickup_fail.data or {}).detail or "")) or "")
            return api.fail("verification_failed", d)
        end
        d.detail = "I made " .. total .. " " .. tostring(out and out.name) .. " in the " .. tostring(job.station.name)
            .. (job.fuel and job.fuel.source == "station" and " (using the fuel that was already in it)" or "") .. "."
        if total < out_total(job) then d.partial = true end
        return { ok = true, data = d }
    end
end

local function craft_step(api, job, t)
    if job.phase == "open" then
        local r = open_poll(api, job, t)
        if r == true then
            if job.plan.kind == "processing" then
                local bad = proc_setup(api, job)
                if bad then return bad end
                job.phase = "load"
            else
                job.phase = "send"
            end
            return nil
        end
        return r
    end
    if job.plan.kind == "processing" then return proc_step(api, job, t) end
    return bench_step(api, job, t)
end

-- The pending action for the bridge's slot. The menu is closed on EVERY exit path.
local function action(api, ctx, job)
    local a = { kind = "craft", id = ctx and ctx.id,
                timeout_s = 120 + math.floor((job.plan.seconds or 0) * M.cfg.proc_slack + M.cfg.proc_extra_s) }
    local function finish(why)
        if job.ui_open and not paused() then pcall(W.close, api, job.plan.kind); job.ui_open = false end
        local IN = api.module("input")
        if IN and IN.release then pcall(IN.release, "screen") end
        release(api, job, why)
    end
    a.cancel = function()
        if not paused() then api.call("move", "stop") end
        finish("cancelled")
    end
    a.poll = function(self)
        if paused() then self.started = api.now(); return nil end
        if job.stopped then
            finish("interrupted")
            return api.fail("interrupted", { why = job.stopped, detail = "Something else took over (" .. tostring(job.stopped) .. "), so I stopped crafting." })
        end
        if not acquire(api, job) or job.own == "suspended" or api.reflex_owns_pawn() then
            self.started = api.now()
            return nil
        end
        if job.token then local A = arbiter(api); if A and A.renew then pcall(A.renew, job.token) end end
        if job.resumed then
            job.resumed = nil
            if job.phase == "open" then job.open.phase, job.open.moving = "approach", false end
            if job.ep then job.ep.phase, job.ep.moving = "approach", false end
        end
        local ok, res = pcall(craft_step, api, job, api.now())
        if not ok then res = api.fail("body_error", { detail = "crafting: " .. tostring(res) }) end
        if res then finish(res.ok and "done" or tostring(res.reason)) end
        return res
    end
    return { pending = a }
end

-- ------------------------------------------------------------------ read tools
local function stations_tool(api, args)
    local ctx, bad = context(api, tonumber(args.radius) or M.cfg.station_radius_m)
    if not ctx then return bad end
    local out = {}
    for _, s in ipairs(ctx.stations) do
        local w = { id = s.id, station = s.station, name = s.name, kind = s.kind, distance = s.distance, position = s.position }
        local all = idx().by_station[s.station] or {}
        local unl, ready = 0, {}
        for _, rid in ipairs(all) do
            if ctx.unlocked and ctx.unlocked[rid] then
                unl = unl + 1
                local a = M.assess(rid, 1, ctx)
                if a.status == "ready" and #ready < 12 then ready[#ready + 1] = a.name or rid end
            end
        end
        w.recipes, w.recipes_unlocked, w.can_make_now = #all, ctx.unlocked and unl or api.null, ready
        local actor = api.actor_of({ id = s.id, class = s.class })
        local st = actor and W.station_state(api, actor, s.kind)
        if st and s.kind == "processing" then
            local function names(c) local o = {}; for _, r in ipairs(c.rows) do o[#o + 1] = tostring(r.name or r.item) .. " x" .. r.count end; return o end
            w.state = { running = st.running, recipe = st.recipe, remaining_s = r1(st.remaining_s), fuel_s = r1(st.fuel_s),
                        resources = names(st.resources), fuel = names(st.fuel), output = names(st.output) }
        end
        out[#out + 1] = w
    end
    return { ok = true, data = { stations = out, unlocked_recipes = ctx.unlocked_n or api.null } }
end

local function recipes_tool(api, args)
    local ctx, bad = context(api)
    if not ctx then return bad end
    local limit = math.max(1, math.min(50, math.floor(tonumber(args.limit) or M.cfg.list_limit)))
    local list
    if need_str(args.item) then
        local id, hits, kind = M.resolve_item(args.item)
        if not id then
            return item_resolution_failure(api, args.item, hits, kind, limit, ctx)
        end
        list = M.candidates(id, tonumber(args.count) or 1, ctx)
    elseif need_str(args.station) then
        local want, sid = lower(args.station), nil
        for s, st in pairs(M.data().stations or {}) do if lower(s) == want or lower(st.name) == want then sid = s end end
        for _, s in ipairs(ctx.stations) do if s.id == args.station then sid = s.station end end
        if not sid then return api.fail("unknown_target", { station = args.station, detail = "I don't know a station called " .. args.station .. "." }) end
        list = {}
        for _, rid in ipairs(idx().by_station[sid] or {}) do list[#list + 1] = M.assess(rid, 1, ctx) end
        table.sort(list, function(x, y) if x.rank ~= y.rank then return x.rank > y.rank end return tostring(x.name) < tostring(y.name) end)
    else -- craftable now (default)
        list = M.craftable(ctx, { near_only = args.near_only == true })
    end
    local out = {}
    for i = 1, math.min(#list, limit) do out[i] = M.card(list[i]) end
    return { ok = true, data = { recipes = out, total = #list, unlocked_recipes = ctx.unlocked_n or api.null } }
end

local function plan_tool(api, args)
    local ctx, bad = context(api, nil, true)
    if not ctx then return bad end
    ctx.gather_for = W.gather_options(api)
    local goal
    if need_str(args.recipe) then goal = { recipe = args.recipe }
    elseif need_str(args.item) then
        local id, hits, kind = M.resolve_item(args.item)
        if not id then
            return item_resolution_failure(api, args.item, hits, kind, M.cfg.list_limit, ctx)
        end
        goal = { item = id }
    else return api.fail("invalid_args", { detail = "item or recipe is required" }) end
    local tree, why = M.plan_tree(goal, tonumber(args.count) or 1, ctx)
    if not tree then return api.fail(why, { recipe = args.recipe, detail = "I don't know that recipe." }) end
    return { ok = true, data = tree }
end

-- ------------------------------------------------------------------ get_state extras (honest perception)
-- client_bridge get_state calls this with the state it built (data.interactables = census rows).
-- Adds stations_nearby = [{id, name, station, distance, running?, making?, contents?}] (max 4), the
-- processing state read from the station's own component; cached M.cfg.extras_ttl_s.
M.cfg.extras_ttl_s = 5
function M.state_extras(api, data)
    local st = state()
    local now = api.now()
    if st.extras and st.extras_at and now - st.extras_at >= 0 and now - st.extras_at < M.cfg.extras_ttl_s then return st.extras end
    local rows = {}
    for _, t in ipairs(type(data) == "table" and data.interactables or {}) do
        local sid = M.station_type(t.class)
        if sid and #rows < 4 then
            local info = station_info(sid) or {}
            local r = { id = t.id, name = info.name or t.name, station = sid, distance = t.distance }
            if info.kind == "processing" then
                local a = api.actor_of({ id = t.id, class = t.class })
                local s = a and W.station_state(api, a, "processing")
                if s then
                    r.running = s.running
                    if s.recipe then r.making = s.recipe end
                    local c = {}
                    for _, x in ipairs(s.resources.rows) do c[#c + 1] = tostring(x.name or x.item) .. " x" .. x.count end
                    for _, x in ipairs(s.fuel.rows) do c[#c + 1] = tostring(x.name or x.item) .. " x" .. x.count .. " (fuel)" end
                    for _, x in ipairs(s.output.rows) do c[#c + 1] = tostring(x.name or x.item) .. " x" .. x.count .. " (done)" end
                    if #c > 0 then r.contents = c end
                end
            end
            rows[#rows + 1] = r
        end
    end
    table.sort(rows, function(x, y) return (x.distance or 0) < (y.distance or 0) end)
    st.extras, st.extras_at = (#rows > 0) and { stations_nearby = rows } or {}, now
    return st.extras
end

-- ------------------------------------------------------------------ handlers
local function guard(fn)
    return function(log, args, ctx)
        local api = ctx and ctx.api
        if not api then return { ok = false, reason = "body_error", data = { detail = "crafting needs the bridge api (ctx.api)" } } end
        if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
        return fn(api, args or {}, ctx)
    end
end

M.HANDLERS = {
    craft = guard(function(api, args, ctx)
        local job = start_craft(api, args, ctx)
        if job.ok == false then return job end
        return action(api, ctx, job)
    end),
    recipes = guard(recipes_tool),
    craft_plan = guard(plan_tool),
    stations = guard(stations_tool),
}

local FIND = { { "sense", "census" }, { "inventory", "list" } }
M.NEEDS = {
    craft = { { "sense", "census" }, { "inventory", "list" }, { "inventory", "interact_target" }, { "inventory", "press_interact" },
              { "move", "go_to" }, { "move", "status" } },
    recipes = FIND, craft_plan = FIND, stations = FIND,
}

-- ------------------------------------------------------------------ manifest (client_mod/scripts/manifest.lua shape)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
local function str(desc) return { type = "string", description = desc } end
M.MANIFEST = {
    craft = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 15, timeout_s = 300,
        detail_is_speech = true,
        description = "Make one recipe at a nearby station from carried items (walks there, uses it, collects the "
            .. "result). Does not gather or craft ingredients: see craft_plan.",
        args = { type = "object", properties = obj({
            item = str("Item to make (name or id)."),
            recipe = str("Recipe id, to pick one of several."),
            count = { type = "integer", minimum = 1, maximum = M.cfg.max_count, default = 1, description = "Items (crafts with recipe)." },
            station = str("Station id (default nearest)."),
            fuel = str("Fuel to burn (processing).") }) },
        preconditions = { "the recipe is unlocked", "you carry all inputs", "a station of its type is within 60 m" },
        ground = obj({ item = "item", station = "thing" }),
        reasons = { "missing_materials", "not_unlocked", "nothing_in_range", "ambiguous_target", "unknown_recipe", "station_busy",
                    "inventory_full", "not_interactable", "path_blocked", "too_far", "verification_failed", "timeout",
                    "craft_failed", "not_implemented", "interrupted" } },
    recipes = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "List recipes: craftable now (default), every recipe for an item with its status and missing "
            .. "inputs, or what a station makes.",
        args = { type = "object", properties = obj({
            item = str("Item name or id."),
            station = str("Station type, name or id."),
            count = { type = "integer", minimum = 1, default = 1, description = "How many wanted." },
            near_only = { type = "boolean", default = false, description = "Only stations near you." },
            limit = { type = "integer", minimum = 1, maximum = 50, default = 25 } }) },
        reasons = { "unknown_recipe", "ambiguous_target", "unknown_target", "state_unavailable" } },
    craft_plan = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "Inspect a goal item's required inputs and alternative acquisitions. Counts may be lower "
            .. "bounds; recipe execution and suggested craft steps can be conditional or unknown. Read only.",
        args = { type = "object", properties = obj({
            item = str("Goal item name or id."),
            recipe = str("Or a recipe id."),
            count = { type = "integer", minimum = 1, default = 1, description = "How many." } }) },
        reasons = { "unknown_recipe", "ambiguous_target", "invalid_args", "state_unavailable" } },
    stations = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "Stations near you: type, distance, unlocked recipes, what you can make now, and a furnace's "
            .. "state (running, contents, fuel, output).",
        args = { type = "object", properties = obj({
            radius = { type = "number", minimum = 5, maximum = 120, default = 60, description = "Metres." } }) },
        reasons = { "state_unavailable" } },
}

return M
