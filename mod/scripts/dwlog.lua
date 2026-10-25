-- Append-only JSONL logger. One file per server run; Claude/the brain reads it, Luis never pastes it.
local json = require("json") -- rxi/json.lua v0.1.2 (vendored, MIT)

local M = {}
local file_path

-- dir must already exist (tools/deploy_mod.ps1 creates it).
function M.init(dir)
    file_path = dir .. "/mod_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl"
end

function M.path() return file_path end

-- Unreal objects and other userdata aren't JSON; stringify anything json.lua rejects.
local function safe(v)
    local t = type(v)
    if t == "table" then
        local out = {}
        for k, x in pairs(v) do out[tostring(k)] = safe(x) end
        return out
    elseif t == "string" or t == "number" or t == "boolean" or t == "nil" then
        return v
    end
    return tostring(v)
end

function M.event(name, data)
    local f = io.open(file_path, "a")
    if not f then
        print("[DWCompanion] cannot open log file " .. tostring(file_path) .. "\n")
        return
    end
    local ok, line = pcall(json.encode, { ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), event = name, data = safe(data or {}) })
    f:write(ok and line or json.encode({ event = "log_encode_error", data = { name = name, err = tostring(line) } }), "\n")
    f:close()
end

return M
