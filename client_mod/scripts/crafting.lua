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
-- Conceptual recipe/planning references, not Dragonwilds UI API documentation:
-- https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md#botcraftrecipe-count-craftingtable
-- https://sites.uci.edu/kolbynottingham/2024/10/30/mindcraft
-- https://arxiv.org/html/2412.21033v1
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
    -- the cache is per file size: a regenerated catalog (tools/build_recipes.py) loads with the module's next
    -- hot reload instead of staying stale until the client restarts (rung 3: the burnt-food alts, 17:20Z)
    local path = ROOT .. "/mod/body/recipe_data.lua"
    local f, size = io.open(path, "rb"), nil
    if f then size = f:seek("end"); f:close() end
    DATA = rawget(_G, "DWRecipeData")
    if not DATA or (size and rawget(_G, "DWRecipeDataSize") ~= size) then
        DATA = assert(loadfile(path))()
        _G.DWRecipeData, _G.DWRecipeDataSize = DATA, size
    end
    return DATA
end

-- Indexes over the catalog (built once per data table).
local function idx()
    local d = M.data()
    if M._idx and M._idx.data == d then return M._idx end
    local I = { data = d, id_of = {}, name_of = {}, path_of = {}, by_output = {}, by_input = {}, by_station = {}, class_sid = {} }
    for p, it in pairs(d.items or {}) do
        local id = it.id or asset(p)
        I.id_of[p], I.name_of[p], I.path_of[id] = id, it.name, p
    end
    local function id_of(p) I.id_of[p] = I.id_of[p] or asset(p); return I.id_of[p] end
    for rid, r in pairs(d.recipes or {}) do
        for _, o in ipairs(r.outputs or {}) do
            local id = id_of(o[1])
            I.path_of[id] = I.path_of[id] or o[1]
            local l = I.by_output[id] or {}; I.by_output[id] = l; l[#l + 1] = rid
        end
        for _, c in ipairs(r.inputs or {}) do
            local id = id_of(c[1]); I.path_of[id] = I.path_of[id] or c[1]
            local l = I.by_input[id] or {}; I.by_input[id] = l; l[#l + 1] = rid
        end
        for _, sid in ipairs(r.stations or {}) do
            local l = I.by_station[sid] or {}; I.by_station[sid] = l; l[#l + 1] = rid
        end
    end
    for _, l in pairs(I.by_output) do table.sort(l) end
    for _, l in pairs(I.by_input) do table.sort(l) end
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
    -- every word he said is a word of the name ("stone axe" -> Stone Logging Axe; live 17:10Z it read unknown)
    local qw = {}
    for w in lq:gmatch("%a+") do if #w > 2 then qw[#qw + 1] = w:gsub("s$", "") end end
    if #qw > 0 then
        for id in pairs(I.by_output) do
            local tok = {}
            for w in lower(name_of_id(id)):gmatch("%a+") do tok[(w:gsub("s$", ""))] = true end
            local all = true
            for _, w in ipairs(qw) do if not tok[w] then all = false; break end end
            if all then hits[#hits + 1] = id end
        end
        table.sort(hits)
        if #hits == 1 then return hits[1] end
        if #hits > 0 then return nil, hits end
    end
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

-- Candidates for an unresolved name (a category match lists its items, never picks one). With his context (ctx), each
-- carries its best recipe's status and the list is ordered best first, so what he can make now leads and is named in
-- the detail (live rung 4, 21:57Z: "bow" listed 41 names, crossbows and vestiges first, the Ash Shortbow he could make
-- never shown; he tried the locked longbow and gave up).
local function item_resolution_failure(api, query, hits, kind, limit, ctx)
    hits = hits or {}
    local best = {}
    if ctx then
        for _, id in ipairs(hits) do best[id] = M.candidates(id, 1, ctx)[1] or false end
        local function rk(id) return best[id] and best[id].rank or -1 end
        table.sort(hits, function(x, y) if rk(x) ~= rk(y) then return rk(x) > rk(y) end return name_of_id(x) < name_of_id(y) end)
    end
    local c, now = {}, {}
    for i = 1, math.min(#hits, limit) do
        local id = hits[i]
        local item = (M.data().items or {})[idx().path_of[id]] or {}
        local b = best[id]
        c[i] = { item = id, name = name_of_id(id), category = kind == "category" and item.category or nil, status = b and b.status or nil }
        if b and b.status == "ready" then now[#now + 1] = name_of_id(id) end
    end
    if #c == 0 then return api.fail("unknown_recipe", { item = query, detail = "I don't know how to make " .. tostring(query) .. "." }) end
    return api.fail("ambiguous_target", { item = query, candidates = c, total = #hits,
        detail = "\"" .. query .. "\" could be several things (" .. #hits .. ")" .. (#now > 0 and ("; I can make now: " .. table.concat(now, ", "))
            or (ctx and "; I can't make any of them right now" or "")) .. ". Which one do you mean?" })
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
    return table.concat(out, " OR ")
end
M.unlock_text = unlock_text

-- Which parts of a recipe's unlock rule he has met, in words (rung 3, live 18:05Z: "ALL ITEMS[ Flax ] AND ALL
-- ACTORS[ Spinning Wheel ]" with Flax carried read to him as a riddle: "no idea how to unlock it"). The rule counts
-- items he has PICKED UP and stations he has USED (W.discovered); disc nil = unknown, then nil.
function M.unlock_status(r, disc)
    if type(r) ~= "table" or type(r.uq) ~= "table" or not disc then return nil end
    local by_name = {}
    for id in pairs(disc.items or {}) do by_name[lower(name_of_id(id))] = true end
    local alts = {}
    for _, q in ipairs(r.uq) do
        local parts = {}
        for quant, kind, list in q:gmatch("(%u+)%s+(%u+)%[([^%]]*)%]") do
            for name in list:gmatch("[^,]+") do
                name = name:match("^%s*(.-)%s*$")
                if kind == "ITEMS" then
                    parts[#parts + 1] = "picked up " .. name .. ": " .. (by_name[lower(name)] and "yes" or "not yet")
                elseif kind == "ACTORS" then
                    local sid = idx().class_sid[name]
                    parts[#parts + 1] = "used a " .. tostring(sid and station_name(sid) or name) .. ": "
                        .. ((disc.actors or {})[name] and "yes" or "not yet")
                end
            end
            if quant == "ANY" and #parts > 1 then parts[#parts] = parts[#parts] .. " (any one of these)" end
        end
        if #parts > 0 then alts[#alts + 1] = table.concat(parts, "; ") end
    end
    return (#alts > 0) and table.concat(alts, " | or: ") or nil
end

-- True when the recipe's unlock is met except for "used a <station>" terms naming a station type that makes it and
-- stands near (ctx.near): the craft opens that station, and using one is what the game counts (ActorsInteractedWith;
-- live 18:22-18:25Z a press on his wheel made thread ready). A player just walks up and makes it (rung 4, 19:56Z:
-- Leather "not unlocked: used a Tannery: not yet" beside the Tannery he was about to use).
function M.unlocks_on_use(r, disc, near)
    if type(r) ~= "table" or type(r.uq) ~= "table" or not disc then return false end
    local by_name = {}
    for id in pairs(disc.items or {}) do by_name[lower(name_of_id(id))] = true end
    local here = {}
    for _, sid in ipairs(r.stations or {}) do if (near or {})[sid] then here[sid] = true end end
    for _, q in ipairs(r.uq) do
        local ok, by_use = true, false
        for quant, kind, list in q:gmatch("(%u+)%s+(%u+)%[([^%]]*)%]") do
            local met, total = 0, 0
            for name in list:gmatch("[^,]+") do
                name = name:match("^%s*(.-)%s*$")
                total = total + 1
                if kind == "ITEMS" and by_name[lower(name)] then met = met + 1
                elseif kind == "ACTORS" and (disc.actors or {})[name] then met = met + 1
                elseif kind == "ACTORS" and here[idx().class_sid[name] or ""] then met, by_use = met + 1, true end
            end
            if not ((quant == "ANY" and met > 0) or met == total) then ok = false end
        end
        if ok and by_use then return true end
    end
    return false
end

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
    -- the failed result a craft can give instead (burnt food: the recipe's AlternativeOutput, by the cook's level)
    p.alts = {}
    for _, c in ipairs(r.alt or {}) do p.alts[#p.alts + 1] = { path = c[1], item = item_id(c[1]), name = item_name(c[1]), per = c[2], chance = r.alt_chance } end
    if p.kind == "processing" then
        local pt = r.pt or {}
        local lo, hi = tonumber(pt[1]) or 0, tonumber(pt[2]) or tonumber(pt[1]) or 0
        -- the recipe's processing_time is the time per item as played: the station's processing_rate (5.0 on most) is no
        -- divisor (live: Tannery ~10 s a Leather, [8, 12]; dividing by 5 gave a 29 s wait for 3 and timed out at 2 of 3,
        -- 2026-11-02 03:2xZ). The wait still ends as soon as the outputs are in.
        p.seconds = ((lo + hi) / 2) * crafts
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
-- ctx = {have = {item_id = n}, native? = fn(item_id) -> n | nil, unlocked = {rid = true} | nil (unknown),
--        near = {sid = station row}}; native (context()) is the game's own per-item count, preferred over have.
-- -> {recipe, item, name, station, station_name, kind, crafts, viable, status, missing = {...},
--     unlock?, vendor?, station_row?, detail}
-- status: ready | not_unlocked | missing_input | no_station | vendor | no_station_type
local RANK = { ready = 5, missing_input = 4, no_station = 3, not_unlocked = 2, unlock_unknown = 2, vendor = 1, no_station_type = 0 }
M.RANK = RANK

function M.assess(rid, crafts, ctx)
    local r = recipe_of(rid)
    local p = M.plan(rid, crafts)
    local a = { recipe = rid, crafts = crafts, missing = {}, inputs = {}, outputs = {} }
    local out1 = p.outputs[1]
    a.item, a.name = out1 and out1.item, out1 and out1.name
    for _, c in ipairs(p.inputs) do
        local have = (ctx.native and ctx.native(c.item)) or (ctx.have or {})[c.item] or 0
        a.inputs[#a.inputs + 1] = { item = c.item, name = c.name, need = c.count, have = have }
        if have < c.count then a.missing[#a.missing + 1] = { item = c.item, name = c.name, need = c.count, have = have } end
    end
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
    if not unl then a.unlock = unlock_text(r) end
    local on_use = unl == false and ctx.discovered ~= nil and M.unlocks_on_use(r, ctx.discovered(), ctx.near)
    if on_use then unl, a.unlock_on_use = true, true end -- using the station near him unlocks it: makeable
    if #(r.stations or {}) == 0 then
        a.status, a.detail = "no_station_type", "nothing in the game crafts " .. tostring(a.name or rid) .. " at a station"
    elseif vendor then
        a.status, a.vendor = "vendor", true
        a.detail = (a.name or rid) .. " is bought from " .. tostring(a.station_name) .. ", and I can't trade with vendors yet"
    elseif unl == false then
        a.status = "not_unlocked"
        a.unlock_status = M.unlock_status(r, ctx.discovered and ctx.discovered() or nil)
        a.detail = "I haven't unlocked " .. tostring(a.name or rid) .. " yet" .. (a.unlock_status
            and (" (it unlocks once I've " .. a.unlock_status .. ")")
            or (a.unlock and (" (it unlocks with: " .. a.unlock .. ")") or ""))
    elseif unl == nil then
        a.status, a.detail = "unlock_unknown", "I can't read which recipes I've unlocked right now"
    elseif #a.missing > 0 then
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

-- Every recipe that takes item_id as an input, assessed, best first: what a station turns a carried item into (a
-- player puts raw meat on a fire). crafts nil = as many as the carried stack makes (at least 1).
function M.uses(item_id_, crafts, ctx)
    local out = {}
    local have = (ctx.native and ctx.native(item_id_)) or (ctx.have or {})[item_id_] or 0
    for _, rid in ipairs(idx().by_input[item_id_] or {}) do
        local need = 1
        for _, c in ipairs(recipe_of(rid).inputs or {}) do if item_id(c[1]) == item_id_ then need = math.max(1, c[2] or 1) end end
        out[#out + 1] = M.assess(rid, crafts or math.max(1, math.min(M.cfg.max_count, math.floor(have / need))), ctx)
    end
    table.sort(out, function(x, y)
        if x.rank ~= y.rank then return x.rank > y.rank end
        if #x.missing ~= #y.missing then return #x.missing < #y.missing end
        return x.recipe < y.recipe
    end)
    return out
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

-- Food that can burn: the recipe's alt output behind ChanceToBurnFoodLevelN (the ingredient's power level). The
-- Cooking levels per power level are the wiki's Culinary Confidence table (50 % not burnt at the first level,
-- 100 % at the second; https://dragonwilds.runescape.wiki/w/Culinary_Confidence, read 2026-11-01). Live 17:07 and
-- 17:40Z: ClaudeDev at Cooking 7-8 burnt 5 of 5 Raw Farm Meat (power level 2, below its first level 12).
M.BURN_LEVELS = { { 1, 12 }, { 12, 27 }, { 27, 41 }, { 41, 50 }, { 50, 75 }, { 75, 99 } }
-- The game's OWN odds come first (2026-11-02): his ChanceToBurnFoodLevelN attributes (W.burn_odds, cached by context())
-- are the chance at his Cooking right now; the wiki levels above only say from when it stops ("none from N").
-- Perception only: every cook is listed with its odds and he chooses (no recipe is skipped or vetoed here).
M.cfg.burn_ttl_s = 30
local function burn_note(rid)
    local r = recipe_of(rid) or {}
    local n = tonumber(tostring(r.alt_chance or ""):match("ChanceToBurnFoodLevel(%d+)"))
    if not n or not r.alt or not r.alt[1] then return nil end
    local lv = M.BURN_LEVELS[n] or {}
    local into = item_name(r.alt[1][1]) or item_id(r.alt[1][1])
    local raw = r.inputs and r.inputs[1] and (item_name(r.inputs[1][1]) or item_id(r.inputs[1][1])) or "it"
    local odds = (state().burn_odds or {})[n]
    local text
    if type(odds) == "number" then
        local pct = math.floor(odds * 100 + 0.5)
        text = raw .. (pct <= 0 and ": never burns at your Cooking now"
                       or pct >= 100 and (": always burns at your Cooking now (comes out as " .. tostring(into) .. ")")
                       or (": burns about " .. pct .. "% of the time at your Cooking now (comes out as " .. tostring(into) .. ")"))
            .. " (the game's own odds, power level " .. n .. " food)"
            .. ((pct > 0 and lv[2]) and ("; none from Cooking " .. lv[2] .. " (wiki)") or "")
    else
        text = "can come out as " .. tostring(into) .. ": power level " .. n .. " food; "
            .. ((tonumber(lv[1]) or 1) > 1 and ("below Cooking " .. lv[1] .. " most burn, ") or "")
            .. "at Cooking " .. tostring(lv[1]) .. " about half, from " .. tostring(lv[2]) .. " none"
    end
    return { into = into, food_power_level = n, chance = odds, source = odds and "game" or "wiki", text = text }
end
M.burn_note = burn_note

-- Wire form of an assessment.
function M.card(a)
    local c = { recipe = a.recipe, name = a.name, item = a.item, crafts = a.crafts, status = a.status, station = a.station,
                station_name = a.station_name, kind = a.kind, inputs = a.inputs, outputs = a.outputs, detail = a.detail,
                may_burn = burn_note(a.recipe) }
    if #a.missing > 0 then c.missing = a.missing end
    if a.unlock then c.unlock = a.unlock end
    if a.unlock_status then c.unlock_status = a.unlock_status end
    if a.station_row then c.station_id, c.station_distance = a.station_row.id, a.station_row.distance end
    return c
end

-- ------------------------------------------------------------------ the crafting tree (pure, read-only)
-- plan_tree(goal = {item | recipe}, count, ctx + {gather_for = fn(item_id) -> resource name | nil,
--           quantity_mode = "additional_output" (default: count MORE, carried ones don't count) | "inventory_target"
--           (reach count in total)})
-- -> {root = node, steps = {...}, missing = {...}, ready = bool, quantity_mode}
-- node = {item, name, need, have, status, recipe?, station?, crafts?, inputs = {nodes}, alternatives = {...},
--         unlock?, gather?}
-- status: have | craft (ready now) | craft_after (needs its inputs first) | not_unlocked | no_station |
--         gather | obtain | vendor | cycle | depth
-- The pool of carried items is shared across the tree, so two branches never count the same logs twice.
-- Every alternative recipe is listed at its node; only the first ranked one is expanded.
function M.plan_tree(goal, count, ctx)
    count = math.max(1, math.floor(tonumber(count) or 1))
    local mode = ctx.quantity_mode or "additional_output"
    local pool, seeded = copy(ctx.have), {}
    local steps, missing = {}, {}
    local function take(item, n)
        if ctx.native and not seeded[item] then seeded[item] = true; pool[item] = ctx.native(item) or pool[item] end
        local have = math.min(pool[item] or 0, n)
        pool[item] = (pool[item] or 0) - have
        return have
    end
    local node
    local function expand(rid, item, need, depth, stack)
        local r = recipe_of(rid)
        local per = math.max(1, per_craft(r, item))
        local crafts = math.ceil(need / per)
        local a = M.assess(rid, crafts, { have = {}, unlocked = ctx.unlocked, near = ctx.near })
        local n = { recipe = rid, crafts = crafts, station = a.station, station_name = a.station_name, kind = a.kind, inputs = {} }
        stack[item] = true
        local inputs_ok = true
        for _, c in ipairs(M.plan(rid, crafts).inputs) do
            local child = node(c.item, c.count, depth + 1, stack)
            n.inputs[#n.inputs + 1] = child
            if child.status ~= "have" then inputs_ok = false end
        end
        stack[item] = nil
        if a.status == "vendor" or a.status == "not_unlocked" or a.status == "unlock_unknown" then
            n.status, n.unlock, n.detail = a.status == "vendor" and "vendor" or "not_unlocked", a.unlock, a.detail
            if a.status ~= "vendor" then steps[#steps + 1] = { ["do"] = "unlock", recipe = rid, name = a.name, how = a.unlock } end
        elseif not a.station_row then
            n.status, n.detail = "no_station", a.detail
            steps[#steps + 1] = { ["do"] = "find_station", station = a.station, name = a.station_name, recipe = rid }
        else
            n.status = inputs_ok and "craft" or "craft_after"
            n.station_id = a.station_row.id
        end
        steps[#steps + 1] = { ["do"] = "craft", recipe = rid, item = item, name = name_of_id(item), crafts = crafts,
                              count = crafts * per, station = a.station, station_name = a.station_name,
                              ready = n.status == "craft" or nil }
        -- a processing station's own time per batch (recipe data, e.g. Leather 8-12 s): what a long load costs, so a
        -- speed-up (Overdrive on a tannery) can be weighed before it starts (live 2026-11-02: 6 hides waited out 38 s)
        local pt = r and type(r.processing_time) == "table" and tonumber(r.processing_time[1]) and r.processing_time or nil
        if pt then
            local lo, hi = tonumber(pt[1]), tonumber(pt[2]) or tonumber(pt[1])
            steps[#steps].each_s = lo == hi and lo or { lo, hi }
            steps[#steps].takes_s = math.floor(crafts * (lo + hi) / 2 + 0.5)
        end
        return n
    end
    node = function(item, need, depth, stack)
        local n = { item = item, name = name_of_id(item), need = need }
        -- additional_output: the goal item he already carries does not count toward the goal
        n.have = (depth == 0 and mode == "additional_output") and 0 or take(item, need)
        local short = need - n.have
        if short <= 0 then n.status = "have"; return n end
        n.short = short
        if stack[item] then n.status = "cycle"; missing[#missing + 1] = { item = item, name = n.name, count = short }; return n end
        if depth > M.cfg.plan_depth then n.status = "depth"; missing[#missing + 1] = { item = item, name = n.name, count = short }; return n end
        local cands = {}
        for _, rid in ipairs(idx().by_output[item] or {}) do
            local r = recipe_of(rid)
            if r and #(r.stations or {}) > 0 and #(r.inputs or {}) > 0 then
                local a = M.assess(rid, math.ceil(short / math.max(1, per_craft(r, item))), { have = pool, unlocked = ctx.unlocked, near = ctx.near })
                cands[#cands + 1] = a
            end
        end
        table.sort(cands, function(x, y)
            if x.rank ~= y.rank then return x.rank > y.rank end
            if #x.missing ~= #y.missing then return #x.missing < #y.missing end
            return x.recipe < y.recipe
        end)
        local res = ctx.gather_for and ctx.gather_for(item) or nil
        -- a gatherable raw material is gathered unless an unlocked, station-ready recipe exists
        if res and not (cands[1] and (cands[1].status == "ready" or cands[1].status == "missing_input")) then
            n.status, n.gather = "gather", res
            steps[#steps + 1] = { ["do"] = "gather", resource = res, item = item, name = n.name, count = short }
        elseif #cands == 0 then
            n.status = "obtain"
            steps[#steps + 1] = { ["do"] = "obtain", item = item, name = n.name, count = short }
            missing[#missing + 1] = { item = item, name = n.name, count = short }
        else
            local sub = expand(cands[1].recipe, item, short, depth, stack)
            for k, v in pairs(sub) do n[k] = v end
            if res then n.gather_instead = res end
        end
        if #cands > 1 or (res and #cands > 0) then
            n.alternatives = {}
            for i = (n.recipe and 2 or 1), #cands do
                local c = cands[i]
                n.alternatives[#n.alternatives + 1] = { recipe = c.recipe, status = c.status, station = c.station_name, detail = c.detail }
            end
        end
        return n
    end
    local root
    if goal.recipe then
        local rid = M.recipe(goal.recipe)
        if not rid then return nil, "unknown_recipe" end
        local r = recipe_of(rid)
        local out = r.outputs[1] and item_id(r.outputs[1][1])
        root = { item = out, name = out and name_of_id(out), need = count * per_craft(r, out), have = 0 }
        local sub = expand(rid, out, root.need, 0, {})
        for k, v in pairs(sub) do root[k] = v end
    else
        root = node(goal.item, count, 0, {})
    end
    local ready = root.status == "have" or root.status == "craft"
    return { root = root, steps = steps, missing = missing, ready = ready, quantity_mode = goal.recipe and "additional_output" or mode }
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

-- The game's own chance to burn food of each power level for HIS character: Dominion float attributes
-- ChanceToBurnFoodLevel1..6 (the Cooking perks GE_PerkV2_Cooking_ChanceToBurn_LevelN move them), read with
-- UAttributeFunctionLibrary.BP_TryGetFloatAttributeValue (out params filled as tables OutAttributeValue / OutbFound;
-- live 2026-11-02 ClaudeDev: L1 0.0, L2 0.4615, L3-6 1.0). Read-only. -> {[n] = chance 0..1} | nil
function W.burn_odds(api)
    local U, s = sense_U(api)
    local pawn = U and s and type(s.local_pawn) == "function" and s.local_pawn() or nil
    local lib = U and U.try(StaticFindObject, "/Script/Dominion.Default__AttributeFunctionLibrary")
    if not (U and U.valid(pawn) and U.valid(lib)) then return nil end
    local out, any = {}, false
    for n = 1, 6 do
        local cls = U.try(StaticFindObject, "/Script/Dominion.ChanceToBurnFoodLevel" .. n)
        if U.valid(cls) then
            local v, f = {}, {}
            local ok = pcall(function() lib:BP_TryGetFloatAttributeValue(pawn, cls, -1.0, v, f) end)
            if ok and f.OutbFound == true and type(v.OutAttributeValue) == "number" and v.OutAttributeValue >= 0 then
                out[n], any = v.OutAttributeValue, true
            end
        end
    end
    return any and out or nil
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

-- A station's shelter rule (UBuildingShelterComponent "BuildingShelter" on BP_Station_Spinning_Wheel_C, dump
-- 26161880): InteractionRequirements 0 InteractInShelterOnly / 1 InteractExternallyOnly / 2 InteractAnywhere, and the
-- game's own words. Over it: a trace from 2.2 m to 10 m above the station (anything there = a roof, maybe a tree).
-- -> {rule = "shelter_only" | "outside_only", says = text, covered = true | false | nil} | nil (no rule)
local SHELTER_RULES = { [0] = "shelter_only", [1] = "outside_only" }
function W.shelter(api, actor, pos)
    local U = sense_U(api)
    local c = U and U.try(function() return actor.BuildingShelter end)
    if not (U and U.valid(c)) then return nil end
    local req = tonumber(U.try(function() return c.InteractionRequirements end))
    local rule = req and SHELTER_RULES[req]
    if not rule then return nil end
    local says = U.str(U.try(function() return rule == "shelter_only" and c.RequiresShelterText or c.RequiresNoShelterText end))
    local out = { rule = rule, says = (says and says ~= "" and says ~= "None") and says or nil }
    local b = api.module("build")
    if pos and b and b.W and type(b.W.trace) == "function" then
        local ok, hit = pcall(b.W.trace, api, { X = pos[1] * 100, Y = pos[2] * 100, Z = (pos[3] + 2.2) * 100 },
            { X = pos[1] * 100, Y = pos[2] * 100, Z = (pos[3] + 10) * 100 })
        if ok then out.covered = hit == true end
    end
    return out
end
function M.shelter_words(sh, name)
    if not sh then return nil end
    -- the game's text is a tail after the station's name (live 19:0xZ: " needs more surrounding shelter.")
    local says = sh.says and sh.says:match("^%s*(.-)%s*$")
    if says and says:match("^%l") then says = tostring(name) .. " " .. says end
    local quote = says and (" (the game says: \"" .. says .. "\")") or ""
    if sh.rule == "shelter_only" then
        return "the " .. tostring(name) .. " only works in a shelter, walls and a roof round it" .. quote
            .. (sh.covered == false and ", and there is open sky over this one" or sh.covered and ", and something is over this one" or "")
    end
    return "the " .. tostring(name) .. " only works outside, not under a roof" .. quote
end

-- What his unlock rules count (UProgressComponent, dump 26161880): ItemsPickedUp (TSet<UItemData*>, "ITEMS[...]")
-- and ActorsInteractedWith (TSet<TSubclassOf<AActor>>, "ACTORS[...]": a station used at least once).
-- -> {items = {item_id = true}, actors = {class_short = true}} | nil
function W.discovered(api)
    local U = sense_U(api)
    local pc = local_pc(api)
    local prog = pc and U and U.try(function() return pc.ProgressComponent end)
    if not (U and U.valid(prog)) then return nil end
    local out, n = { items = {}, actors = {} }, 0
    for field, key in pairs({ ItemsPickedUp = "items", ActorsInteractedWith = "actors" }) do
        pcall(function()
            prog[field]:ForEach(function(a, b)
                local e = b ~= nil and b or a
                local v = U.try(function() return e:get() end)
                local path = U.path_of(v ~= nil and v or e)
                local short = path and path:match("%.([%w_]+)$")
                if short then out[key][short] = true; n = n + 1 end
            end)
        end)
    end
    if n == 0 then return nil end
    return out
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
        local c = U and U.prop(actor, p) -- Blueprint variables, on any station class: U.prop (R17)
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

-- Room for what a station makes: a free InventoryItems slot (inventory.free_slot) and his carry weight
-- (move.encumbrance). A station whose output finds no room drops it on the ground by itself (live 2026-11-02 00:31Z:
-- bag 32/32 and 406/400, the Tannery's 2 Leather left lying there). -> { free_slot = bool|nil, weight, max_weight, over }
function W.room(api)
    local out = {}
    local inv, mv = api.module("inventory"), api.module("move")
    if inv and type(inv.free_slot) == "function" then
        local ok, s = pcall(inv.free_slot, "InventoryItems")
        if ok then out.free_slot = s ~= nil end
    end
    if mv and type(mv.encumbrance) == "function" then
        local ok, e = pcall(mv.encumbrance)
        if ok and type(e) == "table" and tonumber(e.cur) and tonumber(e.max) then
            out.weight, out.max_weight = math.floor(e.cur * 10 + 0.5) / 10, math.floor(e.max * 10 + 0.5) / 10
            out.over = e.on == true or e.cur > e.max
        end
    end
    return out
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

local function refresh_burn(api)
    local st, t = state(), api.now()
    if st.burn_at and t - st.burn_at >= 0 and t - st.burn_at < M.cfg.burn_ttl_s then return st.burn_odds end
    local ok, odds = pcall(W.burn_odds, api)
    st.burn_odds, st.burn_at = (ok and odds) or st.burn_odds, t
    return st.burn_odds
end

local function context(api, radius_m)
    local have = api.counts()
    if not have then return nil, api.fail("state_unavailable", { detail = "I can't read my inventory right now." }) end
    refresh_burn(api)
    local rows = M.stations(api, radius_m)
    local unl, n = unlocked(api)
    -- the game's own total for an item (GetNumItemsByData) when it can be read; else the slot count stands.
    -- One read per item per context (craftable() assesses every unlocked recipe).
    local inv, seen = api.module("inventory"), {}
    local function native(item)
        if seen[item] == nil then
            local path = idx().path_of[item]
            seen[item] = path and inv and type(inv.count_item) == "function" and inv.count_item(path) or false
        end
        return seen[item] or nil
    end
    -- what the unlock rules count, read lazily (only a locked recipe asks)
    local disc, disc_read = nil, false
    local function discovered()
        if not disc_read then disc_read = true; disc = W.discovered(api) end
        return disc
    end
    return { have = have, native = native, unlocked = unl, unlocked_n = n, near = near_map(rows), stations = rows,
             discovered = discovered }
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
        local move = rawget(_G, "DW_MOVE")
        if move and move.mode ~= "idle" and move.owner_token == job.token then
            if api.log then api.log("cleanup unconfirmed: parent still owns active movement") end
            return false
        end
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
        if (not e.goal and d and d <= M.cfg.reach_m) or at_goal then
            local sk=api.module("skills")
            if e.moving and not (sk and sk._episode_cleanup and sk._episode_cleanup(api,e,job.token)) then return nil end
            if e.child_lost then return api.fail("interrupted",{detail="craft movement was replaced"}) end
            e.phase, e.face_until = "face", t + M.cfg.face_s; return nil
        end
        if not e.moving then
            if e.approaches >= M.cfg.approaches then
                return api.fail("too_far", { station = row.id, distance = d and r1(d), detail = "I can't get close enough to the " .. tostring(row.name) .. "." })
            end
            local A=arbiter(api)
            if not job.token or not (A and A.owns_move and A.owns_move(job.token)) then
                return api.fail("interrupted",{detail="craft movement ownership unavailable"})
            end
            local mr = api.call("move", "go_to", e.goal or stand_point(here or row.position, row.position, M.cfg.stand_m),
                                { tolerance_m = M.cfg.approach_tol_m, timeout_s = 60, owner_token = job.token })
            if not mr.ok then return mr end
            e.moving=true -- keep ownership if a successful start lacks its generation
            local gen=(mr.data and mr.data.gen) or mr.gen
            if type(gen)~="number" or gen%1~=0 then return api.fail("verification_failed",{detail="craft movement generation unavailable"}) end
            e.child_gen,e.child_token,e.moving=gen,job.token,true
            local bound=api.call("move","child_status",gen,job.token)
            if not (bound and bound.ok) then return nil end
            if ((bound.data and bound.data.mode) or bound.mode)=="superseded" then
                e.child_lost=true;return api.fail("interrupted",{detail="craft movement was replaced"})
            end
            e.approaches = e.approaches + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        local sk=api.module("skills")
        if not (sk and sk._episode_cleanup and sk._episode_cleanup(api,e,job.token)) then return nil end
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
            local actor = api.actor_of({ id = row.id, class = row.class })
            local sh = actor and W.shelter(api, actor, row.position)
            local why = M.shelter_words(sh, row.name)
            return api.fail("verification_failed", { station = row.id, shelter = sh,
                detail = "I pressed use on the " .. tostring(row.name) .. " but its menu didn't open"
                    .. (why and ("; " .. why) or "") .. "." })
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
    if not need_str(args.item) and need_str(args.input) then -- what a station makes from this carried item
        local id, hits, kind = M.resolve_item(args.input)
        if not id then return nil, item_resolution_failure(api, args.input, hits, kind, 10) end
        local list = M.uses(id, args.count ~= nil and count or nil, ctx)
        if #list == 0 then
            return nil, api.fail("unknown_recipe", { input = id, detail = "Nothing in the game is made from " .. name_of_id(id) .. "." })
        end
        return list, nil, id
    end
    if not need_str(args.item) then return nil, api.fail("invalid_args", { detail = "item, input or recipe is required" }) end
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

-- Stations he loaded himself (id -> when), kept across hot reloads: what sits in any other station's input slots is
-- someone else's, and he never adds to it, spins it or cooks it (Luis's rule: never take from his stations or
-- containers; live 18:22Z the model aimed a fur craft at Luis's Spinning Wheel, which holds Luis's 2 fur).
local function loads_ledger()
    local l = rawget(_G, "DWCraftLoads")
    if not l then l = {}; _G.DWCraftLoads = l end
    return l
end
local LEDGER_S = 3600
local function foreign_inputs(api, station_id, rows)
    local mine = loads_ledger()[station_id]
    if mine and api.now() - mine < LEDGER_S then return nil end
    local held = {}
    for _, r in ipairs(rows or {}) do held[#held + 1] = tostring(r.count) .. " " .. tostring(r.name or name_of_id(r.item)) end
    return (#held > 0) and table.concat(held, ", ") or nil
end

-- A processing station that can take this recipe's inputs now: not running another recipe, and every input has a
-- slot (its own stack or a free one). nil + what blocks it otherwise (rung 3: Luis's Spinning Wheel holds his
-- fur in its only slot; the nearest wheel must not win over Claude's own empty one).
local function station_takes(api, row, a)
    local actor = api.actor_of({ id = row.id, class = row.class })
    local s = actor and W.station_state(api, actor, "processing")
    if not s then return true end -- unreadable: the load step reports the truth
    if s.running and s.recipe and s.recipe ~= a.recipe then return false, "it is making " .. tostring(s.recipe) end
    local theirs = foreign_inputs(api, row.id, s.resources.rows)
    if theirs then return false, "it holds " .. theirs .. " that someone else left" end
    local sh = W.shelter(api, actor, row.position)
    if sh and sh.rule == "shelter_only" and sh.covered == false then return false, "it only works in a shelter and has open sky over it" end
    local want, have, used = {}, {}, 0
    for _, c in ipairs(a.inputs or {}) do want[c.item] = true end
    local foreign = {}
    for _, r in ipairs(s.resources.rows) do
        used = used + 1
        have[r.item] = true
        if not want[r.item] then foreign[#foreign + 1] = tostring(r.count) .. " " .. tostring(r.name or name_of_id(r.item)) end
    end
    local need = 0
    for it in pairs(want) do if not have[it] then need = need + 1 end end
    if need <= (s.resources.slots or 0) - used then return true end
    return false, "it already holds " .. (#foreign > 0 and table.concat(foreign, ", ") or "other things")
end

local function start_craft(api, args, ctx0)
    -- lying in a bed or shelter, the game lets him neither walk nor use a station (rung 3 gate 19:56Z: "I can't get
    -- the game to let me use the Crafting Table", 6 sides tried, while he lay in the Summon Shelter)
    local sk = api.module and api.module("skills")
    local bed = sk and sk.W and type(sk.W.resting_in) == "function" and select(2, pcall(sk.W.resting_in, api)) or nil
    if type(bed) == "string" then
        return api.fail("resting", { resting_in = bed, detail = "I'm lying in " .. bed .. ", so I can't walk to a "
            .. "station or use one until I get up (interact on that bed)." })
    end
    local ctx, bad = context(api)
    if not ctx then return bad end
    if ctx.unlocked == nil then
        return api.fail("state_unavailable", { detail = "I can't read which recipes I've unlocked right now." })
    end
    local list, err, item = resolve_candidates(api, args, ctx)
    if not list then return err end
    local viable = {}
    for _, a in ipairs(list) do if a.viable then viable[#viable + 1] = a end end
    if args.recipe == nil and #viable > 1 then
        local names = {}
        for _, a in ipairs(viable) do names[#names + 1] = a.recipe end
        local from = not need_str(args.item) and need_str(args.input)
        return api.fail("ambiguous_target", { item = item, candidates = cand_wire(viable),
            detail = from and ("I can make " .. #viable .. " things from " .. name_of_id(item) .. " here; which recipe should I use?")
                or ("I can make " .. name_of_id(item) .. " " .. #viable .. " ways; which recipe should I use?") })
    end
    local a = viable[1]
    if not a then
        local best = list[1]
        local reason = ({ not_unlocked = "not_unlocked", unlock_unknown = "state_unavailable", missing_input = "missing_materials",
                          no_station = "nothing_in_range", vendor = "not_implemented", no_station_type = "unknown_recipe" })[best.status] or "unknown_recipe"
        -- a recipe he named can't be made, but another recipe for the same item can right now: say so (live 18:24Z:
        -- he asked for thread from fur, locked, while thread from his Flax was ready, and gave up)
        local instead
        if args.recipe ~= nil and best.item then
            for _, o in ipairs(M.candidates(best.item, 1, ctx)) do -- one craft: what he could start with
                if o.viable and o.recipe ~= best.recipe then instead = o; break end
            end
        end
        local detail = (best.detail or "I can't make that.")
        if instead then
            local ins = {}
            for _, c in ipairs(instead.inputs or {}) do ins[#ins + 1] = c.need .. " " .. tostring(c.name) end
            detail = detail .. "; but I can make " .. tostring(instead.name) .. " now from " .. table.concat(ins, " + ")
                .. " each (recipe " .. instead.recipe .. ")"
        end
        return api.fail(reason, { recipe = best.recipe, item = best.item, missing = (#best.missing > 0) and best.missing or nil,
            unlock = best.unlock, unlock_status = best.unlock_status, station = best.station_name,
            candidates = (#list > 1) and cand_wire(list) or nil,
            ready_instead = instead and { recipe = instead.recipe, name = instead.name, inputs = instead.inputs } or nil,
            detail = detail .. "." })
    end
    local row, perr = pick_station(api, a, args, ctx)
    if not row then return perr end
    local passed = {}
    if not need_str(args.station) and a.kind == "processing" then
        local ok_type = {}
        for _, sid in ipairs(recipe_of(a.recipe).stations or {}) do ok_type[sid] = true end
        local free
        for _, s in ipairs(ctx.stations) do -- nearest first
            if ok_type[s.station] then
                local ok, why = station_takes(api, s, a)
                if ok then free = s; break end
                passed[#passed + 1] = { id = s.id, name = s.name, why = why }
            end
        end
        row = free or row
        if not free then passed = {} end -- none free: the nearest one's load step says what fills it
    end
    if a.kind == "processing" then -- never walk to and open a station holding someone else's inputs (Luis's rule)
        local actor = api.actor_of({ id = row.id, class = row.class })
        local st = actor and W.station_state(api, actor, "processing")
        local theirs = st and foreign_inputs(api, row.id, st.resources.rows)
        if theirs then
            return api.fail("station_busy", { station = row.name, station_id = row.id, someone_elses = theirs,
                detail = "The " .. tostring(row.name) .. " " .. tostring(row.id) .. " holds " .. theirs
                    .. " that someone else left, so I won't use it: those aren't mine." })
        end
    end
    local plan = M.plan(a.recipe, a.crafts, row.station)
    local job = { kind = "craft", a = a, plan = plan, station = row, alternatives = {}, ctx = ctx, args = args,
                  passed = (#passed > 0) and passed or nil }
    for _, o in ipairs(list) do if o ~= a then job.alternatives[#job.alternatives + 1] = { recipe = o.recipe, status = o.status } end end
    job.open = { phase = "approach", moving = false, approaches = 0, presses = 0 }
    job.phase = "open"
    job.before = copy(ctx.have)
    W.arm_result_hook(api)
    return job
end

-- Counts helpers: nil when either inventory read failed (unknown, never a zero)
local function gained(before, now, item)
    if type(before) ~= "table" or type(now) ~= "table" then return nil end
    return (now[item] or 0) - (before[item] or 0)
end

local function base_data(job)
    local d = { recipe = job.a.recipe, recipe_chosen = job.a.recipe, item = job.a.item, crafts = job.a.crafts,
                station = job.station.name, station_id = job.station.id, alternatives = job.alternatives }
    if job.passed then -- nearer stations he did not use, and why (so he can say which one he used)
        d.passed_stations = job.passed
        local w = {}
        for _, p in ipairs(job.passed) do w[#w + 1] = "the nearer " .. tostring(p.name) .. " (" .. tostring(p.why) .. ")" end
        d.why_this_station = "I used the " .. tostring(job.station.name) .. " " .. tostring(job.station.id) .. ", not " .. table.concat(w, "; ")
    end
    return d
end

-- bench: send -> await verdict + inventory
local function bench_step(api, job, t)
    if job.phase == "send" then
        job.before = api.counts() or job.before -- fresh: he may have eaten or picked up on the way
        job.seq0 = state().seq or 0
        local ok, err = W.send_craft(api, job.a.recipe, job.a.crafts)
        if not ok then return api.fail("not_implemented", { detail = "The crafting menu didn't take my order (" .. tostring(err) .. ")." }) end
        job.phase, job.until_t = "await", t + M.cfg.result_wait_s + (job.plan.seconds or 0)
        return nil
    end
    -- await: only a verdict for this recipe and count is ours
    local path = (recipe_of(job.a.recipe) or {}).path
    local v
    for _, e in ipairs(W.results_since(job.seq0)) do
        if e.recipe_path == path and e.count == job.a.crafts then v = e end
    end
    local now = api.counts()
    local out = job.plan.outputs[1]
    local got = out and gained(job.before, now, out.item) or nil
    if v and v.result and v.result ~= 0 then
        local reason, words = M.result_failure(v.result, out and out.name)
        local d = base_data(job)
        d.result_code, d.detail = v.result, words
        return api.fail(reason, d)
    end
    local want = out and out.count or 1
    if got and got >= want then
        local d = base_data(job)
        local consumed = {}
        for _, c in ipairs(job.plan.inputs) do consumed[#consumed + 1] = { item = c.item, name = c.name, count = -gained(job.before, now, c.item) } end
        d.count, d.gained, d.consumed, d.result_code = got, got, consumed, v and v.result or api.null
        d.detail = "I made " .. got .. " " .. tostring(out.name) .. " at the " .. tostring(job.station.name) .. "."
        return { ok = true, data = d }
    end
    if t >= job.until_t then
        local d = base_data(job)
        if v and v.result == 0 then
            d.result_code = 0
            d.detail = got == nil and "The game said the craft worked, but I couldn't read my inventory to check."
                or ("The game said the craft worked, but the " .. tostring(out and out.name) .. " didn't show up in my inventory.")
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
    if not lr.ok then return rows end
    local d = lr.data or {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, r in ipairs(d[where] or {}) do if r.item == item and (tonumber(r.count) or 0) > 0 then rows[#rows + 1] = r end end
    end
    return rows
end

local function proc_setup(api, job)
    local actor = station_actor(api, job)
    local s = actor and W.station_state(api, actor, "processing")
    if not s then return api.fail("state_unavailable", { station = job.station.id, detail = "I can't read the " .. tostring(job.station.name) .. " right now." }) end
    job.actor, job.st0 = actor, s
    job.station_before = { resources = s.resources.rows, fuel = s.fuel.rows, output = s.output.rows, running = s.running,
                           recipe = s.recipe }
    local theirs = foreign_inputs(api, job.station.id, s.resources.rows)
    if theirs then
        local d = base_data(job)
        d.station_before, d.someone_elses = job.station_before, theirs
        d.detail = "The " .. tostring(job.station.name) .. " holds " .. theirs .. " that someone else left, so I won't use it: "
            .. "those aren't mine."
        return api.fail("station_busy", d)
    end
    local fuel_by_item = s.fuel.by_item
    local f, why, fd = M.choose_fuel(job.plan, job.args.fuel, job.ctx.have, fuel_by_item)
    if not f then
        local d = base_data(job); for k, v in pairs(fd or {}) do d[k] = v end
        d.station_before = job.station_before
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
            loads_ledger()[job.station.id] = api.now()
            job.loaded[q.item] = (job.loaded[q.item] or 0) + job.moving.amount
            q.count = q.count - job.moving.amount
            job.moving = nil
            if q.count <= 0 then table.remove(job.queue, 1) end
            -- the next drag, or the start, in this same poll (live 17:40Z: 1.2 s from the fuel landing to the toggle
            -- vs Luis's 0.9 s, one poll per phase change)
            if not job.queue[1] then job.phase = "start" end
            return nil, true
        end
        if t >= job.moving.until_t then
            local d = base_data(job)
            d.detail = "I tried to put the " .. tostring(q.name) .. " into the " .. tostring(job.station.name) .. " but it didn't go in."
            d.station_before, d.loaded = job.station_before, job.loaded
            return api.fail("verification_failed", d)
        end
        return nil
    end
    local rows = carried_rows(api, q.item)
    local row = rows[1]
    if not row then
        local d = base_data(job)
        d.detail = "I ran out of " .. tostring(q.name) .. " while loading the " .. tostring(job.station.name) .. "."
        return api.fail("missing_materials", d)
    end
    local to = first_slot(inv, nil, q.item)
    if not to then
        local d = base_data(job)
        d.station_before = job.station_before
        local held = {}
        for _, r in ipairs(inv.rows or {}) do held[#held + 1] = tostring(r.count) .. " " .. tostring(r.name or name_of_id(r.item)) end
        d.detail = "The " .. tostring(job.station.name) .. " has no free slot for the " .. tostring(q.name)
            .. (#held > 0 and (": it already holds " .. table.concat(held, ", ")) or "") .. "."
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
    for _, o in ipairs(job.plan.alts or {}) do want[o.item] = true end
    local list = {}
    for _, t in ipairs(api.census_things(M.cfg.collect_radius_m + 30, 60) or {}) do
        if t.category == "items" and want[t.item] and not job.pre_items[t.id] and t.position
            and dist2d(t.position, job.station.position) <= M.cfg.collect_radius_m then
            list[#list + 1] = t
        end
    end
    return list
end

local function out_items(job) -- what this recipe can drop: its outputs and its failed result (burnt food)
    local l = {}
    for _, o in ipairs(job.plan.outputs) do l[#l + 1] = o end
    for _, o in ipairs(job.plan.alts or {}) do l[#l + 1] = o end
    return l
end

local function produced_total(api, job, s)
    local n = 0
    local now = api.counts()
    for _, o in ipairs(out_items(job)) do
        n = n + math.max(0, gained(job.before, now, o.item) or 0) + ((s and s.output.by_item[o.item]) or 0)
            - ((job.st0.output.by_item[o.item]) or 0)
    end
    for _, t in ipairs(proc_collect_targets(api, job)) do n = n + (tonumber(t.count) or 1) end
    return n
end

local function out_total(job)
    local n = 0
    for _, o in ipairs(job.plan.outputs) do n = n + o.count end
    return n
end

local function proc_step(api, job, t)
    if job.phase == "load" then
        local r, again = load_step(api, job, t)
        if again and job.phase == "load" then r = load_step(api, job, t) end
        if r ~= nil or job.phase == "load" then return r end
    end
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
        job.before = api.counts() or job.before -- fresh: he may have eaten or picked up on the way
        if not s.running then
            local ok, err = W.toggle(api)
            if not ok then return api.fail("not_implemented", { detail = "The " .. tostring(job.station.name) .. "'s start button didn't respond (" .. tostring(err) .. ")." }) end
        end
        job.phase, job.until_t = "starting", t + M.cfg.start_wait_s
        return nil
    elseif job.phase == "starting" then
        if s.running or produced_total(api, job, s) > 0 then
            job.phase = "wait"
            job.started_at = t
            job.until_t = t + (job.plan.seconds or 0) * M.cfg.proc_slack + M.cfg.proc_extra_s
            return nil
        end
        if t >= job.until_t then
            local d = base_data(job)
            d.station_before, d.loaded, d.fuel_used = job.station_before, job.loaded, job.fuel
            d.detail = "I loaded the " .. tostring(job.station.name) .. " but it won't start."
            return api.fail("verification_failed", d)
        end
        return nil
    elseif job.phase == "wait" then
        local made = produced_total(api, job, s)
        if made >= out_total(job) or (not s.running and made > 0) then
            job.phase, job.collect_until = "magnet", t + M.cfg.magnet_wait_s
            return nil
        end
        if t >= job.until_t and made > 0 and not job.timed_out then
            -- out of time with some made: collect those (they lie by the station) and say the rest wasn't done, never
            -- leave them behind (live 2026-11-02 03:2xZ: "made 2 of 3" and both Leather left lying by the Tannery)
            job.timed_out = { after_s = math.floor(t - (job.started_at or t)), made = made }
            job.phase, job.collect_until = "magnet", t + M.cfg.magnet_wait_s
            return nil
        end
        if t >= job.until_t then
            local d = base_data(job)
            d.loaded, d.fuel_used, d.produced, d.station_before = job.loaded, job.fuel, made, job.station_before
            d.detail = "The " .. tostring(job.station.name) .. " stopped or took too long ("
                .. math.floor(t - (job.started_at or t)) .. " s); it made " .. made .. " of " .. out_total(job) .. "."
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
            local r = sk._episode_poll(api, job.ep, t, job.token)
            if r == nil then return nil end
            if not (sk._episode_cleanup and sk._episode_cleanup(api,job.ep,job.token)) then return nil end
            job.ep = nil
            -- the spots round the station failed: walk up to the item itself the plain way (the interact tool's own
            -- approach, with its tighter last step) once before giving up (live 2026-11-02 03:09Z: 3 Leather lay by the
            -- Tannery, "no use from where I can stand" from the side spots; interact on one took it at once)
            if not r.ok and not job.plain_tried and (r.data or {}).why ~= "gone" then job.plain_tried = true
            elseif not r.ok then job.pickup_fail = r end
            job.picks = (job.picks or 0) + 1
            return nil
        end
        local want = {}
        for _, o in ipairs(out_items(job)) do want[o.item] = true end
        if s.store_output and not job.took then
            job.took = true
            for _, r in ipairs(s.output.rows) do if want[r.item] then W.take_from(api, r.slot, s._out) end end
            job.collect_until = t + M.cfg.magnet_wait_s
            return nil
        end
        local targets = proc_collect_targets(api, job)
        local sk = api.module("skills")
        if #targets > 0 and (job.picks or 0) < out_total(job) + 3 and sk and sk._episode_poll and sk._new_episode
            and not job.pickup_fail then
            local th = targets[1]
            -- close the station's menu first, as a player does: with it open the game offers no pickup at all (live
            -- 2026-11-02 03:31Z, 447/400 so the Leather stayed on the ground: 4 spots, "no use from where I can stand",
            -- menu closed only at the end; a plain interact right after took one at once)
            if job.ui_open and not paused() then
                pcall(W.close, api, job.plan.kind); job.ui_open = false
                local IN = api.module("input")
                if IN and IN.release then pcall(IN.release, "screen") end
            end
            -- the shared episode (aim at the item itself, other sides on a miss); the output lies at the station,
            -- whose own interaction wins any near miss, so it stands where the station is not behind the item
            job.ep = sk._new_episode(api, th, { label = th.name or "output", avoid = (not job.plain_tried) and job.station.position or nil,
                -- any NEW output of this recipe the detector targets will do (never a pre-existing item)
                accept = function(det) return det.item ~= nil and want[det.item] == true and det.actor ~= nil
                                              and not job.pre_items[det.actor] end })
            job.ep.want_item, job.ep.need_gain = th.item, true
            return nil
        end
        if job.took and t < (job.collect_until or 0) then return nil end
        local now = api.counts()
        local collected, total, failed, bad = {}, 0, {}, 0
        for _, o in ipairs(job.plan.outputs) do
            local g = gained(job.before, now, o.item)
            if g and g > 0 then collected[#collected + 1] = { item = o.item, name = o.name, count = g }; total = total + g end
        end
        for _, o in ipairs(job.plan.alts or {}) do -- the recipe's failed result (burnt food): his to report, not a win
            local g = gained(job.before, now, o.item)
            if g and g > 0 then failed[#failed + 1] = { item = o.item, name = o.name, count = g }; bad = bad + g end
        end
        local d = base_data(job)
        d.loaded, d.fuel_used, d.station_before, d.collected = job.loaded, job.fuel, job.station_before, collected
        if bad > 0 then d.failed_output = failed end
        local out = job.plan.outputs[1]
        d.count = out and gained(job.before, now, out.item) or 0
        local spoilt = {}
        for _, f in ipairs(failed) do spoilt[#spoilt + 1] = f.count .. " " .. tostring(f.name) end
        spoilt = table.concat(spoilt, ", ")
        if total <= 0 and bad > 0 then
            d.detail = "The " .. tostring(job.station.name) .. " finished, but nothing came out right: I got " .. spoilt .. " and no " .. tostring(out and out.name) .. "."
                .. (job.fuel and job.fuel.source == "station" and " (I used the fuel that was already in it.)" or "")
            return api.fail("craft_failed", d)
        end
        if total <= 0 then
            local left = now ~= nil and proc_collect_targets(api, job) or {}
            if #left > 0 then -- what it made is still lying there: say so, where, and the room he has (read, not guessed)
                local n, p = 0, left[1].position
                for _, th in ipairs(left) do n = n + (tonumber(th.count) or 1) end
                local room = (W.room and W.room(api)) or {}
                d.left_behind = { item = left[1].item, name = left[1].name, count = n, ids = {},
                                  at = p and { math.floor(p[1] + 0.5), math.floor(p[2] + 0.5) } or nil }
                for _, th in ipairs(left) do d.left_behind.ids[#d.left_behind.ids + 1] = th.id end
                d.bag = room
                local facts = {}
                if room.free_slot == false then facts[#facts + 1] = "my bag has no free slot" end
                if room.over then facts[#facts + 1] = "I'm carrying too much (" .. string.format("%g", room.weight) .. " of " .. string.format("%g", room.max_weight) .. ")" end
                d.detail = "The " .. tostring(job.station.name) .. " made " .. n .. " " .. tostring(left[1].name)
                    .. ", but it didn't come to my bag and is still lying on the ground by it"
                    .. (p and (" at (" .. d.left_behind.at[1] .. ", " .. d.left_behind.at[2] .. ")") or "")
                    .. (#facts > 0 and (" (" .. table.concat(facts, " and ") .. ")") or "") .. "."
                    .. (job.pickup_fail and (" " .. tostring((job.pickup_fail.data or {}).detail or "")) or "")
                return api.fail(room.free_slot == false and "inventory_full" or "verification_failed", d)
            end
            d.detail = now == nil and ("The " .. tostring(job.station.name) .. " finished, but I couldn't read my inventory to check what I got.")
                or ("The " .. tostring(job.station.name) .. " finished, but I couldn't pick up what it made."
                    .. (job.pickup_fail and (" " .. tostring((job.pickup_fail.data or {}).detail or "")) or ""))
            return api.fail("verification_failed", d)
        end
        d.detail = "I made " .. total .. " " .. tostring(out and out.name) .. " in the " .. tostring(job.station.name)
            .. (job.fuel and job.fuel.source == "station" and " (using the fuel that was already in it)" or "") .. "."
            .. (bad > 0 and (" The rest came out wrong: " .. spoilt .. ".") or "")
        if total < out_total(job) then d.partial = true end
        if job.timed_out and total < out_total(job) then
            d.detail = d.detail .. " The " .. tostring(job.station.name) .. " was still on the rest after " .. job.timed_out.after_s
                .. " s, so I stopped waiting (" .. total .. " of " .. out_total(job) .. ")."
        elseif total < out_total(job) and bad == 0 then
            d.detail = d.detail .. " The " .. tostring(job.station.name) .. " stopped with " .. total .. " of " .. out_total(job) .. " done."
        end
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
        local sk=api.module("skills")
        if job.open and (job.open.child_gen or job.open.moving) and not (sk and sk._episode_cleanup and sk._episode_cleanup(api,job.open,job.token)) then return false end
        if job.ep and (job.ep.child_gen or job.ep.moving) and not (sk and sk._episode_cleanup and sk._episode_cleanup(api,job.ep,job.token)) then return false end
        if job.ui_open and not paused() then pcall(W.close, api, job.plan.kind); job.ui_open = false end
        local IN = api.module("input")
        if IN and IN.release then pcall(IN.release, "screen") end
        if release(api, job, why) == false then return false end
        return true
    end
    a.cancel = function()
        finish("cancelled")
    end
    a.poll = function(self)
        if paused() then self.started = api.now(); return nil end
        if job.stopped then
            if not finish("interrupted") then return nil end
            return api.fail("interrupted", { why = job.stopped, detail = "Something else took over (" .. tostring(job.stopped) .. "), so I stopped crafting." })
        end
        if not acquire(api, job) or job.own == "suspended" or api.reflex_owns_pawn() then
            self.started = api.now()
            return nil
        end
        if job.token then local A = arbiter(api); if A and A.renew then pcall(A.renew, job.token) end end
        if job.resumed then
            local sk=api.module("skills")
            if job.open and (job.open.child_gen or job.open.moving) and not (sk and sk._episode_cleanup and sk._episode_cleanup(api,job.open,job.token)) then return nil end
            if job.ep and (job.ep.child_gen or job.ep.moving) and not (sk and sk._episode_cleanup and sk._episode_cleanup(api,job.ep,job.token)) then return nil end
            job.resumed = nil
            if job.phase == "open" then job.open.phase, job.open.moving, job.open.child_lost = "approach", false, nil end
            if job.ep then job.ep.phase, job.ep.moving, job.ep.child_lost = "approach", false, nil end
        end
        local res=job.pending_result
        if not res then
            local ok
            ok, res = pcall(craft_step, api, job, api.now())
            if not ok then res = api.fail("body_error", { detail = "crafting: " .. tostring(res) }) end
            if res then job.pending_result=res end
        end
        if res and not finish(res.ok and "done" or tostring(res.reason)) then return nil end
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
        local unl, ready, burns = 0, {}, {}
        for _, rid in ipairs(all) do
            if ctx.unlocked and ctx.unlocked[rid] then
                unl = unl + 1
                local a = M.assess(rid, 1, ctx)
                if a.status == "ready" and #ready < 12 then
                    ready[#ready + 1] = a.name or rid
                    local b = burn_note(rid)
                    if b and #burns < 6 then burns[#burns + 1] = (a.name or rid) .. " from " .. b.text end
                end
            end
        end
        w.recipes, w.recipes_unlocked, w.can_make_now = #all, ctx.unlocked and unl or api.null, ready
        if #burns > 0 then w.burn_odds = burns end
        local actor = api.actor_of({ id = s.id, class = s.class })
        local st = actor and W.station_state(api, actor, s.kind)
        if st and s.kind == "processing" then
            local function names(c) local o = {}; for _, r in ipairs(c.rows) do o[#o + 1] = tostring(r.name or r.item) .. " x" .. r.count end; return o end
            w.state = { running = st.running, recipe = st.recipe, remaining_s = r1(st.remaining_s), fuel_s = r1(st.fuel_s),
                        resources = names(st.resources), fuel = names(st.fuel), output = names(st.output) }
            local theirs = foreign_inputs(api, s.id, st.resources.rows)
            if theirs then w.someone_elses = theirs .. " (not mine to use)" end
        end
        local sh = actor and W.shelter(api, actor, s.position)
        if sh then w.shelter = M.shelter_words(sh, s.name) end
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
    local mode = args.quantity_mode == nil and "additional_output" or args.quantity_mode
    if mode ~= "additional_output" and mode ~= "inventory_target" then
        return api.fail("invalid_args", {detail="quantity_mode must be additional_output or inventory_target."})
    end
    if mode == "inventory_target" and need_str(args.recipe) then
        return api.fail("invalid_args", {detail="inventory_target requires an item, not a recipe."})
    end
    local ctx, bad = context(api)
    if not ctx then return bad end
    ctx.gather_for = W.gather_for(api)
    ctx.quantity_mode = mode
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
    -- his burn chance per food power level (the game's own attribute), for the brain's food options
    local odds = refresh_burn(api)
    if odds then
        local o = {}
        for n = 1, 6 do if odds[n] then o["level" .. n] = odds[n] end end
        st.extras.burn_odds = o
    end
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
            .. "result). Safe to try straight away: when an input, the unlock or a station is missing it does nothing "
            .. "and says which. It does not gather or craft ingredients (craft_plan plans those).",
        args = { type = "object", properties = obj({
            item = str("Item to make (name or id)."),
            input = str("Or a carried item to put in the station instead of naming what comes out (e.g. raw food at a fire): the recipe that takes it."),
            recipe = str("Recipe id, to pick one of several."),
            count = { type = "integer", minimum = 1, maximum = M.cfg.max_count, description = "Items, default 1 (crafts with recipe or input; input without count: all of it)." },
            station = str("Station id (default nearest)."),
            fuel = str("Fuel to burn (processing).") }) },
        preconditions = { "the recipe is unlocked", "you carry all inputs", "a station of its type is within 60 m" },
        ground = obj({ item = "item", station = "thing" }),
        reasons = { "missing_materials", "not_unlocked", "nothing_in_range", "ambiguous_target", "unknown_recipe", "station_busy",
                    "inventory_full", "not_interactable", "path_blocked", "too_far", "verification_failed", "timeout",
                    "craft_failed", "not_implemented", "interrupted", "resting" } },
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
        description = "Plan a goal item from carried items: ordered steps (gather, craft at station, unlock, find "
            .. "station) and alternative recipes. Read only.",
        args = { type = "object", properties = obj({
            item = str("Goal item name or id."),
            recipe = str("Or a recipe id."),
            count = { type = "integer", minimum = 1, default = 1, description = "How many." },
            quantity_mode = { type = "string", enum = { "additional_output", "inventory_target" }, default = "additional_output",
                description = "additional_output: make count more; inventory_target: end up carrying count in total." } }) },
        reasons = { "unknown_recipe", "ambiguous_target", "invalid_args", "state_unavailable" } },
    stations = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "Stations near you: type, distance, unlocked recipes, what you can make now, and a furnace's "
            .. "state (running, contents, fuel, output).",
        args = { type = "object", properties = obj({
            radius = { type = "number", minimum = 5, maximum = 120, default = 60, description = "Metres." } }) },
        reasons = { "state_unavailable" } },
}

return M
