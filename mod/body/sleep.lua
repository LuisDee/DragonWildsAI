-- Sleep: the companion sleeps so it never blocks Luis's night skip (build 26161880; DISCOVERIES
-- "Night skip and sleep"). The puppet is a BP_PlayerCharacter_C with a DominionPlayerState in
-- GameState.PlayerArray, so the game counts it as a player for "all players sleeping".
--
-- Reflected API used (dump): ADominionPlayerCharacter.PlayerRestComponent (UPlayerRestComponent:
-- IsSleeping (replicated), CurrentRestingAreaActor/Component); UBedComponent:CanSleep / Sleep /
-- StopSleeping / Claim (ADominionPlayerCharacter*), IsClaimedByAnyPlayer, IsClaimedByPlayer,
-- GetClaimingCharacterName, bRequiresClaimingToSleepIn; InGameTimeFunctionLibrary:IsNighttime(ctx).
-- The night skip itself is native (UPlayerSleepSubsystem, ADominionGameMode.OnAllPlayersSleeping).
--
-- Ways to put the bot to sleep, in order of preference:
--   bed   BedComponent:CanSleep(puppet) then Sleep(puppet). Never claims a bed someone else owns;
--         an unclaimed bed that requires claiming is claimed for the bot (opts.allow_claim).
--   flag  write the puppet's PlayerRestComponent.IsSleeping = true (property only, no OnRep). Whether
--         the native subsystem counts this is what the night test decides (UNVERIFIED).
-- The reflex (M.tick, main.lua loop): Luis starts sleeping -> the bot sleeps (bed within
-- REFLEX_BED_CM, else flag); Luis wakes -> the bot wakes and resumes following him.
-- Debug safety valve (night_skip handler / DW_NIGHT_SKIP): "spectator" sets the bot PlayerState's
-- bIsSpectator + bOnlySpectator; "flag" keeps the rest flag on while Luis sleeps (the reflex's
-- fallback); "off" restores both. Which one the subsystem honours: DISCOVERIES.
--
-- Bridge handlers (registered beside body/skills.lua, sharing its action slot and tick loop):
--   sleep {target?="nearest"|<bed owner id>, mode?="auto"|"bed"|"flag"}  ASYNC when walking to a bed.
--         ok {mode, bed?, sleeping=true} verified: re-read IsSleeping (and the resting area for a bed).
--         Fails: nothing_in_range (no usable bed, mode=bed), unknown_target, path_blocked, timeout,
--         verification_failed (CanSleep false / not sleeping after Sleep), companion_down.
--   wake {}  SYNC. ok {was, sleeping=false}.
--   sleep_status {} read-only: night, Luis/bot sleeping, usable beds, reflex + night_skip modes.
--   night_skip {mode="spectator"|"flag"|"off"}  debug valve.
-- UNVERIFIED in game: everything above except the reads (sleep_probe read, 2026-10-25).
local U = require("body.util")

local M = {}

M.TIME_LIB = "/Script/Dominion.Default__InGameTimeFunctionLibrary"
M.BED_SEARCH_CM = 10000       -- "nearest" looks this far
M.BED_REACH_CM = 250          -- Sleep() when this close
M.BED_ACCEPT_CM = 100
M.WALK_TIMEOUT_MS = 55000
M.REISSUE_MS = 2000
M.STUCK_MS = 5000
M.STUCK_MOVE_CM = 50
M.REFLEX_MS = 1000
M.REFLEX_BED_CM = 2500        -- reflex walks to a bed only this close; else flag at once
M.BOT_NAME = "Claude"

local S = { log = nil, bridge = nil, skills = nil, puppet = nil, how = nil, bed = nil,
            luis_was = false, resume_follow = nil, valve = "off", reflex = "auto", loop = nil,
            allow_claim = true }

local function log(name, data) U.event(S.log, name, data) end
local function result(ok, reason, data) return { ok = ok, reason = reason, data = data or {} } end

-- ------------------------------------------------------------------ reads
function M.rest(p)
    local rc = U.try(function() return p.PlayerRestComponent end)
    if not U.valid(rc) then return nil end
    return rc
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

-- Usable for the bot: does not require claiming, or is unclaimed, or is the bot's own.
-- -> list of {comp, owner, id, at, d, requires_claim, claimed, claimant, usable, why}
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
        }
        local mine = p and U.try(function() return b:IsClaimedByPlayer(p) end) == true
        if r.claimed and not mine and r.claimant ~= M.BOT_NAME then
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
                   claimed = b.claimed, claimant = b.claimant, usable = b.usable, why = b.why } or nil
end
M.wire_bed = wire_bed

local function pick_bed(p, target)
    local list = M.beds(U.loc(p), p)
    for _, b in ipairs(list) do
        if target and target ~= "nearest" then
            if b.id == target then return b, list end
        elseif b.usable and b.d <= M.BED_SEARCH_CM then
            return b, list
        end
    end
    return nil, list
end

-- ------------------------------------------------------------------ actions (native)
function M.flag(p, on)
    local rc = M.rest(p)
    if not rc then return false, "no PlayerRestComponent" end
    local ok, err = U.call(S.log, "sleep.IsSleeping_write", { value = on == true }, function() rc.IsSleeping = (on == true) end)
    return ok and M.is_sleeping(p) == (on == true), err
end

-- Sleep in bed b. -> ok, reason, data
function M.bed_sleep(p, b)
    local data = { bed = wire_bed(b) }
    if not b.usable then return false, "unknown_target", data end
    if b.requires_claim and not b.claimed then
        if not S.allow_claim then return false, "unknown_target", data end
        U.call(S.log, "sleep.BedComponent.Claim", { bed = b.id }, function() b.comp:Claim(p) end)
    end
    local can = U.try(function() return b.comp:CanSleep(p) end)
    data.can_sleep = can
    if can ~= true then data.detail = "CanSleep is false (too early in the day, or the bed refuses)"; return false, "verification_failed", data end
    local ok, err = U.call(S.log, "sleep.BedComponent.Sleep", { bed = b.id }, function() b.comp:Sleep(p) end)
    if not ok then data.detail = tostring(err); return false, "body_error", data end
    local area = M.resting_area(p)
    data.sleeping, data.resting_area = M.is_sleeping(p), area and U.short(area) or nil
    if not data.sleeping then return false, "verification_failed", data end
    S.how, S.bed = "bed", b
    return true, nil, data
end

function M.wake(p)
    local was = S.how
    if S.how == "bed" and S.bed and U.valid(S.bed.comp) then
        U.call(S.log, "sleep.BedComponent.StopSleeping", { bed = S.bed.id }, function() S.bed.comp:StopSleeping(p) end)
    end
    if M.is_sleeping(p) then M.flag(p, false) end
    S.how, S.bed = nil, nil
    return not M.is_sleeping(p), was
end

-- ------------------------------------------------------------------ the sleep skill
local function finish(a, ok, reason, data) return S.skills._finish(a, ok, reason, data) end

local function step_sleep(a)
    local p = S.puppet.get()
    if not p then return finish(a, false, "companion_down", {}) end
    local b = a.bed
    if not U.valid(b.comp) then return finish(a, false, "unknown_target", { bed = a.bed_id }) end
    local now = S.skills.now()
    local here = U.loc(p)
    if U.dist(here, b.at) <= M.BED_REACH_CM then
        local ok, reason, data = M.bed_sleep(p, b)
        data.mode = "bed"
        return finish(a, ok, reason, data)
    end
    if now - a.started >= M.WALK_TIMEOUT_MS then return finish(a, false, "timeout", { bed = wire_bed(b) }) end
    if not a.last_pos or U.dist(here, a.last_pos) > M.STUCK_MOVE_CM then
        a.last_pos, a.last_progress = here, now
    elseif now - a.last_progress >= M.STUCK_MS then
        return finish(a, false, "path_blocked", { bed = wire_bed(b), position = U.to_wire(here) })
    end
    if not a.last_issue or now - a.last_issue >= M.REISSUE_MS then
        a.last_issue = now
        local c = U.controller_of(p)
        if c then S.skills._move_to_actor(c, b.owner, M.BED_ACCEPT_CM) end
    end
end

-- mode: auto (bed if usable, else flag) | bed | flag
function M.h_sleep(args, ctx)
    local p, err = S.puppet.ensure_ready()
    if not p then return result(false, "companion_down", { detail = err }) end
    local mode = args.mode or "auto"
    if mode ~= "auto" and mode ~= "bed" and mode ~= "flag" then return result(false, "invalid_args", { detail = "mode is auto, bed or flag" }) end
    if M.is_sleeping(p) then return result(true, nil, { mode = S.how or "unknown", already = true, sleeping = true }) end
    local b
    if mode ~= "flag" then
        b = pick_bed(p, args.target)
        if not b and (mode == "bed" or (args.target and args.target ~= "nearest")) then
            return result(false, args.target and args.target ~= "nearest" and "unknown_target" or "nothing_in_range",
                          { target = args.target, detail = "no usable bed within " .. U.cm_to_m(M.BED_SEARCH_CM) .. " m" })
        end
    end
    if not b then
        local ok, e = M.flag(p, true)
        if not ok then return result(false, "verification_failed", { mode = "flag", detail = tostring(e) }) end
        S.how = "flag"
        return result(true, nil, { mode = "flag", sleeping = true, verified_count = false })
    end
    if U.dist(U.loc(p), b.at) <= M.BED_REACH_CM then
        local ok, reason, data = M.bed_sleep(p, b)
        data.mode = "bed"
        return result(ok, reason, data)
    end
    local a = { kind = "sleep", id = ctx.id, async = not ctx.reflex, bed = b, bed_id = b.id, step = step_sleep }
    S.skills._start(a)
    return nil -- async
end

function M.h_wake()
    local p = S.puppet.get()
    if not p then return result(false, "companion_down", {}) end
    local ok, was = M.wake(p)
    if not ok then return result(false, "verification_failed", { was = was, sleeping = true }) end
    return result(true, nil, { was = was or "none", sleeping = false })
end

function M.status()
    local p = S.puppet and S.puppet.get() or nil
    local luis = U.find_player("luis")
    local origin = (p and U.loc(p)) or (luis and U.loc(luis))
    local beds = {}
    for i, b in ipairs(M.beds(origin, p)) do if i <= 5 then beds[#beds + 1] = wire_bed(b) end end
    return { night = M.is_night(p or luis), luis_sleeping = luis and M.is_sleeping(luis) or false,
             bot_sleeping = p and M.is_sleeping(p) or false, how = S.how, beds = beds,
             reflex = S.reflex, night_skip = S.valve }
end

-- ------------------------------------------------------------------ night-skip valve (debug)
local function set_spectator(p, on)
    local ps = p and U.player_state(p)
    if not U.valid(ps) then return false, "no bot PlayerState" end
    return U.call(S.log, "sleep.ps_spectator", { value = on }, function()
        ps.bIsSpectator = on
        ps.bOnlySpectator = on
    end)
end

function M.set_valve(mode)
    if mode ~= "spectator" and mode ~= "flag" and mode ~= "off" then return false, "mode is spectator, flag or off" end
    local p = S.puppet and S.puppet.get()
    if mode == "spectator" then
        local ok, err = set_spectator(p, true)
        if not ok then return false, tostring(err) end
    elseif S.valve == "spectator" then
        set_spectator(p, false)
    end
    S.valve = mode
    log("night_skip_valve", { mode = mode })
    return true
end

-- ------------------------------------------------------------------ reflex: sleep when Luis sleeps
function M.tick()
    if S.reflex == "off" and S.valve ~= "flag" then return end
    local p = S.puppet and S.puppet.get()
    local luis = U.find_player("luis")
    if not (p and luis) then return end
    local asleep = M.is_sleeping(luis)
    if asleep and not S.luis_was then
        S.luis_was = true
        if M.is_sleeping(p) then return end
        local cur = S.skills.current and S.skills.current()
        S.resume_follow = cur and cur.kind == "follow" and cur.player or nil
        local b = S.reflex ~= "off" and S.reflex ~= "flag" and pick_bed(p) or nil
        if b and b.d <= M.REFLEX_BED_CM then
            log("sleep_reflex", { luis = "asleep", plan = "bed", bed = b.id })
            M.h_sleep({ target = b.id, mode = "bed" }, { id = "reflex_sleep", reflex = true })
        else
            local ok = M.flag(p, true)
            if ok then S.how = "flag" end
            log("sleep_reflex", { luis = "asleep", plan = "flag", ok = ok })
        end
    elseif not asleep and S.luis_was then
        S.luis_was = false
        local cur = S.skills.current and S.skills.current()
        if cur and cur.kind == "sleep" then S.skills._finish(cur, false, "interrupted", { by = "luis_woke" }) end
        local ok = M.wake(p)
        log("sleep_reflex", { luis = "awake", woke = ok, resume_follow = S.resume_follow })
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
    night_skip = function(args)
        local ok, err = M.set_valve(args.mode)
        if not ok then return result(false, "invalid_args", { detail = err }) end
        return result(true, nil, M.status())
    end,
}

-- opts: {skills, puppet, no_loop, reflex = "auto"|"bed"|"flag"|"off" (env DW_SLEEP_REFLEX),
--        night_skip = "off"|"spectator"|"flag" (env DW_NIGHT_SKIP), allow_claim}
function M.register(bridge, log_mod, opts)
    opts = opts or {}
    S.bridge, S.log = bridge, log_mod
    S.skills = opts.skills or require("body.skills")
    S.puppet = opts.puppet or require("body.puppet")
    S.reflex = opts.reflex or os.getenv("DW_SLEEP_REFLEX") or "auto"
    if opts.allow_claim ~= nil then S.allow_claim = opts.allow_claim end
    for name, fn in pairs(M.HANDLERS) do bridge.handlers[name] = S.skills._probe_guard(name, fn) end
    if S.skills.add_state_extender then S.skills.add_state_extender("sleep", state_extender) end
    local valve = opts.night_skip or os.getenv("DW_NIGHT_SKIP")
    if valve and valve ~= "" and valve ~= "off" then M.set_valve(valve) end
    if not opts.no_loop and not S.loop then
        S.loop = LoopInGameThreadWithDelay(M.REFLEX_MS, function()
            local ok, err = pcall(M.tick)
            if not ok then log("sleep_tick_error", { err = tostring(err) }) end
        end)
    end
    log("sleep_registered", { reflex = S.reflex, night_skip = S.valve })
    return M
end

function M._reset()
    if S.loop and CancelDelayedAction then pcall(CancelDelayedAction, S.loop) end
    S.loop, S.how, S.bed, S.luis_was, S.resume_follow, S.valve, S.reflex = nil, nil, nil, false, nil, "off", "auto"
    S.allow_claim = true
end
M._S = S

return M
