-- Fake of client_mod/scripts/inventory.lua (same API and list shape: hotbar, bag, loadout, held).
-- drop() is confirmed "by the server" one list() later (async like the real one) unless FAKE.drop_never.
local M = {}
_G.FAKE = _G.FAKE or {}
local F = _G.FAKE
F.inv = F.inv or { oak_bag = 5, oak_bar = 3 }
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
M.HANDLERS = { inv_debug = function(log, args, ctx) return { ok = true, data = { echo = args.x } } end }
return M
