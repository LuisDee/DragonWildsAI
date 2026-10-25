-- LIVE (spells agent): put the spell panel back on the spell radial (SwitchRadial if the emote radial
-- is showing) and close the wheel with Q; report slice SpellSlotNums and the final input mode.
-- Results -> client_io/out/wheel_close_async.json. No spell key pressed.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local J = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local panel
    for _, p in ipairs(U.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        if not (U.fullname(p) or ""):find("WidgetTree", 1, true) then panel = p end
    end
    local eis = U.find_first("EnhancedInputLocalPlayerSubsystem")
    local function inject(a) return U.valid(a) and pcall(function() eis:InjectInputVectorForAction(a, { X = 1, Y = 0, Z = 0 }, {}, {}) end) end
    local function read(label)
        local nums = {}
        pcall(function() panel.SpellRadialWidget.Slices:ForEach(function(_, e) nums[#nums + 1] = U.try(function() return e:get().SpellSlotNum end) end) end)
        return { label = label, mode = U.short(U.try(function() return pc.CurrentInputMode end)),
                 switcher = U.try(function() return panel.WidgetSwitcher:GetActiveWidgetIndex() end), slot_nums = nums }
    end
    local res = { read("before") }
    local steps = {}
    if res[1].switcher == 1 then steps[#steps + 1] = function() inject(panel.SwitchRadialInputAction); return "press switch" end end
    steps[#steps + 1] = function() return read("mid") end
    steps[#steps + 1] = function() if U.short(U.try(function() return pc.CurrentInputMode end)) ~= "DIM_Gameplay" then inject(panel.TriggerSpellRadialInputAction); return "press menu" end; return "already closed" end
    steps[#steps + 1] = function() return read("after") end
    local i, h = 1, nil
    h = LoopInGameThreadWithDelay(400, function()
        if i > #steps then
            local f = io.open("C:/gameserver/client_io/out/wheel_close_async.json", "wb"); if f then f:write(J.encode(res)); f:close() end
            CancelDelayedAction(h); return true
        end
        local ok, r = pcall(steps[i]); res[#res + 1] = ok and r or ("err " .. tostring(r)); i = i + 1
    end)
    return { ok = true, started = true }
end
