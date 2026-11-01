-- One-off death-memory repair (movement agent, 2026-11-01): deaths recorded by a fall kept the falling body's
-- position (63 m under the cliff top), but the game leaves the grave where he last stood. ARGS.fixes =
-- { { ts = "1793551045.988", position = { x, y, z } }, ... } (metres, the last grounded sample from the server
-- recorder); the old position is kept as body_position. fx.unrecover = true clears a wrong "recovered" mark. Works on the live copy (_G.DWSkills.deaths) and saves it.
return function(log)
    local A = ARGS or {}
    local inst = rawget(_G, "__dwc_bridge")
    local api = inst and inst.module and inst.module.API
    local sk = api and api.module("skills")
    if not (sk and type(sk.graves_remembered) == "function") then return { ok = false, error = "skills module not loaded" } end
    sk.graves_remembered() -- loads the file into memory when it isn't yet
    local mem = sk.memory()
    if type(mem.deaths) ~= "table" then return { ok = false, error = "no deaths in memory" } end
    local done = {}
    for _, fx in ipairs(A.fixes or {}) do
        for _, d in ipairs(mem.deaths) do
            if tostring(d.ts) == tostring(fx.ts) and (type(fx.position) == "table" or fx.unrecover) then
                if fx.unrecover then d.recovered, d.recovered_how, d.recovered_at = false, nil, nil end
                if not d.body_position and type(fx.position) == "table" then d.body_position = d.position end
                d.position = fx.position or d.position
                done[#done + 1] = { ts = d.ts, position = d.position, body_position = d.body_position, grave_id = d.grave_id }
            end
        end
    end
    if A.dry then return { ok = true, dry = true, would = done } end
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local j = dofile(ROOT .. "/client_mod/scripts/dkjson.lua")
    local f = io.open(sk.DEATH_FILE, "wb")
    if not f then return { ok = false, error = "cannot write " .. tostring(sk.DEATH_FILE) } end
    f:write(j.encode({ deaths = mem.deaths })); f:close()
    if log then log("death_spot_fix: " .. #done .. " death(s) moved to where he last stood") end
    return { ok = true, fixed = done }
end
