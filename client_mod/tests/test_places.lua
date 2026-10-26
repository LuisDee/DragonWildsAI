-- Offline tests for client_mod/scripts/places.lua (pure geometry + the read_all shape with fake reads).
-- Usage: lua test_places.lua <empty_dir>
local _dir = assert(arg[1], "usage: lua test_places.lua <empty_dir>")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local P = dofile(here .. "/../scripts/places.lua")
local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

local big = { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } }
local small = { { 10, 10 }, { 30, 10 }, { 30, 30 }, { 10, 30 } }
local concave = { { 0, 0 }, { 50, 0 }, { 50, 50 }, { 25, 10 }, { 0, 50 } } -- a notch from the top
check("area", P.area(big) == 10000, P.area(big))
local bb = P.bbox(concave)
check("bbox", bb[1] == 0 and bb[2] == 0 and bb[3] == 50 and bb[4] == 50)
check("inside", P.inside(big, 50, 50) and not P.inside(big, 150, 50))
check("concave notch is outside", not P.inside(concave, 25, 40) and P.inside(concave, 5, 5))
check("degenerate polygon", not P.inside({ { 0, 0 }, { 1, 1 } }, 0, 0))
local regions = { { name = "Valley", polygon = big }, { name = "Village", polygon = small }, { name = "Empty", polygon = {} } }
check("smallest containing region wins", (P.region_at(regions, 20, 20) or {}).name == "Village")
check("outer region", (P.region_at(regions, 80, 80) or {}).name == "Valley")
check("no region", P.region_at(regions, 500, 500) == nil)

-- read_all with fake engine reads: our region agrees with the game's
P.W.regions = function() return { { name = "Valley", polygon = big }, { name = "Village", polygon = small } } end
P.W.landmarks = function() return { { desc = "Zanik", position = { 20, 20, 1 } } } end
P.W.me = function() return { position = { 20, 21, 0 }, game_region = "Village" } end
local all = P.read_all()
check("read_all shape", all.schema == "dw_places_raw/1" and #all.regions == 2 and #all.landmarks == 1)
check("agrees with the game", all.computed_region == "Village" and all.agrees == true, all.computed_region)
P.W.me = function() return { position = { 80, 80, 0 }, game_region = "Village" } end
check("disagreement is reported", P.read_all().agrees == false)
P.W.me = function() return {} end
check("no pawn: no claim", P.read_all().agrees == nil)
local h = P.HANDLERS.places(nil, { summary = true }, nil)
check("summary handler", h.ok and h.data.regions == 2 and h.data.landmarks == 1)
check("manifest is a read", P.MANIFEST.places.kind == "read" and P.MANIFEST.places.moves == false)

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
