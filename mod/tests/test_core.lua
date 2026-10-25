-- Offline unit tests for the shared core and the promoted services: body/util.lua,
-- body/removal.lua, body/speech.lua (relay route), scripts/debug_cmds.lua (lookup order) and the
-- bridge's top-level probe flag. Fake UE objects only; nothing here needs a server.
-- Usage: lua test_core.lua <empty_dir>   (tests/test_lua_core.py runs it with a pytest tmp dir)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local H = dofile(here .. "/bridge_harness.lua")
package.path = here .. "/../?.lua;" .. package.path -- body.* (mod root), as main.lua does in game
local json = require("dkjson")
local U = require("body.util")
local removal = require("body.removal")
local speech = require("body.speech")
local debug_cmds = require("debug_cmds")
local bridge = require("bridge")

local dir = assert(arg[1] or os.getenv("DW_BRIDGE_DIR"), "usage: lua test_core.lua <dir>")

-- =============================================================================== fake UE
local W = {}
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
function Obj:HasAnyInternalFlags(f) return self._garbage == true and (f & 0x200000) ~= 0 end
local function obj(full, t)
    t = t or {}
    t._valid, t._full = true, full
    return setmetatable(t, Obj)
end
local LEVEL = "/Game/Maps/L_World.L_World:PersistentLevel."

local function reset()
    W.by_class, W.calls, W.first = {}, {}, {}
    H.log.events = {}
    U.set_log(H.log)
end
local function add(class, o) W.by_class[class] = W.by_class[class] or {}; table.insert(W.by_class[class], o); return o end
local function call_log(name) W.calls[#W.calls + 1] = name end

function FindAllOf(class) local l = W.by_class[class]; return l and #l > 0 and l or nil end
function FindFirstOf(class) return W.first[class] end
function StaticFindObject() return nil end

local function pawn(name, ctrl_full)
    local p = obj("BP_PlayerCharacter_C " .. LEVEL .. name, { loc = { X = 0, Y = 0, Z = 0 } })
    p.K2_GetActorLocation = function(self) return self.loc end
    p.GetActorForwardVector = function() return { X = 0, Y = 1, Z = 0 } end
    if ctrl_full then
        p.controller = obj(ctrl_full)
        p.controller.UnPossess = function() call_log("UnPossess") end
        p.controller.SetLifeSpan = function() call_log("controller.SetLifeSpan") end
    end
    p.GetController = function(self) return self.controller end
    p.SetLifeSpan = function() call_log("pawn.SetLifeSpan") end
    return add("BP_PlayerCharacter_C", p)
end

-- =============================================================================== tests
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("util.alive: valid and not Garbage; util.find_all filters zombies and CDOs", function()
    reset()
    local a = add("Thing", obj("Thing " .. LEVEL .. "Thing_1"))
    local z = add("Thing", obj("Thing " .. LEVEL .. "Thing_2", { _garbage = true }))
    local d = add("Thing", obj("Thing /Script/X.Default__Thing"))
    local dead = add("Thing", obj("Thing " .. LEVEL .. "Thing_3")); dead._valid = false
    assert(U.alive(a) and not U.alive(z) and not U.alive(dead) and not U.alive(nil))
    assert(U.valid(z), "a zombie still reports IsValid() (that is the trap)")
    assert(#U.find_all("Thing") == 2) -- a, d
    assert(#U.find_all("Thing", { skip_defaults = true }) == 1)
    assert(#U.find_all("Thing", { valid_only = true }) == 3) -- a, z, d
    assert(#U.find_all("Nothing") == 0 and U.find_first("Nothing") == nil)
end)

test("util.split_pawns: players vs puppets, destroyed puppets skipped", function()
    reset()
    local luis = pawn("BP_PlayerCharacter_C_1", "BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_1")
    local puppet = pawn("BP_PlayerCharacter_C_2", "AIController " .. LEVEL .. "AIController_1")
    local zombie = pawn("BP_PlayerCharacter_C_3", "AIController " .. LEVEL .. "AIController_2")
    zombie._garbage = true
    local players, puppets = U.split_pawns()
    assert(#players == 1 and players[1] == luis)
    assert(#puppets == 1 and puppets[1] == puppet)
end)

test("util names, guids, geometry and results", function()
    reset()
    local o = obj("WearableEquipmentData /Game/Eq/Body/ITEM_X.ITEM_X")
    assert(U.path_of(o) == "/Game/Eq/Body/ITEM_X.ITEM_X" and U.class_word(o) == "WearableEquipmentData")
    assert(U.short(o) == "ITEM_X")
    local g = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 1 }
    local hex = U.guid_hex(g)
    assert(hex == "0C0FFEE100C0DE000BADF00D00000001", hex)
    assert(U.guid_eq(U.guid_from_hex(hex), g) and not U.guid_eq(g, { A = 1, B = 2, C = 3, D = 4 }))
    assert(U.guid_from_hex("nope") == nil and U.guid_hex(nil) == nil)
    local dst = { A = 0, B = 0, C = 0, D = 0 }
    U.guid_set(dst, g)
    assert(U.guid_eq(dst, g) and U.guid_eq(U.guid_copy(dst), g))
    local p = pawn("BP_PlayerCharacter_C_9")
    p.loc = { X = 100, Y = 200, Z = 0 }
    local f = U.in_front(p, 300, 50)
    assert(f.X == 100 and f.Y == 500 and f.Z == 50)
    assert(U.in_front({}, 300) == nil)
    local r = U.fail("invalid_args", { detail = "x" })
    assert(r.ok == false and r.reason == "invalid_args" and r.data.detail == "x")
    assert(U.ok().ok == true and U.result(1, nil).ok == false)
    local v, err = U.try_err(function() error("boom") end)
    assert(v == nil and err:find("boom"))
    assert(select("#", U.try(function() error("x") end)) <= 1, "U.try must return at most one value")
end)

test("util.call: breadcrumb is logged BEFORE the native call; errors are logged and returned", function()
    reset()
    local seen_before
    local ok, res = U.call(nil, "Thing.Do", { n = 1 }, function()
        seen_before = H.log.events[#H.log.events]
        return 42
    end)
    assert(ok and res == 42)
    assert(seen_before and seen_before.name == "native" and seen_before.data.call == "Thing.Do")
    ok, res = U.call(nil, "Thing.Fail", {}, function() error("bad arg") end)
    assert(not ok and tostring(res):find("bad arg"))
    local last = H.log.events[#H.log.events]
    assert(last.name == "native_error" and last.data.call == "Thing.Fail")
end)

-- ------------------------------------------------------------------ removal
local function puppet_with_ranged(strip_works)
    local p = pawn("BP_PlayerCharacter_C_5", "AIController " .. LEVEL .. "AIController_5")
    local comp = obj("PlayerRangedAttackComponent " .. LEVEL .. "Ranged")
    comp.K2_DestroyComponent = function(self, owner)
        call_log("strip")
        if strip_works and owner == p then self._garbage = true end
    end
    p.PlayerRangedAttackComponent = comp
    local held = obj("BP_Mace_C " .. LEVEL .. "Mace")
    held.SetLifeSpan = function() call_log("held.SetLifeSpan") end
    p.PlayerEquipmentComponent = { HeldEquipmentActorRight = held }
    return p
end

test("removal.safe_remove: strip ranged -> UnPossess -> SetLifeSpan (pawn, held, controller)", function()
    reset()
    local p = puppet_with_ranged(true)
    local r = removal.safe_remove(p)
    assert(r.ok, json.encode(r))
    assert(table.concat(W.calls, ",") == "strip,UnPossess,held.SetLifeSpan,pawn.SetLifeSpan,controller.SetLifeSpan", table.concat(W.calls, ","))
    -- every native step left a breadcrumb first
    local crumbs = {}
    for _, e in ipairs(H.log.events) do if e.name == "native" then crumbs[#crumbs + 1] = e.data.call end end
    assert(crumbs[1] == "removal.K2_DestroyComponent" and crumbs[2] == "removal.UnPossess")
end)

test("removal.safe_remove: strip failure never unpossesses; real players and zombies are refused/skipped", function()
    reset()
    local p = puppet_with_ranged(false)
    local r = removal.safe_remove(p)
    assert(not r.ok and r.reason == "strip_failed")
    for _, c in ipairs(W.calls) do assert(c ~= "UnPossess" and not c:find("SetLifeSpan"), c) end
    reset()
    local luis = pawn("BP_PlayerCharacter_C_1", "BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_1")
    r = removal.safe_remove(luis)
    assert(not r.ok and r.reason == "is_real_player" and #W.calls == 0)
    local z = pawn("BP_PlayerCharacter_C_7", "AIController " .. LEVEL .. "AIController_7")
    z._garbage = true
    r = removal.safe_remove(z)
    assert(r.ok and r.reason == "already_gone" and #W.calls == 0)
end)

test("removal.remove_all: only puppets", function()
    reset()
    pawn("BP_PlayerCharacter_C_1", "BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_1")
    puppet_with_ranged(true)
    local out = removal.remove_all(H.log, {})
    assert(#out.results == 1 and out.results[1].ok and out.orphan_controllers_destroyed == 0)
end)

-- ------------------------------------------------------------------ speech
local function chat_world()
    reset()
    speech._reset()
    local hooks = {}
    function RegisterHook(fn, pre, post) hooks[#hooks + 1] = { fn = fn, pre = pre, post = post }; return 1, 2 end
    -- One connected player whose PlayerState.OwnerGuid we can watch.
    local owner = { CharacterGuid = { InnerGuid = { A = 0xAD09D558, B = 0x4C934E5D, C = 0x366719BF, D = 0xDD0E1B60 } } }
    local ps = obj("DominionPlayerState " .. LEVEL .. "PS_1", { OwnerGuid = owner, PlayerId = 256 })
    local pc = obj("BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_1", { PlayerState = ps })
    add("BP_PlayerController_C", pc)
    local registered = {}
    local dn = obj("DisplayNameComponent", {
        Server_RegisterCharacter = function(_, og, name)
            registered[#registered + 1] = { guid = U.guid_copy(og.CharacterGuid.InnerGuid), name = name }
        end,
    })
    W.first.DominionGameStateBase = obj("BP_GameState_C " .. LEVEL .. "GS", { DisplayNameComponent = dn })
    -- The chat component: a re-send re-enters every hook, as it does in game.
    local sent = {}
    local chat = {}
    local function param(v) return { get = function() return v end } end
    function chat:Server_SendChatMessage(msg, filter)
        sent[#sent + 1] = { body = msg.MessageBody, guid = U.guid_copy(msg.SenderData.CharacterGuid), filter = filter }
        for _, h in ipairs(hooks) do
            h.post(param(chat), param({ MessageBody = { ToString = function() return msg.MessageBody end }, SenderData = msg.SenderData }), param(filter))
        end
    end
    -- A player typing `text`: build the genuine message and fire the hook like the server does.
    local function player_says(text)
        local msg = { MessageBody = { ToString = function() return text end },
                      SenderData = { CharacterGuid = { A = 1, B = 2, C = 3, D = 4 }, PlayerId = 256 } }
        for _, h in ipairs(hooks) do h.post(param(chat), param(msg), param({ filter = true })) end
    end
    return { hooks = hooks, owner = owner, registered = registered, sent = sent, player_says = player_says,
             ps = ps, pc = pc, chat = chat }
end

test("speech: default mode is log and makes no native call", function()
    local w = chat_world()
    assert(speech.mode() == "log" or os.getenv("DW_SAY_MODE") ~= nil)
    if os.getenv("DW_SAY_MODE") then return end
    local r = speech.say(H.log, "hello")
    assert(r.ok and r.data.method == "log" and #w.hooks == 0 and #w.sent == 0)
    assert(speech.say(H.log, "").reason == "invalid_args")
end)

test("speech relay: say() queues; the next player line carries it as the bot; names registered, GUID restored", function()
    local w = chat_world()
    speech.DEFAULT_MODE = "relay"
    if os.getenv("DW_SAY_MODE") then return end
    local before = U.guid_copy(w.owner.CharacterGuid.InnerGuid)
    local r = speech.say(H.log, "On my way!")
    assert(r.ok and r.data.method == "relay" and r.data.queued and r.data.on_demand == false, json.encode(r))
    assert(#w.hooks == 1 and w.hooks[1].fn == speech.CHAT_FN)
    assert(#w.registered == 1 and w.registered[1].name == speech.NAME and U.guid_eq(w.registered[1].guid, speech.GUID))
    assert(U.guid_eq(w.owner.CharacterGuid.InnerGuid, before), "player's OwnerGuid must be restored")
    assert(#w.sent == 0, "nothing is sent without a triggering line")
    w.player_says("hey")
    assert(#w.sent == 1 and w.sent[1].body == "On my way!" and U.guid_eq(w.sent[1].guid, speech.GUID), json.encode(w.sent))
    assert(w.sent[1].filter and w.sent[1].filter.filter == true, "the genuine filter is reused")
    assert(not speech.is_relaying())
    w.player_says("again")
    assert(#w.sent == 1, "queue is drained once")
    -- second say: names are not registered twice
    speech.say(H.log, "two")
    assert(#w.registered == 1)
    -- a second arm is a no-op
    assert(speech.arm_relay(H.log).already and #w.hooks == 1)
    local st = speech.status()
    assert(st.relay_armed and st.pending == 1 and st.capabilities.on_demand == false)
end)

test("speech relay: !as / !echo triggers, TTL drop, queue cap", function()
    local w = chat_world()
    speech.arm_relay(H.log, { triggers = true })
    w.player_says("!as hello there")
    assert(#w.sent == 1 and w.sent[1].body == "hello there" and U.guid_eq(w.sent[1].guid, speech.GUID))
    w.player_says("!echo hi")
    assert(#w.sent == 2 and w.sent[2].body == "[Claude] hi" and U.guid_eq(w.sent[2].guid, { A = 1, B = 2, C = 3, D = 4 }))
    w.player_says("plain line")
    assert(#w.sent == 2, "no trigger, no queue: nothing relayed")
    -- stale and overflowing queue entries are dropped, never said late
    local s = rawget(_G, "__dw_speech")
    s.queue[#s.queue + 1] = { text = "stale", t = os.time() - speech.QUEUE_TTL_S - 5 }
    s.queue[#s.queue + 1] = { text = "fresh", t = os.time() }
    w.player_says("x")
    assert(#w.sent == 3 and w.sent[3].body == "fresh" and s.dropped == 1)
    speech.DEFAULT_MODE = "relay"
    if os.getenv("DW_SAY_MODE") then return end
    for i = 1, speech.QUEUE_MAX + 2 do speech.say(H.log, "m" .. i) end
    assert(#s.queue == speech.QUEUE_MAX)
end)

test("speech direct: scalar-only call, net ids patched in by the pre-hook from the live PS; unpatched disables; relay fallback", function()
    local w = chat_world()
    speech.DEFAULT_MODE = "direct"
    if os.getenv("DW_SAY_MODE") then return end
    local prim, sec, uid = { id = "eos" }, { id = "steam" }, { id = "uid" }
    w.owner.AccountGuid = { NetIdPrimary = prim, NetIdSecondary = sec }
    w.ps.UniqueID = uid
    w.chat.IsValid = function() return true end
    w.pc.PlayerChat = w.chat
    local function param(v) return { get = function() return v end } end
    local captured, run_pre = {}, true
    local orig = w.chat.Server_SendChatMessage
    function w.chat:Server_SendChatMessage(msg, filter)
        -- what UE4SS receives from Lua: no userdata anywhere in the tables (the nested-userdata crash)
        assert(msg.SenderData.PrimaryNetId == nil and msg.SenderData.SecondaryNetId == nil and filter.SenderId == nil)
        assert(filter.ReceiverIds == nil, "the call's own filter table is empty")
        -- the UE param buffer: a zeroed TArray the pre-hook fills by element assignment
        local items = {}
        filter.ReceiverIds = setmetatable({ GetArrayNum = function() return #items end, items = items },
                                          { __newindex = function(_, k, v) items[k] = v end })
        if run_pre then for _, h in ipairs(w.hooks) do if h.pre then h.pre(param(self), param(msg), param(filter)) end end end
        captured[#captured + 1] = { msg = msg, filter = filter }
        return orig(self, msg, filter)
    end
    local r = speech.say(H.log, "Right behind you.")
    assert(r.ok and r.data.method == "direct" and r.data.on_demand == true, json.encode(r))
    assert(#w.sent == 1 and w.sent[1].body == "Right behind you." and U.guid_eq(w.sent[1].guid, speech.GUID))
    -- the pre-hook assigned the very objects read from the PlayerState (UE4SS engine-copies them)
    local c = captured[1]
    assert(c.msg.SenderData.PrimaryNetId == prim and c.msg.SenderData.SecondaryNetId == sec and c.filter.SenderId == uid)
    assert(c.msg.SenderData.PlayerId == 256)
    assert(#c.filter.ReceiverIds.items == 1 and c.filter.ReceiverIds.items[1] == uid, "receivers = each player's live UniqueID")
    assert(#w.registered == 1, "names registered once")
    assert(not speech.is_relaying())
    assert(#w.hooks == 1 and w.hooks[1].fn == speech.CHAT_FN and speech.status().direct_armed)
    -- the pre-hook is one-shot: a player's own line is never patched
    w.player_says("plain")
    assert(rawget(_G, "__dw_speech").direct_job == nil)
    -- no PlayerChat -> queued for the relay instead of failing
    w.pc.PlayerChat = nil
    local r2 = speech.say(H.log, "queued one")
    assert(r2.ok and r2.data.method == "relay" and r2.data.queued and r2.data.direct_err, json.encode(r2))
    assert(#w.hooks == 2, "relay post-hook armed for the fallback")
    assert(speech.status().capabilities.on_demand == true)
    -- a pre-hook that does not patch disables direct for the run (and that line falls back to relay)
    w.pc.PlayerChat = w.chat
    run_pre = false
    local r3 = speech.say(H.log, "unpatched")
    assert(r3.ok and r3.data.method == "relay" and r3.data.direct_err:find("unpatched"), json.encode(r3))
    assert(speech.status().direct_disabled)
    run_pre = true
    local n = #captured
    local r4 = speech.say(H.log, "after disable")
    assert(r4.data.method == "relay" and #captured == n, "no further direct sends once disabled")
end)

test("speech: bot lines are recognisable (main.lua drops them from command_received)", function()
    chat_world()
    assert(speech.is_bot_guid({ A = speech.GUID.A, B = speech.GUID.B, C = speech.GUID.C, D = speech.GUID.D }))
    assert(not speech.is_bot_guid({ A = 1, B = 2, C = 3, D = 4 }) and not speech.is_bot_guid(nil))
end)

-- ------------------------------------------------------------------ debug_cmds + bridge probe
local function write(path, s) local f = assert(io.open(path, "wb")); f:write(s); f:close() end

test("debug_run: scripts/ first, then experiments/; unknown names are rejected", function()
    reset()
    local sdir, edir = dir .. "/scripts_t", dir .. "/experiments_t"
    os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. '"' .. sdir .. '"')
    os.execute((package.config:sub(1, 1) == "\\" and "mkdir " or "mkdir -p ") .. '"' .. edir .. '"')
    write(sdir .. "/both.lua", "return { run = function() return 'scripts' end }")
    write(edir .. "/both.lua", "return { run = function() return 'experiments' end }")
    write(edir .. "/exp_only.lua", "return { run = function(log, args) return args.x end }")
    local fake = { handlers = {} }
    debug_cmds.register(fake, H.log, { sdir, edir })
    local run = fake.handlers.debug_run
    assert(run({ module = "both" }).data.result == "scripts")
    assert(run({ module = "exp_only", args = { x = 7 } }).data.result == 7)
    local r = run({ module = "missing" })
    assert(not r.ok and r.reason == "invalid_args" and #r.data.tried == 2)
    assert(run({ module = "../x" }).reason == "invalid_args")
    -- the old single-directory signature still works
    debug_cmds.register(fake, H.log, edir)
    assert(fake.handlers.debug_run({ module = "both" }).data.result == "experiments")
end)

-- Every experiment loads through the real lookup (mod/scripts, then mod/experiments) and its
-- default/read-only action runs against an empty world without raising. Crash paths must refuse.
test("experiments: all load by name via debug_run and fail safe in an empty world", function()
    reset()
    speech._reset()
    function RegisterHook() return 1, 2 end
    local fake = { handlers = {} }
    debug_cmds.register(fake, H.log, { here .. "/../scripts", here .. "/../experiments" })
    local run = fake.handlers.debug_run
    local cases = {
        { "puppet_test", {} }, { "puppet_gear", {} }, { "puppet_combat", {} }, { "follower_test", {} },
        { "body_probe", { nav_query = false } }, { "names_probe", {} }, { "perf_probe", {} },
        { "name_register", {} }, { "chat_relay", {} }, { "chat_as", {} }, { "puppet_safe", {} },
        { "companion", {} }, { "say_test", { variant = "a" } }, { "speech_direct", {} },
        { "presence_probe", {} }, { "presence_test", {} },
        { "rules_probe", {} }, { "rules_probe", { action = "sense" } }, { "sleep_probe", {} }, { "sleep_arm", { action = "status" } },
        { "item_probe", {} }, { "item_probe", { action = "gone", target = "x" } },
        { "gather_probe", {} }, { "gather_test", {} },
    }
    for _, c in ipairs(cases) do
        local r = run({ module = c[1], args = c[2] })
        assert(r.ok, c[1] .. ": " .. json.encode(r))
    end
    -- known crash paths refuse without an explicit override
    for _, c in ipairs({ { "puppet_test", { action = "destroy" } }, { "puppet_test", { action = "unpossess" } },
                         { "puppet_combat", { action = "hit" } }, { "say_test", {} },
                         { "speech_direct", { action = "send" } }, { "presence_test", { action = "add" } },
                         { "item_probe", { action = "drop" } }, { "item_probe", { action = "take", target = "x" } } }) do
        local r = run({ module = c[1], args = c[2] })
        assert(r.ok and r.data.result.ok == false and r.data.result.error:find("refused"), c[1] .. " " .. json.encode(r))
    end
end)

-- ------------------------------------------------------------------ presence (map/compass)
test("presence: appends one scalar-only bot entry (bot ident), updates it by Identifier, never twice", function()
    reset()
    local presence = require("body.presence")
    presence._reset()
    local items = { { Identifier = { A = 9, B = 9, C = 9, D = 9 }, Location = { X = 1, Y = 1, Z = 1 }, RotationByte = 0 } }
    local arr = setmetatable({}, { __newindex = function(_, k, v) items[k] = v end })
    rawset(arr, "ForEach", function(_, fn) for i, e in ipairs(items) do fn(i, { get = function() return e end }) end end)
    local reg = obj("GameplayObjectRegistry " .. LEVEL .. "GOR", { PlayerCharacters = arr, ForceNetUpdate = function() end })
    W.first.GameplayObjectSubsystem = obj("GameplayObjectSubsystem /Engine/Transient.GOS", { ObjectRegistry = reg })
    local uid = { live = true }
    local ps = obj("DominionPlayerState " .. LEVEL .. "BotPS", { UniqueID = uid, PlayerColor = { Color = { R = 0, G = 0, B = 0, A = 1 } } })
    local p = pawn("BP_PlayerCharacter_C_bot", LEVEL .. "AIController_1")
    p.PlayerState = ps
    p.loc = { X = 100, Y = 200, Z = 300 }
    p.K2_GetActorRotation = function() return { Yaw = 90 } end
    local r = presence.ensure(H.log, p)
    assert(r.ok and r.data.index == 2 and #items == 2, json.encode(r))
    local e = items[2]
    assert(e.OwningPlayerUniqueID == nil, "never a struct userdata inside the table (UE4SS nested-userdata crash)")
    for k, v in pairs(e) do assert(type(v) ~= "userdata", k) end
    assert(e.OwningPlayerName == presence.NAME and U.guid_eq(e.Identifier, presence.IDENT))
    assert(U.guid_eq(e.OwningCharacterGuid.InnerGuid, presence.CHAR_GUID) and e.RotationByte == 64)
    assert(e.Color.R == presence.COLOR.R, "falls back to Claude orange for an unset PlayerColor")
    assert(presence.ensure(H.log, p).reason == "already" and #items == 2)
    -- a native removal ahead of ours shifts the index: update still finds it by Identifier
    table.remove(items, 1)
    p.loc = { X = 5, Y = 6, Z = 7 }
    assert(presence.update(H.log, p))
    assert(items[1].Location.X == 5 and items[1].Location.Z == 7)
    assert(presence.ensure(H.log, nil).reason == "no_puppet")
end)

test("bridge: a top-level probe flag reaches the handler as args.probe", function()
    reset()
    assert(bridge.init({ dir = dir, log = H.log }))
    local seen
    bridge.handlers.probe_check = function(args) seen = args.probe; return { ok = true, data = {} } end
    write(dir .. "/brain_to_body.jsonl", bridge.encode({ v = 1, type = "cmd", id = "p1", tool = "probe_check", args = bridge.object(), probe = true }) .. "\n")
    bridge.poll()
    assert(seen == true)
    bridge.handlers.probe_check = nil
end)

-- =============================================================================== run
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    print((ok and "PASS " or "FAIL ") .. t[1] .. (ok and "" or ("\n     " .. tostring(err))))
    if not ok then failures = failures + 1 end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
