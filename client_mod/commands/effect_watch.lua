-- READ-ONLY effect watcher (spells agent, T0 evidence pass): the FIRST run stores a snapshot of
-- everything a spell could change on Claude's client; the SECOND run diffs against it and writes the
-- delta, then clears. Run it once before a cast and once while the spell is active.
-- Captured: pawn GE instances (class) and gameplay tags; HUD spell-timer tags (SpellTimerUIAPI);
-- PC input mode and camera view target; held-equipment enchant data (AHeldEquipmentActor Magical/
-- Physical effect info); position, max walk speed, movement mode; every actor within 40 m (class
-- counts); the bed/rest state. No input, no writes besides _G.DW_EFFECT_WATCH.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local function nm(o) return U.valid(o) and U.short(o) or nil end
    local function cw(o) return U.valid(o) and U.class_word(o) or nil end
    local s = { ge = {}, tags = {}, timers = {}, held = {}, actors = {}, t = os.time() }
    local ge = U.try(function() return pawn.GameplayEffectsComponent end)
    for _, f in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
        pcall(function() ge[f]:ForEach(function(_, e) local x = e:get(); if U.valid(x) then s.ge[#s.ge + 1] = cw(x) end end) end)
    end
    pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) s.tags[#s.tags + 1] = U.str(t:get().TagName) end) end)
    local hud = U.find_first("HUDUISubsystem")
    local st = hud and U.try(function() return hud.SpellTimerUIAPI end)
    pcall(function() st.HUDSpellTimerByTag:ForEach(function(k, v) local kk = k:get(); s.timers[#s.timers + 1] = U.str(kk.TagName) or tostring(kk) end) end)
    s.input_mode = nm(U.try(function() return pc.CurrentInputMode end))
    s.view_target = cw(U.try(function() return pc:GetViewTarget() end))
    s.camera_mgr_target = cw(U.try(function() return pc.PlayerCameraManager.ViewTarget.Target end))
    local eq = U.try(function() return pawn.PlayerEquipmentComponent end)
    for _, side in ipairs({ "HeldEquipmentActorLeft", "HeldEquipmentActorRight" }) do
        local a = eq and U.try(function() return eq[side] end)
        if U.valid(a) then
            local m = U.try(function() return a.MagicalHeldEquipmentEffectInfo end)
            local ph = U.try(function() return a.PhysicalHeldEquipmentEffectInfo end)
            s.held[side] = { actor = cw(a), magical = m and nm(U.try(function() return m.EffectData end)),
                             physical = ph and nm(U.try(function() return ph.EffectData end)),
                             magical_exp = m and U.try(function() return m.ServerExpirationTime end) }
        end
    end
    local p = U.loc(pawn)
    s.pos = p and { p.X / 100, p.Y / 100, p.Z / 100 }
    s.walk_speed = U.try(function() return pawn.CharacterMovement.MaxWalkSpeed end)
    s.move_mode = U.try(function() return pawn.CharacterMovement.MovementMode end)
    local rc = U.try(function() return pawn.PlayerRestComponent end)
    s.resting = rc and U.try(function() return rc:IsResting() end)
    for _, a in ipairs(U.find_all("Actor", { skip_defaults = true })) do
        local q = U.loc(a)
        if q and p and U.dist(p, q) < 4000 then
            local c = cw(a) or "?"
            s.actors[c] = (s.actors[c] or 0) + 1
        end
    end
    local prev = rawget(_G, "DW_EFFECT_WATCH")
    if not prev then
        _G.DW_EFFECT_WATCH = s
        return { ok = true, stored = true, ge = s.ge, tags = s.tags, timers = s.timers, input_mode = s.input_mode, view_target = s.view_target, held = s.held }
    end
    _G.DW_EFFECT_WATCH = nil
    local function added(a, b)
        local seen, out = {}, {}
        for _, x in ipairs(a or {}) do seen[x] = (seen[x] or 0) + 1 end
        for _, x in ipairs(b or {}) do if (seen[x] or 0) > 0 then seen[x] = seen[x] - 1 else out[#out + 1] = x end end
        return out
    end
    local d = { ok = true, dt_s = s.t - prev.t, ge_added = added(prev.ge, s.ge), ge_removed = added(s.ge, prev.ge),
                tags_added = added(prev.tags, s.tags), tags_removed = added(s.tags, prev.tags),
                timers_added = added(prev.timers, s.timers), timers_now = s.timers,
                input_mode = { prev.input_mode, s.input_mode }, view_target = { prev.view_target, s.view_target },
                camera_target = { prev.camera_mgr_target, s.camera_mgr_target }, held_before = prev.held, held_now = s.held,
                walk_speed = { prev.walk_speed, s.walk_speed }, move_mode = { prev.move_mode, s.move_mode }, resting = { prev.resting, s.resting },
                moved_m = (prev.pos and s.pos) and math.floor(math.sqrt((s.pos[1] - prev.pos[1]) ^ 2 + (s.pos[2] - prev.pos[2]) ^ 2 + (s.pos[3] - prev.pos[3]) ^ 2) * 100) / 100,
                actors_added = {}, actors_removed = {} }
    for c, n in pairs(s.actors) do if n > (prev.actors[c] or 0) then d.actors_added[c] = n - (prev.actors[c] or 0) end end
    for c, n in pairs(prev.actors) do if n > (s.actors[c] or 0) then d.actors_removed[c] = n - (s.actors[c] or 0) end end
    return d
end
