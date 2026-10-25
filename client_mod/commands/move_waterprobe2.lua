-- Read-only: water PhysicsVolumes (bWaterVolume) the client has loaded, with bounds (a water map).
return function(log)
    if rawget(_G, "DW_PAUSE") then return { error = "paused" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local me = pc.Pawn:K2_GetActorLocation()
    local out = { n = 0, water = 0, list = {} }
    for _, v in ipairs(FindAllOf("PhysicsVolume") or {}) do
        local n = v:GetFullName()
        if not n:find("Default__") then
            out.n = out.n + 1
            local okw, w = pcall(function() return v.bWaterVolume end)
            if okw and w then
                out.water = out.water + 1
                local o, e = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 }
                pcall(function() v:GetActorBounds(false, o, e, false) end)
                if #out.list < 30 then
                    out.list[#out.list + 1] = string.format("%s d=%.0fm c=(%.0f,%.0f,%.1f) ext=(%.0f,%.0f,%.1f)", n:match("^(%S+)"),
                        math.sqrt((o.X - me.X) ^ 2 + (o.Y - me.Y) ^ 2) / 100, o.X / 100, o.Y / 100, o.Z / 100, e.X / 100, e.Y / 100, e.Z / 100)
                end
            end
        end
    end
    return out
end
