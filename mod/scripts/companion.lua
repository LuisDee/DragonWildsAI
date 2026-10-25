-- Companion reflex (body-level, no LLM): keep one creature following the player.
-- Verified mechanism (2026-10-25, Luis via GFN): DominionAICharacter:Confuse(pawn, true) makes an
-- existing creature enter its ambient Follow state; it keeps up over 30-40 m and replicates to
-- vanilla clients. It does not survive the player leaving, so this re-acquires on every check:
-- after a join, a despawn, or if the creature stops following.
local M = {}

local CHECK_MS = 5000
local MAX_ACQUIRE_CM = 6000                -- only recruit creatures within 60 m
local PREFERRED = { "Kebbit", "Deer" }      -- passive wildlife first, in this order

local state = { companion = nil, pawn = nil }

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function fullname(o) return o and try(function() return o:GetFullName() end) or "" end

local function loc(a)
    local v = try(function() return a:K2_GetActorLocation() end)
    return v and { x = v.X, y = v.Y, z = v.Z }
end

local function dist(a, b)
    if not (a and b) then return math.huge end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

local function player_pawn()
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if valid(p) then return p end
    end
end

-- Nearest creature of the most preferred kind within range.
local function pick(pawn)
    local here, best = loc(pawn), {}
    for _, ai in ipairs(FindAllOf("DominionAICharacter") or {}) do
        if valid(ai) then
            local n, d = fullname(ai), dist(loc(ai), here)
            for rank, kind in ipairs(PREFERRED) do
                if d <= MAX_ACQUIRE_CM and n:find(kind, 1, true) then
                    if not best[rank] or d < best[rank].d then best[rank] = { ai = ai, d = d } end
                end
            end
        end
    end
    for rank = 1, #PREFERRED do
        if best[rank] then return best[rank].ai, best[rank].d end
    end
end

local function following(ai) return try(function() return ai:IsFollower() end) == true end

local function check(log, bridge)
    local pawn = player_pawn()
    if not pawn then state.companion, state.pawn = nil, nil; return end
    -- UE4SS hands out a new wrapper per lookup, so compare object names, not userdata.
    local pawn_name = fullname(pawn)
    if pawn_name ~= state.pawn then state.companion, state.pawn = nil, pawn_name end -- rejoin/respawn

    local c = state.companion
    if valid(c) and following(c) then return end

    if valid(c) then -- still exists but stopped following: re-apply
        local ok = pcall(function() c:Confuse(pawn, true) end)
        log.event("companion_reapply", { companion = fullname(c), ok = ok })
        return
    end

    local ai, d = pick(pawn)
    if not ai then return end
    local ok, err = pcall(function() ai:Confuse(pawn, true) end)
    log.event("companion_acquired", { companion = fullname(ai), dist_cm = d, ok = ok, err = (not ok) and tostring(err) or nil })
    if ok then
        state.companion = ai
        bridge.emit_event("companion_acquired", { companion = fullname(ai) })
    end
end

function M.status()
    local c = state.companion
    return { companion = valid(c) and fullname(c) or nil, following = valid(c) and following(c) or false,
             location = valid(c) and loc(c) or nil, pawn = state.pawn }
end

function M.start(log, bridge)
    LoopInGameThreadWithDelay(CHECK_MS, function()
        local ok, err = pcall(check, log, bridge)
        if not ok then log.event("companion_error", { err = tostring(err) }) end
    end)
    log.event("companion_started", { check_ms = CHECK_MS, preferred = PREFERRED })
end

return M
