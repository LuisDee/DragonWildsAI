-- READ-ONLY baseline before any cast: GE instances and gameplay tags on Claude's pawn, the
-- action-level triggers of the spell input actions, the world clock the cooldown map uses, and the
-- Windstep perk's unlock info vs his Agility level. Nothing injected or written.
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
    local ge = U.try(function() return pawn.GameplayEffectsComponent end)
    if not U.valid(ge) then
        for _, c in ipairs(U.find_all("DominionGameplayEffectsComponent", { skip_defaults = true })) do
            local o = U.try(function() return c:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(pawn) then ge = c end
        end
    end
    out.ge_comp = nm(ge)
    out.ge = {}
    for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
        local list = {}
        pcall(function() ge[f]:ForEach(function(_, e) local x = e:get(); list[#list + 1] = U.class_word(x) end) end)
        out.ge[f] = list
    end
    out.tags = {}
    pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) out.tags[#out.tags + 1] = U.str(t:get().TagName) end) end)
    out.windstep_tag = U.str(U.try(function() return pawn.WindstepTag.TagName end))
    local actions = {}
    for _, n in ipairs({ "UI/IA_SpellMenu", "Spellcasting/IA_Spellcasting_QuickAccess0", "Spellcasting/IA_Spellcasting_PlaceSpell",
                         "Spellcasting/IA_Spellcasting_Cancel", "SpellsMenu/IA_SpellsMenu_AcceptSelection", "SpellsMenu/IA_SpellsMenu_SelectSlot" }) do
        local short = n:match("([^/]+)$")
        local a = U.find_object("/Game/Gameplay/Inputs/Actions/" .. n .. "." .. short)
        if a then
            local d = { vt = U.try(function() return a.ValueType end), consume = U.try(function() return a.bConsumeInput end), trig = {} }
            pcall(function() a.Triggers:ForEach(function(_, t) d.trig[#d.trig + 1] = U.class_word(t:get()) end) end)
            actions[short] = d
        else
            actions[short] = "not loaded"
        end
    end
    out.actions = actions
    local gs = U.find_first("GameStateBase")
    out.server_time = gs and U.try(function() return gs:GetServerWorldTimeSeconds() end)
    -- Agility level vs the Windstep perk
    local sk = U.try(function() return pc.SkillComponent end)
    out.skills = {}
    pcall(function() sk.Skills:ForEach(function(_, s)
        local x = s:get(); local d = x.SkillData
        out.skills[U.short(d) or "?"] = U.try(function() return sk:GetSkillLevel(d) end)
    end) end)
    out.falling = U.try(function() return pawn.CharacterMovement:IsFalling() end)
    return out
end
