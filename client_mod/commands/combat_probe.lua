-- READ-ONLY combat probe on Claude's client (combat.lua discovery): the pawn's combat input actions
-- (PlayerInputBufferInputActions, lock-on, evade), their value types and triggers, rotation settings,
-- power level, special charge, stamina, and the nearest creatures' damage affinities. No input is
-- injected, nothing is written. Short (well under 100 ms).
return function(log)
    local ROOT = "C:/gameserver"
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    local out = {}
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local function ia(a)
        if not U.valid(a) then return nil end
        local d = { name = U.short(a), value_type = U.try(function() return a.ValueType end),
                    consume = U.try(function() return a.bConsumeInput end), triggers = {}, modifiers = {} }
        pcall(function() a.Triggers:ForEach(function(_, t) d.triggers[#d.triggers + 1] = U.class_word(t:get()) end) end)
        pcall(function() a.Modifiers:ForEach(function(_, t) d.modifiers[#d.modifiers + 1] = U.class_word(t:get()) end) end)
        return d
    end
    local acts = U.try(function() return pawn.PlayerInputBufferInputActions end)
    out.buffer_actions = {}
    for _, k in ipairs({ "PrimaryAction", "SecondaryAction", "SpecialAction", "EvadeAction", "MountAction", "MovementAction" }) do
        out.buffer_actions[k] = ia(U.try(function() return acts[k] end))
    end
    local lo = U.try(function() return pawn.LockOnTargetingComponent end)
    if U.valid(lo) then
        out.lock_on = { comp = nm(lo), toggle = ia(U.try(function() return lo.ToggleLockOnInput end)),
                        switch = nm(U.try(function() return lo.SwitchTargetInput end)),
                        max_dist = U.try(function() return lo.MaxTargetDistance end),
                        trace_dist = U.try(function() return lo.TraceDistance end),
                        trace_radius = U.try(function() return lo.TraceRadius end),
                        screen_tol = U.try(function() return lo.ScreenSpaceAngleTolerance end),
                        camera_actor = nm(U.try(function() return lo.LockOnCameraActor end)),
                        widget = nm(U.try(function() return lo.TargetingWidgetInstance end)),
                        pc = nm(U.try(function() return lo.PlayerController end)) }
    end
    -- components by family, owned by the pawn
    local me = U.short(pawn)
    local function mine(cls)
        for _, c in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local o = U.try(function() return c:GetOwner() end)
            if U.valid(o) and U.short(o) == me then return c end
        end
    end
    local ev = mine("PlayerEvadeComponent")
    if ev then out.evade = { comp = nm(ev), input = nm(U.try(function() return ev.InputAction end)),
                             evading = U.try(function() return ev:IsEvading() end), enabled = U.try(function() return ev:IsEvadeEnabled() end) } end
    local bl = mine("PlayerBlockingComponent")
    if bl then out.block = { comp = nm(bl), angle = U.try(function() return bl.BlockingAngle end),
                             parry_window = U.try(function() return bl.ParryWindowLength end),
                             min_dur = U.try(function() return bl.MinimumBlockDuration end),
                             bare = U.try(function() return bl.BareHandsBlockingDamageNegation end) } end
    local at = mine("PlayerMeleeAttackComponent") or mine("PlayerAttackComponent")
    if at then
        out.attack = { comp = nm(at), class = U.class_word(at), buffering = U.try(function() return at.InputBufferingDuration end), early_out = {} }
        pcall(function() at.EarlyOutActions:ForEach(function(_, a) out.attack.early_out[#out.attack.early_out + 1] = nm(a:get()) end) end)
        pcall(function() out.attack.aim_angle = at.MaximumAngleAimAssist; out.attack.aim_radius = at.ScreenSpaceRadius end)
    end
    local sc = U.try(function() return pawn.SpecialChargeComponent end) or mine("SpecialChargeComponent")
    if U.valid(sc) then out.special = { charge = U.try(function() return sc:GetSpecialCharge() end), max = U.try(function() return sc:GetMaxSpecialCharge() end) } end
    local st = U.try(function() return pawn.StaminaComponent end)
    if U.valid(st) then out.stamina = { U.try(function() return st:GetStamina() end), U.try(function() return st:GetMaxStamina() end) } end
    out.rotation = { use_ctrl_yaw = U.try(function() return pawn.bUseControllerRotationYaw end),
                     orient_to_move = U.try(function() return pawn.CharacterMovement.bOrientRotationToMovement end),
                     ctrl_desired = U.try(function() return pawn.CharacterMovement.bUseControllerDesiredRotation end),
                     rot_rate_yaw = U.try(function() return pawn.CharacterMovement.RotationRate.Yaw end) }
    out.power_level = U.try(function() return pawn:BP_GetPowerLevel() end)
    local lib = U.find_object("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    out.equip_power_level = lib and U.try(function() return lib:GetCurrentEquipmentPowerLevel(pc) end)
    out.cam_mgr = nm(U.try(function() return pc.PlayerCameraManager end))
    -- nearest creatures: power level, hp, archetype, affinities
    out.creatures = {}
    local origin = U.loc(pawn)
    local list = {}
    for _, a in ipairs(U.find_all("DominionAICharacter", { skip_defaults = true })) do
        local p = U.loc(a)
        if p then list[#list + 1] = { a = a, d = U.dist(origin, p) } end
    end
    table.sort(list, function(x, y) return x.d < y.d end)
    for i = 1, math.min(4, #list) do
        local a = list[i].a
        local data = U.try(function() return a.LoadedData end)
        local c = { id = U.short(a), d_m = math.floor(list[i].d) / 100, name = U.str(U.try(function() return data.AIName end)),
                    pl = U.try(function() return a.PowerLevel end), pl_fn = U.try(function() return a:GetAIPowerLevel() end),
                    hp = U.health(a), arch = U.try(function() return data.Archetype end),
                    alert = U.try(function() return a.CurrentAlertnessState end), aff = {}, immune = {} }
        pcall(function()
            a.AIAttributesComponent.DamageTypeAffinities:ForEach(function(k, v)
                c.aff[#c.aff + 1] = tostring(U.str(U.try(function() return k:get().TagName end))) .. "=" .. tostring(U.try(function() return v:get() end))
            end)
        end)
        local ac = U.try(function() return a.AiAttackComponent end)
        c.attack_comp = nm(ac)
        out.creatures[#out.creatures + 1] = c
    end
    return out
end
