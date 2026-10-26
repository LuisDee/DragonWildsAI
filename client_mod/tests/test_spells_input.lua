-- Integration test: the REAL client_mod/scripts/input.lua (the modal gate) + the REAL spells.lua W.inject
-- path, over fake UE objects (BUGS L30: input.lua's gate silently blocked every wheel press after Q, and
-- test_spells could not see it because it stubs W.inject). A fake game reacts to the injected actions:
-- Q opens the wheel (DIM_RadialMenu), a quick key selects (instant: cast; placed: placement mode), LMB
-- places. Reverse cases: a build-mode modal and an open container screen block the very first press.
-- Run: lua client_mod/tests/test_spells_input.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local ROOT = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local function uobj(full, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    t.HasAnyInternalFlags = function() return false end
    return t
end

-- ---------------------------------------------------------------- the fake game (input side is real)
local G
local modes = {}
local function mode_obj(n) modes[n] = modes[n] or uobj("InputModeData /Game/" .. n .. "." .. n); return modes[n] end
local bm = uobj("BuildModeComponent /Game/L.L:PersistentLevel.PC.BuildModeComponent", {})
setmetatable(bm, { __index = function(_, k) if k == "CurrentBuildMode" then return G.build end end })
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1", {
    IsLocalController = function() return true end, BuildModeComponent = bm })
setmetatable(pc, { __index = function(_, k) if k == "CurrentInputMode" then return mode_obj(G.mode) end end })
local chest = uobj("BP_Chest_C /Game/L.L:PersistentLevel.BP_Chest_C_7")
local chest_inv = uobj("InventoryComponent /Game/L.L:PersistentLevel.BP_Chest_C_7.Inventory", { GetOwner = function() return chest end })
local wapi = uobj("WorldActorInventoryUIAPI /Engine/Transient.WorldActorInventoryUIAPI_1", { CloseCurrentInventory = function() G.container = false end })
setmetatable(wapi, { __index = function(_, k) if k == "InventoryComponent" then return G.container and chest_inv or nil end end })
local uiapi = uobj("InventoryUIAPI /Engine/Transient.InventoryUIAPI_1", { PlayerController = pc, WorldInventoryAPI = wapi })

local function act(n) return uobj("InputAction /Game/Gameplay/Inputs/Actions/" .. n .. "." .. n, { n = n }) end
local ACTS = { menu = act("IA_SpellMenu"), place = act("IA_Spellcasting_PlaceSpell"), cancel = act("IA_Spellcasting_Cancel"),
               next_page = act("IA_SpellsMenu_SwitchRadialRight"), prev_page = act("IA_SpellsMenu_SwitchRadialLeft"),
               accept = act("IA_SpellsMenu_AcceptSelection"), quick = {} }
for i = 0, 7 do ACTS.quick[i + 1] = act("IA_Spellcasting_QuickAccess" .. i) end

local T = 0
local function at(dt, fn) G.sched[#G.sched + 1] = { t = T + dt, fn = fn } end
local function tick()
    local keep = {}
    for _, s in ipairs(G.sched) do if T >= s.t then s.fn() else keep[#keep + 1] = s end end
    G.sched = keep
end
local AIR, EARTH = "ITEM_Rune_Air", "ITEM_Rune_Earth"
local SPELLS = {
    USD_Windstep = { asset = "USD_Windstep", name = "Windstep", cast_type = 0, cooldown_s = 3, icon = "T_W", desc = "Jump higher.",
                     cost = { { item = AIR, name = "Air Rune", count = 5 } }, perk = { level = 1 } },
    USD_SummonShelter = { asset = "USD_SummonShelter", name = "Summon Shelter", cast_type = 1, cooldown_s = 15, icon = "T_S", desc = "A bed.",
                          cost = { { item = EARTH, name = "Earth Rune", count = 10 } }, perk = { level = 1 } },
}
local function effect(s, landed)
    for _, c in ipairs(s.cost) do G.items[c.item] = G.items[c.item] - c.count end
    G.last_cast[s.asset] = 100
    if landed then G.actors["BP_Magic_X_1"] = { class = "BP_Magic_X_C", position = landed } end
end
local eis = uobj("EnhancedInputLocalPlayerSubsystem /Engine/Transient.EIS", {
    InjectInputVectorForAction = function(_, a)
        G.injected[#G.injected + 1] = a.n
        local n = a.n
        if n == "IA_SpellMenu" then
            if G.mode == "DIM_RadialMenu" then G.mode = "DIM_Gameplay" elseif G.mode == "DIM_Gameplay" then at(0.15, function() G.mode = "DIM_RadialMenu" end) end
        elseif n:match("^IA_Spellcasting_QuickAccess") and G.mode == "DIM_RadialMenu" then
            local s = SPELLS[G.wheel[tonumber(n:match("%d+")) + 1]]
            if s.cast_type == 0 then G.mode = "DIM_Gameplay"; at(0.4, function() effect(s) end)
            else G.mode = "DIM_SpellPlacementMode"; G.placing = s end
        elseif n == "IA_Spellcasting_PlaceSpell" and G.mode == "DIM_SpellPlacementMode" then
            G.mode = "DIM_Gameplay"; local aim = G.aimed or { 3, 0, 0 }
            at(0.5, function() effect(G.placing, { aim[1], aim[2], 0 }) end)
        elseif n == "IA_Spellcasting_Cancel" then
            if G.mode ~= "DIM_RadialMenu" then G.mode = "DIM_Gameplay" end
        end
    end })
function FindAllOf(cls)
    if cls == "BP_PlayerController_C" then return { pc } end
    if cls == "InventoryUIAPI" then return { uiapi } end
    return {}
end
function FindFirstOf(cls) if cls == "EnhancedInputLocalPlayerSubsystem" then return eis end end
function StaticFindObject() return nil end

-- ---------------------------------------------------------------- the real modules
_G.DWInput = nil
local I = assert(loadfile(ROOT .. "/client_mod/scripts/input.lua"))()
I.clock = function() return T end
local SRC = os.getenv("DW_SPELLS_SRC") or (ROOT .. "/client_mod/scripts/spells.lua")
local SP = assert(loadfile(SRC))()
local W = SP.W
SP.wall = function() return T end
-- the world reads are faked (they are UE reads); W.inject is NOT: it must go through input.lua
W.pc = function() return pc end
W.pawn = function() return {} end
W.static = function(o) return o end
W.all_spells = function() return {} end
W.hooks_start = function() end
W.requirement = function() return nil end
W.own_modes = function() return {} end
W.clock = function() return nil end
W.snapshot = function()
    local s = { wheel = {}, unlocked = {}, objects = {}, items = {}, last_cast = {}, ge = {}, tags = {}, actors = {}, skills = {},
                per_radial = 12, radials = 4, place_max_m = 15, input_mode = G.mode, position = { 0, 0, 0 }, view_target = "BP_PlayerCharacter_C",
                held_effects = {} }
    for i = 1, 48 do s.wheel[i] = G.wheel[i] or false end
    for id, sp in pairs(SPELLS) do s.unlocked[id] = true; s.objects[id] = sp end
    for k, v in pairs(G.items) do s.items[k] = v end
    for k, v in pairs(G.last_cast) do s.last_cast[k] = v end
    for k, v in pairs(G.actors) do s.actors[k] = v end
    return s
end
W.actions = function() return ACTS end
W.shown_icons = function() local o = {}; for i = 1, 12 do local s = SPELLS[G.wheel[i]]; o[i] = s and s.icon or false end; return o end
W.selected = function() return G.placing and G.placing.asset end
W.preview = function() if G.mode ~= "DIM_SpellPlacementMode" then return nil end; local a = G.aimed or { 3, 0, 0 }; return { valid = true, position = { a[1], a[2], 0 } } end
W.spots = function() return { { position = { 4, 0, 0 }, spread_m = 0.1 } } end
W.aim = function(_, p) G.aimed = p; return 5 end
W.cam_dist = function() return 5 end
W.players = function() return {} end
local api = {
    module = function(n) if n == "input" then return I end end,
    fail = function(reason, data) return { ok = false, reason = reason, data = data or {} } end,
    now = function() return T end, log = function() end, my_position = function() return { 0, 0, 0 } end,
    census_things = function() return {} end,
    find_thing = function(id) return nil, { ok = false, reason = "unknown_target", data = { target = id } } end,
}
local function reset(o)
    o = o or {}
    T = 0
    _G.DWSpells, _G.DW_PAUSE, _G.DWArbiter = nil, nil, nil
    SP.mem().roles = {}
    G = { mode = "DIM_Gameplay", build = o.build or 0, container = o.container or false, wheel = { "USD_Windstep", "USD_SummonShelter" },
          items = { [AIR] = 50, [EARTH] = 50 }, last_cast = {}, actors = {}, sched = {}, injected = {} }
end
local function run(args)
    local r = SP.HANDLERS.cast(nil, args, { api = api })
    if not r.wait then return r end
    local w, deadline = r.wait, T + r.wait_s
    for _ = 1, 400 do
        T = T + 0.1
        tick()
        local res = w.poll(w)
        if not res and T >= deadline then res = w.expire(w) end
        if res then return res end
    end
    return { ok = false, reason = "test_hang" }
end
local function inj() return table.concat(G.injected, ",") end

-- 1. instant spell: every press (Q, then the quick key inside the non-gameplay wheel mode) passes the gate
reset()
do
    local res = run({ spell = "Windstep" })
    check("real gate: instant cast goes through (Q, then key 1 inside the wheel mode)", res.ok and res.data.settled == true
        and inj() == "IA_SpellMenu,IA_Spellcasting_QuickAccess0", tostring(res.reason) .. " " .. inj())
end
-- 2. placed spell: Q, key 2, LMB inside the placement mode
reset()
do
    local res = run({ spell = "Summon Shelter" })
    check("real gate: placed cast goes through (Q, key 2, LMB in placement mode)", res.ok
        and inj() == "IA_SpellMenu,IA_Spellcasting_QuickAccess1,IA_Spellcasting_PlaceSpell", tostring(res.reason) .. " " .. inj())
end
-- 3. build mode open: the gate blocks the first press; nothing is injected; the reply says why
reset({ build = 2 })
do
    local res = run({ spell = "Windstep" })
    check("real gate: build-mode modal blocks the cast (nothing injected)", res.ok == false and #G.injected == 0, tostring(res.reason) .. " " .. inj())
    check("real gate: the reply says a modal blocked it", res.reason == "busy" and (res.data.detail or ""):find("build", 1, true) ~= nil, res.data.detail)
end
-- 4. a container screen open: blocked too
reset({ container = true })
do
    local res = run({ spell = "Windstep" })
    check("real gate: an open container screen blocks the cast", res.ok == false and #G.injected == 0 and res.reason == "busy", tostring(res.reason) .. " " .. inj())
end

print(string.format("test_spells_input: %d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
