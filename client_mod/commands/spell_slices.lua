-- READ-ONLY: the spell radial widget's slices (SpellSlotNum per slice, icon, enabled), the radial's
-- name text and CachedSectionId, to learn which wheel page the radial shows. Nothing injected.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local out = { ok = true, panels = {} }
    for _, p in ipairs(U.find_all("SpellcastingMainPanel", { skip_defaults = true })) do
        local d = { name = U.short(p), visible = U.try(function() return p:IsVisible() end), slices = {} }
        local rw = U.try(function() return p.SpellRadialWidget end)
        if U.valid(rw) then
            d.cached_section = U.try(function() return rw.CachedSectionId end)
            d.subdiv = U.try(function() return rw.SubdivisionCount end)
            d.spell_name = U.str(U.try(function() return rw.SpellName:GetText() end))
            d.bIsSpellbookInstance = U.try(function() return rw.bIsSpellbookInstance end)
            pcall(function() rw.Slices:ForEach(function(_, e)
                local s = e:get()
                d.slices[#d.slices + 1] = { slot = U.try(function() return s.SpellSlotNum end), cls = U.class_word(s),
                                            icon = U.short(U.try(function() return s.SliceIcon.Brush.ResourceObject end)) }
            end) end)
        end
        out.panels[#out.panels + 1] = d
    end
    -- the spellbook instance of the radial (spellbook menu) too, for comparison
    out.radials = {}
    for _, r in ipairs(U.find_all("SpellcastingRadialBase", { skip_defaults = true })) do
        out.radials[#out.radials + 1] = { name = U.fullname(r):sub(1, 160), book = U.try(function() return r.bIsSpellbookInstance end) }
    end
    return out
end
