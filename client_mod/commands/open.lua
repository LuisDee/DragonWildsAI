-- Travel to the dev server with the same URL options a real client sends (?p=<base64 pw>?pf=PC?cpx=1).
local function b64(s)
    local c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((s:gsub('.', function(x) local r, b = '', x:byte(); for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end; return r end) .. '0000')
        :gsub('%d%d%d?%d?%d?%d?', function(x) if #x < 6 then return '' end; local n = 0; for i = 1, 6 do n = n + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end; return c:sub(n + 1, n + 1) end)
        .. ({ '', '==', '=' })[#s % 3 + 1])
end
return function(log)
    local pw = ""
    local f = io.open("C:/GameServers/Dragonwilds/RSDragonwilds/Saved/Config/WindowsServer/DedicatedServer.ini", "r")
    if f then for line in f:lines() do local v = line:match("^WorldPassword=(.*)$"); if v then pw = v:gsub("%s+$", "") end end; f:close() end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    ksl:ExecuteConsoleCommand(pc, "open 127.0.0.1:7777?p=" .. b64(pw) .. "?pf=PC?cpx=1", pc)
    return { sent = true }
end
