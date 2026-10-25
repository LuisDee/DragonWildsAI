-- Offline test for client_mod/scripts/hookhub.lua (BUGS L24): one native hook per UFunction per process,
-- never unregistered, deferred while not in the world, callbacks skipped under DW_PAUSE.
-- Usage: lua test_hookhub.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local FILE = here .. "/../scripts/hookhub.lua"
local fails, passes = 0, 0
local function check(name, cond, extra)
    if cond then passes = passes + 1; print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(extra)) end
end

local natives, unregisters = {}, 0
function RegisterHook(path, pre, post) natives[path] = (natives[path] or 0) + 1; _G["POST_" .. path] = post; return 1, 2 end
function UnregisterHook() unregisters = unregisters + 1 end

local P = "/Script/Dominion.DamageComponent:Multicast_ApplyDamageFromGameplayEffect"
local hub = dofile(FILE)
-- at the main menu: deferred, no native call
local ok, why = hub.on(P, "sense:on_damage", function() end, { defer = true })
check("deferred while not in the world", ok == false and natives[P] == nil, why)
-- in the world: registered once
local seen = {}
ok = hub.on(P, "sense:on_damage", function(a) seen[#seen + 1] = "sense:" .. tostring(a) end)
check("registered natively once in the world", ok and natives[P] == 1)
-- a second module on the same path (combat) shares the ONE native hook
ok = hub.on(P, "combat:on_damage", function(a) seen[#seen + 1] = "combat:" .. tostring(a) end)
check("a second subscriber adds no native hook", ok and natives[P] == 1, natives[P])
-- a hot reload of the module file (fresh instance) + re-subscribe: still one native hook
local hub2 = dofile(FILE)
hub2.on(P, "sense:on_damage", function(a) seen[#seen + 1] = "sense2:" .. tostring(a) end)
check("hot reload re-subscribes without a native call", natives[P] == 1)
-- the native callback dispatches to every subscriber; an erroring one doesn't stop the others
hub2.on(P, "broken", function() error("boom") end)
_G["POST_" .. P]("x")
table.sort(seen)
check("dispatch to all subscribers", #seen == 2 and seen[1] == "combat:x" and seen[2] == "sense2:x", table.concat(seen, ","))
check("an erroring subscriber is counted, not fatal", hub2.status().counts.errors == 1)
-- paused (disconnect / join / teardown): nothing runs, no parameter touched
seen = {}
_G.DW_PAUSE = true
_G["POST_" .. P](setmetatable({}, { __index = function() error("touched a param while paused") end }))
check("callbacks skipped while DW_PAUSE", #seen == 0 and hub2.status().counts.paused_skips == 1)
-- no registration while paused either
local ok3 = hub2.on("/Script/Dominion.HealthComponent:OnRep_AuthoritativeHealth", "sense:on_health", function() end)
check("no native registration while paused", ok3 == false and natives["/Script/Dominion.HealthComponent:OnRep_AuthoritativeHealth"] == nil)
_G.DW_PAUSE = nil
check("flush registers what was pending", hub2.flush() >= 1 and natives["/Script/Dominion.HealthComponent:OnRep_AuthoritativeHealth"] == 1)
-- off drops a subscriber; the native hook stays; UnregisterHook is never called
hub2.off(P, "combat:on_damage")
seen = {}
_G["POST_" .. P]("y")
check("off drops only that subscriber", #seen == 1 and seen[1] == "sense2:y")
check("UnregisterHook never called", unregisters == 0)
check("not_in_world: no pawn / front end", hub2.not_in_world(nil) and
    hub2.not_in_world({ GetFullName = function() return "BP_PlayerCharacter_C /Game/Maps/L_FrontEnd.L_FrontEnd:X" end }) and
    not hub2.not_in_world({ GetFullName = function() return "BP_PlayerCharacter_C /Game/Maps/World/L_World.L_World:X" end }))

-- the A/B switch: no native registration at all
_G.DWHookHub = nil
local hub3 = dofile(FILE)
hub3.status(); _G.DWHookHub.off = true
local before = natives["/Script/X.Y:Z"]
local ok4 = hub3.on("/Script/X.Y:Z", "k", function() end)
check("hooks-off switch: nothing registered", ok4 == false and natives["/Script/X.Y:Z"] == before and hub3.status().hooks_off)

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
