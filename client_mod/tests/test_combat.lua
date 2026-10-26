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
    if rising and (name == "IA_PrimaryAction" or name == "IA_SpecialAction") and not world.inputs_dead and not world.ranged then
        stamina = stamina - (name == "IA_PrimaryAction" and 10 or 0)
        if name == "IA_SpecialAction" then special = special - 25 end
        pending_hits[#pending_hits + 1] = { t = T + 0.3, amount = name == "IA_PrimaryAction" and 12 or 21 }
    end
end

function FindAllOf(cls)
    if cls == "BP_PlayerController_C" or cls == "PlayerController" then return { pc } end
    if cls == "PlayerState" then
        -- Luis (Zezima) is online with a visible pawn; Claude's own state too
        local luis_pawn = obj({}, "BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_9")
        function luis_pawn:K2_GetActorLocation() return { X = -3000, Y = 0, Z = 0 } end
        return { obj({ PawnPrivate = luis_pawn, GetPlayerName = function() return fname("Zezima") end }, "PS /x.PS_9"),
                 obj({ PawnPrivate = pawn, GetPlayerName = function() return fname("Claude") end }, "PS /x.PS_1") }
    end
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
function fake_move.set_avoid_zones(log, zones) MV.zone_sets = (MV.zone_sets or 0) + 1; MV.zones = zones; return { ok = true, zones = #zones } end
function fake_move.escape_zones(log, opts)
    MV.escapes = (MV.escapes or 0) + 1
    MV.escape_opts = opts
    local r = MV.escape_reply or { ok = false, why = "no_route" }
    if r.ok then
        local prev = fake_move.snapshot()
        MV.mode, MV.goal, MV.dist, MV.opts = "go_to", { r.at[1], r.at[2], r.at[3] }, nil, { tolerance_m = 0.4 }
        return { ok = true, at = r.at, eta_s = r.eta_s, prev = prev, zone = "z" }
    end
    return r
end
function fake_move.status()
    local r = { mode = MV.mode, target = type(MV.goal) == "string" and MV.goal or nil }
    for k, v in pairs(MV.extra or {}) do r[k] = v end
    return r
end
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
-- the persistent memory goes to a temp root (never the repo's data/skills)
Cm.cfg.memory_root = (tmpdir .. "/test_combat_mem"):gsub("\\", "/")
os.execute('mkdir "' .. (tmpdir .. "/test_combat_mem/data/skills/shockbyte"):gsub("/", "\\") .. '" 2>nul')
os.remove(Cm.cfg.memory_root .. "/data/skills/shockbyte/combat_memory_BP_PlayerCharacter_C_1.json")
Cm._reset_build("TESTBUILD")
Cm.cfg.memory_enabled = false -- on only in the memory section (sections must not learn from each other)
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
                    if world.wall_x and pawn.loc.X > world.wall_x then pawn.loc.X = world.wall_x end -- a wall across +X
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
    _G.DWCombat, _G.DWArbiter, _G.DWDefense = nil, nil, nil
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
    do -- fight odds for get_state (prep information, the same estimate as combat_brief)
        local me = { hp = 100, max_hp = 100, pl = 1 }
        local odds = Cm.fight_odds(me, 12, {
            { id = "k1", name = "Kebbit", hp = 30, max_hp = 30, power_level = 1, distance = 5 },
            { id = "d1", name = "Grey Drake", hp = 900, max_hp = 900, power_level = 6, distance = 20 },
            { id = "far", name = "Troll", hp = 900, power_level = 8, distance = 90 },
            { id = "f1", name = "Pet", follower = true, distance = 2 } })
        check("odds: an easy creature", odds.k1 and odds.k1.verdict == "likely_win", odds.k1 and odds.k1.verdict)
        check("odds: a hard creature says so, with the gap and times", odds.d1 and odds.d1.verdict == "too_strong" and odds.d1.pl_gap == 5 and odds.d1.die_s ~= nil, odds.d1 and odds.d1.verdict)
        check("odds: out of sight / followers skipped", odds.far == nil and odds.f1 == nil)
        -- prepared odds: only what he owns and can cast, each use named with its source
        local drake = { id = "d1", name = "Grey Drake", hp = 900, max_hp = 900, power_level = 6 }
        local known = { ["DamageType.Physical.Stab"] = { v = "weak", src = "journal" } }
        local list = { loadout = {}, hotbar = { { item = "ITEM_Sword_Bronze", count = 1 }, { item = "ITEM_Consumable_Fish_Anchovies", count = 4, consumable = "food", heal = 30 } },
                       bag = { { item = "ITEM_Dagger_Iron", count = 1 } } }
        local now = odds.d1
        local p = Cm.prepared_odds(me, drake, list, { tempest = true, enchant = {} }, known, 1)
        local uses = table.concat(p.uses, " | ")
        check("prep: the stab-weak dagger he owns is used, with the source", uses:find("Iron Dagger vs stab-weak (journal)", 1, true) ~= nil, uses)
        check("prep: Tempest Shield's shield (50 + 7.5 x Attack)", uses:find("Tempest Shield (+57 shield)", 1, true) ~= nil, uses)
        check("prep: carried healing food counted", uses:find("4 food (+120 HP)", 1, true) ~= nil, uses)
        check("prep: better odds than now", p.die_s > now.die_s and p.kill_s < now.kill_s, tostring(p.die_s) .. "/" .. tostring(p.kill_s))
        local none = Cm.prepared_odds(me, drake, { loadout = {}, hotbar = {}, bag = {} }, { enchant = {} }, nil, 1)
        check("prep: nothing owned -> no uses, same as now", #none.uses == 0 and none.die_s == now.die_s)
        local enc = Cm.prepared_odds(me, { name = "Goblin Brute", hp = 420, max_hp = 420, power_level = 4 },
            { hotbar = { { item = "ITEM_Sword_Bronze", count = 1 } } }, { enchant = { ["DamageType.Magical.Fire"] = true } },
            { ["DamageType.Magical.Fire"] = { v = "weak", src = "prior" } }, 1)
        check("prep: a castable enchant of a type it is weak to", table.concat(enc.uses, "|"):find("Enchant Weapon (Fire) vs fire-weak (prior)", 1, true) ~= nil, table.concat(enc.uses, "|"))
        local ka = Cm.known_affinities("Kalphite Worker")
        check("known: prior resistance with its source", ka and ka["DamageType.Physical.Stab"] and ka["DamageType.Physical.Stab"].src == "prior")
        -- a long boss fight (velgar.md gap 5): windows + flights, poison DoT vs resistances, shield vs breath, every food
        local velgar = { id = "v", name = "Velgar", hp = 6000, max_hp = 6000, power_level = 4, boss = true }
        local me4 = { hp = 100, max_hp = 100, pl = 4 }
        local kit = { loadout = {}, hotbar = { { item = "ITEM_Mace_Iron", name = "Iron Mace", count = 1 },
                                               { item = "ITEM_Food_BerryDrizzle", name = "Berry Drizzle Pan-Seared", count = 20, consumable = "food", heal = 160 },
                                               { item = "ITEM_Potion_Antipoison_Lesser", name = "Lesser Antipoison Potion", count = 20, consumable = "potion" } },
                      bag = { { item = "ITEM_Shield_AntiDragon", name = "Anti-Dragon Shield", count = 1 } } }
        local pv = Cm.prepared_odds(me4, velgar, kit, { tempest = true, enchant = {} }, nil, 5)
        check("boss: the long-fight model (4 windows, 3 flights)", pv and pv.boss and pv.windows == 4 and pv.flights == 3, pv and pv.windows)
        local u = table.concat(pv.uses, " | ")
        check("boss: the shield vs breath, poison resistance, food eaten over time", u:find("Anti-Dragon Shield vs breath", 1, true) and u:find("poison resistance ~66%", 1, true)
              and u:find("20 food (eaten", 1, true), u)
        check("boss: poison DoT counted, reduced by the resistances", pv.dot_hps and pv.dot_hps < 4 * 0.5, pv.dot_hps)
        check("boss: the kill time includes the flights", pv.kill_s >= 3 * 20, pv.kill_s)
        check("boss: priors named in the result", pv.priors and pv.priors.poison_dps == 4 and pv.priors.flight_s == 20)
        local bare = Cm.prepared_odds(me4, velgar, { hotbar = { { item = "ITEM_Mace_Iron", name = "Iron Mace", count = 1 } } }, { enchant = {} }, nil, 5)
        check("boss: the kit makes a real difference", (bare.die_s or 1e9) < (pv.die_s or 1e9), tostring(bare.die_s) .. " vs " .. tostring(pv.die_s))
        check("boss: no resistance -> the full DoT share", bare.dot_hps == 2, bare.dot_hps)
        check("boss: PL 4 + the wiki's kit outlasts him (likely win)", pv.verdict == "likely_win" and pv.survives == true, pv.verdict)
        local pl1 = Cm.prepared_odds({ hp = 100, max_hp = 100, pl = 1 }, velgar, kit, { tempest = true, enchant = {} }, nil, 5)
        check("boss: the same kit at PL 1 is a likely loss", pl1.verdict == "likely_lose" and pl1.die_s ~= nil, pl1.verdict)
        local gd = Cm.known_affinities("Green Dragon")
        check("known: wiki weakness + resistance, labelled wiki", gd and gd["DamageType.Magical.Water"] and gd["DamageType.Magical.Water"].v == "weak"
              and gd["DamageType.Magical.Water"].src == "wiki" and gd["DamageType.Magical.Fire"].v == "resist")
        local vw = Cm.wiki_creature("Velgar")
        check("wiki: Velgar PL 4, 6000 HP, immune to Poison + Burning effects", vw and vw.pl[1] == 4 and vw.hp[1] == 6000
              and table.concat(vw.immune_effects, ",") == "Poison,Burning")
        check("known: the wiki outranks the hand-written priors (learned and journal outrank the wiki)",
              Cm.known_affinities("Goblin Runt")["DamageType.Magical.Fire"].src == "wiki")
        check("known: a journal word maps to the full tag", Cm.norm_tag("Fire") == "DamageType.Magical.Fire" and Cm.norm_tag("Stab") == "DamageType.Physical.Stab")
    end
    do -- any shield he owns, from data (the parry cases need the Wooden Shield he crafts himself)
        local only_wood = { loadout = {}, hotbar = { { item = "ITEM_Dagger_Bone", slot = 1 } }, bag = { { item = "ITEM_Shield_Wood", slot = 3 } } }
        local b2 = Cm.best_weapon(only_wood, { name = "Goblin Runt" })
        check("a crafted Wooden Shield is the shield", b2.shield and b2.shield.entry.item == "ITEM_Shield_Wood" and b2.shield.where == "bag", b2.shield and b2.shield.entry.item)
        local both = { loadout = {}, hotbar = { { item = "ITEM_Shield_Wood", slot = 1 } }, bag = { { item = "ITEM_Shield_Iron", slot = 3 } } }
        check("the better-blocking shield wins", Cm.best_weapon(both, {}).shield.entry.item == "ITEM_Shield_Iron")
    end
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
    check("plan: parry press = T - 2L - block delay - window/2", math.abs(p.at_s - (0.8 - 0.06 - Dm.cfg.block_delay_s - 0.05)) < 1e-6, p.at_s)
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
    do -- "none, out_of_reach" and still hit from there: the reach grows to that distance (live 08:17)
        local hop = { key = "Kebbit:Hop", dmg_time = info.dmg_time, shape = info.shape }
        local p1 = Dm.plan(hop, with("dist_cm", 900), {}, fixed)
        Dm.feedback(hop.key, p1.action, "hit", 7, p1.dist_cm)
        local p2 = Dm.plan(hop, with("dist_cm", 900), {}, fixed)
        check("plan: a hit taken from 9 m makes 9 m in reach", p1.why == "out_of_reach" and p2.action ~= "none", p2.action .. " " .. tostring(p2.why))
    end
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
            local seen = world.block_start and (world.block_start + 0.06 + 0.11) -- + the server's BlockDelay
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

-- ================================================================ 10c. an approach that can't get there (BUGS L34, live 09:34: a Kebbit behind a wall)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    -- (a) no progress: a wall 1 m ahead, the target 6 m away behind it
    world.wall_x = 100
    local k = new_creature("BP_AI_Kebbit_Character_02_C_wall", "Kebbit", { X = 600, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 1 })
    local t0 = T
    check("wall: fight starts", Cm._start_fight(nil, k, { mode = "attack", force = true, by = "brain" }).ok)
    run_until(function() return Cm._state().fight == nil end, 60)
    local res = Cm._state().last.result
    check("wall: ends path_blocked, not a timeout", res and res.reason == "path_blocked", res and res.reason)
    check("wall: ends fast (no 0.5 m gain for 12 s)", T - t0 < 16, T - t0)
    check("wall: says what and why", res and res.data.why == "no_progress" and res.data.target == "Kebbit" and res.data.detail:find("Kebbit", 1, true)
          and res.data.dist_m and res.data.dist_m > 4, res and res.data and res.data.detail)
    world.wall_x = nil
    A.reset(nil)
    -- (b) move's own verdict: follow says unreachable (no_route) -> at once, with its reason
    reset_world()
    world.wall_x = 100
    local k2 = new_creature("BP_AI_Kebbit_Character_02_C_wall2", "Kebbit", { X = 600, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 1 })
    check("unreach: fight starts", Cm._start_fight(nil, k2, { mode = "attack", force = true, by = "brain" }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "approach" end, 3)
    local t1 = T
    MV.extra = { status = "unreachable", unreachable = { reason = "no_route", detail = "dz=-0.3m d=4.3m lp_fail=unreachable_in_window" }, lp_fail = "unreachable_in_window" }
    run_until(function() return Cm._state().fight == nil end, 10)
    local r2 = Cm._state().last.result
    check("unreach: move's verdict ends it at once", r2 and r2.reason == "path_blocked" and r2.data.why == "no_route" and T - t1 < 1, r2 and r2.data and r2.data.why)
    check("unreach: the detail is a sentence he can say", r2 and r2.data.detail == "I can't reach the Kebbit: there's no way through to it from here.", r2 and r2.data.detail)
    MV.extra, world.wall_x = nil, nil
    A.reset(nil)
    -- (c) live 2026-10-25 22:01: move's verdict "leader_above_jump_height" (a Kebbit up a ledge) -> said plainly
    reset_world()
    local k3 = new_creature("BP_AI_Kebbit_Character_02_C_ledge", "Kebbit", { X = 1500, Y = 0, Z = 270 }, { hp = 30, pl = 1, arch = 1 })
    world.wall_x = 100
    Cm._start_fight(nil, k3, { mode = "attack", force = true, by = "brain" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "approach" end, 3)
    MV.extra = { status = "unreachable", unreachable = { reason = "leader_above_jump_height", detail = "dz=2.7m d=13.7m lp_fail=verify_exhausted" }, lp_fail = "verify_exhausted" }
    run_until(function() return Cm._state().fight == nil end, 10)
    local r3 = Cm._state().last.result
    check("ledge (22:01 replay): path_blocked, higher than he can jump", r3 and r3.reason == "path_blocked" and r3.data.detail == "I can't reach the Kebbit: it's higher up than I can jump.", r3 and r3.data and r3.data.detail)
    MV.extra, world.wall_x = nil, nil
    A.reset(nil)
    -- (d) a target that keeps moving away (the distance keeps changing, so no single stall): the chase budget
    reset_world()
    local k4 = new_creature("BP_AI_Kebbit_Character_02_C_run", "Kebbit", { X = 1500, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 1 })
    world.on_step = function() -- runs away a touch slower than he walks, with a zig-zag
        k4.loc.X = k4.loc.X + 4.96
        k4.loc.Y = 300 * math.sin(T * 0.7)
    end
    local t0 = T
    Cm._start_fight(nil, k4, { mode = "attack", force = true, by = "brain" })
    run_until(function() return Cm._state().fight == nil end, 60)
    local r4 = Cm._state().last.result
    check("chase: too_far / cant_catch, never a bare timeout", r4 and r4.reason == "too_far" and r4.data.why == "cant_catch", r4 and r4.reason)
    check("chase: ends on the chase budget (~30 s)", T - t0 < 40, T - t0)
    check("chase: says what happened", r4 and r4.data.detail:find("chased the Kebbit", 1, true) ~= nil, r4 and r4.data and r4.data.detail)
    world.on_step = nil
    A.reset(nil)
end

-- ================================================================ 10d. AI actions (dragon abilities) + boss phases (velgar.md gaps 1 and 3)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local v = new_creature("BP_AI_DragonVelgar_Character_C_1", "Velgar", { X = 400, Y = 0, Z = 0 }, { hp = 6000, pl = 4, arch = 0, boss = true })
    local cur = { cls = nil }
    local acomp = obj({ GetOwner = function() return v end }, "BP_DragonVelgar_ActionsComponent_C /x")
    setmetatable(acomp, { __index = function(_, k) if k == "CurrentAction" then
        return cur.cls and obj({ GetClass = function() return obj({}, "BlueprintGeneratedClass /Game/AI/Dragon/" .. cur.cls .. "." .. cur.cls) end }, "Action /x") end end })
    -- the arena's replicated phase
    local arena = obj({ PhaseRuntimeData = { PhaseIndex = 0, bTransitioningToNext = false },
                        PhaseData = { ForEach = function(_, f) for i = 1, 4 do f(i, {}) end end } }, "PhasedDragonArenaAILevelData /Game/L.L:PersistentLevel.Arena_1")
    local real_ffo = FindFirstOf
    FindFirstOf = function(cls) if cls == "PhasedDragonArenaAILevelData" then return arena end return real_ffo(cls) end
    local n0 = #read_activity()
    check("ability: fight starts on a boss", Cm._start_fight(nil, v, { mode = "attack", force = true, by = "brain" }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 5)
    -- 1. a poison breath to the front: answered like a telegraph (unblockable -> a dodge), keyed by its class
    cur.cls = "DAA_DragonVelgar_PoisonBreath_Front_C"
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return acomp end }, { get = function() return 7 end })
    local defended = run_until(function() local f = Cm._state().fight; return f and f.phase == "defend" end, 1)
    local f = Cm._state().fight
    check("ability: the breath is defended", defended and f.def and f.def.key == "Velgar:DAA_DragonVelgar_PoisonBreath_Front_C", f and f.def and f.def.key)
    check("ability: unblockable -> dodge", f and f.def and f.def.plan.action == "dodge", f and f.def and f.def.plan.action)
    local ev
    for i = n0 + 1, #read_activity() do local l = read_activity()[i]; if l:find('"kind":"creature_ability"', 1, true) then ev = l end end
    check("ability: activity event with kind and side", ev and ev:find('"ability":"breath_cone"', 1, true) and ev:find('"side":"front"', 1, true), ev)
    run_until(function() local g = Cm._state().fight; return g and g.phase ~= "defend" end, 5)
    -- 2. he flies (Reposition) and the arena moves to the next phase: hold, never "too far" / "can't catch"
    cur.cls = "DAA_DragonVelgar_Reposition_C"
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return acomp end }, { get = function() return 8 end })
    arena.PhaseRuntimeData = { PhaseIndex = 1, bTransitioningToNext = true }
    v.loc = { X = 6000, Y = 0, Z = 2000 } -- 60 m up and away
    local t0 = T
    run_until(function() return Cm._state().fight == nil end, 45)
    check("boss: no too_far / cant_catch / path_blocked while he is up (45 s)", Cm._state().fight ~= nil, Cm._state().last and Cm._state().last.result.reason)
    local st = Cm.status()
    check("boss: phase in combat_status", st.boss and st.boss.index == 1 and st.boss.transitioning == true and st.boss.airborne == true and st.boss.phases == 4,
          st.boss and st.boss.index)
    check("boss: the hold shows in the fight", st.fight and st.fight.boss_hold == true)
    local ex = Cm.state_extras(nil, { nearby_entities = {} })
    check("boss: get_state boss_fight for the digest", ex.boss_fight and ex.boss_fight.phase == 1 and ex.boss_fight.airborne == true)
    local pev
    for i = n0 + 1, #read_activity() do local l = read_activity()[i]; if l:find('"kind":"boss_phase"', 1, true) then pev = l end end
    check("boss: boss_phase activity event", pev and pev:find('"phase":1', 1, true) and pev:find('"airborne":true', 1, true), pev)
    -- 3. he lands (the action stops, the transition ends): the normal budgets apply again
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StopCurrentAIAction"]({ get = function() return acomp end })
    arena.PhaseRuntimeData = { PhaseIndex = 1, bTransitioningToNext = false }
    run_until(function() return Cm._state().fight == nil end, 40)
    local r = Cm._state().last.result
    check("boss: landed but out of reach -> the normal truthful ending again", r and (r.reason == "too_far" or r.reason == "path_blocked"), r and r.reason)
    FindFirstOf = real_ffo
    A.reset(nil)
end

-- ================================================================ 10e. poisoned mid-fight: read the status (properties), use a cure from the wiki data
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local poison = { EffectType = 2, CurrentValue = 0, Config = { MaximumValue = 100 } }
    pawn.TrackedStatusEffectsComponent = obj({ TrackedStatusEffectInstances = { ForEach = function(_, f)
        f(1, { get = function() return obj(poison, "TrackedStatusEffectInstance /x") end }) end } }, "C /x")
    local saved_hotbar = inv_list.hotbar
    inv_list.hotbar = { { item = "ITEM_Consumable_Sandwich_Veggie", name = "Forager's Sandwich", count = 2, consumable = "food", heal = 70, slot = 1 },
                        { item = "ITEM_Potion_Antipoison_Lesser", name = "Lesser Antipoison Potion", count = 3, consumable = "potion", slot = 2 } }
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_poison", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    local n0 = #read_activity()
    Cm._start_fight(nil, gob, { mode = "attack", force = true, by = "brain" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    poison.CurrentValue = 40
    world.on_step = function() for _, u in ipairs(INV.uses) do if u == "ITEM_Potion_Antipoison_Lesser" then poison.CurrentValue = 0 end end end
    check("poison: a cure is used (the potion that cures beats the food that only resists)",
          run_until(function() for _, u in ipairs(INV.uses) do if u == "ITEM_Potion_Antipoison_Lesser" then return true end end end, 3), table.concat(INV.uses, ","))
    run_until(function() local f = Cm._state().fight; return f and (f.n_cures or 0) >= 1 end, 6)
    local ev
    for i = n0 + 1, #read_activity() do local l = read_activity()[i]; if l:find('"kind":"cured"', 1, true) then ev = l end end
    check("poison: verified cure -> cured event", ev and ev:find('"status":"Poison"', 1, true) and ev:find('"before":40', 1, true), ev)
    local ex = Cm.state_extras(nil, { nearby_entities = {} })
    check("poison: the remembered perk is in get_state", ex.buffs_remembered and ex.buffs_remembered.Antipoison ~= nil, ex.buffs_remembered and next(ex.buffs_remembered))
    -- no cure carried: said once, not spammed
    world.on_step = nil
    poison.CurrentValue = 30
    inv_list.hotbar = { { item = "ITEM_Consumable_Sandwich_Veggie", name = "Seared Anchovies", count = 2, consumable = "food", heal = 30, slot = 1 } }
    Cm._state().fight.next_eat = nil
    run_until(function() return false end, 3)
    local nst = 0
    for i = n0 + 1, #read_activity() do if read_activity()[i]:find('"kind":"status"', 1, true) then nst = nst + 1 end end
    check("poison: no cure -> one status event (have_cure false)", nst == 1, nst)
    ex = Cm.state_extras(nil, { nearby_entities = {} })
    check("poison: get_state status_effects", ex.status_effects and ex.status_effects.Poison == "30/100", ex.status_effects and ex.status_effects.Poison)
    Cm.stop(nil, "test")
    inv_list.hotbar, pawn.TrackedStatusEffectsComponent, world.on_step = saved_hotbar, nil, nil
    A.reset(nil)
end

-- ================================================================ 10f. packs (S1: wolves, thugs): two or three on him at once
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local w1 = new_creature("BP_AI_Wolf_C_1", "Wolf", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    local w2 = new_creature("BP_AI_Wolf_C_2", "Wolf", { X = 0, Y = 150, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, w1, { mode = "attack", force = true, by = "brain" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    -- (a) w1 swings (lands late), then w2 swings and lands first: answer w2 now
    world.resolved = nil
    goblin_attack(w1, 1.4)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "defend" end, 1)
    step(10)
    goblin_attack(w2, 0.5)
    local switched = run_until(function() local f = Cm._state().fight; return f and f.def and f.def.attacker == "BP_AI_Wolf_C_2" end, 1)
    check("pack: the swing that lands first is answered first", switched, Cm._state().fight.def and Cm._state().fight.def.attacker)
    check("pack: simultaneous swings counted", (Cm._state().fight.n_multi or 0) >= 1)
    run_until(function() local f = Cm._state().fight; return f and f.phase ~= "defend" end, 5)
    -- (b) w1 swings early, w2 later: w2 is queued and answered right after
    world.resolved = nil
    goblin_attack(w1, 0.5)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "defend" and f.def.attacker == "BP_AI_Wolf_C_1" end, 1)
    step(5)
    hooks["/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies"]({ get = function()
        return obj({ GetOwner = function() return w2 end, CurrentAttack = { AttackData = obj({ GetDamageTime = function() return 1.6 end,
            AttackPropertyFlags = 0, GetLastDamageTime = function() return 1.6 end, GetDuration = function() return 2 end,
            Damage = { ForEach = function() end } }, "ATK_Wolf_Bite_C /Game/AI/Wolf/ATK_Wolf_Bite.Default__ATK_Wolf_Bite_C") } }, "C /x") end },
        { get = function() return 7 end })
    local queued = run_until(function() local f = Cm._state().fight; return f and f.phase == "defend" and f.def.attacker == "BP_AI_Wolf_C_2" end, 4)
    check("pack: the later swing is queued and answered after", queued, Cm._state().fight.def and Cm._state().fight.def.attacker)
    run_until(function() local f = Cm._state().fight; return f and f.phase ~= "defend" end, 5)
    -- (c) low HP with the pack on him: back away from the PACK (both wolves), not just the target
    local o0 = { defense = Cm.orders.defense, disengage = Cm.orders.disengage, heal_hp = Cm.orders.heal_hp, reengage_hp = Cm.orders.reengage_hp }
    Cm.set_orders({ defense = "auto", disengage = true, heal_hp = 0.5, reengage_hp = 0.8 })
    Cm._state().attackers["BP_AI_Wolf_C_2"] = T
    pawn.hp = 40
    run_until(function() return MV.mode == "go_to" end, 3)
    check("pack: disengages away from both (the centroid)", type(MV.goal) == "table" and MV.goal[1] < 0 and MV.goal[2] < 0,
          MV.goal and (tostring(MV.goal[1]) .. "," .. tostring(MV.goal[2])))
    Cm.stop(nil, "test")
    Cm.set_orders(o0)
    A.reset(nil)
    -- (d) the target runs off while another is biting him in reach: fight the one on him
    reset_world()
    pawn.hp = 100
    local w3 = new_creature("BP_AI_Wolf_C_3", "Wolf", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    local w4 = new_creature("BP_AI_Wolf_C_4", "Wolf", { X = -120, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, w3, { mode = "attack", force = true, by = "brain" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    Cm._state().attackers["BP_AI_Wolf_C_4"] = T
    w3.loc = { X = 2500, Y = 0, Z = 0 }
    local re = run_until(function() local f = Cm._state().fight; return f and f.target_id == "BP_AI_Wolf_C_4" end, 3)
    check("pack: the target ran off; fights the wolf biting him", re, Cm._state().fight and Cm._state().fight.target_id)
    w3.loc = { X = 300, Y = 0, Z = 0 } -- back, still on him
    Cm._state().telegraphs["BP_AI_Wolf_C_3"] = T
    run_until(function() return false end, 1)
    Cm.stop(nil, "test")
    local ends = read_activity()
    check("pack: combat_end reports the pack size", (ends[#ends] or ""):find('"pack":', 1, true) ~= nil, ends[#ends])
    A.reset(nil)
end

-- ================================================================ 10g. ground hazards -> move's avoid zones (velgar.md gap 2)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_haz", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    local meteors = {}
    local real_find = FindAllOf
    FindAllOf = function(cls)
        if cls == "AIMeteorProjectile" then
            local out = {}
            for _, m in ipairs(meteors) do if not m._dead_obj then out[#out + 1] = m end end
            return out
        end
        return real_find(cls)
    end
    local function meteor(id, at, radius, tel)
        local m = obj({ Radius = radius, TelegraphTime = tel, loc = at }, "BP_DragonVelgar_MeteorStrike_MeteorProjectile_C /Game/L.L:PersistentLevel." .. id)
        function m:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
        meteors[#meteors + 1] = m
        return m
    end
    Cm._start_fight(nil, gob, { mode = "attack", force = true, by = "brain" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    -- (a) a meteor circle lands on him in 2 s: zones are handed to move, he walks out, then the previous move is restored
    MV.escape_reply = { ok = true, at = { 6, 0, 0 }, eta_s = 0.8 }
    local n0 = #read_activity()
    local m1 = meteor("Meteor_1", { X = pawn.loc.X, Y = pawn.loc.Y, Z = 0 }, 400, 2.0)
    check("hazard: escape_zones called with the time left",
          run_until(function() return (MV.escapes or 0) >= 1 end, 3) and MV.escape_opts.time_s > 1 and MV.escape_opts.time_s <= 2, MV.escape_opts and MV.escape_opts.time_s)
    local z = (MV.zones or {})[1] or {}
    check("hazard: the zone is in metres with r_cm and an expiry", z.kind == "circle" and math.abs(z.x - pawn.loc.X / 100) < 3 and z.r_cm == 400 and z.until_s ~= nil,
          z.id)
    check("hazard: holds the fight while walking out", Cm._state().fight.escape ~= nil)
    MV.calls = {}
    local restored = run_until(function() for _, c in ipairs(MV.calls) do if c:find("^restore") then return true end end end, 3)
    check("hazard: move.restore(prev) once out", restored, table.concat(MV.calls, ","))
    local ev
    for i = n0 + 1, #read_activity() do local l = read_activity()[i]; if l:find('"kind":"hazard"', 1, true) then ev = l end end
    check("hazard: activity says how he answered", ev and ev:find('"answer":"walk_out"', 1, true) and ev:find('"hazard":"meteor"', 1, true), ev)
    m1._dead_obj = true
    -- (b) too slow: a dodge outward instead
    MV.escape_reply = { ok = false, why = "too_slow", eta_s = 1.9 }
    Cm._state().fight.escaped_zone = nil
    local ev0 = world.injected.IA_Player_Evade or 0
    meteor("Meteor_2", { X = pawn.loc.X + 50, Y = pawn.loc.Y, Z = 0 }, 400, 0.6)
    check("hazard: too_slow -> evade pressed", run_until(function() return (world.injected.IA_Player_Evade or 0) > ev0 end, 2), world.injected.IA_Player_Evade)
    local dodged
    for i = n0 + 1, #read_activity() do local l = read_activity()[i]; if l:find('"answer":"dodge"', 1, true) and l:find('"why":"too_slow"', 1, true) then dodged = l end end
    check("hazard: the dodge is reported with the reason", dodged ~= nil)
    -- (c) the fight ends: his zones are cleared
    MV.zones = nil
    Cm.stop(nil, "test")
    check("hazard: zones cleared at the fight's end", type(MV.zones) == "table" and #MV.zones == 0)
    FindAllOf = real_find
    MV.escape_reply, MV.escapes = nil, nil
    A.reset(nil)
end

-- ================================================================ 11a. hit while looting (live 09:41): the impact event names the attacker, he fights back
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    world.drop_on_death = true
    local a = new_creature("BP_AI_RuntGoblin_Character_C_la", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 20, pl = 1, arch = 0 })
    local b = new_creature("BP_AI_Kebbit_Character_02_C_lb", "Kebbit", { X = 0, Y = 300, Z = 0 }, { hp = 60, pl = 1, arch = 1 })
    check("loot-hit: commanded fight starts", Cm._start_fight(nil, a, { mode = "attack", force = true, by = "brain" }).ok)
    check("loot-hit: loots after the kill", run_until(function() local f = Cm._state().fight; return f and f.phase == "loot" end, 15))
    -- B's attack lands: its impact event, then the HP drop (no damage multicast reaches the client)
    local comp = obj({ GetOwner = function() return b end }, "C /x")
    hooks["/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData"]({ get = function() return comp end })
    pawn.hp = pawn.hp - 7
    local switched = run_until(function() local f = Cm._state().fight; return f and f.target_id == "BP_AI_Kebbit_Character_02_C_lb" end, 2)
    check("loot-hit: the hit is attributed and he turns on the attacker", switched)
    run_until(function() return Cm._state().fight == nil end, 30)
    check("loot-hit: the attacker is dealt with", b.hp <= 0, b.hp)
    world.drop_on_death = nil
    A.reset(nil)
end

-- ================================================================ 11b. a telegraph mid-disengage: defend, then back to the disengage (live 08:11 dropped it)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_heal2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    check("heal+defend: fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "disengage" end, 2)
    world.resolved, world.result = nil, nil
    goblin_attack(gob, 0.9)
    check("heal+defend: defends the telegraph", run_until(function() local f = Cm._state().fight; return f and f.phase == "defend" end, 1))
    run_until(function() return world.resolved end, 3)
    local f = Cm._state().fight
    local back = run_until(function() local g = Cm._state().fight; return g and g.phase ~= "defend" end, 3)
    check("heal+defend: back to the disengage after the defence", back and (Cm._state().fight.phase == "disengage" or pawn.hp >= 80), Cm._state().fight and Cm._state().fight.phase)
    check("heal+defend: re-engages once healed", run_until(function() local g = Cm._state().fight; return g and (g.phase == "approach" or g.phase == "engage") and pawn.hp >= 80 end, 60), pawn.hp)
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

-- ================================================================ 13. ranged: crossbow vs a moving goblin, learning the real bolt
reset_world()
do
    local Rg = assert(loadfile(root .. "/client_mod/scripts/ranged.lua"))()
    _G.DWRanged = nil
    Cm.set_modules({ ranged = Rg })
    world.ranged = true
    held.right, held.left = "ITEM_Crossbow_Adamant", nil
    local truth = { speed = 5600, gz = -1700, t0 = 0.1 }
    local projs = {}
    local ammo = obj({ ProjectileData = { LaunchSpeed = 4000, OverrideGravityZ = 0, TimeWithoutGravity = 0, MaxSimulationTime = 3 } },
                     "RangedAmmoData /Game/Ammo/ITEM_Ammo_Bolts_Bone.ITEM_Ammo_Bolts_Bone")
    local wactor = obj({}, "BP_Crossbow_Adamant_C /Game/L.L:PersistentLevel.BP_Crossbow_Adamant_C_1")
    function wactor:K2_GetActorLocation() return { X = pawn.loc.X, Y = pawn.loc.Y, Z = pawn.loc.Z + 60 } end
    local rcomp = obj({ GetOwner = function() return pawn end, GetEquippedRangedAmmoDataForCurrentWeapon = function() return ammo end,
                        IsAimModeActive = function() return world.block_last and T - world.block_last < 0.05 end,
                        HasRequiredAmmoEquipped = function() return true end, RangedWeaponActor = wactor,
                        GetCurrentArrowInaccuracy = function() return 0 end }, "PlayerRangedAttackComponent /x.RC")
    rcomp.HasReachedFullAccuracy = false
    local cam_mgr = obj({ GetCameraLocation = function() return { X = pawn.loc.X - 250, Y = pawn.loc.Y + 40, Z = pawn.loc.Z + 130 } end }, "PCM /x")
    pc.PlayerCameraManager = cam_mgr
    pc.SetControlRotation = function(_, r) world.ctrl_rot = { Pitch = r.Pitch, Yaw = r.Yaw } end
    local real_find = FindAllOf
    FindAllOf = function(cls)
        if cls == "PlayerRangedAttackComponent" then return { rcomp } end
        if cls == "DominionProjectile" then
            local out = {}
            for _, pr in ipairs(projs) do if not pr._dead_obj then out[#out + 1] = pr end end
            return out
        end
        return real_find(cls)
    end
    inv_list.hotbar[#inv_list.hotbar + 1] = { item = "ITEM_Crossbow_Adamant", slot = 4 }
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_rng", "Goblin Runt", { X = 2000, Y = 0, Z = 0 }, { hp = 150, pl = 1, arch = 0 })
    local dirY = 1
    local aim_started
    local nshots = 0
    world.on_step = function()
        -- the goblin strafes at 3 m/s between Y = -400 and +400
        gob.loc.Y = gob.loc.Y + dirY * 3
        if math.abs(gob.loc.Y) > 400 then dirY = -dirY end
        -- aim mode: full accuracy 0.5 s after the aim key is held
        local aiming = world.block_last and T - world.block_last < 0.05
        if aiming then aim_started = aim_started or T else aim_started = nil end
        rcomp.HasReachedFullAccuracy = aim_started ~= nil and T - aim_started >= 0.5
        -- fly the bolts with the TRUE parameters
        for _, pr in ipairs(projs) do
            if not pr._dead_obj then
                local ft = T - pr.t0
                pr.loc = Rg.position(pr.m, pr.dir, truth, ft)
                local gp = { X = gob.loc.X, Y = gob.loc.Y, Z = gob.loc.Z }
                local dx, dy, dz = pr.loc.X - gp.X, pr.loc.Y - gp.Y, pr.loc.Z - gp.Z
                if math.sqrt(dx * dx + dy * dy + dz * dz) < 60 and gob.hp > 0 then
                    gob.hp = math.max(0, gob.hp - 30)
                    multicast(gob, pawn, 30)
                    pr._dead_obj = true
                elseif ft > 2.5 or pr.loc.Z < -500 then pr._dead_obj = true end
            end
        end
    end
    -- the game fires on the primary press while aiming: from the muzzle toward the crosshair point
    local real_inject = eis.InjectInputVectorForAction
    eis.InjectInputVectorForAction = function(self, action, vv, a, b)
        local name = action:GetFullName():match("%.([%w_]+)$")
        local rising = last_inject[name] ~= frame_n - 1
        real_inject(self, action, vv, a, b)
        if name == "IA_PrimaryAction" and rising and world.ctrl_rot then
            nshots = nshots + 1
            local cam = cam_mgr:GetCameraLocation()
            local m = wactor:K2_GetActorLocation()
            local r = world.ctrl_rot
            local fwd = { X = math.cos(math.rad(r.Pitch)) * math.cos(math.rad(r.Yaw)), Y = math.cos(math.rad(r.Pitch)) * math.sin(math.rad(r.Yaw)), Z = math.sin(math.rad(r.Pitch)) }
            local tp = { X = cam.X + fwd.X * 6000 - m.X, Y = cam.Y + fwd.Y * 6000 - m.Y, Z = cam.Z + fwd.Z * 6000 - m.Z }
            local pr = obj({ m = m, dir = Rg.vec.norm(tp), t0 = T, loc = m }, "BP_Arrow_Base_C /Game/L.L:PersistentLevel.BP_Arrow_Base_C_" .. nshots)
            function pr:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
            projs[#projs + 1] = pr
        end
    end
    local r = Cm.attack(nil, "Goblin Runt", { force = true })
    check("ranged: fight starts", r.ok, r.reason)
    run_until(function() return Cm._state().fight == nil end, 90)
    eis.InjectInputVectorForAction = real_inject
    FindAllOf = real_find
    local res = Cm._state().last.result
    local key = "ITEM_Crossbow_Adamant|ITEM_Ammo_Bolts_Bone"
    local p = Rg.profile(key)
    local m = Rg.metrics()[key]
    check("ranged: kept the crossbow (no melee swap)", INV.equips[1] == nil or INV.equips[1] == "ITEM_Crossbow_Adamant", INV.equips[1])
    check("ranged: shots fired", nshots >= 5, nshots)
    check("ranged: the goblin died", gob.hp <= 0 and res.ok, tostring(gob.hp) .. " " .. tostring(res.reason))
    check("ranged: learned the bolt speed from the real flight", math.abs(p.speed - truth.speed) / truth.speed < 0.08, p.speed)
    check("ranged: learned gravity", math.abs(p.gz - truth.gz) / math.abs(truth.gz) < 0.15, p.gz)
    check("ranged: metrics by distance and speed", m and m.shots >= 5 and next(m.by_dist) ~= nil and next(m.by_speed) ~= nil)
    check("ranged: hit rate improves (later shots hit)", m and m.hits >= 5, m and (m.hits .. "/" .. m.shots))
    world.ranged = nil
    inv_list.hotbar[#inv_list.hotbar] = nil
    pc.PlayerCameraManager, pc.SetControlRotation = nil, function() end
    A.reset(nil)
end

-- ================================================================ 14. defensive abilities: learn what avoids a lunge (bandit)
do
    _G.DWDefense = nil
    local function ctxf() return { dist_cm = 300, latency_s = 0.03, stamina = 60, can_parry = false, can_block = true, block_cost = 10,
        evade_cost = 15, hp_frac = 1, max_hp = 100, heal_hp = 0.5,
        abilities = { phase_dash = { available = true, latency_s = 0.4 }, tempest_shield = { available = true, latency_s = 0.4 },
                      windstep = { available = false, why = "no runes" } } } end
    local info = { key = "Dragon:ATK_Lunge", dmg_time = 1.6 }
    local first = Dm.plan(info, ctxf(), { defense = "auto" }, function() return 0.5 end)
    check("abilities: with no history the rule answer comes first (block)", first.action == "block", first.action)
    check("abilities: unavailable ability not offered", (function() for _, c in ipairs(first.candidates) do if c.action == "windstep" then return false end end return true end)())
    Dm.observe_lunge("Dragon:ATK_Lunge", 450)
    check("threat: a learned lunge extends reach and tags it", Dm.threat(info, 100).tags.lunge and Dm.threat(info, 100).reach_cm >= 450 + 300)
    -- the fake world: a lunge hurts unless answered with Phase Dash (or a shield + block)
    local function outcome_of(action)
        if action == "phase_dash" or action == "tempest_shield" then return "avoided", 0 end
        return "hit", 40
    end
    local picks = {}
    math.randomseed(3)
    for i = 1, 25 do
        local p = Dm.plan(info, ctxf(), { defense = "auto" })
        local o, dmg = outcome_of(p.action)
        Dm.feedback(info.key, p.action, o, dmg)
        picks[#picks + 1] = p.action
    end
    local late_ok = 0
    for i = 16, 25 do if picks[i] == "phase_dash" or picks[i] == "tempest_shield" then late_ok = late_ok + 1 end end
    check("bandit: learns an ability avoids the lunge (>= 8 of the last 10)", late_ok >= 8, table.concat(picks, ","))
    check("bandit: learned the lunge's damage", (Dm.rec(info.key).damage or 0) > 30, Dm.rec(info.key).damage)
    local p2 = Dm.plan(info, ctxf(), { defense = "auto", abilities = { phase_dash = false, tempest_shield = false } }, function() return 0.5 end)
    check("orders: the model can forbid abilities", p2.action ~= "phase_dash" and p2.action ~= "tempest_shield", p2.action)
    local pd = Dm.plan(info, (function() local c = ctxf(); c.abilities.tempest_shield = nil; return c end)(), { defense = "auto" }, function() return 0.5 end)
    if pd.action == "phase_dash" then
        check("phase dash timing: cast before the evade, evade before impact", pd.cast_at_s < pd.evade_at_s and pd.evade_at_s < 1.6 and pd.spell_asset == "USD_PhaseDash")
    else
        check("phase dash chosen when it is the learned answer", false, pd.action)
    end
    local tooshort = Dm.plan({ key = "Rat:Bite", dmg_time = 0.4 }, ctxf(), {}, function() return 0.5 end)
    check("abilities: a too-short telegraph leaves no time to cast", (function() for _, c in ipairs(tooshort.candidates) do if c.action == "phase_dash" then return false end end return true end)())
    _G.DWDefense = nil
end

-- ================================================================ 15. live-like: a lunging attack, Phase Dash through the spells contract
reset_world()
do
    _G.DWDefense = nil
    PERKS.unlocked = {}
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local casts = {}
    local fake_spells = {
        ability_status = function(asset) return { available = asset ~= "USD_Windstep", latency_s = 0.35 } end,
        cast_now = function(log, asset, opts)
            casts[#casts + 1] = { asset = asset, t = T, owner = opts and opts.owner_token }
            if asset == "USD_TempestShield" then world.shield_until = T + 60 else world.active_spell = { asset = asset, t = T } end
            local job = { t = T }
            function job.poll(self) if T - self.t >= 0.3 then return { ok = true, cast_t = self.t + 0.3 } end end
            return job
        end,
    }
    Cm.set_modules({ spells = fake_spells })
    local drake = new_creature("BP_AI_Drake_C_1", "Drake", { X = 600, Y = 0, Z = 0 }, { hp = 50000, pl = 2, arch = 0 })
    check("lunge: fight starts", Cm._start_fight(nil, drake, { mode = "attack", force = true }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 6)
    local results = {}
    for i = 1, 12 do
        world.resolved, world.result = nil, nil
        -- telegraph: a 1.6 s lunge; the server resolves it at impact
        local shape = obj({ Depth = 250, ZHeight = 150, TopAngle = 60, Offset = { X = 0, Z = 0 } }, "DominionShape_Wedge /Game/x.Shape")
        local ad = obj({ AttackPropertyFlags = 0, GetDamageTime = function() return 1.6 end, GetLastDamageTime = function() return 1.6 end,
                         GetDuration = function() return 2.5 end, Damage = { ForEach = function(_, f) f(1, { get = function() return { Time = 1.6, Shape = shape } end }) end } },
                       "ATK_Drake_Lunge_C /Game/AI/Drake/ATK_Drake_Lunge.Default__ATK_Drake_Lunge_C")
        local comp = obj({ GetOwner = function() return drake end, CurrentAttack = { AttackData = ad } }, "C /x")
        hooks["/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies"]({ get = function() return comp end }, { get = function() return 3 end })
        drake.loc.X = pawn.loc.X + 500 -- it rears back, then lunges 3.5 m
        local impact, start_x = T + 1.6, drake.loc.X
        world.on_step = function()
            -- the lunge: the drake closes 4 m during the wind-up
            if T < impact then drake.loc.X = math.max(pawn.loc.X + 150, drake.loc.X - 2.5) end
            if T >= impact and not world.resolved then
                world.resolved = true
                local sp = world.active_spell
                local phasing = sp and sp.asset == "USD_PhaseDash" and T - sp.t < 2.0 and world.evading_until and world.evading_until > T
                local shielded = world.shield_until and world.shield_until > T and world.block_last and T - world.block_last < 0.05
                if phasing or shielded then world.result = "avoided"
                else
                    pawn.hp = pawn.hp - 30
                    multicast(pawn, drake, 30)
                    world.result = "hit"
                end
                if phasing then world.active_spell = nil end -- the dash is used up; a shield lasts
                -- the client receives the AI's damage-cache multicast at the impact either way
                hooks["/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData"]({ get = function() return comp end })
            end
        end
        run_until(function() local f = Cm._state().fight; return world.resolved and f and f.phase ~= "defend" end, 4)
        results[#results + 1] = world.result
        if os.getenv("DBG") then local f = Cm._state().fight; print("round", i, world.result, f and f.last_defence and f.last_defence.action, f and f.n_precasts) end
        pawn.hp = 100 -- keep the fight going (heal between rounds)
        drake.loc.X = start_x
        step(80)
    end
    local late = 0
    for i = 8, 12 do if results[i] == "avoided" then late = late + 1 end end
    check("lunge: learns to avoid it with an ability (>= 4 of the last 5)", late >= 4, table.concat(results, ","))
    check("lunge: abilities cast through the spells contract with the fight's arbiter token", #casts >= 1 and casts[1].owner ~= nil, #casts)
    check("lunge: lunge distance learned", (Dm.rec("Drake:ATK_Drake_Lunge").lunge_cm or 0) > 200, Dm.rec("Drake:ATK_Drake_Lunge").lunge_cm)
    Cm.stop(nil, "test")
    Cm.set_modules({ spells = false })
    A.reset(nil)
end

-- ================================================================ 16. combat_brief: facts for the model
reset_world()
do
    new_creature("BP_AI_RuntGoblin_Character_C_br", "Goblin Runt", { X = 800, Y = 0, Z = 0 }, { hp = 156, pl = 1, arch = 0 })
    local b = Cm.HANDLERS.combat_brief(nil, { target = "Goblin Runt" }, {})
    check("brief: ok", b.ok, b.reason)
    local d = b.data or {}
    check("brief: creature and power levels", d.creature and d.creature.power_level == 1 and d.me.power_level == 2)
    check("brief: wiki prior weakness (Fire) from the data file", d.weaknesses.priors and d.weaknesses.priors.weak["DamageType.Magical.Fire"])
    local dag
    for _, w in ipairs(d.weapons or {}) do if w.item == "ITEM_Dagger_Bone" then dag = w end end
    check("brief: his weapons with damage types vs the target", dag and dag.vs_target["DamageType.Physical.Stab"] == "neutral" and dag.dps)
    check("brief: healing food listed", d.food and #d.food >= 1 and d.food[1].heal == 10)
    check("brief: estimate as information", d.assessment and d.assessment.verdict ~= nil)
    check("brief: invalid args", Cm.HANDLERS.combat_brief(nil, {}, {}).reason == "invalid_args")
end

-- ================================================================ 17. pre-casting: cadence, timing, active windows
do
    _G.DWDefense = nil
    Dm.observe_cadence("Drake", 0); Dm.observe_cadence("Drake", 3); Dm.observe_cadence("Drake", 6)
    local eta, iv = Dm.next_attack_eta("Drake", 7)
    check("cadence: learned interval and next attack", math.abs(iv - 3) < 1e-6 and math.abs(eta - 2) < 1e-6, tostring(eta) .. " " .. tostring(iv))
    Dm.observe_damage("Drake:ATK_Lunge", 40)
    Dm.observe("Drake:ATK_Lunge", 1.6)
    local ctx = { max_hp = 100, stamina = 60, latency_s = 0.03,
                  abilities = { phase_dash = { available = true, latency_s = 2.05 }, tempest_shield = { available = false } } }
    local d1 = Dm.precast_decision("Drake", 7.0, ctx, { defense = "auto" }, function() return 0.5 end)
    check("precast: phase dash planned when reacting is too slow (2.05 s cast vs 1.6 s wind-up)", d1 and d1.ability == "phase_dash", d1 and d1.why)
    check("precast: not yet (window would close before the impact)", d1 and d1.cast_now == false, d1 and d1.cast_in_s)
    local d2 = Dm.precast_decision("Drake", 7.6, ctx, { defense = "auto" }, function() return 0.5 end)
    check("precast: cast now so the 2 s window covers the expected impact", d2 and d2.cast_now == true, d2 and d2.cast_in_s)
    local nod = Dm.precast_decision("Drake", 7.6, ctx, { defense = "auto", abilities = { phase_dash = false } }, function() return 0.5 end)
    check("precast: the model can forbid it", nod == nil)
    local ctx2 = { max_hp = 100, abilities = { tempest_shield = { available = true, latency_s = 2.0 } } } -- too slow to react
    local d3 = Dm.precast_decision("Drake", 7.0, ctx2, {}, function() return 0.5 end)
    check("precast: tempest shield cast at once against a dangerous attacker", d3 and d3.ability == "tempest_shield" and d3.cast_now)
    check("precast: none for a harmless creature", Dm.precast_decision("Kebbit", 7.0, ctx2, {}, function() return 0.5 end) == nil)
    local p = Dm.plan({ key = "Drake:ATK_Lunge", dmg_time = 1.6 }, { dist_cm = 300, stamina = 60, can_block = true, block_cost = 10, evade_cost = 15,
        max_hp = 100, hp_frac = 1, active = { phase_dash = 1.8 } }, { defense = "auto" }, function() return 0.5 end)
    check("plan: an active Phase Dash window -> dash through (phase_dash_pre, evade input)", p.action == "phase_dash_pre" and p.input == "dodge", p.action)
    _G.DWDefense = nil
end

-- ================================================================ 18. live-like: a rhythmic lunge, Phase Dash too slow to react -> learns to pre-cast
reset_world()
do
    _G.DWDefense = nil
    PERKS.unlocked = {}
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local casts = {}
    local fake_spells = {
        ability_status = function(asset)
            return { available = asset == "USD_PhaseDash", latency_s = 2.05, why = asset ~= "USD_PhaseDash" and "no runes" or nil }
        end,
        cast_now = function(log, asset, opts)
            local rec = { asset = asset, t = T, owner = opts and opts.owner_token, polls = 0 }
            casts[#casts + 1] = rec
            local job = {}
            function job.poll() rec.polls = rec.polls + 1; if T - rec.t >= 2.05 then rec.done = rec.done or T; return { ok = true, cast_t = rec.done, latency_s = 2.05 } end end
            return job
        end,
    }
    Cm.set_modules({ spells = fake_spells })
    local drake = new_creature("BP_AI_Drake_C_2", "Drake", { X = 300, Y = 0, Z = 0 }, { hp = 50000, pl = 2, arch = 0 })
    check("rhythm: fight starts", Cm._start_fight(nil, drake, { mode = "attack", force = true }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 6)
    local results = {}
    local next_t = T + 0.5
    for i = 1, 14 do
        run_until(function() return T >= next_t end, 5)
        world.resolved, world.result = nil, nil
        local ad = obj({ AttackPropertyFlags = 0, GetDamageTime = function() return 1.6 end, GetLastDamageTime = function() return 1.6 end,
                         GetDuration = function() return 2.5 end, Damage = { ForEach = function(_, f) f(1, { get = function() return { Time = 1.6 } end }) end } },
                       "ATK_Drake_Lunge_C /Game/AI/Drake/ATK_Drake_Lunge.Default__ATK_Drake_Lunge_C")
        local comp = obj({ GetOwner = function() return drake end, CurrentAttack = { AttackData = ad } }, "C /x")
        hooks["/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies"]({ get = function() return comp end }, { get = function() return 3 end })
        local impact = T + 1.6
        world.on_step = function()
            if T >= impact and not world.resolved then
                world.resolved = true
                local phasing = false
                for _, c in ipairs(casts) do
                    if c.asset == "USD_PhaseDash" and c.done and T - c.done <= 2.0 and T >= c.done then
                        phasing = world.evading_until and world.evading_until > T
                    end
                end
                if phasing then world.result = "avoided"
                else
                    pawn.hp = pawn.hp - 40
                    multicast(pawn, drake, 40)
                    world.result = "hit"
                end
                hooks["/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData"]({ get = function() return comp end })
            end
        end
        run_until(function() return world.resolved end, 3)
        results[#results + 1] = world.result
        pawn.hp = 100
        next_t = next_t + 3.0
    end
    local late = 0
    for i = 9, 14 do if results[i] == "avoided" then late = late + 1 end end
    local f = Cm._state().fight
    check("rhythm: pre-casts Phase Dash ahead of the lunge and dashes through it (>= 4 of the last 6)", late >= 4, table.concat(results, ","))
    check("rhythm: casts went through the spells contract under the fight's token", #casts >= 3 and casts[1].owner ~= nil and casts[1].polls > 10, #casts)
    check("rhythm: pre-casts counted", f and (f.n_precasts or 0) >= 3, f and f.n_precasts)
    check("rhythm: the cast latency was learned", math.abs((Cm._state().ability_latency or {}).USD_PhaseDash or 0) - 2.05 < 0.05)
    Cm.stop(nil, "test")
    Cm.set_modules({ spells = false })
    A.reset(nil)
end

-- ================================================================ 19. modal gate: no gameplay press while build mode is open
reset_world()
do
    _G.DWInput = nil
    local inp = assert(loadfile(root .. "/client_mod/scripts/input.lua"))()
    inp.cfg.orphan_s = 999 -- keep the modal open for this test (its owner "build" is alive)
    inp.claim("build", "test build job")
    Cm.set_modules({ input = inp })
    pc.BuildModeComponent = obj({ CurrentBuildMode = 2 }, "BuildModeComponent /x") -- Placement
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_gate", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    Cm.guard_start(nil)
    multicast(pawn, gob, 5) -- it hits Claude: the reflex takes the pawn
    local injected0 = 0
    for _, n in pairs(world.injected) do injected0 = injected0 + n end
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    step(150)
    local injected = 0
    for _, n in pairs(world.injected) do injected = injected + n end
    check("gate: a reflex fight in build Placement mode presses nothing", injected == injected0 and Cm._state().fight ~= nil,
          injected - injected0)
    check("gate: the refusals are counted", (Cm._state().counts.gated or 0) > 0)
    if os.getenv("DBG") then local f = Cm._state().fight; print("GATE", f and f.phase, table.concat(Cm._state().log_lines, " || "):sub(-900)) end
    -- the build owner leaves build mode: presses go out again
    pc.BuildModeComponent.CurrentBuildMode = 0
    inp.release("build")
    step(150)
    local after = 0
    for _, n in pairs(world.injected) do after = after + n end
    check("gate: presses resume once build mode is closed", after > injected, after - injected)
    Cm.stop(nil, "test")
    Cm.guard_stop(nil)
    pc.BuildModeComponent = nil
    Cm.set_modules({ input = false })
    A.reset(nil)
end

-- ================================================================ 20. a non-gameplay input mode (live 23:39: an Oculus build menu left open)
reset_world()
do
    _G.DWInput = nil
    local inp = assert(loadfile(root .. "/client_mod/scripts/input.lua"))()
    Cm.set_modules({ input = inp })
    local back = obj({}, "InputAction /Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    local real_sfo = StaticFindObject
    StaticFindObject = function(path) if path:find("IA_UI_GenericBack", 1, true) then return back end return real_sfo(path) end
    pc.CurrentInputMode = obj({}, "DominionInputMode /Game/Inputs/DIM_OculusBuildMenu")
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_mode", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    check("mode: fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
    run_until(function() return Cm._state().fight == nil end, 10)
    local res = Cm._state().last.result
    check("mode: presses the mode's own back key (raw, past the gate)", (world.injected.IA_UI_GenericBack or 0) >= 2, world.injected.IA_UI_GenericBack)
    check("mode: no attack while the mode stays open", (world.injected.IA_PrimaryAction or 0) == 0)
    check("mode: a stuck mode fails loudly with its name", res and res.reason == "body_error" and res.data.why == "input_mode_blocked"
          and res.data.mode == "DIM_OculusBuildMenu", res and res.data and res.data.why)
    pc.CurrentInputMode = nil
    StaticFindObject = real_sfo
    Cm.set_modules({ input = false })
    A.reset(nil)
end

-- ================================================================ 20b. attacked mid-conversation (talk review finding 8): leave through talk, say why
reset_world()
do
    _G.DWInput = nil
    local inp = assert(loadfile(root .. "/client_mod/scripts/input.lua"))()
    local back = obj({}, "InputAction /Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    local real_sfo = StaticFindObject
    StaticFindObject = function(path) if path:find("IA_UI_GenericBack", 1, true) then return back end return real_sfo(path) end
    local TK = { stops = {}, leaves = 0 }
    local fake_talk = {
        stop = function(_, why) TK.stops[#TK.stops + 1] = why; return { ok = true } end,
        start = function(_, args)
            if args and args.leave then TK.leaves = TK.leaves + 1; if TK.refuse then return { ok = false, reason = "not_implemented", data = { why = "no_dialogue_ui" } } end
                pc.CurrentInputMode = nil; return { ok = true } end
            return { ok = false }
        end }
    Cm.set_modules({ input = inp, talk = fake_talk })
    local function converse()
        pc.CurrentInputMode = obj({}, "DominionInputMode /Game/Inputs/DIM_ConversationUI")
        pc.ConversationComponent = { CurrentNPC = obj({}, "BP_NPC_C /Game/L.L:PersistentLevel.BP_NPC_Ilya_C_1") }
    end
    converse()
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_conv", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    local n0 = #read_activity()
    check("conv: fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true, by = "reflex" }).ok)
    run_until(function() return Cm._state().fight == nil end, 20)
    local res = Cm._state().last.result
    check("conv: never the generic back key in a dialogue", (world.injected.IA_UI_GenericBack or 0) == 0, world.injected.IA_UI_GenericBack)
    check("conv: the talk job is stopped with the reason", TK.stops[1] == "attacked by Goblin Runt", TK.stops[1])
    check("conv: left through talk's own leave, once", TK.leaves == 1, TK.leaves)
    local ev
    local acts = read_activity()
    for i = n0 + 1, #acts do if acts[i]:find('"kind":"conversation_interrupted"', 1, true) then ev = acts[i] end end
    check("conv: a conversation_interrupted event says why and with whom", ev and ev:find('"why":"attacked"', 1, true) and ev:find('"npc":"BP_NPC_Ilya_C_1"', 1, true)
          and ev:find('"via":"talk"', 1, true) and ev:find('"attacker":"Goblin Runt"', 1, true), ev)
    check("conv: then the fight goes on and wins", res and res.ok and gob.hp <= 0, res and res.reason)
    -- talk cannot leave: the panel's own Cancel (as the conversation modal), then a truthful failure if it stays open
    reset_world()
    converse()
    TK.refuse, TK.leaves, TK.stops = true, 0, {}
    local cancel = obj({}, "InputAction /Game/UI/Conversation/IA_Conversation_Cancel.IA_Conversation_Cancel")
    local panel = obj({ CancelInputAction = cancel }, "ConversationMainPanel_C /Engine/Transient.ConversationMainPanel_C_1")
    local real_find = FindAllOf
    FindAllOf = function(cls) if cls == "ConversationMainPanel" then return { panel } end return real_find(cls) end
    local gob2 = new_creature("BP_AI_RuntGoblin_Character_C_conv2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    check("conv2: fight starts", Cm._start_fight(nil, gob2, { mode = "attack", force = true, by = "brain" }).ok)
    run_until(function() return Cm._state().fight == nil end, 12)
    local res2 = Cm._state().last.result
    check("conv2: the panel's Cancel is pressed (no generic back)", (world.injected.IA_Conversation_Cancel or 0) >= 1 and (world.injected.IA_UI_GenericBack or 0) == 0,
          tostring(world.injected.IA_Conversation_Cancel) .. " " .. tostring(world.injected.IA_UI_GenericBack))
    check("conv2: a stuck dialogue fails loudly", res2 and res2.reason == "body_error" and res2.data.why == "conversation_blocked" and res2.data.npc == "BP_NPC_Ilya_C_1", res2 and res2.data and res2.data.why)
    check("conv2: a commanded fight says fight_ordered", TK.stops[1] == "fight ordered: Goblin Runt", TK.stops[1])
    check("conv2: no attack while the dialogue stays open", (world.injected.IA_PrimaryAction or 0) == 0)
    FindAllOf = real_find
    pc.CurrentInputMode, pc.ConversationComponent = nil, nil
    StaticFindObject = real_sfo
    Cm.set_modules({ input = false, talk = false })
    A.reset(nil)
end

-- ================================================================ 21. staff/wand: magic attacks from the weapon's own primary (runes in the magic ammo slot)
reset_world()
do
    local Rg = assert(loadfile(root .. "/client_mod/scripts/ranged.lua"))()
    _G.DWRanged = nil
    Cm.set_modules({ ranged = Rg })
    world.ranged = true
    held.right, held.left = nil, "ITEM_Staff_Ash" -- two-handed: shows in the left hand
    inv_list.loadout = { { item = "ITEM_Rune_Fire", name = "Fire Rune", count = 40, loadout_slot = "MagicAmmo1", slot = 6 } }
    local projs = {}
    local real_find = FindAllOf
    FindAllOf = function(cls)
        if cls == "DominionSpellProjectile" then
            local out = {}
            for _, pr in ipairs(projs) do if not pr._dead_obj then out[#out + 1] = pr end end
            return out
        end
        return real_find(cls)
    end
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_mag", "Goblin Runt", { X = 1500, Y = 0, Z = 0 }, { hp = 90, pl = 1, arch = 0 })
    local real_inject = eis.InjectInputVectorForAction
    eis.InjectInputVectorForAction = function(self, action, vv, a, b)
        local name = action:GetFullName():match("%.([%w_]+)$")
        local rising = last_inject[name] ~= frame_n - 1
        real_inject(self, action, vv, a, b)
        if name == "IA_PrimaryAction" and rising then
            -- the cast: a homing magic projectile from the caster, a rune spent
            inv_list.loadout[1].count = inv_list.loadout[1].count - 1
            local pr = obj({ loc = { X = pawn.loc.X, Y = pawn.loc.Y, Z = pawn.loc.Z + 120 }, t0 = T }, "BP_SpellProjectile_C /Game/L.L:PersistentLevel.BP_SpellProjectile_C_" .. #projs)
            function pr:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
            projs[#projs + 1] = pr
        end
    end
    world.on_step = function()
        for _, pr in ipairs(projs) do
            if not pr._dead_obj then
                local dx, dy, dz = gob.loc.X - pr.loc.X, gob.loc.Y - pr.loc.Y, gob.loc.Z - pr.loc.Z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d < 50 then
                    gob.hp = math.max(0, gob.hp - 30); multicast(gob, pawn, 30); pr._dead_obj = true
                else
                    local sp = 30 -- 3000 cm/s homing
                    pr.loc.X, pr.loc.Y, pr.loc.Z = pr.loc.X + dx / d * sp, pr.loc.Y + dy / d * sp, pr.loc.Z + dz / d * sp
                end
            end
        end
    end
    local r = Cm.attack(nil, "Goblin Runt", { force = true })
    check("magic: fight starts", r.ok, r.reason)
    run_until(function() return Cm._state().fight == nil end, 60)
    local res = Cm._state().last.result
    check("magic: the staff's primary casts (no melee swap, no shield)", INV.equips[1] == nil, INV.equips[1])
    check("magic: no aim hold for a staff", (world.injected.IA_SecondaryAction or 0) == 0, world.injected.IA_SecondaryAction)
    check("magic: runes spent and the goblin died", gob.hp <= 0 and res.ok and inv_list.loadout[1].count < 40, tostring(gob.hp) .. " " .. tostring(res.reason))
    local mm = Rg.metrics()["ITEM_Staff_Ash|ITEM_Rune_Fire"] or {}
    check("magic: projectiles tracked and scored (shots, hits)", (mm.shots or 0) >= 2 and (mm.hits or 0) >= 1, tostring(mm.shots) .. "/" .. tostring(mm.hits))
    -- no runes in the magic slot -> a truthful refusal
    inv_list.loadout = {}
    gob.hp = 90
    local r2 = Cm.attack(nil, "Goblin Runt", { force = true })
    run_until(function() return Cm._state().fight == nil end, 10)
    local res2 = Cm._state().last.result
    check("magic: no runes -> not_enough_resources (no_runes)", res2.reason == "not_enough_resources" and res2.data.why == "no_runes", res2.reason)
    eis.InjectInputVectorForAction = real_inject
    FindAllOf = real_find
    world.ranged = nil
    inv_list.loadout = {}
    A.reset(nil)
end

-- ================================================================ 22. persistent combat memory (docs/design/combat-memory.md)
reset_world()
do
    Cm.cfg.memory_enabled = true
    local dir = Cm.cfg.memory_root .. "/data/skills/shockbyte"
    local path = dir .. "/combat_memory_BP_PlayerCharacter_C_1.json"
    for _, f in ipairs({ path, path .. ".bak", path .. ".tmp" }) do os.remove(f) end
    local function restart() _G.DWCombat, _G.DWDefense, _G.DWRanged = nil, nil, nil end
    local function read(pth) local f = io.open(pth, "rb"); if not f then return nil end local t = f:read("a"); f:close(); return t end
    local function exists(pth) local f = io.open(pth, "rb"); if f then f:close(); return true end return false end
    restart()
    local m0 = Cm.memory(nil, pawn)
    check("memory: none yet -> new", m0.status == "new", m0.status)
    -- what one session learned
    local key = "Goblin Runt:ATK_Goblin_Slash"
    local r = Dm.rec(key)
    r.n, r.impact_s, r.lunge_cm, r.damage, r.offset = 4, 0.9, 120, 15, 0.02
    r.arms = { parry = { s = 5, f = 0, n = 5 }, dodge = { s = 1, f = 2, n = 3 } }
    Dm.observe_cadence("Goblin Runt", 10); Dm.observe_cadence("Goblin Runt", 12.5); Dm.observe_cadence("Goblin Runt", 15)
    Cm._state().learned["goblin runt"] = { Fire = "weak" }
    -- a fight ends: the only write, and only after the fight is over
    local writes = {}
    local real_open = Cm.fs.open
    Cm.fs.open = function(pth, mode)
        if mode and mode:find("w", 1, true) then writes[#writes + 1] = { path = pth, in_fight = Cm._state().fight ~= nil } end
        return real_open(pth, mode)
    end
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local g = new_creature("BP_AI_RuntGoblin_Character_C_mem", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 20, pl = 1, arch = 0 })
    check("memory: fight starts", Cm._start_fight(nil, g, { mode = "attack", force = true, by = "brain" }).ok)
    run_until(function() return Cm._state().fight == nil end, 30)
    local in_fight = 0
    for _, w in ipairs(writes) do if w.in_fight then in_fight = in_fight + 1 end end
    check("memory: no file write while fighting", in_fight == 0, in_fight)
    check("memory: written once at the fight's end (tmp then renamed)", #writes == 1 and writes[1].path == path .. ".tmp" and exists(path)
          and not exists(path .. ".tmp") and not exists(path .. ".bak"), #writes)
    Cm.fs.open = real_open
    local txt = read(path) or ""
    check("memory: tagged with the build and world", txt:find('"build":"TESTBUILD"', 1, true) ~= nil and txt:find('"world":"shockbyte"', 1, true) ~= nil, txt:sub(1, 160))
    check("memory: the fight is in the creature's history", Cm.creature_history("Goblin Runt").fights == 1)
    -- a client restart: everything in _G is gone; the file brings it back
    restart()
    check("memory: restart forgets", Dm.status().attacks[key] == nil)
    local m1 = Cm.memory(nil, pawn)
    check("memory: loaded after a restart", m1.status == "loaded" and m1.imported.attacks >= 1, m1.status)
    local t, src = Dm.impact_delay(key, {})
    check("memory: per-attack timing survives", t == 0.9 and src == "learned", tostring(t) .. " " .. tostring(src))
    check("memory: the bandit survives (parry still the answer)", Dm.status().attacks[key].arms.parry.s == 5)
    check("memory: the learned weakness survives", (Cm._state().learned["goblin runt"] or {}).Fire == "weak")
    local cad = (_G.DWDefense.cadence or {})["Goblin Runt"] or {}
    check("memory: the rhythm survives without the old clock", cad.interval ~= nil and cad.last_t == nil)
    check("memory: a remembered rhythm restarts cleanly", pcall(Dm.observe_cadence, "Goblin Runt", 3) and Dm.next_attack_eta("Goblin Runt", 3.5) ~= nil)
    -- a second fight: history grows; the brief shows it (information, never a veto)
    local g2 = new_creature("BP_AI_RuntGoblin_Character_C_mem2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 20, pl = 1, arch = 0 })
    Cm._start_fight(nil, g2, { mode = "attack", force = true, by = "brain" })
    run_until(function() return Cm._state().fight == nil end, 30)
    local h = Cm.creature_history("Goblin Runt")
    check("memory: history per creature (2 fights, damage series)", h.fights == 2 and #h.damage_taken == 2 and h.first_encounter == false, h.fights)
    check("memory: an unseen creature is a first encounter", Cm.creature_history("Goblin Brute").first_encounter == true)
    new_creature("BP_AI_RuntGoblin_Character_C_mem3", "Goblin Runt", { X = 300, Y = 0, Z = 0 }, { hp = 20, pl = 1, arch = 0 })
    local okb, brief = pcall(Cm.combat_brief, nil, "BP_AI_RuntGoblin_Character_C_mem3")
    check("memory: combat_brief carries history + memory status", okb and brief.ok and brief.data.history.fights == 2 and brief.data.memory.status == "loaded",
          okb and brief.data and brief.data.history and brief.data.history.fights or tostring(brief))
    -- family priors: data tokens, always labelled, never "learned"
    local fp = Dm.family_prior("Goblin Brute:ATK_Goblin_Slash")
    check("family: the same attack asset on another creature", fp and fp.from == key and fp.why == "same_attack" and fp.label == "prior:family", fp and fp.why)
    local fp2 = Dm.family_prior("Goblin Brute:ATK_GoblinBrute_Smash")
    check("family: a shared creature + attack token", fp2 and fp2.from == key and fp2.why == "family", fp2 and fp2.why)
    check("family: unrelated creatures get nothing", Dm.family_prior("Kebbit:ATK_Kebbit_Attack_01") == nil)
    local t2, src2 = Dm.impact_delay("Goblin Brute:ATK_GoblinBrute_Smash", {})
    check("family: timing prior labelled", t2 == 0.9 and src2 == "prior:family", tostring(src2))
    local th = Dm.threat({ key = "Goblin Brute:ATK_GoblinBrute_Smash" }, 100)
    check("family: threat carries the prior's label and lunge", th.prior and th.prior.label == "prior:family" and th.lunge_cm == 120)
    local fa = Cm.family_affinity("Goblin Brute")
    check("family: weakness prior from a token-sharing creature, labelled", fa and fa.from == "goblin runt" and fa.verdicts.Fire == "weak" and fa.label == "prior:family")
    -- a file from another build is refused loudly and kept
    local stale = (read(path) or ""):gsub('"build":"TESTBUILD"', '"build":"OLD1"')
    local f = io.open(path, "wb"); f:write(stale); f:close()
    restart()
    local lines = {}
    local m2 = Cm.memory(function(l) lines[#lines + 1] = l end, pawn)
    local kept = path:gsub("%.json$", "") .. ".build-OLD1.json"
    check("stale: refused, not imported", m2.status == "refused_stale" and Dm.status().attacks[key] == nil and (m2.detail or ""):find("OLD1", 1, true) ~= nil, m2.status)
    check("stale: said loudly + the old file kept", (lines[1] or ""):find("MEMORY REFUSED", 1, true) ~= nil and exists(kept) and not exists(path), lines[1])
    os.remove(kept)
    -- a corrupt file
    f = io.open(path, "wb"); f:write("{nope"); f:close()
    restart()
    local m3 = Cm.memory(nil, pawn)
    check("corrupt: tolerated and kept aside", m3.status == "corrupt" and not exists(path), m3.status)
    os.remove((m3.detail or ""):match("kept as (.+)$") or "")
    -- a crash between the two renames leaves only .bak: the load uses it
    restart()
    Cm.memory(nil, pawn)
    Dm.rec(key).n, Dm.rec(key).impact_s = 2, 0.8
    Cm.memory_save(nil)
    os.rename(path, path .. ".bak")
    restart()
    local m4 = Cm.memory(nil, pawn)
    check("bak: recovered from the .bak", m4.status == "loaded" and Dm.status().attacks[key] ~= nil and Dm.status().attacks[key].impact_s == 0.8, m4.status)
    -- boss attempts (velgar.md gap 7): damage by threat, phase reached, cause of death; persisted with the memory
    local F = { t = 100, t0 = 10, target_name = "Velgar", boss = true, boss_max_phase = 2, boss_phases = 4, hp_start = 6000, target_hp = 2400,
                n_heals = 6, n_cures = 2, kills = 0 }
    F.def = { tel_t = 99, key = "Velgar:ATK_DragonVelgar_ClawAttack_Left_C", info = {} }
    Cm.note_damage(F, 30)
    F.def = { tel_t = 99.5, key = "Velgar:DAA_DragonVelgar_PoisonBreath_Front_C", info = { ability = "breath_cone" } }
    Cm.note_damage(F, 25)
    F.def = nil
    Cm._state().statuses = { t = os.time(), effects = { Poison = { value = 40, max = 100, harmful = true } } }
    Cm.note_damage(F, 12)
    F.dmg_taken = 67
    check("attempt: damage by threat", F.dmg_by["melee:ATK_DragonVelgar_ClawAttack_Left_C"] == 30 and F.dmg_by["ability:breath_cone"] == 25 and F.dmg_by.poison == 12)
    restart()
    local mm = Cm.memory(nil, pawn)
    Cm.record_boss_attempt(mm, F, { ok = false, reason = "companion_down", data = { died = true } })
    Cm.memory_save(nil)
    restart()
    Cm.memory(nil, pawn)
    local ba = Cm.boss_attempts("Velgar")
    check("attempt: persisted across a restart, phase reached + cause of death", ba and ba.attempts == 1 and ba.phase_reached[1] == 2
          and ba.causes_of_death[1] == "poison" and ba.last.boss_hp_left_pct == 40 and ba.last.damage_by.poison == 12, ba and ba.attempts)
    check("attempt: not recorded for an ordinary creature", (function() local G = { target_name = "Kebbit" }; Cm.record_boss_attempt(Cm._state().mem, G, { ok = true }); return Cm.boss_attempts("Kebbit") == nil end)())
    for _, x in ipairs({ path, path .. ".bak" }) do os.remove(x) end
    Cm.cfg.memory_enabled = false
    restart()
    A.reset(nil)
end

print(string.format("combat/arbiter tests: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
