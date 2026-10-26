-- Offline regression test for the DWClient command runner (client_mod/scripts/main.lua), L28:
-- the poll path must not spawn processes (an io.popen pipe read blocked the GameThread, 2026-10-26
-- 07:14). Here io.popen and os.execute are booby-trapped (popen "blocks": it raises and counts), and
-- the queue protocol is exercised: run, partial lines, withdrawn files, stale entries, rotation.
-- Usage: lua test_runner.lua <empty_dir>
local dir = assert(arg[1], "usage: lua test_runner.lua <empty_dir>"):gsub("\\", "/")
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
for _, d in ipairs({ "/client_io/cmd", "/client_io/out", "/logs/client" }) do
    os.execute('mkdir "' .. (dir .. d):gsub("/", "\\") .. '" 2>nul')
end
local CMD, OUT = dir .. "/client_io/cmd", dir .. "/client_io/out"
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function append(p, s) local f = assert(io.open(p, "ab")); f:write(s); f:close() end

-- a command queued BEFORE the runner loads (a previous client run's leftover) must not run
write(CMD .. "/stale.lua", "return function(log) return { stale = true } end")
append(CMD .. "/queue.txt", "stale\n")

-- engine + process traps
local real_getenv = os.getenv
os.getenv = function(k)
    if k == "DW_CLIENT_ROOT" then return dir elseif k == "DW_CLIENT_BRIDGE" then return "0" end
    return real_getenv(k)
end
local popen_calls, exec_calls = 0, 0
local real_execute = os.execute
io.popen = function() popen_calls = popen_calls + 1; error("io.popen would block the game thread") end
local loop_fn
function LoopInGameThreadWithDelay(ms, fn) loop_fn = fn; return 1 end
function ExecuteInGameThread(fn) fn() end
local real_print = print
print = function() end

dofile(here .. "/../scripts/main.lua")
print = real_print
-- from now on, os.execute is counted too (the startup mkdirs may legitimately run once, above)
os.execute = function(...) exec_calls = exec_calls + 1; return real_execute(...) end

local fails = 0
local function check(name, c, info) if c then print("ok   " .. name) else fails = fails + 1; print("FAIL " .. name .. " " .. tostring(info)) end end

check("runner loop registered", type(loop_fn) == "function")
loop_fn()
check("stale queue entry from before the load is not run", not exists(OUT .. "/stale.json") and exists(CMD .. "/stale.lua"))

-- 1. a queued command runs; its file is consumed; the result is written
write(CMD .. "/hello.lua", "return function(log) return { hi = 42 } end")
append(CMD .. "/queue.txt", "hello\n")
loop_fn()
local f = io.open(OUT .. "/hello.json", "rb"); local txt = f and f:read("a"); if f then f:close() end
check("queued command runs and answers", txt and txt:find('"hi"') and txt:find("42"), txt)
check("command file consumed", not exists(CMD .. "/hello.lua"))

-- 2. a half-written queue line (no newline yet) waits until complete
write(CMD .. "/later.lua", "return function(log) return { later = true } end")
append(CMD .. "/queue.txt", "lat")
loop_fn()
check("partial queue line is not acted on", not exists(OUT .. "/later.json"))
append(CMD .. "/queue.txt", "er\n")
loop_fn()
check("completed line then runs", exists(OUT .. "/later.json"))

-- 3. a queued name whose file was withdrawn (Clear-ClientCmd) is skipped quietly; a file with no
--    queue entry is NOT picked up (no directory listing any more)
append(CMD .. "/queue.txt", "withdrawn\n")
write(CMD .. "/unqueued.lua", "return function(log) return { x = 1 } end")
loop_fn()
check("withdrawn entry: no answer, no error", not exists(OUT .. "/withdrawn.json"))
check("unqueued file is not run", not exists(OUT .. "/unqueued.json"))

-- 4. rotation: push the queue past 16 KB; entries appended around the rotation are not lost
local pad = string.rep("x", 60)
for k = 1, 300 do append(CMD .. "/queue.txt", "pad" .. k .. pad .. "\n") end
loop_fn() -- reads everything and rotates
write(CMD .. "/after.lua", "return function(log) return { after = true } end")
append(CMD .. "/queue.txt", "after\n")
loop_fn()
check("queue rotated (old file kept aside)", exists(CMD .. "/queue.txt.old"))
check("entry appended after the rotation runs", exists(OUT .. "/after.json"))

-- 5. no process was spawned on any poll
check("poll path never calls io.popen", popen_calls == 0, popen_calls)
check("poll path never calls os.execute", exec_calls == 0, exec_calls)

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
