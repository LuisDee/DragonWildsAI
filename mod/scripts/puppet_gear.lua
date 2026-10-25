-- Route 1, experiments E1/E2 (docs/research/2026-10-25-humanoid-companion-dump.md A.2, E1, E2):
-- dress and arm the server-driven puppet by writing the replicated equipment state on its pawn.
-- Run via debug_run {module="puppet_gear", args={action=...}} with Luis connected and a possessed
-- puppet alive (puppet_test spawn + possess). Never unpossess/destroy the puppet (deadlocks, see DISCOVERIES).
--   mirror          : read-only: Luis's appearance handles, wearables, held actor (class/data/socket)
--   dress           : copy Luis's appearance; wear Luis's armour (or iron body armour if he wears none)
--   arm  {weapon=}  : spawn a held actor for a weapon data asset and attach it to the puppet's right hand
--   disarm          : drop the puppet's held actor (SetLifeSpan; it is not a possessed pawn)
local M = {}

local WEAPONS = {
    sword = "/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril",
    greatsword = "/Game/Gameplay/Character/Player/Equipment/Held/GreatSword/ITEM_GreatSword_Iron.ITEM_GreatSword_Iron",
    bow = "/Game/Gameplay/Character/Player/Equipment/Held/Bow/ITEM_Shortbow_Oak.ITEM_Shortbow_Oak",
    axe = "/Game/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Iron.ITEM_Logging_Axe_Iron",
}
local IRON_BODY = "/Game/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_T4_Body_Iron.ITEM_Armour_T4_Body_Iron"
local HELD_BASE = "/Game/Gameplay/Character/Player/Equipment/Held/BP_HeldEquipmentBase.BP_HeldEquipmentBase_C"
local SLOTS = { "Head", "Body", "Legs", "Cape" }
local LOOK_KEYS = { "BodyTypeDataHandle", "FaceDataHandle", "HairPresetDataHandle", "FacialHairPresetDataHandle",
                    "HairColorPrimitiveDataHandle", "SkinTonePrimitiveDataHandle", "EyeColorPrimitiveDataHandle",
                    "EyebrowColorPrimitiveDataHandle" }

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function fullname(o) return valid(o) and try(function() return o:GetFullName() end) or nil end
local function str(v) return v and try(function() return v:ToString() end) or nil end

local function pawns()
    local players, puppets = {}, {}
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        -- Skip destroyed actors awaiting GC: UE4SS IsValid() is still true for them; only the
        -- internal Garbage|Unreachable flags tell them apart (see puppet_safe.lua).
        if valid(p) and try(function() return p:HasAnyInternalFlags(0x10200000) end) ~= true then
            local c = try(function() return p:GetController() end)
            local is_player = (fullname(c) or ""):find("PlayerController", 1, true) ~= nil
            table.insert(is_player and players or puppets, p)
        end
    end
    return players[1], puppets[1]
end

local function gear(p)
    local eq = try(function() return p.PlayerEquipmentComponent end)
    local out = { equipment_component = fullname(eq) }
    if not eq then return out end
    for _, s in ipairs(SLOTS) do out[s] = fullname(try(function() return eq["Current" .. s .. "Wearable"] end)) end
    local h = try(function() return eq:GetHeldEquipmentActorRight() end)
    local root = valid(h) and try(function() return h.RootComponent end)
    out.held_right = valid(h) and {
        actor = fullname(h), class = fullname(try(function() return h:GetClass() end)),
        data = fullname(try(function() return h.HeldEquipmentData end)),
        item = fullname(try(function() return h.HeldEquipmentItem end)),
        id = try(function() return h.HeldEquipmentActorID end),
        parent = fullname(root and try(function() return root:GetAttachParent() end)),
        socket = str(root and try(function() return root:GetAttachSocketName() end)),
    } or nil
    out.right_socket = str(try(function() return eq.HeldRightSocketName end))
    return out
end

local actions = {}

function actions.mirror()
    local luis, puppet = pawns()
    if not luis then return { ok = false, error = "no connected player" } end
    local look = {}
    local cd = try(function() return luis.PlayerCustomizationComponent.CustomizationSaveData end)
    for _, k in ipairs(LOOK_KEYS) do look[k] = cd and str(try(function() return cd[k].RowName end)) end
    return { luis = gear(luis), luis_look = look, puppet = puppet and gear(puppet) or nil }
end

function actions.dress(log)
    local luis, p = pawns()
    if not (luis and p) then return { ok = false, error = "need Luis and a puppet" } end
    local r = {}
    -- Appearance: copy the data-table row handles; fall back to whole-struct assignment.
    r.look_ok, r.look_err = pcall(function()
        local src = luis.PlayerCustomizationComponent.CustomizationSaveData
        local dst = p.PlayerCustomizationComponent.CustomizationSaveData
        for _, k in ipairs(LOOK_KEYS) do dst[k].DataTable = src[k].DataTable; dst[k].RowName = src[k].RowName end
    end)
    if not r.look_ok then
        r.look_struct_ok = pcall(function()
            p.PlayerCustomizationComponent.CustomizationSaveData = luis.PlayerCustomizationComponent.CustomizationSaveData
        end)
    end
    r.look_rep_ok = pcall(function() p.PlayerCustomizationComponent:OnRep_PlayerCustomization() end)
    -- Armour: Luis's wearables where he has them; iron body otherwise.
    local eq, leq = p.PlayerEquipmentComponent, luis.PlayerEquipmentComponent
    r.slots = {}
    for _, s in ipairs(SLOTS) do
        local item = try(function() return leq["Current" .. s .. "Wearable"] end)
        if not valid(item) and s == "Body" then item = StaticFindObject(IRON_BODY) end
        if valid(item) then
            local ok, err = pcall(function()
                eq["Current" .. s .. "Wearable"] = item
                eq["OnRep_Current" .. s .. "Wearable"](eq, nil)
            end)
            r.slots[s] = { item = fullname(item), ok = ok, err = (not ok) and tostring(err) or nil }
        end
    end
    pcall(function() p:ForceNetUpdate() end)
    r.look_err = r.look_err and tostring(r.look_err)
    r.after = gear(p)
    log.event("puppet_dress", r)
    return r
end

function actions.arm(log, args)
    local luis, p = pawns()
    if not p then return { ok = false, error = "no puppet" } end
    local data = StaticFindObject(WEAPONS[args.weapon or "sword"] or args.weapon)
    if not valid(data) then return { ok = false, error = "weapon data not loaded", weapon = args.weapon } end
    local eq = p.PlayerEquipmentComponent
    -- Mirror Luis's real held actor class and socket when he holds something; generic base otherwise.
    local lh = luis and try(function() return luis.PlayerEquipmentComponent:GetHeldEquipmentActorRight() end)
    local cls = (valid(lh) and try(function() return lh:GetClass() end)) or StaticFindObject(HELD_BASE)
    local socket = try(function() return eq.HeldRightSocketName end)
    local r = { weapon = fullname(data), class = fullname(cls) }
    local w
    r.spawn_ok, r.spawn_err = pcall(function()
        w = p:GetWorld():SpawnActor(cls, p:K2_GetActorLocation(), { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not valid(w) then r.spawn_err = tostring(r.spawn_err); log.event("puppet_arm", r); return r end
    r.data_ok = pcall(function() w.HeldEquipmentData = data end)
    r.attach_ok, r.attach_err = pcall(function() w:K2_AttachToComponent(p.Mesh, socket, 2, 2, 1, false) end)
    r.slot_ok, r.slot_err = pcall(function()
        eq.HeldEquipmentActorRight = w
        eq:OnRep_HeldEquipmentActorRight(nil)
    end)
    pcall(function() p:ForceNetUpdate(); w:ForceNetUpdate() end)
    r.attach_err, r.slot_err = r.attach_err and tostring(r.attach_err), r.slot_err and tostring(r.slot_err)
    r.after = gear(p)
    log.event("puppet_arm", r)
    return r
end

function actions.disarm(log)
    local _, p = pawns()
    if not p then return { ok = false, error = "no puppet" } end
    local eq = p.PlayerEquipmentComponent
    local h = try(function() return eq.HeldEquipmentActorRight end)
    local ok = pcall(function()
        eq.HeldEquipmentActorRight = nil
        eq:OnRep_HeldEquipmentActorRight(h)
        if valid(h) then h:SetLifeSpan(0.1) end
    end)
    log.event("puppet_disarm", { ok = ok, held = fullname(h) })
    return { ok = ok }
end

function M.run(log, args)
    local a = actions[args.action or "mirror"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
