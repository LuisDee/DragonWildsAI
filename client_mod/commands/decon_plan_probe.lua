-- READ-ONLY probe (deconstruct skill, 2026-11-01): what `deconstruct` WOULD take down, without pressing anything.
-- Prefix `local TARGET = 27` and `local WHOLE = true` (and optionally `local INCLUDE_STATIONS = true`).
-- Prints the queue in order (id, name, kind) and what it leaves, with its reason and words.
return function(log)
    local inst = rawget(_G, "__dwc_bridge")
    if not inst or not inst.module then return { ok = false, reason = "bridge not running" } end
    if rawget(_G, "DW_PAUSE") then return { ok = false, reason = "paused" } end
    local API = inst.module.API
    local D = API.module("deconstruct")
    if not D then return { ok = false, reason = "deconstruct module not loaded" } end
    local target = rawget(_G, "TARGET") or TARGET
    local whole = (rawget(_G, "WHOLE") or WHOLE) == true
    local inc = (rawget(_G, "INCLUDE_STATIONS") or INCLUDE_STATIONS) == true
    pcall(D.ledger, nil, true)
    local here = API.my_position()
    local rows = D.W.pieces(API, here, 120, {})
    if not rows then return { ok = false, reason = "no pieces" } end
    local tgt
    for _, p in ipairs(rows) do if p.pid == tonumber(target) or p.id == target then tgt = p end end
    if not tgt then return { ok = false, reason = "no target " .. tostring(target), n = #rows } end
    local near = {}
    for _, p in ipairs(rows) do
        local dx, dy = p.position[1] - tgt.position[1], p.position[2] - tgt.position[2]
        if math.sqrt(dx * dx + dy * dy) <= 40 then near[#near + 1] = p end
    end
    local words = D.W.words(API)
    for _, p in ipairs(near) do
        if p.actor then
            p.game_says = D.W.can_destroy(API, p.actor)
            if p.game_says and p.game_says ~= 0 then p.game_words = words[p.game_says] end
        end
    end
    local okw, world = pcall(D.world_id)
    local plan = D.plan(near, tgt, { whole = whole, include_stations = inc, world = okw and world or "unknown" })
    local q, l = {}, {}
    for _, p in ipairs(plan.queue) do q[#q + 1] = { p.pid, p.name, p.kind, p.mine and "mine" or nil } end
    for _, p in ipairs(plan.left) do l[#l + 1] = { p.pid or p.id, p.name, p.kind, p.why, p.words, p.holds } end
    return { ok = true, me = here, world = okw and world or nil, target = { tgt.pid, tgt.name, tgt.position }, queue_n = #q, queue = q, left = l }
end
