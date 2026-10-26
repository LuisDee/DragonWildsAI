-- READ-ONLY build probe P2: the key mappings of the building mapping contexts (which action PLACES),
-- the input-mode data assets the PC uses for building, and whether IA_BuildMenu is loaded. Nothing pressed.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local out = { ok = true, imc = {} }
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    for _, n in ipairs({ "IMC_BuildingMode", "IMC_BuildingGeneral", "IMC_BuildingUI", "IMC_BuildMenuPrompt" }) do
        local path = n == "IMC_BuildMenuPrompt" and "/Game/Gameplay/Inputs/Mappings/InputPrompts/IMC_BuildMenuPrompt.IMC_BuildMenuPrompt"
            or ("/Game/Gameplay/Inputs/Mappings/" .. n .. "." .. n)
        local c = U.find_object(path)
        local rows = {}
        if c then
            pcall(function() c.Mappings:ForEach(function(_, m)
                local e = m:get()
                if #rows < 40 then
                    rows[#rows + 1] = nm(U.try(function() return e.Action end)) .. "=" .. tostring(U.str(U.try(function() return e.Key.KeyName end)))
                end
            end) end)
            out.imc[n] = rows
        else out.imc[n] = "not loaded" end
    end
    out.menu_action_loaded = U.find_object("/Game/Gameplay/Inputs/Actions/UI/IA_BuildMenu.IA_BuildMenu") ~= nil
    out.primary_loaded = U.find_object("/Game/Gameplay/Inputs/Actions/Basic/IA_PrimaryAction.IA_PrimaryAction") ~= nil
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local cm = pc and U.try(function() return pc.CurrentInputMode end)
    out.current_mode = nm(cm)
    out.mode_class = U.class_word(cm)
    -- input-mode assets with Build / Oculus / Placement in their name (the modes build mode switches to)
    local modes = {}
    for _, o in ipairs(out.mode_class and U.find_all(out.mode_class, { skip_defaults = true }) or {}) do
        local s = U.short(o) or ""
        if s:find("Build") or s:find("Oculus") or s:find("Placement") then modes[#modes + 1] = s end
    end
    out.build_modes = modes
    return out
end
