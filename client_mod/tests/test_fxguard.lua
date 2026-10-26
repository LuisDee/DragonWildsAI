-- Offline test for client_mod/scripts/fxguard.lua (BUGS L38): every live player character's
-- TaggedLocalNiagaraSystems is emptied (own and other players' pawns, and the class defaults), an
-- already-empty map is left alone, a failed Empty() is reported, and healthy() follows the maps.
-- Fake UE objects only. Usage: lua test_fxguard.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_fxguard.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local repo = here .. "/../.."
os.execute('mkdir "' .. (dir .. "/mod/body"):gsub("/", "\\") .. '" 2>nul')
local src = assert(io.open(repo .. "/mod/body/util.lua", "rb")):read("a")
local f = assert(io.open(dir .. "/mod/body/util.lua", "wb")); f:write(src); f:close()

local pass, fail = 0, 0
local function check(c, msg) if c then pass = pass + 1; print("PASS " .. msg) else fail = fail + 1; print("FAIL " .. msg) end end

local function tmap(keys, broken)
    local m = { keys = keys }
    function m:ForEach(fn) for _, k in ipairs(self.keys) do fn({ get = function() return { TagName = k } end }, nil) end end
    function m:Empty() if broken then error("Empty unsupported") end self.keys = {} end
    return m
end
local function pawn(name, keys, broken)
    return { IsValid = function() return true end, HasAnyInternalFlags = function() return false end,
             GetFullName = function() return "BP_PlayerCharacter_C /Game/Maps/World/L_World.L_World:PersistentLevel." .. name end,
             TaggedLocalNiagaraSystems = tmap(keys, broken) }
end
local ALL = {}
_G.FindAllOf = function(cls) return cls == "DominionPlayerCharacter" and ALL or nil end
_G.os.getenv = (function(g) return function(k) if k == "DW_CLIENT_ROOT" then return dir end return g(k) end end)(os.getenv)
local F = assert(loadfile(repo .. "/client_mod/scripts/fxguard.lua"))()

-- menu: no pawns -> healthy, nothing applied
check(F.healthy() == true, "no player characters (menu): healthy")

local me = pawn("BP_PlayerCharacter_C_1", { "Environment.SoulScourge" })
local other = pawn("BP_PlayerCharacter_C_2", { "Environment.SoulScourge", "Future.Tag" })
local cdo = pawn("Default__BP_PlayerCharacter_C", { "Environment.SoulScourge" })
local empty = pawn("BP_PlayerCharacter_C_3", {})
ALL = { me, other, cdo, empty }
check(F.healthy() == false, "pawns with rows: not healthy")
local logs = {}
local r = F.start(function(m) logs[#logs + 1] = m end)
check(r.ok == true and r.guarded == true, "start(): ok and guarded")
check(#me.TaggedLocalNiagaraSystems.keys == 0, "own pawn emptied")
check(#other.TaggedLocalNiagaraSystems.keys == 0, "another player's pawn emptied (its tag events run on this client too)")
check(#cdo.TaggedLocalNiagaraSystems.keys == 0, "class default object emptied too (a respawned pawn copies it: no 10 s window)")
check(#r.applied == 3, "exactly the three maps with rows applied (empty map left alone)")
check(r.applied[2].keys[2] == "Future.Tag", "rows a future patch adds are covered (all keys reported)")
check(#logs == 3 and logs[1]:find("Environment.SoulScourge", 1, true) ~= nil, "each emptied map is logged with its keys")
check(F.healthy() == true, "after start(): healthy")

-- respawn: a fresh pawn arrives with the default rows -> unhealthy until the service re-applies
local new = pawn("BP_PlayerCharacter_C_4", { "Environment.SoulScourge" })
ALL[#ALL + 1] = new
check(F.healthy() == false, "fresh pawn (respawn/join): not healthy")
F.start(nil)
check(F.healthy() == true and #new.TaggedLocalNiagaraSystems.keys == 0, "service re-apply covers the fresh pawn")

-- a build where Empty() fails: reported, not healthy
local bad = pawn("BP_PlayerCharacter_C_5", { "Environment.SoulScourge" }, true)
ALL = { bad }
local rb = F.start(nil)
check(rb.ok == false and rb.reason == "write_failed" and rb.failed[1].err ~= nil, "Empty() failure reported truthfully")
check(F.healthy() == false, "failed write: not healthy (service retries with backoff)")

print(("%d/%d passed"):format(pass, pass + fail))
os.exit(fail == 0 and 0 or 1)
