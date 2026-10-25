-- Smoke test: move.lua status (read-only) plus the pawn position in metres.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local st = M.status()
    local out = { mode = st.mode, status = st.status, result = st.result }
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if not x:GetFullName():find("Default__", 1, true) and x.Pawn and x.Pawn:IsValid() then
            local l = x.Pawn:K2_GetActorLocation(); out.pos_m = { l.X / 100, l.Y / 100, l.Z / 100 }
        end
    end
    return out
end
