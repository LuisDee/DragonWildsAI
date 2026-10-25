-- Press Start on whichever worlds panel has the selected Online Session (Recent/Public/Friends).
return function(log)
    local api = FindFirstOf("MainMenuUIAPI")
    local scr = api:GetCurrentScreenWidget()
    local res = { screen = tostring(api:GetCurrentScreenType()) }
    for _, name in ipairs({ "RecentPanel", "PublicPanel", "FriendsPanel" }) do
        local p = scr[name]
        if p and p:IsValid() then
            local ok, err = pcall(function() p:StartGamePressed() end)
            res[name] = ok or tostring(err)
            if ok then break end
        end
    end
    res.after = tostring(api:GetCurrentScreenType())
    return res
end
