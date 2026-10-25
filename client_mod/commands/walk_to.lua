-- Walk to another player with real movement input: each 50 ms face the target (control rotation) and
-- AddMovementInput toward it, like holding W. Straight line (no pathing yet). Stops within 300 cm or
-- after 30 s. Writes progress to the client log. Target: first other player's pawn.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local me = pc and pc.Pawn
    if not (me and me:IsValid()) then return { ok = false, error = "no pawn" } end
    local target
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if p:IsValid() and p ~= me and not p:GetFullName():find("Default__") then target = p end
    end
    if not target then return { ok = false, error = "no other player visible to this client" } end
    if _G.DW_WALK then pcall(CancelDelayedAction, _G.DW_WALK) end
    local t0 = os.clock()
    local function dist()
        local a, b = me:K2_GetActorLocation(), target:K2_GetActorLocation()
        return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2), a, b
    end
    local d0 = dist()
    local ticks = 0
    _G.DW_WALK = LoopInGameThreadWithDelay(1, function()
        ticks = ticks + 1
        local ok, err = pcall(function()
            if not (me:IsValid() and target:IsValid()) then error("lost pawn") end
            local d, a, b = dist()
            if d < 300 or os.clock() - t0 > 30 then
                log(string.format("walk_to done d=%.0f ticks=%d", d, ticks))
                CancelDelayedAction(_G.DW_WALK); _G.DW_WALK = nil; return
            end
            local dx, dy = b.X - a.X, b.Y - a.Y
            local yaw = math.deg(math.atan(dy, dx))
            pc:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 })
            me:AddMovementInput({ X = dx / d, Y = dy / d, Z = 0 }, 1.0, false)
            if ticks % 400 == 0 then log(string.format("walk_to d=%.0f", d)) end
        end)
        if not ok then log("walk_to error " .. tostring(err)); CancelDelayedAction(_G.DW_WALK); _G.DW_WALK = nil end
    end)
    return { ok = true, target = target:GetFullName():match("([%w_]+)$"), start_dist_m = math.floor(d0 / 100) }
end
