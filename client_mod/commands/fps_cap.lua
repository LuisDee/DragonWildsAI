-- Cap the client's frame rate at runtime through the game's own user settings (the same values
-- GameUserSettings.ini holds for the next boot). Client-local; see DISCOVERIES "Client hang (R2)".
local CAP = 30.0
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local gus = StaticFindObject("/Script/Engine.Default__GameUserSettings"):GetGameUserSettings()
    if not U.valid(gus) then return { ok = false, reason = "no_game_user_settings" } end
    gus.GameFrameRateLimit = CAP
    gus.FrontendFrameRateLimit = CAP
    gus:SetFrameRateLimit(CAP)
    gus:ApplyNonResolutionSettings()
    local K = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    return { ok = true, FrameRateLimit = gus:GetFrameRateLimit(), GameFrameRateLimit = gus.GameFrameRateLimit,
             FrontendFrameRateLimit = gus.FrontendFrameRateLimit,
             t_MaxFPS = U.try(function() return K:GetConsoleVariableFloatValue("t.MaxFPS") end) }
end
