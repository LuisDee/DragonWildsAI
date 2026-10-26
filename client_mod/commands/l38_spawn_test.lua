-- BUGS L38 (dev, cosmetic only): call the SAME UNiagaraFunctionLibrary::SpawnSystemAttached the pawn's
-- AddNiagaraSystemAttachedWithLocalTag calls (NS_SoulScorge_PlayerEffect_Buildup on Mesh/spine_03,
-- KeepRelativeOffset, bAutoDestroy=false, bAutoActivate=true, no pooling), once with bPreCullCheck=true
-- (what the game passes) and once false; report what each returned and destroy what was created.
-- Does NOT touch LocalFX. Client-local component only (nothing replicates).
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local sys
    pawn.TaggedLocalNiagaraSystems:ForEach(function(k, v) sys = v:get().System end)
    if not U.valid(sys) then return { ok = false, reason = "no system" } end
    local NFL = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    local out = { ok = true, system = sys:GetFullName(), mesh = U.short(pawn.Mesh) }
    for _, pre in ipairs({ true, false }) do
        local ok, c = pcall(function()
            return NFL:SpawnSystemAttached(sys, pawn.Mesh, FName("spine_03"), { X = 0, Y = 0, Z = 0 },
                { Pitch = 0, Yaw = 0, Roll = 0 }, 0, false, true, 0, pre)
        end)
        local key = pre and "precull_true" or "precull_false"
        out[key] = (not ok) and ("error " .. tostring(c)) or (U.valid(c) and c:GetFullName() or "NULL")
        if ok and U.valid(c) then pcall(function() c:DestroyComponent(false) end) end
    end
    return out
end
