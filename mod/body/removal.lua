-- Crash-free removal of a server-spawned, AI-possessed BP_PlayerCharacter_C ("puppet").
-- Promoted from scripts/puppet_safe.lua (verified on build 26161880, DISCOVERIES "Unpossess crash:
-- fix bisect", runs 1-2g). The debug entry point is experiments/puppet_safe.lua.
--
-- Why: any unpossess of an AI-possessed puppet (UnPossess, K2_DestroyActor, SetLifeSpan) crashed
-- the server. The pawn's controller-changed delegate calls
-- UPlayerRangedAttackComponent::OnPlayerControllerChanged(Pawn, OldController, NewController),
-- which casts OldController to ADominionPlayerController and reads ->LoadoutComponent (+0x1248)
-- without checking that the cast succeeded; for an AIController the cast is null. Destroying that
-- one component first (it is then garbage, so the delegate skips it) makes unpossess safe.
--
--   local removal = require("body.removal")
--   local r = removal.safe_remove(puppet)   -- r = {ok=bool, reason=str|nil, data={...}}
--
-- main.lua registers it with body.puppet via set_safe_remover; puppet.park() uses it only when
-- DW_PUPPET_SAFE_REMOVE=1 (otherwise the puppet is hidden and parked, never removed).
-- UNTESTED: the puppet's death/respawn path, which probably fires the same handler. Keep the
-- puppet immortal; the strip only protects removal.
local U = require("body.util")

local M = {}

-- Components whose controller-changed handler dereferences a DominionPlayerController without a
-- null check. Bisected: PlayerRangedAttackComponent alone is necessary and sufficient.
M.UNSAFE_COMPONENTS = { "PlayerRangedAttackComponent" }
M.LIFESPAN_S = 0.1

-- UE4SS IsValid() stays true for a destroyed actor until GC; the Garbage flag is the real test.
M.alive = U.alive

-- opts.unpossess (default true): call UnPossess explicitly before destroying. With false, the
-- destroy itself unpossesses (also verified safe after the strip). opts.log: logger (default U's).
function M.safe_remove(puppet, opts)
    opts = opts or {}
    local log = opts.log
    if not U.alive(puppet) then return U.result(true, "already_gone") end
    local name = U.fullname(puppet)
    local ctrl = U.controller_of(puppet)
    if U.is_player_controller(ctrl) then return U.result(false, "is_real_player", { puppet = name }) end
    local has_ctrl = U.alive(ctrl)

    if has_ctrl then
        -- Remove the unsafe handlers first. If any of them survives, stop here: an unpossess now
        -- would crash the server (a native access violation that pcall cannot catch).
        for _, prop in ipairs(M.UNSAFE_COMPONENTS) do
            local comp = U.try(function() return puppet[prop] end)
            if U.alive(comp) then
                -- K2_DestroyComponent(Object) only destroys when Object is the owner.
                U.call(log, "removal.K2_DestroyComponent", { puppet = name, component = prop }, function()
                    comp:K2_DestroyComponent(puppet)
                end)
                if U.alive(comp) then
                    return U.result(false, "strip_failed", { puppet = name, component = prop })
                end
            end
        end
        if opts.unpossess ~= false then
            local ok, err = U.call(log, "removal.UnPossess", { puppet = name }, function() ctrl:UnPossess() end)
            if not ok then return U.result(false, "unpossess_error", { puppet = name, err = tostring(err) }) end
        end
    end

    -- SetLifeSpan, not K2_DestroyActor: the engine destroys the actor on its next tick, outside
    -- our callback (immediate destroys from a UE4SS callback are avoided; see DISCOVERIES).
    -- Held weapons (body.gear) are separate actors attached to the mesh; remove them too, or they
    -- would be left behind (detached) when the pawn goes.
    local held = {}
    local eq = U.try(function() return puppet.PlayerEquipmentComponent end)
    for _, slot in ipairs({ "HeldEquipmentActorRight", "HeldEquipmentActorLeft" }) do
        local h = eq and U.try(function() return eq[slot] end)
        if U.alive(h) and U.call(log, "removal.held_SetLifeSpan", { slot = slot }, function() h:SetLifeSpan(M.LIFESPAN_S) end) then
            held[#held + 1] = U.fullname(h)
        end
    end
    local ok_p = U.call(log, "removal.pawn_SetLifeSpan", { puppet = name }, function() puppet:SetLifeSpan(M.LIFESPAN_S) end)
    local ok_c = (not has_ctrl) or U.call(log, "removal.controller_SetLifeSpan", {}, function() ctrl:SetLifeSpan(M.LIFESPAN_S) end)
    local ok = ok_p and ok_c
    return U.result(ok, (not ok) and "destroy_error" or nil,
                    { puppet = name, controller = has_ctrl and U.fullname(ctrl) or nil, held = held })
end

-- Destroy plain AIControllers that possess nothing (left over when a puppet was unpossessed but
-- only the pawn was destroyed). FindAllOf matches the exact class, so creature controller
-- subclasses are not touched. Returns the count.
function M.remove_orphan_controllers(log)
    local n = 0
    for _, c in ipairs(U.find_all("AIController")) do
        local dying = (U.try(function() return c:GetLifeSpan() end) or 0) > 0 -- already queued
        if not dying and not U.alive(U.try(function() return c:K2_GetPawn() end)) then
            if U.call(log, "removal.orphan_SetLifeSpan", { controller = U.short(c) }, function() c:SetLifeSpan(M.LIFESPAN_S) end) then
                n = n + 1
            end
        end
    end
    return n
end

-- Remove every puppet (each alive BP_PlayerCharacter_C not possessed by a PlayerController).
-- opts: {unpossess, orphans}. Returns {results, orphan_controllers_destroyed}.
function M.remove_all(log, opts)
    opts = opts or {}
    local out = {}
    local _, puppets = U.split_pawns()
    for _, p in ipairs(puppets) do
        out[#out + 1] = M.safe_remove(p, { unpossess = opts.unpossess, log = log })
    end
    local orphans = opts.orphans and M.remove_orphan_controllers(log) or 0
    U.event(log, "puppet_safe_remove", { results = out, orphans = orphans })
    return { results = out, orphan_controllers_destroyed = orphans }
end

return M
