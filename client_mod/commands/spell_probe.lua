-- READ-ONLY spell probe on Claude's client (R2.20 phase A): unlocked spells, the wheel, rune counts,
-- cooldowns, the casting input actions and the spell UI objects. No input injected, no UFunction with
-- side effects called, nothing written. Property reads plus the BlueprintPure getter
-- SpellcastingComponent:GetCurrentlySelectedSpellData().
return function(log)
    local ROOT = "C:/gameserver"
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local out = { ok = true }
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local function unwrap(e) if type(e) == "userdata" then local ok, v = pcall(function() return e:get() end); if ok and v ~= nil then return v end end; return e end
    local function each(arr, fn, cap)
        if arr == nil then return end
        local n = 0
        pcall(function() arr:ForEach(function(i, e) n = n + 1; if n > (cap or 256) then return true end; fn(unwrap(e), i) end) end)
    end
    local function ia(a)
        if not U.valid(a) then return nil end
        local d = { name = U.short(a), value_type = U.try(function() return a.ValueType end), triggers = {} }
        pcall(function() a.Triggers:ForEach(function(_, t) d.triggers[#d.triggers + 1] = U.class_word(t:get()) end) end)
        return d
    end
    local function perk_info(p)
        if not U.valid(p) then return nil end
        local r = { perk = U.short(p), name = U.str(U.try(function() return p.PerkName end)) }
        local ui = U.try(function() return p.PerkUnlockInfo end)
        if ui then
            r.level = U.try(function() return ui.RequiredSkillLevel end)
            local sk = U.try(function() return ui.AssociatedSkill end)
            r.skill = U.str(U.try(function() return sk:GetObjectID():GetAssetPathName() end)) or nm(sk)
        end
        r.desc = U.str(U.try(function() return p.PerkDescription end)) or U.str(U.try(function() return p.Description end))
        return r
    end
    local function spell_info(s)
        if not U.valid(s) then return nil end
        local r = { asset = U.short(s), name = U.str(U.try(function() return s.SpellDisplayName end)),
                    cooldown_s = U.try(function() return s.CooldownDuration end),
                    cast_type = U.try(function() return s.CastType end),
                    needs_unlocking = U.try(function() return s.bNeedsUnlocking end),
                    special_req = U.str(U.try(function() return s.SpecialRequirementsText end)),
                    perk = perk_info(U.try(function() return s.OwningPerk end)), runes = {} }
        local c = U.try(function() return s.Modules end)
        each(c and U.try(function() return c.Modules end), function(w)
            local m = U.try(function() return w.Module end)
            if U.valid(m) and (U.class_word(m) or ""):find("CostItems", 1, true) then
                each(U.try(function() return m.ItemsCostInfo end), function(ci)
                    local it = U.try(function() return ci.ItemData end)
                    r.runes[#r.runes + 1] = { item = nm(it), count = U.try(function() return ci.Count end) }
                end, 16)
            end
        end, 64)
        return r
    end

    -- SpellcastingComponent (PC): wheel + input actions
    local sc = U.try(function() return pc.SpellcastingComponent end)
    if U.valid(sc) then
        local w = { comp = nm(sc), radials = U.try(function() return sc.NumSpellRadials end),
                    per_radial = U.try(function() return sc.NumSpellSlotsPerRadial end),
                    place = ia(U.try(function() return sc.PlaceSpellInputAction end)),
                    cancel = ia(U.try(function() return sc.CancelSpellInputAction end)),
                    adjust = ia(U.try(function() return sc.AdjustSpellInputAction end)),
                    max_place_m = U.try(function() return sc.MaxDistanceFromCameraToPlaceSpell end),
                    selected = {} }
        each(U.try(function() return sc.SelectedSpells end), function(s, i)
            w.selected[#w.selected + 1] = U.valid(s) and U.short(s) or "-"
        end, 64)
        w.current = nm(U.try(function() return sc:GetCurrentlySelectedSpellData() end))
        out.wheel = w
    else
        out.wheel = { error = "no SpellcastingComponent" }
    end

    -- Unlocked spells (PC ProgressComponent.SpellsUnlocked, TSet)
    local prog = U.try(function() return pc.ProgressComponent end)
    out.unlocked = {}
    if U.valid(prog) then
        local set = U.try(function() return prog.SpellsUnlocked end)
        local ok, err = pcall(function()
            set:ForEach(function(a, b) local e = unwrap(b ~= nil and b or a); out.unlocked[#out.unlocked + 1] = spell_info(e) or tostring(e) end)
        end)
        if not ok then out.unlocked_err = tostring(err) end
    else
        out.unlocked_err = "no ProgressComponent"
    end
    out.spell_data_loaded = #U.find_all("UtilitySpellData", { skip_defaults = true })

    -- Runes carried (rune page of the inventory)
    local inv = U.try(function() return pc.InventoryComponent end)
    out.runes = {}
    each(inv and U.try(function() return inv.ItemSlots end), function(it)
        if U.valid(it) then
            local d = nm(U.try(function() return it.ItemData end)) or ""
            if d:find("Rune", 1, true) then out.runes[d] = (out.runes[d] or 0) + (U.try(function() return it.Count end) or 0) end
        end
    end, 256)

    -- Pawn magic components: preparing/cast state, cooldown map
    local um = U.try(function() return pawn.PlayerUtilityMagicComponent end)
    if U.valid(um) then
        local m = { comp = nm(um), class = U.class_word(um), last_cast = {}, spell_actor = nm(U.try(function() return um.CurrentSpellActor end)) }
        local sp = U.try(function() return um.SpellBeingPreparedOrCast end)
        if sp then
            m.preparing = {}
            for _, f in ipairs({ "SpellData", "State", "CastID", "bIsCasting", "bIsPreparing" }) do
                local v = U.try(function() return sp[f] end)
                if v ~= nil then m.preparing[f] = type(v) == "userdata" and (nm(v) or tostring(v)) or v end
            end
        end
        pcall(function() um.LastCastTimeBySpellData:ForEach(function(k, v) m.last_cast[nm(unwrap(k)) or "?"] = unwrap(v) end) end)
        local ct = U.try(function() return um.CastingTag end)
        m.casting_tag = ct and U.str(U.try(function() return ct.TagName end))
        out.utility_magic = m
    end
    local cm = U.try(function() return pawn.PlayerCombatMagicComponent end)
    out.combat_magic = U.valid(cm) and { comp = nm(cm), class = U.class_word(cm) } or nil

    -- PC input modes for spells
    out.input_modes = {}
    for _, k in ipairs({ "SpellcastingModeInputMode", "SpellPlacementModeInputMode", "SpellPlacementModeAdvancedMovementInputMode",
                         "RadialMenuInputMode", "QuickAccessRadialInputMode" }) do
        out.input_modes[k] = nm(U.try(function() return pc[k] end))
    end
    local im = U.try(function() return pc.CurrentInputMode end)
    out.current_input_mode = nm(im)

    -- UI: HUDUISubsystem.SpellcastingAPI and the live spell panel widget(s)
    local hud = U.find_first("HUDUISubsystem")
    out.ui_api = hud and nm(U.try(function() return hud.SpellcastingAPI end)) or nil
    out.panels = {}
    for _, p in ipairs(U.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        local d = { name = U.fullname(p), visible = U.try(function() return p:IsVisible() end) }
        for _, k in ipairs({ "TriggerSpellRadialInputAction", "GenericAcceptInputAction", "SwitchRadialInputAction",
                             "TriggerSpellBookInputAction", "ChangeSpellRadialLeftInputAction", "ChangeSpellRadialRightInputAction" }) do
            d[k] = ia(U.try(function() return p[k] end))
        end
        local rw = U.try(function() return p.SpellRadialWidget end)
        if U.valid(rw) then
            d.radial = { name = U.short(rw), select = ia(U.try(function() return rw.SelectSlotInputAction end)), quick = {}, slices = 0 }
            each(U.try(function() return rw.QuickAccessInputActions end), function(a) d.radial.quick[#d.radial.quick + 1] = nm(a) end, 16)
            each(U.try(function() return rw.Slices end), function() d.radial.slices = d.radial.slices + 1 end, 64)
        end
        out.panels[#out.panels + 1] = d
    end
    return out
end
