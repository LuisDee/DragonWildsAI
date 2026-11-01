-- Read-only food/drink value probe (needs-options agent 2026-11-01). The game's own numbers for what each consumable
-- restores: DT_FoodSustenance (FFoodSustenance: Sustenance, DecayBuffer), DT_DrinkHydration (FDrinkHydration:
-- Hydration, DecayBuffer), DT_Toxicity_V2 (Soulscourge), DT_Wither_V2, DT_RestEndurance, joined to every LOADED
-- FoodItemData / DrinkItemData through its row handles (SustenanceRowHandle / HydrationRowHandle / ToxicityRowHandle /
-- WitherRowHandle / EnduranceRowHandle / VitalShieldRowHandle) plus AmountToHealOnConsume, Duration, ItemUsageDelay.
-- Property reads + UE4SS UDataTable:FindRow (the read pattern build.lua uses live) only; nothing is written.
-- Copy to client_io/cmd/ and queue it (client_lib.ps1 Invoke-ClientCmd). tools/gen_food_values.py merges the result.
return function(log)
    local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
    local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
    local function str(v)
        if v == nil then return nil end
        if type(v) == "string" then return v end
        local s = try(function() return v:ToString() end)
        if type(s) == "string" and s ~= "" and s ~= "None" then return s end
        return nil
    end
    local function n(v) return type(v) == "number" and v or nil end
    local P = "/Game/Gameplay/Items/Consumables/"
    local TABLES = {
        sustenance = { P .. "Food/DT_FoodSustenance.DT_FoodSustenance", { "Sustenance", "DecayBuffer" } },
        hydration = { P .. "Food/DT_DrinkHydration.DT_DrinkHydration", { "Hydration", "DecayBuffer" } },
        toxicity = { P .. "DT_Toxicity_V2.DT_Toxicity_V2", { "Toxicity" } },
        wither = { P .. "DT_Wither_V2.DT_Wither_V2", { "Wither" } },
        endurance = { P .. "Food/DT_RestEndurance.DT_RestEndurance", { "Endurance", "Rest", "RestEndurance", "Value" } },
    }
    local out = { tables = {}, items = {}, errors = {} }
    local dts = {}
    local function row_of(key, rowname)
        local dt, fields = dts[key], TABLES[key][2]
        if not (dt and rowname) then return nil end
        local okr, row = pcall(function() return dt:FindRow(rowname) end)
        if not okr or row == nil then return nil end
        local r = {}
        for _, f in ipairs(fields) do r[f] = n(try(function() return row[f] end)) end
        r.text = str(try(function() return row.StatText end))
        return r
    end
    for key, spec in pairs(TABLES) do
        local dt = try(function() return StaticFindObject(spec[1]) end)
        if valid(dt) then
            dts[key] = dt
            local t = { path = spec[1], rows = {} }
            t.row_struct = str(try(function() return dt:GetRowStruct():GetFName() end))
            local names = {}
            local okf = pcall(function()
                dt:ForEachRow(function(name, _) names[#names + 1] = str(name) or tostring(name) end)
            end)
            if not okf or #names == 0 then
                local rn = try(function() return dt:GetRowNames() end)
                if type(rn) == "table" then for _, x in ipairs(rn) do names[#names + 1] = str(x) or tostring(x) end end
            end
            t.enumerated = #names
            for _, name in ipairs(names) do t.rows[name] = row_of(key, name) end
            out.tables[key] = t
        else
            out.errors[#out.errors + 1] = key .. ": table not loaded"
        end
    end
    local FIELDS = { shield = { "VitalShield" } }
    for key, spec in pairs(TABLES) do FIELDS[key] = spec[2] end
    -- -> row name, table name, {field = number, text} read through the handle's OWN DataTable
    local function handle(data, prop, key)
        local h = try(function() return data[prop] end)
        if h == nil then return nil end
        local rn = str(try(function() return h.RowName end))
        local dt = try(function() return h.DataTable end)
        if not (rn and valid(dt)) then return rn end
        local okr, row = pcall(function() return dt:FindRow(rn) end)
        local r
        if okr and row ~= nil then
            r = {}
            for _, f in ipairs(FIELDS[key] or {}) do r[f] = n(try(function() return row[f] end)) end
            r.text = str(try(function() return row.StatText end))
        end
        return rn, str(try(function() return dt:GetFName() end)), r
    end
    local seen = {}
    local function scan(cls, kind, props)
        for _, data in ipairs(try(function() return FindAllOf(cls) end) or {}) do
            local full = valid(data) and str(try(function() return data:GetFullName() end)) or nil
            if full and not full:find("Default__", 1, true) then
                local id = full:match("%.([%w_]+)$") or full
                if not seen[id] then
                    seen[id] = true
                    local r = { kind = kind, name = str(try(function() return data.Name end)),
                                class = str(try(function() return data:GetClass():GetFName() end)),
                                heal = n(try(function() return data.AmountToHealOnConsume end)),
                                duration_s = n(try(function() return data.Duration end)),
                                usage_delay_s = n(try(function() return data.ItemUsageDelay end)),
                                use_verb = str(try(function() return data.UseVerb end)) }
                    for prop, key in pairs(props) do
                        local rn, tname, row = handle(data, prop, key)
                        if rn then
                            r[key .. "_row"] = rn
                            if tname then r[key .. "_table"] = tname end
                            if row then r[key] = row end
                        end
                    end
                    out.items[id] = r
                end
            end
        end
    end
    scan("FoodItemData", "food", { SustenanceRowHandle = "sustenance", ToxicityRowHandle = "toxicity",
                                   VitalShieldRowHandle = "shield" })
    scan("DrinkItemData", "drink", { HydrationRowHandle = "hydration", ToxicityRowHandle = "toxicity",
                                     WitherRowHandle = "wither", EnduranceRowHandle = "endurance" })
    local nfood, ndrink = 0, 0
    for _, r in pairs(out.items) do if r.kind == "food" then nfood = nfood + 1 else ndrink = ndrink + 1 end end
    out.counts = { food = nfood, drink = ndrink }
    return out
end
