-- READ-ONLY build probe (docs/research/2026-11-01-autonomous-building.md §6 step 2): one building piece's size,
-- transform, snap plugs and mesh sockets, so placement can attach to a free socket instead of guessing.
-- Target (prefix the file with `local ACTOR = "<id>"`, `local PIECE = "<asset id>"` or `local PREVIEW = true`):
--   ACTOR   that building actor (U.short id)
--   PIECE   the nearest non-preview piece of that asset within 15 m
--   PREVIEW the build-mode preview managed by my PC
--   default the nearest non-preview building piece within 15 m
-- Reads only: properties, TArray elements of a validated owner in this tick, pure getters (GetAllSocketNames,
-- GetSocketLocation with the FName the engine itself returned). Nothing pressed, nothing sent, nothing under DW_PAUSE.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local s = inst.module.API.module("sense")
    local U = s and s.U
    local pc = s.local_pc()
    local me = s.local_pawn and s.local_pawn(pc)
    local my = me and U.loc(me)
    local want_actor, want_piece = rawget(_G, "ACTOR") or ACTOR, rawget(_G, "PIECE") or PIECE
    local want_preview = (rawget(_G, "PREVIEW") or PREVIEW) == true
    local function v3(v) local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end); if ok and type(x) == "number" then return { x, y, z } end end
    local function r2(x) return type(x) == "number" and math.floor(x * 100 + 0.5) / 100 or x end
    local function m3(v) return v and { r2(v[1] / 100), r2(v[2] / 100), r2(v[3] / 100) } or nil end
    local function piece_of(a) local d = U.try(function() return a.BuildingPieceData end); return U.valid(d) and U.short(d) or nil end
    -- the target
    local target, best
    for _, a in ipairs(U.find_all("BaseBuildingActor", { skip_defaults = true }) or {}) do
        local prev = U.try(function() return a.bIsPreview end) == true
        if want_actor then
            if U.short(a) == want_actor then target = a end
        elseif want_preview then
            local m = prev and U.try(function() return a.PlayerControllerManagingPlacement end)
            if prev and (U.valid(m) and U.short(m) == U.short(pc)) then target = a end
        elseif not prev and (not want_piece or piece_of(a) == want_piece) then
            local at = U.loc(a)
            local d = at and my and U.dist(at, my) or math.huge
            if d <= 1500 and (not best or d < best) then target, best = a, d end
        end
    end
    if not U.valid(target) then return { ok = false, reason = "no target", actor = want_actor, piece = want_piece, preview = want_preview } end
    local a = target
    local out = { ok = true, id = U.short(a), class = U.class_word(a), piece = piece_of(a) }
    local at = U.loc(a)
    out.position_m = m3(v3(at))
    local rot = U.try(function() return a:K2_GetActorRotation() end)
    out.rotation = rot and { pitch = r2(rot.Pitch), yaw = r2(rot.Yaw), roll = r2(rot.Roll) } or nil
    out.scale = v3(U.try(function() return a:GetActorScale3D() end))
    out.preview = U.try(function() return a.bIsPreview end)
    out.ghosted = U.try(function() return a.bIsGhosted end)
    out.stability = U.try(function() return a.StabilityValue end)
    out.piece_index = U.try(function() return a.BuildingPieceDataIndex end)
    -- size: the piece's own local bounds (cm), and the engine's world bounds as a cross-check
    local b = U.try(function() return a.BuildingPieceLocalBounds end)
    if b then
        out.local_bounds_cm = { origin = v3(U.try(function() return b.Origin end)), extent = v3(U.try(function() return b.BoxExtent end)),
                                sphere = U.try(function() return b.SphereRadius end) }
    end
    -- snap component and its plugs
    local sc = U.try(function() return a.BuildingSnapComponent end)
    if U.valid(sc) then
        local snap = { radius = U.try(function() return sc.SnappingRadius end), radius_basic = U.try(function() return sc.SnappingRadiusInBasicSnappingMode end),
                       from_sockets = U.try(function() return sc.bUseSocketsForPlugGeneration end), plugs = {} }
        local okp, errp = pcall(function()
            sc.Plugs:ForEach(function(i, e)
                if #snap.plugs >= 40 then return end
                local p = U.try(function() return e:get() end) or e
                local tr = U.try(function() return p.PlugTransform end)
                local row = { i = i,
                    piece_tag = U.str(U.try(function() return p.PlugProfile.PieceTag.TagName end)),
                    plug_tag = U.str(U.try(function() return p.PlugProfile.PlugTag.TagName end)),
                    t = v3(tr and U.try(function() return tr.Translation end)),
                    q = (function() local q = tr and U.try(function() return tr.Rotation end); local ok, x, y, z, w = pcall(function() return q.X, q.Y, q.Z, q.W end); return ok and { r2(x), r2(y), r2(z), r2(w) } or nil end)() }
                snap.plugs[#snap.plugs + 1] = row
            end)
        end)
        if not okp then snap.error = tostring(errp) end
        snap.n = #snap.plugs
        out.snap = snap
    else
        out.snap = { missing = true }
    end
    -- mesh sockets (plugs may be generated from them): names + world locations, at most 30 per mesh, 4 meshes
    out.meshes = {}
    pcall(function()
        a.CachedMeshes:ForEach(function(_, e)
            if #out.meshes >= 4 then return end
            local mc = U.try(function() return e:get() end) or e
            if not U.valid(mc) then return end
            local row = { name = U.short(mc), sockets = {} }
            local names = U.try(function() return mc:GetAllSocketNames() end)
            pcall(function()
                names:ForEach(function(_, ne)
                    if #row.sockets >= 30 then return end
                    local fname = U.try(function() return ne:get() end) or ne
                    local loc = v3(U.try(function() return mc:GetSocketLocation(fname) end))
                    row.sockets[#row.sockets + 1] = { name = U.str(fname) or tostring(fname), at_m = m3(loc) }
                end)
            end)
            row.n = #row.sockets
            out.meshes[#out.meshes + 1] = row
        end)
    end)
    return out
end
