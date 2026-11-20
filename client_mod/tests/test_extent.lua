-- Offline tests for things with an extent (client_mod/scripts/sense.lua M.box_nearest / M.extent_of and the census):
-- a pond is as far off as its nearest point, not its middle.
-- The live failure (window s16, 2026-11-17, runs 031503 and 033022): thirsty beside Zanik, he looked for water (80 m)
-- and explored for it six times (40 m of sight) and was told there was none; the pond's middle was 84.7 m off and its
-- bank a few metres away. Both trials were lost to it.
-- The numbers below are the dev world's ponds as the live client read them (probe 2026-11-17, build 26574459).
--   lua client_mod/tests/test_extent.lua
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

local W = { me = { X = 4658.8, Y = 189127.1, Z = -3544.6 }, ics = {} }
local pawn = uobj("BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_1", {
    K2_GetActorLocation = function() return { X = W.me.X, Y = W.me.Y, Z = W.me.Z } end })
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1", {
    IsLocalController = function() return true end, Pawn = pawn })
function FindAllOf(cls)
    if cls == "BP_PlayerController_C" then return { pc } end
    if cls == "InteractionComponent" then return W.ics end
    return {}
end

-- an actor with an interaction component: mid cm, scale, yaw, the engine's bounds half sizes cm (nil: no bounds read)
local function thing(cls, id, prompt, mid, scale, yaw, half)
    local a = uobj(cls .. " /Game/L.L:PersistentLevel." .. id, {
        K2_GetActorLocation = function() return { X = mid.X, Y = mid.Y, Z = mid.Z } end,
        GetActorScale3D = function() return { X = scale[1], Y = scale[2], Z = scale[3] } end,
        K2_GetActorRotation = function() return { Pitch = 0, Yaw = yaw, Roll = 0 } end,
        GetActorBounds = function(_, _, o, e)
            if not half then error("no bounds") end
            o.X, o.Y, o.Z = mid.X, mid.Y, mid.Z
            e.X, e.Y, e.Z = half[1], half[2], half[3]
        end })
    local ic = uobj("SingleSourceContainerInteractionComponent /Game/L.L:PersistentLevel." .. id .. ".Interaction", {
        GetOwner = function() return a end, InteractionPrompt = ftext(prompt),
        K2_GetComponentLocation = function() return { X = mid.X, Y = mid.Y, Z = mid.Z } end })
    W.ics[#W.ics + 1] = ic
    return a
end

local S = assert(loadfile(root .. "/client_mod/scripts/sense.lua"))()
check("sense exports box_nearest and extent_of", type(S.box_nearest) == "function" and type(S.extent_of) == "function")
if failn > 0 then
    print(string.format("%d passed, %d failed", pass, failn))
    os.exit(1)
end

-- ---------------------------------------------------------------- the nearest point of a turned box
local function near(a, b) return math.abs(a - b) < 0.01 end
local p = S.box_nearest({ X = 3000, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }, 1000, 500, 100, 0)
check("box: straight out along its long side", near(p.X, 1000) and near(p.Y, 0) and near(p.Z, 0), p.X .. "," .. p.Y)
p = S.box_nearest({ X = 3000, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }, 1000, 500, 100, 90)
check("box: turned 90 degrees its short side faces him", near(p.X, 500) and near(p.Y, 0), p.X .. "," .. p.Y)
p = S.box_nearest({ X = 3000, Y = 3000, Z = 900 }, { X = 0, Y = 0, Z = 0 }, 1000, 500, 100, 0)
check("box: off a corner, and above it", near(p.X, 1000) and near(p.Y, 500) and near(p.Z, 100), p.X .. "," .. p.Y .. "," .. p.Z)
p = S.box_nearest({ X = 300, Y = -200, Z = 50 }, { X = 0, Y = 0, Z = 0 }, 1000, 500, 100, 33)
check("box: inside it the nearest point is where he is", near(p.X, 300) and near(p.Y, -200) and near(p.Z, 50), p.X .. "," .. p.Y)

-- ---------------------------------------------------------------- an actor's extent
local POND_MID = { X = 4677.25, Y = 179141.25, Z = -3494.95 }
local pond = thing("BP_WaterVolume_C", "BP_WaterVolume_C_UAID_00BE4395530E72EB01_2108496385", "Collect Water", POND_MID,
    { 29.997646, 49.02343, 6.485214 }, 37.960446, { 2690.3187, 2855.1944, 324.2607 })
local ext = S.extent_of(pond)
check("extent: a water volume is the turned box its scale and yaw give (they give the engine's own bounds)",
    ext and ext.turned == true and near(ext.ha, 1499.88) and near(ext.hb, 2451.17) and near(ext.yaw, 37.960446),
    ext and (tostring(ext.turned) .. " " .. tostring(ext.ha) .. " " .. tostring(ext.hb)))
local odd = thing("BP_WaterVolume_C", "BP_WaterVolume_C_UAID_ODD", "Collect Water", { X = 0, Y = 0, Z = 0 },
    { 1, 1, 1 }, 20, { 4000, 3000, 300 })
ext = S.extent_of(odd)
check("extent: scale and yaw that do not give the bounds -> the bounds themselves, unturned",
    ext and ext.turned == false and ext.ha == 4000 and ext.hb == 3000 and ext.yaw == 0, ext and tostring(ext.ha))
local blind = thing("BP_WaterVolume_C", "BP_WaterVolume_C_UAID_BLIND", "Collect Water", { X = 0, Y = 0, Z = 0 }, { 1, 1, 1 }, 0, nil)
check("extent: bounds that do not read -> none (its middle, as before)", S.extent_of(blind) == nil)
local chest = thing("BP_WorldChest_C", "BP_WorldChest_C_1", "Open", { X = 4658.8, Y = 189127.1 - 9900, Z = -3544.6 },
    { 1, 1, 1 }, 0, { 50, 50, 50 })
check("extent: a thing of no extent class has none", S.extent_of(chest) == nil)

-- ---------------------------------------------------------------- the census: seen by its nearest point
W.ics = { W.ics[1], W.ics[4] } -- the pond (its middle 99.9 m off) and a chest 99 m off
local c = S.census(nil, { radius_m = 80 })
local rows = (c and c.interactables) or {}
local row
for _, x in ipairs(rows) do if tostring(x.id):find("WaterVolume", 1, true) then row = x end end
check("census: a pond whose near edge is inside the radius is seen, though its middle is not", row ~= nil, #rows)
check("census: its distance is to its nearest point (71.4 m), its position stays its middle",
    row and row.distance and math.abs(row.distance - 71.4) < 0.15 and math.abs(row.position[2] - 1791.41) < 0.01, row and row.distance)
check("census: the row tells where that nearest point is and how big the water is",
    row and type(row.nearest) == "table" and math.abs(row.nearest[1] - 43.52) < 0.05 and math.abs(row.nearest[2] - 1819.96) < 0.05
    and type(row.size_m) == "table" and row.size_m[1] == 30 and row.size_m[2] == 49,
    row and row.nearest and (row.nearest[1] .. "," .. row.nearest[2]))
local chest_row
for _, x in ipairs(rows) do if tostring(x.id):find("WorldChest", 1, true) then chest_row = x end end
check("census: a thing with no extent 99 m off stays out of an 80 m look", chest_row == nil)
-- id_has (collect_water's far look for the nearest pond): only those things are described, nothing else in the radius
local function ids_of(cc) local t = {}; for _, x in ipairs((cc and cc.interactables) or {}) do t[#t + 1] = tostring(x.id) end; return t end
local all = ids_of(S.census(nil, { radius_m = 200, kinds = { interactables = true } }))
local only = ids_of(S.census(nil, { radius_m = 200, kinds = { interactables = true }, lean = true, id_has = "WaterVolume" }))
check("census: without id_has the chest 99 m off is listed in 200 m", #all == 2, table.concat(all, ","))
check("census: id_has lists the pond alone", #only == 1 and only[1]:find("WaterVolume", 1, true) ~= nil, table.concat(only, ","))
c = S.census(nil, { radius_m = 60 })
row = nil
for _, x in ipairs((c and c.interactables) or {}) do if tostring(x.id):find("WaterVolume", 1, true) then row = x end end
check("census: 71 m of ground to the pond is outside a 60 m radius", row == nil)
-- standing in the water
W.me = { X = POND_MID.X + 300, Y = POND_MID.Y - 200, Z = POND_MID.Z + 300 }
c = S.census(nil, { radius_m = 10 })
row = nil
for _, x in ipairs((c and c.interactables) or {}) do if tostring(x.id):find("WaterVolume", 1, true) then row = x end end
check("census: in the water it is 0 m off", row and row.distance == 0, row and row.distance)

-- ---------------------------------------------------------------- a standing poison cloud (a box) on the hazards list
-- (L3 deaths 2026-11-20: a PoisonEmitterBox owned by BP_DEDA_PoisonBreath_PoisonCloud_C): distance to its edge,
-- compass from him, size from its own extent, what it does
W.me = { X = 0, Y = 0, Z = 0 }
local cl_owner = uobj("BP_DEDA_PoisonBreath_PoisonCloud_C /Game/L.L:PersistentLevel.BP_DEDA_PoisonBreath_PoisonCloud_C_9")
local cl = uobj("PoisonEmitterBox /Game/L.L:PersistentLevel.BP_DEDA_PoisonBreath_PoisonCloud_C_9.PoisonEmitterBox", {
    NetworkedExtent = { X = 300, Y = 400, Z = 150 }, GetOwner = function() return cl_owner end,
    K2_GetComponentLocation = function() return { X = -900, Y = -1200, Z = 0 } end })
local base_find = FindAllOf
FindAllOf = function(cls) if cls == "PoisonEmitterBox" then return { cl } end return base_find(cls) end
c = S.census(nil, { radius_m = 50 })
local hz = ((c and c.hazards) or {})[1]
check("census: a poison cloud is a hazards row in words", hz and hz.kind == "ground_hazard" and hz.name == "poison cloud"
    and hz.id == "BP_DEDA_PoisonBreath_PoisonCloud_C_9" and tostring(hz.effect):find("poison", 1, true), hz and hz.kind)
check("census: the cloud's distance is to its edge (15 m to the middle, r 5 m), NW of him", hz and hz.distance == 10 and hz.direction == "NW",
    hz and (tostring(hz.distance) .. " " .. tostring(hz.direction)))
c = S.census(nil, { radius_m = 50, kinds = { creatures = true } })
check("census: a census that does not want hazards does not list it", c and (c.hazards == nil or #c.hazards == 0))
FindAllOf = base_find

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
