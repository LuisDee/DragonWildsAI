-- Gather probe (docs/research/2026-10-25-woodcutting-loop.md W0/W2/W3, docs/research/2026-10-25-mining.md).
-- debug_run {module="gather_probe", args={action=..., ...}}
--   census  {radius_m=40, center="puppet"|"player"}  READ-ONLY: trees, stumps, felled trees, logs,
--           world items, mining rocks, ore nodes near the centre (class, hp, tier gate, drops), the
--           puppet's held item and ItemMagnet. Default action.
--   convert {radius_m=15}   ConvertFoliageNearbyLocation(world, puppet, r, true, false, puppet): turns
--           tree foliage instances near the puppet into AFellableTree actors (W2). Simple args only.
--   swing   {target=<short actor name>, kind="chop"|"overhead"|"mine", approach=true}
--           ONE BP_PerformAttack with the held tool's chain at the target; logs the target's health
--           now and 1.5 s / 3 s later (W3/W5). Needs a tool in hand (bridge equip).
--   magnet  {}  read the puppet's BP_Components_ItemMagnet (MagnetRange, active).
-- Every state-changing native call goes through U.call (breadcrumb first).
local U = require("body.util")
local M = {}

local function each(arr, fn, cap)
    if arr == nil then return 0 end
    local n = tonumber(U.try(function() return arr:GetArrayNum() end)) or tonumber(U.try(function() return #arr end))
    if not n or n <= 0 then return 0 end
    local count = 0
    pcall(function()
        arr:ForEach(function(_, e)
            count = count + 1
            if count > (cap or 64) then return true end
            local v = U.try(function() return e:get() end)
            fn(v == nil and e or v)
        end)
    end)
    return count
end

local function softpath(sp)
    if sp == nil then return nil end
    local p = U.str(U.try(function() return sp:GetObjectID():GetAssetPathName() end))
    if p and p ~= "" and p ~= "None" then return p end
    local loaded = U.try(function() return sp:GetWeakPtr():Get() end)
    if U.valid(loaded) then return U.path_of(loaded) end
    return U.str(U.try(function() return sp:ToString() end))
end

local function drops(comp)
    local out = {}
    if not U.valid(comp) then return out end
    each(U.try(function() return comp.ItemsToDrop end), function(d)
        out[#out + 1] = {
            item = softpath(U.try(function() return d.ItemDataClass end)),
            min = U.try(function() return d.MinToDrop end), max = U.try(function() return d.MaxToDrop end),
            group = U.try(function() return d.MaximumGrouping end), p = U.try(function() return d.ProbabilityOfDrop end),
        }
    end)
    return out
end

local function modifiers(arr)
    local out = {}
    each(arr, function(m)
        if U.valid(m) then
            out[#out + 1] = { mod = U.short(m), cls = U.class_word(m), tier = U.try(function() return m.RequiredTier end),
                              cat = U.str(U.try(function() return m.RequiredCategory.TagName end)) }
        end
    end)
    return out
end

local function center_of(args)
    local _, puppets = U.split_pawns()
    local players = U.split_pawns()
    local p = puppets[1]
    if args.center == "player" then return U.loc(players[1]), p end
    return U.loc(p) or U.loc(players[1]), p
end

local CLASSES = { "FellableTree", "FelledTree", "SplittableTreeLog", "TreeLog", "RuntimeSpawnedWorldItem",
                  "DestructibleMiningRock", "OreNode", "DivineRock", "ResourceRespawnComponent" }

local function describe(cls, a, d)
    local r = { id = U.short(a), class = U.class_word(a), dist_m = U.cm_to_m(d), pos = U.to_wire(U.loc(a)) }
    r.hp = U.health(a)
    r.max_hp = U.try(function() return a.HealthComponent.MaxHealth end)
    if cls == "FellableTree" then
        r.stump = U.try(function() return a.bIsStump end)
        r.split_frac = U.try(function() return a.SplitDamageFraction end)
        r.mods_tree = modifiers(U.try(function() return a.DamageModifiersWhenTree end))
        r.mods_stump = modifiers(U.try(function() return a.DamageModifiersWhenStump end))
        r.drops = drops(U.try(function() return a.ItemDropOnDestructionComponent end))
    elseif cls == "TreeLog" or cls == "SplittableTreeLog" then
        r.item = U.path_of(U.try(function() return a.PrimaryAssociatedItemData end))
        r.mods = modifiers(U.try(function() return a.DamageComponent.DamageModifiers end))
        r.can_take = U.try(function() return a.DamageComponent.bCanTakeDamage end)
        r.drops = drops(U.try(function() return a.ItemDropOnDestructionComponent end))
        local mid = {}
        local okm = pcall(function() a:GetMidPointWorldLocation(mid) end)
        r.mid = okm and mid.X and U.to_wire(mid) or nil
        r.height = U.try(function() return a:GetLogHeight() end)
        r.log_type = U.try(function() return a:GetLogType() end)
    elseif cls == "RuntimeSpawnedWorldItem" then
        r.item = U.path_of(U.try(function() return a.ItemData end))
        r.stack = U.try(function() return a:GetStackSize() end)
    elseif cls == "DestructibleMiningRock" or cls == "DivineRock" then
        r.drops = drops(U.try(function() return a.ItemDropOnDestructionComponent end))
        r.mods = modifiers(U.try(function() return a.DamageComponent.DamageModifiers end))
        r.destroy_on_zero = U.try(function() return a.bDestroyActorOnZeroHealth end)
        r.respawn_avail = U.try(function() return a.RespawnComponent:GetQuantityAvailable() end)
        r.respawn_max = U.try(function() return a.RespawnComponent:GetMaxResources() end)
    elseif cls == "OreNode" then
        r.node_health = U.try(function() return a.NodeHealth end)
        r.has_resources = U.try(function() return a:HasAvailableResources() end)
        r.tag = U.str(U.try(function() return a.ResourceTag.TagName end))
        r.max_spawns = U.try(function() return a.MaxPopulatedSpawns end)
        r.populated = tonumber(U.try(function() return a.PopulatedSpawnComponents:GetArrayNum() end))
        r.empty = tonumber(U.try(function() return a.EmptySpawnComponents:GetArrayNum() end))
        r.drops = drops(U.try(function() return a.ItemDropComponent end))
        r.mods = modifiers(U.try(function() return a.DamageComponent.DamageModifiers end))
        r.respawn_avail = U.try(function() return a.RespawnComponent:GetQuantityAvailable() end)
        r.respawn_max = U.try(function() return a.RespawnComponent:GetMaxResources() end)
    end
    return r
end

function M.census(log, args)
    local center, p = center_of(args)
    if not center then return { ok = false, err = "no puppet or player" } end
    local radius = (args.radius_m or 40) * 100
    local out = { center = U.to_wire(center), counts = {}, near = {} }
    for _, cls in ipairs(CLASSES) do
        local all = U.find_all(cls, { skip_defaults = true })
        local near = {}
        for _, a in ipairs(all) do
            local at = cls == "ResourceRespawnComponent" and U.loc(U.try(function() return a:GetOwner() end)) or U.loc(a)
            local d = U.dist(center, at)
            if d <= radius then near[#near + 1] = { a = a, d = d } end
        end
        table.sort(near, function(x, y) return x.d < y.d end)
        out.counts[cls] = { all = #all, near = #near }
        if cls == "ResourceRespawnComponent" then
            local owners = {}
            for _, n in ipairs(near) do
                local o = U.try(function() return n.a:GetOwner() end)
                local w = U.class_word(o) or "?"
                owners[w] = (owners[w] or 0) + 1
            end
            out.respawn_owner_classes = owners
        else
            local list = {}
            for i = 1, math.min(#near, args.max or 6) do list[#list + 1] = describe(cls, near[i].a, near[i].d) end
            out.near[cls] = list
        end
    end
    local fol = U.find_all("BP_InteractableFoliageISMC_Tree_C", { skip_defaults = true })
    local meshes = {}
    for _, c in ipairs(fol) do
        local n = (U.short(c) or "?"):gsub("_%d+$", "")
        meshes[n] = (meshes[n] or 0) + (tonumber(U.try(function() return c:GetInstanceCount() end)) or 0)
    end
    out.foliage_tree_instances = meshes
    if p then
        local eq = U.try(function() return p.PlayerEquipmentComponent end)
        local h = U.try(function() return eq.HeldEquipmentActorRight end)
        out.held = U.valid(h) and U.path_of(U.try(function() return h.HeldEquipmentData end)) or nil
        out.puppet = U.short(p)
    end
    log.event("gather_probe_census", out)
    return out
end

function M.magnet(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not p then return { ok = false, err = "no puppet" } end
    local m = U.try(function() return p.BP_Components_ItemMagnet end)
    local r = { comp = U.fullname(m), range = U.try(function() return m.MagnetRange end),
                active = U.try(function() return m:IsActive() end) }
    log.event("gather_probe_magnet", r)
    return r
end

function M.convert(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not p then return { ok = false, err = "no puppet" } end
    local lib = U.find_object("/Script/Dominion.Default__InteractableFoliageFunctionLibrary")
    if not lib then return { ok = false, err = "no foliage library CDO" } end
    local before = #U.find_all("FellableTree", { skip_defaults = true })
    local at = U.loc(p)
    local r = (args.radius_m or 15) * 100
    local t0 = os.clock()
    local ok, err = U.call(log, "gather_probe.ConvertFoliageNearbyLocation", { at = U.to_wire(at), r = r }, function()
        lib:ConvertFoliageNearbyLocation(p, at, r, true, false, p)
    end)
    local after = #U.find_all("FellableTree", { skip_defaults = true })
    return { ok = ok, err = err and tostring(err), trees_before = before, trees_after = after,
             ms = math.floor((os.clock() - t0) * 1000) }
end

local SETS = {
    chop = { "/Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut1.BP_Player_Axe_Woodcut1_C",
             "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet.Default__PA_Attack_Hatchet_C" },
    overhead = { "/Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut2.BP_Player_Axe_Woodcut2_C",
                 "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet_Special.Default__PA_Attack_Hatchet_Special_C" },
    mine = { "/Game/Gameplay/Character/Player/Attacks/Pickaxe/BP_Player_Pickaxe_Mine1.BP_Player_Pickaxe_Mine1_C",
             "/Game/Gameplay/Character/Player/Attacks/Pickaxe/PA_Attack_Pickaxe.Default__PA_Attack_Pickaxe_C" },
}

local function find_by_short(name)
    for _, cls in ipairs(CLASSES) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            if U.short(a) == name then return a end
        end
    end
end

function M.swing(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not p then return { ok = false, err = "no puppet" } end
    if args.convert_m then M.convert(log, { radius_m = args.convert_m }) end
    local t = find_by_short(args.target)
    if not t and args.nearest then -- nearest actor whose class contains args.nearest
        local best, bd
        for _, cls in ipairs(CLASSES) do
            for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
                if (U.class_word(a) or ""):find(args.nearest, 1, true) and (args.cls == nil or args.cls == cls) then
                    local d = U.actor_dist(p, a)
                    if (not bd or d < bd) and not (cls == "FellableTree" and args.skip_stumps and U.try(function() return a.bIsStump end)) then
                        best, bd = a, d
                    end
                end
            end
        end
        t = best
    end
    if not t then return { ok = false, err = "no such target", target = args.target } end
    args.target = U.short(t)
    local tl = U.loc(t)
    if tl and args.face ~= false then
        local pl = U.loc(p)
        local yaw = math.deg(math.atan(tl.Y - pl.Y, tl.X - pl.X))
        U.call(log, "gather_probe.K2_SetActorRotation", { yaw = yaw }, function()
            p:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        end)
    end
    local set = SETS[args.kind or "chop"]
    local atk, act = U.find_object(set[1]), U.find_object(set[2])
    if not (atk and act) then return { ok = false, err = "attack set not loaded" } end
    local c = U.controller_of(p)
    if c then U.call(log, "gather_probe.K2_SetFocus", {}, function() c:K2_SetFocus(t) end) end
    local hp0 = U.health(t)
    local ok, err = U.call(log, "gather_probe.BP_PerformAttack", { target = args.target, kind = args.kind }, function()
        p.PlayerMeleeAttackComponent:BP_PerformAttack(atk, {
            Data = act, PlayerOwner = p, EquipmentHand = 1, ActionInputType = 0, DesiredActionTarget = t,
        })
    end)
    local function later(ms)
        ExecuteInGameThreadWithDelay(ms, function()
            local alive = U.alive(t)
            log.event("gather_probe_swing_after", { target = args.target, ms = ms, alive = alive,
                hp = alive and U.health(t) or nil, stump = alive and U.try(function() return t.bIsStump end) or nil })
        end)
    end
    later(1500); later(3000)
    -- emulated hit (args.damage): HealthComponent:DecreaseHealth at the swing's damage point.
    if args.damage then
        ExecuteInGameThreadWithDelay(args.dmg_ms or 550, function()
            if not U.alive(t) then return end
            local hc = U.try(function() return t.HealthComponent end)
            local before = U.health(t)
            local okd, errd = U.call(log, "gather_probe.DecreaseHealth", { target = args.target, amount = args.damage }, function()
                hc:DecreaseHealth(args.damage, "dw_gather")
            end)
            log.event("gather_probe_hit", { target = args.target, ok = okd, err = errd and tostring(errd), before = before,
                after = U.health(t), stump = U.try(function() return t.bIsStump end) })
        end)
    end
    return { ok = ok, err = err and tostring(err), hp_before = hp0, dist_m = U.cm_to_m(U.actor_dist(p, t)) }
end

-- approach {target|nearest, cls, accept_cm=80, convert_m}: MoveToActor on the resource actor.
function M.approach(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not p then return { ok = false, err = "no puppet" } end
    if args.convert_m then M.convert(log, { radius_m = args.convert_m }) end
    local t = find_by_short(args.target)
    if not t and args.nearest then
        local best, bd
        for _, a in ipairs(U.find_all(args.cls or "FellableTree", { skip_defaults = true })) do
            if (U.class_word(a) or ""):find(args.nearest, 1, true) and not U.try(function() return a.bIsStump end) then
                local d = U.actor_dist(p, a)
                if not bd or d < bd then best, bd = a, d end
            end
        end
        t = best
    end
    if not t then return { ok = false, err = "no target" } end
    local c = U.controller_of(p)
    local ok, res = U.call(log, "gather_probe.MoveToActor", { target = U.short(t) }, function()
        return c:MoveToActor(t, args.accept_cm or 80, true, true, true, nil, true)
    end)
    return { ok = ok, res = res, target = U.short(t), dist_m = U.cm_to_m(U.actor_dist(p, t)) }
end

function M.dist(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    local t = find_by_short(args.target)
    return { dist_m = U.cm_to_m(U.actor_dist(p, t)), dist2d_m = U.cm_to_m(U.dist2d(U.loc(p), U.loc(t))),
             hp = U.health(t), alive = U.alive(t), puppet = U.to_wire(U.loc(p)), target = U.to_wire(U.loc(t)) }
end

-- hook_dmg {}: log the tree/rock damage-modifier BP functions (once per run, _G flag). Read-only
-- callbacks. Shows whether a puppet swing reaches the resource's damage pipeline and which held
-- equipment the tier gate resolves.
local function pval(x)
    local v = U.try(function() return x:get() end)
    if v == nil then v = x end
    return v
end

function M.hook_dmg(log, args)
    _G.__dw_gather_dmg_hooks = _G.__dw_gather_dmg_hooks or {}
    local reg = _G.__dw_gather_dmg_hooks
    local cls = "/Game/Gameplay/DamageModifiers/BP_DamageModifier_SpecificWeapon.BP_DamageModifier_SpecificWeapon_C"
    -- resolve the real class path from a live modifier when possible
    for _, t in ipairs(U.find_all("FellableTree", { skip_defaults = true })) do
        local found
        each(U.try(function() return t.DamageModifiersWhenTree end), function(m)
            if not found and (U.class_word(m) or ""):find("SpecificWeapon", 1, true) then
                found = (U.class_name(m) or ""):match("^%S+%s+(.*)$")
            end
        end)
        if found then cls = found; break end
    end
    local out = { class = cls, registered = {} }
    local fns = args.fns or { "ModifyDamage", "GetHeldEquipmentThatInflictedDamage", "IsEquipmentOfSufficientTier",
                              "IsEquipmentCorrectCategory", "IsDamageCausedByUnarmedAttack" }
    for _, fn in ipairs(fns) do
        local path = cls .. ":" .. fn
        if not reg[path] then
            local function cb(phase) return function(ctx, a1, a2, a3)
                local d = { fn = fn, phase = phase, self = U.short(pval(ctx)) }
                pcall(function()
                    if fn == "ModifyDamage" then
                        d.in_amount = pval(a1)
                        local di = pval(a2)
                        d.amount = U.try(function() return di.Amount end)
                        d.instigator = U.short(U.try(function() return di.Instigator end))
                        d.source = U.fullname(U.try(function() return di.Source end))
                    elseif fn == "IsEquipmentOfSufficientTier" or fn == "IsEquipmentCorrectCategory" then
                        d.held = U.short(pval(a1))
                        d.result = pval(a2)
                    elseif fn == "GetHeldEquipmentThatInflictedDamage" then
                        local di = pval(a1)
                        d.source = U.fullname(U.try(function() return di.Source end))
                        d.held = U.short(pval(a2))
                    else
                        d.result = pval(a2)
                    end
                end)
                log.event("gather_probe_dmg", d)
            end end
            local ok, err = pcall(RegisterHook, path, cb("pre"), cb("post"))
            reg[path] = ok
            out.registered[fn] = ok and true or tostring(err)
        else
            out.registered[fn] = "already"
        end
    end
    log.event("gather_probe_hooks", out)
    return out
end

-- held {}: what the native getters say the puppet (and each player) holds. Read-only calls.
function M.held(log, args)
    local players, puppets = U.split_pawns()
    local out = {}
    local function one(p)
        local eq = U.try(function() return p.PlayerEquipmentComponent end)
        local h = U.try(function() return eq.HeldEquipmentActorRight end)
        return {
            pawn = U.short(p),
            prop_data = U.short(U.try(function() return h.HeldEquipmentData end)),
            prop_item = U.fullname(U.try(function() return h.HeldEquipmentItem end)),
            actor_get_data = U.short(U.try(function() return h:GetHeldEquipmentData() end)),
            actor_get_item = U.fullname(U.try(function() return h:GetHeldEquipmentItem() end)),
            comp_get_data_right = U.short(U.try(function() return eq:GetHeldEquipmentDataRight() end)),
            comp_category_right = U.str(U.try(function() return eq:GetRightHandEquipmentCategory().TagName end)),
            actor_id = U.try(function() return h.HeldEquipmentActorID end),
        }
    end
    for _, p in ipairs(puppets) do out[#out + 1] = one(p) end
    for _, p in ipairs(players) do out[#out + 1] = one(p) end
    log.event("gather_probe_held", { held = out })
    return out
end

function M.run(log, args)
    args = args or {}
    local fn = M[args.action or "census"]
    if type(fn) ~= "function" or args.action == "run" then return { ok = false, err = "unknown action" } end
    return fn(log, args)
end

return M
