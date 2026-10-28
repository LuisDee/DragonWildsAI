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
local native_open, native_closed, native_ready = W.map_open, W.map_closed, W.map_ready
local T = 0
local G
local INPUT
local function reset(opts)
    opts = opts or {}
    _G.DWLodestone = nil
    if INPUT then INPUT.current = nil end
    G = { pos = { 50, 1890, -35 }, map = false, seq = 0, tries = {}, closes = 0, can = opts.can ~= false, afford = opts.afford ~= false,
          no_map = opts.no_map, no_arrive = opts.no_arrive, no_signal = opts.no_signal, ep_polls = 0 }
    W.registry_lodestones = function() return {
        { key = "aaaa", guid = { A = 1 }, position = { 51, 1891, -35 }, respawn = { 52, 1892, -35 } },
        { key = "bbbb", guid = { A = 2 }, position = { 2100, 400, 10 }, respawn = { 2101, 401, 10 } },
    } end
    W.can_teleport = function(_, f, t) return G.can end
    W.cost = function() return 3, G.afford end
    W.cost_item = function() return { item = "ITEM_Rune_Law", name = "Law Rune" } end
    W.map_open = function() return G.map end
    W.map_closed = function() return not G.map end
    W.map_ready = function() if G.ready == false then return nil end return {menu={},parent={}} end
    W.close_map = function() G.closes = G.closes + 1; G.map = false; return true end
    W.try_teleport = function(_, f, t)
        G.tries[#G.tries + 1] = { f.key, t.key }
        if not G.no_arrive then G.pos = { t.respawn[1] + 1, t.respawn[2], t.respawn[3] } end
        if not G.no_signal then _G.DWLodestone.seq = (_G.DWLodestone.seq or 0) + 1; _G.DWLodestone.success_seq = _G.DWLodestone.seq end
        return true
    end
    W.arm_hook = function() return true end
end
local api = {
    null = "NULL",
    now = function() return T end,
    my_position = function() return G.pos end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data } end,
    census_things = function() return { { id = "BP_WorldLodestone_C_1", class = "BP_WorldLodestone_C", category = "interactables", kind = "lodestone", actions = {"interact"}, position = { 51, 1891, -35 }, distance = 2 } } end,
    call = function() return { ok = true } end,
    log = function() end,
}
local SK = {
    -- skills.run_job's contract: {pending = {poll, cancel, timeout_s}}; pause = no step (as hold() does)
    run_job = function(_, _, job)
        local a = { timeout_s = 100 }
        job.token = 42
        job.own = "owner"
        G.job = job
        _G.DWArbiter = { owner = { token = 42 } }
        a.poll = function()
            if _G.DW_PAUSE then return nil end
            local r = job.pending_result or job.step(T)
            if r then job.pending_result=r; if job.cleanup and job.cleanup() == false then return nil end end
            return r
        end
        a.cancel = function() if job.cleanup then job.cleanup() end end
        return { pending = a }
    end,
    _new_episode = function(_, thing) return { thing = thing, phase = "approach" } end,
    _episode_poll = function(_, e, t, token)
        assert(token == 42, "parent token must reach episode")
        G.ep_polls = G.ep_polls + 1
        if G.ep_polls >= 2 then if not G.no_map then G.map = true end; return { ok = true, data = { target = e.thing.id } } end
        return nil
    end,
}
INPUT = { current = nil }
INPUT.owner = function() return INPUT.current end
INPUT.claim_if_free = function(_, owner) if INPUT.current then return false end INPUT.current = { owner = owner }; return true end
INPUT.release_if_owned = function(_, owner) if INPUT.current and INPUT.current.owner == owner then INPUT.current = nil; return true end return false end
api.module = function(n) if n == "skills" then return SK elseif n == "input" then return INPUT end end
local function teleport(args, n)
    local h = L.HANDLERS.teleport(nil, args, { api = api, id = "t1" })
    if h.ok == false then return h end
    for _ = 1, n or 100 do T = T + 1; local r = h.pending:poll(); if r then return r end end
end

-- happy path by position (the brain resolves its own place names to positions)
reset()
local r = teleport({ to = { 2100, 400, 10 } })
check("teleport to the lodestone nearest a point: ok, arrived, success signal", r and r.ok and r.data.to == "lodestone:bbbb" and r.data.travelled_m > 1000
    and r.data.cost.item == "Law Rune", r and r.reason)
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
r = teleport({ to = "Manafem Plains" })
check("a name is not resolved here (no false promise): unknown_target", r.reason == "unknown_target")

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

-- A foreign screen prevents any episode interaction and cannot be released.
reset()
INPUT.current = { owner = "foreign" }
h = L.HANDLERS.teleport(nil, { to = "lodestone:bbbb" }, { api = api, id = "foreign" })
T = T + 1
res = h.pending:poll()
check("foreign screen rejected without interacting", res and res.reason == "busy" and G.ep_polls == 0 and INPUT.current.owner == "foreign")

-- An action that loses its claim must not close or release the successor's map.
reset()
h = L.HANDLERS.teleport(nil, { to = "lodestone:bbbb" }, { api = api, id = "replaced" })
T = T + 1; h.pending:poll()
G.map = true; INPUT.current = { owner = "foreign" }
h.pending:cancel()
check("foreign replacement survives cancellation", G.map and G.closes == 0 and INPUT.current.owner == "foreign")

-- Suspension closes only its own map and releases its own claim.
reset()
h = L.HANDLERS.teleport(nil, { to = "lodestone:bbbb" }, { api = api, id = "suspend" })
T = T + 1; h.pending:poll()
G.map = true; G.job.own = "suspended"; _G.DWArbiter.owner = nil
G.job.on_suspend()
check("suspend requests own map closure and retains claim", not G.map and G.closes == 1 and INPUT.current ~= nil)
G.job.on_suspend()
check("suspend releases claim after observed closure", INPUT.current == nil)

-- The production widget census distinguishes closed from unknown; IsShowingMap is not used.
reset()
INPUT.observe_screens = function() return {{type=13,name="Map"},{type=29,name="TopBarMenu"}} end
INPUT.input_mode = function() return "DIM_FullScreenUIMap" end
check("widget census reports map despite stale view API",native_open(api)==true and native_closed(api)==false)
INPUT.observe_screens = function() return {} end
check("empty screens with map input mode are not closed",native_open(api)==false and native_closed(api)==false)
INPUT.input_mode = function() return "DIM_Gameplay" end
check("empty screens and gameplay mode confirm closure",native_closed(api)==true)
INPUT.observe_screens = function() return nil end
check("unreadable screen census is unknown",native_open(api)==nil and native_closed(api)==nil)

-- Actual binding reader rejects unrelated controller, panel and active parent.
local function object(id)
    return {IsValid=function() return true end, GetAddress=function() return id end,
            GetFullName=function() return "Class /Transient/" .. tostring(id) end}
end
local pc, other, panel, parent, stack, root_widget, menu = object(1),object(2),object(3),object(4),object(5),object(6),object(7)
parent.GetOwningPlayer=function() return pc end;parent.MapPanel=panel;parent.CurrentScreenWidget=panel
stack.GetActiveWidget=function() return parent end;root_widget.MainMenuStack=stack;menu.MainMenuWidget=root_widget
menu.GetCurrentScreenWidget=function() return parent end
FindAllOf=function(name) if name=="MainMenuUIAPI" then return {menu} end return {} end
INPUT.pc=function() return pc end
check("actual menu binding accepts matching local map parent",native_ready(api)~=nil)
parent.GetOwningPlayer=function() return other end
check("actual menu binding rejects foreign PC",native_ready(api)==nil)
parent.GetOwningPlayer=function() return pc end;parent.CurrentScreenWidget=other
check("actual menu binding rejects another panel",native_ready(api)==nil)
parent.CurrentScreenWidget=panel;stack.GetActiveWidget=function() return other end
check("actual menu binding waits for active stack",native_ready(api)==nil)
FindAllOf=function() return {} end

-- A delayed close request is submitted once and retains its claim until observed closed.
reset()
h = L.HANDLERS.teleport(nil, { to="lodestone:bbbb" }, { api=api,id="delayed" })
T=T+1;h.pending:poll(); G.map=true
W.close_map=function() G.closes=G.closes+1;return true end
check("close submission retains claim",G.job.cleanup()==false and G.closes==1 and INPUT.current~=nil)
check("still-open map does not repeat close",G.job.cleanup()==false and G.closes==1 and INPUT.current~=nil)
G.map=false
check("observed close releases claim",G.job.cleanup()==true and INPUT.current==nil)

-- The menu must be active before issuing a destination; suspension cannot replay it.
reset()
G.ready=false
h = L.HANDLERS.teleport(nil, {to="lodestone:bbbb"}, {api=api,id="ready"})
for _=1,4 do T=T+1;h.pending:poll() end
check("not-ready menu never issues teleport",#G.tries==0)
G.ready=true;T=T+1;h.pending:poll()
check("ready menu issues teleport once",#G.tries==1)
G.job.own="suspended";_G.DWArbiter.owner=nil;G.job.on_suspend()
G.job.own="owner";_G.DWArbiter.owner={token=42};G.job.on_resume()
for _=1,5 do T=T+1;res=h.pending:poll();if res then break end end
check("suspension does not replay issued teleport",#G.tries==1 and res and res.ok)

-- The read tool
reset()
local lr = L.HANDLERS.lodestones(nil, {}, { api = api })
check("lodestones: nearest first, the far one reachable with the cost item the game names", lr.ok and lr.data.lodestones[1].here == true
    and lr.data.lodestones[2].reachable == true and lr.data.lodestones[2].cost.count == 3 and lr.data.lodestones[2].cost.item == "Law Rune")

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
