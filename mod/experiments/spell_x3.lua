-- X3 (docs/research/2026-10-25-spells-and-weaknesses.md section 6): Wind Stomp emulation.
-- Lives in mod/experiments (debug_run searches mod/scripts, then mod/experiments).
-- Runs body/spells.lua's real wind_stomp route (loaded fresh from DW_MOD_ROOT) with the route
-- unlocked for this experiment only. Never targets a point within spells.SAFE_PLAYER_CM (or 1.5x
-- the 700 cm explosion radius) of a real player; never touches a player.
--   targets {}                         read-only: AIs within 60 m of the puppet, hp, distance to
--                                      the nearest player, IsStumbling()
--   canary {dx_m=15, force=false}      spawn the explosion dx_m metres from the puppet with no
--                                      creature in range (crash canary for spawn/BeginPlay/SetOwner/
--                                      SetLifeSpan [+ StartDelayedDamage when force=true])
--   stomp {match="Kalphite", force=false}  explosion at the nearest matching AI's feet (>= safe
--                                      distance from players); records the candidates in radius
--   check {}                           IsStumbling()/hp of the last stomp's candidates
-- Each action is one debug_run; check crash_*.dmp and ping between runs.
local M = {}

local function loadmod(rel)
    local root = assert(os.getenv("DW_MOD_ROOT"), "DW_MOD_ROOT unset")
    return assert(loadfile(root .. "/" .. rel))()
end

local U = require("body.util")
local LAST = rawget(_G, "__dw_spell_x3_last") or {}

local function spells_mod(log)
    local S = loadmod("body/spells.lua")
    S.configure({ allow_unverified = true, cost_policy = "free", log = log })
    local root = os.getenv("DW_MOD_LOG_DIR")
    if root then pcall(S.load_catalog, root .. "/../../data/spells_26161880.json") end
    return S
end

local function puppet()
    local _, puppets = U.split_pawns()
    return puppets[1]
end

local function nearest_player(point)
    local best = math.huge
    for _, p in ipairs((U.split_pawns())) do
        local d = U.dist(point, U.loc(p)); if d < best then best = d end
    end
    return best
end

local function stumbling(ai)
    local hr = U.try(function() return ai.AiHitReactionsComponent end)
    if not U.valid(hr) then return nil end
    return U.try(function() return hr:IsStumbling() end)
end

-- UAIDataAsset.HitReactionConfig (DOM:698): the force thresholds the stomp has to beat.
local function thresholds(ai)
    local d = U.try(function() return ai.LoadedData end)
    local hr = d and U.try(function() return d.HitReactionConfig end)
    if not hr then return nil end
    local function n(k) local v = U.try(function() return hr[k] end); return type(v) == "number" and v or nil end
    return { light = n("LightForceThreshold"), heavy = n("HeavyForceThreshold"), knockdown = n("KnockDownForceThreshold"),
             can_stumble = U.try(function() return hr.bCanStumble end) }
end

-- Read-only: gameplay tag names on an AI (GE component container + replicated tag stacks).
local function tag_names(ai)
    local out = {}
    local gec = U.try(function() return ai.GameplayEffectsComponent end)
    local function add_arr(arr, field)
        if not arr then return end
        pcall(function()
            arr:ForEach(function(_, e)
                local v = U.try(function() return e:get() end) or e
                local t = field and U.try(function() return v[field] end) or v
                local n = U.str(U.try(function() return t.TagName end))
                if n and n ~= "None" then out[n] = true end
            end)
        end)
    end
    if gec then
        add_arr(U.try(function() return gec.GameplayTags.GameplayTags end))
        local tc = U.try(function() return gec.GameplayTagsComponent end)
        add_arr(tc and U.try(function() return tc.ReplicatedGameplayTagStackContainer.Stacks end), "Tag")
    end
    return out
end

-- Read-only: the explosion's DelayedDamageInfliction.PendingDamage (FDamagedActor, DOM:2223),
-- scalar fields only.
local function read_pending(ex)
    local ddi = U.try(function() return ex.DelayedDamageInfliction end)
    local arr = ddi and U.try(function() return ddi.PendingDamage end)
    if not arr then return nil end
    local out = {}
    pcall(function()
        arr:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            local ev = U.try(function() return d.PointDamageEvent end)
            out[#out + 1] = {
                hit_reaction_flag = U.try(function() return d.bPerformingHitReaction end),
                amount = ev and U.try(function() return ev.Amount end),
                force = ev and U.try(function() return ev.Force end),
                instigator = ev and U.short(U.try(function() return ev.Instigator end)),
                source = ev and U.short(U.try(function() return ev.Source end)),
                hit_montage = ev and U.short(U.try(function() return ev.HitReaction end)),
                should_hit_react = ev and U.try(function() return ev.CachedDamageShouldHitReact end),
                victim = ev and U.to_wire(U.try(function() return { X = ev.VictimLocation.X, Y = ev.VictimLocation.Y, Z = ev.VictimLocation.Z } end)),
            }
        end)
    end)
    return out
end

-- Sample IsStumbling()/hp every 100 ms for 3 s on the game thread (the stagger is short).
local function start_sampler(cands, ex, PENDING)
    local n = 0
    for _, c in ipairs(cands) do c.samples, c.max_stumble, c.min_hp, c.new_tags = 0, false, c.hp, {} end
    -- returning true does NOT stop LoopInGameThreadWithDelay (seen 2026-10-25: a sampler kept
    -- running); cancel by handle like skills.lua/bridge.lua do.
    local h
    h = LoopInGameThreadWithDelay(100, function()
        n = n + 1
        if ex and U.valid(ex) then
            local pd = read_pending(ex)
            PENDING.samples = PENDING.samples + 1
            if pd and #pd > PENDING.seen_max then PENDING.seen_max, PENDING.first, PENDING.at_ms = #pd, pd, n * 100 end
        end
        if n > 30 then
            if h and CancelDelayedAction then pcall(CancelDelayedAction, h) end
            return true
        end
        for _, c in ipairs(cands) do
            if U.valid(c.ai) then
                c.samples = c.samples + 1
                if stumbling(c.ai) == true then c.max_stumble = true; c.first_stumble_ms = c.first_stumble_ms or n * 100 end
                for t in pairs(tag_names(c.ai)) do
                    if not c.tags_before[t] and not c.new_tags[t] then c.new_tags[t] = n * 100 end
                end
                local hp = U.health(c.ai)
                if hp and (not c.min_hp or hp < c.min_hp) then c.min_hp = hp end
            end
        end
        return n >= 30
    end)
end

local function ais_near(point, r)
    local out = {}
    for _, ai in ipairs(U.try(FindAllOf, "DominionAICharacter") or {}) do
        if U.valid(ai) then
            local d = U.dist(point, U.loc(ai))
            if d <= r then out[#out + 1] = { ai = ai, d = d } end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

function M.run(log, args)
    args = args or {}
    local action = args.action or "targets"
    local p = puppet()
    if not p then return { ok = false, error = "no puppet" } end
    local here = U.loc(p)

    if action == "targets" then
        local out = {}
        for _, e in ipairs(ais_near(here, 6000)) do
            local at = U.loc(e.ai)
            out[#out + 1] = { id = U.short(e.ai), d_m = U.cm_to_m(e.d), hp = U.health(e.ai),
                              player_m = U.cm_to_m(nearest_player(at)), stumbling = stumbling(e.ai),
                              force_thresholds = thresholds(e.ai) }
        end
        return { ok = true, puppet = U.to_wire(here), targets = out }
    end

    if action == "explosions" then -- read-only: live explosion actors (cleanup check)
        local out = {}
        for _, a in ipairs(U.try(FindAllOf, "BP_WindstepExplosion_C") or {}) do
            local garbage = U.try(function() return a:HasAnyInternalFlags(0x10200000) end)
            out[#out + 1] = { id = U.short(a), valid = U.valid(a), garbage = garbage, at = U.to_wire(U.loc(a)),
                              owner = U.short(U.try(function() return a:GetOwner() end)),
                              created = U.try(function() return a.ServerTimeOfCreation end) }
        end
        return { ok = true, explosions = out }
    end

    local S = spells_mod(log)
    if action == "canary" then
        local dx = (tonumber(args.dx_m) or 15) * 100
        local point = { X = here.X + dx, Y = here.Y, Z = here.Z }
        local radius = 700
        local near = ais_near(point, radius * 1.5)
        if #near > 0 then return { ok = false, error = "a creature is in range; canary wants none", n = #near } end
        if U.dist(point, here) < radius * 1.5 then return { ok = false, error = "too close to the puppet" } end
        local r = S.cast(p, "windstep", point, { trigger = args.force and "force" or nil })
        return { ok = r.ok, result = r, point = U.to_wire(point), player_m = U.cm_to_m(nearest_player(point)) }
    end

    if action == "stomp" then
        local match = (args.match or "Kalphite"):lower()
        local target
        for _, e in ipairs(ais_near(here, 6000)) do
            local id = (U.short(e.ai) or ""):lower()
            if id:find(match, 1, true) and (U.health(e.ai) or 1) > 0 then target = e.ai; break end
        end
        if not target then return { ok = false, error = "no matching AI within 60 m of the puppet", match = match } end
        local at = U.loc(target)
        local cands = {}
        for _, e in ipairs(ais_near(at, 700)) do
            cands[#cands + 1] = { id = U.short(e.ai), hp = U.health(e.ai), stumbling = stumbling(e.ai), ai = e.ai,
                                  tags_before = tag_names(e.ai) }
        end
        local r = S.cast(p, "windstep", target, { trigger = args.force and "force" or nil })
        local ex
        for _, a in ipairs(U.try(FindAllOf, "BP_WindstepExplosion_C") or {}) do
            if U.short(a) == r.data.explosion then ex = a end
        end
        local pending_now = ex and read_pending(ex) or nil
        local pending = { seen_max = 0, samples = 0 }
        if r.ok then pcall(start_sampler, cands, ex, pending) end
        LAST = { at = at, cands = cands, t = os.time(), result = r, pending = pending }
        rawset(_G, "__dw_spell_x3_last", LAST)
        local wire = {}
        for _, c in ipairs(cands) do wire[#wire + 1] = { id = c.id, hp_before = c.hp, stumbling_before = c.stumbling } end
        return { ok = r.ok, result = r, target = U.short(target), candidates = wire, pending_at_cast = pending_now }
    end

    if action == "check" then
        if not LAST.cands then return { ok = false, error = "no stomp yet" } end
        local out = {}
        for _, c in ipairs(LAST.cands) do
            local alive = U.valid(c.ai)
            local rec = { id = c.id, valid = alive, hp_before = c.hp, samples = c.samples,
                          stumbled = c.max_stumble, first_stumble_ms = c.first_stumble_ms, min_hp = c.min_hp,
                          force_thresholds = alive and thresholds(c.ai) or nil,
                          new_tags_ms = c.new_tags, tags_before = c.tags_before }
            if alive then
                rec.hp_now = U.health(c.ai)
                rec.stumbling_now = stumbling(c.ai)
                local st, det = S.is_target_stunned(c.ai)
                rec.stunned_now, rec.stun_detail = st, det
            end
            out[#out + 1] = rec
        end
        return { ok = true, since_s = os.time() - LAST.t, candidates = out, pending = LAST.pending }
    end
    return { ok = false, error = "unknown action " .. tostring(action) }
end

return M
