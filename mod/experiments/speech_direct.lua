-- On-demand speech experiment: say "Claude: <text>" in chat WITHOUT a triggering player line.
--
-- HISTORY: v1 passed Server_SendChatMessage a Lua table whose SenderData held FUniqueNetIdRepl
-- USERDATA (live PS structs). That CRASHED THE SERVER (crash_2026_10_25_15_45_24, 14:45:24 UTC):
-- UE4SS bug (83330635 and main) - push_structproperty's userdata branch calls
-- get_userdata<UScriptStruct>() with the default stack index 1, not params.stored_at_index, so a
-- struct userdata nested inside a table is read from the wrong slot (the outer table) -> AV.
-- Top-level struct userdata params (the relay) and property assignment (__newindex: self and key are
-- removed first, the value is at index 1) are fine. Never put a struct userdata inside a table.
--
-- v2 (body/speech.lua send_direct): call with SCALAR-ONLY tables, and a one-shot PRE-hook on
-- Server_SendChatMessage copies the net ids into the live param buffer by property assignment.
-- That relies on the native implementation reading the same param buffer the pre-hook edits:
-- action=prove checks exactly that, read-only, on DisplayNameComponent:GetCharacterDisplayName.
--
-- debug_run {module="speech_direct", args={action=...}}:
--   ids      (default) read-only: net id strings (ConvertUniqueNetIdToJsonString) of each PS source
--   capture  arm a passive post-hook that records the next GENUINE chat line's SenderData/filter
--   status   captured data + which PS sources match the genuine fields
--   prove    READ-ONLY proof that pre-hook edits reach native code (needs a connected player):
--            name of (empty account, host CharacterGuid) without / with the pre-hook patching in the
--            host's NetIdPrimary/Secondary, vs the control (host's own OwnerGuid).
--   send     {confirm=true, text=...}: ONE direct message via a fresh load of body/speech.lua's
--            send_direct. Refuses unless prove passed this run (or force_unproven=true).
--            Client-affecting: needs Luis's go-ahead.
local U = require("body.util")

local M = {}
M.CHAT_FN = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage"
M.DN_FN = "/Script/Dominion.DisplayNameComponent:GetCharacterDisplayName"
M.LIB = "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary"
M.BOT = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }

local function st()
    local s = rawget(_G, "__dw_speech_direct")
    if not s then s = { armed = false, captures = {}, sends = 0 }; rawset(_G, "__dw_speech_direct", s) end
    return s
end

local function here_dir()
    local src = debug.getinfo(1, "S").source
    return (src:sub(1, 1) == "@" and src:sub(2) or src):match("^(.*)[/\\]experiments[/\\][^/\\]+$")
end

-- The CURRENT body/speech.lua from disk (the server keeps the copy it loaded at start). It shares
-- state with the loaded one through _G.__dw_speech.
local function fresh_speech()
    local root = here_dir()
    local chunk = root and loadfile(root .. "/body/speech.lua")
    if chunk then return chunk() end
    return require("body.speech")
end

local function idstr(ud)
    if ud == nil then return nil end
    local l = U.find_object(M.LIB)
    if not U.valid(l) then return "no_lib" end
    local ok, r = pcall(function() return l:ConvertUniqueNetIdToJsonString(ud) end) -- top-level userdata: safe
    if not ok then return "err:" .. tostring(r) end
    return U.str(r) or tostring(r)
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
    }
end

-- Register `fn` once per run with a pre- or post-callback that dispatches to _G[key] (latest code).
local function hook_once(log, flag, fn, key, pre)
    local s = st()
    if s[flag] then return true end
    local function dispatch(ctx, a, b)
        local h = rawget(_G, key)
        if h then
            local ok, err = pcall(h, ctx, a, b)
            if not ok then U.event(nil, "speech_direct_hook_error", { key = key, err = tostring(err) }) end
        end
    end
    local ok, err = U.call(log, "speech_direct.RegisterHook", { fn = fn, pre = pre }, function()
        if pre then RegisterHook(fn, dispatch, function() end) else RegisterHook(fn, function() end, dispatch) end
    end)
    s[flag] = ok
    return ok, err
end

-- ------------------------------------------------------------------ passive capture
function M._on_chat(ctx, msg_param, filter_param)
    local s = st()
    if #s.captures >= 5 then return end
    local msg = msg_param:get()
    local g = U.try(function() return msg.SenderData.CharacterGuid end)
    if U.guid_eq(g, M.BOT) then return end -- our own sends
    local f = filter_param:get()
    local rec = {
        t = os.time(),
        text_len = #(U.try(function() return msg.MessageBody:ToString() end) or ""),
        player_id = U.try(function() return msg.SenderData.PlayerId end),
        color = U.try(function() local c = msg.SenderData.Color; return { R = c.R, G = c.G, B = c.B, A = c.A } end),
        character_guid = U.guid_hex(g),
        primary = idstr(U.try(function() return msg.SenderData.PrimaryNetId end)),
        secondary = idstr(U.try(function() return msg.SenderData.SecondaryNetId end)),
        filter_sender = idstr(U.try(function() return f.SenderId end)),
        receivers = U.try(function() return f.ReceiverIds:GetArrayNum() end),
    }
    s.captures[#s.captures + 1] = rec
    U.event(nil, "speech_direct_capture", rec)
end

-- ------------------------------------------------------------------ prove (read-only)
function M._prove_patch(ctx, og_param, _)
    local job = st().prove_job
    if not job or job.done then return end
    job.done = true
    local og = og_param:get()
    og.AccountGuid.NetIdPrimary = job.acct.NetIdPrimary     -- the same __newindex copy send_direct uses
    og.AccountGuid.NetIdSecondary = job.acct.NetIdSecondary
    job.patched = true
end

local function prove(log)
    local s = st()
    local _, hps = host()
    if not hps then return { ok = false, error = "needs a connected player" } end
    local gs = U.find_first("DominionGameStateBase")
    local dn = gs and U.try(function() return gs.DisplayNameComponent end)
    if not U.valid(dn) then return { ok = false, error = "no DisplayNameComponent" } end
    rawset(_G, "__dw_speech_direct_prove", M._prove_patch)
    local armed, aerr = hook_once(log, "prove_armed", M.DN_FN, "__dw_speech_direct_prove", true)
    if not armed then return { ok = false, error = "hook: " .. tostring(aerr) } end
    local g = U.guid_copy(hps.OwnerGuid.CharacterGuid.InnerGuid)
    local function scalar_owner() return { CharacterGuid = { InnerGuid = { A = g.A, B = g.B, C = g.C, D = g.D } } } end
    local function name_of(og)
        local ok, r = U.call(log, "speech_direct.GetCharacterDisplayName", {}, function()
            return dn:GetCharacterDisplayName(og, "NOPE")
        end)
        return ok and (U.str(r) or tostring(r)) or ("err:" .. tostring(r))
    end
    local control = name_of(hps.OwnerGuid)        -- top-level userdata (genuine): safe
    local base = name_of(scalar_owner())          -- empty account
    local job = { acct = hps.OwnerGuid.AccountGuid }
    s.prove_job = job
    local patched = name_of(scalar_owner())       -- empty account, patched by the pre-hook
    s.prove_job = nil
    local pass = job.patched == true and patched == control and base ~= control and control ~= "NOPE"
    s.proven = pass
    U.event(log, "speech_direct_prove", { control = control, base = base, patched = patched, hook_ran = job.patched, pass = pass })
    return { ok = true, pass = pass, control = control, base = base, patched = patched, hook_ran = job.patched == true }
end

-- ------------------------------------------------------------------ send (production code path)
local function send(log, args)
    if args.confirm ~= true then
        return { ok = false, error = "refused: send is client-affecting; pass confirm=true (Luis's go-ahead)" }
    end
    if not st().proven and args.force_unproven ~= true then
        return { ok = false, error = "refused: run action=prove first (it must pass this run)" }
    end
    local text = type(args.text) == "string" and args.text ~= "" and args.text or "Hello, it's Claude."
    local speech = fresh_speech()
    if type(speech.send_direct) ~= "function" then return { ok = false, error = "body/speech.lua has no send_direct" } end
    local ok, err = speech.send_direct(log, text)
    st().sends = st().sends + 1
    return { ok = ok, err = err, text = text, status = speech.status() }
end

-- ------------------------------------------------------------------ entry
function M.run(log, args)
    args = args or {}
    rawset(_G, "__dw_speech_direct_cb", M._on_chat)
    local action = args.action or "ids"
    if action == "send" then return send(log, args) end
    if action == "prove" then return prove(log) end
    if action == "capture" then
        local ok, err = hook_once(log, "armed", M.CHAT_FN, "__dw_speech_direct_cb", false)
        return { ok = ok, err = err and tostring(err), captures = st().captures }
    end
    local _, hps, bps = host()
    local out = { ok = true, host = ps_ids(hps), bot = ps_ids(bps), armed = st().armed, proven = st().proven,
                  sends = st().sends }
    if action == "status" then
        out.captures = st().captures
        local c, h = st().captures[#st().captures], out.host
        if c and h then
            out.match = {
                primary_is_acct_primary = c.primary == h.acct_primary,
                secondary_is_acct_secondary = c.secondary == h.acct_secondary,
                filter_sender_is_unique_id = c.filter_sender == h.unique_id,
                receivers_empty = c.receivers == 0,
                player_id_is_ps = c.player_id == h.player_id,
            }
        end
    end
    return out
end

return M
