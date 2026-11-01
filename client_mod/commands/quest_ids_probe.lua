-- Read-only probe (quests agent, 2026-11-01): each quest in his log -> its QuestData's name, asset and PersistenceID
-- (UDominionDataAsset.PersistenceID, the id the character save's QuestProgress.Quests[].QuestId holds), so a save clone
-- can have chosen quests removed. Property reads of live objects only.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local out = { quests = {} }
    local me
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then me = pc end
    end
    local qc = me and U.try(function() return me.QuestProgressComponent end)
    if not U.valid(qc) then return { error = "no QuestProgressComponent" } end
    U.each(U.try(function() return qc.Quests end), function(q)
        local d = U.try(function() return q.Data end)
        if not U.valid(d) then return end
        out.quests[#out.quests + 1] = {
            name = U.str(U.try(function() return d.QuestName end)),
            asset = U.short(d),
            id = U.str(U.try(function() return d.PersistenceID end)),
            internal = U.str(U.try(function() return d.InternalName end)),
            state = tonumber(U.try(function() return q.State end)),
            objective = U.str(U.try(function() return q.CurrentObjective end)),
        }
    end, 128)
    return out
end
