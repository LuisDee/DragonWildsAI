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
--   * a HUD SCREEN (BUGS B-stuck-focused-ui): a non-gameplay input mode while the game's own
--     InputManagerUIAPI:IsOpen reports one of M.SCREENS (Processing, Inventory, Crafting, Map, ...) is kind
--     "screen". Its opener claims "screen" while it means it to be open (crafting, lodestone). Unclaimed (no
--     owner of ANY kind) for cfg.orphan_s it is closed with the game's own InputManagerUIAPI:CloseWidgetIfOpen;
--     and M.after_action (client_bridge's action finish) closes a stray screen at once when an action ends.
--     Live 2026-10-26: a Campfire craft left Processing(15)+Inventory(11) open -> DIM_FocussedInGameUI for good.
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
-- Gameplay VARIANTS (DIM_Gameplay_<x>, e.g. DIM_Gameplay_LockOnTargeting while locked on: live skill_routes
-- 2026-10-26 15:1x, combat's own lock-on was read as "stuck in a non-gameplay mode") keep the gameplay controls.
function M.is_gameplay_mode(im)
    return type(im) == "string" and (im == M.GAMEPLAY_MODE or im:sub(1, #M.GAMEPLAY_MODE + 1) == M.GAMEPLAY_MODE .. "_")
end
function M.input_mode()
    if paused() then return nil end
    local pc = M.pc()
    return pc and U.short(U.try(function() return pc.CurrentInputMode end)) or nil
end

-- ------------------------------------------------------------------ HUD screens (BUGS B-stuck-focused-ui)
-- EWidgetType values (dump 26161880 Dominion_enums.hpp) that are focused SCREENS: open, they put the PC in a
-- menu input mode (live: Processing 15 + Inventory 11 -> DIM_FocussedInGameUI). Left out on purpose: the HUD
-- itself (Compass, VitalsBars, InteractionPrompt, ...), modes with their own owner/exit (Spellcasting 21,
-- Fishing 35, QuickAccessRadial 39, Emotes 28, Conversation 27, Resting 16), the container path (WorldInventory 26,
-- Container 33: close_container), Building 1 (build.lua) and Pause/Settings/Server (front-end menus).
-- Closed in this ORDER: the station panels first (closing Processing also closes its coupled Inventory, live),
-- Inventory last.
M.SCREENS = { { 15, "Processing" }, { 6, "Crafting" }, { 36, "Runecrafting" }, { 8, "Enchanting" }, { 34, "Composter" },
              { 13, "Map" }, { 12, "Journal" }, { 31, "LorePopup" }, { 30, "Sign" }, { 19, "Skills" }, { 20, "SpellBook" },
              { 41, "QuestList" }, { 37, "AgilityCourseInfo" }, { 29, "TopBarMenu" }, { 5, "CompositeVariableMenu" },
              { 11, "Inventory" } }
-- The menu input modes a screen puts the PC in (the DominionInputMode assets, object dump 26161880). Only these
-- are checked for screens: the spell, build, fishing and radial modes keep kind "mode" (their owners' own exits).
M.SCREEN_MODES = { DIM_FocussedInGameUI = true, DIM_UnfocussedInGameUI = true, DIM_FullScreenUI = true,
                   DIM_FullScreenUIMap = true, DIM_MainInventoryMenu = true, DIM_CraftingMenu = true, DIM_AgilityCourseUI = true }
function M.input_manager()
    return cached("input_mgr", function()
        for _, a in ipairs(U.find_all("InputManagerUIAPI", { skip_defaults = true }) or {}) do return a end
    end)
end
local function screen_open(api, pc, t)
    local ok, v = pcall(function() return api:IsOpen(pc, t) end)
    return ok and v == true
end
-- The screens the game itself says are open: {{type, name}, ...} | nil (no API / paused).
function M.open_screens()
    if paused() then return nil end
    local api, pc = M.input_manager(), M.pc()
    if not (api and pc) then return nil end
    local out = {}
    for _, e in ipairs(M.SCREENS) do
        if screen_open(api, pc, e[1]) then out[#out + 1] = { type = e[1], name = e[2] } end
    end
    return out
end
-- The game's own close for every open screen (or only the EWidgetTypes in the list `types`), in M.SCREENS
-- order, re-reading IsOpen before each close (a coupled widget closes with its parent).
-- InputManagerUIAPI:CloseWidgetIfOpen(PC, Type, bIsTriggeredByOutsideWidget=false, bShouldCheckPauseBlock=false):
-- plain enum/bool args, no structs (live 2026-10-26: closes Processing + its Inventory, mode -> DIM_Gameplay).
-- -> closed names, still-open names (nil, nil when the API is unavailable or paused)
function M.close_screens(types)
    if paused() then return nil, nil end
    local api, pc = M.input_manager(), M.pc()
    if not (api and pc) then return nil, nil end
    local only
    if types then only = {}; for _, t in ipairs(types) do only[t] = true end end
    local closed, left = {}, {}
    for _, e in ipairs(M.SCREENS) do
        if (not only or only[e[1]]) and screen_open(api, pc, e[1]) then
            pcall(function() api:CloseWidgetIfOpen(pc, e[1], false, false) end)
            if screen_open(api, pc, e[1]) then left[#left + 1] = e[2] else closed[#closed + 1] = e[2] end
        end
    end
    return closed, left
end
local function names(list)
    local out = {}
    for _, e in ipairs(list or {}) do out[#out + 1] = e.name end
    return out
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
    if im and not M.is_gameplay_mode(im) then
        local scr = M.SCREEN_MODES[im] and M.open_screens() or nil
        if scr and #scr > 0 then return { kind = "screen", mode = im, screens = names(scr) } end
        return { kind = "mode", mode = im }
    end
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
    if m.kind == "screen" then local c = M.close_screens(); return c ~= nil and #c > 0 end
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

-- A screen cleanup record: kept in state (input_status.last_screen_cleanup) and written to the text log.
local function note(rec, log)
    rec.at = M.clock()
    st().last_screen = rec
    local msg = string.format("input: stray screen (%s): mode %s, closed [%s]%s -> %s", tostring(rec.why), tostring(rec.mode),
        table.concat(rec.closed or {}, ","), (rec.left and #rec.left > 0) and (" still open [" .. table.concat(rec.left, ",") .. "]") or "",
        tostring(rec.after))
    if not log then
        local inst = rawget(_G, "__dwc_bridge")
        local api = inst and inst.module and inst.module.API
        log = api and api.log
    end
    if type(log) == "function" then pcall(log, msg) end
end

-- A modal open with no live owner for cfg.orphan_s is cleaned up (a dead job, a bridge restart, a pause):
-- one step per orphan_s, at most cfg.cancels steps per episode, then it is left alone and reported.
-- A conversation: talk.lua's sweep when talk is enabled (a try counts only when IT pressed Cancel; talk review
-- V1), else our own panel Cancel, so a dialogue can never strand him (V2).
local function sweep(m)
    local s = st()
    s.orphan_tries = s.orphan_tries or {}
    if not m or m.kind == "paused" then s.orphan_since, s.orphan_tries = {}, {}; return end
    if s.owners[m.kind] or (m.kind == "screen" and next(s.owners) ~= nil) then -- a screen: ANY claim means "meant"
        s.orphan_since[m.kind], s.orphan_tries[m.kind] = nil, nil
        return
    end
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
    if m.kind == "screen" then
        local closed, left = M.close_screens()
        note({ why = "orphan", mode = m.mode, closed = closed, left = left, after = M.input_mode() })
    elseif m.kind == "build" then M.leave_build_step() else M.close_container() end
end
M._sweep = sweep

-- The general guard (BUGS B-stuck-focused-ui): client_bridge calls it when ANY action ends. If the PC is left
-- in a non-gameplay input mode, nobody claims a modal, and the game says a screen is open, that screen is
-- stray: close it now with the game's own close and log it. A screen mode (M.SCREEN_MODES) with no open screen
-- is only logged (no guessing); other modes (spells, fishing, build) are left to their owners.
-- -> the record {why, mode, closed, left, after} | nil (nothing to do)
function M.after_action(why, log)
    if paused() then return nil end
    local s = st()
    -- a "screen" claim lives only as long as the action that opened the screen (crafting, lodestone): the action
    -- has ended, so the claim is stale even when an exit path (a failure step, an interrupt) didn't release it
    s.owners.screen = nil
    if next(s.owners) ~= nil then return nil end
    local im = M.input_mode()
    if im == nil or not M.SCREEN_MODES[im] then return nil end
    local bm = M.build_mode()
    if (bm and bm ~= "None") or M.world_inventory() then return nil end -- their own sweeps (build / container)
    local closed, left = M.close_screens()
    local rec = { why = "after " .. tostring(why), mode = im, closed = closed, left = left, after = M.input_mode() }
    if closed and #closed > 0 then s.cleanups = s.cleanups + 1 end
    note(rec, log)
    return rec
end

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
    return { modal = M.modal(), owners = owners, cleanups = s.cleanups, refused = s.refused, stuck = s.stuck,
             last_screen_cleanup = s.last_screen }
end
M.HANDLERS = { input_status = function() return { ok = true, data = M.status() } end }

return M
