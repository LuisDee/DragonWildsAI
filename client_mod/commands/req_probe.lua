-- Spell special-requirement probe (L1). Lists each unlocked spell's SpecialRequirementsStrategy class
-- and SpecialRequirementsText (pure reads). It then calls the game's own BlueprintNativeEvent
-- USpellSpecialRequirementsStrategy::AreSpecialRequirementsMet(const APlayerController*) -> FGameplayTag
-- (a const check: empty tag = met) on the strategy class's DEFAULT OBJECT, for the classes named in
-- ONLY (first run: the logging-axe one alone; widen after it proves safe). No input, no writes.
local ONLY = { BP_USSRS_RequiresLoggingAxe_C = true }
local ALL = true -- run 2 (20:05 UTC+1): the logging-axe call proved safe; all classes
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    if not pc then return { ok = false, reason = "no pc" } end
    local out = { ok = true, spells = {}, called = 0 }
    local prog = pc.ProgressComponent
    local list = {}
    pcall(function() prog.SpellsUnlocked:ForEach(function(a, b)
        local e = b ~= nil and b or a
        if type(e) == "userdata" then local ok, v = pcall(function() return e:get() end); if ok and v then e = v end end
        if U.valid(e) then list[#list + 1] = e end
    end) end)
    for _, s in ipairs(list) do
        local cls = U.try(function() return s.SpecialRequirementsStrategy end)
        if U.valid(cls) then
            local r = { spell = U.short(s), name = U.str(U.try(function() return s.SpellDisplayName end)),
                        text = U.str(U.try(function() return s.SpecialRequirementsText end)), strategy = U.short(cls) }
            if ALL or ONLY[r.strategy] then
                local cdo = U.try(function() return cls:GetCDO() end)
                r.cdo = U.valid(cdo) and U.short(cdo) or nil
                if U.valid(cdo) then
                    out.called = out.called + 1
                    local ok, tag = pcall(function() return cdo:AreSpecialRequirementsMet(pc) end)
                    r.call_ok = ok
                    if ok then
                        r.tag_type = type(tag)
                        r.tag = U.str(U.try(function() return tag.TagName end)) or (type(tag) == "table" and tostring(tag.TagName)) or tostring(tag)
                    else r.err = tostring(tag) end
                end
            end
            out.spells[#out.spells + 1] = r
        end
    end
    return out
end
