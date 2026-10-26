-- Read-only: which UserWidgets are in the viewport now (to identify what put the PC in DIM_FocussedInGameUI).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local out = {}
    for _, w in ipairs(U.find_all("UserWidget", { skip_defaults = true }) or {}) do
        local inv = U.try(function() return w:IsInViewport() end)
        if inv == true then out[#out + 1] = U.class_word(w) end
        if #out > 60 then break end
    end
    table.sort(out)
    return { ok = true, mode = I.input_mode(), in_viewport = out }
end
