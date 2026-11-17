-- quests: what the game says about Claude's quests (M5 brynmoor_quest_chain; audit docs/design/every-skill-coverage.md §10).
-- READ ONLY, from the game's own data: the controller's QuestProgressComponent.Quests (FQuestProgress: Data =
-- UQuestData, State = EQuestState Ungiven/Given/Complete, CurrentObjective = an FName key, QuestInts, QuestBools)
-- and each quest's UQuestData (QuestName, QuestDescription, Objectives: TMap<FName, FQuestObjectiveData{Description,
-- SubobjectiveDescription, Hint}>). The model sees the current step in the game's own words, so progress is
-- truthful; no quest or NPC names live in code. The same rows the harness probe reads (bench_probe.lua quests).
--   get_state extras: quests = {active = [{quest, objective, step, hint}], complete = [names], counts}
--   read tool `quests {all?}`: the same with every quest, ungiven ones too (all = true)
-- W = the engine touches (tests replace them). Never a write, never a call that changes state.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }
M.cfg = { cap = 128, field_cap = 64, extras_ttl_s = 5, active_rows = 8, markers_ttl_s = 60, markers_cap = 512, where_per_quest = 3 }
M.STATE = { [0] = "ungiven", [1] = "given", [2] = "complete" } -- EQuestState
M.MARKER = { [0] = "target", [1] = "area", [2] = "npc" }         -- EQuestLocationType

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end

local L = U.loader(ROOT) -- the shared sibling-module loader (mod/body/util.lua)
M.mods, M.set_modules = L.mods, L.set_modules
local mod = L.mod

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
function W.pc()
    local inp = mod("input")
    if inp and inp.pc then local pc = inp.pc(); if pc then return pc end end
    local s = mod("sense")
    return s and s.local_pc and s.local_pc() or nil
end
-- -> rows {quest, state, objective_key, objective, sub, hint, description, main, ints = {}, bools = {}} | nil.
-- State is read first; the objective text, counters, flags and description only for GIVEN quests (or opts.all):
-- an ungiven or completed quest is just its name and state (simplify review: no needless per-quest reads).
function W.rows(pc, opts)
    opts = opts or {}
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    if not U.valid(qc) or paused() then return nil end
    local out = {}
    U.each(U.try(function() return qc.Quests end), function(q)
        local d = U.try(function() return q.Data end)
        if not U.valid(d) then return end
        local r = { quest = text(U.try(function() return d.QuestName end)) or U.short(d), asset = U.short(d),
                    state = M.STATE[num(U.try(function() return q.State end)) or -1] or "unknown",
                    objective_key = text(U.try(function() return q.CurrentObjective end)), ints = {}, bools = {} }
        if r.state == "given" or opts.all then
            r.description = text(U.try(function() return d.QuestDescription end))
            r.main = U.try(function() return d.bIsMainQuest end) == true or nil
            if r.objective_key then
                -- the step in the game's own words: Objectives[CurrentObjective]
                U.each(U.try(function() return d.Objectives end), function(v, k)
                    if text(k) == r.objective_key and v then
                        r.objective = text(U.try(function() return v.Description end))
                        r.sub = text(U.try(function() return v.SubobjectiveDescription end))
                        r.hint = text(U.try(function() return v.Hint end))
                        return true
                    end
                end, M.cfg.field_cap)
            end
            U.each(U.try(function() return q.QuestInts end), function(x)
                -- FQuestInt {QuestIntName, QuestIntValue}, FQuestBool {QuestBoolName, bQuestBoolValue} (Dominion.hpp:6399,
                -- 6418). Read as Name / Value until 2026-11-16 they were never there, so no counter or flag ever showed
                local k = text(U.try(function() return x.QuestIntName end)); if k then r.ints[k] = num(U.try(function() return x.QuestIntValue end)) end
            end, M.cfg.field_cap)
            U.each(U.try(function() return q.QuestBools end), function(x)
                local k = text(U.try(function() return x.QuestBoolName end)); if k then r.bools[k] = U.try(function() return x.bQuestBoolValue end) == true end
            end, M.cfg.field_cap)
        end
        out[#out + 1] = r
    end, M.cfg.cap)
    return out
end

-- The game's quest map markers (what the map and compass show a player): UQuestWorldSubsystem.QuestLocations, the
-- AQuestLocation actors {Type, Radius, Quest, bShownByDefault, QuestLocationName} (all 174 are loaded on the client,
-- live 2026-11-01), static, so re-read every markers_ttl_s; the ground height under each from one downward trace
-- (the FTUE ones sit ~230 m above the ground), cached per marker. -> {{id, quest, key, kind, radius_m, x, y, top}}
local MK = { at = nil, rows = nil, z = {} }
local function ground_z(pawn, x, y, top)
    local ksl = U.find_object and U.find_object("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and pawn) then return nil end
    local C0, out = { R = 0, G = 0, B = 0, A = 0 }, {}
    local ok, hit = pcall(function()
        return ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = top + 5000 }, { X = x, Y = y, Z = top - 100000 }, 0, false, {}, 0, out, true, C0, C0, 0.0)
    end)
    local z = ok and hit == true and U.try(function() return out.ImpactPoint.Z end)
    return type(z) == "number" and z / 100 or nil
end
function W.markers(now)
    if MK.rows and MK.at and now and now - MK.at >= 0 and now - MK.at < M.cfg.markers_ttl_s then return MK.rows end
    local rows = {}
    local ss = (U.find_all("QuestWorldSubsystem", { skip_defaults = true }) or {})[1]
    U.each(ss and U.try(function() return ss.QuestLocations end), function(a)
        if not U.valid(a) then return end
        local q = U.try(function() return a.Quest end)
        local at = U.loc(a)
        local okp, x, y, z = pcall(function() return at.X, at.Y, at.Z end)
        if not (U.valid(q) and okp and type(x) == "number") then return end
        rows[#rows + 1] = { id = U.short(a), quest = text(U.try(function() return q.QuestName end)), asset = U.short(q), key = text(U.try(function() return a.QuestLocationName end)),
                            kind = M.MARKER[num(U.try(function() return a.Type end)) or -1], radius_m = (num(U.try(function() return a.Radius end)) or 0) / 100,
                            default = U.try(function() return a.bShownByDefault end) == true, x = x, y = y, top = z }
    end, M.cfg.markers_cap)
    MK.rows, MK.at = rows, now
    return rows
end
-- his VisibilityTrackers: {LocationName = shown?}
function W.visibility(pc)
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    local out = {}
    U.each(U.valid(qc) and U.try(function() return qc.VisibilityTrackers end), function(t)
        local k = text(U.try(function() return t.LocationName end))
        if k then out[k] = U.try(function() return t.bLocationVisibility end) == true end
    end, M.cfg.markers_cap)
    return out
end
-- the markers the game shows him now (his tracker says shown, or no tracker and shown by default)
function W.where(pc, now)
    local pawn = pc and U.try(function() return pc.Pawn end)
    local here = U.valid(pawn) and U.loc(pawn)
    local okh, hx, hy = pcall(function() return here.X, here.Y end)
    local vis = W.visibility(pc)
    local out = {}
    for _, m in ipairs(W.markers(now) or {}) do
        local shown = vis[m.key]
        if m.quest and (shown == true or (shown == nil and m.default)) then
            -- a miss (ground not loaded that far out: live 15:5xZ, 207 m) is retried at most every 10 s
            local zc = MK.z[m.id]
            if zc == nil or (type(zc) == "table" and now and now - zc.miss >= 10) then MK.z[m.id] = ground_z(pawn, m.x, m.y, m.top) or { miss = now or 0 } end
            local z = type(MK.z[m.id]) == "number" and MK.z[m.id] or nil
            local xy = { math.floor(m.x / 10 + 0.5) / 10, math.floor(m.y / 10 + 0.5) / 10 }
            out[#out + 1] = { quest = m.quest, asset = m.asset, key = m.key, kind = m.kind, radius_m = m.radius_m, xy = xy,
                              position = z and { xy[1], xy[2], math.floor(z * 10 + 0.5) / 10 } or nil,
                              distance_m = okh and math.floor(math.sqrt((m.x - hx) ^ 2 + (m.y - hy) ^ 2) / 100 + 0.5) or nil }
        end
    end
    return out
end

-- ------------------------------------------------------------------ pure
-- A marker's key in words: "Windmill_Area_FTUE_RC" -> "Windmill Area" (the all-capitals tags are the game's own
-- quest and tutorial codes, not words a player sees)
function M.marker_name(key)
    local w = {}
    for tok in tostring(key or ""):gmatch("[^_%.]+") do
        if tok:find("%l") then w[#w + 1] = (tok:gsub("(%l)(%u)", "%1 %2")) end
    end
    return #w > 0 and table.concat(w, " ") or tostring(key)
end
-- The all-capitals tokens of a marker's key ("WOM_Objective_FTUE_GS" -> WOM, FTUE, GS)
function M.codes(key)
    local c = {}
    for tok in tostring(key or ""):gmatch("[^_%.]+") do
        if not tok:find("%l") and tok:find("%u%u") then c[#c + 1] = tok end
    end
    return c
end
-- A code spelled out by the initials of a run of capitalised words in the quest's own text ("WOM" in "Speak to the
-- Wise Old Man" -> "Wise Old Man"), else nil: the game's marker keys abbreviate the NPC the step names
function M.expand(code, text)
    local run = {}
    local function hit()
        if #run ~= #code then return nil end
        local ini = {}
        for i, w in ipairs(run) do ini[i] = w:sub(1, 1) end
        return table.concat(ini) == code and table.concat(run, " ") or nil
    end
    for w in tostring(text or ""):gmatch("%S+") do
        local bare = w:gsub("[^%w']", "")
        if bare:find("^%u") then
            run[#run + 1] = bare
            if #run > #code then table.remove(run, 1) end
            local h = hit()
            if h then return h end
        else
            run = {}
        end
    end
    return nil
end
-- a marker's name with its abbreviated NPC spelled out from the quest's text ("Objective" -> "Wise Old Man Objective":
-- live, First Steps' only marker read "Objective", so go_to "Wise Old Man" could not resolve it)
function M.label(row, text)
    local name = row.name
    for _, c in ipairs(row.codes or {}) do
        local e = M.expand(c, text)
        if e and not tostring(name):find(e, 1, true) then name = e .. " " .. name end
    end
    return name
end
-- marker rows -> {quest asset (or name) = {{name, kind, radius_m, position | xy, distance_m, inside}}}, nearest first
function M.where_by_quest(rows, per)
    local by = {}
    for _, m in ipairs(rows or {}) do
        local k = m.asset or m.quest -- two quests can share a name (live 17:2xZ: a finished First Steps' "Doric Objective"
        local t = by[k] or {}         -- marker showed under the new First Steps)
        by[k] = t
        t[#t + 1] = { name = M.marker_name(m.key), codes = M.codes(m.key), kind = m.kind,
                      radius_m = (m.radius_m or 0) > 0 and m.radius_m or nil,
                      position = m.position, xy = (not m.position) and m.xy or nil, distance_m = m.distance_m,
                      inside = (m.kind == "area" and m.distance_m and m.radius_m and m.distance_m <= m.radius_m) or nil }
    end
    for _, t in pairs(by) do
        table.sort(t, function(a, b) return (a.distance_m or math.huge) < (b.distance_m or math.huge) end)
        while #t > (per or 3) do table.remove(t) end
    end
    return by
end

-- Rows -> what the model sees. opts.all keeps ungiven quests too; opts.where = where_by_quest's table.
function M.summary(rows, opts)
    opts = opts or {}
    local active, complete, ungiven = {}, {}, {}
    for _, r in ipairs(rows or {}) do
        if r.state == "given" then
            local a = { quest = r.quest, step = r.objective or r.objective_key, detail = r.sub, hint = r.hint, main = r.main,
                        where = opts.where and opts.where[r.asset or r.quest] or nil }
            for _, m in ipairs(a.where or {}) do -- labels in the step's own words; the raw codes stay internal
                m.name = M.label(m, table.concat({ tostring(r.objective or ""), tostring(r.sub or ""), tostring(r.hint or "") }, " "))
                m.codes = nil
            end
            if next(r.ints or {}) then a.counters = r.ints end
            if next(r.bools or {}) then a.flags = r.bools end
            active[#active + 1] = a
        elseif r.state == "complete" then complete[#complete + 1] = r.quest
        else ungiven[#ungiven + 1] = r.quest end
    end
    -- the game gives a quest's parts one name: a part that is complete while another of that name is given is not
    -- "the quest complete". Listed bare it read as done and he stopped with the next part open (fresh chain
    -- 20261116-045722: complete = [..., "Rune Mysteries"] beside the active Rune Mysteries, "Rune Mysteries is
    -- done", then 503 s standing). The active row says an earlier part is done; complete keeps the finished ones
    local given = {}
    for _, a in ipairs(active) do given[tostring(a.quest)] = a end
    local over, seen = {}, {}
    for _, q in ipairs(complete) do
        local a = given[tostring(q)]
        if a then a.earlier_part_complete = true
        elseif not seen[tostring(q)] then over[#over + 1] = q; seen[tostring(q)] = true end -- both parts done: one name
    end
    complete = over
    table.sort(active, function(x, y) if (x.main or false) ~= (y.main or false) then return x.main == true end return tostring(x.quest) < tostring(y.quest) end)
    table.sort(complete)
    local out = { active = active, complete = complete, counts = { active = #active, complete = #complete, ungiven = #ungiven } }
    if opts.all then table.sort(ungiven); out.ungiven = ungiven end
    return out
end

-- ------------------------------------------------------------------ tool + perception
local function quests_tool(log, args)
    if paused() then return { ok = false, reason = "companion_down", data = { detail = "I'm not in the world right now." } } end
    local pc = W.pc()
    local rows = W.rows(pc, { all = args and args.all == true })
    if not rows then return { ok = false, reason = "state_unavailable", data = { detail = "I can't read my quest log right now." } } end
    return { ok = true, data = M.summary(rows, { all = args and args.all == true, where = M.where_now(pc) }) }
end
M._tool = quests_tool
-- the active quests' markers now (best effort: a read error leaves them out)
function M.where_now(pc)
    local ok, rows = pcall(W.where, pc, os.time())
    return ok and M.where_by_quest(rows, M.cfg.where_per_quest) or nil
end

local CACHE = { at = nil, v = nil }
function M.state_extras(api)
    if paused() then return {} end
    local now = (api and api.now and api.now()) or os.time()
    if CACHE.v and CACHE.at and now - CACHE.at >= 0 and now - CACHE.at < M.cfg.extras_ttl_s then return CACHE.v end
    local pc = W.pc()
    local rows = W.rows(pc)
    local v = {}
    if rows then
        local s = M.summary(rows, { where = M.where_now(pc) })
        while #s.active > M.cfg.active_rows do table.remove(s.active) end
        v = { quests = s }
    end
    CACHE.at, CACHE.v = now, v
    return v
end
function M._reset_cache() CACHE.at, CACHE.v = nil, nil end
-- client_bridge calls this when an action ends (a talk, a kill, a craft may have moved a quest on): the next state
-- reads the quest log anew instead of showing the step from before it
function M.action_ended() M._reset_cache() end

M.HANDLERS = { quests = function(log, args) return quests_tool(log, args or {}) end }
M.NEEDS = { quests = { { "sense", "local_pc" } } }
do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        quests = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Your quest log from the game: active quests with the current step in the game's own words "
                .. "(and its hint), and where: the step's own map markers as the map and compass show them (an area "
                .. "circle, a target spot or the NPC: name, kind, radius_m, position, distance_m, inside); go_to takes the "
                .. "position. Completed quests too; all = true adds the ones not started. Read only.",
            args = { type = "object", properties = obj({ all = { type = "boolean", default = false, description = "Include quests not started yet." } }) },
            reasons = { "companion_down", "state_unavailable" } },
    }
end

return M
