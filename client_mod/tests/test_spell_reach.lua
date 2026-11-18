-- Offline tests for the spell's own camera-trace reach (2026-11-18, Bark to Bones Oak case) over a fake engine:
-- W.static reads CameraTraceDistance / CameraTraceIgnoreDistance (and marks them unread when the read fails), M.reach
-- caps the reach by a read trace > 0 and never widens it, an unread or 0 trace leaves the reach of before, the
-- approach stands closer by the trace, and client_mod/commands/spell_reach_probe.lua reads and logs every placed spell.
-- Run:  lua client_mod/tests/test_spell_reach.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local real_getenv = os.getenv
os.getenv = function(k) if k == "DW_CLIENT_ROOT" then return root end return real_getenv(k) end
package.path = root .. "/client_mod/scripts/?.lua;" .. package.path
local json = require("dkjson")
local pass, fails = 0, 0
local function check(name, c, info) if c then pass = pass + 1 else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

-- ---- fake engine: a UObject is a table; a key in `missing` raises on read (an unreadable property)
local function obj(full, props, missing)
    local t = props or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    if missing then
        setmetatable(t, { __index = function(_, k) if missing[k] then error("no property " .. k) end return nil end })
    end
    return t
end
local function arr(items)
    return { ForEach = function(_, fn) for i, v in ipairs(items) do if fn(i, { get = function() return v end }) then break end end end }
end
local function spell(asset, props, missing)
    props = props or {}
    props.SpellDisplayName = props.SpellDisplayName or asset
    return obj("UtilitySpellData /Game/Gameplay/UtilityMagic/PerkSpells/X/" .. asset .. "." .. asset, props, missing)
end

local SP = assert(loadfile(root .. "/client_mod/scripts/spells.lua"))()
local W = SP.W
SP.mem().roles = {}

-- ---- W.static: the trace read
local bark = spell("USD_Treequipment", { CastType = 1, CameraTraceDistance = 900, CameraTraceIgnoreDistance = 400 })
local st = W.static(bark)
check("static: trace read (m)", st.trace_read == true and st.trace_m == 9 and st.trace_ignore_m == 4, json.encode(st))
check("static: version bumped past 2 (cache survives hot reloads)", st.v == SP.STATIC_V and SP.STATIC_V >= 3)
local zero = W.static(spell("USD_Zero", { CastType = 1, CameraTraceDistance = 0, CameraTraceIgnoreDistance = 400 }))
check("static: a 0 trace is read as 0", zero.trace_read == true and zero.trace_m == 0)
local unread = W.static(spell("USD_Unread", { CastType = 1 }, { CameraTraceDistance = true, CameraTraceIgnoreDistance = true }))
check("static: an unreadable trace is unread, nil", unread.trace_read == false and unread.trace_m == nil and unread.trace_ignore_m == nil)
local ov = W.static(spell("USD_Over", { CastType = 1, bOverrideMaxPlacementDistanceFromCamera = true, MaxPlacementDistanceFromCamera = 1200,
                                        CameraTraceDistance = 900 }))
check("static: the override still read", ov.reach_m == 12 and ov.trace_m == 9)

-- ---- M.reach: the rule
local snap = { place_max_m = 15 }
local function reach(s, sn) local r, src = SP.reach(s, sn); return r, src end
local r, src = reach(st, snap)
check("reach: a read trace under the limit caps it", r == 9 and src == "spell_trace", tostring(r) .. " " .. tostring(src))
r, src = reach(unread, snap)
check("reach: unread trace = the component's 15 m, as before", r == 15 and src == "component", tostring(r) .. " " .. tostring(src))
r, src = reach(zero, snap)
check("reach: a 0 trace changes nothing", r == 15 and src == "component")
r, src = reach({ trace_m = 30, trace_read = true }, snap)
check("reach: a longer trace never widens it", r == 15 and src == "component")
r, src = reach(ov, snap)
check("reach: override 12 then trace 9 -> 9", r == 9 and src == "spell_trace")
r, src = reach({ reach_m = 12 }, snap)
check("reach: override alone", r == 12 and src == "spell_override")
r, src = reach(unread, nil)
check("reach: nothing read -> cfg 15 m", r == SP.cfg.place_max_m and src == "default")
r, src = reach(unread, { place_max_m = 0 })
check("reach: component 0 -> cfg", r == SP.cfg.place_max_m and src == "default")
-- the old expression, for every case without a trace: identical
for _, c in ipairs({ { {}, { place_max_m = 15 } }, { { reach_m = 7 }, { place_max_m = 15 } }, { {}, {} }, { {}, nil }, { { reach_m = 20 }, nil } }) do
    local s, sn = c[1], c[2]
    local old = s.reach_m or ((sn and sn.place_max_m and sn.place_max_m > 0) and sn.place_max_m) or SP.cfg.place_max_m
    check("reach: unchanged without a trace " .. json.encode(c), (SP.reach(s, sn)) == old)
end
local n = SP.reach_note(unread, snap)
check("reach_note: unread trace logged as unknown", n.trace_m == "unknown" and n.reach_m == 15 and n.reach_src == "component", json.encode(n))
n = SP.reach_note(st, snap)
check("reach_note: read trace", n.trace_m == 9 and n.trace_ignore_m == 4 and n.reach_src == "spell_trace")
n = SP.reach_note({}, snap)
check("reach_note: a stub without the read says nothing", n.trace_m == nil and n.reach_m == 15)

-- ---- the approach: the Oak case (target 10.5 m from him, ~13 m from the camera)
local saved = { cam_dist = W.cam_dist, move_go_to = W.move_go_to, inject = W.inject, snapshot = W.snapshot }
local function open_with(s, cam)
    local goes = 0
    W.cam_dist = function() return cam end
    W.move_go_to = function() goes = goes + 1; return true end
    W.inject = function() return true end
    W.snapshot = function() return { position = { 0, 0, 0 }, place_max_m = 15 } end
    local job = { api = { now = function() return 0 end }, st = s, d = {}, presses = {}, acts = {}, row = { name = "Bark to Bones" },
                  target = { kind = "point", position = { 10.5, 0, 0 } } }
    SP.begin_open(job, 0, { position = { 0, 0, 0 }, place_max_m = 15 })
    return job, goes
end
local job, goes = open_with(st, 13)
check("approach: trace 9 m, view 13 m -> walks closer first", job.phase == "approach" and goes == 1 and job.approach.reach == 9
      and job.approach.stand == 9 - SP.cfg.approach_margin_m, json.encode(job.approach))
job, goes = open_with(unread, 13)
check("approach: trace unread, view 13 m -> opens at once as before (15 m reach)", job.phase == "open" and goes == 0, job.phase)
job, goes = open_with(zero, 13)
check("approach: trace 0 -> as before", job.phase == "open" and goes == 0)
job, goes = open_with(st, 7.5)
check("approach: trace 9 m, view 7.5 m -> opens", job.phase == "open" and goes == 0)
for k, v in pairs(saved) do W[k] = v end

-- ---- the probe over a fake engine
local logs = {}
local comp = obj("SpellcastingComponent /Script/x.SC", { MinDistanceFromCameraToPlaceSpell = 500, MaxDistanceFromCameraToPlaceSpell = 1500,
                                                       TraceDistanceToClampSpellToSurface = 1000, AdjustSpellDistanceIncrement = 50 })
local pc = obj("BP_PlayerController_C /Game/x.PC", { SpellcastingComponent = comp })
local mod_move = obj("SpellModule_Movement /Game/x.USD_Shelter:SpellModule_Movement_0", { CameraTraceDistance = 0, CameraTraceIgnoreDistance = 400 })
local mod_cast = obj("SpellModule_Cast /Game/x.USD_Shelter:SpellModule_Cast_0", {})
local p_bark = spell("USD_Treequipment", { CastType = 1, CameraTraceDistance = 1000, CameraTraceIgnoreDistance = 400,
    bOverrideMaxPlacementDistanceFromCamera = false, MaxPlacementDistanceFromCamera = 1500, DistanceAboveGroundToPlaceSpell = 0,
    bAlwaysTryToPlaceOnSurface = true, TraceProfile = { Name = "SpellPlacement" } })
local p_shelter = spell("USD_SummonShelter", { CastType = 1, CameraTraceDistance = 0, CameraTraceIgnoreDistance = 400,
    Modules = { Modules = arr({ { Module = mod_move }, { Module = mod_cast } }) } })
local p_wind = spell("USD_Windstep", { CastType = 0, CameraTraceDistance = 0 })
local p_odd = spell("USD_Odd", { CastType = 2 }, { CameraTraceDistance = true })
local BARK_PATH = "/Game/Gameplay/UtilityMagic/PerkSpells/Treequipment/USD_Treequipment.USD_Treequipment"
function StaticFindObject(p) if p == BARK_PATH then return p_bark end return nil end
function FindAllOf(c) if c == "UtilitySpellData" then return { p_shelter, p_wind, p_odd, p_bark } end return {} end
local probe_sp = assert(loadfile(root .. "/client_mod/scripts/spells.lua"))()
probe_sp.mem().static, probe_sp.mem().roles = {}, {}
probe_sp.W.snapshot = function() return { place_max_m = 15, objects = { USD_SummonShelter = p_shelter }, unlocked = { USD_SummonShelter = true } } end
probe_sp.W.pc = function() return pc end
probe_sp.default_api = function() return { module = function() return nil end } end
local real_loadfile = loadfile
loadfile = function(p, ...)
    if tostring(p):match("client_mod/scripts/spells%.lua$") then return function() return probe_sp end end
    return real_loadfile(p, ...)
end
local probe = assert(real_loadfile(root .. "/client_mod/commands/spell_reach_probe.lua"))()
local okp, res = pcall(probe, function(m) logs[#logs + 1] = m end)
loadfile = real_loadfile
check("probe: runs", okp and type(res) == "table" and res.ok == true, tostring(res))
if okp and type(res) == "table" then
    local by = {}
    for _, r2 in ipairs(res.spells or {}) do by[r2.asset] = r2 end
    check("probe: Bark to Bones found and read", res.bark_found and by.USD_Treequipment and by.USD_Treequipment.trace_cm == 1000
          and by.USD_Treequipment.trace_ignore_cm == 400 and by.USD_Treequipment.trace_profile == "SpellPlacement"
          and by.USD_Treequipment.on_surface == true, json.encode(by.USD_Treequipment))
    check("probe: the cast's reach for Bark = its trace", by.USD_Treequipment and by.USD_Treequipment.reach_m == 10
          and by.USD_Treequipment.reach_src == "spell_trace")
    check("probe: placed spell with a module trace", by.USD_SummonShelter and by.USD_SummonShelter.unlocked == true
          and #by.USD_SummonShelter.modules == 1 and by.USD_SummonShelter.modules[1].trace_ignore_cm == 400
          and by.USD_SummonShelter.reach_m == 15, json.encode(by.USD_SummonShelter))
    check("probe: instant spells left out", by.USD_Windstep == nil)
    check("probe: an unreadable trace is listed as unread", by.USD_Odd and by.USD_Odd.trace_cm == nil and by.USD_Odd.static_trace_read == false
          and table.concat(res.unread, ","):find("USD_Odd.CameraTraceDistance", 1, true) ~= nil, json.encode(res.unread))
    check("probe: component limits", res.component and res.component.MinDistanceFromCameraToPlaceSpell == 500
          and res.component.MaxDistanceFromCameraToPlaceSpell == 1500)
    local all = table.concat(logs, "\n")
    check("probe: logs a line per spell + component", all:find("USD_Treequipment (placed): CameraTraceDistance 1000", 1, true)
          and all:find("component min 500", 1, true) and all:find("USD_SummonShelter", 1, true), all)
    check("probe: encodes as JSON", pcall(json.encode, res))
end
_G.DW_PAUSE = true
local okq, rq = pcall(probe, function() end)
check("probe: paused -> refuses", okq and rq.ok == false and rq.reason == "paused")
_G.DW_PAUSE = nil

print(string.format("test_spell_reach: %d passed, %d failed", pass, fails))
os.exit(fails == 0 and 0 or 1)
