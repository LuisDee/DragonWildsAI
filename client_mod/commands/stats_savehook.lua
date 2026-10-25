-- READ-ONLY observer: post-hooks on the server->client save RPCs of DominionPlayerControllerBase
-- (Client_SaveToDisk, Client_LoadFromDisk, Client_SetHasEditedProfile). Logs only the call time (and the bool),
-- never reads or builds the struct params. Idempotent: registers once (state in _G.DWSaveHook).
-- Output: C:/gameserver/client_io/events/savehook.jsonl. Rerun to get the counters.
return function(log)
    local OUT = "C:/gameserver/client_io/events/savehook.jsonl"
    _G.DWSaveHook = _G.DWSaveHook or { n = {}, registered = {} }
    local st = _G.DWSaveHook
    local function note(name, extra)
        st.n[name] = (st.n[name] or 0) + 1
        local f = io.open(OUT, "a")
        if f then f:write(string.format('{"fn":"%s","ts":%d,"iso":"%s"%s}\n', name, os.time(),
            os.date("!%Y-%m-%dT%H:%M:%SZ"), extra or "")); f:close() end
    end
    local fns = {
        "/Script/Dominion.DominionPlayerControllerBase:Client_SaveToDisk",
        "/Script/Dominion.DominionPlayerControllerBase:Client_LoadFromDisk",
        "/Script/Dominion.DominionPlayerControllerBase:Client_SetHasEditedProfile",
    }
    local res = {}
    for _, path in ipairs(fns) do
        local short = path:match(":(.+)$")
        if not st.registered[short] then
            local ok, err = pcall(function()
                RegisterHook(path, function(ctx, a)
                    local extra
                    if short == "Client_SetHasEditedProfile" then
                        local okb, b = pcall(function() return a:get() end)
                        extra = ',"value":"' .. tostring(okb and b) .. '"'
                    end
                    note(short, extra)
                end)
            end)
            st.registered[short] = ok
            res[short] = ok and "registered" or ("failed: " .. tostring(err))
        else
            res[short] = "already"
        end
    end
    return { hooks = res, counts = st.n }
end
