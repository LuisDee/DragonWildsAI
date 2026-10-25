-- Jump-envelope CALIBRATION on flat ground (needs main's clearance: Claude jumps in place).
-- 3 single jumps, then double jumps with the 2nd press at 0.25 / 0.33 / 0.40 s (2 each). Measures
-- the capsule's rise per jump each frame (take-off = first airborne frame, landing = first grounded
-- frame after it). Writes data/envelopes/Claude.json (traversal design format; metres, p10 minus a
-- 0.15 m margin) which scripts/move.lua prefers over its estimates. Result also in _G.DW_CALIB.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
return function(log)
    if rawget(_G, "DW_PAUSE") then return { ok = false, error = "paused" } end
    if _G.DW_MOVE and _G.DW_MOVE.mode ~= "idle" then return { ok = false, error = "a move is running; stop it first" } end
    local pc
    for _, x in ipairs(FindAllOf("PlayerController") or {}) do if not x:GetFullName():find("Default__") then pc = x end end
    local pawn = pc.Pawn
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- the spot must be FLAT and OPEN (traces start 70 cm out: Claude's own gear blocks traces)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local c0 = { R = 0, G = 0, B = 0, A = 0 }
    local me = pawn:K2_GetActorLocation()
    local hh = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local feet = me.Z - hh
    local zs, blocked = {}, {}
    for k = 0, 7 do
        local a = math.rad(k * 45)
        for _, r in ipairs({ 80, 150 }) do
            local x, y = me.X + math.cos(a) * r, me.Y + math.sin(a) * r
            local o = {}
            if ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = feet + 100 }, { X = x, Y = y, Z = feet - 200 }, 0, false, {}, 0, o, true, c0, c0, 0.0) and o.ImpactPoint then
                zs[#zs + 1] = o.ImpactPoint.Z
            end
        end
        for _, zz in ipairs({ 50, 170 }) do
            local o2 = {}
            local s0 = { X = me.X + math.cos(a) * 70, Y = me.Y + math.sin(a) * 70, Z = feet + zz }
            local e0 = { X = me.X + math.cos(a) * 250, Y = me.Y + math.sin(a) * 250, Z = feet + zz }
            if ksl:LineTraceSingle(pawn, s0, e0, 0, false, {}, 0, o2, true, c0, c0, 0.0) then blocked[#blocked + 1] = k * 45 .. "@" .. zz end
        end
    end
    local o3 = {}
    local roof = ksl:LineTraceSingle(pawn, { X = me.X + 70, Y = me.Y, Z = feet + 200 }, { X = me.X + 70, Y = me.Y, Z = feet + 500 }, 0, false, {}, 0, o3, true, c0, c0, 0.0)
    local fz_min, fz_max = math.huge, -math.huge
    for _, z in ipairs(zs) do fz_min, fz_max = math.min(fz_min, z), math.max(fz_max, z) end
    local frange = (#zs > 0) and math.floor(fz_max - fz_min) or nil
    if #zs < 12 or (frange or 999) > 30 or #blocked > 0 or roof then
        return { ok = false, error = "spot not flat/open: step a few metres", floor_range_cm = frange, n = #zs, blocked = blocked, roof = roof }
    end
    -- take the pawn properly (a brain follow is suspended and resumed afterwards)
    local A = assert(loadfile(ROOT .. "/client_mod/scripts/arbiter.lua"))()
    local grant = A.request(log, { name = "calibration", level = "command", resumable = false, uses_move = true, lease_s = 10 })
    if not grant.ok then return { ok = false, error = "arbiter: " .. tostring(grant.reason), owner = grant.owner } end
    local token = grant.token
    local function now() return gs:GetRealTimeSeconds(pawn) end
    local plan = { { kind = "single" }, { kind = "single" }, { kind = "single" },
        { kind = "double", delay = 0.25 }, { kind = "double", delay = 0.25 },
        { kind = "double", delay = 0.33 }, { kind = "double", delay = 0.33 },
        { kind = "double", delay = 0.40 }, { kind = "double", delay = 0.40 } }
    local res = { state = "running", trials = {} }
    _G.DW_CALIB = res
    local i, phase, t0, z0, zmax, air_seen, second_done = 1, "wait", now(), nil, nil, false, false
    if _G.DW_CALIB_H then pcall(CancelDelayedAction, _G.DW_CALIB_H) end
    _G.DW_CALIB_H = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(function()
            if rawget(_G, "DW_PAUSE") or not (pc:IsValid() and pawn:IsValid()) then res.state = "aborted"; error("abort") end
            if not A.holds(token) then res.state = "preempted"; error("preempted") end
            A.renew(token)
            local t = now()
            local z = pawn:K2_GetActorLocation().Z
            local ground = pawn.CharacterMovement:IsMovingOnGround()
            local tr = plan[i]
            if phase == "wait" then
                if t - t0 > 1.0 and ground then
                    z0, zmax, air_seen, second_done = z, z, false, false
                    pawn:Jump(); t0 = t; phase = "air"
                end
            elseif phase == "air" then
                zmax = math.max(zmax, z)
                if not ground then air_seen = true end
                if t - t0 > 0.1 then pawn:StopJumping() end
                if tr.kind == "double" and not second_done and t - t0 >= tr.delay then
                    pawn:Jump(); second_done = true; tr.t2 = t
                end
                if tr.t2 and t - tr.t2 > 0.1 then pawn:StopJumping() end
                if air_seen and ground and t - t0 > 0.3 then
                    res.trials[#res.trials + 1] = { kind = tr.kind, delay = tr.delay, rise_cm = math.floor(zmax - z0), air_s = math.floor((t - t0) * 100) / 100 }
                    i, phase, t0 = i + 1, "wait", t
                    if i > #plan then phase = "done" end
                elseif t - t0 > 4 then
                    res.trials[#res.trials + 1] = { kind = tr.kind, delay = tr.delay, error = "no landing" }
                    i, phase, t0 = i + 1, "wait", t
                    if i > #plan then phase = "done" end
                end
            end
            if phase == "done" then
                local singles, best_dj, best_delay = {}, nil, nil
                local by = {}
                for _, r in ipairs(res.trials) do
                    if r.rise_cm then
                        if r.kind == "single" then singles[#singles + 1] = r.rise_cm
                        else
                            by[r.delay] = by[r.delay] or {}
                            table.insert(by[r.delay], r.rise_cm)
                        end
                    end
                end
                table.sort(singles)
                local jump = singles[1]
                for d, list in pairs(by) do
                    table.sort(list)
                    if not best_dj or list[1] > best_dj then best_dj, best_delay = list[1], d end
                end
                res.jump_rise_min_cm, res.dj_rise_min_cm, res.dj_delay_s = jump, best_dj, best_delay
                local f = io.open(ROOT .. "/data/envelopes/Claude.json", "w")
                if f and jump then
                    f:write(string.format('{"character":"Claude","measured":"%s","step_m":0.45,"jump_up_m":{"stand":%.2f},' ..
                        '"dj_up_m":%s,"dj_delay_s":%s,"safe_drop_m":14.5,"source":"client_mod/commands/move_calib.lua (p10/min of trials minus 0.15 m)"}',
                        os.date("!%Y-%m-%dT%H:%M:%SZ"), jump / 100 - 0.15,
                        best_dj and string.format("%.2f", best_dj / 100 - 0.15) or "null",
                        best_delay and string.format("%.2f", best_delay) or "null"))
                    f:close()
                    res.file = "data/envelopes/Claude.json"
                end
                res.state = "done"
                if log then log("calib: jump " .. tostring(jump) .. " cm, double " .. tostring(best_dj) .. " cm at " .. tostring(best_delay) .. " s") end
                pcall(A.release, log, token, "calibration done")
                CancelDelayedAction(_G.DW_CALIB_H); _G.DW_CALIB_H = nil
            end
        end)
        if not ok then
            if res.state == "running" then res.state = "error"; res.err = tostring(err) end
            pcall(A.release, log, token, "calibration " .. tostring(res.state))
            pcall(CancelDelayedAction, _G.DW_CALIB_H); _G.DW_CALIB_H = nil
        end
    end)
    return { started = true, trials = #plan, floor_range_cm = frange }
end
