-- Read-only: one downward + one forward LineTraceSingle at Claude's position (local planner canary
-- on the real client), plus the jump envelope from the engine's own numbers. Does not move the pawn.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local me = pawn:K2_GetActorLocation()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local out = {}
    local t0 = os.clock()
    local hit = ksl:LineTraceSingle(pawn, { X = me.X, Y = me.Y, Z = me.Z + 100 }, { X = me.X, Y = me.Y, Z = me.Z - 900 }, 0, false, {}, 0, out, true, c0, c0, 0.0)
    local res = { down_hit = hit, floor_z = out.ImpactPoint and out.ImpactPoint.Z, pen = out.bStartPenetrating,
                  me_z = me.Z, ms = math.floor((os.clock() - t0) * 100000) / 100 }
    local yaw = pawn:K2_GetActorRotation().Yaw
    local fx, fy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local o2 = {}
    res.fwd_hit = ksl:LineTraceSingle(pawn, { X = me.X, Y = me.Y, Z = me.Z - 40 }, { X = me.X + fx * 300, Y = me.Y + fy * 300, Z = me.Z - 40 }, 0, false, {}, 0, o2, true, c0, c0, 0.0)
    res.fwd_nz = o2.ImpactNormal and o2.ImpactNormal.Z
    res.fwd_dist = o2.Distance
    local mc = pawn.CharacterMovement
    local function num(f) local ok, x = pcall(f); return ok and x or tostring(x) end
    res.env = {
        MaxStepHeight = num(function() return mc.MaxStepHeight end),
        JumpZVelocity = num(function() return mc.JumpZVelocity end),
        GravityScale = num(function() return mc.GravityScale end),
        GravityZ = num(function() return mc:GetGravityZ() end),
        MaxJumpHeight = num(function() return mc:GetMaxJumpHeight() end),
        MaxJumpHeightWithJumpTime = num(function() return mc:GetMaxJumpHeightWithJumpTime() end),
        WalkableFloorAngle = num(function() return mc.WalkableFloorAngle end),
        MinFallDamageHeight = num(function() return mc.MinFallDamageHeight end),
        MaxFallDamageHeight = num(function() return mc.MaxFallDamageHeight end),
        JumpMaxHoldTime = num(function() return pawn.JumpMaxHoldTime end),
        HalfHeight = num(function() return pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end),
        DoubleJumpPerk = num(function() return pc.SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk) end),
    }
    return res
end
