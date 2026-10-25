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

-- Where to aim at an actor. Fallen tree logs: the trunk meshes are physics-simulated and roll away
-- from the actor's origin, which stays where the piece spawned (verified live 2026-10-25: a
-- BP_Log_Oak_C origin 11 m from its GetMidPointWorldLocation; every swing aimed by the origin
-- whiffed). So logs aim at GetMidPointWorldLocation (out-param struct, read OK); others at the origin.
-- `from` is accepted for callers that pass the puppet position (unused).
function M.aim(a, from)
    local origin = U.loc(a)
    if U.try(function() return a.GetMidPointWorldLocation ~= nil end) then
        local mid = {}
        local ok = pcall(function() a:GetMidPointWorldLocation(mid) end)
        if ok and type(mid.X) == "number" and (mid.X ~= 0 or mid.Y ~= 0) then
            return { X = mid.X, Y = mid.Y, Z = mid.Z or (origin and origin.Z) or 0 }
        end
    end
    return origin
end

-- Stand point `r_cm` from `at`, on the side facing `from`, rotated by `deg` degrees.
function M.ring_point(at, from, r_cm, deg)
    local ang = math.atan((from.Y - at.Y), (from.X - at.X)) + math.rad(deg or 0)
    return { X = at.X + math.cos(ang) * r_cm, Y = at.Y + math.sin(ang) * r_cm, Z = at.Z }
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

-- ------------------------------------------------------------------ look: generic perception
-- Everything around a point, described from GAME DATA, found through the game's own base classes
-- (dump 26161880), never item lists: anything with a UInteractionComponent (gatherables, drops,
-- stations, chests, NPCs), ADestructibleWorldActor (trees, stumps, felled trunks, logs, rocks),
-- AOreNode, ADominionAICharacter. Names: the item's display name (UItemData.Name FText: a drop's
-- ItemData, a gatherable's ItemData, a destructible's first drop), else the interaction prompt,
-- else a cleaned class name. Verbs: pickup (world items), gather (interactable resources), chop /
-- mine (the tool gate's category tag), attack (creatures), interact (anything else interactable).
M.LOOK_BASES = { "InteractionComponent", "DestructibleWorldActor", "OreNode", "DominionAICharacter" }
M.LOOK_SKIP = { BP_PlayerCharacter_C = true }

local function clean_class(cw)
    if not cw then return "?" end
    local s = cw:gsub("^BP_AI_", ""):gsub("^BP_", ""):gsub("_C$", ""):gsub("_Character$", ""):gsub("_%d+$", "")
    s = s:gsub("(%l)(%u)", "%1 %2") -- AshBranch -> Ash Branch
    return (s:gsub("_", " "))
end

local function text_of(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end

local function item_name(data) return U.valid(data) and text_of(U.try(function() return data.Name end)) or nil end

local function first_drop(comp)
    if not U.valid(comp) then return nil end
    local name, path
    pcall(function()
        comp.ItemsToDrop:ForEach(function(_, e)
            if name or path then return true end
            local d = U.try(function() return e:get() end) or e
            local sp = U.try(function() return d.ItemDataClass end)
            local obj = U.try(function() return sp:Get() end) or U.try(function() return sp:GetWeakPtr():Get() end)
            if U.valid(obj) then name, path = item_name(obj), U.path_of(obj) end
            if not path then path = U.str(U.try(function() return sp:GetObjectID():GetAssetPathName() end)) end
        end)
    end)
    return name, path
end

local function gate_verb(a)
    local verb
    local function scan(arr)
        if verb or arr == nil then return end
        pcall(function()
            arr:ForEach(function(_, e)
                local m = U.try(function() return e:get() end) or e
                local tag = U.str(U.try(function() return m.RequiredCategory.TagName end)) or ""
                if tag:find("Hatchet", 1, true) then verb = "chop" elseif tag:find("Pickaxe", 1, true) then verb = "mine" end
            end)
        end)
    end
    scan(U.try(function() return a.DamageModifiersWhenTree end))
    scan(U.try(function() return a.DamageComponent.DamageModifiers end))
    return verb
end

-- Describe one actor (cheap property reads). Returns a compact table for the wire.
function M.describe(a, ic, origin)
    local cw = U.class_word(a) or ""
    local d = { id = U.short(a), class = cw, position = U.to_wire(M.aim(a)), hp = U.health(a) }
    if origin then d.distance = U.cm_to_m(U.dist2d(origin, M.aim(a) or U.loc(a))) end
    local data = U.try(function() return a.ItemData end)
    local st = M.state_of(a)
    if st.stump then d.stump = true end
    if st.hidden then d.hidden = true end
    if U.valid(data) then
        d.name, d.item = item_name(data), U.path_of(data)
        local n = U.try(function() return a:GetStackSize() end)
        if n then d.count, d.kind, d.verb = n, "item", "pickup"
        else
            d.kind, d.verb = "gatherable", "gather"
            local avail = U.try(function() return a:IsResourceAvailable() end)
            if avail ~= nil then d.available = avail == true end
        end
    elseif U.try(function() return a.HealthComponent ~= nil and a.DamageComponent ~= nil end) and not cw:find("AI_", 1, true) then
        local dn, dp = first_drop(U.try(function() return a.ItemDropOnDestructionComponent end))
        d.kind, d.verb = "resource", gate_verb(a) or "hit"
        d.drops, d.drop_item = dn, dp
        local short = dn or (dp and (dp:match("%.ITEM_[%a]+_[%a]+_([%w_]+)$") or dp:match("%.([%w_]+)$")))
        d.name = short and (clean_class(cw) .. " (" .. short:gsub("_", " ") .. ")") or nil
    elseif cw and (cw:find("^BP_AI_") or U.try(function() return a.AiAttackComponent ~= nil end)) then
        d.kind, d.verb = "creature", "attack"
    end
    if ic then
        d.prompt = text_of(U.try(function() return ic.InteractionPrompt end))
        if not d.kind or d.verb == "hit" then d.kind, d.verb = "interactable", "interact" end
    end
    d.name = d.name or d.prompt or clean_class(cw)
    return d
end

local function words(s)
    local out = {}
    for w in tostring(s or ""):lower():gmatch("[%a]+") do
        if #w > 2 then out[#out + 1] = w end
    end
    return out
end

-- Pure: how well a description matches the words of `about` (0 = not at all).
function M.match_score(d, about)
    local q = words(about)
    if #q == 0 then return 0 end
    local hay = table.concat({ d.name or "", clean_class(d.class), d.prompt or "", d.drops or "", d.drop_item or "",
                               d.item or "", d.kind or "", d.verb or "" }, " "):lower()
    local score = 0
    for _, w in ipairs(q) do
        -- plural forms: branches -> branch, berries -> berry, logs -> log
        local forms = { w, (w:gsub("ies$", "y")), (w:gsub("es$", "")), (w:gsub("s$", "")) }
        for _, f in ipairs(forms) do
            if #f > 2 and hay:find(f, 1, true) then score = score + 1; break end
        end
    end
    return score / #q
end

-- look: {origin (cm), radius_cm=2000, about="sticks", max=15} -> ranked list of descriptions.
function M.look(opts)
    opts = opts or {}
    local origin, r = opts.origin, opts.radius_cm or 2000
    local seen, list = {}, {}
    for _, base in ipairs(M.LOOK_BASES) do
        for _, o in ipairs(U.find_all(base, { skip_defaults = true })) do
            local a, ic = o, nil
            if base == "InteractionComponent" then
                ic = o
                a = U.try(function() return o:GetOwner() end)
            end
            local id = U.alive(a) and U.short(a) or nil
            if id and not seen[id] and not M.LOOK_SKIP[U.class_word(a) or ""] then
                local at = M.aim(a) or U.loc(a)
                if not origin or U.dist(origin, at) <= r then
                    seen[id] = true
                    local ok, d = pcall(M.describe, a, ic, origin)
                    if ok and d then
                        d._score = M.match_score(d, opts.about)
                        list[#list + 1] = d
                    end
                end
            end
        end
    end
    table.sort(list, function(x, y)
        if x._score ~= y._score then return x._score > y._score end
        return (x.distance or 0) < (y.distance or 0)
    end)
    local out = {}
    for i = 1, math.min(#list, opts.max or 15) do
        local d = list[i]
        d.match = opts.about and U.round(d._score, 2) or nil
        d._score = nil
        out[#out + 1] = d
    end
    return out, #list
end

function M._reset() S.last_convert = {}; S.clock = nil end

return M
