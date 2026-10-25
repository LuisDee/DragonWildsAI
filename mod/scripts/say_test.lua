-- Which chat-display path reaches a vanilla client? Run via debug_run {module="say_test", args={variant=...}}.
--   a: Client_ReceiveChatMessage with Luis's own CharacterGuid + PlayerId, text prefixed "[Companion] "
--   b: Client_DisplayTextNotification (HUD toast)
--   c: register a display name for our GUID (Server_RegisterCharacter), then Client_ReceiveChatMessage
local M = {}

local LUIS_GUID_HEX = "AD09D5584C934E5D366719BFDD0E1B60" -- DCG:<OwnerId> from the join log
local BOT_GUID = { A = 0x0C0FFEE1, B = 0x00C0DE00, C = 0x0BADF00D, D = 0x00000001 }

local function try(f) local ok, v = pcall(f); if ok then return v end end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) == true end

local function guid_from_hex(h)
    local function word(i) return tonumber(h:sub(i, i + 7), 16) end
    return { A = word(1), B = word(9), C = word(17), D = word(25) }
end

local function controllers()
    local out = {}
    for _, pc in ipairs(FindAllOf("BP_PlayerController_C") or {}) do
        if valid(pc) then out[#out + 1] = pc end
    end
    return out
end

local function luis_player_id(pc)
    return try(function() return pc.PlayerState.PlayerId end) or 256
end

function M.run(log, args)
    local v, text = args.variant or "a", args.text or "Hello from your companion!"
    local out = { variant = v, results = {} }
    if v == "c" then
        local gs = FindFirstOf("DominionGameStateBase")
        local ok, err = pcall(function()
            gs.DisplayNameComponent:Server_RegisterCharacter({ CharacterGuid = { InnerGuid = BOT_GUID } }, "Companion")
        end)
        out.register = { ok = ok, err = (not ok) and tostring(err) or nil }
    end
    for _, pc in ipairs(controllers()) do
        log.event("say_test", { variant = v, pc = try(function() return pc:GetFullName() end) })
        local ok, err = pcall(function()
            if v == "b" then
                pc:Client_DisplayTextNotification({ TagName = FName("None") }, FText(text))
            else
                local sender = (v == "a")
                    and { CharacterGuid = guid_from_hex(LUIS_GUID_HEX), PlayerId = luis_player_id(pc), Color = { R = 80, G = 200, B = 255, A = 255 } }
                    or { CharacterGuid = BOT_GUID, PlayerId = 9001, Color = { R = 80, G = 200, B = 255, A = 255 } }
                local body = (v == "a") and ("[Companion] " .. text) or text
                pc.PlayerChat:Client_ReceiveChatMessage({ SenderData = sender, MessageBody = body })
            end
        end)
        out.results[#out.results + 1] = { ok = ok, err = (not ok) and tostring(err) or nil }
    end
    return out
end

return M
