-- Smoke test: one jump through the character's own Jump()/StopJumping() (what the jump input calls).
-- Samples the height every 50 ms for 1 s into _G.DW_SMOKE_JUMP; read it with smoke_jump_read.lua.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__", 1, true) then pc = x end end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local z0 = pawn:K2_GetActorLocation().Z
    local res = { z0_cm = z0, max_dz_cm = 0, samples = 0, done = false }
    _G.DW_SMOKE_JUMP = res
    pawn:Jump()
    for i = 1, 20 do
        ExecuteWithDelay(i * 50, function()
            ExecuteInGameThread(function()
                if not pawn:IsValid() then return end
                local dz = pawn:K2_GetActorLocation().Z - z0
                res.samples = res.samples + 1
                if dz > res.max_dz_cm then res.max_dz_cm = dz end
                if i == 6 then pawn:StopJumping() end
                if i == 20 then res.done = true end
            end)
        end)
    end
    return { ok = true, z0_cm = z0 }
end
