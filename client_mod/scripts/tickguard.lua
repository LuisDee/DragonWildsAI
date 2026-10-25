-- tickguard.lua: slow down engine tick functions that can deadlock Claude's headless client.
--
-- Why (DISCOVERIES "Client hang (R2)"): ULightFlickeringWorldSubSystem::Tick (Dominion, ticked by
-- UJgxTickableWorldSubsystem.PrimarySubsystemTick in TG_DuringPhysics) first waits
-- (WaitUntilTaskCompletes) for the background task it launched last frame. That task posts a
-- GameThread task and DontCompleteUntil()s on it. When the background task is late by about a
-- frame (busy background workers during item and asset loads, 4 vCPUs shared with the server,
-- ~115 fps), the GameThread waits on an event for work only the GameThread can run, and it hangs
-- forever.
-- Fix: give that tick function a huge TickInterval. It then ticks about once an hour, and the
-- previous task has always finished long before. The subsystem only animates light intensity,
-- which a -nullrhi client never draws. Server and other players are untouched (client-local
-- object).
-- The write is a reflected float property (FTickFunction.TickInterval, read again to verify).
-- FTickTaskLevel re-reads TickInterval every frame, so no re-registration is needed.
-- A new world gets new subsystem instances: client_bridge SERVICES calls healthy()/start() every
-- 10 s, which re-applies the interval.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()

local M = { U = U }

-- One row per guarded tick function. class = FindAllOf short class name, prop = the reflected
-- FTickFunction-derived struct property on it, interval_s = the TickInterval to enforce.
M.GUARDS = {
    { class = "LightFlickeringWorldSubSystem", prop = "PrimarySubsystemTick", interval_s = 3600.0,
      why = "Tick waits on a bg task that DontCompleteUntil()s a GameThread task -> GameThread deadlock" },
}

local function say(log, msg) if log then pcall(log, "tickguard: " .. msg) end end

local function interval_of(obj, prop)
    return U.try(function() return obj[prop].TickInterval end)
end

-- Live (non-default) instances of each guard with their current interval. Read-only.
function M.status()
    local rows, all_ok = {}, true
    for _, g in ipairs(M.GUARDS) do
        for _, o in ipairs(U.find_all(g.class, { skip_defaults = true })) do
            local cur = interval_of(o, g.prop)
            local ok = type(cur) == "number" and cur >= g.interval_s * 0.99
            all_ok = all_ok and ok
            rows[#rows + 1] = { class = g.class, name = U.short(o), interval = cur, ok = ok }
        end
    end
    return { ok = true, guarded = all_ok, instances = rows }
end

-- Healthy when every live instance already has the interval (no instances, e.g. at the menu,
-- counts as healthy: there is nothing to guard yet).
function M.healthy() return M.status().guarded == true end

-- Apply the interval to every live instance that lacks it and read it back.
function M.apply(log)
    local applied, failed = {}, {}
    for _, g in ipairs(M.GUARDS) do
        for _, o in ipairs(U.find_all(g.class, { skip_defaults = true })) do
            local before = interval_of(o, g.prop)
            if not (type(before) == "number" and before >= g.interval_s * 0.99) then
                local okw, err = pcall(function() o[g.prop].TickInterval = g.interval_s end)
                local after = interval_of(o, g.prop)
                local row = { class = g.class, name = U.short(o), before = before, after = after, err = (not okw) and tostring(err) or nil }
                if okw and type(after) == "number" and after >= g.interval_s * 0.99 then
                    applied[#applied + 1] = row
                    say(log, ("%s %s TickInterval %s -> %s"):format(g.class, tostring(row.name), tostring(before), tostring(after)))
                else
                    failed[#failed + 1] = row
                    say(log, ("FAILED %s %s: before=%s after=%s err=%s"):format(g.class, tostring(row.name), tostring(before), tostring(after), tostring(row.err)))
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
