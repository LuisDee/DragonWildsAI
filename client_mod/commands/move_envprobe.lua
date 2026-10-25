-- Read-only: Claude's water depth (EnvironmentComponent) and movement mode.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local out = { mode = pawn.CharacterMovement.MovementMode }
    local ok, comp = pcall(function() return pawn.EnvironmentComponent end)
    out.prop = ok and comp and comp:IsValid() and comp:GetFullName() or tostring(comp)
    if not (ok and comp and comp:IsValid()) then
        for _, c in ipairs(FindAllOf("EnvironmentComponent") or {}) do
            local okp, o = pcall(function() return c:GetOwner() end)
            if okp and o == pawn then comp = c; out.found = c:GetFullName() end
        end
    end
    if comp and comp:IsValid() then
        local okd, d = pcall(function() return comp:GetNormalizedWaterDepth() end)
        out.depth = okd and d or tostring(d)
    end
    return out
end
