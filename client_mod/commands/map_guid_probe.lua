-- Read-only: does the map registry row's OwningCharacterGuid match a PlayerState's OwnerGuid.CharacterGuid?
-- (the registry's OwningPlayerName can be masked by the name filter: "luisdeburnayb***t"). Property reads only.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local out = { rows = {}, states = {} }
    local reg = U.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    if U.valid(reg) then
        pcall(function()
            reg.PlayerCharacters:ForEach(function(i, e)
                local d = U.try(function() return e:get() end) or e
                out.rows[#out.rows + 1] = { name = U.str(U.try(function() return d.OwningPlayerName end)),
                    char = U.guid_hex(U.try(function() return d.OwningCharacterGuid.InnerGuid end)) }
            end)
        end)
    end
    for _, ps in ipairs(U.find_all("DominionPlayerState", { skip_defaults = true })) do
        local og = U.prop(ps, "OwnerGuid")
        local dn = U.prop(ps, "DisplayNameComponent")
        out.states[#out.states + 1] = { name = U.str(U.try(function() return ps:GetPlayerName() end)),
            char = U.guid_hex(U.try(function() return og.CharacterGuid.InnerGuid end)),
            display_comp = U.valid(dn) and U.short(dn) or nil,
            pawn = U.valid(U.prop(ps, "PawnPrivate")) or false }
    end
    return out
end
