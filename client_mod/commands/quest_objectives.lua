-- READ ONLY dev-fact probe: every objective of every quest's UQuestData (TMap<FName, FQuestObjectiveData> Objectives:
-- key -> Description / SubobjectiveDescription / Hint), in map order, plus the quest's state and current objective.
-- Why: the GOAL case capstone_stage_1_shelter has the placeholder "<the shelter objective key from quest data>"
-- (docs/judge_freeze_notes.md). The objective map is asset data, readable even for an UNGIVEN quest (Dragon Slayer
-- shows state 0 on a fresh dev character), so one run of this on any character gives the shelter step's own words.
-- Writes client_io/out/quest_objectives.json. No writes to the game, no calls that change state.
-- Edit FILTER to a quest name substring (nil = all quests).
local FILTER = nil
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local function text(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end

return function(log)
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") then pc = x end
    end
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    if not U.valid(qc) then return { ok = false, error = "no QuestProgressComponent (not in the world?)" } end
    local STATE = { [0] = "ungiven", [1] = "given", [2] = "complete" }
    local out = {}
    U.each(U.try(function() return qc.Quests end), function(q)
        local d = U.try(function() return q.Data end)
        if not U.valid(d) then return end
        local name = text(U.try(function() return d.QuestName end)) or U.short(d)
        if FILTER and not tostring(name):lower():find(FILTER:lower(), 1, true) then return end
        local row = { quest = name, asset = U.short(d), state = STATE[U.try(function() return q.State end)] or "unknown",
                      current = text(U.try(function() return q.CurrentObjective end)), objectives = {} }
        local i = 0
        U.each(U.try(function() return d.Objectives end), function(v, k)
            i = i + 1
            row.objectives[#row.objectives + 1] = {
                i = i, key = text(k),
                description = v and text(U.try(function() return v.Description end)) or nil,
                sub = v and text(U.try(function() return v.SubobjectiveDescription end)) or nil,
                hint = v and text(U.try(function() return v.Hint end)) or nil }
        end, 128)
        out[#out + 1] = row
    end, 256)
    local res = { ok = true, quests = out, n = #out }
    local json = U.try(function() return assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))() end)
    if json then
        local f = io.open(ROOT .. "/client_io/out/quest_objectives.json", "w")
        if f then f:write(json.encode(res, { indent = true })); f:close() end
    end
    return res
end
