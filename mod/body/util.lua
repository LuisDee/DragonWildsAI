-- Shared helpers for the body modules (body/puppet.lua, body/gear.lua, body/skills.lua, body/speech.lua).
-- Same idioms as the proven experiment modules (scripts/puppet_test.lua, puppet_gear.lua, puppet_combat.lua):
-- every UE access goes through try()/valid() so a missing property or a dead wrapper is a Lua
-- error we can catch. pcall can NOT catch native access violations (DISCOVERIES "ROOT CAUSES"),
-- so risky native calls also leave a breadcrumb in the log first (U.call).
--
-- Units: the game works in centimetres; everything on the bridge wire is in METRES
-- (brain/interface.py: follow distance in metres, the mock's positions in metres).
local U = {}

function U.try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
end

function U.valid(o)
    return o ~= nil and U.try(function() return o:IsValid() end) == true
end

function U.fullname(o)
    return U.valid(o) and U.try(function() return o:GetFullName() end) or nil
end

-- Object name without class or outer path: "BP_AI_Kebbit_Character_C_2147480001".
-- Stable for the lifetime of the actor, so it serves as the entity id on the wire.
function U.short(o)
    local n = U.fullname(o)
    return n and (n:match("([%w_]+)$") or n) or nil
end

-- UE4SS hands FString/FName/FText back as userdata with ToString(); plain strings pass through.
function U.str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    return U.try(function() return v:ToString() end)
end

function U.loc(a)
    local v = U.try(function() return a:K2_GetActorLocation() end)
    return v and { X = v.X, Y = v.Y, Z = v.Z } or nil
end

function U.dist(p, q)
    if not (p and q) then return math.huge end
    return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2)
end

function U.dist2d(p, q)
    if not (p and q) then return math.huge end
    return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2)
end

function U.actor_dist(a, b) return U.dist(U.loc(a), U.loc(b)) end

local function round(x, n)
    local m = 10 ^ (n or 2)
    return math.floor(x * m + 0.5) / m
end
U.round = round

-- {X,Y,Z} cm -> [x,y,z] m (wire format). nil stays nil.
function U.to_wire(v)
    if not v then return nil end
    return { round(v.X / 100), round(v.Y / 100), round(v.Z / 100) }
end

-- [x,y,z] m (wire format) -> {X,Y,Z} cm, or nil if it is not three numbers.
function U.from_wire(t)
    if type(t) ~= "table" or #t ~= 3 then return nil end
    for i = 1, 3 do if type(t[i]) ~= "number" then return nil end end
    return { X = t[1] * 100, Y = t[2] * 100, Z = t[3] * 100 }
end

function U.cm_to_m(d) return d == math.huge and nil or round(d / 100) end

-- Real players are pawns whose controller is a PlayerController; every other BP_PlayerCharacter_C
-- is a puppet (the split logic of scripts/puppet_test.lua, verified in game 2026-10-25).
U.PLAYER_CHAR_CLASS = "BP_PlayerCharacter_C"

function U.controller_of(p)
    local c = U.try(function() return p:GetController() end)
    return U.valid(c) and c or nil
end

function U.is_player_controller(c)
    return (U.fullname(c) or ""):find("PlayerController", 1, true) ~= nil
end

function U.split_pawns()
    local players, puppets = {}, {}
    for _, p in ipairs(U.try(FindAllOf, U.PLAYER_CHAR_CLASS) or {}) do
        if U.valid(p) then
            table.insert(U.is_player_controller(U.controller_of(p)) and players or puppets, p)
        end
    end
    return players, puppets
end

function U.health(a)
    return U.try(function() return a.HealthComponent:GetAuthoritativeHealth() end)
        or U.try(function() return a:GetHealthComponent():GetAuthoritativeHealth() end)
end

function U.max_health(a)
    return U.try(function() return a.HealthComponent.MaxHealth end)
        or U.try(function() return a.HealthComponent:GetMaxHealth() end)
end

-- Player display name (PlayerState name), falling back to the pawn's object name.
function U.player_name(p)
    local ps = U.try(function() return p.PlayerState end)
    local n = U.valid(ps) and U.str(U.try(function() return ps:GetPlayerName() end)) or nil
    if n and n ~= "" then return n end
    return U.short(p)
end

-- PlayerState PlayerId: the chat hook reports this as command_received.player (e.g. "256").
-- The pawn's PlayerState, else its controller's (the chat PlayerId lives on the PlayerState).
local function player_state(p)
    local ps = U.try(function() return p.PlayerState end)
    if U.valid(ps) then return ps end
    local c = U.controller_of(p)
    ps = c and U.try(function() return c.PlayerState end)
    return U.valid(ps) and ps or nil
end

function U.player_id(p)
    local ps = player_state(p)
    if not ps then return nil end
    return U.try(function() return ps.PlayerId end) or U.try(function() return ps:GetPlayerId() end)
end

-- Aliases for "the first connected player" (the brain's Controller may say "me"; Luis is the owner).
U.PLAYER_ALIASES = { [""] = true, me = true, luis = true, player = true }

-- Find a connected player. `who` may be:
--   * the chat PlayerId as a string or number ("256", from FChatMessageData.SenderData.PlayerId;
--     this is what command_received.player carries) -> PlayerState.PlayerId match;
--   * a display name (exact, then case-insensitive);
--   * an alias in U.PLAYER_ALIASES (or nil) -> the first connected player.
-- If nothing matches and exactly one player is connected, a numeric id falls back to that player
-- (its PlayerState may be unreadable); with loose=true any unmatched name does (follow only
-- targets players, so "follow Zezima" with one player online means that player).
function U.find_player(who, loose)
    local players = U.split_pawns()
    if #players == 0 then return nil end
    local w = who ~= nil and tostring(who) or ""
    local lw = w:lower()
    if U.PLAYER_ALIASES[lw] then return players[1] end
    local num = tonumber(w)
    if num then
        for _, p in ipairs(players) do
            if tonumber(U.player_id(p)) == num then return p end
        end
    end
    for _, p in ipairs(players) do
        if U.player_name(p) == w then return p end
    end
    for _, p in ipairs(players) do
        if (U.player_name(p) or ""):lower() == lw then return p end
    end
    if #players == 1 and (num or loose) then return players[1] end
    return nil
end

-- Log a breadcrumb, then run fn under pcall. The breadcrumb is flushed to disk before the native
-- call, so if the server dies the log's last line names the call that killed it.
function U.call(log, label, data, fn)
    if log then pcall(log.event, "native", { call = label, data = data }) end
    local ok, res = pcall(fn)
    if not ok and log then pcall(log.event, "native_error", { call = label, err = tostring(res) }) end
    return ok, res
end

return U
