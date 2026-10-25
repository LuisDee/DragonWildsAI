-- READ-ONLY: spells.ability_status for the defensive/movement spells combat may use, through the same
-- self-built api combat uses (no bridge ctx). No input, no cast.
return function(log)
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local SP = assert(loadfile("C:/gameserver/client_mod/scripts/spells.lua"))()
    local out = { ok = true }
    for _, a in ipairs({ "USD_TempestShield", "USD_Windstep", "USD_PhaseDash", "USD_Surge", "USD_Vengeance", "USD_SnareTrap" }) do
        local ok, r = pcall(SP.ability_status, a)
        out[a] = ok and r or { error = tostring(r) }
    end
    return out
end
