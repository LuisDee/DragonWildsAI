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
-- Engage-loop precedent (Minecraft API/physics are not used here):
-- https://github.com/PrismarineJS/mineflayer-pvp
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
    reserve_wait_s = 5,      -- ... but held back by it this long (or for a finishing blow) a swing goes ahead on what he has
    flee_hp = 0.35,          -- hard veto: below this HP fraction, flee
    eat_hp = 0.55,           -- while fleeing / after a fight: eat food that heals below this
    fight_enter = 0.5,       -- utility to start fighting / to keep fighting (hysteresis)
    fight_stay = 0.4,
    pl_gap_flee = 2,         -- enemy power level - mine >= this: too strong, unless his own numbers say he wins it
    pl_gap_hard = 4,         -- ... and at this gap, too strong whatever the numbers (they extrapolate badly that far)
    max_hostiles = 2,        -- more simultaneous hostiles than this: flee
    lost_m = 40, lost_s = 5, -- target farther than lost_m for lost_s: give up
    resolve_m = 60,          -- attack "<name>": the nearest living one within this
    fight_timeout_s = 120,
    special_hp_factor = 2,   -- use the special only on targets with >= this many normal swings of HP
    special_gap_s = 6,
    telegraph_m = 6, telegraph_fresh_s = 1.0,
    disengage_m = 10,        -- back off this far to eat (orders.disengage)
    magic_base_dmg = 10, eat_every_s = 8, attempts_max = 20, -- odds: rune damage prior; the game's eating pace; boss attempts kept
    -- (boss fight priors: client_mod/scripts/boss_profiles.lua; item traits: item_traits.lua)
    ai_action_resolve_s = 3, -- an AI action older than this is never resolved (it has ended; its creature may be gone)
    hazard_s = 0.25, hazard_window_s = 15, hazard_persist_s = 30, hazard_margin_cm = 40, -- ground hazards (gap 2)
    status_s = 0.5, cure_at = 0.05, no_cure_recheck_s = 10,
    trend_s = 6, trend_min_s = 3, danger_ttl_s = 15, danger_win_margin = 0.8, -- losing fast: ttl < 15 s and win > 0.8 x ttl
    tool_jobs = { fishing = "fish", gather = "gather", farm = "tend", agility = "agility" }, -- module -> its arbiter name prefix
    ambient = nil, ambient_status_s = 2.0, -- out-of-fight hazards/cures: nil = env DW_COMBAT_AMBIENT ("1" = on); off by default -- statuses read every status_s in a fight; a harmful one above cure_at x max -> its cure
    threat_scan_s = 2, threat_repeat_s = 60, -- threat_seen: hostiles in sight not rated a likely win (pack counted), out of a fight
    odds_m = 40, odds_max = 6, facts_s = 30, census_s = 0.5, world_id_s = 60, odds_prep_s = 10, -- get_state fight_odds: creatures in sight
    -- fight odds, calibrated on his own fights of 16-18 Nov 2026 (105 reflex fights with the odds said at their start,
    -- 215 fights' intake; fitted on 16 Nov, tested on 17-18 Nov; tools/fight_odds_truth.py measures it again):
    odds_t0_s = 1,             -- reaching it and the first swing (paid once, not mid-fight)
    odds_uptime = 0.5,         -- a weapon's real damage rate = hit / press cadence x this (he defends, closes in, waits)
    odds_uptime_hands = 0.15,  -- bare hands (3 fights: 0.6-1.2 dealt per s vs ~9 by hit / cadence)
    odds_hands_hit = 8,        -- a punch, until he has landed his own (measured: 90 HP in 11 presses)
    odds_pack_slow = 1.5,      -- n hostiles: kill time x n^this on top of their summed HP (packs took 3-10x longer)
    odds_landed_per_s = 0.024, -- intake per attacker = the game's mean attack damage x this (blocks, misses, gaps)
    odds_kill_band = { 0.85, 2.7 }, odds_die_band = { 0.35, 1.6 }, -- measured 20th-80th percentile of real / estimate
    odds_learn_n = 2, odds_learn_min_s = 8, -- his own record replaces a prior after this many fights (intake: this long)
    memory_enabled = true, history_max = 10, steam_manifest = "C:/Program Files (x86)/Steam/steamapps/appmanifest_1374490.acf",
    chase_moved_m = 3, -- a stall while the target itself moved this far = it is running, not a wall
    chase_max_s = 30, -- approaching (all episodes) this long without landing a hit: too_far, cant_catch
    chase_per_m_s = 0.5, -- and this much longer for each metre he starts away: the walk to a rat 58 m off up a hill is no chase
    approach_stall_s = 12, approach_gain_m = 0.5, -- approach: no 0.5 m gain for 12 s = blocked (path_blocked)
    impact_attrib_s = 0.8, max_retargets = 4, -- an HP drop this soon after a creature's impact event is its hit
    -- he swings at what he can reach (M.swap_target): the target out of reach this long, or this many swings in a row
    -- that landed nothing, while a creature that attacked him stands within swap_m on his level
    swap_out_s = 2.5, swap_dry_presses = 3, swap_m = 4, swap_dz_cm = 100, max_swaps = 8,
    conversation_retry_s = 2.0, conversation_leave_s = 5.0, -- leaving an NPC dialogue for a fight (talk finding 8)
    move_axes = "xy",
    ranged_max_m = 25,       -- ranged: shoot from up to this far (shrinks when out of the projectile's range)
    ranged_keep_m = 12,      -- ... and close in to about this when farther
    ranged_min_m = 4,
    ranged_aim_s = 1.0,      -- aim this long when the game's full-accuracy flag is unreadable
    ranged_aim_z = 0,        -- aim height above the target's actor origin (capsule centre), cm
    magic_aim_s = 0.25,      -- staff/wand: settle the aim this long before each cast        -- IA_Movement axes: "xy" = X right, Y forward (UE template); "yx" swaps them
    disengage_s = 25,        -- give the heal this long before re-assessing
    lock_on = true,
    -- a step-in has to close the gap: step_in_stall_s of it without step_in_gain_m nearer = something is between us
    -- (a ledge, a rock), so the follow (it plans round and jumps) takes over for step_in_off_s; engage_far_s out of
    -- reach in a row = back to approach, whose blocked rule ends it with the reason. Rung 5 Ratcatcher 20261116-065655:
    -- a rat 3 m off on a 1.5 m ledge, the step-in stopped the follow and pushed at the ledge for 63 s (and 24.5 s in
    -- the next fight), the fight ended "timeout" with nothing said
    step_in_stall_s = 1.0, step_in_gain_m = 0.3, step_in_off_s = 5, engage_far_s = 4,
    windup_swing = true, windup_margin_s = 0.15, -- a swing of his own in the wind-up of one he will dodge (M.windup_swing)
    evade_retap_s = 0.17,    -- no evading read this long after the dodge key (5 frames at 30 fps) -> the key once more
    step_in_m = 5, step_in_dz_cm = 150, -- a gap this short on his level (after a dodge) is closed with the movement
    -- input, as a player holds forward; move.follow's stuck/local planner stood ~2 s per gap (live 12:53, a runt:
    -- 36.7 s out of reach, 7 swings in a minute, died)
    nudge = true,            -- turn the body toward the target with a short movement nudge when standing
    face_err_deg = 35,
    loot = true, loot_radius_m = 7, loot_s = 20, loot_max = 6, loot_wait_s = 0.8,
    -- a flee is SHORT and BOUNDED (the MMO / DST "leash": an anchor + a radius; live 2026-11-01 the old 45 s flee
    -- dragged him 134-200 m off route, and fleeing to Luis, who stood next to the goblin, kept him in its reach):
    -- at most flee_leash_m from where it began and flee_timeout_s; still chased there = he can't outrun it, so he
    -- turns and fights. He runs to the protected player only when that player is within flee_ally_m and at least
    -- ally_clear_m from every threat; he eats while fleeing only with every threat at least eat_clear_m away.
    safe_m = 22, safe_s = 4, flee_timeout_s = 15, flee_far_m = 30, flee_leash_m = 25, flee_ally_m = 30, ally_clear_m = 8,
    flee_caught_frac = 0.2, -- lost this share of max HP to threats while running: it is catching him, he fights it
    flee_in_reach_m = 4, outrun_frac = 0.95, -- no flee from a threat within this (or its learned reach) that is this fast vs his sprint
    eat_clear_m = 5, cornered_m = 8, refled_s = 30, -- cornered: still within cornered_m at the bound; a creature that
    -- comes after him again within refled_s of a flee is fought (no second run)
    finish_margin = 0.5,     -- low HP is no reason to run when he kills it in under half the time it needs to kill him
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

-- Gameplay input modes: DIM_Gameplay and its variants (DIM_Gameplay_LockOnTargeting: combat's own lock-on
-- enters it; live skill_routes bug 2026-10-26: "stuck in DIM_Gameplay_LockOnTargeting"). Inputs work there.
function M.is_gameplay_mode(mode)
    return type(mode) == "string" and (mode == "DIM_Gameplay" or mode:sub(1, 13) == "DIM_Gameplay_")
end

-- ------------------------------------------------------------------ data files (one memo loader)
-- client_mod/scripts/<name>.lua returning a table (DATA, never logic); loaded once, false when missing or broken.
local DATA = {}
function M.data(name)
    if DATA[name] == nil then
        local ok, t = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/" .. name .. ".lua"))() end)
        DATA[name] = ok and type(t) == "table" and t or false
    end
    return DATA[name] or nil
end
function M.set_data(name, t) DATA[name] = t end -- tests

-- Provisional weakness priors by creature name (docs/research/2026-10-25-spells-and-weaknesses.md;
-- wiki/gamever, MEDIUM confidence). Live DamageTypeAffinities (empty on the client for Kebbits) and
-- learned hit outcomes override these.
M.PRIORS = M.data("creature_priors") or {} -- data file (client_mod/scripts/creature_priors.lua), not code
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
local LOADER = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua): injectable for tests
M.mods = LOADER.mods
M.set_modules = LOADER.set_modules
local mod, mcall = LOADER.mod, LOADER.mcall

function M.weapons() return M.data("weapons_data") or { items = {} } end
function M.set_weapons(d) M.set_data("weapons_data", d) end

-- ------------------------------------------------------------------ pure decision functions
-- Damage per second of a weapon profile's primary chain (catalog damage / press cadence).
function M.dps(p)
    local pr = p and p.prim
    if not (pr and pr.dmg and pr.next_ms and pr.next_ms > 0) then return nil end
    return pr.dmg / (pr.next_ms / 1000)
end

-- His own damage per second with this weapon (nil profile = bare hands): what his hits with it really did
-- (learned per weapon name from the server's verdicts on his target, persisted), else the catalog's; per press
-- cadence from the weapon's montage data (900 ms for hands, as step_engage presses them). nil = unknown.
function M.my_dps(p)
    local learned = (C().hit_dmg or {})[(p and p.name) or "hands"]
    local pr = p and p.prim
    local dmg = learned or (pr and pr.dmg)
    local ms = (pr and pr.next_ms) or 900
    if not (dmg and ms > 0) then return nil end
    return dmg / (ms / 1000)
end

-- One verified hit of his on the target: learn what a hit with this weapon does (EMA).
function M.learn_hit(F, amount)
    if not (amount and amount > 0 and amount < 10000) then return end
    local c = C()
    c.hit_dmg = c.hit_dmg or {}
    local k = (F.profile and F.profile.name) or "hands"
    local old = c.hit_dmg[k]
    c.hit_dmg[k] = old and (old * 0.7 + amount * 0.3) or amount
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
-- known (optional) = {tag = {v, src}} (combat.known_affinities): used instead of M.affinity, and the first
-- affinity that changed the score is returned as `why` ("stab-weak (journal)").
function M.score_weapon(p, enemy, learned, known)
    if not p or p.kind ~= "melee" or not p.prim then return nil end
    local f = M.TOOL_FACTOR[p.cat]
    if f == 0 then return nil end
    -- his own learned damage with it first (M.my_dps: the server's verdicts on his hits), the catalog only when he has
    -- none: live 2026-11-02 01:16Z a Stone Dagger (catalog 15/s x1.5 stab-weak = 22.5) beat his Bronze Sword (catalog
    -- 16.3, learned 48 a hit = 56/s, 5 rat kills, 0 deaths) and he died to two Giant Rats with it, 0 hits landed
    local s = (M.my_dps(p) or M.dps(p) or 0) * (f or 1)
    local why
    for _, tag in ipairs(p.types or {}) do
        local a, src
        if known then local k = known[tag]; a, src = k and k.v, k and k.src
        else a = M.affinity(enemy, tag, learned) end
        if a == "weak" then s = s * 1.5 elseif a == "resist" then s = s * 0.6 elseif a == "immune" then s = s * 0.05 end
        if a and src and not why then why = (tostring(tag):match("([^%.]+)$") or tag):lower() .. "-" .. a .. " (" .. src .. ")" end
    end
    return s, why
end

-- His record with each weapon against this creature (combat memory history): {item = {n, kills, deaths}}.
function M.weapon_record(enemy, m)
    m = m or C().mem
    local h = m and m.history and enemy and enemy.name and m.history[tostring(enemy.name):lower()] or nil
    local r = {}
    for _, f in ipairs(h or {}) do
        if f.weapon then
            local x = r[f.weapon] or { n = 0, kills = 0, deaths = 0 }
            x.n = x.n + 1
            if f.outcome == "killed" then x.kills = x.kills + 1 elseif f.outcome == "died" then x.deaths = x.deaths + 1 end
            r[f.weapon] = x
        end
    end
    return r
end

-- Best weapon he OWNS (inventory.list entries: hotbar, bag, loadout) for this enemy, and the best
-- shield. -> {weapon = {entry, profile, score}, shield = {entry, profile}} (nil when none).
-- A weapon he has fought this creature with 2+ times and won with more than he died ("proven") beats one that is not,
-- whatever the numbers say: a player keeps the sword he killed 5 rats with (live 2026-11-02 01:16Z, see score_weapon).
function M.best_weapon(list, enemy, data, learned, known, record)
    data = data or M.weapons()
    local items = data.items or {}
    record = record or M.weapon_record(enemy)
    local function proven(item) local x = record[item]; return x ~= nil and x.n >= 2 and x.kills > x.deaths end
    local best, shield, best_proven
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            local p = e.item and items[e.item]
            if p and not e.broken then
                local s, why = M.score_weapon(p, enemy, learned, known)
                if s and (not best or s > best.score + 1e-6) then best = { entry = e, profile = p, score = s, where = where, why = why } end
                if s and proven(e.item) and (not best_proven or s > best_proven.score + 1e-6) then
                    local x = record[e.item]
                    best_proven = { entry = e, profile = p, score = s, where = where,
                                    why = string.format("proven: %d kills, %d deaths in %d fights with it vs %s", x.kills, x.deaths, x.n, tostring(enemy.name)) }
                end
                if p.role == "shield" and (not shield or (p.block or 0) > (shield.profile.block or 0)) then
                    shield = { entry = e, profile = p, where = where }
                end
            end
        end
    end
    if best_proven and best and not proven(best.entry.item) then best = best_proven end
    return { weapon = best, shield = shield }
end

-- Prior damage per second of an enemy we have no damage data for, from its power level (a guess: "unknown").
function M.enemy_dps_prior(pl) return 2 + 2 * math.max(pl or 1, 0) end

-- What his own fights say (combat memory history, persisted; record_fight writes fight_s, pack, dealt, hands):
--   mine[weapon name]  = {rate, n}: his damage per engaged second, from fights with one hostile where he dealt damage
--                        (rate = sum dealt / sum (fight_s - odds_t0_s));
--   theirs[creature]   = {dps, n}: its damage on him per attacker per second, from fights of at least
--                        odds_learn_min_s (a short fight ends before it swings: sum taken / sum (fight_s x pack)).
-- Only rows with odds_learn_n or more fights are returned. -> {mine = {}, theirs = {}}
function M.learned_rates(m)
    m = m or C().mem
    local cfg = M.cfg
    local mine, theirs = {}, {}
    for name, h in pairs(m and type(m.history) == "table" and m.history or {}) do
        local t = { taken = 0, s = 0, n = 0 }
        for _, f in ipairs(type(h) == "table" and h or {}) do
            local fs = tonumber(f.fight_s)
            if fs and fs > 0 then
                local pack = math.max(tonumber(f.pack) or 1, 1)
                if f.hands and pack <= 1 and (tonumber(f.dealt) or 0) > 0 and fs >= 2 then
                    local w = mine[f.hands] or { dealt = 0, s = 0, n = 0 }
                    w.dealt, w.s, w.n = w.dealt + tonumber(f.dealt), w.s + math.max(fs - (cfg.odds_t0_s or 0), 0.5), w.n + 1
                    mine[f.hands] = w
                end
                if fs >= (cfg.odds_learn_min_s or 8) then
                    t.taken, t.s, t.n = t.taken + (tonumber(f.damage_taken) or 0), t.s + fs * pack, t.n + 1
                end
            end
        end
        if t.n >= (cfg.odds_learn_n or 2) and t.s > 0 then theirs[name] = { dps = t.taken / t.s, n = t.n } end
    end
    local out = {}
    for w, x in pairs(mine) do if x.n >= (cfg.odds_learn_n or 2) and x.s > 0 then out[w] = { rate = x.dealt / x.s, n = x.n } end end
    return { mine = out, theirs = theirs }
end

-- His real damage per engaged second with this weapon profile (nil = bare hands); `nominal` overrides the hit / cadence
-- rate (a prepared loadout's weapon vs a weakness). -> rate, source | nil
-- His own record with it first; else hit / press cadence (M.my_dps: his learned hit, else the catalog's; a punch:
-- odds_hands_hit) x the measured uptime. Live 2026-11-18 01:11Z: bare hands read "likely win, 14 s to kill" a 100 HP
-- Giant Rat; he dealt 90 in 74 s and died (hit / cadence alone was ~7x his real rate).
function M.fight_rate(p, nominal)
    local cfg = M.cfg
    local name = (p and p.name) or "bare hands"
    local L = M.learned_rates().mine[name]
    if L and not nominal then return math.max(L.rate, 0.05), string.format("his last %d fights with it", L.n) end
    nominal = nominal or M.my_dps(p) or (not p and (cfg.odds_hands_hit or 8) / 0.9) or M.dps(p)
    if not nominal then return nil end
    return nominal * (p and (cfg.odds_uptime or 1) or (cfg.odds_uptime_hands or 1)), "estimate"
end

-- "40-60 s" for a band of seconds (rounded the way a player says it; over 10 min said so). -> string | nil
function M.band_words(lo, hi)
    if not (tonumber(lo) and tonumber(hi)) then return nil end
    local function r(x)
        if x < 20 then return math.floor(x + 0.5) elseif x < 100 then return math.floor(x / 5 + 0.5) * 5 end
        return math.floor(x / 10 + 0.5) * 10
    end
    local a, b = math.max(r(lo), 1), r(hi)
    if a >= 600 then return "over 10 min" end
    if b > 600 then return string.format("%d s to over 10 min", a) end
    if a >= b then return string.format("about %d s", a) end
    return string.format("%d-%d s", a, b)
end

-- "Goblin Runt x3, Giant Rat" for a list of creature rows (first seen first). -> string | nil
function M.pack_words(list)
    local names, order = {}, {}
    for _, e in ipairs(list or {}) do
        local n = tostring(e.name or "?")
        if not names[n] then names[n] = 0; order[#order + 1] = n end
        names[n] = names[n] + 1
    end
    local words = {}
    for _, n in ipairs(order) do words[#words + 1] = names[n] > 1 and (n .. " x" .. names[n]) or n end
    return #words > 0 and table.concat(words, ", ") or nil
end

-- Fight or flight. me = {hp, max_hp, pl, dps (his real rate: M.fight_rate)}; enemies = {{name, hp, max_hp, pl, boss,
-- dps_obs (per attacker: M.enemy_dps), dps_src}}; orders = M.orders; current = "fight"|"flee"|nil (hysteresis).
-- -> {decision, u_fight, why, verdict, my_ttk, their_ttk, kill_lo/hi, die_lo/hi, unknown, ...}
-- The numbers (calibrated on his own fights, cfg.odds_*; tools/fight_odds_truth.py):
--   time to kill = odds_t0_s + (HP of every hostile counted) x n^odds_pack_slow / his rate (no PL factor: HP is real)
--   time to die  = his HP / (sum of their rates); a hostile with no damage data takes the PL prior and makes the
--                  verdict "unknown" ("no damage data for X")
--   bands        = x odds_kill_band / x odds_die_band (the measured 20th-80th percentile of real / estimate)
--   verdict      = likely_win when even the slow kill beats the fast death, likely_lose the other way, else uncertain
-- The reflex's fight-or-flee decision keeps reading the central times (u_fight); the verdict and the bands are words.
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
    local worst_gap, total_hp, their_dps, boss, unknown = -99, 0, 0, false, nil
    for _, e in ipairs(enemies) do
        if e.boss then boss = true end
        local gap = (e.pl or 1) - my_pl
        if gap > worst_gap then worst_gap = gap end
        total_hp = total_hp + math.max(e.hp or e.max_hp or 50, 1)
        local d = e.dps_obs
        if not d then -- no damage data: the power-level guess, said as such
            d = M.enemy_dps_prior(e.pl) * (1.25 ^ gap)
            unknown = unknown or tostring(e.name or "it")
        end
        their_dps = their_dps + d
    end
    local n = #enemies
    r.pl_gap, r.boss, r.enemies = worst_gap, boss or nil, n
    local my_dps = math.max(me.dps or ((cfg.odds_hands_hit or 8) / 0.9 * (cfg.odds_uptime_hands or 1)), 0.05)
    r.my_ttk = (cfg.odds_t0_s or 0) + total_hp * n ^ (cfg.odds_pack_slow or 0) / my_dps
    r.their_ttk = (me.hp or 1) / math.max(their_dps, 0.05)
    local kb, db = cfg.odds_kill_band or { 1, 1 }, cfg.odds_die_band or { 1, 1 }
    r.kill_lo, r.kill_hi = r.my_ttk * kb[1], r.my_ttk * kb[2]
    r.die_lo, r.die_hi = r.their_ttk * db[1], r.their_ttk * db[2]
    r.unknown = unknown and ("no damage data for " .. unknown) or nil
    local ratio = r.their_ttk / math.max(r.my_ttk, 0.1)
    local u_ratio = ratio / (ratio + 1)                         -- 0.5 when even
    local u_hp = math.sqrt(math.max(0, math.min(1, (hp_frac - cfg.flee_hp) / (1 - cfg.flee_hp))))
    r.u_fight = u_ratio * (0.6 + 0.4 * u_hp)
    -- a power-level gap alone is no reason to run: the gap is already in both damage rates above (1.25^gap). It is
    -- "too strong" when those numbers say he loses, or the gap is huge (live 2026-11-01 21:50Z, Luis watching: a PL-2
    -- Giant Rat vs his PL 0, "17 s to kill it, 40 s to die", and the gap alone made him run; the rat ran him down)
    local too_strong = worst_gap >= (cfg.pl_gap_hard or 4) or (worst_gap >= cfg.pl_gap_flee and r.u_fight < cfg.fight_enter)
    r.too_strong = too_strong or nil
    r.verdict = (boss and "boss") or (too_strong and "too_strong")
        or (#enemies > cfg.max_hostiles and "outnumbered") or (unknown and "unknown")
        or (r.kill_hi < r.die_lo and "likely_win") or (r.kill_lo > r.die_hi and "likely_lose") or "uncertain"
    if orders.force then r.decision, r.why = "fight", "forced"; return r end
    local flee_hp = orders.flee_hp or cfg.flee_hp
    -- almost won: running at low HP from a creature he kills well before it kills him only gives it free hits
    -- (live 2026-11-01 11:28: he fled at 22 HP from a runt that had ~15 HP left, and took 18 more while fleeing)
    -- (mid-fight: the reach overhead odds_t0_s is paid already)
    local finishing = r.my_ttk - (cfg.odds_t0_s or 0) <= (cfg.finish_margin or 0.5) * r.their_ttk
    r.finishing = finishing or nil
    if orders.commanded then
        -- a commanded fight is the model's decision (North Star review): no strength vetoes; only the
        -- model's own flee_hp policy (combat_orders) can turn it into flight
        if hp_frac < flee_hp and not finishing then return veto("low_hp") end
        r.decision, r.why = "fight", "commanded"
        return r
    end
    -- the reflex (policy from combat_orders: stance, flee_hp)
    if orders.stance == "flee" then return veto("orders") end
    if boss then return veto("boss") end
    if too_strong then return veto("too_strong") end
    if #enemies > cfg.max_hostiles then return veto("outnumbered") end
    if hp_frac < flee_hp then
        if not finishing then return veto("low_hp") end
        r.decision, r.why = "fight", "finishing"
        return r
    end
    local need = current == "fight" and cfg.fight_stay or cfg.fight_enter
    r.decision = r.u_fight >= need and "fight" or "flee"
    r.why = r.decision == "fight" and "winnable" or "losing"
    return r
end

-- Which nearby creatures are threats right now. creatures = list of read_creature() tables with
-- distance_m; attackers/ally_attackers = {id = last hit time}; t = now. -> sorted threat list.
-- telegraphs (optional) = {id = time of its last AI attack start}: a creature swinging within telegraph_m of him
-- now is attacking him even before its first hit lands ("attacking_me", ranked with attacked_me).
function M.pick_threats(creatures, attackers, ally_attackers, orders, t, cfg, telegraphs)
    cfg = cfg or M.cfg
    orders = orders or M.orders
    local out = {}
    for _, c in ipairs(creatures or {}) do
        if not c.dead and not c.follower and not (orders.avoid or {})[(c.name or ""):lower()] then
            local why
            local hit = attackers and attackers[c.id]
            local ally = ally_attackers and ally_attackers[c.id]
            local tele = telegraphs and telegraphs[c.id]
            if hit and t - hit <= cfg.attacker_memory_s then why = "attacked_me"
            elseif tele and t - tele <= 2 * cfg.telegraph_fresh_s and (c.distance_m or 99) <= cfg.telegraph_m then why = "attacking_me"
            elseif ally and t - ally <= cfg.attacker_memory_s and (c.distance_m or 99) <= cfg.assist_m then why = "attacked_ally"
            elseif c.archetype == 0 and c.in_combat and (c.distance_m or 99) <= cfg.aggro_m then why = "hostile_near"
            elseif orders.stance == "aggressive" and c.archetype == 0 and (c.distance_m or 99) <= cfg.aggro_m then why = "hostile_near" end
            if why then
                local d = {}
                for k, v in pairs(c) do d[k] = v end
                d.why = why
                d.rank = ((why == "attacked_me" or why == "attacking_me") and 0 or why == "attacked_ally" and 1 or 2) * 1000 + (c.distance_m or 99)
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

-- `a` is any actor (a census row, or whatever target the brain named): by-name reads go through U.prop (R17:
-- UE4SS's property cache is keyed by class ADDRESS, and a streamed-out Blueprint class's address gets reused).
local function read_creature(a, origin)
    local data = U.prop(a, "LoadedData")
    local at = U.loc(a)
    local hp = num(U.health(a))
    local hc = U.prop(a, "HealthComponent")
    local d = {
        id = U.short(a), actor = a, pos = at,
        name = (U.valid(data) and text(U.try(function() return data.AIName end))) or U.short(a),
        hp = hp, max_hp = hc ~= nil and num(U.try(function() return hc:GetMaxHealth() end)) or nil,
        pl = num(U.prop(a, "PowerLevel")),
        archetype = U.valid(data) and num(U.try(function() return data.Archetype end)) or nil,
        boss = U.valid(data) and U.try(function() return data.bIsBoss end) == true or nil,
        follower = U.try(function() return a:IsFollower() end) == true or nil,
    }
    -- a player's summon (sense.is_summon: its class is a FollowerDataAsset's; live 22:03Z he fled from Luis's
    -- "Buddy" as a PL-7 threat, and at 22:05:50Z retargeted onto it after a goblin died) is never a threat
    local S = mod("sense")
    if S and S.is_summon and S.is_summon(a) then d.follower, d.summon = true, true end
    d.dead = (hc ~= nil and U.try(function() return hc:IsDead() end) == true) or (hp ~= nil and hp <= 0)
    local al = num(U.prop(a, "CurrentAlertnessState"))
    if al ~= nil then d.in_combat = al == 3 or al == 4 end
    if origin and at then d.distance_m = U.dist(origin, at) / 100 end
    return d
end
M.read_creature = read_creature

-- Live damage-type affinities (TMap<GameplayTag, EDamageTypeAffinity>); empty on the client so far.
local function read_affinities(a)
    local out
    local aac = U.prop(a, "AIAttributesComponent") -- any target actor (R17)
    pcall(function()
        aac.DamageTypeAffinities:ForEach(function(k, v)
            local tag = U.str(U.try(function() return k:get().TagName end))
            local aff = M.AFFINITY[U.try(function() return v:get() end)]
            if tag and aff then out = out or {}; out[tag] = aff end
        end)
    end)
    return out
end

-- The creature census, CACHED for cfg.census_s (one FindAllOf + reads per window, shared by every caller this
-- tick: threats, the pack, fight-or-flight, find_creature). A narrower radius from (about) the same origin is
-- served from the cache; a wider one or a moved origin scans again.
local function census_clock() return M.clock and M.clock() or os.clock() end
local function creatures_near(origin, radius_m)
    local c = C()
    local cc = c.census
    local t = census_clock()
    if cc and origin and cc.origin and t - cc.t < M.cfg.census_s and radius_m <= cc.radius and U.dist(origin, cc.origin) < 100 then
        local out = {}
        for _, d in ipairs(cc.rows) do if (d.distance_m or 1e9) <= radius_m then out[#out + 1] = d end end
        return out
    end
    local out, by_id = {}, {}
    for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
        local at = U.loc(a)
        local id = U.short(a)
        if id then by_id[id] = a end
        if at and origin and U.dist(origin, at) <= radius_m * 100 then
            local ok, d = pcall(read_creature, a, origin)
            if ok and d then out[#out + 1] = d end
        end
    end
    c.census = { t = t, origin = origin and { X = origin.X, Y = origin.Y, Z = origin.Z }, radius = radius_m, rows = out, by_id = by_id }
    return out
end
M.creatures_near = creatures_near

-- An actor by id: the census's own map first (no FindAllOf on the hot path), then one scan.
local function find_creature(id)
    local cc = C().census
    local a = cc and cc.by_id and cc.by_id[id]
    if a and U.valid(a) then return a end
    for _, x in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
        if U.short(x) == id then return x end
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

-- A player's pawn position by name (nil when that player's pawn is not visible: out of relevancy or offline).
function M.player_pos(name)
    if type(name) ~= "string" or name == "" then return nil end
    for _, ps in ipairs(U.find_all("PlayerState", { skip_defaults = true })) do
        if U.str(U.try(function() return ps:GetPlayerName() end)) == name then
            local p = U.try(function() return ps.PawnPrivate end)
            return U.valid(p) and U.loc(p) or nil
        end
    end
end

-- Resolve an attack target: entity id, or a creature name (nearest live one within cfg.resolve_m; the brain sees
-- creatures to ~50 m in get_state, and live 11:29 "Goblin Runt" at 41 m was refused by a 40 m cap).
-- -> actor | nil, detail (why not, with the nearest creature of that name when the id is gone)
function M.resolve_target(target, origin)
    if type(target) == "userdata" or type(target) == "table" and target.IsValid then return target end
    if type(target) ~= "string" or target == "" then return nil end
    local a = find_creature(target)
    if a then return a end
    local want, best, bd = target:lower(), nil, math.huge
    local radius = M.cfg.resolve_m or 60
    for _, c in ipairs(creatures_near(origin, radius)) do
        if not c.dead and (c.name or ""):lower():find(want, 1, true) and c.distance_m < bd then best, bd = c.actor, c.distance_m end
    end
    if best then return best end
    -- not found: say why, truthfully, and what is there instead (an id of a creature that died or despawned)
    local base = target:match("^BP_AI_(.-)_Character") or target:match("^BP_AI_(.-)_C_%d+$")
    local detail = { target = target }
    if target:match("_C_%d+$") then
        detail.detail = "no creature with that id is in sight now: it died, despawned or went out of view"
    else
        detail.detail = string.format("no living %s within %d m", target, radius)
    end
    local alt, ad
    for _, c in ipairs(creatures_near(origin, radius)) do
        local cls = U.class_word(c.actor) or ""
        if not c.dead and base and cls:lower():find(base:lower(), 1, true) and c.distance_m < (ad or math.huge) then alt, ad = c, c.distance_m end
    end
    if alt then detail.nearest_same_kind = { id = alt.id, name = alt.name, distance_m = math.floor(alt.distance_m * 10) / 10 } end
    return nil, detail
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

-- The shared modal gate (client_mod/scripts/input.lua, build review finding 4): while build mode is open
-- the attack click is the PLACE click, and while a container screen is open inputs act on it, so no
-- gameplay press goes out then (the gate also cleans up a modal nobody owns). Cached per frame.
local function gated()
    local inp = mod("input")
    if not (inp and inp.gate) then return nil end
    local c = C()
    -- one gate read per game frame (combat's frame loop numbers them); outside a frame: always read
    if c.frame_id and c.gate_frame == c.frame_id then return c.gate_res end
    local ok, m = pcall(inp.gate)
    c.gate_frame, c.gate_res = c.frame_id, ok and m or nil
    if c.gate_res then c.counts.gated = (c.counts.gated or 0) + 1 end
    return c.gate_res
end
M._gated = gated

local function inject(action, vec)
    if gated() then return false end
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
    { path = "/Script/Dominion.DamageComponent:Multicast_ApplyPointDamageFromGameplayEffect", handler = "on_point_damage" },
    { path = "/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies", handler = "on_ai_attack" },
    { path = "/Script/Dominion.AiRangedAttackComponent:Multicast_PerformAttackOnSimulatedProxies", handler = "on_ai_attack" },
    -- the server's verdict on Claude's block (PlayerBlockingComponent, NetMulticast; params not read)
    { path = "/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData", handler = "on_ai_impact" },
    { path = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack", handler = "on_parried" },
    { path = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingBlockedAttack", handler = "on_blocked" },
    -- AI ACTIONS (dragon breath, earth spikes, meteor flight, reposition: velgar.md gap 1). Read-only: the hook
    -- keeps the component and the int ActionId (a scalar) and nothing else; the action's class is read on the
    -- next fight tick from the component's CurrentAction (a property read), never inside the hook.
    { path = "/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction", handler = "on_ai_action" },
    { path = "/Script/Dominion.DominionAIActionsComponent:Multicast_StopCurrentAIAction", handler = "on_ai_action_stop" },
}

local function trim_map(m, t, keep_s)
    for k, v in pairs(m) do if t - (type(v) == "table" and v.t or v) > keep_s then m[k] = nil end end
end

-- Damage multicast: who hit whom. Read-only param reads (same reads as sense.lua's vitals watcher).
function M.on_damage(ctx, ev, point)
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
        -- a point hit carries the server's verdict on his block (FDominionPointDamageEvent.BlockOutcome: EBlockResult,
        -- and DamageBlocked); the plain event has neither
        local blk
        if point then
            local bo = U.try(function() return e.BlockOutcome end)
            if bo then
                blk = { result = num(U.try(function() return bo.Result end)), blocked = num(U.try(function() return e.DamageBlocked end)),
                        blockable = U.try(function() return bo.bWasBlockableAttack end) }
            end
        end
        c.me_dmg[#c.me_dmg + 1] = { seq = c.me_seq, t = t, amount = amount, inst = iid, block = blk, point = point and true or false,
                                    absorbed = num(U.try(function() return e.AmountAbsorbedByShield end)) }
        if #c.me_dmg > 20 then table.remove(c.me_dmg, 1) end
        if f then f.dmg_taken = (f.dmg_taken or 0) + amount; M.note_damage(f, amount) end
        c.last_mc_dmg_t = t
    end
    if vid == me and iid and not mine_i then
        c.attackers[iid] = t
        local data = U.prop(inst, "LoadedData") -- instigator and victim are any class: by-name reads via U.prop (R17)
        local name = U.valid(data) and text(U.try(function() return data.AIName end)) or iid
        local tk = c.taken[name:lower()] or { sum = 0, t0 = t, n = 0 }
        tk.sum, tk.n, tk.t = tk.sum + amount, tk.n + 1, t
        c.taken[name:lower()] = tk
        if f then f.last_hit_by = name end -- who killed him, when the fight ends in his death (the grave's danger)
    elseif mine_i and vid ~= me then
        local types, outcomes = {}, {}
        pcall(function()
            e.TypeDamagesArray.TypeDamages:ForEach(function(_, td)
                pcall(function() td:get().Types.GameplayTags:ForEach(function(_, g) types[#types + 1] = U.str(g:get().TagName) end) end)
            end)
        end)
        pcall(function() e.TypeDamagesOutcome:ForEach(function(_, o) outcomes[#outcomes + 1] = M.OUTCOME[o:get()] end) end)
        local data = U.prop(victim, "LoadedData")
        local name = U.valid(data) and text(U.try(function() return data.AIName end)) or vid
        local hit = { t = t, victim = vid, name = name, amount = amount, types = types, outcomes = outcomes,
                      fatal = U.try(function() return e.bIsFatalHit end) == true }
        c.counts.hits = c.counts.hits + 1
        hit.seq = c.counts.hits
        c.my_hits[#c.my_hits + 1] = hit
        if #c.my_hits > 30 then table.remove(c.my_hits, 1) end
        if #types > 0 and #outcomes > 0 then M.learn_outcome(c.learned, name, types, outcomes); c.learned_ver = (c.learned_ver or 0) + 1 end
    elseif iid and vid ~= me and U.valid(U.prop(victim, "PlayerState")) and U.valid(U.prop(inst, "LoadedData")) then
        c.ally_attackers[iid] = t -- a creature hit another player (Luis)
    end
    if vid ~= me and U.try(function() return e.bIsFatalHit end) == true then
        -- who killed what, so "already dead" and the kill count say whose kill it was (live 2026-11-01: a
        -- goblin someone else finished was counted as his kill, and he could only guess "your buddy got it")
        local by = mine_i and "me" or nil
        if not by and U.valid(inst) then
            local ps = U.prop(inst, "PlayerState")
            by = U.valid(ps) and U.str(U.try(function() return ps:GetPlayerName() end)) or nil
            if not by then
                local d = U.prop(inst, "LoadedData")
                by = U.valid(d) and text(U.try(function() return d.AIName end)) or U.class_word(inst)
            end
        end
        c.deaths = c.deaths or {}
        c.deaths[vid] = { t = t, by = by }
        for k, v in pairs(c.deaths) do if t - v.t > 300 then c.deaths[k] = nil end end
    end
end
function M.death_of(id) local d = C().deaths; return d and d[id] end

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
    local data = U.prop(owner, "LoadedData") -- the attack component's owner is any class (R17)
    local who = U.valid(data) and text(U.try(function() return data.AIName end)) or "?"
    info.key = who .. ":" .. (info.name or ("class" .. tostring(class_id)))
    local D = mod("defense")
    local cap = U.prop(owner, "CapsuleComponent")
    local hh = cap ~= nil and num(U.try(function() return cap:GetScaledCapsuleHalfHeight() end)) or nil
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
    do
        local data = U.prop(a, "LoadedData") -- any owner class (R17)
        local nm = U.valid(data) and text(U.try(function() return data.AIName end)) or id
        local D = mod("defense")
        if D and D.observe_cadence then D.observe_cadence(nm, t) end
    end
    -- only attacks near Claude are worth reading; between fights too (the guard's last position of him), since
    -- the swing that starts a reflex fight is the one its first defence answers (live 2026-11-01 12:38: unread,
    -- the answer was planned for "?:unknown", a dodge, and the runt hit for 18)
    local f = c.fight
    local near = (f and f.me_pos) or (not f and c.guard and c.guard_pos) or nil
    if (f and id == f.target_id) or (near and U.loc(a) and U.dist(U.loc(a), near) < 800) then
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
-- An AI action started on some creature: remember it for the next tick (no reads beyond owner + id here).
-- Crash 2026-10-26 14:56:19 (crash_2026_10_26_15_56_19, BUGS.md): the record must NEVER hold a UObject
-- across ticks. It kept comp/owner refs; ambient creatures (Kebbits, chickens) that despawned behind him on
-- an explore were GC'd, and the next fight's ability_frame read r.comp.CurrentAction -> native AV in UE4SS
-- __index (pcall can't catch it). Keep object PATHS; ability_frame re-finds them (StaticFindObject: nil once
-- the object is gone) and checks U.alive before any property read. Records are pruned here too, because
-- outside a fight (ambient off) nothing else prunes them.
local function prune_ai_actions(c, t)
    for k, r in pairs(c.ai_actions or {}) do
        if (not r.running and t - (r.stopped_t or r.t) > 30) or t - r.t > 120 then c.ai_actions[k] = nil end
    end
end
M._prune_ai_actions = prune_ai_actions
function M.on_ai_action(ctx, id_p)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local a = U.try(function() return comp:GetOwner() end)
    if not U.valid(a) then return end
    local id = U.short(a)
    local aid = id_p and U.try(function() return id_p:get() end)
    local t = now(a)
    c.ai_actions = c.ai_actions or {}
    prune_ai_actions(c, t)
    c.ai_actions[id] = { t = t, comp_path = U.path_of(comp), owner_path = U.path_of(a),
                         action_id = type(aid) == "number" and aid or nil, running = true }
    c.counts.ai_actions = (c.counts.ai_actions or 0) + 1
end
-- The live object behind a stored path, or nil when it is gone / awaiting GC (never a stale wrapper).
local function refind(path)
    local o = path and U.find_object(path)
    return (o and U.alive(o)) and o or nil
end
M._refind = refind
function M.on_ai_action_stop(ctx)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local a = U.try(function() return comp:GetOwner() end)
    local r = U.valid(a) and (c.ai_actions or {})[U.short(a)]
    if r then r.running, r.stopped_t = false, now(a) end
end

-- Words of an identifier, lowercased: split at "_", lower->Upper, acronym->Word ("AIAction" = ai action) and
-- letter<->digit. "DAA_DragonVelgar_PoisonBreath_Front_C" -> daa dragon velgar poison breath front c.
-- (Idiom: two gsub passes, lua-users.org/wiki/StringRecipes; no %f so it runs on any Lua.)
function M.words(s)
    s = s:gsub("(%l)(%u)", "%1_%2"):gsub("(%u)(%u%l)", "%1_%2"):gsub("(%a)(%d)", "%1_%2"):gsub("(%d)(%a)", "%1_%2")
    local w = {}
    for part in s:gmatch("[^_]+") do w[#w + 1] = part:lower() end
    return w
end
-- true when the words of `tok` occur as a contiguous run of whole words of `words` (BUGS L39: whole words, so
-- "Breath" is not found in "Breathe", nor "Idle" in "Idler", nor "Front" in "Frontflip").
function M.has_words(words, tok)
    local tw = M.words(tok)
    for i = 1, #words - #tw + 1 do
        local j = 1
        while j <= #tw and words[i + j - 1] == tw[j] do j = j + 1 end
        if j > #tw then return true end
    end
    return false
end

-- The profile of an AI action class (client_mod/scripts/ability_profiles.lua, data): the first token of
-- `order` found in the class name as whole words wins; the side (Front/Left/Right) is a word too. -> table or nil
function M.ability_profile(cls)
    if type(cls) ~= "string" then return nil end
    local ABIL = M.data("ability_profiles")
    if not ABIL then return nil end
    local words = M.words(cls)
    for _, tok in ipairs(ABIL.order or {}) do
        if M.has_words(words, tok) then
            local p = {}
            for k, v in pairs(ABIL[tok] or {}) do p[k] = v end
            p.token = tok
            for word, side in pairs(ABIL.sides or {}) do
                if M.has_words(words, word) then p.side = side end
            end
            return p
        end
    end
    return nil
end

-- Per fight tick: resolve new AI actions (class -> profile) and answer a threatening one near Claude like a
-- telegraphed attack (defence plan; the key is "<creature name>:<action class>", learned like any attack).
function M.ability_frame(F, me)
    local c = C()
    prune_ai_actions(c, F.t) -- a stopped action after 30 s, any after 120 s
    for id, r in pairs(c.ai_actions or {}) do
        if not r.cls and F.t - r.t > M.cfg.ai_action_resolve_s then
            r.cls = "?" -- too old: the action has ended, and its creature may have despawned (crash 14:56:19)
        elseif not r.cls then
            local comp, owner = refind(r.comp_path), refind(r.owner_path)
            local cur = comp and U.try(function() return comp.CurrentAction end)
            local cls = U.valid(cur) and U.short(U.try(function() return cur:GetClass() end)) or nil
            r.cls = cls or "?"
            r.profile = M.ability_profile(cls)
            for _, hz in ipairs((r.profile and r.profile.hazards) or {}) do
                c.hazard_watch = c.hazard_watch or {}
                c.hazard_watch[hz] = math.max(c.hazard_watch[hz] or 0, F.t + M.cfg.hazard_window_s)
            end
            r.name = U.try(function() return text(U.prop(owner, "LoadedData").AIName) end) -- any owner class (R17)
            say(F.log, string.format("ai action %s on %s: %s (%s)", tostring(r.action_id), tostring(r.name or id), tostring(r.cls),
                r.profile and r.profile.kind or "no profile"))
            if r.profile and r.profile.kind ~= "idle" then
                M.emit_activity({ kind = "creature_ability", creature = r.name, creature_id = id, ability = r.profile.kind,
                                  side = r.profile.side, action_class = r.cls, airborne = r.profile.airborne or nil })
            end
            local pr = r.profile
            if pr and pr.threat and not r.answered and (id == F.target_id or (owner and me.pos and U.loc(owner)
                and U.dist(U.loc(owner), me.pos) <= (pr.reach_m or 20) * 100)) then
                r.answered = true
                local info = { key = tostring(r.name or "?") .. ":" .. r.cls, dmg_time = pr.impact_s, unblockable = pr.unblockable,
                               ability = pr.kind, side = pr.side, no_jump = pr.jumpable == false or nil,
                               shape = { reach_cm = (pr.reach_m or 20) * 100, aoe = pr.aoe or nil } }
                if not F.ambient and F.phase ~= "defend" and F.phase ~= "flee" and F.phase ~= "loot" and F.phase ~= "restore" then
                    return M._start_defend(F, me, id, r.t, info)
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ ground hazards -> move.lua avoid zones (gap 2)
-- The game's damage-on-the-ground actors (client_mod/scripts/hazard_profiles.lua, data) are read by PROPERTY
-- (radius, telegraph time, landing point) and handed to move.set_avoid_zones (metres; r_cm; until_s on the
-- GetRealTimeSeconds clock = F.t). Inside a zone with time to spare: move.escape_zones walks out, then
-- move.restore(prev); too slow: a dodge outward (Phase Dash first when it is ready). The census runs only for the
-- hazard kinds an AI action just named (ability_profiles `hazards`), every cfg.hazard_s, while watched or on the ground.
function M.hazard_profiles() return M.data("hazard_profiles") or {} end
local function first_num(o, names)
    for _, n in ipairs(names or {}) do
        local v = num(U.prop(o, n)) -- names tried in order on Blueprint subclasses: R17
        if v and v > 0 then return v end
    end
end
function M.hazard_census(F, me, names)
    local c = C()
    c.hazard_seen = c.hazard_seen or {}
    local zones, land = {}, {}
    local live = {}
    for _, hp in ipairs(M.hazard_profiles()) do
        if names[hp.name] then
            for _, o in ipairs(U.find_all(hp.class, { skip_defaults = true }) or {}) do
                if U.valid(o) then
                    local id = U.short(o) or ("?" .. #zones)
                    local owner = hp.component_is_hazard and U.try(function() return o:GetOwner() end) or o
                    local pos = owner and U.loc(owner)
                    if hp.target then
                        local tl = U.prop(o, hp.target)
                        local tx, ty = tl and num(U.try(function() return tl.X end)), tl and num(U.try(function() return tl.Y end))
                        if tx and ty and (tx ~= 0 or ty ~= 0) then pos = { X = tx, Y = ty, Z = num(U.try(function() return tl.Z end)) or (pos and pos.Z) or 0 } end
                    end
                    if pos then
                        live[id] = true
                        local seen = c.hazard_seen[id]
                        if not seen then
                            local tel = hp.telegraph and num(U.prop(o, hp.telegraph))
                            seen = { t = F.t, ttl = (tel and tel > 0) and tel or hp.ttl_default, kind = hp.name }
                            c.hazard_seen[id] = seen
                        end
                        -- persistent (clouds, trails): a long expiry, re-sent only when the set of ids changes
                        local until_s = hp.persistent and (seen.t + M.cfg.hazard_persist_s) or (seen.t + seen.ttl + 0.3)
                        if until_s > F.t then
                            local zid = hp.name .. ":" .. id
                            zones[#zones + 1] = { id = zid, kind = "circle", x = pos.X / 100, y = pos.Y / 100, z = pos.Z / 100,
                                                  r_cm = first_num(o, hp.radius) or hp.radius_default, until_s = until_s }
                            land[zid] = { land_s = math.max(0, (seen.t + seen.ttl) - F.t), hazard = hp.name }
                        end
                    end
                end
            end
        end
    end
    for id in pairs(c.hazard_seen) do if not live[id] then c.hazard_seen[id] = nil end end
    return zones, land
end

-- Boss phases (velgar.md gap 3): the arena's replicated phase (APhasedDragonArenaAILevelData.PhaseRuntimeData
-- {PhaseIndex, bTransitioningToNext}), read once a second while fighting a boss; a change is an activity event.
M.BOSS_ARENA_CLASS = "PhasedDragonArenaAILevelData"
function M.boss_frame(F, me)
    if not F.boss then return end
    if F.t - (F.boss_t or -9) < 1.0 then return end
    F.boss_t = F.t
    local c = C()
    local lvl = c.boss_lvl
    if not U.valid(lvl) then
        if F.t - (c.boss_lvl_look_t or -99) < 5 then return end
        c.boss_lvl_look_t = F.t
        lvl = U.find_first(M.BOSS_ARENA_CLASS)
        c.boss_lvl = U.valid(lvl) and lvl or nil
        if not c.boss_lvl then return end
    end
    local idx = num(U.try(function() return lvl.PhaseRuntimeData.PhaseIndex end))
    local tr = U.try(function() return lvl.PhaseRuntimeData.bTransitioningToNext end) == true
    -- the phase count is fixed per arena actor: counted once
    c.boss_phase_n = c.boss_phase_n or {}
    local lid = U.short(lvl) or "?"
    local n = c.boss_phase_n[lid]
    if not n then
        n = 0
        pcall(function() lvl.PhaseData:ForEach(function() n = n + 1 end) end)
        c.boss_phase_n[lid] = n
    end
    local air, why = M.airborne(F.target_id)
    local b = c.boss or {}
    local changed = b.index ~= idx or b.transitioning ~= tr or b.airborne ~= air
    c.boss = { index = idx, transitioning = tr, phases = n > 0 and n or nil, airborne = air or tr, why = why, t = F.t, target = F.target_name }
    if idx and (not F.boss_max_phase or idx > F.boss_max_phase) then F.boss_max_phase = idx end
    if n > 0 then F.boss_phases = n end
    if changed then
        say(F.log, string.format("boss phase %s/%s transitioning=%s airborne=%s (%s)", tostring(idx), tostring(n), tostring(tr), tostring(air), tostring(why)))
        M.emit_activity({ kind = "boss_phase", creature = F.target_name, phase = idx, phases = n > 0 and n or nil,
                          transitioning = tr or nil, airborne = (air or tr) or nil, why = why })
    end
end

-- Is this creature off the ground or between boss phases right now? (no chase while it is up)
function M.airborne(id)
    local c = C()
    local r = (c.ai_actions or {})[id]
    if r and r.running and r.profile and r.profile.airborne then return true, r.profile.kind end
    local b = c.boss
    if b and b.transitioning then return true, "phase_transition" end
    return false
end

function M.on_ai_impact(ctx)
    if _G.DW_PAUSE then return end
    local c = C()
    local comp = ctx:get()
    local a = U.try(function() return comp:GetOwner() end)
    if not U.valid(a) then return end
    c.impact_seq = (c.impact_seq or 0) + 1
    c.impacts = c.impacts or {}
    c.impacts[#c.impacts + 1] = { seq = c.impact_seq, id = U.short(a), t = now(a) }
    if #c.impacts > 20 then table.remove(c.impacts, 1) end
end
function M.on_blocked(ctx) on_block_event(ctx, "blocked") end
function M.on_point_damage(ctx, ev) return M.on_damage(ctx, ev, true) end
M.BLOCK_RESULT = { [0] = "not blocking", [1] = "block failed", [2] = "block successful", [3] = "staggered" } -- EBlockResult

function M.hooks_start(log)
    local c = C()
    local p = mcall("inventory", "pawn")
    if p then c.me_id = U.short(p) end
    local pc0 = local_pc()
    if pc0 then c.pc_id = U.short(pc0) end
    c.handlers = { on_damage = M.on_damage, on_point_damage = M.on_point_damage, on_ai_attack = M.on_ai_attack, on_parried = M.on_parried, on_blocked = M.on_blocked,
                   on_ai_impact = M.on_ai_impact, on_ai_action = M.on_ai_action, on_ai_action_stop = M.on_ai_action_stop }
    local res = {}
    for _, h in ipairs(M.HOOKS) do
        if c.hooks[h.path] then res[h.handler .. ":" .. h.path:match(":(.+)$")] = "kept"
        else
            -- BUGS L24: through the shared hook hub (one native hook per path, shared with sense.lua's
            -- vitals watcher on the same Multicast_* functions; never unregistered; skipped under DW_PAUSE)
            local hubm = (function()
                local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or ((os.getenv("DW_CLIENT_ROOT") or "C:/gameserver") .. "/client_mod/scripts")
                return assert(loadfile(dir .. "/hookhub.lua"))()
            end)()
            local ok = hubm.on(h.path, "combat:" .. h.handler .. ":" .. h.path, function(...)
                local cc = _G.DWCombat
                local fn = cc and cc.handlers and cc.handlers[h.handler]
                if fn then
                    local ok2, err = pcall(fn, ...)
                    if not ok2 then cc.hook_err = tostring(err) end
                end
            end, { defer = hubm.not_in_world(p), log = log })
            if ok then c.hooks[h.path] = true end
            res[h.path:match("%.([%w_]+:[%w_]+)$")] = ok and "ok" or "pending"
            say(log, "hook " .. h.path .. " native=" .. tostring(ok))
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
    local cap = U.prop(actor, "CapsuleComponent") -- the target is any actor class (R17)
    local rad = cap ~= nil and num(U.try(function() return cap:GetScaledCapsuleRadius() end)) or 40
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
    local okw, walltime = pcall(require, "walltime") -- ms ts + act/ep (telemetry items 2, 5)
    if okw and type(walltime) == "table" and type(walltime.stamp) == "function" then walltime.stamp(ev) else ev.ts = os.time(); ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts) end
    local line = U.try(function() return json_mod.encode(ev) end)
    if not line then return end
    local fh = io.open(M.ACTIVITY_PATH, "a")
    if fh then fh:write(line, "\n"); fh:close() end
end

-- Leaving an NPC conversation because a fight needs the controls (talk review finding 8). Through the talk
-- module, the conversation's owner: talk.stop(why) ends a running talk job with that reason (its result says
-- why), then talk.start{leave = true} presses the dialogue panel's own Cancel as the modal's owner and verifies
-- it closed. Without talk: the panel's CancelInputAction through input.inject as the "conversation" modal.
-- Never IA_UI_GenericBack. One "conversation_interrupted" activity event (first attempt) says who and why.
local function talk_mod()
    local inst = rawget(_G, "__dwc_bridge")
    local api = inst and inst.module and inst.module.API
    local t = api and api.module and U.try(function() return api.module("talk") end)
    if type(t) == "table" then return t end
    return mod("talk")
end
M._talk_mod = talk_mod
function M.leave_conversation(F, attempt)
    local pc = F.pc
    local npc = pc and U.short(U.try(function() return pc.ConversationComponent.CurrentNPC end))
    F.conv_npc = F.conv_npc or npc
    local why = (F.by == "reflex" or F.mode == "reflex") and "attacked" or "fight_ordered"
    local talk = talk_mod()
    local via, r
    if type(talk) == "table" and type(talk.start) == "function" then
        if type(talk.stop) == "function" then
            pcall(talk.stop, F.log, why == "attacked" and ("attacked by " .. tostring(F.target_name)) or ("fight ordered: " .. tostring(F.target_name)))
        end
        local ok, rr = pcall(talk.start, F.log, { leave = true })
        r = ok and rr or { ok = false, reason = tostring(rr) }
        via = "talk"
    end
    if not (type(r) == "table" and r.ok) then
        local inp = mod("input")
        local panel
        for _, p in ipairs(U.find_all("ConversationMainPanel", { skip_defaults = true }) or {}) do if U.valid(p) then panel = p; break end end
        local cancel = panel and U.try(function() return panel.CancelInputAction end)
        if U.valid(cancel) and inp and inp.inject then
            if inp.claim then pcall(inp.claim, "conversation", "combat") end
            local ok, pressed = pcall(inp.inject, cancel, nil, { modal = "conversation" })
            if inp.release then pcall(inp.release, "conversation") end
            via = (ok and pressed) and "panel_cancel" or via or "none"
        else
            via = via or "none"
        end
    end
    F.conv_via = via
    say(F.log, string.format("conversation with %s: leaving (%s, attempt %d, via %s)", tostring(F.conv_npc), why, attempt or 1, tostring(via)))
    if (attempt or 1) == 1 then
        M.emit_activity({ kind = "conversation_interrupted", by = F.by or "unknown", why = why, npc = F.conv_npc,
                          attacker = F.target_name, attacker_id = F.target_id, via = via,
                          talk_reason = type(r) == "table" and not r.ok and (r.reason or (r.data and r.data.why)) or nil })
    end
    return via
end

-- An approach that cannot get there ends at once with the reason (BUGS L34; live 09:34: a Kebbit behind a
-- wall, move said "unreachable: no_route" after 50 s and the fight still ran to its 120 s timeout).
-- Two signals: move's own verdict (follow sets status "unreachable" with a reason), and no progress: the
-- distance has not improved by approach_gain_m for approach_stall_s. -> nil or the failure data
function M.approach_blocked(F, ms)
    if M.airborne(F.target_id) then -- a boss in the air / between phases: not "unreachable", not "running away"
        if not F.boss_hold then mcall("move", "progress_reset", F.log) end
        F.boss_hold = true
        return nil
    end
    if F.boss_hold then mcall("move", "progress_reset", F.log) end -- he landed: a fresh window
    F.boss_hold = nil
    -- move's own approach tracker (one watchdog for everyone; opts.progress set by follow_target)
    local pg = type(ms) == "table" and ms.progress or nil
    if not (type(pg) == "table" and (pg.verdict == "stalled" or pg.verdict == "unreachable")) then return nil end
    local why = pg.why or (pg.verdict == "unreachable" and "unreachable" or "no_progress")
    local name = "the " .. tostring(F.target_name or "creature")
    local clause = mcall("move", "why_words", why, name) or why
    local base = { why = why, target = F.target_name, target_id = F.target_id, dist_m = pg.dist_m or (F.dist_m and math.floor(F.dist_m * 10) / 10),
                   best_m = pg.best_dist_m, stalled_s = pg.since_s, chased_s = pg.elapsed_s, target_moved_m = pg.target_moved_m,
                   walls = why == "blocked" or nil,
                   move = { lp_fail = ms.lp_fail, stuck_n = ms.stuck_n, unreachable = ms.unreachable },
                   detail = string.format("I can't get to %s: %s.", name, clause) }
    if why == "cant_catch" or why == "too_long" then base.reason = "too_far" end
    return base
end

-- ------------------------------------------------------------------ persistent combat memory
-- What he learned in fights survives a client restart (design docs/design/combat-memory.md): defence
-- (per-attack timing, parry offset, lunge, reach, damage, the response bandit, cadence), learned damage-type
-- verdicts, swing stamina costs, ranged profiles, and a per-creature fight history (information for the
-- brain, never a veto). One JSON file per world and character, tagged with the client build:
--   <root>/data/skills/<world>/combat_memory_<character>.json
-- Loaded ONCE (first fight / combat_brief of that world+character); written ONLY at a fight's end, as
-- write-then-rename (Lua's os.rename will not replace an existing file on Windows: the old file is moved to
-- .bak first, the new one renamed in, the .bak removed; a crash between leaves .bak, which the load uses).
-- A file from another build is REFUSED loudly (kept as ...build-<old>.json, status "refused_stale");
-- a corrupt one is kept as .corrupt-<time>.json (status "corrupt"). Never any game call here.
M.fs = { open = io.open, rename = os.rename, remove = os.remove, execute = os.execute }
local function sanitize(w)
    w = w and tostring(w):gsub("[^%w_%-]", "") or ""
    return w ~= "" and w or nil
end
-- The world his memory is filed under: the shared resolver (mod/body/util.lua U.world_id: explicit settings, else the
-- server he actually joined; never a silent "shockbyte"). M.fs lets tests fake the files. -> id, source
function M.world_id() return U.world_id(ROOT, { fs = M.fs, cache_s = M.cfg.world_id_s }) end
function M._reset_world_cache() U.world_reset() end
local BUILD
function M.client_build()
    if BUILD ~= nil then return BUILD or nil end
    BUILD = sanitize(os.getenv("DW_CLIENT_BUILD")) or false
    if not BUILD then
        local f = M.fs.open(M.cfg.steam_manifest, "r")
        if f then
            local txt = f:read("a") or ""; f:close()
            BUILD = sanitize(txt:match('"buildid"%s+"(%d+)"')) or false
        end
    end
    return BUILD or nil
end
M._reset_build = function(b) BUILD = b end
function M.memory_path(world, char)
    local dir = (M.cfg.memory_root or ROOT) .. "/data/skills/" .. world
    return dir .. "/combat_memory_" .. char .. ".json", dir
end
local function json()
    json_mod = json_mod or U.try(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    return json_mod
end
local function read_all(path)
    local f = M.fs.open(path, "rb"); if not f then return nil end
    local t = f:read("a"); f:close(); return t
end

-- What he has learned of a world's creatures (each attack's timing, reach and lunge; the ranged fits) is the
-- player's, not one character's: kept beside the characters' memories as combat_knowledge.json, read by every
-- character of his in that world and written with each memory save. (Step trials run on a new fork each: in windows
-- s6 to s9 every trial began with "none yet" and left the first Giant Rat lunge unanswered as out of reach.)
-- Which answer works (a record's arms) is not in it: that hangs on what the character holds and how he fights.
-- (Window s11: forks took over "dodge 18 of 22" from characters without a shield, rolled 18 of 28 attacks against
-- 2 of 28 in s9, ran out of stamina and took 2 hits with no answer left.)
local function creature_facts(defense, arms_of)
    local out = { cadence = type(defense) == "table" and defense.cadence or nil, attacks = {} }
    for k, r in pairs(type(defense) == "table" and type(defense.attacks) == "table" and defense.attacks or {}) do
        if type(r) == "table" then
            local copy = {}
            for f, v in pairs(r) do copy[f] = v end
            copy.arms = arms_of and arms_of[k] and arms_of[k].arms or nil
            out.attacks[k] = copy
        end
    end
    return out
end
function M.knowledge_path(world) return (M.cfg.memory_root or ROOT) .. "/data/skills/" .. world .. "/combat_knowledge.json" end
function M.knowledge_load(log, m)
    local path = M.knowledge_path(m.world)
    local txt = read_all(path) or read_all(path .. ".tmp") -- (.tmp: a save that died between its remove and its rename)
    if not txt then return nil end
    local J = json()
    local ok, doc = pcall(function() return J and J.decode(txt) end)
    if not ok or type(doc) ~= "table" then return nil end -- unreadable: the next save writes a whole one
    if m.build and tostring(doc.build) ~= m.build then
        if log then pcall(log, string.format("combat: knowledge %s is from build %s (client build %s): not used", path, tostring(doc.build), m.build)) end
        return nil
    end
    local D, R = mod("defense"), mod("ranged")
    local own = D and D.status and D.status().attacks or {} -- (his own records, loaded before this: their arms stay)
    m.known = { attacks = D and D.import and D.import(creature_facts(doc.defense, own)) or 0, ranged = R and R.import and R.import(doc.ranged) or 0 }
    if log then
        pcall(log, string.format("combat: %d attacks added from what his characters learned in this world (%s, last written by %s)",
            m.known.attacks, path, tostring(doc.by)))
    end
    return m.known
end
function M.knowledge_save(m, doc)
    local J = json()
    if not J then return false end
    local ok, txt = pcall(J.encode, { v = 1, build = m.build, world = m.world, saved_at = doc.saved_at, by = m.char,
                                      defense = creature_facts(doc.defense), ranged = doc.ranged })
    if not ok or type(txt) ~= "string" then return false end
    local path = M.knowledge_path(m.world)
    local tmp = path .. ".tmp"
    local f = M.fs.open(tmp, "wb")
    if not f then return false end
    f:write(txt); f:close()
    M.fs.remove(path)
    return M.fs.rename(tmp, path) and true or false
end

-- -> the memory record (c.mem); loads the character's own file the first time a world+character is seen
local function memory_own(log, pawn)
    local c = C()
    local char = sanitize(pawn and U.try(function() return U.player_name(pawn) end)) or (c.mem and c.mem.char) or "unknown"
    local world, world_src = M.world_id()
    local key = world .. "/" .. char
    if c.mem and c.mem.key == key then return c.mem end
    if not M.cfg.memory_enabled then c.mem = { key = key, world = world, char = char, history = {}, status = "disabled", off = true }; return c.mem end
    local path = M.memory_path(world, char)
    local build = M.client_build()
    local m = { key = key, world = world, world_source = world_src, char = char, path = path, build = build, history = {}, status = "new", loaded_at = os.time() }
    c.mem = m
    local txt = read_all(path)
    local from = path
    if not txt then txt = read_all(path .. ".bak"); from = path .. ".bak" end
    if not txt then
        if log then pcall(log, "combat: memory " .. path .. ": none yet (this character's first fights in this world)") end
        return m
    end
    local J = json()
    local ok, doc = pcall(function() return J and J.decode(txt) end)
    if not ok or type(doc) ~= "table" then
        local keep = path .. ".corrupt-" .. os.time() .. ".json"
        M.fs.rename(from, keep)
        m.status, m.detail = "corrupt", "unreadable memory file kept as " .. keep
        if log then pcall(log, "combat: MEMORY CORRUPT: " .. m.detail) end
        return m
    end
    m.file_build = doc.build and tostring(doc.build) or nil
    if build and m.file_build ~= build then
        local keep = path:gsub("%.json$", "") .. ".build-" .. tostring(m.file_build) .. ".json"
        M.fs.remove(keep)
        M.fs.rename(from, keep)
        m.status = "refused_stale"
        m.detail = string.format("memory from build %s refused (client build %s); kept as %s; learning starts again",
            tostring(m.file_build), build, keep)
        if log then pcall(log, "combat: MEMORY REFUSED: " .. m.detail) end
        return m
    end
    local D, R = mod("defense"), mod("ranged")
    m.imported = { attacks = D and D.import and D.import(doc.defense) or 0, ranged = R and R.import and R.import(doc.ranged) or 0 }
    for name, v in pairs(type(doc.learned) == "table" and doc.learned or {}) do
        if c.learned[name] == nil then c.learned[name] = v end
    end
    c.learned_ver = (c.learned_ver or 0) + 1
    c.press_cost = c.press_cost or {}
    for k, v in pairs(type(doc.press_cost) == "table" and doc.press_cost or {}) do
        if c.press_cost[k] == nil then c.press_cost[k] = v end
    end
    c.hit_dmg = c.hit_dmg or {}
    for k, v in pairs(type(doc.hit_dmg) == "table" and doc.hit_dmg or {}) do
        if c.hit_dmg[k] == nil and type(v) == "number" then c.hit_dmg[k] = v end
    end
    m.history = type(doc.history) == "table" and doc.history or {}
    m.boss_attempts = type(doc.boss_attempts) == "table" and doc.boss_attempts or nil
    m.status = build and "loaded" or "loaded_build_unknown"
    m.saved_at = doc.saved_at
    if log then
        local n = 0
        for _ in pairs(m.history) do n = n + 1 end
        pcall(log, string.format("combat: memory loaded %s (build %s, %d attacks, %d creatures)", path, tostring(m.file_build), m.imported.attacks, n))
    end
    return m
end

-- -> the memory record (c.mem): the character's own first, then what his other characters learned of this world
function M.memory(log, pawn)
    local m = memory_own(log, pawn)
    if m and not m.off and m.known == nil then
        m.known = false
        pcall(M.knowledge_load, log, m)
    end
    return m
end

-- Which threat a hit just now came from (gap 7): the defence window it fell in (an ability or a named melee
-- attack), else poison when he is poisoned, else "other". Accumulated per fight in F.dmg_by.
function M.note_damage(F, amount)
    if not (F and amount and amount > 0) then return end
    local d = F.def
    local threat
    if d and d.tel_t and F.t and F.t - d.tel_t <= 4 then
        threat = (d.info and d.info.ability) and ("ability:" .. d.info.ability)
            or ("melee:" .. tostring(d.key and tostring(d.key):match(":(.+)$") or "?"))
    elseif ((C().statuses or {}).effects or {}).Poison then threat = "poison"
    else threat = "other" end
    F.dmg_by = F.dmg_by or {}
    F.dmg_by[threat] = math.floor(((F.dmg_by[threat] or 0) + amount) * 10) / 10
    F.last_threat = threat
end

-- A boss attempt (gap 7): phase reached, damage by threat, cause of death; newest last, at most cfg.attempts_max.
function M.record_boss_attempt(m, F, res)
    local name = F.target_name and tostring(F.target_name):lower()
    if not (m and name and F.boss) then return end
    m.boss_attempts = m.boss_attempts or {}
    local a = m.boss_attempts[name] or {}
    m.boss_attempts[name] = a
    local died = (res.data or {}).died == true or res.reason == "companion_down"
    a[#a + 1] = { at = os.time(), outcome = M._outcome_of(F, res), reason = res.reason,
                  phase_reached = F.boss_max_phase, phases = F.boss_phases,
                  damage_taken = math.floor((F.dmg_taken or 0) * 10) / 10, damage_by = F.dmg_by or {},
                  cause_of_death = died and (F.last_threat or "unknown") or nil,
                  boss_hp_left_pct = (F.target_hp and F.hp_start and F.hp_start > 0) and math.floor(100 * F.target_hp / F.hp_start) or nil,
                  dur_s = F.t and F.t0 and math.floor(F.t - F.t0) or nil, heals = F.n_heals or 0, cures = F.n_cures or 0 }
    while #a > M.cfg.attempts_max do table.remove(a, 1) end
end
function M.boss_attempts(name, m)
    m = m or C().mem
    local a = m and m.boss_attempts and name and m.boss_attempts[tostring(name):lower()] or nil
    if not a or #a == 0 then return nil end
    local dmg, phase, causes = {}, {}, {}
    for i, e in ipairs(a) do dmg[i] = e.damage_taken; phase[i] = e.phase_reached; if e.cause_of_death then causes[#causes + 1] = e.cause_of_death end end
    return { attempts = #a, damage_taken = dmg, phase_reached = phase, causes_of_death = causes, last = a[#a] }
end

-- Engaged seconds of a fight: from its first engage (else its start) to the loot or the end. -> s | nil
function M.fight_span(F)
    local a, b = F.engage_t or F.t0, F.fought_until or F.t
    if not (a and b) then return nil end
    return math.floor(math.max(b - a, 0) * 10) / 10
end

-- One fight into the creature's history (newest last, at most cfg.history_max).
function M.record_fight(m, F, res)
    local name = F.target_name and tostring(F.target_name):lower()
    if not (m and name) then return end
    local h = m.history[name] or {}
    m.history[name] = h
    h[#h + 1] = { at = os.time(), outcome = M._outcome_of(F, res), reason = res.reason, damage_taken = math.floor((F.dmg_taken or 0) * 10) / 10,
                  dur_s = F.t and F.t0 and math.floor((F.t - F.t0) * 10) / 10 or nil, kills = F.kills or 0,
                  parries = F.n_parried or 0, blocks = F.n_blocked or 0, dodges = F.n_dodges or 0, heals = F.n_heals or 0,
                  weapon = F.equip_plan and F.equip_plan.weapon or nil,
                  killed_by = M._outcome_of(F, res) == "died" and (F.last_hit_by or F.target_name) or nil,
                  -- what the odds learn from (M.learned_rates): engaged seconds, the most hostiles at once, his verified
                  -- damage on the target, and what was in his hands
                  fight_s = M.fight_span(F), pack = math.max(F.max_pack or 1, 1), dealt = math.floor((F.dmg or 0) * 10) / 10,
                  hands = (F.profile and F.profile.name) or "bare hands" }
    while #h > M.cfg.history_max do table.remove(h, 1) end
end

-- The fight he died in at about this time (a grave's ts): {creature, killed_by, at} | nil. A grave's danger beyond
-- falls (live 2026-11-02: "risk: none known" on the grave a Goblin Warrior killed him at; he ran back there at PL 0).
function M.killed_at(ts, m)
    m = m or C().mem
    ts = tonumber(ts)
    if not (m and m.history and ts) then return nil end
    local best, bd
    for name, h in pairs(m.history) do
        for _, e in ipairs(h) do
            local d = e.outcome == "died" and e.at and math.abs(e.at - ts) or nil
            if d and d <= 90 and (not bd or d < bd) then best, bd = { creature = name, killed_by = e.killed_by, at = e.at }, d end
        end
    end
    return best
end

-- Write the memory: tmp, then old -> .bak, tmp -> file, remove .bak. -> ok, err
function M.memory_save(log, m)
    m = m or C().mem
    if not m or m.off then return false, "no memory" end
    local J = json()
    if not J then return false, "no json" end
    local c = C()
    local D, R = mod("defense"), mod("ranged")
    local doc = { v = 1, build = m.build, world = m.world, character = m.char, saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                  defense = D and D.export and D.export() or nil, ranged = R and R.export and R.export() or nil,
                  learned = c.learned, press_cost = c.press_cost, hit_dmg = c.hit_dmg, history = m.history, boss_attempts = m.boss_attempts }
    local ok, txt = pcall(J.encode, doc)
    if not ok or type(txt) ~= "string" then return false, "encode: " .. tostring(txt) end
    local path, dir = M.memory_path(m.world, m.char)
    local tmp = path .. ".tmp"
    local f = M.fs.open(tmp, "wb")
    if not f and not m.mkdir_tried then -- the world's folder: created once, only if missing
        m.mkdir_tried = true
        M.fs.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
        f = M.fs.open(tmp, "wb")
    end
    if not f then m.save_err = "cannot write " .. tmp; return false, m.save_err end
    f:write(txt); f:close()
    local bak = path .. ".bak"
    M.fs.remove(bak)
    local had = M.fs.rename(path, bak)
    local okr, err = M.fs.rename(tmp, path)
    if not okr then
        if had then M.fs.rename(bak, path) end
        m.save_err = "rename: " .. tostring(err)
        if log then pcall(log, "combat: memory save failed: " .. m.save_err) end
        return false, m.save_err
    end
    M.fs.remove(bak)
    m.saves, m.save_err, m.saved_at = (m.saves or 0) + 1, nil, doc.saved_at
    pcall(M.knowledge_save, m, doc)
    return true
end

-- The brain's view of one creature's history: counts, the damage-taken series, outcomes, first encounter.
function M.creature_history(name, m)
    m = m or C().mem
    local h = m and name and m.history[tostring(name):lower()] or nil
    if not h or #h == 0 then return { fights = 0, first_encounter = true } end
    local dmg, out = {}, {}
    for i, e in ipairs(h) do dmg[i] = e.damage_taken; out[i] = e.outcome end
    return { fights = #h, first_encounter = false, damage_taken = dmg, outcomes = out, last_at = h[#h].at }
end

-- A family prior for damage-type verdicts: a learned creature sharing a name token (data words, labelled).
function M.family_affinity(name, learned)
    learned = learned or C().learned
    local D = mod("defense")
    if not (D and D._tokens and name) then return nil end
    local want = D._tokens(name)
    local best, bn
    for other, v in pairs(learned) do
        if other ~= tostring(name):lower() and type(v) == "table" and next(v) then
            local n = 0
            for k in pairs(D._tokens(other)) do if want[k] then n = n + 1 end end
            if n > 0 and (not bn or n > bn) then best, bn = other, n end
        end
    end
    if not best then return nil end
    return { from = best, verdicts = learned[best], label = "prior:family" }
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
    cap.block_angle = num(U.try(function() return pc.Pawn.PlayerBlockingComponent.BlockingAngle end)) -- (degrees in front of him)
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
    return M._outcome_of(F, res)
end
function M._outcome_of(F, res)
    if res.ok and F.kills > 0 then return "killed" end
    local d = res.data or {}
    if d.fled then return "fled" end
    if d.died then return "died" end
    local r = res.reason
    if r == "unknown_target" or r == "too_far" then return "lost" end
    if r == "timeout" then return "timeout" end
    if r == "unsafe" then return "failed" end
    return res.ok and "done" or "interrupted"
end

-- Time in the fight he did NOT swing, by cause (one decision tick each): defending, casting, out_of_reach, stamina,
-- closing_in, backing_off, fleeing. Reported in the result, the combat_end event and the fight-end log line, so
-- "presses=0" always comes with its reason (live 2026-11-01 11:28: 10 s against a runt, 0 swings, no reason logged).
function M.held(F, why)
    F.held_s = F.held_s or {}
    F.held_s[why] = (F.held_s[why] or 0) + M.DECIDE_S
end
local function held_summary(F)
    local out, parts = nil, {}
    for k, v in pairs(F.held_s or {}) do
        if v >= 0.05 then out = out or {}; out[k] = math.floor(v * 10 + 0.5) / 10; parts[#parts + 1] = string.format("%s %.1fs", k, v) end
    end
    table.sort(parts)
    return out, table.concat(parts, ", ")
end
M._held_summary = held_summary

local function result_of(F, ok, reason, data)
    data = data or {}
    data.target = F.target_name
    data.target_id = F.target_id
    data.presses, data.hits, data.kills = F.presses, F.hits, F.kills
    if F.killed_by then data.target_killed_by = F.killed_by end
    if F.others_dmg then data.others_damage_to_target = math.floor(F.others_dmg) end
    if F.rg and (F.rg.shots or 0) > 0 then data.shots = { fired = F.rg.shots, hits = F.rg.hits, misses = F.rg.misses } end
    data.looted = F.looted
    data.phase_log = F.phase_log
    data.defense = { parries = F.n_parried or 0, blocks = F.n_blocked or 0, dodges = F.n_dodges or 0, jumps = F.n_jumps or 0,
                     abilities = F.n_abilities, precasts = F.n_precasts,
                     avoided = F.n_avoided or 0, hits_taken = F.n_hit or 0, heals = F.n_heals or 0 }
    data.damage_taken = F.dmg_taken or 0
    data.held_back_s = held_summary(F)
    if F.cornered then data.cornered = F.cornered end
    if F.mode == "attack" and F.first then M.fought_words(F, data) end
    return { ok = ok, reason = reason, data = data }
end

local function set_phase(F, ph, why)
    if F.phase == ph then return end
    F.phase = ph
    F.phase_t = F.t
    -- the engaged span (his fight record's fight_s: first engage to the loot or the end; M.learned_rates)
    if ph == "engage" and not F.engage_t then F.engage_t = F.t end
    if (ph == "loot" or ph == "restore") and not F.fought_until then F.fought_until = F.t end
    -- the fight is over: the bow stops aiming at the corpse (live 07:35Z bow gate: the aim kept the camera, so the
    -- loot walk stopped twice on "another skill took the camera" and 17 s passed with nothing picked up)
    if F.rg and (ph == "loot" or ph == "restore") then F.rg.aiming, F.rg.aim_t0, F.hold = false, nil, nil end
    F.phase_log[#F.phase_log + 1] = string.format("%.1f %s%s", F.t - F.t0, ph, why and (" " .. why) or "")
    if #F.phase_log > 30 then table.remove(F.phase_log, 1) end
    say(F.log, "phase " .. ph .. (why and (" (" .. why .. ")") or "") .. " target=" .. tostring(F.target_name))
end

local function tap(F, action, frames, label)
    if not action then return false end
    F.inputs[#F.inputs + 1] = { act = action, frames = frames or M.cfg.tap_frames, label = label }
    return true
end

-- What he carries, by name (hotbar + bag; the loadout's ammo rows are the bag's stacks): for the loot actually gained.
local function carried_counts()
    local l = mcall("inventory", "list", nil) or {}
    local out = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(l[where] or {}) do
            local k = e.name or e.item
            if k then out[k] = (out[k] or 0) + (e.count or 1) end
        end
    end
    return out
end
M._carried_counts = carried_counts

-- The loot as his inventory's change across the loot phase (a pile is one pickup of several stacks: live 2026-11-01 a
-- cow's pile read "Animal Hide x1" while he got 3 Raw Farm Meat, 3 Animal Hide and 2 Animal Bone).
local function loot_gain(F)
    if not F.loot_inv0 then return nil end
    local now_c, out = carried_counts(), {}
    for k, n in pairs(now_c) do
        local g = n - (F.loot_inv0[k] or 0)
        if g > 0 then out[#out + 1] = { name = k, count = g } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.emit_combat_end(F, res)
    local d = res.data or {}
    local gain = loot_gain(F)
    local loot = gain or F.loot_names
    if F.dead_seen then
        local c = C()
        c.recent_kills = c.recent_kills or {}
        -- class: the game's class word of the creature (its sense row's .class), so a kill is matched to the bestiary
        -- by what the game calls it, not only by its AIName (tools/job_run.p_boss_killed)
        table.insert(c.recent_kills, 1, { creature = F.target_name, class = F.target_class, iso =os.date("!%Y-%m-%dT%H:%M:%SZ"), mine = F.kills > 0,
            killed_by = F.killed_by, loot = loot, looted = F.loot_inv0 ~= nil })
        while #c.recent_kills > 5 do table.remove(c.recent_kills) end
    end
    M.emit_activity({ kind = "combat_end", by = F.by or "unknown", dur_s = F.t and F.t0 and math.floor((F.t - F.t0) * 10) / 10 or nil,
        target = F.target_name, target_id = F.target_id, outcome = outcome_of(F, res), reason = res.reason,
        damage_taken = F.dmg_taken or 0, damage_dealt = math.max(0, (F.hp_start or 0) - (F.target_hp or 0)), fight_s = M.fight_span(F),
        hp_end = F.hp_now, loot = loot, parries = F.n_parried or 0, blocks = F.n_blocked or 0,
        dodges = F.n_dodges or 0, jumps = F.n_jumps or 0, heals = F.n_heals or 0, cures = F.n_cures or nil, presses = F.presses, why = F.why,
        windup_swings = F.n_windup, step_stalls = F.n_step_stalls, dodge_retaps = F.n_retaps,
        pack = (F.max_pack or 0) > 1 and F.max_pack or nil, kills = F.kills, multi_swings = F.n_multi, hazards = F.n_hazards,
        fled_why = d.why, detail = d.detail, still_chased = d.still_chased, held_back_s = d.held_back_s, cornered = d.cornered,
        fled_m = F.fled_m and math.floor(F.fled_m) or nil })
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
    if F.zones_set or F.escape then mcall("move", "set_avoid_zones", F.log, {}) end -- the hazards were this fight's
    F.result = res
    c.last = { result = res, mode = F.mode, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.fight == F then c.fight = nil end
    if F.flee_why and not F.cornered and F.target_id and F.t then -- (guard_tick: it comes after him again -> he fights)
        c.fled_from = c.fled_from or {}
        c.fled_from[F.target_id] = F.t
    end
    M.emit_combat_end(F, res)
    do -- the fight's end: the only time the memory is written (a file write; no game call)
        local m = c.mem
        if m then
            pcall(M.record_fight, m, F, res)
            pcall(M.record_boss_attempt, m, F, res)
            local okw, err = pcall(M.memory_save, F.log, m)
            if not okw then m.save_err = tostring(err) end
        end
    end
    local arb = mod("arbiter")
    if arb and F.token then pcall(arb.release, F.log, F.token, res.ok and "done" or res.reason) end
    local _, held_txt = held_summary(F)
    say(F.log, string.format("fight end ok=%s reason=%s presses=%d (%d in a wind-up) hits=%d dmg_taken=%.0f held back: %s", tostring(res.ok), tostring(res.reason),
        F.presses, F.n_windup or 0, F.hits, F.dmg_taken or 0, held_txt ~= "" and held_txt or "-"))
end
M._finish = finish

local function follow_target(F, dist_m, sprint)
    if F.t - (F.follow_t or -9) < 1.0 then return F.following end -- at most one (re)start per second
    F.follow_t = F.t
    local cfg = M.cfg
    local r = mcall("move", "follow", F.log, F.target_id, dist_m, { sprint = sprint, face_when_near = true, nav = false, owner_token = F.token,
        progress = { stall_s = cfg.approach_stall_s, gain_m = cfg.approach_gain_m, budget_s = cfg.chase_max_s, budget_per_m = cfg.chase_per_m_s,
                     moving_m = cfg.chase_moved_m } })
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
-- Would this held item hit anything? A weapon (or a tool with a fighting score, like an axe) yes; a fishing rod,
-- net, torch, spade, or an item the data does not know: no (live 15:38:59: killed while fishing, 4 swings of a rod,
-- 0 hits).
function M.fights_with(item_id)
    local p = item_id and (M.weapons().items or {})[item_id]
    if not p then return false end
    if p.role == "shield" then return true end
    if p.kind == "ranged" or p.kind == "magic" then return p.role == "weapon" end
    return M.score_weapon(p, {}, nil) ~= nil
end

local function step_equip(F, pawn)
    if not F.equip_plan then
        -- the tool job he was doing must not keep acting: a job the arbiter SUSPENDED for this fight has already
        -- paused its inputs and resumes afterwards (left alone); one running outside the arbiter is stopped with its
        -- module's own stop (a no-op when idle)
        local suspended = {}
        local arb = mod("arbiter")
        local ast = arb and arb.status and arb.status() or {}
        for _, r in ipairs(ast.suspended or {}) do suspended[#suspended + 1] = tostring(r.name) end
        for name, job_prefix in pairs(M.cfg.tool_jobs) do
            local paused = false
            for _, n in ipairs(suspended) do if n:find(job_prefix, 1, true) == 1 then paused = true end end
            local m = not paused and mod(name)
            if m and type(m.stop) == "function" then pcall(m.stop, F.log, "attacked: " .. tostring(F.target_name)) end
        end
        local list = mcall("inventory", "list", F.log) or {}
        local enemy = { name = F.target_name, affinities = F.affinities }
        local pick = M.best_weapon(list, enemy, nil, C().learned)
        local items = M.weapons().items or {}
        if F.weapon_pref == "held" then
            -- fight with whatever is in his hands now (bare hands included): no swap
            local hr, hl = held_items(pawn)
            local hid = hr or hl
            pick = { weapon = hid and { entry = { item = hid }, profile = items[hid] or {}, score = 0 } or nil }
        elseif F.weapon_pref then
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
            -- (a WEAPON only: the fishing rod's data says kind "magic", role "tool"; live 16:03: he swung the Ash Rod)
            -- ... and only while it does at least what his best melee weapon does, by his own learned damage: Ranged 1
            -- with Stone Arrows hits for ~4 (live 22:05Z: he kept the Ash Shortbow he had out, with a Stone Club in the
            -- bag, so the fight read "too_strong" and he ran; Luis: "you have a club but keep switching to your bow")
            if hp and (hp.kind == "ranged" or hp.kind == "magic") and hp.role == "weapon" then
                local held_dps = M.my_dps(hp) -- nil: nothing known about it yet, so it stays
                local melee = pick.weapon and pick.weapon.profile
                local melee_dps = melee and melee.kind == "melee" and M.my_dps(melee) or 0
                if held_dps == nil or held_dps >= melee_dps then pick = { weapon = { entry = { item = hid }, profile = hp, score = 0 } }
                else say(F.log, string.format("held %s does %.1f/s, %s %.1f/s: fighting with the %s", tostring(hp.name), held_dps or 0,
                    tostring(melee.name), melee_dps, tostring(melee.name))) end
            end
        end
        F.equip_plan = { weapon = pick.weapon and pick.weapon.entry.item, shield = nil, sent = {}, t = F.t }
        if not pick.weapon and F.weapon_pref ~= "held" then
            -- no weapon he owns: put the held tool away and fight bare-handed (a rod would never land a hit)
            local hr, hl = held_items(pawn)
            local drop = {}
            if hr and not M.fights_with(hr) then drop[#drop + 1] = "HeldRight" end
            if hl and not M.fights_with(hl) then drop[#drop + 1] = "HeldLeft" end
            if #drop > 0 then F.equip_plan.drop = drop end
        end
        if pick.weapon then
            F.profile = pick.weapon.profile
            F.weapon_score = pick.weapon.score
            if pick.shield and pick.weapon.profile.slot ~= "two_handed" and pick.weapon.profile.kind == "melee" then F.equip_plan.shield = pick.shield.entry.item end
        end
        F.prev_right, F.prev_left = held_items(pawn)
        -- a two-handed tool (the Mithril Logging Axe) is reported in the LEFT hand only (DISCOVERIES R2):
        -- restore whatever was the main held item
        F.prev_main = F.prev_right or F.prev_left
        say(F.log, string.format("weapon %s (score %.1f%s) shield %s; held before %s / %s", tostring(F.equip_plan.weapon),
            F.weapon_score or 0, (pick.weapon and pick.weapon.why) and (", " .. pick.weapon.why) or "", tostring(F.equip_plan.shield),
            tostring(F.prev_right), tostring(F.prev_left)))
    end
    local plan = F.equip_plan
    local right, left = held_items(pawn)
    if plan.drop then -- hands free first (unequip the tool): verified by the held items, at most 4 s
        local still = {}
        for _, slot in ipairs(plan.drop) do
            local item = slot == "HeldRight" and right or left
            if item and not M.fights_with(item) then still[#still + 1] = slot end
        end
        if #still == 0 then plan.drop = nil; F.profile = nil; say(F.log, "tool put away: bare hands")
        elseif F.t - plan.t > 4 then plan.drop = nil; say(F.log, "could not put the tool away in 4 s; fighting with it")
        else
            for _, slot in ipairs(still) do
                if not plan.sent[slot] or F.t - plan.sent[slot] > 1.5 then
                    plan.sent[slot] = F.t
                    local r = mcall("inventory", "unequip", F.log, slot)
                    say(F.log, "unequip " .. slot .. " (a tool, not a weapon) -> " .. tostring(r and (r.via or r.reason)))
                end
            end
            return false
        end
    end
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

-- ONE estimate of what a creature's attacks cost him per second PER ATTACKER, for the reflex AND get_state's
-- fight_odds. Sources, best first (measured 16-18 Nov: defense.lua's per-attack rate read 2-3x too low against his
-- real deaths, e.g. "182 s to die" vs 80 s, so it comes last):
--   his own fights with it (M.learned_rates: damage taken per engaged second per attacker),
--   the game's attack damage (creature_attacks.lua, from DT_AIAttackDamage via data/bestiary.json) x
--     cfg.odds_landed_per_s,
--   defense.lua's learned rate (its learned attack damage x the share that landed / its attack rhythm),
--   nil (M.assess then takes the power-level prior and calls the odds "unknown"). -> dps, source | nil
function M.enemy_dps(name)
    if not name then return nil end
    local key = tostring(name):lower()
    local L = M.learned_rates().theirs[key]
    if L then return math.max(L.dps, 0.01), string.format("his last %d fights with it", L.n) end
    local ga = (M.data("creature_attacks") or {})[key]
    if ga and tonumber(ga.mean) and ga.mean > 0 then return ga.mean * (M.cfg.odds_landed_per_s or 0.024), "game attack data" end
    local D = mod("defense")
    if not (D and D.expected_dps) then return nil end
    local ok, dps = pcall(D.expected_dps, name)
    if ok and type(dps) == "number" and dps > 0 then return dps, "its attacks on him (rough)" end
    return nil
end

-- Every hostile in the fight: the target, what hit him lately, and every aggressive creature within aggro range,
-- fighting yet or not (fight study 2026-11-18: two deaths came from packs that joined after the odds were read on one
-- runt, "likely win, 20 s to die", pack 3-4 at the end).
local function enemies_for_assess(F, origin)
    local c = C()
    local list = {}
    for _, cr in ipairs(creatures_near(origin, M.cfg.assist_m)) do
        local hit = c.attackers[cr.id]
        if cr.id == F.target_id or (hit and F.t - hit <= M.cfg.attacker_memory_s) or (cr.archetype == 0 and (cr.distance_m or 99) < M.cfg.aggro_m) then
            if not cr.dead and not cr.follower then
                cr.dps_obs, cr.dps_src = M.enemy_dps(cr.name)
                list[#list + 1] = cr
            end
        end
    end
    return list
end

-- Flee uses one fresh, observed threat set for both safety and escape geometry.
local function flee_threats(F, me)
    if not me.pos then return nil, "position unavailable" end
    local ok, actors = pcall(FindAllOf, "DominionAICharacter")
    if not ok or type(actors) ~= "table" then return nil, "threat census unavailable" end
    local out, c, seen = {}, C(), {}
    for _, actor in ipairs(actors) do
        if U.alive(actor) and not (U.fullname(actor) or ""):find("Default__", 1, true) then
            local id, pos = U.short(actor), U.loc(actor)
            if id then seen[id] = true end
            local hit, tele = id and c.attackers[id], id and c.telegraphs[id]
            local recent = (hit and F.t - hit <= M.cfg.attacker_memory_s) or (tele and F.t - tele <= M.cfg.attacker_memory_s)
            if recent or id == F.target_id then
                if not pos then return nil, "observed threat position unavailable" end
                if U.dist(me.pos, pos) <= M.cfg.safe_m * 100 then
                    local good, cr = pcall(read_creature, actor, me.pos)
                    if not good or not cr or (id == F.target_id and not recent and cr.in_combat == nil) then return nil, "threat state unavailable" end
                    if not cr.dead and not cr.follower and (recent or (id == F.target_id and cr.in_combat)) then out[#out + 1] = { id = id, pos = pos } end
                end
            end
        end
    end
    for _, tracked in ipairs({ c.attackers, c.telegraphs }) do
        for id, t in pairs(tracked) do
            if F.t - t <= M.cfg.attacker_memory_s and not seen[id] then return nil, "recent threat not visible" end
        end
    end
    return out
end

local function flee_owned(F)
    local a = mod("arbiter")
    local token, gen = F.token, F.gen
    local ok = a and a.owns_move and a.owns_move(token)
    return ok and C().fight == F and C().gen == gen and not F.done and F.phase == "flee" and F.token == token
end

local function flee_move(F, me, threats)
    if not flee_owned(F) then return nil, "movement ownership lost" end
    local sx, sy = 0, 0
    for _, threat in ipairs(threats) do sx, sy = sx + threat.pos.X, sy + threat.pos.Y end
    if #threats == 0 then return nil, "no observed threat position" end
    local dx, dy = me.pos.X - sx / #threats, me.pos.Y - sy / #threats
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return nil, "threat direction unresolved" end
    local far = M.cfg.flee_far_m * 100
    if F.flee_from then -- never past the leash (a leg of at least 6 m)
        local left = M.cfg.flee_leash_m * 100 - U.dist2d(me.pos, F.flee_from)
        far = math.max(600, math.min(far, left + 200))
    end
    local goal = { (me.pos.X + dx / length * far) / 100, (me.pos.Y + dy / length * far) / 100, me.pos.Z / 100 }
    local r = mcall("move", "go_to", F.log, goal, { sprint = true, tolerance_m = 3,
        timeout_s = M.cfg.flee_timeout_s, owner_token = F.token })
    if not flee_owned(F) then return nil, "movement ownership lost" end
    if type(r) ~= "table" or r.ok ~= true then return nil, "escape movement rejected" end
    F.flee_to, F.drove_move, F.flee_follow, F.flee_move_pending = goal, true, false, true
    return true
end

-- Running to the protected player helps only when he is near and NOT next to what is hitting me (live 11:28 the
-- flee followed Luis, who stood beside the runt: 22 -> 4 HP "fleeing"). -> true when ally_pos qualifies.
function M.ally_is_refuge(ally_pos, me_pos, threats)
    if not (ally_pos and me_pos) then return false end
    if U.dist2d(ally_pos, me_pos) > M.cfg.flee_ally_m * 100 then return false end
    for _, th in ipairs(threats or {}) do
        if th.pos and U.dist2d(ally_pos, th.pos) < M.cfg.ally_clear_m * 100 then return false end
    end
    return threats ~= nil
end

local function begin_flee(F, why)
    if F.cornered then return end -- it already kept up with one flee: he fights it out (no second run)
    C().counts.flees = C().counts.flees + 1
    F.flee_why, F.decision, F.inputs = why, "flee", {}
    set_phase(F, "flee", why)
    -- the leash anchor: a flee never takes him farther than cfg.flee_leash_m from here
    F.flee_from = F.me_pos and { X = F.me_pos.X, Y = F.me_pos.Y, Z = F.me_pos.Z } or nil
    F.fled_m = 0
    F.flee_hp0 = F.hp_now
    M.emit_activity({ kind = "flee_started", by = F.by or "unknown", from = F.target_name, from_id = F.target_id, why = why, hp = F.hp_now,
                      leash_m = M.cfg.flee_leash_m, max_s = M.cfg.flee_timeout_s })
    F.safe_since, F.flee_retry_t, F.flee_failures = nil, F.t - 1, 0
    local luis = M.orders.protect or M.cfg.protect or M.nearest_player_name(F.me_pos)
    if luis and flee_owned(F) then
        local threats = F.me_last and flee_threats(F, F.me_last) or nil
        if not M.ally_is_refuge(M.player_pos(luis), F.me_pos, threats) then return end -- (step_flee runs away instead)
        local r = mcall("move", "follow", F.log, luis, 3, { sprint = true, owner_token = F.token })
        if not flee_owned(F) then return end
        if type(r) == "table" and r.ok == true and r.target_visible ~= false then
            F.flee_to, F.drove_move, F.flee_follow = luis, true, true
        end
    end
end

-- Cornered: still chased at the leash / the time limit (it is as fast as he is), or it came after him again
-- right after a flee. Running more only gives it free hits, so he turns and fights it out, and says so.
local function turn_to_fight(F, me, why)
    F.cornered = why
    F.decision = "fight"
    F.flee_follow, F.flee_move_pending, F.following = false, false, false
    mcall("move", "stop", F.log)
    M.emit_activity({ kind = "flee_failed", by = F.by or "unknown", from = F.target_name, from_id = F.target_id, why = why,
                      fled_m = F.fled_m and math.floor(F.fled_m) or nil, hp = me.hp, next = "fighting back" })
    F.assess_t = -9
    set_phase(F, "approach", "cornered: " .. why)
end
M._turn_to_fight = turn_to_fight

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

local eat_allowed -- (defined below; status_frame uses it)
-- ------------------------------------------------------------------ status effects (velgar.md gap 4)
-- His own tracked statuses, by PROPERTY reads only (pawn.TrackedStatusEffectsComponent.TrackedStatusEffectInstances:
-- EffectType, CurrentValue, Config.MaximumValue; dump 26161880); no UFunction call. -> {Poison = {value, max}, ...}
M.TRACKED = { [1] = "Cold", [2] = "Poison", [3] = "Burning", [4] = "Bleeding", [5] = "Slow", [6] = "WellRested", [7] = "Cosiness",
              [8] = "Wither", [9] = "Scorch", [10] = "AnimaCharge", [11] = "SoulScourge", [12] = "Shocked", [13] = "Chilled",
              [14] = "SlowBuildup", [15] = "OverEating", [16] = "Hamstrung" }
M.HARMFUL = { Cold = true, Poison = true, Burning = true, Bleeding = true, Slow = true, Wither = true, Scorch = true, SoulScourge = true,
              Shocked = true, Chilled = true, SlowBuildup = true, Hamstrung = true }
function M.read_statuses(pawn)
    local comp = U.try(function() return pawn.TrackedStatusEffectsComponent end)
    if not U.valid(comp) then return nil end
    local out = {}
    pcall(function()
        comp.TrackedStatusEffectInstances:ForEach(function(_, e)
            local inst = U.try(function() return e:get() end) or e
            if U.valid(inst) then
                local ty = num(U.try(function() return inst.EffectType end))
                local v = num(U.try(function() return inst.CurrentValue end))
                local name = ty and M.TRACKED[ty]
                if name and v and v > 0 then
                    out[name] = { value = math.floor(v * 10) / 10, max = num(U.try(function() return inst.Config.MaximumValue end)),
                                  harmful = M.HARMFUL[name] or nil }
                end
            end
        end)
    end)
    return out
end

-- What a consumable does to statuses (client_mod/scripts/consumable_wiki.lua, generated from the wiki snapshot).
function M.consumable_info(name)
    local CONS = M.data("consumable_wiki")
    return CONS and name and CONS[tostring(name):lower()] or nil
end

-- The best carried item against a status: one that CURES it first, then the strongest resistance; the hotbar
-- before the bag (inventory.use moves nothing; a bag item answers in_bag). -> entry, info, "cures"|"resists"
function M.best_cure(list, status)
    local best, binfo, bhow, bscore
    for wi, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            local info = M.consumable_info(e.name)
            if info then
                local cures = false
                for _, st in ipairs(info.cures or {}) do if st == status then cures = true end end
                local res = (info.resists or {})[status]
                if cures or res then
                    local sc = (cures and 1000 or 0) + (res or 0) + (wi == 1 and 5 or 0)
                    if not bscore or sc > bscore then best, binfo, bhow, bscore = e, info, cures and "cures" or "resists", sc end
                end
            end
        end
    end
    return best, binfo, bhow
end

-- Perks he took (remembered from his own use of an item, with the wiki duration): {perk = {until, from}}
local function remember_buffs(c, item_name, info)
    c.buffs = c.buffs or {}
    for _, perk in ipairs((info and info.perks) or {}) do
        c.buffs[perk] = { until_t = os.time() + (info.duration_s or 0), from = item_name, resists = info.resists }
    end
end
function M.active_buffs()
    local c, out, t = C(), {}, os.time()
    for perk, b in pairs(c.buffs or {}) do
        if b.until_t > t then out[perk] = { left_s = b.until_t - t, from = b.from, resists = b.resists } else c.buffs[perk] = nil end
    end
    return out
end

-- Per fight tick (every cfg.status_s): read the statuses; poisoned (or any status a carried item cures) above
-- cfg.cure_at of its maximum -> use the cure (one at a time, verified: the value drops -> a "cured" event).
-- The ONE writer of c.statuses: a fresh read unless the cached one is younger than max_age_s. -> effects | nil
function M.refresh_statuses(pawn, max_age_s)
    local c = C()
    local cur = c.statuses
    if cur and max_age_s and os.clock() - (cur.clock or -99) < max_age_s then return cur.effects end
    local st = M.read_statuses(pawn)
    if st then c.statuses = { t = os.time(), clock = os.clock(), effects = st } end
    return st
end

-- Carried items' signature (what a "no cure" verdict depends on).
local function inv_sig(list)
    local parts = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do parts[#parts + 1] = tostring(e.item) .. "x" .. tostring(e.count) end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function M.status_frame(F, pawn, me)
    if F.t - (F.status_t or -9) < M.cfg.status_s then return end
    F.status_t = F.t
    local c = C()
    local st = M.refresh_statuses(pawn, nil)
    if not st then return end
    local cp = F.cure_pending
    if cp and F.t - cp.t >= 3 then
        F.cure_pending = nil
        if F.ambient then M.ambient_release(F, "cure checked") end
        local now_v = (st[cp.status] or {}).value or 0
        if now_v < cp.v0 - 0.5 then
            F.n_cures = (F.n_cures or 0) + 1
            M.emit_activity({ kind = "cured", by = F.by or "unknown", status = cp.status, item = cp.item, before = cp.v0, after = now_v })
            say(F.log, string.format("cured %s %.0f -> %.0f (%s)", cp.status, cp.v0, now_v, cp.item))
        else
            F.cure_fails = (F.cure_fails or 0) + 1
        end
    end
    if F.cure_pending or F.phase == "defend" then return end
    F.no_cure = F.no_cure or {}
    for status, e in pairs(st) do
        local nc = F.no_cure[status]
        -- a status he had no cure for is looked at again only every cfg.no_cure_recheck_s (and only acted on if the
        -- carried items changed): no inventory read at the status cadence
        if e.harmful and e.value >= M.cfg.cure_at * (e.max or 100) and not (nc and F.t - nc.t < M.cfg.no_cure_recheck_s) then
            local list = mcall("inventory", "list", F.log) or {}
            local sig = inv_sig(list)
            if nc and nc.sig == sig then nc.t = F.t; return end
            local item, info, how = M.best_cure(list, status) -- the cure first, then whether he may eat now
            if not item then
                if not nc then
                    M.emit_activity({ kind = "status", by = F.by or "unknown", status = status, value = e.value, max = e.max,
                                      have_cure = false })
                end
                F.no_cure[status] = { t = F.t, sig = sig }
                return
            end
            F.no_cure[status] = nil
            local ok = eat_allowed(F)
            if not ok then return end
            if F.ambient and not M.ambient_acquire(F, "cure " .. status) then return end
            F.next_eat = F.t + M.cfg.eat_every_s
            local r = mcall("inventory", "use", F.log, item.item)
            say(F.log, string.format("%s %s %.0f: use %s (%s) -> %s", status, how, e.value, tostring(item.name), tostring(item.item),
                tostring(r and (r.via or r.reason))))
            F.cure_pending = { t = F.t, status = status, v0 = e.value, item = item.name or item.item }
            remember_buffs(c, item.name, info)
            return
        end
    end
end

eat_allowed = function(F, kind)
    if F.next_eat and F.t < F.next_eat then return false, "cooldown" end
    -- one use at a time per kind: a press during another use's ~6 s animation of the same kind is ignored by the game
    -- (a food and a drink overlap: inventory.consume_busy(kind)); no kind = any use in progress
    if mcall("inventory", "consume_busy", kind) then return false, "consume_in_progress" end
    local st = mcall("inventory", "eat_status")
    if type(st) == "table" and st.can_eat == false then
        if st.cooldown_s then F.next_eat = F.t + st.cooldown_s end
        return false, st.reason or "game_refuses"
    end
    return true
end

local function try_eat(F, me, force, verify_only)
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
    if F.heal_pending or verify_only then return end
    local frac = (me.hp or 0) / me.max_hp
    if not force and frac >= M.cfg.eat_hp then return end
    local ok, why = eat_allowed(F, "food")
    if not ok then return false, why end
    local list = mcall("inventory", "list", F.log) or {}
    local pick = best_heal_food(list) or mcall("inventory", "best_consumable", list, "food")
    if not pick then F.no_food = true; return false, "no_food" end
    F.next_eat = F.t + M.cfg.eat_every_s
    local r = mcall("inventory", "use", F.log, pick.item)
    say(F.log, "eat " .. tostring(pick.item) .. " hp=" .. tostring(me.hp) .. " -> " .. tostring(r and (r.via or r.reason)))
    F.ate = (F.ate or 0) + 1
    F.heal_pending = { t = F.t, hp0 = me.hp or 0, food = pick.name or pick.item }
    return true
end
M._try_eat = try_eat

local function step_flee(F, pawn, me)
    if not flee_owned(F) then return end
    local threats, why = flee_threats(F, me)
    if not flee_owned(F) then return end
    -- eat only with every threat out of its reach: a bite mid-hit is wasted time under its blows (live 11:28
    -- "stopping to eat whilst getting hit"); the pending bite is verified either way
    local near_cm
    for _, th in ipairs(threats or {}) do
        local d = (th.pos and me.pos) and U.dist2d(th.pos, me.pos)
        if d and (not near_cm or d < near_cm) then near_cm = d end
    end
    local clear = threats ~= nil and (near_cm == nil or near_cm >= M.cfg.eat_clear_m * 100)
    try_eat(F, me, false, not clear)
    if me.pos and F.flee_from then F.fled_m = U.dist2d(me.pos, F.flee_from) / 100 end
    local leashed = F.fled_m ~= nil and F.fled_m >= M.cfg.flee_leash_m
    if leashed and not F.leash_stop then -- the leash: no farther, whatever the threats look like
        F.leash_stop = true
        F.flee_follow, F.flee_move_pending = false, false
        mcall("move", "stop", F.log)
    end
    if not threats then
        F.safe_since = nil
        F.flee_error = why
    elseif #threats == 0 then
        F.safe_since = F.safe_since or F.t
        if F.t - F.safe_since >= M.cfg.safe_s then
            return finish(F, result_of(F, F.mode ~= "attack", F.mode == "attack" and "unsafe" or nil,
                { fled = true, why = F.flee_why, hp = me.hp }))
        end
    else
        F.safe_since = nil
        -- it keeps hitting him while he runs: running only gives it free hits (and he cannot defend on the move), so
        -- he turns and fights while he still has the HP to (live 2026-11-01 21:50Z: a Giant Rat bit him from 100 to
        -- 40 HP over a 15 s flee that stuck against the ground for 9 s; he died fighting it at 60 HP after)
        local lost = (F.flee_hp0 and me.hp) and (F.flee_hp0 - me.hp) or 0
        if lost >= (me.max_hp or 100) * (M.cfg.flee_caught_frac or 0.2) then
            -- "it is faster than me" is remembered only when he really ran: a flee stuck on the ground says nothing
            -- about its speed (the 21:50 flee stuck 9 s and marked the Giant Rat uncatchable; measured 06:4xZ: its
            -- MaxWalkSpeed 600 vs his sprint 680, and at 06:05 that memory alone kept him punching it bare-handed)
            local el = math.max(F.t - (F.phase_t or F.t), 0.1)
            local ran = (F.fled_m or 0) * 100 / el
            local spr = num(U.try(function() return pawn.CharacterMovement:GetSprintingMaxSpeed() end)) or 680
            if ran >= spr * (M.cfg.caught_ran_frac or 0.6) then
                local cb = C().caught_by or {}
                C().caught_by = cb
                cb[F.target_name or "?"] = true
            else
                say(F.log, string.format("flee: hit while running at %.1f m/s (sprint %.1f): stuck, not outrun; not remembered as faster",
                    ran / 100, spr / 100))
            end
            return turn_to_fight(F, me, string.format("it kept hitting me while I ran (%d HP in %d s)", math.floor(lost), math.floor(F.t - F.phase_t)))
        end
        -- bounded: at the leash (or the time limit) with a threat still after him, it is as fast as he is. Handing his
        -- legs back with it still chasing only lets it bite him on the way (21:50:51Z: "unsafe", the go_to resumed,
        -- the rat followed and caught him 8 s later)
        if (leashed or F.t - F.phase_t > M.cfg.flee_timeout_s) and near_cm then
            if leashed then -- he ran the whole leash and it is still on him: remembered (this session), no second run from one
                local cb = C().caught_by or {}
                C().caught_by = cb
                cb[F.target_name or "?"] = true
            end
            return turn_to_fight(F, me, string.format("it kept up with me for %d m", math.floor(F.fled_m or 0)))
        end
        if not leashed and F.t - (F.flee_retry_t or -9) >= 1 then
            local st = mcall("move", "status")
            if not flee_owned(F) then return end
            if type(st) ~= "table" then
                F.flee_error = "escape movement status unavailable"
            elseif st.mode == "idle" then
                F.flee_retry_t = F.t
                if F.flee_move_pending then
                    F.flee_move_pending = false
                    if st.result and st.result.status == "failed" then
                        F.flee_failures = (F.flee_failures or 0) + 1
                        F.flee_error = "escape movement failed: " .. tostring(st.result.reason or st.result.why or "unknown")
                    end
                end
                if (F.flee_failures or 0) >= 3 then
                    return finish(F, result_of(F, false, "unsafe", { fled = false, why = F.flee_why, still_chased = true, detail = F.flee_error }))
                end
                local ok, err = flee_move(F, me, threats)
                if not flee_owned(F) then return end
                if not ok then F.flee_failures, F.flee_error = (F.flee_failures or 0) + 1, err end
            end
        end
    end
    if F.t - F.phase_t > M.cfg.flee_timeout_s or (F.flee_failures or 0) >= 3 then
        local chased = threats and (#threats > 0) or nil
        if threats and #threats == 0 then chased = false end
        local detail = threats and #threats == 0 and "safety was not yet confirmed"
            or F.flee_error or "escape timed out while threats remained"
        return finish(F, result_of(F, false, "unsafe", { fled = false, why = F.flee_why,
            still_chased = chased, detail = detail }))
    end
end

M._step_flee = step_flee

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

-- Packs (S1: wolves, thugs): the creatures on him now = the target + every attacker of the last
-- attacker_memory_s within assist_m. -> list of {id, pos, name}, and their centroid (a disengage backs away
-- from the pack, not from one of them).
function M.pack(F, me)
    local c = C()
    local out = {}
    local seen = {}
    if F.target_pos then out[#out + 1] = { id = F.target_id, pos = F.target_pos, name = F.target_name }; seen[F.target_id or "?"] = true end
    for _, cr in ipairs(creatures_near(me.pos, M.cfg.assist_m)) do -- (the cached census)
        local hit = c.attackers[cr.id]
        local tele = c.telegraphs[cr.id]
        if not cr.dead and not seen[cr.id] and ((hit and F.t - hit <= M.cfg.attacker_memory_s) or (tele and F.t - tele <= M.cfg.attacker_memory_s)) then
            seen[cr.id] = true
            out[#out + 1] = { id = cr.id, pos = cr.pos or (cr.actor and U.loc(cr.actor)), name = cr.name }
        end
    end
    local sx, sy, n = 0, 0, 0
    for _, e in ipairs(out) do if e.pos then sx, sy, n = sx + e.pos.X, sy + e.pos.Y, n + 1 end end
    local centroid = n > 0 and { X = sx / n, Y = sy / n, Z = me.pos and me.pos.Z or 0 } or F.target_pos
    if #out > (F.max_pack or 0) then F.max_pack = #out end
    F.pack_n, F.pack_centroid = #out, centroid
    return out, centroid
end

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

-- Start a cast (reactive or ahead). -> the cast record (also in F.casts)
local function start_cast(F, ability, asset, why)
    local D = mod("defense")
    local def = D and D.abilities()[ability] or {}
    local rec = { ability = ability, asset = asset, t = F.t, why = why, job = M.spell_api.cast(F, asset), def = def }
    if not rec.job then rec.failed = "no_cast_route" end
    F.casts = F.casts or {}
    F.casts[#F.casts + 1] = rec
    F.n_abilities = F.n_abilities or {}
    F.n_abilities[ability] = (F.n_abilities[ability] or 0) + 1
    say(F.log, string.format("cast %s (%s) %s", tostring(ability), tostring(why), rec.failed or ""))
    return rec
end
M._start_cast = start_cast

-- Per frame: step every running cast; a finished one opens its effect window.
local function casts_frame(F)
    F.casting = nil
    for _, rec in ipairs(F.casts or {}) do
        if not rec.result and not rec.failed and rec.job and type(rec.job.poll) == "function" then
            local ok, r = pcall(rec.job.poll, rec.job)
            if ok and r then
                rec.result = r
                if r.ok then
                    local lat = r.latency_s or (F.t - rec.t)
                    local c = C()
                    c.ability_latency = c.ability_latency or {}
                    local old = c.ability_latency[rec.asset]
                    c.ability_latency[rec.asset] = old and (old * 0.7 + lat * 0.3) or lat
                    rec.done_t = F.t
                    local dur = rec.def.window_s or rec.def.lasts_s or 1
                    F.effects = F.effects or {}
                    F.effects[rec.ability] = F.t + dur
                    F.ab_ctx = nil -- availability changed (cooldown)
                else
                    rec.failed = r.reason or "failed"
                end
            elseif not ok then rec.failed = "poll_error" end
            if not rec.result and not rec.failed then F.casting = rec end
        end
    end
end
M._casts_frame = casts_frame

-- Abilities up now or about to be (a cast in progress): {name = {from = s, to = s}} relative to now.
local function active_effects(F)
    local out
    for name, until_t in pairs(F.effects or {}) do
        if until_t > F.t then out = out or {}; out[name] = { from = 0, to = until_t - F.t } end
    end
    local c = C()
    for _, rec in ipairs(F.casts or {}) do
        if not rec.result and not rec.failed then
            local lat = (c.ability_latency or {})[rec.asset] or 1.0
            local done_in = math.max(0, rec.t + lat - F.t)
            local dur = rec.def.window_s or rec.def.lasts_s or 1
            out = out or {}
            out[rec.ability] = { from = done_in, to = done_in + dur, pending = true }
        end
    end
    return out
end

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

-- The defensive spells he may use in THIS fight. A cast goes through the real spell inputs and takes 0.7-2.2 s
-- (measured) with no swing meanwhile, plus runes; so when the fight is a likely win he trades blows instead (live
-- 2026-11-01 11:27: Tempest Shield + Windstep casts against a Goblin Runt, 0 swings in 10 s, both Windsteps went
-- off after the hit had landed). Spells come in once the fight is hard (the latest assessment is not
-- "likely_win", or a boss). combat_orders.abilities = {name = true} allows one in every fight, false never.
function M.fight_abilities(F)
    local all = ability_ctx(F)
    local pol = M.orders.abilities or {}
    local a = F.assessment
    local hard = F.boss or (a ~= nil and a.verdict ~= nil and a.verdict ~= "likely_win") or false
    local out = {}
    for name, st in pairs(all) do
        if pol[name] == true or (pol[name] ~= false and hard) then out[name] = st end
    end
    F.spells_held = not hard or nil
    return out
end

local function start_defend(F, me, attacker_id, tt, info)
    local c = C()
    F.defended = F.defended or {}
    if attacker_id then F.defended[attacker_id] = F.t end -- (an attack on him, whether it lands or not: M.swap_target)
    local D = mod("defense")
    local apos
    if attacker_id == F.target_id then apos = F.target_pos
    else local a = find_creature(attacker_id); apos = a and U.loc(a) end
    local cap = F.cap or {}
    local ctx = { dist_cm = (apos and me.pos) and U.dist2d(apos, me.pos) or nil, latency_s = F.latency or 0.03,
                  stamina = me.stamina, can_parry = cap.can_parry, can_block = cap.can_block,
                  parry_cost = cap.parry_cost, block_cost = cap.block_cost, evade_cost = c.evade_cost or 15,
                  hp_frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1, heal_hp = M.orders.heal_hp,
                  max_hp = me.max_hp, abilities = M.fight_abilities(F), active = active_effects(F),
                  evade_lead_s = M.evade_lead(F.pc and U.try(function() return F.pc.Pawn end)),
                  heavy = M.too_heavy() and true or nil }
    -- how fast it is closing on him (its velocity toward him), for the reach check
    local aa = attacker_id == F.target_id and F.target or find_creature(attacker_id)
    local v = U.alive(aa) and U.try(function() return aa:GetVelocity() end)
    if v and apos and me.pos then
        local dx, dy = me.pos.X - apos.X, me.pos.Y - apos.Y
        local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
        ctx.closing_cms = ((v.X or 0) * dx + (v.Y or 0) * dy) / l
    end
    info = info or { key = "?:unknown" }
    local pawn = U.try(function() return F.pc.Pawn end)
    if pawn and apos and me.pos then ctx.face_deg = (face_err(pawn, me.pos, apos)) end
    ctx.block_angle = cap.block_angle
    local plan = D and D.plan(info, ctx, M.orders)
        or { action = "block", at_s = M.react_delay(), hold_s = 0.9, impact_s = 0.6, why = "no defense module" }
    F.def = { plan = plan, tel_t = tt, key = info.key, attacker = attacker_id, apos = apos, hp0 = me.hp, st0 = me.stamina,
              apos_tel = apos and { X = apos.X, Y = apos.Y, Z = apos.Z },
              me_seq0 = c.me_seq or 0, blk_seq0 = c.block_seq or 0, imp_seq0 = c.impact_seq or 0, info = info }
    F.last_tele = tt
    if F.following then mcall("move", "stop", F.log); F.following = false end
    set_phase(F, "defend", string.format("%s %s impact %.2fs %s (%s%s)", plan.action, tostring(info.key), plan.impact_s or -1,
        tostring(plan.src), tostring(plan.why), (plan.why == "out_of_reach" and ctx.dist_cm and plan.reach_cm)
            and string.format(": %.1f m off, taken to reach %.1f m", ctx.dist_cm / 100, plan.reach_cm / 100) or ""))
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
    elseif d.impact_seen and (act == "block" or act == "parry" or act == "tempest_shield" or (d.plan.input == "block")) then outcome = "blocked"
    elseif (act == "dodge" or act == "jump" or act == "retreat" or act:sub(-4) == "_pre") and (d.impact_t or d.evaded) then outcome = "avoided"
    elseif d.cast and d.cast.result and d.cast.result.ok and d.impact_t then outcome = "avoided"
    elseif d.cast and (d.cast.failed or (d.cast.result and not d.cast.result.ok)) then outcome = "whiff"; d.cast_failed = true
    else outcome = "whiff" end
    if d.impact_t and D then D.observe(d.key, d.impact_t - d.tel_t) end
    -- how far the attacker came during the attack (a lunge), measured on Claude's own perception
    if D and d.apos_tel and d.apos_end then
        local dx, dy = d.apos_end.X - d.apos_tel.X, d.apos_end.Y - d.apos_tel.Y
        D.observe_lunge(d.key, math.sqrt(dx * dx + dy * dy))
    end
    if D then D.feedback(d.key, act, outcome, d.hit_amt, d.plan.dist_cm) end
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
    say(F.log, string.format("defence %s -> %s (key %s, impact %s, dmg %s, evaded %s, montage %s, acted at %s%s)", act, outcome, tostring(d.key),
        d.impact_t and string.format("%.2fs", d.impact_t - d.tel_t) or "-", tostring(d.hit_amt or 0), tostring(d.evaded), tostring(d.montage),
        d.started_rel and string.format("%.2fs", d.started_rel) or "-", (d.retap and ", key twice" or "")
        .. (d.face_key and string.format(", turned %.0f deg from it at the key", d.face_key) or "")
        .. (d.face_hit and string.format(", %.0f deg at the hit", d.face_hit) or "")
        .. (d.verdict and string.format(", the server: %s%s", tostring(M.BLOCK_RESULT[d.verdict.result] or d.verdict.result),
            d.verdict.blocked and string.format(", %.0f blocked", d.verdict.blocked) or "") or "")
        .. (d.hit_via and (", " .. d.hit_via) or "")))
    F.last_defence = { action = act, outcome = outcome, key = d.key, impact_s = d.impact_t and (d.impact_t - d.tel_t) or nil,
                       plan_at = d.plan.at_s, why = d.plan.why, moved = d.moved, face_key = d.face_key, face_hit = d.face_hit,
                       verdict = d.verdict and M.BLOCK_RESULT[d.verdict.result] or nil }
    if d.moved then say(F.log, string.format("dodge %s moved toward %+dcm right %+dcm", tostring(d.moved.dir), d.moved.toward_cm, d.moved.right_cm)) end
    F.def, F.hold, F.evade_dir, F.evade_until, F.move_inject = nil, nil, nil, nil, nil
    local q = F.queued_tele
    F.queued_tele = nil
    if q and F.t - q.tt <= 2.5 and F.me_last then
        say(F.log, "queued swing from " .. tostring(q.id))
        return start_defend(F, F.me_last, q.id, q.tt, q.info)
    end
    -- low HP with the attacker on him: its swing has just passed (dodged, blocked, parried, or it missed), so this is
    -- the room to eat, the way a player does (live 2026-11-01 22:08: at 28 HP with 5 food he never ate: the
    -- back-off-and-eat path waits for 5 m of room a faster cow never gave)
    local me = F.me_last
    if outcome ~= "hit" and me and me.max_hp and me.max_hp > 0 and not F.dis and not F.no_food and (F.eat_fails or 0) < 3
        and (me.hp or 0) / me.max_hp < (M.orders.heal_hp or 0.5) and M.orders.disengage ~= false then
        local ate, why = try_eat(F, me, true)
        if ate then say(F.log, string.format("ate in the gap after the %s (hp %.0f)", outcome, me.hp or 0)) end
    end
    set_phase(F, F.dis and "disengage" or "engage", "defended " .. outcome)
end

-- When his roll can't be hit, from the roll's own montage: {from_s, to_s} after it starts (the first
-- AnimNotifyState_Invulnerability_C of the Left / Right / Backward / Forward dodge montages; the latest start and the
-- earliest end among them). nil when it can't be read. Read once per client session.
function M.evade_window(pawn)
    local c = C()
    if c.evade_win ~= nil then return c.evade_win or nil end
    local comp = U.try(function() return pawn.EvadeComponent end)
    local set = U.valid(comp) and U.try(function() return comp.DefaultAnimationSet end)
    local from, to
    for _, k in ipairs({ "LeftMontage", "RightMontage", "BackwardMontage", "ForwardMontage" }) do
        local m = set and U.try(function() return set[k] end)
        if U.valid(m) then
            local a, b
            pcall(function()
                m.Notifies:ForEach(function(_, e)
                    local n = e:get()
                    local cls = n.NotifyStateClass
                    if U.valid(cls) and U.short(cls):find("Invulnerab") and (not a or n.LinkValue < a) then a, b = n.LinkValue, n.LinkValue + n.Duration end
                end)
            end)
            if a then from, to = math.max(from or a, a), math.min(to or b, b) end
        end
    end
    c.evade_win = (from and to and to > from) and { from_s = from, to_s = to } or false
    if c.evade_win then
        say(nil, string.format("dodge: the roll can't be hit %.2f-%.2f s after it starts (its montage): the key goes %.2f s before an impact",
            from, to, (from + to) / 2))
    end
    return c.evade_win or nil
end
-- How long before an impact his dodge key goes: the middle of the roll's invulnerable window (nil: the default).
function M.evade_lead(pawn)
    local w = U.valid(pawn) and M.evade_window(pawn)
    return w and (w.from_s + w.to_s) / 2 or nil
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
    if not d then return end
    local plan = d.plan
    -- a block faces where the camera looks: the block key turns his body to the camera's yaw (live probe
    -- block_face_probe 2026-11-17: 120 deg in 12 frames). So from the telegraph to the hit the camera is on the one
    -- that swings, as a player's is. (Before: it pointed where he last walked or dodged; block -> hit 4 of 7.)
    local blk = plan.action == "parry" or plan.action == "block" or plan.action == "tempest_shield" or plan.input == "block"
    local tp = d.apos_now or d.apos
    local mp = (F.me_last or {}).pos
    if blk and tp and mp and not d.impact_t then
        pcall(function() F.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(tp.Y - mp.Y, tp.X - mp.X)), Roll = 0 }) end)
    end
    if d.started then
        -- the dodge that didn't come out: the key once more, as a player does. Live 2026-11-16 07:50:52Z and 08:13:06Z
        -- (Goblin Runt Attack1): "evaded false", no sideways move, hit for 15 at 1.23 / 1.37 s, 0.5 s after the one
        -- tap (a dodge reads as evading within 1-4 frames of its input: attack_evade_probe). Per frame: the hit is
        -- 0.2-0.3 s after the key
        if not d.cast and (plan.input or plan.action) == "dodge" and not d.evaded and not d.retap and not d.impact_t
            and acts.evade and F.t - d.started >= M.cfg.evade_retap_s then
            d.evaded = my_evading(pawn)
            if not d.evaded and ((F.me_last or {}).stamina or 0) >= (C().evade_cost or 15) then
                d.retap = true
                if F.move_inject then F.move_until = F.t + (plan.hold_s or 0.35) end
                if F.evade_dir then F.evade_until = F.t + (plan.hold_s or 0.35) end
                tap(F, acts.evade, 4, "evade_again")
                F.n_retaps = (F.n_retaps or 0) + 1
                say(F.log, string.format("the dodge didn't come out %.2f s after the key: the key again", F.t - d.started))
            end
        end
        return
    end
    if F.t - d.tel_t < (plan.cast_at_s or plan.at_s or 0) then return end
    local me = F.me_last or {}
    d.started = F.t
    d.started_rel = F.t - d.tel_t
    if blk and tp and mp then d.face_key = (face_err(pawn, mp, tp)) end
    local a = plan.action
    if plan.spell_asset then
        -- a defensive ability: cast it now (the spells module drives the real spell inputs)
        d.cast = start_cast(F, a, plan.spell_asset, "reactive " .. tostring(d.key))
        return
    end
    if plan.input then
        -- "<ability>_pre": the ability is up, only its follow-up input; a dash charge is used up by it
        local name = a:sub(1, -5)
        local D = mod("defense")
        local def = D and D.abilities()[name] or {}
        if def.charges and F.effects then F.effects[name] = nil end
        a = plan.input
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
    -- (the cast itself is stepped by casts_frame)
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
        if (d.cast and d.cast.def and d.cast.def.charges) and F.effects then F.effects[d.cast.ability] = nil end -- the dash is used up
        F.n_dodges = (F.n_dodges or 0) + 1
    end
    if plan.action == "tempest_shield" and not d.block_done and rel >= (plan.at_s or 0) and acts.secondary then
        d.block_done = true
        F.hold, F.hold_until = acts.secondary, F.t + (plan.hold_s or 0.9)
    end
end
M._defend_followup = defend_followup

-- The wind-up of a swing he will dodge is time for a swing of his own: the dodge cuts his swing short whenever it
-- comes (live probe attack_evade_probe 2026-11-16, Bronze Sword: evading 1-4 frames after the evade input at 0.1,
-- 0.3, 0.5 and 0.7 s into a swing, 1 frame with no swing). So: his target in reach, the press due, stamina for the
-- swing AND the dodge, and his hit lands (dmg_ms) before the dodge is due. Rune Mysteries 20261116-074002, three
-- Goblin Runts, no shield: 11 dodges, 14.6 s of 45 standing from the telegraph to the dodge, 10 swings, dead.
-- Only for the plain dodge: a block, a parry and a cast were not probed.
function M.windup_swing(F, me, plan, rel)
    local cfg = M.cfg
    if cfg.windup_swing == false or plan.action ~= "dodge" or plan.input or plan.spell_asset or plan.cast_at_s then return false end
    if F.casting or F.dis or not (F.dist_m and F.reach and F.dist_m <= F.reach) then return false end
    if F.t < (F.next_press or 0) then return false end
    local prim = (F.profile or {}).prim or {}
    if (plan.at_s or 0) - rel < (prim.dmg_ms or 400) / 1000 + cfg.windup_margin_s then return false end
    return (me.stamina or 0) >= M.swing_need(F, prim)
end

local function step_defend(F, pawn, me, acts)
    local d = F.def
    if not d then return set_phase(F, "engage", "no plan") end
    local c = C()
    local plan = d.plan
    local rel = F.t - d.tel_t
    defend_act(F, pawn, acts)
    if not d.started and acts.primary and M.windup_swing(F, me, plan, rel) then
        local prim = (F.profile or {}).prim or {}
        tap(F, acts.primary, M.cfg.tap_frames, "primary_windup")
        F.next_press = F.t + (prim.next_ms or 900) / 1000 + jitter(M.cfg.press_jitter_ms)
        F.last_press_t, F.presses, F.n_windup = F.t, F.presses + 1, (F.n_windup or 0) + 1
        c.counts.presses = c.counts.presses + 1
        F.pending_press = { t = F.t, stamina = me.stamina, hits = F.hits }
    end
    if F.evade_until and F.t >= F.evade_until then F.evade_dir, F.evade_until = nil, nil end
    if d.jump_release and F.t >= d.jump_release then pcall(function() pawn:StopJumping() end); d.jump_release = nil end
    if d.started and (plan.input or plan.action) == "dodge" and not d.evaded and F.t - d.started < 0.6 then d.evaded = my_evading(pawn) end
    if d.st_dodge and d.started and F.t - d.started > 0.3 and me.stamina then
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
                d.verdict = e.block or d.verdict
                if (e.amount or 0) > 0 then d.hit_via = e.point and "a point hit" or "a plain hit" end
            end
        end
    end
    if F.hold and not d.parried then
        local ai = U.try(function() return pawn.Mesh:GetAnimInstance() end)
        local m = U.valid(ai) and U.short(U.try(function() return ai:GetCurrentActiveMontage() end)) or nil
        if m and m:find("Parry", 1, true) then d.parried, d.impact_t, d.montage = true, d.impact_t or F.t, m end
    end
    for _, e in ipairs(c.impacts or {}) do
        if e.seq > (d.imp_seq0 or 0) and e.id == d.attacker then d.imp_seq0 = e.seq; d.impact_t = d.impact_t or e.t; d.impact_seen = true end
    end
    -- where the attacker is now (the camera follows it while a block is the answer): the census's row, no search
    do
        local a = d.attacker == F.target_id and F.target or ((c.census or {}).by_id or {})[d.attacker]
        local p = a and U.valid(a) and U.loc(a)
        if p then d.apos_now = { X = p.X, Y = p.Y, Z = p.Z } end
    end
    -- the attacker's position when the hit resolves (lunge learning), and how far he was turned from it then
    if d.impact_t and not d.apos_end then
        local a = d.attacker == F.target_id and F.target or find_creature(d.attacker)
        local p = a and U.loc(a)
        if p then
            d.apos_end = { X = p.X, Y = p.Y, Z = p.Z }
            if d.face_key and me.pos then d.face_hit = (face_err(pawn, me.pos, p)) end
        end
    end
    -- a new telegraph (a combo's next swing) closes this one
    for id, tt in pairs(c.telegraphs) do
        if d.started and tt > d.tel_t + 0.2 and (id == d.attacker or id == F.target_id) then
            finish_defend(F)
            return start_defend(F, me, id, tt, (c.tele_info or {})[id])
        end
    end
    -- another pack member swings meanwhile (S1): when its hit lands BEFORE the one we are answering (or ours has
    -- landed), answer it now; else queue it for right after (the plan's own timing still applies to each)
    for id, tt in pairs(c.telegraphs) do
        if id ~= d.attacker and tt > d.tel_t and tt > (d.other_t or 0) and F.t - tt <= M.cfg.telegraph_fresh_s then
            local a = find_creature(id)
            local p = a and U.loc(a)
            if p and me.pos and U.dist(p, me.pos) <= M.cfg.telegraph_m * 100 then
                d.other_t = tt
                local info2 = (c.tele_info or {})[id]
                local D = mod("defense")
                local their = tt + ((D and D.impact_delay and D.impact_delay(info2 and info2.key or "?", info2 or {})) or 0.8)
                local ours = d.tel_t + (plan.impact_s or 0.6)
                F.n_multi = (F.n_multi or 0) + 1
                if d.impact_t or their < ours - 0.1 then
                    finish_defend(F)
                    return start_defend(F, me, id, tt, info2)
                end
                F.queued_tele = { id = id, tt = tt, info = info2 }
            end
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
        local from = F.pack_centroid or F.target_pos -- (frame refreshes the pack every 0.5 s)
        if (F.dist_m or 99) < 3.5 and acts.evade and (me.stamina or 0) >= (C().evade_cost or 15) then
            F.evade_dir = away_dir(me.pos, from, "back")
            F.evade_until = F.t + 0.35
            tap(F, acts.evade, 4, "evade_back")
            F.n_dodges = (F.n_dodges or 0) + 1
        end
        local dir = away_dir(me.pos, from, "back")
        if dir and me.pos then
            local far = M.cfg.disengage_m * 100
            local goal = { (me.pos.X + dir.X * far) / 100, (me.pos.Y + dir.Y * far) / 100, me.pos.Z / 100 }
            mcall("move", "go_to", F.log, goal, { sprint = true, tolerance_m = 2, timeout_s = 8, owner_token = F.token })
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
    local magic = F.profile and F.profile.kind == "magic"
    local comp = Rg.ranged_component(pawn)
    if not comp and not magic then return false, "no_ranged_component" end
    local prm = (comp and Rg.read_weapon_params(pawn)) or {}
    if magic then
        -- a staff / wand: its primary action casts a magic projectile and spends the runes in the
        -- loadout's magic ammo slot (catalog ammo "Runes"); no aim hold, the projectile is learned
        -- from the DominionSpellProjectile actors it spawns
        local l = mcall("inventory", "list", F.log) or {}
        local runes
        for _, e in ipairs(l.loadout or {}) do if tostring(e.loadout_slot or ""):find("MagicAmmo", 1, true) then runes = e end end
        if not runes then return false, "no_runes" end
        prm = { ammo = runes.item, has_ammo = (runes.count or 1) > 0, full_accuracy_s = M.cfg.magic_aim_s }
        F.rune_item, F.rune_count0 = runes.item, runes.count
    end
    local right, left = held_items(pawn)
    local key = tostring(right or left or "?") .. "|" .. tostring(prm.ammo or "?")
    local seed = prm.speed and { speed = prm.speed, gz = prm.gz or Rg.cfg.default_gz, t0 = prm.t0 or 0, source = "game_data" } or nil
    F.rg = { R = Rg, comp = comp, key = key, aimer = Rg.new_aimer(key, seed), seed = prm, shots = 0, hits = 0, misses = 0, magic = magic }
    F.reach, F.follow = M.cfg.ranged_max_m, M.cfg.ranged_keep_m
    say(F.log, string.format("ranged: %s speed %s (game data %s) gz %s t0 %s (%s) full-accuracy %ss ammo ok %s", key, tostring(F.rg.aimer.p.speed), tostring(prm.speed),
        tostring(F.rg.aimer.p.gz), tostring(F.rg.aimer.p.t0), tostring(F.rg.aimer.p.source), tostring(prm.full_accuracy_s), tostring(prm.has_ammo)))
    if prm.has_ammo == false then return false, magic and "no_runes" or "no_ammo" end
    return true
end
M._ranged_setup = ranged_setup

-- Over his carry weight he only walks: no sprint, no jump and no dodge roll (live 2026-11-16 08:4xZ at 352 of 300:
-- the evade key gave no roll on four defences and on a bare probe, 0 m moved, IsEvading never true; two flees made
-- 3 and 0 m in 5 s and cost 30 and 36 HP). {on, cur, max} when he is, else nil.
function M.too_heavy()
    local e = mcall("move", "encumbrance")
    return type(e) == "table" and e.on == true and e or nil
end

-- Can he get away from his target? Not when he is over his carry weight, not when it is already in reach (its learned reach, else flee_in_reach_m) and
-- at least as fast as his sprint (its max walk speed or its speed now, whichever is more), or when it has caught
-- a flee of his before (c.caught_by, this session). -> stuck(bool), why(text)
function M.cant_escape(F, pawn, me)
    local a = F.target
    if not (U.alive(a) and me.pos) then return false end
    local heavy = M.too_heavy()
    if heavy then
        return true, string.format("I'm carrying too much to run or roll (%.0f of %.0f weight): I can only walk", heavy.cur or 0, heavy.max or 0)
    end
    local p = U.loc(a)
    local d_m = p and U.dist2d(p, me.pos) / 100
    if not d_m then return false end
    local caught = (C().caught_by or {})[F.target_name or "?"]
    -- one that ran him down before will again from a few metres off (every death of 2026-11-16 began with a flee
    -- from Goblin Runts 5 m away that "kept up with me for 25 m" or "kept hitting me while I ran": 25-36 HP gone)
    if caught and d_m <= (M.cfg.caught_near_m or 12) then
        return true, string.format("it is %.0f m off and I can't outrun it (it caught me running before)", d_m)
    end
    local reach_m = M.cfg.flee_in_reach_m or 4
    local D = mod("defense")
    if D and D.max_reach_cm then reach_m = math.max(reach_m, (D.max_reach_cm(F.target_name) or 0) / 100) end
    if d_m > reach_m then return false end
    local mine = num(U.try(function() return pawn.CharacterMovement:GetSprintingMaxSpeed() end)) or 680
    local its = num(U.try(function() return a.CharacterMovement.MaxWalkSpeed end)) or 0
    local v = U.try(function() return a:GetVelocity() end)
    if v then its = math.max(its, math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2)) end
    if its >= mine * (M.cfg.outrun_frac or 0.95) or caught then
        return true, string.format("it is on me (%.0f m) and I can't outrun it (%s)", d_m,
            caught and "it caught me running before" or string.format("%.1f vs my %.1f m/s", its / 100, mine / 100))
    end
    return false
end

-- Is this projectile his (instigator or owner is his pawn or controller)? Unreadable: assume it is.
function M.own_projectile(a, pawn, pc)
    local inst = U.try(function() return a:GetInstigator() end)
    local own = U.try(function() return a:GetOwner() end)
    local known = false
    for _, x in ipairs({ inst, own }) do
        if U.valid(x) then
            known = true
            if (pawn and U.short(x) == U.short(pawn)) or (pc and U.short(x) == U.short(pc)) then return true end
        end
    end
    return not known
end

-- Per frame: aim the camera and follow a flying shot.
local function ranged_frame(F, pawn)
    local g = F.rg
    if not g then return end
    local Rg, aimer = g.R, g.aimer
    -- the bow's own state, read every frame (logged on change): aim mode, full accuracy, an arrow nocked
    if g.comp and not g.magic then
        local comp = g.comp
        local aim = U.try(function() return comp:IsAimModeActive() end)
        local full = U.try(function() return comp.HasReachedFullAccuracy end)
        local wa = U.try(function() return comp.RangedWeaponActor end)
        local lp = U.valid(wa) and U.try(function() return wa.LoadedProjectile end) or nil
        local loaded = U.valid(wa) and (U.valid(lp) and true or false) or nil
        g.flags = { aim = aim, full = full, loaded = loaded }
        -- a new arrow on the bow (another actor, or the same one shown again after the release)
        if loaded == true and (g.loaded_id ~= U.short(lp) or g.prev_loaded ~= true) then g.loaded_id, g.loaded_t = U.short(lp), F.t end
        if aim == true and g.prev_aim ~= true then g.aim_on_t = F.t end
        g.prev_loaded, g.prev_aim = loaded, aim
        g.loaded_actor = loaded and lp or nil
        local st = string.format("aim=%s full=%s loaded=%s held=%s", tostring(aim), tostring(full), tostring(loaded), tostring(F.hold ~= nil))
        if st ~= g.bow_state then
            g.bow_state = st
            say(F.log, string.format("ranged: bow %s (%.2f s since the release, phase %s)", st, F.t - (F.last_press_t or F.t), tostring(F.phase)))
        end
    end
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
            -- the arrow that flies is the one that was nocked at the release (so it is in ids_before); the next arrow
            -- the bow nocks ~1 s later is a new projectile actor too, but it sits on the bow (live 2026-11-02 04:55:
            -- tracking that one scored every miss at the target's range, fitted 9-114 cm/s and taught the profile
            -- 1566 -> 461). So: never the arrow on the bow now, and only one that moves or has left the muzzle.
            local cands = {}
            if shot.arrow and U.valid(shot.arrow) then cands[#cands + 1] = shot.arrow end
            for id, a in pairs(Rg.projectile_ids()) do
                -- only his own shot: Luis's sceptre bolts and his summon's spit are projectiles too (live 2026-11-01
                -- 22:07: two "staff shots" tracked 10 m off were someone else's, and taught the aimer a wrong speed)
                if not shot.ids_before[id] and M.own_projectile(a, pawn, F.pc) then cands[#cands + 1] = a end
            end
            local on_bow = g.loaded_actor and U.valid(g.loaded_actor) and U.short(g.loaded_actor) or nil
            for _, a in ipairs(cands) do
                local id = U.short(a)
                if id ~= on_bow then
                    local vel = U.try(function() return a:GetVelocity() end)
                    local sp = vel and math.sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2 + (vel.Z or 0) ^ 2) or 0
                    local p = U.loc(a)
                    local off = (p and shot.muzzle) and U.dist(p, shot.muzzle) or 0
                    if g.magic or sp > 500 or off > 150 then shot.proj, shot.proj_id = a, id; break end
                end
            end
        end
        local pp = shot.proj and U.alive(shot.proj) and U.loc(shot.proj) or nil
        local tp = U.alive(F.target) and U.loc(F.target) or nil
        -- an arrow that has stopped (stuck in the ground or in the target: a live actor until MaxSimulationTime,
        -- live 2026-11-02 05:07: every shot "flew" 4.5 s, fits of 0 cm/s) ends the shot; its resting samples are not flight
        -- (from its positions: the client reads ~0 from a flying arrow's GetVelocity, live 05:19)
        local stopped = false
        local sm = shot.samples or {}
        if pp and not g.magic and #sm >= 2 then
            local a, b = sm[#sm - 1].pos, sm[#sm].pos
            local still = function(p, q) return math.abs(p.X - q.X) + math.abs(p.Y - q.Y) + math.abs(p.Z - q.Z) < 3 end
            if still(b, pp) and still(a, b) then
                stopped, pp = true, nil
                while #sm >= 2 and still(sm[#sm].pos, sm[#sm - 1].pos) do table.remove(sm) end -- resting samples are not flight
            end
        end
        local done = aimer:sample(F.t, pp, tp)
        if shot.proj and not pp then done = true end
        if stopped then done = true end
        -- a staff's spell bolt is not a projectile actor the client sees (every staff cast since 2026-10-26: "no
        -- projectile", even 3 casts / 3 hits on a runt): its outcome is the target's HP, read for the bolt's flight
        if g.magic and not shot.proj and F.t - shot.t > (M.cfg.magic_verdict_s or 1.6) then
            local hit = false
            for _, h in ipairs(C().my_hits) do
                if h.seq > (shot.hit_seq0 or 0) and h.victim == F.target_id then hit = true end
            end
            aimer.shot = nil
            g.shots = g.shots + 1
            if hit then g.hits = g.hits + 1 else g.misses = g.misses + 1 end
            g.casts_unseen = (g.casts_unseen or 0) + 1
            if hit then F.unverified_run = 0; F.verified = F.verified + 1 end
            g.last = { hit = hit, dist_m = shot.dist_m, target_speed = shot.target_speed, magic = true }
            say(F.log, string.format("magic cast %d %s at %.0f m, target moving %.1f m/s, facing off %s deg",
                g.shots, hit and "HIT" or "miss", shot.dist_m or -1, shot.target_speed or 0, tostring(shot.yaw_off)))
            return
        end
        if not shot.proj and F.t - shot.t > 1.0 and not g.magic then done = true; shot.no_projectile = true end
        -- the server's verdict (our damage multicast on the target) can trail the bolt's end: wait a bit
        if done and not shot.no_projectile then
            shot.gone_t = shot.gone_t or F.t
            if F.t - shot.gone_t < 0.3 then done = false end
        end
        if done then
            local hit, dmg = false, 0
            for _, h in ipairs(C().my_hits) do
                if h.seq > (shot.hit_seq0 or 0) and h.victim == F.target_id then hit = true; dmg = dmg + (tonumber(h.amount) or 0) end
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
                    g.shots, hit and string.format("HIT %.0f dmg", dmg) or "miss", tostring(g.last.miss_cm), tostring(g.last.vertical_cm), tostring(g.last.lateral_cm),
                    tostring(res and res.fit and math.floor(res.fit.speed or 0)), tostring(res and res.fit and math.floor(res.fit.gz or 0)),
                    aimer.p.speed, aimer.p.gz, aimer.p.t0))
            end
        end
    end
end
M._ranged_frame = ranged_frame

-- The plain reason a bow / crossbow can't shoot: its ammo slot is empty, and what fitting ammo is in his bag
-- instead (the game does not refill the slot from the bag: farming run 7, 2026-11-02 05:5xZ, Fang Arrows in the bag,
-- "the bow's ammo slot keeps coming up empty").
function M._ammo_words_for_list(why, prof, l)
    if why ~= "no_ammo" or not prof then return nil end
    local ok, wk = pcall(M.weapons_known, l or {})
    local row = ok and wk and wk[prof.name or "?"] or nil
    local what = (prof.cat == "crossbow") and "bolts" or "arrows"
    local have = {}
    for _, a in ipairs((row and row.ammo_carried) or {}) do have[#have + 1] = string.format("%d %s", a.count or 0, a.name or "?") end
    if #have > 0 then
        return string.format("The %s's ammo slot is empty; %s %s in my bag, not in the ammo slot, so it can't shoot them yet.",
            prof.name or "weapon", table.concat(have, ", "), #have == 1 and (have[1]:match("^1 ") and "is" or "are") or "are")
    end
    return string.format("The %s's ammo slot is empty and I carry no %s for it.", prof.name or "weapon", what)
end
function M.ammo_words(why, prof)
    if why ~= "no_ammo" or not prof then return nil end
    return M._ammo_words_for_list(why, prof, mcall("inventory", "list", nil) or {})
end

-- Is the bow drawn? After a release the bow nocks the next arrow (~1.0-1.25 s, live 2026-11-02 04:55) and the
-- draw (TimeBeforeFullAccuracy) runs from then; the game's HasReachedFullAccuracy never turned true on his client,
-- so it is time since the later of "aim started" and "this arrow nocked". A staff: time since aim start.
function M.bow_ready(F, g)
    local fa = (g.seed and g.seed.full_accuracy_s) or M.cfg.ranged_aim_s
    -- spread matters with range: at point blank a part draw hits (live 2026-11-02 05:19: a kebbit on him attacked
    -- every 3.1 s and left ~1.0 s of each 1.25 s draw, so 35 s went without a shot)
    local d = F.dist_m
    if d and not g.magic then fa = fa * math.max(M.cfg.min_draw_frac or 0.35, math.min(1, d / (M.cfg.ranged_keep_m or 12))) end
    if not g.aim_t0 then return false end
    if g.magic or not g.comp then return (F.t - g.aim_t0) >= fa end
    local fl = g.flags or {}
    if fl.loaded == false or fl.aim == false then return false end
    local from = math.max(g.aim_t0, (fl.aim == true and g.aim_on_t) or g.aim_t0)
    if F.last_press_t then
        -- the arrow nocked since the release, else (unreadable, or no change seen) the usual nock time after it
        if (g.loaded_t or -1) > F.last_press_t then from = math.max(from, g.loaded_t)
        else from = math.max(from, F.last_press_t + (M.cfg.nock_s or 1.25)) end
    end
    return (F.t - from) >= fa
end

-- Release the drawn shot (primary) and start following it.
local function loose(F, pawn, me, acts, tgt, d, why)
    local cfg, g = M.cfg, F.rg
    local fl = g.flags or {}
    say(F.log, string.format("ranged: release%s at %.2f s since the last, %.2f s aimed, %.2f s since nocked; aim=%s loaded=%s",
        why and (" " .. why) or "", F.t - (F.last_press_t or g.aim_t0), F.t - g.aim_t0, F.t - (g.loaded_t or g.aim_t0), tostring(fl.aim), tostring(fl.loaded)))
    tap(F, acts.primary, cfg.tap_frames, "shoot")
    local shot = g.aimer:fired(F.t, g.sol, g.R.projectile_ids(), g.muzzle)
    shot.arrow = g.loaded_actor
    shot.hits0, shot.hit_seq0 = F.hits, C().counts.hits
    F.last_press_t = F.t
    -- what each shot was taken at (hit vs miss: distance, the target's speed, how far off his facing was)
    shot.dist_m = d
    local vel = U.alive(F.target) and U.try(function() return F.target:GetVelocity() end)
    if vel then shot.target_speed = math.floor(math.sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2) / 10) / 10 end
    local yaw = U.try(function() return pawn:K2_GetActorRotation().Yaw end)
    if yaw and me.pos and tgt and tgt.pos then
        local want = math.deg(math.atan(tgt.pos.Y - me.pos.Y, tgt.pos.X - me.pos.X))
        shot.yaw_off = math.floor(math.abs(((want - yaw + 540) % 360) - 180))
    end
    F.presses = F.presses + 1
    C().counts.presses = C().counts.presses + 1
    local prof = F.profile or {}
    F.next_press = F.t + (prof.reload_s or 1.0) + 0.3 + jitter(cfg.press_jitter_ms)
    return true
end
M._loose = loose

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
                -- a drawn arrow goes first (its dodge is planned ~1 s ahead of the impact; live 2026-11-02 03:49 every
                -- telegraph dropped a full draw and the kebbit attacked every 3 s, so most draws were thrown away)
                local loosed = false
                if not g.magic and g.aiming and g.sol and not g.aimer.shot and F.t >= (F.next_press or 0) and M.bow_ready(F, g) then
                    loosed = M._loose(F, pawn, me, acts, tgt, F.dist_m or 99, "before the dodge")
                end
                g.aiming = false
                -- the aim key stays held through a release: letting go 0.15-0.2 s after the tap lost the arrow
                -- (live 2026-11-02 05:19:43 and 05:20:18: "no projectile")
                local since = F.t - (F.last_press_t or -9)
                if since < (cfg.release_hold_s or 0.4) then F.hold_until = (F.last_press_t or F.t) + (cfg.release_hold_s or 0.4)
                else F.hold = nil end
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
    -- hold aim (IA_SecondaryAction for crossbows/bows) while engaged; a staff/wand has no aim hold
    -- (its secondary is another action)
    if not g.aiming then g.aiming, g.aim_t0 = true, F.t end
    if acts.secondary and not g.magic then
        -- aim held but the bow not drawing (after a dodge the held key did not bring aim mode back, live 2026-11-02
        -- 05:07:40, and he stood 77 s): let go of it and press it again, as a player does
        local fl = g.flags or {}
        if fl.aim == false and F.t - g.aim_t0 > 0.8 and F.t - (g.repress_t or -9) > 1.5 then
            g.repress_t, F.hold = F.t, nil
            g.represses = (g.represses or 0) + 1
            say(F.log, string.format("ranged: aim held %.1f s but the bow is not drawing; pressing aim again", F.t - g.aim_t0))
        elseif F.t - (g.repress_t or -9) > 0.15 then
            F.hold, F.hold_until = acts.secondary, F.t + 0.3
        end
    end
    if g.aimer.shot then return end -- a bolt is in the air
    if F.unverified_run >= cfg.verify_presses then
        if g.magic then
            -- the casts are not seen leaving the staff, so a run of them without a hit is misses, and he says so
            -- (live 2026-11-01 22:07: "the staff keeps firing nothing" while Luis watched it fire and miss)
            if (F.runes_spent or 0) > 0 or F.runes_left == nil then
                return finish(F, result_of(F, false, "missed", { why = "casts_missed", shots = g.shots, hits = g.hits,
                    detail = string.format("%d casts in a row missed (%d of %d hit this fight); last at %.0f m, target moving %.1f m/s",
                        F.unverified_run, g.hits, g.shots, (g.last and g.last.dist_m) or -1, (g.last and g.last.target_speed) or 0) }))
            end
            return finish(F, result_of(F, false, "body_error", { why = "casts_not_firing",
                detail = string.format("%d casts spent no runes (%d left)", F.unverified_run, F.runes_left or 0) }))
        end
        return finish(F, result_of(F, false, "body_error", { why = "shots_not_firing", detail = "ranged presses spawned no projectile" }))
    end
    if F.t < (F.next_press or 0) or not g.sol then return end
    local prm = (g.comp and not g.magic) and (g.R.read_weapon_params(pawn) or {}) or {}
    if not M.bow_ready(F, g) then return end
    if g.magic and F.t - (F.rune_check_t or -9) > 3 then
        F.rune_check_t = F.t
        local l = mcall("inventory", "list", F.log) or {}
        local left = 0
        for _, e in ipairs(l.loadout or {}) do if tostring(e.loadout_slot or ""):find("MagicAmmo", 1, true) then left = left + (e.count or 0) end end
        if F.runes_left and left < F.runes_left then F.runes_spent = (F.runes_spent or 0) + (F.runes_left - left) end
        F.runes_left = left
        if left <= 0 then
            return finish(F, result_of(F, false, "not_enough_resources", { why = "no_runes", detail = "the magic ammo slot is empty" }))
        end
    end
    if prm.has_ammo == false then
        return finish(F, result_of(F, false, "not_enough_resources", { why = "no_ammo", detail = "no ammunition equipped for this weapon" }))
    end
    loose(F, pawn, me, acts, tgt, d)
end
M._step_ranged = step_ranged

-- Stamina kept back for the defence the orders and gear allow (live dev 08:01-08:02: with 40 max
-- stamina, attacking down to the fixed reserve left no stamina for the next dodge -> "retreat" -> hit).
function M.defence_reserve(F)
    local c = C()
    local r = M.cfg.stamina_reserve
    local d = M.orders.defense or "auto"
    local cap = F.cap or {}
    local dodge_first = d == "dodge" or (d == "auto" and not cap.can_block and not cap.can_parry)
    if dodge_first then r = math.max(r, (c.evade_cost or 15) + 5) end
    if (d == "block" or d == "parry" or d == "auto") and cap.can_block then r = math.max(r, (cap.block_cost or 10) + 5) end
    return r
end

-- Stamina a primary swing needs now: its cost plus the defence reserve, or the cost alone for a finishing blow (the
-- target's HP within one of his hits) or once the reserve has held him back cfg.reserve_wait_s. With his max stamina
-- cut (rest low: 40 at endurance 0) reserve + cost was about all he had: he parried a 20-HP runt for 24 s without one
-- swing and the fight ran out the clock (live 2026-11-01 17:35Z).
function M.swing_need(F, prim)
    local k = (F.profile and F.profile.name) or "hands"
    local cost = (prim and prim.stam) or (C().press_cost or {})[k] or 10
    local hit = (C().hit_dmg or {})[k] or (prim and prim.dmg)
    local finishing = hit and F.target_hp and F.target_hp > 0 and F.target_hp <= hit
    local waited = F.reserve_held_since and F.t - F.reserve_held_since >= M.cfg.reserve_wait_s
    if finishing or waited then return cost end
    return M.defence_reserve(F) + cost
end

-- The dodge or montage his body is in (it takes no walking input until it ends), or nil.
function M.busy_montage(pawn)
    if my_evading(pawn) then return "evading" end
    local ai = U.try(function() return pawn.Mesh:GetAnimInstance() end)
    local m = U.valid(ai) and U.try(function() return ai:GetCurrentActiveMontage() end)
    return U.valid(m) and U.short(m) or nil
end

local function step_engage(F, pawn, me, acts, tgt)
    local cfg = M.cfg
    local d_m = F.dist_m
    -- keep in range: a short gap on his level (a dodge took him out of reach) -> step back in with the movement input;
    -- farther, or above / below him -> follow the creature (move.lua faces it when near)
    local tp = F.target_pos
    F.step_in = nil
    local can_step = d_m > F.reach and d_m <= cfg.step_in_m and tp and me.pos and math.abs(tp.Z - me.pos.Z) <= cfg.step_in_dz_cm
        and F.t >= (F.step_in_off_until or 0)
    if can_step then -- (decision ticks of stepping in, not seconds: a defence in between is not a stall)
        -- the gap is measured afresh when it closed, when the creature itself moved (it backed off: nothing is between
        -- us) and after a defence (his dodge opened it). Rune Mysteries 20261116-074002, three Goblin Runts: each
        -- DodgeBack and each dodge of his own counted as "made no ground", the slow follow took over twice for 5 s
        -- (0.5 m/s), 12.2 s of 45 out of reach, 10 swings, dead
        local moved = F.si_tp0 and U.dist2d(tp, F.si_tp0) >= cfg.step_in_gain_m * 100
        if not F.si_d0 or d_m <= F.si_d0 - cfg.step_in_gain_m or moved or F.si_tele ~= F.last_tele then
            F.si_d0, F.si_n, F.si_tp0, F.si_tele = d_m, 0, { X = tp.X, Y = tp.Y, Z = tp.Z }, F.last_tele
        end
        -- a body still in its dodge or another montage (a hit's stagger) takes no walking input: that is no stall.
        -- Live 2026-11-16 08:16:22Z: hit while dodging, 1 s of step-in with no ground, the follow then walked at once
        local mont = M.busy_montage(pawn)
        if not mont then F.si_n = F.si_n + 1 end
        if F.si_n * M.DECIDE_S >= cfg.step_in_stall_s then
            can_step, F.si_d0, F.step_in_off_until = false, nil, F.t + cfg.step_in_off_s
            F.n_step_stalls = (F.n_step_stalls or 0) + 1
            local v = U.try(function() return pawn:GetVelocity() end)
            say(F.log, string.format("step-in made no ground (%.1f m off, something between us; speed %.0f cm/s): the follow goes round", d_m,
                v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1))
        end
    else F.si_d0 = nil end
    if can_step then
        if F.following then mcall("move", "stop", F.log); F.following = false end
        local dx, dy = tp.X - me.pos.X, tp.Y - me.pos.Y
        local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
        F.step_in, F.step_in_until = { X = dx / l, Y = dy / l, Z = 0 }, F.t + M.DECIDE_S + 0.05
        F.n_step_ins = (F.n_step_ins or 0) + 1
    elseif d_m > F.reach + 0.3 and not F.following then follow_target(F, F.follow, d_m > 8) end
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
    if d_m > F.reach then
        F.far_n = (F.far_n or 0) + 1
        if F.far_n * M.DECIDE_S >= cfg.engage_far_s then
            F.far_n, F.step_in = 0, nil
            set_phase(F, "approach", "out of reach")
        end
        return M.held(F, "out_of_reach")
    end
    F.far_n = 0
    if F.casting then return M.held(F, "casting") end -- the spell's own inputs are running
    -- lock on once (one frame of the toggle; InputTriggerPressed)
    if cfg.lock_on and not F.locked and not F.no_lock and acts.lock then
        F.locked = true
        tap(F, acts.lock, 1, "lock_on")
        F.next_press = math.max(F.next_press or 0, F.t + 0.12)
        return
    end
    -- a swing goes where the camera looks: the attack key turns his body to the camera's yaw within 8 frames (live
    -- probe swing_face_probe 2026-11-17: 120 deg). So in reach the camera is on the one he swings at, as a player's
    -- is. (Window s9: after a block that faced another attacker, 8 swings went 84 to 168 deg off the target and
    -- landed nothing.)
    if F.target_pos and me.pos then
        pcall(function()
            F.pc:SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(F.target_pos.Y - me.pos.Y, F.target_pos.X - me.pos.X)), Roll = 0 })
        end)
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
        if spent then -- what a swing really costs with this weapon (bare hands have no catalog row)
            local cost = pp.stamina - me.stamina
            local c = C()
            c.press_cost = c.press_cost or {}
            local k = (F.profile and F.profile.name) or "hands"
            c.press_cost[k] = c.press_cost[k] and (c.press_cost[k] * 0.7 + cost * 0.3) or cost
        end
        local hit = F.hits > pp.hits
        say(F.log, string.format("swing at the %s from %.1f m (%+.1f m in height, facing %.0f deg off): %s", tostring(F.target_name), pp.d or -1, pp.dz or 0,
            pp.err or -1, hit and "hit" or spent and "landed nothing" or "no effect"))
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
        if (me.stamina or 0) < cfg.stamina_reserve + (prim.stam or 0) then F.next_press = F.t + 0.3; return M.held(F, "stamina") end
        tap(F, acts[se.input], cfg.tap_frames, se.style)
        F.next_press = F.t + ((tim and tim.next_ms) or 900) / 1000 + jitter(cfg.press_jitter_ms)
        F.last_press_t = F.t
        F.presses = F.presses + 1
        C().counts.presses = C().counts.presses + 1
        F.pending_press = { t = F.t, stamina = me.stamina, hits = F.hits, err = err, d = d_m, dz = tp and me.pos and (tp.Z - me.pos.Z) / 100 }
        return
    end
    -- special: charge covers it, target is worth it, not too often
    if spec and spec.cost and acts.special and F.cap and F.cap.special_ok and (me.special or 0) >= spec.cost and F.t - (F.last_special or -99) >= cfg.special_gap_s
        and (F.target_hp or 0) >= cfg.special_hp_factor * (prim.dmg or 10) then
        tap(F, acts.special, cfg.tap_frames, "special")
        F.last_special = F.t
        F.next_press = F.t + (spec.next_ms or 1200) / 1000 + jitter(cfg.press_jitter_ms)
    elseif (me.stamina or 0) >= M.swing_need(F, prim) and acts.primary then
        tap(F, acts.primary, cfg.tap_frames, "primary")
        F.next_press = F.t + (prim.next_ms or 900) / 1000 + jitter(cfg.press_jitter_ms)
        F.reserve_held_since = nil
    else
        F.reserve_held_since = F.reserve_held_since or F.t
        F.next_press = F.t + 0.3 -- let stamina come back (keep the reserve for defence)
        return M.held(F, "stamina")
    end
    F.last_press_t = F.t
    F.presses = F.presses + 1
    C().counts.presses = C().counts.presses + 1
    F.pending_press = { t = F.t, stamina = me.stamina, hits = F.hits, err = err, d = d_m, dz = tp and me.pos and (tp.Z - me.pos.Z) / 100 }
end

local function step_loot(F, pawn, me)
    local cfg = M.cfg
    if F.t - F.phase_t < cfg.loot_wait_s then return end
    if not F.loot_inv0 then F.loot_inv0 = carried_counts() end
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
                                 name = text(U.try(function() return U.prop(w, "ItemData").Name end)), -- R17
                                 count = num(U.try(function() return w:GetStackSize() end)) }, d
                end
            end
        end
        if not best then return set_phase(F, "restore", "no loot") end
        F.loot_item = best
        mcall("move", "go_to", F.log, { best.pos.X / 100, best.pos.Y / 100, best.pos.Z / 100 }, { tolerance_m = 0.9, sprint = false, timeout_s = 10, owner_token = F.token })
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

-- Per fight tick. Returns true while an escape owns the pawn this tick (the phase step is skipped).
-- The census runs ONLY for the hazard kinds an AI action just named (ability_profiles `hazards`, a watch window of
-- cfg.hazard_window_s) or that are still on the ground; zones go to move only when their set changes. Whether he
-- stands in one is avoidzones' own test (AZ.at on the normalised wire zones; feet height).
function M.hazard_frame(F, pawn, me, acts)
    local c = C()
    local cfg = M.cfg
    local names, any = {}, false
    for name, until_t in pairs(c.hazard_watch or {}) do
        if until_t > F.t then names[name] = true; any = true else c.hazard_watch[name] = nil end
    end
    for _, z in ipairs(F.zones or {}) do local k = z.id:match("^([%w_]+):"); if k then names[k] = true; any = true end end
    if any and F.t - (F.hazard_t or -99) >= cfg.hazard_s and me.pos then
        F.hazard_t = F.t
        local zones, land = M.hazard_census(F, me, names)
        local ids = {}
        for _, z in ipairs(zones) do ids[#ids + 1] = z.id end
        local sig = table.concat(ids, ",")
        if sig ~= (F.zone_sig or "") then
            F.zone_sig = sig
            mcall("move", "set_avoid_zones", F.log, zones) -- the wire format (metres, scalars only: R15)
            F.zones_set = #zones > 0 or nil
        end
        F.zones, F.zone_land = zones, land
    elseif not any then
        if F.zones_set then mcall("move", "set_avoid_zones", F.log, {}); F.zones_set, F.zone_sig = nil, nil end
        F.zones, F.zone_land = nil, nil
    end
    -- an escape under way: hold until it arrives (move idle) or its time is up, then restore the previous move
    local e = F.escape
    if e then
        local st = mcall("move", "status")
        if F.t >= e.until_t or (type(st) == "table" and st.mode == "idle" and F.t - e.t > 0.3) then
            F.escape = nil
            if F.ambient then M.ambient_release(F, "hazard escaped") -- the arbiter resumes whoever had the pawn
            elseif e.prev then mcall("move", "restore", F.log, e.prev) end
            F.following = false -- the fight's own follow starts again
            say(F.log, "hazard: out of " .. tostring(e.zone) .. " (" .. tostring(e.how) .. ")")
            return false
        end
        return true
    end
    if F.phase == "defend" or not me.pos or not F.zones or #F.zones == 0 then return false end
    local AZm = mod("avoidzones")
    local zs = AZm and AZm.normalize(F.zones, F.t)
    if not zs then return false end
    F.half_h = F.half_h or num(U.try(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)) or 90
    local zin = AZm.at(zs, me.pos.X, me.pos.Y, me.pos.Z - F.half_h, cfg.hazard_margin_cm)
    if not zin then return false end
    local info = (F.zone_land or {})[zin.id] or { land_s = 1, hazard = "?" }
    if zin.id == F.escaped_zone and F.t - (F.escaped_t or -9) < 1.0 then return false end -- just tried this one
    F.escaped_zone, F.escaped_t = zin.id, F.t
    F.n_hazards = (F.n_hazards or 0) + 1
    if F.ambient and not M.ambient_acquire(F, "hazard " .. tostring(info.hazard)) then return false end
    local r = mcall("move", "escape_zones", F.log, { time_s = info.land_s, bound = c.boss_bound })
    if type(r) == "table" and r.ok and not r.already_safe then
        F.escape = { t = F.t, until_t = F.t + (r.eta_s or 1) + 0.6, prev = r.prev, zone = zin.id, how = "walked" }
        F.following = false
        M.emit_activity({ kind = "hazard", by = F.by or "unknown", hazard = info.hazard, answer = "walk_out", eta_s = r.eta_s, land_s = info.land_s })
        return true
    end
    local why = type(r) == "table" and r.why or "no_move"
    -- too slow / no safe point / no route: a dodge outward (Phase Dash first when ready)
    local ab = ability_ctx(F)
    local D = mod("defense")
    local pd = D and D.abilities().phase_dash
    if pd and (ab.phase_dash or {}).available and (M.orders.abilities or {}).phase_dash ~= false then
        start_cast(F, "phase_dash", pd.spell_asset, "hazard: " .. tostring(info.hazard))
    end
    if acts.evade and (me.stamina or 0) >= (c.evade_cost or 15) then
        if F.ambient then
            -- no fight input pump outside a fight: one evade press through the input gate (not directional)
            local inp = mod("input")
            if inp and inp.inject then pcall(inp.inject, acts.evade) end
            M.ambient_release(F, "hazard dodged")
        else
            F.evade_dir = away_dir(me.pos, { X = zin.X, Y = zin.Y, Z = me.pos.Z }, "back")
            F.evade_until = F.t + 0.35
            tap(F, acts.evade, 4, "evade_hazard")
        end
        F.n_dodges = (F.n_dodges or 0) + 1
    end
    M.emit_activity({ kind = "hazard", by = F.by or "unknown", hazard = info.hazard, answer = "dodge", why = why, land_s = info.land_s })
    say(F.log, "hazard " .. tostring(zin.id) .. ": " .. tostring(why) .. " -> dodge outward")
    return false
end

-- The fight goes on against another creature. One place for it: what was read of the old target (HP, distance, a
-- fatal hit, who killed it) is not carried over to the new one. The creature the fight began with is remembered
-- (F.first), and every other one he fights is listed (F.others), for the result's words and the way back.
local function switch_target(F, row)
    if F.locked and not F.dead_seen and U.alive(F.target) then
        -- his lock is on a creature that lives: let it go (one frame of the toggle, as finish does). Which creature a
        -- new press would lock cannot be read (FLockOnTarget has no reflected fields), so he fights on without one
        local pawn = F.pc and U.try(function() return F.pc.Pawn end)
        local acts = U.valid(pawn) and actions(pawn)
        if acts and acts.lock then inject(acts.lock) end
        F.no_lock = true
    end
    F.first = F.first or { actor = F.target, id = F.target_id, name = F.target_name, killed = (F.dead_seen and not F.killed_by) or false }
    if row.id ~= F.first.id then
        F.others = F.others or {}
        local known
        for _, o in ipairs(F.others) do if o.id == row.id then known = true end end
        if not known then F.others[#F.others + 1] = { id = row.id, name = row.name, killed = false } end
    end
    F.target, F.target_id, F.target_name = row.actor, row.id, row.name
    F.target_class = row.class or (U.valid(row.actor) and U.class_word(row.actor)) or nil
    F.dead_seen, F.locked, F.following, F.follow_t = false, false, false, nil
    F.target_hp, F.target_pos, F.dist_m = row.hp, row.pos, row.distance_m or 99
    F.fatal_hit, F.killed_by, F.out_since, F.far_n, F.si_d0 = nil, nil, nil, 0, nil
    F.sw_hits, F.sw_presses = F.hits, F.presses
    M.set_reach(F, row.actor)
end

-- The nearest threat that this fight has not seen dead. The census is cached for cfg.census_s, so a row read just
-- before a death still says alive: taken as the next target, the same creature's death was counted as a second kill
-- (test_combat (g5), one run in two).
local function live_threat(F, me, c)
    for _, th in ipairs(M.pick_threats(creatures_near(me.pos, M.cfg.assist_m), c.attackers, c.ally_attackers, M.orders, F.t)) do
        if not (F.dead_ids or {})[th.id] then return th end
    end
end

-- His kill of the current target, noted on the fight's list of who he fought.
function M.note_kill(F)
    if F.first and F.first.id == F.target_id then F.first.killed = true end
    for _, o in ipairs(F.others or {}) do if o.id == F.target_id then o.killed = true end end
end

-- A commanded fight that took on other creatures too: data.also_fought says so in words he can speak, and
-- data.went_for names the creature he was sent for when the fight ended on another one with that one not killed.
function M.fought_words(F, data)
    local first = F.first
    if not first or not F.others or #F.others == 0 then return end
    local names, k, n = {}, {}, {}
    for _, o in ipairs(F.others) do
        local nm = o.name or "creature"
        if not k[nm] and not n[nm] then names[#names + 1] = nm end
        if o.killed then k[nm] = (k[nm] or 0) + 1 else n[nm] = (n[nm] or 0) + 1 end
    end
    local parts = {}
    for _, nm in ipairs(names) do if k[nm] then parts[#parts + 1] = string.format("%d %s killed", k[nm], nm) end end
    for _, nm in ipairs(names) do if n[nm] then parts[#parts + 1] = string.format("%d %s not killed", n[nm], nm) end end
    local settled = first.killed or F.target_id == first.id
    if not settled then data.went_for = { name = first.name, id = first.id, killed = false } end
    data.also_fought = string.format(settled and "Besides the %s I went for, I fought what attacked me: %s."
        or "I did not kill the %s I went for; besides it I fought what attacked me: %s.", tostring(first.name or "creature"), table.concat(parts, ", "))
end

-- He swings at what he can reach. Ratcatcher 20261116-212108: the Giant Rat he was sent for stood up a ledge while
-- two others bit him; the fight kept to the one named for 120 s (21 dodges, 6 swings, none landed, 114 damage) and he
-- died in the next. When the target has been out of his reach for swap_out_s, or swap_dry_presses swings in a row
-- landed nothing on it, and a creature that attacked him (a hit, or a swing he had to answer) within
-- attacker_memory_s stands within swap_m on his level, the fight goes on against that one. The one he went for is
-- taken up again when the others are down (frame, restore). -> true when the target changed
function M.swap_target(F, me, c)
    local cfg = M.cfg
    if F.hits ~= F.sw_hits then F.sw_hits, F.sw_presses = F.hits, F.presses end
    if (F.dist_m or 99) > F.reach then F.out_since = F.out_since or F.t else F.out_since = nil end
    if F.t - (F.swap_t or -9) < 0.25 then return false end
    F.swap_t = F.t
    local why
    local dry = F.presses - (F.sw_presses or 0)
    if F.out_since and F.t - F.out_since >= cfg.swap_out_s then why = string.format("out of my reach for %.1f s", F.t - F.out_since)
    elseif dry >= cfg.swap_dry_presses then why = string.format("%d swings in a row landed nothing on it", dry) end
    if not why or (F.swaps or 0) >= cfg.max_swaps or not me.pos then return false end
    local best, seen_n = nil, 0
    for _, cr in ipairs(creatures_near(me.pos, cfg.swap_m)) do
        if cr.id ~= F.target_id and not cr.dead and not cr.follower and not (M.orders.avoid or {})[(cr.name or ""):lower()] then
            seen_n = seen_n + 1
            local last = math.max(c.attackers[cr.id] or -1e9, (F.defended or {})[cr.id] or -1e9)
            if F.t - last <= cfg.attacker_memory_s and cr.pos and math.abs(cr.pos.Z - me.pos.Z) <= cfg.swap_dz_cm
                and (not best or (cr.distance_m or 99) < (best.distance_m or 99)) then best = cr end
        end
    end
    if not best then
        if F.t - (F.swap_said or -9) >= 2 then
            F.swap_said = F.t
            say(F.log, string.format("the %s: %s; nothing else that attacked me is within %d m on my level (%d other creature%s there)",
                tostring(F.target_name), why, cfg.swap_m, seen_n, seen_n == 1 and "" or "s"))
        end
        return false
    end
    F.swaps = (F.swaps or 0) + 1
    say(F.log, string.format("the %s (%s): %s; the %s (%s) attacked me and is %.1f m off: fighting it", tostring(F.target_name), tostring(F.target_id), why,
        tostring(best.name), tostring(best.id), best.distance_m or -1))
    switch_target(F, best)
    F.phase_log[#F.phase_log + 1] = string.format("%.1f swap to %s (%s)", F.t - F.t0, tostring(best.name), why)
    if #F.phase_log > 30 then table.remove(F.phase_log, 1) end
    set_phase(F, "approach", "fighting what is on me")
    return true
end

local function frame(F)
    local c = C()
    if F.gen ~= c.gen or F.done then return end
    if _G.DW_PAUSE then return abort_paused(F) end
    local pc = F.pc
    local pawn = pc and U.valid(pc) and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return finish(F, result_of(F, false, "companion_down")) end
    F.t = now(pawn)
    if F.def then defend_act(F, pawn, actions(pawn)) end -- (its moment; then a dodge key that did nothing, again)
    if F.casts then casts_frame(F) end
    if F.def and F.def.cast then defend_followup(F, pawn, actions(pawn)) end
    F.frame_n = (F.frame_n or 0) + 1
    c.frame_id = (c.frame_id or 0) + 1
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
    elseif F.step_in and F.t < (F.step_in_until or 0) then pcall(function() pawn:AddMovementInput(F.step_in, 1.0, false) end)
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
    if F.hp_prev and me.hp and me.hp < F.hp_prev - 0.5 and F.t - (c.last_mc_dmg_t or -9) > 1.0 then
        -- damage seen only as an HP drop: record it like a damage event (attacker unknown)
        c.me_seq = (c.me_seq or 0) + 1
        c.me_dmg = c.me_dmg or {}
        c.me_dmg[#c.me_dmg + 1] = { seq = c.me_seq, t = F.t, amount = F.hp_prev - me.hp, source = "hp_poll" }
        if #c.me_dmg > 20 then table.remove(c.me_dmg, 1) end
        F.dmg_taken = (F.dmg_taken or 0) + (F.hp_prev - me.hp)
        M.note_damage(F, F.hp_prev - me.hp)
        -- who did it: no damage multicast reaches the client for AI hits, but the attacker's impact event
        -- (Multicast_SendDamageCacheData) does, just before the HP drop (live 09:41: a second Kebbit hit him
        -- 4 times while he looted, unanswered, because nothing recorded it as an attacker)
        local best
        for _, e in ipairs(c.impacts or {}) do
            if e.id and F.t - e.t >= -0.2 and F.t - e.t <= M.cfg.impact_attrib_s and (not best or e.t > best.t) then best = e end
        end
        if best then c.attackers[best.id] = F.t; c.me_dmg[#c.me_dmg].inst = best.id end
    end
    F.hp_prev = me.hp
    if not F.lat_t or F.t - F.lat_t > 5 then -- one-way latency for timed defence
        F.lat_t = F.t
        local ping = num(U.try(function() return pc.PlayerState:GetPingInMilliseconds() end))
        if ping and ping > 0 then F.latency = ping / 2000 end
    end
    if me.dead then return finish(F, result_of(F, false, "companion_down", { died = true })) end
    if F.heal_pending and F.t - F.heal_pending.t >= 2.5 and F.phase ~= "disengage" and F.phase ~= "flee" then
        M._try_eat(F, me, false) -- (verifies the pending bite; eats again only below eat_hp)
    end
    if F.t - F.t0 > M.cfg.fight_timeout_s then
        local _, held = held_summary(F)
        local tp, mp = F.target_pos, me.pos
        local dz = tp and mp and (tp.Z - mp.Z) / 100
        return finish(F, result_of(F, false, "timeout", { dist_m = F.dist_m and math.floor(F.dist_m * 10) / 10,
            detail = string.format("the fight ran %d s %s: %d swings, %d hit%s%s", math.floor(F.t - F.t0),
                (F.kills or 0) == 0 and "without a kill" or string.format("and was not over (%d kill%s)", F.kills, F.kills == 1 and "" or "s"), F.presses or 0, F.hits or 0,
                held ~= "" and ("; not swinging for: " .. held) or "",
                F.dist_m and string.format("; the %s is %.1f m away%s", tostring(F.target_name or "target"), F.dist_m,
                    dz and math.abs(dz) >= 0.8 and string.format(", %.1f m %s me", math.abs(dz), dz > 0 and "above" or "below") or "") or "") }))
    end
    local acts = actions(pawn)
    local mode = U.short(U.try(function() return pc.CurrentInputMode end))
    F.input_mode = mode
    local in_conv = mode and mode:find("Conversation", 1, true) ~= nil
    if in_conv and not F.casting then
        -- a dialogue (talk review finding 8): never the generic back key; leave through talk (its own verified
        -- leave: the panel's Cancel as the conversation's owner), at most twice, and say why
        F.mode_bad_since = F.mode_bad_since or F.t
        if (F.conv_leaves or 0) < 2 and F.t - (F.conv_leave_t or -9) >= M.cfg.conversation_retry_s then
            F.conv_leave_t, F.conv_leaves = F.t, (F.conv_leaves or 0) + 1
            M.leave_conversation(F, F.conv_leaves)
        end
        if F.t - F.mode_bad_since > M.cfg.conversation_leave_s then
            return finish(F, result_of(F, false, "body_error", { why = "conversation_blocked", mode = mode, npc = F.conv_npc,
                via = F.conv_via, detail = "the conversation did not close, so gameplay inputs do not work" }))
        end
    elseif mode and not M.is_gameplay_mode(mode) and not F.casting then
        F.mode_bad_since = F.mode_bad_since or F.t
        if F.t - (F.mode_press_t or -9) >= 0.5 and (F.mode_presses or 0) < 4 then
            -- leave it the way a player does: the mode's own back/cancel key (Escape)
            F.mode_press_t, F.mode_presses = F.t, (F.mode_presses or 0) + 1
            local back = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
            local cancel = U.find_object("/Game/Gameplay/Inputs/Actions/Spellcasting/IA_Spellcasting_Cancel.IA_Spellcasting_Cancel")
            local a = (mode == "DIM_SpellcastingMode" or mode == "DIM_SpellPlacementMode") and cancel or back
            -- raw: the gate blocks gameplay presses in a non-gameplay mode, but this IS the mode's own back key
            local inp = mod("input")
            if mode == "DIM_Resting" then
                -- lying in a bed or shelter: the game ends a rest on a plain interact press, not on Back (skills.lua
                -- get-up path; live 2026-11-01 19:56Z: attack with a bow and a staff, 3 presses each swallowed, "stuck
                -- in DIM_Resting" after the previous window's nap)
                a = nil
                local r = mcall("inventory", "press_interact", F.log)
                say(F.log, "input mode DIM_Resting: pressing use to get up -> " .. tostring(r and (r.ok or r.reason)))
            end
            if a then
                if inp and inp.raw_inject then inp.raw_inject(a)
                else local s = eis(); if s then pcall(function() s:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end) end end
            end
            say(F.log, "input mode " .. tostring(mode) .. ": pressing back to reach gameplay")
        end
        if F.t - F.mode_bad_since > 5 then
            return finish(F, result_of(F, false, "body_error", { why = "input_mode_blocked", mode = mode,
                detail = "stuck in " .. tostring(mode) .. "; gameplay inputs do not work there" }))
        end
    else
        if F.conv_leaves and not F.conv_closed then
            F.conv_closed = true
            say(F.log, "conversation closed (" .. tostring(F.conv_via) .. ")")
        end
        F.mode_bad_since, F.mode_presses = nil, 0
    end
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
                if h.source ~= "hp_poll" then M.learn_hit(F, h.amount) end -- (a multicast names him as the instigator)
                if F.following then mcall("move", "progress_reset", F.log) end
                if h.fatal then F.fatal_hit = true end
            end
        end
    end
    local tgt = U.alive(F.target) and read_creature(F.target, me.pos) or nil
    if tgt then
        local press_win = F.rg and (M.cfg.magic_verdict_s or 1.6) + 0.9 or 1.2
        local after_press = F.last_press_t ~= nil and F.t - F.last_press_t <= press_win
        if F.target_hp and tgt.hp and tgt.hp < F.target_hp - 0.5 and not after_press then
            -- someone else's hit (Buddy's, Luis's): not his (live 2026-11-01 22:05: "hits=7" with 0 presses)
            F.others_dmg = (F.others_dmg or 0) + (F.target_hp - tgt.hp)
        elseif F.target_hp and tgt.hp and tgt.hp < F.target_hp - 0.5 and F.t - (F.last_hit_t or -9) > 0.3 then
            -- the target lost HP right after his press: his hit (the damage multicast did not reach the client live)
            F.hits = F.hits + 1
            F.dmg = (F.dmg or 0) + (F.target_hp - tgt.hp)
            F.last_hit_t = F.t
            -- his own hit only when it follows his press (another player's hit drops the HP too)
            if F.last_press_t and F.t - F.last_press_t <= 1.2 then M.learn_hit(F, F.target_hp - tgt.hp) end
            if F.following then mcall("move", "progress_reset", F.log) end
            c.counts.hits = c.counts.hits + 1
            c.my_hits[#c.my_hits + 1] = { seq = c.counts.hits, t = F.t, victim = F.target_id, name = F.target_name,
                                          amount = F.target_hp - tgt.hp, source = "hp_poll" }
            if #c.my_hits > 30 then table.remove(c.my_hits, 1) end
            F.hit_seq = c.counts.hits
            if tgt.hp <= 0 then F.fatal_hit = true end
        end
        F.target_pos, F.dist_m, F.target_hp = tgt.pos, tgt.distance_m or 99, tgt.hp
        if tgt.dead and not F.dead_seen then
            F.dead_seen = true
            local dd = M.death_of(F.target_id)
            if dd and dd.by and dd.by ~= "me" then F.killed_by = dd.by -- someone else's kill is not his
            else
                F.kills = F.kills + 1
                c.counts.kills = c.counts.kills + 1
            end
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
    if F.dead_seen then
        F.dead_ids = F.dead_ids or {}
        F.dead_ids[F.target_id] = true
        if not F.killed_by then M.note_kill(F) end
    end
    if F.dead_seen and (F.phase == "engage" or F.phase == "defend" or F.phase == "approach" or F.phase == "equip") then
        -- another attacker still on us? retarget instead of looting
        local nxt = live_threat(F, me, c)
        -- self-defence is the reflex's job in any fight: a commanded fight retargets only what is hitting him
        if nxt and nxt.id ~= F.target_id and (F.mode == "reflex" or nxt.why == "attacked_me") then
            say(F.log, "retarget " .. nxt.id)
            switch_target(F, nxt)
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
        -- the weapon he WILL fight with: before the equip phase picks it, the first assessment (react) used to score
        -- him bare-handed (dps 5) with a sword in the bag, and could flee "losing" before drawing it
        if not F.profile and not F.equip_plan and F.pre_profile == nil then
            local pick = M.best_weapon(mcall("inventory", "list", F.log) or {}, { name = F.target_name, affinities = F.affinities }, nil, c.learned)
            F.pre_profile = pick.weapon and pick.weapon.profile or false
        end
        local profile = F.profile or (not F.equip_plan and F.pre_profile) or nil
        local orders = F.mode == "attack" and { commanded = true, force = F.force, avoid = {}, flee_hp = M.orders.flee_hp } or M.orders
        if F.cornered then orders = { force = true, avoid = {} } end -- it kept up with his flee: fight it out
        local rate, rate_src = M.fight_rate(profile)
        local foes = enemies_for_assess(F, me.pos)
        local a = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = rate }, foes, orders, F.decision, M.cfg)
        F.assessment = a
        if a.decision == "flee" and not F.cornered then
            -- running from what is already on him and at least as fast only gives it free hits (live 2026-11-01
            -- 22:08: a cow 5.5 m away, mid-swing, hit him for 36 in the first 0.4 s of the flee)
            local stuck, why = M.cant_escape(F, pawn, me)
            if stuck then
                F.cornered = why
                a.decision, a.why = "fight", "cant_outrun"
                say(F.log, "no flee: " .. why)
            end
        end
        if not F.start_said and F.mode == "reflex" then
            -- tell the brain at once what the reflex is doing about it, and why (communication: never silent)
            F.start_said = true
            M.emit_activity({ kind = "combat_started", by = "reflex", target = F.target_name, target_id = F.target_id, why = F.why,
                decision = a.decision, because = F.cornered and ("cornered: " .. F.cornered) or a.why, verdict = a.verdict,
                hp = me.hp, max_hp = me.max_hp, target_hp = F.target_hp,
                weapon = profile and profile.name or "bare hands", est_s_to_kill = a.my_ttk and math.floor(a.my_ttk),
                est_s_to_die = a.their_ttk and math.floor(a.their_ttk), pack = a.enemies,
                hostiles = M.pack_words(foes), unknown = a.unknown, my_rate_from = rate_src,
                est_kill = M.band_words(a.kill_lo, a.kill_hi), est_die = M.band_words(a.die_lo, a.die_hi) })
        end
        if a.decision == "flee" then return begin_flee(F, a.why) end
        F.decision = "fight"
        -- the HP TREND (live 16:15: a "losing" flee began 14 s in and he died fleeing): time to live at the damage
        -- rate of the last cfg.trend_s against the time to win (his observed damage rate on the target, else the
        -- estimate). Losing fast -> disengage-heal now if he can, else (self-defence) flee now.
        F.hp_trend = F.hp_trend or {}
        local tr = F.hp_trend
        tr[#tr + 1] = { t = F.t, hp = me.hp or 0 }
        while #tr > 1 and F.t - tr[1].t > M.cfg.trend_s do table.remove(tr, 1) end
        local dt = F.t - tr[1].t
        local rate = dt >= M.cfg.trend_min_s and math.max(0, (tr[1].hp - (me.hp or 0)) / dt) or 0
        if rate > 0.3 then
            local ttl = (me.hp or 0) / rate
            local fight_s = math.max(F.t - F.t0, 1)
            local my_rate = (F.dmg or 0) / fight_s
            -- his own observed damage rate decides once he has fought a while (5 s of no damage = not winning)
            local ttw = (my_rate > 0.1 and F.target_hp) and (F.target_hp / my_rate) or (fight_s >= 5 and 1e9) or a.my_ttk or 1e9
            a.ttl_s, a.ttw_s = math.floor(ttl), ttw < 1e8 and math.floor(ttw) or nil
            -- (cornered: it kept up with his flee, so backing off or running again only gives it free hits)
            if ttl < M.cfg.danger_ttl_s and ttw > ttl * M.cfg.danger_win_margin and not F.cornered then
                local why = string.format("losing fast: ~%ds to live, ~%s to win", math.floor(ttl), ttw < 1e8 and (math.floor(ttw) .. "s") or "?")
                if M.orders.disengage ~= false and not F.dis and not F.no_food and (F.eat_fails or 0) < 3 and F.phase ~= "disengage"
                    and F.t - (F.dis_end or -99) > 10 then
                    local list = mcall("inventory", "list", F.log) or {}
                    if M.best_heal_food(list) then
                        F.dis = { step = "back", t = F.t }
                        F.n_disengage = (F.n_disengage or 0) + 1
                        F.danger_disengages = (F.danger_disengages or 0) + 1
                        if F.phase == "defend" then return end -- (finish_defend goes back to the disengage)
                        return set_phase(F, "disengage", why)
                    end
                    F.no_food = true
                end
                if F.mode == "reflex" and not F.dis then
                    -- (the same question as any flee: can he get away at all?)
                    local stuck, cw = M.cant_escape(F, pawn, me)
                    if not stuck then return begin_flee(F, why) end
                    F.cornered = cw
                    say(F.log, "no flee (" .. why .. "): " .. cw)
                end
            end
        end
        -- low HP but winnable: back off and eat first (the model's policy: orders.disengage / heal_hp)
        local frac = (me.max_hp and me.max_hp > 0) and (me.hp or 0) / me.max_hp or 1
        if M.orders.disengage ~= false and not F.dis and (F.phase == "engage" or F.phase == "approach") and not F.cornered and not a.finishing
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
    -- a hard fight (not a likely win, or a boss): Tempest Shield before the first blow, not at 28 HP (live
    -- 2026-11-01 22:08: cast at 28 HP against a cow and died 3 s later); once per fight
    if not F.opened_shield and not F.casting and (F.phase == "approach" or F.phase == "engage") then
        local ab = M.fight_abilities(F)
        local act = active_effects(F) or {}
        local D = mod("defense")
        local def = D and D.abilities and D.abilities().tempest_shield
        F.opened_shield = true
        if ab.tempest_shield and def and not act.tempest_shield and not F.def then
            start_cast(F, "tempest_shield", def.spell_asset, "before engaging: " .. tostring(F.assessment and F.assessment.verdict))
            F.n_precasts = (F.n_precasts or 0) + 1
        end
    end
    -- (also late in a defence, once its hit has passed: the next attack's window may need casting now)
    local past_hit = F.phase == "defend" and F.def and F.def.started and F.t - F.def.tel_t > (F.def.plan.impact_s or 0.6) + 0.1
    if (F.phase == "engage" or F.phase == "approach" or past_hit) and not F.casting and F.t - (F.precast_t or -9) >= 0.25 then
        F.precast_t = F.t
        local D = mod("defense")
        if D and D.precast_decision then
            local ctx = { max_hp = me.max_hp, stamina = me.stamina, latency_s = F.latency or 0.03, abilities = M.fight_abilities(F),
                          active = active_effects(F) }
            local dec = D.precast_decision(F.target_name, F.t, ctx, M.orders)
            if dec and dec.cast_now then
                local rec = start_cast(F, dec.ability, dec.spell_asset, "ahead: " .. tostring(dec.why))
                rec.pre_key = dec.key
                F.n_precasts = (F.n_precasts or 0) + 1
            end
        end
    end
    pcall(M.ability_frame, F, me)
    if F.t - (F.pack_t or -9) >= 0.5 and me.pos then F.pack_t = F.t; pcall(M.pack, F, me) end
    do local okst, err = pcall(M.status_frame, F, pawn, me); if not okst then c.status_err = tostring(err) end end
    if F.phase ~= "defend" then M.boss_frame(F, me) end
    do
        local okh, owned = pcall(M.hazard_frame, F, pawn, me, acts)
        if not okh then c.hazard_err = tostring(owned) elseif owned then return end
    end
    if F.phase == "approach" or F.phase == "disengage" then
        for id, tt in pairs(c.telegraphs) do
            if F.t - tt <= M.cfg.telegraph_fresh_s and tt > (F.last_tele or 0) and id == F.target_id and (F.dist_m or 99) <= M.cfg.telegraph_m then
                return M._start_defend(F, me, id, tt, (c.tele_info or {})[id]) -- F.dis is kept: back to it after
            end
        end
    end
    if (F.phase == "engage" or F.phase == "approach") and tgt and not F.dead_seen and not F.rg and not F.dis and not F.casting
        and M.swap_target(F, me, c) then return end
    if F.phase == "react" then
        if F.t >= F.react_until then set_phase(F, "equip") end
    elseif F.phase == "equip" then
        if step_equip(F, pawn) then
            local r, l = held_items(pawn)
            F.cap = M.capabilities(pc, r, l)
            if F.profile and (F.profile.kind == "ranged" or F.profile.kind == "magic") then
                local ok, why = ranged_setup(F, pawn, pc)
                if not ok then
                    return finish(F, result_of(F, false, (why == "no_ammo" or why == "no_runes") and "not_enough_resources" or "body_error",
                        { why = why, detail = M.ammo_words(why, F.profile) or ("ranged weapon not ready: " .. tostring(why)) }))
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
        M.held(F, "closing_in")
        -- (a target named from farther than lost_m is not "lost" while he closes in: farther than it began, + 5 m)
        local lost_m = math.max(M.cfg.lost_m, (F.start_dist_m or 0) + 5)
        if tgt and tgt.distance_m and tgt.distance_m > lost_m and not M.airborne(F.target_id) then
            F.far_since = F.far_since or F.t
            if F.t - F.far_since > M.cfg.lost_s then return finish(F, result_of(F, false, "too_far", { dist_m = tgt.distance_m })) end
        else F.far_since = nil end
        if not F.following then follow_target(F, F.follow, (F.dist_m or 0) > 8) end
        if F.dist_m and F.dist_m <= F.reach then set_phase(F, "engage")
        else
            local blocked = M.approach_blocked(F, mcall("move", "status"))
            if blocked then
                local reason = blocked.reason or "path_blocked"
                blocked.reason = nil
                return finish(F, result_of(F, false, reason, blocked))
            end
        end
    elseif F.phase == "engage" then
        if F.rg then step_ranged(F, pawn, me, acts, tgt) else step_engage(F, pawn, me, acts, tgt) end
        if F.dist_m and F.dist_m > F.reach * 3 then
            local nxt = live_threat(F, me, c)
            if nxt and nxt.id ~= F.target_id and nxt.why == "attacked_me" and (nxt.distance_m or 99) <= F.reach * 1.5
                and (F.retargets or 0) < M.cfg.max_retargets then
                F.retargets = (F.retargets or 0) + 1
                say(F.log, "target moved away; " .. tostring(nxt.name) .. " is on me: fighting it")
                switch_target(F, nxt)
            else
                set_phase(F, "approach", "target moved away")
            end
        end
    elseif F.phase == "defend" then
        M.held(F, "defending")
        step_defend(F, pawn, me, acts)
    elseif F.phase == "disengage" then
        M.held(F, "backing_off")
        step_disengage(F, pawn, me, acts)
        if not F.dis then F.dis_end = F.t end
    elseif F.phase == "flee" then
        M.held(F, "fleeing")
        step_flee(F, pawn, me)
    elseif F.phase == "loot" or F.phase == "restore" then
        -- attacked while looting or putting things back: answer it first
        local nxt = F.t - (F.loot_threat_t or -9) >= 0.5 and live_threat(F, me, c)
        if nxt then F.loot_threat_t = F.t end
        if nxt and nxt.why == "attacked_me" and (F.retargets or 0) < M.cfg.max_retargets then
            F.retargets = (F.retargets or 0) + 1
            say(F.log, "attacked by " .. nxt.id .. " during " .. F.phase .. ": fighting back")
            mcall("move", "stop", F.log)
            F.loot_item = nil
            switch_target(F, nxt)
            return set_phase(F, "approach", "attacked by " .. tostring(nxt.name))
        end
        -- the others are down: the fight he was asked for is with the creature he went for
        if F.phase == "restore" and not F.restore_sent and F.mode == "attack" and F.first and F.first.id ~= F.target_id and not F.first.killed then
            local row = U.alive(F.first.actor) and read_creature(F.first.actor, me.pos) or nil
            if row and not row.dead then
                say(F.log, string.format("back to the %s I went for (%s), %.1f m off", tostring(row.name), tostring(row.id), row.distance_m or -1))
                switch_target(F, row)
                return set_phase(F, "approach", "back to the one I went for")
            elseif not row then
                return finish(F, result_of(F, false, "unknown_target", { detail = string.format("the %s I went for is no longer in sight", tostring(F.first.name or "creature")) }))
            end
        end
        if F.phase == "loot" then step_loot(F, pawn, me) else step_restore(F, pawn) end
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
    if U.valid(U.prop(actor, "PlayerState")) or (U.class_word(actor) or ""):find("PlayerCharacter", 1, true) then
        return { ok = false, reason = "unsafe", data = { why = "never attack players" } }
    end
    c.me_id, c.pc_id = U.short(pawn), U.short(pc)
    c.on_target = {}
    pcall(M.memory, log, pawn) -- once per world+character: what earlier fights taught him
    local me = read_me(pawn, pc)
    local tgt = read_creature(actor, me.pos)
    if tgt.dead then
        local tid = U.short(actor)
        local dd, mine = M.death_of(tid), 0
        for _, h in ipairs(c.my_hits or {}) do if h.victim == tid then mine = mine + 1 end end
        local who = dd and (dd.by == "me" and "I killed it" or dd.by and ("killed by " .. dd.by)) or "I did not see who killed it"
        local ago = dd and string.format(" %d s ago", math.floor(math.max(0, now(pawn) - dd.t))) or ""
        return { ok = false, reason = "unknown_target", data = { killed_by = dd and dd.by or nil, detail = string.format(
            "already dead: %s%s; %s", who, ago, mine > 0 and string.format("I hit it %d time(s)", mine) or "I never hit it") } }
    end
    if tgt.follower then return { ok = false, reason = "unsafe", data = { why = "a player's follower" } } end
    -- a commanded fight is the model's call (North Star review): the fight-or-flight estimate is
    -- returned as INFORMATION, never as a refusal; only "never attack players" is a hard gate
    local held = M.held_weapon(pawn)
    local estimate = M.assess_vs({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = M.fight_rate(held) },
        { name = tgt.name, hp = tgt.hp, max_hp = tgt.max_hp, pl = tgt.pl, boss = tgt.boss, dps_obs = M.enemy_dps(tgt.name) }) or {}
    -- the pawn FIRST, then the old fight ends (live 18:19: a refused command-level attack had already ended the
    -- guard's running reflex fight, so nothing fought back and a runt beat him down to 1 % HP)
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "combat:" .. (opts.mode or "attack"), level = opts.level or (opts.mode == "reflex" and "reflex" or "command"),
                                     resumable = false, uses_move = true, lease_s = 5,
                                     on_stop = function(_, _, why) local f = C().fight; if f and f.token == token then finish(f, result_of(f, false, "interrupted", { detail = why })) end end })
        if not r.ok then
            local cur = c.fight
            return { ok = false, reason = "interrupted", data = { detail = r.detail or "pawn busy", why = "pawn_busy", owner = r.owner,
                     current_fight = cur and { target = cur.target_name, mode = cur.mode, phase = cur.phase } or nil } }
        end
        token = r.token
    end
    if c.fight and c.fight.token ~= token then finish(c.fight, result_of(c.fight, false, "interrupted", { detail = "a new fight started" })) end
    c.gen = c.gen + 1
    c.counts.fights = c.counts.fights + 1
    local t = now(pawn)
    local F = { gen = c.gen, log = log, pc = pc, mode = opts.mode or "attack", force = opts.force, token = token,
                target = actor, target_id = tgt.id, target_name = tgt.name, target_class = tgt.class or (U.valid(actor) and U.class_word(actor)) or nil, target_hp = tgt.hp, target_pos = tgt.pos,
                dist_m = tgt.distance_m or 99, start_dist_m = tgt.distance_m, affinities = read_affinities(actor),
                t0 = t, t = t, phase_t = t, inputs = {}, presses = 0, hits = 0, kills = 0, verified = 0, unverified_run = 0,
                hit_seq = c.counts.hits, phase_log = {}, items_before = {}, loot_skip = {}, why = opts.why,
                by = opts.by or (opts.mode == "reflex" and "reflex" or "debug"), hp_start = tgt.hp, loot_names = {},
                style = opts.style, weapon_pref = opts.weapon, boss = tgt.boss or nil, cornered = opts.cornered }
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
    local actor, why = M.resolve_target(target, U.loc(pawn))
    if not actor then return { ok = false, reason = "unknown_target", data = why or { target = tostring(target) } } end
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
-- ------------------------------------------------------------------ ambient hazards + cures (outside fights)
-- The same hazard and cure code as the fight loop (M.hazard_frame / M.status_frame) on a light context, from the
-- combat_guard service's tick while no fight runs. OFF until the read-only live probe passes (cfg.ambient, or
-- env DW_COMBAT_AMBIENT=1). Triggers only: the hazard census runs only while an AI action opened a hazard watch
-- (or zones are down); statuses are read after a damage event, then every cfg.ambient_status_s while a harmful one
-- stays. To ACT it takes a short reflex lease from the arbiter (the current owner, e.g. a follow or a gather, is
-- suspended and resumed on release). Never under DW_PAUSE; nothing at all without a valid, living pawn.
function M.ambient_enabled()
    if M.cfg.ambient ~= nil then return M.cfg.ambient == true end
    return os.getenv("DW_COMBAT_AMBIENT") == "1"
end
function M.ambient_acquire(A, why)
    if A.token then
        local arb = mod("arbiter")
        if arb and arb.holds and arb.holds(A.token) then arb.renew(A.token); return true end
        A.token = nil
    end
    local arb = mod("arbiter")
    if not arb then return true end -- no arbiter (tests without one): act anyway
    local r = arb.request(A.log, { name = "combat:ambient", level = "reflex", resumable = false, uses_move = true, lease_s = 8,
                                   on_stop = function() A.token = nil; A.escape = nil end })
    if not (r and r.ok) then
        say(A.log, "ambient: no lease for " .. tostring(why) .. " (" .. tostring(r and r.reason) .. ")")
        return false
    end
    A.token = r.token
    A.n_leases = (A.n_leases or 0) + 1
    say(A.log, "ambient: lease for " .. tostring(why))
    return true
end
function M.ambient_release(A, why)
    if not A.token then return end
    local arb = mod("arbiter")
    if arb then pcall(arb.release, A.log, A.token, why or "done") end
    A.token = nil
end
function M.ambient_tick(log, pawn, pc)
    if _G.DW_PAUSE or not M.ambient_enabled() then return end
    if not U.valid(pawn) or U.try(function() return pawn.HealthComponent:IsDead() end) == true then return end
    local c = C()
    local A = c.ambient
    if not A then A = { ambient = true, by = "ambient", phase = "idle", inputs = {} }; c.ambient = A end
    A.log, A.pc = log, pc
    A.t = now(pawn)
    local me = read_me(pawn, pc)
    A.me_last = me
    -- AI actions seen since the last tick: resolved here too (their profiles open the hazard watch; no defence
    -- outside a fight: the guard starts one if something attacks)
    if next(c.ai_actions or {}) then pcall(M.ability_frame, A, me) end
    -- hazards: only while watched / on the ground (M.hazard_frame keeps its own cadence)
    local watched = next(c.hazard_watch or {}) ~= nil or (A.zones and #A.zones > 0) or A.escape ~= nil
    if watched then
        local okh, err = pcall(M.hazard_frame, A, pawn, me, actions(pawn))
        if not okh then c.ambient_err = tostring(err) end
        pcall(casts_frame, A)
    end
    -- statuses: after damage, then while a harmful one stays
    local dmg_seen = (c.me_seq or 0) ~= (A.me_seq or 0)
    A.me_seq = c.me_seq or 0
    local due = dmg_seen or A.cure_pending or (A.harmful and A.t - (A.status_t or -99) >= M.cfg.ambient_status_s)
    if due then
        A.status_t = nil -- (status_frame's own cadence check)
        local oks, err = pcall(M.status_frame, A, pawn, me)
        if not oks then c.ambient_err = tostring(err) end
        A.harmful = false
        for _, e in pairs(((c.statuses or {}).effects) or {}) do if e.harmful then A.harmful = true end end
        A.status_t = A.t
    end
    if A.token and not A.escape and not A.cure_pending then M.ambient_release(A, "nothing to do") end
end

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
    if c.fled_from then trim_map(c.fled_from, t, cfg.refled_s or 30) end
    if c.fight then c.guard_hp = nil; return end
    -- an AI hit reaches this client as an HP drop plus the attacker's impact event, with no damage multicast
    -- (the fight frame attributes it the same way): so between fights too, whoever just hit him is
    -- "attacked_me" at once, whatever its archetype or stance
    local hp = num(U.health(pawn))
    if hp and c.guard_hp and hp < c.guard_hp - 0.5 and t - (c.last_mc_dmg_t or -9) > 1.0 then
        local best
        local win = cfg.impact_attrib_s + cfg.guard_period_ms / 1000
        for _, e in ipairs(c.impacts or {}) do
            if e.id and t - e.t >= -0.2 and t - e.t <= win and (not best or e.t > best.t) then best = e end
        end
        if best then c.attackers[best.id] = t; c.guard_hit = { t = t, id = best.id, amount = c.guard_hp - hp } end
    end
    c.guard_hp = hp
    local origin = U.loc(pawn)
    c.guard_pos = origin -- (on_ai_attack reads swings near him between fights)
    do local oka, err = pcall(M.ambient_tick, log, pawn, pc); if not oka then c.ambient_err = tostring(err) end end
    if c.ambient and (c.ambient.escape or c.ambient.token) then return end -- busy getting out of something
    if U.try(function() return pawn.HealthComponent:IsDead() end) == true then return end
    -- one creature scan per tick: on a tick threat_watch is due the census is read out to odds_m here, so its rows
    -- come from this cache (no second FindAllOf of creatures); the reflex still sees only what is within its reach
    local reach_m = math.max(cfg.aggro_m, cfg.assist_m)
    local watch_due = not (c.threat_t and t - c.threat_t < (cfg.threat_scan_s or 2) and t >= c.threat_t)
    local rows = creatures_near(origin, watch_due and math.max(reach_m, cfg.odds_m or 0) or reach_m)
    if watch_due then
        local near = {}
        for _, r in ipairs(rows) do if (r.distance_m or 1e9) <= reach_m then near[#near + 1] = r end end
        rows = near
    end
    local threats = M.pick_threats(rows, c.attackers, c.ally_attackers, M.orders, t, cfg, c.telegraphs)
    c.guard_seen = #threats
    -- what he just ran from (within refled_s) is no new reason to run again while it only stands near: one
    -- bounded flee, not a chain of them (the Rung 1 night: flees dragged him 134-200 m off route); if it
    -- attacks him again he fights it (cornered, below)
    local th
    for _, x in ipairs(threats) do
        local fl = c.fled_from and c.fled_from[x.id]
        if not (fl and t - fl <= (cfg.refled_s or 30) and x.why ~= "attacked_me" and x.why ~= "attacking_me") then th = x; break end
    end
    if not th then
        local okw, werr = pcall(M.threat_watch, pawn, pc, origin, t)
        if not okw then c.threat_err = tostring(werr) end
        return
    end
    -- (a swing near him may be at someone else: passive waits for a hit that lands)
    if M.orders.stance == "passive" and th.why ~= "attacked_me" then return end
    if th.why == "attacked_ally" and M.orders.stance == "passive" then return end
    c.guard_last = { t = os.time(), id = th.id, name = th.name, why = th.why, d = th.distance_m }
    -- it came after him again soon after he ran from it: running again only gives it free hits, so he fights
    local fled = c.fled_from and c.fled_from[th.id]
    local cornered = fled and t - fled <= (cfg.refled_s or 30) and (th.why == "attacked_me" or th.why == "attacking_me")
        and string.format("it came after me again %d s after I ran from it", math.floor(t - fled)) or nil
    say(log, string.format("threat %s (%s) %.1f m pl=%s why=%s%s", th.name, th.id, th.distance_m or -1, tostring(th.pl), th.why,
        cornered and (" cornered=" .. cornered) or ""))
    local r = start_fight(log, th.actor, { mode = "reflex", level = "reflex", why = th.why, cornered = cornered })
    if not r.ok then say(log, "reflex could not start: " .. tostring(r.reason)) end
end
M._guard_tick = guard_tick

-- threat_seen (fight study 2026-11-18): hostiles in sight, out of a fight, that the body's own odds do not rate a
-- likely win, the PACK counted (two deaths came from packs met on one creature's odds; a goblin camp met during an
-- explore reached the model only after he died). One activity when a hostile not reported in threat_repeat_s joins
-- the group; the brain gives the model a turn. Facts only: it never moves, presses or vetoes anything.
-- Reads only the census rows (already read for the reflex), his HP and power level (read_me) and held items' data.
function M.threat_watch(pawn, pc, origin, t)
    local cfg, c = M.cfg, C()
    if c.threat_t and t - c.threat_t < (cfg.threat_scan_s or 2) and t >= c.threat_t then return end
    c.threat_t = t
    local pack = {}
    for _, r in ipairs(creatures_near(origin, cfg.odds_m)) do
        if not r.dead and not r.follower and r.archetype == 0 and not (M.orders.avoid or {})[(r.name or ""):lower()] then
            pack[#pack + 1] = r
        end
    end
    if #pack == 0 then return end
    table.sort(pack, function(a, b) return (a.distance_m or 1e9) < (b.distance_m or 1e9) end)
    c.threat_said = c.threat_said or {}
    local new
    for _, r in ipairs(pack) do
        local s = c.threat_said[r.id]
        if not s or t - s >= (cfg.threat_repeat_s or 60) or t < s then new = true end
    end
    if not new then return end
    local me = read_me(pawn, pc)
    if me.dead or not me.hp then return end
    if not (c.threat_dps and t - c.threat_dps.t < 5 and t >= c.threat_dps.t) then
        local eq = U.try(function() return pawn.PlayerEquipmentComponent end)
        local rk = U.valid(eq) and U.short(U.try(function() return eq:GetHeldEquipmentDataRight() end)) or ""
        local lk = U.valid(eq) and U.short(U.try(function() return eq:GetHeldEquipmentDataLeft() end)) or ""
        local items = M.weapons().items or {}
        local w = items[rk] or items[lk]
        -- what is in his hands, at his real rate (a tool or nothing: bare hands; M.fight_rate)
        c.threat_dps = { t = t, v = M.fight_rate(w and w.role == "weapon" and w or nil) }
    end
    -- the fight he would meet: the nearest hostile and every hostile within aggro range of it
    local near = pack[1]
    local en, group = {}, {}
    for _, r in ipairs(pack) do
        local close = r == near or (r.pos and near.pos and U.dist(r.pos, near.pos) <= cfg.aggro_m * 100)
            or (not (r.pos and near.pos) and math.abs((r.distance_m or 1e9) - (near.distance_m or 0)) <= cfg.aggro_m)
        if close and #en < (cfg.odds_max or 6) then
            local d, src = M.enemy_dps(r.name)
            en[#en + 1] = { name = r.name, hp = r.hp, max_hp = r.max_hp, pl = r.pl, boss = r.boss == true, dps_obs = d, dps_src = src }
            group[#group + 1] = r
        end
    end
    local a = M.assess({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = c.threat_dps.v }, en, { reflexonly = true }, nil, cfg)
    if not (a and a.verdict) or a.verdict == "likely_win" then return end
    for _, r in ipairs(pack) do c.threat_said[r.id] = t end
    M.emit_activity({ kind = "threat_seen", by = "reflex", target = near.name, target_id = near.id,
        distance_m = near.distance_m and math.floor(near.distance_m) or nil, target_pl = near.pl, target_hp = near.hp,
        pack = #pack, hostiles = M.pack_words(pack), fight_pack = #group, fight_hostiles = M.pack_words(group),
        verdict = a.verdict, pl_gap = a.pl_gap, unknown = a.unknown,
        est_s_to_die = a.their_ttk and math.floor(a.their_ttk), est_s_to_kill = a.my_ttk and math.floor(a.my_ttk),
        est_kill = M.band_words(a.kill_lo, a.kill_hi), est_die = M.band_words(a.die_lo, a.die_hi),
        hp = me.hp, max_hp = me.max_hp, aggro_m = cfg.aggro_m })
end

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
        fs = { mode = f.mode, phase = f.phase, boss_hold = f.boss_hold, reach = f.reach, radius_cm = f.target_radius_cm, target = f.target_name, target_id = f.target_id, dist_m = f.dist_m and math.floor(f.dist_m * 10) / 10,
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
             boss = c.boss, statuses = c.statuses,
             ambient = { enabled = M.ambient_enabled(), leases = c.ambient and c.ambient.n_leases, holding = c.ambient and c.ambient.token ~= nil,
                         escaping = c.ambient and c.ambient.escape ~= nil, err = c.ambient_err },
             memory = c.mem and { status = c.mem.status, detail = c.mem.detail, path = c.mem.path, build = c.mem.build, file_build = c.mem.file_build,
                                  saves = c.mem.saves, save_err = c.mem.save_err, imported = c.mem.imported } or nil,
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
        if not r.ok then return { ok = false, reason = "interrupted", data = { detail = r.detail or "pawn busy", owner = r.owner } } end
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
function M._journal_weaknesses(name)
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
    local facts = M.creature_facts(cr.name) or {}
    local wk = { live = read_affinities(actor), learned = facts.learned, journal = facts.journal and facts.journal.list,
                 journal_entry = facts.journal and facts.journal.entry, priors = facts.priors, family = facts.family,
                 merged = facts.affinities }
    local wr = facts.wiki -- the wiki snapshot (labelled; the journal and his own hits outrank it)
    if wr then wk.wiki = { weak = wr.weak, resist = wr.resist, immune = wr.immune, immune_effects = wr.immune_effects,
                           pl = wr.pl, hp = wr.hp, url = wr.url } end
    d.weaknesses = wk
    local mem = M.memory(log, pawn)
    d.history = M.creature_history(cr.name, mem)
    d.boss_attempts = M.boss_attempts(cr.name, mem)
    d.memory = { status = mem.status, detail = mem.detail, build = mem.build, file_build = mem.file_build }
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
    -- the estimate, as information: with what is in his hands, at his real rate (M.fight_rate)
    local held = M.held_weapon(pawn)
    local rate, rate_src = M.fight_rate(held)
    local dps_obs, dps_src = M.enemy_dps(cr.name)
    local a = M.assess_vs({ hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = rate }, { name = cr.name, hp = cr.hp, max_hp = cr.max_hp,
        pl = cr.pl, boss = cr.boss, dps_obs = dps_obs }) or {}
    d.assessment = { verdict = a.verdict, est_s_to_kill = a.my_ttk and math.floor(a.my_ttk), est_s_to_die = a.their_ttk and math.floor(a.their_ttk),
                     est_kill = M.band_words(a.kill_lo, a.kill_hi), est_die = M.band_words(a.die_lo, a.die_hi), unknown = a.unknown,
                     with = held and held.name or "bare hands", my_rate_from = rate_src, damage_from = dps_src,
                     pl_gap = a.pl_gap }
    -- what Claude has learned about this creature's attacks (per attack key)
    local D = mod("defense")
    d.attacks_learned = {}
    for key, r in pairs(D and D.status().attacks or {}) do
        if key:find((cr.name or "?") .. ":", 1, true) == 1 then
            local best_resp, best_mean
            for resp, a in pairs(r.arms or {}) do
                local mean = (1 + a.s) / (2 + a.s + a.f)
                if a.n > 0 and (not best_mean or mean > best_mean) then best_resp, best_mean = resp, mean end
            end
            d.attacks_learned[#d.attacks_learned + 1] = { attack = key, impact_s = r.impact_s, damage = r.damage, lunge_cm = r.lunge_cm,
                parried = r.parried, blocked = r.blocked, hit = r.hit, avoided = r.avoided,
                best_response = best_resp, best_rate = best_mean and math.floor(best_mean * 100) / 100 or nil }
        end
    end
    d.orders = M.orders
    return out
end

-- The weapon profile in his hands (weapons_data; a tool or nothing = nil: bare hands). Property reads and the
-- equipment component's own getters, as state_extras uses them. -> profile | nil
function M.held_weapon(pawn)
    local eq = U.valid(pawn) and U.try(function() return pawn.PlayerEquipmentComponent end)
    if not U.valid(eq) then return nil end
    local rk = U.short(U.try(function() return eq:GetHeldEquipmentDataRight() end)) or ""
    local lk = U.short(U.try(function() return eq:GetHeldEquipmentDataLeft() end)) or ""
    local items = M.weapons().items or {}
    local w = items[rk] or items[lk]
    return w and w.role == "weapon" and w or nil
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
    -- fight odds for the creatures in sight (prep information for the brain: the same estimate combat_brief
    -- gives; never a veto) and his own power level. Pure maths on the census rows already in `data`.
    if not (c.odds and t - c.odds.t < 3) then
        local me = read_me(pawn, pc)
        local items = M.weapons().items or {}
        local w = items[r] or items[l]
        local dps, dps_src = M.fight_rate(w and w.role == "weapon" and w or nil) -- (a tool or nothing in hand: bare hands)
        local odds = M.fight_odds(me, dps, data and data.nearby_entities, { weapon = w and w.role == "weapon" and w.name or "bare hands", from = dps_src })
        -- a fight that is not an easy win: what he knows about the creature, and the odds with what he
        -- OWNS and CAN CAST (information; prep eval 2026-10-26). The inventory / spell / journal reads
        -- happen only then, and at most every odds_prep_s.
        local hard = false
        for _, o in pairs(odds) do if o.verdict ~= "likely_win" then hard = true end end
        -- what each creature in sight resists / is weak to, for every fight (the element of an enchant, a spell or
        -- a staff is his pick per fight: Luis 2026-11-01); the resolver is cached per creature (cfg.facts_s)
        for _, e in ipairs(type(data and data.nearby_entities) == "table" and data.nearby_entities or {}) do
            local o = e.id and odds[e.id]
            if o and not o.known then o.known = M.known_affinities(e.name) end
        end
        if hard then
            if not (c.prep_ctx and t - c.prep_ctx.t < M.cfg.odds_prep_s) then
                c.prep_ctx = { t = t, list = mcall("inventory", "list", nil) or {}, cast = M.castable_prep(),
                               attack = M.skill_level("Attack") }
            end
            for _, e in ipairs(type(data and data.nearby_entities) == "table" and data.nearby_entities or {}) do
                local o = e.id and odds[e.id]
                if o then
                    o.known = M.known_affinities(e.name)
                    local wr = M.wiki_creature(e.name)
                    o.immune_effects = wr and wr.immune_effects or nil
                    if o.verdict ~= "likely_win" then
                        o.prepared = M.prepared_odds(me, e, c.prep_ctx.list, c.prep_ctx.cast, o.known, c.prep_ctx.attack)
                    end
                end
            end
        end
        c.odds = { t = t, pl = me.pl, v = odds }
    end
    local f = c.fight
    local boss = f and f.boss and c.boss and { creature = c.boss.target, phase = c.boss.index, phases = c.boss.phases,
        airborne = c.boss.airborne or nil, transitioning = c.boss.transitioning or nil } or nil
    M.refresh_statuses(pawn, 3)
    local sts
    for name, e in pairs((c.statuses or {}).effects or {}) do
        if e.harmful then sts = sts or {}; sts[name] = e.max and string.format("%g/%g", e.value, e.max) or tostring(e.value) end
    end
    local buffs
    for perk, b in pairs(M.active_buffs()) do buffs = buffs or {}; buffs[perk] = string.format("%d s left (from %s)", b.left_s, tostring(b.from)) end
    if not (c.wl and t - c.wl.t < 5) then
        local okw, wl = pcall(M.weapons_known, mcall("inventory", "list", nil) or {})
        c.wl = { t = t, v = okw and wl or nil }
    end
    local okh, ench = pcall(M.held_enchant, pawn)
    return { held_actions = c.extras.v, power_level = c.odds.pl, fight_odds = c.odds.v, boss_fight = boss,
             status_effects = sts, buffs_remembered = buffs, weapons_known = c.wl.v, held_enchant = okh and ench or nil,
             recent_kills = c.recent_kills }
end

-- What each weapon he owns really does: his own learned hit damage with it (persisted), else the data's base swing;
-- per second at its press cadence; and for a ranged or magic weapon whether its ammo slot holds anything (live
-- 2026-11-01 22:05: he picked the bow over his club on "shoots arrows" alone, learned ~4/hit, no arrows slotted).
-- -> {[name] = {kind, per_hit, per_s, from = "learned" | "data", ammo = n | nil, ammo_slot}}
function M.weapons_known(list)
    local items = M.weapons().items or {}
    local slots, slot_item = {}, {}
    for _, e in ipairs(list.loadout or {}) do
        local sl = tostring(e.loadout_slot or "")
        if sl:find("Ammo", 1, true) or sl:find("Bolts", 1, true) then
            local k = sl:find("MagicAmmo", 1, true) and "MagicAmmo" or sl
            slots[k] = (slots[k] or 0) + (e.count or 0)
            slot_item[k] = slot_item[k] or e
        end
    end
    -- the other arrows / bolts he carries (live 2026-11-02 03:47: he crafted Fang Arrows and shot his 2 Stone ones,
    -- because nothing showed him which arrows were slotted or that better ones were in his bag)
    local function carried_ammo(pat, except)
        local by, order = {}, {}
        for _, where in ipairs({ "hotbar", "bag" }) do
            for _, e in ipairs(list[where] or {}) do
                if e.item and e.item:find(pat) and e.item ~= except then
                    local n = e.name or e.item
                    if not by[n] then by[n] = { name = n, item = e.item, count = 0 }; order[#order + 1] = by[n] end
                    by[n].count = by[n].count + (e.count or 1)
                end
            end
        end
        return #order > 0 and order or nil
    end
    local out, seen = {}, {}
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do
            local p = e.item and items[e.item]
            if p and p.role == "weapon" and not seen[e.item] then
                seen[e.item] = true
                local learned = (C().hit_dmg or {})[p.name or "hands"]
                local dps = M.my_dps(p)
                local row = { kind = p.kind, per_hit = learned and math.floor(learned * 10 + 0.5) / 10 or (p.prim and p.prim.dmg),
                              per_s = dps and math.floor(dps * 10 + 0.5) / 10 or nil, from = learned and "learned" or "data",
                              types = (#(p.types or {}) > 0) and p.types or nil }
                if p.kind == "magic" then row.ammo_slot = "MagicAmmo"
                elseif p.kind == "ranged" then row.ammo_slot = (p.cat == "crossbow") and "CrossbowBolts" or "Ammo" end
                if row.ammo_slot then row.ammo = slots[row.ammo_slot] or 0 end
                if p.kind == "ranged" then
                    local inslot = slot_item[row.ammo_slot]
                    row.ammo_name = inslot and (inslot.name or inslot.item) or nil
                    row.ammo_carried = carried_ammo(p.cat == "crossbow" and "^ITEM_Ammo_Bolts" or "^ITEM_Ammo_Arrows", inslot and inslot.item)
                end
                out[p.name or e.item] = row
            end
        end
    end
    return out
end

-- The enchant on his held weapon (AHeldEquipmentActor.MagicalHeldEquipmentEffectInfo, replicated): the effect,
-- the damage type it adds (the effect's own element word: HEED_EnchantWeaponFire -> DamageType.Magical.Fire) and
-- the seconds left (ServerExpirationTime against the game state's server clock). nil when none.
function M.held_enchant(pawn)
    local eq = U.try(function() return pawn.PlayerEquipmentComponent end)
    local gs = U.find_first and U.find_first("GameStateBase") or U.try(function() return FindFirstOf("GameStateBase") end)
    local now_s = U.valid(gs) and num(U.try(function() return gs:GetServerWorldTimeSeconds() end)) or nil
    for _, side in ipairs({ "HeldEquipmentActorRight", "HeldEquipmentActorLeft" }) do
        local a = eq and U.try(function() return eq[side] end)
        if U.valid(a) then
            for _, f in ipairs({ "MagicalHeldEquipmentEffectInfo", "PhysicalHeldEquipmentEffectInfo" }) do
                local info = U.try(function() return a[f] end)
                local e = info and U.short(U.try(function() return info.EffectData end))
                if e and e ~= "" then
                    local exp = num(U.try(function() return info.ServerExpirationTime end))
                    local el = e:match("EnchantWeapon(%a+)$")
                    return { effect = e, adds = el and ("DamageType.Magical." .. el) or nil,
                             left_s = (exp and now_s and exp > 0) and math.max(0, math.floor(exp - now_s)) or nil }
                end
            end
        end
    end
    return nil
end

-- What he knows about a creature's damage-type affinities, each with its source:
-- learned (his own hits) > journal (the game's journal entry he has) > prior (creature_priors data) >
-- prior:family (a learned creature sharing a name token). -> {tag = {v = weak|resist|immune, src}} or nil
-- ONE creature-knowledge resolver: name -> canonical key -> every fact we hold, each source kept apart, and the
-- merged affinities {tag = {v, src}} in authority order: learned (his own hits) > journal (the game's entry he
-- has) > wiki (snapshot) > prior (creature_priors data) > prior:family (a learned creature sharing a name token).
-- Cached per key for cfg.facts_s (the journal read is a find_all); his learning invalidates it.
function M.creature_facts(name)
    if not name then return nil end
    local c = C()
    local key = tostring(name):lower()
    c.facts = c.facts or {}
    local f = c.facts[key]
    local lv = c.learned_ver or 0
    if f and f.lv == lv and os.time() - f.t < M.cfg.facts_s then return f end
    f = { key = key, t = os.time(), lv = lv, learned = c.learned[key] }
    c.journal_cache = c.journal_cache or {}
    local jc = c.journal_cache[key]
    if jc == nil then
        local okj, jw, jname = pcall(M._journal_weaknesses, name)
        jc = (okj and jw) and { list = jw, entry = jname } or false
        c.journal_cache[key] = jc
    end
    f.journal = jc or nil
    f.wiki = M.wiki_creature(name)
    for k, pr in pairs(M.PRIORS) do if key:find(k, 1, true) then f.priors = pr end end
    if not (f.learned and next(f.learned)) then f.family = M.family_affinity(name) end
    local out, n = {}, 0
    local function put(tag, v, src) if v and v ~= "neutral" and not out[tag] then out[tag] = { v = v, src = src }; n = n + 1 end end
    for tag, v in pairs(f.learned or {}) do put(tag, v, "learned") end
    -- (only damage types: a journal line like "Occasionally lacks confidence" is lore, not an affinity)
    for _, tag in ipairs(jc and jc.list or {}) do
        local nt = M.norm_tag(tag)
        if tostring(nt):find("^DamageType%.") then put(nt, "weak", "journal") end
    end
    local wr = f.wiki
    if wr then
        for _, tag in ipairs(wr.weak or {}) do put(tag, "weak", "wiki") end
        for _, tag in ipairs(wr.resist or {}) do put(tag, "resist", "wiki") end
        for _, tag in ipairs(wr.immune or {}) do put(tag, "immune", "wiki") end
    end
    local pr = f.priors
    if pr then
        for tag in pairs(pr.weak or {}) do put(tag, "weak", "prior") end
        for tag in pairs(pr.resist or {}) do put(tag, "resist", "prior") end
        for tag in pairs(pr.immune or {}) do put(tag, "immune", "prior") end
    end
    for tag, v in pairs(f.family and f.family.verdicts or {}) do put(tag, v, "prior:family") end
    f.affinities = n > 0 and out or nil
    f.immune_effects = wr and wr.immune_effects or nil
    f.inflicts = wr and wr.inflicts or nil
    c.facts[key] = f
    return f
end
function M.known_affinities(name)
    local f = M.creature_facts(name)
    return f and f.affinities or nil
end

-- The wiki snapshot's facts for a creature (client_mod/scripts/creature_wiki.lua, generated by
-- tools/gen_creature_wiki.py): {pl = {...}, hp = {...}, race, weak/resist/immune (tags), immune_effects, url}.
function M.wiki_creature(name)
    local WIKI = M.data("creature_wiki")
    return WIKI and name and WIKI[tostring(name):lower()] or nil
end

-- A skill level from sense.me() (read-only; the game's own SkillComponent read lives there).
function M.skill_level(name)
    local me = mcall("sense", "me")
    local sk = type(me) == "table" and me.skills or nil
    if type(sk) ~= "table" then return nil end
    for k, v in pairs(sk) do
        if type(v) == "table" and (v.skill == name or v.name == name or k == name) then return tonumber(v.level) end
    end
    return nil
end

-- Castable prep spells right now (the spells module's own availability: unlocked, runes, cooldown).
M.ENCHANTS = { ["DamageType.Magical.Fire"] = "USD_EnchantWeapon_Fire", ["DamageType.Magical.Air"] = "USD_EnchantWeapon_Air",
                ["DamageType.Magical.Water"] = "USD_EnchantWeapon_Water" }
local function short_tag(tag) return tostring(tag):match("([^%.]+)$") or tostring(tag) end
M.short_tag = short_tag
-- A journal weakness may be a bare word ("Fire"): the full damage-type tag from the weapon data that ends with it.
function M.norm_tag(x)
    x = tostring(x or "")
    if x:find(".", 1, true) then return x end
    local want = "." .. x:lower()
    for _, p in pairs(M.weapons().items or {}) do
        for _, t in ipairs(p.types or {}) do if t:lower():sub(-#want) == want then return t end end
    end
    for tag in pairs(M.ENCHANTS) do if tag:lower():sub(-#want) == want then return tag end end
    return x
end
function M.castable_prep()
    local sp = mod("spells")
    local out = { enchant = {} }
    if not (sp and sp.ability_status) then return out end
    local function avail(asset) local ok, st = pcall(sp.ability_status, asset); return ok and type(st) == "table" and st.available == true end
    out.tempest = avail("USD_TempestShield")
    for tag, asset in pairs(M.ENCHANTS) do if avail(asset) then out.enchant[tag] = true end end
    return out
end

local AFF_MULT = { weak = 1.5, resist = 0.6, immune = 0.05 }

-- Tempest Shield's shield health (game data GE_TempestShield: 50 + 7.5 x Attack level).
function M.tempest_hp(level) return 50 + 7.5 * (level or 1) end

-- One assess call shape for "this one creature, information only" (fight odds, briefs, estimates).
function M.assess_vs(me_stats, e)
    local en = { name = e.name, hp = tonumber(e.hp or e.health), max_hp = tonumber(e.max_hp or e.max_health),
                 pl = tonumber(e.power_level or e.pl), boss = e.boss == true, dps_obs = e.dps_obs }
    local ok, a = pcall(M.assess, me_stats, { en }, { reflexonly = true }, nil, M.cfg)
    return ok and a or nil
end

-- What his loadout can do against a creature: ONE digest for both odds models.
--   weapon: melee via M.best_weapon/score_weapon (with the KNOWN affinities and their sources); ranged/magic with
--           ONE ammo rule (its ammo kind carried; magic: any rune); the best dps wins
--   shield: M.best_weapon's shield; breath_block from item_traits (data)
--   foods:  every healing food item (ONE heal rule: the entry's heal, else the consumable data's), best first
--   poison_resist: his best carried poison resistance (consumable data)
-- -> {dps, weapon, why, uses = {...}, foods = {h...}, nfood, shield, breath_block, poison_resist, tempest}
function M.loadout_capability(list, cast, enemy, known, attack_level)
    local cfg = M.cfg
    local items = M.weapons().items or {}
    local cap = { uses = {}, foods = {}, nfood = 0, poison_resist = 0 }
    local carried = {}
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, it in ipairs((list or {})[where] or {}) do if it.item then carried[it.item] = (carried[it.item] or 0) + (it.count or 1) end end
    end
    local function has_ammo(p)
        if p.kind == "melee" or not p.ammo or p.ammo == "None" or p.ammo == "Self" then return true end
        for id in pairs(carried) do
            if (p.kind == "magic" and id:find("Rune", 1, true)) or (p.kind ~= "magic" and id:find(tostring(p.ammo):gsub("s$", ""), 1, true)) then return true end
        end
        return false
    end
    -- melee: the existing chooser with the known affinities
    local bw = M.best_weapon(list, enemy or {}, nil, C().learned, known)
    local best, bdps, bwhy = bw.weapon and bw.weapon.profile, bw.weapon and bw.weapon.score, bw.weapon and bw.weapon.why
    -- ranged / magic
    for id in pairs(carried) do
        local p = items[id]
        if p and p.role == "weapon" and (p.kind == "ranged" or p.kind == "magic") and has_ammo(p) then
            local d = M.dps(p) or (p.kind == "magic" and p.mult and p.prim and p.prim.next_ms and (cfg.magic_base_dmg * p.mult) / (p.prim.next_ms / 1000))
            if d and (not bdps or d > bdps) then best, bdps, bwhy = p, d, p.kind == "magic" and "rune damage: estimate" or nil end
        end
    end
    cap.dps, cap.weapon, cap.why = bdps or 12, best, bwhy
    if best then cap.uses[#cap.uses + 1] = best.name .. (bwhy and ((bwhy:find("estimate", 1, true) and " (" or " vs ") .. bwhy .. (bwhy:find("estimate", 1, true) and ")" or "")) or "") end
    if best and best.kind == "melee" and cast and cast.enchant and not bwhy then
        for tag in pairs(cast.enchant) do
            local k = known and known[tag]
            if k and k.v == "weak" then
                cap.dps = cap.dps * AFF_MULT.weak
                cap.uses[#cap.uses + 1] = "Enchant Weapon (" .. short_tag(tag) .. ") vs " .. short_tag(tag):lower() .. "-weak (" .. k.src .. ")"
                break
            end
        end
    end
    if cast and cast.tempest then
        cap.tempest = M.tempest_hp(attack_level)
        cap.uses[#cap.uses + 1] = string.format("Tempest Shield (+%d shield)", math.floor(cap.tempest))
    end
    -- shields: the best block (chooser), and the best breath block (item traits, by display name)
    cap.shield = bw.shield and bw.shield.profile
    local traits = M.data("item_traits") or {}
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, it in ipairs((list or {})[where] or {}) do
            local nm = it.name or ((items[it.item or ""] or {}).name)
            local tr = nm and traits[tostring(nm):lower()]
            if tr and tr.blocks_breath and tr.blocks_breath > (cap.breath_block or 0) then cap.breath_block, cap.breath_shield = tr.blocks_breath, nm end
            local info = M.consumable_info(it.name)
            local h = tonumber(it.heal) or (info and info.heal)
            if it.consumable == "food" and h and h > 0 then
                for _ = 1, (it.count or 1) do cap.foods[#cap.foods + 1] = h end
                cap.nfood = cap.nfood + (it.count or 1)
            end
            local r = info and info.resists and info.resists.Poison
            if r and r > cap.poison_resist then cap.poison_resist = r end
        end
    end
    table.sort(cap.foods, function(a, b) return a > b end)
    return cap
end

-- The boss profile (data): the creature's own, else the default.
function M.boss_profile(name)
    local bp = M.data("boss_profiles") or {}
    return bp[tostring(name or ""):lower()] or bp.default or {}
end

-- A long boss fight, prepared (gap 5; an ESTIMATE, every prior named in the result):
--   time   = his damage window: boss HP / his prepared DPS, split into `windows` melee windows (arena PhaseData count
--            when seen, else the boss profile's) + (windows - 1) flights of the profile's flight_s (no damage dealt);
--   intake = their melee DPS (the assess formula, x (1 - breath_share x breath block) with a breath-blocking shield)
--            + poison DoT (poison_dps x poison_uptime x (1 - his poison resistance), when the creature poisons:
--            wiki text / observed abilities) during windows, + meteor_dps during flights;
--   supply = HP + Tempest Shield + food, eaten at most once per cfg.eat_every_s, every item counted;
--   die_s  = when intake exceeds supply. -> {verdict, kill_s, die_s, windows, flights, dot_hps, uses, priors, not_counted}
function M.boss_prepared(me, e, cap)
    local cfg = M.cfg
    local c = C()
    local bp = M.boss_profile(e.name)
    local windows = (c.boss and c.boss.phases) or bp.windows or 4
    local flights = math.max(0, windows - 1)
    local uses = { table.unpack(cap.uses) }
    local gap = (tonumber(e.power_level or e.pl) or 1) - (me.pl or 1)
    local melee = M.enemy_dps_prior(tonumber(e.power_level or e.pl)) * (1.25 ^ gap)
    local my_dps = math.max(cap.dps * (1.25 ^ (-math.max(gap, 0))), 0.1)
    if cap.breath_block then
        melee = melee * (1 - (bp.breath_share or 0) * cap.breath_block)
        uses[#uses + 1] = tostring(cap.breath_shield) .. " vs breath"
    end
    local wr = M.wiki_creature(e.name)
    local poisons = false
    for _, x in ipairs((wr and wr.inflicts) or {}) do if x == "Poison" then poisons = true end end
    for _, r in pairs(c.ai_actions or {}) do if r.profile and r.profile.status == "Poison" and r.name == e.name then poisons = true end end
    local dot = 0
    if poisons then
        local res = math.min(cap.poison_resist * 2, 99) -- a potion + a Fungal Fortitude food stack (wiki: 66%); at most the best x 2
        dot = (bp.poison_dps or 0) * (bp.poison_uptime or 0) * (1 - res / 100)
        if res > 0 then uses[#uses + 1] = string.format("poison resistance ~%d%%", res) end
    end
    local intake = melee + dot
    local fight_s = (tonumber(e.hp or e.health) or 1000) / my_dps
    local flight_s = bp.flight_s or 20
    local kill_s = fight_s + flights * flight_s
    local hp = (me.hp or 100) + (cap.tempest or 0)
    local die_s, t, eaten, next_eat = nil, 0, 0, 0
    local window_len = fight_s / windows
    local maxhp = me.max_hp or 100
    while t < 7200 do
        t = t + 1
        local cyc = window_len + flight_s
        local k = math.floor(t / cyc)
        local in_flight = k < flights and (t - k * cyc) > window_len
        hp = hp - (in_flight and (bp.meteor_dps or 0) or intake)
        if hp < maxhp * 0.5 and eaten < #cap.foods and t >= next_eat then
            eaten = eaten + 1; hp = math.min(hp + cap.foods[eaten], maxhp + 200); next_eat = t + cfg.eat_every_s
        end
        if hp <= 0 then die_s = t; break end
        if t >= kill_s then break end
    end
    if #cap.foods > 0 then uses[#uses + 1] = string.format("%d food (eaten %d by then)", #cap.foods, eaten) end
    local verdict = "likely_win" -- outlasts the whole fight
    if die_s then
        local ratio = die_s / math.max(kill_s, 1)
        verdict = ratio / (ratio + 1) >= cfg.fight_enter and "likely_win" or "likely_lose"
    end
    return { verdict = verdict, kill_s = math.floor(kill_s),
             die_s = die_s and math.floor(die_s) or nil, survives = die_s == nil or nil, windows = windows, flights = flights,
             dot_hps = dot > 0 and math.floor(dot * 10) / 10 or nil, uses = uses, boss = true,
             priors = { poison_dps = bp.poison_dps, poison_uptime = bp.poison_uptime, flight_s = flight_s, meteor_dps = bp.meteor_dps,
                        breath_share = bp.breath_share, breath_block = cap.breath_block, source = bp.source },
             not_counted = "blocking, dodging (meteors assumed mostly dodged), armour, infusions/potions' damage buffs, a second fighter" }
end

-- The odds with his best preparation from what he owns and can cast (an estimate, labelled as such): the
-- loadout digest (best weapon vs what is KNOWN, a castable enchant it is weak to, Tempest Shield, food). A boss
-- gets the long-fight model. Not counted: blocking/parrying/dodging, his armour, a second fighter.
function M.prepared_odds(me, e, list, cast, known, attack_level)
    local cap = M.loadout_capability(list, cast, e, known, attack_level)
    if e.boss == true then return M.boss_prepared(me, e, cap) end
    local hp = (me.hp or 100) + (cap.tempest or 0)
    local heal = 0
    for _, h in ipairs(cap.foods) do heal = heal + h end
    heal = math.min(heal, 2 * (me.max_hp or 100)) -- a short fight: about two bars of food get eaten
    local uses = { table.unpack(cap.uses) }
    if heal > 0 then hp = hp + heal; uses[#uses + 1] = string.format("%d food (+%d HP)", cap.nfood, math.floor(heal)) end
    -- his real rate with that weapon (its hit / cadence vs the weakness, x the measured uptime; bare hands when none)
    local rate = M.fight_rate(cap.weapon, cap.weapon and cap.dps or nil)
    local row = e
    if e.dps_obs == nil then
        local d = M.enemy_dps(e.name)
        if d then row = {}; for k, v in pairs(e) do row[k] = v end; row.dps_obs = d end
    end
    local a = M.assess_vs({ hp = hp, max_hp = hp, pl = me.pl, dps = rate }, row)
    if not a then return nil end
    -- the times decide here (the PL-gap label "too_strong" would hide what the preparation changes)
    local verdict = a.verdict
    if verdict == "too_strong" then
        verdict = (a.unknown and "unknown") or (a.kill_hi < a.die_lo and "likely_win") or (a.kill_lo > a.die_hi and "likely_lose") or "uncertain"
    end
    return { verdict = verdict, kill_s = a.my_ttk and math.floor(a.my_ttk), die_s = a.their_ttk and math.floor(a.their_ttk), uses = uses,
             est_kill = M.band_words(a.kill_lo, a.kill_hi), est_die = M.band_words(a.die_lo, a.die_hi), unknown = a.unknown,
             not_counted = "blocking, dodging, armour, a second fighter" }
end

-- A census row is hostile: the game's Aggressive archetype (sense: "Aggressive"; combat's read_creature: 0) or attitude.
local function row_hostile(e)
    return e.hostile == true or e.archetype == "Aggressive" or e.archetype == 0
end

-- Metres between two census rows (positions in metres, [x, y, z] or {X, Y, Z}). -> m | nil
local function row_dist(a, b)
    local p, q = a.position, b.position
    if type(p) ~= "table" or type(q) ~= "table" then return nil end
    local ax, ay, az = tonumber(p[1] or p.X or p.x), tonumber(p[2] or p.Y or p.y), tonumber(p[3] or p.Z or p.z) or 0
    local bx, by, bz = tonumber(q[1] or q.X or q.x), tonumber(q[2] or q.Y or q.y), tonumber(q[3] or q.Z or q.z) or 0
    if not (ax and ay and bx and by) then return nil end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end

-- {id -> {verdict, kill_s, die_s, kill/die bands, pack, hostiles, unknown, pl_gap, ...}} for up to cfg.odds_max living,
-- non-follower creatures within cfg.odds_m. `dps` = his real rate with what he holds (M.fight_rate); `held` =
-- {weapon, from} said back. Fighting one means fighting every hostile within aggro range of it too (cfg.aggro_m;
-- fight study 2026-11-18: packs met on one creature's odds killed him twice), so each row's odds count that pack.
function M.fight_odds(me, dps, entities, held)
    local out, n = {}, 0
    local list, all = {}, {}
    for _, e in ipairs(type(entities) == "table" and entities or {}) do
        local d = tonumber(e.distance_m or e.distance)
        if type(e) == "table" and e.id and e.alive ~= false and not e.follower then
            all[#all + 1] = e
            if not d or d <= M.cfg.odds_m then list[#list + 1] = e end
        end
    end
    table.sort(list, function(a, b) return (tonumber(a.distance_m or a.distance) or 1e9) < (tonumber(b.distance_m or b.distance) or 1e9) end)
    local function with_dps(e) -- the reflex's own estimate of its damage rate (the same numbers decide fight or flight)
        if e.dps_obs ~= nil then return e end
        local d, src = M.enemy_dps(e.name)
        if not d then return e end
        local row = {}
        for k, v in pairs(e) do row[k] = v end
        row.dps_obs, row.dps_src = d, src
        return row
    end
    local function en(e)
        local r = with_dps(e)
        return { name = r.name, hp = tonumber(r.hp or r.health), max_hp = tonumber(r.max_hp or r.max_health),
                 pl = tonumber(r.power_level or r.pl), boss = r.boss == true, dps_obs = r.dps_obs }
    end
    for _, e in ipairs(list) do
        if n >= M.cfg.odds_max then break end
        local foes, group = { en(e) }, { e }
        for _, o in ipairs(all) do
            local dm = o ~= e and row_hostile(o) and row_dist(e, o)
            if dm and dm <= M.cfg.aggro_m and #foes < M.cfg.odds_max then foes[#foes + 1] = en(o); group[#group + 1] = o end
        end
        local ok, a = pcall(M.assess, { hp = me.hp, max_hp = me.max_hp, pl = me.pl, dps = dps }, foes, { reflexonly = true }, nil, M.cfg)
        if ok and a and a.verdict then
            n = n + 1
            local src = with_dps(e).dps_src
            out[e.id] = { verdict = a.verdict, kill_s = a.my_ttk and math.floor(a.my_ttk), die_s = a.their_ttk and math.floor(a.their_ttk),
                          kill_lo = math.floor(a.kill_lo), kill_hi = math.floor(a.kill_hi + 0.5),
                          die_lo = math.floor(a.die_lo), die_hi = math.floor(a.die_hi + 0.5),
                          est_kill = M.band_words(a.kill_lo, a.kill_hi), est_die = M.band_words(a.die_lo, a.die_hi),
                          pack = #foes > 1 and #foes or nil, hostiles = #foes > 1 and M.pack_words(group) or nil,
                          unknown = a.unknown, damage_from = src, weapon = held and held.weapon or nil,
                          weapon_from = held and held.from or nil, pl_gap = a.pl_gap }
        end
    end
    return out
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
            description = "Fight a creature until it dies, defending per combat_orders (never players). data.assessment estimates the fight. "
                .. "The kill trains the skill of the weapon you hold (melee: Attack, bows: Ranged, staffs: Magic; `weapon` picks it, default best melee).",
            args = { type = "object", required = { "target" }, properties = obj({
                target = { type = "string", description = "Creature id, or a name (nearest)." },
                weapon = { type = "string", description = "Carried item to fight with (e.g. a crossbow), or held = what is in hand now; default best melee." },
                style = STYLE,
                force = { type = "boolean", default = false, description = "Ignore flee_hp for this fight." } }) },
            ground = obj({ target = "creature" }),
            reasons = { "unknown_target", "too_far", "path_blocked", "interrupted", "timeout", "not_unlocked", "invalid_args", "not_enough_resources", "companion_down", "body_error", "missed" } },
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
