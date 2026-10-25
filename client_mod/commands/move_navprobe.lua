-- Read-only: which navigation objects exist on Claude's client, and nav-related cvars.
return function(log)
    local out = {}
    for _, c in ipairs({ "NavigationSystemV1", "RecastNavMesh", "NavigationDataChunkActor", "NavMeshBoundsVolume", "LandscapeStreamingProxy", "WorldPartitionStreamingSourceComponent" }) do
        local n = 0
        for _, o in ipairs(FindAllOf(c) or {}) do if not o:GetFullName():find("Default__") then n = n + 1 end end
        out[c] = n
    end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    for _, cv in ipairs({ "wp.Runtime.EnableServerStreaming", "ai.navigation.AllowClientSideNavigation" }) do
        local ok, v = pcall(function() return ksl:GetConsoleVariableIntValue(cv) end)
        out[cv] = ok and v or tostring(v)
    end
    local cdo = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
    out.cdo_allow_client = cdo and tostring(cdo.bAllowClientSideNavigation)
    return out
end
