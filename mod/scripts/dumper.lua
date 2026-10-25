-- Headless reflection dumps. Hotkeys/GUI aren't available on the server, so dumps run
-- from Lua once, DUMP_DELAY_MS after boot, only if <mod_root>/dump.flag exists.
-- Output lands in the ue4ss/ folder (UE4SS_ObjectDump.txt, CXXHeaderDump/, UHTHeaderDump/)
-- and Mods/shared/types (Lua types).
local M = {}

local DUMP_DELAY_MS = 120000

local DUMPS = {
    { "DumpAllObjects", function() DumpAllObjects() end },
    { "GenerateSDK", function() GenerateSDK() end },
    { "GenerateLuaTypes", function() GenerateLuaTypes() end },
    { "GenerateUHTCompatibleHeaders", function() GenerateUHTCompatibleHeaders() end },
}

function M.maybe_dump(mod_root, log)
    local flag = mod_root and (mod_root .. "/dump.flag")
    local f = flag and io.open(flag, "r")
    if not f then return end
    f:close()
    log.event("dump_scheduled", { delay_ms = DUMP_DELAY_MS })
    ExecuteInGameThreadWithDelay(DUMP_DELAY_MS, function()
        for _, d in ipairs(DUMPS) do
            local started = os.clock()
            local ok, err = pcall(d[2])
            log.event("dump_done", { dump = d[1], ok = ok, err = err and tostring(err), cpu_s = os.clock() - started })
        end
        os.remove(flag) -- one-shot: recreate the flag to dump again (e.g. after a game patch)
    end)
end

return M
