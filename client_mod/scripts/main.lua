-- DWClient: UE4SS mod for Claude's own game CLIENT (route R2, docs/design/real-player-remediation.md).
-- Drives the local player through the game's own client code paths. Two parts:
--  1. Command runner: write <cmd_dir>/<name>.lua (returning function(log) -> table), THEN append the
--     line "<name>" to <cmd_dir>/queue.txt; it runs on the game thread, and the result goes to
--     <out_dir>/<name>.json (tools/client_cmd.sh, tools/client_lib.ps1 Invoke-ClientCmd).
--     NO PROCESS SPAWNING on the poll path (L28, 2026-10-26 07:14: the client hung with the GameThread
--     in NtReadFile <- fgetc reading an `io.popen('dir /b ...')` pipe). The queue is a plain file read
--     from a saved byte offset, like the bridge's JSONL (docs/design/client-runner-queue.md).
--  2. The brain bridge: client_mod/scripts/client_bridge.lua, loaded with loadfile so it (and the client
--     modules it dispatches to) can be reloaded WITHOUT a client restart: run
--     client_mod/commands/bridge_start.lua through the runner. DW_CLIENT_BRIDGE=0 disables the autostart.
-- Paths are lowercase/relative-friendly for the Linux port; override the root with DW_CLIENT_ROOT.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local LOG_PATH = ROOT .. "/logs/client/client.log"
local CMD_DIR = ROOT .. "/client_io/cmd"
local OUT_DIR = ROOT .. "/client_io/out"
-- Shared JSON (dkjson via mod/scripts/jsonutil.lua), the same one the bridge uses.
package.path = ROOT .. "/mod/scripts/?.lua;" .. package.path

local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), tostring(msg), "\n"); f:close() end
    print("[DWClient] " .. tostring(msg) .. "\n")
end

-- Fallback encoder, used only if jsonutil cannot load.
local function encode_fallback(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "table" and depth < 6 then
        local parts, is_list = {}, #v > 0
        for k, x in pairs(v) do
            local val = encode_fallback(x, depth + 1)
            parts[#parts + 1] = is_list and val or string.format("%q:%s", tostring(k), val)
        end
        return is_list and ("[" .. table.concat(parts, ",") .. "]") or ("{" .. table.concat(parts, ",") .. "}")
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif v == nil then return "null"
    else return string.format("%q", tostring(v)) end
end
local ok_json, jsonutil = pcall(require, "jsonutil")
local encode = ok_json and jsonutil.encode or encode_fallback

-- Queue reader: new complete lines of <cmd_dir>/queue.txt since the saved offset (plain file I/O).
-- Rotation: once fully read and over QUEUE_ROTATE bytes, the queue is renamed and the renamed file is
-- drained once more (a writer appending between our read and the rename is not lost); writers open
-- the queue by name for every append, so they simply start a new one.
local QUEUE = CMD_DIR .. "/queue.txt"
local QUEUE_ROTATE = 16384
local qstate = { offset = 0, partial = "" }

local function read_new(path, from)
    local f = io.open(path, "rb")
    if not f then return nil, 0 end
    local size = f:seek("end") or 0
    if size < from then from = 0 end -- the file was replaced: start over
    f:seek("set", from)
    local data = f:read("a") or ""
    f:close()
    return data, from + #data
end

local function split_names(st, data, names, seen)
    local buf = st.partial .. data
    local last = 1
    for line, nl in buf:gmatch("([^\r\n]*)\r?\n()") do
        last = nl
        local n = line:gsub("%s+$", "")
        if n ~= "" and n:match("^[%w_%-%.]+$") and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    st.partial = buf:sub(last)
end

local function list_cmds()
    local names, seen = {}, {}
    local data, off = read_new(QUEUE, qstate.offset)
    if data then
        qstate.offset = off
        split_names(qstate, data, names, seen)
        if off >= QUEUE_ROTATE and qstate.partial == "" then
            local old = QUEUE .. ".old"
            os.remove(old)
            if os.rename(QUEUE, old) then
                local rest = read_new(old, off)
                if rest and #rest > 0 then split_names(qstate, rest, names, seen) end
                qstate.offset, qstate.partial = 0, ""
            end
        end
    end
    for i, n in ipairs(names) do names[i] = n:match("%.lua$") and n or (n .. ".lua") end
    return names
end

local function run_cmd(name)
    local path = CMD_DIR .. "/" .. name
    do -- a queue entry whose file was withdrawn (Clear-ClientCmd) or already run: nothing to do
        local f = io.open(path, "rb")
        if not f then return end
        f:close()
    end
    local chunk, err = loadfile(path)
    os.remove(path)
    local result
    if not chunk then
        result = { ok = false, error = "load: " .. tostring(err) }
    else
        local ok, fn = pcall(chunk)
        if ok and type(fn) == "function" then
            local ok2, res = pcall(fn, log)
            result = ok2 and { ok = true, result = res } or { ok = false, error = tostring(res) }
        else
            result = { ok = false, error = "chunk must return a function: " .. tostring(fn) }
        end
    end
    local f = io.open(OUT_DIR .. "/" .. name:gsub("%.lua$", ".json"), "w")
    if f then f:write(encode(result)); f:close() end
    log("ran " .. name .. " ok=" .. tostring(result.ok))
end

-- Directories: created ONCE at load, and only if missing (an open-for-append probe; no process
-- unless the directory really is absent).
local function ensure_dir(d)
    local probe = d .. "/.dwclient_probe"
    local f = io.open(probe, "a")
    if f then f:close(); os.remove(probe); return end
    os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
end
ensure_dir(ROOT .. "/logs/client")
ensure_dir(CMD_DIR)
ensure_dir(OUT_DIR)
-- Start AFTER anything already queued before this load: those entries were for a previous client run.
do local _, off = read_new(QUEUE, 0); qstate.offset = off or 0 end
log("DWClient loaded (json=" .. (ok_json and "dkjson" or "fallback: " .. tostring(jsonutil)) .. ", runner=queue)")

-- Poll on the game thread: a plain read of the queue file (no process), so a 500 ms cadence is cheap.
LoopInGameThreadWithDelay(500, function()
    for _, name in ipairs(list_cmds()) do
        local ok, err = pcall(run_cmd, name)
        if not ok then log("runner error: " .. tostring(err)) end
    end
end)

-- Brain bridge (client_bridge.lua). Started on the game thread; it polls the brain's file every 100 ms.
-- Harmless at the main menu: get_state answers companion_down until the pawn exists.
if os.getenv("DW_CLIENT_BRIDGE") ~= "0" then
    ExecuteInGameThread(function()
        local ok, res = pcall(function()
            local B = assert(loadfile(ROOT .. "/client_mod/scripts/client_bridge.lua"))()
            return B.start({ root = ROOT, log = log, start_modules = true })
        end)
        log("bridge autostart ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(res))))
    end)
end
