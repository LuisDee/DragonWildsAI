-- READ-ONLY: what gather would see around Claude (client_mod/scripts/sense.lua foliage scan + the
-- census resources). Standing trees within 40 m as foliage rows (class, name, tool gate from the class
-- default object, HP), then the census resources list (which now includes foliage). No input, no moves.
return function(log)
    if _G.DW_PAUSE then return { ok = false, reason = "paused" } end
    local S = assert(loadfile("C:/gameserver/client_mod/scripts/sense.lua"))()
    local pawn = S.local_pawn()
    if not pawn then return { ok = false, reason = "no pawn" } end
    local me = S.U.loc(pawn)
    local t0 = os.clock()
    local rows = S.foliage(me, 4000, { kinds = { tree = true }, max = 12 })
    local ms = math.floor((os.clock() - t0) * 1000)
    for _, r in ipairs(rows) do r._comp, r._pos = nil, nil end
    local c = S.census(log, { radius_m = 40, max = 15, kinds = { resources = true } })
    local res = {}
    for _, r in ipairs(c.resources or {}) do res[#res + 1] = { r.name, r.kind, r.distance, r.tool, r.tool_tier, r.health } end
    -- is the axe chop montage already in memory? (StaticFindObject never loads; a first-ever swing
    -- might load it synchronously, the suspected hang pattern)
    local loaded = {}
    for _, path in ipairs({ "/Game/Art/Animation/PlayerM/Hatchet/AM_Player_Axe_OnSpot_Woodcut1.AM_Player_Axe_OnSpot_Woodcut1",
                            "/Game/Gameplay/Character/Player/Attacks/Axe/BP_Player_Axe_Woodcut1.BP_Player_Axe_Woodcut1_C" }) do
        loaded[path:match("([%w_]+)$")] = S.U.find_object(path) ~= nil
    end
    return { ok = true, loaded = loaded, me = S.U.to_wire(me), trees = rows, trees_ms = ms, census_ms = c.ms, census_resources = res }
end
