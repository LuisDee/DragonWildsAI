-- Offline unit tests for the companion body (mod/body/*.lua) against fake UE objects.
-- Usage: lua test_body.lua <empty_dir>   (tests/test_lua_body.py runs it with a pytest tmp dir)
-- Covers handler dispatch through the real bridge, capabilities/probe, player-id resolution,
-- the follow reflex, go_to, the attack loop's termination, equip + persistence, park, say,
-- and the hard rule: the puppet is never unpossessed or destroyed.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local H = dofile(here .. "/bridge_harness.lua")
package.path = here .. "/../?.lua;" .. package.path -- body.* (mod root), as main.lua does in game
local json = require("dkjson")
local bridge = require("bridge")
local puppet = require("body.puppet")
local skills = require("body.skills")
local speech = require("body.speech")
local combat = require("body.combat")
local REAL_ATTACK_DATA = combat.data() -- the generated body/attack_data.lua (checked in its own test)

local dir =assert(arg[1] or os.getenv("DW_BRIDGE_DIR"), "usage: lua test_body.lua <dir>")
local IN, OUT = dir .. "/brain_to_body.jsonl", dir .. "/body_to_brain.jsonl"
local STATE = dir .. "/bot_state.json"

-- =============================================================================== fake UE
local F = {}
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
local function obj(full, t)
    t = t or {}
    t._valid, t._full = true, full
    return setmetatable(t, Obj)
end
local function forbid(name) return function() F.forbidden[#F.forbidden + 1] = name; error("FORBIDDEN " .. name) end end
local function rec(list, v) list[#list + 1] = v end

local LEVEL = "/Game/Maps/L_World.L_World:PersistentLevel."
local PATHS = {
    player_char = "/Game/Gameplay/Character/Player/BP_PlayerCharacter.BP_PlayerCharacter_C",
    held_base = "/Game/Gameplay/Character/Player/Equipment/Held/BP_HeldEquipmentBase.BP_HeldEquipmentBase_C",
    sword_atk = "/Game/Gameplay/Character/Player/Attacks/Sword/BP_Player_Sword_Attack1.BP_Player_Sword_Attack1_C",
    sword_act = "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.Default__PA_Attack_Sword_C",
    sword = "/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril",
    iron_body = "/Game/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_T4_Body_Iron.ITEM_Armour_T4_Body_Iron",
}

local function actor(full, x, y, z, t)
    local a = obj(full, t)
    a.loc = { X = x, Y = y, Z = z }
    a.hp = a.hp or 100
    a.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    a.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
    a.K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
    a.GetWorld = function() return F.world end
    a.GetController = function(self) return self.controller end
    a.ForceNetUpdate = function() end
    a.HealthComponent = obj("PlayerHealthComponent", {
        GetAuthoritativeHealth = function() return a.hp end,
        SetIsImmortal = function(_, v) a.immortal = v end,
        MaxHealth = 100,
    })
    return a
end

local function ai_controller(pawn)
    local c = obj("AIController " .. LEVEL .. "AIController_" .. (#F.controllers + 1), {
        moves = {}, locs = {}, stops = 0, focus = nil,
    })
    c.MoveToActor = function(self, goal, r) rec(self.moves, { goal = goal, r = r }); return F.move_result end
    c.MoveToLocation = function(self, dest, r) rec(self.locs, { dest = dest, r = r }); return F.move_result end
    c.StopMovement = function(self) self.stops = self.stops + 1 end
    c.GetMoveStatus = function() return F.move_status end
    c.K2_SetFocus = function(self, t) self.focus = t end
    c.K2_ClearFocus = function(self) self.focus = nil end
    c.UnPossess = forbid("UnPossess")
    c.K2_DestroyActor = forbid("controller K2_DestroyActor")
    rec(F.controllers, c)
    pawn.controller = c
    return c
end

local function make_puppet(x, y, z)
    local n = #F.spawned + 1
    local p = actor("BP_PlayerCharacter_C " .. LEVEL .. "BP_PlayerCharacter_C_9" .. n, x, y, z, { bHidden = false })
    p.swings = {}
    p.SpawnDefaultController = function(self) ai_controller(self) end
    p.K2_DestroyActor = forbid("puppet K2_DestroyActor")
    p.SetLifeSpan = forbid("puppet SetLifeSpan")
    p.Destroy = forbid("puppet Destroy")
    p.SetActorHiddenInGame = function(self, v) self.bHidden = v end
    p.SetActorEnableCollision = function(self, v) self.collision = v end
    p.K2_TeleportTo = function(self, loc) self.loc = { X = loc.X, Y = loc.Y, Z = loc.Z }; return true end
    p.Mesh = obj("CharacterMesh0")
    p.CharacterMovement = obj("DominionMovementComponent", {
        DisableMovement = function() p.movement = "none" end,
        SetMovementMode = function(_, m) p.movement = m end,
    })
    p.PlayerMeleeAttackComponent = obj("PlayerMeleeAttackComponent", {
        BP_PerformAttack = function(_, atk, inst)
            rec(p.swings, { atk = atk, inst = inst })
            local t = inst.DesiredActionTarget
            if t and F.swing_damage then t.hp = t.hp - F.swing_damage end
        end,
    })
    local eq = obj("BP_Components_PlayerEquipment_C", { HeldRightSocketName = "prop_r", HeldLeftSocketName = "prop_l", reps = {} })
    for _, s in ipairs({ "Head", "Body", "Legs", "Cape" }) do
        eq["OnRep_Current" .. s .. "Wearable"] = function(self) rec(self.reps, s) end
    end
    eq.OnRep_HeldEquipmentActorRight = function(self) rec(self.reps, "Right") end
    eq.OnRep_HeldEquipmentActorLeft = function(self) rec(self.reps, "Left") end
    eq.GetHeldEquipmentActorRight = function(self) return self.HeldEquipmentActorRight end
    p.PlayerEquipmentComponent = eq
    rec(F.spawned, p)
    rec(F.puppets, p)
    return p
end

local function make_held(x, y, z)
    local w = actor("BP_HeldEquipmentBase_C " .. LEVEL .. "BP_HeldEquipmentBase_C_" .. (#F.held + 1), x, y, z)
    w.K2_AttachToComponent = function(self, parent, socket) self.parent, self.socket = parent, socket end
    w.SetLifeSpan = function(self) self.dying = true end
    rec(F.held, w)
    return w
end

local function make_player(name, id, x, y, z)
    local p = actor("BP_PlayerCharacter_C " .. LEVEL .. "BP_PlayerCharacter_C_" .. id, x, y, z)
    p.controller = obj("BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_" .. id)
    p.PlayerState = obj("DominionPlayerState", { PlayerId = id, GetPlayerName = function() return name end })
    local pc = p.controller
    pc.chats, pc.toasts = {}, {}
    pc.PlayerChat = obj("PlayerChatComponent", {
        Client_ReceiveChatMessage = function(_, msg)
            if F.chat_error then error("chat marshalling failed") end
            rec(pc.chats, msg)
        end,
    })
    pc.Client_DisplayTextNotification = function(_, tag, text) rec(pc.toasts, { tag = tag, text = text }) end
    rec(F.players, p)
    return p
end

local function make_ai(kind, n, x, y, z, hp)
    local a = actor("BP_AI_" .. kind .. "_Character_C " .. LEVEL .. "BP_AI_" .. kind .. "_Character_C_" .. n, x, y, z, { hp = hp or 50 })
    a.IsFollower = function() return false end
    a.AiDamageComponent = obj("AiDamageComponent", { PredictDamage = forbid("PredictDamage"), ApplyDamageFromGameplayEffect = forbid("ApplyDamage") })
    rec(F.ais, a)
    return a
end

local function reset_world()
    F.players, F.puppets, F.ais, F.spawned, F.held, F.controllers = {}, {}, {}, {}, {}, {}
    F.forbidden = F.forbidden or {}
    F.move_result, F.move_status, F.swing_damage, F.chat_error = 2, 3, nil, false
    F.world = obj("World /Game/Maps/L_World.L_World", {
        SpawnActor = function(_, cls, loc)
            if cls == F.assets[PATHS.player_char] then return make_puppet(loc.X, loc.Y, loc.Z) end
            return make_held(loc.X, loc.Y, loc.Z)
        end,
        K2_GetWorldSettings = function() return { KillZ = -100000 } end,
    })
    F.assets = {}
    F.assets[PATHS.player_char] = obj("BlueprintGeneratedClass " .. PATHS.player_char)
    F.assets[PATHS.held_base] = obj("BlueprintGeneratedClass " .. PATHS.held_base)
    F.assets[PATHS.sword_atk] = obj("BlueprintGeneratedClass " .. PATHS.sword_atk)
    F.assets[PATHS.sword_act] = obj("PA_Attack_Sword_C " .. PATHS.sword_act)
    F.assets[PATHS.sword] = obj("HeldEquipmentData " .. PATHS.sword)
    F.assets[PATHS.iron_body] = obj("WearableEquipmentData " .. PATHS.iron_body)
end

function FindAllOf(name)
    local out = {}
    local function add(list) for _, o in ipairs(list) do out[#out + 1] = o end end
    if name == "BP_PlayerCharacter_C" then add(F.players); add(F.puppets)
    elseif name == "DominionAICharacter" then add(F.ais)
    elseif name == "BP_PlayerController_C" then for _, p in ipairs(F.players) do out[#out + 1] = p.controller end end
    return #out > 0 and out or nil
end
function FindFirstOf() return nil end
function StaticFindObject(path) return F.assets[path] end
function FName(s) return { name = s } end
function FText(s) return { text = s } end

-- =============================================================================== bridge io
local function write(path, s, mode)
    local f = assert(io.open(path, mode or "ab"))
    f:write(s)
    f:close()
end
local out_offset = 0
local function drain()
    local f = io.open(OUT, "rb")
    if not f then return {} end
    f:seek("set", out_offset)
    local s = f:read("a")
    f:close()
    out_offset = out_offset + #s
    local out = {}
    for line in s:gmatch("([^\n]*)\n") do out[#out + 1] = { raw = line, msg = json.decode(line) } end
    return out
end
local seq = 0
-- Send one cmd through the real bridge; returns the new outbound messages.
local function cmd(tool, args)
    seq = seq + 1
    local id = tool .. "_" .. seq
    write(IN, bridge.encode({ v = 1, type = "cmd", id = id, tool = tool, args = args or bridge.object() }) .. "\n")
    bridge.poll()
    return drain(), id
end
local function result_of(msgs, id)
    for _, m in ipairs(msgs) do if m.msg.type == "result" and m.msg.id == id then return m.msg, m.raw end end
end
local function events_of(msgs, typ)
    local out = {}
    for _, m in ipairs(msgs) do if m.msg.type == "event" and m.msg.event.type == typ then out[#out + 1] = m.msg.event end end
    return out
end
local function ticks(n)
    for _ = 1, n do skills.tick() end
    return drain()
end

-- Fake combo table (same shape as the generated body/attack_data.lua) with round timings, so the
-- tick arithmetic in the tests is exact (TICK_MS = 250).
local ATK = "/Game/Gameplay/Character/Player/Attacks/"
local A = {
    sword_set = combat.DEFAULT_SET,
    sword_special_set = ATK .. "Sword/PA_Attack_Sword_Special.PA_Attack_Sword_Special_C",
    sword_special_cdo = ATK .. "Sword/PA_Attack_Sword_Special.Default__PA_Attack_Sword_Special_C",
    sword2 = ATK .. "Sword/BP_Player_Sword_Attack2.BP_Player_Sword_Attack2_C",
    sword3 = ATK .. "Sword/BP_Player_Sword_Attack3.BP_Player_Sword_Attack3_C",
    sword_sp = ATK .. "Sword/BP_Player_Sword_SpecialAction.BP_Player_Sword_SpecialAction_C",
    club_set = ATK .. "Club/PA_Attack_Club.PA_Attack_Club_C",
    club_cdo = ATK .. "Club/PA_Attack_Club.Default__PA_Attack_Club_C",
    club_special_set = ATK .. "Club/PA_Attack_Club_Special.PA_Attack_Club_Special_C",
    club_special_cdo = ATK .. "Club/PA_Attack_Club_Special.Default__PA_Attack_Club_Special_C",
    club1 = ATK .. "Club/BP_Player_Club_Attack1.BP_Player_Club_Attack1_C",
    club2 = ATK .. "Club/BP_Player_Club_Attack2.BP_Player_Club_Attack2_C",
    club3 = ATK .. "Club/BP_Player_Club_Attack3.BP_Player_Club_Attack3_C",
    club_sp = ATK .. "Club/BP_Player_Club_SpecialAction.BP_Player_Club_SpecialAction_C",
    mace = "/Game/Gameplay/Character/Player/Equipment/Held/Mace/ITEM_Mace_Skullsplitter.ITEM_Mace_Skullsplitter",
    mace_unknown = "/Game/Gameplay/Character/Player/Equipment/Held/Mace/ITEM_Mace_Unlisted.ITEM_Mace_Unlisted",
}
local FAKE_ATTACK_DATA = {
    build = "test",
    sets = {
        [A.sword_set] = { name = "Attack", cdo = PATHS.sword_act, steps = {
            { cls = PATHS.sword_atk, damage = 11, next_ms = 500, reset_ms = 1000 },
            { cls = A.sword2, damage = 11, next_ms = 750, reset_ms = 1250 },
            { cls = A.sword3, damage = 13, next_ms = 1000, reset_ms = 1500 },
        } },
        [A.sword_special_set] = { name = "Barge", cdo = A.sword_special_cdo, steps = {
            { cls = A.sword_sp, damage = 24, next_ms = 1000, reset_ms = 1500, special_cost = 25 } } },
        [A.club_set] = { name = "Attack", cdo = A.club_cdo, steps = {
            { cls = A.club1, damage = 13.5, next_ms = 500, reset_ms = 1000 },
            { cls = A.club2, damage = 13.5, next_ms = 500, reset_ms = 1000 },
            { cls = A.club3, damage = 15, next_ms = 750, reset_ms = 1250 },
        } },
        [A.club_special_set] = { name = "Block Breaker", cdo = A.club_special_cdo, steps = {
            { cls = A.club_sp, damage = 20, next_ms = 1000, reset_ms = 1500, special_cost = 33 } } },
    },
    items = {
        [PATHS.sword] = { id = "ITEM_Sword_Mithril", category = "sword", primary = A.sword_set, special = A.sword_special_set },
        [A.mace] = { id = "ITEM_Mace_Skullsplitter", category = "mace", primary = A.club_set, special = A.club_special_set },
    },
    categories = { sword = A.sword_set, mace = A.club_set },
}
local function fake_attack_assets()
    for _, k in ipairs({ "sword2", "sword3", "sword_sp", "club1", "club2", "club3", "club_sp" }) do
        F.assets[A[k]] = obj("BlueprintGeneratedClass " .. A[k])
    end
    for _, k in ipairs({ "sword_special_cdo", "club_cdo", "club_special_cdo" }) do
        F.assets[A[k]] = obj("PA_C " .. A[k])
    end
end
-- Put a held weapon (its data asset path) in the puppet's right hand, as gear.read sees it.
local function hold(p, item_path)
    p.PlayerEquipmentComponent.HeldEquipmentActorRight = obj("BP_Held_C " .. LEVEL .. "BP_Held_C_1",
        { HeldEquipmentData = obj("HeldEquipmentData " .. item_path) })
end
local function swing_names(p, from)
    local out = {}
    for i = from or 1, #p.swings do
        out[#out + 1] = (p.swings[i].atk._full:match("([%w_]+)$"))
    end
    return table.concat(out, ",")
end

-- Fresh world + fresh module state for each test.
local function setup()
    reset_world()
    fake_attack_assets()
    combat.set_data(FAKE_ATTACK_DATA)
    puppet._reset()
    skills._reset()
    speech._reset()
    os.remove(STATE)
    puppet.init({ log = H.log, state_path = STATE })
    skills.register(bridge, H.log, { puppet = puppet })
    drain()
end
local function spawned()
    local msgs, id = cmd("body_spawn")
    local r = result_of(msgs, id)
    assert(r and r.ok, "body_spawn failed: " .. json.encode(r))
    return F.spawned[#F.spawned], F.controllers[#F.controllers]
end

-- =============================================================================== tests
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("capabilities lists only real handlers", function()
    setup()
    local msgs, id = cmd("capabilities")
    local r = result_of(msgs, id)
    assert(r.ok and type(r.data.tools) == "table")
    local set = {}
    for _, t in ipairs(r.data.tools) do set[t] = true end
    for _, t in ipairs({ "ping", "capabilities", "get_state", "follow", "stop", "go_to", "attack", "say", "equip" }) do
        assert(set[t], "missing " .. t)
    end
    for _, t in ipairs({ "gather", "craft", "place", "give" }) do assert(not set[t], "stub listed: " .. t) end
end)

test("probe answers ok without acting", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local p, c = spawned()
    for _, tool in ipairs({ "follow", "stop", "go_to", "attack", "equip", "say", "get_state", "body_park" }) do
        local msgs, id = cmd(tool, { probe = true })
        local r = result_of(msgs, id)
        assert(r and r.ok and r.data.probe == true and r.data.tool == tool, tool .. ": " .. json.encode(r))
    end
    assert(#c.moves == 0 and #c.locs == 0 and c.stops == 0, "a probe acted")
    assert(skills.current() == nil and #p.swings == 0 and not p.bHidden)
    assert(#p.controller.moves == 0 and #F.held == 0)
end)

test("empty args without probe are invalid_args, never defaults", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    for _, tool in ipairs({ "follow", "go_to", "attack", "equip", "say" }) do
        local msgs, id = cmd(tool)
        local r = result_of(msgs, id)
        assert(r and r.ok == false and r.reason == "invalid_args", tool .. ": " .. json.encode(r))
    end
    assert(#F.spawned == 0, "nothing may spawn on invalid args")
end)

test("get_state without a puppet: companion_down but players and entities listed", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    make_ai("Kebbit", 1, 1000, 0, 0, 30)
    local msgs, id = cmd("get_state")
    local r, raw = result_of(msgs, id)
    assert(r.ok == false and r.reason == "companion_down")
    assert(raw:find('"position":null', 1, true) and raw:find('"following":null', 1, true))
    assert(r.data.players[1].name == "luis_epic" and r.data.players[1].player_id == 256)
    assert(r.data.nearby_entities[1].kind == "kebbit")
end)

test("body_spawn: one puppet, 3 m from the player, AI-possessed and immortal", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local p, c = spawned()
    assert(#F.spawned == 1 and p.loc.X == 300 and p.loc.Z == 50)
    assert(p.controller == c and c._full:find("AIController", 1, true))
    assert(p.immortal == true)
    spawned()
    assert(#F.spawned == 1, "second spawn must reuse the puppet")
    -- lost module state (hot reload): adopt, don't spawn a second one
    puppet._reset()
    puppet.init({ log = H.log, state_path = STATE })
    spawned()
    assert(#F.spawned == 1, "must adopt the existing AI-possessed puppet")
end)

test("get_state with a puppet: verified fields filled, rest listed in not_implemented", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    make_ai("Kebbit", 7, 1300, 0, 50, 30)
    make_ai("Wolf", 8, 999999, 0, 0, 30) -- out of range
    spawned()
    local msgs, id = cmd("get_state")
    local r, raw = result_of(msgs, id)
    assert(r.ok and r.reason == nil, json.encode(r))
    local d = r.data
    assert(d.position[1] == 3 and d.position[3] == 0.5 and d.health == 100 and d.max_health == 100)
    assert(raw:find('"following":null', 1, true) and raw:find('"inventory":{}', 1, true))
    assert(math.abs(d.players[1].distance - 3.04) < 0.001, tostring(d.players[1].distance))
    assert(#d.nearby_entities == 1)
    local e = d.nearby_entities[1]
    assert(e.id == "BP_AI_Kebbit_Character_C_7" and e.kind == "kebbit" and e.hp == 30 and e.alive == true and e.distance == 10)
    assert(raw:find('"hostile":null', 1, true), "hostile unknown without DW_STATE_ATTITUDE")
    local ni = table.concat(d.not_implemented, ",")
    assert(ni == "inventory,nearby_resources,structures,places", ni)
end)

test("player ids: chat PlayerId string, aliases, names, single-player fallback", function()
    setup()
    local U = require("body.util")
    local luis = make_player("luis_epic", 256, 0, 0, 0)
    local bob = make_player("bob", 257, 500, 0, 0)
    assert(U.find_player("256") == luis and U.find_player(257) == bob)
    assert(U.find_player("me") == luis and U.find_player("Luis") == luis and U.find_player(nil) == luis)
    assert(U.find_player("BOB") == bob and U.find_player("zezima") == nil and U.find_player("999") == nil)
    F.players = { luis }
    luis.PlayerState = nil -- unreadable PlayerState: numeric id falls back to the only player
    assert(U.find_player("256") == luis and U.find_player("zezima") == nil and U.find_player("zezima", true) == luis)
end)

test("follow '256': immediate ok, reflex re-issues MoveToActor on cadence, never blocks", function()
    setup()
    local luis = make_player("luis_epic", 256, 2000, 0, 0)
    local p, c = spawned()
    p.loc = { X = 0, Y = 0, Z = 0 }
    local msgs, id = cmd("follow", { player = "256", distance = 3 })
    local r = result_of(msgs, id)
    assert(r.ok and r.data.following == "256" and r.data.distance == 3)
    assert(#c.moves == 1 and c.moves[1].goal == luis and c.moves[1].r == 300, "first MoveToActor right away")
    -- moving: refresh only every FOLLOW_REISSUE_MS (3000 ms = 12 ticks)
    F.move_status = 3
    ticks(11)
    assert(#c.moves == 1, "no re-issue while moving: " .. #c.moves)
    ticks(1)
    assert(#c.moves == 2)
    -- idle and still far: re-issue every FOLLOW_MS (500 ms = 2 ticks)
    F.move_status = 0
    ticks(2)
    assert(#c.moves == 3)
    ticks(1)
    assert(#c.moves == 3, "reflex runs on its 500 ms cadence, not every tick")
    ticks(1)
    assert(#c.moves == 4)
    -- close enough: nothing to do
    p.loc = { X = 1800, Y = 0, Z = 0 }
    ticks(8)
    assert(#c.moves == 4)
    local s = result_of(cmd("get_state"))
    msgs, id = cmd("get_state")
    s = result_of(msgs, id)
    assert(s.data.following == "256" and s.data.action == "follow")
end)

test("follow catch-up teleport after 5 s beyond 50 m", function()
    setup()
    make_player("luis_epic", 256, 10000, 0, 0)
    local p = spawned()
    p.loc = { X = 0, Y = 0, Z = 0 }
    cmd("follow", { player = "me" })
    ticks(20)
    assert(p.loc.X == 9800, "teleported 2 m behind the player, got X=" .. tostring(p.loc.X))
end)

test("stop ends follow silently, stops movement, no more moves", function()
    setup()
    make_player("luis_epic", 256, 2000, 0, 0)
    local p, c = spawned()
    p.loc = { X = 0, Y = 0, Z = 0 }
    cmd("follow", { player = "luis" })
    local msgs, id = cmd("stop")
    local r = result_of(msgs, id)
    assert(r.ok and r.data.stopped == "follow" and c.stops == 1)
    assert(#events_of(msgs, "task_failed") == 0, "follow ended by command: no event")
    local n = #c.moves
    F.move_status = 0
    msgs = ticks(10)
    assert(#c.moves == n and skills.following() == nil)
    msgs, id = cmd("get_state")
    local _, raw = result_of(msgs, id)
    assert(raw:find('"following":null', 1, true))
end)

test("follow: player leaves -> task_failed unknown_target", function()
    setup()
    make_player("luis_epic", 256, 2000, 0, 0)
    spawned()
    local _, id = cmd("follow", { player = "256" })
    F.players = {}
    local msgs = ticks(2)
    local ev = events_of(msgs, "task_failed")
    assert(#ev == 1 and ev[1].task_id == id and ev[1].reason == "unknown_target")
    assert(skills.current() == nil)
end)

test("go_to coords: async reply when game state shows arrival (metres on the wire)", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local p, c = spawned()
    local msgs, id = cmd("go_to", { target = { 10, 5, 0 } })
    assert(result_of(msgs, id) == nil, "go_to must reply asynchronously")
    assert(#c.locs == 1 and c.locs[1].dest.X == 1000 and c.locs[1].dest.Y == 500)
    msgs = ticks(3)
    assert(result_of(msgs, id) == nil, "not there yet")
    p.loc = { X = 950, Y = 480, Z = 120 }
    msgs = ticks(1)
    local r = result_of(msgs, id)
    assert(r and r.ok and r.data.target_position[1] == 10 and r.data.position[1] == 9.5 and r.data.arrive_tolerance > 3)
    local ev = events_of(msgs, "task_done")
    assert(#ev == 1 and ev[1].task_id == id and ev[1].data.target_position)
end)

test("go_to a player by chat id moves to the actor", function()
    setup()
    local luis = make_player("luis_epic", 256, 3000, 0, 0)
    local p, c = spawned()
    p.loc = { X = 0, Y = 0, Z = 0 }
    local msgs, id = cmd("go_to", { target = "256" })
    assert(result_of(msgs, id) == nil and c.moves[1].goal == luis)
    p.loc = { X = 2800, Y = 0, Z = 0 }
    local r = result_of(ticks(1), id)
    assert(r and r.ok)
end)

test("go_to failures: unknown target, request failed, stuck -> path_blocked", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local p, c = spawned()
    local msgs, id = cmd("go_to", { target = "narnia" })
    assert(result_of(msgs, id).reason == "unknown_target")
    F.move_result = 0
    msgs, id = cmd("go_to", { target = { 50, 0, 0 } })
    assert(result_of(msgs, id).reason == "path_blocked" and skills.current() == nil)
    F.move_result = 2
    msgs, id = cmd("go_to", { target = { 50, 0, 0 } })
    local before = #c.locs
    msgs = ticks(80) -- 20 s, never moving
    local r = result_of(msgs, id)
    assert(r and r.reason == "path_blocked" and r.data.reissues == 3, json.encode(r))
    assert(#c.locs == before + 3, "re-issued the move before giving up")
    assert(#events_of(msgs, "task_failed") == 1)
end)

test("go_to interrupted by follow: interrupted result + task_failed, then follow ok", function()
    setup()
    make_player("luis_epic", 256, 2000, 0, 0)
    spawned()
    local _, gid = cmd("go_to", { target = { 100, 0, 0 } })
    local msgs, fid = cmd("follow", { player = "256" })
    local g = result_of(msgs, gid)
    assert(g and g.ok == false and g.reason == "interrupted" and g.data.by == "follow")
    local ev = events_of(msgs, "task_failed")
    assert(#ev == 1 and ev[1].task_id == gid and ev[1].reason == "interrupted")
    assert(result_of(msgs, fid).ok)
end)

test("attack: approach, combo 1-2-3 on the step timings, stop when target hp hits 0", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local wolf = make_ai("Wolf", 3, 2300, 0, 0, 30)
    local p, c = spawned()
    F.swing_damage = 10
    local msgs, id = cmd("attack", { target = "BP_AI_Wolf_Character_C_3" })
    assert(result_of(msgs, id) == nil, "attack replies asynchronously")
    assert(c.focus == wolf)
    msgs = ticks(1)
    assert(#c.moves == 1 and c.moves[1].goal == wolf and #p.swings == 0, "approach first")
    p.loc = { X = 2100, Y = 0, Z = 0 } -- in range (2 m)
    ticks(1)
    assert(#p.swings == 1)
    local sw = p.swings[1]
    assert(sw.atk == F.assets[PATHS.sword_atk] and sw.inst.Data == F.assets[PATHS.sword_act])
    assert(sw.inst.PlayerOwner == p and sw.inst.EquipmentHand == 1 and sw.inst.ActionInputType == 0 and sw.inst.DesiredActionTarget == wolf)
    ticks(1)
    assert(#p.swings == 1, "step 1 next_ms 500: nothing 250 ms later")
    ticks(1)
    assert(#p.swings == 2 and wolf.hp == 10 and p.swings[2].atk == F.assets[A.sword2], "step 2 at +500 ms")
    assert(p.swings[2].inst.Data == F.assets[PATHS.sword_act], "the whole chain uses the primary action's CDO")
    ticks(2)
    assert(#p.swings == 2, "step 2 next_ms 750")
    msgs = ticks(1)
    assert(#p.swings == 3 and wolf.hp == 0 and p.swings[3].atk == F.assets[A.sword3], "step 3 at +750 ms")
    msgs = ticks(1)
    local r = result_of(msgs, id)
    assert(r and r.ok and r.data.killed == true and r.data.swings == 3 and r.data.combos == 1, json.encode(r))
    assert(r.data.attack_set == "PA_Attack_Sword_C" and r.data.specials == 0, json.encode(r))
    local ev = events_of(msgs, "task_done")
    assert(#ev == 1 and ev[1].task_id == id and ev[1].data.killed == true)
    ticks(20)
    assert(#p.swings == 3 and skills.current() == nil and c.focus == nil, "loop ended, focus cleared")
end)

test("attack: by kind, target vanishes -> ok gone; unknown/dead target", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local kebbit = make_ai("Kebbit", 4, 400, 0, 0, 30)
    make_ai("Kebbit", 5, 4000, 0, 0, 0)
    spawned()
    local msgs, id = cmd("attack", { target = "kebbit" }) -- nearest live-or-dead match: id 4
    ticks(1)
    kebbit._valid = false
    msgs = ticks(1)
    local r = result_of(msgs, id)
    assert(r and r.ok and r.data.gone == true and r.data.target == "BP_AI_Kebbit_Character_C_4", json.encode(r))
    msgs, id = cmd("attack", { target = "BP_AI_Kebbit_Character_C_5" })
    assert(result_of(msgs, id).reason == "unknown_target", "dead target")
    msgs, id = cmd("attack", { target = "dragon" })
    assert(result_of(msgs, id).reason == "unknown_target")
end)

test("attack: no damage -> verification_failed; out of reach -> timeout; no PredictDamage ever", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    make_ai("Dummy", 6, 450, 0, 0, 100)
    local p = spawned()
    F.swing_damage = 0
    local _, id = cmd("attack", { target = "dummy" })
    -- unarmed: default Sword set, no special; 10 swings = 3 combos + 1 (~8.3 s), then the check
    local msgs = ticks(40)
    local r = result_of(msgs, id)
    assert(r and r.reason == "verification_failed" and #p.swings == 10, json.encode(r))
    local S1, S2, S3 = "BP_Player_Sword_Attack1_C", "BP_Player_Sword_Attack2_C", "BP_Player_Sword_Attack3_C"
    local want = table.concat({ S1, S2, S3, S1, S2, S3, S1, S2, S3, S1 }, ",")
    assert(swing_names(p) == want, swing_names(p))
    -- unreachable target: keeps approaching until the 55 s timeout
    make_ai("Goat", 7, 3000, 0, 0, 100)
    _, id = cmd("attack", { target = "goat" })
    msgs = ticks(221)
    r = result_of(msgs, id)
    assert(r and r.reason == "timeout", json.encode(r))
end)

local function count(s, pat) return select(2, s:gsub(pat, "")) end

test("combat: combo state machine steps in order, finisher waits reset_ms, a long gap resets the chain", function()
    local st = combat.new_combo({ { next_ms = 500, reset_ms = 1000 }, { next_ms = 700, reset_ms = 1200 },
                                  { next_ms = 900, reset_ms = 2000 } })
    local _, i = combat.combo_peek(st, 0)
    assert(i == 1 and combat.combo_ready(st, 0))
    assert(combat.combo_advance(st, 0) == 500)
    assert(not combat.combo_ready(st, 499) and combat.combo_ready(st, 500))
    _, i = combat.combo_peek(st, 600)
    assert(i == 2, "within step 1's reset window: continue")
    assert(combat.combo_advance(st, 600) == 1300)
    _, i = combat.combo_peek(st, 1799)
    assert(i == 3, "still inside step 2's reset_ms (1200)")
    _, i = combat.combo_peek(st, 1800)
    assert(i == 1 and st.combos == 0, "gap >= reset_ms: chain starts over")
    combat.combo_advance(st, 1800)
    combat.combo_peek(st, 2300); combat.combo_advance(st, 2300)
    _, i = combat.combo_peek(st, 3000)
    assert(i == 3)
    assert(combat.combo_advance(st, 3000) == 5000, "finisher: wait its reset_ms before step 1")
    assert(st.i == 1 and st.combos == 1 and st.count == 5)
    _, i = combat.combo_peek(st, 5000)
    assert(i == 1)
    combat.combo_reset(st)
    assert(st.i == 1 and st.last_at == nil)
end)

test("attack with the Skullsplitter: Club chain (never Sword), special between combos when charged", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local ogre = make_ai("Ogre", 8, 150, 0, 0, 1000)
    local p = spawned()
    hold(p, A.mace)
    local charge = 100
    p.SpecialChargeComponent = obj("SpecialChargeComponent", { GetSpecialCharge = function() return charge end })
    F.swing_damage = 10
    local _, id = cmd("attack", { target = "ogre" })
    ticks(1)
    -- sturdy target (1000 hp >= 3 x 13.5) and full charge: the special opens
    assert(#p.swings == 1 and p.swings[1].atk == F.assets[A.club_sp], swing_names(p))
    assert(p.swings[1].inst.Data == F.assets[A.club_special_cdo] and p.swings[1].inst.DesiredActionTarget == ogre)
    ticks(3)
    assert(#p.swings == 1, "special next_ms 1000")
    ticks(1)
    assert(swing_names(p) == "BP_Player_Club_SpecialAction_C,BP_Player_Club_Attack1_C", swing_names(p))
    assert(p.swings[2].inst.Data == F.assets[A.club_cdo], "combo steps carry the PA_Attack_Club CDO")
    ticks(2)
    assert(swing_names(p, 2) == "BP_Player_Club_Attack1_C,BP_Player_Club_Attack2_C", swing_names(p))
    ticks(2)
    assert(swing_names(p, 2) == "BP_Player_Club_Attack1_C,BP_Player_Club_Attack2_C,BP_Player_Club_Attack3_C",
        swing_names(p))
    for _, sw in ipairs(p.swings) do
        assert(not sw.atk._full:find("Sword", 1, true) and sw.inst.EquipmentHand == 1, "no sword attacks with a mace")
    end
    -- special cooldown 8 s: combos only until then (never mid-combo), then the special again
    ticks(26) -- to +8.25 s after the special
    assert(count(swing_names(p), "SpecialAction") == 1, swing_names(p))
    ticks(10)
    assert(count(swing_names(p), "SpecialAction") == 2, "special again after cooldown: " .. swing_names(p))
    -- the second special came right after a finisher, at chain step 1
    local names = {}
    for n in swing_names(p):gmatch("[^,]+") do names[#names + 1] = n end
    for k = 2, #names do
        if names[k] == "BP_Player_Club_SpecialAction_C" then
            assert(names[k - 1] == "BP_Player_Club_Attack3_C", "special only between combos: " .. swing_names(p))
        end
    end
    -- low charge: no more specials
    charge = 10
    local before = #p.swings
    ticks(60)
    assert(#p.swings > before and count(swing_names(p, before + 1), "SpecialAction") == 0, swing_names(p, before + 1))
    skills._finish(skills.current(), false, "interrupted", {})
    -- an unlisted mace falls back to its category's set; unarmed to the Sword set
    local prof = combat.profile_for(A.mace_unknown)
    assert(prof.primary_key == A.club_set and prof.source == "category")
    assert(combat.profile_for(nil).primary_key == A.sword_set and combat.profile_for(nil).special == nil)
    assert(id)
end)

test("attack: chain continues after a short chase, restarts at step 1 after a long one", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local boar = make_ai("Boar", 9, 150, 0, 0, 1000)
    local p, c = spawned()
    F.swing_damage = 1
    cmd("attack", { target = "boar" })
    ticks(1)
    assert(swing_names(p) == "BP_Player_Sword_Attack1_C")
    boar.loc = { X = 900, Y = 0, Z = 0 } -- out of range for 250 ms (< step 1 reset_ms 1000)
    ticks(1)
    assert(#c.moves >= 1 and #p.swings == 1, "chase")
    boar.loc = { X = 150, Y = 0, Z = 0 }
    ticks(1)
    assert(swing_names(p) == "BP_Player_Sword_Attack1_C,BP_Player_Sword_Attack2_C", swing_names(p))
    boar.loc = { X = 900, Y = 0, Z = 0 } -- out of range for 1.5 s (> step 2 reset_ms 1250)
    ticks(6)
    boar.loc = { X = 150, Y = 0, Z = 0 }
    ticks(1)
    assert(swing_names(p, 3) == "BP_Player_Sword_Attack1_C", "long gap: chain restarted: " .. swing_names(p))
end)

test("combat hooks: on_tick and evade take the tick, before_swing can skip, a failing hook is ignored", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    make_ai("Boar", 10, 150, 0, 0, 1000)
    local p = spawned()
    F.swing_damage = 1
    local seen
    local remove = combat.add_hook("on_tick", "test_spell", function(ctx) seen = ctx; return true end)
    cmd("attack", { target = "boar" })
    ticks(4)
    assert(#p.swings == 0 and seen and seen.t and seen.p == p and type(seen.perform) == "function", "on_tick took every tick")
    remove()
    combat.add_hook("evade", "test_evade", function(ctx) return ctx.threat ~= nil end)
    combat.notify_threat({ by = "boar", ms_until = 400 }, skills.now())
    ticks(2)
    assert(#p.swings == 0, "evading while a telegraph is recorded")
    combat.threat = nil
    combat.add_hook("before_swing", "veto", function() return "skip" end)
    ticks(2)
    assert(#p.swings == 0, "before_swing skip")
    combat.add_hook("before_swing", "veto", function() error("hook bug") end) -- same name: replaces
    local seen_after
    combat.add_hook("after_swing", "count", function(_, sw, ok) seen_after = { sw = sw, ok = ok } end)
    ticks(1)
    assert(#p.swings == 1 and seen_after and seen_after.ok == true and seen_after.sw.step == 1,
        "a hook error never blocks the swing")
    assert(not pcall(combat.add_hook, "bogus", "x", function() end), "unknown hook kinds are rejected")
end)

test("generated attack_data.lua: Skullsplitter -> Club 5-step chain with timing, sword -> Sword set", function()
    local d = assert(REAL_ATTACK_DATA, "body/attack_data.lua missing: run tools/gen_attack_data.py")
    local skull = d.items[A.mace]
    assert(skull and skull.primary == A.club_set and skull.special == A.club_special_set)
    local set = d.sets[A.club_set]
    assert(set.cdo == A.club_cdo and #set.steps == 5 and set.steps[1].cls == A.club1, #set.steps)
    for i, st in ipairs(set.steps) do
        assert(st.timed and st.next_ms > 0 and st.reset_ms > st.next_ms, "step " .. i)
        assert(st.cls:find("BP_Player_Club_Attack" .. i, 1, true), st.cls)
    end
    assert(#set.short == 4 and set.short[4].cls:find("ShortComboEnd", 1, true))
    assert(d.sets[A.club_special_set].steps[1].special_cost == 33)
    assert(d.items[PATHS.sword].primary == combat.DEFAULT_SET and d.categories.mace == A.club_set)
    combat.set_data(d)
    local prof = combat.profile_for(A.mace)
    assert(prof.source == "item" and #prof.steps == 5 and prof.special_key == A.club_special_set)
    combat.CHAIN = "short"
    assert(#combat.profile_for(A.mace).steps == 4)
    combat.CHAIN = "full"
    combat.set_data(FAKE_ATTACK_DATA)
end)

test("equip: right-hand weapon and inferred body slot, verified by read-back and persisted", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    local p = spawned()
    local msgs, id = cmd("equip", { item_path = PATHS.sword })
    local r = result_of(msgs, id)
    assert(r and r.ok and r.data.slot == "right" and r.data.persisted == true, json.encode(r))
    local w = F.held[1]
    assert(w.HeldEquipmentData == F.assets[PATHS.sword] and w.parent == p.Mesh and w.socket == "prop_r")
    assert(p.PlayerEquipmentComponent.HeldEquipmentActorRight == w and r.data.gear.right == PATHS.sword)
    msgs, id = cmd("equip", { item_path = PATHS.iron_body })
    r = result_of(msgs, id)
    assert(r.ok and r.data.slot == "body" and p.PlayerEquipmentComponent.CurrentBodyWearable == F.assets[PATHS.iron_body])
    -- swapping the weapon clears the old held actor
    cmd("equip", { item_path = PATHS.sword, hand = "right" })
    assert(F.held[1].dying and p.PlayerEquipmentComponent.HeldEquipmentActorRight == F.held[2])
    msgs, id = cmd("equip", { item_path = "/Game/Nope.Nope" })
    assert(result_of(msgs, id).reason == "unknown_target")
    local f = assert(io.open(STATE, "rb"))
    local saved = json.decode(f:read("a"))
    f:close()
    assert(saved.gear.right == PATHS.sword and saved.gear.body == PATHS.iron_body)
end)

test("persisted gear is re-applied when the puppet is spawned in a new run", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    spawned()
    cmd("equip", { item_path = PATHS.sword })
    cmd("equip", { item_path = PATHS.iron_body })
    -- new server run: same state file, no puppet in the world
    local luis = F.players[1]
    reset_world()
    F.players = { luis }
    puppet._reset()
    puppet.init({ log = H.log, state_path = STATE })
    local p = spawned()
    assert(#F.spawned == 1)
    assert(p.PlayerEquipmentComponent.CurrentBodyWearable == F.assets[PATHS.iron_body])
    local w = p.PlayerEquipmentComponent.HeldEquipmentActorRight
    assert(w and w.HeldEquipmentData == F.assets[PATHS.sword])
end)

test("park hides + parks under the player without unpossess/destroy; body_spawn unparks", function()
    setup()
    make_player("luis_epic", 256, 100, 200, 300)
    local p, c = spawned()
    cmd("follow", { player = "256" })
    local msgs, id = cmd("body_park")
    local r = result_of(msgs, id)
    assert(r.ok and r.data.parked == true and skills.current() == nil)
    assert(p.bHidden == true and p.collision == false and p.movement == "none" and c.stops >= 1)
    assert(p.loc.X == 100 and p.loc.Y == 200 and p.loc.Z == 300 - 1000, "parked 10 m under the player")
    assert(p.controller == c, "still possessed")
    msgs, id = cmd("body_spawn")
    assert(result_of(msgs, id).ok and p.bHidden == false and p.collision == true and p.movement == 1)
    assert(p.loc.X == 400 and #F.spawned == 1)
    -- follow on a parked puppet unparks it too
    cmd("body_park")
    cmd("follow", { player = "256" })
    assert(p.bHidden == false)
end)

test("lifecycle loop: spawn after two checks, auto-park when everyone leaves, auto-unpark", function()
    setup()
    local luis = make_player("luis_epic", 256, 0, 0, 0)
    puppet.tick()
    assert(#F.spawned == 0, "waits one check after the player appears")
    puppet.tick()
    assert(#F.spawned == 1)
    local p = F.spawned[1]
    F.players = {}
    puppet.tick()
    assert(p.bHidden == true and puppet.is_parked())
    F.players = { luis }
    puppet.tick()
    assert(p.bHidden == false and not puppet.is_parked() and #F.spawned == 1)
    -- a command park is not undone by the loop
    puppet.park("cmd")
    puppet.tick()
    assert(p.bHidden == true)
end)

test("say: chat RPC to every player, toast fallback on a Lua error", function()
    setup()
    speech.DEFAULT_MODE = "chat" -- the legacy Client_* mode, offline only (the real default is log)
    local a = make_player("luis_epic", 256, 0, 0, 0)
    local b = make_player("bob", 257, 0, 0, 0)
    local msgs, id = cmd("say", { text = "On my way!" })
    local r = result_of(msgs, id)
    assert(r.ok and r.data.method == "chat" and r.data.recipients == 2 and r.data.verified == false)
    local m = a.controller.chats[1]
    assert(m.MessageBody == "On my way!" and m.SenderData.PlayerId == 9001 and m.SenderData.CharacterGuid.A == 0x0C0FFEE1)
    assert(#b.controller.chats == 1)
    F.chat_error = true
    msgs, id = cmd("say", { text = string.rep("x", 300) })
    r = result_of(msgs, id)
    assert(r.ok and r.data.method == "notify" and #r.data.text == 256)
    assert(a.controller.toasts[1].text.text == string.rep("x", 256))
end)

test("a crashing step becomes body_error and the loop carries on", function()
    setup()
    make_player("luis_epic", 256, 0, 0, 0)
    spawned()
    local _, id = cmd("go_to", { target = { 50, 0, 0 } })
    skills.current().step = function() error("boom") end
    local msgs = ticks(1)
    local r = result_of(msgs, id)
    assert(r and r.reason == "body_error" and r.data.detail:find("boom"))
    msgs, id = cmd("stop")
    assert(result_of(msgs, id).ok)
end)

test("hard rule: nothing ever unpossessed, destroyed or direct-damaged", function()
    assert(#F.forbidden == 0, "forbidden calls: " .. table.concat(F.forbidden, ", "))
end)

-- =============================================================================== run
assert(bridge.init({ dir = dir, log = H.log }))
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    print((ok and "PASS " or "FAIL ") .. t[1] .. (ok and "" or ("\n     " .. tostring(err))))
    if not ok then failures = failures + 1 end
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
