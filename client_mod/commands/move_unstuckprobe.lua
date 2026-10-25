-- Read-only: the game's own Unstuck input (IA_UnstuckCharacter_Held): its triggers (hold time),
-- which mapping contexts map it, and whether those contexts are active on Claude's subsystem.
return function(log)
    local out = { actions = {}, contexts = {} }
    local function nm(o) local ok, n = pcall(function() return o:GetFullName() end); return ok and n or tostring(o) end
    for _, a in ipairs(FindAllOf("InputAction") or {}) do
        local n = nm(a)
        if n:find("Unstuck") then
            local rec = { name = n, value_type = a.ValueType, triggers = {} }
            pcall(function() a.Triggers:ForEach(function(_, e)
                local t = e:get()
                local tr = { nm(t):match("([%w_]+)$") }
                pcall(function() tr[#tr + 1] = "hold=" .. tostring(t.HoldTimeThreshold) end)
                rec.triggers[#rec.triggers + 1] = table.concat(tr, " ")
            end) end)
            out.actions[#out.actions + 1] = rec
        end
    end
    local subs = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
    for _, ctx in ipairs(FindAllOf("InputMappingContext") or {}) do
        local found = {}
        pcall(function() ctx.DefaultKeyMappings.Mappings:ForEach(function(_, e)
            local m = e:get()
            if m.Action and m.Action:IsValid() and nm(m.Action):find("Unstuck") then
                local trig = {}
                pcall(function() m.Triggers:ForEach(function(_, t) trig[#trig + 1] = nm(t:get()):match("([%w_]+)$") .. " hold=" .. tostring(t:get().HoldTimeThreshold) end) end)
                found[#found + 1] = m.Key.KeyName:ToString() .. " [" .. table.concat(trig, ",") .. "]"
            end
        end) end)
        if #found > 0 then
            local prio = {}
            local okh, has = pcall(function() return subs:HasMappingContext(ctx, prio) end)
            out.contexts[#out.contexts + 1] = { ctx = nm(ctx):match("([%w_]+)$"), keys = found, active = okh and tostring(has) or "?" }
        end
    end
    return out
end
