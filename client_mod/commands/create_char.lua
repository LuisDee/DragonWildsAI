-- Create a character named Claude through the real character-create screen (verified flow, DISCOVERIES R2).
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(7)
    local w = api:GetCurrentScreenWidget()
    w:OnCharacterTypeSelected_Standard()
    local et = w.EditableTextCharacterName.EditableText
    et:SetText(FText("Claude"))
    w:OnCharacterNameInputChanged(FText("Claude"))
    local ok, err = pcall(function() w:CheckNameAndCreate() end)
    return { create = ok or tostring(err), screen = tostring(api:GetCurrentScreenType()) }
end
