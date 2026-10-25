-- Companion speech. UNVERIFIED IN GAME: nothing here has been seen on a client yet.
-- Plan from docs/research/2026-10-25-humanoid-companion-dump.md section D (option 1, fallback option 4):
--   1. chat:   for every BP_PlayerController_C: pc.PlayerChat:Client_ReceiveChatMessage(FChatMessageData)
--              FChatMessageData { SenderData: FChatPlayerSenderData { PrimaryNetId, SecondaryNetId,
--              CharacterGuid: FGuid{A,B,C,D}, PlayerId: int32, Color: FColor{R,G,B,A} }, MessageBody: FString }
--              Client RPC, Reliable, no validation. Called on the server it goes to that PC's client.
--              The NetId fields (FUniqueNetIdRepl) are left out: they can't be built from Lua. Which
--              sender name the client shows is the open question (E5).
--   2. notify: pc:Client_DisplayTextNotification(FGameplayTag, FText) (a HUD toast), used when the
--              chat call raises a Lua error or there is no PlayerChat component.
-- RISK: struct marshalling (UE4SS push_structproperty) already crashed natively once with
-- PredictDamage's TArray<FTypeDamage>. These structs have no arrays, but a native crash is
-- still possible and pcall can't catch it: every call is breadcrumbed first.
-- DW_SAY_MODE = chat (default) | notify | log (log only, no native call).
-- DW_SAY_REGISTER_NAME=1 also registers the companion GUID with a name through
-- GameState.DisplayNameComponent:Server_RegisterCharacter (E5; writes into the world save).
local U = require("body.util")

local M = {}

M.MAX_LEN = 256 -- in-game chat limit
M.NAME = os.getenv("DW_COMPANION_NAME") or "Companion"
M.GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }
M.PLAYER_ID = 9001 -- not used by real players (Luis's was 256)
M.COLOR = { R = 80, G = 200, B = 255, A = 255 }

local registered = false

local function controllers()
    local out = {}
    for _, pc in ipairs(U.try(FindAllOf, "BP_PlayerController_C") or {}) do
        if U.valid(pc) then out[#out + 1] = pc end
    end
    return out
end

local function register_name(log)
    if registered or os.getenv("DW_SAY_REGISTER_NAME") ~= "1" then return end
    registered = true
    local gs = U.try(FindFirstOf, "DominionGameStateBase")
    if not U.valid(gs) then return end
    U.call(log, "say.Server_RegisterCharacter", { name = M.NAME }, function()
        gs.DisplayNameComponent:Server_RegisterCharacter({ CharacterGuid = { InnerGuid = M.GUID } }, M.NAME)
    end)
end

local function chat_message(text)
    return {
        SenderData = { CharacterGuid = M.GUID, PlayerId = M.PLAYER_ID, Color = M.COLOR },
        MessageBody = text,
    }
end

local function send_chat(log, pc, text)
    local chat = U.try(function() return pc.PlayerChat end)
    if not U.valid(chat) then return false, "no PlayerChat" end
    return U.call(log, "say.Client_ReceiveChatMessage", { pc = U.short(pc), len = #text }, function()
        chat:Client_ReceiveChatMessage(chat_message(text))
    end)
end

local function send_notify(log, pc, text)
    return U.call(log, "say.Client_DisplayTextNotification", { pc = U.short(pc), len = #text }, function()
        local tag = { TagName = FName and FName("None") or "None" }
        local ftext = FText and FText(text) or text
        pc:Client_DisplayTextNotification(tag, ftext)
    end)
end

-- Returns {ok, reason, data}. ok means the calls were made without a Lua error; delivery to the
-- client is NOT verified (data.verified=false).
function M.say(log, text)
    if type(text) ~= "string" or text == "" then
        return { ok = false, reason = "invalid_args", data = { detail = "text must be a non-empty string" } }
    end
    text = text:sub(1, M.MAX_LEN)
    local mode = os.getenv("DW_SAY_MODE") or "chat"
    if log then pcall(log.event, "say", { text = text, mode = mode }) end
    if mode == "log" then return { ok = true, data = { method = "log", recipients = 0, verified = false } } end
    if mode == "chat" then register_name(log) end
    local pcs = controllers()
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
        return { ok = false, reason = "body_error", data = data }
    end
    return { ok = true, data = data }
end

function M._reset() registered = false end

return M
