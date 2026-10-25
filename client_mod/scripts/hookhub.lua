-- hookhub: the ONE place the client mod registers UFunction hooks (BUGS L24).
--
-- Crash 2026-10-25 22:31:35 UTC (dump crash_2026_10_25_23_31_35.6102217.dmp): access violation in game
-- code reached through two nested UE4SS native-hook trampolines (UE4SS.dll +0xcc7, mislabelled
-- "StartCallbackGarbageCollector" without symbols) during a disconnect. Before it, our vitals re-arm had
-- called UnregisterHook + RegisterHook on Multicast_ApplyDamage* / OnRep_* (only one of the four
-- unregisters even logged), and combat.lua hooked the same Multicast_* functions a second time. UE4SS
-- issue #484 reports UnregisterHook crashing a game depending on the hooked function (v3.0.1 builds).
-- So, from now on:
--   * each UFunction path is natively hooked AT MOST ONCE per client process (one post-hook), and
--     NEVER unregistered (re-arming = swapping the Lua handler, no native call);
--   * modules subscribe handlers by key: hub.on(path, key, fn); the native callback dispatches to every
--     subscriber (each in pcall);
--   * while _G.DW_PAUSE is set (disconnect / join / world teardown) the callback returns at once,
--     before touching any parameter or UObject;
--   * the native registration is deferred until a pawn exists in the game world (opts.defer_until_world):
--     registering at the main menu is never needed and is where the vitals hooks went silent.
-- State lives in _G.DWHookHub (survives hot reloads of this file and of the subscribing modules).
-- Precedent: UE4SS docs (RegisterHook returns ids; UnregisterHook needs both), UE4SS issue #484
-- (UnregisterHook crash, function-dependent), PalMods guidance (do engine work in the game thread).
local M = {}

local function H()
    local h = rawget(_G, "DWHookHub")
    if not h then
        h = { paths = {}, counts = { registered = 0, failed = 0, dispatched = 0, paused_skips = 0, errors = 0 } }
        _G.DWHookHub = h
    end
    return h
end
M._state = H

local function paused() return rawget(_G, "DW_PAUSE") == true end

-- Where hookhub.lua lives, for modules that load it next to themselves (tests run them from other roots).
M.FILE = (debug.getinfo(1, "S").source:match("^@(.*)$"))

-- defer = true when we positively know we are not in the game world: no local pawn, or the front-end map
function M.not_in_world(pawn)
    if pawn == nil then return true end
    local ok, name = pcall(function() return pawn:GetFullName() end)
    return ok and type(name) == "string" and name:find("FrontEnd", 1, true) ~= nil
end

-- One native post-hook for `path`, dispatching to the path's subscribers.
local function native(path, log)
    local h = H()
    local rec = h.paths[path]
    if rec.native then return true end
    if type(RegisterHook) ~= "function" then return false end
    local ok, pre, post = pcall(RegisterHook, path, function() end, function(...)
        local hub = rawget(_G, "DWHookHub")
        if not hub then return end
        if rawget(_G, "DW_PAUSE") == true then hub.counts.paused_skips = hub.counts.paused_skips + 1; return end
        local r = hub.paths[path]
        if not r then return end
        hub.counts.dispatched = hub.counts.dispatched + 1
        for key, fn in pairs(r.subs) do
            local ok2, err = pcall(fn, ...)
            if not ok2 then hub.counts.errors = hub.counts.errors + 1; r.last_error = key .. ": " .. tostring(err) end
        end
    end)
    if ok then
        rec.native, rec.ids, rec.at = true, { pre = pre, post = post }, os.time()
        h.counts.registered = h.counts.registered + 1
    else
        rec.error = tostring(pre)
        h.counts.failed = h.counts.failed + 1
    end
    if log then pcall(log, "hookhub: " .. path .. " native=" .. tostring(ok) .. (ok and "" or (" " .. tostring(pre)))) end
    return ok
end

-- Subscribe fn (called with the hook's own arguments) under `key` (replaces that key's previous fn).
-- opts.defer: the caller knows it is NOT in the game world (no pawn, the front-end menu): the native
-- registration waits (pending) until a later call without defer (or M.flush). Paused = deferred too.
-- Returns true when the path is natively hooked now, false + reason when pending or failed.
function M.on(path, key, fn, opts)
    opts = opts or {}
    local h = H()
    local rec = h.paths[path] or { subs = {} }
    h.paths[path] = rec
    rec.subs[key] = fn
    if rec.native then return true end
    if not opts.defer and not paused() then return native(path, opts.log), rec.error end
    rec.pending = true
    return false, "pending (not in the world yet)"
end

-- Drop a subscriber (the native hook stays; it just has one fewer handler).
function M.off(path, key)
    local rec = H().paths[path]
    if rec then rec.subs[key] = nil end
end

-- Register every pending path now (call once a pawn is in the world).
function M.flush(log)
    if paused() then return 0 end
    local n = 0
    for path, rec in pairs(H().paths) do
        if not rec.native and rec.pending then
            if native(path, log) then n = n + 1 end
            rec.pending = not rec.native
        end
    end
    return n
end

function M.hooked(path) local r = H().paths[path]; return r ~= nil and r.native == true end

function M.status()
    local h = H()
    local paths = {}
    for p, r in pairs(h.paths) do
        local keys = {}
        for k in pairs(r.subs) do keys[#keys + 1] = k end
        table.sort(keys)
        paths[p] = { native = r.native == true, pending = r.pending == true, subs = keys, error = r.error, last_error = r.last_error }
    end
    return { ok = true, counts = h.counts, paths = paths }
end

M.HANDLERS = { hookhub_status = function() return M.status() end }

return M
