-- On-demand speech experiment: say "Claude: <text>" in chat WITHOUT a triggering player line.
--
-- Route: the server's own PlayerChatComponent:Server_SendChatMessage on a connected player's
-- PlayerChat (as the verified relay does), with an FChatMessageData passed as a Lua table whose
-- network fields are userdata COPIED from live engine structs, never built:
--   SenderData.PrimaryNetId   <- host_ps.OwnerGuid.AccountGuid.NetIdPrimary   (FUniqueNetIdRepl)
--   SenderData.SecondaryNetId <- host_ps.OwnerGuid.AccountGuid.NetIdSecondary (FUniqueNetIdRepl)
--   SenderData.CharacterGuid  =  the bot GUID (scalars)
--   SenderData.PlayerId/Color =  scalars (as in a genuine line)
--   Filter.SenderId           <- host_ps.UniqueID (FUniqueNetIdRepl); ReceiverIds left empty
-- UE4SS marshalling (RE-UE4SS LuaUObject.cpp, identical at our build 83330635): the param buffer is
-- Memzero'd; a table goes through convert_lua_table_to_struct, which runs push_structproperty(Set)
-- per field; a struct field given as userdata of the SAME UScriptStruct is written with
-- FStructProperty::CopyCompleteValue (the engine copy, FUniqueNetIdRepl's operator=). That is the
-- same path the verified relay already uses for the whole genuine FChatMessageData.
--
-- debug_run {module="speech_direct", args={action=...}}:
--   ids      (default) read-only: net id strings (ConvertUniqueNetIdToJsonString) of each PS source
--   capture  arm a passive post-hook that records the next GENUINE chat line's SenderData/filter
--   status   captured data + which PS sources match the genuine fields
--   send     {confirm=true, text=...}: ONE direct message. Client-affecting: needs Luis's go-ahead.
local U = require("body.util")
local speech = require("body.speech")

local M = {}
M.CHAT_FN = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage"
M.LIB = "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary"

local function st()
    local s = rawget(_G, "__dw_speech_direct")
    if not s then s = { armed = false, captures = {}, sends = 0 }; rawset(_G, "__dw_speech_direct", s) end
    return s
end

local function lib() return U.find_object(M.LIB) end

-- Net id -> JSON string via the game's own BP library (struct param copied by CopyCompleteValue).
local function idstr(ud)
    if ud == nil then return nil end
    local l = lib()
    if not U.valid(l) then return "no_lib" end
    local ok, r = pcall(function() return l:ConvertUniqueNetIdToJsonString(ud) end)
    if not ok then return "err:" .. tostring(r) end
    return U.str(r) or tostring(r)
end

local function udtype(ud)
    local ok, t = pcall(function() return ud:type() end)
    return ok and t or type(ud)
end

local function host()
    local _, puppets = U.split_pawns()
    local bot = puppets[1]
    local bps = bot and U.try(function() return bot.PlayerState end)
    for _, pc in ipairs(U.player_controllers()) do
        local ps = U.try(function() return pc.PlayerState end)
        if U.alive(ps) and ps ~= bps then return pc, ps, bps end
    end
    return nil, nil, bps
end

local function ps_ids(ps)
    if not U.valid(ps) then return nil end
    return {
        ps = U.fullname(ps),
        player_id = U.try(function() return ps.PlayerId end),
        unique_id = idstr(U.try(function() return ps.UniqueID end)),
        acct_primary = idstr(U.try(function() return ps.OwnerGuid.AccountGuid.NetIdPrimary end)),
        acct_secondary = idstr(U.try(function() return ps.OwnerGuid.AccountGuid.NetIdSecondary end)),
        char_guid = U.guid_hex(U.try(function() return ps.OwnerGuid.CharacterGuid.InnerGuid end)),
        unique_id_type = udtype(U.try(function() return ps.UniqueID end)),
    }
end

-- ------------------------------------------------------------------ passive capture
function M._on_chat(ctx, msg_param, filter_param)
    local s = st()
    if #s.captures >= 5 then return end
    local msg = msg_param:get()
    local g = U.try(function() return msg.SenderData.CharacterGuid end)
    if speech.is_bot_guid(g) then return end -- our own sends
    local f = filter_param:get()
    local rec = {
        t = os.time(),
        component = U.fullname(ctx:get()),
        text_len = #(U.try(function() return msg.MessageBody:ToString() end) or ""),
        player_id = U.try(function() return msg.SenderData.PlayerId end),
        color = U.try(function() local c = msg.SenderData.Color; return { R = c.R, G = c.G, B = c.B, A = c.A } end),
        character_guid = U.guid_hex(g),
        primary = idstr(U.try(function() return msg.SenderData.PrimaryNetId end)),
        secondary = idstr(U.try(function() return msg.SenderData.SecondaryNetId end)),
        filter_sender = idstr(U.try(function() return f.SenderId end)),
        receivers = U.try(function() return f.ReceiverIds:GetArrayNum() end),
    }
    local rs = {}
    pcall(function() f.ReceiverIds:ForEach(function(_, e) rs[#rs + 1] = idstr(e:get()) end) end)
    rec.receiver_ids = rs
    s.captures[#s.captures + 1] = rec
    U.event(nil, "speech_direct_capture", rec)
end

local function arm(log)
    local s = st()
    if s.armed then return { armed = true, already = true } end
    local ok, err = U.call(log, "speech_direct.RegisterHook", { fn = M.CHAT_FN }, function()
        RegisterHook(M.CHAT_FN, function() end, function(ctx, a, b)
            local h = rawget(_G, "__dw_speech_direct_cb") -- latest loadfile'd version
            if h then
                local hok, herr = pcall(h, ctx, a, b)
                if not hok then U.event(nil, "speech_direct_capture_error", { err = tostring(herr) }) end
            end
        end)
    end)
    s.armed = ok
    return { armed = ok, err = (not ok) and tostring(err) or nil }
end

-- ------------------------------------------------------------------ build + send
-- Every network field is a userdata pointing at a live engine struct; the rest are scalars.
function M.build(host_ps, text, opts)
    opts = opts or {}
    local acct = host_ps.OwnerGuid.AccountGuid
    local pid = opts.player_id or U.try(function() return host_ps.PlayerId end) or 0
    local c = opts.color or speech.COLOR
    local msg = {
        SenderData = {
            PrimaryNetId = acct.NetIdPrimary,
            SecondaryNetId = acct.NetIdSecondary,
            CharacterGuid = { A = speech.GUID.A, B = speech.GUID.B, C = speech.GUID.C, D = speech.GUID.D },
            PlayerId = pid,
            Color = { R = c.R, G = c.G, B = c.B, A = c.A },
        },
        MessageBody = text:sub(1, speech.MAX_LEN),
    }
    local filter = { SenderId = (opts.filter_sender == "account") and acct.NetIdPrimary or host_ps.UniqueID }
    return msg, filter
end

local function check_types(msg, filter)
    for name, ud in pairs({ primary = msg.SenderData.PrimaryNetId, secondary = msg.SenderData.SecondaryNetId,
                            filter_sender = filter.SenderId }) do
        if udtype(ud) ~= "UScriptStruct" then return false, name .. " is " .. tostring(udtype(ud)) end
    end
    return true
end

local function send(log, args)
    if args.confirm ~= true then
        return { ok = false, error = "refused: send is client-affecting; pass confirm=true (Luis's go-ahead)" }
    end
    local text = type(args.text) == "string" and args.text ~= "" and args.text or "Hello, it's Claude."
    local pc, hps = host()
    if not pc then return { ok = false, error = "no connected player" } end
    local chat = U.try(function() return pc.PlayerChat end)
    if not U.valid(chat) then return { ok = false, error = "no PlayerChat" } end
    local reg = speech.register_names(log) -- (each player's account, bot GUID) -> "Claude"; once per run
    local msg, filter = M.build(hps, text, args)
    local tok, terr = check_types(msg, filter)
    if not tok then return { ok = false, error = "refused: " .. terr } end
    local sp = rawget(_G, "__dw_speech")
    if sp then sp.relaying = true end -- relay hook (if armed) must not treat this as a template
    local ok, err = U.call(log, "speech_direct.Server_SendChatMessage", { pc = U.short(pc), len = #text }, function()
        chat:Server_SendChatMessage(msg, filter)
    end)
    if sp then sp.relaying = false end
    st().sends = st().sends + 1
    U.event(log, "speech_direct_send", { ok = ok, err = (not ok) and tostring(err) or nil, text = text })
    return { ok = ok, err = (not ok) and tostring(err) or nil, text = text, names = reg, host = U.fullname(hps) }
end

-- ------------------------------------------------------------------ entry
function M.run(log, args)
    args = args or {}
    rawset(_G, "__dw_speech_direct_cb", M._on_chat)
    local action = args.action or "ids"
    if action == "send" then return send(log, args) end
    if action == "capture" then
        local a = arm(log)
        return { ok = a.armed, arm = a, captures = st().captures }
    end
    local pc, hps, bps = host()
    local out = { ok = true, host = ps_ids(hps), bot = ps_ids(bps), armed = st().armed, sends = st().sends }
    if action == "status" then
        out.captures = st().captures
        local c, h = st().captures[#st().captures], out.host
        if c and h then
            out.match = {
                primary_is_acct_primary = c.primary == h.acct_primary,
                secondary_is_acct_secondary = c.secondary == h.acct_secondary,
                primary_is_unique_id = c.primary == h.unique_id,
                filter_sender_is_unique_id = c.filter_sender == h.unique_id,
                filter_sender_is_acct_primary = c.filter_sender == h.acct_primary,
                receivers_empty = c.receivers == 0,
                player_id_is_ps = c.player_id == h.player_id,
            }
        end
    end
    return out
end

return M
