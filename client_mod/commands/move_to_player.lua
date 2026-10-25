-- Click-to-move for a player controller: UAIBlueprintHelperLibrary:SimpleMoveToLocation (path following
-- feeds movement input every frame, as in the top-down template). Target: the other player's position.
return function(log)
    if _G.DW_WALK then pcall(CancelDelayedAction, _G.DW_WALK); _G.DW_WALK = nil end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local me = pc.Pawn
    local target
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if p:IsValid() and p ~= me and not p:GetFullName():find("Default__") then target = p end
    end
    if not target then return { ok = false, error = "no other player" } end
    local goal = target:K2_GetActorLocation()
    local lib = StaticFindObject("/Script/AIModule.Default__AIBlueprintHelperLibrary")
    local ok, err = pcall(function() lib:SimpleMoveToLocation(pc, { X = goal.X, Y = goal.Y, Z = goal.Z }) end)
    local nav = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    local navsys = FindFirstOf("NavigationSystemV1")
    local a = me:K2_GetActorLocation()
    return { ok = ok, err = err and tostring(err), navsys = navsys and navsys:IsValid() or false,
             dist_m = math.floor(math.sqrt((a.X - goal.X) ^ 2 + (a.Y - goal.Y) ^ 2) / 100) }
end
