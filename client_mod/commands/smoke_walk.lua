-- Smoke test (tools/client_smoke.ps1): walk 2 m along the pawn's facing with move.lua go_to.
-- Returns at once with the start and goal; poll smoke_move_status.lua for the result.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__", 1, true) then pc = x end end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local l, f = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    local start = { l.X / 100, l.Y / 100, l.Z / 100 }
    local goal = { start[1] + f.X * 2, start[2] + f.Y * 2, start[3] }
    local r = M.go_to(log, goal, { tolerance_m = 0.6, timeout_s = 15 })
    return { ok = r.ok ~= false, start = start, goal = goal, go_to = r }
end
