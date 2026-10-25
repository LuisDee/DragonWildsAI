-- Debug triggers over the bridge (CLAUDE.md section 7 "Test via a debug trigger that bypasses the LLM").
-- debug_run {module, fn="run", args={}} reloads a mod module from disk and calls
-- module[fn](log, args) on the game thread (the bridge poll runs there), so experiments
-- can be iterated with Luis connected: deploy the new file, send debug_run, no restart.
-- Only plain module names are accepted (^[%w_]+$); the bridge files are local-only.
--
-- Lookup order: each directory in `dirs` in turn (main.lua passes <mod_root>/scripts, then
-- <mod_root>/experiments), so a name resolves to scripts/<name>.lua if it exists, else
-- experiments/<name>.lua. Keep names unique across both folders.
-- Only the named file is reloaded: modules it require()s (body.util, body.speech, ...) stay the
-- copies loaded at server start until a restart.
local M = {}

-- First "<dir>/<name>.lua" that exists, or nil plus the list of paths tried.
function M.resolve(dirs, name)
    local tried = {}
    for _, d in ipairs(dirs) do
        local path = d .. "/" .. name .. ".lua"
        local f = io.open(path, "rb")
        if f then f:close(); return path end
        tried[#tried + 1] = path
    end
    return nil, tried
end

-- dirs: a list of directories, or one directory string (the old signature).
-- Modules are loaded with loadfile on every call: clearing package.loaded + require was
-- verified NOT to pick up redeployed files under UE4SS.
function M.register(bridge, log, dirs)
    if type(dirs) == "string" then dirs = { dirs } end
    M.dirs = dirs
    bridge.handlers.debug_run = function(args)
        local name, fn = args.module, args.fn or "run"
        if type(name) ~= "string" or not name:match("^[%w_]+$") or type(fn) ~= "string" then
            return { ok = false, reason = "invalid_args", data = { detail = "module must match ^[%w_]+$" } }
        end
        local path, tried = M.resolve(dirs, name)
        if not path then
            return { ok = false, reason = "invalid_args", data = { stage = "resolve", detail = "no such module", tried = tried } }
        end
        local ok_req, mod = pcall(function()
            local chunk = assert(loadfile(path))
            return chunk()
        end)
        if not ok_req then
            return { ok = false, reason = "body_error", data = { stage = "require", path = path, detail = tostring(mod) } }
        end
        if type(mod) ~= "table" or type(mod[fn]) ~= "function" then
            return { ok = false, reason = "invalid_args", data = { detail = name .. "." .. fn .. " is not a function" } }
        end
        log.event("debug_run", { module = name, path = path, fn = fn, args = args.args })
        local ok_run, result = pcall(mod[fn], log, args.args or {})
        if not ok_run then
            return { ok = false, reason = "body_error", data = { stage = "run", detail = tostring(result) } }
        end
        return { ok = true, data = { result = result } }
    end
end

return M
