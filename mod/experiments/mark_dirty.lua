-- Push-model replication fix: the server runs net.IsPushModelEnabled=1, so a raw Lua property
-- write is NOT replicated unless the property is marked dirty. UNetPushModelHelpers:MarkPropertyDirty
-- (Object, FName) is Blueprint-callable with simple args. debug_run {module="mark_dirty"} marks the
-- puppet's identity properties (written by body/identity.lua and identity_platform) dirty.
local U = require("body.util")
local M = {}

local PAWN_PROPS = { "PlayerState" }
local PS_PROPS = { "PlayerNamePrivate", "PlayerId", "bIsABot", "PlatformData", "PlayerColor", "OwnerGuid", "Owner" }

function M.run(log, args)
    local _, puppets = U.split_pawns()
    local p = puppets[1]
    if not U.valid(p) then return { ok = false, error = "no puppet" } end
    local lib = StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
    if not U.valid(lib) then return { ok = false, error = "NetPushModelHelpers CDO not found" } end
    local ps = U.try(function() return p.PlayerState end)
    local out = { pawn = {}, ps = {}, ps_name = U.fullname(ps) }
    for _, prop in ipairs(PAWN_PROPS) do
        out.pawn[prop] = U.call(log, "mark_dirty.pawn", { prop = prop }, function() lib:MarkPropertyDirty(p, FName(prop)) end)
    end
    if U.valid(ps) then
        for _, prop in ipairs(args.ps_props or PS_PROPS) do
            out.ps[prop] = U.call(log, "mark_dirty.ps", { prop = prop }, function() lib:MarkPropertyDirty(ps, FName(prop)) end)
        end
        U.call(log, "mark_dirty.ps_netupdate", {}, function() ps:ForceNetUpdate() end)
    end
    U.call(log, "mark_dirty.pawn_netupdate", {}, function() p:ForceNetUpdate() end)
    return out
end

return M
