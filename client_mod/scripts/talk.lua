-- talk: TALKING TO NPCs on Claude's own client (design docs/design/talk-primitive.md), the player's own path:
--
--   start   walk to the NPC (any interactable the census lists, e.g. prompt "Talk"), face it until the game's
--           interact detector targets it, ONE interact press (E); verified by the controller's conversation
--           participant becoming active / its LastMessage changing.
--   read    the replicated LastMessage (speaker, line, options with available / unavailable) and the dialogue
--           panel's own option list (text + the input action that picks it, Continue, Cancel). Lines with no
--           user choice are advanced with the panel's ContinueInputAction (what reading does), at most 8.
--   choose  the MODEL picks by number or by the option's text, matched only against the options last shown;
--           the option's own input action is injected (the number key); verified by the payload changing or
--           the conversation ending.
--   leave   the panel's CancelInputAction; verified inactive.
--   quests  every reply carries quests_changed, diffed from the controller's QuestProgressComponent.Quests.
--   Never the conversation RPCs (they take hand-built structs: CLAUDE.md §0); read-only state otherwise.
-- W = the engine touches (tests replace them). Live state in _G.DWTalk.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

M.cfg = {
    stand_tol_m = 1.5, reach_m = 3.5, face_s = 3.0, presses = 2,
    open_wait_s = 4.0, change_wait_s = 3.0, max_lines = 8, tap_frames = 2,
    approach_timeout_s = 90, lease_s = 5, decide_s = 0.1, panel_class = "ConversationMainPanel",
}
M.CHOICE = { [0] = "server_only", [1] = "available", [2] = "unavailable" } -- EConversationChoiceType
M.QUEST = { [0] = "ungiven", [1] = "given", [2] = "complete" }          -- EQuestState

local function C()
    local c = rawget(_G, "DWTalk")
    if not c then c = { gen = 0, counts = { talks = 0, choices = 0, lines = 0 }, lines = {} }; _G.DWTalk = c end
    return c
end
M._state = C
local function paused() return rawget(_G, "DW_PAUSE") == true end
local function say(log, msg)
    if log then pcall(log, "talk: " .. msg) end
    local c = C()
    c.lines[#c.lines + 1] = os.date("!%H:%M:%S ") .. msg
    if #c.lines > 40 then table.remove(c.lines, 1) end
end
local function d2(a, b) if not (a and b) then return math.huge end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
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
local function mcall(name, fn, ...)
    local m = mod(name)
    if not (m and m[fn]) then return nil, "no " .. name .. "." .. fn end
    local ok, r = pcall(m[fn], ...)
    if not ok then return nil, tostring(r) end
    return r
end

-- ------------------------------------------------------------------ pure
-- The user choices of a conversation state: panel rows (what the screen shows, with input actions) merged
-- with the payload's options (availability). -> {{n, text, available, act}}
function M.choices(st)
    local out = {}
    local payload = {}
    for _, o in ipairs(st and st.options or {}) do if o.type ~= 0 and o.text then payload[#payload + 1] = o end end
    local rows = (st and st.panel_options and #st.panel_options > 0) and st.panel_options or payload
    for i, r in ipairs(rows) do
        if r.text then
            local avail = true
            for _, o in ipairs(payload) do if o.text == r.text and o.type == 2 then avail = false end end
            if r.type == 2 then avail = false end
            out[#out + 1] = { n = #out + 1, text = r.text, available = avail, act = r.act, slot = i }
        end
    end
    return out
end

-- The model's pick -> the shown option. pick: a number (1-based) or text (exact, case-insensitive, then a
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

-- Quest rows before/after -> what changed. rows: {{quest, state, objective}}
function M.quest_diff(q0, q1)
    local by = {}
    for _, r in ipairs(q0 or {}) do if r.quest then by[r.quest] = r end end
    local out = {}
    for _, r in ipairs(q1 or {}) do
        local a = r.quest and by[r.quest]
        if not a then out[#out + 1] = { quest = r.quest, from = "ungiven", to = r.state, objective = r.objective }
        elseif a.state ~= r.state or a.objective ~= r.objective then
            out[#out + 1] = { quest = r.quest, from = a.state, to = r.state, objective = r.objective, objective_before = a.objective }
        end
    end
    return out
end

-- A comparable signature of the conversation (what verifies an advance).
function M.signature(st)
    if not st or not st.active then return "inactive" end
    local parts = { tostring(st.node), tostring(st.speaker), tostring(st.line) }
    for _, o in ipairs(st.options or {}) do parts[#parts + 1] = tostring(o.text) .. ":" .. tostring(o.type) end
    return table.concat(parts, "|")
end

local function options_words(shown)
    local w = {}
    for _, o in ipairs(shown or {}) do w[#w + 1] = string.format("%d) %s%s", o.n, o.text, o.available and "" or " (not available)") end
    return table.concat(w, "; ")
end
M.options_words = options_words

-- ------------------------------------------------------------------ engine touches
local W = {}
M.W = W
local GS
function W.now(ctx)
    if M.clock then return M.clock() end
    GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GS:GetRealTimeSeconds(ctx) end)
    return ok and t or os.time()
end
function W.pc() return mcall("sense", "local_pc") end
function W.pawn(pc)
    if not U.valid(pc) then return nil end
    local p = U.try(function() return pc.Pawn end)
    return U.alive(p) and p or nil
end
function W.loc(a) return U.loc(a) end
function W.dead(pawn) return U.try(function() return pawn.HealthComponent:IsDead() end) == true end
local function each(arr, fn)
    if paused() or not arr then return end
    pcall(function() arr:ForEach(function(_, e) local v = U.try(function() return e:get() end) or e; fn(v) end) end)
end
function W.panel()
    local p = U.find_first(M.cfg.panel_class)
    if not U.valid(p) then return nil end
    if U.try(function() return p:IsInViewport() end) == false then return nil end
    return p
end
-- The conversation as the client sees it. -> {active, speaker, line, node, options = {{text, type}}, panel_options, continue, cancel}
function W.conv(pc)
    local comp = pc and U.try(function() return pc.ConversationComponent end)
    local part = U.valid(comp) and U.try(function() return comp.DomConversationParticipant end)
    if not U.valid(part) then return { active = false, missing = true } end
    local st = { options = {}, panel_options = {} }
    st.active = U.try(function() return part:IsInActiveConversation() end) == true or (num(U.try(function() return part.ConversationsActive end)) or 0) > 0
    local msg = U.try(function() return part.LastMessage end)
    if msg then
        st.speaker = text(U.try(function() return msg.Message.ParticipantDisplayName end))
        st.line = text(U.try(function() return msg.Message.Text end))
        st.node = U.str(U.try(function() return msg.CurrentNode.NodeGUID end)) or U.str(U.try(function() return msg.CurrentNode end))
        each(U.try(function() return msg.Options end), function(o)
            st.options[#st.options + 1] = { text = text(U.try(function() return o.ChoiceText end)), type = num(U.try(function() return o.ChoiceType end)) }
        end)
    end
    local panel = W.panel()
    if panel then
        st.panel = true
        each(U.try(function() return panel.AllOptions end), function(d)
            if U.valid(d) then
                local a = U.try(function() return d.InputAction end)
                st.panel_options[#st.panel_options + 1] = { text = text(U.try(function() return d.DisplayName end)), act = U.valid(a) and a or nil }
            end
        end)
        local c = U.try(function() return panel.ContinueInputAction end)
        local x = U.try(function() return panel.CancelInputAction end)
        st.continue, st.cancel = U.valid(c) and c or nil, U.valid(x) and x or nil
        if not st.speaker then st.speaker = text(U.try(function() return panel.Text_SpeakerName:GetText() end)) end
        if not st.line then st.line = text(U.try(function() return panel.Text_SpeakerLine:GetText() end)) end
    end
    return st
end
function W.quests(pc)
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    if not U.valid(qc) then return nil end
    local out = {}
    each(U.try(function() return qc.Quests end), function(q)
        local d = U.try(function() return q.Data end)
        if U.valid(d) then
            out[#out + 1] = { quest = text(U.try(function() return d.QuestName end)) or U.short(d),
                              state = M.QUEST[num(U.try(function() return q.State end)) or -1] or tostring(U.try(function() return q.State end)),
                              objective = U.str(U.try(function() return q.CurrentObjective end)) }
        end
    end)
    return out
end
function W.target(pawn) return mcall("inventory", "interact_target", pawn) end
function W.press(log) return mcall("inventory", "press_interact", log) end
function W.inject(act)
    local inp = mod("input")
    if inp and inp.raw_inject then return inp.raw_inject(act) == true end
    local cb = mod("combat")
    local f = cb and (cb.inject or cb._inject)
    return f and f(act) or false
end
function W.gate()
    local inp = mod("input")
    if not (inp and inp.gate) then return nil end
    local ok, m = pcall(inp.gate)
    return ok and m or nil
end
function W.claim() local inp = mod("input"); if inp and inp.claim then pcall(inp.claim, "mode", "talk") end end
function W.release()
    local inp = mod("input")
    if inp and inp.release and inp.owner then
        local o = U.try(function() return inp.owner("mode") end)
        if o and o.owner == "talk" then pcall(inp.release, "mode") end
    end
end
function W.find(id, r) local api = M.api; return api and api.find_thing and api.find_thing(id, r) end
function W.face(pc, yaw) pcall(function() pc:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }) end) end
function W.go_to(log, p, tol_m, timeout_s)
    return mcall("move", "go_to", log, { p.X / 100, p.Y / 100, p.Z / 100 }, { tolerance_m = tol_m, timeout_s = timeout_s })
end
function W.move_status() return mcall("move", "status") or {} end
function W.move_stop(log) return mcall("move", "stop", log) end

-- ------------------------------------------------------------------ the job
local function snapshot(J, st)
    st = st or W.conv(J.pc)
    local shown = M.choices(st)
    C().shown = shown
    return st, shown
end

local function result_of(J, ok, reason, data)
    data = data or {}
    local st = J.st or W.conv(J.pc)
    local shown = J.shown or M.choices(st)
    data.in_conversation = st.active == true
    data.speaker = st.speaker
    data.lines = J.lines
    data.options = {}
    for _, o in ipairs(shown) do data.options[#data.options + 1] = { n = o.n, text = o.text, available = o.available } end
    data.chose = J.chose
    data.quests_changed = M.quest_diff(J.q0, W.quests(J.pc) or J.q0)
    if #data.quests_changed == 0 then data.quests_changed = nil end
    return { ok = ok == true, reason = reason, data = data }
end

local function finish(J, res)
    if J.done then return end
    J.done = true
    local c = C()
    if J.handle then pcall(CancelDelayedAction, J.handle) end
    J.handle, J.tap = nil, nil
    if not paused() then
        if J.moving then pcall(W.move_stop, J.log); J.moving = false end
        if res.data and res.data.in_conversation then W.claim() else W.release() end
    end
    J.result = res
    c.last = { result = res, ended = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    if c.job == J then c.job = nil end
    local arb = mod("arbiter")
    if arb and J.token and not J.released then J.released = true; pcall(arb.release, J.log, J.token, res.ok and "done" or res.reason) end
    say(J.log, string.format("done %s %s: %s", tostring(res.ok), tostring(res.reason or ""), tostring(res.data and res.data.detail or "")))
end
local function fail(J, reason, why, detail) return finish(J, result_of(J, false, reason, { why = why, detail = detail })) end
local function set_phase(J, ph, note) J.phase, J.phase_t = ph, J.t; say(J.log, "phase " .. ph .. (note and (" " .. note) or "")) end

local function add_line(J, st)
    if st and st.line and st.line ~= J.last_line then
        J.lines[#J.lines + 1] = { speaker = st.speaker, text = st.line }
        J.last_line = st.line
        C().counts.lines = C().counts.lines + 1
    end
end

-- read: collect the line; continue through choice-less lines; stop at a choice or the end
local function step_read(J)
    local st, shown = snapshot(J)
    J.st, J.shown = st, shown
    if not st.active then
        return finish(J, result_of(J, true, nil, { ended = true, detail = J.chose and "The conversation ended." or "We finished talking." }))
    end
    add_line(J, st)
    if #shown > 0 then
        return finish(J, result_of(J, true, nil, { detail = string.format("%s says: %s Options: %s", tostring(st.speaker or "They"),
            tostring(st.line or "..."), options_words(shown)) }))
    end
    if (J.advanced or 0) >= M.cfg.max_lines or not st.continue then
        return finish(J, result_of(J, true, nil, { detail = string.format("%s says: %s", tostring(st.speaker or "They"), tostring(st.line or "...")),
            more = st.continue ~= nil or nil }))
    end
    J.advanced = (J.advanced or 0) + 1
    J.sig0 = M.signature(st)
    J.tap = { act = st.continue, frames = M.cfg.tap_frames }
    set_phase(J, "wait_change", "continue")
end

local function frame(J)
    local c = C()
    if J.gen ~= c.gen or J.done then return end
    if paused() then
        J.done = true
        if J.handle then pcall(CancelDelayedAction, J.handle) end
        J.result = { ok = false, reason = "interrupted", data = { why = "world_teardown", detail = "The world is reloading." } }
        if c.job == J then c.job = nil end
        return
    end
    local pawn = W.pawn(J.pc)
    if not pawn then return finish(J, result_of(J, false, "companion_down", { why = "no_pawn" })) end
    J.t = W.now(pawn)
    if J.tap then W.inject(J.tap.act); J.tap.frames = J.tap.frames - 1; if J.tap.frames <= 0 then J.tap = nil end end
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
    local me = W.loc(pawn)
    local ph = J.phase
    if ph == "approach" then
        local p = J.target.pos
        if me and d2(me, p) <= M.cfg.reach_m * 100 then if J.moving then W.move_stop(J.log); J.moving = false end; return set_phase(J, "press") end
        if not J.moving then W.go_to(J.log, p, M.cfg.stand_tol_m, M.cfg.approach_timeout_s); J.moving, J.move_t = true, J.t end
        local res = (W.move_status() or {}).result or {}
        if res.status == "failed" or res.status == "stopped" or J.t - J.move_t > M.cfg.approach_timeout_s then
            J.moving = false
            return fail(J, "path_blocked", "cant_reach", string.format("I can't get to %s.", tostring(J.target.name or "them")))
        end
        if res.status == "arrived" then J.moving = false; if me and d2(me, p) <= M.cfg.reach_m * 100 + 100 then return set_phase(J, "press") end end
        return
    end
    if ph == "press" then
        local p = J.target.pos
        if me then W.face(J.pc, math.deg(math.atan(p.Y - me.Y, p.X - me.X))) end
        local tg = W.target(pawn)
        if tg and tg.actor == J.target.id then
            local modal = W.gate()
            if modal and modal.kind ~= "mode" then
                return fail(J, "interrupted", "screen_open", string.format("A %s screen is open, so I can't talk right now.", tostring(modal.kind)))
            end
            J.sig0 = M.signature(W.conv(J.pc))
            W.press(J.log)
            J.presses = (J.presses or 0) + 1
            return set_phase(J, "open_wait")
        end
        if J.t - J.phase_t > M.cfg.face_s then
            return fail(J, "not_interactable", "not_talkable", string.format("I'm next to %s but the game won't let me talk to them%s.",
                tostring(J.target.name or "them"), tg and tg.actor and (" (it targets " .. tostring(tg.name or tg.prompt or tg.actor) .. ")") or ""))
        end
        return
    end
    if ph == "open_wait" then
        local st = W.conv(J.pc)
        if st.active and (M.signature(st) ~= J.sig0 or st.line) then
            C().counts.talks = C().counts.talks + 1
            W.claim()
            return step_read(J)
        end
        if J.t - J.phase_t > M.cfg.open_wait_s then
            if (J.presses or 0) < M.cfg.presses then return set_phase(J, "press", "re-press") end
            return fail(J, "verification_failed", "no_conversation", string.format("I pressed talk on %s but no conversation opened.", tostring(J.target.name or "them")))
        end
        return
    end
    if ph == "wait_change" then
        if J.tap then return end
        local st = W.conv(J.pc)
        if not st.active or M.signature(st) ~= J.sig0 then return step_read(J) end
        if J.t - J.phase_t > M.cfg.change_wait_s then
            if J.mode == "leave" then return fail(J, "verification_failed", "no_change", "I tried to end the conversation but it's still open.") end
            if J.advanced and J.advanced > 0 and not J.chose then
                return finish(J, result_of(J, true, nil, { detail = "The conversation stopped moving on.", stuck = true }))
            end
            return fail(J, "verification_failed", "no_change", string.format("I picked \"%s\" but the conversation didn't move on.", tostring(J.chose or "?")))
        end
    end
end
M._frame = frame

local function new_job(log, ctx, mode, pc, extra)
    local c = C()
    if c.job then finish(c.job, { ok = false, reason = "interrupted", data = { why = "new_talk", detail = "A new talk started." } }) end
    c.gen = c.gen + 1
    local pawn = W.pawn(pc)
    local t = W.now(pawn)
    local J = { gen = c.gen, log = log, pc = pc, mode = mode, t0 = t, t = t, phase_t = t, lines = {}, q0 = W.quests(pc) or {} }
    for k, v in pairs(extra or {}) do J[k] = v end
    c.job = J
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

function M.start(log, args, ctx)
    args = args or {}
    if paused() then return { ok = false, reason = "companion_down", data = { why = "paused", detail = "The world is loading." } } end
    local pc = W.pc()
    local pawn = W.pawn(pc)
    if not pawn then return { ok = false, reason = "companion_down", data = { why = "no_pawn" } } end
    local st = W.conv(pc)
    if args.leave == true then
        if not st.active then return { ok = false, reason = "invalid_args", data = { why = "not_in_conversation", detail = "I'm not talking to anyone." } } end
        local J = new_job(log, ctx, "leave", pc)
        J.sig0 = M.signature(st)
        if st.cancel then J.tap = { act = st.cancel, frames = M.cfg.tap_frames } end
        set_phase(J, "wait_change", "leave")
        run(J)
        return { ok = true }
    end
    if args.choose ~= nil then
        if not st.active then return { ok = false, reason = "invalid_args", data = { why = "not_in_conversation", detail = "I'm not talking to anyone, so there's nothing to choose." } } end
        local shown = C().shown or M.choices(st)
        local o, why = M.resolve(shown, args.choose)
        if not o then
            return { ok = false, reason = "invalid_args", data = { why = "invalid_choice", match = why, options = shown,
                detail = string.format("\"%s\" isn't one of the options: %s.", tostring(args.choose), options_words(shown)) } }
        end
        if not o.available then
            return { ok = false, reason = "not_unlocked", data = { why = "option_unavailable", detail = string.format("I can't pick \"%s\" yet; the game greys it out.", o.text) } }
        end
        -- the option's own input action from the CURRENT panel (same slot), else the panel's per-slot select actions
        local now_opts = M.choices(st)
        local act = (now_opts[o.n] and now_opts[o.n].text == o.text and now_opts[o.n].act) or o.act
        if not act then return { ok = false, reason = "body_error", data = { why = "no_option_input", detail = "I can see the options but not the key that picks them." } } end
        local J = new_job(log, ctx, "choose", pc, { chose = o.text })
        J.sig0 = M.signature(st)
        J.tap = { act = act, frames = M.cfg.tap_frames }
        C().counts.choices = C().counts.choices + 1
        set_phase(J, "wait_change", "choose " .. o.n .. " " .. o.text)
        run(J)
        return { ok = true }
    end
    if st.active and not args.target then
        local J = new_job(log, ctx, "read", pc)
        set_phase(J, "read")
        step_read(J)
        if not J.done then run(J) end
        return { ok = true }
    end
    if type(args.target) ~= "string" or args.target == "" then
        return { ok = false, reason = "invalid_args", data = { detail = "target (who to talk to: an id from look) is required to start talking" } }
    end
    local t = W.find(args.target, 120)
    if not t or not t.position then
        return { ok = false, reason = "unknown_target", data = { why = "unknown_target", detail = string.format("I can't see %s.", tostring(args.target)) } }
    end
    local pos = { X = t.position[1] * 100, Y = t.position[2] * 100, Z = (t.position[3] or 0) * 100 }
    local arb = mod("arbiter")
    local token, J
    if arb then
        local r = arb.request(log, { name = "talk", level = "command", resumable = false, uses_move = true, lease_s = M.cfg.lease_s,
            on_suspend = function() if J then J.suspended = true; J.moving = false end end,
            on_resume = function() if J and not J.done then J.suspended = false; J.moving = false; set_phase(J, "approach", "resumed"); return true end return false end,
            on_stop = function(_, _, why) if J and not J.done then J.released = true; finish(J, { ok = false, reason = "interrupted", data = { why = tostring(why), detail = "I was told to do something else." } }) end end })
        if not r.ok then return { ok = false, reason = "interrupted", data = { why = "pawn_busy", owner = r.owner, detail = "I'm busy with something else." } } end
        token = r.token
    end
    J = new_job(log, ctx, "start", pc, { token = token, target = { id = t.id or args.target, name = t.name, pos = pos } })
    set_phase(J, "approach", tostring(t.name) .. " " .. tostring(t.id))
    run(J)
    return { ok = true }
end

function M.stop(log, why)
    local J = C().job
    if J and not J.done then finish(J, { ok = false, reason = "interrupted", data = { why = why or "stopped", detail = "I stopped." } }) end
    return { ok = true }
end

function M.status()
    local c = C()
    local J = c.job
    return { ok = true, job = J and { mode = J.mode, phase = J.phase, lines = #J.lines } or nil, shown = c.shown, last = c.last, counts = c.counts, log = c.lines }
end

M.HANDLERS = {
    talk = function(log, args, ctx)
        M.api = ctx and ctx.api or M.api
        local r = M.start(log, args or {}, ctx)
        if not r.ok then return r end
        local J = C().job
        if not J then return (C().last and C().last.result) or { ok = false, reason = "body_error" } end
        local a = { kind = "talk", id = ctx and ctx.id, timeout_s = M.cfg.approach_timeout_s + 40 }
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
    talk = { { "sense", "local_pc" }, { "inventory", "interact_target" }, { "inventory", "press_interact" }, { "move", "go_to" }, { "move", "status" } },
}

do
    local OBJ = { __jsontype = "object" }
    local function obj(t) return setmetatable(t or {}, OBJ) end
    M.MANIFEST = {
        talk = { kind = "action", llm = true, moves = true, priority = "command", duration_s = 6, timeout_s = 140,
            detail_is_speech = false,
            description = "Talk to someone (an NPC from look, e.g. prompt Talk): walks over and starts the conversation, and "
                .. "returns what they say and your answer options. Then call again with choose = an option's number or text "
                .. "to answer, or leave = true to end it. Reports quests that changed.",
            args = { type = "object", properties = obj({
                target = { type = "string", description = "Who to talk to: an id from look (only to start)." },
                choose = { description = "Your answer: an option number or its text, from the last reply.",
                           anyOf = { { type = "integer" }, { type = "string" } } },
                leave = { type = "boolean", description = "End the conversation." } }) },
            ground = obj({ target = "thing" }),
            reasons = { "unknown_target", "not_interactable", "verification_failed", "invalid_args", "not_unlocked", "path_blocked",
                        "interrupted", "companion_down" } },
        talk_status = { kind = "probe", llm = false, moves = false, timeout_s = 5,
            args = { type = "object", properties = obj(), additionalProperties = false }, description = "Talk job state (debug)." },
    }
end

return M
