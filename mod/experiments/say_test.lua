-- HISTORICAL / DANGEROUS. Which hand-built chat-display path reaches a vanilla client?
-- Variants a and b are exactly the calls that froze Luis's client on 2026-10-25 (DISCOVERIES
-- "Client freeze from injected chat RPCs"); none of them displayed anything. The working route is
-- the relay in body/speech.lua. Kept only as a record of what was tried.
-- Refuses to run unless args.confirm_client_rpc == true (CLAUDE.md / ARCHITECTURE rule: Client_*
-- RPCs to a live player need Luis's explicit go-ahead).
--   a: Client_ReceiveChatMessage with Luis's own CharacterGuid + PlayerId, text prefixed "[Companion] "
--   b: Client_DisplayTextNotification (HUD toast)
--   c: register a name for the bot GUID with an EMPTY account (shows "Unknown Character"), then
--      Client_ReceiveChatMessage
-- debug_run {module="say_test", args={variant="a", confirm_client_rpc=true}}
local U = require("body.util")
local speech = require("body.speech")

local M = {}

local LUIS_GUID_HEX = "AD09D5584C934E5D366719BFDD0E1B60" -- DCG:<OwnerId> from the join log

function M.run(log, args)
    args = args or {}
    if args.confirm_client_rpc ~= true then
        return { ok = false, error = "refused: these Client_* RPCs froze a client; pass confirm_client_rpc=true only with Luis's go-ahead" }
    end
    local v, text = args.variant or "a", args.text or "Hello from your companion!"
    local out = { variant = v, results = {} }
    if v == "c" then
        local gs = U.find_first("DominionGameStateBase")
        local ok, err = U.call(log, "say_test.Server_RegisterCharacter", {}, function()
            gs.DisplayNameComponent:Server_RegisterCharacter({ CharacterGuid = { InnerGuid = speech.GUID } }, "Companion")
        end)
        out.register = { ok = ok, err = (not ok) and tostring(err) or nil }
    end
    for _, pc in ipairs(U.player_controllers()) do
        local ok, err = U.call(log, "say_test." .. v, { pc = U.fullname(pc) }, function()
            if v == "b" then
                pc:Client_DisplayTextNotification({ TagName = FName("None") }, FText(text))
            else
                local sender = (v == "a")
                    and { CharacterGuid = U.guid_from_hex(LUIS_GUID_HEX), PlayerId = U.try(function() return pc.PlayerState.PlayerId end) or 256, Color = speech.COLOR }
                    or { CharacterGuid = speech.GUID, PlayerId = speech.PLAYER_ID, Color = speech.COLOR }
                local body = (v == "a") and ("[Companion] " .. text) or text
                pc.PlayerChat:Client_ReceiveChatMessage({ SenderData = sender, MessageBody = body })
            end
        end)
        out.results[#out.results + 1] = { ok = ok, err = (not ok) and tostring(err) or nil }
    end
    return out
end

return M
