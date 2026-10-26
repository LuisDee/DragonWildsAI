-- Offline tests for equip verification: inventory.equip_state (the game's read-back: held with the
-- item's own held-actor class, or worn) and skills.lua's equip / unequip waiters built on it.
-- Run: lua client_mod/tests/test_equip.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

-- ---------------------------------------------------------------- fake engine (just what equip_state reads)
local function obj(t, full) t.IsValid = function() return true end; t.GetFullName = function() return full end; return t end
local function cls(path) return obj({}, "BlueprintGeneratedClass " .. path) end
local function soft(path) return { GetObjectID = function() return { GetAssetPathName = function() return path end } end } end
local AXE_CLASS = "/Game/Held/Hatchet/BP_Logging_Axe_Mithril.BP_Logging_Axe_Mithril_C"
local SHIELD_CLASS = "/Game/Held/Shield/BP_Shield_Bronze.BP_Shield_Bronze_C"
local axe_data = obj({ Name = "Mithril Logging Axe", HeldEquipmentActorClass = soft(AXE_CLASS) }, "HeldEquipmentData /Game/Held/ITEM_Logging_Axe_Mithril.ITEM_Logging_Axe_Mithril")
local shield_data = obj({ Name = "Bronze Shield", HeldEquipmentActorClass = soft(SHIELD_CLASS) }, "HeldEquipmentData /Game/Held/ITEM_Shield_Bronze.ITEM_Shield_Bronze")
local eq = obj({}, "PlayerEquipmentComponent /x")
local held = { right = nil, left = nil, actor_right = nil, actor_left = nil }
function eq:GetHeldEquipmentDataRight() return held.right end
function eq:GetHeldEquipmentDataLeft() return held.left end
setmetatable(eq, { __index = function(_, k)
    if k == "HeldEquipmentActorRight" then return held.actor_right end
    if k == "HeldEquipmentActorLeft" then return held.actor_left end
end })
local function actor(class_path, name)
    local a = obj({}, "BlueprintGeneratedClass_inst /Game/L.L:PersistentLevel." .. name)
    a.GetClass = function() return { GetFullName = function() return "BlueprintGeneratedClass " .. class_path end } end
    return a
end
local pawn = obj({ PlayerEquipmentComponent = eq }, "BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_1")
pawn.HasAnyInternalFlags = function() return false end
local pc = obj({ Pawn = pawn, IsLocalController = function() return true end }, "BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1")
function FindAllOf(c) if c == "BP_PlayerController_C" then return { pc } end return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end

local I = assert(loadfile(root .. "/client_mod/scripts/inventory.lua"))()

-- ---------------------------------------------------------------- 1. equip_state
local function list(t)
    return { ok = true, hotbar = t.hotbar or {}, bag = {}, loadout = t.loadout or {}, held = t.held or {} }
end
do
    -- a two-handed axe: the game reports it in the LEFT hand only (live, DISCOVERIES R2)
    held.left, held.actor_left = axe_data, actor(AXE_CLASS, "BP_Logging_Axe_Mithril_C_7")
    local s = I.equip_state(nil, "ITEM_Logging_Axe_Mithril", list({
        loadout = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", loadout_slot = "HeldLeft", slot = 8 } },
        held = { left_item = "ITEM_Logging_Axe_Mithril", left = "Mithril Logging Axe" } }))
    check("2H axe: held left, actor class matches the item's", s.equipped and s.held == "left" and s.actor_matches == true, s.actor_class)
    -- the data is set but the actor has not spawned yet (a swap in progress)
    held.actor_left = nil
    local s2 = I.equip_state(nil, "ITEM_Logging_Axe_Mithril", list({ held = { left_item = "ITEM_Logging_Axe_Mithril" } }))
    check("swap in progress: no held actor yet -> not equipped", not s2.equipped and s2.held == "left" and s2.actor == nil)
    -- a wrong actor (the previous tool still in the hand)
    held.actor_left = actor(SHIELD_CLASS, "BP_Shield_Bronze_C_3")
    local s3 = I.equip_state(nil, "ITEM_Logging_Axe_Mithril", list({ held = { left_item = "ITEM_Logging_Axe_Mithril" } }))
    check("wrong held actor -> not equipped", not s3.equipped and s3.actor_matches == false, s3.actor_class)
    -- a shield in the left hand with a one-handed weapon right
    held.left, held.actor_left = shield_data, actor(SHIELD_CLASS, "BP_Shield_Bronze_C_4")
    local s4 = I.equip_state(nil, "ITEM_Shield_Bronze", list({ held = { left_item = "ITEM_Shield_Bronze", right_item = "ITEM_Dagger_Bone" } }))
    check("shield: held left with its own actor class", s4.equipped and s4.held == "left" and s4.actor_matches)
    -- armour: in the Body loadout slot and worn
    local s5 = I.equip_state(nil, "ITEM_Armour_T3_Body_Bronze", list({
        loadout = { { item = "ITEM_Armour_T3_Body_Bronze", name = "Bronze Platebody", loadout_slot = "Body", slot = 1 } },
        held = { worn = { body = "Bronze Platebody" } } }))
    check("armour: in the Body slot and worn", s5.equipped and s5.worn and s5.loadout_slot == "Body")
    local s6 = I.equip_state(nil, "ITEM_Armour_T3_Body_Bronze", list({
        loadout = { { item = "ITEM_Armour_T3_Body_Bronze", name = "Bronze Platebody", loadout_slot = "Body", slot = 1 } },
        held = { worn = { body = "Adventurer's Tunic" } } }))
    check("armour: in the slot but not worn (yet) -> not equipped", not s6.equipped)
    local s7 = I.equip_state(nil, "ITEM_Torch", list({ hotbar = { { item = "ITEM_Torch", slot = 6 } } }))
    check("only carried -> not equipped", not s7.equipped and s7.held == nil and s7.loadout_slot == nil)
    check("unreadable list is reported", I.equip_state(nil, "x", { ok = false }).unreadable)
end

-- ---------------------------------------------------------------- 2. skills equip / unequip waiters
local SK = assert(loadfile(root .. "/client_mod/scripts/skills.lua"))()
local state = { list = nil, equip_calls = 0, unequip_calls = 0, after_equip = nil, after_unequip = nil }
local api = {
    call = function(modname, fn, ...)
        if fn == "list" then return { ok = true, data = state.list } end
        if fn == "equip" then state.equip_calls = state.equip_calls + 1; if state.after_equip then state.after_equip() end; return { ok = true, data = {} } end
        if fn == "unequip" then state.unequip_calls = state.unequip_calls + 1; if state.after_unequip then state.after_unequip() end; return { ok = true, data = {} } end
        if fn == "equip_state" then return { ok = true, data = I.equip_state(nil, (...), state.list) } end
        return { ok = false, reason = "not_implemented", data = {} }
    end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
    match_score = function(t, what) return ((t.name or ""):lower():find(what:lower(), 1, true)) and 1 or 0 end,
}
local ctx = { api = api }
do
    -- equip the axe from the hotbar: the game shows it only once the held actor spawned
    held.left, held.actor_left = nil, nil
    state.list = list({ hotbar = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", slot = 3 } } })
    state.after_equip = function()
        held.left = axe_data -- data first...
        state.list = list({ hotbar = state.list.hotbar, held = { left_item = "ITEM_Logging_Axe_Mithril", left = "Mithril Logging Axe" },
                            loadout = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", loadout_slot = "HeldLeft", slot = 8 } } })
    end
    local r = SK.HANDLERS.equip(nil, { item = "Mithril Logging Axe" }, ctx)
    check("equip: a waiter", r.wait and r.wait.poll)
    check("equip: not answered before the held actor exists", r.wait.poll() == nil)
    held.actor_left = actor(AXE_CLASS, "BP_Logging_Axe_Mithril_C_9") -- ...then the actor
    local ok = r.wait.poll()
    check("equip: verified (held left, its own actor class)", ok and ok.ok and ok.data.held == "left" and ok.data.actor_class == "BP_Logging_Axe_Mithril_C",
          ok and ok.data.actor_class)
    -- a wrong actor stays -> expire names why
    held.actor_left = actor(SHIELD_CLASS, "BP_Shield_Bronze_C_5")
    state.list = list({ hotbar = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", slot = 3 } } })
    held.left = nil
    local r2 = SK.HANDLERS.equip(nil, { item = "Mithril Logging Axe" }, ctx)
    state.after_equip = nil
    held.left = axe_data
    state.list = list({ hotbar = state.list.hotbar, held = { left_item = "ITEM_Logging_Axe_Mithril" } })
    check("equip: wrong actor never verifies", r2.wait.poll() == nil)
    local ex = r2.wait.expire()
    check("equip: expire says why (wrong_held_actor)", ex.reason == "verification_failed" and ex.data.why == "wrong_held_actor", ex.data.why)
    check("equip: unknown item -> not_in_inventory", SK.HANDLERS.equip(nil, { item = "Dragon Sword" }, ctx).reason == "not_in_inventory")
    -- unequip: verified once neither held nor in the loadout
    held.actor_left = actor(AXE_CLASS, "BP_Logging_Axe_Mithril_C_9")
    state.list = list({ hotbar = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", slot = 3 } },
                        held = { left_item = "ITEM_Logging_Axe_Mithril" },
                        loadout = { { item = "ITEM_Logging_Axe_Mithril", name = "Mithril Logging Axe", loadout_slot = "HeldLeft", slot = 8 } } })
    state.after_unequip = function()
        held.left, held.actor_left = nil, nil
        state.list = list({ hotbar = state.list.hotbar })
    end
    local u = SK.HANDLERS.unequip(nil, { item = "ITEM_Logging_Axe_Mithril" }, ctx)
    local uok = u.wait and u.wait.poll()
    check("unequip: verified off (no longer held, not in the loadout)", uok and uok.ok and state.unequip_calls == 1, uok and uok.reason)
    check("unequip: nothing equipped -> already", SK.HANDLERS.unequip(nil, { item = "ITEM_Torch" }, ctx).data.already == true)
    check("unequip: needs item or slot", SK.HANDLERS.unequip(nil, {}, ctx).reason == "invalid_args")
    local by = SK.MANIFEST
    check("manifest: equip and unequip offered to the model", by.equip.llm == true and by.unequip.llm == true and #by.equip.description <= 360)
end

print(string.format("equip tests: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
