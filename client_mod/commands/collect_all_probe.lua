-- Read-only: the game's collect-all settings (UItemDeveloperSettings CDO: CollectAllRadius, same-type and
-- non-magnetising flags) and what the interaction detector offers right now (prompt + secondary prompt).
return function(log)
    local out = {}
    local ok, cdo = pcall(function() return StaticFindObject("/Script/Dominion.Default__ItemDeveloperSettings") end)
    if ok and cdo and cdo:IsValid() then
        for _, k in ipairs({ "CollectAllRadius", "bCollectAllCollectsOnlySameType", "bCollectAllIgnoresNonMagnetizingItems" }) do
            local okk, v = pcall(function() return cdo[k] end)
            if okk then out[k] = v else out[k] = "err " .. tostring(v) end -- never `ok and v or x`: a false v reads as the error
        end
    else
        out.cdo = "not found"
    end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") then pc = x; break end
    end
    local p = pc and pc.Pawn
    if p and p:IsValid() then
        local okd, det = pcall(function() return p.InteractionDetector end)
        local ic = okd and det and det:IsValid() and det.CurrentInteractable or nil
        if ic and ic:IsValid() then
            local function txt(f) local okt, v = pcall(function() return f():ToString() end); return okt and v or nil end
            local owner = ic:GetOwner()
            out.target = owner and owner:IsValid() and owner:GetFullName():match("([^%.]+)$") or "?"
            out.prompt = txt(function() return ic.InteractionPrompt end)
            out.has_secondary = ic.bHasSecondaryInteraction
            out.secondary_prompt = txt(function() return ic.SecondaryInteractionPrompt end)
            local okm, mag = pcall(function() return owner.bMagnetize end)
            if okm then out.bMagnetize = mag end
        else
            out.target = "none"
        end
    end
    return out
end
