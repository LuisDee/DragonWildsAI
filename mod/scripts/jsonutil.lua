-- Shared JSON for the mod (dwlog + bridge), on top of vendored dkjson.lua (David Kolf, MIT,
-- dkjson 2.8 from https://dkolf.de/dkjson-lua/). dkjson already gives us explicit nulls
-- (json.null), empty objects (metatable __jsontype = "object") and cycle detection; the
-- exception handler below turns userdata (UObjects), functions and cycles into strings so
-- encoding a log event or a reply is never fatal on the game thread.
local json = require("dkjson")

local M = {}

M.null = json.null            -- encodes as null
M.MAX_DEPTH = 32              -- fallback walk only (see sanitize)
local OBJECT_MT = { __jsontype = "object" }

-- Mark t (default {}) so it encodes as {} even when empty. Returns t.
function M.object(t) return setmetatable(t or {}, OBJECT_MT) end

local function on_exception(reason, value, _, msg)
    if reason == "unsupported type" then return json.quotestring(tostring(value)) end
    return json.quotestring("<" .. tostring(msg) .. ">") -- e.g. "<reference cycle>"
end

-- dkjson rejects keys that are not strings or numbers (no exception hook for keys), so on
-- that error re-encode a copy with stringified keys. Depth-capped as a guard.
local function sanitize(v, depth)
    if type(v) ~= "table" or v == M.null then return v end
    if depth >= M.MAX_DEPTH then return "<max depth>" end
    local out = {}
    for k, x in pairs(v) do
        local kt = type(k)
        out[(kt == "string" or kt == "number") and k or tostring(k)] = sanitize(x, depth + 1)
    end
    if getmetatable(v) == OBJECT_MT then setmetatable(out, OBJECT_MT) end
    return out
end

-- Fresh state table per call: dkjson keeps its buffer in the state and would reuse a stale
-- one after an error.
function M.encode(v)
    local ok, s = pcall(json.encode, v, { exception = on_exception })
    if ok then return s end
    return json.encode(sanitize(v, 0), { exception = on_exception })
end

-- Decode one JSON document. Returns the value, or nil plus an error message. JSON null
-- decodes to nil. Trailing non-whitespace is an error (dkjson alone would ignore it).
function M.decode(text)
    local v, pos, err = json.decode(text)
    if err then return nil, err end
    if pos and text:find("%S", pos) then return nil, "trailing data at " .. pos end
    return v
end

return M
