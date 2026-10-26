-- Read-only sampler for an AllowMovementThenCastInstant spell (Recall; re-run 2026-10-26: it stayed "prepared",
-- no runes spent, no cooldown). Queue this, then cast Recall through the bridge, then (optionally) walk a few metres
-- and cast it again: every 0.5 s for 40 s it records what the game shows, so we learn what makes it go off.
-- Output: client_io/out/recall_probe.jsonl (one line per sample). Presses nothing.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local SPELL = "USD_Recall"
return function(log)
    local SP = assert(loadfile(ROOT .. "/client_mod/scripts/spells.lua"))()
    local json = assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    local path = ROOT .. "/client_io/out/recall_probe.jsonl"
    local f0 = io.open(path, "w"); if f0 then f0:close() end
    local n, t0 = 0, os.clock()
    local api = { module = function() return nil end }
    LoopInGameThreadWithDelay(500, function()
        n = n + 1
        if n > 80 or rawget(_G, "DW_PAUSE") then return true end
        local ok, s = pcall(SP.W.snapshot, api)
        if not ok or type(s) ~= "table" then return false end
        local actors = {}
        for id, a in pairs(s.actors or {}) do actors[#actors + 1] = id .. ":" .. tostring(a.class) end
        local row = { i = n, t = os.clock() - t0, casting = s.casting, casting_name = s.casting_name, mode = s.input_mode,
                      last_cast = s.last_cast and s.last_cast[SPELL], air = s.items and s.items.ITEM_Rune_Air,
                      law = s.items and s.items.ITEM_Rune_Law, position = s.position, falling = s.falling, actors = actors,
                      tags = s.tags, ge = s.ge }
        local f = io.open(path, "a")
        if f then f:write(json.encode(row), "\n"); f:close() end
        return false
    end)
    return { ok = true, out = path, note = "sampling 40 s; cast Recall now" }
end
