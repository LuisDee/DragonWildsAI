-- Real-craft capture + catalog drift check: record ONE real craft by a player (which server RPCs his
-- client sends, with params, and the exact inventory/station deltas), and compare it with the recipe
-- catalog's plan (body/crafting.lua M.plan over body/recipe_data.lua). There is no emulated craft any
-- more (real-player remediation, 2026-10-25): the capture tells the real-client route which game path
-- to drive, and the comparison keeps the catalog honest. READ-ONLY: it never writes to the player,
-- his inventory or the station. Driven by tools/craft_drift.py.
--
--   debug_run {module="craft_drift", args={action="arm", seconds=240, radius_m=12}}
--       starts a 250 ms watcher (one per run; re-arming replaces it) over:
--         * the first connected player's inventories (PC.InventoryComponent and
--           PersonalInventoryComponent: ItemSlots -> {item: count}),
--         * every station actor of a catalogued type within radius_m of him (refreshed every 5 s):
--           its inventories (ResourcesInventory, FuelInventory, CatalystInventory, the processing
--           component's OutputInventory) and processing state (CurrentRecipe, bStationRunning,
--           RemainingProcessingTime, RemainingFuelTime),
--         * world items within 4 m of those stations (processing outputs spawn as world items),
--       and hooks (once per run) InventoryController:Server_CraftRecipe and :Server_ToggleProcessing
--       (pre + post), snapshotting his inventory inside the hook.
--       Every change is appended to args.out (tools/craft_drift.py: logs/drift/craft_drift_<ts>.jsonl).
--   {action="status"}  what was captured so far (+ the file path)
--   {action="stop"}    cancel the watcher
--   {action="plan", recipe=..., count=n, station=sid}  the emulation's plan from a FRESH copy of
--       body/crafting.lua + body/recipe_data.lua (loadfile, so redeployed code is what is checked)
-- UE4SS notes: RegisterHook pre callbacks fire before native RPC bodies (speech pre-hook, DISCOVERIES);
-- LoopInGameThreadWithDelay is stopped only by CancelDelayedAction (DISCOVERIES "Spells").
local U = require("body.util")
local jsonutil = require("jsonutil")

local M = {}

M.PERIOD_MS = 250
M.REFRESH_MS = 5000
M.WORLD_ITEM_CM = 400
-- The player's server RPCs a craft can go through (UInventoryController, Dominion.hpp:24740), so a
-- capture shows which real path a player's craft takes (the real-client route will call the same).
-- Params are logged generically: objects by short name, numbers as numbers, TArrays as their type.
local IC = "/Script/Dominion.InventoryController:"
M.HOOKS = {
    craft = IC .. "Server_CraftRecipe",                        -- (CraftingStation, Recipe, Count, BonusCount, XPMul, BonusXPMul, Inventories)
    toggle = IC .. "Server_ToggleProcessing",                  -- (ProcessingStation)
    move = IC .. "Server_MoveItemBetweenInventories",          -- (SrcInv, SrcSlot, DstInv, DstSlot): loading a furnace / taking outputs
    move_all = IC .. "Server_MoveAllItemsBetweenInventories",  -- (SrcInv, DstInv)
    fill = IC .. "Server_FillStacksBetweenInventories",        -- (SrcInv, DstInv)
    split_put = IC .. "Server_SplitAndPutStack",               -- (SrcInv, SrcSlot, Amount, DstInv, DstSlot)
    repair = IC .. "Server_RepairItem",                        -- (CraftingStation, Item, Recipe, Inventories)
    masterwork = IC .. "Server_UpgradeMasterworkEquipment",    -- (CraftingStation, Inventory, SlotIndex, Inventories)
    interact = "/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction",  -- opening the station
}

-- One hook param, readable and scalar-only (never a userdata in the log record).
local function describe(v)
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then return v end
    if v == nil then return nil end
    local full = U.fullname(v)
    if full then
        local owner = U.try(function() return v:GetOwner() end)
        local o = U.valid(owner) and U.short(owner) or nil
        return o and (U.short(v) .. "@" .. o) or (full:match("([%w_%-]+)$") or full)
    end
    local n = U.try(function() return v:GetArrayNum() end)
    if n then return "TArray[" .. tostring(n) .. "]" end
    return type(v)
end
M.STATION_INV_PROPS = { "ResourcesInventory", "FuelInventory", "CatalystInventory" }

local G = rawget(_G, "__dw_craft_drift")
if not G then
    G = { hooks = {}, loop = nil, file = nil, t0 = nil, last = {}, events = 0, crafts = {}, stations = {},
          refreshed = 0, until_ms = 0, player = nil }
    rawset(_G, "__dw_craft_drift", G)
end

local function now_ms() return math.floor(os.clock() * 1000) end
local function asset(p) return p and (p:match("%.([^%./]+)$") or p) or nil end

local function fresh(modname)
    local path = package.searchpath(modname, package.path)
    if not path then return nil, modname .. " not on package.path" end
    local ok, mod = pcall(function() return assert(loadfile(path))() end)
    if not ok then return nil, tostring(mod) end
    return mod
end

local function emit(rec)
    G.events = G.events + 1
    rec.t = now_ms() - (G.t0 or now_ms())
    rec.wall = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if G.file then
        local f = io.open(G.file, "ab")
        if f then f:write(jsonutil.encode(rec), "\n"); f:close() end
    end
end

-- {item_id = count} of one UInventoryComponent (read-only)
local function inv_counts(inv, out)
    out = out or {}
    if not U.valid(inv) then return out end
    pcall(function()
        inv.ItemSlots:ForEach(function(_, e)
            local it = U.try(function() return e:get() end)
            if U.valid(it) then
                local id = asset(U.path_of(U.try(function() return it.ItemData end)))
                local n = tonumber(U.try(function() return it.Count end)) or 0
                if id and n > 0 then out[id] = (out[id] or 0) + n end
            end
        end)
    end)
    return out
end

local function player_counts(pawn)
    local pc = U.controller_of(pawn)
    if not pc then return nil end
    local out = {}
    inv_counts(U.try(function() return pc.InventoryComponent end), out)
    inv_counts(U.try(function() return pc.PersonalInventoryComponent end), out)
    return out
end

local function same(a, b)
    if a == nil or b == nil then return a == b end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function station_classes()
    local D = fresh("body.recipe_data") or {}
    local out = {}
    for sid, st in pairs(D.stations or {}) do
        for _, cls in ipairs(st.classes or {}) do out[cls] = sid end
    end
    return out
end

local function refresh_stations(pawn, radius_cm)
    local at = U.loc(pawn)
    local list = {}
    for cls, sid in pairs(G.classes or {}) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            if U.class_word(a) == cls then
                local d = U.dist(at, U.loc(a))
                if d <= radius_cm then list[#list + 1] = { actor = a, id = U.short(a), station = sid, class = cls, dist = d } end
            end
        end
    end
    table.sort(list, function(x, y) return x.dist < y.dist end)
    for i = #list, 4, -1 do list[i] = nil end
    G.stations = list
end

local function station_state(s)
    local a = s.actor
    if not U.alive(a) then return { gone = true } end
    local st = { inv = {} }
    for _, prop in ipairs(M.STATION_INV_PROPS) do
        local inv = U.try(function() return a[prop] end)
        if U.valid(inv) then st.inv[prop] = inv_counts(inv) end
    end
    local comp = U.try(function() return a.ProcessingStation end)
    if U.valid(comp) then
        local outinv = U.try(function() return comp.OutputInventory end)
        if U.valid(outinv) then st.inv.OutputInventory = inv_counts(outinv) end
        st.recipe = asset(U.path_of(U.try(function() return comp.CurrentRecipe end)))
        st.running = U.try(function() return comp.bStationRunning end) == true
        st.processing = U.try(function() return comp.bProcessTimerRunning end) == true
        st.remaining_processing = tonumber(U.try(function() return comp.RemainingProcessingTime end))
        st.remaining_fuel = tonumber(U.try(function() return comp.RemainingFuelTime end))
    end
    -- world items around the station (processing outputs are launched as world items)
    local here = U.loc(a)
    local wi = {}
    for _, w in ipairs(U.find_all("RuntimeSpawnedWorldItem")) do
        if U.dist(here, U.loc(w)) <= M.WORLD_ITEM_CM then
            local id = asset(U.path_of(U.try(function() return w.ItemData end)))
            local n = tonumber(U.try(function() return w:GetStackSize() end)) or 1
            if id then wi[id] = (wi[id] or 0) + n end
        end
    end
    st.inv.world_items = wi
    return st
end

-- Canonical text of a plain table (sorted keys), for change detection.
local function canon(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. canon(v[k] ~= nil and v[k] or v[tonumber(k)]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function state_key(st)
    -- remaining_* tick down constantly: keep them out of the change detection
    local c = {}
    for k, v in pairs(st) do if k ~= "remaining_processing" and k ~= "remaining_fuel" then c[k] = v end end
    return canon(c)
end

local function step()
    local t = now_ms()
    if t > G.until_ms then
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        G.loop = nil
        emit({ kind = "stopped", why = "time" })
        return
    end
    local pawn = U.find_player(G.player or "luis")
    if not pawn then return end
    if t - G.refreshed >= M.REFRESH_MS then
        G.refreshed = t
        refresh_stations(pawn, G.radius_cm)
    end
    local inv = player_counts(pawn)
    if inv and not same(inv, G.last.player) then
        G.last.player = inv
        emit({ kind = "player", counts = inv })
    end
    for _, s in ipairs(G.stations) do
        local st = station_state(s)
        local key = state_key(st)
        if key ~= G.last[s.id] then
            G.last[s.id] = key
            emit({ kind = "station", id = s.id, station = s.station, class = s.class, state = st })
        end
    end
end

local function param(p)
    local v = U.try(function() return p:get() end)
    return v
end

local function arm_hooks(log)
    if type(RegisterHook) ~= "function" then return { err = "RegisterHook unavailable" } end
    local out = {}
    for tag, path in pairs(M.HOOKS) do
        if not G.hooks[tag] then
            local function cb(phase)
                return function(ctx, a1, a2, a3, a4, a5, a6, a7)
                    local ok, err = pcall(function()
                        local pawn = U.find_player(G.player or "luis")
                        local rec = { kind = "hook", hook = tag, fn = path:match(":(.*)$"), phase = phase,
                                      counts = pawn and player_counts(pawn) or nil, params = {} }
                        for i, p in ipairs({ a1, a2, a3, a4, a5, a6, a7 }) do rec.params[i] = describe(param(p)) end
                        rec.caller = describe(U.try(function() return ctx:get() end))
                        if tag == "craft" then
                            local station = param(a1)
                            rec.recipe = asset(U.path_of(param(a2)))
                            rec.count = tonumber(param(a3))
                            rec.bonus = tonumber(param(a4))
                            local owner = U.valid(station) and U.try(function() return station:GetOwner() end)
                            rec.station_actor = owner and U.short(owner) or nil
                            rec.station_class = owner and U.class_word(owner) or nil
                            if phase == "pre" then G.crafts[#G.crafts + 1] = { recipe = rec.recipe, count = rec.count } end
                        elseif tag == "toggle" then
                            local station = param(a1)
                            local owner = U.valid(station) and U.try(function() return station:GetOwner() end)
                            rec.station_actor = owner and U.short(owner) or nil
                            rec.recipe = U.valid(station) and asset(U.path_of(U.try(function() return station.CurrentRecipe end))) or nil
                        end
                        emit(rec)
                    end)
                    if not ok then U.event(log, "craft_drift_hook_error", { hook = tag, err = tostring(err) }) end
                end
            end
            local ok, err = U.call(log, "craft_drift.RegisterHook", { fn = path }, function()
                RegisterHook(path, cb("pre"), cb("post"))
            end)
            G.hooks[tag] = ok or nil
            out[tag] = ok and "armed" or tostring(err)
        else
            out[tag] = "already"
        end
    end
    return out
end

function M.run(log, args)
    args = args or {}
    local action = args.action or "status"
    if action == "arm" then
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        -- tools/craft_drift.py passes out=<repo>/logs/drift/...jsonl (it creates the folder)
        G.file = args.out or ((os.getenv("DW_MOD_LOG_DIR") or ".") .. "/craft_drift_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl")
        G.t0, G.last, G.events, G.crafts, G.stations, G.refreshed = now_ms(), {}, 0, {}, {}, 0
        G.player = args.player
        G.radius_cm = (tonumber(args.radius_m) or 12) * 100
        G.until_ms = G.t0 + (tonumber(args.seconds) or 240) * 1000
        G.classes = station_classes()
        local hooks = arm_hooks(log)
        emit({ kind = "armed", hooks = hooks, radius_m = G.radius_cm / 100, player = args.player or "luis" })
        step()
        G.loop = LoopInGameThreadWithDelay(M.PERIOD_MS, function()
            local ok, err = pcall(step)
            if not ok then U.event(log, "craft_drift_step_error", { err = tostring(err) }) end
        end)
        local st = {}
        for _, s in ipairs(G.stations) do st[#st + 1] = { id = s.id, station = s.station, distance = U.cm_to_m(s.dist) } end
        return { ok = true, file = G.file, hooks = hooks, stations = st, player_seen = G.last.player ~= nil }
    elseif action == "stop" then
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        G.loop = nil
        emit({ kind = "stopped", why = "stop" })
        return { ok = true, file = G.file, events = G.events }
    elseif action == "check" then
        -- READ-ONLY live self-test of a fresh body/crafting.lua: the full craft check (Luis's live
        -- unlock mirror, the bot's real inventory store, the station census) without consuming anything.
        local crafting, err = fresh("body.crafting")
        if not crafting then return { ok = false, err = err } end
        local D = fresh("body.recipe_data")
        local inv = require("body.inventory")
        crafting.configure({ data = D, inventory = inv.is_ready() and inv or nil, log = log })
        crafting.configure({ mirror = crafting.live_mirror() })
        local m = crafting.live_mirror()()
        local _, puppets = U.split_pawns()
        local p = puppets[1] or U.split_pawns()[1]
        local here = p and U.loc(p)
        if not here then return { ok = false, err = "no puppet or player position" } end
        local ok, a, b = crafting.check({ recipe = args.recipe, item = args.item, count = args.count or 1 }, here)
        local near = {}
        local ids = {}
        for sid in pairs(D.stations) do ids[#ids + 1] = sid end
        for _, s in ipairs(crafting.find_stations(ids, here, { radius_cm = (tonumber(args.radius_m) or 60) * 100 })) do
            near[#near + 1] = { station = s.station, id = s.id, distance = U.cm_to_m(s.dist2d) }
        end
        return { ok = true, from = U.short(p), mirror = m and { source = m.source, name = m.name, count = m.count } or nil,
                 result = ok and { ok = true, recipe = a.recipe, seconds = a.seconds } or { ok = false, reason = a, data = b },
                 stations_near = near }
    elseif action == "plan" then
        local crafting, err = fresh("body.crafting")
        if not crafting then return { ok = false, err = err } end
        local D, err2 = fresh("body.recipe_data")
        if not D then return { ok = false, err = err2 } end
        crafting.configure({ data = D })
        local rid = crafting.recipe(args.recipe or "")
        if not rid then return { ok = false, err = "unknown recipe " .. tostring(args.recipe) } end
        local p = crafting.plan(rid, tonumber(args.count) or 1, args.station)
        return { ok = true, plan = p }
    end
    local st = {}
    for _, s in ipairs(G.stations or {}) do st[#st + 1] = { id = s.id, station = s.station, distance = U.cm_to_m(s.dist) } end
    return { ok = true, file = G.file, running = G.loop ~= nil, events = G.events, crafts = G.crafts, stations = st,
             hooks = G.hooks }
end

return M
