-- Shared setup for offline bridge tests: put mod/scripts on package.path and stub the
-- UE4SS globals the mod uses. Lets the body run under a plain Lua 5.4 interpreter.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../scripts/?.lua;" .. package.path

local H = { loops = {}, next_handle = 1, cancelled = {} }

-- LoopInGameThreadWithDelay(delayMs, callback) -> handle. Tests drive H.tick() manually.
function LoopInGameThreadWithDelay(delay_ms, cb)
    local handle = H.next_handle
    H.next_handle = handle + 1
    H.loops[handle] = { delay_ms = delay_ms, cb = cb }
    return handle
end

function CancelDelayedAction(handle)
    local found = H.loops[handle] ~= nil
    H.loops[handle] = nil
    H.cancelled[#H.cancelled + 1] = handle
    return found
end

function ExecuteInGameThreadWithDelay(_, cb) cb() end
function RegisterHook() error("RegisterHook is not available offline") end

-- Run every registered loop callback once.
function H.tick()
    for _, l in pairs(H.loops) do l.cb() end
end

-- Busy-wait (stdlib Lua has no sleep). Only used by the integration runner.
function H.sleep(seconds)
    local stop = os.clock() + seconds
    while os.clock() < stop do end
end

-- Minimal dwlog stand-in that records events in memory.
H.log = { events = {} }
function H.log.event(name, data) H.log.events[#H.log.events + 1] = { name = name, data = data } end

return H
