-- READ-ONLY: the key mappings of the spell-related input mapping contexts and the DIM_* input modes
-- (which contexts each mode applies, and its flags), plus the UI's own display info for wheel slot 0
-- (SpellcastingUIAPI:GetSpellDisplayInfo, BlueprintPure). Nothing injected or written.
return function(log)
    local ROOT = "C:/gameserver"
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local out = { ok = true, contexts = {}, modes = {} }
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local function trig(list, arr)
        pcall(function() arr:ForEach(function(_, t)
            local o = t:get(); local w = U.class_word(o)
            local hold = U.try(function() return o.HoldTimeThreshold end)
            list[#list + 1] = hold and (w .. "(" .. string.format("%.2f", hold) .. ")") or w
        end) end)
    end
    local want = { "IMC_SpellcastingMode", "IMC_SpellcastingModeAdvancedMovement", "IMC_RadialSelection", "IMC_GameplayUI",
                   "IMC_SpellMenuPrompt", "IMC_Combat", "IMC_SpellsUI", "IMC_TopBarMenuSpellsRadial" }
    for _, n in ipairs(want) do
        local c = U.find_object("/Game/Gameplay/Inputs/Mappings/" .. n .. "." .. n)
        if c then
            local rows = {}
            pcall(function() c.Mappings:ForEach(function(_, m)
                local e = m:get()
                local a = nm(U.try(function() return e.Action end)) or "?"
                if n ~= "IMC_GameplayUI" and n ~= "IMC_Combat" or a:find("Spell", 1, true) or a:find("Radial", 1, true) or a:find("Primary", 1, true) then
                    local k = U.str(U.try(function() return e.Key.KeyName end))
                    local r = { a = a, key = k, trig = {} }
                    trig(r.trig, U.try(function() return e.Triggers end))
                    rows[#rows + 1] = r
                end
            end) end)
            out.contexts[n] = rows
        else
            out.contexts[n] = "not loaded"
        end
    end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    if not pc then return { ok = false, reason = "no pc" } end
    for _, k in ipairs({ "SpellcastingModeInputMode", "SpellPlacementModeInputMode", "RadialMenuInputMode" }) do
        local m = U.try(function() return pc[k] end)
        if U.valid(m) then
            local d = { name = U.short(m), config = U.try(function() return m.InputConfig end),
                        spell_menu_ok = U.try(function() return m.bIsSpellcastingMenuAllowedToOpen end),
                        hold_attack = U.try(function() return m.bCanHoldToAttackWhileModeActive end), contexts = {} }
            pcall(function() m.Mappings:ForEach(function(_, e)
                local x = e:get()
                d.contexts[#d.contexts + 1] = (nm(U.try(function() return x.MappingContext end)) or "?") .. "@" .. tostring(U.try(function() return x.Priority end))
            end) end)
            out.modes[k] = d
        end
    end
    -- the UI's own view of slot 0 (only when a spell sits there)
    local sc = U.try(function() return pc.SpellcastingComponent end)
    local first = sc and U.try(function() return sc.SelectedSpells[1] end)
    local hud = U.find_first("HUDUISubsystem")
    local api = hud and U.try(function() return hud.SpellcastingAPI end)
    if U.valid(first) and U.valid(api) then
        local ok, info = pcall(function() return api:GetSpellDisplayInfo(0) end)
        out.display_ok = ok
        if ok and info ~= nil then
            local d = { type = type(info) }
            local function f(k) return U.try(function() return info[k] end) end
            d.name = U.str(f("SpellName")); d.desc = U.str(f("DescriptionText")); d.unlocked = f("bIsUnlocked")
            d.cooldown = f("CooldownDuration"); d.special = f("bHasSpecialRequirement"); d.special_text = U.str(f("SpecialRequirementText"))
            d.cost, d.missing = {}, {}
            for _, key in ipairs({ "SpellItemCost", "SpellItemsMissing" }) do
                local arr = f(key)
                local dst = key == "SpellItemCost" and d.cost or d.missing
                if type(arr) == "table" then
                    for _, c in ipairs(arr) do dst[#dst + 1] = { nm(c.ItemData) or tostring(c.ItemData), c.Count } end
                else
                    pcall(function() arr:ForEach(function(_, c) local x = c:get(); dst[#dst + 1] = { nm(x.ItemData), x.Count } end) end)
                end
            end
            out.display0 = d
        else
            out.display_err = tostring(info)
        end
    end
    return out
end
