-- New-character narrative intro (a Bink video, never ends headless): run the widget's own finish handler.
-- Fallback: the controller's AllowPlayerCharacterToSpawn (what intro completion calls) if no pawn after.
return function(log)
    local res = {}
    local w
    for _, x in ipairs(FindAllOf("NarrativeIntroWidget") or {}) do if not x:GetFullName():find("Default__") and not x:GetFullName():find("WidgetTree") then w = x end end
    res.widget = w and w:GetFullName():match("([%w_]+)$") or "none"
    if w then res.finish = pcall(function() w:OnOutAnimationFinished() end) end
    return res
end
