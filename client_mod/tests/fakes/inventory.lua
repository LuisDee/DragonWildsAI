-- Fake of client_mod/scripts/inventory.lua (same API and list shape: hotbar, bag, loadout, held).
-- drop() is confirmed "by the server" one list() later (async like the real one) unless FAKE.drop_never.
-- interact_target(pawn) = the nearest world item / gatherable / interactable within 3 m (the game's
-- detector trace); press_interact takes it out of FAKE.world into the bag (graves: their contents).
local M = {}
_G.FAKE = _G.FAKE or {}
local F = _G.FAKE
F.inv = F.inv or { oak_bag = 5, oak_bar = 3 }
F.extra = F.extra or {} -- item id -> count, things picked up by interact
function M.list(log)
    if F.pending_drop then
        F.inv.oak_bag = math.max(0, F.inv.oak_bag - F.pending_drop)
        F.pending_drop = nil
    end
    local hotbar, bag = {}, {}
    if F.inv.oak_bar > 0 then
        hotbar[1] = { name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = F.inv.oak_bar, slot_type = "QuickAction", slot = 0 }
    end
    if F.inv.oak_bag > 0 then
        bag[1] = { name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = F.inv.oak_bag, slot_type = "InventoryItems", slot = 2 }
    end
    local slot = 3
    for item, n in pairs(F.extra) do
        bag[#bag + 1] = { name = item, item = item, count = n, slot_type = "InventoryItems", slot = slot }
        slot = slot + 1
    end
    if F.has_food then bag[#bag + 1] = { name = "Sandwich", item = "ITEM_Sandwich", count = 1, consumable = "food", slot = 20 } end
    if F.has_drink then bag[#bag + 1] = { name = "Water", item = "ITEM_Water", count = 1, consumable = "drink", slot = 21 } end
    return { ok = true, hotbar = hotbar, bag = bag,
             loadout = { { name = "Bronze Hatchet", item = "ITEM_Tool_Axe_Bronze", count = 1, slot = 7, loadout_slot = "HeldRight" } },
             personal = {}, held = { right = "Bronze Hatchet", right_item = "ITEM_Tool_Axe_Bronze" } }
end
function M.drop(log, what, count)
    if not tostring(what):lower():find("oak") then return { ok = false, reason = "not in inventory: " .. tostring(what) } end
    F.dropped = { what, count }
    if not F.drop_never then F.pending_drop = count end
    return { ok = true, item = { name = "Oak Logs", item = "ITEM_Resources_Wood_Oak", count = F.inv.oak_bag, slot = 2 },
             amount = count }
end
function M.describe_item(it) return { name = it.name, item = it.item, count = it.count } end

local function near()
    local p = (F.move and F.move.position) or F.me_pos or { 1, 2, 3 }
    local best, bd, bcat, bi
    for _, cat in ipairs({ "items", "resources", "interactables" }) do
        for i, r in ipairs(F.world[cat] or {}) do
            local d = math.sqrt((r.position[1] - p[1]) ^ 2 + (r.position[2] - p[2]) ^ 2)
            if d <= 3 and (cat ~= "resources" or r.kind == "gatherable") and (not bd or d < bd) then best, bd, bcat, bi = r, d, cat, i end
        end
    end
    return best, bcat, bi
end
function M.interact_target(pawn)
    if F.detector_override then return F.detector_override end
    local r = near()
    if not r then return { none = true } end
    return { actor = r.id, class = r.class, prompt = r.prompt or "Pick up", item = r.item, name = r.name }
end
function M.press_interact(log)
    F.presses = (F.presses or 0) + 1
    if F.press_noop then return { ok = true, action = "IA_Interact" } end
    local o = F.detector_override
    if o and o.item then -- the detector's (converted) target is what the press takes
        F.extra[o.item] = (F.extra[o.item] or 0) + 1
        return { ok = true, action = "IA_Interact" }
    end
    local r, cat, i = near()
    if r and r.chest then F.open_chest = r.id; return { ok = true, action = "IA_Interact" } end
    if r and (cat == "items" or r.kind == "gatherable" or r.contents) then

        table.remove(F.world[cat], i)
        local gain = r.contents or { { item = r.item, count = r.count or 1 } }
        for _, g in ipairs(gain) do F.extra[g.item] = (F.extra[g.item] or 0) + (g.count or 1) end
    end
    return { ok = true, action = "IA_Interact" }
end
-- Containers (chests): FAKE.chests = {[id] = {slots = n, rows = {{slot, item, name, count}}}}; a press on a world
-- row with chest = true opens it (FAKE.open_chest = id, as the game opens its screen). Transfers move counts
-- between the carried fake inventory (oak_bar / oak_bag / extra) and the chest, unless FAKE.transfer_noop.
local function chest_rows(inv)
    local out = { slots = inv.slots or 0, rows = {}, by_item = {} }
    for _, r in ipairs(inv.rows or {}) do
        if (r.count or 0) > 0 then
            out.rows[#out.rows + 1] = { slot = r.slot, item = r.item, name = r.name, count = r.count }
            out.by_item[r.item] = (out.by_item[r.item] or 0) + r.count
        end
    end
    return out
end
function M.world_inventory()
    local c = F.open_chest and F.chests and F.chests[F.open_chest]
    if c then return { inv = c, owner = F.open_chest } end
end
function M.inventory_of(actor) return actor and F.chests and F.chests[actor.id] or nil end
function M.close_world_inventory() F.closed = (F.closed or 0) + 1; F.open_chest = nil; return true end
function M.external_rows(inv) return chest_rows(inv) end
function M.free_slot(type_name) return 9 end
local function take_carried(row, n)
    if row.item == "ITEM_Resources_Wood_Oak" then
        local k = row.slot_type == "QuickAction" and "oak_bar" or "oak_bag"
        F.inv[k] = F.inv[k] - n
    else
        F.extra[row.item] = (F.extra[row.item] or 0) - n
        if F.extra[row.item] <= 0 then F.extra[row.item] = nil end
    end
end
function M.to_external(log, row, amount, to_slot, inv)
    F.transfers = (F.transfers or 0) + 1
    if F.transfer_noop then return { ok = true } end
    take_carried(row, amount)
    for _, r in ipairs(inv.rows) do
        if r.slot == to_slot then r.count = r.count + amount; return { ok = true } end
    end
    inv.rows[#inv.rows + 1] = { slot = to_slot, item = row.item, name = row.name, count = amount }
    return { ok = true }
end
function M.from_external(log, from_slot, inv, amount, to_slot, to_page)
    F.transfers = (F.transfers or 0) + 1
    if F.transfer_noop then return { ok = true } end
    for _, r in ipairs(inv.rows) do
        if r.slot == from_slot then
            r.count = r.count - amount
            if r.item == "ITEM_Resources_Wood_Oak" then F.inv.oak_bag = F.inv.oak_bag + amount
            else F.extra[r.item] = (F.extra[r.item] or 0) + amount end
            return { ok = true }
        end
    end
    return { ok = false, reason = "no such slot" }
end

function M.reflex_start(log) F.reflex_starts = (F.reflex_starts or 0) + 1; F.reflex_on = true; return { ok = true } end
function M.reflex_status() return { running = F.reflex_on == true } end
function M.vitals_policy() return F.policy or { drink_below_pct = 40, eat_below_pct = 40, reserve_warn = 2 } end
M.HANDLERS = { inv_debug = function(log, args, ctx) return { ok = true, data = { echo = args.x } } end }
return M
