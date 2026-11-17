-- Offline tests for client_mod/scripts/talk.lua v2 (review docs/reviews/2026-10-26-talk-primitive-review.md):
-- option merge/numbering/resolve, quest diffs (ints/bools), and whole talks against a fake dialogue with the real
-- arbiter: the shared interact episode (faked as skills._new_episode/_episode_poll), the update counter, a hub
-- node that returns identical payloads, two-step selection, ServerOnly options, stale options, a conversation
-- ended elsewhere, pause, orphan cleanup, another screen, no dialogue UI.
-- Run:  lua client_mod/tests/test_talk.lua
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local pass, failn = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1 else failn = failn + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local T = 0
local loops, nid = {}, 0
function LoopInGameThreadWithDelay(ms, fn) nid = nid + 1; loops[nid] = { fn = fn }; return nid end
function CancelDelayedAction(h) loops[h] = nil end
function StaticFindObject() return nil end
function FindAllOf() return {} end
function FindFirstOf() return nil end

local IA = { cont = { n = "continue" }, cancel = { n = "cancel" } }
for i = 1, 6 do IA["k" .. i] = { n = "key" .. i } end
-- node -> {line, options = {{text, type, go}}} ; continue-only nodes have `next`
local TREE = {
    hello = { line = "Ah, an adventurer.", next = "hub" },
    hub = { line = "What brings you here?", options = {
        { text = "Tell me about farming.", type = 1, go = "hub", bools = { AskedFarming = true } }, -- returns to the SAME hub
        { text = "(server only branch)", type = 0, go = "hub" },
        { text = "I made a fishing net!", type = 1, go = "net" },
        { text = "Tell me about the dragon.", type = 2, go = "hub" },
        { text = "Goodbye.", type = 1, go = "END" } } },
    net = { line = "A fine net! Catch me some shrimp.", next = "END", give = "Shrimp Catcher" },
}

local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWTalk, _G.DWArbiter, _G.DW_PAUSE, _G.DWTalkHook = nil, nil, nil, nil
    Wd = { npc = "BP_NPC_WiseOldMan_C_1", node = nil, active = false, panel = o.panel ~= false, mode = "DIM_Gameplay",
           quests = { { quest = "First Steps", state = "complete", ints = {}, bools = {} } }, presses = {}, epresses = 0,
           mute = o.mute, two_step = o.two_step, deaf = o.deaf, selected = nil, pawn_id = "PAWN_1" }
end
local function HK() _G.DWTalkHook = _G.DWTalkHook or { count = 0 }; return _G.DWTalkHook end

local function go(node, extra)
    local q = extra or {}
    if q.bools then for k, v in pairs(q.bools) do Wd.quests[1].bools[k] = v end end
    if node == "END" then Wd.node, Wd.active, Wd.mode = nil, false, "DIM_Gameplay"; HK().count = HK().count + 1; return end
    Wd.node, Wd.active, Wd.mode = node, true, "DIM_ConversationUI"
    Wd.selected = nil
    local n = TREE[node]
    if n.give then Wd.quests[#Wd.quests + 1] = { quest = n.give, state = "given", objective = "CatchShrimp", ints = {}, bools = {} } end
    HK().count = HK().count + 1 -- the game's HandleConversationUpdated (hooked, count only)
end

-- shown panel rows for a node: user options only, keyed by on-screen number (key1.. in OptionSelectInputActions order)
local function rows(node)
    local out = {}
    local k = 0
    for i, o in ipairs(TREE[node].options or {}) do
        if o.type ~= 0 then k = k + 1; out[#out + 1] = { text = o.text, act = IA["k" .. k], n = k, src = i } end
    end
    return out
end

local function on_press(name)
    Wd.presses[#Wd.presses + 1] = name
    if Wd.deaf or not Wd.node then return end
    local n = TREE[Wd.node]
    if name == "continue" then
        if Wd.swallow_continue and Wd.node == "hello" then Wd.push_at = T + 0.06; return end
        if Wd.selected then local o = n.options[Wd.selected.src]; go(o.go, o); return end
        if n.next then go(n.next) end
    elseif name == "cancel" then go("END")
    elseif name:match("^key%d$") and n.options then
        local k = tonumber(name:sub(4))
        for _, r in ipairs(rows(Wd.node)) do
            if r.n == k then
                local o = n.options[r.src]
                if o.type ~= 1 then return end
                if Wd.two_step then Wd.selected = r else go(o.go, o) end
            end
        end
    end
end

local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
local fake_move = { go_to = function() return { ok = true } end, status = function() return { mode = "idle" } end, stop = function() return { ok = true } end,
                    snapshot = function() end, restore = function() return true end }
A.set_move(fake_move)
-- the shared interact episode (skills.lua), faked: approach 1 s, then ONE interact press, then verify
local SK = {}
function SK._new_episode(api, thing) return { thing = thing, phase = "approach", t0 = nil } end
function SK._episode_poll(api, e, t)
    e.t0 = e.t0 or t
    if e.phase == "approach" then if t - e.t0 > 1 then e.phase = "verify"; Wd.epresses = Wd.epresses + 1; if not Wd.mute then go("hello") end; e.vt = t end; return nil end
    if t - e.vt > 3 then return { ok = false, reason = "verification_failed", data = { detail = "nothing changed", target = "NPC_X", prompt = "Talk", presses = 2 } } end
    return nil
end
local K = assert(loadfile(root .. "/client_mod/scripts/talk.lua"))()
K.clock = function() return T end
K.set_modules({ move = fake_move, arbiter = A, skills = SK })
local W = K.W
local PC = {}
W.pc = function() return PC end
W.pawn = function() return { id = "P" } end
W.pawn_id = function() return Wd.pawn_id end
W.dead = function() return false end
W.scalars = function()
    if _G.DW_PAUSE then return { active = false, paused = true } end
    return { active = Wd.active, npc = Wd.active and Wd.npc or nil, mode = Wd.mode, count = HK().count }
end
W.read = function()
    local st = W.scalars()
    st.options, st.panel_rows = {}, {}
    if not st.active then return st end
    local n = TREE[Wd.node]
    st.speaker, st.line, st.node = "Wise Old Man", n.line, Wd.node
    for _, o in ipairs(n.options or {}) do st.options[#st.options + 1] = { text = o.text, type = o.type } end
    if not n.options then st.options[1] = { type = 1 } end -- a continue-only node: one textless choice
    if Wd.panel then
        st.panel = true
        if n.options then st.panel_rows = rows(Wd.node) end
        st.continue, st.cancel = IA.cont, IA.cancel
        st.selected = Wd.selected and Wd.selected.text or nil
    end
    if Wd.on_read then Wd.on_read() end
    return st
end
W.quests = function()
    local out = {}
    for i, q in ipairs(Wd.quests) do
        local b = {}
        for k, v in pairs(q.bools) do b[k] = v end
        out[i] = { quest = q.quest, state = q.state, objective = q.objective, ints = {}, bools = b }
    end
    return out
end
W.ui_press = function(act) if Wd.modal then return false, Wd.modal end; Wd.held = act.n; return true end
W.claim = function() Wd.claimed = true end
W.release = function() Wd.claimed = false end
W.arm_hook = function() return true end
W.skills = function() return SK end
K.api = { find_thing = function(id) if id == "BP_NPC_WiseOldMan_C_1" then return { id = id, name = "Wise Old Man", position = { 15, 0, 0 } } end end,
          call = function() return { ok = true } end }

local function pump(sec, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(sec / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        -- the game sees a held key on its rising edge only (one press per hold)
        local h = Wd.held
        Wd.held = nil
        if h and h ~= Wd.prev_held then on_press(h) end
        if Wd.push_at and T >= Wd.push_at then Wd.push_at = nil; go("hub") end
        Wd.prev_held = h
        if until_fn and until_fn() then return true end
    end
end
local function talk(args, sec)
    local r = K.HANDLERS.talk(nil, args or {}, { id = "t", api = K.api })
    if not r.pending then return r end
    local res
    pump(sec or 120, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT", data = K.status() }
end
local function count(list, name) local n = 0; for _, x in ipairs(list) do if x == name then n = n + 1 end end; return n end

-- ---------------------------------------------------------------- pure
do
    local st = { options = { { text = "A", type = 1 }, { text = "S", type = 0 }, { text = "B", type = 2 } },
                 panel_rows = { { text = "B", act = 2, n = 2 }, { text = "A", act = 1, n = 1 } } }
    local shown = K.choices(st)
    check("choices sorted by on-screen number, joined by text", #shown == 2 and shown[1].text == "A" and shown[2].text == "B" and shown[2].available == false)
    check("server-only never shown (payload only)", #K.choices({ options = { { text = "X", type = 1 }, { text = "S", type = 0 } } }) == 1)
    -- live P2 (2026-10-26): the panel rows' DisplayName read nil; the texts come from the payload by position
    local p2 = K.choices({ options = { { text = "Yes please [Begin Tutorial]", type = 1 }, { text = "I can work it out [Skip Tutorial]", type = 1 } },
                           panel_rows = { { act = "k1", n = 1 }, { act = "k2", n = 2 } } })
    check("nil panel text: payload text by position, panel key kept", #p2 == 2 and p2[1].text == "Yes please [Begin Tutorial]"
        and p2[1].act == "k1" and p2[2].act == "k2" and p2[2].available == true)
    local opts ={ { n = 1, text = "Tell me about farming." }, { n = 2, text = "I made a fishing net!" }, { n = 3, text = "Tell me about the dragon." } }
    check("resolve by number", K.resolve(opts, 2).n == 2)
    check("resolve by text, any case", K.resolve(opts, "i made a fishing net!").n == 2)
    check("resolve unique substring", K.resolve(opts, "net").n == 2)
    check("resolve ambiguous", select(2, K.resolve(opts, "Tell me")) == "ambiguous")
    -- a target by name: the nearest perceived thing whose prompt is the game's "Talk" (never a non-NPC namesake)
    local rows = { { id = "Statue_1", name = "Doric Statue", prompt = "Inspect", position = { 0, 0, 0 } },
                   { id = "BP_NPC_Doric_FTUE_C_1", name = "Doric", prompt = "Talk", position = { 1, 0, 0 } } }
    local fapi = { find_thing = function() return nil end, census_things = function() return rows end,
                   resolve_name = function(rs, what) for _, r in ipairs(rs) do if r.name:lower() == what:lower() then return r end end end }
    check("target by name -> the Talk NPC", (K.resolve_target(fapi, "doric") or {}).id == "BP_NPC_Doric_FTUE_C_1")
    check("target by name: no Talk namesake -> nil", K.resolve_target(fapi, "doric statue") == nil)
    local ow = K.outcome_words({ { quest = "Getting Started", from = "given", to = "complete" },
                                 { quest = "Ratcatcher", from = "ungiven", to = "given", step = "Speak to Vannaka near the windmill." } },
                               { gained = { soup = 1 } }, { soup = "Vegetable Soup" })
    check("outcome words", ow == "Quest Getting Started is complete. New quest Ratcatcher: Speak to Vannaka near the windmill. Given to you in this conversation: 1 Vegetable Soup.", ow)
    check("inv diff", (K.inv_diff({ a = 2, b = 1 }, { a = 3 }) or {}).gained.a == 1 and K.inv_diff({ a = 2, b = 1 }, { a = 3 }).lost.b == 1
        and K.inv_diff({ a = 1 }, { a = 1 }) == nil)
    local qd = K.quest_diff({ { quest = "A", state = "given", ints = { n = 1 }, bools = {} } },
                           { { quest = "A", state = "given", ints = { n = 2 }, bools = { b = true } }, { quest = "B", state = "given" } })
    check("quest diff: ints and bools", #qd == 2 and qd[1].ints.n.to == 2 and qd[1].bools.b.to == true and qd[2].from == "ungiven")
    -- live 2026-11-01: two quests named "Rune Mysteries" (one complete, one given); the hand-in only moved the given one
    local RM = { { quest = "Rune Mysteries", asset = "Q_RM1", state = "complete" }, { quest = "Rune Mysteries", asset = "Q_RM2", state = "given", objective = "Objective2", step = "Bring 50 Ash Logs" } }
    qd = K.quest_diff(RM, { RM[1], { quest = "Rune Mysteries", asset = "Q_RM2", state = "given", objective = "Objective3", step = "Return to Zanik." } })
    local w = K.outcome_words(qd)
    check("quest diff: two quests of one name matched by asset", #qd == 1 and qd[1].step == "Return to Zanik." and w == "Rune Mysteries, next step: Return to Zanik.", w)
    -- live 18:56Z: part 1 complete and part 2 given in one talk; "is complete" alone read as the whole quest done
    w = K.outcome_words({ { quest = "Rune Mysteries", from = "given", to = "complete" },
                          { quest = "Rune Mysteries", from = "ungiven", to = "given", step = "Mine Rune Essence." } })
    -- window s17 (2026-11-17), rollouts of runs 044508 and 045210: "One part ... is complete, but ... is not over. It
    -- goes on as a new quest of the same name, now given: ..." still read as a job done (went on 4 of 10); worded as
    -- the one quest a player sees, moving to its next step, 9 of 10
    check("a finished quest followed by its namesake is one quest moving on", w == "Rune Mysteries is not finished: it moved on to its next step, Mine Rune Essence.", w)
    w = K.outcome_words({ { quest = "Rune Mysteries", from = "given", to = "complete" },
                          { quest = "Rune Mysteries", from = "ungiven", to = "given" } })
    check("... and with no step text it still says the quest is not finished", w == "Rune Mysteries is not finished: it moved on to its next step.", w)
    w = K.outcome_words({ { quest = "Getting Started", from = "given", to = "complete" },
                          { quest = "Ratcatcher", from = "ungiven", to = "given", step = "Kill rats." } })
    check("a finished quest and a new one of another name are said as two", w == "Quest Getting Started is complete. New quest Ratcatcher: Kill rats.", w)
    check("conversation mode word", K.is_conversation_mode("DIM_ConversationUI") and not K.is_conversation_mode("DIM_SpellcastingMode"))
end

-- ---------------------------------------------------------------- start through the shared episode; read to the hub
do
    reset()
    local res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("start: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("start: the episode pressed E once", Wd.epresses == 1, Wd.epresses)
    check("start: both lines in order with speaker", #res.data.lines == 2 and res.data.lines[1].text == "Ah, an adventurer." and res.data.lines[2].speaker == "Wise Old Man")
    check("start: server-only option hidden; 4 numbered options", #res.data.options == 4 and res.data.options[2].text == "I made a fishing net!" and res.data.options[2].n == 2)
    check("start: greyed option kept with available=false", res.data.options[3].available == false)
    check("start: node signature returned", type(res.data.node) == "string" and res.data.node ~= "inactive")
    check("start: one Continue for the one continue-only line", count(Wd.presses, "continue") == 1)
    check("start: claim released between turns (R5)", Wd.claimed == false and A.owner() == nil)

    -- hub: the same node comes back identical; the update counter still proves the advance (finding 5)
    res = talk({ choose = 1 })
    check("hub choice: ok (no false no_change)", res.ok == true and res.data.chose == "Tell me about farming.", tostring(res.reason) .. " " .. tostring(res.data and res.data.why))
    check("hub choice: quest bool reported", res.data.quests_changed and res.data.quests_changed[1].bools and res.data.quests_changed[1].bools.AskedFarming.to == true)
    check("hub choice: no Continue pressed on a choice node", count(Wd.presses, "continue") == 1, count(Wd.presses, "continue"))

    local bad = K.HANDLERS.talk(nil, { choose = "the dragon" }, { api = K.api })
    check("greyed option refused", bad.data.why == "option_unavailable")
    bad = K.HANDLERS.talk(nil, { choose = "sing" }, { api = K.api })
    check("unknown option lists the options", bad.data.why == "invalid_choice" and bad.data.detail:find("2) I made a fishing net!", 1, true) ~= nil)

    res = talk({ choose = "fishing net" })
    check("net: quest given, cumulative from the start", res.ok and res.data.quests_changed and #res.data.quests_changed == 2, res.data.quests_changed and #res.data.quests_changed)
    check("net: ended after the last line", res.data.ended == true and res.data.in_conversation == false and Wd.claimed == false)
end

-- ---------------------------------------------------------------- finding 1: options appear between read and press
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    talk({ leave = true })
    -- the game ignores the Continue, but the server pushes the choice node a tick later: no second Continue
    Wd.swallow_continue = true
    local res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.swallow_continue = nil
    check("race: exactly one Continue, then the options", res.ok and count(Wd.presses, "continue") == 2 and #res.data.options == 4,
        count(Wd.presses, "continue") .. " " .. tostring(res.data and #res.data.options))
end

-- ---------------------------------------------------------------- finding 2: two-step selection
do
    reset({ two_step = true })
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    local res = talk({ choose = 2 })
    check("two-step: confirmed after the highlight matched", res.ok and res.data.ended and K.status().counts.confirms == 1, tostring(res.reason))
end

-- ---------------------------------------------------------------- finding 3: stale options
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    TREE.hub2 = { line = "Something else now.", options = { { text = "Ok.", type = 1, go = "END" } } }
    Wd.node = "hub2"; HK().count = HK().count + 1 -- the server moved on
    local before = #Wd.presses
    local r = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    check("stale: options_changed with the new options", r.reason == "invalid_args" and r.data.why == "options_changed" and r.data.options[1].text == "Ok.", r.data and r.data.why)
    check("stale: nothing pressed", #Wd.presses == before)
    local res = talk({ choose = 1 })
    check("stale: then the new option works", res.ok and res.data.ended, tostring(res.reason))
end

-- ---------------------------------------------------------------- input never reaches the UI: stop, don't guess
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.deaf = true
    local res = talk({ choose = 2 })
    check("deaf UI: input_not_reaching_ui", res.reason == "verification_failed" and res.data.why == "input_not_reaching_ui", res.data and res.data.why)
    check("deaf UI: never pressed Continue to force it", count(Wd.presses, "continue") == 1)
end

-- ---------------------------------------------------------------- args, ended elsewhere, pause, screens
do
    reset()
    local mx = talk({ target = "BP_NPC_WiseOldMan_C_1", choose = 1 })
    check("target + choose with no dialogue: opens it, says so, picks nothing", mx.ok and #mx.data.options == 4 and mx.data.chose == nil
        and tostring(mx.data.note):find("opened the conversation", 1, true) ~= nil, mx.data and mx.data.note)
    reset()
    check("{} when not talking", K.HANDLERS.talk(nil, {}, { api = K.api }).data.why == "not_in_conversation")
    check("leave when not talking", K.HANDLERS.talk(nil, { leave = true }, { api = K.api }).data.why == "not_in_conversation")
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    local res = talk({})
    check("{} re-reads", res.ok and #res.data.options == 4)
    Wd.node, Wd.active, Wd.mode = nil, false, "DIM_Gameplay" -- combat's GenericBack ended it
    local r = K.HANDLERS.talk(nil, { choose = 1 }, { api = K.api })
    check("ended elsewhere: says so", r.data.why == "not_in_conversation" and r.data.detail:find("ended without me", 1, true) ~= nil, r.data.detail)

    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    _G.DW_PAUSE = true
    local before = #Wd.presses
    r = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    check("pause: refused, no press", r.reason == "companion_down" and #Wd.presses == before)
    _G.DW_PAUSE = nil
    Wd.node, Wd.active = nil, false
    r = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    check("after unpause: not_in_conversation, no stale index", r.data.why == "not_in_conversation" and #Wd.presses == before)

    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.mode = "DIM_WorldMap"
    res = talk({})
    check("map opened mid-conversation: screen_open names it", res.data.why == "screen_open" and res.data.detail:find("DIM_WorldMap", 1, true) ~= nil, res.data.detail)

    reset({ panel = false })
    res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("no dialogue UI: reported, nothing pressed", res.data.why == "no_dialogue_ui" and #Wd.presses == 0, res.data.why)

    reset({ mute = true })
    res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("press with no dialogue: no_conversation", res.reason == "verification_failed" and res.data.why == "no_conversation", tostring(res.reason))
    -- live 2026-11-16 12:37Z: the failure said nothing of what the press saw, so its cause could only be guessed at
    check("no_conversation carries what the press saw", res.data.prompt == "Talk" and res.data.presses == 2 and res.data.pressed == "NPC_X"
        and res.data.detail:find('2 times (the prompt the game showed on them read "Talk") but no conversation opened.', 1, true) ~= nil, res.data.detail)
    -- live 20261116-194849: a fight held the talk up; its loot and the food he ate were said as that conversation's
    -- ("no conversation opened. Given to you in this conversation: 5 Goblin Pack. Gone from your bag during it: 1 Rat Roast.")
    reset({ mute = true })
    do
        local carried0, n = W.carried, 0
        W.carried = function()
            n = n + 1
            if n == 1 then return { roast = 1 }, { roast = "Rat Roast" } end
            return { pack = 5 }, { pack = "Goblin Pack" }
        end
        res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
        W.carried = carried0
    end
    check("no conversation opened: what changed in his bag meanwhile is not said to be given in it", res.data.why == "no_conversation"
        and res.data.items == nil and not tostring(res.data.detail):find("Given to you", 1, true)
        and not tostring(res.data.detail):find("Gone from your bag", 1, true), res.data.detail)

    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.modal = { kind = "build" }
    r = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    local rr = r.pending and nil or r
    if r.pending then pump(5, function() rr = r.pending.poll(); return rr ~= nil end) end
    check("another modal: screen_open, nothing pressed", rr and rr.data.why == "screen_open", rr and rr.data and rr.data.why)
    Wd.modal = nil
    reset()
    check("unknown target", K.HANDLERS.talk(nil, { target = "nobody" }, { api = K.api }).reason == "unknown_target")
end

-- ---------------------------------------------------------------- a second choose while the first is pending
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    local a = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    local b = K.HANDLERS.talk(nil, { choose = 2 }, { api = K.api })
    check("double choose: the second waits for the first", a.pending ~= nil and b.reason == "invalid_args" and b.data.why == "answer_pending", b.data and b.data.why)
    local res
    pump(10, function() res = a.pending.poll(); return res ~= nil end)
    check("double choose: the first one completes", res and res.ok == true)
end

-- ---------------------------------------------------------------- finding 9: orphan cleanup with the panel's Cancel
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    _G.DWTalk.conv = nil -- talk lost its state (bridge restart)
    local s1 = K.sweep_orphan()
    check("orphan: first seen, nothing pressed", s1.state == "orphan_seen")
    T = T + 1.5
    local s2 = K.sweep_orphan()
    check("orphan: Cancel pressed", s2.state == "cancel_pressed")
    pump(0.1)
    check("orphan: dialogue closed", Wd.active == false and count(Wd.presses, "cancel") == 1)
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("owned conversation is not an orphan", K.sweep_orphan().state == "owned")
end

-- ---------------------------------------------------------------- live 17:2xZ: CurrentNPC reads nil on the client
do
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.npc = nil
    check("nil npc: our open dialogue is owned, not swept", K.sweep_orphan().state == "owned")
    T = T + 1.5
    check("nil npc: still owned a moment later, no Cancel", K.sweep_orphan().state == "owned" and count(Wd.presses, "cancel") == 0)
    local r = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("nil npc: target while talking re-reads it", r.ok and #r.data.options == 4, r.data and r.data.detail)
    r = talk({ target = "BP_NPC_WiseOldMan_C_1", choose = 2 })
    check("target + choose on an open dialogue answers it", r.ok and r.data.chose == "I made a fishing net!", r.data and (r.data.chose or r.data.detail))
end

-- ---------------------------------------------------------------- contract
do
    check("manifest talk action", K.MANIFEST.talk.kind == "action" and K.MANIFEST.talk.llm and K.MANIFEST.talk.moves)
    check("sweep_orphan exported", type(K.sweep_orphan) == "function")
    local src = assert(io.open(root .. "/client_mod/scripts/talk.lua", "rb")):read("*a")
    local code = src:gsub("%-%-[^\n]*", "")
    check("no server RPC / advance calls", not code:find("[:.]Server_%w+%s*%(") and not code:find("AdvanceConversation", 1, true)
          and not code:find("HideConversationUI", 1, true) and not code:find("raw_inject", 1, true))
    check("no NPC or quest names in logic", not code:find("Wise Old Man", 1, true) and not code:find("Shrimp", 1, true))
end

print(string.format("test_talk: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
