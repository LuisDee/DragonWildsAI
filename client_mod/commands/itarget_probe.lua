-- Read-only: what the interaction detector targets now, plus the conversation state.
return function(log)
    local V = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local pc = I.pc()
    local U = I.U
    local part = pc and U.try(function() return pc.ConversationComponent.DomConversationParticipant end)
    return { ok = true, target = V.interact_target(V.pawn()), modal = I.modal(),
             participant = U.valid(part) and U.short(part) or nil,
             last_msg = part and U.try(function() return tostring(part.LastMessage.Message.Text:ToString()) end) or nil }
end
