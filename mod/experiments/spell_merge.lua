-- Offline (plain Lua 5.4, no game): re-merge body/spells.lua usage metadata into the X1 catalog.
-- Usage: lua mod/experiments/spell_merge.lua [data/spells_26161880.json]
-- The in-game dump (mod/scripts/spell_dump.lua) already merges once; run this after editing
-- spells.lua META so the catalog the brain reads stays in sync without another game run.
local here = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$")) or "."
package.path = here .. "/../?.lua;" .. here .. "/../scripts/?.lua;" .. package.path
local jsonutil = require("jsonutil")
local spells = require("body.spells")

local path = arg[1] or (here .. "/../../data/spells_" .. spells.BUILD .. ".json")
local f = assert(io.open(path, "rb"))
local doc = assert(jsonutil.decode(f:read("*a")))
f:close()

-- restore empty-object markers dkjson needs for stable output
local function objectify(t, depth)
    if type(t) ~= "table" or depth > 12 then return end
    if next(t) == nil then return end
    local is_array = #t > 0
    if not is_array then jsonutil.object(t) end
    for _, v in pairs(t) do objectify(v, depth + 1) end
end
objectify(doc, 0)
for _, rec in pairs(doc.spells or {}) do
    if type(rec.runes) == "table" then jsonutil.object(rec.runes) end
end

spells.merge_catalog(doc)
doc.meta_merged_offline_at = os.time()
local out = assert(io.open(path, "wb"))
out:write(jsonutil.encode(doc))
out:close()
local n, missing = 0, #(doc.meta_missing or {})
for _ in pairs(doc.spells or {}) do n = n + 1 end
print(("merged usage into %d spells (%d without META) -> %s"):format(n, missing, path))
