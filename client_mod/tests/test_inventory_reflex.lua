-- Offline test for client_mod/scripts/inventory.lua: consumable classification by class (IsA, never
-- by property presence: the 18:20 UTC "ate the pickaxe" bug), the stay-fed reflex (hotbar only, one
-- pending use, outcome verify, bad-marking, no repeated presses) and use()'s fresh slot check.
-- Fake UE objects only; nothing touches the game. Usage: lua test_inventory_reflex.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_inventory_reflex.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local repo = here .. "/../.."
for _, d in ipairs({ "/mod/body", "/client_mod/scripts", "/client_io/events" }) do
    os.execute('mkdir "' .. (dir .. d):gsub("/", "\\") .. '" 2>nul')
end
local function copy(rel)
    local src = assert(io.open(repo .. rel, "rb")):read("a")
    local f = assert(io.open(dir .. rel, "wb")); f:write(src); f:close()
end
copy("/mod/body/util.lua"); copy("/client_mod/scripts/dkjson.lua")

-- ---------------------------------------------------------------- fake engine
local function trivial() -- what UE4SS returns for a property the object lacks: non-nil, invalid
    return setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return false end end
        error("trivial object")
    end })
end
local function obj(name, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return name end
    t.HasAnyInternalFlags = function() return false end
    return setmetatable(t, { __index = function() return trivial() end })
end
local function ftext(s) return { ToString = function() return s end } end
local CLASSES = {}
for _, n in ipairs({ "FoodItemData", "DrinkItemData", "PotionItemData", "EquipmentData" }) do
    CLASSES["/Script/Dominion." .. n] = obj("Class /Script/Dominion." .. n, { _name = n })
end
local function item_data(id, name, isa)
    local d = obj("ItemData /Game/Items/" .. id .. "." .. id, { Name = ftext(name) })
    d.IsA = function(_, cls) return isa[cls._name] == true end
    return d
end
local DATA = {
    pick = item_data("ITEM_Pickaxe_Mithril", "Mithril Pickaxe", { EquipmentData = true }),
    tea = item_data("ITEM_Consumable_Tea_Pumpkin", "Pumpkin Spice Infusion", { DrinkItemData = true }),
    sand = item_data("ITEM_Consumable_Sandwich_Veggie", "Forager's Sandwich", { FoodItemData = true }),
    rock = item_data("ITEM_Resources_Stone", "Stone", {}),
}
local function item(data, count) return obj("Item /Engine/Transient.Item", { ItemData = data, Count = count }) end
local function tarray(t, n)
    return { GetArrayNum = function() return n end, ForEach = function(_, fn)
        for i = 1, n do if fn(i, { get = function() return t[i] end }) then break end end
    end, _t = t, __n = n }
end
local function slots(t, n) local a = tarray(t, n); return setmetatable(a, { __index = function(_, k) return t[k] end }) end

local S = { hyd = 10, sus = 80, presses = {}, effect = {} } -- effect[data id] = {stat, amount}
local hotbar_items, bag_items = {}, {}
local function rebuild()
    local raw = {}
    for i = 1, 8 do raw[i] = hotbar_items[i] end
    for i = 1, 32 do raw[8 + i] = bag_items[i] end
    return slots(raw, 176)
end
local inv = obj("BP_Components_Inventory_C /Game/x.Inv", { NumberOfQuickActionSlots = 8 })
inv.InventoryPages = tarray({ { SlotType = 1, NumSlots = 32 }, { SlotType = 2, NumSlots = 32 }, { SlotType = 3, NumSlots = 32 },
                              { SlotType = 4, NumSlots = 72 } }, 4)
inv.GetNumEmptySlots = function() return 170 end
local lo = obj("BP_Components_Loadout_C /Game/x.Lo", { ItemSlots = slots({}, 12) })
local function comp(name, get) return obj(name, { GetCurrentHydration = get, GetCurrentSustenance = get }) end
local pawn = obj("BP_PlayerCharacter_C /Game/x.BP_PlayerCharacter_C_1", {
    HydrationComponent = comp("Hyd", function() return S.hyd end),
    SustenanceComponent = comp("Sus", function() return S.sus end),
    HealthComponent = obj("Health", { IsDead = function() return false end }),
})
local pc = obj("BP_PlayerController_C /Game/x.BP_PlayerController_C_1", { Pawn = pawn, InventoryComponent = inv,
    LoadoutComponent = lo, PersonalInventoryComponent = obj("P", { ItemSlots = slots({}, 20) }),
    IsLocalController = function() return true end })
local bar = obj("WBP_Inventory_QuickAccesBar_C /Engine/Transient.Bar", {
    UseItemInSlot = function(_, i)
        local it = hotbar_items[i + 1]
        S.presses[#S.presses + 1] = it and it.ItemData.Name:ToString() or "empty"
        local e = it and S.effect[it.ItemData:GetFullName()]
        if e then S[e[1]] = S[e[1]] + e[2] end
    end })
local api_calls = 0
local api = obj("InventoryUIAPI /Game/x.Api", { PlayerController = pc,
    HandleInternalUseItem = function() api_calls = api_calls + 1 end })
local ALL = { BP_PlayerController_C = { pc }, QuickAccessBarBase = { bar }, InventoryUIAPI = { api },
              WorldItem = {}, InteractableDetectorComponent = {}, PlayerInteractionManager = {} }
function FindAllOf(c) return ALL[c] end
function FindFirstOf(c) return (ALL[c] or {})[1] end
function StaticFindObject(p) return CLASSES[p] end
local loops = {}
function LoopInGameThreadWithDelay(_, fn) loops[#loops + 1] = fn; return #loops end
function CancelDelayedAction(h) loops[h] = function() end end

-- ---------------------------------------------------------------- load the module
local env_root = dir
local I = assert(loadfile(repo .. "/client_mod/scripts/inventory.lua", "t",
    setmetatable({ os = setmetatable({ getenv = function(k) return k == "DW_CLIENT_ROOT" and env_root or os.getenv(k) end },
                                     { __index = os }) }, { __index = _G })))()
local function refresh() inv.ItemSlots = rebuild() end
local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1; print("FAIL " .. msg) else print("ok   " .. msg) end end

-- 1. classification by class, not by property presence
check(I.consumable_kind(DATA.pick) == nil, "pickaxe is not consumable (TrivialObject StatSustenance ignored)")
check(I.consumable_kind(DATA.tea) == "drink", "tea is a drink")
check(I.consumable_kind(DATA.sand) == "food", "sandwich is food")
check(I.consumable_kind(DATA.rock) == nil, "stone is not consumable")

-- 2. the 18:20 layout: pickaxe on the hotbar BEFORE the drink; thirsty -> drinks the tea only
hotbar_items = { item(DATA.sand, 48), item(DATA.tea, 48), item(DATA.pick, 1) }
bag_items = {}
refresh()
S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
S.effect[DATA.sand:GetFullName()] = { "sus", 60 }
hotbar_items = { item(DATA.pick, 1), item(DATA.tea, 48), item(DATA.sand, 48) }; refresh()
I.reflex_start(nil, { period_ms = 2000, verify_s = 0 })
local t0 = os.time()
local R = _G.DWFedReflex
for _ = 1, 5 do R.tick_fn(nil) end
check(#S.presses == 1 and S.presses[1] == "Pumpkin Spice Infusion", "thirsty: one press, on the tea (got " .. table.concat(S.presses, ",") .. ")")
check(S.hyd == 70, "hydration rose to 70")
check(R.pending == nil and not next(R.bad), "use verified ok, nothing marked bad")

-- 3. a drink that does not raise the stat is marked bad after one press, never pressed again
S.presses, S.hyd = {}, 10
S.effect[DATA.tea:GetFullName()] = nil
R.last = {}
for _ = 1, 6 do R.tick_fn(nil); R.last.drink = nil end
check(#S.presses == 1, "no-effect drink pressed once only (got " .. #S.presses .. ")")
check(R.bad["ITEM_Consumable_Tea_Pumpkin"] == true, "no-effect drink marked bad")

-- 4. food only in the bag: no press, no InventoryUIAPI call (bag path disabled), a warning event
I.reflex_start(nil, { verify_s = 0 }) -- restart clears bad marks
S.presses, S.hyd, S.sus = {}, 80, 10
hotbar_items = { item(DATA.pick, 1) }; bag_items = { item(DATA.sand, 48) }; refresh()
R.tick_fn(nil)
check(#S.presses == 0 and api_calls == 0, "food only in bag: nothing pressed, bag use not called")
local f = io.open(dir .. "/client_io/events/vitals.jsonl", "rb"); local log = f and f:read("a") or ""; if f then f:close() end
check(log:find('"no_hotbar_food"', 1, true) ~= nil, "no_hotbar_food event logged")

-- 5. use() refuses equipment and a changed slot
hotbar_items = { item(DATA.pick, 1), item(DATA.tea, 3) }; bag_items = {}; refresh()
local r = I.use(nil, "Mithril Pickaxe")
check(r.ok == false and r.reason == "equipment, not usable", "use() refuses equipment (" .. tostring(r.reason) .. ")")
r = I.use(nil, "Pumpkin Spice Infusion", { require = "food" })
check(r.ok == false and r.reason == "not food", "use() enforces the required class")

-- 6. vitals policy (the model's call) + the safety floor; eat to heal only when the policy asks
I.reflex_start(nil, { verify_s = 0 })
S.effect[DATA.tea:GetFullName()] = { "hyd", 30 }
hotbar_items = { item(DATA.tea, 3) }; bag_items = {}; refresh()
local pr = I.set_vitals_policy(nil, { drink_below_pct = 20 })
check(pr.ok and pr.policy.drink_below_pct == 20 and pr.policy.safety_floor_pct == 10, "policy set and read back")
S.presses, S.hyd, R.last = {}, 30, {}
R.tick_fn(nil)
check(#S.presses == 0, "hydration 30% above the model's 20%: no drink")
S.hyd = 15; R.last = {}
R.tick_fn(nil)
check(#S.presses == 1, "below 20%: drinks")
check(I.set_vitals_policy(nil, { drink_below_pct = 2 }).policy.drink_below_pct == 10, "clamped to the safety floor")
S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
R.tick_fn(nil)
check(#S.presses == 1, "below the floor: drinks whatever the policy")
-- heal: food that heals is eaten only below heal_below_pct
local heal_food = item_data("ITEM_Consumable_Stew", "Stew", { FoodItemData = true })
heal_food.AmountToHealOnConsume = 20
S.hp = 40
pawn.HealthComponent = obj("Health", { IsDead = function() return false end, GetAuthoritativeHealth = function() return S.hp end,
                                       GetMaxHealth = function() return 100 end })
S.effect[heal_food:GetFullName()] = { "hp", 20 }
hotbar_items = { item(heal_food, 2) }; refresh()
S.presses, S.hyd, S.sus, R.last, R.pending = {}, 80, 80, {}, nil
I.set_vitals_policy(nil, { heal_below_pct = 0 })
R.tick_fn(nil)
check(#S.presses == 0, "heal off: hurt but fed, no eating")
I.set_vitals_policy(nil, { heal_below_pct = 50 })
R.tick_fn(nil)
check(#S.presses == 1 and S.presses[1] == "Stew", "hurt below 50%: eats healing food (got " .. table.concat(S.presses, ",") .. ")")
I.set_vitals_policy(nil, { drink_below_pct = 40, eat_below_pct = 40, heal_below_pct = 0 })

-- talk review finding 11: a modal (build mode, a chest screen, a conversation) is open -> the reflex presses nothing
do
    local g0 = I._input_gate
    hotbar_items = { item(DATA.tea, 48) }; refresh()
    S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
    S.presses, S.hyd, R.last, R.pending, R.bad = {}, 10, {}, nil, {}
    I._input_gate = function() return { kind = "conversation", mode = "DIM_ConversationUI" } end
    R.tick_fn(nil)
    check(#S.presses == 0, "modal open: thirsty, but no hotbar press (got " .. table.concat(S.presses, ",") .. ")")
    I._input_gate = function() return nil end
    R.last = {}
    R.tick_fn(nil)
    check(#S.presses == 1, "modal closed: drinks")
    I._input_gate = g0
end

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
