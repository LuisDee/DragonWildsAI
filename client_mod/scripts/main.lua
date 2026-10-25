-- DWClient: UE4SS mod for Claude's own game CLIENT (route R2, docs/design/real-player-remediation.md).
-- Drives the local player through the game's own client code paths. For now it is a hot-load
-- command runner: drop <name>.lua (returning function(log) -> table) into <cmd_dir>; it runs on the
-- game thread, and the result goes to <out_dir>/<name>.json. Paths are lowercase/relative-friendly
-- for the Linux port; override the root with DW_CLIENT_ROOT.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local LOG_PATH = ROOT .. "/logs/client/client.log"
local CMD_DIR = ROOT .. "/client_io/cmd"
local OUT_DIR = ROOT .. "/client_io/out"

local function log(msg)
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), tostring(msg), "\n"); f:close() end
    print("[DWClient] " .. tostring(msg) .. "\n")
end

local function encode(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "table" and depth < 6 then
        local parts, is_list = {}, #v > 0
        for k, x in pairs(v) do
            local val = encode(x, depth + 1)
            parts[#parts + 1] = is_list and val or string.format("%q:%s", tostring(k), val)
        end
        return is_list and ("[" .. table.concat(parts, ",") .. "]") or ("{" .. table.concat(parts, ",") .. "}")
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif v == nil then return "null"
    else return string.format("%q", tostring(v)) end
end

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
log("DWClient loaded")

-- Poll every 2 s on the game thread. dir via popen is cheap at this rate.
LoopInGameThreadWithDelay(2000, function()
    for _, name in ipairs(list_cmds()) do
        local ok, err = pcall(run_cmd, name)
        if not ok then log("runner error: " .. tostring(err)) end
    end
end)
