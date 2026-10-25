-- READ-ONLY crafting probe (R2.19): stations near Claude typed from the recipe catalog (+ processing
-- state), his own recipe unlocks, what he can craft now, and whether the crafting UI API objects
-- exist on this headless client. Never moves, presses or calls a UI handler.
-- Uses the running bridge's services (client_bridge M.API) with a fresh loadfile of crafting.lua.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    local B = inst.module
    local C = assert(loadfile("C:/gameserver/client_mod/scripts/crafting.lua"))()
    local ctx = { api = B.API }
    local out = { ok = true }
    out.stations = C.HANDLERS.stations(log, { radius = (ARGS or {}).radius or 80 }, ctx)
    out.craftable = C.HANDLERS.recipes(log, { limit = 30 }, ctx)
    local s = B.API.module("sense")
    local U = s and s.U
    local ui = {}
    for _, cls in ipairs({ "CraftingUIAPI", "ProcessingStationUIAPI", "InventoryUIAPI" }) do
        local n, open = 0, nil
        for _, o in ipairs(U and U.find_all(cls, { skip_defaults = true }) or {}) do
            n = n + 1
            local cur = U.try(function() return cls == "CraftingUIAPI" and o.CurrentStation or o.ProcessingStationComponent end)
            if cls ~= "InventoryUIAPI" and U.valid(cur) then open = U.short(U.try(function() return cur:GetOwner() end)) end
        end
        ui[cls] = { count = n, open_station = open }
    end
    out.ui = ui
    local unl, n = C.W.unlocked(B.API)
    out.unlocked_count = n
    if unl then
        local ids = {}
        for id in pairs(unl) do ids[#ids + 1] = id end
        table.sort(ids)
        out.unlocked = ids
    end
    out.result_hook_armed = (rawget(_G, "DWCraft") or {}).hooked == true
    return out
end
