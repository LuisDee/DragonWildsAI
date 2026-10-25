-- Read-only: dump the game's character display-name registry (GameState.DisplayNameComponent).
-- debug_run {module="names_probe"}. Server-side reads only; nothing is sent to clients.
local M = {}

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function hex(n) return n and string.format("%08X", n % 0x100000000) or nil end

local function entries(arr)
    local out = {}
    pcall(function()
        arr:ForEach(function(_, elem)
            local e = elem:get()
            local g = try(function() return e.CharacterGuid.InnerGuid end)
            out[#out + 1] = {
                account = try(function() return e.AccountGuidSaveStr:ToString() end),
                character_guid = g and (hex(g.A) .. hex(g.B) .. hex(g.C) .. hex(g.D)) or nil,
                name = try(function() return e.CharacterName:ToString() end),
            }
        end)
    end)
    return out
end

function M.run()
    local gs = FindFirstOf("DominionGameStateBase")
    local dn = gs and try(function() return gs.DisplayNameComponent end)
    if not dn then return { ok = false, error = "no DisplayNameComponent" } end
    return {
        original = entries(dn.OriginalCharacterNames),
        sanitized = entries(dn.SanitizedCharacterNames),
    }
end

return M
