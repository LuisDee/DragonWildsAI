-- Reflex rules: Luis's standing orders ("Claude, every time the kalphite raises its claws, windstep
-- away") as data the body runs at tick speed, with no LLM in the loop (design
-- docs/design/robustness-and-item-catalog.md section 10; CLAUDE.md principle 1).
--
-- A rule = {id, enemy, trigger, actions, cooldown_s, note}:
--   enemy    enemy class key it applies to, matched case-insensitively as a substring of the enemy's
--            kind ("kalphite" matches kalphiteworker/kalphitesoldier); "*" = any enemy.
--            Rules are stored and persisted PER ENEMY CLASS (bot state key `reflex_rules`).
--   trigger  only what the body can sense (M.TRIGGERS); anything else is refused with `cant_sense`:
--     telegraph {attack?, near_m=8}  a nearby enemy of that class STARTS an attack (edge: once per
--                                    attack). Sensor: polls AiAttackComponent.CurrentAttack.AttackData
--                                    (nil -> set). The "AUTH ATTACK : TELEGRAPH" server log line is
--                                    native (no reflected source in the dump), so this is the earliest
--                                    reflected signal: attack start, ~1.3 s before the damage point
--                                    (Kebbit log, 2026-10-25). `attack` filters by the attack data name.
--     enemy_hp_below {value=%}       the current target's HP below value % of its max
--     cluster_at_least {value=n}     n or more live enemies within the stomp radius of the target
--     own_hp_below {value=%}         the companion's own HP below value %
--     luis_hp_below {value=%}        Luis's (first connected player's) HP below value %
--     enemy_stunned {}               the target stumbles or is knocked down (spells.is_target_stunned)
--     spell_ready {spell}            that spell is castable now (cooldown over, runes, unlocked)
--   actions  1-3 of (M.ACTIONS), run in order when the trigger fires:
--     cast {spell, target=self|enemy|cluster}   through body/spells.lua (its gates: verified route,
--                                    cooldown, Luis's unlocks, runes, player safety distance)
--     evade {distance_m=4}           step away from the enemy (MoveToLocation; the game's own dodge,
--                                    PlayerEvadeComponent, has no reflected start function)
--     switch_weapon {item}           equip a held item the bot OWNS (inventory store count > 0; no
--                                    store -> refused), via body/gear.lua
--     retreat {duration_s=4}         run to Luis (MoveToActor) and hold there for duration_s
--     focus_target {}                make the triggering enemy the attack's target
--   cooldown_s  minimum gap between two firings of the rule (default 3 s)
-- Level triggers (HP, cluster, stunned, spell_ready) fire whenever true, limited by cooldown_s.
--
-- Runs inside body/combat.lua's behaviour tree as the FIRST on_tick hook (before spells' utility
-- reflexes, so Luis's orders win): M.install(combat). Rules therefore act while the companion
-- fights (the attack skill), not while it only follows.
-- Bridge handlers: set_reflex_rule, list_rules, clear_rule (M.register).
--
-- UNVERIFIED in game: the attack-state poll (CurrentAttack.AttackData being set on the server while
-- an AI attacks), the evade/retreat moves during a fight, focus switching, switch_weapon mid-fight.
-- Verified elsewhere: MoveToLocation/MoveToActor (skills), gear.equip right hand, U.health reads.
local U = require("body.util")

local M = {}

M.MAX_RULES_PER_ENEMY = 8
M.MAX_RULES = 32
M.MAX_ACTIONS = 3
M.DEFAULT_COOLDOWN_S = 3
M.TELEGRAPH_NEAR_M = 8
M.SENSE_CM = 1500             -- telegraph sensor scan radius around the companion
M.THREAT_FRESH_MS = 1500      -- a telegraph event is "now" for this long
M.EVADE_M = 4
M.EVADE_BUSY_MS = 900         -- keep the BT from re-approaching while stepping away
M.RETREAT_S = 4
M.RETREAT_ACCEPT_CM = 250
M.CLUSTER_RADIUS_CM = 700     -- Wind Stomp radius (spells catalog)
M.STATE_KEY = "reflex_rules"

M.TRIGGERS = {
    telegraph = { params = { attack = "string", near_m = "number" } },
    enemy_hp_below = { value = "pct" },
    cluster_at_least = { value = "count" },
    own_hp_below = { value = "pct" },
    luis_hp_below = { value = "pct" },
    enemy_stunned = {},
    spell_ready = { spell = true },
}
M.TRIGGER_ORDER = { "telegraph", "enemy_hp_below", "cluster_at_least", "own_hp_below", "luis_hp_below",
                    "enemy_stunned", "spell_ready" }
M.ACTIONS = {
    cast = { spell = true, targets = { self = true, enemy = true, cluster = true } },
    evade = {}, switch_weapon = { item = true }, retreat = {}, focus_target = {},
}
M.ACTION_ORDER = { "cast", "evade", "switch_weapon", "retreat", "focus_target" }

local S = {
    log = nil, bridge = nil, store = nil, spells = nil, gear = nil, inventory = nil, combat = nil,
    rules = { v = 1, next_id = 1, by_enemy = {} }, last_fired = {}, attacking = {}, events = {},
}

local function log(name, data) if S.log then pcall(S.log.event, name, data) end end
local function result(ok, reason, data) return { ok = ok, reason = reason, data = data or {} } end
local function object(t)
    local okj, j = pcall(require, "jsonutil")
    return okj and j.object(t or {}) or (t or {})
end

-- ------------------------------------------------------------------ helpers
function M.kind_of(name)
    local k = (name or ""):gsub("^BP_AI_", ""):gsub("_Character_C.*$", ""):gsub("_C_%d+$", "")
    return k:lower()
end

function M.enemy_key(s)
    if type(s) ~= "string" then return nil end
    local k = s:lower():gsub("[^%w%*]", "")
    if k == "" or k == "any" or k == "all" or k == "anyenemy" then k = "*" end
    -- plural to singular for the obvious cases ("kalphites" -> "kalphite")
    if k ~= "*" and #k > 3 and k:sub(-1) == "s" and k:sub(-2) ~= "ss" then k = k:sub(1, -2) end
    return k
end

function M.scope_matches(key, kind)
    if key == "*" then return true end
    return type(kind) == "string" and kind:find(key, 1, true) ~= nil
end

local function hp_pct(a)
    local hp, max = U.health(a), U.max_health(a)
    if type(hp) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return 100 * hp / max
end

local function enemies_near(origin, radius_cm)
    local out = {}
    if not origin then return out end
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        if U.try(function() return ai:IsFollower() end) ~= true and (U.health(ai) or 1) > 0 then
            local at = U.loc(ai)
            local d = at and U.dist(origin, at)
            if d and d <= radius_cm then out[#out + 1] = { ai = ai, at = at, d = d, id = U.short(ai) } end
        end
    end
    return out
end
M._enemies_near = enemies_near

-- ------------------------------------------------------------------ validation (pure)
local function num(v) return type(v) == "number" and v == v and v or nil end

-- -> rule table, nil | nil, reason, data
function M.validate(spec)
    if type(spec) ~= "table" then return nil, "invalid_args", { detail = "rule must be an object" } end
    local enemy = M.enemy_key(spec.enemy == nil and "*" or spec.enemy)
    if not enemy then return nil, "invalid_args", { detail = "enemy must be a class name or '*'" } end
    local tr = spec.trigger
    if type(tr) == "string" then tr = { kind = tr } end
    if type(tr) ~= "table" or type(tr.kind) ~= "string" then
        return nil, "invalid_args", { detail = "trigger.kind is required", sensable = M.TRIGGER_ORDER }
    end
    local tdef = M.TRIGGERS[tr.kind]
    if not tdef then
        return nil, "cant_sense", { trigger = tr.kind, sensable = M.TRIGGER_ORDER,
                                    detail = "the body cannot sense '" .. tr.kind .. "'" }
    end
    local trigger = { kind = tr.kind }
    if tdef.value then
        local v = num(tr.value)
        if not v then return nil, "invalid_args", { detail = tr.kind .. " needs a numeric value" } end
        if tdef.value == "pct" and (v <= 0 or v > 100) then return nil, "invalid_args", { detail = "value is a percentage 1-100" } end
        if tdef.value == "count" and (v < 1 or v > 20) then return nil, "invalid_args", { detail = "value is an enemy count 1-20" } end
        trigger.value = v
    end
    if tdef.spell then
        if type(tr.spell) ~= "string" or tr.spell == "" then return nil, "invalid_args", { detail = "spell_ready needs a spell" } end
        local asset = (not S.spells) and tr.spell or S.spells.resolve(tr.spell)
        if not asset then return nil, "invalid_args", { detail = "unknown spell " .. tr.spell } end
        trigger.spell = asset
    end
    if tr.kind == "telegraph" then
        if type(tr.attack) == "string" and tr.attack ~= "" then trigger.attack = tr.attack end
        local near = num(tr.near_m)
        trigger.near_m = (near and near > 0 and near <= 15) and near or M.TELEGRAPH_NEAR_M
    end
    local acts = spec.actions
    if acts == nil and spec.action ~= nil then acts = { spec.action } end
    if type(acts) ~= "table" or #acts == 0 then return nil, "invalid_args", { detail = "at least one action is required" } end
    if #acts > M.MAX_ACTIONS then return nil, "invalid_args", { detail = "at most " .. M.MAX_ACTIONS .. " actions" } end
    local actions = {}
    for i, a in ipairs(acts) do
        if type(a) == "string" then a = { kind = a } end
        if type(a) ~= "table" or type(a.kind) ~= "string" then return nil, "invalid_args", { detail = "action " .. i .. " needs a kind" } end
        local adef = M.ACTIONS[a.kind]
        if not adef then
            return nil, "not_implemented", { action = a.kind, actions = M.ACTION_ORDER,
                                              detail = "the body cannot do '" .. a.kind .. "' as a reflex" }
        end
        local out = { kind = a.kind }
        if adef.spell then
            if type(a.spell) ~= "string" or a.spell == "" then return nil, "invalid_args", { detail = "cast needs a spell" } end
            -- without the spells service (not loaded), keep the name as given rather than drop the rule
            local asset = (not S.spells) and a.spell or S.spells.resolve(a.spell)
            if not asset then return nil, "invalid_args", { detail = "unknown spell " .. a.spell } end
            out.spell = asset
            local t = a.target
            if t ~= nil and not adef.targets[t] then return nil, "invalid_args", { detail = "cast target must be self, enemy or cluster" } end
            out.target = t
        end
        if adef.item then
            if type(a.item) ~= "string" or a.item == "" then return nil, "invalid_args", { detail = "switch_weapon needs an item" } end
            out.item = a.item
        end
        if a.kind == "evade" then
            local d = num(a.distance_m)
            out.distance_m = (d and d >= 1 and d <= 10) and d or M.EVADE_M
        elseif a.kind == "retreat" then
            local d = num(a.duration_s)
            out.duration_s = (d and d >= 1 and d <= 30) and d or M.RETREAT_S
        end
        actions[#actions + 1] = out
    end
    local cd = num(spec.cooldown_s)
    local rule = {
        enemy = enemy, trigger = trigger, actions = actions,
        cooldown_s = (cd and cd >= 0.5 and cd <= 600) and cd or M.DEFAULT_COOLDOWN_S,
        note = type(spec.note) == "string" and spec.note:sub(1, 200) or nil,
    }
    return rule
end

-- Things worth telling Luis about a valid rule (its spell can't be cast right now, no inventory...).
function M.warnings(rule)
    local w = {}
    for _, a in ipairs(rule.actions) do
        if a.kind == "cast" and S.spells then
            local ok, reason, data = S.spells.can_cast(a.spell)
            if not ok and reason ~= "on_cooldown" then
                w[#w + 1] = { action = "cast", spell = a.spell, reason = reason, detail = data and data.detail }
            end
        elseif a.kind == "switch_weapon" and not (S.inventory and type(S.inventory.count) == "function") then
            w[#w + 1] = { action = "switch_weapon", reason = "state_unavailable", detail = "no bot inventory store yet" }
        end
    end
    if rule.trigger.kind == "spell_ready" and S.spells then
        local ok, reason = S.spells.can_cast(rule.trigger.spell)
        if not ok and reason ~= "on_cooldown" then w[#w + 1] = { trigger = "spell_ready", spell = rule.trigger.spell, reason = reason } end
    end
    return w
end

-- ------------------------------------------------------------------ store (per enemy class)
local function same_trigger(a, b)
    return a.kind == b.kind and a.value == b.value and a.attack == b.attack and a.spell == b.spell
end

local function count_all()
    local n = 0
    for _, list in pairs(S.rules.by_enemy) do n = n + #list end
    return n
end

local function persist()
    if not (S.store and S.store.save) then return false end
    local by = object({})
    for k, list in pairs(S.rules.by_enemy) do if #list > 0 then by[k] = list end end
    local ok, saved = pcall(S.store.save, { v = 1, next_id = S.rules.next_id, by_enemy = by })
    if not ok then log("rules_persist_error", { err = tostring(saved) }) end
    return ok and saved ~= false
end

function M.load()
    if not (S.store and S.store.load) then return 0 end
    local ok, r = pcall(S.store.load)
    if not ok or type(r) ~= "table" or type(r.by_enemy) ~= "table" then return 0 end
    local by, n, max_id = {}, 0, 0
    for k, list in pairs(r.by_enemy) do
        if type(list) == "table" then
            by[k] = {}
            for _, rule in ipairs(list) do
                local clean = M.validate(rule)
                if clean then
                    clean.id = type(rule.id) == "string" and rule.id or ("r" .. (max_id + 1))
                    max_id = math.max(max_id, tonumber(clean.id:match("^r(%d+)$")) or 0)
                    by[k][#by[k] + 1] = clean
                    n = n + 1
                end
            end
        end
    end
    S.rules = { v = 1, next_id = math.max(tonumber(r.next_id) or 1, max_id + 1), by_enemy = by }
    log("rules_loaded", { count = n })
    return n
end

-- -> rule (with id), replaced(bool) | nil, reason, data
function M.add(spec)
    local rule, reason, data = M.validate(spec)
    if not rule then return nil, reason, data end
    local list = S.rules.by_enemy[rule.enemy] or {}
    for i, old in ipairs(list) do
        if same_trigger(old.trigger, rule.trigger) then
            rule.id = old.id
            list[i] = rule
            S.rules.by_enemy[rule.enemy] = list
            return rule, true
        end
    end
    if #list >= M.MAX_RULES_PER_ENEMY then return nil, "invalid_args", { detail = "too many rules for " .. rule.enemy } end
    if count_all() >= M.MAX_RULES then return nil, "invalid_args", { detail = "too many rules" } end
    rule.id = "r" .. S.rules.next_id
    S.rules.next_id = S.rules.next_id + 1
    list[#list + 1] = rule
    S.rules.by_enemy[rule.enemy] = list
    return rule, false
end

function M.find(id)
    for k, list in pairs(S.rules.by_enemy) do
        for i, r in ipairs(list) do if r.id == id then return r, k, i end end
    end
    return nil
end

-- filter: {id} | {enemy} | {all=true}. -> removed ids
function M.clear(filter)
    local removed = {}
    if filter.all then
        for _, list in pairs(S.rules.by_enemy) do for _, r in ipairs(list) do removed[#removed + 1] = r.id end end
        S.rules.by_enemy = {}
    elseif filter.id then
        local r, k, i = M.find(filter.id)
        if r then table.remove(S.rules.by_enemy[k], i); removed[1] = r.id end
    elseif filter.enemy then
        local k = M.enemy_key(filter.enemy)
        for _, r in ipairs(S.rules.by_enemy[k] or {}) do removed[#removed + 1] = r.id end
        S.rules.by_enemy[k] = nil
    end
    for _, id in ipairs(removed) do S.last_fired[id] = nil end
    return removed
end

-- Flat list, sorted by id number. enemy (optional) filters to rules that apply to that class.
function M.list(enemy)
    local out = {}
    local want = enemy and M.enemy_key(enemy)
    for k, list in pairs(S.rules.by_enemy) do
        for _, r in ipairs(list) do
            if not want or want == k or k == "*" or M.scope_matches(k, want) then out[#out + 1] = r end
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.id:match("%d+")) or 0) < (tonumber(b.id:match("%d+")) or 0)
    end)
    return out
end

-- ------------------------------------------------------------------ telegraph sensor
-- Poll each nearby enemy's AiAttackComponent.CurrentAttack.AttackData. A change from nothing (or a
-- different attack) to an attack is one telegraph event: {by, by_id, kind, attack, at, d}.
-- Feeds combat.notify_threat so spells' shield-on-telegraph scorer sees it too.
local function attack_name(ai)
    local comp = U.try(function() return ai.AiAttackComponent end)
    if not U.valid(comp) then return nil end
    local data = U.try(function() return comp.CurrentAttack.AttackData end)
    if not U.valid(data) then return nil end
    local n = U.short(data) or U.class_name(data)
    return n and (n:gsub("^Default__", "")) or "attack"
end
M._attack_name = attack_name

function M.sense(ctx, near)
    local now = ctx.now or 0
    local seen = {}
    for _, e in ipairs(near) do
        local name = attack_name(e.ai)
        local id = e.id or tostring(e.ai)
        seen[id] = true
        local prev = S.attacking[id]
        if name and name ~= prev then
            local ev = { by = e.ai, by_id = id, kind = M.kind_of(id), attack = name, at = now, d = e.d }
            S.events[#S.events + 1] = ev
            log("rules_telegraph", { by = id, attack = name, d_m = U.cm_to_m(e.d) })
            if S.combat and S.combat.notify_threat then
                pcall(S.combat.notify_threat, { by = e.ai, by_id = id, attack = name, source = "rules.sense" }, now)
                ctx.threat = S.combat.threat
            end
        end
        S.attacking[id] = name
    end
    for id in pairs(S.attacking) do if not seen[id] then S.attacking[id] = nil end end
    for i = #S.events, 1, -1 do
        if now - S.events[i].at > M.THREAT_FRESH_MS or now < S.events[i].at then table.remove(S.events, i) end
    end
end

-- ------------------------------------------------------------------ trigger checks
-- -> subject actor (truthy) when the trigger fires, plus an optional event key (edge triggers)
local CHECK = {}

function CHECK.telegraph(rule, env)
    local tr = rule.trigger
    for _, ev in ipairs(S.events) do
        if M.scope_matches(rule.enemy, ev.kind) and ev.d <= tr.near_m * 100
           and (not tr.attack or (ev.attack or ""):lower():find(tr.attack:lower(), 1, true)) then
            local key = ev.by_id .. "|" .. ev.attack .. "|" .. tostring(ev.at)
            if not env.done_keys[rule.id .. "|" .. key] then return ev.by, key end
        end
    end
end

local function target_in_scope(rule, env)
    local t = env.ctx.t
    if U.valid(t) and M.scope_matches(rule.enemy, M.kind_of(U.short(t))) then return t end
end

function CHECK.enemy_hp_below(rule, env)
    local t = target_in_scope(rule, env)
    local pct = t and hp_pct(t)
    if pct and pct > 0 and pct < rule.trigger.value then return t end
end

function CHECK.cluster_at_least(rule, env)
    local t = env.ctx.t
    if not U.valid(t) then return nil end
    local at = U.loc(t)
    local n, match = 0, false
    for _, e in ipairs(env.near) do
        if U.dist(at, e.at) <= M.CLUSTER_RADIUS_CM then
            n = n + 1
            if M.scope_matches(rule.enemy, M.kind_of(e.id)) then match = true end
        end
    end
    if match and n >= rule.trigger.value then return t end
end

function CHECK.own_hp_below(rule, env)
    local t = target_in_scope(rule, env)
    local pct = t and hp_pct(env.ctx.p)
    if pct and pct < rule.trigger.value then return t end
end

function CHECK.luis_hp_below(rule, env)
    local t = target_in_scope(rule, env)
    local luis = t and U.find_player("luis")
    local pct = luis and hp_pct(luis)
    if pct and pct < rule.trigger.value then return t end
end

function CHECK.enemy_stunned(rule, env)
    local t = target_in_scope(rule, env)
    if t and S.spells and S.spells.is_target_stunned(t) then return t end
end

function CHECK.spell_ready(rule, env)
    local t = target_in_scope(rule, env)
    if t and S.spells and S.spells.can_cast(rule.trigger.spell) then return t end
end
M._CHECK = CHECK

-- ------------------------------------------------------------------ actions
local function move_to_location(p, dest, accept_cm)
    local c = U.controller_of(p)
    if not c then return false, "companion_down" end
    local ok, res = U.call(S.log, "rules.MoveToLocation", { dest = dest, accept = accept_cm }, function()
        return c:MoveToLocation(dest, accept_cm, true, true, true, false, nil, true)
    end)
    if not ok then return false, "body_error" end
    if tonumber(res) == 0 then return false, "path_blocked" end
    return true
end

local function move_to_actor(p, goal, accept_cm)
    local c = U.controller_of(p)
    if not c then return false, "companion_down" end
    local ok, res = U.call(S.log, "rules.MoveToActor", { goal = U.short(goal), accept = accept_cm }, function()
        return c:MoveToActor(goal, accept_cm, true, true, true, nil, true)
    end)
    if not ok then return false, "body_error" end
    if tonumber(res) == 0 then return false, "path_blocked" end
    return true
end

-- Item id ("ITEM_Club_Wood") or path -> data path, via the attack data table (catalog-generated).
function M.item_path(item)
    if type(item) ~= "string" then return nil end
    if item:sub(1, 1) == "/" then return item end
    local data = S.combat and S.combat.data and S.combat.data()
    local want = item:lower()
    for path in pairs(data and data.items or {}) do
        local id = path:match("%.([%w_]+)$") or path
        if id:lower() == want then return path end
    end
    return nil
end

local ACT = {}

function ACT.cast(a, env, subject)
    if not S.spells then return false, "not_implemented" end
    local tgt
    if a.target == "self" then tgt = nil
    elseif a.target == "cluster" then
        local pts = {}
        for _, e in ipairs(env.near) do pts[#pts + 1] = e.at end
        tgt = S.spells.pick_cluster(pts, M.CLUSTER_RADIUS_CM, 1) or (subject and U.loc(subject))
    else
        tgt = subject or env.ctx.t
    end
    local r = S.spells.cast(env.ctx.p, a.spell, tgt, {})
    return r.ok == true, r.reason, r.data
end

function ACT.evade(a, env, subject)
    local p = env.ctx.p
    local here, from = U.loc(p), U.loc(subject or env.ctx.t)
    if not (here and from) then return false, "unknown_target" end
    local dx, dy = here.X - from.X, here.Y - from.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then
        local f = U.forward(p) or { X = 1, Y = 0 }
        dx, dy, len = -f.X, -f.Y, 1
    end
    local d = a.distance_m * 100
    local dest = { X = here.X + dx / len * d, Y = here.Y + dy / len * d, Z = here.Z }
    local ok, reason = move_to_location(p, dest, 50)
    if ok then env.busy_until = math.max(env.busy_until or 0, env.ctx.now + M.EVADE_BUSY_MS) end
    return ok, reason, { to = U.to_wire(dest) }
end

function ACT.retreat(a, env)
    local luis = U.find_player("luis")
    if not luis then return false, "unknown_target" end
    local ok, reason = move_to_actor(env.ctx.p, luis, M.RETREAT_ACCEPT_CM)
    if ok then env.busy_until = math.max(env.busy_until or 0, env.ctx.now + a.duration_s * 1000) end
    return ok, reason
end

function ACT.switch_weapon(a, env)
    local inv = S.inventory
    if not (inv and type(inv.count) == "function") then return false, "state_unavailable", { detail = "no bot inventory store" } end
    local path = M.item_path(a.item)
    local id = path and (path:match("%.([%w_]+)$") or path) or a.item
    if (tonumber(U.try(inv.count, id)) or 0) <= 0 then return false, "not_in_inventory", { item = id } end
    if not path then return false, "invalid_args", { detail = "unknown item " .. a.item } end
    if not S.gear then return false, "not_implemented" end
    local cur = S.gear.read(env.ctx.p)
    if cur and cur.right == path then return true, nil, { already = true } end
    local r = S.gear.equip(S.log, env.ctx.p, path, {})
    return type(r) == "table" and r.ok == true, type(r) == "table" and r.reason or "body_error"
end

function ACT.focus_target(_, env, subject)
    local act = env.ctx.a
    if not (act and U.valid(subject)) then return false, "unknown_target" end
    if act.target == subject then return true end
    act.target, act.target_id = subject, U.short(subject)
    act.first_hp, act.last_hp = nil, nil
    act.focus_switches = (act.focus_switches or 0) + 1
    local c = U.controller_of(env.ctx.p)
    if c then U.call(S.log, "rules.K2_SetFocus", { target = act.target_id }, function() c:K2_SetFocus(subject) end) end
    return true
end
M._ACT = ACT

-- ------------------------------------------------------------------ the combat hook
-- Truthy when a rule acted this tick (or an evade/retreat is still running): the BT then skips its
-- approach and swing for this tick.
function M.combat_tick(ctx)
    local p = ctx.p
    if not U.valid(p) then return nil end
    local now = ctx.now or 0
    local a = ctx.a or {}
    local near = enemies_near(U.loc(p), M.SENSE_CM)
    M.sense(ctx, near)
    if a._rules_busy_until and now < a._rules_busy_until then return "rules_busy" end
    local rules = M.list()
    if #rules == 0 then return nil end
    a._rules_done = a._rules_done or {}
    local env = { ctx = ctx, near = near, done_keys = a._rules_done, busy_until = nil }
    local acted = nil
    for _, rule in ipairs(rules) do
        local last = S.last_fired[rule.id]
        if not last or now - last >= rule.cooldown_s * 1000 or now < last then
            local check = CHECK[rule.trigger.kind]
            local ok_c, subject, key = pcall(check, rule, env)
            if ok_c and subject then
                S.last_fired[rule.id] = now
                if key then a._rules_done[rule.id .. "|" .. key] = true end
                local results = {}
                for _, act in ipairs(rule.actions) do
                    local ok_a, ok, reason = pcall(ACT[act.kind], act, env, subject)
                    if not ok_a then ok, reason = false, "body_error: " .. tostring(ok) end
                    results[#results + 1] = { kind = act.kind, spell = act.spell, ok = ok == true, reason = reason }
                    if ok then acted = rule.id end
                end
                log("rule_fired", { id = rule.id, enemy = rule.enemy, trigger = rule.trigger.kind,
                                    subject = U.short(subject), results = results })
            elseif not ok_c then
                log("rule_check_error", { id = rule.id, err = tostring(subject) })
            end
        end
    end
    if env.busy_until then a._rules_busy_until = env.busy_until end
    return acted
end

-- Install as the first on_tick hook of body/combat.lua (Luis's orders before utility reflexes).
function M.install(combat)
    S.combat = combat
    local list = combat.hooks and combat.hooks.on_tick
    local remover = combat.add_hook("on_tick", "rules", M.combat_tick)
    if type(list) == "table" and #list > 1 and list[#list].name == "rules" then
        table.insert(list, 1, table.remove(list)) -- move to the front
    end
    log("rules_installed", { rules = count_all() })
    return remover
end

-- ------------------------------------------------------------------ bridge
local function rule_wire(r)
    return { id = r.id, enemy = r.enemy, trigger = object(r.trigger), actions = r.actions,
             cooldown_s = r.cooldown_s, note = r.note }
end

local function wire_list(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = rule_wire(r) end
    return out
end

-- opts: {spells, gear, inventory, combat, store = {load() -> tbl, save(tbl) -> bool}}
function M.configure(opts)
    opts = opts or {}
    for _, k in ipairs({ "spells", "gear", "inventory", "combat", "store" }) do
        if opts[k] ~= nil then S[k] = opts[k] end
    end
    if opts.log ~= nil then S.log = opts.log end
end

function M.register(bridge, log_mod, opts)
    S.bridge, S.log = bridge, log_mod or S.log
    M.configure(opts)
    M.load()
    -- set_reflex_rule {enemy?, trigger{kind,...}, actions[{kind,...}], cooldown_s?, note?}
    bridge.handlers.set_reflex_rule = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "set_reflex_rule" }) end
        if args.trigger == nil or (args.actions == nil and args.action == nil) then
            return result(false, "invalid_args", { detail = "trigger and actions are required", sensable = M.TRIGGER_ORDER,
                                                   actions = M.ACTION_ORDER })
        end
        local rule, replaced_or_reason, data = M.add(args)
        if not rule then return result(false, replaced_or_reason, data) end
        local persisted = persist()
        local back = M.find(rule.id) -- verified state: read the stored rule back
        if not back then return result(false, "verification_failed", { detail = "rule not stored" }) end
        log("rule_set", { id = rule.id, enemy = rule.enemy, trigger = rule.trigger.kind, replaced = replaced_or_reason })
        return result(true, nil, { rule = rule_wire(back), replaced = replaced_or_reason == true, persisted = persisted,
                                   warnings = M.warnings(back), count = count_all() })
    end
    bridge.handlers.list_rules = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "list_rules" }) end
        return result(true, nil, { rules = wire_list(M.list(args.enemy)), sensable = M.TRIGGER_ORDER, actions = M.ACTION_ORDER })
    end
    -- clear_rule {id} | {enemy} | {all=true}
    bridge.handlers.clear_rule = function(args)
        args = args or {}
        if args.probe == true then return result(true, nil, { probe = true, tool = "clear_rule" }) end
        if not (type(args.id) == "string" or type(args.enemy) == "string" or args.all == true) then
            return result(false, "invalid_args", { detail = "id, enemy or all=true is required" })
        end
        local removed = M.clear({ id = args.id, enemy = args.enemy, all = args.all == true })
        if args.id and #removed == 0 then return result(false, "unknown_target", { id = args.id }) end
        local persisted = persist()
        return result(true, nil, { removed = removed, persisted = persisted, count = count_all() })
    end
    log("rules_registered", { rules = count_all() })
    return M
end

function M._reset()
    S.log, S.bridge, S.store, S.spells, S.gear, S.inventory, S.combat = nil, nil, nil, nil, nil, nil, nil
    S.rules = { v = 1, next_id = 1, by_enemy = {} }
    S.last_fired, S.attacking, S.events = {}, {}, {}
end
M._S = S

return M
