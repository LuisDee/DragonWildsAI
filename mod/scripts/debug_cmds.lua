-- Debug triggers over the bridge (CLAUDE.md section 7 "Test via a debug trigger that bypasses the LLM").
-- debug_run {module, fn="run", args={}} reloads a mod module from disk and calls
-- module[fn](log, args) on the game thread (the bridge poll runs there), so experiments
-- can be iterated with Luis connected: deploy the new file, send debug_run, no restart.
-- Only plain module names under the mod are accepted; the bridge files are local-only.
local M = {}

-- scripts_dir: <mod_root>/scripts. Modules are loaded with loadfile from there on every call:
-- clearing package.loaded + require was verified NOT to pick up redeployed files under UE4SS.
function M.register(bridge, log, scripts_dir)
    bridge.handlers.debug_run = function(args)
        local name, fn = args.module, args.fn or "run"
        if type(name) ~= "string" or not name:match("^[%w_]+$") or type(fn) ~= "string" then
            return { ok = false, reason = "invalid_args", data = { detail = "module must match ^[%w_]+$" } }
        end
        local ok_req, mod = pcall(function()
            local chunk = assert(loadfile(scripts_dir .. "/" .. name .. ".lua"))
            return chunk()
        end)
        if not ok_req then
            return { ok = false, reason = "body_error", data = { stage = "require", detail = tostring(mod) } }
        end
        if type(mod) ~= "table" or type(mod[fn]) ~= "function" then
            return { ok = false, reason = "invalid_args", data = { detail = name .. "." .. fn .. " is not a function" } }
        end
        log.event("debug_run", { module = name, fn = fn, args = args.args })
        local ok_run, result = pcall(mod[fn], log, args.args or {})
        if not ok_run then
            return { ok = false, reason = "body_error", data = { stage = "run", detail = tostring(result) } }
        end
        return { ok = true, data = { result = result } }
    end
end

return M
