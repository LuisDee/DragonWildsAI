-- READ-ONLY sleep/rest probe (R2.20 phase C prep): IMC_Resting key mappings, the PC's RestingInputMode,
-- Claude's PlayerRestComponent state, in-game time / night, and beds or resting areas nearby (owner,
-- interaction prompt, distance). Nothing injected, no state-changing call.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local out = { ok = true }
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local c = U.find_object("/Game/Gameplay/Inputs/Mappings/IMC_Resting.IMC_Resting")
    out.imc_resting = {}
    if c then
        pcall(function() c.Mappings:ForEach(function(_, m)
            local e = m:get()
            local r = { a = nm(U.try(function() return e.Action end)), key = U.str(U.try(function() return e.Key.KeyName end)), trig = {} }
            pcall(function() e.Action.Triggers:ForEach(function(_, t) r.trig[#r.trig + 1] = U.class_word(t:get()) end) end)
            out.imc_resting[#out.imc_resting + 1] = r
        end) end)
    else out.imc_resting = "not loaded" end
    local rm = U.try(function() return pc.RestingInputMode end)
    out.resting_mode = nm(rm)
    out.current_mode = nm(U.try(function() return pc.CurrentInputMode end))
    local rc = U.try(function() return pawn.PlayerRestComponent end)
    if not U.valid(rc) then rc = U.try(function() return pawn.BP_Components_Sleep end) end
    if U.valid(rc) then
        out.rest = { comp = nm(rc), sleeping = U.try(function() return rc.IsSleeping end),
                     resting = U.try(function() return rc:IsResting() end),
                     waiting = U.try(function() return rc:IsWaitingForSleep() end),
                     timeframe = U.try(function() return rc:IsInTimeframeForSleep() end),
                     area = nm(U.try(function() return rc.CurrentRestingAreaActor end)),
                     try_text = U.str(U.try(function() return rc.TryToSleepText end)),
                     early_text = U.str(U.try(function() return rc.TooEarlyToSleepText end)) }
    end
    local lib = U.find_object("/Script/Dominion.Default__InGameTimeFunctionLibrary")
    if lib then
        out.night = U.try(function() return lib:IsNighttime(pc) end)
        local ts = U.try(function() return lib:GetInGameTime(pc) end)
        local ticks = ts and U.try(function() return ts.Ticks end)
        if type(ticks) == "number" then out.hour = math.floor((ticks / 3.6e10) % 24 * 100) / 100 end
    end
    local me = U.loc(pawn)
    out.beds = {}
    for _, cls in ipairs({ "BedComponent", "RestingAreaComponent" }) do
        for _, b in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local o = U.try(function() return b:GetOwner() end)
            if U.valid(o) then
                local p = U.loc(o)
                local d = me and p and U.dist(me, p) / 100
                if d and d < 80 then
                    local ic = U.try(function() return o.Interaction end) or U.try(function() return o.InteractionComponent end)
                    out.beds[#out.beds + 1] = { comp = cls, owner = U.short(o), cls = U.class_word(o), dist_m = math.floor(d * 10) / 10,
                        prompt = U.valid(ic) and U.str(U.try(function() return ic.InteractionPrompt end)) or nil,
                        claim_needed = U.try(function() return b.bRequiresClaimingToSleepIn end),
                        resting_player = nm(U.try(function() return b:GetCurrentRestingPlayer() end)),
                        leave_text = U.str(U.try(function() return b.LeaveActionText end)) }
                end
            end
        end
    end
    return out
end
