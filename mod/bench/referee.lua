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
        local hooked = s.hooks and s.hooks.damage == "ok"  -- the v1 damage hook reports damage with attribution
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
    if anchor then
        local here = U.loc(anchor)
        for _, a in ipairs(U.find_all(M.CREATURE_CLASS, { skip_defaults = true })) do
            local q = U.loc(a)
            if q and here and U.dist(q, here) <= M.RADIUS_CM then
                local key = "creature:" .. tostring(U.short(a))
                local hp = U.health(a)
                if not (s.hooks and s.hooks.damage == "ok") and s.prev[key] and hp and s.prev[key] > hp then
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
    elseif args.action == "hooks" then  -- register the v1 hooks (once per server process)
        return { ok = true, hooks = M.register_hooks() }
    elseif args.action == "start" then
        if s.handle then return { ok = true, already = true } end
        s.watch = tostring(args.watch or "Claude")
        s.stop = false
        s.active = true
        s.handle = LoopInGameThreadWithDelay(M.POLL_MS, function()
            if s.stop or rawget(_G, "DW_PAUSE") then return end
            pcall(M.poll, s.watch)
        end)
        emit("referee_start", { watch = s.watch, version = M.VERSION })
        return { ok = true, started = true }
    elseif args.action == "stop" then
        s.stop = true
        s.active = false
        if s.handle and CancelDelayedAction then pcall(CancelDelayedAction, s.handle) end
        s.handle = nil
        emit("referee_stop", {})
        return { ok = true, stopped = true }
    end
    return { ok = true, running = s.handle ~= nil, polls = s.polls, watch = s.watch, version = M.VERSION }
end

return M
