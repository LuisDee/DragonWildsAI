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
local OBJS = {} -- every fake object by path, so StaticFindObject re-finds it (combat keeps paths across ticks, never refs)
local function obj(t, full)
    t.IsValid = function() return not t._dead_obj end
    t.GetFullName = function() return full end
    local path = type(full) == "string" and full:match("^%S+%s+(.*)$")
    if path then OBJS[path] = t end
    return t
end
local function fname(s) return { ToString = function() return s end } end
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn, ms = ms, next = T }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
local hooks = {}
function RegisterHook(path, pre, post) hooks[path] = post; return 1, 2 end
local CDOS = {}
function StaticFindObject(path) return CDOS[path] or OBJS[path] end
local PERKS = { unlocked = {} }

local world = { creatures = {}, items = {}, pcs = {}, injected = {} }
local pawn, pc
local stamina, special = 80, 100
local function new_pawn()
    pawn = obj({ loc = { X = 0, Y = 0, Z = 0 }, yaw = 0, hp = 100 }, "BP_PlayerCharacter_C /Game/L.L:PersistentLevel.BP_PlayerCharacter_C_1")
    function pawn:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    function pawn:K2_GetActorRotation() return { Pitch = 0, Yaw = self.yaw, Roll = 0 } end
    function pawn:AddMovementInput(d, s)
        self.nudged = (self.nudged or 0) + 1; self.yaw = math.deg(math.atan(d.Y, d.X))
        if world.walk_input and (s or 0) >= 0.99 then self.loc.X, self.loc.Y = self.loc.X + d.X * 5, self.loc.Y + d.Y * 5 end -- (opt-in: 5 m/s)
    end
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
    if rising and name == "IA_Player_Evade" then
        if (world.evade_drop or 0) > 0 then world.evade_drop = world.evade_drop - 1 -- (opt-in: the game ate this key press)
        else world.evading_until = T + 0.5; world.evade_start = T end
    end
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
-- move's approach-progress tracker, faked with move.lua's own semantics (status().progress; opts.progress)
local function prog_new(o)
    o = o or {}
    return { stall = o.stall_s or 12, gain = (o.gain_m or 0.5) * 100, budget = o.budget_s, moving = (o.moving_m or 3) * 100, elapsed = 0 }
end
function fake_move.go_to(log, goal, opts) MV.calls[#MV.calls + 1] = "go_to"; MV.mode, MV.goal, MV.opts, MV.dist = "go_to", goal, opts, nil
    MV.prog = prog_new(opts and opts.progress); return { ok = true, mode = "go_to" } end
function fake_move.follow(log, goal, dist, opts)
    MV.calls[#MV.calls + 1] = "follow:" .. tostring(goal); MV.mode, MV.goal, MV.dist, MV.opts = "follow", goal, dist, opts
    MV.prog = prog_new(opts and opts.progress)
    return { ok = true, mode = "follow", target_visible = goal ~= "Nobody" }
end
function fake_move.progress_reset() if MV.prog then MV.prog.best, MV.prog.best_t, MV.prog.best_tpos, MV.prog.elapsed = nil, nil, nil, 0 end return { ok = true } end
do -- the real words table (move.lua loads offline: no engine calls at load)
    local okm, realmove = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/move.lua"))() end)
    fake_move.why_words = okm and realmove.why_words or function(why) return tostring(why) end
end
local function prog_view()
    local P = MV.prog
    if not P or MV.mode == "idle" then return nil end
    local since = (P.last_t and P.best_t) and (P.last_t - P.best_t) or 0
    local moved = (P.best_tpos and P.tpos) and math.sqrt((P.best_tpos.X - P.tpos.X) ^ 2 + (P.best_tpos.Y - P.tpos.Y) ^ 2) or 0
    local verdict, why = "ok", nil
    local un = MV.extra and MV.extra.unreachable
    if un then verdict, why = "unreachable", un.reason
    else
        local over = P.budget and P.elapsed > P.budget
        if over or since > P.stall then
            verdict = "stalled"
            if moved > P.moving then why = "cant_catch" elseif over then why = "too_long"
            else why = MV.bumped and "blocked" or "no_progress" end
        end
    end
    return { verdict = verdict, why = why, dist_m = P.dist and P.dist / 100, best_dist_m = P.best and P.best / 100, since_s = since,
             elapsed_s = P.elapsed, target_moved_m = moved / 100 }
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
    local r = { mode = MV.mode, target = type(MV.goal) == "string" and MV.goal or nil, progress = prog_view() }
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
function fake_inv.unequip(log, slot)
    INV.unequips = INV.unequips or {}
    INV.unequips[#INV.unequips + 1] = slot
    if slot == "HeldRight" then held.right = nil else held.left = nil end
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
-- per-run temp paths: other agents run this file at the same time (a shared activity file / memory root made
-- sections read each other's events)
local RUN_ID = tostring(os.time()) .. "_" .. tostring(math.floor(os.clock() * 1e6)) .. "_" .. tostring(math.random(1, 1e9))
local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."
Cm.ACTIVITY_PATH = (tmpdir .. "/test_combat_activity_" .. RUN_ID .. ".jsonl"):gsub("\\", "/")
os.remove(Cm.ACTIVITY_PATH)
-- the persistent memory goes to a temp root (never the repo's data/skills)
Cm.cfg.memory_root = (tmpdir .. "/test_combat_mem_" .. RUN_ID):gsub("\\", "/")
os.execute('mkdir "' .. (tmpdir .. "/test_combat_mem_" .. RUN_ID .. "/data/skills/shockbyte"):gsub("/", "\\") .. '" 2>nul')
os.remove(Cm.cfg.memory_root .. "/data/skills/shockbyte/combat_memory_BP_PlayerCharacter_C_1.json")
Cm._reset_build("TESTBUILD")
_G.DW_WORLD_GUID = "shockbyte" -- the memory tests' world (the real resolver is tested in §22b with a fake fs)
Cm._reset_world_cache()
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
                    if world.wall_x and pawn.loc.X > world.wall_x then pawn.loc.X = world.wall_x; MV.bumped = true end -- a wall across +X
                    pawn.yaw = math.deg(math.atan(dy, dx))
                elseif MV.mode == "go_to" then MV.mode = "idle" end
            end
        end
        if MV.prog and MV.mode ~= "idle" then
            local g = resolve(MV.goal)
            if g then
                local P = MV.prog
                local d = math.sqrt((g.X - pawn.loc.X) ^ 2 + (g.Y - pawn.loc.Y) ^ 2)
                local near = d <= ((MV.dist or (MV.opts and MV.opts.tolerance_m) or 1) * 100) + 5
                P.dist, P.tpos = d, { X = g.X, Y = g.Y }
                if near then P.best, P.best_t, P.best_tpos = d, T, { X = g.X, Y = g.Y }
                else
                    P.elapsed = P.elapsed + 0.01
                    if not P.best or d < P.best - P.gain then P.best, P.best_t, P.best_tpos = d, T, { X = g.X, Y = g.Y } end
                end
                P.best_t = P.best_t or T
                P.last_t = T
            end
        end
        stamina = math.min(80, stamina + 0.15)
        local keep = {}
        for _, h in ipairs(pending_hits) do
            if T >= h.t then
                local tgt = Cm._state().fight and Cm._state().fight.target
                if tgt and tgt.hp > 0 and not tgt.unhittable then
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
    MV.mode, MV.calls, MV.goal, MV.prog, MV.bumped = "idle", {}, nil, nil, nil
    INV.equips, INV.uses, INV.interacts = {}, {}, 0
    held.right, held.left = nil, "ITEM_Logging_Axe_Mithril"
    pawn.loc, pawn.hp, stamina, special = { X = 0, Y = 0, Z = 0 }, 100, 80, 100
    pawn.yaw = 0 -- (facing +X, where the tests put what he fights)
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
    do -- his learned damage beats the catalog, and a proven weapon beats an untried one (live 2026-11-02 01:16Z:
       -- a Stone Dagger, catalog x1.5 stab-weak, replaced the Bronze Sword he had killed 5 Giant Rats with; he died)
        local st = Cm._state()
        local saved = st.hit_dmg
        st.hit_dmg = {}
        local rat = { name = "Giant Rat", affinities = { ["DamageType.Physical.Stab"] = "weak" } }
        local kit = { loadout = {}, hotbar = { { item = "ITEM_Sword_Bronze", slot = 1 } }, bag = { { item = "ITEM_Dagger_Stone", slot = 3 } } }
        check("catalog only: the stab-weak rat makes the dagger win", Cm.best_weapon(kit, rat, nil, nil, nil, {}).weapon.entry.item == "ITEM_Dagger_Stone")
        st.hit_dmg["Bronze Sword"] = 48.3
        check("learned 48/hit: the sword outscores the untried dagger",
              Cm.score_weapon(W.items.ITEM_Sword_Bronze, rat) > Cm.score_weapon(W.items.ITEM_Dagger_Stone, rat))
        st.hit_dmg = {}
        local rec = { ITEM_Sword_Bronze = { n = 5, kills = 5, deaths = 0 } }
        local b = Cm.best_weapon(kit, rat, nil, nil, nil, rec).weapon
        check("proven sword (5 kills, 0 deaths) beats the untried dagger", b.entry.item == "ITEM_Sword_Bronze"
              and tostring(b.why):find("proven", 1, true) ~= nil, b.entry.item)
        rec = { ITEM_Sword_Bronze = { n = 1, kills = 1, deaths = 0 } }
        check("one fight is not proven", Cm.best_weapon(kit, rat, nil, nil, nil, rec).weapon.entry.item == "ITEM_Dagger_Stone")
        rec = { ITEM_Sword_Bronze = { n = 3, kills = 1, deaths = 2 } }
        check("a weapon he died with more than he won is not proven", Cm.best_weapon(kit, rat, nil, nil, nil, rec).weapon.entry.item == "ITEM_Dagger_Stone")
        local m = { history = { ["giant rat"] = { { weapon = "ITEM_Sword_Bronze", outcome = "killed" }, { weapon = "ITEM_Sword_Bronze", outcome = "killed" },
                                                 { weapon = "ITEM_Dagger_Stone", outcome = "died" } } } }
        local r2 = Cm.weapon_record(rat, m)
        check("weapon_record counts per weapon", r2.ITEM_Sword_Bronze.n == 2 and r2.ITEM_Sword_Bronze.kills == 2 and r2.ITEM_Dagger_Stone.deaths == 1)
        st.hit_dmg = saved
    end
    check("live affinity used", Cm.affinity({ name = "X", affinities = { ["DamageType.Physical.Crush"] = "immune" } }, "DamageType.Physical.Crush") == "immune")

    local me = { hp = 100, max_hp = 100, pl = 2, dps = Cm.dps(dag) }
    local keb = { name = "Kebbit", hp = 60, max_hp = 60, pl = 1 }
    local a = Cm.assess(me, { keb }, Cm.orders)
    check("assess kebbit = fight", a.decision == "fight", a.why .. " " .. a.u_fight)
    check("assess strong = flee", Cm.assess(me, { { name = "Troll", hp = 900, pl = 5 } }, Cm.orders).why == "too_strong")
    check("assess boss = flee", Cm.assess(me, { { name = "Dragon", hp = 9000, pl = 2, boss = true } }, Cm.orders).why == "boss")
    -- a PL gap of 2 his numbers win is a fight (live 21:50Z: PL-2 Giant Rat vs his PL 0, 17 s to kill vs 40 s to die,
    -- he ran on the gap alone and was run down); losing numbers, or a gap of 4+, still flee
    local me0 = { hp = 100, max_hp = 100, pl = 0, dps = 7.6 }
    local rat = { name = "Giant Rat", hp = 130, max_hp = 130, pl = 2, dps_obs = 1.6 }
    local ar = Cm.assess(me0, { rat }, Cm.orders)
    check("assess: PL gap 2 but winnable -> fight", ar.decision == "fight" and ar.verdict ~= "too_strong", tostring(ar.why) .. " " .. tostring(ar.verdict) .. " " .. tostring(ar.u_fight))
    local ar2 = Cm.assess(me0, { { name = "Giant Rat", hp = 900, max_hp = 900, pl = 2, dps_obs = 8 } }, Cm.orders)
    check("assess: PL gap 2 and losing numbers -> too_strong", ar2.why == "too_strong", tostring(ar2.why))
    local ar3 = Cm.assess(me0, { { name = "Giant Rat", hp = 20, max_hp = 20, pl = 4, dps_obs = 0.5 } }, Cm.orders)
    check("assess: PL gap 4 -> too_strong whatever the numbers", ar3.why == "too_strong", tostring(ar3.why))
    check("assess outnumbered", Cm.assess(me, { keb, keb, keb }, Cm.orders).why == "outnumbered")
    check("assess low hp", Cm.assess({ hp = 30, max_hp = 100, pl = 2, dps = 15 }, { { name = "Kebbit", hp = 200, max_hp = 200, pl = 1 } }, Cm.orders).why == "low_hp")
    -- low HP but almost won (kills it in 3.2 s, it needs 9.4 s): running only gives it free hits (live 11:28)
    local fin = Cm.assess({ hp = 30, max_hp = 100, pl = 2, dps = 15 }, { keb }, Cm.orders)
    check("assess low hp, finishing: fights on", fin.decision == "fight" and fin.why == "finishing" and fin.finishing, fin.why)
    check("assess low hp, finishing, commanded: fights on", Cm.assess({ hp = 30, max_hp = 100, pl = 2, dps = 15 }, { keb }, { commanded = true }).decision == "fight")
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

-- Flee continuation: movement completion is not safety while observed threats remain.
reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_1", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    check("flee continuation: active protect follow is retained", f and MV.mode == "follow")
    local calls = #MV.calls
    step(30)
    check("flee continuation: active follow does not churn", #MV.calls == calls)
    MV.mode = "idle"
    run_until(function() return MV.mode == "go_to" end, 3)
    check("flee continuation: arrived while chased starts escape", MV.mode == "go_to" and MV.opts.owner_token == f.token and Cm._state().fight == f)
    local oldgoal = MV.goal
    local other = new_creature("BP_AI_TestThreat_C_2", "Other", { X = 0, Y = 600, Z = 0 }, { hp = 100, pl = 1, arch = 0, alert = 0 })
    Cm._state().telegraphs["BP_AI_TestThreat_C_2"] = T
    MV.mode = "idle"; step(120)
    check("flee continuation: recent telegraph contributes to direction", MV.goal and MV.goal[2] < -1 and oldgoal and oldgoal[2] == 0)
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_3", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local other = new_creature("BP_AI_TestThreat_C_4", "Other", { X = -400, Y = 0, Z = 0 }, { hp = 100, pl = 1, arch = 0, alert = 0 })
    Cm._state().telegraphs["BP_AI_TestThreat_C_4"] = T
    MV.mode = "idle"
    run_until(function() return Cm._state().fight == nil end, 6)
    local result = Cm._state().last and Cm._state().last.result
    check("flee continuation: opposing threats fail specifically", result and not result.ok and result.data.detail == "threat direction unresolved", result and result.data.detail)
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_5", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local original_go = fake_move.go_to
    fake_move.go_to = function() return { ok = false } end
    MV.mode = "idle"
    run_until(function() return Cm._state().fight == nil end, 6)
    local result = Cm._state().last and Cm._state().last.result
    check("flee continuation: rejected moves fail without false safety", result and not result.ok and result.data.detail == "escape movement rejected")
    fake_move.go_to = original_go
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_6", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local real_status = fake_move.status
    fake_move.status = function() A.reset(nil); return { mode = "idle" } end
    local before = #MV.calls
    f.flee_retry_t = -100
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    local moved = false; for i = before + 1, #MV.calls do if MV.calls[i] == "go_to" then moved = true end end
    check("flee continuation: owner loss during status does not issue escape", not moved)
    fake_move.status = real_status
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_7", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local emitted, emit = {}, Cm.emit_activity
    Cm.emit_activity = function(ev) emitted[#emitted + 1] = ev end
    MV.mode = "idle"; MV.extra = { result = { status = "failed", reason = "no_route" } }
    world.on_step = function() if MV.mode == "go_to" then MV.mode = "idle" end end
    run_until(function() return Cm._state().fight == nil end, 8)
    local result = Cm._state().last.result
    local last = emitted[#emitted]
    check("flee: completed move failures retain reason and emit failed outcome", not result.ok and result.data.detail == "escape movement failed: no_route" and last and last.outcome == "failed" and last.detail == result.data.detail, tostring(result.data.detail) .. " / " .. tostring(last and last.outcome) .. " / " .. tostring(last and last.detail))
    MV.extra, world.on_step = nil, nil; Cm.emit_activity = emit; Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_8", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    Cm._state().attackers["unseen_attacker"] = T
    enemy.loc = { X = 6000, Y = 0, Z = 0 }; Cm._state().attackers[f.target_id] = nil
    enemy.CurrentAlertnessState = 0; step(500)
    check("flee: recent unseen attacker prevents false safety", Cm._state().fight == f and f.flee_error == "recent threat not visible")
    Cm._state().attackers["unseen_attacker"] = T - Cm.cfg.attacker_memory_s - 1
    check("flee: expired observation and stale target can clear", run_until(function() return Cm._state().fight == nil end, 8))
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_9", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local original_find = FindAllOf
    FindAllOf = function(cls) if cls == "DominionAICharacter" then error("census failed") end return original_find(cls) end
    f.phase_t = T - Cm.cfg.flee_timeout_s - 1; f.t = T
    local emitted, emit = {}, Cm.emit_activity
    Cm.emit_activity = function(ev) emitted[#emitted + 1] = ev end
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    local result, ev = Cm._state().last.result, emitted[#emitted]
    check("flee: census failure times out truthfully", not result.ok and result.data.detail == "threat census unavailable" and result.data.still_chased == nil and ev.detail == result.data.detail and ev.still_chased == nil)
    Cm.emit_activity = emit; FindAllOf = original_find; Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_10", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    local getloc = enemy.K2_GetActorLocation
    enemy.K2_GetActorLocation = function() error("unreadable position") end
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    check("flee: missing threat position is unresolved", f.flee_error == "observed threat position unavailable")
    enemy.K2_GetActorLocation = getloc
    Cm._state().attackers[f.target_id] = nil; enemy.CurrentAlertnessState = nil
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    check("flee: unreadable target combat state is unresolved", f.flee_error == "threat state unavailable")
    enemy.CurrentAlertnessState = 4; Cm._state().attackers[f.target_id] = T
    local oldgo = fake_move.go_to
    fake_move.go_to = function() A.reset(nil); return { ok = true } end
    MV.mode = "idle"; f.flee_retry_t = -100
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    check("flee: reentrant owner loss cannot claim movement", not f.flee_move_pending)
    fake_move.go_to = oldgo; Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_11", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    enemy.loc = { X = 6000, Y = 0, Z = 0 }; enemy.CurrentAlertnessState = 0
    Cm._state().attackers = {}; Cm._state().telegraphs = {}
    f.phase_t, f.t, f.safe_since, f.flee_error = T - Cm.cfg.flee_timeout_s - 1, T, T, "earlier census failure"
    local emitted, emit = {}, Cm.emit_activity
    Cm.emit_activity = function(ev) emitted[#emitted + 1] = ev end
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = pawn.hp, max_hp = 100 })
    local result, ev = Cm._state().last.result, emitted[#emitted]
    check("flee: deadline before safe dwell reports unconfirmed safety", not result.ok and result.data.still_chased == false and result.data.detail == "safety was not yet confirmed" and ev.still_chased == false and ev.detail == result.data.detail)
    Cm.emit_activity = emit; Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do -- a flee it keeps hitting him through turns into a fight (21:50Z: bitten 100 -> 40 HP over a 15 s flee, then killed)
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_12", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 70
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    check("caught: setup fled", f and f.phase == "flee" and f.flee_hp0 ~= nil, f and f.phase)
    f.flee_hp0 = 70; f.t = T
    Cm._state().attackers[f.target_id] = T
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = 45, max_hp = 100 })
    check("caught: 25 HP lost while running -> turns to fight", f.phase == "approach" and tostring(f.cornered):find("kept hitting me", 1, true) ~= nil,
          tostring(f.phase) .. " " .. tostring(f.cornered))
    Cm.guard_stop(nil); A.reset(nil)
end

reset_world()
do -- caught while stuck is not "faster than me"; caught while really running is (measured 06:4xZ: rat 600 vs sprint 680)
    for _, case in ipairs({ { fled = 0.5, want = nil, name = "stuck" }, { fled = 40, want = true, name = "ran" } }) do
        Cm.guard_start(nil)
        local enemy = new_creature("BP_AI_TestThreat_C_14", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
        multicast(pawn, enemy, 30); pawn.hp = 70
        run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
        local f = Cm._state().fight
        Cm._state().caught_by = {}
        f.flee_hp0 = 70; f.t = T; f.phase_t = T - 8
        f.flee_from = { X = pawn.loc.X - case.fled * 100, Y = pawn.loc.Y, Z = pawn.loc.Z }
        Cm._state().attackers[f.target_id] = T
        Cm._step_flee(f, pawn, { pos = pawn.loc, hp = 45, max_hp = 100 })
        check("caught (" .. case.name .. "): turns to fight", f.phase == "approach", f.phase)
        check("caught (" .. case.name .. "): remembered as faster only when he really ran",
            (Cm._state().caught_by or {})["Threat"] == case.want, tostring((Cm._state().caught_by or {})["Threat"]))
        Cm.guard_stop(nil); A.reset(nil)
        reset_world()
    end
end

reset_world()
do -- at the flee's time limit with it still after him (beyond cornered_m) he fights, not hand his legs back
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestThreat_C_13", "Threat", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    f.flee_hp0 = 40
    enemy.loc = { X = pawn.loc.X + 1200, Y = pawn.loc.Y, Z = pawn.loc.Z }
    Cm._state().attackers[f.target_id] = T
    f.phase_t, f.t = T - Cm.cfg.flee_timeout_s - 1, T
    Cm._step_flee(f, pawn, { pos = pawn.loc, hp = 40, max_hp = 100 })
    check("still chased at the bound (12 m) -> fight, not unsafe", f.phase == "approach" and tostring(f.cornered):find("kept up", 1, true) ~= nil,
          tostring(f.phase) .. " " .. tostring(f.cornered) .. " " .. tostring(Cm._state().last and Cm._state().last.result and Cm._state().last.result.reason))
    Cm.guard_stop(nil); A.reset(nil)
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
    local impact = T + dmg_time + (opts.late_s or 0) -- (late_s: it lands this much later (or, negative, sooner) than its data says)
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
            -- the roll can't be hit 0.15-0.75 s after it starts (its montage's Invulnerability notify, live
            -- 2026-11-16); the server sees the key 2 x one-way latency later
            elseif world.evade_start and T >= world.evade_start + 0.06 + 0.15 - 1e-6 and T <= world.evade_start + 0.06 + 0.75 then
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
    check("wall: says what and why", res and res.data.why == "blocked" and res.data.target == "Kebbit" and res.data.detail:find("Kebbit", 1, true)
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
    check("unreach: the detail is a sentence he can say (move's words)", r2 and r2.data.detail == "I can't get to the Kebbit: there's no way through to the Kebbit from here.", r2 and r2.data.detail)
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
    check("ledge (22:01 replay): path_blocked, higher than he can jump", r3 and r3.reason == "path_blocked" and r3.data.detail == "I can't get to the Kebbit: the Kebbit is higher up than I can jump.", r3 and r3.data and r3.data.detail)
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
    check("chase: says what happened", r4 and r4.data.detail:find("the Kebbit keeps moving away", 1, true) ~= nil, r4 and r4.data and r4.data.detail)
    -- the budget is for a chase, not for the walk to a thing far off (live 20261116-184943: a rat 57.8 m away up a hill)
    check("chase: move is told to give the budget more for each metre he starts away", MV.opts and type(MV.opts.progress) == "table"
        and MV.opts.progress.budget_s == 30 and (tonumber(MV.opts.progress.budget_per_m) or 0) > 0, MV.opts and MV.opts.progress and MV.opts.progress.budget_per_m)
    world.on_step = nil
    A.reset(nil)
end

-- ================================================================ 10d. AI actions (dragon abilities) + boss phases (velgar.md gaps 1 and 3)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local v = new_creature("BP_AI_DragonVelgar_Character_C_1", "Velgar", { X = 400, Y = 0, Z = 0 }, { hp = 6000, pl = 4, arch = 0, boss = true })
    local cur = { cls = nil }
    local acomp = obj({ GetOwner = function() return v end }, "BP_DragonVelgar_ActionsComponent_C /Game/L.L:PersistentLevel.Velgar_1.Actions")
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
    MV.extra = { unreachable = { reason = "target_above_jump_height" } } -- he perched 20 m up: move says so
    run_until(function() return Cm._state().fight == nil end, 40)
    MV.extra = nil
    local r = Cm._state().last.result
    check("boss: landed but out of reach -> the normal truthful ending again", r and (r.reason == "too_far" or r.reason == "path_blocked"), r and r.reason)
    FindFirstOf = real_ffo
    A.reset(nil)
end

-- ================================================================ 10d2. regression crash_2026_10_26_15_56_19: AI actions of creatures that
-- despawned (and were GC'd) before the next fight. Live: explore past Kebbits/chickens, then a Giant Rat fight ran
-- ability_frame, which read r.comp.CurrentAction on a freed component -> native AV in UE4SS __index. A freed fake
-- here records ANY access (even IsValid) as the crash; combat must never touch it again after the hook returned.
reset_world()
do
    Cm.hooks_start(nil) -- as at boot: the multicast hooks are live before any fight
    local AV = {}
    local function freeable(t, full)
        obj(t, full)
        local path = full:match("^%S+%s+(.*)$")
        return t, function() -- free: unfindable, and every access is the native crash
            OBJS[path] = nil
            for k in pairs(t) do t[k] = nil end
            setmetatable(t, { __index = function(_, k) AV[#AV + 1] = tostring(k) end })
        end
    end
    local kb = new_creature("BP_AI_Kebbit_Character_C_gone", "Kebbit", { X = 3000, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 1 })
    local kcomp, free_comp = freeable({ GetOwner = function() return kb end,
        CurrentAction = obj({ GetClass = function() return obj({}, "BlueprintGeneratedClass /Game/AI/X.DAA_Kebbit_IdleBreak_01_C") end }, "A /x") },
        "BP_Kebbit_ActionsComponent_C /Game/L.L:PersistentLevel.BP_AI_Kebbit_Character_C_gone.Actions")
    -- (a) an old action (outside any fight: nothing resolves it), then its creature despawns and is GC'd
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return kcomp end }, { get = function() return 369 end })
    check("stale: the hook keeps paths, never UObject refs", (function()
        for _, r in pairs(Cm._state().ai_actions or {}) do for _, v in pairs(r) do if type(v) == "table" then return false end end end
        return true end)())
    free_comp(); kb._dead_obj = true; OBJS["/Game/L.L:PersistentLevel.BP_AI_Kebbit_Character_C_gone"] = nil
    T = T + 10
    -- (b) a fresh action whose creature is gone within the same second (despawn right after the multicast)
    local kb2 = new_creature("BP_AI_Kebbit_Character_C_gone2", "Kebbit", { X = 3200, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 1 })
    local kcomp2, free_comp2 = freeable({ GetOwner = function() return kb2 end },
        "BP_Kebbit_ActionsComponent_C /Game/L.L:PersistentLevel.BP_AI_Kebbit_Character_C_gone2.Actions")
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return kcomp2 end }, { get = function() return 370 end })
    free_comp2(); kb2._dead_obj = true
    -- the next fight (the Giant Rat at 14:56:18) runs ability_frame over both records
    local rat = new_creature("BP_AI_GiantRat_Character_C_1", "Giant Rat", { X = 200, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    Cm._start_fight(nil, rat, { mode = "attack", force = true, by = "brain" })
    run_until(function() return false end, 1)
    check("stale: no access to a freed component or creature after the hook", #AV == 0, table.concat(AV, ","))
    local recs = Cm._state().ai_actions or {}
    local r1, r2 = recs["BP_AI_Kebbit_Character_C_gone"], recs["BP_AI_Kebbit_Character_C_gone2"]
    check("stale: an old action is not resolved", r1 == nil or (r1.cls == "?" and r1.profile == nil), r1 and r1.cls)
    check("stale: a gone creature's action resolves to '?'", r2 and r2.cls == "?" and r2.profile == nil, r2 and r2.cls)
    A.reset(nil)
end

-- ================================================================ 10d1. a refused attack leaves the running fight alone (live 18:19: died at 1 %)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local runt = new_creature("BP_AI_RuntGoblin_Character_C_busy", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    local keb = new_creature("BP_AI_Kebbit_Character_02_C_busy", "Kebbit", { X = 0, Y = 400, Z = 0 }, { hp = 30, pl = 1, arch = 4 })
    check("busy: the reflex fight starts", Cm._start_fight(nil, runt, { mode = "reflex", level = "reflex", why = "attacked_me" }).ok)
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    local r = Cm._start_fight(nil, keb, { mode = "attack", force = true, by = "brain" }) -- command level: refused
    check("busy: a command-level attack during a reflex fight is refused (pawn_busy)", not r.ok and r.data.why == "pawn_busy"
          and r.data.current_fight and r.data.current_fight.target == "Goblin Runt", r.data and r.data.why)
    local f = Cm._state().fight
    check("busy: the reflex fight is NOT ended", f and f.target_name == "Goblin Runt" and not f.done, f and f.target_name)
    run_until(function() return Cm._state().fight == nil end, 30)
    local res = Cm._state().last.result
    check("busy: and it goes on to win", res and res.ok and runt.hp <= 0, res and res.reason)
    -- same level: the new fight replaces the old one (ended as interrupted)
    local r1 = new_creature("BP_AI_RuntGoblin_Character_C_busy2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 600, pl = 1, arch = 0 })
    local k2 = new_creature("BP_AI_Kebbit_Character_02_C_busy2", "Kebbit", { X = 0, Y = 200, Z = 0 }, { hp = 30, pl = 1, arch = 4 })
    Cm._start_fight(nil, r1, { mode = "reflex", level = "reflex", why = "attacked_me" })
    run_until(function() local ff = Cm._state().fight; return ff and ff.phase == "engage" end, 3)
    local old = Cm._state().fight
    local r2 = Cm._start_fight(nil, k2, { mode = "attack", level = "reflex", force = true, by = "test" })
    check("busy: a same-level fight replaces the old one", r2.ok and old.done and Cm._state().fight.target_name == "Kebbit", r2.reason)
    Cm.stop(nil, "test")
    A.reset(nil)
end

-- ================================================================ 10d2. BUGS L39: idle "Breathe" animations are not a breath attack
do
    local kb = Cm.ability_profile("DAA_Kebbit_Breathe_01_C")
    local dr = Cm.ability_profile("DAA_Deer_Breathe_01_C")
    local pb = Cm.ability_profile("DAA_DragonVelgar_PoisonBreath_Front_C")
    check("L39: a Kebbit's Breathe is idle (no threat)", kb and kb.kind == "idle" and not kb.threat, kb and kb.kind)
    check("L39: a Deer's Breathe is idle", dr and dr.kind == "idle" and not dr.threat, dr and dr.kind)
    check("L39: Velgar's PoisonBreath is still a breath cone (front, a threat)", pb and pb.kind == "breath_cone" and pb.threat and pb.side == "front", pb and pb.kind)
    check("L39: PoisonBreath keeps its own profile (Poison status), not plain Breath", pb and pb.token == "PoisonBreath" and pb.status == "Poison", pb and pb.token)
    -- every DAA_ class in the 26161880 dump resolves to the profile its name says (whole words, not substrings)
    local want = {
        DAA_DragonVelgar_PoisonBreath_Left_C = { "breath_cone", "left" }, DAA_DragonVelgar_PoisonBreath_Right_C = { "breath_cone", "right" },
        DAA_DragonVelgar_EarthSpikes_C = { "ground_spikes" }, DAA_DragonVelgar_MeteorStrike_C = { "meteor" },
        DAA_DragonVelgar_Reposition_C = { "reposition" }, DAA_DragonVelgar_Intro_C = { "cinematic" },
        DAA_DragonVelgar_Death_C = { "cinematic" }, DAA_Shared_Death_C = { "cinematic" }, DAA_AbyssalDemon_Death_C = { "cinematic" },
        DAA_KalphiteWorker_Death_C = { "cinematic" }, DAA_DragonVelgar_Idle_3_C = { "idle" }, DAA_DragonLesser_Idle_C = { "idle" },
        DAA_DragonLesser_Idle_Breaker_02_C = { "idle" }, DAA_DragonLesser_Alert_Idle_Breaker_01_C = { "idle" },
        DAA_Cow_Alert_Idle_break_C = { "idle" },
    }
    for cls, w in pairs(want) do
        local p = Cm.ability_profile(cls)
        check("L39: " .. cls .. " -> " .. w[1], p and p.kind == w[1] and (w[2] == nil or p.side == w[2]), p and (p.kind .. "/" .. tostring(p.side)))
    end
    check("L39: no profile for a montage", Cm.ability_profile("DAA_Shared_PlayMontage_C") == nil)
    -- the matcher is general, not the Breathe entry: with no Breathe/Idle tokens at all, a Breathe still is no breath,
    -- and no token matches inside a longer word (Idler, Deathless, Frontflip, Spikesaw), whatever the order
    Cm.set_data("ability_profiles", { order = { "Breath", "Idle", "Death", "Spikes" }, Breath = { kind = "breath_cone" },
        Idle = { kind = "idle" }, Death = { kind = "cinematic" }, Spikes = { kind = "ground_spikes" }, sides = { Front = "front" } })
    check("L39: Breath never matches Breathe (no Breathe entry)", Cm.ability_profile("DAA_Kebbit_Breathe_01_C") == nil)
    check("L39: Breath never matches Breathing", Cm.ability_profile("DAA_Wolf_Breathing_C") == nil)
    check("L39: Idle never matches Idler", Cm.ability_profile("DAA_X_Idler_C") == nil)
    check("L39: Death never matches Deathless", Cm.ability_profile("DAA_X_DeathlessRoar_C") == nil)
    check("L39: Spikes never matches Spikesaw", Cm.ability_profile("DAA_X_Spikesaw_C") == nil)
    local ff = Cm.ability_profile("DAA_X_FireBreath_Frontflip_C")
    check("L39: a CamelCase word still matches (FireBreath) and Front is not in Frontflip", ff and ff.kind == "breath_cone" and ff.side == nil, ff and tostring(ff.side))
    local ac = Cm.ability_profile("DAA_X_AIBreath01_C")
    check("L39: acronym and digit boundaries split (AIBreath01)", ac and ac.kind == "breath_cone", ac and ac.kind)
    Cm.set_data("ability_profiles", nil) -- reload the real data file
    check("L39: words() splits CamelCase, acronyms and digits", table.concat(Cm.words("DAA_AIAction_PoisonBreath01_C"), " ") == "daa ai action poison breath 01 c",
        table.concat(Cm.words("DAA_AIAction_PoisonBreath01_C"), " "))
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
    -- no census without an AI action that names hazards (hot path): a meteor alone is not looked for
    local m0 = meteor("Meteor_0", { X = pawn.loc.X, Y = pawn.loc.Y, Z = 0 }, 400, 3.0)
    run_until(function() return false end, 1)
    check("hazard: no census until an ability names a hazard", (MV.escapes or 0) == 0 and MV.zones == nil)
    m0._dead_obj = true
    -- the creature starts its meteor strike (the ability profile names "meteor" and "poison_cloud")
    local acomp = obj({ GetOwner = function() return gob end, CurrentAction = obj({ GetClass = function()
        return obj({}, "BlueprintGeneratedClass /Game/AI/X.DAA_DragonVelgar_MeteorStrike_C") end }, "A /x") }, "C /Game/L.L:PersistentLevel.Gob.Actions")
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return acomp end }, { get = function() return 4 end })
    run_until(function() return false end, 0.3)
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

-- ================================================================ 10h. ambient hazards + cures outside fights (always-on service, off by default)
reset_world()
do
    local poison = { EffectType = 2, CurrentValue = 0, Config = { MaximumValue = 100 } }
    pawn.TrackedStatusEffectsComponent = obj({ TrackedStatusEffectInstances = { ForEach = function(_, f)
        f(1, { get = function() return obj(poison, "TrackedStatusEffectInstance /x") end }) end } }, "C /x")
    local saved_hotbar = inv_list.hotbar
    inv_list.hotbar = { { item = "ITEM_Potion_Antipoison_Lesser", name = "Lesser Antipoison Potion", count = 3, consumable = "potion", slot = 2 } }
    world.on_step = function() for _, u in ipairs(INV.uses) do if u == "ITEM_Potion_Antipoison_Lesser" then poison.CurrentValue = 0 end end end
    -- Claude is following Luis (a command owner of the pawn)
    local own = A.request(nil, { name = "brain:follow", level = "command", uses_move = true, resumable = true })
    fake_move.follow(nil, "Zezima", 3, {})
    Cm.guard_start(nil)
    local function hurt() poison.CurrentValue = 40; Cm._state().me_seq = (Cm._state().me_seq or 0) + 1 end
    -- (a) off by default: poisoned and hurt, nothing is used
    Cm.cfg.ambient = nil
    hurt()
    run_until(function() return false end, 2)
    check("ambient: off by default (no env, no cfg)", #INV.uses == 0 and Cm.status().ambient.enabled == false, #INV.uses)
    -- (b) on: a damage event -> statuses read -> the cure, under a short reflex lease; the follow is suspended and resumed
    Cm.cfg.ambient = true
    hurt()
    local used = run_until(function() return #INV.uses >= 1 end, 3)
    check("ambient: poisoned while following -> the cure is used", used and INV.uses[1] == "ITEM_Potion_Antipoison_Lesser", table.concat(INV.uses, ","))
    check("ambient: it took the pawn with a reflex lease", (Cm._state().ambient.n_leases or 0) >= 1)
    MV.calls = {}
    local resumed = run_until(function() local o = A.owner(); return o and o.name == "brain:follow" end, 6)
    check("ambient: the follow is resumed after", resumed, A.owner() and A.owner().name)
    local back = false
    for _, cl in ipairs(MV.calls) do if cl:find("Zezima", 1, true) then back = true end end
    check("ambient: the follow's move is replayed", back, table.concat(MV.calls, ","))
    -- (c) a hazard while following: walk out under the lease, then the follow comes back
    local meteors = {}
    local real_find = FindAllOf
    FindAllOf = function(cls)
        if cls == "AIMeteorProjectile" then local out = {}; for _, m in ipairs(meteors) do if not m._dead_obj then out[#out + 1] = m end end; return out end
        return real_find(cls)
    end
    local drake = new_creature("BP_AI_DragonVelgar_Character_C_amb", "Velgar", { X = 3000, Y = 0, Z = 0 }, { hp = 6000, pl = 4, arch = 0, boss = true })
    local acomp = obj({ GetOwner = function() return drake end, CurrentAction = obj({ GetClass = function()
        return obj({}, "BlueprintGeneratedClass /Game/AI/X.DAA_DragonVelgar_MeteorStrike_C") end }, "A /x") }, "C /Game/L.L:PersistentLevel.Drake.Actions")
    hooks["/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction"]({ get = function() return acomp end }, { get = function() return 9 end })
    run_until(function() return false end, 0.5)
    check("ambient: the AI action opens the hazard watch outside a fight", ((Cm._state().hazard_watch or {}).meteor or 0) > T)
    local m = obj({ Radius = 400, TelegraphTime = 2.0, loc = { X = pawn.loc.X, Y = pawn.loc.Y, Z = 0 } }, "BP_Meteor_C /Game/L.L:PersistentLevel.MeteorA")
    function m:K2_GetActorLocation() return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    meteors[1] = m
    MV.escape_reply = { ok = true, at = { pawn.loc.X / 100 + 6, pawn.loc.Y / 100, 0 }, eta_s = 0.8 }
    check("ambient: a meteor on him while following -> escape_zones", run_until(function() return (MV.escapes or 0) >= 1 end, 3), MV.escapes)
    m._dead_obj = true
    resumed = run_until(function() local o = A.owner(); return o and o.name == "brain:follow" end, 5)
    check("ambient: the follow is resumed after the escape", resumed, A.owner() and A.owner().name)
    -- (d) DW_PAUSE / (e) a dead pawn: nothing at all
    _G.DW_PAUSE = true
    hurt(); INV.uses = {}
    run_until(function() return false end, 2)
    _G.DW_PAUSE = nil
    check("ambient: nothing under DW_PAUSE", #INV.uses == 0, #INV.uses)
    local real_dead = pawn.HealthComponent.IsDead
    pawn.HealthComponent.IsDead = function() return true end
    hurt(); INV.uses = {}
    run_until(function() return false end, 2)
    pawn.HealthComponent.IsDead = real_dead
    check("ambient: nothing while dead", #INV.uses == 0, #INV.uses)
    Cm.guard_stop(nil)
    Cm.cfg.ambient = nil
    FindAllOf = real_find
    MV.escape_reply, MV.escapes = nil, nil
    inv_list.hotbar, pawn.TrackedStatusEffectsComponent, world.on_step = saved_hotbar, nil, nil
    Cm._state().hazard_watch, Cm._state().ambient = nil, nil
    if own and own.token then A.release(nil, own.token, "test") end
    A.reset(nil)
end

-- ================================================================ 10i. attacked while fishing (live 15:38:59: 4 swings of a rod, 0 hits, died)
reset_world()
do
    local saved = inv_list.hotbar
    local FISH = { stops = {} }
    Cm.set_modules({ fishing = { stop = function(_, why) FISH.stops[#FISH.stops + 1] = why; return { ok = true } end } })
    -- (a) no weapon at all: the rod is put away, he fights bare-handed, his hits land
    inv_list.hotbar = { { item = "ITEM_FishingRod_Wood", name = "Wooden Fishing Rod", slot = 1 },
                        { item = "ITEM_Food_Sandwich", name = "Forager's Sandwich", consumable = "food", heal = 10, slot = 0 } }
    held.right, held.left = "ITEM_FishingRod_Wood", nil
    INV.unequips = {}
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_fish", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    check("fishing: self-defence starts", Cm._start_fight(nil, gob, { mode = "reflex", level = "reflex", why = "attacked_me" }).ok)
    run_until(function() return Cm._state().fight == nil end, 20)
    local res = Cm._state().last.result
    check("fishing: the rod is put away first (unequip HeldRight)", (INV.unequips or {})[1] == "HeldRight" and held.right == nil, table.concat(INV.unequips or {}, ","))
    check("fishing: bare-handed hits land and the runt dies", res and res.ok and gob.hp <= 0, res and res.reason)
    check("fishing: the fishing job was stopped (not suspended by the arbiter)", FISH.stops[1] ~= nil and FISH.stops[1]:find("attacked", 1, true) ~= nil, FISH.stops[1])
    -- (b) a weapon in the bag: equipped over the rod (no bare hands)
    reset_world()
    inv_list.hotbar = { { item = "ITEM_FishingRod_Wood", name = "Wooden Fishing Rod", slot = 1 }, { item = "ITEM_Dagger_Bone", slot = 5 } }
    held.right, held.left = "ITEM_FishingRod_Wood", nil
    INV.unequips = {}
    local gob2 = new_creature("BP_AI_RuntGoblin_Character_C_fish2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    Cm._start_fight(nil, gob2, { mode = "reflex", level = "reflex", why = "attacked_me" })
    run_until(function() return Cm._state().fight == nil end, 20)
    check("fishing: a carried weapon is equipped over the rod", INV.equips[1] == "ITEM_Dagger_Bone" and #(INV.unequips or {}) == 0, INV.equips[1])
    -- (c) a fishing job the arbiter SUSPENDED for the fight is left alone (it resumes after)
    reset_world()
    FISH.stops = {}
    local job = A.request(nil, { name = "fish", level = "task", resumable = true, uses_move = true })
    inv_list.hotbar = { { item = "ITEM_Dagger_Bone", slot = 5 } }
    held.right = "ITEM_Dagger_Bone"
    local gob3 = new_creature("BP_AI_RuntGoblin_Character_C_fish3", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    Cm._start_fight(nil, gob3, { mode = "reflex", level = "reflex", why = "attacked_me" })
    run_until(function() return Cm._state().fight == nil end, 20)
    check("fishing: a suspended fishing job is not stopped", #FISH.stops == 0, FISH.stops[1])
    check("fishing: and it is resumed after the fight", A.owner() and A.owner().name == "fish", A.owner() and A.owner().name)
    if job and job.token then A.release(nil, job.token, "test") end
    check("fights_with: a rod / net / unknown item no, a dagger / shield / axe yes",
          not Cm.fights_with("ITEM_FishingRod_Wood") and not Cm.fights_with("ITEM_FishingNet_CoarseNet") and Cm.fights_with("ITEM_Dagger_Bone")
          and Cm.fights_with("ITEM_Shield_Bronze") and Cm.fights_with("ITEM_Logging_Axe_Mithril"))
    Cm.set_modules({ fishing = false })
    inv_list.hotbar = saved
    A.reset(nil)
end

-- ================================================================ 10j. losing fast: end it before it is fatal (live 16:15: a "losing" flee 14 s in, died fleeing)
reset_world()
do
    local saved = inv_list.hotbar
    local o0 = { disengage = Cm.orders.disengage, heal_hp = Cm.orders.heal_hp, reengage_hp = Cm.orders.reengage_hp }
    -- (a) self-defence, no food, HP falling ~6/s, his swings not landing (the runt does not die): flee EARLY, on the
    -- trend (the estimate says "winnable": a 120 HP runt), long before 40 % HP
    inv_list.hotbar = { { item = "ITEM_Dagger_Bone", slot = 5 } }
    held.right, held.left = "ITEM_Dagger_Bone", nil
    world.inputs_dead = true
    local g = new_creature("BP_AI_RuntGoblin_Character_C_lose", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 120, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "reflex", level = "reflex", why = "attacked_me" })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    world.on_step = function() if pawn.hp > 0 then pawn.hp = pawn.hp - 0.06 end end
    local fled = run_until(function() local f = Cm._state().fight; return (f and f.phase == "flee") or f == nil end, 20)
    local f = Cm._state().fight
    check("losing fast: a self-defence fight with no food flees early", fled and f and f.phase == "flee" and pawn.hp > 40, tostring(pawn.hp))
    check("losing fast: the reason names the time to live", f and (f.phase_log[#f.phase_log] or ""):find("losing fast", 1, true) ~= nil, f and f.phase_log[#f.phase_log])
    world.on_step, world.inputs_dead = nil, nil
    Cm.stop(nil, "test")
    A.reset(nil)
    -- (b) commanded, food carried, disengage orders (heal_hp 0.3): disengage to heal BEFORE 30 % (on the trend)
    reset_world()
    Cm.set_orders({ disengage = true, heal_hp = 0.3, reengage_hp = 0.8 })
    inv_list.hotbar = { { item = "ITEM_Dagger_Bone", slot = 5 }, { item = "ITEM_Food_Sandwich", name = "Forager's Sandwich", consumable = "food", heal = 10, slot = 0 } }
    held.right, held.left = "ITEM_Dagger_Bone", nil
    pawn.hp = 100
    local g2 = new_creature("BP_AI_RuntGoblin_Character_C_lose2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g2, { mode = "attack", force = true, by = "brain" })
    run_until(function() local ff = Cm._state().fight; return ff and ff.phase == "engage" end, 3)
    world.on_step = function() if pawn.hp > 0 then pawn.hp = pawn.hp - 0.06 end end
    local dis = run_until(function() local ff = Cm._state().fight; return ff and ff.phase == "disengage" end, 20)
    check("losing fast: a commanded fight disengages to heal before heal_hp", dis and pawn.hp > 60, tostring(pawn.hp))
    world.on_step = nil
    Cm.stop(nil, "test")
    A.reset(nil)
    -- (c) HP falling but the creature dies first: keep fighting (no flee, no disengage)
    reset_world()
    inv_list.hotbar = { { item = "ITEM_Dagger_Bone", slot = 5 } }
    held.right, held.left = "ITEM_Dagger_Bone", nil
    pawn.hp = 100
    local g3 = new_creature("BP_AI_RuntGoblin_Character_C_win", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    Cm._start_fight(nil, g3, { mode = "reflex", level = "reflex", why = "attacked_me" })
    world.on_step = function() if pawn.hp > 0 then pawn.hp = pawn.hp - 0.03 end end
    run_until(function() return Cm._state().fight == nil end, 30)
    world.on_step = nil
    local r3 = Cm._state().last.result
    check("winning while hurt: no early flee, the creature dies", r3 and r3.ok and g3.hp <= 0, r3 and r3.reason)
    A.reset(nil)
    -- (d) the stamina reserve: no swing that would leave less than a dodge (a defend-heavy fight keeps its dodge)
    reset_world()
    held.right, held.left = "ITEM_Dagger_Bone", nil
    pawn.hp = 100
    local g4 = new_creature("BP_AI_RuntGoblin_Character_C_stam", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g4, { mode = "attack", force = true, by = "brain" })
    run_until(function() local ff = Cm._state().fight; return ff and ff.phase == "engage" end, 3)
    local reserve = Cm.defence_reserve(Cm._state().fight)
    world.on_step = function() stamina = reserve + 3 end -- below reserve + any swing's cost
    local p0 = world.injected.IA_PrimaryAction or 0
    run_until(function() return false end, 3)
    check("stamina: no swing below the dodge reserve", (world.injected.IA_PrimaryAction or 0) == p0, (world.injected.IA_PrimaryAction or 0) - p0)
    world.on_step = function() stamina = 80 end
    run_until(function() return (world.injected.IA_PrimaryAction or 0) > p0 end, 3)
    check("stamina: swings again with stamina to spare", (world.injected.IA_PrimaryAction or 0) > p0)
    -- (d2) held back by the reserve for reserve_wait_s, he swings on what he has (exhausted: max stamina 40, live
    -- 17:35Z parried a 20-HP runt for 24 s without a swing); a finishing blow needs no reserve at all
    world.on_step = function() stamina = reserve + 3 end
    run_until(function() return false end, 1.5)
    local p1 = world.injected.IA_PrimaryAction or 0
    run_until(function() return false end, 2)
    check("stamina: still holding inside the wait", (world.injected.IA_PrimaryAction or 0) == p1, (world.injected.IA_PrimaryAction or 0) - p1)
    run_until(function() return (world.injected.IA_PrimaryAction or 0) > p1 end, Cm.cfg.reserve_wait_s + 1)
    check("stamina: swings after reserve_wait_s held back", (world.injected.IA_PrimaryAction or 0) > p1)
    local ff = Cm._state().fight
    local prim = (ff.profile or {}).prim or {}
    check("stamina: a finishing blow needs only the swing's cost",
          Cm.swing_need({ profile = ff.profile, t = 0, target_hp = 1 }, prim) <
          Cm.swing_need({ profile = ff.profile, t = 0, target_hp = 4000 }, prim))
    world.on_step = nil
    Cm.stop(nil, "test")
    Cm.set_orders(o0)
    inv_list.hotbar = saved
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

-- ================================================================ 19b. lock-on mode is gameplay (live skill_routes 2026-10-26: "stuck in DIM_Gameplay_LockOnTargeting")
reset_world()
do
    check("gameplay modes: DIM_Gameplay and its variants", Cm.is_gameplay_mode("DIM_Gameplay") and Cm.is_gameplay_mode("DIM_Gameplay_LockOnTargeting")
          and not Cm.is_gameplay_mode("DIM_OculusBuildMenu") and not Cm.is_gameplay_mode("DIM_ConversationUI") and not Cm.is_gameplay_mode(nil))
    local back = obj({}, "InputAction /Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    local real_sfo = StaticFindObject
    StaticFindObject = function(path) if path:find("IA_UI_GenericBack", 1, true) then return back end return real_sfo(path) end
    pc.CurrentInputMode = obj({}, "DominionInputMode /Game/Inputs/DIM_Gameplay_LockOnTargeting")
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local gob = new_creature("BP_AI_RuntGoblin_Character_C_lock", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 60, pl = 1, arch = 0 })
    check("lock-on mode: fight starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
    run_until(function() return Cm._state().fight == nil end, 20)
    local res = Cm._state().last.result
    check("lock-on mode: attacks (no back key, no input_mode_blocked)", (world.injected.IA_PrimaryAction or 0) >= 1 and (world.injected.IA_UI_GenericBack or 0) == 0
          and not (res and res.data and res.data.why == "input_mode_blocked"), res and res.reason)
    check("lock-on mode: the fight is won", res and res.ok and gob.hp <= 0, res and res.reason)
    pc.CurrentInputMode = nil
    StaticFindObject = real_sfo
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
    -- the held staff known to hit for 1 while his best melee does more: the reflex/attack fights with the melee
    -- weapon instead (live 22:05Z: the Ash Shortbow he had out at ~4 a hit, a Stone Club in the bag)
    inv_list.loadout = { { item = "ITEM_Rune_Fire", name = "Fire Rune", count = 40, loadout_slot = "MagicAmmo1", slot = 6 } }
    Cm._state().hit_dmg = Cm._state().hit_dmg or {}
    local staff_name = (Cm.weapons().items.ITEM_Staff_Ash or {}).name
    Cm._state().hit_dmg[staff_name] = 1
    held.right, held.left = nil, "ITEM_Staff_Ash"
    INV.equips = {}
    gob.hp = 90
    Cm.attack(nil, "Goblin Runt", { force = true })
    run_until(function() local f = Cm._state().fight; return f == nil or (f.equip_plan ~= nil) end, 5)
    local f3 = Cm._state().fight
    local plan_w = f3 and f3.equip_plan and f3.equip_plan.weapon or (Cm._state().last and Cm._state().last.weapon)
    check("weak held staff (learned 1/hit) -> his melee weapon instead", plan_w ~= nil and plan_w ~= "ITEM_Staff_Ash", tostring(plan_w))
    Cm._state().hit_dmg[staff_name] = nil
    Cm.stop(nil)
    run_until(function() return Cm._state().fight == nil end, 5)
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
    local kpath = Cm.knowledge_path("shockbyte")
    check("memory: written once at the fight's end (tmp then renamed), the world's shared knowledge with it", #writes == 2
          and writes[1].path == path .. ".tmp" and writes[2].path == kpath .. ".tmp" and exists(path) and exists(kpath)
          and not exists(path .. ".tmp") and not exists(path .. ".bak") and not exists(kpath .. ".tmp"), #writes)
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
    stale = (read(kpath) or ""):gsub('"build":"TESTBUILD"', '"build":"OLD1"') -- (a patch: the shared knowledge is as old)
    f = io.open(kpath, "wb"); f:write(stale); f:close()
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

os.remove(Cm.ACTIVITY_PATH)
os.execute('rmdir /s /q "' .. (tmpdir .. "/test_combat_mem_" .. RUN_ID):gsub("/", "\\") .. '" 2>nul')
-- ================================================================ 22b. the memory's world: never a silent "shockbyte" (live 2026-10-26: dev fights filed there)
do
    local saved = _G.DW_WORLD_GUID
    local files = {}
    local real_open = Cm.fs.open
    Cm.fs.open = function(path, mode)
        for suffix, content in pairs(files) do
            if path:sub(-#suffix) == suffix then
                local lines, i = {}, 0
                for l in (content .. string.char(10)):gmatch("(.-)" .. string.char(10)) do lines[#lines + 1] = l end
                return { read = function(_, fmt) if fmt == "l" then i = i + 1; return lines[i] end return content end, close = function() end }
            end
        end
        return nil
    end
    local function wid() Cm._reset_world_cache(); return Cm.world_id() end
    _G.DW_WORLD_GUID = nil
    local NL, BOM = string.char(10), string.char(239, 187, 191)
    files = { ["logs/state/last_join.json"] = BOM .. '{"addr":"127.0.0.1:7777","ts":"x"}',
              ["client_io/secrets/server.txt"] = "203.0.113.5:7777" .. NL .. "SECRET",
              ["client_io/secrets/server_dev.txt"] = "127.0.0.1:7777" .. NL .. "PW" }
    local id, src = wid()
    check("world: the joined dev server -> dev (no env)", id == "dev" and src == "joined", tostring(id) .. " " .. tostring(src))
    files["logs/state/last_join.json"] = '{"addr":"203.0.113.5:7777"}'
    id, src = wid()
    check("world: the joined Shockbyte address -> shockbyte", id == "shockbyte" and src == "joined", id)
    files["logs/state/last_join.json"] = '{"addr":"198.51.100.9:7777"}'
    id, src = wid()
    check("world: an unknown server is named, never shockbyte", id == "server_198_51_100_9_7777" and src == "joined_unknown", id)
    files = {}
    id, src = wid()
    check("world: nothing known -> unknown, never shockbyte", id == "unknown" and src == "unknown", id)
    _G.DW_WORLD_GUID = "dev_scenarios"
    id, src = wid()
    check("world: an explicit DW_WORLD_GUID wins", id == "dev_scenarios" and src == "global", tostring(id) .. " " .. tostring(src))
    Cm.fs.open = real_open
    _G.DW_WORLD_GUID = saved
    Cm._reset_world_cache()
end

-- ================================================================ 22c. the REAL Ash Rod item data (live 16:03: "keep a held magic item" kept the rod)
reset_world()
do
    local rod = Cm.weapons().items.ITEM_FishingRod_Ash
    check("rod data: the game says kind magic, role tool", rod and rod.kind == "magic" and rod.role == "tool", rod and rod.kind)
    check("rod data: it does not fight", not Cm.fights_with("ITEM_FishingRod_Ash"))
    local saved = inv_list.hotbar
    -- (a) holding the real rod, a Bronze Greatsword carried: the sword is equipped (not the rod kept)
    inv_list.hotbar = { { item = "ITEM_FishingRod_Ash", name = "Ash Rod", slot = 7 }, { item = "ITEM_GreatSword_Bronze", name = "Bronze Greatsword", slot = 2 } }
    held.right, held.left = "ITEM_FishingRod_Ash", nil
    INV.unequips = {}
    local g1 = new_creature("BP_AI_RuntGoblin_Character_C_rod1", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    Cm._start_fight(nil, g1, { mode = "reflex", level = "reflex", why = "hostile_near" })
    run_until(function() return Cm._state().fight == nil or (Cm._state().fight.equip_plan ~= nil) end, 3)
    local plan = Cm._state().fight and Cm._state().fight.equip_plan or {}
    check("real rod: the carried greatsword is the weapon, not the rod", plan.weapon == "ITEM_GreatSword_Bronze", plan.weapon)
    Cm.stop(nil, "test")
    -- (b) holding the real rod, no weapon: the rod is put away (bare hands)
    reset_world()
    inv_list.hotbar = { { item = "ITEM_FishingRod_Ash", name = "Ash Rod", slot = 7 } }
    held.right, held.left = "ITEM_FishingRod_Ash", nil
    INV.unequips = {}
    local g2 = new_creature("BP_AI_RuntGoblin_Character_C_rod2", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 0 })
    Cm._start_fight(nil, g2, { mode = "reflex", level = "reflex", why = "hostile_near" })
    run_until(function() return Cm._state().fight == nil end, 20)
    check("real rod, no weapon: put away, bare hands win", (INV.unequips or {})[1] == "HeldRight" and Cm._state().last.result.ok, table.concat(INV.unequips or {}, ","))
    inv_list.hotbar = saved
    A.reset(nil)
end

-- ================================================================ 23. self-defence (live 2026-11-01 11:27: stood still while a runt hit him)
-- (a) pure: the learned enemy rate, threats from telegraphs, refuge, spells held, target-not-found detail
reset_world()
do
    check("expected_dps: unknown rhythm = nil", Dm.expected_dps("Goblin Runt") == nil)
    Dm.observe_cadence("Goblin Runt", 0); Dm.observe_cadence("Goblin Runt", 2); Dm.observe_cadence("Goblin Runt", 4)
    Dm.feedback("Goblin Runt:ATK_Slash", "block", "hit", 20)
    Dm.feedback("Goblin Runt:ATK_Slash", "block", "blocked", 0)
    Dm.feedback("Goblin Runt:ATK_Slash", "parry", "parried", 0)
    local dps, why = Dm.expected_dps("Goblin Runt")
    -- 20 dmg x (1 hit + 1) / (3 resolved + 2) / 2 s = 4
    check("expected_dps: damage x share landed / rhythm", dps and math.abs(dps - 4) < 0.01, dps)
    check("expected_dps: explains itself", why and why.interval_s == 2 and why.n == 3, why and why.n)
    check("enemy_dps reads it", math.abs((Cm.enemy_dps("Goblin Runt") or 0) - 4) < 0.01)
    check("enemy_dps: unknown creature = nil (the prior decides)", Cm.enemy_dps("Troll") == nil)
    _G.DWDefense = nil

    local cr = { { id = "g1", name = "Goblin Runt", distance_m = 3, archetype = 4 }, { id = "g2", name = "Goblin Runt", distance_m = 12, archetype = 4 } }
    local th = Cm.pick_threats(cr, {}, {}, { avoid = {} }, 10, Cm.cfg, { g1 = 9.5, g2 = 9.5 })
    check("telegraph near him = attacking_me", #th == 1 and th[1].id == "g1" and th[1].why == "attacking_me", #th)
    check("old telegraph = no threat", #Cm.pick_threats(cr, {}, {}, { avoid = {} }, 20, Cm.cfg, { g1 = 9.5 }) == 0)

    local me = { X = 0, Y = 0, Z = 0 }
    check("refuge: ally clear of the threat", Cm.ally_is_refuge({ X = -2000, Y = 0, Z = 0 }, me, { { pos = { X = 400, Y = 0, Z = 0 } } }))
    check("no refuge: ally beside the threat (live 11:28)", not Cm.ally_is_refuge({ X = 500, Y = 0, Z = 0 }, me, { { pos = { X = 400, Y = 0, Z = 0 } } }))
    check("no refuge: ally too far", not Cm.ally_is_refuge({ X = -9000, Y = 0, Z = 0 }, me, {}))
    check("no refuge: threats unknown", not Cm.ally_is_refuge({ X = -2000, Y = 0, Z = 0 }, me, nil))

    local F = { t = 10, ab_ctx = { windstep = { available = true }, tempest_shield = { available = true } }, ab_ctx_t = 10, assessment = { verdict = "likely_win" } }
    local ab0 = Cm.orders.abilities
    Cm.orders.abilities = {}
    check("spells held in a likely win", next(Cm.fight_abilities(F)) == nil and F.spells_held == true)
    F.assessment.verdict = "likely_lose"
    check("spells in a hard fight", Cm.fight_abilities(F).windstep ~= nil and F.spells_held == nil)
    F.assessment.verdict = "likely_win"
    Cm.orders.abilities = { windstep = true }
    local ab = Cm.fight_abilities(F)
    check("combat_orders can allow one in every fight", ab.windstep ~= nil and ab.tempest_shield == nil)
    Cm.orders.abilities = ab0

    local F2 = { held_s = {} }
    Cm.held(F2, "casting"); Cm.held(F2, "casting"); Cm.held(F2, "defending")
    local hs, txt = Cm._held_summary(F2)
    check("held back: seconds by cause", hs and hs.casting == 0.2 and hs.defending == 0.1 and txt:find("casting 0.2s", 1, true), txt)

    new_creature("BP_AI_Kebbit_C_near", "Kebbit", { X = 1200, Y = 0, Z = 0 }, { hp = 60 })
    local a, d = Cm.resolve_target("BP_AI_Kebbit_C_77", { X = 0, Y = 0, Z = 0 })
    check("gone id: nil + why + the nearest of its kind", a == nil and d and d.detail:find("died, despawned", 1, true)
        and d.nearest_same_kind and d.nearest_same_kind.id == "BP_AI_Kebbit_C_near", d and d.detail)
    local a2, d2 = Cm.resolve_target("Wolf", { X = 0, Y = 0, Z = 0 })
    check("no such creature: the radius in the reason", a2 == nil and d2 and d2.detail == "no living Wolf within 60 m", d2 and d2.detail)
    local a3 = Cm.resolve_target("kebbit", { X = 0, Y = 0, Z = 0 })
    check("name within 60 m resolves", a3 ~= nil)
end

-- (b) between fights a creature's hit is an impact event + an HP drop: the guard fights back at once, and says so
reset_world()
do
    os.remove(Cm.ACTIVITY_PATH)
    held.right, held.left = "ITEM_Dagger_Bone", nil
    Cm.guard_start(nil)
    local b = new_creature("BP_AI_Kebbit_Character_02_C_gh", "Kebbit", { X = 150, Y = 0, Z = 0 }, { hp = 40, pl = 1, arch = 1 })
    step(40) -- the guard has his HP
    local comp = obj({ GetOwner = function() return b end }, "C /x")
    hooks["/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData"]({ get = function() return comp end })
    pawn.hp = pawn.hp - 7
    local started = run_until(function() local f = Cm._state().fight; return f ~= nil end, 1)
    local f = Cm._state().fight
    check("guard: a non-hostile's hit starts the reflex within 1 s", started and f and f.why == "attacked_me" and f.target_id == "BP_AI_Kebbit_Character_02_C_gh",
        f and f.why)
    run_until(function() return Cm._state().fight == nil end, 20)
    check("guard: it is dealt with", b.hp <= 0, b.hp)
    local ev
    for _, l in ipairs(read_activity()) do if l:find('"kind":"combat_started"', 1, true) then ev = l end end
    check("combat_started event: decision, weapon, estimates", ev and ev:find('"decision":"fight"', 1, true) and ev:find('"weapon":"', 1, true)
        and ev:find('"est_s_to_kill":', 1, true), ev)
    local res = Cm._state().last.result
    check("result reports held_back_s", res and type(res.data.held_back_s) == "table", res and res.data.held_back_s)
    Cm.guard_stop(nil); A.reset(nil)
end

-- (c) a swing starting next to him is an attack on him (before its hit lands); passive waits for the hit
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    Cm.guard_start(nil)
    Cm.orders.stance = "passive"
    local g = new_creature("BP_AI_RuntGoblin_Character_C_tg", "Goblin Runt", { X = 250, Y = 0, Z = 0 }, { hp = 30, pl = 1, arch = 4 })
    step(40) -- (the guard knows where he is)
    world.resolved = true -- (the telegraph only; no resolution)
    goblin_attack(g, 0.8); world.on_step = nil
    step(50)
    check("passive: a swing alone does not start a fight", Cm._state().fight == nil)
    local ti = (Cm._state().tele_info or {})["BP_AI_RuntGoblin_Character_C_tg"]
    check("between fights a swing near him is read (its key for the first defence)", ti and ti.key == "Goblin Runt:ATK_Goblin_Slash", ti and ti.key)
    Cm.orders.stance = "defensive"
    goblin_attack(g, 0.8); world.on_step = nil
    local started = run_until(function() return Cm._state().fight ~= nil end, 0.6)
    check("defensive: a swing next to him starts the reflex before the hit", started and Cm._state().fight.why == "attacking_me",
        Cm._state().fight and Cm._state().fight.why)
    Cm.stop(nil, "test")
    Cm.guard_stop(nil); A.reset(nil)
end

-- (d) the flee is bounded: no farther than the leash; one that keeps up with him is fought (flee_failed, said)
reset_world()
do
    os.remove(Cm.ACTIVITY_PATH)
    local p0 = Cm.orders.protect
    Cm.orders.protect = "Nobody" -- (no player to run to: the flee runs away from the threat)
    Cm.guard_start(nil)
    local id = "BP_AI_Troll_C_leash"
    local troll = new_creature(id, "Troll", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, troll, 30); pawn.hp = 70
    check("leash: a strong attacker -> flee", run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4))
    local F = Cm._state().fight
    world.on_step = function() -- as fast as he is: 4 m behind him, still swinging
        local dx, dy = troll.loc.X - pawn.loc.X, troll.loc.Y - pawn.loc.Y
        local dd = math.sqrt(dx * dx + dy * dy)
        if dd > 400 then troll.loc.X, troll.loc.Y = pawn.loc.X + dx / dd * 400, pawn.loc.Y + dy / dd * 400 end
        Cm._state().attackers[id] = T
    end
    local turned = run_until(function() return F.cornered ~= nil end, 20)
    local fled_m = math.sqrt(pawn.loc.X ^ 2 + pawn.loc.Y ^ 2) / 100
    check("leash: it kept up -> he turns and fights", turned and F.decision == "fight" and Cm._state().fight == F, F.cornered)
    check("leash: no farther than the leash (25 m)", fled_m <= Cm.cfg.flee_leash_m + 3, fled_m)
    step(200)
    check("leash: no second run while cornered", F.phase ~= "flee" and Cm._state().fight == F, F.phase)
    check("leash: one that kept up the whole leash is remembered", (Cm._state().caught_by or {})["Troll"] == true)
    local ev
    for _, l in ipairs(read_activity()) do if l:find('"kind":"flee_failed"', 1, true) then ev = l end end
    check("flee_failed event: why and what next", ev and ev:find("kept up with me", 1, true) and ev:find('"next":"fighting back"', 1, true), ev)
    world.on_step = nil
    Cm.stop(nil, "test")
    Cm.guard_stop(nil); A.reset(nil)
    Cm.orders.protect = p0
end

-- (e) it comes after him again right after he ran from it: fought, no second flee
reset_world()
do
    local id = "BP_AI_Troll_C_again"
    Cm._state().fled_from = { [id] = T - 5 }
    Cm.guard_start(nil)
    local troll = new_creature(id, "Troll", { X = 400, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    step(100)
    check("again: standing near (in combat) is no reason to run again", Cm._state().fight == nil)
    multicast(pawn, troll, 30); pawn.hp = 70
    run_until(function() return Cm._state().fight ~= nil end, 2)
    local F = Cm._state().fight
    step(200)
    check("again: cornered, no flee", F and F.cornered and F.cornered:find("came after me again", 1, true) and F.phase ~= "flee", F and F.phase)
    Cm.stop(nil, "test")
    Cm.guard_stop(nil); A.reset(nil)
end

-- (f) fleeing with the threat next to him: no bite under its blows
reset_world()
do
    Cm.guard_start(nil)
    local p0 = Cm.orders.protect
    Cm.orders.protect = "Nobody"
    local id = "BP_AI_Troll_C_eat"
    local troll = new_creature(id, "Troll", { X = 300, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, troll, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    world.on_step = function() -- glued to him
        troll.loc.X, troll.loc.Y = pawn.loc.X + 200, pawn.loc.Y
        Cm._state().attackers[id] = T
    end
    step(150)
    check("flee: no eating with the threat in reach", #INV.uses == 0, #INV.uses)
    world.on_step = function() troll.loc.X, troll.loc.Y = pawn.loc.X + 900, pawn.loc.Y; Cm._state().attackers[id] = T end
    run_until(function() return #INV.uses > 0 end, 3)
    check("flee: eats once it is out of reach", #INV.uses > 0, #INV.uses)
    world.on_step = nil
    Cm.stop(nil, "test")
    Cm.guard_stop(nil); A.reset(nil)
    Cm.orders.protect = p0
end

-- (g) a dodge took him 4 m off: he steps back in with the movement input and swings (live 12:53: move.follow's
-- planner stood ~2 s per gap, 36.7 s out of reach, died)
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", nil
    world.walk_input = true
    local follow0, follows = fake_move.follow, 0
    fake_move.follow = function() follows = follows + 1; return { ok = true, mode = "follow", target_visible = true } end -- (stands still)
    local g = new_creature("BP_AI_RuntGoblin_Character_C_step", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    pawn.loc = { X = -250, Y = 30, Z = 0 }
    local f0, p0 = follows, world.injected.IA_PrimaryAction or 0
    local back = run_until(function() return (world.injected.IA_PrimaryAction or 0) > p0 end, 3)
    local F = Cm._state().fight
    check("step in: back in reach and swinging within 3 s", back and F and (F.n_step_ins or 0) > 0, F and F.n_step_ins)
    check("step in: no planner follow for a short gap", follows == f0, follows - f0)
    -- above him (a ledge): that is the follow's job
    g.loc = { X = pawn.loc.X + 350, Y = pawn.loc.Y, Z = 400 }
    run_until(function() return follows > f0 end, 2)
    check("step in: a gap up a ledge goes to the follow", follows > f0)
    -- on his level but the step-in gains no ground (a rock between them; rung 5 Ratcatcher 20261116-065655: 63 s
    -- pushing at a ledge, the fight ended "timeout" with nothing said): the follow takes over, then approach
    g.loc = { X = pawn.loc.X + 350, Y = pawn.loc.Y, Z = pawn.loc.Z }
    world.walk_input = nil
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    local f1 = follows
    run_until(function() return follows > f1 end, 2.5)
    check("step in: no ground gained in 1 s goes to the follow", follows > f1, follows - f1)
    local ap = run_until(function() local f = Cm._state().fight; return f and f.phase == "approach" end, 5)
    F = Cm._state().fight
    check("engage: 4 s out of reach goes back to approach", ap, F and F.phase)
    check("engage: the way back is in the phase log", F and tostring(F.phase_log[#F.phase_log]):find("out of reach", 1, true) ~= nil, F and F.phase_log[#F.phase_log])
    fake_move.follow, world.walk_input = follow0, nil
    Cm.stop(nil, "test"); A.reset(nil)
end

-- (g2) the creature itself backs off while he steps in (a Goblin Runt's DodgeBack): nothing is between them, so the
-- step-in goes on. Rune Mysteries 20261116-074002: "step-in made no ground ... the follow goes round" twice against
-- three runts, the follow crept at 0.5 m/s, 12.2 s of 45 out of reach, 10 swings, dead
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", nil
    world.walk_input = true
    local follow0, follows = fake_move.follow, 0
    fake_move.follow = function() follows = follows + 1; return { ok = true, mode = "follow", target_visible = true } end
    local g = new_creature("BP_AI_RuntGoblin_Character_C_back", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    local t_back = T + 1.6
    world.on_step = function() if T < t_back then g.loc.X, g.loc.Y = pawn.loc.X + 350, pawn.loc.Y end end -- as fast as he steps
    local f0, p0 = follows, world.injected.IA_PrimaryAction or 0
    step(160)
    local F = Cm._state().fight
    check("step in: a creature that backs off is no stall (no follow)", follows == f0 and (F.n_step_stalls or 0) == 0,
        tostring(follows - f0) .. " follows, " .. tostring(F.n_step_stalls) .. " stalls")
    local back = run_until(function() return (world.injected.IA_PrimaryAction or 0) > p0 end, 2)
    check("step in: swinging again once it stops backing off", back and follows == f0, follows - f0)
    fake_move.follow, world.walk_input, world.on_step = follow0, nil, nil
    Cm.stop(nil, "test"); A.reset(nil)
end

-- (g4) still in his dodge (the body takes no walking input): that second is no stall
reset_world()
do
    held.right, held.left = "ITEM_Dagger_Bone", nil
    local follow0, follows = fake_move.follow, 0
    fake_move.follow = function() follows = follows + 1; return { ok = true, mode = "follow", target_visible = true } end
    local g = new_creature("BP_AI_RuntGoblin_Character_C_busy", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
    pawn.loc = { X = -200, Y = 0, Z = 0 } -- 3.5 m off, and (no walk_input) his steps gain nothing
    world.evading_until = T + 1.5
    local f0 = follows
    step(140)
    check("step in: no stall counted while he is still in his dodge", follows == f0 and (Cm._state().fight.n_step_stalls or 0) == 0, follows - f0)
    run_until(function() return follows > f0 end, 2)
    check("step in: once the dodge is over, 1 s without ground is a stall", follows > f0 and Cm._state().fight.n_step_stalls == 1, follows - f0)
    fake_move.follow, world.evading_until = follow0, nil
    Cm.stop(nil, "test"); A.reset(nil)
end

-- (g5) he swings at what he can reach. Ratcatcher 20261116-212108: the Giant Rat he was sent for stood up a ledge at
-- the windmill while two others bit him. The commanded fight kept to the one named: 120 s, 21 dodges, 52 s defending,
-- 6 swings, none landed, 114 damage taken, and he died in the fight after it
reset_world()
do
    local UP, BY = "BP_AI_GiantRat_Character_C_up", "BP_AI_GiantRat_Character_C_by"
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    world.wall_x = 100 -- (the foot of the ledge)
    local up = new_creature(UP, "Giant Rat", { X = 600, Y = 0, Z = 300 }, { hp = 40, pl = 1, arch = 0 })
    local by = new_creature(BY, "Giant Rat", { X = 0, Y = 150, Z = 0 }, { hp = 40, pl = 1, arch = 0, alert = 3 })
    check("swap: fight starts", Cm._start_fight(nil, up, { mode = "attack", force = true, by = "brain" }).ok)
    local bite_t = T + 1
    world.on_step = function()
        if by.hp <= 0 then return end
        by.loc = { X = pawn.loc.X, Y = pawn.loc.Y + 150, Z = pawn.loc.Z } -- it stays on him
        if T >= bite_t then bite_t = T + 1.5; pawn.hp = pawn.hp - 3; multicast(pawn, by, 3) end
    end
    run_until(function() return by.hp <= 0 or Cm._state().fight == nil end, 25)
    local F = Cm._state().fight
    check("swap: the one he went for is out of reach and another bites him: he kills that one", by.hp <= 0 and F ~= nil,
        "by.hp " .. tostring(by.hp) .. ", " .. tostring(not F and Cm._state().last.result.reason or F.phase))
    local back = run_until(function() local f = Cm._state().fight; return f == nil or (f.target_id == UP and f.phase == "approach") end, 8)
    F = Cm._state().fight
    check("swap: then he goes back for the one he went for", back and F ~= nil and F.target_id == UP, F and F.target_id)
    MV.extra = { status = "unreachable", unreachable = { reason = "leader_above_jump_height", detail = "dz=3.0m d=5.8m lp_fail=verify_exhausted" }, lp_fail = "verify_exhausted" }
    run_until(function() return Cm._state().fight == nil end, 10)
    local res = Cm._state().last.result
    check("swap: it ends on the one he went for, with the true reason", res and res.reason == "path_blocked" and res.data.target_id == UP
        and res.data.detail == "I can't get to the Giant Rat: the Giant Rat is higher up than I can jump.", res and (tostring(res.reason) .. " " .. tostring(res.data.target_id)))
    check("swap: the result says what he fought besides it", res and res.data.kills == 1
        and res.data.also_fought == "Besides the Giant Rat I went for, I fought what attacked me: 1 Giant Rat killed.", res and (tostring(res.data.also_fought) .. " kills " .. tostring(res.data.kills) .. " hits " .. tostring(res.data.hits)))
    check("swap: no went_for when it ended on the one he went for", res and res.data.went_for == nil)
    MV.extra, world.wall_x, world.on_step = nil, nil, nil
    A.reset(nil)

    -- in reach by the distance, but his swings land nothing (1.3 m above him: the swing has a height)
    reset_world()
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local air = new_creature(UP .. "2", "Giant Rat", { X = 150, Y = 0, Z = 130 }, { hp = 40, pl = 1, arch = 0 })
    air.unhittable = true
    local by2 = new_creature(BY .. "2", "Giant Rat", { X = 0, Y = -150, Z = 0 }, { hp = 40, pl = 1, arch = 0, alert = 3 })
    Cm._start_fight(nil, air, { mode = "attack", force = true, by = "brain" })
    bite_t = T + 1
    world.on_step = function()
        if by2.hp > 0 and T >= bite_t then bite_t = T + 1.5; pawn.hp = pawn.hp - 3; multicast(pawn, by2, 3) end
    end
    run_until(function() return by2.hp <= 0 or Cm._state().fight == nil end, 25)
    F = Cm._state().fight
    check("swap: swings that land nothing on the one he went for, and another bites him: he kills that one", by2.hp <= 0 and F ~= nil,
        "by2.hp " .. tostring(by2.hp) .. ", presses " .. tostring(F and F.presses))
    -- the fight ends while he is on another creature: the result says which one he went for
    world.on_step = nil
    local by3 = new_creature(BY .. "3", "Giant Rat", { X = pawn.loc.X, Y = pawn.loc.Y - 150, Z = 0 }, { hp = 5000, pl = 1, arch = 0, alert = 3 })
    bite_t = T
    world.on_step = function()
        if T >= bite_t then bite_t = T + 1.5; pawn.hp = math.max(40, pawn.hp - 3); multicast(pawn, by3, 3) end
    end
    local on3 = run_until(function() local f = Cm._state().fight; return f == nil or f.target_id == BY .. "3" end, 25)
    F = Cm._state().fight
    check("swap: a third one bites him once he is back on the one he cannot hit: he takes it too", on3 and F ~= nil and F.target_id == BY .. "3", F and F.target_id)
    Cm.stop(nil, "test")
    res = Cm._state().last.result
    check("swap: ended while on another creature: the result names the one he went for, not killed", res and type(res.data.went_for) == "table"
        and res.data.went_for.id == UP .. "2" and res.data.went_for.name == "Giant Rat" and res.data.went_for.killed == false
        and res.data.target_id == BY .. "3", res and res.data.target_id)
    check("swap: ...and what he fought", res and res.data.also_fought == "I did not kill the Giant Rat I went for; besides it I fought what attacked me: 1 Giant Rat killed, 1 Giant Rat not killed.",
        res and res.data.also_fought)
    world.on_step = nil
    A.reset(nil)

    -- an ordinary fight, his swings landing: another creature's bites do not pull him off the one he went for
    reset_world()
    held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
    local main = new_creature(UP .. "4", "Giant Rat", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    local by4 = new_creature(BY .. "4", "Giant Rat", { X = 0, Y = 150, Z = 0 }, { hp = 40, pl = 1, arch = 0, alert = 3 })
    Cm._start_fight(nil, main, { mode = "attack", force = true, by = "brain" })
    bite_t = T + 1
    world.on_step = function()
        if T >= bite_t then bite_t = T + 1.5; pawn.hp = math.max(60, pawn.hp - 3); multicast(pawn, by4, 3) end
    end
    step(1000)
    F = Cm._state().fight
    check("swap: none while his swings land on the one he went for", F ~= nil and F.target_id == UP .. "4" and (F.swaps or 0) == 0 and F.hits > 3,
        F and (tostring(F.target_id) .. " swaps " .. tostring(F.swaps) .. " hits " .. tostring(F.hits)))
    world.on_step = nil
    Cm.stop(nil, "test"); A.reset(nil)
end

-- (g3) no shield, so every swing at him is answered with a dodge: the wind-up before the dodge is time for a swing
-- of his own (the dodge cuts a swing short whenever it comes: live probe attack_evade_probe 2026-11-16). Rune
-- Mysteries 20261116-074002: 14.6 s of 45 standing between the telegraph and the dodge
for _, on in ipairs({ true, false }) do
    reset_world()
    held.right, held.left = "ITEM_Dagger_Bone", nil
    Cm.cfg.windup_swing = on
    Cm.orders.defense = "dodge" -- (the rig's dagger can block; live a Stone Dagger with no shield could only dodge)
    local g = new_creature("BP_AI_RuntGoblin_Character_C_wind" .. tostring(on), "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" and f.presses > 0 end, 3)
    local F = Cm._state().fight
    run_until(function() return T >= (F.next_press or 0) - 0.05 end, 2) -- his next swing is about due
    world.resolved, world.result = nil, nil
    goblin_attack(g, 1.4)
    run_until(function() return F.phase == "defend" end, 1)
    local p0, plan = F.presses, F.def and F.def.plan
    run_until(function() return not F.def or F.def.started end, 2)
    local in_windup = F.presses - p0
    run_until(function() return F.phase ~= "defend" end, 4)
    if on then
        check("wind-up: a dodge plan with room for a swing gets one", plan and plan.action == "dodge" and in_windup == 1 and F.n_windup == 1,
            tostring(plan and plan.action) .. " at " .. tostring(plan and plan.at_s) .. " presses " .. tostring(in_windup))
        check("wind-up: the dodge still comes and the swing is avoided", (F.n_dodges or 0) == 1 and world.result == "dodged", world.result)
    else
        check("wind-up (off): no swing between the telegraph and the dodge", in_windup == 0, in_windup)
    end
    world.on_step = nil
    Cm.stop(nil, "test"); A.reset(nil)
end
Cm.cfg.windup_swing = true
reset_world()
do -- no room: the dodge is due before his hit would land -> no swing
    held.right, held.left = "ITEM_Dagger_Bone", nil
    Cm.orders.defense = "dodge"
    local g = new_creature("BP_AI_RuntGoblin_Character_C_wind3", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" and f.presses > 0 end, 3)
    local F = Cm._state().fight
    run_until(function() return T >= (F.next_press or 0) - 0.05 end, 2)
    world.resolved, world.result = nil, nil
    goblin_attack(g, 0.55)
    run_until(function() return F.phase == "defend" end, 1)
    local p0 = F.presses
    run_until(function() return F.phase ~= "defend" end, 4)
    check("wind-up: a quick swing at him leaves no room, no swing of his", F.presses == p0 and (F.n_windup or 0) == 0, F.presses - p0)
    world.on_step, Cm.orders.defense = nil, nil
    Cm.stop(nil, "test"); A.reset(nil)
end
reset_world()
do -- an attack lands up to 0.2 s sooner or later than its data says (live 2026-11-16: Goblin Runt Attack2 0.90-1.17 s)
    held.right, held.left = "ITEM_Dagger_Bone", nil
    Cm.orders.defense = "dodge"
    local g = new_creature("BP_AI_RuntGoblin_Character_C_early", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" and f.presses > 0 end, 3)
    local F = Cm._state().fight
    local got = {}
    for _, late in ipairs({ -0.2, -0.1, 0, 0.1, 0.2 }) do
        world.resolved, world.result, world.evade_start = nil, nil, nil
        goblin_attack(g, 1.2, { late_s = late })
        run_until(function() return F.phase == "defend" end, 1)
        run_until(function() return F.phase ~= "defend" end, 4)
        got[#got + 1] = string.format("%+.1f %s", late, tostring(world.result))
        step(40)
    end
    local all = true
    for _, s in ipairs(got) do if not s:find("dodged") then all = false end end
    check("dodge: an impact 0.2 s sooner or later than its data is still inside the roll's invulnerable window", all, table.concat(got, ", "))
    world.on_step, Cm.orders.defense = nil, nil
    Cm.stop(nil, "test"); A.reset(nil)
end
reset_world()
do -- the dodge key that the game ate: pressed once more, the swing is still avoided
    held.right, held.left = "ITEM_Dagger_Bone", nil
    Cm.orders.defense = "dodge"
    local g = new_creature("BP_AI_RuntGoblin_Character_C_retap", "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
    Cm._start_fight(nil, g, { mode = "attack", force = true })
    run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" and f.presses > 0 end, 3)
    local F = Cm._state().fight
    world.resolved, world.result, world.evade_drop, world.evading_until = nil, nil, 1, nil
    goblin_attack(g, 1.4)
    run_until(function() return F.phase == "defend" end, 1)
    run_until(function() return F.phase ~= "defend" end, 4)
    check("dodge: a key press that did nothing is pressed again and the swing avoided", F.n_retaps == 1 and world.result == "dodged",
        tostring(F.n_retaps) .. " " .. tostring(world.result))
    world.resolved, world.result = nil, nil
    goblin_attack(g, 1.4)
    run_until(function() return F.phase == "defend" end, 1)
    run_until(function() return F.phase ~= "defend" end, 4)
    check("dodge: one that came out is not pressed twice", F.n_retaps == 1 and world.result == "dodged", tostring(F.n_retaps) .. " " .. tostring(world.result))
    world.on_step, Cm.orders.defense, world.evade_drop = nil, nil, nil
    Cm.stop(nil, "test"); A.reset(nil)
end

-- ================================================================ live 2026-11-01 22:05-22:08 (Luis's session)
reset_world()
do -- an attacker already on him and at least as fast: no flee, he fights (a cow hit him 36 in the flee's first 0.4 s)
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestCow_C_21", "Cow", { X = 300, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    enemy.CharacterMovement = obj({ MaxWalkSpeed = 750 }, "CMC /x")
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.decision ~= nil end, 4)
    local f = Cm._state().fight
    check("no flee: in reach and faster -> fights, says why", f and f.phase ~= "flee" and f.decision == "fight"
        and tostring(f.cornered):find("can't outrun", 1, true) ~= nil, f and (tostring(f.phase) .. " " .. tostring(f.cornered)))
    Cm.guard_stop(nil); A.reset(nil)
end
reset_world()
do -- the same threat farther than its reach: the flee still happens
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestCow_C_22", "Cow2", { X = 900, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    enemy.CharacterMovement = obj({ MaxWalkSpeed = 750 }, "CMC /x")
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.phase == "flee" end, 4)
    local f = Cm._state().fight
    check("flee: fast threat 9 m away -> still flees", f and f.phase == "flee", f and f.phase)
    Cm.guard_stop(nil); A.reset(nil)
end
reset_world()
do -- one that ran him down before, 9 m off: no flee (2026-11-16: every death began with a flee the runts kept up with)
    Cm._state().caught_by = { Cow3 = true }
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestCow_C_23", "Cow3", { X = 900, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.decision ~= nil end, 4)
    local f = Cm._state().fight
    check("no flee: it caught me running before, 9 m off -> fights, says why", f and f.phase ~= "flee" and f.decision == "fight"
        and tostring(f.cornered):find("caught me running before", 1, true) ~= nil, f and (tostring(f.phase) .. " " .. tostring(f.cornered)))
    Cm._state().caught_by = {}
    Cm.guard_stop(nil); A.reset(nil)
end
reset_world()
do -- over his carry weight: no flee (he only walks) and the reason is said
    fake_move.encumbrance = function() return { on = true, cur = 352, max = 300 } end
    Cm.guard_start(nil)
    local enemy = new_creature("BP_AI_TestCow_C_24", "Cow4", { X = 900, Y = 0, Z = 0 }, { hp = 900, pl = 6, arch = 0, alert = 4 })
    multicast(pawn, enemy, 30); pawn.hp = 40
    run_until(function() local f = Cm._state().fight; return f and f.decision ~= nil end, 4)
    local f = Cm._state().fight
    check("no flee: carrying too much -> fights, says why", f and f.phase ~= "flee" and f.decision == "fight"
        and tostring(f.cornered):find("352 of 300", 1, true) ~= nil, f and (tostring(f.phase) .. " " .. tostring(f.cornered)))
    fake_move.encumbrance = nil
    Cm.guard_stop(nil); A.reset(nil)
end
do -- over his carry weight the game gives no roll and no jump: the plan is what he can still do
    local info = { key = "CowT:Bite", dmg_time = 0.8 }
    local ctx = { dist_cm = 150, stamina = 100, can_parry = false, can_block = true, evade_cost = 15, hp_frac = 1, max_hp = 100, heavy = true }
    local fixed = function() return 0.5 end
    check("plan: heavy, orders dodge, a shield -> block", Dm.plan(info, ctx, { defense = "dodge" }, fixed).action == "block")
    ctx.can_block = false
    local p = Dm.plan(info, ctx, { defense = "dodge" }, fixed)
    check("plan: heavy, no shield -> no dodge", p.action ~= "dodge" and p.action ~= "jump", tostring(p.action))
    ctx.heavy = nil
    check("plan: the same, not heavy -> dodge", Dm.plan(info, ctx, { defense = "dodge" }, fixed).action == "dodge")
end
do -- the out-of-reach check counts the ground a closing attacker covers before its impact
    local info = { key = "CowT:Charge", dmg_time = 0.8 }
    local ctx = { dist_cm = 650, stamina = 100, can_parry = false, can_block = false, evade_cost = 15, hp_frac = 1, max_hp = 100 }
    local fixed = function() return 0.5 end
    check("plan: 6.5 m, standing -> out_of_reach", Dm.plan(info, ctx, {}, fixed).why == "out_of_reach")
    ctx.closing_cms = 400
    local p = Dm.plan(info, ctx, {}, fixed)
    check("plan: 6.5 m, closing at 4 m/s -> defends", p.action ~= "none" and (p.closing_cm or 0) > 0, tostring(p.action) .. " " .. tostring(p.why))
end
reset_world()
do -- attacking a creature someone else killed: the reason says whose kill it was, not "already dead"
    local gob = new_creature("BP_AI_TestGob_C_23", "Gob", { X = 200, Y = 0, Z = 0 }, { hp = 60, alert = 4 })
    local buddy = new_creature("BP_AI_TestBuddy_C_24", "Buddy", { X = 250, Y = 0, Z = 0 }, { hp = 60 })
    local hook = hooks["/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect"]
    Cm.guard_start(nil) -- (hooks on)
    hook = hooks["/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect"]
    gob.hp = 0
    local e = { Amount = 60, Instigator = buddy, bIsFatalHit = true }
    hook({ get = function() return gob.DamageComp end }, { get = function() return e end })
    local r = Cm.attack(nil, "BP_AI_TestGob_C_23")
    check("already dead: names the killer and his own hits", r.reason == "unknown_target" and r.data and r.data.killed_by == "Buddy"
        and tostring(r.data.detail):find("killed by Buddy", 1, true) ~= nil and tostring(r.data.detail):find("never hit it", 1, true) ~= nil,
        r.data and tostring(r.data.detail))
    Cm.guard_stop(nil); A.reset(nil)
end

-- a grave's killer: the fight he died in at the grave's time (live 2026-11-02: the Goblin Warrior grave said "none known")
do
    local m = { history = { ["goblin warrior"] = { { at = 1000, outcome = "died", killed_by = "Goblin Warrior" } },
                            ["giant rat"] = { { at = 1003, outcome = "killed" } } } }
    local k = Cm.killed_at(1001.2, m)
    check("killed_at: the fight he died in near the grave's time", k and k.creature == "goblin warrior" and k.killed_by == "Goblin Warrior", k and k.creature)
    check("killed_at: nothing 2 min off", Cm.killed_at(1200, m) == nil)
    local F = { target_name = "Goblin Runt", last_hit_by = "Goblin Archer", kills = 0 }
    local mem = { history = {} }
    Cm.record_fight(mem, F, { ok = false, reason = "companion_down", data = { died = true } })
    check("record_fight: a death names who hit him last", mem.history["goblin runt"][1].killed_by == "Goblin Archer")
end


-- weapons_known names the slotted arrows and the other arrows he carries (live 2026-11-02 03:47)
do
    local list = { loadout = { { item = "ITEM_Shortbow_Wood", name = "Ash Shortbow", loadout_slot = "HeldRight" },
                               { item = "ITEM_Ammo_Arrows_Stone_Bodkin", name = "Stone Arrow", count = 2, loadout_slot = "Ammo" } },
                   bag = { { item = "ITEM_Ammo_Arrows_Stone_Bodkin", name = "Stone Arrow", count = 2, slot_type = "Ammo" },
                           { item = "ITEM_Ammo_Arrows_Bone_Bodkin", name = "Fang Arrow", count = 33, slot_type = "Ammo" },
                           { item = "ITEM_Ammo_Bolts_Bone", name = "Bone Bolts", count = 10, slot_type = "Ammo" } } }
    local wk = Cm.weapons_known(list)
    local b = wk["Ash Shortbow"] or {}
    check("weapons_known: the slotted arrows by name", b.ammo == 2 and b.ammo_name == "Stone Arrow", b.ammo_name)
    check("weapons_known: the other arrows he carries (not bolts, not the slotted stack)", b.ammo_carried and #b.ammo_carried == 1
        and b.ammo_carried[1].name == "Fang Arrow" and b.ammo_carried[1].count == 33, b.ammo_carried and #b.ammo_carried)
end

-- an empty ammo slot says what is in the bag instead
do
    local list = { loadout = { { item = "ITEM_Shortbow_Wood", name = "Ash Shortbow", loadout_slot = "HeldRight" } },
                   bag = { { item = "ITEM_Ammo_Arrows_Bone_Bodkin", name = "Fang Arrow", count = 33, slot_type = "Ammo" } } }
    local w = Cm._ammo_words_for_list and Cm._ammo_words_for_list("no_ammo", { name = "Ash Shortbow", cat = "bow" }, list)
    check("ammo_words: names the arrows in the bag", w and w:find("33 Fang Arrow are in my bag", 1, true) ~= nil, w)
    local w2 = Cm._ammo_words_for_list and Cm._ammo_words_for_list("no_ammo", { name = "Ash Shortbow", cat = "bow" }, { loadout = {}, bag = {} })
    check("ammo_words: none carried", w2 and w2:find("carry no arrows", 1, true) ~= nil, w2)
end

-- ================================================================ bow_ready: the draw runs from the nock (live 2026-11-02)
do
    local g = { comp = {}, seed = { full_accuracy_s = 1.25 }, aim_t0 = 10, flags = { loaded = true }, loaded_t = 9 }
    local F = { t = 11.0 }
    check("bow_ready: 1.0 s into the first draw is not ready", not Cm.bow_ready(F, g))
    F.t = 11.3
    check("bow_ready: 1.3 s into the first draw is ready", Cm.bow_ready(F, g))
    F.last_press_t = 11.3; F.t = 12.7
    check("bow_ready: after a release, no new arrow nocked yet -> not ready (the old aim start does not count)", not Cm.bow_ready(F, g))
    g.flags.loaded = false
    check("bow_ready: nothing on the bow -> not ready", not Cm.bow_ready(F, g))
    g.flags.loaded, g.loaded_t = true, 12.4
    check("bow_ready: nocked 0.3 s ago -> still drawing", not Cm.bow_ready(F, g))
    F.t = 13.7
    check("bow_ready: nocked 1.3 s ago -> ready", Cm.bow_ready(F, g))
    g.flags.loaded = nil
    F.t = 13.0
    check("bow_ready: unreadable nock -> release + nock_s + draw", not Cm.bow_ready(F, g))
    F.t = 13.9
    check("bow_ready: unreadable nock, 2.6 s after the release -> ready", Cm.bow_ready(F, g))
    g.flags = { loaded = true, aim = false }
    check("bow_ready: aim mode off (a dodge dropped it) -> not ready", not Cm.bow_ready(F, g))
    g.flags.aim, g.aim_on_t = true, 13.5
    check("bow_ready: the draw runs from when aim mode came back", not Cm.bow_ready(F, g))
    F.t = 14.8
    check("bow_ready: 1.3 s after aim came back -> ready", Cm.bow_ready(F, g))
    -- the same arrow shown on the bow all along (no nock change seen): never stuck, the usual nock time instead
    local g2 = { comp = {}, seed = { full_accuracy_s = 1.25 }, aim_t0 = 0, flags = { loaded = true, aim = true }, loaded_t = 0, aim_on_t = 0 }
    local F2 = { t = 2.0, last_press_t = 1.0 }
    check("bow_ready: no nock change seen, 1 s after the release -> not yet", not Cm.bow_ready(F2, g2))
    F2.t = 3.6
    check("bow_ready: no nock change seen, 2.6 s after the release -> ready (never a stall)", Cm.bow_ready(F2, g2))
    local g3 = { comp = {}, seed = { full_accuracy_s = 1.25 }, aim_t0 = 0, flags = { loaded = true, aim = true }, aim_on_t = 0 }
    check("bow_ready: a kebbit 3 m off -> 0.5 s of draw is enough", Cm.bow_ready({ t = 0.5, dist_m = 3 }, g3))
    check("bow_ready: 14 m off -> 0.5 s is not", not Cm.bow_ready({ t = 0.5, dist_m = 14 }, g3))
end

-- ================================================================ 22c. what he learned of a world's creatures goes with the player
-- Step trials run on a new fork of a checkpoint each. In windows s6 to s9 every trial's client said "memory ...: none
-- yet", and the first Giant Rat lunge of a trial was left unanswered as out of reach (none -> hit 14 times), though his
-- earlier characters had been hit by that lunge from 4.5 to 5.8 m. An attack's timing and reach is the creature's.
reset_world()
do
    Cm.cfg.memory_enabled = true
    local dir = Cm.cfg.memory_root .. "/data/skills/shockbyte"
    local kpath = dir .. "/combat_knowledge.json"
    local function clean()
        for _, n in ipairs({ "combat_memory_BP_PlayerCharacter_C_1", "combat_memory_ClaudeFork", "combat_memory_ClaudeFork2", "combat_knowledge" }) do
            for _, s in ipairs({ ".json", ".json.bak", ".json.tmp" }) do os.remove(dir .. "/" .. n .. s) end
        end
    end
    local function restart() _G.DWCombat, _G.DWDefense, _G.DWRanged = nil, nil, nil end
    local function as(name) pawn.PlayerState = name and { IsValid = function() return true end, GetPlayerName = function() return name end } or nil end
    local key = "Giant Rat:ATK_GiantRat_Attack_01"
    local fixed = function() return 0.5 end
    local function lunge()
        return Dm.plan({ key = key, dmg_time = 1.08 }, { dist_cm = 650, latency_s = 0.03, stamina = 60, can_block = true, block_cost = 10,
                                                        evade_cost = 15, hp_frac = 1, heal_hp = 0.5 }, {}, fixed)
    end
    clean(); restart()
    Cm.memory(nil, pawn)
    check("knowledge: an attack never met, 6.5 m off, is taken to be out of reach", lunge().why == "out_of_reach", lunge().why)
    local r = Dm.rec(key); r.n, r.impact_s, r.hit_from_cm = 3, 1.08, 575 -- (he was hit by it from 5.75 m)
    r.arms = { dodge = { s = 18, f = 4, n = 22 } } -- (and without a shield the roll was his only answer)
    Cm.memory_save(nil)
    -- another character of his in the same world
    restart(); as("ClaudeFork")
    local lines = {}
    local m = Cm.memory(function(l) lines[#lines + 1] = l end, pawn)
    local a = Dm.status().attacks[key]
    check("knowledge: a new character has no memory of its own", m.status == "new" and m.char == "ClaudeFork", tostring(m.status) .. " " .. tostring(m.char))
    check("knowledge: but knows the attack another character of his learned", a and a.hit_from_cm == 575 and a.impact_s == 1.08, a and a.hit_from_cm)
    check("knowledge: and the log says so", table.concat(lines, " | "):find("1 attacks added from what his characters learned in this world", 1, true) ~= nil,
        table.concat(lines, " | "))
    check("knowledge: so that lunge from 6.5 m is answered", lunge().action ~= "none", tostring(lunge().action) .. " " .. tostring(lunge().why))
    -- which answer works is the character's own (what he holds, how he fights): window s11's forks took over "dodge
    -- 18 of 22" from characters without a shield, rolled 18 of 28 attacks and ran out of stamina
    check("knowledge: which answer worked for another character does not come with it", a and (a.arms == nil or a.arms.dodge == nil or a.arms.dodge.n == 0), a and a.arms and a.arms.dodge and a.arms.dodge.n)
    do
        local f = io.open(kpath, "rb"); local txt = f and f:read("a") or ""; if f then f:close() end
        check("knowledge: the file holds the creature's facts only", txt:find('"hit_from_cm"', 1, true) ~= nil and txt:find('"arms"', 1, true) == nil, txt:sub(1, 200))
    end
    Dm.rec(key).arms = { parry = { s = 2, f = 0, n = 2 } }
    -- what the second character learns reaches the first
    Dm.rec(key).n, Dm.rec(key).hit_from_cm = 5, 600
    Cm.memory_save(nil)
    restart(); as(nil)
    local m1 = Cm.memory(nil, pawn)
    check("knowledge: what the second learned reaches the first", m1.status == "loaded" and Dm.status().attacks[key].hit_from_cm == 600,
        tostring(m1.status) .. " " .. tostring(Dm.status().attacks[key].hit_from_cm))
    local own = Dm.status().attacks[key].arms or {}
    check("knowledge: and the first keeps his own record of which answer works", own.dodge and own.dodge.s == 18 and own.parry == nil,
        tostring(own.dodge and own.dodge.s) .. " " .. tostring(own.parry and own.parry.s))
    -- another build's timings are not trusted; a file that does not read is tolerated
    local f = io.open(kpath, "rb"); local txt = f:read("a"); f:close()
    f = io.open(kpath, "wb"); f:write((txt:gsub("TESTBUILD", "OLD1"))); f:close()
    restart(); as("ClaudeFork2")
    Cm.memory(nil, pawn)
    check("knowledge: another build's is not used", Dm.status().attacks[key] == nil)
    f = io.open(kpath, "wb"); f:write("{nope"); f:close()
    restart()
    local m2 = Cm.memory(nil, pawn)
    check("knowledge: a file that does not read is tolerated", m2.status == "new" and Dm.status().attacks[key] == nil, m2.status)
    Cm.memory_save(nil)
    f = io.open(kpath, "rb"); txt = f and f:read("a") or ""; if f then f:close() end
    check("knowledge: and the next save writes a whole one", txt:find('"build":"TESTBUILD"', 1, true) ~= nil or txt:find('"build": "TESTBUILD"', 1, true) ~= nil, txt:sub(1, 120))
    clean(); as(nil)
    Cm.cfg.memory_enabled = false
    restart()
    A.reset(nil)
end

-- ================================================================ a block faces where the camera looks
-- Live probe block_face_probe 2026-11-17 (ClaudeDev): with the camera 120 deg off his body, the block key turned his
-- body to the camera's yaw within 12 frames (nothing for ~3 frames, then 540 deg/s). In fights the camera pointed where
-- he last walked or dodged: over 2026-11-15/16 block -> hit 4 of 7 (once 0.8 s into the block), parry -> hit 12 of 53.
do -- the plan: he has to face it by the impact. The turn fits in a parry's lead only from a small angle
    _G.DWDefense = nil
    local fixed = function() return 0.5 end
    local function ctxf(face, over)
        local c = { dist_cm = 150, latency_s = 0.03, stamina = 60, can_parry = true, can_block = true, parry_cost = 10, block_cost = 10,
                    evade_cost = 15, hp_frac = 1, heal_hp = 0.5, face_deg = face }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    local info = { key = "GoblinF:ATK_Slash", dmg_time = 0.8 }
    check("face: facing it -> parry", Dm.plan(info, ctxf(10), {}, fixed).action == "parry")
    check("face: 70 deg off -> the turn fits in the parry's lead", Dm.plan(info, ctxf(70), {}, fixed).action == "parry")
    check("face: facing unread -> the rule as it was", Dm.plan(info, ctxf(nil), {}, fixed).action == "parry")
    local p = Dm.plan(info, ctxf(150), {}, fixed)
    check("face: 150 deg off -> a block pressed at once, and it says why", p.action == "block" and p.why == "facing_away" and p.at_s < 0.3
        and math.abs((p.turn_s or 0) - (0.1 + 105 / 540)) < 1e-6, tostring(p.action) .. " " .. tostring(p.why) .. " " .. tostring(p.turn_s))
    local q = Dm.plan({ key = "RatF:Bite", dmg_time = 0.45 }, ctxf(180), {}, fixed)
    check("face: behind him and 0.45 s to the bite -> no block can face it in time: a dodge", q.action == "dodge" and q.why == "facing_away",
        tostring(q.action) .. " " .. tostring(q.why))
    local n = Dm.plan({ key = "RatF:Bite", dmg_time = 0.45 }, ctxf(180, { stamina = 12 }), {}, fixed)
    check("face: the same with no stamina for a dodge -> the block all the same", n.action == "block", n.action)
    check("face: a wider block angle on his own component is used", Dm.plan(info, ctxf(150, { block_angle = 300 }), {}, fixed).action == "parry")
    local far = Dm.plan(info, ctxf(0, { dist_cm = 900 }), {}, fixed)
    check("reach: an unanswered telegraph carries the reach it was judged by", far.action == "none" and far.why == "out_of_reach"
        and far.reach_cm and far.reach_cm < 900, tostring(far.action) .. " " .. tostring(far.reach_cm))
end
reset_world()
do -- the fight: the one behind him swings; the camera goes on it, the block turns him, the hit is blocked
    PERKS.unlocked = { PerkV2_Attack_Parry = true }
    Cm.set_orders({ defense = "auto" })
    pc.SetControlRotation = function(_, r) world.ctrl_rot = { Pitch = r.Pitch, Yaw = r.Yaw } end
    for _, case in ipairs({ { name = "turns", turn = true, want = "blocked" }, { name = "the turn fails", turn = false, want = "hit" } }) do
        held.right, held.left = "ITEM_Dagger_Bone", "ITEM_Shield_Bronze"
        pawn.yaw = 0
        local gob = new_creature("BP_AI_RuntGoblin_Character_C_front" .. (case.turn and "1" or "2"), "Goblin Runt", { X = 150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
        local rat = new_creature("BP_AI_GiantRat_C_behind" .. (case.turn and "1" or "2"), "Giant Rat", { X = -150, Y = 0, Z = 0 }, { hp = 5000, pl = 1, arch = 0 })
        check("face fight (" .. case.name .. "): starts", Cm._start_fight(nil, gob, { mode = "attack", force = true }).ok)
        run_until(function() local f = Cm._state().fight; return f and f.phase == "engage" end, 3)
        pawn.yaw, world.ctrl_rot = 0, nil
        world.resolved, world.result = nil, nil
        goblin_attack(rat, 0.8)
        local resolve = world.on_step
        local PLAIN, POINT = "/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect",
            "/Script/Dominion.DamageComponent:Multicast_ApplyPointDamageFromGameplayEffect"
        world.on_step = function()
            local blocking = world.block_last and T - world.block_last < 0.05
            -- the game's own rule: a held block turns the body to the camera; a hit from outside the block's angle is not blocked
            if blocking and world.ctrl_rot and case.turn then pawn.yaw = world.ctrl_rot.Yaw end
            local want = math.deg(math.atan(rat.loc.Y - pawn.loc.Y, rat.loc.X - pawn.loc.X))
            local off = math.abs((want - pawn.yaw + 540) % 360 - 180)
            if off > 60 and not world.resolved then
                -- the hit comes as a point hit with the server's verdict on the block in it
                local keep, plain = world.block_last, hooks[PLAIN]
                world.block_last = nil
                hooks[PLAIN] = function(c, ev)
                    local e = ev:get()
                    e.BlockOutcome, e.DamageBlocked = { Result = 0, bWasBlockableAttack = true }, 0
                    hooks[POINT](c, { get = function() return e end })
                end
                resolve()
                hooks[PLAIN] = plain
                world.block_last = keep
                return
            end
            resolve()
        end
        run_until(function() local f = Cm._state().fight; return world.resolved and f and f.phase ~= "defend" end, 3)
        local f = Cm._state().fight
        local ld = f and f.last_defence or {}
        local lines = table.concat(Cm._state().log_lines, " | ")
        check("face fight (" .. case.name .. "): the camera went on the one that swung, behind him", world.ctrl_rot and math.abs(math.abs(world.ctrl_rot.Yaw) - 180) < 1,
            world.ctrl_rot and world.ctrl_rot.Yaw)
        check("face fight (" .. case.name .. "): a block, not a parry, with the reason", ld.action == "block" and ld.why == "facing_away", tostring(ld.action) .. " " .. tostring(ld.why))
        check("face fight (" .. case.name .. "): " .. case.want, world.result == case.want and ld.outcome == case.want, tostring(world.result) .. " " .. tostring(ld.outcome))
        check("face fight (" .. case.name .. "): the line says how far he was turned from it at the key",
            lines:find("turned 180 deg from it at the key", 1, true) ~= nil, lines:sub(-400))
        if case.want == "hit" then
            check("face fight: a hit through a block says where he faced and the server's verdict",
                lines:find("180 deg at the hit", 1, true) ~= nil and lines:find("the server: not blocking", 1, true) ~= nil, lines:sub(-400))
        else
            check("face fight: no damage taken", pawn.hp == 100, pawn.hp)
        end
        -- back in the fight: a swing goes where the camera looks too (live probe swing_face_probe 2026-11-17), so the
        -- camera returns to the one he swings at. Window s9: 8 swings went 84 to 168 deg off the target after such a block
        run_until(function() return world.ctrl_rot and math.abs(world.ctrl_rot.Yaw) < 1 end, 2)
        check("face fight (" .. case.name .. "): the camera is back on the one he swings at", world.ctrl_rot and math.abs(world.ctrl_rot.Yaw) < 1,
            world.ctrl_rot and world.ctrl_rot.Yaw)
        if case.want == "hit" then
            check("face fight: the hit names the damage event that carried it", lines:find("a point hit", 1, true) ~= nil, lines:sub(-300))
        end
        Cm.stop(nil, "test")
        A.reset(nil)
        reset_world()
    end
    pc.SetControlRotation = nil
    PERKS.unlocked = {}
end

print(string.format("combat/arbiter tests: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
