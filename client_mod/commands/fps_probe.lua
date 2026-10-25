-- Read-only: frame-rate limiter state (t.MaxFPS and friends, GameUserSettings limits).
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local K = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local out = { cvars = {} }
    for _, n in ipairs({ "t.MaxFPS", "domMaxFPS", "r.VSync", "t.IdleWhenNotForeground", "r.DontLimitOnBattery" }) do
        out.cvars[n] = U.try(function() return K:GetConsoleVariableFloatValue(n) end)
    end
    local gus = U.try(function() return StaticFindObject("/Script/Engine.Default__GameUserSettings"):GetGameUserSettings() end)
    if U.valid(gus) then
        out.gus_class = U.class_word(gus)
        out.FrameRateLimit = U.try(function() return gus:GetFrameRateLimit() end)
        out.GameFrameRateLimit = U.try(function() return gus.GameFrameRateLimit end)
        out.FrontendFrameRateLimit = U.try(function() return gus.FrontendFrameRateLimit end)
    end
    local eng = U.find_first("GameEngine")
    if eng then
        out.bSmoothFrameRate = U.try(function() return eng.bSmoothFrameRate end)
        out.bUseFixedFrameRate = U.try(function() return eng.bUseFixedFrameRate end)
        out.FixedFrameRate = U.try(function() return eng.FixedFrameRate end)
    end
    return out
end
