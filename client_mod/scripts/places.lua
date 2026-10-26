-- places.lua: the game's own place data, READ ONLY (BUGS A5: a wiki region / NPC name -> a world position).
--
-- What the game knows about places (dump 26161880; DISCOVERIES "Lodestones, map regions and travel", read live on
-- the server 2026-10-25 via mod/experiments/travel_probe.lua):
--   * BP_MapRegion_C actors (persistent level): RegionID, RegionName (FText), PowerLevel and a closed
--     BoundarySpline (6-90 points). Overlapping polygons: the smallest one containing a point wins.
--   * AGameplayObjectRegistry.Landmarks (TArray<FLandmarkData>): ~558 map points {Location, Identifier, Category,
--     UserVisibleDescription, bNeedsToBeDiscovered}; the description names NPCs ("Zanik", "Wise Old Man", several
--     spots each), shrines, anima vents, agility courses ...
--   * The local controller's RevealedMapFogComponent.CurrentMapRegion: the region the GAME says he is in (the check
--     for our point-in-polygon).
-- Lodestones are per world (player-built) and stay with lodestone.lua; this module does not list them.
--
-- Consumers: client_mod/commands/places_dump.lua (writes the raw dump that tools/build_places.py normalises into
-- data/places_<build>.json for brain/places.py) and, once registered, the read tool `places`.
-- Pure parts (polygon, point-in-polygon, smallest region) take plain tables: client_mod/tests/test_places.lua.
-- Never writes to the game; only property reads and BlueprintPure/const spline getters.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local M = { W = {} }
local W = M.W
local U -- mod/body/util.lua, loaded on first engine read (tests never need it)
local function util()
    if U == nil then U = assert(loadfile(ROOT .. "/mod/body/util.lua"))() end
    return U
end

M.cfg = { max_points = 128, max_landmarks = 2000 }

-- ---------- pure geometry (metres, [x, y])
local function r2(x) return math.floor(x * 100 + 0.5) / 100 end

function M.bbox(poly)
    if type(poly) ~= "table" or #poly == 0 then return nil end
    local a, b, c, d = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(poly) do
        a, b = math.min(a, p[1]), math.min(b, p[2])
        c, d = math.max(c, p[1]), math.max(d, p[2])
    end
    return { r2(a), r2(b), r2(c), r2(d) }
end

function M.area(poly)
    local s, n = 0, #poly
    for i = 1, n do
        local p, q = poly[i], poly[i % n + 1]
        s = s + p[1] * q[2] - q[1] * p[2]
    end
    return math.abs(s) / 2
end

-- even-odd ray cast; points on the edge may go either way
function M.inside(poly, x, y)
    local n, inside = #poly, false
    if n < 3 then return false end
    local j = n
    for i = 1, n do
        local xi, yi, xj, yj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
        if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
        j = i
    end
    return inside
end

-- the smallest region whose polygon holds [x, y] (overlaps: travel.region_at's rule), or nil
function M.region_at(regions, x, y)
    local best, best_a
    for _, r in ipairs(regions or {}) do
        local poly = r.polygon
        if type(poly) == "table" and #poly >= 3 and M.inside(poly, x, y) then
            local a = M.area(poly)
            if best_a == nil or a < best_a then best, best_a = r, a end
        end
    end
    return best
end

-- ---------- engine reads (replaceable in tests through M.W)
local function each(arr, fn, cap)
    local n = 0
    if arr == nil then return end
    pcall(function()
        arr:ForEach(function(_, e)
            n = n + 1
            if n > cap then return true end
            local ok, v = pcall(function() return e:get() end)
            fn(ok and v ~= nil and v or e)
        end)
    end)
end

local function text(v)
    local u = util()
    return u.str(v) or u.try(function() return v:ToString() end)
end

-- the spline's control points in world space, metres [x, y, z] (ESplineCoordinateSpace::World = 1)
function W.spline_points(spline)
    local u = util()
    local out = {}
    local n = tonumber(u.try(function() return spline:GetNumberOfSplinePoints() end)) or 0
    for i = 0, math.min(n, M.cfg.max_points) - 1 do
        local p = u.try(function() return spline:GetLocationAtSplinePoint(i, 1) end)
        local ok, x, y, z = pcall(function() return p.X, p.Y, p.Z end)
        if ok and type(x) == "number" then out[#out + 1] = { r2(x / 100), r2(y / 100), r2((z or 0) / 100) } end
    end
    return out, n
end

function W.regions()
    local u = util()
    local out = {}
    for _, r in ipairs(u.find_all("MapRegion", { skip_defaults = true })) do
        local spline = u.try(function() return r.BoundarySpline end)
        local pts, n = {}, 0
        if u.valid(spline) then pts, n = W.spline_points(spline) end
        local poly = {}
        for _, p in ipairs(pts) do poly[#poly + 1] = { p[1], p[2] } end
        out[#out + 1] = {
            id = u.short(r), region_id = tonumber(u.try(function() return r.RegionID end)),
            name = text(u.try(function() return r.RegionName end)) or text(u.try(function() return r:GetRegionName() end)),
            power = tonumber(u.try(function() return r.PowerLevel end)),
            -- FGameplayTag property reads (no hand-built struct): the tag hierarchy may name the province
            tag = text(u.try(function() return r.MapRegionTag.TagName end)),
            quest_tag = text(u.try(function() return r.QuestConversationEntryTag.TagName end)),
            closed = u.valid(spline) and u.try(function() return spline:IsClosedLoop() end) or nil,
            spline_points = n, polygon = poly, z = pts[1] and pts[1][3] or nil, bbox = M.bbox(poly),
        }
    end
    return out
end

function W.landmarks()
    local u = util()
    local reg = u.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    local out = {}
    if not u.valid(reg) then return out end
    each(u.try(function() return reg.Landmarks end), function(e)
        local loc = u.try(function() return { X = e.Location.X, Y = e.Location.Y, Z = e.Location.Z } end)
        local name = u.str(u.try(function() return e.InternalName end))
        out[#out + 1] = { desc = text(u.try(function() return e.UserVisibleDescription end)),
                          name = name ~= "None" and name or nil,
                          category = tonumber(u.try(function() return e.Category end)),
                          discover = u.try(function() return e.bNeedsToBeDiscovered end),
                          guid = u.guid_hex(u.try(function() return e.Identifier end)),
                          position = loc and u.to_wire(loc) or nil }
    end, M.cfg.max_landmarks)
    return out
end

-- {position (m), game_region (the game's CurrentMapRegion name)} for the local player
function W.me()
    local u = util()
    local pc
    for _, c in ipairs(u.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if u.try(function() return c:IsLocalController() end) == true then pc = c end
    end
    if not u.valid(pc) then return {} end
    local pawn = u.try(function() return pc.Pawn end)
    local fog = u.try(function() return pc.RevealedMapFogComponent end)
    local cur = u.valid(fog) and u.try(function() return fog.CurrentMapRegion end) or nil
    return { position = u.valid(pawn) and u.to_wire(u.loc(pawn)) or nil,
             game_region = u.valid(cur) and (text(u.try(function() return cur.RegionName end))) or nil,
             game_region_id = u.valid(cur) and tonumber(u.try(function() return cur.RegionID end)) or nil }
end

-- everything, plus our own region test against the game's answer
function M.read_all()
    local regions, landmarks, me = W.regions(), W.landmarks(), W.me()
    local mine = me.position and M.region_at(regions, me.position[1], me.position[2]) or nil
    local agrees = nil -- nil = can't tell (no pawn, no game answer or outside every polygon)
    if me.game_region ~= nil and mine ~= nil then agrees = (me.game_region == mine.name) end
    return { schema = "dw_places_raw/1", regions = regions, landmarks = landmarks, me = me,
             computed_region = mine and mine.name or nil,
             agrees = agrees }
end

-- ---------- tool (read-only; registration = "places" in client_bridge.lua M.MODULES)
M.HANDLERS = {}
M.HANDLERS.places = function(_log, args, _ctx)
    local all = M.read_all()
    if type(args) == "table" and args.summary then
        return { ok = true, data = { regions = #all.regions, landmarks = #all.landmarks, me = all.me,
                                     computed_region = all.computed_region, agrees = all.agrees } }
    end
    return { ok = true, data = all }
end
local OBJ = { __jsontype = "object" }
M.MANIFEST = {
    places = { kind = "read", llm = false, moves = false, duration_s = 1, timeout_s = 20,
        description = "The game's map regions (polygons) and landmarks (named map points such as NPCs) and the region you are in. Read-only.",
        args = { type = "object", properties = setmetatable({ summary = { type = "boolean" } }, OBJ) },
        reasons = { "state_unavailable", "companion_down" } },
}

return M
