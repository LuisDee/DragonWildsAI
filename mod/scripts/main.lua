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
    -- ---- BOT INVENTORY + ITEM SKILLS (body/inventory.lua, body/items.lua, body/item_skills.lua) ----
    -- The persistent instance store lives in the "inventory" section of the puppet's bot state file
    -- (DW_BOT_STATE); on first run it migrates the persisted gear into owned, equipped instances, so
    -- gear.equip's ownership rule keeps the bot dressed. Must run before the puppet (re)applies gear,
    -- i.e. here at startup. Then: pickup / drop / give / inventory / inventory_grant handlers and the
    -- get_state inventory + nearby_items fields. (The spells block below hands the same store to the
    -- spells budget policy: count(item_id) / take(item_id, n).)
    local ok_inv, err_inv = pcall(function()
        local puppet = require("body.puppet")
        require("body.inventory").init({ log = log, puppet = puppet })
        require("body.item_skills").register(bridge, log, { skills = require("body.skills"), puppet = puppet })
    end)
    log.event("inventory_started", { ok = ok_inv, err = (not ok_inv) and tostring(err_inv) or nil })
    -- ---- end BOT INVENTORY ----
    -- ---- GATHER (body/gather.lua over body/resource_profiles.lua; services sense, hitcheck, watch) ----
    -- Bridge handler `gather {resource, count, radius?, bonus?}` (async, gather_progress events),
    -- sharing body/skills.lua's action slot and tick loop. Collects into the inventory above.
    -- the emulated hit is OFF by default (DW_GATHER_HIT=auto turns it on; gather.lua header); DW_NO_GATHER=1 skips it.
    if os.getenv("DW_NO_GATHER") ~= "1" then
        local ok_g, err_g = pcall(function()
            require("body.gather").register(bridge, log, { skills = require("body.skills"), puppet = require("body.puppet") })
        end)
        log.event("gather_started", { ok = ok_g, err = (not ok_g) and tostring(err_g) or nil })
    end
    -- ---- end GATHER ----
end
-- ===================== SPELLS + REFLEX RULES (body/spells.lua, body/rules.lua) =====================
-- Bridge handlers: cast, spells, spell_tactics (spells) and set_reflex_rule, list_rules, clear_rule
-- (rules). Combat hooks into body/combat.lua's BT: rules first (Luis's standing orders), then the
-- spells utility reflexes (shield on low HP / telegraph, Windstep on 3+ clustered enemies).
--   * Cost policy: DW_SPELL_COST_POLICY, else "mirror_budget" (Luis's unlocks AND the bot's own runes)
--     when the inventory store (body/inventory.lua count/take) is available, else "mirror" (logged).
--   * Routes not verified in game (catalog routes[r].verified) stay off unless DW_SPELLS_UNVERIFIED=1.
--   * Catalog: DW_SPELLS_CATALOG, else <repo>/data/spells_<build>.json (repo = DW_REPO_ROOT, else
--     derived from DW_MOD_LOG_DIR = <repo>/logs/mod).
--   * Rules persist per enemy class in the bot state file (puppet section "reflex_rules").
-- DW_NO_SPELLS=1 switches this block off; it needs the body (DW_NO_BODY unset).
if os.getenv("DW_NO_BODY") ~= "1" and os.getenv("DW_NO_SPELLS") ~= "1" then
    local ok_spells, err_spells = pcall(function()
        local skills, combat = require("body.skills"), require("body.combat")
        local spells, rules, puppet = require("body.spells"), require("body.rules"), require("body.puppet")
        local ok_inv, inv = pcall(require, "body.inventory")
        -- the inventory block above initialises the store; only a ready store can pay runes
        local store = (ok_inv and type(inv) == "table" and type(inv.count) == "function"
                       and type(inv.take) == "function"
                       and (type(inv.is_ready) ~= "function" or inv.is_ready())) and inv or nil
        if not store then
            log.event("spells_policy_fallback", { policy = "mirror",
                      detail = ok_inv and "inventory store not ready (no count/take or init failed)" or tostring(inv) })
        end
        local repo = os.getenv("DW_REPO_ROOT")
        if not repo or repo == "" then
            local ld = os.getenv("DW_MOD_LOG_DIR") or ""
            local base, n = ld:gsub("[/\\]logs[/\\]mod[/\\]?$", "")
            repo = n > 0 and base or nil
        end
        local catalog = os.getenv("DW_SPELLS_CATALOG")
        if not catalog or catalog == "" then catalog = repo and (repo .. "/data/spells_" .. spells.BUILD .. ".json") or nil end
        spells.register(bridge, log, { puppet = puppet, find_ai = skills.find_ai, catalog_path = catalog,
                                       cost_policy = store and "mirror_budget" or "mirror", inventory = store })
        local rule_store = type(puppet.section) == "function" and {
            load = function() return puppet.section(rules.STATE_KEY) end,
            save = function(t) return puppet.set_section(rules.STATE_KEY, t) end,
        } or nil
        rules.register(bridge, log, { spells = spells, gear = require("body.gear"), inventory = store,
                                      combat = combat, store = rule_store })
        rules.install(combat)
        spells.install_combat_hooks(combat)
    end)
    log.event("spells_started", { ok = ok_spells, err = (not ok_spells) and tostring(err_spells) or nil })
end
-- =================== end SPELLS + REFLEX RULES =====================================================
-- ===================== SLEEP (body/sleep.lua) ======================================================
-- The bot counts as a player for the night skip, so it must sleep when Luis does. Handlers: sleep,
-- wake, sleep_status. Reflex loop (1 s): Luis's rest state goes sleeping -> the bot sleeps (a free bed
-- within 15 m, else it spawns a Summon Shelter next to itself and sleeps in it: VERIFIED to pass the
-- night); Luis wakes -> the bot wakes, its shelter is removed, it follows him again.
-- DW_SLEEP_REFLEX=auto|shelter|off (default auto).
-- DW_NO_SLEEP=1 switches this block off.
if os.getenv("DW_NO_BODY") ~= "1" and os.getenv("DW_NO_SLEEP") ~= "1" then
    local ok_sleep, err_sleep = pcall(function()
        require("body.sleep").register(bridge, log, { skills = require("body.skills"), puppet = require("body.puppet") })
    end)
    log.event("sleep_started", { ok = ok_sleep, err = (not ok_sleep) and tostring(err_sleep) or nil })
end
-- =================== end SLEEP =====================================================================
-- ===================== CRAFTING (body/crafting.lua over body/recipe_data.lua) ======================
-- READ-ONLY crafting knowledge and feasibility. NO emulated crafting (Luis, 2026-10-25, real-player
-- remediation): the body never consumes inputs or grants outputs; `craft` stays not_implemented until
-- the real-client route uses the game's own crafting path. Handlers: craft_check (is it possible
-- here: inputs, station of the right type in range, recipe unlocked by Luis), recipes, stations.
-- Data: body/recipe_data.lua, generated by tools/build_recipes.py from live game data.
-- DW_CRAFT_UNLOCKS=mirror|all, DW_CRAFT_FUEL=strict|off; DW_NO_CRAFT=1 skips it.
if os.getenv("DW_NO_BODY") ~= "1" and os.getenv("DW_NO_CRAFT") ~= "1" then
    local ok_craft, err_craft = pcall(function()
        local inv = require("body.inventory")
        require("body.crafting").register(bridge, log, { skills = require("body.skills"), puppet = require("body.puppet"),
                                                         inventory = inv.is_ready() and inv or nil })
    end)
    log.event("crafting_started", { ok = ok_craft, err = (not ok_craft) and tostring(err_craft) or nil })
end
-- =================== end CRAFTING ==================================================================
-- ===================== TRAVEL (body/travel.lua) ====================================================
-- Lodestone travel like a player: `travel {to: lodestone | region | [x,y,z]}` (async: teleport the
-- PUPPET via K2_TeleportTo to the best lodestone Luis can use, settle check, then walk on), plus the
-- read-only `where {position?}` (region + nearest lodestone) and `lodestones {}`. Teleports only into
-- streamed-in areas (server streams around players). DW_TRAVEL_UNLOCK=luis|registry,
-- DW_TRAVEL_COST=free|budget (law runes from the bot inventory). DW_NO_TRAVEL=1 switches it off.
if os.getenv("DW_NO_BODY") ~= "1" and os.getenv("DW_NO_TRAVEL") ~= "1" then
    local ok_tr, err_tr = pcall(function()
        local ok_inv, inv = pcall(require, "body.inventory")
        require("body.travel").register(bridge, log, { skills = require("body.skills"), puppet = require("body.puppet"),
                                                       store = ok_inv and type(inv) == "table" and inv or nil })
    end)
    log.event("travel_started", { ok = ok_tr, err = (not ok_tr) and tostring(err_tr) or nil })
end
-- =================== end TRAVEL ====================================================================
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
