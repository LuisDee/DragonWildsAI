-- Read-only identity probe for the nameplate work (DISCOVERIES "Nameplate / identity").
-- debug_run {module="identity_probe"}. Server-side reads only; nothing is sent to clients.
-- Reports, for every BP_PlayerCharacter_C: controller, PlayerState (class, PlayerName, PlayerId,
-- bIsABot, OwnerGuid.CharacterGuid, PlayerColor, PlatformData.DisplayName), the nameplate
-- component, and the game mode's PlayerStateClass / DefaultPlayerName.
local M = {}

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function hex(n) return n and string.format("%08X", n % 0x100000000) or nil end
local function fullname(o) return o and try(function() return o:GetFullName() end) or nil end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function str(v) return v and try(function() return v:ToString() end) or nil end
local function guid(g) return g and (hex(g.A) .. "-" .. hex(g.B) .. "-" .. hex(g.C) .. "-" .. hex(g.D)) or nil end

local function ps_info(ps)
    if not valid(ps) then return nil end
    return {
        name = fullname(ps),
        class = str(try(function() return ps:GetClass():GetFName() end)),
        player_name = str(try(function() return ps:GetPlayerName() end)),
        player_name_private = str(try(function() return ps.PlayerNamePrivate end)),
        player_id = try(function() return ps.PlayerId end),
        is_bot = try(function() return ps.bIsABot end),
        pawn = fullname(try(function() return ps.PawnPrivate end)),
        char_guid = guid(try(function() return ps.OwnerGuid.CharacterGuid.InnerGuid end)),
        color_hex = str(try(function() return ps.PlayerColor.HexString end)),
        color_player_id = try(function() return ps.PlayerColor.PlayerId end),
        platform_display_name = str(try(function() return ps.PlatformData.DisplayName end)),
        platform_name = str(try(function() return ps.PlatformData.PlatformName end)),
        has_display_name_comp = valid(try(function() return ps.DisplayNameComponent end)),
    }
end

function M.run(log, args)
    local out = { pawns = {} }
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if valid(p) and try(function() return p:HasAnyInternalFlags(0x200000 | 0x10000000) end) ~= true then
            local c = try(function() return p:GetController() end)
            local np = try(function() return p.PlayerNameplateComponent end)
            out.pawns[#out.pawns + 1] = {
                pawn = fullname(p),
                controller = valid(c) and fullname(c) or nil,
                controller_wants_ps = valid(c) and try(function() return c.bWantsPlayerState end) or nil,
                controller_ps = ps_info(valid(c) and try(function() return c.PlayerState end) or nil),
                pawn_ps = ps_info(try(function() return p.PlayerState end)),
                nameplate = valid(np) and {
                    name = fullname(np),
                    widget = fullname(try(function() return np:GetUserWidgetObject() end)),
                    widget_class = fullname(try(function() return np:GetWidgetClass() end)),
                } or nil,
            }
        end
    end
    local gm = FindFirstOf("DominionGameMode")
    out.game_mode = fullname(gm)
    out.player_state_class = fullname(try(function() return gm.PlayerStateClass end))
    out.default_player_name = str(try(function() return gm.DefaultPlayerName end))
    local gs = FindFirstOf("DominionGameStateBase")
    local n = 0
    pcall(function() gs.PlayerArray:ForEach(function() n = n + 1 end) end)
    out.player_array_count = n
    out.registry_sanitized = {}
    pcall(function()
        gs.DisplayNameComponent.SanitizedCharacterNames:ForEach(function(_, elem)
            local e = elem:get()
            out.registry_sanitized[#out.registry_sanitized + 1] = (str(try(function() return e.AccountGuidSaveStr end)) or "?") .. " | "
                .. (guid(try(function() return e.CharacterGuid.InnerGuid end)) or "?") .. " | " .. (str(try(function() return e.CharacterName end)) or "?")
        end)
    end)
    out.all_player_states = {}
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        out.all_player_states[#out.all_player_states + 1] = ps_info(ps)
    end
    if log then log.event("identity_probe", out) end
    return out
end

return M
