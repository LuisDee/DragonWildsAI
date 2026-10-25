-- Discovery hooks: log UFunction calls (with params) so Claude can read what the server
-- saw when Luis acts in game. Each entry is registered with pcall; a missing function
-- is logged, not fatal. Fill PENDING entries in from the reflection dump.
local M = {}

-- Readable description of a hook parameter (RemoteUnrealParam).
local function describe(param)
    local ok, v = pcall(function() return param:get() end)
    if not ok then return "<unreadable>" end
    if type(v) == "userdata" then
        local ok2, name = pcall(function() return v:GetFullName() end)
        if ok2 and name then return name end
        local ok3, s = pcall(function() return v:ToString() end) -- FString/FText/FName
        if ok3 and s then return s end
    end
    return tostring(v)
end

-- Known engine functions (exist at startup). ClientRestart fires when a player's pawn is
-- (re)possessed, i.e. when Luis joins or respawns: the Phase 1 "he got in" signal.
M.HOOKS = {
    { path = "/Script/Engine.PlayerController:ClientRestart", tag = "player_restart" },
}

-- Candidates from the build 26161880 dump (docs/research/2026-10-25-dump-chat-inventory.md).
-- Every path exists verbatim in UE4SS_ObjectDump.txt (OD:<line>). None is a tick or movement
-- function: each fires once per player action (RPC), per delegate broadcast, or per reflected call.
-- Note: UE4SS hooks fire on reflected calls only (RPCs, BP calls, dynamic delegates); a direct
-- C++ call bypasses them, so some of these may stay silent. Client_* RPCs are not hooked:
-- they do not execute on the dedicated server.
M.PENDING = {
    -- CHAT -------------------------------------------------------------------------------
    -- Client -> server chat RPC (Server, Reliable, WithValidation). Params: FChatMessageData
    -- {SenderData, MessageBody}, FChatPlayerFilterData. Fires once per message sent. OD:45120
    { path = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage", tag = "chat",
      -- FChatMessageData { SenderData: FChatPlayerSenderData { ..., PlayerId: int32 }, MessageBody: FString }
      extract = function(params)
          local msg = params[1]:get()
          return { text = msg.MessageBody:ToString(), player_id = msg.SenderData.PlayerId }
      end },
    -- Client -> server tag-based player event (FChatPlayerEventData). Rare (join/leave/death style). OD:45118
    { path = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendPlayerEvent", tag = "chat_event" },

    -- INTERACT ---------------------------------------------------------------------------
    -- The generic "press E" RPC (Server, Reliable): InteractionComponent, Collider,
    -- bIsSecondaryInteraction, bIsRelease. Fires on press and on release only. OD:64357
    { path = "/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction", tag = "interact" },
    -- Server's acceptance of the request (NetMulticast, so it runs on the server too). Once per accepted interaction. OD:64362
    { path = "/Script/Dominion.PlayerInteractionManager:Multicast_AcknowledgeInteractionRequest", tag = "interact" },

    -- ITEM PICKUP ------------------------------------------------------------------------
    -- Dropped/spawned world item picked up (delegate handler, Interactee = player character). OD:66888
    { path = "/Script/Dominion.RuntimeSpawnedWorldItem:HandleInteraction", tag = "item_pickup" },
    -- Gatherable/harvestable ground resources (sticks, stones, plants; foliage converts to these). OD:48310
    { path = "/Script/Dominion.BaseInteractableResource:OnInteraction", tag = "item_pickup" },
    -- Resource grants its items (returns bool); fires only if called via reflection. Once per gather. OD:48320
    { path = "/Script/Dominion.BaseInteractableResource:DropItems", tag = "item_pickup" },
    -- Blueprint bound event on the BP gatherable (script function, so it should fire). Once per gather. OD:264010
    { path = "/Game/Gameplay/World/Spawners/GatherableResources/BP_BaseGatherableResource.BP_BaseGatherableResource_C:BndEvt__BP_Spawner_Potato_InteractionComponent_K2Node_ComponentBoundEvent_0_OnInteraction__DelegateSignature", tag = "item_pickup" },

    -- INVENTORY ADD ----------------------------------------------------------------------
    -- PC handler for OnNewLogEvent of the player's log-inventory: one call per add/remove/move;
    -- the LogEvent class (InventoryLogEventAddedItem etc.) says which. OD:72912
    { path = "/Script/Dominion.DominionPlayerController:OnNewInventoryChangedLogEvent", tag = "inventory_add" },
    -- Inventory add helpers (BlueprintCallable, return bool); fire only on BP/reflected calls. OD:58849, OD:58855, OD:58838
    { path = "/Script/Dominion.InventoryComponent:AddItemByData", tag = "inventory_add" },
    { path = "/Script/Dominion.InventoryComponent:AddItem", tag = "inventory_add" },
    { path = "/Script/Dominion.InventoryComponent:AddItems", tag = "inventory_add" },

    -- HARVEST (trees/rocks): delegate-bound health-changed handler on destructibles; fires per hit,
    -- not per tick (world actors do not regenerate). OD:52377
    { path = "/Script/Dominion.DestructibleWorldActor:OnHealthChanged", tag = "harvest_hit" },
}

local function describe_all(raw)
    local params = {}
    for i, p in ipairs(raw) do params[i] = describe(p) end
    return params
end

-- Entries with `extract = function(params) -> fields` (for struct params, where describe()
-- would only give a name) log just the extracted fields, which is cheaper on the game thread;
-- the raw params are described only if extraction fails. Entries without one log every param.
local function register_one(h, log, handlers)
    local ok, pre_or_err = pcall(RegisterHook, h.path, function(ctx, ...)
        local raw = { ... }
        if not h.extract then
            log.event("hook", { tag = h.tag, fn = h.path, self = describe(ctx), params = describe_all(raw) })
            return
        end
        local ok_x, fields = pcall(h.extract, raw)
        if not (ok_x and fields) then
            log.event("hook", { tag = h.tag, fn = h.path, self = describe(ctx), params = describe_all(raw),
                                fields = { extract_error = tostring(fields) } })
            return
        end
        log.event("hook", { tag = h.tag, fn = h.path, self = describe(ctx), fields = fields })
        local handler = handlers[h.tag]
        if handler then pcall(handler, fields, ctx) end
    end)
    log.event("hook_registered", { tag = h.tag, fn = h.path, ok = ok, err = (not ok) and tostring(pre_or_err) or nil })
end

-- handlers: optional { [tag] = fn(fields, ctx) } called after a hook with an extractor fires.
function M.register(log, handlers)
    handlers = handlers or {}
    for _, h in ipairs(M.HOOKS) do register_one(h, log, handlers) end
    -- Game classes may load after the mod; register the rest once the world is up.
    ExecuteInGameThreadWithDelay(30000, function()
        for _, h in ipairs(M.PENDING) do register_one(h, log, handlers) end
    end)
end

return M
