-- READ-ONLY: the summoned shelters near Claude: actor origin + forward, every InteractionComponent's
-- world location (the point the interaction detector must face), prompt, and Claude's distance to
-- each; plus whose spell actor it is (Claude's PlayerUtilityMagicComponent.OurSpellActors). No input.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local function m(v) return v and { math.floor(v.X) / 100, math.floor(v.Y) / 100, math.floor(v.Z) / 100 } or nil end
    local me = U.loc(pawn)
    local mine = {}
    pcall(function() pawn.PlayerUtilityMagicComponent.OurSpellActors:ForEach(function(_, e)
        local a = e:get(); if not U.valid(a) then a = U.try(function() return a:Get() end) end
        if U.valid(a) then mine[U.short(a)] = true end
    end) end)
    local out = { ok = true, me = m(me), mine = mine, shelters = {} }
    for _, a in ipairs(U.find_all("UtilitySpell", { skip_defaults = true })) do
        local p = U.loc(a)
        local d = { id = U.short(a), cls = U.class_word(a), pos = m(p), dist_m = p and math.floor(U.dist(me, p)) / 100,
                    fwd = m(U.try(function() return a:GetActorForwardVector() end)), mine = mine[U.short(a)] == true, interactions = {} }
        for _, ic in ipairs(U.find_all("InteractionComponent", { skip_defaults = true })) do
            local o = U.try(function() return ic:GetOwner() end)
            if U.valid(o) and U.short(o) == U.short(a) then
                local l = U.try(function() return ic:K2_GetComponentLocation() end)
                d.interactions[#d.interactions + 1] = { name = U.short(ic), prompt = U.str(U.try(function() return ic.InteractionPrompt end)),
                    pos = m(l), dist_m = l and math.floor(U.dist(me, l)) / 100 }
            end
        end
        out.shelters[#out.shelters + 1] = d
    end
    local det = U.try(function() return pawn.InteractableDetector end)
    out.detector_target = det and U.short(U.try(function() return det.CurrentInteractable end))
    return out
end
