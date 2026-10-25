-- Nameplate experiment: copy Luis's account part of OwnerGuid onto the bot's PlayerState (engine
-- struct copy from a live struct, never built in Lua), keep the bot's own CharacterGuid, so a client
-- lookup of (account, CharacterGuid) hits the registered "Claude" entry (as chat names did).
-- debug_run {module="owner_account", args={action="apply"|"read"}}. Reversible by respawning the bot.
local U = require("body.util")
local M = {}

local BOT = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }

local function hex(g) return g and string.format("%08X-%08X-%08X-%08X", g.A % 2^32, g.B % 2^32, g.C % 2^32, g.D % 2^32) end

local function read(ps)
    local g = U.try(function() return ps.OwnerGuid.CharacterGuid.InnerGuid end)
    local lib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    return { ps = U.fullname(ps), char_guid = g and hex(g) }
end

function M.run(log, args)
    local players, puppets = U.split_pawns()
    local luis, bot = players[1], puppets[1]
    if not (U.valid(luis) and U.valid(bot)) then return { ok = false, error = "need Luis and the bot" } end
    local lps, bps = luis.PlayerState, bot.PlayerState
    if not (U.valid(lps) and U.valid(bps)) then return { ok = false, error = "missing PlayerState" } end
    if args.action == "apply" then
        local ok, err = U.call(log, "owner_account.copy", {}, function()
            bps.OwnerGuid.AccountGuid = lps.OwnerGuid.AccountGuid -- engine struct copy (CopyCompleteValue)
            local g = bps.OwnerGuid.CharacterGuid.InnerGuid
            g.A, g.B, g.C, g.D = BOT.A, BOT.B, BOT.C, BOT.D
            bps:ForceNetUpdate()
        end)
        U.call(log, "owner_account.onrep", {}, function() bps:OnRep_OwnerGuidUpdated() end)
        return { applied = ok, err = err and tostring(err), luis = read(lps), bot = read(bps) }
    end
    return { luis = read(lps), bot = read(bps) }
end

return M
