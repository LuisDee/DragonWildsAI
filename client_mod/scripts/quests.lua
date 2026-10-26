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
M.cfg = { cap = 128, field_cap = 64, extras_ttl_s = 5, active_rows = 8 }
M.STATE = { [0] = "ungiven", [1] = "given", [2] = "complete" } -- EQuestState

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
local function num(v) return type(v) == "number" and v or nil end

M.mods = {}
function M.set_modules(t) for k, v in pairs(t) do M.mods[k] = v end end
local function mod(name)
    if not M.mods[name] then
        local ok, m = pcall(function() return assert(loadfile(ROOT .. "/client_mod/scripts/" .. name .. ".lua"))() end)
        if ok then M.mods[name] = m end
    end
    return M.mods[name]
end

local function each(arr, fn, cap)
    if paused() or not arr then return end
    local n = 0
    pcall(function()
        arr:ForEach(function(k, v)
            n = n + 1
            if n > (cap or M.cfg.cap) then return true end
            local kk = U.try(function() return k:get() end) or k
            local vv = v ~= nil and (U.try(function() return v:get() end) or v) or nil
            fn(kk, vv)
        end)
    end)
end

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
function W.pc()
    local inp = mod("input")
    if inp and inp.pc then local pc = inp.pc(); if pc then return pc end end
    local s = mod("sense")
    return s and s.local_pc and s.local_pc() or nil
end
-- -> rows {quest, state, objective_key, objective, sub, hint, description, ints = {}, bools = {}} | nil
function W.rows(pc)
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    if not U.valid(qc) or paused() then return nil end
    local out = {}
    each(U.try(function() return qc.Quests end), function(_, q)
        q = q or _
        local d = U.try(function() return q.Data end)
        if not U.valid(d) then return end
        local r = { quest = text(U.try(function() return d.QuestName end)) or U.short(d), asset = U.short(d),
                    state = M.STATE[num(U.try(function() return q.State end)) or -1] or "unknown",
                    objective_key = text(U.try(function() return q.CurrentObjective end)),
                    description = text(U.try(function() return d.QuestDescription end)),
                    main = U.try(function() return d.bIsMainQuest end) == true or nil, ints = {}, bools = {} }
        if r.objective_key then
            -- the step in the game's own words: Objectives[CurrentObjective]
            each(U.try(function() return d.Objectives end), function(k, v)
                if r.objective then return end
                if text(k) == r.objective_key and v then
                    r.objective = text(U.try(function() return v.Description end))
                    r.sub = text(U.try(function() return v.SubobjectiveDescription end))
                    r.hint = text(U.try(function() return v.Hint end))
                end
            end, M.cfg.field_cap)
        end
        each(U.try(function() return q.QuestInts end), function(_, x) x = x or _; local k = text(U.try(function() return x.Name end)); if k then r.ints[k] = num(U.try(function() return x.Value end)) end end, M.cfg.field_cap)
        each(U.try(function() return q.QuestBools end), function(_, x) x = x or _; local k = text(U.try(function() return x.Name end)); if k then r.bools[k] = U.try(function() return x.Value end) == true end end, M.cfg.field_cap)
        out[#out + 1] = r
    end, M.cfg.cap)
    return out
end

-- ------------------------------------------------------------------ pure
-- Rows -> what the model sees. opts.all keeps ungiven quests too.
function M.summary(rows, opts)
    opts = opts or {}
    local active, complete, ungiven = {}, {}, {}
    for _, r in ipairs(rows or {}) do
        if r.state == "given" then
            local a = { quest = r.quest, step = r.objective or r.objective_key, detail = r.sub, hint = r.hint, main = r.main }
            if next(r.ints or {}) then a.counters = r.ints end
            if next(r.bools or {}) then a.flags = r.bools end
            active[#active + 1] = a
        elseif r.state == "complete" then complete[#complete + 1] = r.quest
        else ungiven[#ungiven + 1] = r.quest end
    end
    table.sort(active, function(x, y) if (x.main or false) ~= (y.main or false) then return x.main == true end return tostring(x.quest) < tostring(y.quest) end)
    table.sort(complete)
    local out = { active = active, complete = complete, counts = { active = #active, complete = #complete, ungiven = #ungiven } }
    if opts.all then table.sort(ungiven); out.ungiven = ungiven end
    return out
end

-- ------------------------------------------------------------------ tool + perception
local function quests_tool(log, args)
    if paused() then return { ok = false, reason = "companion_down", data = { detail = "I'm not in the world right now." } } end
    local rows = W.rows(W.pc())
    if not rows then return { ok = false, reason = "state_unavailable", data = { detail = "I can't read my quest log right now." } } end
    return { ok = true, data = M.summary(rows, { all = args and args.all == true }) }
end
M._tool = quests_tool

local CACHE = { at = nil, v = nil }
function M.state_extras(api)
    if paused() then return {} end
    local now = (api and api.now and api.now()) or os.time()
    if CACHE.v and CACHE.at and now - CACHE.at >= 0 and now - CACHE.at < M.cfg.extras_ttl_s then return CACHE.v end
    local rows = W.rows(W.pc())
    local v = {}
    if rows then
        local s = M.summary(rows)
        while #s.active > M.cfg.active_rows do table.remove(s.active) end
        v = { quests = s }
    end
    CACHE.at, CACHE.v = now, v
    return v
end
function M._reset_cache() CACHE.at, CACHE.v = nil, nil end

M.HANDLERS = { quests = function(log, args) return quests_tool(log, args or {}) end }
M.NEEDS = { quests = { { "sense", "local_pc" } } }
do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        quests = { kind = "read", llm = true, moves = false, duration_s = 0.3, timeout_s = 10,
            description = "Your quest log from the game: active quests with the current step in the game's own words "
                .. "(and its hint), completed quests; all = true adds the ones not started. Read only.",
            args = { type = "object", properties = obj({ all = { type = "boolean", default = false, description = "Include quests not started yet." } }) },
            reasons = { "companion_down", "state_unavailable" } },
    }
end

return M
