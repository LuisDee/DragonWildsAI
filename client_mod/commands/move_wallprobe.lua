-- Read-only: what blocks the local planner's knee-height horizontal wall checks around Claude?
-- 8 rays of 1.4 m at feet+50 cm (exactly like localplan verify), on the Visibility channel and per
-- object type (LineTraceSingleForObjects: 0 WorldStatic, 1 WorldDynamic, 2 Pawn, 3 PhysicsBody,
-- 4 Vehicle, 5 Destructible). Reports hit distance and normal. Does not move the pawn.
return function(log)
    if rawget(_G, "DW_PAUSE") then return { error = "paused" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local me = pawn:K2_GetActorLocation()
    local hh = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local z = me.Z - hh + 50
    local out = { me = { me.X, me.Y, me.Z }, rays = {} }
    for k = 0, 7 do
        local a = math.rad(k * 45)
        local s = { X = me.X + math.cos(a) * 60, Y = me.Y + math.sin(a) * 60, Z = z }   -- start outside our capsule
        local e = { X = me.X + math.cos(a) * 200, Y = me.Y + math.sin(a) * 200, Z = z }
        local o = {}
        local hit = ksl:LineTraceSingle(pawn, s, e, 0, false, {}, 0, o, true, c0, c0, 0.0)
        local r = { dir = k * 45, vis = hit and string.format("%.0fcm nz=%.2f", o.Distance or -1, o.ImpactNormal and o.ImpactNormal.Z or -9) or "-" }
        for ot = 0, 5 do
            local o2 = {}
            local ok, h2 = pcall(function() return ksl:LineTraceSingleForObjects(pawn, s, e, { ot }, false, {}, 0, o2, true, c0, c0, 0.0) end)
            if ok and h2 then r["obj" .. ot] = string.format("%.0fcm", o2.Distance or -1) elseif not ok then r["obj" .. ot] = "err" end
        end
        -- complex collision too
        local o3 = {}
        r.vis_complex = ksl:LineTraceSingle(pawn, s, e, 0, true, {}, 0, o3, true, c0, c0, 0.0) and string.format("%.0fcm", o3.Distance or -1) or "-"
        out.rays[#out.rays + 1] = r
    end
    return out
end
