-- Read-only: Claude's capsule collision profile, and knee-height ring traces on Visibility vs the
-- pawn's own profile (what really blocks him). Starts 60 cm out (his gear blocks traces).
return function(log)
    if rawget(_G, "DW_PAUSE") then return { error = "paused" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local cap = pawn.CapsuleComponent
    local out = {}
    local okp, prof = pcall(function() return cap:GetCollisionProfileName():ToString() end)
    out.profile = okp and prof or tostring(prof)
    local me = pawn:K2_GetActorLocation()
    out.me = { me.X, me.Y, me.Z }
    local hh = cap:GetScaledCapsuleHalfHeight()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local z = me.Z - hh + 50
    local pname = FName(okp and prof or "Pawn")
    out.rays = {}
    for k = 0, 7 do
        local a = math.rad(k * 45)
        local s = { X = me.X + math.cos(a) * 70, Y = me.Y + math.sin(a) * 70, Z = z }
        local e = { X = me.X + math.cos(a) * 300, Y = me.Y + math.sin(a) * 300, Z = z }
        local o1, o2 = {}, {}
        local h1 = ksl:LineTraceSingle(pawn, s, e, 0, false, {}, 0, o1, true, c0, c0, 0.0)
        local ok2, h2 = pcall(function() return ksl:LineTraceSingleByProfile(pawn, s, e, pname, false, {}, 0, o2, true, c0, c0, 0.0) end)
        out.rays[#out.rays + 1] = string.format("%d: vis=%s prof=%s", k * 45,
            h1 and string.format("%.0f", o1.Distance or -1) or "-",
            ok2 and (h2 and string.format("%.0f", o2.Distance or -1) or "-") or ("err " .. tostring(h2)))
    end
    return out
end
