-- combat: Claude fights (or runs) like a player, on his own CLIENT (route R2). Real player paths only:
--   * attack / special / block = Enhanced Input injection of the pawn's own input-buffer actions
--     (pawn.PlayerInputBufferInputActions: IA_PrimaryAction, IA_SpecialAction, IA_SecondaryAction;
--     Boolean, InputTriggerDown) through EnhancedInputLocalPlayerSubsystem:InjectInputVectorForAction
--     (the FVector variant; FInputActionValue has no reflected fields, DISCOVERIES R2 locomotion);
--   * dodge = IA_Player_Evade (EvadeAction; directional when movement input is given the same frames);
--   * lock-on = the pawn's LockOnTargetingComponent.ToggleLockOnInput (IA_ToggleLockOnTargeting,
--     InputTriggerPressed: one frame, then released);
--   * weapon swap = the hotbar number key (inventory.equip); loot = the interact key (inventory);
--   * movement = move.lua's public API only (follow/go_to/stop), through the control arbiter.
-- Never calls server RPCs, never emulates damage; outcomes are verified from replicated state
-- (stamina spent per swing, the server's damage multicasts on the target, target HP / IsDead).
--
-- Design (search-before-building, DISCOVERIES "Client combat (R2)"):
--   * fight-or-flight = a small utility function (time-to-kill comparison, gamedev.net "help me
--     understand utility AI"; Infinite Axis-style response curves) gated by hard vetoes (boss,
--     power-level gap, outnumbered, low HP) and hysteresis;
--   * reactive priority logic re-evaluated every decision tick (the legacy server combat.lua used
--     beehive selectors the same way; here the priorities are an ordered list per phase);
--   * engage loop shape = mineflayer-pvp (follow range + attack range + view distance);
--   * human-like: 150-300 ms reaction delay, jittered press cadence from the weapon's own montage
--     timing (input window end, tools/gen_weapon_profiles.py), stamina reserve kept for defence.
--
-- Entry points (log = DWClient text logger):
--   M.attack(log, target, opts)       commanded fight (level "command"): target = entity id / name
--   M.guard_start(log, opts)          the reflex: threat watch -> fight or flee (level "reflex")
--   M.guard_stop(log)  M.stop(log, why)  M.status()  M.set_orders(t)  M.hooks_start(log)
--   M.HANDLERS = {attack, combat_status, combat_orders}  (bridge module handlers)
-- Pure, offline-tested: M.score_weapon, M.best_weapon, M.assess, M.pick_threats, M.learn_outcome.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    guard_period_ms = 300,
    aggro_m = 14,            -- reflex: hostiles closer than this are threats (Aggressive + in combat)
    assist_m = 20,           -- reflex: defend the protected player against attackers this close to us
    attacker_memory_s = 6,   -- an attacker stays a threat this long after its last hit
    reach_m = 2.2,           -- melee range (dagger/sword wedge depth ~1.1-1.7 m + capsules)
    follow_m = 1.6,          -- follow distance while engaged
    react_ms = { 150, 300 }, -- human reaction delay before the first action and before defending
    press_jitter_ms = { 40, 200 },
    tap_frames = 3,          -- a key tap = this many frames of injection (~30 ms at 100 Hz)
    stamina_reserve = 20,    -- keep this much stamina for a block or a dodge
    flee_hp = 0.35,          -- hard veto: below this HP fraction, flee
    eat_hp = 0.55,           -- while fleeing / after a fight: eat food that heals below this
    fight_enter = 0.5,       -- utility to start fighting / to keep fighting (hysteresis)
    fight_stay = 0.4,
    pl_gap_flee = 2,         -- enemy power level - mine >= this: too strong (Claude is level 1)
    max_hostiles = 2,        -- more simultaneous hostiles than this: flee
    lost_m = 40, lost_s = 5, -- target farther than lost_m for lost_s: give up
    fight_timeout_s = 120,
    special_hp_factor = 2,   -- use the special only on targets with >= this many normal swings of HP
    special_gap_s = 6,
    telegraph_m = 6, telegraph_fresh_s = 1.0,
    block_hold_s = 0.9,      -- MinimumBlockDuration 0.75 s on Claude's PlayerBlockingComponent
    block_stamina = 15, evade_stamina = 15,
    lock_on = true,
    nudge = true,            -- turn the body toward the target with a short movement nudge when standing
    face_err_deg = 35,
    loot = true, loot_radius_m = 7, loot_s = 20, loot_max = 6, loot_wait_s = 0.8,
    safe_m = 22, safe_s = 4, flee_timeout_s = 45, flee_far_m = 30,
    protect = "Zezima",      -- Luis's character on the Shockbyte world
    verify_presses = 6,      -- this many presses with no stamina drop and no hit -> the input is not reaching the game
}

-- Standing orders (the brain / Luis can change them: combat_orders):
--   stance: "defensive" (fight what attacks him or the protected player, when winnable),
--           "aggressive" (also engage Aggressive hostiles that come near),
--           "passive" (never start a fight by reflex; flee when attacked), "flee" (always flee).
--   avoid:  {name=true} creatures never to fight; force: commanded attacks ignore the vetoes.
M.orders = { stance = "defensive", avoid = {}, force = false }

-- Provisional weakness priors by creature name (docs/research/2026-10-25-spells-and-weaknesses.md;
-- wiki/gamever, MEDIUM confidence). Live DamageTypeAffinities (empty on the client for Kebbits) and
-- learned hit outcomes override these.
M.PRIORS = {
    goblin = { weak = { ["DamageType.Magical.Fire"] = true } },
    kalphite = { resist = { ["DamageType.Physical.Crush"] = true, ["DamageType.Physical.Slash"] = true,
                            ["DamageType.Physical.Stab"] = true, ["DamageType.Ranged"] = true } },
}
M.TOOL_FACTOR = { axe = 0.6, pickaxe = 0.6, spade = 0.3, torch = 0, fishing_rod = 0, fishingnet = 0,
                  container = 0, harvest_tool = 0, farming = 0, animaorb = 0 }
M.AFFINITY = { [0] = "weak", "resist", "immune" } -- EDamageTypeAffinity
M.OUTCOME = { [0] = "neutral", "weak", "resist", "immune" } -- ETypeDamageOutcome

-- ------------------------------------------------------------------ state (hot-reload safe)
local function C()
    local c = _G.DWCombat
    if not c then
        c = { gen = 0, hooks = {}, attackers = {}, ally_attackers = {}, telegraphs = {}, my_hits = {},
              learned = {}, taken = {}, counts = { fights = 0, flees = 0, kills = 0, presses = 0, hits = 0,
              telegraphs = 0, blocks = 0, evades = 0, loot = 0 }, last = nil, log_lines = {} }
        _G.DWCombat = c
    end
    c.orders = c.orders or M.orders
    c.cfg_over = c.cfg_over or {}
    return c
end
M._state = C
-- Orders and cfg overrides live in _G (every loadfile instance of this module shares them).
do
    local c = C()
    M.orders = c.orders
    for k, v in pairs(c.cfg_over) do M.cfg[k] = v end
end

local GS
function M.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
local now = M.now
local rnd = math.random
local function jitter(r) return (r[1] + rnd() * (r[2] - r[1])) / 1000 end
M.react_delay = function() return jitter(M.cfg.react_ms) end

local function say(log, msg)
    if log then pcall(log, "combat: " .. msg) end
    local c = C()
    c.log_lines[#c.log_lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.log_lines > 40 then table.remove(c.log_lines, 1) end
end

-- ------------------------------------------------------------------ sibling modules (loadfile, injectable)
M.mods = {}
function M.set_modules(t) for k, v in pairs(t) do M.mods[k] = v end end
local function mod(name)
    if not M.mods[name] then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/" .. name .. ".lua"))() end)
        if ok then M.mods[name] = m end
    end
    return M.mods[name]
end
local function mcall(name, fn, ...)
    local m = mod(name)
    if not (m and m[fn]) then return nil, "no " .. name .. "." .. fn end
    local ok, r = pcall(m[fn], ...)
    if not ok then return nil, tostring(r) end
    return r
end

local WEAPONS
function M.weapons()
    if not WEAPONS then
        local ok, d = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/weapons_data.lua"))() end)
        WEAPONS = ok and d or { items = {} }
    end
    return WEAPONS
end
function M.set_weapons(d) WEAPONS = d end

-- ------------------------------------------------------------------ pure decision functions
-- Damage per second of a weapon profile's primary chain (catalog damage / press cadence).
function M.dps(p)
    local pr = p and p.prim
    if not (pr and pr.dmg and pr.next_ms and pr.next_ms > 0) then return nil end
    return pr.dmg / (pr.next_ms / 1000)
end

-- Affinity of an enemy to a damage type tag: "weak" | "resist" | "immune" | nil.
-- Sources, strongest first: learned hit outcomes, live affinities, name priors.
function M.affinity(enemy, tag, learned)
    local name = enemy and (enemy.name or ""):lower() or ""
    local l = learned and learned[name]
    if l and l[tag] and l[tag] ~= "neutral" then return l[tag] end
    if l and l[tag] == "neutral" then return nil end
    local live = enemy and enemy.affinities
    if live and live[tag] then return live[tag] end
    for key, pr in pairs(M.PRIORS) do
        if name:find(key, 1, true) then
            if pr.weak and pr.weak[tag] then return "weak" end
            if pr.resist and pr.resist[tag] then return "resist" end
            if pr.immune and pr.immune[tag] then return "immune" end
        end
    end
    return nil
end

-- Score of a weapon profile against an enemy (higher = better). nil = not a usable melee weapon.
-- Ranged/magic weapons need ammo/runes and aiming: not used by the reflex yet.
function M.score_weapon(p, enemy, learned)
    if not p or p.kind ~= "melee" or not p.prim then return nil end
    local f = M.TOOL_FACTOR[p.cat]
    if f == 0 then return nil end
    local s = (M.dps(p) or 0) * (f or 1)
    for _, tag in ipairs(p.types or {}) do
        local a = M.affinity(enemy, tag, learned)
        if a == "weak" then s = s * 1.5 elseif a == "resist" then s = s * 0.6 elseif a == "immune" then s = s * 0.05 end
    end
    return s
end

-- Best weapon he OWNS (inventory.list entries: hotbar, bag, loadout) for this enemy, and the best
-- shield. -> {weapon = {entry, profile, score}, shield = {entry, profile}} (nil when none).
function M.best_weapon(list, enemy, data, learned)
    data = data or M.weapons()
    local items = data.items or {}
    local best, shield
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            local p = e.item and items[e.item]
            if p and not e.broken then
                local s = M.score_weapon(p, enemy, learned)
                if s and (not best or s > best.score + 1e-6) then best = { entry = e, profile = p, score = s, where = where } end
                if p.role == "shield" and (not shield or (p.block or 0) > (shield.profile.block or 0)) then
                    shield = { entry = e, profile = p, where = where }
                end
            end
        end
    end
    return { weapon = best, shield = shield }
end

-- Prior damage per second of an enemy we have not seen hit yet, from its power level.
function M.enemy_dps_prior(pl) return 2 + 2 * math.max(pl or 1, 0) end

-- Fight or flight. me = {hp, max_hp, pl, dps}; enemies = {{name, hp, max_hp, pl, boss, dps_obs}};
-- orders = M.orders; current = "fight"|"flee"|nil (hysteresis). -> {decision, u_fight, why, ...}
function M.assess(me, enemies, orders, current, cfg)
    cfg = cfg or M.cfg
    orders = orders or M.orders
    local r = { decision = "fight", u_fight = 1 }
    local hp_frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1
    r.hp_frac = hp_frac
    local function veto(why) r.decision, r.u_fight, r.why = "flee", 0, why; return r end
    if orders.stance == "flee" then return veto("orders") end
    if #enemies == 0 then r.decision, r.why = "none", "no_enemies"; return r end
    local my_pl = me.pl or 1
    local worst_gap, total_hp, their_dps = -99, 0, 0
    for _, e in ipairs(enemies) do
        if e.boss and not orders.force then return veto("boss") end
        local gap = (e.pl or 1) - my_pl
        if gap > worst_gap then worst_gap = gap end
        total_hp = total_hp + math.max(e.hp or e.max_hp or 50, 1)
        local d = e.dps_obs or M.enemy_dps_prior(e.pl)
        their_dps = their_dps + d * (1.25 ^ gap)
    end
    r.pl_gap = worst_gap
    if not orders.force then
        if worst_gap >= cfg.pl_gap_flee then return veto("too_strong") end
        if #enemies > cfg.max_hostiles then return veto("outnumbered") end
        if hp_frac < cfg.flee_hp then return veto("low_hp") end
    end
    local my_dps = math.max((me.dps or 5) * (1.25 ^ (-worst_gap)), 0.1)
    r.my_ttk = total_hp / my_dps
    r.their_ttk = (me.hp or 1) / math.max(their_dps, 0.1)
    local ratio = r.their_ttk / math.max(r.my_ttk, 0.1)
    local u_ratio = ratio / (ratio + 1)                         -- 0.5 when even
    local u_hp = math.sqrt(math.max(0, math.min(1, (hp_frac - cfg.flee_hp) / (1 - cfg.flee_hp))))
    r.u_fight = u_ratio * (0.6 + 0.4 * u_hp)
    if orders.force then r.decision, r.why = "fight", "forced"; return r end
    local need = current == "fight" and cfg.fight_stay or cfg.fight_enter
    r.decision = r.u_fight >= need and "fight" or "flee"
    r.why = r.decision == "fight" and "winnable" or "losing"
    return r
end

-- Which nearby creatures are threats right now. creatures = list of read_creature() tables with
-- distance_m; attackers/ally_attackers = {id = last hit time}; t = now. -> sorted threat list.
function M.pick_threats(creatures, attackers, ally_attackers, orders, t, cfg)
    cfg = cfg or M.cfg
    orders = orders or M.orders
    local out = {}
    for _, c in ipairs(creatures or {}) do
        if not c.dead and not c.follower and not (orders.avoid or {})[(c.name or ""):lower()] then
            local why
            local hit = attackers and attackers[c.id]
            local ally = ally_attackers and ally_attackers[c.id]
            if hit and t - hit <= cfg.attacker_memory_s then why = "attacked_me"
            elseif ally and t - ally <= cfg.attacker_memory_s and (c.distance_m or 99) <= cfg.assist_m then why = "attacked_ally"
            elseif c.archetype == 0 and c.in_combat and (c.distance_m or 99) <= cfg.aggro_m then why = "hostile_near"
            elseif orders.stance == "aggressive" and c.archetype == 0 and (c.distance_m or 99) <= cfg.aggro_m then why = "hostile_near" end
            if why then
                local d = {}
                for k, v in pairs(c) do d[k] = v end
                d.why = why
                d.rank = (why == "attacked_me" and 0 or why == "attacked_ally" and 1 or 2) * 1000 + (c.distance_m or 99)
                out[#out + 1] = d
            end
        end
    end
    table.sort(out, function(a, b) return a.rank < b.rank end)
    return out
end

-- Learn a damage-type outcome from one of our hits: learned[name][tag] = weak|resist|immune|neutral.
function M.learn_outcome(learned, name, types, outcomes)
    if not (name and types and outcomes) then return end
    local key = name:lower()
    learned[key] = learned[key] or {}
    for i, tag in ipairs(types) do
        local o = outcomes[i]
        if o then learned[key][tag] = o end
    end
end

-- ------------------------------------------------------------------ game reads
local function local_pc()
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then return pc end
    end
end
M.local_pc = local_pc

local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end

local function read_creature(a, origin)
    local data = U.try(function() return a.LoadedData end)
    local at = U.loc(a)
    local hp = num(U.health(a))
    local d = {
        id = U.short(a), actor = a, pos = at,
        name = (U.valid(data) and text(U.try(function() return data.AIName end))) or U.short(a),
        hp = hp, max_hp = num(U.try(function() return a.HealthComponent:GetMaxHealth() end)),
        pl = num(U.try(function() return a.PowerLevel end)),
        archetype = U.valid(data) and num(U.try(function() return data.Archetype end)) or nil,
        boss = U.valid(data) and U.try(function() return data.bIsBoss end) == true or nil,
        follower = U.try(function() return a:IsFollower() end) == true or nil,
    }
    d.dead = U.try(function() return a.HealthComponent:IsDead() end) == true or (hp ~= nil and hp <= 0)
    local al = num(U.try(function() return a.CurrentAlertnessState end))
    d.in_combat = al == 3 or al == 4
    if origin and at then d.distance_m = U.dist(origin, at) / 100 end
    return d
end
M.read_creature = read_creature

-- Live damage-type affinities (TMap<GameplayTag, EDamageTypeAffinity>); empty on the client so far.
local function read_affinities(a)
    local out
    pcall(function()
        a.AIAttributesComponent.DamageTypeAffinities:ForEach(function(k, v)
            local tag = U.str(U.try(function() return k:get().TagName end))
            local aff = M.AFFINITY[U.try(function() return v:get() end)]
            if tag and aff then out = out or {}; out[tag] = aff end
        end)
    end)
    return out
end

local function creatures_near(origin, radius_m)
    local out = {}
    for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
        local at = U.loc(a)
        if at and origin and U.dist(origin, at) <= radius_m * 100 then
            local ok, d = pcall(read_creature, a, origin)
            if ok and d then out[#out + 1] = d end
        end
    end
    return out
end
M.creatures_near = creatures_near

local function find_creature(id)
    for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
        if U.short(a) == id then return a end
    end
end

-- Resolve an attack target: entity id, or a creature name (nearest live one within 40 m).
function M.resolve_target(target, origin)
    if type(target) == "userdata" or type(target) == "table" and target.IsValid then return target end
    if type(target) ~= "string" or target == "" then return nil end
    local a = find_creature(target)
    if a then return a end
    local want, best, bd = target:lower(), nil, math.huge
    for _, c in ipairs(creatures_near(origin, 40)) do
        if not c.dead and (c.name or ""):lower():find(want, 1, true) and c.distance_m < bd then best, bd = c.actor, c.distance_m end
    end
    return best
end

local function read_me(pawn, pc)
    local d = { hp = num(U.health(pawn)), max_hp = num(U.try(function() return pawn.HealthComponent:GetMaxHealth() end)) }
    local st = U.try(function() return pawn.StaminaComponent end)
    if U.valid(st) then d.stamina = num(U.try(function() return st:GetStamina() end)); d.max_stamina = num(U.try(function() return st:GetMaxStamina() end)) end
    local sc = U.try(function() return pawn.SpecialChargeComponent end)
    if U.valid(sc) then d.special = num(U.try(function() return sc:GetSpecialCharge() end)) end
    -- BP_GetPowerLevel is a Blueprint event (it may touch gear data): read it at most every 10 s
    local c = C()
    local t = os.time()
    if not c.pl_t or t - c.pl_t >= 10 or c.pl_pawn ~= U.short(pawn) then
        c.pl = num(U.try(function() return pawn:BP_GetPowerLevel() end)) or c.pl or 1
        c.pl_t, c.pl_pawn = t, U.short(pawn)
    end
    d.pl = c.pl
    d.dead = U.try(function() return pawn.HealthComponent:IsDead() end) == true
    d.pos = U.loc(pawn)
    return d
end
M.read_me = read_me

-- The pawn's own combat input actions (cached per pawn).
local function actions(pawn)
    local c = C()
    local id = U.short(pawn)
    if c.actions and c.actions.pawn == id then return c.actions end
    local acts = U.try(function() return pawn.PlayerInputBufferInputActions end)
    local function get(k) local a = acts and U.try(function() return acts[k] end); return U.valid(a) and a or nil end
    local lo = U.try(function() return pawn.LockOnTargetingComponent end)
    c.actions = { pawn = id, primary = get("PrimaryAction"), secondary = get("SecondaryAction"), special = get("SpecialAction"),
                  evade = get("EvadeAction"), lock = U.valid(lo) and U.try(function() return lo.ToggleLockOnInput end) or nil }
    return c.actions
end
M.actions = actions

local function eis()
    local c = C()
    if not (c.eis and U.valid(c.eis)) then c.eis = U.find_first("EnhancedInputLocalPlayerSubsystem") end
    return c.eis
end

local function inject(action)
    local s = eis()
    if not (s and U.valid(action)) then return false end
    local ok = pcall(function() s:InjectInputVectorForAction(action, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    return ok
end
M._inject = inject

-- ------------------------------------------------------------------ hooks (damage + telegraphs)
-- Registered once (state in _G.DWCombat.hooks); each dispatches to the newest handler (hot reload).
M.HOOKS = {
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyPointDamageFromGameplayEffect", handler = "on_damage" },
    { path = "/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies", handler = "on_ai_attack" },
    { path = "/Script/Dominion.AiRangedAttackComponent:Multicast_PerformAttackOnSimulatedProxies", handler = "on_ai_attack" },
}

local function trim_map(m, t, keep_s)
    for k, v in pairs(m) do if t - (type(v) == "table" and v.t or v) > keep_s then m[k] = nil end end
end

-- Damage multicast: who hit whom. Read-only param reads (same reads as sense.lua's vitals watcher).
function M.on_damage(ctx, ev)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local victim = U.try(function() return comp:GetOwner() end)
    if not U.valid(victim) then return end
    local e = ev:get()
    local inst = U.try(function() return e.Instigator end)
    local vid, iid = U.short(victim), U.valid(inst) and U.short(inst) or nil
    local t = now(victim)
    local me = c.me_id
    local amount = num(U.try(function() return e.Amount end)) or 0
    -- the instigator of a player's hit may be the pawn or its controller (first live fight: hits on the
    -- target were never matched to the pawn); count both as "mine"
    local mine_i = iid ~= nil and (iid == me or iid == c.pc_id)
    local f = c.fight
    if f and vid == f.target_id then
        -- every damage event on the current target, whoever caused it (diagnostics + hit verification)
        local src = U.try(function() return e.Source end)
        c.on_target = c.on_target or {}
        c.on_target[#c.on_target + 1] = { t = t, amount = amount, inst = iid, inst_class = U.valid(inst) and U.class_word(inst) or nil,
                                          src_class = U.valid(src) and U.class_word(src) or nil, mine = mine_i }
        if #c.on_target > 12 then table.remove(c.on_target, 1) end
    end
    if vid == me and iid and not mine_i then
        c.attackers[iid] = t
        local data = U.try(function() return inst.LoadedData end)
        local name = U.valid(data) and text(U.try(function() return data.AIName end)) or iid
        local tk = c.taken[name:lower()] or { sum = 0, t0 = t, n = 0 }
        tk.sum, tk.n, tk.t = tk.sum + amount, tk.n + 1, t
        c.taken[name:lower()] = tk
    elseif mine_i and vid ~= me then
        local types, outcomes = {}, {}
        pcall(function()
            e.TypeDamagesArray.TypeDamages:ForEach(function(_, td)
                pcall(function() td:get().Types.GameplayTags:ForEach(function(_, g) types[#types + 1] = U.str(g:get().TagName) end) end)
            end)
        end)
        pcall(function() e.TypeDamagesOutcome:ForEach(function(_, o) outcomes[#outcomes + 1] = M.OUTCOME[o:get()] end) end)
        local data = U.try(function() return victim.LoadedData end)
        local name = U.valid(data) and text(U.try(function() return data.AIName end)) or vid
        local hit = { t = t, victim = vid, name = name, amount = amount, types = types, outcomes = outcomes,
                      fatal = U.try(function() return e.bIsFatalHit end) == true }
        c.counts.hits = c.counts.hits + 1
        hit.seq = c.counts.hits
        c.my_hits[#c.my_hits + 1] = hit
        if #c.my_hits > 30 then table.remove(c.my_hits, 1) end
        if #types > 0 and #outcomes > 0 then M.learn_outcome(c.learned, name, types, outcomes) end
    elseif iid and vid ~= me and U.valid(U.try(function() return victim.PlayerState end))
        and U.valid(U.try(function() return inst.LoadedData end)) then
        c.ally_attackers[iid] = t -- a creature hit another player (Luis)
    end
end

function M.on_ai_attack(ctx)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local a = U.try(function() return comp:GetOwner() end)
    if not U.valid(a) then return end
    local id = U.short(a)
    c.telegraphs[id] = now(a)
    c.counts.telegraphs = c.counts.telegraphs + 1
end

function M.hooks_start(log)
    local c = C()
    local p = mcall("inventory", "pawn")
    if p then c.me_id = U.short(p) end
    local pc0 = local_pc()
    if pc0 then c.pc_id = U.short(pc0) end
    c.handlers = { on_damage = M.on_damage, on_ai_attack = M.on_ai_attack }
    local res = {}
    for _, h in ipairs(M.HOOKS) do
        if c.hooks[h.path] then res[h.handler .. ":" .. h.path:match(":(.+)$")] = "kept"
        else
            local ok, pre, post = pcall(RegisterHook, h.path, function() end, function(...)
                local cc = _G.DWCombat
                local fn = cc and cc.handlers and cc.handlers[h.handler]
                if fn then
                    local ok2, err = pcall(fn, ...)
                    if not ok2 then cc.hook_err = tostring(err) end
                end
            end)
            if ok then c.hooks[h.path] = { pre = pre, post = post } end
            res[h.path:match("%.([%w_]+:[%w_]+)$")] = ok and "ok" or tostring(pre)
            say(log, "hook " .. h.path .. " ok=" .. tostring(ok))
        end
    end
    return { ok = true, hooks = res }
end

-- ------------------------------------------------------------------ the fight engine
-- One fight at a time, a per-frame loop (LoopInGameThreadWithDelay(1)): inputs every frame,
-- decisions every DECIDE_S. Phases: react -> equip -> approach/engage <-> defend -> loot -> restore,
-- and flee from any phase.
M.DECIDE_S = 0.1

function M.set_reach(F, actor)
    local rad = num(U.try(function() return actor.CapsuleComponent:GetScaledCapsuleRadius() end)) or 40
    local extra = math.max(0, rad - 40) / 100
    F.target_radius_cm = rad
    F.reach = M.cfg.reach_m + extra
    F.follow = M.cfg.follow_m + extra
end

local function result_of(F, ok, reason, data)
    data = data or {}
    data.target = F.target_name
    data.target_id = F.target_id
    data.presses, data.hits, data.kills = F.presses, F.hits, F.kills
    data.looted = F.looted
    data.phase_log = F.phase_log
    return { ok = ok, reason = reason, data = data }
end

local function set_phase(F, ph, why)
    if F.phase == ph then return end
    F.phase = ph
    F.phase_t = F.t
    F.phase_log[#F.phase_log + 1] = string.format("%.1f %s%s", F.t - F.t0, ph, why and (" " .. why) or "")
    if #F.phase_log > 30 then table.remove(F.phase_log, 1) end
    say(F.log, "phase " .. ph .. (why and (" (" .. why .. ")") or "") .. " target=" .. tostring(F.target_name))
end

local function tap(F, action, frames, label)
    if not action then return false end
    F.inputs[#F.inputs + 1] = { act = action, frames = frames or M.cfg.tap_frames, label = label }
    return true
end

local function finish(F, res)
    if F.done then return end
    F.done = true
    local c = C()
    if F.handle then pcall(CancelDelayedAction, F.handle) end
    F.handle = nil
    -- a lock-on on a target that is still alive is toggled off again (one frame, as a key press);
    -- a dead target releases it by itself (LockOnTargetingComponent:HandleOnCurrentTargetDied)
    if F.locked and not F.dead_seen and U.alive(F.target) then
        local pawn = F.pc and U.try(function() return F.pc.Pawn end)
        local acts = U.valid(pawn) and actions(pawn)
        if acts and acts.lock then inject(acts.lock) end
    end
    if F.drove_move then mcall("move", "stop", F.log) end
    F.result = res
    c.last = { result = res, mode = F.mode, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.fight == F then c.fight = nil end
    local arb = mod("arbiter")
    if arb and F.token then pcall(arb.release, F.log, F.token, res.ok and "done" or res.reason) end
    say(F.log, string.format("fight end ok=%s reason=%s presses=%d hits=%d", tostring(res.ok), tostring(res.reason), F.presses, F.hits))
end
M._finish = finish

local function follow_target(F, dist_m, sprint)
    if F.t - (F.follow_t or -9) < 1.0 then return F.following end -- at most one (re)start per second
    F.follow_t = F.t
    local r = mcall("move", "follow", F.log, F.target_id, dist_m, { sprint = sprint, face_when_near = true, nav = false })
    F.drove_move = true
    F.following = r and r.ok ~= false
    return F.following
end

-- Yaw error (deg) between the pawn's facing and the target.
local function face_err(pawn, me, tp)
    local rot = U.try(function() return pawn:K2_GetActorRotation() end)
    if not (rot and me and tp) then return 0 end
    local want = math.deg(math.atan(tp.Y - me.Y, tp.X - me.X))
    local e = (want - rot.Yaw + 540) % 360 - 180
    return math.abs(e), want
end

local function held_items(pawn)
    local h = mcall("inventory", "held", pawn) or {}
    return h.right_item, h.left_item
end

-- equip phase: best weapon (and a shield for a one-handed weapon) from his own inventory
local function step_equip(F, pawn)
    if not F.equip_plan then
        local list = mcall("inventory", "list", F.log) or {}
        local enemy = { name = F.target_name, affinities = F.affinities }
        local pick = M.best_weapon(list, enemy, nil, C().learned)
        F.equip_plan = { weapon = pick.weapon and pick.weapon.entry.item, shield = nil, sent = {}, t = F.t }
        if pick.weapon then
            F.profile = pick.weapon.profile
            F.weapon_score = pick.weapon.score
            if pick.shield and pick.weapon.profile.slot ~= "two_handed" then F.equip_plan.shield = pick.shield.entry.item end
        end
        F.prev_right, F.prev_left = held_items(pawn)
        -- a two-handed tool (the Mithril Logging Axe) is reported in the LEFT hand only (DISCOVERIES R2):
        -- restore whatever was the main held item
        F.prev_main = F.prev_right or F.prev_left
        say(F.log, string.format("weapon %s (score %.1f) shield %s; held before %s / %s", tostring(F.equip_plan.weapon),
            F.weapon_score or 0, tostring(F.equip_plan.shield), tostring(F.prev_right), tostring(F.prev_left)))
    end
    local plan = F.equip_plan
    local right, left = held_items(pawn)
    local need_w = plan.weapon and right ~= plan.weapon and left ~= plan.weapon
    local need_s = plan.shield and not need_w and left ~= plan.shield
    if not need_w and not need_s then return true end
    if F.t - plan.t > 4 then
        say(F.log, "equip did not confirm in 4 s; fighting with what is held")
        F.profile = (M.weapons().items or {})[right or ""] or F.profile
        return true
    end
    local want = need_w and plan.weapon or plan.shield
    if not plan.sent[want] or F.t - plan.sent[want] > 1.5 then
        plan.sent[want] = F.t
        local r = mcall("inventory", "equip", F.log, want)
        say(F.log, "equip " .. tostring(want) .. " -> " .. tostring(r and (r.via or r.reason)))
    end
    return false
end

local function enemies_for_assess(F, origin)
    local c = C()
    local list = {}
    for _, cr in ipairs(creatures_near(origin, M.cfg.assist_m)) do
        local hit = c.attackers[cr.id]
        if cr.id == F.target_id or (hit and F.t - hit <= M.cfg.attacker_memory_s) or (cr.archetype == 0 and cr.in_combat and (cr.distance_m or 99) < M.cfg.aggro_m) then
            if not cr.dead then
                local tk = c.taken[(cr.name or ""):lower()]
                if tk and tk.n >= 2 and tk.t > tk.t0 then cr.dps_obs = tk.sum / math.max(tk.t - tk.t0, 1) end
                list[#list + 1] = cr
            end
        end
    end
    return list
end

local function begin_flee(F, why)
    C().counts.flees = C().counts.flees + 1
    F.flee_why = why
    F.decision = "flee"
    F.inputs = {}
    set_phase(F, "flee", why)
    local luis = M.cfg.protect
    local r = luis and mcall("move", "follow", F.log, luis, 3, { sprint = true })
    if r and r.ok ~= false and (r.target_visible ~= false) then F.flee_to = luis
    else
        -- away from the threat
        local me, tp = F.me_pos, F.target_pos
        if me and tp then
            local dx, dy = me.X - tp.X, me.Y - tp.Y
            local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
            local g = { (me.X + dx / l * M.cfg.flee_far_m * 100) / 100, (me.Y + dy / l * M.cfg.flee_far_m * 100) / 100, me.Z / 100 }
            mcall("move", "go_to", F.log, g, { sprint = true, tolerance_m = 3, timeout_s = M.cfg.flee_timeout_s })
            F.flee_to = g
        end
    end
    F.drove_move = true
    F.safe_since = nil
end

local function try_eat(F, me)
    if not me.max_hp or me.max_hp <= 0 or (me.hp or 0) / me.max_hp >= M.cfg.eat_hp then return end
    if F.next_eat and F.t < F.next_eat then return end
    F.next_eat = F.t + 8
    local list = mcall("inventory", "list", F.log) or {}
    local pick
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do
            if e.consumable == "food" and (e.heal or 0) > 0 and (not pick or (e.heal or 0) > (pick.heal or 0)) then pick = e end
        end
    end
    pick = pick or mcall("inventory", "best_consumable", list, "food")
    if pick then
        local r = mcall("inventory", "use", F.log, pick.item)
        say(F.log, "eat " .. tostring(pick.item) .. " hp=" .. tostring(me.hp) .. " -> " .. tostring(r and (r.via or r.reason)))
        F.ate = (F.ate or 0) + 1
    end
end

local function step_flee(F, pawn, me)
    try_eat(F, me)
    local threats = 0
    for _, cr in ipairs(creatures_near(me.pos, M.cfg.safe_m)) do
        local hit = C().attackers[cr.id]
        if not cr.dead and (cr.id == F.target_id and cr.in_combat or (hit and F.t - hit <= M.cfg.attacker_memory_s)) then threats = threats + 1 end
    end
    if threats == 0 then
        F.safe_since = F.safe_since or F.t
        if F.t - F.safe_since >= M.cfg.safe_s then
            return finish(F, result_of(F, F.mode ~= "attack", F.mode == "attack" and "unsafe" or nil,
                { fled = true, why = F.flee_why, hp = me.hp }))
        end
    else F.safe_since = nil end
    if F.t - F.phase_t > M.cfg.flee_timeout_s then
        return finish(F, result_of(F, false, "unsafe", { fled = true, why = F.flee_why, still_chased = threats > 0 }))
    end
end

local function step_defend(F, pawn, me, acts)
    if F.t < (F.defend_at or 0) then return end
    if not F.defend_mode then
        local right, left = held_items(pawn)
        local items = M.weapons().items or {}
        local can_block = (left and items[left] and items[left].can_block) or (right and items[right] and items[right].can_block)
        if can_block and (me.stamina or 0) >= M.cfg.block_stamina and acts.secondary then
            F.defend_mode = "block"
            F.defend_until = F.t + M.cfg.block_hold_s
            C().counts.blocks = C().counts.blocks + 1
        elseif acts.evade and (me.stamina or 0) >= M.cfg.evade_stamina then
            F.defend_mode = "evade"
            F.defend_until = F.t + 0.5
            -- directional roll sideways (a short neutral evade keeps us close; sideways leaves the attack arc)
            local tp = F.target_pos
            if tp and me.pos then
                local dx, dy = tp.X - me.pos.X, tp.Y - me.pos.Y
                local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
                local s = rnd() < 0.5 and 1 or -1
                F.evade_dir = { X = -dy / l * s, Y = dx / l * s, Z = 0 }
            end
            tap(F, acts.evade, 4, "evade")
            C().counts.evades = C().counts.evades + 1
        else
            F.defend_mode = "none"
            F.defend_until = F.t
        end
        say(F.log, "defend: " .. F.defend_mode .. " stamina=" .. tostring(me.stamina))
    end
    if F.defend_mode == "block" and not F.hold then
        -- hold the block key: injected every frame until hold_until (IA_SecondaryAction, InputTriggerDown)
        F.hold, F.hold_until = acts.secondary, F.defend_until
    end
    if F.t >= (F.defend_until or 0) then
        F.defend_mode, F.hold, F.evade_dir = nil, nil, nil
        F.defended = (F.defended or 0) + 1
        set_phase(F, "engage", "defended")
    end
end

local function step_engage(F, pawn, me, acts, tgt)
    local cfg = M.cfg
    local d_m = F.dist_m
    -- keep in range: follow the creature (move.lua faces it when near)
    if d_m > F.reach + 0.3 and not F.following then follow_target(F, F.follow, d_m > 8) end
    -- telegraph from the target or an attacker right next to us -> defend after a human delay
    local c = C()
    for id, tt in pairs(c.telegraphs) do
        if F.t - tt <= cfg.telegraph_fresh_s and tt > (F.last_tele or 0) then
            local cr = id == F.target_id and tgt or nil
            local close = cr and d_m <= cfg.telegraph_m
            if not close then
                local a = find_creature(id)
                local p = a and U.loc(a)
                close = p and me.pos and U.dist(p, me.pos) <= cfg.telegraph_m * 100
            end
            if close then
                F.last_tele = tt
                F.defend_at = F.t + M.react_delay()
                if F.following then mcall("move", "stop", F.log); F.following = false end
                set_phase(F, "defend", "telegraph " .. id)
                return
            end
        end
    end
    if d_m > F.reach then return end
    -- lock on once (one frame of the toggle; InputTriggerPressed)
    if cfg.lock_on and not F.locked and acts.lock then
        F.locked = true
        tap(F, acts.lock, 1, "lock_on")
        F.next_press = math.max(F.next_press or 0, F.t + 0.12)
        return
    end
    -- face: a short nudge toward the target when the body points away (orient-to-movement pawn)
    local err = face_err(pawn, me.pos, F.target_pos)
    F.face_err = err
    if cfg.nudge and err > cfg.face_err_deg and F.target_pos and me.pos then
        local dx, dy = F.target_pos.X - me.pos.X, F.target_pos.Y - me.pos.Y
        local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
        F.nudge = { X = dx / l, Y = dy / l, Z = 0 }
        F.nudge_until = F.t + 0.08
    end
    if F.t < (F.next_press or 0) then return end
    -- verify the previous press: stamina spent, or a hit landed on the target
    if F.pending_press and F.t - F.pending_press.t >= 0.35 then
        local pp = F.pending_press
        F.pending_press = nil
        local spent = pp.stamina and me.stamina and me.stamina < pp.stamina - 0.5
        local hit = F.hits > pp.hits
        if spent or hit then F.verified, F.unverified_run = F.verified + 1, 0
        else F.unverified_run = F.unverified_run + 1 end
        if F.unverified_run >= cfg.verify_presses then
            return finish(F, result_of(F, false, "body_error", { detail = "attack presses had no effect (no stamina spent, no hit)" }))
        end
    end
    local prof = F.profile or {}
    local prim, spec = prof.prim or {}, prof.spec
    -- special: charge covers it, target is worth it, not too often
    if spec and spec.cost and acts.special and (me.special or 0) >= spec.cost and F.t - (F.last_special or -99) >= cfg.special_gap_s
        and (F.target_hp or 0) >= cfg.special_hp_factor * (prim.dmg or 10) then
        tap(F, acts.special, cfg.tap_frames, "special")
        F.last_special = F.t
        F.next_press = F.t + (spec.next_ms or 1200) / 1000 + jitter(cfg.press_jitter_ms)
    elseif (me.stamina or 0) >= cfg.stamina_reserve + (prim.stam or 0) and acts.primary then
        tap(F, acts.primary, cfg.tap_frames, "primary")
        F.next_press = F.t + (prim.next_ms or 900) / 1000 + jitter(cfg.press_jitter_ms)
    else
        F.next_press = F.t + 0.3 -- let stamina come back (keep the reserve for defence)
        return
    end
    F.presses = F.presses + 1
    C().counts.presses = C().counts.presses + 1
    F.pending_press = { t = F.t, stamina = me.stamina, hits = F.hits, err = err }
end

local function step_loot(F, pawn, me)
    local cfg = M.cfg
    if F.t - F.phase_t < cfg.loot_wait_s then return end
    if F.t - F.phase_t > cfg.loot_s or (F.looted or 0) >= cfg.loot_max then return set_phase(F, "restore", "loot done") end
    local inv = mod("inventory")
    -- current loot item: a world item that appeared near the kill since the fight began
    if not F.loot_item or not U.alive(F.loot_item.actor) then
        if F.loot_item then F.looted = (F.looted or 0) + 1; C().counts.loot = C().counts.loot + 1 end
        F.loot_item = nil
        local best, bd
        for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do
            local id = U.short(w)
            local p = U.loc(w)
            if id and p and not F.items_before[id] and not F.loot_skip[id] and F.death_pos and U.dist(p, F.death_pos) <= cfg.loot_radius_m * 100 then
                local d = me.pos and U.dist(p, me.pos) or 0
                if not bd or d < bd then best, bd = { actor = w, id = id, pos = p, t = F.t, presses = 0 }, d end
            end
        end
        if not best then return set_phase(F, "restore", "no loot") end
        F.loot_item = best
        mcall("move", "go_to", F.log, { best.pos.X / 100, best.pos.Y / 100, best.pos.Z / 100 }, { tolerance_m = 0.9, sprint = false, timeout_s = 10 })
        F.drove_move = true
        return
    end
    local li = F.loot_item
    if F.t - li.t > 8 or li.presses >= 3 then F.loot_skip[li.id] = true; F.loot_item = nil; return end
    local tg = inv and inv.interact_target and U.try(inv.interact_target, pawn)
    if tg and tg.actor == li.id and F.t - (li.last_press or 0) > 0.6 then
        li.last_press, li.presses = F.t, li.presses + 1
        mcall("move", "stop", F.log)
        mcall("inventory", "press_interact", F.log)
    end
end

local function step_restore(F, pawn)
    if not F.restore_sent then
        F.restore_sent = F.t
        local right, left = held_items(pawn)
        if F.prev_main and right ~= F.prev_main and left ~= F.prev_main then
            local r = mcall("inventory", "equip", F.log, F.prev_main)
            say(F.log, "re-equip " .. tostring(F.prev_main) .. " -> " .. tostring(r and (r.via or r.reason)))
        end
        return
    end
    local right, left = held_items(pawn)
    local back = F.prev_main == nil or right == F.prev_main or left == F.prev_main
    if back or F.t - F.restore_sent > 2.5 then
        return finish(F, result_of(F, true, nil, { killed = F.kills > 0, restored = (F.prev_main and back) or nil,
                                                   restored_item = F.prev_main, fled = false }))
    end
end

-- World teardown (main's crash convention): end the fight WITHOUT touching any game object.
local function abort_paused(F)
    if F.done then return end
    F.done = true
    local c = C()
    if F.handle then pcall(CancelDelayedAction, F.handle) end
    F.handle = nil
    F.result = result_of(F, false, "interrupted", { detail = "world teardown (DW_PAUSE)" })
    c.last = { result = F.result, mode = F.mode, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.fight == F then c.fight = nil end
    local arb = mod("arbiter")
    if arb and F.token then pcall(arb.release, nil, F.token, "paused") end -- pause-aware: no move calls
end

local function frame(F)
    local c = C()
    if F.gen ~= c.gen or F.done then return end
    if _G.DW_PAUSE then return abort_paused(F) end
    local pc = F.pc
    local pawn = pc and U.valid(pc) and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return finish(F, result_of(F, false, "companion_down")) end
    F.t = now(pawn)
    -- per frame: inputs + nudge/evade direction
    local keep = {}
    for _, inp in ipairs(F.inputs) do
        if inject(inp.act) then F.injected = (F.injected or 0) + 1 end
        inp.frames = inp.frames - 1
        if inp.frames > 0 then keep[#keep + 1] = inp end
    end
    F.inputs = keep
    if F.hold then
        if F.t < (F.hold_until or 0) then inject(F.hold) else F.hold = nil end
    end
    if F.evade_dir then pcall(function() pawn:AddMovementInput(F.evade_dir, 1.0, false) end)
    elseif F.nudge and F.t < (F.nudge_until or 0) then pcall(function() pawn:AddMovementInput(F.nudge, 0.3, false) end) end
    if F.t - (F.dec_t or -1) < M.DECIDE_S then return end
    F.dec_t = F.t
    -- decisions
    local arb = mod("arbiter")
    if arb and F.token then
        if not arb.holds(F.token) then return finish(F, result_of(F, false, "interrupted", { detail = "lost the pawn to a higher priority" })) end
        arb.renew(F.token)
    end
    local me = read_me(pawn, pc)
    F.me_pos = me.pos
    if me.dead then return finish(F, result_of(F, false, "companion_down", { died = true })) end
    if F.t - F.t0 > M.cfg.fight_timeout_s then return finish(F, result_of(F, false, "timeout")) end
    local acts = actions(pawn)
    if F.following then -- the follow may have ended on its own (stuck, target lost): start it again when needed
        local st = mcall("move", "status")
        if type(st) == "table" and st.mode ~= "follow" then F.following = false end
    end
    -- count our verified hits on this target (the server's damage multicasts, combat hook)
    for _, h in ipairs(c.my_hits) do
        if h.seq > F.hit_seq then
            F.hit_seq = h.seq
            if h.victim == F.target_id then
                F.hits = F.hits + 1; F.dmg = (F.dmg or 0) + (h.amount or 0); F.last_hit_t = F.t
                if h.fatal then F.fatal_hit = true end
            end
        end
    end
    local tgt = U.alive(F.target) and read_creature(F.target, me.pos) or nil
    if tgt then
        F.target_pos, F.dist_m, F.target_hp = tgt.pos, tgt.distance_m or 99, tgt.hp
        if tgt.dead and not F.dead_seen then
            F.dead_seen = true
            F.kills = F.kills + 1
            c.counts.kills = c.counts.kills + 1
            F.death_pos = tgt.pos
        end
    elseif not F.dead_seen and F.phase ~= "flee" then
        -- target actor gone (out of relevancy, or dead and despawned)
        -- a creature can vanish right after the killing blow: our fatal hit (or a hit just now) counts
        F.dead_seen = (F.target_hp ~= nil and F.target_hp <= 0) or F.fatal_hit or (F.last_hit_t ~= nil and F.t - F.last_hit_t < 2)
        F.death_pos = F.target_pos
        if not F.dead_seen then return finish(F, result_of(F, false, "unknown_target", { detail = "target no longer visible" })) end
        F.kills = F.kills + 1
    end
    if F.dead_seen and (F.phase == "engage" or F.phase == "defend" or F.phase == "approach" or F.phase == "equip") then
        -- another attacker still on us? retarget instead of looting
        local nxt = M.pick_threats(creatures_near(me.pos, M.cfg.assist_m), c.attackers, c.ally_attackers, M.orders, F.t)[1]
        if nxt and nxt.id ~= F.target_id and F.mode == "reflex" then
            say(F.log, "retarget " .. nxt.id)
            F.target, F.target_id, F.target_name, F.dead_seen, F.locked, F.following = nxt.actor, nxt.id, nxt.name, false, false, false
            M.set_reach(F, nxt.actor)
            return set_phase(F, "approach", "next attacker")
        end
        mcall("move", "stop", F.log)
        F.following = false
        if M.cfg.loot then return set_phase(F, "loot", "target dead") end
        return set_phase(F, "restore", "target dead")
    end
    -- re-assess fight or flight every 0.5 s while fighting
    if F.phase ~= "flee" and F.phase ~= "loot" and F.phase ~= "restore" and F.t - (F.assess_t or -9) >= 0.5 then
        F.assess_t = F.t
        local profile = F.profile
        local a = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = M.dps(profile) }, enemies_for_assess(F, me.pos),
            F.mode == "attack" and { stance = "defensive", force = F.force, avoid = {} } or M.orders, F.decision, M.cfg)
        F.assessment = a
        if a.decision == "flee" then return begin_flee(F, a.why) end
        F.decision = "fight"
    end
    if F.phase == "react" then
        if F.t >= F.react_until then set_phase(F, "equip") end
    elseif F.phase == "equip" then
        if step_equip(F, pawn) then set_phase(F, "approach") end
    elseif F.phase == "approach" then
        if tgt and tgt.distance_m and tgt.distance_m > M.cfg.lost_m then
            F.far_since = F.far_since or F.t
            if F.t - F.far_since > M.cfg.lost_s then return finish(F, result_of(F, false, "too_far", { dist_m = tgt.distance_m })) end
        else F.far_since = nil end
        if not F.following then follow_target(F, F.follow, (F.dist_m or 0) > 8) end
        if F.dist_m and F.dist_m <= F.reach then set_phase(F, "engage") end
    elseif F.phase == "engage" then
        step_engage(F, pawn, me, acts, tgt)
        if F.dist_m and F.dist_m > F.reach * 3 then set_phase(F, "approach", "target moved away") end
    elseif F.phase == "defend" then
        step_defend(F, pawn, me, acts)
    elseif F.phase == "flee" then
        step_flee(F, pawn, me)
    elseif F.phase == "loot" then
        step_loot(F, pawn, me)
    elseif F.phase == "restore" then
        step_restore(F, pawn)
    end
end
M._frame = frame

-- Start a fight. opts = {mode="attack"|"reflex", level, force, why, react=true}. -> {ok, ...}
local function start_fight(log, actor, opts)
    opts = opts or {}
    if _G.DW_PAUSE then return { ok = false, reason = "companion_down", data = { detail = "paused (world loading)" } } end
    local c = C()
    if not (c.hooks_started and c.handlers) then c.hooks_started = true; M.hooks_start(log) end
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    if not U.alive(actor) then return { ok = false, reason = "unknown_target" } end
    -- never players: a pawn with a valid PlayerState, or any player-character class (AI pawns also
    -- have a PlayerState property, but it is an invalid/null object)
    if U.valid(U.try(function() return actor.PlayerState end)) or (U.class_word(actor) or ""):find("PlayerCharacter", 1, true) then
        return { ok = false, reason = "unsafe", data = { why = "never attack players" } }
    end
    c.me_id, c.pc_id = U.short(pawn), U.short(pc)
    c.on_target = {}
    local me = read_me(pawn, pc)
    local tgt = read_creature(actor, me.pos)
    if tgt.dead then return { ok = false, reason = "unknown_target", data = { detail = "already dead" } } end
    if tgt.follower then return { ok = false, reason = "unsafe", data = { why = "a player's follower" } } end
    -- veto strong enemies up front for commanded attacks (Claude is level 1)
    if opts.mode == "attack" and not opts.force then
        local a = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = 12 }, { tgt }, { stance = "defensive", avoid = {} }, nil, M.cfg)
        if a.decision == "flee" then
            return { ok = false, reason = "unsafe", data = { why = a.why, enemy = tgt.name, enemy_pl = tgt.pl, my_pl = me.pl, u_fight = a.u_fight } }
        end
    end
    if c.fight then finish(c.fight, result_of(c.fight, false, "interrupted", { detail = "a new fight started" })) end
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "combat:" .. (opts.mode or "attack"), level = opts.level or (opts.mode == "reflex" and "reflex" or "command"),
                                     resumable = false, uses_move = true, lease_s = 5,
                                     on_stop = function(_, _, why) local f = C().fight; if f and f.token == token then finish(f, result_of(f, false, "interrupted", { detail = why })) end end })
        if not r.ok then return { ok = false, reason = "interrupted", data = { detail = "pawn busy", owner = r.owner } } end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.fights = c.counts.fights + 1
    local t = now(pawn)
    local F = { gen = c.gen, log = log, pc = pc, mode = opts.mode or "attack", force = opts.force, token = token,
                target = actor, target_id = tgt.id, target_name = tgt.name, target_hp = tgt.hp, target_pos = tgt.pos,
                dist_m = tgt.distance_m or 99, affinities = read_affinities(actor),
                t0 = t, t = t, phase_t = t, inputs = {}, presses = 0, hits = 0, kills = 0, verified = 0, unverified_run = 0,
                hit_seq = c.counts.hits, phase_log = {}, items_before = {}, loot_skip = {}, why = opts.why }
    for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do F.items_before[U.short(w) or "?"] = true end
    -- distances are centre to centre: a big creature (a cow's capsule) keeps us farther away, so
    -- reach and follow distance grow with its capsule radius beyond a Kebbit-sized one
    M.set_reach(F, actor)
    F.react_until = t + ((opts.react ~= false) and M.react_delay() or 0)
    c.fight = F
    set_phase(F, "react", opts.why)
    mcall("move", "stop", log)
    F.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, F)
        if not ok then
            say(log, "frame error " .. tostring(err))
            F.errors = (F.errors or 0) + 1
            if F.errors >= 5 then finish(F, result_of(F, false, "body_error", { detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { target = tgt.name, target_id = tgt.id, distance_m = tgt.distance_m, enemy_pl = tgt.pl, my_pl = me.pl, hp = tgt.hp } }
end
M._start_fight = start_fight

function M.attack(log, target, opts)
    opts = opts or {}
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    local actor = M.resolve_target(target, U.loc(pawn))
    if not actor then return { ok = false, reason = "unknown_target", data = { target = tostring(target) } } end
    return start_fight(log, actor, { mode = "attack", force = opts.force, why = "commanded" })
end

function M.stop(log, why)
    local f = C().fight
    if not f then return { ok = true, was = "idle" } end
    finish(f, result_of(f, false, "interrupted", { detail = why or "stopped" }))
    return { ok = true, was = f.phase }
end

-- ------------------------------------------------------------------ the reflex (guard)
local function guard_tick(log)
    if _G.DW_PAUSE then return end
    local c = C()
    local cfg = M.cfg
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return end
    c.me_id = U.short(pawn)
    local t = now(pawn)
    trim_map(c.attackers, t, 60); trim_map(c.ally_attackers, t, 60); trim_map(c.telegraphs, t, 30)
    if c.fight then return end
    if U.try(function() return pawn.HealthComponent:IsDead() end) == true then return end
    local origin = U.loc(pawn)
    local threats = M.pick_threats(creatures_near(origin, math.max(cfg.aggro_m, cfg.assist_m)), c.attackers, c.ally_attackers, M.orders, t, cfg)
    c.guard_seen = #threats
    local th = threats[1]
    if not th then return end
    if M.orders.stance == "passive" and th.why ~= "attacked_me" then return end
    if th.why == "attacked_ally" and M.orders.stance == "passive" then return end
    c.guard_last = { t = os.time(), id = th.id, name = th.name, why = th.why, d = th.distance_m }
    say(log, string.format("threat %s (%s) %.1f m pl=%s why=%s", th.name, th.id, th.distance_m or -1, tostring(th.pl), th.why))
    local r = start_fight(log, th.actor, { mode = "reflex", level = "reflex", why = th.why })
    if not r.ok then say(log, "reflex could not start: " .. tostring(r.reason)) end
end
M._guard_tick = guard_tick

function M.guard_start(log, opts)
    local c = C()
    for k, v in pairs(opts or {}) do if M.cfg[k] ~= nil then M.cfg[k] = v; c.cfg_over[k] = v end end
    local h = M.hooks_start(log)
    c.hooks_started = true
    c.guard_fn = function() guard_tick(log) end
    if not c.guard then
        c.guard = LoopInGameThreadWithDelay(M.cfg.guard_period_ms, function()
            local cc = _G.DWCombat
            if _G.DW_PAUSE then return end
            if cc and cc.guard_fn then
                local ok, err = pcall(cc.guard_fn)
                if not ok then cc.guard_err = tostring(err) end
            end
        end)
    end
    return { ok = true, hooks = h.hooks, orders = M.orders }
end

function M.guard_stop(log)
    local c = C()
    if c.guard then pcall(CancelDelayedAction, c.guard) end
    c.guard, c.guard_fn = nil, nil
    return { ok = true }
end

function M.set_orders(t)
    M.orders = C().orders
    for k, v in pairs(t or {}) do
        if k == "avoid" and type(v) == "table" then
            M.orders.avoid = {}
            for _, n in ipairs(v) do M.orders.avoid[tostring(n):lower()] = true end
        elseif M.orders[k] ~= nil or k == "stance" then M.orders[k] = v end
    end
    return { ok = true, orders = M.orders }
end

function M.status()
    local c = C()
    local f = c.fight
    local fs
    if f then
        fs = { mode = f.mode, phase = f.phase, reach = f.reach, radius_cm = f.target_radius_cm, target = f.target_name, target_id = f.target_id, dist_m = f.dist_m and math.floor(f.dist_m * 10) / 10,
               target_hp = f.target_hp, presses = f.presses, verified = f.verified, hits = f.hits, dmg = f.dmg, face_err = f.face_err and math.floor(f.face_err),
               weapon = f.equip_plan and f.equip_plan.weapon, assessment = f.assessment, injected = f.injected, phase_log = f.phase_log,
               age_s = f.t and f.t0 and math.floor((f.t - f.t0) * 10) / 10 }
    end
    local learned = {}
    for k, v in pairs(c.learned) do learned[k] = v end
    return { ok = true, fight = fs, last = c.last, guard = c.guard ~= nil, guard_last = c.guard_last, guard_err = c.guard_err,
             hook_err = c.hook_err, counts = c.counts, on_target = c.on_target, orders = M.orders, learned = learned, lines = c.log_lines,
             hooks = (function() local n = 0; for _ in pairs(c.hooks) do n = n + 1 end; return n end)() }
end

-- ------------------------------------------------------------------ bridge module handlers
-- attack: an async action ({pending = a}); the bridge pre-empts other actions (attack is in ACTION_TOOLS).
M.HANDLERS = {
    attack = function(log, args, ctx)
        if type(args.target) ~= "string" or args.target == "" then
            return { ok = false, reason = "invalid_args", data = { detail = "target is required (entity id or creature name)" } }
        end
        local r = M.attack(log, args.target, { force = args.force == true })
        if not r.ok then return r end
        local F = C().fight
        local a = { kind = "attack", id = ctx and ctx.id, timeout_s = M.cfg.fight_timeout_s + 15 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local f = C().fight
            if f and f == F then return nil end
            return (F and F.result) or { ok = false, reason = "body_error", data = { detail = "fight vanished" } }
        end
        return { pending = a }
    end,
    combat_status = function() return M.status() end,
    combat_orders = function(log, args) return M.set_orders(args) end,
}

return M
