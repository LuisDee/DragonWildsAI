-- chat.lua: text chat for Claude's own game CLIENT (route R2). Uses only the game's player code paths.
--
-- RECEIVE: post-hook on PlayerChatComponent:Client_ReceiveChatMessage, the reliable client RPC the
--   server sends to every receiver (the sender too) for each chat line. It is the same delivery
--   every player's client gets; ChatWidget:OnChatMessageReceived (the chat box) is fed from it via
--   the OnChatMessageReceived delegate. Each line is appended to <ROOT>/client_io/events/chat.jsonl:
--     {"type":"chat","from":"Zezima","text":"...","ts":1761417600,"iso":"...Z","self":false,
--      "player_id":258,"guid":"<32 hex>"}
--   Chat errors (spam warning etc.) go to the same file as {"type":"chat_error","text":...}, and
--   player events (join/leave tags) as {"type":"chat_event","from":...,"tag":...}.
-- SEND: M.say(log, text) does what the chat box does on Enter: it puts the text into the live
--   OpenedChatSubWidget.MessageSendBox and calls the widget's own OnTextCommitted(Text, OnEnter),
--   the handler bound to that EditableText's commit. Native code then builds FChatMessageData from
--   Claude's real identity and calls Server_SendChatMessage. No struct is built in Lua.
--
-- Hot-reload safe: state lives in _G.DWChat; hooks are registered once and dispatch to the newest
-- handlers, so loadfile()+start() again swaps the code without stacking hooks.
-- L28: never spawn a process on a hot path. A directory is created only if it is really missing
-- (an open-for-append probe), and only once per load (cached).
local DIRS_OK = {}
local function ensure_dir(d)
    d = tostring(d):gsub("\\", "/")
    if DIRS_OK[d] then return end
    local probe = d .. "/.dwclient_probe"
    local f = io.open(probe, "a")
    if f then f:close(); os.remove(probe); DIRS_OK[d] = true; return end
    if package.config:sub(1, 1) == "\\" then os.execute('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul')
    else os.execute('mkdir -p "' .. d .. '"') end
    DIRS_OK[d] = true
end
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
local EVENTS_DIR = ROOT .. "/client_io/events"
local EVENTS_PATH = EVENTS_DIR .. "/chat.jsonl"

local json = assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()

local M = { EVENTS_PATH = EVENTS_PATH }
local S = _G.DWChat or { hooks = {}, names = {}, sent = {}, counts = { rx = 0, ui = 0, err = 0, ev = 0 } }
_G.DWChat = S

local F_RECV = "/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage"
local F_EVENT = "/Script/JagexChatBackend.PlayerChatComponent:Client_ReceivePlayerEvent"
local F_UI = "/Script/Dominion.ChatWidget:OnChatMessageReceived"
local F_UIERR = "/Script/Dominion.ChatWidget:OnChatErrorMessageReceived"
local ETEXTCOMMIT_ONENTER = 1 -- SlateCore ETextCommit::OnEnter

local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
local function alive(o) return o ~= nil and try(function() return o:IsValid() end) == true end

local function guid_hex(g)
    return try(function()
        return string.format("%08X%08X%08X%08X", g.A % 0x100000000, g.B % 0x100000000, g.C % 0x100000000, g.D % 0x100000000)
    end)
end

local function emit(ev)
    ev.ts = ev.ts or os.time()
    ev.iso = os.date("!%Y-%m-%dT%H:%M:%SZ", ev.ts)
    local line = try(function() return json.encode(ev) end)
    if not line then return end
    local f = io.open(EVENTS_PATH, "a")
    if f then f:write(line, "\n"); f:close() end
end

-- The local player's controller (this client has exactly one live BP_PlayerController_C).
local function local_pc()
    for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
        if alive(pc) and not pc:GetFullName():find("Default__", 1, true) then return pc end
    end
    return nil
end

local function local_guid()
    local pc = local_pc()
    return pc and try(function() return guid_hex(pc.PlayerState.OwnerGuid.CharacterGuid.InnerGuid) end)
end

-- Sender name, resolved the way the chat box does: CharacterGuid -> the replicated
-- DisplayNameComponent.SanitizedCharacterNames entry. Fallbacks: the PlayerState with that
-- CharacterGuid, then the PlayerState with that PlayerId.
local function resolve_name(guid, player_id)
    if guid and S.names[guid] then return S.names[guid] end
    local name
    if guid then
        for _, dn in ipairs(FindAllOf("DisplayNameComponent") or {}) do
            if name then break end
            if alive(dn) and not dn:GetFullName():find("Default__", 1, true) then
                pcall(function()
                    dn.SanitizedCharacterNames:ForEach(function(_, elem)
                        if name then return end
                        local e = elem:get()
                        if guid_hex(e.CharacterGuid.InnerGuid) == guid then
                            local n = try(function() return e.CharacterName:ToString() end)
                            if n and n ~= "" then name = n end
                        end
                    end)
                end)
            end
        end
    end
    if not name then
        for _, ps in ipairs(FindAllOf("DominionPlayerState") or {}) do
            if alive(ps) and not ps:GetFullName():find("Default__", 1, true) then
                local g = try(function() return guid_hex(ps.OwnerGuid.CharacterGuid.InnerGuid) end)
                local pid = try(function() return ps.PlayerId end)
                if (guid and g == guid) or (not guid and player_id and pid == player_id) then
                    name = try(function() return ps:GetPlayerName():ToString() end)
                    break
                end
            end
        end
    end
    if name and guid then S.names[guid] = name end
    return name
end

-- Read a FChatPlayerSenderData (property reads only).
local function sender(sd)
    local guid = try(function() return guid_hex(sd.CharacterGuid) end)
    local pid = try(function() return sd.PlayerId end)
    return guid, pid, resolve_name(guid, pid) or ("player" .. tostring(pid or "?"))
end

-- ---------------------------------------------------------------- hook handlers (swappable)
function S.on_receive(_, msg_param)
    local m = msg_param:get()
    local text = try(function() return m.MessageBody:ToString() end) or ""
    local guid, pid, from = sender(m.SenderData)
    S.counts.rx = S.counts.rx + 1
    local me = local_guid()
    emit({ type = "chat", from = from, text = text, self = (guid ~= nil and guid == me), player_id = pid, guid = guid })
end

function S.on_event(_, ev_param)
    local e = ev_param:get()
    local guid, pid, from = sender(e.SenderData)
    local tag = try(function() return e.Tag.TagName:ToString() end)
    S.counts.ev = S.counts.ev + 1
    emit({ type = "chat_event", from = from, tag = tag, player_id = pid, guid = guid })
end

function S.on_ui() S.counts.ui = S.counts.ui + 1 end

function S.on_ui_error(_, text_param)
    local text = try(function() return text_param:get():ToString() end)
    S.counts.err = S.counts.err + 1
    emit({ type = "chat_error", text = text })
end

local HUB
local function hub()
    if not HUB then
        local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]")) or (ROOT .. "/client_mod/scripts")
        HUB = assert(loadfile(dir .. "/hookhub.lua"))()
    end
    return HUB
end

-- BUGS L24: one native hook per path per process via the hub (never unregistered; the callback is
-- skipped while DW_PAUSE); registered only with a pawn in the game world
local function local_pawn()
    local ok, p = pcall(function()
        local pc = FindFirstOf("PlayerController")
        return pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() and pc.Pawn or nil
    end)
    return ok and p or nil
end
local function register(path, handler_name, log)
    if S.hooks[path] then return true end
    local ok = hub().on(path, "chat:" .. handler_name, function(...)
        local st = rawget(_G, "DWChat") or S
        local h = st[handler_name] or S[handler_name]
        if h then h(...) end
    end, { defer = hub().not_in_world(local_pawn()), log = log })
    if ok then S.hooks[path] = true end
    if log then log("chat hook " .. path .. " native=" .. tostring(ok)) end
    return ok
end

-- Install the receive hooks (idempotent). Returns {ok, reason, data}.
function M.start(log)
    ensure_dir(EVENTS_DIR)
    local results = {
        receive = register(F_RECV, "on_receive", log),
        player_event = register(F_EVENT, "on_event", log),
        -- (the ChatWidget UI hooks F_UI / F_UIERR are no longer registered: widgets are torn down first on
        --  a disconnect, and they only counted; BUGS L24)
    }
    return { ok = results.receive, reason = (not results.receive) and "receive hook failed" or nil,
             data = { hooks = results, counts = S.counts, events = EVENTS_PATH } }
end

-- ---------------------------------------------------------------- send
local function chat_settings()
    local cdo = try(function() return StaticFindObject("/Script/JagexChatBackend.Default__ChatDeveloperSettings") end)
    local limit = alive(cdo) and try(function() return cdo.MessageCharacterLimit end) or 256
    local dur = alive(cdo) and try(function() return cdo.SpamDetectionDuration end) or 10
    local max = alive(cdo) and try(function() return cdo.SpamDetectionMessageLimit end) or 5
    return (limit and limit > 0) and limit or 256, dur or 10, max or 5
end

-- The live chat input widget (the instance under the HUD's WBP_Chat_C, not the class archetype).
local function opened_widget()
    for _, w in ipairs(FindAllOf("OpenedChatSubWidget") or {}) do
        local n = w:GetFullName()
        if alive(w) and n:find("/Engine/Transient", 1, true) and alive(try(function() return w.MessageSendBox end)) then
            return w
        end
    end
    return nil
end

-- Say one line in chat as Claude. Returns {ok, reason, data}. ok=true means the chat box accepted
-- it (its input box was consumed); the server's echo arrives as a {"type":"chat","self":true} event.
function M.say(log, text)
    text = tostring(text or ""):gsub("[%c]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return { ok = false, reason = "empty text" } end
    local limit, spam_dur, spam_max = chat_settings()
    if #text > limit then text = text:sub(1, limit) end
    -- Stay under the game's spam detector (it would show Claude a warning and drop lines).
    local now = os.time()
    local recent = {}
    for _, t in ipairs(S.sent) do if now - t < spam_dur then recent[#recent + 1] = t end end
    S.sent = recent
    if #recent >= math.max(1, spam_max - 1) then
        return { ok = false, reason = "rate limited (" .. #recent .. " lines in " .. spam_dur .. " s)" }
    end
    local w = opened_widget()
    if not w then return { ok = false, reason = "no live chat input widget" } end
    local box = w.MessageSendBox
    local ft = FText(text)
    pcall(function() box:SetText(ft) end)
    local ok, err = pcall(function() w:OnTextCommitted(ft, ETEXTCOMMIT_ONENTER) end)
    if not ok then return { ok = false, reason = "OnTextCommitted: " .. tostring(err) } end
    local after = try(function() return box:GetText():ToString() end)
    S.sent[#S.sent + 1] = now
    if log then log("chat say len=" .. #text .. " box_after=" .. tostring(after)) end
    return { ok = true, reason = nil, data = { text = text, box_after = after, rx_before = S.counts.rx } }
end

M.state = S
return M
