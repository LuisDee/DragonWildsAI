-- READ-ONLY watcher (BUGS L38): for 20 s, every frame, log CHANGES of Claude's pawn's LocalFX map
-- (tag -> UNiagaraComponent, NULL shown), its GameplayEffectsComponent tags and GE instance classes, and
-- every NiagaraComponent created in the window (its Asset one frame later). Writes
-- client_io/out/l38_watch.jsonl. No input, no writes to the game.
return function(log)
    local U = assert(loadfile("C:/gameserver/mod/body/util.lua"))()
    local json = assert(loadfile("C:/gameserver/client_mod/scripts/dkjson.lua"))()
    local pc
    for _, x in ipairs(U.find_all("BP_PlayerController_C", { skip_defaults = true })) do
        if U.try(function() return x:IsLocalController() end) == true then pc = x end
    end
    local pawn = pc and U.try(function() return pc.Pawn end)
    if not U.valid(pawn) then return { ok = false, reason = "no pawn" } end
    local path = "C:/gameserver/client_io/out/l38_watch.jsonl"
    local f = io.open(path, "w"); f:close()
    local function w(t) t.t = os.clock(); local h = io.open(path, "a"); h:write(json.encode(t) .. "\n"); h:close() end
    local W = rawget(_G, "__l38w") or {}; _G.__l38w = W
    W.until_t = os.clock() + 20; W.new = {}
    if not W.hooked then
        W.hooked = true
        pcall(function() NotifyOnNewObject("/Script/Niagara.NiagaraComponent", function(o)
            local S = rawget(_G, "__l38w")
            if S and os.clock() < (S.until_t or 0) then S.new[#S.new + 1] = { o = o, t = os.clock() } end
        end) end)
    end
    local last = {}
    local function snap()
        local s = { fx = {}, tags = {}, ge = {} }
        pcall(function() pawn.LocalFX:ForEach(function(k, v)
            local c = v:get(); s.fx[#s.fx + 1] = U.str(k:get().TagName) .. "=" .. (U.valid(c) and U.short(c) or "NULL") end) end)
        local ge = U.try(function() return pawn.GameplayEffectsComponent end)
        pcall(function() ge.GameplayTags.GameplayTags:ForEach(function(_, t) s.tags[#s.tags + 1] = U.str(t:get().TagName) end) end)
        for _, fl in ipairs({ "ReplicatedInstances", "NonReplicatedInstances" }) do
            pcall(function() ge[fl]:ForEach(function(_, e) local x = e:get(); if U.valid(x) then s.ge[#s.ge + 1] = U.class_word(x) end end) end)
        end
        return s
    end
    local h
    h = LoopInGameThreadWithDelay(1, function()
        if os.clock() > W.until_t or not U.valid(pawn) then w({ ev = "end" }); CancelDelayedAction(h); return end
        local s = snap()
        for _, k in ipairs({ "fx", "tags", "ge" }) do
            local j = table.concat(s[k], ",")
            if j ~= last[k] then last[k] = j; w({ ev = k, v = s[k] }) end
        end
        local keep = {}
        for _, n in ipairs(W.new) do
            if os.clock() - n.t > 0.05 then
                local a = U.try(function() return n.o.Asset end)
                w({ ev = "niagara_new", comp = U.valid(n.o) and U.short(n.o) or "gone",
                    asset = U.valid(a) and a:GetFullName() or "nil",
                    outer = U.try(function() return U.short(n.o:GetOuter()) end) })
            else keep[#keep + 1] = n end
        end
        W.new = keep
    end)
    return { ok = true, watching_s = 20 }
end
