-- Leave the current server back to the main menu (engine `disconnect`).
return function(log)
    -- Pause every game-thread loop (vitals, reflex, move, bridge) before the world tears down:
    -- a loop touching objects mid-teardown crashed the client (DISCOVERIES). The bridge clears it
    -- once a new pawn exists.
    _G.DW_PAUSE = true
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    ksl:ExecuteConsoleCommand(pc, "disconnect", pc)
    return { sent = true }
end
