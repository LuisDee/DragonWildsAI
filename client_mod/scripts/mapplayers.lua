-- mapplayers.lua: every player the game's world map and HUD compass show, at ANY distance. READ ONLY.
--
-- Why (retro 2026-11-01, root cause 3): a player's pawn replicates to Claude's client only within net relevancy
-- (~150 m), so beyond that the census can't see him and go_to / follow answered target_not_visible six times.
-- A human looks at the compass. The game keeps AGameplayObjectRegistry.PlayerCharacters
-- (TArray<FPlayerCharacterData> {Location, RotationByte, OwningCharacterGuid, OwningPlayerUniqueID, OwningPlayerName,
-- Color, Identifier}, ReplicatedUsing OnRep_PlayerCharacters) for the map and the compass and replicates it to every
-- client (DISCOVERIES "Map and compass presence"; verified on Claude's client 2026-11-01: his own row "ClaudeDev" at
-- his pawn's exact position). Read the way lodestone.lua / places.lua read the same registry: ForEach over the live
-- array (never index past Num: UE4SS grows it), property reads of the live structs, nothing built, nothing written.
-- Prior art: mineflayer-pathfinder's dynamic GoalFollow (re-aim at the target as it moves; keep the original target
-- rather than re-picking): https://github.com/PrismarineJS/mineflayer-pathfinder
--
-- API (cm inside; rows' `position` is metres [x,y,z]):
--   M.players({me = pawn | me_pos = {X,Y,Z}, me_name, now}) -> rows {name, position, pos (cm), id, me = true|nil,
--        distance (m, horizontal, from me), direction ("NE"), bearing_deg (0 = north, 90 = east)}, nearest first
--   M.find(name, opts) -> the row of that player (never me) | nil, rows
--   M.pawn_of(name, me) -> his replicated pawn (not me) | nil       (PlayerState names, M.same_name)
--   M.same_name(a, b)  equal ignoring case, or one a prefix of the other with the shorter >= M.MIN_PREFIX chars: a
--        long name cut short ("luisdeburnaybast" is the character of the account "luisdeburnaybastos"); a name the
--        game's filter masked ("luisdeburnayb***t") matches with each run of '*' standing for hidden letters
--   Rows are named by their PlayerState (joined on the character GUID); `map_name` = the registry's masked name.
--   M.pick(rows, name, skip_me) -> exact (case-insensitive) first, else the ONE prefix match
--   M.compass(from, to) -> "N".."NW", bearing_deg | nil      north = world -Y, east = +X (DISCOVERIES "Map compass")
--   M.side(from, yaw_deg, to) -> "in front" | "behind" | "to the left" | "to the right" (of someone facing yaw_deg)
-- Pure parts take plain tables (client_mod/tests/test_mapplayers.lua); engine reads go through M.W (replaceable).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U -- mod/body/util.lua, loaded on first engine read (the pure parts never need it)
local function util()
    if U == nil then U = assert(loadfile(ROOT .. "/mod/body/util.lua"))() end
    return U
end

local M = { W = {} }
local W = M.W
M.cfg = { ttl_s = 0.5, max_rows = 64 }
M.MIN_PREFIX = 8

-- ---------------------------------------------------------------- pure
-- m: a name the game's name filter masked ("luisdeburnayb***t": runs of '*' stand for hidden letters, not
-- always as many); p: a plain name. Both lower case. Equal under the mask, or one cut short of the other.
local function masked_same(m, p)
    if p:find("*", 1, true) then return false end
    local pat = m:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*+", ".+")
    if p:find("^" .. pat .. "$") then return true end
    local visible = #m:gsub("%*", "")
    if visible >= M.MIN_PREFIX and p:find("^" .. pat) then return true end -- the masked name cut short of p
    local head = m:match("^[^*]*")
    return #p >= M.MIN_PREFIX and #p <= #head and head:sub(1, #p) == p -- p cut short, inside the visible head
end

function M.same_name(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
    a, b = a:lower(), b:lower()
    if a == b then return true end
    if a:find("*", 1, true) then return masked_same(a, b) end
    if b:find("*", 1, true) then return masked_same(b, a) end
    if #a > #b then a, b = b, a end
    return #a >= M.MIN_PREFIX and b:sub(1, #a) == a
end

function M.pick(rows, name, skip_me)
    local want = type(name) == "string" and name:lower() or ""
    if want == "" then return nil end
    local hit, n = nil, 0
    for _, r in ipairs(rows or {}) do
        if not (skip_me and r.me) and type(r.name) == "string" then
            if r.name:lower() == want then return r end
            if M.same_name(r.name, name) then hit, n = r, n + 1 end
        end
    end
    return n == 1 and hit or nil
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function M.compass(from, to)
    if not (from and to) then return nil end
    local east, north = to.X - from.X, from.Y - to.Y
    if east * east + north * north < 1 then return nil end
    local ang = (math.deg(math.atan(east, north)) + 360) % 360
    return DIRS[math.floor(((ang + 22.5) % 360) / 45) + 1], math.floor(ang + 0.5) % 360
end

-- UE yaw: 0 faces +X, 90 faces +Y (both in world space, seen from above)
function M.side(from, yaw_deg, to)
    if not (from and to and type(yaw_deg) == "number") then return nil end
    local dx, dy = to.X - from.X, to.Y - from.Y
    if dx * dx + dy * dy < 1 then return nil end
    local rel = (math.deg(math.atan(dy, dx)) - yaw_deg) % 360 -- 0 = straight ahead, 90 = his right (+Y side of +X)
    if rel <= 50 or rel >= 310 then return "in front" end
    if rel >= 130 and rel <= 230 then return "behind" end
    return rel < 180 and "to the right" or "to the left"
end

-- ---------------------------------------------------------------- engine reads
function W.registry()
    local u = util()
    local c = rawget(_G, "DWMapRegistry")
    if c and u.valid(c) then return c end
    local reg = u.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    _G.DWMapRegistry = reg
    return reg
end

-- -> {{name, pos = {X,Y,Z} cm, id, char}} straight from the replicated array (char = OwningCharacterGuid hex)
function W.read()
    local u = util()
    local out = {}
    local reg = W.registry()
    if not u.valid(reg) then return out end
    u.each(u.try(function() return reg.PlayerCharacters end), function(d)
        local ok, x, y, z = pcall(function() local l = d.Location; return l.X, l.Y, l.Z end)
        if ok and type(x) == "number" and type(y) == "number" then
            out[#out + 1] = { name = u.str(u.try(function() return d.OwningPlayerName end)), pos = { X = x, Y = y, Z = z or 0 },
                              id = u.guid_hex(u.try(function() return d.Identifier end)),
                              char = u.guid_hex(u.try(function() return d.OwningCharacterGuid.InnerGuid end)) }
        end
    end, M.cfg.max_rows)
    return out
end

-- PlayerStates (always relevant) -> {{name, pawn = the replicated pawn | nil, char = OwnerGuid.CharacterGuid hex}}
function W.states()
    local u = util()
    local out = {}
    for _, ps in ipairs(u.find_all("PlayerState", { skip_defaults = true })) do
        local n = u.str(u.try(function() return ps:GetPlayerName() end))
        if n and n ~= "" then
            local pw = u.prop(ps, "PawnPrivate") -- declared on the native APlayerState; R17-guarded anyway
            local og = u.prop(ps, "OwnerGuid") -- ADominionPlayerState (native); nil on another PlayerState class
            out[#out + 1] = { name = n, pawn = u.valid(pw) and pw or nil,
                              char = og and u.guid_hex(u.try(function() return og.CharacterGuid.InnerGuid end)) or nil }
        end
    end
    return out
end

-- The registry's OwningPlayerName can come masked by the game's name filter ("luisdeburnayb***t", live
-- 2026-11-01) while his PlayerState has the real name ("luisdeburnaybast"); the row's OwningCharacterGuid equals
-- that PlayerState's OwnerGuid.CharacterGuid (verified live), so each row takes the PlayerState's name.
local function named(rows)
    local by_char = {}
    for _, s in ipairs(W.states()) do if s.char then by_char[s.char] = s.name end end
    for _, r in ipairs(rows) do
        local n = r.char and by_char[r.char]
        if n and n ~= r.name then r.map_name, r.name = r.name, n end
    end
    return rows
end

function M.pawn_of(name, me)
    local hit, n
    for _, s in ipairs(W.states()) do
        if s.pawn and s.pawn ~= me then
            if type(name) == "string" and s.name:lower() == name:lower() then return s.pawn, s.name end
            if M.same_name(s.name, name) then hit, n = s, (n or 0) + 1 end
        end
    end
    if n == 1 then return hit.pawn, hit.name end
    return nil
end

function M.players(opts)
    opts = opts or {}
    local u = util()
    local t = opts.now or os.clock()
    local c = rawget(_G, "DWMapPlayers")
    if not c or t - c.t >= M.cfg.ttl_s or t < c.t then
        if rawget(_G, "DW_PAUSE") == true then -- no UObject reads while the world changes
            c = c or { t = t, rows = {} }
        else
            c = { t = t, rows = named(W.read()) }
            _G.DWMapPlayers = c
        end
    end
    local me_pos, me_name = opts.me_pos, opts.me_name
    if opts.me then
        me_pos = me_pos or u.loc(opts.me)
        me_name = me_name or u.player_name(opts.me)
    end
    local out = {}
    for _, r in ipairs(c.rows) do
        local row = { name = r.name, map_name = r.map_name, pos = { X = r.pos.X, Y = r.pos.Y, Z = r.pos.Z }, id = r.id }
        row.position = u.to_wire(row.pos)
        if me_name and type(r.name) == "string" and r.name:lower() == tostring(me_name):lower() then row.me = true end
        if me_pos then
            local d = u.dist2d(me_pos, row.pos)
            if not me_name and d < 100 then row.me = true end
            if not row.me then
                row.distance = u.cm_to_m(d)
                row.direction, row.bearing_deg = M.compass(me_pos, row.pos)
            end
        end
        out[#out + 1] = row
    end
    table.sort(out, function(a, b) return (a.distance or -1) < (b.distance or -1) end)
    return out
end

function M.find(name, opts)
    local rows = M.players(opts)
    return M.pick(rows, name, true), rows
end

return M
