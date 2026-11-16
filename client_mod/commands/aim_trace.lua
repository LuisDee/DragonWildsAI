-- READ-ONLY tracer (2026-11-16, issue B16 placement speed): what do the game's cursor, helper and ghost do after an
-- aim change, sampled every frame? Starts a 33 ms game-thread loop for DUR_S seconds (run again to stop early) and
-- writes one JSON row per sample to logs/client/aimtrace.jsonl: the frame number, game and real time, control
-- rotation, the camera's place and facing, what the camera's forward ray hits, the build mode, the MPC cursor and
-- colour, the BuildingHelper actor and the preview actor. Property reads, pure getters and one line trace per sample.
local DUR_S = 120
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    local old = rawget(_G, "__dw_aimtrace")
    if old and old.handle then
        old.stop = true
        return { ok = true, stopped = true, rows = old.n }
    end
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local json = assert(loadfile(ROOT .. "/client_mod/scripts/dkjson.lua"))()
    local s = inst.module.API.module("sense")
    local U = s.U
    local path = ROOT .. "/logs/client/aimtrace.jsonl"
    local f = assert(io.open(path, "w"))
    local st = { n = 0 }
    rawset(_G, "__dw_aimtrace", st)
    local ksl = U.find_object("/Script/Engine.Default__KismetSystemLibrary")
    local kml = U.find_object("/Script/Engine.Default__KismetMaterialLibrary")
    local gst = U.find_object("/Script/Engine.Default__GameplayStatics")
    local function r(x) return math.floor(x * 1000 + 0.5) / 1000 end
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { r(x / 100), r(y / 100), r(z / 100) } end end
    local function r3(q) local ok, p, y = pcall(function() return q.Pitch, q.Yaw end); if ok and type(y) == "number" then return { r(p), r(y) } end end
    local C0 = { R = 0, G = 0, B = 0, A = 0 }
    local t0
    local function sample()
        if rawget(_G, "DW_PAUSE") then return end
        local pc, pawn = s.local_pc(), s.local_pawn()
        if not (U.valid(pc) and U.valid(pawn)) then return end
        local row = {}
        row.rt = U.try(function() return gst:GetRealTimeSeconds(pawn) end)
        row.gt = U.try(function() return gst:GetTimeSeconds(pawn) end)
        row.frame = U.try(function() return ksl:GetFrameCount() end)
        t0 = t0 or row.rt
        row.ctl = r3(U.try(function() return pc:GetControlRotation() end))
        local pcm = U.try(function() return pc.PlayerCameraManager end)
        local cam = U.valid(pcm) and v3(U.try(function() return pcm:GetCameraLocation() end))
        local cr = U.valid(pcm) and r3(U.try(function() return pcm:GetCameraRotation() end))
        row.cam, row.cam_rot = cam, cr
        row.pawn = v3(U.try(function() return pawn:K2_GetActorLocation() end))
        if cam and cr then
            local p, y = math.rad(cr[1]), math.rad(cr[2])
            local d = { math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p) }
            local o = {}
            local ok, hit = pcall(function()
                return ksl:LineTraceSingle(pawn, { X = cam[1] * 100, Y = cam[2] * 100, Z = cam[3] * 100 },
                    { X = (cam[1] + d[1] * 15) * 100, Y = (cam[2] + d[2] * 15) * 100, Z = (cam[3] + d[3] * 15) * 100 }, 0, false, {}, 0, o, true, C0, C0, 0.0)
            end)
            if ok and hit == true then
                row.ray = v3(o.ImpactPoint)
                local ha = U.try(function() return o.HitObjectHandle.Actor end)
                row.ray_actor = ha and U.short(ha) or nil
            end
        end
        local bm = U.try(function() return pc.BuildModeComponent end)
        if U.valid(bm) then
            row.mode = tostring(U.try(function() return bm.CurrentBuildMode end))
            local mpc = U.try(function() return bm.MaterialParameterCollection end)
            if kml and U.valid(mpc) then
                local pos = U.try(function() return kml:GetVectorParameterValue(pawn, mpc, bm.CursorWorldPositionMPN) end)
                local okp, x, y, z = pcall(function() return pos.R, pos.G, pos.B end)
                row.cursor = okp and type(x) == "number" and { r(x / 100), r(y / 100), r(z / 100) } or nil
                row.colour = U.try(function() return kml:GetScalarParameterValue(pawn, mpc, bm.PlacingValidityStateIndexMPN) end)
            end
            local hw = U.try(function() return bm.BuildingHelperActor end)
            local h = hw and U.try(function() return hw:Get() end)
            if U.valid(h) then
                row.helper = v3(U.try(function() return h:K2_GetActorLocation() end))
                row.helper_yaw = U.try(function() return r(h:K2_GetActorRotation().Yaw) end)
            end
            local w = U.try(function() return bm.CurrentlyPlacingPieceData end)
            local d = w and U.try(function() return w:Get() end)
            row.placing = U.valid(d) and U.short(d) or nil
        end
        if row.placing then -- the ghost, when the piece has a preview actor (one find per second at most)
            if not (st.ghost and U.valid(st.ghost)) and (st.ghost_at or 0) + 1 < (row.rt or 0) then
                st.ghost_at, st.ghost = row.rt, nil
                for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
                    if U.try(function() return a.bIsPreview end) == true then st.ghost = a; break end
                end
            end
            if st.ghost and U.valid(st.ghost) then
                row.ghost = v3(U.try(function() return st.ghost:K2_GetActorLocation() end))
                row.ghost_yaw = U.try(function() return r(st.ghost:K2_GetActorRotation().Yaw) end)
            end
        else
            st.ghost = nil
        end
        f:write(json.encode(row), "\n")
        st.n = st.n + 1
        if st.n % 30 == 0 then f:flush() end
        return row.rt
    end
    st.handle = LoopInGameThreadWithDelay(33, function()
        local ok, rt = pcall(sample)
        if st.stop or (ok and rt and t0 and rt - t0 > DUR_S) then
            pcall(function() f:close() end)
            local h = st.handle
            rawset(_G, "__dw_aimtrace", nil)
            if h and CancelDelayedAction then pcall(CancelDelayedAction, h) end
        end
    end)
    return { ok = true, started = true, path = path, dur_s = DUR_S }
end
