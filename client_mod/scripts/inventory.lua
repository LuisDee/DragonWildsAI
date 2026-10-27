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
    local data = U.valid(a) and U.try(function() return a.ItemData end)
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
    local refuse = M.crash_refusal(d.item, d.name, d.consumable) -- its hotbar key would consume it
    if refuse then say(log, "equip refused (crash-safety): " .. tostring(d.item)); return refuse end
    if d.consumable then return { ok = false, reason = "consumable requires consume transaction" } end
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

-- Shared across separately loaded inventory modules: one in-process consumable use at a time.
local TX = _G.DWConsumableTransaction or { seq = 0 }
_G.DWConsumableTransaction = TX
local function tx_arbiter()
    local ok, a = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/arbiter.lua"))() end)
    return ok and a or nil
end
local function tx_owner(token)
    local a = tx_arbiter()
    return token ~= nil and a and a.holds and a.holds(token) == true
end
function M.consume_begin(token, caller, seconds, item)
    if _G.DW_PAUSE or not tx_owner(token) then return nil, "consumable owner unavailable" end
    local now = os.time()
    local prior = TX.active
    if prior and not prior.interrupted then
        local held = tx_owner(prior.token)
        if TX.active == prior and not held then M.consume_finish(prior.id, prior.token, true) end
    end
    if _G.DW_PAUSE or not tx_owner(token) then return nil, "consumable owner unavailable" end
    if TX.active and TX.active.interrupted and TX.active.until_t <= now then TX.active = nil end
    if TX.active then return nil, "consumable verification pending" end
    TX.seq = TX.seq + 1
    TX.active = { id = TX.seq, token = token, caller = caller, item = item, duration = (seconds or 6) + ((seconds or 6) > 0 and 1 or 0), until_t = now, pressed = false }
    return TX.seq
end
function M.consume_owned(id, token)
    local x = TX.active
    if not x or x.interrupted or x.id ~= id or x.token ~= token then return false end
    if _G.DW_PAUSE then M.consume_finish(id, token, true); return false end
    local held = tx_owner(token)
    if TX.active ~= x or x.interrupted or x.id ~= id or x.token ~= token then return false end
    if _G.DW_PAUSE or not held then M.consume_finish(id, token, true); return false end
    return true
end
function M.consume_finish(id, token, interrupted)
    local x = TX.active
    if not x or x.id ~= id or x.token ~= token then return false end
    if interrupted and x.pressed and os.time() < x.until_t then x.interrupted = true
    else TX.active = nil end
    return true
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
    if d.consumable and not M.consume_owned(opts.transaction, opts.owner_token) then return { ok = false, reason = "consumable transaction required" } end
    if where == "hotbar" then
        local bar = M.hotbar()
        if not bar then return { ok = false, reason = "no hotbar widget" } end
        say(log, "use: hotbar UseItemInSlot(" .. d.slot .. ") " .. tostring(d.item))
        if d.consumable and (not M.consume_owned(opts.transaction, opts.owner_token) or TX.active.pressed or TX.active.item ~= d.item) then return { ok = false, reason = "consumable transaction invalid" } end
        if d.consumable then TX.active.pressed = true; TX.active.until_t = os.time() + TX.active.duration end
        local ok, err = pcall(function() bar:UseItemInSlot(d.slot) end)
        return { ok = ok, reason = (not ok) and tostring(err) or nil, via = "hotbar key " .. (d.slot + 1), item = d }
    end
    if opts.hotbar_only then return { ok = false, reason = "not on the hotbar (bag use disabled)", item = d } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, "use: HandleInternalUseItem(" .. d.slot .. ", " .. tostring(d.slot_type) .. ") " .. tostring(d.item))
    if d.consumable and (not M.consume_owned(opts.transaction, opts.owner_token) or TX.active.pressed or TX.active.item ~= d.item) then return { ok = false, reason = "consumable transaction invalid" } end
    if d.consumable then TX.active.pressed = true; TX.active.until_t = os.time() + TX.active.duration end
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

-- Move `what` to another page ("hotbar" = QuickAction, "bag" = InventoryItems), as dragging it in the
-- inventory UI (InventoryUIAPI:HandleInternalDragAndDrop, the same call unequip uses). to_slot nil = the
-- first free slot of that page. Returns at once; the caller verifies with M.list.
M.MOVE_PAGES = { hotbar = "QuickAction", bag = "InventoryItems" }
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
    if not slot then return { ok = false, reason = "inventory_full", detail = "no free " .. tostring(to) .. " slot" } end
    local api = M.ui_api()
    if not api then return { ok = false, reason = "no InventoryUIAPI" } end
    say(log, string.format("HandleInternalDragAndDrop(%d, %s, %d, %s) %s", d.slot, tostring(d.slot_type), slot, page, tostring(d.item)))
    local ok, err = pcall(function() api:HandleInternalDragAndDrop(d.slot, SLOT_TYPE[d.slot_type], slot, SLOT_TYPE[page]) end)
    return { ok = ok, reason = (not ok) and tostring(err) or nil, item = d, to = page, to_slot = slot }
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
    if not U.valid(inv) then inv = U.try(function() return actor.InventoryComponent end) end
    return U.valid(inv) and inv or nil
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
                    out.rows[#out.rows + 1] = { slot = i - 1, item = id, name = text(U.try(function() return data.Name end)) or id, count = n }
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
-- bad_after (BUGS L32): an item is given up only after this many FAILED uses in a row. One miss (pressed while
-- busy: mid-gather 07:48 UTC, hydration fell 29.8 -> 29.5) used to mark Clean Water bad for good, and he
-- dehydrated to 0 with water on his hotbar. A success clears the count; the per-kind cooldown spaces retries.
M.REFLEX_CFG = { period_ms = 2000, cooldown_s = 6, verify_s = 4, collect = true, allow_bag = false, bad_after = 3,
                 floor_leaves = 6 }

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
local function reflex_emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    ev.type, ev.ts = "reflex", os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
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

-- One use outcome for an item: a failure is a strike, `bad_after` strikes in a row mark it bad (no more presses
-- until the reflex restarts); a success clears its strikes.
local function strike(item, ok)
    R.strikes = R.strikes or {}
    if ok then R.strikes[item] = nil; return end
    R.strikes[item] = (R.strikes[item] or 0) + 1
    if R.strikes[item] >= (M.REFLEX_CFG.bad_after or 3) then R.bad[item] = true end
end

local function reflex_release(interrupted)
    local p = R.pending
    if p and p.tx then M.consume_finish(p.tx, p.token, interrupted) end
    if p and p.token then local a = tx_arbiter(); if a then pcall(a.release, nil, p.token, "fed verification ended") end end
    R.pending = nil
end
local function reflex_input(log, emergency, fn)
    local a = tx_arbiter()
    if not a then return nil end
    local grant = a.request(log, { name = "fed:input", level = emergency and "reflex" or "task", uses_move = false,
        resumable = false, replace_same = false, lease_s = 3 })
    if not (grant and grant.ok and a.holds(grant.token)) then return nil end
    local ok, result = pcall(fn)
    local owned = a.holds(grant.token)
    a.release(log, grant.token, "fed input ended")
    return ok and owned and result or nil
end
local function reflex_use(log, item, kind, before, t, cfg)
    local a = tx_arbiter()
    if not a then return nil end
    local tx, token
    local function interrupted() if tx and token then M.consume_finish(tx, token, true) end end
    local r = a.request(log, { name = "fed:" .. kind, level = R.floor_hit and "reflex" or "task", uses_move = false, resumable = false,
        replace_same = false, lease_s = cfg.verify_s + 2, on_suspend = interrupted, on_stop = interrupted })
    if not (r and r.ok) then return nil end
    token = r.token
    tx = M.consume_begin(r.token, "fed", cfg.verify_s, item)
    if not tx then a.release(log, r.token, "consumable busy"); return nil end
    local pawn = M.pawn()
    if kind == "drink" then before = stat(pawn, "HydrationComponent", "GetCurrentHydration")
    elseif kind == "food" then before = stat(pawn, "SustenanceComponent", "GetCurrentSustenance")
    else before = U.try(function() return pawn.HealthComponent:GetAuthoritativeHealth() end) end
    if not M.consume_owned(tx, r.token) or type(before) ~= "number" then
        M.consume_finish(tx, r.token, true); a.release(log, r.token, "baseline unavailable"); return nil
    end
    local result = M.use(log, item, { require = kind == "heal" and "food" or kind, hotbar_only = not cfg.allow_bag,
        owner_token = r.token, transaction = tx })
    if not M.consume_owned(tx, r.token) then
        M.consume_finish(tx, r.token, true); a.release(log, r.token, "use interrupted"); return nil
    end
    if not result.ok then
        M.consume_finish(tx, r.token, true); a.release(log, r.token, "use failed"); return result
    end
    R.pending = { kind = kind, item = item, before = before, t = t, token = r.token, tx = tx }
    return result
end

function R.tick(log)
    if _G.DW_PAUSE then
        if R.pending and R.pending.tx then M.consume_finish(R.pending.tx, R.pending.token, true); R.pending = nil end
        return
    end -- set by disconnect/travel commands: no UObject access during teardown
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
    -- Outcome of the previous use: the stat must have risen, else that item is marked bad (no retries).
    local pend = R.pending
    local hp = U.try(function() return p.HealthComponent:GetAuthoritativeHealth() end)
    local hp_max = U.try(function() return p.HealthComponent:GetMaxHealth() end)
    if pend and not M.consume_owned(pend.tx, pend.token) then
        reflex_release(true); pend = nil
    end
    if pend and t - pend.t >= cfg.verify_s then
        local now_v
        if pend.kind == "drink" then now_v = hyd elseif pend.kind == "heal" then now_v = hp else now_v = sus end
        local known = type(now_v) == "number" and type(pend.before) == "number"
        local ok = known and now_v > pend.before + 0.5
        reflex_emit({ action = "verify", kind = pend.kind, item = pend.item, before = pend.before, after = now_v, ok = ok == true })
        if known then strike(pend.item, ok) end
        reflex_release(false)
        pend = nil
    end
    -- Nothing to drink / eat carried at all (live 2026-10-26 15:06: hydration 0, HP falling, and the reflex
    -- was SILENT because it only warned about bag-only items): tell the brain once a minute, so it fetches some.
    -- `failed` = carried, but every one is marked bad (failed bad_after uses in a row).
    local carried
    if (thirsty or hungry) and not pend then
        carried = M.list(log)
        for _, need in ipairs({ { thirsty, "drink", hyd, hyd_max }, { hungry, "food", sus, sus_max } }) do
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
            local owner = M._input_owner(blocked.kind)
            local pressed = reflex_input(log, true, function()
                if M._input_owner(blocked.kind) then return false end
                return M._input_leave(blocked)
            end)
            if pressed ~= nil then R.floor_leaves = R.floor_leaves + 1 end
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
    -- eat to heal (policy heal_below_pct, the model's call): food whose item data heals (heal > 0)
    local hurt = pol.heal_below_pct and type(hp) == "number" and type(hp_max) == "number" and hp_max > 0
        and hp < hp_max * pol.heal_below_pct / 100
    if hurt and not pend and not hungry and (not R.last.heal or t - R.last.heal >= cfg.cooldown_s) then
        local l = M.list(log)
        local pick
        for _, d in ipairs(l.hotbar or {}) do
            if d.consumable == "food" and (tonumber(d.heal) or 0) > 0 and not R.bad[d.item] and (tonumber(d.soulscourge) or 0) == 0 then
                if not pick or (tonumber(d.heal) or 0) < (tonumber(pick.heal) or 0) then pick = d end -- smallest heal first
            end
        end
        if pick then
            local r = reflex_use(log, pick.item, "heal", hp, t, cfg)
            if not r then return end
            R.last.heal = t
            reflex_emit({ action = "use", kind = "heal", item = pick.item, name = pick.name, stat = hp, ok = r.ok, via = r.via,
                          reason = r.reason })
            if not r.ok then strike(pick.item, false) end
            return
        end
    end
    if not (thirsty or hungry) then return end -- (after the verify: a successful use ends the need)
    if not pend then
        local l = carried or M.list(log)
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
                -- Soulscourge (Dirty Water +20, damage over time at 100): only below the safety floor; above it the
                -- brain is told to purify / fetch a clean one (Luis/main 2026-10-26: clean first, dirty only to survive)
                if d and (tonumber(d.soulscourge) or 0) > 0 and not R.floor_hit then
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
                    local r = reflex_use(log, d.item, need[2], need[3], t, cfg)
                    if not r then return end
                    R.last[need[2]] = t
                    reflex_emit({ action = "use", kind = need[2], item = d.item, name = d.name, stat = need[3], ok = r.ok,
                                  via = r.via, reason = r.reason })
                    if not r.ok then strike(d.item, false) end
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
                local r = reflex_input(log, R.floor_hit, function() return M.press_interact(log) end)
                if r then reflex_emit({ action = "collect", item = tg.item, name = tg.name, ok = r.ok }) end
            end
        end
    end
end

-- Start (idempotent) / stop / status. opts override M.REFLEX_CFG fields.
function M.reflex_start(log, opts)
    for k, v in pairs(opts or {}) do M.REFLEX_CFG[k] = v end
    R.cfg = M.REFLEX_CFG
    reflex_release(true)
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
    reflex_release(true)
    if R.loop and CancelDelayedAction then pcall(CancelDelayedAction, R.loop) end
    R.loop = nil
    return { ok = true }
end

function M.reflex_status()
    return { running = R.loop ~= nil, last = R.last, bad = R.bad, pending = R.pending, err = R.err, cfg = R.cfg,
             warned = R.warned, floor_hit = R.floor_hit, floor_leaves = R.floor_leaves }
end

return M
