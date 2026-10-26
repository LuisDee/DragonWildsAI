-- READ-ONLY (BUGS L38): Claude's pawn's tag-driven local Niagara FX. ADominionPlayerCharacter keeps
-- TaggedLocalNiagaraSystems (trigger tag -> {LocalVFXTag, System, AttachPointName}) and LocalFX
-- (LocalVFXTag -> UNiagaraComponent* spawned by AddNiagaraSystemAttachedWithLocalTag). The L38 crash is
-- RemoveNiagaraSystemWithLocalTag calling a virtual on a NULL LocalFX value. Also: current GE classes, tags.
-- No input, no writes.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local out = { ok = true, tagged = {}, local_fx = {}, ge = {}, tags = {} }
    pcall(function() pawn.TaggedLocalNiagaraSystems:ForEach(function(k, v)
        local kk, vv = k:get(), v:get()
        local sys = U.try(function() return vv.System end)
        out.tagged[#out.tagged + 1] = { trigger = U.str(kk.TagName), vfx_tag = U.str(vv.LocalVFXTag.TagName),
            system = U.valid(sys) and sys:GetFullName() or "nil", attach = U.str(vv.AttachPointName) }
    end) end)
    pcall(function() pawn.LocalFX:ForEach(function(k, v)
        local c = v:get()
        out.local_fx[#out.local_fx + 1] = { tag = U.str(k:get().TagName), comp = U.valid(c) and c:GetFullName() or "NULL" }
    end) end)
    local ge = U.try(function() return pawn.GameplayEffectsComponent end)
    for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
        pcall(function() ge[f]:ForEach(function(_, e) local x = e:get(); if U.valid(x) then out.ge[#out.ge + 1] = x:GetFullName() end end) end)
    end
    pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) out.tags[#out.tags + 1] = U.str(t:get().TagName) end) end)
    out.can_render = nil
    return out
end
