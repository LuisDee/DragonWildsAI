-- Offline unit tests for the spells service (mod/body/spells.lua) against fake UE objects.
-- Usage: lua mod/tests/test_spells.lua
-- Covers name resolution, route selection (META, catalog-derived, modular opt-in), the verified-
-- route gate, cooldowns + global gap, the three cost policies (free / budget / mirror), the
-- wind_stomp safety distance and native call sequence, self_effect verification, held_effect gating,
-- stun detection, pick_cluster, the combat on_tick hook, bridge handlers, and that the real
-- data/spells_26161880.json carries valid usage metadata for every spell.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../?.lua;" .. here .. "/../scripts/?.lua;" .. package.path
local jsonutil = require("jsonutil")
local spells = require("body.spells")

-- =============================================================================== harness
local passed, failed = 0, {}
local function test(name, fn)
    spells._reset()
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed[#failed + 1] = name .. ": " .. tostring(err) end
end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

-- =============================================================================== fake UE
local F
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid ~= false end
function Obj:GetFullName() return self._full end
local function obj(full, t) t = t or {}; t._full = full; return setmetatable(t, Obj) end

local function actor(full, x, y, z, t)
    local a = obj(full, t)
    a.loc = { X = x, Y = y, Z = z }
    a.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    a.hp, a.max = a.hp or 100, a.max or 100
    a.HealthComponent = obj("HealthComponent", {
        GetAuthoritativeHealth = function() return a.hp end, MaxHealth = a.max,
    })
    return a
end

local function reset_world()
    F = { calls = {}, players = {}, puppets = {}, ais = {}, objects = {} }
    F.world = obj("World /Game/Maps/L_World", {
        SpawnActor = function(_, cls, loc)
            local ex = actor("BP_WindstepExplosion_C /Game/L.BP_WindstepExplosion_C_" .. (#F.calls + 1), loc.X, loc.Y, loc.Z)
            F.calls[#F.calls + 1] = { "SpawnActor", cls, loc }
            ex.SetOwner = function(_, o) F.calls[#F.calls + 1] = { "SetOwner", o } end
            ex.SetLifeSpan = function(_, s) F.calls[#F.calls + 1] = { "SetLifeSpan", s } end
            ex.DelayedDamageInfliction = obj("DelayedDamageInflictionComponent", {
                StartDelayedDamage = function(_, d) F.calls[#F.calls + 1] = { "StartDelayedDamage", d } end,
            })
            return ex
        end,
    })
    _G.StaticFindObject = function(path) return F.objects[path] end
    _G.FindAllOf = function(cls)
        if cls == "BP_PlayerCharacter_C" then
            local out = {}
            for _, p in ipairs(F.players) do out[#out + 1] = p end
            for _, p in ipairs(F.puppets) do out[#out + 1] = p end
            return out
        elseif cls == "DominionAICharacter" then return F.ais end
        return {}
    end
end

local function player(x, y, z)
    local p = actor("BP_PlayerCharacter_C /Game/L.BP_PlayerCharacter_C_1", x, y, z)
    local pc = obj("BP_PlayerController_C /Game/L.BP_PlayerController_C_1")
    p.GetController = function() return pc end
    F.players[#F.players + 1] = p
    return p
end

local function puppet(x, y, z)
    local p = actor("BP_PlayerCharacter_C /Game/L.BP_PlayerCharacter_C_99", x, y, z)
    local c = obj("AIController /Game/L.AIController_1")
    p.GetController = function() return c end
    p.GetWorld = function() return F.world end
    p.instances = {}
    p.GameplayEffectsComponent = obj("DominionGameplayEffectsComponent", {
        ReplicatedInstances = {
            ForEach = function(_, fn) for i, g in ipairs(p.instances) do fn(i, { get = function() return g end }) end end,
        },
        InstantiateGameplayEffect = function(_, cls, inst, force)
            F.calls[#F.calls + 1] = { "InstantiateGameplayEffect", cls, inst, force }
            if not F.ge_noop then p.instances[#p.instances + 1] = obj("BP_TempestShieldGameplayEffectInstance_C /x.y") end
        end,
    })
    F.puppets[#F.puppets + 1] = p
    return p
end

local function ai(name, x, y, z, t)
    local a = actor("BP_AI_" .. name .. "_Character_C /Game/L.BP_AI_" .. name .. "_Character_C_" .. (#F.ais + 1), x, y, z, t)
    a.IsFollower = function() return false end
    a.AiHitReactionsComponent = obj("AiHitReactionsComponent", { IsStumbling = function() return a.stumbling == true end })
    F.ais[#F.ais + 1] = a
    return a
end

local clock_t = 1000
local function clock() return clock_t end

local function setup(opts)
    reset_world()
    clock_t = 1000
    local o = { clock = clock, allow_unverified = true }
    for k, v in pairs(opts or {}) do o[k] = v end
    spells.configure(o)
    F.objects[spells.PATHS.explosion_windstep] = obj("BlueprintGeneratedClass " .. spells.PATHS.explosion_windstep)
    F.objects[spells.META.USD_TempestShield.effect] = obj("BlueprintGeneratedClass " .. spells.META.USD_TempestShield.effect)
end

-- =============================================================================== tests
test("resolve by asset, suffix, display name, alias", function()
    setup()
    eq(spells.resolve("USD_TempestShield"), "USD_TempestShield")
    eq(spells.resolve("tempestshield"), "USD_TempestShield")
    eq(spells.resolve("Tempest Shield"), "USD_TempestShield")
    eq(spells.resolve("shield"), "USD_TempestShield")
    eq(spells.resolve("wind stomp"), "USD_Windstep")
    eq(spells.resolve("Trunk Totem"), "USD_PileEmUp")
    eq(spells.resolve("astral projection"), "USD_AxtralProjection")
    eq(spells.resolve("nope"), nil)
    eq(spells.resolve(""), nil)
end)

test("route selection: META, catalog-derived, modular opt-in", function()
    setup()
    eq(spells.route("USD_TempestShield"), "self_effect")
    eq(spells.route("USD_Windstep"), "wind_stomp")
    eq(spells.route("USD_EnchantWeapon_Fire"), "held_effect")
    eq(spells.route("USD_MagicalMending"), "none")
    eq(spells.route("USD_Splinter"), "none")
    spells.configure({ catalog = { spells = { USD_ShadowVeil = { modules = {
        { kind = "SpellModule_GameplayEffect", target = "SpellOwner", effect = "/x/GE_ShadowVeil.GE_ShadowVeil_C" } } } } } })
    eq(spells.route("USD_ShadowVeil"), "self_effect", "catalog self GE")
    spells.configure({ allow_modular = true })
    eq(spells.route("USD_MagicalMending"), "modular")
    eq(spells.route("USD_TempestShield"), "self_effect", "explicit route wins over modular")
end)

test("unverified routes are refused unless allow_unverified", function()
    setup({ allow_unverified = false })
    local ok, reason, data = spells.can_cast("shield")
    eq(ok, false); eq(reason, "not_implemented"); truthy(data.detail:find("not verified"))
    spells.configure({ allow_unverified = true })
    ok = spells.can_cast("shield")
    eq(ok, true)
    ok, reason = spells.can_cast("mending")
    eq(ok, false); eq(reason, "not_implemented")
    ok, reason = spells.can_cast("does not exist")
    eq(ok, false); eq(reason, "unknown_skill")
end)

test("modular route needs the opt-in even when unverified routes are allowed", function()
    setup({ allow_modular = false })
    local ok, reason = spells.can_cast("USD_MagicalMending")
    eq(ok, false); eq(reason, "not_implemented")
    spells.configure({ allow_modular = true })
    ok = spells.can_cast("USD_MagicalMending")
    eq(ok, true)
end)

test("cooldown per spell and the global gap", function()
    setup()
    local p = puppet(0, 0, 0)
    local r = spells.cast(p, "shield")
    eq(r.ok, true, "first cast")
    eq(r.data.cooldown_s, 45)
    local ok, reason, data = spells.can_cast("shield")
    eq(ok, false); eq(reason, "on_cooldown"); truthy(data.remaining_s > 44)
    -- global gap blocks a different spell for MIN_GAP_S
    ok, reason = spells.can_cast("USD_Windstep")
    eq(ok, false); eq(reason, "on_cooldown")
    clock_t = clock_t + 2
    ok = spells.can_cast("USD_Windstep")
    eq(ok, true)
    clock_t = clock_t + 44
    ok = spells.can_cast("shield")
    eq(ok, true, "cooldown over after 45 s")
end)

test("catalog cooldown and runes override the wiki fallback", function()
    setup()
    spells.configure({ catalog = { spells = { USD_TempestShield = { cooldown_s = 60, runes = { Air = 20 } } } } })
    eq(spells.cooldown_s("USD_TempestShield"), 60)
    local r, src = spells.runes("USD_TempestShield")
    eq(r.Air, 20); eq(src, "game")
    local _, src2 = spells.runes("USD_Windstep")
    eq(src2, "wiki")
end)

test("cost policy free ignores runes", function()
    setup({ cost_policy = "free" })
    local p = puppet(0, 0, 0)
    local r = spells.cast(p, "shield")
    eq(r.ok, true); eq(next(r.data.paid), nil)
end)

test("cost policy budget: no store, not enough, then pays after a successful cast", function()
    setup({ cost_policy = "budget" })
    local p = puppet(0, 0, 0)
    local ok, reason = spells.can_cast("shield")
    eq(ok, false); eq(reason, "state_unavailable")
    local bag = { ITEM_Rune_Air = 10 }
    local store = {
        count = function(item) return bag[item] or 0 end,
        take = function(item, n) if (bag[item] or 0) < n then return false end; bag[item] = bag[item] - n; return true end,
    }
    spells.configure({ inventory = store })
    local data
    ok, reason, data = spells.can_cast("shield")
    eq(ok, false); eq(reason, "not_enough_resources"); eq(data.missing.Air, 5)
    bag.ITEM_Rune_Air = 20
    local r = spells.cast(p, "shield")
    eq(r.ok, true); eq(r.data.paid.Air, 15); eq(bag.ITEM_Rune_Air, 5)
end)

test("budget: a failed native call pays nothing and starts no cooldown", function()
    setup({ cost_policy = "budget" })
    local p = puppet(0, 0, 0)
    local bag = { ITEM_Rune_Air = 50 }
    spells.configure({ inventory = { count = function(i) return bag[i] or 0 end,
                                      take = function(i, n) bag[i] = bag[i] - n; return true end } })
    p.GameplayEffectsComponent.InstantiateGameplayEffect = function() error("boom") end
    local r = spells.cast(p, "shield")
    eq(r.ok, false); eq(r.reason, "body_error"); eq(bag.ITEM_Rune_Air, 50)
    eq(spells.remaining_s("USD_TempestShield"), 0)
end)

test("cost policy mirror: only Luis's unlocked spells, perk-gated stomp", function()
    setup({ cost_policy = "mirror" })
    local ok, reason = spells.can_cast("shield")
    eq(ok, false); eq(reason, "state_unavailable")
    spells.configure({ mirror = { unlocked = { USD_Windstep = true } } })
    ok, reason = spells.can_cast("shield")
    eq(ok, false); eq(reason, "not_unlocked")
    ok = spells.can_cast("windstep")
    eq(ok, true, "perks unknown -> spell unlock is enough")
    spells.configure({ mirror = function() return { unlocked = { USD_Windstep = true }, perks = {} } end })
    local data
    ok, reason, data = spells.can_cast("windstep")
    eq(ok, false); eq(reason, "not_unlocked"); eq(data.perk, "PerkV2_Agility_Spell_Windstep_Upgrade")
    spells.configure({ mirror = { unlocked = { USD_Windstep = true }, perks = { PerkV2_Agility_Spell_Windstep_Upgrade = true } } })
    ok = spells.can_cast("windstep")
    eq(ok, true)
end)

test("cost policy mirror_budget: unlock AND runes", function()
    setup({ cost_policy = "mirror_budget" })
    local p = puppet(0, 0, 0)
    local bag = { ITEM_Rune_Air = 100 }
    spells.configure({ mirror = { unlocked = {} },
                       inventory = { count = function(i) return bag[i] or 0 end,
                                     take = function(i, n) bag[i] = bag[i] - n; return true end } })
    local ok, reason = spells.can_cast("shield")
    eq(ok, false); eq(reason, "not_unlocked")
    spells.configure({ mirror = { unlocked = { USD_TempestShield = true } } })
    local r = spells.cast(p, "shield")
    eq(r.ok, true); eq(bag.ITEM_Rune_Air, 85)
end)

test("rank: scores, threshold and ordering", function()
    setup()
    local r = spells.rank({ hp_frac = 0.2, cluster_n = 4, cluster_centre = { X = 0, Y = 0, Z = 0 }, kalphite = true })
    eq(#r, 2); eq(r[1].spell, "USD_TempestShield")
    r = spells.rank({ hp_frac = 1, cluster_n = 2, cluster_centre = { X = 0, Y = 0, Z = 0 } })
    eq(#r, 0)
    r = spells.rank({ hp_frac = 1, threat = true })
    eq(r[1].spell, "USD_TempestShield")
    spells.add_scorer("USD_Bad", function() error("x") end)
    r = spells.rank({ hp_frac = 1, cluster_n = 3, cluster_centre = { X = 1, Y = 2, Z = 3 } })
    eq(r[1].spell, "USD_Windstep"); eq(r[1].target.Y, 2)
    spells.SCORERS.USD_Bad = nil
end)

test("unknown cost policy is rejected", function()
    local ok = pcall(spells.configure, { cost_policy = "cheap" })
    eq(ok, false)
end)

test("wind_stomp refuses a point near a player", function()
    setup()
    local p = puppet(0, 0, 0)
    player(2000, 0, 0)
    local kal = ai("KalphiteWorker", 2900, 0, 0) -- 9 m from the player: inside 1.5 x 7 m
    local r = spells.cast(p, "windstep", kal)
    eq(r.ok, false); eq(r.reason, "unsafe")
    eq(#F.calls, 0, "no native call")
    eq(spells.remaining_s("USD_Windstep"), 0, "no cooldown on refusal")
end)

test("wind_stomp spawns, owns, cleans up; force adds StartDelayedDamage(0)", function()
    setup()
    local p = puppet(0, 0, 0)
    player(-5000, 0, 0)
    local kal = ai("KalphiteWorker", 3000, 0, 0)
    local r = spells.cast(p, "windstep", kal)
    eq(r.ok, true, tostring(r.reason))
    eq(F.calls[1][1], "SpawnActor"); eq(F.calls[1][3].X, 3000)
    eq(F.calls[2][1], "SetOwner"); eq(F.calls[2][2], p)
    eq(F.calls[3][1], "SetLifeSpan")
    eq(#F.calls, 3, "no StartDelayedDamage by default (BeginPlay triggers it)")
    eq(r.data.radius_m, 7)
    clock_t = clock_t + 5
    F.calls = {}
    r = spells.cast(p, "windstep", { 30, 0, 0 }, { trigger = "force" })
    eq(r.ok, true)
    eq(F.calls[3][1], "StartDelayedDamage"); eq(F.calls[3][2], 0.0)
end)

test("wind_stomp without the explosion class loaded is not_implemented", function()
    setup()
    local p = puppet(0, 0, 0)
    F.objects[spells.PATHS.explosion_windstep] = nil
    local r = spells.cast(p, "windstep", { 50, 0, 0 })
    eq(r.ok, false); eq(r.reason, "not_implemented")
end)

test("wind_stomp rejects a bad target", function()
    setup()
    local p = puppet(0, 0, 0)
    local r = spells.cast(p, "windstep", "kalphite")
    eq(r.ok, false); eq(r.reason, "invalid_args")
end)

test("self_effect verifies a new GE instance; no instance -> verification_failed + cooldown", function()
    setup()
    local p = puppet(0, 0, 0)
    local r = spells.cast(p, "shield")
    eq(r.ok, true); eq(r.data.instances_after, 1)
    eq(F.calls[1][1], "InstantiateGameplayEffect"); eq(F.calls[1][3], nil); eq(F.calls[1][4], false)
    clock_t = clock_t + 100
    F.ge_noop = true
    r = spells.cast(p, "shield")
    eq(r.ok, false); eq(r.reason, "verification_failed")
    truthy(spells.remaining_s("USD_TempestShield") > 0, "native call ran: cooldown starts anyway")
end)

test("self_effect with the effect class not loaded", function()
    setup()
    local p = puppet(0, 0, 0)
    F.objects[spells.META.USD_TempestShield.effect] = nil
    local r = spells.cast(p, "shield")
    eq(r.ok, false); eq(r.reason, "not_implemented")
end)

test("cast without a puppet", function()
    setup()
    local r = spells.cast(nil, "shield")
    eq(r.ok, false); eq(r.reason, "companion_down")
end)

test("held_effect needs something in hand", function()
    setup()
    local p = puppet(0, 0, 0)
    local heed = "/Game/Gameplay/UtilityMagic/PerkSpells/EnchantWeapon/HEED_EnchantWeaponFire.HEED_EnchantWeaponFire"
    F.objects[heed] = obj("BP_BaseEnchantWeaponHeldEquipmentEffectData_C " .. heed)
    p.PlayerEquipmentComponent = obj("PlayerEquipmentComponent", {})
    local r = spells.cast(p, "fire enchant")
    eq(r.ok, false); eq(r.reason, "invalid_args")
end)

test("is_target_stunned: stumble, hooked knockdown, presumed after a stomp", function()
    setup()
    local p = puppet(0, 0, 0)
    local k = ai("KalphiteSoldier", 3000, 0, 0)
    local s, d = spells.is_target_stunned(k)
    eq(s, false); eq(d.presumed, false)
    k.stumbling = true
    s, d = spells.is_target_stunned(k)
    eq(s, true); eq(d.stumbling, true)
    k.stumbling = false
    spells.note_knockdown(k, true)
    s, d = spells.is_target_stunned(k)
    eq(s, true); eq(d.knockdown, true)
    spells.note_knockdown(k, false)
    spells.cast(p, "windstep", k)
    s, d = spells.is_target_stunned(k)
    eq(s, false, "presumed is reported but is not proof"); eq(d.presumed, true)
    eq(spells.is_target_stunned(nil), false)
end)

test("pick_cluster finds the densest group", function()
    setup()
    local pts = { { X = 0, Y = 0, Z = 0 }, { X = 300, Y = 0, Z = 0 }, { X = 0, Y = 300, Z = 0 }, { X = 5000, Y = 0, Z = 0 } }
    local c, n = spells.pick_cluster(pts, 700, 3)
    eq(n, 3); truthy(c and c.X < 1000)
    c, n = spells.pick_cluster(pts, 700, 4)
    eq(c, nil); eq(n, 3)
    c, n = spells.pick_cluster({}, 700, 1)
    eq(c, nil); eq(n, 0)
end)

test("combat on_tick hook: shield on low HP, stomp on a cluster, tactics off", function()
    setup()
    local p = puppet(0, 0, 0)
    player(-9000, 0, 0)
    local t = ai("KalphiteWorker", 3000, 0, 0)
    ai("KalphiteWorker", 3200, 0, 0); ai("KalphiteWorker", 3000, 200, 0)
    local hooks = {}
    local combat = { add_hook = function(kind, name, fn) hooks[#hooks + 1] = { kind, name, fn }; return function() end end }
    spells.install_combat_hooks(combat)
    eq(hooks[1][1], "on_tick"); eq(hooks[1][2], "spells")
    p.hp = 30
    local ctx = { a = {}, p = p, t = t, now = 0 }
    eq(spells.combat_tick(ctx), "USD_TempestShield")
    eq(spells.combat_tick(ctx), nil, "eval_ms gate")
    p.hp = 100
    clock_t = clock_t + 2
    ctx.now = 1000
    eq(spells.combat_tick(ctx), "USD_Windstep")
    spells.set_tactics({ stomp = false, shield = false, bogus = 1 })
    eq(spells.tactics().bogus, nil)
    clock_t = clock_t + 10
    ctx.now = 3000
    eq(spells.combat_tick(ctx), nil)
end)

test("bridge handlers: probe, invalid args, list, tactics", function()
    setup()
    local p = puppet(0, 0, 0)
    local bridge = { handlers = {} }
    spells.register(bridge, nil, { puppet = { get = function() return p end },
                                   find_ai = function(id) for _, a in ipairs(F.ais) do if a._full:find(id, 1, true) then return a end end end })
    eq(bridge.handlers.cast({ probe = true }).data.probe, true)
    eq(bridge.handlers.cast({}).reason, "invalid_args")
    eq(bridge.handlers.cast({ spell = "windstep", target = "Nobody" }).reason, "unknown_target")
    local r = bridge.handlers.cast({ spell = "shield" })
    eq(r.ok, true, tostring(r.reason))
    local l = bridge.handlers.spells({}).data.spells
    truthy(#l >= 40)
    eq(bridge.handlers.spell_tactics({ stomp_min = 4 }).data.tactics.stomp_min, 4)
end)

test("list() rows carry role, cost, cooldown, use_when", function()
    setup()
    local roles = {}
    for _, r in ipairs(spells.ROLES) do roles[r] = true end
    for _, row in ipairs(spells.list()) do
        truthy(roles[row.role], row.id .. " role " .. tostring(row.role))
        truthy(type(row.use_when) == "string" and row.use_when ~= "", row.id .. " use_when")
        truthy(type(row.runes) == "table", row.id .. " runes")
    end
end)

test("META roles are valid and every META spell has preconditions", function()
    local roles = {}
    for _, r in ipairs(spells.ROLES) do roles[r] = true end
    for asset, m in pairs(spells.META) do
        truthy(roles[m.role], asset .. " bad role " .. tostring(m.role))
        truthy(type(m.preconditions) == "table" and #m.preconditions > 0, asset .. " preconditions")
        truthy(type(m.use_when) == "string" and #m.use_when > 10, asset .. " use_when")
        if m.route then truthy(spells.ROUTES[m.route], asset .. " route " .. m.route) end
    end
end)

test("data/spells_26161880.json: every spell has usage metadata", function()
    local f = io.open(here .. "/../../data/spells_26161880.json", "rb")
    if not f then return end -- generated in game; optional offline
    local doc = assert(jsonutil.decode(f:read("*a")))
    f:close()
    local roles = {}
    for _, r in ipairs(spells.ROLES) do roles[r] = true end
    local n = 0
    for asset, rec in pairs(doc.spells) do
        n = n + 1
        truthy(type(rec.usage) == "table", asset .. " usage")
        truthy(roles[rec.usage.role], asset .. " role")
        truthy(type(rec.usage.use_when) == "string" and rec.usage.use_when ~= "", asset .. " use_when")
        truthy(type(rec.usage.cooldown_s) == "number", asset .. " cooldown")
        truthy(spells.META[asset], asset .. " missing from META")
    end
    truthy(n >= 50, "spell count " .. n)
    eq(doc.spells.USD_PileEmUp.name, "Trunk Totem")
    eq(doc.spells.USD_TempestShield.runes.Air, 15)
end)

test("merge_catalog adds usage and reports META gaps both ways", function()
    local doc = { spells = { USD_Windstep = { runes = { Air = 5 }, cooldown_s = 3 }, USD_NewThing = { runes = {} } } }
    spells.merge_catalog(doc)
    eq(doc.spells.USD_Windstep.usage.role, "combat_cc")
    eq(doc.spells.USD_NewThing.usage.role, "other")
    eq(doc.meta_missing[1], "USD_NewThing")
    truthy(#doc.meta_not_in_game > 10)
end)

-- =============================================================================== report
print(("test_spells: %d passed, %d failed"):format(passed, #failed))
for _, f in ipairs(failed) do print("FAIL " .. f) end
os.exit(#failed == 0 and 0 or 1)
