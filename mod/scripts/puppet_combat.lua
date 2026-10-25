-- Route 1, experiments E3/E4 (docs/research/2026-10-25-humanoid-companion-dump.md E3, E4): the puppet
-- fights. Run via debug_run {module="puppet_combat", args={action=...}} with Luis connected and an
-- armed puppet alive. Never unpossess/destroy the puppet (deadlocks, see DISCOVERIES).
--   targets            : nearby DominionAICharacters with health and distance to the puppet (read-only)
--   approach {match=}  : AIController:MoveToActor(nearest target matching `match`)
--   swing   {match=}   : (a) the game's own melee attack, BP_PerformAttack, at the target
--   hit     {match=, amount=25, credit="puppet"|"luis"} : (b) server-side damage to the target
--   immortal           : puppet HealthComponent:SetIsImmortal(true)
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

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function fullname(o) return valid(o) and try(function() return o:GetFullName() end) or nil end
local function loc(a) return try(function() return a:K2_GetActorLocation() end) end
local function dist(a, b)
    local p, q = loc(a), loc(b)
    if not (p and q) then return math.huge end
    return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2)
end
local function first(paths)
    for _, path in ipairs(paths) do
        local o = StaticFindObject(path)
        if valid(o) then return o, path end
    end
end

local function pawns()
    local players, puppets = {}, {}
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if valid(p) then
            local c = try(function() return p:GetController() end)
            table.insert(((fullname(c) or ""):find("PlayerController", 1, true)) and players or puppets, p)
        end
    end
    return players[1], puppets[1]
end

local function health(a)
    return try(function() return a.HealthComponent:GetAuthoritativeHealth() end)
        or try(function() return a:GetHealthComponent():GetAuthoritativeHealth() end)
end

local function nearest(puppet, match)
    local best, best_d
    for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do
        local n = fullname(ai) or ""
        if valid(ai) and (not match or n:find(match, 1, true)) then
            local d = dist(ai, puppet)
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
    for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do
        if valid(ai) and #out < 15 then
            out[#out + 1] = { name = (fullname(ai) or ""):match("([%w_]+)$"), dist_m = math.floor(dist(ai, p) / 100), health = health(ai) }
        end
    end
    table.sort(out, function(a, b) return a.dist_m < b.dist_m end)
    return { targets = out }
end

function actions.approach(log, args)
    local _, p = pawns()
    local t, d = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local ok, res = pcall(function() return p:GetController():MoveToActor(t, 150.0, true, true, true, nil, true) end)
    log.event("puppet_approach", { target = fullname(t), dist_cm = d, ok = ok, res = tostring(res) })
    return { target = fullname(t), dist_m = math.floor(d / 100), ok = ok, result = tostring(res) }
end

function actions.swing(log, args)
    local _, p = pawns()
    local t = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local atk, atk_path = first(ATTACKS)
    local act, act_path = first(ACTIONS)
    local hp0 = health(t)
    local ok, err = pcall(function()
        p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, {
            Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = t,
        })
    end)
    local r = { target = fullname(t), attack = atk_path, action = act_path, ok = ok,
                err = (not ok) and tostring(err) or nil, health_before = hp0, health_now = health(t) }
    log.event("puppet_swing", r)
    return r
end

function actions.hit(log, args)
    local luis, p = pawns()
    local t = p and nearest(p, args.match)
    if not t then return { ok = false, error = "no puppet or no target" } end
    local instigator = (args.credit == "luis" and luis) or p
    local hp0 = health(t)
    local ok, err = pcall(function()
        local dc = try(function() return t.AiDamageComponent end) or t:GetAiDamageComponent()
        local ev = dc:PredictDamage(PHYSICAL, { { StatusEffect = 0, Types = {}, Amount = args.amount or 25.0 } },
            0.0, instigator, instigator, t:K2_GetActorLocation(), DIR_FRONT, 1.0, 0)
        dc:ApplyDamageFromGameplayEffect(ev, false, true)
    end)
    local r = { target = fullname(t), ok = ok, err = (not ok) and tostring(err) or nil,
                health_before = hp0, health_now = health(t), credit = fullname(instigator) }
    log.event("puppet_hit", r)
    return r
end

function actions.immortal(log)
    local _, p = pawns()
    if not p then return { ok = false, error = "no puppet" } end
    local ok, err = pcall(function() p.HealthComponent:SetIsImmortal(true, p) end)
    log.event("puppet_immortal", { ok = ok, err = (not ok) and tostring(err) or nil })
    return { ok = ok, err = (not ok) and tostring(err) or nil, health = health(p) }
end

function M.run(log, args)
    local a = actions[args.action or "targets"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
