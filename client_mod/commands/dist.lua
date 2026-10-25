return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local me = pc.Pawn; local out = {}
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if p:IsValid() and p ~= me and not p:GetFullName():find("Default__") then
            local a, b = me:K2_GetActorLocation(), p:K2_GetActorLocation()
            out[#out + 1] = math.floor(math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2))
        end
    end
    local v = me:GetVelocity()
    return { dist_cm = out, speed = math.floor(math.sqrt(v.X ^ 2 + v.Y ^ 2)) }
end
