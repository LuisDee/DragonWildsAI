-- Movement ladder: the ghost leader's phase and its samples since ARGS.from_i ({el_s, gx, gy, gz, mx, my, mz (cm),
-- move status, move source}). ARGS.stop = true also stops the follow (and drops the ghost).
return function(log)
    local ROOT = (os.getenv("DW_CLIENT_ROOT") or "C:/gameserver"):gsub("\\", "/")
    local A = ARGS or {}
    local g = rawget(_G, "DW_GHOST")
    if not g then return { ok = false, error = "no ghost" } end
    local rows, n = g:samples(A.from_i or 1)
    local st = rawget(_G, "DW_MOVE") or {}
    local out = { ok = true, phase = g:phase(), n = n, rows = rows, mode = st.mode, status = st.status,
                  result = st.result, stuck_total = st.stuck_total, lp_runs = st.lp_runs, trail_entries = st.trail_entries,
                  backtracks = st.backtracks, jumps = st.jumps, sprint_presses = st.sprint_presses,
                  trail_skips = st.trail_skips, double_jumps = st.double_jumps, trail_jumps = st.trail_jumps }
    if A.stop then
        local M = assert(loadfile(ROOT .. "/client_mod/scripts/move.lua"))()
        if st.mode == "follow" then M.stop(log) end
        _G.DW_GHOST = nil
    end
    return out
end
