-- Offline tests for client_mod/scripts/input.lua: the modal gate (build review finding 4) and the orphan
-- cleanup (finding 5), over fake UE objects. Run: lua client_mod/tests/test_input.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local function uobj(full, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    return t
end
local W = { mode = 0, open = nil, injected = {}, closes = 0, input_mode = "DIM_Gameplay" }
local cancel = uobj("InputAction /Game/IA_Building_Cancel.IA_Building_Cancel")
local attack = uobj("InputAction /Game/IA_PrimaryAction.IA_PrimaryAction")
local bm = uobj("BuildModeComponent /Game/L.L:PersistentLevel.PC.BuildModeComponent", { CancelAction = cancel })
setmetatable(bm, { __index = function(_, k) if k == "CurrentBuildMode" then return W.mode end end })
local modes = {}
local function mode_obj(n) modes[n] = modes[n] or uobj("InputModeData /Game/" .. n .. "." .. n); return modes[n] end
local pc = uobj("BP_PlayerController_C /Game/L.L:PersistentLevel.BP_PlayerController_C_1", {
    IsLocalController = function() return true end, BuildModeComponent = bm })
setmetatable(pc, { __index = function(_, k) if k == "CurrentInputMode" then return mode_obj(W.input_mode) end end })
local chest = uobj("BP_Chest_C /Game/L.L:PersistentLevel.BP_Chest_C_7")
local chest_inv = uobj("InventoryComponent /Game/L.L:PersistentLevel.BP_Chest_C_7.Inventory", { GetOwner = function() return chest end })
local wapi = uobj("WorldActorInventoryUIAPI /Engine/Transient.WorldActorInventoryUIAPI_1", {
    CloseCurrentInventory = function() W.closes = W.closes + 1; W.open = nil end })
setmetatable(wapi, { __index = function(_, k) if k == "InventoryComponent" then return W.open and chest_inv or nil end end })
local uiapi = uobj("InventoryUIAPI /Engine/Transient.InventoryUIAPI_1", { PlayerController = pc, WorldInventoryAPI = wapi })
local eis = uobj("EnhancedInputLocalPlayerSubsystem /Engine/Transient.EIS", {
    InjectInputVectorForAction = function(_, a) W.injected[#W.injected + 1] = a; if a == cancel then W.mode = math.max(0, W.mode - 1) end end })
function FindAllOf(cls)
    if cls == "BP_PlayerController_C" then return { pc } end
    if cls == "InventoryUIAPI" then return { uiapi } end
    return {}
end
function FindFirstOf(cls) if cls == "EnhancedInputLocalPlayerSubsystem" then return eis end end
function StaticFindObject() return nil end

_G.DWInput = nil
local I = assert(loadfile(root .. "/client_mod/scripts/input.lua"))()
local T = 0
I.clock = function() return T end

-- 1. gameplay: nothing blocks; inject goes out
check("no modal: gate open", I.gate() == nil)
local ok = I.inject(attack)
check("no modal: injected", ok and W.injected[#W.injected] == attack)

-- 2. build mode Placement: the attack click is the place click -> refused; build's own presses allowed
W.mode, W.injected = 2, {}
I.claim("build", "build:job1")
local okb, m = I.inject(attack)
check("Placement: reflex attack refused (never a stray place)", okb == false and m and m.kind == "build" and m.mode == "Placement" and #W.injected == 0,
    m and m.kind)
local own = I.inject(attack, nil, { modal = "build" })
check("Placement: build's own press allowed", own and #W.injected == 1)

-- 3. container screen open: refused; owner allowed
W.mode, W.open, W.injected = 0, true, {}
I.claim("container", "store")
okb, m = I.inject(attack)
check("chest open: refused, names the chest", okb == false and m.kind == "container" and m.owner == "BP_Chest_C_7" and #W.injected == 0)

-- 4. orphans: a modal with no owner for >= 1 s is cleaned up; owned ones never
I.release("container")
T = 10; I.gate()
check("orphan container: not closed before 1 s", W.closes == 0)
T = 11.2; I.gate()
check("orphan container: closed after 1 s", W.closes == 1 and W.open == nil)
W.mode, W.injected = 2, {}
T = 20; I.gate() -- build still owned by job1
T = 30; I.gate()
check("owned build mode: never touched", #W.injected == 0)
I.release("build")
T = 31; I.gate(); T = 32.1; I.gate()
check("orphan build mode: one Cancel per orphan_s", #W.injected == 1 and W.injected[1] == cancel and W.mode == 1)
T = 33.2; I.gate()
check("orphan build mode: second Cancel -> None", #W.injected == 2 and W.mode == 0, W.mode)
T = 35; local g = I.gate()
check("after cleanup: gate open again", g == nil)

-- 5. bounded: a mode that never leaves gets at most cfg.cancels presses, then is reported stuck
W.mode, W.injected = 3, {}
local c0 = cancel
bm.CancelAction = uobj("InputAction /Game/IA_Dead.IA_Dead") -- a cancel that does nothing
for i = 1, 12 do T = 40 + i * 1.1; I.gate() end
check("stuck modal: bounded presses, reported", #W.injected == I.cfg.cancels and I.status().stuck == "build", #W.injected)
bm.CancelAction, W.mode = c0, 0
T = 60; I.gate()

-- 6. a non-gameplay input mode (spell placement, Oculus build menu) blocks too; its owner passes modal="mode"
W.input_mode, W.injected = "DIM_SpellPlacementMode", {}
okb, m = I.inject(attack)
check("spell placement mode: reflex attack refused", okb == false and m.kind == "mode" and m.mode == "DIM_SpellPlacementMode")
check("spell owner may press", I.inject(attack, nil, { modal = "mode" }) == true)
W.input_mode = "DIM_OculusBuildMenu"
check("Oculus build menu blocks", (I.gate() or {}).mode == "DIM_OculusBuildMenu")
T = 70; I.gate(); T = 75; I.gate()
check("an input mode is never 'cleaned up' by guessing", #W.injected == 1)
W.input_mode = "DIM_Gameplay"
-- 6a. a gameplay VARIANT (lock-on, live skill_routes 2026-10-26) is gameplay: nothing blocks, a lookalike prefix does
W.input_mode, W.injected = "DIM_Gameplay_LockOnTargeting", {}
check("lock-on mode: no modal", I.modal() == nil and I.gate() == nil)
check("lock-on mode: a reflex attack goes out", I.inject(attack) == true)
W.input_mode = "DIM_GameplayMenu"
check("a lookalike (DIM_GameplayMenu) still blocks", (I.gate() or {}).kind == "mode")
check("is_gameplay_mode", I.is_gameplay_mode("DIM_Gameplay") and I.is_gameplay_mode("DIM_Gameplay_X") and not I.is_gameplay_mode(nil)
      and not I.is_gameplay_mode("DIM_SpellcastingMode"))
W.input_mode = "DIM_Gameplay"

-- 6b. a conversation is its own kind: spells' "mode" doesn't pass it; talk's "conversation" does
W.input_mode, W.injected = "DIM_ConversationUI", {}
okb, m = I.inject(attack, nil, { modal = "mode" })
check("conversation: a cast (modal=mode) is refused", okb == false and m.kind == "conversation")
check("conversation: talk's own press passes", I.inject(attack, nil, { modal = "conversation" }) == true)
W.input_mode = "DIM_Gameplay"

-- 6c. an orphan conversation: talk is consulted ONLY when enabled; the sweep is never re-entered
do
    local calls, depth, maxdepth = 0, 0, 0
    local talk = { sweep_orphan = function()
        calls = calls + 1
        depth = depth + 1; maxdepth = math.max(maxdepth, depth)
        I.inject(cancel) -- a sweep that presses through the gate (the v2 recursion)
        depth = depth - 1
    end }
    _G.__dwc_bridge = { module = { API = { module = function(n) if n == "talk" then return talk end end } } }
    I.release("conversation")
    W.input_mode = "DIM_ConversationUI"
    T = 200; I.gate(); T = 202; I.gate()
    check("talk absent from the sweep while DW_ENABLE_TALK is off", calls == 0)
    _G.DW_ENABLE_TALK = true
    T = 204; I.gate(); T = 206; I.gate()
    check("enabled: talk.sweep_orphan called, never recursively", calls >= 1 and maxdepth == 1, tostring(calls) .. "/" .. tostring(maxdepth))
    _G.DW_ENABLE_TALK, _G.__dwc_bridge = nil, nil
    W.input_mode = "DIM_Gameplay"
    check("gate still works after", I.gate() == nil)
end

-- 6d. talk disabled (V2): an orphan conversation is left with the panel's own Cancel (bounded, counted per press)
do
    local part = uobj("ConversationParticipantComponent /Game/L.L:PersistentLevel.PC.Participant")
    local conv_cancel = uobj("InputAction /Game/IA_Conversation_Cancel.IA_Conversation_Cancel")
    pc.ConversationComponent = { DomConversationParticipant = part }
    local panel = uobj("ConversationMainPanel /Engine/Transient.ConversationMainPanel_1", { DomConversationParticipant = part, CancelInputAction = conv_cancel })
    local fa0 = FindAllOf
    FindAllOf = function(c) if c == "ConversationMainPanel" then return { panel } end return fa0(c) end
    local presses = 0
    local inj0 = eis.InjectInputVectorForAction
    eis.InjectInputVectorForAction = function(_, a)
        W.injected[#W.injected + 1] = a
        if a == conv_cancel then presses = presses + 1; if presses >= 2 then W.input_mode = "DIM_Gameplay" end end
    end
    _G.DWInput = nil
    I = assert(loadfile(root .. "/client_mod/scripts/input.lua"))()
    I.clock = function() return T end
    W.input_mode, W.injected = "DIM_ConversationUI", {}
    for i = 1, 10 do T = 300 + i * 1.1; I.gate() end
    check("talk off: orphan conversation left with the panel's own Cancel, then the gate opens", presses == 2 and I.gate() == nil, presses)
    -- the real leave step used by interact
    W.input_mode = "DIM_ConversationUI"
    check("leave_conversation_step presses the panel's Cancel", I.leave_conversation_step() == true and W.injected[#W.injected] == conv_cancel)
    W.input_mode = "DIM_Gameplay"
    check("leave_conversation_step: nothing open -> no press", I.leave_conversation_step() == false)
    FindAllOf, eis.InjectInputVectorForAction = fa0, inj0
end

-- 7. pause: no game call at all
_G.DW_PAUSE = true
W.mode, W.injected = 2, {}
local gp = I.gate()
local okp = I.inject(attack)
check("paused: gate says paused, nothing injected or read", gp.kind == "paused" and okp == false and #W.injected == 0)
_G.DW_PAUSE = nil

print(string.format("%d passed, %d failed", pass, failn))
os.exit(failn == 0 and 0 or 1)
