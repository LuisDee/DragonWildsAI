-- Movement ladder (tools/travel_ladder.py follow legs): start move.follow of a ghost leader replaying a recorded
-- human track (client_mod/scripts/ghost_leader.lua). ARGS = {track = {{t_s, x_cm, y_cm, z_cm, air}, ...},
-- distance_m = 3, delay_s = 2, hold_s = 8}. Read the result with move_ghost_status.lua.
return function(log)
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local M = assert(loadfile(ROOT .. "/client_mod/scripts/move.lua"))()
    local G = assert(loadfile(ROOT .. "/client_mod/scripts/ghost_leader.lua"))()
    local A = ARGS or {}
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do
        if x:IsValid() and not x:GetFullName():find("Default__") then pc = x; break end
    end
    if not (pc and pc.Pawn and pc.Pawn:IsValid()) then return { ok = false, error = "no pawn" } end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local function clock() return GS:GetRealTimeSeconds(pc.Pawn) end
    local function me() local p = pc.Pawn; return p and p:IsValid() and p:K2_GetActorLocation() or nil end
    local ghost = G.new(A.track, { clock = clock, me = me, delay_s = A.delay_s or 2, hold_s = A.hold_s or 8 })
    _G.DW_GHOST = ghost
    local r = M.follow(log, { actor = ghost }, A.distance_m or 3, { as_player = true })
    return { ok = r and r.ok, follow = r, duration_s = ghost.duration_s, delay_s = ghost.delay_s, hold_s = ghost.hold_s }
end
