-- Read-only: the branch spawners near him: is each one's branch there (IsResourceAvailable, hidden, mesh shown)?
return function(log)
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local U = S.U
    local out = { rows = {} }
    local c = S.census(log, { radius_m = 14, max = 2000 })
    out.totals = c.totals
    for _, cat in ipairs({ "interactables", "resources", "gatherables", "pickups", "items" }) do
        for _, r in ipairs(c[cat] or {}) do
            if tostring(r.class or ""):find("AshBranch", 1, true) then
                local a = S.actor_of and S.actor_of({ id = r.id, class = r.class }) or nil
                local row = { cat = cat, id = tostring(r.id):sub(-24), d = r.distance, pos = r.position, prompt = r.prompt, visible = r.visible }
                if a and U.valid(a) then
                    row.avail = U.try(function() return a:IsResourceAvailable() end)
                    row.hidden = U.prop(a, "bIsHidden")
                    row.hidden_fn = U.try(function() return a:IsHidden() end)
                    local rc = U.prop(a, "RespawnComponent")
                    row.respawn = rc ~= nil and U.valid(rc) and tostring(U.try(function() return rc:GetFullName() end)):sub(1, 60) or nil
                    local root = U.prop(a, "RootComponent")
                    row.root_vis = root and U.valid(root) and U.try(function() return root:IsVisible() end)
                    row.collide = U.try(function() return a:GetActorEnableCollision() end)
                else
                    row.actor = false
                end
                out.rows[#out.rows + 1] = row
            end
        end
    end
    return out
end
