-- Create a character through the real character-create screen (verified flow, DISCOVERIES R2).
-- Name: client_io/state/character_name.txt, else "Claude".
return function(log)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local name = "Claude"
    local f = io.open(root .. "/client_io/state/character_name.txt", "r")
    if f then local n = (f:read("*l") or ""):match("^%s*(.-)%s*$"); f:close(); if n ~= "" then name = n end end
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(7)
    local w = api:GetCurrentScreenWidget()
    w:OnCharacterTypeSelected_Standard()
    local et = w.EditableTextCharacterName.EditableText
    et:SetText(FText(name))
    w:OnCharacterNameInputChanged(FText(name))
    local ok, err = pcall(function() w:CheckNameAndCreate() end)
    return { create = ok or tostring(err), name = name, screen = tostring(api:GetCurrentScreenType()) }
end
