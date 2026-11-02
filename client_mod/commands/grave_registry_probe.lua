-- Read-only: AGameplayObjectRegistry.Gravestones (the replicated map/compass grave markers, FGravestoneData:
-- Location, OwningCharGuid, OwningCharDisplayName, Identifier) against his own character guid. rung1 grave probe.
return function(log)
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    local inst = rawget(_G, "__dwc_bridge")
    local api = inst and inst.module and inst.module.API
    local S = api and api.module("sense")
    local reg = U.find_all("GameplayObjectRegistry", { skip_defaults = true })[1]
    if not U.valid(reg) then return { ok = false, why = "no registry" } end
    local function key(g)
        local ok, k = pcall(function()
            local i = g.InnerGuid or g
            return string.format("%d:%d:%d:%d", i.A, i.B, i.C, i.D)
        end)
        return ok and k or nil
    end
    local mine
    pcall(function() mine = key(S.local_pc():GetCharacterGuid()) end)
    local out = {}
    pcall(function()
        reg.Gravestones:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            local p = U.try(function() return { d.Location.X / 100, d.Location.Y / 100, d.Location.Z / 100 } end)
            local name = U.try(function() return d.OwningCharDisplayName:ToString() end)
            local og = key(U.try(function() return d.OwningCharGuid end))
            out[#out + 1] = { position = p, owner = name, owner_guid = og, mine = (og and mine) and og == mine or nil,
                              id = U.guid_hex and U.guid_hex(U.try(function() return d.Identifier end)) or nil }
        end)
    end)
    return { ok = true, my_guid = mine, n = #out, graves = out }
end
