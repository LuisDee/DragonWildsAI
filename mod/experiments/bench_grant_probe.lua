-- Eval agent experiment (DEV server only): does InventoryComponent:AddItemByData grant an item server-side?
-- CLAUDE.md principle 4: no struct is built in Lua. The FGameplayTagContainer argument is a COPY of a live, empty
-- container read from an existing UItem in the same inventory (UItem.GameplayTags). If none is empty, nothing is called.
--   debug_run {"module":"bench_grant_probe","args":{"character_guid":"...","path":"/Game/.../ITEM_X.ITEM_X","count":1}}
local M = {}

function M.run(log, args)
    args = args or {}
    if os.getenv("DW_SERVER_ROLE") ~= "dev" then return { ok = false, error = "not_dev_server" } end
    local src = debug.getinfo(1, "S").source
    local root = (src:match("^@(.*)[/\\][Ee]xperiments[/\\]bench_grant_probe%.lua$") or "."):gsub("\\", "/")
    local U = assert(loadfile(root .. "/body/util.lua"))()
    local target
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        local ps = U.try(function() return p.PlayerState end)
        if ps and U.try(function() return U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid) end) == args.character_guid then target = p end
    end
    if not target then return { ok = false, error = "character_not_found" } end
    local pc = U.controller_of(target)
    local inv = U.try(function() return pc.InventoryComponent end)
    if not U.valid(inv) then return { ok = false, error = "no_inventory" } end
    local data = U.find_object(tostring(args.path or ""))
    if not U.valid(data) then return { ok = false, error = "item_data_not_loaded", path = args.path } end
    -- a live empty tag container to copy (principle 4)
    local tags, from
    pcall(function()
        inv.ItemSlots:ForEach(function(_, e)
            local it = U.try(function() return e:get() end) or e
            if tags == nil and U.valid(it) then
                local t = U.try(function() return it.GameplayTags end)
                local n = t and U.try(function() return #t.GameplayTags end)
                if t and n == 0 then tags, from = t, U.short(it) end
            end
        end)
    end)
    if not tags then return { ok = false, error = "no_live_empty_tag_container" } end
    local before = U.try(function() return inv:GetNumItemsByData(data) end)
    if args.dry then return { ok = true, dry = true, before = before, tags_from = from } end
    local ok, err = pcall(function() inv:AddItemByData(data, math.floor(tonumber(args.count) or 1), 100.0, tags) end)
    local after = U.try(function() return inv:GetNumItemsByData(data) end)
    return { ok = ok, error = (not ok) and tostring(err) or nil, before = before, after = after, tags_from = from }
end

return M
