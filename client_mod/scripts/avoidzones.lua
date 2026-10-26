-- avoidzones.lua: AVOID ZONES for client-side locomotion (route R2; docs/design/velgar.md section 3c).
-- Pure geometry, no engine calls (unit-tested offline: client_mod/tests/test_avoidzones.lua).
--
-- Pattern (adapted, not invented; search record in docs/DISCOVERIES.md "Avoid zones"):
--   * hazards are a COST on the planner's cells, not walls (influence-map pathfinding: Critch &
--     Churchill, CoG 2021 sneak-attack A*; Unity forum advice "integrate danger into the path cost
--     and agents avoid it without being told"); sooner-expiring zones cost less, so when no other
--     way exists the route crosses the one that ends soonest;
--   * "get out now" = an EQS-style query: generate candidate points around us (rays in 32
--     directions, the first point along each ray that is outside every zone), filter by the bound,
--     score by distance, then test reachability (done by move.lua with real traces).
--
-- Zone (wire format, scalars only: UE4SS R15 crashes on struct userdata inside Lua table params):
--   { id = "breath1", kind = "circle" | "cone", x, y, z (METRES, like every move API), r_cm,
--     until_s (same clock as move/combat: GameplayStatics:GetRealTimeSeconds) | ttl_s (relative),
--     yaw_deg, half_angle_deg (cone: apex at x,y, axis yaw_deg, range r_cm), h_cm (vertical reach
--     above/below z, default 400; z omitted = any height) }
-- Internal zone: same fields in cm (X, Y, Z, r, h, yaw (rad), half (rad), until_s, id, kind).
local AZ = {}

AZ.cfg = {
    h_cm = 400,          -- default vertical reach of a zone around its z
    cost_base = 20,      -- planner cost (in cells) for a cell inside a zone ...
    cost_per_s = 2,      -- ... plus this per second the zone still lasts ...
    cost_max = 60,       -- ... capped (a zone that is about to end is cheaper to cross)
    rays = 32,           -- escape candidates: rays around us
    ray_step_cm = 25,
    max_abs_m = 50000,   -- sanity: |x| or |y| above this (metres) is a centimetre value sent by mistake
}

local function num(x) return type(x) == "number" and x == x and x or nil end

-- Normalise the caller's list. Returns internal zones, or nil + a truthful error.
function AZ.normalize(list, now_s)
    if type(list) ~= "table" then return nil, "zones must be a list" end
    local out = {}
    for k, z in ipairs(list) do
        if type(z) ~= "table" then return nil, "zone " .. k .. " is not a table" end
        for _, f in pairs(z) do
            if type(f) == "userdata" or type(f) == "table" or type(f) == "function" then
                return nil, "zone " .. k .. ": scalars only (no tables/userdata)"
            end
        end
        local x, y, r = num(z.x), num(z.y), num(z.r_cm)
        if not (x and y and r and r > 0) then return nil, "zone " .. k .. ": needs numeric x, y (metres) and r_cm > 0" end
        if math.abs(x) > AZ.cfg.max_abs_m or math.abs(y) > AZ.cfg.max_abs_m then
            return nil, "zone " .. k .. ": x/y look like centimetres; send metres"
        end
        local kind = z.kind or "circle"
        if kind ~= "circle" and kind ~= "cone" then return nil, "zone " .. k .. ": kind must be circle or cone" end
        local untl = num(z.until_s)
        if not untl and num(z.ttl_s) then
            if not now_s then return nil, "zone " .. k .. ": ttl_s needs the game clock (no pawn)" end
            untl = now_s + z.ttl_s
        end
        if not untl then return nil, "zone " .. k .. ": needs until_s (or ttl_s)" end
        local iz = { id = tostring(z.id or ("zone" .. k)), kind = kind, X = x * 100, Y = y * 100,
            Z = num(z.z) and z.z * 100 or nil, r = r, h = num(z.h_cm) or AZ.cfg.h_cm, until_s = untl }
        if kind == "cone" then
            local yaw, half = num(z.yaw_deg), num(z.half_angle_deg)
            if not (yaw and half and half > 0 and half < 180) then return nil, "zone " .. k .. ": cone needs yaw_deg and 0 < half_angle_deg < 180" end
            iz.yaw, iz.half = math.rad(yaw), math.rad(half)
        end
        out[#out + 1] = iz
    end
    return out
end

-- Drop expired zones (in place); returns the list.
function AZ.prune(zs, now_s)
    if not (zs and now_s) then return zs end
    for k = #zs, 1, -1 do if zs[k].until_s <= now_s then table.remove(zs, k) end end
    return zs
end

local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end

-- Is the point (cm; zf = feet height or nil) inside zone z, grown by margin cm (capsule radius)?
function AZ.contains(z, x, y, zf, margin)
    margin = margin or 0
    if z.Z and zf and math.abs(zf - z.Z) > z.h then return false end
    local dx, dy = x - z.X, y - z.Y
    local d = math.sqrt(dx * dx + dy * dy)
    if d > z.r + margin then return false end
    if z.kind ~= "cone" then return true end
    if d <= margin then return true end
    local off = math.abs(wrap(math.atan(dy, dx) - z.yaw))
    if off <= z.half then return true end
    local past = off - z.half
    return past < math.pi / 2 and d * math.sin(past) <= margin
end

-- The zone containing the point (the one that lasts longest wins: that is the one to leave), or nil.
function AZ.at(zs, x, y, zf, margin)
    local best
    for _, z in ipairs(zs or {}) do
        if AZ.contains(z, x, y, zf, margin) and (not best or z.until_s > best.until_s) then best = z end
    end
    return best
end

-- Extra planner cost (cells) for standing in (x, y, zf).
function AZ.cost(zs, x, y, zf, now_s, margin)
    local c = 0
    for _, z in ipairs(zs or {}) do
        if AZ.contains(z, x, y, zf, margin) then
            local left = math.max(0, z.until_s - (now_s or 0))
            c = c + math.min(AZ.cfg.cost_max, AZ.cfg.cost_base + AZ.cfg.cost_per_s * left)
        end
    end
    return c
end

-- First zone met walking the segment a -> b (cm tables with X, Y[, Z]); returns zone, distance cm.
function AZ.on_segment(zs, a, b, zf, margin, step)
    if not (zs and #zs > 0) then return nil end
    step = step or 50
    local dx, dy = b.X - a.X, b.Y - a.Y
    local L = math.sqrt(dx * dx + dy * dy)
    local n = math.max(1, math.ceil(L / step))
    for k = 0, n do
        local f = k / n
        local z = AZ.at(zs, a.X + dx * f, a.Y + dy * f, zf, margin)
        if z then return z, L * f end
    end
    return nil
end

-- First zone on a polyline from `from` through pts[i0..] (planner points carry Z = floor height).
function AZ.on_route(zs, from, pts, i0, zf, margin)
    local prev = from
    for k = i0 or 1, #(pts or {}) do
        local z = AZ.on_segment(zs, prev, pts[k], pts[k].Z or zf, margin)
        if z then return z end
        prev = pts[k]
    end
    return nil
end

-- Escape candidates: along `rays` directions, the first point outside every zone (grown by margin)
-- and inside the bound {X, Y, r} (cm). Sorted nearest first. Each {X, Y, dist, yaw (deg)}.
function AZ.exits(zs, me, zf, opts)
    opts = opts or {}
    local margin = opts.margin or 0
    local bound = opts.bound
    local maxd = opts.max_cm or 2500
    local out = {}
    local nr = opts.rays or AZ.cfg.rays
    for k = 0, nr - 1 do
        local yaw = 2 * math.pi * k / nr
        local cx, cy = math.cos(yaw), math.sin(yaw)
        local s = 0
        while s <= maxd do
            local x, y = me.X + cx * s, me.Y + cy * s
            if bound and math.sqrt((x - bound.X) ^ 2 + (y - bound.Y) ^ 2) > bound.r then break end
            if not AZ.at(zs, x, y, zf, margin) then
                out[#out + 1] = { X = x, Y = y, dist = s, yaw = math.deg(yaw) }
                break
            end
            s = s + (opts.step or AZ.cfg.ray_step_cm)
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

return AZ
