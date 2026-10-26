-- Read-only: the UFunction names of the Journal / Notification / MainMenu UI APIs (to find the close for a focused screen).
return function(log)
    local out = {}
    for _, cls in ipairs({ "JournalUIAPI", "NotificationUIAPI", "MainMenuUIAPI" }) do
        local a = FindFirstOf(cls)
        local names = {}
        if a and a:IsValid() then
            local c = a:GetClass()
            while c and c:IsValid() and #names < 80 do
                pcall(function() c:ForEachFunction(function(f) names[#names + 1] = f:GetFName():ToString() end) end)
                local ok, sup = pcall(function() return c:GetSuperStruct() end)
                if not ok or not sup or not sup:IsValid() or sup:GetFName():ToString() == "Object" then break end
                c = sup
            end
        end
        out[cls] = names
    end
    return { ok = true, funcs = out }
end
