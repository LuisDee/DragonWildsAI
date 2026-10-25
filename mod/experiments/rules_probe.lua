-- READ-ONLY live checks for the spells + reflex rules wiring (body/spells.lua, body/rules.lua) on a
-- running server, before the restart that loads them for real. Nothing here casts, moves, equips or
-- writes a game property: it only reads.
--   debug_run {"module":"rules_probe","args":{"action":"status"}}
--       fresh copy of the deployed body/spells.lua (loadfile, so the server's module cache is not
--       touched): loads the catalog, reports reflex route gates, the compact castable list under the
--       mirror policy, and Luis's live unlocks (ProgressComponent.SpellsUnlocked TSet read).
--   debug_run {"module":"rules_probe","args":{"action":"sense","radius_m":30}}
--       one read of AiAttackComponent.CurrentAttack.AttackData for every AI within radius_m of Luis
--       (the telegraph sensor's attack-state poll).
--   debug_run {"module":"rules_probe","args":{"action":"watch","seconds":20,"radius_m":30}}
--       the same read every 200 ms for `seconds` (cancelled with CancelDelayedAction); each attack
--       start is logged as rules_probe_attack in logs/mod/mod_*.jsonl. Run it while Luis fights.
local U = require("body.util")

local M = {}

local function mod_root() return (os.getenv("DW_MOD_ROOT") or "."):gsub("[/\\]+$", "") end

local function repo_root()
    local r = os.getenv("DW_REPO_ROOT")
    if r and r ~= "" then return r end
    local base, n = (os.getenv("DW_MOD_LOG_DIR") or ""):gsub("[/\\]logs[/\\]mod[/\\]?$", "")
    return n > 0 and base or nil
end

local function fresh_spells()
    local chunk, err = loadfile(mod_root() .. "/body/spells.lua")
    if not chunk then return nil, err end
    local ok, mod = pcall(chunk)
    if not ok then return nil, tostring(mod) end
    return mod
end

local function attack_of(ai)
    local comp = U.try(function() return ai.AiAttackComponent end)
    if not U.valid(comp) then return nil, "no AiAttackComponent" end
    local cur = U.try(function() return comp.CurrentAttack end)
    if cur == nil then return nil, "CurrentAttack unreadable" end
    local data = U.try(function() return cur.AttackData end)
    if not U.valid(data) then return false end
    return (U.short(data) or "?"):gsub("^Default__", "")
end

local function ais_near(origin, radius_cm)
    local out = {}
    for _, ai in ipairs(U.find_all("DominionAICharacter")) do
        local d = U.dist(origin, U.loc(ai))
        if d <= radius_cm then out[#out + 1] = { ai = ai, d = d } end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function origin()
    local players, puppets = U.split_pawns()
    local o = players[1] or puppets[1]
    return o and U.loc(o), #players
end

function M.status(log)
    local spells, err = fresh_spells()
    if not spells then return { ok = false, err = err } end
    local path = repo_root() and (repo_root() .. "/data/spells_" .. spells.BUILD .. ".json")
    local t0 = os.clock()
    local doc, lerr = path and spells.load_catalog(path)
    local load_ms = math.floor((os.clock() - t0) * 1000)
    local mirror_fn = spells.live_mirror()
    local m = mirror_fn()
    spells.configure({ cost_policy = "mirror", mirror = m })
    local castable = {}
    for _, r in ipairs(spells.list({ compact = true })) do castable[#castable + 1] = r.name .. (r.castable and "" or (" (" .. tostring(r.reason) .. ")")) end
    spells.configure({ allow_unverified = true })
    local if_unverified = {}
    for _, r in ipairs(spells.list({ compact = true })) do if_unverified[#if_unverified + 1] = r.name end
    local n_unlocked = 0
    for _ in pairs(m and m.unlocked or {}) do n_unlocked = n_unlocked + 1 end
    local res = {
        ok = doc ~= nil, catalog = path, catalog_err = lerr, catalog_load_ms = load_ms,
        spell_count = doc and doc.spell_count, routes = doc and doc.routes,
        reflexes = (function() spells.configure({ allow_unverified = false }); return spells.reflex_status() end)(),
        mirror_source = m and m.source, mirror_name = m and m.name, unlocked = n_unlocked,
        windstep_perk = m and m.perks and m.perks.PerkV2_Agility_Spell_Windstep_Upgrade == true or false,
        castable_now = castable, castable_if_unverified_allowed = if_unverified,
    }
    U.event(log, "rules_probe_status", res)
    return res
end

function M.sense(log, args)
    local o, nplayers = origin()
    local radius = (tonumber(args.radius_m) or 30) * 100
    if not o then
        -- nobody online: any=true reads every loaded AI (first 20) around the world origin
        if args.any ~= true then return { ok = false, err = "nobody online and no puppet (pass any=true)" } end
        o, radius = { X = 0, Y = 0, Z = 0 }, math.huge
    end
    local out = {}
    for _, e in ipairs(ais_near(o, radius)) do
        local atk, why = attack_of(e.ai)
        out[#out + 1] = { id = U.short(e.ai), d_m = U.cm_to_m(e.d), attacking = atk or false, err = why }
        if #out >= 20 then break end
    end
    local res = { ok = true, players = nplayers, ais = out }
    U.event(log, "rules_probe_sense", res)
    return res
end

-- 200 ms poll for `seconds`, logging attack starts. One sampler at a time (_G guard).
function M.watch(log, args)
    local seconds = math.min(tonumber(args.seconds) or 20, 120)
    local radius = (tonumber(args.radius_m) or 30) * 100
    local prev = rawget(_G, "__dw_rules_probe_watch")
    if prev and CancelDelayedAction then pcall(CancelDelayedAction, prev.handle) end
    local st = { left = math.floor(seconds * 5), attacking = {}, starts = 0 }
    st.handle = LoopInGameThreadWithDelay(200, function()
        st.left = st.left - 1
        if st.left <= 0 then
            if CancelDelayedAction then pcall(CancelDelayedAction, st.handle) end
            U.event(log, "rules_probe_watch_end", { starts = st.starts })
            return true
        end
        local o = origin()
        if not o then return false end
        for _, e in ipairs(ais_near(o, radius)) do
            local id = U.short(e.ai)
            local atk = attack_of(e.ai)
            if atk and atk ~= st.attacking[id] then
                st.starts = st.starts + 1
                U.event(log, "rules_probe_attack", { by = id, attack = atk, d_m = U.cm_to_m(e.d), n = st.starts })
            end
            st.attacking[id] = atk or nil
        end
        return false
    end)
    rawset(_G, "__dw_rules_probe_watch", st)
    return { ok = true, watching_s = seconds, radius_m = radius / 100, log_event = "rules_probe_attack" }
end

function M.run(log, args)
    args = args or {}
    local action = args.action or "status"
    local fn = ({ status = M.status, sense = M.sense, watch = M.watch })[action]
    if not fn then return { ok = false, err = "unknown action " .. tostring(action), actions = { "status", "sense", "watch" } } end
    local ok, res = pcall(fn, log, args)
    if not ok then return { ok = false, err = tostring(res) } end
    return res
end

return M
