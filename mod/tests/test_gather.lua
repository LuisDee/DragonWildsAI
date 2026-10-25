-- Offline unit tests for the gather skill and its services: body/gather.lua (the generic loop over a
-- profile), body/resource_profiles.lua (data), body/sense.lua, body/hitcheck.lua, body/watch.lua.
-- A small fake world implements the recorded mechanics: oak HP 220 -> stump 110 + splittable log
-- (HP 105) -> BP_Log_Oak (HP 105) -> 6 drops; stump -> 1 drop; stone rock HP 75 -> 12 drops.
-- Usage: lua test_gather.lua <empty_dir>   (tests/test_lua_gather.py runs it with a tmp dir)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local H = dofile(here .. "/bridge_harness.lua")
package.path = here .. "/../?.lua;" .. package.path

-- =============================================================================== fake UE
local F
local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return self._valid end
function Obj:GetFullName() return self._full end
local function obj(full, t)
    t = t or {}
    t._valid, t._full = true, full
    return setmetatable(t, Obj)
end
local LEVEL = "/Game/Maps/L_World.L_World:PersistentLevel."
local OAK = "/Game/Gameplay/Items/Resources/Wood/ITEM_Resources_Wood_Oak.ITEM_Resources_Wood_Oak"
local STONE = "/Game/Gameplay/Items/Resources/Mineral/ITEM_Resources_Stone.ITEM_Resources_Stone"
local ADAMANT_AXE = "/UmbralSands/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Adamant.ITEM_Logging_Axe_Adamant"
local STONE_AXE = "/Game/Gameplay/Character/Player/Equipment/Held/Hatchet/ITEM_Logging_Axe_Stone.ITEM_Logging_Axe_Stone"
local BRONZE_PICK = "/Game/Gameplay/Character/Player/Equipment/Held/Pickaxe/ITEM_Pickaxe_Bronze.ITEM_Pickaxe_Bronze"

local function arr(list)
    return { ForEach = function(_, fn) for i, v in ipairs(list) do fn(i, { get = function() return v end }) end end,
             GetArrayNum = function() return #list end }
end

local function gate(tier, tag)
    return obj("BP_DamageModifier_SpecificWeapon_C /Game/Gameplay/DamageModifiers/DA_HatchetOnly_Tier" .. tier,
               { RequiredTier = tier, RequiredCategory = { TagName = tag } })
end

local spawn -- forward

local function actor(cls, families, x, y, hp, extra)
    F.n = F.n + 1
    local a = obj(cls .. " " .. LEVEL .. cls .. "_" .. F.n, extra or {})
    a._families = families
    a.loc = { X = x, Y = y, Z = 0 }
    a.hp = hp
    a.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    if hp then
        a.HealthComponent = obj("WorldActorHealthComponent", {
            MaxHealth = hp,
            GetAuthoritativeHealth = function() return a.hp end,
            DecreaseHealth = function(_, amount) F.damage(a, amount) end,
        })
    end
    F.actors[#F.actors + 1] = a
    return a
end

local function destroy(a) a._valid = false end

local function drop(item, x, y)
    F.n = F.n + 1
    local d = { actor = obj("BP_RuntimeSpawnedWorldItem_C " .. LEVEL .. "W_" .. F.n), id = "W_" .. F.n,
                item = item:match("%.([%w_]+)$"), item_data_path = item, count = 1, loc = { X = x, Y = y, Z = 0 } }
    d.actor.K2_GetActorLocation = function() return { X = x, Y = y, Z = 0 } end
    F.drops[#F.drops + 1] = d
    return d
end

-- the recorded mechanics (DISCOVERIES Woodcutting timeline)
local function oak_damage(a, amount)
    a.hp = math.max(0, a.hp - amount)
    local cw = a._full:match("^(%S+)")
    if cw:find("Tree_Oak") then
        if not a.bIsStump and a.hp <= 110 then
            a.bIsStump, a.hp = true, 110
            spawn.splittable(a.loc.X + 150, a.loc.Y)
            drop(OAK, a.loc.X + 100, a.loc.Y + 50)
        elseif a.bIsStump and a.hp <= 0 then
            destroy(a); drop(OAK, a.loc.X, a.loc.Y + 60)
        end
    elseif cw:find("SplittableLog_Oak") and a.hp <= 0 then
        destroy(a); spawn.log(a.loc.X + 50, a.loc.Y)
    elseif cw:find("BP_Log_Oak") and a.hp <= 0 then
        destroy(a)
        for i = 1, 6 do drop(OAK, a.loc.X + i * 20, a.loc.Y - 50) end
    elseif cw:find("OreNode_Stone") and a.hp <= 0 then
        a.bIsHidden = true
        for i = 1, 12 do drop(STONE, a.loc.X + i * 10, a.loc.Y + 40) end
    end
end

spawn = {
    oak = function(x, y)
        return actor("BP_BM_Tree_Oak_01_C", { FellableTree = true }, x, y, 220,
            { bIsStump = false, DamageModifiersWhenTree = arr({ gate(3, "Item.Equipment.Tool.Hatchet") }),
              DamageModifiersWhenStump = arr({ gate(3, "Item.Equipment.Tool.Hatchet") }) })
    end,
    ash = function(x, y)
        return actor("BP_BM_Tree_Ash_01_C", { FellableTree = true }, x, y, 160, { bIsStump = false })
    end,
    splittable = function(x, y)
        return actor("BP_SplittableLog_Oak_C", { TreeLog = true, SplittableTreeLog = true }, x, y, 105)
    end,
    log = function(x, y)
        -- pivot at one end, midpoint 600 cm along +X (as live: GetMidPointWorldLocation(out))
        return actor("BP_Log_Oak_C", { TreeLog = true }, x, y, 105, {
            GetMidPointWorldLocation = function(self, out) out.X, out.Y, out.Z = self.loc.X + 600, self.loc.Y, 0 end })
    end,
    stone = function(x, y)
        return actor("BP_OreNode_Stone_C", { DestructibleMiningRock = true }, x, y, 75,
            { bIsHidden = false, DamageComponent = { DamageModifiers = arr({ gate(1, "Item.Equipment.Tool.Pickaxe") }) } })
    end,
}

function FindAllOf(cls)
    local out = {}
    for _, a in ipairs(F.actors) do if a._valid and a._families[cls] then out[#out + 1] = a end end
    return #out > 0 and out or nil
end
function FindFirstOf() return nil end
function StaticFindObject(path)
    if path:find("/Attacks/", 1, true) then
        F.assets[path] = F.assets[path] or obj("Class " .. path)
        return F.assets[path]
    end
    return F.assets[path]
end

-- =============================================================================== modules under test
local U = require("body.util")
local gather = require("body.gather")
local profiles = require("body.resource_profiles")
local sense = require("body.sense")
local hitcheck = require("body.hitcheck")
local watch = require("body.watch")
local reach = require("body.reach")
U.set_log(H.log)
gather.HIT = "auto" -- the default is native (no emulation); these tests cover the emulated route too

local function reset()
    F = { n = 0, actors = {}, drops = {}, assets = {}, inv = {}, now = 0, swings = {}, emits = {}, finished = nil,
          held = ADAMANT_AXE, move_ok = true, native_damage = nil, pickup_reason = nil, logs = {} }
    F.damage = oak_damage
    sense._reset()
    hitcheck._reset()
    F.puppet = obj("BP_PlayerCharacter_C " .. LEVEL .. "BP_PlayerCharacter_C_1")
    F.puppet.loc = { X = 0, Y = 0, Z = 0 }
    F.puppet.K2_GetActorLocation = function(self) return { X = self.loc.X, Y = self.loc.Y, Z = self.loc.Z } end
    F.puppet.GetController = function() return F.controller end
    F.controller = obj("AIController " .. LEVEL .. "AIController_1")
end

local function store()
    return {
        kind = "fake",
        count = function(item) return F.inv[item] or 0 end,
        find_drops = function(opts)
            local out = {}
            for _, d in ipairs(F.drops) do
                if d.actor._valid and (not opts.item or d.item == opts.item) then
                    d.dist = U.dist(opts.origin, d.loc)
                    if d.dist <= opts.radius_cm then out[#out + 1] = d end
                end
            end
            table.sort(out, function(a, b) return a.dist < b.dist end)
            return out
        end,
        pickup = function(_, info)
            if F.pickup_reason then return { ok = false, reason = F.pickup_reason, data = { detail = "store full" } } end
            info.actor._valid = false
            F.inv[info.item_data_path] = (F.inv[info.item_data_path] or 0) + info.count
            return { ok = true, data = { count = info.count, item = info.item } }
        end,
    }
end

local function deps()
    return {
        now = function() return F.now end,
        puppet = function() return F.puppet end,
        finish = function(a, ok, reason, data)
            if a.done then return end
            a.done = true
            F.finished = { ok = ok, reason = reason, data = data }
        end,
        emit = function(name, data) F.emits[#F.emits + 1] = { name = name, data = data } end,
        log = function(name, data) F.logs[#F.logs + 1] = { name = name, data = data } end,
        store = store(),
        held = function() return F.held end,
        face = function() return 0 end,
        stop_movement = function() F.stops = (F.stops or 0) + 1 end,
        shape_of = function() return reach.window_of({ kind = "DominionShape_Wedge", Depth = 150, TopAngle = 80, AngleOffset = 0 }) end,
        convert = function() F.converts = (F.converts or 0) + 1 end,
        perform = function(p, sw, actor, crumb)
            F.swings[#F.swings + 1] = { kind = sw.kind, target = actor, label = sw.label }
            if F.gate_events then
                hitcheck._record({ fn = "GetHeldEquipmentThatInflictedDamage", who = U.short(p), held = nil })
                hitcheck._record({ fn = "IsDamageCausedByUnarmedAttack", who = U.short(p), result = true })
                hitcheck._record({ fn = "ModifyDamage", who = U.short(p), amount = 10 })
            end
            if F.native_damage then -- the swing lands on the aimed target (DesiredActionTarget may be nil for logs)
                local tgt = actor
                if not tgt then for _, x in ipairs(F.actors) do if x._valid and U.short(x) == crumb.target then tgt = x end end end
                if tgt then F.damage(tgt, F.native_damage) end
            end
            return true
        end,
        move_to_actor = function(_, target)
            if not F.move_ok then return 0 end
            local t = target:K2_GetActorLocation()
            F.puppet.loc = { X = t.X - 80, Y = t.Y, Z = t.Z } -- arrive next to it
            return 2
        end,
        move_to_location = function(_, dest)
            if not F.move_ok then return 0 end
            F.loc_moves = (F.loc_moves or 0) + 1
            F.puppet.loc = { X = dest.X, Y = dest.Y, Z = dest.Z }
            return 2
        end,
        decrease_health = function(actor, amount)
            F.emulated = (F.emulated or 0) + 1
            actor.HealthComponent:DecreaseHealth(amount)
            return true
        end,
    }
end

local function run(resource, count, args, max_ticks)
    args = args or {}
    args.resource, args.count = resource, count
    local chk = assert(gather.check_args(args))
    local d = deps()
    sense.set_clock(function() return F.now end)
    local a = gather.new_action(chk.key, chk.profile, args, d, d.store.count(chk.profile.item))
    a.id = "t1"
    local tree = gather.tree(d)
    for _ = 1, (max_ticks or 4000) do
        F.now = F.now + 250
        tree(a)
        if a.done then break end
    end
    return F.finished, a
end

-- =============================================================================== tests
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end

test("profiles: resolve keys, aliases, item ids; unknown is nil", function()
    eq(profiles.resolve("oak"), "oak")
    eq(profiles.resolve("Oak Logs"), "oak")
    eq(profiles.resolve("log"), "oak")
    eq(profiles.resolve("ITEM_Resources_Wood_Oak"), "oak")
    eq(profiles.resolve(OAK), "oak")
    eq(profiles.resolve("stone"), "stone")
    eq(profiles.resolve("rocks"), "stone")
    eq(profiles.resolve("unobtainium"), nil)
    for key, p in pairs(profiles.RESOURCES) do
        truthy(p.item and p.item:find("^/"), key .. " item path")
        truthy(profiles.TOOL_CATEGORIES[p.tool], key .. " tool category")
        truthy(p.root and p.root.class and p.root.attack, key .. " root stage")
    end
end)

test("tool_ok: category and tier rules", function()
    local oak = profiles.RESOURCES.oak
    eq(gather.tool_ok(profiles.TOOLS.ITEM_Logging_Axe_Adamant, oak, { tier = 3 }), true)
    eq(gather.tool_ok(profiles.TOOLS.ITEM_Logging_Axe_Bronze, oak, { tier = 3 }), true)
    local ok, why = gather.tool_ok(profiles.TOOLS.ITEM_Logging_Axe_Stone, oak, { tier = 3 })
    eq(ok, false); eq(why, "tier_too_low")
    ok, why = gather.tool_ok(profiles.TOOLS.ITEM_Pickaxe_Bronze, oak, { tier = 1 })
    eq(why, "wrong_category")
    ok, why = gather.tool_ok(nil, oak, nil)
    eq(why, "no_tool")
end)

test("hitcheck.verdict: damaged, gate_no_weapon, tier, category, no_contact", function()
    eq(hitcheck.verdict({}, 220, 136), "damaged")
    eq(hitcheck.verdict({ { fn = "GetHeldEquipmentThatInflictedDamage" }, { fn = "IsDamageCausedByUnarmedAttack", result = true },
                          { fn = "ModifyDamage", amount = 10 } }, 220, 220), "gate_no_weapon")
    eq(hitcheck.verdict({ { fn = "GetHeldEquipmentThatInflictedDamage", held = "ITEM_Logging_Axe_Stone" },
                          { fn = "IsDamageCausedByUnarmedAttack", result = false },
                          { fn = "IsEquipmentCorrectCategory", result = true }, { fn = "IsEquipmentOfSufficientTier", result = false },
                          { fn = "ModifyDamage" } }, 220, 220), "gate_tier")
    eq(hitcheck.verdict({ { fn = "IsEquipmentCorrectCategory", result = false }, { fn = "ModifyDamage" } }, 1, 1), "gate_category")
    eq(hitcheck.verdict({}, 220, 220), "no_contact")
    eq(hitcheck.verdict({ { fn = "GetHeldEquipmentThatInflictedDamage", held = "X" }, { fn = "ModifyDamage" } }, 5, 5), "modified_to_zero")
end)

test("reach: wedge windows and the aim solution (calibrated live: Chop target 35 deg right, overhead straight)", function()
    local chop = reach.window_of({ kind = "DominionShape_Wedge", Depth = 115, TopAngle = 80, AngleOffset = 35 })
    eq(chop.max_cm, 115); eq(chop.half_angle, 40); eq(chop.angle_offset, 35)
    local here, tree = { X = 0, Y = 0, Z = 0 }, { X = 100, Y = 0, Z = 0 }
    local sol = reach.solve(here, tree, 30, chop, 1, 15)
    eq(sol.in_range, true); eq(sol.yaw, -35); eq(sol.hi, 130)
    sol = reach.solve({ X = -200, Y = 0, Z = 0 }, tree, 30, chop, 1, 15)
    eq(sol.in_range, false); truthy(sol.stand and math.abs(sol.stand.X - (100 - 100)) < 1, "stand at the sweet spot")
    local over = reach.window_of({ kind = "DominionShape_Wedge", Depth = 170, TopAngle = 15, AngleOffset = 0, Offset = { X = 0, Y = 0, Z = -40 } })
    sol = reach.solve(here, { X = 180, Y = 0, Z = 0 }, 30, over, 1, 15)
    eq(sol.in_range, true); eq(sol.yaw, 0)
    eq(reach.window_of(nil).kind, "default")
end)

test("look: generic perception from game data, ranked by what the player named", function()
    reset()
    spawn.oak(600, 0)
    local stick = actor("BP_Spawner_AshBranch_01_C", {}, 300, 100, nil, {
        ItemData = obj("ItemData /Game/Gameplay/Items/Resources/Wood/ITEM_Stick.ITEM_Stick", { Name = { ToString = function() return "Ash Branch" end } }),
        IsResourceAvailable = function() return true end })
    local ic = actor("InteractionComponent", { InteractionComponent = true }, 300, 100, nil, {
        InteractionPrompt = { ToString = function() return "Pick up" end } })
    ic.GetOwner = function() return stick end
    local rock = spawn.stone(900, 0)
    rock._families.DestructibleWorldActor = true
    local list, total = sense.look({ origin = { X = 0, Y = 0, Z = 0 }, radius_cm = 2000, about = "ash branches" })
    truthy(total >= 2, "found things: " .. tostring(total))
    eq(list[1].id, U.short(stick)); eq(list[1].name, "Ash Branch"); eq(list[1].verb, "gather"); eq(list[1].prompt, "Pick up")
    local r
    for _, t in ipairs(list) do if t.id == U.short(rock) then r = t end end
    truthy(r, "rock listed"); eq(r.verb, "mine"); eq(r.kind, "resource")
end)

test("watch.diff: appear, update, gone", function()
    local d = watch.diff({ a = { hp = 1 }, b = { hp = 5 } }, { b = { hp = 4 }, c = { hp = 9 } })
    eq(#d, 3)
    eq(d[1].change, "gone"); eq(d[1].actor, "a")
    eq(d[2].change, "update"); eq(d[3].change, "appear")
end)

test("sense: filters, census excludes stumps, nearest by distance, key is a 1 m grid", function()
    reset()
    local t1 = spawn.oak(1000, 0)
    local t2 = spawn.oak(500, 0)
    t2.bIsStump = true
    spawn.ash(300, 0)
    local spec = profiles.RESOURCES.oak.root
    local list = sense.census(spec, { origin = { X = 0, Y = 0, Z = 0 }, radius_cm = 5000 })
    eq(#list, 1); eq(list[1].actor, t1)
    local stump = sense.nearest(profiles.RESOURCES.oak.children[3], { origin = { X = 0, Y = 0, Z = 0 }, radius_cm = 5000 })
    eq(stump.actor, t2)
    eq(sense.key({ X = 149, Y = -49 }), "1:0")
end)

test("oak: fells, chops the logs and the stump, collects, goal verified from the inventory", function()
    reset()
    spawn.oak(1500, 0)
    local res, a = run("oak", 8)
    truthy(res, "finished")
    eq(res.ok, true, "ok (" .. tostring(res.reason) .. ")")
    eq(res.data.item, "ITEM_Resources_Wood_Oak")
    truthy(res.data.gathered >= 8, "gathered " .. tostring(res.data.gathered))
    eq(res.data.sites, 1)
    truthy(res.data.emulated_hits > 0 and res.data.native_hits == 0, "emulated hits")
    local kinds = {}
    for _, s in ipairs(F.swings) do kinds[s.kind] = (kinds[s.kind] or 0) + 1 end
    truthy(kinds.primary and kinds.special, "chop on the tree, overhead on logs/stump")
    local last = F.emits[#F.emits]
    eq(last.name, "gather_progress"); eq(last.data.want, 8); truthy(last.data.have >= 8)
    truthy((F.converts or 0) > 0, "foliage converted before the scan")
    -- order (Luis): tree, then the fell's pieces until they are drops, the drops, and the stump LAST
    local order = {}
    for _, e in ipairs(F.emits) do if e.name == "gather_step" then order[#order + 1] = e.data.stage end end
    eq(order[1], "root")
    local last_piece, stump_at = 0, nil
    for i, st in ipairs(order) do
        if st == "splittable" or st == "log" then last_piece = i end
        if st == "stump" and not stump_at then stump_at = i end
    end
    truthy(last_piece > 1, "pieces worked")
    truthy(stump_at and stump_at > last_piece, "stump after every piece: " .. table.concat(order, ","))
end)

test("logs are worked from their midpoint (the rolled mesh), not the stale pivot", function()
    reset()
    local lg = spawn.log(1000, 0)
    F.puppet.loc = { X = 1700, Y = 900, Z = 0 } -- beside the middle of the 12 m log
    local res = run("oak", 6, { bonus = false })
    eq(res.ok, true, tostring(res.reason))
    eq(lg._valid, false, "log chopped")
    truthy((F.loc_moves or 0) > 0, "walked to a stand point by the midpoint")
end)

test("no contact: the bot repositions around the target before giving up", function()
    reset(); spawn.oak(1500, 0)
    rawget(_G, "__dw_hitcheck").armed = true -- armed but no events: every swing is no_contact
    local res = run("oak", 3)
    eq(res.ok, false)
    truthy((F.loc_moves or 0) >= 2, "tried other stand points")
    local bad = false
    for _, l in ipairs(F.logs) do if l.name == "gather_bad_target" and tostring(l.data.why):find("no_contact") then bad = true end end
    truthy(bad, "marked bad with swing_no_effect:no_contact")
end)

test("oak: bonus=false leaves the stump standing", function()
    reset()
    local tree = spawn.oak(1500, 0)
    spawn.oak(4000, 0) -- second tree for the remaining logs
    local res = run("oak", 9, { bonus = false })
    eq(res.ok, true, tostring(res.reason))
    eq(tree._valid, true, "stump kept")
    eq(tree.bIsStump, true)
end)

test("nothing_in_range after widening to the max radius", function()
    reset()
    spawn.ash(500, 0) -- wrong species only
    local res, a = run("oak", 3)
    eq(res.ok, false); eq(res.reason, "nothing_in_range")
    eq(res.data.radius_m, gather.MAX_RADIUS_CM / 100)
end)

test("wrong_tool: pickaxe for oak; stone axe below the oak's live tier-3 gate", function()
    reset(); spawn.oak(1500, 0); F.held = BRONZE_PICK
    local res = run("oak", 3)
    eq(res.reason, "wrong_tool"); eq(res.data.detail, "wrong_category")
    reset(); spawn.oak(1500, 0); F.held = STONE_AXE
    res = run("oak", 3)
    eq(res.reason, "wrong_tool"); eq(res.data.detail, "tier_too_low"); eq(res.data.need_tier, 3)
    reset(); spawn.oak(1500, 0); F.held = nil
    res = run("oak", 3)
    eq(res.reason, "wrong_tool"); eq(res.data.detail, "no_tool")
    eq(#F.swings, 0, "never swings with the wrong tool")
end)

test("path_blocked after BAD_STREAK unreachable targets", function()
    reset()
    for i = 1, 4 do spawn.oak(1500 * i, 0) end
    F.move_ok = false
    local res = run("oak", 3)
    eq(res.reason, "path_blocked")
    eq(#F.swings, 0)
end)

test("inventory_full when the store refuses a pickup", function()
    reset(); spawn.oak(1500, 0); F.pickup_reason = "inventory_full"
    local res = run("oak", 3)
    eq(res.reason, "inventory_full")
end)

test("timeout", function()
    reset(); spawn.oak(1500, 0)
    local base, per = gather.TIMEOUT_BASE_MS, gather.TIMEOUT_PER_UNIT_MS
    gather.TIMEOUT_BASE_MS, gather.TIMEOUT_PER_UNIT_MS = 3000, 0
    local ok, res = pcall(run, "oak", 50)
    gather.TIMEOUT_BASE_MS, gather.TIMEOUT_PER_UNIT_MS = base, per
    assert(ok, res)
    eq(res.reason, "timeout")
end)

test("native damage is used when it works, never doubled by the emulated hit", function()
    reset(); spawn.oak(1500, 0); F.native_damage = 84
    local res = run("oak", 6)
    eq(res.ok, true, tostring(res.reason))
    truthy(res.data.native_hits > 0); eq(res.data.emulated_hits, 0); eq(F.emulated, nil)
end)

test("hitcheck armed: the gate verdict (unarmed) triggers the emulated hit", function()
    reset(); spawn.oak(1500, 0); F.gate_events = true
    rawget(_G, "__dw_hitcheck").armed = true
    local res = run("oak", 6)
    eq(res.ok, true, tostring(res.reason))
    truthy(res.data.emulated_hits > 0)
    local verdicts = {}
    for _, l in ipairs(F.logs) do if l.name == "gather_hit" then verdicts[l.data.verdict or "nil"] = true end end
    truthy(verdicts.gate_no_weapon, "logged verdict gate_no_weapon")
end)

test("HIT=native: no emulation; a gated target goes bad and the task fails", function()
    reset(); spawn.oak(1500, 0)
    gather.HIT = "native"
    local ok, res = pcall(run, "oak", 3)
    gather.HIT = "auto"
    assert(ok, res)
    eq(res.ok, false)
    eq(F.emulated, nil)
end)

test("stone: pickaxe on a mining rock, drops collected", function()
    reset(); spawn.stone(800, 0); F.held = BRONZE_PICK
    local res = run("stone", 10)
    eq(res.ok, true, tostring(res.reason))
    eq(res.data.item, "ITEM_Resources_Stone")
    truthy(F.inv[STONE] >= 10)
    for _, s in ipairs(F.swings) do eq(s.kind, "primary") end
end)

test("loose drops of the item nearby are collected first", function()
    reset()
    for i = 1, 3 do drop(OAK, 200 + i * 10, 0) end
    local res = run("oak", 3)
    eq(res.ok, true, tostring(res.reason))
    eq(#F.swings, 0, "no tree needed")
end)

test("check_args: invalid and unknown", function()
    local _, e = gather.check_args({ count = 3 }); eq(e.reason, "invalid_args")
    _, e = gather.check_args({ resource = "oak", count = 0 }); eq(e.reason, "invalid_args")
    _, e = gather.check_args({ resource = "oak", count = 2.5 }); eq(e.reason, "invalid_args")
    _, e = gather.check_args({ resource = "oak", count = 2, radius = -1 }); eq(e.reason, "invalid_args")
    _, e = gather.check_args({ resource = "mithril_wood", count = 2 }); eq(e.reason, "unknown_target")
    truthy(#e.data.known > 3)
end)

test("register: probe-safe handler; missing args answer invalid_args; no store -> not_implemented", function()
    reset()
    local bridge = { handlers = {}, emit_event = function() end }
    local started = 0
    local fake_skills = {
        now = function() return F.now end,
        _start = function() started = started + 1 end,
        _finish = function() end,
        _probe_guard = function(name, fn)
            return function(args, ctx)
                if type(args) == "table" and args.probe == true then return { ok = true, data = { probe = true, tool = name } } end
                return fn(args or {}, ctx)
            end
        end,
    }
    local fake_puppet = { get = function() return F.puppet end, ensure_ready = function() return F.puppet end }
    gather.register(bridge, H.log, { skills = fake_skills, puppet = fake_puppet })
    local h = bridge.handlers.gather
    truthy(h, "registered")
    local r = h({ probe = true }, { id = "p" }); eq(r.ok, true); eq(r.data.probe, true)
    r = h({}, { id = "x" }); eq(r.reason, "invalid_args")
    -- body.inventory is not initialised in this test: the handler refuses rather than counting nothing
    r = h({ resource = "oak", count = 2 }, { id = "y" })
    eq(r.reason, "not_implemented")
    eq(started, 0)
    -- with a store it starts an async action
    gather.register(bridge, H.log, { skills = fake_skills, puppet = fake_puppet, store = store() })
    r = bridge.handlers.gather({ resource = "oak", count = 2 }, { id = "z" })
    eq(r, nil, "async"); eq(started, 1)
end)

-- =============================================================================== runner
local failures = 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if not ok then failures = failures + 1 end
    print((ok and "PASS " or "FAIL ") .. t[1] .. (ok and "" or ("\n     " .. tostring(err))))
end
print(string.format("%d/%d passed", #tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)
