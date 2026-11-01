-- Offline test for client_mod/scripts/mapplayers.lua: name matching (names cut short), compass words (north = -Y,
-- east = +X), sides of a facing player, and the registry read over a fake GameplayObjectRegistry (me flagged,
-- distances, the cache, the pause guard, pawn_of over PlayerStates).
-- Usage: lua test_mapplayers.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = here .. "/../.."
local real_getenv = os.getenv
os.getenv = function(k) if k == "DW_CLIENT_ROOT" then return root end return real_getenv(k) end
local MP = dofile(here .. "/../scripts/mapplayers.lua")
os.getenv = real_getenv

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- names
check("same name, other case", MP.same_name("ClaudeDev", "claudedev"))
check("a long name cut short matches the full one", MP.same_name("luisdeburnaybast", "luisdeburnaybastos"))
check("... both ways", MP.same_name("luisdeburnaybastos", "luisdeburnaybast"))
check("a short prefix is no match (luis)", not MP.same_name("luis", "luisdeburnaybast"))
check("different names", not MP.same_name("Zezima", "Zezimb"))
-- the game's name filter masks the registry name (live 2026-11-01): "luisdeburnaybast" -> "luisdeburnayb***t"
check("masked: the real character name", MP.same_name("luisdeburnayb***t", "luisdeburnaybast"))
check("masked: ... both ways", MP.same_name("luisdeburnaybast", "luisdeburnayb***t"))
check("masked: the account name (masked name cut short of it)", MP.same_name("luisdeburnayb***t", "luisdeburnaybastos"))
check("masked: a name cut short inside the visible head", MP.same_name("luisdeburnayb***t", "luisdeburnay"))
check("masked: a different ending is no match", not MP.same_name("luisdeburnayb***t", "luisdeburnaybasx"))
check("masked: a short name is no match", not MP.same_name("luisdeburnayb***t", "luis"))
check("masked: pattern characters in a name are literal", MP.same_name("a.b-c(d)e**f", "a.b-c(d)exyzf")
      and not MP.same_name("a.b-c(d)e**f", "aXb-c(d)exyzf"))
local rows = { { name = "luisdeburnaybast" }, { name = "ClaudeDev", me = true }, { name = "luisdeburnaybastard2" } }
check("pick: exact first", MP.pick(rows, "LUISDEBURNAYBAST") == rows[1])
check("pick: an ambiguous prefix picks nobody", MP.pick({ { name = "luisdeburnaybastos" }, rows[3] }, "luisdeburnaybast") == nil)
check("pick: the one prefix match", MP.pick({ rows[1] }, "luisdeburnaybastos") == rows[1])
check("pick: me is skipped", MP.pick(rows, "ClaudeDev", true) == nil and MP.pick(rows, "ClaudeDev") == rows[2])

-- compass: north = -Y, east = +X
local o = { X = 0, Y = 0 }
local function dir(x, y) return (MP.compass(o, { X = x, Y = y })) end
check("compass N = -Y", dir(0, -100) == "N", dir(0, -100))
check("compass E = +X", dir(100, 0) == "E", dir(100, 0))
check("compass S = +Y", dir(0, 100) == "S", dir(0, 100))
check("compass NE", dir(100, -100) == "NE", dir(100, -100))
check("compass SW", dir(-100, 100) == "SW", dir(-100, 100))
local _, b = MP.compass(o, { X = 100, Y = -100 })
check("bearing NE = 45", b == 45, b)
check("no direction at the same spot", MP.compass(o, { X = 0, Y = 0 }) == nil)

-- sides of someone facing yaw (UE yaw 0 = +X; +Y is to his right)
check("in front", MP.side(o, 0, { X = 200, Y = 10 }) == "in front")
check("behind", MP.side(o, 0, { X = -200, Y = 0 }) == "behind")
check("to the right (+Y facing +X)", MP.side(o, 0, { X = 0, Y = 200 }) == "to the right", MP.side(o, 0, { X = 0, Y = 200 }))
check("to the left", MP.side(o, 0, { X = 0, Y = -200 }) == "to the left")
check("facing south (yaw 90): +Y is in front", MP.side(o, 90, { X = 0, Y = 200 }) == "in front")

-- the registry read (fake UE objects; mod/body/util.lua reads plain tables directly)
local function obj(t) t.IsValid = function() return true end; t.GetFullName = t.GetFullName or function() return "X /Game/x" end; return t end
local function fstr(s) return { ToString = function() return s end } end
local reg_rows = {
    { OwningPlayerName = fstr("ClaudeDev"), Location = { X = 11377, Y = 184869, Z = -3115 }, Identifier = { A = 1, B = 2, C = 3, D = 4 } },
    { OwningPlayerName = fstr("luisdeburnaybast"), Location = { X = 11377 + 22600, Y = 184869 - 22600, Z = -3000 }, Identifier = { A = 5, B = 6, C = 7, D = 8 } },
}
local REG = obj({ PlayerCharacters = { ForEach = function(_, fn) for i, e in ipairs(reg_rows) do fn(i, { get = function() return e end }) end end } })
local me_pawn = obj({ PlayerState = obj({ GetPlayerName = function() return fstr("ClaudeDev") end }),
                      K2_GetActorLocation = function() return { X = 11377, Y = 184869, Z = -3115 } end })
local luis_pawn = obj({ K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
local states = {
    obj({ GetPlayerName = function() return fstr("ClaudeDev") end, PawnPrivate = me_pawn }),
    obj({ GetPlayerName = function() return fstr("luisdeburnaybast") end, PawnPrivate = nil }),
}
local reads = 0
function FindAllOf(c)
    if c == "GameplayObjectRegistry" then reads = reads + 1; return { REG } end
    if c == "PlayerState" then return states end
    return {}
end
_G.DWMapPlayers, _G.DWMapRegistry = nil, nil
local list = MP.players({ me = me_pawn, now = 100 })
check("registry: two rows", #list == 2, #list)
local me_row, luis_row
for _, r in ipairs(list) do if r.me then me_row = r else luis_row = r end end
check("registry: my own row is flagged me", me_row and me_row.name == "ClaudeDev" and me_row.distance == nil)
check("registry: his row: 320 m NE of me", luis_row and luis_row.direction == "NE" and math.abs(luis_row.distance - 319.6) < 0.5,
      luis_row and (tostring(luis_row.distance) .. " " .. tostring(luis_row.direction)))
check("registry: metres on the wire", luis_row and luis_row.position[1] == 339.77 and luis_row.position[3] == -30, luis_row and luis_row.position[1])
check("find: the account name finds the character cut short", MP.find("luisdeburnaybastos", { me = me_pawn, now = 100 }) ~= nil)
check("find: never me", MP.find("ClaudeDev", { me = me_pawn, now = 100 }) == nil)
-- cache: within ttl no second read of the registry array
local before = reads
reg_rows[2].Location = { X = 11377, Y = 184869 - 50000, Z = -3000 }
local again = MP.find("luisdeburnaybast", { me = me_pawn, now = 100.2 })
check("cache: within ttl the old row (no new read)", again and again.direction == "NE")
again = MP.find("luisdeburnaybast", { me = me_pawn, now = 100.7 })
check("cache: after ttl he moved (500 m N)", again and again.direction == "N" and math.abs(again.distance - 500) < 0.5, again and again.distance)
check("cache: the registry object itself is kept", reads == before, reads - before)
_G.DW_PAUSE = true
reg_rows[2].Location = { X = 0, Y = 0, Z = 0 }
again = MP.find("luisdeburnaybast", { me = me_pawn, now = 200 })
check("pause: no reads while the world changes (last rows kept)", again and again.direction == "N")
_G.DW_PAUSE = nil
-- the masked registry name takes his PlayerState's name, joined on the character GUID (live 2026-11-01)
local G1, G2 = { A = 9, B = 9, C = 9, D = 1 }, { A = 9, B = 9, C = 9, D = 2 }
reg_rows[1].OwningCharacterGuid, reg_rows[2].OwningCharacterGuid = { InnerGuid = G1 }, { InnerGuid = G2 }
reg_rows[2].OwningPlayerName = fstr("luisdeburnayb***t")
states[1].OwnerGuid, states[2].OwnerGuid = { CharacterGuid = { InnerGuid = G1 } }, { CharacterGuid = { InnerGuid = G2 } }
local named = MP.find("luisdeburnaybastos", { me = me_pawn, now = 300 })
check("masked: the row is named by his PlayerState", named and named.name == "luisdeburnaybast"
      and named.map_name == "luisdeburnayb***t", named and (tostring(named.name) .. " / " .. tostring(named.map_name)))
states[2].OwnerGuid = nil
_G.DWMapPlayers = nil
local unjoined = MP.find("luisdeburnaybast", { me = me_pawn, now = 400 })
check("masked: no PlayerState joined -> still found through the mask", unjoined and unjoined.name == "luisdeburnayb***t")
-- pawn_of: only a replicated pawn, never mine
check("pawn_of: out of sight -> nil", MP.pawn_of("luisdeburnaybastos", me_pawn) == nil)
states[2].PawnPrivate = luis_pawn
local pw, pname = MP.pawn_of("luisdeburnaybastos", me_pawn)
check("pawn_of: in sight -> his pawn and his in-game name", pw == luis_pawn and pname == "luisdeburnaybast", tostring(pname))
check("pawn_of: never my own pawn", MP.pawn_of("ClaudeDev", me_pawn) == nil)

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
