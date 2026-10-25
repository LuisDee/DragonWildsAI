-- Lodestone / region / teleport discovery (build 26161880). EVERY default action is READ-ONLY.
-- The only write ("tp") moves the PUPPET, never a player, and refuses without confirm=true.
--   debug_run {"module":"travel_probe"}                         summary: counts of everything below
--   {"action":"lodestones"}       WorldLodestone actors, LodestoneComponents, registry Lodestones entries
--   {"action":"regions"}          BP_MapRegion actors: RegionID, RegionName, spline point count, bbox
--   {"action":"labels"}           BP_RegionLabelActor_C map labels (MapRegionIconComponent.LabelText)
--   {"action":"landmarks"}        registry Landmarks (InternalName, description, category, location)
--   {"action":"luis"}             Luis's controller: teleport component (cost flags), map fog (current
--                                 region, RevealedMapRegionsBitmap), revealed icons; READ ONLY
--   {"action":"can","from":"<hex>","to":"<hex>"}   CanTeleport / GetTeleportationCost / CanAfford on
--                                 Luis's teleport component (BlueprintPure, scalar-only FGuid tables)
--   {"action":"where","at":[x,y,z]}   body/travel.lua region + nearest lodestone (fresh loadfile)
--   {"action":"tp","to":"<hex>","confirm":true}    body/travel.lua teleport of the PUPPET (fresh loadfile)
local U = require("body.util")

local M = {}

local function each(arr, fn)
    local out = {}
    if arr == nil then return out end
    U.try(function()
        arr:ForEach(function(i, e)
            local v = U.try(function() return fn(e:get(), i) end)
            if v ~= nil then out[#out + 1] = v end
        end)
    end)
    return out
end

local function vec(v)
    if v == nil then return nil end
    local t = U.try(function() return { X = v.X, Y = v.Y, Z = v.Z } end)
    return t and U.to_wire(t) or nil
end

local function text(v)
    return U.str(v) or U.try(function() return v:ToString() end)
end

local function registry()
    for _, r in ipairs(U.find_all("GameplayObjectRegistry", { skip_defaults = true })) do return r end
end

function M.lodestones()
    local actors = {}
    for _, a in ipairs(U.find_all("WorldLodestone", { skip_defaults = true })) do
        actors[#actors + 1] = {
            id = U.short(a), class = U.class_word(a), pos = U.to_wire(U.loc(a)),
            display = text(U.try(function() return a.DisplayName end)),
            guid = U.guid_hex(U.try(function() return a.GameplayObjectRegistryIdentifier end)),
            offset = vec(U.try(function() return a.TeleportLocationOffset end)),
            unavailable = text(U.try(function() return a.InteractionUnavailableAdditionalDescriptionText end)),
            prompt = text(U.try(function() return a.InteractionComponent.InteractionPrompt end)),
            hidden = U.try(function() return a.bHidden end),
        }
    end
    local comps = {}
    for _, c in ipairs(U.find_all("LodestoneComponent", { skip_defaults = true })) do
        local owner = U.try(function() return c:GetOwner() end)
        comps[#comps + 1] = {
            id = U.fullname(c), owner = U.valid(owner) and U.fullname(owner) or nil,
            owner_pos = U.valid(owner) and U.to_wire(U.loc(owner)) or nil,
            owner_display = U.valid(owner) and text(U.try(function() return owner.DisplayName end)) or nil,
            guid = U.guid_hex(U.try(function() return c.GameplayObjectRegistryIdentifier end)),
            offset = vec(U.try(function() return c.TeleportLocationOffset end)),
        }
    end
    local reg = registry()
    local entries = reg and each(U.try(function() return reg.Lodestones end), function(e)
        return { guid = U.guid_hex(e.Identifier), loc = vec(e.Location), respawn = vec(e.RespawnLocation) }
    end) or {}
    return { actors = actors, components = comps, registry = entries, registry_found = reg ~= nil }
end

local function spline_info(s)
    if not U.valid(s) then return nil end
    local n = tonumber(U.try(function() return s:GetNumberOfSplinePoints() end)) or 0
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i = 0, n - 1 do
        local p = U.try(function() return s:GetLocationAtSplinePoint(i, 1) end) -- ESplineCoordinateSpace::World
        if p then
            minx, miny = math.min(minx, p.X), math.min(miny, p.Y)
            maxx, maxy = math.max(maxx, p.X), math.max(maxy, p.Y)
        end
    end
    return { points = n, closed = U.try(function() return s:IsClosedLoop() end),
             bbox_m = n > 0 and { U.round(minx / 100), U.round(miny / 100), U.round(maxx / 100), U.round(maxy / 100) } or nil }
end

function M.regions()
    local out = {}
    for _, r in ipairs(U.find_all("MapRegion", { skip_defaults = true })) do
        out[#out + 1] = {
            id = U.short(r), region_id = U.try(function() return r.RegionID end),
            name = text(U.try(function() return r.RegionName end)) or text(U.try(function() return r:GetRegionName() end)),
            power = U.try(function() return r.PowerLevel end), pos = U.to_wire(U.loc(r)),
            spline = spline_info(U.try(function() return r.BoundarySpline end)),
        }
    end
    return out
end

function M.labels()
    local out = {}
    for _, c in ipairs(U.find_all("MapRegionIconComponent", { skip_defaults = true })) do
        local owner = U.try(function() return c:GetOwner() end)
        out[#out + 1] = { label = text(U.try(function() return c.LabelText end)),
                          owner = U.valid(owner) and U.short(owner) or nil,
                          pos = U.valid(owner) and U.to_wire(U.loc(owner)) or nil }
    end
    return out
end

function M.landmarks()
    local reg = registry()
    return reg and each(U.try(function() return reg.Landmarks end), function(e)
        return { name = U.str(e.InternalName), desc = text(e.UserVisibleDescription), cat = e.Category,
                 loc = vec(e.Location), guid = U.guid_hex(e.Identifier), discover = e.bNeedsToBeDiscovered }
    end) or {}
end

local function luis_pc()
    local players = U.split_pawns()
    local p = players[1]
    return p and U.controller_of(p), p
end

local function teleport_comp(pc)
    local c = U.try(function() return pc.LodestoneTeleportationComponent end)
    if not U.valid(c) then c = U.try(function() return pc.BP_Components_LodestoneTeleportationComponent end) end
    return U.valid(c) and c or nil
end

function M.luis()
    local pc, pawn = luis_pc()
    if not pc then return { error = "no player" } end
    local tc = teleport_comp(pc)
    local fog = U.try(function() return pc.RevealedMapFogComponent end)
    local cur = U.valid(fog) and U.try(function() return fog.CurrentMapRegion end)
    local cost_item = tc and U.try(function() return tc.TeleportationCostItemData end)
    local icons = U.try(function() return pc.RevealedMapIconsComponent end)
    local names = {}
    if U.valid(icons) then
        U.try(function()
            icons.RevealedLandmarkNames:ForEach(function(_, e) names[#names + 1] = U.str(e:get()) end)
        end)
    end
    return {
        pc = U.short(pc), pos = U.to_wire(U.loc(pawn)),
        teleport_comp = tc and U.fullname(tc) or nil,
        cost_enabled = tc and U.try(function() return tc.bEnableTeleportationCost end),
        cost_item = U.valid(cost_item) and U.path_of(cost_item) or nil,
        hide_map = tc and U.try(function() return tc.bHideMapAfterTeleportationStarted end),
        damage_on_complete = tc and U.try(function() return tc.bShouldTryDamageOnTeleportComplete end),
        fog = U.valid(fog) and U.fullname(fog) or nil,
        current_region = U.valid(cur) and text(U.try(function() return cur.RegionName end)) or nil,
        current_region_id = U.valid(cur) and U.try(function() return cur.RegionID end) or nil,
        revealed_bitmap = U.valid(fog) and U.try(function() return fog.RevealedMapRegionsBitmap end) or nil,
        revealed_landmarks = names,
        pawn_region_cached = U.try(function() return text(pawn.CachedMapRegion.RegionName) end),
    }
end

function M.can(args)
    local pc = luis_pc()
    local tc = pc and teleport_comp(pc)
    if not tc then return { error = "no teleport component" } end
    local from, to = U.guid_from_hex(args.from or ""), U.guid_from_hex(args.to or "")
    if not (from and to) then return { error = "from/to must be 32-hex guids" } end
    -- scalar-only tables (R15 safe); BlueprintPure reads on Luis's component, no state change
    return {
        can = U.try(function() return tc:CanTeleport(from, to) end),
        cost = U.try(function() return tc:GetTeleportationCost(from, to) end),
        afford = U.try(function() return tc:CanAffordTeleportationCost(from, to) end),
    }
end

local function fresh_travel()
    local root = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]experiments[/\\][^/\\]*$"))
    local chunk = root and loadfile(root .. "/body/travel.lua")
    return chunk and chunk() or require("body.travel")
end

function M.run(log, args)
    args = args or {}
    local a = args.action or "summary"
    if a == "lodestones" then return M.lodestones() end
    if a == "regions" then return { regions = M.regions() } end
    if a == "labels" then return { labels = M.labels() } end
    if a == "landmarks" then return { landmarks = M.landmarks() } end
    if a == "luis" then return M.luis() end
    if a == "can" then return M.can(args) end
    if a == "where" then
        local t = fresh_travel()
        return t.where({ position = args.at }, { log = log })
    end
    if a == "tp" then
        if args.confirm ~= true then return { ok = false, error = "refused: tp moves the puppet; pass confirm=true" } end
        local t = fresh_travel()
        return t.teleport_to_lodestone(args.to, { log = log })
    end
    local l = M.lodestones()
    return { lodestone_actors = #l.actors, lodestone_components = #l.components, registry_lodestones = #l.registry,
             regions = #M.regions(), labels = #M.labels(), landmarks = #M.landmarks() }
end

return M
