-- Offline tests for client_mod/scripts/quests.lua: the REAL W.rows over fake UE4SS objects (TArray / TMap with
-- ForEach + :get(), FText as strings), the summary, the read tool and the get_state extras.
-- Run:  lua client_mod/tests/test_quests.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end

local function uobj(full, props)
    props = props or {}
    return setmetatable({}, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "GetFullName" then return function() return full end end
        if k == "HasAnyInternalFlags" then return function() return false end end
        return props[k]
    end })
end
local function wrap(v) return { get = function() return v end } end
local function arr(list) return { ForEach = function(_, fn) for i, e in ipairs(list) do if fn(i, wrap(e)) then break end end end } end
local function map(pairs_list) return { ForEach = function(_, fn) for _, kv in ipairs(pairs_list) do if fn(wrap(kv[1]), wrap(kv[2])) then break end end end } end

local function quest(name, main, objectives)
    local o = {}
    for _, x in ipairs(objectives) do o[#o + 1] = { x[1], { Description = x[2], SubobjectiveDescription = x[3], Hint = x[4] } } end
    return uobj("QuestData /Game/Quests/Q_" .. name:gsub("%W", "") .. ".Q_" .. name:gsub("%W", ""),
                { QuestName = name, QuestDescription = name .. " desc", bIsMainQuest = main, Objectives = map(o) })
end
local Q1 = quest("Rune Mysteries", true, { { "Objective1", "Speak to Zanik", nil, "East of Vannaka" }, { "Objective2", "Gather 50 Ash Logs", "0/50", "Chop ash trees" } })
local Q2 = quest("Goblin Diplomacy", false, { { "Objective1", "Speak to Zanik on the ridge" } })
local Q3 = quest("Ratcatcher", true, { { "Done", "Done" } })

local QUESTS
local PC = uobj("BP_PlayerController_C /Game/PC_1", { QuestProgressComponent = setmetatable({}, { __index = function(_, k)
    if k == "IsValid" then return function() return true end end
    if k == "GetFullName" then return function() return "QuestProgressComponent /Game/PC_1.QPC" end end
    if k == "Quests" then return arr(QUESTS) end
end }) })

local Qm = assert(loadfile(root .. "/client_mod/scripts/quests.lua"))()
Qm.W.pc = function() return PC end

QUESTS = {
    { Data = Q1, State = 1, CurrentObjective = "Objective2", QuestInts = arr({ { QuestIntName = "AshLogs", QuestIntValue = 12 } }),
      QuestBools = arr({ { QuestBoolName = "HasSpokeToZanik", bQuestBoolValue = true } }) },
    { Data = Q2, State = 0, CurrentObjective = "None", QuestInts = arr({}), QuestBools = arr({}) },
    { Data = Q3, State = 2, CurrentObjective = "Done", QuestInts = arr({}), QuestBools = arr({}) },
}

local rows = Qm.W.rows(PC)
check("rows read through TArray/TMap wrappers", rows and #rows == 3, rows and #rows)
check("state mapped", rows[1].state == "given" and rows[2].state == "ungiven" and rows[3].state == "complete")
check("current step in the game's own words", rows[1].objective == "Gather 50 Ash Logs" and rows[1].sub == "0/50" and rows[1].hint == "Chop ash trees", rows[1].objective)
check("quest ints read", rows[1].ints.AshLogs == 12)
check("no objective for an ungiven quest (key None)", rows[2].objective == nil)

local r = Qm.HANDLERS.quests(nil, {})
check("tool: active quest with step", r.ok and #r.data.active == 1 and r.data.active[1].quest == "Rune Mysteries" and r.data.active[1].step == "Gather 50 Ash Logs")
check("tool: counters shown", r.data.active[1].counters and r.data.active[1].counters.AshLogs == 12)
check("tool: completed listed", r.data.complete[1] == "Ratcatcher")
check("tool: ungiven hidden by default", r.data.ungiven == nil and r.data.counts.ungiven == 1)
r = Qm.HANDLERS.quests(nil, { all = true })
check("tool all: ungiven listed", r.data.ungiven and r.data.ungiven[1] == "Goblin Diplomacy")

Qm._reset_cache()
local ex = Qm.state_extras({ now = function() return 1 end })
check("extras: quests in get_state", ex.quests and ex.quests.active[1].quest == "Rune Mysteries")
QUESTS[1].CurrentObjective = "Objective1"
check("extras cached for ttl", Qm.state_extras({ now = function() return 2 end }).quests.active[1].step == "Gather 50 Ash Logs")
check("extras refresh after ttl", Qm.state_extras({ now = function() return 10 end }).quests.active[1].step == "Speak to Zanik")
-- an action that ended may have moved a quest on (a talk, a kill, a craft): the state after it is read anew
QUESTS[1].CurrentObjective = "Objective2"
check("extras: still the kept copy inside the ttl", Qm.state_extras({ now = function() return 11 end }).quests.active[1].step == "Speak to Zanik")
check("extras: an action's end is told to the module", type(Qm.action_ended) == "function")
if Qm.action_ended then Qm.action_ended("talk") end
check("extras: read anew after an action ended", Qm.state_extras({ now = function() return 11 end }).quests.active[1].step == "Gather 50 Ash Logs",
    Qm.state_extras({ now = function() return 11 end }).quests.active[1].step)
QUESTS[1].CurrentObjective = "Objective1"
Qm._reset_cache()

_G.DW_PAUSE = true
check("paused: no reads", Qm.HANDLERS.quests(nil, {}).reason == "companion_down")
_G.DW_PAUSE = nil
local PC0 = Qm.W.pc
Qm.W.pc = function() return nil end
check("no controller: state_unavailable", Qm.HANDLERS.quests(nil, {}).reason == "state_unavailable")
Qm.W.pc = PC0

-- the game's quest map markers (live 2026-11-01: Windmill_Area_FTUE_RC, an 80 m area for Ratcatcher)
check("marker name: the game's codes dropped", Qm.marker_name("Windmill_Area_FTUE_RC") == "Windmill Area"
    and Qm.marker_name("Vannaka_NPC_FTUE_RC") == "Vannaka" and Qm.marker_name("TribeA.Taskgiver1") == "Tribe A Taskgiver1")
local wb = Qm.where_by_quest({ { quest = "Ratcatcher", key = "Windmill_Area_FTUE_RC", kind = "area", radius_m = 80, xy = { 156.1, 1713.4 }, distance_m = 60 },
                               { quest = "Ratcatcher", key = "Vannaka_NPC_FTUE_RC", kind = "npc", radius_m = 0, position = { 152.5, 1787.1, -24.4 }, distance_m = 20 } })
check("where: nearest first, inside an area, xy only without a ground height", wb.Ratcatcher[1].name == "Vannaka"
    and wb.Ratcatcher[2].inside == true and wb.Ratcatcher[2].xy and not wb.Ratcatcher[2].position and wb.Ratcatcher[1].radius_m == nil)

-- live 17:2xZ: two quests named "First Steps"; the finished one's marker must not show under the new one
local fs = Qm.where_by_quest({ { quest = "First Steps", asset = "Q_FS1", key = "Doric_Objective_FTUE", kind = "target", position = { 109, 1848, -32 }, distance_m = 19 },
                               { quest = "First Steps", asset = "Q_FS2", key = "Objective", kind = "target", position = { 485, 1776, -35 }, distance_m = 397 } })
check("where: keyed by quest asset", #fs.Q_FS2 == 1 and fs.Q_FS2[1].distance_m == 397 and fs.Q_FS1[1].name == "Doric Objective")
local sm = Qm.summary({ { quest = "First Steps", asset = "Q_FS1", state = "complete" }, { quest = "First Steps", asset = "Q_FS2", state = "given", objective = "Speak to the Wise Old Man" } }, { where = fs })
check("summary: the active quest gets only its own markers", sm.active[1].where and #sm.active[1].where == 1 and sm.active[1].where[1].distance_m == 397)

-- live: First Steps' only marker "WOM_Objective_FTUE_GS" read "Objective"; the step spells the code out
check("expand: a code from the initials of the step's capitalised words",
    Qm.expand("WOM", "Speak to the Wise Old Man by the temple.") == "Wise Old Man" and Qm.expand("GS", "Speak to Doric") == nil
    and Qm.expand("WOM", "Speak to the wise old man") == nil)
local wom = Qm.where_by_quest({ { quest = "First Steps", asset = "Q_GS", key = "WOM_Objective_FTUE_GS", kind = "target", position = { 61.1, 1874.2, -4.4 }, distance_m = 5 } })
local smw = Qm.summary({ { quest = "First Steps", asset = "Q_GS", state = "given", objective = "Speak to the Wise Old Man." } }, { where = wom })
check("summary: a marker's abbreviated NPC is named from the step, no raw codes shown",
    smw.active[1].where[1].name == "Wise Old Man Objective" and smw.active[1].where[1].codes == nil, smw.active[1].where[1].name)
local smd = Qm.summary({ { quest = "Ratcatcher", state = "given", objective = "Kill rats near the windmill." } },
    { where = Qm.where_by_quest({ { quest = "Ratcatcher", key = "Windmill_Area_FTUE_RC", kind = "area", radius_m = 80, position = { 156.1, 1713.4, -3.5 }, distance_m = 76 } }) })
check("summary: a marker with no abbreviation keeps its name", smd.active[1].where[1].name == "Windmill Area")

check("manifest read tool", Qm.MANIFEST.quests.kind == "read" and Qm.MANIFEST.quests.llm)
local src = assert(io.open(root .. "/client_mod/scripts/quests.lua", "rb")):read("*a"):gsub("%-%-[^\n]*", "")
check("no quest/NPC names in logic", not src:find("Zanik", 1, true) and not src:find("Rune Mysteries", 1, true))

print(string.format("test_quests: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
