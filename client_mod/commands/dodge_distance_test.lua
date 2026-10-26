-- LIVE probe (spells agent, M2 gap audit 2026-10-26): ONE ground dodge, the pawn's own EvadeAction injected through
-- Enhanced Input (what the dodge key does; same path as air_dash_test.lua, but on the ground), sampled for ~1.5 s.
-- It measures what Surge adds (wiki: a Surge charge makes a dodge travel 8 m; data/spell_effects.json proof kind
-- dodge_distance_gain_m had no probe). Refuses while the arbiter has an owner or the pawn is falling.
--   ARGS = nil / {}        -> start a dodge; result lands in _G.DW_DODGE_DIST (+ client_io/out/dodge_distance_async.json)
--   ARGS = {read = true}   -> return the last result (read-only)
return function(log)
    local args = (type(ARGS) == "table" and ARGS) or {}
    if args.read then return _G.DW_DODGE_DIST or { done = false, missing = true } end
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
    if U.try(function() return pawn.CharacterMovement:IsFalling() end) == true then return { ok = false, reason = "falling" } end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local ev = U.try(function() return pawn.PlayerInputBufferInputActions.EvadeAction end)
    if not (eis and ev) then return { ok = false, reason = "no evade action" } end
    local p0 = U.loc(pawn)
    local res = { done = false, start = { p0.X / 100, p0.Y / 100, p0.Z / 100 }, max_h_m = 0, tags = {} }
    _G.DW_DODGE_DIST = res
    res.evade_injected = pcall(function() eis:InjectInputVectorForAction(ev, { X = 1, Y = 0, Z = 0 }, {}, {}) end)
    local frame, h = 0, nil
    h = LoopInGameThreadWithDelay(1, function()
        frame = frame + 1
        if rawget(_G, "DW_PAUSE") == true or not U.valid(pawn) then CancelDelayedAction(h); return true end
        local p = U.loc(pawn)
        local dh = math.sqrt((p.X - p0.X) ^ 2 + (p.Y - p0.Y) ^ 2) / 100
        if dh > res.max_h_m then res.max_h_m = dh end
        if frame == 4 then
            local ge = U.try(function() return pawn.GameplayEffectsComponent end)
            pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) res.tags[#res.tags + 1] = U.str(t:get().TagName) end) end)
        end
        if frame >= 45 then
            res.end_pos = { p.X / 100, p.Y / 100, p.Z / 100 }
            res.end_h_m = math.sqrt((p.X - p0.X) ^ 2 + (p.Y - p0.Y) ^ 2) / 100
            res.done = true
            local f = io.open("C:/gameserver/client_io/out/dodge_distance_async.json", "wb")
            if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h)
            return true
        end
    end)
    return { ok = true, started = true }
end
