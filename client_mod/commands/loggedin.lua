return function(log)
    local mm = FindFirstOf("DomMatchmakerSubsystem")
    local api = FindFirstOf("MainMenuUIAPI")
    return { logged_in = tostring(mm:IsUserLoggedIn()), screen = tostring(api:GetCurrentScreenType()) }
end
