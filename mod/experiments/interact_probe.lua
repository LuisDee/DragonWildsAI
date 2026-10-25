-- READ-ONLY probe for ground gatherables (sticks, stones, plants, mushrooms: ABaseInteractableResource,
-- e.g. BP_Spawner_AshBranch_0x_C / BP_Spawner_Stone_C) and other interactables near the puppet, to pick
-- the safest server-side grant route for the puppet (which has no PlayerController inventory).
--   debug_run {module="interact_probe", args={radius_m=15, max=8}}
-- Reads: class, ItemData (+ Name, MaxStackSize), ItemDropComponent.ItemsToDrop (min/max/item),
-- ResourceState fields, IsResourceAvailable(), RespawnComponent quantity, the interaction component's
-- prompt/type/distance, PlayerHookToTriggerWhenMadeUnavailableDueToInteraction, FoliageDepictable.
-- Also the generic look (body/sense.lua) for comparison. No calls that change state.
local U = require("body.util")
local M = {}

local function root()
    local dc = package.loaded["debug_cmds"]
    local d = dc and dc.dirs and dc.dirs[1]
    return d and d:gsub("[/\\]scripts$", "") or nil
end

local function drops(comp)
    local out = {}
    pcall(function()
        comp.ItemsToDrop:ForEach(function(_, e)
            local d = U.try(function() return e:get() end) or e
            local sp = U.try(function() return d.ItemDataClass end)
            out[#out + 1] = { item = U.str(U.try(function() return sp:GetObjectID():GetAssetPathName() end)),
                              min = U.try(function() return d.MinToDrop end), max = U.try(function() return d.MaxToDrop end) }
        end)
    end)
    return out
end

function M.run(log, args)
    args = args or {}
    local _, puppets = U.split_pawns()
    local p = puppets[1] or (U.split_pawns())[1]
    local origin = U.loc(p)
    if not origin then return { ok = false, err = "no puppet or player" } end
    local r = (args.radius_m or 15) * 100
    local out = {}
    for _, a in ipairs(U.find_all("BaseInteractableResource", { skip_defaults = true })) do
        local d = U.dist(origin, U.loc(a))
        if d <= r and #out < (args.max or 8) then
            local data = U.try(function() return a.ItemData end)
            local ic = U.try(function() return a.InteractionComponent end)
            local rs = U.try(function() return a.ResourceState end)
            local hook = U.try(function() return a.PlayerHookToTriggerWhenMadeUnavailableDueToInteraction end)
            out[#out + 1] = {
                id = U.short(a), class = U.class_word(a), dist_m = U.cm_to_m(d),
                item = U.path_of(data), name = U.str(U.try(function() return data.Name end)),
                max_stack = U.try(function() return data.MaxStackSize end),
                drops = drops(U.try(function() return a.ItemDropComponent end)),
                available = U.try(function() return a:IsResourceAvailable() end),
                state = rs and { available = U.try(function() return rs.bIsAvailable end), raw = tostring(rs) } or nil,
                respawn = { avail = U.try(function() return a.RespawnComponent:GetQuantityAvailable() end),
                            max = U.try(function() return a.RespawnComponent:GetMaxResources() end) },
                prompt = U.str(U.try(function() return ic.InteractionPrompt end)),
                itype = U.try(function() return ic.InteractionType end), idist = U.try(function() return ic.InteractionDistance end),
                player_hook = U.fullname(hook),
                foliage = U.class_word(U.try(function() return a.FoliageDepictableComponent end)),
            }
        end
    end
    local look
    if args.look ~= false and root() then
        local ok, sense = pcall(function() return assert(loadfile(root() .. "/body/sense.lua"))() end)
        if ok then look = (sense.look({ origin = origin, radius_cm = r, about = args.about, max = args.max or 8 })) end
    end
    local res = { origin = U.to_wire(origin), gatherables = out, look = look }
    log.event("interact_probe", res)
    return res
end

return M
