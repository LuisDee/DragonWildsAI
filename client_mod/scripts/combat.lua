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
    disengage_m = 10,        -- back off this far to eat (orders.disengage)
    move_axes = "xy",
    ranged_max_m = 25,       -- ranged: shoot from up to this far (shrinks when out of the projectile's range)
    ranged_keep_m = 12,      -- ... and close in to about this when farther
    ranged_min_m = 4,
    ranged_aim_s = 1.0,      -- aim this long when the game's full-accuracy flag is unreadable
    ranged_aim_z = 0,        -- aim height above the target's actor origin (capsule centre), cm        -- IA_Movement axes: "xy" = X right, Y forward (UE template); "yx" swaps them
    disengage_s = 25,        -- give the heal this long before re-assessing
    lock_on = true,
    nudge = true,            -- turn the body toward the target with a short movement nudge when standing
    face_err_deg = 35,
    loot = true, loot_radius_m = 7, loot_s = 20, loot_max = 6, loot_wait_s = 0.8,
    safe_m = 22, safe_s = 4, flee_timeout_s = 45, flee_far_m = 30,
    protect = os.getenv("DW_PLAYER_NAME"), -- the player to defend and flee to (config; combat_orders.protect overrides)
    verify_presses = 6,      -- this many presses with no stamina drop and no hit -> the input is not reaching the game
}

-- Standing orders (the brain / Luis can change them: combat_orders):
--   stance: "defensive" (fight what attacks him or the protected player, when winnable),
--           "aggressive" (also engage Aggressive hostiles that come near),
--           "passive" (never start a fight by reflex; flee when attacked), "flee" (always flee).
--   avoid:  {name=true} creatures never to fight; force: commanded attacks ignore the vetoes.
--   defense / allow_jump / disengage / heal_hp / reengage_hp / flee_hp: the fighting policy (below).
M.orders = { stance = "defensive", avoid = {}, force = false,
             defense = "auto",   -- auto | parry | block | dodge | none (how to answer an enemy attack)
             allow_jump = true,  -- jump out of low sweeps / area attacks when the shape says so
             disengage = true,   -- low HP mid-fight: back off, eat to heal, then re-engage or flee
             heal_hp = 0.5,      -- disengage and eat below this HP fraction
             reengage_hp = 0.8,  -- ... and go back in at or above this
             flee_hp = nil }     -- nil = cfg.flee_hp

-- Provisional weakness priors by creature name (docs/research/2026-10-25-spells-and-weaknesses.md;
-- wiki/gamever, MEDIUM confidence). Live DamageTypeAffinities (empty on the client for Kebbits) and
-- learned hit outcomes override these.
M.PRIORS = (function()
    local ok, d = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/creature_priors.lua"))() end)
    return ok and type(d) == "table" and d or {}
end)() -- data file (client_mod/scripts/creature_priors.lua), not code
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
    local function veto(why) r.decision, r.why = "flee", why; return r end
    if #enemies == 0 then r.decision, r.why = "none", "no_enemies"; return r end
    -- the numbers first: always reported (information for the model), whatever decides
    local my_pl = me.pl or 1
    local worst_gap, total_hp, their_dps, boss = -99, 0, 0, false
    for _, e in ipairs(enemies) do
        if e.boss then boss = true end
        local gap = (e.pl or 1) - my_pl
        if gap > worst_gap then worst_gap = gap end
        total_hp = total_hp + math.max(e.hp or e.max_hp or 50, 1)
        local d = e.dps_obs or M.enemy_dps_prior(e.pl)
        their_dps = their_dps + d * (1.25 ^ gap)
    end
    r.pl_gap, r.boss, r.enemies = worst_gap, boss or nil, #enemies
    local my_dps = math.max((me.dps or 5) * (1.25 ^ (-worst_gap)), 0.1)
    r.my_ttk = total_hp / my_dps
    r.their_ttk = (me.hp or 1) / math.max(their_dps, 0.1)
    local ratio = r.their_ttk / math.max(r.my_ttk, 0.1)
    local u_ratio = ratio / (ratio + 1)                         -- 0.5 when even
    local u_hp = math.sqrt(math.max(0, math.min(1, (hp_frac - cfg.flee_hp) / (1 - cfg.flee_hp))))
    r.u_fight = u_ratio * (0.6 + 0.4 * u_hp)
    r.verdict = (boss and "boss") or (worst_gap >= cfg.pl_gap_flee and "too_strong")
        or (#enemies > cfg.max_hostiles and "outnumbered") or (r.u_fight >= cfg.fight_enter and "likely_win") or "likely_lose"
    if orders.force then r.decision, r.why = "fight", "forced"; return r end
    local flee_hp = orders.flee_hp or cfg.flee_hp
    if orders.commanded then
        -- a commanded fight is the model's decision (North Star review): no strength vetoes; only the
        -- model's own flee_hp policy (combat_orders) can turn it into flight
        if hp_frac < flee_hp then return veto("low_hp") end
        r.decision, r.why = "fight", "commanded"
        return r
    end
    -- the reflex (policy from combat_orders: stance, flee_hp)
    if orders.stance == "flee" then return veto("orders") end
    if boss then return veto("boss") end
    if worst_gap >= cfg.pl_gap_flee then return veto("too_strong") end
    if #enemies > cfg.max_hostiles then return veto("outnumbered") end
    if hp_frac < flee_hp then return veto("low_hp") end
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

-- The nearest OTHER player whose pawn is visible (the default ally to flee to / defend when no
-- protect is configured): PlayerStates are always replicated, pawns only within relevancy.
function M.nearest_player_name(origin)
    local me = C().me_id
    local best, bd
    for _, ps in ipairs(U.find_all("PlayerState", { skip_defaults = true })) do
        local p = U.try(function() return ps.PawnPrivate end)
        if U.valid(p) and U.short(p) ~= me then
            local at = U.loc(p)
            local d = (at and origin) and U.dist(origin, at) or 1e9
            local n = U.str(U.try(function() return ps:GetPlayerName() end))
            if n and (not bd or d < bd) then best, bd = n, d end
        end
    end
    return best
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
                  evade = get("EvadeAction"), movement = get("MovementAction"),
                  lock = U.valid(lo) and U.try(function() return lo.ToggleLockOnInput end) or nil }
    return c.actions
end
M.actions = actions

local function eis()
    local c = C()
    if not (c.eis and U.valid(c.eis)) then c.eis = U.find_first("EnhancedInputLocalPlayerSubsystem") end
    return c.eis
end

local function inject(action, vec)
    local s = eis()
    if not (s and U.valid(action)) then return false end
    local v = vec or { X = 1.0, Y = 0.0, Z = 0.0 }
    local ok = pcall(function() s:InjectInputVectorForAction(action, { X = v.X or 0, Y = v.Y or 0, Z = v.Z or 0 }, {}, {}) end)
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
    -- the server's verdict on Claude's block (PlayerBlockingComponent, NetMulticast; params not read)
    { path = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack", handler = "on_parried" },
    { path = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingBlockedAttack", handler = "on_blocked" },
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
    if vid == me then
        -- every damage event on Claude (defence outcomes, damage_taken)
        c.me_seq = (c.me_seq or 0) + 1
        c.me_dmg = c.me_dmg or {}
        c.me_dmg[#c.me_dmg + 1] = { seq = c.me_seq, t = t, amount = amount, inst = iid,
                                    absorbed = num(U.try(function() return e.AmountAbsorbedByShield end)) }
        if #c.me_dmg > 20 then table.remove(c.me_dmg, 1) end
        if f then f.dmg_taken = (f.dmg_taken or 0) + amount end
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

-- What the starting AI attack is (read-only, at the telegraph): its data object's damage time(s),
-- property flags (Unblockable 1, Unparryable 2) and first damage shape (DISCOVERIES, UAiAttackData).
local function read_shape(sh)
    if not U.valid(sh) then return nil end
    local function f(k) return num(U.try(function() return sh[k] end)) end
    local d = { class = U.class_word(sh), radius = f("Radius"), depth = f("Depth"), zheight = f("ZHeight"),
                top_angle = f("TopAngle"), half_height = f("HalfHeight") }
    local off = U.try(function() return sh.Offset end)
    if off then d.offset_x, d.offset_z = num(U.try(function() return off.X end)), num(U.try(function() return off.Z end)) end
    local ext = U.try(function() return sh.Extent end) or U.try(function() return sh.BoxExtent end)
    if ext then d.extent = { x = num(U.try(function() return ext.X end)), y = num(U.try(function() return ext.Y end)), z = num(U.try(function() return ext.Z end)) } end
    return d
end
M.read_shape = read_shape

local function read_attack(comp, owner, class_id)
    local info = { class_id = class_id }
    local ad = U.try(function() return comp.CurrentAttack.AttackData end)
    if U.valid(ad) then
        info.name = (U.short(ad) or ""):gsub("^Default__", ""):gsub("_C$", "")
        info.dmg_time = num(U.try(function() return ad:GetDamageTime() end))
        info.last_dmg_time = num(U.try(function() return ad:GetLastDamageTime() end))
        info.duration = num(U.try(function() return ad:GetDuration() end))
        local flags = num(U.try(function() return ad.AttackPropertyFlags end)) or 0
        info.flags = flags
        info.unblockable = (flags & 1) ~= 0 or nil
        info.unparryable = (flags & 2) ~= 0 or nil
        info.special = (flags & 4) ~= 0 or nil
        info.finisher = (flags & 8) ~= 0 or nil
        info.force_blast = (flags & 16) ~= 0 or nil
        -- what the client can see ahead of the hit: the montage (and its length), root-motion scaling
        -- (lunges move the attacker with root motion), leaving the navmesh, the combo's next attack
        local mon = U.try(function() return ad.Montage end)
        if U.valid(mon) then
            info.montage = U.short(mon)
            info.montage_s = num(U.try(function() return mon:GetPlayLength() end))
        end
        info.root_motion_scale = num(U.try(function() return ad.MaximumRootMotionScaling end))
        info.leaves_navmesh = U.try(function() return ad.bLeaveNavMesh end) == true or nil
        local nxt = U.try(function() return ad.NextAttack end)
        info.combo_next = U.valid(nxt) and U.short(nxt) or nil
        local nd = 0
        pcall(function() ad.Damage:ForEach(function() nd = nd + 1 end) end)
        info.hits = nd > 0 and nd or nil
        pcall(function()
            ad.Damage:ForEach(function(_, e)
                if info.shape_raw then return true end
                local dd = e:get()
                info.dmg_time = info.dmg_time or num(U.try(function() return dd.Time end))
                info.shape_raw = read_shape(U.try(function() return dd.Shape end)) or false
            end)
        end)
        if info.shape_raw == false then info.shape_raw = nil end
    end
    local data = U.try(function() return owner.LoadedData end)
    local who = U.valid(data) and text(U.try(function() return data.AIName end)) or "?"
    info.key = who .. ":" .. (info.name or ("class" .. tostring(class_id)))
    local D = mod("defense")
    local hh = num(U.try(function() return owner.CapsuleComponent:GetScaledCapsuleHalfHeight() end))
    if D and info.shape_raw then info.shape = D.shape_info(info.shape_raw, hh) end
    return info
end
M.read_attack = read_attack

function M.on_ai_attack(ctx, class_id)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local a = U.try(function() return comp:GetOwner() end)
    if not U.valid(a) then return end
    local id = U.short(a)
    local t = now(a)
    c.telegraphs[id] = t
    c.counts.telegraphs = c.counts.telegraphs + 1
    -- only attacks near Claude are worth reading
    local f = c.fight
    if f and (id == f.target_id or (f.me_pos and U.loc(a) and U.dist(U.loc(a), f.me_pos) < 800)) then
        local ok, info = pcall(read_attack, comp, a, class_id and U.try(function() return class_id:get() end))
        if ok and info then info.t = t; c.tele_info = c.tele_info or {}; c.tele_info[id] = info end
    end
end

local function on_block_event(ctx, kind)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local o = U.try(function() return comp:GetOwner() end)
    if not (U.valid(o) and U.short(o) == c.me_id) then return end
    c.block_seq = (c.block_seq or 0) + 1
    c.block_events = c.block_events or {}
    c.block_events[#c.block_events + 1] = { seq = c.block_seq, kind = kind, t = now(o) }
    if #c.block_events > 20 then table.remove(c.block_events, 1) end
end
function M.on_parried(ctx) on_block_event(ctx, "parried") end
function M.on_blocked(ctx) on_block_event(ctx, "blocked") end

function M.hooks_start(log)
    local c = C()
    local p = mcall("inventory", "pawn")
    if p then c.me_id = U.short(p) end
    local pc0 = local_pc()
    if pc0 then c.pc_id = U.short(pc0) end
    c.handlers = { on_damage = M.on_damage, on_ai_attack = M.on_ai_attack, on_parried = M.on_parried, on_blocked = M.on_blocked }
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

-- Activity events for the brain (client_io/events/activity.jsonl; the bridge forwards each line as
-- an "activity" event). One combat_end per fight, plus fled / healed while it runs.
M.ACTIVITY_PATH = ROOT .. "/client_io/events/activity.jsonl"
local json_mod
function M.emit_activity(ev)
    json_mod = json_mod or U.try(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    if not json_mod then return end
    ev.type = "activity"
    ev.ts = os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local line = U.try(function() return json_mod.encode(ev) end)
    if not line then return end
    local fh = io.open(M.ACTIVITY_PATH, "a")
    if fh then fh:write(line, "\n"); fh:close() end
end

local function cdo_of(class_path)
    if type(class_path) ~= "string" then return nil end
    local pkg, name = class_path:match("^(.*)%.([%w_]+)$")
    return pkg and U.find_object(pkg .. ".Default__" .. name) or nil
end

-- What the held gear lets him do (the game's own action data): parry (block action bCanParry +
-- SkillPerkRequiredToParry unlocked), block costs, the special (its action's RequiredPerk unlocked).
-- Claude at Attack 1 has neither PerkV2_Attack_Parry (Attack 5) nor PerkV2_Attack_MeleeSpecialAttacks.
function M.capabilities(pc, right, left)
    local items = M.weapons().items or {}
    local spc = U.try(function() return pc.SkillPerkComponent end)
    local function unlocked(perk)
        if not U.valid(perk) then return true end
        if not U.valid(spc) then return false end
        local ok, v = pcall(function() return spc:IsPerkUnlocked(perk) end)
        return ok and v == true
    end
    local cap = { can_block = false, can_parry = false }
    local blocker = (left and items[left] and items[left].can_block and items[left]) or (right and items[right] and items[right].can_block and items[right])
    if blocker then
        cap.can_block = true
        cap.block_item = blocker.name
        local cdo = cdo_of(blocker.block_action)
        if cdo then
            cap.block_cost = num(U.try(function() return cdo.BlockStaminaCost end))
            cap.parry_cost = num(U.try(function() return cdo.ParryStaminaCost end))
            local cp = U.try(function() return cdo.bCanParry end) == true
            local perk = U.try(function() return cdo.SkillPerkRequiredToParry end)
            cap.parry_perk = U.valid(perk) and U.short(perk) or nil
            cap.can_parry = cp and unlocked(perk)
        end
    end
    local w = right and items[right] or (left and items[left])
    local spec = w and w.spec
    if spec and spec.action then
        local cdo = cdo_of(spec.action)
        local perk = cdo and U.try(function() return cdo.RequiredPerk end)
        cap.special_perk = U.valid(perk) and U.short(perk) or nil
        cap.special_ok = cdo ~= nil and unlocked(perk)
    else
        cap.special_ok = spec ~= nil
    end
    return cap
end

local function outcome_of(F, res)
    if res.ok and F.kills > 0 then return "killed" end
    local d = res.data or {}
    if d.fled then return "fled" end
    if d.died then return "died" end
    local r = res.reason
    if r == "unknown_target" or r == "too_far" then return "lost" end
    if r == "timeout" then return "timeout" end
    if r == "unsafe" then return "fled" end
    return res.ok and "done" or "interrupted"
end

local function result_of(F, ok, reason, data)
    data = data or {}
    data.target = F.target_name
    data.target_id = F.target_id
    data.presses, data.hits, data.kills = F.presses, F.hits, F.kills
    data.looted = F.looted
    data.phase_log = F.phase_log
    data.defense = { parries = F.n_parried or 0, blocks = F.n_blocked or 0, dodges = F.n_dodges or 0, jumps = F.n_jumps or 0,
                     abilities = F.n_abilities,
                     avoided = F.n_avoided or 0, hits_taken = F.n_hit or 0, heals = F.n_heals or 0 }
    data.damage_taken = F.dmg_taken or 0
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

function M.emit_combat_end(F, res)
    local d = res.data or {}
    M.emit_activity({ kind = "combat_end", by = F.by or "unknown", dur_s = F.t and F.t0 and math.floor((F.t - F.t0) * 10) / 10 or nil,
        target = F.target_name, target_id = F.target_id, outcome = outcome_of(F, res), reason = res.reason,
        damage_taken = F.dmg_taken or 0, damage_dealt = math.max(0, (F.hp_start or 0) - (F.target_hp or 0)),
        hp_end = F.hp_now, loot = F.loot_names, parries = F.n_parried or 0, blocks = F.n_blocked or 0,
        dodges = F.n_dodges or 0, jumps = F.n_jumps or 0, heals = F.n_heals or 0, presses = F.presses, why = F.why,
        fled_why = d.why })
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
    M.emit_combat_end(F, res)
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
        local items = M.weapons().items or {}
        if F.weapon_pref then
            -- the model chose the weapon (attack.weapon): name or id of an item he carries
            local inv = mod("inventory")
            local e = inv and inv.find and inv.find(list, F.weapon_pref)
            if not e then return finish(F, result_of(F, false, "not_in_inventory", { why = "weapon_not_carried", weapon = F.weapon_pref })) end
            pick = { weapon = { entry = e, profile = items[e.item] or {}, score = 0 }, shield = pick.shield }
        else
            -- already holding a ranged weapon: keep it (the player or the model armed him with it)
            local hr, hl = held_items(pawn)
            local hp = (hr and items[hr]) or (hl and items[hl])
            local hid = (hr and items[hr]) and hr or hl
            if hp and hp.kind == "ranged" then pick = { weapon = { entry = { item = hid }, profile = hp, score = 0 } } end
        end
        F.equip_plan = { weapon = pick.weapon and pick.weapon.entry.item, shield = nil, sent = {}, t = F.t }
        if pick.weapon then
            F.profile = pick.weapon.profile
            F.weapon_score = pick.weapon.score
            if pick.shield and pick.weapon.profile.slot ~= "two_handed" and pick.weapon.profile.kind ~= "ranged" then F.equip_plan.shield = pick.shield.entry.item end
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
    M.emit_activity({ kind = "fled", by = F.by or "unknown", from = F.target_name, from_id = F.target_id, why = why, hp = F.hp_now })
    local luis = M.orders.protect or M.cfg.protect or M.nearest_player_name(F.me_pos)
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

-- Eat the food that heals most, the way a player does (its hotbar key / the inventory UI's use).
-- Respects the game's eating limits when inventory.lua exposes them (eat_status: can_eat, cooldown_s,
-- fullness); otherwise our own cooldown. The heal is verified from the HP that follows (healed event).
local function best_heal_food(list)
    local pick
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do
            if e.consumable == "food" and (e.heal or 0) > 0 and (not pick or (e.heal or 0) > (pick.heal or 0)) then pick = e end
        end
    end
    return pick
end
M.best_heal_food = best_heal_food

local function eat_allowed(F)
    if F.next_eat and F.t < F.next_eat then return false, "cooldown" end
    local st = mcall("inventory", "eat_status")
    if type(st) == "table" and st.can_eat == false then
        if st.cooldown_s then F.next_eat = F.t + st.cooldown_s end
        return false, st.reason or "game_refuses"
    end
    return true
end

local function try_eat(F, me, force)
    if not me.max_hp or me.max_hp <= 0 then return end
    -- verify the previous bite: HP went up -> healed event
    local hp_ = F.heal_pending
    if hp_ and F.t - hp_.t >= 2.5 then
        F.heal_pending = nil
        if (me.hp or 0) > hp_.hp0 + 0.5 then
            F.n_heals = (F.n_heals or 0) + 1
            M.emit_activity({ kind = "healed", by = F.by or "unknown", food = hp_.food, hp_before = hp_.hp0, hp_after = me.hp })
            say(F.log, string.format("healed %.0f -> %.0f (%s)", hp_.hp0, me.hp or -1, tostring(hp_.food)))
        else
            F.eat_fails = (F.eat_fails or 0) + 1
        end
    end
    if F.heal_pending then return end
    local frac = (me.hp or 0) / me.max_hp
    if not force and frac >= M.cfg.eat_hp then return end
    local ok, why = eat_allowed(F)
    if not ok then return false, why end
    local list = mcall("inventory", "list", F.log) or {}
    local pick = best_heal_food(list) or mcall("inventory", "best_consumable", list, "food")
    if not pick then F.no_food = true; return false, "no_food" end
    F.next_eat = F.t + 8
    local r = mcall("inventory", "use", F.log, pick.item)
    say(F.log, "eat " .. tostring(pick.item) .. " hp=" .. tostring(me.hp) .. " -> " .. tostring(r and (r.via or r.reason)))
    F.ate = (F.ate or 0) + 1
    F.heal_pending = { t = F.t, hp0 = me.hp or 0, food = pick.name or pick.item }
    return true
end
M._try_eat = try_eat

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

-- Defence against one telegraphed attack. defense.lua plans it (parry / block / dodge / jump /
-- retreat, timed from the attack's own data and learned per attack); it is executed here and the
-- outcome is read from the server's verdicts: Claude's PlayerBlockingComponent parried / blocked
-- multicasts, damage multicasts on Claude, his evade component, the current montage (*Parry*).
local function away_dir(me, tp, side)
    if not (me and tp) then return nil end
    local dx, dy = tp.X - me.X, tp.Y - me.Y
    local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
    dx, dy = dx / l, dy / l
    -- UE is left-handed: X forward, Y right. Right of forward (dx, dy) is (-dy, dx).
    if side == "left" then return { X = dy, Y = -dx, Z = 0 } end
    if side == "right" then return { X = -dy, Y = dx, Z = 0 } end
    return { X = -dx, Y = -dy, Z = 0 } -- back
end
M.away_dir = away_dir

-- Defensive abilities are cast through the spells module (the player's own spell inputs). Contract
-- (docs/design/defense-abilities.md): spells.ability_status(asset) -> {available, why, latency_s,
-- cooldown_s, runes_ok}; spells.cast_now(log, asset, {owner_token}) -> job with poll() -> nil | {ok,
-- cast_t, reason}. Without them the abilities are simply unavailable (reported, never faked).
M.spell_api = {
    status = function(asset)
        local sp = mod("spells")
        if sp and type(sp.ability_status) == "function" then
            local ok, r = pcall(sp.ability_status, asset)
            if ok and type(r) == "table" then return r end
        end
        return { available = false, why = "no_fast_cast_route" }
    end,
    cast = function(F, asset)
        local sp = mod("spells")
        if sp and type(sp.cast_now) == "function" then
            local ok, job = pcall(sp.cast_now, F.log, asset, { owner_token = F.token })
            if ok then return job end
        end
        return nil
    end,
}

local function ability_ctx(F)
    if F.ab_ctx and F.t - (F.ab_ctx_t or -9) < 2 then return F.ab_ctx end
    local D = mod("defense")
    local out = {}
    local c = C()
    for name, def in pairs(D and D.abilities() or {}) do
        local st = M.spell_api.status(def.spell_asset) or {}
        out[name] = { available = st.available == true, why = st.why,
                      latency_s = (c.ability_latency or {})[def.spell_asset] or st.latency_s }
    end
    F.ab_ctx, F.ab_ctx_t = out, F.t
    return out
end
M._ability_ctx = ability_ctx

local function start_defend(F, me, attacker_id, tt, info)
    local c = C()
    local D = mod("defense")
    local apos
    if attacker_id == F.target_id then apos = F.target_pos
    else local a = find_creature(attacker_id); apos = a and U.loc(a) end
    local cap = F.cap or {}
    local ctx = { dist_cm = (apos and me.pos) and U.dist2d(apos, me.pos) or nil, latency_s = F.latency or 0.03,
                  stamina = me.stamina, can_parry = cap.can_parry, can_block = cap.can_block,
                  parry_cost = cap.parry_cost, block_cost = cap.block_cost, evade_cost = c.evade_cost or 15,
                  hp_frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1, heal_hp = M.orders.heal_hp,
                  max_hp = me.max_hp, abilities = ability_ctx(F) }
    info = info or { key = "?:unknown" }
    local plan = D and D.plan(info, ctx, M.orders)
        or { action = "block", at_s = M.react_delay(), hold_s = 0.9, impact_s = 0.6, why = "no defense module" }
    F.def = { plan = plan, tel_t = tt, key = info.key, attacker = attacker_id, apos = apos, hp0 = me.hp, st0 = me.stamina,
              apos_tel = apos and { X = apos.X, Y = apos.Y, Z = apos.Z },
              me_seq0 = c.me_seq or 0, blk_seq0 = c.block_seq or 0, info = info }
    F.last_tele = tt
    if F.following then mcall("move", "stop", F.log); F.following = false end
    set_phase(F, "defend", string.format("%s %s impact %.2fs %s (%s)", plan.action, tostring(info.key), plan.impact_s or -1,
        tostring(plan.src), tostring(plan.why)))
end
M._start_defend = start_defend

local function finish_defend(F)
    local d = F.def
    if not d then return end
    local D = mod("defense")
    local act = d.plan.action
    local outcome
    if d.parried then outcome = "parried"
    elseif (d.hit_amt or 0) > 0 then outcome = "hit"
    elseif d.blocked then outcome = "blocked"
    elseif (act == "dodge" or act == "jump" or act == "retreat") and (d.impact_t or d.evaded) then outcome = "avoided"
    elseif d.cast and d.cast.result and d.cast.result.ok and d.impact_t then outcome = "avoided"
    elseif d.cast and (d.cast.failed or (d.cast.result and not d.cast.result.ok)) then outcome = "whiff"; d.cast_failed = true
    else outcome = "whiff" end
    if d.impact_t and D then D.observe(d.key, d.impact_t - d.tel_t) end
    -- how far the attacker came during the attack (a lunge), measured on Claude's own perception
    if D and d.apos_tel and d.apos_end then
        local dx, dy = d.apos_end.X - d.apos_tel.X, d.apos_end.Y - d.apos_tel.Y
        D.observe_lunge(d.key, math.sqrt(dx * dx + dy * dy))
    end
    if D then D.feedback(d.key, act, outcome, d.hit_amt) end
    if act == "dodge" and d.pos0 and d.apos0 and F.me_pos then
        local fx, fy = d.apos0.X - d.pos0.X, d.apos0.Y - d.pos0.Y
        local l = math.max(math.sqrt(fx * fx + fy * fy), 1)
        fx, fy = fx / l, fy / l
        local mx, my = F.me_pos.X - d.pos0.X, F.me_pos.Y - d.pos0.Y
        d.moved = { toward_cm = math.floor(mx * fx + my * fy), right_cm = math.floor(-mx * fy + my * fx), dir = d.plan.dir }
    end
    if outcome == "parried" then F.n_parried = (F.n_parried or 0) + 1
    elseif outcome == "blocked" then F.n_blocked = (F.n_blocked or 0) + 1
    elseif outcome == "hit" then F.n_hit = (F.n_hit or 0) + 1
    elseif outcome == "avoided" then F.n_avoided = (F.n_avoided or 0) + 1 end
    local c = C()
    c.counts[outcome] = (c.counts[outcome] or 0) + 1
    say(F.log, string.format("defence %s -> %s (key %s, impact %s, dmg %s, evaded %s, montage %s)", act, outcome, tostring(d.key),
        d.impact_t and string.format("%.2fs", d.impact_t - d.tel_t) or "-", tostring(d.hit_amt or 0), tostring(d.evaded), tostring(d.montage)))
    F.last_defence = { action = act, outcome = outcome, key = d.key, impact_s = d.impact_t and (d.impact_t - d.tel_t) or nil,
                       plan_at = d.plan.at_s, why = d.plan.why, moved = d.moved }
    if d.moved then say(F.log, string.format("dodge %s moved toward %+dcm right %+dcm", tostring(d.moved.dir), d.moved.toward_cm, d.moved.right_cm)) end
    F.def, F.hold, F.evade_dir, F.evade_until, F.move_inject = nil, nil, nil, nil, nil
    set_phase(F, "engage", "defended " .. outcome)
end

local function my_evading(pawn)
    local c = C()
    local comp = U.try(function() return pawn.EvadeComponent end)
    if not U.valid(comp) then
        for _, x in ipairs(U.find_all("PlayerEvadeComponent", { skip_defaults = true })) do
            local o = U.try(function() return x:GetOwner() end)
            if U.valid(o) and U.short(o) == c.me_id then comp = x end
        end
    end
    return U.valid(comp) and U.try(function() return comp:IsEvading() end) == true
end

-- Start the planned defence at its moment. Called EVERY FRAME (a parry window is 100 ms; the
-- 100 ms decision tick would be too coarse) and from step_defend. Uses the last decision's reads.
local function defend_act(F, pawn, acts)
    local d = F.def
    if not d or d.started then return end
    local plan = d.plan
    if F.t - d.tel_t < (plan.cast_at_s or plan.at_s or 0) then return end
    local me = F.me_last or {}
    d.started = F.t
    d.started_rel = F.t - d.tel_t
    local a = plan.action
    if plan.spell_asset then
        -- a defensive ability: cast it now (the spells module drives the real spell inputs)
        d.cast = { t = F.t, asset = plan.spell_asset, job = M.spell_api.cast(F, plan.spell_asset) }
        F.n_abilities = F.n_abilities or {}
        F.n_abilities[a] = (F.n_abilities[a] or 0) + 1
        if not d.cast.job then d.cast.failed = "no_cast_route" end
        return
    end
    if (a == "parry" or a == "block") and acts.secondary then
        F.hold, F.hold_until = acts.secondary, F.t + (plan.hold_s or 0.9)
        inject(acts.secondary) -- this very frame
    elseif a == "dodge" and acts.evade then
        -- a player's directional dodge: movement keys held (IA_Movement, Axis2D, camera-relative:
        -- X = right, Y = forward; cfg.move_axes can swap them) plus the evade key. The camera faces the
        -- attacker first, so "left"/"right" are sideways to it and "back" is away from it.
        local tp = d.apos or F.target_pos
        if tp and me.pos then
            pcall(function() F.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(tp.Y - me.pos.Y, tp.X - me.pos.X)), Roll = 0 }) end)
        end
        if acts.movement then
            local sx = (plan.dir == "left" and -1) or (plan.dir == "right" and 1) or 0
            local sy = (plan.dir == "back" and -1) or 0
            local v = M.cfg.move_axes == "yx" and { X = sy, Y = sx } or { X = sx, Y = sy }
            F.move_inject, F.move_until = v, F.t + (plan.hold_s or 0.35)
        else
            F.evade_dir = away_dir(me.pos, tp, plan.dir) -- fallback: the movement handler's own call
        end
        F.evade_until = F.t + (plan.hold_s or 0.35)
        d.pos0 = me.pos and { X = me.pos.X, Y = me.pos.Y, Z = me.pos.Z }
        d.apos0 = tp and { X = tp.X, Y = tp.Y, Z = tp.Z }
        tap(F, acts.evade, 4, "evade")
        F.n_dodges = (F.n_dodges or 0) + 1
        d.st_dodge = me.stamina
    elseif a == "jump" then
        pcall(function() pawn:Jump() end)
        d.jump_release = F.t + (plan.hold_s or 0.25)
        F.n_jumps = (F.n_jumps or 0) + 1
    elseif a == "retreat" then
        F.evade_dir = away_dir(me.pos, d.apos or F.target_pos, "back")
        F.evade_until = F.t + (plan.hold_s or 0.8)
    end
end
M._defend_act = defend_act

-- Per frame after an ability was cast: its follow-up input (Phase Dash = the evade while the dash
-- window is open; Tempest Shield = keep blocking) and the cast's verdict (latency learned per spell).
local function defend_followup(F, pawn, acts)
    local d = F.def
    if not (d and d.cast) then return end
    local plan, rel = d.plan, F.t - d.tel_t
    local job = d.cast.job
    if job and not d.cast.result and type(job.poll) == "function" then
        local ok, r = pcall(job.poll, job)
        if ok and r then
            d.cast.result = r
            if r.ok and r.cast_t then
                local c = C()
                c.ability_latency = c.ability_latency or {}
                local lat = math.max(0, r.cast_t - d.cast.t)
                local old = c.ability_latency[d.cast.asset]
                c.ability_latency[d.cast.asset] = old and (old * 0.7 + lat * 0.3) or lat
            end
        end
    end
    if plan.evade_at_s and not d.evade_done and rel >= plan.evade_at_s and acts.evade then
        d.evade_done = true
        local me = F.me_last or {}
        local tp = d.apos or F.target_pos
        if tp and me.pos then
            pcall(function() F.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(tp.Y - me.pos.Y, tp.X - me.pos.X)), Roll = 0 }) end)
        end
        if acts.movement then
            local sx = (plan.dir == "left" and -1) or (plan.dir == "right" and 1) or 0
            F.move_inject, F.move_until = (M.cfg.move_axes == "yx" and { X = 0, Y = sx } or { X = sx, Y = 0 }), F.t + 0.35
        end
        tap(F, acts.evade, 4, "phase_dash")
        F.n_dodges = (F.n_dodges or 0) + 1
    end
    if plan.action == "tempest_shield" and not d.block_done and rel >= (plan.at_s or 0) and acts.secondary then
        d.block_done = true
        F.hold, F.hold_until = acts.secondary, F.t + (plan.hold_s or 0.9)
    end
end
M._defend_followup = defend_followup

local function step_defend(F, pawn, me, acts)
    local d = F.def
    if not d then return set_phase(F, "engage", "no plan") end
    local c = C()
    local plan = d.plan
    local rel = F.t - d.tel_t
    defend_act(F, pawn, acts)
    if F.evade_until and F.t >= F.evade_until then F.evade_dir, F.evade_until = nil, nil end
    if d.jump_release and F.t >= d.jump_release then pcall(function() pawn:StopJumping() end); d.jump_release = nil end
    if d.started and plan.action == "dodge" and not d.evaded and F.t - d.started < 0.6 then d.evaded = my_evading(pawn) end
    if d.st_dodge and d.started and F.t - d.started > 0.6 and me.stamina then
        local cost = d.st_dodge - me.stamina
        if cost > 1 and cost < 60 then c.evade_cost = c.evade_cost and (c.evade_cost * 0.7 + cost * 0.3) or cost end
        d.st_dodge = nil
    end
    -- evidence: the server's verdicts since the telegraph
    for _, e in ipairs(c.block_events or {}) do
        if e.seq > d.blk_seq0 then
            d.blk_seq0 = e.seq
            if e.kind == "parried" then d.parried = true else d.blocked = true end
            d.impact_t = d.impact_t or e.t
        end
    end
    for _, e in ipairs(c.me_dmg or {}) do
        if e.seq > d.me_seq0 then
            d.me_seq0 = e.seq
            if e.inst == d.attacker or e.inst == nil then
                d.hit_amt = (d.hit_amt or 0) + (e.amount or 0)
                d.impact_t = d.impact_t or e.t
                if (e.absorbed or 0) > 0 then d.blocked = true end
            end
        end
    end
    if F.hold and not d.parried then
        local ai = U.try(function() return pawn.Mesh:GetAnimInstance() end)
        local m = U.valid(ai) and U.short(U.try(function() return ai:GetCurrentActiveMontage() end)) or nil
        if m and m:find("Parry", 1, true) then d.parried, d.impact_t, d.montage = true, d.impact_t or F.t, m end
    end
    -- the attacker's position when the hit resolves (lunge learning)
    if d.impact_t and not d.apos_end then
        local a = d.attacker == F.target_id and F.target or find_creature(d.attacker)
        local p = a and U.loc(a)
        if p then d.apos_end = { X = p.X, Y = p.Y, Z = p.Z } end
    end
    -- a new telegraph (a combo's next swing) closes this one
    for id, tt in pairs(c.telegraphs) do
        if d.started and tt > d.tel_t + 0.2 and (id == d.attacker or id == F.target_id) then
            finish_defend(F)
            return start_defend(F, me, id, tt, (c.tele_info or {})[id])
        end
    end
    local window_end = d.tel_t + (plan.impact_s or 0.6) + 0.6
    local hold_done = not F.hold or F.t >= (F.hold_until or 0)
    if (F.t >= window_end and hold_done) or (d.impact_t and F.t >= d.impact_t + 0.2 and hold_done) or rel > 4 then
        finish_defend(F)
    end
end

-- Low HP mid-fight: back off out of reach, keep the enemy in view, eat to heal, then re-engage
-- (fight-or-flight re-assessed) or flee. Thresholds are the model's standing orders.
local function step_disengage(F, pawn, me, acts)
    local g = F.dis
    local o = M.orders
    if g.step == "back" then
        if (F.dist_m or 99) < 3.5 and acts.evade and (me.stamina or 0) >= (C().evade_cost or 15) then
            F.evade_dir = away_dir(me.pos, F.target_pos, "back")
            F.evade_until = F.t + 0.35
            tap(F, acts.evade, 4, "evade_back")
            F.n_dodges = (F.n_dodges or 0) + 1
        end
        local dir = away_dir(me.pos, F.target_pos, "back")
        if dir and me.pos then
            local far = M.cfg.disengage_m * 100
            local goal = { (me.pos.X + dir.X * far) / 100, (me.pos.Y + dir.Y * far) / 100, me.pos.Z / 100 }
            mcall("move", "go_to", F.log, goal, { sprint = true, tolerance_m = 2, timeout_s = 8 })
            F.drove_move, F.following = true, false
        end
        g.step, g.t = "move", F.t
        return
    end
    if g.step == "move" then
        local st = mcall("move", "status")
        if F.t - g.t > 6 or (F.dist_m or 0) >= M.cfg.disengage_m - 1 or (type(st) == "table" and st.mode == "idle" and F.t - g.t > 0.5) then
            mcall("move", "stop", F.log)
            g.step, g.t = "eat", F.t
        end
        return
    end
    -- eat: face the enemy (control rotation; move is idle) and eat while it keeps its distance
    if F.target_pos and me.pos then
        pcall(function() F.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(F.target_pos.Y - me.pos.Y, F.target_pos.X - me.pos.X)), Roll = 0 }) end)
    end
    local frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1
    try_eat(F, me, true)
    local done_why
    if frac >= (o.reengage_hp or 0.8) and not F.heal_pending then done_why = "healed"
    elseif F.no_food and not F.heal_pending then done_why = "no_food"
    elseif (F.eat_fails or 0) >= 3 then done_why = "eating_failed"
    elseif F.t - g.t > M.cfg.disengage_s then done_why = "timeout"
    elseif (F.dist_m or 99) < 4 then done_why = "enemy_closed_in" end
    if done_why then
        F.dis = nil
        F.assess_t = -9 -- re-assess at once: fight on (approach) or flee
        set_phase(F, "approach", "disengage done: " .. done_why)
    end
end

-- Ranged engage (crossbow / bow; ranged.lua does the maths). Keep distance, hold aim (the weapon's
-- secondary input), point the camera every frame at ranged.lua's lead solution, release (primary) once
-- the game says full accuracy, then follow the real bolt to learn speed/gravity/bias and score the shot.
local function ranged_setup(F, pawn, pc)
    local Rg = mod("ranged")
    if not Rg then return false, "no ranged module" end
    local comp = Rg.ranged_component(pawn)
    if not comp then return false, "no_ranged_component" end
    local prm = Rg.read_weapon_params(pawn) or {}
    local right, left = held_items(pawn)
    local key = tostring(right or left or "?") .. "|" .. tostring(prm.ammo or "?")
    local seed = prm.speed and { speed = prm.speed, gz = prm.gz or Rg.cfg.default_gz, t0 = prm.t0 or 0, source = "game_data" } or nil
    F.rg = { R = Rg, comp = comp, key = key, aimer = Rg.new_aimer(key, seed), seed = prm, shots = 0, hits = 0, misses = 0 }
    F.reach, F.follow = M.cfg.ranged_max_m, M.cfg.ranged_keep_m
    say(F.log, string.format("ranged: %s speed %s gz %s t0 %s (%s) full-accuracy %ss ammo ok %s", key, tostring(F.rg.aimer.p.speed),
        tostring(F.rg.aimer.p.gz), tostring(F.rg.aimer.p.t0), tostring(F.rg.aimer.p.source), tostring(prm.full_accuracy_s), tostring(prm.has_ammo)))
    if prm.has_ammo == false then return false, "no_ammo" end
    return true
end
M._ranged_setup = ranged_setup

-- Per frame: aim the camera and follow a flying shot.
local function ranged_frame(F, pawn)
    local g = F.rg
    if not g then return end
    local Rg, aimer = g.R, g.aimer
    if g.aiming and F.target then
        local muzzle = Rg.muzzle(pawn, g.comp)
        local cam = Rg.camera_location(F.pc)
        local rot, sol, info = aimer:solve(muzzle, cam, { aim_z = M.cfg.ranged_aim_z })
        g.sol, g.sol_why, g.sol_info, g.muzzle = sol, (not rot) and sol or nil, info, muzzle
        if rot then
            pcall(function() F.pc:SetControlRotation(rot) end)
            g.sol = sol
        else g.sol = nil end
    end
    local shot = aimer.shot
    if shot then
        if not shot.proj and (F.frame_n or 0) % 2 == 0 then
            for id, a in pairs(Rg.projectile_ids()) do
                if not shot.ids_before[id] then shot.proj, shot.proj_id = a, id; break end
            end
        end
        local pp = shot.proj and U.alive(shot.proj) and U.loc(shot.proj) or nil
        local tp = U.alive(F.target) and U.loc(F.target) or nil
        local done = aimer:sample(F.t, pp, tp)
        if shot.proj and not pp then done = true end
        if not shot.proj and F.t - shot.t > 1.0 then done = true; shot.no_projectile = true end
        -- the server's verdict (our damage multicast on the target) can trail the bolt's end: wait a bit
        if done and not shot.no_projectile then
            shot.gone_t = shot.gone_t or F.t
            if F.t - shot.gone_t < 0.3 then done = false end
        end
        if done then
            local hit = false
            for _, h in ipairs(C().my_hits) do
                if h.seq > (shot.hit_seq0 or 0) and h.victim == F.target_id then hit = true end
            end
            if shot.no_projectile then
                F.unverified_run = F.unverified_run + 1
                aimer.shot = nil
                say(F.log, "ranged: no projectile seen after the shot")
            else
                F.unverified_run = 0
                F.verified = F.verified + 1
                local res = aimer:finish(hit)
                g.shots = g.shots + 1
                if hit then g.hits = g.hits + 1 else g.misses = g.misses + 1 end
                local mi = res and res.miss
                g.last = { hit = hit, miss_cm = mi and math.floor(mi.dist_cm), vertical_cm = mi and math.floor(mi.vertical_cm or 0),
                           lateral_cm = mi and math.floor(mi.lateral_cm or 0), fit = res and res.fit and { speed = res.fit.speed, gz = res.fit.gz, t0 = res.fit.t0 },
                           profile = { speed = aimer.p.speed, gz = aimer.p.gz, t0 = aimer.p.t0, pitch_bias = aimer.p.pitch_bias, yaw_bias = aimer.p.yaw_bias } }
                say(F.log, string.format("ranged shot %d %s miss %s cm (v %s, lat %s) fit speed %s gz %s -> profile %.0f/%.0f/%.2f",
                    g.shots, hit and "HIT" or "miss", tostring(g.last.miss_cm), tostring(g.last.vertical_cm), tostring(g.last.lateral_cm),
                    tostring(res and res.fit and math.floor(res.fit.speed or 0)), tostring(res and res.fit and math.floor(res.fit.gz or 0)),
                    aimer.p.speed, aimer.p.gz, aimer.p.t0))
            end
        end
    end
end
M._ranged_frame = ranged_frame

local function step_ranged(F, pawn, me, acts, tgt)
    local cfg = M.cfg
    local g = F.rg
    local c = C()
    -- an attacker right next to us: stop aiming and defend (the melee answers apply)
    for id, tt in pairs(c.telegraphs) do
        if F.t - tt <= cfg.telegraph_fresh_s and tt > (F.last_tele or 0) then
            local a = id == F.target_id and F.target or find_creature(id)
            local p = a and U.loc(a)
            if p and me.pos and U.dist(p, me.pos) <= cfg.telegraph_m * 100 then
                g.aiming, F.hold = false, nil
                return M._start_defend(F, me, id, tt, (c.tele_info or {})[id])
            end
        end
    end
    local d = F.dist_m or 99
    if tgt and tgt.pos then g.aimer:observe(F.t, tgt.pos) end
    if d > F.reach or (g.sol == nil and g.sol_why == "out_of_range" and g.aiming) then
        -- too far (or out of the projectile's range): close in without aiming
        g.aiming, F.hold, g.aim_t0 = false, nil, nil
        if g.sol_why == "out_of_range" then F.reach = math.max(cfg.ranged_min_m + 2, d * 0.75); g.sol_why = nil end
        if not F.following then follow_target(F, F.follow, d > 15) end
        return
    end
    if F.following then mcall("move", "stop", F.log); F.following = false end
    -- hold aim (IA_SecondaryAction for crossbows/bows) while engaged
    if acts.secondary then F.hold, F.hold_until = acts.secondary, F.t + 0.3 end
    if not g.aiming then g.aiming, g.aim_t0 = true, F.t end
    if g.aimer.shot then return end -- a bolt is in the air
    if F.unverified_run >= cfg.verify_presses then
        return finish(F, result_of(F, false, "body_error", { why = "shots_not_firing", detail = "ranged presses spawned no projectile" }))
    end
    if F.t < (F.next_press or 0) or not g.sol then return end
    local prm = g.R.read_weapon_params(pawn) or {}
    local ready = prm.full_accuracy or (F.t - g.aim_t0) >= (g.seed.full_accuracy_s or cfg.ranged_aim_s)
    if not ready then return end
    if prm.has_ammo == false then
        return finish(F, result_of(F, false, "not_enough_resources", { why = "no_ammo", detail = "no ammunition equipped for this weapon" }))
    end
    tap(F, acts.primary, cfg.tap_frames, "shoot")
    local shot = g.aimer:fired(F.t, g.sol, g.R.projectile_ids(), g.muzzle)
    shot.hits0, shot.hit_seq0 = F.hits, C().counts.hits
    F.presses = F.presses + 1
    C().counts.presses = C().counts.presses + 1
    local prof = F.profile or {}
    F.next_press = F.t + (prof.reload_s or 1.0) + 0.3 + jitter(cfg.press_jitter_ms)
end
M._step_ranged = step_ranged

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
            if close then return start_defend(F, me, id, tt, (c.tele_info or {})[id]) end
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
    -- the model chose a style (e.g. the weapon's special action): press that one each time
    local se = F.style_entry
    if se and (se.input == "special" or se.input == "primary") and acts[se.input] and se.style ~= "visceral" then
        local tim = (se.input == "special" and spec) or prim
        if se.needs == "airborne" then pcall(function() pawn:Jump() end) end
        if (me.stamina or 0) < cfg.stamina_reserve + (prim.stam or 0) then F.next_press = F.t + 0.3; return end
        tap(F, acts[se.input], cfg.tap_frames, se.style)
        F.next_press = F.t + ((tim and tim.next_ms) or 900) / 1000 + jitter(cfg.press_jitter_ms)
        F.presses = F.presses + 1
        C().counts.presses = C().counts.presses + 1
        F.pending_press = { t = F.t, stamina = me.stamina, hits = F.hits, err = err }
        return
    end
    -- special: charge covers it, target is worth it, not too often
    if spec and spec.cost and acts.special and F.cap and F.cap.special_ok and (me.special or 0) >= spec.cost and F.t - (F.last_special or -99) >= cfg.special_gap_s
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
        if F.loot_item then
            F.looted = (F.looted or 0) + 1; C().counts.loot = C().counts.loot + 1
            F.loot_names[#F.loot_names + 1] = { name = F.loot_item.name or F.loot_item.id, count = F.loot_item.count or 1 }
        end
        F.loot_item = nil
        local best, bd
        for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do
            local id = U.short(w)
            local p = U.loc(w)
            if id and p and not F.items_before[id] and not F.loot_skip[id] and F.death_pos and U.dist(p, F.death_pos) <= cfg.loot_radius_m * 100 then
                local d = me.pos and U.dist(p, me.pos) or 0
                if not bd or d < bd then
                    best, bd = { actor = w, id = id, pos = p, t = F.t, presses = 0,
                                 name = text(U.try(function() return w.ItemData.Name end)),
                                 count = num(U.try(function() return w:GetStackSize() end)) }, d
                end
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
    M.emit_combat_end(F, F.result) -- a file write only
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
    if F.def and not F.def.started then defend_act(F, pawn, actions(pawn)) end
    if F.def and F.def.cast then defend_followup(F, pawn, actions(pawn)) end
    F.frame_n = (F.frame_n or 0) + 1
    if F.rg then ranged_frame(F, pawn) end
    -- per frame: held movement keys first (a directional evade samples them), then the queued taps
    if F.move_inject then
        if F.t < (F.move_until or 0) then
            local am = actions(pawn).movement
            if am then inject(am, F.move_inject) end
        else F.move_inject = nil end
    end
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
    if F.evade_until and F.t >= F.evade_until then F.evade_dir, F.evade_until = nil, nil end
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
    F.me_pos, F.hp_now, F.me_last = me.pos, me.hp, me
    if not F.lat_t or F.t - F.lat_t > 5 then -- one-way latency for timed defence
        F.lat_t = F.t
        local ping = num(U.try(function() return pc.PlayerState:GetPingInMilliseconds() end))
        if ping and ping > 0 then F.latency = ping / 2000 end
    end
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
            F.mode == "attack" and { commanded = true, force = F.force, avoid = {}, flee_hp = M.orders.flee_hp } or M.orders, F.decision, M.cfg)
        F.assessment = a
        if a.decision == "flee" then return begin_flee(F, a.why) end
        F.decision = "fight"
        -- low HP but winnable: back off and eat first (the model's policy: orders.disengage / heal_hp)
        local frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1
        if M.orders.disengage ~= false and not F.dis and (F.phase == "engage" or F.phase == "approach")
            and frac < (M.orders.heal_hp or 0.5) and not F.no_food and (F.eat_fails or 0) < 3 and F.t - (F.dis_end or -99) > 10 then
            local list = mcall("inventory", "list", F.log) or {}
            if M.best_heal_food(list) then
                F.dis = { step = "back", t = F.t }
                F.n_disengage = (F.n_disengage or 0) + 1
                return set_phase(F, "disengage", string.format("hp %.0f%% < %.0f%%", frac * 100, (M.orders.heal_hp or 0.5) * 100))
            end
            F.no_food = true
        end
    end
    if F.phase == "approach" or F.phase == "disengage" then
        for id, tt in pairs(c.telegraphs) do
            if F.t - tt <= M.cfg.telegraph_fresh_s and tt > (F.last_tele or 0) and id == F.target_id and (F.dist_m or 99) <= M.cfg.telegraph_m then
                F.dis = nil
                return M._start_defend(F, me, id, tt, (c.tele_info or {})[id])
            end
        end
    end
    if F.phase == "react" then
        if F.t >= F.react_until then set_phase(F, "equip") end
    elseif F.phase == "equip" then
        if step_equip(F, pawn) then
            local r, l = held_items(pawn)
            F.cap = M.capabilities(pc, r, l)
            if F.profile and F.profile.kind == "ranged" then
                local ok, why = ranged_setup(F, pawn, pc)
                if not ok then
                    return finish(F, result_of(F, false, why == "no_ammo" and "not_enough_resources" or "body_error",
                        { why = why, detail = "ranged weapon not ready: " .. tostring(why) }))
                end
            end
            if F.style and F.style ~= "auto" then
                local a, bad = M.check_style(F.style, pawn, pc)
                if not a then return finish(F, bad) end
                F.style_entry = a
            end
            say(F.log, string.format("can block %s (%s) parry %s (perk %s) special %s (perk %s)", tostring(F.cap.can_block), tostring(F.cap.block_item),
                tostring(F.cap.can_parry), tostring(F.cap.parry_perk), tostring(F.cap.special_ok), tostring(F.cap.special_perk)))
            set_phase(F, "approach")
        end
    elseif F.phase == "approach" then
        if tgt and tgt.distance_m and tgt.distance_m > M.cfg.lost_m then
            F.far_since = F.far_since or F.t
            if F.t - F.far_since > M.cfg.lost_s then return finish(F, result_of(F, false, "too_far", { dist_m = tgt.distance_m })) end
        else F.far_since = nil end
        if not F.following then follow_target(F, F.follow, (F.dist_m or 0) > 8) end
        if F.dist_m and F.dist_m <= F.reach then set_phase(F, "engage") end
    elseif F.phase == "engage" then
        if F.rg then step_ranged(F, pawn, me, acts, tgt) else step_engage(F, pawn, me, acts, tgt) end
        if F.dist_m and F.dist_m > F.reach * 3 then set_phase(F, "approach", "target moved away") end
    elseif F.phase == "defend" then
        step_defend(F, pawn, me, acts)
    elseif F.phase == "disengage" then
        step_disengage(F, pawn, me, acts)
        if not F.dis then F.dis_end = F.t end
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
    -- (re)register when any hook of this version is missing (a hot reload may add hooks) or the
    -- dispatch table belongs to an older load
    local missing = not (c.hooks_started and c.handlers) or c.handlers.on_damage ~= M.on_damage
    for _, h in ipairs(M.HOOKS) do if not c.hooks[h.path] then missing = true end end
    if missing then c.hooks_started = true; M.hooks_start(log) end
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
    -- a commanded fight is the model's call (North Star review): the fight-or-flight estimate is
    -- returned as INFORMATION, never as a refusal; only "never attack players" is a hard gate
    local estimate = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = 12 }, { tgt }, { reflexonly = true }, nil, M.cfg)
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
                hit_seq = c.counts.hits, phase_log = {}, items_before = {}, loot_skip = {}, why = opts.why,
                by = opts.by or (opts.mode == "reflex" and "reflex" or "debug"), hp_start = tgt.hp, loot_names = {},
                style = opts.style, weapon_pref = opts.weapon }
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
    return { ok = true, data = { target = tgt.name, target_id = tgt.id, distance_m = tgt.distance_m, enemy_pl = tgt.pl, my_pl = me.pl, hp = tgt.hp,
             assessment = { verdict = estimate.verdict, u_fight = estimate.u_fight and math.floor(estimate.u_fight * 100) / 100,
                            est_s_to_kill = estimate.my_ttk and math.floor(estimate.my_ttk), est_s_to_die = estimate.their_ttk and math.floor(estimate.their_ttk),
                            pl_gap = estimate.pl_gap } } }
end
M._start_fight = start_fight

function M.attack(log, target, opts)
    opts = opts or {}
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    local actor = M.resolve_target(target, U.loc(pawn))
    if not actor then return { ok = false, reason = "unknown_target", data = { target = tostring(target) } } end
    return start_fight(log, actor, { mode = "attack", force = opts.force, why = "commanded", by = opts.by or "debug", style = opts.style,
                                     weapon = opts.weapon })
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
        elseif k == "abilities" and type(v) == "table" then
            M.orders.abilities = M.orders.abilities or {}
            for name, on in pairs(v) do M.orders.abilities[name] = on end
        elseif M.orders[k] ~= nil or k == "stance" or k == "flee_hp" or k == "protect" then M.orders[k] = v end
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
               weapon = f.equip_plan and f.equip_plan.weapon, assessment = f.assessment,
               ranged = f.rg and { key = f.rg.key, shots = f.rg.shots, hits = f.rg.hits, last = f.rg.last, aiming = f.rg.aiming,
                                   solution = f.rg.sol and { tau = f.rg.sol.tau, pitch = f.rg.sol.pitch, range_m = f.rg.sol.range_cm and f.rg.sol.range_cm / 100 } or f.rg.sol_why } or nil, injected = f.injected, phase_log = f.phase_log,
               age_s = f.t and f.t0 and math.floor((f.t - f.t0) * 10) / 10 }
    end
    local learned = {}
    for k, v in pairs(c.learned) do learned[k] = v end
    return { ok = true, fight = fs, last = c.last, guard = c.guard ~= nil, guard_last = c.guard_last, guard_err = c.guard_err,
             hook_err = c.hook_err, counts = c.counts, on_target = c.on_target, orders = M.orders, learned = learned, lines = c.log_lines,
             hooks = (function() local n = 0; for _ in pairs(c.hooks) do n = n + 1 end; return n end)() }
end

-- ------------------------------------------------------------------ the held items' own actions
-- Every held item carries its actions in its item data (UHeldEquipmentData: PrimaryActionClass,
-- SpecialActionClass, SecondaryActionClass, PrimarySprintActionClass, PrimaryJumpActionClass,
-- PrimaryVisceralActionClass). Each action's CDO (UPlayerAction) has its display name (ActionName,
-- e.g. "Chop" / "Overhead Chop" on the Mithril Logging Axe), RequiredPerk and bRequiresHolding.
-- They are read live (patch-proof) and offered to the model as STYLES; the model picks one from
-- these names and the player's tips. Nothing here says which style suits what.
M.ACTION_SLOTS = {
    { style = "primary", field = "PrimaryActionClass", input = "primary" },
    { style = "special", field = "SpecialActionClass", input = "special" },
    { style = "secondary", field = "SecondaryActionClass", input = "secondary", hold = true },
    { style = "sprint", field = "PrimarySprintActionClass", input = "primary", needs = "sprinting" },
    { style = "jump", field = "PrimaryJumpActionClass", input = "primary", needs = "airborne" },
    { style = "visceral", field = "PrimaryVisceralActionClass", input = "primary", needs = "after a parry" },
}

local function perk_unlocked(pc, perk)
    if not U.valid(perk) then return true end
    local spc = U.try(function() return pc.SkillPerkComponent end)
    if not U.valid(spc) then return false end
    local ok, v = pcall(function() return spc:IsPerkUnlocked(perk) end)
    return ok and v == true
end

-- -> {item, item_name, hand, actions = {{style, name, input, hold, needs, perk, unlocked, dmg, stamina}}}
function M.held_actions(pawn, pc)
    pc = pc or local_pc()
    pawn = pawn or (pc and U.try(function() return pc.Pawn end))
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    local eq = U.try(function() return pawn.PlayerEquipmentComponent end)
    local right = U.valid(eq) and U.try(function() return eq:GetHeldEquipmentDataRight() end)
    local left = U.valid(eq) and U.try(function() return eq:GetHeldEquipmentDataLeft() end)
    local main = U.valid(right) and right or (U.valid(left) and left or nil)
    local out = { ok = true, actions = {} }
    if not main then out.item = nil; out.detail = "nothing held (bare hands)"; return out end
    out.item = (U.path_of(main) or ""):match("%.([%w_]+)$")
    out.item_name = text(U.try(function() return main.Name end))
    out.hand = main == right and "right" or "left"
    local prof = (M.weapons().items or {})[out.item or ""] or {}
    for _, s in ipairs(M.ACTION_SLOTS) do
        local src = main
        if s.style == "secondary" and U.valid(left) and left ~= main then src = left end -- a shield's block
        local cls = U.try(function() return src[s.field] end)
        local cdo = U.valid(cls) and U.try(function() return cls:GetCDO() end)
        if U.valid(cdo) then
            local name = text(U.try(function() return cdo.ActionName end)) or text(U.try(function() return cdo.PromptText end))
            local perk = U.try(function() return cdo.RequiredPerk end)
            local a = { style = s.style, name = name or s.style, input = s.input, hold = s.hold or U.try(function() return cdo.bRequiresHolding end) == true or nil,
                        needs = s.needs, perk = U.valid(perk) and U.short(perk) or nil, unlocked = perk_unlocked(pc, perk),
                        action_class = U.short(cls) }
            if s.style == "primary" and prof.prim then a.dmg, a.stamina, a.every_s = prof.prim.dmg, prof.prim.stam, prof.prim.next_ms and prof.prim.next_ms / 1000 end
            if s.style == "special" and prof.spec then a.dmg, a.charge_cost, a.every_s = prof.spec.dmg, prof.spec.cost, prof.spec.next_ms and prof.spec.next_ms / 1000 end
            if s.style == "secondary" and U.valid(cdo) then
                a.can_parry = U.try(function() return cdo.bCanParry end) == true or nil
                local pp = U.try(function() return cdo.SkillPerkRequiredToParry end)
                if a.can_parry then a.parry_perk, a.parry_unlocked = U.valid(pp) and U.short(pp) or nil, perk_unlocked(pc, pp) end
            end
            out.actions[#out.actions + 1] = a
        end
    end
    return out
end

-- A style the model asked for -> the action entry, matching the slot name ("primary", "special", ...)
-- or the action's own display name, case-insensitive ("Overhead Chop", "overhead").
function M.resolve_style(held, style)
    if style == nil or style == "" then return nil end
    local want = tostring(style):lower()
    local acts = (held and held.actions) or {}
    for _, a in ipairs(acts) do if a.style == want then return a end end
    for _, a in ipairs(acts) do if (a.name or ""):lower() == want then return a end end
    for _, a in ipairs(acts) do if (a.name or ""):lower():find(want, 1, true) then return a end end
    return nil, "no_such_style"
end

local function styles_text(held)
    local parts = {}
    for _, a in ipairs((held and held.actions) or {}) do
        parts[#parts + 1] = string.format("%s = %s%s", a.style, tostring(a.name), a.unlocked == false and (" (locked: " .. tostring(a.perk) .. ")") or "")
    end
    return table.concat(parts, "; ")
end
M.styles_text = styles_text

-- Validate a requested style for the held item. -> entry | nil, failure result
function M.check_style(style, pawn, pc)
    if style == nil or style == "" or style == "auto" then return nil end
    local held = M.held_actions(pawn, pc)
    local a = M.resolve_style(held, style)
    if not a then
        return nil, { ok = false, reason = "invalid_args", data = { why = "no_such_style", style = style, item = held.item_name,
            styles = held.actions, detail = string.format("My %s has no '%s' action. It has: %s.", tostring(held.item_name or "hands"),
            tostring(style), styles_text(held)) } }
    end
    if a.unlocked == false then
        return nil, { ok = false, reason = "not_unlocked", data = { why = "perk_locked", style = a.style, name = a.name, perk = a.perk,
            detail = string.format("I can't do %s yet; it needs the %s perk.", tostring(a.name), tostring(a.perk)) } }
    end
    return a
end

-- One-off use of a held item's action (a swing to show Luis, one overhead chop...). Real inputs:
-- a tap of the action's input (held ~0.8 s for a holding action like block); a jump style jumps
-- first. Takes the pawn at command level for the short press. Verified by stamina spent or the
-- action's montage starting. -> async {pending}.
function M.use_action(log, style, opts)
    opts = opts or {}
    if _G.DW_PAUSE then return { ok = false, reason = "companion_down" } end
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    local a, bad = M.check_style(style or "primary", pawn, pc)
    if not a then return bad end
    if a.needs == "sprinting" or a.needs == "after a parry" then
        return { ok = false, reason = "not_implemented", data = { why = "context_action", style = a.style, name = a.name,
            detail = string.format("%s only happens %s; I can't do it on its own.", tostring(a.name), a.needs) } }
    end
    local acts = actions(pawn)
    local input = acts[a.input]
    if not input then return { ok = false, reason = "body_error", data = { detail = "no input for " .. tostring(a.input) } } end
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "use_action", level = "command", resumable = false, uses_move = false, lease_s = 5 })
        if not r.ok then return { ok = false, reason = "interrupted", data = { detail = "pawn busy", owner = r.owner } } end
        token = r.token
    end
    local st0 = U.try(function() return pawn.StaminaComponent:GetStamina() end)
    local sp0 = U.try(function() return pawn.SpecialChargeComponent:GetSpecialCharge() end)
    local ai = U.try(function() return pawn.Mesh:GetAnimInstance() end)
    local m0 = U.valid(ai) and U.short(U.try(function() return ai:GetCurrentActiveMontage() end)) or nil
    local U_ = { t0 = now(pawn), frames = 0, done = false, style = a.style, name = a.name }
    local hold_frames = a.hold and 80 or M.cfg.tap_frames
    if a.needs == "airborne" then pcall(function() pawn:Jump() end) end
    local start_frame = a.needs == "airborne" and 15 or 0
    local function close(res)
        if U_.done then return end
        U_.done = true
        if U_.handle then pcall(CancelDelayedAction, U_.handle) end
        if a.needs == "airborne" then pcall(function() pawn:StopJumping() end) end
        if arb and token then pcall(arb.release, log, token, res.ok and "done" or res.reason) end
        U_.result = res
        say(log, string.format("use_action %s (%s) -> %s %s", tostring(a.style), tostring(a.name), tostring(res.ok), tostring(res.reason or "")))
    end
    U_.handle = LoopInGameThreadWithDelay(1, function()
        if _G.DW_PAUSE then return close({ ok = false, reason = "interrupted", data = { detail = "world teardown" } }) end
        local ok = pcall(function()
            if not U.valid(pawn) then return close({ ok = false, reason = "companion_down" }) end
            U_.frames = U_.frames + 1
            local f = U_.frames - start_frame
            if f >= 1 and f <= hold_frames then inject(input) end
            local t = now(pawn)
            if f > hold_frames and not U_.checked and t - U_.t0 >= 0.6 then
                local st = U.try(function() return pawn.StaminaComponent:GetStamina() end)
                local m = U.valid(ai) and U.short(U.try(function() return ai:GetCurrentActiveMontage() end)) or nil
                local sp = U.try(function() return pawn.SpecialChargeComponent:GetSpecialCharge() end)
                local spent = (st0 and st and st < st0 - 0.5) or (sp0 and sp and sp < sp0 - 0.5)
                local montage = m and m ~= m0
                U_.checked = true
                if spent or montage or a.hold then
                    close({ ok = true, data = { style = a.style, name = a.name, stamina_spent = (st0 and st) and (st0 - st) or nil,
                                                   charge_spent = (sp0 and sp) and (sp0 - sp) or nil, montage = m } })
                else
                    close({ ok = false, reason = "verification_failed", data = { style = a.style, name = a.name,
                        detail = string.format("I pressed %s but nothing happened.", tostring(a.name)) } })
                end
            end
            if t - U_.t0 > 4 then close({ ok = false, reason = "timeout" }) end
        end)
        if not ok then close({ ok = false, reason = "body_error" }) end
    end)
    C().use_action = U_
    return { ok = true, pending = U_ }
end

-- ------------------------------------------------------------------ combat brief (facts for the model)
-- Everything the model needs to PREPARE for a fight, as information only (the model decides the prep:
-- weapon, shield, enchant, buffs, food, or not fighting at all). Sources, strongest first:
-- live game data -> what Claude learned from his own hits -> the game's journal entry (Weaknesses)
-- -> the creature_priors data file (wiki research). Nothing is decided here.
local function journal_weaknesses(name)
    if not name then return nil end
    local want = name:lower()
    for _, j in ipairs(U.find_all("JournalEntryWorldData", { skip_defaults = true })) do
        local dn = text(U.try(function() return j.DisplayName end))
        if dn and (dn:lower() == want or dn:lower():find(want, 1, true)) then
            local w = {}
            pcall(function() j.Weaknesses:ForEach(function(_, t) local x = text(U.try(function() return t:get() end)); if x then w[#w + 1] = x end end) end)
            return w, dn
        end
    end
    return nil
end

function M.combat_brief(log, target, ctx)
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "companion_down" } end
    local origin = U.loc(pawn)
    local actor = M.resolve_target(target, origin)
    if not actor then return { ok = false, reason = "unknown_target", data = { target = tostring(target) } } end
    local cr = read_creature(actor, origin)
    local me = read_me(pawn, pc)
    local out = { ok = true, data = {} }
    local d = out.data
    d.creature = { id = cr.id, name = cr.name, power_level = cr.pl, hp = cr.hp, max_hp = cr.max_hp, boss = cr.boss,
                   attitude = ({ [0] = "hostile", "defensive", "passive", "bird", "neutral_until_attacked" })[cr.archetype or -1],
                   in_combat = cr.in_combat or nil, distance_m = cr.distance_m and math.floor(cr.distance_m * 10) / 10 }
    d.me = { power_level = me.pl, hp = me.hp, max_hp = me.max_hp, stamina = me.stamina }
    -- weaknesses / resistances by source
    local wk = { live = read_affinities(actor), learned = C().learned[(cr.name or ""):lower()] }
    local jw, jname = journal_weaknesses(cr.name)
    if jw then wk.journal = jw; wk.journal_entry = jname end
    for key, pr in pairs(M.PRIORS) do
        if (cr.name or ""):lower():find(key, 1, true) then wk.priors = pr end
    end
    d.weaknesses = wk
    -- his weapons vs this creature
    local list = mcall("inventory", "list", log) or {}
    local items = M.weapons().items or {}
    d.weapons = {}
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do
            local p = e.item and items[e.item]
            if p and (p.role == "weapon" or p.role == "shield") then
                local aff = {}
                for _, tag in ipairs(p.types or {}) do aff[tag] = M.affinity({ name = cr.name, affinities = wk.live }, tag, C().learned) or "neutral" end
                d.weapons[#d.weapons + 1] = { item = e.item, name = p.name, kind = p.kind, role = p.role, power_level = p.pl,
                    damage_types = p.types, vs_target = aff, dps = M.dps(p) and math.floor(M.dps(p) * 10) / 10 or nil,
                    block = p.block, ammo = p.ammo, where = where }
            end
        end
    end
    -- spells that buff, defend or fight (from the spells module's own list, when the bridge api is there)
    local sp = mod("spells")
    if sp and sp.HANDLERS and sp.HANDLERS.spells and ctx and ctx.api then
        local ok, r = pcall(sp.HANDLERS.spells, log, {}, ctx)
        local roles = sp.catalog_roles and sp.catalog_roles() or {}
        if ok and type(r) == "table" and r.data and r.data.spells then
            d.spells = {}
            for _, row in ipairs(r.data.spells) do
                local role = row.role or roles[row.id or ""]
                if role == "weapon_buff" or role == "combat_defence" or role == "combat_cc" or role == "combat_damage" then
                    d.spells[#d.spells + 1] = { name = row.name, role = role, use_when = row.use_when, castable = row.castable,
                                                reason = row.reason, remaining_s = row.remaining_s }
                end
            end
        end
    end
    -- food that heals
    d.food = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do
            if e.consumable == "food" and (e.heal or 0) > 0 then d.food[#d.food + 1] = { item = e.item, name = e.name, heal = e.heal, count = e.count } end
        end
    end
    -- the estimate, as information
    local a = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = 12 }, { cr }, { reflexonly = true }, nil, M.cfg)
    d.assessment = { verdict = a.verdict, est_s_to_kill = a.my_ttk and math.floor(a.my_ttk), est_s_to_die = a.their_ttk and math.floor(a.their_ttk),
                     pl_gap = a.pl_gap }
    -- what Claude has learned about this creature's attacks (per attack key)
    local D = mod("defense")
    d.attacks_learned = {}
    for key, r in pairs(D and D.status().attacks or {}) do
        if key:find((cr.name or "?") .. ":", 1, true) == 1 then
            d.attacks_learned[#d.attacks_learned + 1] = { attack = key, impact_s = r.impact_s, damage = r.damage, lunge_cm = r.lunge_cm,
                parried = r.parried, blocked = r.blocked, hit = r.hit, avoided = r.avoided }
        end
    end
    d.orders = M.orders
    return out
end

-- get_state extras (client_bridge calls state_extras on every module): what his hands can do.
-- Cached 3 s, or until the held item changes, so get_state stays cheap.
function M.state_extras(api, data)
    local c = C()
    local pc = local_pc()
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return {} end
    local eq = U.try(function() return pawn.PlayerEquipmentComponent end)
    local r = U.valid(eq) and U.short(U.try(function() return eq:GetHeldEquipmentDataRight() end)) or ''
    local l = U.valid(eq) and U.short(U.try(function() return eq:GetHeldEquipmentDataLeft() end)) or ''
    local key = r .. '|' .. l
    local t = os.time()
    if not (c.extras and c.extras.key == key and t - c.extras.t < 3) then
        local h = M.held_actions(pawn, pc)
        h.ok = nil
        c.extras = { key = key, t = t, v = h }
    end
    return { held_actions = c.extras.v }
end

-- Module functions each tool needs (the bridge offers a tool only when they exist).
M.NEEDS = {
    attack = { { 'inventory', 'list' }, { 'inventory', 'equip' }, { 'move', 'follow' } },
    use_action = { { 'arbiter', 'request' } },
}

-- ------------------------------------------------------------------ bridge module handlers
-- attack: an async action ({pending = a}); the bridge pre-empts other actions (attack is in ACTION_TOOLS).
M.HANDLERS = {
    attack = function(log, args, ctx)
        if type(args.target) ~= "string" or args.target == "" then
            return { ok = false, reason = "invalid_args", data = { detail = "target is required (entity id or creature name)" } }
        end
        local r = M.attack(log, args.target, { force = args.force == true, by = "brain", style = args.style, weapon = args.weapon })
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
    held_actions = function() return M.held_actions() end,
    combat_brief = function(log, args, ctx)
        if type(args.target) ~= "string" or args.target == "" then
            return { ok = false, reason = "invalid_args", data = { detail = "target is required (creature id or name)" } }
        end
        return M.combat_brief(log, args.target, ctx)
    end,
    use_action = function(log, args, ctx)
        local r = M.use_action(log, args.style or "primary", args)
        if not r.ok then return r end
        local U_ = r.pending
        local a = { kind = "use_action", id = ctx and ctx.id, timeout_s = 8 }
        a.poll = function() return U_.result end
        return { pending = a }
    end,
}

-- Capability contract entries for these tools (they win over manifest.lua's; see its header).
-- Kept short (prompt budget: about 350 characters per tool); tips and edge cases are in failure details.
do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    local STYLE = { type = "string", description = "A held item's action: primary, special, secondary, jump, or its name (held_actions)." }
    M.MANIFEST = {
        attack = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 30, timeout_s = 150,
            detail_is_speech = true,
            description = "Fight a creature until it dies, defending per combat_orders (never players). data.assessment estimates the fight.",
            args = { type = "object", required = { "target" }, properties = obj({
                target = { type = "string", description = "Creature id, or a name (nearest)." },
                weapon = { type = "string", description = "Carried item to fight with, e.g. a crossbow; default best melee." },
                style = STYLE,
                force = { type = "boolean", default = false, description = "Ignore flee_hp for this fight." } }) },
            ground = obj({ target = "creature" }),
            reasons = { "unknown_target", "too_far", "interrupted", "timeout", "not_unlocked", "invalid_args", "not_enough_resources", "companion_down", "body_error" } },
        use_action = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 2, timeout_s = 8,
            detail_is_speech = true,
            description = "Use one of your held item's actions once (a swing, a block, the special), e.g. to show the player.",
            args = { type = "object", properties = obj({ style = STYLE }) },
            reasons = { "invalid_args", "not_unlocked", "not_implemented", "verification_failed", "interrupted", "companion_down" } },
        held_actions = { kind = "read", llm = true, moves = false, duration_s = 0, timeout_s = 5,
            description = "The actions of what you hold, from item data: style, name (e.g. Chop, Overhead Chop), perk, unlocked, damage.",
            args = { type = "object", properties = obj() } },
        combat_orders = { kind = "waiter", llm = true, moves = false, duration_s = 0, timeout_s = 5,
            description = "Set your standing combat policy, kept until changed.",
            args = { type = "object", properties = obj({
                stance = { type = "string", enum = { "defensive", "aggressive", "passive", "flee" } },
                defense = { type = "string", enum = { "auto", "parry", "block", "dodge", "none" } },
                abilities = { type = "object", description = "Spells the reflex may use: {phase_dash, windstep, tempest_shield} true/false." },
                allow_jump = { type = "boolean" }, disengage = { type = "boolean", description = "Back off and eat when hurt." },
                heal_hp = { type = "number", minimum = 0, maximum = 1 }, reengage_hp = { type = "number", minimum = 0, maximum = 1 },
                flee_hp = { type = "number", minimum = 0, maximum = 1 }, protect = { type = "string" },
                avoid = { type = "array", items = { type = "string" } } }) } },
        combat_brief = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Facts to prepare a fight: power levels, the creature's weaknesses, your weapons vs it, usable buff/defence "
                .. "spells, healing food, the estimate, its learned attacks.",
            args = { type = "object", required = { "target" }, properties = obj({
                target = { type = "string", description = "Creature id, or a name (nearest)." } }) },
            ground = obj({ target = "creature" }) },
        combat_status = { kind = "probe", llm = false, timeout_s = 5, description = "Combat state (debug).", args = { type = "object", properties = obj() } },
    }
end

return M
