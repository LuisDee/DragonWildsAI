-- Puppet gear: dress and arm the puppet by writing PlayerEquipmentComponent replicated state.
-- Verified in game (DISCOVERIES "Route 1: puppet dressed and armed", 2026-10-25, Luis via GFN):
--   * wearables: eq.Current<Slot>Wearable = data; eq:OnRep_Current<Slot>Wearable(nil); ForceNetUpdate
--   * right hand: SpawnActor(held class) -> w.HeldEquipmentData = data -> K2_AttachToComponent(Mesh,
--     HeldRightSocketName, 2, 2, 1, false) -> eq.HeldEquipmentActorRight = w -> OnRep(nil) -> ForceNetUpdate
--     (verified with Luis's own held class BP_Mace_Skullsplitter_C).
-- UNVERIFIED here: the LEFT hand (same pattern, Left names); replacing a held actor (old one is
-- cleared then SetLifeSpan, as scripts/puppet_gear.lua disarm); resolving the weapon's own class
-- from the data asset's soft pointer HeldEquipmentActorClass; whether the generic BP_HeldEquipmentBase_C
-- renders a weapon's mesh; LoadAsset for data assets that are not loaded yet.
local U = require("body.util")

local M = {}

M.HELD_BASE = "/Game/Gameplay/Character/Player/Equipment/Held/BP_HeldEquipmentBase.BP_HeldEquipmentBase_C"
M.WEAR_SLOTS = { head = "Head", body = "Body", legs = "Legs", cape = "Cape" }
M.HANDS = { right = "Right", left = "Left" }
M.SLOT_ORDER = { "head", "body", "legs", "cape", "right", "left" }

local function find_asset(path)
    local o = U.try(StaticFindObject, path)
    if U.valid(o) then return o end
    -- UNVERIFIED: UE4SS LoadAsset (game thread only, may hitch). Only for assets not loaded yet.
    if type(LoadAsset) == "function" then
        pcall(LoadAsset, path)
        o = U.try(StaticFindObject, path)
        if U.valid(o) then return o end
    end
    return nil
end

-- "WearableEquipmentData /Game/...": UE4SS GetFullName starts with the class name.
local function class_word(o) return ((U.fullname(o) or ""):match("^(%S+)")) or "" end

-- Slot for an item: an explicit hand/slot arg wins; wearables infer head/body/legs/cape from the path.
-- Returns slot ("right", "body", ...) or nil, reason.
function M.slot_for(data, item_path, hand)
    local wearable = class_word(data):find("Wearable", 1, true) ~= nil
    hand = type(hand) == "string" and hand:lower() or nil
    if wearable then
        if hand and M.WEAR_SLOTS[hand] then return hand end
        local seg = item_path:match("/Equipment/(%a+)/")
        local s = seg and seg:lower()
        if s and M.WEAR_SLOTS[s] then return s end
        return nil, "cannot infer wearable slot (pass hand=head|body|legs|cape)"
    end
    if hand == nil then return "right" end
    if M.HANDS[hand] then return hand end
    return nil, "held items need hand=right|left"
end

-- Weapon category from a held data path, e.g. ".../Held/Mace/ITEM_Mace_Mithril..." -> "Mace".
function M.category(path)
    return path and path:match("/Held/(%a+)/") or nil
end

-- Resolve the held actor class to spawn: explicit path, the data asset's own class (soft pointer),
-- a real player's held class if it holds the same item, else the generic base.
local function soft_path(sp)
    if sp == nil then return nil end
    local s = U.str(sp)
    if s and s:find("/", 1, true) then return s end
    local ok, p = pcall(function()
        local a = sp.SoftObjectPtr.ObjectID.AssetPath
        return U.str(a.PackageName) .. "." .. U.str(a.AssetName)
    end)
    return ok and p or nil
end

local function held_class(data, item_path, opts)
    if opts.actor_class then
        local c = find_asset(opts.actor_class)
        if c then return c, "explicit" end
    end
    local sp = soft_path(U.try(function() return data.HeldEquipmentActorClass end))
    if sp then
        local c = U.try(StaticFindObject, sp)
        if U.valid(c) then return c, "data_asset" end
    end
    for _, pl in ipairs((U.split_pawns())) do
        for _, side in ipairs({ "Right", "Left" }) do
            local h = U.try(function() return pl.PlayerEquipmentComponent["GetHeldEquipmentActor" .. side](pl.PlayerEquipmentComponent) end)
            if U.valid(h) and U.fullname(U.try(function() return h.HeldEquipmentData end)) == U.fullname(data) then
                local c = U.try(function() return h:GetClass() end)
                if U.valid(c) then return c, "mirror_player" end
            end
        end
    end
    local base = U.try(StaticFindObject, M.HELD_BASE)
    if U.valid(base) then return base, "base" end
    return nil, nil
end

-- Current gear as {slot = data asset path}, read back from the replicated state.
function M.read(p)
    local out = {}
    local eq = U.try(function() return p.PlayerEquipmentComponent end)
    if not U.valid(eq) then return out end
    for slot, S in pairs(M.WEAR_SLOTS) do
        local n = U.fullname(U.try(function() return eq["Current" .. S .. "Wearable"] end))
        out[slot] = n and (n:match("^%S+%s+(.*)$") or n) or nil
    end
    for hand, H in pairs(M.HANDS) do
        local h = U.try(function() return eq["HeldEquipmentActor" .. H] end)
        local n = U.valid(h) and U.fullname(U.try(function() return h.HeldEquipmentData end)) or nil
        out[hand] = n and (n:match("^%S+%s+(.*)$") or n) or nil
    end
    return out
end

local function wear(log, p, eq, slot, data)
    local S = M.WEAR_SLOTS[slot]
    return U.call(log, "gear.wear", { slot = slot, item = U.fullname(data) }, function()
        eq["Current" .. S .. "Wearable"] = data
        eq["OnRep_Current" .. S .. "Wearable"](eq, nil)
        p:ForceNetUpdate()
    end)
end

local function hold(log, p, eq, hand, data, item_path, opts)
    local H = M.HANDS[hand]
    local cls, cls_from = held_class(data, item_path, opts)
    if not cls then return false, "no held actor class" end
    -- Clear the hand first (UNVERIFIED for replacement; mirrors scripts/puppet_gear.lua disarm).
    local old = U.try(function() return eq["HeldEquipmentActor" .. H] end)
    if U.valid(old) then
        U.call(log, "gear.clear_hand", { hand = hand, old = U.fullname(old) }, function()
            eq["HeldEquipmentActor" .. H] = nil
            eq["OnRep_HeldEquipmentActor" .. H](eq, old)
            old:SetLifeSpan(0.1) -- a held actor, not a possessed pawn: safe to destroy
        end)
    end
    local w
    local ok, err = U.call(log, "gear.spawn_held", { class = U.fullname(cls), from = cls_from }, function()
        w = p:GetWorld():SpawnActor(cls, p:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(w) then return false, "spawn failed: " .. tostring(err) end
    local socket = U.try(function() return eq["Held" .. H .. "SocketName"] end)
    ok, err = U.call(log, "gear.attach_held", { hand = hand, socket = U.str(socket) }, function()
        w.HeldEquipmentData = data
        w:K2_AttachToComponent(p.Mesh, socket, 2, 2, 1, false)
        eq["HeldEquipmentActor" .. H] = w
        eq["OnRep_HeldEquipmentActor" .. H](eq, nil)
        p:ForceNetUpdate()
        w:ForceNetUpdate()
    end)
    if not ok then
        pcall(function() w:SetLifeSpan(0.1) end)
        return false, tostring(err)
    end
    return true, U.fullname(cls), cls_from
end

-- Equip one item. opts: {hand=, actor_class=}. Returns {ok, reason, data}. Success is decided by
-- reading the slot back (principle 2), not by the calls returning.
function M.equip(log, p, item_path, opts)
    opts = opts or {}
    if type(item_path) ~= "string" or not item_path:find("^/") then
        return { ok = false, reason = "invalid_args", data = { detail = "item_path must be an object path" } }
    end
    local eq = U.try(function() return p.PlayerEquipmentComponent end)
    if not U.valid(eq) then return { ok = false, reason = "body_error", data = { detail = "no PlayerEquipmentComponent" } } end
    local data = find_asset(item_path)
    if not data then return { ok = false, reason = "unknown_target", data = { item_path = item_path, detail = "data asset not found" } } end
    local slot, why = M.slot_for(data, item_path, opts.hand)
    if not slot then return { ok = false, reason = "invalid_args", data = { item_path = item_path, detail = why } } end
    local res = { slot = slot, item_path = item_path }
    local ok, a, b
    if M.WEAR_SLOTS[slot] then
        ok, a = wear(log, p, eq, slot, data)
    else
        ok, a, b = hold(log, p, eq, slot, data, item_path, opts)
        res.actor_class, res.actor_class_from = ok and a or nil, ok and b or nil
    end
    if not ok then
        res.detail = tostring(a)
        return { ok = false, reason = "body_error", data = res }
    end
    local now = M.read(p)[slot]
    local want = (U.fullname(data) or ""):match("^%S+%s+(.*)$")
    if now == nil or now ~= want then
        res.detail, res.read_back = "slot did not take the item", now
        return { ok = false, reason = "verification_failed", data = res }
    end
    res.gear = M.read(p)
    return { ok = true, data = res }
end

return M
