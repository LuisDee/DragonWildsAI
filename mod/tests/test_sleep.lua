-- Offline tests for body/sleep.lua (the verified night-skip flow: shelter spawn + direct Sleep, beds,
-- the sleep-when-Luis-sleeps reflex) against fake UE objects and a fake skills action slot.
-- Usage: lua mod/tests/test_sleep.lua <empty_temp_dir>
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../?.lua;" .. here .. "/../scripts/?.lua;" .. package.path
local sleep = require("body.sleep")

local passed, failed = 0, {}
local function test(name, fn)
    sleep._reset()
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed[#failed + 1] = name; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- ------------------------------------------------------------------ fake world
local F
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid ~= false end
function Obj:GetFullName() return self._full end
local function obj(full, t) t = t or {}; t._full = full; return setmetatable(t, Obj) end

local function pawn(full, x, ctrl)
    local p = obj(full)
    p.loc = { X = x, Y = 0, Z = 0 }
    p.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    p.PlayerRestComponent = obj("BP_Components_Rest_C /x.Rest", { IsSleeping = false })
    p.GetController = function() return ctrl end
    p.GetWorld = function() return F.world end
    p.PlayerState = obj("DominionPlayerState /x.PS_" .. x, { GetPlayerName = function() return ctrl._name end })
    return p
end

local function count(kind)
    local n = 0
    for _, c in ipairs(F.calls) do if c == kind then n = n + 1 end end
    return n
end

-- A bed component on an owner actor; can_sleep defaults to FALSE (as the live shelter answered).
local function bed(id, x, t)
    t = t or {}
    local owner = t.owner or obj("BP_Bed_C /Game/L." .. id)
    owner.loc = owner.loc or { X = x, Y = t.y or 0, Z = 0 }
    owner.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    local b = obj("BedComponent /Game/L." .. id .. ".Bed", {
        bRequiresClaimingToSleepIn = t.requires_claim == true,
        GetOwner = function() return owner end,
        IsClaimedByAnyPlayer = function(self) return self.claimant ~= nil end,
        IsClaimedByPlayer = function(self, p) return self.claimant_pawn == p end,
        GetClaimingCharacterName = function(self) return self.claimant end,
        claimant = t.claimant,
        CanSleep = function() return false end,
        Claim = function(self, p) F.calls[#F.calls + 1] = "Claim"; self.claimant, self.claimant_pawn = "Claude", p end,
        Sleep = function(_, p)
            F.calls[#F.calls + 1] = "Sleep"
            if F.sleep_works == false then return end
            p.PlayerRestComponent.IsSleeping = true
            p.PlayerRestComponent.CurrentRestingAreaActor = owner
        end,
        StopSleeping = function(_, p) F.calls[#F.calls + 1] = "StopSleeping"; p.PlayerRestComponent.IsSleeping = false end,
    })
    F.beds[#F.beds + 1] = b
    return b
end

local function world(opts)
    opts = opts or {}
    sleep._reset()
    F = { calls = {}, beds = {}, action = nil, now = 0, finished = {}, follows = {}, spawned = {} }
    F.shelter_cls = obj("BlueprintGeneratedClass " .. sleep.SHELTER_CLASS)
    F.world = obj("World /Game/L", {
        SpawnActor = function(_, cls, at, rot)
            F.calls[#F.calls + 1] = "SpawnActor"
            local n = #F.spawned + 1
            local sh = obj("BP_Magic_SummonShelter_C /Game/L.BP_Magic_SummonShelter_C_" .. n)
            sh.loc = { X = at.X, Y = at.Y, Z = at.Z }
            sh.rot = rot
            sh.SetLifeSpan = function(self, s) F.calls[#F.calls + 1] = "SetLifeSpan"; self._valid = false end
            sh.SetOwner = function(self, o) F.calls[#F.calls + 1] = "SetOwner"; self.owner = o end
            F.spawned[n] = sh
            bed("Shelter" .. n, at.X, { owner = sh })
            return sh
        end,
    })
    local pc = obj("BP_PlayerController_C /x.PC", { _name = "Zezima" })
    local ai = obj("AIController /x.AI", { _name = "Claude",
        MoveToActor = function() F.calls[#F.calls + 1] = "MoveToActor"; return 2 end })
    F.luis = pawn("BP_PlayerCharacter_C /x.Luis", 0, pc)
    F.bot = pawn("BP_PlayerCharacter_C /x.Bot", 300, ai)
    _G.FindAllOf = function(cls)
        if cls == "BP_PlayerCharacter_C" then return { F.luis, F.bot } end
        if cls == "BedComponent" then return F.beds end
        if cls == "BP_Magic_SummonShelter_C" then return F.spawned end
        return {}
    end
    _G.StaticFindObject = function(path)
        if path == sleep.SHELTER_CLASS then return (F.class_loaded ~= false) and F.shelter_cls or nil end
        return obj("InGameTimeFunctionLibrary /Script/Dominion.Default__X", { IsNighttime = function() return F.night end })
    end
    _G.LoadAsset = function() F.calls[#F.calls + 1] = "LoadAsset"; F.class_loaded = true end
    F.class_loaded = opts.class_loaded
    local skills = {
        now = function() return F.now end,
        current = function() return F.action end,
        _start = function(a) a.started = F.now; F.action = a end,
        _finish = function(a, ok, reason, data) a.done = true; F.action = nil; F.finished[#F.finished + 1] = { ok = ok, reason = reason, data = data } end,
        _move_to_actor = function(c, g, acc) return c:MoveToActor(g, acc) end,
        _probe_guard = function(name, fn) return function(args, ctx)
            if type(args) == "table" and args.probe then return { ok = true, data = { probe = true, tool = name } } end
            return fn(args or {}, ctx or {}) end end,
        add_state_extender = function(_, fn) F.extender = fn end,
    }
    local puppet = { get = function() return F.bot end, ensure_ready = function() return F.bot end }
    F.bridge = { handlers = { follow = function(args) F.follows[#F.follows + 1] = args.player; return { ok = true } end } }
    sleep.register(F.bridge, nil, { skills = skills, puppet = puppet, no_loop = true })
    return F
end

local H = function(name, args, ctx) return F.bridge.handlers[name](args or {}, ctx or { id = "c1" }) end

-- ------------------------------------------------------------------ tests
test("handlers registered and probe-safe; the useless spectator valve is gone", function()
    world()
    for _, h in ipairs({ "sleep", "wake", "sleep_status" }) do eq(H(h, { probe = true }).data.probe, true, h) end
    eq(F.bridge.handlers.night_skip, nil)
    eq(#F.calls, 0)
    F.night = true
    local s = H("sleep_status").data
    eq(s.night, true); eq(s.bot_sleeping, false)
end)

test("no bed: spawn a shelter ~3 m away (away from Luis) and Sleep directly although CanSleep is false", function()
    world()
    local r = H("sleep", {})
    eq(r.ok, true, tostring(r.reason)); eq(r.data.mode, "shelter"); eq(r.data.can_sleep, false)
    eq(F.calls[1], "SpawnActor"); eq(F.calls[2], "SetOwner"); eq(F.calls[3], "Sleep")
    local sh = F.spawned[1]
    eq(sh.owner, F.bot, "owned by the bot, like a real cast"); eq(sh.Instigator, F.bot)
    eq(sh.loc.X, 600, "3 m from the bot, on the side away from Luis (who is at X=0)")
    eq(r.data.resting_area, "BP_Magic_SummonShelter_C_1")
    eq(count("MoveToActor"), 0, "never walks into the shelter")
    local w = H("wake")
    eq(w.ok, true); eq(w.data.was, "shelter"); eq(w.data.shelter_removed, true)
    eq(F.calls[#F.calls], "SetLifeSpan")
end)

test("shelter class not loaded: LoadAsset by path; Sleep that does not take: shelter removed, verification_failed", function()
    world({ class_loaded = false })
    local r = H("sleep", { mode = "shelter" })
    eq(r.ok, true, tostring(r.reason)); eq(r.data.class_from, "load_asset"); eq(F.calls[1], "LoadAsset")
    H("wake")
    F.sleep_works = false
    r = H("sleep", { mode = "shelter" })
    eq(r.ok, false); eq(r.reason, "verification_failed"); eq(F.calls[#F.calls], "SetLifeSpan")
end)

test("the shelter never lands on a player: blocked spot -> next angle", function()
    world()
    F.luis.loc = { X = 600, Y = 0, Z = 0 } -- Luis stands right where the first spot would be... on the far side
    F.bot.loc = { X = 300, Y = 0, Z = 0 }
    local pt = sleep.shelter_point(F.bot)
    truthy(pt, "a spot")
    local dx, dy = pt.X - 600, pt.Y
    truthy(math.sqrt(dx * dx + dy * dy) >= sleep.SHELTER_PLAYER_CLEAR_CM, "clear of Luis")
end)

test("a free bed within reach: direct Sleep; Luis's claimed bed and other shelters are never used", function()
    world()
    bed("Bed_Luis", 350, { requires_claim = true, claimant = "Zezima" })
    eq(H("sleep", { mode = "bed" }).reason, "nothing_in_range")
    eq(H("sleep", { target = "Bed_Luis" }).reason, "unknown_target")
    bed("Bed_Spare", 420, { requires_claim = true })
    local r = H("sleep", { mode = "bed" })
    eq(r.ok, true, tostring(r.reason)); eq(r.data.bed.id, "Bed_Spare"); eq(F.calls[1], "Claim"); eq(F.calls[2], "Sleep")
    H("wake"); eq(F.calls[#F.calls], "StopSleeping")
    -- someone else's shelter is not a bed for the bot
    world()
    local other = obj("BP_Magic_SummonShelter_C /Game/L.BP_Magic_SummonShelter_C_77")
    bed("Other", 350, { owner = other })
    r = H("sleep", {})
    eq(r.data.mode, "shelter", "spawned its own")
end)

test("a far bed: walk, then Sleep from ~3 m; blocked by the bed's own collision close by: Sleep anyway", function()
    world()
    bed("Bed_Far", 3000)
    eq(H("sleep", { mode = "bed" }, { id = "s1" }), nil, "async")
    F.action.step(F.action)
    eq(F.calls[1], "MoveToActor")
    F.bot.loc.X = 2750; F.now = 1000
    F.action.step(F.action)
    eq(F.finished[1].ok, true); eq(F.finished[1].data.mode, "bed")
    -- stuck 4 m short
    sleep.wake(F.bot); F.finished = {}
    F.bot.loc.X = 300
    H("sleep", { mode = "bed" }, { id = "s2" })
    F.bot.loc.X = 2600
    for _ = 1, 7 do F.now = F.now + 1000; if F.action then F.action.step(F.action) end end
    eq(F.finished[1].ok, true, "within BED_DIRECT_MAX_CM")
    -- stuck far away: path_blocked for mode=bed, shelter fallback for auto
    sleep.wake(F.bot); F.finished = {}
    F.bot.loc.X = 300
    H("sleep", { mode = "bed" }, { id = "s3" })
    for _ = 1, 7 do F.now = F.now + 1000; if F.action then F.action.step(F.action) end end
    eq(F.finished[1].reason, "path_blocked")
    F.finished = {}
    H("sleep", { mode = "auto" }, { id = "s4" })
    for _ = 1, 7 do F.now = F.now + 1000; if F.action then F.action.step(F.action) end end
    eq(F.finished[1].ok, true); eq(F.finished[1].data.mode, "shelter"); eq(F.finished[1].data.after, "path_blocked")
end)

test("reflex: Luis's IsSleeping true -> shelter + Sleep; false -> wake, shelter removed, follow resumed", function()
    world()
    F.action = { kind = "follow", player = "256" }
    sleep.tick()
    eq(#F.calls, 0, "Luis awake: nothing")
    F.luis.PlayerRestComponent.IsSleeping = true
    sleep.tick()
    eq(F.bot.PlayerRestComponent.IsSleeping, true); eq(F.calls[1], "SpawnActor")
    sleep.tick()
    eq(count("SpawnActor"), 1, "once per sleep")
    F.luis.PlayerRestComponent.IsSleeping = false
    F.bot.PlayerRestComponent.IsSleeping = false -- the game woke both (as seen live)
    sleep.tick()
    eq(F.calls[#F.calls], "SetLifeSpan"); eq(count("StopSleeping"), 0, "already awake: no StopSleeping")
    eq(F.follows[1], "256")
end)

test("reflex prefers a free bed close by, a far one is skipped for a shelter", function()
    world()
    bed("Bed_Near", 500)
    F.luis.PlayerRestComponent.IsSleeping = true
    sleep.tick()
    eq(F.calls[1], "Sleep"); eq(count("SpawnActor"), 0)
    world()
    bed("Bed_Far", 5000)
    F.luis.PlayerRestComponent.IsSleeping = true
    sleep.tick()
    eq(F.calls[1], "SpawnActor")
end)

test("state extender reports sleeping flags", function()
    world()
    local d = F.extender({}, F.bot)
    eq(d.sleeping, false); eq(d.luis_sleeping, false)
    eq(H("sleep", { mode = "nap" }).reason, "invalid_args")
end)

print(("test_sleep: %d passed, %d failed"):format(passed, #failed))
os.exit(#failed == 0 and 0 or 1)
