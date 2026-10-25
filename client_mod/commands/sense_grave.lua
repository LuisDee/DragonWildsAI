-- Find gravestones Claude's client can see: class, position, owner, contents, access (read-only).
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local U = S.U
    local pc, me = S.local_pc(), S.local_pawn()
    local here = U.loc(me)
    local out = { me = U.to_wire(here), graves = {} }
    for _, g in ipairs(U.find_all("Gravestone", { skip_defaults = true })) do
        local at = U.loc(g)
        local d = { id = U.short(g), class = U.class_word(g), position = U.to_wire(at), distance = U.cm_to_m(U.dist(here, at)) }
        d.name = U.str(U.try(function() return g.DisplayName end))
        d.can_access = U.try(function() return g:CanPlayerAccessGravestone(pc) end)
        local guid = U.try(function() return g:GetOwningCharacterGuid() end)
        d.owner_guid = guid and (U.guid_hex(guid) or U.guid_hex(U.try(function() return guid.Guid end))) or nil
        local ic = U.try(function() return g.InteractionComponent end)
        d.prompt = U.str(U.try(function() return ic.InteractionPrompt end))
        local inv = U.try(function() return g:GetInventory() end)
        d.items = {}
        if U.valid(inv) then
            d.inventory = U.class_word(inv)
            pcall(function()
                local arr = inv.ItemSlots
                for i = 1, arr:GetArrayNum() do
                    local it = arr[i]
                    if U.valid(it) then local e = I.describe_item(it); d.items[#d.items + 1] = (e.name or "?") .. " x" .. tostring(e.count) end
                end
            end)
        end
        out.graves[#out.graves + 1] = d
    end
    local mine = U.try(function() return pc.PlayerState.OwnerGuid.CharacterGuid end)
    out.my_character_guid = mine and U.guid_hex(mine) or nil
    local c = S.census(log, { radius_m = 60, max = 10, kinds = { creatures = true, players = true } })
    out.creatures, out.players = c.creatures, c.players
    return out
end
