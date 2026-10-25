-- Open the real character-select screen (loads local characters and selects one), report what it holds.
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(8)
    return { screen = tostring(api:GetCurrentScreenType()) }
end
