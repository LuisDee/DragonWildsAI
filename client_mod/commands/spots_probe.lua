-- READ-ONLY: run spells.lua's W.spots (placed-spell spot candidates, traces only) around Claude and
-- report how many pass and the best few. No input, no cast. (Player clearance not applied here.)
return function(log)
    if rawget(_G, "DW_PAUSE") == true then return { ok = false, reason = "paused" } end
    local root = "C:/gameserver/client_mod/scripts/"
    local sense = assert(loadfile(root .. "sense.lua"))()
    local SP = assert(loadfile(root .. "spells.lua"))()
    local api = { module = function(n) if n == "sense" then return sense end end, census_things = function() return {} end }
    local t0 = os.clock()
    local spots = SP.W.spots(api, nil)
    local far = SP.W.spots(api, nil, { rings = SP.cfg.far_rings_m, los = false })
    local fb = {}
    for i = 1, math.min(3, #far) do fb[i] = far[i] end
    local out = { ok = true, n = #spots, cpu_s = os.clock() - t0, best = {}, far_n = #far, far_best = fb }
    for i = 1, math.min(5, #spots) do out.best[i] = spots[i] end
    return out
end
