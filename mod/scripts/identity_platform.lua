-- Nameplate attempt 2: fill the bot PlayerState's PlatformData / PlayerColor / PlayerId the way a
-- real player's look (Luis: PlatformData.DisplayName="luisdeburnaybastos", PlatformName="WIN",
-- PlayerColor {HexString, PlayerId=256}, PlayerId=256). These are replicated PlayerState properties
-- with OnRep handlers (OnRep_PlatformDataUpdated, OnRep_PlayerColorUpdated, OnRep_PlayerId);
-- default values never replicate, so those OnReps never fired on clients for the bot.
-- Scalar/string property writes only; no RPC, no struct passed anywhere. UniqueId is NOT touched.
-- debug_run {module="identity_platform", args={action="read"|"apply", name="Claude", player_id=257}}
local M = {}

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function alive(o) return valid(o) and try(function() return o:HasAnyInternalFlags(0x200000 | 0x10000000) end) ~= true end
local function fullname(o) return o and try(function() return o:GetFullName() end) or nil end
local function str(v) return v and try(function() return v:ToString() end) or nil end

local function pawns()
    local luis, puppet
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if alive(p) then
            local c = try(function() return p:GetController() end)
            local n = fullname(c) or ""
            if n:find("PlayerController", 1, true) then luis = luis or p
            elseif n:find("AIController", 1, true) then puppet = puppet or p end
        end
    end
    return luis, puppet
end

local function read_ps(ps)
    if not valid(ps) then return nil end
    local col = try(function() return ps.PlayerColor.Color end)
    return {
        name = fullname(ps),
        player_id = try(function() return ps.PlayerId end),
        platform_display_name = str(try(function() return ps.PlatformData.DisplayName end)),
        platform_name = str(try(function() return ps.PlatformData.PlatformName end)),
        platform_type = try(function() return ps.PlatformData.PlatformType end),
        color = col and { R = col.R, G = col.G, B = col.B, A = col.A } or nil,
        color_hex = str(try(function() return ps.PlayerColor.HexString end)),
        color_player_id = try(function() return ps.PlayerColor.PlayerId end),
        player_name = str(try(function() return ps:GetPlayerName() end)),
    }
end

local actions = {}

function actions.read()
    local luis, puppet = pawns()
    return { luis = read_ps(luis and try(function() return luis.PlayerState end)),
             puppet = read_ps(puppet and try(function() return puppet.PlayerState end)) }
end

function actions.apply(log, args)
    local luis, puppet = pawns()
    local ps = puppet and try(function() return puppet.PlayerState end)
    if not valid(ps) then return { ok = false, error = "puppet has no PlayerState" } end
    local lps = luis and try(function() return luis.PlayerState end)
    local name = args.name or "Claude"
    local pid = args.player_id or 257
    local src = read_ps(lps) or {}
    log.event("identity_platform_plan", { ps = fullname(ps), name = name, player_id = pid, template = src })
    local steps = {}
    local function step(n, f)
        local ok, err = pcall(f)
        steps[#steps + 1] = { step = n, ok = ok, err = (not ok) and tostring(err) or nil }
    end
    step("platform_display_name", function() ps.PlatformData.DisplayName = name end)
    step("platform_name", function() ps.PlatformData.PlatformName = src.platform_name or "WIN" end)
    if src.platform_type then step("platform_type", function() ps.PlatformData.PlatformType = src.platform_type end) end
    if args.color ~= false then
        local c = args.rgba or { R = 0.85, G = 0.47, B = 0.34, A = 1.0 } -- Claude orange
        step("color", function()
            local col = ps.PlayerColor.Color
            col.R, col.G, col.B, col.A = c.R, c.G, c.B, c.A
        end)
        step("color_hex", function() ps.PlayerColor.HexString = args.hex or "D97757FF" end)
        step("color_player_id", function() ps.PlayerColor.PlayerId = pid end)
    end
    if args.player_id ~= false then step("player_id", function() ps.PlayerId = pid end) end
    -- Server-side OnReps (opt-in), then replicate.
    if args.onrep == true then -- opt-in: native OnReps may touch client-only UI on the server
        step("onrep_platform", function() ps:OnRep_PlatformDataUpdated() end)
        step("onrep_color", function() ps:OnRep_PlayerColorUpdated() end)
        step("onrep_owner", function() ps:OnRep_OwnerGuidUpdated() end)
    end
    step("net_update", function() ps:ForceNetUpdate(); puppet:ForceNetUpdate() end)
    local r = { ok = true, steps = steps, after = read_ps(ps) }
    log.event("identity_platform", r)
    return r
end

-- Make clients destroy and re-create their copy of the puppet (as on a rejoin), without moving it:
-- shrink NetCullDistanceSquared so it is irrelevant to everyone, then restore it after args.ms
-- (default 9000; actor channels close ~5 s after relevancy is lost). Tests whether the nameplate is
-- only filled when the client creates the pawn. Server-side property/UFunction only.
function actions.recycle(log, args)
    local _, puppet = pawns()
    if not puppet then return { ok = false, error = "no puppet" } end
    local orig = try(function() return puppet.NetCullDistanceSquared end)
    if type(orig) ~= "number" or orig <= 1 then return { ok = false, error = "bad NetCullDistanceSquared", value = orig } end
    local ms = args.ms or 9000
    log.event("identity_recycle_plan", { puppet = fullname(puppet), orig = orig, ms = ms })
    local ok, err = pcall(function() puppet:SetNetCullDistanceSquared(1.0) end)
    if not ok then return { ok = false, error = tostring(err) } end
    ExecuteInGameThreadWithDelay(ms, function()
        local ok2, err2 = pcall(function() puppet:SetNetCullDistanceSquared(orig); puppet:ForceNetUpdate() end)
        log.event("identity_recycle_restored", { ok = ok2, err = (not ok2) and tostring(err2) or nil,
            now = try(function() return puppet.NetCullDistanceSquared end) })
    end)
    return { ok = true, orig = orig, restore_in_ms = ms }
end

function M.run(log, args)
    local a = actions[args.action or "read"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
