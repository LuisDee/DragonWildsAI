-- The bot on vanilla clients' world map and HUD compass, like another player.
--
-- How other players get there (dump, build 26161880; DISCOVERIES "Map and compass"):
--   AGameplayObjectRegistry (one per world, also UGameplayObjectSubsystem.ObjectRegistry) holds
--   PlayerCharacters : TArray<FPlayerCharacterData>, ReplicatedUsing=OnRep_PlayerCharacters, no
--   SaveGame flag. Element = {Location (FVector_NetQuantize), RotationByte (yaw/360*256),
--   OwningCharacterGuid (FDomCharacterGuid.InnerGuid), OwningPlayerUniqueID (FUniqueNetIdRepl),
--   OwningPlayerName, Color (FLinearColor = PlayerState.PlayerColor.Color), Identifier (FGuid)}.
--   UMapUIAPI and UCompassWidget read the registry (compass icons keyed by FGuid = Identifier;
--   EMapIconType.OtherPlayerCharacter = 2). The server adds an entry natively in
--   ADominionPlayerCharacter::OnWorldLoadedAroundCharacter, which needs a DominionPlayerState: the
--   puppet gets its PS only after possession, so that call logs "DominionPlayerState must be
--   valid" and the bot never gets an entry (verified: registry has Luis only, PlayerArray has both).
--
-- What this module does (UNVERIFIED on clients until Luis looks):
--   ensure(): append ONE entry for the bot, SCALAR fields only, Identifier = M.IDENT.
--   OwningPlayerUniqueID is left as UE4SS's AddZeroed leaves it = an empty net id, the same value
--   as the bot PS's own (empty) UniqueID. It is NOT copied in via the table: a struct userdata
--   nested in a Lua table crashes UE4SS (push_structproperty reads stack index 1; DISCOVERIES
--   "On-demand speech", crash_2026_10_25_15_45_24).
--   update(): rewrite that entry's Location/RotationByte from the puppet (found by Identifier
--   every time, since native removals shift indices). Push model is OFF, so writes replicate.
-- Limits: UE4SS TArray has no RemoveAt, so the entry can't be removed live; it is gone after a
-- restart (not saved). Reading PlayerCharacters[i] past Num GROWS the array (UE4SS AddZeroed), so
-- this module only reads through ForEach.
-- The proper fix (needs a puppet respawn, puppet.lua): link the PS to the AIController BEFORE
-- Possess, so APawn::PossessedBy copies it and the native OnWorldLoadedAroundCharacter registers the
-- bot itself. UNVERIFIED; that native path may also touch PlayerController-only state (R1-class).
local U = require("body.util")

local M = {}

M.NAME = os.getenv("DW_COMPANION_NAME") or "Claude"
M.CHAR_GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 } -- = speech.GUID
M.IDENT = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x0000A11E }     -- registry entry id
M.COLOR = { R = 0.851, G = 0.467, B = 0.341, A = 1.0 }                            -- Claude orange
M.INTERVAL_MS = 1000

local function state()
    local s = rawget(_G, "__dw_presence")
    if not s then
        s = { looping = false, stop = false, updates = 0, last_err = nil, added = 0 }
        rawset(_G, "__dw_presence", s)
    end
    return s
end

function M.registry()
    local sub = U.find_first("GameplayObjectSubsystem")
    local reg = sub and U.try(function() return sub.ObjectRegistry end)
    if U.alive(reg) then return reg end
    return U.find_first("GameplayObjectRegistry")
end

-- 1-based index of the entry whose Identifier is `ident` (default M.IDENT), plus Num.
function M.find_entry(reg, ident)
    ident = ident or M.IDENT
    local idx, n = nil, 0
    pcall(function()
        reg.PlayerCharacters:ForEach(function(i, elem)
            n = i
            if not idx and U.guid_eq(U.try(function() return elem:get().Identifier end), ident) then idx = i end
        end)
    end)
    return idx, n
end

local function rot_byte(p)
    local yaw = U.try(function() return p:K2_GetActorRotation().Yaw end) or 0
    return math.floor(((yaw % 360) / 360) * 256) % 256
end

local function bot_color(ps)
    local c = U.try(function() local k = ps.PlayerColor.Color; return { R = k.R, G = k.G, B = k.B, A = k.A } end)
    if c and (c.R + c.G + c.B) > 0 then return c end
    return M.COLOR
end

-- Append the bot's entry if missing. Returns U.result.
function M.ensure(log, p)
    if not U.alive(p) then return U.result(false, "no_puppet") end
    local ps = U.try(function() return p.PlayerState end)
    if not U.alive(ps) then return U.result(false, "no_player_state") end
    local reg = M.registry()
    if not reg then return U.result(false, "no_registry") end
    local idx, n = M.find_entry(reg)
    if idx then return U.result(true, "already", { index = idx, num = n }) end
    local loc = U.loc(p) or { X = 0, Y = 0, Z = 0 }
    local c = bot_color(ps)
    local entry = {
        Location = { X = loc.X, Y = loc.Y, Z = loc.Z },
        RotationByte = rot_byte(p),
        OwningCharacterGuid = { InnerGuid = { A = M.CHAR_GUID.A, B = M.CHAR_GUID.B, C = M.CHAR_GUID.C, D = M.CHAR_GUID.D } },
        -- OwningPlayerUniqueID: deliberately absent (zeroed = empty id); never a userdata in a table
        OwningPlayerName = M.NAME,
        Color = { R = c.R, G = c.G, B = c.B, A = c.A },
        Identifier = { A = M.IDENT.A, B = M.IDENT.B, C = M.IDENT.C, D = M.IDENT.D },
    }
    local ok, err = U.call(log, "presence.append_PlayerCharacters", { num = n }, function()
        reg.PlayerCharacters[n + 1] = entry
    end)
    pcall(function() reg:ForceNetUpdate() end)
    local idx2, n2 = M.find_entry(reg)
    if ok and idx2 then state().added = state().added + 1 end
    U.event(log, "presence_ensure", { ok = ok, err = (not ok) and tostring(err) or nil, index = idx2, num = n2 })
    return U.result(ok and idx2 ~= nil, (not ok) and "body_error" or (idx2 == nil and "not_added" or nil),
                    { index = idx2, num = n2, err = (not ok) and tostring(err) or nil })
end

-- Rewrite the bot entry's Location/RotationByte. Scalar writes only.
function M.update(log, p)
    if not U.alive(p) then return false, "no_puppet" end
    local reg = M.registry()
    if not reg then return false, "no_registry" end
    local idx = M.find_entry(reg)
    if not idx then return false, "no_entry" end
    local loc = U.loc(p)
    if not loc then return false, "no_location" end
    local rb = rot_byte(p)
    local ok, err = pcall(function()
        reg.PlayerCharacters:ForEach(function(i, elem)
            if i == idx then
                local e = elem:get()
                e.Location.X, e.Location.Y, e.Location.Z = loc.X, loc.Y, loc.Z
                e.RotationByte = rb
            end
        end)
    end)
    local s = state()
    if ok then s.updates = s.updates + 1 else s.last_err = tostring(err) end
    return ok, (not ok) and tostring(err) or nil
end

-- Game-thread loop, once per run (survives experiment reloads). get_puppet() -> pawn or nil.
function M.start(log, get_puppet)
    local s = state()
    s.stop = false
    rawset(_G, "__dw_presence_get", get_puppet)
    if s.looping then return { started = false, already = true } end
    if type(LoopInGameThreadWithDelay) ~= "function" then return { started = false, err = "no LoopInGameThreadWithDelay" } end
    s.looping = true
    s.handle = LoopInGameThreadWithDelay(M.INTERVAL_MS, function()
        local st = state()
        if st.stop then return end
        local get = rawget(_G, "__dw_presence_get")
        local p = get and U.try(get)
        if p then M.update(nil, p) end
    end)
    return { started = true }
end

-- Returning true does NOT end a LoopInGameThreadWithDelay loop (DISCOVERIES Spells); cancel it.
function M.stop()
    local s = state()
    s.stop = true
    if s.handle and CancelDelayedAction then pcall(CancelDelayedAction, s.handle) end
    s.handle, s.looping = nil, false
end

function M.status()
    local s = state()
    local reg = M.registry()
    local idx, n
    if reg then idx, n = M.find_entry(reg) end
    return { registry = U.short(reg), entry_index = idx, num = n, looping = s.looping, updates = s.updates,
             added = s.added, last_err = s.last_err, ident = U.guid_hex(M.IDENT) }
end

function M._reset() rawset(_G, "__dw_presence", nil); rawset(_G, "__dw_presence_get", nil) end

return M
