-- READ-ONLY talk probe P1 (docs/design/talk-primitive.md §7): the controller's conversation component and
-- participant (active, LastMessage), the dialogue panel (if any) with its input actions, the quest list, and the
-- NPC interactables in range. Property reads and pure getters only: never presses, never moves.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local B = inst.module
    local s = B.API.module("sense")
    local U = s and s.U
    if not U then return { ok = false, reason = "no sense" } end
    local function str(x) local v = U.str(x); if v and v ~= "" then return v end end
    local pc = s.local_pc()
    local pawn = s.local_pawn(pc)
    local me = pawn and U.loc(pawn)
    local out = { ok = true }
    local comp = pc and U.try(function() return pc.ConversationComponent end)
    out.component = U.valid(comp) and U.class_word(comp) or "missing"
    local part = U.valid(comp) and U.try(function() return comp.DomConversationParticipant end)
    out.participant = U.valid(part) and U.class_word(part) or "missing"
    if U.valid(part) then
        out.active_fn = U.try(function() return part:IsInActiveConversation() end)
        out.conversations_active = U.try(function() return part.ConversationsActive end)
        local msg = U.try(function() return part.LastMessage end)
        out.last = msg and {
            speaker = str(U.try(function() return msg.Message.ParticipantDisplayName end)),
            text = str(U.try(function() return msg.Message.Text end)),
            node = str(U.try(function() return msg.CurrentNode.NodeGUID end)) or tostring(U.try(function() return msg.CurrentNode end)),
            n_options = U.try(function() return msg.Options:GetArrayNum() end),
        } or "unreadable"
    end
    out.current_npc = U.valid(comp) and U.short(U.try(function() return comp.CurrentNPC end)) or nil
    local panel = U.find_first("ConversationMainPanel")
    out.panel = U.valid(panel) and {
        class = U.class_word(panel), in_viewport = U.try(function() return panel:IsInViewport() end),
        continue = U.short(U.try(function() return panel.ContinueInputAction end)),
        cancel = U.short(U.try(function() return panel.CancelInputAction end)),
        n_select = U.try(function() return panel.OptionSelectInputActions:GetArrayNum() end),
        n_all = U.try(function() return panel.AllOptions:GetArrayNum() end),
        mapping = U.short(U.try(function() return panel.OptionSelectMappingContext end)),
    } or "none"
    out.input_mode = pc and U.short(U.try(function() return pc.CurrentInputMode end))
    -- the panel's participant is OURS (full-name match: UObject wrappers never compare with ==)
    if U.valid(panel) and U.valid(part) then
        local pp = U.try(function() return panel.DomConversationParticipant end)
        out.panel_participant_matches = U.fullname(pp) ~= nil and U.fullname(pp) == U.fullname(part)
        out.panel_participant = U.fullname(pp)
    end
    out.participant_full = U.valid(part) and U.fullname(part) or nil
    -- register the two count-only hooks talk.lua uses (review R6, P1): hookhub, paused-aware, never unregistered
    local hub = B.API.module("hookhub")
    out.hooks = {}
    local k = rawget(_G, "DWTalkHook") or { count = 0 }
    _G.DWTalkHook = k
    if hub and hub.on then
        for _, path in ipairs({ "/Script/CommonConversationRuntime.ConversationParticipantComponent:ClientUpdateConversation",
                                "/Script/Dominion.PlayerConversationComponent:BP_HandleConversationUpdated" }) do
            local ok, why = hub.on(path, "talk", function() local h = _G.DWTalkHook; h.count = h.count + 1 end, { log = log })
            out.hooks[#out.hooks + 1] = { path = path, native = ok == true, why = why, hooked = hub.hooked and hub.hooked(path) or nil }
        end
        k.armed = true
    else
        out.hooks = "no hookhub"
    end
    out.hook_count = k.count
    local qc = pc and U.try(function() return pc.QuestProgressComponent end)
    out.quests = {}
    if U.valid(qc) then
        pcall(function()
            qc.Quests:ForEach(function(_, e)
                local q = U.try(function() return e:get() end) or e
                local d = U.try(function() return q.Data end)
                if U.valid(d) and #out.quests < 40 then
                    out.quests[#out.quests + 1] = { quest = str(U.try(function() return d.QuestName end)) or U.short(d),
                        state = U.try(function() return q.State end), objective = str(U.try(function() return q.CurrentObjective end)) }
                end
            end)
        end)
    else
        out.quests = "missing"
    end
    out.npcs = {}
    for _, a in ipairs(U.find_all("InteractableNPC", { skip_defaults = true }) or {}) do
        if U.alive(a) and #out.npcs < 10 then
            local ic = U.try(function() return a.InteractionComponent end)
            local p = U.loc(a)
            out.npcs[#out.npcs + 1] = { id = U.short(a), class = U.class_word(a),
                prompt = U.valid(ic) and str(U.try(function() return ic.InteractionPrompt end)) or nil,
                d = (p and me) and math.floor(U.dist2d(p, me)) / 100 or nil }
        end
    end
    table.sort(out.npcs, function(x, y) return (x.d or 1e9) < (y.d or 1e9) end)
    return out
end
