-- Read-only: which HUD widgets the game's own InputManagerUIAPI thinks are open (IsOpen for every EWidgetType,
-- dump Dominion_enums.hpp EWidgetType) + CurrentlyActiveWidgetForController + the PC input mode. Used to find
-- what holds DIM_FocussedInGameUI with no visible screen (BUGS B-stuck-focused-ui).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local pc = I.pc()
    local api
    for _, a in ipairs(U.find_all("InputManagerUIAPI", { skip_defaults = true }) or {}) do api = a; break end
    if not api then return { ok = false, reason = "no InputManagerUIAPI" } end
    local open = {}
    for t = 1, 41 do
        local ok, v = pcall(function() return api:IsOpen(pc, t) end)
        if ok and v == true then open[#open + 1] = t end
    end
    local active = U.try(function() return api.CurrentlyActiveWidgetForController end)
    local lore
    for _, a in ipairs(U.find_all("LorePopupUIAPI", { skip_defaults = true }) or {}) do
        lore = U.try(function() return tostring(a.CurrentEntry:ToString()) end) or "?"
    end
    local panels = {}
    for _, w in ipairs(U.find_all("DomHUDUserWidget", { skip_defaults = true }) or {}) do
        local vis = U.try(function() return w:GetVisibility() end)
        local inv = U.try(function() return w:IsInViewport() end)
        local n = U.class_word(w)
        if vis ~= nil and vis ~= 1 and vis ~= 2 and not n:find("Floating", 1, true) then
            panels[#panels + 1] = n .. " vis=" .. tostring(vis) .. " vp=" .. tostring(inv)
        end
        if #panels > 80 then break end
    end
    table.sort(panels)
    return { ok = true, mode = I.input_mode(), open = open,
        active = U.valid(active) and U.class_word(active) or nil, lore_entry = lore, visible_hud_panels = panels }
end
