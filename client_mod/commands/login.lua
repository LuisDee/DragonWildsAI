-- Landing screen: the game's own sign-in (OnLoginTriggered, what the login button runs).
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(2)
    local w = api:GetCurrentScreenWidget()
    local res = { screen = tostring(api:GetCurrentScreenType()), widget = w:GetFullName():match("([%w_]+_C)_%d+$") }
    res.login = pcall(function() w:OnLoginTriggered() end)
    local mm = FindFirstOf("DomMatchmakerSubsystem")
    res.logged_in = mm and tostring(mm:IsUserLoggedIn()) or "?"
    return res
end
