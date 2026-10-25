-- Fake client chat module (same API as client_mod/scripts/chat.lua). State in _G.FAKE.
-- With FAKE.chat_path set it also writes the server's echo (a self=true line), like the real server does.
local M = {}
_G.FAKE = _G.FAKE or {}
local ST = _G.FAKE_CHAT_STATE or { hooks = {} } -- like chat.lua's _G.DWChat (survives reloads)
_G.FAKE_CHAT_STATE = ST
M.state = ST
function M.start(log)
    _G.FAKE.chat_started = (_G.FAKE.chat_started or 0) + 1
    if _G.FAKE.hooks_fail then return { ok = false, reason = "receive hook failed" } end -- classes not loaded yet
    ST.hooks["/Script/JagexChatBackend.PlayerChatComponent:Client_ReceiveChatMessage"] = { pre = 1, post = 2 }
    return { ok = true }
end
function M.say(log, text)
    _G.FAKE.said = _G.FAKE.said or {}
    table.insert(_G.FAKE.said, text)
    if _G.FAKE.say_fail then return { ok = false, reason = "rate limited (4 lines in 10 s)" } end
    if _G.FAKE.chat_path then
        local f = io.open(_G.FAKE.chat_path, "ab")
        if f then
            f:write('{"type":"chat","from":"Claude","self":true,"text":"' .. text:gsub('[\\"]', "") .. '"}\n')
            f:close()
        end
    end
    return { ok = true, data = { text = text } }
end
return M
