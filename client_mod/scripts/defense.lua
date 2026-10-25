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
local D = {}

D.cfg = {
    parry_window_s = 0.10,  -- PlayerBlockingComponent.ParryWindowLength (100, ms) on Claude's client
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

-- Plan the answer to one telegraph.
--   info = {key, dmg_time, unblockable, unparryable, shape = shape_info, ...}
--   ctx  = {dist_cm, latency_s (one way), stamina, can_parry, can_block, parry_cost, block_cost, evade_cost,
--           hp_frac, heal_hp}
--   orders = {defense = auto|parry|block|dodge|none, allow_jump}
-- -> {action = parry|block|dodge|jump|retreat|none, at_s (after the telegraph), hold_s, impact_s, why, src}
function D.plan(info, ctx, orders, rng)
    rng = rng or rnd
    orders = orders or {}
    info = info or {}
    local cfg = D.cfg
    S().counts.plans = S().counts.plans + 1
    local key = info.key or "?"
    local T, src = D.impact_delay(key, info)
    local L = clamp(ctx.latency_s or 0.03, 0, 0.25)
    local react = cfg.react_s[1] + rng() * (cfg.react_s[2] - cfg.react_s[1])
    local err = (rng() * 2 - 1) * cfg.jitter_s
    local p = { impact_s = T, src = src, key = key }
    local style = orders.defense or "auto"
    if style == "none" then p.action, p.why = "none", "orders"; return p end
    local reach = (info.shape and info.shape.reach_cm) or cfg.default_reach_cm
    if ctx.dist_cm and ctx.dist_cm > reach + cfg.reach_margin_cm then p.action, p.why = "none", "out_of_reach"; return p end
    local st = ctx.stamina or 0
    local blockable = not info.unblockable
    local parryable = blockable and not info.unparryable
    local low_or_aoe = info.shape and (info.shape.low or info.shape.aoe)
    local can_jump = orders.allow_jump ~= false and low_or_aoe
    local can_dodge = st >= (ctx.evade_cost or 15)
    local can_parry = ctx.can_parry and parryable and st >= (ctx.parry_cost or 10)
    local can_block = ctx.can_block and blockable and st >= (ctx.block_cost or 10)
    local low_hp = ctx.hp_frac and ctx.heal_hp and ctx.hp_frac < ctx.heal_hp
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
    if pick == "parry" then
        local at = T - 2 * L - cfg.parry_window_s / 2 + off + err
        if at < react then
            -- too fast to time a parry from the telegraph: a human would just raise the block
            pick, p.why = can_block and "block" or (can_dodge and "dodge" or "retreat"), "too_fast_to_parry"
        else
            p.at_s, p.hold_s = at, math.max(cfg.min_block_s, T - at + cfg.block_tail_s)
        end
    end
    if pick == "block" then
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

-- Outcome of a planned defence: parried | blocked | hit | avoided | whiff. Adapts the parry offset.
function D.feedback(key, action, outcome)
    local r = rec(key)
    local s = S()
    if r[outcome] then r[outcome] = r[outcome] + 1 end
    if s.counts[outcome] then s.counts[outcome] = s.counts[outcome] + 1 end
    if action == "parry" then
        if outcome == "blocked" then r.offset = clamp(r.offset + D.cfg.late_step_s, -D.cfg.max_offset_s, D.cfg.max_offset_s)
        elseif outcome == "hit" then r.offset = clamp(r.offset - D.cfg.early_step_s, -D.cfg.max_offset_s, D.cfg.max_offset_s) end
    elseif action == "dodge" and outcome == "hit" then
        r.dodge_hits = (r.dodge_hits or 0) + 1
    end
    r.last = { action = action, outcome = outcome, t = os.time() }
end

function D.status()
    local s = S()
    return { counts = s.counts, attacks = s.attacks }
end

return D
