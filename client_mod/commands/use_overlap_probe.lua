-- Does the game take a food use and a drink use at the same time from Claude's client? (needs agent, 2026-11-01:
-- Luis's recording has a Farm Steak and a Clean Water used 0.06-0.83 s apart, 5 times.) Presses the hotbar key of the
-- first clean food and/or drink on the hotbar (ARGS.kinds = {"food", "drink"} by default, in that order, same frame),
-- the way inventory.use does (QuickAccessBar:UseItemInSlot), WITHOUT the one-use-at-a-time gate, and returns the stats
-- right after. The caller polls get_state to see which stats rose and which counts fell. Dev world only.
return function(log)
    local I = assert(loadfile("C:/gameserver/client_mod/scripts/inventory.lua"))()
    local kinds = (type(ARGS) == "table" and type(ARGS.kinds) == "table") and ARGS.kinds or { "food", "drink" }
    local l = I.list(log)
    if not l.ok then return { ok = false, error = "inventory list failed" } end
    local pick = {}
    for _, d in ipairs(l.hotbar or {}) do
        local k = d.consumable
        if (k == "food" or k == "drink") and not pick[k] and (tonumber(d.soulscourge) or 0) == 0 then pick[k] = d end
    end
    local bar = I.hotbar()
    local p = I.pawn()
    if not bar or not p then return { ok = false, error = "no hotbar widget or pawn" } end
    local function st()
        local function g(c, f) local ok, v = pcall(function() return p[c][f](p[c]) end); return ok and v or nil end
        return { sustenance = g("SustenanceComponent", "GetCurrentSustenance"), hydration = g("HydrationComponent", "GetCurrentHydration") }
    end
    local out = { ok = true, before = st(), pressed = {} }
    for _, k in ipairs(kinds) do
        local d = pick[k]
        if d then
            local ok, err = pcall(function() bar:UseItemInSlot(d.slot) end)
            out.pressed[#out.pressed + 1] = { kind = k, item = d.item, name = d.name, slot = d.slot, count = d.count, ok = ok,
                                              err = (not ok) and tostring(err) or nil, clock = os.clock() }
        else
            out.pressed[#out.pressed + 1] = { kind = k, missing = true }
        end
    end
    out.after_now = st()
    return out
end
