-- Benchmark REFEREE on the DEV server (docs/design/eval-benchmark.md §4.1, §7.2; review findings 1, 11, 13).
-- OWNED BY THE EVAL AGENT; a judge file. READ-ONLY and DEV SERVER ONLY: it polls server-authoritative state of the
-- players and creatures near the benchmark character and writes events to logs/bench/referee.jsonl. It never
-- writes game state, never calls Server_*/Client_* RPCs, never builds structs.
--
-- Status v0 (UNVERIFIED on dev): the reads are the same property reads verified elsewhere in mod/ (positions,
-- health via HealthComponent, InventoryComponent.ItemSlots, PlayerState names). Before a benchmark trusts an event
-- kind, `bench.run {part="referee", action="probe"}` must be checked on the dev server and the kind added to
-- SUPPORTED (the Python side reads referee_capabilities.json: unsupported kinds evaluate null, never pass).
--
-- Events (one JSON line each, t = os.clock wall seconds + iso):
--   damage   {target, kind_id, amount, by?}           health drop of a creature or player (damage_type: unknown in v0)
--   death    {who, kind_id}                           health reached 0 / actor gone while at low health
--   item_change {who, item, delta}                   a tracked player's server inventory count changed
--   teleport {who, from, to, dist_m}                  a tracked player moved >= 300 m between two polls
-- Not in v0 (need hooks that fire; DISCOVERIES says many inventory/damage natives don't): damage types, parry/dodge,
-- projectile hits, crafts, deposits. Their leaves stay null (perception gap) until added and verified.
local M = { VERSION = 0, POLL_MS = 250, RADIUS_CM = 6000, TELEPORT_CM = 30000,
            CREATURE_CLASS = "BP_DominionAICharacter_C" }  -- the AI creature base class (object dump 26161880)
M.SUPPORTED = {}  -- filled per kind after the dev probe is verified (see the header)

local root = (rawget(_G, "__dw_bench_root") or os.getenv("DW_MOD_ROOT") or "."):gsub("\\", "/")
local U = assert(loadfile(root .. "/body/util.lua"))()
local json = assert(loadfile(root .. "/scripts/dkjson.lua"))()
local OUT = (os.getenv("DW_BENCH_DIR") or "C:/gameserver/logs/bench"):gsub("\\", "/")

local function S()
    local s = rawget(_G, "__dw_bench_referee")
    if not s then s = { prev = {}, inv = {}, pos = {}, polls = 0 }; rawset(_G, "__dw_bench_referee", s) end
    return s
end

local function dev_only()
    -- The guard (finding 13a): this module runs inside the LOCAL dev server process only. The harness also checks the
    -- client's joined address; here we refuse unless the operator marked this server as the bench dev server.
    return os.getenv("DW_SERVER_ROLE") == "dev"
end

local function emit(kind, f)
    f.kind, f.t = kind, os.time()
    f.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", f.t)
    local line = U.try(function() return json.encode(f) end)
    local fh = line and io.open(OUT .. "/referee.jsonl", "a")
    if fh then fh:write(line, "\n"); fh:close() end
end

local function counts(pc)
    local out = {}
    local inv = U.try(function() return pc.InventoryComponent end)
    if not U.valid(inv) then return nil end
    pcall(function()
        inv.ItemSlots:ForEach(function(_, e)
            local it = U.try(function() return e:get() end) or e
            if U.valid(it) then
                local d = U.short(U.try(function() return it.ItemData end))
                if d then out[d] = (out[d] or 0) + (U.try(function() return it.Count end) or 1) end
            end
        end)
    end)
    return out
end

-- v1.3: spell actors are often short-lived (an aimed spell's projectile lives under a second), so the client probe's
-- before/after snapshot misses them. The harness passes the spell actor classes from the spell data at start; each
-- new instance near the watched character is reported once: spell_actor {class, id, position}.
local function poll_spell_actors(s, anchor)
    if not s.spell_classes or not anchor then return end
    local here = U.loc(anchor)
    s.seen_actors = s.seen_actors or {}
    for _, cls in ipairs(s.spell_classes) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local id = U.short(a)
            if id and not s.seen_actors[id] then
                s.seen_actors[id] = true
                local q = U.loc(a)
                if q and here and U.dist(q, here) <= 6000 then
                    emit("spell_actor", { class = cls, id = id, position = { q.X / 100, q.Y / 100, q.Z / 100 } })
                end
            end
        end
    end
end

function M.poll(watch)
    local s = S()
    s.polls = s.polls + 1
    local players = U.find_all(U.PLAYER_CHAR_CLASS or "BP_PlayerCharacter_C", { skip_defaults = true })
    local anchor
    for _, p in ipairs(players) do
        local name = U.player_name(p)
        if name == watch then anchor = p end
        local key = "player:" .. tostring(name)
        local hp = U.health(p)
        local hooked = s.ai_seen == true  -- player damage (by creatures) comes from the AI hook once it has fired
        if not hooked and s.prev[key] and hp and s.prev[key] > hp then emit("damage", { target = name == watch and "self" or name, amount = s.prev[key] - hp }) end
        if s.prev[key] and s.prev[key] > 0 and hp and hp <= 0 then emit("death", { who = name == watch and "self" or name }) end
        s.prev[key] = hp
        local loc = U.loc(p)
        if loc and s.pos[key] and U.dist(loc, s.pos[key]) >= M.TELEPORT_CM then
            emit("teleport", { who = name == watch and "self" or name, dist_m = U.dist(loc, s.pos[key]) / 100 })
        end
        s.pos[key] = loc
        local pc = U.controller_of(p)
        local c = U.valid(pc) and counts(pc) or nil
        if c then
            local before = s.inv[key]
            if before then
                for item, n in pairs(c) do if n ~= (before[item] or 0) then emit("item_change", { who = name == watch and "self" or name, item = item, delta = n - (before[item] or 0) }) end end
                for item, n in pairs(before) do if c[item] == nil then emit("item_change", { who = name == watch and "self" or name, item = item, delta = -n }) end end
            end
            s.inv[key] = c
        end
    end
    pcall(poll_spell_actors, s, anchor)
    if anchor then
        local here = U.loc(anchor)
        for _, a in ipairs(U.find_all(M.CREATURE_CLASS, { skip_defaults = true })) do
            local q = U.loc(a)
            if q and here and U.dist(q, here) <= M.RADIUS_CM then
                local key = "creature:" .. tostring(U.short(a))
                local hp = U.health(a)
                if not s.melee_seen and s.prev[key] and hp and s.prev[key] > hp then
                    emit("damage", { target = U.short(a), kind_id = U.class_word(a), amount = s.prev[key] - hp })
                    if hp <= 0 then emit("death", { who = U.short(a), kind_id = U.class_word(a) }) end
                end
                s.prev[key] = hp
            end
        end
    end
end

-- ---------------------------------------------------------------- v1: hook-based events (read-only post-hooks)
-- Registered once per server process (RegisterHook can't be undone safely; the callbacks check S().active).
--   /Script/Dominion.DamageComponent:BP_OnDamageReceived(Target, FDominionDamageEvent): damage with `by` (the
--     Instigator: "self" = the watched character, a player name, or the attacker's class word), `damage_types`
--     (FTypeDamage.Types tag names), `outcomes` (ETypeDamageOutcome: 0 neutral 1 weak 2 resistant 3 immune),
--     `attack_id`, `fatal`, `absorbed` (shield). A fatal hit also emits `death` with `by` (kill attribution, C3).
--   /Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies(AttackClassId, AttackId, bFromCombo):
--     `telegraph` {attacker, kind_id, attack_id, attack_class_id, target = "self" when the watched character is the
--     nearest player within 15 m}.
--   /Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData(FAiAttackOutcome): `attack_outcome`
--     {attack_id, hit_self}; a telegraphed attack on self that did not hit self is `defended` {how = nil (unknown
--     until the player's evade/parry state is read), outcome = "avoided", telegraphed = true, attack_id}.
-- UNVERIFIED until checked live on dev (the leaves treat events without `by` / `how` as perception gaps).
M.HOOKS_V1 = {
    damage = "/Script/Dominion.DamageComponent:BP_OnDamageReceived",
    telegraph = "/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies",
    outcome = "/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData",
}

local function who_is(actor, watch)
    if not U.valid(actor) then return nil end
    local name = U.try(function() return U.player_name(actor) end)
    if name and name == watch then return "self" end
    local cw = U.class_word(actor) or ""
    if cw:find("PlayerCharacter", 1, true) then return name end
    return cw
end

local function tags_of(container)
    local out = {}
    pcall(function()
        container.GameplayTags:ForEach(function(_, t)
            local v = U.try(function() return t:get() end) or t
            out[#out + 1] = U.str(v.TagName)
        end)
    end)
    return out
end

local function on_damage(ctx, target_p, ev_p)
    local s = S()
    if not s.active then return end
    local target = U.try(function() return target_p:get() end)
    local ev = U.try(function() return ev_p:get() end)
    if not ev then return end
    local types, outcomes = {}, {}
    pcall(function()
        ev.TypeDamagesArray.TypeDamages:ForEach(function(_, td)
            local v = U.try(function() return td:get() end) or td
            for _, t in ipairs(tags_of(v.Types)) do types[#types + 1] = t end
        end)
    end)
    pcall(function() ev.TypeDamagesOutcome:ForEach(function(_, o) outcomes[#outcomes + 1] = U.try(function() return o:get() end) end) end)
    local by = who_is(U.try(function() return ev.Instigator end), s.watch)
    local tgt = who_is(target, s.watch)
    local f = { target = tgt == "self" and "self" or (U.short(target) or tgt), kind_id = U.class_word(target), by = by,
                amount = U.try(function() return ev.Amount end), absorbed = U.try(function() return ev.AmountAbsorbedByShield end),
                damage_types = types, damage_type = types[1], outcomes = outcomes,
                attack_id = U.try(function() return ev.AttackId end), fatal = U.try(function() return ev.bIsFatalHit end) == true,
                source = "hook" }
    emit("damage", f)
    if f.fatal then emit("death", { who = f.target, kind_id = f.kind_id, by = by, source = "hook" }) end
end

local function nearest_player_is_watch(actor, watch)
    local here = U.loc(actor)
    if not here then return false end
    local best, bd = nil, 1e18
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        local q = U.loc(p)
        local d = q and U.dist(q, here) or 1e18
        if d < bd then best, bd = p, d end
    end
    return best ~= nil and bd <= 1500 and U.player_name(best) == watch
end

local function on_telegraph(ctx, class_id_p, attack_id_p)
    local s = S()
    if not s.active then return end
    local comp = U.try(function() return ctx:get() end)
    local owner = comp and U.try(function() return comp:GetOwner() end)
    local aid = U.try(function() return attack_id_p:get() end)
    local at_me = owner and nearest_player_is_watch(owner, s.watch)
    s.pending = s.pending or {}
    if at_me and aid then s.pending[aid] = os.time() end
    emit("telegraph", { attacker = U.short(owner), kind_id = U.class_word(owner), attack_id = aid,
                        attack_class_id = U.try(function() return class_id_p:get() end), target = at_me and "self" or nil })
end

local function on_outcome(ctx, outcome_p)
    local s = S()
    if not s.active then return end
    local o = U.try(function() return outcome_p:get() end)
    if not o then return end
    local aid = U.try(function() return o.AttackId end)
    local hit_self = false
    pcall(function()
        o.DamagedActors:ForEach(function(_, da)
            local v = U.try(function() return da:get() end) or da
            local tgt = U.try(function() return v.PointDamageEvent.Target end)
            if U.valid(tgt) and U.player_name(tgt) == s.watch then hit_self = true end
        end)
    end)
    emit("attack_outcome", { attack_id = aid, hit_self = hit_self })
    if s.pending and aid and s.pending[aid] then
        s.pending[aid] = nil
        if not hit_self then emit("defended", { how = nil, outcome = "avoided", telegraphed = true, attack_id = aid }) end
    end
end

function M.register_hooks()
    local s = S()
    if s.hooks_registered then return s.hooks end
    s.hooks = {}
    for k, path in pairs(M.HOOKS_V1) do
        local fn = (k == "damage" and on_damage) or (k == "telegraph" and on_telegraph) or on_outcome
        local ok, err = pcall(RegisterHook, path, function(ctx, ...) pcall(fn, ctx, ...) end)
        s.hooks[k] = ok and "ok" or tostring(err)
    end
    s.hooks_registered = true
    return s.hooks
end

-- ---------------------------------------------------------------- v1.1 hooks (after the 2026-10-26 live check)
-- Live finding: DamageComponent:BP_OnDamageReceived never fires (not called through ProcessEvent), and
-- FDominionPointDamageEvent has no Target field, so v1's hit_self was always false. v1.1 uses the multicasts the
-- server itself calls (they go through ProcessEvent):
--   PlayerMeleeAttackComponent:Multicast_SendDamageCacheData(TArray<FTimedDamageInfo>)  -> damage BY a player (melee):
--       owner = the attacking player; each DamagedActor.PointDamageEvent: Amount, TypeDamagesArray (damage types),
--       TypeDamagesOutcome, AttackId, VictimLocation -> the victim = the creature/player nearest that point.
--   AiAttackComponent:Multicast_SendDamageCacheData(FAiAttackOutcome)                     -> damage BY a creature.
--   PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack / ...BlockedAttack -> parry / block.
--   AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies                           -> telegraph.
-- A telegraphed attack on the watched character that did not hurt him is `defended`: how = "dodge" when the evade
-- invulnerability tag (UPlayerDamageComponent.InvulnerableEvadeTag) was on the pawn, else how = nil (unknown).
-- Callbacks dispatch through _G.__dw_bench_ref_dispatch so a redeployed referee.lua takes effect without re-hooking.
M.HOOKS_V11 = {
    melee = "/Script/Dominion.PlayerMeleeAttackComponent:Multicast_SendDamageCacheData",
    ai = "/Script/Dominion.AiAttackComponent:Multicast_SendDamageCacheData",
    parried = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingParriedAttack",
    blocked = "/Script/Dominion.PlayerBlockingComponent:Multicast_NotifyActorsToDamagePendingBlockedAttack",
    telegraph = "/Script/Dominion.AiAttackComponent:Multicast_PerformAttackOnSimulatedProxies",
}

local function vec(v)
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    return ok and type(x) == "number" and { X = x, Y = y, Z = z } or nil
end

local function nearest_actor(at, max_cm)
    if not at then return nil end
    local best, bd = nil, max_cm or 400
    for _, cls in ipairs({ M.CREATURE_CLASS, "BP_PlayerCharacter_C" }) do
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local q = U.loc(a)
            local d = q and U.dist(q, at)
            if d and d < bd then best, bd = a, d end
        end
    end
    return best
end

local function point_event_fields(pe)
    local types, outcomes = {}, {}
    pcall(function()
        pe.TypeDamagesArray.TypeDamages:ForEach(function(_, td)
            local v = U.try(function() return td:get() end) or td
            for _, t in ipairs(tags_of(v.Types)) do types[#types + 1] = t end
        end)
    end)
    pcall(function() pe.TypeDamagesOutcome:ForEach(function(_, o) outcomes[#outcomes + 1] = U.try(function() return o:get() end) end) end)
    return { amount = U.try(function() return pe.Amount end), damage_types = types, damage_type = types[1], outcomes = outcomes,
             attack_id = U.try(function() return pe.AttackId end), fatal = U.try(function() return pe.bIsFatalHit end) == true,
             victim_at = vec(U.try(function() return pe.VictimLocation end)) }
end

local function name_of(actor, watch)
    if not U.valid(actor) then return nil end
    local cw = U.class_word(actor) or ""
    if cw:find("PlayerCharacter", 1, true) then
        local n = U.player_name(actor)
        return n == watch and "self" or n
    end
    return U.short(actor)
end

local function each_damaged(list, fn)
    pcall(function()
        list:ForEach(function(_, da)
            local v = U.try(function() return da:get() end) or da
            local pe = U.try(function() return v.PointDamageEvent end)
            if pe then fn(point_event_fields(pe)) end
        end)
    end)
end

local function emit_damage(s, by, f)
    local victim = nearest_actor(f.victim_at)
    local tgt = name_of(victim, s.watch)
    s.last_by = s.last_by or {}
    if tgt then s.last_by[tgt] = { by = by, t = os.time() } end
    emit("damage", { target = tgt, kind_id = victim and U.class_word(victim), by = by, amount = f.amount, damage_type = f.damage_type,
                     damage_types = f.damage_types, outcomes = f.outcomes, attack_id = f.attack_id, fatal = f.fatal, source = "hook" })
    if f.fatal then emit("death", { who = tgt, kind_id = victim and U.class_word(victim), by = by, source = "hook" }) end
    return tgt
end

local function owner_of(ctx)
    local comp = U.try(function() return ctx:get() end)
    return comp and U.try(function() return comp:GetOwner() end)
end

local D = {}
function D.melee(ctx, infos_p)
    local s = S()
    s.melee_seen = true
    local by = name_of(owner_of(ctx), s.watch)
    local infos = U.try(function() return infos_p:get() end)
    pcall(function()
        infos:ForEach(function(_, ti)
            local v = U.try(function() return ti:get() end) or ti
            each_damaged(v.DamageInfo.DamagedActors, function(f) emit_damage(s, by, f) end)
        end)
    end)
end

local function evade_tag(pawn)
    local dc = U.try(function() return pawn.PlayerDamageComponent end) or U.try(function() return pawn.DamageComponent end)
    return dc and U.str(U.try(function() return dc.InvulnerableEvadeTag.TagName end))
end

local function pawn_has_tag(pawn, tag)
    if not tag then return false end
    local ge = U.try(function() return pawn.GameplayEffectsComponent end)
    for _, t in ipairs(ge and tags_of(ge.GameplayTags) or {}) do if t == tag then return true end end
    return false
end

local function watched_pawn(watch)
    for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
        if U.player_name(p) == watch then return p end
    end
end

function D.ai(ctx, outcome_p)
    local s = S()
    s.ai_seen = true
    local attacker = owner_of(ctx)
    local by = attacker and U.class_word(attacker)
    local o = U.try(function() return outcome_p:get() end)
    if not o then return end
    local aid = U.try(function() return o.AttackId end)
    local hit_self = false
    each_damaged(U.try(function() return o.DamagedActors end), function(f)
        if emit_damage(s, by, f) == "self" then hit_self = true end
    end)
    local key = tostring(U.short(attacker)) .. ":" .. tostring(aid)
    if s.pending2 and s.pending2[key] then
        s.pending2[key] = nil
        if not hit_self then
            local pawn = watched_pawn(s.watch)
            local dodged = pawn and pawn_has_tag(pawn, evade_tag(pawn))
            emit("defended", { how = dodged and "dodge" or nil, outcome = dodged and "dodged" or "avoided", telegraphed = true,
                               direction_ok = dodged or nil, attack_id = aid, attacker_kind = by })
        end
    end
end

local function parry_like(how, outcome)
    return function(ctx, list_p, pending_p)
        local s = S()
        local who = name_of(owner_of(ctx), s.watch)
        local pend = U.try(function() return pending_p:get() end)
        local aid = pend and U.try(function() return pend.AttackId end)
        local atk = pend and U.try(function() return pend.Attacker end)
        if s.pending2 and atk then s.pending2[tostring(U.short(atk)) .. ":" .. tostring(aid)] = nil end
        if who == "self" then
            emit("defended", { how = how, outcome = outcome, telegraphed = true, attack_id = aid, attacker_kind = atk and U.class_word(atk) })
        end
    end
end
D.parried = parry_like("parry", "parried")
D.blocked = parry_like("block", "blocked")

function D.telegraph(ctx, class_id_p, attack_id_p)
    local s = S()
    local owner = owner_of(ctx)
    local aid = U.try(function() return attack_id_p:get() end)
    local at_me = owner and nearest_player_is_watch(owner, s.watch)
    if at_me and aid then
        s.pending2 = s.pending2 or {}
        s.pending2[tostring(U.short(owner)) .. ":" .. tostring(aid)] = os.time()
    end
    emit("telegraph", { attacker = U.short(owner), kind_id = U.class_word(owner), attack_id = aid,
                        attack_class_id = U.try(function() return class_id_p:get() end), target = at_me and "self" or nil })
end

-- ---------------------------------------------------------------- v1.2: his base (containers, crafts, buildings, plots)
-- Client->server RPCs the server receives through ProcessEvent (post-hooks, read-only; DISCOVERIES Phase 2 hooked
-- Server_RequestInteraction the same way). Owner = the calling player's controller -> his name -> "self".
--   InventoryController:Server_MoveItemBetweenInventories / Server_SplitAndPutStack / Server_MoveAllItemsBetweenInventories
--       -> container_change {by, container, container_class, item, count, from_player, new_since_start}
--   InventoryController:Server_CraftRecipe(Station, Recipe, Count, ...)  -> craft {by, recipe, station_class, count}
--   BuildModeComponent:Server_SpawnBuilding(PieceIndex, Transform, bGhost, ...) -> built {by, piece_index, ghost}
--   FarmCommandComponent:Server_TryPlantSeed / Server_TryHarvestPlot -> planted / harvested {by, plot_id}
-- "His" container = one that did not exist when the referee started (s.known_inv), i.e. built during the case.
M.HOOKS_V12 = {
    move = "/Script/Dominion.InventoryController:Server_MoveItemBetweenInventories",
    split_put = "/Script/Dominion.InventoryController:Server_SplitAndPutStack",
    move_all = "/Script/Dominion.InventoryController:Server_MoveAllItemsBetweenInventories",
    craft = "/Script/Dominion.InventoryController:Server_CraftRecipe",
    build = "/Script/Dominion.BuildModeComponent:Server_SpawnBuilding",
    plant = "/Script/Dominion.FarmCommandComponent:Server_TryPlantSeed",
    harvest = "/Script/Dominion.FarmCommandComponent:Server_TryHarvestPlot",
}

local function caller_name(ctx, watch)
    local comp = U.try(function() return ctx:get() end)
    local owner = comp and U.try(function() return comp:GetOwner() end)
    if not U.valid(owner) then return nil end
    local pawn = U.try(function() return owner.Pawn end) or owner
    local n = U.try(function() return U.player_name(pawn) end)
    return n == watch and "self" or n
end

local function inv_owner(inv)
    local o = U.valid(inv) and U.try(function() return inv:GetOwner() end) or nil
    return o
end

local function slot_item(inv, idx)
    local it = U.try(function() return inv:GetItemFromSlot(idx) end)
    if not U.valid(it) then return nil, nil end
    return U.short(U.try(function() return it.ItemData end)), U.try(function() return it.Count end)
end

local function container_event(s, by, src, dst, item, count)
    local owner = inv_owner(dst)
    local key = U.short(owner)
    local src_owner = inv_owner(src)
    local from_player = src_owner and ((U.class_word(src_owner) or ""):find("Player", 1, true) ~= nil) or false
    emit("container_change", { by = by, container = key, container_class = owner and U.class_word(owner), item = item, count = count,
                               from_player = from_player, new_since_start = key ~= nil and not (s.known_inv or {})[key] })
end

function D.move(ctx, src_p, sidx_p, dst_p, didx_p)
    local s = S()
    local src, dst = U.try(function() return src_p:get() end), U.try(function() return dst_p:get() end)
    local item, count = slot_item(dst, U.try(function() return didx_p:get() end))
    container_event(s, caller_name(ctx, s.watch), src, dst, item, count)
end

function D.split_put(ctx, src_p, sidx_p, amount_p, dst_p, didx_p)
    local s = S()
    local src, dst = U.try(function() return src_p:get() end), U.try(function() return dst_p:get() end)
    local item = slot_item(dst, U.try(function() return didx_p:get() end))
    container_event(s, caller_name(ctx, s.watch), src, dst, item, U.try(function() return amount_p:get() end))
end

function D.move_all(ctx, src_p, dst_p)
    local s = S()
    container_event(s, caller_name(ctx, s.watch), U.try(function() return src_p:get() end), U.try(function() return dst_p:get() end),
                    "*", nil)
end

function D.craft(ctx, station_p, recipe_p, count_p)
    local s = S()
    local st = U.try(function() return station_p:get() end)
    local owner = st and U.try(function() return st:GetOwner() end)
    emit("craft", { by = caller_name(ctx, s.watch), recipe = U.short(U.try(function() return recipe_p:get() end)),
                    station_class = owner and U.class_word(owner), count = U.try(function() return count_p:get() end) })
end

function D.build(ctx, index_p, transform_p, ghost_p)
    local s = S()
    emit("built", { by = caller_name(ctx, s.watch), piece_index = U.try(function() return index_p:get() end),
                    ghost = U.try(function() return ghost_p:get() end) == true })
end

local function farm(kind)
    return function(ctx, plot_p, ...)
        local s = S()
        emit(kind, { by = caller_name(ctx, s.watch), plot_id = tostring(U.try(function() return plot_p:get() end)) })
    end
end
D.plant = farm("planted")
D.harvest = farm("harvested")

function M.snapshot_inventories()
    local s = S()
    s.known_inv = {}
    for _, inv in ipairs(U.find_all("InventoryComponent", { skip_defaults = true })) do
        local o = inv_owner(inv)
        if o then s.known_inv[U.short(o)] = true end
    end
end

function M.register_hooks_v12()
    local s = S()
    if s.hooks3_registered then return s.hooks3 end
    s.hooks3 = {}
    for k, path in pairs(M.HOOKS_V12) do
        local ok, err = pcall(RegisterHook, path, function(ctx, ...)
            local st = rawget(_G, "__dw_bench_referee")
            local d = rawget(_G, "__dw_bench_ref_dispatch")
            if st and st.active2 and d and d[k] then pcall(d[k], ctx, ...) end
        end)
        s.hooks3[k] = ok and "ok" or tostring(err)
    end
    s.hooks3_registered = true
    return s.hooks3
end

rawset(_G, "__dw_bench_ref_dispatch", D)

function M.register_hooks_v11()
    local s = S()
    if s.hooks2_registered then return s.hooks2 end
    s.hooks2 = {}
    for k, path in pairs(M.HOOKS_V11) do
        local ok, err = pcall(RegisterHook, path, function(ctx, ...)
            local st = rawget(_G, "__dw_bench_referee")
            local d = rawget(_G, "__dw_bench_ref_dispatch")
            if st and st.active2 and d and d[k] then pcall(d[k], ctx, ...) end
        end)
        s.hooks2[k] = ok and "ok" or tostring(err)
    end
    s.hooks2_registered = true
    return s.hooks2
end

-- debug_run entry (through mod/scripts/bench.lua): action = start | stop | status | probe | hooks.
function M.run(log, args)
    args = args or {}
    if not dev_only() then return { ok = false, error = "not_dev_server", detail = "set DW_SERVER_ROLE=dev on the dev server only" } end
    local s = S()
    if args.action == "probe" then
        local players = {}
        for _, p in ipairs(U.find_all("BP_PlayerCharacter_C", { skip_defaults = true })) do
            local pc = U.controller_of(p)
            local ps = U.try(function() return p.PlayerState end)
            players[#players + 1] = { name = U.player_name(p), health = U.health(p), has_inventory = U.valid(pc) and counts(pc) ~= nil,
                                      character_guid = ps and U.try(function() return U.guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid) end) }
        end
        local here = players[1] and nil
        local creatures = {}
        for _, a in ipairs(U.find_all(M.CREATURE_CLASS, { skip_defaults = true })) do
            if #creatures < 12 then creatures[#creatures + 1] = { id = U.short(a), class = U.class_word(a), health = U.health(a) } end
        end
        return { ok = true, version = M.VERSION, players = players, creatures = creatures, supported = M.SUPPORTED }
    elseif args.action == "hooks" then  -- register the v1.1 hooks (once per server process; dispatch is reloadable)
        return { ok = true, hooks = M.register_hooks_v11(), hooks_v12 = M.register_hooks_v12() }
    elseif args.action == "start" then
        if s.handle then return { ok = true, already = true } end
        s.watch = tostring(args.watch or "Claude")
        s.stop = false
        s.active = false  -- v1 hooks (superseded) stay silent
        s.active2 = true
        pcall(M.snapshot_inventories)  -- containers that exist now are not "his" (built during the case)
        s.spell_classes = type(args.spell_actor_classes) == "table" and args.spell_actor_classes or nil
        s.seen_actors = {}
        for _, cls in ipairs(s.spell_classes or {}) do  -- actors already there are not new
            for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do s.seen_actors[U.short(a) or "?"] = true end
        end
        s.handle = LoopInGameThreadWithDelay(M.POLL_MS, function()
            if s.stop or rawget(_G, "DW_PAUSE") then return end
            pcall(M.poll, s.watch)
        end)
        emit("referee_start", { watch = s.watch, version = M.VERSION })
        return { ok = true, started = true }
    elseif args.action == "stop" then
        s.stop = true
        s.active = false
        s.active2 = false
        if s.handle and CancelDelayedAction then pcall(CancelDelayedAction, s.handle) end
        s.handle = nil
        emit("referee_stop", {})
        return { ok = true, stopped = true }
    end
    return { ok = true, running = s.handle ~= nil, polls = s.polls, watch = s.watch, version = M.VERSION }
end

return M
