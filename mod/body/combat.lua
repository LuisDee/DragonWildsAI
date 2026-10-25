-- Melee combat reflex layer for the attack skill (body/skills.lua h_attack). Game-tick speed, no LLM
-- (design docs/design/robustness-and-item-catalog.md sections 3 and 5).
--
-- * Weapon profile: the HELD item's primary combo chain and its special, from the generated table
--   body/attack_data.lua (tools/gen_attack_data.py <- data/items_<build>.json). Unknown items fall
--   back to their category's set, then to the verified Sword set.
-- * Combo state machine (pure, unit-tested): step through the chain in order. Step k+1 is issued
--   at step k's next_ms (end of its AttackInputWindow, after its damage point); after the finisher
--   wait its reset_ms (AttackResetChain) and start over; any gap longer than the last step's
--   reset_ms (e.g. chasing the target) also restarts the chain at step 1.
-- * Special (the weapon's SpecialActionClass): only between combos (chain at step 1), when our
--   cooldown is over, the target is a good candidate (not about to die from a normal swing), and
--   the puppet's special charge covers the cost (SpecialChargeComponent:GetSpecialCharge(), read
--   2026-10-25 on the live puppet: 100/100; unreadable -> cooldown only).
-- * Behaviour tree: beehive.lua (vendored, MIT, body/vendor/beehive). Leaves return only
--   'success' (this branch took the tick) or 'failure' (pass), never 'running', so the root
--   selector re-evaluates every priority on every tick (reactive):
--     end_checks > hook on_tick > hook evade > approach > recovering > ineffective
--       > special (sequence: wanted, swing) > combo swing
-- * Extension points for spells/evade (body/spells.lua plugs in without editing this loop):
--     combat.add_hook(kind, name, fn); kinds:
--       on_tick(ctx)            truthy -> it acted this tick (the swing is skipped)
--       evade(ctx)              truthy -> evading this tick; ctx.threat holds the last telegraph
--       before_swing(ctx, sw)   "skip" -> no swing this tick; a table {atk=, act=, label=} replaces it
--       after_swing(ctx, sw, ok)
--     combat.notify_threat(info) records a telegraph (e.g. from a DominionAiAttackComponent hook).
--     ctx = {a, p, t, hp, d, now, profile, combo, threat, perform = function(atk, act, label)}
-- The only native combat call is BP_PerformAttack through M.perform (verified with the Sword set;
-- other sets UNVERIFIED in game). The direct-damage path (PredictDamage/ApplyDamage...) is never
-- used: it crashed the server in UE4SS struct marshalling.
local U = require("body.util")
local gear = require("body.gear")
local selector = require("body.vendor.beehive.selector")
local sequence = require("body.vendor.beehive.sequence")
local null = require("jsonutil").null

local M = {}

M.CHAIN = "full"                  -- "full" (NextAttackClass) or "short" (no MeleeExtendCombo perk)
M.SPECIAL_COOLDOWN_MS = 8000      -- our own minimum gap between specials
M.SPECIAL_ENABLED = true
M.SPECIAL_OPENER_HP_FACTOR = 3    -- before the first full combo, only on targets with hp >= 3x a swing
M.WEAPON_RECHECK_MS = 2000        -- re-read the held item (only at chain step 1) this often
M.FALLBACK_NEXT_MS = 1250         -- the old verified cadence, for a set without timing
M.FALLBACK_RESET_MS = 2500
M.DEFAULT_SET = "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.PA_Attack_Sword_C"
-- Last resort when attack_data.lua is missing: the verified Sword step 1 (DISCOVERIES "Combat (E3)").
M.LEGACY = {
    name = "Attack", cdo = "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.Default__PA_Attack_Sword_C",
    steps = { { cls = "/Game/Gameplay/Character/Player/Attacks/Sword/BP_Player_Sword_Attack1.BP_Player_Sword_Attack1_C",
                next_ms = 1250, reset_ms = 2500 } },
}

local okd, DATA = pcall(require, "body.attack_data")
if not okd or type(DATA) ~= "table" then DATA = nil end

function M.data() return DATA end
function M.set_data(d) DATA = d end -- tests / hot swap

-- ------------------------------------------------------------------ weapon profile
local function lookup_set(key)
    if not key then return nil end
    if DATA and DATA.sets and DATA.sets[key] then return DATA.sets[key] end
    if key == M.DEFAULT_SET and not DATA then return M.LEGACY end
    return nil
end

-- Pure: item data path (gear.read(p).right, nil when unarmed) -> profile
-- {item, primary_key, primary, special_key, special, source = item|category|default}.
function M.profile_for(item_path)
    local items = DATA and DATA.items or {}
    local it = item_path and items[item_path]
    local src, pk, sk = "item", it and it.primary, it and it.special
    if not pk then
        local cat = item_path and gear.category(item_path)
        pk = cat and DATA and DATA.categories and DATA.categories[cat:lower()]
        src = "category"
    end
    if not lookup_set(pk) then pk, sk, src = M.DEFAULT_SET, nil, "default" end
    local prim = lookup_set(pk)
    local steps = prim and ((M.CHAIN == "short" and prim.short) or prim.steps) or {}
    return { item = item_path, primary_key = pk, primary = prim, steps = steps,
             special_key = sk, special = lookup_set(sk), source = src }
end

-- Live objects for a set's steps: StaticFindObject only (never loads). The chain is cut at the
-- first step whose class is not loaded. Returns {act=CDO, steps={{obj, cls, next_ms, ...}}} or nil.
local resolved = {}
function M.resolve(set, steps)
    if not set then return nil end
    steps = steps or set.steps
    local key = set.cdo .. "|" .. tostring(#steps) .. "|" .. tostring(steps[#steps] and steps[#steps].cls)
    local r = resolved[key]
    if r and U.valid(r.act) and r.steps[1] and U.valid(r.steps[1].obj) then return r end
    local act = U.try(StaticFindObject, set.cdo)
    if not U.valid(act) then return nil end
    r = { act = act, name = set.name, steps = {} }
    for _, st in ipairs(steps) do
        local o = U.try(StaticFindObject, st.cls)
        if not U.valid(o) then break end
        r.steps[#r.steps + 1] = {
            obj = o, cls = st.cls, damage = st.damage, special_cost = st.special_cost,
            next_ms = st.next_ms or M.FALLBACK_NEXT_MS, reset_ms = st.reset_ms or M.FALLBACK_RESET_MS,
        }
    end
    if #r.steps == 0 then return nil end
    resolved[key] = r
    return r
end

-- ------------------------------------------------------------------ combo state machine (pure)
-- steps: array of {next_ms, reset_ms, ...}. The state never touches the game.
function M.new_combo(steps)
    return { steps = steps or {}, i = 1, last_at = nil, reset_ms = nil, ready_at = 0, combos = 0, count = 0 }
end

function M.combo_reset(st)
    st.i, st.last_at, st.reset_ms = 1, nil, nil
end

-- The step to swing next at `now` (applies the gap reset first). Returns step, index.
function M.combo_peek(st, now)
    if st.last_at and st.reset_ms and now - st.last_at >= st.reset_ms then M.combo_reset(st) end
    if st.i > #st.steps then st.i = 1 end
    return st.steps[st.i], st.i
end

function M.combo_ready(st, now) return now >= (st.ready_at or 0) end

-- Record that the current step was swung at `now`. Returns the time the next swing is due.
function M.combo_advance(st, now)
    local step = st.steps[st.i]
    if not step then return now end
    st.count = st.count + 1
    st.last_at, st.reset_ms = now, step.reset_ms or M.FALLBACK_RESET_MS
    if st.i >= #st.steps then
        -- finisher: let the game's chain reset (AttackResetChain), then start over at step 1
        st.ready_at = now + (step.reset_ms or M.FALLBACK_RESET_MS)
        st.i = 1
        st.combos = st.combos + 1
    else
        st.ready_at = now + (step.next_ms or M.FALLBACK_NEXT_MS)
        st.i = st.i + 1
    end
    return st.ready_at
end

-- ------------------------------------------------------------------ hooks
M.HOOK_KINDS = { on_tick = true, evade = true, before_swing = true, after_swing = true }
M.hooks = { on_tick = {}, evade = {}, before_swing = {}, after_swing = {} }

-- Register (or replace, by name) a hook. Returns a function that removes it.
function M.add_hook(kind, name, fn)
    assert(M.HOOK_KINDS[kind], "unknown combat hook kind: " .. tostring(kind))
    assert(type(name) == "string" and type(fn) == "function", "add_hook(kind, name, fn)")
    local list = M.hooks[kind]
    for i = #list, 1, -1 do if list[i].name == name then table.remove(list, i) end end
    list[#list + 1] = { name = name, fn = fn }
    return function() M.remove_hook(kind, name) end
end

function M.remove_hook(kind, name)
    local list = M.hooks[kind] or {}
    for i = #list, 1, -1 do if list[i].name == name then table.remove(list, i) end end
end

-- First truthy hook result wins. A failing hook is logged and skipped (never breaks the fight).
local function run_hooks(kind, ctx, ...)
    for _, h in ipairs(M.hooks[kind]) do
        local ok, r = pcall(h.fn, ctx, ...)
        if not ok then
            if ctx.log then ctx.log("combat_hook_error", { kind = kind, name = h.name, err = tostring(r) }) end
        elseif r then
            return r, h.name
        end
    end
    return nil
end
M._run_hooks = run_hooks

M.threat = nil
-- Record an enemy telegraph for the evade hook: info = {by=<actor>, ms_until=<number>, ...}.
function M.notify_threat(info, now)
    if type(info) == "table" then info.at = now; M.threat = info end
end

-- ------------------------------------------------------------------ native wrappers
-- The verified swing: PlayerMeleeAttackComponent:BP_PerformAttack(attackClass, FPlayerActionInstance
-- {Data=<PA_* CDO>, PlayerOwner=puppet, EquipmentHand=1 (Right), ActionInputType=0, DesiredActionTarget}).
function M.perform(log_mod, p, atk, act, target, crumb)
    return U.call(log_mod, "BP_PerformAttack", crumb, function()
        p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, {
            Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = target,
        })
    end)
end

-- Special charge of the puppet (no-arg getter; verified readable 2026-10-25). nil when unreadable.
function M.special_charge(p)
    local sc = U.try(function() return p.SpecialChargeComponent end)
    if not U.valid(sc) then return nil end
    local v = U.try(function() return sc:GetSpecialCharge() end)
    return type(v) == "number" and v or nil
end

-- ------------------------------------------------------------------ the attack behaviour tree
-- deps (from skills.lua): {cfg = skills constants, now(), puppet(), finish(a, ok, reason, data),
-- approach(a, p, t) (throttled MoveToActor), log_mod, log(name, data)}.
local S_, F_ = "success", "failure"

local function result_data(a, extra)
    local prof = a.profile
    local d = { target = a.target_id, swings = a.swings, specials = a.specials, combos = a.combo and a.combo.combos or 0,
                weapon = prof and prof.item and prof.item:match("([%w_]+)$") or null,
                attack_set = prof and prof.primary_key and prof.primary_key:match("([%w_]+)$") or null }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
M._result_data = result_data

-- Utility check for the special (one function, so a scorer can replace it later).
-- Returns ok, why. Rules: special set loaded; our cooldown over; between combos (chain at step 1);
-- the target is not about to die from a normal swing; before the first finished combo only on a
-- sturdy target (hp >= SPECIAL_OPENER_HP_FACTOR x step-1 damage); charge >= cost when readable.
function M.special_candidate(a, now)
    if not (M.SPECIAL_ENABLED and a.spec and a.spec.steps[1]) then return false, "no_special" end
    if now < (a.special_ready_at or 0) then return false, "cooldown" end
    if a.combo.i ~= 1 then return false, "mid_combo" end
    local hp = a.ctx.hp
    local first = a.prim.steps[1].damage
    if hp ~= nil and first then
        if hp <= first then return false, "target_low" end
        if a.combo.combos == 0 and hp < first * M.SPECIAL_OPENER_HP_FACTOR then return false, "opener_target_low" end
    end
    local cost = a.spec.steps[1].special_cost
    local charge = M.special_charge(a.ctx.p)
    a.last_charge = charge
    if cost and charge and charge < cost then return false, "no_charge" end
    return true
end

-- (Re)load the weapon profile from what the puppet holds. Keeps the combo state when unchanged.
local function load_weapon(a, p, deps)
    a.weapon_checked_at = deps.now()
    local held = gear.read(p).right
    if a.profile and a.profile.item == held and a.prim then return end
    local prof = M.profile_for(held)
    local prim = M.resolve(prof.primary, prof.steps)
    if not prim and prof.primary_key ~= M.DEFAULT_SET then
        prof = M.profile_for(nil) -- the held weapon's set is not loaded: fall back to the Sword set
        prim = M.resolve(prof.primary, prof.steps)
    end
    a.profile, a.prim = prof, prim
    a.spec = prof.special and M.resolve(prof.special) or nil
    a.combo = M.new_combo(prim and prim.steps or {})
    deps.log("attack_weapon", { item = held, set = prof.primary_key, source = prof.source,
                                steps = prim and #prim.steps or 0, special = prof.special_key })
end

function M.attack_tree(deps)
    local cfg = deps.cfg

    local function ctx_of(a)
        local c = a.ctx
        c.now, c.combo, c.threat, c.profile = deps.now(), a.combo, M.threat, a.profile
        return c
    end

    -- 1. termination rules (unchanged contract): companion down, target gone/dead, timeout, leash.
    local function end_checks(a)
        local now = deps.now()
        local p = deps.puppet()
        if not p then deps.finish(a, false, "companion_down", {}); return S_ end
        local t = a.target
        if not U.valid(t) then
            deps.finish(a, true, nil, result_data(a, { killed = (a.last_hp ~= nil and a.last_hp <= 0) or null, gone = true }))
            return S_
        end
        local hp = U.health(t)
        if hp ~= nil then
            a.first_hp = a.first_hp or hp
            a.last_hp = hp
            if hp <= 0 then deps.finish(a, true, nil, result_data(a, { killed = true })); return S_ end
        end
        if now - a.started >= cfg.ATTACK_TIMEOUT_MS then
            deps.finish(a, false, "timeout", result_data(a, { hp = hp or null })); return S_
        end
        local d = U.actor_dist(p, t)
        if d > cfg.ATTACK_LEASH_CM then
            deps.finish(a, false, "too_far", result_data(a, { distance = U.cm_to_m(d) })); return S_
        end
        a.ctx = a.ctx or { a = a, log = deps.log }
        local c = a.ctx
        c.p, c.t, c.hp, c.d = p, t, hp, d
        c.perform = function(atk, act, label)
            return M.perform(deps.log_mod, p, atk, act, t, { target = a.target_id, label = label })
        end
        if not a.profile or (a.combo.i == 1 and now - (a.weapon_checked_at or -math.huge) >= M.WEAPON_RECHECK_MS) then
            load_weapon(a, p, deps)
        end
        if not a.prim then deps.finish(a, false, "body_error", result_data(a, { detail = "attack set not loaded" })); return S_ end
        return F_
    end

    local function hook_leaf(kind)
        return function(a)
            local r = run_hooks(kind, ctx_of(a))
            return r and S_ or F_
        end
    end

    local function approach(a)
        local c = a.ctx
        if c.d <= cfg.ATTACK_RANGE_CM then return F_ end
        deps.approach(a, c.p, c.t)
        return S_
    end

    local function recovering(a)
        return (deps.now() < (a.ready_at or 0)) and S_ or F_
    end

    local function ineffective(a)
        local hp = a.ctx.hp
        if a.swings >= cfg.ATTACK_INEFFECTIVE_SWINGS and hp ~= nil and a.first_hp ~= nil and hp >= a.first_hp then
            deps.finish(a, false, "verification_failed",
                result_data(a, { detail = "no damage after " .. a.swings .. " swings", hp = hp }))
            return S_
        end
        return F_
    end

    -- One swing through before_swing / perform / after_swing. Returns ok (false: vetoed or error).
    local function do_swing(a, sw)
        local ctx = ctx_of(a)
        local r = run_hooks("before_swing", ctx, sw)
        if r == "skip" then return false, "skipped" end
        if type(r) == "table" and r.atk and r.act then sw = r end
        local ok, err = M.perform(deps.log_mod, ctx.p, sw.atk, sw.act, ctx.t,
            { target = a.target_id, set = sw.set, step = sw.step, n = a.swings + 1, label = sw.label })
        run_hooks("after_swing", ctx, sw, ok)
        if ok then
            a.swings = a.swings + 1
        else
            a.errors = a.errors + 1
            a.ready_at = deps.now() + M.FALLBACK_NEXT_MS
            if a.errors >= cfg.ATTACK_MAX_ERRORS then
                deps.finish(a, false, "body_error", result_data(a, { detail = tostring(err) }))
            end
        end
        return ok
    end

    local function special_wanted(a) return M.special_candidate(a, deps.now()) and S_ or F_ end

    local function swing_special(a)
        local now = deps.now()
        local st = a.spec.steps[1]
        local ok = do_swing(a, { atk = st.obj, act = a.spec.act, set = a.spec.name, step = "special",
                                 label = "special", charge = a.last_charge })
        if a.done then return S_ end
        if ok then
            a.specials = a.specials + 1
            a.special_ready_at = now + math.max(M.SPECIAL_COOLDOWN_MS, st.reset_ms or 0)
            M.combo_reset(a.combo)
            a.ready_at = now + (st.next_ms or M.FALLBACK_NEXT_MS)
        else
            a.special_ready_at = now + M.SPECIAL_COOLDOWN_MS -- vetoed or failed: do not retry at once
        end
        return S_
    end

    local function swing_combo(a)
        local now = deps.now()
        local step, i = M.combo_peek(a.combo, now)
        if not step then return F_ end
        local ok = do_swing(a, { atk = step.obj, act = a.prim.act, set = a.prim.name, step = i,
                                 cls = step.cls:match("([%w_]+)$") })
        if a.done then return S_ end
        if ok then a.ready_at = M.combo_advance(a.combo, now) end
        return S_
    end

    return selector({
        end_checks,
        hook_leaf("on_tick"),
        hook_leaf("evade"),
        approach,
        recovering,
        ineffective,
        sequence({ special_wanted, swing_special }),
        swing_combo,
    })
end

function M._reset()
    resolved = {}
    M.threat = nil
    for k in pairs(M.hooks) do M.hooks[k] = {} end
end

return M
