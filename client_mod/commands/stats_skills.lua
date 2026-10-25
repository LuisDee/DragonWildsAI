-- READ-ONLY: Claude's live skills as the client sees them (pc.SkillComponent, replicated from the server),
-- the XP curve, power level, perks, and whether any CachedCharacterStates actor is visible on the client.
-- No input, no movement, no writes.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local function str(v) local ok, s = pcall(function() return U.str(v) end); return ok and s or nil end
    local pc = S.local_pc()
    if not pc then return { ok = false, reason = "no local pc" } end
    local pawn = S.local_pawn(pc)
    local sc = pc.SkillComponent
    local out = { pc = U.short(pc), skills = {} }
    out.total_level = U.try(function() return sc:GetTotalSkillLevel() end)
    sc.Skills:ForEach(function(i, e)
        local s = U.try(function() return e:get() end) or e
        local d = U.try(function() return s.SkillData end)
        local r = { i = i, xp = U.try(function() return s.CurrentXP end) }
        if U.valid(d) then
            r.name = str(d.Name)
            r.pid = str(U.try(function() return d.PersistenceID end))
            r.internal = str(U.try(function() return d.InternalName end))
            r.max_level = U.try(function() return d.MaxLevel end)
            r.level = U.try(function() return sc:GetSkillLevel(d) end)
            r.total_xp = U.try(function() return sc:GetTotalXP(d) end)
            r.next_total = U.try(function() return sc:GetTotalXPNeededForNextLevel(d) end)
        end
        out.skills[#out.skills + 1] = r
    end)
    local curve = {}
    for _, L in ipairs({ 2, 3, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 99, 100 }) do
        curve[tostring(L)] = U.try(function() return sc:GetTotalXPNeededForLevel(L) end)
    end
    out.xp_for_level = curve
    if pawn then
        out.power_level = U.try(function() return pawn:BP_GetPowerLevel() end)
        local spc = U.try(function() return pc.SkillPerkComponent end) or U.try(function() return pawn.SkillPerkComponent end)
        if U.valid(spc) then
            local n = 0
            pcall(function() spc.SkillPerkRuntimeStates:ForEach(function() n = n + 1 end) end)
            out.perk_runtime_states = n
            out.double_jump_unlocked = U.try(function() return spc:IsPerkUnlocked(pawn.DoubleJumpSkillPerk) end)
        end
    end
    local caches = U.find_all("CachedCharacterStates", { skip_defaults = true }) or {}
    out.cached_states_actors_on_client = #caches
    return out
end
