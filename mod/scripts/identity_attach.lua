-- Give the AI-possessed puppet a DominionPlayerState so clients can name it ("Claude" overhead).
-- debug_run {module="identity_attach", args={action=...}}
--   status  : identity_probe (read-only)
--   attach  : spawn /Script/Dominion.DominionPlayerState, wire it to the puppet's AIController and
--             pawn (SetOwner, Controller.PlayerState, Pawn.PlayerState, PawnPrivate), set
--             bIsABot, OwnerGuid.CharacterGuid = bot GUID (scalar writes only), PlayerName via
--             GameMode:ChangeName, ForceNetUpdate. No unpossess, no client RPC, no hand-built struct.
--   register: DisplayNameComponent:Server_RegisterCharacter(<puppet PS's own OwnerGuid>, name), so the
--             registry has (puppet account str, bot GUID) -> name. Server RPC on the server, own struct.
--   detach  : undo attach (clear both PlayerState pointers, SetLifeSpan the PlayerState).
-- Why manual: AController::InitPlayerState is not reflected, and AIController only creates one in
-- PostInitializeComponents when bWantsPlayerState was already true (UE4SS SpawnActor is not
-- deferred, so setting it after spawn is too late). Re-possessing would unpossess (crash path).
local M = {}

local BOT_GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }
local PS_CLASS = "/Script/Dominion.DominionPlayerState"

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end
local function alive(o) return valid(o) and try(function() return o:HasAnyInternalFlags(0x200000 | 0x10000000) end) ~= true end
local function fullname(o) return o and try(function() return o:GetFullName() end) or nil end

local function find_puppet()
    for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
        if alive(p) then
            local c = try(function() return p:GetController() end)
            if valid(c) and (fullname(c) or ""):find("AIController", 1, true) then return p, c end
        end
    end
end

local function step(log, steps, name, f)
    local ok, v = pcall(f)
    steps[#steps + 1] = { step = name, ok = ok, err = (not ok) and tostring(v) or nil }
    log.event("identity_attach_step", steps[#steps])
    return ok, v
end

local function dofile_probe(log)
    local scripts = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$")
    local probe = assert(loadfile(scripts .. "/identity_probe.lua"))()
    return probe.run(nil, {})
end

local actions = {}

function actions.status(log)
    return dofile_probe(log)
end

function actions.attach(log, args)
    local p, c = find_puppet()
    if not p then return { ok = false, error = "no AI-possessed puppet" } end
    local existing = try(function() return p.PlayerState end)
    if valid(existing) then return { ok = false, error = "puppet already has a PlayerState", ps = fullname(existing) } end
    local cls = StaticFindObject(PS_CLASS)
    if not valid(cls) then return { ok = false, error = "class not found", path = PS_CLASS } end
    local name = args.name or "Claude"
    log.event("identity_attach_plan", { puppet = fullname(p), controller = fullname(c), class = PS_CLASS, name = name,
        writes = { "SpawnActor PS", "PS:SetOwner(ai)", "PS.bIsABot", "PS.OwnerGuid.CharacterGuid.InnerGuid", "ai.PlayerState",
                   "pawn.PlayerState", "PS.PawnPrivate", "GameMode:ChangeName", "ForceNetUpdate" } })
    local steps = {}
    local loc = try(function() return p:K2_GetActorLocation() end) or { X = 0, Y = 0, Z = 0 }
    local ok, ps = step(log, steps, "spawn", function()
        return p:GetWorld():SpawnActor(cls, { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok or not valid(ps) then return { ok = false, error = "spawn failed", steps = steps } end
    step(log, steps, "set_owner", function() ps:SetOwner(c) end)
    step(log, steps, "is_bot", function() ps.bIsABot = true end)
    step(log, steps, "owner_guid", function()
        local g = ps.OwnerGuid.CharacterGuid.InnerGuid
        g.A, g.B, g.C, g.D = BOT_GUID.A, BOT_GUID.B, BOT_GUID.C, BOT_GUID.D
    end)
    step(log, steps, "controller_ps", function() c.PlayerState = ps end)
    step(log, steps, "pawn_ps", function() p.PlayerState = ps end)
    step(log, steps, "pawn_private", function() ps.PawnPrivate = p end)
    if args.change_name ~= false then
        step(log, steps, "change_name", function()
            FindFirstOf("DominionGameMode"):ChangeName(c, name, false)
        end)
    end
    step(log, steps, "net_update", function() ps:ForceNetUpdate(); p:ForceNetUpdate() end)
    return { ok = true, ps = fullname(ps), steps = steps, after = dofile_probe(log) }
end

function actions.register(log, args)
    local p = find_puppet()
    local ps = p and try(function() return p.PlayerState end)
    if not valid(ps) then return { ok = false, error = "puppet has no PlayerState (run attach)" } end
    local gs = FindFirstOf("DominionGameStateBase")
    local name = args.name or "Claude"
    log.event("identity_register_plan", { ps = fullname(ps), name = name })
    local ok, err = pcall(function() gs.DisplayNameComponent:Server_RegisterCharacter(ps.OwnerGuid, name) end)
    log.event("identity_register", { ok = ok, err = (not ok) and tostring(err) or nil })
    return { ok = ok, err = (not ok) and tostring(err) or nil }
end

function actions.detach(log)
    local p, c = find_puppet()
    if not p then return { ok = false, error = "no AI-possessed puppet" } end
    local ps = try(function() return p.PlayerState end)
    log.event("identity_detach_plan", { ps = fullname(ps) })
    local steps = {}
    step(log, steps, "pawn_ps_nil", function() p.PlayerState = nil end)
    step(log, steps, "controller_ps_nil", function() c.PlayerState = nil end)
    if valid(ps) then step(log, steps, "ps_lifespan", function() ps:SetLifeSpan(0.1) end) end
    step(log, steps, "net_update", function() p:ForceNetUpdate() end)
    return { ok = true, steps = steps }
end

-- Hot-load mod/body/identity.lua (require would return the cached copy) and run ensure() on the
-- puppet: validates the shipped module in game. With a PS already attached it only re-checks the
-- registry (no writes unless the (",", bot GUID) entry is missing).
function actions.module(log, args)
    local scripts = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$")
    -- The running server's body.util may predate helpers identity uses (U.alive): bind a fresh copy
    -- for this load only, then restore the live one.
    local live_util = package.loaded["body.util"]
    package.loaded["body.util"] = assert(loadfile(scripts .. "/../body/util.lua"))()
    local okl, identity = pcall(function() return assert(loadfile(scripts .. "/../body/identity.lua"))() end)
    package.loaded["body.util"] = live_util
    if not okl then return { ok = false, error = tostring(identity) } end
    local p, c = find_puppet()
    if not p then return { ok = false, error = "no AI-possessed puppet" } end
    return identity.ensure(log, p, c, args.name)
end

function M.run(log, args)
    local a = actions[args.action or "status"]
    if not a then return { ok = false, error = "unknown action" } end
    return a(log, args)
end

return M
