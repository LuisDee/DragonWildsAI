-- Chat route experiment: re-send a GENUINE chat message (built by Luis's client, all net ids valid)
-- through the server's own Server_SendChatMessage, with only the text changed. Proves whether the
-- game's chat pipeline will carry server-originated text to a vanilla client.
-- debug_run {module="chat_relay"} arms a post-hook (once per server run). Then, when Luis types
-- "!echo <words>", the server broadcasts "[Claude] <words>" through the normal chat path.
local M = {}

local FN = "/Script/JagexChatBackend.PlayerChatComponent:Server_SendChatMessage"
local PREFIX = "[Claude] "

function M.run(log)
    if _G.__dw_chat_relay_armed then return { armed = true, already = true } end
    local relaying = false
    local ok, err = pcall(RegisterHook, FN, function() end, function(ctx, msg_param, filter_param)
        if relaying then return end -- our own re-send also passes through this hook
        local ok_t, text = pcall(function() return msg_param:get().MessageBody:ToString() end)
        if not ok_t or type(text) ~= "string" or text:sub(1, 6) ~= "!echo " then return end
        relaying = true
        local ok_s, err_s = pcall(function()
            local msg = msg_param:get()
            msg.MessageBody = PREFIX .. text:sub(7)
            ctx:get():Server_SendChatMessage(msg, filter_param:get())
        end)
        relaying = false
        log.event("chat_relay", { ok = ok_s, err = (not ok_s) and tostring(err_s) or nil, text = text })
    end)
    _G.__dw_chat_relay_armed = ok
    log.event("chat_relay_armed", { ok = ok, err = (not ok) and tostring(err) or nil })
    return { armed = ok, err = (not ok) and tostring(err) or nil }
end

return M
