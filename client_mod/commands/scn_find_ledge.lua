-- Scenario suite (tools/scenario_run.py, "ledge_jump"): find a ledge Claude can JUMP onto near him. READ-ONLY:
-- traces only, no movement, no input. A ledge = along one heading, flat ground at his feet level, then
-- within 0.5 m the floor rises by RISE_MIN..RISE_MAX (a step, too high to walk: MaxStepHeight is 45 cm,
-- jump apex 180 cm), then at least 1 m of flat landing with 2 m headroom.
-- Runner args (prefixed by the runner as `local ARGS = {...}`): radius_m (6), headings (16), rise_min_m (0.6),
-- rise_max_m (1.4). Returns {ok, candidates = [{base, edge, top, rise_m, heading_deg, dist_m}], traces, feet}.
-- Traces use the capsule's own profile like move.lua (fallback Visibility); ~1 ms each.
return function(log)
    local A = (type(ARGS) == "table" and ARGS) or {}
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, error = "paused" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if not x:GetFullName():find("Default__", 1, true) then
            local okp, p = pcall(function() return x.Pawn end)
            if okp and p and p:IsValid() then pc = x end
        end
    end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local prof
    pcall(function() prof = FName(pawn.CapsuleComponent:GetCollisionProfileName():ToString()) end)
    local n = 0
    local function trace(a, b)
        n = n + 1
        local out = {}
        local ok, hit = false, false
        if prof then ok, hit = pcall(function() return KSL:LineTraceSingleByProfile(pawn, a, b, prof, false, {}, 0, out, true, C0, C0, 0.0) end) end
        if not ok then out = {}; hit = KSL:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0) end
        if hit ~= true then return nil end
        return out.ImpactPoint and out.ImpactPoint.Z, out
    end
    local l = pawn:K2_GetActorLocation()
    local half = 88
    pcall(function() half = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    local feet = l.Z - half
    local function floor_at(x, y)
        return (trace({ X = x, Y = y, Z = feet + 300 }, { X = x, Y = y, Z = feet - 250 }))
    end
    local radius = (tonumber(A.radius_m) or 6) * 100
    local heads = tonumber(A.headings) or 16
    local rmin, rmax = (tonumber(A.rise_min_m) or 0.6) * 100, (tonumber(A.rise_max_m) or 1.4) * 100
    local step = 50
    local cands = {}
    for h = 0, heads - 1 do
        local yaw = h * 2 * math.pi / heads
        local dx, dy = math.cos(yaw), math.sin(yaw)
        local prev = feet
        local flat = true
        for d = step, radius, step do
            local x, y = l.X + dx * d, l.Y + dy * d
            local z = floor_at(x, y)
            if not z then break end                         -- hole / void: give up on this heading
            local rise = z - prev
            if rise > rmin and rise < rmax and flat then
                -- landing: 1 m of flat floor past the edge, and headroom above it
                local z2 = floor_at(x + dx * 50, y + dy * 50)
                local z3 = floor_at(x + dx * 100, y + dy * 100)
                local roof = trace({ X = x + dx * 75, Y = y + dy * 75, Z = z + 20 }, { X = x + dx * 75, Y = y + dy * 75, Z = z + 220 })
                if z2 and z3 and math.abs(z2 - z) < 25 and math.abs(z3 - z) < 25 and not roof then
                    local bd = math.max(0, d - 150)
                    cands[#cands + 1] = {
                        heading_deg = math.floor(math.deg(yaw) + 0.5), dist_m = d / 100, rise_m = math.floor(rise) / 100,
                        base = { (l.X + dx * bd) / 100, (l.Y + dy * bd) / 100, prev / 100 },
                        edge = { x / 100, y / 100, z / 100 },
                        top = { (x + dx * 75) / 100, (y + dy * 75) / 100, z / 100 },
                    }
                end
                break
            end
            if math.abs(rise) > 30 then flat = false end      -- uneven approach: not a clean ledge
            prev = z
        end
    end
    -- best first: a rise near 1 m (clearly a jump, safely under the apex), then the nearest
    table.sort(cands, function(a, b)
        local sa, sb = math.abs(a.rise_m - 1.0), math.abs(b.rise_m - 1.0)
        if math.abs(sa - sb) > 0.15 then return sa < sb end
        return a.dist_m < b.dist_m
    end)
    return { ok = true, candidates = cands, traces = n, feet = { l.X / 100, l.Y / 100, feet / 100 } }
end
