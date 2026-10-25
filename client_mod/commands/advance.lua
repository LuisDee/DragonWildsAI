-- Advance through first-run legal screens using each screen's own confirm handler (as its button does).
-- EULA (41): scroll to end, confirm. TOS/PP (24): accept. Player conduct (21): confirm.
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    local steps = {}
    for _ = 1, 6 do
        local t = tonumber(tostring(api:GetCurrentScreenType()))
        local w = api:GetCurrentScreenWidget()
        local ok, err
        if t == 41 then ok, err = pcall(function() w:OnUserScrolled(1.0); w:OnConfirmClicked() end)
        elseif t == 24 then ok, err = pcall(function() w:OnButtonAcceptClicked() end)
        elseif t == 21 then ok, err = pcall(function() w:OnConfirmClicked() end)
        else steps[#steps + 1] = { stop_at = t, widget = w:IsValid() and w:GetFullName():match("([%w_]+_C)") or "nil" }; break end
        steps[#steps + 1] = { screen = t, ok = ok, err = err and tostring(err) or nil, next = tostring(api:GetCurrentScreenType()) }
        if tonumber(tostring(api:GetCurrentScreenType())) == t then break end
    end
    return steps
end
