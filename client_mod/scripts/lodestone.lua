-- lodestone: fast travel the way a player does it (route R2; M5 long trips, M6 Goblin Diplomacy).
--
-- The player's path (dump 26161880, Dominion.hpp; DISCOVERIES "Lodestones, map regions and travel"):
--   1. walk to a lodestone (BP_WorldLodestone_C, prompt "Teleport") and press use: the game opens the map
--      (UBaseTeleportationComponent:OnInteractTeleportationObject on his controller's
--      LodestoneTeleportationComponent; UMapUIAPI:IsShowingMap() reads true);
--   2. click a destination lodestone on the map: the map widget calls the SAME component's
--      TryTeleport(FromId, ToId) (a local client function; it sends Server_TryTeleport itself), after the
--      game's own CanTeleport / CanAffordTeleportationCost checks;
--   3. the server moves him and answers Client_OnTeleportSuccessful(TargetLocation) (a Client RPC: a
--      read-only post-hook fires).
-- Never a position write (no K2_TeleportTo: that was the retired server puppet). The FGuids passed are the
-- LIVE structs read from AGameplayObjectRegistry.Lodestones (copies of engine structs, never built in Lua).
--
-- Tools:
--   lodestones {}   read: every lodestone (position, distance, reachable = the game's CanTeleport from the
--                   nearest one, cost {count, item} with the cost item the game names)
--   teleport {to}   action: `to` = a lodestone id from `lodestones`, or [x, y, z] metres (the lodestone
--                   nearest that point: the brain resolves its own place names to positions). Walk to the
--                   nearest lodestone, use it (map opens), TryTeleport, verified by the success RPC AND his
--                   position within cfg.arrive_m of the destination. Reasons: not_unlocked, missing_materials,
--                   unknown_target, already_there, too_far, path_blocked, verification_failed, interrupted.
-- Job plumbing (arbiter, pause, busy-wait, reflex, lease renewal, cancel/cleanup) is skills.lua's run_job.
-- UNVERIFIED live: steps 1-3 above; the map-close input after a refusal.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
local M = { W = {} }
local W = M.W

M.cfg = { arrive_m = 25, success_wait_s = 30, map_wait_s = 4, list_ttl_s = 30, timeout_s = 160 }
M.HOOK = "/Script/Dominion.BaseTeleportationComponent:Client_OnTeleportSuccessful"

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function need_str(v) return type(v) == "string" and v ~= "" end
local function mem()
    local m = rawget(_G, "DWLodestone")
    if type(m) ~= "table" then m = {}; _G.DWLodestone = m end
    return m
end
local function d2(a, b) return U.dist2d(U.from_wire(a), U.from_wire(b)) / 100 end

-- ---------- world reads (replaceable in tests)
function W.pc(api) local s = api.module("sense"); return s and s.local_pc and s.local_pc() or nil end
function W.component(api)
    local pc = W.pc(api)
    local c = pc and U.try(function() return pc.LodestoneTeleportationComponent end)
    return U.valid(c) and c or nil
end
-- The registry's lodestones: {{key (guid hex), guid (the LIVE struct), position (m), respawn (m)}}, cached.
function W.registry_lodestones(api)
    local m = mem()
    local now = api.now()
    if m.list and m.list_t and now - m.list_t < M.cfg.list_ttl_s then return m.list end
    if paused() then return m.list or {} end
    local reg = U.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    local out = {}
    if U.valid(reg) then
        pcall(function()
            reg.Lodestones:ForEach(function(_, e)
                local d = U.try(function() return e:get() end) or e
                local g = U.try(function() return d.Identifier end)
                local key = U.guid_hex(g)
                local function v(p) local ok, x, y, z = pcall(function() return p.X, p.Y, p.Z end); if ok and type(x) == "number" then return { x / 100, y / 100, z / 100 } end end
                if key then out[#out + 1] = { key = key, guid = g, position = v(d.Location), respawn = v(d.RespawnLocation) } end
            end)
        end)
    end
    m.list, m.list_t = out, now
    return out
end
function W.can_teleport(api, from, to)
    local c = W.component(api)
    if not c or paused() then return nil end
    local v = U.try(function() return c:CanTeleport(from.guid, to.guid) end)
    if v == nil then return nil end
    return v == true
end
-- The cost item the game names (TeleportationCostItemData), read once per session -> {item, name} | nil
function W.cost_item(api)
    local m = mem()
    if m.cost_item ~= nil then return m.cost_item or nil end
    local c = W.component(api)
    local d = c and U.try(function() return c.TeleportationCostItemData end)
    if not U.valid(d) then return nil end
    local p = U.path_of(d)
    local name = U.str(U.try(function() return d.Name end))
    m.cost_item = { item = p and p:match("%.([%w_]+)$") or U.short(d), name = name or U.short(d) }
    return m.cost_item
end
function W.cost(api, from, to)
    local c = W.component(api)
    if not c or paused() then return nil, nil end
    local n = tonumber(U.try(function() return c:GetTeleportationCost(from.guid, to.guid) end))
    local afford = U.try(function() return c:CanAffordTeleportationCost(from.guid, to.guid) end)
    return n, afford == nil and nil or afford == true
end
function W.try_teleport(api, from, to)
    local c = W.component(api)
    if not c or paused() then return false, "no LodestoneTeleportationComponent" end
    local ok, err = pcall(function() c:TryTeleport(from.guid, to.guid) end)
    return ok, (not ok) and tostring(err) or nil
end
function W.map_open(api)
    local m = mem()
    if not (m.map_api and U.valid(m.map_api)) then m.map_api = U.find_all("MapUIAPI", { skip_defaults = true })[1] end
    if not U.valid(m.map_api) then return nil end
    return U.try(function() return m.map_api:IsShowingMap() end) == true
end
-- The game's own HUD close for the Map widget (InputManagerUIAPI:CloseWidgetIfOpen, EWidgetType Map 13, via
-- input.close_screens: the close verified live on the Processing panel, BUGS B-stuck-focused-ui); the UI's own
-- back key (IA_UI_GenericBack, as Esc) only when that API is missing.
M.MAP_WIDGET = 13
function W.close_map(api)
    local IN = api.module("input")
    if IN and type(IN.close_screens) == "function" then
        local ok, closed = pcall(IN.close_screens, { M.MAP_WIDGET })
        if ok and closed then return true end
    end
    local a = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_UI_GenericBack.IA_UI_GenericBack")
    if IN and a then return IN.raw_inject(a) end
    return false
end
function W.arm_hook(api)
    local m = mem()
    if m.armed then return true end
    local ok, hub = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/hookhub.lua"))() end)
    if not ok or type(hub) ~= "table" then return false end
    hub.on(M.HOOK, "lodestone:success", function()
        local s = rawget(_G, "DWLodestone"); if s then s.success_seq = (s.success_seq or 0) + 1 end
    end, { log = api.log })
    m.armed = true
    return true
end
function W.success_seq() return mem().success_seq or 0 end

-- ---------- helpers
local function nearest(list, p)
    local best, bd
    for _, l in ipairs(list) do
        local q = l.respawn or l.position
        local d = q and p and d2(q, p)
        if d and (not bd or d < bd) then best, bd = l, d end
    end
    return best, bd
end
local function describe(api, l, from, here, item)
    local p = l.respawn or l.position
    local r = { id = "lodestone:" .. l.key, position = p, distance = here and p and math.floor(d2(here, p) + 0.5) or nil }
    if from and from.key ~= l.key then
        r.reachable = W.can_teleport(api, from, l)
        local n, afford = W.cost(api, from, l)
        r.cost = n and { count = n, item = item and item.name or nil, can_afford = afford } or nil
    elseif from then r.here = true end
    return r
end
-- `to` = "lodestone:<hex>" or [x, y, z] metres (the lodestone nearest that point)
function M.resolve(list, to)
    if type(to) == "table" and type(to[1]) == "number" then return (nearest(list, to)) end
    local key = tostring(to or ""):match("^lodestone:(%x+)$")
    for _, l in ipairs(list) do if key and l.key:lower() == key:lower() then return l end end
    return nil
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
    local item = W.cost_item(api)
    local out = {}
    for _, l in ipairs(list) do out[#out + 1] = describe(api, l, from, here, item) end
    table.sort(out, function(a, b) return (a.distance or 1e12) < (b.distance or 1e12) end)
    return { ok = true, data = { lodestones = out, nearest = out[1] and out[1].id or api.null } }
end

M.HANDLERS.teleport = function(log, args, ctx)
    local api = ctx and ctx.api
    if not api then return { ok = false, reason = "body_error", data = { detail = "needs ctx.api" } } end
    if paused() then return api.fail("companion_down", { detail = "I'm not in the world right now." }) end
    args = args or {}
    if not (need_str(args.to) or type(args.to) == "table") then
        return api.fail("invalid_args", { detail = "to is required (a lodestone id from lodestones, or [x, y, z])" })
    end
    local sk = api.module("skills")
    if not (sk and type(sk.run_job) == "function" and type(sk._new_episode) == "function" and type(sk._episode_poll) == "function") then
        return api.fail("not_implemented", { detail = "I can't use a lodestone yet." })
    end
    local here = api.my_position()
    local list = W.registry_lodestones(api)
    if #list < 2 then return api.fail("not_unlocked", { detail = "There's no other lodestone I could travel to." }) end
    local from, dfrom = nearest(list, here)
    local to = M.resolve(list, args.to)
    if not to then return api.fail("unknown_target", { to = args.to, detail = "I don't know that lodestone." }) end
    if to.key == from.key then return api.fail("already_there", { detail = "That's the lodestone I'm next to." }) end
    if W.can_teleport(api, from, to) == false then
        return api.fail("not_unlocked", { to = "lodestone:" .. to.key, detail = "I can't teleport there yet: that lodestone isn't unlocked for me." })
    end
    local n, afford = W.cost(api, from, to)
    local item = W.cost_item(api) or { item = nil, name = "runes" }
    if afford == false then
        return api.fail("missing_materials", { missing = { { item = item.item, name = item.name, need = n } },
            detail = "Teleporting there costs " .. tostring(n or "some") .. " " .. tostring(item.name) .. ", and I don't have enough." })
    end
    local stone -- the lodestone ACTOR nearest me (to walk to and press use on)
    for _, t in ipairs(api.census_things(80, 40) or {}) do
        if t.category == "interactables" and (t.class or ""):find("Lodestone", 1, true) and (t.prompt or "") ~= "" then
            if not stone or (t.distance or 1e9) < (stone.distance or 1e9) then stone = t end
        end
    end
    if not stone then
        return api.fail("too_far", { detail = "I'm not near a lodestone (the nearest is " .. math.floor((dfrom or 0) + 0.5) .. " m away)." })
    end
    W.arm_hook(api)
    local job = { kind = "teleport", phase = "use", from = from, to = to, start = here }
    job.ep = sk._new_episode(api, stone, { label = "lodestone" })
    local IN = api.module("input") -- the map is MEANT to be open during this job (input's stray-screen guard)
    if IN and IN.claim then pcall(IN.claim, "screen", "teleport") end
    local function close()
        if IN and IN.release then pcall(IN.release, "screen") end
        if not paused() and W.map_open(api) then W.close_map(api) end
    end
    local function fail_close(reason, d) close(); return api.fail(reason, d) end
    job.cleanup = close
    job.on_resume = function() if job.phase == "use" then job.ep.phase, job.ep.moving = "approach", false end end
    job.step = function(t)
        if job.phase == "use" then
            if W.map_open(api) then job.phase = "map" else
                local r = sk._episode_poll(api, job.ep, t)
                if r and not r.ok then return r end
                if r then job.phase, job.map_until = "map_wait", t + M.cfg.map_wait_s end
                return nil
            end
        end
        if job.phase == "map_wait" then
            if W.map_open(api) then job.phase = "map"
            elseif t >= job.map_until then return api.fail("verification_failed", { why = "map_not_open", detail = "I used the lodestone but its map didn't open." })
            else return nil end
        end
        if job.phase == "map" then
            job.seq0 = W.success_seq()
            local ok, err = W.try_teleport(api, from, to)
            if not ok then return fail_close("verification_failed", { why = "try_teleport_failed", detail = "The teleport didn't start (" .. tostring(err) .. ")." }) end
            job.phase, job.until_t = "travel", t + M.cfg.success_wait_s
            return nil
        end
        local now = api.my_position()
        local dest = to.respawn or to.position
        local arrived = now and dest and d2(now, dest) <= M.cfg.arrive_m
        if W.success_seq() > (job.seq0 or 0) and arrived then
            close()
            return { ok = true, data = { from = "lodestone:" .. from.key, to = "lodestone:" .. to.key, position = now,
                travelled_m = job.start and math.floor(d2(job.start, now) + 0.5) or api.null,
                cost = n and { count = n, item = item.name } or api.null } }
        end
        if t >= job.until_t then
            return fail_close("verification_failed", { why = arrived and "no_success_signal" or "not_arrived", position = now,
                detail = arrived and "I seem to be at the lodestone but the game never confirmed the teleport." or "I tried to teleport but I'm still here." })
        end
        return nil
    end
    local h = sk.run_job(api, ctx, job)
    if type(h) == "table" and h.pending then h.pending.timeout_s = M.cfg.timeout_s end
    return h
end

-- ---------- manifest (llm = false until verified live: steps 1-3 in the header are UNVERIFIED)
local OBJ = { __jsontype = "object" }
local function obj(t) return setmetatable(t or {}, OBJ) end
M.MANIFEST = {
    lodestones = { kind = "read", llm = true, moves = false, duration_s = 0.5, timeout_s = 15,
        description = "Lodestones you could fast-travel to: where they are, whether you can reach them from the nearest one, and the cost. Read-only.",
        args = { type = "object", properties = obj() }, reasons = { "state_unavailable", "companion_down" } },
    teleport = { kind = "action", llm = false, moves = true, priority = "command", duration_s = 20, timeout_s = 170,
        detail_is_speech = true,
        description = "Fast-travel like a player: walk to the nearest lodestone, use it, pick the destination on its map; checks you arrived.",
        args = { type = "object", required = { "to" }, properties = obj({
            to = { description = "A lodestone id from lodestones, or [x, y, z] metres (the lodestone nearest that point)." } }) },
        reasons = { "not_unlocked", "missing_materials", "unknown_target", "already_there", "too_far", "path_blocked",
                    "interrupted", "verification_failed", "timeout" } },
}

return M
