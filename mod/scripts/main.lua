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

-- Shared Lua core (body/util.lua): default logger for U.call breadcrumbs everywhere.
local ok_util, U = pcall(require, "body.util")
if ok_util then U.set_log(log) else log.event("util_unavailable", { err = tostring(U) }) end

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
-- debug_run loads modules by name from scripts/ first, then experiments/ (docs/ARCHITECTURE.md).
require("debug_cmds").register(bridge, log, { (mod_root or ".") .. "/scripts", (mod_root or ".") .. "/experiments" })
-- LEGACY Kebbit follower reflex (experiments/companion.lua): OFF unless DW_COMPANION=1. It predates
-- the humanoid puppet and recruits a creature next to the player every 5 s.
-- DW_NO_HOOKS=1 / DW_NO_BODY=1 switch subsystems off (for bisecting server problems).
if os.getenv("DW_COMPANION") == "1" then
    local ok_c, err_c = pcall(function()
        local companion = require("experiments.companion")
        companion.start(log, bridge)
        bridge.handlers.companion_status = function() return { ok = true, data = companion.status() } end
    end)
    log.event("companion_legacy", { ok = ok_c, err = (not ok_c) and tostring(err_c) or nil })
end
-- Companion body (mod/body/): puppet lifecycle + skill handlers (follow, go_to, attack, equip, say,
-- get_state, capabilities). DW_NO_BODY=1 switches it off. Handlers act only when commanded;
-- the automatic spawn/park lifecycle loop is opt-in with DW_PUPPET_AUTOSPAWN=1 so it never
-- adopts puppets that experiment modules (puppet_test, puppet_safe) are working on.
if os.getenv("DW_NO_BODY") ~= "1" then
    local ok_body, err_body = pcall(function()
        local puppet = require("body.puppet").init({ log = log, mod_root = mod_root })
        -- Safe removal (body/removal.lua), used by park() only with DW_PUPPET_SAFE_REMOVE=1.
        local removal = require("body.removal")
        puppet.set_safe_remover(function(p, l) local r = removal.safe_remove(p, { log = l }); return type(r) == "table" and r.ok == true end)
        require("body.skills").register(bridge, log, { puppet = puppet })
        if os.getenv("DW_PUPPET_AUTOSPAWN") == "1" then puppet.start() end
    end)
    log.event("body_started", { ok = ok_body, err = (not ok_body) and tostring(err_body) or nil,
                                autospawn = os.getenv("DW_PUPPET_AUTOSPAWN") == "1" })
end
-- Frame-time sampler -> logs/perf/mod_perf.jsonl (scripts/perf_sampler.lua). DW_PERF=0 disables it.
-- Armed 60 s after start so the game world exists for its clock; debug_run can also arm it.
if os.getenv("DW_PERF") ~= "0" and mod_root then
    ExecuteInGameThreadWithDelay(60000, function()
        local ok, res = pcall(function()
            local chunk = assert(loadfile(mod_root .. "/scripts/perf_sampler.lua"))
            return chunk().run(log, {})
        end)
        log.event("perf_autostart", { ok = ok, err = (not ok) and tostring(res) or nil,
                                      clock = ok and type(res) == "table" and res.clock or nil })
    end)
end
-- Speech (body/speech.lua): status handler; DW_SAY_MODE=relay arms the verified chat relay once the
-- chat classes are loaded (the same 30 s delay as the hooks).
local ok_sp, speech = pcall(require, "body.speech")
if ok_sp then
    bridge.handlers.speech_status = function() return { ok = true, data = speech.status() } end
    if speech.mode() == "relay" and os.getenv("DW_NO_HOOKS") ~= "1" then
        ExecuteInGameThreadWithDelay(30000, function() pcall(speech.arm_relay, log) end)
    end
else
    log.event("speech_unavailable", { err = tostring(speech) })
end
-- The bot's own relayed lines pass through the chat hook too (with the template player's
-- PlayerId): never forward them to the brain as a player command.
local function is_bot_line(f)
    return ok_sp and (speech.is_relaying() or (f.character_guid ~= nil and speech.is_bot_guid(f.character_guid)))
end
if os.getenv("DW_NO_HOOKS") ~= "1" then
    require("hooks").register(log, {
        -- Every chat line goes to the brain; the Controller decides whether it's a command.
        chat = function(f)
            if is_bot_line(f) then return end
            bridge.emit_event("command_received", { player = tostring(f.player_id), text = f.text })
        end,
    })
end
