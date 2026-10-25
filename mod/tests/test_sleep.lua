-- Offline tests for body/sleep.lua against fake UE objects and a fake skills action slot.
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
    p.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = 0, Z = 0 } end
    p.PlayerRestComponent = obj("BP_Components_Rest_C /x.Rest", { IsSleeping = false })
    p.GetController = function() return ctrl end
    p.PlayerState = obj("DominionPlayerState /x.PS_" .. x, { bIsSpectator = false, bOnlySpectator = false,
                        GetPlayerName = function() return ctrl._name end })
    return p
end

local function bed(id, x, t)
    t = t or {}
    local owner = obj("BP_Bed_C /Game/L." .. id)
    owner.K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end
    local b = obj("BedComponent /Game/L." .. id .. ".Bed", {
        bRequiresClaimingToSleepIn = t.requires_claim == true,
        GetOwner = function() return owner end,
        IsClaimedByAnyPlayer = function(self) return self.claimant ~= nil end,
        IsClaimedByPlayer = function(self, p) return self.claimant_pawn == p end,
        GetClaimingCharacterName = function(self) return self.claimant end,
        claimant = t.claimant,
        CanSleep = function() return F.can_sleep end,
        Claim = function(self, p) F.calls[#F.calls + 1] = "Claim"; self.claimant, self.claimant_pawn = "Claude", p end,
        Sleep = function(_, p) F.calls[#F.calls + 1] = "Sleep"; p.PlayerRestComponent.IsSleeping = true
                    p.PlayerRestComponent.CurrentRestingAreaActor = owner end,
        StopSleeping = function(_, p) F.calls[#F.calls + 1] = "StopSleeping"; p.PlayerRestComponent.IsSleeping = false end,
    })
    F.beds[#F.beds + 1] = b
    return b
end

local function world()
    F = { calls = {}, beds = {}, can_sleep = true, action = nil, now = 0, finished = {}, follows = {} }
    local pc = obj("BP_PlayerController_C /x.PC", { _name = "Zezima" })
    local ai = obj("AIController /x.AI", { _name = "Claude",
        MoveToActor = function() F.calls[#F.calls + 1] = "MoveToActor"; return 2 end })
    F.luis = pawn("BP_PlayerCharacter_C /x.Luis", 0, pc)
    F.bot = pawn("BP_PlayerCharacter_C /x.Bot", 300, ai)
    _G.FindAllOf = function(cls)
        if cls == "BP_PlayerCharacter_C" then return { F.luis, F.bot } end
        if cls == "BedComponent" then return F.beds end
        return {}
    end
    _G.StaticFindObject = function() return obj("InGameTimeFunctionLibrary /Script/Dominion.Default__X",
        { IsNighttime = function() return F.night end }) end
    local skills = {
        now = function() return F.now end,
        current = function() return F.action end,
        _start = function(a) a.started = F.now; F.action = a end,
        _finish = function(a, ok, reason, data) a.done = true; F.action = nil; F.finished[#F.finished + 1] = { ok = ok, reason = reason, data = data } end,
        _move_to_actor = function(c, g, acc) return c:MoveToActor(g, acc) end,
        _probe_guard = function(name, fn) return function(args, ctx)
            if type(args) == "table" and args.probe then return { ok = true, data = { probe = true, tool = name } } end
            return fn(args or {}, ctx or {}) end end,
        add_state_extender = function(n, fn) F.extender = fn end,
    }
    local puppet = { get = function() return F.bot end, ensure_ready = function() return F.bot end }
    F.bridge = { handlers = { follow = function(args) F.follows[#F.follows + 1] = args.player; return { ok = true } end } }
    sleep.register(F.bridge, nil, { skills = skills, puppet = puppet, no_loop = true })
    return F
end

local H = function(name, args, ctx) return F.bridge.handlers[name](args or {}, ctx or { id = "c1" }) end

-- ------------------------------------------------------------------ tests
test("handlers registered, probe-safe, status read-only", function()
    world()
    for _, h in ipairs({ "sleep", "wake", "sleep_status", "night_skip" }) do eq(H(h, { probe = true }).data.probe, true, h) end
    eq(#F.calls, 0)
    F.night = true
    local s = H("sleep_status").data
    eq(s.night, true); eq(s.bot_sleeping, false); eq(s.luis_sleeping, false)
end)

test("sleep in a bed within reach: CanSleep then Sleep, verified by IsSleeping", function()
    world()
    bed("Bed_1", 400)
    local r = H("sleep", { target = "nearest" })
    eq(r.ok, true, tostring(r.reason)); eq(r.data.mode, "bed"); eq(r.data.resting_area, "Bed_1")
    eq(F.calls[1], "Sleep")
    eq(H("sleep", {}).data.already, true)
    local w = H("wake")
    eq(w.ok, true); eq(w.data.was, "bed"); eq(F.calls[#F.calls], "StopSleeping")
end)

test("CanSleep false -> verification_failed, nothing called", function()
    world()
    bed("Bed_1", 400)
    F.can_sleep = false
    local r = H("sleep", { mode = "bed" })
    eq(r.ok, false); eq(r.reason, "verification_failed"); eq(#F.calls, 0)
end)

test("never uses a bed claimed by someone else; claims an unclaimed bed that needs it", function()
    world()
    bed("Bed_Luis", 350, { requires_claim = true, claimant = "Zezima" })
    local r = H("sleep", { mode = "bed" })
    eq(r.reason, "nothing_in_range", "Luis's bed is not usable")
    eq(H("sleep", { target = "Bed_Luis" }).reason, "unknown_target")
    bed("Bed_Spare", 420, { requires_claim = true })
    r = H("sleep", { mode = "bed" })
    eq(r.ok, true, tostring(r.reason)); eq(r.data.bed.id, "Bed_Spare")
    eq(F.calls[1], "Claim"); eq(F.calls[2], "Sleep")
end)

test("a far bed: async walk, then sleep on arrival; stuck -> path_blocked", function()
    world()
    bed("Bed_Far", 3000)
    local r = H("sleep", {}, { id = "s1" })
    eq(r, nil, "async")
    truthy(F.action and F.action.kind == "sleep")
    F.action.step(F.action)
    eq(F.calls[1], "MoveToActor")
    F.bot.loc.X = 2900; F.now = 1000
    F.action.step(F.action)
    eq(F.finished[1].ok, true); eq(F.finished[1].data.mode, "bed")
    -- stuck
    sleep.wake(F.bot); F.finished = {}
    F.bot.loc.X = 300
    H("sleep", {}, { id = "s2" })
    for t = 1, 8 do F.now = F.now + 1000; if F.action then F.action.step(F.action) end end
    eq(F.finished[1].reason, "path_blocked")
end)

test("no bed: auto falls back to the rest flag; mode=bed refuses", function()
    world()
    eq(H("sleep", { mode = "bed" }).reason, "nothing_in_range")
    local r = H("sleep", {})
    eq(r.ok, true); eq(r.data.mode, "flag"); eq(F.bot.PlayerRestComponent.IsSleeping, true)
    eq(H("wake").ok, true); eq(F.bot.PlayerRestComponent.IsSleeping, false)
    eq(H("sleep", { mode = "nap" }).reason, "invalid_args")
end)

test("reflex: Luis sleeps -> bot sleeps (bed nearby, else flag); Luis wakes -> bot wakes and follows again", function()
    world()
    F.action = { kind = "follow", player = "256" }
    sleep.tick()
    eq(F.bot.PlayerRestComponent.IsSleeping, false, "Luis awake: nothing")
    F.luis.PlayerRestComponent.IsSleeping = true
    sleep.tick()
    eq(F.bot.PlayerRestComponent.IsSleeping, true, "no bed: flag")
    sleep.tick()
    F.luis.PlayerRestComponent.IsSleeping = false
    sleep.tick()
    eq(F.bot.PlayerRestComponent.IsSleeping, false, "woke")
    eq(F.follows[1], "256", "resumed following")
    -- with a bed in reach
    bed("Bed_1", 400)
    F.action = nil
    F.luis.PlayerRestComponent.IsSleeping = true
    sleep.tick()
    eq(F.bot.PlayerRestComponent.IsSleeping, true); eq(F.calls[#F.calls], "Sleep")
    F.luis.PlayerRestComponent.IsSleeping = false
    sleep.tick()
    eq(F.calls[#F.calls], "StopSleeping")
end)

test("night_skip valve: spectator flags on the bot PlayerState only, off restores", function()
    world()
    eq(H("night_skip", { mode = "spectator" }).ok, true)
    eq(F.bot.PlayerState.bOnlySpectator, true); eq(F.bot.PlayerState.bIsSpectator, true)
    eq(F.luis.PlayerState.bOnlySpectator, false, "never Luis")
    eq(H("night_skip", { mode = "off" }).ok, true)
    eq(F.bot.PlayerState.bOnlySpectator, false)
    eq(H("night_skip", { mode = "nope" }).reason, "invalid_args")
end)

test("state extender reports sleeping flags", function()
    world()
    local d = F.extender({}, F.bot)
    eq(d.sleeping, false); eq(d.luis_sleeping, false)
end)

print(("test_sleep: %d passed, %d failed"):format(passed, #failed))
os.exit(#failed == 0 and 0 or 1)
