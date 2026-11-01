-- Read-only: what Claude's client can read on a player's summoned friend (KalphiteFriend) vs a wild creature.
return function(log)
    local out = {}
    local ok, actors = pcall(FindAllOf, "DominionAICharacter")
    if not ok or type(actors) ~= "table" then return { ok = false, err = "census" } end
    for _, a in ipairs(actors) do
        local okn, fn = pcall(function() return a:GetFullName() end)
        if okn and fn and not fn:find("Default__", 1, true) and (fn:find("Kalphite", 1, true) or fn:find("GiantRat", 1, true)) then
            local r = { name = fn:match("([%w_]+)$") }
            local function try(k, f) local o, v = pcall(f); r[k] = o and tostring(v) or ("ERR " .. tostring(v):sub(1, 60)) end
            try("IsFollower", function() return a:IsFollower() end)
            try("IsConfused", function() return a:IsConfused() end)
            try("alert", function() return a.CurrentAlertnessState end)
            try("pl", function() return a.PowerLevel end)
            try("bIsFollower", function() return a.bIsFollower end)
            try("FollowerComponent", function() return a.FollowerComponent and a.FollowerComponent:IsValid() end)
            try("team", function() return a:GetGenericTeamId().TeamID end)
            try("ctrl", function() local c = a:GetController(); return c and c:IsValid() and c:GetFullName() end)
            try("owner", function() local o = a:GetOwner(); return o and o:IsValid() and o:GetFullName() end)
            try("instigator", function() local o = a:GetInstigator(); return o and o:IsValid() and o:GetFullName() end)
            out[#out + 1] = r
            if #out >= 6 then break end
        end
    end
    return { ok = true, rows = out }
end
