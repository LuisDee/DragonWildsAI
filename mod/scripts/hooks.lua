-- Discovery hooks: log UFunction calls (with params) so Claude can read what the server
-- saw when Luis acts in game. Each entry is registered with pcall; a missing function
-- is logged, not fatal. Fill PENDING entries in from the reflection dump.
local M = {}

-- Readable description of a hook parameter (RemoteUnrealParam).
local function describe(param)
    local ok, v = pcall(function() return param:get() end)
    if not ok then return "<unreadable>" end
    if type(v) == "userdata" then
        local ok2, name = pcall(function() return v:GetFullName() end)
        if ok2 and name then return name end
        local ok3, s = pcall(function() return v:ToString() end) -- FString/FText/FName
        if ok3 and s then return s end
    end
    return tostring(v)
end

-- Known engine functions (exist at startup). ClientRestart fires when a player's pawn is
-- (re)possessed, i.e. when Luis joins or respawns: the Phase 1 "he got in" signal.
M.HOOKS = {
    { path = "/Script/Engine.PlayerController:ClientRestart", tag = "player_restart" },
}

-- Candidates from the dump go here, e.g.
-- { path = "/Script/Dominion.<Class>:<ServerPickupFn>", tag = "item_pickup" },
-- { path = "/Script/Dominion.<Class>:<ServerChatFn>", tag = "chat" },
M.PENDING = {}

local function register_one(h, log)
    local ok, pre_or_err = pcall(RegisterHook, h.path, function(ctx, ...)
        local params = {}
        for i, p in ipairs({ ... }) do params[i] = describe(p) end
        log.event("hook", { tag = h.tag, fn = h.path, self = describe(ctx), params = params })
    end)
    log.event("hook_registered", { tag = h.tag, fn = h.path, ok = ok, err = (not ok) and tostring(pre_or_err) or nil })
end

function M.register(log)
    for _, h in ipairs(M.HOOKS) do register_one(h, log) end
    -- Game classes may load after the mod; register the rest once the world is up.
    ExecuteInGameThreadWithDelay(30000, function()
        for _, h in ipairs(M.PENDING) do register_one(h, log) end
    end)
end

return M
