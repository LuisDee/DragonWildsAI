-- Body side of the brain <-> body JSONL file bridge (brain/BRIDGE_PROTOCOL.md v1).
--
-- Reads brain_to_body.jsonl (tailed by byte offset), appends results/events/errors to
-- body_to_brain.jsonl. Polled on the game thread with LoopInGameThreadWithDelay, so
-- handlers may touch Unreal objects directly. Pure Lua 5.4 + io: ports to Linux UE4SS.
--
-- Prior art (idioms only, no code copied):
--   * ue4ss-bridge (littleRabbit94, MIT): UE4SS Lua file IPC polled every 50 ms from a
--     game-side loop, pcall around every handler so one bad request can't kill the loop.
--     It uses a single request.json/response.json pair; we use two append-only files
--     instead to avoid its read/write race. https://github.com/littleRabbit94/ue4ss-bridge
--   * MotorTownMods (drpsyko101): dedicated-server UE4SS Lua mod that polls non-blocking
--     LuaSocket from a game-thread loop; the same "never block the game thread" rule
--     applies here. https://github.com/drpsyko101/MotorTownMods
--   * File-size via f:seek("end") and seek-from-offset reading: Programming in Lua 21.3,
--     https://www.lua.org/pil/21.3.html . The tail itself mirrors brain/transport.py
--     (_read_new): read [offset, EOF), keep the trailing partial line, reset on truncation.
--   * UE4SS delayed actions API: https://docs.ue4ss.com/dev/lua-api/global-functions/delayedactions.html
-- No standalone pure-Lua "tail -f" library was found worth vendoring; the tail is ~25 lines.
local jsonutil = require("jsonutil") -- dkjson 2.8 (vendored, MIT) + shared encode/decode

local M = {}

M.V = 1
M.POLL_MS = 150
M.BRAIN_TO_BODY = "brain_to_body.jsonl"
M.BODY_TO_BRAIN = "body_to_brain.jsonl"

-- Tools named in the protocol. A known tool without a handler answers not_implemented;
-- anything else answers unknown_tool (as the mock does via GameInterface.call).
M.TOOLS = { "get_state", "follow", "stop", "go_to", "attack", "gather", "craft", "place", "give", "pickup", "drop", "say", "ping",
            "cast", "set_reflex_rule", "list_rules", "clear_rule", "sleep", "wake" }
local KNOWN = {}
for _, t in ipairs(M.TOOLS) do KNOWN[t] = true end

-- --------------------------------------------------------------------- JSON helpers
-- The protocol needs explicit nulls ("reason":null, "id":null) and {} objects. Handlers use
-- bridge.null for null and bridge.object(t) for a table that must encode as {} when empty.
-- Userdata (UObjects) and functions encode as their tostring(): never fatal.
M.null = jsonutil.null
M.object = jsonutil.object
M.encode = jsonutil.encode

-- --------------------------------------------------------------------- state
local cfg = { dir = nil, in_path = nil, out_path = nil, tail = nil, log = nil, handle = nil }
M.stats = { received = 0, malformed = 0, sent = 0, errors = 0 }

local function log(name, data)
    if cfg.log then pcall(cfg.log.event, name, data) end
end

local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size or 0
end

-- One write per line in append mode, so a reader never sees interleaved lines.
-- Binary mode: no \r\n translation on Windows, identical bytes on Linux.
function M.send(msg)
    local ok, line = pcall(M.encode, msg)
    if not ok then
        log("bridge_encode_error", { err = tostring(line) })
        line = M.encode({ v = M.V, type = "error", id = type(msg) == "table" and type(msg.id) == "string" and msg.id or M.null,
                          reason = "body_error", detail = "encode failed: " .. tostring(line) })
    end
    local f, err = io.open(cfg.out_path, "ab")
    if not f then
        log("bridge_write_error", { path = cfg.out_path, err = tostring(err) })
        return false
    end
    f:write(line .. "\n")
    f:close() -- close flushes
    M.stats.sent = M.stats.sent + 1
    return true
end

-- Push an unsolicited event, e.g. bridge.emit_event("attacked", {by = "wolf_2"}).
-- The event object is flat: {"type": name, ...data}, matching brain/interface.py.
function M.emit_event(name, data)
    local ev = {}
    for k, v in pairs(data or {}) do ev[k] = v end
    ev.type = name
    return M.send({ v = M.V, type = "event", event = ev })
end

local function send_error(id, reason, detail)
    M.stats.errors = M.stats.errors + 1
    M.send({ v = M.V, type = "error", id = id or M.null, reason = reason, detail = detail })
end

-- Send the one result for a command. Handlers that finish later (long actions) return
-- nil and call this themselves with ctx.id once the action succeeds, fails or is interrupted.
function M.reply(id, res)
    res = type(res) == "table" and res or { ok = false, reason = "body_error", data = { detail = "handler returned " .. type(res) } }
    local data = res.data
    if type(data) ~= "table" or next(data) == nil then data = M.object() end
    local ok = res.ok == true
    local reason = res.reason
    if reason == nil then reason = ok and M.null or "body_error" end
    return M.send({ v = M.V, type = "result", id = id, ok = ok, reason = reason, data = data })
end

-- --------------------------------------------------------------------- handlers
-- cmd name -> handler(args, ctx) returning {ok=, reason=, data=}, or nil if it will
-- call M.reply(ctx.id, ...) itself later. Register more with M.handlers[name] = fn.
M.handlers = {}

function M.not_implemented(tool)
    return { ok = false, reason = "not_implemented", data = { tool = tool } }
end

M.handlers.ping = function()
    return { ok = true, data = { pong = true, server_clock = os.clock(), server_time = os.time() } }
end

-- Every key BRIDGE_PROTOCOL.md requires in get_state data, with the shape of its empty value.
local STATE_KEYS = {
    { "position", "null" }, { "health", "null" }, { "inventory", "object" }, { "following", "null" },
    { "players", "array" }, { "nearby_entities", "array" }, { "nearby_resources", "array" },
    { "structures", "array" }, { "places", "array" },
}
local EMPTY = {
    null = function() return M.null end,
    object = function() return M.object() end,
    array = function() return {} end,
}

-- Stub until the state exporter exists. Carries every STATE_KEYS key (with null/empty
-- values) plus `not_implemented` listing the stubbed keys. ok=false so the brain never
-- treats placeholder values as verified state (principle 2). When some fields become
-- real, return ok=true and list only the still-missing keys.
M.handlers.get_state = function()
    local data, missing = {}, {}
    for i, k in ipairs(STATE_KEYS) do
        data[k[1]] = EMPTY[k[2]]()
        missing[i] = k[1]
    end
    data.not_implemented = missing
    return { ok = false, reason = "not_implemented", data = data }
end

local function handle(msg)
    local id = msg.id
    if msg.type ~= "cmd" or type(id) ~= "string" or type(msg.tool) ~= "string" then
        send_error(type(id) == "string" and id or nil, "malformed", "expected type=cmd with string id and tool")
        return
    end
    local tool = msg.tool
    local args = type(msg.args) == "table" and msg.args or {}
    -- The brain sends "probe": true at the top level of the cmd (brain/protocol.py); handlers
    -- (body/skills.lua probe_guard) read args.probe. Copy it so a probe never acts.
    if msg.probe == true and args.probe == nil then args.probe = true end
    local h = M.handlers[tool]
    local res
    if h then
        local ok, r = pcall(h, args, { id = id, tool = tool, msg = msg })
        if not ok then
            log("bridge_handler_error", { tool = tool, id = id, err = tostring(r) })
            r = { ok = false, reason = "body_error", data = { tool = tool, detail = tostring(r) } }
        end
        res = r
        if res == nil then return end -- async: the handler replies later
    elseif KNOWN[tool] then
        res = M.not_implemented(tool)
    else
        res = { ok = false, reason = "unknown_tool", data = { tool = tool } }
    end
    M.reply(id, res)
end

-- Parse one complete line: a table if it is a JSON object, else nil.
local function parse(text)
    if text:sub(1, 1) ~= "{" then return nil end -- arrays, scalars and junk are not objects
    local ok, v = pcall(jsonutil.decode, text)
    if ok and type(v) == "table" then return v end
    return nil
end

-- --------------------------------------------------------------------- tail + poll
-- A byte-offset tail of one JSONL file (BRIDGE_PROTOCOL.md "Files"): read [offset, EOF), keep the
-- trailing partial line, reset to 0 when the file shrinks or disappears. Exported so other readers
-- (the client body's chat events, client_mod/scripts/client_bridge.lua) reuse it.
-- M.new_tail(path, {from_start = bool}) -> t; t:read() -> list of raw line strings; t.offset.
function M.new_tail(path, opts)
    local t = { path = path, offset = (opts and opts.from_start) and 0 or file_size(path), partial = "" }
    function t:read()
        local f = io.open(self.path, "rb")
        if not f then
            if self.offset > 0 then self.offset, self.partial = 0, "" end -- file removed: treat as truncated
            return {}
        end
        local size = f:seek("end") or 0
        if size < self.offset then -- truncated or rotated: start over
            log("bridge_truncated", { path = self.path, size = size, offset = self.offset })
            self.offset, self.partial = 0, ""
        end
        if size == self.offset then
            f:close()
            return {}
        end
        f:seek("set", self.offset)
        local chunk = f:read(size - self.offset) or ""
        f:close()
        self.offset = self.offset + #chunk
        local buf = self.partial .. chunk
        local lines, start = {}, 1
        while true do
            local nl = buf:find("\n", start, true)
            if not nl then break end
            lines[#lines + 1] = buf:sub(start, nl - 1)
            start = nl + 1
        end
        self.partial = buf:sub(start) -- trailing partial line waits for the rest
        return lines
    end
    return t
end

-- Read new complete lines of the brain's file since the saved offset.
local function read_new_lines()
    return cfg.tail and cfg.tail:read() or {}
end

-- One poll step: handle every complete line that arrived. Returns the number of lines seen.
function M.poll()
    local lines = read_new_lines()
    for _, raw in ipairs(lines) do
        local text = raw:match("^%s*(.-)%s*$")
        if text ~= "" then
            M.stats.received = M.stats.received + 1
            local msg = parse(text)
            if msg then
                local ok, err = pcall(handle, msg)
                if not ok then log("bridge_dispatch_error", { err = tostring(err) }) end
            else
                M.stats.malformed = M.stats.malformed + 1
                log("bridge_malformed", { line = text:sub(1, 500) })
                send_error(nil, "malformed", text:sub(1, 200))
            end
        end
    end
    return #lines
end

-- Set paths and start offset without scheduling the loop (tests call this, then poll()).
-- opts: dir (default $DW_BRIDGE_DIR), log (dwlog-like module), from_start (bool),
-- in_name / out_name (file names; default M.BRAIN_TO_BODY / M.BODY_TO_BRAIN).
function M.init(opts)
    opts = opts or {}
    local dir = opts.dir or os.getenv("DW_BRIDGE_DIR")
    if not dir or dir == "" then return nil, "DW_BRIDGE_DIR not set" end
    dir = dir:gsub("[/\\]+$", "")
    cfg.dir, cfg.log = dir, opts.log
    -- File names are overridable per instance (the client body uses its own pair).
    cfg.in_path = dir .. "/" .. (opts.in_name or M.BRAIN_TO_BODY)
    cfg.out_path = dir .. "/" .. (opts.out_name or M.BODY_TO_BRAIN)
    -- Start at the current end so stale commands from an earlier run are ignored.
    cfg.tail = M.new_tail(cfg.in_path, { from_start = opts.from_start })
    return true
end

function M.paths() return { dir = cfg.dir, input = cfg.in_path, output = cfg.out_path, offset = cfg.tail and cfg.tail.offset or 0 } end

-- Init from the environment and poll on the game thread every POLL_MS.
function M.start(log_mod, opts)
    opts = opts or {}
    opts.log = opts.log or log_mod
    local ok, err = M.init(opts)
    if not ok then
        if opts.log then opts.log.event("bridge_disabled", { err = err }) end
        return false
    end
    local poll_ms = opts.poll_ms or M.POLL_MS
    cfg.handle = LoopInGameThreadWithDelay(poll_ms, function()
        local pok, perr = pcall(M.poll)
        if not pok then log("bridge_poll_error", { err = tostring(perr) }) end
    end)
    log("bridge_started", { dir = cfg.dir, poll_ms = poll_ms, offset = M.paths().offset })
    return true
end

function M.stop()
    if cfg.handle and CancelDelayedAction then pcall(CancelDelayedAction, cfg.handle) end
    cfg.handle = nil
end

return M
