-- X4 (docs/research/2026-10-25-spells-and-weaknesses.md section 6): Tempest Shield via its
-- gameplay effect on the PUPPET: GameplayEffectsComponent:InstantiateGameplayEffect(GE, nil, false).
-- NOT RUN LIVE YET. Risk: UTempestShieldGameplayEffectInstance computes MaxHealth natively from
-- EffectHealthBase (50) + EffectHealthPerAttackSkillLevel (7.5) x Attack level, and the Attack level
-- lives on a PlayerController the puppet does not have (null-PC deref = server crash, DISCOVERIES
-- "ROOT CAUSES"); the instance also replicates FX to clients.
-- Guard rails: refuses unless args.confirm == "offline_canary" AND no real player is connected.
--   status {}                                   read-only: puppet GE instances (+ any shield instance fields)
--   apply {confirm="offline_canary", upgraded=false}
--   remove {}                                   BP_RemoveAllGameplayEffectsWithData(GE class) on the puppet
local M = {}

local U = require("body.util")
local GE = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/GE_TempestShield.GE_TempestShield_C"
local GE_UP = "/Game/Gameplay/UtilityMagic/PerkSpells/TempestShield/GE_TempestShield_Upgraded.GE_TempestShield_Upgraded_C"

local function loadmod(rel)
    return assert(loadfile(assert(os.getenv("DW_MOD_ROOT")) .. "/" .. rel))()
end

local function status(p)
    local gec = U.try(function() return p.GameplayEffectsComponent end)
    local out = {}
    local arr = gec and U.try(function() return gec.ReplicatedInstances end)
    if arr then
        pcall(function()
            arr:ForEach(function(_, e)
                local g = U.try(function() return e:get() end) or e
                local rec = { class = (U.fullname(g) or ""):match("^(%S+)") }
                if (rec.class or ""):find("TempestShield", 1, true) then
                    rec.max_health = U.try(function() return g.MaxHealth end)
                    rec.target = U.short(U.try(function() return g.TargetCharacter end))
                end
                out[#out + 1] = rec
            end)
        end)
    end
    return out
end

function M.run(log, args)
    args = args or {}
    local players, puppets = U.split_pawns()
    local p = puppets[1]
    if not p then return { ok = false, error = "no puppet" } end
    local action = args.action or "status"
    if action == "status" then return { ok = true, puppet = U.short(p), instances = status(p), players = #players } end
    if action == "apply" then
        if args.confirm ~= "offline_canary" then return { ok = false, error = "needs confirm=offline_canary" } end
        if #players > 0 then return { ok = false, error = "a player is connected; X4 runs offline only", players = #players } end
        local S = loadmod("body/spells.lua")
        S.configure({ allow_unverified = true, cost_policy = "free", log = log })
        local r = S.cast(p, "tempest shield", nil, { upgraded = args.upgraded == true })
        return { ok = r.ok, result = r, instances = status(p) }
    end
    if action == "remove" then
        local gec = U.try(function() return p.GameplayEffectsComponent end)
        local n = 0
        for _, path in ipairs({ GE, GE_UP }) do
            local cls = U.try(StaticFindObject, path)
            if U.valid(cls) and gec then
                local ok = U.call(log, "spells.BP_RemoveAllGameplayEffectsWithData", { effect = path }, function()
                    gec:BP_RemoveAllGameplayEffectsWithData(cls)
                end)
                if ok then n = n + 1 end
            end
        end
        return { ok = true, removed_calls = n, instances = status(p) }
    end
    return { ok = false, error = "unknown action " .. tostring(action) }
end

return M
