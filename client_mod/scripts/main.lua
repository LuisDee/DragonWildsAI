-- DWClient: UE4SS mod for Claude's own game CLIENT (route R2, docs/design/real-player-remediation.md).
-- Drives the local player through the game's own client code paths. Two parts:
--  1. Command runner (kept as is; other tools use it): drop <name>.lua (returning function(log) -> table)
--     into <cmd_dir>; it runs on the game thread, and the result goes to <out_dir>/<name>.json
--     (tools/client_cmd.sh).
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

local function list_cmds()
    local names = {}
    local p = io.popen('dir /b "' .. CMD_DIR:gsub("/", "\\") .. '\\*.lua" 2>nul')
    if p then
        for line in p:lines() do names[#names + 1] = line end
        p:close()
    end
    return names
end

local function run_cmd(name)
    local path = CMD_DIR .. "/" .. name
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

os.execute('mkdir "' .. (ROOT .. "/logs/client"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. CMD_DIR:gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. OUT_DIR:gsub("/", "\\") .. '" 2>nul')
log("DWClient loaded (json=" .. (ok_json and "dkjson" or "fallback: " .. tostring(jsonutil)) .. ")")

-- Poll every 2 s on the game thread. dir via popen is cheap at this rate.
LoopInGameThreadWithDelay(2000, function()
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
