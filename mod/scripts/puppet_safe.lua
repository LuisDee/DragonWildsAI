-- Crash-free removal of a server-spawned, AI-possessed BP_PlayerCharacter_C ("puppet").
--
-- Why: any unpossess of an AI-possessed puppet (UnPossess, K2_DestroyActor, SetLifeSpan) crashed
-- the server. The pawn's controller-changed delegate calls
-- UPlayerRangedAttackComponent::OnPlayerControllerChanged(Pawn, OldController, NewController),
-- which casts OldController to ADominionPlayerController and reads ->LoadoutComponent (+0x1248)
-- without checking that the cast succeeded; for an AIController the cast is null. Destroying that
-- one component first (it is then garbage, so the delegate skips it) makes unpossess safe.
-- Verified on build 26161880: docs/DISCOVERIES.md "Unpossess crash: fix bisect".
--
--   local safe = dofile(scripts_dir .. "/puppet_safe.lua")   -- or loadfile, as debug_cmds does
--   local r = safe.safe_remove(puppet)   -- r = {ok=bool, reason=str|nil, data={...}}
--
-- debug_run {module="puppet_safe", args={}} removes every puppet (each BP_PlayerCharacter_C that
-- is not possessed by a PlayerController).
local M = {}

local GARBAGE_OR_UNREACHABLE = 0x200000 | 0x10000000 -- EInternalObjectFlags Garbage | Unreachable
-- Components whose controller-changed handler dereferences a DominionPlayerController without a
-- null check. Bisected: PlayerRangedAttackComponent alone is necessary and sufficient.
M.UNSAFE_COMPONENTS = { "PlayerRangedAttackComponent" }

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function fullname(o) return o and try(function() return o:GetFullName() end) or nil end

-- UE4SS IsValid() stays true for a destroyed actor until GC; the Garbage flag is the real test.
local function alive(o)
    return valid(o) and try(function() return o:HasAnyInternalFlags(GARBAGE_OR_UNREACHABLE) end) ~= true
end
M.alive = alive

local function is_player_controller(c)
    return valid(c) and (fullname(c) or ""):find("PlayerController", 1, true) ~= nil
end

local function result(ok, reason, data) return { ok = ok, reason = reason, data = data or {} } end

-- opts.unpossess (default true): call UnPossess explicitly before destroying. With false, the
-- destroy itself unpossesses (also verified safe after the strip).
function M.safe_remove(puppet, opts)
    opts = opts or {}
    if not alive(puppet) then return result(true, "already_gone") end
    local name = fullname(puppet)
    local ctrl = try(function() return puppet:GetController() end)
    if is_player_controller(ctrl) then return result(false, "is_real_player", { puppet = name }) end
    local has_ctrl = alive(ctrl)

    if has_ctrl then
        -- Remove the unsafe handlers first. If any of them survives, stop here: an unpossess now
        -- would crash the server (a native access violation that pcall cannot catch).
        for _, prop in ipairs(M.UNSAFE_COMPONENTS) do
            local comp = try(function() return puppet[prop] end)
            if alive(comp) then
                -- K2_DestroyComponent(Object) only destroys when Object is the owner.
                pcall(function() comp:K2_DestroyComponent(puppet) end)
                if alive(comp) then
                    return result(false, "strip_failed", { puppet = name, component = prop })
                end
            end
        end
        if opts.unpossess ~= false then
            local ok, err = pcall(function() ctrl:UnPossess() end)
            if not ok then return result(false, "unpossess_error", { puppet = name, err = tostring(err) }) end
        end
    end

    -- SetLifeSpan, not K2_DestroyActor: the engine destroys the actor on its next tick, outside
    -- our callback (immediate destroys from a UE4SS callback are avoided; see DISCOVERIES).
    local ok_p = pcall(function() puppet:SetLifeSpan(0.1) end)
    local ok_c = (not has_ctrl) or pcall(function() ctrl:SetLifeSpan(0.1) end)
    local ok = ok_p and ok_c
    local reason = nil
    if not ok then reason = "destroy_error" end
    return result(ok, reason, { puppet = name, controller = has_ctrl and fullname(ctrl) or nil })
end

function M.run(log, args)
    local out = {}
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if alive(p) and not is_player_controller(try(function() return p:GetController() end)) then
            out[#out + 1] = M.safe_remove(p, args)
        end
    end
    log.event("puppet_safe_remove", { results = out })
    return { results = out }
end

return M
