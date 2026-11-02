-- deconstruct: take built pieces down the way a player does (route R2; co-play issue B13: "can't deconstruct").
--
-- The player's path (wiki "Buildings/Mechanics" Ghost mode + Repair mode; guides: B, then T = Repair mode, aim at the
-- piece, middle mouse = destroy; left click repairs). In the game's own data (dump 26161880, read live 2026-11-01):
--   * B = IA_BuildMenu -> BuildModeComponent.CurrentBuildMode Selection; IA_Building_Repair
--     (BuildModeComponent.ToggleRepairAndEditModeAction) -> RepairAndEdit (3);
--   * in RepairAndEdit the game targets the piece under the camera: BuildInteractionComponent.TargetedPieceHandle
--     (.Context = that piece's GlobalBuildingManager id). That is the POSITIVE target signal: destroy is pressed
--     only when it names the piece we mean;
--   * IA_Building_DestroyObject (BuildInteractionComponent.DestroyBuildingAction, MMB, a Pressed trigger) -> the game
--     itself sends Server_Interact(PieceID, Destroy = 3, inventories, location); the server answers
--     Client_TelemetryDestroyPlacedPiece on BuildModeComponent (a Client RPC: its post-hook fires);
--   * refusals: EBuildingDestroyRequestResult {CanDestroy, CantDestroyInUse, CantDestroyProtected,
--     CantDestroyWhileNotEmpty} with the game's own words in DestroyRequestNotificationTextMap.
-- No struct is built in Lua, no RPC is called from Lua: every step is an injected input or a property read.
--
-- deconstruct {target, whole?, include_stations?}
--   target  a structures id (get_state.structures / look): "BuildingPiece_<n>" or an actor id
--   whole   also every piece connected to it (walls, roof, floors, props, foundations), roof first, so nothing
--           collapses unexpectedly; pieces left standing are listed with the reason
--   Luis's safety rules (2026-11-01), enforced here, everything else is the model's call:
--     * never a container that holds items (anyone's): reported and left (the game refuses too);
--     * stations, farm plots and containers that aren't mine are left unless include_stations (the player asked
--       for that one) AND they are empty; a piece something kept stands on is left (it would fall);
--     * on the group's world (shockbyte) only my own pieces.
--   verify (per piece): the piece is gone from GlobalBuildingManager.BuildingPieces, then the refund: what my
--   inventory gained plus what dropped on the ground beside it, against the piece's cost.
-- "Mine": a ledger of pieces I built (data/skills/<world>/my_pieces.json, by piece + position: piece ids may be
-- renumbered when the server reloads), filled from the build-complete telemetry (Client RPC to the builder only)
-- and seeded from verified build replies. get_state.structures rows get mine = true from it.
local M = { W = {} }
local W = M.W
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end
local function r1(x) return math.floor(x * 10 + 0.5) / 10 end
local function r2(x) return math.floor(x * 100 + 0.5) / 100 end
local function hd(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
local function d3(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + ((a[3] or 0) - (b[3] or 0)) ^ 2) end

M.cfg = {
    standoff_m = 3.5, high_standoff_m = 5.0, high_m = 2.5, reach_m = 7.5, min_m = 1.5, stands = 3,
    open_wait_s = 1.2, mode_presses = 5, aim_wait_s = 0.35, aim_rereads = 2,
    aim_tol_m = 0.06, aim_fixes = 5, aim_fix_wait_s = 0.2,
    verify_s = 4.0, settle_s = 1.2, drop_r_m = 5.0, leave_presses = 3, leave_wait_s = 0.5,
    piece_timeout_s = 75, timeout_s = 900, max_pieces = 80,
    -- connected pieces (whole): two pieces link when within link_h_m horizontally and link_z_m vertically (the
    -- game's tile is 3 m; a roof sits 4.5 m above its wall's base, live 2026-11-01); a kept piece "stands on" a
    -- floor piece within on_h_m of its centre and on_z_m above or below its top
    link_h_m = 3.15, link_z_m = 4.65, on_h_m = 1.6, on_z_m = 0.6,
    mine_match_m = 0.3, pending_s = 60, ledger_every_s = 30,
    collect_s = 90, -- picking the refund up off the ground afterwards, at most this long
}
M.ACTIONS = {
    destroy = "/Game/Gameplay/Inputs/Actions/Building/IA_Building_DestroyObject.IA_Building_DestroyObject",
    repair = "/Game/Gameplay/Inputs/Actions/Building/IA_Building_Repair.IA_Building_Repair",
    menu = "/Game/Gameplay/Inputs/Actions/UI/IA_BuildMenu.IA_BuildMenu",
}
M.HOOK_PATHS = {
    destroyed = "/Script/Dominion.BuildModeComponent:Client_TelemetryDestroyPlacedPiece",
    complete = "/Script/Dominion.BuildModeComponent:Client_TelemetryOnBuildingPieceComplete",
    -- (M.HOOKS_V: bump when this list changes, so a hot reload arms the new ones)
    -- what MY client sends (post-hooks on the client's own calls; params read, never written)
    register = "/Script/Dominion.BuildInteractionComponent:Server_RegisterTargetPiece",
    interact = "/Script/Dominion.BuildInteractionComponent:Server_Interact",
}
M.HOOKS_V = 2
M.DESTROY_RESULT = { [0] = "CanDestroy", "CantDestroyInUse", "CantDestroyProtected", "CantDestroyWhileNotEmpty" }
-- fallbacks for BuildInteractionComponent.DestroyRequestNotificationTextMap (live: 2 and 3 are in the map, 1 is not)
M.DESTROY_TEXT = { [1] = "Someone is using it.", [2] = "Only the Host can destroy this.", [3] = "Only empty containers can be destroyed." }

local function mem()
    local m = rawget(_G, "DWDecon")
    if type(m) ~= "table" then m = { hk = { seq = 0 }, pending = {} }; _G.DWDecon = m end
    m.hk = m.hk or { seq = 0 }
    m.pending = m.pending or {}
    return m
end
local function sense_U(api) local s = api.module("sense"); return s and s.U, s end
local function B(api) local b = api.module("build"); return type(b) == "table" and b.W and b or nil end
local function IN(api) local m = api.module("input"); return m and type(m.gate) == "function" and m or nil end

-- ------------------------------------------------------------------ classification (pure; tested offline)
-- What kind of piece, from the game's own asset id and actor class (no hand list of pieces):
-- station | farm_plot | container | foundation | roof | structure | prop
function M.kind(id, class, has_inventory)
    local s = (tostring(id or "") .. " " .. tostring(class or ""))
    if s:find("FarmPlot", 1, true) then return "farm_plot" end
    if s:find("Station", 1, true) or s:find("BP_Crafting_", 1, true) or s:find("Composter", 1, true) then return "station" end
    if has_inventory then return "container" end
    if s:find("Foundation", 1, true) then return "foundation" end
    if s:find("Roof", 1, true) or s:find("Floor", 1, true) or s:find("Ceiling", 1, true) then return "roof" end
    if class and class ~= "" then return "prop" end -- an actor that is none of the above: torch, bedroll, decoration
    return "structure" -- instance-only pieces: walls, door/window frames, stairs, beams, ...
end
M.KEEP_KINDS = { station = true, farm_plot = true, container = true }
-- Do two pieces touch (whole-structure flood)?
function M.linked(a, b)
    local c = M.cfg
    return hd(a.position, b.position) <= c.link_h_m and math.abs(a.position[3] - b.position[3]) <= c.link_z_m
end
-- Does piece k stand on floor piece f (a foundation / floor tile: its location is its top)?
function M.stands_on(k, f)
    local c = M.cfg
    if not (f.kind == "foundation" or f.kind == "roof") then return false end
    return hd(k.position, f.position) <= c.on_h_m and math.abs(k.position[3] - f.position[3]) <= c.on_z_m
end
-- Take-down order: props first (a torch on a wall), then from the top down, foundations last.
local RANK = { prop = 0, roof = 1, structure = 1, container = 1, station = 1, farm_plot = 1, foundation = 2 }
function M.order(list)
    table.sort(list, function(a, b)
        local ra, rb = RANK[a.kind] or 1, RANK[b.kind] or 1
        if ra ~= rb then return ra < rb end
        if math.abs(a.position[3] - b.position[3]) > 0.05 then return a.position[3] > b.position[3] end
        return (a.pid or 0) > (b.pid or 0)
    end)
    return list
end
-- May this piece come down? -> nil (yes) | {why, words}
function M.policy(p, opts)
    opts = opts or {}
    if (p.holds or 0) > 0 then
        return { why = "holds_items", words = "the " .. p.name .. " holds " .. p.holds .. " item" .. (p.holds == 1 and "" or "s") .. ", so I'm leaving it" }
    end
    if p.game_says and p.game_says ~= 0 then
        return { why = M.DESTROY_RESULT[p.game_says] or tostring(p.game_says), words = "the game says: " .. tostring(p.game_words or M.DESTROY_TEXT[p.game_says] or "it can't be destroyed") }
    end
    if opts.world == "shockbyte" and not p.mine then
        return { why = "not_mine", words = "the " .. p.name .. " isn't mine and this is the group's world, so I only take down my own pieces here" }
    end
    if M.KEEP_KINDS[p.kind] and not p.mine and not opts.include_stations then
        -- not in his ledger is all that is known (the game keeps no owner per piece): never "someone else's" (live
        -- 21:07Z: his own 19:04 wheel, missed by the ledger, was called someone else's)
        return { why = "not_mine", words = "the " .. p.name .. " is a " .. p.kind:gsub("_", " ") .. " I have no record of placing (the game keeps no owner on pieces; I go by my own list of what I built), so I'm leaving it unless its owner wants it gone (include_stations)" }
    end
end
-- The plan: the pieces to take down (in order) and the ones left standing with the reason.
-- pieces = every piece near the target {pid, id, name, kind, position, holds, mine, game_says}; target = one of them.
-- -> {queue = {...}, left = {{piece, why, words}}}
function M.plan(pieces, target, opts)
    opts = opts or {}
    local queue, left, seen = {}, {}, {}
    local function leave(p, why, words) left[#left + 1] = { piece = p, why = why, words = words } end
    local set = { target }
    seen[target.pid] = true
    if opts.whole then -- flood through the structure (stations, plots and containers attach but don't carry it on)
        local i = 1
        while i <= #set do
            local a = set[i]
            if not M.KEEP_KINDS[a.kind] then
                for _, b in ipairs(pieces) do
                    if not seen[b.pid] and M.linked(a, b) then seen[b.pid] = true; set[#set + 1] = b end
                end
            end
            i = i + 1
        end
    else -- a single piece: whatever stands on it comes down first, if it may
        for _, b in ipairs(pieces) do
            if not seen[b.pid] and b.pid ~= target.pid and M.stands_on(b, target) then seen[b.pid] = true; set[#set + 1] = b end
        end
    end
    local keep = {}
    for _, p in ipairs(set) do
        local no = M.policy(p, { world = opts.world, include_stations = opts.include_stations and (p == target or not opts.whole) })
        if no then keep[#keep + 1] = p; leave(p, no.why, no.words) else queue[#queue + 1] = p end
    end
    -- a kept piece standing on a queued floor piece keeps that floor piece too (else it would fall)
    local changed = true
    while changed do
        changed = false
        for i = #queue, 1, -1 do
            local f = queue[i]
            for _, k in ipairs(keep) do
                if k.pid ~= f.pid and M.stands_on(k, f) then
                    table.remove(queue, i)
                    keep[#keep + 1] = f
                    leave(f, "supports", "the " .. k.name .. " stands on it, so I left it")
                    changed = true
                    break
                end
            end
        end
    end
    -- one piece: what stands on it was queued only to let it come down; if it stays, nothing comes down
    if not opts.whole then
        local has = false
        for _, p in ipairs(queue) do if p.pid == target.pid then has = true end end
        if not has then queue = {} end
    end
    return { queue = M.order(queue), left = left }
end

-- ------------------------------------------------------------------ world reads (every one replaceable in tests)
local function asset(U, o)
    local p = U.valid(o) and U.path_of(o)
    return p and (p:match("%.([%w_]+)$") or p:match("([%w_]+)$")) or nil
end
local function text(U, v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
-- Every loaded piece type: BuildingPieceDataIndex -> {data, id, name} (UBuildingPieceData; 863 live, read once)
function W.catalogue(api)
    local m = mem()
    if m.cat and m.cat_n and m.cat_n > 0 then return m.cat end
    local U = sense_U(api)
    if paused() or not U then return {} end
    local cat, n = {}, 0
    for _, d in ipairs(U.find_all("BuildingPieceData", { skip_defaults = true }) or {}) do
        local idx = tonumber((U.try(function() return d.BuildingPieceDataIndex end)))
        if idx then
            n = n + 1
            cat[idx] = { data = d, id = asset(U, d), name = text(U, U.try(function() return d.DisplayName end)) }
        end
    end
    m.cat, m.cat_n = cat, n
    return cat
end
-- Items in an actor's own inventories (stations: Resources/Fuel/Catalyst; crates: one). inventory.inventory_of
-- can't see these (live 2026-11-01: GetInventory and the InventoryComponent property are nil on crates and
-- stations), so: every InventoryComponent whose owner is this actor (one find_all per job). -> n, {item = n} | nil
function W.contents(api, actor, job)
    local U = sense_U(api)
    if paused() or not U.valid(actor) then return nil end
    local comps = job and job.inv_comps
    if not comps then
        comps = {}
        for _, c in ipairs(U.find_all("InventoryComponent", { skip_defaults = true }) or {}) do
            local ow = U.try(function() return c:GetOwner() end)
            local k = ow and U.valid(ow) and U.short(ow)
            if k then comps[k] = comps[k] or {}; table.insert(comps[k], c) end
        end
        if job then job.inv_comps = comps end
    end
    local list = comps[U.short(actor)]
    if not list then return nil end
    local n, by = 0, {}
    for _, c in ipairs(list) do
        pcall(function()
            local arr = c.ItemSlots
            for i = 1, (arr:GetArrayNum() or 0) do
                local it = arr[i]
                if U.valid(it) then
                    local id = asset(U, U.try(function() return it.ItemData end)) or "?"
                    local k = tonumber(U.try(function() return it.Count end)) or 1
                    n = n + k
                    by[id] = (by[id] or 0) + k
                end
            end
        end)
    end
    return n, by
end
function W.bi(api)
    local U = sense_U(api)
    local b = B(api)
    local pc = b and b.W.pc(api)
    local bi = pc and U.try(function() return pc.BuildInteractionComponent end)
    return U.valid(bi) and bi or nil
end
function W.targeted(api) -- the piece the game highlights now (0 = none) | nil
    local U = sense_U(api)
    local bi = W.bi(api)
    local v = bi and tonumber((U.try(function() return bi.TargetedPieceHandle.Context end))) or nil
    -- diagnostics for the reply when targeting fails: the raw handle reads
    if bi then
        local m = mem()
        -- the handle's resolver: the cell proxy for instance pieces (Context = their pid), the actor itself for actor
        -- pieces (crate, torch: Context stays 0 live 14:2x), whose BuildingPieceID is then the pid
        local obj = U.try(function() return bi.TargetedPieceHandle.PieceResolver:GetObject() end)
        if not U.valid(obj) then obj = U.try(function() return bi.TargetedPieceHandle.PieceResolver end) end
        local rpid = U.valid(obj) and tonumber((U.try(function() return obj.BuildingPieceID end))) or nil
        m.last_tgt = { ctx = v, auth = tonumber((U.try(function() return bi.AuthorityTargetedPieceHandle.Context end))),
                       resolver = U.valid(obj) and U.short(obj) or nil, rpid = rpid }
        if (not v or v == 0) and rpid and rpid > 0 then v = rpid end
    end
    return v
end
function W.action(api, which)
    local U = sense_U(api)
    local b = B(api)
    if which == "destroy" then
        local bi = W.bi(api)
        local a = bi and U.try(function() return bi.DestroyBuildingAction end)
        if U.valid(a) then return a end
    elseif which == "repair" then
        local bm = b and b.W.bm(api)
        local a = bm and U.try(function() return bm.ToggleRepairAndEditModeAction end)
        if U.valid(a) then return a end
    end
    return U.find_object(M.ACTIONS[which])
end
function W.press(api, action) local b = B(api); return b and b.W.press(api, action) or false end
function W.mode(api) local i = IN(api); return i and i.build_mode() or nil end
function W.words(api) -- the game's own refusal words (TMap, read once)
    local m = mem()
    if m.words then return m.words end
    local U = sense_U(api)
    local bi = W.bi(api)
    local t = {}
    if bi and not paused() then
        pcall(function()
            bi.DestroyRequestNotificationTextMap:ForEach(function(k, v)
                local kk = U.try(function() return k:get() end); if kk == nil then kk = k end
                local vv = U.try(function() return v:get() end); if vv == nil then vv = v end
                if tonumber(kk) then t[tonumber(kk)] = U.str(vv) end
            end)
        end)
    end
    for k, v in pairs(M.DESTROY_TEXT) do if t[k] == nil then t[k] = v end end
    m.words = t
    return t
end
-- The game's own answer for an actor piece: ABaseBuildingActor:CanBeDestroyedByPlayer(PC) -> 0..3 | nil
function W.can_destroy(api, actor)
    local U = sense_U(api)
    local b = B(api)
    local pc = b and b.W.pc(api)
    if paused() or not (pc and U.valid(actor)) then return nil end
    local ok, v = pcall(function() return actor:CanBeDestroyedByPlayer(pc) end)
    return ok and tonumber(v) or nil
end
-- The ids of every built piece the client knows now (GlobalBuildingManager.BuildingPieces keys). -> {pid = true} | nil
function W.alive(api)
    local U = sense_U(api)
    if paused() or not U then return nil end
    local m = mem()
    if not (m.gbm and U.valid(m.gbm)) then
        m.gbm = nil
        for _, a in ipairs(U.find_all("GlobalBuildingManager", { skip_defaults = true }) or {}) do if U.valid(a) then m.gbm = a end end
    end
    local map = m.gbm and U.try(function() return m.gbm.BuildingPieces end)
    if map == nil then return nil end
    local out = {}
    local ok = pcall(function()
        map:ForEach(function(k) local pid = tonumber((U.try(function() return k:get() end))); if pid then out[pid] = true end end)
    end)
    return ok and out or nil
end
-- Built pieces within r of pos as plan rows: {pid, id, name, piece, kind, position, yaw, data, actor, holds, holds_items, mine}
function W.pieces(api, pos, r, job)
    local b = B(api)
    local list = b and b.W.built_pieces(api, pos, r)
    if not list then return nil end
    local cat = W.catalogue(api)
    local U = sense_U(api)
    local out = {}
    for _, e in ipairs(list) do
        local c = (e.index and cat[e.index]) or {}
        local cls = e.actor and U.short(U.try(function() return e.actor:GetClass() end)) or nil
        local n, by
        if e.actor then n, by = W.contents(api, e.actor, job) end
        local p = { pid = e.pid, id = e.id, piece = e.piece or c.id, name = e.name or c.name or ("building piece #" .. tostring(e.index)),
                    index = e.index, data = e.data or c.data, position = e.position, yaw = e.yaw, ghosted = e.ghosted, actor = e.actor,
                    class = cls, holds = n, holds_items = by }
        p.kind = M.kind(p.piece, cls, n ~= nil) -- stations and plots are told apart before "has an inventory"
        out[#out + 1] = p
    end
    M.mark_mine(api, out)
    return out
end
-- What one piece cost (its data's Requirements, through build.describe) -> {item = n}
function W.cost(api, p)
    local b = B(api)
    if not (b and p.data) then return nil end
    local ok, d = pcall(b.describe, api, p.data)
    if not (ok and d) then return nil end
    local out = {}
    for _, c in ipairs(d.cost or {}) do out[c.item] = (out[c.item] or 0) + c.count end
    return out
end
-- Where to aim at a piece: its box centre (the piece's own bounds, through build's piece_profile), else by kind
-- (a foundation's location is its top; a wall's is its base). -> {points}, box?
function W.aim_points(api, p, here)
    local b = B(api)
    local box = p.actor and b and (function()
        local U = sense_U(api)
        local bb = U.try(function() return p.actor.BuildingPieceLocalBounds end)
        local ok, ex, ey, ez, ox, oy, oz = pcall(function() return bb.BoxExtent.X, bb.BoxExtent.Y, bb.BoxExtent.Z, bb.Origin.X, bb.Origin.Y, bb.Origin.Z end)
        if ok and type(ex) == "number" then return { extent = { ex / 100, ey / 100, ez / 100 }, origin = { ox / 100, oy / 100, oz / 100 } } end
    end)() or nil
    if not box and b and p.data then box = (b.W.piece_profile(api, p.data) or {}).box end
    return M.aim_points(p, box, here), box
end
function M.aim_points(p, box, here)
    local P = p.position
    local c
    if box then
        local yaw = math.rad(p.yaw or 0)
        local ox, oy = box.origin[1], box.origin[2]
        c = { P[1] + ox * math.cos(yaw) - oy * math.sin(yaw), P[2] + ox * math.sin(yaw) + oy * math.cos(yaw), P[3] + box.origin[3] }
    elseif p.kind == "foundation" then c = { P[1], P[2], P[3] - 0.15 }
    elseif p.kind == "roof" then c = { P[1], P[2], P[3] + 1.0 }
    elseif p.kind == "structure" then c = { P[1], P[2], P[3] + 1.5 }
    else c = { P[1], P[2], P[3] + 0.4 } end
    local pts = { c }
    -- then toward me (the near face), up/down and sideways: the camera ray may hit a neighbour first
    local dx, dy = (here and here[1] or c[1] + 1) - c[1], (here and here[2] or c[2]) - c[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1, 0, 1 end
    dx, dy = dx / l, dy / l
    local ext = box and math.min(math.max(box.extent[1], box.extent[2]), 1.4) or 0.8
    local zext = box and math.min(box.extent[3], 1.5) or 0.6
    for _, o in ipairs({ { ext * 0.6, 0, 0 }, { 0, 0, zext * 0.5 }, { 0, 0, -zext * 0.5 }, { 0, ext * 0.5, 0 }, { 0, -ext * 0.5, 0 } }) do
        pts[#pts + 1] = { c[1] + dx * o[1] - dy * o[2], c[2] + dy * o[1] + dx * o[2], c[3] + o[3] }
    end
    return pts
end
-- Distance (m) from a world point to a piece's box (the box in the piece's own frame: origin relative to its location,
-- turned by its yaw); 0 = inside. -> d, centre distance
function M.box_dist(p, box, pt)
    local P = p.position
    local yaw = math.rad(p.yaw or 0)
    local dx, dy, dz = pt[1] - P[1], pt[2] - P[2], pt[3] - P[3]
    local lx, ly = dx * math.cos(yaw) + dy * math.sin(yaw), -dx * math.sin(yaw) + dy * math.cos(yaw)
    local l = { lx - box.origin[1], ly - box.origin[2], dz - box.origin[3] }
    local s = 0
    for i = 1, 3 do local o = math.abs(l[i]) - box.extent[i]; if o > 0 then s = s + o * o end end
    return math.sqrt(s), math.sqrt(l[1] ^ 2 + l[2] ^ 2 + l[3] ^ 2)
end
-- The piece a point lies on/in among rows (each with .box): nearest box, ties by the nearest centre.
-- -> row, d | nil
function M.piece_at(rows, pt, tol)
    local best, bd, bc
    for _, p in ipairs(rows or {}) do
        if p.box and p.position then
            local d, c = M.box_dist(p, p.box, pt)
            if d <= (tol or 0.3) and (not bd or d < bd - 0.02 or (math.abs(d - bd) <= 0.02 and c < bc)) then best, bd, bc = p, d, c end
        end
    end
    return best, bd
end
-- Line of sight over the piece boxes (the slab test in each box's own frame). The game highlights the first piece my
-- view ray meets (live 14:27Z: a torch on the inner face of a wall, aimed at from outside, highlighted the wall), so
-- I stand where nothing else lies between my eye and the piece.
-- -> t of entry (0..1) | nil
function M.seg_box(p, box, a, b)
    local P = p.position
    local yaw = math.rad(p.yaw or 0)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local function loc(q)
        local dx, dy = q[1] - P[1], q[2] - P[2]
        return { dx * cy + dy * sy - box.origin[1], -dx * sy + dy * cy - box.origin[2], q[3] - P[3] - box.origin[3] }
    end
    local la, lb = loc(a), loc(b)
    local t0, t1 = 0, 1
    for i = 1, 3 do
        local d, e = lb[i] - la[i], box.extent[i]
        if math.abs(d) < 1e-9 then
            if math.abs(la[i]) > e then return nil end
        else
            local u, v = (-e - la[i]) / d, (e - la[i]) / d
            if u > v then u, v = v, u end
            if u > t0 then t0 = u end
            if v < t1 then t1 = v end
            if t0 > t1 then return nil end
        end
    end
    return t0
end
-- The first other piece between eye and pt (entered more than 0.25 m before pt: a torch's centre may sit in its wall's
-- box). -> row | nil
function M.blocker(rows, P, eye, pt)
    local len = d3(eye, pt)
    if len < 0.01 then return nil end
    local best, bt
    for _, r in ipairs(rows or {}) do
        if r.box and r.position and r.pid ~= P.pid and not r.done then
            local t = M.seg_box(r, r.box, eye, pt)
            if t and t < 1 - 0.25 / len and (not bt or t < bt) then best, bt = r, t end
        end
    end
    return best
end
-- A stand point at `want` m from the piece's aim point with a clear line to it, not inside another piece, nearest to
-- me and not one I tried. -> {x, y, z} | nil
function M.clear_stand(rows, P, c, here, want, tried)
    local best, bd
    for _, dist in ipairs({ want, want + 1.5, math.max(2.0, want - 1.0) }) do
        for k = 0, 11 do
            local a = math.rad(k * 30)
            local s = { c[1] + math.cos(a) * dist, c[2] + math.sin(a) * dist, here[3] }
            local ok = true
            for _, q in ipairs(tried or {}) do if hd(q, s) < 1.0 then ok = false end end
            if ok then
                for _, r in ipairs(rows or {}) do
                    if r.box and r.position and not r.done and M.box_dist(r, r.box, s) < 0.35 then ok = false; break end
                end
            end
            if ok and not M.blocker(rows, P, { s[1], s[2], s[3] + 0.7 }, c) then
                local d = hd(here, s)
                if not bd or d < bd then best, bd = s, d end
            end
        end
    end
    return best
end
-- The camera's view ray: origin (cm) and unit direction.
function W.camera_ray(api)
    local U = sense_U(api)
    local b = B(api)
    local pc = b and b.W.pc(api)
    local cm = pc and U.try(function() return pc.PlayerCameraManager end)
    if not U.valid(cm) then return nil end
    local l = U.try(function() return cm:GetCameraLocation() end)
    local r = U.try(function() return cm:GetCameraRotation() end)
    local ok, x, y, z, pi, ya = pcall(function() return l.X, l.Y, l.Z, r.Pitch, r.Yaw end)
    if not (ok and type(x) == "number" and type(pi) == "number") then return nil end
    local pr, yr = math.rad(pi), math.rad(ya)
    return { x, y, z }, { math.cos(pr) * math.cos(yr), math.cos(pr) * math.sin(yr), math.sin(pr) }
end
-- Aim the camera's view ray THROUGH pos. The camera hangs ~5.8 m behind me on its arm (live 14:3xZ: camera at x 89.0,
-- me at 94.9) and swings round me when the view turns, so a rotation taken from the camera's old spot misses a small
-- piece (a torch is 0.2 m wide). The arm's ray passes through the point nearest my head, so aim from there; the
-- miss check below re-aims until the ray really passes through pos.
function W.aim(api, pos)
    local okr, o, f = pcall(W.camera_ray, api)
    local me = api.my_position()
    local b = B(api)
    local pc = b and b.W.pc(api)
    if not (okr and o and me and pc and pos) then return b and b.W.aim(api, pos) end
    local C = { o[1] / 100, o[2] / 100, o[3] / 100 }
    local H = { me[1], me[2], me[3] + 0.7 }
    local k = (H[1] - C[1]) * f[1] + (H[2] - C[2]) * f[2] + (H[3] - C[3]) * f[3]
    local from = k > 0 and { C[1] + f[1] * k, C[2] + f[2] * k, C[3] + f[3] * k } or H
    local dx, dy, dz = pos[1] - from[1], pos[2] - from[2], (pos[3] or from[3]) - from[3]
    pcall(function() pc:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 }) end)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- How far (m) the camera's view ray passes from pos (nil = can't read the camera).
function W.aim_miss(api, pos)
    local okr, o, f = pcall(W.camera_ray, api)
    if not (okr and o and pos) then return nil end
    local v = { pos[1] - o[1] / 100, pos[2] - o[2] / 100, pos[3] - o[3] / 100 }
    local k = v[1] * f[1] + v[2] * f[2] + v[3] * f[3]
    if k <= 0 then return 99 end
    return math.sqrt(math.max(0, v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2 - k * k))
end
-- What is under my crosshair (the camera's view ray, the line the game's own destroy press used: live 14:2x, the crate
-- aimed this way came down; BuildInteractionComponent.TargetedPieceHandle stays 0 on this client): the hit actor's
-- BuildingPieceID, else the piece whose box holds the impact point (instance-only pieces live on a CellBuildingProxy).
-- -> {pid?, how = "actor"|"box"|"other"|"nothing", at = {m}, what?}
function W.crosshair(api, rows, range_m)
    local U = sense_U(api)
    local o, f = W.camera_ray(api)
    if not o then return nil end
    local r = (range_m or 15) * 100
    local b = B(api)
    local hit, out = b.W.trace(api, { X = o[1], Y = o[2], Z = o[3] }, { X = o[1] + f[1] * r, Y = o[2] + f[2] * r, Z = o[3] + f[3] * r })
    if not hit then return { how = "nothing" } end
    local okp, ix, iy, iz = pcall(function() return out.ImpactPoint.X, out.ImpactPoint.Y, out.ImpactPoint.Z end)
    if not (okp and type(ix) == "number") then return { how = "nothing" } end
    local at = { ix / 100, iy / 100, iz / 100 }
    local comp = U.try(function() return out.Component:Get() end)
    if not U.valid(comp) then comp = U.try(function() return out.Component end) end
    local owner = U.valid(comp) and U.try(function() return comp:GetOwner() end) or nil
    local what = U.valid(owner) and U.short(owner) or nil
    local pid = U.valid(owner) and tonumber((U.try(function() return owner.BuildingPieceID end))) or nil
    if pid and pid > 0 then return { pid = pid, how = "actor", at = at, what = what } end
    local row, d = M.piece_at(rows, at, 0.3)
    if row and (what == nil or what:find("Cell", 1, true) or what:find("Building", 1, true)) then
        return { pid = row.pid, how = "box", d = r2(d), at = at, what = what }
    end
    return { how = "other", at = at, what = what }
end
-- Things lying on the ground near a point (census items): {id = {id, name, item, count, position}}
function W.ground(api, at, r)
    local here = api.my_position() or at
    local out = {}
    for _, t in ipairs(api.census_things(math.min(80, hd(here, at) + r + 2), 40) or {}) do
        if t.category == "items" and t.position and hd(t.position, at) <= r then
            out[t.id] = { id = t.id, name = t.name, item = t.item, count = tonumber(t.count) or 1, position = t.position }
        end
    end
    return out
end

-- ------------------------------------------------------------------ hooks (hookhub: one native post-hook per path)
function W.arm_hooks(api)
    local m = mem()
    if m.hk.armed == M.HOOKS_V then return true end -- re-arming swaps the Lua handlers only (hookhub: one native hook per path)
    local ok, hub = pcall(function()
        local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or (ROOT .. "/client_mod/scripts")
        return assert(loadfile(dir .. "/hookhub.lua"))()
    end)
    if not ok or type(hub) ~= "table" then return false end
    local function g(p) local okg, v = pcall(function() return p:get() end); if okg then return v end return p end
    hub.on(M.HOOK_PATHS.destroyed, "decon:destroyed", function(_, handle, ghosted, res)
        local s = rawget(_G, "DWDecon")
        if not (s and s.hk) then return end
        local h = g(handle)
        local okc, c = pcall(function() return h.Context end)
        local ctx = okc and tonumber(c) or nil
        local vals = {}
        pcall(function() g(res):ForEach(function(_, e) local v = tonumber(g(e)); if v then vals[#vals + 1] = v end end) end)
        s.hk.seq = s.hk.seq + 1
        s.hk.destroyed = { seq = s.hk.seq, pid = ctx, ghosted = g(ghosted) == true, res = vals }
    end, { log = api.log })
    hub.on(M.HOOK_PATHS.register, "decon:register", function(_, target_id, piece_id)
        local s = rawget(_G, "DWDecon")
        if not (s and s.hk) then return end
        s.hk.seq = s.hk.seq + 1
        s.hk.register = { seq = s.hk.seq, target = tonumber(g(target_id)), pid = tonumber(g(piece_id)), t = os.clock() }
    end, { log = api.log })
    hub.on(M.HOOK_PATHS.interact, "decon:interact", function(_, piece_id, itype)
        local s = rawget(_G, "DWDecon")
        if not (s and s.hk) then return end
        s.hk.seq = s.hk.seq + 1
        s.hk.interact = { seq = s.hk.seq, pid = tonumber(g(piece_id)), type = tonumber(g(itype)) }
    end, { log = api.log })
    hub.on(M.HOOK_PATHS.complete, "decon:mine", function(_, ghosted, index)
        local s = rawget(_G, "DWDecon")
        if not s then return end
        local idx = tonumber(g(index))
        if idx then s.pending[#s.pending + 1] = { index = idx, t = os.time() } end
    end, { log = api.log })
    m.hk.armed = M.HOOKS_V
    return true
end

-- ------------------------------------------------------------------ "mine": the ledger of pieces I built
M.fs = { open = io.open, rename = os.rename, remove = os.remove }
local UTIL
local function world_id()
    UTIL = UTIL or assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    return (UTIL.world_id(ROOT))
end
M.world_id = world_id
function M.ledger_path(world) return ROOT .. "/data/skills/" .. tostring(world) .. "/my_pieces.json" end
local function json() local m = mem(); m.json = m.json or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))(); return m.json end
function M.ledger(world, fresh)
    local m = mem()
    world = world or M.world_id()
    local L = m.ledger
    if L and L.world == world and not fresh and os.time() - (L.t or 0) < M.cfg.ledger_every_s then return L end
    L = { world = world, t = os.time(), pieces = {} }
    local f = M.fs.open(M.ledger_path(world), "rb")
    if f then
        local txt = f:read("a") or ""; f:close()
        local ok, d = pcall(function() return json().decode(txt) end)
        if ok and type(d) == "table" and type(d.pieces) == "table" then L.pieces = d.pieces end
        if ok and type(d) == "table" and type(d.left) == "table" then L.left = d.left end
    end
    m.ledger = L
    return L
end
function M.save_ledger(L)
    local path = M.ledger_path(L.world)
    local tmp = path .. ".tmp"
    local f = M.fs.open(tmp, "wb")
    if not f then
        os.execute('mkdir "' .. (ROOT .. "/data/skills/" .. L.world):gsub("/", "\\") .. '" 2>nul')
        f = M.fs.open(tmp, "wb")
    end
    if not f then return false end
    f:write(json().encode({ v = 1, world = L.world, pieces = L.pieces, left = L.left }, { indent = true })); f:close()
    M.fs.remove(path)
    return M.fs.rename(tmp, path) == true
end
local function ledger_find(L, p)
    for i, e in ipairs(L.pieces) do
        if e.piece == p.piece and type(e.at) == "table" and d3(e.at, p.position) <= M.cfg.mine_match_m then return i, e end
    end
end
function M.note_mine(L, p, source)
    if ledger_find(L, p) then return false end
    L.pieces[#L.pieces + 1] = { piece = p.piece, name = p.name, at = { r2(p.position[1]), r2(p.position[2]), r2(p.position[3]) },
                                source = source, noted = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    return true
end
function M.forget_mine(L, p) local i = ledger_find(L, p); if i then table.remove(L.pieces, i); return true end return false end
-- Resolve build telemetry seen since the last call against pieces near me (rows WITH index): the newest piece of
-- that type (piece ids grow), and only if it is among the newest pieces around me (an older piece of the same type
-- must never be taken for the one just placed: the telemetry can arrive before the new piece replicates).
-- -> true when the ledger changed
function M.resolve_pending(L, rows, now)
    local m = mem()
    if #m.pending == 0 or not rows then return false end
    local top = 0
    for _, p in ipairs(rows) do if (p.pid or 0) > top then top = p.pid end end
    local keep, dirty = {}, false
    for _, pd in ipairs(m.pending) do
        local best
        if now - pd.t >= 1 then
            for _, p in ipairs(rows) do
                if p.index == pd.index and (not best or (p.pid or 0) > (best.pid or 0)) then best = p end
            end
            if best and (best.pid or 0) < top - 3 then best = nil end
        end
        if best and best.position then dirty = M.note_mine(L, best, "build telemetry") or dirty
        elseif now - pd.t < M.cfg.pending_s then keep[#keep + 1] = pd end
    end
    m.pending = keep
    return dirty
end
-- His bases: the ledger's pieces in clusters (a piece within link_m of one in the cluster joins it), nearest first ->
-- {{centre = {x, y, z}, distance_m, direction, pieces, covered, stations = {names}}}. His memory of what he built,
-- out to any distance (live 2026-11-02 01:29Z: no roofed wheel in sensing range, so he walled a new one in while
-- his own roofed house stood 100 m off). covered = a roof or a ceiling tile in it.
M.cfg.bases = { link_m = 6.0, max = 4 }
local COMPASS8 = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
function M.bases(L, here)
    local pts = {}
    for _, e in ipairs((L or {}).pieces or {}) do
        if type(e.at) == "table" and #e.at >= 3 then pts[#pts + 1] = e end
    end
    local seen, out = {}, {}
    for i = 1, #pts do
        if not seen[i] then
            seen[i] = true
            local cl, k = { pts[i] }, 1
            while k <= #cl do
                for j = 1, #pts do
                    if not seen[j] and d3(cl[k].at, pts[j].at) <= M.cfg.bases.link_m then seen[j] = true; cl[#cl + 1] = pts[j] end
                end
                k = k + 1
            end
            local sx, sy, sz, covered, st, have = 0, 0, 0, false, {}, {}
            for _, e in ipairs(cl) do
                sx, sy, sz = sx + e.at[1], sy + e.at[2], sz + e.at[3]
                local id = tostring(e.piece or "")
                if id:find("Roof", 1, true) or id:find("_Floor_", 1, true) then covered = true end
                if id:find("^BUILDPIECE_") or id:find("Station", 1, true) or id:find("Chest", 1, true) or id:find("Crate", 1, true) then
                    local nm = tostring(e.name or id)
                    if not have[nm] then have[nm] = true; st[#st + 1] = nm end
                end
            end
            local c = { r2(sx / #cl), r2(sy / #cl), r2(sz / #cl) }
            local b = { centre = c, pieces = #cl, covered = covered, stations = st }
            if here then
                local dx, dy = c[1] - here[1], c[2] - here[2]
                b.distance_m = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
                -- game +Y is south (the compass the body uses elsewhere: N = -Y)
                local a = math.deg(math.atan(-dy, dx)) % 360
                b.direction = COMPASS8[math.floor((a + 22.5) / 45) % 8 + 1]
            end
            out[#out + 1] = b
        end
    end
    table.sort(out, function(a, b) return (a.distance_m or 0) < (b.distance_m or 0) end)
    while #out > M.cfg.bases.max do table.remove(out) end
    return out
end
-- Room to pick something up: over the game's carry weight (move.encumbrance: the PlayerEncumbranceComponent), or no
-- free bag slot while I carry none of it to stack onto. -> {over, full, weight, max_weight}
function M.room(api, item)
    local out = {}
    local mv, inv = api.module("move"), api.module("inventory")
    if mv and type(mv.encumbrance) == "function" then
        local ok, e = pcall(mv.encumbrance)
        if ok and type(e) == "table" and tonumber(e.cur) and tonumber(e.max) then
            out.weight, out.max_weight = r1(e.cur), r1(e.max)
            out.over = e.on == true or e.cur >= e.max
        end
    end
    if inv and type(inv.free_slot) == "function" then
        local ok, sl = pcall(inv.free_slot, "InventoryItems")
        if ok and sl == nil and not (item and ((api.counts() or {})[item] or 0) > 0) then out.full = true end
    end
    return out
end
-- What I left lying on the ground (a teardown's refund I had no room for): the ledger's "left", so it isn't forgotten.
function M.note_left(L, items, at, why)
    L.left = L.left or {}
    L.left[#L.left + 1] = { items = items, at = { r2(at[1]), r2(at[2]), r2(at[3] or 0) }, why = why, noted = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    while #L.left > 20 do table.remove(L.left, 1) end
end
-- Flag rows I built (in place).
function M.mark_mine(api, rows)
    local okw, world = pcall(M.world_id)
    if not okw then return end
    local L = M.ledger(world)
    if M.resolve_pending(L, rows, os.time()) then M.save_ledger(L) end
    for _, p in ipairs(rows or {}) do if p.position and ledger_find(L, p) then p.mine = true end end
end
-- get_state.structures (build.lua fills it first in M.MODULES order): mine = true on my own pieces. Pending build
-- telemetry is resolved here (one piece read around me, only while some is pending).
function M.state_extras(api, data)
    if paused() or type(data) ~= "table" then return nil end
    local okw, world = pcall(M.world_id)
    if not okw then return nil end
    local L = M.ledger(world)
    if #mem().pending > 0 then
        local b = B(api)
        local here = api.my_position()
        local near = b and here and b.W.built_pieces(api, here, 15)
        if near and M.resolve_pending(L, near, os.time()) then M.save_ledger(L) end
    end
    -- false = read against the ledger and not in it (the game keeps no owner per piece, dump 26161880), so the brain
    -- can tell his pieces from other players' and pre-existing ones (brain run 19:42Z: "we already got most of it up
    -- here" about other crates and tables); nil = not checked
    for _, s in ipairs(type(data.structures) == "table" and data.structures or {}) do
        if type(s) == "table" and s.position and s.piece then s.mine = ledger_find(L, s) ~= nil end
    end
    local okb, bases = pcall(M.bases, L, api.my_position())
    if okb and #bases > 0 then return { my_bases = bases } end
    return nil
end

-- ------------------------------------------------------------------ the job
local function arbiter(api) local A = api.module("arbiter"); return A and type(A.request) == "function" and A or nil end
local function sum_into(t, by) for k, v in pairs(by or {}) do t[k] = (t[k] or 0) + v end end
local function items_words(by, names)
    local parts = {}
    for k, v in pairs(by or {}) do parts[#parts + 1] = { k = k, v = v } end
    table.sort(parts, function(a, b) return a.v > b.v end)
    local out = {}
    for _, x in ipairs(parts) do out[#out + 1] = x.v .. " " .. ((names and names[x.k]) or x.k:gsub("^ITEM_", ""):gsub("_", " ")) end
    return #out > 0 and table.concat(out, ", ") or "nothing"
end
M._items_words = items_words

local function find_target(rows, target)
    local q = tostring(target)
    local pid = tonumber(q:match("^BuildingPiece_(%d+)$") or q:match("^#?(%d+)$"))
    for _, p in ipairs(rows) do
        if p.id == q or (pid and p.pid == pid) then return p end
    end
end

function M.start(api, args)
    local cfg = M.cfg
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    if not need_str(args.target) and type(args.target) ~= "number" then
        return api.fail("invalid_args", { detail = "target is required: a structures id from get_state or look" })
    end
    if not B(api) then return api.fail("not_implemented", { detail = "the build module isn't loaded" }) end
    local sense = api.module("sense")
    if sense and type(sense.has_privilege) == "function" then
        local ok, v = pcall(sense.has_privilege, "build")
        if ok and v == false then
            return api.fail("no_permission", { detail = "The server hasn't given me building rights, so I can't take anything down here." })
        end
    end
    local here = api.my_position()
    if not here then return api.fail("companion_down", { detail = "no position" }) end
    local job = { kind = "deconstruct", phase = "next", presses = {}, removed = {}, failed = nil, collapsed = {},
                  refund = {}, dropped = {}, expected = {}, t0 = api.now() }
    pcall(M.ledger, nil, true) -- my pieces: a fresh read per job (the file may have changed)
    job.counts_start = {}
    for k, v in pairs(api.counts() or {}) do job.counts_start[k] = v end
    local rows = W.pieces(api, here, 120, job)
    if not rows then return api.fail("state_unavailable", { detail = "I can't read the built pieces around me right now." }) end
    local tgt = find_target(rows, args.target)
    if not tgt then
        return api.fail("unknown_target", { target = args.target, detail = "I can't see a built piece with the id " .. tostring(args.target) .. "." })
    end
    -- the neighbourhood of the target (a house is small; whole = flood within it)
    local near = {}
    local here0 = api.my_position()
    for _, p in ipairs(rows) do
        if hd(p.position, tgt.position) <= 40 then
            near[#near + 1] = p
            local _, box = W.aim_points(api, p, here0) -- its box (actor bounds or its data's), for the crosshair test
            p.box = box
        end
    end
    local words = W.words(api)
    for _, p in ipairs(near) do
        if p.actor then
            p.game_says = W.can_destroy(api, p.actor)
            if p.game_says and p.game_says ~= 0 then p.game_words = words[p.game_says] end
        end
    end
    local okw, world = pcall(M.world_id)
    job.world = okw and world or "unknown"
    local plan = M.plan(near, tgt, { whole = args.whole == true, include_stations = args.include_stations == true, world = job.world })
    job.queue, job.left, job.target, job.whole = plan.queue, plan.left, tgt, args.whole == true
    job.rows = near
    job.probe_press = args.probe_press == true
    if #job.queue == 0 then
        local w = (plan.left[1] and plan.left[1].words) or "there is nothing I may take down there"
        local why = (plan.left[1] and plan.left[1].why) or "blocked"
        return api.fail(why == "holds_items" and "not_empty" or (why == "not_mine" and "not_mine" or "blocked"), {
            target = tgt.id, left = M.left_rows(plan.left), detail = "I didn't take down the " .. tgt.name .. ": " .. w .. "." })
    end
    if #job.queue > cfg.max_pieces then
        return api.fail("invalid_args", { target = tgt.id, pieces = #job.queue, detail = "That's " .. #job.queue .. " pieces, more than I take down in one go (" .. cfg.max_pieces .. ")." })
    end
    job.planned = {}
    for _, p in ipairs(job.queue) do job.planned[p.pid] = p end
    job.names = {}
    return job
end

function M.left_rows(left)
    local out = {}
    for _, l in ipairs(left or {}) do
        out[#out + 1] = { id = l.piece.id, name = l.piece.name, why = l.why, says = l.words,
                          holds = l.piece.holds_items and next(l.piece.holds_items) and l.piece.holds_items or nil }
    end
    return out
end

local function stand_point(here, at, d, angle_deg)
    local dx, dy = here[1] - at[1], here[2] - at[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.01 then dx, dy, l = 1, 0, 1 end
    local a = math.atan(dy, dx) + math.rad(angle_deg or 0)
    return { at[1] + math.cos(a) * d, at[2] + math.sin(a) * d, here[3] }
end

local function step(api, job, t)
    local cfg = M.cfg
    local i = IN(api)
    local P = job.cur
    local function piece_failed(reason, words, extra)
        job.failed = { id = P.id, name = P.name, why = reason, says = words }
        for k, v in pairs(extra or {}) do job.failed[k] = v end
        job.phase = "leave"
    end
    if job.phase == "next" then
        local alive = W.alive(api)
        if not alive then job.final = api.fail("state_unavailable", { detail = "I lost track of the built pieces." }); job.phase = "leave"; return nil end
        -- anything planned that is gone without my press fell when its support went
        for pid, p in pairs(job.planned) do
            if not alive[pid] and not p.done then p.done = true; job.collapsed[#job.collapsed + 1] = { id = p.id, name = p.name } end
        end
        job.cur = nil
        while #job.queue > 0 do
            local p = table.remove(job.queue, 1)
            if not p.done then job.cur = p; break end
        end
        if not job.cur then job.phase = "leave"; return nil end
        P = job.cur
        P.t0, P.stand, P.moves = t, 0, 0
        P.cost = W.cost(api, P)
        sum_into(job.expected, P.cost)
        job.phase = "approach"
        return nil
    elseif job.phase == "approach" then
        if t - P.t0 > cfg.piece_timeout_s then return piece_failed("timeout", "I spent too long trying to get at it") end
        local here = api.my_position()
        if not here then return nil end
        local pts, box = W.aim_points(api, P, here)
        P.aims, P.box = pts, box
        local c = pts[1]
        local up = c[3] - (here[3] - 0.88)
        local want = up > cfg.high_m and cfg.high_standoff_m or cfg.standoff_m
        local dh = hd(here, c)
        if not P.moving then
            local in_range = dh >= cfg.min_m and dh <= want + 1.0 and d3(here, c) <= cfg.reach_m
            local blk = M.blocker(job.rows, P, { here[1], here[2], here[3] + 0.7 }, c)
            P.blk = blk and blk.id or nil
            if in_range and not blk then job.phase = "mode"; return nil end
            P.tried = P.tried or {}
            local goal = M.clear_stand(job.rows, P, c, here, want, P.tried)
            if in_range and not goal then job.phase = "mode"; return nil end -- nowhere clearer: try from here
            if P.moves >= 2 + cfg.stands then
                if d3(here, c) <= cfg.reach_m then job.phase = "mode"; return nil end
                return piece_failed("too_far", "I couldn't find a spot to reach it from" .. (blk and (" (the " .. blk.name .. " is in the way)") or ""))
            end
            goal = goal or stand_point(here, c, want, (P.stand or 0) * 90)
            P.tried[#P.tried + 1] = goal
            local mr = api.call("move", "go_to", goal, { tolerance_m = 1.0, timeout_s = 45, allow_unstuck = false, owner_token = job.token })
            if not mr.ok then
                P.moves, P.walk_fail = P.moves + 1, (mr.data and mr.data.detail) or mr.reason or "I can't walk there"
                if P.moves >= 2 + cfg.stands then return piece_failed(mr.reason or "path_blocked", P.walk_fail) end
                return nil
            end
            P.moving, P.moves = true, P.moves + 1
            return nil
        end
        local st = api.move_status()
        if st.mode == "go_to" then return nil end
        P.moving = false
        local res = type(st.result) == "table" and st.result or {}
        if res.status ~= "arrived" and res.status ~= "stopped" then P.stand = (P.stand or 0) + 1 end
        return nil
    elseif job.phase == "mode" then
        W.arm_hooks(api)
        if i then i.claim("build", "deconstruct:" .. tostring(P.id)) end
        local mode = W.mode(api)
        if mode == "RepairAndEdit" then job.phase, P.ai, P.aim_t = "aim", 0, nil; return nil end
        if mode == nil then job.final = api.fail("state_unavailable", { detail = "I can't read the build mode." }); job.phase = "leave"; return nil end
        if job.mode_t and t < job.mode_t then return nil end
        job.mode_presses = (job.mode_presses or 0) + 1
        if job.mode_presses > cfg.mode_presses then
            return piece_failed("verification_failed", "I couldn't switch the build screen to repair mode (it stayed in " .. tostring(mode) .. ")")
        end
        if mode == "None" then
            job.presses[#job.presses + 1] = "menu"; W.press(api, W.action(api, "menu"))
        elseif mode == "Selection" then
            job.presses[#job.presses + 1] = "repair"; W.press(api, W.action(api, "repair"))
        else -- Placement: back out of it first
            job.presses[#job.presses + 1] = "cancel"
            if i then i.leave_build_step(function(a) W.press(api, a) end) end
        end
        job.mode_t = t + cfg.open_wait_s
        return nil
    elseif job.phase == "aim" then
        if W.mode(api) ~= "RepairAndEdit" then job.phase = "mode"; return nil end
        if t - P.t0 > cfg.piece_timeout_s then return piece_failed("timeout", "I spent too long trying to get my aim on it") end
        if P.aim_t and t < P.aim_t then return nil end
        if P.aim_t then -- an aim is in: read what the game highlights
            local pt0 = P.aims[P.ai]
            local miss = pt0 and W.aim_miss(api, pt0)
            if miss and miss > cfg.aim_tol_m and (P.fixes or 0) < cfg.aim_fixes then -- the camera swung: re-aim
                P.fixes = (P.fixes or 0) + 1
                W.aim(api, pt0)
                P.aim_t = t + cfg.aim_fix_wait_s
                return nil
            end
            P.miss = miss
            local tg = W.targeted(api)
            if not tg or tg == 0 then
                local ch = W.crosshair(api, job.rows, 15)
                P.ch = ch
                tg = ch and ch.pid or 0
            end
            if tg == P.pid then
                job.phase = "press"; return nil
            end
            P.reads = (P.reads or 0) + 1
            if tg and tg ~= 0 then P.hit_other = tg end
            P.seen = P.seen or {}
            if #P.seen < 24 and P.reads == 1 then
                local lt, hk = mem().last_tgt or {}, mem().hk
                P.seen[#P.seen + 1] = { st = P.stand, ai = P.ai, ctx = lt.ctx, res = lt.resolver, rpid = lt.rpid,
                                        miss = P.miss and r2(P.miss) or nil, fixes = P.fixes,
                                        ch = P.ch and { P.ch.pid, P.ch.how, P.ch.what, P.ch.d } or nil,
                                        reg = hk.register and { hk.register.target, hk.register.pid, hk.register.seq } or nil }
            end
            if P.reads < cfg.aim_rereads then P.aim_t = t + cfg.aim_wait_s; return nil end -- the camera settles: re-aim same point
        end
        P.ai = (P.ai or 0) + 1
        P.reads, P.fixes = 0, 0
        local pt = P.aims[P.ai]
        if not pt and job.probe_press and P.mine and not P.probed then
            -- DEBUG probe (args.probe_press, my own pieces only): press with no target signal, aimed at the first
            -- point, and let the Server_Interact hook say which piece the game's own press path chose
            P.probed = true
            W.aim(api, P.aims[1])
            P.aim_t, P.force_press = t + cfg.aim_wait_s, true
            P.ai = 0
            job.phase = "press"
            return nil
        end
        if not pt then -- no point worked from here: another stand point, else give up on it
            P.stand = (P.stand or 0) + 1
            if P.stand >= cfg.stands then
                local other
                for _, r in ipairs(job.rows or {}) do if P.hit_other and r.pid == P.hit_other then other = r end end
                local ch = P.ch
                local words = other and ("the " .. other.name .. " (" .. tostring(other.id) .. ") is in the way")
                    or (ch and ch.how == "other" and ("something else is in the way (" .. tostring(ch.what or "the ground") .. ")"))
                    or "my aim never lands on it"
                return piece_failed("not_targetable", "I can't get my aim on it: " .. words, { seen = P.seen, want = P.pid })
            end
            job.phase = "approach"; P.ai = 0
            local here = api.my_position()
            if here then
                P.tried = P.tried or {}
                P.tried[#P.tried + 1] = here -- this spot didn't work
                local goal = M.clear_stand(job.rows, P, P.aims[1], here, cfg.standoff_m, P.tried) or stand_point(here, P.aims[1], cfg.standoff_m, 90)
                P.tried[#P.tried + 1] = goal
                local mr = api.call("move", "go_to", goal, { tolerance_m = 1.0, timeout_s = 45, allow_unstuck = false, owner_token = job.token })
                if mr.ok then P.moving, P.moves = true, P.moves + 1 end
            end
            return nil
        end
        W.aim(api, pt)
        P.aim_t = t + cfg.aim_wait_s
        return nil
    elseif job.phase == "press" then
        -- re-check just before: the game still highlights it (the camera may have drifted)
        if P.force_press then
            if P.aim_t and t < P.aim_t then return nil end
        else
            local tg = W.targeted(api)
            if not tg or tg == 0 then local ch = W.crosshair(api, job.rows, 15); tg = ch and ch.pid or 0 end
            if tg ~= P.pid then job.phase = "aim"; P.aim_t = t; return nil end
        end
        P.counts0 = {}
        for k, v in pairs(api.counts() or {}) do P.counts0[k] = v end
        P.ground0 = W.ground(api, P.position, cfg.drop_r_m)
        P.seq0 = mem().hk.seq
        P.alive0 = {}
        for pid in pairs(W.alive(api) or {}) do P.alive0[pid] = true end
        local a = W.action(api, "destroy")
        if not a then return piece_failed("not_implemented", "I can't find the destroy key") end
        job.presses[#job.presses + 1] = "destroy"
        W.press(api, a)
        P.press_t, P.verify_until = t, t + cfg.verify_s
        job.phase = "verify"
        return nil
    elseif job.phase == "verify" then
        local alive = W.alive(api)
        local gone = alive and not alive[P.pid]
        -- safety: my press must never take down a piece I didn't plan (a station, a plot, a supporting floor). If one
        -- went, stop at once and say which.
        if alive and P.alive0 then
            local lost = {}
            for _, r in ipairs(job.rows or {}) do -- the pieces around the job (40 m), not the whole map
                if r.pid ~= P.pid and P.alive0[r.pid] and not alive[r.pid] and not job.planned[r.pid] then
                    lost[#lost + 1] = { pid = r.pid, id = r.id, name = r.name or "piece" }
                end
            end
            if #lost > 0 then
                local names = {}
                for _, l in ipairs(lost) do names[#names + 1] = "the " .. l.name .. " (" .. l.id .. ")" end
                job.collateral = lost
                return piece_failed("wrong_piece", "my press also took down " .. table.concat(names, ", ") .. ", which I hadn't planned, so I stopped")
            end
        end
        local hk = mem().hk.destroyed
        P.telemetry = P.telemetry or (hk and hk.seq > (P.seq0 or 0) and hk) or nil
        if gone then
            P.gone_t = P.gone_t or t
            -- the refund: wait settle_s for it to land (inventory and/or the ground)
            if t - P.gone_t < cfg.settle_s then return nil end
            local counts = api.counts() or {}
            local gained = {}
            for k, v in pairs(counts) do local d = v - (P.counts0[k] or 0); if d > 0 then gained[k] = d end end
            local ground = W.ground(api, P.position, cfg.drop_r_m)
            local dropped = {}
            for id, g in pairs(ground) do if not P.ground0[id] then dropped[#dropped + 1] = g end end
            P.done = true
            local row = { id = P.id, name = P.name, s = r1(t - P.t0), refund = gained, dropped = (#dropped > 0) and dropped or nil,
                          cost = P.cost, telemetry = P.telemetry and { res = P.telemetry.res, pid = P.telemetry.pid } or nil }
            local hk = mem().hk
            if hk.interact and hk.interact.seq > (P.seq0 or 0) then row.sent = { pid = hk.interact.pid, type = hk.interact.type } end
            job.removed[#job.removed + 1] = row
            sum_into(job.refund, gained)
            for _, g in ipairs(dropped) do job.dropped[#job.dropped + 1] = g end
            if P.mine then pcall(function() local L = M.ledger(job.world); if M.forget_mine(L, P) then M.save_ledger(L) end end) end
            job.phase = "next"
            return nil
        end
        if t >= P.verify_until then
            local says = P.actor and W.can_destroy(api, P.actor)
            local words = says and says ~= 0 and (W.words(api)[says] or M.DESTROY_RESULT[says]) or nil
            local hk = mem().hk
            local sent = hk.interact and hk.interact.seq > (P.seq0 or 0) and hk.interact or nil
            return piece_failed(says and says ~= 0 and (M.DESTROY_RESULT[says] or "refused") or "verification_failed",
                words and ("the game says: " .. words) or "I pressed destroy on it but it's still standing",
                { telemetry = P.telemetry and true or false, sent = sent and { pid = sent.pid, type = sent.type } or false })
        end
        return nil
    elseif job.phase == "collect" then
        -- the refund drops beside the piece and a player picks it up. Walking over it was not enough (window 2,
        -- 03:24-03:28Z: 28 + 8 + 4 Ash Logs left lying after every teardown), so: skills.lua's fetch (walk to it and
        -- take it, the pickup path a player's fetch uses) per item still lying there, while I have room (carry weight
        -- under the game's limit, a slot for it); what I leave is said and remembered (the ledger's "left").
        local function finish() job.collect_done = true; return M.result(api, job, job.closed, W.mode(api)) end
        if job.stopped or t - job.collect_t0 > cfg.collect_s then
            if job.cfetch then api.call("move", "stop") end
            return finish()
        end
        job.c_tried, job.collected = job.c_tried or {}, job.collected or {}
        if job.c_moving then -- the plain walk-over (no fetch to hand): the game's magnet may take it
            local st = api.move_status()
            if st.mode == "go_to" then return nil end
            job.c_moving, job.c_wait = false, t + 1.5
            return nil
        end
        if job.c_wait and t < job.c_wait then return nil end
        if job.cfetch then
            local okf, r = pcall(job.cfetch.step, t)
            if okf and r == nil then return nil end
            local c = job.cfetch_item
            job.cfetch = nil
            if okf and type(r) == "table" and r.ok and r.data then
                job.collected[c] = (job.collected[c] or 0) + (tonumber(r.data.count) or 0)
            elseif okf and type(r) == "table" then
                job.collect_fail = job.collect_fail or (r.data and r.data.detail) or r.reason
            else
                job.collect_fail = job.collect_fail or tostring(r)
            end
            return nil
        end
        local S = api.module("skills")
        for _, g in ipairs(job.dropped) do
            local key = g.item or g.name or g.id
            if not job.c_tried[key] then
                job.c_tried[key] = true
                local first, n = nil, 0
                for _, h in ipairs(job.dropped) do
                    if (h.item or h.name or h.id) == key and W.ground(api, h.position, 1.5)[h.id] then first = first or h; n = n + (h.count or 1) end
                end
                if first then
                    local room = M.room(api, g.item)
                    if room.over or room.full then job.no_room = room; return finish() end
                    local f = S and type(S.STARTERS) == "table" and type(S.STARTERS.fetch) == "function"
                        and S.STARTERS.fetch(api, { target = first.id, count = n }, {}) or nil
                    if type(f) == "table" and type(f.step) == "function" then
                        f.token, job.cfetch, job.cfetch_item = job.token, f, key
                        return nil
                    end
                    if type(f) == "table" and f.ok == false then job.collect_fail = job.collect_fail or (f.data and f.data.detail) or f.reason end
                    local mr = api.call("move", "go_to", first.position, { tolerance_m = 0.6, timeout_s = 20, allow_unstuck = false, owner_token = job.token })
                    if mr and mr.ok then job.c_moving = true; return nil end
                end
            end
        end
        return finish()
    else -- leave: Cancel until the mode reads None twice (build.lua's rule)
        local mode = W.mode(api)
        local function done(closed)
            if i then i.release("build") end
            if not job.final and not job.stopped and not job.collect_done and #job.dropped > 0 then -- walk over what still lies there
                job.closed, job.phase, job.collect_t0 = closed, "collect", t
                return nil
            end
            return M.result(api, job, closed, mode)
        end
        if job.leave_t and t < job.leave_t then return nil end
        if mode == "None" then
            job.none_reads = (job.none_reads or 0) + 1
            if job.none_reads >= 2 then return done(true) end
            job.leave_t = t + cfg.leave_wait_s
            return nil
        end
        job.none_reads = 0
        if (job.leaves or 0) >= cfg.leave_presses then return done(false) end
        job.leaves = (job.leaves or 0) + 1
        job.presses[#job.presses + 1] = "cancel"
        if i then i.leave_build_step(function(a) W.press(api, a) end) end
        job.leave_t = t + cfg.leave_wait_s
        return nil
    end
end
M._step = step

M.RESULT_ORDER = { "removed_n", "took_s", "refund", "expected", "on_ground", "dropped", "stopped_at", "collateral", "left", "collapsed", "removed",
                   "site", "left_build_mode", "presses" }
function M.result(api, job, closed, mode)
    if job.final then
        job.final.data = job.final.data or {}
        job.final.data.left_build_mode = closed
        return job.final
    end
    local took = r1(api.now() - job.t0)
    local n = #job.removed
    local names = {}
    for _, g in ipairs(job.dropped) do if g.item then names[g.item] = g.name end end
    -- the game's display names for the rest from my inventory listing (skills.lua gain_words; live 16:11Z: an
    -- undropped refund read "4 Resources Wood Ash" for 4 Ash Logs)
    local okl, lr = pcall(api.call, "inventory", "list")
    local inv = okl and type(lr) == "table" and (type(lr.data) == "table" and lr.data or lr) or {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(type(inv[where]) == "table" and inv[where] or {}) do
            if type(e) == "table" and e.item and e.name and not names[e.item] then names[e.item] = e.name end
        end
    end
    -- the refund = what my inventory gained over the whole job in the refund's items (its cost, plus what dropped);
    -- still on the ground = the drops the census still shows
    local keys = {}
    for k in pairs(job.expected) do keys[k] = true end
    for _, g in ipairs(job.dropped) do if g.item then keys[g.item] = true end end
    local now_c = api.counts() or {}
    local got = {}
    for k in pairs(keys) do local d = (now_c[k] or 0) - ((job.counts_start or {})[k] or 0); if d > 0 then got[k] = d end end
    job.refund = got
    local left_ground, lg_by = {}, {}
    for _, g in ipairs(job.dropped) do
        if W.ground(api, g.position, 1.5)[g.id] then
            left_ground[#left_ground + 1] = g
            lg_by[g.item or g.name] = (lg_by[g.item or g.name] or 0) + (g.count or 1)
        end
    end
    job.on_ground = left_ground
    local parts = {}
    if n > 0 then
        parts[#parts + 1] = string.format("Took down %d piece%s%s in %d s", n, n == 1 and "" or "s",
            n == 1 and (" (the " .. job.removed[1].name .. ")") or (job.whole and (" of the building the " .. job.target.name .. " was part of, top first,") or ""), math.floor(took + 0.5))
        local refund_line = next(got) and ("got back " .. items_words(got, names)) or "got nothing back into my bag"
        local in_bag, cost_matches = true, true
        for k, v in pairs(job.expected) do
            if (got[k] or 0) < v then in_bag = false end
            if (got[k] or 0) + (lg_by[k] or 0) < v then cost_matches = false end
        end
        if next(job.expected) and in_bag then refund_line = refund_line .. " (all it cost)"
        elseif next(job.expected) and not cost_matches then refund_line = refund_line .. " (it cost " .. items_words(job.expected, names) .. ")" end
        if next(lg_by) then
            local at = left_ground[1].position
            local nr = job.no_room
            local why = nr and (nr.over and string.format("I'm carrying too much, %g of %g", nr.weight or 0, nr.max_weight or 0)
                or "my bag has no free slot") or (job.collect_fail and ("picking it up failed: " .. tostring(job.collect_fail))) or nil
            refund_line = refund_line .. "; " .. items_words(lg_by, names) .. string.format(" still lie on the ground at (%.0f, %.0f)", at[1], at[2])
                .. (why and (" (" .. why .. ")") or "")
            pcall(function()
                local L = M.ledger(job.world)
                local its = {}
                for k, v in pairs(lg_by) do its[#its + 1] = { item = k, name = names[k] or k, count = v } end
                M.note_left(L, its, at, why or "not picked up")
                M.save_ledger(L)
            end)
        end
        parts[#parts + 1] = refund_line
    end
    if #job.collapsed > 0 then parts[#parts + 1] = #job.collapsed .. " more fell when their support went" end
    if job.failed then parts[#parts + 1] = "stopped at the " .. job.failed.name .. ": " .. job.failed.says end
    if #job.left > 0 then
        local by = {}
        for _, l in ipairs(job.left) do by[l.words] = (by[l.words] or 0) + 1 end
        local ws = {}
        for w in pairs(by) do ws[#ws + 1] = w end
        table.sort(ws)
        parts[#parts + 1] = "left " .. #job.left .. " standing (" .. table.concat(ws, "; ") .. ")"
    end
    local detail = table.concat(parts, "; ") .. "."
    local still = {}
    for _, l in ipairs(job.left) do still[#still + 1] = { id = l.piece.id, name = l.piece.name, position = l.piece.position } end
    local data = setmetatable({
        detail = detail, removed_n = n, took_s = took, refund = api.object(job.refund), expected = api.object(job.expected),
        dropped = #job.dropped > 0 and job.dropped or nil, on_ground = #(job.on_ground or {}) > 0 and job.on_ground or nil,
        stopped_at = job.failed, collateral = job.collateral, left = M.left_rows(job.left),
        collapsed = #job.collapsed > 0 and job.collapsed or nil, removed = job.removed,
        site = { center = job.target.position, still_standing = still }, left_build_mode = closed,
        build_mode_after = (not closed) and (mode or api.null) or nil,
    }, { __jsontype = "object", __jsonorder = { "detail", table.unpack(M.RESULT_ORDER) } })
    if n == 0 then
        local f = job.failed or {}
        local code = f.why == "too_far" and "too_far" or (f.why == "not_targetable" and "not_interactable") or (f.why == "timeout" and "timeout") or "verification_failed"
        if f.why == "CantDestroyWhileNotEmpty" then code = "not_empty" elseif f.why == "CantDestroyProtected" then code = "no_permission" end
        data.detail = "I didn't take down the " .. job.target.name .. ": " .. tostring(f.says or "nothing came down") .. "."
        return { ok = false, reason = code, data = data }
    end
    return { ok = true, data = data }
end

M.HANDLERS = {}
M.NEEDS = { deconstruct = { { "build", "describe" }, { "sense", "local_pc" }, { "move", "go_to" }, { "move", "status" }, { "input", "gate" } } }
M.HANDLERS.deconstruct = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    args = args or {}
    local job = M.start(api, args)
    if job.ok == false then return job end
    local A = arbiter(api)
    local function release(why)
        if job.token and job.own ~= "released" then job.own = "released"; if A then pcall(A.release, api.log, job.token, why) end end
    end
    local function acquire()
        if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
        if not A then job.own = "none"; return true end
        local r = A.request(api.log, { name = "skill:deconstruct", level = "command", uses_move = true, lease_s = 30, resumable = true,
            on_suspend = function()
                job.own = "suspended"
                local i = IN(api)
                if i and not paused() then i.release("build"); i.leave_build_step(function(a) W.press(api, a) end) end
                if job.phase ~= "leave" then job.reenter = true end
            end,
            on_resume = function() job.own = "owner"; job.resumed = true; return true end,
            on_stop = function(_, _, why) if job.own ~= "released" then job.stopped = why or "stopped" end end })
        if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
        job.own = "waiting"
        return false
    end
    local a = { kind = "deconstruct", id = ctx.id, timeout_s = M.cfg.timeout_s }
    a.cancel = function()
        local i = IN(api)
        if i and not paused() then i.release("build"); i.leave_build_step(function(x) W.press(api, x) end) end
        if not paused() then api.call("move", "stop") end
        release("cancelled")
    end
    a.poll = function(self)
        if paused() then return nil end
        if job.stopped and job.phase ~= "leave" and job.phase ~= "collect" then
            job.final = api.fail("interrupted", { why = job.stopped, detail = "Something else took over (" .. tostring(job.stopped) .. "), so I stopped taking it down." })
            if #job.removed > 0 then job.final = nil; job.failed = { name = (job.cur or job.target).name, why = "interrupted", says = "something else took over (" .. tostring(job.stopped) .. ")" } end
            job.phase = "leave"
        end
        if not acquire() or job.own == "suspended" or api.reflex_owns_pawn() then return nil end
        if A and job.token and type(A.renew) == "function" then pcall(A.renew, job.token) end
        if job.resumed then
            job.resumed = nil
            if job.reenter and job.cur then job.reenter = nil; job.phase = "approach"; job.cur.moving = false; job.mode_presses = 0 end
        end
        local b = B(api)
        local ok, res = pcall(step, api, job, (b and b.W.clock(api)) or api.now())
        if not ok then
            job.final, job.phase = api.fail("body_error", { detail = "deconstruct: " .. tostring(res) }), "leave"
            res = nil
        end
        if res then release(res.ok and "done" or tostring(res.reason)); res.data = res.data or {}; res.data.presses = job.presses end
        return res
    end
    return { pending = a }
end

-- ------------------------------------------------------------------ manifest
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    deconstruct = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 15, timeout_s = 900,
        detail_is_speech = true,
        description = "Take down a built piece the way a player does (build menu, repair mode, aim, destroy), or with whole=true "
            .. "every piece connected to it, top first so nothing falls. Says what came down, what you got back (the "
            .. "materials it cost: they drop beside it and I walk over them; any still on the ground are named with their "
            .. "ids in on_ground, for fetch) and what was left and why. Never takes "
            .. "a container that holds items; stations, farm plots and containers that aren't yours stay unless the player "
            .. "asked for that one (include_stations); a piece something kept stands on stays.",
        args = { type = "object", required = { "target" }, properties = obj({
            target = { type = "string", description = "A structures id (get_state / look), e.g. BuildingPiece_42 or an actor id." },
            whole = { type = "boolean", default = false, description = "Also every piece connected to it (the whole house)." },
            include_stations = { type = "boolean", default = false, description = "Also an empty station / plot / container that isn't yours, only when the player asked for it." } }) },
        reasons = { "unknown_target", "not_empty", "not_mine", "blocked", "no_permission", "too_far", "not_interactable", "verification_failed", "interrupted", "timeout" } },
}

return M
