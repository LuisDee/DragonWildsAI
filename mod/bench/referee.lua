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
        if s.prev[key] and hp and s.prev[key] > hp then emit("damage", { target = name == watch and "self" or name, amount = s.prev[key] - hp }) end
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
                if s.prev[key] and hp and s.prev[key] > hp then
                    emit("damage", { target = U.short(a), kind_id = U.class_word(a), amount = s.prev[key] - hp })
                    if hp <= 0 then emit("death", { who = U.short(a), kind_id = U.class_word(a) }) end
                end
                s.prev[key] = hp
            end
        end
    end
end

-- debug_run entry (through mod/scripts/bench.lua): action = start | stop | status | probe.
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
    elseif args.action == "start" then
        if s.handle then return { ok = true, already = true } end
        s.watch = tostring(args.watch or "Claude")
        s.stop = false
        s.handle = LoopInGameThreadWithDelay(M.POLL_MS, function()
            if s.stop or rawget(_G, "DW_PAUSE") then return end
            pcall(M.poll, s.watch)
        end)
        emit("referee_start", { watch = s.watch, version = M.VERSION })
        return { ok = true, started = true }
    elseif args.action == "stop" then
        s.stop = true
        if s.handle and CancelDelayedAction then pcall(CancelDelayedAction, s.handle) end
        s.handle = nil
        emit("referee_stop", {})
        return { ok = true, stopped = true }
    end
    return { ok = true, running = s.handle ~= nil, polls = s.polls, watch = s.watch, version = M.VERSION }
end

return M
