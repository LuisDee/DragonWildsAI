-- inventory.list's room: the free slots on the pages a pickup lands in (hotbar + item page), never the game's
-- GetNumEmptySlots, which counts the rune, ammo and quest pages too (164 live with a full item page; gather's
-- inventory_full test never saw 0). The REAL inventory module with fake UE bindings. Usage: lua test_inventory_room.lua
local here = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
local old = loadfile
local U = {}
U.try = function(f, ...) local ok, v = pcall(f, ...); if ok then return v end end
U.valid = function(o) return o ~= nil end
U.alive = U.valid
U.str = function(v) return v ~= nil and tostring(v) or nil end
U.class_word = function() return 'Item' end
U.path_of = function(o) return o.path end
U.find_object = function() return nil end
U.find_all = function() return {} end
U.short = function() return nil end
loadfile = function(path, ...) if path:find('/mod/body/util.lua', 1, true) then return function() return U end end return old(path, ...) end
local M = assert(old(here .. '/../scripts/inventory.lua'))(); loadfile = old

local n, bad = 0, 0
local function check(x, msg, detail)
    n = n + 1
    if not x then bad = bad + 1; print('FAIL ' .. msg .. (detail ~= nil and (': ' .. tostring(detail)) or '')) end
end

local function data(id, name, max) return { path = '/Game/Items/' .. id .. '.' .. id, Name = name, MaxStackSize = max } end
local ASH, STONE, NET, AIR = data('ITEM_Resources_Wood_Ash', 'Ash Logs', 99), data('ITEM_Resources_Stone', 'Stone', 99),
    data('ITEM_FishingNet_CoarseNet', 'Coarse Net', 1), data('ITEM_Rune_Air', 'Air Rune', 9999)
local function item(d, count) return { ItemData = d, Count = count, Durability = -1, GetMaxDurability = function() return -1 end } end

-- the live layout (DISCOVERIES "Inventory layout"): hotbar 8, then Items 32, Runes 32, Ammo 32, Quest 72 = 176 raw slots
local PAGES = { { SlotType = 1, NumSlots = 32 }, { SlotType = 2, NumSlots = 32 }, { SlotType = 3, NumSlots = 32 }, { SlotType = 4, NumSlots = 72 } }
local function fake_pc(slots, empty)
    local arr = setmetatable({ GetArrayNum = function() return 176 end }, { __index = function(_, i) return slots[i - 1] end })
    local inv = {
        NumberOfQuickActionSlots = 8,
        ItemSlots = arr,
        InventoryPages = { ForEach = function(_, fn) for i, p in ipairs(PAGES) do fn(i, { get = function() return p end }) end end },
        GetNumEmptySlots = function() return empty end,
        ComputeCurrentWeight = function() return 0 end,
    }
    return { InventoryComponent = inv }
end
M.pawn = function() return nil end

-- 1. item page full (32 rows), hotbar full (8), a rune stack on the rune page: the game says 163 empty, room is 0
local slots = {}
for raw = 0, 7 do slots[raw] = item(raw < 4 and NET or STONE, raw < 4 and 1 or 99) end
for raw = 8, 39 do slots[raw] = item(ASH, 99) end
slots[40] = item(AIR, 900)
local pc = fake_pc(slots, 163)
M.pc = function() return pc end
local l = M.list()
check(l.ok and l.empty_slots == 163, 'empty_slots stays the game count (every page)', l.empty_slots)
check(type(l.room) == 'table' and l.room.total == 0 and l.room.items == 0 and l.room.hotbar == 0, 'a full item page + hotbar is room 0',
      l.room and l.room.total)
check(l.room and l.room.items_slots == 32 and l.room.hotbar_slots == 8, 'room carries the page sizes', l.room and l.room.items_slots)
check(#l.bag == 33 and l.bag[33].slot_type == 'InventoryRunes', 'the rune stack is listed on its own page', #l.bag)

-- 2. three free item slots and one free hotbar slot; a rune and a quest item elsewhere change nothing
slots[3], slots[20], slots[21], slots[22] = nil, nil, nil, nil
slots[110] = item(data('ITEM_Quest_Thing', 'Quest Thing', 1), 1)
l = M.list()
check(l.room and l.room.items == 3 and l.room.hotbar == 1 and l.room.total == 4, 'room counts the free item and hotbar slots only',
      l.room and (l.room.items .. '/' .. l.room.hotbar))
-- get_state.bag reads the same rows: used = item-page bag rows, capacity = the item page; capacity - used == room.items
local used = 0
for _, d in ipairs(l.bag) do if (d.slot_type or 'InventoryItems') == 'InventoryItems' then used = used + 1 end end
check(32 - used == l.room.items, 'get_state.bag capacity - used equals room.items', used)
check(l.hotbar[1].max_stack == 1 and l.bag[1].max_stack == 99, 'rows carry MaxStackSize (gather stack room)', l.bag[1].max_stack)

-- 3. pages unread: no room, never a guessed 0
check(M.room_of({}, {}, {}) == nil, 'no pages read: room nil')
check(M.room_of({ { type_name = 'QuickAction', n = 8 } }, {}, {}) == nil, 'item page unread: room nil')
local r = M.room_of({ { type_name = 'QuickAction', n = 8 }, { type_name = 'InventoryItems', n = 32 } }, { {}, {} }, { { slot_type = 'InventoryItems' }, { slot_type = 'InventoryAmmunition' } })
check(r and r.items == 31 and r.hotbar == 6 and r.total == 37, 'room_of: item page and hotbar only', r and r.total)

print(string.format('inventory room: %d passed, %d failed', n - bad, bad))
if bad > 0 then os.exit(1) end
