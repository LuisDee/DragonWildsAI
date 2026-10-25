-- Gather: ONE generic loop over a resource profile (body/resource_profiles.lua): find -> approach ->
-- swing with the held tool's own attack chain -> follow the profile's state chain (felled tree ->
-- splittable logs -> logs -> stump) -> collect the drops into the bot inventory -> repeat until the
-- goal count is verified from the inventory. Trees, rocks and ores differ only in their profile.
--
-- Bridge tool (registered by M.register beside body/skills.lua, same action slot and tick loop):
--   gather {resource, count, radius?, bonus?}  ASYNC
--     resource: profile key, alias, drop item id or path ("oak", "log", "ITEM_Resources_Wood_Oak", "stone")
--     count:    how many MORE of the drop item to collect (delta, like the mock and brain/executor.py)
--     radius:   initial search radius in metres (default 30); widens x1.5 on failure up to MAX_RADIUS_CM
--     bonus:    false skips bonus stages (the stump: +1 log, but chopping it stops regrowth)
--   events:  gather_progress {task_id, resource, item, have, want}; then task_done / task_failed
--   ok data: {resource, item, gathered, want, total, sites, swings, native_hits, emulated_hits,
--             picked, seconds, radius_m}
--   reasons: nothing_in_range, wrong_tool, path_blocked, inventory_full, interrupted (pre-empted),
--            timeout, companion_down, invalid_args, unknown_target (unknown resource),
--            not_implemented (no inventory service)
--
-- Services used: body/sense (find, foliage conversion, relocate), body/hitcheck (did the swing
-- register, why not), body/watch (timeline recorder, M.WATCH), body/combat (attack sets, perform),
-- body/gear (held item), body/inventory + body/items (count, pickup) via M.default_store().
--
-- THE HIT (verified live 2026-10-25, DISCOVERIES "Gather"): a puppet swing reaches a tree's damage
-- pipeline but the tool gate (BP_DamageModifier_SpecificWeapon_C) reads it as UNARMED (no
-- ActionGranter item instance), so it does 0 damage. Mode M.HIT = "auto": swing for real; at the
-- swing's damage point, if the HP did not drop AND hitcheck saw the gate reject it (or hooks are
-- unavailable and the puppet is within reach), apply the same hit with
-- HealthComponent:DecreaseHealth(step damage x tool multiplier, "dw_gather"). DecreaseHealth on a
-- standing oak was verified: 220 -> 136 -> split into stump 110 + BP_FelledTree_Oak_C + log + drop.
-- The tool rule is kept by our own check: the held tool's category and tier must satisfy the
-- resource's live gate (RequiredCategory / RequiredTier), else wrong_tool. Native damage, when it
-- works (an item instance on the puppet), is detected and used instead; never both.
-- Behaviour tree (beehive, like combat.lua): leaves return 'success' when they took the tick.
--   end_checks > recovering(swing in flight) > tool_check > work_target > choose_target
local U = require("body.util")
local gear = require("body.gear")
local combat = require("body.combat")
local sense = require("body.sense")
local hitcheck = require("body.hitcheck")
local watch = require("body.watch")
local profiles = require("body.resource_profiles")
local selector = require("body.vendor.beehive.selector")
local jsonutil = require("jsonutil")

local M = {}

M.HIT = os.getenv("DW_GATHER_HIT") or "auto"   -- auto | native (never emulate)
M.WATCH = os.getenv("DW_GATHER_WATCH") ~= "0"   -- timeline events "gather_watch" (1 Hz near the site)
M.DEFAULT_RADIUS_CM = 3000
M.MAX_RADIUS_CM = 12000
M.WIDEN = 1.5
M.ACCEPT_CM = 50                -- MoveToActor acceptance (the navmesh stops at the trunk anyway)
M.PICKUP_CM = 200               -- take a drop from this close
M.APPROACH_REISSUE_MS = 1500
M.STUCK_MS = 4000
M.STUCK_MOVE_CM = 50
M.MAX_REISSUE = 3
M.STUCK_SWING_SLACK_CM = 90     -- stuck but this close beyond reach: try swinging anyway
M.DMG_SLACK_MS = 150            -- check the HP this long after the swing's damage point
M.NO_EFFECT_SWINGS = 4          -- swings in a row with no HP change -> target is bad
M.BAD_STREAK = 3                -- bad targets in a row -> fail (path_blocked)
M.TOOL_RECHECK_MS = 3000
M.PROGRESS_MIN_MS = 2000
M.DROP_SETTLE_MS = 1500         -- after the last break, wait this long for drops to land
M.TIMEOUT_BASE_MS = 90000
M.TIMEOUT_PER_UNIT_MS = 20000
M.TIMEOUT_MAX_MS = 1700000      -- brain waits 1800 s (brain/bridge_client.py DEFAULT_TIMEOUTS)
M.FALLBACK_DMG_MS = 600
M.FALLBACK_NEXT_MS = 1300

local S_, F_ = "success", "failure"

-- ------------------------------------------------------------------ inventory adapter
-- The bot inventory (body/inventory.lua + body/items.lua, the inventory agent's API):
--   count(item) -> available count; find_drops(opts) -> world item infos; pickup(log, info) -> result.
function M.store_from(inv, items)
    return {
        kind = "inventory",
        count = function(item) return tonumber(inv.count(item)) or 0 end,
        find_drops = function(opts) return items.find(opts) end,
        pickup = function(log, info) return items.take_world_item(log, info.actor, inv) end,
    }
end

function M.default_store()
    local ok_inv, inv = pcall(require, "body.inventory")
    local ok_it, items = pcall(require, "body.items")
    if not (ok_inv and ok_it and type(inv) == "table" and type(items) == "table"
            and inv.count and items.take_world_item and items.find) then
        return nil, "inventory service missing"
    end
    if inv.is_ready and not inv.is_ready() then return nil, "inventory not initialised" end
    return M.store_from(inv, items)
end

-- ------------------------------------------------------------------ tools
-- Required category tag and tier of the actor's tool gate (live), else the profile's fallback.
function M.gate_of(actor, profile)
    local need = { tier = profile.min_tier or 1, tag = (profiles.TOOL_CATEGORIES[profile.tool] or {}).tag, source = "profile" }
    local function scan(arr)
        if arr == nil then return end
        pcall(function()
            arr:ForEach(function(_, e)
                local m = U.try(function() return e:get() end) or e
                if (U.class_word(m) or ""):find("SpecificWeapon", 1, true) then
                    local t = tonumber(U.try(function() return m.RequiredTier end))
                    if t then need.tier, need.source = t, "live" end
                    local tag = U.str(U.try(function() return m.RequiredCategory.TagName end))
                    if tag and tag ~= "" and tag ~= "None" then need.tag = tag end
                end
            end)
        end)
    end
    if actor then
        if U.try(function() return actor.bIsStump end) == true then
            scan(U.try(function() return actor.DamageModifiersWhenStump end))
        else
            scan(U.try(function() return actor.DamageModifiersWhenTree end))
        end
        if need.source ~= "live" then scan(U.try(function() return actor.DamageComponent.DamageModifiers end)) end
    end
    return need
end

-- Pure: does `tool` (resource_profiles.TOOLS entry) satisfy profile + need? Returns ok, why.
function M.tool_ok(tool, profile, need)
    if not tool then return false, "no_tool" end
    if tool.category ~= profile.tool then return false, "wrong_category" end
    local want_tag = (profiles.TOOL_CATEGORIES[tool.category] or {}).tag
    if need and need.tag and want_tag and need.tag ~= want_tag then return false, "wrong_category" end
    if need and need.tier and tool.tier < need.tier then return false, "tier_too_low" end
    return true
end

-- ------------------------------------------------------------------ attack sets
-- {obj, act, damage, dmg_ms, next_ms, label} for the held item and kind (primary | special).
function M.swing_for(held, kind)
    local prof = combat.profile_for(held)
    local raw, set = prof.primary, nil
    local steps = prof.steps
    if kind == "special" and prof.special then raw, steps = prof.special, prof.special.steps end
    set = raw and combat.resolve(raw, steps)
    if not set and kind == "special" then return M.swing_for(held, "primary") end
    if not set or not set.steps[1] then return nil end
    local st, rs = set.steps[1], (steps or {})[1] or {}
    return { obj = st.obj, act = set.act, damage = st.damage or rs.damage or 10, dmg_ms = rs.dmg_ms or M.FALLBACK_DMG_MS,
             next_ms = st.next_ms or rs.next_ms or M.FALLBACK_NEXT_MS, label = set.name or kind, kind = kind }
end

-- ------------------------------------------------------------------ result
local function result_data(a, extra)
    local d = {
        resource = a.key, item = a.item_id, gathered = a.have or 0, want = a.want, total = a.total or 0,
        sites = a.sites, swings = a.swings, native_hits = a.native_hits, emulated_hits = a.emulated_hits,
        picked = a.picked, seconds = U.round((a.deps.now() - a.started) / 1000, 1),
        radius_m = U.cm_to_m(a.radius_cm),
    }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
M._result_data = result_data

-- ------------------------------------------------------------------ the action
-- args: validated {resource, count, radius?, bonus?}; deps: see M.tree.
function M.new_action(key, profile, args, deps, base)
    local a = {
        kind = "gather", key = key, profile = profile, item = profile.item, item_id = profiles.item_id(profile.item),
        want = math.floor(args.count), base = base or 0, have = 0, total = base or 0,
        radius_cm = math.min((tonumber(args.radius) or M.DEFAULT_RADIUS_CM / 100) * 100, M.MAX_RADIUS_CM),
        bonus = args.bonus ~= false, sites = 0, swings = 0, native_hits = 0, emulated_hits = 0, picked = 0,
        bad = {}, taken = {}, bad_streak = 0, site = nil, target = nil, deps = deps,
        timeout_ms = math.min(M.TIMEOUT_BASE_MS + M.TIMEOUT_PER_UNIT_MS * math.floor(args.count), M.TIMEOUT_MAX_MS),
    }
    if deps.now then a.started = deps.now() end
    return a
end

-- deps: {now(), puppet(), finish(a, ok, reason, data), emit(name, data), log(name, data), log_mod,
--        store = {count, find_drops, pickup}, move_to_actor(c, actor, accept) -> request result,
--        decrease_health(actor, amount) -> ok (default: HealthComponent:DecreaseHealth via U.call),
--        perform(p, swing, actor) -> ok (default: combat.perform), face(p, actor), held(p) -> path,
--        convert(p, at, radius_cm) (default sense.convert_foliage)}
function M.tree(deps)
    local function now() return deps.now() end
    local function lg(name, data) if deps.log then deps.log(name, data) end end

    local function fail(a, reason, extra)
        deps.finish(a, false, reason, result_data(a, extra)); return S_
    end

    -- ---------------------------------------------------------------- end checks
    local function end_checks(a)
        local p = deps.puppet()
        if not p then deps.finish(a, false, "companion_down", result_data(a)); return S_ end
        a.p = p
        local total = deps.store.count(a.item)
        a.total = total
        a.have = math.max(0, total - a.base)
        if a.have ~= a.last_have and (a.have >= a.want or not a.last_emit or now() - a.last_emit >= M.PROGRESS_MIN_MS) then
            a.last_have, a.last_emit = a.have, now()
            deps.emit("gather_progress", { task_id = a.id, resource = a.key, item = a.item_id, have = a.have, want = a.want })
        end
        if a.have >= a.want then deps.finish(a, true, nil, result_data(a)); return S_ end
        if now() - a.started >= a.timeout_ms then return fail(a, "timeout") end
        if a.watch then pcall(a.watch.step, a.watch, now()) end
        return F_
    end

    -- ---------------------------------------------------------------- swing resolution
    local function resolve_swing(a)
        local sw = a.swing
        if not sw or sw.resolved then return end
        if now() < sw.at + sw.dmg_ms + M.DMG_SLACK_MS then return end
        sw.resolved = true
        local t = a.target
        local actor = t and t.actor
        if not (actor and U.alive(actor)) then return end
        local hp_now = U.health(actor)
        local verdict = hitcheck.armed() and hitcheck.check(U.short(a.p), sw.seq, sw.hp, hp_now) or nil
        if sw.hp and hp_now and hp_now < sw.hp then
            a.native_hits = a.native_hits + 1
            t.no_effect = 0
            lg("gather_hit", { target = t.id, mode = "native", before = sw.hp, after = hp_now })
            return
        end
        local gated = verdict == "gate_no_weapon" or verdict == "modified_to_zero"
        local in_reach = sw.dist <= (t.spec.reach_cm or 170) + M.STUCK_SWING_SLACK_CM
        if M.HIT == "auto" and (gated or (verdict == nil and in_reach)) then
            local amount = sw.damage * (a.tool and a.tool.mult or 1)
            local ok = deps.decrease_health(actor, amount, a)
            local after = U.health(actor)
            if ok and (after == nil or not sw.hp or after < sw.hp) then
                a.emulated_hits = a.emulated_hits + 1
                t.no_effect, t.hits = 0, (t.hits or 0) + 1
                lg("gather_hit", { target = t.id, mode = "emulated", verdict = verdict, amount = amount, before = sw.hp, after = after })
                return
            end
        end
        t.no_effect = (t.no_effect or 0) + 1
        t.last_verdict = verdict
        lg("gather_hit", { target = t.id, mode = "none", verdict = verdict, before = sw.hp, after = hp_now, dist_cm = sw.dist })
    end

    local function recovering(a)
        resolve_swing(a)
        if a.done then return S_ end
        if now() < (a.ready_at or 0) then return S_ end
        return F_
    end

    -- ---------------------------------------------------------------- tool
    local function tool_check(a)
        if a.tool_checked_at and now() - a.tool_checked_at < M.TOOL_RECHECK_MS then return F_ end
        a.tool_checked_at = now()
        local held = deps.held(a.p)
        local tool = profiles.tool_for(held)
        a.held, a.tool = held, tool
        local need = a.need or { tier = a.profile.min_tier, tag = (profiles.TOOL_CATEGORIES[a.profile.tool] or {}).tag }
        local ok, why = M.tool_ok(tool, a.profile, need)
        if not ok then
            return fail(a, "wrong_tool", { held = held and profiles.item_id(held) or jsonutil.null, detail = why,
                                           need_category = a.profile.tool, need_tier = need.tier })
        end
        return F_
    end

    -- ---------------------------------------------------------------- targets
    local function mark_bad(a, why)
        local t = a.target
        if t then
            a.bad[t.key] = true
            lg("gather_bad_target", { target = t.id, stage = t.stage, why = why })
        end
        a.target, a.move = nil, nil
        a.bad_streak = a.bad_streak + 1
        if a.bad_streak >= M.BAD_STREAK then
            return fail(a, "path_blocked", { detail = why, bad_targets = a.bad_streak })
        end
        return S_
    end

    local function set_target(a, entry, spec, stage)
        a.target = { actor = entry.actor, id = entry.id, loc = entry.loc, key = sense.key(entry.loc) .. "/" .. stage,
                     spec = spec, stage = stage, no_effect = 0, hits = 0, info = entry }
        a.move = nil
        if stage ~= "drop" then
            a.need = M.gate_of(entry.actor, a.profile)
            local ok, why = M.tool_ok(a.tool, a.profile, a.need)
            if not ok then
                fail(a, "wrong_tool", { held = a.held and profiles.item_id(a.held) or jsonutil.null, detail = why,
                                        need_category = a.profile.tool, need_tier = a.need.tier, target = entry.id })
                return false
            end
        end
        lg("gather_target", { target = entry.id, stage = stage, dist_m = U.cm_to_m(entry.dist), hp = entry.state and entry.state.hp })
        return true
    end

    local function site_spec_entry(a, spec)
        local site = a.site
        if spec.at_root then
            local e = sense.nearest(spec, { origin = site.loc, radius_cm = 200 })
            if e and a.bad[sense.key(e.loc) .. "/" .. spec.name] then return nil end
            return e
        end
        local skip = {}
        for k in pairs(a.bad) do
            local pos, stage = k:match("^(.-)/(.*)$")
            if stage == spec.name then skip[pos] = true end
        end
        return sense.nearest(spec, { origin = U.loc(a.p) or site.loc, near = { loc = site.loc, radius_cm = a.profile.site_radius_cm or 1000 },
                                     skip = skip })
    end

    local function drops_near(a, origin, radius)
        return deps.store.find_drops({ origin = origin, radius_cm = radius, item = a.item_id, max = 8 }) or {}
    end

    local function choose_target(a)
        local p = a.p
        local here = U.loc(p)
        if a.site then
            for _, spec in ipairs(a.profile.children or {}) do
                if not (spec.bonus and not a.bonus) then
                    local e = site_spec_entry(a, spec)
                    if e then return set_target(a, e, spec, spec.name) and S_ or S_ end
                end
            end
            local st = a.profile.settle
            if st and now() - (a.site.last_break or a.site.started) < (st.max_ms or 10000)
                and sense.nearest({ class = st.class, match = st.match }, { origin = a.site.loc, radius_cm = a.profile.site_radius_cm or 1000 }) then
                return S_ -- the felled tree is still turning into logs
            end
            local drops = drops_near(a, a.site.loc, a.profile.collect_radius_cm or 1200)
            for _, d in ipairs(drops) do
                if not a.taken[d.id] and not a.bad[sense.key(d.loc) .. "/drop"] then
                    d.dist = U.dist(here, d.loc)
                    set_target(a, d, { name = "drop", reach_cm = M.PICKUP_CM }, "drop")
                    return S_
                end
            end
            if a.site.last_break and now() - a.site.last_break < M.DROP_SETTLE_MS then return S_ end
            lg("gather_site_done", { site = a.site.id, seconds = U.round((now() - a.site.started) / 1000, 1) })
            a.site = nil
            return S_
        end
        -- loose drops of our item near us (e.g. from an earlier interrupted run) come first
        local loose = drops_near(a, here, a.profile.collect_radius_cm or 1200)
        for _, d in ipairs(loose) do
            if not a.taken[d.id] and not a.bad[sense.key(d.loc) .. "/drop"] then
                set_target(a, d, { name = "drop", reach_cm = M.PICKUP_CM }, "drop"); return S_
            end
        end
        -- SCAN for a new root, widening the radius on failure
        local spec = a.profile.root
        if a.profile.foliage then deps.convert(p, here, a.radius_cm) end
        local skip = {}
        for k in pairs(a.bad) do local pos, stage = k:match("^(.-)/(.*)$"); if stage == "root" then skip[pos] = true end end
        local e = sense.nearest(spec, { origin = here, radius_cm = a.radius_cm, skip = skip })
        if not e then
            if a.radius_cm >= M.MAX_RADIUS_CM then
                return fail(a, "nothing_in_range", { radius_m = U.cm_to_m(a.radius_cm) })
            end
            a.radius_cm = math.min(a.radius_cm * M.WIDEN, M.MAX_RADIUS_CM)
            lg("gather_widen", { radius_m = U.cm_to_m(a.radius_cm) })
            return S_
        end
        a.site = { loc = e.loc, id = e.id, started = now() }
        a.sites = a.sites + 1
        if set_target(a, e, spec, "root") then return S_ end
        return S_
    end

    -- ---------------------------------------------------------------- work the target
    local function refresh(a)
        local t = a.target
        if U.alive(t.actor) then
            if t.stage == "drop" then return true end
            local st = sense.state_of(t.actor)
            local f = sense.FILTERS[t.spec.filter or "any"] or sense.FILTERS.any
            if f(st, t.actor) then t.loc = U.loc(t.actor) or t.loc; return true end
            return false -- broken (felled, emptied, stump destroyed)
        end
        if t.stage == "drop" then return false end
        -- reverted to foliage (undamaged trees do within seconds): convert there and find it again
        local e = sense.relocate(deps.log_mod, a.p, t.spec, t.loc, 200, a.profile.foliage)
        if e then t.actor, t.id = e.actor, e.id; return true end
        return false
    end

    local function target_done(a)
        local t = a.target
        a.target, a.move = nil, nil
        if t.stage ~= "drop" then
            if (t.hits or 0) > 0 or (a.native_hits + a.emulated_hits) > 0 then a.bad_streak = 0 end
            if a.site then a.site.last_break = now() end
        end
        lg("gather_target_done", { target = t.id, stage = t.stage, hits = t.hits })
        return S_
    end

    local function approach(a, t, d)
        local m = a.move
        local here = U.loc(a.p)
        if not m or m.key ~= t.key then
            m = { key = t.key, reissues = 0, last_pos = here, last_progress = now(), issued = nil }
            a.move = m
        end
        if not m.last_pos or U.dist(here, m.last_pos) > M.STUCK_MOVE_CM then
            m.last_pos, m.last_progress = here, now()
        elseif now() - m.last_progress >= M.STUCK_MS then
            m.reissues, m.last_progress, m.issued = m.reissues + 1, now(), nil
            if m.reissues > M.MAX_REISSUE then return mark_bad(a, "path_blocked") end
        end
        if not m.issued or now() - m.issued >= M.APPROACH_REISSUE_MS then
            m.issued = now()
            local c = U.controller_of(a.p)
            local r = c and deps.move_to_actor(c, t.actor, M.ACCEPT_CM) or 0
            if r == 0 then m.reissues = m.reissues + 1; if m.reissues > M.MAX_REISSUE then return mark_bad(a, "path_blocked") end end
        end
        return S_
    end

    local function swing(a, t, d)
        local sw = M.swing_for(a.held, t.spec.attack or "primary")
        if not sw then return fail(a, "wrong_tool", { detail = "attack set not loaded", held = a.held and profiles.item_id(a.held) or jsonutil.null }) end
        deps.face(a.p, t.actor)
        local seq = hitcheck.seq()
        local hp0 = U.health(t.actor) -- before the swing: native damage may land at once
        local ok = deps.perform(a.p, sw, t.actor, { target = t.id, stage = t.stage, n = a.swings + 1, label = sw.label })
        a.swings = a.swings + 1
        a.swing = { at = now(), dmg_ms = sw.dmg_ms, damage = sw.damage, hp = hp0, seq = seq, dist = d, resolved = not ok }
        a.ready_at = now() + sw.next_ms
        if not ok then t.no_effect = (t.no_effect or 0) + 1 end
        return S_
    end

    local function pickup(a, t)
        local r = deps.store.pickup(deps.log_mod, t.info or t)
        if r and r.ok then
            if t.id then a.taken[t.id] = true end -- it lingers ~0.1 s (SetLifeSpan): never take it twice
            a.picked = a.picked + (tonumber(r.data and r.data.count) or 1)
            a.target = nil
            lg("gather_pickup", { item = a.item_id, count = r.data and r.data.count, world_item = t.id })
            return S_
        end
        local why = r and (r.reason or "") or "no result"
        local detail = r and r.data and tostring(r.data.detail or "") or ""
        if why == "inventory_full" or detail:lower():find("full", 1, true) then
            return fail(a, "inventory_full", { detail = detail })
        end
        a.bad[t.key] = true
        a.target = nil
        lg("gather_pickup_failed", { world_item = t.id, reason = why, detail = detail })
        return S_
    end

    local function work_target(a)
        local t = a.target
        if not t then return F_ end
        if not refresh(a) then return target_done(a) end
        local d = U.actor_dist(a.p, t.actor)
        local reach = t.spec.reach_cm or 170
        if t.stage == "drop" then
            if d > reach then return approach(a, t, d) end
            return pickup(a, t)
        end
        if (t.no_effect or 0) >= M.NO_EFFECT_SWINGS then
            if t.last_verdict == "gate_tier" or t.last_verdict == "gate_category" then
                return fail(a, "wrong_tool", { detail = t.last_verdict, target = t.id })
            end
            return mark_bad(a, "swing_no_effect:" .. tostring(t.last_verdict))
        end
        if d > reach then
            local m = a.move
            local stuck_close = m and m.reissues > 0 and d <= reach + M.STUCK_SWING_SLACK_CM
            if not stuck_close then return approach(a, t, d) end
        end
        return swing(a, t, d)
    end

    return selector({ end_checks, recovering, tool_check, work_target, choose_target })
end

-- ------------------------------------------------------------------ live deps and the handler
local function face(log, p, actor)
    local pl, tl = U.loc(p), U.loc(actor)
    if not (pl and tl) then return end
    local yaw = math.deg(math.atan(tl.Y - pl.Y, tl.X - pl.X))
    U.call(log, "gather.K2_SetActorRotation", { yaw = U.round(yaw, 1) }, function()
        p:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    end)
end

local function decrease_health(log, actor, amount)
    local hc = U.try(function() return actor.HealthComponent end)
    if not U.valid(hc) then return false end
    local ok = U.call(log, "gather.DecreaseHealth", { target = U.short(actor), amount = amount }, function()
        hc:DecreaseHealth(amount, "dw_gather")
    end)
    return ok
end

-- Live deps for a gather action. opts: {skills (body/skills.lua), log_mod, puppet, store, bridge}
function M.live_deps(opts)
    local log_mod = opts.log_mod
    local skills = opts.skills
    return {
        now = opts.now or function() return skills.now() end,
        puppet = function() return opts.puppet.get() end,
        finish = opts.finish or function(a, ok, reason, data) return skills._finish(a, ok, reason, data) end,
        emit = opts.emit or function(name, data) if opts.bridge then pcall(opts.bridge.emit_event, name, data) end end,
        log = function(name, data) U.event(log_mod, name, data) end,
        log_mod = log_mod,
        store = opts.store,
        held = function(p) return gear.read(p).right end,
        face = function(p, actor) face(log_mod, p, actor) end,
        perform = function(p, sw, actor, crumb) return (combat.perform(log_mod, p, sw.obj, sw.act, actor, crumb)) end,
        move_to_actor = opts.move_to_actor or (skills and skills._move_to_actor) or function(c, actor, accept)
            local ok, r = U.call(log_mod, "MoveToActor", { goal = U.short(actor), accept = accept }, function()
                return c:MoveToActor(actor, accept, true, true, true, nil, true)
            end)
            return ok and (tonumber(r) or 2) or 0
        end,
        decrease_health = function(actor, amount) return decrease_health(log_mod, actor, amount) end,
        convert = function(p, at, r) return sense.convert_foliage(log_mod, p, at, r) end,
    }
end

-- Validate args and build {key, profile} or an error result.
function M.check_args(args)
    if type(args.resource) ~= "string" or args.resource == "" then
        return nil, { ok = false, reason = "invalid_args", data = { detail = "resource is required" } }
    end
    local n = tonumber(args.count)
    if not n or n < 1 or n ~= math.floor(n) then
        return nil, { ok = false, reason = "invalid_args", data = { detail = "count must be an integer >= 1" } }
    end
    if args.radius ~= nil and (tonumber(args.radius) == nil or tonumber(args.radius) <= 0) then
        return nil, { ok = false, reason = "invalid_args", data = { detail = "radius must be a positive number of metres" } }
    end
    local key, profile = profiles.resolve(args.resource)
    if not key then
        local known = {}
        for k in pairs(profiles.RESOURCES) do known[#known + 1] = k end
        table.sort(known)
        return nil, { ok = false, reason = "unknown_target", data = { resource = args.resource, known = known } }
    end
    return { key = key, profile = profile }
end

-- Start a gather action in the skills action slot. Returns nil (async) or an error result.
-- opts: {skills, puppet, log_mod, bridge, store, now, finish, emit}
function M.start(args, ctx, opts)
    local chk, err = M.check_args(args)
    if not chk then return err end
    local store = opts.store
    if not store then
        local why
        store, why = M.default_store()
        if not store then return { ok = false, reason = "not_implemented", data = { detail = why } } end
    end
    local p, perr = opts.puppet.ensure_ready()
    if not p then return { ok = false, reason = "companion_down", data = { detail = perr } } end
    hitcheck.arm(opts.log_mod)
    local deps = M.live_deps({ skills = opts.skills, puppet = opts.puppet, log_mod = opts.log_mod, bridge = opts.bridge,
                               store = store, now = opts.now, finish = opts.finish, emit = opts.emit })
    local a = M.new_action(chk.key, chk.profile, args, deps, store.count(chk.profile.item))
    a.id, a.async = ctx and ctx.id, true
    a.tree = M.tree(deps)
    a.step = function(self) self.tree(self) end
    if M.WATCH then
        a.watch = watch.new({ log = opts.log_mod, tag = "gather_watch", radius_cm = 2500, period_ms = 1000,
                              center = function() return (a.site and a.site.loc) or U.loc(a.p or p) end })
    end
    local start = opts.start or opts.skills._start
    start(a)
    a.started = deps.now()
    U.event(opts.log_mod, "gather_start", { resource = chk.key, item = a.item_id, want = a.want, base = a.base,
                                             radius_m = U.cm_to_m(a.radius_cm), store = store.kind })
    return nil
end

-- Register the bridge handler `gather` (probe-safe) next to body/skills.lua's handlers.
-- opts: {skills = body.skills (registered), puppet = body.puppet, store = override}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    local skills = opts.skills or require("body.skills")
    local puppet = opts.puppet or require("body.puppet")
    sense.set_clock(function() return skills.now() end)
    local function h_gather(args, ctx)
        return M.start(args, ctx, { skills = skills, puppet = puppet, log_mod = log_mod, bridge = bridge, store = opts.store })
    end
    local guard = skills._probe_guard
    bridge.handlers.gather = guard and guard("gather", h_gather) or h_gather
    U.event(log_mod, "gather_registered", { resources = (function()
        local k = {}; for name in pairs(profiles.RESOURCES) do k[#k + 1] = name end; table.sort(k); return k end)() })
    return M
end

return M
