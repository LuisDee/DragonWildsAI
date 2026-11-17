-- Read-only bestiary probe (bestiary agent 2026-11-17, plan docs/research/2026-11-17-bestiary-gaps.md): the game's own
-- creature data that the wiki mirror lacks, in one call on his own client.
--   journal       every loaded JournalEntryWorldData: DisplayName, Weaknesses[] (FText lines), PowerLevel, Locations[],
--                 Materials[], UnlockCondition.AIData (the AI data asset it belongs to)
--   attack_damage DT_AIAttackDamage_{BG,Fellhollow,DowdunReach}: row name -> FAiAttackDamageDataTableRow.Damage
--   ai_data       DT_AIData_{BG,UmbralSands}: row name -> FAIDataTableRow.MaxHealth
--   attacks       the AI subsystem's AIActionAttackRegistry.Attacks (every attack class path, loaded or not), and per
--                 LOADED ATK_*_C class its default object (the object combat.lua read_attack reads at a telegraph):
--                 Damage[] {Time, DamageDataTableRowHandle -> Damage, Types tags, DamageClass, Force, Directionality},
--                 AttackPropertyFlags, AiAttackType, GameplayEffects, NextAttack. Only classes of creatures that have
--                 spawned near him are loaded: run it at home and in each region or vault, the merge takes the union.
--   enemy_loot    DT_EnemyLootDropTable (+ _DowdunReach, DT_CompositeEnemyLootDropTable): row -> TablesByPowerLevel[]
--                 {MinimumPowerLevel, TableHandles[]}, each handle FindRow'd through its OWN DataTable to
--                 FLootDropTableRow {Conditions, DropChance, Resources[] {item, min, max, chance}, Recipes[]}
--   chests        every loaded WorldChest actor: ChestRespawnProfile -> FChestRespawnSettings -> LootRollHandle ->
--                 FLootItemSetRoll -> item-set handles -> FLootItemSet.SpawnableItems (server-only tables read as unread)
-- Allowed calls only: property reads, StaticFindObject (never loads), FindAllOf, UDataTable ForEachRow / GetRowNames /
-- FindRow, UClass GetCDO, K2_GetActorLocation. No RPC, no hand-built struct, no LoadAsset, nothing written.
-- Reads on Blueprint-class objects (ATK_*_C defaults, WorldChest actors) go through U.prop (risk register R17).
-- Bounded: rows per table, rows in all, list lengths, and a time budget per call; each table or source in its own pcall.
-- What it could not read is listed in result.unread (and by group in result.unread_by_group) and logged.
-- One call blocks the game thread for its whole run (the runner calls it on the game thread; tickguard.lua and the
-- server's timeouts do not like long stalls). The first live run (2026-11-17 23:32Z, one call, max_s 8) spent 7.9 s in the
-- attack registry walk and never started enemy loot, attack reads or chests. So: run ONE GROUP PER CALL (ARGS.only), the
-- default cap is 5 s a call, and the registry walk goes in slices (start, limit) that resume from result.attacks.walk.next.
-- Optional prefix (the runner's ARGS convention), every key optional:
--   local ARGS = { only = "enemy_loot",   -- or a list { "journal", "chests" } or "ai_data, attack_damage"; default all
--                  start = 1, limit = 100, -- registry paths start .. start+limit-1 (sorted, so stable between calls)
--                  walk_s = 3,             -- the walk's share of max_s (default 0.6 * max_s), so the reads still run
--                  vault = "Skeklac Kara", max_rows = 4000, max_s = 5 }
-- Groups: journal, attack_damage, ai_data, attacks, enemy_loot, chests (an unknown one is an error).
-- Run (main session, between windows, from C:\gameserver, dev client in game; one line each, one group per call; each
-- result lands in client_io\out\<Name>.json):
--   journal:
--     . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; [IO.File]::WriteAllText($f, 'local ARGS = { only = "journal" }' + "`n" + $src); $r = Invoke-ClientCmd -Path $f -Name bestiary_probe_journal -TimeoutS 30; if ($r) { $r.result.counts; $r.result.unread } else { Clear-ClientCmd bestiary_probe_journal; 'no answer' }
--   attack_damage:
--     . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; [IO.File]::WriteAllText($f, 'local ARGS = { only = "attack_damage" }' + "`n" + $src); $r = Invoke-ClientCmd -Path $f -Name bestiary_probe_attack_damage -TimeoutS 30; if ($r) { $r.result.sections; $r.result.unread } else { Clear-ClientCmd bestiary_probe_attack_damage; 'no answer' }
--   ai_data:
--     . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; [IO.File]::WriteAllText($f, 'local ARGS = { only = "ai_data" }' + "`n" + $src); $r = Invoke-ClientCmd -Path $f -Name bestiary_probe_ai_data -TimeoutS 30; if ($r) { $r.result.sections; $r.result.unread } else { Clear-ClientCmd bestiary_probe_ai_data; 'no answer' }
--   attacks (slices of 100 registry paths, each resumed from walk.next; stops on no answer or no progress):
--     . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; $s = 1; while ($s) { $n = "bestiary_probe_attacks_$s"; [IO.File]::WriteAllText($f, "local ARGS = { only = 'attacks', start = $s, limit = 100 }`n" + $src); $r = Invoke-ClientCmd -Path $f -Name $n -TimeoutS 30; if (-not $r -or -not $r.ok) { Clear-ClientCmd $n; "stopped at start $s (no answer or error)"; break }; $w = $r.result.attacks.walk; "start $s -> next $($w.next): walked $($w.walked) of $($w.n) in $($w.seconds) s, $($r.result.attacks.loaded_n) loaded"; if (-not $w.next -or [int]$w.next -le $s) { break }; $s = [int]$w.next }
--   enemy_loot:
--     . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; [IO.File]::WriteAllText($f, 'local ARGS = { only = "enemy_loot" }' + "`n" + $src); $r = Invoke-ClientCmd -Path $f -Name bestiary_probe_enemy_loot -TimeoutS 30; if ($r) { $r.result.sections; $r.result.unread } else { Clear-ClientCmd bestiary_probe_enemy_loot; 'no answer' }
--   chests (inside a vault, its name in $vault; only the WorldChest actors loaded near him are read):
--     $vault = 'Skeklac Kara'; . tools\client_lib.ps1; $src = Get-Content -Raw client_mod\commands\bestiary_tables_probe.lua; $f = "$env:TEMP\bestiary_probe_run.lua"; $n = 'bestiary_probe_chests_' + ($vault -replace '\W', ''); [IO.File]::WriteAllText($f, "local ARGS = { only = 'chests', vault = '$vault' }`n" + $src); $r = Invoke-ClientCmd -Path $f -Name $n -TimeoutS 30; if ($r) { $r.result.counts; $r.result.unread } else { Clear-ClientCmd $n; 'no answer' }
-- Merge (the earlier full run first: a later file's group replaces that group only, attack slices add up):
--   $p = @('data\bestiary_probe_20261117.json') + (Get-ChildItem client_io\out\bestiary_probe_*.json | ForEach-Object FullName); .venv\Scripts\python.exe -m tools.build_bestiary build ($p | ForEach-Object { '--from-probe', $_ })
return function(log)
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    local A = (type(ARGS) == "table" and ARGS) or {}
    local MAX_ROWS = tonumber(A.max_rows) or 4000     -- rows per table
    local MAX_TOTAL = tonumber(A.max_total) or 40000  -- FindRow calls in all
    local MAX_S = tonumber(A.max_s) or 5              -- seconds for this call (one group per call: ARGS.only)
    local WALK_S = math.min(tonumber(A.walk_s) or MAX_S * 0.6, MAX_S)  -- the registry walk stops here, so its reads run
    local START = math.max(1, math.floor(tonumber(A.start) or 1))     -- registry paths START .. START+LIMIT-1
    local LIMIT = math.max(1, math.floor(tonumber(A.limit) or 100))
    local MAX_ARR = 64                                -- elements per inner array
    local MAX_JOURNAL, MAX_ATTACKS, MAX_CHESTS, MAX_PATHS = 800, 1500, 64, 4000
    local try, valid = U.try, U.valid
    local function s(v)
        local x = U.str(v)
        if type(x) == "string" and x ~= "" and x ~= "None" then return x end
        return nil
    end
    local function n(v) return type(v) == "number" and v or nil end
    local function b(v) return v == true or nil end
    -- the groups this call runs (ARGS.only: a name, a list, or "a, b"); the rest are not touched and not reported
    local GROUPS = { "journal", "attack_damage", "ai_data", "attacks", "enemy_loot", "chests" }
    local wanted
    if A.only ~= nil then
        local known, list = {}, {}
        for _, g in ipairs(GROUPS) do known[g] = true end
        if type(A.only) == "table" then for _, g in ipairs(A.only) do list[#list + 1] = tostring(g) end
        else for g in tostring(A.only):gmatch("[^,%s]+") do list[#list + 1] = g end end
        wanted = {}
        for _, g in ipairs(list) do
            if not known[g] then error("bestiary_tables_probe: unknown group '" .. g .. "' in ARGS.only (groups: " .. table.concat(GROUPS, ", ") .. ")") end
            wanted[g] = true
        end
        if not next(wanted) then error("bestiary_tables_probe: ARGS.only names no group (groups: " .. table.concat(GROUPS, ", ") .. ")") end
    end
    local function want(g) return wanted == nil or wanted[g] == true end
    local t0 = os.clock()
    local function over() return os.clock() - t0 > MAX_S end
    local total = 0
    local out = { probe = "bestiary_tables_probe", version = 2, vault = A.vault, groups = {},
                  caps = { max_rows = MAX_ROWS, max_total = MAX_TOTAL, max_s = MAX_S, max_array = MAX_ARR, walk_s = WALK_S,
                           start = START, limit = LIMIT },
                  sections = {}, unread = {}, unread_by_group = {}, truncated = {} }
    for _, g in ipairs(GROUPS) do if want(g) then out.groups[#out.groups + 1] = g end end
    out.only = wanted and out.groups or nil
    local group = "other"  -- the group of the running section: unread lines are filed under it
    local function say(msg) pcall(log, "[bestiary_probe] " .. msg) end
    local function unread(what, why)
        local line = what .. ": " .. why
        out.unread[#out.unread + 1] = line
        local l = out.unread_by_group[group]
        if not l then l = {}; out.unread_by_group[group] = l end
        l[#l + 1] = line
        say("could not read " .. line)
    end
    local function truncated(what) out.truncated[#out.truncated + 1] = what; say("truncated " .. what) end
    local function section(name, fn)
        group = name:match("^[^:]+")
        if over() then out.sections[name] = { ok = false, skipped = true }; unread(name, "time cap reached before it started"); return end
        local ts = os.clock()
        local ok, err = pcall(fn)
        out.sections[name] = { ok = ok, seconds = math.floor((os.clock() - ts) * 1000) / 1000 }
        if not ok then out.sections[name].error = tostring(err); unread(name, "error " .. tostring(err)) end
    end
    local function find_row(dt, rn)
        if not (dt and rn) or total >= MAX_TOTAL then return nil end
        total = total + 1
        local ok, row = pcall(function() return dt:FindRow(rn) end)
        if ok then return row end
        return nil
    end
    local function each(arr, fn, cap) U.each(arr, fn, cap or MAX_ARR) end
    local function tags(container)
        local list = {}
        each(try(function() return container.GameplayTags end), function(g)
            local x = s(try(function() return g.TagName end)); if x then list[#list + 1] = x end
        end)
        return list
    end
    local function short_class(c) return valid(c) and (U.short(c) or s(try(function() return c:GetFName() end))) or nil end
    local function item_of(d)
        if not valid(d) then return nil end
        return U.short(d), s(try(function() return d.Name end))
    end
    -- an FDataTableRowHandle -> { table, row }, and the handle's own DataTable (nil when not loaded)
    local function handle_of(h)
        if h == nil then return nil end
        local rn = s(try(function() return h.RowName end))
        if not rn then return nil end
        local dt = try(function() return h.DataTable end)
        local r = { row = rn }
        if valid(dt) then r.table = s(try(function() return dt:GetFName() end)); return r, dt end
        r.table_loaded = false
        return r, nil
    end
    local function resources(arr)
        local list = {}
        each(arr, function(r)
            local id, name = item_of(try(function() return r.SpawnedItemData end))
            list[#list + 1] = { item = id, item_name = name,
                                min = n(try(function() return r.MinimumDropAmount end)),
                                max = n(try(function() return r.MaximumDropAmount end)),
                                chance = n(try(function() return r.DropChance end)),
                                per_player = b(try(function() return r.bOneInstancePerPlayerOnlyVisibleToThem end)),
                                to_inventory = b(try(function() return r.bAutoAddToInventory end)),
                                damagers_only = b(try(function() return r.bOnlyForPlayersThatInflictedDamage end)) }
        end)
        return list
    end
    -- every row of one table, FindRow'd by name (the food_values_probe pattern); read_row(row) -> a value
    local function read_table(label, path, read_row)
        local dt = U.find_object(path)
        if not dt then unread(label, "table not loaded (" .. path .. ")"); return nil end
        local t = { path = path, rows = {} }
        t.row_struct = s(try(function() return dt:GetRowStruct():GetFName() end))
        local names = {}
        local okf, errf = pcall(function()
            dt:ForEachRow(function(name, _)
                if #names >= MAX_ROWS then return true end
                names[#names + 1] = s(name) or tostring(name)
            end)
        end)
        if not okf or #names == 0 then
            local rn = try(function() return dt:GetRowNames() end)
            if type(rn) == "table" then for _, x in ipairs(rn) do if #names < MAX_ROWS then names[#names + 1] = s(x) or tostring(x) end end end
            if not okf and #names == 0 then unread(label, "ForEachRow failed: " .. tostring(errf)) end
        end
        t.enumerated = #names
        if #names >= MAX_ROWS then truncated(label .. ": row cap " .. MAX_ROWS) end
        local read, failed = 0, 0
        for _, name in ipairs(names) do
            if over() or total >= MAX_TOTAL then t.partial = true; unread(label, "cap reached after " .. read .. " rows"); break end
            local row = find_row(dt, name)
            local ok, v = false, nil
            if row ~= nil then ok, v = pcall(read_row, row, name) end
            if ok and v ~= nil then t.rows[name] = v; read = read + 1 else failed = failed + 1 end
        end
        t.read, t.failed = read, failed
        if failed > 0 then unread(label, failed .. " rows did not read") end
        return t
    end

    -- 1. the journal (lowest risk: the reads combat.lua _journal_weaknesses makes live)
    if want("journal") then section("journal", function()
        local list = U.find_all("JournalEntryWorldData", { skip_defaults = true })
        local j = { found = #list, with_weaknesses = 0, entries = {} }
        for i, e in ipairs(list) do
            if i > MAX_JOURNAL then truncated("journal: entry cap " .. MAX_JOURNAL); break end
            if over() then unread("journal", "time cap after " .. (i - 1) .. " entries"); break end
            local r = { asset = U.short(e), name = s(try(function() return e.DisplayName end)),
                        power_level = n(try(function() return e.PowerLevel end)), weaknesses = {}, locations = {}, materials = {} }
            each(try(function() return e.Weaknesses end), function(t) local x = s(t); if x then r.weaknesses[#r.weaknesses + 1] = x end end)
            each(try(function() return e.Locations end), function(l)
                local x = s(try(function() return l.LocationText end)) or s(try(function() return l.LocationID end))
                if x then r.locations[#r.locations + 1] = x end
            end)
            each(try(function() return e.Materials end), function(m)
                local id, name = item_of(try(function() return m.MaterialItemData end))
                local x = name or id or s(try(function() return m.MaterialID end))
                if x then r.materials[#r.materials + 1] = x end
            end)
            r.ai_data = s(try(function() return e.UnlockCondition.AIData:GetObjectID():GetAssetPathName() end))
            if #r.weaknesses > 0 then j.with_weaknesses = j.with_weaknesses + 1 end
            j.entries[#j.entries + 1] = r
        end
        out.journal = j
    end) end

    -- 2. attack damage and AI health tables, each in its own pcall
    local DMG = {
        DT_AIAttackDamage_BG = "/Game/Gameplay/AI/DT_AIAttackDamage_BG.DT_AIAttackDamage_BG",
        DT_AIAttackDamage_Fellhollow = "/FutureMajorVersion/Gameplay/AI/DT_AIAttackDamage_Fellhollow.DT_AIAttackDamage_Fellhollow",
        DT_AIAttackDamage_DowdunReach = "/DowdunReach/Gameplay/AI/DT_AIAttackDamage_DowdunReach.DT_AIAttackDamage_DowdunReach",
    }
    if want("attack_damage") then out.attack_damage = {} end
    for key, path in pairs(want("attack_damage") and DMG or {}) do
        section("attack_damage:" .. key, function()
            out.attack_damage[key] = read_table(key, path, function(row) return n(row.Damage) end)
        end)
    end
    local AID = {
        DT_AIData_BG = "/Game/Gameplay/AI/DT_AIData_BG.DT_AIData_BG",
        DT_AIData_UmbralSands = "/UmbralSands/Gameplay/AI/DT_AIData_UmbralSands.DT_AIData_UmbralSands",
    }
    if want("ai_data") then out.ai_data = {} end
    for key, path in pairs(want("ai_data") and AID or {}) do
        section("ai_data:" .. key, function()
            out.ai_data[key] = read_table(key, path, function(row) return n(row.MaxHealth) end)
        end)
    end

    -- 3. attack definitions: the registry's class list, then each LOADED class's default object. The walk over the
    -- registry (one StaticFindObject per path, about 520 paths: 7.9 s live and unfinished) takes the slice START ..
    -- START+LIMIT-1 of the sorted list and at most WALK_S of the call; result.attacks.walk.next is where the next call starts.
    local classes, cdos = {}, {}  -- path -> true; asset -> cdo
    if want("attacks") then
    out.attacks = { registry = {}, loaded = {} }
    section("attacks:registry", function()
        local regs = U.find_all("AIActionAttackRegistry", { skip_defaults = true })
        if #regs == 0 then unread("attacks:registry", "no AIActionAttackRegistry instance loaded"); return end
        local paths = {}
        U.each(try(function() return regs[1].Attacks end), function(sp)
            local p = s(try(function() return sp:GetObjectID():GetAssetPathName() end))
            if p and not classes[p] then classes[p] = true; paths[#paths + 1] = p end
        end, MAX_PATHS)
        if #paths >= MAX_PATHS then truncated("attacks:registry: path cap " .. MAX_PATHS) end
        table.sort(paths)
        out.attacks.registry = { instances = #regs, n = #paths, paths = paths }
    end)
    section("attacks:find", function()
        local nl = 0
        local paths = out.attacks.registry.paths or {}
        local np = #paths
        local w = { start = START, limit = LIMIT, n = np, walked = 0 }
        out.attacks.walk = w
        if START > np and np > 0 then unread("attacks:find", "start " .. START .. " is past the registry's " .. np .. " paths") end
        local last = math.min(np, START + LIMIT - 1)
        local tw = os.clock()
        for i = START, last do
            if os.clock() - t0 > WALK_S then
                w.capped, w.next = true, i
                unread("attacks:find", "time cap in the registry walk at path " .. i .. " of " .. np .. " (resume with start = " .. i .. ")")
                break
            end
            local p = paths[i]
            w.walked, w.stop = w.walked + 1, i
            local cls = U.find_object(p)  -- loaded only; StaticFindObject never loads
            local cdo = cls and try(function() return cls:GetCDO() end)
            if valid(cdo) then
                local asset = (U.short(cdo) or ""):gsub("^Default__", ""):gsub("_C$", "")
                if asset ~= "" and not cdos[asset] then cdos[asset] = { cdo = cdo, path = p }; nl = nl + 1 end
            end
        end
        if not w.capped and last < np then w.next = last + 1 end
        w.seconds = math.floor((os.clock() - tw) * 1000) / 1000
        if w.walked > 0 then w.ms_per_path = math.floor(w.seconds * 1000 / w.walked * 10) / 10 end
        -- attack defaults that FindAllOf lists (it may include loaded classes the registry does not name): first slice only
        if START == 1 then
            for _, o in ipairs(U.find_all("AiAttackData")) do
                local full = U.fullname(o) or ""
                local asset = full:match("Default__(ATK_[%w_]-)_C$")
                if asset and not cdos[asset] then cdos[asset] = { cdo = o, path = U.path_of(o) }; nl = nl + 1 end
            end
        end
        out.attacks.loaded_n = nl
        if nl == 0 then
            unread("attacks", "no ATK_* class loaded" .. (w.walked > 0 and (" in registry paths " .. START .. ".." .. w.stop) or "")
                .. " (no creature of theirs spawned near him yet)")
        end
    end)
    section("attacks:read", function()
        local names = {}
        for asset in pairs(cdos) do names[#names + 1] = asset end
        table.sort(names)
        for i, asset in ipairs(names) do
            if i > MAX_ATTACKS then truncated("attacks: cap " .. MAX_ATTACKS); break end
            if over() then unread("attacks:read", "time cap after " .. (i - 1) .. " attacks"); break end
            local c = cdos[asset].cdo
            local ok, rec = pcall(function()
                local r = { path = cdos[asset].path, hits = {} }
                local flags = n(U.prop(c, "AttackPropertyFlags"))
                if flags then
                    r.flags = flags
                    r.unblockable = (flags & 1) ~= 0 or nil
                    r.unparryable = (flags & 2) ~= 0 or nil
                    r.special = (flags & 4) ~= 0 or nil
                    r.finisher = (flags & 8) ~= 0 or nil
                    r.force_blast = (flags & 16) ~= 0 or nil
                end
                r.type = s(try(function() return U.prop(c, "AiAttackType").TagName end))
                r.collateral = b(U.prop(c, "bCanDoCollateralDamage"))
                r.multi_hit = b(U.prop(c, "bAllowMultipleHits"))
                r.effects_if_blocked = b(U.prop(c, "bApplyGEsIfBlocked"))
                r.next = short_class(U.prop(c, "NextAttack"))
                r.effects = {}
                each(U.prop(c, "GameplayEffects"), function(ge) local x = short_class(ge); if x then r.effects[#r.effects + 1] = x end end)
                local nsp = 0
                each(U.prop(c, "Spawns"), function() nsp = nsp + 1 end)
                r.spawns = nsp > 0 and nsp or nil
                each(U.prop(c, "Damage"), function(d)
                    local h = { time = n(try(function() return d.Time end)), force = n(try(function() return d.Force end)),
                                damage_class = n(try(function() return d.DamageClass end)),
                                direction = n(try(function() return d.Directionality end)),
                                types = tags(try(function() return d.Types end)) }
                    local hr, dt = handle_of(try(function() return d.DamageDataTableRowHandle end))
                    if hr then
                        h.table, h.row = hr.table, hr.row
                        local row = find_row(dt, hr.row)
                        h.damage = row ~= nil and n(try(function() return row.Damage end)) or nil
                        if hr.table_loaded == false then h.table_loaded = false end
                    end
                    r.hits[#r.hits + 1] = h
                end)
                return r
            end)
            if ok then out.attacks.loaded[asset] = rec else unread("attack " .. asset, tostring(rec)) end
        end
    end)
    end

    -- 4. creature drop tables, each table in its own pcall; drop rows FindRow'd through each handle's own table
    if want("enemy_loot") then out.enemy_loot, out.loot_rows = {}, {} end
    local LOOT = {
        DT_EnemyLootDropTable = "/Game/Gameplay/Items/LootDropTables/DT_EnemyLootDropTable.DT_EnemyLootDropTable",
        DT_EnemyLootDropTable_DowdunReach = "/DowdunReach/Gameplay/Items/LootDropTables/DT_EnemyLootDropTable_DowdunReach.DT_EnemyLootDropTable_DowdunReach",
        DT_CompositeEnemyLootDropTable = "/Game/Gameplay/Items/LootDropTables/DT_CompositeEnemyLootDropTable.DT_CompositeEnemyLootDropTable",
    }
    local function drop_row(hr, dt)
        local key = (hr.table or "?") .. ":" .. hr.row
        if out.loot_rows[key] ~= nil then return key end
        local row = find_row(dt, hr.row)
        if row == nil then
            out.loot_rows[key] = false
            unread("loot row " .. key, dt and "FindRow found nothing" or "its table is not loaded")
            return key
        end
        local r = { drop_chance = n(try(function() return row.DropChance end)), conditions = {} }
        each(try(function() return row.Conditions end), function(c)
            local v = n(c); r.conditions[#r.conditions + 1] = ({ [0] = "day", [1] = "night" })[v] or v
        end)
        r.items = resources(try(function() return row.Resources end))
        r.recipes = {}
        each(try(function() return row.Recipes end), function(g)
            local rd = try(function() return g.GrantedRecipe end)
            r.recipes[#r.recipes + 1] = { recipe = valid(rd) and U.short(rd) or nil, chance = n(try(function() return g.DropChance end)) }
        end)
        out.loot_rows[key] = r
        return key
    end
    for key, path in pairs(want("enemy_loot") and LOOT or {}) do
        section("enemy_loot:" .. key, function()
            out.enemy_loot[key] = read_table(key, path, function(row)
                local levels = {}
                each(row.TablesByPowerLevel, function(lv)
                    local l = { min_power_level = n(try(function() return lv.MinimumPowerLevel end)), drops = {} }
                    each(try(function() return lv.TableHandles end), function(h)
                        local hr, dt = handle_of(h)
                        if hr then l.drops[#l.drops + 1] = drop_row(hr, dt) end
                    end)
                    levels[#levels + 1] = l
                end)
                return levels
            end)
        end)
    end

    -- 5. vault chests: only the WorldChest actors loaded near him
    if want("chests") then section("chests", function()
        local list = U.find_all("WorldChest", { skip_defaults = true })
        local res = { found = #list, actors = {} }
        if #list == 0 then unread("chests", "no WorldChest actor loaded near him (run it inside a vault)") end
        local sets = {}
        local function item_set(hr, dt)
            local key = (hr.table or "?") .. ":" .. hr.row
            if sets[key] == nil then
                local row = find_row(dt, hr.row)
                sets[key] = row ~= nil and resources(try(function() return row.SpawnableItems end)) or false
                if row == nil then unread("item set " .. key, dt and "FindRow found nothing" or "its table is not loaded") end
            end
            return { set = key, items = sets[key] or nil }
        end
        for i, ch in ipairs(list) do
            if i > MAX_CHESTS then truncated("chests: cap " .. MAX_CHESTS); break end
            if over() then unread("chests", "time cap after " .. (i - 1) .. " chests"); break end
            local ok, rec = pcall(function()
                local loc = U.loc(ch)
                local r = { id = U.short(ch), class = U.class_word(ch), vault = A.vault,
                            pos_m = loc and { math.floor(loc.X) / 100, math.floor(loc.Y) / 100, math.floor(loc.Z) / 100 } or nil,
                            state = n(U.prop(ch, "ChestState")), respawn_disabled = b(U.prop(ch, "bRespawnDisabled")) }
                local pr, pdt = handle_of(U.prop(ch, "ChestRespawnProfile"))
                r.profile = pr
                if not pr then r.unread = "no ChestRespawnProfile"; return r end
                local prow = find_row(pdt, pr.row)
                if prow == nil then r.unread = pdt and "profile row not found" or "profile table not loaded on the client"; return r end
                r.respawn = ({ [0] = "never", [1] = "on_opened", [2] = "on_emptied" })[n(try(function() return prow.RespawnTrigger end)) or -1]
                local lr, ldt = handle_of(try(function() return prow.LootRollHandle end))
                r.roll = lr
                local roll = lr and find_row(ldt, lr.row)
                if roll == nil then r.unread = ldt and "loot roll row not found" or "loot roll table not loaded on the client"; return r end
                r.min_extra_rolls = n(try(function() return roll.MinAdditionalSetRolls end))
                r.max_extra_rolls = n(try(function() return roll.MaxAdditionalSetRolls end))
                r.guaranteed_items = resources(try(function() return roll.GuaranteedStandaloneItems end))
                r.guaranteed_sets, r.extra_sets = {}, {}
                each(try(function() return roll.GuaranteedItemSets end), function(h)
                    local hr, dt = handle_of(h); if hr then r.guaranteed_sets[#r.guaranteed_sets + 1] = item_set(hr, dt) end
                end)
                each(try(function() return roll.AdditionalItemSets end), function(a)
                    local hr, dt = handle_of(try(function() return a.LootItemSetHandle end))
                    if hr then
                        local x = item_set(hr, dt); x.chance = n(try(function() return a.DropChance end))
                        r.extra_sets[#r.extra_sets + 1] = x
                    end
                end)
                return r
            end)
            if ok then res.actors[#res.actors + 1] = rec else unread("chest " .. tostring(i), tostring(rec)) end
            if ok and rec.unread then unread("chest " .. tostring(rec.id), rec.unread) end
        end
        out.chests = res
    end) end

    out.rows_read = total
    out.seconds = math.floor((os.clock() - t0) * 1000) / 1000
    local na = 0
    for _ in pairs(out.attacks and out.attacks.loaded or {}) do na = na + 1 end
    out.counts = { journal = out.journal and #out.journal.entries or 0,
                   journal_with_weaknesses = out.journal and out.journal.with_weaknesses or 0,
                   attacks_listed = out.attacks and out.attacks.registry.n or 0, attacks_loaded = na,
                   chests = out.chests and #out.chests.actors or 0, unread = #out.unread }
    say(string.format("done in %.2f s (%s): %d journal entries (%d with weaknesses), %d attacks loaded of %d listed, %d chests, %d rows, %d unread",
        out.seconds, table.concat(out.groups, ","), out.counts.journal, out.counts.journal_with_weaknesses, na, out.counts.attacks_listed, out.counts.chests,
        total, #out.unread))
    return out
end
