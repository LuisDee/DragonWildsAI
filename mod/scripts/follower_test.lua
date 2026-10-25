-- Phase 4 experiments T2/T3 (docs/research/2026-10-25-dump-body.md section 8), run via
-- debug_run {module="follower_test", args={action=...}} with Luis connected. Server-side only.
--   action="status"  : Luis's pawn, its follower (if any) and nearby AI characters (read-only)
--   action="summon"  : FollowerComponent:ToggleFollower(DA_Kalphite_Friend) - the same call the
--                      game's Pharaoh's Sceptre spell makes (BP_SMBG_SpawnKalphiteFollower)
--   action="dismiss" : same call again (toggles the follower off)
--   action="confuse" : nearest DominionAICharacter:Confuse(pawn, true) -> ambient Follow state
local M = {}

local FOLLOWER_DA = "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Friend/DA_Kalphite_Friend.DA_Kalphite_Friend"

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function name(o) return o and try(function() return o:GetFullName() end) end

local function loc(actor)
    local v = actor and try(function() return actor:K2_GetActorLocation() end)
    return v and { x = v.X, y = v.Y, z = v.Z }
end

local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end

local function player_pawn()
    local pawns = FindAllOf("BP_PlayerCharacter_C") or {}
    for _, p in ipairs(pawns) do
        if valid(p) then return p end
    end
end

local function dist(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function describe_ai(ai, from)
    local l = loc(ai)
    return {
        name = name(ai),
        location = l,
        dist_cm = dist(l, from),
        is_follower = try(function() return ai:IsFollower() end),
        controller = name(try(function() return ai:GetController() end)),
        replicates = try(function() return ai:GetIsReplicated() end),
        replicate_movement = try(function() return ai.bReplicateMovement end),
    }
end

local function status(pawn)
    local here = loc(pawn)
    local comp = try(function() return pawn:GetFollowerComponent() end)
    local follower = try(function() return pawn.Follower end)
    local ais = {}
    for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do
        if valid(ai) and #ais < 10 then ais[#ais + 1] = describe_ai(ai, here) end
    end
    return {
        pawn = name(pawn),
        pawn_location = here,
        follower_component = name(comp),
        follower = valid(follower) and describe_ai(follower, here) or nil,
        time_remaining = comp and try(function() return comp.FollowerRealTimeRemaining end),
        nearby_ai = ais,
    }
end

function M.run(log, args)
    local action = args.action or "status"
    local pawn = player_pawn()
    if not pawn then return { ok = false, error = "no player pawn (is Luis connected?)" } end

    if action == "summon" or action == "dismiss" then
        local da = StaticFindObject(FOLLOWER_DA)
        if not valid(da) then return { ok = false, error = "follower data asset not loaded", path = FOLLOWER_DA } end
        local comp = pawn:GetFollowerComponent()
        local on_cooldown = try(function() return comp:IsFollowerOnCooldown(da) end)
        local ok, err = pcall(function() comp:ToggleFollower(da) end)
        log.event("follower_toggle", { action = action, ok = ok, err = (not ok) and tostring(err) or nil, on_cooldown = on_cooldown })
        local res = status(pawn)
        res.toggled, res.toggle_error, res.was_on_cooldown = ok, (not ok) and tostring(err) or nil, on_cooldown
        return res
    elseif action == "confuse" then
        local here, best, best_d = loc(pawn), nil, math.huge
        for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do
            local d = valid(ai) and dist(loc(ai), here)
            if d and d < best_d then best, best_d = ai, d end
        end
        if not best then return { ok = false, error = "no AI character loaded near the player" } end
        local ok, err = pcall(function() best:Confuse(pawn, true) end)
        log.event("ai_confuse", { target = name(best), ok = ok, err = (not ok) and tostring(err) or nil })
        return { confused = ok, error = (not ok) and tostring(err) or nil, target = describe_ai(best, here) }
    end
    return status(pawn)
end

return M
