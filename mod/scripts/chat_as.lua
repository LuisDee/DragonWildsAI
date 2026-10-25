-- Chat route experiment 2: make relayed lines show as "Claude".
-- debug_run {module="chat_as"} registers display name "Claude" for the bot's CharacterGuid
-- (DisplayNameComponent:Server_RegisterCharacter, simple struct of 4 ints + a string) and arms a
-- post-hook: when Luis types "!as <words>", his GENUINE message is re-sent through the server's
-- Server_SendChatMessage with MessageBody=<words> and only SenderData.CharacterGuid swapped to the
-- bot's (net ids stay Luis's, so the message stays well-formed).
local M = {}

local FN = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage"
local BOT_GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }
local NAME = "Claude"

local function register_name(log)
    local gs = FindFirstOf("DominionGameStateBase")
    local ok, err = pcall(function()
        gs.DisplayNameComponent:Server_RegisterCharacter({ CharacterGuid = { InnerGuid = BOT_GUID } }, NAME)
    end)
    log.event("chat_as_register", { ok = ok, err = (not ok) and tostring(err) or nil })
    return ok, err
end

function M.run(log, args)
    local reg_ok, reg_err = register_name(log)
    if _G.__dw_chat_as_armed then return { registered = reg_ok, armed = true, already = true } end
    local relaying = false
    local ok, err = pcall(RegisterHook, FN, function() end, function(ctx, msg_param, filter_param)
        if relaying then return end
        local ok_t, text = pcall(function() return msg_param:get().MessageBody:ToString() end)
        if not ok_t or type(text) ~= "string" or text:sub(1, 4) ~= "!as " then return end
        relaying = true
        local ok_s, err_s = pcall(function()
            local msg = msg_param:get()
            local g = msg.SenderData.CharacterGuid
            g.A, g.B, g.C, g.D = BOT_GUID.A, BOT_GUID.B, BOT_GUID.C, BOT_GUID.D
            msg.MessageBody = text:sub(5)
            ctx:get():Server_SendChatMessage(msg, filter_param:get())
        end)
        relaying = false
        log.event("chat_as", { ok = ok_s, err = (not ok_s) and tostring(err_s) or nil, text = text })
    end)
    _G.__dw_chat_as_armed = ok
    return { registered = reg_ok, register_err = reg_err and tostring(reg_err), armed = ok, err = (not ok) and tostring(err) or nil }
end

return M
