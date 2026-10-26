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
copy("/client_mod/scripts/input.lua") -- the REAL modal gate (L32 integration)

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

-- 3. a drink that never raises the stat is marked bad after bad_after (3) failed uses, never pressed again
S.presses, S.hyd = {}, 10
S.effect[DATA.tea:GetFullName()] = nil
R.last = {}
for _ = 1, 10 do R.tick_fn(nil); R.last.drink = nil end
check(#S.presses == 3, "no-effect drink pressed bad_after=3 times only (got " .. #S.presses .. ")")
check(R.bad["ITEM_Consumable_Tea_Pumpkin"] == true, "no-effect drink marked bad")

-- 3b. BUGS L32: ONE failed use (pressed while busy) never gives up a good drink: the next try drinks
I.reflex_start(nil, { verify_s = 0 })
R = _G.DWFedReflex
S.presses, S.hyd, R.last = {}, 10, {}
S.effect[DATA.tea:GetFullName()] = nil -- the first press does nothing (busy)
R.tick_fn(nil) -- press 1 (no effect)
S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
R.last.drink = nil
R.tick_fn(nil) -- verify press 1 (failed: a strike) and press 2 (works)
R.tick_fn(nil) -- verify press 2 (ok)
check(#S.presses == 2 and S.hyd >= 60, "L32: retried after one miss and drank (presses " .. #S.presses .. ", hyd " .. S.hyd .. ")")
check(not R.bad["ITEM_Consumable_Tea_Pumpkin"] and not (R.strikes or {})["ITEM_Consumable_Tea_Pumpkin"], "L32: not marked bad; strikes cleared by the success")

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

-- L32 integration: the REAL input.lua gate over the fake PC: gameplay -> drinks; a conversation input mode -> nothing
do
    hotbar_items = { item(DATA.tea, 48) }; refresh()
    S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
    I.reflex_start(nil, { verify_s = 0 })
    R = _G.DWFedReflex
    _G.DWInput = nil
    pc.CurrentInputMode = obj("DataAsset /Game/Input/DIM_ConversationUI.DIM_ConversationUI")
    S.presses, S.hyd, R.last = {}, 10, {}
    R.tick_fn(nil)
    check(#S.presses == 0, "real gate: a conversation is open -> no hotbar press")
    pc.CurrentInputMode = obj("DataAsset /Game/Input/DIM_Gameplay.DIM_Gameplay")
    R.last = {}
    R.tick_fn(nil)
    check(#S.presses == 1, "real gate: gameplay -> drinks (got " .. #S.presses .. ")")
end

-- live 2026-10-26 15:06: nothing to drink or eat CARRIED -> the reflex was silent while he dehydrated.
-- Now: a no_drink / no_food event (once a minute), reason names whether none is carried or all failed.
local function events(action)
    local fh = io.open(dir .. "/client_io/events/vitals.jsonl", "rb"); local txt = fh and fh:read("a") or ""; if fh then fh:close() end
    local n = 0
    for line in txt:gmatch("[^\n]+") do if line:find('"action":"' .. action .. '"', 1, true) then n = n + 1 end end
    return n, txt
end
do
    I.reflex_start(nil, { verify_s = 0 })
    R = _G.DWFedReflex
    local g0 = I._input_gate
    I._input_gate = function() return nil end
    hotbar_items = { item(DATA.pick, 1) }; bag_items = {}; refresh()
    S.presses, S.hyd, S.sus, R.last, R.pending, R.warned = {}, 5, 80, {}, nil, nil
    local n0 = events("no_drink")
    R.tick_fn(nil); R.tick_fn(nil)
    local n1, txt = events("no_drink")
    check(n1 == n0 + 1, "nothing carried: ONE no_drink event over two ticks (got " .. (n1 - n0) .. ")")
    check(txt:find("no drink carried, hotbar or bag", 1, true) ~= nil, "no_drink reason: none carried")
    check(#S.presses == 0, "nothing carried: nothing pressed")
    -- food carried, but marked bad -> no_food, reason "failed"
    hotbar_items = { item(DATA.sand, 3) }; refresh()
    S.hyd, S.sus, R.warned = 80, 5, nil
    R.bad = { ITEM_Consumable_Sandwich_Veggie = true }
    local f0 = events("no_food")
    R.tick_fn(nil)
    local f1, txt2 = events("no_food")
    check(f1 == f0 + 1 and txt2:find("every food I carry failed to work", 1, true) ~= nil, "all food bad: no_food, reason 'failed'")
    -- a drink only in the bag is NOT no_drink (that is no_hotbar_drink)
    R.bad, R.warned = {}, nil
    hotbar_items = {}; bag_items = { item(DATA.tea, 3) }; refresh()
    S.hyd, S.sus = 5, 80
    local d0 = events("no_drink")
    R.tick_fn(nil)
    check(events("no_drink") == d0, "drink in the bag: no no_drink event")
    I._input_gate = g0
end

-- live 2026-10-26 14:59: a build screen blocks the drink near 0. At the safety floor, with a usable drink on
-- the hotbar, the reflex leaves a build/container screen itself (one step per tick, bounded), then drinks.
do
    I.reflex_start(nil, { verify_s = 0 })
    R = _G.DWFedReflex
    local g0, l0 = I._input_gate, I._input_leave
    local modal = { kind = "build", mode = "Placement" }
    local leaves = 0
    I._input_gate = function() return modal end
    I._input_leave = function(m) leaves = leaves + 1; if leaves >= 2 then modal = nil end; return m.kind == "build" end
    hotbar_items = { item(DATA.tea, 48) }; bag_items = {}; refresh()
    S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
    -- above the floor (thirsty by policy, 20 < 40%) -> blocked, no leave
    S.presses, S.hyd, S.sus, R.last, R.pending = {}, 20, 80, {}, nil
    R.tick_fn(nil)
    check(leaves == 0 and #S.presses == 0, "thirsty above the floor: build screen left alone, nothing pressed")
    S.hyd = 5
    R.tick_fn(nil)
    check(leaves == 1 and #S.presses == 0, "below the floor: one leave step, no hotbar press while still blocked")
    check(events("floor_leave") >= 1, "floor_leave event logged")
    R.tick_fn(nil) -- second step closes it
    R.tick_fn(nil) -- gate clear -> drinks
    check(leaves == 2 and #S.presses == 1 and S.presses[1] == "Pumpkin Spice Infusion", "screen gone: drinks (leaves " .. leaves .. ", presses " .. #S.presses .. ")")
    check(R.floor_leaves == nil, "leave count reset once unblocked")
    -- bounded: a screen that never closes gets at most floor_leaves steps
    modal, leaves = { kind = "build", mode = "Placement" }, -100
    S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
    for _ = 1, 12 do R.tick_fn(nil) end
    check(leaves == -100 + 6, "never-closing screen: at most 6 leave steps (got " .. (leaves + 100) .. ")")
    -- no usable drink -> no point leaving: no step
    modal, leaves = { kind = "build", mode = "Placement" }, 0
    R.floor_leaves = nil
    hotbar_items = {}; refresh()
    for _ = 1, 3 do R.tick_fn(nil) end
    check(leaves == 0, "nothing usable: the screen is not left")
    -- a conversation / input mode is never left by the reflex
    modal = { kind = "conversation", mode = "DIM_ConversationUI" }
    hotbar_items = { item(DATA.tea, 48) }; refresh()
    for _ = 1, 3 do R.tick_fn(nil) end
    check(leaves == 0, "conversation at the floor: not touched by the reflex")
    I._input_gate, I._input_leave = g0, l0
end

-- the same over the REAL input.lua: an OWNED Placement build mode (the build job's claim survives), at the
-- floor -> the reflex injects the build's own CancelAction; never a hotbar press while it is open
do
    I.reflex_start(nil, { verify_s = 0 })
    R = _G.DWFedReflex
    _G.DWInput = nil
    pc.CurrentInputMode = obj("DataAsset /Game/Input/DIM_Gameplay.DIM_Gameplay")
    local injected = {}
    local cancel = obj("InputAction /Game/Input/IA_Build_Cancel.IA_Build_Cancel")
    local bm = obj("BuildModeComponent /Game/x.BM", { CurrentBuildMode = 2, CancelAction = cancel })
    pc.BuildModeComponent = bm
    ALL.EnhancedInputLocalPlayerSubsystem = { obj("EnhancedInputLocalPlayerSubsystem /Engine/Transient.EIS", {
        InjectInputVectorForAction = function(_, a) injected[#injected + 1] = a:GetFullName(); if a == cancel then bm.CurrentBuildMode = 0 end end }) }
    local IN = assert(loadfile(dir .. "/client_mod/scripts/input.lua"))()
    IN.claim("build", "build:campfire") -- a live (or leaked) owner: the orphan sweep would not touch it
    hotbar_items = { item(DATA.tea, 48) }; bag_items = {}; refresh()
    S.effect[DATA.tea:GetFullName()] = { "hyd", 60 }
    S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
    R.tick_fn(nil)
    check(#injected == 1 and injected[1]:find("IA_Build_Cancel", 1, true) and #S.presses == 0,
          "real input: owned Placement at the floor -> the build's Cancel injected, no hotbar press (" .. table.concat(injected, ",") .. ")")
    R.tick_fn(nil)
    check(#S.presses == 1, "real input: build mode None -> drinks (presses " .. #S.presses .. ")")
    pc.BuildModeComponent = nil
    ALL.EnhancedInputLocalPlayerSubsystem = nil
end

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
