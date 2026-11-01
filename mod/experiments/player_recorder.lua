-- Player recorder (READ-ONLY): what every connected player does, from the authoritative server, for human
-- baselines (Luis) and the same metrics for Claude (DIRECTION-2026-11-01: evals to a real player's standard).
-- Never writes to a player, an inventory or the world. Modelled on craft_drift.lua (same hook + loop pattern).
--
--   debug_run {module="player_recorder", args={action="arm", out=<path.jsonl>, seconds=1800, period_ms=200}}
--     * every period_ms, per player pawn: position (m), speed (m/s), yaw, movement mode, health      -> kind="pos"
--     * inventory counts (PC.InventoryComponent + PersonalInventoryComponent): every change, as a delta -> kind="inv"
--     * pre-hooks on the player-action server RPCs below (who, params as short scalars)                 -> kind="rpc"
--   {action="status"} | {action="stop"}
-- Hooks are registered once per server run (UE4SS cannot unregister); they only emit while armed.
local U = require("body.util")
local jsonutil = require("jsonutil")

local M = {}
M.PERIOD_MS = 200

local IC = "/Script/Dominion.InventoryController:"
M.HOOKS = {
    interact = "/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction", -- every interact press (pickup, open, harvest)
    use_item = IC .. "Server_UseItemFromInventory",         -- eat / drink / use
    drop = IC .. "Server_DropItemFromInventory",            -- (Inventory, SlotIndex, Instigator, AmountOverride)
    split = IC .. "Server_SplitStack",                      -- (Inventory, SlotIndex, StackCount)
    split_put = IC .. "Server_SplitAndPutStack",
    move = IC .. "Server_MoveItemBetweenInventories",
    move_all = IC .. "Server_MoveAllItemsBetweenInventories",
    craft = IC .. "Server_CraftRecipe",
    toggle = IC .. "Server_ToggleProcessing",
    build_spawn = "/Script/Dominion.BuildModeComponent:Server_SpawnBuilding",          -- (PieceIndex, Transform, bGhost, Invs)
    build_interact = "/Script/Dominion.BuildInteractionComponent:Server_Interact",     -- deconstruct / repair / ...
    harvest_plot = "/Script/Dominion.FarmCommandComponent:Server_TryHarvestPlot",
    ability = "/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbility", -- attacks, dodges, spells (a client's request)
    spell_targets = "/Script/Dominion.SpellTargetingComponent:Server_NotifyTargetActors",
}

local G = rawget(_G, "__dw_player_recorder")
if not G then
    G = { hooks = {}, loop = nil, file = nil, armed = false, events = 0, inv = {}, until_ms = 0 }
    rawset(_G, "__dw_player_recorder", G)
end

local function clock_ms() return math.floor(os.clock() * 1000) end
-- epoch milliseconds: the arm time's os.time() plus the clock since then (os.date has only seconds)
local function epoch_ms() return (G.epoch0 or os.time()) * 1000 + (clock_ms() - (G.clock0 or clock_ms())) end
local function asset(p) return p and (p:match("%.([^%./]+)$") or p) or nil end
local function r2(x) return x and math.floor(x * 100 + 0.5) / 100 or nil end

local function emit(rec)
    if not (G.armed and G.file) then return end
    G.events = G.events + 1
    rec.ts = epoch_ms() / 1000
    local f = io.open(G.file, "ab")
    if f then f:write(jsonutil.encode(rec), "\n"); f:close() end
end

local function describe(v)
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then return v end
    if v == nil then return nil end
    local full = U.fullname(v)
    if full then return full:match("([%w_%-]+)$") or full end
    local n = U.try(function() return v:GetArrayNum() end)
    if n then return "TArray[" .. tostring(n) .. "]" end
    return type(v)
end

-- the player behind a component/actor: its owner chain up to a pawn, a controller or a player state
local function who_of(obj)
    local a = obj
    for _ = 1, 4 do
        if not U.valid(a) then return nil end
        -- the CLASS, not the full path: a component's path names its outer controller (live 12:40: every rpc row
        -- was "who": "BP_Components_InteractionManager")
        local cls = U.class_word(a) or ""
        if cls:find("PlayerState", 1, true) then return U.str(U.try(function() return a:GetPlayerName() end)) end
        if cls:find("PlayerController", 1, true) then
            local p = U.try(function() return a.Pawn end)
            return U.valid(p) and U.player_name(p) or U.short(a)
        end
        if cls:find("BP_PlayerCharacter_C", 1, true) then return U.player_name(a) end
        a = U.try(function() return a:GetOwner() end)
    end
    return nil
end

local function inv_counts(inv, out)
    if not U.valid(inv) then return out end
    pcall(function()
        inv.ItemSlots:ForEach(function(_, e)
            local it = U.try(function() return e:get() end)
            if U.valid(it) then
                local id = asset(U.path_of(U.try(function() return it.ItemData end)))
                local n = tonumber(U.try(function() return it.Count end)) or 0
                if id and n > 0 then out[id] = (out[id] or 0) + n end
            end
        end)
    end)
    return out
end

local function counts_of(pawn)
    local pc = U.controller_of(pawn)
    if not pc then return nil end
    local out = {}
    inv_counts(U.try(function() return pc.InventoryComponent end), out)
    inv_counts(U.try(function() return pc.PersonalInventoryComponent end), out)
    return out
end

local function step()
    if not G.armed then return end
    if clock_ms() > G.until_ms then
        G.armed = false
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        G.loop = nil
        return
    end
    local players = U.split_pawns()
    for _, p in ipairs(players) do
        local name = U.player_name(p) or "?"
        local at = U.loc(p)
        if at then
            local vel = U.try(function() return p:GetVelocity() end)
            local speed = vel and math.sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2) / 100 or nil
            local rot = U.try(function() return p:K2_GetActorRotation() end)
            local mode = U.try(function() return p.CharacterMovement.MovementMode end)
            emit({ kind = "pos", who = name, p = { r2(at.X / 100), r2(at.Y / 100), r2(at.Z / 100) }, v = r2(speed),
                   vz = vel and r2((vel.Z or 0) / 100) or nil, yaw = rot and r2(rot.Yaw) or nil,
                   mode = tonumber(mode) or describe(mode), hp = r2(tonumber(U.health(p))) })
        end
        local c = counts_of(p)
        if c then
            local last = G.inv[name]
            if last then
                local d = {}
                for k, n in pairs(c) do if (last[k] or 0) ~= n then d[k] = n - (last[k] or 0) end end
                for k, n in pairs(last) do if c[k] == nil then d[k] = -n end end
                if next(d) then emit({ kind = "inv", who = name, delta = d }) end
            else
                emit({ kind = "inv_start", who = name, counts = c })
            end
            G.inv[name] = c
        end
    end
end

local function arm_hooks(log)
    if type(RegisterHook) ~= "function" then return { err = "RegisterHook unavailable" } end
    local out = {}
    -- hooks registered once per server run call G.on_rpc, which every arm replaces, so a redeployed file's handler
    -- takes over without a server restart
    G.on_rpc = function(tag, ctx, a1, a2, a3, a4)
        if not G.armed then return end
        local ok, err = pcall(function()
            local self = U.try(function() return ctx:get() end)
            local rec = { kind = "rpc", rpc = tag, who = who_of(self), params = {} }
            for i, p in ipairs({ a1, a2, a3, a4 }) do
                local v = U.try(function() return p:get() end)
                rec.params[i] = describe(v)
            end
            if tag == "interact" then
                local comp = U.try(function() return a1:get() end)
                local owner = U.valid(comp) and U.try(function() return comp:GetOwner() end) or nil
                rec.target = owner and U.short(owner) or nil
                rec.target_class = owner and U.class_word(owner) or nil
                local tat = owner and U.loc(owner) or nil
                rec.target_p = tat and { r2(tat.X / 100), r2(tat.Y / 100), r2(tat.Z / 100) } or nil
            end
            emit(rec)
        end)
        if not ok then U.event(log, "player_recorder_hook_error", { hook = tag, err = tostring(err) }) end
    end
    for tag, path in pairs(M.HOOKS) do
        if not G.hooks[tag] then
            local function pre(ctx, a1, a2, a3, a4)
                if G.on_rpc then return G.on_rpc(tag, ctx, a1, a2, a3, a4) end
                if not G.armed then return end
                local ok, err = pcall(function()
                    local self = U.try(function() return ctx:get() end)
                    local rec = { kind = "rpc", rpc = tag, who = who_of(self), params = {} }
                    -- scalar / object params only; struct params (transforms, ability handles) are named by type
                    for i, p in ipairs({ a1, a2, a3, a4 }) do
                        local v = U.try(function() return p:get() end)
                        rec.params[i] = describe(v)
                    end
                    if tag == "interact" then
                        local comp = U.try(function() return a1:get() end)
                        local owner = U.valid(comp) and U.try(function() return comp:GetOwner() end) or nil
                        rec.target = owner and U.short(owner) or nil
                        rec.target_class = owner and U.class_word(owner) or nil
                        local tat = owner and U.loc(owner) or nil
                        rec.target_p = tat and { r2(tat.X / 100), r2(tat.Y / 100), r2(tat.Z / 100) } or nil
                    end
                    emit(rec)
                end)
                if not ok then U.event(log, "player_recorder_hook_error", { hook = tag, err = tostring(err) }) end
            end
            local ok, err = U.call(log, "player_recorder.RegisterHook", { fn = path }, function()
                RegisterHook(path, pre, function() end)
            end)
            G.hooks[tag] = ok or nil
            out[tag] = ok and "armed" or tostring(err)
        else
            out[tag] = "already"
        end
    end
    return out
end

function M.run(log, args)
    args = args or {}
    local action = args.action or "status"
    if action == "arm" then
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        G.file = args.out or ((os.getenv("DW_MOD_LOG_DIR") or ".") .. "/player_recorder_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl")
        G.epoch0, G.clock0 = os.time(), clock_ms()
        G.until_ms = G.clock0 + (tonumber(args.seconds) or 1800) * 1000
        G.events, G.inv, G.armed = 0, {}, true
        local period = math.max(100, tonumber(args.period_ms) or M.PERIOD_MS)
        local hooks = arm_hooks(log)
        local names = {}
        for _, p in ipairs(U.split_pawns()) do names[#names + 1] = U.player_name(p) end
        emit({ kind = "armed", hooks = hooks, period_ms = period, players = names })
        G.loop = LoopInGameThreadWithDelay(period, function()
            local ok, err = pcall(step)
            if not ok then U.event(log, "player_recorder_step_error", { err = tostring(err) }) end
        end)
        return { ok = true, file = G.file, hooks = hooks, players = names }
    elseif action == "stop" then
        emit({ kind = "stopped" })
        G.armed = false
        if G.loop and CancelDelayedAction then pcall(CancelDelayedAction, G.loop) end
        G.loop = nil
        return { ok = true, file = G.file, events = G.events }
    end
    return { ok = true, armed = G.armed, file = G.file, events = G.events,
             hooks = (function() local o = {} for k in pairs(G.hooks) do o[#o + 1] = k end return o end)() }
end

return M
