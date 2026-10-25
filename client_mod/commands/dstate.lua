return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    local dp = api:GetCurrentScreenWidget().DirectPanel
    return { screen = tostring(api:GetCurrentScreenType()), err_vis = tostring(dp.IpErrorText:GetVisibility()),
             ip = dp.IpAddress.EditableText:GetText():ToString(), join_enabled = tostring(dp.JoinButton:GetIsEnabled()),
             wts = dp.WorldTypeSelector:GetFullName() }
end
