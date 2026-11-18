-- Smoke test (tools/client_smoke.ps1): walk 5 m along the pawn's facing with move.lua go_to.
-- Returns at once with the start and goal; poll smoke_move_status.lua for the result.
-- 5 m, well past go_to's widest arrival circle: tolerance_m (0.6 here; move.lua:5169 st.tol_cm) plus 1 m when he is
-- in water over the goal (move.lua:2849, the under-water goal rule). A 2 m walk "arrived" after 0.5 m in a pond
-- (2026-11-18T12:29:08Z). client_smoke.ps1 holds the same three numbers.
return function(log)
    local M = assert(loadfile("C:/gameserver/client_mod/scripts/move.lua"))()
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__", 1, true) then pc = x end end
    local pawn = pc and pc.Pawn
    if not (pawn and pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local l, f = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector()
    local start = { l.X / 100, l.Y / 100, l.Z / 100 }
    local goal = { start[1] + f.X * 5, start[2] + f.Y * 5, start[3] }
    local r = M.go_to(log, goal, { tolerance_m = 0.6, timeout_s = 20 })
    return { ok = r.ok ~= false, start = start, goal = goal, go_to = r }
end
