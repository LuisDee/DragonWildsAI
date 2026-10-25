-- Read-only probe of client chat objects.
return function(log)
    local out = {}
    local function nm(o) if not o then return "nil" end local ok, n = pcall(function() return o:GetFullName() end) return ok and n or "?" end
    local function valid(o) return o ~= nil and o:IsValid() end
    out.chat_widgets = {}
    for _, w in ipairs(FindAllOf("WBP_Chat_C") or {}) do out.chat_widgets[#out.chat_widgets+1] = nm(w) end
    out.opened = {}
    for _, w in ipairs(FindAllOf("OpenedChatSubWidget") or {}) do
        local e = { name = nm(w) }
        pcall(function() e.pcc = nm(w.PlayerChatComponent) end)
        pcall(function() e.box = nm(w.MessageSendBox) end)
        pcall(function() e.vis = tostring(w:IsVisible()) end)
        pcall(function() e.in_vp = tostring(w:IsInViewport()) end)
        pcall(function() if valid(w.MessageSendBox) then e.box_text = w.MessageSendBox:GetText():ToString() end end)
        out.opened[#out.opened+1] = e
    end
    out.pccs = {}
    for _, c in ipairs(FindAllOf("PlayerChatComponent") or {}) do
        local e = { name = nm(c) }
        pcall(function() e.enabled = tostring(c.bIsChatEnabled) end)
        out.pccs[#out.pccs+1] = e
    end
    out.ps = {}
    for _, ps in ipairs(FindAllOf("DominionPlayerState") or {}) do
        local n = nm(ps)
        if not n:find("Default__") then
            local e = { name = n:match("([%w_]+)$") }
            pcall(function() e.pid = ps.PlayerId end)
            pcall(function() e.pname = ps:GetPlayerName():ToString() end)
            pcall(function() e.cguid = string.format("%08X%08X%08X%08X", ps.OwnerGuid.CharacterGuid.A, ps.OwnerGuid.CharacterGuid.B, ps.OwnerGuid.CharacterGuid.C, ps.OwnerGuid.CharacterGuid.D) end)
            out.ps[#out.ps+1] = e
        end
    end
    out.hudsub = {}
    for _, s in ipairs(FindAllOf("ChatUIAPI") or {}) do out.hudsub[#out.hudsub+1] = nm(s) end
    return out
end
