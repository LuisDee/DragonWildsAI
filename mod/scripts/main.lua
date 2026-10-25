-- DWCompanion: UE4SS Lua mod entry point (the companion's "body").
-- Deployed by tools/deploy_mod.ps1 to <Win64>/ue4ss/Mods/DWCompanion/.
-- Paths come from env vars so nothing here is Windows-specific.

local MOD_NAME = "DWCompanion"

-- Mod root: $DW_MOD_ROOT (set by tools/start_server.ps1) if present, else derived from
-- this script's path (<root>/scripts/main.lua).
local source = debug.getinfo(1, "S").source
local env_root = os.getenv("DW_MOD_ROOT")
local mod_root, mod_root_from
if env_root and env_root ~= "" then
    mod_root, mod_root_from = (env_root:gsub("[/\\]+$", "")), "env"
else
    mod_root = source:match("^@(.*)[/\\][Ss]cripts[/\\]main%.lua$")
    mod_root_from = mod_root and "script_path" or nil
end

-- Let modules outside scripts/ (body/, skills/, state/, bridge/) be required later.
if mod_root then
    package.path = package.path .. ";" .. mod_root .. "/?.lua;" .. mod_root .. "/?/init.lua"
end

local log = require("dwlog")
log.init(os.getenv("DW_MOD_LOG_DIR") or (mod_root and (mod_root .. "/logs")) or "dwcompanion_logs")

log.event("mod_loaded", { mod = MOD_NAME, lua = _VERSION, mod_root = mod_root, mod_root_from = mod_root_from, source = source })
if not mod_root then
    -- No dump.flag check and no extra package.path: set DW_MOD_ROOT to fix.
    log.event("mod_root_unknown", { source = source, hint = "set DW_MOD_ROOT to the mod folder (the one holding scripts/)" })
end
print(string.format("[%s] loaded; logging to %s\n", MOD_NAME, log.path()))

require("dumper").maybe_dump(mod_root, log)
local bridge = require("bridge")
bridge.start(log)
require("debug_cmds").register(bridge, log)
require("hooks").register(log, {
    -- Every chat line goes to the brain; the Controller decides whether it's a command.
    chat = function(f) bridge.emit_event("command_received", { player = tostring(f.player_id), text = f.text }) end,
})
