-- LIVE probe (rung 5, Rune Mysteries 20261116-074002): does a swing lock out the dodge? One primary press, then the
-- evade `delay` frames later (30 fps), sampled for ~1.5 s: the frame the EvadeComponent reads evading, and how far
-- the dodge carried. Answers whether he may swing during an enemy's wind-up and still dodge on time.
--   ARGS = {delay = 9}          -> press primary, evade 9 frames later (delay = -1: evade alone, the baseline)
--   ARGS = {delay = -1, move = {X = 0, Y = 1}} -> a directional dodge (the move input held 10 frames from the key)
--   ARGS = {read = true}        -> the last result
-- It also samples the pawn's InvulnerableEvadeTag (PlayerDamageComponent): inv_first / inv_last = the frames after
-- the key between which a hit does nothing, i.e. where the key has to sit against an attack's impact.
return function(log)
    local args = (type(ARGS) == "table" and ARGS) or {}
    if args.read then return _G.DW_ATK_EVADE or { done = false, missing = true } end
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
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
    local acts = U.try(function() return pawn.PlayerInputBufferInputActions end)
    local ev, prim, mv = acts and acts.EvadeAction, acts and acts.PrimaryAction, acts and acts.MovementAction
    if not (eis and ev and prim) then return { ok = false, reason = "no actions" } end
    local comp = U.try(function() return pawn.EvadeComponent end)
    if not U.valid(comp) then
        for _, x in ipairs(U.find_all("PlayerEvadeComponent", { skip_defaults = true })) do
            local o = U.try(function() return x:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(pawn) then comp = x end
        end
    end
    local delay = tonumber(args.delay) or 9
    local dmgc = U.try(function() return pawn.PlayerDamageComponent end)
    local function invulnerable()
        if not U.valid(dmgc) then return nil end
        local ok, v = pcall(function() return pawn:HasGameplayTag(dmgc.InvulnerableEvadeTag) end)
        return ok and v == true
    end
    local p0 = U.loc(pawn)
    local res = { done = false, delay = delay, evading_frames = {}, max_h_m = 0, has_comp = U.valid(comp) }
    _G.DW_ATK_EVADE = res
    local function inj(a) return pcall(function() eis:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end) end
    if delay >= 0 then res.primary_injected = inj(prim) end
    local frame, h = 0, nil
    local at = math.max(delay, 0)
    h = LoopInGameThreadWithDelay(1, function()
        frame = frame + 1
        if rawget(_G, "DW_PAUSE") == true or not U.valid(pawn) then CancelDelayedAction(h); return true end
        if frame == at + 1 then
            res.p_at_evade = U.loc(pawn)
            res.evade_injected = inj(ev)
            res.evade_frame = frame
        end
        if type(args.move) == "table" and mv and frame > at and frame <= at + 10 then
            pcall(function() eis:InjectInputVectorForAction(mv, { X = args.move.X or 0, Y = args.move.Y or 0, Z = 0 }, {}, {}) end)
        end
        if res.evade_frame and invulnerable() then
            res.inv_first = res.inv_first or (frame - res.evade_frame)
            res.inv_last = frame - res.evade_frame
            res.inv_frames = (res.inv_frames or 0) + 1
        end
        local e = U.valid(comp) and U.try(function() return comp:IsEvading() end) == true
        if e then
            res.first_evading = res.first_evading or frame
            res.last_evading = frame
        end
        local p = U.loc(pawn)
        local dh = math.sqrt((p.X - p0.X) ^ 2 + (p.Y - p0.Y) ^ 2) / 100
        if dh > res.max_h_m then res.max_h_m = dh end
        if frame >= at + 50 then
            res.end_h_m = dh
            res.evade_lag_frames = res.first_evading and (res.first_evading - res.evade_frame) or nil
            res.p_at_evade = nil
            res.done = true
            CancelDelayedAction(h)
            return true
        end
    end)
    return { ok = true, started = true, delay = delay }
end
