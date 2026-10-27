-- skills: COMPOSITE skills on Claude's client (route R2; streamline plan step 2). Each tool does the
-- whole job and answers ONE terminal result, verified from fresh game state, with a specific reason
-- and a truthful sentence in data.detail the brain may say as is ("Communication is paramount").
--
--   fetch(target | item, count=1)   find (sense census: world items + ground/foliage pickups) ->
--                                   approach (move.lua) -> FACE it so the game's own interaction
--                                   detector targets it -> one IA_Interact press -> verify the
--                                   inventory grew (repeats for count)
--   consume(item | "food" | "drink") hotbar use (inventory.use with the consumable-class check) ->
--                                   verify the stat rose; not carried but lying within 15 m -> fetch
--                                   first; only in the bag -> "in_bag" (no bag-UI path: it hung)
--   come_to(player, distance=2)     move.lua follow (persistent: re-plans while unreachable) until
--                                   within distance, then stop; fails with the unreachable reason
--                                   after UNREACHABLE_S
--   recover_grave()                 find OWN BP_PlayerGravestone_C (owner guid vs ours) -> approach ->
--                                   face -> "Take All" press -> verify the inventory grew
--   give(player, item, count)       approach the player -> drop at feet (inventory.drop, the UI's
--                                   drop) -> verify the carried count fell
--   interact(target)                the shared engine on any look id (the bridge route delegates here)
-- Every skill acquires the pawn through arbiter.lua (level "command"; a reflex fight suspends it and
-- it re-approaches on resume) and does nothing while _G.DW_PAUSE is set.
--
-- Prior art (search-before-building, docs/ARCHITECTURE.md 8.6): MINDcraft's high-level commands
-- (!goToPlayer(closeness), !givePlayer = go to the player and toss, !consume(item), runAsAction with
-- a timeout; github.com/kolbytn/mindcraft src/agent/commands/actions.js), mineflayer-collectblock
-- (find nearest -> path -> collect -> verify inventory), the interaction-detector facing lesson
-- (DISCOVERIES R2: the detector targets what he FACES within ~1.5 m). Decision: ADAPT those shapes
-- over the bridge's own services (ctx.api); BUILD the thin Lua state machines.
--
-- Contract: HANDLERS[tool](log, args, ctx) -> {pending = action} | failure. ctx.api = the bridge's
-- services (client_bridge.lua M.API: call, census_things, find_thing, match_score, actor_of, counts,
-- me, my_position, aim_at, move_status, reflex_owns_pawn, module, fail, reason_code, null, object).
-- W = the few direct engine touches (facing nudge, grave owner); tests replace them.
-- L28: never spawn a process on a hot path. A directory is created only if it is really missing
-- (an open-for-append probe), and only once per load (cached).
local DIRS_OK = {}
local function ensure_dir(d)
    d = tostring(d):gsub("\\", "/")
    if DIRS_OK[d] then return end
    local probe = d .. "/.dwclient_probe"
    local f = io.open(probe, "a")
    if f then f:close(); os.remove(probe); DIRS_OK[d] = true; return end
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. d .. '"') end
    DIRS_OK[d] = true
end
local M = {}

M.cfg = {
    reach_m = 2.0,          -- walk closer than this before facing (the detector traces ~6 m but picks what he faces)
    approach_m = 1.0,       -- move.go_to tolerance for the approach
    close_m = 0.6,          -- second, tighter approach when facing alone did not get the detector onto it
    approaches = 3,
    face_s = 3.0,           -- face + nudge until the detector targets the thing
    nudge_scale = 0.3,
    verify_s = 4.0,         -- after a press: wait this long for the inventory to grow / the thing to go
    no_progress_s = 25,     -- approach watchdog: no 0.5 m closer to the thing for this long ends the episode (live
    progress_m = 0.5,       -- 2026-10-25 21:57: interact cycled standing spots on an unreachable ledge for 101 s)
    presses = 2,            -- presses per thing before verification_failed
    fetch_radius_m = 30, fetch_max_radius_m = 60,
    consume_ground_m = 15,  -- consume: fetch first when it lies this close
    consume_verify_s = 6,
    come_to_m = 2.0, come_to_unreachable_s = 30, come_to_timeout_s = 100,
    give_m = 2.0, give_wait_s = 6,
    grave_radius_m = 80,
    lease_s = 15,
    busy_wait_s = 20,       -- the pawn held by an equal/higher owner this long (not a fight): fail "busy" naming it
    timeout_s = { fetch = 110, consume = 115, come_to = 105, recover_grave = 110, give = 100, interact = 100, explore = 290,
                  store = 105, take = 105, collect_water = 115 },
}

local W = {}
M.W = W

local function paused() return rawget(_G, "DW_PAUSE") == true end
-- Hot-reload-safe memory: the last tool he held (re-equipped after a grave recovery).
local function memory()
    local m = rawget(_G, "DWSkills")
    if not m then m = {}; _G.DWSkills = m end
    return m
end
M.memory = memory
local function dist2d(a, b)
    if not (a and b) then return nil end
    return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
end
local function copy(t) local o = {}; for k, v in pairs(t or {}) do o[k] = v end; return o end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end

-- ------------------------------------------------------------------ engine touches (tests replace)
-- Face a point: camera yaw (as move.lua steers) + a small movement input toward it, because the body
-- turns only toward movement (bOrientRotationToMovement; gather.lua does the same nudge).
function W.face(api, pos, nudge)
    api.aim_at(pos)
    if not nudge then return end
    local s = api.module("sense")
    local pawn = s and s.local_pawn and s.local_pawn()
    local here = api.my_position()
    if not (pawn and here and pos) then return end
    local dx, dy = pos[1] - here[1], pos[2] - here[2]
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.05 then return end
    pcall(function() pawn:AddMovementInput({ X = dx / l, Y = dy / l, Z = 0 }, M.cfg.nudge_scale, false) end)
end

-- What the game's interaction detector targets now (inventory.interact_target(pawn): no log arg).
function W.detector(api)
    local inv = api.module("inventory")
    local s = api.module("sense")
    if not (inv and inv.interact_target) then return nil end
    local ok, d = pcall(inv.interact_target, s and s.local_pawn and s.local_pawn() or nil)
    return ok and type(d) == "table" and d or nil
end

local function guid_key(g)
    if g == nil then return nil end
    local ok, k = pcall(function()
        local x = g.InnerGuid or g
        local a, b, c, d = x.A, x.B, x.C, x.D
        if type(a) ~= "number" then return nil end
        return string.format("%d:%d:%d:%d", a, b, c, d)
    end)
    return ok and k or nil
end
M._guid_key = guid_key

-- Is this gravestone Claude's own? true | false | nil (unknown). AGravestone:GetOwningCharacterGuid()
-- vs ADominionPlayerControllerBase:GetCharacterGuid() (both FDomCharacterGuid{InnerGuid}; reflection
-- dump 26161880). UNVERIFIED live: when either read fails the answer is nil and recover_grave only
-- takes a grave when it is the only one around.
function W.grave_owner(api, thing)
    local a = api.actor_of(thing)
    local s = api.module("sense")
    local pc = s and s.local_pc and s.local_pc()
    if not (a and pc) then return nil end
    local og = guid_key(select(2, pcall(function() return a:GetOwningCharacterGuid() end)))
    local mine = guid_key(select(2, pcall(function() return pc:GetCharacterGuid() end)))
    if not (og and mine) then return nil end
    return og == mine
end

-- ------------------------------------------------------------------ pawn ownership (arbiter)
local function arbiter(api)
    local A = api.module("arbiter")
    return A and type(A.request) == "function" and A or nil
end

-- job.own: nil (not yet) | "owner" | "suspended" | "waiting" (reflex busy) | "none" (no arbiter)
local function acquire(api, job)
    if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
    local A = arbiter(api)
    if not A then job.own = "none"; return true end
    local r = A.request(api.log, { name = "skill:" .. job.kind, level = job.level or "command", uses_move = true,
                                   lease_s = M.cfg.lease_s, resumable = true,
                                   on_suspend = function()
                                       job.own = "suspended"
                                       -- a modal (an open chest / build mode) is left at once: a reflex's input must
                                       -- never land on it (build review finding 4)
                                       if job.on_suspend then pcall(job.on_suspend) end
                                   end,
                                   on_resume = function() job.own = "owner"; job.resumed = true; return true end,
                                   on_stop = function(_, _, why)
                                       if job.own ~= "released" then job.stopped = why or "stopped" end
                                       if job.cleanup then pcall(job.cleanup) end
                                   end })
    if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
    job.own = "waiting"
    job.refused = type(r) == "table" and r or { reason = "busy" } -- the real owner, for the model (never a guess)
    return false
end

local function release(api, job, why)
    if job.token and job.own ~= "released" then
        local A = arbiter(api)
        job.own = "released"
        if A then pcall(A.release, api.log, job.token, why) end
    end
end

-- nil = carry on; false = wait (a reflex has the pawn; the action timer is held); result = stop now
local function hold(api, job, a)
    if paused() then a.started = api.now(); return false end
    if job.stopped then return api.fail("interrupted", { why = job.stopped,
        detail = "Something else took over (" .. tostring(job.stopped) .. "), so I stopped." }) end
    if not acquire(api, job) or job.own == "suspended" or api.reflex_owns_pawn() then
        -- fighting back (or waiting for the fight to end): the job's clock stops. A pawn that stays
        -- busy for BUSY_WAIT_S is reported with its real owner (who, level, since) instead of waiting on.
        job.wait_since = job.wait_since or api.now()
        local o = job.refused and job.refused.owner or {}
        if job.own == "waiting" and o.level ~= "reflex" and api.now() - job.wait_since >= M.cfg.busy_wait_s then
            return api.fail("busy", { owner = o.name, owner_level = o.level, owner_since = o.since,
                owner_age_s = o.since and math.floor(api.now() - o.since) or nil, reason_detail = job.refused and job.refused.reason,
                detail = "the pawn is held by " .. tostring(o.name or "another module") .. " (" .. tostring(o.level or "?") .. ")" })
        end
        a.started = api.now()
        return false
    end
    job.wait_since = nil
    if job.token then local A = arbiter(api); if A and A.renew then pcall(A.renew, job.token) end end
    if job.resumed then job.resumed = nil; return "resumed" end
    return nil
end

-- ------------------------------------------------------------------ sentences
-- ONE table of movement words: move.lua's why_words(why, thing) (simplify review 2026-10-26). `thing` = what he can't
-- reach ("the Workbench"). M.why_words keeps its old one-argument form for build/crafting.
local MOVE_MOD
local function move_mod(api)
    local m = api and api.module and api.module("move")
    if m and m.why_words then return m end
    if MOVE_MOD == nil then
        local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
        local ok, mm = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/move.lua"))() end)
        MOVE_MOD = ok and mm or false
    end
    return MOVE_MOD or nil
end
local function why_words(why, thing, api)
    local m = move_mod(api)
    if m and m.why_words then return m.why_words(why, thing) end
    return "I can't find a way there"
end
M.why_words = why_words

local function move_failure(api, res, what, data)
    local why = res.reason or res.why or "path_blocked"
    local d = copy(data)
    d.why, d.dist_m = why, res.dist_m
    d.detail = "I can't get to " .. what .. ": " .. why_words(why, what, api) .. "."
    local code = api.reason_code(why)
    if code == "body_error" or code == why and not (code == "path_blocked" or code == "timeout") then code = "path_blocked" end
    return api.fail(code, d)
end

-- ------------------------------------------------------------------ the shared "use a thing" episode
-- thing = a look/census row (id, name, item, position, kind, category); opts.accept(det) -> bool (the
-- detector targets something that serves this episode, e.g. any world item of the wanted item id).
-- Phases: approach -> face -> verify; poll(t) -> nil (working) | result.
local function same_target(thing, det)
    if not det or det.none then return false end
    if det.actor ~= nil and det.actor == thing.id then return true end
    if tostring(thing.id):sub(1, 4) == "fol:" then -- foliage has no actor until the server converts it
        return (det.name ~= nil and det.name == thing.name) or (det.item ~= nil and det.item == thing.item)
    end
    return false
end
M._same_target = same_target

-- Where to USE a thing from (live bug 20:46 UTC: interact walked onto the summoned shelter's ROOF, its
-- actor origin, so the game never offered the bed). Generic for every interactable (beds, stations,
-- chests, lodestones, NPCs):
--   ipoint  the thing's INTERACTION point: the location of its interaction collider (a scene component
--           named Interaction*Collider/Collision/Volume, or the InteractionComponent itself when it is a
--           scene component); the actor origin only when none reads
--   spots   standing spots ~1.2 m from ipoint, first on the side facing AWAY from the actor's centre
--           (the open side: a tent's opening, a bench's front), then rotated around it; each is tried
--           until the game's own detector targets the thing from there
-- World items and ground pickups keep the plain approach (walk onto them).
M.cfg.spot_m = 1.5
M.cfg.spot_angles = { 0, 50, -50, 100, -100, 180 }
M.cfg.on_top_m = 1.0       -- standing this much above the interaction point = on top of the thing: step off
-- collider first: the detection volume (live read 20:57, summoned shelter: InteractionCollider at the
-- ENTRANCE, 1.6 m out along the forward vector; the InteractionComponent itself sits at the origin)
local COLLIDER_PROPS = { "InteractionCollider", "InteractionCollision", "InteractionVolume", "InteractionBox",
                         "InteractionSphere", "InteractionComponent", "Interaction" }

function W.interaction_point(api, thing)
    local a = api.actor_of(thing)
    local s = api.module("sense")
    local U = s and s.U
    if not (a and U) then return nil end
    local function loc(c)
        if not U.valid(c) then return nil end
        local v = U.try(function() return c:K2_GetComponentLocation() end)
        local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
        if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end
    end
    local p, from
    local at = U.loc(a)
    for _, prop in ipairs(COLLIDER_PROPS) do
        p = loc(U.try(function() return a[prop] end))
        -- not on the actor (an NPC's InteractionComponent reads (0,0,0): live 09:25 UTC) -> not a usable point
        if p and at and math.sqrt((p[1] * 100 - at.X) ^ 2 + (p[2] * 100 - at.Y) ^ 2) > 1000 then p = nil end
        if p then from = prop; break end
    end
    local f = U.try(function() return a:GetActorForwardVector() end)
    local okf, fx, fy = pcall(function() return f.X, f.Y end)
    return p, from, (okf and type(fx) == "number") and { fx, fy } or nil
end

local function spots_around(ip, origin, fwd, angles, dist_m)
    -- first direction: the actor's forward vector (a tent's entrance faces it: live read 20:50, shelter
    -- forward (-1,0,0), entrance on -X), else away from the actor's centre, else +X; then rotations
    local dx, dy, l = 0, 0, 0
    if fwd then dx, dy = fwd[1], fwd[2]; l = math.sqrt(dx * dx + dy * dy) end
    if l < 0.3 and origin then dx, dy = ip[1] - origin[1], ip[2] - origin[2]; l = math.sqrt(dx * dx + dy * dy) end
    if l < 0.3 then dx, dy, l = 1, 0, 1 end
    dx, dy = dx / l, dy / l
    local out = {}
    local k = dist_m or M.cfg.spot_m
    for _, deg in ipairs(angles or M.cfg.spot_angles) do
        local r = math.rad(deg)
        local cx, cy = dx * math.cos(r) - dy * math.sin(r), dx * math.sin(r) + dy * math.cos(r)
        out[#out + 1] = { ip[1] + cx * k, ip[2] + cy * k, ip[3] }
    end
    return out
end
M._spots_around = spots_around

-- A small thing (a world item) next to a bigger interactable that competes for the game's detector (the
-- station it came out of, the item the detector picked instead): the detector's camera ray and character trace
-- run from him THROUGH the thing, so whatever lies beyond it along that line wins any near miss. Stand where
-- the competitor is NOT behind the thing: beside it first (90 deg), then with the competitor behind HIM, then
-- the far side last. Angles are measured from the direction thing -> competitor (0 = between them, 180 =
-- the far side, where the competitor is right behind the thing).
M.cfg.small_spot_m = 0.9
M.cfg.small_avoid_angles = { 90, -90, 0, 180 }
local function spots_avoiding(ip, avoid)
    -- spots_around's first direction is ip - origin; origin = the mirror of avoid puts 0 deg on avoid's side
    return spots_around(ip, { 2 * ip[1] - avoid[1], 2 * ip[2] - avoid[2] }, nil, M.cfg.small_avoid_angles, M.cfg.small_spot_m)
end
M._spots_avoiding = spots_avoiding

-- A water source (pond, river), from census data: a WaterVolume class family or the game's own "Collect Water"
-- prompt (DISCOVERIES "Drinkable water for a fresh character"). No name list.
M.cfg.water_reach_m = 2.0
-- a water volume's census point is its ORIGIN, deep in the middle (live 2026-10-26: the start pond's origin read
-- 85 m off while its bank was much nearer), so search wider than look's 80 m
M.cfg.water_search_m = 150
M.cfg.water_wades = 3  -- wade steps on: both 2026-10-26 crashes were the reflex drinking Dirty Water (L38), not wading
function W.is_water(thing)
    if type(thing) ~= "table" then return false end
    if tostring(thing.class or thing.id or ""):find("WaterVolume", 1, true) then return true end
    return lower(thing.prompt):find("collect water", 1, true) ~= nil
end

-- The source's reflected output asset, not a named-item rule or an inventory guess.
function W.water_item(api, thing)
    local ok, actor, U = pcall(api.actor_of, thing)
    if not ok or not actor or not U then return nil end
    local good, item = pcall(function()
        if not U.valid(actor) then return nil end
        local data = actor.WaterItemData
        if not U.valid(data) then return nil end
        return U.short(data)
    end)
    return good and type(item) == "string" and item ~= "" and item or nil
end

local function new_episode(api, thing, opts)
    opts = opts or {}
    local e = { thing = thing, phase = "approach", moving = false, approaches = 0, presses = 0, tol = M.cfg.approach_m,
                before = api.counts() or {}, accept = opts.accept, label = opts.label or thing.name or "that",
                screen_job = opts.screen_job,
                ipoint = thing.position }
    local small = thing.category == "items" or tostring(thing.id):sub(1, 4) == "fol:" or thing.kind == "gatherable"
    if not small and thing.position then
        local ip, from, fwd = W.interaction_point(api, thing)
        e.ipoint, e.ipoint_from = ip or thing.position, from or "actor_origin"
        e.spots, e.spot_i = spots_around(e.ipoint, thing.position, fwd), 1
        -- a water volume (pond, river): its origin is deep inside it (live 2026-10-26 16:08: 3.1 m under the
        -- surface, too_far x6 from spots round it); players use water from the EDGE, so stand on the bank and
        -- face the surface there (move.shore_point, real traces). Without water sense yet, the old spots stay
        -- (wading in calibrates it, and the next try finds the shore).
        if W.is_water(thing) then
            -- DISCOVERIES "Drinkable water": arrival = within water_reach_m (2D) of the surface point, the
            -- game's detector must read THIS volume (or its "Collect Water" prompt); collect_water also requires the
            -- press to ADD an item (need_gain), plain interact keeps its generic verification
            e.water = true
            e.accept = function(det) return det.actor == thing.id or (thing.prompt ~= nil and det.prompt == thing.prompt) end
            local r = api.call("move", "shore_point", thing.position) -- normalised: {ok, data = {stand, edge, alts, how}}
            local sp = type(r) == "table" and (type(r.data) == "table" and r.data or r) or nil
            if sp and r.ok and sp.stand and sp.edge then
                e.ipoint, e.ipoint_from, e.shore = sp.edge, "shore_" .. tostring(sp.how), true -- (the bank is above the surface: not "on top")
                e.spots, e.spot_i, e.tol = { sp.stand }, 1, 0.5 -- at the waterline, not near it
                for _, a in ipairs(sp.alts or {}) do e.spots[#e.spots + 1] = a.stand end
            else
                e.shore_why = sp and sp.why or nil
            end
        end
    elseif small and thing.position then
        e.small = true -- after the plain approach, other sides are tried (spots made on demand, BUGS L7)
        -- opts.avoid = where a competing interactable stands (a station's output on it): go straight to the
        -- sides where it is not behind the item (live 2026-10-26: "the game targets BP_Station_Campfire_C")
        if type(opts.avoid) == "table" and opts.avoid[1] and dist2d(opts.avoid, thing.position) > 0.05 then
            e.spots, e.spot_i, e.tol, e.avoid = spots_avoiding(e.ipoint, opts.avoid), 1, 0.4, opts.avoid
        end
    end
    return e
end

local function gained(before, now, want)
    local best, n, all = nil, 0, {}
    for k, v in pairs(now or {}) do
        local d = v - (before[k] or 0)
        if d > 0 then
            all[k] = d
            if (not want or k == want) and d > n then best, n = k, d end
        end
    end
    return best, n, all
end

-- The bed/shelter actor he is lying in (PlayerRestComponent.CurrentRestingAreaActor), or nil.
function W.resting_in(api)
    local s = api.module("sense")
    local U = s and s.U
    local p = s and s.local_pawn and s.local_pawn()
    if not (U and U.valid(p)) then return nil end
    local rc = U.try(function() return p.PlayerRestComponent end)
    if not U.valid(rc) then return nil end
    local a = U.try(function() return rc.CurrentRestingAreaActor end)
    return U.valid(a) and U.short(a) or nil
end

-- Signals that a press did something besides the inventory: he is now sleeping/resting (beds), or the
-- thing's prompt changed (open -> close, ...). Read-only.
function W.press_signals(api)
    local s = api.module("sense")
    local tod = s and type(s.time_of_day) == "function" and select(2, pcall(s.time_of_day)) or nil
    local wi = W.open_container(api)
    return { sleeping = type(tod) == "table" and tod.sleeping or nil, container = wi and wi.owner or nil,
             conversation = W.conversation_npc(api) }
end

-- The NPC he is in a conversation with (PC.ConversationComponent: DomConversationParticipant.ConversationsActive > 0,
-- CurrentNPC), or nil. Read-only; never under pause (talk review finding 13).
function W.conversation_npc(api)
    if paused() then return nil end
    local s = api.module("sense")
    local U = s and s.U
    local pc = s and s.local_pc and s.local_pc()
    local cc = U and pc and U.try(function() return pc.ConversationComponent end)
    if not (U and U.valid(cc)) then return nil end
    local active = tonumber(U.try(function() return cc.DomConversationParticipant.ConversationsActive end)) or 0
    if active <= 0 then return nil end
    return U.short(U.try(function() return cc.CurrentNPC end)) or "?"
end

-- The container whose screen the game has open for him (inventory.world_inventory): {inv, owner} | nil.
function W.open_container(api)
    local inv = api.module("inventory")
    if not (inv and type(inv.world_inventory) == "function") or paused() then return nil end
    local ok, w = pcall(inv.world_inventory)
    return ok and type(w) == "table" and w or nil
end

-- A station screen is evidence only when its native active station belongs to
-- the actor the detector selected. Other screen families remain unknown here.
function W.screen_target(api, screens, actor)
    if not actor then return nil end
    local craft = api.module("crafting")
    if not (craft and craft.W and type(craft.W.open_station) == "function") then return nil end
    for _, screen in ipairs(screens) do
        local kind = screen.type == 6 and "crafting" or (screen.type == 15 and "processing" or nil)
        if kind then
            local ok, owner = pcall(craft.W.open_station, api, kind)
            if ok and owner == actor then return { screen = screen.name, owner = owner } end
        end
    end
end

local function interaction_screen_ready(api, e)
    local input = api.module("input")
    if not (input and type(input.observe_screens) == "function" and type(input.input_mode) == "function"
            and type(input.is_gameplay_mode) == "function" and type(input.modal) == "function") then
        return nil, "screen state unavailable"
    end
    local screens, mode = input.observe_screens(), input.input_mode()
    if not screens or not mode then return nil, "screen state unavailable" end
    if #screens > 0 or not input.is_gameplay_mode(mode) or input.modal() then return nil, "a screen or modal is open" end
    return input
end

local function next_spot(e, api)
    if e.small and not e.spots and api then
        -- a small thing the detector would not name from the first approach (another stack in front, the
        -- station it lies on): stand on the sides where what the detector picked instead is NOT behind it;
        -- when that can't be placed, the sides away from where he stood (the side he stood on is skipped)
        local det = e.detector
        local other = det and not det.none and det.actor and det.actor ~= e.thing.id and api.find_thing
            and api.find_thing(det.actor, 15) or nil
        local avoid = type(other) == "table" and other.position or nil
        if avoid and dist2d(avoid, e.ipoint) > 0.05 then
            e.spots, e.avoid = spots_avoiding(e.ipoint, avoid), avoid
        else
            local here = api.my_position()
            e.spots = spots_around(e.ipoint, here and { 2 * e.ipoint[1] - here[1], 2 * e.ipoint[2] - here[2] } or nil, nil,
                                   nil, M.cfg.small_spot_m)
            table.remove(e.spots, 1) -- the side he already stood on
        end
        e.spot_i, e.phase, e.moving, e.approaches, e.tol = 1, "approach", false, 0, 0.4
        return true
    end
    if not e.spots or e.spot_i >= #e.spots then return false end
    e.spot_i, e.phase, e.moving, e.approaches = e.spot_i + 1, "approach", false, 0
    return true
end

local function episode_poll(api, e, t, owner_token)
    local th = e.thing
    local goal = (e.wading and e.wade_goal) or (e.spots and e.spots[e.spot_i]) or th.position
    if e.phase == "approach" then
        -- fail-fast progress watchdog (like combat's L34): the approach must get closer to the THING (not to the
        -- current standing spot); a poll gap (suspended by a reflex, then resumed) restarts the window
        local here0 = api.my_position()
        local dth = here0 and e.ipoint and dist2d(here0, e.ipoint)
        if e.last_poll and t - e.last_poll > 2 then e.best_t = t end
        e.last_poll = t
        if dth then
            if not e.best_d or dth < e.best_d - M.cfg.progress_m then e.best_d, e.best_t = dth, t end
            e.best_t = e.best_t or t
            if t - e.best_t > M.cfg.no_progress_s then
                if e.moving then pcall(api.call, "move", "stop"); e.moving = false end
                local why = e.last_move_why or "no_progress"
                return api.fail("path_blocked", { target = th.id, why = why, dist_m = math.floor(dth * 10 + 0.5) / 10,
                    no_progress_s = M.cfg.no_progress_s, spots_tried = e.spots and e.spot_i,
                    detail = string.format("I can't get to the %s: %s (I got no closer than %.0f m in %d s).", e.label,
                        why_words(why, "the " .. e.label, api), e.best_d or dth, M.cfg.no_progress_s) })
            end
        end
        local bed = W.resting_in(api)
        if bed and bed ~= th.id then
            return api.fail("resting", { resting_in = bed, detail = "lying in " .. tostring(bed)
                .. "; movement is disabled until he gets up (interact on that bed)" })
        end
        local here = api.my_position()
        local d = here and goal and dist2d(here, goal)
        local on_top = here and e.ipoint and e.spots and not e.shore and not e.small and (here[3] - (e.ipoint[3] or here[3])) > M.cfg.on_top_m
        local near = d and d <= math.max(e.spots and (e.tol + 0.3) or M.cfg.reach_m, e.tol + 0.3)
            and not (e.tight and d > M.cfg.close_m + 0.3)
        -- water: on the bank within reach of the surface point counts as there, whichever spot he stopped at
        -- (move's water avoidance halts him at the edge, 0.9 m short of a wet spot: live too_far x10)
        -- (not with a shore_point stand: that IS the waterline spot where the game reads the water, live 18:3x)
        if e.water and not e.shore and not e.wading and here and e.ipoint and dist2d(here, e.ipoint) <= M.cfg.water_reach_m then near = true end
        if e.wading then near = d and d <= 0.6 end
        if near and not on_top then
            e.phase, e.face_until, e.moving = "face", t + M.cfg.face_s, false
            W.face(api, e.ipoint, false) -- look at it first (the camera), as a player turns to what he wants
            return nil
        end
        if not e.moving then
            if e.approaches >= M.cfg.approaches then
                if next_spot(e) then return nil end
                return api.fail("too_far", { target = th.id, distance = d, spots_tried = e.spots and e.spot_i, detector = e.detector,
                    detail = "I can't get close enough to the " .. e.label .. "." })
            end
            -- never the game's Unstuck (pause menu, teleports to the start point): live 20:49, it fired twice
            -- while he stood on a tent roof and the client stopped answering right after
            -- move's shared approach-progress tracker measures to the THING (not the standing spot); its window restarts
            -- with each go_to, so the episode keeps the cross-spot window above (the 101 s case cycled 6 spots)
            local mr = api.call("move", "go_to", goal, { tolerance_m = e.wading and 0.4 or e.tol, timeout_s = 60, allow_unstuck = false, wade = e.water or nil, owner_token = owner_token, -- water: walk INTO the shallows (no water detour)
                                                        progress = { to = e.ipoint, stall_s = M.cfg.no_progress_s, gain_m = M.cfg.progress_m } })
            if not mr.ok then return mr end
            e.moving, e.approaches = true, e.approaches + 1
            return nil
        end
        local st = api.move_status()
        local pv = type(st.progress) == "table" and st.progress or nil
        if pv and (pv.verdict == "stalled" or pv.verdict == "unreachable") and pv.why then e.last_move_why = pv.why end
        if st.mode == "go_to" then return nil end
        e.moving = false
        -- a wade step ends where move let him go (its water avoidance may stop him at the very edge): face from there
        if e.wading then e.phase, e.face_until = "face", t + M.cfg.face_s; W.face(api, e.ipoint, true); return nil end
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "arrived" then return nil end -- re-check the distance next tick
        if res.status == "stopped" then return nil end -- e.g. suspended by a reflex and resumed: walk again
        e.last_move_why = res.reason or res.why or e.last_move_why
        if next_spot(e) then return nil end -- that side is blocked: try the next standing spot (big things only)
        return move_failure(api, res, "the " .. e.label, { target = th.id })
    elseif e.phase == "face" then
        local det = W.detector(api)
        e.detector = det
        if same_target(th, det) or (det and not det.none and e.accept and e.accept(det)) then
            if e.screen_job then
                local input, why = interaction_screen_ready(api, e)
                if not input then return api.fail("verification_failed", { target = th.id, detail = why }) end
                local existing = input.owner and input.owner("screen")
                if not (existing and existing.owner == e.screen_job.screen_owner)
                    and not (type(input.claim_if_free) == "function" and input.claim_if_free("screen", e.screen_job.screen_owner)) then
                    return api.fail("busy", { target = th.id, detail = "screen is owned by another action" })
                end
                e.screen_job.screen_input = input
                e.screen_actor = det.actor
            end
            e.sig_before = W.press_signals(api)
            e.prompt_before = det.prompt
            if e.water and e.need_gain then
                local source = det.actor == th.id and th or (det.actor and api.find_thing(det.actor, M.cfg.water_search_m))
                local output = source and source.id == det.actor and W.water_item(api, source)
                if not output or output ~= e.want_item then
                    return api.fail("verification_failed", { target = det.actor, why = output and "water_output_changed" or "water_output_unknown",
                        detail = output and "The water source under my crosshair produces a different item."
                            or "I can't verify which item this water source produces." })
                end
                local okc, snapshot = pcall(api.counts)
                if not okc or type(snapshot) ~= "table" then
                    return api.fail("verification_failed", { target = source.id, why = "inventory_unavailable",
                        detail = "I can't read my inventory to verify the water collection." })
                end
                e.before, e.water_source = snapshot, source
            end
            local pr = api.call("inventory", "press_interact", e.secondary and { secondary = true } or nil)
            if not pr.ok then return pr end
            e.presses = e.presses + 1
            e.phase, e.verify_until = "verify", t + M.cfg.verify_s
            return nil
        end
        W.face(api, e.ipoint, true)
        if t >= e.face_until then
            -- water (live 2026-10-26 19:2x): from the bank 3 m above the pond the game's detector targets nothing (or
            -- a branch on the bank); one step nearer the water's edge and it reads the volume ("Collect Water").
            -- Step toward the surface point, 1 m at a time, at most cfg.water_wades times, then try the next spot.
            if e.water and (e.wades or 0) < M.cfg.water_wades then
                local here = api.my_position()
                if here and e.ipoint then
                    local dx, dy = e.ipoint[1] - here[1], e.ipoint[2] - here[2]
                    local l = math.sqrt(dx * dx + dy * dy)
                    if l > 0.3 then
                        local step = math.min(1.0, l)
                        e.wades, e.wading = (e.wades or 0) + 1, true
                        e.wade_goal = { here[1] + dx / l * step, here[2] + dy / l * step, here[3] }
                        e.phase, e.moving, e.approaches = "approach", false, 0
                        return nil
                    end
                end
            end
            if next_spot(e, api) then e.wading = false; return nil end -- the detector won't take it from here: another side
            local here = api.my_position()
            local dd = here and dist2d(here, e.ipoint)
            if not e.spots and not e.tight and dd and dd > M.cfg.close_m + 0.2 then -- small things: one tighter approach
                e.tight, e.tol, e.phase = true, M.cfg.close_m, "approach"
                return nil
            end
            local other = det and not det.none and (det.name or det.actor)
            return api.fail("not_interactable", { target = th.id, detector = det, spots_tried = e.spots and e.spot_i,
                interaction_point = e.ipoint, interaction_from = e.ipoint_from,
                detail = (e.water and other and ("the water doesn't take from here: the game targets " .. tostring(other) .. " instead"))
                    or (e.water and "the water doesn't take from where I can stand on the bank")
                    or (other and ("the game targets " .. tostring(other) .. ", not the " .. e.label))
                    or ("the game offers no use for the " .. e.label .. " from where I can stand") })
        end
        return nil
    else -- verify
        local source = e.water_source or th
        local now_counts
        if e.water and e.need_gain then
            local okc, snapshot = pcall(api.counts)
            if not okc or type(snapshot) ~= "table" then
                return api.fail("verification_failed", { target = source.id, why = "inventory_unavailable",
                    detail = "I pressed Collect Water but can't read my inventory to verify what arrived." })
            end
            now_counts = snapshot
        else now_counts = api.counts() end
        local item, n, all = gained(e.before, now_counts, e.want_item)
        if not item and not e.want_item then item, n, all = gained(e.before, api.counts()) end
        if e.water and e.need_gain then all = item and { [item] = n } or {} end
        local gone = tostring(source.id):sub(1, 4) ~= "fol:" and api.actor_of(source) == nil and api.find_thing(source.id, 10) == nil
        local changed
        if not e.need_gain then
            if e.screen_job then
                local input = e.screen_job.screen_input
                local own = input and input.owner and input.owner("screen")
                if not own or own.owner ~= e.screen_job.screen_owner then
                    return api.fail("interrupted", { target = th.id, detail = "screen ownership lost" })
                end
                local screens = input.observe_screens()
                if not screens then return api.fail("verification_failed", { target = th.id, detail = "screen state unavailable after use" }) end
                if #screens > 0 and not (item or gone or W.open_container(api) or W.conversation_npc(api)) then
                    local seen = W.screen_target(api, screens, e.screen_actor)
                    if seen then changed = "screen_opened"; e.screen_observed = seen
                    else return api.fail("verification_failed", { target = th.id, detail = "the open screen could not be attributed to the selected target" }) end
                end
            end
            local sig = W.press_signals(api)
            if not changed and sig.sleeping == true and not (e.sig_before and e.sig_before.sleeping) then changed = "sleeping" end
            -- a chest / storage: the game opened ITS screen (deposit and withdraw: move_item with the container)
            if not changed and sig.container == th.id and not (e.sig_before and e.sig_before.container == th.id) then
                changed = "opened"
            end
            -- an NPC: the press started a conversation with it (talk.lua builds on this; never pressed twice)
            if not changed and sig.conversation and sig.conversation == th.id and not (e.sig_before and e.sig_before.conversation) then
                changed = "conversation"
            end
            if not changed then
                local det = W.detector(api)
                if det and det.prompt and e.prompt_before and det.prompt ~= e.prompt_before and same_target(th, det) then
                    changed = "prompt:" .. tostring(e.prompt_before) .. "->" .. tostring(det.prompt)
                end
            end
        end
        if item or ((gone or changed) and not e.need_gain) then
            -- water that WORKED: remember where he stood (move.shore_point offers it first next time)
            if e.water and item then local here = api.my_position(); if here and source.position then pcall(api.call, "move", "remember_water_spot", source.position, here) end end
            return { ok = true, data = { target = e.screen_observed and e.screen_observed.owner or source.id,
                                         requested_target = e.screen_observed and e.screen_observed.owner ~= source.id and source.id or nil,
                                         item = item or api.null, count = n, gained = api.object(all),
                                         target_gone = gone, changed = changed or api.null,
                                         screen = e.screen_observed,
                                         prompt = e.detector and e.detector.prompt or api.null } }
        end
        if t >= e.verify_until then
            -- never a second press while a conversation is up: E would advance or close the dialogue
            if e.presses < M.cfg.presses and not W.conversation_npc(api) then e.phase, e.face_until = "face", t + M.cfg.face_s; return nil end
            return api.fail("verification_failed", { target = source.id, prompt = e.detector and e.detector.prompt,
                detail = (e.water and e.need_gain) and "I pressed Collect Water but couldn't verify a gain of its expected item"
                    or ("pressed use on the " .. e.label .. "; nothing changed (inventory, the thing, sleep state, its prompt)") })
        end
        return nil
    end
end
M._episode_poll = episode_poll
M._new_episode = new_episode

-- ------------------------------------------------------------------ finding things
local function is_pickup(t)
    if t.category == "items" then return true end
    if t.category == "resources" then
        for _, a in ipairs(t.actions or {}) do if a == "interact" then return true end end
    end
    return false
end

-- Best pickup matching `what` (an item id or the player's words) within radius, nearest among the
-- best-scoring; skip ids in `skip`.
local function find_pickup(api, what, radius, skip)
    local things = api.census_things(radius, 60)
    if not things then return nil end
    local best, bs, bd
    for _, t in ipairs(things) do
        if is_pickup(t) and not (skip and skip[t.id]) then
            local s = (t.item == what or lower(t.name) == lower(what)) and 2 or api.match_score(t, what)
            local d = t.distance or 1e9
            if s > 0 and (not best or s > bs or (s == bs and d < bd)) then best, bs, bd = t, s, d end
        end
    end
    return best
end
M._find_pickup = find_pickup

-- A carried row for `what` (name, id, or kind food/drink/potion), preferring the hotbar and clean items.
-- item = "food" | "drink" | "potion" names the consumable DATA CLASS (inventory.consumable_kind), not words
local KINDS = { food = "food", drink = "drink", potion = "potion" }
local function inv_rows(d)
    local rows = {}
    for _, where in ipairs({ "hotbar", "bag" }) do
        for _, it in ipairs(d[where] or {}) do local r = copy(it); r.where = where; rows[#rows + 1] = r end
    end
    return rows
end
-- Names resolve through the bridge's shared api.resolve_name (exact > whole words > all words; a partial
-- overlap never substitutes another item). opts.consumable: only consumables match fuzzily (consume).
-- -> row | nil, kind, info {near = rows that only partly matched}
local function carried_rank(r) return (r.where == "hotbar" and 0.5 or 0) + ((r.consumable and not r.soulscourge) and 0.1 or 0) end
local function consumables_carried(rows)
    local out, seen = {}, {}
    for _, r in ipairs(rows) do
        if r.consumable and not seen[r.item] then seen[r.item] = true; out[#out + 1] = r end
    end
    return out
end
local function find_carried(api, list, what, opts)
    local kind = KINDS[lower(what)]
    local rows = inv_rows(list)
    if kind then
        local best, bs
        for _, r in ipairs(rows) do
            if r.consumable == kind and (not best or carried_rank(r) > bs) then best, bs = r, carried_rank(r) end
        end
        return best, kind, { near = {} }
    end
    local row, info = api.resolve_name(rows, what, { rank = carried_rank,
        fuzzy_ok = opts and opts.consumable and function(r) return r.consumable ~= nil end or nil })
    return row, nil, info
end
M._find_carried = find_carried

-- ------------------------------------------------------------------ job plumbing
-- A pending action for the bridge's action slot: job.step(t) -> nil | result.
local function action(api, ctx, job)
    local a = { kind = job.kind, id = ctx and ctx.id, timeout_s = M.cfg.timeout_s[job.kind] or 100 }
    a.cancel = function()
        local A = arbiter(api)
        if not paused() and job.kind ~= "consume" and A and job.token and A.holds(job.token) then api.call("move", "stop") end
        if job.cleanup then pcall(job.cleanup) end
        release(api, job, "cancelled")
    end
    if job.kind == "consume" or job.screen_owner then
        -- State-only cleanup: bridge may call this while the world is tearing down.
        a.pause_cleanup = function()
            if job.consume_inv and job.consume_tx then
                job.consume_inv.consume_finish(job.consume_tx, job.token, true); job.consume_tx = nil
            end
            if job.screen_owner and job.cleanup then pcall(job.cleanup) end
            release(api, job, "paused")
        end
    end
    a.poll = function(self)
        local h = hold(api, job, self)
        if h == false then return nil end
        if type(h) == "table" then if job.screen_owner and job.cleanup then pcall(job.cleanup) end; release(api, job, "interrupted"); return h end
        if h == "resumed" and job.on_resume then job.on_resume() end
        if job.screen_owner and job.token then
            local A = arbiter(api)
            if not (A and A.holds and A.holds(job.token)) then
                if job.cleanup then pcall(job.cleanup) end
                release(api, job, "interrupted")
                return api.fail("interrupted", { detail = "interaction ownership lost" })
            end
        end
        local res
        if job.screen_owner then
            local ok
            ok, res = pcall(job.step, api.now())
            if not ok then
                if job.cleanup then pcall(job.cleanup) end
                release(api, job, "body_error")
                return api.fail("body_error", { detail = tostring(res) })
            end
        else res = job.step(api.now()) end
        if res then
            if job.verify_final and res.ok then
                if job.screen_owner then
                    local verified, final = pcall(job.verify_final, res)
                    res = verified and final or api.fail("body_error", { detail = tostring(final) })
                else res = job.verify_final(res) end
            end
            if job.screen_owner and job.cleanup then pcall(job.cleanup) end
            release(api, job, res.ok and "done" or tostring(res.reason))
        end
        return res
    end
    return { pending = a }
end

-- Shared pawn-ownership plumbing for other modules (simplify review 2026-10-26; shoot.lua, lodestone.lua):
--   _acquire(api, job) / _release(api, job, why) / _hold(api, job, a) -> nil (carry on) | false (wait: paused, a
--   reflex owns the pawn, suspended; the action timer a.started is held) | result (stop now: stopped, busy for
--   cfg.busy_wait_s naming the real owner) | "resumed";  job = {kind, level?, on_suspend?, cleanup?, stopped?}
--   run_job(api, ctx, job) -> {pending}: the whole wrapper (job.step(t) -> nil | result; on_resume?, cleanup?,
--   verify_final?), timeout cfg.timeout_s[kind] or 100.
M._acquire, M._release, M._hold, M.run_job = acquire, release, hold, action

local function resume_episode(job) return function() if job.ep then job.ep.phase, job.ep.moving = "approach", false end end end

-- ------------------------------------------------------------------ fetch
local function start_fetch(api, args, ctx, opts)
    opts = opts or {}
    local target = args.target or args.id
    local want = args.item
    if not need_str(target) and not need_str(want) then
        return api.fail("invalid_args", { detail = "target (an id from look) or item (a name) is required" })
    end
    local count = math.max(1, math.floor(tonumber(args.count) or 1))
    local job = { kind = opts.kind or "fetch", picked = {}, total = 0, skip = {}, gains = {} }
    local first
    if need_str(target) then
        local t, r = api.find_thing(target)
        if not t then
            local d = copy(r and r.data); d.detail = "I can't see that " .. (want or "thing") .. " anywhere near me."
            return api.fail("unknown_target", d)
        end
        if not is_pickup(t) then
            return api.fail("not_interactable", { target = target, kind = t.kind, actions = t.actions,
                detail = "I can't pick up the " .. tostring(t.name or target) .. "." })
        end
        first = t
        want = want or t.item or t.name
    else
        first = find_pickup(api, want, M.cfg.fetch_radius_m) or find_pickup(api, want, M.cfg.fetch_max_radius_m)
        if not first then
            return api.fail("nothing_in_range", { item = want, radius_m = M.cfg.fetch_max_radius_m,
                detail = "I can't see any " .. tostring(want) .. " lying around here." })
        end
    end
    job.want_item = first.item -- the inventory key a pickup of it adds (nil for an unknown foliage drop)
    local function begin(t)
        job.cur = t
        job.ep = new_episode(api, t, { label = t.name,
            accept = function(det) return job.want_item ~= nil and det.item == job.want_item end })
        job.ep.want_item, job.ep.need_gain = job.want_item, true
    end
    begin(first)
    job.on_resume = resume_episode(job)
    job.step = function(t)
        local r = episode_poll(api, job.ep, t, job.token)
        if not r then return nil end
        if not r.ok then
            if job.total > 0 then -- some made it: say what we have
                return { ok = true, data = { item = job.want_item or job.item, count = job.total, want = count, partial = true,
                    picked = job.picked, gained = api.object(job.gains), stopped_because = r.reason,
                    detail = "I got " .. job.total .. " " .. tostring(job.cur.name) .. ", but " .. tostring(r.data and r.data.detail or r.reason) } }
            end
            return r
        end
        local d = r.data
        job.item = job.item or (d.item ~= api.null and d.item or nil)
        job.want_item = job.want_item or job.item
        job.total = job.total + (tonumber(d.count) or 0)
        for k, v in pairs(d.gained or {}) do job.gains[k] = (job.gains[k] or 0) + v end
        job.picked[#job.picked + 1] = job.cur.id
        job.skip[job.cur.id] = true
        if job.total >= count then
            return { ok = true, data = { item = job.want_item or job.item or api.null, count = job.total, want = count,
                picked = job.picked, gained = api.object(job.gains), name = first.name } }
        end
        local nxt = find_pickup(api, job.want_item or want, M.cfg.fetch_radius_m, job.skip)
        if not nxt then
            return { ok = true, data = { item = job.want_item or job.item or api.null, count = job.total, want = count, partial = true,
                picked = job.picked, gained = api.object(job.gains), name = first.name,
                detail = "I picked up " .. job.total .. " " .. tostring(first.name) .. "; that's all I can see." } }
        end
        begin(nxt)
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ consume
local STAT_OF = { drink = "hydration", food = "sustenance", potion = "health" }
local function stat_now(api, stat)
    local d = api.me()
    if not d then return nil end
    if stat == "health" then return tonumber(d.health) end
    local s = type(d.survival) == "table" and d.survival[stat]
    return type(s) == "table" and tonumber(s[1]) or nil
end

local function count_of(api, item)
    local c = api.counts()
    if type(c) ~= "table" then return nil end
    if c[item] == nil then return 0 end
    return tonumber(c[item])
end

local function start_consume(api, args, ctx)
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required (a name, an item id, food or drink)" }) end
    local what = args.item
    local job = { kind = "consume" }
    local lr = api.call("inventory", "list")
    if not lr.ok then return lr end
    local row, kind, info = find_carried(api, lr.data, what, { consumable = true })
    local function use_step(r)
        if not r.consumable then
            return api.fail("not_consumable", { item = r.item, name = r.name,
                detail = "I can't eat or drink the " .. tostring(r.name) .. "." })
        end
        -- crash-safety rule (BUGS L38): refused with the truthful reason, before any move or press
        local inv = api.module and api.module("inventory")
        local refuse = inv and type(inv.crash_refusal) == "function" and inv.crash_refusal(r.item, r.name, r.consumable) or nil
        if refuse then
            return api.fail("unsafe", { item = r.item, name = r.name, risk = refuse.risk, detail = refuse.detail })
        end
        if r.where ~= "hotbar" then
            return api.fail("in_bag", { item = r.item, name = r.name, offer = "move_item",
                detail = "The " .. tostring(r.name) .. " is in my bag, not on my hotbar; I can only use things from the hotbar." })
        end
        job.stat = STAT_OF[r.consumable]
        job.row = r
        local A = arbiter(api)
        if not (A and job.token and A.holds(job.token)) then return api.fail("busy", { detail = "Consumable owner unavailable." }) end
        local inv = api.module("inventory")
        local tx, why = inv.consume_begin(job.token, "command", M.cfg.consume_verify_s, r.item)
        if not tx then return api.fail("busy", { detail = why }) end
        job.consume_tx, job.consume_inv = tx, inv
        job.before, job.before_n = stat_now(api, job.stat), count_of(api, r.item)
        if not inv.consume_owned(tx, job.token) then return api.fail("interrupted", { detail = "Consumption interrupted before input." }) end
        local ur = api.call("inventory", "use", r.item, { require = r.consumable, hotbar_only = true, owner_token = job.token, transaction = tx })
        if not ur.ok then
            inv.consume_finish(tx, job.token, true); job.consume_tx = nil
            local d = copy(ur.data); d.detail = d.detail or ("I tried to use the " .. tostring(r.name) .. " but the game didn't take it.")
            return api.fail(ur.reason == "body_error" and "body_error" or ur.reason, d)
        end
        job.until_t = api.now() + M.cfg.consume_verify_s
        job.phase = "verify"
        return nil
    end
    if not row and not kind then
        -- not carried. A primitive (PRINCIPLES 4b): say where one is and what he CAN eat or drink; the
        -- model composes interact + consume. Never a different item silently (a partial name match).
        local carried, have = consumables_carried(inv_rows(lr.data)), {}
        for _, r in ipairs(carried) do have[#have + 1] = r.name end
        local also = #have > 0 and (" What I can eat or drink: " .. table.concat(have, ", ") .. ".")
                     or " I have nothing to eat or drink on me."
        local unlike = {}
        for _, r in ipairs(info and info.near or {}) do if not r.consumable then unlike[#unlike + 1] = r.name end end
        if #unlike > 0 then also = " (" .. table.concat(unlike, ", ") .. " isn't something I can eat or drink.)" .. also end
        local data = { item = what, carried_consumables = have }
        local near = find_pickup(api, what, M.cfg.consume_ground_m)
        if not near then
            data.detail = "I don't have any " .. what .. " on me, and I can't see one nearby." .. also
            return api.fail("not_in_inventory", data)
        end
        data.on_ground = { id = near.id, name = near.name, distance = near.distance }
        data.detail = "I don't have any " .. what .. " on me yet; there's " .. tostring(near.name) .. " on the ground "
                .. tostring(near.distance and (math.floor(near.distance + 0.5) .. " m away") or "nearby") .. "." .. also
        return api.fail("not_in_inventory", data)
    elseif not row then
        return api.fail("not_in_inventory", { item = what, kind = kind,
            detail = "I don't have anything to " .. (kind == "food" and "eat" or "drink") .. " on me." })
    else
        job.row, job.phase = row, "use"
    end
    job.cleanup = function()
        local inv = api.module("inventory")
        if inv and job.consume_tx then inv.consume_finish(job.consume_tx, job.token, true); job.consume_tx = nil end
    end
    job.on_suspend = job.cleanup
    job.on_resume = function() if job.fetch and job.fetch.on_resume then job.fetch.on_resume() end end
    job.step = function(t)
        if job.phase == "use" then return use_step(job.row) end
        if job.phase == "fetch" then
            local fr = job.fetch.step(t)
            if not fr then return nil end
            if not fr.ok then return fr end
            local l2 = api.call("inventory", "list")
            if not l2.ok then return l2 end
            local got = fr.data.item ~= api.null and fr.data.item or nil
            local r2 = got and find_carried(api, l2.data, got) or find_carried(api, l2.data, what)
            if not r2 then return api.fail("verification_failed", { detail = "I picked it up but can't find it in my inventory." }) end
            job.fetched = true
            return use_step(r2)
        end
        local inv = api.module("inventory")
        if not (inv and inv.consume_owned(job.consume_tx, job.token)) then return api.fail("interrupted", { detail = "Consumption verification interrupted." }) end
        local now_v, now_n = stat_now(api, job.stat), count_of(api, job.row.item)
        if not inv.consume_owned(job.consume_tx, job.token) then return api.fail("interrupted", { detail = "Consumption verification interrupted." }) end
        local rose = now_v and job.before and now_v > job.before + 0.5
        local used = now_n ~= nil and job.before_n ~= nil and now_n < job.before_n
        if rose or (used and t >= job.until_t - M.cfg.consume_verify_s / 2) then
            inv.consume_finish(job.consume_tx, job.token, false); job.consume_tx = nil
            return { ok = true, data = { item = job.row.item, name = job.row.name, kind = job.row.consumable, stat = job.stat,
                before = job.before, after = now_v, stat_rose = rose == true, count_left = now_n, fetched = job.fetched == true,
                risk = job.row.risk } }
        end
        if t >= job.until_t then
            inv.consume_finish(job.consume_tx, job.token, false); job.consume_tx = nil
            if used then
                return { ok = true, data = { item = job.row.item, name = job.row.name, kind = job.row.consumable, stat = job.stat,
                    before = job.before, after = now_v, stat_rose = false, count_left = now_n, fetched = job.fetched == true,
                    risk = job.row.risk } }
            end
            local known_stat = type(now_v) == "number" and type(job.before) == "number"
            return api.fail("verification_failed", { item = job.row.item, stat = job.stat, before = job.before, after = now_v,
                detail = known_stat and ("I tried to use the " .. tostring(job.row.name) .. " but my " .. tostring(job.stat) .. " didn't go up.")
                    or ("I tried to use the " .. tostring(job.row.name) .. " but could not verify the outcome.") })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ come_to
local function player_row(api, name)
    local things = api.census_things(150, 20)
    for _, t in ipairs(things or {}) do
        if t.category == "players" and (t.name == name or t.id == name) then return t end
    end
    return nil
end

local function start_come_to(api, args, ctx, opts)
    opts = opts or {}
    local who = args.player
    if not need_str(who) then return api.fail("invalid_args", { detail = "player is required" }) end
    local dist = math.max(1, tonumber(args.distance) or M.cfg.come_to_m)
    local job = { kind = opts.kind or "come_to", phase = "start" }
    local function begin()
        local r = api.call("move", "follow", who, dist, { owner_token = job.token })
        if not r.ok then return r end
        if r.data.target_visible == false then
            api.call("move", "stop")
            return api.fail("unknown_target", { player = who,
                detail = "I can't see where you are from here, " .. who .. " (you're too far away for me to see)." })
        end
        job.phase, job.since = "walk", api.now()
        return nil
    end
    local r0 = begin()
    if r0 then return r0 end
    job.on_resume = function() job.phase = "start" end
    job.step = function(t)
        if job.phase == "start" then return begin() end
        local st = api.move_status()
        if st.mode ~= "follow" then
            local res = type(st.result) == "table" and st.result or {}
            if res.status == "failed" then return move_failure(api, res, who, { player = who }) end
            job.phase = "start" -- stopped underneath us (e.g. a reflex suspend): start again
            return nil
        end
        if st.status == "near" then
            local here, p = api.my_position(), player_row(api, who)
            local d = here and p and dist2d(here, p.position)
            if d and d <= dist + 1.5 then
                api.call("move", "stop")
                return { ok = true, data = { player = who, dist_m = math.floor(d * 10 + 0.5) / 10, position = here,
                                             target_position = p.position, arrive_tolerance = dist + 1.5 } }
            end
            return nil
        end
        if st.status == "unreachable" or st.unreachable then
            job.unreach_since = job.unreach_since or t
            if t - job.unreach_since >= M.cfg.come_to_unreachable_s then
                local u = st.unreachable or {}
                api.call("move", "stop")
                return move_failure(api, { reason = u.reason or "no_route", dist_m = st.dist_m }, "you", { player = who,
                    leader_pos = u.leader_pos, my_pos = u.my_pos })
            end
        else
            job.unreach_since = nil
        end
        if t - job.since > M.cfg.come_to_timeout_s - 5 then
            api.call("move", "stop")
            return move_failure(api, { reason = "timeout", dist_m = st.dist_m }, "you", { player = who })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ recover_grave
local function grave_of(api, rows)
    local graves, mine, unknown = {}, nil, 0
    for _, r in ipairs(rows or {}) do
        if tostring(r.class or ""):find("Gravestone", 1, true) then
            graves[#graves + 1] = r
            local own = W.grave_owner(api, r)
            if own == true and (not mine or (r.distance or 0) < (mine.distance or 0)) then mine = r; r.owner_check = "verified" end
            if own == nil then unknown = unknown + 1 end
        end
    end
    if not mine and #graves == 1 and unknown == 1 then mine = graves[1]; mine.owner_check = "unverified" end
    return mine, #graves - (mine and 1 or 0)
end
M._grave_of = grave_of

local function is_grave(t) return t.category == "interactables" and tostring(t.class or ""):find("Gravestone", 1, true) ~= nil end

local function start_recover_grave(api, args, ctx)
    local things = api.census_things(M.cfg.grave_radius_m, 60)
    if not things then return api.fail("companion_down", { detail = "I can't look around right now." }) end
    local rows = {}
    for _, t in ipairs(things) do if is_grave(t) then rows[#rows + 1] = t end end
    local mine, others = grave_of(api, rows)
    if not mine then
        if #rows == 0 then
            return api.fail("nothing_in_range", { radius_m = M.cfg.grave_radius_m,
                detail = "I can't see my grave anywhere near here." })
        end
        local any_unknown = false
        for _, r in ipairs(rows) do if W.grave_owner(api, r) == nil then any_unknown = true end end
        return api.fail(any_unknown and "ambiguous_target" or "nothing_in_range", { graves = others,
            detail = any_unknown and "There are several graves here and I can't tell which one is mine."
                or "The graves around here aren't mine, and I won't touch other people's." })
    end
    local job = { kind = "recover_grave", grave = mine, phase = "grave" }
    job.ep = new_episode(api, mine, { label = "grave" })
    job.ep.need_gain = false
    job.on_resume = resume_episode(job)
    local mem = memory()
    job.step = function(t)
        if job.phase == "equip" then -- re-equip the tool he held before he died (best effort, never fails the job)
            local lr = api.call("inventory", "list")
            local held = lr.ok and type(lr.data.held) == "table" and lr.data.held or {}
            if held.right_item == job.want_held or held.left_item == job.want_held then
                job.result.data.reequipped = job.want_name or job.want_held
                return job.result
            end
            if t >= job.equip_until then
                job.result.data.reequipped, job.result.data.reequip_failed = false, job.want_name or job.want_held
                return job.result
            end
            return nil
        end
        local r = episode_poll(api, job.ep, t, job.token)
        if not r then return nil end
        if not r.ok then return r end
        local d = r.data
        d.grave, d.items = mine.id, d.gained
        M.death_recovered("recover_grave", mine.position, mine.id)
        local n = 0
        for _, v in pairs(d.gained or {}) do n = n + v end
        d.count = n
        if n == 0 then
            return api.fail("verification_failed", { grave = mine.id,
                detail = "I used my grave but nothing came back into my inventory." })
        end
        job.result = { ok = true, data = d }
        local lh = mem.last_held
        if lh and lh.item then
            local lr = api.call("inventory", "list")
            local held = lr.ok and type(lr.data.held) == "table" and lr.data.held or {}
            local holding = held.right_item or held.left_item
            if not holding and lr.ok and find_carried(api, lr.data, lh.item) then
                local er = api.call("inventory", "equip", lh.item)
                if er.ok then
                    job.phase, job.want_held, job.want_name, job.equip_until = "equip", lh.item, lh.name, t + 3
                    return nil
                end
                d.reequipped, d.reequip_failed = false, lh.name or lh.item
            end
        end
        return job.result
    end
    return job
end

-- ------------------------------------------------------------------ give
local function start_give(api, args, ctx)
    if not need_str(args.player) or not need_str(args.item) then
        return api.fail("invalid_args", { detail = "player and item are required" })
    end
    local n = math.floor(tonumber(args.count) or 0)
    if n < 1 then return api.fail("invalid_args", { detail = "count must be >= 1" }) end
    local lr = api.call("inventory", "list")
    if not lr.ok then return lr end
    local row = find_carried(api, lr.data, args.item)
    if not row then
        return api.fail("not_in_inventory", { item = args.item,
            detail = "I don't have any " .. args.item .. " to give you." })
    end
    local have = count_of(api, row.item)
    if have == nil then return api.fail("verification_failed", { detail = "I couldn't read my inventory count." }) end
    if have < n then
        return api.fail("not_enough_resources", { item = row.item, have = have, want = n,
            detail = "I only have " .. have .. " " .. tostring(row.name) .. "." })
    end
    local job = { kind = "give", phase = "walk", row = row }
    local walk = start_come_to(api, { player = args.player, distance = M.cfg.give_m }, ctx, { kind = "give" })
    if walk.ok == false then return walk end
    job.walk = walk
    job.on_resume = function() if job.phase == "walk" then walk.on_resume() end end
    job.step = function(t)
        if job.phase == "walk" then
            local r = walk.step(t)
            if not r then return nil end
            if not r.ok then return r end
            job.before = count_of(api, row.item)
            if job.before == nil then return api.fail("verification_failed", { detail = "I couldn't read my inventory count before dropping." }) end
            local dr = api.call("inventory", "drop", row.item, n)
            if not dr.ok then return dr end
            job.phase, job.until_t = "verify", t + M.cfg.give_wait_s
            return nil
        end
        local now_n = count_of(api, row.item)
        if now_n ~= nil and now_n <= job.before - n then
            return { ok = true, data = { item = row.item, name = row.name, count = n, player = args.player, at = "feet",
                                         inventory_left = now_n } }
        end
        if t >= job.until_t then
            return api.fail("verification_failed", { item = row.item, count = n,
                detail = now_n == nil and "I dropped it, but couldn't read my inventory to verify the result."
                    or ("I dropped the " .. tostring(row.name) .. " but it didn't leave my inventory.") })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ interact (generic, any look id)
local function start_interact(api, args, ctx)
    local id = args.target or args.id
    if not need_str(id) then return api.fail("invalid_args", { detail = "target is required (an id from look)" }) end
    local t, r = api.find_thing(id)
    if not t then
        local d = copy(r and r.data); d.detail = d.detail or "I can't see that anywhere near me."
        return api.fail(r and r.reason or "unknown_target", d)
    end
    local can = false
    for _, act in ipairs(t.actions or {}) do if act == "interact" then can = true end end
    if not can then return api.fail("not_interactable", { target = id, kind = t.kind, actions = t.actions,
        detail = "There's nothing I can do with the " .. tostring(t.name or id) .. " by pressing use." }) end
    local job = { kind = "interact" }
    local accept = (t.category == "items" and t.item) and function(det) return det.item == t.item end or nil
    -- lying in this very bed/shelter: the game ends the rest on a plain interact press (live 20:59, the
    -- detector targets nothing while resting); verified by the resting area clearing
    if W.resting_in(api) == t.id then
        local pr = api.call("inventory", "press_interact")
        if not pr.ok then return pr end
        local until_t = api.now() + 4
        job.step = function(tt)
            if W.resting_in(api) ~= t.id then
                return { ok = true, data = { target = id, changed = "got_up", item = api.null, count = 0 } }
            end
            if tt >= until_t then
                return api.fail("verification_failed", { target = id, detail = "pressed use to get up; still lying in the " .. tostring(t.name or id) })
            end
            return nil
        end
        return job
    end
    job.screen_owner = "interact:" .. tostring(job)
    job.cleanup = function()
        local input = job.screen_input
        if input and type(input.release_if_owned) == "function" then input.release_if_owned("screen", job.screen_owner) end
        job.screen_input = nil
    end
    job.on_suspend = job.cleanup
    job.ep = new_episode(api, t, { accept = accept, screen_job = job })
    job.ep.secondary = args.secondary == true
    if tostring(t.class or ""):find("Gravestone", 1, true) then
        job.verify_final = function(res)
            local n = 0
            for _, v in pairs(res.data and res.data.gained or {}) do n = n + (tonumber(v) or 0) end
            if n > 0 then M.death_recovered("interact", t.position, t.id) end
            return res
        end
    end
    job.on_resume = resume_episode(job)
    job.step = function(tt)
        if job.leaving then return job.leave_step(tt) end
        local res = episode_poll(api, job.ep, tt, job.token)
        -- talk review V2: the press started a conversation, but talk.lua isn't enabled. Never leave him trapped
        -- in an open dialogue (every gated action would be refused): leave with the panel's own Cancel
        -- (bounded, read back), then say truthfully what it was.
        if res and res.ok and res.data and res.data.changed == "conversation" and not W.talk_enabled(api) then
            job.leaving, job.leave_tries, job.leave_t, job.npc = true, 0, 0, t.name or t.id
            return job.leave_step(tt)
        end
        return res
    end
    job.leave_step = function(tt)
        local still = W.conversation_npc(api)
        local function done(stuck)
            return api.fail("not_implemented", { why = "conversation", target = t.id, still_open = stuck or nil,
                detail = "That's someone to talk to; I can't hold conversations yet" .. (stuck and ", and the conversation is still open." or ", so I said goodbye.") })
        end
        if not still then return done(false) end
        if tt < job.leave_t then return nil end
        if job.leave_tries >= 3 then return done(true) end
        job.leave_tries, job.leave_t = job.leave_tries + 1, tt + 1
        local IN = api.module("input")
        if IN and type(IN.leave_conversation_step) == "function" then
            IN.leave_conversation_step(function(a) IN.raw_inject(a) end)
        end
        return nil
    end
    return job
end

-- talk.lua runs conversations only when loaded AND enabled (_G.DW_ENABLE_TALK; its review is pending).
function W.talk_enabled(api)
    if rawget(_G, "DW_ENABLE_TALK") ~= true then return false end
    local tk = api.module("talk")
    return tk ~= nil
end

-- ------------------------------------------------------------------ grave memory (BUGS L19 + L22), persisted
-- EVERY unrecovered death: {ts, iso, position, lost = [{item, name, count}], grave_id?, recovered}. Written
-- when the vitals watcher reports a death (from the last inventory he was seen carrying), kept in
-- client_io/state/last_death.json ({deaths = [...]}; an old single-record file is migrated) so a client
-- restart does not forget it. A death is "recovered" once ITS grave (matched by id, or the nearest death
-- within GRAVE_MATCH_M of the grave) is emptied, or its grave is seen gone at the spot.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
M.DEATH_FILE = ROOT .. "/client_io/state/last_death.json"
M.GRAVE_MATCH_M, M.MAX_DEATHS = 15, 12
local function json_mod()
    local ok, j = pcall(require, "jsonutil")
    return ok and j or nil
end
local function deaths()
    local mem = memory()
    if mem.deaths == nil then
        mem.deaths = {}
        local j = json_mod()
        local f = io.open(M.DEATH_FILE, "rb")
        if f and j then
            local s = f:read("a"); f:close()
            local d = j.decode(s)
            if type(d) == "table" and type(d.deaths) == "table" then mem.deaths = d.deaths
            elseif type(d) == "table" and d.ts then mem.deaths = { d } end -- the L19 single-record file
        elseif f then f:close() end
    end
    return mem.deaths
end
local function save_deaths()
    local j = json_mod()
    if not j then return end
    ensure_dir(ROOT .. "/client_io/state")
    local f = io.open(M.DEATH_FILE, "wb")
    if f then f:write(j.encode({ deaths = deaths() })); f:close() end
end
-- unrecovered deaths, newest first
function M.graves_remembered()
    local out = {}
    for _, d in ipairs(deaths()) do if not d.recovered then out[#out + 1] = d end end
    table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return out
end
-- the newest unrecovered death (go_to "my_grave"), or the one with that ts ("my_grave:<ts>")
function M.death_memory(ts)
    for _, d in ipairs(M.graves_remembered()) do
        if not ts or tostring(d.ts) == tostring(ts) then return d end
    end
    return nil
end
function M.record_death(api, ts)
    local mem = memory()
    local lost = {}
    for _, r in ipairs(mem.last_items or {}) do lost[#lost + 1] = r end
    local here = api.my_position() or (mem.last_pos)
    local list = deaths()
    list[#list + 1] = { ts = ts, iso = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(tonumber(ts) or os.time())), position = here, lost = lost, recovered = false }
    while #list > M.MAX_DEATHS do table.remove(list, 1) end
    save_deaths()
end
local function nearest_death(pos, grave_id)
    local best, bd
    for _, d in ipairs(M.graves_remembered()) do
        if grave_id and d.grave_id == grave_id then return d end
        local dd = pos and type(d.position) == "table" and dist2d(pos, d.position) or nil
        if dd and dd <= M.GRAVE_MATCH_M and (not bd or dd < bd) then best, bd = d, dd end
    end
    return best
end
-- a grave emptied (pos = the grave's position, id = its actor id): mark THAT death recovered
function M.death_recovered(how, pos, grave_id)
    local d = (pos or grave_id) and nearest_death(pos, grave_id) or M.death_memory()
    if d then d.recovered, d.recovered_how, d.recovered_at = true, how, os.time(); save_deaths() end
end
-- census sight of his own grave: bind it to its death (id, live contents); at a death spot with no grave
-- of his in sight for long, the grave is gone (despawned or taken)
function M.grave_seen(grave)
    local d = nearest_death(grave.position, grave.id)
    if d and d.grave_id ~= grave.id then d.grave_id = grave.id; save_deaths() end
    return d
end

-- ------------------------------------------------------------------ get_state extras (honest perception)
-- Called by the bridge's get_state with the state it built. Adds:
--   my_grave   {id, name, distance, position, items (total count), contents ["Torch x1", ...], owner}
--              owner = "verified" (owner guid = ours) | "unverified" (unreadable, the only grave around)
--   other_graves  n graves that are someone else's (or can't be told apart)
--   last_death {ago_s, respawned}  from the vitals watcher's death/revive rows (client_bridge forward_vitals)
--   last_held  the tool he held last (name)

function M.state_extras(api, data)
    local mem, out = memory(), {}
    if paused() then return out end
    local null = api.null
    if type(data.held_item) == "string" and data.held_item ~= "" then
        mem.last_held = { item = data.held_item, name = type(data.held) == "string" and data.held or data.held_item }
    end
    if mem.last_held then out.last_held = mem.last_held.name end
    -- his active skill perks (read-only; sense.perks caches them)
    local sense = api.module("sense")
    if sense and type(sense.perks) == "function" then
        local okp, pk = pcall(sense.perks)
        if okp and type(pk) == "table" then out.perks = pk end
    end
    -- what he carries now (for the death memory) and where he is
    if type(data.inventory_items) == "table" and #data.inventory_items > 0 then
        local rows = {}
        for _, r in ipairs(data.inventory_items) do
            if r.where == "hotbar" or r.where == "bag" then rows[#rows + 1] = { item = r.item, name = r.name, count = r.count } end
        end
        mem.last_items = rows
    end
    if type(data.position) == "table" then
        mem.last_pos = data.position
        mem.visited = mem.visited or {} -- his trail as 10 m cells (explore goes where he has been least)
        local c = M.cfg.explore.cell_m
        local ck = math.floor(data.position[1] / c) .. ":" .. math.floor(data.position[2] / c)
        if mem.last_cell ~= ck then mem.visited[ck] = (mem.visited[ck] or 0) + 1; mem.last_cell = ck end
    end
    -- vitals drain rates (points per real minute), from samples >= 20 s apart over the last ~10 min
    local function num(v) return type(v) == "number" and v or nil end
    local t = api.now()
    mem.vit = mem.vit or {}
    local last = mem.vit[#mem.vit]
    if num(data.sustenance) and (not last or t - last.t >= 20) then
        mem.vit[#mem.vit + 1] = { t = t, sus = data.sustenance, hyd = num(data.hydration) }
        while #mem.vit > 40 or (mem.vit[1] and t - mem.vit[1].t > 600) do table.remove(mem.vit, 1) end
    end
    if #mem.vit >= 2 then
        local a, b = mem.vit[1], mem.vit[#mem.vit]
        local mins = (b.t - a.t) / 60
        if mins >= 0.5 then
            -- only the falling part counts (eating makes it jump up): the drain = the steepest fall rate
            local sus_rate, hyd_rate
            local function rate(key)
                local best
                for i = 2, #mem.vit do
                    local p, q = mem.vit[i - 1], mem.vit[i]
                    if p[key] and q[key] and q[key] < p[key] and q.t > p.t then
                        local r = (p[key] - q[key]) / ((q.t - p.t) / 60)
                        best = best and math.max(best, r) or r
                    end
                end
                return best
            end
            sus_rate, hyd_rate = rate("sus"), rate("hyd")
            out.vitals_rate = { sustenance_per_min = sus_rate and math.floor(sus_rate * 100 + 0.5) / 100 or api.null,
                                hydration_per_min = hyd_rate and math.floor(hyd_rate * 100 + 0.5) / 100 or api.null }
        end
    end
    -- activity rate feedback (information only): XP per minute per skill and item gains per minute over
    -- the last ~10 min, plus the best rate seen this session; the skill gaining XP fastest is the activity
    local snap = { t = t, xp = {}, inv = {} }
    for _, sk in ipairs(type(data.skills) == "table" and data.skills or {}) do
        if type(sk) == "table" and sk.skill and num(sk.xp) then snap.xp[sk.skill] = sk.xp end
    end
    for k, v in pairs(type(data.inventory) == "table" and data.inventory or {}) do if num(v) then snap.inv[k] = v end end
    mem.act = mem.act or {}
    mem.best = mem.best or { xp = {}, inv = {} }
    local la = mem.act[#mem.act]
    if not la or t - la.t >= 20 then
        mem.act[#mem.act + 1] = snap
        while #mem.act > 40 or (mem.act[1] and t - mem.act[1].t > 600) do table.remove(mem.act, 1) end
    end
    if #mem.act >= 2 then
        local a0, a1 = mem.act[1], mem.act[#mem.act]
        local mins = (a1.t - a0.t) / 60
        if mins >= 1 then
            local best_skill, best_rate
            for skn, xp1 in pairs(a1.xp) do
                local r = (xp1 - (a0.xp[skn] or xp1)) / mins
                if r > 0 then
                    if r > (mem.best.xp[skn] or 0) then mem.best.xp[skn] = r end
                    if not best_rate or r > best_rate then best_skill, best_rate = skn, r end
                end
            end
            local items = {}
            for k, n1 in pairs(a1.inv) do
                local g = (n1 - (a0.inv[k] or 0)) / mins
                if g > 0 then
                    if g > (mem.best.inv[k] or 0) then mem.best.inv[k] = g end
                    items[#items + 1] = { item = k, per_min = math.floor(g * 10 + 0.5) / 10, best_per_min = math.floor(mem.best.inv[k] * 10 + 0.5) / 10 }
                end
            end
            table.sort(items, function(x, y) return x.per_min > y.per_min end)
            while #items > 4 do table.remove(items) end
            if best_skill or #items > 0 then
                out.activity = { skill = best_skill, window_min = math.floor(mins * 10 + 0.5) / 10,
                                 xp_per_min = best_rate and math.floor(best_rate + 0.5) or api.null,
                                 best_xp_per_min = best_skill and math.floor(mem.best.xp[best_skill] + 0.5) or api.null, items = items }
            end
        end
    end
    -- every unrecovered grave (BUGS L22), with distance and what he lost there; the newest is death_memory
    if out.my_grave then M.grave_seen(out.my_grave) end
    local here = data.position
    local list = {}
    for _, dm in ipairs(M.graves_remembered()) do
        local dist = (type(here) == "table" and type(dm.position) == "table") and dist2d(here, dm.position) or nil
        local n, names = 0, {}
        for _, r in ipairs(dm.lost or {}) do
            n = n + (tonumber(r.count) or 1)
            if #names < 10 then names[#names + 1] = tostring(r.name or r.item) .. " x" .. tostring(r.count or 1) end
        end
        list[#list + 1] = { ts = dm.ts, iso = dm.iso, ago_s = dm.ts and math.max(0, math.floor(os.time() - dm.ts)) or nil,
                            position = dm.position, distance = dist and math.floor(dist + 0.5) or nil, lost_items = n,
                            lost = names, lost_ids = dm.lost, grave_id = dm.grave_id, go_to = "my_grave:" .. tostring(dm.ts) }
    end
    if #list > 0 then out.graves_remembered, out.death_memory = list, list[1] end
    local inv = api.module("inventory")
    if inv and type(inv.vitals_policy) == "function" then
        local okp, pol = pcall(inv.vitals_policy)
        if okp and type(pol) == "table" then
            out.vitals_policy = { drink_below_pct = pol.drink_below_pct, eat_below_pct = pol.eat_below_pct,
                                  heal_below_pct = pol.heal_below_pct or api.null, reserve_warn = pol.reserve_warn,
                                  safety_floor_pct = inv.SAFETY_FLOOR_PCT }
        end
    end
    local g, others = grave_of(api, data.interactables)
    if g then
        local contents = api.contents_of(g) or {}
        local names, n = {}, 0
        for _, c in ipairs(contents) do
            n = n + (tonumber(c.count) or 1)
            names[#names + 1] = tostring(c.name or c.item) .. " x" .. tostring(c.count or 1)
        end
        out.my_grave = { id = g.id, name = g.name, distance = g.distance, position = g.position, items = n,
                         contents = names, owner = g.owner_check }
    end
    if others > 0 then out.other_graves = others end
    -- the in-game clock and the sleep window (sense.time_of_day), and how full the bag is
    local sense = api.module("sense")
    if sense and type(sense.time_of_day) == "function" then
        local okt, tod = pcall(sense.time_of_day)
        if okt and type(tod) == "table" then out.time_of_day = tod end
    end
    local inv_rows = data.inventory_items or {}
    local used = 0
    for _, r in ipairs(inv_rows) do if r.where == "bag" then used = used + 1 end end
    if inv and type(inv.pages) == "function" and type(inv.pc) == "function" then
        local okc, cap = pcall(function()
            local pc = inv.pc()
            local ic = pc and pc.InventoryComponent
            if not (ic and ic:IsValid()) then return nil end
            for _, pg in ipairs(inv.pages(ic)) do if pg.type_name == "InventoryItems" then return pg.n end end
        end)
        out.bag = { used = used, capacity = okc and cap or nil }
    end
    -- his own recipe unlocks (crafting.W.unlocked: PlayerController.ProgressComponent.RecipesUnlocked),
    -- cached 30 s, for the brain's needs -> options digest (brain/needs.py: what he could craft or cook)
    local crafting = api.module("crafting")
    if crafting and type(crafting.W) == "table" and type(crafting.W.unlocked) == "function" then
        if not mem.unl_at or api.now() - mem.unl_at >= 30 then
            local oku, set = pcall(crafting.W.unlocked, api)
            if oku and type(set) == "table" then
                local ids = {}
                for id in pairs(set) do ids[#ids + 1] = id end
                table.sort(ids)
                mem.unl = ids
            end
            mem.unl_at = api.now()
        end
        if mem.unl then out.recipes_unlocked = mem.unl end
    end
    local life = rawget(_G, "DW_LIFE")
    if type(life) == "table" and life.died_at then
        out.last_death = { ago_s = math.max(0, math.floor(api.now() - life.died_at)), respawned = life.respawned_at ~= nil }
    end
    return out
end

-- Module functions each skill composes (client_bridge lists a skill only while they all exist).
local FIND = { { "sense", "census" }, { "inventory", "list" }, { "inventory", "interact_target" }, { "inventory", "press_interact" },
               { "move", "go_to" }, { "move", "status" } }
local function plus(base, more) local o = {}; for _, x in ipairs(base) do o[#o + 1] = x end; for _, x in ipairs(more) do o[#o + 1] = x end; return o end
M.NEEDS = {
    fetch = FIND,
    interact = FIND,
    recover_grave = FIND,
    consume = { { "sense", "census" }, { "sense", "me" }, { "inventory", "list" }, { "inventory", "use" } },
    come_to = { { "sense", "census" }, { "move", "follow" }, { "move", "status" }, { "move", "stop" } },
    give = { { "sense", "census" }, { "inventory", "list" }, { "inventory", "drop" }, { "move", "follow" }, { "move", "status" },
             { "move", "stop" } },
    move_item = { { "inventory", "list" }, { "inventory", "move" } },
    explore = { { "sense", "census" }, { "move", "go_to" }, { "move", "status" }, { "move", "stop" } },
    store = plus(FIND, { { "inventory", "inventory_of" }, { "inventory", "external_rows" }, { "inventory", "to_external" } }),
    collect_water = FIND,
    take = plus(FIND, { { "inventory", "inventory_of" }, { "inventory", "external_rows" }, { "inventory", "from_external" } }),
    set_vitals_policy = { { "inventory", "set_vitals_policy" } },
    equip = { { "inventory", "list" }, { "inventory", "equip" } },
    unequip = { { "inventory", "unequip" } },
}

-- ------------------------------------------------------------------ explore (BUGS L21)
-- explore {about, max_legs = 6, leg_m = 30, radius = 40}: walk outward in legs, each toward the LEAST
-- VISITED direction (his own trail: 10 m cells he has stood in, kept in memory), looking around while
-- walking and after every leg; stop the moment something matching `about` (the model's words, matched
-- like look's about) is perceived. Generic: no places, no item lists. Reports what it found, or how far.
M.cfg.explore = { legs = 6, leg_m = 30, radius_m = 40, cell_m = 10 }
local DIRS = {}
for i = 0, 7 do local r = math.rad(i * 45); DIRS[#DIRS + 1] = { math.cos(r), math.sin(r), i * 45 } end
local function visits_near(mem, p)
    local c, n = M.cfg.explore.cell_m, 0
    for dx = -1, 1 do for dy = -1, 1 do
        n = n + ((mem.visited or {})[(math.floor(p[1] / c) + dx) .. ":" .. (math.floor(p[2] / c) + dy)] or 0)
    end end
    return n
end
M._visits_near = visits_near

local function matching(api, about, radius)
    local best, bs
    for _, t in ipairs(api.census_things(radius, 40) or {}) do
        if t.category ~= "players" then
            local sc = api.match_score(t, about)
            if sc > 0 and (not best or sc > bs or (sc == bs and (t.distance or 1e9) < (best.distance or 1e9))) then best, bs = t, sc end
        end
    end
    return best
end

local function start_explore(api, args, ctx)
    if not need_str(args.about) then return api.fail("invalid_args", { detail = "about is required (what to look for)" }) end
    local cfg = M.cfg.explore
    local legs = math.max(1, math.floor(tonumber(args.max_legs) or cfg.legs))
    local leg_m = math.max(8, tonumber(args.leg_m) or cfg.leg_m)
    local radius = math.min(80, tonumber(args.radius) or cfg.radius_m)
    local start = api.my_position()
    if not start then return api.fail("companion_down", { detail = "no position" }) end
    local hit = matching(api, args.about, radius)
    if hit then
        return api.fail("already_in_sight", { found = hit, detail = tostring(hit.name) .. " is already in sight ("
            .. tostring(hit.distance) .. " m, id " .. tostring(hit.id) .. ")" })
    end
    local mem = memory()
    local job = { kind = "explore", legs_done = 0, failed = {}, trail = { start }, travelled = 0 }
    local function pick()
        local here = api.my_position() or start
        local best, bscore
        for _, d in ipairs(DIRS) do
            if not job.failed[d[3]] then
                local goal = { here[1] + d[1] * leg_m, here[2] + d[2] * leg_m, here[3] }
                local away = dist2d(goal, start) or 0
                local score = visits_near(mem, goal) * 10 - away -- least visited, then farther from where he began
                if not best or score < bscore then best, bscore = { goal = goal, deg = d[3] }, score end
            end
        end
        return best
    end
    local function next_leg()
        while job.legs_done < legs do
            local p = pick()
            if not p then return false end
            local mr = api.call("move", "go_to", p.goal, { tolerance_m = 3, timeout_s = 40, allow_unstuck = false, owner_token = job.token })
            if mr.ok then job.leg, job.legs_done = p, job.legs_done + 1; return true end
            job.failed[p.deg] = true
        end
        return false
    end
    if not next_leg() then return api.fail("path_blocked", { detail = "no direction to explore from here" }) end
    job.on_resume = function() next_leg() end
    job.step = function(t)
        local st = api.move_status()
        local h = matching(api, args.about, radius)
        if st.mode == "go_to" and not h then return nil end
        if h and st.mode == "go_to" then api.call("move", "stop") end
        local here = api.my_position()
        if here then
            job.travelled = job.travelled + (dist2d(here, job.trail[#job.trail]) or 0)
            job.trail[#job.trail + 1] = here
        end
        if h then
            return { ok = true, data = { found = h, legs = job.legs_done, travelled_m = math.floor(job.travelled + 0.5),
                                         from = start, position = here } }
        end
        local res = type(st.result) == "table" and st.result or {}
        if res.status == "failed" and job.leg then job.failed[job.leg.deg] = true end
        if not next_leg() then
            return api.fail("nothing_in_range", { about = args.about, legs = job.legs_done, travelled_m = math.floor(job.travelled + 0.5),
                trail = job.trail, detail = "explored " .. job.legs_done .. " legs (about " .. math.floor(job.travelled + 0.5)
                    .. " m) and saw nothing matching '" .. args.about .. "'" })
        end
        return nil
    end
    return job
end

-- ------------------------------------------------------------------ store / take (containers: build review finding 14)
-- store {item, count?, container} / take {item, count?, container}: one coupled action each (PRINCIPLES 4b:
-- approach + open + transfer + close belong together, and the open screen is modal state that must not
-- leak). Real player path: walk to the chest and press use (the shared episode; the press is verified by the
-- game opening THIS container's screen, W.press_signals.container), then the screen's own handlers move one
-- stack per press (inventory.to_external = HandleSplitToExternalSlot, inventory.from_external =
-- HandleSplitToSlotFromExternal; crafting.lua's furnace loading uses the same ones), verified by BOTH
-- inventories' counts, then the screen's own close (input.close_container) on EVERY exit path. The modal
-- is claimed in input.lua (no reflex input while it is open; an orphan is closed after 1 s). Never any game
-- call under DW_PAUSE. A shared chest's contents are reported (CLAUDE.md §0: say what he used or took).
local function carried_count(api, item)
    local n = 0
    local lr = api.call("inventory", "list")
    for _, r in ipairs(inv_rows(lr.ok and lr.data or {})) do
        if r.item == item then n = n + (tonumber(r.count) or 1) end
    end
    return n
end
local function free_or_same(rows, slots, item)
    for _, r in ipairs(rows) do if r.item == item then return r.slot end end
    local used = {}
    for _, r in ipairs(rows) do used[r.slot] = true end
    for i = 0, (slots or 0) - 1 do if not used[i] then return i end end
    return nil
end
local function input_mod(api) local m = api.module("input"); return m and type(m.claim) == "function" and m or nil end
local function in_container(rows, what, api) return (api.resolve_name(rows, what)) end
local function contents_words(rows)
    local names = {}
    for _, r in ipairs(rows) do names[#names + 1] = tostring(r.count) .. " " .. tostring(r.name) end
    return names
end

local function start_transfer(api, args, ctx, deposit)
    local kind = deposit and "store" or "take"
    local invm = api.module("inventory")
    if not (invm and type(invm.inventory_of) == "function" and type(invm.external_rows) == "function"
            and type(invm.to_external) == "function" and type(invm.from_external) == "function") then
        return api.fail("not_implemented", { detail = "I can't use chests yet." })
    end
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required" }) end
    if not need_str(args.container) then return api.fail("invalid_args", { detail = "container is required (an id from look)" }) end
    local sense = api.module("sense")
    if sense and type(sense.has_privilege) == "function" and sense.has_privilege("open_chests") == false then
        return api.fail("no_permission", { why = "open_chests",
            detail = "The server hasn't given me rights to open chests here, so I can't use it." })
    end
    local t, r = api.find_thing(args.container)
    if not t then
        local d = copy(r and r.data); d.detail = "I can't see that chest anywhere near me."
        return api.fail("unknown_target", d)
    end
    local inv = invm.inventory_of(api.actor_of(t))
    if not inv then
        return api.fail("not_a_container", { container = t.id, detail = "The " .. tostring(t.name or "thing") .. " isn't something I can store things in." })
    end
    local label = t.name or "chest"
    local want = math.floor(tonumber(args.count) or 0)
    local item, iname
    if deposit then
        local lr = api.call("inventory", "list")
        local row = lr.ok and find_carried(api, lr.data, args.item) or nil
        if not row then return api.fail("not_in_inventory", { item = args.item, detail = "I don't have any " .. args.item .. "." }) end
        item, iname = row.item, row.name or row.item
        local have = carried_count(api, item)
        if want < 1 then want = have end
        if want > have then
            return api.fail("not_enough_resources", { item = item, have = have, want = want, detail = "I only have " .. have .. " " .. tostring(iname) .. "." })
        end
    end
    local job = { kind = kind, container = t, moved = 0, phase = "open" }
    local IN = input_mod(api)
    if IN then IN.claim("container", kind) end
    local function close()
        if paused() then return end -- never a game call under pause; input.lua closes the orphan after resume
        if IN then IN.close_container() elseif type(invm.close_world_inventory) == "function" then pcall(invm.close_world_inventory, api.log) end
    end
    local function finish(res)
        close()
        if IN then IN.release("container") end
        return res
    end
    job.cleanup = function() close(); if IN then IN.release("container") end end
    local function contents() return invm.external_rows(inv) end
    local function press()
        local left = want - job.moved
        local c = contents()
        if deposit then
            local lr = api.call("inventory", "list")
            local row
            for _, x in ipairs(inv_rows(lr.ok and lr.data or {})) do if x.item == item and (tonumber(x.count) or 0) > 0 then row = x; break end end
            if not row then return finish(api.fail("verification_failed", { item = item, moved = job.moved, detail = "I ran out of " .. tostring(iname) .. "." })) end
            local to = free_or_same(c.rows, c.slots, item)
            if not to then return finish(api.fail("container_full", { item = item, moved = job.moved, container = t.id,
                detail = "The " .. label .. " is full" .. (job.moved > 0 and (" after " .. job.moved .. " " .. tostring(iname)) or "") .. "." })) end
            local n = math.min(left, tonumber(row.count) or 1)
            local before = carried_count(api, item) -- read BEFORE the press (the server may answer at once)
            local res = invm.to_external(api.log, row, n, to, inv)
            if not res.ok then return finish(api.fail("body_error", { detail = tostring(res.reason) })) end
            job.pending = { n = n, carried = before - n, inside = (c.by_item[item] or 0) + n, until_t = api.now() + M.cfg.verify_s }
        else
            local src
            for _, x in ipairs(c.rows) do if x.item == item then src = x; break end end
            if not src then return finish(api.fail("verification_failed", { item = item, moved = job.moved, detail = "There's no more " .. tostring(iname) .. " in the " .. label .. "." })) end
            local page = lower(args.to) == "hotbar" and "hotbar" or "bag"
            local lr = api.call("inventory", "list")
            local to
            for _, x in ipairs(inv_rows(lr.ok and lr.data or {})) do if x.item == item and x.where == page then to = x.slot; break end end
            if not to and type(invm.free_slot) == "function" then to = invm.free_slot(page == "hotbar" and "QuickAction" or "InventoryItems") end
            if not to then return finish(api.fail("inventory_full", { item = item, moved = job.moved, detail = "My " .. page .. " is full." })) end
            local n = math.min(left, tonumber(src.count) or 1)
            local before = carried_count(api, item)
            local res = invm.from_external(api.log, src.slot, inv, n, to, page)
            if not res.ok then return finish(api.fail("body_error", { detail = tostring(res.reason) })) end
            job.pending = { n = n, carried = before + n, inside = (c.by_item[item] or 0) - n, until_t = api.now() + M.cfg.verify_s }
        end
        return nil
    end
    local function begin_transfer()
        if not deposit then -- what is inside is only certain once the screen is open (contents may replicate on open)
            local c = contents()
            local best = in_container(c.rows, args.item, api)
            if not best then
                local names = contents_words(c.rows)
                return finish(api.fail("not_in_container", { item = args.item, container = t.id, contents = names,
                    detail = "There's no " .. args.item .. " in the " .. label .. (#names > 0 and (" (it has " .. table.concat(names, ", ") .. ").") or "; it's empty.") }))
            end
            item, iname = best.item, best.name
            local have = c.by_item[item] or 0
            if want < 1 then want = have end
            if want > have then
                return finish(api.fail("not_enough_resources", { item = item, have = have, want = want,
                    detail = "There are only " .. have .. " " .. tostring(iname) .. " in the " .. label .. "." }))
            end
        end
        job.phase, job.start_inside = "transfer", contents().by_item[item] or 0
        return press()
    end
    local wi = W.open_container(api)
    if wi and wi.owner == t.id then job.phase = "ready" else job.ep = new_episode(api, t, { label = label }) end
    -- pre-empted (a reflex): the screen was closed at once (on_suspend); on resume walk back and open it again
    job.on_suspend = function() close(); job.pending = nil; if job.phase ~= "open" then job.reopen = true end end
    job.on_resume = function()
        if job.reopen then job.reopen, job.phase, job.ep = nil, "open", new_episode(api, t, { label = label })
        elseif job.ep and job.phase == "open" then job.ep.phase, job.ep.moving = "approach", false end
    end
    job.step = function(tt)
        if job.phase == "ready" then return begin_transfer() end
        if job.phase == "open" then
            local res = episode_poll(api, job.ep, tt, job.token)
            if not res then return nil end
            if not res.ok then return finish(res) end
            local now = W.open_container(api)
            if not (now and now.owner == t.id) then
                return finish(api.fail("verification_failed", { container = t.id, detail = "I used the " .. label .. " but it didn't open." }))
            end
            return begin_transfer()
        end
        local p = job.pending
        local carried, inside = carried_count(api, item), contents().by_item[item] or 0
        if p and carried == p.carried and inside == p.inside then
            job.moved, job.pending = job.moved + p.n, nil
            if job.moved >= want then
                return finish({ ok = true, data = { item = item, name = iname, count = job.moved, container = t.id, container_name = label,
                    carried_now = carried, inside_now = inside, contents = contents_words(contents().rows) } })
            end
            return press()
        end
        if p and tt >= p.until_t then
            return finish(api.fail("verification_failed", { item = item, moved = job.moved, container = t.id,
                detail = "I tried to move the " .. tostring(iname) .. (deposit and " into " or " out of ") .. "the " .. label .. " but "
                    .. (job.moved > 0 and ("only " .. job.moved .. " went") or "nothing moved") .. "." }))
        end
        return nil
    end
    return job
end
local function start_store(api, args, ctx) return start_transfer(api, args, ctx, true) end
local function start_take(api, args, ctx) return start_transfer(api, args, ctx, false) end
M._start_transfer = start_transfer

-- ------------------------------------------------------------------ collect_water (DISCOVERIES "Drinkable water")
-- collect_water {target?, count = 1}: the nearest water source (census: W.is_water) or the given one; the shared
-- episode (bank spot from move.shore_point, arrival within water_reach_m of the surface, the detector must read
-- the volume / "Collect Water", one press, an item must come in), repeated per count (the source never runs
-- dry). Partial results are reported as such; nothing is claimed without the inventory gain.
local function start_collect_water(api, args, ctx)
    local want = math.max(1, math.floor(tonumber(args.count) or 1))
    local t0, src
    if need_str(args.target) then
        local r
        src, r = api.find_thing(args.target, M.cfg.water_search_m)
        if not src then return api.fail("unknown_target", { target = args.target, detail = "I can't see that water anywhere near me." }) end
        if not W.is_water(src) then
            return api.fail("not_interactable", { target = args.target, detail = "The " .. tostring(src.name or "thing") .. " isn't water I can collect." })
        end
    else
        for _, t in ipairs(api.census_things(M.cfg.water_search_m, 40) or {}) do
            if W.is_water(t) and (not src or (t.distance or 1e9) < (src.distance or 1e9)) then src = t end
        end
        if not src then return api.fail("nothing_in_range", { radius_m = M.cfg.water_search_m, detail = "I can't see any water I could collect near me." }) end
    end
    local expected = W.water_item(api, src)
    if not expected then
        return api.fail("verification_failed", { target = src.id, why = "water_output_unknown",
            detail = "I can't verify which item this water source produces." })
    end
    local job = { kind = "collect_water", got = 0, item = nil, sources = {} }
    local function sources_of()
        local rows = {}
        for target, count in pairs(job.sources) do rows[#rows + 1] = { target = target, count = count } end
        table.sort(rows, function(a, b) return a.target < b.target end)
        return rows, #rows == 1 and rows[1].target or api.null
    end
    local function begin()
        job.ep = new_episode(api, src, { label = src.name or "water" })
        job.ep.need_gain, job.ep.want_item = true, expected
    end
    begin()
    job.on_resume = resume_episode(job)
    job.step = function(t)
        local res = episode_poll(api, job.ep, t, job.token)
        if not res then return nil end
        if res.ok and (tonumber(res.data and res.data.count) or 0) > 0 then
            job.got = job.got + res.data.count
            job.item = job.item or res.data.item
            job.sources[res.data.target] = (job.sources[res.data.target] or 0) + res.data.count
            if job.got >= want then
                local sources, target = sources_of()
                return { ok = true, data = { item = job.item, count = job.got, wanted = want, target = target, sources = sources } }
            end
            begin()
            return nil
        end
        if job.got > 0 then -- some came in, then a press failed: say exactly that
            local d = copy(res.data or {})
            d.stopped_target = d.target
            d.sources, d.target = sources_of()
            d.item, d.count, d.wanted, d.partial = job.item, job.got, want, true
            d.detail = "I collected " .. job.got .. " of " .. want .. " water, then " .. tostring(res.data and res.data.detail or res.reason) .. "."
            return { ok = true, data = d }
        end
        return res
    end
    return job
end

-- ------------------------------------------------------------------ handlers
local STARTERS ={ fetch = start_fetch, consume = start_consume, come_to = start_come_to, recover_grave = start_recover_grave,
                   give = start_give, interact = start_interact, explore = start_explore,
                   store = start_store, take = start_take, collect_water = start_collect_water }
M.STARTERS = STARTERS

local function handler(name)
    return function(log, args, ctx)
        local api = ctx and ctx.api
        if not api then return { ok = false, reason = "body_error", data = { detail = "skills need the bridge api (ctx.api)" } } end
        if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
        local job = STARTERS[name](api, args or {}, ctx)
        if job.ok == false then return job end
        return action(api, ctx, job)
    end
end

M.HANDLERS = { skills_status = function() return { ok = true, data = { cfg = M.cfg, tools = { "interact", "consume", "move_item", "equip",
                                                                                               "fetch", "come_to", "recover_grave", "give" } } } end }
for name in pairs(STARTERS) do M.HANDLERS[name] = handler(name) end

-- ------------------------------------------------------------------ inventory primitives (no pawn: waiters)
-- move_item(item, to = hotbar|bag): the inventory UI's drag (inventory.move); verified once the item is
-- listed in that page. equip(item): the hotbar key / inventory use (inventory.equip); verified once it
-- is in his hands or in the loadout.
local function where_is(api, item)
    local lr = api.call("inventory", "list")
    if not lr.ok then return nil end
    local row = find_carried(api, lr.data, item)
    local held = type(lr.data.held) == "table" and lr.data.held or {}
    local equipped = false
    for _, e in ipairs(lr.data.loadout or {}) do if e.item == item or e.name == item then equipped = true end end
    return row, held, equipped, lr.data
end

M.HANDLERS.move_item = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required" }) end
    local to = lower(args.to or "hotbar")
    local page = ({ hotbar = "hotbar", bag = "bag" })[to]
    if not page then return api.fail("invalid_args", { detail = "to must be hotbar or bag" }) end
    local row = where_is(api, args.item)
    if not row then return api.fail("not_in_inventory", { item = args.item, detail = "I don't have any " .. args.item .. "." }) end
    if row.where == page then return { ok = true, data = { item = row.item, name = row.name, to = page, already = true } } end
    local r = api.call("inventory", "move", row.item, page, args.slot)
    if not r.ok then
        local d = copy(r.data); d.detail = d.detail or ("I couldn't move the " .. tostring(row.name) .. " to my " .. page .. ".")
        return api.fail(r.reason, d)
    end
    local w = { kind = "move_item" }
    w.poll = function()
        local now = where_is(api, row.item)
        if now and now.where == page then return { ok = true, data = { item = row.item, name = row.name, to = page } } end
        return nil
    end
    w.expire = function()
        return api.fail("verification_failed", { item = row.item, detail = "I tried to move the " .. tostring(row.name)
            .. " to my " .. page .. " but it didn't move." })
    end
    return { wait = w, wait_s = 4 }
end

-- set_vitals_policy: WHEN the stay-fed reflex eats/drinks/heals is the model's decision (inventory.lua
-- vitals policy); a safety floor stays in code. Answers with the policy read back.
M.HANDLERS.set_vitals_policy = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    local r = api.call("inventory", "set_vitals_policy", args or {})
    return r
end

M.HANDLERS.equip = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if not need_str(args.item) then return api.fail("invalid_args", { detail = "item is required" }) end
    local row, held, equipped = where_is(api, args.item)
    if not row and not equipped then return api.fail("not_in_inventory", { item = args.item, detail = "I don't have any " .. args.item .. "." }) end
    local item = row and row.item or args.item
    if equipped or held.right_item == item or held.left_item == item then
        return { ok = true, data = { item = item, already = true } }
    end
    local r = api.call("inventory", "equip", item)
    if not r.ok then
        local d = copy(r.data); d.detail = d.detail or ("I couldn't equip the " .. tostring(row and row.name or item) .. ".")
        return api.fail(r.reason, d)
    end
    local w = { kind = "equip" }
    w.poll = function()
        -- the game's own read-back: held with the item's own held-actor class, or worn (inventory.equip_state)
        local es = api.call("inventory", "equip_state", item)
        if es.ok and type(es.data) == "table" and not es.data.unreadable then
            local d = es.data
            if d.equipped then
                return { ok = true, data = { item = item, name = row and row.name, held = d.held, loadout_slot = d.loadout_slot,
                                              worn = d.worn, actor_class = d.actor_class } }
            end
            w.last = d
            return nil
        end
        local _, h, eq = where_is(api, item) -- an inventory module without equip_state (older fakes)
        if eq or (h and (h.right_item == item or h.left_item == item)) then
            return { ok = true, data = { item = item, name = row and row.name, held = h and (h.right or h.left) } }
        end
        return nil
    end
    w.expire = function()
        local d = w.last or {}
        local why = (d.held and d.actor_matches == false) and "wrong_held_actor" or (d.held and not d.actor) and "no_held_actor"
            or (d.loadout_slot and not d.worn and not d.held) and "in_loadout_not_shown" or "not_equipped"
        return api.fail("verification_failed", { item = item, why = why, held = d.held, loadout_slot = d.loadout_slot,
            actor_class = d.actor_class, want_class = d.want_class,
            detail = "Tried to equip " .. tostring(row and row.name or item) .. ": " .. why .. "." })
    end
    return { wait = w, wait_s = 4 }
end

-- unequip {item | slot}: put a held item away or take off a worn piece, the way a player does
-- (inventory.unequip: the item's hotbar key again for a held hotbar item, else the inventory UI's drag
-- into the bag); verified from the game's read-back (no longer held, no longer in the loadout).
M.HANDLERS.unequip = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    local slot = args.slot
    local item = args.item
    if not need_str(item) and slot == nil then return api.fail("invalid_args", { detail = "item or slot is required" }) end
    if need_str(item) and slot == nil then
        local es = api.call("inventory", "equip_state", item)
        local d = es.ok and es.data or {}
        if not d.loadout_slot and not d.held then return { ok = true, data = { item = item, already = true } } end
        slot = d.loadout_slot or (d.held == "left" and "HeldLeft" or "HeldRight")
        item = d.item_id or item
    end
    local r = api.call("inventory", "unequip", slot)
    if not r.ok then
        local d = copy(r.data); d.detail = d.detail or ("Couldn't unequip " .. tostring(item or slot) .. ".")
        return api.fail(r.reason, d)
    end
    if r.data and r.data.reason == "slot already empty" then return { ok = true, data = { slot = slot, already = true } } end
    local w = { kind = "unequip" }
    w.poll = function()
        if not need_str(item) then
            local lr = api.call("inventory", "list")
            for _, e in ipairs((lr.ok and lr.data.loadout) or {}) do if tostring(e.loadout_slot) == tostring(slot) or e.slot == slot then return nil end end
            return { ok = true, data = { slot = slot } }
        end
        local es = api.call("inventory", "equip_state", item)
        local d = es.ok and es.data or {}
        if not d.unreadable and not d.held and not d.loadout_slot then return { ok = true, data = { item = item, slot = slot } } end
        return nil
    end
    w.expire = function()
        return api.fail("verification_failed", { item = item, slot = slot, why = "still_equipped",
            detail = "Tried to unequip " .. tostring(item or slot) .. ": still_equipped." })
    end
    return { wait = w, wait_s = 4 }
end

-- ------------------------------------------------------------------ manifest entries (client_mod/scripts/manifest.lua shape)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
local function str(desc) return { type = "string", description = desc } end
local SPEAKS = true
-- PRINCIPLES 4b (Luis): primitives first, the MODEL composes ("walk to him" + "drop the logs"). Offered
-- to the LLM: interact (frame-coupled: approach + face + press + verify), consume, move_item, equip (and
-- the bridge's go_to / follow / stop / drop / look / inspect / inventory). The compounds fetch, come_to,
-- recover_grave and give stay as tested debug tools (llm = false), not offered.
local COMPOUND = " (Compound kept for debugging; the model composes the primitives instead.)"
M.MANIFEST = {
    interact = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 110,
        detail_is_speech = SPEAKS, aliases = { "pickup" },
        description = "Press use (E) on one perceived thing: walks there, faces it, presses, checks it worked. Picks up a "
            .. "ground stack or plant, Take All from a grave, lies down in a bed/shelter (interact on it again to get up), "
            .. "opens, talks.",
        args = { type = "object", required = { "target" }, properties = obj({
            target = str("The id of one perceived thing (from situation or look). Not a name or coordinates."),
            secondary = { type = "boolean", default = false,
                description = "Its second action (F), e.g. collect every nearby stack of that kind." } }) },
        ground = obj({ target = "thing" }),
        reasons = { "unknown_target", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    consume = { kind = "action", llm = true, moves = false, priority = "command", duration_s = 3, timeout_s = 30,
        detail_is_speech = SPEAKS,
        description = "Eat or drink one item from your hotbar (bag items: move_item first; ground items: interact first).",
        args = { type = "object", required = { "item" }, properties = obj({
            item = str("A carried item's name or id, or 'food' / 'drink' / 'potion'.") }) },
        ground = obj({ item = "carried" }),
        reasons = { "in_bag", "not_in_inventory", "not_consumable", "verification_failed" } },
    move_item = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = SPEAKS,
        description = "Move a carried item between bag and hotbar (only hotbar food/drink can be used).",
        args = { type = "object", required = { "item", "to" }, properties = obj({
            item = str("A carried item's name or id."),
            to = { type = "string", enum = { "hotbar", "bag" }, description = "Where to put it." },
            slot = { type = "integer", minimum = 0, description = "Slot in that page (default: first free)." } }) },
        ground = obj({ item = "carried" }),
        reasons = { "not_in_inventory", "inventory_full", "verification_failed", "invalid_args" } },
    -- live-verified 2026-10-26 (2 Dirty Water from BP_WaterVolume_C at (157, 1914) m via move.shore_point)
    collect_water = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 8, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Collect water (Dirty Water) from a pond or river: walks to the bank, uses the water, checks it came in; "
            .. "repeats for count. Dirty Water is drinkable but unhealthy; boil it at a Campfire for Clean Water.",
        args = { type = "object", properties = obj({
            target = str("A water source's id from look (default: the nearest water)."),
            count = { type = "integer", minimum = 1, maximum = 20, default = 1, description = "How many." } }) },
        reasons = { "nothing_in_range", "unknown_target", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    store = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 8, timeout_s = 110,
        detail_is_speech = SPEAKS,
        description = "Put carried items into a chest or storage: walks there, opens it, moves them in, checks, closes it.",
        args = { type = "object", required = { "item", "container" }, properties = obj({
            item = str("A carried item's name or id."),
            container = str("The chest's id (from situation or look)."),
            count = { type = "integer", minimum = 1, description = "How many (default: all you carry)." } }) },
        ground = obj({ item = "carried", container = "thing" }),
        reasons = { "not_in_inventory", "not_enough_resources", "not_a_container", "container_full", "no_permission",
                    "unknown_target", "too_far", "path_blocked", "not_interactable", "verification_failed", "timeout" } },
    take = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 8, timeout_s = 110,
        detail_is_speech = SPEAKS,
        description = "Take items out of a chest or storage: walks there, opens it, moves them to your bag or hotbar, "
            .. "checks, closes it. Shared chests are fine; say what you took.",
        args = { type = "object", required = { "item", "container" }, properties = obj({
            item = str("The item's name or id."),
            container = str("The chest's id (from situation or look)."),
            count = { type = "integer", minimum = 1, description = "How many (default: all of it)." },
            to = { type = "string", enum = { "bag", "hotbar" }, default = "bag", description = "Where to put it." } }) },
        ground = obj({ container = "thing" }),
        reasons = { "not_in_container", "not_enough_resources", "not_a_container", "inventory_full", "no_permission",
                    "unknown_target", "too_far", "path_blocked", "not_interactable", "verification_failed", "timeout" } },
    equip = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = SPEAKS,
        description = "Equip a carried weapon, tool, shield or armour piece; answers once the game shows it in your hands or worn.",
        args = { type = "object", required = { "item" }, properties = obj({ item = str("A carried item's name or id.") }) },
        ground = obj({ item = "carried" }),
        reasons = { "not_in_inventory", "verification_failed" } },
    unequip = { kind = "waiter", llm = true, moves = false, duration_s = 1, timeout_s = 10, detail_is_speech = SPEAKS,
        description = "Put away a held item or take off a worn piece (into your bag); answers once the game shows it off.",
        args = { type = "object", properties = obj({ item = str("The equipped item's name or id."),
            slot = str("Or a loadout slot: HeldRight, HeldLeft, Head, Body, Legs, Cape.") }) },
        ground = obj({ item = "carried" }),
        reasons = { "invalid_args", "verification_failed" } },
    set_vitals_policy = { kind = "waiter", llm = true, moves = false, duration_s = 0, timeout_s = 10,
        description = "Set when your reflex eats, drinks or eats to heal by itself (% of max; a 10% floor always applies).",
        args = { type = "object", properties = obj({
            drink_below_pct = { type = "number", minimum = 10, maximum = 95, description = "Drink below this % hydration." },
            eat_below_pct = { type = "number", minimum = 10, maximum = 95, description = "Eat below this % food." },
            heal_below_pct = { type = "number", minimum = 0, maximum = 95, description = "Eat healing food below this % HP (0 = off)." },
            reserve_warn = { type = "integer", minimum = 0, maximum = 20, description = "Warn below this many usable items." } }) },
        reasons = { "invalid_args" } },
    explore = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 60, timeout_s = 300,
        detail_is_speech = SPEAKS,
        description = "Search outward, least-visited directions first, until something matching 'about' comes into view; "
            .. "reports what was found or how far you searched.",
        args = { type = "object", required = { "about" }, properties = obj({
            about = str("What to look for, in words (e.g. water, berries, a tree)."),
            max_legs = { type = "integer", minimum = 1, maximum = 12, default = 6, description = "How many legs." },
            leg_m = { type = "number", minimum = 8, maximum = 80, default = 30, description = "Metres per leg." } }) },
        reasons = { "already_in_sight", "nothing_in_range", "path_blocked", "interrupted", "timeout" } },
    fetch = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 8, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Pick up items lying on the ground by name or id (find, walk, face, use, verify; repeats for count)." .. COMPOUND,
        args = { type = "object", properties = obj({
            target = str("An id from situation or look (a world item or ground pickup)."),
            item = str("What to pick up, by name or item id."),
            count = { type = "integer", minimum = 1, maximum = 20, default = 1, description = "How many items." } }) },
        reasons = { "unknown_target", "nothing_in_range", "not_interactable", "too_far", "path_blocked", "verification_failed", "timeout" } },
    come_to = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 15, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Walk to a player and stop next to them (persistent follow until near)." .. COMPOUND,
        args = { type = "object", required = { "player" }, properties = obj({
            player = str("The player's exact name."),
            distance = { type = "number", minimum = 1, maximum = 10, default = 2, description = "Stop this close, metres." } }) },
        reasons = { "unknown_target", "path_blocked", "timeout", "interrupted" } },
    recover_grave = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 20, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Go to your own gravestone, Take All, verify, re-equip the last held tool." .. COMPOUND,
        args = { type = "object", properties = obj() },
        reasons = { "nothing_in_range", "ambiguous_target", "path_blocked", "not_interactable", "verification_failed", "timeout" } },
    give = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 15, timeout_s = 120,
        detail_is_speech = SPEAKS,
        description = "Walk to a player and drop carried items at their feet." .. COMPOUND,
        args = { type = "object", required = { "player", "item", "count" }, properties = obj({
            player = str("The player's exact name."), item = str("A carried item's name or id."),
            count = { type = "integer", minimum = 1, description = "How many." } }) },
        reasons = { "not_in_inventory", "not_enough_resources", "path_blocked", "unknown_target", "verification_failed", "timeout" } },
}

return M
