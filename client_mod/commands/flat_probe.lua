-- READ-ONLY flat-ground finder for a placed spell (Summon Shelter): candidate points ~5 m around
-- Claude in 12 directions, skipping any within 6 m of another player. Per candidate it makes 9 downward
-- Visibility traces (3x3, 1.5 m apart) for the height spread and the centre normal, a clearance trace
-- (0.5 m -> 3.5 m up) and a line-of-sight trace from Claude's chest. Same trace call as move.lua
-- (KismetSystemLibrary:LineTraceSingle, out table filled by UE4SS). About 130 traces, no input.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local function trace(a, b)
        local out = {}
        local ok, hit = pcall(function() return KSL:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, C0, C0, 0.0) end)
        if not ok then return nil, nil, "err" end
        return hit == true, out
    end
    local me = U.loc(pawn)
    local others = {}
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        if U.short(p) ~= U.short(pawn) then others[#others + 1] = { name = U.player_name(p), pos = U.loc(p) } end
    end
    local function ground(x, y)
        local hit, out = trace({ X = x, Y = y, Z = me.Z + 400 }, { X = x, Y = y, Z = me.Z - 600 })
        if not hit then return nil end
        return out.ImpactPoint.Z, out.ImpactNormal and out.ImpactNormal.Z, tonumber(out.Distance) or 0
    end
    local cands = {}
    for _, r in ipairs({ 500 }) do
        for i = 0, 11 do
            local ang = math.rad(i * 30)
            local cx, cy = me.X + r * math.cos(ang), me.Y + r * math.sin(ang)
            local near
            for _, o in ipairs(others) do
                local d = math.sqrt((o.pos.X - cx) ^ 2 + (o.pos.Y - cy) ^ 2) / 100
                if d < 6 then near = o.name .. " " .. math.floor(d * 10) / 10 .. " m" end
            end
            local c = { dir_deg = i * 30, point_m = { math.floor(cx) / 100, math.floor(cy) / 100 } }
            if near then
                c.skip = "player " .. near
            else
                local zs, zc, nz = {}, nil, nil
                for dx = -1, 1 do for dy = -1, 1 do
                    local z, n, dist = ground(cx + dx * 150, cy + dy * 150)
                    if z then zs[#zs + 1] = z end
                    if dx == 0 and dy == 0 then zc, nz = z, n; c.start_inside = dist == 0 or nil end
                end end
                if zc and #zs == 9 then
                    local lo, hi = math.huge, -math.huge
                    for _, z in ipairs(zs) do lo = math.min(lo, z); hi = math.max(hi, z) end
                    c.spread_m = math.floor(hi - lo) / 100
                    c.normal_z = nz and math.floor(nz * 1000) / 1000
                    c.z_m = math.floor(zc) / 100
                    c.point_m[3] = c.z_m
                    local up = trace({ X = cx, Y = cy, Z = zc + 50 }, { X = cx, Y = cy, Z = zc + 350 })
                    c.overhead_blocked = up == true
                    local los = trace({ X = me.X, Y = me.Y, Z = me.Z + 50 }, { X = cx, Y = cy, Z = zc + 80 })
                    c.los_blocked = los == true
                else
                    c.skip = "no ground (" .. #zs .. "/9)"
                end
            end
            cands[#cands + 1] = c
        end
    end
    local best
    for _, c in ipairs(cands) do
        if not c.skip and not c.overhead_blocked and not c.los_blocked and (c.normal_z or 0) > 0.96 then
            if not best or c.spread_m < best.spread_m then best = c end
        end
    end
    return { ok = true, me_m = { me.X / 100, me.Y / 100, me.Z / 100 }, others = #others, best = best, candidates = cands }
end
