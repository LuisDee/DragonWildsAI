-- Read-only: Claude's carry weight and encumbered flag (UPlayerEncumbranceComponent getters), plus movement speeds.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") then pc = x; break end
    end
    local p = pc and pc.Pawn
    if not (p and p:IsValid()) then return { error = "no pawn" } end
    local out = {}
    local ok, ec = pcall(function() return p.PlayerEncumbranceComponent end)
    out.has_component = ok and ec and ec:IsValid() or false
    if out.has_component then
        for _, fn in ipairs({ "IsEncumbered", "GetCurrentCarryWeight", "GetMaxCarryWeight" }) do
            local okf, v = pcall(function() return ec[fn](ec) end)
            out[fn] = okf and v or ("err " .. tostring(v))
        end
        local okc, cw = pcall(function() return ec.CurrentCarryWeight end)
        out.CurrentCarryWeight = okc and cw or nil
    end
    local okm, cm = pcall(function() return p.CharacterMovement end)
    if okm and cm then
        for _, k in ipairs({ "MaxWalkSpeed", "MaxWalkSpeedCrouched", "JumpZVelocity" }) do
            local okk, v = pcall(function() return cm[k] end)
            out[k] = okk and v or nil
        end
        local okv, vel = pcall(function() return cm.Velocity end)
        if okv and vel then out.speed = math.sqrt(vel.X ^ 2 + vel.Y ^ 2) end
    end
    return out
end
