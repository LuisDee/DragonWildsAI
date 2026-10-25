-- READ-ONLY probe: how does the bot appear to vanilla clients' world map and HUD compass?
--
-- From the dump (build 26161880):
--   * AGameplayObjectRegistry.PlayerCharacters : TArray<FPlayerCharacterData>, ReplicatedUsing
--     OnRep_PlayerCharacters. FPlayerCharacterData = {Location (NetQuantize), RotationByte,
--     OwningCharacterGuid (FDomCharacterGuid), OwningPlayerUniqueID (FUniqueNetIdRepl),
--     OwningPlayerName, Color (FLinearColor), Identifier (FGuid)}.
--   * UMapUIAPI.GameplayObjectRegistry and UCompassWidget.GameplayObjectRegistry read it;
--     UCompassWidget.GameplayObjectsToIcons is keyed by FGuid (= Identifier).
--   * EMapIconType has LocalPlayerCharacter=1 / OtherPlayerCharacter=2.
--   * ADominionPlayerCharacter.GameplayObjectRegistry (0x15C0): every player pawn holds the pointer.
-- debug_run {module="presence_probe"} -> PlayerArray, registry entries, pawn locations.
local U = require("body.util")
local M = {}

local LIB = "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary"

local function idstr(ud)
    local l = U.find_object(LIB)
    if ud == nil or not U.valid(l) then return nil end
    local ok, r = pcall(function() return l:ConvertUniqueNetIdToJsonString(ud) end)
    return ok and (U.str(r) or tostring(r)) or ("err:" .. tostring(r))
end

local function v3(v)
    return v and { U.round(v.X / 100, 2), U.round(v.Y / 100, 2), U.round(v.Z / 100, 2) } or nil
end

local function color(c)
    return U.try(function() return { U.round(c.R, 3), U.round(c.G, 3), U.round(c.B, 3), U.round(c.A, 3) } end)
end

function M.registry_entries(reg)
    local out = {}
    pcall(function()
        reg.PlayerCharacters:ForEach(function(i, elem)
            local e = elem:get()
            out[#out + 1] = {
                i = i,
                loc_m = v3(U.try(function() return e.Location end)),
                rot = U.try(function() return e.RotationByte end),
                char_guid = U.guid_hex(U.try(function() return e.OwningCharacterGuid.InnerGuid end)),
                unique_id = idstr(U.try(function() return e.OwningPlayerUniqueID end)),
                name = U.str(U.try(function() return e.OwningPlayerName end)),
                color = color(U.try(function() return e.Color end)),
                identifier = U.guid_hex(U.try(function() return e.Identifier end)),
            }
        end)
    end)
    return out
end

local function ps_info(ps)
    return {
        ps = U.short(ps),
        name = U.str(U.try(function() return ps:GetPlayerName() end)),
        player_id = U.try(function() return ps.PlayerId end),
        bot = U.try(function() return ps.bIsABot end),
        char_guid = U.guid_hex(U.try(function() return ps.OwnerGuid.CharacterGuid.InnerGuid end)),
        pawn = U.short(U.try(function() return ps.PawnPrivate end)),
        unique_id = idstr(U.try(function() return ps.UniqueID end)),
    }
end

function M.run(log, args)
    local gs = U.find_first("DominionGameStateBase")
    local pa = {}
    pcall(function() gs.PlayerArray:ForEach(function(_, e) pa[#pa + 1] = ps_info(e:get()) end) end)
    local regs = U.find_all("GameplayObjectRegistry")
    local reg = regs[1]
    local players, puppets = U.split_pawns()
    local pawns = {}
    for _, p in ipairs(players) do pawns[#pawns + 1] = { kind = "player", pawn = U.short(p), loc_m = v3(U.loc(p)),
        registry = U.short(U.try(function() return p.GameplayObjectRegistry end)) } end
    for _, p in ipairs(puppets) do pawns[#pawns + 1] = { kind = "puppet", pawn = U.short(p), loc_m = v3(U.loc(p)),
        registry = U.short(U.try(function() return p.GameplayObjectRegistry end)),
        ps = U.short(U.try(function() return p.PlayerState end)) } end
    local sub = U.find_first("GameplayObjectSubsystem")
    return {
        ok = true,
        player_array = pa,
        registries = #regs,
        registry = U.fullname(reg),
        subsystem_registry = sub and U.short(U.try(function() return sub.ObjectRegistry end)) or nil,
        player_characters = reg and M.registry_entries(reg) or nil,
        interp = reg and { dist = U.try(function() return reg.PlayerCharacterInterpolationDistanceThreshold end),
                           time = U.try(function() return reg.PlayerCharacterInterpolationTimeThreshold end) } or nil,
        pawns = pawns,
    }
end

return M
