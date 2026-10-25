-- Join the server in client_io/secrets/server.txt (line 1 address, line 2 world password) with the same
-- URL options a real client sends (?p=<base64 pw>?pf=PC?cpx=1). Requires a prior sign-in (login.lua).
local function b64(s)
    local c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((s:gsub('.', function(x) local r, b = '', x:byte(); for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end; return r end) .. '0000')
        :gsub('%d%d%d?%d?%d?%d?', function(x) if #x < 6 then return '' end; local n = 0; for i = 1, 6 do n = n + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end; return c:sub(n + 1, n + 1) end)
        .. ({ '', '==', '=' })[#s % 3 + 1])
end
return function(log)
    -- Pause every game-thread loop (vitals, reflex, move, bridge) before the world tears down:
    -- a loop touching objects mid-teardown crashed the client (DISCOVERIES). The bridge clears it
    -- once a new pawn exists.
    _G.DW_PAUSE = true
    local root = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local f = assert(io.open(root .. "/client_io/secrets/server.txt", "r"))
    local addr = (f:read("*l") or ""):gsub("%s+$", ""); local pw = (f:read("*l") or ""):gsub("%s+$", ""); f:close()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local pc = FindFirstOf("PlayerController")
    ksl:ExecuteConsoleCommand(pc, "open " .. addr .. "?p=" .. b64(pw) .. "?pf=PC?cpx=1", pc)
    return { sent = true, addr = addr }
end
