-- LIVE (spells agent): jump, then about 0.3 s later press evade once (the pawn's own EvadeAction, which is
-- what the dodge key injects) while airborne, and sample the position for 1.5 s. Results go to
-- client_io/out/air_dash_async.json: horizontal displacement, apex, and whether the evade started.
-- It measures what Phase Dash ("a second dash in mid-air") adds. Refuses while the arbiter has an owner.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local J = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local A = rawget(_G, "DWArbiter")
    if A and A.owner then return { ok = false, reason = "arbiter busy: " .. tostring(A.owner.name) } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and pc.Pawn
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local ev = U.try(function() return pawn.PlayerInputBufferInputActions.EvadeAction end)
    local p0 = U.loc(pawn)
    local res = { start = { p0.X / 100, p0.Y / 100, p0.Z / 100 }, max_dz_m = 0, max_h_m = 0, evade_action = U.short(ev), tags = {} }
    pawn:Jump()
    local frame, h = 0, nil
    h = LoopInGameThreadWithDelay(1, function()
        frame = frame + 1
        if rawget(_G, "DW_PAUSE") == true or not U.valid(pawn) then CancelDelayedAction(h); return true end
        local p = U.loc(pawn)
        local dh = math.sqrt((p.X - p0.X) ^ 2 + (p.Y - p0.Y) ^ 2) / 100
        if dh > res.max_h_m then res.max_h_m = dh end
        if (p.Z - p0.Z) / 100 > res.max_dz_m then res.max_dz_m = (p.Z - p0.Z) / 100 end
        if frame == 6 then pawn:StopJumping() end
        if frame == 9 then
            res.falling_at_press = U.try(function() return pawn.CharacterMovement:IsFalling() end)
            res.evade_injected = pcall(function() eis:InjectInputVectorForAction(ev, { X = 1, Y = 0, Z = 0 }, {}, {}) end)
        end
        if frame == 14 then
            local ge = U.try(function() return pawn.GameplayEffectsComponent end)
            pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) res.tags[#res.tags + 1] = U.str(t:get().TagName) end) end)
        end
        if frame >= 45 then
            res.end_pos = { p.X / 100, p.Y / 100, p.Z / 100 }
            local f = io.open("C:/gameserver/client_io/out/air_dash_async.json", "wb")
            if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h)
            return true
        end
    end)
    return { ok = true, started = true }
end
