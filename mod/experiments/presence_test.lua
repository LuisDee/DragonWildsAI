-- Map/compass presence experiment (thin wrapper over body/presence.lua).
-- debug_run {module="presence_test", args={action=...}}:
--   status (default) read-only: registry entries (presence_probe) + presence.status()
--   add    {confirm=true}: append the bot's FPlayerCharacterData entry and start the 1 s
--          location updater. Client-affecting (replicated to every client): Luis's go-ahead.
--   stop   stop the location updater (the entry itself can't be removed live; gone on restart)
-- body/presence.lua is new (not loaded at server start), so the first require here loads it from
-- disk; reload=true forces a fresh load of it (only safe while nothing else holds it).
local U = require("body.util")
local M = {}

local function presence(reload)
    if reload then package.loaded["body.presence"] = nil end
    return require("body.presence")
end

local function puppet()
    local _, puppets = U.split_pawns()
    return puppets[1]
end

function M.run(log, args)
    args = args or {}
    local P = presence(args.reload == true)
    local action = args.action or "status"
    if action == "add" then
        if args.confirm ~= true then
            return { ok = false, error = "refused: replicated to every client; pass confirm=true (Luis's go-ahead)" }
        end
        local r = P.ensure(log, puppet())
        local loop = r.ok and P.start(log, puppet) or nil
        return { ok = r.ok, ensure = r, loop = loop, status = P.status() }
    end
    if action == "stop" then P.stop(); return { ok = true, status = P.status() } end
    local probe = assert(loadfile((debug.getinfo(1, "S").source:sub(2):gsub("presence_test%.lua$", "presence_probe.lua"))))()
    local reg = P.registry()
    return { ok = true, status = P.status(), entries = reg and probe.registry_entries(reg) or nil }
end

return M
