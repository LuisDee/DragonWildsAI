-- Offline tests for stable foliage ids (BUGS L26): client_mod/scripts/sense.lua M.foliage_id /
-- parse_foliage_id / resolve_foliage over fake InteractableFoliageISMComponents (real sense.lua).
-- The live failure: a tree seen at 23 m was walked to; the server converted the instance into an actor
-- (NearbyFoliageConverterComponent, 3 m) and hid it, and the old "fol:<component>:<index>" id then named
-- nothing. Also covered: ISM swap-remove re-indexing, World Partition re-streaming (a new component,
-- another name), and same-class-only matching.
--   lua client_mod/tests/test_foliage_ids.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

function StaticFindObject() return nil end
function FindFirstOf() return nil end

local function uobj(full, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    return t
end
local function ftext(s) return { ToString = function() return s end } end
local ash_cdo = uobj("BP_BM_Tree_Ash_03_C /Game/Default__BP_BM_Tree_Ash_03_C", { DisplayName = ftext("Ash Tree"), HealthComponent = { MaxHealth = 160 } })
local ash_cls = uobj("BlueprintGeneratedClass /Game/Trees/BP_BM_Tree_Ash_03.BP_BM_Tree_Ash_03_C", { GetCDO = function() return ash_cdo end })
local oak_cls = uobj("BlueprintGeneratedClass /Game/Trees/BP_BM_Tree_Oak_01.BP_BM_Tree_Oak_01_C", { GetCDO = function() return nil end })

local function inst(x, y, z, s) return { Transform = { WPlane = { X = x, Y = y, Z = z }, XPlane = { X = s or 1, Y = 0, Z = 0 } } } end
-- A component whose instance list is a plain Lua array (1-based, like UE4SS TArray reads) and whose
-- overlap query is a real sphere test, returning 0-based indices like the engine.
local function comp(name, cls, at, instances)
    local c
    c = uobj("BP_InteractableFoliageISMC_Tree_C /Game/L.L:PersistentLevel." .. name, {
        ActorClass = cls, bDamageable = true, bInteractable = false, PerInstanceSMData = instances,
        K2_GetComponentLocation = function() return { X = at.X, Y = at.Y, Z = at.Z } end,
        K2_GetComponentRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end,
        K2_GetComponentScale = function() return { X = 1, Y = 1, Z = 1 } end,
        GetInstancesOverlappingSphere = function(_, center, r)
            local out = {}
            for i, e in ipairs(c.PerInstanceSMData) do
                local p = e.Transform.WPlane
                local wx, wy, wz = at.X + p.X, at.Y + p.Y, at.Z + p.Z
                if math.sqrt((wx - center.X) ^ 2 + (wy - center.Y) ^ 2 + (wz - center.Z) ^ 2) <= r then
                    local idx = i - 1
                    out[#out + 1] = { get = function() return idx end }
                end
            end
            return out
        end })
    return c
end

-- the world: Claude, one PC, foliage components and converted actors
local W = { me = { X = 0, Y = 0, Z = 0 }, comps = {}, actors = {} }
local pawn = uobj("BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_1", {
    K2_GetActorLocation = function() return { X = W.me.X, Y = W.me.Y, Z = W.me.Z } end })
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1", {
    IsLocalController = function() return true end, Pawn = pawn })
function FindAllOf(cls)
    if cls == "BP_PlayerController_C" then return { pc } end
    if cls == "InteractableFoliageISMComponent" then return W.comps end
    local out = {}
    for _, a in ipairs(W.actors) do if a.cls == cls then out[#out + 1] = a end end
    return out
end
local function actor(cls, id, pos)
    local a = uobj(cls .. " /Game/L.L:PersistentLevel." .. id, { cls = cls,
        K2_GetActorLocation = function() return { X = pos.X, Y = pos.Y, Z = pos.Z } end,
        DisplayName = ftext("Ash Tree"), HealthComponent = { Health = 160, MaxHealth = 160 } })
    W.actors[#W.actors + 1] = a
    return a
end

local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()

-- ---------------------------------------------------------------- 1. the id: class + where it stands
local ORIGIN = { X = 10000, Y = 180000, Z = -3000 }
local function reset()
    W.actors = {}
    W.comps = { comp("BP_InteractableFoliageISMC_Tree_C_12", ash_cls, ORIGIN,
        { inst(840, 14948, -130), inst(3000, 0, 0), inst(-500, 200, 10) }) }
    W.me = { X = 10000 + 840 - 2250, Y = 180000 + 14948, Z = -3000 } -- 22.5 m west of the first tree (the live case)
end
reset()
local rows = S.foliage(W.me, 4000, { kinds = { tree = true } })
local tree
for _, r in ipairs(rows) do if r._index == 0 then tree = r end end
check("id = class + decimetre position", tree and tree.id == "fol:BP_BM_Tree_Ash_03_C@1084,19495,-313", tree and tree.id)
local k = S.parse_foliage_id(tree and tree.id)
check("parse: class and cm position", k and k.class == "BP_BM_Tree_Ash_03_C" and k.pos.X == 10840 and k.pos.Y == 194950 and k.pos.Z == -3130,
    k and (k.class .. " " .. k.pos.X .. "," .. k.pos.Y .. "," .. k.pos.Z))
check("parse: negative coordinates", (S.parse_foliage_id("fol:X_C@-12,-3,-4") or {}).pos.X == -120)
check("parse: an old component:index id is legacy", (S.parse_foliage_id("fol:BP_InteractableFoliageISMC_Tree_C_12:59") or {}).legacy ~= nil)
check("parse: not a foliage id", S.parse_foliage_id("BP_AI_Wolf_C_1") == nil and S.parse_foliage_id("fol:junk") == nil)
local ID = tree and tree.id

-- ---------------------------------------------------------------- 2. resolving
local r, how = S.resolve_foliage(ID)
check("same instance: same", r and how == "same" and r.id == ID and math.abs((r.distance or 0) - 22.5) < 0.11, tostring(how) .. " " .. tostring(r and r.distance))

-- ISM swap-remove: the instance at index 0 is removed and the last one takes its slot -> our tree moved index
reset()
local legacy_before = "fol:BP_InteractableFoliageISMC_Tree_C_12:0"
W.comps[1].PerInstanceSMData = { inst(-500, 200, 10), inst(3000, 0, 0), inst(840, 14948, -130) } -- our tree: index 0 -> 2
r, how = S.resolve_foliage(ID)
check("re-indexed (swap-remove): still the same tree", r and r.id == ID and r._index == 2, r and r._index)
local lr = S.resolve_foliage(legacy_before)
check("the old index-based id now names a DIFFERENT instance (why ids moved)", lr == nil or lr._pos.X ~= 10840, lr and lr.id)

-- World Partition re-streaming: the cell's component comes back as a new object with another name and
-- its location rounded differently (6 cm off): the nearest same-class instance within 1 m is the tree
reset()
W.comps = { comp("BP_InteractableFoliageISMC_Tree_C_3", ash_cls, { X = ORIGIN.X + 6, Y = ORIGIN.Y, Z = ORIGIN.Z },
    { inst(3000, 0, 0), inst(840, 14948, -130) }) }
r, how = S.resolve_foliage(ID)
check("re-streamed component (new name, 6 cm off): reindexed, new id handed back", r and how == "reindexed" and r.id ~= ID and r.class == "BP_BM_Tree_Ash_03_C",
    tostring(how) .. " " .. tostring(r and r.id))

-- same class only: an oak standing on the same spot is not our ash
reset()
W.comps = { comp("BP_InteractableFoliageISMC_Tree_C_12", oak_cls, ORIGIN, { inst(840, 14948, -130) }) }
r, how = S.resolve_foliage(ID)
check("another class on the spot is not the tree", r == nil and how == "not_found", tostring(how))

-- too far off: the nearest ash is 1.5 m away -> not ours
reset()
W.comps = { comp("BP_InteractableFoliageISMC_Tree_C_12", ash_cls, ORIGIN, { inst(840 + 150, 14948, -130) }) }
r, how = S.resolve_foliage(ID)
check("a same-class instance 1.5 m off is another tree", r == nil and how == "not_found", tostring(how))

-- ---------------------------------------------------------------- 3. converted (the live L26 case)
-- he walked up to it (1.4 m); the server spawned the tree actor where it stood and hid the instance
reset()
W.comps[1].PerInstanceSMData[1] = inst(840, 14948, -130, 0.0)
W.me = { X = 10840 - 140, Y = 194948, Z = -3000 }
actor("BP_BM_Tree_Ash_03_C", "BP_BM_Tree_Ash_03_C_2147454756", { X = 10840 + 40, Y = 194948 - 30, Z = -3130 })
actor("BP_BM_Tree_Ash_03_C", "BP_BM_Tree_Ash_03_C_2147450000", { X = 10840 + 900, Y = 194948, Z = -3130 }) -- a different ash
r, how = S.resolve_foliage(ID)
check("converted: the actor it became", r and how == "converted" and r.id == "BP_BM_Tree_Ash_03_C_2147454756" and r.converted_from == ID,
    tostring(how) .. " " .. tostring(r and r.id))
check("converted: a census resource row (kind, distance from me)", r and r.kind == "destructible" and r.distance and r.distance < 2.5,
    r and (tostring(r.kind) .. " " .. tostring(r.distance)))

-- felled / picked: the instance is hidden and no actor stands there
reset()
W.comps[1].PerInstanceSMData[1] = inst(840, 14948, -130, 0.0)
r, how = S.resolve_foliage(ID)
check("hidden and no actor: felled_or_picked", r == nil and how == "felled_or_picked", tostring(how))

-- not streamed in / nothing there at all
reset()
W.comps = {}
r, how = S.resolve_foliage(ID)
check("nothing there: not_found", r == nil and how == "not_found", tostring(how))

-- legacy ids handed out before the change still resolve while the instance keeps its index
reset()
r, how = S.resolve_foliage("fol:BP_InteractableFoliageISMC_Tree_C_12:0")
check("legacy id: exact component:index around me", r and how == "legacy" and r.id == ID, tostring(how) .. " " .. tostring(r and r.id))
check("not a foliage id", select(2, S.resolve_foliage("wolf_1")) == "not_a_foliage_id")

-- census rows never carry the internal fields
reset()
local cen = S.census(nil, { radius_m = 40 })
local fol
for _, x in ipairs((cen and cen.resources) or {}) do if x.kind == "foliage" then fol = x end end
check("census: foliage rows with stable ids, no internals", fol and fol.id:match("^fol:BP_BM_Tree_Ash_03_C@") and fol._legacy == nil and fol._comp == nil,
    fol and fol.id)

-- interactables: the interaction point is used only when it sits on the actor (live 09:25: an NPC's read (0,0,0))
do
    local npc = uobj("BP_NPC_WiseOldMan_FTUE_C /Game/L.L:PersistentLevel.BP_NPC_WiseOldMan_FTUE_C_1", {
        K2_GetActorLocation = function() return { X = 6130, Y = 187360, Z = -3550 } end })
    local ic0 = uobj("InteractionComponent /Game/L.L:PersistentLevel.NPC.IC", { K2_GetComponentLocation = function() return { X = 0, Y = 0, Z = 0 } end })
    local d = S._describe_interactable(npc, ic0, "npc", { X = 6270, Y = 188150, Z = -3550 })
    check("NPC with an interaction point at the origin: actor position kept", d.position[2] > 1800 and d.distance < 20, d.distance)
    local tent = uobj("BP_Shelter_C /Game/L.L:PersistentLevel.BP_Shelter_C_1", { K2_GetActorLocation = function() return { X = 2000, Y = 2000, Z = 300 } end })
    local ic1 = uobj("BoxComponent /Game/L.L:PersistentLevel.Shelter.IC", { K2_GetComponentLocation = function() return { X = 2160, Y = 2000, Z = 300 } end })
    d = S._describe_interactable(tent, ic1, "resting_area", nil)
    check("a real interaction point near the actor is used", math.abs(d.position[1] - 21.6) < 0.01 and d.actor_position)
end

-- perks: active skill perks by property reads (cached)
do
    local function ft(s) return { ToString = function() return s end } end
    local agility = uobj("SkillData /Game/Skills/SD_Agility.SD_Agility", { Name = ft("Agility") })
    local function perk(id, name, lvl) return uobj("SkillPerkData /Game/Perks/" .. id .. "." .. id,
        { PerkName = ft(name), PerkDescription = ft(name .. " desc"), PerkUnlockInfo = { AssociatedSkill = agility, RequiredSkillLevel = lvl } }) end
    local function arr(t) return { ForEach = function(_, f) for i, v in ipairs(t) do f(i, { get = function() return v end }) end end } end
    local p1, p2 = perk("PERK_Windstep", "Windstep", 5), perk("PERK_Sprint", "Second Wind", 1)
    pc.SkillPerkComponent = uobj("SkillPerkComponent /Game/L.L:PersistentLevel.PC.SkillPerkComponent", {
        SkillPerkRuntimeStates = arr({ { AssociatedSkill = agility, ActivePerkDatas = arr({ p1, p2, p1 }) } }) })
    S._reset_perks()
    local pk = S.perks(1000)
    check("perks: deduplicated, sorted by skill then level, with name/skill/level", pk and #pk == 2 and pk[1].name == "Second Wind"
        and pk[2].name == "Windstep" and pk[2].skill == "Agility" and pk[2].level == 5, pk and #pk)
    pc.SkillPerkComponent = nil
    check("perks: cached within the TTL", #S.perks(1010) == 2)
    S._reset_perks()
end

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
