-- Hitcheck: did a swing register on a resource, and if not, WHY. Generic for anything gated by
-- the game's tool modifier BP_DamageModifier_SpecificWeapon_C (trees: DA_HatchetOnly[_TierN],
-- rocks/ore: DA_PickaxeOnly). Read-only hooks plus a pure verdict function.
--
-- Verified live 2026-10-25 (build 26161880, experiments/gather_probe hook_dmg, Luis watching):
--   * A puppet BP_PerformAttack (hatchet Chop) at 1.1 m from an oak REACHES the tree's damage pipeline:
--     the hooks fired GetHeldEquipmentThatInflictedDamage (Source = the puppet pawn, HeldEquipment out
--     = nil), IsDamageCausedByUnarmedAttack (out = true), then ModifyDamage (Amount 10, Instigator =
--     the puppet). IsEquipmentOfSufficientTier / IsEquipmentCorrectCategory were NOT called and the
--     tree's HP stayed 220. So the gate treats the puppet's swing as UNARMED.
--   * The same axe swing kills Kebbits (creatures have no tool gate).
--   * Cause (inference, strong): FPlayerActionInstance.ActionGranter (UEquipment*) is nil in our
--     BP_PerformAttack call; the game derives "the equipment that inflicted the damage" from it.
--     The puppet has no UHeldEquipmentItem (its held actor's HeldEquipmentItem is nil, DISCOVERIES
--     Route 1). Fix candidates: an item instance for the puppet (inventory agent, design section 13),
--     or the emulated hit (gather.lua: HealthComponent:DecreaseHealth at the damage point).
--   * UE4SS fires the Lua callback for these BP (script) functions AFTER they ran (out params are
--     filled; the call order logged is inner functions first, ModifyDamage last). The second
--     (post) callback passed to RegisterHook never fired. UNVERIFIED for other UE4SS builds.
-- Verdicts (M.verdict): damaged | gate_no_weapon | gate_tier | gate_category | modified_to_zero |
-- no_contact (no modifier call after the swing: out of reach, missed, or not a gated resource).
local U = require("body.util")

local M = {}

M.CLASS = "/Game/Gameplay/DamageModifiers/BP_DamageModifier_SpecificWeapon.BP_DamageModifier_SpecificWeapon_C"
M.FNS = { "GetHeldEquipmentThatInflictedDamage", "IsDamageCausedByUnarmedAttack",
          "IsEquipmentOfSufficientTier", "IsEquipmentCorrectCategory", "ModifyDamage" }
M.KEEP = 64

-- Shared across loadfile reloads (experiments) so hooks register once per server run.
local G = rawget(_G, "__dw_hitcheck")
if not G then
    G = { armed = false, registered = {}, seq = 0, events = {}, current = nil }
    rawset(_G, "__dw_hitcheck", G)
end

local function pval(x)
    local v = U.try(function() return x:get() end)
    if v == nil then return x end
    return v
end

local function record(ev)
    G.seq = G.seq + 1
    ev.seq = G.seq
    local list = G.events
    list[#list + 1] = ev
    if #list > M.KEEP then table.remove(list, 1) end
end
M._record = record -- tests feed events through this

local function on_call(fn, a1, a2)
    if fn == "GetHeldEquipmentThatInflictedDamage" then
        local di = pval(a1)
        G.current = U.short(U.try(function() return di.Source end)) or U.short(U.try(function() return di.Instigator end))
        record({ fn = fn, who = G.current, held = U.short(pval(a2)) })
    elseif fn == "IsDamageCausedByUnarmedAttack" then
        local di = pval(a1)
        local who = U.short(U.try(function() return di.Source end)) or G.current
        record({ fn = fn, who = who, result = pval(a2) == true })
    elseif fn == "IsEquipmentOfSufficientTier" or fn == "IsEquipmentCorrectCategory" then
        record({ fn = fn, who = G.current, held = U.short(pval(a1)), result = pval(a2) == true })
    elseif fn == "ModifyDamage" then
        local di = pval(a2)
        local who = U.short(U.try(function() return di.Instigator end)) or G.current
        record({ fn = fn, who = who, amount = U.try(function() return di.Amount end) })
        G.current = nil
    end
end

-- The server's own record of what a swing damaged (authoritative, per the coordinator's plan):
-- PlayerMeleeAttackComponent:Multicast_SendDamageCacheData(TArray<FTimedDamageInfo>) (DOM:30186).
-- FTimedDamageInfo {TimeOffset, DamageInfo = FDamageInfo {DamagedActors = TArray<FDamagedActor
-- {PointDamageEvent = FDominionPointDamageEvent {Amount, Instigator, Source, InstigatorLocation,
-- VictimLocation, HitLocation, ...}, Actor = facade handle}}, AttackId, Location, Shape, ...}}.
-- READ ONLY (nested struct reads, never pushed: R15). The victim is identified by VictimLocation.
M.CACHE_FN = "/Script/Dominion.PlayerMeleeAttackComponent:Multicast_SendDamageCacheData"
M.CACHE_V = 2

local function v3(v) return v and { X = U.try(function() return v.X end), Y = U.try(function() return v.Y end), Z = U.try(function() return v.Z end) } or nil end

M.VICTIM_CLASSES = { "FellableTree", "TreeLog", "FelledTree", "DestructibleMiningRock", "OreNode", "DominionAICharacter", "BP_PlayerCharacter_C" }
-- The alive actor whose origin is nearest to `at` (within 150 cm), as "<short name>".
function M.nearest_actor(at)
    if not (at and at.X) then return nil end
    local best, bd
    for _, cls in ipairs(M.VICTIM_CLASSES) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local d = U.dist(at, U.loc(a))
            if d < 150 and (not bd or d < bd) then best, bd = a, d end
        end
    end
    return best and U.short(best) or nil
end

local function on_cache(comp, arr)
    local owner = U.try(function() return comp:GetOwner() end)
    local ev = { fn = "DamageCache", who = U.short(owner), swings = {}, hits = 0 }
    local list = pval(arr)
    pcall(function()
        list:ForEach(function(_, elem)
            local td = U.try(function() return elem:get() end) or elem
            local di = U.try(function() return td.DamageInfo end)
            local sw = { t = U.try(function() return td.TimeOffset end), at = v3(U.try(function() return di.Location end)),
                         attack_id = U.try(function() return di.AttackId end),
                         shape = U.class_word(U.try(function() return di.Shape end)), victims = {} }
            pcall(function()
                di.DamagedActors:ForEach(function(_, de)
                    local d = U.try(function() return de:get() end) or de
                    local pe = U.try(function() return d.PointDamageEvent end)
                    local vat = v3(U.try(function() return pe.VictimLocation end))
                    sw.victims[#sw.victims + 1] = {
                        victim = M.nearest_actor(vat), -- identity by VictimLocation (actor origin: stale for rolled logs)
                        amount = U.try(function() return pe.Amount end),
                        victim_at = v3(U.try(function() return pe.VictimLocation end)),
                        hit_at = v3(U.try(function() return pe.HitLocation end)),
                        from = v3(U.try(function() return pe.InstigatorLocation end)),
                    }
                    ev.hits = ev.hits + 1
                end)
            end)
            ev.swings[#ev.swings + 1] = sw
        end)
    end)
    record(ev)
    U.event(nil, "hitcheck_damage_cache", ev)
end

-- Register the hooks once per server run. Returns {armed, registered = {fn = true|err}}.
function M.arm(log)
    -- The hook calls G.cache_fn, so a reloaded hitcheck (experiments) swaps the reader without a
    -- second registration. CACHE_V bumps re-register once when an older reader is installed.
    G.cache_fn = on_cache
    if G.cache_v ~= M.CACHE_V then
        local ok, err = pcall(RegisterHook, M.CACHE_FN, function(ctx, a1)
            if G.cache_v_live == M.CACHE_V then pcall(G.cache_fn, pval(ctx), a1) end
        end)
        if ok then G.cache_v, G.cache_v_live = M.CACHE_V, M.CACHE_V end
        G.cache_armed = ok or G.cache_armed
        G.registered.DamageCache = ok and true or tostring(err)
    end
    if G.armed then return { armed = true, registered = G.registered } end
    local any = false
    for _, fn in ipairs(M.FNS) do
        local path = M.CLASS .. ":" .. fn
        local ok, err = pcall(RegisterHook, path, function(_, a1, a2)
            pcall(on_call, fn, a1, a2)
        end)
        G.registered[fn] = ok and true or tostring(err)
        any = any or ok
    end
    G.armed = any
    U.event(log, "hitcheck_armed", { armed = any, registered = G.registered })
    return { armed = any, registered = G.registered }
end

function M.armed() return G.armed end
function M.cache_armed() return G.cache_armed == true end

-- Damage-cache hits recorded for `who` since seq: list of {amount, victim_at, hit_at, from}.
function M.cache_hits(who, seq)
    local out = {}
    for _, ev in ipairs(G.events) do
        if ev.seq > (seq or 0) and ev.fn == "DamageCache" and (who == nil or ev.who == who) then
            for _, sw in ipairs(ev.swings or {}) do for _, v in ipairs(sw.victims or {}) do out[#out + 1] = v end end
        end
    end
    return out
end
function M.seq() return G.seq end

-- Events for `who` (actor short name) recorded after seq.
function M.since(who, seq)
    local out = {}
    for _, ev in ipairs(G.events) do
        if ev.seq > (seq or 0) and (who == nil or ev.who == who) then out[#out + 1] = ev end
    end
    return out
end

-- Pure verdict from the events of one swing plus the HP change.
function M.verdict(events, hp_before, hp_now)
    if hp_before and hp_now and hp_now < hp_before then return "damaged" end
    local saw_mod, saw = false, {}
    for _, ev in ipairs(events or {}) do
        if ev.fn == "ModifyDamage" then saw_mod = true end
        saw[#saw + 1] = ev
    end
    for _, ev in ipairs(saw) do
        if ev.fn == "IsDamageCausedByUnarmedAttack" and ev.result == true then return "gate_no_weapon" end
        if ev.fn == "GetHeldEquipmentThatInflictedDamage" and ev.held == nil and not saw_mod then return "gate_no_weapon" end
        if ev.fn == "IsEquipmentCorrectCategory" and ev.result == false then return "gate_category" end
        if ev.fn == "IsEquipmentOfSufficientTier" and ev.result == false then return "gate_tier" end
    end
    for _, ev in ipairs(saw) do
        if ev.fn == "GetHeldEquipmentThatInflictedDamage" and ev.held == nil then return "gate_no_weapon" end
    end
    if saw_mod then return "modified_to_zero" end
    return "no_contact"
end

-- Convenience: verdict for `who` since `seq`.
function M.check(who, seq, hp_before, hp_now)
    local evs = M.since(who, seq)
    return M.verdict(evs, hp_before, hp_now), #evs
end

function M._reset()
    G.armed, G.registered, G.seq, G.events, G.current, G.cache_armed = false, {}, 0, {}, nil, nil
end

return M
