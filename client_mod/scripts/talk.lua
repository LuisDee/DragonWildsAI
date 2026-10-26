-- talk: TALKING TO NPCs on Claude's own client (design docs/design/talk-primitive.md, rev 2 after the review
-- docs/reviews/2026-10-26-talk-primitive-review.md). The player's own path only:
--
--   start   talk {target}: the shared interact episode (skills.lua: approach, interaction point, standing spots,
--           face until the game's detector targets the NPC, ONE interact press). Opened = the controller's
--           participant ConversationsActive > 0 AND ConversationComponent.CurrentNPC == that NPC (finding 5a);
--           checked every tick during the episode's verify so the episode never presses a second time.
--   read    cheap scalars every tick (the update counter from a count-only hookhub post-hook on
--           PlayerConversationComponent:HandleConversationUpdated, ConversationsActive, CurrentNPC, the input
--           mode); the payload (LastMessage: speaker, line, options' ChoiceText/ChoiceType only) and the panel
--           (AllOptions text + input action, numbered by OptionSelectInputActions) are read once per change
--           (finding 14). ServerOnly options are never shown (finding 4).
--   continue  only when the SAME-TICK read shows no user options and an empty panel list (finding 1), once per
--           verified update; lines are returned in order with the speaker; a quest change stops it (2a).
--   choose  talk {choose}: the node is re-read first; a changed node fails options_changed with the new options
--           (finding 3). The option's own key is injected; if no update follows but the panel's
--           CurrentSelectedOption is now THAT option, the panel's confirm (Continue) is pressed once (finding 2).
--           If neither happens: input_not_reaching_ui, and we stop (finding 18a: fallback order injected action
--           -> the button's own UI handler (disabled until probed) -> stop and ask Luis; never the advance RPC).
--   leave   talk {leave}: the panel's CancelInputAction; verified inactive.
--   quests  baseline at conversation start, cumulative diff of State, CurrentObjective, QuestInts and QuestBools
--           (finding 6), re-diffed on end.
--   orphans sweep_orphan(): a conversation nobody owns is closed with the panel's own Cancel (finding 9).
--   Never Server_* / the advance RPCs / HideConversationUI; reads only, presses through the input gate.
-- Rev 3 (re-review v2, R1-R10): UObject wrappers are matched by U.short names, never ==; one clock (the pawn's
-- GetRealTimeSeconds); the orphan sweep is re-entrancy-guarded and presses as the modal's owner; the input claim is
-- held only while a talk job runs (between turns the sweep asks talk, which alone decides ownership); any read of
-- an open conversation adopts it; the update counter hooks the client RPC + the BP event, and the highlight-confirm
-- path is enabled only once the counter is proven live.
-- W = the engine touches (tests replace them). Live state in _G.DWTalk (hot reload safe).
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    open_wait_s = 4.0, change_wait_s = 3.0, highlight_wait_s = 0.8, max_lines = 8, tap_frames = 1, -- ONE frame: a held key must never land on a newer node
    episode_timeout_s = 90, lease_s = 5, decide_s = 0.1,
    panel_class = "ConversationMainPanel", conversation_mode_word = "Conversation", gameplay_mode = "DIM_Gameplay",
    -- R6: the update counter: the incoming client RPC (ProcessEvent-dispatched) and the BP implementable event
    hook_paths = { "/Script/CommonConversationRuntime.ConversationParticipantComponent:ClientUpdateConversation",
                   "/Script/Dominion.PlayerConversationComponent:BP_HandleConversationUpdated" },
    hook_verified = false, -- true only after a live proof; the counter also proves itself (C().hook_proven)
    orphan_s = 1.0, cancels = 3, abandon_s = 120, -- R5: a dialogue untouched by talk for 2 min is abandoned
    ui_handler_fallback = false, -- finding 18a step 2: enabled only after an offline + live probe of the handler
    each_cap = 16, each_cap_quest_fields = 64,
}
M.CHOICE = { [0] = "server_only", [1] = "available", [2] = "unavailable" } -- EConversationChoiceType
M.QUEST = { [0] = "ungiven", [1] = "given", [2] = "complete" }          -- EQuestState

local function C()
    local c = rawget(_G, "DWTalk")
    if not c then c = { gen = 0, counts = { talks = 0, choices = 0, lines = 0, confirms = 0, orphan_cancels = 0 }, lines = {} }; _G.DWTalk = c end
    return c
end
M._state = C
local function HK()
    local h = rawget(_G, "DWTalkHook")
    if not h then h = { count = 0 }; _G.DWTalkHook = h end
    return h
end
local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "talk: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
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

-- ------------------------------------------------------------------ pure
-- Is this input mode the dialogue's own? (finding 7 / 5c; a name check on the game's mode asset)
function M.is_conversation_mode(mode) return type(mode) == "string" and mode:find(M.cfg.conversation_mode_word, 1, true) ~= nil end

-- The user choices of a read: panel rows (what the screen shows: text, its key, the on-screen number) JOINED BY
-- TEXT with the payload (availability); ServerOnly entries never appear. -> {{n, text, available, act}}
function M.choices(st)
    local payload = {}
    for _, o in ipairs(st and st.options or {}) do
        if o.text and o.type ~= 0 then payload[o.text] = o end
    end
    local out = {}
    local rows = st and st.panel_rows or {}
    if #rows > 0 then
        for i, r in ipairs(rows) do
            local p = r.text and payload[r.text]
            local hidden = r.text and not p and st.options and #st.options > 0 and M._server_only_text(st, r.text)
            if r.text and not hidden then
                out[#out + 1] = { n = r.n or i, text = r.text, act = r.act, available = not (p and p.type == 2) and r.enabled ~= false }
            end
        end
    else
        local i = 0
        for _, o in ipairs(st and st.options or {}) do
            if o.text and o.type ~= 0 then i = i + 1; out[#out + 1] = { n = i, text = o.text, available = o.type ~= 2 } end
        end
    end
    table.sort(out, function(a, b) return a.n < b.n end)
    return out
end
function M._server_only_text(st, t)
    for _, o in ipairs(st.options or {}) do if o.text == t and o.type == 0 then return true end end
    return false
end

-- The model's pick -> a shown option: a number (the on-screen one) or text (exact, case-insensitive, then a
-- unique substring). -> option | nil, why
function M.resolve(shown, pick)
    if type(pick) == "number" or (type(pick) == "string" and pick:match("^%s*%d+%s*$")) then
        local n = math.floor(tonumber(pick))
        for _, o in ipairs(shown or {}) do if o.n == n then return o end end
        return nil, "no_such_number"
    end
    if type(pick) ~= "string" or pick == "" then return nil, "empty" end
    local want = pick:lower():gsub("^%s+", ""):gsub("%s+$", "")
    for _, o in ipairs(shown or {}) do if o.text:lower() == want then return o end end
    local hit
    for _, o in ipairs(shown or {}) do
        if o.text:lower():find(want, 1, true) then
            if hit then return nil, "ambiguous" end
            hit = o
        end
    end
    if hit then return hit end
    return nil, "no_match"
end

-- Quest rows -> what changed (state, objective, ints, bools). rows: {{quest, state, objective, ints={}, bools={}}}
function M.quest_diff(q0, q1)
    local by = {}
    for _, r in ipairs(q0 or {}) do if r.quest then by[r.quest] = r end end
    local out = {}
    for _, r in ipairs(q1 or {}) do
        local a = r.quest and by[r.quest]
        local d = { quest = r.quest }
        local any = false
        if not a then d.from, d.to, d.objective, any = "ungiven", r.state, r.objective, true
        else
            if a.state ~= r.state then d.from, d.to, any = a.state, r.state, true end
            if a.objective ~= r.objective then d.objective, d.objective_before, any = r.objective, a.objective, true end
        end
        for _, kind in ipairs({ "ints", "bools" }) do
            for k, v in pairs(r[kind] or {}) do
                local was = a and (a[kind] or {})[k]
                if was ~= v then d[kind] = d[kind] or {}; d[kind][k] = { from = was, to = v }; any = true end
            end
        end
        if any then out[#out + 1] = d end
    end
    return out
end

-- A stable text key of a quest diff (R10: a second change to the same quest is still a change).
function M.diff_key(qd)
    local parts = {}
    for _, d in ipairs(qd or {}) do
        local x = { tostring(d.quest), tostring(d.from), tostring(d.to), tostring(d.objective) }
        for _, kind in ipairs({ "ints", "bools" }) do
            local ks = {}
            for k, v in pairs(d[kind] or {}) do ks[#ks + 1] = k .. "=" .. tostring(v.to) end
            table.sort(ks)
            x[#x + 1] = table.concat(ks, ",")
        end
        parts[#parts + 1] = table.concat(x, ";")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- The node signature (finding 3): the node handle's fields as read, speaker, line, option texts and types.
function M.signature(st)
    if not st or not st.active then return "inactive" end
    local parts = { tostring(st.node), tostring(st.speaker), tostring(st.line) }
    for _, o in ipairs(st.options or {}) do parts[#parts + 1] = tostring(o.text) .. ":" .. tostring(o.type) end
    for _, r in ipairs(st.panel_rows or {}) do parts[#parts + 1] = "p:" .. tostring(r.text) end
    return table.concat(parts, "|")
end

local function options_words(shown)
    local w = {}
    for _, o in ipairs(shown or {}) do w[#w + 1] = string.format("%d) %s%s", o.n, o.text, o.available and "" or " (not available)") end
    return table.concat(w, "; ")
end
M.options_words = options_words

local function public_options(shown)
    local out = {}
    for _, o in ipairs(shown or {}) do out[#out + 1] = { n = o.n, text = o.text, available = o.available } end
    return out
end

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
local GS
-- ONE clock (R3): the game's real-time seconds with the pawn as world context; nil when unreadable (callers treat
-- nil as "not now", never mixing in os.time()).
function W.now(ctx)
    if M.clock then return M.clock() end
    if not ctx then return nil end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return (ok and type(t) == "number") and t or nil
end
-- R9: the cached, re-validated controller from input.lua (no FindAllOf per call); sense as the fallback.
function W.pc()
    local inp = mod("input")
    if inp and inp.pc then local pc = inp.pc(); if pc then return pc end end
    local s = mod("sense")
    return s and s.local_pc and s.local_pc() or nil
end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.pawn_id(pawn) return U.short(pawn) end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
local function same(a, b) -- R1 + V3: wrappers never compare with ==; the FULL name is exact (outer path included)
    if a == nil or b == nil then return false end
    local fa = U.fullname(a)
    return fa ~= nil and fa == U.fullname(b)
end
M._same = same
local function each(arr, fn, cap)
    if paused() or not arr then return end
    local n = 0
    pcall(function()
        arr:ForEach(function(_, e)
            n = n + 1
            if n > (cap or M.cfg.each_cap) then return true end
            local v = U.try(function() return e:get() end) or e
            fn(v, n)
        end)
    end)
end
local function participant(pc)
    local comp = pc and U.try(function() return pc.ConversationComponent end)
    local part = U.valid(comp) and U.try(function() return comp.DomConversationParticipant end)
    return U.valid(comp) and comp or nil, U.valid(part) and part or nil
end
-- Per-tick scalars only (finding 14). -> {active, npc, mode, count, missing}
function W.scalars(pc)
    if paused() then return { active = false, paused = true } end
    local comp, part = participant(pc)
    if not part then return { active = false, missing = true, count = HK().count } end
    local n = num(U.try(function() return part.ConversationsActive end)) or 0
    return { active = n > 0, npc = U.short(U.try(function() return comp.CurrentNPC end)),
             mode = U.short(U.try(function() return pc.CurrentInputMode end)), count = HK().count }
end
-- The dialogue panel of THIS player (finding 15): find_all + skip_defaults + valid + the participant matches;
-- cached, re-validated per call.
function W.panel(pc)
    local _, part = participant(pc)
    local c = C()
    -- live P1 (2026-10-26): with no conversation the panel's participant is unset; accept an unset one (one panel per
    -- client), reject only a panel bound to ANOTHER participant
    local function mine(p)
        if not U.valid(p) then return false end
        local pp = U.try(function() return p.DomConversationParticipant end)
        return part == nil or not U.valid(pp) or same(pp, part)
    end
    if c.panel and mine(c.panel) then return c.panel end
    c.panel = nil
    for _, p in ipairs(U.find_all(M.cfg.panel_class, { skip_defaults = true }) or {}) do
        if mine(p) then c.panel = p; break end
    end
    return c.panel
end
-- The full read: scalars + the payload + the panel (once per change, bounded). -> st
function W.read(pc)
    local st = W.scalars(pc)
    st.options, st.panel_rows = {}, {}
    if not st.active then return st end
    local _, part = participant(pc)
    local msg = part and U.try(function() return part.LastMessage end)
    if msg then
        st.speaker = text(U.try(function() return msg.Message.ParticipantDisplayName end))
        st.line = text(U.try(function() return msg.Message.Text end))
        local g = U.try(function() return msg.CurrentNode.NodeGuid end) -- R8: the FGuid's four numbers
        if g then
            local parts = {}
            for _, k in ipairs({ "A", "B", "C", "D" }) do parts[#parts + 1] = tostring(num(U.try(function() return g[k] end))) end
            st.node = table.concat(parts, "-")
        end
        each(U.try(function() return msg.Options end), function(o)
            st.options[#st.options + 1] = { text = text(U.try(function() return o.ChoiceText end)), type = num(U.try(function() return o.ChoiceType end)) }
        end)
    end
    local panel = W.panel(pc)
    if panel then
        st.panel = true
        local keys = {}
        each(U.try(function() return panel.OptionSelectInputActions end), function(a, i) if U.valid(a) then keys[#keys + 1] = { a = a, n = i } end end)
        each(U.try(function() return panel.AllOptions end), function(d, i)
            if U.valid(d) then
                local a = U.try(function() return d.InputAction end)
                local n
                for _, k in ipairs(keys) do if U.valid(a) and same(k.a, a) then n = k.n end end
                st.panel_rows[#st.panel_rows + 1] = { text = text(U.try(function() return d.DisplayName end)), act = U.valid(a) and a or nil, n = n or i, data = d }
            end
        end)
        local c, x = U.try(function() return panel.ContinueInputAction end), U.try(function() return panel.CancelInputAction end)
        st.continue, st.cancel = U.valid(c) and c or nil, U.valid(x) and x or nil
        local sel = U.try(function() return panel.CurrentSelectedOption end)
        st.selected = U.valid(sel) and text(U.try(function() return sel.DisplayName end)) or nil
    end
    return st
end
function W.quests(pc)
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    if not U.valid(qc) or paused() then return nil end
    local out = {}
    each(U.try(function() return qc.Quests end), function(q)
        local d = U.try(function() return q.Data end)
        if U.valid(d) then
            local r = { quest = text(U.try(function() return d.QuestName end)) or U.short(d),
                        state = M.QUEST[num(U.try(function() return q.State end)) or -1] or tostring(U.try(function() return q.State end)),
                        objective = U.str(U.try(function() return q.CurrentObjective end)), ints = {}, bools = {} }
            each(U.try(function() return q.QuestInts end), function(x) local k = U.str(U.try(function() return x.Name end)); if k then r.ints[k] = num(U.try(function() return x.Value end)) end end, M.cfg.each_cap_quest_fields)
            each(U.try(function() return q.QuestBools end), function(x) local k = U.str(U.try(function() return x.Name end)); if k then r.bools[k] = U.try(function() return x.Value end) == true end end, M.cfg.each_cap_quest_fields)
            out[#out + 1] = r
        end
    end, 128)
    return out
end
-- A UI press through the input gate: allowed only while the open modal is the dialogue itself (finding 7b).
-- A UI press as the conversation modal's OWNER (R2): claim "conversation" for the press, so input's sweep (which
-- calls talk.sweep_orphan for an unowned conversation) is never re-entered from our own press; released after,
-- unless a talk job holds the claim.
function W.ui_press(act)
    local inp = mod("input")
    if not inp then return false, "no input layer" end
    local m = inp.modal and inp.modal() or nil
    local kind = m and m.kind
    if m and not (kind == "conversation" or (kind == "mode" and M.is_conversation_mode(m.mode))) then return false, m end
    if not inp.inject then return false, "no input.inject" end
    local held = C().claimed
    if not held and inp.claim then pcall(inp.claim, "conversation", "talk") end
    local ok, r = pcall(inp.inject, act, nil, { modal = kind })
    if not held and inp.release then pcall(inp.release, "conversation") end
    if not ok then return false, tostring(r) end
    return r == true, nil
end
function W.claim() local inp = mod("input"); C().claimed = true; if inp and inp.claim then pcall(inp.claim, "conversation", "talk") end end
function W.release() local inp = mod("input"); C().claimed = nil; if inp and inp.release then pcall(inp.release, "conversation") end end
function W.arm_hook(log)
    local h = mod("hookhub")
    if not (h and h.on) then return false end
    local any = false
    for _, path in ipairs(M.cfg.hook_paths) do
        local ok = h.on(path, "talk", function() local k = HK(); k.count = k.count + 1 end, { log = log }) -- count only
        any = any or ok == true
    end
    HK().armed = any
    return any
end
function W.skills() return mod("skills") end

-- ------------------------------------------------------------------ conversation memory (one at a time)
local function conv_clear(why)
    local c = C()
    if c.conv then say(nil, "conversation state cleared: " .. tostring(why)) end
    c.conv = nil
end

-- A conversation that ended without our Cancel / a world change / a different NPC -> a truthful note (finding 8, 10).
local function conv_check(pc, sc, now)
    local c = C()
    local cv = c.conv
    if not cv then return nil end
    local pid = W.pawn_id(W.pawn(pc))
    if cv.pawn_id and pid ~= cv.pawn_id then conv_clear("world changed"); return "The world reloaded, so my conversation ended." end
    if not sc.active then
        conv_clear("ended elsewhere")
        W.release()
        return string.format("My conversation with %s ended without me ending it (maybe I had to fight).", tostring(cv.npc_name or cv.npc))
    end
    if sc.npc and cv.npc and sc.npc ~= cv.npc then
        conv_clear("other npc")
        return "I'm now in a different conversation."
    end
    cv.last_call = now
    return nil
end

-- ------------------------------------------------------------------ the job
local function result_of(J, ok, reason, data)
    data = data or {}
    local st = J.st or { active = false }
    data.in_conversation = st.active == true
    data.npc = J.npc_name or (C().conv and C().conv.npc_name)
    data.speaker = st.speaker
    data.lines = J.lines
    data.options = public_options(J.shown or {})
    data.node = J.sig
    data.chose = J.chose
    data.picked_via = J.picked_via
    data.hook_armed, data.hook_count = HK().armed == true, HK().count
    data.note = data.note or J.note
    local base = (C().conv and C().conv.base) or J.q0
    local qd = M.quest_diff(base, W.quests(J.pc) or base)
    if #qd > 0 then data.quests_changed = qd end
    return { ok = ok == true, reason = reason, data = data }
end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle, J.tap = nil, nil
    W.release() -- R5: never held between turns (Lua only, safe under pause)
    if not paused() and res.data then
        if res.data.in_conversation then
            local cv = c.conv
            if not cv and J.st and J.st.npc then -- R4: adopt what we just read
                cv = { npc = J.st.npc, npc_name = J.npc_name or J.st.speaker, pawn_id = J.pawn_id, base = J.q0, since = J.t }
                c.conv = cv
            end
            if cv then cv.sig, cv.shown, cv.last_call = J.sig, J.shown, J.t end
        else
            conv_clear("ended")
        end
    end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data and res.data.detail or "")))
end
local function fail(J, reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return finish(J, result_of(J, false, reason, d))
end
local function set_phase(J, ph, note) J.phase, J.phase_t = ph, J.t; say(J.log, "phase " .. ph .. (note and (" " .. note) or "")) end

local function press(J, act, what)
    local ok, why = W.ui_press(act)
    if not ok then
        local kind = type(why) == "table" and why.kind or tostring(why)
        fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't %s in the conversation.", tostring(kind), what))
        return false
    end
    -- the first frame went now, in the same tick as the read that decided it (finding 1); extra frames (if
    -- configured) are dropped the moment a new payload arrives
    J.tap = M.cfg.tap_frames > 1 and { act = act, frames = M.cfg.tap_frames - 1, count0 = HK().count } or nil
    return true
end

local function add_line(J, st)
    if st.line and (st.line ~= J.last_line or st.count ~= J.last_line_count) then
        J.lines[#J.lines + 1] = { speaker = st.speaker, text = st.line }
        J.last_line, J.last_line_count = st.line, st.count
        C().counts.lines = C().counts.lines + 1
    end
end

-- read the node (full read, once per change), collect its line, continue through choice-less lines
local function step_read(J)
    local st = W.read(J.pc)
    local prev_sig = J.sig
    J.st = st
    J.sig = M.signature(st)
    J.shown = M.choices(st)
    -- R6: the counter proves itself once it moved together with a real content change
    if J.count_moved and prev_sig and J.sig ~= prev_sig and st.active then C().hook_proven = true end
    J.count_moved = nil
    -- R4: any read of an open conversation adopts it (opened by interact, a bridge restart, ...)
    if st.active and st.npc and (not C().conv or C().conv.npc ~= st.npc) then
        C().conv = { npc = st.npc, npc_name = J.npc_name or st.speaker, pawn_id = J.pawn_id, base = J.q0, since = J.t, last_call = J.t }
    end
    if J.mode == "choose" and not J.picked_via and J.sig ~= prev_sig then J.picked_via = "key" end
    if not st.active then
        if J.mode == "choose" and not J.picked_via then J.picked_via = "key" end
        return finish(J, result_of(J, true, nil, { ended = true, detail = "The conversation ended." }))
    end
    if st.mode and not M.is_conversation_mode(st.mode) and st.mode ~= M.cfg.gameplay_mode then
        return fail(J, "interrupted", "screen_open", string.format("The game opened another screen (%s) in the middle of the conversation.", tostring(st.mode)))
    end
    add_line(J, st)
    if not st.panel then
        return fail(J, "not_implemented", "no_dialogue_ui", string.format("%s says: %s (there is no dialogue window to answer in, so I'm not pressing anything).",
            tostring(st.speaker or "They"), tostring(st.line or "...")))
    end
    if #J.shown > 0 then
        return finish(J, result_of(J, true, nil, { detail = string.format("%s says: %s Options: %s", tostring(st.speaker or "They"),
            tostring(st.line or "..."), options_words(J.shown)) }))
    end
    local qd = M.quest_diff((C().conv and C().conv.base) or J.q0, W.quests(J.pc) or {})
    local qkey = M.diff_key(qd)
    if J.quest_key ~= nil and qkey ~= J.quest_key and (J.advanced or 0) > 0 then -- R10: by content, not count
        return finish(J, result_of(J, true, nil, { detail = "A quest changed; stopping to look.", quest_stop = true }))
    end
    J.quest_key = qkey
    -- finding 1: Continue only when THIS read shows no user options and the panel list is empty
    local any_user = false
    for _, o in ipairs(st.options or {}) do if o.type == 1 or o.type == 2 then if o.text then any_user = true end end end
    if any_user or #(st.panel_rows or {}) > 0 or not st.continue or (J.advanced or 0) >= M.cfg.max_lines then
        return finish(J, result_of(J, true, nil, { detail = string.format("%s says: %s", tostring(st.speaker or "They"), tostring(st.line or "...")),
            more = (J.advanced or 0) >= M.cfg.max_lines or nil }))
    end
    J.advanced = (J.advanced or 0) + 1
    J.count0 = st.count
    if not press(J, st.continue, "read on") then return end
    set_phase(J, "wait_update", "continue")
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if paused() then
        -- finding 10: no game call at all; the conversation died with the world
        J.done = true
        if J.handle then pcall(CancelDelayedAction, J.handle) end
        J.result = { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is reloading." } }
        if c.job == J then c.job = nil end
        conv_clear("paused")
        W.release() -- R5: Lua-only releases are safe under pause
        local arbp = mod("arbiter")
        if arbp and J.token and not J.released then J.released = true; pcall(arbp.release, nil, J.token, "paused") end
        return
    end
    local pawn = W.pawn(J.pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.tap then
        if (HK().count or 0) ~= J.tap.count0 then J.tap = nil end
    end
    if J.tap then
        if J.tap.frames > 0 then W.ui_press(J.tap.act) end
        J.tap.frames = J.tap.frames - 1
        if J.tap.frames <= 0 then J.tap = nil end
    end
    if J.suspended then return end
    if J.t - (J.dec_t or -1) < M.cfg.decide_s then return end
    J.dec_t = J.t
    local arb = mod("arbiter")
    if arb and J.token then
        if not arb.holds(J.token) then
            if arb.is_suspended and arb.is_suspended(J.token) then J.suspended = true; return end
            return finish(J, result_of(J, false, "interrupted", { why = "preempted", detail = "Something else took over before I could talk." }))
        end
        arb.renew(J.token)
    end
    if W.dead(pawn) then return fail(J, "companion_down", "died", "I died.") end
    local sc = W.scalars(J.pc)
    local ph = J.phase
    if ph == "episode" then
        -- opened? (checked first every tick: the episode must never press E a second time into the dialogue)
        if sc.active and sc.npc == J.target.id then
            if J.ep and J.ep.moving then pcall(function() J.api.call("move", "stop") end) end
            J.ep = nil
            C().counts.talks = C().counts.talks + 1
            C().conv = { npc = J.target.id, npc_name = J.target.name, pawn_id = W.pawn_id(pawn), base = J.q0, since = J.t, last_call = J.t }
            W.claim()
            return step_read(J)
        end
        if sc.active and sc.npc and sc.npc ~= J.target.id then
            return fail(J, "verification_failed", "other_conversation", string.format("I started talking to someone else (%s), not %s.",
                tostring(sc.npc), tostring(J.target.name or J.target.id)))
        end
        local SK = W.skills()
        local res = SK._episode_poll(J.api, J.ep, J.t)
        if res == nil then
            if J.t - J.t0 > M.cfg.episode_timeout_s then return fail(J, "timeout", "timeout", "I couldn't get to them in time.") end
            return
        end
        if res.ok and res.data and res.data.changed == "conversation" then return end -- the next tick reads it
        if res.ok then
            return fail(J, "verification_failed", "no_conversation", string.format("I pressed talk on %s but no conversation opened.", tostring(J.target.name or "them")))
        end
        local d = res.data or {}
        if res.reason == "verification_failed" then
            return fail(J, "verification_failed", "no_conversation", string.format("I pressed talk on %s but no conversation opened.", tostring(J.target.name or "them")))
        end
        return finish(J, { ok = false, reason = res.reason, data = { why = d.why or res.reason, detail = d.detail, target = J.target.id } })
    end
    if ph == "wait_update" then
        if J.tap then return end
        if (sc.count or 0) > (J.count0 or 0) then J.count_moved = true end
        if not sc.active or J.count_moved then return step_read(J) end
        if J.t - J.phase_t > M.cfg.change_wait_s then
            local st = W.read(J.pc) -- the hook may be missing: one full read before giving up
            if M.signature(st) ~= J.sig then return step_read(J) end
            if J.mode == "leave" then return fail(J, "verification_failed", "no_change", "I tried to end the conversation but it's still open.") end
            return finish(J, result_of(J, true, nil, { detail = "The conversation stopped moving on.", stuck = true }))
        end
        return
    end
    if ph == "choose_wait" then
        if J.tap then return end
        if (sc.count or 0) > (J.count0 or 0) then J.count_moved = true end
        if not sc.active or J.count_moved then return step_read(J) end
        local since = J.t - J.phase_t
        local hook_ok = M.cfg.hook_verified or C().hook_proven == true
        if since >= M.cfg.highlight_wait_s and not J.confirmed then
            local st = W.read(J.pc)
            if M.signature(st) ~= J.sig then return step_read(J) end
            -- finding 2 + R6 + R7: the key may only highlight; confirm ONLY when the counter is proven (so "no update"
            -- really means none), the highlight CHANGED because of our key, and it is the model's choice
            if hook_ok and st.selected and st.selected == J.chose and st.selected ~= J.selected0 and st.continue then
                J.picked_via = "key+confirm"
                J.confirmed = true
                C().counts.confirms = C().counts.confirms + 1
                say(J.log, "option highlighted, confirming")
                if not press(J, st.continue, "confirm my answer") then return end
                J.count0 = HK().count
                J.phase_t = J.t
                return
            end
        end
        if since > M.cfg.change_wait_s then
            local st = W.read(J.pc)
            if M.signature(st) ~= J.sig then return step_read(J) end
            if not hook_ok then
                -- without a proven counter an identical hub and a deaf key look the same: say exactly that
                J.st, J.shown = st, M.choices(st)
                return fail(J, "verification_failed", "no_visible_change", string.format(
                    "I picked \"%s\", but the conversation looks exactly the same: it may have come back to the same question, or my key didn't reach it.",
                    tostring(J.chose)))
            end
            return fail(J, "verification_failed", "input_not_reaching_ui", string.format(
                "I pressed the key for \"%s\" but the conversation didn't react; I'll stop here and ask for help rather than guess.", tostring(J.chose)))
        end
        return
    end
end
M._frame = frame

local function new_job(log, ctx, mode, pc, extra)
    local c = C()
    if c.job then finish(c.job, { ok = false, reason = "interrupted", data = { why = "new_talk", detail = "A new talk started." } }) end
    c.gen = c.gen + 1
    local pawn = W.pawn(pc)
    local t = W.now(pawn)
    local J = { gen = c.gen, log = log, pc = pc, mode = mode, t0 = t, t = t, phase_t = t, lines = {}, api = ctx and ctx.api or M.api }
    for k, v in pairs(extra or {}) do J[k] = v end
    J.q0 = J.q0 or W.quests(pc) or {}
    J.pawn_id = W.pawn_id(pawn)
    c.job = J
    W.claim() -- held while this job runs; finish releases it (R5)
    return J
end

local function run(J)
    J.handle = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(frame, J)
        if not ok then
            say(J.log, "frame error " .. tostring(err))
            J.errors = (J.errors or 0) + 1
            if J.errors >= 5 then finish(J, { ok = false, reason = "body_error", data = { why = "frame_error", detail = tostring(err) } }) end
        end
    end)
end

local function bad(reason, why, detail, extra)
    local d = extra or {}
    d.why, d.detail = why, detail
    return { ok = false, reason = reason, data = d }
end

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return bad("companion_down", "paused", "The world is loading.") end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return bad("companion_down", "no_pawn") end
    pcall(W.arm_hook, log)
    local now = W.now(pawn)
    M.reap_stale(now)
    local sc = W.scalars(pc)
    local note = conv_check(pc, sc, now)
    local has_target = type(args.target) == "string" and args.target ~= ""
    if has_target and (args.choose ~= nil or args.leave) then
        return bad("invalid_args", "mixed_args", "Start a conversation with target first, then answer with choose in the next call.")
    end
    if args.leave == true then
        if not sc.active then return bad("invalid_args", "not_in_conversation", note or "I'm not talking to anyone.") end
        local st = W.read(pc)
        if not st.cancel then return bad("not_implemented", "no_dialogue_ui", "There is no dialogue window to close.") end
        local J = new_job(log, ctx, "leave", pc, { q0 = C().conv and C().conv.base, note = note })
        J.st, J.sig, J.count0 = st, M.signature(st), st.count
        J.npc_name = C().conv and C().conv.npc_name
        if not press(J, st.cancel, "leave") then return J.result end
        set_phase(J, "wait_update", "leave")
        run(J)
        return { ok = true }
    end
    if args.choose ~= nil then
        local running = C().job
        if running and not running.done and running.mode == "choose" then
            return bad("invalid_args", "answer_pending", "I'm still waiting to see what my last answer did.")
        end
        if not sc.active then return bad("invalid_args", "not_in_conversation", note or "I'm not talking to anyone, so there's nothing to choose.") end
        local st = W.read(pc)
        local cv = C().conv
        local sig = M.signature(st)
        local now_shown = M.choices(st)
        -- finding 3: the node must be the one the model read
        if not cv or cv.sig ~= sig then
            if cv then cv.sig, cv.shown = sig, now_shown end
            return bad("invalid_args", "options_changed", string.format("The conversation moved on since I last looked. %s says: %s Options now: %s",
                tostring(st.speaker or "They"), tostring(st.line or "..."), options_words(now_shown)),
                { options = public_options(now_shown), node = sig, speaker = st.speaker, line = st.line })
        end
        local o, why = M.resolve(cv.shown, args.choose)
        if not o then
            return bad("invalid_args", "invalid_choice", string.format("\"%s\" isn't one of the options: %s.", tostring(args.choose), options_words(cv.shown)),
                { match = why, options = public_options(cv.shown) })
        end
        if not o.available then
            return bad("not_unlocked", "option_unavailable", string.format("I can't pick \"%s\" yet; the game greys it out.", o.text))
        end
        local act
        for _, x in ipairs(now_shown) do if x.text == o.text then act = x.act end end
        if not act then return bad("body_error", "no_option_input", "I can see the options but not the key that picks them.") end
        local J = new_job(log, ctx, "choose", pc, { chose = o.text, q0 = cv.base, note = note })
        J.st, J.sig, J.shown, J.count0, J.npc_name = st, sig, now_shown, st.count, cv.npc_name
        J.selected0 = st.selected
        C().counts.choices = C().counts.choices + 1
        if not press(J, act, "answer") then return J.result end
        set_phase(J, "choose_wait", "choose " .. o.n .. " " .. o.text)
        run(J)
        return { ok = true }
    end
    if not has_target then
        if not sc.active then return bad("invalid_args", "not_in_conversation", note or "I'm not talking to anyone; give target to start.") end
        local J = new_job(log, ctx, "read", pc, { q0 = C().conv and C().conv.base, note = note })
        J.npc_name = C().conv and C().conv.npc_name
        set_phase(J, "read")
        step_read(J)
        if not J.done then run(J) end
        return { ok = true }
    end
    if sc.active then
        if sc.npc == args.target then
            local J = new_job(log, ctx, "read", pc, { q0 = C().conv and C().conv.base, note = note })
            if not C().conv then C().conv = { npc = sc.npc, pawn_id = W.pawn_id(pawn), base = J.q0, since = now, last_call = now } end
            set_phase(J, "read")
            step_read(J)
            if not J.done then run(J) end
            return { ok = true }
        end
        return bad("invalid_args", "already_talking", string.format("I'm already talking to %s; leave that conversation first.", tostring(sc.npc)))
    end
    local api = ctx and ctx.api or M.api
    local SK = W.skills()
    if not (SK and SK._new_episode and SK._episode_poll and api) then
        return bad("not_implemented", "no_episode", "My walk-up-and-use routine isn't loaded, so I can't start a conversation.")
    end
    local t = api.find_thing(args.target, 120)
    if not t or not t.position then return bad("unknown_target", "unknown_target", string.format("I can't see %s.", tostring(args.target))) end
    local arb = mod("arbiter")
    local token, J
    if arb then
        local r = arb.request(log, { name = "talk", level = "command", resumable = true, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true end end,
            on_resume = function() if J and not J.done then J.suspended = false; if J.ep then J.ep.phase, J.ep.moving = "approach", false end; return true end return false end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, { ok = false, reason = "interrupted", data = { why = tostring(why), detail = "I was told to do something else." } }) end end })
        if not r.ok then return bad("interrupted", "pawn_busy", "I'm busy with something else.", { owner = r.owner }) end
        token = r.token
    end
    J = new_job(log, ctx, "start", pc, { token = token, target = { id = t.id or args.target, name = t.name }, npc_name = t.name, note = note })
    J.ep = SK._new_episode(api, t, { label = t.name })
    set_phase(J, "episode", tostring(t.name) .. " " .. tostring(t.id))
    run(J)
    return { ok = true }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, { ok = false, reason = "interrupted", data = { why = why or "stopped", detail = "I stopped." } }) end
    return { ok = true }
end

-- Finding 9: a conversation nobody owns (no talk conversation recorded, another NPC, or no talk call for
-- abandon_s) is closed with the panel's own Cancel, at most cfg.cancels times (read back between), then reported
-- stuck. Called by input.lua's sweep for the "conversation" modal and at the start of every talk call.
-- V4: a job whose frame loop stopped ticking (a bridge restart, a reload mid-job) still holds the claim; after
-- stale_s without a frame it is dropped, its claim released (Lua only).
M.cfg.stale_s = 5
function M.reap_stale(now)
    local c = C()
    local J = c.job
    if J and not J.done and type(now) == "number" and type(J.t) == "number" and now - J.t > M.cfg.stale_s then
        J.done = true
        J.result = { ok = false, reason = "interrupted", data = { why = "stale_job", detail = "My last conversation step stopped half-way." } }
        c.job = nil
        W.release()
        return true
    end
    if not c.job and c.claimed then W.release(); return true end
    return false
end

function M.sweep_orphan(log)
    if paused() then return { ok = true, skipped = "paused" } end
    local c = C()
    if c.in_sweep then return { ok = true, skipped = "reentrant" } end -- R2
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = true, skipped = "no pawn" } end
    local now = W.now(pawn)
    if type(now) ~= "number" then return { ok = true, skipped = "no clock" } end -- R3: never mix clocks
    M.reap_stale(now)
    local sc = W.scalars(pc)
    if not sc.active then c.orphan = nil; return { ok = true, state = "none" } end
    local cv = c.conv
    local owned = c.job ~= nil or (cv and cv.npc == sc.npc and now - (cv.last_call or now) < M.cfg.abandon_s)
    if owned then c.orphan = nil; return { ok = true, state = "owned" } end
    local o = c.orphan
    if not o or o.npc ~= sc.npc then c.orphan = { npc = sc.npc, since = now, cancels = 0 }; return { ok = true, state = "orphan_seen" } end
    if o.cancels >= M.cfg.cancels then o.stuck = true; return { ok = false, state = "stuck", npc = sc.npc, cancels = o.cancels } end
    if now - o.since < M.cfg.orphan_s or (o.last and now - o.last < M.cfg.orphan_s) then return { ok = true, state = "orphan_wait" } end
    local st = W.read(pc)
    if not st.cancel then return { ok = false, state = "no_cancel_key", npc = sc.npc } end
    o.cancels, o.last = o.cancels + 1, now -- R2: counted BEFORE the press
    c.in_sweep = true
    local okp, ok = pcall(W.ui_press, st.cancel)
    c.in_sweep = nil
    ok = okp and ok
    c.counts.orphan_cancels = c.counts.orphan_cancels + 1
    say(log, string.format("orphan conversation with %s: Cancel %d -> %s", tostring(sc.npc), o.cancels, tostring(ok)))
    if cv then conv_clear("orphaned") end
    return { ok = ok == true, state = "cancel_pressed", npc = sc.npc, cancels = o.cancels }
end

function M.status()
    local c = C()
    local J = c.job
    return { ok = true, job = J and { mode = J.mode, phase = J.phase, lines = #J.lines } or nil, conv = c.conv and { npc = c.conv.npc, sig = c.conv.sig } or nil,
             orphan = c.orphan, hook_count = HK().count, last = c.last, counts = c.counts, log = c.lines }
end

-- Perception (finding 12): while a conversation is open, get_state carries conversation = {npc, speaker, line,
-- options}; the full read only when the update counter moved.
function M.state_extras(api)
    if paused() then return {} end
    local pc = W.pc()
    local sc = W.scalars(pc)
    local c = C()
    if not sc.active then c.extras = nil; return {} end
    if c.extras and c.extras_count == sc.count and c.extras_npc == sc.npc then return c.extras end
    local st = W.read(pc)
    c.extras = { conversation = { npc = (c.conv and c.conv.npc_name) or sc.npc, speaker = st.speaker, line = st.line, options = public_options(M.choices(st)) } }
    c.extras_count, c.extras_npc = sc.count, sc.npc
    return c.extras
end

M.HANDLERS = {
    talk = function(log, args, ctx)
        M.api = ctx and ctx.api or M.api
        pcall(M.sweep_orphan, log)
        local r = M.start(log, args or {}, ctx)
        if not r.ok then return r end
        local J = C().job
        if not J then return (C().last and C().last.result) or { ok = false, reason = "body_error" } end
        local a = { kind = "talk", id = ctx and ctx.id, timeout_s = M.cfg.episode_timeout_s + 40 }
        a.cancel = function() M.stop(log, "cancelled by the brain") end
        a.poll = function()
            local j = C().job
            if j and j == J then return nil end
            return (J and J.result) or { ok = false, reason = "body_error", data = { detail = "talk job vanished" } }
        end
        return { pending = a }
    end,
    talk_status = function() return M.status() end,
}

M.NEEDS = {
    talk = { { "sense", "local_pc" }, { "skills", "_episode_poll" }, { "input", "inject" }, { "inventory", "press_interact" }, { "move", "go_to" } },
}

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        talk = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 140,
            detail_is_speech = false,
            description = "Talk to someone (an NPC from look, e.g. prompt Talk): walks over, starts the conversation and "
                .. "returns what they say and your numbered answer options. Answer in the next call with choose = the "
                .. "option's number or text, or end it with leave = true; call with no arguments to re-read. Reports "
                .. "quest changes.",
            args = { type = "object", properties = obj({
                target = { type = "string", description = "Who to talk to: an id from look (only to start)." },
                choose = { description = "Your answer: an option number or its text, from the last reply.",
                           anyOf = { { type = "integer" }, { type = "string" } } },
                leave = { type = "boolean", description = "End the conversation." } }) },
            ground = obj({ target = "thing" }),
            reasons = { "unknown_target", "not_interactable", "too_far", "verification_failed", "invalid_args", "not_unlocked",
                        "not_implemented", "path_blocked", "interrupted", "timeout", "companion_down" } },
        talk_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Talk job state (debug)." },
    }
end

return M
