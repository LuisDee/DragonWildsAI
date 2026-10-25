-- Append-only JSONL logger. One file per server run; Claude/the brain reads it, Luis never pastes it.
local jsonutil = require("jsonutil")

local M = {}
local file_path, file

-- Keep one handle open for the run. Each event is one write followed by a flush, so lines
-- are on disk immediately even if the server is killed. (setvbuf("line") is not used: the
-- Windows CRT treats line buffering as full buffering.)
local function open()
    local f, err = io.open(file_path, "a")
    if not f then
        print("[DWCompanion] cannot open log file " .. tostring(file_path) .. ": " .. tostring(err) .. "\n")
        return nil
    end
    file = f
    return f
end

-- dir must already exist (tools/deploy_mod.ps1 creates it).
function M.init(dir)
    if file then file:close() end
    file = nil
    file_path = dir .. "/mod_" .. os.date("!%Y%m%dT%H%M%SZ") .. ".jsonl"
    open()
end

function M.path() return file_path end

function M.event(name, data)
    local f = file or open() -- retry each event if the first open failed
    if not f then return end
    local ok, line = pcall(jsonutil.encode, { ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), event = name, data = data or {} })
    if not ok then line = jsonutil.encode({ event = "log_encode_error", data = { name = name, err = tostring(line) } }) end
    f:write(line .. "\n")
    f:flush()
end

return M
