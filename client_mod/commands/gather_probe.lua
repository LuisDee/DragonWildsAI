-- READ-ONLY gather probe on Claude's client (gather.lua discovery, R2.17). Why can't the census see
-- STANDING trees? Reads, never writes, never injects input:
--   * every InteractableFoliageISMComponent (the trees/bushes still drawn as foliage): owner, the
--     actor class an instance converts into (ActorClass), damageable/interactable flags, instance
--     count, and how many instances lie within 40 m (GetInstancesOverlappingSphere: an int array);
--   * the pawn's NearbyFoliageConverterComponent (server-side converter near players): enabled, range;
--   * converted tree actors (FellableTree) and trunk pieces near him.
-- No GetInstanceTransform here (an FTransform out param; probed separately in gather_probe2.lua).
return function(log)
    local ROOT = "C:/gameserver"
    local U = assert(loadfile(ROOT .. "/mod/body/util.lua"))()
    if _G.DW_PAUSE then return { ok = false, reason = "paused" } end
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local me = U.loc(pawn)
    local out = { ok = true, me = U.to_wire(me), comps = {}, n_comps = 0 }
    local t0 = os.clock()
    for _, c in ipairs(U.find_all("InteractableFoliageISMComponent", { skip_defaults = true })) do
        out.n_comps = out.n_comps + 1
        local d = { name = U.short(c), class = U.class_word(c) }
        d.actor_class = U.short(U.try(function() return c.ActorClass end))
        d.damageable = U.try(function() return c.bDamageable end)
        d.interactable = U.try(function() return c.bInteractable end)
        d.foliage_type = U.try(function() return c.FoliageType end)
        d.count = U.try(function() return c:GetInstanceCount() end)
        local near, err = U.try_err(function()
            local arr = c:GetInstancesOverlappingSphere({ X = me.X, Y = me.Y, Z = me.Z }, 4000.0, true)
            local n, first = 0, {}
            if type(arr) == "table" then -- UE4SS returns a TArray<int32> return value as a plain Lua table
                for _, e in ipairs(arr) do n = n + 1; if #first < 3 then first[#first + 1] = (type(e) == "userdata" and e:get()) or e end end
            elseif arr then
                arr:ForEach(function(_, e) n = n + 1; if #first < 3 then first[#first + 1] = e:get() end end)
            end
            return { n = n, first = first }
        end)
        d.within_40m = near or err
        -- instance positions WITHOUT a struct out-param: the reflected PerInstanceSMData[i].Transform
        -- (an FMatrix of FPlanes; WPlane = local translation, |XPlane| = scale) plus the component's
        -- own world location/rotation/scale (plain FVector/FRotator returns).
        if type(near) == "table" and #near.first > 0 and ((d.actor_class or ""):find("Tree", 1, true) or (d.actor_class or ""):find("Rock", 1, true)) then
            d.comp_loc = U.to_wire(U.try(function() local v = c:K2_GetComponentLocation(); return { X = v.X, Y = v.Y, Z = v.Z } end))
            d.comp_rot = U.try(function() local r = c:K2_GetComponentRotation(); return { r.Pitch, r.Yaw, r.Roll } end)
            d.comp_scale = U.try(function() local s = c:K2_GetComponentScale(); return { s.X, s.Y, s.Z } end)
            d.inst = {}
            for _, idx in ipairs(near.first) do
                local r, e2 = U.try_err(function()
                    local m = c.PerInstanceSMData[idx + 1].Transform
                    local w, x = m.WPlane, m.XPlane
                    return { i = idx, local_cm = { w.X, w.Y, w.Z }, xplane = { x.X, x.Y, x.Z, x.W } }
                end)
                d.inst[#d.inst + 1] = r or { i = idx, err = e2 }
            end
        end
        out.by_class = out.by_class or {}
        local key = tostring(d.class) .. ">" .. tostring(d.actor_class)
        out.by_class[key] = (out.by_class[key] or 0) + 1
        if (d.class or ""):find("Tree", 1, true) or (d.actor_class or ""):find("Tree", 1, true) or (d.actor_class or ""):find("Rock", 1, true) or (d.actor_class or ""):find("Ore", 1, true) then
            if #out.comps < 40 and type(near) == "table" and near.n > 0 then out.comps[#out.comps + 1] = d end
        end
    end
    out.comps_ms = math.floor((os.clock() - t0) * 1000)
    local conv = U.try(function() return pawn.NearbyFoliageConverterComponent end)
    if U.valid(conv) then
        out.converter = { comp = U.short(conv), enabled = U.try(function() return conv:GetEnabled() end),
                          range = U.try(function() return conv:GetRange() end),
                          start_enabled = U.try(function() return conv.bStartEnabled end),
                          damageable = U.try(function() return conv.bConvertDamageableFoliage end),
                          interactable = U.try(function() return conv.bConvertInteractableFoliage end) }
    end
    out.actors = {}
    for _, cls in ipairs({ "FellableTree", "FelledTree", "SplittableTreeLog", "TreeLog", "DestructibleMiningRock", "OreNode" }) do
        local l = {}
        for _, a in ipairs(U.find_all(cls, { skip_defaults = true })) do
            local at = U.loc(a)
            local dm = at and math.floor(U.dist(me, at) / 10) / 10
            if dm and dm < 80 then
                l[#l + 1] = { id = U.short(a), d = dm, hp = U.health(a), stump = U.try(function() return a.bIsStump end) }
            end
        end
        table.sort(l, function(x, y) return x.d < y.d end)
        for i = #l, 6, -1 do l[i] = nil end
        out.actors[cls] = l
    end
    out.ms = math.floor((os.clock() - t0) * 1000)
    return out
end
