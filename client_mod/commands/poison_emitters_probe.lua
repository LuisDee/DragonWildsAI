-- Read-only probe (survival agent 2026-11-01): every status emitter component in the loaded world (Dominion
-- UTrackedStatusEmitterBox/Sphere and subclasses: PoisonEmitterBox, BurningEmitterBox on campfires, SlowEmitterBox on
-- water, BP_QuickSandVolume boxes), with its real class, owner actor, position and extent, nearest first. Two deaths on
-- 2026-11-01 were 4 HP/s "PoisonEmitterBox" poison (12:45 [566,1884,-47], 13:26 [445,1813,-30]); none was loaded later
-- at either site, so it was transient (near enemy camps). Property reads only.
return function(log)
    local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
    local pc = FindFirstOf("PlayerController")
    local p = pc and pc.Pawn
    local me = p and p:IsValid() and try(function() return p:K2_GetActorLocation() end)
    local out = { rows = {} }
    for _, cls in ipairs({ "TrackedStatusEmitterBox", "TrackedStatusEmitterSphere" }) do
        local all = FindAllOf(cls) or {}
        for _, c in ipairs(all) do
            if c:IsValid() and not tostring(c:GetFullName()):find("Default__", 1, true) then
                local owner = try(function() return c:GetOwner() end)
                local loc = try(function() return c:K2_GetComponentLocation() end)
                local row = { class = try(function() return c:GetClass():GetFName():ToString() end) or cls, name = try(function() return c:GetFName():ToString() end),
                              owner = owner and owner:IsValid() and try(function() return owner:GetFName():ToString() end) or nil,
                              owner_class = owner and owner:IsValid() and try(function() return owner:GetClass():GetFName():ToString() end) or nil }
                if loc then
                    row.pos_m = { math.floor(loc.X) / 100, math.floor(loc.Y) / 100, math.floor(loc.Z) / 100 }
                    if me then
                        local dx, dy, dz = loc.X - me.X, loc.Y - me.Y, loc.Z - me.Z
                        row.dist_m = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) / 10) / 10
                    end
                end
                local ext = try(function() return c.BoxExtent end)
                if ext then row.extent_m = { math.floor(ext.X) / 100, math.floor(ext.Y) / 100, math.floor(ext.Z) / 100 } end
                local r = try(function() return c.SphereRadius end)
                if type(r) == "number" then row.radius_m = math.floor(r) / 100 end
                out.rows[#out.rows + 1] = row
            end
        end
    end
    table.sort(out.rows, function(a, b) return (a.dist_m or 1e9) < (b.dist_m or 1e9) end)
    out.n = #out.rows
    while #out.rows > 40 do table.remove(out.rows) end
    if me then out.me_m = { math.floor(me.X) / 100, math.floor(me.Y) / 100, math.floor(me.Z) / 100 } end
    return out
end
