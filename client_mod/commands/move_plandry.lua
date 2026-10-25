-- Read-only DRY RUN of the local planner (scripts/localplan.lua) on the live client: samples the
-- trace grid around Claude (8 traces/frame), plans toward Zezima (or 15 m ahead), verifies walls,
-- and logs the route. Does NOT move the pawn. Result: _G.DW_PLANDRY (read with move_planres.lua).
return function(log)
    local LP = assert(loadfile("C:/gameserver/client_mod/scripts/localplan.lua"))()
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local me = pawn:K2_GetActorLocation()
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local function trace(a, b, horizontal)
        local out = {}
        local hit = ksl:LineTraceSingle(pawn, a, b, 0, false, {}, 0, out, true, c0, c0, 0.0)
        if horizontal then return hit end
        if not hit then return nil end
        return out.ImpactPoint and out.ImpactPoint.Z, (tonumber(out.Distance) or 1) < 0.5
    end
    local goal
    for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
        local ok, n = pcall(function() return ps:GetPlayerName():ToString() end)
        if ok and n == "Zezima" and ps.PawnPrivate and ps.PawnPrivate:IsValid() then goal = ps.PawnPrivate:K2_GetActorLocation() end
    end
    local yaw = pawn:K2_GetActorRotation().Yaw
    goal = goal and { X = goal.X, Y = goal.Y, Z = goal.Z - 88 }
        or { X = me.X + math.cos(math.rad(yaw)) * 1500, Y = me.Y + math.sin(math.rad(yaw)) * 1500, Z = me.Z - 88 }
    local P = LP.new({ trace = trace, center = { X = me.X, Y = me.Y, Z = me.Z }, feet_z = me.Z - 88, radius_m = 9, cell_cm = 100,
        env = { step = 45, jump = 165, djump = 165, drop = 1000 } })
    local t0 = gs:GetRealTimeSeconds(pawn)
    local res = { state = "sampling", me = { me.X, me.Y, me.Z }, goal = { goal.X, goal.Y, goal.Z } }
    _G.DW_PLANDRY = res
    local stage, pts, rounds = "sampling", nil, 0
    if _G.DW_PLANDRY_H then pcall(CancelDelayedAction, _G.DW_PLANDRY_H) end
    _G.DW_PLANDRY_H = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(function()
            if stage == "sampling" then
                if P:step(8) == "ready" then
                    local why
                    pts, why = P:plan(goal)
                    if not pts then stage = "done"; res.state = "no_plan"; res.why = why; return end
                    stage = "verifying"
                end
            elseif stage == "verifying" then
                local r = P:verify(pts, 8)
                if r == "blocked" then
                    rounds = rounds + 1
                    pts = rounds <= 12 and P:plan(goal) or nil
                    if not pts then stage = "done"; res.state = "verify_exhausted"; return end
                elseif r == "ok" then
                    stage = "done"; res.state = "ok"
                    local acts, out = {}, {}
                    for _, p in ipairs(pts) do acts[#acts + 1] = p.act:sub(1, 1); out[#out + 1] = { math.floor(p.X), math.floor(p.Y), math.floor(p.Z) } end
                    res.acts, res.points = table.concat(acts), out
                end
            end
        end)
        if not ok then stage = "done"; res.state = "error"; res.err = tostring(err) end
        if stage == "done" then
            local nodes, layers2 = 0, 0
            for _, l in pairs(P.nodes) do nodes = nodes + #l; if #l > 1 then layers2 = layers2 + 1 end end
            res.nodes, res.two_layer_cells, res.traces, res.replans, res.expanded = nodes, layers2, P.traces, rounds, P.expanded
            res.block_log = P.block_log
            if pts then res.best_end = { math.floor(pts[#pts].X), math.floor(pts[#pts].Y), math.floor(pts[#pts].Z) } end
            res.s = math.floor((gs:GetRealTimeSeconds(pawn) - t0) * 100) / 100
            log("plandry: " .. tostring(res.state) .. " acts=" .. tostring(res.acts) .. " traces=" .. P.traces .. " s=" .. res.s)
            CancelDelayedAction(_G.DW_PLANDRY_H); _G.DW_PLANDRY_H = nil
        end
    end)
    return { started = true, me = res.me, goal = res.goal }
end
