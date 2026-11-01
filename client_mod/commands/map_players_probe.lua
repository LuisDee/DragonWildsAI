-- Read-only probe: AGameplayObjectRegistry.PlayerCharacters on Claude's client (the map/compass player list),
-- next to his own pawn's position and every PlayerState. Property reads of live structs only.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local out = { registries = 0, rows = {}, states = {} }
    local regs = U.find_all("GameplayObjectRegistry", { skip_defaults = true })
    out.registries = #regs
    local reg = regs[1]
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then
            local p = U.try(function() return pc.Pawn end)
            out.me = { name = U.player_name(p), pos = U.to_wire(U.loc(p)) }
        end
    end
    if U.valid(reg) then
        out.reg = U.short(reg)
        pcall(function()
            reg.PlayerCharacters:ForEach(function(i, e)
                local d = U.try(function() return e:get() end) or e
                local row = { i = i }
                row.name = U.str(U.try(function() return d.OwningPlayerName end))
                local ok, x, y, z = pcall(function() return d.Location.X, d.Location.Y, d.Location.Z end)
                if ok then row.pos = { x / 100, y / 100, z / 100 } end
                row.rot = U.try(function() return d.RotationByte end)
                row.char_guid = U.guid_hex(U.try(function() return d.OwningCharacterGuid end))
                row.id = U.guid_hex(U.try(function() return d.Identifier end))
                row.color = U.try(function() local c = d.Color; return { c.R, c.G, c.B, c.A } end)
                local nid = U.try(function() return d.OwningPlayerUniqueID end)
                row.uid_type = nid and type(nid) or nil
                out.rows[#out.rows + 1] = row
            end)
        end)
    end
    for _, ps in ipairs(U.find_all("PlayerState", { skip_defaults = true })) do
        local pw = U.try(function() return ps.PawnPrivate end)
        out.states[#out.states + 1] = { name = U.str(U.try(function() return ps:GetPlayerName() end)),
            pawn = U.valid(pw) and U.short(pw) or nil, pos = U.valid(pw) and U.to_wire(U.loc(pw)) or nil }
    end
    return out
end
