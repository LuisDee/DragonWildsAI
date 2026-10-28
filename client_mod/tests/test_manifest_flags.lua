-- Which module tools are offered to the model (llm) and how the bridge treats them (action = kind action + moves).
-- A tool is offered only after a live verification (main, 2026-10-26). Run: lua client_mod/tests/test_manifest_flags.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end
function FindAllOf() return {} end
function FindFirstOf() return nil end
function StaticFindObject() return nil end
local function load(n) return assert(loadfile(root .. "/client_mod/scripts/" .. n .. ".lua"))() end
local function entry(mod, tool) local m = load(mod); return m.MANIFEST and m.MANIFEST[tool] end
local want = {
    { "build", "build", true, "action" }, { "build", "buildables", true, "read" },
    { "quests", "quests", true, "read" },
    -- Lodestone staging: two native component controls passed; full compound proof is pending.
    -- All model launches remain forbidden until that proof passes on the final deployed code.
    { "lodestone", "teleport", true, "action" }, { "lodestone", "lodestones", true, "read" },
    { "shoot", "shoot", false, "action" },
}
for _, w in ipairs(want) do
    local e = entry(w[1], w[2])
    check(w[1] .. "." .. w[2] .. " llm=" .. tostring(w[3]) .. " kind=" .. w[4], e and e.llm == w[3] and e.kind == w[4],
        e and (tostring(e.llm) .. "/" .. tostring(e.kind)) or "missing")
    if e and w[4] == "action" then check(w[2] .. " moves (bridge action tool)", e.moves == true) end
end
-- every module listed in the bridge is one of client_mod/scripts
local src = assert(io.open(root .. "/client_mod/scripts/client_bridge.lua", "rb")):read("a")
for _, n in ipairs({ "build", "quests", "lodestone", "shoot", "input" }) do
    check("client_bridge.MODULES lists " .. n, src:find('"' .. n .. '"', 1, true) ~= nil)
end
-- skills.lua's own manifest (source check: skills.lua needs the full fake engine to load)
do
    local s = assert(io.open(root .. "/client_mod/scripts/skills.lua", "rb")):read("a")
    check("skills.collect_water llm=true action moves",
        s:find('collect_water = { kind = "action", llm = true, moves = true', 1, true) ~= nil)
end
print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
