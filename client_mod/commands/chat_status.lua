-- Read-only: chat hook counters and the chat enablement the client sees.
return function(log)
    local S = _G.DWChat
    local out = { installed = S ~= nil, counts = S and S.counts, hooks = {} }
    if S then for k in pairs(S.hooks) do out.hooks[#out.hooks + 1] = k end end
    for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
        if not pc:GetFullName():find("Default__", 1, true) then
            pcall(function() out.pc_is_chat_enabled = pc:IsChatEnabled() end)
            pcall(function() out.comp_enabled = pc.PlayerChat.bIsChatEnabled end)
        end
    end
    return out
end
