-- Read-only probe (quests agent, 2026-11-01): the game's quest map markers on Claude's client.
-- AQuestLocation {Type (Target/Area/NPC), Radius, Quest (UQuestData), bShownByDefault, QuestLocationName}, found as
-- actors AND through UQuestWorldSubsystem.QuestLocations; his QuestProgressComponent.VisibilityTrackers
-- ({LocationName, bLocationVisibility}) and TrackedQuestMap. Property reads of live objects only; no calls that change state.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local TYPES = { [0] = "Target", [1] = "Area", [2] = "NPC" }
    local function txt(v) local s = U.str(v); if s and s ~= "" and s ~= "None" then return s end end
    local out = { actors = {}, subsystem = {}, trackers = {}, tracked = {} }
    local me
    for _, pc in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return pc:IsLocalController() end) == true then me = pc end
    end
    local here = me and U.to_wire(U.loc(U.try(function() return me.Pawn end)))
    out.me = here
    local function row(a)
        local r = { id = U.short(a), class = U.class_word and U.class_word(a) or nil }
        r.type = TYPES[tonumber(U.try(function() return a.Type end)) or -1]
        r.radius_m = (tonumber(U.try(function() return a.Radius end)) or 0) / 100
        local q = U.try(function() return a.Quest end)
        r.quest = U.valid(q) and (txt(U.try(function() return q.QuestName end)) or U.short(q)) or nil
        r.asset = U.valid(q) and U.short(q) or nil
        r.shown_by_default = U.try(function() return a.bShownByDefault end) == true
        r.name = txt(U.try(function() return a.QuestLocationName end))
        r.pos = U.to_wire(U.loc(a))
        if here and r.pos then r.dist = math.floor(math.sqrt((r.pos[1] - here[1]) ^ 2 + (r.pos[2] - here[2]) ^ 2) + 0.5) end
        return r
    end
    for _, a in ipairs(U.find_all("QuestLocation", { skip_defaults = true }) or {}) do
        if U.valid(a) then out.actors[#out.actors + 1] = row(a) end
    end
    for _, ss in ipairs(U.find_all("QuestWorldSubsystem", { skip_defaults = true }) or {}) do
        U.each(U.try(function() return ss.QuestLocations end), function(a)
            if U.valid(a) then out.subsystem[#out.subsystem + 1] = row(a) end
        end, 256)
    end
    local qc = me and U.try(function() return me.QuestProgressComponent end)
    if U.valid(qc) then
        U.each(U.try(function() return qc.VisibilityTrackers end), function(t)
            out.trackers[#out.trackers + 1] = { name = txt(U.try(function() return t.LocationName end)),
                                                visible = U.try(function() return t.bLocationVisibility end) == true }
        end, 256)
        pcall(function()
            qc.TrackedQuestMap:ForEach(function(k, v)
                local kk = U.try(function() return k:get() end)
                local vv = U.try(function() return v:get() end)
                out.tracked[#out.tracked + 1] = { type = tostring(kk), quest = U.valid(vv) and txt(U.try(function() return vv.QuestName end)) or nil }
            end)
        end)
    end
    out.n = { actors = #out.actors, subsystem = #out.subsystem, trackers = #out.trackers }
    return out
end
