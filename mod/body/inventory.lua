-- The bot's own inventory: a persistent, server-side store of item INSTANCES (Luis, 2026-10-25:
-- "the bot equips only what is in its inventory, like a normal player"; design
-- docs/design/robustness-and-item-catalog.md sections 7, 12, 13).
--
-- The puppet has no PlayerController, so it has no game inventory component (a null-PC inventory is
-- the R1/R8 crash class). Items enter this store only through pickup (body/items.lua), being given
-- (later), crafting (later), the one-time gear migration, or an explicit debug grant.
--
-- An instance (one stack) is a plain table, persisted as JSON:
--   { id = "i12", item = "ITEM_Resources_Wood_Oak", item_data_path = "/Game/.../ITEM_X.ITEM_X",
--     count = 37, max_stack = 99,
--     level = 0,            -- UItem.NumMasterworkUpgradesApplied (masterwork upgrade level)
--     ascension = nil,      -- UNVERIFIED: no reflected field found yet; kept for when it is
--     enchant = nil,        -- UHeldEquipmentItem.CurrentMagicalHeldEquipmentEffectInstance.Data path
--     enchantments = nil,   -- UEquipment.EnchantmentGameplayEffects class paths
--     durability = -1, max_durability = -1,   -- UItem.Durability / GetMaxDurability (-1 = none)
--     tags = nil,           -- UItem.GameplayTags names (may carry ascension state)
--     guid = "hex32",       -- UItem.Guid of the world item it came from
--     name = "Oak Logs", source = "pickup" | "seed_gear" | "debug" | "returned",
--     equipped = nil | "right" | "head" | ... }
-- Runes are items too ("ITEM_Rune_Air"), so body/spells.lua's budget policy can pay with
-- count(item_id) / take(item_id, n) (module functions, not methods).
--
-- Stacking: a new stack merges into existing unequipped stacks with the same stack key
-- (item_data_path, level, ascension, enchant) up to max_stack, then opens new stacks.
-- max_stack comes from the instance (read from UItemData.MaxStackSize at pickup), else the
-- configured resolver, else the live data asset, else 1 for instance-y items (durability or a
-- level), else M.DEFAULT_MAX_STACK.
--
-- Equipped instances (equipped = slot) stay in the store but are NOT available: count/take/summary
-- skip them, exactly like a player's loadout is not their bag.
--
-- Persistence: the "inventory" section of the ONE bot state file (DW_BOT_STATE) that body/puppet.lua
-- owns (puppet.section / puppet.set_section), so gear and inventory never race two writers. Tests
-- and experiments may pass {state_path=} instead (a standalone file of the same shape).
-- Every mutation saves before returning.
local U = require("body.util")
local jsonutil = require("jsonutil")

local M = {}

M.SECTION = "inventory"
M.VERSION = 1
M.DEFAULT_MAX_STACK = 99
M.STACK_KEY_FIELDS = { "item_data_path", "level", "ascension", "enchant" }
M.INSTANCE_FIELDS = { "level", "ascension", "enchant", "enchantments", "durability", "max_durability",
                      "tags", "guid", "name", "source" }

local S = { items = {}, next_id = 1, seeded_gear = false, log = nil, persist = nil, max_stack_fn = nil, ready = false }

local function log(name, data) U.event(S.log, name, data) end

-- ------------------------------------------------------------------ ids and paths
-- "ITEM_X" from "/Game/.../ITEM_X.ITEM_X", "ItemData /Game/...ITEM_X.ITEM_X" or "ITEM_X".
function M.item_id(x)
    if type(x) ~= "string" or x == "" then return nil end
    local p = x:match("^%S+%s+(/.*)$") or x
    return p:match("%.([%w_]+)$") or p:match("([%w_]+)$") or p
end

local function is_path(x) return type(x) == "string" and x:sub(1, 1) == "/" end

local function matches(inst, item)
    if is_path(item) then return inst.item_data_path == item end
    return inst.item == item
end

-- ------------------------------------------------------------------ persistence
local function standalone(path)
    local function load()
        local f = io.open(path, "rb")
        if not f then return nil end
        local text = f:read("a")
        f:close()
        local v = jsonutil.decode(text)
        if type(v) ~= "table" then log("inventory_state_corrupt", { path = path }); return nil end
        return v[M.SECTION]
    end
    local function save(section)
        local doc = { v = 1 }
        local f = io.open(path, "rb")
        if f then
            local v = jsonutil.decode(f:read("a"))
            f:close()
            if type(v) == "table" then doc = v end
        end
        doc[M.SECTION] = section
        local tmp = path .. ".tmp"
        local w, err = io.open(tmp, "wb")
        if not w then log("inventory_write_error", { path = tmp, err = tostring(err) }); return false end
        w:write(jsonutil.encode(doc))
        w:close()
        os.remove(path)
        return os.rename(tmp, path) and true or false
    end
    return { load = load, save = save }
end

local function via_puppet(puppet)
    return {
        load = function() return puppet.section(M.SECTION) end,
        save = function(section) return puppet.set_section(M.SECTION, section) end,
    }
end

local function snapshot()
    local items = {}
    for i, it in ipairs(S.items) do
        local c = {}
        for k, v in pairs(it) do c[k] = v end
        items[i] = c
    end
    return { v = M.VERSION, next_id = S.next_id, seeded_gear = S.seeded_gear, items = items }
end

function M.save()
    if not S.persist then return false end
    local ok, res = pcall(S.persist.save, snapshot())
    if not ok or not res then log("inventory_save_failed", { err = ok and "save returned false" or tostring(res) }) end
    return ok and res and true or false
end

local function load_section(sec)
    S.items, S.next_id, S.seeded_gear = {}, 1, false
    if type(sec) ~= "table" then return end
    S.next_id = tonumber(sec.next_id) or 1
    S.seeded_gear = sec.seeded_gear == true
    for _, it in ipairs(type(sec.items) == "table" and sec.items or {}) do
        if type(it) == "table" and type(it.item_data_path) == "string" and (tonumber(it.count) or 0) > 0 then
            it.count = math.floor(tonumber(it.count))
            it.item = it.item or M.item_id(it.item_data_path)
            it.id = it.id or ("i" .. S.next_id)
            local n = tonumber(tostring(it.id):match("^i(%d+)$"))
            if n and n >= S.next_id then S.next_id = n + 1 end
            S.items[#S.items + 1] = it
        end
    end
end

-- opts: {log, puppet = body.puppet (persist in its state file), state_path = standalone file,
--        persist = {load=fn()->section, save=fn(section)->bool}, max_stack = fn(path)->n,
--        seed_gear = {slot = path} (default: puppet.saved_gear())}
function M.init(opts)
    opts = opts or {}
    S.log = opts.log
    S.max_stack_fn = opts.max_stack
    S.persist = opts.persist or (opts.state_path and standalone(opts.state_path)) or (opts.puppet and via_puppet(opts.puppet)) or nil
    local sec = S.persist and U.try(S.persist.load) or nil
    load_section(sec)
    S.ready = true
    local gear = opts.seed_gear
    if gear == nil and opts.puppet and type(opts.puppet.saved_gear) == "function" then gear = U.try(opts.puppet.saved_gear) end
    if type(gear) == "table" and not S.seeded_gear then M.seed_from_gear(gear) end
    log("inventory_ready", { stacks = #S.items, seeded_gear = S.seeded_gear, persisted = S.persist ~= nil })
    return M
end

function M.is_ready() return S.ready end

-- ------------------------------------------------------------------ max stack
function M.max_stack(inst)
    local n = tonumber(inst.max_stack)
    if n and n >= 1 then return math.floor(n) end
    if S.max_stack_fn then
        n = tonumber(U.try(S.max_stack_fn, inst.item_data_path))
        if n and n >= 1 then return math.floor(n) end
    end
    local data = U.find_object(inst.item_data_path)
    n = data and tonumber(U.try(function() return data.MaxStackSize end))
    if n and n >= 1 then return math.floor(n) end
    if (tonumber(inst.durability) or -1) >= 0 or (tonumber(inst.level) or 0) > 0 then return 1 end
    return M.DEFAULT_MAX_STACK
end

local function stack_key(inst)
    local parts = {}
    for i, k in ipairs(M.STACK_KEY_FIELDS) do parts[i] = tostring(inst[k] == nil and "" or inst[k]) end
    return table.concat(parts, "|")
end

-- ------------------------------------------------------------------ reads
function M.list(include_equipped)
    local out = {}
    for _, it in ipairs(S.items) do
        if include_equipped or not it.equipped then out[#out + 1] = it end
    end
    return out
end

function M.get(id)
    for _, it in ipairs(S.items) do if it.id == id then return it end end
end

-- Available (unequipped) count of an item id ("ITEM_Rune_Air") or data path.
function M.count(item)
    local n = 0
    for _, it in ipairs(S.items) do
        if not it.equipped and matches(it, item) then n = n + it.count end
    end
    return n
end

-- {item_id = available count}; encodes as {} when empty (the get_state `inventory` field).
function M.summary()
    local out = jsonutil.object()
    for _, it in ipairs(S.items) do
        if not it.equipped then out[it.item] = (out[it.item] or 0) + it.count end
    end
    return out
end

-- Instance list for get_state (bounded), equipped ones included and marked.
function M.detail(max)
    local out = {}
    for _, it in ipairs(S.items) do
        if max and #out >= max then break end
        local e = { id = it.id, item = it.item, count = it.count }
        for _, k in ipairs({ "level", "ascension", "enchant", "durability", "max_durability", "equipped", "name" }) do
            if it[k] ~= nil and it[k] ~= -1 and not (k == "level" and it[k] == 0) then e[k] = it[k] end
        end
        out[#out + 1] = e
    end
    return out
end

-- Resolve a loose name ("oak", "Oak Logs", "ITEM_Resources_Wood_Oak", a path) to ONE owned item id.
-- Returns item_id or nil, reason ("unknown" | "ambiguous"), candidates.
function M.resolve(query)
    if type(query) ~= "string" or query == "" then return nil, "unknown", {} end
    local ids, order = {}, {}
    local function add(it) if not ids[it.item] then ids[it.item] = true; order[#order + 1] = it.item end end
    for _, it in ipairs(S.items) do if matches(it, query) or matches(it, M.item_id(query)) then return it.item end end
    local q = query:lower()
    for _, it in ipairs(S.items) do
        if (it.item or ""):lower():find(q, 1, true) or (it.name or ""):lower():find(q, 1, true) then add(it) end
    end
    if #order == 1 then return order[1] end
    return nil, #order == 0 and "unknown" or "ambiguous", order
end

-- An unequipped instance of exactly this data path (for equip), preferring the highest level.
function M.find_for_equip(item_path, slot)
    local best
    for _, it in ipairs(S.items) do
        if it.item_data_path == item_path and (not it.equipped or it.equipped == slot) then
            if not best or (tonumber(it.level) or 0) > (tonumber(best.level) or 0) then best = it end
        end
    end
    return best
end

-- ------------------------------------------------------------------ writes
local function new_stack(inst, count)
    local it = { id = "i" .. S.next_id, item = inst.item or M.item_id(inst.item_data_path),
                 item_data_path = inst.item_data_path, count = count, max_stack = inst.max_stack }
    S.next_id = S.next_id + 1
    for _, k in ipairs(M.INSTANCE_FIELDS) do it[k] = inst[k] end
    it.equipped = inst.equipped
    S.items[#S.items + 1] = it
    return it
end

-- Add one instance (inst.count items). Returns {added = n, ids = {stack ids touched}} or nil, reason.
-- opts.save = false defers the save (callers batching several adds must call M.save()).
function M.add(inst, opts)
    opts = opts or {}
    if type(inst) ~= "table" or type(inst.item_data_path) ~= "string" or not is_path(inst.item_data_path) then
        return nil, "invalid_args"
    end
    local n = math.floor(tonumber(inst.count) or 0)
    if n < 1 then return nil, "invalid_args" end
    inst.item = inst.item or M.item_id(inst.item_data_path)
    local cap = M.max_stack(inst)
    inst.max_stack = inst.max_stack or cap
    local key, ids, left = stack_key(inst), {}, n
    if not inst.equipped then
        for _, it in ipairs(S.items) do
            if left <= 0 then break end
            if not it.equipped and stack_key(it) == key and it.count < cap then
                local put = math.min(cap - it.count, left)
                it.count, left = it.count + put, left - put
                ids[#ids + 1] = it.id
            end
        end
    end
    while left > 0 do
        local put = inst.equipped and left or math.min(cap, left)
        ids[#ids + 1] = new_stack(inst, put).id
        left = left - put
    end
    if opts.save ~= false then M.save() end
    log("inventory_add", { item = inst.item, count = n, stacks = ids, source = inst.source })
    return { added = n, ids = ids }
end

-- Take n available items. Partial stacks go first, so full stacks stay whole for drops.
-- Returns true, {portions} (each a copy of the instance with the taken count) or false, reason.
-- No partial take: either all n are removed or nothing is.
function M.take(item, n, opts)
    opts = opts or {}
    n = math.floor(tonumber(n) or 0)
    if n < 1 then return false, "invalid_args" end
    if M.count(item) < n then return false, "not_enough_resources" end
    local cands = {}
    for i, it in ipairs(S.items) do
        if not it.equipped and matches(it, item) then cands[#cands + 1] = { i = i, it = it } end
    end
    table.sort(cands, function(a, b)
        if a.it.count ~= b.it.count then return a.it.count < b.it.count end
        return a.i < b.i
    end)
    local portions, left, empty = {}, n, {}
    for _, c in ipairs(cands) do
        if left <= 0 then break end
        local put = math.min(c.it.count, left)
        local p = {}
        for k, v in pairs(c.it) do p[k] = v end
        p.count, p.from = put, c.it.id
        portions[#portions + 1] = p
        c.it.count, left = c.it.count - put, left - put
        if c.it.count == 0 then empty[c.it] = true end
    end
    for i = #S.items, 1, -1 do if empty[S.items[i]] then table.remove(S.items, i) end end
    if opts.save ~= false then M.save() end
    log("inventory_take", { item = item, count = n, portions = #portions })
    return true, portions
end

-- Put portions returned by take() back (a failed drop). Never merges into equipped stacks.
function M.put_back(portions)
    for _, p in ipairs(portions or {}) do
        p.from = nil
        p.source = p.source or "returned"
        M.add(p, { save = false })
    end
    return M.save()
end

-- Mark an instance equipped in `slot`; whatever was equipped there goes back to the bag.
-- A stack of more than one is split: one item is equipped, the rest stays available.
function M.mark_equipped(id, slot)
    local target = M.get(id)
    if not target then return nil, "unknown" end
    for _, it in ipairs(S.items) do
        if it.equipped == slot and it ~= target then it.equipped = nil end
    end
    if target.count > 1 and not target.equipped then
        target.count = target.count - 1
        local one = {}
        for k, v in pairs(target) do one[k] = v end
        one.count, one.equipped = 1, nil
        target = new_stack(one, 1)
    end
    target.equipped = slot
    M.save()
    return target
end

function M.equipped_in(slot)
    for _, it in ipairs(S.items) do if it.equipped == slot then return it end end
end

-- One-time migration: every persisted gear item becomes an owned, equipped instance, so equip
-- (which now requires ownership) keeps working for the gear the bot already wears.
function M.seed_from_gear(gear)
    local added = {}
    for slot, path in pairs(gear or {}) do
        if type(path) == "string" and is_path(path) and not M.equipped_in(slot) then
            local r = M.add({ item_data_path = path, count = 1, max_stack = 1, source = "seed_gear", equipped = slot }, { save = false })
            if r then added[slot] = r.ids[1] end
        end
    end
    S.seeded_gear = true
    M.save()
    log("inventory_seeded_gear", { added = added })
    return added
end

-- Debug grant (bridge `inventory_grant`, never used by the brain).
function M.grant(item_data_path, count, fields)
    local inst = { item_data_path = item_data_path, count = count, source = "debug" }
    for k, v in pairs(fields or {}) do inst[k] = v end
    return M.add(inst)
end

-- Test hook.
function M._reset()
    S.items, S.next_id, S.seeded_gear, S.log, S.persist, S.max_stack_fn, S.ready = {}, 1, false, nil, nil, nil, false
end

return M
