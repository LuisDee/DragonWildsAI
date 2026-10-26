-- defense: how Claude answers an enemy attack (route R2, client side), used by combat.lua.
-- parry (a block timed into the parry window just before impact), block (hold), dodge (directional
-- evade timed so its i-frames cover the impact), jump (out of low / area attacks), or retreat.
-- Nothing is per enemy: the timing comes from the attack's own data (UAiAttackData.Damage[].Time,
-- GetDamageTime(), AttackPropertyFlags Unblockable/Unparryable, the damage Shape) read when the
-- attack starts on Claude's client, and is then LEARNED per attack from what actually happened
-- (the observed time from the telegraph to the impact, and parried / blocked / hit outcomes).
-- The model sets the policy through combat.lua's standing orders (orders.defense, allow_jump,
-- heal_hp ...); this module executes it with human-like reaction delays and small timing errors.
--
-- Prior art (search-before-building, DISCOVERIES "Client combat (R2)"): parry = a defensive input
-- active inside a few-frame window before the hit; input lag shrinks the window
-- (bugnet.io/blog/bug-reporting-for-games-with-parry-and-block-timing); lag compensation splits the
-- one-way latency off the wind-up (gamedev.net/forums/topic/634003). Nothing found for bots that
-- learn parry timing; decision: build a small per-attack estimator (EMA of observed impact times +
-- an outcome-driven offset).
--
-- Timing model (client clock): the telegraph (AI attack multicast) reaches us one-way latency L
-- after the server starts the attack; the server resolves the hit T after its start. A press must
-- REACH the server inside [T - window, T], so it is sent at  t_tel + T - 2L - window/2 + offset.
-- T is observed directly as (damage/block event time - telegraph time): both arrive L late, so their
-- difference is the server's T.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local D = {}

D.cfg = {
    parry_window_s = 0.10,  -- PlayerBlockingComponent.ParryWindowLength (100, ms) on Claude's client
    block_delay_s = 0.11,   -- server "AuthorityApplyBlocking: BlockDelay [0.117]" for a remote player (dev log)
    react_s = { 0.15, 0.30 }, -- human reaction delay to the telegraph
    jitter_s = 0.025,       -- timing error of a human press
    block_tail_s = 0.40,    -- keep a block up this long past the expected impact
    min_block_s = 0.75,     -- PlayerBlockingComponent.MinimumBlockDuration
    evade_lead_s = 0.20,    -- start the dodge this long before the impact (i-frames cover it)
    jump_lead_s = 0.25,
    prior_impact_s = 0.60,  -- when neither the attack data nor observations say
    ema = 0.35,
    late_step_s = 0.02,     -- a plain block where a parry was wanted = pressed too early -> later next time
    early_step_s = 0.03,    -- got hit = pressed too late -> earlier next time
    max_offset_s = 0.20,
    reach_margin_cm = 120,
    default_reach_cm = 400,
    low_top_cm = 60,        -- a shape whose top is below this (above the attacker's feet) is a low sweep
    lunge_cm = 150,         -- a learned approach this long during an attack makes it a "lunge"
    danger_frac = 0.3,      -- an attack expected to take this share of max HP is fully dangerous
    unknown_danger = 0.3,
    prior_strength = 4,     -- pseudo-observations behind the rule prior
    prior_rule = 0.75, prior_alt = 0.5, prior_fit = 0.6, prior_misfit = 0.3,
    danger_bonus = 0.3,     -- a fitting ability's prior grows by this x danger
    precast_danger = 0.5,   -- pre-cast only against attacks at least this dangerous (learned damage)
    prior_pre_needed = 0.8, -- pre-cast prior when reacting is too slow for the attack
    prior_pre_alt = 0.45,   -- ... and when reacting would also fit in time
    precast_min_score = 0.3,
    ability_cost = 0.35,    -- runes/cooldown cost, scaled by (1 - danger)
    ability_latency_s = 0.6, -- spell cast latency until measured (the spells module reports it)
    ability_margin_s = 0.15,
}

local function S()
    _G.DWDefense = _G.DWDefense or { attacks = {}, counts = { plans = 0, parried = 0, blocked = 0, hit = 0, avoided = 0, whiff = 0 } }
    return _G.DWDefense
end
D._state = S
local rnd = math.random
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end

-- Classify a damage shape {class, radius, depth, zheight, top_angle, extent={x,y,z}, offset_z, half_height}
-- (UDominionShape_{Sphere,Wedge,Box,Capsule,Arc}). -> {kind, reach_cm, low, aoe}
function D.shape_info(sh, attacker_half_height_cm)
    if type(sh) ~= "table" then return { kind = "unknown" } end
    local cls = (sh.class or ""):lower()
    local kind = cls:find("sphere") and "sphere" or cls:find("wedge") and "wedge" or cls:find("box") and "box"
        or cls:find("capsule") and "capsule" or cls:find("arc") and "arc" or "unknown"
    local oz = sh.offset_z or 0
    local reach, top, aoe
    if kind == "sphere" then
        reach = (sh.radius or 0) + math.abs(sh.offset_x or 0)
        top = oz + (sh.radius or 0)
        aoe = (sh.offset_x or 0) == 0 and (sh.radius or 0) >= 200
    elseif kind == "wedge" or kind == "arc" then
        reach = (sh.depth or sh.radius or 0) + (sh.offset_x or 0)
        top = oz + (sh.zheight or 0) / 2
        aoe = (sh.top_angle or 0) >= 180
    elseif kind == "box" then
        local e = sh.extent or {}
        reach = (e.x or 0) + (sh.offset_x or 0)
        top = oz + (e.z or 0)
    elseif kind == "capsule" then
        reach = (sh.radius or 0) + (sh.half_height or 0) + (sh.offset_x or 0)
        top = oz + (sh.half_height or 0)
    end
    local hh = attacker_half_height_cm or 90
    local low = top ~= nil and (top + hh) < D.cfg.low_top_cm -- shapes are relative to the capsule centre
    return { kind = kind, reach_cm = (reach and reach > 0) and reach or nil, low = low or nil, aoe = aoe or nil, top_cm = top }
end

-- Learned record for one attack key.
local function rec(key)
    local s = S()
    local r = s.attacks[key]
    if not r then r = { n = 0, offset = 0, parried = 0, blocked = 0, hit = 0, avoided = 0, whiff = 0 }; s.attacks[key] = r end
    return r
end
D.rec = rec

-- Expected server-side time from the attack start to the impact, seconds.
function D.impact_delay(key, info)
    local r = S().attacks[key]
    if r and r.n > 0 and r.impact_s then return r.impact_s, "learned" end
    if info and info.dmg_time and info.dmg_time > 0 then return info.dmg_time, "attack_data" end
    return D.cfg.prior_impact_s, "prior"
end

-- ------------------------------------------------------------------ the threat (data + learned)
-- What this attack will do, from its data and from what it did before (all per attack key, never per
-- creature): impact time, reach incl. learned lunge, expected damage, flags.
function D.threat(info, max_hp)
    local key = info.key or "?"
    local r = S().attacks[key] or {}
    local reach = (info.shape and info.shape.reach_cm) or D.cfg.default_reach_cm
    local lunge = r.lunge_cm or 0
    -- a hit taken from farther away than that ("none, out_of_reach" and still hit: live 08:17, a Kebbit
    -- chasing Claude's retreat) is direct evidence of the reach
    local th = { key = key, reach_cm = math.max(reach + lunge, r.hit_from_cm or 0), lunge_cm = lunge, damage = r.damage, unblockable = info.unblockable,
                 unparryable = info.unparryable, low = info.shape and info.shape.low, aoe = info.shape and info.shape.aoe }
    local frac = (th.damage and max_hp and max_hp > 0) and th.damage / max_hp or nil
    th.danger = frac and math.min(1, frac / D.cfg.danger_frac) or D.cfg.unknown_danger
    th.tags = {}
    if th.unblockable then th.tags.unblockable = true end
    if th.unparryable then th.tags.unparryable = true end
    if th.low then th.tags.low = true end
    if th.aoe then th.tags.aoe = true end
    if lunge >= D.cfg.lunge_cm then th.tags.lunge = true end
    th.tags.melee = true
    return th
end

-- ------------------------------------------------------------------ learning which answer works (bandit)
-- Thompson sampling over Beta posteriors per (attack key, response), with a prior from the rules.
-- Reward: avoided / parried = 1, blocked = 0.75, hit = scaled by the damage taken, whiff = no update.
-- (UCB1 can lock onto an early winner; Thompson keeps exploring in proportion to doubt, which suits a
-- small, changing action set: research record in docs/design/defense-abilities.md.)
local function probit(u) -- inverse normal CDF approximation (Tukey lambda); probit(0.5) = 0
    u = clamp(u, 1e-6, 1 - 1e-6)
    return 4.91 * (u ^ 0.14 - (1 - u) ^ 0.14)
end

local function arm(key, resp)
    local r = rec(key)
    r.arms = r.arms or {}
    local a = r.arms[resp]
    if not a then a = { s = 0, f = 0, n = 0 }; r.arms[resp] = a end
    return a
end
D.arm = arm

-- Beta(alpha, beta) sample from one uniform (normal approximation, clamped).
local function beta_sample(alpha, beta, u)
    local m = alpha / (alpha + beta)
    local sd = math.sqrt(alpha * beta / ((alpha + beta) ^ 2 * (alpha + beta + 1)))
    return clamp(m + probit(u) * sd, 0, 1)
end
D.beta_sample = beta_sample

-- ------------------------------------------------------------------ choosing the answer
-- Plan the answer to one telegraph.
--   info = {key, dmg_time, unblockable, unparryable, shape = shape_info, ...}
--   ctx  = {dist_cm, latency_s (one way), stamina, can_parry, can_block, parry_cost, block_cost, evade_cost,
--           hp_frac, max_hp, heal_hp,
--           abilities = {phase_dash = {available, latency_s, why}, windstep = {...}, tempest_shield = {...}}}
--   orders = {defense = auto|parry|block|dodge|none, allow_jump, abilities = {name = false to forbid}}
-- -> {action = parry|block|dodge|jump|phase_dash|windstep|tempest_shield|retreat|none, at_s, hold_s,
--     cast_at_s (abilities), evade_at_s (phase dash), impact_s, why, src, dir, candidates, threat}
function D.plan(info, ctx, orders, rng)
    rng = rng or rnd
    orders = orders or {}
    info = info or {}
    ctx = ctx or {}
    local cfg = D.cfg
    S().counts.plans = S().counts.plans + 1
    local key = info.key or "?"
    local T, src = D.impact_delay(key, info)
    local L = clamp(ctx.latency_s or 0.03, 0, 0.25)
    local react = cfg.react_s[1] + rng() * (cfg.react_s[2] - cfg.react_s[1])
    local err = (rng() * 2 - 1) * cfg.jitter_s
    local th = D.threat(info, ctx.max_hp)
    local p = { impact_s = T, src = src, key = key, threat = th, dist_cm = ctx.dist_cm }
    local style = orders.defense or "auto"
    if style == "none" then p.action, p.why = "none", "orders"; return p end
    if ctx.dist_cm and ctx.dist_cm > th.reach_cm + cfg.reach_margin_cm then p.action, p.why = "none", "out_of_reach"; return p end
    local st = ctx.stamina or 0
    local blockable = not info.unblockable
    local parryable = blockable and not info.unparryable
    local can_jump = orders.allow_jump ~= false and (th.low or th.aoe)
    local can_dodge = st >= (ctx.evade_cost or 15)
    local can_parry = ctx.can_parry and parryable and st >= (ctx.parry_cost or 10)
    local can_block = ctx.can_block and blockable and st >= (ctx.block_cost or 10)
    local low_hp = ctx.hp_frac and ctx.heal_hp and ctx.hp_frac < ctx.heal_hp
    -- 1. the rule choice (also the prior)
    local pick
    if style == "parry" then pick = can_parry and "parry" or can_block and "block" or can_dodge and "dodge"
    elseif style == "block" then pick = can_block and "block" or can_dodge and "dodge"
    elseif style == "dodge" then pick = can_dodge and "dodge" or can_block and "block"
    else -- auto
        if not blockable then pick = (can_jump and "jump") or (can_dodge and "dodge")
        elseif can_parry and not low_hp then pick = "parry"
        elseif low_hp and can_dodge then pick = "dodge"
        elseif can_block then pick = "block"
        elseif can_jump then pick = "jump"
        elseif can_dodge then pick = "dodge" end
    end
    if not pick and can_jump then pick = "jump" end
    pick = pick or "retreat"
    local r = S().attacks[key]
    local off = r and r.offset or 0
    -- a parry the telegraph leaves no time for becomes a block (a human would just raise the shield)
    local parry_at = T - 2 * L - cfg.block_delay_s - cfg.parry_window_s / 2 + off + err
    if pick == "parry" and parry_at < react then
        pick, p.why = can_block and "block" or (can_dodge and "dodge" or "retreat"), "too_fast_to_parry"
    end
    -- 2. candidates: the plain answers that are possible now, plus abilities that are available and fit
    --    in the time the telegraph leaves (style "auto" only: an explicit style is the model's order)
    local cands = { [pick] = cfg.prior_rule }
    if style == "auto" then
        if can_parry and parry_at >= react then cands.parry = cands.parry or cfg.prior_alt end
        if can_block then cands.block = cands.block or cfg.prior_alt end
        if can_dodge then cands.dodge = cands.dodge or cfg.prior_alt end
        if can_jump then cands.jump = cands.jump or cfg.prior_alt end
        local AB = D.abilities()
        for name, ab in pairs(ctx.abilities or {}) do
            local def = AB[name]
            local allowed = not (orders.abilities and orders.abilities[name] == false)
            if def and allowed and ab.available then
                local lead = (ab.latency_s or cfg.ability_latency_s) + (def.then_input == "evade" and cfg.evade_lead_s or cfg.ability_margin_s)
                if T - L - lead >= react then
                    -- prior: higher when the ability is made for this kind of attack
                    local fit = false
                    for _, tag in ipairs(def.avoids or {}) do if th.tags[tag] then fit = true end end
                    -- a fitting ability is worth more the more dangerous the attack (learned damage)
                    cands[name] = fit and math.min(0.95, cfg.prior_fit + cfg.danger_bonus * th.danger) or cfg.prior_misfit
                end
            end
        end
    end
    -- 2b. an ability cast AHEAD is still active: use its follow-up (dash in the window, block under the shield)
    -- (active = {name = {from, to}} seconds from now: up now, or a cast in progress that will be)
    for name, win in pairs(ctx.active or {}) do
        local def = D.abilities()[name]
        if type(win) == "number" then win = { from = 0, to = win } end
        if def and def.then_input and win and win.to > 0 then
            local need = def.then_input == "evade" and (T - L - cfg.evade_lead_s) or math.max(0, T - L - 0.1)
            if need >= win.from and need <= win.to then
                cands[name .. "_pre"] = math.min(0.95, cfg.prior_fit + cfg.danger_bonus * th.danger)
            end
        end
    end
    -- 3. Thompson sampling with a cost: runes / cooldowns are worth spending on dangerous attacks only
    -- no outcome seen for this attack yet: act on the priors (what a sensible player does first);
    -- once there is evidence, sample (explore in proportion to doubt)
    local tried = 0
    for _, a in pairs((r and r.arms) or {}) do tried = tried + a.n end
    local best, best_score
    p.candidates = {}
    for resp, prior in pairs(cands) do
        local a = arm(key, resp)
        local alpha = 1 + cfg.prior_strength * prior + a.s
        local beta = 1 + cfg.prior_strength * (1 - prior) + a.f
        local sample = tried > 0 and beta_sample(alpha, beta, rng()) or alpha / (alpha + beta)
        local cost = 0
        if D.abilities()[resp] then cost = cfg.ability_cost * (1 - th.danger) end -- "_pre" answers are already paid
        local score = sample - cost
        p.candidates[#p.candidates + 1] = { action = resp, score = math.floor(score * 1000) / 1000, n = a.n }
        if not best_score or score > best_score + 1e-9 or (math.abs(score - best_score) <= 1e-9 and resp == pick) then
            best, best_score = resp, score
        end
    end
    table.sort(p.candidates, function(x, y) return x.score > y.score end)
    if best ~= pick then p.why = p.why or "learned" end
    pick = best
    -- 4. timing of the chosen answer
    if pick == "parry" then
        p.at_s, p.hold_s = parry_at, math.max(cfg.min_block_s, T - parry_at + cfg.block_tail_s)
    elseif pick == "block" then
        p.at_s = react
        p.hold_s = math.max(cfg.min_block_s, T - react + cfg.block_tail_s)
    elseif pick == "dodge" then
        p.at_s = math.max(react, T - L - cfg.evade_lead_s + err)
        p.hold_s = 0.35
        p.dir = (rng() < 0.5) and "left" or "right"
    elseif pick == "jump" then
        p.at_s = math.max(react, T - L - cfg.jump_lead_s + err)
        p.hold_s = 0.25
    elseif pick == "retreat" then
        p.at_s, p.hold_s = react, 0.8
    elseif pick:sub(-4) == "_pre" then
        -- the ability is already up: only its follow-up input
        local def = D.abilities()[pick:sub(1, -5)] or {}
        if def.then_input == "evade" then
            p.input = "dodge"
            p.at_s = math.max(react, T - L - cfg.evade_lead_s + err)
            p.hold_s = 0.35
            p.dir = (rng() < 0.5) and "left" or "right"
        else
            p.input = "block"
            p.at_s = react
            p.hold_s = math.max(cfg.min_block_s, T - react + cfg.block_tail_s)
        end
    else -- an ability: cast early enough that it is active at the impact
        local ab = (ctx.abilities or {})[pick] or {}
        local def = D.abilities()[pick] or {}
        local lat = ab.latency_s or cfg.ability_latency_s
        if def.then_input == "evade" then
            p.evade_at_s = math.max(react + lat, T - L - cfg.evade_lead_s + err)
            p.cast_at_s = math.max(react, p.evade_at_s - lat)
            p.dir = (rng() < 0.5) and "left" or "right"
            p.at_s, p.hold_s = p.cast_at_s, 0.35
        elseif def.then_input == "block" then
            p.cast_at_s = react
            p.at_s = react + lat
            p.hold_s = math.max(cfg.min_block_s, T - p.at_s + cfg.block_tail_s)
        else
            p.cast_at_s = math.max(react, T - L - lat - cfg.ability_margin_s + err)
            p.at_s, p.hold_s = p.cast_at_s, 0.3
        end
        p.spell_asset = def.spell_asset
    end
    p.action = pick
    p.why = p.why or (style == "auto" and (not blockable and "unblockable" or low_hp and "low_hp" or "auto") or style)
    return p
end

-- An impact was observed (damage on Claude, or the game's blocked / parried notify) `dt` seconds
-- after the telegraph: update the attack's impact-time estimate.
function D.observe(key, dt)
    if not key or not dt or dt <= 0 or dt > 5 then return end
    local r = rec(key)
    r.n = r.n + 1
    r.impact_s = r.impact_s and (r.impact_s + D.cfg.ema * (dt - r.impact_s)) or dt
    r.last_dt = dt
end

-- How far the attacker travelled between its telegraph and the impact (a lunge), and the damage it did.
function D.observe_lunge(key, cm)
    if not key or not cm or cm < 0 or cm > 3000 then return end
    local r = rec(key)
    r.lunge_cm = r.lunge_cm and (r.lunge_cm + D.cfg.ema * (cm - r.lunge_cm)) or cm
end
function D.observe_damage(key, amount)
    if not key or not amount or amount <= 0 then return end
    local r = rec(key)
    r.damage = r.damage and math.max(r.damage * 0.8, r.damage + D.cfg.ema * (amount - r.damage)) or amount
end

-- Outcome of a planned defence: parried | blocked | hit | avoided | whiff. Adapts the parry offset
-- and the bandit arm of the chosen response. damage = what Claude took (for the hit reward).
function D.feedback(key, action, outcome, damage, dist_cm)
    local r = rec(key)
    if outcome == "hit" and dist_cm and dist_cm > 0 and dist_cm < 3000 then r.hit_from_cm = math.max(r.hit_from_cm or 0, dist_cm) end
    local s = S()
    if r[outcome] then r[outcome] = r[outcome] + 1 end
    if s.counts[outcome] then s.counts[outcome] = s.counts[outcome] + 1 end
    if action == "parry" then
        if outcome == "blocked" then r.offset = clamp(r.offset + D.cfg.late_step_s, -D.cfg.max_offset_s, D.cfg.max_offset_s)
        elseif outcome == "hit" then r.offset = clamp(r.offset - D.cfg.early_step_s, -D.cfg.max_offset_s, D.cfg.max_offset_s) end
    elseif action == "dodge" and outcome == "hit" then
        r.dodge_hits = (r.dodge_hits or 0) + 1
    end
    if damage and damage > 0 then D.observe_damage(key, damage) end
    if outcome ~= "whiff" and action and action ~= "none" then
        local reward = (outcome == "parried" or outcome == "avoided") and 1 or (outcome == "blocked" and 0.75) or 0
        if outcome == "hit" and damage and r.damage and r.damage > 0 then reward = clamp(0.3 * (1 - damage / r.damage), 0, 0.3) end
        local a = arm(key, action)
        a.s, a.f, a.n = a.s + reward, a.f + (1 - reward), a.n + 1
    end
    r.last = { action = action, outcome = outcome, t = os.time() }
end

-- ------------------------------------------------------------------ pre-casting (ahead of the telegraph)
-- Casting a defensive spell takes 0.7-2 s through the real spell inputs (measured live), often more
-- than an attack's wind-up. So an ability can also be cast AHEAD: Tempest Shield when a fight against
-- a known-dangerous attacker is on, Phase Dash shortly before the next attack is expected (its 2 s
-- dash window then covers the impact). Whether pre-casting or reacting works better is learned per
-- attack like any other answer (arms "<ability>_pre" vs "<ability>").

-- Attack rhythm per creature: intervals between its telegraphs (EMA).
function D.observe_cadence(creature, t)
    if not creature or not t then return end
    local s = S()
    s.cadence = s.cadence or {}
    local c = s.cadence[creature]
    if not c then s.cadence[creature] = { last_t = t, n = 0 }; return end
    local dt = t - c.last_t
    if dt > 0.3 and dt < 15 then
        c.interval = c.interval and (c.interval + D.cfg.ema * (dt - c.interval)) or dt
        c.n = c.n + 1
    end
    c.last_t = t
end

-- Seconds until the creature's next attack is expected (nil when its rhythm is unknown).
function D.next_attack_eta(creature, t)
    local c = (S().cadence or {})[creature]
    if not (c and c.interval and c.n >= 2) then return nil end
    local eta = c.last_t + c.interval - t
    while eta < -0.5 do eta = eta + c.interval end -- missed one: the next in the rhythm
    return eta, c.interval
end

-- The creature's most dangerous known attack (largest learned damage).
function D.most_dangerous(creature)
    local best, br
    local pre = tostring(creature) .. ":"
    for key, r in pairs(S().attacks) do
        if key:sub(1, #pre) == pre and r.damage and (not br or r.damage > br.damage) then best, br = key, r end
    end
    return best, br
end

-- Should an ability be cast now, ahead of the next attack?
--   ctx = {max_hp, stamina, latency_s, abilities = {name = {available, latency_s}}, active = {name = remaining_s}}
-- -> {ability, spell_asset, key, cast_now = bool, cast_in_s, why} | nil, why
function D.precast_decision(creature, t, ctx, orders, rng)
    rng = rng or rnd
    orders = orders or {}
    if (orders.defense or "auto") ~= "auto" then return nil, "orders" end
    local key, r = D.most_dangerous(creature)
    if not key then return nil, "no_known_danger" end
    local th = D.threat({ key = key }, ctx.max_hp)
    if th.danger < D.cfg.precast_danger then return nil, "not_dangerous" end
    local T = D.impact_delay(key, {})
    local L = clamp(ctx.latency_s or 0.03, 0, 0.25)
    local react = (D.cfg.react_s[1] + D.cfg.react_s[2]) / 2
    local best, best_score
    for name, def in pairs(D.abilities()) do
        local ab = (ctx.abilities or {})[name]
        local allowed = not (orders.abilities and orders.abilities[name] == false)
        -- already up (or being cast) and covering the next expected impact: nothing to do
        local act = (ctx.active or {})[name]
        if type(act) == "number" then act = { from = 0, to = act } end
        local covered = false
        if act then
            local eta = def.window_s and D.next_attack_eta(creature, t)
            covered = (not def.window_s) or (eta ~= nil and act.to >= eta + T) or act.pending == true
        end
        if def.precast and allowed and ab and ab.available and not covered then
            local lat = ab.latency_s or D.cfg.ability_latency_s
            local fit = false
            for _, tag in ipairs(def.avoids or {}) do if th.tags[tag] then fit = true end end
            -- reacting is possible only if the wind-up covers reaction + cast + lead
            local lead = def.then_input == "evade" and D.cfg.evade_lead_s or D.cfg.ability_margin_s
            local reactive_ok = T - L - lead - lat >= react
            local prior_pre = fit and (reactive_ok and D.cfg.prior_pre_alt or D.cfg.prior_pre_needed) or D.cfg.prior_misfit
            local pre = arm(key, name .. "_pre")
            local reac = arm(key, name)
            local function score(a, prior)
                local alpha = 1 + D.cfg.prior_strength * prior + a.s
                local beta = 1 + D.cfg.prior_strength * (1 - prior) + a.f
                return (a.n > 0 or pre.n + reac.n > 0) and beta_sample(alpha, beta, rng()) or alpha / (alpha + beta)
            end
            local s_pre = score(pre, prior_pre) - D.cfg.ability_cost * (1 - th.danger)
            local s_reac = reactive_ok and score(reac, fit and math.min(0.95, D.cfg.prior_fit + D.cfg.danger_bonus * th.danger) or D.cfg.prior_misfit) or -1
            if s_pre > s_reac and s_pre > D.cfg.precast_min_score and (not best_score or s_pre > best_score) then
                local d = { ability = name, spell_asset = def.spell_asset, key = key, latency_s = lat, score = s_pre }
                if def.window_s then
                    -- a short window: time the cast so the window covers the next expected impact
                    local eta = D.next_attack_eta(creature, t)
                    if not eta then d = nil
                    else
                        local impact_in = eta + T
                        d.cast_in_s = impact_in - lat - def.window_s / 2
                        d.cast_now = d.cast_in_s <= 0 and impact_in >= lat -- the window still reaches the impact
                        d.why = string.format("next attack in %.1fs, cast %.2fs, window %.1fs", eta, lat, def.window_s)
                    end
                else
                    d.cast_in_s, d.cast_now = 0, true
                    d.why = "dangerous attacker"
                end
                if d then best, best_score = d, s_pre end
            end
        end
    end
    if not best then return nil, "reactive_preferred" end
    return best
end

-- The defensive abilities table (data file client_mod/scripts/defense_abilities.lua).
local AB
function D.abilities()
    if not AB then
        local ok, d = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/defense_abilities.lua"))() end)
        AB = ok and type(d) == "table" and d or {}
    end
    return AB
end
function D.set_abilities(t) AB = t end

function D.status()
    local s = S()
    return { counts = s.counts, attacks = s.attacks }
end

return D
