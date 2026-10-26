-- READ-ONLY: the current input mode's mapping contexts and their action -> key rows (how to leave a mode).
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local m = pc and U.try(function() return pc.CurrentInputMode end)
    if not U.valid(m) then return { ok = false, reason = "no mode" } end
    local out = { ok = true, mode = U.short(m), contexts = {} }
    pcall(function() m.Mappings:ForEach(function(_, e)
        local x = e:get()
        local c = U.try(function() return x.InputMapping end)
        local rows = {}
        pcall(function() c.Mappings:ForEach(function(_, mm)
            local r = mm:get()
            rows[#rows + 1] = (U.short(U.try(function() return r.Action end)) or "?") .. "=" .. (U.str(U.try(function() return r.Key.KeyName end)) or "?")
        end) end)
        out.contexts[#out.contexts + 1] = { ctx = U.short(c), rows = rows }
    end) end)
    return out
end
