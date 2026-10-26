-- Read-only: visible UserWidgets (not floating text/damage), by class, to find what holds DIM_FocussedInGameUI.
return function(log)
    local count = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        local okv, vis = pcall(function() return w:IsVisible() end)
        if okv and vis then
            local n = w:GetClass():GetFName():ToString()
            if not n:find("Floating", 1, true) then count[n] = (count[n] or 0) + 1 end
        end
    end
    local out = {}
    for k, v in pairs(count) do out[#out + 1] = k .. " x" .. v end
    table.sort(out)
    return { ok = true, visible = out }
end
