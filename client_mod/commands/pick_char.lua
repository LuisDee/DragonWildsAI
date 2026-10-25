-- Select the local character the way the landing screen's character selector does
-- (CharacterSelectorWidget:OnSelectionUpdatedUpdatePlayerCharacter(index)), then sign in if needed.
-- Which character: the name in client_io/state/character_name.txt (matched against the selector's
-- SelectableChoiceData[].DisplaySlotName), else index 0. GOAL.md: dev runs use a dedicated dev character.
return function(log)
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local want
    local f = io.open(root .. "/client_io/state/character_name.txt", "r")
    if f then want = (f:read("*l") or ""):match("^%s*(.-)%s*$"); f:close() end
    if want == "" then want = nil end
    local api = FindFirstOf("MainMenuUIAPI")
    api:NavigateToScreen(2)
    local w = api:GetCurrentScreenWidget()
    local sel = w.CharacterSelectorWidget
    local idx, names = 0, {}
    if want then
        idx = nil
        pcall(function()
            sel.SelectableChoiceData:ForEach(function(i, e)
                local n = e:get().DisplaySlotName:ToString()
                names[#names + 1] = n
                if n == want and not idx then idx = i - 1 end
            end)
        end)
        if not idx then return { ok = false, reason = "character_not_found", want = want, have = names } end
    end
    local ok, err = pcall(function() sel:OnSelectionUpdatedUpdatePlayerCharacter(idx) end)
    local mm = FindFirstOf("DomMatchmakerSubsystem")
    if not mm:IsUserLoggedIn() then pcall(function() w:OnLoginTriggered() end) end
    return { screen = tostring(api:GetCurrentScreenType()), picked = ok or tostring(err), index = idx, want = want, have = names }
end
