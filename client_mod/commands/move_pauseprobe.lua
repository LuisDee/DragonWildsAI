-- Read-only: which UI objects exist in-world for the pause menu / Unstuck path.
return function(log)
    local out = {}
    for _, c in ipairs({ "PauseMenuScreen", "MainMenuUIAPI", "DomHeldProgressBarButton", "DominionHUD", "InGameUIAPI" }) do
        local n, names = 0, {}
        for _, o in ipairs(FindAllOf(c) or {}) do
            if not o:GetFullName():find("Default__") then n = n + 1; if #names < 3 then names[#names + 1] = o:GetFullName():sub(1, 160) end end
        end
        out[c] = { n = n, names = names }
    end
    return out
end
