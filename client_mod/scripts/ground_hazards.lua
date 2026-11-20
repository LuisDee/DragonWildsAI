-- ground_hazards.lua: STANDING ground hazards (poison clouds), read from the live world by PROPERTY, for perception
-- (sense.census "hazards" rows -> the brain's Hazards line) and for walks (move.lua's avoid-zone layer "ground": every
-- go_to / follow plans round them, gather and approach walks included). Data: the hazard_profiles.lua entries marked
-- `standing = true`: a cloud that stays where it is, whoever made it, so it is looked for without an AI action naming
-- it first (combat's census only runs after one). Why: 4 of 8 deaths in the L3 trials of 2026-11-20 were
-- BP_DEDA_PoisonBreath_PoisonCloud_C clouds (a UPoisonEmitterBox component) he walked through while gathering.
--
-- Engine reads, all made elsewhere already on these same classes (no new engine call):
--   FindAllOf(<native class>)                    combat.hazard_census, poison_emitters_probe
--   obj:IsValid(), obj:GetFullName()             everywhere (id, owner id and class word, skip Default__)
--   comp:K2_GetComponentLocation()               sense.read_damage on the PoisonEmitterBox that hurt him
--   comp:GetOwner()                              sense.read_damage, combat.hazard_census, the probe
--   PROPERTY reads on the native component       the profile's `extent` (FVector: UEffectEmitterBox.NetworkedExtent,
--                                                UBoxComponent.BoxExtent) or `radius` names, and
--                                                USceneComponent.RelativeScale3D. Native classes are never freed, so
--                                                plain reads are safe (ARCHITECTURE R17); the caller may pass U.prop.
-- Pure otherwise: offline test client_mod/tests/test_ground_hazards.lua.
local GH = {}

GH.cfg = {
    h_pad_cm = 200,     -- a zone's vertical reach is the box's half height plus this (his capsule over the box floor)
    max_scale = 20,     -- a RelativeScale3D component above this is taken as unread (1)
}

local function num(x) return type(x) == "number" and x == x and x or nil end
local function plain_read(o, name) local ok, v = pcall(function() return o[name] end); if ok then return v end end
local function try(f) local ok, v = pcall(f); if ok then return v end end
local function vec(v)
    if v == nil then return nil end
    local x, y, z = num(try(function() return v.X end)), num(try(function() return v.Y end)), num(try(function() return v.Z end))
    if x and y and z then return { X = x, Y = y, Z = z } end
end
local function fullname(o) local n = try(function() return o:GetFullName() end); return type(n) == "string" and n or nil end
local function short(o) local n = fullname(o); return n and (n:match("([%w_]+)$") or n) or nil end
local function class_word(o) local n = fullname(o); return n and n:match("^(%S+)") or nil end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function r1(x) return math.floor(x * 10 + 0.5) / 10 end

-- The profiles that are looked for without a trigger (data: hazard_profiles.lua `standing`).
function GH.standing(profiles)
    local out = {}
    for _, hp in ipairs(type(profiles) == "table" and profiles or {}) do
        if type(hp) == "table" and hp.standing and hp.class then out[#out + 1] = hp end
    end
    return out
end

-- Its size from its own properties: r_cm (horizontal reach), h_cm (vertical reach around its centre), ext (the box's
-- half extent in cm, scaled) | nil, read = "extent" | "radius" | "default". A box becomes the circle round its
-- half-diagonal, so it covers the box at any yaw (its rotation is not read).
function GH.size(o, hp, read)
    read = read or plain_read
    local sc = vec(read(o, "RelativeScale3D"))
    local sx, sy, sz = 1, 1, 1
    if sc and sc.X > 0 and sc.Y > 0 and sc.Z > 0 and sc.X < GH.cfg.max_scale and sc.Y < GH.cfg.max_scale and sc.Z < GH.cfg.max_scale then
        sx, sy, sz = sc.X, sc.Y, sc.Z
    end
    for _, n in ipairs(hp.extent or {}) do
        local e = vec(read(o, n))
        if e and e.X > 0 and e.Y > 0 then
            local ex, ey, ez = e.X * sx, e.Y * sy, math.max(e.Z, 0) * sz
            return math.sqrt(ex * ex + ey * ey), ez + GH.cfg.h_pad_cm, { X = ex, Y = ey, Z = ez }, "extent"
        end
    end
    for _, n in ipairs(hp.radius or {}) do
        local r = num(read(o, n))
        if r and r > 0 then return r * math.max(sx, sy), r * sz + GH.cfg.h_pad_cm, nil, "radius" end
    end
    return hp.radius_default or 400, (hp.h_default or 400), nil, "default"
end

-- Every live standing hazard within radius_cm of origin (cm): rows {id, hazard, words, effect, X, Y, Z (cm), r_cm, h_cm,
-- ext, size_from, owner, owner_class, dist_cm}, nearest first.
-- opts: profiles (all of hazard_profiles; the standing ones are kept), origin {X,Y,Z}, radius_cm (nil = any),
-- find (FindAllOf), read (property reader: U.prop or a plain read).
function GH.scan(opts)
    opts = opts or {}
    local find = opts.find or rawget(_G, "FindAllOf")
    if type(find) ~= "function" then return {} end
    local o0, rmax = opts.origin, opts.radius_cm
    local out, seen = {}, {}
    for _, hp in ipairs(GH.standing(opts.profiles)) do
        local okf, all = pcall(find, hp.class)
        for _, c in ipairs(okf and type(all) == "table" and all or {}) do
            local fn = valid(c) and fullname(c) or nil
            if fn and not fn:find("Default__", 1, true) then
                local owner = hp.component_is_hazard and try(function() return c:GetOwner() end) or nil
                if owner and not valid(owner) then owner = nil end
                local at = hp.component_is_hazard and vec(try(function() return c:K2_GetComponentLocation() end))
                    or vec(try(function() return c:K2_GetActorLocation() end))
                if at then
                    local id = (owner and short(owner)) or short(c) or "?"
                    if seen[id] then id = id .. "@" .. math.floor(at.X / 100) .. "_" .. math.floor(at.Y / 100) end
                    seen[id] = true
                    local d = o0 and math.sqrt((at.X - o0.X) ^ 2 + (at.Y - o0.Y) ^ 2) or nil
                    local r, h, ext, from = GH.size(c, hp, opts.read)
                    -- within the radius when its edge is (a big cloud whose middle is just out of range still counts)
                    if not (rmax and d and d - r > rmax) then
                        out[#out + 1] = { id = id, hazard = hp.name, words = hp.words or hp.name, effect = hp.effect,
                                          X = at.X, Y = at.Y, Z = at.Z, r_cm = r, h_cm = h, ext = ext, size_from = from,
                                          owner = owner and short(owner) or nil, owner_class = owner and class_word(owner) or nil,
                                          dist_cm = d }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.dist_cm or 0) < (b.dist_cm or 0) end)
    return out
end

-- move.lua avoid zones (the wire format: metres, scalars only), each lasting until until_s (the move clock).
function GH.zones(rows, until_s)
    local out = {}
    for _, r in ipairs(rows or {}) do
        out[#out + 1] = { id = tostring(r.hazard) .. ":" .. tostring(r.id), kind = "circle", x = r.X / 100, y = r.Y / 100,
                          z = r.Z / 100, r_cm = r.r_cm, h_cm = r.h_cm, until_s = until_s }
    end
    return out
end

-- A census row (category hazards; positions in metres like every census row): {id, kind = "ground_hazard", hazard,
-- name ("poison cloud"), effect, position, distance (m, to its edge, 0 inside), inside, across_m, direction (compass
-- from origin, when compass is given), owner_class}.
function GH.describe(r, origin, compass)
    local d = origin and math.sqrt((r.X - origin.X) ^ 2 + (r.Y - origin.Y) ^ 2) or nil
    local row = { id = r.id, kind = "ground_hazard", hazard = r.hazard, name = r.words, effect = r.effect,
                  position = { r1(r.X / 100), r1(r.Y / 100), r1(r.Z / 100) },
                  across_m = r1(2 * (r.ext and math.max(r.ext.X, r.ext.Y) or r.r_cm) / 100), owner_class = r.owner_class }
    if d then
        row.distance = r1(math.max(0, d - r.r_cm) / 100)
        row.center_m = r1(d / 100)
        row.inside = d <= r.r_cm or nil
    end
    if compass and origin then
        local okc, dir = pcall(compass, origin, { X = r.X, Y = r.Y })
        if okc and type(dir) == "string" then row.direction = dir end
    end
    return row
end

-- One line for the client log: "poison cloud BP_..._C_123 at [396.1,1681.4] r=5.2m (extent) 12 m NW".
function GH.log_words(r)
    return string.format("%s %s at [%.1f,%.1f,%.1f] r=%.1fm (%s)%s", tostring(r.words), tostring(r.id), r.X / 100, r.Y / 100,
        r.Z / 100, r.r_cm / 100, tostring(r.size_from), r.dist_cm and string.format(" %.0f m off", r.dist_cm / 100) or "")
end

return GH
