-- Shared Lua core for the whole mod: body/, scripts/ and experiments/ all use these helpers
-- instead of re-defining try/valid/fullname/split_pawns (docs/ARCHITECTURE.md, rule 1).
--
-- Every UE access goes through try()/valid() so a missing property or a dead wrapper is a Lua
-- error we can catch. pcall can NOT catch native access violations (DISCOVERIES "ROOT CAUSES"),
-- so every risky native call goes through U.call: it writes a breadcrumb to the log (flushed to
-- disk) BEFORE the call, so if the server dies the log's last line names the call that killed it.
--
-- Units: the game works in centimetres; everything on the bridge wire is in METRES
-- (brain/interface.py: follow distance in metres, the mock's positions in metres).
--
-- API stability: body/skills.lua, body/gear.lua and body/puppet.lua depend on every name here.
-- Add functions; never change an existing signature or return shape (U.try returns ONE value:
-- callers write tonumber(U.try(...)), so a second return value would break them; use U.try_err).
local U = {}

-- ------------------------------------------------------------------ logging / breadcrumbs
-- Default logger (a dwlog-like module with .event(name, data)). main.lua sets it once, so
-- experiments and services can breadcrumb without threading `log` through every call.
local default_log = nil

function U.set_log(log) default_log = log end
function U.get_log() return default_log end

-- Log an event without ever raising. `log` may be nil (then the default logger is used).
function U.event(log, name, data)
    log = log or default_log
    if log then pcall(log.event, name, data) end
end

-- A breadcrumb: "about to do <step>". Same as U.event with a fixed event name.
function U.crumb(log, step, data) U.event(log, "crumb", { step = step, data = data }) end

-- ------------------------------------------------------------------ guarded access
function U.try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
end

-- Like U.try, but returns nil, err_string on failure (for probes that report the error).
function U.try_err(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil, tostring(v)
end

function U.valid(o)
    return o ~= nil and U.try(function() return o:IsValid() end) == true
end

-- EInternalObjectFlags Garbage (1<<21) | Unreachable (1<<28).
U.GARBAGE_OR_UNREACHABLE = 0x200000 | 0x10000000

-- Valid AND not destroyed-awaiting-GC. After SetLifeSpan/destroy an actor stays in FindAllOf,
-- with IsValid() still true, until GC runs (minutes); only the internal Garbage flag tells it
-- apart (DISCOVERIES "Unpossess crash: fix bisect", notes). Use this for anything you are about
-- to act on (possess, move, equip). Objects without HasAnyInternalFlags (offline fakes) count as alive.
function U.alive(o)
    if not U.valid(o) then return false end
    return U.try(function() return o:HasAnyInternalFlags(U.GARBAGE_OR_UNREACHABLE) end) ~= true
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

-- Full name without the leading class word: "/Game/.../ITEM_X.ITEM_X" (UE4SS GetFullName is
-- "<Class> <path>"). This is the object path StaticFindObject takes.
function U.path_of(o)
    local n = U.fullname(o)
    return n and (n:match("^%S+%s+(.*)$") or n) or nil
end

-- The class word of GetFullName: "WearableEquipmentData", "BP_PlayerController_C", ...
function U.class_word(o) return ((U.fullname(o) or ""):match("^(%S+)")) or nil end

-- Full name of the object's class ("BlueprintGeneratedClass /Game/...").
function U.class_name(o)
    return U.valid(o) and U.try(function() return o:GetClass():GetFullName() end) or nil
end

-- UE4SS hands FString/FName/FText back as userdata with ToString(); plain strings pass through.
function U.str(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    return U.try(function() return v:ToString() end)
end

-- ------------------------------------------------------------------ finding objects
-- FindAllOf(short_class) filtered to alive objects; always a table. opts.skip_defaults also
-- drops class default objects ("Default__" in the name). opts.valid_only keeps zombies (use only
-- for diagnostics that want to see them).
function U.find_all(class, opts)
    opts = opts or {}
    local out = {}
    local keep = opts.valid_only and U.valid or U.alive
    for _, o in ipairs(U.try(FindAllOf, class) or {}) do
        if keep(o) and not (opts.skip_defaults and (U.fullname(o) or ""):find("Default__", 1, true)) then
            out[#out + 1] = o
        end
    end
    return out
end

function U.find_first(class)
    local o = U.try(FindFirstOf, class)
    return U.alive(o) and o or nil
end

-- StaticFindObject(path) if it is loaded and valid, else nil. Never loads anything.
function U.find_object(path)
    local o = U.try(StaticFindObject, path)
    return U.valid(o) and o or nil
end

-- ------------------------------------------------------------------ geometry
-- Validity first: a cached actor ref whose actor was destroyed and GC'd is a dangling wrapper, and ANY
-- method/property lookup on it is a native AV in UE4SS __index that pcall can't catch (crash
-- 2026-10-26 14:56:19, BUGS.md). IsValid itself is safe on it (UE4SS's live-object set).
function U.loc(a)
    if not U.valid(a) then return nil end
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

-- Forward vector, defaulting to +X when it can't be read.
function U.forward(a)
    return U.try(function() return a:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
end

-- A point `ahead_cm` in front of the actor (negative = behind), raised by `up_cm`. nil if the
-- actor has no location. The verified puppet spawn point is U.in_front(player, 300, 50).
function U.in_front(a, ahead_cm, up_cm)
    local at = U.loc(a)
    if not at then return nil end
    local f = U.forward(a)
    return { X = at.X + f.X * ahead_cm, Y = at.Y + f.Y * ahead_cm, Z = at.Z + (up_cm or 0) }
end

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

-- ------------------------------------------------------------------ players vs puppets
-- Real players are pawns whose controller is a PlayerController; every other BP_PlayerCharacter_C
-- is a puppet (the split logic of experiments/puppet_test.lua, verified in game 2026-10-25).
U.PLAYER_CHAR_CLASS = "BP_PlayerCharacter_C"
U.PLAYER_CONTROLLER_CLASS = "BP_PlayerController_C"

function U.controller_of(p)
    local c = U.try(function() return p:GetController() end)
    return U.valid(c) and c or nil
end

function U.is_player_controller(c)
    return (U.fullname(c) or ""):find("PlayerController", 1, true) ~= nil
end

-- (players, puppets). Destroyed-awaiting-GC pawns are skipped (U.alive), so a removed puppet
-- is never re-adopted or re-possessed.
function U.split_pawns()
    local players, puppets = {}, {}
    for _, p in ipairs(U.find_all(U.PLAYER_CHAR_CLASS)) do
        table.insert(U.is_player_controller(U.controller_of(p)) and players or puppets, p)
    end
    return players, puppets
end

-- Connected players' controllers (BP_PlayerController_C), alive only.
function U.player_controllers() return U.find_all(U.PLAYER_CONTROLLER_CLASS) end

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
U.player_state = player_state

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

-- ------------------------------------------------------------------ GUIDs
-- FGuid {A,B,C,D} (uint32 each) <-> 32 hex chars, as the join log prints them (DCG:<hex>).
function U.guid_hex(g)
    if type(g) ~= "table" and type(g) ~= "userdata" then return nil end
    local ok, s = pcall(function()
        return string.format("%08X%08X%08X%08X", g.A % 0x100000000, g.B % 0x100000000, g.C % 0x100000000, g.D % 0x100000000)
    end)
    return ok and s or nil
end

function U.guid_from_hex(h)
    if type(h) ~= "string" or not h:match("^%x+$") or #h ~= 32 then return nil end
    local function word(i) return tonumber(h:sub(i, i + 7), 16) end
    return { A = word(1), B = word(9), C = word(17), D = word(25) }
end

-- Copy {A,B,C,D} out of a UE struct (or table) into a plain table.
function U.guid_copy(g)
    local ok, t = pcall(function() return { A = g.A, B = g.B, C = g.C, D = g.D } end)
    return ok and t or nil
end

-- Write {A,B,C,D} into a UE struct in place (a struct property field by field, as verified in
-- experiments/name_register: whole-struct assignment is avoided).
function U.guid_set(dst, src)
    dst.A, dst.B, dst.C, dst.D = src.A, src.B, src.C, src.D
end

function U.guid_eq(a, b)
    if a == nil or b == nil then return false end
    local ok, eq = pcall(function() return a.A == b.A and a.B == b.B and a.C == b.C and a.D == b.D end)
    return ok and eq or false
end

-- ------------------------------------------------------------------ results
-- The tool result shape every handler returns (CLAUDE.md section 5).
function U.result(ok, reason, data) return { ok = ok == true, reason = reason, data = data or {} } end
function U.ok(data) return { ok = true, data = data or {} } end
function U.fail(reason, data) return { ok = false, reason = reason, data = data or {} } end

-- ------------------------------------------------------------------ the guarded native call
-- Log a breadcrumb, then run fn under pcall. The breadcrumb is flushed to disk before the native
-- call, so if the server dies the log's last line names the call that killed it. `log` may be nil
-- (the default logger from U.set_log is used). Returns pcall's (ok, result_or_error).
-- EVERY native call that can change game state goes through here (docs/ARCHITECTURE.md, rule 2).
function U.call(log, label, data, fn)
    log = log or default_log
    if log then pcall(log.event, "native", { call = label, data = data }) end
    local ok, res = pcall(fn)
    if not ok and log then pcall(log.event, "native_error", { call = label, err = tostring(res) }) end
    return ok, res
end

-- ------------------------------------------------------------------ containers + sibling modules (shared)
-- Iterate a UE4SS TArray / TSet / TMap (its ForEach), bounded: fn(value, key, n) with each RemoteUnrealParam
-- unwrapped (:get()); fn returning true stops. Never under DW_PAUSE (world teardown). (simplify review 2026-10-26:
-- one copy instead of one per module.)
local function unwrap(e)
    local t = type(e)
    if t == "userdata" or (t == "table" and type(rawget(e, "get")) == "function") then
        local ok, v = pcall(function() return e:get() end)
        if ok and v ~= nil then return v end
    end
    return e
end
U.unwrap = unwrap
function U.each(c, fn, cap)
    if c == nil or rawget(_G, "DW_PAUSE") == true then return end
    local n = 0
    pcall(function()
        c:ForEach(function(a, b)
            n = n + 1
            if n > (cap or 256) then return true end
            if b == nil then return fn(unwrap(a), n, n) end
            return fn(unwrap(b), unwrap(a), n)
        end)
    end)
end

-- One sibling-module loader per module (replaces the M.mods / set_modules / mod / mcall copies):
--   local L = U.loader(ROOT); M.set_modules = L.set_modules; local mod, mcall = L.mod, L.mcall
-- mod(name) loadfiles client_mod/scripts/<name>.lua once (or the injected one); mcall(name, fn, ...) pcalls it and
-- returns the result | nil, why.
function U.loader(root)
    local L = { mods = {} }
    function L.set_modules(t) for k, v in pairs(t) do L.mods[k] = v end end
    function L.mod(name)
        if not L.mods[name] then
            local ok, m = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/" .. name .. ".lua"))() end)
            if ok then L.mods[name] = m end
        end
        return L.mods[name]
    end
    function L.mcall(name, fn, ...)
        local m = L.mod(name)
        if not (m and m[fn]) then return nil, "no " .. name .. "." .. fn end
        local ok, r = pcall(m[fn], ...)
        if not ok then return nil, tostring(r) end
        return r
    end
    return L
end

-- ------------------------------------------------------------------ world id (one resolver for every module)
-- The world Claude's learned data is filed under (traversal, nav memory, combat memory ...). NEVER a silent
-- "shockbyte" (live 2026-10-26: dev learning was filed under shockbyte because the client process has no
-- DW_WORLD_GUID). Order:
--   1. explicit: opts.world, _G.DW_WORLD_GUID (scenario_run sets it), env DW_WORLD_GUID,
--      <root>/client_io/world_guid.txt;
--   2. the server he actually JOINED: <root>/logs/state/last_join.json's "addr" (tools/client_boot.ps1)
--      matched against the boot targets' FIRST line only (the address; the password line is never read):
--      client_io/secrets/server.txt = "shockbyte", server_<name>.txt = <name> (dev, and the default target);
--   3. a joined server matching no target -> "server_<host>_<port>"; nothing known -> "unknown".
-- Sanitised like brain/worlds.py sanitize(). -> id, source ("opts"|"global"|"env"|"world_guid.txt"|"joined"|
-- "joined_unknown"|"unknown"). opts = {world, fs = {open = io.open}, cache_s = 60, now = os.time}. The
-- joined-server lookup is cached per root for cache_s (explicit settings are re-read every call: they win).
function U.world_sanitize(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[^%w_%-]", ""):sub(1, 64)
    return s ~= "" and s or nil
end
local WORLD_CACHE = {}
function U.world_reset() WORLD_CACHE = {} end
function U.world_id(root, opts)
    opts = opts or {}
    root = tostring(root or os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local san = U.world_sanitize
    local open = (opts.fs and opts.fs.open) or io.open
    local function first_line(path)
        local okf, f = pcall(open, path, "rb")
        if not (okf and f) then return nil end
        local l = f:read("l"); f:close()
        if not l then return nil end
        return (l:gsub("^\239\187\191", ""):gsub("%s+$", "")) -- (a UTF-8 BOM from PowerShell)
    end
    local w = san(opts.world); if w then return w, "opts" end
    w = san(rawget(_G, "DW_WORLD_GUID")); if w then return w, "global" end
    w = san(os.getenv("DW_WORLD_GUID")); if w then return w, "env" end
    w = san(first_line(root .. "/client_io/world_guid.txt")); if w then return w, "world_guid.txt" end
    local t = (opts.now or os.time)()
    local c = WORLD_CACHE[root]
    if c and t - c.t < (opts.cache_s or 60) then return c.id, c.source end
    local id, src
    local j = first_line(root .. "/logs/state/last_join.json") or ""
    local addr = j:match('"addr"%s*:%s*"([^"]+)"')
    if addr then
        if first_line(root .. "/client_io/secrets/server.txt") == addr then id, src = "shockbyte", "joined" end
        if not id then
            local names = { "dev" }
            local def = san(first_line(root .. "/logs/state/client_default_target.txt"))
            if def and def ~= "dev" and def ~= "shockbyte" then names[#names + 1] = def end
            for _, n in ipairs(names) do
                if not id and first_line(root .. "/client_io/secrets/server_" .. n .. ".txt") == addr then id, src = n, "joined" end
            end
        end
        if not id then id, src = "server_" .. (san((addr:gsub("[%.:]", "_"))) or "x"), "joined_unknown" end
    end
    if not id then id, src = "unknown", "unknown" end
    WORLD_CACHE[root] = { t = t, id = id, source = src }
    return id, src
end

return U
