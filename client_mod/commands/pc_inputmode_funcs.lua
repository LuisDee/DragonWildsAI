-- Read-only: the local PC's UFunctions whose name mentions InputMode/Focus (to find the game's own way back to gameplay).
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/input.lua"))()
    local pc = I.pc()
    local names = {}
    local c = pc and pc:GetClass()
    local guard = 0
    while c and c:IsValid() and guard < 12 do
        guard = guard + 1
        pcall(function() c:ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if n:find("InputMode") or n:find("Focus") or n:find("UIMode") then names[#names + 1] = c:GetFName():ToString() .. "." .. n end
        end) end)
        local ok, sup = pcall(function() return c:GetSuperStruct() end)
        if not ok or not sup or not sup:IsValid() then break end
        c = sup
    end
    local stack = {}
    pcall(function() pc.InputModeStack:ForEach(function(_, e) stack[#stack + 1] = tostring(e:get():GetFName():ToString()) end) end)
    return { ok = true, funcs = names, stack = stack }
end
