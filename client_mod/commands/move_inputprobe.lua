-- Read-only: Enhanced Input subsystem, sprint component and input actions on Claude's client.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc and pc.Pawn
    local out = {}
    local function nm(o) local ok, n = pcall(function() return o:GetFullName() end); return ok and n or tostring(o) end
    local subs = FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}
    out.subsystems = {}
    for _, s in ipairs(subs) do out.subsystems[#out.subsystems + 1] = nm(s) end
    local sc = pawn and pawn.SprintComponent
    out.sprint_comp = sc and nm(sc)
    if sc and sc:IsValid() then
        out.sprint_action = nm(sc.SprintInputAction)
        out.is_sprinting = tostring(sc:IsSprinting())
        out.sprint_enabled = tostring(sc:IsSprintEnabled())
        out.min_vel = sc.MinimumVelocityRequired
        out.min_input = sc.MinimumMovementInputRequired
    end
    out.jump_action = pawn and nm(pawn.JumpInputAction)
    out.press_to_sprint = {}
    for _, cls in ipairs({ "DominionGameUserSettings", "DominionUserSettings" }) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            local ok, v = pcall(function() return o.bPressToSprint end)
            out.press_to_sprint[#out.press_to_sprint + 1] = nm(o) .. "=" .. tostring(v)
        end
    end
    local mc = pawn and pawn.CharacterMovement
    out.move_comp = mc and nm(mc)
    if mc then
        out.max_walk = mc.MaxWalkSpeed
        out.jump_z = mc.JumpZVelocity
        out.ok_sprint_speed = pcall(function() out.sprint_speed = mc:GetSprintingMaxSpeed() end)
    end
    out.jump_max_count = pawn and pawn.JumpMaxCount
    out.jump_count = pawn and pawn.JumpCurrentCount
    return out
end
