-- Offline unit tests for the bot inventory and item skills: body/inventory.lua (store, stacking,
-- persistence in the puppet's bot state file, gear migration), the equip gate in body/gear.lua,
-- body/items.lua (world items) and body/item_skills.lua (pickup / drop / give handlers through the
-- real bridge and the real skills tick loop), against fake UE objects.
-- Usage: lua test_inventory.lua <empty_dir>   (tests/test_lua_inventory.py runs it with a tmp dir)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local H = dofile(here .. "/bridge_harness.lua")
package.path = here .. "/../?.lua;" .. package.path
local json = require("dkjson")
local bridge = require("bridge")
local puppet = require("body.puppet")
local skills = require("body.skills")
local inventory = require("body.inventory")
local items = require("body.items")
local item_skills = require("body.item_skills")
local gear = require("body.gear")

local dir = assert(arg[1] or os.getenv("DW_BRIDGE_DIR"), "usage: lua test_inventory.lua <dir>")
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
local function rec(list, v) list[#list + 1] = v end
local function forbid(name) return function() rec(F.forbidden, name); error("FORBIDDEN " .. name) end end
local function text(s) return { ToString = function() return s end } end

local LEVEL = "/Game/Maps/L_World.L_World:PersistentLevel."
local OAK = "/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak"
local ASH = "/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Ash.ITEM_Resources_Wood_Ash"
local AIR = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Air.ITEM_Rune_Air"
local SWORD = "/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/ITEM_Sword_Mithril.ITEM_Sword_Mithril"
local SWORD_CLASS = "/DowdunReach/Gameplay/Character/Player/Equipment/Held/Sword/BP_Sword_Mithril.BP_Sword_Mithril_C"
local BODY = "/Game/Gameplay/Character/Player/Equipment/Body/ITEM_Armour_T4_Body_Iron.ITEM_Armour_T4_Body_Iron"
local NULL = setmetatable({ _null = true }, { __index = function() return nil end })
function CreateInvalidObject() return NULL end

local function actor(full, x, y, z, t)
    local a = obj(full, t)
    a.loc = { X = x, Y = y, Z = z }
    a.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    a.GetActorForwardVector = function() return { X = 1, Y = 0, Z = 0 } end
    a.GetWorld = function() return F.world end
    a.GetController = function(self) return self.controller end
    a.ForceNetUpdate = function() end
    return a
end

local function make_data(path, max_stack, name)
    local d = obj("ItemData " .. path, { MaxStackSize = max_stack, Name = text(name or path:match("([%w_]+)$")) })
    F.assets[path] = d
    return d
end

local n_items = 0
local function world_item(path, count, x, y, z, opts)
    opts = opts or {}
    n_items = n_items + 1
    local data = F.assets[path] or make_data(path, 99)
    local id = (opts.cls or "BP_RuntimeSpawnedWorldItem_C") .. "_" .. (2147400000 + n_items)
    local uitem = obj("Item " .. LEVEL .. id .. ".Item_1", {
        Count = count, Durability = opts.durability or -1, NumMasterworkUpgradesApplied = opts.level or 0,
        Guid = { A = 1, B = 2, C = 3, D = n_items }, GetMaxDurability = function() return opts.max_durability or -1 end,
    })
    local w = actor((opts.cls or "BP_RuntimeSpawnedWorldItem_C") .. " " .. LEVEL .. id, x, y, z, {
        ItemData = data, sticky = opts.sticky,
        MagneticComponentGrantItem = obj("MagneticComponent_GrantItem " .. LEVEL .. id .. ".Mag", {
            SpawnedItem = uitem, bHasBeenGranted = false, Target = opts.target,
        }),
    })
    w.GetStackSize = function(self) return self.MagneticComponentGrantItem.SpawnedItem.Count end
    w.IsBeingManipulated = function() return false end
    w.SetActorHiddenInGame = function(self, v) self.hidden = v end
    w.SetActorEnableCollision = function(self, v) self.collision = v end
    w.SetLifeSpan = function(self, s) self.life = s; if not self.sticky then self._valid = false end end
    w.GetLifeSpan = function(self) return self.life or 0 end
    w.K2_DestroyActor = forbid("world item K2_DestroyActor (must use SetLifeSpan)")
    rec(F.world_items, w)
    return w
end

local function make_player(name, id, x, y, z)
    local p = actor("BP_PlayerCharacter_C " .. LEVEL .. "BP_PlayerCharacter_C_" .. id, x, y, z)
    p.controller = obj("BP_PlayerController_C " .. LEVEL .. "BP_PlayerController_C_" .. id)
    p.PlayerState = obj("DominionPlayerState", { PlayerId = id, GetPlayerName = function() return name end })
    rec(F.players, p)
    return p
end

local function make_puppet(x, y, z)
    local p = actor("BP_PlayerCharacter_C " .. LEVEL .. "BP_PlayerCharacter_C_91", x, y, z)
    local c = obj("AIController " .. LEVEL .. "AIController_1", { moves = {}, locs = {}, stops = 0 })
    c.MoveToActor = function(self, goal, r) rec(self.moves, { goal = goal, r = r }); return F.move_result end
    c.MoveToLocation = function(self, dest, r) rec(self.locs, { dest = dest, r = r }); return F.move_result end
    c.StopMovement = function(self) self.stops = self.stops + 1 end
    c.GetMoveStatus = function() return 3 end
    c.UnPossess = forbid("UnPossess")
    p.controller = c
    p.K2_DestroyActor = forbid("puppet K2_DestroyActor")
    p.SetLifeSpan = forbid("puppet SetLifeSpan")
    p.Mesh = obj("CharacterMesh0")
    local eq = obj("BP_Components_PlayerEquipment_C", { HeldRightSocketName = "prop_r", HeldLeftSocketName = "prop_l" })
    for _, s in ipairs({ "Head", "Body", "Legs", "Cape" }) do eq["OnRep_Current" .. s .. "Wearable"] = function() end end
    eq.OnRep_HeldEquipmentActorRight = function() end
    eq.OnRep_HeldEquipmentActorLeft = function() end
    p.PlayerEquipmentComponent = eq
    p.HealthComponent = obj("PlayerHealthComponent", { GetAuthoritativeHealth = function() return 100 end, MaxHealth = 100 })
    F.puppet = p
    return p, c
end

local function reset_world()
    F.players, F.world_items, F.held, F.puppet, F.forbidden = {}, {}, {}, nil, F.forbidden or {}
    F.assets, F.spawn_calls, F.spawn_error, F.spawn_bad_stack, F.move_result = {}, {}, false, false, 2
    make_data(OAK, 99, "Oak Logs")
    make_data(ASH, 99, "Ash Logs")
    make_data(AIR, 999, "Air Rune")
    F.assets[SWORD_CLASS] = obj("BlueprintGeneratedClass " .. SWORD_CLASS)
    F.assets[SWORD] = obj("HeldEquipmentData " .. SWORD, { HeldEquipmentActorClass = SWORD_CLASS, MaxStackSize = 1 })
    F.assets[BODY] = obj("WearableEquipmentData " .. BODY, { MaxStackSize = 1 })
    F.assets[items.PATHS.noexpiry] = obj("BlueprintGeneratedClass " .. items.PATHS.noexpiry)
    F.assets[items.PATHS.helper] = obj("ItemHelperLibrary " .. items.PATHS.helper, {
        SpawnAndLaunchItem_Sync = function(_, world, params, out)
            rec(F.spawn_calls, { world = world, params = params, out = out })
            if F.spawn_error then error("struct marshalling failed") end
            local t = params.Transform.Translation
            local data = params.SpawnedItemData
            local count = F.spawn_bad_stack and params.Count - 1 or params.Count
            return world_item(data._full:match("^%S+%s+(.*)$"), count, t.X, t.Y, t.Z - items.SPAWN_RAISE_CM, { cls = "BP_RuntimeSpawnedWorldItem_NoExpiry_C" })
        end,
    })
    F.world = obj("World /Game/Maps/L_World.L_World", {
        SpawnActor = function(_, cls, loc)
            local w = actor("BP_Held_C " .. LEVEL .. "BP_Held_C_" .. (#F.held + 1), loc.X, loc.Y, loc.Z)
            w.K2_AttachToComponent = function(self, parent, socket) self.parent, self.socket = parent, socket end
            w.SetLifeSpan = function(self) self.dying = true end
            rec(F.held, w)
            return w
        end,
    })
end

function FindAllOf(name)
    local out = {}
    if name == "BP_PlayerCharacter_C" then
        for _, p in ipairs(F.players) do out[#out + 1] = p end
        if F.puppet then out[#out + 1] = F.puppet end
    elseif name == "RuntimeSpawnedWorldItem" then
        for _, w in ipairs(F.world_items) do out[#out + 1] = w end
    elseif name == "BP_PlayerController_C" then
        for _, p in ipairs(F.players) do out[#out + 1] = p.controller end
    end
    return #out > 0 and out or nil
end
function FindFirstOf() return nil end
function StaticFindObject(path) return F.assets[path] end

-- The skills/item_skills puppet dependency: the fake puppet above (the real body/puppet.lua is
-- used only for persistence below).
local fake_puppet = {
    get = function() return F.puppet end,
    controller = function() return F.puppet and F.puppet.controller end,
    ensure_ready = function() if F.puppet then return F.puppet, F.puppet.controller end; return nil, "no puppet" end,
    ensure_spawned = function() return F.puppet end,
    status = function() return { spawned = F.puppet ~= nil } end,
    teleport_near = function() return true end,
    remember_gear = function() return true end,
}

-- =============================================================================== bridge io
local function write(path, s) local f = assert(io.open(path, "ab")); f:write(s); f:close() end
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
    local all = {}
    for _ = 1, n do
        skills.tick()
        for _, m in ipairs(drain()) do all[#all + 1] = m end
    end
    return all
end
local function read_state()
    local f = io.open(STATE, "rb")
    if not f then return nil end
    local v = json.decode(f:read("a"))
    f:close()
    return v
end

local function setup(opts)
    opts = opts or {}
    reset_world()
    inventory._reset()
    skills._reset()
    puppet._reset()
    os.remove(STATE)
    if opts.state then write(STATE, json.encode(opts.state)) end
    puppet.init({ log = H.log, state_path = STATE })
    inventory.init({ log = H.log, puppet = puppet })
    skills.register(bridge, H.log, { puppet = fake_puppet, no_loop = true })
    item_skills.register(bridge, H.log, { skills = skills, puppet = fake_puppet })
    drain()
end

-- =============================================================================== tests
local tests, failures = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

test("store: stacks merge up to the live MaxStackSize, overflow opens new stacks", function()
    setup()
    inventory.add({ item_data_path = OAK, count = 60 })
    inventory.add({ item_data_path = OAK, count = 60 })
    local l = inventory.list()
    eq(#l, 2); eq(l[1].count, 99); eq(l[2].count, 21); eq(l[1].max_stack, 99)
    eq(inventory.count("ITEM_Resources_Wood_Oak"), 120); eq(inventory.count(OAK), 120)
    eq(inventory.summary().ITEM_Resources_Wood_Oak, 120)
    -- different instance state (a level) never merges; an unknown item with a level is not stackable
    inventory.add({ item_data_path = SWORD, count = 1, level = 6 })
    inventory.add({ item_data_path = SWORD, count = 1 })
    eq(inventory.count(SWORD), 2); eq(#inventory.list(), 4)
    -- 4 stacks of 99 oak = 396 (the Phase 8 target), counted from the store
    inventory.add({ item_data_path = OAK, count = 396 - 120 })
    eq(inventory.count(OAK), 396)
    local full = 0
    for _, it in ipairs(inventory.list()) do if it.item_data_path == OAK and it.count == 99 then full = full + 1 end end
    eq(full, 4)
end)

test("store: take is all-or-nothing, partial stacks first; put_back refunds; runes for spells", function()
    setup()
    inventory.add({ item_data_path = OAK, count = 99 })
    inventory.add({ item_data_path = OAK, count = 30 }) -- -> 99 + 30
    local ok, why = inventory.take(OAK, 200)
    eq(ok, false); eq(why, "not_enough_resources"); eq(inventory.count(OAK), 129)
    local portions
    ok, portions = inventory.take("ITEM_Resources_Wood_Oak", 40)
    eq(ok, true); eq(inventory.count(OAK), 89)
    eq(#portions, 2); eq(portions[1].count, 30, "the partial stack goes first"); eq(portions[2].count, 10)
    inventory.put_back(portions)
    eq(inventory.count(OAK), 129)
    -- the spells budget API: plain functions with an item id
    inventory.add({ item_data_path = AIR, count = 20 })
    local count, take = inventory.count, inventory.take
    eq(count("ITEM_Rune_Air"), 20)
    eq(take("ITEM_Rune_Air", 15), true); eq(count("ITEM_Rune_Air"), 5)
    eq(take("ITEM_Rune_Air", 15), false); eq(count("ITEM_Rune_Air"), 5)
    eq(take("ITEM_Rune_Air", 0), false)
end)

test("store: resolve loose names to one owned item; ambiguous and unknown", function()
    setup()
    inventory.add({ item_data_path = OAK, count = 3, name = "Oak Logs" })
    inventory.add({ item_data_path = ASH, count = 2, name = "Ash Logs" })
    eq(inventory.resolve("oak"), "ITEM_Resources_Wood_Oak")
    eq(inventory.resolve("Oak Logs"), "ITEM_Resources_Wood_Oak")
    eq(inventory.resolve(ASH), "ITEM_Resources_Wood_Ash")
    local id, why, cands = inventory.resolve("logs")
    eq(id, nil); eq(why, "ambiguous"); eq(#cands, 2)
    id, why = inventory.resolve("stone")
    eq(id, nil); eq(why, "unknown")
end)

test("persistence: inventory is a section of the puppet's bot state file; gear and others survive", function()
    setup({ state = { v = 1, gear = { right = SWORD }, reflex_rules = { x = 1 } } })
    inventory.add({ item_data_path = OAK, count = 42, name = "Oak Logs" })
    local s = read_state()
    eq(s.gear.right, SWORD, "gear kept"); eq(s.reflex_rules.x, 1, "another service's section kept")
    eq(s.inventory.v, 1)
    -- a new run: same file, fresh modules
    inventory._reset(); puppet._reset()
    puppet.init({ log = H.log, state_path = STATE })
    inventory.init({ log = H.log, puppet = puppet })
    eq(inventory.count(OAK), 42)
    eq(inventory.equipped_in("right").item_data_path, SWORD, "seeded once, still equipped")
    -- ids keep increasing across runs
    local r = inventory.add({ item_data_path = ASH, count = 1 })
    for _, it in ipairs(inventory.list(true)) do if it.id == r.ids[1] then eq(it.item, "ITEM_Resources_Wood_Ash") end end
    local seen = {}
    for _, it in ipairs(inventory.list(true)) do assert(not seen[it.id], "duplicate id " .. it.id); seen[it.id] = true end
    -- puppet.set_section refuses the reserved keys
    assert(not pcall(puppet.set_section, "gear", {}))
end)

test("persistence: a corrupt state file is kept aside, not silently overwritten", function()
    setup()
    inventory.add({ item_data_path = OAK, count = 5 })
    write(STATE, "{not json") -- append garbage: the file no longer decodes
    inventory._reset(); puppet._reset()
    puppet.init({ log = H.log, state_path = STATE })
    local kept = false
    for _, e in ipairs(H.log.events) do if e.name == "bot_state_corrupt" and e.data.kept_as then kept = e.data.kept_as end end
    assert(kept, "corrupt file not kept")
    local f = assert(io.open(kept, "rb")); f:close()
    os.remove(kept)
end)

test("migration: persisted gear becomes owned, equipped instances exactly once", function()
    setup({ state = { v = 1, gear = { right = SWORD, body = BODY } } })
    eq(inventory.equipped_in("right").item_data_path, SWORD)
    eq(inventory.equipped_in("body").item_data_path, BODY)
    eq(inventory.count(SWORD), 0, "equipped is not in the bag")
    eq(next(inventory.summary()), nil)
    eq(#inventory.list(true), 2)
    -- re-init must not seed again
    inventory.init({ log = H.log, puppet = puppet })
    eq(#inventory.list(true), 2)
end)

test("equip gate: unowned -> not_in_inventory (no native call); owned -> equipped; debug flag", function()
    setup()
    local p = make_puppet(0, 0, 0)
    local r = gear.equip(H.log, p, SWORD, {})
    eq(r.ok, false); eq(r.reason, "not_in_inventory"); eq(#F.held, 0, "nothing spawned for an unowned item")
    -- the bridge handler: same refusal, and the debug override works
    local msgs, id = cmd("equip", { item_path = SWORD })
    eq(result_of(msgs, id).reason, "not_in_inventory")
    msgs, id = cmd("equip", { item_path = SWORD, debug_unowned = true })
    local res = result_of(msgs, id)
    assert(res.ok and res.data.debug_unowned == true, json.encode(res))
    -- owned: equips and marks the instance; a second copy stays in the bag
    inventory.add({ item_data_path = SWORD, count = 1 })
    inventory.add({ item_data_path = SWORD, count = 1 })
    r = gear.equip(H.log, p, SWORD, {})
    assert(r.ok and r.data.instance, json.encode(r))
    eq(inventory.equipped_in("right").id, r.data.instance)
    eq(inventory.count(SWORD), 1)
    -- wearables too; re-equipping the same worn item in its slot is allowed (respawn re-apply)
    inventory.add({ item_data_path = BODY, count = 1 })
    eq(gear.equip(H.log, p, BODY, {}).ok, true)
    eq(gear.equip(H.log, p, BODY, { hand = "body" }).ok, true)
    eq(inventory.equipped_in("body").item_data_path, BODY)
end)

test("equip gate: the migrated gear re-applies on spawn through the real puppet", function()
    setup({ state = { v = 1, gear = { right = SWORD, body = BODY } } })
    local p = make_puppet(0, 0, 0)
    -- puppet.apply_saved_gear uses gear.equip, which now needs ownership: the migration grants it
    local orig_get = puppet.get
    puppet.get = function() return p end
    local out = puppet.apply_saved_gear()
    puppet.get = orig_get
    eq(out.right, true); eq(out.body, true)
    eq(p.PlayerEquipmentComponent.CurrentBodyWearable, F.assets[BODY])
end)

test("pickup nearest + filter: walk, take (hide, no collision, SetLifeSpan), verify gone + store", function()
    setup()
    make_puppet(0, 0, 0)
    world_item(ASH, 1, 500, 0, 0)
    local oak = world_item(OAK, 6, 1000, 0, 0)
    local msgs, id = cmd("pickup", { target = "nearest", item = "oak" })
    eq(result_of(msgs, id), nil, "async")
    msgs = ticks(1)
    local c = F.puppet.controller
    assert(#c.locs >= 1 and c.locs[#c.locs].dest.X == 1000, "walks to the oak, not the nearer ash")
    eq(oak.hidden, nil, "not taken from afar")
    F.puppet.loc = { X = 900, Y = 0, Z = 0 }
    msgs = ticks(1)
    eq(oak.hidden, true); eq(oak.collision, false); eq(oak.life, items.REMOVE_LIFESPAN_S)
    eq(inventory.count(OAK), 6, "added in the same tick")
    msgs = ticks(1)
    local r = result_of(msgs, id)
    assert(r and r.ok, json.encode(r))
    eq(r.data.item, "ITEM_Resources_Wood_Oak"); eq(r.data.count, 6); eq(r.data.inventory.ITEM_Resources_Wood_Oak, 6)
    eq(#events_of(msgs, "task_done"), 1)
    local inst = inventory.list()[1]
    eq(inst.max_stack, 99); eq(inst.name, "Oak Logs"); eq(inst.source, "pickup"); assert(inst.guid)
end)

test("pickup limit: several world items in a row; by id; probe; invalid args", function()
    setup()
    make_puppet(0, 0, 0)
    world_item(OAK, 1, 100, 0, 0)
    world_item(OAK, 1, 150, 0, 0)
    world_item(OAK, 1, 120, 50, 0)
    local msgs, id = cmd("pickup", { target = "nearest", item = "oak", limit = 3 })
    msgs = ticks(8)
    local r = result_of(msgs, id)
    assert(r and r.ok and r.data.count == 3 and #r.data.picked == 3, json.encode(r))
    eq(inventory.count(OAK), 3); eq(#inventory.list(), 1, "merged into one stack")
    -- by id
    local w = world_item(ASH, 4, 100, 0, 0)
    msgs, id = cmd("pickup", { target = w._full:match("([%w_]+)$") })
    msgs = ticks(3)
    r = result_of(msgs, id)
    assert(r and r.ok and r.data.count == 4, json.encode(r))
    -- probe and invalid args never act
    world_item(OAK, 1, 100, 0, 0)
    msgs, id = cmd("pickup", { probe = true })
    r = result_of(msgs, id)
    assert(r.ok and r.data.probe == true)
    for _, a in ipairs({ {}, { target = "" }, { target = "nearest", limit = 0 }, { target = "nearest", limit = 99 }, { target = "nearest", item = 5 } }) do
        msgs, id = cmd("pickup", a)
        eq(result_of(msgs, id).reason, "invalid_args", json.encode(a))
    end
    eq(skills.current(), nil); eq(inventory.count(OAK), 3)
end)

test("pickup failures: nothing in range, unknown id, a player is collecting it, path blocked", function()
    setup()
    make_puppet(0, 0, 0)
    local msgs, id = cmd("pickup", { target = "nearest" })
    eq(result_of(msgs, id).reason, "nothing_in_range")
    msgs, id = cmd("pickup", { target = "BP_RuntimeSpawnedWorldItem_C_1" })
    eq(result_of(msgs, id).reason, "unknown_target")
    local luis = make_player("luis_epic", 256, 0, 0, 0)
    local w = world_item(OAK, 3, 100, 0, 0, { target = luis })
    msgs, id = cmd("pickup", { target = w._full:match("([%w_]+)$") })
    eq(result_of(msgs, id).reason, "unknown_target")
    msgs, id = cmd("pickup", { target = "nearest" })
    eq(result_of(msgs, id).reason, "nothing_in_range", "items a player's magnet is pulling are not offered")
    -- far item, the puppet never moves -> path_blocked after the reissues
    world_item(ASH, 1, 2000, 0, 0)
    msgs, id = cmd("pickup", { target = "nearest", item = "ash" })
    msgs = ticks(math.ceil((item_skills.STUCK_MS * (item_skills.MAX_REISSUE + 2)) / skills.TICK_MS))
    local r = result_of(msgs, id)
    assert(r and r.reason == "path_blocked", json.encode(r))
    eq(inventory.count(ASH), 0)
end)

test("pickup verification: the world item stays -> store rolled back, verification_failed", function()
    setup()
    make_puppet(0, 0, 0)
    world_item(OAK, 5, 100, 0, 0, { sticky = true }) -- SetLifeSpan has no effect on this one
    local msgs, id = cmd("pickup", { target = "nearest" })
    msgs = ticks(1)
    eq(inventory.count(OAK), 5)
    msgs = ticks(math.ceil(item_skills.VERIFY_MS / skills.TICK_MS) + 1)
    local r = result_of(msgs, id)
    assert(r and r.reason == "verification_failed", json.encode(r))
    eq(inventory.count(OAK), 0, "no duplicate left in the store")
end)

test("drop at feet: store first, SpawnAndLaunchItem_Sync with EVERY struct field, verified", function()
    setup()
    local p = make_puppet(0, 0, 0)
    inventory.add({ item_data_path = OAK, count = 150, name = "Oak Logs" })
    local msgs, id = cmd("drop", { item = "oak", count = 120 })
    local r = result_of(msgs, id)
    assert(r and r.ok, json.encode(r))
    eq(r.data.count, 120); eq(#r.data.world_items, 2, "99 + 21: one world item per max stack")
    eq(r.data.inventory_left, 30); eq(inventory.count(OAK), 30)
    eq(#F.spawn_calls, 2)
    local prm = F.spawn_calls[1].params
    for _, k in ipairs({ "ItemClass", "bCreateItem", "bMagnetize", "SpawnedItemData", "CopiedItem", "Count", "Transform",
                         "LaunchDirection", "LaunchSpeed", "LaunchAngleVariance", "bSkipFloorSafetyCheck", "OwnerController",
                         "bSpawnOnlyForController", "PlayerControllerThatDroppedItem", "bAddToWorldItemRuntimeCache",
                         "bMagnetizeToInstigatorOnSpawn" }) do
        assert(prm[k] ~= nil, "missing struct field " .. k)
    end
    eq(prm.CopiedItem, NULL); eq(prm.OwnerController, NULL); eq(prm.PlayerControllerThatDroppedItem, NULL)
    eq(prm.bSpawnOnlyForController, false, "must replicate"); eq(prm.bCreateItem, true); eq(prm.bMagnetize, false)
    eq(prm.ItemClass, F.assets[items.PATHS.noexpiry]); eq(prm.SpawnedItemData, F.assets[OAK]); eq(prm.Count, 99)
    eq(prm.Transform.Rotation.W, 1.0); eq(prm.Transform.Scale3D.Z, 1.0)
    eq(prm.Transform.Translation.X, 100, "1 m in front of the bot")
    eq(F.spawn_calls[1].world, F.world); eq(F.spawn_calls[1].out, "")
    eq(F.spawn_calls[2].params.Count, 21)
    -- the new world items are real, at the spot, with the right stack
    local w = items.by_id(r.data.world_items[1])
    eq(items.read(w).count, 99)
    eq(skills.current(), nil)
    eq(p.controller.stops, 0, "a drop does not stop the bot")
end)

test("drop failures: unknown, not enough, too far from Luis, invalid args, probe", function()
    setup()
    make_puppet(0, 0, 0)
    inventory.add({ item_data_path = OAK, count = 5 })
    local msgs, id = cmd("drop", { item = "stone", count = 1 })
    eq(result_of(msgs, id).reason, "not_in_inventory")
    msgs, id = cmd("drop", { item = "oak", count = 6 })
    local r = result_of(msgs, id)
    eq(r.reason, "not_enough_resources"); eq(r.data.have, 5)
    make_player("luis_epic", 256, 5000, 0, 0)
    msgs, id = cmd("drop", { item = "oak", count = 1, at = "luis" })
    eq(result_of(msgs, id).reason, "too_far")
    for _, a in ipairs({ {}, { item = "oak" }, { item = "oak", count = 0 }, { item = "oak", count = 1.5 }, { item = "oak", count = 1, at = "moon" } }) do
        msgs, id = cmd("drop", a)
        eq(result_of(msgs, id).reason, "invalid_args", json.encode(a))
    end
    msgs, id = cmd("drop", { probe = true })
    assert(result_of(msgs, id).ok)
    eq(#F.spawn_calls, 0); eq(inventory.count(OAK), 5)
end)

test("drop: a failed spawn refunds the store; a wrong stack is reported and not refunded", function()
    setup()
    make_puppet(0, 0, 0)
    inventory.add({ item_data_path = OAK, count = 10 })
    F.spawn_error = true
    local msgs, id = cmd("drop", { item = "oak", count = 4 })
    local r = result_of(msgs, id)
    eq(r.reason, "body_error"); eq(inventory.count(OAK), 10, "refunded")
    F.spawn_error, F.spawn_bad_stack = false, true
    msgs, id = cmd("drop", { item = "oak", count = 4 })
    r = result_of(msgs, id)
    eq(r.reason, "verification_failed"); eq(r.data.spawned, true)
    eq(inventory.count(OAK), 6, "an item did spawn: no refund (never duplicate)")
end)

test("drop at Luis when close; give walks to the player then drops at his feet", function()
    setup()
    make_puppet(0, 0, 0)
    local luis = make_player("luis_epic", 256, 300, 0, 0)
    inventory.add({ item_data_path = OAK, count = 20 })
    local msgs, id = cmd("drop", { item = "oak", count = 2, at = "luis" })
    local r = result_of(msgs, id)
    assert(r.ok, json.encode(r))
    eq(F.spawn_calls[1].params.Transform.Translation.X, 200, "1 m from Luis toward the bot")
    -- give from afar: async, walks first
    luis.loc = { X = 3000, Y = 0, Z = 0 }
    msgs, id = cmd("give", { player = "256", item = "oak", count = 5 })
    eq(result_of(msgs, id), nil, "async")
    msgs = ticks(1)
    local c = F.puppet.controller
    eq(c.moves[#c.moves].goal, luis)
    eq(#F.spawn_calls, 1, "nothing dropped on the way")
    F.puppet.loc = { X = 2800, Y = 0, Z = 0 }
    msgs = ticks(1)
    r = result_of(msgs, id)
    assert(r and r.ok and r.data.player == "256" and r.data.count == 5, json.encode(r))
    eq(F.spawn_calls[2].params.Transform.Translation.X, 2900)
    eq(inventory.count(OAK), 13)
    eq(#events_of(msgs, "task_done"), 1)
    -- give failures answer at once
    msgs, id = cmd("give", { player = "256", item = "oak", count = 99 })
    eq(result_of(msgs, id).reason, "not_enough_resources")
    -- unknown name: with one player online it means that player (loose, as follow); with two it fails
    make_player("bob", 257, 0, 0, 0)
    msgs, id = cmd("give", { player = "nobody_here", item = "oak", count = 1 })
    eq(result_of(msgs, id).reason, "unknown_target")
    msgs, id = cmd("give", { item = "oak", count = 1 })
    eq(result_of(msgs, id).reason, "invalid_args")
end)

test("get_state: inventory summary, instances and nearby_items; inventory no longer not_implemented", function()
    setup()
    make_puppet(0, 0, 0)
    inventory.add({ item_data_path = OAK, count = 7, name = "Oak Logs" })
    inventory.add({ item_data_path = SWORD, count = 1, level = 6 })
    world_item(ASH, 2, 300, 0, 0)
    local msgs, id = cmd("get_state")
    local r = result_of(msgs, id)
    assert(r.ok, json.encode(r))
    eq(r.data.inventory.ITEM_Resources_Wood_Oak, 7); eq(r.data.inventory.ITEM_Sword_Mithril, 1)
    eq(#r.data.inventory_items, 2); eq(r.data.inventory_items[2].level, 6)
    eq(#r.data.nearby_items, 1); eq(r.data.nearby_items[1].item, "ITEM_Resources_Wood_Ash")
    eq(r.data.nearby_items[1].distance, 3); eq(r.data.nearby_items[1].count, 2)
    for _, k in ipairs(r.data.not_implemented) do assert(k ~= "inventory", "inventory still listed as not implemented") end
    -- empty store encodes as an object
    inventory._reset(); inventory.init({ log = H.log, persist = { load = function() end, save = function() return true end } })
    local _, raw = result_of(cmd("get_state"))
    msgs, id = cmd("get_state")
    _, raw = result_of(msgs, id)
    assert(raw:find('"inventory":{}', 1, true), raw:sub(1, 300))
end)

test("debug: inventory listing and inventory_grant (not a brain tool)", function()
    setup()
    local msgs, id = cmd("inventory_grant", { item_path = AIR, count = 50 })
    assert(result_of(msgs, id).ok)
    msgs, id = cmd("inventory")
    local r = result_of(msgs, id)
    eq(r.data.inventory.ITEM_Rune_Air, 50)
    msgs, id = cmd("inventory_grant", { item_path = "ITEM_Rune_Air", count = 5 })
    eq(result_of(msgs, id).reason, "invalid_args")
    msgs, id = cmd("capabilities")
    local set = {}
    for _, t in ipairs(result_of(msgs, id).data.tools) do set[t] = true end
    assert(set.pickup and set.drop and set.give and set.inventory, "capabilities must list the item tools")
end)

test("hard rule: no unpossess, no puppet destroy, no immediate world-item destroy", function()
    eq(#F.forbidden, 0, "forbidden calls: " .. table.concat(F.forbidden, ", "))
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
