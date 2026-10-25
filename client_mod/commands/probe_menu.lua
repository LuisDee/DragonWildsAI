-- Read-only: what front-end/menu objects exist in the headless client.
return function(log)
    local out = {}
    local function names(cls, max)
        local list = {}
        local all = FindAllOf(cls)
        for i, o in ipairs(all or {}) do
            if i > (max or 5) then break end
            list[#list + 1] = o:GetFullName()
        end
        return { n = all and #all or 0, items = list }
    end
    for _, c in ipairs({ "MainMenuWorldsDirectWidget", "MainMenuWorldsScreen", "EnterIpAddressDialog",
                         "PlayerController", "GameInstance", "World", "DomUserWidget" }) do
        out[c] = names(c, 4)
    end
    return out
end
