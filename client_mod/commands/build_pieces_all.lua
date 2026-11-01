-- READ-ONLY: every built piece the client knows (GlobalBuildingManager.BuildingPieces, the same census build.lua's
-- W.built_pieces reads), as {x, y, z} metres rounded to 0.1, plus my position. tools/build_run.py picks a fresh
-- build spot from it (40+ m from any piece) and logs the nearest piece to the spot.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s and s.U
    if not U then return { ok = false, reason = "no sense" } end
    local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
    local l = U.loc(s.local_pawn())
    local me = l and { r1(l.X / 100), r1(l.Y / 100), r1(l.Z / 100) }
    local gbm
    for _, a in ipairs(FindAllOf("GlobalBuildingManager") or {}) do if U.valid(a) then gbm = a end end
    if not gbm then return { ok = false, reason = "no GlobalBuildingManager", me = me } end
    local pts = {}
    local ok, err = pcall(function()
        gbm.BuildingPieces:ForEach(function(_, e)
            local v = U.try(function() return e:get() end) or e
            local okp, x, y, z = pcall(function() local p = v.ClientVisible.Location; return p.X, p.Y, p.Z end)
            if okp and type(x) == "number" then pts[#pts + 1] = { r1(x / 100), r1(y / 100), r1(z / 100) } end
        end)
    end)
    return { ok = ok, error = (not ok) and tostring(err) or nil, me = me, n = #pts, pts = pts }
end
