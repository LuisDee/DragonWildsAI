-- Offline tests for client_mod/scripts/arbiter.lua and client_mod/scripts/combat.lua: the arbiter
-- with a fake move.lua; combat's pure decision functions; and whole fights against a fake engine
-- (a frame pump, fake pawn/creatures/world items, fake Enhanced Input that turns injected attack
-- presses into server-like damage multicasts, fake inventory). Run:
--   lua client_mod/tests/test_combat.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
math.randomseed(7)

-- ---------------------------------------------------------------- fake engine
local T = 0
local function obj(t, full)
    t.IsValid = function() return not t._dead_obj end
    t.GetFullName = function() return full end
    return t
end
local function fname(s) return { ToString = function() return s end } end
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn, ms = ms, next = T }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = post; return 1, 2 end
local CDOS = {}
function StaticFindObject(path) return CDOS[path] end
local PERKS = { unlocked = {} }

local world = { creatures = {}, items = {}, pcs = {}, injected = {} }
local pawn, pc
local stamina, special = 80, 100
local function new_pawn()
    pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, yaw = 0, hp = 100 }, "BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_1")
    function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    function pawn:K2_GetActorRotation() return { Pitch = 0, Yaw = self.yaw, Roll = 0 } end
    function pawn:AddMovementInput(d, s) self.nudged = (self.nudged or 0) + 1; self.yaw = math.deg(math.atan(d.Y, d.X)) end
    function pawn:BP_GetPowerLevel() return 2 end
    pawn.HealthComponent = obj({ GetAuthoritativeHealth = function() return pawn.hp end, GetMaxHealth = function() return 100 end,
                                 IsDead = function() return pawn.hp <= 0 end }, "C /x")
    pawn.StaminaComponent = obj({ GetStamina = function() return stamina end, GetMaxStamina = function() return 80 end }, "C /x")
    pawn.SpecialChargeComponent = obj({ GetSpecialCharge = function() return special end }, "C /x")
    pawn.PlayerInputBufferInputActions = {
        PrimaryAction = obj({}, "InputAction /Game/IA_PrimaryAction.IA_PrimaryAction"),
        SecondaryAction = obj({}, "InputAction /Game/IA_SecondaryAction.IA_SecondaryAction"),
        SpecialAction = obj({}, "InputAction /Game/IA_SpecialAction.IA_SpecialAction"),
        EvadeAction = obj({}, "InputAction /Game/IA_Player_Evade.IA_Player_Evade"),
        MovementAction = obj({}, "InputAction /Game/IA_Movement.IA_Movement"),
    }
    pawn.LockOnTargetingComponent = obj({ ToggleLockOnInput = obj({}, "InputAction /Game/IA_ToggleLockOnTargeting.IA_ToggleLockOnTargeting") }, "C /x")
    pc = obj({ Pawn = pawn, IsLocalController = function() return true end }, "BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1")
    pc.SkillPerkComponent = obj({ IsPerkUnlocked = function(_, p) return PERKS.unlocked[p:GetFullName():match("([%w_]+)$")] == true end }, "C /x")
    pawn.EvadeComponent = obj({ IsEvading = function() return (world.evading_until or -1) > T end }, "C /x")
end
new_pawn()

local function new_creature(id, name, at, opts)
    opts = opts or {}
    local c = obj({ loc = at, hp = opts.hp or 60, alert = opts.alert or 0 }, "BP_AI_Kebbit_C /Game/L.L:PersistentLevel." .. id)
    function c:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    c.LoadedData = obj({ AIName = fname(name), Archetype = opts.arch or 4, bIsBoss = opts.boss or false }, "AIDataAsset /Game/DA")
    c.HealthComponent = obj({ GetAuthoritativeHealth = function() return c.hp end, GetMaxHealth = function() return opts.hp or 60 end,
                              IsDead = function() return c.hp <= 0 end }, "C /x")
    c.PowerLevel = opts.pl or 1
    c.CurrentAlertnessState = c.alert
    c.IsFollower = function() return false end
    c.DamageComp = obj({ GetOwner = function() return c end }, "C /x")
    world.creatures[#world.creatures + 1] = c
    return c
end
local function new_item(id, at)
    local w = obj({ loc = at }, "BP_WorldItem_C /Game/L.L:PersistentLevel." .. id)
    function w:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    world.items[#world.items + 1] = w
    return w
end

local eis = obj({}, "EnhancedInputLocalPlayerSubsystem /Engine/Transient.EIS_1")
local frame_n = 0
local last_inject = {}
local pending_hits = {}
function eis:InjectInputVectorForAction(action, v)
    local name = action:GetFullName():match("%.([%w_]+)$")
    world.injected[name] = (world.injected[name] or 0) + 1
    world.last_vec = world.last_vec or {}
    world.last_vec[name] = { X = v.X, Y = v.Y }
    local rising = last_inject[name] ~= frame_n - 1
    last_inject[name] = frame_n
    if rising and name == "IA_Player_Evade" then world.evading_until = T + 0.5; world.evade_start = T end
    if rising and name == "IA_SecondaryAction" then world.block_start = T end
    if name == "IA_SecondaryAction" then world.block_last = T end
    if rising and (name == "IA_PrimaryAction" or name == "IA_SpecialAction") and not world.inputs_dead then
        stamina = stamina - (name == "IA_PrimaryAction" and 10 or 0)
        if name == "IA_SpecialAction" then special = special - 25 end
        pending_hits[#pending_hits + 1] = { t = T + 0.3, amount = name == "IA_PrimaryAction" and 12 or 21 }
    end
end

function FindAllOf(cls)
    if cls == "BP_PlayerController_C" or cls == "PlayerController" then return { pc } end
    if cls == "DominionAICharacter" then
        local out = {}
        for _, c in ipairs(world.creatures) do if not c._dead_obj then out[#out + 1] = c end end
        return out
    end
    if cls == "WorldItem" then
        local out = {}
        for _, w in ipairs(world.items) do if not w._dead_obj then out[#out + 1] = w end end
        return out
    end
    return {}
end
function FindFirstOf(cls) if cls == "EnhancedInputLocalPlayerSubsystem" then return eis end end

-- fake damage multicast, as the server sends it: ctx = the victim's damage component, ev = event
local function multicast(victim, instigator, amount)
    local hook = hooks["/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect"]
    if not hook then return end
    local e = { Amount = amount, Instigator = instigator, bIsFatalHit = false,
                TypeDamagesArray = { TypeDamages = { ForEach = function(_, f) f(1, { get = function() return { Types = { GameplayTags = { ForEach = function(_, g) g(1, { get = function() return { TagName = fname("DamageType.Physical.Stab") } end }) end } } } end }) end } },
                TypeDamagesOutcome = { ForEach = function(_, f) f(1, { get = function() return 0 end }) end } }
    local comp = victim == pawn and obj({ GetOwner = function() return pawn end }, "C /x") or victim.DamageComp
    hook({ get = function() return comp end }, { get = function() return e end })
end

-- ---------------------------------------------------------------- fake move / inventory modules
local MV = { mode = "idle", calls = {} }
local fake_move = {}
function fake_move.go_to(log, goal, opts) MV.calls[#MV.calls + 1] = "go_to"; MV.mode, MV.goal, MV.opts, MV.dist = "go_to", goal, opts, nil; return { ok = true, mode = "go_to" } end
function fake_move.follow(log, goal, dist, opts)
    MV.calls[#MV.calls + 1] = "follow:" .. tostring(goal); MV.mode, MV.goal, MV.dist, MV.opts = "follow", goal, dist, opts
    return { ok = true, mode = "follow", target_visible = goal ~= "Nobody" }
end
function fake_move.stop() MV.calls[#MV.calls + 1] = "stop"; MV.mode = "idle"; return { ok = true } end
function fake_move.status() return { mode = MV.mode, target = type(MV.goal) == "string" and MV.goal or nil } end
function fake_move.snapshot() if MV.mode == "idle" then return nil end return { mode = MV.mode, goal = MV.goal, distance_m = MV.dist, opts = { tolerance_m = MV.dist } } end
function fake_move.restore(log, s) MV.calls[#MV.calls + 1] = "restore:" .. tostring(s.goal); MV.mode, MV.goal, MV.dist = s.mode, s.goal, s.distance_m; return { ok = true } end

local held = { right = nil, left = "ITEM_Logging_Axe_Mithril" }
local inv_list = {
    hotbar = {
        { item = "ITEM_Food_Sandwich", name = "Forager's Sandwich", consumable = "food", heal = 10, slot = 0 },
        { item = "ITEM_Drink", name = "Drink", consumable = "drink", slot = 1 },
        { item = "ITEM_Pickaxe_Mithril", slot = 2 }, { item = "ITEM_Logging_Axe_Mithril", slot = 3 },
        { item = "ITEM_Dagger_Bone", slot = 5 }, { item = "ITEM_Torch", slot = 6 }, { item = "ITEM_Shield_Bronze", slot = 7 },
    }, bag = {}, loadout = {},
}
local INV = { equips = {}, uses = {}, interacts = 0 }
local fake_inv = {}
function fake_inv.pawn() return pawn end
function fake_inv.list() return inv_list end
function fake_inv.held() return { right_item = held.right, left_item = held.left } end
local slots = { ITEM_Dagger_Bone = "right", ITEM_Shield_Bronze = "left", ITEM_Torch = "left" }
function fake_inv.equip(log, item)
    INV.equips[#INV.equips + 1] = item
    if item == "ITEM_Logging_Axe_Mithril" or item == "ITEM_Pickaxe_Mithril" then held.right, held.left = nil, item -- live: 2H shows in LEFT only
    elseif slots[item] == "right" then
        if held.right == nil and (held.left == "ITEM_Logging_Axe_Mithril" or held.left == "ITEM_Pickaxe_Mithril") then held.left = nil end
        held.right = item
    else held.left = item end
    return { ok = true, via = "hotbar key" }
end
function fake_inv.use(log, item) INV.uses[#INV.uses + 1] = item; pawn.hp = math.min(100, pawn.hp + 10); return { ok = true, via = "hotbar key" } end
function fake_inv.best_consumable(l, kind) for _, e in ipairs(l.hotbar) do if e.consumable == kind then return e end end end
function fake_inv.interact_target()
    for _, w in ipairs(world.items) do
        if not w._dead_obj and math.sqrt((w.loc.X - pawn.loc.X) ^ 2 + (w.loc.Y - pawn.loc.Y) ^ 2) < 150 then return { actor = w:GetFullName():match("([%w_]+)$") } end
    end
    return { none = true }
end
function fake_inv.press_interact()
    INV.interacts = INV.interacts + 1
    for _, w in ipairs(world.items) do
        if not w._dead_obj and math.sqrt((w.loc.X - pawn.loc.X) ^ 2 + (w.loc.Y - pawn.loc.Y) ^ 2) < 150 then w._dead_obj = true; return { ok = true } end
    end
    return { ok = true }
end

-- ---------------------------------------------------------------- load the modules under test
local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.set_move(fake_move)
A.clock = function() return T end
local Cm = assert(loadfile(root .. "/client_mod/scripts/combat.lua"))()
local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."
Cm.ACTIVITY_PATH = (tmpdir .. "/test_combat_activity.jsonl"):gsub("\\", "/")
os.remove(Cm.ACTIVITY_PATH)
local Dm = assert(loadfile(root .. "/client_mod/scripts/defense.lua"))()
Cm.clock = function() return T end
Cm.set_modules({ move = fake_move, inventory = fake_inv, arbiter = A, defense = Dm })
-- the game's action CDOs (combat.capabilities): perk-gated special and parry
local function perk(name) return obj({}, "SkillPerkData /Game/PerksV2/" .. name .. "." .. name) end
CDOS["/Game/Gameplay/Character/Player/Attacks/Dagger/PA_Attack_Dagger_Special.Default__PA_Attack_Dagger_Special_C"] =
    obj({ RequiredPerk = perk("PerkV2_Attack_MeleeSpecialAttacks") }, "PA_C /x")
CDOS["/Game/Gameplay/Character/Player/Abilities/Block/PA_Block_Shield_Kite_Iron.Default__PA_Block_Shield_Kite_Iron_C"] =
    obj({ bCanParry = true, SkillPerkRequiredToParry = perk("PerkV2_Attack_Parry"), BlockStaminaCost = 10, ParryStaminaCost = 10 }, "PA_C /x")
local function read_activity()
    local out = {}
    local f = io.open(Cm.ACTIVITY_PATH, "r")
    if not f then return out end
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

-- world step: frame pump at 100 Hz; move "physics"; pending server hits
local function resolve(goal)
    if type(goal) == "table" and goal[1] then return { X = goal[1] * 100, Y = goal[2] * 100, Z = goal[3] * 100 } end
    for _, c in ipairs(world.creatures) do if c:GetFullName():match("([%w_]+)$") == goal and not c._dead_obj then return c.loc end end
    if goal == "Zezima" then return { X = -3000, Y = 0, Z = 0 } end
end
local function step(n)
    for _ = 1, n or 1 do
        T = T + 0.01
        frame_n = frame_n + 1
        if MV.mode ~= "idle" then
            local g = resolve(MV.goal)
            if g then
                local dx, dy = g.X - pawn.loc.X, g.Y - pawn.loc.Y
                local d = math.sqrt(dx * dx + dy * dy)
                local tol = (MV.dist or (MV.opts and MV.opts.tolerance_m) or 1) * 100
                if d > tol then
                    local sp = math.min(5, d - tol)
                    pawn.loc.X, pawn.loc.Y = pawn.loc.X + dx / d * sp, pawn.loc.Y + dy / d * sp
                    pawn.yaw = math.deg(math.atan(dy, dx))
                elseif MV.mode == "go_to" then MV.mode = "idle" end
            end
        end
        stamina = math.min(80, stamina + 0.15)
        local keep = {}
        for _, h in ipairs(pending_hits) do
            if T >= h.t then
                local tgt = Cm._state().fight and Cm._state().fight.target
                if tgt and tgt.hp > 0 then
                    tgt.hp = math.max(0, tgt.hp - h.amount)
                    multicast(tgt, world.instigator or pawn, h.amount)
                    if tgt.hp <= 0 and world.drop_on_death then new_item("BP_WorldItem_C_9" .. #world.items, { X = tgt.loc.X + 50, Y = tgt.loc.Y, Z = 0 }) end
                end
            else keep[#keep + 1] = h end
        end
        pending_hits = keep
        if world.on_step then world.on_step() end
        for id, l in pairs(loops) do
            if T >= l.next then l.next = T + math.max(l.ms, 1) / 1000; l.fn() end
            if not loops[id] then end
        end
    end
end
local function run_until(cond, max_s)
    local t_end = T + (max_s or 30)
    while T < t_end do step(1); if cond() then return true end end
    return false
end
local function reset_world()
    world.creatures, world.items, world.injected, world.on_step, world.drop_on_death, world.inputs_dead, world.instigator = {}, {}, {}, nil, nil, nil, nil
    pending_hits, loops = {}, {}
    MV.mode, MV.calls, MV.goal = "idle", {}, nil
    INV.equips, INV.uses, INV.interacts = {}, {}, 0
    held.right, held.left = nil, "ITEM_Logging_Axe_Mithril"
    pawn.loc, pawn.hp, stamina, special = { X = 0, Y = 0, Z = 0 }, 100, 80, 100
    _G.DWCombat, _G.DWArbiter = nil, nil
    Cm.orders.stance, Cm.orders.force, Cm.orders.avoid = "defensive", false, {}
end

-- ================================================================ 1. arbiter
reset_world()
do
    local r1 = A.request(nil, { name = "gather", level = "task", uses_move = true })
    check("arb grant task", r1.ok and A.owner().name == "gather")
    fake_move.go_to(nil, { 5, 5, 0 })
    local r2 = A.request(nil, { name = "fight", level = "reflex" })
    check("arb reflex preempts task", r2.ok and r2.preempted and r2.preempted.suspended)
    check("arb task suspended with move snapshot", A.is_suspended(r1.token) and A.status().suspended[1].has_move_snap)
    check("arb move stopped on suspend", MV.mode == "idle")
    local r3 = A.request(nil, { name = "idle_wander", level = "idle" })
    check("arb lower refused", not r3.ok and r3.reason == "busy" and r3.owner.name == "fight")
    local rel = A.release(nil, r2.token, "done")
    check("arb release resumes task", rel.resumed == "gather" and A.owner().name == "gather")
    check("arb move restored on resume", MV.mode == "go_to" and MV.calls[#MV.calls]:find("^restore"))
    local r4 = A.request(nil, { name = "gather2", level = "task" })
    check("arb same level replaces (stops old)", r4.ok and r4.preempted and not r4.preempted.suspended and not A.is_suspended(r1.token))
    A.release(nil, r4.token)
    check("arb empty after release", A.owner() == nil)
    -- implicit adoption of an unregistered follow (the bridge driving move directly)
    fake_move.follow(nil, "Zezima", 3)
    local r5 = A.request(nil, { name = "fight", level = "reflex" })
    check("arb adopts unregistered move", r5.ok and r5.preempted and r5.preempted.name == "move:follow" and r5.preempted.suspended)
    A.release(nil, r5.token)
    check("arb resumes adopted follow", MV.mode == "follow" and MV.goal == "Zezima" and A.owner().implicit)
    local refused = A.request(nil, { name = "gather", level = "task" })
    check("arb refusal says who and what", not refused.ok and refused.owner.name == "move:follow" and refused.owner.move and refused.owner.move.mode == "follow")
    fake_move.stop()
    check("arb implicit owner released when its move ends (live bug 20:07)", A.owner() == nil)
    check("arb task granted after the move ended", A.request(nil, { name = "gather", level = "task" }).ok)
    A.reset(nil)
    -- lease expiry
    local r6 = A.request(nil, { name = "crashy", level = "command", lease_s = 2 })
    T = T + 3
    check("arb lease expires", A.owner() == nil and not A.holds(r6.token))
    -- callbacks + stale suspension
    local resumed = 0
    local r7 = A.request(nil, { name = "task_cb", level = "task", uses_move = false, on_resume = function() resumed = resumed + 1 end })
    local r8 = A.request(nil, { name = "cmd", level = "command" })
    T = T + A.MAX_SUSPEND_S + 1
    A.release(nil, r8.token)
    check("arb stale suspension is stopped not resumed", resumed == 0 and A.owner() == nil)
    local r9 = A.request(nil, { name = "task_cb", level = "task", uses_move = false, on_resume = function() resumed = resumed + 1 end })
    local r10 = A.request(nil, { name = "cmd", level = "command" })
    A.release(nil, r10.token)
    check("arb on_resume callback", resumed == 1 and A.owner().name == "task_cb")
    A.reset(nil)
end

-- ================================================================ 2. pure decisions
do
    local W = Cm.weapons()
    check("weapons data loaded", W.items and W.items.ITEM_Dagger_Bone ~= nil)
    local dag, axe, pick = W.items.ITEM_Dagger_Bone, W.items.ITEM_Logging_Axe_Mithril, W.items.ITEM_Pickaxe_Mithril
    check("dps dagger > axe", Cm.dps(dag) > Cm.dps(axe))
    check("torch not a weapon", Cm.score_weapon(W.items.ITEM_Torch, {}) == nil)
    local best = Cm.best_weapon(inv_list, { name = "Kebbit" })
    check("best weapon = Bone Dagger", best.weapon and best.weapon.entry.item == "ITEM_Dagger_Bone", best.weapon and best.weapon.entry.item)
    check("best shield = Bronze Shield", best.shield and best.shield.entry.item == "ITEM_Shield_Bronze")
    -- Kalphites resist Stab/Slash/Crush: every melee weapon is down-weighted but still ranked
    local s1 = Cm.score_weapon(dag, { name = "Kebbit" })
    local s2 = Cm.score_weapon(dag, { name = "Kalphite Worker" })
    check("prior resistance lowers score", s2 < s1)
    local learned = {}
    Cm.learn_outcome(learned, "Kebbit", { "DamageType.Physical.Stab" }, { "weak" })
    check("learned weakness raises score", Cm.score_weapon(dag, { name = "Kebbit" }, learned) > s1)
    check("live affinity used", Cm.affinity({ name = "X", affinities = { ["DamageType.Physical.Crush"] = "immune" } }, "DamageType.Physical.Crush") == "immune")

    local me = { hp = 100, max_hp = 100, pl = 2, dps = Cm.dps(dag) }
    local keb = { name = "Kebbit", hp = 60, max_hp = 60, pl = 1 }
    local a = Cm.assess(me, { keb }, Cm.orders)
    check("assess kebbit = fight", a.decision == "fight", a.why .. " " .. a.u_fight)
    check("assess strong = flee", Cm.assess(me, { { name = "Troll", hp = 900, pl = 5 } }, Cm.orders).why == "too_strong")
    check("assess boss = flee", Cm.assess(me, { { name = "Dragon", hp = 9000, pl = 2, boss = true } }, Cm.orders).why == "boss")
    check("assess outnumbered", Cm.assess(me, { keb, keb, keb }, Cm.orders).why == "outnumbered")
    check("assess low hp", Cm.assess({ hp = 30, max_hp = 100, pl = 2, dps = 15 }, { keb }, Cm.orders).why == "low_hp")
    check("assess force overrides veto", Cm.assess(me, { { name = "Troll", hp = 900, pl = 5 } }, { force = true }).decision == "fight")
    check("assess orders flee", Cm.assess(me, { keb }, { stance = "flee" }).decision == "flee")
    -- an even fight at equal level: borderline, hysteresis keeps an ongoing fight going
    local even = { name = "Wolf", hp = 260, max_hp = 260, pl = 2 }
    local mid = { hp = 60, max_hp = 100, pl = 2, dps = 12 }
    local e1 = Cm.assess(mid, { even }, Cm.orders, nil)
    local e2 = Cm.assess(mid, { even }, Cm.orders, "fight")
    check("assess hysteresis", e1.u_fight == e2.u_fight and (e2.decision == "fight" or e1.decision == "flee"), e1.u_fight)
    check("assess observed dps matters", Cm.assess(me, { { name = "Kebbit", hp = 60, pl = 1, dps_obs = 60 } }, Cm.orders).u_fight < a.u_fight)

    local cr = {
        { id = "k1", name = "Kebbit", archetype = 4, distance_m = 5 },
        { id = "w1", name = "Wolf", archetype = 0, in_combat = true, distance_m = 10 },
        { id = "w2", name = "Wolf", archetype = 0, in_combat = false, distance_m = 8 },
        { id = "g1", name = "Goblin", archetype = 0, in_combat = true, distance_m = 18 },
        { id = "k2", name = "Kebbit", archetype = 4, distance_m = 12 },
    }
    local th = Cm.pick_threats(cr, { k2 = 99 }, {}, Cm.orders, 100)
    check("threats: attacker first, then near hostile in combat", #th == 2 and th[1].id == "k2" and th[2].id == "w1",
          #th .. " " .. tostring(th[1] and th[1].id))
    check("threats: passive kebbit ignored", (function() for _, x in ipairs(th) do if x.id == "k1" then return false end end return true end)())
    local th2 = Cm.pick_threats(cr, {}, {}, { stance = "aggressive", avoid = {} }, 100)
    check("threats: aggressive stance adds idle hostiles", #th2 == 2 and th2[1].id == "w2")
    local th3 = Cm.pick_threats(cr, { k2 = 99 }, {}, { stance = "defensive", avoid = { kebbit = true } }, 100)
    check("threats: avoid list", #th3 == 1 and th3[1].id == "w1")
    check("threats: old attacker forgotten", #Cm.pick_threats(cr, { k2 = 80 }, {}, Cm.orders, 100) == 1)
    local d = Cm.react_delay()
    check("reaction delay 150-300 ms", d >= 0.15 and d <= 0.3, d)
end

-- ================================================================ 3. commanded fight vs a Kebbit
reset_world()
do
    local task = A.request(nil, { name = "gather", level = "task", uses_move = true })
    fake_move.go_to(nil, { 20, 20, 0 })
    world.instigator = pc -- live: our hits may name the controller as instigator
    local keb = new_creature("BP_AI_Kebbit_Character_02_C_1", "Kebbit", { X = 600, Y = 0, Z = 0 }, { hp = 60, pl = 1 })
    world.drop_on_death = true
    local r = Cm.attack(nil, "Kebbit")
    check("attack starts", r.ok, r.reason)
    check("attack preempted the task (suspended)", A.is_suspended(task.token))
    local done = run_until(function() return Cm._state().fight == nil end, 60)
    local res = Cm._state().last and Cm._state().last.result
    check("fight finished", done)
    check("fight ok (killed)", res and res.ok and res.data.killed, res and (res.reason or "") .. " " .. table.concat(res.data.phase_log or {}, " | "))
    check("equipped dagger then shield", INV.equips[1] == "ITEM_Dagger_Bone" and INV.equips[2] == "ITEM_Shield_Bronze", table.concat(INV.equips, ","))
    check("restored the axe", held.left == "ITEM_Logging_Axe_Mithril" and held.right == nil and INV.equips[#INV.equips] == "ITEM_Logging_Axe_Mithril")
    check("pressed primary", (world.injected.IA_PrimaryAction or 0) >= 3)
    check("no special without PerkV2_Attack_MeleeSpecialAttacks", (world.injected.IA_SpecialAction or 0) == 0)
    local acts = read_activity()
    check("combat_end activity written", #acts >= 1 and acts[#acts]:find('"kind":"combat_end"', 1, true) and acts[#acts]:find('"outcome":"killed"', 1, true)
          and acts[#acts]:find('"by":"debug"', 1, true), acts[#acts])
    check("locked on", (world.injected.IA_ToggleLockOnTargeting or 0) == 1)
    check("hits verified via damage multicast", res and res.data.hits >= 3, res and res.data.hits)
    check("looted the drop", res and res.data.looted == 1 and INV.interacts >= 1, res and (tostring(res.data.looted) .. " i=" .. INV.interacts .. " " .. table.concat(res.data.phase_log, " | ")))
    check("task resumed after fight", A.owner() and A.owner().name == "gather" and MV.mode == "go_to")
    check("kebbit dead", keb.hp <= 0)
    check("weakness learning recorded neutral", Cm._state().learned.kebbit and Cm._state().learned.kebbit["DamageType.Physical.Stab"] == "neutral")
    A.reset(nil)
end

-- ================================================================ 4. strong target: fought with an assessment; never players
reset_world()
do
    new_creature("BP_AI_Troll_C_1", "Troll", { X = 500, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0 })
    local r = Cm.attack(nil, "Troll")
    check("strong target NOT refused: the model decides (North Star)", r.ok, r.reason)
    check("strong target: assessment returned as information", r.ok and r.data.assessment.verdict == "too_strong" and r.data.assessment.est_s_to_die ~= nil,
          r.data and r.data.assessment and r.data.assessment.verdict)
    run_until(function() local f = Cm._state().fight; return f and (f.phase == "approach" or f.phase == "engage") end, 3)
    check("commanded fight vs a strong enemy keeps fighting (no strength veto)", Cm._state().fight and Cm._state().fight.phase ~= "flee")
    Cm.stop(nil, "test")
    A.reset(nil)
    local p2 = obj({ PlayerState = obj({}, "PS /x") }, "BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_2")
    function p2:K2_GetActorLocation() return { X = 100, Y = 0, Z = 0 } end
    local r2 = Cm._start_fight(nil, p2, { mode = "attack" })
    check("never attack players", not r2.ok and r2.reason == "unsafe")
    check("unknown target", Cm.attack(nil, "Dragon").reason == "unknown_target")
end

-- ================================================================ 5. reflex: attacked by a strong hostile -> flee to Luis, eat
reset_world()
do
    Cm.guard_start(nil)
    local troll = new_creature("BP_AI_Troll_C_2", "Troll", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    troll.CurrentAlertnessState = 4
    -- the troll hits Claude twice
    multicast(pawn, troll, 30)
    pawn.hp = 70
    multicast(pawn, troll, 30)
    pawn.hp = 40
    local started = run_until(function() return Cm._state().fight ~= nil end, 2)
    check("reflex started on attack", started)
    local fled = run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 3)
    check("reflex flees a strong attacker", fled, Cm._state().fight and Cm._state().fight.phase)
    check("flee follows Luis", (function() for _, c in ipairs(MV.calls) do if c == "follow:Zezima" then return true end end end)())
    run_until(function() return #INV.uses > 0 end, 3)
    check("ate while fleeing (hp < 55%)", INV.uses[1] == "ITEM_Food_Sandwich")
    -- the troll loses interest: out of combat and far away
    troll.CurrentAlertnessState = 0
    troll.loc = { X = 6000, Y = 0, Z = 0 }
    Cm._state().attackers = {}
    local ended = run_until(function() return Cm._state().fight == nil end, 10)
    local res = Cm._state().last.result
    check("flee ends when safe (reflex ok, fled)", ended and res.ok and res.data.fled, res and res.reason)
    Cm.guard_stop(nil)
    A.reset(nil)
end

-- ================================================================ 6. telegraph -> block with the shield; inputs that do nothing fail loudly
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local wolf = new_creature("BP_AI_Wolf_C_1", "Wolf", { X = 150, Y = 0, Z = 0 }, { hp = 2000, pl = 1, arch = 0 })
    Cm.orders.force = false
    local r = Cm._start_fight(nil, wolf, { mode = "attack", force = true })
    check("fight vs wolf starts", r.ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    local hook = hooks["/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies"]
    check("telegraph hook registered", hook ~= nil)
    local b0 = world.injected.IA_SecondaryAction or 0
    hook({ get = function() return obj({ GetOwner = function() return wolf end }, "C /x") end })
    local blocked = run_until(function() return (world.injected.IA_SecondaryAction or 0) > b0 + 40 end, 2)
    check("blocked after a telegraph (held >= 40 frames)", blocked, tostring(world.injected.IA_SecondaryAction) .. " " .. table.concat((Cm._state().fight or {phase_log={}}).phase_log, " | ") .. " " .. table.concat(Cm._state().log_lines, " || "))
    check("block held, not tapped (~0.9 s)", (world.injected.IA_SecondaryAction or 0) < b0 + 120)
    -- now the inputs stop working (e.g. a UI mode eats them): the fight must fail, not loop
    world.inputs_dead = true
    stamina = 80
    local ended = run_until(function() return Cm._state().fight == nil end, 30)
    local res = Cm._state().last.result
    check("dead inputs fail loudly", ended and not res.ok and res.reason == "body_error", res and res.reason)
    A.reset(nil)
end

-- ================================================================ 7. bridge handler shape
reset_world()
do
    new_creature("BP_AI_Kebbit_Character_02_C_7", "Kebbit", { X = 300, Y = 0, Z = 0 }, { hp = 30, pl = 1 })
    local h = Cm.HANDLERS.attack(nil, { target = "BP_AI_Kebbit_Character_02_C_7" }, { id = "t1" })
    check("handler returns pending", type(h) == "table" and h.pending and h.pending.poll)
    check("pending not done yet", h.pending.poll(h.pending) == nil)
    run_until(function() return Cm._state().fight == nil end, 40)
    local res = h.pending.poll(h.pending)
    check("pending resolves ok", res and res.ok, res and res.reason)
    check("handler invalid args", Cm.HANDLERS.attack(nil, {}, {}).reason == "invalid_args")
    check("status shape", Cm.HANDLERS.combat_status().counts.fights >= 1)
    check("orders", Cm.HANDLERS.combat_orders(nil, { stance = "passive", avoid = { "Kebbit" } }).orders.avoid.kebbit == true)
end

-- ================================================================ 7b. big target: reach scales with its capsule (a cow stands ~3 m away)
reset_world()
do
    local cow = new_creature("BP_AI_Cow_Character_C_1", "Cow", { X = 800, Y = 0, Z = 0 }, { hp = 60, pl = 1 })
    cow.CapsuleComponent = obj({ GetScaledCapsuleRadius = function() return 120 end }, "C /x")
    -- the fake move cannot get closer than 3.0 m to it (like the live cow)
    local real_follow = fake_move.follow
    fake_move.follow = function(log, goal, dist, opts) return real_follow(log, goal, math.max(dist, 3.0), opts) end
    check("big target: fight starts", Cm.attack(nil, "Cow").ok)
    check("big target: reach grows with capsule", math.abs(Cm._state().fight.reach - 3.0) < 1e-6, Cm._state().fight.reach)
    run_until(function() return Cm._state().fight == nil end, 40)
    fake_move.follow = real_follow
    local res = Cm._state().last.result
    check("big target: killed from 3 m", res.ok and res.data.killed and res.data.presses >= 3, res.reason)
end

-- ================================================================ 8. world teardown (_G.DW_PAUSE): no game calls
reset_world()
do
    Cm.orders.stance, Cm.orders.avoid = "defensive", {}
    local task = A.request(nil, { name = "gather", level = "task", uses_move = true })
    fake_move.go_to(nil, { 20, 20, 0 })
    new_creature("BP_AI_Kebbit_Character_02_C_8", "Kebbit", { X = 900, Y = 0, Z = 0 }, { hp = 100, pl = 1 })
    check("pause test: fight starts", Cm.attack(nil, "Kebbit").ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "approach" end, 3)
    local ncalls = #MV.calls
    local gets = 0
    local real_find = FindAllOf
    _G.DW_PAUSE = true
    FindAllOf = function(...) gets = gets + 1; return real_find(...) end
    step(5)
    FindAllOf = real_find
    local res = Cm._state().last and Cm._state().last.result
    check("pause ends the fight as interrupted", Cm._state().fight == nil and res and res.reason == "interrupted", res and res.reason)
    check("pause: no move calls and no object scans", #MV.calls == ncalls and gets == 0, (#MV.calls - ncalls) .. " " .. gets)
    check("pause: suspended stack dropped, nothing resumed", A.owner() == nil and #A.status().suspended == 0)
    check("pause: new requests refused", A.request(nil, { name = "x", level = "task" }).reason == "paused")
    check("pause: attack refused", Cm.attack(nil, "Kebbit").reason == "companion_down")
    Cm.guard_start(nil)
    gets = 0
    FindAllOf = function(...) gets = gets + 1; return real_find(...) end
    step(100)
    FindAllOf = real_find
    check("pause: guard loop idle", gets == 0, gets)
    Cm.guard_stop(nil)
    _G.DW_PAUSE = nil
    local _ = task
end

-- ================================================================ 9. defense.lua: planning, timing, learning
do
    _G.DWDefense = nil
    local fixed = function() return 0.5 end -- rng: mid reaction (0.225 s), zero timing error
    local function with(k, v) local c = {}; for a, b in pairs({ dist_cm = 150, latency_s = 0.03, stamina = 60, can_parry = true, can_block = true,
        parry_cost = 10, block_cost = 10, evade_cost = 15, hp_frac = 1, heal_hp = 0.5 }) do c[a] = b end; if k then c[k] = v end; return c end
    local ctx = with()
    local info = { key = "Goblin:ATK_Slash", dmg_time = 0.8, shape = Dm.shape_info({ class = "DominionShape_Wedge", depth = 200, zheight = 150, top_angle = 90 }, 90) }
    local p = Dm.plan(info, ctx, { defense = "auto" }, fixed)
    check("plan: parry when able", p.action == "parry" and p.src == "attack_data", p.action)
    check("plan: parry press = T - 2L - window/2", math.abs(p.at_s - (0.8 - 0.06 - 0.05)) < 1e-6, p.at_s)
    check("plan: parry hold covers impact", p.at_s + p.hold_s >= 0.8 + 0.3)
    local fast = Dm.plan({ key = "Rat:Bite", dmg_time = 0.25 }, ctx, {}, fixed)
    check("plan: too fast to parry -> block", fast.action == "block" and fast.why == "too_fast_to_parry", fast.action .. " " .. tostring(fast.why))
    check("plan: no parry perk -> block", Dm.plan(info, with("can_parry", false), {}, fixed).action == "block")
    local unb = Dm.plan({ key = "Troll:Slam", dmg_time = 1.0, unblockable = true }, ctx, {}, fixed)
    check("plan: unblockable -> dodge", unb.action == "dodge" and unb.at_s > 0.5 and unb.dir ~= nil)
    local slam = Dm.shape_info({ class = "DominionShape_Sphere", radius = 350, offset_x = 0, offset_z = -80 }, 90)
    check("shape: centred big sphere = aoe", slam.aoe and slam.reach_cm == 350)
    local sweep = Dm.shape_info({ class = "DominionShape_Box", extent = { x = 250, y = 100, z = 20 }, offset_z = -80 }, 90)
    check("shape: flat box near the feet = low", sweep.low == true, sweep.top_cm)
    check("plan: unblockable low sweep -> jump", Dm.plan({ key = "Troll:Sweep", dmg_time = 1.0, unblockable = true, shape = sweep }, ctx, { allow_jump = true }, fixed).action == "jump")
    check("plan: jump disallowed by orders -> dodge", Dm.plan({ key = "Troll:Sweep", dmg_time = 1.0, unblockable = true, shape = sweep }, ctx, { allow_jump = false }, fixed).action == "dodge")
    local far = Dm.plan(info, with("dist_cm", 900), {}, fixed)
    check("plan: out of reach -> none", far.action == "none" and far.why == "out_of_reach")
    check("plan: orders dodge", Dm.plan(info, ctx, { defense = "dodge" }, fixed).action == "dodge")
    check("plan: orders none", Dm.plan(info, ctx, { defense = "none" }, fixed).action == "none")
    check("plan: low hp prefers dodge", Dm.plan(info, with("hp_frac", 0.3), {}, fixed).action == "dodge")
    check("plan: no stamina -> retreat", Dm.plan(info, with("stamina", 5), {}, fixed).action == "retreat")
    Dm.observe("Goblin:ATK_Slash", 0.9); Dm.observe("Goblin:ATK_Slash", 0.9)
    local t1, src = Dm.impact_delay("Goblin:ATK_Slash", info)
    check("learn: observed impact replaces prior", src == "learned" and t1 > 0.85, t1)
    Dm.feedback("Goblin:ATK_Slash", "parry", "blocked")
    check("learn: blocked-not-parried = too early -> press later", Dm.rec("Goblin:ATK_Slash").offset > 0)
    Dm.feedback("Goblin:ATK_Slash", "parry", "hit"); Dm.feedback("Goblin:ATK_Slash", "parry", "hit")
    check("learn: hit = too late -> press earlier", Dm.rec("Goblin:ATK_Slash").offset < 0)
    _G.DWDefense = nil
end

-- fake AI attack: the telegraph multicast + the server's resolution at impact time
local function goblin_attack(goblin, dmg_time, opts)
    opts = opts or {}
    local shape = obj({ Depth = 200, ZHeight = 150, TopAngle = 90, Offset = { X = 0, Z = 0 } }, "DominionShape_Wedge /Game/x.Shape")
    local ad = obj({ AttackPropertyFlags = opts.flags or 0, GetDamageTime = function() return dmg_time end,
                     GetLastDamageTime = function() return dmg_time end, GetDuration = function() return 2 end,
                     Damage = { ForEach = function(_, f) f(1, { get = function() return { Time = dmg_time, Shape = shape } end }) end } },
                   "ATK_Goblin_Slash_C /Game/AI/Goblin/ATK_Goblin_Slash.Default__ATK_Goblin_Slash_C")
    local comp = obj({ GetOwner = function() return goblin end, CurrentAttack = { AttackData = ad } }, "C /x")
    local hook = hooks["/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies"]
    hook({ get = function() return comp end }, { get = function() return 7 end })
    world.block_start = nil
    local impact = T + dmg_time
    world.on_step = function()
        if T >= impact and not world.resolved then
            world.resolved = true
            local own = obj({ GetOwner = function() return pawn end }, "C /x")
            local blocking = world.block_last and T - world.block_last < 0.05
            -- the server sees the press 2 x one-way latency (0.03 s default) later than the client's telegraph clock
            local seen = world.block_start and (world.block_start + 0.06)
            if blocking and seen and impact - seen <= 0.10 + 1e-6 and impact - seen >= -1e-6 then
                hooks["/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack"]({ get = function() return own end })
                world.result = "parried"
            elseif blocking then
                hooks["/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingBlockedAttack"]({ get = function() return own end })
                world.result = "blocked"
            elseif world.evading_until and world.evading_until > T then
                world.result = "dodged"
            else
                pawn.hp = pawn.hp - 15
                multicast(pawn, goblin, 15)
                world.result = "hit"
            end
        end
    end
end

-- ================================================================ 10. fights: parry (perk), block (no perk), dodge (orders)
for _, case in ipairs({
    { name = "parry with the perk", perks = { PerkV2_Attack_Parry = true }, defense = "auto", want_action = "parry", want = "parried" },
    { name = "block without the perk", perks = {}, defense = "auto", want_action = "block", want = "blocked" },
    { name = "dodge by orders", perks = {}, defense = "dodge", want_action = "dodge", want = "dodged" },
}) do
    reset_world()
    PERKS.unlocked = case.perks
    Cm.set_orders({ defense = case.defense })
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_" .. case.want, "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    check(case.name .. ": fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    world.resolved, world.result = nil, nil
    goblin_attack(gob, 0.8)
    run_until(function() local f = Cm._state().fight; return world.resolved and f and f.phase == "engage" end, 3)
    local f = Cm._state().fight
    local ld = f and f.last_defence or {}
    check(case.name .. ": planned " .. case.want_action, ld.action == case.want_action, tostring(ld.action) .. " " .. tostring(ld.why))
    check(case.name .. ": server result " .. case.want, world.result == case.want, world.result)
    local want_outcome = case.want == "dodged" and "avoided" or case.want
    check(case.name .. ": verified outcome " .. want_outcome, ld.outcome == want_outcome, ld.outcome)
    check(case.name .. ": no damage taken", pawn.hp == 100, pawn.hp)
    if case.want == "dodged" then
        local mv = world.last_vec and world.last_vec.IA_Movement
        check("dodge: directional via IA_Movement (sideways) + IA_Player_Evade", mv and math.abs(mv.X) == 1 and mv.Y == 0 and (world.injected.IA_Player_Evade or 0) > 0,
              mv and (mv.X .. "," .. mv.Y))
    end
    if case.want == "parried" then
        local r = Dm.rec("Goblin Runt:ATK_Goblin_Slash")
        check("parry: impact time learned from the verdict", r.n == 1 and math.abs(r.impact_s - 0.8) < 0.05, r.impact_s)
    end
    Cm.stop(nil, "test")
    A.reset(nil)
end
PERKS.unlocked = {}
Cm.set_orders({ defense = "auto" })

-- ================================================================ 11. low HP: disengage, eat to heal, re-engage
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_heal", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    check("heal: fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    pawn.hp = 40
    check("heal: disengages below heal_hp", run_until(function() local f = Cm._state().fight; return f and f.phase == "disengage" end, 2))
    local backed = run_until(function() return MV.mode == "go_to" end, 2)
    check("heal: backs off (go_to away from the enemy)", backed and type(MV.goal) == "table" and MV.goal[1] < 0, MV.goal and MV.goal[1])
    check("heal: eats the healing food", run_until(function() return #INV.uses >= 1 end, 10) and INV.uses[1] == "ITEM_Food_Sandwich", INV.uses[1])
    local back = run_until(function() local f = Cm._state().fight; return f and (f.phase == "approach" or f.phase == "engage") and pawn.hp >= 80 end, 60)
    check("heal: re-engages once healed", back, pawn.hp)
    local healed = 0
    for _, l in ipairs(read_activity()) do if l:find('"kind":"healed"', 1, true) then healed = healed + 1 end end
    check("heal: healed activity events", healed >= 3, healed)
    Cm.stop(nil, "test")
    A.reset(nil)
end

-- ================================================================ 12. the held item's own actions (styles)
reset_world()
do
    local function action(name, perk_name, extra)
        local cdo = obj({ ActionName = fname(name), RequiredPerk = perk_name and perk(perk_name) or nil }, "PA_C /x")
        for k, v in pairs(extra or {}) do cdo[k] = v end
        return obj({ GetCDO = function() return cdo end }, "BlueprintGeneratedClass /Game/PA_" .. name:gsub(" ", "") .. ".PA_" .. name:gsub(" ", "") .. "_C")
    end
    local axe = obj({ Name = fname("Mithril Logging Axe"), PrimaryActionClass = action("Chop"), SpecialActionClass = action("Overhead Chop", "PerkV2_Woodcutting_Overhead"),
                      SecondaryActionClass = action("Block") },
                    "HeldEquipmentData /DowdunReach/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Mithril.ITEM_Logging_Axe_Mithril")
    pawn.PlayerEquipmentComponent = obj({ GetHeldEquipmentDataRight = function() return nil end, GetHeldEquipmentDataLeft = function() return axe end }, "C /x")
    local h = Cm.held_actions(pawn, pc)
    check("held_actions: read from the item data", h.ok and h.item == "ITEM_Logging_Axe_Mithril" and #h.actions == 3, #h.actions)
    local names = {}
    for _, a in ipairs(h.actions) do names[a.style] = a.name end
    check("held_actions: display names", names.primary == "Chop" and names.special == "Overhead Chop" and names.secondary == "Block")
    check("resolve_style by name", Cm.resolve_style(h, "Overhead Chop").style == "special")
    check("resolve_style by partial name", Cm.resolve_style(h, "overhead").style == "special")
    check("resolve_style by slot", Cm.resolve_style(h, "primary").name == "Chop")
    local _, bad = Cm.check_style("Overhead Chop", pawn, pc)
    check("check_style: locked perk -> not_unlocked", bad and bad.reason == "not_unlocked", bad and bad.reason)
    local _, bad2 = Cm.check_style("pirouette", pawn, pc)
    check("check_style: unknown style lists the real ones", bad2 and bad2.reason == "invalid_args" and bad2.data.detail:find("Overhead Chop", 1, true))
    PERKS.unlocked = { PerkV2_Woodcutting_Overhead = true }
    check("check_style: unlocked perk -> ok", Cm.check_style("overhead", pawn, pc).input == "special")
    -- use_action: one real press of the special input, verified by stamina spent
    local r = Cm.HANDLERS.use_action(nil, { style = "Overhead Chop" }, { id = "u1" })
    check("use_action pending", r.pending ~= nil)
    local s0 = world.injected.IA_SpecialAction or 0
    run_until(function() return r.pending.poll() ~= nil end, 5)
    local res = r.pending.poll()
    check("use_action pressed the special input", (world.injected.IA_SpecialAction or 0) > s0)
    check("use_action verified (stamina spent)", res and res.ok and res.data.name == "Overhead Chop", res and res.reason)
    check("use_action released the pawn", A.owner() == nil)
    PERKS.unlocked = {}
    pawn.PlayerEquipmentComponent = nil
    A.reset(nil)
end

print(string.format("combat/arbiter tests: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
