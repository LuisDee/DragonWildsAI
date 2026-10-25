-- Consent form: decline optional data sharing on the live popup (RefuseAll).
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    local w = api:GetCurrentScreenWidget()
    local dlg
    for _, d in ipairs(FindAllOf("GenericDialog3Buttons") or {}) do if not d:GetFullName():find("Default__") then dlg = d end end
    local ok = pcall(function() w:RefuseAll(dlg) end)
    return { refuse = ok, screen = tostring(api:GetCurrentScreenType()) }
end
