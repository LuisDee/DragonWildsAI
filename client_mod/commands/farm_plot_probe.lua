-- Read-only: what the game shows a player about each farm plot in range (pure reads only; never Interact, never an RPC).
-- Per UFarmSlotComponent: its PlotTier tag, GetPlotID, the soil/harvest/disease/water/fertilize/weeds/rapid-grow reads,
-- the interaction component's prompts (the property and GetInteractionPrompt(pawn), the secondary one) and its
-- status texts, and the plot information widget's visible text blocks (the look-at panel: plant, stage, needs).
-- Output: client_io/out/farm_plot_probe.json.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local function s(v) return U.str(v) end
local function b(c, fn) local x = U.try(function() return c[fn](c) end); if x == nil then return nil end; return x == true end

local function widget_texts(w, out, depth)
    if not U.valid(w) or depth > 6 or #out > 40 then return end
    local n = U.fullname(w) or ""
    if n:match("^TextBlock ") or n:match("^RichTextBlock ") then
        local t = s(U.try(function() return w:GetText() end))
        local vis = U.try(function() return w:GetVisibility() end)
        if t and t ~= "" then out[#out + 1] = { name = U.short(w), text = t, vis = vis } end
        return
    end
    local cnt = U.try(function() return w:GetChildrenCount() end)
    if type(cnt) == "number" then
        for i = 0, math.min(cnt, 30) - 1 do widget_texts(U.try(function() return w:GetChildAt(i) end), out, depth + 1) end
    end
    local root = U.try(function() return w.WidgetTree.RootWidget end)
    if root and depth == 0 then widget_texts(root, out, depth + 1) end
end

return function(log)
    local pc = U.try(function() return FindFirstOf("PlayerController") end)
    local okp, pcs = pcall(FindAllOf, "BP_PlayerController_C")
    for _, c in ipairs(okp and pcs or {}) do if U.try(function() return c:IsLocalController() end) then pc = c end end
    local pawn = U.valid(pc) and U.try(function() return pc.Pawn end) or nil
    local me = U.valid(pawn) and U.loc(pawn) or nil
    local out = { me = me, plots = {} }
    local ok, list = pcall(FindAllOf, "FarmSlotComponent")
    for _, c in ipairs(ok and list or {}) do
        local owner = U.try(function() return c:GetOwner() end)
        if U.alive(owner) then
            local v = U.try(function() return c:K2_GetComponentLocation() end)
            local d = (me and v) and math.floor(math.sqrt((me.X - v.X) ^ 2 + (me.Y - v.Y) ^ 2) / 10 + 0.5) / 10 or nil
            if d == nil or d <= 150 then
                local r = { owner = U.short(owner), owner_class = U.class_word(owner), slot = U.try(function() return c.SlotIndex end),
                    distance_m = d, pos = v and { X = v.X, Y = v.Y, Z = v.Z } or nil,
                    plot_id = tostring(U.try(function() return c:GetPlotID() end)),
                    tier = U.str(U.try(function() return c.PlotTier.TagName end)),
                    soil = U.try(function() return c:GetSoilState() end),
                    harvestable = b(c, "CanHarvest"), diseased = b(c, "CanHealDisease"), watered = b(c, "IsFullyWatered"),
                    fertilized = b(c, "IsFullyFertilized"), weeds_grown = b(c, "AreWeedsFullyGrown"),
                    rapid_grow = b(c, "CanRapidGrow"), growth_lock = b(c, "ShouldVisualizeGrowthLock") }
                local ic = U.try(function() return c.InteractionComponent end)
                if U.valid(ic) then
                    r.prompt_prop = s(U.try(function() return ic.InteractionPrompt end))
                    r.prompt = U.valid(pawn) and s(U.try(function() return ic:GetInteractionPrompt(pawn) end)) or nil
                    r.prompt2 = s(U.try(function() return ic:GetSecondaryInteractionPrompt() end))
                    r.has_secondary = U.try(function() return ic:HasSecondaryInteraction() end)
                    r.texts = {}
                    for _, k in ipairs({ "PlotName", "PlotStatusDisplayText", "HarvestPrompt", "HealDiseasePrompt", "SeedRequiredText",
                                         "SpadeRequiredText", "CanBeWateredText", "CanBeFertilizedText", "NoWaterDisplayText",
                                         "NoCompostDisplayText", "NoPlantDisplayText", "YieldDetailsText", "DiseaseChanceDetailsText" }) do
                        r.texts[k] = s(U.try(function() return ic[k] end))
                    end
                end
                local wc = U.try(function() return c.InformationWidgetComponent end)
                if U.valid(wc) then
                    local w = U.try(function() return wc:GetWidget() end) or U.try(function() return wc:GetUserWidgetObject() end)
                    r.widget = U.fullname(w)
                    r.widget_texts = {}
                    widget_texts(w, r.widget_texts, 0)
                end
                out.plots[#out.plots + 1] = r
            end
        end
    end
    out.count = #out.plots
    return { ok = true, r = out }
end
