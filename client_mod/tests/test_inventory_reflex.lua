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
copy("/mod/body/util.lua"); copy("/client_mod/scripts/dkjson.lua"); copy("/client_mod/scripts/arbiter.lua")
copy("/client_mod/scripts/input.lua") -- the REAL modal gate (L32 integration)
copy("/client_mod/scripts/consumable_wiki.lua") -- the REAL soulscourge data (Dirty Water 20)
os.execute('mkdir "' .. (dir .. "/data"):gsub("/", "\\") .. '" 2>nul')
copy("/data/consumable_risks.json") -- the REAL risk data (L38 fixed by fxguard: Dirty Water no longer listed)

-- ---------------------------------------------------------------- fake engine
local function trivial() -- what UE4SS returns for a property the object lacks: non-nil, invalid
    return setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return false end end
        error("trivial object")
    end })
end
local next_address=0
local function obj(name, t)
    t = t or {}
    next_address=next_address+1
    local address=next_address
    t.IsValid = function() return true end
    t.GetAddress = function() return address end
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
    dirty = item_data("ITEM_Consumable_Water_Dirty", "Dirty Water", { DrinkItemData = true }),
    clean = item_data("ITEM_Consumable_Water_Clean", "Clean Water", { DrinkItemData = true }),
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
I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
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
I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
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
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
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
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, S.sus, R.last, R.pending, R.warned = {}, 5, 80, {}, nil, nil
    local n0 = events("inventory_read_unknown")
    R.tick_fn(nil); R.tick_fn(nil)
    local n1, txt = events("inventory_read_unknown")
    check(n1 == n0 + 1, "unverified slots: ONE unknown event over two ticks (got " .. (n1 - n0) .. ")")
    check(txt:find("inventory could not be read completely", 1, true) ~= nil, "unknown reason: incomplete read")
    check(#S.presses == 0, "nothing carried: nothing pressed")
    -- food carried, but marked bad -> no_food, reason "failed"
    hotbar_items = { item(DATA.sand, 3) }; refresh()
    S.hyd, S.sus, R.warned = 80, 5, nil
    R.bad = { ITEM_Consumable_Sandwich_Veggie = true }
    local f0 = events("inventory_read_unknown")
    R.tick_fn(nil)
    local f1, txt2 = events("inventory_read_unknown")
    check(f1 == f0 + 1 and txt2:find("inventory could not be read completely", 1, true) ~= nil, "bad known food with incomplete slots remains unknown")
    -- a drink only in the bag is NOT no_drink (that is no_hotbar_drink)
    R.bad, R.warned = {}, nil
    hotbar_items = {}; bag_items = { item(DATA.tea, 3) }; refresh()
    S.hyd, S.sus = 5, 80
    local d0 = events("no_drink")
    R.tick_fn(nil)
    check(events("no_drink") == d0, "drink in the bag: no no_drink event")
    local old_pages=inv.InventoryPages.ForEach
    inv.InventoryPages.ForEach=function() error("page unavailable") end
    hotbar_items={item(DATA.tea,3)}; bag_items={}; refresh()
    S.presses,S.hyd,R.last,R.pending,R.warned={},5,{},nil,nil
    R.tick_fn(nil)
    check(#S.presses==1 and S.presses[1]=="Pumpkin Spice Infusion","page failure: verified hotbar drink still used")
    I.reflex_start(nil,{verify_s=0}); R=_G.DWFedReflex
    hotbar_items={}; bag_items={item(DATA.tea,3)}; refresh()
    S.presses,S.hyd,R.last,R.pending,R.warned={},5,{},nil,nil
    local loc0=events("inventory_location_unknown")
    R.tick_fn(nil)
    check(events("inventory_location_unknown")==loc0+1 and #S.presses==0,"page failure: observed unmapped drink is not claimed absent or pressed")
    inv.InventoryPages.ForEach=old_pages
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
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
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
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
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
    -- a stray HUD screen (a Campfire's Processing + Inventory, BUGS B-stuck-focused-ui) IS left at the floor
    modal, leaves = { kind = "screen", mode = "DIM_FocussedInGameUI", screens = { "Processing", "Inventory" } }, 0
    R.floor_leaves = nil
    I._input_leave = function(m) leaves = leaves + 1; modal = nil; return m.kind == "screen" end
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
    R.tick_fn(nil); R.tick_fn(nil)
    check(leaves == 1 and #S.presses == 1, "stray screen at the floor: left once, then drinks (leaves " .. leaves .. ", presses " .. #S.presses .. ")")
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
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
    R.tick_fn(nil)
    for _ = 1, 8 do R.tick_fn(nil) end
    check(#injected == 0 and #S.presses == 0 and (R.floor_leaves or 0) == 0,
        "real input: orphan claim defers without consuming leave budget")
    IN.release("build")
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
    A.reset(nil)
    IN.claim("build", "build:cooperative")
    local suspended = false
    local owner = A.request(nil, { name = "build:cooperative", level = "command", uses_move = false,
        on_suspend = function() suspended = true; IN.release("build") end })
    R.tick_fn(nil)
    check(owner.ok and suspended and #injected == 1 and bm.CurrentBuildMode == 0,
        "real input: safety floor preempts owner and cooperatively leaves released modal")
    A.reset(nil)
    IN.release("build"); bm.CurrentBuildMode = 0
    R.tick_fn(nil)
    check(#S.presses == 1, "real input: after owner releases and mode closes, drinks (presses " .. #S.presses .. ")")
    pc.BuildModeComponent = nil
    ALL.EnhancedInputLocalPlayerSubsystem = nil
end

-- Dirty Water (+20 Soulscourge, wiki data): only below the safety floor; Clean Water always first (main 2026-10-26)
do
    I.reflex_start(nil, { verify_s = 0 })
    R = _G.DWFedReflex
    local g0 = I._input_gate
    I._input_gate = function() return nil end
    _G.DWInput = nil
    pc.CurrentInputMode = obj("DataAsset /Game/Input/DIM_Gameplay.DIM_Gameplay")
    check(I.soulscourge_of("Dirty Water") == 20 and I.soulscourge_of("Clean Water") == 0, "soulscourge from data: Dirty Water 20, Clean Water 0")
    S.effect[DATA.dirty:GetFullName()] = { "hyd", 10 }
    S.effect[DATA.clean:GetFullName()] = { "hyd", 25 }
    hotbar_items = { item(DATA.dirty, 5) }; bag_items = {}; refresh()
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, S.sus, R.last, R.pending, R.warned = {}, 30, 80, {}, nil, nil
    local h0 = events("held_back_drink")
    R.tick_fn(nil)
    check(#S.presses == 0, "dirty only, thirsty above the floor: not drunk (" .. table.concat(S.presses, ",") .. ")")
    check(events("held_back_drink") == h0 + 1, "dirty only: held_back_drink told (purify / find clean)")
    S.hyd, R.last, R.warned = 5, {}, nil
    R.tick_fn(nil)
    check(#S.presses == 1 and S.presses[1] == "Dirty Water",
          "dirty only, below the floor: drunk (L38 crash fixed by fxguard; Dirty Water beats death) (" .. table.concat(S.presses, ",") .. ")")
    check(I.risk_of("ITEM_Consumable_Water_Dirty") == nil and I.risk_of("ITEM_Consumable_Water_Clean") == nil,
          "real risk data: Dirty Water no longer a crash risk (BUGS L38 fixed)")
    -- both carried (dirty in the first slot): Clean Water first, above or below the floor
    hotbar_items = { item(DATA.dirty, 5), item(DATA.clean, 2) }; refresh()
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, R.last, R.pending = {}, 30, {}, nil
    R.tick_fn(nil)
    check(#S.presses == 1 and S.presses[1] == "Clean Water", "both: Clean Water first above the floor (" .. table.concat(S.presses, ",") .. ")")
    I.reflex_start(nil, { verify_s = 0 }) -- release any previous in-flight owner before resetting fixture
    S.presses, S.hyd, R.last, R.pending = {}, 5, {}, nil
    R.tick_fn(nil)
    check(#S.presses == 1 and S.presses[1] == "Clean Water", "both: Clean Water first below the floor (" .. table.concat(S.presses, ",") .. ")")
    I._input_gate = g0
end

-- crash-safety MECHANISM (kept for any future reproduced crash item; BUGS L38): with a risk row whose risk is a
-- crash, use() and equip() refuse that item with the truthful sentence, and press nothing. A synthetic fixture
-- (the real data no longer lists anything since fxguard fixed L38), loaded into a second module instance.
do
    local dir2 = dir .. "/risk_fixture"
    for _, d in ipairs({ "/mod/body", "/client_mod/scripts", "/client_io/events", "/data" }) do
        os.execute('mkdir "' .. (dir2 .. d):gsub("/", "\\") .. '" 2>nul')
    end
    for _, rel in ipairs({ "/mod/body/util.lua", "/client_mod/scripts/dkjson.lua", "/client_mod/scripts/input.lua",
                           "/client_mod/scripts/consumable_wiki.lua" }) do
        local src = assert(io.open(repo .. rel, "rb")):read("a")
        local f = assert(io.open(dir2 .. rel, "wb")); f:write(src); f:close()
    end
    local f = assert(io.open(dir2 .. "/data/consumable_risks.json", "wb"))
    f:write('{"items": {"ITEM_Consumable_Water_Dirty": {"risk": "client_crash", "detail": "test fixture", "instead": "boil it at a campfire into Clean Water"}}}')
    f:close()
    local saved = env_root
    env_root = dir2
    local I2 = assert(loadfile(repo .. "/client_mod/scripts/inventory.lua", "t",
        setmetatable({ os = setmetatable({ getenv = function(k) return k == "DW_CLIENT_ROOT" and env_root or os.getenv(k) end },
                                         { __index = os }) }, { __index = _G })))()
    env_root = saved
    hotbar_items = { item(DATA.dirty, 3), item(DATA.clean, 1) }; bag_items = {}; refresh()
    S.presses = {}
    local rr = I2.crash_refusal("ITEM_Consumable_Water_Dirty", "Dirty Water", "drink")
    check(rr and rr.reason == "unsafe" and rr.detail == "I won't drink Dirty Water: it crashes my game. Boil it at a campfire into Clean Water first.",
          "crash_refusal (fixture row): the exact truthful sentence (" .. tostring(rr and rr.detail) .. ")")
    local r1 = I2.use(nil, "Dirty Water", { require = "drink" })
    check(r1.ok == false and r1.reason == "unsafe" and #S.presses == 0, "use(fixture crash item): refused, nothing pressed")
    local r2 = I2.equip(nil, "Dirty Water")
    check(r2.ok == false and r2.reason == "unsafe" and #S.presses == 0, "equip(fixture crash item): refused (its key would drink it), nothing pressed")
    check(I2.crash_refusal("ITEM_Consumable_Water_Clean", "Clean Water", "drink") == nil, "an unlisted item: no refusal")
    check(I.crash_refusal("ITEM_Consumable_Water_Dirty", "Dirty Water", "drink") == nil, "real data: Dirty Water is not refused any more")
end

-- find(): a partial name never substitutes another item; a kind preference picks the consumable among substring hits
do
    local l = { hotbar = { { name = "Water Rune", item = "ITEM_Rune_Water" }, { name = "Clean Water", item = "ITEM_Consumable_Water_Clean", consumable = "drink" } },
                bag = {}, loadout = {} }
    check(I.find(l, "water").item == "ITEM_Rune_Water", "find(water): first substring hit without a preference")
    check(I.find(l, "water", "drink").item == "ITEM_Consumable_Water_Clean", "find(water, drink): the drink wins over the rune")
    check(I.find(l, "clean water").item == "ITEM_Consumable_Water_Clean", "find: case-insensitive exact name")
    l.hotbar[2] = nil
    check(I.find(l, "Clean Water") == nil, "find(Clean Water) with only the Water Rune: no match")
end

-- Real inventory transaction: no raw use, one live owner, interrupted use cannot be replayed.
do
    I.reflex_stop()
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
    A.reset(nil)
    S.presses = {}; hotbar_items = { item(DATA.tea, 4) }; refresh()
    local raw = I.use(nil, "Pumpkin Spice Infusion", { require = "drink", hotbar_only = true })
    check(not raw.ok and #S.presses == 0, "transaction: raw consumable use fails closed")
    local real_time, fake_time = os.time, os.time()
    os.time = function() return fake_time end
    local grant = A.request(nil, { name = "test", level = "command", uses_move = false })
    local tx = I.consume_begin(grant.token, "test", 4, "ITEM_Consumable_Tea_Pumpkin")
    local duplicate = I.consume_begin(grant.token, "second", 4, "ITEM_Consumable_Tea_Pumpkin")
    check(tx and not duplicate, "transaction: same owner cannot overlap another use")
    local ok = I.use(nil, "Pumpkin Spice Infusion", { require = "drink", hotbar_only = true, owner_token = grant.token, transaction = tx })
    check(ok.ok and #S.presses == 1, "transaction: current owner may press")
    local repeat_use = I.use(nil, "Pumpkin Spice Infusion", { require = "drink", hotbar_only = true, owner_token = grant.token, transaction = tx })
    check(not repeat_use.ok and #S.presses == 1, "transaction: one input per transaction")
    fake_time = fake_time + 6
    check(I.consume_owned(tx, grant.token) and not I.consume_begin(grant.token, "waiter", 4, "ITEM_Consumable_Tea_Pumpkin"),
        "transaction: active waiter does not expire")
    local I2 = assert(loadfile(repo .. "/client_mod/scripts/inventory.lua", "t",
        setmetatable({ os = setmetatable({ getenv = function(k) return k == "DW_CLIENT_ROOT" and env_root or os.getenv(k) end },
                                         { __index = os }) }, { __index = _G })))()
    check(not I2.consume_begin(grant.token, "reload", 4, "ITEM_Consumable_Tea_Pumpkin"), "transaction: reload shares active gate")
    fake_time = fake_time - 6
    _G.DW_PAUSE = true
    check(not I.consume_owned(tx, grant.token), "transaction: pause invalidates waiter")
    _G.DW_PAUSE = nil
    check(not I.consume_owned(tx, grant.token), "transaction: pause cannot resume old waiter")
    I.consume_finish(tx, grant.token, true)
    check(not I.consume_owned(tx, grant.token) and not I.consume_begin(grant.token, "later", 4, "ITEM_Consumable_Tea_Pumpkin"), "transaction: interrupted press invalidates waiter and retains gate")
    fake_time = fake_time + 6
    local next_tx = I.consume_begin(grant.token, "later", 4, "ITEM_Consumable_Tea_Pumpkin")
    check(next_tx ~= nil and next_tx ~= tx, "transaction: original bounded window permits a later use")
    hotbar_items = { item(DATA.tea, 4), item(DATA.clean, 4) }; refresh()
    local wrong = I.use(nil, "Clean Water", { require = "drink", owner_token = grant.token, transaction = next_tx })
    check(not wrong.ok and #S.presses == 1, "transaction: intended item enforced")
    I.consume_finish(next_tx, grant.token, false)
    A.release(nil, grant.token, "test"); os.time = real_time
end

-- A real reflex tick must defer while a command owns the pawn, without charging its cooldown.
do
    I.reflex_stop()
    local A = assert(loadfile(dir .. "/client_mod/scripts/arbiter.lua"))()
    A.reset(nil)
    hotbar_items = { item(DATA.tea, 4) }; bag_items = {}; refresh()
    S.presses, S.hyd, S.sus = {}, 30, 80
    S.effect[DATA.tea:GetFullName()] = { "hyd", 20 }
    I.reflex_start(nil, { verify_s = 0 })
    R.last = {}
    local grant = A.request(nil, { name = "command:test", level = "command", uses_move = false })
    R.tick_fn(nil)
    check(#S.presses == 0 and R.last.drink == nil, "real reflex defers to command without cooldown")
    A.release(nil, grant.token, "test")
    R.tick_fn(nil)
    check(#S.presses == 1, "real reflex presses after command releases")
    I.reflex_stop(); A.reset(nil)
    S.hyd, S.presses = 30, {}
    S.effect[DATA.tea:GetFullName()] = nil
    I.reflex_start(nil, { verify_s = 0 }); R.last = {}; R.tick_fn(nil)
    S.hyd = nil
    R.tick_fn(nil)
    check(not (R.strikes or {})["ITEM_Consumable_Tea_Pumpkin"], "unknown post-read does not strike drink")
    I.reflex_stop(); A.reset(nil); S.hyd = 80
end

-- The real bridge and skills action share the real inventory transaction with the real reflex.
do
    I.reflex_stop()
    local previous = _G.DWConsumableTransaction.active
    if previous and previous.interrupted then previous.until_t = 0 end
    local H = dofile(repo .. "/mod/tests/bridge_harness.lua")
    local json = require("dkjson")
    local scriptdir, bridgedir = dir .. "/integrated_scripts", dir .. "/integrated_bridge"
    os.execute('mkdir "' .. scriptdir:gsub("/", "\\") .. '" 2>nul')
    os.execute('mkdir "' .. bridgedir:gsub("/", "\\") .. '" 2>nul')
    local function cp(src, dst)
        local f = assert(io.open(src, "rb")); local text = f:read("a"); f:close()
        f = assert(io.open(dst, "wb")); f:write(text); f:close()
    end
    for _, n in ipairs({ "skills", "manifest", "arbiter", "quests" }) do cp(repo .. "/client_mod/scripts/" .. n .. ".lua", scriptdir .. "/" .. n .. ".lua") end
    for _, n in ipairs({ "chat", "move", "sense" }) do cp(here .. "/fakes/" .. n .. ".lua", scriptdir .. "/" .. n .. ".lua") end
    _G.FAKE = { move = { mode = "idle", calls = {} }, auto_arrive = true }
    local B = assert(loadfile(repo .. "/client_mod/scripts/client_bridge.lua"))()
    local t = 500
    B.clock = function() return t end
    B.start({ root = repo, dir = bridgedir, scripts = scriptdir, chat_events = dir .. "/chat.jsonl",
        vitals_events = dir .. "/vitals.jsonl", move_events = dir .. "/move.jsonl", gather_events = dir .. "/gather.jsonl", jlog = H.log, no_loop = true })
    local original_module = B.module
    B.module = function(name) if name == "inventory" then return I end; return original_module(name) end
    local sense = B.module("sense")
    sense.me = function() return { ok = true, position = { 0, 0, 0 }, survival = { hydration = { S.hyd, 100 }, sustenance = { S.sus, 100 } }, health = 100 } end
    local A = B.module("arbiter"); A.reset(nil)
    local move = B.module("move"); A.set_move(move)
    pc.CurrentInputMode = obj("DataAsset /Game/Input/DIM_Gameplay.DIM_Gameplay")
    hotbar_items = { item(DATA.tea, 4) }; bag_items = {}; refresh()
    S.hyd, S.sus, S.presses = 30, 80, {}
    S.effect[DATA.tea:GetFullName()] = nil
    I.reflex_start(nil, { verify_s = 5 }); R.last = {}
    local f = assert(io.open(bridgedir .. "/brain_to_client.jsonl", "ab"))
    f:write(json.encode({ v = 1, type = "cmd", id = "real-overlap", tool = "consume", args = { item = "drink" } }) .. "\n"); f:close()
    B.step(); t = t + 0.5; B.step()
    check(#S.presses == 1 and B._state().action ~= nil, "real bridge and skills command press once while held")
    R.tick_fn(nil)
    check(#S.presses == 1 and R.last.drink == nil, "real skills command and reflex cannot overlap")
    f = assert(io.open(bridgedir .. "/brain_to_client.jsonl", "ab"))
    f:write(json.encode({ v = 1, type = "cmd", id = "real-stop", tool = "stop", args = {} }) .. "\n"); f:close()
    t = t + 0.5; B.step()
    local stopped = B._state().action == nil
    local held = A.request(nil, { name = "after-cancel", level = "command", uses_move = false })
    local denied = I.consume_begin(held and held.token, "after-cancel", 5, "ITEM_Consumable_Tea_Pumpkin")
    check(stopped and not denied and #S.presses == 1, "real bridge stop cancels command and retains interrupted gate")
    if held and held.ok then A.release(nil, held.token, "test") end
    if _G.DWConsumableTransaction.active then _G.DWConsumableTransaction.active.until_t = 0 end
    S.hyd, R.last = 30, {}
    f = assert(io.open(bridgedir .. "/brain_to_client.jsonl", "ab"))
    f:write(json.encode({ v = 1, type = "cmd", id = "real-preempt", tool = "consume", args = { item = "drink" } }) .. "\n"); f:close()
    t = t + 0.5; B.step(); t = t + 0.5; B.step()
    local pressed_before = #S.presses
    S.hyd = 5; R.tick_fn(nil)
    t = t + 0.5; B.step()
    f = assert(io.open(bridgedir .. "/client_to_brain.jsonl", "rb")); local replies = f:read("a"); f:close()
    local interrupted = false
    for line in replies:gmatch("[^\n]+") do
        local result = json.decode(line)
        if result and result.id == "real-preempt" and result.type == "result" and result.reason == "interrupted" then interrupted = true end
    end
    check(pressed_before == 2 and #S.presses == 2 and interrupted,
        "real safety preemption invalidates command without replay or competing press")
    if _G.DWConsumableTransaction.active then _G.DWConsumableTransaction.active.until_t = 0 end
    S.hyd, R.last = 30, {}
    f = assert(io.open(bridgedir .. "/brain_to_client.jsonl", "ab"))
    f:write(json.encode({ v = 1, type = "cmd", id = "real-pause", tool = "consume", args = { item = "drink" } }) .. "\n"); f:close()
    t = t + 0.5; B.step(); t = t + 0.5; B.step()
    local pause_tx = _G.DWConsumableTransaction.active
    local prior_find, scans = FindAllOf, 0
    FindAllOf = function(...) scans = scans + 1; return prior_find(...) end
    _G.DW_PAUSE = true; t = t + 0.5; B.step()
    FindAllOf = prior_find
    check(pause_tx and pause_tx.interrupted and B._state().action == nil and scans == 0,
        "real bridge pause performs state-only transaction cleanup")
    sense.local_pawn = function() return obj("BP_PlayerCharacter_C /Game/L_World.L_World:PersistentLevel.Pawn") end
    t = t + 6; B.step(); t = t + 4; B.step()
    check(not _G.DW_PAUSE and B._state().action == nil and pause_tx.interrupted,
        "real bridge unpause cannot resume old transaction")
    local next_owner = A.request(nil, { name = "post-pause", level = "command", uses_move = false })
    local premature = I.consume_begin(next_owner.token, "post-pause", 5, "ITEM_Consumable_Tea_Pumpkin")
    check(not premature, "real bridge pause retains verification gate")
    A.release(nil, next_owner.token, "test")
    pause_tx.until_t = 0
    local old = A.request(nil, { name = "abandoned", level = "command", uses_move = false })
    local abandoned = I.consume_begin(old.token, "abandoned", 5, "ITEM_Consumable_Tea_Pumpkin")
    I.use(nil, "Pumpkin Spice Infusion", { require = "drink", owner_token = old.token, transaction = abandoned })
    A.release(nil, old.token, "abandoned without cleanup")
    local fresh = A.request(nil, { name = "new owner", level = "command", uses_move = false })
    local blocked = I.consume_begin(fresh.token, "new owner", 5, "ITEM_Consumable_Tea_Pumpkin")
    local tombstone = _G.DWConsumableTransaction.active
    check(not blocked and tombstone and tombstone.interrupted, "lost owner turns abandoned press into bounded tombstone")
    tombstone.until_t = 0
    local recovered = I.consume_begin(fresh.token, "new owner", 5, "ITEM_Consumable_Tea_Pumpkin")
    check(recovered ~= nil, "lost owner gate clears after original window")
    I.consume_finish(recovered, fresh.token, false); A.release(nil, fresh.token, "test")
    I.reflex_stop(); B.stop(); A.reset(nil)
    -- Expire the interrupted test transaction without waiting or modifying game state.
    local active = _G.DWConsumableTransaction.active
    if active and active.interrupted then active.until_t = 0 end
end

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
