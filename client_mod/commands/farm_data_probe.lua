-- Read-only: the game's own farming data, from the loaded native data assets (no writes, no RPCs).
--   FarmPlantDataAsset (every crop: tier, yield, disease, harvest item, plot tags, stage cycles), its seeds
--   (SeedHeldEquipmentData -> FarmPlantData), FarmCompostData / FarmWaterData, the FarmingSettings CDO,
--   ComposterComponent instances/templates (accepted tags, output, rates), and every ItemData with CompostAmount > 0.
-- Output: client_io/out/farm_data_probe.json (data/farming_26161880.json is built from it by tools/build_farming.py).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local function s(v) return U.str(v) end
local function path(o) return U.path_of(o) end
local function num(f) local v = U.try(f); if type(v) == "number" then return v end; if type(v) == "boolean" then return v end end
local function tags(c)
    local out = {}
    pcall(function()
        c.GameplayTags:ForEach(function(_, e)
            local t = U.try(function() return e:get() end) or e
            local n = U.str(U.try(function() return t.TagName end))
            if n then out[#out + 1] = n end
        end)
    end)
    return out
end
local function tag(t) return U.str(U.try(function() return t.TagName end)) end
local function all(cls)
    local ok, list = pcall(FindAllOf, cls)
    local out = {}
    for _, o in ipairs(ok and list or {}) do
        local n = U.fullname(o) or ""
        if not n:find("Default__", 1, true) then out[#out + 1] = o end
    end
    return out
end

return function(log)
    local out = { plants = {}, seeds = {}, compost = {}, water = {}, composters = {}, compostable = {}, errors = {} }
    for _, p in ipairs(all("FarmPlantDataAsset")) do
        local r = { path = path(p), name = s(U.try(function() return p.DisplayName end)),
            tier = num(function() return p.Tier end), base_yield = num(function() return p.BaseYield end),
            disease = num(function() return p.DiseaseChance end), disease_not_preferred = num(function() return p.DiseaseChanceNotPreferred end),
            berry_bush = num(function() return p.bIsBerryBush end), harvest_xp_factor = num(function() return p.HarvestXpFactor end),
            harvest_item = path(U.try(function() return p.HarvestableItem end)),
            plantable_in = tags(U.try(function() return p.PlantableIn end)), stages = {}, stage_texts = {} }
        pcall(function()
            local sd = p.SeedDropPerHarvestableItem
            r.seed_drop = {}
            for _, k in ipairs({ "Chance", "DropChance", "Min", "Max", "MinAmount", "MaxAmount", "Amount", "Count" }) do
                local v = U.try(function() return sd[k] end)
                if type(v) == "number" then r.seed_drop[k] = v end
            end
            local it = U.try(function() return sd.Item end) or U.try(function() return sd.ItemData end)
            if it then r.seed_drop.item = path(it) end
        end)
        U.each(U.try(function() return p.StageDisplayTexts end), function(t) r.stage_texts[#r.stage_texts + 1] = s(t) end)
        U.each(U.try(function() return p.Stages end), function(st)
            r.stages[#r.stages + 1] = { path = path(st), cycles = num(function() return st.CyclesToGrow end),
                cycles_not_preferred = num(function() return st.CyclesToGrowNotPreferred end),
                disease = num(function() return st.DiseaseChance end), disease_not_preferred = num(function() return st.DiseaseChanceNotPreferred end),
                -- each stage's meshes (FFarmPlantStageVisData.Mesh): a plot's PlantMeshComponent mesh names its stage
                mesh = path(U.try(function() return st.Healthy.Mesh end)), mesh_diseased = path(U.try(function() return st.Diseased.Mesh end)),
                mesh_dead = path(U.try(function() return st.Dead.Mesh end)) }
        end)
        out.plants[#out.plants + 1] = r
    end
    for _, sd in ipairs(all("SeedHeldEquipmentData")) do
        out.seeds[#out.seeds + 1] = { path = path(sd), name = s(U.try(function() return sd.Name end)),
            plant = path(U.try(function() return sd.FarmPlantData end)) }
    end
    for _, c in ipairs(all("FarmCompostData")) do
        out.compost[#out.compost + 1] = { path = path(c), disease = num(function() return c.DiseaseChance end),
            yield = num(function() return c.YieldMultiplier end), status = s(U.try(function() return c.StatusText end)) }
    end
    for _, c in ipairs(all("FarmWaterData")) do
        out.water[#out.water + 1] = { path = path(c), disease = num(function() return c.DiseaseChance end),
            yield = num(function() return c.YieldMultiplier end), status = s(U.try(function() return c.StatusText end)) }
    end
    local fs = U.try(function() return StaticFindObject("/Script/Dominion.Default__FarmingSettings") end)
    if U.valid(fs) then
        local f = {}
        for _, k in ipairs({ "CyclePeriod", "DiseaseCycles", "WeedsCycles", "RainWaterIndex", "WaterNeededForWatering",
                             "CompostNeededForFertilizing", "DiggingChargesNeededForTilling", "PlantingGracePeriodHours",
                             "BerryBushXpReductionFactor", "YieldXpFactor", "ShovelPlantDestructionActionDuration" }) do
            f[k] = num(function() return fs[k] end)
        end
        f.GrowthTimes = {}
        U.each(U.try(function() return fs.GrowthTimes end), function(v) f.GrowthTimes[#f.GrowthTimes + 1] = v end)
        f.ShovelCategory = tag(U.try(function() return fs.ShovelCategory end))
        f.CompostItemCategory = tag(U.try(function() return fs.CompostItemCategory end))
        f.CureDiseasePotionCategory = tag(U.try(function() return fs.CureDiseasePotionCategory end))
        f.UnlockingRecipe = U.str(U.try(function() return fs.UnlockingRecipe:GetObjectID():GetAssetPathName() end))
        f.ComposterBuildingPieceData = U.str(U.try(function() return fs.ComposterBuildingPieceData:GetObjectID():GetAssetPathName() end))
        f.CompostDataRef = {}
        U.each(U.try(function() return fs.CompostDataRef end), function(v)
            f.CompostDataRef[#f.CompostDataRef + 1] = U.str(U.try(function() return v:GetObjectID():GetAssetPathName() end))
        end)
        f.WaterDataRef = {}
        U.each(U.try(function() return fs.WaterDataRef end), function(v)
            f.WaterDataRef[#f.WaterDataRef + 1] = U.str(U.try(function() return v:GetObjectID():GetAssetPathName() end))
        end)
        out.settings = f
    else
        out.errors[#out.errors + 1] = "no FarmingSettings CDO"
    end
    local okc, comps = pcall(FindAllOf, "ComposterComponent")
    for _, c in ipairs(okc and comps or {}) do
        local owner = U.try(function() return c:GetOwner() end)
        out.composters[#out.composters + 1] = { name = U.fullname(c), owner = U.short(owner),
            pos = U.valid(owner) and U.loc(owner) or nil,
            accepted = tags(U.try(function() return c.AcceptedInputItemTags end)),
            output = path(U.try(function() return c.OutputType end)),
            rate = num(function() return c.ProcessingRate end), mult = num(function() return c.CompostOutputMultiplier end),
            capacity = num(function() return c.OutputCapacity end) }
    end
    local seen = {}
    local items = {}
    for _, cls in ipairs({ "ItemData", "BuffItemData", "ConsumableItemData", "DrinkItemData", "FoodItemData", "FuelItemData",
                           "PotionItemData", "SeedHeldEquipmentData", "HeldEquipmentData", "EquipmentData", "TrinketItemData" }) do
        local oki, l = pcall(FindAllOf, cls)
        for _, it in ipairs(oki and l or {}) do items[#items + 1] = it end
    end
    for _, it in ipairs(items) do
        local n = U.fullname(it) or ""
        if not seen[n] and not n:find("Default__", 1, true) then
            seen[n] = true
            local a = num(function() return it.CompostAmount end)
            if type(a) == "number" and a > 0 then
                out.compostable[#out.compostable + 1] = { path = path(it), name = s(U.try(function() return it.Name end)), compost = a,
                    category = tag(U.try(function() return it.Category end)), filters = tags(U.try(function() return it.ItemFilterTags end)) }
            end
        end
    end
    out.counts = { plants = #out.plants, seeds = #out.seeds, compost = #out.compost, water = #out.water,
                   composters = #out.composters, compostable = #out.compostable }
    return { ok = true, r = out }
end
