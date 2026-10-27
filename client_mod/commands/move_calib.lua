-- Jump-envelope CALIBRATION on flat ground (needs main's clearance: Claude jumps in place).
-- 3 single jumps, then double jumps with the 2nd press at 0.25 / 0.33 / 0.40 s (2 each). Measures
-- the capsule's rise per jump each frame (take-off = first airborne frame, landing = first grounded
-- frame after it). Writes data/envelopes/Claude.json (traversal design format; metres, p10 minus a
-- 0.15 m margin) which scripts/move.lua prefers over its estimates. Result also in _G.DW_CALIB.
local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
-- Retain the previous envelope under a unique backup name. On Windows the two renames
-- have a crash window; the backup is the recovery copy, not an atomic transaction.
local function save_measurements(root, jump, dj, delay)
    if not jump and not dj then return false, "no complete measured trials" end
    local okj, J = pcall(function() return assert(loadfile(root .. "/client_mod/scripts/dkjson.lua"))() end)
    if not okj then return false, "JSON unavailable: " .. tostring(J) end
    local path = root .. "/data/envelopes/Claude.json"
    local f, err, code = io.open(path, "rb")
    local exists, doc = f ~= nil, {}
    if not f and code ~= 2 then return false, "envelope read: " .. tostring(err) end
    if f then
        local okread, txt = pcall(function() return f:read("a") end)
        local okclose, closed = pcall(function() return f:close() end)
        if not okread or type(txt) ~= "string" or not okclose or not closed then return false, "envelope read/close failed" end
        local okdecode, value, nextpos, decode_error = pcall(J.decode, txt, 1, J.null)
        if not okdecode or type(value) ~= "table" or decode_error or not txt:match("^%s*{")
            or type(nextpos) ~= "number" or txt:sub(nextpos):match("%S") then
            return false, "envelope JSON invalid: " .. tostring(decode_error or value)
        end
        doc = value
    end
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if doc.measurement_provenance ~= nil and (type(doc.measurement_provenance) ~= "table" or doc.measurement_provenance == J.null) then
        return false, "invalid measurement provenance"
    end
    doc.measurement_provenance = doc.measurement_provenance or {}
    local provenance = doc.measurement_provenance
    local function record(field, method)
        provenance[field] = { verified = true, measured = stamp, method = method, source = "client_mod/commands/move_calib.lua" }
    end
    if jump then
        if type(doc.jump_up_m) ~= "table" or doc.jump_up_m == J.null then doc.jump_up_m = {} end
        doc.jump_up_m.stand = math.floor((jump / 100 - 0.15) * 100 + 0.5) / 100
        record("jump_up_m.stand", "three grounded single-jump trials")
    end
    if dj then
        doc.dj_up_m, doc.dj_delay_s = math.floor((dj / 100 - 0.15) * 100 + 0.5) / 100, delay
        record("dj_up_m", "two grounded trials with airborne jump count 1 to 2")
    end
    local oke, txt = pcall(J.encode, doc, { indent = true })
    if not oke or type(txt) ~= "string" then return false, "envelope encode failed: " .. tostring(txt) end
    local suffix, tmp, bak
    for n = 1, 1000 do
        suffix = os.date("!%Y%m%dT%H%M%S") .. "-" .. n
        tmp, bak = path .. ".tmp-" .. suffix, path .. ".bak-" .. suffix
        local tf, _, tc = io.open(tmp, "rb")
        local bf, _, bc = io.open(bak, "rb")
        if tf then tf:close() end; if bf then bf:close() end
        if not tf and tc ~= 2 then return false, "temporary path check failed" end
        if not bf and bc ~= 2 then return false, "backup path check failed" end
        if not tf and not bf then break end
        tmp, bak = nil, nil
    end
    if not tmp then return false, "no available backup name" end
    local out, we = io.open(tmp, "wb")
    if not out then return false, "temporary write: " .. tostring(we) end
    local okw, wrote = pcall(function() return out:write(txt) end)
    local okc, closed = pcall(function() return out:close() end)
    if not okw or not wrote or not okc or not closed then os.remove(tmp); return false, "temporary write/close failed" end
    if exists then
        local moved, me = os.rename(path, bak)
        if not moved then os.remove(tmp); return false, "backup rename: " .. tostring(me) end
    end
    local installed, ie = os.rename(tmp, path)
    if not installed then
        if exists then
            local restored, re = os.rename(bak, path)
            if not restored then return false, "install failed: " .. tostring(ie) .. "; rollback failed: " .. tostring(re) .. "; recover from " .. bak end
        end
        os.remove(tmp)
        return false, "install failed: " .. tostring(ie)
    end
    return true
end

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
    local perk_ok, perk = pcall(function() return pc.SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk) end)
    local plan = { { kind = "single" }, { kind = "single" }, { kind = "single" } }
    if perk_ok and perk == true then
        for _, delay in ipairs({ 0.25, 0.33, 0.40 }) do
            for _ = 1, 2 do plan[#plan + 1] = { kind = "double", delay = delay } end
        end
    end
    local res = { state = "running", trials = {}, double_perk = perk_ok and (perk == true and "unlocked" or perk == false and "locked" or "unknown") or "unknown" }
    _G.DW_CALIB = res
    local i, phase, t0, z0, zmax, air_seen, second_done, second_seen = 1, "wait", now(), nil, nil, false, false, false
    if _G.DW_CALIB_H then pcall(CancelDelayedAction, _G.DW_CALIB_H) end
    _G.DW_CALIB_H = LoopInGameThreadWithDelay(1, function()
        local ok, err = pcall(function()
            if rawget(_G, "DW_PAUSE") or not (pc:IsValid() and pawn:IsValid()) then res.state = "aborted"; error("abort") end
            if not A.holds(token) then res.state = "preempted"; error("preempted") end
            A.renew(token)
            local t = now()
            local z = pawn:K2_GetActorLocation().Z
            local ground = pawn.CharacterMovement:IsMovingOnGround()
            if ground ~= true and ground ~= false then error("ground state unavailable") end
            local tr = plan[i]
            if phase == "wait" then
                if t - t0 > 5 and not ground then
                    error(i == 1 and "grounded start not confirmed" or "grounded state not confirmed after trial")
                end
                if t - t0 > 1.0 and ground then
                    z0, zmax, air_seen, second_done, second_seen = z, z, false, false, false
                    local okc, initial = pcall(function() return pawn.JumpCurrentCount end)
                    tr.counter_reset = okc and tonumber(initial) == 0
                    tr.counter_bad = not okc or tonumber(initial) == nil
                    tr.first_seen = false
                    pawn:Jump(); t0 = t; phase = "air"
                end
            elseif phase == "air" then
                zmax = math.max(zmax, z)
                if not ground then
                    air_seen = true
                    local okc, count = pcall(function() return pawn.JumpCurrentCount end)
                    if tr.kind == "double" and (not okc or tonumber(count) == nil) then tr.counter_bad = true end
                    if tr.counter_reset and okc and tonumber(count) == 1 and not second_done then tr.first_seen = true end
                end
                if t - t0 > 0.1 then pawn:StopJumping() end
                if tr.kind == "double" and not second_done and t - t0 >= tr.delay then
                    local okc, count = pcall(function() return pawn.JumpCurrentCount end)
                    local okp, still_unlocked = pcall(function() return pc.SkillPerkComponent:IsPerkUnlocked(pawn.DoubleJumpSkillPerk) end)
                    if ground == false and air_seen and tr.first_seen and not tr.counter_bad and okc and tonumber(count) == 1 and okp and still_unlocked == true then
                        pawn:Jump(); tr.t2 = t
                    end
                    second_done = true
                end
                if tr.t2 and not second_seen and ground == false and t > tr.t2 and t - tr.t2 <= 0.3 then
                    local okc, count = pcall(function() return pawn.JumpCurrentCount end)
                    if okc and tonumber(count) == 2 then second_seen = true end
                end
                if tr.t2 and t - tr.t2 > 0.1 then pawn:StopJumping() end
                if air_seen and ground and t - t0 > 0.3 then
                    local valid = tr.kind ~= "double" or (second_seen and not tr.counter_bad)
                    res.trials[#res.trials + 1] = { kind = tr.kind, delay = tr.delay,
                        rise_cm = valid and math.floor(zmax - z0) or nil,
                        error = not valid and "second jump not observed" or nil,
                        air_s = math.floor((t - t0) * 100) / 100 }
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
                local jump = #singles == 3 and singles[1] or nil
                for d, list in pairs(by) do
                    table.sort(list)
                    if #list == 2 and (not best_dj or list[1] > best_dj) then best_dj, best_delay = list[1], d end
                end
                res.jump_rise_min_cm, res.dj_rise_min_cm, res.dj_delay_s = jump, best_dj, best_delay
                local ok_save, save_error = save_measurements(ROOT, jump, best_dj, best_delay)
                if ok_save then
                    res.file, res.state = "data/envelopes/Claude.json", "done"
                else
                    res.state, res.err = "error", save_error
                end
                if log then log("calib: " .. res.state .. " jump " .. tostring(jump) .. " cm, double " .. tostring(best_dj) .. " cm at " .. tostring(best_delay) .. " s " .. tostring(res.err or "")) end
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
