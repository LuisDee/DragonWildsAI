-- Debug triggers over the bridge (CLAUDE.md section 7 "Test via a debug trigger that bypasses the LLM").
-- debug_run {module, fn="run", args={}} reloads a mod module from disk and calls
-- module[fn](log, args) on the game thread (the bridge poll runs there), so experiments
-- can be iterated with Luis connected: deploy the new file, send debug_run, no restart.
-- Only plain module names under the mod are accepted; the bridge files are local-only.
local M = {}

function M.register(bridge, log)
    bridge.handlers.debug_run = function(args)
        local name, fn = args.module, args.fn or "run"
        if type(name) ~= "string" or not name:match("^[%w_]+$") or type(fn) ~= "string" then
            return { ok = false, reason = "invalid_args", data = { detail = "module must match ^[%w_]+$" } }
        end
        package.loaded[name] = nil -- pick up the freshly deployed file
        local ok_req, mod = pcall(require, name)
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
