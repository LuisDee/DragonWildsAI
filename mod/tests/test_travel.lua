-- Offline tests for body/travel.lua against fake UE objects and a fake skills action slot.
-- Usage: lua mod/tests/test_travel.lua <empty_temp_dir>
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../?.lua;" .. here .. "/../scripts/?.lua;" .. package.path
local travel = require("body.travel")
local U = require("body.util")

local passed, failed = 0, {}
local function test(name, fn)
    travel._reset()
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed[#failed + 1] = name; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- ------------------------------------------------------------------ fake world (cm)
local F
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid ~= false end
function Obj:GetFullName() return self._full end
local function obj(full, t) t = t or {}; t._full = full; return setmetatable(t, Obj) end
local function at(o, x, y, z)
    o.loc = { X = x, Y = y, Z = z or 0 }
    o.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    return o
end

-- a UE4SS-like TArray of struct elements (ForEach(i, elem) with elem:get())
local function tarray(list)
    return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end }
end

local function guid(hex) return U.guid_from_hex(hex) end

local function region(name, id, x0, y0, x1, y1)
    local pts = { { x0, y0 }, { x1, y0 }, { x1, y1 }, { x0, y1 } }
    local spline = obj("SplineComponent /x." .. name .. ".Spline", {
        GetNumberOfSplinePoints = function() return #pts end,
        GetLocationAtSplinePoint = function(_, i) local p = pts[i + 1]; return { X = p[1], Y = p[2], Z = 0 } end,
        GetLocationAtSplineInputKey = function(_, key)
            local i = math.floor(key); local f = key - i
            local p, q = pts[i + 1], pts[(i + 1) % #pts + 1]
            return { X = p[1] + (q[1] - p[1]) * f, Y = p[2] + (q[2] - p[2]) * f, Z = 0 }
        end,
    })
    local r = obj("BP_MapRegion_C /Game/L.Region_" .. id, { RegionName = name, RegionID = id, PowerLevel = id,
                                                             BoundarySpline = spline })
    F.regions[#F.regions + 1] = r
    return r
end

local LA, LB = "5E74232B4126EDE0BAEFF9856FFD03C6", "0000000100000002000000030000000A"

local function lodestone(hex, x, y, opts)
    opts = opts or {}
    local e = { Identifier = guid(hex), Location = { X = x, Y = y, Z = 0 }, RespawnLocation = { X = x, Y = y, Z = 145 } }
    F.entries[#F.entries + 1] = e
    if opts.actor ~= false then
        local a = at(obj("BP_WorldLodestone_C /Game/L.Lodestone_" .. hex, { DisplayName = "Lodestone",
                         GameplayObjectRegistryIdentifier = guid(hex) }), x, y, 0)
        F.lodestones[#F.lodestones + 1] = a
    end
    return e
end

local function tile(x, y, ext)
    F.tiles[#F.tiles + 1] = at(obj("LandscapeStreamingProxy /Game/L.Tile_" .. x .. "_" .. y, {
        GetActorBounds = function(_, _, origin, extent)
            origin.X, origin.Y, origin.Z = x, y, 0
            extent.X, extent.Y, extent.Z = ext, ext, 100
        end }), x - ext, y - ext, 0)
end

local function world(opts)
    opts = opts or {}
    F = { calls = {}, regions = {}, entries = {}, lodestones = {}, tiles = {}, now = 0, finished = {},
          action = nil, can = {}, move_result = 2, teleport_ok = true, teleport_drift = 0 }
    local tc = obj("BP_Components_LodestoneTeleportationComponent_C /x.PC.TC", {
        CanTeleport = function(_, from, to)
            F.calls[#F.calls + 1] = "CanTeleport"
            assert(type(from) == "table" and type(from.A) == "number", "scalar FGuid table (R15)")
            return F.can[U.guid_hex(to)] == true and U.guid_hex(from) ~= U.guid_hex(to)
        end,
        CalculateTeleportationCost = function(_, d, w) return math.floor(d / 200000) + 1 end,
    })
    local pc = obj("BP_PlayerController_C /x.PC", { _name = "Zezima", LodestoneTeleportationComponent = tc })
    local ai = obj("AIController /x.AI", {
        MoveToLocation = function(_, dest) F.calls[#F.calls + 1] = "MoveToLocation"; F.last_move = dest; return F.move_result end,
        StopMovement = function() F.calls[#F.calls + 1] = "StopMovement" end,
    })
    F.luis = at(obj("BP_PlayerCharacter_C /x.Luis", { GetController = function() return pc end,
                    PlayerState = obj("PS /x.PS", { GetPlayerName = function() return "Zezima" end }) }),
                opts.luis_x or 0, opts.luis_y or 0, 0)
    F.bot = at(obj("BP_PlayerCharacter_C /x.Bot", { GetController = function() return ai end }), 300, 0, 0)
    F.bot.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 90, Roll = 0 } end
    F.bot.K2_TeleportTo = function(self, loc, rot)
        F.calls[#F.calls + 1] = "K2_TeleportTo"
        assert(type(loc.X) == "number" and type(rot.Yaw) == "number", "scalar tables only")
        if not F.teleport_ok then return false end
        self.loc = { X = loc.X + F.teleport_drift, Y = loc.Y, Z = loc.Z }
        return true
    end
    F.bot.ForceNetUpdate = function() end
    F.registry = obj("GameplayObjectRegistry /x.Registry", {})
    F.registry.Lodestones = tarray(F.entries)
    _G.FindAllOf = function(cls)
        if cls == "BP_PlayerCharacter_C" then return { F.luis, F.bot } end
        if cls == "GameplayObjectRegistry" then return { F.registry } end
        if cls == "WorldLodestone" then return F.lodestones end
        if cls == "MapRegion" then return F.regions end
        if cls == "LandscapeStreamingProxy" then return F.tiles end
        return {}
    end
    local skills = {
        now = function() return F.now end,
        _start = function(a) a.started = F.now; F.action = a end,
        _preempt = function() end,
        _finish = function(a, ok, reason, data)
            if a.done then return end
            a.done = true; F.action = nil
            F.finished[#F.finished + 1] = { ok = ok, reason = reason, data = data }
        end,
        _move_to_location = function(c, dest, acc) return c:MoveToLocation(dest, acc) end,
        _probe_guard = function(name, fn) return function(args, ctx)
            if type(args) == "table" and args.probe then return { ok = true, data = { probe = true, tool = name } } end
            return fn(args or {}, ctx or {}) end end,
    }
    local puppet = { get = function() return F.bot end, ensure_ready = function() return F.bot, F.bot:GetController() end }
    F.store = { n = opts.runes or 0, count = function(item) return item == "ITEM_Rune_Law" and F.store.n or 0 end,
                take = function(item, n) F.store.n = F.store.n - n; return true end }
    F.bridge = { handlers = {} }
    travel.register(F.bridge, nil, { skills = skills, puppet = puppet, store = F.store })
    _G.ExecuteInGameThreadWithDelay = nil
    return F
end

local H = function(name, args, ctx) return F.bridge.handlers[name](args or {}, ctx or { id = "t1" }) end
local function tick(ms) F.now = F.now + (ms or 250); if F.action then F.action.step(F.action) end end
local function count(name) local n = 0; for _, c in ipairs(F.calls) do if c == name then n = n + 1 end end; return n end

-- Standard map: Temple Woods (big) with a small Village inside; a far region with lodestone B.
local function standard(opts)
    world(opts)
    region("Temple Woods", 1, -10000, -10000, 10000, 10000)
    region("Village", 2, -1000, -1000, 1000, 1000)
    region("Far Plains", 3, 40000, -10000, 80000, 10000)
    lodestone(LA, 500, 0)
    lodestone(LB, 60000, 0)
    tile(0, 0, 12600)          -- Luis's area loaded
    tile(60000, 0, 12600)      -- the far lodestone's area loaded too
end

-- ------------------------------------------------------------------ tests
test("handlers registered and probe-safe: no reads, no calls", function()
    standard()
    for _, h in ipairs({ "travel", "where", "lodestones" }) do eq(H(h, { probe = true }).data.probe, true, h) end
    eq(#F.calls, 0)
end)

test("region_at: point in polygon, smallest region wins, parent reported", function()
    standard()
    local r, parent = travel.region_at({ X = 0, Y = 0, Z = 0 })
    eq(r.name, "Village"); eq(parent.name, "Temple Woods")
    eq(travel.region_at({ X = 5000, Y = 5000, Z = 0 }).name, "Temple Woods")
    eq(travel.region_at({ X = 30000, Y = 0, Z = 0 }), nil)
    eq(travel.find_region("far plains").name, "Far Plains")
    eq(travel.find_region("the village").name, "Village")
end)

test("lodestones: registry list, region-based names, unlocked via Luis's CanTeleport", function()
    standard()
    F.can[LB] = true
    local list = travel.lodestones()
    eq(#list, 2)
    eq(list[1].name, "Village Lodestone"); eq(list[1].region, "Village"); eq(list[1].unlocked_by_luis, false)
    eq(list[2].name, "Far Plains Lodestone"); eq(list[2].unlocked_by_luis, true)
    eq(list[2].position[1], 600); eq(list[2].arrival[3], 1.45)
    truthy(count("CanTeleport") >= 1)
end)

test("a single lodestone is never 'unlocked' (needs another to come from); registry mode relaxes it", function()
    world()
    region("Temple Woods", 1, -10000, -10000, 10000, 10000)
    lodestone(LA, 500, 0)
    F.can[LA] = true
    eq(travel.lodestones()[1].unlocked_by_luis, false)
    travel._reset(); world()
    region("Temple Woods", 1, -10000, -10000, 10000, 10000)
    lodestone(LA, 500, 0)
    local old = os.getenv
    os.getenv = function(k) if k == "DW_TRAVEL_UNLOCK" then return "registry" end return old(k) end
    local ok, err = pcall(function() eq(travel.lodestones()[1].unlocked_by_luis, true) end)
    os.getenv = old
    assert(ok, err)
end)

test("where: region, parent, nearest lodestone, loaded; position arg validated", function()
    standard()
    local w = H("where", { position = { 1, 2, 0 } })
    eq(w.ok, true); eq(w.data.region, "Village"); eq(w.data.parent_region, "Temple Woods")
    eq(w.data.nearest_lodestone.name, "Village Lodestone"); eq(w.data.loaded, true)
    local d = H("where").data -- the puppet's own position
    eq(d.position[1], 3)
    eq(H("where", { position = "x" }).reason, "invalid_args")
    eq(H("where", { position = { 300, 0, 0 } }).data.loaded, false, "no tile, no player near")
end)

test("travel to an unlocked lodestone: teleport, settle, nav probe, verified position", function()
    standard()
    F.can[LB] = true
    local r = H("travel", { to = LB }, { id = "tr1" })
    eq(r, nil, "async")
    eq(count("StopMovement"), 1); eq(count("K2_TeleportTo"), 1)
    eq(F.bot.loc.X, 60000); eq(F.bot.loc.Z, 145)
    tick(500); eq(#F.finished, 0, "waits for the settle check")
    tick(600)
    eq(#F.finished, 1)
    local f = F.finished[1]
    eq(f.ok, true, tostring(f.reason)); eq(f.data.teleported, true); eq(f.data.lodestone, LB)
    eq(f.data.region, "Far Plains"); eq(f.data.nav_ok, true)
    eq(count("MoveToLocation"), 1, "one short MoveTo proves nav after the teleport")
end)

test("travel by lodestone name works too", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = "far plains lodestone" }), nil)
    eq(F.bot.loc.X, 60000)
end)

test("travel to a lodestone Luis has not unlocked -> not_unlocked, nothing moves", function()
    standard()
    local r = H("travel", { to = LB })
    eq(r.ok, false); eq(r.reason, "not_unlocked"); eq(count("K2_TeleportTo"), 0)
end)

test("unknown lodestone id -> no_lodestone; unknown name -> unknown_target with lists", function()
    standard()
    eq(H("travel", { to = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" }).reason, "no_lodestone")
    eq(H("travel", { to = "the moon lodestone" }).reason, "no_lodestone")
    local r = H("travel", { to = "Narnia" })
    eq(r.reason, "unknown_target"); eq(#r.data.regions, 3); eq(#r.data.lodestones, 2)
    eq(H("travel", {}).reason, "invalid_args")
    eq(H("travel", { to = LB, teleport = "sometimes" }).reason, "invalid_args")
end)

test("destination not streamed in -> too_far/destination_unloaded, nothing moves", function()
    standard()
    F.tiles = {}
    tile(0, 0, 12600) -- only Luis's area
    F.can[LB] = true
    local r = H("travel", { to = LB })
    eq(r.reason, "too_far"); eq(r.data.detail, "destination_unloaded"); eq(count("K2_TeleportTo"), 0)
end)

test("coords: teleport to the best unlocked lodestone when it saves enough, then walk on", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = { 650, 50, 0 } }), nil)
    eq(count("K2_TeleportTo"), 1)
    tick(1100) -- settle -> walk
    eq(count("MoveToLocation"), 1)
    eq(F.last_move.X, 65000)
    F.bot.loc = { X = 64950, Y = 5000, Z = 0 }
    tick()
    eq(F.finished[1].ok, true); eq(F.finished[1].data.teleported, true)
    truthy(F.finished[1].data.saved_m > 500)
end)

test("coords near the bot: no teleport (saving below the threshold), just walk", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = { 20, 0, 0 } }), nil)
    eq(count("K2_TeleportTo"), 0); eq(count("MoveToLocation"), 1)
    F.bot.loc = { X = 2000, Y = 0, Z = 0 }
    tick()
    eq(F.finished[1].ok, true); eq(F.finished[1].data.teleported, false)
end)

test("teleport=never walks; teleport=require without a usable lodestone -> no_lodestone", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = { 650, 0, 0 }, teleport = "never" }), nil)
    eq(count("K2_TeleportTo"), 0)
    travel._reset(); standard()
    eq(H("travel", { to = { 650, 0, 0 }, teleport = "require" }).reason, "no_lodestone")
end)

test("region target: teleport to a lodestone inside it -> done on arrival (inside the polygon)", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = "Far Plains" }), nil)
    eq(count("K2_TeleportTo"), 1)
    tick(1100)
    eq(F.finished[1].ok, true); eq(F.finished[1].data.region, "Far Plains")
end)

test("already inside the target region -> ok already_there, nothing moves", function()
    standard()
    local r = H("travel", { to = "Village" })
    eq(r.ok, true); eq(r.data.already_there, true)
    eq(count("K2_TeleportTo") + count("MoveToLocation") + count("StopMovement"), 0)
end)

test("walk stuck -> path_blocked after the reissue cap", function()
    standard()
    eq(H("travel", { to = { 20, 0, 0 } }), nil)
    for _ = 1, 30 do tick(1000) end
    eq(F.finished[1].reason, "path_blocked")
    eq(count("MoveToLocation"), 1 + travel.MAX_REISSUE)
end)

test("MoveTo request refused -> path_blocked through the action slot", function()
    standard()
    F.move_result = 0
    eq(H("travel", { to = { 20, 0, 0 } }), nil)
    eq(F.finished[1].reason, "path_blocked")
end)

test("teleport did not land -> verification_failed", function()
    standard()
    F.can[LB] = true
    F.teleport_drift = 2000
    eq(H("travel", { to = LB }), nil)
    eq(F.finished[1].reason, "verification_failed")
end)

test("fell after the teleport -> rolled back to the start, verification_failed", function()
    standard()
    F.can[LB] = true
    eq(H("travel", { to = LB }), nil)
    F.bot.loc.Z = -5000 -- falling through unloaded ground
    tick(1100)
    eq(F.finished[1].reason, "verification_failed")
    eq(F.bot.loc.X, 300, "back where it started"); eq(count("K2_TeleportTo"), 2)
end)

test("budget cost: pays law runes from the bot's own store, refuses when short", function()
    local old = os.getenv
    os.getenv = function(k) if k == "DW_TRAVEL_COST" then return "budget" end return old(k) end
    local ok, err = pcall(function()
        standard({ runes = 0 })
        F.can[LB] = true
        local r = H("travel", { to = LB })
        eq(r.reason, "not_enough_resources"); eq(count("K2_TeleportTo"), 0)
        travel._reset(); standard({ runes = 10 })
        F.can[LB] = true
        eq(H("travel", { to = LB }), nil)
        eq(F.store.n, 10 - 1)
    end)
    os.getenv = old
    assert(ok, err)
end)

test("teleport_to_lodestone (sync API): debug allow_locked, crowd offset, settle check", function()
    standard()
    F.luis.loc = { X = 500, Y = 0, Z = 145 } -- Luis stands on the Village pad
    local r = travel.teleport_to_lodestone(LA, {})
    eq(r.reason, "not_unlocked")
    r = travel.teleport_to_lodestone(LA, { allow_locked = true })
    eq(r.ok, true, tostring(r.reason))
    eq(F.bot.loc.X, 500 + travel.CROWD_CM, "beside Luis, not inside him")
    eq(count("MoveToLocation"), 1, "settle ran (no delay fn offline) and probed nav")
end)

test("lodestones handler: wire list with distances and modes", function()
    standard()
    local r = H("lodestones")
    eq(r.ok, true); eq(#r.data.lodestones, 2); eq(r.data.unlock_mode, "luis"); eq(r.data.cost_mode, "free")
    eq(r.data.lodestones[1].distance, 2.47) -- to the arrival point (145 cm up)
    for _, l in ipairs(r.data.lodestones) do eq(l._guid, nil); eq(l.guid, nil, "no structs or guids leak") end
end)

print(("test_travel: %d passed, %d failed"):format(passed, #failed))
os.exit(#failed == 0 and 0 or 1)
