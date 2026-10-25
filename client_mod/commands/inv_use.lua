-- Use (eat/drink) an item by name via the game's use path (edit WHAT; inventory.lua). Also reports the item data class.
local WHAT = "Pumpkin Spice Infusion"
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local U = I.U
    local cls
    local pc = I.pc()
    pcall(function()
        local arr = pc.InventoryComponent.ItemSlots
        for i = 1, arr:GetArrayNum() do
            local it = arr[i]
            if U.valid(it) and U.str(it.ItemData.Name) == WHAT then cls = U.class_name(it.ItemData) end
        end
    end)
    local r = I.use(log, WHAT)
    r.data_class = cls
    return r
end
