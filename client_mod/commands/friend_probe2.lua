-- Read-only: does a player's pawn on Claude's client name its follower (ADominionPlayerCharacter.Follower)?
return function(log)
    local out = {}
    local ok, ps = pcall(FindAllOf, "BP_PlayerCharacter_C")
    if not ok or type(ps) ~= "table" then return { ok = false, err = "no players" } end
    for _, p in ipairs(ps) do
        local okn, fn = pcall(function() return p:GetFullName() end)
        if okn and fn and not fn:find("Default__", 1, true) then
            local r = { pawn = fn:match("([%w_]+)$") }
            local o, f = pcall(function() return p.Follower end)
            r.follower = o and f and (pcall(function() return f:IsValid() end) and f:IsValid() and f:GetFullName():match("([%w_]+)$") or "invalid") or ("ERR " .. tostring(f):sub(1, 80))
            local o2, ps2 = pcall(function() return p.PlayerState end)
            r.player = o2 and ps2 and ps2:IsValid() and tostring(ps2:GetPlayerName()) or nil
            out[#out + 1] = r
        end
    end
    return { ok = true, rows = out }
end
