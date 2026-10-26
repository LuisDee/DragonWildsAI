-- The game's own HUD-widget close: InputManagerUIAPI:CloseWidgetIfOpen(PC, EWidgetType, bIsTriggeredByOutsideWidget=false,
-- bShouldCheckPauseBlock=false) for every widget IsOpen reports (BUGS B-stuck-focused-ui). Reports what it closed.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local U = I.U
    local pc = I.pc()
    local api
    for _, a in ipairs(U.find_all("InputManagerUIAPI", { skip_defaults = true }) or {}) do api = a; break end
    if not api then return { ok = false, reason = "no InputManagerUIAPI" } end
    local closed, errs = {}, {}
    for _, t in ipairs({ 15, 11 }) do
        local okq, open = pcall(function() return api:IsOpen(pc, t) end)
        if okq and open == true then
            local ok, err = pcall(function() api:CloseWidgetIfOpen(pc, t, false, false) end)
            if ok then closed[#closed + 1] = t else errs[#errs + 1] = tostring(err) end
        end
    end
    return { ok = #errs == 0, closed = closed, errs = errs, before = I.input_mode() }
end
