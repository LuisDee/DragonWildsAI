-- Read-only boot/watchdog probe (tools/client_boot.ps1, tools/client_watchdog.ps1, tools/client_smoke.ps1):
-- where the client is (map from the local PlayerController's path, menu screen, signed in, pawn,
-- narrative intro widget) and the brain bridge's background services. Calls only getters.
return function(log)
    local out = { t = os.time() }
    local function try(f) local ok, v = pcall(f); if ok then return v end end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        local n = x:GetFullName()
        if not n:find("Default__", 1, true) then
            local p = try(function() return x.Pawn end)
            if not pc or (p and p:IsValid()) then pc = x; out.pc_path = n end
        end
    end
    -- "BP_PlayerController_C /Game/Maps/World/L_World.L_World:PersistentLevel.BP_PlayerController_C_..."
    out.map = out.pc_path and out.pc_path:match("([%w_]+)%.[%w_]+:PersistentLevel") or nil
    if pc then
        local pawn = try(function() return pc.Pawn end)
        if pawn and pawn:IsValid() then
            out.pawn = pawn:GetFullName():match("([%w_]+)$")
            local l = try(function() return pawn:K2_GetActorLocation() end)
            if l then out.pos_m = { math.floor(l.X) / 100, math.floor(l.Y) / 100, math.floor(l.Z) / 100 } end
            out.health = try(function() return pawn.HealthComponent:GetAuthoritativeHealth() end)
        end
    end
    local api = FindFirstOf("MainMenuUIAPI")
    if api and api:IsValid() then out.screen = try(function() return tonumber(tostring(api:GetCurrentScreenType())) end) end
    local mm = FindFirstOf("DomMatchmakerSubsystem")
    if mm and mm:IsValid() then out.logged_in = try(function() return mm:IsUserLoggedIn() end) end
    out.intro_widgets = 0
    for _, w in ipairs(FindAllOf("NarrativeIntroWidget") or {}) do
        local n = w:GetFullName()
        if not n:find("Default__", 1, true) and not n:find("WidgetTree", 1, true) then out.intro_widgets = out.intro_widgets + 1 end
    end
    local inst = rawget(_G, "__dwc_bridge")
    if inst then
        local st = try(inst.status)
        if type(st) == "table" then
            out.bridge = { running = true, started = st.started, action = st.action, services = {} }
            if type(st.services) == "table" then
                for name, s in pairs(st.services) do
                    out.bridge.services[name] = { state = s.state, starts = s.starts, detail = s.detail }
                end
            else
                out.bridge.services_off = tostring(st.services)
            end
        end
    else
        out.bridge = { running = false }
    end
    return out
end
