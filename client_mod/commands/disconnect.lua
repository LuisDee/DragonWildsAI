-- Leave the current server back to the main menu (engine `disconnect`).
return function(log)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    ksl:ExecuteConsoleCommand(pc, "disconnect", pc)
    return { sent = true }
end
