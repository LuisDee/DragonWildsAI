-- build: Claude's building, from the game's own build data (route R2; design docs/design/build-primitive.md).
-- This file holds the READ part, the parts the design review is unlikely to change:
--   buildables {about?, can_build_now?, max?}: every piece HE has unlocked (PlayerController.ProgressComponent
--   .BuildingsUnlocked, the game's own list) with its name, description, category and material cost
--   (UBuildingPieceData.DisplayName / Description / Category / Requirements {Amount, ItemData}) and, against
--   what he carries (hotbar + bag), what is still missing. No hand list of pieces, no phrase map: the model
--   picks from this list.
-- The build action itself (open build mode, select, aim, read the preview, place, verify) comes after the
-- review and the live probes P1-P4 (design §7).
-- Read-only: property reads on the local player controller's components and data assets; nothing under
-- DW_PAUSE (array reads on objects being torn down crash natively, 21:49:34).
local M = { W = {} }
local W = M.W
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end

M.cfg = { max = 25, max_cap = 60, describe_max = 8 }

local function sense_U(api)
    local s = api.module("sense")
    return s and s.U, s
end

-- "/Game/.../BUILDPIECE_Chest.BUILDPIECE_Chest" -> "BUILDPIECE_Chest" (the asset name = a stable piece id)
local function asset(U, o)
    local p = U.valid(o) and U.path_of(o)
    return p and (p:match("%.([%w_]+)$") or p:match("([%w_]+)$")) or nil
end
local function text(U, v)
    local s = U.str(v)
    if s and s ~= "" and s ~= "None" then return s end
end

-- Elements of a reflected TArray: UE4SS hands them out either directly or as a param with :get().
local function each(U, arr, fn)
    if arr == nil then return end
    pcall(function()
        arr:ForEach(function(_, e)
            local v = U.try(function() return e:get() end)
            if v == nil then v = e end
            fn(v)
        end)
    end)
end

function W.pc(api)
    local _, s = sense_U(api)
    return s and type(s.local_pc) == "function" and s.local_pc() or nil
end

local function mem()
    local m = rawget(_G, "DWBuild")
    if type(m) ~= "table" then m = { static = {} }; _G.DWBuild = m end
    m.static = m.static or {}
    return m
end
M.STATIC_V = 2 -- bump when describe() changes shape (cached static data is per session)

-- His unlocked pieces: the UBuildingPieceData objects of ProgressComponent.BuildingsUnlocked (deduplicated:
-- live P1a, the Deluxe decorations are listed twice), or nil, why.
function W.unlocked(api)
    local U = sense_U(api)
    if not U then return nil, "no sense module" end
    if paused() then return nil, "paused" end
    local pc = W.pc(api)
    local prog = pc and U.try(function() return pc.ProgressComponent end)
    if not U.valid(prog) then return nil, "no ProgressComponent" end
    local out, seen = {}, {}
    each(U, U.try(function() return prog.BuildingsUnlocked end), function(d)
        local id = U.valid(d) and asset(U, d)
        if id and not seen[id] then seen[id] = true; out[#out + 1] = d end
    end)
    return out
end

-- One piece as data: {id, name, description, category, cost = {{item, name, count}}, xp, host_only, index}
-- Static per session: read once per piece (struct arrays and FText reads are cached, review finding 11).
function M.describe(api, d)
    local U = sense_U(api)
    local id = asset(U, d)
    local m = mem()
    local c = id and m.static[id]
    if c and c.v == M.STATIC_V then return c.p end
    local p = { id = id }
    p.name = text(U, U.try(function() return d.DisplayName end)) or p.id
    p.description = text(U, U.try(function() return d.Description end))
    local tag = text(U, U.try(function() return d.Category.TagName end))
    p.category = tag and ((tag:match("([%w_]+)$") or tag):gsub("(%l)(%u)", "%1 %2")) or nil
    p.cost = {}
    each(U, U.try(function() return d.Requirements end), function(r)
        local data = U.try(function() return r.ItemData end)
        local n = tonumber(U.try(function() return r.Amount end))
        local iid = asset(U, data)
        if iid and n and n > 0 then
            p.cost[#p.cost + 1] = { item = iid, name = text(U, U.try(function() return data.Name end)) or iid, count = n }
        end
    end)
    p.xp = tonumber(U.try(function() return d.ConstructionXPOnBuild end))
    p.index = tonumber(U.try(function() return d.BuildingPieceDataIndex end))
    p.shelter_text = text(U, U.try(function() return d.ShelterRequirementText end))
    -- the piece data carries only the tooltip's words (UBuildingPieceData, dump 26161880; the rule itself is on the built
    -- actor's BuildingShelter component): "Requires Shelter" (the Spinning Wheel) vs "Must Be Exposed" (the Campfire)
    local st = lower(p.shelter_text)
    if st:find("shelter", 1, true) and not st:find("expos", 1, true) then p.needs_shelter = true end
    if U.try(function() return d.bOnlyAvailableToHost end) == true then p.host_only = true end
    if id then m.static[id] = { v = M.STATIC_V, p = p } end
    return p
end

-- Materials in storage near him (the game also builds from linked storage, DISCOVERIES l.677): read-only
-- contents of chests/storage within radius_m, {item = n} plus {item = {container id, ...}}. Advisory only.
function W.storage_counts(api, radius_m)
    local counts, where = {}, {}
    if paused() then return counts, where end
    local invm = api.module("inventory")
    if not (invm and type(invm.inventory_of) == "function" and type(invm.external_rows) == "function") then return counts, where end
    for _, t in ipairs(api.census_things(radius_m or 15, 20) or {}) do
        if t.category == "interactables" and (t.kind == "storage" or t.kind == "container" or t.kind == "chest") then
            local inv = invm.inventory_of(api.actor_of(t))
            if inv then
                for item, n in pairs(invm.external_rows(inv).by_item or {}) do
                    counts[item] = (counts[item] or 0) + n
                    where[item] = where[item] or {}
                    where[item][#where[item] + 1] = t.id
                end
            end
        end
    end
    return counts, where
end

-- What is missing for one piece against carried counts {item = n} (and nearby storage, advisory):
-- {{item, name, need, have, in_storage?}} (empty = he can build it from what he carries)
function M.missing(piece, counts, storage)
    local out = {}
    for _, c in ipairs(piece.cost or {}) do
        local have = (counts or {})[c.item] or 0
        if have < c.count then
            local st = storage and storage[c.item] or nil
            out[#out + 1] = { item = c.item, name = c.name, need = c.count, have = have, in_storage = st }
        end
    end
    return out
end

local function score(api, p, about)
    if not about then return 0 end
    if lower(p.name) == lower(about) or lower(p.id) == lower(about) then return 2 end
    return api.match_score({ name = p.name, class = p.id, prompt = p.category, drops = p.description }, about)
end
-- The words of a name or an ask, with their singulars ("walls" -> walls, wall).
local STOP = { a = true, an = true, the = true, ["and"] = true, ["or"] = true, of = true, ["in"] = true, on = true, to = true,
               ["for"] = true, with = true, my = true, me = true, some = true, plus = true }
local function toks(s)
    local out, set = {}, {}
    for w in lower(s):gmatch("[%a%d]+") do
        if not set[w] then out[#out + 1] = w; set[w] = true end
        if #w > 3 and w:sub(-1) == "s" then set[w:sub(1, -2)] = true end
    end
    return out, set
end
M._toks = toks
-- Ranks pieces for an ask of several things ("foundation wall roof door crafting table firepit crate"): every word
-- gets its own best pieces in turn, so one word's many matches can't push another's off the list. Rung 2 run
-- 20261116-010103: the best 30 by total score were roof-support walls, the model never saw "Square Foundation",
-- "WALL WITH DOOR FRAME" or "Campfire", and three build calls failed on names.
-- A piece answers a word: 3 a word of its name, 2 its name shares 4+ letters with it ("firepit" / "Campfire"),
-- 1 a word of its id, category or description. rows: {name, id, category, description, can_build_now}.
-- -> the rows that answer any word, ranked; by_word = { word = { names, best first, at most 5 } }
function M.rank_about(rows, about)
    local qs = {}
    for _, w in ipairs((toks(about))) do if #w > 2 and not STOP[w] then qs[#qs + 1] = w end end
    if #qs == 0 then return nil end
    local lists = {}
    local _, qset = toks(about)
    for _, r in ipairs(rows) do
        local nl, ns = toks(r.name)
        local _, rest = toks(table.concat({ r.id or "", r.category or "", r.description or "" }, " "))
        r._hits, r._tier = 0, {}
        -- how much of its name the ask says: "Wall" for "walls" is all of it, "Roof Support Wall" a third (its
        -- numbers aside: "30 Roof" is a roof)
        local said, n = 0, 0
        for _, w in ipairs(nl) do
            if not STOP[w] and not w:match("^%d+$") then
                n = n + 1
                if qset[w] or (#w > 3 and w:sub(-1) == "s" and qset[w:sub(1, -2)]) then said = said + 1 end
            end
        end
        r._cov, r._len = n > 0 and said / n or 0, n
        for _, w in ipairs(qs) do
            local sing = (#w > 3 and w:sub(-1) == "s") and w:sub(1, -2) or w
            local t = (ns[w] or ns[sing]) and 3 or M.share_run(r.name, w) and 2 or (rest[w] or rest[sing]) and 1 or 0
            r._tier[w] = t
            if t >= 3 then r._hits = r._hits + 1 end
        end
    end
    for _, w in ipairs(qs) do
        local l = {}
        for _, r in ipairs(rows) do if r._tier[w] > 0 then l[#l + 1] = r end end
        table.sort(l, function(a, b)
            if a._tier[w] ~= b._tier[w] then return a._tier[w] > b._tier[w] end
            if a._cov ~= b._cov then return a._cov > b._cov end
            if a._len ~= b._len then return a._len < b._len end -- the plain piece before its variants
            if (a.can_build_now or false) ~= (b.can_build_now or false) then return a.can_build_now or false end
            if lower(a.name) ~= lower(b.name) then return lower(a.name) < lower(b.name) end
            return tostring(a.id) < tostring(b.id)
        end)
        lists[w] = l
    end
    local out, taken, by_word, whole = {}, {}, {}, lower(about)
    for _, r in ipairs(rows) do -- the ask is one piece's whole name: that piece first
        if lower(r.name) == whole or lower(r.id or "") == whole then out[#out + 1] = r; taken[r] = true end
    end
    -- then the pieces whose whole name the ask says in several words ("door frame wall" -> WALL WITH DOOR FRAME)
    local phrase = {}
    for _, r in ipairs(rows) do if not taken[r] and r._cov >= 1 and r._hits >= 2 then phrase[#phrase + 1] = r end end
    table.sort(phrase, function(a, b)
        if a._hits ~= b._hits then return a._hits > b._hits end
        if (a.can_build_now or false) ~= (b.can_build_now or false) then return a.can_build_now or false end
        if lower(a.name) ~= lower(b.name) then return lower(a.name) < lower(b.name) end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, r in ipairs(phrase) do out[#out + 1] = r; taken[r] = true end
    local named = {}
    local depth, more = 0, true
    while more do
        depth, more = depth + 1, false
        for _, w in ipairs(qs) do
            local r = lists[w][depth]
            if r then
                more = true
                if not taken[r] then out[#out + 1] = r; taken[r] = true end
                by_word[w], named[w] = by_word[w] or {}, named[w] or {}
                if #by_word[w] < 5 and not named[w][r.name] and (r._tier[w] >= 2 or #by_word[w] == 0) then
                    by_word[w][#by_word[w] + 1], named[w][r.name] = r.name, true
                end
            end
        end
    end
    for _, w in ipairs(qs) do by_word[w] = by_word[w] or {} end
    for _, r in ipairs(rows) do r._hits, r._tier, r._len, r._cov = nil, nil, nil, nil end
    return out, by_word
end

M.HANDLERS = {}
M.NEEDS = { buildables = { { "sense", "local_pc" }, { "inventory", "list" } } }

M.HANDLERS.buildables = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    args = args or {}
    local list, why = W.unlocked(api)
    if not list then
        return api.fail("state_unavailable", { why = why, detail = "I can't read my building unlocks right now." })
    end
    local counts = api.counts() or {}
    local storage = W.storage_counts(api, 15)
    local sense = api.module("sense")
    local function priv(p) -- true | false | nil (unreadable); never "a and false or nil"
        if not (sense and type(sense.has_privilege) == "function") then return nil end
        local ok, v = pcall(sense.has_privilege, p)
        if ok then return v end
        return nil
    end
    local can_build, is_owner = priv("build"), priv("owner")
    local about = need_str(args.about) and args.about or nil
    local rows = {}
    for _, d in ipairs(list) do
        local ok, p0 = pcall(M.describe, api, d)
        if ok and p0 and p0.id then
            local p = {}
            for k, v in pairs(p0) do p[k] = v end -- a copy: the cached static row stays clean
            p.missing = M.missing(p, counts, storage)
            local short = false
            for _, x in ipairs(p.missing) do if (x.have + (x.in_storage or 0)) < x.need then short = true end end
            p.can_build_now = #p.missing == 0 and can_build ~= false and not (p.host_only and is_owner ~= true)
            if #p.missing > 0 and not short then p.storage_may_cover = true end -- the game may build from nearby storage
            if p.host_only and is_owner ~= true then p.blocked_by = "host_only" end
            p._score = score(api, p, about)
            if args.can_build_now ~= true or p.can_build_now then rows[#rows + 1] = p end
        end
    end
    table.sort(rows, function(a, b)
        if a._score ~= b._score then return a._score > b._score end
        if a.can_build_now ~= b.can_build_now then return a.can_build_now end
        return lower(a.name) < lower(b.name)
    end)
    local by_word
    if about then
        local ranked, bw = M.rank_about(rows, about)
        if ranked and #ranked > 0 then rows, by_word = ranked, bw
        else
            local keep = {}
            for _, p in ipairs(rows) do if p._score > 0 then keep[#keep + 1] = p end end
            rows = keep
        end
    end
    local max = math.max(1, math.min(tonumber(args.max) or M.cfg.max, M.cfg.max_cap))
    local out = {}
    local shown = math.min(#rows, max)
    for i = 1, shown do
        local p = rows[i]
        p._score = nil
        if #p.missing == 0 then p.missing = nil end
        -- a long list is for choosing by name and cost: the tooltip text only when a few are shown
        if shown > M.cfg.describe_max then p.description = nil end
        p.index = nil
        out[#out + 1] = p
    end
    local data = { unlocked = #list, matched = #rows, shown = #out, pieces = out, about = about or api.null,
                   truncated = #rows > #out, may_build = can_build == nil and api.null or can_build }
    if by_word and next(by_word) then
        -- each word of the ask and the pieces that answer it, best first (none = no piece by that word)
        for _, l in pairs(by_word) do if #l == 0 then setmetatable(l, { __jsontype = "array" }) end end
        data.by_word = setmetatable(by_word, { __jsontype = "object" })
    end
    if can_build == false then data.note = "The server hasn't given me building rights here." end
    return { ok = true, data = data }
end

-- ------------------------------------------------------------------ the build action (design §2-4, review Rev 2)
-- build {piece, at?, near?, rotation?}: the player's path, one piece per call (review Q3: leave after each).
--   preflight (no key pressed): Build privilege (no_permission), resolve the piece from data (exact name/asset,
--     else a unique typo; ambiguous_target / unknown_target, never Category), host_only, advisory materials
--   approach: stand standoff = max(2.5 m, footprint + 1 m) from the spot (inside the 7 m camera reach)
--   open: B (IA_BuildMenu, one frame) -> read CurrentBuildMode == Selection; B again ONLY if it reads None
--   select: BuildingUIAPI:CallOnBuildingItemSelected(data) while Selection (the menu slot's own call)
--     -> Placement + CurrentlyPlacingPieceData == data
--   rotate: IA_Building_RotateZ presses (ModifyRotationStepDeg 15, P1a); rotation_verified = false until P4
--   check: placement.lua over the build preview: press ONLY when the OnValidityStateChange hook's last state is
--     Valid, newer than the latest aim, AND the MPC colour index reads 2 (P1b: 2 = Valid|NeedsSnapping), with
--     the preview within match_m; unreadable = no press (review finding 8)
--   place: the place input once (P2 decides which action; never twice within 0.25 s)
--   verify (settle up to cfg.verify_s): every requirement item fell (own + nearby storage) AND one of the
--     telemetry hook (BuildingPieceDataIndex), a new building actor of this piece near the point, or the
--     Construction XP rising; Client_ShowValidityNotification after the press = refused (game's words)
--   leave: Cancel until CurrentBuildMode == None (<= 3, one per tick), on EVERY exit path
-- Modal: claimed in input.lua ("build"): no reflex input lands while it is open; a reflex pre-empt leaves it
-- at once (on_suspend: release the claim, one Cancel; the orphan sweep finishes), resume re-opens.
-- Never a game call under DW_PAUSE (the job just waits; input.lua cleans a leftover mode on resume).
M.cfg.build = {
    standoff_m = 2.5, footprint_m = 1.5, reach_m = 7.0, open_wait_s = 1.5, select_wait_s = 2.0,
    verify_s = 6.0, leave_presses = 3, leave_wait_s = 0.5, timeout_s = 110, match_m = 1.5, rotate_step_deg = 15,
    budget_s = 25,
    settle_s = 4.0, -- a cursor read while it still closes on the spot is not a check, up to this long (placement.lua)
    -- the one-step aim (camrig.lua, issue B16): the rotation is solved from the camera boom's pivot, so the cursor is
    -- on the aim point 2 frames later and stands. Read aim_wait_s after the aim (>= 4 frames at 30 fps); a cursor read
    -- at least aim_settle_s after an exact aim counts as settled. false = the old aim from where the camera stands.
    aim_exact = true, aim_wait_s = 0.15, aim_settle_s = 0.12,
    actor_check_s = 0.1, -- after the press: look for the new piece this soon, and this often
    red_probe_s = 2.0, -- every spot red: press once and wait this long for the game's own reason (0 = off)
    shelter_up_m = 2.0, -- ... and standing more than this above / below its floor is not in it (on the roof)
    shelter_reach_m = 25, -- a shelter-only piece: my own covered floors this close to where it was asked count
    -- after the game confirms the build (telemetry / XP + spend), look this long for the new piece in the world
    -- (an actor of this piece within find_m of the preview that wasn't there before the press), so the reply can
    -- say where it stands (co-play 2026-11-01: structure was always null, the crate read as a failure)
    find_s = 2.5, find_m = 3.0, before_m = 10.0,
    -- on = "<piece id>:<side>": attach flush to a built piece (research 2026-11-01 §4.2). Aim snap_aim_m OUTSIDE the
    -- flush spot: the game's magnet (SnappingRadius 80 cm, 200 cm in Basic mode, live probe) pulls a snapping ghost
    -- onto it, a free one stays where I aimed. So "colour 2 AND the ghost sits on the flush spot (snap_tol_m)" is the
    -- positive snap signal colour 2 alone can't give (Valid vs NeedsSnapping). flush_tol_m: the census check after.
    free_tol_m = 0.15, free_tol_z_m = 0.3, snap_aim_m = 0.25, snap_tol_m = 0.06, snap_tol_z_m = 0.12, flush_tol_m = 0.06, stand_extra_m = 1.5, taken_m = 0.5,
    preview_waits = 6, edge_aim_m = 0.3,
    -- no preview actor (instance-only pieces): the cursor must stop gliding (settle_m between reads) within
    -- cursor_tol_m of the flush spot; up to cursor_checks reads per aim (live: ~1 m/s glide, reads every 0.35 s). Reads
    -- while the cursor still closes on the spot are not counted (placement.lua settle_s; 2026-11-02 02:3xZ on a slope it
    -- climbed 3.3 m -> 0.1 m in 14 reads and ran out just as it arrived: 3 walls lost)
    settle_m = 0.03, tremble_m = 0.15, cursor_tol_m = 0.2, cursor_tol_z_m = 0.25, cursor_checks = 14, corr_max_m = 2.0, corr_max_z_m = 1.2, edge_in_m = 0.3,
    -- speed (Luis's recording: he placed 11 walls from one spot, 0-0.3 m apart, 1-3 s each; MaxPlacementDistance 7 m):
    -- stay where I am when the aim point is within stay_m, my view of it is clear and I'm not in the piece's way
    stay_m = 6.0, stay_clear_m = 0.5, stay_off_floor_m = 0.15, stay_ceiling_m = 0.2,
    -- can't place from here: walk to the nearest spot whose predicted view lands on the aim point (camrig.stands)
    stand_search = true, stand_radii_m = { 2.5, 4.0, 5.5 }, stand_walk_s = 15, stand_arrive_m = 0.4, stand_view_every_s = 0.2, capsule_r_m = 0.45, batch_max = 12, reaim_cam_m = 0.15, reaims_max = 8,
    -- the cursor jumped from my aim onto the flush spot = a seen snap. Under edge_in_m: live 2026-11-16 a door frame's
    -- cursor sat 0.01 m from the flush spot, green, and was called off target: its cursor target is edge_in_m from the
    -- flush spot, 0.29999999999999716 in floats, and the rule asked for >= 0.3 (false on 21 % of positions)
    snap_jump_m = 0.25, snap_jump_tol_m = 0.15,
    ceiling_below_m = 0.2, ceiling_stand_m = 0.8, -- a ceiling/roof off a wall top: aim at the wall face this far below
    -- its top, standing this far past the middle of the cell it covers
    -- live P4 (2026-10-26): the validity hooks never fire (C++ calls, not ProcessEvent), so the MPC colour index
    -- (2 = Valid|NeedsSnapping) on a fresh, on-target preview authorises the press; the game refuses a
    -- NeedsSnapping press itself and Client_ShowValidityNotification names why. true = also require the hook.
    hook_required = false,
}
M.HOOK_PATHS = {
    validity = "/Script/Dominion.BuildModeComponent:OnValidityStateChange",
    refused = "/Script/Dominion.BuildInteractionComponent:Client_ShowValidityNotification",
    complete = "/Script/Dominion.BuildModeComponent:Client_TelemetryOnBuildingPieceComplete",
}
M.STATES = { [0] = "Valid", "Overlapping", "Floating", "NeedsFoundation", "NeedsSnapping", "Unstable", "MissingMaterials",
             "WrongPhysicalSurface", "InsideVault", "InsideProtectedArea", "ReachedCountLimit", "ShelterCheckFailed",
             "InsideBlockedRegion", "None" }
-- P1b: the game's own words per state (BuildInteractionComponent.ValidityNotificationTextMap), read once and
-- cached; these are the fallbacks when it can't be read
M.STATE_TEXT = { [1] = "Blocked", [2] = "You can't place this in the air.", [3] = "You need a foundation to build this.",
                 [5] = "Unstable", [6] = "You require more materials to build this.", [7] = "You can't build here",
                 [8] = "You can't build here", [9] = "Only the Host can build here.", [10] = "Placement limit reached for this piece.",
                 [11] = "You can only place this outside", [12] = "Cannot be placed in this region" }
M.STATE_REASON = { [1] = "blocked", [2] = "blocked", [3] = "blocked", [4] = "blocked", [5] = "blocked", [6] = "missing_materials",
                   [7] = "blocked", [8] = "blocked", [9] = "no_permission", [10] = "limit_reached", [11] = "blocked", [12] = "blocked" }
-- The place input (live P2, IMC_BuildingMode: IA_Building_QuickInteract = LeftMouseButton; IA_PrimaryAction is NOT
-- mapped in build mode). Read from BuildInteractionComponent.QuickInteractAction, the path as fallback.
M.PLACE_ACTIONS = { "/Game/Gameplay/Inputs/Actions/Building/IA_Building_QuickInteract.IA_Building_QuickInteract" }
M.MENU_ACTION = "/Game/Gameplay/Inputs/Actions/UI/IA_BuildMenu.IA_BuildMenu"
-- A rejected preview spot in words. The MPC colour is not the state (DISCOVERIES "ValiditySpawnStateToScalarIndex"):
-- 1 = Overlapping / Floating / NeedsFoundation / Unstable / MissingMaterials / InsideVault / protected / limit /
-- blocked region; 0 = WrongPhysicalSurface or None.
M.REJECT_WORDS = {
    -- red is all the preview shows: the game names the cause (blocked, no foundation, unstable ...) only on a press
    -- (dump 26161880: the scalar is a colour; the validity hooks never fire). Never list guesses as the cause (tools leg
    -- run 5, 03:5xZ: "something in the way" became "the walls I put up block every spot")
    preview_red = "the preview stayed red there (the game doesn't say why while previewing)",
    preview_none = "there was no surface it could go on there",
    preview_off_target = "the preview didn't land where I aimed",
    not_snapped = "the preview didn't snap onto the piece (it stayed where I aimed instead of sitting flush)",
    settling = "the preview kept sliding and never settled where I aimed",
}
-- The success reply in the order the model reads it (dkjson __jsonorder; the bridge encodes data as is): what was
-- placed and where first, the rejected preview spots last and labelled as such.
M.RESULT_ORDER = { "built", "placed", "name", "piece", "structure", "position", "distance_m", "direction", "facing",
                   "attached_to", "side", "flush", "gap_m", "offset_m", "level_m", "facing_off_deg", "snap_moved_m",
                   "spent", "xp", "evidence", "rejected_previews_before_placing", "rotation_verified" }
local RESULT_MT = { __jsontype = "object", __jsonorder = M.RESULT_ORDER }
local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
-- Compass word of a horizontal vector: north = -Y, east = +X (DISCOVERIES "Map compass", brain/geom.direction).
local function compass(dx, dy)
    local ang = (math.deg(math.atan(dx, -dy)) + 360) % 360
    return COMPASS[math.floor(((ang + 22.5) % 360) / 45) + 1]
end
M._compass = compass
local function r1(x) return math.floor(x * 10 + 0.5) / 10 end

-- ---------- world reads/writes (every one replaceable in tests)
local function IN(api) local m = api.module("input"); return m and type(m.gate) == "function" and m or nil end
function W.mode(api) local i = IN(api); return i and i.build_mode() or nil end
function W.bm(api)
    local U = sense_U(api)
    local pc = W.pc(api)
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    return U.valid(bm) and bm or nil
end
function W.placing(api) -- CurrentlyPlacingPieceData is a TWeakObjectPtr: :Get() (live P4, 2026-10-26)
    local U = sense_U(api)
    local bm = W.bm(api)
    local w = bm and U.try(function() return bm.CurrentlyPlacingPieceData end)
    local d = w and U.try(function() return w:Get() end)
    return d and asset(U, d) or nil
end
function W.press(api, action) -- the modal owner's own presses (raw: build owns the modal)
    local i = IN(api)
    if type(action) == "string" then action = sense_U(api).find_object(action) end
    if not action then return false end
    return i and i.raw_inject(action) == true or false
end
function W.menu_action() return M.MENU_ACTION end
function W.place_action(api)
    local U = sense_U(api)
    local pc = W.pc(api)
    local a = pc and U.try(function() return pc.BuildInteractionComponent.QuickInteractAction end)
    if U.valid(a) then return a end
    for _, p in ipairs(M.PLACE_ACTIONS) do local x = U.find_object(p); if x then return x end end
end
function W.rotate_action(api) local U = sense_U(api); local bm = W.bm(api); return bm and U.try(function() return bm.ModifyRotationAction end) end
function W.select(api, data)
    local U = sense_U(api)
    local mem_ = mem()
    if not (mem_.ui and U.valid(mem_.ui)) then mem_.ui = U.find_all("BuildingUIAPI", { skip_defaults = true })[1] end
    local ui = mem_.ui
    if not U.valid(ui) then return false, "no BuildingUIAPI" end
    local ok, err = pcall(function() ui:CallOnBuildingItemSelected(data) end)
    return ok, (not ok) and tostring(err) or nil
end
local CR
local function camrig()
    CR = CR or assert(loadfile((debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or (ROOT .. "/client_mod/scripts")) .. "/camrig.lua"))()
    return CR
end
function W.rig(api)
    local sm = api.module("sense")
    local pc, pawn = W.pc(api), sm and sm.local_pawn and sm.local_pawn()
    if not (pc and pawn) then return nil end
    local okr, rig = pcall(function() return camrig().rig(sense_U(api), pc, pawn) end)
    return okr and rig or nil
end
-- How far from the aim point my view may land and still count as on it, standing at pos (see W.stay_ok).
function W.view_tol(on, pos)
    local cfg = M.cfg.build
    local a = on.anchor
    local top = a.position[3] + a.box.origin[3] + a.box.extent[3]
    local mount = on.mount or {} -- none: a piece on a top (a station on a foundation)
    local tol = cfg.stay_clear_m + ((mount.ceiling and M.thin_axis(a.box)) and a.box.extent[M.thin_axis(a.box)] or 0)
    -- a roof off a wall top snaps from the wall face on the roof's side only (live 2026-11-16: a view 0.95 m off
    -- passed the old loose rule and the preview came no nearer than 1.75 m)
    if mount.ceiling then return cfg.stay_ceiling_m end
    local on_floor = on.side == "in" or math.abs((pos[3] - 0.88) - top) <= 0.6
    return on_floor and tol or math.min(tol, cfg.stay_off_floor_m)
end
local function trace_m(api)
    return function(a, b)
        local hit, o = W.trace(api, { X = a[1] * 100, Y = a[2] * 100, Z = a[3] * 100 }, { X = b[1] * 100, Y = b[2] * 100, Z = b[3] * 100 })
        local ip = hit and o and o.ImpactPoint
        if ip and type(ip.X) == "number" then return true, { ip.X / 100, ip.Y / 100, ip.Z / 100 } end
        return false
    end
end
-- Where to stand to place an attach: the spots round its aim point whose predicted view lands on it and that aren't
-- where the piece goes, the shortest walk first (camrig.stands). nil when the boom can't be read.
function W.stands(api, job, here)
    local cfg = M.cfg.build
    local on = job.on
    local rig = cfg.aim_exact and W.rig(api)
    if not (rig and here and on and on.anchor and on.anchor.box) then return nil end
    local spot, axis = M.flush_spot(on.anchor, on.side, on.box)
    local aim = M.aim_point(on, spot, axis)
    if not (spot and aim) then return nil end
    local okc, list = pcall(function()
        return camrig().stands(rig, here, aim, trace_m(api), { max = 3, radii = cfg.stand_radii_m,
            tol_for = function(pos) return W.view_tol(on, pos) end,
            ok = function(pos) return not M.in_the_way(pos, spot, on.box, (on.mount or {}).yaw or 0) end })
    end)
    return okc and list or nil
end
-- What the screen centre would land on if I aimed at pos from here (camrig.look with the game's line trace); nil
-- when the boom can't be read.
function W.look(api, pos, tol_m)
    local rig = M.cfg.build.aim_exact and W.rig(api)
    if not (rig and pos) then return nil end
    local okl, look = pcall(function() return camrig().look(rig, pos, trace_m(api), tol_m) end)
    return okl and look or nil
end
function W.camera(api)
    local U = sense_U(api)
    local pc = W.pc(api)
    local v = pc and U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end
end
-- Aim the screen centre at pos. -> distance camera -> pos (m), exact (true: solved from the camera boom's pivot, the
-- centre ray passes through pos once the camera has swung, 2 frames; issue B16).
function W.aim(api, pos)
    local U = sense_U(api)
    local pc = W.pc(api)
    local sm = api.module("sense")
    local pawn = sm and sm.local_pawn and sm.local_pawn()
    if pc and pawn and pos and M.cfg.build.aim_exact then
        local okr, dist = pcall(function() return (camrig().aim(U, pc, pawn, pos)) end)
        if okr and dist then return dist, true end
    end
    local cam = W.camera(api) or api.my_position()
    if not (pc and cam and pos) then return nil end
    local dx, dy, dz = pos[1] - cam[1], pos[2] - cam[2], (pos[3] or cam[3]) - cam[3]
    pcall(function() pc:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }) end)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- MPC reads (UKismetMaterialLibrary, pure): the colour index (P1b: 2 = Valid|NeedsSnapping) and the cursor
-- position. [UNVERIFIED until P4a]
function W.mpc(api)
    local U = sense_U(api)
    local m = mem()
    local bm = W.bm(api)
    if not bm then return nil end
    if not (m.kml and U.valid(m.kml)) then m.kml = U.find_object("/Script/Engine.Default__KismetMaterialLibrary") end
    local mpc = U.try(function() return bm.MaterialParameterCollection end)
    if not (m.kml and U.valid(mpc)) then return nil end
    local pawn = api.module("sense") and api.module("sense").local_pawn and api.module("sense").local_pawn()
    local idx = U.try(function() return m.kml:GetScalarParameterValue(pawn, mpc, U.try(function() return bm.PlacingValidityStateIndexMPN end)) end)
    local pos = U.try(function() return m.kml:GetVectorParameterValue(pawn, mpc, U.try(function() return bm.CursorWorldPositionMPN end)) end)
    local okp, x, y, z = pcall(function() return pos.R, pos.G, pos.B end)
    return { index = tonumber(idx), position = (okp and type(x) == "number") and { x / 100, y / 100, z / 100 } or nil }
end
-- The placement preview actor (BaseBuildingActor with bIsPreview, managed by my PC): found ONCE per job after
-- select (one find_all), then re-validated. -> actor | nil
function W.preview_actor(api, job)
    local U = sense_U(api)
    if job and job.preview_obj and U.valid(job.preview_obj) then return job.preview_obj end
    local pc = W.pc(api)
    for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
        if U.try(function() return a.bIsPreview end) == true then
            local m = U.try(function() return a.PlayerControllerManagingPlacement end)
            if not pc or (U.valid(m) and U.short(m) == U.short(pc)) then
                if job then job.preview_obj = a end
                return a
            end
        end
    end
end
-- Does this piece only place snapped (its placement profile's bCanOnlyBeSnapped)? Then colour 2 may mean
-- NeedsSnapping. Read from the preview actor's loaded BuildingPieceDerivedData.PlacementProfileRowHandle via
-- UE4SS's DataTable:FindRow (live P5 probe 2026-10-26: Campfire -> FloorPropNonOverlapProfile, false).
-- -> true | false | nil (unreadable: treated as ambiguous)
function W.snap_only(api, a)
    local U = sense_U(api)
    if paused() or not U.valid(a) then return nil end
    local dd = U.try(function() return a.BuildingPieceDerivedData end)
    local h = U.valid(dd) and U.try(function() return dd.PlacementProfileRowHandle end)
    local dt = h and U.try(function() return h.DataTable end)
    local name = h and U.str(U.try(function() return h.RowName end))
    if not (U.valid(dt) and name) then return nil end
    local ok, row = pcall(function() return dt:FindRow(name) end)
    if not ok or row == nil then return nil end
    local v = U.try(function() return row.bCanOnlyBeSnapped end)
    if v == nil then return nil end
    return v == true
end
function W.construction_xp(api)
    local me = api.me and api.me() or nil
    for _, s in ipairs((me and me.skills) or {}) do if lower(s.skill) == "construction" then return tonumber(s.xp) end end
end
-- Piece index (BuildingPieceDataIndex) -> {data, id, name} from my unlocked pieces (static; re-read every 30 s at most)
local function piece_index(api)
    local m = mem()
    local t = api.now()
    if m.by_index and m.by_index_t and t - m.by_index_t < 30 then return m.by_index end
    local by = m.by_index or {}
    for _, d in ipairs((W.unlocked(api)) or {}) do
        local ok, p = pcall(M.describe, api, d)
        if ok and p and p.index then by[p.index] = { data = d, id = p.id, name = p.name } end
    end
    m.by_index, m.by_index_t = by, t
    return by
end
-- The client's census of built pieces (live 2026-11-01): a structural piece (a Square Foundation, built and confirmed)
-- has NO actor on the client: it is a HISM instance on a CellBuildingProxy; only props (crate, stations) get a
-- BaseBuildingActor. Every piece is in GlobalBuildingManager.BuildingPieces (TMap<uint32 ID, FBuildingPieceState>;
-- .ClientVisible = BuildingPieceDataIndex, Location cm (PlacementZOffset applied: 0.5 m above its preview), Yaw,
-- bGhosted, StabilityValue); the replicated fast array BuildingReplicationArray is empty on a client.
-- -> {{id, pid, index, piece, name, data, position, yaw, ghosted, stability, actor?}} within r (2D) of pos | nil
-- (unreadable). id = the actor's id when it has one (= sense's interactable id), else "BuildingPiece_<ID>".
function W.built_pieces(api, pos, r)
    local U = sense_U(api)
    if paused() or not (U and pos) then return nil end
    local m = mem()
    if not (m.gbm and U.valid(m.gbm)) then
        m.gbm = nil
        for _, a in ipairs(U.find_all("GlobalBuildingManager", { skip_defaults = true }) or {}) do if U.valid(a) then m.gbm = a end end
    end
    local gbm = m.gbm
    local map = gbm and U.try(function() return gbm.BuildingPieces end)
    if map == nil then return nil end
    local out, by = {}, piece_index(api)
    local ok = pcall(function()
        map:ForEach(function(k, v)
            local st = U.try(function() return v:get() end) or v
            local cv = st and U.try(function() return st.ClientVisible end)
            local l = cv and U.try(function() return cv.Location end)
            local okp, x, y, z = pcall(function() return l.X, l.Y, l.Z end)
            if okp and type(x) == "number" and math.sqrt((x / 100 - pos[1]) ^ 2 + (y / 100 - pos[2]) ^ 2) <= r then
                local pid = tonumber((U.try(function() return k:get() end)))
                local idx = tonumber((U.try(function() return cv.BuildingPieceDataIndex end)))
                local info = (idx and by[idx]) or {}
                if pid then
                    out[#out + 1] = { pid = pid, id = "BuildingPiece_" .. pid, index = idx, piece = info.id, name = info.name, data = info.data,
                                      position = { x / 100, y / 100, z / 100 }, yaw = r1(tonumber((U.try(function() return cv.Yaw end))) or 0),
                                      ghosted = U.try(function() return cv.bGhosted end) == true or nil,
                                      stability = tonumber((U.try(function() return cv.StabilityValue end))) }
                end
            end
        end)
    end)
    if not ok then return nil end
    local by_pid = {}
    for _, e in ipairs(out) do by_pid[e.pid] = e end
    if next(by_pid) then -- pieces with an actor: its id and the actor itself (its own box, its name)
        for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
            if U.try(function() return a.bIsPreview end) ~= true then
                local e = by_pid[tonumber((U.try(function() return a.BuildingPieceID end))) or -1]
                if e then
                    e.id, e.actor = U.short(a), a
                    -- an actor's name changes when the game re-creates it (live 19:40Z: his crate was _2147144746,
                    -- then _2147480411, then _2147480415); its piece id (pid) stays. Remember every name it had.
                    m.pid_of = m.pid_of or {}
                    m.pid_of[e.id] = e.pid
                    if not e.name then -- a piece I haven't unlocked: the actor's own piece data names it
                        local d = U.try(function() return a.BuildingPieceData end)
                        if U.valid(d) then e.name, e.piece = text(U, U.try(function() return d.DisplayName end)), e.piece or asset(U, d) end
                    end
                end
            end
        end
    end
    return out
end
-- Built pieces of this piece within r metres of pos (the piece census above; the actor scan if it is unreadable).
function W.structures_near(api, piece_id, pos, r)
    local U = sense_U(api)
    local out = {}
    if paused() or not pos then return out end
    local list = W.built_pieces(api, pos, r)
    if list then
        for _, e in ipairs(list) do
            if e.piece == piece_id then out[#out + 1] = { id = e.id, position = e.position, yaw = e.yaw, pid = e.pid } end
        end
        return out
    end
    for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
        local d = U.try(function() return a.BuildingPieceData end)
        if asset(U, d) == piece_id and U.try(function() return a.bIsPreview end) ~= true then
            local at = U.loc(a)
            if at and math.sqrt((at.X / 100 - pos[1]) ^ 2 + (at.Y / 100 - pos[2]) ^ 2) <= r then
                local yaw = tonumber((U.try(function() return a:K2_GetActorRotation().Yaw end))) -- (()) = one value, nil-safe
                out[#out + 1] = { id = U.short(a), position = { at.X / 100, at.Y / 100, at.Z / 100 }, yaw = yaw }
            end
        end
    end
    return out
end
-- The piece this press built: an actor of this piece within cfg.find_m of where the preview stood that wasn't
-- there before the press (job.before_ids, read at the press), the nearest one. -> {id, position, yaw} | nil
function W.new_structure(api, job)
    local at = (job.preview and job.preview.position) or (job.spot and job.spot.position)
    if not at then return nil end
    local best, bd
    for _, s in ipairs(W.structures_near(api, job.piece.id, at, M.cfg.build.find_m) or {}) do
        if not (job.before_ids and job.before_ids[s.id]) and s.position then
            local d = math.sqrt((s.position[1] - at[1]) ^ 2 + (s.position[2] - at[2]) ^ 2)
            if not bd or d < bd then best, bd = s, d end
        end
    end
    return best
end
local function v3m(U, v) -- an FVector in cm -> {x, y, z} metres
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end
end
-- {origin, extent} metres of an FBoxSphereBounds (the piece's local box: origin relative to the actor location)
local function box_of(U, b)
    if not b then return nil end
    local e, o = v3m(U, U.try(function() return b.BoxExtent end)), v3m(U, U.try(function() return b.Origin end))
    if e and o then return { extent = e, origin = o } end
end
-- A piece's placement profile and size from its OWN data, no preview needed: UBuildingPieceData.DerivedData (a soft
-- pointer: its path, then StaticFindObject = only when already loaded; it is once the piece was selected). Live
-- 2026-11-01: Square Foundation -> FoundationProfile, bCanOnlyBeSnapped false, box 300 cm cube hanging BELOW the
-- actor origin (its location is its top), PlacementZOffset 50; Crate -> FloorPropProfile, box on top of its origin.
-- -> {snap_only = true|false|nil, box = {origin, extent}, profile} | nil (not loaded yet). Cached per piece.
function W.piece_profile(api, data)
    local U = sense_U(api)
    local id = asset(U, data)
    local m = mem()
    m.profiles = m.profiles or {}
    if id and m.profiles[id] then return m.profiles[id] end
    if paused() or not U.valid(data) then return nil end
    local soft = U.try(function() return data.DerivedData end)
    local path = soft and U.str(U.try(function() return soft:GetObjectID():GetAssetPathName() end))
    local dd = path and U.find_object(path)
    if not U.valid(dd) then return nil end
    local p = { box = box_of(U, U.try(function() return dd.BuildingPieceLocalBounds end)),
                z_offset = (tonumber((U.try(function() return dd.PlacementZOffset end))) or 0) / 100 }
    local h = U.try(function() return dd.PlacementProfileRowHandle end)
    local dt = h and U.try(function() return h.DataTable end)
    p.profile = h and U.str(U.try(function() return h.RowName end)) or nil
    if U.valid(dt) and p.profile then
        local ok, row = pcall(function() return dt:FindRow(p.profile) end)
        if ok and row ~= nil then
            local v = U.try(function() return row.bCanOnlyBeSnapped end)
            if v ~= nil then p.snap_only = v == true end
        end
    end
    if id then m.profiles[id] = p end
    return p
end
-- One built piece by its id: {id, name, piece, position (m), yaw, box} | nil
function W.actor_info(api, id)
    local U = sense_U(api)
    if paused() or not need_str(id) then return nil end
    local here = api.my_position()
    local list = here and W.built_pieces(api, here, 200)
    if list then
        for _, e in ipairs(list) do
            if e.id == id then
                -- size: an actor's own box; an instance-only piece's from its data (nil until that data is loaded:
                -- start_build then goes on with a provisional box, re-read once the new piece is selected)
                local box = e.actor and box_of(U, U.try(function() return e.actor.BuildingPieceLocalBounds end))
                if not box and e.data then box = (W.piece_profile(api, e.data) or {}).box end
                return { id = id, pid = e.pid, piece = e.piece, data = e.data, name = e.name or ("building piece #" .. tostring(e.index)),
                         position = e.position, yaw = e.yaw, box = box }
            end
        end
        return nil
    end
    for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
        if U.short(a) == id and U.try(function() return a.bIsPreview end) ~= true then
            local at = U.loc(a)
            local data = U.try(function() return a.BuildingPieceData end)
            return { id = id, piece = asset(U, data), name = U.valid(data) and text(U, U.try(function() return data.DisplayName end)) or id,
                     position = at and { at.X / 100, at.Y / 100, at.Z / 100 } or nil,
                     yaw = tonumber((U.try(function() return a:K2_GetActorRotation().Yaw end))) or 0,
                     box = box_of(U, U.try(function() return a.BuildingPieceLocalBounds end)) }
        end
    end
end
-- The preview actor's yaw (degrees) | nil
function W.preview_yaw(api, job)
    local U = sense_U(api)
    local pa = W.preview_actor(api, job)
    return pa and tonumber((U.try(function() return pa:K2_GetActorRotation().Yaw end))) or nil
end

-- ---------- attach geometry (pure; testable offline). Sides are compass words: north = -Y, east = +X.
M.SIDES = { n = "N", north = "N", e = "E", east = "E", s = "S", south = "S", w = "W", west = "W", top = "top", up = "top", above = "top",
            ["in"] = "in", inside = "in", frame = "in" }
local SIDE_DIR = { N = { 0, -1 }, E = { 1, 0 }, S = { 0, 1 }, W = { -1, 0 } }
-- The anchor's own horizontal axis nearest a compass side, and the box half-sizes along it:
-- -> axis {x, y}, half of the anchor along it, the axis index (1 = its local X, 2 = local Y)
local function side_axis(anchor, side)
    local d = SIDE_DIR[side]
    local yaw = math.rad(anchor.yaw or 0)
    local ax = { { math.cos(yaw), math.sin(yaw) }, { -math.sin(yaw), math.cos(yaw) } }
    local best, bdot, bi
    for i, a in ipairs(ax) do
        for _, sgn in ipairs({ 1, -1 }) do
            local dot = (a[1] * sgn) * d[1] + (a[2] * sgn) * d[2]
            if not bdot or dot > bdot then best, bdot, bi = { a[1] * sgn, a[2] * sgn }, dot, i end
        end
    end
    return best, bi
end
-- A wall-like piece: its box is thin on one horizontal axis (live: Wall 303 x 100 cm, extent 151.5 x 50), or a
-- shorter wall as tall as it is long (live 20:5xZ: MEDIUM WALL 150 x 100 x 150 cm, extent 75 x 50 x 75, read as a
-- tile, so its flush spot was 0.5 m out and both walls read NOT flush) -> that axis' index (1 = local X, 2 = local
-- Y) | nil (a tile, a prop: a table is wide but low)
function M.thin_axis(box)
    if not box then return nil end
    local ex, ey, ez = box.extent[1], box.extent[2], box.extent[3] or 0
    if ey <= 0.4 * ex or (ey <= 0.7 * ex and ex >= 0.6 and ez >= 0.9 * ex) then return 2 end
    if ex <= 0.4 * ey or (ex <= 0.7 * ey and ey >= 0.6 and ez >= 0.9 * ey) then return 1 end
end
-- Where a new piece (its box) stands against anchor's side: {x, y, z} metres (the new actor's location), the side's
-- axis, and the mount {edge = true, yaw = the yaw it must have} for a wall-like piece.
-- Sides: a tile goes beside it at the same level (tops flush); a wall-like piece stands ON that edge (its centre on
-- the edge line, its bottom on the anchor's top, its thin axis across the edge); top: the new box's bottom on the
-- anchor box's top.
function M.flush_spot(anchor, side, new_box)
    local ab, nb = anchor.box, new_box or anchor.box
    if not (anchor.position and ab and nb) then return nil end
    local p = anchor.position
    local top = p[3] + ab.origin[3] + ab.extent[3]
    if side == "top" then
        local o = anchor.top_off or { 0, 0 } -- beside what already stands on its middle (M.top_free)
        return { p[1] + o[1], p[2] + o[2], top - (nb.origin[3] - nb.extent[3]) }, nil
    end
    if side == "in" then -- into a frame (a door in a door-frame wall): the frame's own spot and facing, bottoms level
        local bottom = p[3] + ab.origin[3] - ab.extent[3]
        return { p[1], p[2], bottom - (nb.origin[3] - nb.extent[3]) }, nil, { edge = true, inside = true, yaw = (anchor.yaw or 0) % 360 }
    end
    local axis, i = side_axis(anchor, side)
    local t = M.thin_axis(nb)
    if M.thin_axis(ab) and not t then
        -- off a wall's top toward that side (a ceiling tile / roof on the wall): its edge on the wall's line, its top
        -- flush with the wall's top, the same 90 degree grid as the wall
        local half = nb.extent[i]
        if nb.extent[3] >= 0.5 then
            -- a sloped roof over the cell on that side, its low eave on the wall's top. From Luis's house (census
            -- 2026-11-01): 45° Roofs at the cell centres, 1.47 m over the wall tops (floor + 4.5 m), the eave toward
            -- the wall at the piece's local +X (yaw 90 = eave S, rising N). So: the cell centre (its ridge-wise
            -- half), up by that half times the slope (height / run of its bounds), facing away from the wall.
            local hh = math.min(nb.extent[1], nb.extent[2])
            local slope = nb.extent[3] / math.max(nb.extent[1], nb.extent[2])
            local yaw = math.deg(math.atan(-axis[2], -axis[1])) % 360
            return { p[1] + axis[1] * hh, p[2] + axis[2] * hh, top + hh * slope }, axis,
                { ceiling = true, roof = true, yaw = yaw, per = 360 }
        end
        return { p[1] + axis[1] * half, p[2] + axis[2] * half, top - (nb.origin[3] + nb.extent[3]) }, axis,
            { ceiling = true, yaw = (anchor.yaw or 0) % 360, per = 90 }
    end
    if t and not M.thin_axis(ab) then
        local yaw = ((anchor.yaw or 0) + (t == i and 0 or 90)) % 360
        return { p[1] + axis[1] * ab.extent[i], p[2] + axis[2] * ab.extent[i], top - (nb.origin[3] - nb.extent[3]) }, axis,
            { edge = true, yaw = yaw }
    end
    local half = ab.extent[i] + nb.extent[i] -- the same local axis (the new piece takes the anchor's facing)
    return { p[1] + axis[1] * half, p[2] + axis[2] * half, p[3] }, axis
end
-- How the new piece sits against the anchor (census positions): gap along the side's axis, level difference, and
-- facing off by (degrees: mod 90 for tiles; mod 180 against the yaw it must have for a wall on an edge).
-- flush = all within tol.
function M.flush_report(anchor, side, new_box, built, tol)
    local want, axis, mount = M.flush_spot(anchor, side, new_box)
    if not (want and built and built.position) then return nil end
    local b = built.position
    local gap = axis and ((b[1] - want[1]) * axis[1] + (b[2] - want[2]) * axis[2]) or math.sqrt((b[1] - want[1]) ^ 2 + (b[2] - want[2]) ^ 2)
    local side_off = axis and ((b[1] - want[1]) * -axis[2] + (b[2] - want[2]) * axis[1]) or 0
    local level = b[3] - want[3]
    local per = mount and (mount.per or 180) or 90
    local yo = ((((built.yaw or 0) - (mount and mount.yaw or anchor.yaw or 0)) % per) + per) % per
    if yo > per / 2 then yo = yo - per end
    local r = { gap_m = math.floor(gap * 100 + 0.5) / 100, offset_m = math.floor(side_off * 100 + 0.5) / 100,
                level_m = math.floor(level * 100 + 0.5) / 100, facing_off_deg = math.floor(yo * 10 + 0.5) / 10 }
    r.flush = math.abs(gap) <= tol and math.abs(side_off) <= tol and math.abs(level) <= tol and math.abs(yo) <= 2
    return r
end
-- Does my capsule (here = its centre, m) overlap the new piece's box at spot (turned yaw)? Then I'd be in its way.
function M.in_the_way(here, spot, box, yaw)
    if not (here and spot and box) then return false end
    local r = M.cfg.build.capsule_r_m
    local c = math.rad(yaw or 0)
    local dx, dy = here[1] - spot[1], here[2] - spot[2]
    local lx, ly = dx * math.cos(c) + dy * math.sin(c), -dx * math.sin(c) + dy * math.cos(c)
    if math.abs(lx - (box.origin[1] or 0)) > box.extent[1] + r or math.abs(ly - (box.origin[2] or 0)) > box.extent[2] + r then return false end
    local zlo, zhi = spot[3] + box.origin[3] - box.extent[3], spot[3] + box.origin[3] + box.extent[3]
    return here[3] - 0.88 < zhi and here[3] + 0.88 > zlo
end
-- A floor's top already has a piece on its middle: the free quarter of the top nearest me, as an offset from the
-- middle (candidates in, the free ones out, the nearest taken; a player puts a crate beside the table, not on it).
-- rows: census. -> { dx, dy } | nil (no free quarter)
function M.top_free(anchor, new_box, rows, here)
    local ab = anchor.box
    if not (ab and new_box and anchor.position) or M.thin_axis(ab) then return nil end
    local c = math.rad(anchor.yaw or 0)
    local z = anchor.position[3] + ab.origin[3] + ab.extent[3] - (new_box.origin[3] - new_box.extent[3])
    local best, bd
    for _, q in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
        local lx, ly = q[1] * ab.extent[1] / 2, q[2] * ab.extent[2] / 2
        local off = { lx * math.cos(c) - ly * math.sin(c), lx * math.sin(c) + ly * math.cos(c) }
        local p = { anchor.position[1] + off[1], anchor.position[2] + off[2], z }
        if #M.standing_in(rows, p, new_box, anchor.yaw, { [anchor.id] = true }, 0.2) == 0 then
            local d = here and math.sqrt((p[1] - here[1]) ^ 2 + (p[2] - here[2]) ^ 2) or 0
            if not bd or d < bd then best, bd = off, d end
        end
    end
    return best
end
-- Where the camera must point for an attach (the rotate phase aims there): a wall's top face just inside the edge,
-- a frame's lintel, a wall's face just under its top (a ceiling), else the flush spot itself.
function M.aim_point(on, spot, axis)
    local a = on.anchor
    if not (a and a.position and a.box and spot) then return spot end
    local cfg = M.cfg.build
    local top = a.position[3] + a.box.origin[3] + a.box.extent[3]
    local bottom = a.position[3] + a.box.origin[3] - a.box.extent[3]
    if on.side == "in" then return { a.position[1], a.position[2], bottom + (top - bottom) * 0.88 } end
    if on.mount and on.mount.ceiling and axis then return { a.position[1] + axis[1] * 0.1, a.position[2] + axis[2] * 0.1, top - cfg.ceiling_below_m } end
    if on.mount and axis then return { spot[1] - axis[1] * cfg.edge_in_m, spot[2] - axis[2] * cfg.edge_in_m, top } end
    return spot
end
-- What stands on each edge of a floor piece (a foundation) and over it, from the census: the perception a house
-- needs (which edges still want a wall, which cells have a ceiling, which frames are still openings).
-- rows: {id, name, piece, position, yaw, box}.
-- -> { [floor id] = { edges = {N = "open" | "<name> <id>" | "beside: <name> <id>", ...}, ceiling = "<name> <id>",
--                     inside = {N = "<name> <id>" (a door in that frame) | "an open doorway, no door in it" |
--                               "a window opening"} } }
-- A door stands in its frame on the same edge line, its bottom level with the frame's: the edge's wall is the tallest
-- piece there, a smaller one is in it. A frame is told by the game's own asset id (DA_T1_Wall_Large_Doorframe,
-- ..._Narrow_Doorframe, ..._Windowframe; dump 26161880 / buildables).
local function opening_words(piece)
    piece = tostring(piece or "")
    if piece:find("Doorframe", 1, true) then return "an open doorway, no door in it" end
    if piece:find("Windowframe", 1, true) then return "a window opening" end
end
function M.edges(rows)
    local out = {}
    local function hd(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
    for _, f in ipairs(rows) do
        local fb = f.box
        if fb and f.position and not M.thin_axis(fb) and fb.extent[3] >= 0.75 then
            local p = f.position
            local top = p[3] + fb.origin[3] + fb.extent[3]
            local e = { edges = {}, inside = {} }
            for _, side in ipairs({ "N", "E", "S", "W" }) do
                local axis, i = side_axis(f, side)
                local h = fb.extent[i]
                local edge = { p[1] + axis[1] * h, p[2] + axis[2] * h }
                local next_to = { p[1] + axis[1] * 2 * h, p[2] + axis[2] * 2 * h }
                local wall, inner, beside
                for _, g in ipairs(rows) do
                    if g ~= f and g.position and g.box then
                        local q = g.position
                        local gbot = q[3] + g.box.origin[3] - g.box.extent[3]
                        if M.thin_axis(g.box) and hd(q, edge) <= 0.5 and math.abs(gbot - top) <= 0.6 then
                            if not wall or g.box.extent[3] > wall.box.extent[3] then wall, inner = g, wall or inner
                            else inner = g end
                        elseif not M.thin_axis(g.box) and hd(q, next_to) <= 0.5 and math.abs(q[3] - p[3]) <= 0.6 then
                            beside = "beside: " .. tostring(g.name) .. " " .. g.id
                        end
                    end
                end
                e.edges[side] = wall and (tostring(wall.name) .. " " .. wall.id) or beside or "open"
                e.inside[side] = wall and (inner and (tostring(inner.name) .. " " .. inner.id) or opening_words(wall.piece)) or nil
            end
            for _, g in ipairs(rows) do -- a ceiling/floor piece over the cell, about a wall's height above its top
                if g ~= f and g.position and g.box and not M.thin_axis(g.box) and hd(g.position, p) <= 0.6 then
                    local up = g.position[3] + g.box.origin[3] + g.box.extent[3] - top
                    if up >= 2.0 and up <= 4.5 then e.ceiling = tostring(g.name) .. " " .. g.id end
                end
            end
            out[f.id] = e
        end
    end
    return out
end
-- A cell-sized flat or sloped piece (a ceiling tile, a roof) on a floor's ':top': a roof covers a room from its walls'
-- tops (Luis's house: every roof on a wall top; community guides: the wall-top rim is what roof pieces snap against).
-- Live 2026-11-01: aimed at a foundation's top a roof never landed (twice), or landed ON the floor inside the walls
-- (a 30 deg Hip Roof, 20:29Z: "roof only covers part"). Names the walls on that floor's edges as the on that reaches
-- over it (a wall on the N edge: its S side). placed: it was built there. -> text | nil (not that case)
local OPP = { N = "S", S = "N", E = "W", W = "E" }
-- profile: the new piece's placement profile row (game data: RoofProfile, BaseProfile = floors and walls,
-- FloorProp* = tables, crates, fires); without it, cell-sized pieces only.
function M.roof_hint(anchor_box, new_box, edges, placed, profile)
    if not (anchor_box and new_box) or M.thin_axis(anchor_box) or M.thin_axis(new_box) then return nil end
    if profile then
        if profile ~= "RoofProfile" and profile ~= "BaseProfile" then return nil end
    elseif math.max(new_box.extent[1], new_box.extent[2]) < 1.2 then return nil end
    local ons = {}
    for _, s in ipairs({ "N", "E", "S", "W" }) do
        local v = edges and edges[s]
        if type(v) == "string" and v ~= "open" and not v:find("^beside:") then ons[#ons + 1] = "'" .. v:match("(%S+)$") .. ":" .. OPP[s] .. "'" end
    end
    local lead = placed and (#ons > 0 and " That puts it on the floor inside the walls, so it doesn't cover the room." or " That puts it on the floor.") or ""
    if #ons == 0 then return lead .. " A roof or ceiling tile covers a room from the tops of its walls, and this floor has no wall on any edge yet." end
    return lead .. " A roof or ceiling tile covers a room from the tops of its walls: on " .. table.concat(ons, " or ")
        .. " puts one over this floor from the wall on that edge."
end
-- Does a piece at pos stand on this floor piece (its box at floor.position, turned floor.yaw)? -> metres from the
-- floor's centre | nil. Its bottom (pos z: a placed piece's location is its foot) within 0.6 m of the floor's top.
function M.on_floor(pos, floor, box)
    if not (pos and floor and floor.position and box) then return nil end
    local p = floor.position
    local c = math.rad(floor.yaw or 0)
    local dx, dy = pos[1] - p[1], pos[2] - p[2]
    local lx, ly = dx * math.cos(c) + dy * math.sin(c), -dx * math.sin(c) + dy * math.cos(c)
    if math.abs(lx - box.origin[1]) > box.extent[1] or math.abs(ly - box.origin[2]) > box.extent[2] then return nil end
    if math.abs((pos[3] or 0) - (p[3] + box.origin[3] + box.extent[3])) > 0.6 then return nil end
    return math.sqrt(dx * dx + dy * dy)
end
-- The floor (a foundation or a floor tile, by the game's placement profile) a just-placed piece stands on, and whose:
-- the fact a station/furniture reply carries (live 20:5xZ: a Crafting Table "near me" stood in the middle of his
-- 1.5 m foundation and he found out only when its wall went red). -> {id, name, from_centre_m, mine, words} | nil
function W.floor_under(api, pos, self_id)
    local list = pos and W.built_pieces(api, pos, 8)
    if not list then return nil end
    local best, bd, bbox
    for _, e in ipairs(list) do
        if e.id ~= self_id and e.data then
            local prof = W.piece_profile(api, e.data) or {}
            local box = prof.box
            if box and (prof.profile == "FoundationProfile" or (prof.profile == "BaseProfile" and not M.thin_axis(box))) then
                local d = M.on_floor(pos, e, box)
                if d and (not bd or d < bd) then best, bd, bbox = e, d, box end
            end
        end
    end
    if not best then return nil end
    local mine
    local dm = api.module("deconstruct")
    if dm and type(dm.mark_mine) == "function" then
        local row = { piece = best.piece, position = best.position }
        if pcall(dm.mark_mine, api, { row }) then mine = row.mine == true end
    end
    local words = string.format("It stands on %s%s (%s)%s, %.1f m from its centre (the floor is %.1f x %.1f m).",
        mine and "your " or "the ", tostring(best.name), best.id, mine == false and ", not placed by you" or "",
        bd, bbox.extent[1] * 2, bbox.extent[2] * 2)
    return { id = best.id, name = best.name, from_centre_m = r1(bd), mine = mine, words = words }
end
-- Shelter-only pieces (the piece data's ShelterRequirementText, "Requires Shelter": the Spinning Wheel). The game
-- lets one be PLACED under open sky and then refuses to let it be used (live tools leg run 5, 03:5xZ: a wheel 15 m from
-- his roofed house, then 4 min and 46 logs walling round it). A roof over a spot = a trace 2.2-10 m above its floor
-- hits (crafting.lua W.shelter's covered test, the one stations report), with 0.3-2 m above the floor clear.
function W.ground_at(api, x, y, z) -- the floor under (x, y) from z + 1.5 m (under a roof's slope) down to z - 4 m -> z | nil
    local hit, o = W.trace(api, { X = x * 100, Y = y * 100, Z = (z + 1.5) * 100 }, { X = x * 100, Y = y * 100, Z = (z - 4) * 100 })
    local zi = hit and o and o.ImpactPoint and tonumber(o.ImpactPoint.Z)
    return zi and zi / 100 or nil
end
-- How the ground lies round a standing floor piece: 8 traces just outside its box (corners and edge middles; under
-- it a trace hits the piece itself) -> {lo_m, hi_m (ground below its top, nearest and furthest), fall_m, low_side,
-- words} | nil. Live 2026-11-15 (rung 2): a foundation "near me" went up on a 3 m slope 60 m from the spot asked for,
-- its walls never seated, and its reply said nothing of the ground falling away under it.
function W.ground_round(api, s)
    if s and s.id and not s.box then -- a census row carries no size: the piece's own
        local okb, info = pcall(W.actor_info, api, s.id)
        if okb and info and info.box then s = info end
    end
    if not (s and s.position and s.box and s.box.extent) then return nil end
    local yaw = math.rad(tonumber(s.yaw) or 0)
    local fx, fy = { math.cos(yaw), math.sin(yaw) }, { -math.sin(yaw), math.cos(yaw) }
    local o, e = s.box.origin or { 0, 0, 0 }, s.box.extent
    local cx = s.position[1] + fx[1] * o[1] + fy[1] * o[2]
    local cy = s.position[2] + fx[2] * o[1] + fy[2] * o[2]
    local top = s.position[3] + o[3] + e[3]
    local lo, hi, n, low_at = math.huge, -math.huge, 0, nil
    for _, k in ipairs({ { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }) do
        local a, b = k[1] * (e[1] + 0.4), k[2] * (e[2] + 0.4)
        local x, y = cx + fx[1] * a + fy[1] * b, cy + fx[2] * a + fy[2] * b
        local hit, out = W.trace(api, { X = x * 100, Y = y * 100, Z = (top + 1.0) * 100 }, { X = x * 100, Y = y * 100, Z = (top - 12) * 100 })
        local zi = hit and out and out.ImpactPoint and tonumber(out.ImpactPoint.Z)
        if zi then
            local d = top - zi / 100
            n = n + 1
            if d < lo then lo = d end
            if d > hi then hi, low_at = d, { x - cx, y - cy } end
        end
    end
    if n < 5 then return nil end
    local fall = hi - lo
    local words
    if fall < 0.6 then
        words = string.format("The ground round it is level (%.1f to %.1f m below its top).", lo, hi)
    else
        words = string.format("The ground round it is not level: it lies %.1f m below its top on one side and %.1f m below on its %s side, a fall of %.1f m across the piece.",
            lo, hi, compass(low_at[1], low_at[2]) or "far", fall)
    end
    return { lo_m = r1(lo), hi_m = r1(hi), fall_m = r1(fall), low_side = compass(low_at[1], low_at[2]), words = words }
end
function W.covered_at(api, p)
    local function up(a, b) return (W.trace(api, { X = p[1] * 100, Y = p[2] * 100, Z = (p[3] + a) * 100 }, { X = p[1] * 100, Y = p[2] * 100, Z = (p[3] + b) * 100 })) end
    return up(2.2, 10) == true and up(0.3, 2.0) ~= true
end
-- Where a shelter-only piece can go near `center`: covered spots, on my own floors first (my house), then any covered
-- spot round the centre asked for; and a covered place to stand at standoff_m from it (inside, so the camera sees it).
-- env = {ground_at(x, y, z), covered(p), mine_floors = {{x, y, z}}, reach_m, standoff_m, here}
-- -> {center, stand_at, on_mine} | nil
function M.shelter_plan(env, center)
    local function probe(x, y, z0)
        local z = env.ground_at(x, y, z0)
        if not z then return nil end
        local p = { x, y, z }
        return env.covered(p) and p or nil
    end
    local function on_mine(p)
        for _, f in ipairs(env.mine_floors or {}) do
            if math.sqrt((f[1] - p[1]) ^ 2 + (f[2] - p[2]) ^ 2) <= 1.6 and math.abs(f[3] - p[3]) <= 1.5 then return true end
        end
        return false
    end
    local ring, floors = {}, {}
    local function add(list, p) if p then list[#list + 1] = p end end
    add(ring, probe(center[1], center[2], center[3]))
    for _, r in ipairs({ 1.5, 3.0 }) do
        for i = 0, 7 do
            local a = math.rad(i * 45)
            add(ring, probe(center[1] + r * math.cos(a), center[2] + r * math.sin(a), center[3]))
        end
    end
    for _, f in ipairs(env.mine_floors or {}) do
        if math.sqrt((f[1] - center[1]) ^ 2 + (f[2] - center[2]) ^ 2) <= (env.reach_m or 25) then add(floors, probe(f[1], f[2], f[3] + 1.0)) end
    end
    local function dist(p) return math.sqrt((p[1] - center[1]) ^ 2 + (p[2] - center[2]) ^ 2) end
    local pick
    for _, p in ipairs(ring) do if on_mine(p) and (not pick or dist(p) < dist(pick)) then pick = p end end
    if not pick then for _, p in ipairs(floors) do if not pick or dist(p) < dist(pick) then pick = p end end end
    local mine = pick ~= nil
    if not pick then for _, p in ipairs(ring) do if not pick or dist(p) < dist(pick) then pick = p end end end
    if not pick then return nil end
    -- stand under the same roof, standoff_m off, nearest me
    local here, so, stand, sd = env.here or pick, (env.standoff_m or 1.5) + 0.5, nil, nil
    for i = 0, 7 do
        local a = math.rad(i * 45)
        local q = probe(pick[1] + so * math.cos(a), pick[2] + so * math.sin(a), pick[3])
        local dq = q and math.sqrt((q[1] - here[1]) ^ 2 + (q[2] - here[2]) ^ 2)
        if q and (not sd or dq < sd) then stand, sd = q, dq end
    end
    return { center = pick, stand_at = stand, on_mine = mine }
end
-- Built pieces standing where a new piece would go (its box at spot, turned yaw, plus margin_m): the truthful
-- "what is in the way" for a red preview (live 20:5xZ: a Crafting Table in the middle of a medium foundation kept its
-- S wall red; the model guessed it). rows: census {id, name, position}; skip: ids to leave out. -> up to 2 rows
function M.standing_in(rows, spot, box, yaw, skip, margin_m)
    if not (spot and box) then return {} end
    local m = margin_m or 0.6
    local c = math.rad(yaw or 0)
    local out = {}
    for _, st in ipairs(rows or {}) do
        local q = st.position
        if q and not (skip and skip[st.id]) and not st.ghosted then
            local dx, dy = q[1] - spot[1], q[2] - spot[2]
            local lx, ly = dx * math.cos(c) + dy * math.sin(c), -dx * math.sin(c) + dy * math.cos(c)
            local zlo, zhi = spot[3] + box.origin[3] - box.extent[3], spot[3] + box.origin[3] + box.extent[3]
            if math.abs(lx - box.origin[1]) <= box.extent[1] + m and math.abs(ly - box.origin[2]) <= box.extent[2] + m
                and q[3] >= zlo - 0.5 and q[3] <= zhi + 0.5 then
                out[#out + 1] = st
                if #out >= 2 then break end
            end
        end
    end
    return out
end
-- Place an attach from where I stand? -> true | false, why. Within stay_m of the aim point, on the anchor's floor (a wall:
-- its top face must be in view), not in the new piece's way, and the camera's ray reaching the aim point.
function W.stay_ok(api, job, here)
    local cfg = M.cfg.build
    local on = job.on
    if not (here and on and on.anchor and on.anchor.box) then return false, "no_anchor" end
    -- no mount = a piece on a top (a station on a foundation): the same view rule. Rung 2 run 20261116-010103: it
    -- had none, so he aimed from wherever he stood, the view landed on a wall of the room (the preview 1.7-2.1 m
    -- off, "Blocked") and the crafting table, crate and campfire each failed twice
    local mount = on.mount or {}
    local spot, axis = M.flush_spot(on.anchor, on.side, on.box)
    local aim = M.aim_point(on, spot, axis)
    if not (spot and aim) then return false, "no_aim" end
    if math.sqrt((aim[1] - here[1]) ^ 2 + (aim[2] - here[2]) ^ 2) > cfg.stay_m then return false, "far" end
    local a = on.anchor
    local top = a.position[3] + a.box.origin[3] + a.box.extent[3]
    local on_floor = mount.ceiling or on.side == "in" or math.abs((here[3] - 0.88) - top) <= 0.6
    if M.in_the_way(here, spot, on.box, mount.yaw or 0) then return false, "in_the_way" end
    local tol = cfg.stay_clear_m + ((mount.ceiling and M.thin_axis(a.box)) and a.box.extent[M.thin_axis(a.box)] or 0)
    -- from where the camera WILL stand once I aim there (it swings round its pivot, camrig.lua), not where it is now.
    -- Off the anchor's floor (on the ground beside a foundation) the view must land ON the aim point: just under
    -- the edge is its side face, and the piece doesn't snap from there
    local look = W.look(api, aim, W.view_tol(on, here))
    if look then
        job.stay_off_m = look.off_m
        if not look.clear then return false, "view_blocked" end
        return true
    end
    if not on_floor then return false, "not_on_its_floor" end
    local cam = W.camera(api)
    if not cam then return false, "no_camera" end
    local hit, o = W.trace(api, { X = cam[1] * 100, Y = cam[2] * 100, Z = cam[3] * 100 }, { X = aim[1] * 100, Y = aim[2] * 100, Z = aim[3] * 100 })
    local ip = hit and o and o.ImpactPoint
    if ip and type(ip.X) == "number" then
        local d = math.sqrt((ip.X / 100 - aim[1]) ^ 2 + (ip.Y / 100 - aim[2]) ^ 2 + (ip.Z / 100 - aim[3]) ^ 2)
        if d > tol then return false, "view_blocked" end
    end
    return true
end
-- One line trace from my pawn (KismetSystemLibrary:LineTraceSingle, the call move.lua / spells use).
function W.trace(api, a, b)
    local U = sense_U(api)
    local m = mem()
    if not (m.ksl and U.valid(m.ksl)) then m.ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary") end
    local s = api.module("sense")
    local pawn = s and s.local_pawn and s.local_pawn()
    if not (m.ksl and pawn) or paused() then return false, {} end
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local out = {}
    local ok, hit = pcall(function() return m.ksl:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0) end)
    return ok and hit == true, out
end
function W.clock(api)
    local U = sense_U(api)
    local m = mem()
    if not (m.gst and U.valid(m.gst)) then m.gst = U.find_object("/Script/Engine.Default__GameplayStatics") end
    local s = api.module("sense")
    local pawn = s and s.local_pawn and s.local_pawn()
    local v = m.gst and pawn and U.try(function() return m.gst:GetTimeSeconds(pawn) end)
    return type(v) == "number" and v or api.now()
end
function W.texts(api) -- the game's own words per state (TMap, read once per session)
    local m = mem()
    if m.texts then return m.texts end
    local U = sense_U(api)
    local pc = W.pc(api)
    local bi = pc and U.try(function() return pc.BuildInteractionComponent end)
    if paused() or not U.valid(bi) then return M.STATE_TEXT end
    local t = {}
    pcall(function()
        bi.ValidityNotificationTextMap:ForEach(function(k, v)
            local kk = U.try(function() return k:get() end); if kk == nil then kk = k end
            local vv = U.try(function() return v:get() end); if vv == nil then vv = v end
            local s = U.str(vv)
            if tonumber(kk) and s then t[tonumber(kk)] = s end
        end)
    end)
    m.texts = next(t) and t or M.STATE_TEXT
    return m.texts
end
-- Hooks (hookhub: one native post-hook per path, never unregistered, skipped under DW_PAUSE). Records with
-- a sequence number so "newer than the latest aim" is decidable.
function W.arm_hooks(api)
    local m = mem()
    m.hk = m.hk or { seq = 0 }
    if m.hk.armed then return true end
    local ok, hub = pcall(function()
        local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or (ROOT .. "/client_mod/scripts")
        return assert(loadfile(dir .. "/hookhub.lua"))()
    end)
    if not ok or type(hub) ~= "table" then return false end
    local function g(p) local okg, v = pcall(function() return p:get() end); if okg then return v end return p end
    local function rec(kind, val)
        local s = rawget(_G, "DWBuild")
        if not (s and s.hk) then return end
        s.hk.seq = s.hk.seq + 1
        s.hk[kind] = { seq = s.hk.seq, v = val }
    end
    hub.on(M.HOOK_PATHS.validity, "build:validity", function(_, state) rec("validity", tonumber(g(state))) end, { log = api.log })
    hub.on(M.HOOK_PATHS.refused, "build:refused", function(_, state) rec("refused", tonumber(g(state))) end, { log = api.log })
    hub.on(M.HOOK_PATHS.complete, "build:complete", function(_, ghosted, index) rec("complete", tonumber(g(index))) end, { log = api.log })
    m.hk.armed = true
    return true
end
function W.hook(kind) local m = mem(); return m.hk and m.hk[kind] or nil end
function W.hook_seq() local m = mem(); return m.hk and m.hk.seq or 0 end

-- ---------- piece resolution (review finding 15)
local function lev(a, b)
    if #a > 40 or #b > 40 then return 99 end
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a:sub(i, i) == b:sub(j, j) and 0 or 1))
        end
        prev = cur
    end
    return prev[#b]
end
M._lev = lev
-- Do two names share a run of 4+ letters ("firepit" / "campfire": "fire")? Rung 2 run 1 (05:0xZ): "Firepit" read
-- unknown and nothing named the Campfire, so the item was never built.
function M.share_run(a, b, n)
    a, b = lower(a):gsub("[^%a]", ""), lower(b):gsub("[^%a]", "")
    n = n or 4
    for i = 1, #a - n + 1 do if b:find(a:sub(i, i + n - 1), 1, true) then return true end end
    return false
end
-- have(p) (optional): do I hold what p costs? Several pieces share a name across tiers (live 2026-11-16: "Square
-- Foundation" is DA_T1 and DA_T2, "Wall" / "WALL"; each cost him a turn): the one spelled exactly as asked, else the
-- only one he can pay for, is the one meant; the reply names what was built.
function M.resolve(api, list, q, have)
    local raw = q
    q = lower(q)
    local exact, typo, close, within = {}, {}, {}, {}
    local qw = toks(q)
    for _, d in ipairs(list) do
        local p = M.describe(api, d)
        local n, id = lower(p.name), lower(p.id)
        if n == q or id == q then exact[#exact + 1] = { d = d, p = p }
        else
            local dist = math.min(lev(n, q), lev(id, q))
            if dist <= math.max(1, math.floor(#q / 6)) then typo[#typo + 1] = { d = d, p = p } end
            if n:find(q, 1, true) or q:find(n, 1, true) or M.share_run(n, q) then close[#close + 1] = p.name end
            -- every word of the ask is a word of its name ("Door Frame Wall" -> WALL WITH DOOR FRAME)
            local _, ns = toks(n)
            local all = #qw > 0
            for _, w in ipairs(qw) do
                if not (ns[w] or (#w > 3 and w:sub(-1) == "s" and ns[w:sub(1, -2)])) then all = false; break end
            end
            if all then within[#within + 1] = { d = d, p = p } end
        end
    end
    for _, narrow in ipairs({ function(x) return x.p.name == raw or x.p.id == raw end, have and function(x) return have(x.p) end or false }) do
        if #exact > 1 and narrow then
            local keep = {}
            for _, x in ipairs(exact) do if narrow(x) then keep[#keep + 1] = x end end
            if #keep >= 1 then exact = keep end
        end
    end
    if #exact == 1 then return exact[1].d, exact[1].p end
    if #exact > 1 then return nil, nil, "ambiguous_target", exact end
    if #typo == 1 then return typo[1].d, typo[1].p end
    if #typo > 1 then return nil, nil, "ambiguous_target", typo end
    -- the ask's words inside one name: that piece when it is the only one (or the only one I can pay for), else the
    -- question which (rung 2 run 20261116-010103: "Foundation" and "Door Frame Wall" read as unknown)
    if #within > 1 and have then
        local keep = {}
        for _, x in ipairs(within) do if have(x.p) then keep[#keep + 1] = x end end
        if #keep == 1 then within = keep end
    end
    if #within == 1 then return within[1].d, within[1].p end
    if #within > 1 and #within <= 8 then return nil, nil, "ambiguous_target", within end
    return nil, nil, "unknown_target", close
end

-- ---------- the job
local function arbiter(api) local A = api.module("arbiter"); return A and type(A.request) == "function" and A or nil end

local function start_build(api, args, ctx)
    local cfg = M.cfg.build
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    if not need_str(args.piece) then return api.fail("invalid_args", { detail = "piece is required (a name from buildables)" }) end
    local sense = api.module("sense")
    local function priv(p)
        if not (sense and type(sense.has_privilege) == "function") then return nil end
        local ok, v = pcall(sense.has_privilege, p)
        if ok then return v end -- true | false | nil ("a and false or nil" would lose the false)
        return nil
    end
    if priv("build") == false then
        return api.fail("no_permission", { why = "build", detail = "The server hasn't given me building rights, so I can't place anything here." })
    end
    local list, why = W.unlocked(api)
    if not list then return api.fail("state_unavailable", { why = why, detail = "I can't read what I can build right now." }) end
    local counts, stored
    local data, piece, code, more = M.resolve(api, list, args.piece, function(p)
        counts, stored = counts or api.counts() or {}, stored or W.storage_counts(api, 15)
        local ok, miss = pcall(M.missing, p, counts, stored)
        return ok and type(miss) == "table" and #miss == 0
    end)
    if not data then
        if code == "ambiguous_target" then
            local names = {}
            -- the same name twice (rung 2 run 1: "Which one: Door, Door?"): the game's ids tell them apart (always
            -- given: "Which one: Wall, WALL?" left him to look the ids up)
            local dup = true
            for _, x in ipairs(more) do names[#names + 1] = dup and (x.p.name .. " (" .. tostring(x.p.id) .. (x.p.category and (", " .. x.p.category) or "") .. ")") or x.p.name end
            return api.fail("ambiguous_target", { piece = args.piece, candidates = names, ids = (function()
                    local ids = {}; for _, x in ipairs(more) do ids[#ids + 1] = x.p.id end; return ids end)(),
                detail = "Which one: " .. table.concat(names, ", ") .. "?" .. (dup and " Pass its id as the piece." or "") })
        end
        local close = {}
        for i = 1, math.min(5, #(more or {})) do close[#close + 1] = more[i] end
        return api.fail("unknown_target", { piece = args.piece, close = more,
            detail = "I can't build a " .. args.piece .. " (it isn't one of the pieces I've unlocked)."
                .. (#close > 0 and (" Unlocked pieces with a name like it: " .. table.concat(close, ", ") .. ".") or "") })
    end
    if piece.host_only and priv("owner") ~= true then
        return api.fail("host_only", { piece = piece.id, detail = "Only the host can build the " .. piece.name .. "." })
    end
    local counts, storage = {}, {}
    for k, v in pairs(api.counts() or {}) do counts[k] = v end -- a snapshot (the spend check compares against it)
    for k, v in pairs((W.storage_counts(api, 15))) do storage[k] = v end
    local missing = M.missing(piece, counts, storage)
    -- short, with none of what's short carried or in storage near me: say so now rather than walk, open the menu and
    -- preview it first (live 07:4xZ: a Campfire with no Stone took 11.5 s to get the game's "You require more materials")
    do
        local none, w = #missing > 0, {}
        for _, x in ipairs(missing) do
            if x.have + (x.in_storage or 0) >= x.need or (x.in_storage or 0) > 0 then none = false end
            w[#w + 1] = string.format("%d %s (I carry %d)", x.need, tostring(x.name), x.have)
        end
        if none then
            return api.fail("missing_materials", { piece = piece.id, missing = missing,
                detail = "The " .. piece.name .. " needs " .. table.concat(w, ", ") .. ", and I see none of it in storage within 15 m, so I didn't try to place it." })
        end
    end
    -- target
    local here = api.my_position()
    if not here then return api.fail("companion_down", { detail = "no position" }) end
    local center, exact = nil, false
    local function pos_of(v)
        if type(v) == "table" and type(v[1]) == "number" then return { v[1], v[2], v[3] or here[3] } end
        if need_str(v) then
            if v == "me" then return here end
            local t = api.find_thing(v)
            if t and t.position then return t.position end
            -- a built piece's id as the house line names it (rung 3, live 19:04Z: near "BuildingPiece_62" read unknown)
            local ai = W.actor_info(api, v)
            return ai and ai.position or nil
        end
    end
    if args.at ~= nil then
        center, exact = pos_of(args.at), true
        if not center then return api.fail("unknown_target", { at = args.at, detail = "I can't see where you want it." }) end
    elseif args.near ~= nil then
        center = pos_of(args.near)
        if not center then return api.fail("unknown_target", { near = args.near, detail = "I can't see what to build it next to." }) end
    end
    -- on = "<piece id>[:N|E|S|W|top]": flush against that built piece (no side: the free side nearest me)
    local on
    if args.on ~= nil then
        local aid, sw = tostring(args.on):match("^([^:]+):?(.*)$")
        local anchor = W.actor_info(api, aid)
        if not anchor or not anchor.position then
            return api.fail("unknown_target", { on = args.on, detail = "I can't see a built piece with the id " .. tostring(aid) .. "." })
        end
        local side = sw ~= "" and M.SIDES[lower(sw)] or nil
        if sw ~= "" and not side then
            return api.fail("invalid_args", { on = args.on, detail = "I don't know the side '" .. sw .. "': use N, E, S, W or top." })
        end
        -- sizes: from the pieces' data, loaded once a piece was selected in the build menu; unknown now = a provisional
        -- box (for where to stand), re-read in the rotate phase when the new piece is selected (else state_unavailable)
        local box0 = (W.piece_profile(api, data) or {}).box -- the new piece's size, if its data is loaded
        if not anchor.box and anchor.piece == piece.id then anchor.box = box0 end
        local provisional = not (anchor.box and box0)
        anchor.box = anchor.box or box0 or { origin = { 0, 0, 0 }, extent = { cfg.footprint_m / 2, cfg.footprint_m / 2, 0.5 } }
        box0 = box0 or anchor.box
        -- a roof or ceiling tile on a wall's ':top' reaches out over the room: the side of the wall its floor is on
        -- (live 05:57Z: a 30 deg Hip Roof aimed at the wall's own top line sat red 1.7 m off and nothing was placed)
        local top_as
        if side == "top" and not provisional and M.thin_axis(anchor.box) and not M.thin_axis(box0)
            and math.max(box0.extent[1], box0.extent[2]) >= 1.2 then
            local bd
            for _, st in ipairs(W.structures(api, true) or {}) do
                local pid = tostring(st.piece or "")
                if st.id ~= anchor.id and st.position and (pid:find("Foundation", 1, true) or pid:find("_Floor_", 1, true))
                    and math.abs(st.position[3] - anchor.position[3]) <= 1.0 then
                    for _, s in ipairs({ "N", "E", "S", "W" }) do
                        local p = M.flush_spot(anchor, s, box0)
                        local d = p and math.sqrt((p[1] - st.position[1]) ^ 2 + (p[2] - st.position[2]) ^ 2)
                        if d and d <= 4.0 and (not bd or d < bd) then top_as, bd = s, d end
                    end
                end
            end
            if top_as then side = top_as end
        end
        local function taken(s)
            local p = M.flush_spot(anchor, s, box0)
            for _, st in ipairs(W.structures(api, true) or {}) do
                if st.id ~= anchor.id and st.position and math.sqrt((st.position[1] - p[1]) ^ 2 + (st.position[2] - p[2]) ^ 2) <= cfg.taken_m
                    and math.abs(st.position[3] - p[3]) <= 1.0 then return st end
            end
        end
        if side then
            local t = taken(side)
            if t and side == "top" and not provisional then
                anchor.top_off = M.top_free(anchor, box0, W.structures(api, true), here)
                if anchor.top_off then t = nil end
            end
            if t then
                return api.fail("blocked", { on = args.on, why = "side_taken", taken_by = t.id,
                    detail = side == "top" and ("The top of the " .. anchor.name .. " already has a " .. tostring(t.name) .. " (" .. t.id
                            .. ") on its middle and I see no free quarter of it for the " .. piece.name .. ".")
                        or ("The " .. side .. " side of the " .. anchor.name .. " already has a " .. tostring(t.name) .. " (" .. t.id .. ").") })
            end
        else
            local best, bd
            for _, s in ipairs({ "N", "E", "S", "W" }) do
                local p = M.flush_spot(anchor, s, box0)
                local d = math.sqrt((p[1] - here[1]) ^ 2 + (p[2] - here[2]) ^ 2)
                if not taken(s) and (not bd or d < bd) then best, bd = s, d end
            end
            if not best then
                return api.fail("blocked", { on = args.on, why = "no_free_side", detail = "Every side of the " .. anchor.name .. " already has a piece next to it." })
            end
            side = best
        end
        on = { anchor = anchor, side = side, box = box0, provisional = provisional, top_as = top_as }
        -- a wall on an edge must run along it. Live 15:26Z: the ghost takes my view's yaw, squared to the anchor's
        -- 90 degree grid (aimed east from the W side -> yaw 0, across the edge), so turn it by the difference (mod
        -- 180), in the game's 15 degree steps. I look at the spot from outside, against the side's direction.
        local _, _, mount = M.flush_spot(anchor, side, box0)
        on.mount = mount
        on.turn_auto = args.rotation == nil -- the turn itself is worked out at the stand point (rotate phase)
        center, exact = M.flush_spot(anchor, side, box0), true
    end
    local prof0 = W.piece_profile(api, data)
    local footprint = (prof0 and prof0.box and math.max(prof0.box.extent[1], prof0.box.extent[2]) * 2) or cfg.footprint_m
    local standoff = math.max(cfg.standoff_m, footprint / 2 + 1.0)
    if standoff > cfg.reach_m - 0.5 then
        return api.fail("too_far", { piece = piece.id, detail = "The " .. piece.name .. " is too big to place from where I can stand." })
    end
    if not center then -- in front of me, beyond the standoff
        local yaw = 0
        local U = sense_U(api)
        local pc = W.pc(api)
        local r = pc and U.try(function() return pc:GetControlRotation() end)
        if r and type(r.Yaw) == "number" then yaw = math.rad(r.Yaw) end
        center = { here[1] + math.cos(yaw) * (standoff + 0.5), here[2] + math.sin(yaw) * (standoff + 0.5), here[3] }
    end
    -- a shelter-only piece goes under a roof (my house first), never under open sky
    local shelter
    if piece.needs_shelter and not on then
        local dm = api.module("deconstruct")
        local okl, L = pcall(function() return dm and dm.ledger(nil) end)
        L = okl and L or nil
        local floors = {}
        for _, e in ipairs(L and L.pieces or {}) do
            local id = tostring(e.piece or "")
            if type(e.at) == "table" and #e.at >= 3 and (id:find("Foundation", 1, true) or id:find("_Floor_", 1, true)) then floors[#floors + 1] = e.at end
        end
        local plan = M.shelter_plan({ ground_at = function(x, y, z) return W.ground_at(api, x, y, z) end,
                                      covered = function(p) return W.covered_at(api, p) end,
                                      mine_floors = floors, reach_m = cfg.shelter_reach_m, standoff_m = standoff, here = here }, center)
        if not plan then
            local house
            local okb, bases = pcall(function() return dm and dm.bases(L, here) end)
            for _, b in ipairs(okb and bases or {}) do if b.covered and not house then house = b end end
            local said = piece.shelter_text ~= "" and (" (the game says \"" .. piece.shelter_text .. "\")") or ""
            return api.fail("blocked", { piece = piece.id, why = "no_shelter", shelter_text = piece.shelter_text, my_house = house,
                detail = "The " .. piece.name .. " needs a roof over it" .. said .. ", and there is open sky over every spot "
                    .. "within 3 m of where it would go and no covered floor of mine within " .. math.floor(cfg.shelter_reach_m) .. " m"
                    .. (house and string.format("; my house %d m %s at (%.0f, %.0f) has a roof", house.distance_m or 0, house.direction or "",
                        house.centre[1], house.centre[2]) or "; I have no roofed building of my own to put it in")
                    .. ". Nothing was placed." })
        end
        exact = exact and plan.center[1] == center[1] and plan.center[2] == center[2]
        center, shelter = plan.center, plan
    end
    local short = false
    for _, x in ipairs(missing) do if (x.have + (x.in_storage or 0)) < x.need then short = true end end
    local job = { kind = "build", piece = piece, data = data, phase = "approach", missing = missing, center = center, exact = exact,
                  short_materials = short, on = on, footprint = footprint,
                  standoff = standoff, presses = {}, spent = {}, counts0 = counts, storage0 = storage, opens = 0, leaves = 0,
                  shelter = shelter, stand_at = shelter and shelter.stand_at or nil }
    job.xp0 = W.construction_xp(api)
    return job
end
M._start_build = start_build

local function stand_point(here, pos, d)
    local dx, dy = here[1] - pos[1], here[2] - pos[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then return { pos[1] + d, pos[2], pos[3] } end
    return { pos[1] + dx / l * d, pos[2] + dy / l * d, pos[3] }
end

local function pl() return assert(loadfile((debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or (ROOT .. "/client_mod/scripts")) .. "/placement.lua"))() end

-- The preview as placement.lua reads it: hook state (exact) AND MPC colour (2) AND a position; fresh = the
-- hook record is newer than the latest aim.
local function preview_reader(api, job)
    return function()
        local m = W.mpc(api)
        local h = W.hook("validity")
        if not m or not m.position then return nil end
        if job.on and job.on.target then
            -- attaching: the positive snap signal. Green (and Valid, if the hook ever fires) AND the ghost itself (the
            -- preview actor; the cursor stays where I aimed, snap_aim_m outside) sitting on the flush spot = the game
            -- snapped it onto the anchor's plug. A free green ghost beside the anchor is never pressed.
            local U = sense_U(api)
            local pa = W.preview_actor(api, job)
            local l = pa and U.loc(pa)
            local at = l and { l.X / 100, l.Y / 100, l.Z / 100 } or m.position
            local tg = job.on.target
            local off = math.sqrt((at[1] - tg[1]) ^ 2 + (at[2] - tg[2]) ^ 2)
            -- level: the census location is PlacementZOffset above where its preview stood (live: foundation +0.5 m),
            -- so a ghost that low counts as level too
            local dzs = tg[3] - at[3]
            local dz = math.min(math.abs(dzs), math.abs(dzs - (job.on.z_offset or 0)))
            job.on.last = { at = at, off_m = off, dz_m = dz, cursor = m.position, colour = m.index,
                            yaw = pa and tonumber((U.try(function() return pa:K2_GetActorRotation().Yaw end))) or nil }
            job.on.best_off = math.min(job.on.best_off or off, off)
            local function r2(p) return p and { math.floor(p[1] * 100 + 0.5) / 100, math.floor(p[2] * 100 + 0.5) / 100, math.floor((p[3] or 0) * 100 + 0.5) / 100 } end
            job.on.reads = job.on.reads or {}
            if #job.on.reads >= 12 then table.remove(job.on.reads, 1) end
            local bm = W.bm(api)
            local hw = bm and U.try(function() return bm.BuildingHelperActor end)
            local ha = hw and U.try(function() return hw:Get() end)
            local hyaw = U.valid(ha) and tonumber((U.try(function() return ha:K2_GetActorRotation().Yaw end))) or nil
            job.on.reads[#job.on.reads + 1] = { aim = r2(job.last_aim), cursor = r2(m.position), ghost = r2(at), colour = m.index,
                                                off_m = math.floor(off * 100 + 0.5) / 100, ghost_yaw = job.on.last.yaw and r1(job.on.last.yaw) or nil,
                                                helper_yaw = hyaw and r1(hyaw) or nil }
            local green = m.index == 2 and (not h or h.v == 0)
            local fresh = not h or h.seq > (job.aim_seq or 0)
            local cfg = M.cfg.build
            if job.on.mode == "cursor" then
                -- no preview actor to read (live 2026-11-01: an instance-only piece like the foundation has none; only
                -- BP_BuildingHelper_C sits at the cursor, and the cursor glides ~1 m/s after each aim). Then: aimed AT
                -- the flush spot, green, the cursor settled there -> press; the game's snap (Basic mode) pulls it onto
                -- the grid (live: the first foundation landed exactly on Luis's grid this way) and the census after the
                -- press says whether it really sits flush. snapped = "unseen".
                -- the camera swung after the aim (its spring arm turns round me and hits walls: live 16:33Z, a tile's
                -- cursor wandered 1-7 m while the camera settled): aim again from where it is now, then wait
                local cam = W.camera(api)
                local ac = job.aim_cam
                if not job.aim_exact and cam and ac and job.aim_raw and job.env and math.sqrt((cam[1] - ac[1]) ^ 2 + (cam[2] - ac[2]) ^ 2 + (cam[3] - ac[3]) ^ 2) > cfg.reaim_cam_m
                    and (job.on.reaims or 0) < cfg.reaims_max then
                    job.on.reaims = (job.on.reaims or 0) + 1
                    job.env.aim(job.aim_raw)
                    job.on.prev_cursor = nil
                    return { valid = false, why = "settling", position = at, fresh = fresh }
                end
                local prev = job.on.prev_cursor
                local moved = prev and math.sqrt((m.position[1] - prev[1]) ^ 2 + (m.position[2] - prev[2]) ^ 2) or math.huge
                -- an exact aim: the cursor answers within 2 frames and then stands (live trace 2026-11-16, 40 aims),
                -- so one read aim_settle_s after the aim is the settled cursor
                if job.aim_exact and job.aim_t and api.now() - job.aim_t >= cfg.aim_settle_s then moved = 0 end
                job.on.prev_cursor = m.position
                -- where the cursor must sit: the flush spot for a tile; for a wall the point just inside the edge on the
                -- anchor's top (its z too: a cursor on the side face below would snap it to the bottom edge)
                local ct = job.on.cursor_target or tg
                -- still moving, but this read and the last both on the target: settled enough (live 18:34Z: a wall's cursor
                -- trembled 4-10 cm a read 0.01 m from the flush spot until the checks ran out, "kept sliding")
                local function on_target(p)
                    local ztol = job.on.cursor_target and (job.on.cursor_tol_z_m or cfg.cursor_tol_z_m) or 1.0
                    return p and math.sqrt((p[1] - ct[1]) ^ 2 + (p[2] - ct[2]) ^ 2) <= (job.on.cursor_tol_m or cfg.cursor_tol_m)
                        and math.abs(p[3] - ct[3]) <= ztol
                end
                if moved > cfg.settle_m and not (moved <= cfg.tremble_m and on_target(prev) and on_target(m.position)) then
                    return { valid = false, why = "settling", position = at, fresh = fresh }
                end
                -- aimed away from the flush spot (a wall's top face, a wall's face for a ceiling) but the cursor sits ON
                -- the flush spot: the game's snap moved it there (the helper follows the snapped spot) -> a seen snap
                if green and job.on.cursor_target and math.sqrt((ct[1] - tg[1]) ^ 2 + (ct[2] - tg[2]) ^ 2) >= cfg.snap_jump_m
                    and off <= cfg.snap_jump_tol_m and dz <= cfg.snap_jump_tol_m then
                    return { valid = true, snapped = true, position = at, fresh = fresh, colour = 2 }
                end
                local coff = math.sqrt((at[1] - ct[1]) ^ 2 + (at[2] - ct[2]) ^ 2)
                local zok
                if job.on.cursor_target then zok = math.abs(at[3] - ct[3]) <= (job.on.cursor_tol_z_m or cfg.cursor_tol_z_m) else zok = math.abs(dzs) <= 1.0 end
                if green and coff <= (job.on.cursor_tol_m or cfg.cursor_tol_m) and zok then
                    return { valid = true, snapped = "unseen", position = at, fresh = fresh, colour = 2 }
                end
                -- settled off the spot (live: 0.6 m short and 0.2 m aside, the camera ray isn't the placement trace):
                -- correct the aim by the miss, as a player nudges the mouse; the checker's next re-aim applies it
                local c = job.on.corr or { 0, 0, 0 }
                -- z too, toward a cursor target on a face (live 17:03Z: a ceiling aimed 0.2 m under a wall's top had its
                -- cursor settle on the wall's face 0.4-1.2 m lower, every read; a player lifts the mouse)
                local cz = (c[3] or 0) + (job.on.cursor_target and not zok and (ct[3] - at[3]) or 0)
                c = { c[1] + (ct[1] - at[1]), c[2] + (ct[2] - at[2]), math.max(-cfg.corr_max_z_m, math.min(cfg.corr_max_z_m, cz)) }
                local cl = math.sqrt(c[1] ^ 2 + c[2] ^ 2)
                if cl > cfg.corr_max_m then c = { c[1] / cl * cfg.corr_max_m, c[2] / cl * cfg.corr_max_m, c[3] } end
                job.on.corr, job.on.prev_cursor = c, nil
            elseif green and off <= cfg.snap_tol_m and dz <= cfg.snap_tol_z_m then
                return { valid = true, snapped = true, position = at, fresh = fresh, colour = 2 }
            elseif green and job.on.free and job.last_aim
                and math.sqrt((at[1] - job.last_aim[1]) ^ 2 + (at[2] - job.last_aim[2]) ^ 2) <= cfg.free_tol_m and dz <= cfg.free_tol_z_m then
                return { valid = true, snapped = "free", position = at, fresh = fresh, colour = 2 } -- green where I aimed
            end
            local why = (h and h.v ~= 0 and (M.STATES[h.v] or tostring(h.v))) or (job.short_materials and "MissingMaterials")
                or (m.index == 2 and (job.on.mode == "cursor" and "preview_off_target" or "not_snapped"))
                or (m.index == 1 and "preview_red") or "preview_none"
            return { valid = false, why = why, position = at, fresh = fresh }
        end
        if not h then
            if m.index == 2 then
                if M.cfg.build.hook_required then return { valid = nil, position = m.position } end -- no exact state: unreadable
                -- known limit: a snap piece's colour 2 may be NeedsSnapping, and no positive snap signal is known
                -- yet, so never press for one (main, 2026-10-26)
                if job.snap then return { valid = false, why = "preview_ambiguous", position = m.position, fresh = true } end
                return { valid = true, position = m.position, fresh = true, colour = 2 }
            end
            -- not green: name the likeliest game reason we can know without the exact state
            local why = (job.short_materials and "MissingMaterials") or (m.index == 1 and "preview_red") or "preview_none"
            return { valid = false, why = why, position = m.position, fresh = true }
        end
        local fresh = h.seq > (job.aim_seq or 0)
        local valid = h.v == 0 and m.index == 2
        return { valid = valid, why = (not valid) and (M.STATES[h.v] or tostring(h.v)) or nil, state = h.v,
                 position = m.position, fresh = fresh }
    end
end

-- The success reply (co-play 2026-11-01, retro root cause 6): it leads with a sentence saying what was placed and
-- where it stands (metres + compass from me, facing, structure id from the census); the preview spots rejected
-- before the press come last, labelled as rejected (nothing was placed there). spent_all = false: a new piece
-- stands there but my material counts didn't visibly drop.
local EVIDENCE_WORDS = { telemetry = "the game confirmed it", xp = "my Construction XP rose", actor = "I can see it" }
local function success(api, job, spent, spent_all, evidence, xp_gain)
    local s = job.structure
    local at = (s and s.position) or (job.preview and job.preview.position) or job.spot.position
    local here = api.my_position()
    local dist, dir
    if here and at then
        local dx, dy = at[1] - here[1], at[2] - here[2]
        dist = r1(math.sqrt(dx * dx + dy * dy))
        if dist >= 0.5 then dir = compass(dx, dy) end
    end
    local facing = s and type(s.yaw) == "number" and compass(math.cos(math.rad(s.yaw)), math.sin(math.rad(s.yaw))) or nil
    local used = {}
    for _, c in ipairs(job.piece.cost or {}) do
        if spent[c.item] then used[#used + 1] = tostring(spent[c.item]) .. " " .. tostring(c.name) end
    end
    if xp_gain and xp_gain > 0 then used[#used + 1] = "+" .. tostring(xp_gain) .. " Construction XP" end
    local where = string.format("[%.1f, %.1f, %.1f]", at[1], at[2], at[3] or 0)
    local rel = dir and (tostring(dist) .. " m " .. dir .. " of me") or "right beside me"
    local line = "Placed the " .. job.piece.name .. " and it is built" .. (#used > 0 and (" (" .. table.concat(used, ", ") .. ")") or "")
    local fit -- the short "how it sits" sentence (a batch's line per piece)
    if s then
        line = line .. ": it stands " .. rel .. " at " .. where .. (facing and (", facing " .. facing) or "") .. " (" .. s.id .. ")."
    else
        line = line .. " (" .. (EVIDENCE_WORDS[evidence] or tostring(evidence)) .. "), but I can't see it in the world yet: it should be "
            .. rel .. " at " .. where .. ", where its preview was."
    end
    if not spent_all then line = line .. " My materials didn't visibly go down, so I can't say what it used." end
    local floor_words -- a piece placed freely (a station, a crate): which floor it stands on and where on it
    if s and s.position and not job.on then
        local okf, fl = pcall(W.floor_under, api, s.position, s.id)
        if okf and fl then floor_words, line = fl.words, line .. " " .. fl.words end
        -- off the floor: how far from his own house (live 07:4xZ: a campfire and crate "near me" went up 60 m E of the
        -- house he had just built, where a stone gather had taken him, and he said the house was done with them)
        if not (okf and fl) then
            local dm = api.module("deconstruct")
            local okb, bases = pcall(function() return dm and dm.bases(dm.ledger(nil), s.position) end)
            local house
            for _, b in ipairs(okb and type(bases) == "table" and bases or {}) do
                if b.covered and b.distance_m and (not house or b.distance_m < house.distance_m) then house = b end
            end
            if house and house.distance_m > (M.cfg.build.house_far_m or 12) then
                local hx, hy = house.centre[1] - s.position[1], house.centre[2] - s.position[2]
                line = line .. string.format(" It is %d m from my house (my roofed building of %d pieces at (%.0f, %.0f), %s of it), not by it.",
                    house.distance_m, house.pieces or 0, house.centre[1], house.centre[2], compass(-hx, -hy) or "away")
            end
        end
        if job.shelter then
            local okc, cov = pcall(W.covered_at, api, s.position)
            line = line .. (okc and cov and (" It has a roof over it" .. (job.shelter.on_mine and ", in my own building" or "") .. " (it needs shelter).")
                or " I couldn't confirm a roof over it after all.")
        end
    end
    local ground -- a floor put on the ground: how the ground lies round it
    local pid = tostring(job.piece.id or "")
    if s and s.position and not job.on and (pid:find("Foundation", 1, true) or pid:find("_Floor_", 1, true)) then
        local okg, g = pcall(W.ground_round, api, s)
        if okg and g then ground, line = g, line .. " " .. g.words end
    end
    -- mine: the game keeps no owner per piece (dump 26161880: FBuildingReplicatedEntry, FClientVisible/ServerOnly
    -- BuildingPieceState and ABaseBuildingActor carry none), so his own ledger (deconstruct.lua my_pieces.json) is what
    -- marks get_state.structures mine. The build-complete telemetry fills it too, but missed pieces placed in quick
    -- succession (live 2026-11-01: 18 noted of his ~30); a verified build reply is the surest record.
    if s and s.position then
        local dm = api.module("deconstruct")
        if dm and type(dm.note_mine) == "function" and type(dm.ledger) == "function" then
            pcall(function()
                local L = dm.ledger(dm.world_id())
                if dm.note_mine(L, { piece = job.piece.id, name = job.piece.name, position = s.position }, "build reply") then dm.save_ledger(L) end
            end)
        end
    end
    -- attached: how it really sits against the anchor, measured from the census (not from the preview)
    local att
    if job.on then
        local a, side = job.on.anchor, job.on.side
        local _, _, mount = M.flush_spot(a, side, job.on.box)
        local ceil = mount and mount.ceiling
        -- a door in its frame is IN the frame, not on an edge or a top (live 18:57Z: "on the in edge ... on its top")
        local inside = side == "in"
        local where_on = (inside and "in the frame of the " or side == "top" and "on top of the " or (ceil and "on top of the ")
            or ("on the " .. side .. (mount and " edge of the " or " side of the "))) .. tostring(a.name) .. " (" .. a.id .. ")"
            .. (ceil and (", reaching " .. side) or "") .. (job.on.top_as and " (over its floor: the side the room is on)" or "")
        att = s and M.flush_report(a, side, job.on.box, s, M.cfg.build.flush_tol_m)
        if mount and mount.edge and not mount.inside and s and type(s.yaw) == "number" then mem().ghost_yaw = s.yaw % 360 end -- re-sync
        local pp = job.preview and job.preview.position
        if att and job.on.mode == "cursor" and type(pp) == "table" then
            -- how far the game moved it from my cursor at the press: > 0 = its snap pulled it onto the plug
            att.snap_moved_m = math.floor(math.sqrt((s.position[1] - pp[1]) ^ 2 + (s.position[2] - pp[2]) ^ 2) * 100 + 0.5) / 100
            line = line .. (job.preview.snapped == true and " Its cursor jumped onto the flush spot before I pressed (the game's snap)."
                or " I can't watch this piece's preview snap, so I aimed at the flush spot and measured where it landed.")
        end
        if att then
            local parts = {}
            if math.abs(att.gap_m) > M.cfg.build.flush_tol_m then
                parts[#parts + 1] = string.format("%.2f m %s", math.abs(att.gap_m),
                    inside and "out of the frame's line" or ceil and (att.gap_m > 0 and "gap from the wall" or "over the wall")
                    or mount and (att.gap_m > 0 and "outside the edge" or "in from the edge") or (att.gap_m > 0 and "gap" or "overlap"))
            end
            if math.abs(att.offset_m) > M.cfg.build.flush_tol_m then parts[#parts + 1] = string.format("%.2f m off to the side", math.abs(att.offset_m)) end
            if math.abs(att.level_m) > M.cfg.build.flush_tol_m then parts[#parts + 1] = string.format("%.2f m %s", math.abs(att.level_m), att.level_m > 0 and "higher" or "lower") end
            if math.abs(att.facing_off_deg) > 2 then parts[#parts + 1] = string.format("turned %.0f degrees", att.facing_off_deg) end
            -- the sentence itself is the batch's fit (never cut out of the line by pattern: "0.73 m" has a dot; live
            -- 20:5xZ two NOT-square walls read "It stands at [...]" in the batch reply)
            fit = att.flush and (ceil and ("It sits squarely " .. where_on .. (mount.roof and ": its low edge on the wall's top, sloping up away from it."
                        or ": its edge on the wall's line, its top level with the wall's top, lined up with it."))
                    or inside and ("It sits squarely " .. where_on .. ": in the opening, its bottom level with the frame's, lined up with it.")
                    or mount and ("It stands squarely " .. where_on .. ": on the edge line, on its top, lined up with it.")
                    or ("It sits flush " .. where_on .. ": no gap, level, same facing."))
                or ("It is NOT " .. (mount and "square " or "flush ") .. where_on .. ": " .. table.concat(parts, ", ") .. ".")
        else
            fit = "I meant it to sit flush " .. where_on .. " but can't measure it until I can see it."
        end
        line = line .. " " .. fit
        if side == "top" and s then
            local edges
            for _, st in ipairs(W.structures(api, true) or {}) do if st.id == a.id then edges = st.edges end end
            local hint = M.roof_hint(a.box, job.on.box, edges, true, (W.piece_profile(api, job.data) or {}).profile)
            if hint then line, fit = line .. hint, (fit or "") .. hint end
        end
    end
    local rej = {}
    for _, r in ipairs(job.rejects or {}) do
        rej[#rej + 1] = { spot = r.spot, why = r.why, preview_at = r.preview_at, off_m = r.off_m, trail = r.trail, aim_s = r.aim_s }
    end
    if #rej > 0 then
        line = line .. " Before that " .. #rej .. (#rej == 1 and " preview spot was" or " preview spots were")
            .. " rejected and nothing was placed there; that's the normal search, not a failure."
    end
    return { ok = true, data = setmetatable({ built = line, placed = true, name = job.piece.name, piece = job.piece.id,
        structure = s and s.id or api.null, position = at, distance_m = dist, direction = dir, facing = facing,
        spent = api.object(spent), xp = xp_gain or api.null, evidence = evidence,
        rotation_verified = (att and math.abs(att.facing_off_deg) <= 2) or false, -- attached: the census yaw checked it
        attached_to = job.on and job.on.anchor.id or nil, side = job.on and job.on.side or nil,
        flush = att and att.flush, gap_m = att and att.gap_m, offset_m = att and att.offset_m, level_m = att and att.level_m,
        facing_off_deg = att and att.facing_off_deg, snap_moved_m = att and att.snap_moved_m,
        rejected_previews_before_placing = #rej > 0 and rej or nil,
        placed_after_s = job.place_aim_s, placed_trail = job.place_trail,
        fit = fit or (s and ("It stands at " .. where .. "." .. (floor_words and (" " .. floor_words) or "")
            .. (ground and (" " .. ground.words) or ""))) or nil,
        ground_fall_m = ground and ground.fall_m or nil,
        stayed = job.stayed or nil }, RESULT_MT) }
end
M._success = success

-- ------------------------------------------------------------------ several pieces in one go (speed)
-- Luis builds the way players do: the build screen stays open, he switches pieces inside it and places what is in
-- reach from where he stands. pieces = { {piece, on, at, near, rotation}, ... }; on may name an earlier item of the
-- list as "#k" ("#1:N" = the N edge of the piece item 1 built). Order: the nearest item whose "#k" pieces are built.
local function ref_of(on)
    local k, side = tostring(on or ""):match("^#(%d+):?(.*)$")
    return tonumber(k), side
end
function M.batch_items(list, max)
    max = max or M.cfg.build.batch_max
    if type(list) ~= "table" or #list == 0 then return nil, "pieces must be a list of {piece, on, ...}" end
    if #list > max then return nil, "at most " .. max .. " pieces in one go" end
    local items = {}
    for k, it in ipairs(list) do
        if type(it) ~= "table" or type(it.piece) ~= "string" or it.piece == "" then
            return nil, "pieces #" .. k .. " needs a piece name"
        end
        local r = ref_of(it.on)
        if r and (r < 1 or r > #list or r == k) then return nil, "pieces #" .. k .. ": on '" .. tostring(it.on) .. "' names no other item of the list" end
        local c = {}
        for key, v in pairs(it) do c[key] = v end
        items[k] = c
    end
    return items
end
function M.batch_args(b, k)
    local it, a = b.items[k], {}
    for key, v in pairs(it) do a[key] = v end
    local r, side = ref_of(it.on)
    if r then
        local res = b.results[r]
        local sid = res and res.ok and res.data and res.data.structure
        a.on = (type(sid) == "string" and sid or ("#" .. r)) .. (side ~= "" and (":" .. side) or "")
    end
    return a
end
-- A failure that would meet every other piece too ends a batch; any other one fails its own piece (and what goes on
-- it) and the rest go up. Rung 2 run 20261116-013406: a roof tried first stayed 1.4 m off, and the two walls and
-- the door listed with it were never tried ("Built 0 of 4").
M.BATCH_ENDS = { interrupted = true, cancelled = true, companion_down = true, no_permission = true, state_unavailable = true,
                 body_error = true, lease_expired = true }
function M.batch_goes_on(res) return not (res and M.BATCH_ENDS[tostring(res.reason)]) end
local function built_n(b)
    local n = 0
    for _, r in pairs(b.results) do if type(r) == "table" and r.ok then n = n + 1 end end
    return n
end
function M.batch_pick(api, b)
    local here = api.my_position()
    local best, bd
    local fo = b.failed_once or {}
    local bn = built_n(b)
    for _, retry in ipairs({ false, true }) do -- the ones not yet failed first; then the second tries
        for k, it in ipairs(b.items) do
            -- a second try only once something else went up since (the same piece from the same spot fails the same)
            if not b.done[k] and (fo[k] ~= nil) == retry and (not retry or fo[k] == true or bn > fo[k]) then
                local r = ref_of(it.on)
                local ready = not r or (b.results[r] and b.results[r].ok)
                if ready then
                    local pos
                    if r then pos = b.results[r].data.position
                    elseif it.on then local a = W.actor_info(api, tostring(it.on):match("^([^:]+)")); pos = a and a.position
                    elseif type(it.at) == "table" then pos = it.at end
                    local d = (here and type(pos) == "table" and pos[1] and math.sqrt((pos[1] - here[1]) ^ 2 + (pos[2] - here[2]) ^ 2)) or 1e6 + k
                    if not bd or d < bd then best, bd = k, d end
                end
            end
        end
        if best then return best end
    end
    return best
end
function M.batch_result(api, b, last, t_s)
    local lines, built, spent = {}, {}, {}
    local fail, fails = nil, {}
    for k = 1, #b.items do
        local r = b.results[k]
        if r and r.ok then
            local d = r.data or {}
            built[#built + 1] = { item = k, structure = d.structure, name = d.name, position = d.position, flush = d.flush,
                                  attached_to = d.attached_to, side = d.side, fit = d.fit }
            lines[#lines + 1] = "#" .. k .. " " .. tostring(d.name) .. " (" .. tostring(d.structure) .. "): " .. tostring(d.fit or "built")
            if type(d.spent) == "table" then for item, c in pairs(d.spent) do spent[item] = (spent[item] or 0) + c end end
        elseif r then
            fails[#fails + 1] = { k = k, r = r }
            fail = fail or fails[#fails]
        end
    end
    local untried = {}
    for k = 1, #b.items do if not b.results[k] then untried[#untried + 1] = "#" .. k end end
    local n = #b.items
    local head = string.format("Built %d of %d pieces in %d s", #built, n, math.floor((t_s or 0) + 0.5))
    local text = head .. (#lines > 0 and (": " .. table.concat(lines, " ")) or ".")
    -- a batch goes on past a piece that failed; what stands on it can't
    for _, f in ipairs(fails) do
        local it = b.items[f.k]
        text = text .. " #" .. f.k .. " (" .. tostring(it.key or it.piece) .. (it.on and (" on " .. tostring(it.on)) or "") .. ") failed: "
            .. tostring((f.r.data or {}).detail or f.r.reason)
    end
    if #untried > 0 then text = text .. " Not tried (they go on a piece that failed or the run stopped): " .. table.concat(untried, ", ") .. "." end
    local data = { built_pieces = built, spent = api.object(spent), presses = last and last.data and last.data.presses or nil }
    if fail or #built < n then
        data.detail, data.why = text, fail and (fail.r.data or {}).why or "not_all_built"
        data.failed_item = fail and fail.k or nil
        -- the failed piece's own measurements (where I aimed, where the cursor and ghost landed), as a single build
        -- returns them (live 21:15Z: a batch door "3.63 m from the flush spot" left nothing to debug)
        local fd = fail and fail.r.data or {}
        data.preview_reads, data.ghost_off_m, data.in_the_way = fd.preview_reads, fd.ghost_off_m, fd.in_the_way
        return { ok = false, reason = fail and fail.r.reason or "verification_failed", data = data }
    end
    data.built = text
    return { ok = true, data = data }
end
function M.batch_next(api, job, res)
    local b = job.batch
    b.results[b.i], b.done[b.i] = res, true
    -- a piece the game wouldn't take gets one more try once the others are up, as a player comes back to it (rung 2
    -- run 1, 05:0xZ: the door in its frame failed in the batch at 3.1 m, then went in first time on its own)
    b.failed_once = b.failed_once or {}
    if not res.ok and res.reason == "blocked" and b.failed_once[b.i] == nil then
        b.failed_once[b.i], b.done[b.i] = built_n(b), nil
    end
    if not res.ok and not M.batch_goes_on(res) then b.over = true; return false end
    local k, args, nj
    repeat
        k = M.batch_pick(api, b)
        if not k then b.over = true; return false end
        args = M.batch_args(b, k)
        b.i = k
        nj = start_build(api, args, b.ctx)
        if nj.ok == false then
            b.results[k], b.done[k] = nj, true
            if not M.batch_goes_on(nj) then b.over = true; return false end
        end
    until nj.ok ~= false
    -- the same job table goes on: the poll closure, the arbiter token and the open build screen stay with it
    local keep = { batch = true, token = true, own = true, presses = true, phase_s = true, phase_at = true, last_phase = true,
                   phase_k = true, stay_log = true, vt_log = true }
    for key in pairs(job) do if not keep[key] then job[key] = nil end end
    for key, v in pairs(nj) do if key ~= "presses" then job[key] = v end end
    job.rotation = tonumber(args.rotation) or job.rotation
    return true
end

local function step(api, job, t)
    local cfg = M.cfg.build
    local i = IN(api)
    local function leave_then(res)
        if job.batch and not job.batch.over and not job.stopped and M.batch_next(api, job, res) then return nil end
        job.final = job.final or res
        job.phase = "leave"
        return nil
    end
    if job.phase == "approach" and job.on and not job.stand_at and not job.stay_checked then
        -- in reach, a clear view, not in its way: place from here (a player turns, he doesn't walk)
        job.stay_checked = true
        local ok_stay, why = W.stay_ok(api, job, api.my_position())
        job.stay_why = why
        job.stay_log = job.stay_log or {}
        job.stay_log[#job.stay_log + 1] = (job.batch and ("#" .. tostring(job.batch.i) .. " ") or "") .. (ok_stay and "stayed" or tostring(why))
            .. (job.stay_off_m and string.format(" (view %.2f m off)", job.stay_off_m) or "")
        if ok_stay then job.stayed, job.phase = true, "open"; return nil end
    end
    if job.phase == "approach" then
        local here = api.my_position()
        local d = here and math.sqrt((here[1] - job.center[1]) ^ 2 + (here[2] - job.center[2]) ^ 2)
        -- attaching: stand OUTSIDE the flush spot, on the far side from the anchor, so the camera ray to the aim
        -- point never crosses the anchor piece (a side) / beside the anchor (top)
        if job.on and not job.stand_at and cfg.stand_search and not job.stands_done then
            job.stands_done = true
            local list = here and W.stands(api, job, here)
            if list and #list > 0 then
                job.stand_list, job.stand_i, job.stand_at = list, 1, list[1].pos
                job.stay_log = job.stay_log or {}
                job.stay_log[#job.stay_log + 1] = string.format("  -> %d spots with a clear view, the nearest %.1f m%s", #list, list[1].walk_m,
                    list[1].direct and "" or " (round something)")
            end
        end
        if job.on and not job.stand_at then
            local half = job.footprint / 2
            local _, axis, mount = M.flush_spot(job.on.anchor, job.on.side, job.on.box)
            local out_m = half + cfg.stand_extra_m
            -- a ceiling off a wall top: stand INSIDE the cell it covers, past its middle, looking back at the wall (from
            -- outside, the cell's other walls would be in the camera's way once the house is up)
            if mount and mount.ceiling then out_m = cfg.ceiling_stand_m end
            local ta = job.on.side == "in" and M.thin_axis(job.on.anchor.box)
            if ta then -- into a frame: stand across the wall (along its thin axis), on my side of it
                local yaw = math.rad(job.on.anchor.yaw or 0)
                local n = ta == 2 and { -math.sin(yaw), math.cos(yaw) } or { math.cos(yaw), math.sin(yaw) }
                local h = here or job.center
                if (h[1] - job.center[1]) * n[1] + (h[2] - job.center[2]) * n[2] < 0 then n = { -n[1], -n[2] } end
                out_m = 1.0 + cfg.stand_extra_m + 1.0
                -- a frame in a house: stand on its side that is off every floor (outside). Inside a closed room the
                -- camera boom presses against the far wall and its ray starts in that wall (live run 6, 22:5xZ: the
                -- door's cursor stuck on the N wall's inner face 2.8 m from the S frame, every read, so the door
                -- never snapped; run 5's frame stood on a floor with no wall behind me)
                local a0 = job.on.anchor
                local fz = a0.position[3] + a0.box.origin[3] - a0.box.extent[3]
                -- read just across the frame (0.75 m), not at the stand spot: 3.5 m out from a 3 m room is past its far
                -- wall, off the floor (live retest 23:02Z: he stood N of the N wall, the ray hit its outer face)
                local function floored(m)
                    local okf, f = pcall(W.floor_under, api, { job.center[1] + m[1] * 0.75, job.center[2] + m[2] * 0.75, fz }, a0.id)
                    return okf and f ~= nil
                end
                if floored(n) and not floored({ -n[1], -n[2] }) then n = { -n[1], -n[2] } end
                axis = n
            end
            -- standing height: on the floor under it, never the piece's own height (live 17:44Z: a ceiling's stand
            -- point at the wall top, 2.1 m up, so the go_to never arrived and kept steering the camera level at its
            -- goal through the whole aim: every cursor read at camera height on the walls)
            local sz = job.center[3]
            if mount and mount.ceiling then
                local a = job.on.anchor
                sz = a.position[3] + a.box.origin[3] - a.box.extent[3] + 0.88
            end
            job.stand_at = axis and { job.center[1] + axis[1] * out_m, job.center[2] + axis[2] * out_m, sz }
                or stand_point(here or job.center, job.center, out_m)
        end
        -- on to the build screen: the walk there ends first (a go_to still running steers the camera every frame,
        -- over every aim)
        local function to_open()
            if job.moving and (api.move_status() or {}).mode == "go_to" then api.call("move", "stop") end
            job.moving, job.phase = false, "open"
        end
        local ds = job.stand_at and here and math.sqrt((here[1] - job.stand_at[1]) ^ 2 + (here[2] - job.stand_at[2]) ^ 2)
        -- under a roof: there means on its floor. Live window 2 (03:25Z): the walk to a stand point inside his house
        -- ended ON its roof (4.7 m up, the door shut), 2 m from the point on the map, and every aim hit the roof
        if job.shelter and ds and ds <= 1.2 and not job.moving and math.abs(here[3] - job.stand_at[3]) > cfg.shelter_up_m then
            local c = job.center
            return api.fail("blocked", { piece = job.piece.id, why = "no_way_in", stand_at = job.stand_at, at = here,
                detail = string.format("I couldn't get in under the roof at (%.0f, %.0f) to put the %s down: the way I found ends %.1f m %s its floor%s. Nothing was placed.",
                    c[1], c[2], job.piece.name, math.abs(here[3] - job.stand_at[3]), here[3] > job.stand_at[3] and "above" or "below",
                    here[3] > job.stand_at[3] + 3 and " (on top of the building; its door may be shut)" or "") })
        end
        local there
        if job.stand_list then
            -- a spot from the stand search: there = the predicted view from where I stand lands on the aim point and
            -- I'm not where the piece goes. Rung 2 run 20261116-013406: spots 1.2 and 1.5 m away counted as reached
            -- at once (the old 1.2 m rule), so he placed from where the check had just said in_the_way /
            -- view_blocked: a red door-frame wall 0.30 m off its edge, a roof 1.4 m off
            if here and (not job.view_t or t >= job.view_t) then
                job.view_t = t + cfg.stand_view_every_s
                job.view_ok = W.stay_ok(api, job, here) and true or false
            end
            there = job.view_ok
        else
            there = (job.stand_at and ds and ds <= 1.2 and not (job.shelter and math.abs(here[3] - job.stand_at[3]) > cfg.shelter_up_m))
                or (not job.stand_at and d and d >= job.standoff - 0.6 and d <= cfg.reach_m - 1.5)
        end
        if there then
            if job.stand_list then
                job.stay_log[#job.stay_log + 1] = string.format("  -> placing from spot %d (%.1f m from it, view %.2f m off)", job.stand_i, ds or -1, job.stay_off_m or -1)
            end
            to_open(); return nil
        end
        if not job.moving and job.stand_list and (job.approaches or 0) >= 1 then
            -- the walk to that spot ended short of it: the next one, then the old rule
            job.stand_i = job.stand_i + 1
            local nx = job.stand_list[job.stand_i]
            job.approaches = 0
            if nx then job.stand_at = nx.pos else job.stand_list, job.stand_at = nil, nil; return nil end
        end
        if not job.moving then
            if (job.approaches or 0) >= 2 then
                if job.stand_at and d and d <= cfg.reach_m - 1.5 and d >= 1.5 then to_open(); return nil end -- close enough to try
                return api.fail("too_far", { piece = job.piece.id, distance = d, detail = "I can't get to a spot to build the " .. job.piece.name .. " from." })
            end
            local goal = job.stand_at or stand_point(here or job.center, job.center, job.standoff + 0.5)
            local mr = api.call("move", "go_to", goal, { tolerance_m = job.stand_list and cfg.stand_arrive_m or 0.8, timeout_s = job.stand_list and cfg.stand_walk_s or 60, allow_unstuck = false, owner_token = job.token })
            if not mr.ok then return mr end
            job.moving, job.approaches = true, (job.approaches or 0) + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        job.moving = false
        local res = type(st.result) == "table" and st.result or {}
        if job.stand_list then job.view_t = nil; return nil end -- the view from where the walk ended, then the next spot
        if res.status ~= "arrived" and res.status ~= "stopped" then
            local sk = api.module("skills")
            local words = sk and sk.why_words and sk.why_words(res.reason) or "I can't find a way there"
            return api.fail(api.reason_code(res.reason or "path_blocked") == "body_error" and "path_blocked" or api.reason_code(res.reason or "path_blocked"),
                { piece = job.piece.id, why = res.reason, stand_at = job.stand_at, trip = res.trip,
                  detail = job.shelter and string.format("I can't get in under the roof at (%.0f, %.0f) to put the %s there (it needs shelter): %s%s. Nothing was placed.",
                        job.center[1], job.center[2], job.piece.name, words, job.shelter.on_mine and "; it's my own building, and its door may be shut" or "")
                      or ("I can't get to where the " .. job.piece.name .. " should go: " .. words .. ".") })
        end
        return nil
    elseif job.phase == "open" then
        W.arm_hooks(api)
        if i then i.claim("build", "build:" .. job.piece.id) end
        local mode = W.mode(api)
        if mode == "Selection" then job.phase, job.sel_t = "select", nil; return nil end
        if mode == "Placement" then job.phase = "select"; return nil end
        if mode == nil then return leave_then(api.fail("state_unavailable", { detail = "I can't read the build mode." })) end
        if job.open_t and t < job.open_t then return nil end
        if mode ~= "None" then return nil end -- some other build mode: wait for it to settle (toggle-safe)
        if job.opens >= 2 then return leave_then(api.fail("verification_failed", { why = "menu_not_open", detail = "I pressed build but the build menu didn't open." })) end
        job.opens = job.opens + 1
        job.presses[#job.presses + 1] = "menu"
        W.press(api, W.menu_action())
        job.open_t = t + cfg.open_wait_s
        return nil
    elseif job.phase == "select" then
        local mode = W.mode(api)
        if mode == "Placement" and W.placing(api) == job.piece.id then
            job.phase = "rotate"
            return nil
        end
        if mode == "Placement" and not job.sel_t then
            -- placing another piece (the last one of a batch): pick the new one in the build UI straight away; if the
            -- game doesn't switch, back out of placing and open the menu again
            if not job.switch_t then
                local ok = W.select(api, job.data)
                job.presses[#job.presses + 1] = "select"
                job.switch_t = ok and (t + cfg.select_wait_s) or t
                return nil
            end
            if t < job.switch_t then return nil end
            if not job.switch_out then
                job.switch_out = true
                job.presses[#job.presses + 1] = "cancel"
                if i then i.leave_build_step(function(a) W.press(api, a) end) end
                job.phase, job.open_t = "open", t + cfg.open_wait_s
            end
            return nil
        end
        if not job.sel_t then
            if mode ~= "Selection" then return nil end
            local ok, err = W.select(api, job.data)
            job.presses[#job.presses + 1] = "select"
            if not ok then return leave_then(api.fail("verification_failed", { why = "select_failed", detail = "I couldn't pick the " .. job.piece.name .. " in the build menu (" .. tostring(err) .. ")." })) end
            job.sel_t = t + cfg.select_wait_s
            return nil
        end
        if t >= job.sel_t then
            return leave_then(api.fail("verification_failed", { why = "not_selected", detail = "I picked the " .. job.piece.name .. " in the build menu but the game didn't start placing it." }))
        end
        return nil
    elseif job.phase == "rotate" then
        if job.rot_left == nil and job.on and job.on.mount and job.on.turn_auto then
            -- a wall on an edge / a door in a frame must line up with it. Live 15:26Z: the ghost takes my view's yaw
            -- squared to the anchor's 90 degree grid (aimed east -> yaw 0: the wall stood across the edge); 15:34Z:
            -- 6 presses of 15 turned it along the edge, square. So turn by (wanted - view) mod 180.
            -- Live 15:42-15:46Z (frames 65, 66 turned the wrong way): the ghost does NOT take my view's yaw; it keeps
            -- the rotation of the last placement (63: 0, 64: 0+90, 65: 90+90 = 180, 66: 180+90 = 270, all matching the
            -- census). So I track that yaw (mem().ghost_yaw, every rotate press, re-synced from the census after each
            -- wall) and turn by (wanted - current) mod 180. Unknown at session start: assumed 0, then synced.
            local cur = mem().ghost_yaw or 0
            job.on.ghost_yaw0 = cur
            local per = job.on.mount.per or 180
            job.rotation = ((job.on.mount.yaw - cur) % per + per) % per
        end
        job.rot_left = job.rot_left or (job.rotation and math.floor(((job.rotation % 360) / cfg.rotate_step_deg) + 0.5) or 0)
        if job.rot_left > 0 then
            -- one input = one 15 degree step whatever its axis value (live 2026-11-16: one input of value 6 turned
            -- the ghost 15, not 90: the wall stood 75 off)
            job.rot_left = job.rot_left - 1
            job.presses[#job.presses + 1] = "rotate"
            W.press(api, W.rotate_action(api))
            mem().ghost_yaw = ((mem().ghost_yaw or 0) + cfg.rotate_step_deg) % 360 -- the ghost keeps it (see above)
            return nil
        end
        local P = pl()
        local env = {
            trace = function(a, b) return W.trace(api, a, b) end,
            me = function() local p = api.my_position(); return p and { X = p[1] * 100, Y = p[2] * 100, Z = p[3] * 100 } end,
            players = function()
                local out = {}
                for _, th in ipairs(api.census_things(30, 20) or {}) do if th.category == "players" then out[#out + 1] = th end end
                return out
            end,
            aim = function(p)
                -- a go_to still running steers the camera every frame over this aim (live 17:44Z): a player stands
                -- still to place, so it ends first
                if (api.move_status() or {}).mode == "go_to" then api.call("move", "stop") end
                job.aim_raw = p
                local c = job.on and job.on.mode == "cursor" and job.on.corr
                if c then p = { p[1] + c[1], p[2] + c[2], p[3] + (c[3] or 0) } end
                job.aim_seq, job.last_aim = W.hook_seq(), p
                job.aim_cam = W.camera(api) -- the rotation is worked out from here; the camera swings after it
                local dist, exact = W.aim(api, p)
                job.aim_exact, job.aim_t = exact == true, api.now()
                return dist
            end,
            read = preview_reader(api, job),
        }
        job.env = env
        -- snap-only? From the piece's own data first (live 2026-11-01: the preview-actor read came back unreadable for
        -- the Square Foundation, profile bCanOnlyBeSnapped = false, so a ground foundation was refused as
        -- preview_ambiguous); else the preview's profile; a preview that hasn't spawned yet is waited for. Unknown
        -- still counts as snap (never press blind).
        local prof = W.piece_profile(api, job.data)
        local pa = W.preview_actor(api, job)
        local nopa = mem().nopa or {}
        mem().nopa = nopa
        if job.on and not pa and not nopa[job.piece.id] and (job.pa_waits or 0) < cfg.preview_waits then -- attaching: give a preview actor time to spawn
            job.pa_waits = (job.pa_waits or 0) + 1
            return nil
        end
        if job.on and not pa then nopa[job.piece.id] = true end -- an instance-only piece: never wait for its preview again
        if prof and prof.snap_only ~= nil then
            job.snap, job.snap_src = prof.snap_only, "piece data"
        elseif pa then
            local v = W.snap_only(api, pa)
            job.snap, job.snap_src = v ~= false, v == nil and "unreadable" or "preview"
        elseif (job.pa_waits or 0) < cfg.preview_waits then
            job.pa_waits = (job.pa_waits or 0) + 1
            return nil
        else
            job.snap, job.snap_src = true, "no preview"
        end
        if prof and prof.box then job.footprint = math.max(prof.box.extent[1], prof.box.extent[2]) * 2 end
        local spots, skipped
        if job.on then
            if job.on.provisional then -- the sizes, now that the new piece is selected (its data is loaded)
                local a = job.on.anchor
                local ab = a.data and (W.piece_profile(api, a.data) or {}).box
                if not ab and a.piece == job.piece.id then ab = prof and prof.box end
                if not (ab and prof and prof.box) then
                    return leave_then(api.fail("state_unavailable", { on = a.id, detail = "I can't read the size of the "
                        .. tostring(ab and job.piece.name or a.name) .. ", so I can't line it up flush. Nothing was placed." }))
                end
                a.box, job.on.provisional = ab, false
            end
            job.on.z_offset = prof and prof.z_offset or 0
            -- the flush spot from both real sizes, aimed snap_aim_m (then twice that) OUTSIDE it: only a ghost the
            -- game snapped sits on the spot itself (preview_reader's positive snap signal)
            local box = (prof and prof.box) or job.on.box
            local spot, axis = M.flush_spot(job.on.anchor, job.on.side, box)
            job.on.box, job.on.target, job.center = box, spot, spot
            local here = api.my_position() or spot
            local out = axis
            if not out then
                local dx, dy = here[1] - spot[1], here[2] - spot[2]
                local l = math.sqrt(dx * dx + dy * dy)
                out = l > 0.01 and { dx / l, dy / l } or { 1, 0 }
            end
            spots, skipped = {}, {}
            local function add(p, mm) spots[#spots + 1] = { position = p, exact = true, match_m = mm } end
            job.on.mode = pa and "ghost" or "cursor"
            local _, _, mount = M.flush_spot(job.on.anchor, job.on.side, box)
            local a0 = job.on.anchor
            local a_top = a0.position[3] + a0.box.origin[3] + a0.box.extent[3]
            local a_bottom = a0.position[3] + a0.box.origin[3] - a0.box.extent[3]
            if job.on.side == "in" then
                -- into a frame: the cursor must hover over the frame itself (wiki: snapping works "when hovering over
                -- the previewed object with another built object"); live 15:43Z: aimed into the doorway, the ray went
                -- through it and the cursor landed 6-9 m away. So aim at the frame above the opening (its lintel).
                local h = a_top - a_bottom
                for _, f in ipairs({ 0.88, 0.8 }) do add({ a0.position[1], a0.position[2], a_bottom + h * f }, 3.0 + h) end
                job.on.cursor_target = { a0.position[1], a0.position[2], a_bottom + h * 0.88 }
            elseif not pa then
                if mount and mount.ceiling and axis then
                    -- off a wall's top: from the side it reaches into, aim at the wall's face just below its top (I
                    -- can't see the top from the ground); the nearest plug for a tile there is the top edge
                    local p = { a0.position[1] + axis[1] * 0.1, a0.position[2] + axis[2] * 0.1, a_top - cfg.ceiling_below_m }
                    add(p, 3.0)
                    job.on.cursor_target, job.on.cursor_tol_m, job.on.cursor_tol_z_m = p, 0.6, 0.4
                elseif mount and axis then
                    -- a wall on an edge: aim just INSIDE the edge on the anchor's top face. Live 15:42Z: aimed at the edge
                    -- line from outside, the ray hit the foundation's side face and the frame snapped to its BOTTOM edge,
                    -- 3 m low. On the top face the game snaps it to the top edge (live 15:34Z: square, 6 cm pull).
                    local p = { spot[1] - axis[1] * cfg.edge_in_m, spot[2] - axis[2] * cfg.edge_in_m, a_top }
                    add(p, 1.0)
                    job.on.cursor_target = p
                else -- no ghost to watch: aim at the flush spot itself (the game snaps it), then just beside it
                    add(spot, 1.0)
                    add({ spot[1] + out[1] * 0.15, spot[2] + out[2] * 0.15, spot[3] }, 1.0)
                end
            elseif axis then
                -- live 2026-11-01: aimed 0.25 / 0.5 m outside the flush spot, the free ghost landed 0.8-1.1 m further
                -- out and never snapped. A player looks at the anchor's EDGE (its plugs) to snap: aim on its top just
                -- inside the edge, then just outside it, then the old outside-the-spot points. The free ghost follows
                -- the cursor (1.5 m+ from the flush spot here), so the snap signal stays unambiguous.
                local a = job.on.anchor
                local _, i = side_axis(a, job.on.side)
                local e = a.box.extent[i]
                local top = a.position[3] + a.box.origin[3] + a.box.extent[3]
                local edge = { a.position[1] + axis[1] * e, a.position[2] + axis[2] * e, top }
                for _, o in ipairs({ -cfg.edge_aim_m, cfg.edge_aim_m, 0 }) do
                    add({ edge[1] + axis[1] * o, edge[2] + axis[2] * o, top }, 2 * box.extent[i] + 1.5)
                end
            end
            if pa and job.on.side == "top" and not mount and not axis and W.snap_only(api, pa) == false
                and not M.roof_hint(a0.box, box, nil, false, prof and prof.profile) then
                -- a piece that doesn't snap, on a top (a station on a foundation; never a roof or floor tile, which
                -- would land on the floor inside the walls): its preview sits where I aim, so
                -- aim at the spot itself, then beside it toward me. Live 2026-11-16: aimed 0.25 m outside to watch
                -- for a snap, a crafting table's green preview stayed there and was never pressed ("not_snapped")
                job.on.free = true
                add(spot, 1.0)
                for _, o in ipairs({ 0.4, -0.4 }) do add({ spot[1] + out[1] * o, spot[2] + out[2] * o, spot[3] }, 1.0) end
            elseif pa and job.on.side ~= "in" then
                for _, k in ipairs({ 1, 2 }) do
                    local o = cfg.snap_aim_m * k
                    add({ spot[1] + out[1] * o, spot[2] + out[2] * o, spot[3] }, 2 * cfg.snap_aim_m + 0.5)
                end
            end
        else
            spots, skipped = P.spots(env, job.center, { footprint_m = job.footprint, standoff_m = math.max(0.8, job.footprint / 2 + 0.3),
                                                        around_m = job.exact and { 1.0 } or { 1.5, 3.0 }, around_n = 8,
                                                        shelter = job.shelter ~= nil })
            if job.exact and spots[1] and not spots[1].exact then table.insert(spots, 1, { position = job.center, exact = true }) end
            if #spots == 0 then spots = { { position = job.center, exact = true } } end
        end
        job.skipped = skipped
        -- free placement: the spots the cursor reaches soonest first. Its position steps only every 0.5-1.4 s (live
        -- 03:37Z: 1.4 s, the first spot 7 m from where the preview sat -> 4.4 s and still 2.5 m short), so the
        -- nearest good spot to where the preview already is beats the "best" one across the clearing
        if not job.on and #spots > 1 then
            local okc, mc = pcall(W.mpc, api)
            local cur = okc and mc and mc.position
            if cur then
                local function dc(sp) return math.sqrt((sp.position[1] - cur[1]) ^ 2 + (sp.position[2] - cur[2]) ^ 2) end
                local head = (job.exact and spots[1].exact) and table.remove(spots, 1) or nil
                table.sort(spots, function(a, b) return dc(a) < dc(b) end)
                if head then table.insert(spots, 1, head) end
                job.cursor_at_start = { r1(cur[1]), r1(cur[2]), r1(cur[3] or 0) }
            end
        end
        local checks = (job.on and job.on.mode == "cursor" and cfg.cursor_checks) or (job.on and 4) or 3
        local exact = cfg.aim_exact and W.rig(api) ~= nil
        job.checker = P.checker(env, spots, { match_m = function(sp) return sp.match_m or cfg.match_m end, checks = checks,
                                              budget_s = cfg.budget_s, compare = "2d",
                                              wait_s = exact and cfg.aim_wait_s or nil,
                                              settle_s = exact and 0 or cfg.settle_s })
        job.phase = "check"
        return nil
    elseif job.phase == "check" then
        if W.mode(api) ~= "Placement" then
            return leave_then(api.fail("verification_failed", { why = "placement_closed", detail = "The building preview closed before I could place the " .. job.piece.name .. "." }))
        end
        local r = job.checker:step(t)
        if not r then return nil end
        if r.give_up then
            local P = pl()
            local common = P.common_reason(r.rejects)
            local texts = W.texts(api)
            local code
            for s, name in pairs(M.STATES) do if name == common then code = s end end
            local reason = code and M.STATE_REASON[code] or "blocked"
            if common == "preview_ambiguous" then
                return leave_then(api.fail("verification_failed", { why = "preview_ambiguous", piece = job.piece.id, snap_only_from = job.snap_src,
                    detail = "I can't tell whether the " .. job.piece.name .. " would snap into place there, so I didn't place it." }))
            end
            if r.why == "preview_unreadable" then
                return leave_then(api.fail("verification_failed", { why = "preview_unreadable", piece = job.piece.id,
                    detail = "I can't see the building preview, so I didn't place anything." }))
            end
            local words = (code == 11 and job.piece.shelter_text) or (code and texts[code]) or M.REJECT_WORDS[common]
                or "the game wouldn't let me place it"
            local d = { piece = job.piece.id, why = common, tried = r.rejects, skipped = job.skipped,
                        detail = (#r.rejects > 1 and "Every spot I tried here: " or "I can't put the " .. job.piece.name .. " there: ") .. tostring(words) }
            if job.on then
                local a, best = job.on.anchor, job.on.best_off
                d.attach_to, d.side = a.id, job.on.side
                d.ghost_off_m = best and math.floor(best * 100 + 0.5) / 100 or nil
                d.preview_reads = job.on.reads -- where I aimed, where the cursor and the ghost landed (newest last)
                d.detail = "I couldn't get the " .. job.piece.name .. " to sit flush on the " .. job.on.side
                    .. (job.on.side == "top" and " of the " or " side of the ") .. tostring(a.name) .. " (" .. a.id .. "): " .. tostring(words)
                    .. (best and string.format("; the closest its preview came was %.2f m from the flush spot", best) or "")
                    .. ". Nothing was placed."
                if common == "preview_red" and job.on.target then
                    local skip = { [a.id] = true }
                    local mount = job.on.mount or {}
                    local names = {}
                    for _, st in ipairs(M.standing_in(W.structures(api, true), job.on.target, job.on.box, mount.yaw or a.yaw, skip)) do
                        names[#names + 1] = "the " .. tostring(st.name) .. " (" .. tostring(st.id) .. ")"
                    end
                    if #names > 0 then
                        d.in_the_way = names
                        d.detail = d.detail .. " Within 0.6 m of where it would go stands " .. table.concat(names, " and ") .. "."
                    end
                end
                -- a door aimed at a door-frame wall's side (live 21:16Z twice, "on 107" and "107:N"): it goes IN the frame
                -- (live 20:29Z: Door on 94:in built square); the frame by the game's asset id
                if job.on.side ~= "in" and tostring(a.piece or ""):find("Doorframe", 1, true) and M.thin_axis(job.on.box)
                    and a.box and job.on.box.extent[3] < a.box.extent[3] then
                    d.detail = d.detail .. " A door goes into the frame's opening: on '" .. a.id .. ":in'."
                end
                if job.on.side == "top" then
                    local edges
                    for _, s in ipairs(W.structures(api, true) or {}) do if s.id == a.id then edges = s.edges end end
                    local hint = M.roof_hint(a.box, job.on.box, edges, false, (W.piece_profile(api, job.data) or {}).profile)
                    if hint then d.detail = d.detail .. hint end
                end
            end
            if reason == "missing_materials" then d.missing = job.missing end
            if common == "preview_red" and not job.on then
                -- what stands in the footprint of the spots tried (the census; a fact, not a guess)
                local half = (job.footprint or cfg.footprint_m) / 2
                local box = { origin = { 0, 0, 1.2 }, extent = { half, half, 1.2 } }
                local seen, names = {}, {}
                local okr, rows = pcall(W.structures, api, true)
                for _, st in ipairs(okr and type(rows) == "table" and rows or {}) do -- floors are what it stands on, not in its way
                    local pid = tostring(st.piece or "")
                    if pid:find("Foundation", 1, true) or pid:find("_Floor_", 1, true) then seen[st.id] = true end
                end
                for _, rj in ipairs(r.rejects or {}) do
                    for _, st in ipairs(okr and type(rows) == "table" and M.standing_in(rows, rj.spot, box, 0, {}, 0) or {}) do
                        if not seen[st.id] then seen[st.id] = true; names[#names + 1] = "the " .. tostring(st.name) .. " (" .. tostring(st.id) .. ")" end
                    end
                end
                -- the preview never got there (live window 2: it sat on the roof above me, 3 m off and 4.7 m up)
                local lr = r.rejects and r.rejects[#r.rejects]
                if lr and lr.preview_at and lr.spot and ((lr.off_m or 0) > cfg.match_m or math.abs(lr.preview_at[3] - lr.spot[3]) > 1.5) then
                    local up = lr.preview_at[3] - lr.spot[3]
                    d.detail = d.detail .. string.format(". Its preview never reached the spot: it stayed %.1f m off%s", lr.off_m or 0,
                        math.abs(up) > 1.5 and string.format(" and %.1f m %s it (on whatever my view hit)", math.abs(up), up > 0 and "above" or "below") or "")
                end
                for _, sk in ipairs(job.skipped or {}) do -- the ground itself (live 03:29Z: a foundation on a slope, 2.07 m)
                    if sk.exact and sk.why == "uneven" and sk.spread_m then
                        d.detail = d.detail .. string.format(". The ground where it would go rises %.1f m across its footprint", sk.spread_m)
                    end
                end
                if okr and type(rows) == "table" then
                    d.in_the_way = names
                    d.detail = d.detail .. (#names > 0 and (". Where it would go stands " .. table.concat(names, " and ") .. ".")
                        or ". Nothing built stands where it would go.")
                end
            end
            -- the cause from the game itself: one press on the red preview, as a player clicks to see the message
            -- (BuildInteractionComponent:Client_ShowValidityNotification, the refused hook)
            if common == "preview_red" and cfg.red_probe_s > 0 and not job.red_probe and W.mode(api) == "Placement" and W.place_action(api) then
                job.red_probe = { reason = reason, d = d }
                job.refused0 = (W.hook("refused") or {}).seq or 0
                job.complete0 = (W.hook("complete") or {}).seq or 0
                local last = r.rejects and r.rejects[#r.rejects]
                job.spot = { position = last and (last.preview_at or last.spot) or job.center }
                job.before_ids = {}
                for _, st in ipairs(W.structures_near(api, job.piece.id, job.spot.position, cfg.before_m) or {}) do job.before_ids[st.id] = true end
                job.presses[#job.presses + 1] = "place (to see why it's red)"
                W.press(api, W.place_action(api))
                job.phase, job.verify_until, job.next_actor_check = "verify", t + cfg.red_probe_s, t + 0.5
                return nil
            end
            return leave_then(api.fail(reason, d))
        end
        if r.press then
            job.spot, job.preview = r.spot, r.preview
            job.rejects = r.rejects
            job.place_trail, job.place_aim_s = r.trail, r.aim_s
            job.refused0 = (W.hook("refused") or {}).seq or 0
            job.complete0 = (W.hook("complete") or {}).seq or 0
            local pa = W.place_action(api)
            if not pa then return leave_then(api.fail("not_implemented", { why = "no_place_action", detail = "I can't find the place key." })) end
            -- this piece's actors already standing around the spot: the one the press builds is the id not in here
            job.before_ids = {}
            local at = (r.preview and r.preview.position) or (r.spot and r.spot.position)
            for _, s in ipairs(W.structures_near(api, job.piece.id, at, cfg.before_m) or {}) do job.before_ids[s.id] = true end
            job.presses[#job.presses + 1] = "place"
            W.press(api, pa)
            job.phase, job.verify_until, job.next_actor_check = "verify", t + cfg.verify_s, t + cfg.actor_check_s
            job.press_t, job.vt = t, {}
        end
        return nil
    elseif job.phase == "verify" then
        local rf = W.hook("refused")
        if rf and rf.seq > job.refused0 then
            local texts = W.texts(api)
            local reason = M.STATE_REASON[rf.v] or "blocked"
            local says = tostring((rf.v == 11 and job.piece.shelter_text) or texts[rf.v] or M.STATE_TEXT[rf.v] or "it wouldn't let me place it")
            if job.red_probe then
                local d = job.red_probe.d
                d.why, d.game_says = M.STATES[rf.v] or tostring(rf.v), says
                d.detail = d.detail .. " When I pressed place once to see why, the game said: \"" .. says .. "\". Nothing was placed."
                return leave_then(api.fail(reason, d))
            end
            return leave_then(api.fail(reason, { piece = job.piece.id, why = M.STATES[rf.v] or tostring(rf.v),
                detail = "The game refused it: " .. tostring((rf.v == 11 and job.piece.shelter_text) or texts[rf.v] or "it wouldn't let me place it") .. "." }))
        end
        -- spent: each requirement item fell (own inventory + nearby storage)
        local counts = api.counts() or {}
        local storage = W.storage_counts(api, 15)
        local all_fell, spent = true, {}
        for _, c in ipairs(job.piece.cost or {}) do
            local before = (job.counts0[c.item] or 0) + ((job.storage0 or {})[c.item] or 0)
            local now = (counts[c.item] or 0) + (storage[c.item] or 0)
            -- at most the game's cost: the storage read is around where I stand, so a walk away from a stocked crate
            -- reads as logs spent (live 23:5xZ: a Door "used 15 Ash Logs" after a 52 s walk; it costs 2)
            if now < before then spent[c.item] = math.min(before - now, tonumber(c.count) or (before - now)) else all_fell = false end
            if (job.counts0[c.item] or 0) < (counts[c.item] or 0) then all_fell = false end
        end
        local cp = W.hook("complete")
        local evidence
        if cp and cp.seq > job.complete0 and (not job.piece.index or cp.v == job.piece.index) then evidence = "telemetry" end
        local xp = W.construction_xp(api)
        if not evidence and job.xp0 and xp and xp > job.xp0 then evidence = "xp" end
        -- the new piece in the world, looked for even when the game already confirmed it (telemetry used to skip
        -- this, so structure was always null); at most every 0.5 s (one find_all each)
        if not job.structure and t >= job.next_actor_check then
            job.next_actor_check = t + cfg.actor_check_s
            job.structure = W.new_structure(api, job)
        end
        if not evidence and job.structure then evidence = "actor" end
        -- when each proof arrived after the press (s), for the speed work
        if job.vt and job.press_t then
            local function mark(k, on) if on and not job.vt[k] then job.vt[k] = math.floor((t - job.press_t) * 100 + 0.5) / 100 end end
            mark("spent", all_fell); mark("telemetry", cp and cp.seq > job.complete0); mark("xp", job.xp0 and xp and xp > job.xp0)
            mark("actor", job.structure ~= nil)
            job.vt_log = job.vt_log or {}
            job.vt_log["#" .. tostring(job.batch and job.batch.i or 1)] = job.vt
        end
        local xp_gain = (job.xp0 and xp) and (xp - job.xp0) or nil
        local function built(spent_all)
            mem().structs_t = nil -- get_state.structures re-reads at once, so the next state shows the new piece
            return leave_then(success(api, job, spent, spent_all, evidence, xp_gain))
        end
        if all_fell and evidence then
            -- confirmed: give the census up to cfg.find_s to show the piece, so the reply can say where it stands
            job.found_by = job.found_by or (t + cfg.find_s)
            if job.structure or t >= job.found_by then return built(true) end
            return nil
        end
        if t >= job.verify_until and job.structure then return built(false) end -- a new piece stands there: built
        if t >= job.verify_until and job.red_probe and not evidence then
            local d = job.red_probe.d
            d.detail = d.detail .. " I pressed place once to see why and the game gave no message. Nothing was placed."
            return leave_then(api.fail(job.red_probe.reason, d))
        end
        if t >= job.verify_until then
            return leave_then(api.fail("verification_failed", { piece = job.piece.id, spent = api.object(spent), evidence = evidence or api.null,
                detail = "I pressed place for the " .. job.piece.name .. " but " .. (evidence and "the materials weren't used" or "nothing was built") .. "." }))
        end
        return nil
    else -- leave: Cancel until the mode is VERIFIED None (read twice, after the press has had time to land)
        -- live 14:59 UTC: one Cancel then a single read must never count as "closed"; an unreadable mode is not
        -- closed either. Bounded: cfg.leave_presses Cancels, one per cfg.leave_wait_s; the claim is released only
        -- once None is confirmed, or when giving up (then input.lua's orphan sweep keeps cancelling).
        local mode = W.mode(api)
        local function done(closed)
            if i then i.release("build") end
            local res = job.final or api.fail("verification_failed", { detail = "build ended" })
            if job.batch then res = M.batch_result(api, job.batch, res, api.now() - (job.batch.t0 or api.now())) end
            res.data = res.data or {}
            res.data.left_build_mode = closed
            if not closed then
                res.data.build_mode_after = mode or api.null
                if res.ok then res.data.warning = "the build screen may still be open" end
            end
            return res
        end
        if job.leave_t and t < job.leave_t then return nil end
        if mode == "None" then
            job.none_reads = (job.none_reads or 0) + 1
            if job.none_reads >= 2 then return done(true) end
            job.leave_t = t + cfg.leave_wait_s
            return nil
        end
        job.none_reads = 0
        if job.leaves >= cfg.leave_presses then return done(false) end
        job.leaves = job.leaves + 1
        job.presses[#job.presses + 1] = "cancel"
        if i then i.leave_build_step(function(a) W.press(api, a) end) end
        job.leave_t = t + cfg.leave_wait_s
        return nil
    end
end
M._step = step

M.NEEDS.build = { { "sense", "local_pc" }, { "inventory", "list" }, { "move", "go_to" }, { "move", "status" }, { "input", "gate" } }
M.HANDLERS.build = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    args = args or {}
    local batch
    if args.pieces ~= nil then
        local bo = ctx.batch_opts or {} -- build_blueprint: a longer list, going on past a piece that failed
        local items, bad = M.batch_items(args.pieces, bo.max)
        if not items then return { ok = false, reason = "invalid_args", data = { detail = bad } } end
        batch = { items = items, results = {}, done = {}, t0 = api.now(), ctx = ctx, keep_going = bo.keep_going }
        batch.i = M.batch_pick(api, batch)
        if not batch.i then return { ok = false, reason = "invalid_args", data = { detail = "every piece names another one with #k: none can go first" } } end
        args = M.batch_args(batch, batch.i)
    end
    local job = start_build(api, args, ctx)
    while job.ok == false do
        if not batch then return job end
        batch.results[batch.i], batch.done[batch.i] = job, true
        local k = M.batch_goes_on(job) and M.batch_pick(api, batch)
        if not k then return M.batch_result(api, batch, job, 0) end
        batch.i = k
        args = M.batch_args(batch, k)
        job = start_build(api, args, ctx)
    end
    job.batch = batch
    job.rotation = tonumber(args.rotation) or job.rotation
    local A = arbiter(api)
    local function release(why)
        if job.token and job.own ~= "released" then job.own = "released"; if A then pcall(A.release, api.log, job.token, why) end end
    end
    local function acquire()
        if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
        if not A then job.own = "none"; return true end
        local r = A.request(api.log, { name = "skill:build", level = "command", uses_move = true, lease_s = 30, resumable = true,
            on_suspend = function()
                job.own = "suspended"
                -- leave build mode at once: a reflex click must never place the piece (review finding 4)
                local i = IN(api)
                if i and not paused() then i.release("build"); i.leave_build_step(function(a) W.press(api, a) end) end
                if job.phase ~= "approach" and job.phase ~= "leave" then job.reopen = true end
            end,
            on_resume = function() job.own = "owner"; job.resumed = true; return true end,
            on_stop = function(_, _, why) if job.own ~= "released" then job.stopped = why or "stopped" end end })
        if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
        job.own = "waiting"
        return false
    end
    local a = { kind = "build", id = ctx.id, timeout_s = M.cfg.build.timeout_s * (batch and #batch.items or 1) }
    a.cancel = function()
        local i = IN(api)
        if i and not paused() then i.release("build"); i.leave_build_step(function(x) W.press(api, x) end) end
        if not paused() then api.call("move", "stop") end
        release("cancelled")
    end
    a.poll = function(self)
        if paused() then self.started = api.now(); return nil end -- never a game call under pause
        if job.stopped and job.phase ~= "leave" then
            job.final = api.fail("interrupted", { why = job.stopped, detail = "Something else took over (" .. tostring(job.stopped) .. "), so I put the build away." })
            job.phase = "leave"
        end
        if not acquire() or job.own == "suspended" or api.reflex_owns_pawn() then self.started = api.now(); return nil end
        -- the lease is renewed every tick it runs (arbiter rule; live 2026-11-01: never renewed, so any build longer
        -- than lease_s, e.g. a 30 s walk to the spot, ended "interrupted: lease_expired")
        if A and job.own == "owner" and job.token then A.renew(job.token) end
        if job.resumed then
            job.resumed = nil
            if job.reopen then job.reopen, job.phase, job.opens, job.sel_t, job.open_t = nil, "open", 0, nil, nil
            elseif job.phase == "approach" then job.moving = false end
        end
        -- where the time goes, per phase (s): the speed work measures against Luis's 3.81 s/piece from these
        local now = W.clock(api)
        job.phase_s = job.phase_s or {}
        if job.phase_at and job.last_phase then
            job.phase_s[job.last_phase] = (job.phase_s[job.last_phase] or 0) + (now - job.phase_at)
            local pk = "#" .. tostring(job.batch and job.batch.i or 1)
            job.phase_k = job.phase_k or {}
            job.phase_k[pk] = job.phase_k[pk] or {}
            job.phase_k[pk][job.last_phase] = (job.phase_k[pk][job.last_phase] or 0) + (now - job.phase_at)
        end
        job.phase_at, job.last_phase = now, job.phase
        local ph = job.phase
        local ok, res = pcall(step, api, job, now)
        if not ok then
            job.final, job.phase = api.fail("body_error", { detail = "build: " .. tostring(res) }), "leave"
            res = nil
            -- a batch keeps the error as that piece's result (live 08:0xZ: a nil 'cfg' in the success line was lost,
            -- and the blueprint read "Built 0 of 11 ... Not tried: #1" with the foundation standing)
            if job.batch and not job.batch.over and ph ~= "leave" then
                job.batch.results[job.batch.i], job.batch.done[job.batch.i], job.batch.over = job.final, true, true
            end
        end
        if res and job.batch and ph ~= "leave" then -- a piece of a batch failed outside leave_then: record it, then go on or leave
            if not job.batch.over and not job.stopped and res.ok == false and M.batch_next(api, job, res) then
                res = nil
            else
                if not job.batch.over then job.batch.results[job.batch.i], job.batch.done[job.batch.i], job.batch.over = res, true, true end
                job.final, job.phase, res = job.final or res, "leave", nil
            end
        end
        if res then release(res.ok and "done" or tostring(res.reason)) end
        if res then
            res.data = res.data or {}
            res.data.presses = job.presses
            local ps = {}
            for k, v in pairs(job.phase_s) do ps[k] = math.floor(v * 10 + 0.5) / 10 end
            res.data.phase_s = api.object and api.object(ps) or ps
            local pk = {}
            for k, row in pairs(job.phase_k or {}) do
                pk[k] = {}
                for ph, v in pairs(row) do pk[k][ph] = math.floor(v * 10 + 0.5) / 10 end
            end
            res.data.phase_by_piece = api.object and api.object(pk) or pk
            res.data.stay_log = job.stay_log
            res.data.verify_at_s = job.vt_log and (api.object and api.object(job.vt_log) or job.vt_log) or nil
        end
        return res
    end
    return { pending = a }
end

-- ------------------------------------------------------------------ get_state.structures (review finding 10)
-- Building pieces near him (stations, chests, campfires ... his and others'): census-radius limited, capped,
-- refreshed at most every cfg.structures_every_s (one find_all then), never per frame, never under pause.
-- `mine` is omitted (unverified which field carries the owner; review finding 20).
M.cfg.structures = { radius_m = 30, max = 15, every_s = 5 }
-- One built piece by its id, the way get_state.structures lists it (the GlobalBuildingManager census joined with
-- the pieces' actors): a thing for find_thing when the general census doesn't list it (live 18:57Z: his own crate
-- 13.7 m away, in structures, was "I can't see that chest anywhere near me"). class is set for a piece with an
-- actor (crate, station, door), so actor_of finds it. -> thing | nil
function M.find_structure(api, id, radius_m)
    if paused() or type(id) ~= "string" then return nil end
    local U = sense_U(api)
    local here = api.my_position()
    if not (U and here) then return nil end
    -- by its id now, or by an older name of the same piece (pid_of), or by its BuildingPiece_<pid>
    local pid = tonumber(id:match("^BuildingPiece_(%d+)$")) or (mem().pid_of or {})[id]
    for _, e in ipairs(W.built_pieces(api, here, radius_m or M.cfg.structures.radius_m) or {}) do
        if e.id == id or (pid and e.pid == pid) then
            local d = math.sqrt((e.position[1] - here[1]) ^ 2 + (e.position[2] - here[2]) ^ 2)
            return { id = e.id, name = e.name, piece = e.piece, position = e.position, distance = math.floor(d * 10 + 0.5) / 10,
                     class = e.actor and U.class_word(e.actor) or nil, category = "structures", pid = e.pid,
                     was = e.id ~= id and id or nil, kind = e.actor and "actor" or "piece", actions = { "go_to" } }
        end
    end
end
function W.structures(api, fresh)
    local m = mem()
    local cfg = M.cfg.structures
    local t = api.now()
    if not fresh and m.structs and m.structs_t and t - m.structs_t < cfg.every_s then return m.structs end
    if paused() then return m.structs or {} end
    local U = sense_U(api)
    local here = api.my_position()
    local out = {}
    local list = U and here and W.built_pieces(api, here, cfg.radius_m)
    if list then -- every piece, also the instance-only ones (foundations) that have no actor
        for _, e in ipairs(list) do
            local d = math.sqrt((e.position[1] - here[1]) ^ 2 + (e.position[2] - here[2]) ^ 2)
            out[#out + 1] = { id = e.id, name = e.name or (e.actor and text(U, U.prop(e.actor, "DisplayName"))) or ("building piece #" .. tostring(e.index)),
                              piece = e.piece, position = e.position, distance = math.floor(d * 10 + 0.5) / 10,
                              up_m = here[3] and math.floor((e.position[3] - (here[3] - 0.88)) * 10 + 0.5) / 10 or nil,
                              yaw = e.yaw, ghosted = e.ghosted }
        end
        table.sort(out, function(x, y) return x.distance < y.distance end)
        for i = #out, cfg.max + 1, -1 do out[i] = nil end
        -- each foundation's edges (open / a wall / the next foundation) and its ceiling, from the pieces' own sizes
        local rows = {}
        for _, e in ipairs(list) do
            local box = e.actor and box_of(U, U.try(function() return e.actor.BuildingPieceLocalBounds end))
            if not box and e.data then box = (W.piece_profile(api, e.data) or {}).box end
            if box then rows[#rows + 1] = { id = e.id, name = e.name, piece = e.piece, position = e.position, yaw = e.yaw, box = box } end
        end
        local ok, ed = pcall(M.edges, rows)
        if ok then
            for _, s in ipairs(out) do
                local x = ed[s.id]
                if x then s.edges, s.ceiling, s.inside = x.edges, x.ceiling, next(x.inside) and x.inside or nil end
            end
        end
        m.structs, m.structs_t = out, t
        return out
    end
    if U and here then
        for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
            if U.try(function() return a.bIsPreview end) ~= true then
                local at = U.loc(a)
                local d = at and math.sqrt((at.X / 100 - here[1]) ^ 2 + (at.Y / 100 - here[2]) ^ 2)
                if d and d <= cfg.radius_m then
                    local data = U.try(function() return a.BuildingPieceData end)
                    -- the piece's own name first (= buildables, = sense's interactable name); DisplayName has many
                    -- declarations: by-name reads on Blueprint actors via U.prop (R17)
                    out[#out + 1] = { id = U.short(a), name = (U.valid(data) and text(U, U.try(function() return data.DisplayName end)))
                                          or text(U, U.prop(a, "DisplayName")) or U.short(a),
                                      piece = asset(U, data), position = { at.X / 100, at.Y / 100, at.Z / 100 },
                                      distance = math.floor(d * 10 + 0.5) / 10,
                                      -- height above my feet (capsule half-height 0.88 m; my_position = capsule centre)
                                      up_m = here[3] and math.floor((at.Z / 100 - (here[3] - 0.88)) * 10 + 0.5) / 10 or nil,
                                      yaw = r1(tonumber((U.try(function() return a:K2_GetActorRotation().Yaw end))) or 0),
                                      ghosted = U.try(function() return a.bIsGhosted end) == true or nil }
                end
            end
        end
        table.sort(out, function(x, y) return x.distance < y.distance end)
        for i = #out, cfg.max + 1, -1 do out[i] = nil end
    end
    m.structs, m.structs_t = out, t
    return out
end
function M.state_extras(api)
    local ok, s = pcall(W.structures, api)
    if ok then return { structures = s } end
    return nil
end

-- ------------------------------------------------------------------ blueprints (CLAUDE.md phase 7: relative pieces)
-- data/blueprints/<id>.json: {id, name, about, door_side, pieces = {{key, piece, at | on = "<key>:<side>"}}}. The
-- first piece goes at the spot; every other one attaches to an earlier one by key, the sides as compass words for
-- the blueprint's own door_side. build_blueprint turns it (facing = the side the door faces) and runs it as one
-- `pieces` batch: the build screen stays open, each piece is placed by the verified attach primitives and checked
-- from the census, and a piece the game won't take is reported while the rest go on.
M.cfg.blueprints = { dir = ROOT .. "/data/blueprints", max = 40 }
local function json_lib() local m = mem(); m.json = m.json or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))(); return m.json end
local function read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local txt = f:read("a") or ""; f:close()
    local ok, d = pcall(function() return json_lib().decode(txt) end)
    return ok and type(d) == "table" and d or nil
end
-- What each blueprint costs, as the game's piece costs added up at its last run (costs.json beside the blueprints), so
-- the tool's description can say it before any run (rung 2 run 1, 05:0xZ: the planner had 61 Ash Logs, didn't know the
-- house costs 46, and gathered 40 more first: 191 s)
function M.blueprint_costs()
    local c = read_json(M.cfg.blueprints.dir .. "/costs.json")
    return type(c) == "table" and c or {}
end
function M.blueprint_note_cost(id, words)
    local c = M.blueprint_costs()
    if c[id] == words then return end
    c[id] = words
    local f = io.open(M.cfg.blueprints.dir .. "/costs.json", "wb")
    if f then f:write(json_lib().encode(c, { indent = true })); f:close() end
end
function M.blueprint_ids()
    local ix = read_json(M.cfg.blueprints.dir .. "/index.json")
    return type(ix) == "table" and type(ix.blueprints) == "table" and ix.blueprints or {}
end
function M.blueprint_load(id)
    id = tostring(id or ""):lower():gsub("[^%w_]", "_")
    local bp = id ~= "" and read_json(M.cfg.blueprints.dir .. "/" .. id .. ".json")
    if not (bp and type(bp.pieces) == "table" and #bp.pieces > 0) then
        return nil, "I have no blueprint called '" .. id .. "'; I know: " .. table.concat(M.blueprint_ids(), ", ") .. "."
    end
    return bp
end
local COMPASS, CIDX = { "N", "E", "S", "W" }, { N = 1, E = 2, S = 3, W = 4 }
-- The blueprint as a batch: "#k" refs, sides turned so its door faces `facing`, the first piece at `at`.
-- -> items | nil, why
function M.blueprint_items(bp, at, facing)
    local f = facing and CIDX[tostring(facing):upper():sub(1, 1)]
    local rot = f and ((f - (CIDX[bp.door_side or "N"] or 1)) % 4) or 0
    local index, items = {}, {}
    for k, p in ipairs(bp.pieces) do
        if type(p) ~= "table" or type(p.piece) ~= "string" then return nil, "blueprint piece #" .. k .. " has no piece" end
        index[p.key or ("#" .. k)] = k
        local it = { piece = p.piece, key = p.key }
        if p.on then
            local key, side = tostring(p.on):match("^([^:]+):?(.*)$")
            local r = index[key]
            if not r then return nil, "blueprint piece " .. tostring(p.key) .. " goes on '" .. tostring(key) .. "', which comes later or isn't in it" end
            local c = CIDX[side]
            it.on = "#" .. r .. (side ~= "" and (":" .. (c and COMPASS[(c - 1 + rot) % 4 + 1] or side)) or "")
        elseif type(at) == "table" then it.at = at
        elseif at == nil or at == "me" then it.near = "me"
        else it.at = at end
        items[k] = it
    end
    return items
end
-- What the whole blueprint costs, from buildables (the game's own costs) -> {item = {name, need}}, unknown ids
function M.blueprint_cost(ctx, items)
    local need, unknown, rows = {}, {}, {}
    for _, it in ipairs(items) do
        local row = rows[it.piece]
        if row == nil then
            local r = M.HANDLERS.buildables(nil, { about = it.piece, max = 5 }, ctx)
            row = false
            for _, p in ipairs(((r or {}).data or {}).pieces or {}) do if p.id == it.piece then row = p end end
            rows[it.piece] = row
        end
        if row then
            it.name = row.name
            for _, c in ipairs(row.cost or {}) do
                local n = need[c.item] or { name = c.name, need = 0 }
                n.need = n.need + (tonumber(c.count) or 0)
                need[c.item] = n
            end
        else unknown[#unknown + 1] = it.piece end
    end
    return need, unknown
end
M.HANDLERS.build_blueprint = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    args = args or {}
    local bp, why = M.blueprint_load(args.blueprint)
    if not bp then return api.fail("invalid_args", { detail = why, blueprints = M.blueprint_ids() }) end
    local items, bad = M.blueprint_items(bp, args.at, args.facing)
    if not items then return api.fail("invalid_args", { detail = bad }) end
    local need, unknown = M.blueprint_cost(ctx, items)
    if #unknown > 0 then
        return api.fail("missing_materials", { blueprint = bp.id, why = "not_unlocked",
            detail = "I can't build the " .. bp.name .. " yet: " .. table.concat(unknown, ", ") .. " isn't among the pieces I can build." })
    end
    local have, short, total = api.counts() or {}, {}, {}
    for item, n in pairs(need) do
        total[#total + 1] = n.need .. " " .. tostring(n.name)
        local h = tonumber(have[item]) or 0
        if h < n.need then short[#short + 1] = { item = item, name = n.name, need = n.need, have = h } end
    end
    table.sort(total)
    pcall(M.blueprint_note_cost, bp.id, table.concat(total, ", "))
    if #short > 0 then
        local w = {}
        for _, m in ipairs(short) do w[#w + 1] = string.format("%d %s (I have %d)", m.need, tostring(m.name), m.have) end
        return api.fail("missing_materials", { blueprint = bp.id, missing = short,
            detail = "The " .. bp.name .. " (" .. #items .. " pieces) needs " .. table.concat(w, ", ") .. ". Nothing was placed." })
    end
    ctx.batch_opts = { max = M.cfg.blueprints.max, keep_going = true }
    local r = M.HANDLERS.build(log, { pieces = items }, ctx)
    ctx.batch_opts = nil
    -- the batch's reply, headed by the blueprint and what it costs
    local head = "Blueprint " .. bp.name .. " (" .. #items .. " pieces, " .. table.concat(total, ", ") .. "): "
    local function wrap(res)
        if type(res) == "table" and type(res.data) == "table" then
            if res.data.built then res.data.built = head .. res.data.built end
            if res.data.detail then res.data.detail = head .. res.data.detail end
            res.data.blueprint = bp.id
        end
        return res
    end
    if type(r) == "table" and r.pending then
        local a = r.pending
        local poll0 = a.poll
        a.kind = "build_blueprint"
        a.timeout_s = M.cfg.build.timeout_s * #items
        a.poll = function(self, ...)
            local res = poll0(self, ...)
            if res then return wrap(res) end
            return res
        end
        return r
    end
    return wrap(r)
end

-- ------------------------------------------------------------------ manifest (client_mod/scripts/manifest.lua shape)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    buildables = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 15,
        description = "Pieces you can build (unlocked): name, category, material cost and what you're still missing. Read-only.",
        args = { type = "object", properties = obj({
            about = { type = "string", description = "Words for what to build; several things in one ask work (e.g. foundation wall roof door chest workbench). Each word gets its best pieces in the list, and by_word names them per word (a word with none has no piece)." },
            can_build_now = { type = "boolean", default = false, description = "Only pieces you have the materials for." },
            max = { type = "integer", minimum = 1, maximum = 60, default = 25, description = "At most this many pieces." } }) },
        reasons = { "state_unavailable" } },
    -- offered to the model after live P5 (2026-10-26, a Campfire built and verified on dev)
    build = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 12, timeout_s = 120,
        detail_is_speech = true,
        description = "Build a piece by its name from buildables (you need its materials), or several with pieces. Walks "
            .. "near the spot (stays put when it is in reach), tries preview spots until one is valid, places it once and "
            .. "checks it was built. ok: 'built' says what stands where (metres and compass from you, facing, its "
            .. "structures id); rejected_previews_before_placing are not failures. With on, it only places once the preview "
            .. "snaps onto that piece and says whether it sits flush (gap, level, facing). Not ok: detail says why, and no "
            .. "new piece was found standing there. Trains Construction.",
        args = { type = "object", properties = obj({
            piece = { type = "string", description = "The piece's name or id from buildables (words of its name are enough when only one piece has them all)." },
            at = { description = "Exactly here: [x, y, z] metres or an id." },
            near = { type = "string", description = "Somewhere next to this id: 'me' is beside you wherever this step finds you (a gather or walk before it may have taken you away from your house); a built piece's id (your house's foundation) puts it by that piece." },
            on = { type = "string", description = "Attach to a built piece: its structures id, optionally ':N', ':E', ':S', ':W', ':top' or ':in' (no side: the free side nearest you). What holds what: a wall or door-frame wall stands on a foundation's edge (':N' = its north edge); ':in' puts a door into a door-frame wall; a ceiling tile or roof snaps onto a wall's top, and on '<wall id>:<side>' it reaches out over that side (the side the room is on); ':top' sets it on the piece's top face." },
            rotation = { type = "number", minimum = 0, maximum = 360, description = "Turn it this many degrees (15 degree steps)." },
            pieces = { type = "array", maxItems = 12, items = { type = "object" }, description = "Several in one go, the build "
                .. "screen kept open: a list of {piece, on, rotation}. on may name an earlier item as '#k' ('#1:N' = the N edge "
                .. "of what item 1 built). I go in the order that keeps walking short; a piece that fails is reported and the rest still go up (only what stands on it is left untried)." } }) },
        reasons = { "no_permission", "host_only", "unknown_target", "ambiguous_target", "missing_materials", "blocked", "invalid_args",
                    "limit_reached", "too_far", "path_blocked", "interrupted", "verification_failed", "timeout" } },
}
-- build_blueprint's description names the blueprints on disk (data, not code: a new house is a new json file)
do
    local known = {}
    local okb = pcall(function()
        for _, id in ipairs(M.blueprint_ids()) do
            local bp = M.blueprint_load(id)
            local cost = M.blueprint_costs()[id]
            if bp then known[#known + 1] = "'" .. bp.id .. "': " .. tostring(bp.name) .. ", " .. #bp.pieces .. " pieces"
                .. (cost and (", costs " .. cost .. " in all (the game's piece costs, read at its last build)") or "")
                .. ", door on its " .. tostring(bp.door_side) .. " side. " .. tostring(bp.about or "") end
        end
    end)
    -- not offered to the model (Luis, 2026-11-15: no canned house; he designs it himself from buildables + build).
    -- Still callable over the debug channel (tools/build_run.py stand-ins).
    M.MANIFEST.build_blueprint = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 120, timeout_s = 2400,
        detail_is_speech = true,
        description = "Build a whole saved blueprint, piece by piece, the build screen kept open: its first foundation at the spot, "
            .. "then each piece on the one before it the way the blueprint says (foundations, walls on their edges, the door in "
            .. "its frame, roofs on the walls' tops). Needs all its materials first (not ok missing_materials says how many). "
            .. "Each piece is checked from the census; a piece the game won't take is reported and the rest go on. ok: every "
            .. "piece built; not ok: what was built, what failed and why, and what was not tried. Blueprints: "
            .. (okb and #known > 0 and table.concat(known, " | ") or "(none readable)"),
        args = { type = "object", properties = obj({
            blueprint = { type = "string", description = "The blueprint's id." },
            at = { description = "Where its first foundation goes: [x, y, z] metres, an id, or 'me' (beside where you stand NOW, the default). "
                .. "A request that said 'here' meant where you stood when asked: that is the Asked line's (x, y, z), so pass those numbers; 'me' after walking off to gather is somewhere else." },
            facing = { type = "string", enum = { "N", "E", "S", "W" }, description = "The side its door faces (default: the blueprint's own)." } }),
            required = { "blueprint" } },
        reasons = { "no_permission", "host_only", "unknown_target", "missing_materials", "blocked", "invalid_args", "too_far",
                    "path_blocked", "interrupted", "verification_failed", "timeout" } }
end

-- ground_check {at = [x, y, z], half_m = [hx, hy], step_m} (debug; the rung 2 harness): the ground under a rectangle
-- by line traces, as P.spots reads a footprint -> {spread_m, lo, hi, n, missed}. Live 2026-11-02: the walked-points
-- check passed two slopes where a stand-in foundation then rose 2 m / a wall stood 3 m low.
M.HANDLERS.ground_check = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if type(args.structure) == "string" then -- the ground round a standing piece, as its build reply words it
        local okr, rows = pcall(W.structures, api, true)
        for _, st in ipairs(okr and type(rows) == "table" and rows or {}) do
            if st.id == args.structure then
                local okg, g = pcall(W.ground_round, api, st)
                return { ok = okg and g ~= nil, reason = (not (okg and g)) and "state_unavailable" or nil,
                         data = okg and g or { detail = tostring(g), box = st.box or api.null, yaw = st.yaw or api.null, position = st.position } }
            end
        end
        return api.fail("unknown_target", { detail = "no such structure in my census" })
    end
    local at = type(args.at) == "table" and args.at or api.my_position()
    if not (at and at[1]) then return api.fail("invalid_args", { detail = "at = [x, y, z]" }) end
    local h = type(args.half_m) == "table" and args.half_m or { 4, 4 }
    local step = math.max(0.5, tonumber(args.step_m) or 1.5)
    local z0 = tonumber(at[3]) or (api.my_position() or { 0, 0, 0 })[3]
    local lo, hi, n, missed = math.huge, -math.huge, 0, 0
    for x = -h[1], h[1] + 1e-6, step do
        for y = -h[2], h[2] + 1e-6, step do
            local z = W.ground_at(api, at[1] + x, at[2] + y, z0 + 2)
            if z then lo, hi, n = math.min(lo, z), math.max(hi, z), n + 1 else missed = missed + 1 end
        end
    end
    if n == 0 then return api.fail("state_unavailable", { detail = "no trace hit the ground there", missed = missed }) end
    return { ok = true, data = { spread_m = r1(hi - lo), lo = r1(lo), hi = r1(hi), n = n, missed = missed } }
end
M.MANIFEST.ground_check = { kind = "probe", llm = false, moves = false, timeout_s = 10,
    description = "Ground heights under a rectangle (debug).", args = { type = "object", properties = obj() } }

return M
