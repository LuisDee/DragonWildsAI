-- Companion speech. One module for every way the body can put text in front of players.
--
-- DW_SAY_MODE (read on every say; default "log"):
--   log    : log only, no native call. The default, since hand-built Client_* RPCs froze Luis's
--            client (DISCOVERIES "Client freeze").
--   relay  : the VERIFIED route (DISCOVERIES "SPEECH WORKS AS Claude", 2026-10-25 13:44 UTC):
--            a post-hook on PlayerChatComponent:Server_SendChatMessage re-sends a player's GENUINE
--            client-built FChatMessageData through the server's own Server_SendChatMessage, with
--            only MessageBody and SenderData.CharacterGuid (-> M.GUID) changed. Every net id stays
--            the player's, so the message is well-formed. Clients show it under the name
--            registered for (that player's account, M.GUID): see M.register_names.
--   chat   : LEGACY, DANGEROUS. Hand-built FChatMessageData to Client_ReceiveChatMessage. Never
--            displayed and is the suspected cause of the client freeze. Kept only so the old API
--            still answers; do not enable it with a player connected.
--   notify : LEGACY, DANGEROUS. Client_DisplayTextNotification HUD toast (same incident).
--   direct : ON-DEMAND, UNVERIFIED (experiments/speech_direct; DISCOVERIES "On-demand speech").
--            Server_SendChatMessage on a connected player's PlayerChat, called with SCALAR-ONLY
--            tables (CharacterGuid = M.GUID, PlayerId, Color, MessageBody; empty filter). A one-shot
--            PRE-hook on the same function then copies the network fields into the live param
--            buffer by PROPERTY ASSIGNMENT from live engine structs (never built):
--              SenderData.PrimaryNetId/SecondaryNetId <- host PS OwnerGuid.AccountGuid.NetIdPrimary/
--              NetIdSecondary; Filter.SenderId <- host PS UniqueID.
--            Why not a table holding the userdata: UE4SS bug (83330635 and main): push_structproperty's
--            userdata branch calls get_userdata() at stack index 1 instead of stored_at_index, so a
--            struct userdata NESTED in a Lua table is read from the wrong stack slot -> native AV
--            (crash_2026_10_25_15_45_24; same frames as R3). Property assignment (__newindex) leaves
--            the value at index 1, so it copies correctly (identity's AccountGuid copy).
--            Needs experiments/speech_direct action=prove (a read-only check that the native code sees
--            pre-hook edits) to pass first. If the pre-hook does not patch, direct is disabled for
--            the run; any failure falls back to the relay queue.
--
-- Relay limitation: relay needs a triggering chat line. say() in relay mode QUEUES the text, and
-- it is delivered the next time any player sends a chat message (using that message as the
-- template), within QUEUE_TTL_S. Do NOT build a new Client_* path for on-demand speech.
--
-- Debug triggers (relay mode or experiments/chat_as, chat_relay): a player typing "!as <words>"
-- makes the bot say <words> (verified); "!echo <words>" re-sends "[Claude] <words>" under the
-- player's own name (verified, the first relay test).
--
-- Hook interplay: our re-send passes through every Server_SendChatMessage hook, including
-- scripts/hooks.lua's chat hook. main.lua drops chat lines where M.is_relaying() or
-- M.is_bot_guid(sender guid) so the brain never hears the bot as a player command.
local U = require("body.util")

local M = {}

M.MAX_LEN = 256 -- in-game chat limit
M.NAME = os.getenv("DW_COMPANION_NAME") or "Claude"
M.GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 } -- the bot's CharacterGuid
M.PLAYER_ID = 9001 -- legacy chat mode only (not used by real players; Luis's was 256)
M.COLOR = { R = 80, G = 200, B = 255, A = 255 }
M.CHAT_FN = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage"
M.MODES = { log = true, relay = true, chat = true, notify = true, direct = true }
local LOG_DEFAULT = "log"
M.DEFAULT_MODE = LOG_DEFAULT
M.ECHO_PREFIX = "[Claude] "
M.QUEUE_MAX = 5     -- pending relay lines kept (oldest dropped)
M.QUEUE_TTL_S = 60  -- a queued line older than this is dropped, not said late
M.FLUSH_MAX = 3     -- lines sent per triggering chat message
-- direct: fill FChatPlayerFilterData.ReceiverIds with every connected player's PlayerState.UniqueID
-- (TArray element assignment from a live struct: arr[i] = ud, value at stack index 1 = safe, not
-- R15). Set from the genuine-filter capture (experiments/speech_direct capture).
M.DIRECT_FILL_RECEIVERS = true

-- Shared across module reloads (debug_run loads experiments with loadfile; the hook must be
-- registered once per server run).
local function state()
    local s = rawget(_G, "__dw_speech")
    if not s then
        s = { armed = false, arm_err = nil, triggers = true, relaying = false, queue = {},
              registered = {}, sent = 0, dropped = 0, legacy_registered = false }
        rawset(_G, "__dw_speech", s)
    end
    return s
end

function M.mode()
    local m = (os.getenv("DW_SAY_MODE") or M.DEFAULT_MODE):lower()
    return M.MODES[m] and m or LOG_DEFAULT
end

function M.is_relaying() return state().relaying end
function M.is_bot_guid(g) return U.guid_eq(g, M.GUID) end

local function now() return os.time() end

-- ------------------------------------------------------------------ display-name registry
-- The client resolves a chat sender's name from GameState.DisplayNameComponent, keyed by
-- (account string, CharacterGuid). The account part can't be built from Lua safely, so reuse each
-- connected player's real PlayerState.OwnerGuid: swap its CharacterGuid to M.GUID, call
-- Server_RegisterCharacter(OwnerGuid, name), restore - all in the same tick. Verified for Luis
-- (experiments/name_register, restore checked). Once per player per server run.
local function register_one(log, ps, name)
    local g = U.try(function() return ps.OwnerGuid.CharacterGuid.InnerGuid end)
    local saved = g and U.guid_copy(g)
    if not saved then return false, "no OwnerGuid" end
    local gs = U.find_first("DominionGameStateBase")
    local dn = gs and U.try(function() return gs.DisplayNameComponent end)
    if not U.valid(dn) then return false, "no DisplayNameComponent" end
    local ok, err = U.call(log, "speech.Server_RegisterCharacter", { name = name, owner = U.guid_hex(saved) }, function()
        U.guid_set(g, M.GUID)
        dn:Server_RegisterCharacter(ps.OwnerGuid, name)
    end)
    pcall(U.guid_set, g, saved) -- ALWAYS restore the player's identity
    local restored = U.guid_eq(g, saved)
    U.event(log, "speech_name_register", { ok = ok, err = (not ok) and tostring(err) or nil, restored = restored })
    if not restored then return false, "restore failed" end
    return ok, (not ok) and tostring(err) or nil
end

-- Register M.NAME (or `name`) for the bot under every connected player's account not yet done.
-- opts.force re-registers. Returns {registered = n_new, players = n, errors = {...}}.
function M.register_names(log, name, opts)
    opts = opts or {}
    local s = state()
    name = name or M.NAME
    local n, errors, pcs = 0, {}, U.player_controllers()
    for _, pc in ipairs(pcs) do
        local ps = U.try(function() return pc.PlayerState end)
        local key = U.valid(ps) and ((U.fullname(ps) or "?") .. "|" .. name .. "|" .. U.guid_hex(M.GUID)) or nil
        if key and (opts.force or not s.registered[key]) then
            local ok, err = register_one(log, ps, name)
            if ok then s.registered[key], n = true, n + 1 else errors[#errors + 1] = tostring(err) end
        end
    end
    return { registered = n, players = #pcs, errors = errors }
end

-- Read-only dump of the registry (was scripts/names_probe.lua). Server-side reads only.
local function entries(arr)
    local out = {}
    pcall(function()
        arr:ForEach(function(_, elem)
            local e = elem:get()
            out[#out + 1] = {
                account = U.str(U.try(function() return e.AccountGuidSaveStr end)),
                character_guid = U.guid_hex(U.try(function() return e.CharacterGuid.InnerGuid end)),
                name = U.str(U.try(function() return e.CharacterName end)),
            }
        end)
    end)
    return out
end

function M.names()
    local gs = U.find_first("DominionGameStateBase")
    local dn = gs and U.try(function() return gs.DisplayNameComponent end)
    if not U.valid(dn) then return { ok = false, error = "no DisplayNameComponent" } end
    return { ok = true, bot_guid = U.guid_hex(M.GUID),
             original = entries(dn.OriginalCharacterNames), sanitized = entries(dn.SanitizedCharacterNames) }
end

-- ------------------------------------------------------------------ relay (the verified route)
local function take_pending(s)
    local out, t = {}, now()
    while #s.queue > 0 and #out < M.FLUSH_MAX do
        local item = table.remove(s.queue, 1)
        if t - item.t <= M.QUEUE_TTL_S then out[#out + 1] = item.text else s.dropped = s.dropped + 1 end
    end
    return out
end

-- Post-hook body for Server_SendChatMessage (ctx = PlayerChatComponent param, msg/filter = params).
-- Exposed for tests; the hook calls it through M so the logic lives in one place.
function M._on_chat(ctx, msg_param, filter_param)
    local s = state()
    if s.relaying then return end -- our own re-send also passes through this hook
    local text = U.try(function() return msg_param:get().MessageBody:ToString() end)
    if type(text) ~= "string" then return end
    local lines = {}
    if s.triggers and text:sub(1, 6) == "!echo " then
        lines[#lines + 1] = { body = M.ECHO_PREFIX .. text:sub(7), bot = false, kind = "echo" }
    elseif s.triggers and text:sub(1, 4) == "!as " then
        lines[#lines + 1] = { body = text:sub(5), bot = true, kind = "as" }
    end
    for _, t in ipairs(take_pending(s)) do lines[#lines + 1] = { body = t, bot = true, kind = "say" } end
    if #lines == 0 then return end
    s.relaying = true
    for _, l in ipairs(lines) do
        local ok, err = U.call(nil, "speech.relay_Server_SendChatMessage", { kind = l.kind, len = #l.body }, function()
            local msg = msg_param:get()
            if l.bot then U.guid_set(msg.SenderData.CharacterGuid, M.GUID) end
            msg.MessageBody = l.body:sub(1, M.MAX_LEN)
            ctx:get():Server_SendChatMessage(msg, filter_param:get())
        end)
        if ok then s.sent = s.sent + 1 end
        U.event(nil, "speech_relay", { ok = ok, err = (not ok) and tostring(err) or nil, kind = l.kind, text = l.body })
    end
    s.relaying = false
end

-- Register the relay post-hook once per server run. opts.triggers (default true): honour the
-- "!as " / "!echo " debug triggers. Returns {armed, already, err}.
function M.arm_relay(log, opts)
    opts = opts or {}
    local s = state()
    if opts.triggers ~= nil then s.triggers = opts.triggers and true or false end
    if s.armed then return { armed = true, already = true, triggers = s.triggers } end
    if type(RegisterHook) ~= "function" then return { armed = false, err = "RegisterHook unavailable" } end
    local ok, err = U.call(log, "speech.RegisterHook", { fn = M.CHAT_FN }, function()
        RegisterHook(M.CHAT_FN, function() end, function(ctx, msg_param, filter_param)
            local hok, herr = pcall(M._on_chat, ctx, msg_param, filter_param)
            if not hok then state().relaying = false; U.event(nil, "speech_relay_error", { err = tostring(herr) }) end
        end)
    end)
    s.armed, s.arm_err = ok, (not ok) and tostring(err) or nil
    U.event(log, "speech_relay_armed", { ok = ok, err = s.arm_err, triggers = s.triggers })
    return { armed = ok, err = s.arm_err, triggers = s.triggers }
end

local function enqueue(s, text)
    s.queue[#s.queue + 1] = { text = text, t = now() }
    while #s.queue > M.QUEUE_MAX do table.remove(s.queue, 1); s.dropped = s.dropped + 1 end
end

-- ------------------------------------------------------------------ direct (on-demand)
-- The first connected player that is not the bot: its PlayerChat sends, its PlayerState supplies
-- the copied net ids (the bot's PS carries the same AccountGuid, see body/identity.lua).
local function direct_host()
    for _, pc in ipairs(U.player_controllers()) do
        local ps = U.try(function() return pc.PlayerState end)
        local chat = U.try(function() return pc.PlayerChat end)
        if U.alive(ps) and U.valid(chat) and not U.try(function() return ps.bIsABot end) then return pc, ps, chat end
    end
end

-- A struct value is only engine-copied when it IS a UScriptStruct userdata.
local function struct_ud(v)
    if v == nil then return false end
    local ok, t = pcall(function() return v:type() end)
    return (not ok) or t == "UScriptStruct" -- fakes in tests have no :type()
end

-- The call's own params: SCALARS ONLY (never a userdata inside a table: UE4SS bug, see header).
function M.direct_message(host_ps, text)
    local msg = {
        SenderData = {
            CharacterGuid = { A = M.GUID.A, B = M.GUID.B, C = M.GUID.C, D = M.GUID.D },
            PlayerId = U.try(function() return host_ps.PlayerId end) or 0,
            Color = { R = M.COLOR.R, G = M.COLOR.G, B = M.COLOR.B, A = M.COLOR.A },
        },
        MessageBody = text:sub(1, M.MAX_LEN),
    }
    return msg, {}
end

-- PRE-hook body (one-shot): copy the net ids into the live param buffer by property assignment.
-- Exposed for tests. Runs only while s.direct_job is set, i.e. inside our own send.
function M._direct_patch(ctx, msg_param, filter_param)
    local s = state()
    local job = s.direct_job
    if not job or job.done then return end
    job.done = true
    local m = msg_param:get()
    if not M.is_bot_guid(m.SenderData.CharacterGuid) then job.err = "not our message"; return end
    local sd = m.SenderData
    sd.PrimaryNetId = job.acct.NetIdPrimary     -- __newindex: CopyCompleteValue from the live PS
    sd.SecondaryNetId = job.acct.NetIdSecondary
    local f = filter_param:get()
    f.SenderId = job.uid
    if job.receivers then
        local arr = f.ReceiverIds
        for i, rid in ipairs(job.receivers) do arr[i] = rid end -- AddZeroed + CopyCompleteValue per element
        job.receivers_set = U.try(function() return arr:GetArrayNum() end)
    end
    job.patched = true
end

-- Register the pre-hook once per run; it dispatches to the latest loaded module's _direct_patch.
function M.arm_direct(log)
    local s = state()
    rawset(_G, "__dw_speech_direct_patch", M._direct_patch)
    if s.direct_armed then return { armed = true, already = true } end
    if type(RegisterHook) ~= "function" then return { armed = false, err = "RegisterHook unavailable" } end
    local ok, err = U.call(log, "speech.RegisterHook_direct", { fn = M.CHAT_FN }, function()
        RegisterHook(M.CHAT_FN, function(ctx, a, b)
            local f = rawget(_G, "__dw_speech_direct_patch")
            if f then
                local hok, herr = pcall(f, ctx, a, b)
                if not hok then
                    local job = state().direct_job
                    if job then job.err = tostring(herr) end
                    U.event(nil, "speech_direct_patch_error", { err = tostring(herr) })
                end
            end
        end, function() end)
    end)
    s.direct_armed = ok
    return { armed = ok, err = (not ok) and tostring(err) or nil }
end

-- On-demand send. Returns ok, err. Disables itself for the run if the pre-hook ever fails to patch
-- (that message would have carried empty net ids: the client-freeze shape).
function M.send_direct(log, text)
    local s = state()
    if s.direct_disabled then return false, "direct disabled: " .. s.direct_disabled end
    local armed = M.arm_direct(log)
    if not armed.armed then return false, "arm: " .. tostring(armed.err) end
    local pc, ps, chat = direct_host()
    if not pc then return false, "no connected player" end
    local acct = U.try(function() return ps.OwnerGuid.AccountGuid end)
    local uid = U.try(function() return ps.UniqueID end)
    if not (acct and struct_ud(U.try(function() return acct.NetIdPrimary end))
            and struct_ud(U.try(function() return acct.NetIdSecondary end)) and struct_ud(uid)) then
        return false, "net id source is not a live struct"
    end
    M.register_names(log)
    local msg, filter = M.direct_message(ps, text)
    local job = { acct = acct, uid = uid }
    if M.DIRECT_FILL_RECEIVERS then
        job.receivers = {}
        for _, rpc in ipairs(U.player_controllers()) do
            local rps = U.try(function() return rpc.PlayerState end)
            local rid = U.alive(rps) and U.try(function() return rps.UniqueID end)
            if rid and struct_ud(rid) then job.receivers[#job.receivers + 1] = rid end
        end
    end
    s.direct_job, s.relaying = job, true -- our send passes every chat hook: never a template/command
    local ok, err = U.call(log, "speech.direct_Server_SendChatMessage", { pc = U.short(pc), len = #text }, function()
        chat:Server_SendChatMessage(msg, filter)
    end)
    s.direct_job, s.relaying = nil, false
    if not job.patched then
        s.direct_disabled = job.err or "pre-hook did not run"
        U.event(log, "speech_direct_unpatched", { err = s.direct_disabled, call_ok = ok })
        return false, "unpatched: " .. s.direct_disabled
    end
    if ok then s.sent = s.sent + 1 end
    U.event(log, "speech_direct", { ok = ok, err = (not ok) and tostring(err) or nil, text = text,
                                    receivers = job.receivers_set })
    return ok, (not ok) and tostring(err) or nil
end

local function say_direct(log, text) return M.send_direct(log, text) end

-- ------------------------------------------------------------------ legacy Client_* modes
local function legacy_message(text)
    return { SenderData = { CharacterGuid = M.GUID, PlayerId = M.PLAYER_ID, Color = M.COLOR }, MessageBody = text }
end

local function send_chat(log, pc, text)
    local chat = U.try(function() return pc.PlayerChat end)
    if not U.valid(chat) then return false, "no PlayerChat" end
    return U.call(log, "say.Client_ReceiveChatMessage", { pc = U.short(pc), len = #text }, function()
        chat:Client_ReceiveChatMessage(legacy_message(text))
    end)
end

local function send_notify(log, pc, text)
    return U.call(log, "say.Client_DisplayTextNotification", { pc = U.short(pc), len = #text }, function()
        local tag = { TagName = FName and FName("None") or "None" }
        local ftext = FText and FText(text) or text
        pc:Client_DisplayTextNotification(tag, ftext)
    end)
end

local function say_legacy(log, mode, text)
    local s = state()
    if mode == "chat" and os.getenv("DW_SAY_REGISTER_NAME") == "1" and not s.legacy_registered then
        s.legacy_registered = true
        M.register_names(log)
    end
    local pcs = U.player_controllers()
    local sent, methods, errors = 0, {}, {}
    for _, pc in ipairs(pcs) do
        local ok, err = false, nil
        if mode == "chat" then
            ok, err = send_chat(log, pc, text)
            if ok then methods.chat = true end
        end
        if not ok then
            if err then errors[#errors + 1] = tostring(err) end
            ok, err = send_notify(log, pc, text)
            if ok then methods.notify = true elseif err then errors[#errors + 1] = tostring(err) end
        end
        if ok then sent = sent + 1 end
    end
    local method = (methods.chat and methods.notify) and "mixed" or (methods.chat and "chat") or (methods.notify and "notify") or "none"
    local data = { method = method, recipients = sent, players = #pcs, verified = false, text = text }
    if #pcs > 0 and sent == 0 then
        data.errors = errors
        return U.fail("body_error", data)
    end
    return U.ok(data)
end

-- ------------------------------------------------------------------ say (public API, unchanged)
-- Returns {ok, reason, data}. ok means the text was accepted (logged, queued or the calls made
-- without a Lua error); delivery to a client is NOT verified (data.verified=false).
function M.say(log, text)
    if type(text) ~= "string" or text == "" then
        return U.fail("invalid_args", { detail = "text must be a non-empty string" })
    end
    text = text:sub(1, M.MAX_LEN)
    local mode = M.mode()
    U.event(log, "say", { text = text, mode = mode })
    if mode == "log" then return U.ok({ method = "log", recipients = 0, verified = false }) end
    local direct_err
    if mode == "direct" then
        local ok, err = say_direct(log, text)
        if ok then return U.ok({ method = "direct", queued = false, verified = false, on_demand = true }) end
        direct_err = err -- fall back to the relay queue below
    end
    if mode == "relay" or mode == "direct" then
        local s = state()
        local armed = M.arm_relay(log)
        if not armed.armed then return U.fail("body_error", { method = "relay", detail = armed.err }) end
        M.register_names(log)
        enqueue(s, text)
        return U.ok({ method = "relay", queued = true, pending = #s.queue, verified = false, on_demand = false,
                      direct_err = direct_err,
                      detail = "delivered with the next player chat line" })
    end
    return say_legacy(log, mode, text)
end

-- Capability/status report (bridge handler speech_status in main.lua).
function M.status()
    local s = state()
    return {
        mode = M.mode(), name = M.NAME, bot_guid = U.guid_hex(M.GUID),
        capabilities = { log = true, relay = s.armed, on_demand = M.mode() == "direct" },
        relay_armed = s.armed, relay_err = s.arm_err, triggers = s.triggers,
        direct_armed = s.direct_armed == true, direct_disabled = s.direct_disabled,
        pending = #s.queue, sent = s.sent, dropped = s.dropped,
        gap = M.mode() == "direct" and "direct: on-demand; failures fall back to the relay queue"
            or "relay needs a player's chat line to piggy-back on (DW_SAY_MODE=direct speaks on demand)",
    }
end

-- Test hook: forget all state (a hook already registered with the fake stays registered).
function M._reset()
    rawset(_G, "__dw_speech", nil)
    M.DEFAULT_MODE = LOG_DEFAULT
end

return M
