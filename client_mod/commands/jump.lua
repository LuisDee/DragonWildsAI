-- Gate 2: jump through the local character's own Jump()/StopJumping() (what the jump input calls),
-- 3 times, 1.2 s apart. Movement replicates to the server like any player's.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local z0 = pawn:K2_GetActorLocation().Z
    for i = 0, 2 do
        ExecuteWithDelay(i * 1200, function()
            ExecuteInGameThread(function()
                pawn:Jump()
                ExecuteWithDelay(300, function() ExecuteInGameThread(function() pawn:StopJumping() end) end)
            end)
        end)
    end
    return { ok = true, z0 = z0, locally_controlled = tostring(pawn:IsLocallyControlled()) }
end
