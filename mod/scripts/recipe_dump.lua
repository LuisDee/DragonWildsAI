-- Recipe and crafting-station catalog generator (READ-ONLY). Design: docs/design/
-- robustness-and-item-catalog.md sections 18-19; research: docs/research/
-- 2026-10-25-scalable-agent-frameworks.md section 5. Driven by tools/build_recipes.py, which
-- normalises the raw output into data/recipes_<build>.json (schema in data/README.md).
--
-- Run via debug_run {module="recipe_dump", args={...}} (the file reloads on every call). Stages
-- (each defaults to true; run them one at a time the first time, with a ping and a crash-dump
-- count after each):
--   recipes=true   every loaded URecipeData / URuneRecipeData (FindAllOf), all fields (Dominion.hpp:31900)
--   stations=true  every UCraftingStationComponent / UProcessingStationComponent: the blueprint
--                  component templates (<BP>_C:CraftingStation_GEN_VARIABLE, row handle) and the
--                  live placed ones (ValidRecipes, RecipesCache, location, ghost flag)
--   tables=true    the station rows (FCraftingStationDataTableRow.LabeledRecipes,
--                  FProcessingStationDataRow.Recipes/AcceptedFuels/ProcessingRate, ...) and every
--                  DT_Progression_* row that unlocks recipes (FProgressionBundleRow), through the
--                  UE4SS UDataTable Lua API (ForEachRow; present in the installed UE4SS.dll)
--   player=true    the first connected player's ProgressComponent.RecipesUnlocked (TSet, as the
--                  spells mirror reads SpellsUnlocked) and a pawn's InteractableDetector.InteractionRanges
--   items=true     name / max stack / durability / fuel value of every item a recipe references
--   out=<path>     raw JSON (default <DW_MOD_LOG_DIR>/../recipes_<ts>.json); build=<string>
--
-- Crash safety: property reads, TArray/TSet/TMap ForEach, UDataTable:ForEachRow and FText:ToString
-- only. No UFunction with struct args, no LoadAsset, nothing written to the game. A `recipe_dump`
-- breadcrumb is flushed before every stage and every table, so a crash dump names the step.
local U = require("body.util")
local jsonutil = require("jsonutil")

local M = {}

M.RECIPE_CLASSES = { "RecipeData" }                -- FindAllOf returns subclasses (URuneRecipeData)
M.STATION_CLASSES = { crafting = "CraftingStationComponent", processing = "ProcessingStationComponent" }
M.PROGRESSION_MATCH = "/DT_Progression_"
M.CRAFTING_TABLE = "/Game/Gameplay/World/Stations/DT_CraftingStationsDataTable.DT_CraftingStationsDataTable"
M.INTERACTION_DISTANCE = { [0] = "Short", "Medium", "Long", "Fishing" }   -- EInteractionDistance
M.STORAGE_TYPE = nil

local function crumb(log, step, data) U.event(log, "recipe_dump", { step = step, data = data }) end
local function get(o, k) return U.try(function() return o[k] end) end
local function num(v) return type(v) == "number" and v or nil end
local function bool(v) if type(v) == "boolean" then return v end end
local function str(v)
    local s = U.str(v)
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    return s
end
local function unwrap(e) local v = U.try(function() return e:get() end); if v == nil then return e end; return v end
local function asset(path) return path and (path:match("%.([^%./]+)$") or path) or nil end

local function each(arr, fn, cap)
    if arr == nil then return end
    local n, limit = 0, cap or 4096
    pcall(function()
        arr:ForEach(function(_, e)
            n = n + 1
            if n > limit then return true end
            local ok, err = pcall(fn, unwrap(e))
            if not ok then error(err) end
        end)
    end)
end

local function each_set(s, fn)
    if s == nil then return false end
    return pcall(function()
        s:ForEach(function(a, b)
            local e = b ~= nil and b or a
            fn(unwrap(e))
        end)
    end)
end

local function opath(o) return U.valid(o) and U.path_of(o) or nil end

-- TSoftObjectPtr / TSoftClassPtr -> object path (the catalog.lua softref reads).
local function softpath(sp)
    if sp == nil then return nil end
    local p = str(U.try(function() return sp:GetObjectID():GetAssetPathName() end))
    if not p then
        local loaded = U.try(function() return sp:Get() end)
        p = opath(loaded)
    end
    if p and not p:find(".", 1, true) then p = p .. "." .. p:match("([^/]+)$") end -- package path only
    return p
end

local function tagname(t) return t and str(get(t, "TagName")) or nil end

local function containers(arr)
    local out = {}
    each(arr, function(c)
        local item = opath(get(c, "ItemData"))
        if item then out[#out + 1] = { item = item, count = num(get(c, "Count")) } end
    end)
    return out
end

-- --------------------------------------------------------------------- recipes
local function describe_recipe(r)
    local rec = { path = U.path_of(r), class = U.class_word(r) }
    rec.id = asset(rec.path)
    rec.internal_name = str(get(r, "InternalName"))
    rec.persistence_id = str(get(r, "PersistenceID"))
    rec.soft_deleted = bool(get(r, "bSoftDeleted"))
    rec.consumed = containers(get(r, "ItemsConsumed"))
    rec.created = containers(get(r, "ItemsCreated"))
    rec.extra = containers(get(r, "ExtraItemsCreated"))
    rec.extra_chance = num(get(r, "ChanceToProduceExtraItems"))
    local alt = get(r, "AlternativeItemCreated")
    local alt_item = alt and opath(get(alt, "ItemData"))
    if alt_item then rec.alternative = { item = alt_item, count = num(get(alt, "Count")) } end
    rec.alternative_chance_attribute = opath(get(r, "AlternativeItemChanceAttribute"))
    rec.fuel_override = containers(get(r, "FuelConsumedOverride"))
    local reps = 0
    each(get(r, "RepairItemReplacements"), function() reps = reps + 1 end)
    rec.repair_replacements = reps
    rec.consume_individually = bool(get(r, "bConsumeItemsIndividually"))
    rec.ignore_automatic_unlocks = bool(get(r, "bIgnoreAutomaticUnlocks"))
    rec.ignore_notification = bool(get(r, "bIgnoreNotification"))
    rec.skill = opath(get(r, "SkillUsedToCraft"))
    rec.xp = num(get(r, "SkillXPAwardedOnCraft"))
    local vr = get(r, "VendorReputationRequirement")
    local vt = vr and tagname(get(vr, "ReputationTag"))
    if vt then rec.vendor_reputation = { tag = vt, amount = num(get(vr, "ReputationAmount")) } end
    rec.min_processing_time = num(get(r, "MinProcessingTime"))
    rec.max_processing_time = num(get(r, "MaxProcessingTime"))
    rec.craft_time = num(get(r, "CraftTime"))
    rec.craft_quantity_multiplier = num(get(r, "CraftQuantityMultiplier"))
    rec.max_craft_time = num(get(r, "MaxCraftTime"))
    rec.audio_tag = tagname(get(r, "AudioTag"))
    rec.rune_type = num(get(r, "RuneType"))
    return rec
end

-- --------------------------------------------------------------------- stations
local function row_handle(h)
    if h == nil then return nil end
    local row = str(get(h, "RowName"))
    local tab = opath(get(h, "DataTable"))
    if not row and not tab then return nil end
    return { table = tab, row = row }
end

local function object_list(arr)
    local out = {}
    each(arr, function(o) local p = opath(o); if p then out[#out + 1] = p end end)
    return out
end

local function labeled(arr)
    local out = {}
    each(arr, function(c)
        local recs = {}
        each(get(c, "Collection"), function(sp) local p = softpath(sp); if p then recs[#recs + 1] = p end end)
        out[#out + 1] = { label = str(get(c, "Label")), recipes = recs }
    end)
    return out
end

-- "/Game/.../BP_X.BP_X_C:CraftingStation_GEN_VARIABLE" -> "/Game/.../BP_X.BP_X_C"
local function template_owner(path)
    return path and path:match("^(.-%.[%w_]+_C):[%w_]+_GEN_VARIABLE$") or nil
end

-- Interaction component of a station: live actor .Interaction, else the blueprint's (or a parent
-- blueprint's) Interaction_GEN_VARIABLE template.
local function interaction_of(owner_actor, owner_class_path)
    local ic = owner_actor and get(owner_actor, "Interaction")
    if not U.valid(ic) and owner_class_path then
        local cls = U.find_object(owner_class_path)
        for _ = 1, 6 do
            if not cls then break end
            local cp = U.path_of(cls)
            ic = cp and U.find_object(cp .. ":Interaction_GEN_VARIABLE")
            if U.valid(ic) then break end
            cls = U.try(function() return cls:GetSuperStruct() end)
            if not U.valid(cls) then cls = nil end
        end
    end
    if not U.valid(ic) then return nil end
    local d = num(get(ic, "InteractionDistance"))
    return { distance = d, distance_name = d and M.INTERACTION_DISTANCE[d] or nil,
             type = num(get(ic, "InteractionType")), prompt = str(get(ic, "InteractionPrompt")),
             conditions = object_list(get(ic, "CanInteractConditions")) }
end

local function describe_station(comp, kind)
    local path = U.path_of(comp)
    local rec = { path = path, kind = kind }
    local owner_cls = template_owner(path)
    local owner
    if owner_cls then
        rec.template = true
    else
        owner = U.try(function() return comp:GetOwner() end)
        if not U.alive(owner) then owner = nil end
        if owner then
            rec.actor = U.short(owner)
            owner_cls = U.class_name(owner)
            owner_cls = owner_cls and (owner_cls:match("^%S+%s+(.*)$") or owner_cls)
            rec.loc = U.loc(owner)
            rec.ghosted = bool(get(owner, "bIsGhosted"))
        end
    end
    rec.owner_class = owner_cls
    rec.owner_class_name = asset(owner_cls)
    if kind == "crafting" then
        rec.row = row_handle(get(comp, "CraftingDataRowHandle"))
        rec.display_name = str(get(comp, "DisplayName"))
        rec.valid_recipes = object_list(get(comp, "ValidRecipes"))
        rec.labeled = labeled(get(comp, "CachedLabeledRecipes"))
        rec.is_vendor = bool(get(comp, "bIsVendor"))
        rec.has_repair = bool(get(comp, "bHaveRepairOption"))
        rec.has_masterwork = bool(get(comp, "bHaveMasterworkOption"))
    else
        rec.row = row_handle(get(comp, "ProcessingStationRowHandle"))
        rec.display_name = str(get(comp, "StationName"))
        rec.valid_recipes = object_list(get(comp, "RecipesCache"))
        rec.accepted_fuels = object_list(get(comp, "AcceptedFuelsIncludingRecipeOverrides"))
        rec.accepted_resources = object_list(get(comp, "AcceptedResources"))
        rec.store_output = bool(get(comp, "bStoreOutput"))
        rec.storage_type = num(get(comp, "StorageType"))
        rec.max_stored_stacks = num(get(comp, "MaxNumberOfStoredStacks"))
        rec.spawn_item_class = opath(get(comp, "SpawnItemClass"))
    end
    rec.interaction = interaction_of(owner, owner_cls)
    return rec
end

-- --------------------------------------------------------------------- data tables
local function read_table(log, path, row_fn, errors)
    local dt = U.find_object(path)
    if not dt then errors[#errors + 1] = { stage = "table", path = path, err = "not loaded" }; return nil end
    crumb(log, "table", { path = path })
    local rows, n = {}, 0
    local ok, err = pcall(function()
        dt:ForEachRow(function(name, row)
            n = n + 1
            local okr, rec = pcall(row_fn, row)
            if okr and rec then rec.row = tostring(name); rows[#rows + 1] = rec
            elseif not okr then errors[#errors + 1] = { stage = "row", path = path, row = tostring(name), err = tostring(rec) } end
        end)
    end)
    if not ok then errors[#errors + 1] = { stage = "table", path = path, err = tostring(err) } end
    return { path = path, rows = rows, seen = n, ok = ok }
end

local function crafting_row(row)
    return { display_name = str(get(row, "DisplayNameOverride")), labeled = labeled(get(row, "LabeledRecipes")),
             is_vendor = bool(get(row, "bIsVendor")), has_repair = bool(get(row, "bHaveRepairOption")),
             has_masterwork = bool(get(row, "bHaveMasterworkOption")),
             building = opath(get(row, "StationBuildingPieceData")),
             vendor_tag = tagname(get(row, "VendorTag")) }
end

local function processing_row(row)
    return { recipes = object_list(get(row, "Recipes")), accepted_fuels = object_list(get(row, "AcceptedFuels")),
             starting_fuel = opath(get(row, "StartingFuelItem")), starting_fuel_count = num(get(row, "StartingFuelCount")),
             max_resource_slots = num(get(row, "MaxResourceSlots")), max_fuel_slots = num(get(row, "MaxFuelSlots")),
             processing_rate = num(get(row, "ProcessingRate")), influence_range = num(get(row, "InfluenceRange")),
             auto_start = bool(get(row, "bAutoStartProcess")), stops_when_recipe_changes = bool(get(row, "bStopsWhenRecipeChanges")),
             can_start_through_ui = bool(get(row, "bCanProcessBeStartedThroughUI")),
             building = opath(get(row, "StationBuildingPieceData")) }
end

local function progression_row(row)
    local recipes = object_list(get(row, "UnlockedRecipes"))
    if #recipes == 0 then return nil end
    return { query = str(get(row, "UnlockQueryString")), manual = bool(get(row, "bManuallyUnlocked")),
             milestone = bool(get(row, "bMilestoneUnlock")), recipes = recipes }
end

-- --------------------------------------------------------------------- items referenced
local function describe_item(path)
    local o = U.find_object(path)
    if not o then return { loaded = false } end
    return { loaded = true, class = U.class_word(o), name = str(get(o, "Name")), max_stack = num(get(o, "MaxStackSize")),
             durability = num(get(o, "BaseDurability")), fuel_value = num(get(o, "FuelValue")),
             weight = num(get(o, "Weight")), category = tagname(get(o, "Category")) }
end

-- --------------------------------------------------------------------- player
local function player_snapshot()
    local players = U.split_pawns()
    local out = {}
    for _, p in ipairs(players) do
        local pc = U.controller_of(p)
        local prog = pc and get(pc, "ProgressComponent")
        local snap = { name = U.player_name(p), id = U.player_id(p), recipes_unlocked = {}, not_persisted = {} }
        if U.valid(prog) then
            snap.read_ok = each_set(get(prog, "RecipesUnlocked"), function(r)
                local id = asset(opath(r)); if id then snap.recipes_unlocked[#snap.recipes_unlocked + 1] = id end
            end)
            each_set(get(prog, "RecipesUnlockedThatShouldNotPersist"), function(r)
                local id = asset(opath(r)); if id then snap.not_persisted[#snap.not_persisted + 1] = id end
            end)
            table.sort(snap.recipes_unlocked)
        end
        out[#out + 1] = snap
    end
    return out
end

local function interaction_ranges()
    local players, puppets = U.split_pawns()
    local pawn = players[1] or puppets[1]
    local det = pawn and get(pawn, "InteractableDetector")
    if not U.valid(det) then return nil end
    local r = { detection_range = num(get(det, "DetectionRange")), character_trace = num(get(det, "CharacterTraceDistance")),
                ranges = jsonutil.object(), from = U.short(pawn) }
    pcall(function()
        get(det, "InteractionRanges"):ForEach(function(k, v)
            local key, val = unwrap(k), unwrap(v)
            local name = M.INTERACTION_DISTANCE[tonumber(key) or -1] or tostring(key)
            r.ranges[name] = tonumber(val)
        end)
    end)
    return r
end

local function write_json(path, value)
    local f, err = io.open(path, "wb")
    if not f then return false, tostring(err) end
    local s = jsonutil.encode(value)
    f:write(s)
    f:close()
    return true, #s
end

-- debug_run {module="recipe_dump", fn="probe", args={paths={...}}}: read-only lookup counts, to see
-- what FindAllOf / StaticFindObject return for the station classes and template paths.
function M.probe(log, args)
    args = args or {}
    local out = { find_all = {}, static = {} }
    for _, cls in ipairs(args.classes or { "CraftingStationComponent", "ProcessingStationComponent", "DataTable", "RecipeData" }) do
        local raw = U.try(FindAllOf, cls)
        out.find_all[cls] = { raw = raw and #raw or 0, alive = #U.find_all(cls) }
    end
    for _, p in ipairs(args.paths or {}) do
        local o = U.try(StaticFindObject, p)
        out.static[p] = U.valid(o) and (U.fullname(o) or "valid") or false
    end
    return out
end

function M.run(log, args)
    args = args or {}
    local t0 = os.clock()
    local errors = {}
    local doc = { schema = "dw_recipes_raw/1", build = args.build, generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                  recipes = {}, stations = {}, tables = {}, progression = {}, items = jsonutil.object(),
                  players = {}, interaction_ranges = nil, errors = errors }
    local counts = {}

    if args.recipes ~= false then
        crumb(log, "recipes", nil)
        local seen = {}
        for _, cls in ipairs(M.RECIPE_CLASSES) do
            for _, r in ipairs(U.find_all(cls, { skip_defaults = true })) do
                local p = U.path_of(r)
                if p and not seen[p] then
                    seen[p] = true
                    local ok, rec = pcall(describe_recipe, r)
                    if ok then doc.recipes[#doc.recipes + 1] = rec
                    else errors[#errors + 1] = { stage = "recipe", path = p, err = tostring(rec) } end
                end
            end
        end
        table.sort(doc.recipes, function(a, b) return a.path < b.path end)
        counts.recipes = #doc.recipes
    end

    local tables_wanted = {}
    if args.stations ~= false then
        crumb(log, "stations", nil)
        -- FindAllOf skips archetypes, so the blueprint templates come as explicit paths
        -- (station_paths, which tools/build_recipes.py takes from the build's object dump).
        local comps, seen = {}, {}
        for kind, cls in pairs(M.STATION_CLASSES) do
            for _, c in ipairs(U.find_all(cls, { skip_defaults = true })) do
                local p = U.path_of(c)
                if p and not seen[p] then seen[p] = true; comps[#comps + 1] = { c = c, kind = kind } end
            end
        end
        for _, p in ipairs(type(args.station_paths) == "table" and args.station_paths or {}) do
            local c = type(p) == "string" and not seen[p] and U.find_object(p) or nil
            if c then
                seen[p] = true
                local cw = U.class_word(c) or ""
                comps[#comps + 1] = { c = c, kind = cw:find("Processing", 1, true) and "processing" or "crafting" }
            elseif type(p) == "string" and not seen[p] then
                errors[#errors + 1] = { stage = "station_path", path = p, err = "not loaded" }
            end
        end
        for _, e in ipairs(comps) do
            local c, kind = e.c, e.kind
            do
                local ok, rec = pcall(describe_station, c, kind)
                if ok then
                    doc.stations[#doc.stations + 1] = rec
                    if rec.row and rec.row.table then tables_wanted[rec.row.table] = kind end
                else errors[#errors + 1] = { stage = "station", path = U.path_of(c), err = tostring(rec) } end
            end
        end
        table.sort(doc.stations, function(a, b) return (a.path or "") < (b.path or "") end)
        counts.stations = #doc.stations
    end

    if args.tables ~= false then
        tables_wanted[M.CRAFTING_TABLE] = tables_wanted[M.CRAFTING_TABLE] or "crafting"
        for path, kind in pairs(tables_wanted) do
            local t = read_table(log, path, kind == "processing" and processing_row or crafting_row, errors)
            if t then t.kind = kind; doc.tables[#doc.tables + 1] = t end
        end
        crumb(log, "progression", nil)
        for _, dt in ipairs(U.find_all("DataTable", { skip_defaults = true })) do
            local p = U.path_of(dt)
            if p and p:find(M.PROGRESSION_MATCH, 1, true) then
                local t = read_table(log, p, progression_row, errors)
                if t and #t.rows > 0 then doc.progression[#doc.progression + 1] = t end
            end
        end
        counts.tables, counts.progression_tables = #doc.tables, #doc.progression
    end

    if args.player ~= false then
        crumb(log, "player", nil)
        doc.players = player_snapshot()
        doc.interaction_ranges = interaction_ranges()
        counts.players = #doc.players
    end

    if args.items ~= false then
        crumb(log, "items", nil)
        local n = 0
        local function want(p) if p and doc.items[p] == nil then doc.items[p] = describe_item(p); n = n + 1 end end
        for _, r in ipairs(doc.recipes) do
            for _, k in ipairs({ "consumed", "created", "extra", "fuel_override" }) do
                for _, c in ipairs(r[k] or {}) do want(c.item) end
            end
            if r.alternative then want(r.alternative.item) end
        end
        for _, s in ipairs(doc.stations) do for _, f in ipairs(s.accepted_fuels or {}) do want(f) end end
        for _, t in ipairs(doc.tables) do
            for _, row in ipairs(t.rows) do for _, f in ipairs(row.accepted_fuels or {}) do want(f) end end
        end
        counts.items = n
    end

    counts.errors = #errors
    local out = args.out or ((os.getenv("DW_MOD_LOG_DIR") or ".") .. "/../recipes_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".json")
    crumb(log, "write_json", { out = out })
    local wok, wres = write_json(out, doc)
    local ms = math.floor((os.clock() - t0) * 1000)
    local errs = {}
    for i = 1, math.min(#errors, 10) do errs[i] = errors[i] end
    U.event(log, "recipe_dump_done", { out = out, counts = counts, cpu_ms = ms, write_ok = wok })
    return { ok = wok, out = out, bytes = wok and wres or nil, write_error = (not wok) and wres or nil,
             counts = counts, cpu_ms = ms, errors = errs,
             sample = doc.recipes[1] and { doc.recipes[1].id, doc.recipes[1].consumed, doc.recipes[1].created } or nil }
end

return M
