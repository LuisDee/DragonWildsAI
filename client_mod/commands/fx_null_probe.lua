-- READ-ONLY (BUGS L38 follow-up): where the -nullrhi client holds NULL VFX components, for the live checks
-- tools/live_checks/fx_*.json. On Claude's client every Niagara spawn is NULL (DISCOVERIES "Client crash L38"),
-- so each holder below shows what the game stored and whether the code that later reads it survives.
-- Reports:
--   token, runs: one token per client process and a call counter in it; a check's delta(before.runs,
--     after.runs) >= 2 means the same process answered both (a crash + relaunch restarts the count at 1);
--   fxguard: rows left in the guarded trigger tables (0 = guarded);
--   local_fx: the player's LocalFX map (tag -> component or NULL);
--   held: every AHeldEquipmentActor's FXSourceToAppliedFX entries (source, bundle system, component or NULL);
--   status: every DominionStatusEffect instance on Claude's pawn (class, data VFX path, SpawnedVFX or NULL);
--   tag_fx: UTagActivatedFX components with active entries (owner, tag, particle components / NULLs);
--   drain: UDrainEffectManagerComponent Drain/Beam VFX (component or NULL).
-- No input, no writes besides _G.__fx_null_token / _G.__fx_null_runs.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "__fx_null_token") == nil then _G.__fx_null_token = string.format("%d-%d", os.time(), math.random(1, 1e6)) end
    local function nm(o) return U.valid(o) and U.short(o) or "NULL" end
    local function tag(k) return U.try(function() return U.str(k.TagName) end) end
    _G.__fx_null_runs = (rawget(_G, "__fx_null_runs") or 0) + 1
    local out = { ok = true, token = _G.__fx_null_token, runs = _G.__fx_null_runs, local_fx = {}, held = {}, status = {}, tag_fx = {}, drain = {} }
    local okf, F = pcall(function() return assert(loadfile("C:/gameserver/client_mod/scripts/fxguard.lua"))() end)
    if okf then
        local st = F.status()
        out.fxguard = { guarded = st.guarded, instances = {} }
        for _, r in ipairs(st.instances or {}) do out.fxguard.instances[#out.fxguard.instances + 1] = r.name .. "=" .. tostring(r.rows) end
    end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    out.pawn = U.valid(pawn) and U.short(pawn) or nil
    if U.valid(pawn) then
        pcall(function() pawn.LocalFX:ForEach(function(k, v) out.local_fx[#out.local_fx + 1] = tostring(tag(k:get())) .. "=" .. nm(v:get()) end) end)
        local ge = U.try(function() return pawn.GameplayEffectsComponent end)
        for _, fl in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
            pcall(function() ge[fl]:ForEach(function(_, e)
                local x = e:get()
                if U.valid(x) and (U.class_word(x) or ""):find("StatusEffect", 1, true) then
                    local data = U.try(function() return x.Data end)
                    local cdo = data and U.try(function() return data:GetCDO() end)
                    local vfx = cdo and U.try(function() return cdo.VFX end)
                    out.status[#out.status + 1] = { class = U.class_word(x), data = data and U.try(function() return data:GetFullName() end) or nil,
                        data_vfx = U.valid(vfx) and vfx:GetFullName() or "none", spawned_vfx = nm(U.try(function() return x.SpawnedVFX end)) }
                end
            end) end)
        end
    end
    for _, h in ipairs(U.find_all("HeldEquipmentActor", { skip_defaults = true })) do
        local row = { actor = U.short(h), owner = nm(U.try(function() return h:GetOwner() end)), fx = {} }
        pcall(function() h.FXSourceToAppliedFX:ForEach(function(k, v)
            local src, a = k:get(), v:get()
            local sys = U.try(function() return a.FXBundle.NiagaraSystem end)
            row.fx[#row.fx + 1] = { source = nm(src), bundle_system = U.valid(sys) and U.short(sys) or "none",
                                    niagara = nm(U.try(function() return a.NiagaraComponent end)), audio = nm(U.try(function() return a.AudioComponent end)) }
        end) end)
        out.held[#out.held + 1] = row
    end
    for _, c in ipairs(U.find_all("TagActivatedFX", { skip_defaults = true })) do
        local rows = {}
        pcall(function() c.ActiveFXMap:ForEach(function(k, v)
            local a, comps, nulls = v:get(), 0, 0
            pcall(function() a.ParticleSystems:ForEach(function(_, p) if U.valid(p:get()) then comps = comps + 1 else nulls = nulls + 1 end end) end)
            rows[#rows + 1] = { tag = tag(k:get()), components = comps, nulls = nulls }
        end) end)
        if #rows > 0 then out.tag_fx[#out.tag_fx + 1] = { owner = nm(U.try(function() return c:GetOwner() end)), active = rows } end
    end
    for _, d in ipairs(U.find_all("DrainEffectManagerComponent", { skip_defaults = true })) do
        out.drain[#out.drain + 1] = { owner = nm(U.try(function() return d:GetOwner() end)),
            drain = nm(U.try(function() return d.DrainVFX_NiagaraComponent end)), beam = nm(U.try(function() return d.BeamVFX_NiagaraComponent end)) }
    end
    return out
end
