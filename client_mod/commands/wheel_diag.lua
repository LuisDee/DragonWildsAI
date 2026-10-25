-- LIVE DIAGNOSTIC (injects input; spells agent, with main's go): open the spell wheel (Q), read the
-- slice icons, press "next page" (ChangeSpellRadialRightInputAction), read again, try the panel's
-- SwitchRadialInputAction, read again, then close the wheel (Q) and confirm DIM_Gameplay. No spell key
-- is pressed, so nothing can be cast. Results -> client_io/out/wheel_diag_async.json.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local J = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local panel
    for _, p in ipairs(U.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (U.fullname(p) or ""):find("WidgetTree", 1, true) then panel = p end
    end
    if not (pc and panel) then return { ok = false, reason = "no pc/panel" } end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local function inject(a) return U.valid(a) and pcall(function() eis:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end) end
    local rw = panel.SpellRadialWidget
    local function read(label)
        local icons = {}
        pcall(function() rw.Slices:ForEach(function(_, e) local s = e:get(); icons[#icons + 1] = U.short(U.try(function() return s.SliceIcon.Brush.ResourceObject end)) or "-" end) end)
        return { label = label, mode = U.short(U.try(function() return pc.CurrentInputMode end)), visible = U.try(function() return panel:IsVisible() end),
                 switcher = U.try(function() return panel.WidgetSwitcher:GetActiveWidgetIndex() end),
                 name = U.str(U.try(function() return rw.SpellName:GetText() end)), sel = U.short(U.try(function() return pc.SpellcastingComponent:GetCurrentlySelectedSpellData() end)),
                 icon1 = icons[1], icon2 = icons[2], n = #icons }
    end
    local A = { menu = panel.TriggerSpellRadialInputAction, right = panel.ChangeSpellRadialRightInputAction, switch = panel.SwitchRadialInputAction }
    local steps = {
        function() inject(A.menu); return "press menu" end,
        function() return read("after menu") end,
        function() inject(A.right); return "press right" end,
        function() return read("after right") end,
        function() inject(A.switch); return "press switch" end,
        function() return read("after switch") end,
        function() inject(A.menu); return "press menu (close)" end,
        function() return read("after close") end,
    }
    local res, i, ticks = { read("before") }, 1, 0
    local h
    h = LoopInGameThreadWithDelay(400, function()
        if rawget(_G, "DW_PAUSE") == true or i > #steps then
            local f = io.open("C:/gameserver/client_io/out/wheel_diag_async.json", "wb")
            if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h)
            return true
        end
        local ok, r = pcall(steps[i]); res[#res + 1] = ok and r or ("err " .. tostring(r)); i = i + 1
    end)
    return { ok = true, started = true, actions = { menu = U.short(A.menu), right = U.short(A.right), switch = U.short(A.switch) } }
end
