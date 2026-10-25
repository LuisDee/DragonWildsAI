-- LEGACY (Phase 4 T3, superseded by the humanoid puppet in body/): keep one creature following
-- the player. OFF by default; main.lua starts it only with DW_COMPANION=1 (it used to be on unless
-- DW_NO_COMPANION=1). debug_run {module="companion", fn="status"} reads its state.
-- Verified mechanism (2026-10-25, Luis via GFN): DominionAICharacter:Confuse(pawn, true) makes an
-- existing creature enter its ambient Follow state; it keeps up over 30-40 m and replicates to
-- vanilla clients. It does not survive the player leaving, so this re-acquires on every check:
-- after a join, a despawn, or if the creature stops following.
local U = require("body.util")

local M = {}

local CHECK_MS = 5000
local MAX_ACQUIRE_CM = 6000                -- only recruit creatures within 60 m
local PREFERRED = { "Kebbit", "Deer" }      -- passive wildlife first, in this order

-- Shared across reloads so status() from debug_run sees the running loop's state.
local state = rawget(_G, "__dw_companion") or { companion = nil, pawn = nil, loop = nil }
rawset(_G, "__dw_companion", state)

-- Nearest creature of the most preferred kind within range.
local function pick(pawn)
    local here, best = U.loc(pawn), {}
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        local n, d = U.fullname(ai) or "", U.dist(U.loc(ai), here)
        for rank, kind in ipairs(PREFERRED) do
            if d <= MAX_ACQUIRE_CM and n:find(kind, 1, true) then
                if not best[rank] or d < best[rank].d then best[rank] = { ai = ai, d = d } end
            end
        end
    end
    for rank = 1, #PREFERRED do
        if best[rank] then return best[rank].ai, best[rank].d end
    end
end

local function following(ai) return U.try(function() return ai:IsFollower() end) == true end

local function check(log, bridge)
    -- A real player only: the first BP_PlayerCharacter_C may be the puppet.
    local pawn = U.split_pawns()[1]
    if not pawn then state.companion, state.pawn = nil, nil; return end
    -- UE4SS hands out a new wrapper per lookup, so compare object names, not userdata.
    local pawn_name = U.fullname(pawn)
    if pawn_name ~= state.pawn then state.companion, state.pawn = nil, pawn_name end -- rejoin/respawn

    local c = state.companion
    if U.alive(c) and following(c) then return end

    if U.alive(c) then -- still exists but stopped following: re-apply
        local ok = U.call(log, "companion.Confuse", { companion = U.short(c), reapply = true }, function() c:Confuse(pawn, true) end)
        U.event(log, "companion_reapply", { companion = U.fullname(c), ok = ok })
        return
    end

    local ai, d = pick(pawn)
    if not ai then return end
    local ok, err = U.call(log, "companion.Confuse", { companion = U.short(ai) }, function() ai:Confuse(pawn, true) end)
    U.event(log, "companion_acquired", { companion = U.fullname(ai), dist_cm = d, ok = ok, err = (not ok) and tostring(err) or nil })
    if ok then
        state.companion = ai
        if bridge then bridge.emit_event("companion_acquired", { companion = U.fullname(ai) }) end
    end
end

function M.status()
    local c = state.companion
    local live = U.alive(c)
    return { enabled = state.loop ~= nil, companion = live and U.fullname(c) or nil, following = live and following(c) or false,
             location = live and U.loc(c) or nil, pawn = state.pawn }
end

function M.start(log, bridge)
    if state.loop then return end
    state.loop = LoopInGameThreadWithDelay(CHECK_MS, function()
        local ok, err = pcall(check, log, bridge)
        if not ok then U.event(log, "companion_error", { err = tostring(err) }) end
    end)
    U.event(log, "companion_started", { check_ms = CHECK_MS, preferred = PREFERRED })
end

-- debug_run entry: same as status.
function M.run() return M.status() end

return M
