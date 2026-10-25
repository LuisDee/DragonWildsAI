-- Sleep: the companion sleeps so it never blocks Luis's night skip (build 26161880; DISCOVERIES
-- "NIGHT SKIP WORKS" and "Night skip and sleep"). The puppet is a BP_PlayerCharacter_C with a
-- DominionPlayerState in GameState.PlayerArray, so the game waits on it ("waiting on Claude").
--
-- VERIFIED in game (2026-10-25 15:51 UTC, Luis via GFN; the night passed 3 s after the bot slept):
--   1. SpawnActor(BP_Magic_SummonShelter_C) about 3 m from the bot (what the Summon Shelter spell
--      produces; the bot can't cast the spell itself);
--   2. BedComponent:Sleep(puppet) directly from about 3 m. CanSleep(puppet) answered FALSE and Sleep
--      still worked (CurrentRestingAreaActor = the shelter, IsSleeping = true). Walking into the
--      shelter fails (path_blocked by its collision), so the bot never walks inside.
-- NOT enough (verified): PlayerRestComponent.IsSleeping = true alone; the PlayerState
-- bIsSpectator/bOnlySpectator flags. Neither is used any more.
--
-- Routes, in order:
--   bed      a bed nobody else claimed (never Luis's): walk to within BED_REACH_CM (or stop where the
--            collision blocks within BED_DIRECT_MAX_CM), then a direct Sleep(puppet). An unclaimed
--            bed that requires claiming is claimed for the bot. UNVERIFIED for real beds.
--   shelter  spawn a shelter next to the bot (class by path; LoadAsset if nobody cast the spell this
--            run; else the class of a live shelter), then a direct Sleep. On wake the bot's own
--            shelter is removed (SetLifeSpan, never an immediate destroy: R6).
-- Placement: no traces (struct out params, R15), so "clear ground" = the first of a few points 3 m
-- around the bot (the side away from players first) that is >= SHELTER_PLAYER_CLEAR_CM from every
-- player and >= SHELTER_BED_CLEAR_CM from other beds, at the bot's own height (it stands on ground).
--
-- Reflex (M.tick, 1 s loop wired in main.lua): Luis's PlayerRestComponent.IsSleeping goes true ->
-- the bot sleeps (a free bed within REFLEX_BED_CM, else a shelter; a failed walk falls back to the
-- shelter); IsSleeping goes false -> the bot wakes, its shelter is removed, it follows Luis again.
--
-- Bridge handlers (beside body/skills.lua, sharing its action slot and tick loop):
--   sleep {target?="nearest"|<bed owner id>, mode?="auto"|"bed"|"shelter"}  ASYNC when walking.
--         ok {mode, bed, sleeping=true, resting_area}; verified by re-reading IsSleeping and the
--         resting area. Fails: nothing_in_range (mode=bed, no free bed), unknown_target,
--         path_blocked, timeout, verification_failed, not_implemented (no shelter class), companion_down.
--   wake {}  SYNC. ok {was, sleeping=false, shelter_removed}.
--   sleep_status {} read-only: night, Luis/bot sleeping, how, beds, reflex.
local U = require("body.util")

local M = {}

M.TIME_LIB = "/Script/Dominion.Default__InGameTimeFunctionLibrary"
M.SHELTER_CLASS = "/Game/Gameplay/UtilityMagic/PerkSpells/SummonShelter/BP_Magic_SummonShelter.BP_Magic_SummonShelter_C"
M.SHELTER_SHORT = "BP_Magic_SummonShelter_C"
M.SHELTER_DIST_CM = 300           -- verified distance
M.SHELTER_PLAYER_CLEAR_CM = 500   -- never put the shelter on top of a player
M.SHELTER_BED_CLEAR_CM = 400
M.SHELTER_LIFESPAN_S = 0.1
M.BED_SEARCH_CM = 10000           -- "nearest" looks this far
M.BED_REACH_CM = 300              -- direct Sleep from here (verified at ~3 m)
M.BED_DIRECT_MAX_CM = 450         -- stuck against the bed's collision but this close: sleep anyway
M.BED_ACCEPT_CM = 150
M.WALK_TIMEOUT_MS = 55000
M.REISSUE_MS = 2000
M.STUCK_MS = 4000
M.STUCK_MOVE_CM = 50
M.REFLEX_MS = 1000
M.REFLEX_BED_CM = 1500            -- reflex walks to a bed only this close; else a shelter at once
M.BOT_NAME = "Claude"

local S = { log = nil, bridge = nil, skills = nil, puppet = nil, how = nil, bed = nil, shelter = nil,
            luis_was = false, resume_follow = nil, reflex = "auto", loop = nil, allow_claim = true }

local function log(name, data) U.event(S.log, name, data) end
local function result(ok, reason, data) return { ok = ok, reason = reason, data = data or {} } end

-- ------------------------------------------------------------------ reads
function M.rest(p)
    local rc = U.try(function() return p.PlayerRestComponent end)
    return U.valid(rc) and rc or nil
end

function M.is_sleeping(p)
    local rc = p and M.rest(p)
    return rc and U.try(function() return rc.IsSleeping end) == true or false
end

function M.resting_area(p)
    local rc = p and M.rest(p)
    local a = rc and U.try(function() return rc.CurrentRestingAreaActor end)
    return U.valid(a) and a or nil
end

function M.is_night(ctx)
    local lib = U.try(StaticFindObject, M.TIME_LIB)
    if not (U.valid(lib) and ctx) then return nil end
    return U.try(function() return lib:IsNighttime(ctx) end)
end

local function is_shelter(actor) return (U.short(actor) or ""):find(M.SHELTER_SHORT, 1, true) ~= nil end

-- -> list of {comp, owner, id, at, d, requires_claim, claimed, claimant, shelter, usable, why}
function M.beds(origin, p)
    local out = {}
    for _, b in ipairs(U.find_all("BedComponent")) do
        local owner = U.try(function() return b:GetOwner() end)
        local at = U.valid(owner) and U.loc(owner) or nil
        local r = {
            comp = b, owner = owner, id = U.valid(owner) and U.short(owner) or U.short(b), at = at,
            d = (origin and at) and U.dist(origin, at) or math.huge,
            requires_claim = U.try(function() return b.bRequiresClaimingToSleepIn end) == true,
            claimed = U.try(function() return b:IsClaimedByAnyPlayer() end) == true,
            claimant = U.str(U.try(function() return b:GetClaimingCharacterName() end)),
            shelter = U.valid(owner) and is_shelter(owner) or false,
        }
        local mine = p and U.try(function() return b:IsClaimedByPlayer(p) end) == true
        local ours = S.shelter ~= nil and U.valid(owner) and U.short(owner) == U.short(S.shelter)
        if r.shelter and not ours then
            r.usable, r.why = false, "someone else's shelter"
        elseif r.claimed and not mine and r.claimant ~= M.BOT_NAME then
            r.usable, r.why = false, "claimed by " .. tostring(r.claimant or "someone")
        else
            r.usable = true
        end
        out[#out + 1] = r
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function wire_bed(b)
    return b and { id = b.id, distance = U.cm_to_m(b.d), position = U.to_wire(b.at), requires_claim = b.requires_claim,
                   claimed = b.claimed, claimant = b.claimant, shelter = b.shelter, usable = b.usable, why = b.why } or nil
end
M.wire_bed = wire_bed

local function pick_bed(p, target, max_cm)
    for _, b in ipairs(M.beds(U.loc(p), p)) do
        if target and target ~= "nearest" then
            if b.id == target then return b end
        elseif b.usable and b.d <= (max_cm or M.BED_SEARCH_CM) then
            return b
        end
    end
    return nil
end

local function bed_of(actor)
    local id = U.short(actor)
    for _, b in ipairs(U.find_all("BedComponent")) do
        local o = U.try(function() return b:GetOwner() end)
        if U.valid(o) and U.short(o) == id then return b end
    end
    return U.try(function() return actor.BedComponent end)
end

-- ------------------------------------------------------------------ direct sleep (verified)
-- Sleep(puppet) on a bed component, regardless of CanSleep (it said false and Sleep still worked).
-- -> ok, reason, data
function M.direct_sleep(p, comp, owner, data)
    data = data or {}
    data.can_sleep = U.try(function() return comp:CanSleep(p) end)
    local ok, err = U.call(S.log, "sleep.BedComponent.Sleep", { bed = U.short(owner), can_sleep = tostring(data.can_sleep) },
                           function() comp:Sleep(p) end)
    if not ok then data.detail = tostring(err); return false, "body_error", data end
    local area = M.resting_area(p)
    data.sleeping, data.resting_area = M.is_sleeping(p), area and U.short(area) or nil
    if not data.sleeping then return false, "verification_failed", data end
    return true, nil, data
end

function M.bed_sleep(p, b)
    local data = { bed = wire_bed(b), mode = "bed" }
    if not b.usable then return false, "unknown_target", data end
    if b.requires_claim and not b.claimed and not b.shelter then
        if not S.allow_claim then return false, "unknown_target", data end
        U.call(S.log, "sleep.BedComponent.Claim", { bed = b.id }, function() b.comp:Claim(p) end)
    end
    local ok, reason = M.direct_sleep(p, b.comp, b.owner, data)
    if ok then S.how, S.bed = "bed", b end
    return ok, reason, data
end

-- ------------------------------------------------------------------ shelter (verified spawn)
function M.shelter_class()
    local cls = U.try(StaticFindObject, M.SHELTER_CLASS)
    if U.valid(cls) then return cls, "loaded" end
    for _, a in ipairs(U.find_all(M.SHELTER_SHORT)) do
        cls = U.try(function() return a:GetClass() end)
        if U.valid(cls) then return cls, "live_shelter" end
    end
    if type(LoadAsset) == "function" then
        U.call(S.log, "sleep.LoadAsset", { path = M.SHELTER_CLASS }, function() LoadAsset(M.SHELTER_CLASS) end)
        cls = U.try(StaticFindObject, M.SHELTER_CLASS)
        if U.valid(cls) then return cls, "load_asset" end
    end
    return nil, "not loaded"
end

-- pure-ish: the spawn point. Points 3 m around the bot, the side away from the nearest player first.
function M.shelter_point(p)
    local here = U.loc(p)
    if not here then return nil end
    local players = U.split_pawns()
    local away = { X = 1, Y = 0 }
    local near, nd = nil, math.huge
    for _, pl in ipairs(players) do
        local d = U.dist(here, U.loc(pl))
        if d < nd then near, nd = pl, d end
    end
    if near then
        local at = U.loc(near)
        local dx, dy = here.X - at.X, here.Y - at.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then away = { X = dx / len, Y = dy / len } end
    else
        local f = U.forward(p)
        if f then away = { X = f.X, Y = f.Y } end
    end
    local beds = M.beds(here, p)
    for _, deg in ipairs({ 0, 60, -60, 120, -120, 180 }) do
        local r = math.rad(deg)
        local dx = away.X * math.cos(r) - away.Y * math.sin(r)
        local dy = away.X * math.sin(r) + away.Y * math.cos(r)
        local pt = { X = here.X + dx * M.SHELTER_DIST_CM, Y = here.Y + dy * M.SHELTER_DIST_CM, Z = here.Z }
        local clear = true
        for _, pl in ipairs(players) do
            if U.dist2d(pt, U.loc(pl)) < M.SHELTER_PLAYER_CLEAR_CM then clear = false end
        end
        for _, b in ipairs(beds) do
            if b.at and U.dist2d(pt, b.at) < M.SHELTER_BED_CLEAR_CM then clear = false end
        end
        if clear then
            -- face the bot: the verified spawn used the bot's yaw + 180
            return pt, math.deg(math.atan(-dy, -dx))
        end
    end
    return nil
end

function M.spawn_shelter(p)
    local cls, src = M.shelter_class()
    if not cls then return nil, "not_implemented", { detail = "shelter class not loaded" } end
    local pt, yaw = M.shelter_point(p)
    if not pt then return nil, "nothing_in_range", { detail = "no clear spot 3 m around the bot" } end
    local world = U.try(function() return p:GetWorld() end)
    if not world then return nil, "companion_down", {} end
    local ok, sh = U.call(S.log, "sleep.SpawnActor_shelter", { at = U.to_wire(pt), class_from = src }, function()
        return world:SpawnActor(cls, pt, { Pitch = 0, Yaw = yaw or 0, Roll = 0 })
    end)
    if not ok or not U.valid(sh) then return nil, "body_error", { detail = "spawn failed: " .. tostring(sh) } end
    -- A real cast has Owner = Instigator = GetCaster() = the caster (DISCOVERIES "Summon Shelter
    -- ownership"); without it Luis sees "Claude's shelter has no owner".
    U.call(S.log, "sleep.shelter_SetOwner", { owner = U.short(p) }, function() sh:SetOwner(p) end)
    U.call(S.log, "sleep.shelter_Instigator", { instigator = U.short(p) }, function() sh.Instigator = p end)
    S.shelter = sh
    log("shelter_spawned", { shelter = U.short(sh), at = U.to_wire(pt), class_from = src })
    return sh, nil, { shelter = U.short(sh), at = U.to_wire(pt), class_from = src }
end

function M.remove_shelter()
    local sh = S.shelter
    S.shelter = nil
    if not U.alive(sh) then return false end
    local ok = U.call(S.log, "sleep.shelter_SetLifeSpan", { shelter = U.short(sh) }, function() sh:SetLifeSpan(M.SHELTER_LIFESPAN_S) end)
    return ok
end

function M.shelter_sleep(p)
    local sh, reason, data = M.spawn_shelter(p)
    data.mode = "shelter"
    if not sh then return false, reason, data end
    local comp = bed_of(sh)
    if not U.valid(comp) then M.remove_shelter(); data.detail = "shelter has no BedComponent"; return false, "body_error", data end
    local ok, r2 = M.direct_sleep(p, comp, sh, data)
    if not ok then M.remove_shelter(); return false, r2, data end
    S.how, S.bed = "shelter", { comp = comp, owner = sh, id = U.short(sh) }
    return true, nil, data
end

function M.wake(p)
    local was = S.how
    if M.is_sleeping(p) and S.bed and U.valid(S.bed.comp) then
        U.call(S.log, "sleep.BedComponent.StopSleeping", { bed = S.bed.id }, function() S.bed.comp:StopSleeping(p) end)
    end
    local removed = M.remove_shelter()
    S.how, S.bed = nil, nil
    return not M.is_sleeping(p), was, removed
end

-- ------------------------------------------------------------------ the sleep skill
local function finish(a, ok, reason, data) return S.skills._finish(a, ok, reason, data) end

local function arrive_and_sleep(a, p)
    local ok, reason, data = M.bed_sleep(p, a.bed)
    return finish(a, ok, reason, data)
end

local function give_up(a, p, reason, data)
    if a.fallback_shelter then
        local ok, r2, d2 = M.shelter_sleep(p)
        d2.after = reason
        return finish(a, ok, r2, d2)
    end
    return finish(a, false, reason, data)
end

local function step_sleep(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local b = a.bed
    if not U.valid(b.comp) then return finish(a, false, "unknown_target", { bed = a.bed_id }) end
    local now = S.skills.now()
    local here = U.loc(p)
    local d = U.dist(here, b.at)
    if d <= M.BED_REACH_CM then return arrive_and_sleep(a, p) end
    if now - a.started >= M.WALK_TIMEOUT_MS then return give_up(a, p, "timeout", { bed = wire_bed(b) }) end
    if not a.last_pos or U.dist(here, a.last_pos) > M.STUCK_MOVE_CM then
        a.last_pos, a.last_progress = here, now
    elseif now - a.last_progress >= M.STUCK_MS then
        if d <= M.BED_DIRECT_MAX_CM then return arrive_and_sleep(a, p) end -- blocked by the bed itself
        return give_up(a, p, "path_blocked", { bed = wire_bed(b), position = U.to_wire(here) })
    end
    if not a.last_issue or now - a.last_issue >= M.REISSUE_MS then
        a.last_issue = now
        local c = U.controller_of(p)
        if c then S.skills._move_to_actor(c, b.owner, M.BED_ACCEPT_CM) end
    end
end

-- mode: auto (a free bed if any, else a shelter) | bed | shelter. ctx.reflex: no reply; a failed
-- walk falls back to a shelter.
function M.h_sleep(args, ctx)
    ctx = ctx or {}
    local p, err = S.puppet.ensure_ready()
    if not p then return result(false, "companion_down", { detail = err }) end
    local mode = args.mode or "auto"
    if mode ~= "auto" and mode ~= "bed" and mode ~= "shelter" then
        return result(false, "invalid_args", { detail = "mode is auto, bed or shelter" })
    end
    if M.is_sleeping(p) then return result(true, nil, { mode = S.how or "unknown", already = true, sleeping = true }) end
    local named = args.target and args.target ~= "nearest"
    local b
    if mode ~= "shelter" then
        b = pick_bed(p, args.target, ctx.max_bed_cm)
        if not b and (mode == "bed" or named) then
            return result(false, named and "unknown_target" or "nothing_in_range",
                          { target = args.target, detail = "no free bed within " .. U.cm_to_m(ctx.max_bed_cm or M.BED_SEARCH_CM) .. " m" })
        end
    end
    if not b then
        local ok, reason, data = M.shelter_sleep(p)
        return result(ok, reason, data)
    end
    if U.dist(U.loc(p), b.at) <= M.BED_REACH_CM then
        local ok, reason, data = M.bed_sleep(p, b)
        return result(ok, reason, data)
    end
    local a = { kind = "sleep", id = ctx.id, async = not ctx.reflex, bed = b, bed_id = b.id, step = step_sleep,
                fallback_shelter = ctx.reflex == true or mode == "auto" }
    S.skills._start(a)
    return nil -- async
end

function M.h_wake()
    local p = S.puppet.get()
    if not p then return result(false, "companion_down", {}) end
    local ok, was, removed = M.wake(p)
    if not ok then return result(false, "verification_failed", { was = was, sleeping = true }) end
    return result(true, nil, { was = was or "none", sleeping = false, shelter_removed = removed })
end

function M.status()
    local p = S.puppet and S.puppet.get() or nil
    local luis = U.find_player("luis")
    local origin = (p and U.loc(p)) or (luis and U.loc(luis))
    local beds = {}
    for i, b in ipairs(M.beds(origin, p)) do if i <= 5 then beds[#beds + 1] = wire_bed(b) end end
    local night = M.is_night(luis or p)
    return { night = night, luis_sleeping = luis and M.is_sleeping(luis) or false,
             bot_sleeping = p and M.is_sleeping(p) or false, how = S.how,
             shelter = S.shelter and U.short(S.shelter) or nil, beds = beds, reflex = S.reflex }
end

-- ------------------------------------------------------------------ reflex: sleep when Luis sleeps
function M.tick()
    if S.reflex == "off" then return end
    local p = S.puppet and S.puppet.get()
    local luis = U.find_player("luis")
    if not (p and luis) then return end
    local asleep = M.is_sleeping(luis)
    if asleep and not S.luis_was then
        S.luis_was = true
        if M.is_sleeping(p) then return end
        local cur = S.skills.current and S.skills.current()
        S.resume_follow = cur and cur.kind == "follow" and cur.player or nil
        local mode = (S.reflex == "shelter") and "shelter" or "auto"
        local r = M.h_sleep({ mode = mode }, { id = "reflex_sleep", reflex = true, max_bed_cm = M.REFLEX_BED_CM })
        log("sleep_reflex", { luis = "asleep", mode = mode, walking = r == nil,
                              ok = r and r.ok, reason = r and r.reason, how = S.how })
    elseif not asleep and S.luis_was then
        S.luis_was = false
        local cur = S.skills.current and S.skills.current()
        if cur and cur.kind == "sleep" then S.skills._finish(cur, false, "interrupted", { by = "luis_woke" }) end
        local ok, was, removed = M.wake(p)
        log("sleep_reflex", { luis = "awake", woke = ok, was = was, shelter_removed = removed, resume_follow = S.resume_follow })
        if S.resume_follow and S.bridge and S.bridge.handlers.follow then
            pcall(S.bridge.handlers.follow, { player = S.resume_follow }, { id = "reflex_follow" })
        end
        S.resume_follow = nil
    end
end

local function state_extender(data, p)
    data.sleeping = p and M.is_sleeping(p) or false
    local luis = U.find_player("luis")
    data.luis_sleeping = luis and M.is_sleeping(luis) or false
    return data
end

M.HANDLERS = {
    sleep = M.h_sleep, wake = M.h_wake,
    sleep_status = function() return result(true, nil, M.status()) end,
}

-- opts: {skills, puppet, no_loop, reflex = "auto"|"shelter"|"off" (env DW_SLEEP_REFLEX), allow_claim}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod
    S.skills = opts.skills or require("body.skills")
    S.puppet = opts.puppet or require("body.puppet")
    S.reflex = opts.reflex or os.getenv("DW_SLEEP_REFLEX") or "auto"
    if opts.allow_claim ~= nil then S.allow_claim = opts.allow_claim end
    for name, fn in pairs(M.HANDLERS) do bridge.handlers[name] = S.skills._probe_guard(name, fn) end
    if S.skills.add_state_extender then S.skills.add_state_extender("sleep", state_extender) end
    if not opts.no_loop and not S.loop then
        S.loop = LoopInGameThreadWithDelay(M.REFLEX_MS, function()
            local ok, err = pcall(M.tick)
            if not ok then log("sleep_tick_error", { err = tostring(err) }) end
        end)
    end
    log("sleep_registered", { reflex = S.reflex })
    return M
end

function M._reset()
    if S.loop and CancelDelayedAction then pcall(CancelDelayedAction, S.loop) end
    S.loop, S.how, S.bed, S.shelter, S.luis_was, S.resume_follow, S.reflex = nil, nil, nil, nil, false, nil, "auto"
    S.allow_claim = true
end
M._S = S

return M
