-- Reach: where to stand and which way to face so a melee attack's damage shape covers a target.
-- Generic for every weapon and tool (axes, pickaxes, swords): the game's own hitbox data, no tables.
--
-- Data (verified live 2026-10-25 by the coordinator, experiments/hitbox_probe, DISCOVERIES "Melee
-- hitboxes"): UPlayerAttackData CDO .TimedDamageShapes = {TimeOffset, DamageShape}; the shape is a
-- UDominionShape_{Wedge,Arc,Box,Capsule,Sphere} relative to the attacker with Offset (FVector) and
-- shape fields. Axe Chop (BP_Player_Axe_Woodcut1): Wedge Depth 115, TopAngle 80, AngleOffset +35,
-- t 0.55 s. Overhead Chop (Woodcut2): Wedge Depth 170, TopAngle 15, AngleOffset 0, Offset Z -40,
-- t 0.84 s. The puppet has no camera, so the melee component's screen-space aim assist never helps.
--
-- UNVERIFIED: the sign convention of AngleOffset (UE yaw: + is clockwise seen from above). M.solve
-- uses M.sign(key) (default +1); a caller that sees a whiff with the target inside the distance
-- window calls M.flip(key) once, so the sign is learned from the game (kept per shape).
local U = require("body.util")

local M = {}

M.DEFAULT = { kind = "default", min_cm = 0, max_cm = 150, angle_offset = 0, half_angle = 25 }

local cache = {}
local G = rawget(_G, "__dw_reach_sign") or {}
rawset(_G, "__dw_reach_sign", G)

local function num(o, k) local v = U.try(function() return o[k] end); return type(v) == "number" and v or nil end

-- Pure: a shape description {kind, Depth, MinDepth, TopAngle, AngleOffset, Radius, ArcCircleRadius,
-- Extents={X,Y,Z}, Offset={X,Y,Z}} -> {min_cm, max_cm, angle_offset, half_angle, kind}.
function M.window_of(sh)
    if not sh then return M.DEFAULT end
    local off = sh.Offset or {}
    local fwd = tonumber(off.X) or 0
    local k = (sh.kind or ""):lower()
    if k:find("wedge") then
        return { kind = "wedge", min_cm = (sh.MinDepth or 0) + fwd, max_cm = (sh.Depth or 150) + fwd,
                 angle_offset = sh.AngleOffset or 0, half_angle = (sh.TopAngle or 50) / 2 }
    elseif k:find("sphere") then
        return { kind = "sphere", min_cm = 0, max_cm = (sh.Radius or 100) + math.max(0, fwd), angle_offset = 0, half_angle = 60 }
    elseif k:find("capsule") then
        return { kind = "capsule", min_cm = 0, max_cm = (sh.Radius or 60) + math.max(0, fwd), angle_offset = 0, half_angle = 40 }
    elseif k:find("box") then
        local ex = sh.Extents or {}
        return { kind = "box", min_cm = 0, max_cm = fwd + (tonumber(ex.X) or 80), angle_offset = 0, half_angle = 35 }
    elseif k:find("arc") then
        return { kind = "arc", min_cm = 0, max_cm = (sh.ArcCircleRadius or 150) + fwd, angle_offset = 0, half_angle = 80 }
    end
    return M.DEFAULT
end

-- Read the first timed damage shape of an attack class (UClass of a UPlayerAttackData). Cached.
-- Returns window (M.window_of), key (for M.sign/M.flip), t_s (TimeOffset) or the default window.
function M.shape_of(attack_class)
    local key = U.fullname(attack_class) or tostring(attack_class)
    if cache[key] then return cache[key].win, key, cache[key].t end
    local cdo = U.try(function() return attack_class:GetCDO() end)
    local sh, t
    if cdo then
        pcall(function()
            cdo.TimedDamageShapes:ForEach(function(_, elem)
                if sh then return true end
                local e = U.try(function() return elem:get() end) or elem
                local s = U.try(function() return e.DamageShape end)
                if U.valid(s) then
                    t = num(e, "TimeOffset")
                    local off = U.try(function() return s.Offset end)
                    local ex = U.try(function() return s.Extents end)
                    sh = { kind = U.class_word(s) or ((U.fullname(U.try(function() return s:GetClass() end)) or ""):match("([%w_]+)$")),
                           Depth = num(s, "Depth"), MinDepth = num(s, "MinDepth"), TopAngle = num(s, "TopAngle"),
                           AngleOffset = num(s, "AngleOffset"), Radius = num(s, "Radius"), ArcCircleRadius = num(s, "ArcCircleRadius"),
                           Offset = off and { X = num(off, "X"), Y = num(off, "Y"), Z = num(off, "Z") } or nil,
                           Extents = ex and { X = num(ex, "X"), Y = num(ex, "Y"), Z = num(ex, "Z") } or nil }
                end
            end)
        end)
    end
    local win = M.window_of(sh)
    cache[key] = { win = win, t = t }
    return win, key, t
end

function M.sign(key) return G[key] or 1 end
function M.flip(key) G[key] = -M.sign(key); return G[key] end

-- Pure: given the attacker at `here`, the target point `at` (a log's nearest axis point, a trunk),
-- the target's radius and a window, return {yaw (deg, the facing to use), dist, in_range, stand
-- (a point to walk to when out of range, on the line target->here at the window's sweet spot)}.
function M.solve(here, at, target_radius, win, sign, margin)
    win = win or M.DEFAULT
    margin = margin or 15
    local dx, dy = here.X - at.X, here.Y - at.Y
    local dist = math.sqrt(dx * dx + dy * dy)
    local bearing = math.deg(math.atan(at.Y - here.Y, at.X - here.X))
    local yaw = bearing - (sign or 1) * (win.angle_offset or 0)
    local r = target_radius or 0
    local lo = math.max(0, (win.min_cm or 0) - r)
    local hi = math.max(lo + 20, (win.max_cm or 150) + r - margin)
    local sweet = math.max(lo + 10, hi - 30)
    local in_range = dist >= lo and dist <= hi
    local stand = nil
    if not in_range then
        local ux, uy = 1, 0
        if dist > 1 then ux, uy = dx / dist, dy / dist end
        stand = { X = at.X + ux * sweet, Y = at.Y + uy * sweet, Z = here.Z }
    end
    return { yaw = yaw, bearing = bearing, dist = dist, lo = lo, hi = hi, in_range = in_range, stand = stand }
end

function M._reset() cache = {}; for k in pairs(G) do G[k] = nil end end

return M
