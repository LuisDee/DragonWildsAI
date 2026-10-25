-- Read-only: how can Claude see water ahead? Lists water-body actors the client has (class, bounds)
-- and, on a ring of points around Claude, compares downward traces: Visibility vs the pawn profile vs
-- WorldStatic/WorldDynamic object types (a water surface may block one but not another). Also reads
-- Claude's MovementMode (4 = swimming).
return function(log)
    if rawget(_G, "DW_PAUSE") then return { error = "paused" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local me = pawn:K2_GetActorLocation()
    local out = { me = { math.floor(me.X), math.floor(me.Y), math.floor(me.Z) }, bodies = {} }
    out.movement_mode = pawn.CharacterMovement.MovementMode
    for _, cls in ipairs({ "WaterBody", "WaterBodyLake", "WaterBodyRiver", "WaterBodyOcean", "WaterBodyCustom", "WaterZone" }) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            local n = a:GetFullName()
            if not n:find("Default__") and #out.bodies < 25 then
                local o, e = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }
                pcall(function() a:GetActorBounds(false, o, e, false) end)
                local d = math.sqrt((o.X - me.X) ^ 2 + (o.Y - me.Y) ^ 2) / 100
                out.bodies[#out.bodies + 1] = string.format("%s d=%.0fm c=(%.0f,%.0f,%.0f) ext=(%.0f,%.0f,%.0f)", n:match("^(%S+)") .. " " .. n:match("([%w_]+)$"),
                    d, o.X / 100, o.Y / 100, o.Z / 100, e.X / 100, e.Y / 100, e.Z / 100)
            end
        end
    end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local prof = FName("Player")
    out.ring = {}
    for k = 0, 7 do
        local a = math.rad(k * 45)
        for _, r in ipairs({ 400, 1200 }) do
            local x, y = me.X + math.cos(a) * r, me.Y + math.sin(a) * r
            local s, e = { X = x, Y = y, Z = me.Z + 800 }, { X = x, Y = y, Z = me.Z - 1500 }
            local o1, o2, o3, o4 = {}, {}, {}, {}
            local h1 = ksl:LineTraceSingle(pawn, s, e, 0, false, {}, 0, o1, true, c0, c0, 0.0)
            local okp, h2 = pcall(function() return ksl:LineTraceSingleByProfile(pawn, s, e, prof, false, {}, 0, o2, true, c0, c0, 0.0) end)
            local ok3, h3 = pcall(function() return ksl:LineTraceSingleForObjects(pawn, s, e, { 0 }, false, {}, 0, o3, true, c0, c0, 0.0) end)
            local ok4, h4 = pcall(function() return ksl:LineTraceSingleForObjects(pawn, s, e, { 1 }, false, {}, 0, o4, true, c0, c0, 0.0) end)
            local function z(h, o) return h and o.ImpactPoint and string.format("%.1f", o.ImpactPoint.Z / 100) or "-" end
            out.ring[#out.ring + 1] = string.format("%3d@%2dm vis=%s prof=%s static=%s dyn=%s", k * 45, r / 100, z(h1, o1), okp and z(h2, o2) or "err", ok3 and z(h3, o3) or "err", ok4 and z(h4, o4) or "err")
        end
    end
    return out
end
