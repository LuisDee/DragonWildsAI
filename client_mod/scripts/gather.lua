-- gather: Claude gathers like a player on his own CLIENT (route R2, task R2.17). Real player paths only:
--   * find:    sense.foliage (standing trees / bushes / pickups are foliage instances on the client)
--              + replicated actors (converted trees, felled trunks, log pieces, rocks, ground
--              resources) + dropped WorldItems of the counted item;
--   * tool:    the right tool from HIS OWN inventory (weapons_data cat axe/pickaxe, tier vs the live
--              gate), equipped with the hotbar number key (inventory.equip);
--   * move:    move.lua's public API only (go_to), through the control arbiter at level "task", so the
--              combat reflex pre-empts a gather and the gather resumes afterwards;
--   * aim:     the camera (PlayerController:SetControlRotation) plus a short movement nudge, because the
--              body turns only toward movement (bOrientRotationToMovement); the chop wedge sits ~35 deg
--              right of the body's forward (calibrated on the server puppet, DISCOVERIES "Gather: hit
--              calibration"), other aims are tried in turn when swings do nothing;
--   * swing:   the pawn's own IA_PrimaryAction, injected through combat.lua's helper (combat.inject /
--              combat.actions: the SAME Enhanced Input path as fights, not a fork);
--   * chain:   standing tree -> (server converts it) -> stump + felled tree -> splittable logs -> logs
--              -> item drops -> the item magnet / the interact key (inventory.press_interact);
--   * verify:  progress = HIS inventory count of the item (inventory.list), never our own tally.
-- Never calls server RPCs, never converts foliage, never emulates damage.
--
-- Prior art (search-before-building, DISCOVERIES "Client gathering (R2)"): mineflayer-collectblock
-- (nearest target first; tool via mineflayer-tool equipForBlock before dig; drops within the block
-- become new targets; cancel = stop pathing), Baritone MineProcess (count the inventory each tick,
-- stop at the desired quantity, blacklist the closest target when pathing fails, rescan, give up when
-- nothing is known), the legacy server gather (mod/body/gather.lua: profiles, chain, reach, aim).
-- Decision: ADAPT those shapes; BUILD the thin Lua loop over the existing client modules.
--
-- Entry points (log = DWClient text logger):
--   M.start(log, args, ctx) args = {resource, count (MORE to collect), radius (m), stumps (bool)}
--   M.stop(log, why)   M.status()   M.HANDLERS = {gather (async {pending}), gather_status}
-- Failure reasons (brain/interface.py Reason) with data.why (specific) and data.detail (a sentence):
--   wrong_tool (no_tool | tool_tier_too_low), nothing_in_range (no_resource_nearby), inventory_full,
--   path_blocked (unreachable | swing_no_effect), interrupted, companion_down, timeout,
--   unknown_target (unknown_resource), invalid_args, body_error (inputs_not_reaching_game)
-- Events: client_io/events/gather.jsonl {"type":"gather_progress", task_id, resource, item, have, want}
--   and {"type":"gather_status", task_id, phase, detail} (one per phase change, at most every 2 s).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    radius_m = 30, max_radius_m = 90, widen = 1.5,
    decide_s = 0.1,
    tap_frames = 3,
    press_jitter_ms = { 60, 220 },
    settle_s = 0.35,            -- stand still this long before a swing (swings while moving point along the path)
    face_err_deg = 15, face_max_s = 1.2, nudge_scale = 0.25,
    -- aim offsets to try (deg, + = target to the RIGHT of the body's forward); the first is the prior
    aim_offsets = { axe = { 35, 0, 20, -20 }, pickaxe = { 0, 25, -25, 35 }, default = { 0, 30, -30 } },
    no_effect_swings = 3,       -- verified swings with no damage before the next aim
    sides = 2,                  -- stand points tried around a target (each with every aim)
    unverified_presses = 6,     -- presses with no stamina spent and no damage in a row: input broken
    approach_timeout_s = 40,
    near_enough_cm = 90,        -- a failed approach that ended this close beyond reach still swings
    bad_ttl_s = 600, bad_streak = 3,
    equip_wait_s = 4, equip_repress_s = 1.5,
    collect_wait_s = 2.0, collect_presses = 3, collect_press_gap_s = 0.7, collect_tol_m = 0.8, collect_max_s = 12,
    drop_wait_s = 1.2,          -- after a piece breaks, let its drops land before scanning
    settle_max_s = 10, step_back_m = 2.5,
    adopt_cm = 200,             -- a converted actor this close to a foliage instance is that instance
    timeout_base_s = 120, timeout_per_unit_s = 30, timeout_max_s = 1700,
    count_every_s = 1.0,
    stamina_margin = 2,
    lease_s = 5,
    leftover_m = 25,            -- pieces of OUR felled trees within this are finished first
    stumps = false,             -- chopping a stump stops the tree regrowing (wiki): only when asked
}

-- ------------------------------------------------------------------ state (hot-reload safe)
local function C()
    local c = _G.DWGather
    if not c then
        c = { gen = 0, bad = {}, counts = { jobs = 0, swings = 0, hits = 0, broken = 0, collected = 0 }, log_lines = {} }
        _G.DWGather = c
    end
    return c
end
M._state = C

local rnd = math.random
local function jitter(r) return (r[1] + rnd() * (r[2] - r[1])) / 1000 end

local function say(log, msg)
    if log then pcall(log, "gather: " .. msg) end
    local c = C()
    c.log_lines[#c.log_lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.log_lines > 40 then table.remove(c.log_lines, 1) end
end

-- ------------------------------------------------------------------ sibling modules (loadfile, injectable)
local L = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua)
M.mods, M.set_modules = L.mods, L.set_modules
local mod, mcall = L.mod, L.mcall
M.mod = mod

local PROFILES
function M.profiles()
    PROFILES = PROFILES or mod("gather_profiles")
    return PROFILES
end

-- ------------------------------------------------------------------ world adapter (tests replace it)
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
function W.pc() return mcall("sense", "local_pc") end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.actors(cls) return U.find_all(cls, { skip_defaults = true }) end
function W.foliage(origin, r_cm, opts) return mcall("sense", "foliage", origin, r_cm, opts) or {} end
function W.loc(a) return U.loc(a) end
function W.alive(a) return U.alive(a) end
function W.id(a) return U.short(a) end
function W.class(a) return U.class_word(a) end
function W.hp(a) local v = U.health(a); return type(v) == "number" and v or nil end
function W.max_hp(a) local v = U.try(function() return a.HealthComponent:GetMaxHealth() end); return type(v) == "number" and v > 0 and v or nil end
function W.stump(a) return U.try(function() return a.bIsStump end) == true end
-- A rock that broke stays as a hidden actor (bDestroyActorOnZeroHealth=false) and respawns.
function W.depleted(a)
    if U.try(function() return a.bIsHidden end) == true then return true end
    local has = U.try(function() return a:HasAvailableResources() end)
    return has == false
end
function W.available(a) -- ground resources / bushes
    local v = U.try(function() return a:IsResourceAvailable() end)
    return v ~= false
end
function W.gate(a) return mcall("sense", "gate", a) end
function W.item_of(a) -- ItemData id of a ground resource / world item
    local data = U.try(function() return a.ItemData end)
    local p = U.valid(data) and U.path_of(data)
    return p and p:match("%.([%w_]+)$") or nil
end
-- Logs: the trunk meshes roll away from the actor origin (legacy DISCOVERIES), so aim at the
-- game's own GetMidPointWorldLocation (an FVector out param, filled as a flat table; read OK on the
-- dev server with the same UE4SS).
function W.aim(a)
    local origin = U.loc(a)
    if (U.class_word(a) or ""):find("Log", 1, true) then
        local mid = {}
        local ok = pcall(function() a:GetMidPointWorldLocation(mid) end)
        if ok and type(mid.X) == "number" and (mid.X ~= 0 or mid.Y ~= 0) then return { X = mid.X, Y = mid.Y, Z = mid.Z or (origin and origin.Z) or 0 } end
    end
    return origin
end
function W.drops(origin, r_cm, item)
    local out = {}
    for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do
        local p = U.loc(w)
        if p and U.dist2d(origin, p) <= r_cm then
            local id = W.item_of(w)
            if id and (not item or id == item) then
                out[#out + 1] = { actor = w, key = U.short(w), pos = p, item = id, count = U.try(function() return w:GetStackSize() end) }
            end
        end
    end
    return out
end
function W.stamina(pawn) local v = U.try(function() return pawn.StaminaComponent:GetStamina() end); return type(v) == "number" and v or nil end
function W.yaw(pawn) local r = U.try(function() return pawn:K2_GetActorRotation() end); return r and r.Yaw or 0 end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
function W.face(pc, yaw) pcall(function() pc:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }) end) end
function W.nudge(pawn, dir, scale) pcall(function() pawn:AddMovementInput(dir, scale, false) end) end
function W.actions(pawn) return mcall("combat", "actions", pawn) or {} end
function W.inject(action)
    local cb = mod("combat")
    local f = cb and (cb.inject or cb._inject)
    return f and f(action) or false
end
local json_mod
function W.emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    ev.ts = os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local line = U.try(function() return json_mod.encode(ev) end)
    if not line then return end
    local f = io.open(ROOT .. "/client_io/events/gather.jsonl", "a")
    if f then f:write(line, "\n"); f:close() end
end

-- ------------------------------------------------------------------ pure helpers (offline-tested)
local function matches(cls, match, exclude)
    cls = cls or ""
    if match and not cls:find(match) then return false end
    if type(exclude) == "string" then exclude = { exclude } end
    for _, e in ipairs(exclude or {}) do if cls:find(e) then return false end end
    return true
end
M.matches = matches

local function bearing(a, b) return math.deg(math.atan(b.Y - a.Y, b.X - a.X)) end
local function wrap(d) return (d + 540) % 360 - 180 end
M.wrap = wrap

-- Count of an item in his bag + hotbar (inventory.list rows).
function M.count_in(list, item)
    local n = 0
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if item and e.item == item then n = n + (e.count or 1) end
        end
    end
    return n
end
local function counts_of(list)
    local t = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if e.item then t[e.item] = (t[e.item] or 0) + (e.count or 1) end
        end
    end
    return t
end
M.counts_of = counts_of

-- The best tool he OWNS for a profile: {entry, tier, where} | nil, plus the best tier seen.
-- tools = weapons_data.items (cat "axe"/"pickaxe", tier). Highest tier first (fewer swings).
function M.best_tool(list, profile, tools)
    if not profile.tool then return nil end
    local best
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            local p = e.item and tools[e.item]
            if p and p.cat == profile.tool and not e.broken then
                local tier = p.tier or 1
                if not best or tier > best.tier then best = { entry = e, tier = tier, where = where, name = e.name or p.name } end
            end
        end
    end
    return best
end

local TOOL_WORD = { axe = "logging axe", pickaxe = "pickaxe" }
local function tool_word(p) return TOOL_WORD[p.tool or ""] or tostring(p.tool) end

-- ------------------------------------------------------------------ the job
local function result_of(J, ok, reason, data)
    data = data or {}
    data.resource, data.item, data.want = J.key, J.item, J.want
    data.gathered = J.gained or 0
    data.total = J.have
    data.swings, data.hits, data.broken, data.targets = J.swings, J.hits, J.broken, J.targets
    data.seconds = J.t and J.t0 and math.floor((J.t - J.t0) * 10) / 10 or nil
    data.radius_m = J.radius_cm and J.radius_cm / 100 or nil
    data.tool = J.tool and J.tool.name or nil
    data.phase_log = J.phase_log
    return { ok = ok, reason = reason, data = data }
end
M._result_of = result_of

local function set_phase(J, ph, why)
    if J.phase == ph then return end
    J.phase, J.phase_t = ph, J.t
    if ph == "aim" then J.faced_t = nil end
    J.phase_log[#J.phase_log + 1] = string.format("%.1f %s%s", (J.t or 0) - (J.t0 or 0), ph, why and (" " .. why) or "")
    if #J.phase_log > 40 then table.remove(J.phase_log, 1) end
    say(J.log, "phase " .. ph .. (why and (" (" .. why .. ")") or ""))
    if not J.status_t or (J.t or 0) - J.status_t >= 2 then
        J.status_t = J.t
        pcall(W.emit, { type = "gather_status", task_id = J.task_id, resource = J.key, phase = ph, detail = why })
    end
end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    if J.drove_move and not _G.DW_PAUSE then mcall("move", "stop", J.log) end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("end ok=%s reason=%s gained=%s/%s swings=%d hits=%d", tostring(res.ok), tostring(res.reason),
        tostring(J.gained), tostring(J.want), J.swings, J.hits))
end
M._finish = finish

local function fail(J, reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return finish(J, result_of(J, false, reason, d))
end

local function is_bad(key, t) local e = key and C().bad[key]; return e ~= nil and e > t end
local function mark_bad(J, T, why)
    local until_t = J.t + M.cfg.bad_ttl_s
    for _, k in ipairs({ T.key, T.alias }) do if k then C().bad[k] = until_t end end
    J.bad_streak = (J.bad_streak or 0) + 1
    J.last_bad = why
    say(J.log, "target " .. tostring(T.key) .. " given up: " .. tostring(why))
end

-- Inventory count (bag + hotbar); learns the item of a pickup profile from the inventory delta.
local function refresh_count(J, force)
    if not force and J.t - (J.count_t or -99) < M.cfg.count_every_s then return end
    J.count_t = J.t
    local list = mcall("inventory", "list", J.log)
    if type(list) ~= "table" or list.ok == false then return end
    J.empty_slots = list.empty_slots
    local now_counts = counts_of(list)
    if not J.item and J.profile.item_match then
        for item in pairs(now_counts) do if item:find(J.profile.item_match) then J.item = item end end
    end
    if not J.item and J.learn_item then J.item = J.learn_item end
    if not J.item then
        -- a pickup of an unknown item: the first item whose count rose since the start is it
        for item, n in pairs(now_counts) do if n > (J.inv0[item] or 0) then J.item = item; break end end
    end
    if not J.item then return end
    local have = now_counts[J.item] or 0
    local gained = have - (J.inv0[J.item] or 0)
    if gained ~= J.gained then
        J.gained, J.have = gained, have
        J.bad_streak = 0
        pcall(W.emit, { type = "gather_progress", task_id = J.task_id, resource = J.key, item = J.item, have = math.max(gained, 0), want = J.want })
    end
    J.have = have
end

-- ------------------------------------------------------------------ target selection
-- T = {key, alias, kind = "actor"|"foliage"|"drop", stage, actor, pos (aim cm), attack, reach_cm,
--      name, tier, tool, at_site}
local function actor_target(J, a, stage, spec)
    local p = W.aim(a)
    if not p then return nil end
    local g = J.profile.mode == "chop" and W.gate(a) or nil
    return { key = W.id(a), kind = "actor", stage = stage, actor = a, pos = p, attack = spec.attack or "primary",
             reach_cm = spec.reach_cm or 130, name = W.class(a), tier = g and g.tier, tool = g and g.tool,
             hp0 = W.hp(a), max_hp = W.max_hp(a) }
end

local function children_near(J, center, radius_cm, me)
    local out = {}
    for _, ch in ipairs(J.profile.children or {}) do
        if not ch.bonus or J.stumps then
            for _, a in ipairs(W.actors(ch.class)) do
                local cls = W.class(a)
                local p = W.loc(a)
                if matches(cls, ch.match, ch.exclude) and p and U.dist2d(center, p) <= radius_cm and not is_bad(W.id(a), J.t) then
                    local hp = W.hp(a)
                    local ok = hp == nil or hp > 0
                    if ch.stump then ok = ok and W.stump(a) else ok = ok and not W.stump(a) end
                    if ok then
                        local T = actor_target(J, a, ch.name, ch)
                        if T then T.d = U.dist2d(me, T.pos); out[#out + 1] = T end
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
end

local function roots_near(J, me, radius_cm)
    local root = J.profile.root
    local out, actors_at = {}, {}
    J.floating = nil
    for _, a in ipairs(W.actors(root.class)) do
        local cls = W.class(a)
        local p = W.loc(a)
        local is_it = matches(cls, root.match, root.exclude)
            or (J.profile.mode == "pickup" and J.profile.item ~= nil and W.item_of(a) == J.profile.item)
        -- a profile with root.max_above_m never walks at a target hovering above walkable ground (rune essence
        -- floating over a geyser: it must be knocked down first; live audit 2026-10-26). Measured from his own
        -- capsule centre, so "above" means out of a swing's reach from where he can stand.
        local floating = is_it and p and root.max_above_m and (p.Z - me.Z) > root.max_above_m * 100
        if floating and U.dist2d(me, p) <= radius_cm then
            J.floating = J.floating or {}
            J.floating[#J.floating + 1] = { id = W.id(a), pos = p, above_m = math.floor((p.Z - me.Z) / 10) / 10 }
            is_it = false
        end
        if is_it and p and U.dist2d(me, p) <= radius_cm then
            actors_at[#actors_at + 1] = p
            local hp = W.hp(a)
            local usable
            if J.profile.mode == "pickup" then usable = W.available(a)
            else usable = (hp == nil or hp > 0) and not W.stump(a) and not W.depleted(a) end
            if usable and not is_bad(W.id(a), J.t) then
                local T = actor_target(J, a, "root", root)
                if T then
                    if J.profile.mode == "pickup" then T.item = W.item_of(a) end
                    T.d = U.dist2d(me, T.pos); out[#out + 1] = T
                end
            end
        end
    end
    if root.foliage then
        local kinds = J.profile.mode == "pickup" and { pickup = true } or { tree = true }
        for _, r in ipairs(W.foliage(me, radius_cm, { match = root.match, exclude = root.exclude, kinds = kinds })) do
            local dup = false
            for _, p in ipairs(actors_at) do if U.dist2d(p, r._pos) < M.cfg.adopt_cm then dup = true end end
            if not dup and not is_bad(r.id, J.t) then
                out[#out + 1] = { key = r.id, kind = "foliage", stage = "root", pos = r._pos, attack = root.attack or "primary",
                                  reach_cm = root.reach_cm or 130, name = r.name, tier = r.tool_tier, tool = r.tool,
                                  d = U.dist2d(me, r._pos), max_hp = r.max_health, class = r.class, item = r.item }
            end
        end
    end
    -- nearest first, but a target well above or below his level counts as further (a ledge needs a way up:
    -- prefer the sticks at his feet over the ones on a rock 4 m up, live 2026-10-26 16:05)
    local function score(x)
        local dz = (x.pos and x.pos.Z and me.Z) and math.abs((x.pos.Z + 90) - me.Z) or 0
        return x.d + 3 * math.max(0, dz - M.cfg.stand_dz_cm)
    end
    table.sort(out, function(x, y) return score(x) < score(y) end)
    return out
end
M._roots_near = roots_near

local function drops_near(J, center, radius_cm, me)
    local out = {}
    for _, d in ipairs(W.drops(center, radius_cm, J.item)) do
        if not is_bad(d.key, J.t) and (J.item or J.profile.mode == "pickup") then
            out[#out + 1] = { key = d.key, kind = "drop", actor = d.actor, pos = d.pos, d = U.dist2d(me, d.pos), item = d.item }
        end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
end

-- Next thing to do: drops of our item near our sites/us, then pieces of our felled trees, then the
-- nearest standing root (actor or foliage) within the radius. Returns T or nil, why.
local function choose(J, me)
    local cfg = M.cfg
    -- 1. drops (ours: near a site we broke, or right next to us)
    if J.item then
        for _, s in ipairs(J.sites) do
            local d = drops_near(J, s, J.profile.collect_radius_cm or 1200, me)[1]
            if d then return d end
        end
        local d = drops_near(J, me, 400, me)[1]
        if d then return d end
    end
    -- 2. pieces of our felled trees (current site first)
    for i = #J.sites, 1, -1 do
        local s = J.sites[i]
        if U.dist2d(me, s) <= cfg.leftover_m * 100 then
            local ch = children_near(J, s, J.profile.site_radius_cm or 1200, me)[1]
            if ch then ch.at_site = s; return ch end
        end
    end
    -- 3. a new root
    local roots = roots_near(J, me, J.radius_cm)
    local too_hard
    for _, T in ipairs(roots) do
        if J.tool and T.tier and T.tier > J.tool.tier then too_hard = too_hard or T
        else return T end
    end
    if too_hard then return nil, "tool_tier_too_low", too_hard end
    if J.floating and #J.floating > 0 then return nil, "floating_only", J.floating end
    return nil, "no_resource_nearby"
end
M._choose = choose

-- ------------------------------------------------------------------ phases
local function tap(J, action, frames)
    if not action then return false end
    J.inputs[#J.inputs + 1] = { act = action, frames = frames or M.cfg.tap_frames }
    return true
end

local function start_move(J, goal_cm, tol_m, timeout_s)
    J.drove_move = true
    local me = J.me
    local far = me and U.dist2d(me, goal_cm) > 1200
    local r = mcall("move", "go_to", J.log, { goal_cm.X / 100, goal_cm.Y / 100, goal_cm.Z / 100 },
        { tolerance_m = tol_m, timeout_s = timeout_s or M.cfg.approach_timeout_s, sprint = far })
    J.move_started = J.t
    return r and r.ok ~= false
end

local function move_state()
    local st = mcall("move", "status")
    if type(st) ~= "table" then return "idle", nil end
    if st.mode == "go_to" then return "moving", st end
    return "idle", st
end

-- stand point: reach_cm from the aim point, on our side, rotated by deg around the target. Its height is the
-- TARGET's ground (pos is on the ground for pickups/foliage; + capsule half height) when that differs from ours
-- by more than a step: live 2026-10-26 16:05, branches on a ledge 4 m up were sent as a goal at Claude's own
-- height, so move planned a level walk under the ledge and could not say "it's higher than I can jump".
M.cfg.stand_dz_cm = 150
local function stand_point(T, me, deg)
    local ang = math.atan(me.Y - T.pos.Y, me.X - T.pos.X) + math.rad(deg or 0)
    local r = math.max((T.reach_cm or 130) - 15, 60)
    local z = me.Z
    if T.pos.Z and math.abs((T.pos.Z + 90) - me.Z) > M.cfg.stand_dz_cm then z = T.pos.Z + 90 end
    return { X = T.pos.X + math.cos(ang) * r, Y = T.pos.Y + math.sin(ang) * r, Z = z }
end
M._stand_point = stand_point

-- The foliage instance we walked to became an actor (the server's converter / our swing): adopt it.
local function adopt(J, T)
    if T.kind ~= "foliage" then return false end
    local root = J.profile.root
    for _, a in ipairs(W.actors(root.class)) do
        local p = W.loc(a)
        if p and U.dist2d(p, T.pos) < M.cfg.adopt_cm and matches(W.class(a), root.match, root.exclude) then
            T.kind, T.actor, T.alias = "actor", a, T.key
            T.key = W.id(a)
            T.pos = W.aim(a) or T.pos
            T.hp0 = W.hp(a)
            T.max_hp = W.max_hp(a) or T.max_hp
            local g = J.profile.mode == "chop" and W.gate(a) or nil
            if g then T.tier, T.tool = g.tier or T.tier, g.tool or T.tool end
            if J.profile.mode == "pickup" then J.learn_item = J.learn_item or W.item_of(a); T.item = W.item_of(a) end
            say(J.log, "adopted " .. tostring(T.key) .. " (was " .. tostring(T.alias) .. ") hp=" .. tostring(T.hp0))
            return true
        end
    end
    return false
end

-- Is the target finished? -> true, how
local function target_done(J, T)
    if T.kind == "drop" then return not W.alive(T.actor), "collected" end
    if T.kind ~= "actor" then return false end
    if not W.alive(T.actor) then
        if T.alias and (T.hits or 0) == 0 then
            -- an undamaged converted tree reverts to foliage after a while: chase the instance again
            T.kind, T.key, T.actor, T.alias = "foliage", T.alias, nil, nil
            return false
        end
        -- log pieces are destroyed when they break: gone right after our hits = broken by us
        if (T.hits or 0) > 0 then return true, "broken" end
        return true, "gone"
    end
    if J.profile.mode == "pickup" then return not W.available(T.actor), "picked" end
    if T.stage == "root" and J.profile.root.class == "FellableTree" then
        if W.stump(T.actor) then return true, "felled" end
    end
    local hp = W.hp(T.actor)
    if hp and hp <= 0 then return true, "broken" end
    if W.depleted(T.actor) then return true, "depleted" end
    return false
end

local function on_done(J, T, how)
    local c = C()
    J.T = nil
    J.moving = false
    if how == "gone" then return set_phase(J, "scan", "target vanished") end -- not ours to count
    J.bad_streak = 0
    if T.kind ~= "drop" then -- never pick the same (now empty / stump) thing again
        for _, k in ipairs({ T.key, T.alias }) do if k then c.bad[k] = J.t + M.cfg.bad_ttl_s end end
    end
    if T.kind == "drop" then
        c.counts.collected = c.counts.collected + 1
        J.collected = (J.collected or 0) + 1
        refresh_count(J, true)
        return set_phase(J, "scan", "collected")
    end
    J.broken = J.broken + 1
    c.counts.broken = c.counts.broken + 1
    J.targets = J.targets + 1
    local at = W.loc(T.actor) or T.pos
    if T.stage == "root" and at then J.sites[#J.sites + 1] = { X = at.X, Y = at.Y, Z = at.Z } end
    say(J.log, string.format("%s %s (%s)", tostring(T.key), how, T.stage))
    if T.stage == "root" and J.profile.settle then
        J.settle_t = J.t
        return set_phase(J, "settle", how)
    end
    J.wait_until = J.t + M.cfg.drop_wait_s
    refresh_count(J, true)
    return set_phase(J, "scan", how)
end

local function step_equip(J, pawn)
    if not J.tool then return true end
    local inv = mod("inventory")
    local h = (inv and inv.held and U.try(inv.held, pawn)) or {}
    local want = J.tool.entry.item
    if h.right_item == want or h.left_item == want then return true end
    if J.t - J.phase_t > M.cfg.equip_wait_s then
        return fail(J, "wrong_tool", "equip_failed", string.format("I tried to take out my %s but it didn't come out.", J.tool.name or want))
    end
    if not J.equip_sent or J.t - J.equip_sent > M.cfg.equip_repress_s then
        J.equip_sent = J.t
        local r = mcall("inventory", "equip", J.log, want)
        say(J.log, "equip " .. tostring(want) .. " -> " .. tostring(r and (r.via or r.reason)))
    end
    return false
end

local function step_scan(J, me)
    if J.t < (J.wait_until or 0) then return end
    refresh_count(J)
    if J.done then return end
    if J.item and (J.gained or 0) >= J.want then return end -- the frame ends it
    local T, why, hard = choose(J, me)
    if T then
        J.T = T
        T.side, T.aim_i, T.noeff, T.presses, T.g0 = 0, 1, 0, 0, J.gained or 0
        if J.profile.mode == "pickup" and T.item then J.learn_item = J.learn_item or T.item end
        J.radius_tries = 0
        if T.kind == "drop" then return set_phase(J, "collect", T.key) end
        return set_phase(J, "approach", string.format("%s %s %.1f m", T.stage, tostring(T.name), (T.d or 0) / 100))
    end
    if why == "tool_tier_too_low" then
        return fail(J, "wrong_tool", "tool_tier_too_low",
            string.format("The %s here needs a tier %d %s; my best is my %s (tier %d).", tostring(hard.name), hard.tier,
                tool_word(J.profile), J.tool.name or "?", J.tool.tier), { need_tier = hard.tier, have_tier = J.tool.tier })
    end
    if why == "floating_only" then
        local f = hard[1]
        return fail(J, "nothing_in_range", "floating_only", string.format(
            "The only %s near me is floating out of reach (%d of them, the nearest %.0f m up): it has to be knocked down first, then I can mine it.",
            J.key, #hard, f.above_m), { floating = hard })
    end
    -- nothing: widen, then give up
    if J.radius_cm < M.cfg.max_radius_m * 100 then
        J.radius_cm = math.min(J.radius_cm * M.cfg.widen, M.cfg.max_radius_m * 100)
        say(J.log, "nothing in range; widening to " .. math.floor(J.radius_cm / 100) .. " m")
        return
    end
    if (J.gained or 0) > 0 then
        return fail(J, "nothing_in_range", "no_resource_nearby", string.format("I got %d but there's no more %s within %d m.",
            J.gained, J.key, math.floor(J.radius_cm / 100)))
    end
    return fail(J, "nothing_in_range", "no_resource_nearby", string.format("I can't find any %s within %d m of me.", J.key,
        math.floor(J.radius_cm / 100)))
end

local function step_approach(J, pawn, me)
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local d = U.dist2d(me, T.pos)
    local reach = T.reach_cm or 130
    if d <= reach + 10 and not T.reposition then
        mcall("move", "stop", J.log)
        return set_phase(J, "aim", string.format("%.2f m", d / 100))
    end
    if not J.moving then
        local goal = stand_point(T, me, T.reposition or 0)
        T.reposition = nil
        if not start_move(J, goal, 0.35) then
            mark_bad(J, T, "move refused")
            J.T = nil
            return set_phase(J, "scan", "move refused")
        end
        J.moving = true
        return
    end
    local ms, st = move_state()
    if ms == "moving" and J.t - (J.move_started or J.t) <= M.cfg.approach_timeout_s + 5 then return end
    J.moving = false
    local res = st and st.result or {}
    -- "close" is 2D; a target far above or below him (a ledge) is not in reach from under it
    local level = not (T.pos.Z and math.abs((T.pos.Z + 90) - me.Z) > M.cfg.stand_dz_cm)
    if res.status == "arrived" or (level and d <= reach + M.cfg.near_enough_cm) then
        return set_phase(J, "aim", string.format("%.2f m", d / 100))
    end
    -- could not get there: move's own reason, or (a bare timeout, or our own wait ran out) the shared
    -- approach-progress verdict, which says WHY it was not getting closer (e.g. target_above_jump_height)
    local pv = st and type(st.progress) == "table" and st.progress or nil
    local why = res.why or res.reason
    if (why == nil or why == "timeout") and pv and pv.why then why = pv.why end
    why = tostring(why or "stuck")
    mark_bad(J, T, "unreachable: " .. why)
    J.T = nil
    if J.bad_streak >= M.cfg.bad_streak then
        local plural = tostring(J.key):sub(-1) == "s"
        local words = mcall("move", "why_words", why, plural and "they" or "it", plural)
        return fail(J, "path_blocked", "unreachable", string.format("I can't get to the %s: %s, and the last %d I tried were the same.",
            tostring(J.key), type(words) == "string" and words or why, J.bad_streak), { move = why, progress = pv })
    end
    return set_phase(J, "scan", "unreachable " .. why)
end

local function offsets(J)
    return M.cfg.aim_offsets[J.profile.tool or ""] or M.cfg.aim_offsets.default
end

local function step_aim(J, pawn, me)
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local offs = offsets(J)
    local off = offs[T.aim_i] or 0
    local want = bearing(me, T.pos) - off
    T.want_yaw = want
    if not J.faced_t then W.face(J.pc, want) end
    local err = math.abs(wrap(W.yaw(pawn) - want))
    J.face_err = err
    if err > M.cfg.face_err_deg and J.t - J.phase_t < M.cfg.face_max_s then
        local r = math.rad(want)
        J.nudge = { X = math.cos(r), Y = math.sin(r), Z = 0 }
        J.nudge_until = J.t + 0.12
        return
    end
    J.nudge = nil
    J.faced_t = J.faced_t or J.t
    if J.t - J.faced_t < M.cfg.settle_s then return end
    J.faced_t = nil
    return set_phase(J, "swing", string.format("aim %+d err %.0f", off, err))
end

local function step_swing(J, pawn, me, acts)
    local cfg = M.cfg
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local d = U.dist2d(me, T.pos)
    if d > (T.reach_cm or 130) + 70 then
        J.moving = false
        return set_phase(J, "approach", "drifted out of reach")
    end
    -- verify the previous press: stamina spent (the swing ran) and damage on the target
    local pp = J.pending
    if pp and not pp.st_after and J.t >= pp.t + 0.35 then pp.st_after = W.stamina(pawn) or -1 end -- before it regenerates
    if pp and J.t >= pp.verify_at then
        J.pending = nil
        local st = pp.st_after ~= -1 and pp.st_after or nil
        local spent = pp.stamina and st and st < pp.stamina - 0.5
        local hp = T.kind == "actor" and W.hp(T.actor) or nil
        -- damage: HP fell since the press (or, for a tree that was still foliage, it now exists damaged)
        local hit = (hp and pp.hp and hp < pp.hp - 0.01)
            or (hp and T.max_hp and pp.kind == "foliage" and hp < T.max_hp - 0.01)
        if hit then
            J.hits = J.hits + 1; C().counts.hits = C().counts.hits + 1
            T.noeff, J.unverified = 0, 0
            T.hits = (T.hits or 0) + 1
        elseif spent then
            J.unverified = 0
            T.noeff = T.noeff + 1
        else
            J.unverified = (J.unverified or 0) + 1
            if J.unverified >= cfg.unverified_presses then
                return fail(J, "body_error", "inputs_not_reaching_game", "My swings aren't doing anything at all; something is wrong with my controls.")
            end
        end
        say(J.log, string.format("swing %d on %s: hp %s->%s stamina %s->%s %s", J.swings, tostring(T.key), tostring(pp.hp), tostring(hp),
            tostring(pp.stamina), tostring(st), hit and "HIT" or (spent and "no effect" or "unverified")))
        if T.noeff >= cfg.no_effect_swings then
            T.noeff = 0
            T.aim_i = T.aim_i + 1
            if T.aim_i > #offsets(J) then
                T.aim_i = 1
                T.side = T.side + 1
                if T.side >= cfg.sides then
                    mark_bad(J, T, "swing_no_effect")
                    J.T = nil
                    if J.bad_streak >= cfg.bad_streak then
                        return fail(J, "path_blocked", "swing_no_effect", string.format(
                            "My %s swings aren't hurting the %s; I tried %d different ones.", J.tool and J.tool.name or "tool", tostring(J.key), J.bad_streak))
                    end
                    return set_phase(J, "scan", "swing_no_effect")
                end
                T.reposition = 90 * T.side
                J.moving = false
                return set_phase(J, "approach", "other side")
            end
            return set_phase(J, "aim", "next aim")
        end
    end
    if J.t < (J.next_press or 0) or J.pending then return end
    if T.tier and J.tool and T.tier > J.tool.tier then
        return fail(J, "wrong_tool", "tool_tier_too_low", string.format("This %s needs a tier %d %s; my %s is tier %d.",
            tostring(T.name), T.tier, tool_word(J.profile), J.tool.name or "?", J.tool.tier), { need_tier = T.tier, have_tier = J.tool.tier })
    end
    local prof = J.tool_profile or {}
    local prim = prof.prim or {}
    local st = W.stamina(pawn)
    if st and st < (prim.stam or 5) + cfg.stamina_margin then
        J.next_press = J.t + 0.5 -- let stamina come back
        return
    end
    -- a style the model chose (one of the held tool's own actions, combat.check_style), else the
    -- profile's default for this target
    if J.style and not J.style_entry then
        local a, bad = mcall("combat", "check_style", J.style, pawn, J.pc)
        if not a then
            local d = (type(bad) == "table" and bad.data) or {}
            return fail(J, (type(bad) == "table" and bad.reason) or "invalid_args", d.why or "no_such_style", d.detail, d)
        end
        J.style_entry = a
        say(J.log, string.format("style %s = %s (%s)", tostring(J.style), tostring(a.name), tostring(a.input)))
    end
    local slot = (J.style_entry and J.style_entry.input) or (T.attack == "special" and "special") or "primary"
    local action = acts[slot] or acts.primary
    if slot == "special" then prim = prof.spec or prim end
    if not tap(J, action, cfg.tap_frames) then
        return fail(J, "body_error", "no_attack_input", "I can't find my attack input.")
    end
    J.swings = J.swings + 1
    C().counts.swings = C().counts.swings + 1
    J.pending = { t = J.t, stamina = st, hp = T.kind == "actor" and W.hp(T.actor) or nil, kind = T.kind,
                  verify_at = J.t + (prim.dmg_ms or 600) / 1000 + 0.45 }
    J.next_press = J.t + (prim.next_ms or 1300) / 1000 + jitter(cfg.press_jitter_ms)
end

-- After a tree falls: step back from the toppling trunk, wait while it settles into log pieces.
local function step_settle(J, me)
    local s = J.sites[#J.sites]
    if not J.stepped and s then
        J.stepped = true
        local dx, dy = me.X - s.X, me.Y - s.Y
        local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
        start_move(J, { X = me.X + dx / l * M.cfg.step_back_m * 100, Y = me.Y + dy / l * M.cfg.step_back_m * 100, Z = me.Z }, 0.5, 6)
    end
    local busy = false
    local st = J.profile.settle
    if st and s then
        for _, a in ipairs(W.actors(st.class)) do
            local p = W.loc(a)
            if p and U.dist2d(p, s) < (J.profile.site_radius_cm or 1200) and matches(W.class(a), st.match) then busy = true end
        end
    end
    local waited = J.t - J.phase_t
    if (not busy and waited > 1.5) or waited > (st and st.max_s or M.cfg.settle_max_s) then
        J.stepped = nil
        J.wait_until = J.t + 0.5
        return set_phase(J, "scan", busy and "settle timeout" or "settled")
    end
end

local function step_collect(J, pawn, me)
    local cfg = M.cfg
    local T = J.T
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    T.pos = W.loc(T.actor) or T.pos
    local d = U.dist2d(me, T.pos)
    if J.t - J.phase_t > cfg.collect_max_s then
        mark_bad(J, T, "could not collect")
        J.T = nil
        refresh_count(J, true)
        if J.empty_slots == 0 then
            return fail(J, "inventory_full", "inventory_full", "My bags are full, so I can't pick up any more.")
        end
        return set_phase(J, "scan", "drop skipped")
    end
    if d > cfg.collect_tol_m * 100 + 40 then
        if (not J.moving or move_state() ~= "moving") and J.t - (J.move_started or -9) > 1.5 then
            J.moving = start_move(J, T.pos, cfg.collect_tol_m, 12)
        end
        return
    end
    J.moving = false
    T.near_t = T.near_t or J.t
    if J.t - T.near_t < cfg.collect_wait_s then return end -- the item magnet usually pulls it in
    T.presses = T.presses or 0
    if T.presses >= cfg.collect_presses then
        T.near_t = J.t + cfg.collect_max_s -- give up below
        J.phase_t = J.t - cfg.collect_max_s - 1
        return
    end
    if J.t - (T.press_t or -9) < cfg.collect_press_gap_s then return end
    local tg = mcall("inventory", "interact_target", pawn)
    if type(tg) == "table" and (tg.actor == T.key or (J.item and tg.item == J.item)) then
        T.press_t, T.presses = J.t, T.presses + 1
        mcall("move", "stop", J.log)
        mcall("inventory", "press_interact", J.log)
        say(J.log, "interact to collect " .. tostring(T.key))
    end
end

-- Pickup mode (bushes, branches, stones on the ground): walk up, the detector targets it, press E.
local function step_pick(J, pawn, me)
    local T = J.T
    adopt(J, T)
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    if (T.presses or 0) > 0 then
        refresh_count(J)
        if (J.gained or 0) > (T.g0 or 0) then return on_done(J, T, "picked") end
    end
    if J.t - J.phase_t > 8 then
        mark_bad(J, T, "detector never targeted it")
        J.T = nil
        return set_phase(J, "scan", "not targeted")
    end
    if J.t - (T.press_t or -9) < M.cfg.collect_press_gap_s then return end
    local tg = mcall("inventory", "interact_target", pawn)
    if type(tg) ~= "table" or tg.none then
        local r = math.rad(bearing(me, T.pos))
        J.nudge = { X = math.cos(r), Y = math.sin(r), Z = 0 }
        J.nudge_until = J.t + 0.1
        W.face(J.pc, math.deg(r))
        return
    end
    local mine = (T.kind == "actor" and tg.actor == T.key)
        or (T.kind == "foliage" and matches(tg.class, J.profile.root.match))
        or (J.item and tg.item == J.item)
    if not mine then return end
    T.press_t, T.presses = J.t, (T.presses or 0) + 1
    if T.presses > M.cfg.collect_presses then
        mark_bad(J, T, "interact had no effect")
        J.T = nil
        refresh_count(J, true)
        if J.empty_slots == 0 then return fail(J, "inventory_full", "inventory_full", "My bags are full, so I can't pick up any more.") end
        return set_phase(J, "scan", "interact no effect")
    end
    mcall("inventory", "press_interact", J.log)
    J.count_t = nil
    say(J.log, "interact " .. tostring(tg.actor) .. " (" .. tostring(tg.prompt) .. ")")
end

-- World teardown (main's crash convention): end WITHOUT touching any game object.
local function abort_paused(J)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    J.result = result_of(J, false, "interrupted", { why = "world_teardown", detail = "The world is reloading." })
    c.last = { result = J.result, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token then J.released = true; pcall(arb.release, nil, J.token, "paused") end
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if _G.DW_PAUSE then return abort_paused(J) end
    local pc = J.pc
    local pawn = pc and W.pawn(pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.suspended then
        -- a fight (reflex) has the pawn; we wait in the arbiter's suspended stack. If our entry was
        -- dropped (stack full, too old, world change), nobody will resume us: end.
        if J.t - (J.susp_check or -9) >= 1 then
            J.susp_check = J.t
            local arb = mod("arbiter")
            if arb and J.token and not arb.holds(J.token) and not (arb.is_suspended and arb.is_suspended(J.token)) then
                J.released = true
                return finish(J, result_of(J, false, "interrupted", { why = "not_resumed", detail = "I was interrupted and couldn't get back to it." }))
            end
        end
        return
    end
    -- per frame: key taps + the facing nudge
    local keep = {}
    for _, inp in ipairs(J.inputs) do
        W.inject(inp.act)
        inp.frames = inp.frames - 1
        if inp.frames > 0 then keep[#keep + 1] = inp end
    end
    J.inputs = keep
    if J.nudge and J.t < (J.nudge_until or 0) then W.nudge(pawn, J.nudge, M.cfg.nudge_scale) end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return finish(J, result_of(J, false, "companion_down", { why = "died" })) end
    if J.t - J.t0 > J.timeout_s then
        return fail(J, "timeout", "timeout", string.format("I've been at it for %d minutes and only got %d of %d.",
            math.floor(J.timeout_s / 60), J.gained or 0, J.want))
    end
    refresh_count(J)
    if J.done then return end
    if J.item and (J.gained or 0) >= J.want then
        local trains = J.profile and J.profile.trains
        local v = J.via
        local detail = v and string.format("Got %d %s from %s (no usable %s for %s).", J.gained, v.asked, J.key, v.tool_word, v.asked)
            or string.format("Got %d %s.", J.gained, J.key)
        return finish(J, result_of(J, true, nil, { detail = detail, source = J.key, asked = v and v.asked or nil,
            trains = trains == false and "none" or trains })) -- the skill this gives XP (profile data; "none" = verified none)
    end
    local me = W.loc(pawn)
    J.me = me
    if not me then return end
    local acts = J.acts or W.actions(pawn)
    J.acts = acts
    local ph = J.phase
    if ph == "equip" then
        if step_equip(J, pawn) then set_phase(J, "scan", "tool ready") end
    elseif ph == "scan" then step_scan(J, me)
    elseif ph == "approach" then
        if J.profile.mode == "pickup" and J.T and J.T.kind ~= "drop" then
            local d = U.dist2d(me, J.T.pos)
            if d <= (J.T.reach_cm or 110) then mcall("move", "stop", J.log); J.moving = false; return set_phase(J, "pick") end
        end
        step_approach(J, pawn, me)
        if J.phase == "aim" and J.profile.mode == "pickup" then set_phase(J, "pick") end
    elseif ph == "aim" then step_aim(J, pawn, me)
    elseif ph == "swing" then step_swing(J, pawn, me, acts)
    elseif ph == "settle" then step_settle(J, me)
    elseif ph == "collect" then step_collect(J, pawn, me)
    elseif ph == "pick" then step_pick(J, pawn, me)
    end
end
M._frame = frame

-- ------------------------------------------------------------------ start / stop / status
function M.start(log, args, ctx)
    args = args or {}
    if _G.DW_PAUSE then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local P = M.profiles()
    local key, profile
    if P then key, profile = P.resolve(args.resource) end
    local category, candidates
    if not profile and P and P.category then
        -- a generic word ("ore", "rock", "logs"): every profile whose game identifiers carry it; the
        -- nearest one with a usable node around him wins (gather_profiles.category, no word list)
        candidates = P.category(args.resource)
        if #candidates > 0 then
            category = args.resource
            local pawn0 = W.pawn(W.pc())
            local me0 = pawn0 and W.loc(pawn0)
            local r_cm = math.min((tonumber(args.radius) or M.cfg.radius_m) * 100, M.cfg.max_radius_m * 100)
            local best_d
            for _, k in ipairs(candidates) do
                local cand = P.RESOURCES[k]
                local found = me0 and roots_near({ profile = cand, t = W.now(pawn0) }, me0, r_cm) or {}
                if found[1] and (not best_d or found[1].d < best_d) then best_d, key, profile = found[1].d, k, cand end
            end
            if not profile then
                return { ok = false, reason = "nothing_in_range", data = { why = "no_node_of_kind", resource = args.resource,
                         candidates = candidates, radius_m = r_cm / 100,
                         detail = string.format("No %s within %d m (kinds: %s).", tostring(args.resource), r_cm / 100, table.concat(candidates, ", ")) } }
            end
        end
    end
    if not profile then
        return { ok = false, reason = "unknown_target", data = { why = "unknown_resource", resource = args.resource,
                 detail = string.format("I don't know how to gather '%s'.", tostring(args.resource)) } }
    end
    local want = math.floor(tonumber(args.count) or 0)
    if want < 1 then return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local list = mcall("inventory", "list", log)
    if type(list) ~= "table" or list.ok == false then return { ok = false, reason = "body_error", data = { detail = "inventory unreadable" } } end
    local tool
    local tools = (mcall("combat", "weapons") or {}).items or {}
    -- No usable tool: the SAME item from a tool-free source (profile data: the same `item`, no `tool`) when one is
    -- in range, e.g. ash logs from fallen branches (sticks) before the first axe (DISCOVERIES ground gatherables).
    -- The result says which source was used and why (`source`, `asked`).
    local via
    local function tool_free_alternative()
        if not (P and P.RESOURCES and profile.item) then return nil end
        local me1 = W.loc(pawn)
        local r_cm = math.min((tonumber(args.radius) or M.cfg.radius_m) * 100, M.cfg.max_radius_m * 100)
        local best_k, best_p, best_d
        for k, cand in pairs(P.RESOURCES) do
            if k ~= key and not cand.tool and cand.item == profile.item then
                local found = me1 and roots_near({ profile = cand, t = W.now(pawn) }, me1, r_cm) or {}
                if found[1] and (not best_d or found[1].d < best_d) then best_k, best_p, best_d = k, cand, found[1].d end
            end
        end
        return best_k, best_p
    end
    if profile.tool then
        tool = M.best_tool(list, profile, tools)
        local fail
        if not tool then
            fail = { ok = false, reason = "wrong_tool", data = { why = "no_tool", resource = key, need = profile.tool,
                     detail = string.format("I need a %s for %s and I don't have one.", tool_word(profile), key) } }
        elseif (profile.min_tier or 1) > tool.tier then
            fail = { ok = false, reason = "wrong_tool", data = { why = "tool_tier_too_low", resource = key, need_tier = profile.min_tier,
                     have_tier = tool.tier, detail = string.format("%s needs a tier %d %s; my best is my %s (tier %d).", key,
                     profile.min_tier, tool_word(profile), tool.name or "?", tool.tier) } }
        end
        if fail then
            local ak, ap = tool_free_alternative()
            if not ak then return fail end
            via = { asked = key, source = ak, because = fail.data.why, tool_word = tool_word(profile) }
            key, profile, tool = ak, ap, nil
        end
    end
    if list.empty_slots == 0 and M.count_in(list, profile.item) == 0 then
        return { ok = false, reason = "inventory_full", data = { why = "inventory_full", detail = "My bags are full; I need to drop something first." } }
    end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_gather", detail = "A new gather started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "gather:" .. key, level = "task", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.susp_at = J.t; J.inputs = {}; J.nudge = nil; J.pending = nil; J.moving = false end end,
            on_resume = function()
                if not J or J.done then return false end
                J.suspended = false
                if J.susp_at then J.t0 = J.t0 + math.max((J.t or J.susp_at) - J.susp_at, 0); J.susp_at = nil end
                J.acts = nil
                J.moving = false
                if J.T and J.T.kind ~= "drop" then J.T.reposition = nil end
                set_phase(J, J.tool and "equip" or "scan", "resumed")
                return true
            end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else." })) end end })
        if not r.ok then
            return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner,
                     busy_with = r.owner and r.owner.name, busy_move = r.owner and r.owner.move } }
        end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn)
    local tprof = tool and tools[tool.entry.item] or nil
    J = { gen = c.gen, log = log, pc = pc, key = key, profile = profile, want = want, via = via, item = profile.item, token = token,
          task_id = ctx and ctx.id, tool = tool, tool_profile = tprof, stumps = args.stumps == true or (args.stumps == nil and M.cfg.stumps),
          radius_cm = math.min((tonumber(args.radius) or M.cfg.radius_m) * 100, M.cfg.max_radius_m * 100),
          inv0 = counts_of(list), gained = 0, have = M.count_in(list, profile.item), t0 = t, t = t, phase_t = t,
          inputs = {}, sites = {}, swings = 0, hits = 0, broken = 0, targets = 0, phase_log = {}, bad_streak = 0,
          style = (args.style ~= nil and args.style ~= "" and args.style ~= "auto") and tostring(args.style) or nil,
          timeout_s = math.min(M.cfg.timeout_base_s + M.cfg.timeout_per_unit_s * want, M.cfg.timeout_max_s) }
    c.job = J
    set_phase(J, tool and "equip" or "scan", "start " .. key .. " x" .. want)
    mcall("move", "stop", log)
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { resource = key, item = profile.item, want = want, have = J.have, tool = tool and tool.name,
             category = category, candidates = candidates,
             tool_tier = tool and tool.tier, radius_m = J.radius_cm / 100, timeout_s = J.timeout_s } }
end

function M.stop(log, why)
    local J = C().job
    if not J then return { ok = true, was = "idle" } end
    finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "Stopped." }))
    return { ok = true, was = J.phase }
end

function M.status()
    local c = C()
    local J = c.job
    local js
    if J then
        local T = J.T
        js = { resource = J.key, item = J.item, want = J.want, gained = J.gained, have = J.have, phase = J.phase,
               suspended = J.suspended or nil, swings = J.swings, hits = J.hits, broken = J.broken, radius_m = J.radius_cm / 100,
               tool = J.tool and J.tool.name, face_err = J.face_err and math.floor(J.face_err),
               target = T and { key = T.key, kind = T.kind, stage = T.stage, name = T.name, aim_i = T.aim_i, side = T.side,
                                hits = T.hits, noeff = T.noeff, pos = U.to_wire(T.pos) } or nil,
               sites = #J.sites, phase_log = J.phase_log, age_s = J.t and math.floor((J.t - J.t0) * 10) / 10 }
    end
    local bad = 0
    for _ in pairs(c.bad) do bad = bad + 1 end
    return { ok = true, job = js, last = c.last, counts = c.counts, bad_targets = bad, lines = c.log_lines }
end

-- ------------------------------------------------------------------ bridge module handlers
-- gather: an async action ({pending = a}); the bridge pre-empts other actions (gather is in ACTION_TOOLS).
-- Capability contract entry (wins over manifest.lua's): adds the style argument.
do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        gather = { kind = "action", llm = true, moves = true, priority = "task", duration_s = 120, timeout_s = 1800,
            detail_is_speech = true,
            description = "Harvest a resource (a profile key, e.g. oak, ash, copper, stone_boulder, loose_stones) until you have count MORE; finds targets and equips your tool. The result's `trains` names the skill it gave XP to (none = no XP).",
            args = { type = "object", required = { "resource", "count" }, properties = obj({
                resource = { type = "string", description = "A resource (oak, copper, stone_boulder = mine a stone boulder with a pickaxe, Mining XP; loose_stones = pick stones up off the ground, no XP) or a kind (ore, rock, logs, stone: the nearest of that kind)." },
                count = { type = "integer", minimum = 1, description = "How many more." },
                radius = { type = "number", minimum = 1, maximum = 120, description = "Search radius, m (default 30)." },
                stumps = { type = "boolean", description = "Also chop stumps." },
                style = { type = "string", description = "One of the tool's actions (see held_actions), e.g. Overhead Chop." } }) },
            preconditions = { "a tool of the right kind in your inventory (axe for trees, pickaxe for rocks)" },
            reasons = { "nothing_in_range", "wrong_tool", "path_blocked", "inventory_full", "interrupted", "timeout", "unknown_target",
                        "invalid_args", "not_unlocked" } },
    }
end

M.HANDLERS = {
    gather = function(log, args, ctx)
        if type(args.resource) ~= "string" or args.resource == "" then
            return { ok = false, reason = "invalid_args", data = { detail = "resource is required (e.g. 'oak', 'ash', 'stone')" } }
        end
        if args.count ~= nil and (tonumber(args.count) or 0) < 1 then
            return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } }
        end
        local r = M.start(log, { resource = args.resource, count = args.count or 1, radius = args.radius, stumps = args.stumps,
                                 style = args.style }, ctx)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "gather", id = ctx and ctx.id, timeout_s = (J and J.timeout_s or 600) + 15 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "gather job vanished" } }
        end
        return { pending = a }
    end,
    gather_status = function() return M.status() end,
}

return M
