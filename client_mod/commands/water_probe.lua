-- Read-only: where the water volumes are from where he stands, and whether a 150 m census of 40 rows lists them.
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local U = S.U
    local me = U.me and U.me() or nil
    local out = { vols = {} }
    local a = S.census(log, { radius_m = 150, max = 40 })
    local b = S.census(log, { radius_m = 150, max = 2000, kinds = { interactables = true } })
    out.totals40, out.totals_all = a.totals, b.totals
    local function waters(c)
        local l = {}
        for i, r in ipairs(c.interactables or {}) do
            if tostring(r.class or r.id or ""):find("WaterVolume", 1, true) or tostring(r.prompt or ""):lower():find("collect water", 1, true) then
                l[#l + 1] = { rank = i, id = r.id, distance = r.distance, position = r.position, prompt = r.prompt }
            end
        end
        return l
    end
    out.in40, out.in_all = waters(a), waters(b)
    out.n40, out.n_all = #(a.interactables or {}), #(b.interactables or {})
    out.last40 = a.interactables and a.interactables[#a.interactables] and a.interactables[#a.interactables].distance
    for _, v in ipairs(U.find_all("BP_WaterVolume_C", { skip_defaults = true })) do
        local at = U.loc(v)
        out.vols[#out.vols + 1] = { id = U.short(v), at = at and U.to_wire and U.to_wire(at) or tostring(at) }
    end
    return out
end
