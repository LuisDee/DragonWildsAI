-- gather: Claude gathers like a player on his own CLIENT (route R2, task R2.17). Real player paths only:
--   * find:    sense.foliage (standing trees / bushes / pickups are foliage instances on the client)
--              + replicated actors (converted trees, felled trunks, log pieces, rocks, ground
--              resources) + dropped WorldItems of the counted item;
--   * tool:    the right tool from HIS OWN inventory (weapons_data cat axe/pickaxe, tier vs the live
--              gate), equipped with the hotbar number key (inventory.equip);
--   * move:    move.lua's public API only (go_to), through the control arbiter at level "task", so the
--              combat reflex pre-empts a gather and the gather resumes afterwards;
--   * aim:     the camera (PlayerController:SetControlRotation) plus a short movement nudge, because the
--              body turns only toward movement (bOrientRotationToMovement); the chop wedge sits ~35 deg
--              right of the body's forward (calibrated on the server puppet, DISCOVERIES "Gather: hit
--              calibration"), other aims are tried in turn when swings do nothing;
--   * swing:   the pawn's own IA_PrimaryAction, injected through combat.lua's helper (combat.inject /
--              combat.actions: the SAME Enhanced Input path as fights, not a fork);
--   * chain:   standing tree -> (server converts it) -> stump + felled tree -> splittable logs -> logs
--              -> item drops -> the item magnet / the interact key (inventory.press_interact);
--   * verify:  progress = HIS inventory count of the item (inventory.list), never our own tally.
-- Never calls server RPCs, never converts foliage, never emulates damage.
--
-- Prior art (search-before-building, DISCOVERIES "Client gathering (R2)"): mineflayer-collectblock
-- (nearest target first; tool via mineflayer-tool equipForBlock before dig; drops within the block
-- become new targets; cancel = stop pathing), Baritone MineProcess (count the inventory each tick,
-- stop at the desired quantity, blacklist the closest target when pathing fails, rescan, give up when
-- nothing is known), the legacy server gather (mod/body/gather.lua: profiles, chain, reach, aim).
-- Decision: ADAPT those shapes; BUILD the thin Lua loop over the existing client modules.
-- Collection/tool/quantity-loop references, not Dragonwilds outcome implementations:
-- https://github.com/PrismarineJS/mineflayer-collectblock
-- https://github.com/PrismarineJS/mineflayer-tool
-- https://github.com/cabaletta/baritone/blob/master/src/main/java/baritone/process/MineProcess.java
--
-- Entry points (log = DWClient text logger):
--   M.start(log, args, ctx) args = {resource, count (MORE to collect), radius (m), stumps (bool)}
--   M.stop(log, why)   M.status()   M.HANDLERS = {gather (async {pending}), gather_status}
-- Failure reasons (brain/interface.py Reason) with data.why (specific) and data.detail (a sentence):
--   wrong_tool (no_tool | tool_tier_too_low), nothing_in_range (no_resource_nearby), inventory_full,
--   path_blocked (unreachable | swing_no_effect), zone_blocked (a damaging zone, e.g. a poison cloud, across the only
--   way to bad_streak picks in a row: move's words say what, where, how long), interrupted, companion_down, timeout,
--   unknown_target (unknown_resource), invalid_args, body_error (inputs_not_reaching_game | camera_taken: walks
--   kept ending for a cause that is not the way, M.NOT_PATH)
-- Events: client_io/events/gather.jsonl {"type":"gather_progress", task_id, resource, item, have, want}
--   and {"type":"gather_status", task_id, phase, detail} (one per phase change, at most every 2 s).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    radius_m = 30, max_radius_m = 90, widen = 1.5,
    ground_probe_cm = 200, capsule_half_cm = 88, -- "floating": the ground is read this far beside the thing; his capsule centre stands this high
    near_radius_m = 15, near_max_radius_m = 30, -- args.near = a player: search around HIM (retro 2026-11-01 cause 4)
    decide_s = 0.1,
    tap_frames = 3,
    -- a press before the swing's own next-attack time is dropped, not kept (live 2026-11-16: 200 ms early lost 2 of 10
    -- swings), and one on time is never lost, so the spread only costs time: 60-220 ms made a 1.53 s swing 1.76 s.
    -- The stone pickaxe's 1527 ms is a little short of what the server takes: presses 1.54 s apart were lost (3 of the
    -- 5 seen, each a whole swing, 1.5 s), none at 1.56 s or more
    press_jitter_ms = { 35, 70 },
    settle_s = 0.35,            -- stand still this long before a swing (swings while moving point along the path)
    still_cm_per_s = 40,        -- moving faster than this in the aim phase = still sliding: the settle waits
    face_err_deg = 15, face_max_s = 1.2, nudge_scale = 0.25,
    -- aim offsets to try (deg, + = target to the RIGHT of the body's forward); the first is the prior
    aim_offsets = { axe = { 35, 0, 20, -20 }, pickaxe = { 0, 25, -25, 35 }, default = { 0, 30, -30 } },
    no_effect_swings = 3,       -- verified swings with no damage before the next aim
    -- TEMPORARY GUARD (coordinator 2026-11-01), not the fix: swings in a row that ran and did nothing before he leaves
    -- this log piece (every aim once, ~17 s) and says so in the result. The mechanism behind the unhittable split log
    -- (1 chop in 6) is under study: diag_piece logs its geometry, collision, physics and traces ("gather: diag ...").
    give_up_swings = 12,
    diag_swings = 4,            -- no-effect swings in a row on a log piece before its one diag snapshot
    sides = 2,                  -- stand points tried around a target (each with every aim)
    unverified_presses = 6,     -- presses with no stamina spent and no damage in a row: input broken
    approach_timeout_s = 40,
    -- a player walks by sight when no route comes: the move standing in "planning" (waiting for the nav helper) this
    -- long with no step taken restarts without it (live 2026-11-02 01:45Z: flax 55.6 m away, "Moved 0 m in 40 s")
    route_wait_s = 6,
    -- an approach that timed out this much closer than it began is progress, not "unreachable": go on (01:47Z: 147 m
    -- walked, 5 m left, given up)
    progress_cm = 1000, progress_retries = 2,
    near_enough_cm = 90,        -- a failed approach that ended this close beyond reach still swings
    bad_ttl_s = 600, bad_streak = 3,
    not_path_tries = 3,         -- walks ended for a cause that is not the way (M.NOT_PATH) before the job ends with it
    equip_wait_s = 4, equip_repress_s = 1.5,
    collected_ttl_s = 10,       -- a drop the bag already counted is skipped this long (its client copy lingers ~5 s)
    collect_wait_s = 2.0, collect_presses = 3, collect_press_gap_s = 0.7, collect_tol_m = 0.8, collect_max_s = 12,
    collect_all_cm = 200, -- if the game's CollectAllRadius is unreadable (it read 200, live 15:33Z)
    pile_cm = 150,        -- drops this close to one the game would not hand over count as the same pile
    collect_aim_cm = 200, -- aim the camera at a drop from this close (the detector ray starts at the camera)
    drop_wait_s = 1.2,          -- after a piece breaks, let its drops land before scanning
    settle_max_s = 10, step_back_m = 2.5,
    adopt_cm = 200,             -- a converted actor this close to a foliage instance is that instance
    timeout_base_s = 120, timeout_per_unit_s = 30, timeout_max_s = 1700,
    count_every_s = 1.0,
    stamina_margin = 2,
    lease_s = 5,
    leftover_m = 25,            -- pieces of OUR felled trees within this are finished first
    stumps = false,             -- chopping a stump stops the tree regrowing (wiki): only when asked
}
-- move's walk-end reasons that are not about the way there (the target is not unreachable for them)
M.NOT_PATH = { camera_taken = true }

-- ------------------------------------------------------------------ state (hot-reload safe)
local function C()
    local c = _G.DWGather
    if not c then
        c = { gen = 0, bad = {}, counts = { jobs = 0, swings = 0, hits = 0, broken = 0, collected = 0 }, log_lines = {} }
        _G.DWGather = c
    end
    return c
end
M._state = C

local rnd = math.random
local function jitter(r) return (r[1] + rnd() * (r[2] - r[1])) / 1000 end

local function say(log, msg)
    if log then pcall(log, "gather: " .. msg) end
    local c = C()
    c.log_lines[#c.log_lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.log_lines > 40 then table.remove(c.log_lines, 1) end
end

-- ------------------------------------------------------------------ sibling modules (loadfile, injectable)
local L = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua)
M.mods, M.set_modules = L.mods, L.set_modules
local mod, mcall = L.mod, L.mcall
M.mod = mod

local PROFILES
function M.profiles()
    PROFILES = PROFILES or mod("gather_profiles")
    return PROFILES
end

-- ------------------------------------------------------------------ world adapter (tests replace it)
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
function W.pc() return mcall("sense", "local_pc") end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.actors(cls) return U.find_all(cls, { skip_defaults = true }) end
function W.foliage(origin, r_cm, opts) return mcall("sense", "foliage", origin, r_cm, opts) or {} end
function W.loc(a) return U.loc(a) end
function W.alive(a) return U.alive(a) end
function W.id(a) return U.short(a) end
function W.class(a) return U.class_word(a) end
function W.hp(a) local v = U.health(a); return type(v) == "number" and v or nil end
-- Targets are any resource class (trees, rocks, ground pickups, world items): by-name reads go through U.prop (R17:
-- UE4SS's property cache is keyed by class ADDRESS, and a streamed-out Blueprint class's address gets reused).
function W.max_hp(a)
    local hc = U.prop(a, "HealthComponent")
    local v = hc ~= nil and U.try(function() return hc:GetMaxHealth() end)
    return type(v) == "number" and v > 0 and v or nil
end
function W.stump(a) return U.prop(a, "bIsStump") == true end
-- A rock that broke stays as a hidden actor (bDestroyActorOnZeroHealth=false) and respawns.
function W.depleted(a)
    if U.prop(a, "bIsHidden") == true then return true end
    local has = U.try(function() return a:HasAvailableResources() end)
    return has == false
end
function W.available(a) -- ground resources / bushes
    local v = U.try(function() return a:IsResourceAvailable() end)
    return v ~= false
end
function W.gate(a) return mcall("sense", "gate", a) end
function W.item_of(a) -- ItemData id of a ground resource / world item
    local data = U.prop(a, "ItemData")
    local p = U.valid(data) and U.path_of(data)
    return p and p:match("%.([%w_]+)$") or nil
end
-- Logs: the trunk meshes roll away from the actor origin (legacy DISCOVERIES), so aim at the
-- game's own GetMidPointWorldLocation (an FVector out param, filled as a flat table; read OK on the
-- dev server with the same UE4SS).
function W.aim(a)
    local origin = U.loc(a)
    if (U.class_word(a) or ""):find("Log", 1, true) then
        local mid = {}
        local ok = pcall(function() a:GetMidPointWorldLocation(mid) end)
        if ok and type(mid.X) == "number" and (mid.X ~= 0 or mid.Y ~= 0) then return { X = mid.X, Y = mid.Y, Z = mid.Z or (origin and origin.Z) or 0 } end
    end
    return origin
end
function W.drops(origin, r_cm, item)
    local out = {}
    for _, w in ipairs(U.find_all("WorldItem", { skip_defaults = true })) do
        local p = U.loc(w)
        if p and U.dist2d(origin, p) <= r_cm then
            local id = W.item_of(w)
            if id and (not item or id == item) then
                out[#out + 1] = { actor = w, key = U.short(w), pos = p, item = id, count = U.try(function() return w:GetStackSize() end) }
            end
        end
    end
    return out
end
-- The game's collect-all radius (cm; UItemDeveloperSettings.CollectAllRadius on its CDO), read once; nil if unreadable.
function W.collect_all_cm()
    if W._collect_all == nil then
        local cdo = U.try(function() return StaticFindObject("/Script/Dominion.Default__ItemDeveloperSettings") end)
        local r = U.valid(cdo) and U.try(function() return cdo.CollectAllRadius end)
        W._collect_all = (type(r) == "number" and r > 0) and r or false
    end
    return W._collect_all or nil
end
function W.stamina(pawn) local v = U.try(function() return pawn.StaminaComponent:GetStamina() end); return type(v) == "number" and v or nil end
function W.yaw(pawn) local r = U.try(function() return pawn:K2_GetActorRotation() end); return r and r.Yaw or 0 end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
function W.face(pc, yaw) pcall(function() pc:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }) end) end
-- Aim the camera AT a point (yaw and pitch from the camera, as the mouse aims): the game's interaction detector casts
-- its ray from the camera, which sits behind and above him (client_bridge aim_at, live-verified on small items).
function W.aim_cam(pc, pos)
    local cam = U.try(function() return pc.PlayerCameraManager:GetCameraLocation() end)
    local ok, cx, cy, cz = pcall(function() return cam.X, cam.Y, cam.Z end)
    if not (ok and type(cx) == "number" and type(cz) == "number" and pos) then return false end
    local dx, dy, dz = pos.X - cx, pos.Y - cy, (pos.Z or cz) - cz
    local yaw, pitch = math.deg(math.atan(dy, dx)), math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
    return pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
end
function W.nudge(pawn, dir, scale)
    -- a nudge is a step: never toward a lethal edge (live 2026-11-01 16:37: a walk to his grave on a cliff-top
    -- shoulder slid him off); move.unsafe_ahead names the drop, and then he only aims
    local mv = mod("move")
    local okh, bad = pcall(function() return mv and type(mv.unsafe_ahead) == "function" and mv.unsafe_ahead(pawn, dir.X, dir.Y) end)
    if okh and bad then return end
    pcall(function() pawn:AddMovementInput(dir, scale, false) end)
end
-- The ground beside a thing at p (cm): the highest floor at four points r_cm from it, by move's own downward trace
-- (ground_at), leaving out anything more than 3 m above it (a branch, an overhang). -> Z in cm; false when there is
-- no floor under any of the four; nil when it can't be read.
function W.ground_near(p, r_cm, ground_at)
    local mv = not ground_at and mod("move") or nil
    ground_at = ground_at or (mv and mv.ground_at)
    if type(ground_at) ~= "function" then return nil end
    local best, read = nil, false
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local g = U.try(ground_at, nil, { (p.X + d[1] * r_cm) / 100, (p.Y + d[2] * r_cm) / 100, p.Z / 100 })
        if type(g) == "table" and g.ok then
            local f = g.floor_z and g.floor_z * 100
            if not f then read = true
            elseif f <= p.Z + 300 then read = true; if not best or f > best then best = f end end
        end
    end
    if not read then return nil end
    return best or false
end
-- The height a tool's swing covers about his middle, from the game's own damage shape for that attack (the shared
-- reach service, mod/body/reach.lua; `action` is the tool's attack class path, weapons_data prim.action).
-- -> { lo, hi } cm; nil when it can't be read.
local REACH
function W.swing_band(action)
    if type(action) ~= "string" or action == "" then return nil end
    if REACH == nil then
        package.loaded["body.util"] = package.loaded["body.util"] or U -- reach.lua require()s the util this file loaded
        REACH = U.try(function() return assert(loadfile(ROOT .. "/mod/body/reach.lua"))() end) or false
    end
    if not REACH then return nil end
    local cls = U.find_object(action)
    local cdo = cls and U.try(function() return cls:GetCDO() end) or nil
    local ad = U.valid(cdo) and U.try(function() return cdo.AttackData end) or nil
    if not U.valid(ad) then return nil end
    local _, _, _, sh = REACH.shape_of(ad)
    return REACH.band_of(sh)
end
-- A thing's colliding bounds -> { mid = {X, Y, Z}, half = {X, Y, Z} } cm; nil when they can't be read.
function W.bounds(a)
    local b = U.try(function() local o, e = {}, {}; a:GetActorBounds(true, o, e, false); return { o.X, o.Y, o.Z, e.X, e.Y, e.Z } end)
    if type(b) ~= "table" then return nil end
    for i = 1, 6 do if type(b[i]) ~= "number" then return nil end end
    if b[6] <= 0 then return nil end
    return { mid = { X = b[1], Y = b[2], Z = b[3] }, half = { X = b[4], Y = b[5], Z = b[6] } }
end
-- The floor under a point (cm), by move's own downward trace -> Z in cm; false when there is none within a safe
-- fall; nil when it can't be read.
function W.floor_at(p)
    local mv = mod("move")
    if not (mv and type(mv.ground_at) == "function") then return nil end
    local g = U.try(mv.ground_at, nil, { p.X / 100, p.Y / 100, p.Z / 100 })
    if type(g) ~= "table" or not g.ok then return nil end
    return g.floor_z and g.floor_z * 100 or false
end
function W.actions(pawn) return mcall("combat", "actions", pawn) or {} end
function W.inject(action)
    local cb = mod("combat")
    local f = cb and (cb.inject or cb._inject)
    return f and f(action) or false
end
local json_mod
function W.emit(ev)
    json_mod = json_mod or assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    local okw, walltime = pcall(require, "walltime") -- ms ts + act/ep (telemetry items 2, 5)
    if okw and type(walltime) == "table" and type(walltime.stamp) == "function" then walltime.stamp(ev) else ev.ts = os.time(); ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts) end
    local line = U.try(function() return json_mod.encode(ev) end)
    if not line then return end
    local f = io.open(ROOT .. "/client_io/events/gather.jsonl", "a")
    if f then f:write(line, "\n"); f:close() end
end

-- ------------------------------------------------------------------ pure helpers (offline-tested)
local function matches(cls, match, exclude)
    cls = cls or ""
    if match and not cls:find(match) then return false end
    if type(exclude) == "string" then exclude = { exclude } end
    for _, e in ipairs(exclude or {}) do if cls:find(e) then return false end end
    return true
end
M.matches = matches

local function bearing(a, b) return math.deg(math.atan(b.Y - a.Y, b.X - a.X)) end
local function wrap(d) return (d + 540) % 360 - 180 end
M.wrap = wrap

-- Count of an item in his bag + hotbar (inventory.list rows).
function M.count_in(list, item)
    local n = 0
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if item and e.item == item then n = n + (e.count or 1) end
        end
    end
    return n
end
local function counts_of(list)
    local t = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if e.item then t[e.item] = (t[e.item] or 0) + (e.count or 1) end
        end
    end
    return t
end
M.counts_of = counts_of

-- Free slots on the pages a pickup lands in (item page + hotbar: inventory.list room.total, inventory.room_of). Never
-- list.empty_slots: GetNumEmptySlots counts the rune, ammo and quest pages too (164 live with a full item page), so a
-- full bag never read 0 and a refused pickup ended "interact had no effect". nil = the pages were not read.
function M.pickup_room(list)
    local r = type(list) == "table" and list.room
    return type(r) == "table" and tonumber(r.total) or nil
end
-- Units of an item his own stacks still take (each stack's MaxStackSize less its count, any page); nil when a stack's
-- size is unread (then nobody can say the pickup won't merge).
function M.stack_room(list, item)
    if not item then return 0 end
    local n = 0
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if e.item == item then
                local max = tonumber(e.max_stack)
                if not max then return nil end
                n = n + math.max(0, max - (tonumber(e.count) or 1))
            end
        end
    end
    return n
end
-- Full for this item: no free slot on the item page or hotbar AND no stack of it with room left.
function M.full_for(list, item)
    return M.pickup_room(list) == 0 and M.stack_room(list, item) == 0
end
-- What fills the pages a pickup lands in, by kind: {item, name, slots, count}, most slots first (top k).
function M.fills(list, k)
    local by, order = {}, {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            if e.item and (where == "hotbar" or (e.slot_type or "InventoryItems") == "InventoryItems") then
                local f = by[e.item]
                if not f then f = { item = e.item, name = e.name or e.item, slots = 0, count = 0 }; by[e.item] = f; order[#order + 1] = f end
                f.slots, f.count = f.slots + 1, f.count + (tonumber(e.count) or 1)
            end
        end
    end
    table.sort(order, function(a, b)
        if a.slots ~= b.slots then return a.slots > b.slots end
        if a.count ~= b.count then return a.count > b.count end
        return a.item < b.item
    end)
    local out = {}
    for i = 1, math.min(k or 4, #order) do out[i] = order[i] end
    return out
end
-- The inventory_full result's data: the room read, what fills the bag (top kinds) and a true sentence, so the brain
-- can choose what to store or drop, and the log line's text (no module prefix). The shared bag-full report: gather
-- (full_data below) and collect_water (skills.lua) both use it, each logging under its own name.
function M.full_info(list, item, name, at)
    local fills, words = M.fills(list, 4), {}
    for _, f in ipairs(fills) do
        words[#words + 1] = string.format("%s x%d (%d slot%s)", tostring(f.name), f.count, f.slots, f.slots == 1 and "" or "s")
    end
    local r = list.room or {}
    local what = name and (tostring(name):gsub("_", " ")) or item -- a resource key reads as words ("loose stones")
    local detail = string.format("My bag is full: no free slot on my item page (%s/%s used) or hotbar (%s/%s)%s, so the game "
        .. "won't take %s. It's mostly %s. I need to store or drop something to pick up more.",
        tostring((r.items_slots or 0) - (r.items or 0)), tostring(r.items_slots or "?"),
        tostring((r.hotbar_slots or 0) - (r.hotbar or 0)), tostring(r.hotbar_slots or "?"),
        what and string.format(" and no %s stack with room", tostring(what)) or "", what and ("any more " .. tostring(what)) or "any more",
        #words > 0 and table.concat(words, ", ") or "nothing I can read")
    local line = string.format("bag full for %s (%s): room 0 (item page %s/%s, hotbar %s/%s free), no stack with room; fills: %s",
        tostring(item), tostring(at), tostring(r.items), tostring(r.items_slots), tostring(r.hotbar), tostring(r.hotbar_slots),
        table.concat(words, ", "))
    return { why = "inventory_full", detail = detail, item = item, fills = fills,
             room = { items = r.items, items_slots = r.items_slots, hotbar = r.hotbar, hotbar_slots = r.hotbar_slots } }, line
end
-- gather's own: full_info, logged (unseen signature "gather: bag full for").
function M.full_data(list, item, name, log, at)
    local d, line = M.full_info(list, item, name, at)
    say(log, line)
    return d
end

-- The best tool he OWNS for a profile: {entry, tier, where} | nil, plus the best tier seen.
-- tools = weapons_data.items (cat "axe"/"pickaxe", tier). Highest tier first (fewer swings).
function M.best_tool(list, profile, tools)
    if not profile.tool then return nil end
    local best
    for _, where in ipairs({ "loadout", "hotbar", "bag" }) do
        for _, e in ipairs((list or {})[where] or {}) do
            local p = e.item and tools[e.item]
            if p and p.cat == profile.tool and not e.broken then
                local tier = p.tier or 1
                if not best or tier > best.tier then best = { entry = e, tier = tier, where = where, name = e.name or p.name } end
            end
        end
    end
    return best
end

local TOOL_WORD = { axe = "logging axe", pickaxe = "pickaxe" }
local function tool_word(p) return TOOL_WORD[p.tool or ""] or tostring(p.tool) end
M.tool_word = tool_word -- craft_plan names a gather step's tool in the words gather refuses with

-- ------------------------------------------------------------------ the job
-- Kinds other than the counted item whose count rose since the job began: {{item, name, count}}, biggest first.
function M.also_gained(J)
    local out = {}
    for item, n in pairs(J.now_counts or {}) do
        local g = n - ((J.inv0 or {})[item] or 0)
        if item ~= J.item and g > 0 then out[#out + 1] = { item = item, name = (J.names or {})[item] or item, count = g } end
    end
    table.sort(out, function(a, b) return a.count > b.count or (a.count == b.count and a.item < b.item) end)
    return out
end

local function result_of(J, ok, reason, data)
    data = data or {}
    data.resource, data.item, data.want = J.key, J.item, J.want
    data.gathered = J.gained or 0
    data.total = J.have
    data.swings, data.hits, data.broken, data.targets = J.swings, J.hits, J.broken, J.targets
    data.seconds = J.t and J.t0 and math.floor((J.t - J.t0) * 10) / 10 or nil
    data.radius_m = J.radius_cm and J.radius_cm / 100 or nil
    data.near = J.anchor and J.anchor.name or nil -- the radius was around this player, not around me
    data.tool = J.tool and J.tool.name or nil
    if J.sweep and J.sweep.presses > 0 then data.presses, data.presses_on_move = J.sweep.presses, J.sweep.on_move end
    if J.collect_all then data.collect_all_presses = J.collect_all end
    -- everything else he picked up, named in the result, never silent: what a collect-all took from around the pile
    -- (it takes every kind within 2 m), or what came with the pick itself (a cabbage gives Cabbage Seeds, live 16:14Z)
    local also = M.also_gained(J)
    if #also > 0 then
        data.also = also
        local words = {}
        for _, a in ipairs(also) do words[#words + 1] = string.format("%d %s", a.count, a.name) end
        local w = table.concat(words, ", ")
        if type(data.detail) == "string" then
            data.detail = data.detail:gsub("%.%s*$", "") .. " (and " .. w .. (J.collect_all and " that were lying there)." or " with them).")
        end
    end
    -- log pieces left by the give_up_swings guard: said in the result, so the model and the truth judge see them
    if J.left and #J.left > 0 then
        data.left = J.left
        local groups, order = {}, {}
        for _, l in ipairs(J.left) do
            local g = groups[l.name]
            if not g then g = { name = l.name, n = 0, aims = l.aims, swings = l.swings }; groups[l.name] = g; order[#order + 1] = g end
            g.n = g.n + 1
        end
        local words = {}
        for _, g in ipairs(order) do
            words[#words + 1] = g.n == 1 and string.format("a %s that took no damage from any of my %d aims (%d swings)", g.name, g.aims, g.swings)
                or string.format("%d %ss that took no damage from any of my %d aims (%d swings each)", g.n, g.name, g.aims, g.swings)
        end
        local w = "I left " .. table.concat(words, ", and ") .. "."
        data.detail = type(data.detail) == "string" and (data.detail:gsub("%s*$", "") .. " " .. w) or w
    end
    data.phase_log = J.phase_log
    return { ok = ok, reason = reason, data = data }
end
M._result_of = result_of

local function set_phase(J, ph, why)
    if J.phase == ph then return end
    J.phase, J.phase_t = ph, J.t
    if ph == "aim" then J.faced_t = nil end
    J.phase_log[#J.phase_log + 1] = string.format("%.1f %s%s", (J.t or 0) - (J.t0 or 0), ph, why and (" " .. why) or "")
    if #J.phase_log > 40 then table.remove(J.phase_log, 1) end
    say(J.log, "phase " .. ph .. (why and (" (" .. why .. ")") or ""))
    if not J.status_t or (J.t or 0) - J.status_t >= 2 then
        J.status_t = J.t
        pcall(W.emit, { type = "gather_status", task_id = J.task_id, resource = J.key, phase = ph, detail = why })
    end
end

-- ------------------------------------------------------------------ gather spots (navmem: where it WORKED)
-- The live client's one navigation memory (_G.DW_NAVMEM, loaded by move.lua) holds them per world; the module code is
-- navmem.lua's own (pure). Tests replace W.navmem.
local NM_MOD
function W.navmem()
    if NM_MOD == nil then
        local okc, chunk = pcall(loadfile, ROOT .. "/client_mod/scripts/navmem.lua")
        local okm, mod = false, nil
        if okc and chunk then okm, mod = pcall(chunk) end
        NM_MOD = (okm and type(mod) == "table" and mod.add_gather_spot) and mod or false
    end
    local mem = NM_MOD and NM_MOD.shared()
    if not mem then return nil end
    return NM_MOD, mem
end
local function remember_spots(J)
    local g = J.spot_gain
    J.spot_gain = nil
    if not (J.item and g and #g > 0) then return end
    local NM, mem = W.navmem()
    if not NM then return end
    local name = (J.names or {})[J.item] or J.key
    for _, x in ipairs(g) do NM.add_gather_spot(mem, J.item, name, x.at, x.n) end
    NM.save(mem)
    say(J.log, string.format("remembered %d pick spot(s) of %s", #g, tostring(name)))
end
-- What he remembers of gathering this resource elsewhere (navmem), as one sentence for a "found none" result, or nil.
-- Matched by the job's item when known, else by the resource word (the profile key) against the remembered names.
local function known_spots(J)
    local NM, mem = W.navmem()
    if not NM then return nil end
    local key = tostring(J.key or ""):lower()
    local function match(g)
        if J.item then return g.item == J.item end
        return key ~= "" and (tostring(g.name or ""):lower():find(key, 1, true) ~= nil
            or tostring(g.item or ""):lower():find(key, 1, true) ~= nil)
    end
    local here = J.me and { J.me.X / 100, J.me.Y / 100 }
    local spots = NM.gather_spots(mem, match, here)
    return NM.gather_spot_text(spots, here, os.time(), { beyond_m = J.radius_cm and J.radius_cm / 100 })
end
M._known_spots = known_spots

local function finish(J, res)
    if J.done then return end
    J.done = true
    pcall(remember_spots, J)
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    if J.drove_move and not _G.DW_PAUSE then mcall("move", "stop", J.log) end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("end ok=%s reason=%s gained=%s/%s swings=%d hits=%d", tostring(res.ok), tostring(res.reason),
        tostring(J.gained), tostring(J.want), J.swings, J.hits))
end
M._finish = finish

local function fail(J, reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return finish(J, result_of(J, false, reason, d))
end

local function is_bad(key, t) local e = key and C().bad[key]; return e ~= nil and e > t end
-- a spot where another thing's prompt took the game's offer (water round a stone in a stream): its neighbours wait too
local function contested(pos, t)
    for _, x in ipairs(C().contested or {}) do
        if x.until_t > t and pos and math.sqrt((x.pos.X - pos.X) ^ 2 + (x.pos.Y - pos.Y) ^ 2) <= M.cfg.contested_cm then return x end
    end
end
M._contested = contested
local function mark_bad(J, T, why, no_streak) -- no_streak: left for what it is, not for something that went wrong
    local until_t = J.t + M.cfg.bad_ttl_s
    C().bad_why = C().bad_why or {}
    for _, k in ipairs({ T.key, T.alias }) do if k then C().bad[k] = until_t; C().bad_why[k] = why end end
    if not no_streak then J.bad_streak = (J.bad_streak or 0) + 1 end
    J.last_bad = why
    say(J.log, "target " .. tostring(T.key) .. " given up: " .. tostring(why))
end

-- Inventory count (bag + hotbar); learns the item of a pickup profile from the inventory delta.
local function refresh_count(J, force)
    if not force and J.t - (J.count_t or -99) < M.cfg.count_every_s then return end
    J.count_t = J.t
    local list = mcall("inventory", "list", J.log)
    if type(list) ~= "table" or list.ok == false then return end
    J.room, J.inv_list = M.pickup_room(list), list
    local now_counts = counts_of(list)
    J.now_counts, J.names = now_counts, J.names or {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, e in ipairs(list[where] or {}) do if e.item and e.name then J.names[e.item] = e.name end end
    end
    if not J.item and J.profile.item_match then
        for item in pairs(now_counts) do if item:find(J.profile.item_match) then J.item = item end end
    end
    if not J.item and J.learn_item then J.item = J.learn_item end
    if not J.item then
        -- a pickup of an unknown item: the first item whose count rose since the start is it
        for item, n in pairs(now_counts) do if n > (J.inv0[item] or 0) then J.item = item; break end end
    end
    if not J.item then return end
    local have = now_counts[J.item] or 0
    local gained = have - (J.inv0[J.item] or 0)
    if gained ~= J.gained then
        local sw = J.sweep -- presses this gain answers are no longer pending
        if sw then for _ = 1, math.max(0, gained - (J.gained or 0)) do table.remove(sw.pending, 1) end end
        if gained > (J.gained or 0) and J.me then -- where it worked: navmem's gather spots (saved when the job ends)
            J.spot_gain = J.spot_gain or {}
            J.spot_gain[#J.spot_gain + 1] = { at = { X = J.me.X, Y = J.me.Y, Z = J.me.Z }, n = gained - (J.gained or 0) }
        end
        J.gained, J.have = gained, have
        J.bad_streak, J.not_path_n = 0, nil
        pcall(W.emit, { type = "gather_progress", task_id = J.task_id, resource = J.key, item = J.item, have = math.max(gained, 0), want = J.want })
    end
    J.have = have
end

-- A pickup the game did not take while the bag reads full for the item (fresh read): the job ends inventory_full with
-- what fills the bag, never "interact had no effect" / nothing_in_range. true when it ended the job.
local function fail_if_full(J, item, at)
    refresh_count(J, true)
    item = item or J.item
    if not M.full_for(J.inv_list, item) then return false end
    local d = M.full_data(J.inv_list, item, (item and (J.names or {})[item]) or J.key, J.log, at)
    finish(J, result_of(J, false, "inventory_full", d))
    return true
end

-- A pickup sweep's presses not yet answered by a gain (the client's inventory lags a press by 0.4-1.2 s live) already
-- cover what is still wanted: pressing again (sweep or pick) would take one more than asked (rocks leg, 7 of 6). A press
-- with no gain within sweep_hold_s was a miss and stops counting.
local function sweep_owed(J)
    local sw = J.sweep_on and J.sweep
    if not (sw and J.want) then return false end
    while sw.pending[1] and J.t - sw.pending[1] > M.cfg.sweep_hold_s do table.remove(sw.pending, 1) end
    return (J.gained or 0) + #sw.pending >= J.want
end

-- ...then only recount (5 Hz) until the gains land or the presses expire: no new target, no extra press.
local function await_owed(J)
    if J.t - (J.owed_t or -9) >= 0.2 then J.owed_t = J.t; refresh_count(J, true) end
end

-- ------------------------------------------------------------------ target selection
-- T = {key, alias, kind = "actor"|"foliage"|"drop", stage, actor, pos (aim cm), attack, reach_cm,
--      name, tier, tool, at_site}
local function actor_target(J, a, stage, spec)
    local p = W.aim(a)
    if not p then return nil end
    local g = J.profile.mode == "chop" and W.gate(a) or nil
    return { key = W.id(a), kind = "actor", stage = stage, actor = a, pos = p, attack = spec.attack or "primary",
             reach_cm = spec.reach_cm or 130, name = W.class(a), tier = g and g.tier, tool = g and g.tool,
             hp0 = W.hp(a), max_hp = W.max_hp(a) }
end

local function children_near(J, center, radius_cm, me)
    local out = {}
    for _, ch in ipairs(J.profile.children or {}) do
        if not ch.bonus or J.stumps then
            for _, a in ipairs(W.actors(ch.class)) do
                local cls = W.class(a)
                local p = W.loc(a)
                if matches(cls, ch.match, ch.exclude) and p and U.dist2d(center, p) <= radius_cm and not is_bad(W.id(a), J.t) then
                    local hp = W.hp(a)
                    local ok = hp == nil or hp > 0
                    if ch.stump then ok = ok and W.stump(a) else ok = ok and not W.stump(a) end
                    if ok then
                        local T = actor_target(J, a, ch.name, ch)
                        if T then T.d = U.dist2d(me, T.pos); out[#out + 1] = T end
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
end

local function roots_near(J, me, radius_cm)
    local root = J.profile.root
    local out, actors_at = {}, {}
    J.floating = nil
    J.spent, J.aside = nil, nil -- what is there and can't be taken now: used up, or left earlier (and why)
    for _, a in ipairs(W.actors(root.class)) do
        local cls = W.class(a)
        local p = W.loc(a)
        local is_it = matches(cls, root.match, root.exclude)
            or (J.profile.mode == "pickup" and J.profile.item ~= nil and W.item_of(a) == J.profile.item)
        -- a profile with root.max_above_m never walks at a target hovering above walkable ground (rune essence
        -- floating over a geyser: it must be knocked down first; live audit 2026-10-26). "Above" is measured from
        -- the ground beside the thing, at the height his capsule centre would be standing there. Measured from
        -- where he stood, rocks lying on a rise 28 m off and 3.7 m higher were called "floating out of reach"
        -- and he was sent looking for a way to knock them down (live 2026-11-16, run 143506; he then walked up
        -- and mined one in 12 s). Ground that can't be read is not called floating: he walks, and the walk reports.
        local floating, above = false, nil
        if is_it and p and root.max_above_m and (p.Z - me.Z) > root.max_above_m * 100 and U.dist2d(me, p) <= radius_cm then
            J.ground = J.ground or {}
            local id = W.id(a)
            local g = J.ground[id]
            if g == nil then g = W.ground_near(p, M.cfg.ground_probe_cm); J.ground[id] = (g == nil) and "unread" or g end
            if g == false then floating = true
            elseif type(g) == "number" then
                above = p.Z - g
                floating = above - M.cfg.capsule_half_cm > root.max_above_m * 100
            end
        end
        if floating then
            J.floating = J.floating or {}
            J.floating[#J.floating + 1] = { id = W.id(a), pos = p, above_m = above and math.floor(above / 10) / 10 or nil }
            is_it = false
        end
        if is_it and p and U.dist2d(me, p) <= radius_cm then
            actors_at[#actors_at + 1] = p
            local hp = W.hp(a)
            local usable
            if J.profile.mode == "pickup" then usable = W.available(a)
            else usable = (hp == nil or hp > 0) and not W.stump(a) and not W.depleted(a) end
            if usable and not is_bad(W.id(a), J.t) and not contested(p, J.t) then
                local T = actor_target(J, a, "root", root)
                if T then
                    if J.profile.mode == "pickup" then T.item = W.item_of(a) end
                    T.d = U.dist2d(me, T.pos); out[#out + 1] = T
                end
            elseif J.profile.mode ~= "pickup" and not usable then
                local d = U.dist2d(me, p)
                J.spent = J.spent or { n = 0 }
                J.spent.n = J.spent.n + 1
                if not J.spent.nearest_cm or d < J.spent.nearest_cm then J.spent.nearest_cm = d end
            elseif J.profile.mode ~= "pickup" and is_bad(W.id(a), J.t) then
                J.aside = J.aside or {}
                J.aside[#J.aside + 1] = { id = W.id(a), why = (C().bad_why or {})[W.id(a)] }
            end
        end
    end
    if root.foliage then
        local kinds = J.profile.mode == "pickup" and { pickup = true } or { tree = true }
        for _, r in ipairs(W.foliage(me, radius_cm, { match = root.match, exclude = root.exclude, kinds = kinds })) do
            local dup = false
            for _, p in ipairs(actors_at) do if U.dist2d(p, r._pos) < M.cfg.adopt_cm then dup = true end end
            if not dup and not is_bad(r.id, J.t) and not contested(r._pos, J.t) then
                out[#out + 1] = { key = r.id, kind = "foliage", stage = "root", pos = r._pos, attack = root.attack or "primary",
                                  reach_cm = root.reach_cm or 130, name = r.name, tier = r.tool_tier, tool = r.tool,
                                  d = U.dist2d(me, r._pos), max_hp = r.max_health, class = r.class, item = r.item }
            end
        end
    end
    -- nearest first, but a target well above or below his level counts as further (a ledge needs a way up:
    -- prefer the sticks at his feet over the ones on a rock 4 m up, live 2026-10-26 16:05)
    local function score(x)
        local dz = (x.pos and x.pos.Z and me.Z) and math.abs((x.pos.Z + 90) - me.Z) or 0
        return x.d + 3 * math.max(0, dz - M.cfg.stand_dz_cm)
    end
    table.sort(out, function(x, y) return score(x) < score(y) end)
    return out
end
M._roots_near = roots_near

local function drops_near(J, center, radius_cm, me)
    local out = {}
    for _, d in ipairs(W.drops(center, radius_cm, J.item)) do
        if not is_bad(d.key, J.t) and (J.item or J.profile.mode == "pickup") then
            out[#out + 1] = { key = d.key, kind = "drop", actor = d.actor, pos = d.pos, d = U.dist2d(me, d.pos), item = d.item, n = tonumber(d.count) or 1 }
        end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    return out
end

-- Next thing to do: drops of our item near our sites/us, then pieces of our felled trees, then the
-- nearest standing root (actor or foliage) within the radius. Returns T or nil, why.
local function choose(J, me)
    local cfg = M.cfg
    -- 1. drops (ours: near a site we broke, or right next to us)
    if J.item then
        for _, s in ipairs(J.sites) do
            local d = drops_near(J, s, J.profile.collect_radius_cm or 1200, me)[1]
            if d then return d end
        end
        local d = drops_near(J, me, 400, me)[1]
        -- (a pickup takes a drop whole: a stack bigger than the count still wanted waits for the spawners, below)
        if d and not (J.profile.mode == "pickup" and J.want and d.n > J.want - (J.gained or 0)) then return d end
    end
    -- 2. pieces of our felled trees (current site first), and of the piece named in args.target
    for i = #J.sites, 1, -1 do
        local s = J.sites[i]
        if s.named or U.dist2d(me, s) <= cfg.leftover_m * 100 then
            local ch = children_near(J, s, s.named and 400 or J.profile.site_radius_cm or 1200, me)[1]
            if ch then ch.at_site = s; return ch end
        end
    end
    if J.named then return nil, "named_done" end -- args.target: that piece and what it split into are done
    -- 3. a new root (around the player named in args.near when given: "the stones near me", said by him)
    local roots = roots_near(J, J.anchor and J.anchor.pos or me, J.radius_cm)
    if J.sweep_on and J.profile.mode == "pickup" then
        -- pickups: skip the ones just pressed (taken, or the game is still removing them), and walk the nearest few
        -- as ONE path (the next is its first stop), as a player sweeps a patch instead of zig-zagging nearest-first
        local sw, keep = J.sweep, {}
        for _, T in ipairs(roots) do
            local p = sw and (sw.pressed[T.key] or (T.alias and sw.pressed[T.alias]))
            if not (p and J.t - p.t < cfg.sweep_hold_s) then keep[#keep + 1] = T end
        end
        roots = M.path_order(me, keep, math.min(cfg.path_k, math.max(1, (J.want or 1) - (J.gained or 0))))
    end
    if J.profile.mode == "pickup" and J.item then
        -- a pile of the item lying in the radius is a pickup too (one collect-all press may take it all): the nearer of
        -- it and the next spawner goes first (live 15:52Z: a pile 5 m away was passed for a stone 13.6 m away)
        -- a pickup takes a stack whole: one that fits what is still wanted first, a bigger one only when nothing else
        -- gives the item (live 04:27Z: count 3 by stacks of 10, 10 and 1 took a 10 first, 11 in all)
        local need = J.want and math.max(1, J.want - (J.gained or 0)) or math.huge
        local fits, big = nil, nil
        for _, x in ipairs(drops_near(J, me, J.radius_cm, me)) do
            if x.n <= need then fits = fits or x else big = big or x end
        end
        local dr = fits
        if dr and (not roots[1] or dr.d <= (roots[1].d or U.dist2d(me, roots[1].pos))) then return dr end
        if big and not roots[1] then return big end
    end
    local too_hard
    for _, T in ipairs(roots) do
        if J.tool and T.tier and T.tier > J.tool.tier then too_hard = too_hard or T
        else return T end
    end
    if too_hard then return nil, "tool_tier_too_low", too_hard end
    if J.floating and #J.floating > 0 then return nil, "floating_only", J.floating end
    return nil, "no_resource_nearby"
end
M._choose = choose

-- ------------------------------------------------------------------ phases
local function tap(J, action, frames)
    if not action then return false end
    J.inputs[#J.inputs + 1] = { act = action, frames = frames or M.cfg.tap_frames }
    return true
end

local function start_move(J, goal_cm, tol_m, timeout_s, local_plan, nav, stall_s)
    J.drove_move = true
    local me = J.me
    local far = me and U.dist2d(me, goal_cm) > 1200
    local r = mcall("move", "go_to", J.log, { goal_cm.X / 100, goal_cm.Y / 100, goal_cm.Z / 100 },
        { tolerance_m = tol_m, timeout_s = timeout_s or M.cfg.approach_timeout_s, sprint = far, owner_token = J.token,
          local_plan = local_plan, nav = nav, progress = stall_s and { stall_s = stall_s } or nil })
    J.move_started, J.move_from, J.move_args = J.t, me and { X = me.X, Y = me.Y, Z = me.Z }, { goal_cm, tol_m, timeout_s, local_plan, stall_s }
    J.move_d0 = me and U.dist2d(me, goal_cm) or nil
    J.nav_off = (nav == false) or nil -- a fresh move may wait for a route again
    return r and r.ok ~= false
end

-- Still waiting for a route with no step taken (move status "planning") after route_wait_s: walk by sight instead
-- (move's own nav=false: local planner on real collision, drop-guarded), once per move. -> true when restarted
local function route_wait_over(J, st)
    if J.nav_off or not (st and st.status == "planning") or J.t - (J.move_started or J.t) < M.cfg.route_wait_s then return false end
    if J.me and J.move_from and U.dist2d(J.me, J.move_from) > 100 then return false end
    local a = J.move_args
    if not a then return false end
    say(J.log, string.format("no route after %.0f s standing; walking by sight", J.t - (J.move_started or J.t)))
    mcall("move", "stop", J.log)
    return start_move(J, a[1], a[2], a[3], a[4], false, a[5])
end

-- The walk is not getting closer, by move's shared watchdog (status().progress, no gain for its stall_s): the
-- approach ends now, with that verdict's reason, and not at approach_timeout_s. Quest chain 094732 (2026-11-16
-- 09:51Z): 41 s on one branch under a rock, 29 of them after the watchdog said "stalled"; 6 sticks took 84.9 s.
local function walk_stalled(J, st)
    local pv = st and type(st.progress) == "table" and st.progress or nil
    if not (pv and pv.verdict == "stalled") then return false end
    say(J.log, string.format("approach stalled (%s, %.0f s without getting closer); giving this one up", tostring(pv.why), tonumber(pv.since_s) or 0))
    mcall("move", "stop", J.log)
    J.moving = false
    return true
end

local function move_state()
    local st = mcall("move", "status")
    if type(st) ~= "table" then return "idle", nil end
    if st.mode == "go_to" then return "moving", st end
    return "idle", st
end

-- stand point: reach_cm from the aim point, on our side, rotated by deg around the target. Its height is the
-- TARGET's ground (pos is on the ground for pickups/foliage; + capsule half height) when that differs from ours
-- by more than a step: live 2026-10-26 16:05, branches on a ledge 4 m up were sent as a goal at Claude's own
-- height, so move planned a level walk under the ledge and could not say "it's higher than I can jump".
M.cfg.stand_dz_cm = 150
local function stand_point(T, me, deg)
    local ang = math.atan(me.Y - T.pos.Y, me.X - T.pos.X) + math.rad(deg or 0)
    local r = math.max((T.reach_cm or 130) - 15, 60)
    local z = me.Z
    if T.pos.Z and math.abs((T.pos.Z + 90) - me.Z) > M.cfg.stand_dz_cm then z = T.pos.Z + 90 end
    return { X = T.pos.X + math.cos(ang) * r, Y = T.pos.Y + math.sin(ang) * r, Z = z }
end
M._stand_point = stand_point

-- The swing has a height as well as a depth. A tool's damage shape covers a band about his middle (stone pickaxe: a
-- box 100 cm tall, so 40 to 140 cm over his feet; hatchet: a wedge 200 cm tall) and stays level whatever the camera
-- does. A rock set in a rise is under that band from its high side: live 2026-11-16, runs 154701 and 155233, 27
-- swings each at ..._1366033383 from ground level with its top, hp 60 throughout; probe ClaudeP161704 held the camera
-- at -71 deg for 27 more, nothing. So for a rock or tree whose bounds and whose tool's swing can both be read, the
-- stand is the nearest place round it where the floor puts the thing inside the swing.
M.cfg.band_overlap_cm = 15 -- this much of the thing inside the band counts as covered (bounds are a box, a rock is not)
M.cfg.stand_offsets = { 0, 45, -45, 90, -90, 135, -135, 180 } -- places round it, his own side first
M.cfg.overhang_cm = 300    -- a "floor" this far over the thing's top is a branch or a roof, not where he would stand
local function swing_band(J, T)
    if T.kind ~= "actor" or T.stage ~= "root" or (T.attack or "primary") ~= "primary" then return nil end
    if J.band == nil then
        J.band = W.swing_band(((J.tool_profile or {}).prim or {}).action) or false
        if J.band then
            say(J.log, string.format("my %s's swing covers %.0f to %.0f cm about my middle", J.tool and J.tool.name or "tool", J.band.lo, J.band.hi))
        end
    end
    return J.band or nil
end
-- How much of the thing the swing covers with his middle at mid_z: cm of the band inside the thing's bounds (zero or
-- less: it passes over or under by that much), its bounds, and which way it misses. nil when either can't be read.
local function swing_overlap(J, T, mid_z)
    local band = swing_band(J, T)
    local box = band and W.bounds(T.actor) or nil
    if not box then return nil end
    local bottom, top = box.mid.Z - box.half.Z, box.mid.Z + box.half.Z
    return math.min(mid_z + band.hi, top) - math.max(mid_z + band.lo, bottom), box, (mid_z + band.lo >= top) and "below_swing" or "above_swing"
end
-- which of eight places round the thing a point is at
local function stand_key(T, p) return math.floor(math.deg(math.atan(p.Y - T.pos.Y, p.X - T.pos.X)) / 45 + 0.5) % 8 end
-- Where to stand for a swing: stand_point, and when the swing's height and the thing's bounds are known, the first
-- place round it (from `deg` off his own side) whose floor puts the thing inside the swing; failing that, the place
-- with the most of it inside. Places he already swung from with no effect (T.stands) are not offered again.
-- -> goal, note (nil for his own side)  |  nil, why: "below_swing" / "above_swing" (the swing passes over / under it
--    from every place beside it) or "swing_no_effect" (every place that could reach it was tried).
local function stand_for(J, T, me, deg)
    local base = stand_point(T, me, deg)
    local _, box = swing_overlap(J, T, me.Z)
    if not box then return base end
    local half, top = M.cfg.capsule_half_cm, box.mid.Z + box.half.Z
    local tried_all = T.stands or {}
    local best, best_ov, best_off, near_ov, near_way, tried, unread
    for _, off in ipairs(M.cfg.stand_offsets) do
        local p = stand_point(T, me, deg + off)
        local f
        -- (a point over the thing itself reads the thing, not the floor beside it)
        if math.abs(p.X - box.mid.X) > box.half.X or math.abs(p.Y - box.mid.Y) > box.half.Y then
            f = W.floor_at({ X = p.X, Y = p.Y, Z = top })
            if f and f > top + M.cfg.overhang_cm then f = nil end
        end
        if f == nil then
            if off == 0 then return base end -- his own side can't be read: as before, the swings tell
            unread = true
        elseif f then
            local ov, _, way = swing_overlap(J, T, f + half)
            if not near_ov or ov > near_ov then near_ov, near_way = ov, way end
            if tried_all[stand_key(T, p)] then tried = true
            elseif ov >= M.cfg.band_overlap_cm then
                if off == 0 then return base end
                p.Z = f + half
                say(J.log, string.format("standing %d deg round it, where my swing covers %.0f cm of it", off, ov))
                return p, "by_height"
            elseif ov > 0 and (not best_ov or ov > best_ov) then
                best, best_ov, best_off = { X = p.X, Y = p.Y, Z = f + half }, ov, off
            end
        end
    end
    if best then
        say(J.log, string.format("standing %d deg round it: only %.0f cm of it is inside my swing there, the most from any side", best_off, best_ov))
        return best, "by_height"
    end
    if tried then return nil, "swing_no_effect" end
    if unread then return base end -- some places beside it could not be read: not called out of the swing's reach
    say(J.log, string.format("target %s: my swing passes %s it from every side (nearest %.0f cm)", tostring(T.key),
        near_way == "below_swing" and "over" or "under", near_ov and -near_ov or 0))
    return nil, near_way or "below_swing"
end
M._stand_for = stand_for

-- The foliage instance we walked to became an actor (the server's converter / our swing): adopt it.
-- Pickups: the NEAREST matching actor within pick_adopt_cm. Stones and branches lie 0.5-2 m apart, so "the first one
-- within 2 m" adopted a neighbour (live 2026-11-01 14:08Z: the press took the real one, the adopted neighbour was then
-- faced for 8 s and given up).
M.cfg.pick_adopt_cm = 100
local function adopt(J, T)
    if T.kind ~= "foliage" then return false end
    local root = J.profile.root
    local pick = J.profile.mode == "pickup"
    local best, bd
    if pick then
        for _, a in ipairs(W.actors(root.class)) do
            local p = W.loc(a)
            local dd = p and U.dist2d(p, T.pos)
            if dd and dd < M.cfg.pick_adopt_cm and (not bd or dd < bd) and matches(W.class(a), root.match, root.exclude) then best, bd = a, dd end
        end
    end
    for _, a in ipairs(best and { best } or (pick and {} or W.actors(root.class))) do
        local p = W.loc(a)
        if p and U.dist2d(p, T.pos) < M.cfg.adopt_cm and matches(W.class(a), root.match, root.exclude) then
            T.kind, T.actor, T.alias = "actor", a, T.key
            T.key = W.id(a)
            T.pos = W.aim(a) or T.pos
            T.hp0 = W.hp(a)
            T.max_hp = W.max_hp(a) or T.max_hp
            local g = J.profile.mode == "chop" and W.gate(a) or nil
            if g then T.tier, T.tool = g.tier or T.tier, g.tool or T.tool end
            if J.profile.mode == "pickup" then J.learn_item = J.learn_item or W.item_of(a); T.item = W.item_of(a) end
            say(J.log, "adopted " .. tostring(T.key) .. " (was " .. tostring(T.alias) .. ") hp=" .. tostring(T.hp0))
            return true
        end
    end
    return false
end

-- Is the target finished? -> true, how
local function target_done(J, T)
    if T.kind == "drop" then return not W.alive(T.actor), "collected" end
    if T.kind ~= "actor" then return false end
    if not W.alive(T.actor) then
        if T.alias and (T.hits or 0) == 0 then
            -- an undamaged converted tree reverts to foliage after a while: chase the instance again
            T.kind, T.key, T.actor, T.alias = "foliage", T.alias, nil, nil
            return false
        end
        -- log pieces are destroyed when they break: gone right after our hits = broken by us
        if (T.hits or 0) > 0 then return true, "broken" end
        return true, "gone"
    end
    if J.profile.mode == "pickup" then return not W.available(T.actor), "picked" end
    if T.stage == "root" and J.profile.root.class == "FellableTree" then
        if W.stump(T.actor) then return true, "felled" end
    end
    local hp = W.hp(T.actor)
    if hp and hp <= 0 then return true, "broken" end
    if W.depleted(T.actor) then return true, "depleted" end
    return false
end

local function on_done(J, T, how)
    local c = C()
    J.T = nil
    J.moving = false
    if how == "gone" then return set_phase(J, "scan", "target vanished") end -- not ours to count
    J.bad_streak = 0
    if T.kind ~= "drop" then -- never pick the same (now empty / stump) thing again
        for _, k in ipairs({ T.key, T.alias }) do if k then c.bad[k] = J.t + M.cfg.bad_ttl_s end end
    end
    if T.kind == "drop" then
        c.counts.collected = c.counts.collected + 1
        J.collected = (J.collected or 0) + 1
        refresh_count(J, true)
        return set_phase(J, "scan", "collected")
    end
    J.broken = J.broken + 1
    c.counts.broken = c.counts.broken + 1
    J.targets = J.targets + 1
    local at = W.loc(T.actor) or T.pos
    local pickup = J.sweep_on and J.profile.mode == "pickup"
    -- a picked bush / branch drops nothing to wait for: no site, no drop wait (it cost 1.2 s per item)
    if T.stage == "root" and at and not pickup then J.sites[#J.sites + 1] = { X = at.X, Y = at.Y, Z = at.Z } end
    say(J.log, string.format("%s %s (%s)", tostring(T.key), how, T.stage))
    if T.stage == "root" and J.profile.settle then
        J.settle_t = J.t
        return set_phase(J, "settle", how)
    end
    if not pickup then J.wait_until = J.t + M.cfg.drop_wait_s end
    refresh_count(J, true)
    return set_phase(J, "scan", how)
end

local function step_equip(J, pawn)
    if not J.tool then return true end
    local inv = mod("inventory")
    local h = (inv and inv.held and U.try(inv.held, pawn)) or {}
    local want = J.tool.entry.item
    if h.right_item == want or h.left_item == want then return true end
    if J.t - J.phase_t > M.cfg.equip_wait_s then
        return fail(J, "wrong_tool", "equip_failed", string.format("I tried to take out my %s but it didn't come out.", J.tool.name or want))
    end
    if not J.equip_sent or J.t - J.equip_sent > M.cfg.equip_repress_s then
        J.equip_sent = J.t
        local r = mcall("inventory", "equip", J.log, want)
        say(J.log, "equip " .. tostring(want) .. " -> " .. tostring(r and (r.via or r.reason)))
    end
    return false
end

local function step_scan(J, me)
    -- the drops of what just broke are taken as soon as one lies there (a player doesn't stand and wait them out:
    -- rung 3 mine 2026-11-16, 1.3 s from "broken" to the pick-up every time); anything else waits for the rest to land
    local early = J.t < (J.wait_until or 0)
    if early then
        local s = J.item and J.sites[#J.sites]
        if not (s and drops_near(J, s, J.profile.collect_radius_cm or 1200, me)[1]) then return end
    end
    refresh_count(J)
    if J.done then return end
    if J.item and (J.gained or 0) >= J.want then return end -- the frame ends it
    if J.profile.mode == "pickup" and sweep_owed(J) then return await_owed(J) end
    local T, why, hard = choose(J, me)
    if early and not (T and T.kind == "drop") then return end
    if T then
        J.T = T
        T.side, T.aim_i, T.noeff, T.presses, T.g0 = 0, 1, 0, 0, J.gained or 0
        if J.profile.mode == "pickup" and T.item then J.learn_item = J.learn_item or T.item end
        J.radius_tries = 0
        if T.kind == "drop" then return set_phase(J, "collect", T.key) end
        return set_phase(J, "approach", string.format("%s %s %.1f m", T.stage, tostring(T.name), (T.d or 0) / 100))
    end
    -- nothing left to do: the bag is counted now, not up to count_every_s ago (the magnet may just have brought the
    -- last drop in; the frame ends the job when the count is there)
    refresh_count(J, true)
    if J.done or (J.item and (J.gained or 0) >= J.want) then return end
    if why == "named_done" then
        return finish(J, result_of(J, true, nil, { why = "target_done", detail = string.format(
            "The %s is chopped up and I picked up the pieces: %d %s.", J.named, J.gained or 0, tostring(J.key)) }))
    end
    if why == "tool_tier_too_low" then
        return fail(J, "wrong_tool", "tool_tier_too_low",
            string.format("The %s here needs a tier %d %s; my best is my %s (tier %d).", tostring(hard.name), hard.tier,
                tool_word(J.profile), J.tool.name or "?", J.tool.tier), { need_tier = hard.tier, have_tier = J.tool.tier })
    end
    if why == "floating_only" then
        local f = hard[1]
        return fail(J, "nothing_in_range", "floating_only", string.format(
            "The only %s near me is floating out of reach (%d of them, the nearest %s): it has to be knocked down first, then I can mine it.",
            J.key, #hard, f.above_m and string.format("%.0f m above the ground under it", f.above_m) or "with no ground under it"), { floating = hard })
    end
    -- nothing: widen, then give up (around a named player only up to near_max_radius_m: "near me" stays near him)
    local cap = J.max_radius_cm or M.cfg.max_radius_m * 100
    if J.radius_cm < cap then
        J.radius_cm = math.min(J.radius_cm * M.cfg.widen, cap)
        say(J.log, "nothing in range; widening to " .. math.floor(J.radius_cm / 100) .. " m")
        return
    end
    local of = J.anchor and J.anchor.name or "me"
    local okk, known = pcall(known_spots, J)
    known = okk and known or nil
    local tail = known and (" " .. known) or ""
    if (J.contested or 0) > 0 then
        tail = string.format(" Some lie where the game offers %s instead, so I can't pick those (%d spot%s).", tostring(J.contested_what),
            J.contested, J.contested == 1 and "" or "s") .. tail
    end
    -- What is there and can't be taken now is said, not "I can't find any" (live 2026-11-16, runs 154701 to 155833:
    -- with every essence rock around mined out and one left after 27 swings that did nothing, the result read
    -- "I can't find any rune_essence within 90 m"; look showed the rocks, and he took it for a fault of his tool).
    local parts, extra = {}, { known_spots = known }
    if J.spent and J.spent.n > 0 then
        extra.used_up, extra.used_up_nearest_m = J.spent.n, math.floor(J.spent.nearest_cm / 100 + 0.5)
        parts[#parts + 1] = string.format("%d there %s used up for now (the nearest %d m away)", J.spent.n, J.spent.n == 1 and "is" or "are",
            extra.used_up_nearest_m)
    end
    if J.aside and #J.aside > 0 then
        extra.left_alone = J.aside
        local noeff, low, high = 0, 0, 0
        for _, x in ipairs(J.aside) do
            if x.why == "swing_no_effect" then noeff = noeff + 1
            elseif x.why == "below_swing" then low = low + 1
            elseif x.why == "above_swing" then high = high + 1 end
        end
        if noeff > 0 then
            parts[#parts + 1] = string.format("%d took no damage from any swing I tried, so I left %s", noeff, noeff == 1 and "it" or "them")
        end
        -- (stand_for: the tool's swing passes over or under it from every place beside it)
        for _, v in ipairs({ { low, "low" }, { high, "high" } }) do
            if v[1] > 0 then
                parts[#parts + 1] = string.format("%d %s too %s for my %s to hit from anywhere I can stand beside %s", v[1],
                    v[1] == 1 and "sits" or "sit", v[2], J.tool and J.tool.name or "tool", v[1] == 1 and "it" or "them")
            end
        end
        local rest = #J.aside - noeff - low - high
        if rest > 0 then parts[#parts + 1] = string.format("%d I couldn't get to or use just now", rest) end
    end
    if #parts > 0 then
        local what = table.concat(parts, ", and ") .. "."
        if (J.gained or 0) > 0 then
            return fail(J, "nothing_in_range", "no_resource_nearby", string.format("I got %d but there's no more %s I can take within %d m of %s: %s",
                J.gained, J.key, math.floor(J.radius_cm / 100), of, what) .. tail, extra)
        end
        return fail(J, "nothing_in_range", "no_resource_nearby", string.format("There's no %s I can take within %d m of %s: %s", J.key,
            math.floor(J.radius_cm / 100), of, what) .. tail, extra)
    end
    if (J.gained or 0) > 0 then
        return fail(J, "nothing_in_range", "no_resource_nearby", string.format("I got %d but there's no more %s within %d m of %s.",
            J.gained, J.key, math.floor(J.radius_cm / 100), of) .. tail, extra)
    end
    return fail(J, "nothing_in_range", "no_resource_nearby", string.format("I can't find any %s within %d m of %s.", J.key,
        math.floor(J.radius_cm / 100), of) .. tail, extra)
end

-- a thing no swing hurt is left; three of them in a row end the job
local function leave_unhurt(J, T)
    mark_bad(J, T, "swing_no_effect")
    J.T = nil
    J.moving = false
    if J.bad_streak >= M.cfg.bad_streak then
        return fail(J, "path_blocked", "swing_no_effect", string.format(
            "My %s swings aren't hurting the %s; I tried %d different ones.", J.tool and J.tool.name or "tool", tostring(J.key), J.bad_streak))
    end
    return set_phase(J, "scan", "swing_no_effect")
end

local approach_failed -- (J, T, st, res): below, shared with step_sweep
local function step_approach(J, pawn, me)
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local d = U.dist2d(me, T.pos)
    local reach = T.reach_cm or 130
    -- Near enough already: swing from here. Not while he is walking to a stand chosen for a reason (T.to_stand: the
    -- other side, or the side the swing reaches it from; before, a walk to the other side was stopped on its first
    -- tick because he was still within reach, so "the other side" was the same side), and not from a floor where the
    -- swing passes over or under the thing.
    if d <= reach + 10 and not T.reposition and not T.to_stand then
        local ov = not T.stood and swing_overlap(J, T, me.Z) or nil
        if not ov or ov >= M.cfg.band_overlap_cm then
            mcall("move", "stop", J.log)
            J.moving = false -- the walk is over: the next target's approach starts its own
            return set_phase(J, "aim", string.format("%.2f m", d / 100))
        end
    end
    if not J.moving then
        local rep = T.reposition
        local goal, note = stand_for(J, T, me, rep or 0)
        T.reposition = nil
        if not goal then
            if note == "swing_no_effect" then return leave_unhurt(J, T) end
            mark_bad(J, T, note, true) -- no swing spent on it; the result says how many were left this way
            J.T = nil
            return set_phase(J, "scan", note)
        end
        if not start_move(J, goal, 0.35) then
            mark_bad(J, T, "move refused")
            J.T = nil
            return set_phase(J, "scan", "move refused")
        end
        J.moving = true
        T.to_stand = (rep ~= nil or note ~= nil) or nil
        return
    end
    local ms, st = move_state()
    if ms == "moving" and route_wait_over(J, st) then return end
    if ms == "moving" and walk_stalled(J, st) then return approach_failed(J, T, st, {}) end
    if ms == "moving" and J.t - (J.move_started or J.t) <= M.cfg.approach_timeout_s + 5 then return end
    J.moving = false
    T.to_stand = nil
    local res = st and st.result or {}
    -- "close" is 2D; a target far above or below him (a ledge) is not in reach from under it
    local level = not (T.pos.Z and math.abs((T.pos.Z + 90) - me.Z) > M.cfg.stand_dz_cm)
    if res.status == "arrived" or (level and d <= reach + M.cfg.near_enough_cm) then
        T.stood = true -- the stand was chosen and walked to: swing from it, whatever the floor turned out to be
        return set_phase(J, "aim", string.format("%.2f m", d / 100))
    end
    return approach_failed(J, T, st, res)
end

-- ------------------------------------------------------------------ sweep (pickup mode): pick up on the move
-- Luis's recorded run (docs/BASELINES-2026-11-01-luis.md): 85 of his 97 pickup presses were made WHILE MOVING, about
-- one item a second in a cluster: he runs through the patch and presses E as each item comes under the prompt (the
-- game's detector offers a ground item 1-2.5 m ahead, recorder press distances). Claude did the opposite: walk to a
-- stand point, stop, look, press, wait (2.3 s an item, standing, live 2026-11-01 12:50). So pickup mode walks the
-- cluster as one path (path_order), never stops for a target, presses E whenever the game's own detector highlights a
-- thing of the wanted kind (the target or any other on the way), goes for the next one the moment the game reads it
-- taken, and stops to face a target only when it reached one the game never offered on the way (the old pick phase).
M.cfg.sweep = true
M.cfg.sweep_press_gap_s = 0.2 -- between two presses (Luis: 0.14-0.6 s apart in a dense patch)
M.cfg.sweep_repress_s = 1.0   -- the same thing is not pressed again sooner (a just-taken item lingers client-side)
M.cfg.sweep_hold_s = 2.5      -- a pressed thing is no next target this long (taken: it goes; a miss: it comes back)
M.cfg.sweep_stall_s = 6       -- a ground item he gets no closer to for this long is given up (move's default is 12 s)
M.cfg.sweep_arrive_m = 0.5    -- walk at the thing itself; reaching it this close without an offer = stop and face
M.cfg.sweep_direct_m = 10     -- hops shorter than this walk straight (move's local planner stands ~1 s per plan)
M.cfg.sweep_count_s = 0.4     -- re-count the inventory this soon after a press
M.cfg.creep_m = 1.3           -- closer than this: face it and creep (movement input at creep_scale), no go_to
M.cfg.creep_scale = 0.5
M.cfg.creep_s = 1.5           -- creeping this long without an offer: stop and face it (pick)
M.cfg.pick_budget_s = 4       -- pick (stopped, facing it) this long without an offer: give it up (was 8 s)
M.cfg.other_prompt_s = 1.2    -- another thing's prompt this long beside the target: the game won't offer it there
M.cfg.other_prompt_cm = 200
M.cfg.contested_cm = 300      -- a target this close to such a spot is skipped while it is remembered
M.cfg.path_k = 8              -- the nearest this many are ordered as one path

-- Shortest open path from `me` through the first k of pts (each with .pos; fixed start, open end), exact by Held-Karp
-- dynamic programming over subsets (k <= 8: 2^8 x 8 x 8 steps, well under a millisecond). Nearest-neighbour + 2-opt
-- was the first try and kept a 2-opt local optimum that zig-zags (near-east, far-east, back past the start to the
-- west); a small set is solved exactly instead (sources in DISCOVERIES "Pick up on the move"). Returns the k ordered,
-- then the rest in their given order. Pure.
function M.path_order(me, pts, k)
    k = math.min(k or #pts, #pts, 10)
    if k < 2 then return pts end
    -- metres on the ground, plus roots_near's penalty for a change of level (a ledge needs a way up); `me` is the
    -- capsule centre, a target's pos its ground (+90)
    local function z(a) return a.pos and a.pos.Z and (a.pos.Z + 90) or a.Z end
    local function d(a, b)
        local za, zb = z(a), z(b)
        local dz = (za and zb) and math.abs(za - zb) or 0
        return U.dist2d(a.pos or a, b.pos or b) + 3 * math.max(0, dz - M.cfg.stand_dz_cm)
    end
    local D, D0 = {}, {}
    for i = 1, k do
        D0[i], D[i] = d(me, pts[i]), {}
        for j = 1, k do D[i][j] = d(pts[i], pts[j]) end
    end
    local full = (1 << k) - 1
    local dp, par = {}, {}
    for m = 1, full do dp[m], par[m] = {}, {} end
    for i = 1, k do dp[1 << (i - 1)][i] = D0[i] end
    for m = 1, full do
        local row = dp[m]
        for j = 1, k do
            local c = row[j]
            if c then
                for n = 1, k do
                    local bit = 1 << (n - 1)
                    if m & bit == 0 then
                        local m2, c2 = m | bit, c + D[j][n]
                        local old = dp[m2][n]
                        if not old or c2 < old then dp[m2][n], par[m2][n] = c2, j end
                    end
                end
            end
        end
    end
    local bj, bc
    for j = 1, k do local c = dp[full][j]; if c and (not bc or c < bc) then bj, bc = j, c end end
    local rev, m, j = {}, full, bj
    while j do
        rev[#rev + 1] = pts[j]
        local pj = par[m][j]
        m, j = m & ~(1 << (j - 1)), pj
    end
    local path = {}
    for i = #rev, 1, -1 do path[#path + 1] = rev[i] end
    for i = k + 1, #pts do path[#path + 1] = pts[i] end
    return path
end

-- Is what the game's detector highlights a thing this job wants? The target itself, a world item / spawner of the
-- counted item, or (item still unknown) the profile's own class match.
local function wanted(J, tg)
    if type(tg) ~= "table" or tg.none or not tg.actor then return false end
    local T = J.T
    if T and (tg.actor == T.key or tg.actor == T.alias) then return true end
    if J.item and tg.item then return tg.item == J.item end
    local root = J.profile.root
    return root.match ~= nil and matches(tg.class, root.match, root.exclude)
end
M._wanted = wanted

-- Press E on the move when the prompt is on a wanted thing (no stop). -> the detector row pressed, or nil.
local function sweep_press(J, pawn)
    local sw, cfg = J.sweep, M.cfg
    if J.t - (sw.last_t or -9) < cfg.sweep_press_gap_s then return nil end
    local tg = mcall("inventory", "interact_target", pawn)
    if not wanted(J, tg) then
        if type(tg) == "table" and tg.actor and not sw.seen[tg.actor] then
            sw.seen[tg.actor] = true
            say(J.log, string.format("prompt on %s %s (%s): not a %s", tostring(tg.class), tostring(tg.actor), tostring(tg.prompt), tostring(J.key)))
        end
        return nil
    end
    local prev = sw.pressed[tg.actor]
    if prev and (J.t - prev.t < cfg.sweep_repress_s or prev.n >= cfg.collect_presses) then return nil end
    if sweep_owed(J) then return nil end
    sw.pressed[tg.actor] = { t = J.t, n = (prev and prev.n or 0) + 1 }
    sw.last_t, sw.presses = J.t, sw.presses + 1
    sw.pending[#sw.pending + 1] = J.t
    if J.moving then sw.on_move = sw.on_move + 1 end
    mcall("inventory", "press_interact", J.log)
    J.count_t = math.min(J.count_t or J.t, J.t - cfg.count_every_s + cfg.sweep_count_s)
    say(J.log, string.format("press %s (%s)%s", tostring(tg.actor), tostring(tg.prompt), J.moving and " on the move" or ""))
    return tg
end

local function step_sweep(J, pawn, me)
    local T, cfg = J.T, M.cfg
    adopt(J, T)
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local tg = sweep_press(J, pawn)
    if tg and (tg.actor == T.key or tg.actor == T.alias) then T.press_t, T.presses = J.t, (T.presses or 0) + 1 end
    if (T.presses or 0) >= cfg.collect_presses and J.t - T.press_t > cfg.sweep_repress_s then
        -- the bag first: a pile the game refused for want of room is not a bad target (it stays for after a store)
        local full = fail_if_full(J, J.item or T.item, "sweep")
        if full then return end
        mark_bad(J, T, "interact had no effect")
        J.T = nil
        return set_phase(J, "scan", "interact no effect")
    end
    local d = U.dist2d(me, T.pos)
    local level = not (T.pos.Z and math.abs((T.pos.Z + 90) - me.Z) > cfg.stand_dz_cm)
    if level and d <= cfg.creep_m * 100 and not (T.press_t and J.t - T.press_t < cfg.sweep_repress_s) then
        -- close: no go_to (a straight go_to this short stood still ~3.5 s, live 14:08:45Z; move's waypoint radius is
        -- 1.2 m): face it and creep at it, as a player takes the last step, until the game offers it
        if J.moving then
            local ms = move_state()
            if ms == "moving" then mcall("move", "stop", J.log) end
            J.moving = false
        end
        T.creep_t = T.creep_t or J.t
        if d <= cfg.sweep_arrive_m * 100 or J.t - T.creep_t > cfg.creep_s then return set_phase(J, "pick", "close, not offered") end
        local r = math.rad(bearing(me, T.pos))
        J.nudge, J.nudge_until, J.nudge_scale = { X = math.cos(r), Y = math.sin(r), Z = 0 }, J.t + 0.15, cfg.creep_scale
        W.aim_cam(J.pc, T.pos)
        return
    end
    if not J.moving then
        local goal = { X = T.pos.X, Y = T.pos.Y, Z = level and me.Z or (T.pos.Z + 90) }
        local lp -- a short level hop walks straight (nil = move's default planner); never `x and false or nil` (always nil)
        if d <= cfg.sweep_direct_m * 100 and level then lp = false end
        if not start_move(J, goal, cfg.sweep_arrive_m, nil, lp, nil, cfg.sweep_stall_s) then
            mark_bad(J, T, "move refused")
            J.T = nil
            return set_phase(J, "scan", "move refused")
        end
        J.moving = true
        return
    end
    local ms, st = move_state()
    if ms == "moving" and route_wait_over(J, st) then return end
    if ms == "moving" and walk_stalled(J, st) then return approach_failed(J, T, st, {}) end
    if ms == "moving" and J.t - (J.move_started or J.t) <= cfg.approach_timeout_s + 5 then return end
    J.moving = false
    local res = st and st.result or {}
    if res.status == "arrived" or (level and d <= (T.reach_cm or 130) + cfg.near_enough_cm) then
        if T.press_t and J.t - T.press_t < cfg.sweep_repress_s then return end -- just pressed: let the game take it
        return set_phase(J, "pick", "reached, not offered on the way")
    end
    return approach_failed(J, T, st, res)
end

-- could not get there: move's own reason, or (a bare timeout, or our own wait ran out) the shared
-- approach-progress verdict, which says WHY it was not getting closer (e.g. target_above_jump_height)
approach_failed = function(J, T, st, res)
    J.nav_off = nil
    local d_now = J.me and T.pos and U.dist2d(J.me, T.pos)
    if J.move_d0 and d_now and J.move_d0 - d_now >= M.cfg.progress_cm and (T.progress_tries or 0) < M.cfg.progress_retries then
        T.progress_tries = (T.progress_tries or 0) + 1
        say(J.log, string.format("approach ran out of time %.0f m closer (%.0f m left); going on", (J.move_d0 - d_now) / 100, d_now / 100))
        J.moving = false
        return
    end
    local pv = st and type(st.progress) == "table" and st.progress or nil
    -- a damaging zone (a poison cloud) across the only way that does not clear soon (move zone_blocked: move never
    -- walks him through one, live 2026-11-21 00:41Z he died crossing): this pick is out of reach, another is tried;
    -- the same for bad_streak picks in a row ends the job zone_blocked with move's words (what, where, how long),
    -- never path_blocked (the way is there, it is the cloud on it)
    if res.reason == "zone_blocked" then
        local words = type(res.why) == "string" and res.why or "something that hurts is across the only way there"
        mark_bad(J, T, "zone_blocked: " .. words)
        J.T = nil
        if J.bad_streak >= M.cfg.bad_streak then
            return fail(J, "zone_blocked", "zone_blocked", string.format("I can't get to the %s: %s. The last %d I tried were the same.",
                tostring(J.key), words, J.bad_streak), { move = "zone_blocked", zone = res.zone })
        end
        return set_phase(J, "scan", "zone_blocked: another one")
    end
    local why = res.why or res.reason
    if (why == nil or why == "timeout") and pv and pv.why then why = pv.why end
    why = tostring(why or "stuck")
    -- a walk ended for a cause that is not the way there (move "camera_taken": the camera was taken to aim) says
    -- nothing about the target: it is not marked unreachable, the walk starts again, and if it keeps ending so the job
    -- ends with that true cause. Live 2026-11-20 18:50:28-54Z: 4 flax jobs ended path_blocked, "I can't find a way
    -- there", with the flax 2.3 m away and every walk stopped camera_taken after a reflex fight.
    if M.NOT_PATH[why] then
        J.not_path_n = (J.not_path_n or 0) + 1
        say(J.log, string.format("approach to %s ended %s (%d of %d): not the way there; walking again", tostring(T.key), why, J.not_path_n, M.cfg.not_path_tries))
        if J.not_path_n >= M.cfg.not_path_tries then
            local words = mcall("move", "why_words", why, "it", false)
            return fail(J, "body_error", why, string.format("I couldn't walk to the %s: %s. I stopped after %d tries.",
                tostring(J.key), type(words) == "string" and words or why, J.not_path_n), { move = why })
        end
        J.moving = false
        return
    end
    mark_bad(J, T, "unreachable: " .. why)
    J.T = nil
    if J.bad_streak >= M.cfg.bad_streak then
        local plural = tostring(J.key):sub(-1) == "s"
        local words = mcall("move", "why_words", why, plural and "they" or "it", plural)
        return fail(J, "path_blocked", "unreachable", string.format("I can't get to the %s: %s, and the last %d I tried were the same.",
            tostring(J.key), type(words) == "string" and words or why, J.bad_streak), { move = why, progress = pv })
    end
    return set_phase(J, "scan", "unreachable " .. why)
end

local function offsets(J)
    return M.cfg.aim_offsets[J.profile.tool or ""] or M.cfg.aim_offsets.default
end

-- One snapshot of a log piece and his swing, for the mechanism behind a split log that takes no damage from any aim
-- (rung 3, 1 chop in 6; coordinator 2026-11-01): where the piece is now vs his capsule and vs the point he aims at
-- (T.pos, read when it was chosen), his pitch at the press, its root component's collision and physics state, and
-- what a Visibility line from his camera / held tool / chest through its centre hits first. `tag` = "nohit" (taken
-- at diag_swings no-effect swings in a row, and again when the guard leaves it) or "hit" (the first damage a piece
-- takes: the baseline). Logged as one "gather: diag" line; every read is guarded, a failed one is left out.
local DIAG_C0 = { R = 0, G = 0, B = 0, A = 0 }
local function r0(v) return type(v) == "number" and math.floor(v + 0.5) or nil end
local function diag_piece(J, T, pawn, me, pp, tag)
    local a = T.actor
    if not (a and me and pawn) or (U.is_ue_object(a) and not U.valid(a)) then return end -- (offline fakes are tables)
    local c = W.aim(a)
    if not c then return end
    local d = { tag = tag, piece = T.key, stage = T.stage, hp = W.hp(a), run = T.noeff_run, aim_i = T.aim_i, side = T.side,
                me = { r0(me.X), r0(me.Y), r0(me.Z) }, mid = { r0(c.X), r0(c.Y), r0(c.Z) },
                dz_cm = r0(c.Z - me.Z), d2_cm = r0(U.dist2d(me, c)),
                aimed_cm = T.pos and r0(U.dist(T.pos, c)) or nil, -- the point he aims at vs where it is now (it rolled?)
                yaw_err = r0(wrap(W.yaw(pawn) - bearing(me, c))), pitch_press = pp and pp.pitch and r0(pp.pitch) }
    local o = U.loc(a)
    if o then d.origin = { r0(o.X), r0(o.Y), r0(o.Z) } end
    if o and T.stage == "root" then -- where the ground is around it, against its origin: +X, -X, +Y, -Y at 1.2 m and at 2 m
        local mv = mod("move")
        if mv and type(mv.ground_at) == "function" then
            d.floors_dz = {}
            for _, r in ipairs({ 120, 200 }) do
                for _, v in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                    local g = U.try(mv.ground_at, nil, { (o.X + v[1] * r) / 100, (o.Y + v[2] * r) / 100, o.Z / 100 })
                    d.floors_dz[#d.floors_dz + 1] = (type(g) == "table" and g.ok and g.floor_z) and r0(g.floor_z * 100 - o.Z) or "none"
                end
            end
        end
        local b = U.try(function() local o2, e2 = {}, {}; a:GetActorBounds(true, o2, e2, false); return { o2.X, o2.Y, o2.Z, e2.X, e2.Y, e2.Z } end)
        if type(b) == "table" and type(b[1]) == "number" then d.bounds_mid = { r0(b[1]), r0(b[2]), r0(b[3]) }; d.bounds_half = { r0(b[4]), r0(b[5]), r0(b[6]) } end
        d.feet_dz_cm = r0((me.Z - 88) - o.Z) -- his feet against its origin
    end
    local rot = U.try(function() return J.pc:GetControlRotation() end)
    d.pitch_now = rot and r0(rot.Pitch)
    local rc = U.prop(a, "RootComponent")
    if U.valid(rc) then
        d.root = U.class_word(rc)
        d.profile = U.str(U.try(function() return rc:GetCollisionProfileName() end))
        d.obj_type = tonumber(U.try(function() return rc:GetCollisionObjectType() end))
        d.collision = tonumber(U.try(function() return rc:GetCollisionEnabled() end))
        local none = U.try(function() return FName("None") end)
        if none then
            d.simulating = U.try(function() return rc:IsSimulatingPhysics(none) end)
            d.awake = U.try(function() return rc:RigidBodyIsAwake(none) end)
            local v = U.try(function() return rc:GetPhysicsLinearVelocity(none) end)
            local okv, vx, vy, vz = pcall(function() return v.X, v.Y, v.Z end)
            if okv and type(vx) == "number" then d.speed_cms = r0(math.sqrt(vx * vx + vy * vy + vz * vz)) end
        end
    end
    local ksl = M._ksl
    if not U.valid(ksl) then ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary"); M._ksl = ksl end
    local function line(from)
        if not (U.valid(ksl) and from and type(from.X) == "number") then return nil end
        local len = math.max(U.dist(from, c), 1)
        local k = 1 + 60 / len -- 60 cm past the centre: a piece whose collision blocks the line is crossed for sure
        local to = { X = from.X + (c.X - from.X) * k, Y = from.Y + (c.Y - from.Y) * k, Z = from.Z + (c.Z - from.Z) * k }
        local out = {}
        local ok, hit = pcall(function() return ksl:LineTraceSingle(pawn, from, to, 0, false, {}, 0, out, true, DIAG_C0, DIAG_C0, 0.0) end)
        if not ok then return { err = true } end
        if hit ~= true then return { hit = false, len_cm = r0(len) } end
        local comp = U.try(function() return out.Component:Get() end)
        if not U.valid(comp) then comp = U.try(function() return out.Component end) end
        local owner = U.valid(comp) and U.try(function() return comp:GetOwner() end) or nil
        local who = U.valid(owner) and W.id(owner) or nil
        return { what = who and (who == T.key and "piece" or U.class_word(owner)) or "?", comp = U.valid(comp) and U.class_word(comp) or nil,
                 at_cm = r0(tonumber(U.try(function() return out.Distance end))), len_cm = r0(len) }
    end
    local cam = U.try(function() return J.pc.PlayerCameraManager:GetCameraLocation() end)
    local okc, cx, cy, cz = pcall(function() return cam.X, cam.Y, cam.Z end)
    if okc and type(cx) == "number" then d.cam = line({ X = cx, Y = cy, Z = cz }); d.cam_z = r0(cz - me.Z) end
    local eq = U.prop(pawn, "PlayerEquipmentComponent")
    local tool = U.valid(eq) and U.prop(eq, "HeldEquipmentActorRight") or nil
    local tp = U.valid(tool) and U.loc(tool) or nil
    if tp then d.tool = line(tp); d.tool_z = r0(tp.Z - me.Z) end
    d.chest = line({ X = me.X, Y = me.Y, Z = me.Z + 40 })
    json_mod = json_mod or U.try(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    local s = json_mod and U.try(function() return json_mod.encode(d) end)
    say(J.log, "diag " .. tostring(tag) .. " " .. (s or tostring(T.key)))
    return d
end
M._diag_piece = diag_piece

local function step_aim(J, pawn, me)
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local offs = offsets(J)
    local off = offs[T.aim_i] or 0
    local want = bearing(me, T.pos) - off
    T.want_yaw = want
    if not J.faced_t then W.face(J.pc, want) end
    local err = math.abs(wrap(W.yaw(pawn) - want))
    J.face_err = err
    if err > M.cfg.face_err_deg and J.t - J.phase_t < M.cfg.face_max_s then
        local r = math.rad(want)
        J.nudge = { X = math.cos(r), Y = math.sin(r), Z = 0 }
        J.nudge_until = J.t + 0.12
        return
    end
    J.nudge = nil
    -- a walk that ends at a sprint or in a hop carries him on (live 20:33:51Z: "stopped" 1.59 m from a rock, then
    -- slid 5 m in 2 s, and the swing press found him out of reach): the settle counts from when he stands still, and
    -- a slide out of reach goes back to the approach at once, before a wasted press
    local prev, prev_t = J.aim_me, J.aim_me_t
    J.aim_me, J.aim_me_t = { X = me.X, Y = me.Y }, J.t
    if prev and J.t - prev_t < 0.3 and U.dist2d(prev, me) > M.cfg.still_cm_per_s * (J.t - prev_t) and J.t - J.phase_t < 3 then
        J.faced_t = nil
        local d = U.dist2d(me, T.pos)
        if d > (T.reach_cm or 130) + 70 then
            J.moving = false
            return set_phase(J, "approach", string.format("slid out of reach %.2f m", d / 100))
        end
        return
    end
    J.faced_t = J.faced_t or J.t
    if J.t - J.faced_t < M.cfg.settle_s then return end
    J.faced_t = nil
    return set_phase(J, "swing", string.format("aim %+d err %.0f", off, err))
end

local function step_swing(J, pawn, me, acts)
    local cfg = M.cfg
    local T = J.T
    if adopt(J, T) then end
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    local d = U.dist2d(me, T.pos)
    if d > (T.reach_cm or 130) + 70 then
        J.moving = false
        return set_phase(J, "approach", string.format("drifted out of reach %.2f m", d / 100))
    end
    -- verify the previous press: stamina spent (the swing ran) and damage on the target
    local pp = J.pending
    if pp and not pp.st_after and J.t >= pp.t + 0.35 then pp.st_after = W.stamina(pawn) or -1 end -- before it regenerates
    -- the node's HP can reach this client later than the swing's damage frame (rung 3 mine 2026-11-16: three real hits
    -- in a row read "no effect" 1.33 s after the press and cost a re-aim; each showed by the next press), so a swing is
    -- judged when the next press is due, in the same step as that press
    if pp and J.t >= math.max(pp.verify_at, J.next_press or 0) then
        J.pending = nil
        local st = pp.st_after ~= -1 and pp.st_after or nil
        local spent = pp.stamina and st and st < pp.stamina - 0.5
        -- on the live client a swing's stamina cost often shows only after that sample (rung 3 gate 2026-11-01 19:59Z:
        -- "stamina 100->100" on every swing, HIT or not, while each press read 4 less than the one before, and 6 such
        -- misses on a split log ended in a false inputs_not_reaching_game): a press reading less than the press before
        -- proves that swing ran, so the inputs reach the game and the miss is the aim's
        if not spent and pp.stamina and pp.prev_stamina and pp.stamina < pp.prev_stamina - 0.5 then spent = true end
        -- and so does a press he had to wait for stamina to make: presses that reach nothing spend none, so it would
        -- have climbed back. There a press reads no lower than the one before (he presses as soon as there is enough),
        -- so the rule above cannot see it (two full rounds of aims at each of three trees, test 5b).
        if not spent and pp.waited then spent = true end
        local hp = T.kind == "actor" and W.hp(T.actor) or nil
        -- damage: HP fell since the press (or, for a tree that was still foliage, it now exists damaged)
        local hit = (hp and pp.hp and hp < pp.hp - 0.01)
            or (hp and T.max_hp and pp.kind == "foliage" and hp < T.max_hp - 0.01)
        if hit then
            J.hits = J.hits + 1; C().counts.hits = C().counts.hits + 1
            T.noeff, J.unverified, T.noeff_run = 0, 0, 0
            T.hits = (T.hits or 0) + 1
        elseif spent then
            J.unverified = 0
            T.noeff = T.noeff + 1
            T.noeff_run = (T.noeff_run or 0) + 1
        else
            J.unverified = (J.unverified or 0) + 1
            if J.unverified >= cfg.unverified_presses then
                return fail(J, "body_error", "inputs_not_reaching_game", "My swings aren't doing anything at all; something is wrong with my controls.")
            end
        end
        say(J.log, string.format("swing %d on %s: hp %s->%s stamina %s->%s %s (pressed at %.2f s)", J.swings, tostring(T.key), tostring(pp.hp), tostring(hp),
            tostring(pp.stamina), tostring(st), hit and "HIT" or (spent and "no effect" or "unverified"), pp.t - (J.t0 or 0)))
        if T.stage == "root" and T.kind == "actor" then
            -- a rock or tree that takes no damage: one snapshot too (live 2026-11-16, runs 154701 and 155233: 27 swings
            -- at one essence rock from two sides, hp 60 throughout, and nothing said where he stood against it)
            if spent and T.noeff_run == cfg.diag_swings then pcall(diag_piece, J, T, pawn, me, pp, "nohit") end
        end
        if T.stage ~= "root" and T.kind == "actor" then -- a log piece: the unhittable-piece snapshots (diag_piece)
            -- (a new piece's first read is the previous thing's HP, e.g. the felled tree's 85 on an 80 hp log: not a hit)
            if hit and not T.diag_hit and pp.hp <= (T.max_hp or pp.hp) then T.diag_hit = true; pcall(diag_piece, J, T, pawn, me, pp, "hit")
            elseif spent and T.noeff_run == cfg.diag_swings then pcall(diag_piece, J, T, pawn, me, pp, "nohit") end
        end
        -- TEMPORARY GUARD (cfg.give_up_swings): a piece that takes no damage swing after swing is left after
        -- give_up_swings, not after every aim on both sides (live 21:03Z: 27 swings, ~45 s, at a split log that stayed
        -- at 80 hp from every aim and side), and the result says so (J.left)
        if T.stage ~= "root" and (T.noeff_run or 0) >= cfg.give_up_swings then -- a log piece, not the tree or rock
            pcall(diag_piece, J, T, pawn, me, pp, "nohit")
            J.left = J.left or {}
            local wood = (T.name or ""):match("Log_(%a+)_C")
            J.left[#J.left + 1] = { key = T.key, name = wood and ("split " .. wood .. " log") or "log piece", aims = #offsets(J), swings = T.noeff_run }
            T.noeff, T.aim_i, T.side = cfg.no_effect_swings, #offsets(J), cfg.sides - 1
        end
        if T.noeff >= cfg.no_effect_swings then
            T.noeff = 0
            T.aim_i = T.aim_i + 1
            if T.aim_i > #offsets(J) then
                T.aim_i = 1
                T.side = T.side + 1
                if T.side >= cfg.sides then return leave_unhurt(J, T) end
                T.stands = T.stands or {}
                T.stands[stand_key(T, me)] = true -- swung from here with every aim: stand_for offers another place
                T.reposition = 90 * T.side
                J.moving = false
                return set_phase(J, "approach", "other side")
            end
            return set_phase(J, "aim", "next aim")
        end
    end
    if J.t < (J.next_press or 0) or J.pending then return end
    if T.tier and J.tool and T.tier > J.tool.tier then
        return fail(J, "wrong_tool", "tool_tier_too_low", string.format("This %s needs a tier %d %s; my %s is tier %d.",
            tostring(T.name), T.tier, tool_word(J.profile), J.tool.name or "?", J.tool.tier), { need_tier = T.tier, have_tier = J.tool.tier })
    end
    local prof = J.tool_profile or {}
    local prim = prof.prim or {}
    local st = W.stamina(pawn)
    if st and st < (prim.stam or 5) + cfg.stamina_margin then
        J.next_press = J.t + 0.5 -- let stamina come back
        J.stam_waited = true
        return
    end
    -- a style the model chose (one of the held tool's own actions, combat.check_style), else the
    -- profile's default for this target
    if J.style and not J.style_entry then
        local a, bad = mcall("combat", "check_style", J.style, pawn, J.pc)
        if not a then
            local d = (type(bad) == "table" and bad.data) or {}
            return fail(J, (type(bad) == "table" and bad.reason) or "invalid_args", d.why or "no_such_style", d.detail, d)
        end
        J.style_entry = a
        say(J.log, string.format("style %s = %s (%s)", tostring(J.style), tostring(a.name), tostring(a.input)))
    end
    local slot = (J.style_entry and J.style_entry.input) or (T.attack == "special" and "special") or "primary"
    local action = acts[slot] or acts.primary
    if slot == "special" then prim = prof.spec or prim end
    if not tap(J, action, cfg.tap_frames) then
        return fail(J, "body_error", "no_attack_input", "I can't find my attack input.")
    end
    J.swings = J.swings + 1
    C().counts.swings = C().counts.swings + 1
    local rot = T.stage ~= "root" and U.try(function() return J.pc:GetControlRotation() end) or nil -- for diag_piece
    J.pending = { t = J.t, stamina = st, prev_stamina = J.press_stamina, waited = J.stam_waited, hp = T.kind == "actor" and W.hp(T.actor) or nil,
                  kind = T.kind, verify_at = J.t + (prim.dmg_ms or 600) / 1000 + 0.45, pitch = rot and rot.Pitch or nil }
    J.press_stamina = st
    J.stam_waited = nil
    J.next_press = J.t + (prim.next_ms or 1300) / 1000 + jitter(cfg.press_jitter_ms)
end

-- After a tree falls: step back from the toppling trunk, wait while it settles into log pieces.
local function step_settle(J, me)
    local s = J.sites[#J.sites]
    if not J.stepped and s then
        J.stepped = true
        local dx, dy = me.X - s.X, me.Y - s.Y
        local l = math.max(math.sqrt(dx * dx + dy * dy), 1)
        start_move(J, { X = me.X + dx / l * M.cfg.step_back_m * 100, Y = me.Y + dy / l * M.cfg.step_back_m * 100, Z = me.Z }, 0.5, 6)
    end
    local busy = false
    local st = J.profile.settle
    if st and s then
        for _, a in ipairs(W.actors(st.class)) do
            local p = W.loc(a)
            if p and U.dist2d(p, s) < (J.profile.site_radius_cm or 1200) and matches(W.class(a), st.match) then
                -- the game's own "finished falling" (AFelledTree.CollapseState, replicated: 0 None, 1/2 collapsed);
                -- the trunk then lingers LifeSpanAfterCanopyCollapse s, so "still there" alone always ran to max_s
                -- (rung 3 / quest clone 2026-11-01 19:1xZ: ~10 s "settle timeout" after every tree)
                local done = st.done_prop and tonumber(U.try(function() return a[st.done_prop] end))
                if not (done and done ~= 0) then busy = true end
            end
        end
    end
    local waited = J.t - J.phase_t
    if (not busy and waited > 1.5) or waited > (st and st.max_s or M.cfg.settle_max_s) then
        J.stepped = nil
        J.wait_until = J.t + 0.5
        return set_phase(J, "scan", busy and "settle timeout" or "settled")
    end
end

local function step_collect(J, pawn, me)
    local cfg = M.cfg
    local T = J.T
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    -- the bag has it: the press took it. The client's copy of a taken world item lingers after the server took it
    -- (live 21:05:02Z: the stone counted at the press, its actor went at :07, 5 s stood waiting); the key stays
    -- skipped for collected_ttl_s so the next scan does not walk back to the lingering copy
    if (T.presses or 0) > 0 then
        refresh_count(J, true) -- counted every tick after a press (count_every_s kept him standing up to 1 s by a taken pile)
        if (J.gained or 0) > (T.g0 or 0) then
            C().bad[T.key] = J.t + cfg.collected_ttl_s
            return on_done(J, T, "collected")
        end
    end
    T.pos = W.loc(T.actor) or T.pos
    local d = U.dist2d(me, T.pos)
    if J.t - J.phase_t > cfg.collect_max_s then
        local full = fail_if_full(J, J.item or T.item, "collect")
        if full then return end
        mark_bad(J, T, "could not collect")
        -- the rest of a pile the game kept offering other things in (other items lying on it) is skipped with it:
        -- one try per pile, not one per stack (live 2026-11-02 04:07Z: 9 stacks x 12 s on a mixed pile)
        local n = 0
        for _, x in ipairs(T.other and W.drops(T.pos, cfg.pile_cm, J.item) or {}) do
            if not is_bad(x.key, J.t) then C().bad[x.key] = J.t + M.cfg.bad_ttl_s; n = n + 1 end
        end
        if n > 0 then say(J.log, string.format("skipping %d more stacks in that pile (the game kept offering %s)", n, tostring(T.other))) end
        J.T = nil
        return set_phase(J, "scan", "drop skipped")
    end
    T.presses = T.presses or 0
    -- a small thing on the ground: the detector's ray starts at the camera, so aim it at the item from 2 m in (live
    -- 16:34Z: with the camera level he stood on a dropped stone for 12 s and the game never offered it)
    if d <= cfg.collect_aim_cm then W.aim_cam(J.pc, T.pos) end
    -- the game offers it (or another of our item): press now, on the way in, as a player does (no magnet wait). A pile
    -- of that item (every drop is its own world item) takes ONE collect-all press, the thing's secondary (F), as Luis
    -- took 8 dropped stones with one press (recorder 12:42:16Z, bIsSecondaryInteraction = true)
    if T.presses < cfg.collect_presses and J.t - (T.press_t or -9) >= cfg.collect_press_gap_s then
        local tg = mcall("inventory", "interact_target", pawn)
        if type(tg) == "table" and (tg.actor == T.key or (J.item and tg.item == J.item)) then
            local item = tg.item or T.item
            local r = W.collect_all_cm() or cfg.collect_all_cm
            local mine = (tg.secondary and item) and W.drops(T.pos, r, item) or {}
            local pile, units = #mine, 0
            for _, x in ipairs(mine) do units = units + (tonumber(x.count) or 1) end
            T.press_t, T.presses = J.t, T.presses + 1
            -- collect-all takes EVERYTHING within its radius, every kind: only when the pile is all ours and no more
            -- than the count still wanted (live 2026-11-02 04:09Z: count 4 -> 97 stones + 153 Ash Logs + 18 Cabbage ...)
            local need = J.want and math.max(0, J.want - (J.gained or 0)) or 0
            local all = pile >= 2 and units <= need and #W.drops(T.pos, r, nil) == pile
            mcall("inventory", "press_interact", J.log, all and { secondary = true } or nil)
            J.count_t = nil
            if all then J.collect_all = (J.collect_all or 0) + 1 end
            say(J.log, all and string.format("collect all (%s): %d stacks of %s within %.1f m", tostring(tg.secondary), pile, tostring(item), r / 100)
                or ("interact to collect " .. tostring(T.key)))
            return
        elseif type(tg) == "table" and tg.item and tg.item ~= J.item then
            T.other = tg.item -- another kind lying on it is what the game offers
        end
    end
    if d > cfg.collect_tol_m * 100 + 40 then
        if (not J.moving or move_state() ~= "moving") and J.t - (J.move_started or -9) > 1.5 then
            J.moving = start_move(J, T.pos, cfg.collect_tol_m, 12)
        end
        return
    end
    J.moving = false
    T.near_t = T.near_t or J.t
    if d > 45 and J.t - T.near_t > 0.5 then -- still not offered: lean in, as step_pick does
        local r = math.rad(bearing(me, T.pos))
        J.nudge, J.nudge_until, J.nudge_scale = { X = math.cos(r), Y = math.sin(r), Z = 0 }, J.t + 0.1, nil
    end
    if J.t - T.near_t < cfg.collect_wait_s then return end -- the item magnet usually pulls it in
    if T.presses >= cfg.collect_presses then
        T.near_t = J.t + cfg.collect_max_s -- give up below
        J.phase_t = J.t - cfg.collect_max_s - 1
    end
end

-- Pickup mode (bushes, branches, stones on the ground): walk up, the detector targets it, press E.
local function step_pick(J, pawn, me)
    local T = J.T
    adopt(J, T)
    local done, how = target_done(J, T)
    if done then return on_done(J, T, how) end
    if (T.presses or 0) > 0 then
        refresh_count(J, true)
        if (J.gained or 0) > (T.g0 or 0) then return on_done(J, T, "picked") end
    end
    if J.t - J.phase_t > M.cfg.pick_budget_s then
        local dz = (T.pos and T.pos.Z and me.Z) and ((T.pos.Z + 90) - me.Z) / 100 or 0
        mark_bad(J, T, string.format("detector never targeted it (%.1f m away, %.1f m %s my feet)", U.dist2d(me, T.pos) / 100,
            math.abs(dz), dz < 0 and "below" or "above"))
        J.T = nil
        return set_phase(J, "scan", "not targeted")
    end
    if J.t - (T.press_t or -9) < M.cfg.collect_press_gap_s then return end
    if sweep_owed(J) then return await_owed(J) end
    local tg = mcall("inventory", "interact_target", pawn)
    local mine = type(tg) == "table" and not tg.none and ((T.kind == "actor" and tg.actor == T.key)
        or (T.kind == "foliage" and matches(tg.class, J.profile.root.match))
        or (J.item and tg.item == J.item))
    if not mine then
        -- nothing, or something else holds the prompt: aim the camera at it (pitch too: the detector's ray starts at the
        -- camera) and lean in; the swept one had a sweep job: aim only once it is within half a metre
        local r = math.rad(bearing(me, T.pos))
        local dd = U.dist2d(me, T.pos)
        -- another thing holds the prompt right beside it (a stone lying in a stream: the game offers the water's
        -- "Collect Water", live probe 2026-11-02 08:0xZ at 1.1 m from an available, interactable stone; rung 2
        -- 06:44Z stood 4 s on each of ~25 such stones): give it up after other_prompt_s and skip that spot's others
        local other = type(tg) == "table" and not tg.none and tg.actor ~= nil and tg.actor ~= T.key
        if other and dd <= M.cfg.other_prompt_cm then
            T.other_t = T.other_t or J.t
            if J.t - T.other_t >= M.cfg.other_prompt_s then
                local what = tostring(tg.prompt or tg.class or tg.actor)
                mark_bad(J, T, "the game offers " .. what .. " there instead (" .. tostring(tg.class) .. ")")
                local c = C()
                c.contested = c.contested or {}
                c.contested[#c.contested + 1] = { pos = { X = T.pos.X, Y = T.pos.Y, Z = T.pos.Z }, until_t = J.t + M.cfg.bad_ttl_s,
                                                  what = what, class = tg.class }
                J.contested = (J.contested or 0) + 1
                J.contested_what = what
                J.T = nil
                return set_phase(J, "scan", "another prompt there")
            end
        else
            T.other_t = nil
        end
        if dd > 45 then
            J.nudge, J.nudge_until, J.nudge_scale = { X = math.cos(r), Y = math.sin(r), Z = 0 }, J.t + 0.1, nil
        end
        if J.sweep_on then W.aim_cam(J.pc, T.pos) else W.face(J.pc, math.deg(r)) end
        return
    end
    T.press_t, T.presses = J.t, (T.presses or 0) + 1
    if T.presses > M.cfg.collect_presses then
        local full = fail_if_full(J, J.item or T.item or (type(tg) == "table" and tg.item or nil), "pick")
        if full then return end
        mark_bad(J, T, "interact had no effect")
        J.T = nil
        return set_phase(J, "scan", "interact no effect")
    end
    if J.sweep_on and J.sweep then
        local sw = J.sweep
        sw.presses, sw.last_t = sw.presses + 1, J.t
        sw.pending[#sw.pending + 1] = J.t
        sw.pressed[tg.actor] = { t = J.t, n = ((sw.pressed[tg.actor] or {}).n or 0) + 1 }
    end
    mcall("inventory", "press_interact", J.log)
    J.count_t = nil
    say(J.log, "interact " .. tostring(tg.actor) .. " (" .. tostring(tg.prompt) .. ")")
end

-- World teardown (main's crash convention): end WITHOUT touching any game object.
local function abort_paused(J)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle = nil
    J.result = result_of(J, false, "interrupted", { why = "world_teardown", detail = "The world is reloading." })
    c.last = { result = J.result, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token then J.released = true; pcall(arb.release, nil, J.token, "paused") end
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if _G.DW_PAUSE then return abort_paused(J) end
    local pc = J.pc
    local pawn = pc and W.pawn(pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.suspended then
        -- a fight (reflex) has the pawn; we wait in the arbiter's suspended stack. If our entry was
        -- dropped (stack full, too old, world change), nobody will resume us: end.
        if J.t - (J.susp_check or -9) >= 1 then
            J.susp_check = J.t
            local arb = mod("arbiter")
            if arb and J.token and not arb.holds(J.token) and not (arb.is_suspended and arb.is_suspended(J.token)) then
                J.released = true
                return finish(J, result_of(J, false, "interrupted", { why = "not_resumed", detail = "I was interrupted and couldn't get back to it." }))
            end
        end
        return
    end
    -- per frame: key taps + the facing nudge
    local keep = {}
    for _, inp in ipairs(J.inputs) do
        W.inject(inp.act)
        inp.frames = inp.frames - 1
        if inp.frames > 0 then keep[#keep + 1] = inp end
    end
    J.inputs = keep
    if J.nudge and J.t < (J.nudge_until or 0) then W.nudge(pawn, J.nudge, J.nudge_scale or M.cfg.nudge_scale) end
    -- a swing is pressed on the frame it falls due, not on the next decision tick (up to decide_s late on every swing)
    local due = J.phase == "swing" and J.next_press and J.t >= J.next_press and J.due_for ~= J.next_press
    if not due and J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    if due then J.due_for = J.next_press end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return finish(J, result_of(J, false, "companion_down", { why = "died" })) end
    if J.t - J.t0 > J.timeout_s then
        return fail(J, "timeout", "timeout", string.format("I've been at it for %d minutes and only got %d of %d.",
            math.floor(J.timeout_s / 60), J.gained or 0, J.want))
    end
    refresh_count(J)
    if J.done then return end
    if J.item and (J.gained or 0) >= J.want then
        local trains = J.profile and J.profile.trains
        local v = J.via
        local detail = v and string.format("Got %d %s from %s (no usable %s for %s).", J.gained, v.asked, J.key, v.tool_word, v.asked)
            or string.format("Got %d %s.", J.gained, J.key)
        -- the count asked for and the bag's total, by name: with a bare "total" beside "Got 13" he said "got way more
        -- than 10, 162 stone now" and, on exactly 10, "a bit more too" (rung 3 mine 2026-11-16, the second judged false)
        if J.have then
            detail = detail:gsub("%.$", "") .. string.format(" (%d asked for; %d in my bag now, counting what I had).", J.want, J.have)
        end
        return finish(J, result_of(J, true, nil, { detail = detail, source = J.key, asked = v and v.asked or nil,
            trains = trains == false and "none" or trains })) -- the skill this gives XP (profile data; "none" = verified none)
    end
    local me = W.loc(pawn)
    J.me = me
    if not me then return end
    local acts = J.acts or W.actions(pawn)
    J.acts = acts
    local ph = J.phase
    if ph == "equip" then
        if step_equip(J, pawn) then set_phase(J, "scan", "tool ready") end
    elseif ph == "scan" then step_scan(J, me)
    elseif ph == "approach" then
        if J.sweep_on and J.profile.mode == "pickup" and J.T and J.T.kind ~= "drop" then
            step_sweep(J, pawn, me)
            -- taken: on to the next one in the same tick, so the walk never pauses between two
            if J.phase == "scan" and not J.done then
                step_scan(J, me)
                if J.phase == "approach" and J.T and J.T.kind ~= "drop" then step_sweep(J, pawn, me) end
            end
            return
        end
        step_approach(J, pawn, me)
        if J.phase == "aim" and J.profile.mode == "pickup" then set_phase(J, "pick") end
    elseif ph == "aim" then step_aim(J, pawn, me)
    elseif ph == "swing" then step_swing(J, pawn, me, acts)
    elseif ph == "settle" then step_settle(J, me)
    elseif ph == "collect" then step_collect(J, pawn, me)
    elseif ph == "pick" then step_pick(J, pawn, me)
    end
end
M._frame = frame

-- ------------------------------------------------------------------ start / stop / status
function M.start(log, args, ctx)
    args = args or {}
    if _G.DW_PAUSE then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local P = M.profiles()
    local mode = args.mode
    if mode ~= nil then
        local valid = false
        if type(mode) == "string" and mode ~= "" and P and P.RESOURCES then
            for _, p in pairs(P.RESOURCES) do if p.mode == mode then valid = true; break end end
        end
        if not valid then return { ok = false, reason = "invalid_args", data = { detail = "Unknown or empty acquisition mode: " .. tostring(mode) } } end
    end
    -- args.near = a player's name: every search below is centred on HIM (his pawn must be in sight), with a smaller
    -- default radius; "the 2 stone in front of me" (retro 2026-11-01 root cause 4). The model decides when to pass it.
    local anchor
    if type(args.near) == "string" and args.near ~= "" then
        local MAP = mod("mapplayers")
        local me_a = W.pawn(W.pc())
        local pw, pname
        if MAP then pw, pname = MAP.pawn_of(args.near, me_a) end
        local at = pw and W.loc(pw)
        if not at then
            local row = MAP and me_a and (MAP.find(args.near, { me = me_a })) or nil
            return { ok = false, reason = "unknown_target", data = { why = "player_not_in_sight", near = args.near,
                     map = row and { name = row.name, position = row.position, distance = row.distance, direction = row.direction } or nil,
                     detail = row and string.format("I can't see %s from here (the map has him %s m %s of me), so I can't tell what's near him.",
                                                    tostring(row.name), tostring(row.distance), tostring(row.direction or "away"))
                         or string.format("I can't see a player called %s.", args.near) } }
        end
        anchor = { name = pname or args.near, pos = at }
    end
    local function radius_cm()
        return math.min((tonumber(args.radius) or (anchor and M.cfg.near_radius_m) or M.cfg.radius_m) * 100, M.cfg.max_radius_m * 100)
    end
    local key, profile
    if P then key, profile = P.resolve(args.resource) end
    local category, candidates
    if mode and profile then
        -- A resolved name may identify an item shared by several acquisition modes.
        local matches = {}
        for k, p in pairs(P.RESOURCES) do
            if p.mode == mode and (k == key or (profile.item and p.item == profile.item)) then matches[#matches + 1] = k end
        end
        table.sort(matches)
        if #matches == 0 then
            return { ok = false, reason = "unknown_target", data = { why = "no_source_for_mode", resource = args.resource, mode = mode,
                detail = "No known source for that resource with acquisition mode " .. mode .. "." } }
        end
        local selected = profile.mode == mode and key or matches[1]
        key, profile = selected, P.RESOURCES[selected]
    end
    if not profile and P and P.category then
        -- a generic word ("ore", "rock", "logs"): every profile whose game identifiers carry it; the
        -- nearest one with a usable node around him wins (gather_profiles.category, no word list)
        candidates = P.category(args.resource)
        if mode then
            local filtered = {}
            for _, k in ipairs(candidates) do if P.RESOURCES[k].mode == mode then filtered[#filtered + 1] = k end end
            candidates = filtered
        end
        if #candidates > 0 then
            category = args.resource
            local pawn0 = W.pawn(W.pc())
            local me0 = anchor and anchor.pos or (pawn0 and W.loc(pawn0))
            local r_cm = radius_cm()
            local best_d
            for _, k in ipairs(candidates) do
                local cand = P.RESOURCES[k]
                local found = me0 and roots_near({ profile = cand, t = W.now(pawn0) }, me0, r_cm) or {}
                if found[1] and (not best_d or found[1].d < best_d) then best_d, key, profile = found[1].d, k, cand end
            end
            if not profile then
                return { ok = false, reason = "nothing_in_range", data = { why = "no_node_of_kind", resource = args.resource,
                         candidates = candidates, radius_m = r_cm / 100, near = anchor and anchor.name or nil,
                         detail = string.format("No %s within %d m%s (kinds: %s).", tostring(args.resource), r_cm / 100,
                             anchor and (" of " .. anchor.name) or "", table.concat(candidates, ", ")) } }
            end
        end
    end
    if not profile then
        return { ok = false, reason = "unknown_target", data = { why = "unknown_resource", resource = args.resource,
                 detail = string.format("I don't know how to gather '%s'.", tostring(args.resource)) } }
    end
    local want = math.floor(tonumber(args.count) or 0)
    if want < 1 then return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local list = mcall("inventory", "list", log)
    if type(list) ~= "table" or list.ok == false then return { ok = false, reason = "body_error", data = { detail = "inventory unreadable" } } end
    local tool
    local tools = (mcall("combat", "weapons") or {}).items or {}
    -- No usable tool: the SAME item from a tool-free source (profile data: the same `item`, no `tool`) when one is
    -- in range, e.g. ash logs from fallen branches (sticks) before the first axe (DISCOVERIES ground gatherables).
    -- The result says which source was used and why (`source`, `asked`).
    local via
    local function tool_free_alternative()
        if not (P and P.RESOURCES and profile.item) then return nil end
        local me1 = anchor and anchor.pos or W.loc(pawn)
        local r_cm = radius_cm()
        local best_k, best_p, best_d
        for k, cand in pairs(P.RESOURCES) do
            if k ~= key and not cand.tool and cand.item == profile.item then
                local found = me1 and roots_near({ profile = cand, t = W.now(pawn) }, me1, r_cm) or {}
                if found[1] and (not best_d or found[1].d < best_d) then best_k, best_p, best_d = k, cand, found[1].d end
            end
        end
        return best_k, best_p
    end
    if profile.tool then
        tool = M.best_tool(list, profile, tools)
        local fail
        if not tool then
            fail = { ok = false, reason = "wrong_tool", data = { why = "no_tool", resource = key, need = profile.tool,
                     detail = string.format("I need a %s for %s and I don't have one.", tool_word(profile), key) } }
        elseif (profile.min_tier or 1) > tool.tier then
            fail = { ok = false, reason = "wrong_tool", data = { why = "tool_tier_too_low", resource = key, need_tier = profile.min_tier,
                     have_tier = tool.tier, detail = string.format("%s needs a tier %d %s; my best is my %s (tier %d).", key,
                     profile.min_tier, tool_word(profile), tool.name or "?", tool.tier) } }
        end
        if fail then
            local ak, ap
            if not mode then ak, ap = tool_free_alternative() end
            if not ak then return fail end
            via = { asked = key, source = ak, because = fail.data.why, tool_word = tool_word(profile) }
            key, profile, tool = ak, ap, nil
        end
    end
    -- args.target: a perceived piece (a log or stump lying there: its census id) to chop up and collect, as a player
    -- finishes a log he finds; only that piece, what it splits into within 4 m, and its drops
    local named
    if type(args.target) == "string" and args.target ~= "" then
        for _, ch in ipairs(profile.children or {}) do
            for _, a in ipairs(W.actors(ch.class)) do
                if W.id(a) == args.target and matches(W.class(a), ch.match, ch.exclude) then named = a end
            end
        end
        if not (named and W.loc(named)) then
            return { ok = false, reason = "unknown_target", data = { why = "target_not_found", target = args.target,
                     detail = string.format("I can't see a %s piece called %s (a log or stump lying here).", key, args.target) } }
        end
    end
    if M.full_for(list, profile.item) then
        return { ok = false, reason = "inventory_full", data = M.full_data(list, profile.item, key, log, "start") }
    end
    local c = C()
    if c.job then finish(c.job, result_of(c.job, false, "interrupted", { why = "new_gather", detail = "A new gather started." })) end
    local J
    local arb = mod("arbiter")
    local token
    if arb then
        local r = arb.request(log, { name = "gather:" .. key, level = "task", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.susp_at = J.t; J.inputs = {}; J.nudge = nil; J.pending = nil; J.moving = false end end,
            on_resume = function()
                if not J or J.done then return false end
                J.suspended = false
                if J.susp_at then J.t0 = J.t0 + math.max((J.t or J.susp_at) - J.susp_at, 0); J.susp_at = nil end
                J.acts = nil
                J.moving = false
                if J.T and J.T.kind ~= "drop" then J.T.reposition = nil end
                set_phase(J, J.tool and "equip" or "scan", "resumed")
                return true
            end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, result_of(J, false, "interrupted", { why = tostring(why), detail = "I was told to do something else." })) end end })
        if not r.ok then
            return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = r.detail,
                     busy_with = r.owner and r.owner.name, busy_move = r.owner and r.owner.move } }
        end
        token = r.token
    end
    c.gen = c.gen + 1
    c.counts.jobs = c.counts.jobs + 1
    local t = W.now(pawn)
    local tprof = tool and tools[tool.entry.item] or nil
    J = { gen = c.gen, log = log, pc = pc, key = key, profile = profile, want = want, via = via, item = profile.item, token = token,
          task_id = ctx and ctx.id, tool = tool, tool_profile = tprof, stumps = args.stumps == true or (args.stumps == nil and M.cfg.stumps),
          radius_cm = radius_cm(), anchor = anchor,
          max_radius_cm = anchor and math.max(radius_cm(), M.cfg.near_max_radius_m * 100) or nil,
          inv0 = counts_of(list), gained = 0, have = M.count_in(list, profile.item), t0 = t, t = t, phase_t = t,
          inputs = {}, sites = {}, swings = 0, hits = 0, broken = 0, targets = 0, phase_log = {}, bad_streak = 0,
          sweep = { pressed = {}, pending = {}, seen = {}, presses = 0, on_move = 0 }, sweep_on = M.cfg.sweep and args.sweep ~= false,
          style = (args.style ~= nil and args.style ~= "" and args.style ~= "auto") and tostring(args.style) or nil,
          timeout_s = math.min(M.cfg.timeout_base_s + M.cfg.timeout_per_unit_s * want, M.cfg.timeout_max_s) }
    if named then
        local at = W.loc(named)
        J.named, J.sites[1] = W.class(named), { X = at.X, Y = at.Y, Z = at.Z, named = true }
    end
    c.job = J
    set_phase(J, tool and "equip" or "scan", "start " .. key .. " x" .. want)
    mcall("move", "stop", log)
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, result_of(J, false, "body_error", { why = "frame_error", detail = tostring(err) })) end
        end
    end)
    return { ok = true, data = { resource = key, item = profile.item, want = want, have = J.have, tool = tool and tool.name,
             category = category, candidates = candidates, mode = profile.mode,
             tool_tier = tool and tool.tier, radius_m = J.radius_cm / 100, timeout_s = J.timeout_s, near = anchor and anchor.name or nil } }
end

function M.stop(log, why)
    local J = C().job
    if not J then return { ok = true, was = "idle" } end
    finish(J, result_of(J, false, "interrupted", { why = why or "stopped", detail = "Stopped." }))
    return { ok = true, was = J.phase }
end

function M.status()
    local c = C()
    local J = c.job
    local js
    if J then
        local T = J.T
        js = { resource = J.key, item = J.item, want = J.want, gained = J.gained, have = J.have, phase = J.phase,
               suspended = J.suspended or nil, swings = J.swings, hits = J.hits, broken = J.broken, radius_m = J.radius_cm / 100,
               tool = J.tool and J.tool.name, face_err = J.face_err and math.floor(J.face_err),
               target = T and { key = T.key, kind = T.kind, stage = T.stage, name = T.name, aim_i = T.aim_i, side = T.side,
                                hits = T.hits, noeff = T.noeff, pos = U.to_wire(T.pos) } or nil,
               sites = #J.sites, phase_log = J.phase_log, age_s = J.t and math.floor((J.t - J.t0) * 10) / 10 }
    end
    local bad = 0
    for _ in pairs(c.bad) do bad = bad + 1 end
    return { ok = true, job = js, last = c.last, counts = c.counts, bad_targets = bad, lines = c.log_lines }
end

-- ------------------------------------------------------------------ bridge module handlers
-- gather: an async action ({pending = a}); the bridge pre-empts other actions (gather is in ACTION_TOOLS).
-- Capability contract entry (wins over manifest.lua's): adds the style argument.
-- Which skill each profile trains, from the profiles' own `trains` data (M3 audit 2026-10-26: the model could only
-- learn it AFTER a gather; now the tool list says it up front). Pure: profiles -> "Trains Mining: clay, ...; no XP: ...".
function M.trains_summary(profiles)
    local by, none = {}, {}
    for key, p in pairs((profiles or {}).RESOURCES or {}) do
        if p.trains == false then none[#none + 1] = key
        elseif type(p.trains) == "string" then by[p.trains] = by[p.trains] or {}; table.insert(by[p.trains], key) end
    end
    local skills = {}
    for sk, keys in pairs(by) do table.sort(keys); skills[#skills + 1] = sk end
    table.sort(skills)
    local parts = {}
    for _, sk in ipairs(skills) do parts[#parts + 1] = "Trains " .. sk .. ": " .. table.concat(by[sk], ", ") end
    table.sort(none)
    if #none > 0 then parts[#parts + 1] = "no XP: " .. table.concat(none, ", ") end
    return table.concat(parts, "; ")
end

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    local ok_t, trains = pcall(function() return M.trains_summary(M.profiles()) end)
    trains = (ok_t and trains ~= "") and (" " .. trains .. " (other profiles: not measured).") or ""
    local modes, seen = {}, {}
    for _, p in pairs((M.profiles() or {}).RESOURCES or {}) do
        if p.mode and not seen[p.mode] then seen[p.mode] = true; modes[#modes + 1] = p.mode end
    end
    table.sort(modes)
    M.MANIFEST = {
        gather = { kind = "action", llm = true, moves = true, priority = "task", duration_s = 120, timeout_s = 1800,
            detail_is_speech = true,
            description = "Harvest a resource (a profile key, e.g. oak, ash, copper, stone_boulder, loose_stones) until you have count MORE; finds targets and equips your tool. The result's `trains` names the skill it gave XP to (none = no XP)." .. trains,
            args = { type = "object", required = { "resource", "count" }, properties = obj({
                resource = { type = "string", description = "A resource (oak, copper, stone_boulder = mine a stone boulder with a pickaxe, Mining XP; loose_stones = pick stones up off the ground, no XP) or a kind (ore, rock, logs, stone: the nearest of that kind)." },
                count = { type = "integer", minimum = 1, description = "How many more." },
                mode = { type = "string", description = "Only sources of this kind (" .. table.concat(modes, ", ") .. "); no tool-free substitute." },
                radius = { type = "number", minimum = 1, maximum = 120, description = "Search radius, m (default 30; 15 with near)." },
                near = { type = "string", description = "A player's name: search around HIM instead of you (he must be in sight)." },
                stumps = { type = "boolean", description = "Also chop stumps." },
                target = { type = "string", description = "The id of one log or stump lying here (from what you see) to chop up and collect; ends when it and its pieces are done." },
                style = { type = "string", description = "One of the tool's actions (see held_actions), e.g. Overhead Chop." } }) },
            preconditions = { "a tool of the right kind in your inventory (axe for trees, pickaxe for rocks)" },
            reasons = { "nothing_in_range", "wrong_tool", "path_blocked", "zone_blocked", "inventory_full", "interrupted", "timeout",
                        "unknown_target", "invalid_args", "not_unlocked" } },
    }
end

M.HANDLERS = {
    gather = function(log, args, ctx)
        if type(args.resource) ~= "string" or args.resource == "" then
            return { ok = false, reason = "invalid_args", data = { detail = "resource is required (e.g. 'oak', 'ash', 'stone')" } }
        end
        if args.count ~= nil and (tonumber(args.count) or 0) < 1 then
            return { ok = false, reason = "invalid_args", data = { detail = "count must be 1 or more" } }
        end
        local r = M.start(log, { resource = args.resource, count = args.count or 1, radius = args.radius, stumps = args.stumps,
                                 style = args.style, mode = args.mode, near = args.near, target = args.target,
                                 sweep = args.sweep }, ctx) -- sweep = false: the stop-and-press pickup (debug A/B only)
        if not r.ok then return r end
        local J = C().job
        local a = { kind = "gather", id = ctx and ctx.id, timeout_s = (J and J.timeout_s or 600) + 15 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "gather job vanished" } }
        end
        return { pending = a }
    end,
    gather_status = function() return M.status() end,
}

return M
