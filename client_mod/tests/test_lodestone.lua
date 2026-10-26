-- Offline tests for client_mod/scripts/lodestone.lua (fast travel the player's way: use the lodestone, map opens,
-- TryTeleport with the registry's live ids, verified by the success RPC AND the arrival position).
-- Run: lua client_mod/tests/test_lodestone.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end

local L = assert(loadfile(root .. "/client_mod/scripts/lodestone.lua"))()
local W = L.W
local T = 0
local G
local function reset(opts)
    opts = opts or {}
    _G.DWLodestone = nil
    G = { pos = { 50, 1890, -35 }, map = false, seq = 0, tries = {}, closes = 0, can = opts.can ~= false, afford = opts.afford ~= false,
          no_map = opts.no_map, no_arrive = opts.no_arrive, no_signal = opts.no_signal, ep_polls = 0 }
    W.registry_lodestones = function() return {
        { key = "aaaa", guid = { A = 1 }, position = { 51, 1891, -35 }, respawn = { 52, 1892, -35 } },
        { key = "bbbb", guid = { A = 2 }, position = { 2100, 400, 10 }, respawn = { 2101, 401, 10 } },
    } end
    W.can_teleport = function(_, f, t) return G.can end
    W.cost = function() return 3, G.afford, "Law Rune" end
    W.map_open = function() return G.map end
    W.close_map = function() G.closes = G.closes + 1; G.map = false; return true end
    W.try_teleport = function(_, f, t)
        G.tries[#G.tries + 1] = { f.key, t.key }
        if not G.no_arrive then G.pos = { t.respawn[1] + 1, t.respawn[2], t.respawn[3] } end
        if not G.no_signal then _G.DWLodestone.seq = (_G.DWLodestone.seq or 0) + 1; _G.DWLodestone.success_seq = _G.DWLodestone.seq end
        return true
    end
    W.arm_hook = function() return true end
    W.region_name = function(_, p) if p and p[1] > 1000 then return "Manafem Plains" end return "Temple Woods" end
end
local api = {
    null = "NULL",
    now = function() return T end,
    my_position = function() return G.pos end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data } end,
    census_things = function() return { { id = "BP_WorldLodestone_C_1", class = "BP_WorldLodestone_C", category = "interactables",
                                          prompt = "Teleport", position = { 51, 1891, -35 }, distance = 2 } } end,
    call = function() return { ok = true } end,
    log = function() end,
}
local SK = {
    _new_episode = function(_, thing) return { thing = thing, phase = "approach" } end,
    _episode_poll = function(_, e, t)
        G.ep_polls = G.ep_polls + 1
        if G.ep_polls >= 2 then if not G.no_map then G.map = true end; return { ok = true, data = { target = e.thing.id } } end
        return nil
    end,
}
api.module = function(n) if n == "skills" then return SK end end
local function teleport(args, n)
    local h = L.HANDLERS.teleport(nil, args, { api = api, id = "t1" })
    if h.ok == false then return h end
    for _ = 1, n or 100 do T = T + 1; local r = h.pending:poll(); if r then return r end end
end

-- happy path by region name
reset()
local r = teleport({ to = "Manafem Plains" })
check("teleport by region: ok, arrived, success signal", r and r.ok and r.data.to == "lodestone:bbbb" and r.data.travelled_m > 1000, r and r.reason)
check("TryTeleport used the registry's ids (from the nearest, to the asked)", #G.tries == 1 and G.tries[1][1] == "aaaa" and G.tries[1][2] == "bbbb")

-- by id
reset()
r = teleport({ to = "lodestone:bbbb" })
check("teleport by id: ok", r and r.ok)

-- the game's gates before any walk or press
reset({ can = false })
r = teleport({ to = "lodestone:bbbb" })
check("CanTeleport false: not_unlocked, no press", r.reason == "not_unlocked" and #G.tries == 0 and G.ep_polls == 0)
reset({ afford = false })
r = teleport({ to = "lodestone:bbbb" })
check("can't afford the runes: missing_materials with the cost", r.reason == "missing_materials" and r.data.detail:find("3 Law Rune"), r.data and r.data.detail)
reset()
r = teleport({ to = "lodestone:aaaa" })
check("the one I'm at: already_there", r.reason == "already_there")
r = teleport({ to = "Atlantis" })
check("unknown place: unknown_target", r.reason == "unknown_target")

-- the map never opens -> verification_failed, no teleport
reset({ no_map = true })
r = teleport({ to = "lodestone:bbbb" })
check("map never opens: verification_failed map_not_open, no TryTeleport", r and r.reason == "verification_failed" and r.data.why == "map_not_open" and #G.tries == 0,
    r and r.data and r.data.why)

-- pressed but nothing happened: never a claimed success; the map is closed
reset({ no_arrive = true, no_signal = true })
r = teleport({ to = "lodestone:bbbb" })
check("no arrival: verification_failed not_arrived, map closed", r and r.reason == "verification_failed" and r.data.why == "not_arrived" and G.closes >= 1,
    r and r.data and r.data.why)
reset({ no_signal = true })
r = teleport({ to = "lodestone:bbbb" })
check("arrived but no success RPC: verification_failed no_success_signal", r and r.data and r.data.why == "no_success_signal")

-- pause: no calls (the teleport's own level change pauses the bridge)
reset()
local h = L.HANDLERS.teleport(nil, { to = "lodestone:bbbb" }, { api = api, id = "t2" })
_G.DW_PAUSE = true
for _ = 1, 10 do T = T + 1; h.pending:poll() end
check("paused: no episode polls, no TryTeleport", G.ep_polls == 0 and #G.tries == 0)
_G.DW_PAUSE = nil
local res
for _ = 1, 100 do T = T + 1; res = h.pending:poll(); if res then break end end
check("after the pause it goes on", res and res.ok)

-- the read tool
reset()
local lr = L.HANDLERS.lodestones(nil, {}, { api = api })
check("lodestones: nearest first, the far one reachable with its cost and region", lr.ok and lr.data.lodestones[1].here == true
    and lr.data.lodestones[2].reachable == true and lr.data.lodestones[2].cost.count == 3 and lr.data.lodestones[2].region == "Manafem Plains")

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
