-- lodestone: fast travel the way a player does it (route R2; M5 long trips, M6 Goblin Diplomacy).
--
-- The player's path (dump 26161880, Dominion.hpp; DISCOVERIES "Lodestones, map regions and travel"):
--   1. walk to a lodestone (BP_WorldLodestone_C, prompt "Teleport") and press use: the game opens the map
--      (UBaseTeleportationComponent:OnInteractTeleportationObject(TeleporterIdentifier) on his controller's
--      LodestoneTeleportationComponent; UMapUIAPI:IsShowingMap() reads true);
--   2. click a destination lodestone on the map: the map widget calls the SAME component's
--      TryTeleport(FromId, ToId) (a local client function; it sends Server_TryTeleport itself), after the
--      game's own CanTeleport / CanAffordTeleportationCost (Law runes) checks;
--   3. the server moves him and answers Client_OnTeleportSuccessful(TargetLocation) (a Client RPC: a
--      read-only post-hook fires).
-- Never a position write (no K2_TeleportTo: that was the retired server puppet). The FGuids passed are the
-- LIVE structs read from AGameplayObjectRegistry.Lodestones (copies of engine structs, never built in Lua;
-- CLAUDE.md §0 rule 4), so no hand-built struct reaches an RPC.
--
-- Tools:
--   lodestones {}            read: every lodestone (position, the nearest region name when known, distance,
--                            reachable = the game's CanTeleport from the nearest lodestone, cost in runes)
--   teleport {to}            action: walk to the nearest lodestone, use it (map opens), TryTeleport to `to`
--                            (a lodestone id from `lodestones`, or a region / place name), verified by the
--                            success RPC AND his position within cfg.arrive_m of the destination. Reasons:
--                            not_unlocked (CanTeleport false), missing_materials (runes), unknown_target,
--                            already_there, too_far / path_blocked (walking to the lodestone),
--                            verification_failed (no map / no arrival), companion_down, interrupted.
-- Never under DW_PAUSE (a teleport is a level/stream change: the bridge pauses itself during it; the job
-- waits). UNVERIFIED live: steps 1-3 above; the map-close input after a refusal.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local M = { W = {} }
local W = M.W

M.cfg = { arrive_m = 25, success_wait_s = 30, map_wait_s = 4, list_ttl_s = 30, timeout_s = 150 }
M.HOOK = "/Script/Dominion.BaseTeleportationComponent:Client_OnTeleportSuccessful"

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function lower(s) return tostring(s or ""):lower() end
local function need_str(v) return type(v) == "string" and v ~= "" end
local function mem()
    local m = rawget(_G, "DWLodestone")
    if type(m) ~= "table" then m = { seq = 0 }; _G.DWLodestone = m end
    return m
end
local function d2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
local function sU(api) local s = api.module("sense"); return s and s.U, s end

-- ---------- world reads (replaceable in tests)
function W.pc(api) local _, s = sU(api); return s and s.local_pc and s.local_pc() or nil end
function W.component(api)
    local U = sU(api)
    local pc = W.pc(api)
    local c = pc and U.try(function() return pc.LodestoneTeleportationComponent end)
    return U.valid(c) and c or nil
end
-- The registry's lodestones: {{key (guid string), guid (the LIVE struct), position (m), respawn (m)}}, cached.
function W.registry_lodestones(api)
    local m = mem()
    local now = api.now()
    if m.list and m.list_t and now - m.list_t < M.cfg.list_ttl_s then return m.list end
    if paused() then return m.list or {} end
    local U = sU(api)
    local reg = U.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    local out = {}
    if U.valid(reg) then
        pcall(function()
            reg.Lodestones:ForEach(function(_, e)
                local d = U.try(function() return e:get() end) or e
                local g = U.try(function() return d.Identifier end)
                local function v(p) local ok, x, y, z = pcall(function() return p.X, p.Y, p.Z end); if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end end
                local key
                pcall(function() key = string.format("%08x%08x%08x%08x", g.A % 2 ^ 32, g.B % 2 ^ 32, g.C % 2 ^ 32, g.D % 2 ^ 32) end)
                if key then out[#out + 1] = { key = key, guid = g, position = v(d.Location), respawn = v(d.RespawnLocation) } end
            end)
        end)
    end
    m.list, m.list_t = out, now
    return out
end
function W.can_teleport(api, from, to)
    local U = sU(api)
    local c = W.component(api)
    if not c or paused() then return nil end
    local v = U.try(function() return c:CanTeleport(from.guid, to.guid) end)
    if v == nil then return nil end
    return v == true
end
function W.cost(api, from, to)
    local U = sU(api)
    local c = W.component(api)
    if not c or paused() then return nil, nil end
    local n = tonumber(U.try(function() return c:GetTeleportationCost(from.guid, to.guid) end))
    local afford = U.try(function() return c:CanAffordTeleportationCost(from.guid, to.guid) end)
    local item = U.try(function() return c.TeleportationCostItemData end)
    local s = api.module("sense")
    return n, afford == nil and nil or afford == true, s and s.item_name and s.item_name(item) or "Law Rune"
end
function W.try_teleport(api, from, to)
    local c = W.component(api)
    if not c or paused() then return false, "no LodestoneTeleportationComponent" end
    local ok, err = pcall(function() c:TryTeleport(from.guid, to.guid) end)
    return ok, (not ok) and tostring(err) or nil
end
function W.map_open(api)
    local U = sU(api)
    local m = mem()
    if not (m.map_api and U.valid(m.map_api)) then m.map_api = U.find_all("MapUIAPI", { skip_defaults = true })[1] end
    if not U.valid(m.map_api) then return nil end
    return U.try(function() return m.map_api:IsShowingMap() end) == true
end
function W.close_map(api) -- the UI's own back key (IA_UI_GenericBack), as Esc closes the map
    local U = sU(api)
    local IN = api.module("input")
    local a = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    if IN and a then return IN.raw_inject(a) end
    return false
end
function W.region_name(api, pos) -- the map region a point is in, when the travel helper knows it (optional)
    local tr = api.module("regions")
    if tr and type(tr.region_at) == "function" then local ok, r = pcall(tr.region_at, pos); if ok and r then return r.name or r end end
    return nil
end
function W.arm_hook(api)
    local m = mem()
    if m.armed then return true end
    local ok, hub = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/hookhub.lua"))() end)
    if not ok or type(hub) ~= "table" then return false end
    hub.on(M.HOOK, "lodestone:success", function() local s = rawget(_G, "DWLodestone"); if s then s.seq = (s.seq or 0) + 1; s.success_seq = s.seq end end,
        { log = api.log })
    m.armed = true
    return true
end
function W.success_seq() return mem().success_seq or 0 end

-- ---------- helpers
local function nearest(list, here)
    local best, bd
    for _, l in ipairs(list) do
        local p = l.respawn or l.position
        local d = p and here and d2(p, here)
        if d and (not bd or d < bd) then best, bd = l, d end
    end
    return best, bd
end
local function describe(api, l, from, here)
    local p = l.respawn or l.position
    local r = { id = "lodestone:" .. l.key, position = p, distance = here and p and math.floor(d2(here, p) + 0.5) or nil,
                region = W.region_name(api, p) }
    if from and from.key ~= l.key then
        r.reachable = W.can_teleport(api, from, l)
        local n, afford, item = W.cost(api, from, l)
        r.cost = n and { count = n, item = item, can_afford = afford } or nil
    elseif from then r.here = true end
    return r
end
function M.resolve(api, list, to, here)
    to = tostring(to or "")
    local key = to:match("^lodestone:(%x+)$")
    for _, l in ipairs(list) do if key and l.key == key then return l end end
    -- a region / place name: the lodestone in (or nearest to) that region, by the regions helper when present
    local q = lower(to)
    local best
    for _, l in ipairs(list) do
        local r = W.region_name(api, l.respawn or l.position)
        if r and (lower(r) == q or lower(r):find(q, 1, true)) then
            if not best or (here and d2(l.respawn or l.position, here) < d2(best.respawn or best.position, here)) then best = l end
        end
    end
    return best
end

M.HANDLERS = {}
M.NEEDS = { lodestones = { { "sense", "local_pc" } }, teleport = { { "sense", "local_pc" }, { "move", "go_to" }, { "move", "status" } } }

M.HANDLERS.lodestones = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    local here = api.my_position()
    local list = W.registry_lodestones(api)
    if #list == 0 then return api.fail("state_unavailable", { detail = "I can't read the lodestones right now." }) end
    local from = nearest(list, here)
    local out = {}
    for _, l in ipairs(list) do out[#out + 1] = describe(api, l, from, here) end
    table.sort(out, function(a, b) return (a.distance or 1e12) < (b.distance or 1e12) end)
    return { ok = true, data = { lodestones = out, nearest = out[1] and out[1].id or api.null } }
end

local function arbiter(api) local A = api.module("arbiter"); return A and type(A.request) == "function" and A or nil end

M.HANDLERS.teleport = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    if not need_str(args and args.to) then return api.fail("invalid_args", { detail = "to is required (a lodestone id from lodestones, or a region name)" }) end
    local here = api.my_position()
    local list = W.registry_lodestones(api)
    if #list < 2 then return api.fail("not_unlocked", { detail = "There's no other lodestone I could travel to." }) end
    local from, dfrom = nearest(list, here)
    local to = M.resolve(api, list, args.to, here)
    if not to then return api.fail("unknown_target", { to = args.to, detail = "I don't know a lodestone at " .. tostring(args.to) .. "." }) end
    if to.key == from.key then return api.fail("already_there", { detail = "That's the lodestone I'm next to." }) end
    local can = W.can_teleport(api, from, to)
    if can == false then
        return api.fail("not_unlocked", { to = "lodestone:" .. to.key, detail = "I can't teleport there yet: that lodestone isn't unlocked for me." })
    end
    local n, afford, item = W.cost(api, from, to)
    if afford == false then
        return api.fail("missing_materials", { missing = { { item = "ITEM_Rune_Law", name = item, need = n, have = nil } },
            detail = "Teleporting there costs " .. tostring(n or "some") .. " " .. tostring(item) .. ", and I don't have enough." })
    end
    W.arm_hook(api)
    local sk = api.module("skills")
    if not (sk and type(sk._new_episode) == "function" and type(sk._episode_poll) == "function") then
        return api.fail("not_implemented", { detail = "I can't use a lodestone yet." })
    end
    -- the lodestone ACTOR nearest the from-point (to walk to and press use on)
    local stone
    for _, t in ipairs(api.census_things(80, 40) or {}) do
        if t.category == "interactables" and (t.class or ""):find("Lodestone", 1, true) and (t.prompt or "") ~= "" then
            if not stone or (t.distance or 1e9) < (stone.distance or 1e9) then stone = t end
        end
    end
    if not stone then
        return api.fail("too_far", { detail = "I'm not near a lodestone (the nearest is " .. math.floor((dfrom or 0) + 0.5) .. " m away)." })
    end
    local job = { phase = "use", from = from, to = to, start = here, presses = {} }
    job.ep = sk._new_episode(api, stone, { label = "lodestone" })
    job.ep.need_gain = false
    local A = arbiter(api)
    local function release(why) if job.token and A then pcall(A.release, api.log, job.token, why); job.token = nil end end
    local function acquire()
        if job.own == "owner" or job.own == "none" or job.own == "suspended" then return true end
        if not A then job.own = "none"; return true end
        local r = A.request(api.log, { name = "skill:teleport", level = "command", uses_move = true, lease_s = 30, resumable = true,
            on_suspend = function() job.own = "suspended" end,
            on_resume = function() job.own = "owner"; job.resumed = true; return true end,
            on_stop = function(_, _, why) job.stopped = why or "stopped" end })
        if type(r) == "table" and r.ok then job.own, job.token = "owner", r.token; return true end
        job.own = "waiting"
        return false
    end
    local function fail_close(reason, d)
        if W.map_open(api) then W.close_map(api) end
        return api.fail(reason, d)
    end
    local a = { kind = "teleport", id = ctx.id, timeout_s = M.cfg.timeout_s }
    a.cancel = function() if not paused() then api.call("move", "stop"); if W.map_open(api) then W.close_map(api) end end; release("cancelled") end
    a.poll = function(self)
        if paused() then self.started = api.now(); return nil end -- the teleport itself pauses the bridge; just wait
        if job.stopped and job.phase ~= "travel" then release("stopped"); return fail_close("interrupted", { why = job.stopped,
            detail = "Something else took over (" .. tostring(job.stopped) .. "), so I didn't travel." }) end
        if not acquire() or job.own == "suspended" then self.started = api.now(); return nil end
        if job.resumed then job.resumed = nil; if job.phase == "use" then job.ep.phase, job.ep.moving = "approach", false end end
        local t = api.now()
        local res
        if job.phase == "use" then
            if W.map_open(api) then job.phase = "map" else
                local r = sk._episode_poll(api, job.ep, t)
                if r and not r.ok then release("failed"); return r end
                if r and r.ok then job.phase, job.map_until = "map_wait", t + M.cfg.map_wait_s end
            end
        end
        if job.phase == "map_wait" then
            if W.map_open(api) then job.phase = "map"
            elseif t >= job.map_until then release("failed"); return api.fail("verification_failed", { why = "map_not_open",
                detail = "I used the lodestone but its map didn't open." }) end
        end
        if job.phase == "map" then
            job.seq0 = W.success_seq()
            local ok, err = W.try_teleport(api, from, to)
            job.presses[#job.presses + 1] = "try_teleport"
            if not ok then release("failed"); return fail_close("verification_failed", { why = "try_teleport_failed", detail = "The teleport didn't start (" .. tostring(err) .. ")." }) end
            job.phase, job.until_t = "travel", t + M.cfg.success_wait_s
            return nil
        end
        if job.phase == "travel" then
            local now = api.my_position()
            local dest = to.respawn or to.position
            local arrived = now and dest and d2(now, dest) <= M.cfg.arrive_m
            if W.success_seq() > (job.seq0 or 0) and arrived then
                if W.map_open(api) then W.close_map(api) end
                release("done")
                return { ok = true, data = { from = "lodestone:" .. from.key, to = "lodestone:" .. to.key, position = now,
                    travelled_m = job.start and now and math.floor(d2(job.start, now) + 0.5) or api.null,
                    cost = n and { count = n, item = item } or api.null, region = W.region_name(api, dest) or api.null } }
            end
            if t >= job.until_t then
                release("failed")
                return fail_close("verification_failed", { why = arrived and "no_success_signal" or "not_arrived", position = now,
                    detail = arrived and "I seem to be at the lodestone but the game never confirmed the teleport."
                        or "I tried to teleport but I'm still here." })
            end
        end
        return res
    end
    return { pending = a }
end

-- ---------- manifest (llm = false until verified live: steps 1-3 in the header are UNVERIFIED)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    lodestones = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "Lodestones you could fast-travel to: where they are, whether you can reach them from the nearest one, and the rune cost. Read-only.",
        args = { type = "object", properties = obj() }, reasons = { "state_unavailable", "companion_down" } },
    teleport = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 20, timeout_s = 160,
        detail_is_speech = true,
        description = "Fast-travel like a player: walk to the nearest lodestone, use it, pick the destination on its map; checks you arrived.",
        args = { type = "object", required = { "to" }, properties = obj({
            to = { type = "string", description = "A lodestone id from lodestones, or a region name." } }) },
        reasons = { "not_unlocked", "missing_materials", "unknown_target", "already_there", "too_far", "path_blocked",
                    "interrupted", "verification_failed", "timeout" } },
}

return M
