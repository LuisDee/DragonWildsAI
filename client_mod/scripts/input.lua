-- input: the shared gameplay-input layer and the MODAL GATE (build review 2026-10-26, finding 4).
--
-- The stray-input hazard: while the game's build mode is open (BuildModeComponent.CurrentBuildMode ~= None)
-- the attack click is the PLACE click, so a reflex's IA_PrimaryAction would place the selected piece wherever
-- the camera points and spend materials; while a container's screen is open (the HUD's world inventory), item
-- use and the interact key act on that screen. So:
--   * every module that injects gameplay input (combat, defence and the stay-fed reflex, skills' interact,
--     build, spells) asks M.gate() first, or injects through M.inject(action, vec, opts), which refuses
--     while a modal is open unless opts.modal names that modal (its own owner, e.g. build's B / rotate /
--     place presses while it owns build mode);
--   * the modal's owner registers with M.claim(kind, owner) and M.release(kind); its arbiter on_suspend /
--     on_stop leaves the mode at once (build.lua, skills store/take);
--   * a modal nobody owns (an owner that died, a bridge restart, a pause) is cleaned up once it has been
--     seen unowned for cfg.orphan_s (1 s): build mode -> Cancel (one per orphan_s, read back, at most 3);
--     a container screen -> WorldActorInventoryUIAPI:CloseCurrentInventory (its own close).
--   * a non-gameplay input mode (PC.CurrentInputMode ~= DIM_Gameplay: the spell wheel / placement,
--     DIM_OculusBuildMenu) also blocks: there the attack click casts or places. Its owner (spells) passes
--     opts.modal = "mode"; nothing here exits it.
--   * a conversation (DIM_ConversationUI) is its own kind, "conversation" (owner talk.lua, opts.modal =
--     "conversation"): spells' "mode" does not pass it. An orphan is handed to talk.sweep_orphan.
-- Never any game call under DW_PAUSE (gate answers "paused"; nothing is read or pressed).
-- Reads are cached (the player controller, the HUD API objects, the input subsystem) and re-validated per
-- call: no find_all per check (review finding 10).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }
M.cfg = { orphan_s = 1.0, cancels = 3 }
M.BUILD_MODE = { [0] = "None", "Selection", "Placement", "RepairAndEdit" }

local function paused() return rawget(_G, "DW_PAUSE") == true end
local function st()
    local s = rawget(_G, "DWInput")
    if type(s) ~= "table" then s = { owners = {}, orphan_since = {}, cleanups = 0, refused = 0 }; _G.DWInput = s end
    return s
end
M.clock = function() return os.clock() end -- tests replace it

-- ------------------------------------------------------------------ cached handles
local function cached(key, find)
    local s = st()
    local o = s[key]
    if o ~= nil and U.valid(o) then return o end
    o = find()
    s[key] = o
    return o
end
function M.pc()
    return cached("pc", function()
        for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
            if U.try(function() return pc:IsLocalController() end) == true then return pc end
        end
    end)
end
function M.eis() return cached("eis", function() return U.find_first("EnhancedInputLocalPlayerSubsystem") end) end
function M.inventory_ui()
    return cached("inv_ui", function()
        local pc = M.pc()
        for _, a in ipairs(U.find_all("InventoryUIAPI", { skip_defaults = true })) do
            local apc = U.try(function() return a.PlayerController end)
            if not pc or (U.valid(apc) and U.short(apc) == U.short(pc)) then return a end
        end
    end)
end

-- ------------------------------------------------------------------ the modals
-- Build mode: "None" | "Selection" | "Placement" | "RepairAndEdit" | nil (unreadable)
function M.build_mode()
    if paused() then return nil end
    local pc = M.pc()
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    if not U.valid(bm) then return nil end
    local v = U.try(function() return bm.CurrentBuildMode end)
    return M.BUILD_MODE[tonumber(v) or -1] or (v ~= nil and tostring(v) or nil)
end
-- The open container screen: {inv, owner (actor id), api} | nil
function M.world_inventory()
    if paused() then return nil end
    local ui = M.inventory_ui()
    local w = ui and U.try(function() return ui.WorldInventoryAPI end)
    local inv = U.valid(w) and U.try(function() return w.InventoryComponent end)
    if not U.valid(inv) then return nil end
    local owner = U.try(function() return inv:GetOwner() end)
    return { inv = inv, owner = U.valid(owner) and U.short(owner) or nil, api = w }
end

-- The PC's input mode data asset (DIM_Gameplay, DIM_SpellcastingMode, DIM_SpellPlacementMode,
-- DIM_OculusBuildMenu, ...): the game's own "which controls are live" switch. Anything but gameplay means
-- the attack click does something else (casts, places, picks a menu entry).
M.GAMEPLAY_MODE = "DIM_Gameplay"
function M.input_mode()
    if paused() then return nil end
    local pc = M.pc()
    return pc and U.short(U.try(function() return pc.CurrentInputMode end)) or nil
end

-- Which modal is open now: nil | {kind = "build", mode} | {kind = "container", owner} |
-- {kind = "mode", mode = DIM_...} (a non-gameplay input mode: spell wheel/placement, Oculus) | {kind = "paused"}
function M.modal()
    if paused() then return { kind = "paused" } end
    local mode = M.build_mode()
    if mode and mode ~= "None" then return { kind = "build", mode = mode } end
    local wi = M.world_inventory()
    if wi then return { kind = "container", owner = wi.owner } end
    local im = M.input_mode()
    if im and im:find("Conversation", 1, true) then
        -- a conversation (DIM_ConversationUI): its own kind, owned by talk.lua; a cast's number keys or an
        -- attack click would answer the NPC (talk review finding 7)
        local pc = M.pc()
        local npc = pc and U.short(U.try(function() return pc.ConversationComponent.CurrentNPC end))
        return { kind = "conversation", mode = im, npc = npc }
    end
    if im and im ~= M.GAMEPLAY_MODE then return { kind = "mode", mode = im } end
    return nil
end

-- ------------------------------------------------------------------ owners and orphan cleanup
function M.claim(kind, owner) st().owners[kind] = { owner = owner or "?", at = M.clock() } end
function M.release(kind) st().owners[kind] = nil end
function M.owner(kind) return st().owners[kind] end

-- One Cancel toward leaving build mode, as a player presses Esc (Cancel may step Placement -> Selection ->
-- None, so callers read the mode back NEXT tick and call again, at most cfg.cancels times; input lands on the
-- next frame, never within this call). `press(action)` injects one frame. -> the mode read before the press
function M.leave_build_step(press)
    if paused() then return nil end
    local mode = M.build_mode()
    if mode == "None" or mode == nil then return mode end
    local pc = M.pc()
    local bm = pc and U.try(function() return pc.BuildModeComponent end)
    local cancel = U.valid(bm) and U.try(function() return bm.CancelAction end)
    if U.valid(cancel) then if press then press(cancel) else M.raw_inject(cancel) end end
    return mode
end
function M.close_container()
    if paused() then return false end
    local wi = M.world_inventory()
    if not wi then return true end
    return pcall(function() wi.api:CloseCurrentInventory() end)
end

-- One exit step for a build or container modal, OWNED OR NOT: the stay-fed reflex's safety floor (live
-- 2026-10-26 14:59: a build screen blocked the drink near hydration 0). Survival beats any build/store job:
-- that job's own read-back sees the screen gone and fails truthfully. Conversations and input modes are left
-- to their owners (no generic exit here). -> true when a press/close went out
function M.leave_modal_step(m)
    if paused() or type(m) ~= "table" then return false end
    if m.kind == "build" then return M.leave_build_step() ~= nil end
    if m.kind == "container" then return M.close_container() == true end
    return false
end

-- The conversation panel's own Cancel (ConversationMainPanel.CancelInputAction, the panel of THIS player's
-- participant), cached and re-validated. One press per call; the caller reads back next tick.
-- -> true when a press went out (a conversation was open), false when none is open / no key
function M.leave_conversation_step(press)
    if paused() then return false end
    local m = M.modal()
    if not (m and m.kind == "conversation") then return false end
    local pc = M.pc()
    local part = pc and U.try(function() return pc.ConversationComponent.DomConversationParticipant end)
    local pshort = U.valid(part) and U.short(part) or nil
    local s = st()
    local panel = s.conv_panel
    if not (panel and U.valid(panel)) then
        panel = nil
        for _, p in ipairs(U.find_all("ConversationMainPanel", { skip_defaults = true }) or {}) do
            local pp = U.try(function() return p.DomConversationParticipant end)
            if not pshort or (U.valid(pp) and U.short(pp) == pshort) then panel = p; break end
        end
        s.conv_panel = panel
    end
    local cancel = panel and U.try(function() return panel.CancelInputAction end)
    if not U.valid(cancel) then return false end
    if press then press(cancel) else M.raw_inject(cancel) end
    return true
end

-- A modal open with no live owner for cfg.orphan_s is cleaned up (a dead job, a bridge restart, a pause):
-- one step per orphan_s, at most cfg.cancels steps per episode, then it is left alone and reported.
-- A conversation: talk.lua's sweep when talk is enabled (a try counts only when IT pressed Cancel; talk review
-- V1), else our own panel Cancel, so a dialogue can never strand him (V2).
local function sweep(m)
    local s = st()
    s.orphan_tries = s.orphan_tries or {}
    if not m or m.kind == "paused" then s.orphan_since, s.orphan_tries = {}, {}; return end
    if s.owners[m.kind] then s.orphan_since[m.kind], s.orphan_tries[m.kind] = nil, nil; return end
    if m.kind == "mode" then return end -- an input mode has no generic exit here: block and report, never guess
    local t = M.clock()
    s.orphan_since[m.kind] = s.orphan_since[m.kind] or t
    if t - s.orphan_since[m.kind] < M.cfg.orphan_s then return end
    if (s.orphan_tries[m.kind] or 0) >= M.cfg.cancels then s.stuck = m.kind; return end
    s.orphan_since[m.kind] = t
    if m.kind == "conversation" then
        local inst = rawget(_G, "__dwc_bridge")
        local api = inst and inst.module and inst.module.API
        local talk = rawget(_G, "DW_ENABLE_TALK") == true and api and api.module("talk") or nil
        if talk and type(talk.sweep_orphan) == "function" then
            local ok, r = pcall(talk.sweep_orphan)
            if ok and type(r) == "table" and r.state == "cancel_pressed" then
                s.orphan_tries[m.kind] = (s.orphan_tries[m.kind] or 0) + 1
                s.cleanups = s.cleanups + 1
            end
        elseif M.leave_conversation_step() then
            s.orphan_tries[m.kind] = (s.orphan_tries[m.kind] or 0) + 1
            s.cleanups = s.cleanups + 1
        end
        return
    end
    s.orphan_tries[m.kind] = (s.orphan_tries[m.kind] or 0) + 1
    s.cleanups = s.cleanups + 1
    if m.kind == "build" then M.leave_build_step() else M.close_container() end
end
M._sweep = sweep

-- ------------------------------------------------------------------ the gate + injection
-- nil = gameplay input may go out now; else {kind, mode/owner} = the modal that blocks it.
-- opts.modal = the kind the caller owns ("build" / "container"): that one does not block it.
function M.gate(opts)
    local m = M.modal()
    local s = st()
    if not s.sweeping then -- re-entrancy guard: a sweep's own presses go through gate() again
        s.sweeping = true
        local ok, err = pcall(sweep, m)
        s.sweeping = false
        if not ok then s.sweep_error = tostring(err) end
    end
    if not m then return nil end
    if opts and opts.modal and opts.modal == m.kind then return nil end
    st().refused = st().refused + 1
    return m
end

function M.raw_inject(action, vec)
    if paused() then return false end
    local s = M.eis()
    if not (s and U.valid(action)) then return false end
    local v = vec or { X = 1.0, Y = 0.0, Z = 0.0 }
    return pcall(function() s:InjectInputVectorForAction(action, { X = v.X or 0, Y = v.Y or 0, Z = v.Z or 0 }, {}, {}) end)
end
-- One frame of an Enhanced Input action, unless a modal blocks it. -> ok, blocked_by (modal table)
function M.inject(action, vec, opts)
    local m = M.gate(opts)
    if m then return false, m end
    return M.raw_inject(action, vec) == true, nil
end

function M.status()
    local s = st()
    local owners = {}
    for k, v in pairs(s.owners) do owners[k] = v.owner end
    return { modal = M.modal(), owners = owners, cleanups = s.cleanups, refused = s.refused, stuck = s.stuck }
end
M.HANDLERS = { input_status = function() return { ok = true, data = M.status() } end }

return M
