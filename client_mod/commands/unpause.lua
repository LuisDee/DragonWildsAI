-- Clear _G.DW_PAUSE once the new pawn exists (until the bridge does this automatically).
return function(log)
    local pc; for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local ok = pc and pc.Pawn and pc.Pawn:IsValid()
    if ok then _G.DW_PAUSE = false end
    return { paused = _G.DW_PAUSE == true, pawn = ok and true or false }
end
