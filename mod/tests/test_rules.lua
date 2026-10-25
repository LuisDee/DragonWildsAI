-- Offline unit tests for the reflex rules engine (mod/body/rules.lua) and its wiring into the
-- combat behaviour tree next to the spells reflexes (body/spells.lua install_combat_hooks).
-- Usage: lua mod/tests/test_rules.lua <empty_temp_dir>
-- Covers: validation (sensable triggers only -> cant_sense; actions -> not_implemented), per-enemy
-- storage (replace on the same trigger, limits, list filters, clear), persistence through a store,
-- the bridge handlers (probe, read-back, warnings), the telegraph sensor (attack-state poll, once
-- per attack, notify_threat), every trigger, every action, the hook order in body/combat.lua, and
-- the spells reflex gate by the catalog's verified-in-game route status.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../?.lua;" .. here .. "/../scripts/?.lua;" .. package.path
local tmpdir = arg and arg[1] or nil
local jsonutil = require("jsonutil")
local rules = require("body.rules")
local spells = require("body.spells")
local combat = require("body.combat")

-- =============================================================================== harness
local passed, failed = 0, {}
local function test(name, fn)
    rules._reset(); spells._reset(); combat._reset()
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed[#failed + 1] = name .. ": " .. tostring(err); print("FAIL " .. name .. "\n     " .. tostring(err)) end
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
    a.HealthComponent = obj("HealthComponent", { GetAuthoritativeHealth = function() return a.hp end })
    a.HealthComponent.MaxHealth = a.max
    return a
end

local function reset_world()
    F = { calls = {}, players = {}, puppets = {}, ais = {}, objects = {} }
    F.world = obj("World /Game/Maps/L_World", {
        SpawnActor = function(_, cls, loc)
            F.calls[#F.calls + 1] = { "SpawnActor", cls, loc }
            local ex = actor("BP_WindstepExplosion_C /Game/L.BP_WindstepExplosion_C_" .. #F.calls, loc.X, loc.Y, loc.Z)
            ex.SetOwner = function() end
            ex.SetLifeSpan = function() end
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
    local c = obj("AIController /Game/L.AIController_1", {
        MoveToLocation = function(_, dest, accept) F.calls[#F.calls + 1] = { "MoveToLocation", dest, accept }; return 2 end,
        MoveToActor = function(_, goal, accept) F.calls[#F.calls + 1] = { "MoveToActor", goal, accept }; return 2 end,
        K2_SetFocus = function(_, t) F.calls[#F.calls + 1] = { "K2_SetFocus", t } end,
    })
    p.GetController = function() return c end
    p.GetWorld = function() return F.world end
    p.instances = {}
    p.GameplayEffectsComponent = obj("DominionGameplayEffectsComponent", {
        ReplicatedInstances = { ForEach = function(_, fn) for i, g in ipairs(p.instances) do fn(i, { get = function() return g end }) end end },
        InstantiateGameplayEffect = function(_, cls)
            F.calls[#F.calls + 1] = { "InstantiateGameplayEffect", cls }
            p.instances[#p.instances + 1] = obj("BP_TempestShieldGameplayEffectInstance_C /x.y")
        end,
    })
    F.puppets[#F.puppets + 1] = p
    return p
end

local function ai(name, x, y, z)
    local n = #F.ais + 1
    local a = actor("BP_AI_" .. name .. "_Character_C /Game/L.BP_AI_" .. name .. "_Character_C_" .. n, x, y, z)
    a.IsFollower = function() return false end
    a.AiHitReactionsComponent = obj("AiHitReactionsComponent", { IsStumbling = function() return a.stumbling == true end })
    a.CurrentAttack = { AttackData = nil }
    a.AiAttackComponent = obj("BP_GiantRat_AiAttackComponent_C /Game/L.Comp_" .. n, { CurrentAttack = a.CurrentAttack })
    F.ais[#F.ais + 1] = a
    return a
end

local function start_attack(a, atk)
    a.CurrentAttack.AttackData = atk and obj("ATK_" .. atk .. "_C /Game/AI/ATK_" .. atk .. ".Default__ATK_" .. atk .. "_C") or nil
end

local function count_calls(kind)
    local n = 0
    for _, c in ipairs(F.calls) do if c[1] == kind then n = n + 1 end end
    return n
end

local clock_t = 1000
local function setup(opts)
    reset_world()
    clock_t = 1000
    local so = { clock = function() return clock_t end, allow_unverified = true }
    for k, v in pairs(opts or {}) do so[k] = v end
    spells.configure(so)
    F.objects[spells.PATHS.explosion_windstep] = obj("BlueprintGeneratedClass " .. spells.PATHS.explosion_windstep)
    F.objects[spells.META.USD_TempestShield.effect] = obj("BlueprintGeneratedClass " .. spells.META.USD_TempestShield.effect)
    rules.configure({ spells = spells, combat = combat })
end

local function ctx_for(p, t, now, act)
    act = act or { target = t, target_id = t and t._full:match("([%w_]+)$") }
    return { a = act, p = p, t = t, now = now or 0 }
end

-- =============================================================================== validation
test("validate: sensable triggers, enemy keys, spell resolution", function()
    setup()
    local r = assert(rules.validate({ enemy = "Kalphites", trigger = { kind = "telegraph" },
                                      actions = { { kind = "evade" }, { kind = "cast", spell = "wind stomp", target = "self" } } }))
    eq(r.enemy, "kalphite"); eq(r.trigger.near_m, rules.TELEGRAPH_NEAR_M); eq(r.actions[2].spell, "USD_Windstep")
    eq(r.actions[1].distance_m, rules.EVADE_M); eq(r.cooldown_s, rules.DEFAULT_COOLDOWN_S)
    eq(assert(rules.validate({ trigger = "enemy_stunned", actions = { "focus_target" } })).enemy, "*", "default scope = any")
    eq(assert(rules.validate({ enemy = "any", trigger = { kind = "own_hp_below", value = 40 }, actions = { "retreat" } })).enemy, "*")
    local _, reason, data = rules.validate({ trigger = { kind = "boss_enrages" }, actions = { "evade" } })
    eq(reason, "cant_sense"); eq(data.sensable[1], "telegraph")
    _, reason = rules.validate({ trigger = "telegraph", actions = { "block" } })
    eq(reason, "not_implemented")
    _, reason = rules.validate({ trigger = { kind = "own_hp_below", value = 150 }, actions = { "retreat" } })
    eq(reason, "invalid_args")
    _, reason = rules.validate({ trigger = { kind = "own_hp_below" }, actions = { "retreat" } })
    eq(reason, "invalid_args", "missing value")
    _, reason = rules.validate({ trigger = "telegraph", actions = { { kind = "cast", spell = "fireballz" } } })
    eq(reason, "invalid_args")
    _, reason = rules.validate({ trigger = "telegraph", actions = { { kind = "cast", spell = "shield", target = "luis" } } })
    eq(reason, "invalid_args", "bad cast target")
    _, reason = rules.validate({ trigger = "telegraph", actions = {} })
    eq(reason, "invalid_args")
    _, reason = rules.validate({ trigger = "telegraph", actions = { "evade", "evade", "evade", "evade" } })
    eq(reason, "invalid_args", "too many actions")
    eq(assert(rules.validate({ trigger = { kind = "spell_ready", spell = "shield" }, actions = { { kind = "cast", spell = "shield" } } })).trigger.spell,
       "USD_TempestShield")
end)

test("store: per-enemy, replace on the same trigger, list filter, clear", function()
    setup()
    local a = assert(rules.add({ enemy = "kalphite", trigger = "telegraph", actions = { "evade" } }))
    local b, replaced = rules.add({ enemy = "kalphite", trigger = "telegraph", actions = { "retreat" } })
    eq(b.id, a.id, "same trigger replaces"); eq(replaced, true)
    local c = assert(rules.add({ enemy = "*", trigger = { kind = "own_hp_below", value = 30 }, actions = { "retreat" } }))
    local d = assert(rules.add({ enemy = "goblin", trigger = { kind = "enemy_hp_below", value = 20 }, actions = { "focus_target" } }))
    eq(#rules.list(), 3)
    local ids = {}
    for _, r in ipairs(rules.list("KalphiteSoldier")) do ids[r.id] = true end
    truthy(ids[a.id] and ids[c.id] and not ids[d.id], "kalphitesoldier sees kalphite + * rules")
    eq(#rules.clear({ id = d.id }), 1)
    eq(#rules.clear({ enemy = "Kalphite" }), 1)
    eq(#rules.list(), 1)
    eq(#rules.clear({ all = true }), 1)
    eq(#rules.list(), 0)
    for i = 1, rules.MAX_RULES_PER_ENEMY do
        assert(rules.add({ enemy = "wolf", trigger = { kind = "enemy_hp_below", value = i }, actions = { "evade" } }))
    end
    local _, reason = rules.add({ enemy = "wolf", trigger = { kind = "enemy_hp_below", value = 50 }, actions = { "evade" } })
    eq(reason, "invalid_args", "per-enemy limit")
end)

test("persistence: rules survive a reload through the store (JSON round trip), ids continue", function()
    setup()
    local disk
    local store = {
        load = function() return disk and jsonutil.decode(disk) or nil end,
        save = function(t) disk = jsonutil.encode(t); return true end,
    }
    rules.configure({ store = store })
    local bridge = { handlers = {} }
    rules.register(bridge, nil, { spells = spells, combat = combat, store = store })
    local r = bridge.handlers.set_reflex_rule({ enemy = "kalphite", trigger = { kind = "telegraph" },
                                                actions = { { kind = "evade" }, { kind = "cast", spell = "windstep", target = "self" } },
                                                note = "every time the kalphite raises its claws, windstep away" })
    eq(r.ok, true); eq(r.data.persisted, true)
    truthy(disk:find("kalphite", 1, true) and disk:find("USD_Windstep", 1, true))
    if tmpdir then -- keep a copy of what the bot state section looks like
        local f = io.open(tmpdir .. "/reflex_rules.json", "wb"); if f then f:write(disk); f:close() end
    end
    rules._reset(); spells.configure({ clock = function() return clock_t end })
    local b2 = { handlers = {} }
    rules.register(b2, nil, { spells = spells, combat = combat, store = store })
    local l = b2.handlers.list_rules({}).data.rules
    eq(#l, 1); eq(l[1].enemy, "kalphite"); eq(l[1].actions[2].spell, "USD_Windstep"); eq(l[1].note:sub(1, 10), "every time")
    local r2 = b2.handlers.set_reflex_rule({ enemy = "goblin", trigger = "enemy_stunned", actions = { "focus_target" } })
    truthy(r2.data.rule.id ~= l[1].id, "fresh id after reload")
end)

test("bridge: probe, missing args, cant_sense, read-back + warnings, clear", function()
    setup({ allow_unverified = false })
    local bridge = { handlers = {} }
    rules.register(bridge, nil, { spells = spells, combat = combat })
    for _, h in ipairs({ "set_reflex_rule", "list_rules", "clear_rule" }) do
        eq(bridge.handlers[h]({ probe = true }).data.probe, true, h .. " probe")
    end
    eq(#rules.list(), 0, "probe never acts")
    eq(bridge.handlers.set_reflex_rule({}).reason, "invalid_args")
    local r = bridge.handlers.set_reflex_rule({ trigger = { kind = "boss_enrages" }, actions = { { kind = "evade" } } })
    eq(r.ok, false); eq(r.reason, "cant_sense")
    r = bridge.handlers.set_reflex_rule({ enemy = "kalphite", trigger = { kind = "telegraph" },
                                          actions = { { kind = "evade" }, { kind = "cast", spell = "windstep", target = "self" } } })
    eq(r.ok, true); eq(r.data.rule.enemy, "kalphite")
    eq(r.data.warnings[1].spell, "USD_Windstep"); eq(r.data.warnings[1].reason, "not_implemented", "unverified route warns")
    eq(bridge.handlers.clear_rule({}).reason, "invalid_args")
    eq(bridge.handlers.clear_rule({ id = "r999" }).reason, "unknown_target")
    local c = bridge.handlers.clear_rule({ id = r.data.rule.id })
    eq(c.ok, true); eq(c.data.removed[1], r.data.rule.id)
    eq(#bridge.handlers.list_rules({}).data.rules, 0)
end)

-- =============================================================================== triggers + actions
test("telegraph sensor: attack start is one event, feeds combat.notify_threat", function()
    setup()
    local p = puppet(0, 0, 0)
    local k = ai("KalphiteWorker", 300, 0, 0)
    local ctx = ctx_for(p, k, 0)
    rules.combat_tick(ctx)
    eq(#rules._S.events, 0)
    start_attack(k, "Kalphite_Claw")
    ctx.now = 250
    rules.combat_tick(ctx)
    eq(#rules._S.events, 1); eq(rules._S.events[1].attack, "ATK_Kalphite_Claw_C")
    truthy(combat.threat and combat.threat.at == 250, "notify_threat")
    eq(ctx.threat, combat.threat)
    ctx.now = 500
    rules.combat_tick(ctx)
    eq(#rules._S.events, 1, "same attack still running: no new event")
    start_attack(k, nil); ctx.now = 750; rules.combat_tick(ctx)
    start_attack(k, "Kalphite_Claw"); ctx.now = 1000; rules.combat_tick(ctx)
    eq(#rules._S.events, 2, "a new attack is a new event")
    ctx.now = 5000; rules.combat_tick(ctx)
    eq(#rules._S.events, 0, "events expire")
end)

test("rule: kalphite telegraph -> evade away + Windstep at self, once per attack", function()
    setup()
    local p = puppet(0, 0, 0)
    player(-5000, 0, 0) -- Luis 50 m away: the stomp is safe
    local k = ai("KalphiteSoldier", 300, 0, 0)
    assert(rules.add({ enemy = "kalphite", trigger = "telegraph",
                       actions = { { kind = "evade" }, { kind = "cast", spell = "windstep", target = "self" } } }))
    local act = { target = k }
    local ctx = ctx_for(p, k, 0, act)
    eq(rules.combat_tick(ctx), nil, "nothing yet")
    start_attack(k, "Kalphite_Claw")
    ctx.now = 250
    eq(rules.combat_tick(ctx), "r1")
    eq(F.calls[1][1], "MoveToLocation")
    truthy(F.calls[1][2].X < -300, "steps away from the kalphite (it is at +X)")
    eq(count_calls("SpawnActor"), 1, "windstep cast")
    eq(F.calls[2][3].X, 0, "stomp at the companion's position")
    ctx.now = 500
    eq(rules.combat_tick(ctx), "rules_busy", "evade window keeps the BT from re-approaching")
    ctx.now = 4000; clock_t = clock_t + 4
    eq(rules.combat_tick(ctx), nil, "same attack: fires once")
    eq(count_calls("MoveToLocation"), 1)
    start_attack(k, nil); ctx.now = 4250; rules.combat_tick(ctx)
    start_attack(k, "Kalphite_Claw"); ctx.now = 4500
    eq(rules.combat_tick(ctx), "r1", "next attack fires again")
    eq(count_calls("MoveToLocation"), 2)
end)

test("rule scope: a kebbit attack does not fire a kalphite rule; '*' rules fire for anything", function()
    setup()
    local p = puppet(0, 0, 0)
    local kb = ai("Kebbit", 300, 0, 0)
    assert(rules.add({ enemy = "kalphite", trigger = "telegraph", actions = { "evade" } }))
    start_attack(kb, "Kebbit_Attack_01")
    eq(rules.combat_tick(ctx_for(p, kb, 250)), nil)
    eq(count_calls("MoveToLocation"), 0)
    assert(rules.add({ enemy = "*", trigger = { kind = "telegraph", near_m = 2 }, actions = { "evade" } }))
    start_attack(kb, nil); rules.combat_tick(ctx_for(p, kb, 500))
    start_attack(kb, "Kebbit_Attack_01")
    eq(rules.combat_tick(ctx_for(p, kb, 750)), nil, "near_m 2: the kebbit 3 m away is too far")
    kb.loc.X = 150
    start_attack(kb, nil); rules.combat_tick(ctx_for(p, kb, 1000))
    start_attack(kb, "Kebbit_Attack_01")
    truthy(rules.combat_tick(ctx_for(p, kb, 1250)), "within near_m")
end)

test("rule: Windstep at self near Luis is refused (unsafe) but the evade still runs", function()
    setup()
    local p = puppet(0, 0, 0)
    player(400, 0, 0) -- Luis 4 m away
    local k = ai("KalphiteWorker", 300, 0, 0)
    assert(rules.add({ enemy = "kalphite", trigger = "telegraph",
                       actions = { { kind = "evade" }, { kind = "cast", spell = "windstep", target = "self" } } }))
    start_attack(k, "Kalphite_Claw")
    eq(rules.combat_tick(ctx_for(p, k, 250)), "r1")
    eq(count_calls("MoveToLocation"), 1); eq(count_calls("SpawnActor"), 0, "never stomp near a player")
end)

test("HP triggers: own_hp_below -> retreat to Luis; luis_hp_below; enemy_hp_below -> cast shield", function()
    setup()
    local p = puppet(0, 0, 0)
    local luis = player(-3000, 0, 0)
    local k = ai("KalphiteWorker", 300, 0, 0)
    assert(rules.add({ enemy = "*", trigger = { kind = "own_hp_below", value = 30 }, actions = { { kind = "retreat", duration_s = 2 } } }))
    local act = {}
    local ctx = ctx_for(p, k, 0, act)
    eq(rules.combat_tick(ctx), nil)
    p.hp = 20
    ctx.now = 250
    eq(rules.combat_tick(ctx), "r1")
    eq(F.calls[1][1], "MoveToActor"); eq(F.calls[1][2], luis)
    ctx.now = 2000; eq(rules.combat_tick(ctx), "rules_busy")
    ctx.now = 2300; eq(rules.combat_tick(ctx), nil, "rule cooldown 3 s")
    ctx.now = 3300; eq(rules.combat_tick(ctx), "r1", "level trigger fires again after its cooldown")
    rules.clear({ all = true }); p.hp = 100; act._rules_busy_until = nil
    assert(rules.add({ enemy = "*", trigger = { kind = "luis_hp_below", value = 50 }, actions = { "retreat" } }))
    ctx.now = 10000; eq(rules.combat_tick(ctx), nil)
    luis.hp = 40; ctx.now = 10250; eq(rules.combat_tick(ctx), "r2")
    rules.clear({ all = true }); act._rules_busy_until = nil
    assert(rules.add({ enemy = "kalphite", trigger = { kind = "enemy_hp_below", value = 25 },
                       actions = { { kind = "cast", spell = "shield" } } }))
    ctx.now = 20000; eq(rules.combat_tick(ctx), nil)
    k.hp = 20; ctx.now = 20250
    eq(rules.combat_tick(ctx), "r3"); eq(count_calls("InstantiateGameplayEffect"), 1)
end)

test("cluster_at_least -> Windstep at the cluster centre; enemy_stunned -> focus_target", function()
    setup()
    local p = puppet(0, 0, 0)
    player(-9000, 0, 0)
    local t = ai("KalphiteWorker", 3000, 0, 0)
    ai("KalphiteWorker", 1200, 0, 0)
    assert(rules.add({ enemy = "kalphite", trigger = { kind = "cluster_at_least", value = 3 },
                       actions = { { kind = "cast", spell = "windstep", target = "cluster" } } }))
    eq(rules.combat_tick(ctx_for(p, t, 0)), nil, "only 1 enemy near the target")
    rules._S.last_fired = {}
    ai("KalphiteWorker", 3200, 0, 0); ai("KalphiteWorker", 3000, 200, 0)
    -- the sensor only sees enemies within SENSE_CM of the companion: walk in
    p.loc.X = 2000
    eq(rules.combat_tick(ctx_for(p, t, 250)), "r1")
    local sp = F.calls[#F.calls]
    eq(sp[1], "SpawnActor"); truthy(sp[3].X > 2500, "centre of the 3-kalphite cluster, not the lone one")
    rules.clear({ all = true })
    local other = ai("KalphiteSoldier", 2300, 0, 0)
    assert(rules.add({ enemy = "kalphite", trigger = "enemy_stunned", actions = { "focus_target" } }))
    local act = { target = t, target_id = "x" }
    local ctx = ctx_for(p, other, 1000, act)
    eq(rules.combat_tick(ctx), nil, "not stunned")
    other.stumbling = true
    ctx.now = 1250
    eq(rules.combat_tick(ctx), "r2")
    eq(act.target, other, "the attack now targets the stunned enemy"); eq(F.calls[#F.calls][1], "K2_SetFocus")
end)

test("switch_weapon respects the inventory gate", function()
    setup()
    local p = puppet(0, 0, 0)
    local k = ai("KalphiteWorker", 300, 0, 0)
    local equipped = {}
    local gear = { read = function() return { right = nil } end,
                   equip = function(_, _, path) equipped[#equipped + 1] = path; return { ok = true, data = { slot = "right" } } end }
    local path = "/Game/Gameplay/Items/Equipment/Held/Club/ITEM_Club_Wood.ITEM_Club_Wood"
    local fake_combat = { data = function() return { items = { [path] = { primary = "x" } } } end,
                          notify_threat = combat.notify_threat }
    rules.configure({ gear = gear, combat = fake_combat })
    assert(rules.add({ enemy = "kalphite", trigger = { kind = "enemy_hp_below", value = 90 },
                       actions = { { kind = "switch_weapon", item = "ITEM_Club_Wood" } } }))
    k.hp = 50
    eq(rules.combat_tick(ctx_for(p, k, 0)), nil, "no inventory store: refused")
    local bag = {}
    rules.configure({ inventory = { count = function(id) return bag[id] or 0 end, take = function() return true end } })
    rules._S.last_fired = {}
    eq(rules.combat_tick(ctx_for(p, k, 250)), nil, "not owned: refused")
    eq(#equipped, 0)
    bag.ITEM_Club_Wood = 1
    rules._S.last_fired = {}
    eq(rules.combat_tick(ctx_for(p, k, 500)), "r1")
    eq(equipped[1], path)
end)

-- =============================================================================== combat wiring
test("hook order in body/combat.lua: rules first, then spells; the spells reflex gate", function()
    setup({ allow_unverified = false })
    spells.install_combat_hooks(combat)
    rules.install(combat)
    eq(combat.hooks.on_tick[1].name, "rules"); eq(combat.hooks.on_tick[2].name, "spells")
    local p = puppet(0, 0, 0)
    player(-9000, 0, 0)
    local t = ai("KalphiteWorker", 300, 0, 0)
    p.hp = 20 -- low HP: shield wanted
    local st = spells.reflex_status()
    eq(st.USD_TempestShield.on, false, "self_effect not verified in game")
    local r = combat._run_hooks("on_tick", ctx_for(p, t, 0))
    eq(r, nil, "no rule, shield route off: nothing")
    eq(count_calls("InstantiateGameplayEffect"), 0)
    -- the catalog records the route as verified in game (e.g. with Fire Spirit): Tempest Shield still
    -- needs its own test (null-PC Attack level); once that is recorded too, the reflex turns on
    spells.configure({ catalog = { spells = {}, routes = { self_effect = { verified = true, note = "test" } } } })
    eq(spells.reflex_status().USD_TempestShield.on, false, "route alone is not enough for the shield")
    spells.configure({ catalog = { spells = { USD_TempestShield = { verified_in_game = true } },
                                   routes = { self_effect = { verified = true, note = "test" } } } })
    eq(spells.reflex_status().USD_TempestShield.on, true)
    eq(spells.reflex_status().USD_Windstep.on, false, "wind_stomp still unverified")
    local name
    r, name = combat._run_hooks("on_tick", ctx_for(p, t, 1000))
    eq(r, "USD_TempestShield"); eq(name, "spells")
    -- a matching rule wins over the utility reflex
    assert(rules.add({ enemy = "kalphite", trigger = { kind = "own_hp_below", value = 50 }, actions = { "retreat" } }))
    clock_t = clock_t + 100
    r, name = combat._run_hooks("on_tick", ctx_for(p, t, 5000))
    eq(name, "rules"); eq(r, "r1")
end)

test("spells: shield on a fresh telegraph from the rules sensor (unverified allowed)", function()
    setup({ allow_unverified = true })
    spells.install_combat_hooks(combat)
    rules.install(combat)
    local p = puppet(0, 0, 0)
    player(-9000, 0, 0)
    local t = ai("KalphiteWorker", 300, 0, 0)
    local act = {}
    eq(combat._run_hooks("on_tick", ctx_for(p, t, 0, act)), nil, "full HP, no threat")
    start_attack(t, "Kalphite_Claw")
    local ctx = ctx_for(p, t, 600, act)
    local r = combat._run_hooks("on_tick", ctx)
    eq(r, "USD_TempestShield", "telegraph -> shield")
end)

-- =============================================================================== report
print(("test_rules: %d passed, %d failed"):format(passed, #failed))
os.exit(#failed == 0 and 0 or 1)
