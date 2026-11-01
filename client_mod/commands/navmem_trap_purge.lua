-- One-off nav-memory repair (movement agent, 2026-11-01): remove learned traps that were never traps, and the
-- duplicate copies of a trap id. ARGS.ids = { "t161", ... } to remove; ARGS.dry = true only reports.
-- Works on the live copy (_G.DW_NAVMEM, which move.lua saves over the file) when it is loaded, else the file.
-- Counts: n_ok was bumped once per TICK while an exit grew and once per walk of a stored exit, so it measured
-- use, not evidence; it moves to n_used and n_ok restarts at 1 (one recorded escape).
return function(log)
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local A = ARGS or {}
    local NM = assert(loadfile(ROOT .. "/client_mod/scripts/navmem.lua"))()
    local mem = rawget(_G, "DW_NAVMEM")
    local src = "live"
    if not (mem and mem.traps) then return { ok = false, error = "nav memory not loaded on the client (run a move first)" } end
    if A.world and mem._world ~= A.world then return { ok = false, error = "loaded memory is for " .. tostring(mem._world) } end
    local drop = {}
    for _, id in ipairs(A.ids or {}) do drop[id] = true end
    local best = {}
    for i, t in ipairs(mem.traps) do
        if not t.seed and not t.disabled then
            local b = best[t.id]
            if not b or (t.n_ok or 0) > (mem.traps[b].n_ok or 0) then best[t.id] = i end
        end
    end
    local kept, removed, dups = {}, {}, 0
    for i, t in ipairs(mem.traps) do
        if t.seed then kept[#kept + 1] = t
        elseif drop[t.id] then removed[#removed + 1] = t.id
        elseif t.disabled or best[t.id] ~= i then dups = dups + 1
        else
            if not t.n_used and (t.n_ok or 0) > 1 then t.n_used, t.n_ok = t.n_ok - 1, 1 end
            kept[#kept + 1] = t
        end
    end
    local out = { ok = true, src = src, world = mem._world, before = #mem.traps, after = #kept, removed = removed, duplicates_dropped = dups }
    if A.dry then out.dry = true; return out end
    mem.traps = kept
    out.saved = NM.save(mem)
    if log then log(string.format("navmem: purged traps %s and %d duplicates (%d -> %d)", table.concat(removed, ","), dups, out.before, out.after)) end
    return out
end
