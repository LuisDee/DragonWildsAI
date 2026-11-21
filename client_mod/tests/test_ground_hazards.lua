-- Offline test for client_mod/scripts/ground_hazards.lua (standing poison clouds read by property) against the real
-- hazard_profiles.lua data and fake emitter components. Usage: lua test_ground_hazards.lua [empty_dir]
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local GH = dofile(here .. "/../scripts/ground_hazards.lua")
local PROF = dofile(here .. "/../scripts/hazard_profiles.lua")
local MAP = dofile(here .. "/../scripts/mapplayers.lua")

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

local function obj(t, full)
    t.IsValid = function() return not t._dead end
    t.GetFullName = function() return full end
    return t
end
local function cloud(n, at, props, owner_cls)
    local owner = obj({}, (owner_cls or "BP_DEDA_PoisonBreath_PoisonCloud_C") .. " /Game/L.L:PersistentLevel." .. (owner_cls or "BP_DEDA_PoisonBreath_PoisonCloud_C") .. "_" .. n)
    local c = obj(props or {}, "PoisonEmitterBox /Game/L.L:PersistentLevel." .. (owner_cls or "BP_DEDA_PoisonBreath_PoisonCloud_C") .. "_" .. n .. ".PoisonEmitterBox")
    function c:GetOwner() return owner end
    function c:K2_GetComponentLocation() return { X = at[1], Y = at[2], Z = at[3] } end
    return c, owner
end

-- the data: the box cloud that killed him is profiled, standing, in words
local std = GH.standing(PROF)
local box
for _, p in ipairs(std) do if p.class == "PoisonEmitterBox" then box = p end end
check("data: PoisonEmitterBox is a standing profile", box ~= nil and box.component_is_hazard and box.words == "poison cloud", box and box.name)
check("data: the box is sized by its extent (NetworkedExtent first)", box and box.extent and box.extent[1] == "NetworkedExtent")
check("data: triggered hazards (meteor, ground projectile) are not standing", (function()
    for _, p in ipairs(std) do if p.name == "meteor" or p.name == "ground_projectile" then return false end end
    return true end)())

-- size: extent (scaled), radius, default
do
    local c = cloud(1, { 0, 0, 0 }, { NetworkedExtent = { X = 300, Y = 400, Z = 150 }, RelativeScale3D = { X = 2, Y = 2, Z = 1 } })
    local r, h, ext, from = GH.size(c, box)
    check("size: half-diagonal of the scaled box", math.abs(r - 1000) < 0.01 and from == "extent", r)
    check("size: vertical reach = half height + pad", math.abs(h - (150 + GH.cfg.h_pad_cm)) < 0.01, h)
    check("size: extent kept for the row", ext and ext.X == 600 and ext.Y == 800, ext and ext.X)
    local c0 = cloud(2, { 0, 0, 0 }, { NetworkedExtent = { X = 0, Y = 0, Z = 0 }, BoxExtent = { X = 100, Y = 100, Z = 50 } })
    local r0, _, _, f0 = GH.size(c0, box)
    check("size: an unreplicated NetworkedExtent falls back to BoxExtent", math.abs(r0 - math.sqrt(2) * 100) < 0.01 and f0 == "extent", r0)
    local r1, _, _, f1 = GH.size(cloud(3, { 0, 0, 0 }, {}), box)
    check("size: nothing reads -> the profile's prior", r1 == box.radius_default and f1 == "default", r1)
    local sph = { radius = { "NetworkedRadius" }, radius_default = 400 }
    local rs, _, _, fs = GH.size(obj({ NetworkedRadius = 250 }, "PoisonEmitterSphere /x"), sph)
    check("size: a sphere by its radius", rs == 250 and fs == "radius", rs)
    local weird = cloud(4, { 0, 0, 0 }, { BoxExtent = { X = 100, Y = 0, Z = 50 }, RelativeScale3D = { X = 500, Y = 1, Z = 1 } })
    check("size: a zero-width extent or a crazy scale is not used", select(4, GH.size(weird, box)) == "default")
end

-- scan: fake FindAllOf; Default__ skipped, dead skipped, radius by the edge, ids from the owner, nearest first
do
    local near = cloud(10, { 1200, -900, 0 }, { NetworkedExtent = { X = 300, Y = 400, Z = 150 } }) -- 15 m NE-ish, r 5 m
    local far = cloud(11, { 9000, 0, 0 }, { NetworkedExtent = { X = 300, Y = 400, Z = 150 } })    -- 90 m: out of 60 m
    local edge = cloud(12, { 0, 6300, 0 }, { NetworkedExtent = { X = 300, Y = 400, Z = 150 } })   -- middle at 63 m, edge 58 m
    local dead = cloud(13, { 100, 0, 0 }, {}); dead._dead = true
    local cdo = obj({}, "PoisonEmitterBox /Script/Dominion.Default__PoisonEmitterBox")
    local asked = {}
    local function find(cls) asked[#asked + 1] = cls; if cls == "PoisonEmitterBox" then return { far, edge, near, dead, cdo } end return {} end
    local rows = GH.scan({ profiles = PROF, origin = { X = 0, Y = 0, Z = 0 }, radius_cm = 6000, find = find })
    check("scan: only standing classes are looked for", (function()
        for _, c in ipairs(asked) do if c ~= "PoisonEmitterBox" and c ~= "PoisonEmitterSphere" then return false end end
        return #asked == 2 end)(), table.concat(asked, ","))
    check("scan: in range by its edge; dead, CDO and far ones out", #rows == 2 and rows[1].id == "BP_DEDA_PoisonBreath_PoisonCloud_C_10"
        and rows[2].id == "BP_DEDA_PoisonBreath_PoisonCloud_C_12", #rows .. " " .. tostring(rows[1] and rows[1].id))
    check("scan: owner class and words on the row", rows[1].owner_class == "BP_DEDA_PoisonBreath_PoisonCloud_C" and rows[1].words == "poison cloud"
        and rows[1].hazard == "poison_cloud_box", rows[1].owner_class)
    -- two components on one owner: distinct ids
    local a = cloud(20, { 0, 0, 0 }, {}, "BP_Twin_C")
    local b = cloud(20, { 500, 0, 0 }, {}, "BP_Twin_C")
    local twins = GH.scan({ profiles = PROF, origin = { X = 0, Y = 0, Z = 0 }, find = function(c) if c == "PoisonEmitterBox" then return { a, b } end return {} end })
    check("scan: one owner with two boxes -> two ids", #twins == 2 and twins[1].id ~= twins[2].id, twins[1] and twins[2] and (twins[1].id .. " " .. twins[2].id))
    check("scan: FindAllOf failing is no hazards, no error", #GH.scan({ profiles = PROF, find = function() error("boom") end }) == 0)

    -- zones: move's wire format (metres, scalars), a lasting expiry
    local zs = GH.zones(rows, 123)
    local AZ = dofile(here .. "/../scripts/avoidzones.lua")
    local nz, err = AZ.normalize(zs, 100)
    check("zones: accepted by avoidzones.normalize", nz and #nz == 2, err)
    check("zones: id, metres, r_cm, until_s", zs[1].id == "poison_cloud_box:BP_DEDA_PoisonBreath_PoisonCloud_C_10" and zs[1].x == 12 and zs[1].y == -9
        and math.abs(zs[1].r_cm - 500) < 0.01 and zs[1].until_s == 123, zs[1].id)
    check("zones: he standing at the cloud's middle is inside it", nz and AZ.at(nz, 1200, -900, 0, 40) ~= nil)

    -- describe: the census row the brain reads (distance to the edge, compass, size, effect)
    local d = GH.describe(rows[1], { X = 0, Y = 0, Z = 0 }, MAP.compass)
    check("describe: kind, name, effect", d.kind == "ground_hazard" and d.name == "poison cloud" and tostring(d.effect):find("poison", 1, true), d.kind)
    check("describe: distance to its edge (15 m to the middle, r 5 m)", d.distance == 10 and d.center_m == 15 and not d.inside, d.distance)
    check("describe: compass from him (north = -Y)", d.direction == "NE", d.direction)
    check("describe: size across the box", d.across_m == 8, d.across_m)
    local din = GH.describe(rows[1], { X = 1100, Y = -900, Z = 0 }, MAP.compass)
    check("describe: inside = distance 0", din.inside == true and din.distance == 0, din.distance)
    check("log words name the cloud and where", GH.log_words(rows[1]):find("poison cloud BP_DEDA_PoisonBreath_PoisonCloud_C_10 at %[12.0,%-9.0,0.0%] r=5.0m %(extent%)") ~= nil,
        GH.log_words(rows[1]))
    check("log words: no life read, the rate", GH.log_words(rows[1]):find("life unread, 4 HP/s", 1, true) ~= nil, GH.log_words(rows[1]))
end

-- A damaging zone across the only way (live 2026-11-21 00:41:24Z): the zone carries what avoidzones.verdict needs.
-- dps from the profile (measured), until_s a LEASE (not its end), its end only from the owner's own life property.
do
    check("data: both poison profiles name a measured rate and life properties", (function()
        for _, p in ipairs(GH.standing(PROF)) do
            if not (type(p.dps) == "number" and p.dps > 0 and type(p.life) == "table" and p.life[1]) then return false end
        end
        return true end)())
    -- the owner's own lifetime: BP Duration first, then AActor.InitialLifeSpan; 0 (lives for ever) is no answer
    local c1, o1 = cloud(30, { 0, 0, 0 }, {})
    o1.Duration, o1.InitialLifeSpan = 0, 30
    local c2, o2 = cloud(31, { 300, 0, 0 }, {})
    o2.Duration = 12
    local c3 = cloud(32, { 600, 0, 0 }, {})
    local rows = GH.scan({ profiles = PROF, origin = { X = 0, Y = 0, Z = 0 }, find = function(c) if c == "PoisonEmitterBox" then return { c1, c2, c3 } end return {} end })
    local by = {}
    for _, r in ipairs(rows) do by[r.id] = r end
    local r1, r2, r3 = by["BP_DEDA_PoisonBreath_PoisonCloud_C_30"], by["BP_DEDA_PoisonBreath_PoisonCloud_C_31"], by["BP_DEDA_PoisonBreath_PoisonCloud_C_32"]
    check("life: Duration 0 -> InitialLifeSpan", r1 and r1.life_s == 30 and r1.life_from == "InitialLifeSpan", r1 and r1.life_s)
    check("life: the BP's own Duration", r2 and r2.life_s == 12 and r2.life_from == "Duration", r2 and r2.life_s)
    check("life: none reads -> unknown", r3 and r3.life_s == nil, r3 and r3.life_s)
    check("life: the row carries the profile's rate", r1 and r1.dps == 4, r1 and r1.dps)
    check("life: in the log words", GH.log_words(r2):find("lives 12s (Duration), 4 HP/s", 1, true) ~= nil, GH.log_words(r2))
    -- zones: a lease, seen/first times, ends = first seen + life (never sooner than the real end)
    local first = { [r1.id] = 90, [r2.id] = 99 }
    local zs = GH.zones(rows, 110, { seen_s = 100, first = first })
    local AZ = dofile(here .. "/../scripts/avoidzones.lua")
    local nz = assert(AZ.normalize(zs, 100))
    local zb = {}
    for _, z in ipairs(nz) do zb[z.id] = z end
    local z1, z2, z3 = zb["poison_cloud_box:" .. r1.id], zb["poison_cloud_box:" .. r2.id], zb["poison_cloud_box:" .. r3.id]
    check("zones: the scan's until_s is a lease; seen and first carried", z1.lease == true and z1.until_s == 110 and z1.seen_s == 100 and z1.first_s == 90, z1.first_s)
    check("zones: ends = first seen + its life", z1.ends_s == 120 and z2.ends_s == 111, tostring(z1.ends_s) .. " " .. tostring(z2.ends_s))
    check("zones: no life -> no end (first seen defaults to this scan)", z3.ends_s == nil and z3.first_s == 100, z3.ends_s)
    check("zones: dps and words carried", z1.dps == 4 and z1.words == "poison cloud", z1.dps)
    -- the verdicts (avoidzones.verdict) on these, at t = 100 with 100 HP: 4 HP/s gives 25 s
    local o = { hp = 100, dps_prior = 4, slack_s = 2 }
    local v1, v2, v3 = AZ.verdict(z1, 100, o), AZ.verdict(z2, 100, o), AZ.verdict(z3, 100, o)
    check("verdict: ends in 20 s (+2 slack) < 25 s -> hold", v1.act == "hold" and v1.wait_s == 20 and v1.budget_s == 25, v1.act .. " " .. tostring(v1.wait_s))
    check("verdict: ends in 11 s -> hold", v2.act == "hold" and v2.wait_s == 11, v2.act)
    check("verdict: lease only, end unknown -> blocked", v3.act == "blocked" and v3.why == "end_unknown", v3.act .. " " .. v3.why)
    local v4 = AZ.verdict(z1, 100, { hp = 80, dps_prior = 4, slack_s = 2 })
    check("verdict: 80 HP covers 20 s: 20 + 2 is not under it -> blocked too_long", v4.act == "blocked" and v4.why == "too_long", v4.act .. " " .. v4.why)
    check("verdict: health unread -> blocked", AZ.verdict(z1, 100, { dps_prior = 4 }).why == "hp_unread")
    check("verdict: past its end and still here -> blocked", AZ.verdict(z1, 121, o).why == "ended_late")
    check("verdict: a harmless zone is crossed", AZ.verdict({ harmless = true, until_s = 999 }, 100, o).act == "cross"
        and AZ.verdict({ dps = 0, lease = true, until_s = 999 }, 100, o).act == "cross")
    check("verdict: a fight zone (no lease) ends at until_s; no rate -> the prior", (function()
        local v = AZ.verdict({ until_s = 102 }, 100, o); return v.act == "hold" and v.rated == false and v.dps == 4 end)())
    check("verdict: no rate and no prior -> blocked", AZ.verdict({ until_s = 102 }, 100, { hp = 100 }).why == "rate_unknown")
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
