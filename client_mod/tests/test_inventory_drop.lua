-- inventory.drop across stacks (co-play 2026-11-01: "drop 40 Stone" from a 21-stack dropped nothing; an amount larger
-- than the stack HandleDropItem is given is silently ignored, live build 26161880). Actual module, fake UE bindings.
local here = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local old = loadfile
local U = {}
U.try = function(f, ...) local ok, v = pcall(f, ...); if ok then return v end end
U.valid = function(o) return o ~= nil end
U.alive = U.valid
U.find_all = function() return {} end
loadfile = function(path, ...) if path:find('/mod/body/util.lua', 1, true) then return function() return U end end return old(path, ...) end
local M = assert(old(here .. '/../scripts/inventory.lua'))(); loadfile = old

local n = 0
local function check(x, msg) assert(x, msg); n = n + 1 end

-- the plan
local function row(slot, count, st) return { slot = slot, slot_type = st or "InventoryItems", count = count, item = "ITEM_Resources_Stone" } end
local p, have = M.drop_plan({ row(1, 21), row(25, 99) }, 40)
check(#p == 1 and p[1].row.slot == 25 and p[1].amount == 40 and have == 120, "40 comes from the stack that holds it all")
p = M.drop_plan({ row(1, 21), row(25, 99) }, 10)
check(#p == 1 and p[1].row.slot == 1 and p[1].amount == 10, "the smallest stack that holds it all")
p = M.drop_plan({ row(1, 21), row(25, 99) }, 120)
check(#p == 2 and p[1].row.slot == 25 and p[1].amount == 99 and p[2].row.slot == 1 and p[2].amount == 21, "whole stacks, largest first")
p = M.drop_plan({ row(1, 21), row(25, 99), row(30, 50) }, 130)
check(#p == 2 and p[1].amount == 99 and p[2].row.slot == 30 and p[2].amount == 31, "a part of the next stack")
p = M.drop_plan({ row(0, 30, "QuickAction"), row(4, 30) }, 20)
check(#p == 1 and p[1].row.slot == 4, "bag before hotbar")
p, have = M.drop_plan({ row(1, 21) }, 40)
check(p == nil and have == 21, "not enough: no plan")

-- M.drop sends one HandleDropItem per planned stack, each amount <= its stack
local calls = {}
M.ui_api = function() return { HandleDropItem = function(_, slot, t, amount) calls[#calls + 1] = { slot, t, amount } end } end
M.list = function() return { ok = true, hotbar = {}, bag = { { name = "Stone", item = "ITEM_Resources_Stone", count = 21, slot = 1, slot_type = "InventoryItems" },
                                                             { name = "Stone", item = "ITEM_Resources_Stone", count = 99, slot = 25, slot_type = "InventoryItems" } },
                             loadout = {} } end
local r = M.drop(nil, "Stone", 40)
check(r.ok and r.amount == 40 and #calls == 1 and calls[1][1] == 25 and calls[1][2] == M.SLOT_TYPE.InventoryItems and calls[1][3] == 40,
      "drop 40 Stone -> HandleDropItem(25, InventoryItems, 40)")
calls = {}
r = M.drop(nil, "Stone", 120)
check(r.ok and r.amount == 120 and #calls == 2 and calls[1][3] == 99 and calls[2][3] == 21, "drop 120 -> 99 + 21")
calls = {}
r = M.drop(nil, "Stone", 200)
check(not r.ok and r.reason == "not_enough_resources" and r.have == 120 and #calls == 0 and r.detail:find("120 Stone", 1, true),
      "more than he has: refused with what he has, nothing sent")
calls = {}
r = M.drop(nil, "Stone")
check(r.ok and #calls == 1 and calls[1][1] == 1 and calls[1][3] == 21, "count nil = the whole stack found")
-- split: the inventory UI's split (HandleInternalSplitToSlot), from the smallest stack that keeps some
local sp, big = M.split_plan({ row(1, 21), row(25, 99) }, 40)
check(sp and sp.slot == 25 and big == 99, "split 40: the 99-stack (the 21 can't keep any)")
sp = M.split_plan({ row(1, 21), row(25, 99) }, 10)
check(sp and sp.slot == 1, "split 10: the smallest stack that keeps some")
sp, big = M.split_plan({ row(1, 21) }, 21)
check(sp == nil and big == 21, "split a whole stack: nothing to split")
sp = M.split_plan({ row(0, 30, "QuickAction"), row(4, 30) }, 10)
check(sp and sp.slot == 4, "split: bag before hotbar")
local splits = {}
M.ui_api = function() return { HandleInternalSplitToSlot = function(_, from, ft, amount, to, tt) splits[#splits + 1] = { from, ft, amount, to, tt } end } end
M.free_slot = function(page) return page == "InventoryItems" and 7 or 3 end
r = M.split(nil, "Stone", 40)
check(r.ok and #splits == 1 and splits[1][1] == 25 and splits[1][2] == M.SLOT_TYPE.InventoryItems and splits[1][3] == 40
      and splits[1][4] == 7 and splits[1][5] == M.SLOT_TYPE.InventoryItems and r.from.count == 99 and r.to.slot == 7,
      "split 40 Stone -> HandleInternalSplitToSlot(25, InventoryItems, 40, 7, InventoryItems)")
splits = {}
r = M.split(nil, "Stone", 5, "hotbar")
check(r.ok and splits[1][1] == 1 and splits[1][4] == 3 and splits[1][5] == M.SLOT_TYPE.QuickAction, "split to the hotbar: a free hotbar slot")
splits = {}
r = M.split(nil, "Stone", 200)
check(not r.ok and r.reason == "not_enough_resources" and #splits == 0 and r.detail:find("120 Stone", 1, true), "split more than he has")
r = M.split(nil, "Stone", 99)
check(not r.ok and r.reason == "invalid_args" and #splits == 0 and r.detail:find("biggest stack", 1, true), "split a whole stack: refused, says why")
r = M.split(nil, "Dragon Bones", 1)
check(not r.ok and r.reason == "not_in_inventory", "split what he lacks")
M.free_slot = function() return nil end
r = M.split(nil, "Stone", 10)
check(not r.ok and r.reason == "inventory_full" and #splits == 0, "split with no free slot")

-- the split tool (a waiter): answers once the listing shows both stacks
M.free_slot = function() return 7 end
local bag = { { name = "Stone", item = "ITEM_Resources_Stone", count = 80, slot = 2, slot_type = "InventoryItems" } }
M.list = function() return { ok = true, hotbar = {}, bag = bag, loadout = {} } end
M.ui_api = function() return { HandleInternalSplitToSlot = function() end } end
local api = { fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end }
local h = M.HANDLERS.split(nil, { item = "Stone", count = 40 }, { api = api })
check(h.wait and h.wait.poll() == nil, "split waits for the game")
bag[1].count = 40; bag[2] = { name = "Stone", item = "ITEM_Resources_Stone", count = 40, slot = 7, slot_type = "InventoryItems" }
local res = h.wait.poll()
check(res and res.ok and res.data.count == 40 and res.data.left == 40 and res.data.to.slot == 7
      and res.data.detail == "I split my 80 Stone into 40 and 40.", "split verified from both stacks")
check(h.wait.expire().reason == "verification_failed", "no change: verification_failed")
check(M.HANDLERS.split(nil, { item = "Stone", count = 0 }, { api = api }).reason == "invalid_args", "count 0 refused")
check(M.MANIFEST.split.llm == true and M.MANIFEST.split.kind == "waiter", "split is offered as a waiter")
print('inventory drop fake: ' .. n .. ' passed')
