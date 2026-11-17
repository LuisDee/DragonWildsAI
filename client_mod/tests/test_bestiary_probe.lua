-- Offline test for client_mod/commands/bestiary_tables_probe.lua over a fake engine: every source read, the joins
-- (attack hit -> damage row, enemy loot -> drop row -> items, chest -> profile -> roll -> item sets), one table that
-- will not enumerate and one whose rows fail (the rest still read, both listed as unread), the row and time caps, an
-- empty world, that the result encodes as JSON (the runner's dkjson), the `only` groups (each group in its own call,
-- unread lines filed by group) and the registry walk in slices (start/limit, its own share of the time cap, resumable
-- from walk.next).
-- Usage: lua test_bestiary_probe.lua [out_dir]   (out_dir: also write the full result there as bestiary_probe_fake.json)
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
local root = (here .. "/../.."):gsub("\\", "/")
local real_getenv = os.getenv
os.getenv = function(k) if k == "DW_CLIENT_ROOT" then return root end return real_getenv(k) end
package.path = root .. "/client_mod/scripts/?.lua;" .. package.path
local json = require("dkjson")
local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

-- ---- fake engine
local function obj(full, t)
    t = t or {}
    t.IsValid = function() return true end
    t.GetFullName = function() return full end
    t.GetFName = t.GetFName or function() return (full:match("([%w_]+)$")) end
    return t
end
local function arr(items)
    return { ForEach = function(_, fn)
        for i, v in ipairs(items) do if fn(i, { get = function() return v end }) then break end end
    end }
end
local function soft(path) return { GetObjectID = function() return { GetAssetPathName = function() return path end } end } end
local function dt(path, rows, opts)
    opts = opts or {}
    local names = {}
    for k in pairs(rows) do names[#names + 1] = k end
    table.sort(names)
    return obj("DataTable " .. path, {
        GetRowStruct = function() return { GetFName = function() return opts.struct or "Row" end } end,
        ForEachRow = function(_, fn)
            if opts.no_foreach then error("ForEachRow unavailable") end
            for _, k in ipairs(names) do if fn(k, rows[k]) then break end end
        end,
        GetRowNames = function() if opts.no_names then error("no names") end; return names end,
        FindRow = function(_, k) if opts.bad_rows then error("row read fault") end; return rows[k] end,
    })
end
local function handle(t, row) return { DataTable = t, RowName = row } end
local function item(id, name) return obj("ItemData /Game/Items/" .. id .. "." .. id, { Name = name }) end
local function res(it, mn, mx, ch) return { SpawnedItemData = it, MinimumDropAmount = mn, MaximumDropAmount = mx, DropChance = ch } end

local function world(empty, extra)
    local W = { objects = {}, all = {}, cost = 0 }
    if empty then return W end
    local P = "/Game/Gameplay/AI/"
    local bg = dt(P .. "DT_AIAttackDamage_BG.DT_AIAttackDamage_BG",
        { GiantRat_Bite = { Damage = 12 }, GiantRat_Lunge = { Damage = 18 } })
    W.objects[P .. "DT_AIAttackDamage_BG.DT_AIAttackDamage_BG"] = bg
    -- Fellhollow: lists no rows either way (unread); DowdunReach: not loaded at all (unread)
    W.objects["/FutureMajorVersion/Gameplay/AI/DT_AIAttackDamage_Fellhollow.DT_AIAttackDamage_Fellhollow"] =
        dt("/FutureMajorVersion/Gameplay/AI/DT_AIAttackDamage_Fellhollow.DT_AIAttackDamage_Fellhollow", { Zogre_Flop = { Damage = 40 } },
            { no_foreach = true, no_names = true })
    W.objects[P .. "DT_AIData_BG.DT_AIData_BG"] = dt(P .. "DT_AIData_BG.DT_AIData_BG", { GiantRat_1 = { MaxHealth = 50 } })
    -- the registry: one loaded class, one not loaded
    local rat_path = P .. "GiantRat/Attacks/ATK_GiantRat_Bite.ATK_GiantRat_Bite_C"
    local cdo = obj("ATK_GiantRat_Bite_C " .. P .. "GiantRat/Attacks/ATK_GiantRat_Bite.Default__ATK_GiantRat_Bite_C", {
        AttackPropertyFlags = 3, AiAttackType = { TagName = "AI.Attack.Melee" }, bCanDoCollateralDamage = false,
        GameplayEffects = arr({ obj("BlueprintGeneratedClass /Game/GE/GE_Poison.GE_Poison_C") }),
        NextAttack = nil, Spawns = arr({}),
        Damage = arr({ { Time = 0.6, Force = 300, DamageClass = 1, Directionality = 4,
                         Types = { GameplayTags = arr({ { TagName = "DamageType.Physical.Stab" } }) },
                         DamageDataTableRowHandle = handle(bg, "GiantRat_Bite") } }),
    })
    W.objects[rat_path] = obj("BlueprintGeneratedClass " .. rat_path, { GetCDO = function() return cdo end })
    -- an attack default that only FindAllOf lists, whose damage table is not loaded on the client
    local zog = obj("ATK_Zogre_Flop_C /Game/Gameplay/AI/Zogre/ATK_Zogre_Flop.Default__ATK_Zogre_Flop_C", {
        AttackPropertyFlags = 16, Damage = arr({ { Time = 1.2, DamageClass = 1, Types = { GameplayTags = arr({}) },
                                                  DamageDataTableRowHandle = { RowName = "Zogre_Flop" } } }) })
    local listed = { soft(rat_path), soft(P .. "Kebbit/ATK_Kebbit_Attack_01.ATK_Kebbit_Attack_01_C") }
    for i = 1, extra or 0 do listed[#listed + 1] = soft(string.format("%sZz/ATK_Zz_%02d.ATK_Zz_%02d_C", P, i, i)) end  -- not loaded
    local reg = obj("AIActionAttackRegistry /Game/Maps/World/L_World.L_World:DominionAISubsystem_1.AIActionAttackRegistry_1",
        { Attacks = arr(listed) })
    -- loot: the enemy table, its drop rows, a composite table whose rows fault
    local L = "/Game/Gameplay/Items/LootDropTables/"
    local drops = dt(L .. "DT_LootDropTable.DT_LootDropTable", {
        GiantRat_Common = { DropChance = 1, Conditions = arr({}), Resources = arr({ res(item("ITEM_RawRatMeat", "Raw Rat Meat"), 1, 1, 1) }),
                            Recipes = arr({}) },
        GiantRat_Night = { DropChance = 0.1, Conditions = arr({ 1 }), Resources = arr({ res(item("ITEM_ShinyTooth", "Shiny Tooth"), 1, 2, 0.02) }),
                           Recipes = arr({}) } })
    W.objects[L .. "DT_EnemyLootDropTable.DT_EnemyLootDropTable"] = dt(L .. "DT_EnemyLootDropTable.DT_EnemyLootDropTable", {
        GiantRat = { TablesByPowerLevel = arr({
            { MinimumPowerLevel = 1, TableHandles = arr({ handle(drops, "GiantRat_Common") }) },
            { MinimumPowerLevel = 3, TableHandles = arr({ handle(drops, "GiantRat_Common"), handle(drops, "GiantRat_Night"),
                                                          handle(drops, "Missing_Row") }) } }) } })
    W.objects[L .. "DT_CompositeEnemyLootDropTable.DT_CompositeEnemyLootDropTable"] =
        dt(L .. "DT_CompositeEnemyLootDropTable.DT_CompositeEnemyLootDropTable", { X = {} }, { bad_rows = true })
    -- a vault chest: profile -> roll -> sets
    local sets = dt("/Game/Loot/DT_ItemSets.DT_ItemSets", {
        Skeklac_Core = { SpawnableItems = arr({ res(item("ITEM_VaultCore", "Vault Core"), 1, 1, 1) }) },
        Skeklac_Tomes = { SpawnableItems = arr({ res(item("ITEM_SkillTome", "Skill Tome"), 1, 3, 0.5) }) } })
    local rolls = dt("/Game/Loot/DT_Rolls.DT_Rolls", { Skeklac_Chest = {
        GuaranteedItemSets = arr({ handle(sets, "Skeklac_Core") }), GuaranteedStandaloneItems = arr({}),
        MinAdditionalSetRolls = 1, MaxAdditionalSetRolls = 2,
        AdditionalItemSets = arr({ { LootItemSetHandle = handle(sets, "Skeklac_Tomes"), DropChance = 0.1 } }) } })
    local profiles = dt("/Game/Loot/DT_ChestRespawn.DT_ChestRespawn", { Vault_Skeklac = { RespawnTrigger = 1,
        LootRollHandle = handle(rolls, "Skeklac_Chest") } })
    local chest = obj("BP_WorldChest_Vault_C /Game/Maps/World/L_World.L_World:PersistentLevel.BP_WorldChest_Vault_C_7", {
        ChestRespawnProfile = handle(profiles, "Vault_Skeklac"), ChestState = 0,
        K2_GetActorLocation = function() return { X = 12345, Y = -600, Z = 50 } end })
    -- a chest whose profile table is server-only (not loaded): listed as unread
    local chest2 = obj("BP_WorldChest_Vault_C /Game/x.BP_WorldChest_Vault_C_8", { ChestRespawnProfile = { RowName = "Vault_Other" },
        K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end })
    W.all.JournalEntryWorldData = {
        obj("JournalEntryWorldData /Script/Dominion.Default__JournalEntryWorldData"),
        obj("JournalEntryWorldData /Game/UI/JournalData/Entries/JOURNAL_World_Fauna_GiantRat.JOURNAL_World_Fauna_GiantRat", {
            DisplayName = "Giant Rat", PowerLevel = 1, Weaknesses = arr({ "Weakness: Stab", "Resistance: Crush" }),
            Locations = arr({ { LocationText = "Temple Woods" } }), Materials = arr({ { MaterialItemData = item("ITEM_RawRatMeat", "Raw Rat Meat") } }),
            UnlockCondition = { AIData = soft("/Game/Gameplay/AI/GiantRat/AIData_GiantRat.AIData_GiantRat_C") } }),
        obj("JournalEntryWorldData /Game/UI/JournalData/Entries/JOURNAL_World_Flora_Ash.JOURNAL_World_Flora_Ash", {
            DisplayName = "Ash", Weaknesses = arr({}), Locations = arr({}), Materials = arr({}) }),
    }
    W.all.AIActionAttackRegistry = { reg }
    W.all.AiAttackData = { cdo, zog, obj("AiAttackData /Script/Dominion.Default__AiAttackData") }
    W.all.WorldChest = { chest, chest2 }
    return W
end

local W
-- a fake clock: each StaticFindObject costs W.cost seconds (the registry walk's real cost on his client)
local fake_t = 0
os.clock = function() return fake_t end
function StaticFindObject(p) fake_t = fake_t + (W.cost or 0); return W.objects[p] end
function FindAllOf(c) return W.all[c] end

local src = assert(io.open(root .. "/client_mod/commands/bestiary_tables_probe.lua", "rb")):read("a")
local function probe(args)
    local logs = {}
    local chunk = assert(load((args and ("local ARGS = " .. args .. "\n") or "") .. src, "=bestiary_tables_probe"))
    local fn = chunk()
    local r = fn(function(m) logs[#logs + 1] = m end)
    return r, table.concat(logs, "\n")
end
local function errs(args)
    local ok, err = pcall(probe, args)
    return not ok and tostring(err) or nil
end
local function keys(t) local l = {}; for k in pairs(t or {}) do l[#l + 1] = k end; table.sort(l); return table.concat(l, ",") end
local function has(list, pat) for _, x in ipairs(list or {}) do if tostring(x):find(pat, 1, true) then return true end end return false end

-- 1. a loaded world
W = world()
local r, logs = probe('{ vault = "Skeklac Kara" }')
check("journal: Default__ skipped, both entries read", r.journal.found == 2 and #r.journal.entries == 2, r.journal.found)
local rat = r.journal.entries[1]
check("journal: weaknesses, power level, places, materials, AI data", rat.name == "Giant Rat" and rat.weaknesses[1] == "Weakness: Stab"
    and rat.weaknesses[2] == "Resistance: Crush" and rat.power_level == 1 and rat.locations[1] == "Temple Woods"
    and rat.materials[1] == "Raw Rat Meat" and rat.ai_data:find("AIData_GiantRat"), json.encode(rat))
check("journal: one entry with weaknesses", r.journal.with_weaknesses == 1)
check("attack damage rows", r.attack_damage.DT_AIAttackDamage_BG.rows.GiantRat_Bite == 12
    and r.attack_damage.DT_AIAttackDamage_BG.rows.GiantRat_Lunge == 18)
check("a table that will not enumerate is unread, not an error", has(r.unread, "DT_AIAttackDamage_Fellhollow: ForEachRow failed")
    and r.sections["attack_damage:DT_AIAttackDamage_Fellhollow"].ok == true)
check("a table not loaded is unread", has(r.unread, "DT_AIAttackDamage_DowdunReach: table not loaded"))
check("AI health rows", r.ai_data.DT_AIData_BG.rows.GiantRat_1 == 50)
check("registry lists every attack path", r.attacks.registry.n == 2 and has(r.attacks.registry.paths, "ATK_Kebbit_Attack_01"))
local bite = r.attacks.loaded.ATK_GiantRat_Bite
check("loaded attack: flags", bite and bite.unblockable and bite.unparryable and bite.flags == 3, bite and json.encode(bite))
check("loaded attack: type, effects", bite.type == "AI.Attack.Melee" and bite.effects[1] == "GE_Poison_C")
local h = bite.hits[1]
check("loaded attack: hit joined to its damage row", h.table == "DT_AIAttackDamage_BG" and h.row == "GiantRat_Bite" and h.damage == 12
    and h.types[1] == "DamageType.Physical.Stab" and h.damage_class == 1 and h.time == 0.6, json.encode(h))
local flop = r.attacks.loaded.ATK_Zogre_Flop
check("FindAllOf adds a default the registry does not name", flop and flop.force_blast and flop.hits[1].row == "Zogre_Flop"
    and flop.hits[1].table_loaded == false and flop.hits[1].damage == nil, flop and json.encode(flop))
check("the not-loaded registry class is not invented", r.attacks.loaded.ATK_Kebbit_Attack_01 == nil and r.attacks.loaded_n == 2)
local lv = r.enemy_loot.DT_EnemyLootDropTable.rows.GiantRat
check("enemy loot: levels and drop keys", #lv == 2 and lv[1].min_power_level == 1 and lv[1].drops[1] == "DT_LootDropTable:GiantRat_Common"
    and #lv[2].drops == 3, json.encode(lv))
local night = r.loot_rows["DT_LootDropTable:GiantRat_Night"]
check("drop row: chance, condition, items", night.drop_chance == 0.1 and night.conditions[1] == "night"
    and night.items[1].item == "ITEM_ShinyTooth" and night.items[1].item_name == "Shiny Tooth" and night.items[1].max == 2, json.encode(night))
check("a missing drop row is false and unread", r.loot_rows["DT_LootDropTable:Missing_Row"] == false and has(r.unread, "Missing_Row"))
check("a table whose rows fault: rows unread, later sections still run",
    has(r.unread, "DT_CompositeEnemyLootDropTable: 1 rows did not read") and r.chests ~= nil)
local c1 = r.chests.actors[1]
check("chest: profile -> roll -> sets", c1.vault == "Skeklac Kara" and c1.respawn == "on_opened" and c1.min_extra_rolls == 1
    and c1.guaranteed_sets[1].items[1].item_name == "Vault Core" and c1.extra_sets[1].chance == 0.1
    and c1.extra_sets[1].items[1].item == "ITEM_SkillTome" and c1.pos_m[1] == 123.45, json.encode(c1))
check("chest with a server-only profile table is unread", r.chests.actors[2].unread == "profile table not loaded on the client"
    and has(r.unread, "BP_WorldChest_Vault_C_8"))
check("counts", r.counts.journal == 2 and r.counts.attacks_loaded == 2 and r.counts.chests == 2 and r.counts.unread == #r.unread)
check("prints what it could not read", logs:find("could not read DT_AIAttackDamage_DowdunReach", 1, true) and logs:find("done in", 1, true))
local ok_enc, txt = pcall(json.encode, { ok = true, result = r })
check("all groups ran, in order", r.groups and table.concat(r.groups, ",") == "journal,attack_damage,ai_data,attacks,enemy_loot,chests",
    r.groups and table.concat(r.groups, ","))
check("unread filed by group", r.unread_by_group and has(r.unread_by_group.attack_damage, "DT_AIAttackDamage_DowdunReach: table not loaded")
    and has(r.unread_by_group.enemy_loot, "Missing_Row") and has(r.unread_by_group.chests, "BP_WorldChest_Vault_C_8")
    and r.unread_by_group.journal == nil)
local wk = r.attacks.walk or {}
check("registry walked whole in one slice", wk.start == 1 and wk.stop == 2 and wk.n == 2 and wk.next == nil and wk.walked == 2,
    json.encode(wk))
check("result encodes as JSON", ok_enc and type(txt) == "string" and txt:find('"GiantRat_Bite"', 1, true), txt)
if arg and arg[1] and ok_enc then
    local f = io.open(arg[1]:gsub("\\", "/") .. "/bestiary_probe_fake.json", "wb"); if f then f:write(txt); f:close() end
end

-- 2. caps: one row per table; a spent time budget skips every section and says so
W = world()
r = probe("{ max_rows = 1 }")
check("row cap: truncated and listed", has(r.truncated, "DT_AIAttackDamage_BG: row cap 1") and r.attack_damage.DT_AIAttackDamage_BG.enumerated == 1)
r = probe("{ max_s = -1 }")
check("time cap: sections skipped, each listed as unread", r.sections.journal.skipped and has(r.unread, "journal: time cap")
    and has(r.unread, "chests: time cap") and r.journal == nil)

-- 3. `only`: one group per call, its own cap; the other groups are not run, not read and not listed as unread
local function run(name, f) local ok, err = pcall(f); if not ok then check(name .. " (raised)", false, err) end end
run("only", function()
    W = world()
    r = probe('{ only = "enemy_loot" }')
    check("only enemy_loot: that group alone", table.concat(r.groups, ",") == "enemy_loot" and r.journal == nil and r.attacks == nil
        and r.chests == nil and r.enemy_loot.DT_EnemyLootDropTable.rows.GiantRat ~= nil, keys(r))
    check("only enemy_loot: its sections alone", keys(r.sections) ==
        "enemy_loot:DT_CompositeEnemyLootDropTable,enemy_loot:DT_EnemyLootDropTable,enemy_loot:DT_EnemyLootDropTable_DowdunReach",
        keys(r.sections))
    check("only enemy_loot: unread is that group's alone", keys(r.unread_by_group) == "enemy_loot"
        and not has(r.unread, "time cap") and r.counts.journal == 0 and r.counts.attacks_loaded == 0, json.encode(r.unread))
    r = probe('{ only = { "journal", "chests" }, vault = "Skeklac Kara" }')
    check("only as a list", table.concat(r.groups, ",") == "journal,chests" and #r.journal.entries == 2 and #r.chests.actors == 2
        and r.enemy_loot == nil and r.attack_damage == nil)
    r = probe('{ only = "ai_data, attack_damage" }')
    check("only as a comma list, run in the probe's order", table.concat(r.groups, ",") == "attack_damage,ai_data"
        and r.ai_data.DT_AIData_BG.rows.GiantRat_1 == 50 and r.attack_damage.DT_AIAttackDamage_BG.rows.GiantRat_Bite == 12)
    local e = errs('{ only = "loot" }')
    check("an unknown group is an error naming the groups", e and e:find("unknown group 'loot'", 1, true) and e:find("enemy_loot", 1, true), e)
end)

-- 4. the registry walk in slices: start/limit, a share of the time cap, resumable from walk.next
run("walk", function()
    W = world(false, 7)   -- 9 registry paths: GiantRat (loaded), Kebbit, Zz_01..07 (not loaded)
    r = probe('{ only = "attacks", start = 1, limit = 1 }')
    check("slice 1 of 1 path: next is 2", r.attacks.walk.start == 1 and r.attacks.walk.stop == 1 and r.attacks.walk.next == 2
        and r.attacks.walk.n == 9 and r.attacks.loaded.ATK_GiantRat_Bite ~= nil, json.encode(r.attacks.walk))
    check("slice 1 also adds FindAllOf defaults", r.attacks.loaded.ATK_Zogre_Flop ~= nil and r.attacks.registry.n == 9)
    r = probe('{ only = "attacks", start = 2, limit = 3 }')
    check("slice 2..4: next is 5, no FindAllOf again", r.attacks.walk.stop == 4 and r.attacks.walk.next == 5 and r.attacks.walk.walked == 3
        and r.attacks.loaded.ATK_Zogre_Flop == nil and r.attacks.loaded.ATK_GiantRat_Bite == nil, json.encode(r.attacks))
    check("a slice with no class loaded says which paths", has(r.unread, "no ATK_* class loaded in registry paths 2..4"), json.encode(r.unread))
    r = probe('{ only = "attacks", start = 8, limit = 100 }')
    check("last slice: next is nil", r.attacks.walk.stop == 9 and r.attacks.walk.next == nil, json.encode(r.attacks.walk))
    r = probe('{ only = "attacks", start = 40 }')
    check("start past the end: nothing walked, said", r.attacks.walk.walked == 0 and r.attacks.walk.next == nil
        and has(r.unread, "start 40 is past the registry's 9 paths"), json.encode(r.unread))
    W.cost = 1            -- 1 s per StaticFindObject; max_s 5 gives the walk 3 s, so it stops after 4 paths and the read still runs
    r = probe('{ only = "attacks", max_s = 5 }')
    check("time cap in the walk: stops, next resumes there", r.attacks.walk.walked == 4 and r.attacks.walk.next == 5
        and r.attacks.walk.capped == true and has(r.unread, "time cap in the registry walk at path 5 of 9 (resume with start = 5)"),
        json.encode(r.attacks.walk))
    check("time cap in the walk: the read still runs", r.sections["attacks:read"].ok == true and r.attacks.loaded.ATK_GiantRat_Bite ~= nil)
    W.cost = 0
    check("default per-call cap is 5 s", probe().caps.max_s == 5)
end)

-- 5. an empty world (menu, nothing loaded): no error, everything listed as unread
W = world(true)
r = probe()
check("empty world: no section error", (function() for _, v in pairs(r.sections) do if v.ok ~= true then return false end end return true end)())
check("empty world: unread says why", has(r.unread, "no AIActionAttackRegistry") and has(r.unread, "no WorldChest actor loaded")
    and has(r.unread, "DT_EnemyLootDropTable: table not loaded") and r.counts.attacks_loaded == 0)
check("empty world: encodes", pcall(json.encode, r))

print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
