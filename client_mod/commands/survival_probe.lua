-- Read-only survival probe (survival agent 2026-11-01): toxicity (Soulscourge build-up) and endurance (= the wiki's
-- "Rest") component values on Claude's own pawn, incl. the per-level thresholds and the spell/death costs.
-- Property reads and getters only. Copy to client_io/cmd/ and queue it (client_lib.ps1 Invoke-ClientCmd).
return function(log)
    local pc = FindFirstOf("PlayerController")
    local p = pc and pc.Pawn
    if not (p and p:IsValid()) then return { error = "no pawn" } end
    local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
    local function n(v) return type(v) == "number" and v or nil end
    local out = {}
    local tox = try(function() return p.BP_Components_Toxicity end)
    if tox and tox:IsValid() then
        out.toxicity = { current = n(try(function() return tox.CurrentToxicity end)),
                         highest = n(try(function() return tox.HighestToxicity end)) }
        local lv = {}
        try(function() tox.ToxicityEffectLevels:ForEach(function(_, e) lv[#lv + 1] = n(try(function() return e:get().Value end)) end) end)
        out.toxicity.levels = lv
    end
    local en = try(function() return p.BP_EnduranceComponent end)
    if en and en:IsValid() then
        out.endurance = { current = n(try(function() return en.CurrentEndurance end)),
                          max = n(try(function() return en.MaxEndurance end)),
                          start = n(try(function() return en.StartEndurance end)),
                          removed_on_death = n(try(function() return en.EnduranceRemovedOnDeath end)),
                          removed_per_spell = n(try(function() return en.EnduranceRemovedFromSpellCast end)) }
        local lv = {}
        try(function() en.EnduranceEffectLevels:ForEach(function(_, e) lv[#lv + 1] = n(try(function() return e:get().Value end)) end) end)
        out.endurance.levels = lv
    end
    local st = try(function() return p.StaminaComponent end)
    if st and st:IsValid() then
        out.stamina = { current = n(try(function() return st:GetCurrentStamina() end)), max = n(try(function() return st:GetMaxStamina() end)) }
    end
    out.hydration_max = n(try(function() return p.HydrationComponent:GetMaxHydration() end))
    out.sustenance_max = n(try(function() return p.SustenanceComponent:GetMaxSustenance() end))
    return out
end
