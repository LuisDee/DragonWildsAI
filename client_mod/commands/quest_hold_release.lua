-- TEMPORARY guard for quest runs (quests agent, 2026-11-01; the movement agent's probe move/vent/mv_ventrelease.lua):
-- a human letting go of E. Every Anima Vent's InteractionComponent is InteractionType Hold, and inventory.press_interact
-- injects one frame of IA_Interact and never the release (InteractActionStop = IA_InteractHold), so a siphon roots him
-- (live 19:20Z, ClaudeQ2: xy frozen at (27668, 181294) until the client restart). One frame of the interaction
-- manager's InteractActionStop lets go. tools/quest_run.py sends it after an Anima Vent interact; remove this file and
-- that call once press_interact releases holds itself.
return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc and pc.Pawn
    local mgr = pawn and pawn.InteractionManager
    local ia = mgr and mgr.InteractActionStop
    if not (ia and ia:IsValid()) then return { ok = false, why = "no InteractActionStop" } end
    local sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
    local fn = StaticFindObject("/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction")
    if not (sub and fn) then return { ok = false, why = "no subsystem" } end
    local ok, err = pcall(function() fn(sub, ia, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
    return { ok = ok, err = (not ok) and tostring(err) or nil, action = ia:GetFullName() }
end
