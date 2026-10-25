-- READ-ONLY capture of the crafting call chain on Claude's OWN client (R2.19, live step 2): pre-hooks
-- on the crafting/processing UI handlers and the InventoryController functions they are expected to
-- reach, so one craft shows exactly which functions the UI path calls, in order, with scalar params.
-- Proves (or disproves) "CraftingUIAPI:SendCraftRequest -> InventoryController:CraftRecipe ->
-- Server_CraftRecipe" before we rely on it. Hooks only log; they never change params or call anything.
-- Generated RPC stubs go through ProcessEvent, so the Server_* pre-hooks fire on the calling client;
-- a direct C++ call of a non-RPC function (e.g. CraftRecipe from SendCraftRequest) may NOT fire.
-- ARGS (optional): {off = true} stops logging (hooks stay registered but inert; UE4SS has them per process).
-- Output: <ROOT>/client_io/events/craft_capture.jsonl
return function(log)
    local ARGS = ARGS or {}
    local st = rawget(_G, "DWCraftCapture")
    if not st then st = { hooked = {}, n = 0 }; _G.DWCraftCapture = st end
    st.on = not ARGS.off
    if ARGS.off then return { ok = true, on = false, n = st.n } end
    local path = "C:/gameserver/client_io/events/craft_capture.jsonl"
    local HOOKS = {
        "/Script/Dominion.CraftingUIAPI:SelectRecipe",
        "/Script/Dominion.CraftingUIAPI:SendCraftRequest",
        "/Script/Dominion.CraftingUIAPI:ShowCraftingUI",
        "/Script/Dominion.CraftingUIAPI:HideCraftingUI",
        "/Script/Dominion.InventoryController:CraftRecipe",
        "/Script/Dominion.InventoryController:Server_CraftRecipe",
        "/Script/Dominion.InventoryController:Client_OnCraftingResultHandler",
        "/Script/Dominion.DominionPlayerController:Client_ToggleCraftingMenu",
        "/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction",
        "/Script/Dominion.ProcessingStationUIAPI:ToggleProcessingStationStarted",
        "/Script/Dominion.ProcessingStationUIAPI:SetCurrentProcessingStation",
        "/Script/Dominion.InventoryController:ToggleProcessing",
        "/Script/Dominion.InventoryController:Server_ToggleProcessing",
        "/Script/Dominion.InventoryUIAPI:HandleSplitToExternalSlot",
        "/Script/Dominion.InventoryUIAPI:HandleExternalQuickTransfer",
        "/Script/Dominion.InventoryController:Server_SplitAndPutStack",
        "/Script/Dominion.InventoryController:Server_MoveItemBetweenInventories",
    }
    local function describe(p)
        local ok, v = pcall(function() return p:get() end)
        if not ok then return "?" end
        local t = type(v)
        if t == "number" or t == "boolean" or t == "string" then return v end
        local okn, full = pcall(function() return v:GetFullName() end)
        if okn and type(full) == "string" then return full:match("([^%.:]+)$") or full end
        local okc, n = pcall(function() return v:GetArrayNum() end)
        if okc then return "TArray[" .. tostring(n) .. "]" end
        return t
    end
    local json = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    local function write(rec)
        local f = io.open(path, "ab")
        if not f then return end
        f:write(json.encode(rec) .. "\n")
        f:close()
    end
    local armed, errors = 0, {}
    for _, fn in ipairs(HOOKS) do
        if not st.hooked[fn] then
            local ok, err = pcall(RegisterHook, fn, function(_, ...)
                local s = rawget(_G, "DWCraftCapture")
                if not (s and s.on) then return end
                s.n = s.n + 1
                local params = {}
                for i = 1, select("#", ...) do params[i] = describe((select(i, ...))) end
                write({ seq = s.n, t = os.time(), fn = fn:match(":(.+)$"), cls = fn:match("%.([%w_]+):"), params = params })
            end)
            if ok then st.hooked[fn] = true; armed = armed + 1 else errors[#errors + 1] = fn .. ": " .. tostring(err) end
        end
    end
    local n = 0
    for _ in pairs(st.hooked) do n = n + 1 end
    return { ok = true, on = true, newly_armed = armed, hooked = n, errors = errors, file = path }
end
