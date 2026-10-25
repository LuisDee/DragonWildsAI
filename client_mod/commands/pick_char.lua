-- Select the local character the way the landing screen's character selector does
-- (CharacterSelectorWidget:OnSelectionUpdatedUpdatePlayerCharacter(index)), then sign in if needed.
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(2)
    local w = api:GetCurrentScreenWidget()
    local ok, err = pcall(function() w.CharacterSelectorWidget:OnSelectionUpdatedUpdatePlayerCharacter(0) end)
    local mm = FindFirstOf("DomMatchmakerSubsystem")
    if not mm:IsUserLoggedIn() then pcall(function() w:OnLoginTriggered() end) end
    return { screen = tostring(api:GetCurrentScreenType()), picked = ok or tostring(err) }
end
