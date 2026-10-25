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

-- Game-thread heartbeat: tools/watchdog.ps1 restarts the server if this file goes stale, which
-- catches hangs that produce no crash dump. Written from the game thread on purpose.
local hb_path = os.getenv("DW_HEARTBEAT_FILE")
if hb_path then
    LoopInGameThreadWithDelay(10000, function()
        local f = io.open(hb_path, "w")
        if f then f:write(os.time(), "\n"); f:close() end
    end)
end
require("debug_cmds").register(bridge, log, (mod_root or ".") .. "/scripts")
-- DW_NO_COMPANION / DW_NO_HOOKS=1 switch subsystems off (for bisecting server problems).
if os.getenv("DW_NO_COMPANION") ~= "1" then
    require("companion").start(log, bridge)
    bridge.handlers.companion_status = function() return { ok = true, data = require("companion").status() } end
end
-- Companion body (mod/body/): puppet lifecycle + skill handlers (follow, go_to, attack, equip, say,
-- get_state, capabilities). DW_NO_BODY=1 switches it off. Handlers act only when commanded;
-- the automatic spawn/park lifecycle loop is opt-in with DW_PUPPET_AUTOSPAWN=1 so it never
-- adopts puppets that experiment modules (puppet_test, puppet_safe) are working on.
if os.getenv("DW_NO_BODY") ~= "1" then
    local ok_body, err_body = pcall(function()
        local puppet = require("body.puppet").init({ log = log, mod_root = mod_root })
        -- Safe removal (scripts/puppet_safe.lua), used by park() only with DW_PUPPET_SAFE_REMOVE=1.
        local chunk = mod_root and loadfile(mod_root .. "/scripts/puppet_safe.lua")
        local safe = chunk and chunk()
        if type(safe) == "table" and type(safe.safe_remove) == "function" then
            puppet.set_safe_remover(function(p) local r = safe.safe_remove(p); return type(r) == "table" and r.ok == true end)
        end
        require("body.skills").register(bridge, log, { puppet = puppet })
        if os.getenv("DW_PUPPET_AUTOSPAWN") == "1" then puppet.start() end
    end)
    log.event("body_started", { ok = ok_body, err = (not ok_body) and tostring(err_body) or nil,
                                autospawn = os.getenv("DW_PUPPET_AUTOSPAWN") == "1" })
end
if os.getenv("DW_NO_HOOKS") ~= "1" then
    require("hooks").register(log, {
        -- Every chat line goes to the brain; the Controller decides whether it's a command.
        chat = function(f) bridge.emit_event("command_received", { player = tostring(f.player_id), text = f.text }) end,
    })
end
