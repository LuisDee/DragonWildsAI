-- READ-ONLY probe (deconstruct skill, 2026-11-01): which inventory a building actor carries on the client, and
-- whether its slots are readable without opening it. Prefix `local IDS = {"BP_...", ...}` (actor short names).
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local API = inst.module.API
    local s = API.module("sense")
    local U = s and s.U
    local want = {}
    for _, id in ipairs(rawget(_G, "IDS") or IDS or {}) do want[id] = true end
    local out = {}
    for _, a in ipairs(FindAllOf("BaseBuildingActor") or {}) do
        local id = U.valid(a) and U.short(a)
        if id and want[id] then
            local e = { id = id, comps = {} }
            local g = U.try(function() return a:GetInventory() end)
            e.get_inventory = U.valid(g) and U.short(g) or false
            e.prop_inv = U.valid(U.prop(a, "InventoryComponent")) and U.short(U.prop(a, "InventoryComponent")) or false
            for _, c in ipairs(FindAllOf("InventoryComponent") or {}) do
                local ow = U.valid(c) and U.try(function() return c:GetOwner() end)
                if ow and U.valid(ow) and U.short(ow) == id then
                    local n = U.try(function() return c.ItemSlots:GetArrayNum() end)
                    local items = {}
                    pcall(function()
                        for i = 1, (n or 0) do
                            local it = c.ItemSlots[i]
                            if U.valid(it) then
                                local d = U.try(function() return it.ItemData end)
                                items[#items + 1] = { p = U.valid(d) and U.short(d) or "?", n = tonumber(U.try(function() return it.Count end)) }
                            end
                        end
                    end)
                    e.comps[#e.comps + 1] = { name = U.short(c), class = U.short(U.try(function() return c:GetClass() end)), slots = n, items = items }
                end
            end
            out[#out + 1] = e
        end
    end
    return { ok = true, actors = out }
end
