-- LIVE DIAGNOSTIC (spells agent; injects input, NEVER accepts, so nothing can be cast): open the
-- spell wheel (Q), then for each of 12 stick directions hold IA_SpellsMenu_SelectSlot (Axis2D, the
-- gamepad right stick) for ~0.25 s, injected every frame, and read the radial's CachedSectionId and
-- the SpellName text it shows. Then close the wheel (Q) and confirm DIM_Gameplay.
-- Refuses while the arbiter has an owner (the brain's actions come first).
-- Results -> client_io/out/wheel_stick_async.json.
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
    local mode0 = U.short(U.try(function() return pc.CurrentInputMode end))
    if mode0 ~= "DIM_Gameplay" then return { ok = false, reason = "not in gameplay mode: " .. tostring(mode0) } end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local rw = panel.SpellRadialWidget
    local sel = U.try(function() return rw.SelectSlotInputAction end)
    local function inject(a, x, y) return U.valid(a) and pcall(function() eis:InjectInputVectorForAction(a, { X = x, Y = y, Z = 0 }, {}, {}) end) end
    local function read()
        return { mode = U.short(U.try(function() return pc.CurrentInputMode end)), section = U.try(function() return rw.CachedSectionId end),
                 name = U.str(U.try(function() return rw.SpellName:GetText() end)),
                 sel = U.short(U.try(function() return pc.SpellcastingComponent:GetCurrentlySelectedSpellData() end)) }
    end
    local res = { sel_action = U.short(sel), offset = U.try(function() return rw.OffsetDegree end), stick = U.try(function() return rw.RadialMenuStickinessType end),
                  only_over = U.try(function() return rw.bOnlySelectOverRadial end), before = read(), dirs = {} }
    local frame, dir, h = 0, -1, nil
    inject(panel.TriggerSpellRadialInputAction, 1, 0) -- Q (Released next frame)
    h = LoopInGameThreadWithDelay(1, function()
        frame = frame + 1
        if rawget(_G, "DW_PAUSE") == true then CancelDelayedAction(h); return true end
        if frame == 12 then res.opened = read(); dir = 0 end
        if dir >= 0 and dir < 12 then
            local a = math.rad(dir * 30)
            inject(sel, math.cos(a), math.sin(a))
            if frame % 8 == 0 then
                local r = read(); r.deg = dir * 30
                res.dirs[#res.dirs + 1] = r
                dir = dir + 1
            end
        elseif dir == 12 then
            dir = 13
            res.after_release = read()
            if U.short(U.try(function() return pc.CurrentInputMode end)) == "DIM_RadialMenu" then inject(panel.TriggerSpellRadialInputAction, 1, 0) end
        elseif dir >= 13 then
            dir = dir + 1
            if dir == 25 then
                res.closed = read()
                local f = io.open("C:/gameserver/client_io/out/wheel_stick_async.json", "wb")
                if f then f:write(J.encode(res)); f:close() end
                CancelDelayedAction(h)
                return true
            end
        end
        if frame > 400 then CancelDelayedAction(h); return true end
    end)
    return { ok = true, started = true }
end
