-- Read-only: local player controller, pawn, position, player list (as this client sees it).
return function(log)
    local out = { players = {} }
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local n = pc:GetFullName()
        if not n:find("Default__") then
            out.pc = n:match("([%w_]+)$")
            local pawn = pc.Pawn
            if pawn and pawn:IsValid() then
                out.pawn = pawn:GetFullName():match("([%w_]+)$")
                local l = pawn:K2_GetActorLocation(); out.pos = { math.floor(l.X), math.floor(l.Y), math.floor(l.Z) }
            end
        end
    end
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        local n = ps:GetFullName()
        if not n:find("Default__") then
            local ok, name = pcall(function() return ps:GetPlayerName():ToString() end)
            out.players[#out.players + 1] = ok and name or n:match("([%w_]+)$")
        end
    end
    out.map = FindFirstOf("World") and FindFirstOf("World"):GetFullName():match("([%w_]+)$")
    return out
end
