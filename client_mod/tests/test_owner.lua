-- Offline tests for whose a container is (client_mod/scripts/sense.lua owner_row, skills.lua W.owner_fields):
-- the game's UOwnershipComponent.OwningCharacterGuid on a crate or chest, told to him in look/inspect rows and in
-- store/take results. Run 20261118-015315-N1-I2: he stored into BP_BaseBuilding_Crate_C_2147472971 with no way to
-- tell whose it was (look listed seven crates and an Ash Chest, no owner); the world save holds ClaudeDev's guid
-- on every one of them.
--   lua client_mod/tests/test_owner.lua
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
local function guid(a, b, c, d) return { A = a, B = b, C = c, D = d } end
local FORK = guid(0x11111111, 0x22222222, 0x33333333, 0x44444444)
local DEV = guid(0xE71C5DC1, 0x46F0A55B, 0x69FF52A8, 0x81255DEF)
local LUIS = guid(0xB0E56055, 0x497E9F8C, 0xA6003C95, 0x5B47A47F)

local W = { my_guid = FORK, names = {} }
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1", {
    IsLocalController = function() return true end,
    PlayerState = { OwnerGuid = { CharacterGuid = { InnerGuid = FORK } } } })
local function names_array()
    return { ForEach = function(_, fn)
        for _, e in ipairs(W.names) do fn(nil, { get = function() return e end }) end
    end }
end
local dn = uobj("DisplayNameComponent /Game/L.L:PersistentLevel.GameState.DisplayNameComponent", {})
function FindAllOf(cls)
    if cls == "BP_PlayerController_C" then return { pc } end
    if cls == "DisplayNameComponent" then dn.SanitizedCharacterNames = names_array(); return { dn } end
    return {}
end

local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()

local function crate(owner_guid, private)
    return uobj("BP_BaseBuilding_Crate_C /Game/L.L:PersistentLevel.BP_BaseBuilding_Crate_C_2147472971", {
        OwnershipComponent = uobj("OwnershipComponent /Game/L.L:PersistentLevel.BP_BaseBuilding_Crate_C_2147472971.OwnershipComponent",
            { OwningCharacterGuid = { InnerGuid = owner_guid }, bIsPrivatelyOwned = private == true }) })
end

-- ---------------------------------------------------------------- the game's owner, read
W.names = { { CharacterGuid = { InnerGuid = DEV }, CharacterName = ftext("ClaudeDev") },
            { CharacterGuid = { InnerGuid = LUIS }, CharacterName = ftext("luisdeburnaybast") } }
local d = {}
S.owner_row(crate(DEV), d)
check("a crate ClaudeDev placed reads as his, by name", d.owner == "ClaudeDev" and d.mine == false
    and d.owner_guid == "E71C5DC146F0A55B69FF52A881255DEF" and d.private == nil, d.owner)

d = {}
S.owner_row(crate(FORK), d)
check("his own crate reads yours", d.owner == "yours" and d.mine == true, d.owner)

d = {}
S.owner_row(crate(LUIS, true), d)
check("Luis's private chest reads his name and private", d.owner == "luisdeburnaybast" and d.mine == false and d.private == true, d.owner)

d = {}
S.owner_row(crate(guid(0, 0, 0, 0)), d)
check("an unowned crate reads nobody", d.owner == "nobody" and d.mine == false and d.owner_guid == nil, d.owner)

d = {}
S.owner_row(crate(guid(0xAAAAAAAA, 1, 2, 3)), d)
check("an owner missing from the name list is said so, with the guid", d.owner == "a character not in the name list"
    and d.owner_guid == "AAAAAAAA000000010000000200000003" and d.mine == false, d.owner)

d = {}
S.owner_row(uobj("BP_Station_Campfire_C /Game/L.L:PersistentLevel.BP_Station_Campfire_C_1", {}), d)
check("no ownership component: nothing added (never a guess)", next(d) == nil)

d = {}
local broken = crate(DEV)
broken.OwnershipComponent.OwningCharacterGuid = nil
S.owner_row(broken, d)
check("an unreadable guid adds nothing", next(d) == nil)

-- his own guid unread: the name still reads, mine stays unknown (nil), never false
local saved = pc.PlayerState
pc.PlayerState = nil
d = {}
S.owner_row(crate(DEV), d)
check("his guid unread: owner named, mine unknown", d.owner == "ClaudeDev" and d.mine == nil)
pc.PlayerState = saved

-- ---------------------------------------------------------------- told back in store / take results
local SK = assert(loadfile(root .. "/client_mod/scripts/skills.lua"))()
local row = { id = "BP_BaseBuilding_Crate_C_2147472971", owner = "ClaudeDev", owner_guid = "E71C5DC146F0A55B69FF52A881255DEF", mine = false }
local data = SK.W.owner_fields(row, { container = row.id, count = 20 })
check("a store result carries the crate's owner", data.owner == "ClaudeDev" and data.mine == false and data.owner_guid == row.owner_guid)
data = SK.W.owner_fields({ id = "x" }, { container = "x" })
check("a row without an owner read adds nothing", data.owner == nil and data.mine == nil)
data = SK.W.owner_fields(row, { owner = "set by the result" })
check("never over the result's own field", data.owner == "set by the result")

print(string.format("owner: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
