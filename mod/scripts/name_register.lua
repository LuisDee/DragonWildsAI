-- Register display name "Claude" under (Luis's account, bot CharacterGuid) so chat lines relayed
-- with the bot's CharacterGuid resolve to "Claude" on clients (names_probe showed the registry is
-- keyed by account string + character guid; an empty-account entry never matches).
-- The account part (FDomOnlineCapableAccountGuid) can't be built from Lua safely, so we reuse Luis's
-- real PlayerState.OwnerGuid: swap its CharacterGuid to the bot's, register, restore - same tick.
-- debug_run {module="name_register"}. Server-side only.
local M = {}

local BOT_GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }

local function try(f) local ok, v = pcall(f); if ok then return v end end

function M.run(log, args)
    local name = args.name or "Claude"
    local pc
    for _, c in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
        if try(function() return c:IsValid() end) then pc = c; break end
    end
    if not pc then return { ok = false, error = "no connected player" } end
    local ps = pc.PlayerState
    local gs = FindFirstOf("DominionGameStateBase")
    local g = ps.OwnerGuid.CharacterGuid.InnerGuid
    local saved = { A = g.A, B = g.B, C = g.C, D = g.D }
    log.event("name_register_begin", { saved = saved })
    local ok, err = pcall(function()
        g.A, g.B, g.C, g.D = BOT_GUID.A, BOT_GUID.B, BOT_GUID.C, BOT_GUID.D
        gs.DisplayNameComponent:Server_RegisterCharacter(ps.OwnerGuid, name)
    end)
    g.A, g.B, g.C, g.D = saved.A, saved.B, saved.C, saved.D -- always restore Luis's identity
    local restored = (g.A == saved.A and g.B == saved.B and g.C == saved.C and g.D == saved.D)
    log.event("name_register", { ok = ok, err = (not ok) and tostring(err) or nil, restored = restored })
    return { ok = ok, err = (not ok) and tostring(err) or nil, restored = restored }
end

return M
