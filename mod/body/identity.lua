-- The puppet's identity: a DominionPlayerState so vanilla clients can name it (overhead nameplate
-- "Claude" instead of the widget default "Character Name Here"). DISCOVERIES "Nameplate / identity
-- (build 26161880)".
--
-- Mechanism: the nameplate is native (UPlayerNameplateComponent / UPlayerNameplateWidget, no
-- Blueprint logic, no name property on the pawn); the pawn's name comes from its PlayerState. A
-- server-spawned puppet possessed by a plain AIController has none (AIController only creates one
-- in PostInitializeComponents when bWantsPlayerState is already set, and InitPlayerState is not
-- reflected; re-possessing would unpossess, the crash path). So we spawn a DominionPlayerState and
-- wire it by hand:
--   SpawnActor(DominionPlayerState) -> SetOwner(ai) -> bIsABot -> OwnerGuid.CharacterGuid = bot GUID
--   (scalar writes) -> ai.PlayerState / pawn.PlayerState / ps.PawnPrivate -> GameMode:ChangeName
--   -> ForceNetUpdate.
-- Names are resolved by clients from GameState.DisplayNameComponent (account string + CharacterGuid).
-- The puppet PS has an empty AccountGuid, which the server keys as ","; register(",", bot GUID) ->
-- "Claude" with the PS's OWN OwnerGuid (no hand-built struct; verified it lands as account ",").
--
-- Safety: no client RPC, no hand-built struct, no unpossess. Every native call goes through U.call.
-- Disable with DW_PUPPET_IDENTITY=0. Server-side verified 2026-10-25 (no crash, PlayerArray=1,
-- GetPlayerName()="Claude"); client-side nameplate UNVERIFIED until Luis confirms.
local U = require("body.util")

local M = {}

M.PS_CLASS = "/Script/Dominion.DominionPlayerState"
M.NAME = "Claude"
M.GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 } -- = body.speech M.GUID

local st = { registered = false }

function M.enabled() return os.getenv("DW_PUPPET_IDENTITY") ~= "0" end

local function player_state(p)
    local ps = U.try(function() return p.PlayerState end)
    return U.alive(ps) and ps or nil
end
M.player_state = player_state

-- Is (an account WITH a platform id, bot GUID) -> name already in the sanitized registry?
-- Clients resolve nameplates (and chat senders) by account + CharacterGuid; an empty-account entry
-- (",") shows "Character Name Here" / "Unknown Character" (verified 2026-10-25).
local function is_registered(dn, name)
    local found = false
    pcall(function()
        dn.SanitizedCharacterNames:ForEach(function(_, elem)
            local e = elem:get()
            local acct = U.try(function() return e.AccountGuidSaveStr:ToString() end) or ""
            local n = U.try(function() return e.CharacterName:ToString() end)
            if acct:find(":", 1, true) and n == name and U.guid_eq(U.try(function() return e.CharacterGuid.InnerGuid end), M.GUID) then
                found = true
            end
        end)
    end)
    return found
end

-- Give the bot PS the host player's account part of OwnerGuid (engine struct copy from a live
-- struct, never built in Lua), keeping the bot's CharacterGuid. VERIFIED 2026-10-25: with this the
-- nameplate reads "Claude" on Luis's client. Returns true when copied.
local function copy_account(log, ps)
    local host
    for _, pc in ipairs(U.player_controllers()) do
        local hps = U.try(function() return pc.PlayerState end)
        if U.valid(hps) and hps ~= ps then host = hps; break end
    end
    if not host then return false end
    local ok = U.call(log, "identity.copy_account", { host = U.fullname(host) }, function()
        ps.OwnerGuid.AccountGuid = host.OwnerGuid.AccountGuid
        U.guid_set(ps.OwnerGuid.CharacterGuid.InnerGuid, M.GUID)
    end)
    return ok
end

-- Register the puppet PS's own OwnerGuid under `name` once per run (Server_RegisterCharacter appends
-- to SanitizedCharacterNames even when the entry exists, so check first).
function M.register(log, ps, name)
    name = name or M.NAME
    if st.registered then return true end
    local gs = U.try(function() return FindFirstOf("DominionGameStateBase") end)
    local dn = gs and U.try(function() return gs.DisplayNameComponent end)
    if not U.valid(dn) then return false, "no DisplayNameComponent" end
    if is_registered(dn, name) then st.registered = true; return true end
    local ok, err = U.call(log, "identity.Server_RegisterCharacter", { name = name }, function()
        dn:Server_RegisterCharacter(ps.OwnerGuid, name)
    end)
    st.registered = ok
    return ok, (not ok) and tostring(err) or nil
end

-- Ensure the AI-possessed puppet `p` (controller `c`) has a named DominionPlayerState.
-- Idempotent: returns U.result(true, "already") when it has one. Never unpossesses.
function M.ensure(log, p, c, name)
    name = name or M.NAME
    if not M.enabled() then return U.result(false, "disabled") end
    if not (U.alive(p) and U.alive(c)) then return U.result(false, "no_puppet") end
    if U.is_player_controller(c) then return U.result(false, "is_real_player") end
    local have = player_state(p)
    if have then
        copy_account(log, have)
        M.register(log, have, name)
        return U.result(true, "already", { ps = U.fullname(have) })
    end
    local cls = U.try(StaticFindObject, M.PS_CLASS)
    if not U.valid(cls) then return U.result(false, "class_not_found", { path = M.PS_CLASS }) end
    local loc = U.loc(p) or { X = 0, Y = 0, Z = 0 }
    local ok, ps = U.call(log, "identity.spawn_ps", { puppet = U.fullname(p) }, function()
        return p:GetWorld():SpawnActor(cls, { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not U.valid(ps) then return U.result(false, "spawn_failed", { err = tostring(ps) }) end
    U.call(log, "identity.SetOwner", {}, function() ps:SetOwner(c) end)
    U.call(log, "identity.bIsABot", {}, function() ps.bIsABot = true end)
    U.call(log, "identity.OwnerGuid", {}, function() U.guid_set(ps.OwnerGuid.CharacterGuid.InnerGuid, M.GUID) end)
    copy_account(log, ps)
    -- Register before linking, so the registry entry is there when clients first see the PS.
    local reg_ok, reg_err = M.register(log, ps, name)
    U.call(log, "identity.link", {}, function()
        c.PlayerState = ps
        p.PlayerState = ps
        ps.PawnPrivate = p
    end)
    U.call(log, "identity.ChangeName", { name = name }, function()
        FindFirstOf("DominionGameMode"):ChangeName(c, name, false)
    end)
    pcall(function() ps:ForceNetUpdate() end)
    pcall(function() p:ForceNetUpdate() end)
    local linked = player_state(p) ~= nil
    local pname = U.str(U.try(function() return ps:GetPlayerName() end))
    U.event(log, "puppet_identity", { ps = U.fullname(ps), linked = linked, name = pname, registered = reg_ok, reg_err = reg_err })
    return U.result(linked, (not linked) and "link_failed" or nil, { ps = U.fullname(ps), name = pname, registered = reg_ok })
end

function M._reset() st.registered = false end

return M
