-- Phase 4 experiments T2/T3 (docs/research/2026-10-25-dump-body.md section 8), run via
-- debug_run {module="follower_test", args={action=...}} with Luis connected. Server-side only.
--   action="status"  : Luis's pawn, its follower (if any) and nearby AI characters (read-only)
--   action="summon"  : FollowerComponent:ToggleFollower(DA_Kalphite_Friend) - the same call the
--                      game's Pharaoh's Sceptre spell makes (BP_SMBG_SpawnKalphiteFollower)
--   action="dismiss" : same call again (toggles the follower off)
--   action="confuse" : nearest DominionAICharacter:Confuse(pawn, true) -> ambient Follow state
--                      (verified; the legacy follower reflex experiments/companion.lua uses it)
-- Locations are {X,Y,Z} in cm (they were lower-case {x,y,z} before the move to experiments/).
local U = require("body.util")

local M = {}

local FOLLOWER_DA = "/UmbralSands/Gameplay/AI/Kalphite_Faction/Kalphite_Friend/DA_Kalphite_Friend.DA_Kalphite_Friend"

local function describe_ai(ai, from)
    local l = U.loc(ai)
    local ctrl = U.controller_of(ai)
    local vel = U.try(function() return ai:GetVelocity() end)
    return {
        speed = vel and math.sqrt(vel.X ^ 2 + vel.Y ^ 2 + vel.Z ^ 2),
        movement_mode = U.try(function() return ai.CharacterMovement.MovementMode end),
        move_status = ctrl and U.try(function() return ctrl:GetMoveStatus() end),
        should_follow = U.try(function() return ai:ShouldFollowConfuser() end),
        hidden = U.try(function() return ai.bHidden end),
        name = U.fullname(ai),
        location = l,
        dist_cm = from and l and U.dist(l, from) or nil,
        is_follower = U.try(function() return ai:IsFollower() end),
        controller = U.fullname(ctrl),
        replicates = U.try(function() return ai:GetIsReplicated() end),
        replicate_movement = U.try(function() return ai.bReplicateMovement end),
    }
end

local function status(pawn)
    local here = U.loc(pawn)
    local comp = U.try(function() return pawn:GetFollowerComponent() end)
    local follower = U.try(function() return pawn.Follower end)
    local ais = {}
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        if #ais < 10 then ais[#ais + 1] = describe_ai(ai, here) end
    end
    return {
        pawn = U.fullname(pawn),
        pawn_location = here,
        follower_component = U.fullname(comp),
        follower = U.valid(follower) and describe_ai(follower, here) or nil,
        time_remaining = comp and U.try(function() return comp.FollowerRealTimeRemaining end),
        nearby_ai = ais,
    }
end

function M.run(log, args)
    args = args or {}
    local action = args.action or "status"
    -- A real player only (the first BP_PlayerCharacter_C may be the puppet).
    local pawn = U.split_pawns()[1]
    if not pawn then return { ok = false, error = "no player pawn (is Luis connected?)" } end

    if action == "summon" or action == "dismiss" then
        local da = U.find_object(FOLLOWER_DA)
        if not da then return { ok = false, error = "follower data asset not loaded", path = FOLLOWER_DA } end
        local comp = pawn:GetFollowerComponent()
        local on_cooldown = U.try(function() return comp:IsFollowerOnCooldown(da) end)
        local ok, err = U.call(log, "follower_test.ToggleFollower", { action = action }, function() comp:ToggleFollower(da) end)
        U.event(log, "follower_toggle", { action = action, ok = ok, err = (not ok) and tostring(err) or nil, on_cooldown = on_cooldown })
        local res = status(pawn)
        res.toggled, res.toggle_error, res.was_on_cooldown = ok, (not ok) and tostring(err) or nil, on_cooldown
        return res
    elseif action == "confuse" then
        local here, best, best_d = U.loc(pawn), nil, math.huge
        for _, ai in ipairs(U.find_all("DominionAICharacter")) do
            if not args.match or (U.fullname(ai) or ""):find(args.match, 1, true) then
                local d = U.dist(U.loc(ai), here)
                if d < best_d then best, best_d = ai, d end
            end
        end
        if not best then return { ok = false, error = "no AI character loaded near the player" } end
        local ok, err = U.call(log, "follower_test.Confuse", { target = U.short(best) }, function() best:Confuse(pawn, true) end)
        U.event(log, "ai_confuse", { target = U.fullname(best), ok = ok, err = (not ok) and tostring(err) or nil })
        return { confused = ok, error = (not ok) and tostring(err) or nil, target = describe_ai(best, here) }
    end
    return status(pawn)
end

return M
