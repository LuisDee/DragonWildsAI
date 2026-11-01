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

M.cfg = { max = 25, max_cap = 60 }

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
M.STATIC_V = 1 -- bump when describe() changes shape (cached static data is per session)

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
            if (not about or p._score > 0) and (args.can_build_now ~= true or p.can_build_now) then rows[#rows + 1] = p end
        end
    end
    table.sort(rows, function(a, b)
        if a._score ~= b._score then return a._score > b._score end
        if a.can_build_now ~= b.can_build_now then return a.can_build_now end
        return lower(a.name) < lower(b.name)
    end)
    local max = math.max(1, math.min(tonumber(args.max) or M.cfg.max, M.cfg.max_cap))
    local out = {}
    for i = 1, math.min(#rows, max) do
        local p = rows[i]
        p._score = nil
        if #p.missing == 0 then p.missing = nil end
        out[#out + 1] = p
    end
    local data = { unlocked = #list, matched = #rows, shown = #out, pieces = out, about = about or api.null,
                   truncated = #rows > #out, may_build = can_build == nil and api.null or can_build }
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
    -- after the game confirms the build (telemetry / XP + spend), look this long for the new piece in the world
    -- (an actor of this piece within find_m of the preview that wasn't there before the press), so the reply can
    -- say where it stands (co-play 2026-11-01: structure was always null, the crate read as a failure)
    find_s = 2.5, find_m = 3.0, before_m = 10.0,
    -- on = "<piece id>:<side>": attach flush to a built piece (research 2026-11-01 §4.2). Aim snap_aim_m OUTSIDE the
    -- flush spot: the game's magnet (SnappingRadius 80 cm, 200 cm in Basic mode, live probe) pulls a snapping ghost
    -- onto it, a free one stays where I aimed. So "colour 2 AND the ghost sits on the flush spot (snap_tol_m)" is the
    -- positive snap signal colour 2 alone can't give (Valid vs NeedsSnapping). flush_tol_m: the census check after.
    snap_aim_m = 0.25, snap_tol_m = 0.06, snap_tol_z_m = 0.12, flush_tol_m = 0.06, stand_extra_m = 1.5, taken_m = 0.5,
    preview_waits = 6, edge_aim_m = 0.3,
    -- no preview actor (instance-only pieces): the cursor must stop gliding (settle_m between reads) within
    -- cursor_tol_m of the flush spot; up to cursor_checks reads per aim (live: ~1 m/s glide, reads every 0.35 s)
    settle_m = 0.03, cursor_tol_m = 0.2, cursor_tol_z_m = 0.25, cursor_checks = 14, corr_max_m = 2.0, edge_in_m = 0.3,
    snap_jump_m = 0.3, snap_jump_tol_m = 0.15, -- the cursor jumped from my aim onto the flush spot = a seen snap
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
    preview_red = "the preview was red there (something in the way, not on solid ground, unstable or needs a foundation)",
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
function W.camera(api)
    local U = sense_U(api)
    local pc = W.pc(api)
    local v = pc and U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end
end
function W.aim(api, pos)
    local U = sense_U(api)
    local pc = W.pc(api)
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
-- A wall-like piece: its box is thin on one horizontal axis (live: Wall 303 x 100 cm, extent 151.5 x 50) ->
-- that axis' index (1 = local X, 2 = local Y) | nil (a tile, a prop)
function M.thin_axis(box)
    if not box then return nil end
    local ex, ey = box.extent[1], box.extent[2]
    if ey <= 0.4 * ex then return 2 end
    if ex <= 0.4 * ey then return 1 end
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
        return { p[1], p[2], top - (nb.origin[3] - nb.extent[3]) }, nil
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
        if nb.extent[3] >= 0.5 then -- a roof (tall, sloped): it sits ON the wall top, its bottom on it
            return { p[1] + axis[1] * half, p[2] + axis[2] * half, top - (nb.origin[3] - nb.extent[3]) }, axis,
                { ceiling = true, roof = true, yaw = (anchor.yaw or 0) % 360, per = 90 }
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
-- What stands on each edge of a floor piece (a foundation) and over it, from the census: the perception a house
-- needs (which edges still want a wall, which cells have a ceiling). rows: {id, name, position, yaw, box}.
-- -> { [floor id] = { edges = {N = "open" | "<name> <id>" | "beside: <name> <id>", ...}, ceiling = "<name> <id>" } }
function M.edges(rows)
    local out = {}
    local function hd(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
    for _, f in ipairs(rows) do
        local fb = f.box
        if fb and f.position and not M.thin_axis(fb) and fb.extent[3] >= 0.75 then
            local p = f.position
            local top = p[3] + fb.origin[3] + fb.extent[3]
            local e = { edges = {} }
            for _, side in ipairs({ "N", "E", "S", "W" }) do
                local axis, i = side_axis(f, side)
                local h = fb.extent[i]
                local edge = { p[1] + axis[1] * h, p[2] + axis[2] * h }
                local next_to = { p[1] + axis[1] * 2 * h, p[2] + axis[2] * 2 * h }
                local on, beside
                for _, g in ipairs(rows) do
                    if g ~= f and g.position and g.box then
                        local q = g.position
                        local gbot = q[3] + g.box.origin[3] - g.box.extent[3]
                        if M.thin_axis(g.box) and hd(q, edge) <= 0.5 and math.abs(gbot - top) <= 0.6 then
                            on = tostring(g.name) .. " " .. g.id
                        elseif not M.thin_axis(g.box) and hd(q, next_to) <= 0.5 and math.abs(q[3] - p[3]) <= 0.6 then
                            beside = "beside: " .. tostring(g.name) .. " " .. g.id
                        end
                    end
                end
                e.edges[side] = on or beside or "open"
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
function M.resolve(api, list, q)
    q = lower(q)
    local exact, typo, close = {}, {}, {}
    for _, d in ipairs(list) do
        local p = M.describe(api, d)
        local n, id = lower(p.name), lower(p.id)
        if n == q or id == q then exact[#exact + 1] = { d = d, p = p }
        else
            local dist = math.min(lev(n, q), lev(id, q))
            if dist <= math.max(1, math.floor(#q / 6)) then typo[#typo + 1] = { d = d, p = p } end
            if n:find(q, 1, true) or q:find(n, 1, true) then close[#close + 1] = p.name end
        end
    end
    if #exact == 1 then return exact[1].d, exact[1].p end
    if #exact > 1 then return nil, nil, "ambiguous_target", exact end
    if #typo == 1 then return typo[1].d, typo[1].p end
    if #typo > 1 then return nil, nil, "ambiguous_target", typo end
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
    local data, piece, code, more = M.resolve(api, list, args.piece)
    if not data then
        if code == "ambiguous_target" then
            local names = {}
            for _, x in ipairs(more) do names[#names + 1] = x.p.name end
            return api.fail("ambiguous_target", { piece = args.piece, candidates = names,
                detail = "Which one: " .. table.concat(names, ", ") .. "?" })
        end
        return api.fail("unknown_target", { piece = args.piece, close = more,
            detail = "I can't build a " .. args.piece .. " (it isn't one of the pieces I've unlocked)." })
    end
    if piece.host_only and priv("owner") ~= true then
        return api.fail("host_only", { piece = piece.id, detail = "Only the host can build the " .. piece.name .. "." })
    end
    local counts, storage = {}, {}
    for k, v in pairs(api.counts() or {}) do counts[k] = v end -- a snapshot (the spend check compares against it)
    for k, v in pairs((W.storage_counts(api, 15))) do storage[k] = v end
    local missing = M.missing(piece, counts, storage)
    -- target
    local here = api.my_position()
    if not here then return api.fail("companion_down", { detail = "no position" }) end
    local center, exact = nil, false
    local function pos_of(v)
        if type(v) == "table" and type(v[1]) == "number" then return { v[1], v[2], v[3] or here[3] } end
        if need_str(v) then
            if v == "me" then return here end
            local t = api.find_thing(v)
            return t and t.position or nil
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
        local function taken(s)
            local p = M.flush_spot(anchor, s, box0)
            for _, st in ipairs(W.structures(api, true) or {}) do
                if st.id ~= anchor.id and st.position and math.sqrt((st.position[1] - p[1]) ^ 2 + (st.position[2] - p[2]) ^ 2) <= cfg.taken_m
                    and math.abs(st.position[3] - p[3]) <= 1.0 then return st end
            end
        end
        if side then
            local t = taken(side)
            if t then
                return api.fail("blocked", { on = args.on, why = "side_taken", taken_by = t.id,
                    detail = "The " .. side .. " side of the " .. anchor.name .. " already has a " .. tostring(t.name) .. " (" .. t.id .. ")." })
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
        on = { anchor = anchor, side = side, box = box0, provisional = provisional }
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
    local short = false
    for _, x in ipairs(missing) do if (x.have + (x.in_storage or 0)) < x.need then short = true end end
    local job = { kind = "build", piece = piece, data = data, phase = "approach", missing = missing, center = center, exact = exact,
                  short_materials = short, on = on, footprint = footprint,
                  standoff = standoff, presses = {}, spent = {}, counts0 = counts, storage0 = storage, opens = 0, leaves = 0 }
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
                local prev = job.on.prev_cursor
                local moved = prev and math.sqrt((m.position[1] - prev[1]) ^ 2 + (m.position[2] - prev[2]) ^ 2) or math.huge
                job.on.prev_cursor = m.position
                if moved > cfg.settle_m then return { valid = false, why = "settling", position = at, fresh = fresh } end
                -- where the cursor must sit: the flush spot for a tile; for a wall the point just inside the edge on the
                -- anchor's top (its z too: a cursor on the side face below would snap it to the bottom edge)
                local ct = job.on.cursor_target or tg
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
                local c = job.on.corr or { 0, 0 }
                c = { c[1] + (ct[1] - at[1]), c[2] + (ct[2] - at[2]) }
                local cl = math.sqrt(c[1] ^ 2 + c[2] ^ 2)
                if cl > cfg.corr_max_m then c = { c[1] / cl * cfg.corr_max_m, c[2] / cl * cfg.corr_max_m } end
                job.on.corr, job.on.prev_cursor = c, nil
            elseif green and off <= cfg.snap_tol_m and dz <= cfg.snap_tol_z_m then
                return { valid = true, snapped = true, position = at, fresh = fresh, colour = 2 }
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
    if s then
        line = line .. ": it stands " .. rel .. " at " .. where .. (facing and (", facing " .. facing) or "") .. " (" .. s.id .. ")."
    else
        line = line .. " (" .. (EVIDENCE_WORDS[evidence] or tostring(evidence)) .. "), but I can't see it in the world yet: it should be "
            .. rel .. " at " .. where .. ", where its preview was."
    end
    if not spent_all then line = line .. " My materials didn't visibly go down, so I can't say what it used." end
    -- attached: how it really sits against the anchor, measured from the census (not from the preview)
    local att
    if job.on then
        local a, side = job.on.anchor, job.on.side
        local _, _, mount = M.flush_spot(a, side, job.on.box)
        local ceil = mount and mount.ceiling
        local where_on = (side == "top" and "on top of the " or (ceil and "on top of the ")
            or ("on the " .. side .. (mount and " edge of the " or " side of the "))) .. tostring(a.name) .. " (" .. a.id .. ")"
            .. (ceil and (", reaching " .. side) or "")
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
                    ceil and (att.gap_m > 0 and "gap from the wall" or "over the wall")
                    or mount and (att.gap_m > 0 and "outside the edge" or "in from the edge") or (att.gap_m > 0 and "gap" or "overlap"))
            end
            if math.abs(att.offset_m) > M.cfg.build.flush_tol_m then parts[#parts + 1] = string.format("%.2f m off to the side", math.abs(att.offset_m)) end
            if math.abs(att.level_m) > M.cfg.build.flush_tol_m then parts[#parts + 1] = string.format("%.2f m %s", math.abs(att.level_m), att.level_m > 0 and "higher" or "lower") end
            if math.abs(att.facing_off_deg) > 2 then parts[#parts + 1] = string.format("turned %.0f degrees", att.facing_off_deg) end
            line = line .. (att.flush and (ceil and (" It sits squarely " .. where_on .. (mount.roof and ": on the wall's top, lined up with it."
                        or ": its edge on the wall's line, its top level with the wall's top, lined up with it."))
                    or mount and (" It stands squarely " .. where_on .. ": on the edge line, on its top, lined up with it.")
                    or (" It sits flush " .. where_on .. ": no gap, level, same facing."))
                or (" It is NOT " .. (mount and "square " or "flush ") .. where_on .. ": " .. table.concat(parts, ", ") .. "."))
        else
            line = line .. " I meant it to sit flush " .. where_on .. " but can't measure it until I can see it."
        end
    end
    local rej = {}
    for _, r in ipairs(job.rejects or {}) do
        rej[#rej + 1] = { spot = r.spot, why = r.why, preview_at = r.preview_at, off_m = r.off_m }
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
        rejected_previews_before_placing = #rej > 0 and rej or nil }, RESULT_MT) }
end
M._success = success

local function step(api, job, t)
    local cfg = M.cfg.build
    local i = IN(api)
    local function leave_then(res)
        job.final = job.final or res
        job.phase = "leave"
        return nil
    end
    if job.phase == "approach" then
        local here = api.my_position()
        local d = here and math.sqrt((here[1] - job.center[1]) ^ 2 + (here[2] - job.center[2]) ^ 2)
        -- attaching: stand OUTSIDE the flush spot, on the far side from the anchor, so the camera ray to the aim
        -- point never crosses the anchor piece (a side) / beside the anchor (top)
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
                axis, out_m = n, 1.0 + cfg.stand_extra_m + 1.0
            end
            job.stand_at = axis and { job.center[1] + axis[1] * out_m, job.center[2] + axis[2] * out_m, job.center[3] }
                or stand_point(here or job.center, job.center, out_m)
        end
        local ds = job.stand_at and here and math.sqrt((here[1] - job.stand_at[1]) ^ 2 + (here[2] - job.stand_at[2]) ^ 2)
        if (job.stand_at and ds and ds <= 1.2) or (not job.stand_at and d and d >= job.standoff - 0.6 and d <= cfg.reach_m - 1.5) then
            job.phase = "open"; return nil
        end
        if not job.moving then
            if (job.approaches or 0) >= 2 then
                if job.stand_at and d and d <= cfg.reach_m - 1.5 and d >= 1.5 then job.phase = "open"; return nil end -- close enough to try
                return api.fail("too_far", { piece = job.piece.id, distance = d, detail = "I can't get to a spot to build the " .. job.piece.name .. " from." })
            end
            local goal = job.stand_at or stand_point(here or job.center, job.center, job.standoff + 0.5)
            local mr = api.call("move", "go_to", goal, { tolerance_m = 0.8, timeout_s = 60, allow_unstuck = false, owner_token = job.token })
            if not mr.ok then return mr end
            job.moving, job.approaches = true, (job.approaches or 0) + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        job.moving = false
        local res = type(st.result) == "table" and st.result or {}
        if res.status ~= "arrived" and res.status ~= "stopped" then
            local sk = api.module("skills")
            local words = sk and sk.why_words and sk.why_words(res.reason) or "I can't find a way there"
            return api.fail(api.reason_code(res.reason or "path_blocked") == "body_error" and "path_blocked" or api.reason_code(res.reason or "path_blocked"),
                { piece = job.piece.id, why = res.reason, detail = "I can't get to where the " .. job.piece.name .. " should go: " .. words .. "." })
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
                local c = job.on and job.on.mode == "cursor" and job.on.corr
                if c then p = { p[1] + c[1], p[2] + c[2], p[3] } end
                job.aim_seq, job.last_aim = W.hook_seq(), p
                return W.aim(api, p)
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
        if job.on and not pa and (job.pa_waits or 0) < cfg.preview_waits then -- attaching: give a preview actor time to spawn
            job.pa_waits = (job.pa_waits or 0) + 1
            return nil
        end
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
            if pa and job.on.side ~= "in" then
                for _, k in ipairs({ 1, 2 }) do
                    local o = cfg.snap_aim_m * k
                    add({ spot[1] + out[1] * o, spot[2] + out[2] * o, spot[3] }, 2 * cfg.snap_aim_m + 0.5)
                end
            end
        else
            spots, skipped = P.spots(env, job.center, { footprint_m = job.footprint, standoff_m = math.max(0.8, job.footprint / 2 + 0.3),
                                                        around_m = job.exact and { 1.0 } or { 1.5, 3.0 }, around_n = 8 })
            if job.exact and spots[1] and not spots[1].exact then table.insert(spots, 1, { position = job.center, exact = true }) end
            if #spots == 0 then spots = { { position = job.center, exact = true } } end
        end
        job.skipped = skipped
        local checks = (job.on and job.on.mode == "cursor" and cfg.cursor_checks) or (job.on and 4) or 3
        job.checker = P.checker(env, spots, { match_m = function(sp) return sp.match_m or cfg.match_m end, checks = checks,
                                              budget_s = cfg.budget_s, compare = "2d" })
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
            end
            if reason == "missing_materials" then d.missing = job.missing end
            return leave_then(api.fail(reason, d))
        end
        if r.press then
            job.spot, job.preview = r.spot, r.preview
            job.rejects = r.rejects
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
            job.phase, job.verify_until, job.next_actor_check = "verify", t + cfg.verify_s, t + 0.5
        end
        return nil
    elseif job.phase == "verify" then
        local rf = W.hook("refused")
        if rf and rf.seq > job.refused0 then
            local texts = W.texts(api)
            local reason = M.STATE_REASON[rf.v] or "blocked"
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
            if now < before then spent[c.item] = before - now else all_fell = false end
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
            job.next_actor_check = t + 0.5
            job.structure = W.new_structure(api, job)
        end
        if not evidence and job.structure then evidence = "actor" end
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
    local job = start_build(api, args, ctx)
    if job.ok == false then return job end
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
    local a = { kind = "build", id = ctx.id, timeout_s = M.cfg.build.timeout_s }
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
        local ok, res = pcall(step, api, job, W.clock(api))
        if not ok then
            job.final, job.phase = api.fail("body_error", { detail = "build: " .. tostring(res) }), "leave"
            res = nil
        end
        if res then release(res.ok and "done" or tostring(res.reason)) end
        if res then res.data = res.data or {}; res.data.presses = job.presses end
        return res
    end
    return { pending = a }
end

-- ------------------------------------------------------------------ get_state.structures (review finding 10)
-- Building pieces near him (stations, chests, campfires ... his and others'): census-radius limited, capped,
-- refreshed at most every cfg.structures_every_s (one find_all then), never per frame, never under pause.
-- `mine` is omitted (unverified which field carries the owner; review finding 20).
M.cfg.structures = { radius_m = 30, max = 15, every_s = 5 }
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
            if box then rows[#rows + 1] = { id = e.id, name = e.name, position = e.position, yaw = e.yaw, box = box } end
        end
        local ok, ed = pcall(M.edges, rows)
        if ok then
            for _, s in ipairs(out) do
                local x = ed[s.id]
                if x then s.edges, s.ceiling = x.edges, x.ceiling end
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

-- ------------------------------------------------------------------ manifest (client_mod/scripts/manifest.lua shape)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    buildables = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 15,
        description = "Pieces you can build (unlocked): name, category, material cost and what you're still missing. Read-only.",
        args = { type = "object", properties = obj({
            about = { type = "string", description = "Words for what to build (e.g. chest, workbench, wall); ranks matches first." },
            can_build_now = { type = "boolean", default = false, description = "Only pieces you have the materials for." },
            max = { type = "integer", minimum = 1, maximum = 60, default = 25, description = "At most this many pieces." } }) },
        reasons = { "state_unavailable" } },
    -- offered to the model after live P5 (2026-10-26, a Campfire built and verified on dev)
    build = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 12, timeout_s = 120,
        detail_is_speech = true,
        description = "Build one piece by its name from buildables (you need its materials). Walks near the spot, tries "
            .. "preview spots until the game shows one valid, places it once and checks it was built. ok: the reply's "
            .. "'built' line says what stands where (metres and compass from you, facing, its structures id); spots "
            .. "rejected before that are listed under rejected_previews_before_placing and are not failures. With on, it "
            .. "only places once the preview snaps onto that piece and says whether it sits flush (gap, level, facing). Not ok: "
            .. "detail says why, and no new piece was found standing there. Trains Construction.",
        args = { type = "object", required = { "piece" }, properties = obj({
            piece = { type = "string", description = "The piece's name or id from buildables." },
            at = { description = "Exactly here: [x, y, z] metres or an id." },
            near = { type = "string", description = "Somewhere next to this id ('me' for beside you)." },
            on = { type = "string", description = "Attach to a built piece: its structures id, optionally ':N', ':E', ':S', ':W' or ':top' (no side: the free side nearest you). A wall goes on a foundation's edge; ':in' puts a door into a door-frame wall; a tile or roof on a wall reaches out to that side off its top." },
            rotation = { type = "number", minimum = 0, maximum = 360, description = "Turn it this many degrees (15 degree steps)." } }) },
        reasons = { "no_permission", "host_only", "unknown_target", "ambiguous_target", "missing_materials", "blocked",
                    "limit_reached", "too_far", "path_blocked", "interrupted", "verification_failed", "timeout" } },
}

return M
