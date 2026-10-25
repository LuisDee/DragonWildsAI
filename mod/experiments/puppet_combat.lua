-- Route 1, experiments E3/E4 (docs/research/2026-10-25-humanoid-companion-dump.md E3, E4): the puppet
-- fights. The proven swing loop is promoted into body/skills.lua (bridge tool `attack`).
-- Run via debug_run {module="puppet_combat", args={action=...}} with Luis connected and an
-- armed puppet alive. Never unpossess/destroy the puppet (risk register R1).
--   targets            : nearby DominionAICharacters with health and distance to the puppet (read-only)
--   approach {match=}  : AIController:MoveToActor(nearest target matching `match`)
--   swing   {match=}   : (a) the game's own melee attack, BP_PerformAttack, at the target (verified)
--   hit     {match=, amount=25, credit="puppet"|"luis", allow_crash=true} : (b) server-side damage.
--                        CRASHED the server in UE4SS struct marshalling (TArray<FTypeDamage>,
--                        risk register R3); refuses unless allow_crash=true.
--   immortal           : puppet HealthComponent:SetIsImmortal(true)
local U = require("body.util")

local M = {}

local ATTACKS = {
    "/Game/Gameplay/Character/Player/Attacks/Mace/BP_Player_Mace_Attack1.BP_Player_Mace_Attack1_C",
    "/Game/Gameplay/Character/Player/Attacks/Sword/BP_Player_Sword_Attack1.BP_Player_Sword_Attack1_C",
}
local ACTIONS = {
    "/Game/Gameplay/Character/Player/Attacks/Mace/PA_Attack_Mace.Default__PA_Attack_Mace_C",
    "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.Default__PA_Attack_Sword_C",
}
local PHYSICAL, DIR_FRONT = 1, 4 -- EDamageClass / EReactionDirectionality values from the research note

local function first(paths)
    for _, path in ipairs(paths) do
        local o = U.find_object(path)
        if o then return o, path end
    end
end

local function pawns()
    local players, puppets = U.split_pawns()
    return players[1], puppets[1]
end

local function nearest(puppet, match)
    local best, best_d
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        if not match or (U.fullname(ai) or ""):find(match, 1, true) then
            local d = U.actor_dist(ai, puppet)
            if not best_d or d < best_d then best, best_d = ai, d end
        end
    end
    return best, best_d
end

local actions = {}

function actions.targets()
    local _, p = pawns()
    if not p then return { ok = false, error = "no puppet" } end
    local out = {}
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        if #out < 15 then
            out[#out + 1] = { name = U.short(ai), dist_m = math.floor(U.actor_dist(ai, p) / 100), health = U.health(ai) }
        end
    end
    table.sort(out, function(a, b) return a.dist_m < b.dist_m end)
    return { targets = out }
end

function actions.approach(log, args)
    local _, p = pawns()
    local t, d = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local ok, res = U.call(log, "puppet_combat.MoveToActor", { target = U.short(t) }, function()
        return p:GetController():MoveToActor(t, 150.0, true, true, true, nil, true)
    end)
    U.event(log, "puppet_approach", { target = U.fullname(t), dist_cm = d, ok = ok, res = tostring(res) })
    return { target = U.fullname(t), dist_m = math.floor(d / 100), ok = ok, result = tostring(res) }
end

function actions.swing(log, args)
    local _, p = pawns()
    local t = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local atk, atk_path = first(ATTACKS)
    local act, act_path = first(ACTIONS)
    local hp0 = U.health(t)
    local ok, err = U.call(log, "puppet_combat.BP_PerformAttack", { target = U.short(t), attack = atk_path }, function()
        p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, {
            Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = t,
        })
    end)
    local r = { target = U.fullname(t), attack = atk_path, action = act_path, ok = ok,
                err = (not ok) and tostring(err) or nil, health_before = hp0, health_now = U.health(t) }
    U.event(log, "puppet_swing", r)
    return r
end

function actions.hit(log, args)
    if args.allow_crash ~= true then
        return { ok = false, error = "refused: PredictDamage crashed the server (UE4SS struct marshalling); pass allow_crash=true offline only" }
    end
    local luis, p = pawns()
    local t = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local instigator = (args.credit == "luis" and luis) or p
    local hp0 = U.health(t)
    local ok, err = U.call(log, "puppet_combat.PredictDamage", { target = U.short(t), amount = args.amount or 25.0 }, function()
        local dc = U.try(function() return t.AiDamageComponent end) or t:GetAiDamageComponent()
        local ev = dc:PredictDamage(PHYSICAL, { { StatusEffect = 0, Types = {}, Amount = args.amount or 25.0 } },
            0.0, instigator, instigator, t:K2_GetActorLocation(), DIR_FRONT, 1.0, 0)
        dc:ApplyDamageFromGameplayEffect(ev, false, true)
    end)
    local r = { target = U.fullname(t), ok = ok, err = (not ok) and tostring(err) or nil,
                health_before = hp0, health_now = U.health(t), credit = U.fullname(instigator) }
    U.event(log, "puppet_hit", r)
    return r
end

function actions.immortal(log)
    local _, p = pawns()
    if not p then return { ok = false, error = "no puppet" } end
    local ok, err = U.call(log, "puppet_combat.SetIsImmortal", {}, function() p.HealthComponent:SetIsImmortal(true, p) end)
    U.event(log, "puppet_immortal", { ok = ok, err = (not ok) and tostring(err) or nil })
    return { ok = ok, err = (not ok) and tostring(err) or nil, health = U.health(p) }
end

function M.run(log, args)
    args = args or {}
    local a = actions[args.action or "targets"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
