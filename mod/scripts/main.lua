-- DWCompanion: UE4SS Lua mod entry point (the companion's "body").
-- Deployed by tools/deploy_mod.ps1 to <Win64>/ue4ss/Mods/DWCompanion/.
-- Paths come from env vars so nothing here is Windows-specific.

local MOD_NAME = "DWCompanion"

-- Let modules outside scripts/ (body/, skills/, state/, bridge/) be required later.
local source = debug.getinfo(1, "S").source
local mod_root = source:match("^@(.*)[/\\][Ss]cripts[/\\]main%.lua$")
if mod_root then
    package.path = package.path .. ";" .. mod_root .. "/?.lua;" .. mod_root .. "/?/init.lua"
end

local log = require("dwlog")
log.init(os.getenv("DW_MOD_LOG_DIR") or (mod_root and (mod_root .. "/logs")) or "dwcompanion_logs")

log.event("mod_loaded", { mod = MOD_NAME, lua = _VERSION, mod_root = mod_root, source = source })
print(string.format("[%s] loaded; logging to %s\n", MOD_NAME, log.path()))

require("dumper").maybe_dump(mod_root, log)
local bridge = require("bridge")
bridge.start(log)
require("hooks").register(log, {
    -- Every chat line goes to the brain; the Controller decides whether it's a command.
    chat = function(f) bridge.emit_event("command_received", { player = tostring(f.player_id), text = f.text }) end,
})
