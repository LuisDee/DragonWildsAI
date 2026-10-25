-- skills: COMPOSITE skills on Claude's client (route R2; streamline plan step 2). Each tool does the
-- whole job and answers ONE terminal result, verified from fresh game state, with a specific reason
-- and a truthful sentence in data.detail the brain may say as is ("Communication is paramount").
--
--   fetch(target | item, count=1)   find (sense census: world items + ground/foliage pickups) ->
--                                   approach (move.lua) -> FACE it so the game's own interaction
--                                   detector targets it -> one IA_Interact press -> verify the
--                                   inventory grew (repeats for count)
--   consume(item | "food" | "drink") hotbar use (inventory.use with the consumable-class check) ->
--                                   verify the stat rose; not carried but lying within 15 m -> fetch
--                                   first; only in the bag -> "in_bag" (no bag-UI path: it hung)
--   come_to(player, distance=2)     move.lua follow (persistent: re-plans while unreachable) until
--                                   within distance, then stop; fails with the unreachable reason
--                                   after UNREACHABLE_S
--   recover_grave()                 find OWN BP_PlayerGravestone_C (owner guid vs ours) -> approach ->
--                                   face -> "Take All" press -> verify the inventory grew
--   give(player, item, count)       approach the player -> drop at feet (inventory.drop, the UI's
--                                   drop) -> verify the carried count fell
--   interact(target)                the shared engine on any look id (the bridge route delegates here)
-- Every skill acquires the pawn through arbiter.lua (level "command"; a reflex fight suspends it and
-- it re-approaches on resume) and does nothing while _G.DW_PAUSE is set.
--
-- Prior art (search-before-building, docs/ARCHITECTURE.md 8.6): MINDcraft's high-level commands
-- (!goToPlayer(closeness), !givePlayer = go to the player and toss, !consume(item), runAsAction with
-- a timeout; github.com/kolbytn/mindcraft src/agent/commands/actions.js), mineflayer-collectblock
-- (find nearest -> path -> collect -> verify inventory), the interaction-detector facing lesson
-- (DISCOVERIES R2: the detector targets what he FACES within ~1.5 m). Decision: ADAPT those shapes
-- over the bridge's own services (ctx.api); BUILD the thin Lua state machines.
--
-- Contract: HANDLERS[tool](log, args, ctx) -> {pending = action} | failure. ctx.api = the bridge's
-- services (client_bridge.lua M.API: call, census_things, find_thing, match_score, actor_of, counts,
-- me, my_position, aim_at, move_status, reflex_owns_pawn, module, fail, reason_code, null, object).
-- W = the few direct engine touches (facing nudge, grave owner); tests replace them.
local M = {}

M.cfg = {
    reach_m = 2.0,          -- walk closer than this before facing (the detector traces ~6 m but picks what he faces)
    approach_m = 1.0,       -- move.go_to tolerance for the approach
    close_m = 0.6,          -- second, tighter approach when facing alone did not get the detector onto it
    approaches = 3,
    face_s = 3.0,           -- face + nudge until the detector targets the thing
    nudge_scale = 0.3,
    verify_s = 4.0,         -- after a press: wait this long for the inventory to grow / the thing to go
    presses = 2,            -- presses per thing before verification_failed
    fetch_radius_m = 30, fetch_max_radius_m = 60,
    consume_ground_m = 15,  -- consume: fetch first when it lies this close
    consume_verify_s = 6,
    come_to_m = 2.0, come_to_unreachable_s = 30, come_to_timeout_s = 100,
    give_m = 2.0, give_wait_s = 6,
    grave_radius_m = 80,
    lease_s = 15,
    timeout_s = { fetch = 110, consume = 115, come_to = 105, recover_grave = 110, give = 100, interact = 100 },
}

local W = {}
M.W = W

local function paused() return rawget(_G, "DW_PAUSE") == true end
-- Hot-reload-safe memory: the last tool he held (re-equipped after a grave recovery).
local function memory()
    local m = rawget(_G, "DWSkills")
    if not m then m = {}; _G.DWSkills = m end
    return m
end
M.memory = memory
local function dist2d(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
end
local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end

-- ------------------------------------------------------------------ engine touches (tests replace)
-- Face a point: camera yaw (as move.lua steers) + a small movement input toward it, because the body
-- turns only toward movement (bOrientRotationToMovement; gather.lua does the same nudge).
function W.face(api, pos, nudge)
    api.aim_at(pos)
    if not nudge then return end
    local s = api.module("sense")
    local pawn = s and s.local_pawn and s.local_pawn()
    local here = api.my_position()
    if not (pawn and here and pos) then return end
    local dx, dy = pos[1] - here[1], pos[2] - here[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.05 then return end
    pcall(function() pawn:AddMovementInput({ X = dx / l, Y = dy / l, Z = 0 }, M.cfg.nudge_scale, false) end)
end

-- What the game's interaction detector targets now (inventory.interact_target(pawn): no log arg).
function W.detector(api)
    local inv = api.module("inventory")
    local s = api.module("sense")
    if not (inv and inv.interact_target) then return nil end
    local ok, d = pcall(inv.interact_target, s and s.local_pawn and s.local_pawn() or nil)
    return ok and type(d) == "table" and d or nil
end

local function guid_key(g)
    if g == nil then return nil end
    local ok, k = pcall(function()
        local x = g.InnerGuid or g
        local a, b, c, d = x.A, x.B, x.C, x.D
        if type(a) ~= "number" then return nil end
        return string.format("%d:%d:%d:%d", a, b, c, d)
    end)
    return ok and k or nil
end
M._guid_key = guid_key

-- Is this gravestone Claude's own? true | false | nil (unknown). AGravestone:GetOwningCharacterGuid()
-- vs ADominionPlayerControllerBase:GetCharacterGuid() (both FDomCharacterGuid{InnerGuid}; reflection
-- dump 26161880). UNVERIFIED live: when either read fails the answer is nil and recover_grave only
-- takes a grave when it is the only one around.
function W.grave_owner(api, thing)
    local a = api.actor_of(thing)
    local s = api.module("sense")
    local pc = s and s.local_pc and s.local_pc()
    if not (a and pc) then return nil end
    local og = guid_key(select(2, pcall(function() return a:GetOwningCharacterGuid() end)))
    local mine = guid_key(select(2, pcall(function() return pc:GetCharacterGuid() end)))
    if not (og and mine) then return nil end
    return og == mine
end

-- ------------------------------------------------------------------ pawn ownership (arbiter)
local function arbiter(api)
    local A = api.module("arbiter")
    return A and type(A.request) == "function" and A or nil
end

-- job.own: nil (not yet) | "owner" | "suspended" | "waiting" (reflex busy) | "none" (no arbiter)
local function acquire(api, job)
    if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
    local A = arbiter(api)
    if not A then job.own = "none"; return true end
    local r = A.request(api.log, { name = "skill:" .. job.kind, level = job.level or "command", uses_move = true,
                                   lease_s = M.cfg.lease_s, resumable = true,
                                   on_suspend = function() job.own = "suspended" end,
                                   on_resume = function() job.own = "owner"; job.resumed = true; return true end,
                                   on_stop = function(_, _, why) if job.own ~= "released" then job.stopped = why or "stopped" end end })
    if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
    job.own = "waiting"
    return false
end

local function release(api, job, why)
    if job.token and job.own ~= "released" then
        local A = arbiter(api)
        job.own = "released"
        if A then pcall(A.release, api.log, job.token, why) end
    end
end

-- nil = carry on; false = wait (a reflex has the pawn; the action timer is held); result = stop now
local function hold(api, job, a)
    if paused() then a.started = api.now(); return false end
    if job.stopped then return api.fail("interrupted", { why = job.stopped,
        detail = "Something else took over (" .. tostring(job.stopped) .. "), so I stopped." }) end
    if not acquire(api, job) or job.own == "suspended" or api.reflex_owns_pawn() then
        a.started = api.now() -- fighting back (or waiting for the fight to end): the job's clock stops
        return false
    end
    if job.token then local A = arbiter(api); if A and A.renew then pcall(A.renew, job.token) end end
    if job.resumed then job.resumed = nil; return "resumed" end
    return nil
end

-- ------------------------------------------------------------------ sentences
local WHY_WORDS = {
    no_route = "there's no way I can walk there",
    leader_above_jump_height = "it's higher up than I can jump",
    leader_windstepped = "you Windstepped over somewhere I can't follow yet",
    leader_double_jumped = "you double-jumped somewhere I can't follow yet",
    stuck = "I keep getting stuck on the way",
    unreachable = "I can't find a way there",
    timeout = "it's taking far too long to get there",
}
local function why_words(why)
    why = tostring(why or "")
    if WHY_WORDS[why] then return WHY_WORDS[why] end
    local mv = why:match("^needs:(%w+)")
    if mv then return "I'd need " .. mv:gsub("(%l)(%u)", "%1 %2") .. " to get there, and I can't do that yet" end
    return "I can't find a way there"
end
M.why_words = why_words

local function move_failure(api, res, what, data)
    local why = res.reason or res.why or "path_blocked"
    local d = copy(data)
    d.why, d.dist_m = why, res.dist_m
    d.detail = "I can't get to " .. what .. ": " .. why_words(why) .. "."
    local code = api.reason_code(why)
    if code == "body_error" or code == why and not (code == "path_blocked" or code == "timeout") then code = "path_blocked" end
    return api.fail(code, d)
end

-- ------------------------------------------------------------------ the shared "use a thing" episode
-- thing = a look/census row (id, name, item, position, kind, category); opts.accept(det) -> bool (the
-- detector targets something that serves this episode, e.g. any world item of the wanted item id).
-- Phases: approach -> face -> verify; poll(t) -> nil (working) | result.
local function same_target(thing, det)
    if not det or det.none then return false end
    if det.actor ~= nil and det.actor == thing.id then return true end
    if tostring(thing.id):sub(1, 4) == "fol:" then -- foliage has no actor until the server converts it
        return (det.name ~= nil and det.name == thing.name) or (det.item ~= nil and det.item == thing.item)
    end
    return false
end
M._same_target = same_target

local function new_episode(api, thing, opts)
    opts = opts or {}
    return { thing = thing, phase = "approach", moving = false, approaches = 0, presses = 0, tol = M.cfg.approach_m,
             before = api.counts() or {}, accept = opts.accept, label = opts.label or thing.name or "that" }
end

local function gained(before, now, want)
    local best, n, all = nil, 0, {}
    for k, v in pairs(now or {}) do
        local d = v - (before[k] or 0)
        if d > 0 then
            all[k] = d
            if (not want or k == want) and d > n then best, n = k, d end
        end
    end
    return best, n, all
end

local function episode_poll(api, e, t)
    local th = e.thing
    if e.phase == "approach" then
        local here = api.my_position()
        local d = here and th.position and dist2d(here, th.position)
        if d and d <= math.max(M.cfg.reach_m, e.tol + 0.3) and not (e.tight and d > M.cfg.close_m + 0.3) then
            e.phase, e.face_until, e.moving = "face", t + M.cfg.face_s, false
            W.face(api, th.position, false) -- look at it first (the camera), as a player turns to what he wants
            return nil
        end
        if not e.moving then
            if e.approaches >= M.cfg.approaches then
                return api.fail("too_far", { target = th.id, distance = d,
                    detail = "I can't get close enough to the " .. e.label .. "." })
            end
            local mr = api.call("move", "go_to", th.position, { tolerance_m = e.tol, timeout_s = 60 })
            if not mr.ok then return mr end
            e.moving, e.approaches = true, e.approaches + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        e.moving = false
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "arrived" then return nil end -- re-check the distance next tick
        if res.status == "stopped" then return nil end -- e.g. suspended by a reflex and resumed: walk again
        return move_failure(api, res, "the " .. e.label, { target = th.id })
    elseif e.phase == "face" then
        local det = W.detector(api)
        e.detector = det
        if same_target(th, det) or (det and not det.none and e.accept and e.accept(det)) then
            local pr = api.call("inventory", "press_interact", e.secondary and { secondary = true } or nil)
            if not pr.ok then return pr end
            e.presses = e.presses + 1
            e.phase, e.verify_until = "verify", t + M.cfg.verify_s
            return nil
        end
        W.face(api, th.position, true)
        if t >= e.face_until then
            local here = api.my_position()
            local d = here and dist2d(here, th.position)
            if not e.tight and d and d > M.cfg.close_m + 0.2 then -- one tighter approach, then give up
                e.tight, e.tol, e.phase = true, M.cfg.close_m, "approach"
                return nil
            end
            local other = det and not det.none and (det.name or det.actor)
            return api.fail("not_interactable", { target = th.id, detector = det,
                detail = other and ("I can't get the game to target the " .. e.label .. ", it keeps picking " .. tostring(other) .. ".")
                    or ("I can't get the game to let me use the " .. e.label .. ".") })
        end
        return nil
    else -- verify
        local item, n, all = gained(e.before, api.counts(), e.want_item)
        if not item and not e.want_item then item, n, all = gained(e.before, api.counts()) end
        local gone = tostring(th.id):sub(1, 4) ~= "fol:" and api.actor_of(th) == nil and api.find_thing(th.id, 10) == nil
        if item or (gone and not e.need_gain) then
            return { ok = true, data = { target = th.id, item = item or api.null, count = n, gained = api.object(all),
                                         target_gone = gone, prompt = e.detector and e.detector.prompt or api.null } }
        end
        if t >= e.verify_until then
            if e.presses < M.cfg.presses then e.phase, e.face_until = "face", t + M.cfg.face_s; return nil end
            return api.fail("verification_failed", { target = th.id, prompt = e.detector and e.detector.prompt,
                detail = "I pressed use on the " .. e.label .. " but nothing happened." })
        end
        return nil
    end
end
M._episode_poll = episode_poll

-- ------------------------------------------------------------------ finding things
local function is_pickup(t)
    if t.category == "items" then return true end
    if t.category == "resources" then
        for _, a in ipairs(t.actions or {}) do if a == "interact" then return true end end
    end
    return false
end

-- Best pickup matching `what` (an item id or the player's words) within radius, nearest among the
-- best-scoring; skip ids in `skip`.
local function find_pickup(api, what, radius, skip)
    local things = api.census_things(radius, 60)
    if not things then return nil end
    local best, bs, bd
    for _, t in ipairs(things) do
        if is_pickup(t) and not (skip and skip[t.id]) then
            local s = (t.item == what or lower(t.name) == lower(what)) and 2 or api.match_score(t, what)
            local d = t.distance or 1e9
            if s > 0 and (not best or s > bs or (s == bs and d < bd)) then best, bs, bd = t, s, d end
        end
    end
    return best
end
M._find_pickup = find_pickup

-- A carried row for `what` (name, id, or kind food/drink/potion), preferring the hotbar and clean items.
-- item = "food" | "drink" | "potion" names the consumable DATA CLASS (inventory.consumable_kind), not words
local KINDS = { food = "food", drink = "drink", potion = "potion" }
local function inv_rows(d)
    local rows = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, it in ipairs(d[where] or {}) do local r = copy(it); r.where = where; rows[#rows + 1] = r end
    end
    return rows
end
local function find_carried(api, list, what)
    local kind = KINDS[lower(what)]
    local best, bs
    for _, r in ipairs(inv_rows(list)) do
        local s
        if kind then s = (r.consumable == kind) and 1 or 0
        elseif r.item == what or lower(r.name) == lower(what) then s = 3
        else s = api.match_score({ name = r.name, item = r.item }, what) end
        if s > 0 then
            if r.where == "hotbar" then s = s + 0.5 end
            if r.consumable and not r.soulscourge then s = s + 0.1 end
            if not best or s > bs then best, bs = r, s end
        end
    end
    return best, kind
end
M._find_carried = find_carried

-- ------------------------------------------------------------------ job plumbing
-- A pending action for the bridge's action slot: job.step(t) -> nil | result.
local function action(api, ctx, job)
    local a = { kind = job.kind, id = ctx and ctx.id, timeout_s = M.cfg.timeout_s[job.kind] or 100 }
    a.cancel = function()
        if not paused() then api.call("move", "stop") end
        release(api, job, "cancelled")
    end
    a.poll = function(self)
        local h = hold(api, job, self)
        if h == false then return nil end
        if type(h) == "table" then release(api, job, "interrupted"); return h end
        if h == "resumed" and job.on_resume then job.on_resume() end
        local res = job.step(api.now())
        if res then
            if job.verify_final and res.ok then res = job.verify_final(res) end
            release(api, job, res.ok and "done" or tostring(res.reason))
        end
        return res
    end
    return { pending = a }
end

local function resume_episode(job) return function() if job.ep then job.ep.phase, job.ep.moving = "approach", false end end end

-- ------------------------------------------------------------------ fetch
local function start_fetch(api, args, ctx, opts)
    opts = opts or {}
    local target = args.target or args.id
    local want = args.item
    if not need_str(target) and not need_str(want) then
        return api.fail("invalid_args", { detail = "target (an id from look) or item (a name) is required" })
    end
    local count = math.max(1, math.floor(tonumber(args.count) or 1))
    local job = { kind = opts.kind or "fetch", picked = {}, total = 0, skip = {}, gains = {} }
    local first
    if need_str(target) then
        local t, r = api.find_thing(target)
        if not t then
            local d = copy(r and r.data); d.detail = "I can't see that " .. (want or "thing") .. " anywhere near me."
            return api.fail("unknown_target", d)
        end
        if not is_pickup(t) then
            return api.fail("not_interactable", { target = target, kind = t.kind, actions = t.actions,
                detail = "I can't pick up the " .. tostring(t.name or target) .. "." })
        end
        first = t
        want = want or t.item or t.name
    else
        first = find_pickup(api, want, M.cfg.fetch_radius_m) or find_pickup(api, want, M.cfg.fetch_max_radius_m)
        if not first then
            return api.fail("nothing_in_range", { item = want, radius_m = M.cfg.fetch_max_radius_m,
                detail = "I can't see any " .. tostring(want) .. " lying around here." })
        end
    end
    job.want_item = first.item -- the inventory key a pickup of it adds (nil for an unknown foliage drop)
    local function begin(t)
        job.cur = t
        job.ep = new_episode(api, t, { label = t.name,
            accept = function(det) return job.want_item ~= nil and det.item == job.want_item end })
        job.ep.want_item, job.ep.need_gain = job.want_item, true
    end
    begin(first)
    job.on_resume = resume_episode(job)
    job.step = function(t)
        local r = episode_poll(api, job.ep, t)
        if not r then return nil end
        if not r.ok then
            if job.total > 0 then -- some made it: say what we have
                return { ok = true, data = { item = job.want_item or job.item, count = job.total, want = count, partial = true,
                    picked = job.picked, gained = api.object(job.gains), stopped_because = r.reason,
                    detail = "I got " .. job.total .. " " .. tostring(job.cur.name) .. ", but " .. tostring(r.data and r.data.detail or r.reason) } }
            end
            return r
        end
        local d = r.data
        job.item = job.item or (d.item ~= api.null and d.item or nil)
        job.want_item = job.want_item or job.item
        job.total = job.total + (tonumber(d.count) or 0)
        for k, v in pairs(d.gained or {}) do job.gains[k] = (job.gains[k] or 0) + v end
        job.picked[#job.picked + 1] = job.cur.id
        job.skip[job.cur.id] = true
        if job.total >= count then
            return { ok = true, data = { item = job.want_item or job.item or api.null, count = job.total, want = count,
                picked = job.picked, gained = api.object(job.gains), name = first.name } }
        end
        local nxt = find_pickup(api, job.want_item or want, M.cfg.fetch_radius_m, job.skip)
        if not nxt then
            return { ok = true, data = { item = job.want_item or job.item or api.null, count = job.total, want = count, partial = true,
                picked = job.picked, gained = api.object(job.gains), name = first.name,
                detail = "I picked up " .. job.total .. " " .. tostring(first.name) .. "; that's all I can see." } }
        end
        begin(nxt)
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ consume
local STAT_OF = { drink = "hydration", food = "sustenance", potion = "health" }
local function stat_now(api, stat)
    local d = api.me()
    if not d then return nil end
    if stat == "health" then return tonumber(d.health) end
    local s = type(d.survival) == "table" and d.survival[stat]
    return type(s) == "table" and tonumber(s[1]) or nil
end

local function count_of(api, item)
    local c = api.counts() or {}
    return c[item] or 0
end

local function start_consume(api, args, ctx)
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required (a name, an item id, food or drink)" }) end
    local what = args.item
    local job = { kind = "consume" }
    local lr = api.call("inventory", "list")
    if not lr.ok then return lr end
    local row, kind = find_carried(api, lr.data, what)
    local function use_step(r)
        if not r.consumable then
            return api.fail("not_consumable", { item = r.item, name = r.name,
                detail = "I can't eat or drink the " .. tostring(r.name) .. "." })
        end
        if r.where ~= "hotbar" then
            return api.fail("in_bag", { item = r.item, name = r.name, offer = "move_item",
                detail = "The " .. tostring(r.name) .. " is in my bag, not on my hotbar; I can only use things from the hotbar." })
        end
        job.stat = STAT_OF[r.consumable]
        job.row, job.before, job.before_n = r, stat_now(api, job.stat), count_of(api, r.item)
        local ur = api.call("inventory", "use", r.item, { require = r.consumable, hotbar_only = true })
        if not ur.ok then
            local d = copy(ur.data); d.detail = d.detail or ("I tried to use the " .. tostring(r.name) .. " but the game didn't take it.")
            return api.fail(ur.reason == "body_error" and "body_error" or ur.reason, d)
        end
        job.until_t = api.now() + M.cfg.consume_verify_s
        job.phase = "verify"
        return nil
    end
    if not row and not kind then
        -- not carried. A primitive (PRINCIPLES 4b): say where one is, the model composes interact + consume
        local near = find_pickup(api, what, M.cfg.consume_ground_m)
        if not near then
            return api.fail("not_in_inventory", { item = what,
                detail = "I don't have any " .. what .. " on me, and I can't see one nearby." })
        end
        return api.fail("not_in_inventory", { item = what, on_ground = { id = near.id, name = near.name, distance = near.distance },
            detail = "I don't have any " .. what .. " on me yet; there's " .. tostring(near.name) .. " on the ground "
                .. tostring(near.distance and (math.floor(near.distance + 0.5) .. " m away") or "nearby") .. "." })
    elseif not row then
        return api.fail("not_in_inventory", { item = what, kind = kind,
            detail = "I don't have anything to " .. (kind == "food" and "eat" or "drink") .. " on me." })
    else
        local r = use_step(row)
        if r then return r end
    end
    job.on_resume = function() if job.fetch and job.fetch.on_resume then job.fetch.on_resume() end end
    job.step = function(t)
        if job.phase == "fetch" then
            local fr = job.fetch.step(t)
            if not fr then return nil end
            if not fr.ok then return fr end
            local l2 = api.call("inventory", "list")
            if not l2.ok then return l2 end
            local got = fr.data.item ~= api.null and fr.data.item or nil
            local r2 = got and find_carried(api, l2.data, got) or find_carried(api, l2.data, what)
            if not r2 then return api.fail("verification_failed", { detail = "I picked it up but can't find it in my inventory." }) end
            job.fetched = true
            return use_step(r2)
        end
        local now_v, now_n = stat_now(api, job.stat), count_of(api, job.row.item)
        local rose = now_v and job.before and now_v > job.before + 0.5
        local used = now_n < job.before_n
        if rose or (used and t >= job.until_t - M.cfg.consume_verify_s / 2) then
            return { ok = true, data = { item = job.row.item, name = job.row.name, kind = job.row.consumable, stat = job.stat,
                before = job.before, after = now_v, stat_rose = rose == true, count_left = now_n, fetched = job.fetched == true } }
        end
        if t >= job.until_t then
            if used then
                return { ok = true, data = { item = job.row.item, name = job.row.name, kind = job.row.consumable, stat = job.stat,
                    before = job.before, after = now_v, stat_rose = false, count_left = now_n, fetched = job.fetched == true } }
            end
            return api.fail("verification_failed", { item = job.row.item, stat = job.stat, before = job.before, after = now_v,
                detail = "I tried to use the " .. tostring(job.row.name) .. " but my " .. tostring(job.stat) .. " didn't go up." })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ come_to
local function player_row(api, name)
    local things = api.census_things(150, 20)
    for _, t in ipairs(things or {}) do
        if t.category == "players" and (t.name == name or t.id == name) then return t end
    end
    return nil
end

local function start_come_to(api, args, ctx, opts)
    opts = opts or {}
    local who = args.player
    if not need_str(who) then return api.fail("invalid_args", { detail = "player is required" }) end
    local dist = math.max(1, tonumber(args.distance) or M.cfg.come_to_m)
    local job = { kind = opts.kind or "come_to", phase = "start" }
    local function begin()
        local r = api.call("move", "follow", who, dist)
        if not r.ok then return r end
        if r.data.target_visible == false then
            api.call("move", "stop")
            return api.fail("unknown_target", { player = who,
                detail = "I can't see where you are from here, " .. who .. " (you're too far away for me to see)." })
        end
        job.phase, job.since = "walk", api.now()
        return nil
    end
    local r0 = begin()
    if r0 then return r0 end
    job.on_resume = function() job.phase = "start" end
    job.step = function(t)
        if job.phase == "start" then return begin() end
        local st = api.move_status()
        if st.mode ~= "follow" then
            local res = type(st.result) == "table" and st.result or {}
            if res.status == "failed" then return move_failure(api, res, who, { player = who }) end
            job.phase = "start" -- stopped underneath us (e.g. a reflex suspend): start again
            return nil
        end
        if st.status == "near" then
            local here, p = api.my_position(), player_row(api, who)
            local d = here and p and dist2d(here, p.position)
            if d and d <= dist + 1.5 then
                api.call("move", "stop")
                return { ok = true, data = { player = who, dist_m = math.floor(d * 10 + 0.5) / 10, position = here,
                                             target_position = p.position, arrive_tolerance = dist + 1.5 } }
            end
            return nil
        end
        if st.status == "unreachable" or st.unreachable then
            job.unreach_since = job.unreach_since or t
            if t - job.unreach_since >= M.cfg.come_to_unreachable_s then
                local u = st.unreachable or {}
                api.call("move", "stop")
                return move_failure(api, { reason = u.reason or "no_route", dist_m = st.dist_m }, "you", { player = who,
                    leader_pos = u.leader_pos, my_pos = u.my_pos })
            end
        else
            job.unreach_since = nil
        end
        if t - job.since > M.cfg.come_to_timeout_s - 5 then
            api.call("move", "stop")
            return move_failure(api, { reason = "timeout", dist_m = st.dist_m }, "you", { player = who })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ recover_grave
local function grave_of(api, rows)
    local graves, mine, unknown = {}, nil, 0
    for _, r in ipairs(rows or {}) do
        if tostring(r.class or ""):find("Gravestone", 1, true) then
            graves[#graves + 1] = r
            local own = W.grave_owner(api, r)
            if own == true and (not mine or (r.distance or 0) < (mine.distance or 0)) then mine = r; r.owner_check = "verified" end
            if own == nil then unknown = unknown + 1 end
        end
    end
    if not mine and #graves == 1 and unknown == 1 then mine = graves[1]; mine.owner_check = "unverified" end
    return mine, #graves - (mine and 1 or 0)
end
M._grave_of = grave_of

local function is_grave(t) return t.category == "interactables" and tostring(t.class or ""):find("Gravestone", 1, true) ~= nil end

local function start_recover_grave(api, args, ctx)
    local things = api.census_things(M.cfg.grave_radius_m, 60)
    if not things then return api.fail("companion_down", { detail = "I can't look around right now." }) end
    local rows = {}
    for _, t in ipairs(things) do if is_grave(t) then rows[#rows + 1] = t end end
    local mine, others = grave_of(api, rows)
    if not mine then
        if #rows == 0 then
            return api.fail("nothing_in_range", { radius_m = M.cfg.grave_radius_m,
                detail = "I can't see my grave anywhere near here." })
        end
        local any_unknown = false
        for _, r in ipairs(rows) do if W.grave_owner(api, r) == nil then any_unknown = true end end
        return api.fail(any_unknown and "ambiguous_target" or "nothing_in_range", { graves = others,
            detail = any_unknown and "There are several graves here and I can't tell which one is mine."
                or "The graves around here aren't mine, and I won't touch other people's." })
    end
    local job = { kind = "recover_grave", grave = mine, phase = "grave" }
    job.ep = new_episode(api, mine, { label = "grave" })
    job.ep.need_gain = false
    job.on_resume = resume_episode(job)
    local mem = memory()
    job.step = function(t)
        if job.phase == "equip" then -- re-equip the tool he held before he died (best effort, never fails the job)
            local lr = api.call("inventory", "list")
            local held = lr.ok and type(lr.data.held) == "table" and lr.data.held or {}
            if held.right_item == job.want_held or held.left_item == job.want_held then
                job.result.data.reequipped = job.want_name or job.want_held
                return job.result
            end
            if t >= job.equip_until then
                job.result.data.reequipped, job.result.data.reequip_failed = false, job.want_name or job.want_held
                return job.result
            end
            return nil
        end
        local r = episode_poll(api, job.ep, t)
        if not r then return nil end
        if not r.ok then return r end
        local d = r.data
        d.grave, d.items = mine.id, d.gained
        local n = 0
        for _, v in pairs(d.gained or {}) do n = n + v end
        d.count = n
        if n == 0 then
            return api.fail("verification_failed", { grave = mine.id,
                detail = "I used my grave but nothing came back into my inventory." })
        end
        job.result = { ok = true, data = d }
        local lh = mem.last_held
        if lh and lh.item then
            local lr = api.call("inventory", "list")
            local held = lr.ok and type(lr.data.held) == "table" and lr.data.held or {}
            local holding = held.right_item or held.left_item
            if not holding and lr.ok and find_carried(api, lr.data, lh.item) then
                local er = api.call("inventory", "equip", lh.item)
                if er.ok then
                    job.phase, job.want_held, job.want_name, job.equip_until = "equip", lh.item, lh.name, t + 3
                    return nil
                end
                d.reequipped, d.reequip_failed = false, lh.name or lh.item
            end
        end
        return job.result
    end
    return job
end

-- ------------------------------------------------------------------ give
local function start_give(api, args, ctx)
    if not need_str(args.player) or not need_str(args.item) then
        return api.fail("invalid_args", { detail = "player and item are required" })
    end
    local n = math.floor(tonumber(args.count) or 0)
    if n < 1 then return api.fail("invalid_args", { detail = "count must be >= 1" }) end
    local lr = api.call("inventory", "list")
    if not lr.ok then return lr end
    local row = find_carried(api, lr.data, args.item)
    if not row then
        return api.fail("not_in_inventory", { item = args.item,
            detail = "I don't have any " .. args.item .. " to give you." })
    end
    local have = count_of(api, row.item)
    if have < n then
        return api.fail("not_enough_resources", { item = row.item, have = have, want = n,
            detail = "I only have " .. have .. " " .. tostring(row.name) .. "." })
    end
    local job = { kind = "give", phase = "walk", row = row }
    local walk = start_come_to(api, { player = args.player, distance = M.cfg.give_m }, ctx, { kind = "give" })
    if walk.ok == false then return walk end
    job.walk = walk
    job.on_resume = function() if job.phase == "walk" then walk.on_resume() end end
    job.step = function(t)
        if job.phase == "walk" then
            local r = walk.step(t)
            if not r then return nil end
            if not r.ok then return r end
            job.before = count_of(api, row.item)
            local dr = api.call("inventory", "drop", row.item, n)
            if not dr.ok then return dr end
            job.phase, job.until_t = "verify", t + M.cfg.give_wait_s
            return nil
        end
        local now_n = count_of(api, row.item)
        if now_n <= job.before - n then
            return { ok = true, data = { item = row.item, name = row.name, count = n, player = args.player, at = "feet",
                                         inventory_left = now_n } }
        end
        if t >= job.until_t then
            return api.fail("verification_failed", { item = row.item, count = n,
                detail = "I dropped the " .. tostring(row.name) .. " but it didn't leave my inventory." })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ interact (generic, any look id)
local function start_interact(api, args, ctx)
    local id = args.target or args.id
    if not need_str(id) then return api.fail("invalid_args", { detail = "target is required (an id from look)" }) end
    local t, r = api.find_thing(id)
    if not t then
        local d = copy(r and r.data); d.detail = d.detail or "I can't see that anywhere near me."
        return api.fail(r and r.reason or "unknown_target", d)
    end
    local can = false
    for _, act in ipairs(t.actions or {}) do if act == "interact" then can = true end end
    if not can then return api.fail("not_interactable", { target = id, kind = t.kind, actions = t.actions,
        detail = "There's nothing I can do with the " .. tostring(t.name or id) .. " by pressing use." }) end
    local job = { kind = "interact" }
    job.ep = new_episode(api, t)
    job.ep.secondary = args.secondary == true
    job.on_resume = resume_episode(job)
    job.step = function(tt) return episode_poll(api, job.ep, tt) end
    return job
end

-- ------------------------------------------------------------------ get_state extras (honest perception)
-- Called by the bridge's get_state with the state it built. Adds:
--   my_grave   {id, name, distance, position, items (total count), contents ["Torch x1", ...], owner}
--              owner = "verified" (owner guid = ours) | "unverified" (unreadable, the only grave around)
--   other_graves  n graves that are someone else's (or can't be told apart)
--   last_death {ago_s, respawned}  from the vitals watcher's death/revive rows (client_bridge forward_vitals)
--   last_held  the tool he held last (name)

function M.state_extras(api, data)
    local mem, out = memory(), {}
    local null = api.null
    if type(data.held_item) == "string" and data.held_item ~= "" then
        mem.last_held = { item = data.held_item, name = type(data.held) == "string" and data.held or data.held_item }
    end
    if mem.last_held then out.last_held = mem.last_held.name end
    local inv = api.module("inventory")
    if inv and type(inv.vitals_policy) == "function" then
        local okp, pol = pcall(inv.vitals_policy)
        if okp and type(pol) == "table" then
            out.vitals_policy = { drink_below_pct = pol.drink_below_pct, eat_below_pct = pol.eat_below_pct,
                                  heal_below_pct = pol.heal_below_pct or api.null, reserve_warn = pol.reserve_warn,
                                  safety_floor_pct = inv.SAFETY_FLOOR_PCT }
        end
    end
    local g, others = grave_of(api, data.interactables)
    if g then
        local contents = api.contents_of(g) or {}
        local names, n = {}, 0
        for _, c in ipairs(contents) do
            n = n + (tonumber(c.count) or 1)
            names[#names + 1] = tostring(c.name or c.item) .. " x" .. tostring(c.count or 1)
        end
        out.my_grave = { id = g.id, name = g.name, distance = g.distance, position = g.position, items = n,
                         contents = names, owner = g.owner_check }
    end
    if others > 0 then out.other_graves = others end
    local life = rawget(_G, "DW_LIFE")
    if type(life) == "table" and life.died_at then
        out.last_death = { ago_s = math.max(0, math.floor(api.now() - life.died_at)), respawned = life.respawned_at ~= nil }
    end
    return out
end

-- Module functions each skill composes (client_bridge lists a skill only while they all exist).
local FIND = { { "sense", "census" }, { "inventory", "list" }, { "inventory", "interact_target" }, { "inventory", "press_interact" },
               { "move", "go_to" }, { "move", "status" } }
local function plus(base, more) local o = {}; for _, x in ipairs(base) do o[#o + 1] = x end; for _, x in ipairs(more) do o[#o + 1] = x end; return o end
M.NEEDS = {
    fetch = FIND,
    interact = FIND,
    recover_grave = FIND,
    consume = { { "sense", "census" }, { "sense", "me" }, { "inventory", "list" }, { "inventory", "use" } },
    come_to = { { "sense", "census" }, { "move", "follow" }, { "move", "status" }, { "move", "stop" } },
    give = { { "sense", "census" }, { "inventory", "list" }, { "inventory", "drop" }, { "move", "follow" }, { "move", "status" },
             { "move", "stop" } },
    move_item = { { "inventory", "list" }, { "inventory", "move" } },
    set_vitals_policy = { { "inventory", "set_vitals_policy" } },
    equip = { { "inventory", "list" }, { "inventory", "equip" } },
}

-- ------------------------------------------------------------------ handlers
local STARTERS ={ fetch = start_fetch, consume = start_consume, come_to = start_come_to, recover_grave = start_recover_grave,
                   give = start_give, interact = start_interact }
M.STARTERS = STARTERS

local function handler(name)
    return function(log, args, ctx)
        local api = ctx and ctx.api
        if not api then return { ok = false, reason = "body_error", data = { detail = "skills need the bridge api (ctx.api)" } } end
        if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
        local job = STARTERS[name](api, args or {}, ctx)
        if job.ok == false then return job end
        return action(api, ctx, job)
    end
end

M.HANDLERS = { skills_status = function() return { ok = true, data = { cfg = M.cfg, tools = { "interact", "consume", "move_item", "equip",
                                                                                               "fetch", "come_to", "recover_grave", "give" } } } end }
for name in pairs(STARTERS) do M.HANDLERS[name] = handler(name) end

-- ------------------------------------------------------------------ inventory primitives (no pawn: waiters)
-- move_item(item, to = hotbar|bag): the inventory UI's drag (inventory.move); verified once the item is
-- listed in that page. equip(item): the hotbar key / inventory use (inventory.equip); verified once it
-- is in his hands or in the loadout.
local function where_is(api, item)
    local lr = api.call("inventory", "list")
    if not lr.ok then return nil end
    local row = find_carried(api, lr.data, item)
    local held = type(lr.data.held) == "table" and lr.data.held or {}
    local equipped = false
    for _, e in ipairs(lr.data.loadout or {}) do if e.item == item or e.name == item then equipped = true end end
    return row, held, equipped, lr.data
end

M.HANDLERS.move_item = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required" }) end
    local to = lower(args.to or "hotbar")
    local page = ({ hotbar = "hotbar", bag = "bag" })[to]
    if not page then return api.fail("invalid_args", { detail = "to must be hotbar or bag" }) end
    local row = where_is(api, args.item)
    if not row then return api.fail("not_in_inventory", { item = args.item, detail = "I don't have any " .. args.item .. "." }) end
    if row.where == page then return { ok = true, data = { item = row.item, name = row.name, to = page, already = true } } end
    local r = api.call("inventory", "move", row.item, page, args.slot)
    if not r.ok then
        local d = copy(r.data); d.detail = d.detail or ("I couldn't move the " .. tostring(row.name) .. " to my " .. page .. ".")
        return api.fail(r.reason, d)
    end
    local w = { kind = "move_item" }
    w.poll = function()
        local now = where_is(api, row.item)
        if now and now.where == page then return { ok = true, data = { item = row.item, name = row.name, to = page } } end
        return nil
    end
    w.expire = function()
        return api.fail("verification_failed", { item = row.item, detail = "I tried to move the " .. tostring(row.name)
            .. " to my " .. page .. " but it didn't move." })
    end
    return { wait = w, wait_s = 4 }
end

-- set_vitals_policy: WHEN the stay-fed reflex eats/drinks/heals is the model's decision (inventory.lua
-- vitals policy); a safety floor stays in code. Answers with the policy read back.
M.HANDLERS.set_vitals_policy = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    local r = api.call("inventory", "set_vitals_policy", args or {})
    return r
end

M.HANDLERS.equip = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required" }) end
    local row, held, equipped = where_is(api, args.item)
    if not row and not equipped then return api.fail("not_in_inventory", { item = args.item, detail = "I don't have any " .. args.item .. "." }) end
    local item = row and row.item or args.item
    if equipped or held.right_item == item or held.left_item == item then
        return { ok = true, data = { item = item, already = true } }
    end
    local r = api.call("inventory", "equip", item)
    if not r.ok then
        local d = copy(r.data); d.detail = d.detail or ("I couldn't equip the " .. tostring(row and row.name or item) .. ".")
        return api.fail(r.reason, d)
    end
    local w = { kind = "equip" }
    w.poll = function()
        local _, h, eq = where_is(api, item)
        if eq or (h and (h.right_item == item or h.left_item == item)) then
            return { ok = true, data = { item = item, name = row and row.name, held = h and (h.right or h.left) } }
        end
        return nil
    end
    w.expire = function()
        return api.fail("verification_failed", { item = item, detail = "I tried to equip the " .. tostring(row and row.name or item)
            .. " but it isn't in my hands or worn." })
    end
    return { wait = w, wait_s = 4 }
end

-- ------------------------------------------------------------------ manifest entries (client_mod/scripts/manifest.lua shape)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
local function str(desc) return { type = "string", description = desc } end
local SPEAKS = true
-- PRINCIPLES 4b (Luis): primitives first, the MODEL composes ("walk to him" + "drop the logs"). Offered
-- to the LLM: interact (frame-coupled: approach + face + press + verify), consume, move_item, equip (and
-- the bridge's go_to / follow / stop / drop / look / inspect / inventory). The compounds fetch, come_to,
-- recover_grave and give stay as tested debug tools (llm = false), not offered.
local COMPOUND = " (Compound kept for debugging; the model composes the primitives instead.)"
M.MANIFEST = {
    interact = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 110,
        detail_is_speech = SPEAKS, aliases = { "pickup" },
        description = "Use one thing like a player pressing E: walks to it, faces it until the game targets it, presses "
            .. "use and checks something changed. Picks up an item stack lying on the ground (into your inventory), takes "
            .. "everything from a gravestone ('Take All'), opens, talks, collects plants. One id per call.",
        args = { type = "object", required = { "target" }, properties = obj({
            target = str("An id from situation or look whose actions include interact."),
            secondary = { type = "boolean", default = false,
                description = "Use the thing's SECOND action instead (the F key), when look/inspect shows one, e.g. "
                    .. "collect-all on a dropped stack picks up every nearby stack of that kind at once." } }) },
        ground = obj({ target = "thing" }),
        reasons = { "unknown_target", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    consume = { kind = "action", llm = true, moves = false, priority = "command", duration_s = 3, timeout_s = 30,
        detail_is_speech = SPEAKS,
        description = "Eat or drink one item from your HOTBAR, then check the stat it restores went up. Items in the bag "
            .. "must be moved to the hotbar first (move_item); items on the ground picked up first (interact).",
        args = { type = "object", required = { "item" }, properties = obj({
            item = str("The carried item's name or id, or just 'food' / 'drink' / 'potion' (its kind).") }) },
        ground = obj({ item = "carried" }),
        reasons = { "in_bag", "not_in_inventory", "not_consumable", "verification_failed" } },
    move_item = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = SPEAKS,
        description = "Move a carried item between your bag and your hotbar (as dragging it in the inventory). Only "
            .. "hotbar food/drink can be eaten, so move food there first.",
        args = { type = "object", required = { "item", "to" }, properties = obj({
            item = str("A carried item's name or id."),
            to = { type = "string", enum = { "hotbar", "bag" }, description = "Where to put it." },
            slot = { type = "integer", minimum = 0, description = "Optional slot number in that page (default: first free)." } }) },
        ground = obj({ item = "carried" }),
        reasons = { "not_in_inventory", "inventory_full", "verification_failed", "invalid_args" } },
    equip = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = SPEAKS,
        description = "Equip a carried weapon, tool or armour piece (hotbar key or inventory use); checks it is in your "
            .. "hands or worn.",
        args = { type = "object", required = { "item" }, properties = obj({ item = str("A carried item's name or id.") }) },
        ground = obj({ item = "carried" }),
        reasons = { "not_in_inventory", "verification_failed" } },
    set_vitals_policy = { kind = "waiter", llm = true, moves = false, duration_s = 0, timeout_s = 10,
        description = "Set WHEN your stay-fed reflex eats, drinks and heals by itself (percent of each maximum). Decide it "
            .. "from your vitals, your food/drink stock, threats and the job: e.g. top up before a fight, save food when "
            .. "stock is low, eat to heal after a fight. A safety floor (10%) always applies.",
        args = { type = "object", properties = obj({
            drink_below_pct = { type = "number", minimum = 10, maximum = 95, description = "Drink when hydration is below this % of max." },
            eat_below_pct = { type = "number", minimum = 10, maximum = 95, description = "Eat when food is below this % of max." },
            heal_below_pct = { type = "number", minimum = 0, maximum = 95,
                description = "Also eat healing food when HP is below this % (0 = never eat just to heal)." },
            reserve_warn = { type = "integer", minimum = 0, maximum = 20, description = "Warn when fewer usable items than this." } }) },
        reasons = { "invalid_args" } },
    fetch = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 8, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Pick up items lying on the ground by name or id (find, walk, face, use, verify; repeats for count)." .. COMPOUND,
        args = { type = "object", properties = obj({
            target = str("An id from situation or look (a world item or ground pickup)."),
            item = str("What to pick up, by name or item id."),
            count = { type = "integer", minimum = 1, maximum = 20, default = 1, description = "How many items." } }) },
        reasons = { "unknown_target", "nothing_in_range", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    come_to = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 15, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Walk to a player and stop next to them (persistent follow until near)." .. COMPOUND,
        args = { type = "object", required = { "player" }, properties = obj({
            player = str("The player's exact name."),
            distance = { type = "number", minimum = 1, maximum = 10, default = 2, description = "Stop this close, metres." } }) },
        reasons = { "unknown_target", "path_blocked", "timeout", "interrupted" } },
    recover_grave = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 20, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Go to your own gravestone, Take All, verify, re-equip the last held tool." .. COMPOUND,
        args = { type = "object", properties = obj() },
        reasons = { "nothing_in_range", "ambiguous_target", "path_blocked", "not_interactable", "verification_failed", "timeout" } },
    give = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 15, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Walk to a player and drop carried items at their feet." .. COMPOUND,
        args = { type = "object", required = { "player", "item", "count" }, properties = obj({
            player = str("The player's exact name."), item = str("A carried item's name or id."),
            count = { type = "integer", minimum = 1, description = "How many." } }) },
        reasons = { "not_in_inventory", "not_enough_resources", "path_blocked", "unknown_target", "verification_failed", "timeout" } },
}

return M
