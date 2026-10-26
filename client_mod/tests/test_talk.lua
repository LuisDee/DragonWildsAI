-- Offline tests for client_mod/scripts/talk.lua: option merge/resolve, quest diffs, and whole talks against a
-- fake dialogue (an NPC whose interact opens a conversation tree: continue-only lines, a choice node with an
-- unavailable option, a quest given by one answer, an end), with the REAL arbiter.
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
local function d2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end

local IA = { cont = { n = "continue" }, cancel = { n = "cancel" }, o1 = { n = "opt1" }, o2 = { n = "opt2" }, o3 = { n = "opt3" } }
-- the conversation tree: node -> {line, options = {{text, type, go}}}; continue-only nodes have `next`
local TREE = {
    hello = { speaker = "Wise Old Man", line = "Ah, an adventurer.", next = "ask" },
    ask = { speaker = "Wise Old Man", line = "What brings you here?", options = {
        { text = "Tell me about farming.", type = 1, go = "farm" },
        { text = "I made a fishing net!", type = 1, go = "net" },
        { text = "Tell me about the dragon.", type = 2, go = "ask" },
        { text = "Goodbye.", type = 1, go = "END" } } },
    farm = { speaker = "Wise Old Man", line = "Dig, plant, water.", next = "ask" },
    net = { speaker = "Wise Old Man", line = "A fine net! Catch me some shrimp.", next = "END", give = "Shrimp Catcher" },
}

local Wd
local function reset(o)
    o = o or {}
    T = 0
    for k in pairs(loops) do loops[k] = nil end
    _G.DWTalk, _G.DWArbiter, _G.DW_PAUSE = nil, nil, nil
    Wd = { pawn = { pos = { X = 0, Y = 0, Z = 0 } }, npc = { id = "BP_NPC_WiseOldMan_C_1", name = "Wise Old Man", pos = { X = 1500, Y = 0, Z = 0 } },
           node = nil, quests = { { quest = "First Steps", state = "complete" } }, presses = 0, mute = o.mute, wrong_target = o.wrong_target,
           water = o.water, modal = o.modal, stuck = o.stuck }
end

local fake_move = {}
function fake_move.go_to(log, pos) Wd.goal = { X = pos[1] * 100, Y = pos[2] * 100, Z = 0 }; Wd.move_res = nil; return { ok = true } end
function fake_move.status() if Wd.move_res then return { mode = "idle", result = Wd.move_res } end; return { mode = Wd.goal and "goto" or "idle" } end
function fake_move.stop() Wd.goal = nil; return { ok = true } end
function fake_move.snapshot() return nil end
function fake_move.restore() return true end

local function go(node)
    if node == "END" then Wd.node = nil; return end
    Wd.node = node
    local n = TREE[node]
    if n.give then Wd.quests[#Wd.quests + 1] = { quest = n.give, state = "given", objective = "CatchShrimp" } end
end

local function step(dt)
    local g = Wd.goal
    if g then
        if Wd.water then Wd.goal = nil; Wd.move_res = { status = "failed" }; return end
        local p = Wd.pawn.pos
        local d = d2(p, g)
        if d <= 600 * dt + 150 then p.X, p.Y = g.X - 150, g.Y; Wd.goal = nil; Wd.move_res = { status = "arrived" }
        else p.X, p.Y = p.X + (g.X - p.X) / d * 600 * dt, p.Y + (g.Y - p.Y) / d * 600 * dt end
    end
    -- the game: one press (rising edge) of an injected input acts on the open node
    local inj = Wd.injected
    Wd.injected = nil
    if inj and inj ~= Wd.prev_inj and Wd.node and not Wd.stuck then
        local n = TREE[Wd.node]
        if inj == "continue" and n.next then go(n.next)
        elseif inj == "cancel" then go("END")
        elseif inj:match("^opt%d$") and n.options then
            local o = n.options[tonumber(inj:sub(4))]
            if o and o.type == 1 then go(o.go) end
        end
    end
    Wd.prev_inj = inj
end

local A = assert(loadfile(root .. "/client_mod/scripts/arbiter.lua"))()
A.clock = function() return T end
A.set_move(fake_move)
local K = assert(loadfile(root .. "/client_mod/scripts/talk.lua"))()
K.clock = function() return T end
K.set_modules({ move = fake_move, arbiter = A })
local W = K.W
local PC = {}
W.pc = function() return PC end
W.pawn = function() return Wd.pawn end
W.loc = function(p) return { X = p.pos.X, Y = p.pos.Y, Z = 0 } end
W.dead = function() return false end
W.conv = function()
    if not Wd.node then return { active = false, options = {}, panel_options = {} } end
    local n = TREE[Wd.node]
    local st = { active = true, speaker = n.speaker, line = n.line, node = Wd.node, options = {}, panel_options = {}, panel = true,
                 continue = IA.cont, cancel = IA.cancel }
    for i, o in ipairs(n.options or {}) do
        st.options[i] = { text = o.text, type = o.type }
        st.panel_options[i] = { text = o.text, act = IA["o" .. i] }
    end
    if not n.options then st.options[1] = { text = nil, type = 1 } end -- a continue-only node: one textless choice
    return st
end
W.quests = function() local out = {}; for i, q in ipairs(Wd.quests) do out[i] = { quest = q.quest, state = q.state, objective = q.objective } end; return out end
W.target = function()
    if Wd.wrong_target then return { actor = "BP_Chest_C_1", name = "Chest" } end
    if d2(Wd.pawn.pos, Wd.npc.pos) <= 350 then return { actor = Wd.npc.id, prompt = "Talk" } end
    return { none = true }
end
W.press = function() Wd.presses = Wd.presses + 1; if not Wd.mute then go("hello") end; return { ok = true } end
W.inject = function(a) Wd.injected = a.n; return true end
W.gate = function() return Wd.modal end
W.claim = function() Wd.claimed = true end
W.release = function() Wd.claimed = false end
W.find = function(id) if id == Wd.npc.id then return { id = id, name = Wd.npc.name, position = { Wd.npc.pos.X / 100, 0, 0 } } end end
W.face = function() end

local function pump(sec, until_fn)
    local dt = 0.02
    for _ = 1, math.floor(sec / dt) do
        T = math.floor((T + dt) * 100 + 0.5) / 100
        local ls = {}
        for _, l in pairs(loops) do ls[#ls + 1] = l end
        for _, l in ipairs(ls) do l.fn() end
        step(dt)
        if until_fn and until_fn() then return true end
    end
end
local function talk(args, sec)
    local r = K.HANDLERS.talk(nil, args or {}, { id = "t" })
    if not r.pending then return r end
    local res
    pump(sec or 120, function() res = r.pending.poll(); return res ~= nil end)
    return res or { ok = false, reason = "TEST_TIMEOUT", data = K.status() }
end

-- pure
do
    local shown = K.choices({ options = { { text = "A", type = 1 }, { text = "B", type = 2 }, { type = 0, text = "hidden" } },
                              panel_options = { { text = "A", act = 1 }, { text = "B", act = 2 } } })
    check("choices from the panel", #shown == 2 and shown[1].act == 1 and shown[2].available == false)
    check("choices from the payload when no panel rows", #K.choices({ options = { { text = "X", type = 1 }, { text = "Y", type = 0 } } }) == 1)
    local opts = { { n = 1, text = "Tell me about farming." }, { n = 2, text = "I made a fishing net!" }, { n = 3, text = "Tell me about the dragon." } }
    check("resolve by number", K.resolve(opts, 2).n == 2)
    check("resolve by numeric string", K.resolve(opts, " 3 ").n == 3)
    check("resolve exact text, any case", K.resolve(opts, "i made a fishing net!").n == 2)
    check("resolve unique substring", K.resolve(opts, "net").n == 2)
    local _, why = K.resolve(opts, "Tell me")
    check("resolve ambiguous", why == "ambiguous")
    _, why = K.resolve(opts, 9)
    check("resolve bad number", why == "no_such_number")
    local qd = K.quest_diff({ { quest = "A", state = "given", objective = "x" } }, { { quest = "A", state = "complete" }, { quest = "B", state = "given" } })
    check("quest diff", #qd == 2 and qd[1].to == "complete" and qd[2].from == "ungiven")
end

-- start: walks over, presses talk once, reads through the continue line to the first choice
do
    reset()
    local res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("start: ok", res.ok == true, tostring(res.reason) .. " " .. tostring(res.data and res.data.detail))
    check("start: one press", Wd.presses == 1)
    check("start: both lines read", res.data.lines and #res.data.lines == 2 and res.data.lines[1].text == "Ah, an adventurer.", res.data.lines and #res.data.lines)
    check("start: 4 options with availability", #res.data.options == 4 and res.data.options[3].available == false)
    check("start: in conversation, mode claimed", res.data.in_conversation == true and Wd.claimed == true)
    check("start: arbiter released", A.owner() == nil)
    check("start: detail lists options", res.data.detail:find("2) I made a fishing net!", 1, true) ~= nil, res.data.detail)

    local bad = K.HANDLERS.talk(nil, { choose = "the dragon" }, { id = "c" })
    check("unavailable option refused", bad.ok == false and bad.data.why == "option_unavailable", bad.data and bad.data.why)
    bad = K.HANDLERS.talk(nil, { choose = "sing a song" }, { id = "c" })
    check("unknown option refused with the list", bad.reason == "invalid_args" and bad.data.why == "invalid_choice" and bad.data.detail:find("1) Tell me about farming", 1, true) ~= nil)

    res = talk({ choose = 1 })
    check("choose farming: ok", res.ok == true and res.data.chose == "Tell me about farming.", tostring(res.reason))
    check("choose farming: line then back to the choice", res.data.lines[1].text == "Dig, plant, water." and #res.data.options == 4, res.data.lines[1] and res.data.lines[1].text)

    res = talk({ choose = "fishing net" })
    check("choose net: quest given", res.ok == true and res.data.quests_changed and res.data.quests_changed[1].quest == "Shrimp Catcher"
          and res.data.quests_changed[1].to == "given", res.data.quests_changed and res.data.quests_changed[1] and res.data.quests_changed[1].quest)
    check("choose net: ended after the last line", res.data.ended == true and res.data.in_conversation == false)
    check("choose net: mode released", Wd.claimed == false)
end

do -- leave
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    local res = talk({ leave = true })
    check("leave: ok and inactive", res.ok == true and res.data.in_conversation == false, tostring(res.reason))
    local r = K.HANDLERS.talk(nil, { leave = true }, {})
    check("leave when not talking", r.reason == "invalid_args" and r.data.why == "not_in_conversation")
    r = K.HANDLERS.talk(nil, { choose = 1 }, {})
    check("choose when not talking", r.reason == "invalid_args" and r.data.why == "not_in_conversation")
end

do -- read only (already in a conversation, no args)
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    local res = talk({})
    check("read: options again", res.ok and #res.data.options == 4)
end

do -- failures
    reset({ mute = true })
    local res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("no conversation: verification_failed after 2 presses", res.reason == "verification_failed" and res.data.why == "no_conversation" and Wd.presses == 2, tostring(res.reason) .. " " .. tostring(Wd.presses))
    reset({ wrong_target = true })
    res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("not talkable names the target", res.reason == "not_interactable" and res.data.detail:find("Chest", 1, true) ~= nil, res.data and res.data.detail)
    reset({ water = true })
    res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("cant reach", res.reason == "path_blocked", res.reason)
    reset({ modal = { kind = "build" } })
    res = talk({ target = "BP_NPC_WiseOldMan_C_1" })
    check("modal open: no press", res.reason == "interrupted" and res.data.why == "screen_open" and Wd.presses == 0, tostring(res.reason))
    reset()
    res = K.HANDLERS.talk(nil, { target = "nobody" }, {})
    check("unknown target", res.reason == "unknown_target")
    res = K.HANDLERS.talk(nil, {}, {})
    check("no target, not talking", res.reason == "invalid_args")
    reset()
    talk({ target = "BP_NPC_WiseOldMan_C_1" })
    Wd.stuck = true
    res = talk({ choose = 1 })
    check("choice that doesn't advance: no_change", res.reason == "verification_failed" and res.data.why == "no_change", tostring(res.reason))
end

do -- contract
    check("manifest talk action", K.MANIFEST.talk.kind == "action" and K.MANIFEST.talk.llm and K.MANIFEST.talk.moves)
    check("manifest no top-level anyOf", K.MANIFEST.talk.args.anyOf == nil)
    local src = assert(io.open(root .. "/client_mod/scripts/talk.lua", "rb")):read("*a")
    local code = src:gsub("%-%-[^\n]*", "")
    check("no server RPC calls", not code:find("[:.]Server_%w+%s*%(") and not code:find("AdvanceConversation", 1, true))
end

print(string.format("test_talk: %d passed, %d failed", pass, failn))
if failn > 0 then os.exit(1) end
