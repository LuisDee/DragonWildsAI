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
-- Building actors of this piece within r metres of pos (one find_all per call; called at most once per second).
function W.structures_near(api, piece_id, pos, r)
    local U = sense_U(api)
    local out = {}
    if paused() or not pos then return out end
    for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
        local d = U.try(function() return a.BuildingPieceData end)
        if asset(U, d) == piece_id and U.try(function() return a.bIsPreview end) ~= true then
            local at = U.loc(a)
            if at and math.sqrt((at.X / 100 - pos[1]) ^ 2 + (at.Y / 100 - pos[2]) ^ 2) <= r then
                out[#out + 1] = { id = U.short(a), position = { at.X / 100, at.Y / 100, at.Z / 100 } }
            end
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
    local footprint = cfg.footprint_m
    local standoff = math.max(cfg.standoff_m, footprint + 1.0)
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
                  short_materials = short,
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
        if not h then
            if m.index == 2 then
                if M.cfg.build.hook_required then return { valid = nil, position = m.position } end -- no exact state: unreadable
                -- known limit: a snap piece's colour 2 may be NeedsSnapping, and no positive snap signal is known
                -- yet, so never press for one (main, 2026-10-26)
                if job.snap then return { valid = false, why = "preview_ambiguous", position = m.position, fresh = true } end
                return { valid = true, position = m.position, fresh = true, colour = 2 }
            end
            -- not green: name the likeliest game reason we can know without the exact state
            local why = (job.short_materials and "MissingMaterials") or ("not_valid (colour " .. tostring(m.index) .. ")")
            return { valid = false, why = why, position = m.position, fresh = true }
        end
        local fresh = h.seq > (job.aim_seq or 0)
        local valid = h.v == 0 and m.index == 2
        return { valid = valid, why = (not valid) and (M.STATES[h.v] or tostring(h.v)) or nil, state = h.v,
                 position = m.position, fresh = fresh }
    end
end

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
        if d and d >= job.standoff - 0.6 and d <= cfg.reach_m - 1.5 then job.phase = "open"; return nil end
        if not job.moving then
            if (job.approaches or 0) >= 2 then
                return api.fail("too_far", { piece = job.piece.id, distance = d, detail = "I can't get to a spot to build the " .. job.piece.name .. " from." })
            end
            local mr = api.call("move", "go_to", stand_point(here or job.center, job.center, job.standoff + 0.5), { tolerance_m = 0.8, timeout_s = 60, allow_unstuck = false })
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
        job.rot_left = job.rot_left or (job.rotation and math.floor(((job.rotation % 360) / cfg.rotate_step_deg) + 0.5) or 0)
        if job.rot_left > 0 then
            job.rot_left = job.rot_left - 1
            job.presses[#job.presses + 1] = "rotate"
            W.press(api, W.rotate_action(api))
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
            aim = function(p) job.aim_seq = W.hook_seq(); return W.aim(api, p) end,
            read = preview_reader(api, job),
        }
        job.env = env
        local pa = W.preview_actor(api, job)
        job.snap = (pa and W.snap_only(api, pa)) ~= false -- unknown counts as snap (never press blind)
        local spots, skipped = P.spots(env, job.center, { footprint_m = M.cfg.build.footprint_m, standoff_m = 0.8,
                                                          around_m = job.exact and { 1.0 } or { 1.5, 3.0 }, around_n = 8 })
        if job.exact and spots[1] and not spots[1].exact then table.insert(spots, 1, { position = job.center, exact = true }) end
        if #spots == 0 then spots = { { position = job.center, exact = true } } end
        job.skipped = skipped
        job.checker = P.checker(env, spots, { match_m = cfg.match_m, checks = 3, budget_s = cfg.budget_s, compare = "2d" })
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
                return leave_then(api.fail("verification_failed", { why = "preview_ambiguous", piece = job.piece.id,
                    detail = "I can't tell whether the " .. job.piece.name .. " would snap into place there, so I didn't place it." }))
            end
            if r.why == "preview_unreadable" then
                return leave_then(api.fail("verification_failed", { why = "preview_unreadable", piece = job.piece.id,
                    detail = "I can't see the building preview, so I didn't place anything." }))
            end
            local words = (code == 11 and job.piece.shelter_text) or (code and texts[code]) or "the game wouldn't let me place it"
            local d = { piece = job.piece.id, why = common, tried = r.rejects, skipped = job.skipped,
                        detail = (#r.rejects > 1 and "Every spot I tried here: " or "I can't put the " .. job.piece.name .. " there: ") .. tostring(words) }
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
            job.presses[#job.presses + 1] = "place"
            W.press(api, pa)
            job.phase, job.verify_until, job.next_actor_check = "verify", t + cfg.verify_s, t + 1
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
        if not evidence and t >= job.next_actor_check then
            job.next_actor_check = t + 1
            local near = W.structures_near(api, job.piece.id, job.preview and job.preview.position or job.spot.position, 3)
            if #near > 0 then evidence, job.structure = "actor", near[1] end
        end
        if all_fell and evidence then
            return leave_then({ ok = true, data = { piece = job.piece.id, name = job.piece.name, structure = job.structure and job.structure.id or api.null,
                position = job.preview and job.preview.position or job.spot.position, spent = api.object(spent), evidence = evidence,
                xp = (job.xp0 and xp) and (xp - job.xp0) or api.null, rotation_verified = false,
                tried = job.rejects and #job.rejects > 0 and job.rejects or nil } })
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
    job.rotation = tonumber(args.rotation)
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
function W.structures(api)
    local m = mem()
    local cfg = M.cfg.structures
    local t = api.now()
    if m.structs and m.structs_t and t - m.structs_t < cfg.every_s then return m.structs end
    if paused() then return m.structs or {} end
    local U = sense_U(api)
    local here = api.my_position()
    local out = {}
    if U and here then
        for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
            if U.try(function() return a.bIsPreview end) ~= true then
                local at = U.loc(a)
                local d = at and math.sqrt((at.X / 100 - here[1]) ^ 2 + (at.Y / 100 - here[2]) ^ 2)
                if d and d <= cfg.radius_m then
                    local data = U.try(function() return a.BuildingPieceData end)
                    out[#out + 1] = { id = U.short(a), name = text(U, U.try(function() return a.DisplayName end))
                                          or (U.valid(data) and text(U, U.try(function() return data.DisplayName end))) or U.short(a),
                                      piece = asset(U, data), position = { at.X / 100, at.Y / 100, at.Z / 100 },
                                      distance = math.floor(d * 10 + 0.5) / 10,
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
        description = "Build one piece by its name from buildables (you need its materials). Walks to a spot, places it "
            .. "where the game allows, checks it was built; if it can't, the reply says why.",
        args = { type = "object", required = { "piece" }, properties = obj({
            piece = { type = "string", description = "The piece's name or id from buildables." },
            at = { description = "Exactly here: [x, y, z] metres or an id." },
            near = { type = "string", description = "Somewhere next to this id ('me' for beside you)." },
            rotation = { type = "number", minimum = 0, maximum = 360, description = "Turn it this many degrees (15 degree steps)." } }) },
        reasons = { "no_permission", "host_only", "unknown_target", "ambiguous_target", "missing_materials", "blocked",
                    "limit_reached", "too_far", "path_blocked", "interrupted", "verification_failed", "timeout" } },
}

return M
