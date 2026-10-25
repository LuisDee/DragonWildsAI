-- LIVE DIAGNOSTIC (spells agent; NEVER selects, so nothing can be cast): open the spell wheel (Q),
-- call the radial's own UI handler HighlightSlice(9) (BlueprintCallable, what hovering a slice runs),
-- read CachedSectionId + the SpellName text in the same frame and the following frames, then close
-- the wheel (Q). Refuses while the arbiter has an owner or the mode is not gameplay.
-- Results -> client_io/out/wheel_highlight_async.json.
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
    local panel
    for _, p in ipairs(U.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (U.fullname(p) or ""):find("WidgetTree", 1, true) then panel = p end
    end
    if not (pc and panel) then return { ok = false, reason = "no pc/panel" } end
    if U.short(U.try(function() return pc.CurrentInputMode end)) ~= "DIM_Gameplay" then return { ok = false, reason = "not gameplay" } end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local rw = panel.SpellRadialWidget
    local function inject(a) return U.valid(a) and pcall(function() eis:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end) end
    local function read(label)
        return { label = label, mode = U.short(U.try(function() return pc.CurrentInputMode end)), section = U.try(function() return rw.CachedSectionId end),
                 name = U.str(U.try(function() return rw.SpellName:GetText() end)), computing = U.try(function() return rw.bComputing end),
                 sel = U.short(U.try(function() return pc.SpellcastingComponent:GetCurrentlySelectedSpellData() end)) }
    end
    local res = { steps = {} }
    local frame, h = 0, nil
    inject(panel.TriggerSpellRadialInputAction)
    h = LoopInGameThreadWithDelay(1, function()
        frame = frame + 1
        if rawget(_G, "DW_PAUSE") == true then CancelDelayedAction(h); return true end
        if frame == 12 then
            res.steps[#res.steps + 1] = read("opened")
            local ok, err = pcall(function() rw:HighlightSlice(9) end)
            res.call_ok, res.call_err = ok, (not ok) and tostring(err) or nil
            res.steps[#res.steps + 1] = read("same frame")
        elseif frame == 13 or frame == 16 or frame == 24 then
            res.steps[#res.steps + 1] = read("frame +" .. (frame - 12))
        elseif frame == 26 then
            if U.short(U.try(function() return pc.CurrentInputMode end)) == "DIM_RadialMenu" then inject(panel.TriggerSpellRadialInputAction) end
        elseif frame == 40 then
            res.steps[#res.steps + 1] = read("closed")
            local f = io.open("C:/gameserver/client_io/out/wheel_highlight_async.json", "wb")
            if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h)
            return true
        end
    end)
    return { ok = true, started = true }
end
