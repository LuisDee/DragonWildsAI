-- fxguard.lua: keep game code from dereferencing the NULL VFX components a -nullrhi client gets.
--
-- Why (BUGS L38, DISCOVERIES "Client crash L38"): Claude's client runs with -nullrhi, so
-- FApp::CanEverRender() is false and EVERY UNiagaraFunctionLibrary spawn returns NULL (verified live:
-- SpawnSystemAttached returns NULL with bPreCullCheck true and false; the shipped CreateNiagaraSystem
-- returns NULL on the GUsingNullRHI-style global before creating anything).
-- ADominionPlayerCharacter::AddNiagaraSystemAttachedWithLocalTag stores that result in LocalFX
-- (TMap<FGameplayTag, UNiagaraComponent*>) without a null check, and RemoveNiagaraSystemWithLocalTag
-- later calls a virtual on it: an access violation (mov rax,[rcx], rcx=0; call [rax+2C0h]) inside the
-- gameplay-tag-changed broadcast. The trigger table is TaggedLocalNiagaraSystems (trigger tag ->
-- {LocalVFXTag, System, AttachPointName}); today one row: Environment.SoulScourge ->
-- Player.Vfx.SoulScourge / NS_SoulScorge_PlayerEffect_Buildup (Dirty Water's Soulscourge build-up).
-- Fix: empty TaggedLocalNiagaraSystems on every player character Claude's client knows (his own AND
-- other players' pawns, whose tag events run here too). The tag handler then finds no row and neither
-- adds a NULL nor removes one; whatever row a patch adds later is covered too. Purely cosmetic and
-- client-local (a non-replicated config map): a -nullrhi client never draws those systems anyway.
-- A new pawn (respawn, rejoin, another player joining) gets a fresh map: client_bridge SERVICES calls
-- healthy()/start() every 10 s, and status() lists any instance that still has rows.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

-- One row per game container that maps a trigger to a VFX spawn whose NULL result the game stores and
-- later dereferences on a -nullrhi client. class = FindAllOf short class name, prop = the reflected TMap.
M.GUARDS = {
    { class = "DominionPlayerCharacter", prop = "TaggedLocalNiagaraSystems",
      why = "AddNiagaraSystemAttachedWithLocalTag stores a NULL Niagara component in LocalFX; RemoveNiagaraSystemWithLocalTag derefs it" },
}

local function say(log, msg) if log then pcall(log, "fxguard: " .. msg) end end

local function rows_of(obj, prop)
    local n, keys = 0, {}
    local ok = pcall(function() obj[prop]:ForEach(function(k) n = n + 1; keys[#keys + 1] = U.try(function() return U.str(k:get().TagName) end) end) end)
    return ok and n or nil, keys
end

-- Live (non-default) instances and how many rows each guarded map still holds. Read-only.
function M.status()
    local out, all_ok = {}, true
    for _, g in ipairs(M.GUARDS) do
        for _, o in ipairs(U.find_all(g.class, { skip_defaults = true })) do
            local n, keys = rows_of(o, g.prop)
            local ok = n == 0
            all_ok = all_ok and ok
            out[#out + 1] = { class = g.class, name = U.short(o), rows = n, keys = keys, ok = ok }
        end
    end
    return { ok = true, guarded = all_ok, instances = out }
end

-- Healthy when every live instance's map is empty (no instances, e.g. at the menu, is healthy).
function M.healthy() return M.status().guarded == true end

-- Empty every live instance's map that still has rows, and read it back.
function M.apply(log)
    local applied, failed = {}, {}
    for _, g in ipairs(M.GUARDS) do
        for _, o in ipairs(U.find_all(g.class, { skip_defaults = true })) do
            local before, keys = rows_of(o, g.prop)
            if before ~= 0 then
                local okw, err = pcall(function() o[g.prop]:Empty() end)
                local after = rows_of(o, g.prop)
                local row = { class = g.class, name = U.short(o), before = before, keys = keys, after = after,
                              err = (not okw) and tostring(err) or nil }
                if okw and after == 0 then
                    applied[#applied + 1] = row
                    say(log, ("%s %s %s emptied (%s rows: %s)"):format(g.class, tostring(row.name), g.prop, tostring(before), table.concat(keys, ",")))
                else
                    failed[#failed + 1] = row
                    say(log, ("FAILED %s %s %s: before=%s after=%s err=%s"):format(g.class, tostring(row.name), g.prop, tostring(before), tostring(after), tostring(row.err)))
                end
            end
        end
    end
    local st = M.status()
    return { ok = #failed == 0, reason = (#failed > 0) and "write_failed" or nil,
             applied = applied, failed = failed, instances = st.instances, guarded = st.guarded }
end

-- Service entry point (client_bridge SERVICES).
function M.start(log) return M.apply(log) end

return M
