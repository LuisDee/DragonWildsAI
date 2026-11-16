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
--   * drop:    InventoryUIAPI:HandleDropItem(slot, slotType, amount) (UI drop; amount <= THAT stack, see M.drop_plan)
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

-- Native count of one item (asset path) in the main inventory: InventoryComponent:GetNumItemsByData(ItemData)
-- (DISCOVERIES "Native item counts", live 2026-10-28). -> integer | nil, why
function M.count_item(path)
    if rawget(_G, "DW_PAUSE") then return nil, "paused" end
    if type(path) ~= "string" or path == "" then return nil, "invalid_path" end
    local pc = M.pc()
    local inv = pc and U.try(function() return pc.InventoryComponent end)
    local asset = U.find_object(path)
    if not (U.valid(inv) and U.valid(asset)) then return nil, "inventory_or_item_unavailable" end
    local n = U.try(function() return inv:GetNumItemsByData(asset) end)
    if type(n) ~= "number" or n ~= n or n < 0 then return nil, "count_unavailable" end
    return math.floor(n)
end

-- ------------------------------------------------------------------ reading
-- Page table of the main inventory: list of {type, type_name, first (raw index), n}.
function M.pages(inv)
    local pages, first = {}, 0
    if not U.valid(inv) then return pages end -- array reads on an invalid object crash natively (21:49:34)
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

-- Soulscourge per consumable, from DATA (client_mod/scripts/consumable_wiki.lua, generated from the wiki snapshot:
-- "provides 10 hydration but also 20 Soulscourge"). The item's StatSoulScourge is only the FText LABEL
-- ("Soulscourge" on every item, live), never an amount. -> number | nil (no wiki page)
local CONS
function M.soulscourge_of(name)
    if CONS == nil then
        local ok, t = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/consumable_wiki.lua"))() end)
        CONS = ok and type(t) == "table" and t or false
    end
    local e = CONS and type(name) == "string" and CONS[name:lower()]
    return e and tonumber(e.soulscourge) or nil
end

-- Known body risks per item id (data/consumable_risks.json; BUGS L38: Dirty Water drinks crashed the client).
-- -> {risk, detail, instead} | nil
local RISKS
function M.risk_of(item)
    if RISKS == nil then
        RISKS = false
        local okj, json = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
        local f = okj and io.open(ROOT .. "/data/consumable_risks.json", "rb")
        if f then
            local doc = json.decode(f:read("a")); f:close()
            if type(doc) == "table" and type(doc.items) == "table" then RISKS = doc.items end
        end
    end
    return RISKS and type(item) == "string" and RISKS[item] or nil
end

-- CRASH-SAFETY RULE (BUGS L38, main 2026-10-26; like "never attack players"): an item whose known risk is a crash
-- (data/consumable_risks.json, risk containing "crash") is never used or equipped, by anyone: 3 of 5 Dirty Water uses
-- crashed the client (game code, null read after HandleSlotUseEvent), one of them the model's own consume.
-- -> nil | {ok = false, reason = "unsafe", risk, detail} (the truthful refusal)
function M.crash_refusal(item, name, kind)
    local rk = M.risk_of(item)
    if not (rk and tostring(rk.risk or ""):find("crash", 1, true)) then return nil end
    local verb = (kind == "food" and "eat") or (kind == "drink" and "drink") or "use"
    local instead = rk.instead and (rk.instead:sub(1, 1):upper() .. rk.instead:sub(2) .. " first.") or ""
    return { ok = false, reason = "unsafe", risk = rk.risk, item = item,
             detail = string.format("I won't %s %s: it crashes my game.%s", verb, tostring(name or item), instead ~= "" and (" " .. instead) or "") }
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
        max_stack = num(U.try(function() return data.MaxStackSize end)), -- a split into a free slot never more (skills store)
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
        d.soulscourge = M.soulscourge_of(d.name) -- amount (data), nil = unknown
        local rk = M.risk_of(d.item)
        if rk then d.risk = rk.detail end
        d.use_verb = text(U.try(function() return data.UseVerb end))
    end
    local mw = num(U.try(function() return it.NumMasterworkUpgradesApplied end))
    if mw and mw > 0 then d.masterwork = mw end
    if U.try(function() return it:IsEnchanted() end) == true then d.enchanted = true end
    if U.try(function() return it:IsBroken() end) == true then d.broken = true end
    return d
end

local function slots_of(comp, fn)
    if rawget(_G, "DW_PAUSE") or not U.valid(comp) then return end -- pcall cannot catch the native crash
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

-- Find an item by display name or item id (exact first, then case-insensitive whole-query substring:
-- "water" finds "Clean Water", "Clean Water" never finds "Water Rune") in the hotbar, bag or loadout.
-- prefer_kind ("drink" | "food" | "potion", use()'s opts.require): among substring hits that kind wins,
-- so "water" for a drink is the Clean Water, not the Water Rune listed before it. The brain-side resolver
-- with the same rule is client_bridge.lua M.resolve_name. Returns entry, where ("hotbar" | "bag" | "loadout").
function M.find(list, what, prefer_kind)
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
    d, w = scan(function(d) return (d.item and d.item:lower() == lw) or (d.name and d.name:lower() == lw) end)
    if d then return d, w end
    local function sub(d)
        return (d.name and d.name:lower():find(lw, 1, true)) or (d.item and d.item:lower():find(lw, 1, true))
    end
    if prefer_kind then
        d, w = scan(function(d) return d.consumable == prefer_kind and sub(d) end)
        if d then return d, w end
    end
    return scan(sub)
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
    local data = U.valid(a) and U.prop(a, "ItemData") -- the owner is any class: U.prop (R17)
    local sec = U.try(function() return ic.bHasSecondaryInteraction end) == true
    return { actor = U.short(a), class = U.class_word(a), prompt = text(U.try(function() return ic.InteractionPrompt end)),
             item = item_id(data), name = U.valid(data) and text(U.try(function() return data.Name end)) or nil,
             -- the thing's second action (UInteractionComponent.SecondaryInteractionPrompt), e.g. a stack's
             -- collect-all (UItemDeveloperSettings.CollectAllRadius / bCollectAllCollectsOnlySameType)
             secondary = sec and (text(U.try(function() return ic.SecondaryInteractionPrompt end)) or "secondary") or nil }
end

-- Press the interact key once (one frame of IA_Interact), as a human pressing E. opts.secondary: the
-- secondary-interact key instead (PlayerInteractionManager.SecondaryInteractAction), e.g. collect-all.
function M.press_interact(log, opts)
    local pawn = M.pawn()
    local mgr = pawn and U.try(function() return pawn.InteractionManager end)
    if not U.valid(mgr) then
        for _, c in ipairs(U.find_all("PlayerInteractionManager")) do
            local o = U.try(function() return c:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(pawn) then mgr = c end
        end
    end
    local secondary = type(opts) == "table" and opts.secondary == true
    local ia = U.valid(mgr) and U.try(function() return secondary and mgr.SecondaryInteractAction or mgr.InteractAction end)
    if not U.valid(ia) then return { ok = false, reason = secondary and "no secondary interact action" or "no IA_Interact" } end
    local sub = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local fn = U.find_object(M.IA_INTERACT_FN)
    if not (sub and fn) then return { ok = false, reason = "no input subsystem / inject function" } end
    -- a HOLD interaction (UInteractionComponent.InteractionType 1, e.g. an Anima Vent's siphon) runs until the key
    -- is let go: remember it, so the skill that pressed it (or a walk) lets go (M.release_held)
    local held
    if not secondary then
        local det = pawn and U.try(function() return pawn.InteractableDetector end)
        local ic = U.valid(det) and U.try(function() return det.CurrentInteractable end)
        local itype = U.valid(ic) and U.try(function() return ic.InteractionType end) or nil
        if itype ~= nil and tonumber(itype) == 1 then held = M.hold_row(ic) end
    end
    say(log, "inject " .. tostring(U.short(ia)) .. (held and (" (hold: " .. tostring(held.name or held.actor) .. ")") or ""))
    local ok, err = pcall(function() fn(sub, ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    if ok and held then held.t = os.clock(); rawset(_G, "DW_HELD_INTERACTION", held) end -- (a global: a hot reload keeps it)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, action = U.short(ia), hold = held and true or nil }
end

function M.hold_row(ic)
    local a = U.try(function() return ic:GetOwner() end)
    return { ic = ic, actor = U.valid(a) and U.short(a) or nil, prompt = text(U.try(function() return ic.InteractionPrompt end)),
             name = U.valid(a) and (text(U.try(function() return a.AnimaVentData.DisplayName end)) or U.class_word(a)) or nil }
end

-- The hold interaction he is pressing (DW_HELD_INTERACTION, set by press_interact): {actor, name, prompt, s} or nil. A human
-- holding E on an Anima Vent stands rooted while it siphons (montage AM_PlayerM_Sorcery_Spellcast_AnimaRuneSiphoning, and
-- it keeps draining the vent); the game ends it on the manager's InteractActionStop (IA_InteractHold), the release
-- (live 2026-11-01 19:20Z: never let go, he stood rooted at the vent for minutes; 20:23Z the same, freed by the release).
-- opts.scan: also catch a hold pressed by another path: the detector's Hold target lists him in its replicated
-- PlayersCurrentlyInteracting (a TArray read: only from a caller that is standing still, never across a teleport).
function M.held_interaction(opts)
    local h = rawget(_G, "DW_HELD_INTERACTION")
    if h and not U.valid(h.ic) then rawset(_G, "DW_HELD_INTERACTION", nil); h = nil end
    if not h and type(opts) == "table" and opts.scan and not rawget(_G, "DW_PAUSE") then
        local pawn = M.pawn()
        local det = pawn and U.try(function() return pawn.InteractableDetector end)
        local ic = U.valid(det) and U.try(function() return det.CurrentInteractable end)
        local itype = U.valid(ic) and U.try(function() return ic.InteractionType end) or nil
        if itype ~= nil and tonumber(itype) == 1 then
            local me, mine = U.short(pawn), false
            pcall(function() ic.PlayersCurrentlyInteracting:ForEach(function(_, e)
                local c = e:get(); if U.valid(c) and U.short(c) == me then mine = true end end) end)
            if mine then h = M.hold_row(ic); h.t, h.found = os.clock(), true; rawset(_G, "DW_HELD_INTERACTION", h) end
        end
    end
    if not h then return nil end
    return { actor = h.actor, name = h.name, prompt = h.prompt, found = h.found, s = h.t and math.floor((os.clock() - h.t) * 10 + 0.5) / 10 or nil }
end

-- Let go of the interact key: one frame of the manager's InteractActionStop, as a human releasing E. Only when a
-- hold was pressed, so a tap interaction is never sent a stray release. -> {ok, released = name} | nil
function M.release_held(log, why)
    local h = rawget(_G, "DW_HELD_INTERACTION")
    if not h then return nil end
    rawset(_G, "DW_HELD_INTERACTION", nil)
    local pawn = M.pawn()
    local mgr = pawn and U.try(function() return pawn.InteractionManager end)
    local ia = U.valid(mgr) and U.try(function() return mgr.InteractActionStop end)
    local sub = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local fn = U.find_object(M.IA_INTERACT_FN)
    if not (U.valid(ia) and sub and fn) then return { ok = false, reason = "no InteractActionStop / input subsystem" } end
    say(log, "release " .. tostring(U.short(ia)) .. " (let go of " .. tostring(h.name or h.actor) .. (why and ("; " .. why) or "") .. ")")
    local ok, err = pcall(function() fn(sub, ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, released = h.name or h.actor, prompt = h.prompt }
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
    local refuse = M.crash_refusal(d.item, d.name, d.consumable) -- its hotbar key would consume it
    if refuse then say(log, "equip refused (crash-safety): " .. tostring(d.item)); return refuse end
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

-- Is `item` (id or name) equipped, according to the game itself? Read back after an equip/unequip:
--   * held: the pawn's PlayerEquipmentComponent holds it (right, or LEFT for a two-handed tool: live
--     DISCOVERIES R2), AND the spawned held actor is the item's own held-actor class (the item data's
--     HeldEquipmentActorClass), so a half-done swap (data set, actor not yet spawned) doesn't count;
--   * worn: it sits in a wearable loadout slot (Head/Body/Legs/Cape/...) and the pawn wears it;
--   * in_loadout: the loadout references it (a held hotbar item stays in its hotbar slot AND is
--     referenced by the loadout).
-- -> {item, held = "right"|"left"|nil, actor, actor_class, actor_matches, loadout_slot, worn, equipped}
local WEAR_SLOT = { Head = "head", Body = "body", Legs = "legs", Cape = "cape" }
function M.equip_state(log, item, l)
    l = l or M.list(log)
    local st = { item = item }
    if type(l) ~= "table" or l.ok == false then st.unreadable = true; return st end
    local function is_it(e) return e and (e.item == item or e.name == item) end
    for _, e in ipairs(l.loadout or {}) do
        if is_it(e) then st.loadout_slot = e.loadout_slot; st.item_id = e.item; st.name = e.name end
    end
    local h = l.held or {}
    if h.right_item == item or h.right == item then st.held = "right"
    elseif h.left_item == item or h.left == item then st.held = "left" end
    if st.held then
        local pawn = M.pawn()
        local eq = pawn and U.try(function() return pawn.PlayerEquipmentComponent end)
        if U.valid(eq) then
            local side = st.held == "right" and "Right" or "Left"
            local actor = U.try(function() return eq["HeldEquipmentActor" .. side] end)
            local data = U.try(function() return eq["GetHeldEquipmentData" .. side](eq) end)
            st.actor = U.valid(actor) and U.short(actor) or nil
            st.actor_class = U.valid(actor) and (U.class_name(actor) or ""):match("%.([%w_]+)$") or nil
            local want = U.valid(data) and U.str(U.try(function() return data.HeldEquipmentActorClass:GetObjectID():GetAssetPathName() end))
            st.want_class = want and want:match("%.([%w_]+)$") or nil
            if st.want_class and st.actor_class then st.actor_matches = st.want_class == st.actor_class
            elseif st.actor then st.actor_matches = nil end -- unreadable class: the actor exists
        end
    end
    local ws = st.loadout_slot and WEAR_SLOT[st.loadout_slot]
    if ws then
        local worn = (h.worn or {})[ws]
        st.worn = worn ~= nil and (worn == item or worn == st.name or worn == st.item_id) or nil
    end
    st.equipped = (st.held ~= nil and st.actor ~= nil and st.actor_matches ~= false) or st.worn == true
    return st
end

-- One consumable use at a time PER KIND, shared by every loaded copy of this module (the consume skill, the stay-fed
-- reflex, combat cure/eat): the game ignores a second press of the same kind during a use's ~6 s animation and the
-- stat does not rise (DISCOVERIES "Consumables", 20261027-203109), but a food and a drink overlap: Luis ate and drank
-- 0.06-0.83 s apart five times (recorder 12:47-13:19Z), and Claude's client too (2026-11-01 17:03Z, use_overlap_probe:
-- a Fillet and a Clean Water pressed in one frame, or 0.26-0.5 s apart either way, both stats rose within 1.3 s, one of
-- each spent). A potion, or any other kind, is not measured yet: it waits for, and blocks, every kind.
-- consume_busy(kind) -> {item, kind, left_s} | nil; consume_busy() = any use in progress. The clock is os.clock(),
-- wall time with ms under the MSVC CRT (mod/scripts/walltime.lua), so a lock ends at 6.0 s, not 5-6 s.
local USING = _G.DWConsumeInProgress or {}
_G.DWConsumeInProgress = USING
M.CONSUME_BUSY_S = 6
M.busy_clock = os.clock
local function lock_key(kind) return (kind == "food" or kind == "drink") and kind or "other" end
M.lock_key = lock_key
function M.consume_busy(kind)
    local now = M.busy_clock()
    local keys = kind == nil and { "food", "drink", "other" }
        or (lock_key(kind) == "other" and { "other", "food", "drink" }) or { lock_key(kind), "other" }
    for _, k in ipairs(keys) do
        local u = USING[k]
        if type(u) == "table" and u.until_t and now < u.until_t then
            return { item = u.item, kind = k, by = u.by, left_s = math.ceil((u.until_t - now) * 10) / 10 }
        end
    end
    return nil
end
local function mark_using(d, by)
    USING[lock_key(d.consumable)] = { item = d.name or d.item, by = by, until_t = M.busy_clock() + M.CONSUME_BUSY_S }
end

-- His own eat/drink comes first: the stay-fed reflex defers to the model (main 2026-11-01). Live 15:49Z: he moved a
-- Pumpkin Spice to the hotbar to drink it, the reflex drank it within its 2 s tick, and his own drink ran on a full bar
-- (wasted); 16:20Z the reflex drank a second Clean Water while his Fillet and Clean Water were queued. So:
--   * a command's consume (skills.lua) holds EVERY kind while it waits and presses, and M.use of a command
--     (opts.by == "command") holds every kind for the use's animation plus REFLEX_HOLD_S.use (his next queued use
--     follows within ~0.5 s, or a model call later). Only the reflex waits: his own food and drink still overlap
--     (the per-kind lock above); a combat use holds nothing (its kind's lock is enough);
--   * a move_item of food/drink to the hotbar (M.move) holds THAT kind for REFLEX_HOLD_S.move, the time his consume
--     needs to follow (one model call); if none follows, the reflex uses it then.
-- Under the safety floor only a hold on that very kind counts (he is fixing that stat himself); an all-kinds hold
-- never keeps him from water at the floor while he eats. Never refuses the model: only the reflex reads this.
local HOLD = _G.DWReflexHold or {}
_G.DWReflexHold = HOLD
-- move = 6 s, not longer: moving food to the hotbar and leaving it to the reflex is a real choice (its policy line
-- says so), and a 15 s hold made that wait (live r1-20261102T061730Z: moved, no consume, the reflex ate at 24 s).
-- When the reflex does go first, his own consume answers by_reflex at once (skills.lua) instead of waiting its lock
-- (r1-20261102T051035Z: 6.5 s). Under the floor a kind's hold counts only its first FLOOR_HOLD_S.
M.REFLEX_HOLD_S = { use = 4, move = 6 }
M.FLOOR_HOLD_S = 6
function M.hold_reflex(kind, secs, why)
    local key = kind or "all"
    local now = os.time()
    local until_t = now + (tonumber(secs) or 0)
    if not HOLD[key] or HOLD[key].until_t < until_t then HOLD[key] = { until_t = until_t, why = why, since = now } end
end
function M.reflex_held(kind, at_floor)
    local now = os.time()
    local h = kind and HOLD[kind]
    if h and now < h.until_t and not (at_floor and h.since and now - h.since > M.FLOOR_HOLD_S) then return h end
    h = HOLD.all
    if h and now < h.until_t and not at_floor then return h end
    return nil
end

-- Use (eat, drink, read...) `what` the way a player does: its hotbar number key if it is on the
-- hotbar, else the inventory UI's use. Unlike equip, no "already equipped" check.
function M.use(log, what, opts)
    opts = opts or {}
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what, opts.require)
    if not d or where == "loadout" then return { ok = false, reason = "not in hotbar/bag: " .. tostring(what) } end
    local refuse = M.crash_refusal(d.item, d.name, d.consumable)
    if refuse then say(log, "use refused (crash-safety): " .. tostring(d.item)); return refuse end
    local busy = d.consumable and M.consume_busy(d.consumable)
    if busy then
        return { ok = false, reason = "busy", item = d,
                 detail = "still using the " .. tostring(busy.item) .. " (about " .. busy.left_s .. " s left)" }
    end
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
        if ok and d.consumable then mark_using(d, opts.by) end
        if ok and d.consumable and opts.by == "command" then
            M.hold_reflex(nil, M.CONSUME_BUSY_S + M.REFLEX_HOLD_S.use, "his own use of " .. tostring(d.name or d.item))
        end
        return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "hotbar key " .. (d.slot + 1), item = d }
    end
    if opts.hotbar_only then return { ok = false, reason = "not on the hotbar (bag use disabled)", item = d } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, "use: HandleInternalUseItem(" .. d.slot .. ", " .. tostring(d.slot_type) .. ") " .. tostring(d.item))
    local ok, err = pcall(function() api:HandleInternalUseItem(d.slot, SLOT_TYPE[d.slot_type]) end)
    if ok and d.consumable then mark_using(d, opts.by) end
    if ok and d.consumable and opts.by == "command" then
        M.hold_reflex(nil, M.CONSUME_BUSY_S + M.REFLEX_HOLD_S.use, "his own use of " .. tostring(d.name or d.item))
    end
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

-- Move `what` to another page ("hotbar" = QuickAction, "bag" = InventoryItems), as dragging it in the
-- inventory UI (InventoryUIAPI:HandleInternalDragAndDrop, the same call unequip uses). to_slot nil = the
-- first free slot of that page. Returns at once; the caller verifies with M.list.
M.MOVE_PAGES = { hotbar = "QuickAction", bag = "InventoryItems" }
-- A full hotbar: the row that gives way to a new item. The last slot that holds no food or drink and is not in his
-- hands; nil when every slot is one of those.
function M.swap_out_row(l)
    local held = type(l.held) == "table" and l.held or {}
    for i = #(l.hotbar or {}), 1, -1 do
        local h = l.hotbar[i]
        if not h.consumable and h.item ~= held.right_item and h.item ~= held.left_item then return h end
    end
end
function M.move(log, what, to, to_slot)
    local page = M.MOVE_PAGES[tostring(to or ""):lower()]
    if not page then return { ok = false, reason = "invalid_args", detail = "to must be hotbar or bag" } end
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d then return { ok = false, reason = "not in inventory: " .. tostring(what) } end
    if where == "loadout" then return { ok = false, reason = "invalid_args", detail = "it is equipped: unequip it first" } end
    if d.slot_type == page then return { ok = true, already = true, item = d } end
    local slot = tonumber(to_slot) or M.free_slot(page)
    local out
    if page == M.MOVE_PAGES.hotbar then
        -- A drag ONTO a taken slot swaps the two (the game's own drop; live 2026-11-16: Clean Water dragged onto the
        -- Stone Pickaxe's slot, the pickaxe was in the bag by the next read). So a full hotbar takes one drag, and
        -- no slot is ever empty for the stay-fed reflex to fill first (fresh chain 20261116-085113: he moved his axe
        -- to the bag to make room, the reflex put a Clean Water there, and the soup's move read "no free slot" again).
        if not slot then
            out = M.swap_out_row(l)
            slot = out and out.slot
            if not slot then return { ok = false, reason = "inventory_full",
                detail = "my hotbar is full and every slot holds food, drink or what I'm holding" } end
        else
            for _, h in ipairs(l.hotbar or {}) do if h.slot == slot then out = h end end
        end
    end
    if not slot then return { ok = false, reason = "inventory_full", detail = "no free " .. tostring(to) .. " slot" } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, string.format("HandleInternalDragAndDrop(%d, %s, %d, %s) %s%s", d.slot, tostring(d.slot_type), slot, page, tostring(d.item),
        out and (" (swaps with " .. tostring(out.item) .. ")") or ""))
    local ok, err = pcall(function() api:HandleInternalDragAndDrop(d.slot, SLOT_TYPE[d.slot_type], slot, SLOT_TYPE[page]) end)
    if ok and page == M.MOVE_PAGES.hotbar and (d.consumable == "food" or d.consumable == "drink") then
        M.hold_reflex(d.consumable, M.REFLEX_HOLD_S.move, "he moved " .. tostring(d.name or d.item) .. " to the hotbar")
    end
    return { ok = ok, reason = (not ok) and tostring(err) or nil, item = d, to = page, to_slot = slot,
             swapped_out = out and (out.name or out.item) or nil }
end

-- ------------------------------------------------------------------ containers (chests, storage): the container screen
-- A player opens a chest with the interact key; the game then shows it through the HUD's world-inventory
-- API (InventoryUIAPI.WorldInventoryAPI.InventoryComponent = the open chest's inventory). Items move with
-- the same screen's own handlers (UInventoryUIAPI, dump Dominion.hpp:25045): HandleSplitToExternalSlot
-- (his slot -> a chest slot, an amount; the path crafting.lua's furnace loading uses) and
-- HandleSplitToSlotFromExternal (a chest slot -> his slot, an amount). Scalars + object refs only.
-- The inventory component of a container actor (graves, chests, storage), or nil.
function M.inventory_of(actor)
    if rawget(_G, "DW_PAUSE") or not U.valid(actor) then return nil end
    local inv = U.try(function() return actor:GetInventory() end)
    if not U.valid(inv) then inv = U.prop(actor, "InventoryComponent") end -- any container class: U.prop (R17)
    if not U.valid(inv) then inv = M.owned_inventory(actor) end -- a BUILT crate/chest (store said not_a_container)
    return U.valid(inv) and inv or nil
end
-- A built container's inventory: GetInventory and the InventoryComponent property are nil on BP_BaseBuilding_Crate_C
-- (live 2026-11-01 18:58Z: store -> not_a_container on his own crates; deconstruct.W.contents reads them the same way),
-- so: the one InventoryComponent whose owner is this actor. A station owns several (resources, fuel, catalyst): nil,
-- ambiguous (crafting.lua picks its own slots).
function M.owned_inventory(actor)
    local key = type(U.find_all) == "function" and U.short(actor)
    if not key then return nil end
    local found
    for _, c in ipairs(U.find_all("InventoryComponent", { skip_defaults = true }) or {}) do
        local ow = U.try(function() return c:GetOwner() end)
        if ow and U.valid(ow) and U.short(ow) == key then
            if found then return nil end
            found = c
        end
    end
    return found
end
-- Rows of an external inventory: {slots = n, rows = {{slot (0-based), item, name, count}}, by_item = {id = n}}
function M.external_rows(inv)
    local out = { slots = 0, rows = {}, by_item = {} }
    if rawget(_G, "DW_PAUSE") or not U.valid(inv) then return out end
    pcall(function()
        local arr = inv.ItemSlots
        out.slots = arr:GetArrayNum()
        for i = 1, out.slots do
            local it = arr[i]
            if U.valid(it) then
                local data = U.try(function() return it.ItemData end)
                local id = item_id(data)
                local n = tonumber(U.try(function() return it.Count end)) or tonumber(U.try(function() return it:GetStackSize() end)) or 1
                if id then
                    -- + what the item's data says about itself (category tag, max stack, weight, power level): a grave
                    -- take ranks by it and fits stacks / carry weight by it (skills.grave_take_order)
                    out.rows[#out.rows + 1] = { slot = i - 1, item = id, name = text(U.try(function() return data.Name end)) or id, count = n,
                        category = text(U.try(function() return data.Category.TagName end)),
                        max_stack = num(U.try(function() return data.MaxStackSize end)),
                        weight = num(U.try(function() return data.Weight end)),
                        power = num(U.try(function() return data.PowerLevel end)) }
                    out.by_item[id] = (out.by_item[id] or 0) + n
                end
            end
        end
    end)
    return out
end
-- The container whose screen is open now: {inv, owner (actor short id)} | nil
function M.world_inventory()
    local api = M.ui_api()
    local w = api and U.try(function() return api.WorldInventoryAPI end)
    local inv = U.valid(w) and U.try(function() return w.InventoryComponent end)
    if not U.valid(inv) then return nil end
    local owner = U.try(function() return inv:GetOwner() end)
    return { inv = inv, owner = U.valid(owner) and U.short(owner) or nil }
end
-- Close the container screen (its own close).
function M.close_world_inventory(log)
    local api = M.ui_api()
    local w = api and U.try(function() return api.WorldInventoryAPI end)
    if not U.valid(w) then return false end
    say(log, "WorldInventoryAPI:CloseCurrentInventory()")
    return pcall(function() w:CloseCurrentInventory() end)
end
-- `amount` of his row (slot, slot_type) into slot `to_slot` of the open external inventory.
function M.to_external(log, row, amount, to_slot, inv)
    local api = M.ui_api()
    local st = row and SLOT_TYPE[row.slot_type]
    if not (api and st and row.slot) then return { ok = false, reason = "no InventoryUIAPI / slot type" } end
    say(log, string.format("HandleSplitToExternalSlot(%d, %s, %d, %d) %s", row.slot, tostring(row.slot_type), amount, to_slot, tostring(row.item)))
    local ok, err = pcall(function() api:HandleSplitToExternalSlot(row.slot, st, amount, to_slot, inv) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil }
end
-- `amount` from slot `from_slot` of the open external inventory into his `to_page` (hotbar|bag) slot `to_slot`.
function M.from_external(log, from_slot, inv, amount, to_slot, to_page)
    local api = M.ui_api()
    local st = SLOT_TYPE[M.MOVE_PAGES[tostring(to_page or "bag"):lower()] or "InventoryItems"]
    if not (api and st) then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, string.format("HandleSplitToSlotFromExternal(%d, %d, %d, %s)", from_slot, amount, to_slot, tostring(to_page)))
    local ok, err = pcall(function() api:HandleSplitToSlotFromExternal(from_slot, inv, amount, to_slot, st) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil }
end

-- Which stacks to drop `want` from: HandleDropItem(slot, type, AmountOverride) drops that many of ONE stack, and an
-- amount larger than the stack drops NOTHING (silently; live 2026-11-01, build 26161880: 20 from a 16-stack, and the
-- co-play session's "drop 40 Stone" x3 from a 21-stack while 99 more sat in another). So: the smallest stack that
-- holds it all (bag before hotbar), else whole stacks largest first plus a part of the next.
-- stacks = rows {slot, slot_type, count} -> plan {{row, amount}} | nil, have
function M.drop_plan(stacks, want)
    local have, rows = 0, {}
    for _, r in ipairs(stacks or {}) do
        if (tonumber(r.count) or 0) > 0 then have = have + r.count; rows[#rows + 1] = r end
    end
    if want < 1 or have < want then return nil, have end
    local function hot(r) return r.slot_type == "QuickAction" and 1 or 0 end
    local one
    for _, r in ipairs(rows) do
        if r.count >= want and (not one or hot(r) < hot(one) or (hot(r) == hot(one) and r.count < one.count)) then one = r end
    end
    if one then return { { row = one, amount = want } }, have end
    table.sort(rows, function(a, b) if hot(a) ~= hot(b) then return hot(a) < hot(b) end return a.count > b.count end)
    local plan, left = {}, want
    for _, r in ipairs(rows) do
        if left <= 0 then break end
        local n = math.min(left, r.count)
        plan[#plan + 1] = { row = r, amount = n }
        left = left - n
    end
    return plan, have
end

-- Drop `count` of `what` on the ground, as the inventory UI's drop, across his stacks of it (M.drop_plan).
-- count nil = the whole stack found. -> {ok, item = row, amount = total, drops = {{slot, slot_type, amount}}}
function M.drop(log, what, count)
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d then return { ok = false, reason = "not in inventory: " .. tostring(what) } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    local plan
    if where == "loadout" or count == nil then
        plan = { { row = d, amount = count or d.count or 1, loadout = where == "loadout" } }
    else
        local stacks = {}
        for _, w in ipairs({ "hotbar", "bag" }) do
            for _, r in ipairs(l[w] or {}) do
                if r.item == d.item and r.slot and SLOT_TYPE[r.slot_type] then stacks[#stacks + 1] = r end
            end
        end
        local have
        plan, have = M.drop_plan(stacks, count)
        if not plan then
            return { ok = false, reason = "not_enough_resources", item = d, have = have, want = count,
                     detail = string.format("I only have %d %s.", have or 0, tostring(d.name or d.item)) }
        end
    end
    local drops, total = {}, 0
    for _, p in ipairs(plan) do
        local r = p.row
        local t = p.loadout and SLOT_TYPE.Loadout or SLOT_TYPE[r.slot_type]
        say(log, string.format("HandleDropItem(%d, %s, %d) %s (stack of %s)", r.slot, tostring(M.SLOT_TYPES[t]), p.amount,
            tostring(r.item), tostring(r.count)))
        local ok, err = pcall(function() api:HandleDropItem(r.slot, t, p.amount) end)
        if not ok then return { ok = false, reason = tostring(err), item = d, amount = total, drops = drops } end
        drops[#drops + 1] = { slot = r.slot, slot_type = M.SLOT_TYPES[t], amount = p.amount }
        total = total + p.amount
    end
    return { ok = true, item = d, amount = total, drops = drops }
end

-- ------------------------------------------------------------------ split (the inventory UI's split)
-- A player holds Shift ("Grant Split Stack"), drags a stack and picks the amount in the split widget
-- (USplitStackButtonUIInput, bHalfStackDefaultSplit); dropping it on a free slot runs the screen's own
-- UInventoryUIAPI:HandleInternalSplitToSlot(FromSlotNum, FromSlotType, Amount, ToSlotNum, ToSlotType)
-- (dump Dominion.hpp:25107; live 2026-11-01: 21 stone, Amount 3 -> 18 + 3). Scalars only.
-- Which stack to split `want` off: the smallest that keeps some (count > want), bag before hotbar.
-- stacks = rows {slot, slot_type, count} -> row | nil, biggest (the largest stack's count)
function M.split_plan(stacks, want)
    local one, biggest = nil, 0
    local function hot(r) return r.slot_type == "QuickAction" and 1 or 0 end
    for _, r in ipairs(stacks or {}) do
        local c = tonumber(r.count) or 0
        if c > biggest then biggest = c end
        if want >= 1 and c > want and (not one or hot(r) < hot(one) or (hot(r) == hot(one) and c < one.count)) then one = r end
    end
    return one, biggest
end

-- Split `count` of `what` off one of his stacks into a free slot of `to` ("bag" | "hotbar"; default the
-- stack's own page) or slot `to_slot`. -> {ok, item = row, from = {slot, slot_type, count}, to = {slot, slot_type}, amount}
function M.split(log, what, count, to, to_slot)
    count = math.floor(tonumber(count) or 0)
    if count < 1 then return { ok = false, reason = "invalid_args", detail = "count must be at least 1" } end
    local l = M.list(log)
    if not l.ok then return l end
    local d, where = M.find(l, what)
    if not d then return { ok = false, reason = "not_in_inventory", detail = "I don't have any " .. tostring(what) .. "." } end
    if where == "loadout" then return { ok = false, reason = "invalid_args", item = d, detail = "The " .. tostring(d.name) .. " is equipped; I can only split a stack in my bag or hotbar." } end
    local stacks, have = {}, 0
    for _, w in ipairs({ "hotbar", "bag" }) do
        for _, r in ipairs(l[w] or {}) do
            if r.item == d.item and r.slot and SLOT_TYPE[r.slot_type] then stacks[#stacks + 1] = r; have = have + (r.count or 0) end
        end
    end
    local name = tostring(d.name or d.item)
    local src, biggest = M.split_plan(stacks, count)
    if not src then
        if have < count then
            return { ok = false, reason = "not_enough_resources", item = d, have = have, want = count,
                     detail = string.format("I only have %d %s.", have, name) }
        end
        return { ok = false, reason = "invalid_args", item = d, have = have, want = count, stacks = #stacks,
                 detail = string.format("My biggest stack of %s holds %d, so there is nothing to split %d off; it is already a stack of its own.",
                                        name, biggest, count) }
    end
    local page = to and M.MOVE_PAGES[tostring(to):lower()] or src.slot_type
    if not page then return { ok = false, reason = "invalid_args", detail = "to must be bag or hotbar" } end
    local slot = tonumber(to_slot) or M.free_slot(page)
    if not slot then
        return { ok = false, reason = "inventory_full", item = d,
                 detail = "I have no free " .. (page == "QuickAction" and "hotbar" or "bag") .. " slot to put the split stack in." }
    end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, string.format("HandleInternalSplitToSlot(%d, %s, %d, %d, %s) %s (stack of %s)", src.slot, tostring(src.slot_type),
        count, slot, page, tostring(d.item), tostring(src.count)))
    local ok, err = pcall(function() api:HandleInternalSplitToSlot(src.slot, SLOT_TYPE[src.slot_type], count, slot, SLOT_TYPE[page]) end)
    if not ok then return { ok = false, reason = tostring(err), item = d } end
    return { ok = true, item = d, amount = count, from = { slot = src.slot, slot_type = src.slot_type, count = src.count },
             to = { slot = slot, slot_type = page } }
end

-- The stack at (slot_type, slot) in a listing, or nil.
function M.stack_at(l, slot_type, slot)
    for _, w in ipairs({ "hotbar", "bag" }) do
        for _, r in ipairs(l and l[w] or {}) do if r.slot_type == slot_type and r.slot == slot then return r end end
    end
end

-- ------------------------------------------------------------------ bridge tools (client_bridge module HANDLERS)
-- split {item, count, to?}: a waiter (no pawn, like drop); answers once the listing shows both stacks.
M.SPLIT_WAIT_S = 4
M.HANDLERS = {}
M.HANDLERS.split = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "split needs the bridge api (ctx.api)" } } end
    if type(args.item) ~= "string" or args.item == "" then return api.fail("invalid_args", { detail = "item is required" }) end
    local r = M.split(log, args.item, args.count, args.to, args.slot)
    if not r.ok then
        local code = r.reason
        if code ~= "invalid_args" and code ~= "not_in_inventory" and code ~= "not_enough_resources" and code ~= "inventory_full" then code = "body_error" end
        return api.fail(code, { item = r.item and r.item.item or args.item, have = r.have, want = r.want,
                                detail = r.detail or ("I couldn't split the stack: " .. tostring(r.reason) .. ".") })
    end
    local it, n, from, to = r.item, r.amount, r.from, r.to
    local name = tostring(it.name or it.item)
    local w = { kind = "split" }
    w.poll = function()
        local l = M.list(log)
        if not l.ok then return nil end
        local a, b = M.stack_at(l, from.slot_type, from.slot), M.stack_at(l, to.slot_type, to.slot)
        if a and b and a.item == it.item and b.item == it.item and a.count == from.count - n and b.count == n then
            return { ok = true, data = { item = it.item, name = name, count = n, left = a.count,
                from = { slot = from.slot, page = from.slot_type == "QuickAction" and "hotbar" or "bag", count = a.count },
                to = { slot = to.slot, page = to.slot_type == "QuickAction" and "hotbar" or "bag", count = b.count },
                detail = string.format("I split my %d %s into %d and %d.", from.count, name, a.count, b.count) } }
        end
    end
    w.expire = function()
        return api.fail("verification_failed", { item = it.item, count = n,
            detail = string.format("I tried to split %d %s off my stack of %d, but my inventory didn't change.", n, name, from.count) })
    end
    return { wait = w, wait_s = M.SPLIT_WAIT_S }
end

local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    split = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = true,
        description = "Split a carried stack in two: take count off it into a free slot, the rest stays (e.g. to drop, store "
            .. "or give only part). drop, store and give take the amount themselves, so split only when a separate stack is wanted.",
        args = { type = "object", required = { "item", "count" }, properties = obj({
            item = { type = "string", description = "A carried item's name or id." },
            count = { type = "integer", minimum = 1, description = "How many go into the new stack." },
            to = { type = "string", enum = { "bag", "hotbar" }, description = "Where the new stack goes (default: beside the old one)." } }) },
        ground = obj({ item = "carried" }),
        reasons = { "not_in_inventory", "not_enough_resources", "inventory_full", "verification_failed", "invalid_args" } },
}

-- ------------------------------------------------------------------ stay fed and watered (reflex)
-- A game-thread loop (LoopInGameThreadWithDelay, started by a short command; never blocks the
-- command runner). Every cfg.period_ms it reads hydration / sustenance from the pawn and:
--   * below cfg.drink_below / cfg.eat_below: uses the best drink / food he carries (item data class
--     UDrinkItemData / UFoodItemData; clean first, i.e. no Soulscourge stat), via M.use (the hotbar
--     key or the inventory UI's use), at most once per cfg.cooldown_s per kind;
--   * when hungry/thirsty and the game's detector targets a dropped food/drink world item: presses
--     interact to collect it (cfg.collect).
-- Events go to client_io/events/vitals.jsonl as {"type":"reflex", action, item, stat}.
-- bad_after (BUGS L32): an item is given up only after this many FAILED uses in a row. One miss (pressed while
-- busy: mid-gather 07:48 UTC, hydration fell 29.8 -> 29.5) used to mark Clean Water bad for good, and he
-- dehydrated to 0 with water on his hotbar. A success clears the count; the per-kind cooldown spaces retries.
M.REFLEX_CFG = { period_ms = 2000, cooldown_s = 6, verify_s = 4, collect = true, allow_bag = false, bad_after = 3,
                 floor_leaves = 6, fetch_cooldown_s = 4 }
-- Soulscourge (wiki, dragonwilds.runescape.wiki/w/Soulscourge): when the toxicity bar fills it deals 10 damage/s
-- for 5 s. The bar's size is the game's own ToxicityEffectLevels (live read 2026-11-01: one level at 100).
M.SOULSCOURGE_DAMAGE = 50

local R = _G.DWFedReflex or {}
_G.DWFedReflex = R

-- VITALS POLICY (PRINCIPLES #2e, review H2/M8): WHEN to eat/drink is the MODEL's call (tool
-- set_vitals_policy, from vitals, stock, threats, the current task); the code only keeps a SAFETY FLOOR:
-- below SAFETY_FLOOR_PCT of the maximum he consumes whatever the policy says, so he can't die of thirst
-- while frozen, stuck or fighting. Percentages of the CURRENT maximum (it drops after a death: 75).
--   drink_below_pct / eat_below_pct  consume when the stat is below this share of its maximum
--   heal_below_pct  also eat food that heals (item data AmountToHealOnConsume > 0) when HP is below this
--                   share (nil = never eat just to heal)
--   reserve_warn    tell the brain when fewer than this many usable food (or drink) items are carried
-- Kept in _G (hot reload and module instances share it).
M.SAFETY_FLOOR_PCT = 10
M.POLICY_DEFAULT = { drink_below_pct = 40, eat_below_pct = 40, heal_below_pct = nil, reserve_warn = 2 }
function M.vitals_policy()
    if not R.policy then
        R.policy = {}
        for k, v in pairs(M.POLICY_DEFAULT) do R.policy[k] = v end
    end
    return R.policy
end
local function clamp_pct(v, lo) v = tonumber(v); if not v then return nil end; return math.max(lo, math.min(95, v)) end
-- set_vitals_policy: only the given fields change; values are clamped (eat/drink never below the floor).
function M.set_vitals_policy(log, args)
    local p = M.vitals_policy()
    args = args or {}
    if args.drink_below_pct ~= nil then p.drink_below_pct = clamp_pct(args.drink_below_pct, M.SAFETY_FLOOR_PCT) or p.drink_below_pct end
    if args.eat_below_pct ~= nil then p.eat_below_pct = clamp_pct(args.eat_below_pct, M.SAFETY_FLOOR_PCT) or p.eat_below_pct end
    if args.heal_below_pct ~= nil then
        local v = tonumber(args.heal_below_pct)
        p.heal_below_pct = (v and v > 0) and clamp_pct(v, 1) or nil
    end
    if args.reserve_warn ~= nil then p.reserve_warn = math.max(0, math.min(20, math.floor(tonumber(args.reserve_warn) or p.reserve_warn))) end
    say(log, string.format("vitals policy: drink<%s%% eat<%s%% heal<%s%% reserve %s (floor %d%%)", tostring(p.drink_below_pct),
        tostring(p.eat_below_pct), tostring(p.heal_below_pct), tostring(p.reserve_warn), M.SAFETY_FLOOR_PCT))
    local out = {}
    for k, v in pairs(p) do out[k] = v end
    out.safety_floor_pct = M.SAFETY_FLOOR_PCT
    return { ok = true, policy = out }
end

local function stat(p, comp, getter)
    local c = U.try(function() return p[comp] end)
    return U.valid(c) and num(U.try(function() return c[getter](c) end)) or nil
end

local function best(list, kind, bad, wheres)
    local pick
    for _, where in ipairs(wheres or { "hotbar", "bag" }) do
        for _, d in ipairs(list[where] or {}) do
            if d.consumable == kind and not (bad and bad[d.item]) and not M.risk_of(d.item) then
                -- clean first (no Soulscourge, or unknown), then the least Soulscourge
                local s, ps = tonumber(d.soulscourge) or 0, pick and (tonumber(pick.soulscourge) or 0)
                if not pick or s < ps then pick = d end
            end
        end
    end
    return pick
end
M.best_consumable = best

local json_mod
local okw, walltime = pcall(require, "walltime") -- ms epoch ts (mod/scripts/walltime.lua, telemetry item 5)
local function reflex_emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    ev.type = "reflex"
    -- an older walltime in the client's require cache has no stamp (live 2026-11-01 13:3x: this error aborted every
    -- reflex tick, so he could not drink): fall back, never lose the row or the tick
    if okw and type(walltime) == "table" and type(walltime.stamp) == "function" then walltime.stamp(ev)
    else ev.ts = (okw and type(walltime) == "table" and type(walltime.now) == "function") and walltime.now() or os.time()
        ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ev.ts)) end
    -- the reflex's last use, for consume's "not carried" words (skills.lua: "my reflex drank the last ... 2 s ago")
    if ev.action == "use" and ev.ok and ev.item then _G.DW_REFLEX_LAST_USE = { item = ev.item, name = ev.name, kind = ev.kind, t = os.time() } end
    local line = U.try(function() return json_mod.encode(ev) end)
    local f = line and io.open(ROOT .. "/client_io/events/vitals.jsonl", "a")
    if f then f:write(line, "\n"); f:close() end
end

-- The shared modal gate (input.lua; talk review finding 11): no hotbar use or interact press while build mode,
-- a container screen, a conversation or a non-gameplay input mode is open (the key would act on THAT screen).
local INPUT_MOD
local function input_gate()
    if INPUT_MOD == nil then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/input.lua"))() end)
        INPUT_MOD = ok and type(m) == "table" and m or false
    end
    if not INPUT_MOD then return nil end
    local ok, blocked = pcall(INPUT_MOD.gate)
    return ok and blocked or nil
end
M._input_gate = input_gate
-- The safety floor's exit step and the modal's owner (input.lua; tests replace them)
M._input_leave = function(m)
    input_gate() -- loads INPUT_MOD
    if not INPUT_MOD or type(INPUT_MOD.leave_modal_step) ~= "function" then return false end
    local ok, r = pcall(INPUT_MOD.leave_modal_step, m)
    return ok and r == true
end
M._input_owner = function(kind)
    if not INPUT_MOD then return nil end
    local ok, o = pcall(INPUT_MOD.owner, kind)
    return ok and type(o) == "table" and o.owner or nil
end

-- His toxicity (the Soulscourge build-up bar): pawn.BP_Components_Toxicity.CurrentToxicity, and the bar's size
-- = the lowest ToxicityEffectLevels value (live read 2026-11-01 client_mod/commands/survival_probe.lua: current 0,
-- levels [100]). -> {current, max} | nil (unreadable)
function M.toxicity(p)
    p = p or M.pawn()
    local c = p and U.try(function() return p.BP_Components_Toxicity end)
    if not U.valid(c) then return nil end
    local cur = num(U.try(function() return c.CurrentToxicity end))
    if not cur then return nil end
    if not R.tox_max then
        pcall(function() c.ToxicityEffectLevels:ForEach(function(_, e)
            local v = num(U.try(function() return e:get().Value end))
            if v and v > 0 and (not R.tox_max or v < R.tox_max) then R.tox_max = v end
        end) end)
    end
    return { current = cur, max = R.tox_max or 100 }
end

-- Drag one listed row to the first free slot of a page ("hotbar" | "bag"), the inventory UI's own drag
-- (InventoryUIAPI:HandleInternalDragAndDrop, as M.move; the row itself, so a second copy elsewhere is not picked).
local function drag_row(log, d, to)
    local page = M.MOVE_PAGES[to]
    local slot = page and M.free_slot(page)
    if not slot then return { ok = false, reason = "inventory_full" } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, string.format("reflex drag %s (%s %d) -> %s %d", tostring(d.item), tostring(d.slot_type), d.slot, page, slot))
    local ok, err = pcall(function() api:HandleInternalDragAndDrop(d.slot, SLOT_TYPE[d.slot_type], slot, SLOT_TYPE[page]) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, to_slot = slot }
end

-- Below the safety floor with the drink/food only in the bag (live 2026-11-01 12:26-12:42: 13 Pumpkin Spice Infusions
-- in his bag while the reflex drank 4 Dirty Waters off the hotbar, then hydration 19 -> 0 and 56 HP lost to thirst,
-- "drink only in the bag" once a minute, no brain running): move it to the hotbar as a player drags it; the next
-- tick drinks it. A full hotbar first gives one slot that holds no food/drink and is not in his hands to the bag.
-- -> {ok, moved = item} | {ok, made_room = name} (the item follows on the next tick) | {ok = false, reason}
local function fetch_to_hotbar(log, l, d)
    local r = drag_row(log, d, "hotbar")
    if r.ok then return { ok = true, moved = d.item } end
    if r.reason ~= "inventory_full" then return r end
    local held = type(l.held) == "table" and l.held or {}
    R.swap_failed = R.swap_failed or {}
    local prev = R.made_room -- the last slot we emptied is still full with the same item: that drag did nothing
    for _, h in ipairs(prev and l.hotbar or {}) do
        if (h.raw or h.slot) == prev.key and h.item == prev.item then R.swap_failed[prev.key] = true end
    end
    R.made_room = nil
    local out
    for i = #(l.hotbar or {}), 1, -1 do
        local h = l.hotbar[i]
        if not h.consumable and h.item ~= held.right_item and h.item ~= held.left_item and not R.swap_failed[h.raw or h.slot] then
            out = h; break
        end
    end
    if not out then return { ok = false, reason = "my hotbar is all food, drink or what I'm holding" } end
    local r2 = drag_row(log, out, "bag")
    if not r2.ok then R.swap_failed[out.raw or out.slot] = true else R.made_room = { key = out.raw or out.slot, item = out.item } end
    return { ok = r2.ok, made_room = out.name or out.item, reason = r2.reason }
end
M._fetch_to_hotbar = fetch_to_hotbar

-- One use outcome for an item: a failure is a strike, `bad_after` strikes in a row mark it bad (no more presses
-- until the reflex restarts); a success clears its strikes.
local function strike(item, ok)
    R.strikes = R.strikes or {}
    if ok then R.strikes[item] = nil; return end
    R.strikes[item] = (R.strikes[item] or 0) + 1
    if R.strikes[item] >= (M.REFLEX_CFG.bad_after or 3) then R.bad[item] = true end
end

function R.tick(log)
    if _G.DW_PAUSE then return end -- set by disconnect/travel commands: no UObject access during teardown
    local cfg = M.REFLEX_CFG
    local p = M.pawn()
    if not p or U.try(function() return p.HealthComponent:IsDead() end) == true then return end
    local hyd = stat(p, "HydrationComponent", "GetCurrentHydration")
    local sus = stat(p, "SustenanceComponent", "GetCurrentSustenance")
    local hyd_max = stat(p, "HydrationComponent", "GetMaxHydration") or 100
    local sus_max = stat(p, "SustenanceComponent", "GetMaxSustenance") or 100
    local pol, floor = M.vitals_policy(), M.SAFETY_FLOOR_PCT
    local thirsty = hyd and hyd < hyd_max * math.max(pol.drink_below_pct or floor, floor) / 100
    local hungry = sus and sus < sus_max * math.max(pol.eat_below_pct or floor, floor) / 100
    R.floor_hit = (hyd and hyd < hyd_max * floor / 100) or (sus and sus < sus_max * floor / 100) or nil
    local t = os.time()
    R.last = R.last or {}
    R.bad = R.bad or {}
    -- Outcome of the previous uses: the stat must have risen, else that item is marked bad (no retries). One pending
    -- use per kind (drink, food, heal): a food and a drink overlap in the game (consume_busy above), so a drink never
    -- waits for a food's verify, nor the other way round. R.pending = {kind = {kind, item, before, t}} | nil.
    local hp = U.try(function() return p.HealthComponent:GetAuthoritativeHealth() end)
    local hp_max = U.try(function() return p.HealthComponent:GetMaxHealth() end)
    if type(R.pending) == "table" and R.pending.kind then R.pending = { [R.pending.kind] = R.pending } end -- pre-reload shape
    for k, pd in pairs(R.pending or {}) do
        if t - pd.t >= cfg.verify_s then
            local now_v = (k == "drink" and hyd) or (k == "heal" and hp) or sus
            local known = type(now_v) == "number" and type(pd.before) == "number"
            local ok = known and now_v > pd.before + 0.5
            reflex_emit({ action = "verify", kind = k, item = pd.item, before = pd.before, after = now_v, ok = ok == true })
            if known then strike(pd.item, ok) end -- an unreadable stat is not the item's fault
            R.pending[k] = nil
        end
    end
    if R.pending and not next(R.pending) then R.pending = nil end
    local pending = R.pending or {}
    local pend = next(pending) ~= nil -- any use still being verified
    local function set_pending(k, row) R.pending = R.pending or {}; R.pending[k] = row end
    -- Nothing to drink / eat carried at all (live 2026-10-26 15:06: hydration 0, HP falling, and the reflex
    -- was SILENT because it only warned about bag-only items): tell the brain once a minute, so it fetches some.
    -- `failed` = carried, but every one is marked bad (failed bad_after uses in a row).
    local carried
    if (thirsty or hungry) and not (pending.drink and pending.food) then
        carried = M.list(log)
        for _, need in ipairs({ { thirsty and not pending.drink, "drink", hyd, hyd_max }, { hungry and not pending.food, "food", sus, sus_max } }) do
            local risky
            for _, where in ipairs({ "hotbar", "bag" }) do
                for _, x in ipairs(carried[where] or {}) do if x.consumable == need[2] and M.risk_of(x.item) then risky = risky or x end end
            end
            if need[1] and not best(carried, need[2], R.bad, { "hotbar", "bag" }) and risky then
                -- BUGS L38: never drunk by the reflex, even at the floor (it crashed the client twice); the brain is told
                R.warned = R.warned or {}
                local key = "held_back_" .. need[2]
                if not R.warned[key] or t - R.warned[key] >= 60 then
                    R.warned[key] = t
                    local rk = M.risk_of(risky.item)
                    reflex_emit({ action = key, kind = need[2], item = risky.item, name = risky.name, stat = need[3], floor = R.floor_hit == true,
                                  risk = rk.risk, reason = "only " .. tostring(risky.name) .. ": " .. tostring(rk.instead or "find a safe one") })
                end
            elseif need[1] and not best(carried, need[2], R.bad, { "hotbar", "bag" }) then
                local failed = best(carried, need[2], nil, { "hotbar", "bag" }) ~= nil
                R.warned = R.warned or {}
                local key = "no_" .. need[2]
                if not R.warned[key] or t - R.warned[key] >= 60 then
                    R.warned[key] = t
                    reflex_emit({ action = key, kind = need[2], stat = need[3], max = need[4], floor = R.floor_hit == true,
                                  reason = failed and ("every " .. need[2] .. " I carry failed to work")
                                      or ("no " .. need[2] .. " carried, hotbar or bag") })
                end
            end
        end
    end
    -- a modal is open: no presses this tick (reported once a minute)
    local blocked = (thirsty or hungry or pol.heal_below_pct) and M._input_gate() or nil
    -- Safety floor: a build or container screen never starves him. With a usable drink/food on the hotbar he
    -- leaves that screen himself (input.leave_modal_step: build Cancel / the container's own close), one step
    -- per tick, at most cfg.floor_leaves per blocked episode, then drinks on a later tick once the gate is clear.
    -- A HUD screen (input kind "screen": a station's Processing/Inventory panels, BUGS B-stuck-focused-ui) too:
    -- its leave step is the game's own InputManagerUIAPI:CloseWidgetIfOpen.
    if blocked and R.floor_hit and not pend and (blocked.kind == "build" or blocked.kind == "container" or blocked.kind == "screen") then
        local usable
        for _, need in ipairs({ { thirsty, "drink" }, { hungry, "food" } }) do
            if need[1] and best(carried or M.list(log), need[2], R.bad, cfg.allow_bag and { "hotbar", "bag" } or { "hotbar" }) then
                usable = need[2]
            end
        end
        R.floor_leaves = R.floor_leaves or 0
        if usable and R.floor_leaves < (cfg.floor_leaves or 6) then
            R.floor_leaves = R.floor_leaves + 1
            local pressed = M._input_leave(blocked)
            local owner = M._input_owner(blocked.kind)
            reflex_emit({ action = "floor_leave", kind = blocked.kind, mode = blocked.mode, owner = owner, need = usable,
                          ok = pressed == true, try = R.floor_leaves,
                          reason = "below the safety floor: leaving the " .. tostring(blocked.kind) .. " screen to " .. usable })
        end
    elseif not blocked then
        R.floor_leaves = nil
    end
    if blocked then
        if not R.blocked_at or t - R.blocked_at >= 60 then
            R.blocked_at = t
            reflex_emit({ action = "blocked", kind = blocked.kind, mode = blocked.mode,
                          reason = blocked.screens and ("the " .. table.concat(blocked.screens, " + ") .. " screen is open")
                              or ("a " .. tostring(blocked.kind) .. " screen is open") })
        end
        return
    end
    -- another use of the same kind (a command, combat) is mid-animation: a press now would be ignored, so that kind
    -- waits (consume_busy(kind) in each branch below); the other kind goes ahead
    -- eat to heal (policy heal_below_pct, the model's call): food whose item data heals (heal > 0)
    local hurt = pol.heal_below_pct and type(hp) == "number" and type(hp_max) == "number" and hp_max > 0
        and hp < hp_max * pol.heal_below_pct / 100
    if hurt and not pending.heal and not pending.food and not hungry and (not R.last.heal or t - R.last.heal >= cfg.cooldown_s)
        and not M.reflex_held("food") and not M.consume_busy("food") then
        local l = M.list(log)
        local pick
        for _, d in ipairs(l.hotbar or {}) do
            if d.consumable == "food" and (tonumber(d.heal) or 0) > 0 and not R.bad[d.item] and (tonumber(d.soulscourge) or 0) == 0 then
                if not pick or (tonumber(d.heal) or 0) < (tonumber(pick.heal) or 0) then pick = d end -- smallest heal first
            end
        end
        if pick then
            R.last.heal = t
            local r = M.use(log, pick.item, { require = "food", hotbar_only = true, by = "reflex" })
            reflex_emit({ action = "use", kind = "heal", item = pick.item, name = pick.name, stat = hp, ok = r.ok, via = r.via,
                          reason = r.reason })
            if r.ok then set_pending("heal", { kind = "heal", item = pick.item, before = hp, t = t }) else strike(pick.item, false) end
            return
        end
    end
    if not (thirsty or hungry) then return end -- (after the verify: a successful use ends the need)
    if not (pending.drink and pending.food) then
        local l = carried or M.list(log)
        -- the floor is per stat (it used to be either: a sustenance under the floor let him drink Dirty Water at 39 % water)
        local at_floor = { drink = hyd and hyd < hyd_max * floor / 100, food = sus and sus < sus_max * floor / 100 }
        local maxes, pcts = { drink = hyd_max, food = sus_max }, { drink = pol.drink_below_pct, food = pol.eat_below_pct }
        local words = { drink = "water", food = "food" }
        local function sc(x) return x and (tonumber(x.soulscourge) or 0) or nil end
        for _, need in ipairs({ { thirsty, "drink", hyd }, { hungry, "food", sus } }) do
            local kind = need[2]
            local held = need[1] and M.reflex_held(kind, at_floor[kind])
            if held and (not R.held_said or R.held_said ~= held) then
                R.held_said = held -- the log says once per hold why it waits (no event: it is his own use)
                say(log, "reflex: " .. kind .. " held off (" .. tostring(held.why) .. ")")
            end
            local busy = need[1] and not held and M.consume_busy(kind)
            if not pending[kind] and not (kind == "food" and pending.heal) and need[1] and not held and not busy
                and (not R.last[kind] or t - R.last[kind] >= cfg.cooldown_s) then
                local why -- the reason this use was chosen, for the brain (activity reflex_use.reason)
                local stat_s = string.format("%s %.0f/%.0f", words[kind], need[3] or 0, maxes[kind] or 0)
                -- Hotbar only by default: the client hung right after a bag "use"
                -- (InventoryUIAPI:HandleInternalUseItem, 18:27:40 UTC), so that path is suspect.
                local d = best(l, kind, R.bad, cfg.allow_bag and { "hotbar", "bag" } or { "hotbar" })
                local in_bag = not cfg.allow_bag and best(l, kind, R.bad, { "bag" }) or nil
                if at_floor[kind] and in_bag and (not d or sc(in_bag) < sc(d)) then
                    -- under the floor: what is in the bag beats nothing, and a cleaner one beats Dirty Water (a player
                    -- opens his bag); drag it to the hotbar now, drink it next tick
                    if not R.last["fetch_" .. kind] or t - R.last["fetch_" .. kind] >= (cfg.fetch_cooldown_s or 4) then
                        R.last["fetch_" .. kind] = t
                        local r = fetch_to_hotbar(log, l, in_bag)
                        reflex_emit({ action = "fetch", kind = kind, item = in_bag.item, name = in_bag.name, stat = need[3], max = maxes[kind],
                                      ok = r.ok, made_room = r.made_room, floor = true,
                                      reason = r.ok and string.format("%s is under the %d%% safety floor and my %s is in my bag%s: %s",
                                          stat_s, floor, tostring(in_bag.name), d and (" (only " .. tostring(d.name) .. " on my hotbar)") or "",
                                          r.made_room and ("making room on my hotbar (moved " .. tostring(r.made_room) .. " to my bag)")
                                              or "moving it to my hotbar")
                                          or ("I couldn't get my " .. tostring(in_bag.name) .. " out of my bag: " .. tostring(r.reason)) })
                    end
                    d = nil
                elseif not d and in_bag then
                    R.warned = R.warned or {}
                    if not R.warned[kind] or t - R.warned[kind] >= 60 then
                        R.warned[kind] = t
                        reflex_emit({ action = "no_hotbar_" .. kind, kind = kind, stat = need[3],
                                      reason = kind .. " only in the bag; move it to the hotbar (I do it myself under the "
                                          .. floor .. "% floor)" })
                    end
                end
                -- Soulscourge (Dirty Water +20; a full toxicity bar deals 50 damage): only below the safety floor; above it
                -- the brain is told to purify / fetch a clean one (Luis/main 2026-10-26: clean first, dirty only to survive).
                -- Under the floor it is drunk unless that very drink fills the bar while the 50 damage would kill him.
                if d and sc(d) > 0 and at_floor[kind] then
                    local tox = M.toxicity(p)
                    local fills = tox and tox.current + sc(d) >= tox.max
                    if fills and type(hp) == "number" and hp <= M.SOULSCOURGE_DAMAGE + 5 then
                        R.warned = R.warned or {}
                        if not R.warned.toxic or t - R.warned.toxic >= 60 then
                            R.warned.toxic = t
                            reflex_emit({ action = "held_back_toxic", kind = kind, item = d.item, name = d.name, stat = need[3], hp = hp,
                                          toxicity = tox.current, toxicity_max = tox.max, floor = true,
                                          reason = string.format("%s is under the floor, but one more %s fills my Soulscourge (toxicity %.0f/%.0f, +%d) "
                                              .. "and its %d damage would kill me at %.0f HP: I need clean water (boil it at a Campfire)",
                                              stat_s, tostring(d.name), tox.current, tox.max, sc(d), M.SOULSCOURGE_DAMAGE, hp) })
                        end
                        d = nil
                    else
                        why = string.format("%s is under the %d%% safety floor and %s is all I have (+%d Soulscourge%s)", stat_s, floor,
                            tostring(d.name), sc(d), tox and string.format(", toxicity %.0f/%.0f%s", tox.current, tox.max,
                                fills and string.format(": this fills it, %d damage", M.SOULSCOURGE_DAMAGE) or "") or "")
                    end
                end
                if d and sc(d) > 0 and not at_floor[kind] then
                    R.warned = R.warned or {}
                    local key = "held_back_" .. need[2]
                    if not R.warned[key] or t - R.warned[key] >= 60 then
                        R.warned[key] = t
                        reflex_emit({ action = key, kind = need[2], item = d.item, name = d.name, stat = need[3], soulscourge = d.soulscourge,
                                      reason = string.format("only %s (+%d Soulscourge) to %s; kept for the safety floor (purify it or find a clean one)",
                                          tostring(d.name), tonumber(d.soulscourge) or 0, need[2] == "drink" and "drink" or "eat") })
                    end
                    d = nil
                end
                if d then
                    why = why or string.format("%s is under %s", stat_s, at_floor[kind] and (floor .. "% (the safety floor)")
                        or (tostring(pcts[kind]) .. "% (my vitals policy)"))
                    R.last[kind] = t
                    local r = M.use(log, d.item, { require = kind, hotbar_only = not cfg.allow_bag, by = "reflex" })
                    reflex_emit({ action = "use", kind = kind, item = d.item, name = d.name, stat = need[3], ok = r.ok,
                                  via = r.via, reason = r.ok and why or r.reason, floor = at_floor[kind] == true })
                    if r.ok then set_pending(kind, { kind = kind, item = d.item, before = need[3], t = t })
                    else strike(d.item, false) end
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
                if U.short(w) == tg.actor then data = U.prop(w, "ItemData") end -- R17
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
    R.bad, R.pending, R.strikes = {}, nil, {} -- a (re)start forgets items marked bad
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
    return { running = R.loop ~= nil, last = R.last, bad = R.bad, pending = R.pending, err = R.err, cfg = R.cfg, held = HOLD,
             warned = R.warned, floor_hit = R.floor_hit, floor_leaves = R.floor_leaves }
end

return M
