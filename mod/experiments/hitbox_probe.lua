-- Read-only: dump an attack's damage hitboxes (UPlayerAttackData.TimedDamageShapes) so the bot can
-- position itself so the target lies inside the shape (the puppet has no camera, so no aim assist).
-- debug_run {module="hitbox_probe", args={attacks={<attack class path>, ...}}}
local U = require("body.util")
local M = {}

local FIELDS = { "ArcCircleRadius", "SegmentWidth", "SegmentHeight", "SegmentDepth", "SegmentCount",
                 "Radius", "HalfHeight", "TopAngle", "ZHeight", "MinDepth", "Depth", "AngleOffset" }

local function vec(v) return v and { X = U.try(function() return v.X end), Y = U.try(function() return v.Y end), Z = U.try(function() return v.Z end) } end
local function rot(r) return r and { P = U.try(function() return r.Pitch end), Y = U.try(function() return r.Yaw end), R = U.try(function() return r.Roll end) } end

local function shape_info(s)
    if not U.valid(s) then return nil end
    local out = { class = (U.fullname(U.try(function() return s:GetClass() end)) or ""):match("([%w_]+)$"),
                  offset = vec(U.try(function() return s.Offset end)), pivot = vec(U.try(function() return s.Pivot end)),
                  scale = U.try(function() return s.Scale end), rotation = rot(U.try(function() return s.RotationOffset end)),
                  extents = vec(U.try(function() return s.Extents end)) }
    for _, f in ipairs(FIELDS) do
        local v = U.try(function() return s[f] end)
        if type(v) == "number" then out[f] = v end
    end
    return out
end

function M.run(log, args)
    local res = {}
    for _, path in ipairs(args.attacks or {}) do
        local cls = U.try(StaticFindObject, path)
        local cdo = U.valid(cls) and U.try(function() return cls:GetCDO() end)
        local entry = { found = U.valid(cdo), shapes = {} }
        if U.valid(cdo) then
            entry.damage = U.try(function() return cdo.DamageAmount end)
            entry.single_target = U.try(function() return cdo.bDamageSingleTarget end)
            pcall(function()
                cdo.TimedDamageShapes:ForEach(function(_, elem)
                    local e = elem:get()
                    entry.shapes[#entry.shapes + 1] = { t = U.try(function() return e.TimeOffset end),
                                                        shape = shape_info(U.try(function() return e.DamageShape end)) }
                end)
            end)
        end
        res[(path:match("([%w_]+)$")) or path] = entry
    end
    local mc = (select(2, U.split_pawns()))[1]
    mc = mc and U.try(function() return mc.PlayerMeleeAttackComponent end)
    if U.valid(mc) then
        res._melee_component = { aim_assist_max_angle = U.try(function() return mc.MaximumAngleAimAssist end),
                                 screen_space_radius = U.try(function() return mc.ScreenSpaceRadius end) }
    end
    return res
end

return M
