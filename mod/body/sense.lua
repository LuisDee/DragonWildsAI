-- Sense: find things in the world around the puppet. Generic (trees, rocks, ore, herbs, loot,
-- enemies): a census by class, optional foliage -> actor conversion, and "nearest matching" with
-- filters. No movement, no damage; the only state-changing call is the foliage conversion.
--
-- Verified live 2026-10-25 (build 26161880, experiments/gather_probe, no crash):
--   * FindAllOf("FellableTree" | "TreeLog" | "SplittableTreeLog" | "FelledTree" | "DestructibleMiningRock"
--     | "OreNode" | "RuntimeSpawnedWorldItem") return subclasses (BP_BM_Tree_Oak_01_C, BP_OreNode_Stone_C, ...).
--   * Trees are foliage until converted: UInteractableFoliageFunctionLibrary CDO
--     :ConvertFoliageNearbyLocation(worldctx, FVector, radius_cm, bDamageable=true, bInteractable=false,
--     requirer) turned 47 instances within 50 m into actors in 28 ms (323 within 150 m in 168 ms).
--     Undamaged converted trees revert to foliage within seconds (new actor ids on each conversion);
--     a damaged tree stays an actor. So callers remember a target by POSITION and M.relocate() it.
--   * Readers: HealthComponent:GetAuthoritativeHealth() / .MaxHealth, AFellableTree.bIsStump,
--     ADestructibleWorldActor.bIsHidden, AOreNode:HasAvailableResources().
-- Filters (M.FILTERS): standing (not a stump, hp > 0), stump (stump, hp > 0), alive (hp > 0 or no
-- health component, not hidden, ore nodes with resources), any.
local U = require("body.util")

local M = {}

M.FOLIAGE_LIB = "/Script/Dominion.Default__InteractableFoliageFunctionLibrary"
M.CONVERT_MIN_GAP_MS = 1500   -- do not re-convert the same spot more often than this
M.CONVERT_MAX_CM = 15000      -- hard cap on one conversion radius (150 m: ~320 trees)

local S = { last_convert = {}, clock = nil }

-- Time source in ms (tests and the skills tick override it).
function M.set_clock(fn) S.clock = fn end
local function now_ms()
    if S.clock then return S.clock() end
    return math.floor(os.clock() * 1000)
end

-- ------------------------------------------------------------------ state readers
function M.state_of(a)
    local st = { hp = U.health(a), max_hp = U.try(function() return a.HealthComponent.MaxHealth end) }
    st.stump = U.try(function() return a.bIsStump end) == true
    st.hidden = U.try(function() return a.bIsHidden end) == true
    local res = U.try(function() return a:HasAvailableResources() end)
    if res ~= nil then st.has_resources = res == true end
    return st
end

local function hp_ok(st) return st.hp == nil or st.hp > 0 end

M.FILTERS = {
    any = function() return true end,
    standing = function(st) return not st.stump and hp_ok(st) and not st.hidden end,
    stump = function(st) return st.stump and hp_ok(st) end,
    alive = function(st) return hp_ok(st) and not st.hidden and st.has_resources ~= false end,
}

-- ------------------------------------------------------------------ matching
-- spec = {class = "FellableTree", match = "Tree_Oak" (Lua pattern on the class word, optional),
--         exclude = "Sapling" (pattern, optional), filter = "standing" | fn(state, actor)}
function M.matches(spec, a)
    local cw = U.class_word(a) or ""
    if spec.match and not cw:find(spec.match) then return false end
    if spec.exclude and cw:find(spec.exclude) then return false end
    return true
end

local function filter_fn(spec)
    local f = spec.filter
    if type(f) == "function" then return f end
    return M.FILTERS[f or "any"] or M.FILTERS.any
end

-- Census: every alive, non-default actor of spec.class (matching spec) within radius_cm of origin.
-- Returns a list of {actor, id, class, loc, dist, state}, nearest first. opts: {origin, radius_cm,
-- near = {loc, radius_cm} (second distance constraint), skip = {[key]=true} (M.key), max}.
function M.census(spec, opts)
    opts = opts or {}
    local out = {}
    local ok_f = filter_fn(spec)
    for _, a in ipairs(U.find_all(spec.class, { skip_defaults = true })) do
        if M.matches(spec, a) then
            local at = U.loc(a)
            local d = opts.origin and U.dist(opts.origin, at) or 0
            local inside = (not opts.radius_cm or d <= opts.radius_cm)
                and (not opts.near or U.dist(opts.near.loc, at) <= opts.near.radius_cm)
            if inside and not (opts.skip and opts.skip[M.key(at)]) then
                local st = M.state_of(a)
                if ok_f(st, a) then
                    out[#out + 1] = { actor = a, id = U.short(a), class = U.class_word(a), loc = at, dist = d, state = st }
                end
            end
        end
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    if opts.max then for i = #out, opts.max + 1, -1 do out[i] = nil end end
    return out
end

function M.nearest(spec, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    o.max = 1
    return M.census(spec, o)[1]
end

-- Stable key of a position (1 m grid): remembers a resource across foliage re-conversion.
function M.key(loc)
    if not loc then return "?" end
    return string.format("%d:%d", math.floor(loc.X / 100 + 0.5), math.floor(loc.Y / 100 + 0.5))
end

-- ------------------------------------------------------------------ foliage conversion
-- Convert foliage instances within radius_cm of `at` into actors (trees). Throttled per spot.
-- Returns ok, err. ctx: a world-context object (the puppet).
function M.convert_foliage(log, ctx, at, radius_cm)
    if not (ctx and at) then return false, "no context" end
    radius_cm = math.min(radius_cm or 1500, M.CONVERT_MAX_CM)
    local k = M.key(at) .. "/" .. math.floor(radius_cm / 100)
    local t = now_ms()
    if S.last_convert[k] and t - S.last_convert[k] < M.CONVERT_MIN_GAP_MS then return true, "throttled" end
    S.last_convert[k] = t
    local lib = U.find_object(M.FOLIAGE_LIB)
    if not lib then return false, "foliage library not loaded" end
    return U.call(log, "sense.ConvertFoliageNearbyLocation", { at = U.to_wire(at), r = radius_cm }, function()
        lib:ConvertFoliageNearbyLocation(ctx, { X = at.X, Y = at.Y, Z = at.Z }, radius_cm, true, false, ctx)
    end)
end

-- Find spec near `loc` again (after the actor reverted to foliage): convert a small radius there,
-- then the nearest match within tol_cm. Returns the census entry or nil.
function M.relocate(log, ctx, spec, loc, tol_cm, convert)
    tol_cm = tol_cm or 200
    if convert then M.convert_foliage(log, ctx, loc, math.max(tol_cm * 2, 600)) end
    return M.nearest(spec, { origin = loc, radius_cm = tol_cm })
end

function M._reset() S.last_convert = {}; S.clock = nil end

return M
