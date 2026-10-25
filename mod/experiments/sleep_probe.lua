-- Night skip / sleep probe (build 26161880). Default action is READ-ONLY. Writes touch the PUPPET (or
-- its PlayerState) only, never a real player, and refuse without confirm=true.
--   debug_run {"module":"sleep_probe"}                               read: night?, every pawn's rest state,
--                                                                     PlayerArray flags, beds (BedComponent)
--   {"action":"watch","seconds":120}                                  log rest-state / night changes every 500 ms
--   {"action":"mark","asleep":true,"confirm":true}                    puppet PlayerRestComponent.IsSleeping (no OnRep)
--   {"action":"ps_flag","flag":"bOnlySpectator","value":true,"confirm":true}   bot PlayerState flag
--   {"action":"bed","confirm":true[,"bed":"<owner id>"]}              CanSleep(puppet) then Sleep(puppet) on the
--                                                                     nearest bed within 4 m of the puppet
--   {"action":"bed_stop","confirm":true}                              StopSleeping(puppet) on that bed
local U = require("body.util")

local M = {}

M.TIME_LIB = "/Script/Dominion.Default__InGameTimeFunctionLibrary"
M.PS_FLAGS = { bIsSpectator = true, bOnlySpectator = true, bIsABot = true }
M.BED_REACH_CM = 400

local function night(ctx_obj)
    local lib = U.try(StaticFindObject, M.TIME_LIB)
    if not U.valid(lib) or not ctx_obj then return nil end
    return U.try(function() return lib:IsNighttime(ctx_obj) end)
end

-- FTimespan return -> hours of the in-game day (Ticks are 100 ns). Read-only library calls.
local function hours(ts)
    if ts == nil then return nil end
    local raw = U.try(function() return ts.Ticks end)
    local t = raw ~= nil and tonumber(raw) or nil
    return t and (t / 36000000000) % 24 or nil
end

function M.time(ctx_obj)
    local lib = U.try(StaticFindObject, M.TIME_LIB)
    if not U.valid(lib) or not ctx_obj then return nil end
    return {
        night = U.try(function() return lib:IsNighttime(ctx_obj) end),
        now_h = hours(U.try(function() return lib:GetInGameTime(ctx_obj) end)),
        dusk_h = hours(U.try(function() return lib:GetTimeOfDusk(ctx_obj) end)),
        dawn_h = hours(U.try(function() return lib:GetTimeOfDawn(ctx_obj) end)),
    }
end

local function rest_of(p)
    local rc = U.try(function() return p.PlayerRestComponent end)
    if not U.valid(rc) then return nil end
    local area = U.try(function() return rc.CurrentRestingAreaActor end)
    local comp = U.try(function() return rc.CurrentRestingAreaComponent end)
    return { sleeping = U.try(function() return rc.IsSleeping end), area = U.valid(area) and U.short(area) or nil,
             area_comp = U.valid(comp) and U.class_word(comp) or nil }, rc
end

local function ps_flags(ps)
    if not U.valid(ps) then return nil end
    local f = { name = U.str(U.try(function() return ps:GetPlayerName() end)), id = U.short(ps) }
    for k in pairs(M.PS_FLAGS) do f[k] = U.try(function() return ps[k] end) end
    return f
end

local function beds(origin)
    local out = {}
    for _, b in ipairs(U.find_all("BedComponent")) do
        local owner = U.try(function() return b:GetOwner() end)
        local at = U.valid(owner) and U.loc(owner)
        out[#out + 1] = {
            comp = b, owner = owner, id = U.valid(owner) and U.short(owner) or U.short(b),
            d = (origin and at) and U.dist(origin, at) or math.huge, at = at,
            requires_claim = U.try(function() return b.bRequiresClaimingToSleepIn end),
            claimed = U.try(function() return b:IsClaimedByAnyPlayer() end),
            claimant = U.str(U.try(function() return b:GetClaimingCharacterName() end)),
        }
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function wire_bed(b)
    return { id = b.id, d_m = U.cm_to_m(b.d), at = U.to_wire(b.at), requires_claim = b.requires_claim,
             claimed = b.claimed, claimant = b.claimant }
end

function M.read(log)
    local players, puppets = U.split_pawns()
    local pawns = {}
    for _, p in ipairs(players) do
        local r = rest_of(p) or {}
        r.who, r.kind, r.ps = U.player_name(p), "player", ps_flags(U.player_state(p))
        pawns[#pawns + 1] = r
    end
    for _, p in ipairs(puppets) do
        local r = rest_of(p) or {}
        r.who, r.kind, r.ps = U.short(p), "puppet", ps_flags(U.player_state(p))
        pawns[#pawns + 1] = r
    end
    local gs = players[1] and U.try(function() return players[1]:GetWorld().GameState end)
    local arr = {}
    if gs then
        pcall(function()
            gs.PlayerArray:ForEach(function(_, e)
                local ps = U.try(function() return e:get() end) or e
                arr[#arr + 1] = ps_flags(ps)
            end)
        end)
    end
    local origin = (puppets[1] and U.loc(puppets[1])) or (players[1] and U.loc(players[1]))
    local bl = {}
    for i, b in ipairs(beds(origin)) do if i <= 10 then bl[#bl + 1] = wire_bed(b) end end
    local resting = {}
    for _, r in ipairs(U.find_all("RestingAreaComponent")) do
        local o = U.try(function() return r:GetOwner() end)
        resting[#resting + 1] = { cls = U.class_word(r), owner = U.valid(o) and U.short(o) or nil,
                                  d_m = (origin and U.valid(o)) and U.cm_to_m(U.dist(origin, U.loc(o))) or nil }
        if #resting >= 15 then break end
    end
    local res = { ok = true, night = night(players[1] or puppets[1]), time = M.time(players[1] or puppets[1]), pawns = pawns, player_array = arr, beds = bl,
                  resting_areas = resting }
    U.event(log, "sleep_probe_read", res)
    return res
end

function M.watch(log, args)
    local left = math.floor(math.min(tonumber(args.seconds) or 120, 900) * 2)
    local prev = rawget(_G, "__dw_sleep_watch")
    if prev and CancelDelayedAction then pcall(CancelDelayedAction, prev.h) end
    local st = { last = {} }
    st.h = LoopInGameThreadWithDelay(500, function()
        left = left - 1
        if left <= 0 then
            if CancelDelayedAction then pcall(CancelDelayedAction, st.h) end
            U.event(log, "sleep_watch_end", {})
            return true
        end
        local players, puppets = U.split_pawns()
        local snap = { night = tostring(night(players[1] or puppets[1])) }
        for _, p in ipairs(players) do local r = rest_of(p) or {}; snap[U.player_name(p) or "?"] = tostring(r.sleeping) .. "|" .. tostring(r.area) end
        for _, p in ipairs(puppets) do local r = rest_of(p) or {}; snap["bot"] = tostring(r.sleeping) .. "|" .. tostring(r.area) end
        for k, v in pairs(snap) do
            if st.last[k] ~= v then U.event(log, "sleep_watch_change", { key = k, from = st.last[k], to = v }); st.last[k] = v end
        end
        return false
    end)
    rawset(_G, "__dw_sleep_watch", st)
    return { ok = true, watching_s = left / 2, log_event = "sleep_watch_change" }
end

local function the_puppet()
    local _, puppets = U.split_pawns()
    return puppets[1]
end

function M.mark(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true (writes the puppet's IsSleeping)" } end
    local p = the_puppet()
    if not p then return { ok = false, error = "no puppet" } end
    local _, rc = rest_of(p)
    if not rc then return { ok = false, error = "puppet has no PlayerRestComponent" } end
    local v = args.asleep ~= false
    local ok, err = U.call(log, "sleep_probe.IsSleeping_write", { value = v }, function() rc.IsSleeping = v end)
    return { ok = ok, err = err and tostring(err), after = rest_of(p) }
end

function M.ps_flag(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true (writes the bot PlayerState)" } end
    if not (M.PS_FLAGS[args.flag] and args.flag ~= "bIsABot") then return { ok = false, error = "flag must be bIsSpectator or bOnlySpectator" } end
    local p = the_puppet()
    local ps = p and U.player_state(p)
    if not U.valid(ps) then return { ok = false, error = "puppet has no PlayerState" } end
    local v = args.value ~= false
    local ok, err = U.call(log, "sleep_probe.ps_flag", { flag = args.flag, value = v }, function() ps[args.flag] = v end)
    return { ok = ok, err = err and tostring(err), after = ps_flags(ps) }
end

local function near_bed(p, want)
    for _, b in ipairs(beds(U.loc(p))) do
        if (not want and b.d <= M.BED_REACH_CM) or (want and b.id == want) then return b end
    end
end

function M.bed(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true (BedComponent:Sleep on the puppet)" } end
    local p = the_puppet()
    if not p then return { ok = false, error = "no puppet" } end
    local b = near_bed(p, args.bed)
    if not b then return { ok = false, error = "no bed within 4 m of the puppet (or bed id not found)" } end
    local can = U.try(function() return b.comp:CanSleep(p) end)
    local res = { bed = wire_bed(b), can_sleep = can, before = rest_of(p) }
    if can ~= true and args.force ~= true then res.ok = false; res.error = "CanSleep is not true"; return res end
    local ok, err = U.call(log, "sleep_probe.BedComponent.Sleep", { bed = b.id }, function() b.comp:Sleep(p) end)
    res.ok, res.err, res.after = ok, err and tostring(err), rest_of(p)
    U.event(log, "sleep_probe_bed", res)
    return res
end

function M.bed_stop(log, args)
    if args.confirm ~= true then return { ok = false, error = "refused: pass confirm=true" } end
    local p = the_puppet()
    if not p then return { ok = false, error = "no puppet" } end
    local b = near_bed(p, args.bed)
    if not b then return { ok = false, error = "no bed near the puppet" } end
    local ok, err = U.call(log, "sleep_probe.BedComponent.StopSleeping", { bed = b.id }, function() b.comp:StopSleeping(p) end)
    return { ok = ok, err = err and tostring(err), after = rest_of(p) }
end

function M.run(log, args)
    args = args or {}
    local fn = ({ read = M.read, watch = M.watch, mark = M.mark, ps_flag = M.ps_flag, bed = M.bed, bed_stop = M.bed_stop })[args.action or "read"]
    if not fn then return { ok = false, error = "unknown action" } end
    local ok, res = pcall(fn, log, args)
    if not ok then return { ok = false, error = tostring(res) } end
    return res
end

return M
