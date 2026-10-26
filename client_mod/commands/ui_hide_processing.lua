-- Experiment (BUGS B-stuck-focused-ui): the OLD crafting close for a processing station, CraftingUIAPI:HideCraftingUI(15).
-- Run it while stuck, then widget_open_probe, to see whether it closes the Processing (15) / Inventory (11) widgets.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local ui
    for _, a in ipairs(U.find_all("CraftingUIAPI", { skip_defaults = true }) or {}) do ui = a; break end
    if not ui then return { ok = false, reason = "no CraftingUIAPI" } end
    local ok, err = pcall(function() ui:HideCraftingUI(15) end)
    return { ok = ok, err = (not ok) and tostring(err) or nil, before = I.input_mode() }
end
