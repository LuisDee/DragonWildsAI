-- inventory: Claude's REAL inventory on his own client (route R2), driven only through the game's
-- own client paths, the same ones a player's key press or inventory-UI click runs:
--   * read:    PlayerController.InventoryComponent (paged: 8 hotbar slots, then Items/Runes/Ammo/Quest
--              pages from InventoryPages), LoadoutComponent (12 slots, ELoadoutSlot order),
--              PersonalInventoryComponent, pawn.PlayerEquipmentComponent (what is in his hands)
--   * collect: the interact key. EnhancedInput InjectInputVectorForAction(IA_Interact) on the local
--              player's EnhancedInputLocalPlayerSubsystem; the game's own InteractableDetector has
--              already chosen the target (CurrentInteractable), exactly as for a human pressing E
--   * equip:   hotbar item -> WBP_Inventory_QuickAccesBar.UseItemInSlot(i) (the handler bound to
--              IA_Inventory_QuickAccess_SelectSlot<i+1>, i.e. the number keys); bag item ->
--              InventoryUIAPI:HandleInternalUseItem(slot, slotType) (the inventory UI's "use")
--   * unequip / move: InventoryUIAPI:HandleInternalDragAndDrop(from, fromType, to, toType) (UI drag)
--   * drop:    InventoryUIAPI:HandleDropItem(slot, slotType, amount) (UI drop)
-- Never grants items or writes inventory state. Every call that changes state is logged first.
-- Calls return at once; the server confirms asynchronously, so callers re-read with M.list.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.LOADOUT_SLOTS = { [0] = "Head", "Body", "Legs", "Cape", "Trinket", "Ammo", "MagicAmmo1", "HeldRight", "HeldLeft",
                    "CrossbowBolts", "FishingBait", "Trinket2" }
M.SLOT_TYPES = { [0] = "QuickAction", "InventoryItems", "InventoryRunes", "InventoryAmmunition", "InventoryQuestItems",
                 "Loadout", "External", "FishingBaits", "None" }
local SLOT_TYPE = {}
for k, v in pairs(M.SLOT_TYPES) do SLOT_TYPE[v] = k end
M.SLOT_TYPE = SLOT_TYPE
local LOADOUT_INDEX = {}
for k, v in pairs(M.LOADOUT_SLOTS) do LOADOUT_INDEX[v:lower()] = k end

local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end
local function item_id(data) local p = U.valid(data) and U.path_of(data); return p and p:match("%.([%w_]+)$") or nil end

local function say(log, msg) if log then pcall(log, "inventory: " .. msg) end end

-- ------------------------------------------------------------------ handles
function M.pc()
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then return pc end
    end
end

function M.pawn(pc)
    pc = pc or M.pc()
    local p = pc and U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end

-- The HUD's InventoryUIAPI for the local player (lives in HUDUISubsystem).
function M.ui_api(pc)
    pc = pc or M.pc()
    for _, a in ipairs(U.find_all("InventoryUIAPI", { skip_defaults = true })) do
        local apc = U.try(function() return a.PlayerController end)
        if not pc or (U.valid(apc) and U.short(apc) == U.short(pc)) then return a end
    end
end

-- The live hotbar widget (transient, 8 slots), not the widget-tree archetype.
function M.hotbar()
    for _, w in ipairs(U.find_all("QuickAccessBarBase", { skip_defaults = true })) do
        if (U.fullname(w) or ""):find("/Engine/Transient", 1, true) then return w end
    end
end

-- ------------------------------------------------------------------ reading
-- Page table of the main inventory: list of {type, type_name, first (raw index), n}.
function M.pages(inv)
    local pages, first = {}, 0
    local quick = num(U.try(function() return inv.NumberOfQuickActionSlots end)) or 0
    if quick > 0 then pages[1] = { type = 0, type_name = "QuickAction", first = 0, n = quick }; first = quick end
    pcall(function()
        inv.InventoryPages:ForEach(function(_, e)
            local p = e:get()
            local t, n = p.SlotType, p.NumSlots
            pages[#pages + 1] = { type = t, type_name = M.SLOT_TYPES[t], first = first, n = n }
            first = first + n
        end)
    end)
    return pages
end

-- raw ItemSlots index -> slot type, index within that page (the UI's SlotNum).
local function page_of(pages, raw)
    for _, p in ipairs(pages) do
        if raw >= p.first and raw < p.first + p.n then return p.type, raw - p.first end
    end
end

local KIND_CLASSES = { { "food", "/Script/Dominion.FoodItemData" }, { "drink", "/Script/Dominion.DrinkItemData" },
                       { "potion", "/Script/Dominion.PotionItemData" } }
local function is_a(obj, path)
    local cls = U.find_object(path)
    return cls ~= nil and U.valid(obj) and U.try(function() return obj:IsA(cls) end) == true
end
M.is_a = is_a

-- "food" | "drink" | "potion" | nil for a UItemData, by class (equipment is never consumable).
function M.consumable_kind(data)
    if not U.valid(data) or is_a(data, "/Script/Dominion.EquipmentData") then return nil end
    for _, k in ipairs(KIND_CLASSES) do
        if is_a(data, k[2]) then return k[1] end
    end
    return nil
end

function M.describe_item(it)
    if not U.valid(it) then return nil end
    local data = U.try(function() return it.ItemData end)
    local d = {
        name = text(U.try(function() return data.Name end)) or text(U.try(function() return it:GetPlayerFacingName() end)),
        item = item_id(data),
        count = num(U.try(function() return it.Count end)),
        durability = num(U.try(function() return it.Durability end)),
        max_durability = num(U.try(function() return it:GetMaxDurability() end)),
        kind = U.class_word(it), -- Item / HeldEquipmentItem / WearableEquipment / ...
        category = text(U.try(function() return data.Category.TagName end)),
    }
    if d.max_durability and d.max_durability <= 0 then d.max_durability, d.durability = nil, nil end
    -- Food / drink / potion by CLASS (UObject:IsA on the item data). Never by property presence:
    -- UE4SS returns a non-nil invalid "TrivialObject" for a property the object does not have, so
    -- `data.StatSustenance ~= nil` is true for a pickaxe (live bug 18:20 UTC: the reflex "ate" one).
    d.consumable = M.consumable_kind(data)
    if d.consumable == "food" then
        d.sustenance = text(U.try(function() return data.StatSustenance end))
        d.heal = num(U.try(function() return data.AmountToHealOnConsume end))
    elseif d.consumable == "drink" then
        d.hydration = text(U.try(function() return data.StatHydration end))
    end
    if d.consumable then
        d.soulscourge = text(U.try(function() return data.StatSoulScourge end))
        d.use_verb = text(U.try(function() return data.UseVerb end))
    end
    local mw = num(U.try(function() return it.NumMasterworkUpgradesApplied end))
    if mw and mw > 0 then d.masterwork = mw end
    if U.try(function() return it:IsEnchanted() end) == true then d.enchanted = true end
    if U.try(function() return it:IsBroken() end) == true then d.broken = true end
    return d
end

local function slots_of(comp, fn)
    pcall(function()
        local arr = comp.ItemSlots
        for i = 1, arr:GetArrayNum() do
            local it = arr[i]
            if U.valid(it) then fn(i - 1, it) end
        end
    end)
end

-- Held items, read from the pawn (what other players see in his hands).
function M.held(pawn)
    pawn = pawn or M.pawn()
    local eq = pawn and U.try(function() return pawn.PlayerEquipmentComponent end)
    if not U.valid(eq) then return {} end
    local function name(data) return U.valid(data) and (text(U.try(function() return data.Name end)) or item_id(data)) or nil end
    local r = U.try(function() return eq:GetHeldEquipmentDataRight() end)
    local l = U.try(function() return eq:GetHeldEquipmentDataLeft() end)
    local worn = {}
    for _, s in ipairs({ "Head", "Body", "Legs", "Cape" }) do
        worn[s:lower()] = name(U.try(function() return eq["Current" .. s .. "Wearable"] end))
    end
    return { right = name(r), right_item = item_id(r), left = name(l), left_item = item_id(l),
             right_actor = U.short(U.try(function() return eq.HeldEquipmentActorRight end)),
             left_actor = U.short(U.try(function() return eq.HeldEquipmentActorLeft end)), worn = worn }
end

-- Everything he owns: hotbar, bag (by page), loadout (equipped, by ELoadoutSlot), personal chest
-- inventory, and held items. Each entry has the raw slot plus the UI's (slot_type, slot).
function M.list(log)
    local pc = M.pc()
    if not pc then return { ok = false, reason = "no local player controller" } end
    local inv = U.try(function() return pc.InventoryComponent end)
    local out = { ok = true, hotbar = {}, bag = {}, loadout = {}, personal = {} }
    if U.valid(inv) then
        local pages = M.pages(inv)
        out.pages = {}
        for _, p in ipairs(pages) do out.pages[#out.pages + 1] = p.type_name .. ":" .. p.n end
        slots_of(inv, function(raw, it)
            local d = M.describe_item(it)
            local t, s = page_of(pages, raw)
            d.raw, d.slot_type, d.slot = raw, M.SLOT_TYPES[t], s
            table.insert(t == 0 and out.hotbar or out.bag, d)
        end)
        out.empty_slots = num(U.try(function() return inv:GetNumEmptySlots() end))
        out.weight = num(U.try(function() return inv:ComputeCurrentWeight() end))
    end
    local lo = U.try(function() return pc.LoadoutComponent end)
    if U.valid(lo) then
        slots_of(lo, function(raw, it)
            local d = M.describe_item(it)
            d.slot, d.loadout_slot = raw, M.LOADOUT_SLOTS[raw]
            out.loadout[#out.loadout + 1] = d
        end)
    end
    local pi = U.try(function() return pc.PersonalInventoryComponent end)
    if U.valid(pi) then
        slots_of(pi, function(raw, it)
            local d = M.describe_item(it); d.slot = raw
            out.personal[#out.personal + 1] = d
        end)
    end
    out.held = M.held(M.pawn(pc))
    return out
end

-- Find an item by display name or item id (exact first, then case-insensitive substring) in the
-- hotbar, bag or loadout. Returns entry, where ("hotbar" | "bag" | "loadout").
function M.find(list, what)
    if type(what) ~= "string" or what == "" then return nil end
    local lw = what:lower()
    local function scan(test)
        for _, where in ipairs({ "hotbar", "bag", "loadout" }) do
            for _, d in ipairs(list[where] or {}) do
                if test(d) then return d, where end
            end
        end
    end
    local d, w = scan(function(d) return d.item == what or d.name == what end)
    if d then return d, w end
    return scan(function(d)
        return (d.name and d.name:lower():find(lw, 1, true)) or (d.item and d.item:lower():find(lw, 1, true))
    end)
end

-- ------------------------------------------------------------------ collect (interact key)
M.IA_INTERACT_FN = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction"

-- What the game's own detector currently targets (what E would act on).
function M.interact_target(pawn)
    pawn = pawn or M.pawn()
    local det = pawn and U.try(function() return pawn.InteractionDetector end)
    if not U.valid(det) then
        for _, c in ipairs(U.find_all("InteractableDetectorComponent")) do
            local o = U.try(function() return c:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(pawn) then det = c end
        end
    end
    if not U.valid(det) then return nil end
    local ic = U.try(function() return det.CurrentInteractable end)
    if not U.valid(ic) then return { none = true } end
    local a = U.try(function() return ic:GetOwner() end)
    local data = U.valid(a) and U.try(function() return a.ItemData end)
    return { actor = U.short(a), class = U.class_word(a), prompt = text(U.try(function() return ic.InteractionPrompt end)),
             item = item_id(data), name = U.valid(data) and text(U.try(function() return data.Name end)) or nil }
end

-- Press the interact key once (one frame of IA_Interact), as a human pressing E.
function M.press_interact(log)
    local pawn = M.pawn()
    local mgr = pawn and U.try(function() return pawn.InteractionManager end)
    if not U.valid(mgr) then
        for _, c in ipairs(U.find_all("PlayerInteractionManager")) do
            local o = U.try(function() return c:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(pawn) then mgr = c end
        end
    end
    local ia = U.valid(mgr) and U.try(function() return mgr.InteractAction end)
    if not U.valid(ia) then return { ok = false, reason = "no IA_Interact" } end
    local sub = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local fn = U.find_object(M.IA_INTERACT_FN)
    if not (sub and fn) then return { ok = false, reason = "no input subsystem / inject function" } end
    say(log, "inject " .. tostring(U.short(ia)))
    local ok, err = pcall(function() fn(sub, ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, action = U.short(ia) }
end

-- Collect what the detector targets, if it is a dropped world item.
function M.collect(log)
    local t = M.interact_target()
    if not t or t.none then return { ok = false, reason = "nothing targeted", target = t } end
    if not t.item then return { ok = false, reason = "target is not a world item", target = t } end
    local r = M.press_interact(log)
    r.target = t
    return r
end

-- ------------------------------------------------------------------ equip / unequip / drop
-- Equip `what` (name or item id) from his own inventory the way a player does.
function M.equip(log, what)
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d then return { ok = false, reason = "not in inventory: " .. tostring(what) } end
    if where == "loadout" then return { ok = true, reason = "already equipped", item = d } end
    -- A held hotbar item is ALSO referenced by the loadout; pressing its key again would put it away.
    for _, e in ipairs(l.loadout or {}) do
        if e.item == d.item then return { ok = true, reason = "already equipped", item = e } end
    end
    local before = l.held
    if where == "hotbar" then
        local bar = M.hotbar()
        if not bar then return { ok = false, reason = "no hotbar widget" } end
        say(log, "hotbar UseItemInSlot(" .. d.slot .. ") " .. tostring(d.item))
        local ok, err = pcall(function() bar:UseItemInSlot(d.slot) end)
        return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "hotbar key " .. (d.slot + 1), item = d, held_before = before }
    end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, "HandleInternalUseItem(" .. d.slot .. ", " .. tostring(d.slot_type) .. ") " .. tostring(d.item))
    local ok, err = pcall(function() api:HandleInternalUseItem(d.slot, SLOT_TYPE[d.slot_type]) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "inventory use", item = d, held_before = before }
end

-- Use (eat, drink, read...) `what` the way a player does: its hotbar number key if it is on the
-- hotbar, else the inventory UI's use. Unlike equip, no "already equipped" check.
function M.use(log, what, opts)
    opts = opts or {}
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d or where == "loadout" then return { ok = false, reason = "not in hotbar/bag: " .. tostring(what) } end
    -- Fresh check of the exact slot about to be pressed: the item there must be this item and,
    -- when opts.require is set, of that consumable class. Equipment is never "used" here.
    local pc = M.pc()
    local it = U.try(function() return pc.InventoryComponent.ItemSlots[d.raw + 1] end)
    local data = U.valid(it) and U.try(function() return it.ItemData end)
    if not U.valid(data) or item_id(data) ~= d.item then return { ok = false, reason = "slot changed", item = d } end
    if is_a(data, "/Script/Dominion.EquipmentData") then return { ok = false, reason = "equipment, not usable", item = d } end
    if opts.require and M.consumable_kind(data) ~= opts.require then
        return { ok = false, reason = "not " .. opts.require, item = d }
    end
    if where == "hotbar" then
        local bar = M.hotbar()
        if not bar then return { ok = false, reason = "no hotbar widget" } end
        say(log, "use: hotbar UseItemInSlot(" .. d.slot .. ") " .. tostring(d.item))
        local ok, err = pcall(function() bar:UseItemInSlot(d.slot) end)
        return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "hotbar key " .. (d.slot + 1), item = d }
    end
    if opts.hotbar_only then return { ok = false, reason = "not on the hotbar (bag use disabled)", item = d } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, "use: HandleInternalUseItem(" .. d.slot .. ", " .. tostring(d.slot_type) .. ") " .. tostring(d.item))
    local ok, err = pcall(function() api:HandleInternalUseItem(d.slot, SLOT_TYPE[d.slot_type]) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "inventory use", item = d }
end

-- First empty slot of a page type in the main inventory (UI slot number), or nil.
function M.free_slot(type_name)
    local pc = M.pc()
    local inv = pc and U.try(function() return pc.InventoryComponent end)
    if not U.valid(inv) then return nil end
    local used = {}
    slots_of(inv, function(raw) used[raw] = true end)
    for _, p in ipairs(M.pages(inv)) do
        if p.type_name == type_name then
            for s = 0, p.n - 1 do if not used[p.first + s] then return s end end
        end
    end
end

-- Unequip a loadout slot ("HeldRight", "Body", ... or its index). A held item that sits in the
-- hotbar is put away by pressing its number key again (opts.via ~= "drag"); anything else is
-- dragged from the equipment bar into the first free bag slot.
function M.unequip(log, slot, opts)
    opts = opts or {}
    local idx = type(slot) == "number" and slot or LOADOUT_INDEX[tostring(slot):lower()]
    if not idx then return { ok = false, reason = "unknown loadout slot " .. tostring(slot) } end
    if (idx == 7 or idx == 8) and opts.via ~= "drag" then
        local l = M.list(log)
        local held
        for _, d in ipairs(l.loadout or {}) do if d.slot == idx then held = d end end
        if not held then return { ok = true, reason = "slot already empty" } end
        for _, d in ipairs(l.hotbar or {}) do
            if d.item == held.item then
                local bar = M.hotbar()
                if not bar then return { ok = false, reason = "no hotbar widget" } end
                say(log, "hotbar UseItemInSlot(" .. d.slot .. ") again to put away " .. tostring(d.item))
                local ok, err = pcall(function() bar:UseItemInSlot(d.slot) end)
                return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "hotbar key " .. (d.slot + 1), item = held }
            end
        end
    end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    local to = M.free_slot("InventoryItems")
    if not to then return { ok = false, reason = "no free bag slot" } end
    say(log, string.format("HandleInternalDragAndDrop(%d, Loadout, %d, InventoryItems)", idx, to))
    local ok, err = pcall(function() api:HandleInternalDragAndDrop(idx, SLOT_TYPE.Loadout, to, SLOT_TYPE.InventoryItems) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, from = M.LOADOUT_SLOTS[idx], to_slot = to }
end

-- Drop `count` of `what` on the ground, as the inventory UI's drop. count nil = the whole stack.
function M.drop(log, what, count)
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d then return { ok = false, reason = "not in inventory: " .. tostring(what) } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    local t = where == "loadout" and SLOT_TYPE.Loadout or SLOT_TYPE[d.slot_type]
    local amount = count or d.count or 1
    say(log, string.format("HandleDropItem(%d, %s, %d) %s", d.slot, tostring(M.SLOT_TYPES[t]), amount, tostring(d.item)))
    local ok, err = pcall(function() api:HandleDropItem(d.slot, t, amount) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, item = d, amount = amount }
end

-- ------------------------------------------------------------------ stay fed and watered (reflex)
-- A game-thread loop (LoopInGameThreadWithDelay, started by a short command; never blocks the
-- command runner). Every cfg.period_ms it reads hydration / sustenance from the pawn and:
--   * below cfg.drink_below / cfg.eat_below: uses the best drink / food he carries (item data class
--     UDrinkItemData / UFoodItemData; clean first, i.e. no Soulscourge stat), via M.use (the hotbar
--     key or the inventory UI's use), at most once per cfg.cooldown_s per kind;
--   * when hungry/thirsty and the game's detector targets a dropped food/drink world item: presses
--     interact to collect it (cfg.collect).
-- Events go to client_io/events/vitals.jsonl as {"type":"reflex", action, item, stat}.
M.REFLEX_CFG = { period_ms = 2000, drink_below = 30, eat_below = 30, cooldown_s = 6, verify_s = 4, collect = true, allow_bag = false }

local R = _G.DWFedReflex or {}
_G.DWFedReflex = R

local function stat(p, comp, getter)
    local c = U.try(function() return p[comp] end)
    return U.valid(c) and num(U.try(function() return c[getter](c) end)) or nil
end

local function best(list, kind, bad, wheres)
    local pick
    for _, where in ipairs(wheres or { "hotbar", "bag" }) do
        for _, d in ipairs(list[where] or {}) do
            if d.consumable == kind and not (bad and bad[d.item]) then
                local clean = not d.soulscourge
                if not pick or (clean and pick.soulscourge) then pick = d end
            end
        end
    end
    return pick
end
M.best_consumable = best

local json_mod
local function reflex_emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    ev.type, ev.ts = "reflex", os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local line = U.try(function() return json_mod.encode(ev) end)
    local f = line and io.open(ROOT .. "/client_io/events/vitals.jsonl", "a")
    if f then f:write(line, "\n"); f:close() end
end

function R.tick(log)
    if _G.DW_PAUSE then return end -- set by disconnect/travel commands: no UObject access during teardown
    local cfg = M.REFLEX_CFG
    local p = M.pawn()
    if not p or U.try(function() return p.HealthComponent:IsDead() end) == true then return end
    local hyd = stat(p, "HydrationComponent", "GetCurrentHydration")
    local sus = stat(p, "SustenanceComponent", "GetCurrentSustenance")
    local thirsty = hyd and hyd < cfg.drink_below
    local hungry = sus and sus < cfg.eat_below
    local t = os.time()
    R.last = R.last or {}
    R.bad = R.bad or {}
    -- Outcome of the previous use: the stat must have risen, else that item is marked bad (no retries).
    local pend = R.pending
    if pend and t - pend.t >= cfg.verify_s then
        local now_v = pend.kind == "drink" and hyd or sus
        local ok = now_v and pend.before and now_v > pend.before + 0.5
        reflex_emit({ action = "verify", kind = pend.kind, item = pend.item, before = pend.before, after = now_v, ok = ok == true })
        if not ok then R.bad[pend.item] = true end
        R.pending = nil
        pend = nil
    end
    if not (thirsty or hungry) then return end -- (after the verify: a successful use ends the need)
    if not pend then
        local l = M.list(log)
        for _, need in ipairs({ { thirsty, "drink", hyd }, { hungry, "food", sus } }) do
            if not R.pending and need[1] and (not R.last[need[2]] or t - R.last[need[2]] >= cfg.cooldown_s) then
                -- Hotbar only by default: the client hung right after a bag "use"
                -- (InventoryUIAPI:HandleInternalUseItem, 18:27:40 UTC), so that path is suspect.
                local d = best(l, need[2], R.bad, cfg.allow_bag and { "hotbar", "bag" } or { "hotbar" })
                if not d and best(l, need[2], R.bad, { "bag" }) then
                    R.warned = R.warned or {}
                    if not R.warned[need[2]] or t - R.warned[need[2]] >= 60 then
                        R.warned[need[2]] = t
                        reflex_emit({ action = "no_hotbar_" .. need[2], kind = need[2], stat = need[3],
                                      reason = need[2] .. " only in the bag; move it to the hotbar" })
                    end
                end
                if d then
                    R.last[need[2]] = t
                    local r = M.use(log, d.item, { require = need[2], hotbar_only = not cfg.allow_bag })
                    reflex_emit({ action = "use", kind = need[2], item = d.item, name = d.name, stat = need[3], ok = r.ok,
                                  via = r.via, reason = r.reason })
                    if r.ok then R.pending = { kind = need[2], item = d.item, before = need[3], t = t }
                    else R.bad[d.item] = true end
                end
            end
        end
    end
    if cfg.collect then
        local tg = M.interact_target(p)
        if tg and tg.item and (not R.last.collect or t - R.last.collect >= 2) then
            -- only consumables: read the targeted world item's data class
            local data
            for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do
                if U.short(w) == tg.actor then data = U.try(function() return w.ItemData end) end
            end
            local kind = M.consumable_kind(data)
            local is_drink, is_food = kind == "drink", kind == "food"
            if (thirsty and is_drink) or (hungry and is_food) then
                R.last.collect = t
                local r = M.press_interact(log)
                reflex_emit({ action = "collect", item = tg.item, name = tg.name, ok = r.ok })
            end
        end
    end
end

-- Start (idempotent) / stop / status. opts override M.REFLEX_CFG fields.
function M.reflex_start(log, opts)
    for k, v in pairs(opts or {}) do M.REFLEX_CFG[k] = v end
    R.cfg = M.REFLEX_CFG
    R.bad, R.pending = {}, nil -- a (re)start forgets items marked bad
    R.tick_fn = R.tick
    if not R.loop then
        R.loop = LoopInGameThreadWithDelay(M.REFLEX_CFG.period_ms, function()
            local r = _G.DWFedReflex
            if r and r.tick_fn then
                local ok, err = pcall(r.tick_fn, nil)
                if not ok then r.err = tostring(err) end
            end
        end)
    end
    return { ok = true, cfg = M.REFLEX_CFG }
end

function M.reflex_stop()
    if R.loop and CancelDelayedAction then pcall(CancelDelayedAction, R.loop) end
    R.loop = nil
    return { ok = true }
end

function M.reflex_status()
    return { running = R.loop ~= nil, last = R.last, bad = R.bad, pending = R.pending, err = R.err, cfg = R.cfg }
end

return M
