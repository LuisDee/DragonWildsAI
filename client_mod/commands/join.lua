-- Worlds -> Direct: type IP + password into the real fields and run the Join handler (GoToNextScreen).
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(10)
    local dp = api:GetCurrentScreenWidget().DirectPanel
    local pw = ""
    local f = io.open("C:/GameServers/Dragonwilds/RSDragonwilds/Saved/Config/WindowsServer/DedicatedServer.ini", "r")
    if f then for line in f:lines() do local v = line:match("^WorldPassword=(.*)$"); if v then pw = v:gsub("%s+$", "") end end; f:close() end
    dp.IpAddress.EditableText:SetText(FText("127.0.0.1:7777"))
    dp:OnTextChanged(FText("127.0.0.1:7777"))
    dp.PasswordText.PasswordText:SetText(FText(pw))
    local ok, err = pcall(function() dp:GoToNextScreen() end)
    return { join = ok or tostring(err), screen = tostring(api:GetCurrentScreenType()) }
end
