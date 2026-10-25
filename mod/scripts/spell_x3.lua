-- X3 (docs/research/2026-10-25-spells-and-weaknesses.md section 6): Wind Stomp emulation.
-- Temporary home: mod/scripts (debug_run searches only mod/scripts for now).
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
                              player_m = U.cm_to_m(nearest_player(at)), stumbling = stumbling(e.ai) }
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
            cands[#cands + 1] = { id = U.short(e.ai), hp = U.health(e.ai), stumbling = stumbling(e.ai), ai = e.ai }
        end
        local r = S.cast(p, "windstep", target, { trigger = args.force and "force" or nil })
        LAST = { at = at, cands = cands, t = os.time(), result = r }
        rawset(_G, "__dw_spell_x3_last", LAST)
        local wire = {}
        for _, c in ipairs(cands) do wire[#wire + 1] = { id = c.id, hp_before = c.hp, stumbling_before = c.stumbling } end
        return { ok = r.ok, result = r, target = U.short(target), candidates = wire }
    end

    if action == "check" then
        if not LAST.cands then return { ok = false, error = "no stomp yet" } end
        local out = {}
        for _, c in ipairs(LAST.cands) do
            local alive = U.valid(c.ai)
            out[#out + 1] = { id = c.id, valid = alive, hp_before = c.hp, hp_now = alive and U.health(c.ai) or nil,
                              stumbling_now = alive and stumbling(c.ai) or nil,
                              stunned = alive and select(1, S.is_target_stunned(c.ai)) or nil }
        end
        return { ok = true, since_s = os.time() - LAST.t, candidates = out }
    end
    return { ok = false, error = "unknown action " .. tostring(action) }
end

return M
